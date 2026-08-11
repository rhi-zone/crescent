EXPERIMENT — afternoon-test artifact, not canon.

# v10_toy

A from-scratch, toy-scale build of the "v10" derivation architecture,
implemented from a one-page concept sketch alone — no other file under
`lib/type/` or `docs/` was read while building this (see STUMBLE LOG entry
17). The point of the exercise is to see whether that concept page is
sufficient to build a working, replay-checked type system, and to record
every place it wasn't.

Pure Lua, LuaJIT-compatible, no dependencies. Annotations (`--:`/`--::`) were
originally left off, since typechecking isn't part of what this experiment
measures — but the repo's `.githooks/pre-commit` hook runs `bin/cr check` on
every staged `lib/**/*.lua` file and blocks the commit outright on new
errors, and `--no-verify` is a hard "never" per this repo's own rules. So all
three files ended up fully annotated after all, purely to satisfy that gate
— see the "typechecker detour" section below, which turned out to be a
second, unplanned mini-experiment in its own right (and surfaced four real
compiler gaps, now logged in `TODO.md`).

## Layout

- `init.lua` — the **trusted kernel**: terms, signatures, pattern matching,
  instantiation, and `replay()`. This is the only code a consumer needs to
  trust.
- `w.lua` — signature + rules for a tiny lambda calculus, and an **untrusted**
  Algorithm W prover that emits a derivation for `replay()` to check
  independently.
- `v10_toy_test.lua` — tests (uncounted against the line budget).

## Running

```
bin/cr test lib/type/v10_toy/
```

## Line counts (final)

- `init.lua`: 241 non-blank, non-comment-only lines
- `w.lua`: 274 non-blank, non-comment-only lines
- **Total core+W: 515 lines** — over the 400-line soft target by about 29%.
  Reported, not hidden. Two separate sources of overage, roughly half each:
  (1) the *design* overage from before any annotation work (415 lines: driven
  by `w.lua`'s 8-rule table and the two-phase infer/emit prover needed to
  keep inference — untrusted, mutable substitution — cleanly separated from
  emission — deterministic, replayable); (2) the *typechecker-workaround*
  overage layered on afterward (~100 lines: checked casts on individual
  fields, `type(x) == "table"` narrowing guards in place of truthy checks,
  and one real restructuring — `replay_node`'s tagged `ReplayResult` instead
  of overloaded multi-return arity — all documented inline with
  `TYPECHECKER WORKAROUND:` comments and cross-referenced in `TODO.md`). I
  did not find a way to shrink the design overage without cutting a required
  test case (let-polymorphism) or merging trusted/untrusted code; the
  workaround overage is a direct, roughly 1:1 cost of the compiler gaps
  themselves.
- `v10_toy_test.lua`: 278 lines (uncounted).

## Typechecker detour

This wasn't part of the plan. The task said annotations were optional here
— but `.githooks/pre-commit` doesn't know that; it typechecks every staged
`lib/**/*.lua` file regardless, and this repo's hard rules forbid
`--no-verify`. So getting these three files to a clean `git commit` required
fully annotating and typechecking them anyway, entirely separate from (and
after) the concept-page design work above. That turned into its own
mini-investigation: four distinct, reproducible compiler gaps, each
confirmed with a minimal repro outside this experiment's files before being
worked around here (full detail + repro descriptions in `TODO.md`, dated
2026-08-11):

1. **Self-recursive discriminated unions can't be constructed.** For a union
   type where one variant's field references the union itself (e.g. `Node`'s
   `premises: Node[]`), assignability against the union checks ONLY its
   first declared arm — ever, for any value, any cast strategy (checked,
   forced, or routed through `unknown`). The only construct that reliably
   accepted a value of the "wrong" (non-first) arm was narrowing to a bare
   `table` via `type(x) == "table"` with no further cast. This is the
   deepest and most consequential of the four — self-recursive discriminated
   unions are an ordinary pattern (ASTs, certificate/derivation trees), and
   this repo's own `TODO.md` already had two related-but-distinct entries
   from `lib/type/v10_kernel`'s replayer before this one.
2. **Uninitialized annotated locals need `nil` in their type even under
   complete branch coverage.** No definite-assignment analysis; worked
   around with a real (always-overwritten) initializer instead of widening
   the type.
3. **This repo's standard `T | (nil, string)` return convention doesn't
   narrow via truthy checks anywhere** — not on a fresh call, not on a
   stored-then-checked result, not even the boolean-literal-discriminant
   form. `type(x) == "table"` narrowed correctly every time it was tried in
   its place.
4. **Local (non-stdlib) `require` results type as `unknown` with no
   annotation syntax discoverable for declaring their type** — within this
   experiment's own no-`docs/`-reading constraint. CLAUDE.md references a
   `$Require<T>` mechanism for this that wasn't found by trial; worked
   around with a `type() == "table"` narrow-guard plus one checked cast to a
   hand-written interface per file.

None of these affect the concept-page experiment's own findings above — they
are purely about getting this file past the repo's *own* Lua dialect, a
concern this experiment's concept page has no opinion on either way.

## Effort self-report

Rough wall-clock/effort: the large majority of the *design* time went into
reasoning about pattern/instantiation semantics *before* writing any code —
especially working out, by hand, whether "crossing binders shifts indices"
applies between a rule's premise pattern and its conclusion pattern (it does
not, for every rule this toy needed — see STUMBLE LOG #2). Implementation
itself was comparatively fast once the design was pinned down. Two real bugs
surfaced immediately on first test run (STUMBLE LOG #10, #12) and were each
fixed in one pass after a hand-trace located them precisely — at that point
the design+implementation+tests phase was done and green.

The typechecker detour that followed (getting the already-working,
already-tested code past the pre-commit gate) took roughly as long again as
the whole design+implementation+tests phase before it, almost entirely spent
isolating the four compiler gaps above into minimal, confident repros (each
verified in a scratch file outside this experiment's own files before being
trusted as "real" and worked around) rather than writing annotations per se
— once a gap's actual shape was pinned down, the workaround itself was
usually a few lines.

## STUMBLE LOG

Every point below is somewhere the concept page underdetermined something.
Each entry: what was ambiguous, what I chose, and why.

1. **Where a variable's sort lives.** The concept says a term is "a variable
   (de Bruijn index)" without saying whether its sort is stored on the node
   or derived from an ambient binder-context stack. I store `sort` directly
   on `var` nodes. This keeps `sort_of(term, sig)` a pure, context-free
   function (no threading of an enclosing-binder stack through every call
   site), at the cost of the representation allowing an internally
   inconsistent var/binder sort pairing that nothing but `match` ever checks.

2. **"Crossing binders shifts indices" — the central design fork.** I spent
   most of this experiment's effort here. The concept states this as a
   requirement for `instantiate`, but doesn't say relative to *what* two
   points a shift is computed. I worked a concrete case by hand: `AbsType`'s
   `Body` metavariable is captured in the premise pattern `typeof(Body, T2)`
   at binder-depth 0 (no binder there), and used in the conclusion pattern
   `typeof(abs(Body), arrow(T1,T2))` at binder-depth 1 (inside `abs`'s bound
   argument). The textbook shift formula (`shift(value, 0, use_depth -
   capture_depth)`) predicts a `+1` shift there — which is *wrong*: it turns
   `abs(var(0))` (the identity function) into `abs(var(1))` (a dangling
   reference). The reason: in this system, object-level context is carried
   by the hypothesis+discharge side channel, not by pattern-schema nesting —
   a captured subterm's own de Bruijn indices are already correct relative to
   its real position in the whole program, independent of how deeply the
   *pattern* happens to nest the metavariable token. So `instantiate` in
   `init.lua` performs **no automatic index shifting**; metavariables
   substitute completely verbatim. I could not find a case, across this
   toy's 8 rules, where this produces a wrong result — but I also could not
   derive, from the concept page alone, a general rule for *when* shifting
   would be needed here instead of the hypothesis mechanism handling it. This
   is the single biggest place the concept page underdetermines behavior;
   a fuller system would need to either specify the shift rule precisely or
   commit explicitly to "no term-sort metavariable is ever captured and
   reused at differing pattern depths."

3. **Matching against a target that isn't metavariable-free.** Concept #2
   says matching is against "a metavariable-free term," but Algorithm W
   necessarily produces *intermediate* judgments containing unresolved
   unification variables. Resolved by design, not by extending `match`: the
   prover (`w.lua`) runs inference and unification entirely in a private,
   untrusted phase, and only emits derivation nodes *after* inference
   completes, walking the AST with the final substitution applied. Every
   term `replay()` ever matches against is therefore genuinely
   metavariable-free, except for `forall`-bound (not meta-) type variables in
   generalized schemes, which are ordinary bound `var` nodes, a different
   thing entirely. `match`/`instantiate` in the kernel needed no special
   casing for this.

4. **Rule citations supplying bindings the premises don't determine.**
   Concept #5 explicitly gives axiom citations bindings ("axiom citations
   (with bindings for the axiom's metavariables)") but says nothing about
   ordinary rule citations. `InstantiateEndo` needs to introduce a fresh
   type at a polymorphic use site — a metavariable (`M`) that appears only
   in its conclusion pattern, never in any premise pattern, so nothing in
   match-against-premises can produce a value for it. I extended rule nodes
   with an optional `bindings` field (mirroring axiom citations) used *only*
   to pre-seed metavariables no premise touches; anything a premise *does*
   bind is still independently recomputed by `match` and never trusted from
   the citation. This preserves the trust boundary (nothing checkable is
   taken on faith) while making fresh-metavariable introduction possible.

5. **What "equal" means for discharge.** Concept #6: "h's carried judgment
   to equal the slot's hypothesis pattern instantiated with the shared
   bindings" reads as a plain equality check on an already-fully-instantiated
   pattern. But `AbsType`'s discharge hypothesis pattern `typeof(var(0), T1)`
   has `T1` bound by *nothing else* — no premise pattern mentions it. If
   discharge were pure equality-after-full-instantiation, `T1` could never
   be resolved and `AbsType` would be inexpressible. I read "equal" as "checked
   via the same `match` procedure used for premises" — i.e. discharge
   patterns may still contain unbound metavariables, and matching them
   against a hypothesis's actual judgment both checks and extends the shared
   bindings. This is a real, load-bearing interpretive choice, not a nuance.

6. **Hypothesis identity.** Nothing in the concept requires hypothesis nodes
   to carry an explicit id/name. I used the node's own Lua table identity as
   its id (discharge sets are literal arrays of node references), instead of
   inventing a string-id scheme — this sidesteps an entire class of
   id-collision bugs (two unrelated hypotheses accidentally sharing a name)
   for free.

7. **General let-generalization is not expressible in the concept's pattern
   language, at all — a genuine substrate gap, not a shortcut.** Sound
   generalization needs a negative/freshness side condition ("metavariable M
   occurs nowhere outside this subderivation"), and the concept's matching
   primitive (#2) is purely positive: it can test that a metavariable *does*
   occur (and bind it), never that it *doesn't* occur elsewhere. I could not
   find a way to express "close over whichever metavariables happen to be
   free" as a fixed-shape pattern rule at all, for *any* arity. I sidestepped
   this by hand-writing two rules (`GeneralizeEndo`/`InstantiateEndo`) fixed
   to the exact scheme shape this toy's tests need (`forall a. a -> a`) —
   sound *for this toy*, because the generalized metavariable happens to
   never be constrained by anything outside its own let-binding, but that
   soundness precondition is exactly the check the pattern language cannot
   state. A general "generalize" rule would need either a freshness/occurs-
   elsewhere primitive the concept page doesn't provide, or a second-order
   pattern construct (binding "which metavariable", not just "which
   subterm") that isn't described anywhere in the six numbered points. This
   is the clearest concrete evidence in this experiment of a place the
   concept page needs more machinery, not more cleverness.

8. **No unification-step rules or axioms were needed, despite being
   explicitly licensed ("plus whatever unification-step rules or axioms you
   need").** I chose a two-phase prover (infer fully, *then* emit) precisely
   so that the derivation never needs to represent an in-progress
   unification state — by emission time every judgment is already resolved.
   This was a real design fork: the alternative (one-phase, emitting nodes as
   inference proceeds, with explicit "unify" rule applications recorded in
   the derivation) is arguably closer to what the concept page seems to
   invite, but is considerably more complex and wasn't needed for anything
   this toy's tests require.

9. **No separate variable-typing rule.** Concept #8 explicitly says to "use
   hypothesis nodes for variable-typing assumptions, discharged at
   abstraction/let," which I read as confirming (not just permitting) that
   hypothesis leaves directly realize the variable rule — there's nothing
   left for a dedicated rule to do. Recorded here because a plausible
   alternate reading (a dedicated `VarType` axiom scheme, one per de Bruijn
   index) was briefly considered and discarded.

10. **Root-acceptance "no free variables" needs binder-depth bookkeeping the
    concept doesn't spell out.** A first implementation treated any `var`
    node anywhere in a term as free — this is wrong (a `var(0)` correctly
    nested inside `abs(...)` is bound, not free) and was caught by a hand
    trace of the first real test, not by the concept page itself. Fixed by
    threading a depth counter through the term tree that increases by each
    ancestor operator argument's declared `binds` count (from the
    signature), so freeness is computed relative to the *actual* enclosing
    binder structure rather than a flat scan.

11. **Order among the three root-acceptance conditions** (no metavariables,
    no free variables, no open hypotheses) is unspecified — a term can fail
    more than one simultaneously. I check metavariables, then free
    variables, then open hypotheses, in that order; this is arbitrary and
    only affects which single error message a caller sees first.

12. **Discharge slots are indexed by declaration position, not by which
    premise they reference — and I got this wrong on first pass.** A rule's
    `discharge` list and a citing node's `discharge` map must agree on what
    the key means. I initially keyed a citing node's discharge map by the
    slot's `premise` field (since `LetType`'s one slot references premise 2,
    I wrote `node.discharge[2]`) rather than by the slot's position in the
    rule's `discharge` array (`ipairs` order, always starting at 1). This
    produced a silent "undischarged hypothesis" rejection on an otherwise-
    correct derivation, caught immediately by the let-polymorphism test.
    Fixed by keying strictly by slot position; `AbsType`'s single slot
    happened to have matching premise-index and slot-index (both 1), which
    is exactly why the bug didn't show up until a rule with a
    non-coincidentally-different premise index (`LetType`, slot 1 → premise
    2) was exercised.

13. **`pair_`/`prod` are not among the "five constructs."** Added solely to
    build the letpoly test the concept page's own example names ("pairing id
    applied at two types") as a single derivation with a shared-hypothesis
    DAG, rather than two disconnected roots. A minor, deliberate scope
    addition, not an underdetermined point, but worth flagging as departure
    from the letter of "declare a signature for a tiny lambda calculus
    (literals, variables, abstraction, application, let)."

14. **Which `let` argument binds.** The concept doesn't spell out that a
    `let`'s *body* (not its bound expression) is the argument that binds a
    variable — the only semantically sensible reading, but the concept's
    operator-signature language (#1) is generic enough that it had to be
    stated as an explicit per-operator choice rather than inferred.

15. **De Bruijn representation is assumed alpha-equivalence-free.** Structural
    equality (`deep_eq`) is plain recursive equality on the term
    representation, relying on de Bruijn indices to make this automatically
    alpha-equivalence-safe. The concept implies this by choosing de Bruijn
    indices at all (#1) but never states it as a property being relied upon.

16. **Axiom naming/versioning convention.** Concept #4 says axioms are
    "named and versioned" but not the concrete syntax. I used a
    `Name@vN` string suffix convention (e.g. `"LitIntType@v1"`).

17. **Directory-level `CLAUDE.md` conflict.** `lib/type/CLAUDE.md` instructs
    reading `docs/type-system.md` before touching anything under `lib/type/`.
    The experiment's own hard constraint is the opposite — no file under
    `lib/type/` or `docs/` may be read, since the point is to measure whether
    the concept page alone suffices. Treated the experiment instruction as
    controlling and did not read `docs/type-system.md`; recorded here for
    the record rather than silently overriding it.
