# Typechecker v7 Roadmap

This is the recursive planning document for v7.

It is not a feature wishlist. It exists to keep the work from degrading into
organic growth. Every implementation slice should either close an item here or
add a more precise subdocument that makes the next slice obvious.

## North Star

v7 is a proof-producing checker architecture:

```text
Lua source + annotations + external inputs
  -> elaborator emits certificate
  -> small replay verifier checks certificate
  -> accepted claims are exactly replay-accepted roots
```

The long-term proof story is:

```text
formal kernel semantics
  -> mechanized proof of kernel/replay soundness
  -> production implementation emits evidence for that kernel
```

The production checker is not trusted for soundness. The trusted base should be
the kernel rules, canonical inputs, and the replay verifier.

## Refinement Discipline

Each roadmap item has one of four statuses:

- **Design blocked:** the rule is not precise enough to implement.
- **Spec ready:** prose rules, failure behavior, certificate shape, and
  adversarial cases exist.
- **Verifier slice:** table-native replay exists with fixtures.
- **Elaboration slice:** source/annotation frontend can emit the certificate.

Moving an item forward requires:

- semantic rule;
- well-formedness rule if it introduces a new payload category;
- failure/rejection behavior;
- certificate node shape;
- adversarial fixture;
- note explaining why the rule is substrate rather than a one-off result.

## Milestones

### M0: Replay Kernel Skeleton

Status: **Verifier slice in progress.**

Goal: prove the certificate architecture can reject missing semantic work and
accept only named proofs.

Current verifier:

- scalar type well-formedness;
- selected subtyping replay;
- closed pack movement;
- closed arrow call replay;
- closed return replay;
- literal expression claims;
- immutable context entries for MR0;
- local place reads;
- closed value-list pack construction with producer correspondence;
- unsafe/trusted boundary nodes;
- roots over accepted proofs;
- canonical term IDs for canonicalizable terms.

Primary docs:

- `docs/typechecker-v7-minimal-replay-subset.md`
- `docs/typechecker-v7-mr0-payloads.md`
- `docs/typechecker-v7-mr0-coverage-audit.md`

Closed in this slice:

1. Table-native `ContextEntry` indexing for immutable MR0 contexts.
2. `ExprNode(local_read)` over stable local place IDs.
3. `PackNode(values_closed)` and `StmtNode(return_closed)` producer
   correspondence, so return replay is tied to a value producer rather than an
   arbitrary prebuilt `pack_claim`.

Current next step:

1. Implement `BinderNode(closed_params_context)`.
2. Implement `FunctionNode(closed_arrow_body)`.
3. Add kind-aware validation for `function_signature_export` roots.

Why this next: it connects the existing call/return substrate to actual binding
facts without touching tables, modules, effects, or inference.

### M1: Source-Independent Function Body Replay

Status: **Design blocked.**

Goal: accept a function-body certificate without parsing Lua source:

```text
function f(x: integer): number
  return x
end
```

This milestone still operates over table-native certificates. It does not infer
or parse source. It proves the kernel can connect:

- parameter binder places;
- local read;
- pack claim construction;
- return movement;
- arrow claim/export.

Required subdocs:

- `docs/typechecker-v7-mr0-contexts.md` for places, contexts, local reads, and
  closed value-list/return producer correspondence. Status: verifier slice for
  the MR0 local-read subset.
- `docs/typechecker-v7-mr0-function-body.md` for function-value/body/export
  replay. Status: spec ready.

Do not implement:

- table field reads/writes;
- metatables;
- overload export;
- source parser integration.

### M2: Canonical Inputs And External Certificates

Status: **Spec partially ready.**

Goal: move from in-memory table fixtures to external, deterministic certificate
files.

Already done:

- deterministic table-native serialization;
- SHA-256 term IDs in strict mode.

Missing:

- non-integer numeric canonical encoding;
- context IDs;
- target/source/declaration digest validation;
- external certificate format/parser;
- malformed-input test corpus.

Required subdoc:

- `docs/typechecker-v7-canonical-inputs.md`

Design constraint: never use host `tostring(number)` as semantic digest input.
Numeric payloads need a target-stable encoding.

### M3: Source Elaboration For A Tiny Lua Subset

Status: **Design blocked.**

Goal: parse and elaborate a minimal source subset into MR certificates:

- literals;
- local declarations;
- local annotations;
- function definitions with annotated arrows;
- local reads;
- returns;
- calls of explicitly claimed arrows.

This is where v7 starts becoming a checker rather than only a verifier.

Required subdocs:

- `docs/typechecker-v7-elaboration-mr0.md`
- `docs/typechecker-v7-annotation-surface-mr0.md`

Design constraint: elaboration is untrusted. If a frontend emits the wrong
certificate, replay must reject.

### M4: Tables And Identity

Status: **Spec sketched.**

Goal: table literal identity, own-field writes, sealed record observations, and
record subtyping.

Primary docs:

- `docs/typechecker-v7-design-pass-setmetatable.md`
- `docs/typechecker-v7-design-pass-metatable-lookup.md`
- `docs/typechecker-v7-kernel-semantics.md`

Required subdoc:

- `docs/typechecker-v7-table-identity-rules.md`

Design constraint: primitive capability calls must not be implemented before
identity transitions exist, because primitive calls authorize identity
transitions rather than emulate them.

### M5: External Environments

Status: **Design sketched.**

Goal: explicit declaration, module, FFI, and target inputs with provenance.

Primary docs:

- `docs/typechecker-v7-design-pass-module-provenance.md`
- `docs/typechecker-v7-luajit51-target-table.md`
- `docs/typechecker-v7-missing-feature-audit.md`

Required subdocs:

- `docs/typechecker-v7-decl-env.md`
- `docs/typechecker-v7-module-env.md`
- `docs/typechecker-v7-ffi-env.md`

Design constraint: no concrete stdlib set is part of the kernel spec. Concrete
declarations are driver/project input.

### M6: Flow Facts, Guards, And Assertions

Status: **Design sketched.**

Goal: truthiness, local facts, type guards, assertion signatures, and fact
invalidation.

Primary docs:

- `docs/typechecker-v7-design-pass-places.md`
- `docs/typechecker-v7-missing-feature-audit.md`

Required subdoc:

- `docs/typechecker-v7-flow-facts.md`

Design constraint: facts attach to stable semantic places, not source names.
Shadowed names must not inherit primitive behavior or facts.

### M7: Effects

Status: **Design sketched.**

Goal: contextual-control effects for `throws(E)` and `yields(Y, S)`.

Primary docs:

- `docs/typechecker-v7-design-pass-effects.md`
- `docs/typechecker-v7-kernel-semantics.md`

Required subdoc:

- `docs/typechecker-v7-effects-calculus.md`

Design constraint: IO/caps are runtime values, not effects. Do not add an `io`
effect.

### M8: Type-Level Computation And Generics

Status: **Design sketched.**

Goal: rank-1 generics, kinded first-order type-level functions, match types, and
eventually selected higher-rank/HKT features.

Primary docs:

- `docs/typechecker-v7-design-pass-generics-typelevel.md`
- `docs/typechecker-v7-missing-feature-audit.md`

Required subdoc:

- `docs/typechecker-v7-typelevel-calculus.md`

Design constraint: do not admit `$EachField`/helper intrinsics until their
`IntrinsicSpec` or replacement type-level calculus exists.

### M9: Mechanized Kernel

Status: **Design blocked.**

Goal: transcribe the kernel into a proof assistant and prove replay soundness
for an MR subset.

Prerequisites:

- small-step or big-step semantics for the admitted Lua subset;
- formal definitions of Type, Pack, Claim, Context, Node, Root;
- replay relation;
- theorem statement for accepted roots.

Required subdocs:

- `docs/typechecker-v7-mechanization-plan.md`
- proof-assistant-specific files once the tool is chosen.

Design constraint: do not try to verify the production checker first. Verify the
kernel/replayer and keep elaboration untrusted.

## Active Frontier

Current active frontier:

```text
M0 -> M1: context/local replay for source-independent function body certificates
```

Immediate implementation:

```text
ContextEntry indexing
ExprNode(local_read)
pack_claim construction for local read result
fixtures connecting parameter place -> local_read -> return_closed
```

Stop and escalate if any of these become unclear:

- whether places are identifiers, paths, or structured values in MR0;
- whether context IDs must be canonical before local-read replay;
- how binder parameter claims become context locals;
- whether local reads depend on mutation/invalidation in the MR0 subset.
