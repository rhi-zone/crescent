# Typechecker Framework First-Order Replay

This document specifies F3: first-order rule replay for the framework checker.

F3 is the first milestone that accepts evidence nodes. It intentionally excludes
binders, scoped destructuring, substitution, and oracles.

## Scope

Included:

- F0 object format;
- F1 canonicalization;
- F2 shape validation;
- rule applications;
- fixed-arity constructor patterns;
- `input` metavariables only;
- ordered premises;
- root validation over accepted evidence.

Excluded:

- binders;
- scoped values;
- scoped claims;
- `output` metavariables;
- `fresh` metavariables;
- syntactic substitution;
- alpha-equivalence beyond literal structural equality;
- oracle applications;
- commutative premise sets;
- proof search.

F3 is enough for a tiny combinator theory. It is not enough for STLC.

## Inputs

```text
ReplayInput {
  shape_ok,
  theory_spec,
  certificate
}
```

F3 assumes F2 has already accepted the theory and certificate shapes.

## Outputs

```text
ReplayResult =
  ReplayAccepted { root_digests }
| ReplayRejected { errors }
```

An accepted root means every reachable evidence node needed by that root
replayed under the declared theory rules.

## F3 Rule Subset

F3 admits only rules where:

- every metavariable has `mode = "input"`;
- no metavariable has `kind = "binder"`, `kind = "bound_ref"`, or
  `kind = "scoped"`;
- no premise uses `scope_from`;
- no structural condition is `cond_subst`, `cond_alpha_eq`,
  `cond_binder_eq`, or `cond_binder_neq`;
- every pattern is first-order and fixed shape;
- every premise is ordered.

Rules outside this subset are shape-valid F0/F2 objects but rejected as
unsupported by F3 replay.

## Replay Order

F3 computes a topological order from evidence premise references.

Reject:

- missing premise references;
- cycles;
- duplicate premise IDs in one rule application;
- premise nodes that failed replay;
- oracle applications.

Certificate source order is not semantic.

## Rule Application Replay

For an evidence node with:

```text
RuleApplication {
  rule,
  premises
}
```

F3:

1. Finds the declared rule.
2. Checks the rule is in the F3 subset.
3. Checks the evidence node `judgment` equals the rule judgment.
4. Matches the evidence claim against the rule conclusion pattern.
5. Matches each premise evidence claim against the corresponding premise
   pattern in order.
6. Accumulates metavariable bindings.
7. Checks repeated metavariable occurrences for structural equality.
8. Checks F3-admitted structural conditions.
9. Marks the evidence node accepted if every check passes.

F3 never tries another rule. The certificate names the rule.

## Pattern Matching

Pattern matching is deterministic and left-to-right.

F3 supports:

```text
p_meta
p_term
p_list
p_object
p_literal
p_enum
```

F3 rejects:

```text
p_scoped
p_binder_ref
p_bound_ref
```

because binder, bound-reference, and scoped replay start in F4.

## Metavariable Binding

`p_meta(name)` binds the whole value if `name` is unbound.

If `name` is already bound, the candidate value must be structurally equal to
the prior binding.

Structural equality in F3 is exact projected syntax equality:

- same tags;
- same term heads;
- same field names;
- same array lengths and order;
- same scalar values;

F3 does not perform alpha-equivalence. F4 replaces bound-reference label
equality with alpha-stable binder identity checks.

## Constructor Patterns

For `p_term`:

- candidate value must be a term;
- term head must match;
- pattern fields must exactly match the term-head field set;
- each field matches recursively.

For `p_list`:

- candidate value must be a list;
- list length must match;
- elements match pairwise in order.

For `p_object`:

- candidate value must be an object;
- field sets must match exactly;
- fields match recursively.

F3 does not admit rest fields, optional fields, unordered fields, or associative
matching.

## Structural Conditions

F3 admits:

- `cond_category_eq`;
- `cond_literal_eq`;
- `cond_list_len_eq`;
- `cond_digest_eq`.

F3 rejects:

- `cond_binder_eq`;
- `cond_binder_neq`;
- `cond_alpha_eq`;
- `cond_subst`.

F3 executes admitted conditions only over already-bound metavariables or fields
selected during pattern matching.

## Root Validation

For each root:

1. Find the root declaration.
2. Find the referenced evidence node.
3. Require the evidence node to be accepted.
4. Require evidence node judgment to equal the root required judgment.
5. Match the evidence claim against the root required claim pattern.
6. Enforce `scope_policy`.
7. Compute the F1 root digest.

In F3, `scope_policy = closed` means `claim.scope` must be empty and no scoped
values may appear in the root claim.

## Diagnostics

Minimum F3 diagnostics:

- unsupported rule feature;
- dependency cycle;
- duplicate premise reference;
- premise replay failure;
- rule judgment mismatch;
- premise arity mismatch;
- conclusion pattern mismatch;
- premise pattern mismatch;
- repeated metavariable mismatch;
- unsupported pattern form;
- unsupported structural condition;
- root references rejected node;
- root claim mismatch;
- root scope-policy failure.

## Combinator Validation Theory

The first F3 fixture theory should avoid binders entirely.

Categories:

```text
Ty
Term
```

Term heads:

```text
TyUnit
TyArrow(param: Ty, result: Ty)

TmUnit
TmConst(name: string)
TmApp(fn: Term, arg: Term)
```

Judgment:

```text
HasType(term: Term, ty: Ty)
```

Rules:

```text
const_id:
  -----------------------------
  HasType(TmConst("id_unit"), TyArrow(TyUnit, TyUnit))

unit_intro:
  ----------------------
  HasType(TmUnit, TyUnit)

app:
  HasType(fn, TyArrow(A, B))
  HasType(arg, A)
  ---------------------------
  HasType(TmApp(fn, arg), B)
```

Accepted fixture:

```text
HasType(TmApp(TmConst("id_unit"), TmUnit), TyUnit)
```

Rejected fixtures:

- app premise order swapped;
- app result claims wrong return type;
- unknown rule name;
- repeated metavariable mismatch for argument type;
- root points at an unreplayed/rejected node.

## F3 Acceptance

F3 is complete when:

- the combinator accepted fixture replays;
- all rejected combinator fixtures fail for the expected diagnostic category;
- changing source order without changing dependency edges preserves root digest;
- changing premise order changes the evidence/root digest for ordered rules;
- unreachable accepted evidence does not change root digest;
- unreachable evidence does change certificate digest.
