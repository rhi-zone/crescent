# Typechecker Framework

This is the new top-level direction for typechecker work.

The goal is not another Crescent typechecker version. The goal is a
type-system-agnostic framework for specifying and checking type-system theories.

The framework must be usable, in principle, for:

- STLC;
- System F;
- nominal object-oriented systems such as Java or C#;
- structural and flow-sensitive systems such as TypeScript or Python checkers;
- Crescent/Lua as one later theory.

If a design decision only makes sense for Crescent, it belongs in a Crescent
theory, not in the framework.

## Core Distinction

The framework has three layers:

```text
Framework
  theory-agnostic derivation checker and evidence format

Theory
  syntax classes, judgments, rules, admissible oracles, and soundness obligations

Frontend
  source parser/elaborator that emits theory-specific evidence
```

Only the framework checker and the selected declarative theory spec are trusted
by default. Frontends, inference engines, solvers, annotation parsers, and IDE
integrations are evidence producers. They may be useful and complex, but they
are not trusted for soundness.

If a theory needs non-structural computation that cannot be expressed as
declarative rules, that computation must appear as evidence-producing code whose
outputs are checked, or as an explicit oracle/trusted plugin boundary declared
by the theory.

## Framework Responsibilities

The framework may define:

- symbols and namespaces;
- syntactic categories;
- binders and scopes;
- contexts;
- judgments;
- rule schemas;
- derivation/evidence DAGs;
- premise ordering and dependency tracking;
- canonical serialization for framework data;
- explicit trusted escape/oracle nodes;
- diagnostics for failed replay or malformed evidence.

The framework must not define:

- what a type is;
- what subtyping means;
- whether subtyping exists;
- whether inference exists;
- whether effects, classes, rows, unions, intersections, HKTs, tables, or
  mutation exist;
- any concrete language runtime;
- any stdlib.

Those are theory choices.

## Theory Responsibilities

A theory supplies the objects the framework checks.

Each theory must define:

- syntactic categories, for example `Term`, `Type`, `Kind`, `Effect`, `Class`;
- well-formedness judgments;
- typing/checking judgments;
- equality/subtyping/reduction judgments if the theory has them;
- context forms and context extension rules;
- admissible evidence node families;
- trusted oracle boundaries;
- soundness obligations.

A theory may be small. STLC should fit in a page:

```text
Γ ⊢ x : T
Γ, x:T ⊢ e : U
Γ ⊢ λx:T. e : T -> U
Γ ⊢ f : T -> U
Γ ⊢ a : T
Γ ⊢ f a : U
```

A theory may also be large. A TypeScript-like theory may include structural
object types, flow facts, overloads, conditional types, and trusted escapes. The
framework does not need to understand those constructs, only the judgments and
evidence rules the theory declares.

## Evidence

Evidence is a checked derivation, not an implementation trace.

Evidence nodes name:

- the theory;
- the judgment being proven;
- the rule used;
- input terms;
- premise nodes;
- output claim.

The framework checks that:

- every referenced symbol has the declared category;
- every premise proves the judgment required by the rule schema;
- binders and substitutions are well-scoped;
- side conditions are framework-structural, proven by premise judgments, or
  discharged by an explicit trusted oracle;
- roots point at accepted evidence.

The framework does not search for missing proofs unless a theory explicitly
declares a search/oracle rule whose result is itself checked or trusted.

## Oracles And Escapes

Real-world type systems need escape hatches.

Examples:

- SMT solver result;
- definite-assignment analysis;
- Java overload resolution;
- Python plugin hook;
- TypeScript assignability implementation;
- FFI or platform declaration;
- manually trusted annotation.

The framework should allow these only as explicit oracle nodes:

```text
OracleNode {
  theory,
  judgment,
  claim,
  oracle_kind,
  input_digest,
  result_digest,
  trust_policy
}
```

An oracle node is not hidden inference. It is an auditable trust boundary. A
theory may forbid oracles, require proof-producing oracles, or admit trusted
oracles for selected judgments.

## Validation Ladder

The framework is not considered viable because it handles Crescent MR0. It must
be stress-tested against multiple unrelated theories.

Initial validation theories:

1. STLC: binders, contexts, arrow introduction/elimination.
2. System F subset: type binders, instantiation, alpha/renaming discipline.
3. Nominal OO sketch: class table, inheritance, method lookup, override checks.
4. Structural flow sketch: object fields, union narrowing, flow facts.
5. Imperative state sketch: references, heap typing, assignment, invalidation.

These are not product checkers. They are falsification tests for the framework.
If the framework cannot express one without special pleading, the framework is
wrong.

## Relationship To v7

v7 is no longer the top-level direction.

The v7 documents and `lib/type/v7_mr0/` are retained as prototype material:

- evidence replay experiments;
- canonical serialization experiments;
- examples of what a Crescent theory might eventually need;
- examples of premature theory-specific commitment.

They are not the authority for new design work. New work should start from this
framework document, then define or refine a theory.

No new v7 MR0 feature should be implemented unless it is explicitly framed as a
framework experiment or a Crescent-theory instance.

## Immediate Roadmap

The next work is design, not implementation:

1. Specify the framework data model: categories, judgments, rules, terms,
   binders, contexts, evidence nodes, roots, and oracle nodes. Current draft:
   `docs/typechecker-framework-data-model.md`.
2. Specify the minimal derivation checker independent of any concrete theory.
3. Instantiate STLC as the first theory.
4. Instantiate a small System F subset as the second theory.
5. Audit whether the v7 MR0 verifier is an instance of the framework or a
   theory-specific prototype that should remain isolated.

Implementation starts only after STLC can be written as a theory without
Crescent-specific concepts.

## Non-Goals

This framework is not:

- a universal inference engine;
- a universal subtyping algorithm;
- a claim that all type systems are sound;
- a replacement for language-specific frontends;
- a promise that every real-world checker can avoid trusted oracles.

It is a common substrate for expressing and checking the evidence that a chosen
theory says is sufficient.
