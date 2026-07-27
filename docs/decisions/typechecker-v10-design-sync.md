# v10 typechecker design sync — prefix, kernel primitives, axiom mechanism

Status: decision-input artifact, not a ratified plan. Records a LATER round
of v10 design conversation, conducted partly with an external collaborator
referred to as "fable," that refines and extends the architecture set out in
`docs/decisions/typechecker-v10-proposal.md`. That document is a
prerequisite — this one cross-references it rather than restating it. Purpose:
hand a precise, synthesized state of the design to a fresh session or
collaborator without requiring reconstruction from the underlying
conversation transcript. Only settled conclusions and explicitly-flagged-open
items are recorded here; dead ends, retracted claims, and in-session
corrections are omitted, matching this repo's existing decision-doc
convention (see `typechecker-v10-proposal.md` §2's own framing: "What's
recorded below is the final resolved state per piece — not the intermediate
wrong turns").

**Prerequisite reading:** `docs/decisions/typechecker-version-history.md`
(the graveyard of 8 prior failed attempts) and
`docs/decisions/typechecker-v10-proposal.md` (the original v10 proposal and
its critical evaluation). Read both first.

---

## 1. Prefix architecture

Refines and extends the "Op-sem prefix" piece of `typechecker-v10-proposal.md`
§1/§2. Does not restate that document's content; only the new refinements
follow.

**Settled: the kernel stays completely empty of domain content.** Semantics
does not enter as kernel content — no privileged theory, no smuggled
judgment. It enters as a declared, shared, versioned, citable object (the
"prefix"), structurally the same kind of thing a theory-registry entry is,
just factored out because every theory shares it. A derivation's full
encoding is conceptually `semantics ⊕ theory's rules ⊕ program's judgments`.
Soundness-relative-to-semantics is not a kernel faculty — it is a citation
requirement: a theory's soundness argument is itself an ordinary certificate
that cites the prefix, replayed by the same kernel mechanism that replays
everything else. No new kernel machinery is needed for this part.

Versioning and plurality fall out of this for free: certificates cite their
prefix version, old derivations replay forever against their era's meaning, a
language change is a new prefix version — never a retroactive repricing.
Multiple prefixes can coexist as separate citable objects (e.g. an
eternity-tier pure-Lua semantics vs. a LuaJIT-extended semantics), with
theories declaring which prefix they are sound against.

**Settled, scope:** this generalizes in principle to a language-agnostic
verification substrate — any language's semantics could be a prefix ("the C#
nullability checker" = C#-prefix × nullability-theory) — but that
generalization is explicitly VISION-TIER, not the deliverable. The
deliverable-tier commitment is a single crescent-Lua prefix, instance one,
funding the substrate. Cross-language prefixes are out of scope for the
actual build.

**Settled: `proof/typing.v` (v9's Coq/Rocq proof development) is REJECTED as
a direct source for prefix v1.** Reasoning: adopting it wholesale would be
"context poisoning" — it bundles the real operational semantics
(`step`/`has_type`, a genuine CBV small-step semantics with progress and
preservation proved to `Qed`) together with two unrelated things (v9's own
algorithmic-checker-soundness proof, and a subtype-lattice proof) under one
file family, with a stale header that undercounts its own actual scope (it
claims a narrower "minimal core" than what it actually formalizes — unions,
flow-narrowing, recursion, refs, primops, and loops are all present and
proved despite the header saying they are deferred). If a prefix v1 is
built, it needs deliberate extraction and cleanup from `typing.v`, not
wholesale adoption.

**Settled: `lib/type/static-v5/op_sem.lua` / `op_sem_alt.lua` are OFF-TARGET
for the prefix role.** They formalize v5's own type-inference algorithm's
step relation (the solver's operational semantics), not crescent-Lua's
language semantics. This was independently verified via direct file reading
earlier in the same conversation.

**Open, unresolved discrepancy:** a later message from "fable" listed "v5's
op_sem pair" alongside "v9's Qed development" as assets to read FOR the
prefix role — directly contradicting the earlier, sourced finding above.
This has not been reconciled. Record as OPEN, not resolved either way.

**Settled: `docs/reality-bridge.md` + `lib/sem/bridge/exec.lua` are evidence
FOR a prefix's faithfulness, not a substitute for one.** This is an existing
differential-test harness bridging the (narrower, minimal-core, de-Bruijn)
Coq model to real LuaJIT execution empirically — a term battery checking
"well-typed term, run on real LuaJIT, produces a value inhabiting its
inferred type." It is a validation tool for a prefix (an empirical faithfulness
check), not a citable rule-indexed document itself, and does not substitute
for one.

## 2. Term representation: de Bruijn standardization

Already implemented and committed; cross-referenced here, not re-derived.
Commits: `c6d21460` (initial prototype), `1c82957b` (rename),
`d3a84931` (Algorithm J), `c4b62ec2` (discharge-scoping fix), `b634ea71`
(the de Bruijn standardization itself).

Both theory-registry entries (`lib/type/v10_kernel/theories/algorithm_w.lua`,
`algorithm_j.lua`) were rewritten to use de Bruijn indices for variable
binding instead of named string binders, with a cosmetic-only display name
riding alongside for readability (never used for lookup or identity). This
resolves two of the three carry-forward lessons from the rejected
`lib/type/framework/` attempt (`docs/typechecker-framework-postmortem.md`,
also summarized in `typechecker-version-history.md`'s framework section)
structurally: binder identity becomes lexical position by construction
(lesson 1), and alpha-stable digests become free since alpha-equivalent
terms are byte-identical under de Bruijn (lesson 3). Lesson 2
(capture-avoidance as a checked, not assumed, condition) is only partially
addressed — narrowed in scope, not eliminated. The kernel itself needed zero
changes for this, since it already treats term/certificate payloads as fully
opaque.

Full reasoning is recorded in the commit messages above and in
`lib/type/v10_kernel/NOTATION.md` and `README.md` — this section
forward-references those rather than re-deriving them.

## 3. The kernel-performative concern and its resolution: generic content-checking primitives

New in this round; not present in either prior doc.

**The concern.** Confirmed via direct code trace that `kernel.lua`'s replay
currently proves ONLY citation-graph well-formedness — citation resolves,
arity/shape matches, well-founded, hypotheses discharged. It never inspects
`conclusion` content beyond checking it is non-nil. This means a producer
(theory implementation) with an internal bug — e.g. a broken `unify` missing
an occurs check — could emit a certificate that is structurally perfect
(right rule cited, right arity, right discharge) but semantically WRONG
(incorrect `type_str`), and replay would accept it, because content is
opaque to the kernel by design. This is a real, permanent limitation of a
purely citation-graph-checking kernel, not a bug to be patched.

**The resolution.** This is not a binary "domain-blind (zero content
checking) XOR content-checking (requires one fixed domain, like Coq's actual
kernel, which is hardwired to one logic, CIC)" dilemma. There is a third
point, which is how real LCF-style trusted kernels (HOL, Isabelle's core)
actually achieve both genericity and content-checking simultaneously: a
small, FIXED, GENERIC vocabulary of content-manipulating primitives
(substitution, structural/alpha equality, term combination/application) that
are domain-independent because they operate purely structurally on typed
syntax as data — general enough to underlie many different theories, not
specific to any one. A domain-specific rule (e.g. W-App) should not be an
opaque atomic schema with an unchecked payload; it should be CONSTRUCTED by
composing calls to these generic primitives, the same way a derived tactic
in HOL is a sequence of primitive kernel calls rather than a new trusted
axiom.

This directly resolves an earlier-raised, separate critique in the same
conversation — "W-App should be built from kernel primitives, not
hardcoded as its own opaque named rule" — the two turn out to be the same
underlying problem: an opaque atomic schema with unchecked content, and a
kernel with zero content-checking ability, are two faces of one gap, and the
generic-primitives design closes both at once.

**Concretely required (unbuilt, real design and implementation work, not a
rename):** generic term/type primitives at the kernel level — substitution
(plausibly easier now, post-de-Bruijn-standardization, since de Bruijn
shift/subst is exactly this kind of structural, domain-independent
operation), structural/type equality, and some notion of
application/combination. These must stay small enough to remain page-sized
and shared across all theories, but real enough that a theory's `conclusion`
is PRODUCED BY calls to these primitives rather than handed to the kernel as
an opaque, unchecked blob.

## 4. Fable's proposed stack and axiom/taint mechanism

The following is recorded as fable's own proposal, attributed, not as a
settled crescent decision — the pressure-test round in §5 is the closest
thing to evaluation this content has received so far.

### Stack (a-side)

Fable's proposed full stack for "what should the checker look like":

- **Prefix:** crescent-Lua op-sem as normative spec — internally
  consistency-checked, parity-suited against LuaJIT, authoritative over the
  implementation.
- **Kernel:** page-sized replayer — citation, schematic instantiation,
  structural equality/substitution primitives, well-foundedness,
  lexically-scoped discharge (referring to the already-fixed DAG
  all-paths-discharge bug, commit `c4b62ec2`). Described by fable as
  "first-proved, not uniquely-holy."
- **Certificate layer:** in-process derivation arenas — the prover's own
  work structure, walked once by the replayer, content-hash cached, with an
  alias/schema library as "proved compression." No serialization economics
  implied.
- **Prover(s):** untrusted, fused, arbitrarily clever, constrained only to
  build derivations in their native structure — with v3's
  constraint-gen/solve split cited by fable as "the founding shape."
- **Registry:** theories as entries, rules stated against the prefix,
  arbitrary prover algorithms, certificates the only trust channel.

**Open, unresolved ambiguity on the "v3... founding shape" point:** it is
ambiguous whether fable means reusing v3's actual accumulated code (which
would carry the same "context poisoning" risk already flagged for
`typing.v` in §1 — `lib/type/static/` is the exact lineage with the
documented 105+ ad-hoc `ctx._foo` instances, per
`typechecker-version-history.md`'s v3 section) or reusing only the abstract
generation/solving-split PATTERN. This was raised and NOT resolved by
fable's follow-up reply (see §5). Record as OPEN.

Two named opens carried unchanged from what was already known going into
this round:

- the evidence grammar's addressing/coordination contract, which needs to
  satisfy the framework postmortem's three lessons (§2 above) AND avoid
  declc's Hole H1 — the missing-middle-derivation-layer failure where
  cross-provenance corroboration could structurally never fire because
  harvest vocabularies never coincided (`typechecker-version-history.md`'s
  declc section);
- the corroboration layer itself — the actual research bet, composable
  theories recovering fused-monolith precision, unverified, deliberately
  weak closure predicate (this is `typechecker-v10-proposal.md`'s
  "sharpest unresolved point," unchanged by this round).

### Axiom/sorry mechanism (b-side)

A proposed NEW mechanism, attributed to fable, not yet built, for
controlled/tracked unsoundness.

A derivation leaf that cites no rule is an axiom node — a tracked
assumption, not a proved fact. The kernel does not reject it; it accepts it
but TAINTS it, and taint propagates through citation, so every judgment
transitively resting on an axiom carries the axiom-set in a trust label.
This gives soundness stratification instead of a binary accept/reject:
proved (kernel-replayed, axiom-free), proved-modulo-{named assumption set},
asserted (no certificate at all) — queryable per judgment, aggregable per
module.

This also resolves the "migration policy" open item from
`typechecker-v10-proposal.md` §3 item 6 — but as a separate, self-contained
answer that does NOT depend on that earlier proposal's unsupported
"graveyard's uniform lesson" attribution. That discrepancy in the original
proposal doc stands as previously recorded, unresolved by this new
mechanism; the two are orthogonal. Under this mechanism, the legacy
checker's verdicts get imported as one giant named, versioned axiom
("legacy-v3-trusts-this"), burned down judgment by judgment as real
derivations replace them, rather than requiring an upfront border-control
decision.

Two invariants keep this honest, per fable: axioms must be declared
registry objects (named, owned, versioned — never anonymous inline escape
hatches), and taint must be unlaunderable (no rule, alias, or cache path may
drop an axiom from a judgment's trust label). The second invariant is new
kernel-side logic (a propagation check), not free.

## 5. Pressure-test round: CC's follow-up and fable's confidence-leveled reply

Three items were pressure-tested against fable's stack/axiom proposal. Two
other items raised earlier in the same conversation — the v5-op-sem
discrepancy (§1) and the v3-shape-vs-code ambiguity (§4) — were NOT
addressed by fable's reply and remain open; they are not conflated with the
three below.

**1. Schematic instantiation.** Fable's answer: correct that nothing is
designed yet; what exists today is only shape descriptors (`RuleSchema` =
name/judgment/arity/assumes/discharges booleans, no pattern-with-metavariables).
What real "instantiation checking" requires: a pattern language (terms with
metavariables), a binding discipline, and a matching/substitution algorithm
the kernel runs. Fable's stated confidence: reasonably confident this is a
well-trodden object (first-order pattern matching if `type_str`s end up
first-order terms; higher-order matching flagged as "a tarpit to avoid by
design"), and that the framework postmortem's three lessons (§2) should be
read as prior contact with this exact component's failure modes and should
constrain its design. What fable says cannot yet be answered: what the
pattern language's actual term structure is, because it depends on an
upstream, currently-undecided fork — whether a judgment's content
(`type_str` etc.) is an opaque string or a structured term — everything
about instantiation-checking design forks on this decision, which has not
been made. Status: undesigned; dependencies identified; precedent (the
framework's lessons) known; the term-structure decision is upstream of the
whole component and needs to be made deliberately.

**2. Discharge-certificate format.** Fable's answer: agreed, no resolution
added beyond restating the obligation; this remains exactly as open as
previously recorded.

**3. Axiom/taint mechanics.** Fable's answer, an actual argument, not just
agreement: taint should be a NODE property, not a PATH property (unlike
discharge, which is genuinely path/scope-relative), because "does this
judgment's derivation transitively rest on an axiom" is a fixed fact about
the derivation DAG below a node, independent of which parent cites it —
whereas discharge is inherently about scope (where an assumption gets
closed off), which is parent-path-relative. Argument: taint is a monotone
bottom-up set-union over the DAG (a node's taint = its own axiom-citation,
if any, unioned with the union of all its premises' taints) — computable in
one pass, memoizable per node, because it does not depend on the parent.

This argument rests on one flagged, load-bearing assumption: taint must
never interact with discharge — specifically, discharging a hypothesis must
never be able to remove or convert an axiom's taint (axioms are
undischargeable by definition; if the evidence grammar ever added a form
converting an axiom into a discharged hypothesis, the whole node-property
argument would break and taint would become path-relative like discharge).
The design rule that keeps taint cheap is therefore itself a grammar
constraint that must be stated and enforced: axiom nodes admit no discharge
form.

On mechanics: an axiom is plausibly just a flagged `RuleSchema` variant
(zero premises, taint-set = {its own name}, otherwise an ordinary citation)
— but fable agrees this needs new kernel-side bookkeeping (`walk()` would
need to accumulate and propagate a second set alongside the existing
ancestor-discharge-set), and, given the discharge-scoping fix's own history
(an initial "just use a stack" assumption turned out to need real path-set
tracking once DAG-sharing was considered — commit `c4b62ec2`), this
propagation mechanism needs the same worked-example treatment before "cheap"
counts as verified, not assumed. Fable's specific proposed test case: a node
shared by two parents with DIFFERENT discharge contexts should show
IDENTICAL taint but potentially DIFFERENT discharge status — this is the
case that would distinguish correct taint-propagation from an accidentally
path-relative implementation, the same way an analogous case caught the
original discharge-scoping bug.

**Fable's own confidence summary** (structure preserved): (1) undesigned,
start from the framework's three lessons, term-structure decision is the
upstream fork; (2) open, unchanged; (3) node-property taint is ARGUED (not
just instinct), conditional on one statable grammar rule (axioms are
undischargeable), propagation mechanics are new kernel logic needing the
worked-example treatment, "cheap" is plausible-not-verified.

---

## Open items going into next session

Six items, none resolved by this document. A fresh session should pick these
up, not guess at answers.

1. **v5-op-sem citation discrepancy** (§1) — fable listed `op_sem.lua`/
   `op_sem_alt.lua` as prefix-role assets, contradicting the earlier, sourced
   finding that they formalize v5's own solver, not crescent-Lua semantics.
   Unresolved.
2. **v3 constraint-gen/solve "founding shape" ambiguity** (§4) — unclear
   whether fable means reusing v3's actual code (context-poisoning risk, per
   the 105+ ad-hoc `ctx._foo` instances) or only the abstract
   generation/solving-split pattern. Unresolved.
3. **Schematic instantiation** (§5.1) — undesigned. Depends on an
   upstream, undecided fork: is a judgment's content (`type_str` etc.) an
   opaque string or a structured term? Precedent (framework postmortem's
   three lessons) identified but not yet applied to a concrete design.
4. **Discharge-certificate format** (§5.2) — open, unchanged from prior
   rounds.
5. **Taint-propagation mechanics** (§5.3) — argued as a node property
   conditional on "axiom nodes admit no discharge form," but the
   propagation bookkeeping in `walk()` and its "cheap, one-pass" claim need
   the worked-example treatment (fable's proposed shared-node,
   different-discharge-context test case) before being counted as verified.
6. **Corroboration layer** (§4, `typechecker-v10-proposal.md`'s sharpest
   unresolved point) — the standing research bet, unchanged from the
   original proposal: does the closure predicate ever get exercised against
   a real, mature theory, or does passing it on founding toy entries alone
   risk certifying a mechanism never tested against declc's actual failure
   mode?
