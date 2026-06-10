# Agnostic Static Analysis: Propositional Validation

Status: validation design pass.

This document instantiates `docs/agnostic-static-analysis-object-model.md` with
a tiny propositional semantics. Its purpose is to test the substrate vocabulary
without importing programs, types, binders, dataflow, or Crescent semantics.

## Scope

Included:

- claim identity;
- evidence methods;
- dependency recording;
- trusted assumptions;
- accepted, rejected, and unknown results.

Excluded:

- syntax trees;
- source spans;
- binders;
- type judgments;
- solver search;
- language-specific diagnostics.

## Semantics Entry

```text
SemanticsEntry {
  id = "prop.logic.min",
  version = "0",
  claim_predicates = [
    "holds"
  ],
  observation_predicates = [],
  evidence_methods = [
    "assumption",
    "trusted_axiom",
    "and_intro",
    "and_elim_left",
    "and_elim_right",
    "modus_ponens",
    "contradiction"
  ],
  trusted_methods = [
    "trusted_axiom"
  ]
}
```

This semantics has no observations because its artifacts may be empty. The
claims themselves carry proposition values.

## Proposition Values

The hosted semantics owns proposition syntax:

```text
Prop =
  atom(name)
| and(left, right)
| implies(left, right)
| not(inner)
```

The substrate treats these as opaque claim arguments. It may store and compare
them structurally for identity, but it does not know their logic.

## Claim Form

The only claim predicate is:

```text
holds(prop)
```

Examples:

```text
holds(atom("A"))
holds(and(atom("A"), atom("B")))
holds(implies(atom("A"), atom("B")))
holds(not(atom("A")))
```

No claim means "false" by absence. Absence is `unknown`, not rejection.

## Evidence Methods

### assumption

`assumption` accepts `holds(P)` only inside an evidence scope that explicitly
admits `P` as an assumption.

Dependencies:

- `assumption` dependency on the enclosing evidence scope.

Trust:

- no trust boundary by itself.

### trusted_axiom

`trusted_axiom` accepts `holds(P)` through a visible trust boundary.

Dependencies:

- `trusted_boundary` dependency on the axiom boundary.

Trust:

- trust summary includes the boundary ID, issuer, policy, and payload digest if
  present.

### and_intro

`and_intro` accepts:

```text
holds(and(A, B))
```

when inputs include accepted evidence for:

```text
holds(A)
holds(B)
```

Dependencies:

- accepted-claim dependency on both inputs.

### and_elim_left

`and_elim_left` accepts:

```text
holds(A)
```

when input includes accepted evidence for:

```text
holds(and(A, B))
```

Dependencies:

- accepted-claim dependency on the conjunction input.

### and_elim_right

`and_elim_right` accepts:

```text
holds(B)
```

when input includes accepted evidence for:

```text
holds(and(A, B))
```

Dependencies:

- accepted-claim dependency on the conjunction input.

### modus_ponens

`modus_ponens` accepts:

```text
holds(B)
```

when inputs include accepted evidence for:

```text
holds(A)
holds(implies(A, B))
```

Dependencies:

- accepted-claim dependency on both inputs.

### contradiction

`contradiction` rejects one of two incompatible requested claims when accepted
evidence exists for:

```text
holds(A)
holds(not(A))
```

This method is intentionally not explosion. It does not accept arbitrary `B`
from contradiction. It records an inconsistency diagnostic and rejects the
requested inconsistent claim set unless a hosted policy explicitly allows
inconsistent contexts.

Dependencies:

- accepted-claim dependency on both inconsistent inputs;
- rejection diagnostic dependency on the same inputs.

## Result Rules

For a requested claim:

- accepted: at least one evidence object validates the claim under the
  semantics and trust policy;
- rejected: evidence for the claim is malformed, its method is invalid, its
  dependencies fail, or contradiction rejects the requested set;
- unknown: no valid evidence is available and no rejection applies.

Malformed evidence is rejection of that evidence object. It rejects the claim
only when the check request requires that specific evidence object. Otherwise
the claim may remain unknown if another evidence object could exist.

## Example: Pure Acceptance

Artifacts:

```text
[]
```

Claims:

```text
cA  = holds(atom("A"))
cB  = holds(atom("B"))
cAB = holds(and(atom("A"), atom("B")))
```

Evidence:

```text
eA  = trusted_axiom(cA, trust = t1)
eB  = trusted_axiom(cB, trust = t2)
eAB = and_intro(cAB, inputs = [eA, eB])
```

Result:

```text
accepted: cA, cB, cAB
trust_summary(cAB): [t1, t2]
dependencies(cAB): [cA, cB, t1, t2]
```

## Example: Unknown Is Not Accepted

Claims:

```text
cA = holds(atom("A"))
```

Evidence:

```text
[]
```

Result:

```text
unknown: cA
accepted: []
rejected: []
```

No downstream evidence may consume `cA` as accepted.

## Example: Rejection

Claims:

```text
cB = holds(atom("B"))
```

Evidence:

```text
eB = modus_ponens(cB, inputs = [
  holds(atom("A")),
  holds(implies(atom("C"), atom("B")))
])
```

Result:

```text
rejected evidence: eB
unknown claim: cB
diagnostic: implication antecedent does not match premise
```

The claim is not false. The offered evidence failed.

## Adversarial Check

Attempt:

```text
holds(type_of(expr("x"), type("integer")))
```

This must be rejected by the propositional semantics because `type_of` is not a
`Prop` form. The substrate must not add a generic "typed expression" concept to
make this pass.

If a future hosted type semantics wants such a claim, it defines its own
predicate and evidence methods.

## Design Pressure Found

This pass forces two distinctions that the object model should preserve:

- rejected evidence is not the same as rejected claim truth;
- contradiction is a hosted-semantics policy choice, not a substrate rule.

It also keeps trust summaries transitive: accepting a conjunction through two
trusted axioms carries both trust dependencies.

## Next Pass

The next validation pass should use untyped lambda calculus only if this
propositional pass remains coherent. That pass should introduce artifact
structure and binding pressure without admitting `type` as a substrate concept.
