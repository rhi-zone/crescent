# Typechecker v7

This is the entry point for v7 typechecker work.

v7 is the proof-producing or mechanized-kernel-first architecture line. It is
not v6 with stricter tests, and it is not implementation progress in
`lib/type/static-v6/`. v7 accepts a program only if the accepted claims can be
justified by v7 kernel rules and certificate obligations.

## Source Order

Read in this order:

1. `docs/typechecker-soundness-validation.md` — trust model, version line, and
   acceptance bar.
2. `docs/typechecker-v7-coherence-audit.md` — whether the current design is a
   consistent whole, plus blocking semantic seams.
3. `docs/typechecker-v7-kernel-semantics.md` — current semantic kernel,
   judgments, and certificate obligations.
4. `docs/typechecker-v7-semantic-mining.md` — rules for importing semantics from
   older Crescent designs or external systems without reintroducing ad-hocness.
5. `docs/typechecker-v7-missing-feature-audit.md` — mined feature gaps and
   recommended v7 classifications.
6. `docs/typechecker-v7-consolidation-audit.md` — source hierarchy, conflicts,
   and lineage status.

Older v4/v5/v6 docs are research input only. If they conflict with v7, v7 owns
the active soundness-fatal rule. If v7 is silent, the older doc may motivate an
extension but does not admit it.

## Current Kernel Shape

Admitted or actively sketched:

- value-set algebra: literals, atoms, unions, intersections, complement,
  `unknown`, `never`;
- closed value-list packs and correlated `PackAlt`;
- arrows with return packs and normal-continuation postconditions;
- records as sealed observations of table identities;
- table identity states and transitions;
- proof-producing guards and assertion postconditions;
- overload body checking under every declared branch;
- unsafe/trusted boundaries as certificate events.

Not yet admitted:

- open/rest packs and pack variables;
- contextual control effects such as `throws(E)` and `yields(Y, S)`;
- module/declaration/FFI environments;
- match-type evaluation and field-descriptor folds;
- HKTs, rank-N polymorphism, recursive types, and full kinding;
- metatable precision beyond the table-identity seam;
- operator/metamethod semantics;
- target-specific stdlib profiles.

## Decision Queue

Work these before implementation verticals:

1. **`unknown` movement.** Decide whether `unknown` is denotational top with a
   separate concrete-consumption restriction, or another explicit rule. This
   affects calls, annotations, casts, and all trusted bridges.
2. **Open/rest packs.** Closed packs are insufficient for Lua. Varargs,
   `pcall`, `coroutine.resume`, iterators, `select`, and spread returns need a
   pack-variable/rest story.
3. **Arrow postcondition binders.** Decide how assertion postconditions bind
   parameter places before assertion function types become certificate-valid.
4. **Primitive capabilities.** Decide whether primitive cutouts such as
   `$SetMetatable` are first-class `Type` constructors or external capability
   metadata.
5. **Contextual control effects.** Specify at least `throws(E)` and
   `yields(Y, S)` or explicitly defer precise `error`/`pcall`/coroutine typing.
   Do not generalize this into IO/cap/mutation effects by default.
6. **Module/declaration environments.** Define `ModuleEnv`/`DeclEnv` before
   admitting `$Require`, `--:: require`, `$GlobalScope`, or module exports.
7. **Setmetatable fork.** Decide whether `set_metatable` seals construction or
   only fixes metatable state. `__index` chain walking depends on this.
8. **Match/type-level computation.** Specify match evaluation, captures,
   suspension/rejection, and field descriptors before admitting `$EachField` or
   deleting helper intrinsics.
9. **Operator/metamethod substrate.** Define operator application through
   primitive/metamethod lookup, not per-operator predicates or name-keyed
   handlers.

## Admission Rule

A feature is admitted only when all exist:

- well-formedness rules;
- typing, subtyping, reduction, or identity-transition rules;
- failure/rejection behavior;
- soundness obligation;
- certificate node shape;
- explanation of why the rule is substrate, not a one-off result.

If those cannot be written, the feature remains outside v7.

## Current Framing Decisions

- Effects are **contextual control-flow summaries**, not a generic side-effect
  bucket. Initial candidates are `throws(E)` and `yields(Y, S)`.
- Capabilities are runtime values. IO authority is not an `io` effect.
- Table mutation is modeled first by table identity transitions, not by a
  `mutates` row.
- `$Foo` is a reserved annotation/type-level namespace, not one semantic
  category. Each `$` form needs its own `IntrinsicSpec`.
- `any` is not in the sound type algebra. It is an unsafe boundary only.
- Correlated return alternatives remain whole-pack alternatives until a named
  movement site consumes them.
- Organic growth is the failure mode. Thin vertical implementation slices are
  valid only after the relevant kernel rule and certificate shape exist.
