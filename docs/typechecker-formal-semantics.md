# Typechecker Formal Semantics

Formal-semantics substrate for grounding the crescent typechecker's soundness:
version-parametric, cross-language, validated-semantics-first.

Status: decided design (2026-06-20). Phase 1 is buildable now in pure Lua;
phase 2 (mechanized proof) is a committed staged roadmap, not deferred
indefinitely. Reached via a design-it-twice with 4 decorrelated candidates and
3 adversarial judges (provenance below).

This document owns the soundness-grounding direction. It supersedes the
"Typechecker soundness methodology — open fork" thread in `TODO.md` and refines
the validation-option survey in `docs/typechecker-soundness-validation.md`
("Mechanized Kernel", "Proof-Producing Checker"). It is a positive direction; it
is not a re-adoption of the rejected `docs/typechecker-framework.md` (see
"Refutation of the prior-framework rejection").

## Motivation

The slice typechecker's soundness is established by adversarial testing — critic
agents imagining attacks. Testing shows the *presence* of bugs, never their
*absence*. A covariant-field write-through variance unsoundness
(`docs/agnostic-static-analysis-crescent-slice.md` §6.14) survived **5**
feature-audit rounds before a 6th adversarial pass caught it; an embedded-alias
sub-hole surfaced only because someone happened to imagine that exact case. The
methodology — not any single bug — is the weak link.

Decision: ground soundness in an **executable formal Lua semantics validated
against reality**, with mechanized proof staged behind it. The semantics is the
independent oracle the Lua-only checker cannot provide for itself.

## Decided architecture

"Primitive-decomposed executable semantics in Lua, value-algebra-parametric,
proof-host deferred."

### 1. Phase-1 substrate (now, pure Lua, no proof assistant)

An executable **small-step operational semantics** in pure Lua. Bare-clone-real:
runs on the vendored LuaJIT with no external installs, and reuses
`lib/test/{arb,prop,fuzz}`. It is structured as a reduction over a small set of
**primitives**, with **faults-as-stuck-primitives** — a runtime fault is a
primitive with no reduction rule, i.e. a *stuck* term.

This structure is the point, not an aesthetic choice: soundness **decomposes into
per-primitive progress lemmas**. That decomposition is what makes the variance
class *provable* later (phase 2) rather than only *searchable* (phase 1).

The **value representation is parametric from day one**. This is forced, not
speculative: the Lua 5.3 integer/float split means a fixed value type is dead on
arrival. Only a parametric value algebra can carry `math.type`, the typing of
`//` (floor division), and bitops-on-float erroring — and carry them
*differently across versions*. A monomorphic value type would have to be torn out
the moment S2 wires the second version.

### 2. Two separate differential loops

This separation is the key correction over the naive "differential-test the
checker against a reference interpreter" idea.

- **Loop α (spec ⟷ real interpreters)** validates that our executable semantics
  is **faithful to real Lua**, per version. Oracles: flake-provided PUC Lua
  5.1 / 5.2 / 5.3 / 5.4 plus the vendored LuaJIT 5.1. Undefined behavior and
  nondeterminism are handled by an **admissible-set** result; where versions or
  UB disagree, **stuck-as-unknown is correct** — the spec is allowed to decline
  to commit.

- **Loop β (checker ⟷ our spec)** is the soundness property
  `checker accepts ⟹ ¬fault`, run against our **deterministic** spec — where a
  fault is *unambiguously* a fault — **not** against the noisy real interpreters.
  This is where the variance hunt lives.

  Running β against the real interpreters (as one rejected candidate proposed)
  would **launder the variance signal into stuck**: a real interpreter on one
  version might not fault on the exact aliasing input, so the disagreement gets
  absorbed as admissible/UB instead of flagged as an accepted-yet-faulting
  program. We therefore **do not** run β against real interpreters.

### 3. The Profile: version and language are the same parameter

A **Profile** is `(desugar, value-algebra, enabled-rule-set, typing-delta)`.
Version and language are the **same parameter type**. A version delta is
**data** — more value-kinds, more enabled primitive rules, more desugar branches
— **not a branch in trusted code**. The trusted reducer is fixed; profiles
configure it.

First-class version-parametricity is the **novel contribution**: prior art has
none (see "Prior-art grounding").

### 4. Phase-2 (staged; committed roadmap, not deferred-indefinitely)

Choose the proof host (tentatively **Lean 4**, for dual-use: the executable
`step?` is both the differential oracle and the proof subject) **only once the
real primitive set has been forced by building phase 1**. Then prove
per-primitive **progress + preservation** lemmas, turning the variance class from
findable-by-search into a **universal**.

Deferring the host choice is **on purpose**: it is the literal refutation of
"premature shape commitment" — the shape is committed only after real semantics
force the primitive set, not before.

### 5. Phase-1 honesty: industrialize the search

Phase 1 is still search, so industrialize it. Use **structure-aware generators**
that *deliberately construct aliases* and **coverage-guided fuzzing** aimed at
the variance shape — **not uniform random**, which would miss the measure-zero
aliasing bug exactly as the human auditors did. Phase 1 is strictly better than
blind audit **and** is the non-throwaway substrate the phase-2 proof attaches to
(the executable `step?` becomes the proof subject).

### 6. Cross-language bar (honest, falsifiable)

The mandated second language must be **genuinely different**: a small
λ-calculus with **sum types** and **static arities** — features that break
Lua-shaped cheats. The bar is "**slots in as a Profile without editing the core
value-algebra or primitive mechanism**." That is a real falsification test, not a
rigged reuse percentage. If the second language forces a core edit, the
value-algebra/primitive factoring was wrong and must be redone.

## Refutation of the prior-framework rejection

The framework (`docs/typechecker-framework.md`,
`docs/typechecker-framework-postmortem.md`) was rejected on judgment as
*premature theory-specific commitment to a shape* (theory / evidence-DAG /
binder-replay) that was *more general without earning its keep*. This direction
must show, on substance, why it is not the same mistake.

1. **More-general ≠ right — generality here is forced, and earns its keep.**
   The generality (parametric value algebra) is **forced by the real version
   matrix**: the int/float bomb makes a monomorphic value type dead on arrival.
   And it earns its keep on the **existing checker's** soundness — it is the
   independent oracle that grounds the slice we already have, not generality for
   a hypothetical future client.

2. **Premature shape commitment — the shape is deferred until reality forces
   it.** The proof host and proof shape are **deferred until the real semantics
   force the primitive set** (phase 2 after phase 1). Phase 1's own shape is not
   invented; it is **forced by matching real Lua** under Loop α.

3. **Multi-language bar — a genuinely-different falsifier.** The prior framework
   only ever *validated* STLC (and planned, never ran, the other theories). The
   bar here is a genuinely-different second language (sum types, static arities)
   as a **real falsifier** of the core factoring.

4. **Value over Lua-only.** This produces a **day-one independent soundness
   oracle** that a Lua-only checker cannot self-provide. The framework's
   generality bought no such oracle for the running checker.

5. **No inherited terminology.** New vocabulary — **primitives, profiles,
   faults-as-stuck** — not theory / evidence-DAG / binder-replay. Per the map's
   rule (`docs/static-analysis-map.md`), the agnostic/positive directions must
   not inherit the framework's representation or terms by default; this one does
   not.

### Carry-forward findings (preserved)

The framework's substrate-independent findings
(`docs/typechecker-framework-postmortem.md`, "Lessons Carried Forward") are
preserved here:

- **Source names ≠ binder identity.** Source labels are never semantic identity.
- **Capture-avoidance is checkable**, not assumed.
- **Alpha-stable identity.** Alpha-equivalent terms have stable identity/digests.
- **Trust discipline.** Only the **checker** and the **declarative semantics**
  are trusted. The **real interpreters and the desugarings are untrusted
  oracle/evidence producers** — Loop α validates the spec *against* them but does
  not trust them; Loop β trusts the spec, not the interpreters. This is the
  single most important discipline to keep: losing it is how ad-hoc accumulation
  re-enters.

## Staging

Each increment is independently useful.

- **S1 — primitive-decomposed semantics for the core fragment.** Scalars,
  literals, structural tables (records/indexers, open/closed rows,
  optional/readonly fields), functions (multi-return + vararg), union /
  intersection, equirecursive μ. **No** metatables, coroutines, FFI, or
  full-stdlib. Plus the Loop-α harness vs the **vendored LuaJIT only**.
  Immediately a spec-oracle. This is the v1 subset of
  `docs/agnostic-static-analysis-crescent-slice.md`.

- **S2 — versions + Profiles.** Wire PUC 5.1–5.4 via the flake; introduce
  Profiles and version deltas, **starting with the 5.3 int/float split** as the
  proving case for the parametric value algebra. Loop α across all versions.

- **S3 — Loop-β soundness property.** `checker accepts ⟹ ¬fault` against the
  spec, with **structure-aware alias-targeting generators**. Acceptance test:
  **re-derive the known variance unsoundness as a shrunk counterexample**.

- **S4 — second language.** A λ-calculus with sum types + static arities as a
  Profile. Clears the cross-language bar (no core edit).

- **S5 (phase 2) — mechanized proof.** Choose the proof host (tentatively Lean
  4); prove per-primitive progress + preservation lemmas, feature-by-feature.

## Design-it-twice provenance

Reached via a design-it-twice. Four decorrelated candidate framings:

1. **minimize** — smallest thing that grounds soundness.
2. **max-proof-rigor** — mechanized proof first.
3. **primitive-kernel** — decompose into primitives, prove per-primitive.
4. **invert-oracles** — differential-test the checker against real interpreters.

Three adversarial judges, on: (a) soundness-power; (b) version +
cross-language; (c) crescent-fit + rejection-survival.

**Root disagreement the judges surfaced:** testing-vs-proof, and
commit-vs-defer on generality. **Synthesis resolution:** *phasing* (phase 1
executable-semantics search now; phase 2 mechanized proof once the primitive set
is forced) plus the **two-loop separation** (α validates the spec against
reality; β hunts soundness against the deterministic spec). The two-loop split is
what stops candidate 4 (invert-oracles) from laundering the variance signal into
stuck.

## Prior-art grounding

- The **only** mechanized Lua semantics is Soldevila et al.'s **PLT Redex** model
  — Lua **5.2**, **single-version-locked**, GPL-3.0 GC variant. **No LuaJIT 5.1
  formalization exists.**
- **JSCert** is the methodological exemplar: a "trusted/validated mechanised
  specification" — a Coq spec plus an *extracted interpreter proven correct*,
  *differentially tested* against test262. This validated-semantics-first pattern
  is exactly the one adopted here (Loop α = the differential validation).
- **QuickChick** is the Coq tool for "derive certified generators and prove they
  generate the same relation" — the phase-2 generator-certification analogue.
- **Version-parametricity is first-class NOWHERE** in prior art. Confirmed across
  K, Ott + Lem, Redex, Skel/Necro, Cerberus, and WebAssembly SpecTec. This is the
  novel contribution.

## Cross-references

- `docs/agnostic-static-analysis-crescent-slice.md` §6.14 — the variance closure
  whose survival-through-5-rounds motivates this direction; v1 subset (S1 scope).
- `docs/typechecker-design-thesis.md` — "fully sound is a HARD invariant" stance.
- `docs/typechecker-soundness-validation.md` — the prior validation-option survey
  this refines (Mechanized Kernel / Proof-Producing Checker).
- `docs/soundness-audit.md` — the adversarial-audit method this grounds.
- `docs/typechecker-framework.md`, `docs/typechecker-framework-postmortem.md` —
  the rejected prior framework refuted above on substance.
- `docs/static-analysis-map.md` — artifact authority; the no-inherited-shape rule.
- `lib/test/{arb,prop,fuzz}` — reused by the phase-1 harness.
