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

**Adversarial-review status (2026-06-14).** This thesis has now been through one
round of execution-led adversarial review (three critics, artifacts under
`docs/artifacts/typechecker-run-2026-06-12/critique-*.md`). The verdict: the
thesis **survives as a *direction*** — the core stance (coverage-gradual, sound
over the covered domain, sound-⊤ for the uncovered) is intact and the prior-art
gap is real — but two of its load-bearing claims were **falsified** and two were
**partially** sustained, driving the corrections folded in below. The honest
summary: a sound direction whose one **soundness defect** (mutable-field covariant
write-through; §4b) is now **CLOSED (2026-06-14)**, plus one named category the
original dichotomy missed (variance/identity). It is neither vindicated
wholesale nor refuted; it is refined. The per-claim outcomes are recorded in
§Claims Requiring Adversarial Verification (now annotated with results).

---

## Thesis (one sentence)

The crescent typechecker is **gradual in semantic *coverage* but aims to be fully
*sound* in type-safety** — unhandled constructs receive a sound `unknown` (⊤,
must-narrow-before-use), never an unsound `any` — assembled as a single
de-special-cased value-set lattice, plus *variance/identity facts threaded through
that one subtype relation*, plus a few orthogonal judgement layers, so that *each
error-class is caught soundly across the whole corpus* rather than each file being
fully checked.

*(Revised post-review: "fully sound" → "aims to be fully sound" while the
mutable-field covariant write-through defect (§4b) was open; that defect is now
**CLOSED (2026-06-14)**, so soundness over the covered domain holds. The
decomposition is three categories, not two, the variance/identity clause being the
correction the original sentence lacked.)*

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

**The near-miss that forces precision: TypeScript's `unknown`.** The prior-art
critic (claim 2) confirmed the gap is real but showed it rests on a **thin
margin**, because the sound-⊤ mechanism is *not* a crescent invention.
TypeScript's `unknown` is a genuine **production sound-⊤**: assignable from
everything, assignable to nothing but `unknown`/`any`, must be narrowed before
use. So the bare statement "nobody has a sound ⊤" is **false** — TypeScript and
pyright ship the constructor. The non-gerrymandered claim is narrower and must be
stated exactly:

> The unoccupied region is a sound ⊤ **routed to uncovered constructs, with no
> unsound escape hatch anywhere in the system.**

TypeScript has the sound-⊤ constructor but does **not** route it to uncovered
positions (it reaches for the *unsound* `any` there) and keeps an `any` escape
hatch that makes the whole system unsound. That routing-plus-no-escape-hatch
conjunction is what stays unoccupied — not the ⊤ mechanism itself. This keeps the
"under-explored, not novel" register honest: novelty is claimed for *where the
sound-⊤ is routed and what is absent system-wide*, not for the ⊤ itself (which is
textbook gradual-typing theory: Siek — the dynamic type must not be the top of
the subtyping order; consistency keeps it non-transitive). **[argued, sourced]**
(`critique-priorart.md`; Siek "What is Gradual Typing".)

---

## 3. Decomposition: three categories (value-set, variance/identity, orthogonal layers)

Most "features" are **not separate passes**. Many are enrichments of **one
value-set / subtyping lattice**: nil, unions, records, literals, recursion, and
refinements are all the same kind of thing under `{ <: }`. `| nil` is no
different from `| integer` — both are union members of the value lattice.

**The original dichotomy was wrong — there are three categories, not two.** This
thesis first asserted a clean two-way split (value-subset → no pass; otherwise →
orthogonal layer). The soundness critic falsified it (claim 1) by driving
mutable-field variance through the real substrate, and the falsification holds:
the correct decomposition has **three** categories.

1. **Value-set properties — fall out of the one lattice.** A property that is a
   subset of the value universe, checkable by subtyping: nil, unions, records,
   literals, recursion, refinements. Not a pass; an enrichment of the one `<:`
   relation.

2. **Variance & identity (mutability) — intrinsic to *how subtyping treats
   mutable structure*.** This is the category the dichotomy denied. It is
   **neither** a value-subset fact **nor** a separable judgement layer. The
   decisive case is **mutable-field variance**. By the value-set membership test,
   `{ f: integer } <: { f: number }` is correct (the values inhabiting the former
   *are* a subset) — and the lattice's covariant `_rec_sub` computes exactly that.
   But that answer is *unsound for a mutable field*: read-set inclusion holds,
   write-safety does not (you can write a `number` through the widened alias into
   an `integer` field — see §"Known soundness defect"). The principled fix the
   slice spec itself prescribes (§3.2, §9.2) lives **inside the one subtype
   relation** — split readonly fields (covariant) from mutable fields (invariant)
   in the depth rule of `_rec_sub`, keyed on a per-field mutability bit. That is
   not an orthogonal layer beside `<:`, and it is not a value-subset; it is a
   **variance annotation on a structural constructor**, threaded *through* `<:`.
   The vestigial `readonly` slot in `slice_ty.lua` (parsed but hardcoded `false`,
   never set true — audit round 5 F3) is the design's own admission of this
   category: it exists because the clean dichotomy had nowhere else to put it.
   **Object identity / aliasing** corroborates (the checker cannot distinguish two
   structurally-equal records by `==`, because identity is not a value-set
   property and has no layer) — but mutability is the decisive instance, because
   its prescribed fix lands inside the subtype relation rather than beside it.
   **[falsified-then-corrected; soundness critic claim 1]**

3. **Orthogonal judgement layers — earn their own de-special-cased layer.**
   Genuinely-non-value properties — **effects, linearity / usage, taint,
   termination** — are about *how* a value is produced or used, not *which* values
   it can be, nor how `<:` treats mutable structure. They compose as separate
   row/usage judgements that do not touch the subtype relation. Each must *itself*
   be de-special-cased (effects-as-rows, not per-effect flags). **[argued]**

The old discriminator ("is it a value-subset, yes/no?") is therefore necessary
but not sufficient: it correctly separates category 1 from category 3, but it has
no correct answer for category 2 — *yes* by value-set membership (and that yes is
unsound), *no* by write-safety (and that no is not an orthogonal layer). Variance
is the intrinsic third thing, sitting inside the lattice's subtype rule yet not
being a value-subset fact.

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

## 4. Current gap: totality (a precondition, not the keystone)

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
line was uncovered*."

**"Keystone" was an overclaim — corrected (claim 4 PARTIAL).** The leverage
critic measured the per-property axis directly with `per_property_metric.lua`
over the `lib/` corpus and the keystone framing does not survive intact. Baseline
**Sound-Verdict (SV) sites = 83,226** (82,371 accepted + 373 rejected + 482
unknown), against 51,848 abandoned out-of-subset markers — **61.6% SV coverage of
all potential sites**. On that axis:

- **Totality recovers +10,058 SV conservatively (+12.1%)** — which **beats any
  *single* root construct** (`dynamic-index` alone is +6,719 / +8.1%). On
  "beats the top single root construct," totality holds.
- But the **top-4 root constructs combined recover +13,464 SV (+16.2%)** —
  `dynamic-index` + `multi-assign` + `multi-return` + `expr` — which **exceeds**
  totality's conservative gain and dominates it on the per-property axis.
- And **~half of totality's headline gain is contingent on stdlib fixes**: its
  upper bound (+20,170 / +24.2%, the "cuts the histogram nearly in half" figure)
  requires also modeling `require`/`ffi`/`coroutine`, because ~10,112 of the
  20,170 cascade markers are rooted in unbound-name gaps the unbound→⊤ patch does
  not touch. Totality *alone* delivers [+10,058, +20,170], realistically near the
  floor.

**Reframed honestly.** Totality and root-construct coverage are **complementary,
and "keystone" is dropped.** Totality is the **thesis-defining *semantic*
precondition**: it is what makes the sound-⊤ of §2 *real at the choke point* —
without unbound→⊤, an uncovered RHS abandons its local entirely (not even a ⊤),
so "sound over the covered domain, ⊤ for the uncovered" is not yet literally true
inside a single expression. Root-construct coverage is the **larger near-term
coverage lever** on the SV metric. They do not compete for a single keystone slot;
the semantic precondition and the coverage lever are different jobs.
(`critique-leverage.md`; `per_property_metric.lua`; `gap-cascade-magnitude.md`
§3–§4, whose own "fix substrate gaps first, totality for signal quality"
recommendation the critic found more accurate than the keystone framing.)

---

## 4b. Closed soundness defect — covariant write-through (FIXED 2026-06-14)

> **Status: FIXED (2026-06-14, increment v2.10).** Soundness is a HARD invariant;
> this defect — which falsified the original claim 5 ("soundness holds over the
> covered domain") — is now **closed** by the validated design of
> `docs/agnostic-static-analysis-crescent-slice.md` §6.14: check-mode construction
> (`check_table_expr` + the `check_table` evidence method) plus invariant
> mutable-field subtyping in `_rec_sub` and the indexer rules. The two bug repros
> (`FN_widen_alias_write`, `FN_widen_alias_write_numvar`) now **REJECT** as permanent
> regression tests (`corpus_lower_test.lua`, "§6.14 soundness: …"), the 5 sound
> construction fixtures stay CLEAN, and the full `lib/type/analysis/` suite is green.
> The honest statement is now "sound over the covered domain, including
> mutable-field variance." The text below records the defect that was closed.

**The defect (CLOSED): covariant field write-through.** A `number` could be written
into an `integer` field through a widened alias, accepted CLEAN. The repro
(`crescent_slice_lower.lower → A.check`) now produces `FINDINGS` / `type-mismatch`
at the alias-widen site (`IntBox </: NumBox` under invariant mutable depth):

```lua
--:: IntBox = { f: integer }
--:: NumBox = { f: number }
--: (IntBox, number) -> integer
local function corrupt(ib, x)
  --: NumBox
  local nb = ib       -- IntBox <: NumBox accepted (covariant field) — CLEAN
  nb.f = x            -- x:number written into ib's integer field — accepted
  return ib.f         -- read back as integer; at runtime may be 1.5
end
```

Pre-fix this observed `expected=CLEAN acc=3 rej=0 unk=0`, zero markers. Two controls
pinned it as a genuine covariant-accept, not noise: a **direct** `b.f = x`
(`x:number`, `b.f:integer`) was correctly **REJECTED** (`type-mismatch`); and the
widen step with **no write** was CLEAN. The false negative was precisely (covariant
widen) ∘ (write through the wider view) — two steps each sound in isolation composing
into an unsound whole. Post-fix the widen step itself rejects (the controls still
behave: direct bad write rejected, annotated-local enforced, fresh construction CLEAN).

**Root cause (closed).** `lib/type/analysis/slice_subtype.lua` `_rec_sub` compared
field types **covariantly and unconditionally** (no readonly/mutable discriminator).
The fix makes the **mutable** depth rule INVARIANT (`af.ty` and `bf.ty` mutually `<:`)
across rec / indexer / rec_with_indexer and `_indexer_obligation`; the `readonly` slot
(parsed-but-hardcoded-`false` in v1, so every field invariant) stays covariant when
later inferred/annotated — the deferred-precision layer (§6.14.5).

**Shared root with claim 1.** This is the same fact as category 2 of §3
(variance/identity): the value-set lattice is correct *for reads* and the wrong
tool *for writes through a mutable reference*. The defect and the falsified
dichotomy are one underlying gap.

**The fix is LANDED (slice §6.14, increment v2.10).** The blanket-invariant answer
alone was implemented and **reverted** — it broke 5 of ~13 in-subset fixtures, all
sound record-*construction*
(`docs/artifacts/typechecker-run-2026-06-12/variance-fix-cost.md`). The landed closure
decouples the two operations invariance conflated:

- **Construction** (`local t: T = { … }`, `return { … }`, `f({ … })`) — the value is
  fresh, single-reference, so covariant per-field checking is **sound**. Route it to
  **CHECK mode** (`check_table_expr`, the table-node analogue of the existing
  `check_func_expr`), keyed on the syntactic `table`-node form.
- **Aliasing / all other record flow** — two references at different types to one
  table, so a mutable field must be **invariant** in `_rec_sub` (`af.ty` and `bf.ty`
  mutually `<:`); readonly fields stay covariant.

The soundness argument (slice §6.14.4): the widen step that created the defect is now
invariant whenever the field is writable, and construction never produces a widened
alias — so the (covariant widen) ∘ (write-through) composition cannot form. This is
**not special-casing**: the discriminator is the structural construction/elimination
split the bidirectional spine already encodes (node-kind, not type-name).

The **residual** is a sound *alias-and-read* (widen a mutable record to a supertype,
only read it) that the invariant rule now rejects conservatively. Measured **rare**
(no corpus fixture exhibits it; the blanket-invariant corpus delta was −1, itself a
construction regression this design removes). **Verdict: defer `readonly`** — it is a
pure precision-recovery layer for a pattern the corpus does not contain; the soundness
closure does not depend on it.

What is fixed: **this must-fix soundness bug is CLOSED, and the §9.2 "unreachable in
v1 syntax" fence is disproven** (see the corrected slice doc §9.2 and the landed
closure in §6.14). The bug repros are permanent regression tests; the construction
fixtures and full analysis suite remain green.

---

## 5. Prior-art positioning (epistemics first)

The four-property combination —

- **(A)** a sound ⊤ **routed to uncovered constructs, with no unsound escape hatch
  system-wide** (stated in this precise form — *not* "nobody has a sound ⊤";
  TypeScript's `unknown` is a production sound-⊤, so the bare form is false), plus
  soundness over the covered domain **[the §4b covariant-write-through defect is now
  FIXED (2026-06-14); soundness over the covered domain holds, with `readonly`
  precision recovery the only deferred piece]**,
- **(B)** pluggable / modular, independently-usable analyses,
- **(C)** for a real dynamically-typed language with unannotated code,
- **(D)** a single de-special-cased value-set lattice,

— has **no clear single prior-art occupant** per the survey
(`prior-art-modular-sound-gradual.md`, verdict and summary table) — a verdict the
prior-art critic re-confirmed against the production lineages the survey
under-examined (Luau, Sorbet, Hack, pyright, Typed Racket all fail (A)+(B) the
same way; `critique-priorart.md`). The gap is the **unoccupied intersection** of
four independently-occupied regions, not any single empty cell. The closest
near-misses each lack a *named* property **[argued, sourced]**:

| Work | Missing property |
|---|---|
| **TypeScript (`unknown`)** | (B) monolithic, no plugin-analysis surface (the cleanest miss); and the system-level half of (A) — it *has* the sound-⊤ constructor but does not route it to uncovered constructs and keeps an unsound `any` escape hatch. The strongest single candidate, which is why (A) must be stated in its routed form. |
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

## Claims Requiring Adversarial Verification — RESULTS (round 1, 2026-06-14)

These five load-bearing claims have now been through one execution-led adversarial
round. Each is annotated with its **verdict** and the artifact that established it.
Summary: **2 FALSIFIED, 2 PARTIAL, 1 SURVIVED.** The falsifications and partials
drove the §2/§3/§4/§4b corrections above.

1. **The value-set / judgement dichotomy partitions cleanly — FALSIFIED.** The
   original claim: every property is *either* a value-subset (→ lattice enrichment)
   *or* a genuinely-orthogonal judgement (→ its own layer), with no third category.
   **Falsified** by `critique-soundness.md`: **mutable-field variance is a third
   category** — it lives *inside* the subtype relation yet is not a value-subset
   fact, and its prescribed fix is a per-field variance hybrid the clean dichotomy
   cannot name (the vestigial `readonly` slot is the design's own admission). §3 is
   rewritten to three categories (value-set / variance & identity / orthogonal).

2. **The prior-art gap is real, not a missed occupant — SURVIVED (tightened).**
   No surveyed-or-new system holds (A)+(B)+(C)+(D); the production lineages the
   survey under-examined reinforce rather than overturn the verdict
   (`critique-priorart.md`). **Tightening forced:** the strongest candidate is
   **TypeScript `unknown`** (a real production sound-⊤), so (A) must be stated as
   "sound ⊤ *routed to uncovered constructs, no unsound escape hatch system-wide*,"
   not "nobody has a sound ⊤" (which is false). §2 and §5 now carry the routed form.

3. **Sound ⊤ is genuinely distinct from `any`/`dynamic()` in practice — PARTIAL.**
   Half (b) **SURVIVES**: `unknown` genuinely *blocks* — direct arith/index/call on
   an `unknown` are all rejected, never silently accepted; it is *not* a bounded-any
   on the soundness axis. Half (a), the critic's claimed unusable false positive
   (`type(x)=="number"` not narrowing `unknown`), was **re-run end-to-end and does
   NOT reproduce as a narrowing failure** — see the reconciliation below. ⊤-narrowing
   works (audit round 1 finding 3 / §9.7 of the slice, which the critic mis-attributed
   to round 4 / §9.17). The narrowing layer *is* wired for `unknown`. The genuine,
   narrower residual is a **precision asymmetry** (recorded below), not a usability
   gap, and not the pressure-toward-bounded-any the critic asserted.

   > **Reconciliation (the contradiction the synthesis pass was charged to resolve).**
   > The soundness critic (claim 3) reported `if type(x)=="number" then x+1` does not
   > narrow an `unknown`-typed `x`. Round 1 finding 3 (§9.7 — *not* round 4 / §9.17,
   > which fixed the unrelated `rec_with_indexer` dynamic-read union) reported fixing
   > exactly `unknown`-narrows-to-the-positive-set. Re-running both end-to-end through
   > `crescent_slice_lower.lower → A.check`:
   >
   > | Probe | Result |
   > |---|---|
   > | `(unknown)->number`, `type(x)=="number"`, `return x` | **CLEAN** — narrows |
   > | `(unknown)->string`, `type(x)=="string"`, `return x` (the critic's exact idiom) | **CLEAN** — narrows |
   > | `(unknown)->number`, `type(x)=="number"`, `return x+1` | **CLEAN** — narrows, arith ok |
   > | `(unknown)->integer`, `type(x)=="number"`, `return x+1` (the critic's `C3e`) | **FINDINGS** |
   > | `(number)->integer`, `return x+1` (no narrowing at all) | **FINDINGS** |
   >
   > The critic's `C3e` rejection is **a correct number/integer type mismatch, not a
   > narrowing failure**: narrowing `unknown` by `type=="number"` yields the *positive
   > set* `number` (`unknown ∩ positive = positive`), so `x:number`, `x+1:number`,
   > which is **not** `<: integer` — the last row shows the identical rejection with no
   > narrowing involved. The critic's "control" `C3h` (`integer|string`) was CLEAN only
   > because a **union** narrows to its matching *member* `integer` (`m ∩ positive = m`),
   > making `x+1:integer <: integer`. The two cases differ in narrowed *result type*,
   > both correct; the critic compared them and mis-read the difference as a narrowing
   > failure. **Verdict: round 1 did fix ⊤-narrowing and it holds; the critic's claim-3
   > usability repro is stale/incorrect.**
   >
   > **The genuine residual (recorded honestly):** `unknown` narrows only to the broad
   > positive set (`number`), never to a sharper member (`integer`), whereas a union
   > narrows to its precise member. So a guarded `unknown` is *sound but less precise*
   > than a guarded union — a real precision asymmetry, not an unusable false positive
   > and not bounded-any pressure. This is the honest, narrower (a)-residual.

4. **Totality is highest-leverage *on the correct axis* — PARTIAL ("keystone"
   corrected).** Against any *single* root construct, totality wins (+12.1% SV vs
   `dynamic-index` +8.1%). But the **top-4 root constructs combined dominate**
   (+16.2% SV), and ~half of totality's headline gain is contingent on stdlib fixes
   (`critique-leverage.md`, `per_property_metric.lua`, baseline SV=83,226 / 61.6%
   coverage). "Keystone" is dropped (§4): totality is the *thesis-defining semantic
   precondition* (makes sound-⊤ real at the choke point), root-construct coverage is
   the larger near-term coverage lever — complementary, not competing.

5. **Soundness holds over the covered domain — FALSIFIED then FIXED (2026-06-14).**
   A fully in-subset program could write a `number` into an `integer` field through a
   widened alias and be accepted CLEAN (`critique-soundness.md`; see §4b). Shared a
   root with claim 1 (mutable-field covariance). Soundness is a **HARD invariant**, so
   this was must-fix, not an accepted aim: the closure is now **landed** (slice §6.14,
   increment v2.10) — check-mode covariant construction (`check_table_expr` +
   `check_table` evidence) + invariant-mutable record/indexer subtyping, with the
   residual alias-and-read cost measured rare and `readonly` deferred. The two bug
   repros now REJECT (permanent regression tests), the 5 construction fixtures stay
   CLEAN, and the full analysis suite is green. The honest statement is now "sound over
   the covered domain, including mutable-field variance (the alias-and-read precision
   recovery via `readonly` is the only deferred piece, and it only *adds* acceptances)."

---

## Appendix: original falsifiable framing (pre-review, retained for the record)

The pre-review version stated the five claims as not-yet-stress-tested targets.
Retained verbatim so the before/after is auditable.

1. **The value-set / judgement dichotomy partitions cleanly.** Asserts
   every property is *either* a subset of the value universe checkable by
   subtyping (→ lattice enrichment, no pass) *or* a genuinely-orthogonal judgement
   (→ its own de-special-cased layer), with no third category and no property that
   straddles. *Falsifier:* a real Crescent property (e.g. mutable-field invariance,
   capability-reachability, or a metamethod-dependent operation) that is neither
   cleanly a value-subset *nor* cleanly an orthogonal layer — forcing a special
   case or a hybrid that the dichotomy does not name.

2. **The prior-art gap is real, not a missed occupant.** Asserts no single
   system occupies (A)+(B)+(C)+(D). *Falsifier:* a system (surveyed or not) that in
   fact holds all four — or a demonstration that one of the four properties is
   defined so as to be trivially unoccupiable (making the "gap" an artifact of the
   definition rather than of the literature).

3. **`dynamic()` / `any` is genuinely distinct from our sound ⊤ in practice, not
   just on paper.** Leans on `unknown`-blocks-until-narrowed being a real,
   enforced difference. *Falsifier:* a corpus pattern where our `unknown`
   propagation either (a) is forced to behave like a bounded-any to avoid
   unusable false positives, or (b) produces an unsound accept — i.e. the
   sound-⊤/unsound-any distinction collapses under real code.

4. **Totality is highest-leverage *on the correct axis*.** Asserts the
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
