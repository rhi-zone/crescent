# Typechecker Architecture — From First Principles

The session's iterations (v1 channel-sep → v2 resolution barriers → v3
phasing → bind-ordering → write-intent) each patched the previous
iteration's symptom without re-examining the substrate. This document
re-derives the substrate, classifies each load-bearing decision, then
asks whether the recent iterations were patching the right thing.

Does NOT re-litigate the v2/v3 *data structures* (flat-array AST, FFI
arenas, integer tags, union-find) — those are universally upstream-
correct for a perf-competitive checker and not implicated in current
failures. The questionable surface is the *inference substrate*: the
constrain→solve split, the constraint record, the dispatch model, and
the scheduling discipline.

## 1. Inventory of architectural decisions

| #   | Decision                                                       | Alternatives                                                                                  | Dependent code                                                                                  |
| --- | -------------------------------------------------------------- | --------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| D1  | Inference is constraint-based (Damas-Milner)                   | online unification (v1); demand-driven (Lean elaborator); propagator network; e-graph         | Entire `solve.lua`; v3 cutover; tests asserting order-independence                              |
| D2  | Constraints are flat list records, integer-tagged              | tree-structured (Helium); indexed DB (Coq); explicit edge graph; CHR rule database            | `solve_range` loop; emit-during-solve (η); `_forall_ops` re-emission                            |
| D3  | Constrain and solve are separate phases                        | inline solve during AST walk; interleaved gen/solve; sub-solve recursion                      | `check.lua` pipeline; `gen_function` sub-solve already partially inverts this                   |
| D4  | TV-keyed union-find for equivalence                            | persistent substitution; e-graph union; level/rank skolem trees                               | `unify.bind_var_to_type`, every `find(ctx, tid)` callsite, `tv_waiters`                         |
| D5  | One handler per constraint kind, int switch dispatch           | unified rewrite rules; canonicalize to one shape; CHR                                         | `get_handlers()`; every `solve_*`; the BIND_GENERICS/BOUND/CHECK_ARGS triple                    |
| D6  | Fixpoint scheduling: 4-pass with deferral + waiters            | strict worklist-to-quiescence; explicit dep graph topo; CHR; priority queue                   | `solve_range` pass cap, `c._deferred`, `tv_waiters`, "pass < 4 retry" hack at solve.lua:3972    |
| D7  | Handler return overloaded: `bool \| {solved, emit?, await?}`   | structured effect record; explicit worklist API; monadic                                      | solve.lua:3922-3950 dispatch; `await` field is *documented but unused* by dispatcher            |
| D8  | Writes anywhere via `bind_var_to_type`; reads anywhere via `find` | write-set/read-set declared per constraint; transactional; staged                            | Every fast-path (`solve_sub`'s `try_unify`); bind-ordering doc's premise                        |
| D9  | Let-generalization is sub-solve at AST traversal               | generalize as constraint kind; level-based generalization (Rémy); region-based                | `gen_function` closed-range sub-solve; `_forall_bounds`/`_forall_ops`                           |
| D10 | HKT decomposition is its own constraint kind with gen-time payload | extend unify with HKT rule; canonicalize HKT into TAG_TYPE_CALL + unify                     | `solve_hkt_decompose`; `_hkt_payloads`                                                          |
| D11 | Gen-time mutable channels bridge constrain↔solve              | constraint payload; explicit join-point constraint; effect rows                               | `_last_multi_return*`, `_hkt_payloads`, `_forall_bounds/_ops`; H2-v3's C10/C11/C12              |
| D12 | Errors append to `ctx.errors` during solving                   | errors as failed-constraint records; structured proof-failure tree                            | `solve_range`'s silent_err/dedup; duplicate-error problem                                       |
| D13 | Solver is single-threaded mutation of ctx                      | functional substitution; staged commit                                                        | Every handler                                                                                   |
| D14 | Constraint provenance is implicit (no given/wanted tier)       | tag at emit (bind-ordering doc's proposal)                                                    | The Phase D bug                                                                                 |

## 2. Verdict per decision

- **D1 (constraint-based).** *Right.* v2→v3 fixed real order-dependence. Online unification not viable. Demand-driven is a paradigm change with no evidence it's needed. **Load-bearing & correct.**

- **D2 (flat list).** *Suspect.* Forecloses efficient "what's blocked on TV t?" queries (`tv_waiters` exists to compensate); structural cause of every "scan other constraints to decide" hack. **Load-bearing & suspect.**

- **D3 (gen/solve split).** *Right in principle, porous in practice.* Already violated by D11 (gen-time channels); emit-during-solve (η) re-opens the channel the other way. Honest picture: this is interleaved with implicit ordering invariants. **Load-bearing & correct in principle; the implementation has already abandoned strictness — accept that and design for it.**

- **D4 (union-find).** *Right.* α-bounded, matches the language. E-graphs overkill; persistent substitution loses perf. **Load-bearing & correct.**

- **D5 (handler-per-kind + int dispatch).** *Suspect, entangled with D2.* Every new constraint kind requires editing every handler that might race against it. Unified canonicalize-then-rewrite (GHC) would absorb most. Multi-week rewrite; kind count (~17) is bounded. **Accidental in spirit (you wouldn't design this from scratch) but cheap to keep.**

- **D6 (4-pass + deferral + waiters).** **Wrong.** Three scheduling mechanisms coexist and don't compose: pass cap means waiter can fire too late; "pass < 4 retry" branch at solve.lua:3972 is a confession that quiescence detection is broken. Bind-ordering proposed adding a *fourth* discipline (given-tier) on top. **Single biggest source of failure-mode whack-a-mole. Proximate cause of wake-up-order canary, H2 regression, multi-return correlation gap.**

- **D7 (overloaded return).** *Wrong.* `await` field is documented as informational and unused by dispatcher (solve.lua:3950) — registration happens inside the handler via `await(ctx, c, tv_id)`. Half-built abstraction: protocol pretends to carry intent but dispatcher ignores it. **Accidental (half-applied refactor).**

- **D8 (unrestricted bind sites).** *Suspect.* `try_unify`'s permissive semantics silently lose information. Deeper issue: no notion of "this constraint is *authoritative* for this TV." **Load-bearing & suspect.**

- **D9 (sub-solve for generalization).** *Right, fuzzy boundary.* Bug is D11 + D2: `_forall_ops` exists *because* sub-solve range can't see future call-site constraints. Level-based generalization (Rémy) would dissolve `_forall_ops`. **Load-bearing & correct; surrounding scaffolding is the accidental part.**

- **D10 (HKT as constraint kind).** *Suspect.* H2 regression partly because HKT decomposition reads gen-time channels rather than being a unification rule on TAG_TYPE_CALL. v1's channel-separation tried to fix this at the wrong layer. **Load-bearing & suspect.**

- **D11 (gen-time mutable channels).** **Wrong.** Three channels (`_last_multi_return*`, `_hkt_payloads`, `_forall_bounds/_ops`) each exist because the constraint record can't carry the data and the gen/solve split is enforced only by convention. H2-v3's C10/C11/C12 stay-at-gen-time is a *forced concession* to this decision. **Recent iterations have been engineering around it without naming it.**

- **D12 (error accumulation).** *Accidental.* Drives silent_err/dedup complexity. Errors-as-failed-constraints would be cleaner. **Not implicated in current failures.**

- **D13 (single-threaded).** *Correct.* Don't touch. **Load-bearing & correct.**

- **D14 (implicit provenance).** **Wrong.** What bind-ordering identified. Tier tag is small and addresses rank-N wake-up race directly. **Omission rather than active mistake.**

## 3. Classification summary

- **Load-bearing & correct:** D1, D3 (in principle), D4, D9, D13.
- **Load-bearing & suspect:** D2, D5, D8, D10.
- **Wrong:** D6, D11, D14. *D7 is the half-applied attempted fix to D6.*
- **Accidental:** D5 (overlaps suspect), D7, D12.

**Naming what the recent iterations were patching:** v2/v3/bind-ordering were all working around **{D6, D11, D14}** — three entangled wrongs. v2 (resolution barriers) added a *fourth* scheduling mechanism (waiters) without removing D6's pass loop. Phase D failed because waiters can't express priority — that's D14. Bind-ordering then proposed tier-guards — patching D14 and D8, but still not removing D6.

The iterations were locally correct (each fixes a real symptom) and globally wrong (none names that D6 + D11 + D14 must be addressed *together*).

## 4. Derived architecture

Requirements: HM let-poly (rank-1 sound, complete), rank-N call-site
(sound), HKT direct-call (working), HKT record dispatch (gap), row
polymorphism (working via TAG_ROWVAR), match types (working), FFI
integration (working), narrowing & predicates (working), error message
quality (must improve), perf parity with tsgo (hard floor).

The principled substrate is **outcome II** with one specific shape:

### Replace D6+D11+D14 jointly with: worklist solver + constraint provenance + closure of channels

1. **One scheduler.** Delete the 4-pass cap and the per-constraint `_deferred` flag. Keep `tv_waiters`. The solver is a worklist drained to quiescence. A constraint either (a) makes progress and is retired, (b) parks on one or more TVs via `await`, or (c) fails with a structured error. Quiescence = worklist empty AND no awaited TV got bound since last drain. **(Replaces D6.)**

2. **Tier-tagged constraints + bind discipline at the chokepoint.** Adopt the bind-ordering doc's two-tier discipline (`TIER_GIVEN`/`TIER_WANTED`), *but only because the worklist now has a place to put it*. `bind_var_to_type` becomes the single arbitration point: if any GIVEN is awaiting `tv`, a WANTED bind awaits instead. **(Replaces D14.)**

3. **Constraint payload carries everything; gen-time channels disappear.** Move `_hkt_payloads` into the constraint record (already attempted in H2-v3 as "carry rank_n_set"). Move `_last_multi_return*` into a `C_MULTI_RET_PROJECT(call_ret_tv, slot_idx, dest_tv)` constraint — slot extraction *awaits* `call_ret_tv` and emits per-slot binds. `_forall_ops` becomes a per-template list still, but emitted from sub-solve via the structured `emit` channel rather than mutated as a side-channel. **(Replaces D11.)**

4. **D7 cleanup as a forcing function for #1.** Make `await` in the return record the *only* way to park. Delete the `return false` deferral path. The dispatcher actually reads `result.await` and registers; handlers stop calling `await(ctx, c, tv_id)` directly. Forces the scheduler to be a real worklist.

5. **D8 mitigation rides on #2.** Replace `try_unify`'s permissive return with `try_unify_strict` returning `(bound, blocked_on_tv | nil)`. Every fast-path that today silently accepts a TV instead parks. Phase E from v2's plan — but it composes correctly because there's only one scheduler.

### What this DOESN'T change

D1, D3, D4, D5, D9, D13. The constraint paradigm, gen/solve split,
union-find, handler-per-kind, sub-solve generalization, single-threaded
mutation: all stay. D2 (flat list) stays *for now*. D10 (HKT as
constraint kind) stays — H2 regression is a scheduling failure, not a
representation failure.

### Sizing

- (1)+(4): replace `solve_range`'s pass loop with a worklist. ~150 LOC delete, ~200 LOC add. One commit, one session.
- (2): tier tag + bind discipline. ~150 LOC across solve.lua/unify.lua/constrain.lua. Half-session.
- (3): payload migration (C10/C11/C12 specifically). ~300 LOC. Hardest piece because it touches NODE_CALL_EXPR. One session.
- (5): `try_unify_strict`. ~80 LOC. Trivial after (1) lands.

**Total: 2-3 focused sessions.**

## 5. Sanity check against recent failures

- **Wake-up-order canary (`wrap2`).** Tier discipline at `bind_var_to_type` blocks the wanted bind until the given (rank-N kind signature) resolves. *Natural fit.*
- **H2 record dispatch regression.** Worklist-to-quiescence means `C_HKT_DECOMPOSE` awaiting its actual TV fires whenever that TV is bound, regardless of pass count. Current failure: "wake-up landed in pass 5." *Natural fit.*
- **Multi-return correlation.** `C_MULTI_RET_PROJECT(call_ret, slot, dst)` awaits `call_ret`. No `_last_multi_return_override`. *Natural fit.*
- **HM Phase 2 `_forall_ops` re-emission.** Emit-during-solve (η) already handles this; worklist makes it cleaner because re-emitted ops are just enqueued. *Natural fit.*

No clever local fix needed for any of the four. The difference from v2:
v2 layered waiters on top of the 4-pass loop, so the wake-up could fire
after the pass budget ran out. The derived architecture removes the pass
loop, removing that failure mode.

## 6. Recommendation

**Adopt the derived architecture: outcome (II).** Three suspect/wrong
decisions (D6, D11, D14) fixed together over 2-3 sessions. Do not adopt
full propagator-network / CHR / e-graph (outcome III) — there is no
evidence the constraint paradigm itself is wrong; the evidence points to
*scheduling and provenance*, both fixable inside it.

**Do not re-attempt v2's bind-ordering as a standalone patch.** It fixes
D14 in isolation; without removing D6, the wake-up race recurs in a
different shape.

**Honest self-assessment:** This is what I'd ship, with one caveat. The
migration order matters: (1)+(4) must land first to give (2)+(3) a place
to live. If (1) reveals that the existing test suite has hidden order-
dependencies on the 4-pass behavior (deferred warnings appearing in pass
N suppressing duplicates in pass N+1 via the dedup machinery), the work
expands. *Moderate risk.* The dedup logic in `solve_range` (3866-3883)
is a smell; it exists because of D6 + D12 interacting, and stripping D6
might surface duplicate-error bugs that were masked.

The architecture is genuinely different from v2 in *one* way: v2 kept
the 4-pass loop and *added* a wake-up channel. The derived architecture
*replaces* the loop with the channel. That distinction is what makes
v2's Phase D fail and what makes this work.

## Open questions for implementation session

1. Does the test suite have any test that asserts a constraint resolves in *exactly* pass N? (Grep for `_solved` outside solve.lua to find tests that introspect.) If so, those tests encode the current scheduling and must be rewritten before (1) lands. **Blocker — must resolve before any code changes.**
2. Sub-solve interaction with the worklist: when `gen_function`'s sub-solve drains its range to quiescence, can a constraint await a TV that only the *outer* solver will bind? Today the answer is "the constraint defers and the outer pass picks it up via `_solved=false`." With a pure worklist, sub-solve must explicitly transfer awaited-but-unresolved constraints to the outer worklist on exit. This is the v2-Phase-D question #3 unanswered.
3. Cycle detection: two GIVENs that await each other's TVs deadlock. Current code doesn't have this case (one signature constraint per TV) but tier discipline makes it expressible. Need explicit "if no progress in a full drain, promote oldest awaited to WANTED" or similar tie-break.
4. Does the duplicate-error dedup machinery (solve_range:3866) survive removal of the 4-pass loop, or does it need replacement? Suspect: not needed under quiescent worklist, because no constraint fires twice. But silent_err exists for a reason — audit.
5. `_forall_ops` migration: should re-emission live in the `C_BOUND` handler (when it fires it knows the instantiation) or in a new `C_INSTANTIATE_BODY_OPS` constraint? Both viable; former smaller, latter more auditable.
