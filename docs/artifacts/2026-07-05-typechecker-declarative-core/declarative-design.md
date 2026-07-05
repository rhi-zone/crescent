# Typechecker declarative core — the certified formulation (2026-07-05)

Provenance classes used throughout this artifact dir:
[OWNER-CERTIFIED] = owner said yes in their own words. [AUDIT-FINDING] =
subagent-derived, unrebutted. [OPEN] = unresolved. Nothing is promoted above
its class.

## The formulation

[OWNER-CERTIFIED], verbatim:

> a pool of graded assumptions (grade = credence, three generation sources,
> no source special-cased) + mutual-consistency checking with three-valued
> verdicts (finding strength = witness-status × credence of what it
> contradicts) + one law: a claim used as a hypothesis must independently
> survive as an obligation.

## Owner refinements

- [OWNER-CERTIFIED] Annotations are assumptions like all others — "not less
  important, just less blessed as 100% true."
- [OWNER-CERTIFIED] Grade is a credence scale, not an importance scale.
- [OWNER-CERTIFIED] No special-casing of any source anywhere in the
  semantics.

## The collapse chain (how the formulation was reached)

The derivation is part of this artifact's value; each step below is
traceable in `audits.md` and the disk transcripts cited there.

1. **Three-layer composite.** [AUDIT-FINDING] The paradigm-placement audit
   (agent acbbde2dfc8cee494) first named the design as a composite:
   "bidi-shaped boundary audit + Dialyzer-genus interior consistency +
   verification-shelf verdicts — three layers, three owners."
2. **Owner's question.** [OWNER-CERTIFIED] The owner asked, in substance:
   "aren't annotations just assumptions?" — challenging every place the
   composite treated annotations as a distinct kind of thing.
3. **All three annotation-specific distinctions killed.** [AUDIT-FINDING]
   The same agent, re-adjudicating against its own J1–J5 draft:
   - (1a) *Both-ways audit*: S-param/S-return are just two generation rules;
     "binds two parties" is attribution metadata, not a satisfaction-level
     distinction. An annotation mints two pool entries where a mined belief
     mints one — a compilation fact. Kill.
   - (1b) *Certification targets*: nothing restricts proven-fine to stated
     intent; certifying a mined belief is coherent and useful. "Discharged
     pins are a real product" is reporting policy. Kill.
   - (1c) *Assume-guarantee / chase termination*: "chases terminate at
     annotated boundaries" is Algorithm-W (propagation-control) vocabulary
     that snuck back in via the paradigm naming. The declarative residue is
     Γ in 𝕋_Γ(P): some claims serve as *hypotheses* (constraining the
     execution-set quantifier) rather than *obligations* (checked against
     it) — and which claims enter Γ is grade policy, not anything intrinsic
     to annotations. Kill the annotation-specificity; keep the role.
4. **Two layers + one role bit.** [AUDIT-FINDING] Restated composite: (i)
   one pool of graded assumptions from three generation sources; (ii)
   mutual-consistency checking with three-valued verdict semantics
   (fine / wrong-with-witness / undecided, graded by witness-status ×
   assumption-grade — the working notes' product order already is this).
   What survives as the one primitive, not annotation-shaped: the
   hypothesis/obligation role split — "Any claim admitted to Γ as hypothesis
   must independently stand as obligation, or you assume what you never
   check and Sound-fine breaks." "Lying annotation is a finding" becomes
   "high-grade assumption contradicted," no special mechanism; the both-ways
   audit falls out as two pool entries sharing provenance.
5. **Owner certification.** [OWNER-CERTIFIED] The owner certified the
   formulation quoted at the top, with the refinements above (grade as
   credence; annotations not special; no source special-cased anywhere).

## Relation to the J1–J5 draft

The draft (`declarative-core-draft.md` in this dir) is pre-collapse
vocabulary: it still carries the both-ways audit as a named structure and
grades as intent strength (axiom > stated > belief). Under the certified
formulation those become: two pool entries sharing provenance, and a
credence scale with no source special-cased. The draft retains value for its
J1–J5 judgment-form skeleton (execution, trace satisfaction, modal
satisfaction, provenance/generation, finding validity) and its five holes
H1–H5, all of which remain open (see `open-threads.md`).
