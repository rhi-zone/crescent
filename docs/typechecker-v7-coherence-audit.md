# Typechecker v7 Coherence Audit

This document audits v7 as a semantic whole. It is not a source index and it is
not an implementation plan.

For the current v7 entry point and ordered decision queue, start with
`docs/typechecker-v7.md`.

## Verdict

v7 is coherent only as a conservative kernel that rejects every feature whose
rules are not fully admitted.

It is not yet a complete full-checker design. Several features are present as
motivation, examples, or proposed syntax while their kernel rules are missing.
That is acceptable only if the first checker rejects those features. It becomes
the same failure mode as v4/v5 if implementation treats those sketches as
admitted behavior.

The largest risk is not lack of detail. The largest risk is a half-admitted seam:
syntax, examples, or stdlib contracts assume a feature exists, while the
well-formedness, movement, effect, identity, and certificate rules still reject
or ignore it.

## Coherence Test

A v7 feature is coherent only when all of these agree:

- the syntax/kind says where the construct can appear;
- well-formedness admits exactly those appearances;
- denotation or operational state explains what it means;
- movement, subtyping, call, identity, or reduction rules consume it;
- failure behavior is explicit;
- certificate nodes can replay the rule without inference or name magic;
- all dependent features either use those rules or remain rejected.

If any item is missing, the feature is research input, not admitted design.

## Consistent Core

The following core is internally coherent if interpreted conservatively:

- value-set types for single runtime values;
- closed packs and whole-pack alternatives for correlated returns;
- arrows with parameter packs, return packs, and normal-continuation
  postconditions;
- semantic subtyping with rejection on unproved relations;
- sealed record observations of table identities;
- open table construction facts outside the type lattice;
- identity transitions for table writes, sealing, escape, and fact invalidation;
- overload values as intersections of arrows, with bodies checked under every
  branch before export;
- user guards and assertion postconditions as proof obligations over normal
  returns;
- unsafe/trusted boundaries only as explicit certificate events.

This core does not yet provide precise Lua stdlib typing, precise varargs,
`pcall`, coroutine typing, metatable lookup, module imports, or type-level
folds.

## Blocking Incoherences

### Rest Packs

Rest packs were simultaneously described as part of `Pack` and as not admitted.
That makes varargs, `pcall`, iterators, `select`, and coroutine APIs unsafe to
implement.

Resolution: the first kernel may reserve a `rest` field in the data model, but
`WFPack` rejects non-empty rest until rest movement rules, certificate nodes,
and pack-adjustment semantics are mechanized.

### Contextual Effects

`throws(E)` and `yields(Y, S)` are the right shape for contextual control flow,
but they are not yet integrated into arrows, sequencing, subtyping, overload
selection, or certificates.

Resolution: until the effect extension lands, v7 can prove only normal-return
partial correctness. Precise `error`, `pcall`, coroutine yield/resume, assertion
failure behavior, and totality-sensitive contracts remain rejected or trusted
unsafe boundaries.

### Assertion Failure

Assertion postconditions are fact transitions on normal continuation. Runtime
assertion functions also have a failure path that does not return normally.
Those are different facts.

Resolution: first-kernel assertion signatures may state only what is true when
the call returns normally. Typing the failure path requires the contextual
effect extension, or the function must be treated as a trusted boundary whose
non-returning behavior is outside the theorem.

### Postcondition Binders

Postconditions mention places. Before the place/binder pass, arrow types stored
only parameter types, not parameter binders or positional places.

Resolution status: the place/binder design pass chooses semantic places plus
binder-aware arrows. The remaining work is kernel transcription and certificate
detail, especially call-site substitution and explicit weakening when an actual
argument has no stable caller place.

### Primitive Capabilities

`$SetMetatable` was used as a callee type in certificates, but the `Type`
grammar had no primitive capability constructor.

Resolution status: the primitive-capability design pass chooses first-class
value types, represented as `primitive_cap(name)`, rather than hidden claim
metadata. The remaining work is detailed `PrimitiveSpec` transcription and
certificate validation for each primitive.

### Setmetatable Seal Fork

The kernel currently sketches "fix metatable without sealing own-field
construction"; older M6 sketches "seal on setmetatable". Both cannot be active.

Resolution: no metatable lookup, `__index`, method dispatch, or constructor
template semantics should be admitted until the fork is closed. The current
kernel rule is provisional unless v7 explicitly chooses it.

### Record Indexers And Writes

Record subtyping can use indexers to satisfy fields, but the operational
read/write/indexer movement rules are not yet fully specified.

Resolution: indexer-backed field satisfaction must wait for explicit field and
index read/write judgments. Until then, indexers are a denotational sketch, not
an implementation rule for arbitrary table operations.

### Generic Examples

Examples using `<T <: ...>` imply rank-1 bounded generics, while the first
kernel says type-level variables are not admitted.

Resolution: either admit rank-1 bounded generics with skolemization, escape
checks, WF rules, and certificates, or keep generic examples clearly marked as
future extension examples.

## Dependency Order

The coherent admission order is:

1. `unknown` movement and concrete-consumption restrictions.
2. Closed-pack hygiene: no admitted rest until rest movement exists.
3. Arrow postcondition binders.
4. Primitive capability specs.
5. Table identity read/write/indexer judgments.
6. The `set_metatable` seal/fix fork.
7. Minimal contextual effects: `throws(E)` and possibly `yields(Y, S)`.
8. Open/rest packs and pack variables.
9. Module/declaration/FFI environments and trusted bridge certificates.
10. Match/type-level computation and field-descriptor folds.
11. Operator and metamethod semantics.
12. Stdlib profiles.

Some later work can be specified in parallel, but implementation must not admit
a later feature unless its dependencies are already kernel rules.

## Incompatible Shortcuts

The following shortcuts are explicitly incoherent for v7:

- typing `pcall` precisely without both rest packs and `throws(E)` discharge;
- typing coroutine yield/resume precisely without `yields(Y, S)` and open packs;
- admitting `$Require` without `ModuleEnv`, provenance, and trusted-boundary
  certificate nodes;
- admitting `$EachField<T, F>` with arbitrary `F` while HKTs remain excluded;
- implementing metatable `__index` lookup before the setmetatable fork is
  resolved;
- treating IO as an effect while the design says IO authority is a runtime
  capability value;
- recovering from missing semantics by widening to `unknown` or `any`;
- dispatching on runtime value names instead of typed primitive capabilities.

## Working Rule

When a sketch and an admission rule disagree, the rejection rule wins. The
checker may be incomplete, but it must not pretend that a feature is sound
because the design has an example for it.
