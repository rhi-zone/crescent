# Typechecker Design Thesis: Sound, Coverage-Gradual, Modular Typing

**Status: position / thesis — not a spec.** This document records *what the
crescent typechecker is, as a design position*, so the clarity reached in design
is durable. It is the durable home for the load-bearing claims; specs and
increments live elsewhere (`docs/agnostic-static-analysis-crescent-slice.md`,
`docs/decisions/kernel-recommendation.md`). It exists because this project has a
documented failure mode of decisions evaporating into transcripts — a prior
"HM-fit audit" was lost outright (confirmed absent from the tree;
`docs/decisions/kernel-recommendation.md` §4). This is the articulation that is
meant to survive that.

**Epistemic labelling.** Throughout, claims are marked **[measured]** (a number
from a recorded run), **[argued]** (reasoned from sources/design, not yet
adversarially stress-tested), or **[aspirational]** (a target, not yet built).
The position deliberately does **not** assert novelty or guaranteed value; see
§Prior-Art Positioning and §Claims Requiring Adversarial Verification.

---

## Thesis (one sentence)

The crescent typechecker is **gradual in semantic *coverage* but fully *sound* in
type-safety** — unhandled constructs receive a sound `unknown` (⊤, must-narrow-
before-use), never an unsound `any` — assembled as a single de-special-cased
value-set lattice plus a few orthogonal judgement layers, so that *each
error-class is caught soundly across the whole corpus* rather than each file
being fully checked.

---

## 1. Objective: per-property value, not whole-file coverage

The unit of value is **"error-class X is now caught soundly across the whole
codebase"**, not **"this file fully checks."** Each granularity — each construct,
each property — is independently useful: you can stop adding coverage at any
point and what is present is sound and useful.

This is not aspiration; it is **[measured]** already-true substrate behavior. The
slice checks everything it can reach in a file and records each result as a
separate claim in disjoint `accepted_claims` / `rejected_claims` /
`unknown_claims` sets; `OUT-OF-SUBSET` is a summary label, not a gate that
suppresses output. An out-of-subset file still produces checkable claims for its
in-subset parts, and those claims are individually reportable
(`docs/artifacts/typechecker-run-2026-06-12/partial-file-behavior.md`, Q2/Q4).

**Implication for the success metric.** The right metric is
**error-classes-caught-corpus-wide**, not whole-file `CLEAN%`. The whole-file
number is gated by a file's *last* out-of-subset construct and so understates
delivered value; the construct/claim histogram is the load-bearing signal. (This
is exactly why §4's cascade measurement is reconciled by the per-property frame
rather than contradicted by it.)

---

## 2. The distinguishing thesis: gradual in COVERAGE, sound in SAFETY

This is the axis that distinguishes the design.

- **Gradual in coverage:** the set of language constructs the checker understands
  grows incrementally. At any moment some constructs are uncovered.
- **Sound in safety:** over the covered domain there are no false negatives, and
  uncovered constructs do **not** open a soundness hole. An unhandled construct
  yields a *sound* `unknown` — ⊤, top of the lattice, which the caller must narrow
  before use — **never** an unsound `any`/`dyn` that is silently compatible with
  every type.

This is the **opposite axis** from Siek–Taha gradual typing, which is gradual in
*safety*: its `?`/`dyn` is consistency-compatible with every type (the
consistency relation is reflexive and symmetric but not transitive), which is by
design an *unsound* static judgement — soundness is recovered at runtime via
casts/blame **[argued, sourced]** (Siek & Taha, SFP 2006; AGT, Garcia–Clark–
Tanter, POPL 2016, both cited in
`docs/artifacts/typechecker-run-2026-06-12/prior-art-modular-sound-gradual.md`).
Our `unknown` is a *sound top type that blocks use until narrowed*, the precise
opposite of a compatible-with-everything escape hatch.

**Contrast with Elixir's `dynamic()` (sharpen the near-miss).** Elixir's
set-theoretic system is the closest existing work on the dynamic-language axis,
but its `dynamic()` is **not** a sound ⊤. Per the survey, `dynamic() and T`
admits operations valid for *some* branch — it does not block all uses until
narrowing — and the docs name `term` as top while `any`/`dynamic()` is the
unknown-*compatible* type. That makes `dynamic()` a **bounded-any**, closer to
Siek–Taha's `?` than to a blocked-until-narrowed sound ⊤ **[argued, sourced]**
(`prior-art-modular-sound-gradual.md` §11 and "Adversarial Verification of Key
Claims"; Castagna–Duboc, arXiv 2408.14345).

---

## 3. Decomposition: one value-set lattice + a few orthogonal judgement layers

Most "features" are **not separate passes**. They are enrichments of **one
value-set / subtyping lattice**: nil, unions, records, literals, recursion, and
refinements are all the same kind of thing under `{ <: }`. `| nil` is no
different from `| integer` — both are union members of the value lattice.

The discriminator is sharp:

> **Is the property a subset of the value universe, checkable by subtyping?**
> If **yes** → it is not a pass; it falls out of the one lattice.
> If **no** → it earns its own composable judgement layer — which must *itself*
> be de-special-cased (effects-as-rows, not per-effect flags).

Genuinely-non-value properties — **effects, linearity / usage, taint,
termination** — are the ones that earn a layer, because they are about *how* a
value is produced or used, not *which* values it can be. **[argued]**

This decomposition is grounded in the design as built:

- The v1 grammar is **derived whole from the Lua value universe** — a constructor
  is admitted iff it is needed to describe, or to discriminate between, values the
  universe can produce; nil/union/literal/record/μ/indexer all enter as lattice
  enrichments, not as passes
  (`docs/agnostic-static-analysis-crescent-slice.md` §1.1–§1.3).
- The ratified kernel routes the entire type algebra through **ONE** cycle-guarded
  equirecursive subtype function (`docs/decisions/kernel-recommendation.md` §3.3),
  with flow-narrowing as a *separate orthogonal layer* expressed as
  intersection-against that one relation (§3.5) — exactly the value-lattice /
  orthogonal-judgement split this thesis names.
- The non-value layers already have **structural** (not flag-based)
  representations in the existing material: effects are framed as **rows**
  (`docs/effects.md` — effect rows, row polymorphism, Koka lineage), and operator
  metamethods surface as structural deferral tags (`operator-metamethod-arith`/
  `-concat`/`-len`/…) rather than ad-hoc per-operator handling
  (`docs/agnostic-static-analysis-crescent-slice.md` §6.7.1). *(Note: the session
  artifact `grammar-map-effects-metamethods.md` named in the originating task does
  not exist in the tree or worktrees; the structural-representation claim is
  instead grounded in these committed sources, which support it.)*

---

## 4. Current keystone gap: totality

The lowering currently **chokes** at unsupported constructs: an unannotated
`local x = <out-of-subset expr>` leaves `x` *unbound* (absent from the typing
environment) rather than binding it to a sound ⊤. Every downstream use of `x`
then becomes its own `unbound-name:x` marker, and the gap cascades up the
expression tree (`partial-file-behavior.md` Q3).

The cascade is **[measured]** large: over 868 `lib/` files, **38.9% of all
out-of-subset markers (20,148 of 51,802)** are cascade victims — locally-declared
names abandoned because their RHS was out-of-subset
(`docs/artifacts/typechecker-run-2026-06-12/gap-cascade-magnitude.md` §1–§2). The
`bit` → `band`/`bxor`/`bor` chain is the textbook case: one abandoned
`require("bit")` poisons every downstream helper.

Making **unsupported → `unknown`** (a total, unknown-tolerant core) is the
precondition for the coverage-gradual / independently-useful granularities of §1
and §2: a sound ⊤ at the choke point stops the cascade and lets the in-subset
remainder of the expression keep producing checkable claims.

**Honest tension (do not smooth it over).** The cascade artifact's own verdict is
that this fix is **low-leverage on *whole-file* coverage** — only **3 of 808**
out-of-subset files would graduate to `CHECKED-CLEAN`, because 690 of them also
carry genuine root-construct gaps (`dynamic-index` at 5,061 occurrences,
`multi-assign`, `multi-return`, …) that the ⊤ fix does not touch — but
**high-leverage on totality / signal quality**: it cuts the marker histogram
nearly in half, making the remaining ~31,654 root-construct markers an honest
demand signal (`gap-cascade-magnitude.md` §3–§4).

**The two metrics disagree, and the per-property objective (§1) is what
reconciles them.** Under whole-file `CLEAN%`, totality looks like a +3-file
rounding error. Under error-classes-caught-corpus-wide, it is the enabling
substrate: it is what makes "this property is checked everywhere it appears" true
instead of "checked everywhere it appears *unless an earlier construct on the
line was uncovered*." The keystone claim is therefore that totality is
high-leverage **on the correct axis**, and this very disagreement is a flagged
item for adversarial verification (§Claims, claim 4).

---

## 5. Prior-art positioning (epistemics first)

The four-property combination —

- **(A)** sound ⊤ for uncovered positions + fully sound over the covered domain,
- **(B)** pluggable / modular, independently-usable analyses,
- **(C)** for a real dynamically-typed language with unannotated code,
- **(D)** a single de-special-cased value-set lattice,

— has **no clear single prior-art occupant** per the survey
(`prior-art-modular-sound-gradual.md`, verdict and summary table). The closest
near-misses each lack a *named* property **[argued, sourced]**:

| Work | Missing property |
|---|---|
| Elixir set-theoretic types | (B) monolithic, and (A) precisely (`dynamic()` is bounded-any, not blocked-until-narrowed ⊤) |
| Cousot abstract interpretation + reduced product | (C) as a *user-facing* modular type system for dynamic-language programmers — the theory is there (⊤ = sound unknown, reduced product = modular combination, analyses as lattice enrichments) but was never productized as one |
| Checker Framework | (A) unsound by default (unannotated code is *trusted*, not assigned ⊤), and (C) Java only |
| Dialyzer success typings | (A) the *opposite* trade — no false positives, but has false negatives (unsound) |

**Frame it correctly:** this is an **under-explored design point with proven
theoretical foundations (Cousot)** — **not "novel"** (the survey cannot prove
absence; a missing cell can mean nobody-managed *or* nobody-bothered, and we
cannot distinguish them) and **not "proven valuable"** (an empty cell is not
evidence that filling it pays off). The honest claim is: the foundations are
sound and ancient (abstract interpretation, 1977/1997), the combination appears
unoccupied as a user-facing system, and whether it is worth occupying is what the
build is testing. Sources: all listed in `prior-art-modular-sound-gradual.md`
"Sources (All Verified)" — Cousot POPL 1997; Castagna–Duboc 2024; Ernst et al.
ISSTA 2008; Lindahl–Sagonas PPDP 2006; Siek–Taha SFP 2006; Garcia–Clark–Tanter
POPL 2016.

---

## 6. The substrate already instantiates the instincts

The architecture is **already pointed at this design point**, not in need of a
redesign to reach it:

- **Claim/evidence fixpoint ≈ abstract interpretation.** The substrate's checking
  loop is a worklist fixpoint over the accepted set; `unknown` is the
  never-consumed-as-proof verdict that propagates soundly until an input claim
  settles (`docs/agnostic-static-analysis-object-model.md`; design doc §"fixpoint
  is a post-hoc witness"). This is the abstract-interpretation shape: ⊤ = sound
  unknown, fixpoint over a monotone lattice. **[argued]**
- **Hosted-semantics-on-substrate ≈ pluggable types.** Each semantics is a
  `SemanticsEntry` the substrate routes to but never interprets; the substrate
  "learns nothing" from any hosted predicate or method
  (`docs/agnostic-static-analysis-crescent-slice.md` §2, §2.6). Adding/removing a
  hosted semantics is exactly the pluggable-analysis move (Bracha 2004; OPAL),
  and four independent semantics already coexist on the one substrate
  (`prop.logic.min`, `lambda.untyped.min`, `dataflow.reach.min`, `stlc.min`).

So properties (A)/(B)/(D) are already expressible on the existing substrate; (C)
is what the Crescent slice is mechanizing rung by rung. The design point is
reachable from here by enrichment, not rebuild.

---

## Claims Requiring Adversarial Verification

The following load-bearing claims are **not yet stress-tested**. They are the
target list for the adversarial passes that follow. Each is stated to be
falsifiable.

1. **The value-set / judgement dichotomy partitions cleanly.** Claim 3 asserts
   every property is *either* a subset of the value universe checkable by
   subtyping (→ lattice enrichment, no pass) *or* a genuinely-orthogonal judgement
   (→ its own de-special-cased layer), with no third category and no property that
   straddles. *Falsifier:* a real Crescent property (e.g. mutable-field invariance,
   capability-reachability, or a metamethod-dependent operation) that is neither
   cleanly a value-subset *nor* cleanly an orthogonal layer — forcing a special
   case or a hybrid that the dichotomy does not name.

2. **The prior-art gap is real, not a missed occupant.** Claim 5 asserts no single
   system occupies (A)+(B)+(C)+(D). *Falsifier:* a system (surveyed or not) that in
   fact holds all four — or a demonstration that one of the four properties is
   defined so as to be trivially unoccupiable (making the "gap" an artifact of the
   definition rather than of the literature).

3. **`dynamic()` / `any` is genuinely distinct from our sound ⊤ in practice, not
   just on paper.** Claim 2 leans on `unknown`-blocks-until-narrowed being a real,
   enforced difference. *Falsifier:* a corpus pattern where our `unknown`
   propagation either (a) is forced to behave like a bounded-any to avoid
   unusable false positives, or (b) produces an unsound accept — i.e. the
   sound-⊤/unsound-any distinction collapses under real code.

4. **Totality is highest-leverage *on the correct axis*.** Claim 4 asserts the
   unbound→⊤ fix is the keystone, reconciling the measurement's low *whole-file*
   leverage against high *per-property* leverage. *Falsifier:* a measurement on
   the per-property metric showing totality delivers little error-classes-caught
   gain even there — or that a root-construct fix (`dynamic-index`, `multi-assign`)
   dominates totality on the per-property axis too, demoting totality from keystone
   to one-of-many.

5. **Soundness actually holds over the covered domain.** Pervasive but not
   exhaustively proven. *Falsifier:* any covered-domain construct that admits a
   false negative (a real type error the checker accepts) — which would break the
   "sound over the covered domain" half of the thesis, the more important half.

---

## See also

- `docs/static-analysis-map.md` — artifact authority and placement convention.
- `docs/agnostic-static-analysis-design.md` — the substrate entry point.
- `docs/decisions/kernel-recommendation.md` — the ratified kernel (bidirectional
  spine + one subtype relation).
- `docs/agnostic-static-analysis-crescent-slice.md` — the Crescent slice spec
  (`crescent.slice.v1`), §6 design and §9 design-pressure honesty.
- `docs/artifacts/typechecker-run-2026-06-12/` — the session artifacts this thesis
  is grounded in (prior-art survey, gap-cascade magnitude, partial-file behavior).
