# Typechecker v7

This is no longer the entry point for active typechecker architecture work.

Start with `docs/typechecker-framework.md`.

v7 is retained as prototype material for a Crescent-specific proof-producing
theory and replay verifier. It is not the active top-level architecture.

v7 is the proof-producing or mechanized-kernel-first architecture line. It is
not v6 with stricter tests, and it is not implementation progress in
`lib/type/static-v6/`. v7 accepts a program only if the accepted claims can be
justified by v7 kernel rules and certificate obligations.

New work should not add v7 MR0 features unless the work is explicitly framed as
a framework experiment or as a future Crescent-theory instance.

## Source Order

Read in this order:

1. `docs/typechecker-framework.md` — active type-system-agnostic framework
   direction.
2. `docs/typechecker-soundness-validation.md` — trust model, version line, and
   acceptance bar.
3. `docs/typechecker-v7-roadmap.md` — recursive roadmap from proof-producing
   vision down to the current next slice.
4. `docs/typechecker-v7-first-principles.md` — pre-spec derivation of the
   checker's semantic primitives and design forks.
5. `docs/typechecker-v7-design-pass-unknown.md` — first refinement pass,
   deciding unknown movement from operation domains.
6. `docs/typechecker-v7-design-pass-places.md` — second refinement pass,
   deciding semantic places and binder-aware arrows for facts.
7. `docs/typechecker-v7-design-pass-primitive-capabilities.md` — third
   refinement pass, deciding primitive capabilities as value types.
8. `docs/typechecker-v7-design-pass-effects.md` — fourth refinement pass,
   deciding full arrows are effectful with contextual-control effects.
9. `docs/typechecker-v7-design-pass-packs.md` — fifth refinement pass, deciding
   open/rest packs and movement kinds.
10. `docs/typechecker-v7-design-pass-setmetatable.md` — sixth refinement pass,
   deciding setmetatable fixes metatable state without sealing construction.
11. `docs/typechecker-v7-design-pass-metatable-lookup.md` — seventh refinement
   pass, deciding metatable lookup/assignment relations and invalidation.
12. `docs/typechecker-v7-design-pass-module-provenance.md` — eighth refinement
   pass, deciding explicit environments and provenance for external claims.
13. `docs/typechecker-v7-design-pass-generics-typelevel.md` — ninth refinement
   pass, deciding rank-1 generics and first-order type-level computation before
   HKTs/rank-N.
14. `docs/typechecker-v7-design-pass-operators.md` — tenth refinement pass,
   deciding operator application through primitive/metamethod operation
   judgments, with `and`/`or` split into control-flow expression rules.
15. `docs/typechecker-v7-design-pass-certificates.md` — eleventh refinement
   pass, deciding the replay DAG, context inputs, node families, roots, and
   unsafe/trusted boundary handling.
16. `docs/typechecker-v7-design-pass-target-profile.md` — twelfth refinement
   pass, deciding LuaJIT 5.1/Crescent as the first concrete target profile and
   making numeric, operator, truthiness, raw, and protected-metatable behavior
   explicit profile input.
17. `docs/typechecker-v7-luajit51-target-table.md` — concrete target table for
   the vendored LuaJIT 5.1 runtime: source operators, metamethod dispatch,
   equality/order restrictions, protected metatables, raw operations, and cdata
   boundaries.
18. `docs/typechecker-v7-minimal-replay-subset.md` — first verifier prototype
   slice, deciding MR0's admitted rules, certificate payload families, roots,
   primitive calls, and explicit exclusions.
19. `docs/typechecker-v7-mr0-payloads.md` — concrete MR0 certificate envelope,
   canonical serialization, payload schemas, replay algorithm, and adversarial
   fixtures.
20. `docs/typechecker-v7-canonical-inputs.md` — canonical term/context/node IDs,
   certificate digests, external certificate boundary, and strictness staging.
21. `docs/typechecker-v7-mr0-coverage-audit.md` — implementation coverage audit
   for the table-native MR0 verifier and the next payload family.
22. `docs/typechecker-v7-mr0-contexts.md` — MR0 place/context/local-read rules
   for source-independent function body certificates.
23. `docs/typechecker-v7-mr0-function-body.md` — MR0 source-independent
   function body, parameter context, function value, and function-export root
   replay.
24. `docs/typechecker-v7-coherence-audit.md` — whether the current design is a
   consistent whole, plus blocking semantic seams.
25. `docs/typechecker-v7-kernel-semantics.md` — current semantic kernel,
   judgments, and certificate obligations.
26. `docs/typechecker-v7-semantic-mining.md` — rules for importing semantics from
   older Crescent designs or external systems without reintroducing ad-hocness.
27. `docs/typechecker-v7-missing-feature-audit.md` — mined feature gaps and
   recommended v7 classifications.
28. `docs/typechecker-v7-consolidation-audit.md` — source hierarchy, conflicts,
   and lineage status.

Older v4/v5/v6/v7 docs are research input for new framework work. If they
conflict with `docs/typechecker-framework.md`, the framework direction owns the
active top-level rule. Crescent-specific v7 docs may still own historical v7
prototype behavior. If the active framework is silent, older docs may motivate a
theory extension but do not admit it.

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

## Historical Decision Queue

The historical recursive plan is `docs/typechecker-v7-roadmap.md`.

Frozen v7 frontier at the framework pivot:

```text
M2: canonical inputs and external certificate boundary
```

Do not treat this as the active implementation queue unless a task is explicitly
scoped to v7 prototype work.

Former immediate implementation:

```text
expanded malformed-input corpus
```

## Prototype Implementation Status At Pivot

Current code:

- `lib/type/v7_mr0/init.lua` is a standalone MR0 replay verifier. It is not
  connected to v4/v5/v6 inference and does not search for missing proofs.
- `lib/type/v7_mr0/canonical.lua` provides deterministic table-native
  serialization and SHA-256 term IDs for canonicalizable MR0 payloads.
- `lib/type/v7_mr0/fixtures.lua` is the initial semantic fixture corpus. It
  includes accepted fixtures for implemented replay rules and rejected boundary
  fixtures for MR0 payload families the verifier must not guess yet.
- `lib/type/v7_mr0/v7_mr0_test.lua` runs the corpus plus focused verifier
  checks.

Currently replayed:

- `WFNode(wf_type)`;
- `WFNode(wf_pack_closed)`;
- `SubNode(refl | never_left | unknown_right | literal_to_base |
  integer_to_number | union_right_arm)`;
- `PackMoveNode(closed_exact | closed_call_adjust | closed_return_adjust)`;
- `CallNode(call_arrow)`;
- `StmtNode(return_closed)`;
- literal `ExprNode` rules;
- `ExprNode(local_read)`;
- `PackNode(values_closed)`;
- `BinderNode(closed_params_context)`;
- `FunctionNode(closed_arrow_body)`;
- `UnsafeNode(force_claim | trusted_decl_value)`;
- root acceptance by prior accepted proof, with kind-aware
  `function_signature_export` validation;
- optional strict term-ID validation via canonical payload digests.

Currently rejected as boundary, even if present in the MR0 design doc:

- overload calls, overload exports, non-return statement replay, table identity
  replay, primitive capability calls, metatable lookup/assignment, `type`
  predicate narrowing, `require`, NaN/cdata numeric canonicalization, and the
  expanded malformed-input corpus.

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
