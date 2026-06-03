# Typechecker v7 Consolidation Audit

This document records the current source hierarchy for the typechecker design
after the v7 soundness turn.

For the current v7 entry point and ordered decision queue, start with
`docs/typechecker-v7.md`.

It does not supersede older design material by deletion. Older v4/v5/v6 docs
remain useful evidence and design input, but they are not the authority for the
soundness-fatal checker unless their rules are restated as v7 kernel rules with
certificate obligations.

## Current Source Hierarchy

For v7 work, read documents in this order:

1. `docs/typechecker-v7.md` — entry point and ordered decision queue.
2. `docs/typechecker-soundness-validation.md` — the trust model and acceptance
   bar.
3. `docs/typechecker-v7-coherence-audit.md` — whole-design consistency audit,
   blocking seams, and dependency order.
4. `docs/typechecker-v7-kernel-semantics.md` — admitted kernel objects,
   judgments, and certificate obligations.
5. `docs/typechecker-v7-semantic-mining.md` — how existing systems and older
   Crescent semantics may be imported without reintroducing ad-hoc rules.
6. `docs/typechecker-v7-missing-feature-audit.md` — mined feature gaps and
   recommended v7 classifications.
7. This document — current consolidation status and known conflicts.

Older docs are research inputs:

- `docs/typechecker-v6-plan.md`
- `docs/typechecker-v6-implementation-plan.md`
- `docs/type-system-design/`
- `docs/typechecker-v5-*`
- `docs/typechecker-rewrite-design.md`
- `docs/soundness-audit.md`
- current v4 implementation docs under `lib/type/static/`

If an older doc conflicts with v7, v7 wins for new soundness-fatal work. If v7
is silent, the older doc may motivate a v7 extension but does not admit the
feature by itself.

## Consolidated Decisions

### Version Line

v4 is the running checker. v5 and the unified type-system design are research
lineages. v6 is a direct implementation/prototype line. A mechanized or
proof-producing checker is v7.

v6 implementation progress is not evidence for v7 soundness unless the accepted
programs can be justified by v7 kernel/certificate rules.

The first concrete v7 target profile is `luajit51-crescent`, matching the
vendored runtime and current LuaJIT/FFI surface. Other Lua versions must enter
as separate target profiles with separate certificate digests.

The first concrete LuaJIT target table now records observed operator,
metamethod, protected-metatable, raw-operation, and cdata boundary behavior.

Stdlib bindings are not checker-core semantics and are not part of the v7
semantic spec as a concrete declaration set. They enter, if selected by a
project or driver, through external declaration environment inputs with
provenance, the same category as other checked/trusted declarations.

The first verifier slice is MR0: literals, scalar annotations, closed-pack
calls, overload export checking, explicit unsafe boundaries, fresh table
identity writes, sealed record observations, and a tiny primitive-capability
set.

MR0 now has concrete payload schemas, canonical serialization rules, replay
order, and adversarial fixture requirements in `docs/typechecker-v7-mr0-payloads.md`.

### Architecture Bar

Organic growth is the failure mode. "Thin verticals" are acceptable only as
implementation slices after the relevant kernel rule and certificate shape are
defined. They are not an architecture validation strategy.

### Feature Admission

A feature is admitted only when all of these exist:

- well-formedness rules;
- typing/subtyping/reduction or identity-transition rules;
- failure/rejection behavior;
- soundness obligation;
- certificate node shape;
- an explanation of why the rule is substrate, not a one-off result.

If those cannot be written, the feature remains outside v7.

### Intrinsics

`$Foo` is a reserved annotation/type-level namespace, not one semantic category.

Current v7 classification:

- `$Opaque<T>` / `$Opaque<T, U>` is closest to a pure value-type constructor,
  but still needs stable identity/provenance rules.
- `$Require<T>`, `$FfiC`, and `$GlobalScope` are trusted bridges to module, FFI,
  or declaration state. They require certificate boundaries.
- `$Throw/$Catch` is type-level control/diagnostics, not pure type computation.
- `$EachField` is a record/type-level fold and must wait on field descriptor
  semantics.
- `$PatternReturn` and `$FindReturn` require a specified Lua-pattern subset and
  conservative fallback.
- `$SetMetatable` is not an operation name. It is a primitive capability name
  represented as `primitive_cap("$SetMetatable")`; `set_metatable` fixes
  metatable state without sealing own-field construction.
- `$Name` is not admitted.

Retired `$` encodings stay retired: `$Lit*`, `$Unit`, `$idx_*`, `$pos_*`,
`$opt_*`, `$ro_*`, `$spread_*`, `$computed_*`, `$opaque_*`.

### Packs And Correlation

Return packs are value-list types. Correlated alternatives are represented as
whole-pack alternatives until a named movement site consumes them. Slotwise
union is a correlation-loss operation, not the default semantics of returns or
destructuring.

### Tables And Mutation

Tables are identities. Records are sealed observations of table identities.
Open construction state is not a record type and must not enter ordinary
subtyping. Writes, sealing, metatable setting, escape, and alias invalidation
are identity transitions.

### Guards, Assertions, And Overloads

User guards and assertion signatures are fact transitions only after proof.
Their narrowing component is not an effect and not a return type. Their failure
or nonlocal-exit behavior belongs to the error/effect fork above.

Overloads are intersections of callable branches at use sites, but exporting an
overloaded function requires checking the implementation body under every
declared branch.

## Known Conflicts To Resolve

### v6 Plan Reads Like The Active Path

`docs/typechecker-v6-plan.md` still describes v6 as a coherent implementation
target. For v7 work it must be treated as research/prototype input. Any v6 rule
that survives must be copied or restated into the v7 kernel.

Resolution: add a status banner and avoid implementing from v6 docs directly
when the task is v7.

### Unified Type-System Design Reads Like Canonical Current Design

`docs/type-system-design/README.md` says the directory is the "single canonical
design" for Crescent's type system. That was true for the v5/v6 consolidation
effort, but it is too strong for v7. The modules remain valuable mining input,
especially for lattice, packs, effects, records, and setmetatable, but they are
not proof-producing kernel specs.

Resolution: add a status banner that scopes "canonical" to the pre-v7 unified
design lineage.

### Contextual Control Effects Are A Real Admission Fork

`docs/type-system-design/05-effects.md` and the README present effects as
designed. The v7 kernel has not admitted full effect rows yet, but the older M5
design clearly treats runtime errors as an effect: `error(msg)` produces
`!throw<E>`, and `pcall` discharges that effect into a success/failure pack.
The same shape applies to `yield`: coroutine bodies may suspend with `Y` and
resume as `S`, and `coroutine.create` discharges that into
`Coroutine<Y, S, R>`.

Resolution: v7 must not casually exclude errors from the effect story. Before
typing `error`, `pcall`, assertion failure behavior, or totality-sensitive
function contracts, v7 must either admit a minimal `throws(E)` effect with
composition/discharge/certificate rules or explicitly state that throwing is
outside the first soundness theorem.

The current v7 framing is **contextual control flow**, not a generic side-effect
bucket:

- `throws(E)` and `yields(Y, S)` are plausible initial effects;
- IO authority is modeled as explicit runtime cap values, not an `io` effect;
- table mutation is modeled first by identity transitions, not by a `mutates`
  row.

### Setmetatable Semantics Diverge

The unified design's M6 treats `setmetatable` as sealing construction. v7 now
chooses a different semantic model: the primitive `set_metatable` fixes
metatable state on an open identity but does not by itself seal own-field
construction.

Resolution: v7 owns the active rule. Post-setmetatable reads and writes must be
metatable-aware; if `__newindex`/`__index` behavior is unknown, the checker
rejects rather than pretending the table sealed.

### Current v4 Typechecker Docs Are Operational, Not Normative For v7

`lib/type/static/CLAUDE.md` contains strong rules such as "No new `$`
intrinsics" and a permanent-intrinsics list. For v7, this becomes an admission
discipline, not a blanket prohibition: a `$` form may be admitted only with a
kernel contract and certificate boundary.

Resolution: use v4 docs as implementation archaeology and source evidence, not
as v7 authority.

## Next Consolidation Tasks

1. Write `IntrinsicSpec` sections for one intrinsic at a time, starting with
   `$Opaque` because it is closest to a pure type constructor.
2. Specify metatable-aware field read/write semantics after the v7/M6
   setmetatable fork decision.
3. Define the minimal first replay subset: exact node payloads, canonical term
   serialization, and stale-input rejection tests.
4. Complete remaining `luajit51-crescent` target details: numeric-string
   grammar, exact integer preservation, table length proofs, and cdata operator
   families.
5. Implement a standalone MR0 verifier spike against
   `docs/typechecker-v7-mr0-payloads.md`, without connecting it to v4/v6
   inference.
6. Specify the external declaration environment interface enough for project
   globals files, module declarations, and trusted primitive values to be
   certificate inputs without becoming kernel rules.
7. Create a v7 TODO list that references kernel sections instead of older v5/v6
   module names.
8. Audit `docs/type-system.md` for stale claims about `any`, force casts, and
   current soundness gaps before using it as v7 philosophy input.
9. Work through `docs/typechecker-v7-missing-feature-audit.md` from highest-risk
   missing classification to lowest.
