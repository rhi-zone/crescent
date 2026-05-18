# Typechecker — Solver Bind-Ordering (Givens-Before-Wanteds)

Phase D of the resolution-barrier rework hit a wake-up-order failure:
two constraints want to write the same TV; one should run first. The
fix maps directly to GHC's OutsideIn(X) discipline — *givens before
wanteds* — layered on top of the resolution-barrier wake-up queue
Phases A–C already built.

## 1. Survey of prior art

### GHC — OutsideIn(X)

GHC partitions constraints into **givens** (known-true facts from data
ctors, GADT pattern matches, signatures, type-class superclasses) and
**wanteds** (proof obligations from use sites). The fundamental
discipline: *wanteds never rewrite givens; givens are canonicalized and
used to rewrite wanteds.* Canonicalization brings constraints to a
normal form so order-of-arrival doesn't change the result; the worklist
drains canonicals into the inert set. Implication constraints
(`forall vars. givens => wanteds`) make scope explicit. Refs:
[sheaf/ghc-constraint-solver](https://github.com/sheaf/ghc-constraint-solver/blob/master/constraint_solving.md),
[Tweag: tcplugins II](https://www.tweag.io/blog/2021-12-09-tcplugins-2/).

### Helium / Top (Heeren)

Constraints emitted as a tree mirroring the AST; a separate **ordering
phase** flattens the tree using a chosen traversal strategy. Different
orderings emulate W, M, G algorithms and yield different error
messages. Crucial separation: generation produces a partial order
(tree); a strategy commits to a total order. Ref: Heeren,
["Ordering type constraints"](https://citeseerx.ist.psu.edu/document?repid=rep1&type=pdf&doi=61e3284c9926dcb87e822f03be36ae0297e9a29e).

### Coq / Lean elaboration

Constraints kept in a queue, classified by kind, prioritized: *delta,
quasi-pattern, flex-rigid, recursor, postponed (choice), flex-flex* —
within a class, FIFO. A constraint blocked because its head is a
metavariable `?m s` is **stuck on `?m`**; solver maintains `U[?m]` so
that when `?m` is instantiated, every constraint stuck on `?m` is
woken up. Ref:
[de Moura et al., "Elaboration in Dependent Type Theory"](https://leodemoura.github.io/files/elaboration.pdf).

### Agda

Same shape: postponed constraints carry a **blocker** describing the
meta(s) they wait on; `wakeupConstraints` re-fires them when those
metas are instantiated.

### TypeScript

Two-pass inference: skip context-typed arguments on pass 1 so other
args fix the type parameters first; pass 2 visits everything. Per-
position **priority numbers** — higher-priority candidate discards
lower-priority. Explicitly heuristic. Ref:
[TS Wiki: Reference Checker Inference](https://github.com/microsoft/TypeScript/wiki/Reference-Checker-Inference).

## 2. Categorization

| Category                                          | Systems                                                     |
| ------------------------------------------------- | ----------------------------------------------------------- |
| Givens-before-wanteds (rigidity priority)         | GHC OutsideIn                                               |
| Telescope / tree-ordered generation               | Helium / Top                                                |
| Worklist priorities by constraint kind            | Coq / Lean                                                  |
| Canonicalization to order-insensitive form        | GHC canonicaliser                                           |
| Stuck-on-meta with wake-up queue                  | Coq, Lean, Agda (and crescent's `tv_waiters` from Phase B)  |
| Pass-ordered inference with position priority     | TypeScript                                                  |

## 3. Mapping crescent's situation

The wake-up-order bug is precisely the GHC givens-vs-wanteds case, NOT
the Coq stuck-on-meta case:

- `C_BOUND` derives `A := number` from a **rigid source**: the rank-N
  kind signature `<F: (A,B)->R>` is part of the binder's declared
  type. It's a *given*: knowable without looking at the call's actual
  argument terms.
- `solve_callable`'s eager arg unify writes `A := string` from a
  **flexible source**: the actual argument literal. It's a *wanted*:
  derived from a use site that must conform to the signature.

GHC's discipline says exactly: *givens first, then wanteds rewrite
against the inert set including those givens.* Phase D's "await TV
resolution" is the Coq/Agda mechanism — it correctly handles
*who-resolves-the-meta* once we already know we should wait, but it
does not by itself encode the *priority* between two would-be
resolvers. The fix is to add a priority layer on top of the existing
wake-up queue, sourced from constraint **provenance**, not from
constraint shape.

## 4. Recommended adaptation

**Principle adapted:** OutsideIn-style givens-before-wanteds, expressed
as a two-tier worklist on top of crescent's existing resolution-
barrier (`tv_waiters`) machinery.

### Concrete shape

1. **Constraint provenance tag.** Extend constraint records with a
   `tier` field: `TIER_GIVEN` for constraints derived from declared
   rigid structure (`C_BOUND`, `C_BIND_GENERICS` when sourced from a
   type annotation, named-param decomposition from a signature) and
   `TIER_WANTED` for constraints derived from term-level use sites
   (`solve_callable` arg unifications, return-flow constraints from
   call expressions).

2. **Two-queue solve loop.** `solve.lua`'s main loop drains all
   `TIER_GIVEN` constraints (with normal await/defer semantics from
   Phases B–D) before touching any `TIER_WANTED`. A wanted only fires
   if no given is *makeable-progress-on* this pass. The existing
   fixpoint loop already re-runs constraints; the change is to
   *partition the pass*, not invent new scheduling.

3. **Bind discipline in `unify.bind_var_to_type`.** When a wanted
   attempts `bind_var_to_type(tv, t)`, and `tv` has any awaiting given
   via `tv_waiters`, the wanted *awaits* `tv` instead of binding.
   This subsumes the current `ctx._constraints` scan with a structural
   check on the resolution-barrier data already maintained by Phase B.

4. **Delete the ad-hoc scans** at `solve.lua:2134` and `:2804`. The
   two-queue loop plus the wait-on-blocked-tv rule make them redundant.

5. **Compose with P1.5 (`c26ed415`).** Emit-during-solve handlers tag
   the constraints they emit with the parent's tier (signature-derived
   stays given; site-derived stays wanted). No new channel.

### Honesty

Mostly straight transcription from GHC's discipline, with two
crescent-specific adjustments:
- crescent has no implication constraints, so "scope" collapses to a
  flat partition;
- `tv_waiters` already gives the wake-up half — we only need the
  priority half.

### Sizing

Small-to-medium. Tag field + emission-site audit (~1 day). Two-queue
partition in `solve.lua` (~half day). Bind-discipline rule in
`unify.lua` (~few hours). Ad-hoc scan deletion + test sweep (~half
day). Total ~3 days; no new data structures beyond a single integer
per constraint.

## 5. Critical evaluation

**Why this fits better than alternatives.** Worklist-priority-by-kind
(Coq) over-generalizes — we'd assign a priority to every constraint
kind globally, but the same kind can be given *or* wanted depending on
where it's emitted (`C_UNIFY` from a signature vs. from a use site).
Provenance is the correct discriminator, and that is exactly what
givens/wanteds encodes. Helium-style tree orderings would force a
redesign of generation; we'd rather keep the current emit-during-solve
pipeline.

**What it does NOT solve.** It does not address constraints where *two
givens* race (e.g., two signatures both fixing the same TV — those
must remain unified strictly). It does not give implication scopes, so
deeply nested rank-N inside rank-N may still need explicit barrier
insertion. It does not improve type-error *messages*; Helium's tree
machinery would be the lever for that, in a later phase.

**What it might unlock.** A clean provenance tier is the prerequisite
for: (i) GADT-style narrowing (matches introduce givens local to a
branch); (ii) impredicativity via type-application givens; (iii)
eventually, typeclass-style elaboration if crescent ever grows it — all
of which assume givens-vs-wanteds as the substrate.

## Open questions for implementation session

1. Is `C_BIND_GENERICS` always a given, or only when the callee's type
   came from an annotation? (Inferred-callable case needs auditing.)
2. Should `tier` be inherited automatically by P1.5 emit-during-solve,
   or must each handler call-site declare it explicitly? (Default-
   inherit is safer; explicit is more auditable.)
3. Do return-flow constraints from a call expression count as wanted
   (use-site) or given (the callee's declared return)? GHC treats them
   as wanted; verify against crescent's `solve_callable` return path.
4. For the rare case of two givens racing on the same TV, do we want
   strict unify (today's behavior) or a deterministic "first emitted
   wins" tiebreak from constraint generation order?
5. Can `ctx._constraints` be deleted entirely once the scans are gone,
   or is it still load-bearing for diagnostics / debug dumps?

## Sources

- [sheaf/ghc-constraint-solver: constraint_solving.md](https://github.com/sheaf/ghc-constraint-solver/blob/master/constraint_solving.md)
- [GHC.Tc.Solver (Hackage)](https://hackage.haskell.org/package/ghc-lib-0.20210331/docs/GHC-Tc-Solver.html)
- [Tweag: Type-checking plugins, Part II — GHC's constraint solver](https://www.tweag.io/blog/2021-12-09-tcplugins-2/)
- [Heeren, "Ordering type constraints: a structured approach"](https://citeseerx.ist.psu.edu/document?repid=rep1&type=pdf&doi=61e3284c9926dcb87e822f03be36ae0297e9a29e)
- [Helium4Haskell/Top](https://github.com/Helium4Haskell/Top)
- [de Moura et al., "Elaboration in Dependent Type Theory"](https://leodemoura.github.io/files/elaboration.pdf)
- [Lean.Meta.Basic](https://lean-lang.org/doc/api/Lean/Meta/Basic.html)
- [Agda.TypeChecking.Constraints](https://agda.github.io/agda/Agda-TypeChecking-Constraints.html)
- [TypeScript Wiki: Reference Checker Inference](https://github.com/microsoft/TypeScript/wiki/Reference-Checker-Inference)
