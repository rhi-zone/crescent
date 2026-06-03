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
2. `docs/typechecker-v7-first-principles.md` — pre-spec derivation of the
   checker's semantic primitives and design forks.
3. `docs/typechecker-v7-design-pass-unknown.md` — first refinement pass,
   deciding unknown movement from operation domains.
4. `docs/typechecker-v7-design-pass-places.md` — second refinement pass,
   deciding semantic places and binder-aware arrows for facts.
5. `docs/typechecker-v7-design-pass-primitive-capabilities.md` — third
   refinement pass, deciding primitive capabilities as value types.
6. `docs/typechecker-v7-design-pass-effects.md` — fourth refinement pass,
   deciding full arrows are effectful with contextual-control effects.
7. `docs/typechecker-v7-design-pass-packs.md` — fifth refinement pass, deciding
   open/rest packs and movement kinds.
8. `docs/typechecker-v7-design-pass-setmetatable.md` — sixth refinement pass,
   deciding setmetatable fixes metatable state without sealing construction.
9. `docs/typechecker-v7-design-pass-metatable-lookup.md` — seventh refinement
   pass, deciding metatable lookup/assignment relations and invalidation.
10. `docs/typechecker-v7-design-pass-module-provenance.md` — eighth refinement
   pass, deciding explicit environments and provenance for external claims.
11. `docs/typechecker-v7-design-pass-generics-typelevel.md` — ninth refinement
   pass, deciding rank-1 generics and first-order type-level computation before
   HKTs/rank-N.
12. `docs/typechecker-v7-design-pass-operators.md` — tenth refinement pass,
   deciding operator application through primitive/metamethod operation
   judgments, with `and`/`or` split into control-flow expression rules.
13. `docs/typechecker-v7-design-pass-certificates.md` — eleventh refinement
   pass, deciding the replay DAG, context inputs, node families, roots, and
   unsafe/trusted boundary handling.
14. `docs/typechecker-v7-design-pass-target-profile.md` — twelfth refinement
   pass, deciding LuaJIT 5.1/Crescent as the first concrete target profile and
   making numeric, operator, truthiness, raw, and protected-metatable behavior
   explicit profile input.
15. `docs/typechecker-v7-luajit51-target-table.md` — concrete target table for
   the vendored LuaJIT 5.1 runtime: source operators, metamethod dispatch,
   equality/order restrictions, protected metatables, raw operations, and cdata
   boundaries.
16. `docs/typechecker-v7-minimal-replay-subset.md` — first verifier prototype
   slice, deciding MR0's admitted rules, certificate payload families, roots,
   primitive calls, and explicit exclusions.
17. `docs/typechecker-v7-coherence-audit.md` — whether the current design is a
   consistent whole, plus blocking semantic seams.
18. `docs/typechecker-v7-kernel-semantics.md` — current semantic kernel,
   judgments, and certificate obligations.
19. `docs/typechecker-v7-semantic-mining.md` — rules for importing semantics from
   older Crescent designs or external systems without reintroducing ad-hocness.
20. `docs/typechecker-v7-missing-feature-audit.md` — mined feature gaps and
   recommended v7 classifications.
21. `docs/typechecker-v7-consolidation-audit.md` — source hierarchy, conflicts,
   and lineage status.

Older v4/v5/v6 docs are research input only. If they conflict with v7, v7 owns
the active soundness-fatal rule. If v7 is silent, the older doc may motivate an
extension but does not admit it.

## Current Kernel Shape

Admitted or actively sketched:

- value-set algebra: literals, atoms, unions, intersections, complement,
  `unknown`, `never`;
- value-list packs with closed/rest/variable tails and correlated `PackAlt`;
- arrows with return packs and normal-continuation postconditions;
- records as sealed observations of table identities;
- table identity states and transitions;
- proof-producing guards and assertion postconditions;
- overload body checking under every declared branch;
- unsafe/trusted boundaries as certificate events.

Not yet admitted:

- detailed rest/pack-variable movement transcription;
- contextual control effects such as `throws(E)` and `yields(Y, S)`;
- module/declaration/FFI environments;
- match-type evaluation and field-descriptor folds;
- HKTs, rank-N polymorphism, recursive types, and full kinding;
- exact table length proofs, cdata operators, and numeric-string grammar;
- external declaration/import bridge specs for globals, modules, and FFI.

## Decision Queue

Work these before implementation verticals:

1. **MR0 payload transcription.** Turn the minimal replay subset into concrete
   verifier data structures and canonical serialization.
2. **MR0 adversarial examples.** Write small accepted/rejected programs that
   exercise every admitted MR0 node family.

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
