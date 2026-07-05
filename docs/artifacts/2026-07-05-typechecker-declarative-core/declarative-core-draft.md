# Semantics linter — declarative core (draft, scratch, not greenlit)

STATUS: draft, pre-collapse vocabulary — superseded in part by the two-layer
formulation in `declarative-design.md` (same dir). Retains value for its
J1–J5 judgment-form structure and its 5 holes (H1–H5), all still open.

Attempted analogue of HM's five declarative rules: what the linter's verdicts
*mean*, with zero implementation vocabulary. Everything that exists only to
make deciding fast is absent by construction.

## 1. Semantic domain

**Program.** `P` is a Lua 5.1 program (chunk + reachable modules).

**Execution.** An execution `T` of `P` is a trace: the (finite or infinite)
sequence of *evaluation events* produced by Lua 5.1's operational semantics —
real evaluation order, real scoping, real multivalue adjustment/truncation,
real metamethod dispatch, real error propagation. Events (grammar, one
constructor per observable step class):

    ev ::= eval(s, vs)          -- expression at site s produced value list vs
         | bind(s, x, v)        -- name x bound to v at site s
         | call(s, f, vs)       -- f invoked at s with argument list vs
         | ret(s, vs)           -- call at s returned vs
         | effect(s, e)         -- externally visible effect e at s (via caps)
         | err(s, v)            -- error raised at s with value v

Judgment form **J1**: `P, σ ⇓ T` — under initial state σ, `P` executes to
trace `T`. Its rules ARE Lua 5.1's operational semantics (one per language
form); this spec takes them as given, the way HM takes λ-calculus evaluation
as given.

**Execution set.** `𝕋_Γ(P) = { T | P, σ ⇓ T, σ ⊨ Γ }` where Γ is the
boundary assumption set: the stated claims at `P`'s exports/imports,
interpreted as constraints on the environments σ ranges over. Closed-world:
Γ empty, σ ranges over the program's own entry states. Open-world: σ ranges
over ALL states satisfying Γ. A "real execution" means a member of `𝕋_Γ(P)`.

## 2. Claim language

Atomic behavior propositions (about events in one trace):

    φ ::= arrives(s, k, V)   -- every eval/call event at site s carries, in
                             -- slot k, a value in value-set V
        | happens(e)         -- an event matching pattern e occurs
        | paired(e₁, e₂)     -- every event matching e₁ is followed by a
                             -- matching e₂ (acquire/release, open/close)
        | reachable(s)       -- some event occurs at site s
        | consumed(s)        -- a value produced at s appears later as an
                             -- argument/operand of some event
        | relates(f, R)      -- every (call(s,f,vs), ret(s,ws)) pair in the
                             -- trace has (vs, ws) ∈ R

Claims are modal closures:

    C ::= □φ  |  ◇φ

**Satisfaction.** Judgment form **J2**: `T ⊨ φ` — trace T satisfies φ; one
rule per atomic constructor, each a direct quantification over T's events
(six rules, no auxiliary machinery). Judgment form **J3**: satisfaction by an
execution set:

    (□)  𝕋 ⊨ □φ  iff  ∀T ∈ 𝕋. T ⊨ φ
    (◇)  𝕋 ⊨ ◇φ  iff  ∃T ∈ 𝕋. T ⊨ φ      (that T is the witness)

## 3. Claim provenance

Judgment form **J4**: `P ⊢ C @ g` — program P gives rise to claim C at
intent grade g ∈ {axiom, stated, belief}, ordered axiom > stated > belief.
Three rule families:

**(Stated)** An annotation `--:`/`--::` on a definition compiles to claims at
grade `stated`. One annotation emits claims binding *different parties* —
this split is the both-ways audit, stated declaratively:

    (S-param)   param annotation x: τ at f  ⊢  □arrives(entry(f), x, ⟦τ⟧) @ stated
                — an obligation on every caller of f
    (S-return)  return annotation τ at f    ⊢  □arrives(exit(f), 1, ⟦τ⟧) @ stated
                — an obligation on the body of f

Dually, each obligation on one party is an *assumption* available when
judging the other (the caller may assume the return claim; the body may
assume the param claim). The audit: an annotation is honored iff BOTH its
emitted obligations hold of `𝕋_Γ(P)`; a lying annotation is one whose
body-side obligation is proven wrong.

**(Axiom)** A fixed catalog of universal claims holds of every program at
grade `axiom`: err-events are unintended (`□¬happens(err(s,_))` for each s
not under a handler-by-design), code is meant to run (`◇reachable(s)`),
produced values are meant to matter (`□consumed(s)` for value-producing s),
paired resources close (`□paired(open, close)`), plus house axioms
(caps-first, `(nil, errmsg)`).

**(Belief)** A code form that *presupposes* φ mints `□φ @ belief`: a
dereference `x.f` at s presupposes arrives(s, x, non-nil); a guard
`if x ~= nil` presupposes the author believed both branches reachable. The
notes supply no catalog of presupposing forms — see Hole H5.

## 4. Findings

Judgment form **J5**: `⊢ ⟨C, v⟩` — a finding is valid when:

    (F-fine)   ⊢ ⟨C, proven-fine⟩    iff  𝕋_Γ(P) ⊨ C
    (F-wrong)  ⊢ ⟨□φ, proven-wrong⟩  iff  ∃T ∈ 𝕋_Γ(P). T ⊨ ¬φ
               — T is the witness; the finding carries T (or the definition
               of a family of such T)
    (F-wrong◇) ⊢ ⟨◇φ, proven-wrong⟩  iff  ∀T ∈ 𝕋_Γ(P). T ⊨ ¬φ
               — NOTE: no witness trace exists for this case; see Hole H3
    (F-undec)  ⊢ ⟨C, undecided⟩      iff  neither of the above is *derivable*
               — see Hole H2: this is only meaningful relative to a
               derivation system the notes do not contain

**Grade of a finding**: the pair (witness status, intent grade of C's
provenance under J4), ordered by product order. The gate is an upward-closed
cut in that order. (Declarative: the cut is a parameter, like HM's choice of
initial Γ.)

## 5. Soundness (what the system promises)

Relative to `𝕋_Γ(P)` — i.e. modulo the honesty of boundary assumptions Γ:

    (Sound-wrong)  If the linter emits ⟨C, proven-wrong⟩ then ⊢ ⟨C, proven-wrong⟩
                   — in particular a real execution T ∈ 𝕋_Γ(P) violating C
                   exists and is exhibited (for □-claims).
    (Sound-fine)   If the linter emits ⟨C, proven-fine⟩ then 𝕋_Γ(P) ⊨ C
                   — no real execution violates it.

No completeness is promised (Rice); `undecided` is the labeled residue.

## Holes — parts that resist declarative statement

- **H1 (central).** There is no declarative *derivation system* for
  proven-fine/proven-wrong. J2/J3 define truth (`⊨`), which is undecidable;
  HM's five rules are simultaneously the meaning AND a proof system whose
  derivations an algorithm can search. Here the notes contain only the
  algorithm (solver machinery) and the semantics — the middle layer of
  inference rules whose soundness/completeness could even be *stated* does
  not exist yet. This spec's J5 quantifies over real traces; nothing here
  says what a *derivation* of a verdict looks like.
- **H2.** `undecided` is definable only as "neither verdict derivable in the
  missing system of H1". Against the raw semantics it is empty (every claim
  is true or false of 𝕋). So F-undec is a placeholder, not a rule.
- **H3.** proven-wrong for ◇-claims (e.g. refuting ◇reachable(s) = dead
  code) has no witness execution — the evidence is a universal-absence proof,
  an object H1's missing system would have to define. "Graded witness" is
  undefined for this quadrant of the verdict table.
- **H4.** The uniformity class (noninterference under renaming) is a
  2-safety hyperproperty: satisfaction over *pairs* of traces. The claim
  grammar above is single-trace; no C expresses it. Either the claim language
  gains hyper-claims (⊨ over trace pairs) or uniformity lives outside this
  core. Consistent with the OPEN OBJECTION in the working notes — unresolved.
- **H5.** (Belief) needs a catalog judgment "form F presupposes φ" — same
  shape as the axiom catalog, but the notes name only two examples. A
  catalog is declarative in kind, but this one hasn't been written.

## Honest count

Judgment forms: **5** (J1 execution, J2 trace-satisfaction, J3 modal
satisfaction, J4 provenance, J5 finding validity) + 2 relations taken as
parameters (⟦τ⟧ value-set interpretation; the gate cut).

Rules at the claim level: 6 (J2) + 2 (J3) + 3 families ≈ 4+ rules (J4, with
axiom & belief catalogs open-ended) + 4 (J5, one a placeholder) + 2
soundness statements ≈ **18–20 rules**, versus HM's 1 judgment form and 5–6
rules. Like-for-like caveat both directions: HM also assumes an operational
semantics and a type-expression language externally, as J1 and ⟦τ⟧ are here;
but HM's five rules are also its proof system, and the analogous layer here
(H1) is not merely uncounted — it is missing.
