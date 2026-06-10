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
- optional accepted `not_free_in` claims needed by the hosted substitution
  algorithm if it uses source-name capture checks;
- artifact content for both terms.

The hosted checker may alpha-rename internally before substitution. If it
cannot prove capture avoidance under its chosen representation, the evidence
rejects.

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

## Next Pass

The next validation pass should be STLC only after the object model survives
this binding pressure. STLC may introduce hosted `type` claims, but it must not
promote `type`, `context`, `binder`, substitution, or derivation replay into
substrate primitives by default.
