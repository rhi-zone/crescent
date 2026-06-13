# Adversarial Critique: Prior-Art Gap Claim (Claim 2)

**Critic role:** adversarial prior-art skeptic — task was to FALSIFY the
four-property gap claim, not confirm it.
**Date:** 2026-06-14.
**Target:** `docs/typechecker-design-thesis.md` §5 / Claim 2, leaning on
`docs/artifacts/typechecker-run-2026-06-12/prior-art-modular-sound-gradual.md`.

The four properties under scrutiny:

- **(A)** fully sound over the covered domain + sound `⊤`/`unknown`-must-narrow
  for uncovered positions (NOT an unsound `any`/`dyn`).
- **(B)** independently-usable modular / pluggable analyses.
- **(C)** a real dynamically-typed, largely-unannotated language.
- **(D)** one de-special-cased value-set lattice + orthogonal judgement layers.

---

## Attack Vector 1 — Find the Occupant

I pushed beyond the original survey into the production-checker lineages it
under-examined (Typed Racket, Luau, Sorbet, Hack, TypeScript, pyright/mypy,
Flux/Rust) and the recent sound-gradual literature (2023–2026). New candidates,
with the exact property each lacks:

| Candidate | A (sound + sound-⊤) | B (modular) | C (dynamic, unannotated) | D (one de-spec lattice) | Verdict |
|---|---|---|---|---|---|
| **TypeScript (`unknown`)** | **NO** — `unknown` *is* a genuine sound top-must-narrow, but the system has `any` as a deliberate escape hatch and is explicitly non-sound; soundness "not a primary goal" | NO — single monolithic checker, no plugin analyses | Partial — JS is dynamic but TS code is *annotated by migration*; not the unannotated-corpus setting | NO — structural lattice but riddled with special cases (`any`, declaration merging, `this`-typing) | **Lacks B and D; A only half (sound-⊤ present, system unsound)** |
| **pyright strict (`Unknown`)** | **NO** — strict mode *reports* uses of `Unknown`/implicit-`Any`, but `Any` still conforms to the Python typing spec escape-hatch (assignable to/from anything); not sound | NO — monolithic | **YES** — Python, checks unannotated code by inference | NO — not a single de-special-cased lattice | **Lacks A (Any is unsound), B, D** |
| **Typed Racket (occurrence typing)** | Partial — sound *internally*, but the typed/untyped boundary recovers soundness via runtime contracts/blame (Siek–Taha lineage), not a static sound-⊤; untyped imports need annotation | NO — one migratory type system, not pluggable analyses | Partial — Racket is dynamic, but TR requires a typed *module* with annotations; untyped code isn't checked at all (it's trusted at the contract boundary) | Partial | **Lacks A (runtime-blame soundness, not static sound-⊤) and B** |
| **Luau (nonstrict)** | **NO** — nonstrict mode infers `any` when it can't resolve a type; `any` is unsound, the opposite of sound-⊤ | NO | **YES** — Lua, unannotated | Partial | **Lacks A decisively (uses unsound `any`), B** |
| **Sorbet (`T.untyped`)** | **NO** — "every value of type `T.untyped` can be asserted to be any other type"; unsound by construction | NO — monolithic | **YES** — Ruby, gradual adoption | NO | **Lacks A, B, D** |
| **Flux (Liquid types for Rust)** | Partial/YES — sound by a metatheorem ("well-typed programs don't get stuck"), and refinement layer is modular ("generic refinement types", modular specs) | Partial — modular *specifications*, but not independently-usable orthogonal analyses you can stop adding | **NO** — Rust is statically typed; not unannotated dynamic code | YES-ish — refinements enrich one base lattice | **Lacks C decisively (static language)** |
| **Granule / graded modal types** | NO — full type system, complete grade annotation required; no sound-⊤ for uncovered constructs | YES (for orthogonal axes via the semiring) | NO — new typed language | YES (for the orthogonal-layer half of D) | **Lacks A and C** (already in survey; re-confirmed) |
| **Cousot AI + reduced product / OPAL** | YES (theoretically) | YES (theoretically) | Partial — can analyze dynamic code, never *packaged* as a user-facing modular type system | YES (theoretically) | **Lacks C as a user-facing product** (survey's strongest theoretical near-miss; re-confirmed) |
| **Elixir set-theoretic (`dynamic()`)** | Partial — VM-sound, but `dynamic()` admits operations valid for *some* branch; bounded-any, not blocked-until-narrowed ⊤ | **NO** — monolithic | **YES** | **YES** | **Lacks B; A is bounded-any not sound-⊤** (survey's strongest real-language near-miss; re-confirmed) |

**No new candidate holds all four.** The production checkers the survey
under-examined (Luau, Sorbet, Hack, pyright, Typed Racket) all fail (A) in the
*same* way: their uncovered/unannotated position is an unsound `any`/`T.untyped`/
`dynamic` escape hatch, or soundness is recovered at a *runtime* boundary
(Typed Racket contracts) rather than by a static blocked-until-narrowed ⊤. None
is modular/pluggable (B). This is the survey's central finding, and the
production lineage does not overturn it — it reinforces it.

### The single strongest candidate occupant

**TypeScript with `unknown`.** It is the strongest because, unlike every other
production system, it ships a *genuine sound top-must-narrow type* — `unknown`
is assignable from everything, assignable to nothing but `unknown`/`any`, and
forces narrowing before use. That is property (A)'s mechanism, in production, on
a dynamic-ish language. **The exact property it lacks: (B) — modularity.**
TypeScript is a single monolithic checker with no independently-usable pluggable
analyses; you cannot "stop adding modules" or run the nullness analysis alone.
It *also* fails the system-level half of (A) (the `any` escape hatch keeps the
whole system unsound) and (D) (not a de-special-cased single lattice). But the
cleanest, least-arguable miss is (B): there is simply no plugin-analysis surface.

(Runner-up by a hair: **Elixir set-theoretic**, the survey's pick — same missing
(B), plus its `dynamic()` is bounded-any rather than sound-⊤.)

---

## Attack Vector 2 — Gerrymandering Check

The honest attack: is any property defined so narrowly that the gap is an
artifact of the definition rather than a real unexplored region?

### Property (A) — "sound ⊤ must-narrow, NOT unsound any/dyn"

**This is the property most at risk of gerrymandering, and it survives — but
only narrowly, and the thesis should concede the narrowness.**

The distinction "sound ⊤ that blocks until narrowed" vs "unsound `any`
compatible with everything" is *not* a crescent invention. It is textbook,
load-bearing gradual-typing theory: Siek himself states the dynamic type must
NOT be the top of the subtyping order, precisely because transitivity would
collapse the hierarchy; the consistency relation exists to keep `dynamic`
non-transitive. TypeScript codifies the same split in shipping form: `unknown`
(sound top, narrow-before-use) vs `any` (unsound escape hatch). So property (A),
read at the level of *the type constructor*, is **occupied and ordinary** — it
is not a novel or narrow region.

Where (A) stays non-gerrymandered is the *conjunction*: "use a sound-⊤ for
**uncovered language constructs** AND be sound over the whole covered domain."
Production systems that have the sound-⊤ constructor (TypeScript `unknown`,
pyright `Unknown`) do **not** use it for uncovered constructs — they reach for
the *unsound* sibling (`any`) there, and keep an `any` escape hatch that makes
the system unsound overall. So the region "sound-⊤ *as the uncovered-construct
fallback*, with no unsound escape hatch anywhere" is genuinely unoccupied among
production systems.

**Caveat the thesis must carry:** this is a thin definitional margin. A skeptic
can fairly say "TypeScript already has the sound-⊤; you are claiming novelty for
*where you route it*, not for the mechanism." That is a defensible but
*narrow* claim, and the thesis's existing "under-explored design point, not
novel" framing (§5) is the honest register. If the thesis ever hardens (A) into
"nobody has a sound ⊤" it becomes **false** (TypeScript/pyright have one). It is
only true as "nobody routes a sound ⊤ to uncovered constructs without also
shipping an unsound escape hatch." Recommend the thesis state (A) in exactly
that routed form to avoid the gerrymander.

### Property (D) — "de-special-cased single value-set lattice"

**Mild gerrymandering risk, defensible.** "De-special-cased" is a crescent house
term. A fair external reading: Elixir set-theoretic types and Liquid/refinement
types both *are* single enriched lattices and would, under a charitable reading,
satisfy (D) — and the survey grants them (D). So (D) is **not** drawn so
narrowly that it's unoccupiable; multiple systems satisfy it. The gap does not
rest on (D) being exotic. Good — that means (D) is not the load-bearing novelty,
which keeps the claim honest. The risk would only appear if "de-special-cased"
were read as "and no other system's lattice counts because theirs has a special
case somewhere" — a no-true-Scotsman move. The survey does not commit that move
(it awards D to Elixir, Liquid, Flix, Qualified Types, Cousot), so (D) is clean.

### Properties (B) and (C) — not gerrymandered

(B) "independently-usable modular analyses" is satisfied outright by Checker
Framework (28+ checkers), Bracha, graded types, Flix — it is a real, occupied,
well-understood region. (C) "real dynamic unannotated language" is occupied by
Elixir, Sorbet, Luau, pyright, Dialyzer. Neither is defined to be empty. The gap
is the *conjunction crossing these populated regions*, not any single empty
cell. This is the structurally honest form of a novelty claim: each property is
independently occupied; no system occupies the intersection.

---

## Verdict on Claim 2

**GAP REAL — but resting on a thin (A)-routing margin that the thesis must state
precisely.**

- No surveyed-or-new system holds all four. The production lineages the survey
  under-examined (Luau, Sorbet, Hack, pyright, Typed Racket) fail (A) and (B) in
  the same way the survey predicted, reinforcing rather than overturning it.
- **Strongest candidate: TypeScript with `unknown`.** Exact missing property:
  **(B) modularity** (no pluggable-analysis surface) — and it additionally fails
  system-level (A) (the `any` escape hatch) and (D).
- **Gerrymandering:** Property (A) is *at the margin* — the sound-⊤ vs unsound-any
  distinction is textbook and TypeScript/pyright already ship the sound-⊤
  constructor. (A) is non-gerrymandered ONLY when stated as "sound-⊤ routed to
  **uncovered constructs**, with no unsound escape hatch system-wide." Stated as
  the bare "nobody has a sound ⊤," it is false. Properties (B), (C), (D) are not
  gerrymandered; each is independently occupied, and the gap is their
  unoccupied intersection — the honest shape for a combination claim. The
  thesis's "under-explored, not novel, not proven-valuable" framing (§5) is the
  correct and defensible register; it should additionally pin (A) to its routed
  form.

---

## Sources

- Siek, "What is Gradual Typing" (dynamic must NOT be top of subtyping order; consistency relation): https://jsiek.github.io/home/WhatIsGradualTyping.html
- Wikipedia, Gradual typing (dynamic ≠ top; runtime checks for soundness): https://en.wikipedia.org/wiki/Gradual_typing
- TypeScript soundness ("soundness not a primary goal"; `any` escape hatch): https://www.typescriptlang.org/play/typescript/language/soundness.ts.html , https://francisngo.github.io/blog/understanding-typescript-unsoundness-and-caveats/
- TypeScript `unknown` as sound top-must-narrow (and why it doesn't make TS sound): https://marijnhaverbeke.nl/blog/unknown-type-variance.html , https://joshlehman.ca/blog/typescript-any-unknown-never-types/
- pyright strict mode reports `Unknown`/implicit-Any but conforms to Python `Any` escape-hatch semantics: https://github.com/microsoft/pyright/discussions/9611 , https://github.com/microsoft/pyright/issues/698
- Luau nonstrict infers unsound `any`: https://luau.org/typecheck , https://luau.org/types/
- Sorbet `T.untyped` "can be asserted to be any other type" (unsound): https://sorbet.org/docs/gradual
- Typed Racket / migratory typing — soundness via runtime contracts at boundary: https://www2.ccs.neu.edu/racket/pubs/typed-racket.pdf , https://nuprl.github.io/gtp/projects.html
- Flux: Liquid Types for Rust (sound metatheorem, modular specs; static language): https://ranjitjhala.github.io/static/flux-pldi23.pdf , https://dl.acm.org/doi/10.1145/3591283
- Elixir set-theoretic / `dynamic()` (bounded-any, monolithic): https://arxiv.org/abs/2306.06391 , https://arxiv.org/abs/2408.14345
- Cousot, Types as Abstract Interpretations (theoretical A+B+D, never user-facing for dynamic langs): https://www.di.ens.fr/~cousot/COUSOTpapers/POPL97.shtml
- Original survey: `docs/artifacts/typechecker-run-2026-06-12/prior-art-modular-sound-gradual.md`
