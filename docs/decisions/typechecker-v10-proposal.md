# v10 typechecker proposal — decomposition and critical evaluation

Status: decision-input artifact, not a ratified plan. Records (1) a proposed
architecture for crescent's next typechecker attempt ("v10"), verbatim as
proposed this session, and (2) the resolved state of a critical evaluation of
that proposal that was cross-checked against the graveyard record and then
corrected over several rounds in-session. Nothing here is adopted; several
pieces are explicitly open questions, stated as such below.

**Prerequisite reading:** `docs/decisions/typechecker-version-history.md` is
the map of why the prior 8 replacement attempts (v4, v5, v6, v7, framework,
v9, toy_checker, declc) failed. This document cites that history rather than
re-deriving it — read it first.

---

## 1. The proposal (verbatim)

crescent typechecker v10 — the decomposition:

Op-sem prefix — crescent-Lua's operational semantics, formal, versioned,
citable. The founding document; everything downstream cites it. Closure: the
semantics document exists and the eternity-tier interpreter is parity-tested
against it (v5's instinct, correctly placed).

Kernel — domain-blind certificate replayer: checks citations,
rule-instantiation, well-foundedness, hypothesis discharge. Contains zero type
knowledge. Closure: fits on a page; proved (Coq-grade) or at minimum
property-tested to death. This is the only trusted code.

Evidence grammar — the forms certificates take: judgments-at-loci, declared
rule-schemas, cross-theory citation, hypothetical reasoning,
inductive/coinductive discipline. Versioned-with-ceremony. Closure: the
founding theories' derivations are all expressible; a stranger can read the
notation chapter.

Theory registry — untrusted prover-algorithms as entries; each registers
rule-schemas (soundness discharged against the prefix, once) and emits
certificates (replayed always). Closure: the registration protocol is
documented and W goes through it without special-casing.

Founding entry: Algorithm W — dinner-sized, certificate-emitting, the teaching
entry and the template. Hackable by design: mutations fail at replay, not
silently. Closure: a stranger reads it in a sitting and successfully registers
a variant.

Corroboration layer — cross-theory citation through shared judgments. The
research bet lives here and nowhere else: composable theories recovering
fused-monolith precision. Closure predicate deliberately weak for now: two
theories (W + flow-narrowing) jointly conclude something neither concludes
alone, on real corpus.

Later entries — MLstruct-class inference, flow theories, effects; the SOTA
floor (TS/Scala/MLstruct) as roadmap, not foundation. Refinement/dependent
neighbors: in-architecture, out-of-deliverable.

Migration policy — the legacy checker's relationship to v10 (border control vs.
metric vs. subset-gate), the one constitutional question, decided before
construction per the graveyard's uniform lesson.

---

## 2. Per-piece evaluation

A research pass cross-checked each piece against the graveyard record
(`typechecker-version-history.md` and the underlying docs it cites:
`v9-versions-survey.md`, `kernel-recommendation.md`,
`typechecker-framework-postmortem.md`, `typechecker-ad-hoc-inventory.md`, the
declc README/`synthesis.md`, `toy-checker-findings/notes.md`,
`roadmap-v2.md`). Several rounds of correction followed. What's recorded below
is the final resolved state per piece — not the intermediate wrong turns.

### Op-sem prefix

**Grounded, with one open gap.** The instinct matches v5's parity-test
discipline, which `v9-versions-survey.md` explicitly flags as worth mining:
"the operational-semantics spec + parity-test harness (the cross-implementation
discipline)... is precisely the 'multiple implementations + parity tests' the
project mandates." That part of the proposal is on solid ground.

**Open gap:** the proposal's stated closure bar — "the semantics document
exists and the eternity-tier interpreter is parity-tested against it" — is
weaker than what v9 already built. Per `typechecker-version-history.md`'s v9
section, v9 was designed against "a newly-completed **mechanized proof
development** (`proof/*.v`, Coq/Rocq, 29 increments, all `Qed`, closed under
global context — no axioms/`Admitted`)." Parity-testing an interpreter against
a semantics document is a strictly weaker guarantee than a machine-checked
proof with no admitted lemmas. The proposal is silent on whether that
proof-dev is retained, subsumed, or dropped in favor of parity-testing alone.
**This is an open question, not resolved** — the doc does not say which of the
three it intends.

### Kernel

**Resolved**, after real back-and-forth in-session; recorded here as the
resolution, not the intermediate wrong turns.

`kernel-recommendation.md` (ratified 2026-06-12) evaluated four candidates for
"what trusted *derivation* algorithm should the kernel run" — HM+extensions,
algebraic subtyping/MLstruct, set-theoretic subtyping, and bidirectional
checking — and picked bidirectional checking (§2), bundling var/abs/app as
concrete trusted rules together with the mode-propagation discipline as one
inseparable unit. Verified directly against the text: the doc never
distinguishes structural mode-propagation from type-specific rules as separate
choices, and its §6 re-evaluation triggers list conditions for reconsidering
the *subtype-relation* candidates (2/3) but never a trigger for reconsidering
the bidirectional pick itself.

That said, this does not create a live conflict with v10's kernel piece.
`kernel-recommendation.md`'s four candidates are all *derivers* — algorithms
that compute a type from a term. v10's kernel is explicitly *validate-only*:
per the proposal text, it "checks citations, rule-instantiation,
well-foundedness, hypothesis discharge" against certificates that untrusted
registry entries already produced — it derives nothing itself. So
bidirectional-checking-as-derivation does not belong in a replay-only kernel,
and not because it fails some domain-blindness purity test — it's a category
mismatch: a deriving algorithm being asked to sit in a slot that only
validates.

`kernel-recommendation.md` is not wrong on its own terms; it answers a
different question than the one v10 poses. **Stated explicitly: adopting v10
renders `kernel-recommendation.md`'s candidate-4 pick inapplicable to v10's
kernel** — not "superseded by a better derivation algorithm," but that the
whole "what should the kernel compute" framing stops applying once the
kernel's job is redefined as replay-only. This relationship is recorded here
explicitly rather than left as a silent, unstated divergence from a standing
ratified decision.

### Evidence grammar

**Open gap.** `typechecker-framework-postmortem.md`, per
`typechecker-version-history.md`'s framework section, names three specific
carried-forward lessons:

1. Binder semantic identity must be lexical position, never source-name
   comparison.
2. Capture-avoidance must be a *checked* condition (`cond_subst`), never
   assumed.
3. Alpha-stable digests as an identity invariant.

The v10 proposal's evidence-grammar piece ("judgments-at-loci, declared
rule-schemas, cross-theory citation, hypothetical reasoning,
inductive/coinductive discipline") does not mention any of the three. **Flag
as an open gap — not contradicted, just unaddressed.** The doc should state
whether these three are meant to carry forward into the evidence grammar or
not; it currently says neither.

### Theory registry

**Grounded-in-target, unverified-on-mechanism.** The piece is correctly
targeted at `typechecker-ad-hoc-inventory.md`'s root-cause finding — "105+
ad-hoc instances," dominated by "26 magic `ctx._foo` message-bus fields," with
the conclusion (quoted in `typechecker-version-history.md`'s v3 section): "The
constraint record is the actual choke point, not the solver... Every ctx field
is a constraint payload field that wasn't put in the constraint because the
record doesn't support tagged payloads."

But that doc's own recommendation is mechanism-specific: a tagged-payload
constraint schema, an explicit inter-phase API instead of ctx-mutation, and
proper dispatch tables (cf. `v9-versions-survey.md`'s "what to avoid" list:
"`ctx._foo` mutable message-bus fields," "if-elif-on-tag handler dispatch,"
"constraint records without typed payloads"). The v10 proposal states only the
outcome — "no special-casing," "W goes through it without special-casing" —
without committing to a mechanism. **Flag as grounded-in-target,
unverified-on-mechanism**: the proposal names the right disease but not yet
the cure.

### Founding entry: Algorithm W

**Resolved**, cleanly, through correction in-session.

W reintroducing v1's exact documented failure mode — order-dependent online
unification, where a generic's type variables get permanently pinned by its
first call site and later differently-typed-but-compatible calls fail (per
`typechecker-version-history.md`'s v1 section, citing `typechecker-v3.md`) —
looked at first glance like a repeat of a known dead end. It is not.

The proposal itself explicitly frames W as "dinner-sized... the teaching entry
and the template," registered as one untrusted producer among others (Theory
registry: "untrusted prover-algorithms as entries... emits certificates
(replayed always)"). Nothing requires W to be complete, and nothing requires
it to be more than a toy validating the registration protocol — this is a
completeness/precision defect in W, not a soundness defect in the kernel that
replays its certificates. **This is not an open gap; it is resolved as fine
by design.**

### Corroboration layer

**The sharpest unresolved point in the whole proposal** — and this is where
W's toy status (previous section) relocates the real question rather than
dissolving it.

Cross-theory citation through shared judgments is structurally close to
declc's exact documented failure. Per `typechecker-version-history.md`'s declc
section, the first-slice execution result was 2,401 claims harvested across
8 real `lib/` files, all ending "**ALL Open — zero Proved, zero Refuted**,"
because `harvest_stated`'s site/slot vocabulary never coincided with
`harvest_mined`'s or `harvest_axiom`'s — cross-provenance corroboration "can
structurally never fire under current conventions." That's declc's Hole H1,
"the missing middle derivation layer," and per the declc synthesis.md's own
diagnosis (cited in the version-history doc), what's missing is "a canonical
addressing/interop contract between harvesters, with a named owner and a
review gate."

Nothing in the v10 proposal — not in this section, not in Evidence grammar,
not in Theory registry — states such a contract exists or is planned.

Given that Algorithm W is explicitly a toy with no obligation to be precise
(previous section), the proposal's own closure predicate for this layer —
"two theories (W + flow-narrowing) jointly conclude something neither
concludes alone, on real corpus" — risks being satisfiable using only
toy/founding-grade entries without ever exercising the vocabulary-coincidence
problem that actually killed declc. That problem may only surface once a
real, mature theory (an actual MLstruct-class entry, real flow-narrowing) is
plugged in, not W-grade toys.

**State as the single most important open question going into v10:** does
the corroboration closure test get run against real/mature entries at some
point — and if so, when and how is that scoped — or does passing it against
founding toy entries risk certifying a mechanism that has never actually been
exercised on the failure mode it is meant to survive?

### Later entries

**Unclosed by the proposal's own internal standard.** Every other piece in
the proposal carries an explicit `Closure:` clause. "Later entries" — the
MLstruct-class inference / flow theories / effects roadmap, plus the
refinement/dependent-neighbors framing — has none. **Flag as unclosed**, by
the proposal's own stated convention for every other piece.

### Refinement/dependent neighbors

**Neutral scope framing — neither grounded nor contradicted.** None of the 8
prior attempts (v4, v5, v6, v7, framework, v9, toy_checker, declc) touched
refinement or dependent types per `typechecker-version-history.md`. There is
no graveyard record to check this framing against in either direction.
**State as neutral** — it is not supported by prior-attempt evidence, but it
is also not contradicted by any.

### Migration policy

**Unsupported attribution — no support found in the record.** The proposal's
claim that migration policy is "the one constitutional question, decided
before construction per the graveyard's uniform lesson" was checked
specifically against `roadmap.md`, `roadmap-v2.md`, and
`typechecker-version-history.md`'s terminal-status section.

The record's actual stated throughlines are:

- "Ad-hoc accumulation is the documented root cause of v1→v4 failure" (the
  CLAUDE.md Hard Constraint, commit `fe277ad3`/`f7725f2b`).
- "The framework was rejected on judgment, not on a demonstrated defect"
  (`typechecker-framework-postmortem.md`).
- "Modes are a static approximation of a dynamic property" (toy_checker's
  root-cause finding).
- Cross-provenance corroboration "can structurally never fire" (declc, Hole
  H1).

None of these is about migration, cutover, or border-control timing. The
terminal roadmap language (`roadmap.md`/`roadmap-v2.md`: "Parked, not
abandoned. Autonomous agent-directed development was declared dead by owner
verdict as of 2026-07-08 — supervision cost exceeded value") describes an
owner-verdict decision to park the whole program on supervision cost, not a
migration-policy lesson.

**State plainly: no support was found for attributing this framing to "the
graveyard's uniform lesson."** If a migration policy decision is still wanted
up front — which is a reasonable thing to want on its own merits — it should
be justified on those merits, not presented as inherited precedent from the
record.

---

## 3. What's actually open going into implementation

Six questions, none resolved by this evaluation, all requiring an explicit
answer (not a default) before or during v10 construction:

1. **Op-sem prefix vs. Coq proof.** Is v9's mechanized proof-dev (29
   increments, `Qed`, no axioms/`Admitted`) retained, subsumed into, or
   dropped in favor of the weaker "parity-tested against the semantics
   document" bar the proposal states?
2. **Evidence grammar's silence on the three framework lessons.** Do binder
   semantic identity as lexical position, checked capture-avoidance, and
   alpha-stable digests carry forward into the evidence grammar, or not?
3. **Theory registry's missing mechanism commitment.** "No special-casing" is
   an outcome, not a mechanism — does the registry adopt
   `typechecker-ad-hoc-inventory.md`'s specific recommendation (tagged-payload
   constraint schema, explicit inter-phase API, dispatch tables), something
   else, or is this still undecided?
4. **Corroboration layer's real-entry timing.** Does the corroboration
   closure predicate get exercised against a real, mature theory at some
   defined point, or does passing it on founding toy entries alone risk
   certifying a mechanism that was never tested against declc's actual
   failure mode?
5. **Later entries' missing closure clause.** Every other proposal piece has
   one; this one doesn't. What is it?
6. **Migration policy's unsupported attribution.** The "graveyard's uniform
   lesson" framing has no support in the record — if a pre-construction
   migration decision is still wanted, on what basis (other than inherited
   precedent that doesn't exist) is it justified?

No new editorializing verdict on the proposal as a whole is recorded here —
this document preserves the resolved-vs-open state reached in conversation,
not a new opinion layered on top of it.
