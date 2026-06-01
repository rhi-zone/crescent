# Typechecker v6 Implementation Plan

This document decomposes `docs/typechecker-v6-plan.md` into executable work.
The design rule is the same as the spec: every task must reduce to value claims,
movement sites, proof obligations, and facts. If a task cannot name those, it is
not ready to implement.

v6 is built beside v4. v4 remains the running checker until v6 can check enough
of the repository to replace it. v5 remains research input only.

## Plan Shape

Each package below has:

- a semantic owner;
- concrete files or directories;
- dependency gates;
- conformance fixtures;
- delegation guidance.

Delegation is safe only when the write set and semantic owner are disjoint. Work
that changes the shared fact model, the type AST, or movement-site semantics must
stay serialized.

## Global Invariants

- No name-keyed handlers. If behavior depends on `pcall`, `require`,
  `setmetatable`, or a stdlib name, the task is not done.
- No implicit `any`. `any` is an unsafe boundary with a diagnostic/audit event.
- No silent complexity widening. Budget exhaustion rejects with
  `TYPE_COMPLEXITY_LIMIT`.
- An annotation exports a claim only after its proof obligation succeeds.
- A user-defined guard exports a guard claim only after all true returns prove
  the predicate.
- An overload exports only after the body checks under every overload branch.
- Table facts are identity facts. Record claims are observations, not immutable
  truth about all aliases.
- Module and stdlib facts flow through declarations and the module fact table.

## Directory Layout

Current prototype:

```text
lib/type/static-v6/
  algebra_test.lua
  diagnostics.lua
  init.lua
  normalize.lua
  subtype.lua
  types.lua
```

Planned layout:

```text
lib/type/static-v6/
  ann.lua                 -- annotation/type syntax parser or adapter
  ast.lua                 -- stable typed view over parsed Lua AST, if needed
  cli.lua                 -- opt-in CLI entry point
  diagnostics.lua
  driver.lua              -- file/module orchestration
  env.lua                 -- bindings, identities, flow, module facts
  facts.lua               -- fact and obligation constructors
  flow.lua                -- branch facts, joins, invalidation
  guards.lua              -- intrinsic and verified guard checking
  init.lua
  modules.lua             -- require/module graph/stdlib declarations
  normalize.lua
  overloads.lua
  packs.lua
  records.lua             -- record observations and table identity states
  stdlib.lua              -- declaration facts only, no handlers
  subtype.lua
  syntax.lua              -- expression/statement checker
  types.lua
```

Tests should live next to their packages until a larger fixture runner is needed.

## Existing Code Policy

v6 should reuse requirements and tests aggressively, but copy implementation
code selectively. The failure mode to avoid is inheriting v4/v5's accidental
architecture while changing names.

Reuse or mirror:

- `lib/type/static/parse.lua`, `lex.lua`, `defs.lua`, `arena.lua`, `intern.lua`
  as the parser/AST substrate unless v6 intentionally changes syntax.
- `lib/type/static/errors.lua` through an adapter, following the v5
  `error_format.lua` pattern.
- `lib/type/static-v4/driver/decoder.lua` if v6 chooses POJO AST walking.
- `lib/type/static-v4/walker/diag.lua`, `origin.lua`, and
  `driver/summary.lua` as models for structured provenance and summaries.
- `lib/type/static-v4/cache.lua` and `driver/driver.lua` as models for
  caps-injected recursive require/cache orchestration, retargeted to v6 export
  type serialization.
- `lib/type/static-v5/ann.lua` as an annotation parser skeleton, retargeted to
  v6 constructors.
- v5's independent parity-test discipline for semantic rules, not its current
  source-pipeline special cases.
- v5/v4 tests and snapshots as seed behavior, after translating expectations to
  v6's pinned policies.

Avoid copying:

- `lib/type/static/solve.lua`, `constrain.lua`, `unify.lua`, and
  `intrinsic.lua`: legacy monolith/name-keyed dispatch archaeology only.
- `lib/type/static/env.lua`, `types.lua`, `match.lua`, and `narrow.lua`: tightly
  coupled to legacy arena type IDs, context mutation, and intrinsic encodings.
- `lib/type/static-v4/types.lua`, `subtype.lua`, `empty.lua`, `forall.lua`, and
  `match.lua`: small and useful to read, but v4's single-primitive architecture
  should not define v6.
- `lib/type/static-v4/walker/*` wholesale: port concerns only after v6 IR and
  facts exist.
- `lib/type/static-v5/constrain.lua`: useful bridge prototype, but still has
  stdlib/effect/operator special cases and depends on experimental substrate.
- `lib/type/static-v5/stdlib_types.lua` structurally: reuse declaration intent,
  not conservative fallbacks or gen-pass special cases.

Integration choices that must be made early:

- Parser bridge: direct arena traversal like v5, or arena-to-POJO decoder like
  v4. Do not support both initially.
- Annotation front-end: retarget `static-v5/ann.lua`, or fork a small v6 parser.
- Diagnostics: make provenance first-class in obligations from day one, then
  adapt to existing formatting.
- CLI: add `--v6` only after single-file checking has green unit/snapshot
  coverage.
- Driver/cache: wait until module export type serialization is stable.

## Recursive Decomposition

### 0. Harness And Boundaries

Owner: v6 is loadable, testable, and opt-in without disturbing v4.

Tasks:

- Add `static-v6/cli.lua` with a hidden or explicit flag path, but do not make it
  the default checker.
- Add a tiny fixture runner that can check one Lua source string or file and
  return diagnostics.
- Add a snapshot/conformance convention for v6 fixtures.
- Keep implementation modules v4-checkable where practical; tests may remain
  runtime-only until v6 owns module export typing.

Dependencies:

- Current algebra prototype.

Gate:

- `bin/cr test lib/type/static-v6/` passes.
- Implementation modules pass `bin/cr check` under v4, unless a documented v4
  limitation blocks only tests.

Delegation:

- Safe to delegate fixture-runner scaffolding if it only writes test harness
  files and does not change type semantics.

### 1. Value Algebra

Owner: `Type`, `Pack`, normalization, display, structural keys, subtype shell.

Current files:

- `types.lua`
- `normalize.lua`
- `subtype.lua`
- `diagnostics.lua`
- `algebra_test.lua`

Remaining tasks:

- Split `Pack` helpers into `packs.lua`.
- Add arrow, pack, and record type constructors to `types.lua` without adding
  subtyping behavior yet.
- Add structural hashing/memo keys that do not encode semantics in string
  prefixes.
- Add recursion-depth budget in addition to term budget.
- Add bounded complement/emptiness cases needed by guards and overload calls.

Dependencies:

- None.

Gate:

- Existing 29 algebra assertions stay green.
- New fixtures cover depth budget, pack key/display, and record node display.

Delegation:

- Safe to delegate display/key/budget tests.
- Keep subtype semantics local or serialized because every later vertical depends
  on it.

### 2. Obligations, Facts, And Environment

Owner: the shared layer that prevents ad-hocness from entering through rule
plumbing.

Files:

- `facts.lua`
- `env.lua`
- extensions to `diagnostics.lua`

Tasks:

- Define `Obligation = { producer, consumer, site, span, reason }`.
- Define fact constructors for expressions, bindings, identities, flow, modules,
  and unsafe boundaries.
- Define environment update operations instead of direct table mutation by
  syntax rules.
- Define invalidation hooks for calls, writes, alias exposure, and joins.
- Add obligation discharge helper that calls `subtype.is_subtype`.

Dependencies:

- Value algebra.

Gate:

- Unit tests can create/discharge obligations with correct diagnostics.
- Environment updates are the only path used by later syntax packages.

Delegation:

- Safe to delegate diagnostics/fact constructor tests.
- Do not delegate environment semantics concurrently with syntax checking.

### 3. Annotation And Type Syntax Front-End

Owner: convert existing annotation syntax to v6 `Type`/`Pack`/declaration facts.

Files:

- `ann.lua`
- possibly adapters over `lib/type/static/ann.lua` or `static-v4` parser code

Tasks:

- Parse atoms, literals, `nil`, union, intersection, complement, arrows, packs,
  records, generics syntax if already present.
- Reject unsupported forms with explicit `FEATURE_NOT_ADMITTED` or equivalent.
- Preserve source spans for diagnostics.
- Ensure checked cast and force cast surfaces are distinguishable.

Dependencies:

- Value algebra.
- Packs for arrow syntax.

Gate:

- Annotation parser round-trip or parse fixtures for every type node admitted in
  the current implementation.
- Unsupported HKT/effect/refinement syntax is rejected or parked explicitly.

Delegation:

- Safe to delegate parser fixture expansion.
- Parser behavior that changes admitted type nodes must be reviewed locally.

### 4. Bindings, Assignments, And Casts

Owner: first real movement sites.

Files:

- `syntax.lua`
- `env.lua`
- `facts.lua`

Tasks:

- Implement literal expression claims.
- Implement local binding claims.
- Implement annotation obligations for locals.
- Implement checked cast obligations and force-cast unsafe boundary events.
- Implement simple assignment to existing mutable bindings.

Dependencies:

- Facts/env.
- Annotation parser.

Gate:

- Bad annotation rejects.
- `unknown` cannot satisfy concrete annotation.
- Force cast is visible and grep-able.
- Assignment mismatch rejects.

Delegation:

- Safe to delegate fixture writing once movement semantics are implemented.
- Do not delegate syntax and env changes to separate workers concurrently.

### 5. Arrows, Packs, Calls, And Returns

Owner: function movement sites.

Files:

- `packs.lua`
- `syntax.lua`
- `subtype.lua`

Tasks:

- Implement pack arity checking with Lua multi-return rules at movement sites.
- Implement arrow subtyping: parameters contravariant, returns covariant.
- Check function bodies against declared arrows.
- Check call arguments and produce return packs.
- Check returns against current function return pack.
- Route primitive operators through declared arrows where possible.

Dependencies:

- Bindings/annotations.
- Packs.

Gate:

- Wrong argument type rejects.
- Return mismatch rejects.
- Missing/extra argument behavior is fixture-pinned.
- Multi-return discard/padding behavior is pinned at the movement site.

Delegation:

- Pack-only unit tests are safe to delegate.
- Function-body checking must stay serialized with syntax/env changes.

### 6. Overloads

Owner: overloaded implementation proof and overloaded call result.

Files:

- `overloads.lua`
- `syntax.lua`
- `subtype.lua`

Tasks:

- Represent overload sets as intersection-of-arrows or an explicit overload
  wrapper that normalizes to that claim.
- Check implementation once per overload signature.
- Resolve calls by collecting all matching branches.
- Return union of all matching branch returns.
- Emit `OVERLOAD_NO_MATCH` and `OVERLOAD_BRANCH_UNPROVEN`.

Dependencies:

- Arrows/calls/returns.
- Union normalization.

Gate:

- Body satisfies all overloads.
- Body fails one overload and declaration rejects.
- Ambiguous call returns union, not first branch.
- Union argument call behavior is fixture-pinned.

Delegation:

- Safe to delegate overload fixture corpus after core algorithm exists.
- Do not implement overloads concurrently with arrow call semantics.

### 7. Tables As Identity And Records

Owner: table construction, record observations, reads, writes, alias/seal rules.

Design:

- `docs/typechecker-v6-records-identity-design.md`

Files:

- `records.lua`
- `env.lua`
- `syntax.lua`
- `subtype.lua`

Tasks:

- Introduce `ValueClaim` as the source/env movement-site claim carrying
  `StaticType` plus optional `identity_id`; do not add open table identities to
  `StaticType`.
- Keep construction-phase openness (`TableState.phase`) distinct from structural
  row openness (`RecordType.row`).
- Add record subtyping with field/index variance.
- Model fresh table identities and open construction phase.
- Extend direct writes to fresh unescaped identities.
- Seal identities on annotation, return, unknown call, or escape.
- Implement field reads and writes.
- Implement alias invalidation conservatively.

Dependencies:

- Facts/env.
- Bindings/assignments.
- Record type nodes in parser.

Gate:

- Construction write accepted.
- Missing field after seal rejected.
- Readonly write rejected.
- Alias invalidation fixture rejects stale narrowed field fact.
- Open record width subtyping fixture passes.

Delegation:

- This is high-interaction work; keep implementation serialized.
- Safe to delegate only black-box fixture design or v4/v5 behavior audit.

### 8. Flow And Guards

Owner: branch facts, joins, intrinsic narrowing, verified user guards.

Files:

- `flow.lua`
- `guards.lua`
- `syntax.lua`
- `env.lua`

Tasks:

- Implement branch edge facts for `x ~= nil`, `x == nil`,
  `type(x) == "..."`, literal equality, and tag-field equality.
- Implement join by retaining only facts valid on all incoming edges.
- Invalidate narrowed facts on mutation/call/alias exposure.
- Implement guard declaration checking: every true return path must prove the
  predicate.
- Export verified guard claim only after proof succeeds.

Dependencies:

- Tables as identity for field/discriminant guards.
- Arrows/returns for guard function bodies.

Gate:

- Intrinsic nil/type guards narrow.
- Invalid user guard rejected.
- Valid user guard accepted.
- Mutating narrowed field invalidates the fact.

Delegation:

- Intrinsic guard fixture writing is safe.
- Verified guard checker is not safe to split from flow/env semantics.

### 9. Modules And Stdlib Declarations

Owner: module graph, `require`, globals, stdlib declarations.

Files:

- `modules.lua`
- `stdlib.lua`
- `driver.lua`
- `cli.lua`

Tasks:

- Build module fact table.
- Implement literal `Require<"module">` lookup.
- Reject undeclared literal require in strict mode.
- Treat dynamic require as explicit `unknown` boundary.
- Check module export against declaration.
- Remove need for ambient globals in v6 mode.
- Express stdlib as declarations plus trusted boundary classifications.

Dependencies:

- Arrows/calls.
- Tables/records for stdlib tables.
- Driver/file orchestration.

Gate:

- Declared module import works.
- Module export mismatch rejects.
- Undeclared global rejects.
- `io`/`os` only exist through declarations or explicit boundary.
- No stdlib name handler is needed.

Delegation:

- Module graph/driver scaffolding can be delegated if API is fixed.
- Stdlib declaration authoring can be delegated after declaration format lands.

### 10. Metatables And Methods

Owner: `setmetatable`, `__index`, metamethods, `:` dispatch.

Files:

- `records.lua`
- `syntax.lua`
- possibly `metatables.lua`

Tasks:

- Permit `setmetatable` only on fresh/open identities.
- Seal table observation after metatable assignment.
- Walk table `__index` chains with cycle detection.
- Type `__index` functions as arrows.
- Implement `:` as field lookup plus receiver argument.
- Feed metamethod operator lookup into ordinary call checking.

Dependencies:

- Tables as identity.
- Arrows/calls.
- Modules/stdlib for declared `setmetatable`.

Gate:

- Receiver passing fixture.
- Table `__index` chain fixture.
- Cyclic `__index` terminates.
- Re-metatable rejected.

Delegation:

- Do not delegate until table identity and method-call APIs are stable.

### 11. Generics

Owner: ordinary and bounded polymorphism.

Files:

- `generics.lua`
- `subtype.lua`
- `ann.lua`
- `syntax.lua`

Tasks:

- Add type parameter nodes and bounds.
- Instantiate generic arrows at call sites.
- Generalize only at let/export boundaries.
- Check generic function bodies once under symbolic parameters.
- Ensure unresolved type parameters do not leak `any`.

Dependencies:

- Arrows/calls.
- Records for bounded field access.
- Modules for export boundaries.

Gate:

- Identity function preserves type.
- Bounded generic field access works.
- Bound violation rejects.
- No `any` leakage from unresolved parameters.

Delegation:

- Keep core implementation serialized.
- Safe to delegate corpus search for APIs needing HKTs.

### 12. Optional Capability Effects

Owner: reserved extension; not core.

Tasks:

- Write admission document before implementation.
- Prove ordinary module/capability declarations cannot satisfy the use case.
- If admitted, attach effect rows to arrows and call obligations only.

Dependencies:

- Arrows/calls.
- Overloads.
- Modules/stdlib declarations.

Gate:

- No core feature depends on effects.
- Effect fixtures pass only after explicit admission.

Delegation:

- Safe to delegate research/corpus audit.
- Do not implement effects during core v6.

## Serialization Rules

Serialized work:

- `StaticType` and subtype semantics.
- `Env`/fact invalidation.
- Syntax movement-site checking.
- Table identity semantics.
- Flow/guard semantics.
- Arrow/call semantics while overloads are being added.

Parallelizable work:

- Fixture corpus expansion for an already-implemented vertical.
- Diagnostics formatting for already-fixed reason codes.
- CLI/harness scaffolding after driver API is named.
- Stdlib declaration authoring after declaration format is named.
- Corpus audits and migration inventories.
- Documentation updates that do not change normative semantics.

## Delegation Backlog

Safe bounded tasks to hand to workers/explorers:

- Inventory v4 parser/annotation modules reusable by v6.
- Inventory v4/v5 name-keyed handlers to ensure v6 does not copy them.
- Build additional algebra fixtures for normalization budgets and display.
- Build annotation parser fixtures from existing docs.
- Draft stdlib declaration inventory after module declaration format lands.
- Search repository corpus for table construction/aliasing patterns.
- Search repository corpus for overload-like APIs and guard-like functions.

Do not delegate:

- Changes to subtype semantics.
- Changes to the fact/env model.
- Changes to table identity invalidation.
- Changes to overload call resolution.
- Changes to verified guard proof rules.

## Milestones

### M0: Prototype Stabilized

Already partially done.

Exit:

- v6 module loads.
- Value algebra tests pass.
- Implementation modules typecheck under v4.
- This implementation plan exists.

### M1: First Source File Checker

Exit:

- v6 can check literals, locals, annotations, checked casts, and assignment in a
  single file.
- Diagnostics include producer, consumer, movement site, and reason code.

### M2: Functions

Exit:

- v6 can check declared function bodies, calls, returns, and basic multi-return
  movement.
- Function fixtures are independent of tables/modules.

### M3: Overloads

Exit:

- v6 checks overload bodies per branch.
- Ambiguous calls return union of matching returns.

### M4: Tables

Exit:

- v6 handles fresh table construction, field reads/writes, sealing, and record
  subtyping.
- Alias invalidation is conservative and fixture-pinned.

### M5: Flow And Guards

Exit:

- v6 narrows through core intrinsic guards.
- User guards are verified or rejected.

### M6: Modules

Exit:

- v6 checks a small multi-file module graph.
- Literal require uses module facts.
- Undeclared globals/modules follow pinned policy.

### M7: Methods And Metatables

Exit:

- v6 handles `:` calls and restricted `setmetatable`/`__index`.

### M8: Generics

Exit:

- v6 handles ordinary bounded generics without `any` leakage.

### M9: Replacement Readiness

Exit:

- v6 checks a selected repository corpus slice.
- v6 has no name-keyed stdlib handlers.
- Known rejects are documented as annotation requirements or explicit deferred
  features.

## Immediate Next Tasks

1. Finish M0 by deciding whether `algebra_test.lua` should be v4-checkable or
   remain runtime-only until v6 owns module export typing.
2. Implement `facts.lua` and `env.lua` minimal obligation discharge.
3. Add `packs.lua` and move pack helpers out of `types.lua`.
4. Add annotation parser/adaptor fixtures for the type nodes v6 already accepts.
5. Start M1 with literal/local/annotation checking over a minimal AST path.

## Blocking Spec Decisions

These must be pinned before or during the named milestone. They are not cosmetic.

Before M1:

- Whether v6 adapts the existing annotation parser or forks a small v6 parser.
- Whether v6 walks direct arena nodes or decoded POJO AST nodes.
- Exact fixture format for source-level v6 diagnostics.
- Whether implementation tests must be v4-checkable, or may be runtime-only
  until v6 can type `require` exports correctly.
- Boundary severity for `any` per source: dynamic require, force cast, FFI,
  undeclared external declaration, legacy compatibility.

Before M2:

- Precise Lua pack semantics: where extra returns are discarded, where missing
  values nil-pad, and how varargs/rest interact.
- Represent call and overload returns as `PackResult` unions of whole packs
  before any movement site performs arity adjustment or intentional
  correlation-losing widening.
- Exact union-right subtype behavior for consumer unions, because call
  acceptance and overload matching depend on it.
- Current M2 blockers are tracked in `docs/typechecker-v6-m2-blockers.md`.

Before M4:

- Record width rule in operational terms. The phrase "extra fields not observed
  by the consumer movement site" must become an algorithm.
- Optional field read/write rules, including whether writing `nil` removes a
  field or writes a present `nil` value.
- Exact meanings of construction scope, escaped identity, unknown mutation
  behavior, and provably disjoint write target.

Before M5:

- Invalid guard policy: reject the declaration or downgrade it to plain boolean.
  The current preference is reject for explicit `x is T` declarations.

Before M8:

- Generic generalization and instantiation boundaries.
- Variadic generic design, if needed for `pcall`/coroutine-quality stdlib
  declarations.

Reserved:

- Method/metatable precision beyond restricted fresh/open `setmetatable`.
- Effect admission and severity. Core v6 must not depend on effects.

## Risk Register

- Source bridge risk: v6 can have a clean core and still fail if the AST/gen-pass
  bridge reintroduces special cases.
- Table identity risk: this is the main feature-interaction point for records,
  flow, guards, methods, modules, and mutation.
- Pack risk: Lua multi-return behavior must be pinned before calls, overloads,
  stdlib declarations, and variadic generics.
- Performance risk: realistic-scale checking is unmeasured. Add synthetic and
  corpus gates before replacement-readiness claims.
- Stdlib risk: if stdlib declarations need name handlers, the declaration
  surface is insufficient.
- Test risk: v4 cannot express some module export typing that v6 intends to fix;
  forcing every v6 test through v4 may create false work.
