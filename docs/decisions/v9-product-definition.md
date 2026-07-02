# Decision: v9 product definition — strict discipline enforcer, total semantics / bounded dynamism, owner-held power dial

**Status:** resolved — July 2026 (owner rulings, recorded verbatim in spirit).
**Purpose:** the durable identity card for v9. Future sessions read this before
planning any v9 feature. It complements `v9-versions-survey.md` (what to mine)
by fixing **what the product is**.

---

## Identity: NOT a typechecker in the permissive-inference sense

v9 is a **strict static discipline enforcer**. Owner: "we aren't trying to be a
typechecker, we're trying to be way, way stricter."

Permissive inference — the MLsub/TypeScript-style stance of "find *some* type
that makes it sound" — is the **inverted philosophy**: it stretches the type
language until almost everything checks. v9 does the opposite. **If code
requires an exotic type to check, that is a signal the code is too dynamic, and
the checker ERRORS.**

Inference exists for **propagation** (so users don't write annotations), never
for **absolution** (stretching the type language to bless dubious code).

---

## Coverage: total on semantics, bounded on dynamism

Owner: "we should support all semantics, just not all levels of dynamism
because at some point that requires e.g. a halting oracle / may be uncomputable
in general."

- The supported subset is **NOT a subset of syntax/constructs**. Every Lua
  construct — metatables, varargs, multiple returns, `and`/`or`, mutation, the
  lot — must be handled. The proof-dev already walked this axis
  construct-by-construct (29 increments, `docs/proof-kernel.md`).
- It **IS a subset of dynamism**. Each construct is checkable at
  statically-decidable usage levels; beyond that boundary the checker errors
  honestly.
- **Errors at the dynamism boundary are the product working as intended, not
  gaps.** A "gap" report about code the discipline rejects is a
  misclassification.

---

## The power dial is the owner's, and it's first-class

Owner: "how powerful exactly, we (well ideally *i*) get to decide."

Consequence: the strictness policy — **which dynamism levels are admitted per
construct** — must be an explicit, enumerable, owner-decidable surface: a
policy seam with named rules. It must never be implicit in scattered
implementation choices. If a strictness decision can only be located by reading
solver internals, the seam is missing.

---

## Compactness is a smell test, not a budget

The owner floated "≤3000 lines for the checker" then explicitly retracted it as
a hard limit ("a number i pulled out of my ass; using it as a hard limit is
frankly myopic").

The durable content: **uniformity keeps the core small**, and disproportionate
line-growth when adding a feature is the **early alarm for ad-hoc creep**.
Watch growth-per-feature; don't engineer to a magic number.

---

## Uniformity requirement (the anti-ad-hoc core)

The documented killer of the 8 prior typechecker iterations was per-construct
bespoke inference logic (`docs/typechecker-ad-hoc-inventory.md`: 105+ ad-hoc
instances; e.g. the `foo and bar → boolean|nil` hardcoded-`nil` bug).

The requirement:

- **ONE constraint/transfer discipline.** Every construct participates via the
  same rule shape.
- **No per-construct special-case branches** in the solver/engine. (This is
  the code-level form of the repo-wide no-special-casing hard constraint.)
- **MLsub / Simple-sub (Dolan, Parreaux) is PRIOR ART to mine for machinery**
  — uniform constraint generation, type variables as lattice cells (which the
  validated v9 engine already embodies: commits `37894772` / `f16005d6`),
  biunification / polar types — while **REJECTING its maximal-permissiveness
  acceptance philosophy** per the Identity section above. Mine the mechanism,
  not the stance.

---

## Relation to the proof-dev (`proof/*.v`)

The owner's corrected ontology — this was mis-stated repeatedly and matters:

- The proof-dev is a correct, reality-validated **EXECUTION MODEL of LuaJIT**.
  It buys correctness of the execution model, **and nothing of inference**. It
  does not make inference sound, principled, or non-ad-hoc.
- Its role for v9: the **reference catalogue of what every construct DOES**,
  from which each construct's static discipline — and the dynamism boundary —
  is derived. Total-semantics coverage is the axis it already walked
  construct-by-construct (increments 1–29, `docs/proof-kernel.md`).
- **Inference quality is a separate, engineering problem**, solved by the
  uniformity requirement above — not by the proof-dev.

---

## Substrate

The validated v9 engine — domain-generic monotone fixpoint over lattice cells,
`lib/type/v9/engine/` (commits `37894772`, `f16005d6`: engine + three
pressure-test domains on one engine) — is the **solving substrate**. Strictness
policies and the type domain are **domains/rules over it**, not modifications
to it.

---

## Anti-goals

- **No maximal-permissiveness inference.** Never stretch the type language so
  code checks; error instead.
- **No per-construct special-casing** in the solver/engine — one rule shape
  for everything.
- **No silent passes on unsupported dynamism.** Beyond the decidable boundary
  the checker always errors; it never guesses, defers silently, or degrades to
  acceptance.
- **No halting-oracle territory.** No whole-program dynamism analysis built to
  bless dynamic code; that boundary is where the product errors by design.
