# Agnostic Static Analysis: Untyped Lambda Validation

Status: validation design pass.

This document instantiates `docs/agnostic-static-analysis-object-model.md` with
an untyped lambda-calculus semantics. Its purpose is to test artifact structure,
binding, alpha-equivalence, substitution pressure, and evaluation claims without
admitting `type` as a substrate concept.

This is not a typechecker. It is a hosted semantics that happens to reason
about terms.

## Scope

Included:

- artifact-backed terms;
- hosted binding representation;
- alpha-equivalence claims;
- free-variable claims;
- one-step beta-reduction claims;
- dependency recording over term artifacts and evidence inputs.

Excluded:

- types;
- typed contexts;
- subtyping;
- effects;
- store;
- source-language parsing;
- Crescent/Lua semantics;
- substrate-level binders.

## Design Pressure

The propositional validation pass had no artifact structure. Lambda calculus is
the smallest useful next stress test because it forces a decision about binding
without letting the substrate inherit the rejected framework's binder model.

The intended result is:

```text
binding is hosted vocabulary, but the substrate can still track claims,
evidence, dependencies, trust, and unknown/rejected results
```

If this pass requires adding `Binder`, `Scope`, `Term`, or `AlphaRef` as
substrate primitives, the agnostic design has failed or the object model is too
weak.

## Semantics Entry

```text
SemanticsEntry {
  id = "lambda.untyped.min",
  version = "0",
  claim_predicates = [
    "well_formed",
    "alpha_eq",
    "free_in",
    "not_free_in",
    "steps_to"
  ],
  observation_predicates = [
    "term_shape"
  ],
  evidence_methods = [
    "artifact_shape_check",
    "alpha_normal_form",
    "free_var_scan",
    "beta_step",
    "trusted_term"
  ],
  trusted_methods = [
    "trusted_term"
  ]
}
```

The substrate does not interpret these predicates. The lambda semantics owns
their meaning.

## Artifact Shape

A lambda artifact may contain a term graph or tree:

```text
LamTerm =
  var(name)
| lam(param, body)
| app(fn, arg)
```

`name` and `param` are source labels in the artifact. They are not substrate
identities and are not semantically stable binder identities by themselves.

The hosted lambda checker may convert the artifact into a local representation,
such as de Bruijn indices, locally nameless terms, nominal terms, or explicit
environment closures. That representation is evidence-local unless later
promoted by a derivation.

## Observations

The basic observation predicate is:

```text
term_shape(term_ref, shape)
```

Examples:

```text
term_shape(t1, var("x"))
term_shape(t2, lam("x", t_body))
term_shape(t3, app(t_fn, t_arg))
```

Observation support may be:

- `checked`: the checker read the artifact content and verified the shape;
- `trusted`: an external term artifact was admitted by a visible boundary.

The substrate only records the observation and its support. It does not know
that `lam` binds `x`.

## Claim Forms

### well_formed

```text
well_formed(term_ref)
```

The term artifact is valid lambda syntax under the selected representation.

This is a structural claim. It does not imply the term terminates, normalizes,
has a type, or is closed.

### alpha_eq

```text
alpha_eq(left_term_ref, right_term_ref)
```

The two terms are alpha-equivalent under the hosted lambda semantics.

The evidence may use any checked alpha-normal representation, but the substrate
does not define that representation.

### free_in

```text
free_in(name, term_ref)
```

The source-level variable name appears free in the term.

This claim is deliberately source-label based. A richer hosted semantics could
use declaration identities instead, but the substrate does not choose.

### not_free_in

```text
not_free_in(name, term_ref)
```

The source-level variable name does not appear free in the term.

`not_free_in` is a positive claim with evidence. It is not inferred from absence
of `free_in` unless the hosted semantics provides a complete free-variable
analysis for the term.

### steps_to

```text
steps_to(source_term_ref, target_term_ref)
```

The source term performs one evaluation step to the target term.

This first validation pass only admits call-by-name beta at the outermost
redex:

```text
app(lam(x, body), arg) -> substitute(body, x, arg)
```

The evaluation strategy is hosted semantics. The substrate must not learn
call-by-name, call-by-value, beta-reduction, substitution, or normalization.

## Evidence Methods

### artifact_shape_check

Validates `well_formed(term_ref)` by checking the artifact's lambda shape.

Dependencies:

- artifact content dependency on the term artifact;
- observation dependencies for each checked `term_shape`.

Rejection:

- malformed term artifact rejects the evidence;
- the requested claim may remain unknown if another trusted term source exists.

### alpha_normal_form

Validates `alpha_eq(left, right)` by computing a hosted alpha-normal form for
both terms and comparing them.

Dependencies:

- accepted `well_formed(left)`;
- accepted `well_formed(right)`;
- artifact content dependencies for both terms;
- trust dependencies inherited from the well-formedness claims.

Rejection:

- unequal normal forms reject the evidence, not the possibility that a
  different alpha-equivalence method could exist.

### free_var_scan

Validates `free_in(name, term)` or `not_free_in(name, term)` by scanning the
hosted term representation under binding.

Dependencies:

- accepted `well_formed(term)`;
- artifact content dependency on the term artifact.

Design point:

- `free_in` and `not_free_in` are separate positive claims. `unknown` for one is
  not acceptance of the other.

### beta_step

Validates `steps_to(source, target)` for one outermost beta step.

Inputs:

- accepted `well_formed(source)`;
- accepted `well_formed(target)`;
- the `not_free_in` claims the registry pins for this semantics version (see
  below);
- artifact content for both terms.

The hosted checker may alpha-rename internally before substitution. If it
cannot prove capture avoidance under its chosen representation, the evidence
rejects.

The `not_free_in` inputs are not "optional, if the checker uses source-name
capture checks". A registry contract must pin the input requirements per
semantics version, not leave them contingent on the checker's internal
representation. A consumer scheduling evidence cannot see inside the checker, so
"depends on how the checker is written" is not a contract it can satisfy. For
`lambda.untyped.min` version `0`, the pinned rule is: `beta_step` requires an
accepted `not_free_in(name, source)` for every name that occurs free in the
argument and is bound by a lambda the substitution descends under. Capture
avoidance is thereby a checkable cross-evidence dependency, produced by a
separate `free_var_scan`, not an internal detail of the substitution code.

Dependencies:

- source and target artifact content;
- well-formedness claims;
- any free-variable claims consumed by the substitution witness.

### trusted_term

Accepts `well_formed(term_ref)` through a visible trust boundary.

Dependencies:

- trusted-boundary dependency.

Trust:

- trust summary includes the source of the term and the admission policy.

## Examples

### Alpha Acceptance

Artifacts:

```text
t1 = lam("x", var("x"))
t2 = lam("y", var("y"))
```

Claims:

```text
c1 = well_formed(t1)
c2 = well_formed(t2)
c3 = alpha_eq(t1, t2)
```

Evidence:

```text
e1 = artifact_shape_check(c1)
e2 = artifact_shape_check(c2)
e3 = alpha_normal_form(c3, inputs = [e1, e2])
```

Result:

```text
accepted: c1, c2, c3
dependencies(c3): [c1, c2, artifact(t1), artifact(t2)]
trust_summary(c3): []
```

### Beta Acceptance

Artifacts:

```text
source = app(lam("x", var("x")), var("z"))
target = var("z")
```

Claims:

```text
c_source = well_formed(source)
c_target = well_formed(target)
c_step   = steps_to(source, target)
```

Evidence:

```text
e_source = artifact_shape_check(c_source)
e_target = artifact_shape_check(c_target)
e_step   = beta_step(c_step, inputs = [e_source, e_target])
```

Result:

```text
accepted: c_source, c_target, c_step
```

### Beta With Capture Avoidance

This example forces the cross-evidence dependency the pinned `beta_step`
contract exists for.

Artifacts:

```text
source = app(lam("x", lam("y", var("x"))), var("y"))
target = lam("y1", var("y"))
```

The redex is `(λx. λy. x) y`. Beta substitutes `x := y` into `λy. x`. Naive
substitution would yield `λy. y`: the free `y` from the argument is captured by
the inner binder `y`. The correct capture-avoiding result alpha-renames the
inner binder to a fresh name, here `y1`, giving `λy1. y` where the body `y` is
the free argument variable, still free.

The hosted checker must alpha-rename. Under the pinned contract, because the
argument `var("y")` is free with name `y` and the substitution descends under a
lambda binding `y`, `beta_step` requires an accepted `not_free_in` discharge for
the renamed binder — and consumes a `free_in("y", arg)` claim establishing the
collision that forces the rename. That free-variable fact is produced by
*separate* evidence (`free_var_scan`), not by the substitution step itself.

Claims:

```text
c_source = well_formed(source)
c_target = well_formed(target)
c_arg_fy = free_in("y", arg_ref)        -- arg_ref is the var("y") subterm
c_step   = steps_to(source, target)
```

Evidence:

```text
e_source = artifact_shape_check(c_source)
e_target = artifact_shape_check(c_target)
e_arg_fy = free_var_scan(c_arg_fy)
e_step   = beta_step(c_step, inputs = [e_source, e_target, e_arg_fy])
```

Result:

```text
accepted: c_source, c_target, c_arg_fy, c_step
dependencies(c_step): [
  c_source, c_target,
  c_arg_fy,                      -- cross-evidence free-variable dependency
  artifact(source), artifact(target)
]
```

The `c_arg_fy` entry in `dependencies(c_step)` is the load-bearing point: the
capture-avoidance obligation is discharged by a claim from a different evidence
object, recorded as an accepted-claim dependency, not hidden inside the
substitution code.

Design pressure: the `Dependency` shape expresses this cleanly because the
free-variable fact is itself a claim, and `Dependency.kind = accepted_claim`
already covers "this step relies on another accepted claim". What `Dependency`
does *not* express is the *role* the dependency plays — that `c_arg_fy` is a
capture-avoidance side condition rather than a structural premise. The substrate
records that `c_step` depends on `c_arg_fy`, but not *why*. For `lambda.untyped.min`
that is acceptable because the pinned registry contract names the role; a hosted
semantics with many distinct side-condition kinds may find the unrole'd
dependency edge too coarse for diagnostics. That is a finding for the
mechanization to probe, not a defect of this pass.

### Unknown Is Not Negative

Claim:

```text
free_in("x", t)
```

If no evidence is supplied, the result is:

```text
unknown: free_in("x", t)
```

This does not accept:

```text
not_free_in("x", t)
```

and it does not reject `free_in("x", t)`.

### Rejected Evidence

Claim:

```text
steps_to(app(lam("x", var("x")), var("z")), var("w"))
```

`beta_step` evidence rejects because the target does not match the substitution
result.

Result:

```text
rejected evidence: beta_step(...)
unknown claim: steps_to(source, target)
```

The failed evidence is not proof that no other evaluation relation could step
to `target`; it only fails under `lambda.untyped.min`.

## Adversarial Checks

### Do Not Promote Binders

Attempt:

```text
Id(space = "binder", local = "x")
```

as a substrate-level semantic identity.

This is rejected for the substrate. Binder identity belongs to the hosted lambda
semantics. The substrate may store opaque IDs, but it must not assign binding
meaning to `space = "binder"`.

### Do Not Promote Types

Attempt:

```text
has_type(t, T)
```

inside `lambda.untyped.min`.

This is rejected by the hosted semantics because `has_type` is not a claim
predicate in this semantics. A later STLC hosted semantics may add such a
predicate without changing the substrate.

### Do Not Inherit Framework Replay

Attempt:

```text
scope_from(lambda_body)
```

as evidence machinery.

This is rejected. The hosted lambda checker may open a lambda internally, but
the substrate should only see claims, evidence inputs, dependencies, and trust
summaries.

## Design Pressure Found

This pass forces these distinctions:

- artifact structure is not the same as substrate syntax;
- hosted binding is not substrate binding;
- alpha-equivalence can be checked without making alpha-normal forms part of
  the global object model;
- failed reduction evidence is not proof that a claim is false;
- source labels are not semantic identities unless a hosted semantics says so.

It also exposes one registry rule: a semantics registry must not list evidence
methods that are not actually admitted in that version. The registry is a
checker contract, not a wish list. For that reason `congruence` is deliberately
absent until a later validation pass specifies evaluation contexts or a
concrete strategy rule.

## Mechanization Findings (lib/type/analysis)

The lambda rung was mechanized (`lib/type/analysis/lambda.lua`,
`lambda_test.lua`). Every worked example above is a test. The mechanization
falsified one paper assumption and confirmed the rest:

- **A required-but-not-yet-accepted input must yield `unknown` (retry), never
  `rejected`.** This is the falsification. The paper hand-orders evidence so the
  capture-avoidance `free_in` discharge is always available when `beta_step`
  runs. The first mechanized `beta_step` returned `rejected` when the discharge
  claim was present but not yet accepted — which made the result *order-
  dependent*: it passed when the substrate's `pairs()` sweep happened to accept
  the `free_var_scan` evidence first, and failed otherwise. The fix distinguishes
  three cases for each colliding binder: discharge present and accepted →
  discharged; present but not yet accepted → return `unknown` so the worklist
  retries; absent entirely → `rejected` (contract unsatisfiable). With that fix,
  shuffled submission orders yield identical results (asserted across orders in
  `substrate_test.lua` and over 60 randomized in-process iterations). This is
  exactly the scheduling property the design said paper passes cannot falsify
  because the author hand-orders the inputs.

- **The capture-avoidance cross-evidence dependency records cleanly, as the doc
  predicted.** `beta_step` consumes the `free_in("y", arg)` claim produced by a
  *separate* `free_var_scan`, and the result's `dependency_graph` carries the
  `accepted_claim` edge from `c_step` to `c_arg_fy` (asserted in
  `lambda_test.lua`). The capture-avoiding reduction produces `lam y1. y`, alpha-
  equal to the doc's target and correctly *not* alpha-equal to the naive
  capturing `lam y. y`.

- **The unrole'd-dependency observation holds.** `Dependency.kind =
  accepted_claim` records *that* `c_step` depends on `c_arg_fy` but not the
  *role* (capture-avoidance side condition vs structural premise). For
  `lambda.untyped.min` the pinned registry contract names the role, so the coarse
  edge is acceptable, as the paper said. A hosted semantics with many distinct
  side-condition kinds would want a role on the edge; that remains a future-pass
  finding, not a defect here.

- **The substrate never stored a binder or scope object.** An adversarial test
  walks every Id stored in the analysis state after running the alpha example and
  asserts each lives in a substrate-owned space (`artifact`/`claim`/`ev`/`trust`/
  `observation`) — never `binder` or `scope`. The lambda checker keeps de-Bruijn-
  free alpha-normalization, substitution, and the fresh-name supply entirely
  evidence-local.

## Next Pass

STLC was the next validation pass and is now mechanized
(`docs/agnostic-static-analysis-stlc.md`, `lib/type/analysis/stlc.lua`). It
introduced hosted `type` claims, typing contexts, and deep derivation trees
without promoting `type`, `context`, `binder`, or derivation replay into
substrate primitives — substrate unchanged. The remaining concern this rung
flagged (binders interacting with typing contexts) is resolved there: contexts
are hosted data inside claim args, and structural substrate claim identity is the
correct notion for context-dependent judgments. The rung after STLC is a tiny
Crescent slice, not another synthetic calculus.
