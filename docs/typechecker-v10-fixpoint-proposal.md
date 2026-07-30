> **PROPOSAL — fable-delegation-tier, awaiting orchestrator review.**
> Every rule/axiom/addressing choice below is a delegated-execution design
> decision made to produce a concrete, reviewable artifact — none of it is an
> owner ratification, and all of it is re-openable on challenge. This is a
> design document only: **no `lib/` code is added or modified by this
> proposal.** Several sections below are HALT-adjacent findings (structural
> facts discovered by tracing the ratified replayer's own validation code
> against the proposed rule shapes) that block a naive reading of the
> orchestrating brief; each is resolved within this document using only
> already-ratified mechanisms (schematic axioms, shared non-linear
> metavariables) — none requires touching `lib/type/v10_cleanroom/`. Where a
> genuine choice remains open, it is flagged as such, not resolved silently.

# Fixpoint-certificate proposal: loop invariants and branch joins over the v10 pilot

Scope: extend the flow-narrowing pilot
(`lib/type/v10_kernel/pilot/flow_narrow_v1.lua`) with theory content letting a
prover CERTIFY a loop invariant and a branch join, replayed pointwise by the
existing `lib/type/v10_cleanroom/replayer.lua` — never by re-running the
iteration. Continues `docs/decisions/typechecker-v10-core-design.md`'s "Pilot:
flow-narrowing on the kernel" plan (step 3, further theory content) under the
same fable-delegation-tier execution delegation recorded there.

Substrate read for this proposal: the core design record in full (F1–F13,
the replayer's discharge/taint/schematic-axiom sections), every module in
`lib/type/v10_kernel/pilot/` (`addr_v1.lua`, `prover_addr.lua`,
`flow_narrow_v1.lua` + its test, `narrow_pilot_v1.lua`,
`pilot_initial_facts_v1.lua`, `prover_narrow.lua`, `prover.lua`),
`lib/type/v10_cleanroom/replayer.lua` in full (read, not modified — its
`declare_rule`/`declare_axiom` validation code is what several findings below
trace through literally), and `docs/typechecker-v10-pilot-measurement.md`
(what real corpus code, and its absence of while-loop-guard hits, actually
looks like).

---

## 0. Summary of findings, up front

1. **The discharge/hypothesis machinery does carry the loop-invariant rule —
   but only after a real gap is closed.** A naive premise list for the loop
   rule (as sketched in the orchestrating brief) **fails `declare_rule`'s F11
   validation**: the program point at which the invariant is concluded to
   hold has no premise to ground it in. The fix is a new schematic
   point-binding axiom (§3.4), in the same idiom as `pilot-syntax-facts-v1`.
   This is not a workaround — it is required by the same validity-by-
   construction discipline that already governs every other rule in this
   pilot, and it generalizes: **any rule whose conclusion names a program
   point not equal to one of its premises' own points needs an explicit
   point-binding syntax-fact premise** (§3.4, §4 restate this as a named,
   reusable principle).
2. **"Member-of-union," read as a single recursive rule, is not
   `declare_rule`-admissible at all** — not a workaround-needing case, a
   structurally blocked one: recursing across an arbitrary union spine needs
   to introduce a fresh type metavariable with no premise to bind it, which
   `declare_rule`'s F11 check (conclusion/discharge metavariables must be a
   subset of premise metavariables) rejects outright, for the same reason
   flow_narrow_v1's own rules never needed a "which member" search — rules
   only ever bind by matching against an already-computed premise
   conclusion, never by free choice. The subsumption theory (§1) is
   therefore **five** declared objects, not three, splitting the brief's
   "member-of-union" into two AXIOMS (unconditional, citer-supplied
   bindings) plus a genuine transitivity RULE — this is presented as a
   correction to the brief's framing, not a silent substitution.
3. **The addressing contract's primitives already suffice for loop points —
   but a semantic reading needs to be added, not a new operator.**
   `entry_of`/`exit_of` already wrap any path term; what is missing is the
   prover-side CONVENTION that `exit_of` of a *block's own path* (not only an
   expression's own path) denotes "the point after the block's last
   statement." This is a `prover_addr.lua`-level documentation addition
   (pilot territory, not cleanroom territory) — flagged in §4, not a HALT.
4. **The worked real-loop example (§5) could not be completed as a fully
   axiom+rule-derived certificate.** Two of its premises — the pre-loop fact
   and the back-edge fact — are not producible under this proposal's own
   declared scope for assignment transfer (§2: literal or annotated-source
   RHS only). The certificate is presented with those two leaves as open
   HYPOTHESES, replayed via `M.observe` (not root-strict `M.replay`) —
   exactly the existing precedent `flow_narrow_v1_test.lua` already
   established for facts a theory's own scope cannot derive. This is reported
   as a real scope boundary the worked example exposed, not glossed over.
5. **A "sequential flow between sibling statements" judgment is completely
   undesigned and is the actual prerequisite** for ever deriving a loop's
   pre-loop fact from real preceding code (as opposed to assuming it). This
   is recorded as an open substrate question (§6), per "frame gaps as
   substrate, not results" — it is not resolved here, and no rule below
   depends on it existing.

---

## 1. Subsumption judgment `ty_sub(A, B)`

### 1.1 Why a naive 3-rule reading fails, and the corrected 5-object theory

The brief asks for "reflexivity, member-of-union, union-of-subsets," minimal,
pilot-scoped. Read literally as three rules, this is not
`declare_rule`-admissible. Tracing `replayer.lua`'s `M.declare_rule`
(`lib/type/v10_cleanroom/replayer.lua:178-246`): a rule's conclusion
metavariables, and every discharge slot's hypothesis-pattern metavariables,
must be a subset of the union of the rule's own PREMISE patterns'
metavariables (F11). This is enforced because a rule's metavariables are
bound *only* by matching against a premise's already-computed, ground
conclusion (`ta.match_into`, called once per premise into one shared
environment) — there is no other channel; a rule cannot invent a value.

A single rule intended to prove "`A` is a member of `B`'s union spine at any
depth" needs a shape like:

```
ty_sub(A, Rest)  ⊢  ty_sub(A, ty_union(X, Rest))
```

`X` (the type prepended at this recursion step) occurs in the conclusion but
in no premise — rejected at `declare_rule` time, unconditionally, regardless
of how the rule is phrased, because there is structurally no premise `X`
could ever be matched from. This is exactly the class of thing F11 exists to
reject ("a rule that can never replay is malformed at birth").

**Axioms do not have this constraint** (`M.declare_axiom`,
`lib/type/v10_cleanroom/replayer.lua:154-172`, has no metavariable-subset
check at all): an axiom citation supplies every binding directly
(`replay_axiom`, `lib/type/v10_cleanroom/replayer.lua:400-459` — bindings
come from the citing node's `bindings` table, never from matching). So the
"peel one union layer, either side" facts belong as axioms, and only the
combining step (which never needs a fresh, ungrounded variable) is a genuine
rule. The corrected, `declare_rule`/`declare_axiom`-valid theory:

| name | kind | pattern / premises → conclusion | reads as |
|---|---|---|---|
| `ty-sub-refl` | axiom | `ty_sub(A, A)` | reflexivity |
| `ty-sub-union-here-left` | axiom | `ty_sub(A, ty_union(A, Rest))` | `A` is the union's own literal first operand |
| `ty-sub-union-here-right` | axiom | `ty_sub(B, ty_union(X, B))` | `B` is the union's own literal second operand |
| `ty-sub-trans` | rule | `ty_sub(A,B)`, `ty_sub(B,C)` ⊢ `ty_sub(A,C)` | transitivity |
| `ty-sub-union-of-subsets` | rule | `ty_sub(A,C)`, `ty_sub(B,C)` ⊢ `ty_sub(ty_union(A,B), C)` | union monotonicity (LUB introduction) |

Arbitrary-depth membership (`A` nested `k` layers deep in a right-associated
union spine) is then `k` axiom citations of `union-here-right` chained
through `ty-sub-trans`, plus one final `union-here-left` — the exact same
"peel one binary layer, re-cite" idiom `flow_narrow_v1.lua`'s own header
already documents for arbitrary-width unions (`Rest` is an unconstrained
metavariable that may itself be a union). No enumeration, no side condition,
no new kernel primitive.

`declare_rule` validity check for the two rules (worked by hand, since this
is exactly the load-bearing property):

- `ty-sub-trans`: premise metas = `{A,B,C}`; conclusion `ty_sub(A,C)` metas =
  `{A,C}` ⊆ `{A,B,C}`. Valid.
- `ty-sub-union-of-subsets`: premise metas = `{A,C,B}`; conclusion metas =
  `{A,B,C}` ⊆ `{A,C,B}`. Valid.

### 1.2 Open question, flagged not resolved

**Taint cost of using axioms for pure structural truths.** Because
reflexivity and the two union-here facts must be axioms (a direct structural
consequence of F11, §1.1), every derivation that cites them acquires their
citation key in its effective axiom set (`M.effective_axiom_set`) forever —
identically to how a real reality-boundary fact like `pilot-syntax-facts-v1`
is priced. The axiom mechanism's design intent, as recorded in the core
design doc, is "honestly price every non-premise-derived schematic fact" —
which these ARE, mechanically — but reflexivity of a purely structural
relation is not an assumption about the world the way "the parser saw this
guard shape" is. Whether this conflation (unconditional-logical-truth priced
identically to trust-the-parser) is the intended cost model, or whether a
future kernel primitive should distinguish "always-true, untainted" facts
from "trusted, tainted" ones, is **flagged as open** — it does not block this
proposal (no rule below depends on the distinction existing), and resolving
it would touch `lib/type/v10_cleanroom/replayer.lua`, i.e. owner territory,
so it is recorded here rather than acted on.

---

## 2. Assignment transfer

Pilot scope, per the brief: RHS is a literal (nil/true/false/number/string)
or an annotated source; everything else is a counted skip at the prover
(no certificate attempted, same discipline as every other documented scope
limit in `prover_narrow.lua`).

### 2.1 New operators (additive signature bump)

Following the `narrow-pilot-v1` v1→v2 precedent (`flow_narrow_v1.lua` adding
`guard_selects` to the same signature its rules also use `holds_at`/
`ty_union` from — operators are never imported across signatures, only
sorts are), this proposal's new operators land in a **v3 bump of
`narrow-pilot-v1`** (same op set as v2, plus the operators below):

```
assign_literal(assign_point: point, var: path, tag: prim_tag) : judgment
assign_copies (assign_point: point, var: path, source_var: path) : judgment
```

`assign_literal`/`assign_copies`'s first argument, `assign_point`, is —
matching `guard_selects`'s own convention of directly naming the point of
interest rather than a location to be further wrapped — the point at which
the transferred fact holds, i.e. **`exit_of(rhs_expr_path)`**: exit of the
*specific init/RHS expression*, not the whole owning statement. This mirrors
the guard rules' own choice of `exit_of(test_expr_path)` as "the guard
point" (not the whole `if`-statement's path) — same idiom, applied to
`NODE_LOCAL_STMT`'s `local_stmt_init_path` / `NODE_ASSIGN_STMT`'s
`assign_stmt_init_path` (both already declared in `prover_addr.lua`, no
addressing-contract change needed for this part).

### 2.2 Reality-boundary axioms (two, same idiom as `pilot-syntax-facts-v1`)

- `pilot-assign-literal-facts-v1`: pattern `assign_literal(P, X, Tag)`, fully
  schematic over all three — "the parser saw a literal of tag `Tag` assigned
  to `X` at `P`."
- `pilot-assign-copy-facts-v1`: pattern `assign_copies(P, X, Y)`, fully
  schematic — "the parser saw `X` assigned from bare-identifier `Y` at `P`."

Both admit no discharge form (enforced by the grammar itself, same as
`pilot-syntax-facts-v1`). Each taints every derivation that cites it with its
own key — "trust the parser saw this assignment shape" is priced exactly
like "trust the parser saw this guard shape."

### 2.3 Transfer rules

```
assign-literal-transfer:
  assign_literal(Pa, X, Tag)  ⊢  holds_at(Pa, X, ty_of(Tag))

assign-copy-transfer:
  assign_copies(Pa, X, Y), holds_at(Pa, Y, T)  ⊢  holds_at(Pa, X, T)
```

`declare_rule` validity: `assign-literal-transfer` premise metas
`{Pa,X,Tag}` ⊇ conclusion metas `{Pa,X,Tag}` (`ty_of(Tag)` introduces no new
metavariable). `assign-copy-transfer` premise metas `{Pa,X,Y,T}` ⊇
conclusion metas `{Pa,X,T}`. Both valid, no point-binding gap (§0.1's
principle) here because `Pa` is already the axiom's own first bound
argument in both premises, not a fresh point the conclusion introduces.

### 2.4 Scope limit, explicit

An RHS that is a call expression, a binary/table expression, or a reference
to a variable whose own type is not independently established, is a counted
skip — no `assign_literal`/`assign_copies` axiom is ever cited for it (the
prover simply does not attempt one, same discipline as
`prover_narrow.lua`'s existing skip-reason bookkeeping). §5's worked example
hits exactly this limit on real code.

---

## 3. Loop-invariant discharge rule

### 3.1 The naive premise list, and why it fails F11

The orchestrating brief's shape: a subderivation with an open hypothesis
`holds_at(loop_head, X, T_inv)`, deriving `holds_at(back_edge, X, T')` plus
`T' ⊑ T_inv`; another premise establishing `T0 ⊑ T_inv` at loop entry;
discharge the hypothesis by explicit-id citation; conclude
`holds_at(loop_head, X, T_inv)`.

Written as literally as possible:

```
premises:
  P1 = holds_at(BE, X, Tp)              -- the discharged subderivation
  P2 = ty_sub(Tp, Tinv)                 -- preservation
  P3 = holds_at(PreLoop, X, T0)         -- entry fact
  P4 = ty_sub(T0, Tinv)                 -- entry subsumption
conclusion:
  holds_at(LH, X, Tinv)
discharge slot: premise 1, hypothesis holds_at(LH, X, Tinv)
```

Collect `premise_metas` from `P1..P4`: `{BE, X, Tp, Tinv, PreLoop, T0}`.
**`LH` (`loop_head`) occurs in neither the conclusion-grounding set nor the
discharge slot's own grounding requirement — it appears ONLY in the
discharge slot's hypothesis pattern and the conclusion, never in a literal
top-level premise.** Both the discharge-slot check (`declare_rule`,
`lib/type/v10_cleanroom/replayer.lua:220-228`: slot metavariables must be
`⊆ premise_metas`) and the conclusion check (`:194-202`) reject this rule at
declaration. This is the HALT-adjacent finding the orchestrating brief
explicitly asked this proposal to surface if the discharge machinery turned
out not to carry the naive shape — it does not, as naively written.

### 3.2 The fix: an explicit point-binding syntax fact

Add one more reality-boundary axiom, same idiom as `pilot-syntax-facts-v1`:

```
loop_edge(loop_head: point, back_edge: point) : judgment
```

"the loop whose test/entry point is `loop_head` has back-edge point
`back_edge`" — schematic over both, axiom `pilot-loop-facts-v1`. Add it as a
literal premise:

```
premises:
  P0 = loop_edge(LH, BE)
  P1 = holds_at(BE, X, Tp)
  P2 = ty_sub(Tp, Tinv)
  P3 = holds_at(PreLoop, X, T0)
  P4 = ty_sub(T0, Tinv)
conclusion:
  holds_at(LH, X, Tinv)
discharge slot: premise 1, hypothesis holds_at(LH, X, Tinv)
```

Now `premise_metas = {LH, BE, X, Tp, Tinv, PreLoop, T0}` — `LH` is grounded
via `P0`, `Tinv` via `P2`/`P4`. Conclusion metas `{LH, X, Tinv}` ⊆
`premise_metas`. Discharge slot metas `{LH, X, Tinv}` ⊆ `premise_metas`. Both
checks pass. **This is the corrected rule** —
`narrow-pilot-v1`'s v3 bump declares it as `loop-invariant-discharge`.

Worked discharge-time check (why it is sound, not a rubber stamp): replay
matches `P0..P4` into one shared binding environment, binding concrete
`LH, BE, X, Tp, Tinv, PreLoop, T0` from whatever the four cited premises'
*actual* conclusions are — `Tinv` in particular is bound from `P2`'s actual
`ty_sub(Tp_actual, Tinv_actual)`, not chosen freely by the citing prover.
Discharge then requires the cited hypothesis leaf's judgment to equal
`instantiate(holds_at(LH,X,Tinv), bindings)` using those SAME bound values —
if the untrusted prover cited a `P2` whose `Tinv` disagrees with what the
subderivation actually assumed inside `P1`, the discharge equality check
fails and replay rejects. The shared non-linear `Tinv` across `P2`/`P4`/the
discharge slot is exactly the same soundness mechanism `flow_narrow_v1`'s own
shared `TA` metavariable already uses — no new kernel behavior, a rule
designed correctly against the existing primitives.

### 3.3 Generalized principle (restated from §0)

Any rule whose conclusion (or discharge-slot pattern) needs a program point
that is not literally one of its premises' own point arguments must add an
explicit point-binding syntax-fact premise. This governs §3's loop rule and
§3.4/§4's join rule identically — both `loop_edge` and (§4) `cf_join` are
instances of one reusable shape: a schematic axiom whose sole job is
"introduce a fresh point metavariable, grounded by direct citer-supplied
binding, for a later premise/conclusion to reference."

### 3.4 What the loop rule does NOT resolve

The rule discharges the ASSUMED-INVARIANT hypothesis; it says nothing about
where `PreLoop`'s fact (`P3`) or the back-edge subderivation's own internal
facts come from. Those are prover-construction problems, addressed (and
found wanting, honestly) in §5 and §6.

---

## 4. Join rule

```
cf_join(pa: point, pb: point, pj: point) : judgment   -- new op, v3 bump
```

Reality-boundary axiom `pilot-cf-join-facts-v1`: pattern `cf_join(Pa,Pb,Pj)`,
fully schematic — "control from either `Pa` or `Pb` reaches `Pj`." For an
`if`/`else` with no further branching, the prover computes `Pa =
exit_of(then_body_path)`, `Pb = exit_of(else_body_path)`, `Pj =
entry_of(next_sibling_stmt_path)` (or, per §0.3/§4.1 below, `Pj =
exit_of(if_stmt_path)` when there is no next sibling).

```
narrow-join:
  holds_at(Pa, X, A), holds_at(Pb, X, B), cf_join(Pa, Pb, Pj)
  ⊢  holds_at(Pj, X, ty_union(A, B))
```

`declare_rule` validity: premise metas `{Pa,X,A,Pb,B,Pj}` (shared non-linear
`X` across the first two premises, same idiom as `flow_narrow_v1`'s shared
`TA`); conclusion metas `{Pj,X,A,B}` ⊆ premise metas. Valid, no discharge
slot needed (this rule never opens or closes a hypothesis). `Pj` is grounded
by the `cf_join` premise per §3.3's principle — checked here explicitly
because it is exactly the same class of gap §3.1 found, caught this time
before being written down wrong.

### 4.1 Contract finding: what `Pj` denotes needs a documented reading, not a new operator

`entry_of`/`exit_of` (`addr_v1.lua`) already wrap *any* path term — there is
no new operator required to name "the point after an `if`-statement" or "the
point after a `while`-statement": it is simply `exit_of(if_stmt_path)` /
`exit_of(while_stmt_path)`, both already well-formed terms today. What is
genuinely missing is that `prover_addr.lua`'s header never establishes this
READING — it only documents `exit_of` applied to expression paths (a guard's
own test expression) and `entry_of` applied to block paths (a branch's own
entry). **Required addition, scoped to `prover_addr.lua` (pilot territory,
not cleanroom):** document that `exit_of` of a *block's own path* (as
opposed to an expression's path) denotes "the point after the block's last
statement" — this single reading covers both the join point (`exit_of` of
the whole `if`-statement's own path, or of its enclosing block when a next
sibling exists to entry-address instead) and the loop back-edge point
(`exit_of(while_body_path)`, §3). No indices change; the existing
`WHILE_BODY_INDEX = 1`/`if_else_index` tables already suffice. This is the
addressing-contract finding item 4 of the orchestrating brief asked to check
for — the answer is "the primitives suffice, a documented convention does
not yet exist," not "a contract addition is needed."

### 4.2 Open question, flagged not resolved

For a `repeat...until` loop, the natural "loop head" (the point re-entered
every iteration, including the first) is `entry_of(body_path)`, not
`entry_of(test_path)` as for `while` — the test runs at the END of a
`repeat` body, not the start. The `loop-invariant-discharge` rule itself
(§3.2) is agnostic to this (it only ever sees whatever `(LH, BE)` pair the
prover's `loop_edge` axiom citation supplies), so no rule duplication is
needed — but which two points a `repeat` loop's prover-side helper should
bind as `(LH, BE)` is a genuine design choice not dictated by anything
ratified, and is **flagged open** rather than picked here (a plausible
candidate — `LH = entry_of(body_path)`, `BE = exit_of(test_path)` treating
the until-condition as non-mutating — is recorded as a candidate, not a
decision).

---

## 5. Worked example over real code

### 5.1 Loop selection

Grepped `lib/` for `while`/`repeat` (see the corpus survey in
`docs/typechecker-v10-pilot-measurement.md`, which independently confirms:
**zero while-loop guards appear anywhere in the pilot's existing tracked
scope across the full 996-file rescan** — annotated-union locals guarded by
a `while` simply do not occur in this codebase today). Three real loops were
examined against this proposal's shapes:

1. **`lib/http/server.lua:113-120`** (and its structural twin
   `lib/https/client.lua:96-108`) — chosen for the full worked DAG below.
   ```lua
   local parts = {} --: { [integer]: string }
   local header_end
   while not header_end do
       local s = client_:receive(buf)
       if not s then keep_alive = false; break end
       parts[#parts + 1] = s
       total = total + #s
       if total > max_header_size then client_:send(err_res); keep_alive = false; break end
       header_end = combined:find("\r\n\r\n", 1, true)
   end
   ```
   `header_end` is a genuine nil-vs-value invariant candidate: `string.find`
   returns an integer or nil, and `type()` of an integer is `"number"` — the
   invariant `header_end : number | nil` fits the six-tag vocabulary exactly.
   **It is not, in the real file, `--:`-annotated** — under the pilot's
   existing scope (`prover_narrow.lua` only tracks `--:`-annotated locals or
   parameters) it would not be tracked at all. The worked DAG below therefore
   **hypothetically annotates it** (`local header_end --: number | nil`,
   flagged as hypothetical, not a claim about the actual file) purely to
   exhibit the certificate shape — a direct consequence of §0.4/§5.3's own
   finding that this real file's loop does not actually fall inside item 2's
   assignment-transfer scope either.

2. **`lib/dice/init.lua:296`** (`while v % rn.sides == 0 and boom <
   MAX_EXPLODE do`) — a genuinely out-of-scope loop, checked deliberately as
   a negative case: the guard is a compound boolean (`and` of two numeric
   comparisons), which `prover_narrow.lua`'s `extract_guard` does not
   recognize as any of the three in-scope guard shapes at all (not
   `type(x)==`, not `x==nil`, not bare truthiness). No `guard_selects`-style
   fact, hence no `loop_edge`-paired invariant rule citation, is possible for
   this loop under this proposal — flagged, not silently mishandled, exactly
   matching `flow_narrow_v1.lua`'s own documented scope-limit discipline.

3. **`lib/oauth2/init.lua:227`** (`while pos <= #s and (s:byte(pos) or 0) <=
   32 do pos = pos + 1 end`) — a second negative case, same reason: numeric
   induction-variable bound, not a six-tag-vocabulary guard. This class of
   loop (index-bound iteration) is entirely outside what `ty_sub`/`ty_union`
   can express at all — the pilot's type vocabulary has no sort for numeric
   ranges; a numeric-bound loop invariant is a different theory altogether,
   not a scope-limit of this one.

### 5.2 Certificate DAG for `lib/http/server.lua`'s loop (hypothetically annotated)

Addressing (per `prover_addr.lua`'s existing tables plus §4.1's documented
`exit_of`-of-a-block reading; indices illustrative, matching the file's own
statement order inside its enclosing function body):

- `hdr_decl_path` — the hypothetical `local header_end --: number|nil`
  statement's own path.
- `while_path` — the `while not header_end do ... end` statement's own path
  (next sibling of `hdr_decl_path`).
- `test_path = child(while_path, WHILE_TEST_INDEX=0)` — the `not
  header_end` test.
- `body_path = child(while_path, WHILE_BODY_INDEX=1)`.
- `assign_path` — the `header_end = combined:find(...)` assignment
  statement's own path, a child of `body_path`.
- `LH = entry_of(test_path)` (loop head, re-tested every iteration).
- `BE = exit_of(body_path)` (back-edge point, §4.1's block-exit reading).
- `PreLoop = entry_of(while_path)` (point immediately before the loop's
  first test — same point as `LH` in this specific case, since nothing sits
  between the declaration and the loop testing it the first time; recorded
  as `PreLoop` for clarity even though it is structurally `entry_of(test_path)`
  reached via the zero-guard path rather than a back edge).
- `T_inv = ty_union(ty_of(tag_nil), ty_of(tag_number))`.

DAG, root at the bottom:

```
H1 = hypothesis: holds_at(BE, header_end_path, T_inv)        -- OPEN (§5.3)
H2 = hypothesis: holds_at(PreLoop, header_end_path, ty_of(tag_nil))  -- OPEN (§5.3)

A1 = axiom pilot-loop-facts-v1, bindings {loop_head=LH, back_edge=BE}
     ⊢ loop_edge(LH, BE)

A2 = axiom ty-sub-union-here-left, bindings {A=ty_of(tag_nil), Rest=ty_of(tag_number)}
     ⊢ ty_sub(ty_of(tag_nil), T_inv)                          -- for T0 ⊑ Tinv

R1 = rule ty-sub-refl-as... [not needed: Tp = T_inv exactly, by construction,
     since the loop body's own reassignment re-establishes the SAME union]
     ⊢ ty_sub(T_inv, T_inv)     via axiom ty-sub-refl, binding {A=T_inv}

R2 = rule loop-invariant-discharge
     premises = [ A1, H1, R1, H2, A2 ]
     discharge = { slot 1 (premise index 2, i.e. H1's position) : { H1 } }
     ⊢ holds_at(LH, header_end_path, T_inv)
```

Root: `R2`, replayed via `M.replay` (root-strict) — but only IF `H1`/`H2`
were not hypotheses. As actually built (§5.3), `H1` and `H2` are open
hypotheses that `R2`'s single discharge slot only closes `H1` (the slot
targets premise index 2 per its declared shape, §3.2) — `H2` (the entry
fact) has **no discharge slot in this rule at all**: nothing in
§3's design discharges the entry-fact hypothesis, because it was never meant
to be a hypothesis in the first place — it was meant to be DERIVED (§5.3).
So the actual replay of this DAG is via **`M.observe`, not `M.replay`** — the
root's open-hypothesis set is `{H1, H2}`, non-empty, and root-strict replay
correctly rejects it. This is asserted, not glossed over: **the worked
example, over this specific real (hypothetically-annotated) loop, cannot be
closed into a root-accepted certificate under this proposal's own declared
scope** — only observed.

### 5.3 Why `H1`/`H2` could not be derived, traced to §0's findings

- **`H2` (`PreLoop`'s fact, `header_end : nil`):** `local header_end` (no
  init expression at all) is not covered by §2's assignment-transfer scope —
  it isn't an assignment with a literal or annotated-source RHS; it is a
  declaration with ZERO init expressions. `prover_addr.lua`'s own addressing
  table has no child index at all for "the implicit nil of an uninitialized
  local" (`NODE_LOCAL_STMT`'s init-expression range is `nl..nl+el-1`; when
  `el = 0` there is no init-expression path to hang a fact off of). This is
  a genuine gap in both the addressing contract and item 2's transfer scope,
  surfaced by trying to write this DAG down, not assumed in advance.
- **`H1` (`BE`'s fact, `header_end`'s type after one loop iteration):** the
  reassignment `header_end = combined:find("\r\n\r\n", 1, true)` is a
  call-expression RHS — explicitly out of §2.4's scope (literal or
  annotated-source only). No `assign_literal`/`assign_copies` axiom
  citation is available for it under this proposal.

Both gaps trace to the SAME root cause: this proposal's assignment-transfer
scope (§2), as given in the brief, covers only the two simplest RHS shapes;
real loop bodies overwhelmingly reassign their invariant-carrying variable
from a function call, which is categorically outside that scope. Widening
item 2's scope to call-expression RHS types is NOT something this proposal
resolves (the brief scoped item 2 explicitly to literal/annotated-source,
"everything else = counted skip") — it is recorded here as the concrete,
corpus-grounded reason the worked example bottoms out in open hypotheses
rather than full derivations, consistent with §0.4/§0.5.

---

## 6. Open questions (flagged, not resolved)

- **Sequential same-scope forward-flow judgment is completely undesigned.**
  Every existing pilot rule (guard narrowing, and every rule in this
  proposal) only ever relates a program point to ANOTHER point reached
  by branching FROM it (a guard's two branches, a loop's back edge, a join's
  two incoming points) — none of them relate a point to the NEXT SIBLING
  statement's own point along ordinary sequential control flow.
  `prover_narrow.lua`'s own documented scope limit ("No control-flow/
  fall-through inference... nothing is asserted about the code textually
  following the statement") is exactly this gap, restated. It is the actual
  prerequisite for ever deriving (rather than hypothesizing) a loop's
  pre-loop fact from real preceding code, or a join's continuation fact
  flowing further forward. This is substrate, not a rule this proposal can
  add piecemeal — recorded per "substrate before consumers," not resolved
  here.
- **Taint cost of using axioms for structural truths** (§1.2) — whether
  reflexivity/union-here being tainted identically to reality-boundary facts
  is the intended cost model, or motivates a future distinct kernel-level
  "untainted schematic fact" primitive. Resolving this would touch
  `lib/type/v10_cleanroom/replayer.lua` — owner territory, not acted on
  here.
- **`repeat`-loop `(loop_head, back_edge)` binding choice** (§4.2) — a
  plausible candidate is recorded, not decided.
- **Uninitialized-local addressing** (§5.3, `H2`) — `prover_addr.lua`'s
  contract has no path for a zero-init-expression local's implicit nil.
  Whether this needs a new addressing convention (e.g. treating the
  declaration statement's own path, not an init-expression child, as the
  fact's anchor) or is simply out of scope is not decided here.
- **Widening assignment-transfer to call-expression RHS** — explicitly out
  of this proposal's scope per the brief; §5.3 records it as the concrete
  reason the worked example bottoms out in hypotheses, without proposing a
  design for it.

---

## 7. What this proposal does NOT touch

No file under `lib/type/v10_cleanroom/` is read as a target for change —
every finding above that traces through `replayer.lua`'s validation code
does so to verify a PROPOSED rule against ALREADY-ratified, unchanged
mechanisms (F11's metavariable-subset check, the schematic-axiom mechanism,
shared non-linear metavariables), never to suggest a kernel change. Per the
standing instruction, anything requiring a `v10_cleanroom` change would HALT
to the owner; nothing in this proposal reached that point — every gap found
was closeable within pilot-territory theory design (`lib/type/v10_kernel/
pilot/`, not yet implemented, this document only).

---

## 8. Addendum — orchestrator resolutions (fable-delegation-tier, resolves §1.2/§6 open items)

Two of §6's open questions were resolved by the orchestrator after this
proposal's initial acceptance. Both resolutions and one retraction are
recorded here verbatim in substance, per this repo's decision-doc
convention of showing the correction, not just the outcome.

### 8.1 Zero-premise-rule proposal: error and correction

The orchestrator's first-pass resolution of §1.2's taint-cost question
proposed reframing reflexivity and the two union-here facts (§1.1's
`ty-sub-refl`, `ty-sub-union-here-left`, `ty-sub-union-here-right`) as
**zero-premise RULES** rather than axioms, on the stated grounds that "the
cleanroom core supports them (F11's rejection list is exhaustive)."

This was traced against the actual `declare_rule`/`replay_rule` code
(`lib/type/v10_cleanroom/replayer.lua:178-246`, `:462-592`) and found
**structurally false, not merely undesirable**, and retracted:

- `declare_rule` computes `premise_metas` by iterating `spec.premises`
  (`:184-193`). With `spec.premises = {}` (a true zero-premise rule),
  `premise_metas` is the empty set unconditionally. A schematic conclusion
  like `ty_sub(A, A)` has `conclusion.metas = {A}`, and the F11 check
  (`:197-202`, `{A} ⊆ {}`) rejects it at declaration — this is the exact
  same mechanism, applied identically, that §1.1 already used to prove the
  naive union-recursion rule inadmissible. It is not a different case.
- Independently, `replay_rule` (`:489-504`) builds `bindings` only via
  `ta.match_into(decl_premises[i], results[i].conclusion, bindings)` for
  `i = 1, #decl_premises`. With zero premises this loop never runs, so
  `bindings` stays empty, and `ta.instantiate(decl_conclusion, bindings)`
  on a conclusion containing a free metavariable errors ("unbound
  metavariable is an error"). Only **axiom** citations carry a
  citer-supplied `bindings` table (`replay_axiom`, F12) — rule citations
  have no channel to supply a binding directly.
- Conclusion: "zero premises" and "a schematic (metavariable-carrying)
  conclusion" are mutually exclusive under the ratified kernel as built.
  There is no fill-in that reconciles them without minting an unstated
  kernel mechanism — which would be a guess, not a decision, under this
  repo's halt discipline.

**Adjudicated correction: option (a), unchanged from this proposal's
original §1.1 text** — reflexivity and both union-here facts remain the
three schematic AXIOMS as originally derived (`ty-sub-refl`,
`ty-sub-union-here-left`, `ty-sub-union-here-right`); `ty-sub-trans` and
`ty-sub-union-of-subsets` remain the two genuine RULES. §1's five-object
table is unchanged by this addendum — the zero-premise reframing is
retracted in full, not partially.

### 8.2 Trust rationale for the structural-truth axioms (recorded, not re-opened)

§1.2 flagged as open whether taxing reflexivity/union-here identically to
a reality-boundary fact (e.g. `pilot-syntax-facts-v1`) is the intended cost
model. Adjudicated: these three axioms are **the same trust object as the
theory's own soundness axiom** (the standing assumption, implicit
throughout this proposal and `flow_narrow_v1.lua` alike, that the pilot's
rule set is a faithful account of the source language's flow semantics) —
not a separate, additional assumption. They burn down together, when and
if theory soundness is ever proved against the prefix; they are not
individually retireable before that. The resulting taint-label noise
(these three axiom keys appearing in the trust label of every subsumption
derivation that uses reflexivity or union membership) is **accepted at
pilot tier** on this basis — recorded as a deliberate cost, not an
oversight.

Parked as an **explicitly open OWNER question, not resolved here**:
whether the kernel should ever gain a distinct "proven-lemma" citation
kind — a bindings-carrying leaf whose own soundness certificate is
replayed once (elsewhere, ahead of time), after which citing it contributes
no per-citation taint, giving untainted structural truths a home distinct
from reality-boundary axioms. This would touch `lib/type/v10_cleanroom/
replayer.lua` — kernel-owner territory — and is not acted on by this
proposal or its addendum.

### 8.3 Sequential flow: design (resolves §6's "completely undesigned" item)

§6 flagged "sequential same-scope forward-flow judgment" as undesigned
substrate, the actual prerequisite for ever deriving (rather than
hypothesizing) a loop's pre-loop fact or a join's continuation fact from
real preceding code. The orchestrator's binding resolution: add this
within existing mechanisms — a statement-adjacency syntax fact, a
non-interference syntax fact, and a persistence rule combining them with
`holds_at`. All three land in the same `narrow-pilot-v1` v3 bump as §2's
assignment-transfer operators (additive, same idiom as the v1→v2 bump
documented in `flow_narrow_v1.lua`'s header).

**New operators:**

```
stmt_seq      (from_point: point, to_point: point) : judgment
stmt_preserves(from_point: point, to_point: point, var: path) : judgment
```

`stmt_seq(A, B)` reads: "the parser saw the statement whose own point is
`B` immediately follow, in the same block, the statement whose own point
is `A`" — i.e. `A = exit_of(stmt_i's own path)`, `B =
exit_of(stmt_{i+1}'s own path)` for two syntactically adjacent statements
(or `A = entry_of(block_path)` when `stmt_i` is the block's first
statement, per §4.1's already-documented `exit_of`/`entry_of`-of-a-path
reading — no new addressing primitive, same convention this proposal
already established for loop/join points).

`stmt_preserves(A, B, X)` reads: "the statement whose execution spans from
`A` to `B` (i.e. `stmt_{i+1}` in the pairing above) does not assign `X`."

**Design choice made here, within the "exact shape yours, documented"
latitude the resolution granted:** `stmt_preserves` takes the SAME
`(from_point, to_point)` pair as `stmt_seq`, rather than an independent
statement-path argument. This is not free-standing stylistic preference —
a version with an independent `stmt_path` argument would let an untrusted
prover cite `stmt_seq(A,B)` for one adjacency and `stmt_preserves(S, X)`
for an UNRELATED statement `S`, with nothing in the rule forcing `S` to be
the statement actually spanning `A` to `B` (no metavariable would be
shared between the two premises at all). Binding `stmt_preserves` to the
same `A`/`B` metavariables as `stmt_seq` makes them non-linear across
premises — the same soundness idiom `flow_narrow_v1`'s shared `TA` and
§3.2's shared `Tinv` already use — so replay's shared binding environment
mechanically rejects any citation pairing that doesn't agree on which span
is being asserted non-interfering. This is exactly the class of gap §3.3's
generalized point-binding principle warns about, caught here before being
written down wrong, per that same principle's own instruction.

**Reality-boundary axioms** (same idiom as `pilot-syntax-facts-v1` /
`pilot-loop-facts-v1`, no discharge form):

- `pilot-stmt-seq-facts-v1`: pattern `stmt_seq(A, B)`, fully schematic.
- `pilot-stmt-preserves-facts-v1`: pattern `stmt_preserves(A, B, X)`, fully
  schematic. "Non-interference" here means the parser confirmed the
  statement in question is not a `NODE_ASSIGN_STMT`/`NODE_LOCAL_STMT`
  naming `X` among its targets/declared names — a purely syntactic check,
  same trust boundary as every other syntax-facts axiom in this proposal
  (it does not reason about aliasing, `_G`, metatables, or any semantic
  effect).

  **Correction (Phase 3, pilot/fixpoint_prover.lua):** the addendum's
  original text above additionally claimed this is "trivially true for any
  statement kind this pilot does not itself address as an assignment
  target, e.g. `NODE_IF_STMT`, `NODE_WHILE_STMT` as a whole statement, bare
  call-statements" — i.e., that any compound/control-flow statement
  vacuously preserves `X` merely because this pilot's assignment-tracking
  code doesn't currently model assignment targets nested inside its own
  child blocks. This is **wrong as a general claim, not merely imprecise**:
  an `if`/`while`/`repeat`/`do` statement CAN contain a nested assignment
  to `X` inside its own child block, which the parser can plainly see by
  walking one level deeper — "this pilot's existing code doesn't walk that
  deep" is an IMPLEMENTATION GAP, not a proof of non-interference. Reading
  the retracted sentence as license to emit `stmt_preserves` for a
  compound statement would let the prover cite a FALSE reality-boundary
  axiom (an honestly-priced axiom must still assert something TRUE about
  the file).

  **Corrected, conservative rule, as actually implemented by the prover:**
  `stmt_preserves(A, B, X)` is only ever emitted for a statement PROVABLY
  non-interfering with `X`, specifically: (a) `NODE_LOCAL_STMT` (any
  declared name — it always introduces a fresh binding at a path distinct
  from `X`'s own declaration site, so it structurally can never rebind
  `X`); (b) `NODE_ASSIGN_STMT` whose target list does not include `X`; (c)
  a bare call-expression-statement (`NODE_EXPR_STMT` wrapping a call) —
  this last one IS a documented, flagged trust-boundary limitation (it does
  not reason about upvalue mutation through a closure call), same
  honesty-priced-trust-boundary idiom as every other syntax-facts axiom in
  this pilot (e.g. `guard_selects` not reasoning about aliasing). Any OTHER
  statement kind between two points (`if`/`while`/`repeat`/`do`/`for`/
  `return`/`break`/anything else) is NOT treated as preserving —
  persistence chaining simply stops there (a counted skip, not a
  certificate attempt), conservative but sound.

**Persistence rule:**

```
seq-persist:
  holds_at(A, X, T), stmt_seq(A, B), stmt_preserves(A, B, X)
  ⊢ holds_at(B, X, T)
```

`declare_rule` validity: premise metas `{A,X,T,B}` (shared non-linear `A`
across all three premises, `B` across the last two, `X` across the first
and third); conclusion metas `{B,X,T} ⊆ {A,X,T,B}`. Valid, no discharge
slot (this rule never opens or closes a hypothesis), no point-binding gap
(`B` is grounded by the `stmt_seq` premise, per §3.3's principle — checked
explicitly here for the same reason §4's join rule checked it explicitly).

This closes §6's substrate gap for the SAME-BLOCK, straight-line case only:
chaining `seq-persist` citations statement-by-statement down a block is
how a fact established early in a block (e.g. an annotated declaration, or
an assignment-transfer conclusion from §2) reaches a later point in that
same block, PROVIDED every intervening statement is confirmed
non-interfering. It does not address control-flow-changing statements
(`if`, `while`, `break`, `return`) themselves — those remain the loop-edge
(§3) and join (§4) rules' own territory; `seq-persist` is the connective
tissue BETWEEN them along ordinary fall-through, not a replacement for
either.

