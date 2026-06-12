# Agnostic Static Analysis Object Model

Status: active design direction, second pass.

This document refines `docs/agnostic-static-analysis-design.md` into the first
object model. It is not a JSON format, Lua API, proof assistant encoding, or
replacement typechecker implementation plan.

## Design Goal

The object model must represent static-analysis work without choosing a type
system, source language, solver, or proof calculus.

The smallest useful unit is:

```text
an analyzer accepts or rejects claims about artifacts under named assumptions
```

The model therefore starts with identity, artifacts, claims, evidence,
dependencies, and trust. Syntax trees, binders, types, environments, heaps, and
effects are hosted vocabulary unless a later derivation proves they are
substrate-level.

## Object Kinds

### Identity

Every persistent object that can be referenced by evidence has an identity.

```text
Id {
  space,
  local
}
```

`space` names the identity namespace, such as `artifact`, `observation`,
`claim`, `evidence`, `trust`, or a hosted-semantics namespace.

`local` is an opaque stable key inside that space.

The substrate does not interpret `local` as a source name, path, AST index, or
semantic binder identity. Hosted semantics may define identities with those
meanings.

### Artifact

An artifact is an analyzed object.

```text
Artifact {
  id,
  kind,
  content_ref,
  digest?,
  meta?
}
```

`kind` is descriptive, not semantic authority. Examples: `source_text`,
`syntax_tree`, `cfg`, `module_graph`, `bytecode`, `archive`, `trace`.

`content_ref` points to the stored content. It may be inline data, a path, a
content-addressed blob, or a reference into another artifact.

`digest` is optional at the object-model level. Concrete encodings should use
digests when artifacts cross trust or cache boundaries.

### Observation

An observation is a named fact extracted from one or more artifacts.

```text
Observation {
  id,
  predicate,
  args,
  source_artifacts,
  support
}
```

`predicate` is a symbol owned by the selected analysis semantics. The substrate
does not know whether `node_head`, `edge`, `declares`, `writes`, or
`imports_capability` are meaningful.

`support` records why the observation may be used:

- `checked`: derivable from artifact content by a checker;
- `trusted`: admitted by a visible trust boundary;
- `assumed`: local hypothesis scoped to a larger evidence object.

### Claim

A claim is a proposition that can be accepted, rejected, or left unknown.

```text
Claim {
  id,
  semantics,
  predicate,
  args,
  subject_artifacts
}
```

`semantics` names the hosted static semantics that owns the claim predicate.

Any analysis-local context a hosted semantics needs (lexical scope, path
condition, dataflow point, module context, proof assumption) is encoded inside
`args`. The substrate does not reserve a separate context slot; see "What Is Not
In The Substrate Yet".

### Evidence

Evidence is an object offered in support of a claim.

```text
Evidence {
  id,
  claim,
  method,
  inputs,
  result
}
```

`method` is selected by the claim's semantics. Examples:

- `rule_application`;
- `artifact_check`;
- `dataflow_fixpoint_witness`;
- `solver_witness`;
- `counterexample`;
- `trusted_boundary`;
- `delegated_checker_result`.

The substrate does not require all evidence to be proof trees. A semantics may
use proof trees, traces, witnesses, normalized solver outputs, or small
checker-specific certificates.

### Dependency

A dependency records what an accepted claim relies on.

```text
Dependency {
  from_claim,
  kind,
  target,
  invalidation?
}
```

`target` may be an artifact, observation, claim, evidence object, or trust
boundary.

`kind` is semantics-owned, but the substrate reserves broad classes:

- `artifact_content`;
- `observation`;
- `accepted_claim`;
- `trusted_boundary`;
- `assumption`;
- `external_tool_result`.

`invalidation` describes when the dependency stops being valid. Examples:
artifact digest changes, module declaration changes, store abstraction changes,
capability policy changes, path condition no longer holds.

The substrate does not compute every invalidation relation by itself. It must
store them so incremental and audit tools can reason about them.

### Trust Boundary

A trust boundary is a visible place where analysis accepts something it did not
fully check.

```text
TrustBoundary {
  id,
  kind,
  issuer,
  covers,
  payload_digest?,
  policy
}
```

`covers` is the region or subject the trust grant applies to: the artifact,
declaration, claim predicate family, or analysis context that this boundary
admits without full checking. (It was previously named `scope`; renamed to avoid
collision with the removed `Claim.scope` field, which meant something
unrelated.)

Examples:

- external declaration file;
- hand-written assertion;
- unchecked cast;
- FFI declaration;
- target platform specification;
- SMT solver result without proof;
- cached result from a different checker.

Trust boundaries are not errors. They are part of the product when made visible
and auditable.

## Analysis State

`AnalysisState` supersedes the design doc's sketch `AnalysisUnit`
(`docs/agnostic-static-analysis-design.md`, "Core Shape"). It is the same object
refined: two fields moved off it because they describe a check request, not a
persistent analysis state. `semantics_id` and `inputs` now live on
`CheckRequest` (the registry selects the semantics, and inputs are request
parameters), so they are not state fields. The trust-collection field is named
`trust_boundaries` here and in the design doc; earlier drafts wrote
`trusted_boundaries`, which is dropped.

The state of an analysis run is:

```text
AnalysisState {
  artifacts,
  observations,
  claims,
  evidence,
  trust_boundaries,
  accepted,
  rejected,
  unknown
}
```

The substrate distinguishes three result classes. This section answers open
question 6 in the design doc (failed vs unknown vs trusted claim):

- `accepted`: evidence was checked or explicitly trusted under policy;
- `rejected`: evidence was checked and refused — it failed, or a counterexample
  was accepted;
- `unknown`: no accepted evidence exists and no rejection proof exists.

This trichotomy classifies *evidence outcomes*, not hosted truth. `rejected`
means "evidence was checked and refused", never "the claim is false". The
propositional pass discovered the boundary that fixes this: whether a hosted
contradiction makes a *claim* rejected is hosted policy, never a substrate rule
(see `docs/agnostic-static-analysis-prop-logic.md`, `contradiction`). The
substrate only reports what happened to the evidence; hosted semantics decide
what that means for truth.

`unknown` is not `accepted`. It cannot be consumed as proof by another claim
unless a hosted semantics explicitly admits unknown-as-input through a visible
rule or trust boundary.

## Checker Interface

A checker consumes:

```text
CheckRequest {
  state,
  requested_claims,
  semantics_registry,
  trust_policy
}
```

It produces:

```text
CheckResult {
  accepted_claims,
  rejected_claims,
  unknown_claims,
  diagnostics,
  dependency_graph,
  trust_summary
}
```

This interface deliberately says nothing about inference. A producer may
populate `state.claims` and `state.evidence` before checking, or the checker may
invoke a producer under a policy. Either way, accepted claims must still carry
evidence and trust summaries.

### Check loop: dependency-driven worklist

Evidence may arrive in arbitrary order, so the checker finds a valid acceptance
order by reaching a fixpoint over the *accepted* set: an evidence object whose
inputs are not yet accepted yields `unknown` and is retried once more of its
inputs resolve. The discipline is a **dependency-driven worklist**, and this is a
performance refinement of the same semantics, not a different one.

The soundness premise is a substrate-level invariant on what an evidence verdict
can depend on: an evidence object's result is a function of its claim (static),
its claim's args (static), and *which of its declared `inputs` are accepted* — a
hosted checker reads accepted-ness only by querying its own input Ids (in the
mechanization, `ctx.is_accepted(ev.inputs[k])` / `accepted_result`, never an
undeclared claim). Therefore the *only* event that can flip a pending evidence
from `unknown` to `accepted`/`rejected` is one of **its input claims** becoming
accepted.

The loop exploits this directly. It builds, once, a `dependents` index mapping
each claim (by its structural key) to the evidence whose inputs reference it. It
seeds a queue with every evidence object exactly once; when an evidence accepts
its claim, it re-queues only that claim's dependents. Evidence with no
newly-available input is never re-examined. This replaces the earlier
re-sweep-everything fixpoint — O(rounds × evidence) — with work proportional to
the dependency edges actually traversed.

The refinement preserves every checking property the re-sweep had, and the
unchanged test corpus across all six hosted semantics (propositional, lambda,
dataflow, STLC, the Crescent slice, plus the substrate probes) is the validation
that it is the *same* semantics:

- **Same classification.** Identical accepted / rejected / unknown partition; the
  worklist drains to the same closure the re-sweep reached.
- **Order-independence preserved.** The closure is independent of evidence
  insertion order (the shuffled-order tests are the load-bearing guard); the queue
  reorders work but not the result.
- **Cycle-as-error preserved.** Mutually-blocked evidence is never re-queued by an
  acceptance, settles `unknown`, and is reported by the same cycle-detection pass
  (the cycle tests are the other load-bearing guard) — never nontermination.
- **Unknown-propagation preserved.** `unknown` is still never consumed as proof;
  an evidence stays pending until *its own* inputs are accepted.

A companion micro-refinement memoizes each claim's structural key per check (the
key is constant within a check, so serializing the — potentially deep — args once
per claim rather than once per accepted-ness probe is byte-identical and removes
the substrate's dominant per-probe cost on large graphs). A further refinement
content-addresses the key serialization itself: the serializer takes an optional
per-check intern table that memoizes each arg SUBTREE's serialization by table
identity, so a subtree reached more than once — the same encoded value recurring
across many claims and across the bindings of one deep context, the dominant shape
on lowered real files — serializes once for the whole check instead of once per
containing claim. This is an implementation of the existing structural identity,
not a new identity: with or without interning the key string is byte-identical, so
two claims are the same claim iff their structural serialization is equal, exactly
as before; interning only avoids recomputing equal serializations. It is sound on
the documented invariant that claim args are immutable once constructed (the same
invariant the per-claim key memo and the hosted decode cache already rely on), and
it leaks nothing — the intern table is per-check (dropped when the check returns)
and weak-keyed. None of these refinements introduces any knowledge of a hosted
semantics: all speak only claims, evidence, inputs, dependencies, and structural
keys.

## Semantics Registry

A semantics registry maps a semantics identifier to its checker obligations.

```text
SemanticsEntry {
  id,
  version,
  claim_predicates,
  observation_predicates,
  evidence_methods,
  checker,
  trusted_methods
}
```

The registry is not a language spec by itself. It says how to validate claims
for a hosted semantics.

The first implementation may encode each `checker` as ordinary Lua code. A
later mechanized version may encode some entries in a proof assistant. The
object model should support both without changing accepted-claim semantics.

### Open item: claim-arg schemas vs structural identity

`SemanticsEntry` has no slot for the *shape* of claim arguments. Hosted
semantics define recursive value grammars for their args in prose — the
propositional pass defines `Prop`, the lambda pass defines `LamTerm` — but the
substrate has no arg-schema mechanism and instead compares args structurally for
claim identity. This is a named gap, not a proposal: do not invent a schema
mechanism here.

The divergence the gap creates is structural-identity-vs-hosted-identity. The
substrate's structural comparison treats `lam("x", var("x"))` and
`lam("y", var("y"))` as distinct claim args, but the lambda semantics treats
them as alpha-equal. A hosted semantics whose notion of claim identity is finer
or coarser than structural equality (alpha-equality being the canonical case)
will not get the identity it expects from the substrate by default. Whether that
matters — and how a hosted semantics is allowed to override claim identity — is a
known divergence the mechanization must probe, not something the prose can
settle.

#### Mechanization findings (lib/type/analysis)

The mechanization (`lib/type/analysis/`) settled the open questions this gap
posed, by running them rather than reasoning about them:

1. **Claim identity is purely structural; symmetry is hosted business.** The
   substrate decides claim identity by serializing `(semantics, predicate, args)`
   canonically (`init.lua`, `claim_key`/`_serialize`) and never consults a hosted
   semantics for a finer/coarser notion. So `alpha_eq(t1, t2)` and
   `alpha_eq(t2, t1)` are **distinct** substrate claims even though the lambda
   semantics regards them as the same fact (`substrate_test.lua`, the
   claim-identity probe asserts `claim_key(c12) ~= claim_key(c21)`). This is the
   substrate behavior the object model implies — the substrate must not impose a
   hosted equivalence it does not understand — and the lambda checker handles
   symmetry inside its own evidence (alpha-normal-form comparison), never by
   asking the substrate to treat swapped args as one claim. Recorded here as the
   chosen resolution of the structural-vs-hosted-identity divergence: structural
   wins at the substrate; hosted identity lives in the hosted checker.

2. **`unknown` (TS-unknown) is the wrong substrate type for opaque args.** The
   first attempt typed `Claim.args` as `unknown`. The Crescent typechecker then
   forbids *both* checked-casting away from `unknown` (it is not a subtype of any
   record) *and* force-casting away from it (force casts past `unknown` are a hard
   error). A hosted semantics literally could not read its own args back. The fix
   is the `ArgValue` type (`init.lua`): "arbitrary serializable data" —
   `nil | boolean | number | string | { [string]: ArgValue } | { [integer]:
   ArgValue }`. This is the honest substrate boundary: args are *data the
   substrate can serialize and compare*, never functions/threads. It is not a lazy
   permissive alias — it states exactly what the substrate needs and nothing
   about the hosted grammar.

3. **The opaque-data boundary forces hosted semantics to *parse*, not cast — and
   that is what the trust obligation wanted.** Even from `ArgValue`, the
   typechecker rejects a force cast of an index-signature table down to a
   named-field record. So a hosted checker cannot blind-cast `args` into its
   grammar; it must validate and reconstruct (`prop.lua` `parse_prop`,
   `lambda.lua` `parse_term`) via `type()`-narrowing and tag-dispatch, returning
   `nil` on malformed input. This is *stronger* than a cast and is precisely the
   hosted-checker trust discipline: the checker validates its own inputs rather
   than trusting their shape. The adversarial `type_of`-as-a-Prop probe is
   rejected by exactly this parser, with no substrate special-casing.

4. **STLC closes the open item: no schema mechanism and no claim-identity
   override is needed; two hosted identity notions coexist over the one
   structural substrate identity.** The STLC rung
   (`docs/agnostic-static-analysis-stlc.md`) put hosted `type` vocabulary and
   typing contexts inside claim args — the pressure this open item named. Two
   findings settle it. (a) **Types and contexts parse-not-cast like every prior
   grammar.** Arrow types and context lists are `ArgValue` data validated at the
   checker boundary (`stlc.lua` `parse_type`/`parse_ctx`); the substrate stored no
   `Type`/`Context`/`Judgment` object kind (asserted by walking the state). (b)
   **Structural substrate identity is the *right* notion for context-dependent
   judgments — the complement of the alpha case.** For terms, structural identity
   is *finer* than hosted alpha-equivalence, and the hosted checker reconciles the
   gap in its own evidence (lambda's alpha-normal-form comparison; STLC simply
   derives each alpha-variant judgment independently and never asks the substrate
   to merge them). For typing contexts, structural identity *equals* the hosted
   notion: two judgments are the same fact iff their Γ is structurally the same
   ordered list (binding order and shadowing are significant, and the substrate
   gets this for free). So the divergence this item worried about is real for one
   hosted notion (alpha) and absent for another (contexts/types), and **both live
   over the single structural substrate identity without the substrate learning
   either**. The chosen resolution stands: structural wins at the substrate;
   any finer hosted identity is reconciled inside the hosted checker's evidence,
   never by a substrate schema or identity-override mechanism. Do not add one on
   STLC's account.

## What Is Not In The Substrate Yet

These are intentionally absent:

- syntax categories;
- term heads;
- binders;
- alpha-equivalence;
- substitution;
- subtyping;
- effects;
- heap/state models;
- fixed-point solvers;
- type variables;
- module environments.

They are not rejected. They are withheld until a validation semantics forces
them to become substrate-level rather than hosted vocabulary.

### Removed: Claim.scope

An earlier draft gave `Claim` an opaque `scope?` slot, documented as a future
home for lexical scope, path conditions, dataflow point, module context, and
proof assumptions. Review found this is a withheld primitive in disguise: those
documented tenants are exactly the hosted vocabulary this design withholds, and
neither validation pass (propositional, lambda) uses the slot. Hosted semantics
already encode any such context inside `args` — both passes do. The slot is
removed.

The rule: if a future validation pass forces a context slot, it must be
justified then, as universal to all static analysis. It does not get
pre-reserved. A speculative slot whose only tenants are hosted concepts is
withheld vocabulary, not substrate.

### Removed: Observation.support derived

An earlier draft listed `derived` ("accepted from other observations or claims")
as a fourth `Observation.support` value. It is removed under the same
withhold-until-forced discipline. `derived` overlaps with the Claim+Evidence
machinery — an observation accepted from other claims is a claim with evidence,
not a new support kind — and neither validation pass exercised it. The remaining
support values (`checked`, `trusted`, `assumed`) are the ones the passes use.

## Design Obligation: Hosted-Checker Trust

The substrate trusts each hosted checker's verdict. A checker is arbitrary Lua
(`SemanticsEntry.checker`). This is the structural hole the agnostic direction
must watch: ad-hoc accumulation — the documented root cause of the v1→v4
failure — can relocate *inside* a checker, where the substrate cannot see it. A
checker that quietly special-cases, or runs unchecked inference and reports
"accepted", launders untrusted computation through the substrate's trust.

The rejected framework had a structural defense here that these docs initially
dropped: only the framework checker and the declarative theory spec were
trusted; everything else was checked evidence or an explicit oracle boundary
(`docs/typechecker-framework.md`, "Core Distinction"). The agnostic substrate
must re-state that defense for checkers explicitly, applying the design doc's own
non-negotiable — *inference engines and solvers are untrusted producers unless
their outputs are checked* — to checkers themselves.

Obligations:

- Hosted checkers must be small and auditable, driven by declarative rule data
  wherever a rule can be data.
- Any computation that cannot be declarative must appear either as evidence
  whose outputs the checker checks, or as an explicit trusted-oracle boundary
  recorded in the trust summary. It must not hide inside the checker as
  unaccounted-for "the checker just knows this".
- Every trust summary must carry a slot for "verdict produced by an unverified
  hosted checker" until checkers are mechanized. While a checker is hand-written
  Lua, its verdicts are a trusted boundary, and that trust must be visible in the
  same way every other trusted boundary is.

This obligation is the reason mechanization starts now rather than after more
paper passes: a paper checker cannot be audited for the failure it is meant to
prevent.

## First Concrete Validation

The first validation semantics should be propositional logic.

Reasons:

- no program language;
- no binders;
- no types;
- no dataflow;
- no mutation;
- enough structure to test claims, evidence, dependencies, trusted assumptions,
  accepted/rejected/unknown, and diagnostics.

Minimal predicates:

```text
prop(name)
and(a, b)
implies(a, b)
not(a)
```

Minimal evidence methods:

```text
assumption
and_intro
and_elim_left
and_elim_right
modus_ponens
contradiction
trusted_axiom
```

This is not because propositional logic is the end goal. It is the smallest
test that can falsify the object model without importing language-specific
machinery.

## Next Pass

The next pass should specify the propositional validation semantics using this
object model, including:

- exact claim predicates;
- exact evidence methods;
- dependency recording;
- trust summary behavior;
- accepted/rejected/unknown examples;
- one adversarial example that tries to smuggle a typechecker concept into the
  substrate.

Current propositional validation pass:
`docs/agnostic-static-analysis-prop-logic.md`.
