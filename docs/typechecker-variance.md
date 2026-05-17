# Typechecker — Declaration-Site Variance

Design for variance annotations on generic parameters. **A3 in the roadmap.**

## Status

**Not implemented. Design only. Demoted from "soundness" to "expressiveness"
on 2026-05-17.**

Originally framed as a soundness gap (`docs/soundness-audit.md` Gap 3), but
probing showed that structural invariance on table fields + function
parameter contravariance + `FLAG_SKOLEM` bind-rejection already prevent the
bad cases. Concrete probes confirmed:

- `Container<string>` cannot be passed where `Container<number>` is required
  (structural invariance on fields blocks it).
- `(animal: Animal) -> ()` correctly accepts a `Dog` argument
  (contravariance on function params is already implemented in
  `unify.lua:497–527`).
- A monomorphic function cannot masquerade as polymorphic in a rank-N slot
  (FLAG_SKOLEM rejection).

A3 is therefore an **expressiveness** problem: today the system is sound but
conservative. Users cannot write `ReadBox<+T>` (covariant read-only
container) or `WriteBox<-T>` (contravariant write-only sink) — every generic
is implicitly invariant, which rejects safe assignments like
`ReadBox<Dog> <: ReadBox<Animal>`.

## Design

Declaration-site variance, Scala/Kotlin-style. Syntax:

```
<+T>    -- covariant in T (T appears only in output positions)
<-T>    -- contravariant in T (T appears only in input positions)
<T>     -- invariant (default; T may appear anywhere)
```

Composes with bounds: `<+T: Number>` is "covariant T constrained to Number."

### Semantics

When checking `Container<A> <: Container<B>` for a generic `Container`:

- Each declared parameter has a variance: `+`, `-`, or invariant.
- For each position, recursively check the corresponding type arguments
  under the position's variance:
  - `+T`: check `A_T <: B_T` (covariant — narrower-on-the-left).
  - `-T`: check `B_T <: A_T` (contravariant — wider-on-the-left).
  - invariant: check both directions (status quo).

### Default

Invariant. Existing code is unaffected by this design.

### Why declaration-site (not use-site or inferred)

- **Use-site** (Java wildcards `Container<? extends T>`) is verbose and
  defers the decision; doesn't fit crescent's structural, definition-first
  style.
- **Inferred** (whole-program variance derivation) is unpredictable and
  expensive. Crescent's annotations are otherwise explicit and local;
  inferred variance would be the odd one out.
- **Declaration-site** is consistent with how bounds work today
  (`<T: Bound>`), modular (library author documents intent), deterministic,
  and has clean precedent (Scala, Kotlin, OCaml type abbreviations).

## Implementation sketch

Touch surface, in order:

1. **Annotation parser** (`lib/type/static/ann.lua`, around the forall parser
   at line ~875): recognize optional `+` or `-` prefix on each generic
   parameter name. Store the variance flag on the parameter (e.g., new slot
   on the ANN_FORALL node, or a parallel array). ~40–60 lines.

2. **Type representation**: variance flags must live on the type-level
   parameter so they survive instantiation. Likely a new field on the
   TAG_FORALL representation in `types.lua` (parallel array of variance
   bytes alongside `data` slots that already hold param name ids).
   ~20–40 lines.

3. **Subtype check modulation** (`lib/type/static/unify.lua` table-vs-table
   case around line 582): when both sides have the same generic head, look
   up declared variance per parameter and direct each recursive field check
   accordingly. Default to invariant if no variance is declared. ~80–120
   lines.

4. **Variance propagation through aliases / match types**: where match types
   or generic aliases destructure a type-with-variance, ensure the variance
   flows through correctly. ~40–80 lines.

5. **Error messages** (`lib/type/static/errors.lua`): when a variance check
   fails, emit a diagnostic naming the parameter, its declared variance, and
   the position that violated it. ~30–50 lines.

6. **Tests** in `lib/type/static/type_soundness_test.lua` and
   `type_test.lua`: positive (covariant assignment now allowed),
   negative (covariance in a write position rejected), interactions
   (variance + bounds, variance + rank-N, variance + match types).
   ~200–300 lines.

**Total estimate:** medium, 400–650 lines. Larger than A1.

## Variance-check pseudocode

```
-- subtype check when both heads are the same generic
function check_generic_sub(actual, expected):
    if actual.head ≠ expected.head: fail
    for i, param in expected.head.params:
        a_i = actual.args[i]
        b_i = expected.args[i]
        case param.variance:
            when '+':  check a_i <: b_i
            when '-':  check b_i <: a_i
            when invariant:  check a_i <: b_i AND b_i <: a_i
```

## Interactions

- **A1 (rank-N subsumption, landed):** Orthogonal. Rank-N already works
  without variance per the variance probe in `type_soundness_test.lua`.
- **A2 (HM Phase 2 field-value propagation):** Orthogonal. Different
  machinery.
- **B1 (HKT):** Direct interaction. A higher-kinded parameter
  `<F: SomeKind>` can itself be annotated for variance: `<+F: SomeKind>`
  means "F is a covariant constructor." When `F<T>` is instantiated, the
  variance of F should compose with the variance of T's position. Design
  the syntax so the composition is unambiguous from the start, even if HKT
  itself comes later.

## Open questions

1. **Variance inference for unannotated parameters.** TypeScript infers
   variance and allows explicit override. Should crescent do the same in a
   future pass, or stay explicit-only? Inference would help adoption but
   adds whole-program-ish complexity. Default position: explicit-only at
   first, revisit if usage demands it.
2. **Phantom-type variance.** A parameter that appears in *no* position
   (`Phantom<T>` where T is unused) is bivariant — both `+T` and `-T` are
   sound. Should this be inferred, rejected with a warning, or require
   explicit annotation? Stay explicit-only: phantom types are rare and the
   user should declare intent.
3. **Variance on row-polymorphic record extensions.** A type
   `{name: string, ..., +R}` — what's the variance of R? Row vars are
   intrinsically covariant (extension narrows the row's complement). Likely
   no syntax needed: row vars are implicitly covariant.

## Sequencing

Not blocking anything in the roadmap. Implement when expressiveness becomes
a felt limitation — typically when writing the first heavily-generic
library that wants `ReadOnlyMap`-style types. Until then, defer.

The roadmap update (commit `___`) demotes A3 from Phase A (soundness) to
its own bucket between A and B: "Phase A.5 — expressiveness, optional."
