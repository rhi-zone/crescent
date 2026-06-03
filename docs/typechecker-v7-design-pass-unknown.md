# Typechecker v7 Design Pass: Unknown Movement

This is an iterative first-principles pass. It is pre-spec design work, but it
chooses a direction for the `unknown` fork.

## Question

What is `unknown` allowed to do?

This must be answered before modules, FFI, casts, fallback behavior, and broad
stdlib typing. If `unknown` becomes a convenience escape hatch, v7 loses the
soundness-fatal property.

## First-Principles Derivation

`unknown` derives as the top value type:

```text
[[unknown]] = Value
T <: unknown
```

That means a value claimed as `unknown` may be any runtime value. It does not
mean the checker may pretend it is a string, table, function, or number.

The elimination rule follows directly:

```text
an unknown value may be consumed only by operations whose domain includes all
runtime values, unless a prior fact narrows it or an explicit unsafe boundary
changes the claim
```

This is not a special restriction bolted onto subtyping. It is the ordinary
meaning of operation preconditions.

If an operation requires a `string`, then `unknown` is insufficient because
`unknown <: string` is false. If an operation accepts every runtime value, then
`unknown` is sufficient.

## Movement Classes

### Preservation

Preserving movement does not inspect the concrete value.

Allowed examples:

- bind `x = e` where `e : unknown`;
- assign `unknown` to an unannotated binding;
- pass `unknown` to a parameter explicitly typed `unknown`;
- return `unknown` where the declared return pack expects `unknown`;
- store a value as an unknown field when the destination type allows unknown.

These operations preserve ignorance. They do not create facts.

### Total Observation

Some operations are defined for every runtime value. They may consume
`unknown`.

Allowed examples:

- truthiness tests;
- equality and inequality against arbitrary values;
- primitive runtime classification such as `type(x)`;
- identity-preserving movement through packs.

Total observations may produce facts. For example:

```lua
if type(x) == "string" then
  -- x : string here
end
```

The soundness reason is that `type(x)` is total over all runtime values, not
that `unknown` was treated as a string.

### Concrete Operation

Concrete operations require a proper subtype of `unknown`.

Rejected without narrowing or unsafe boundary:

- call `x(...)` when `x : unknown`;
- index `x[k]` when `x : unknown`;
- read `x.foo` when `x : unknown`;
- write `x.foo = v` when `x : unknown`;
- arithmetic on `x : unknown`;
- pass `x : unknown` to a `string`, `number`, table, function, or nominal
  parameter;
- return `x : unknown` where the declared return type is concrete.

These operations have runtime preconditions. Accepting them would claim safety
that the checker has not proved.

### Refinement

Facts can narrow `unknown` by intersection:

```text
current(x) = unknown
fact(x is T)
current'(x) = unknown & T = T
```

Examples:

- `type(x) == "string"` narrows to `string`;
- `x ~= nil` narrows to `~nil`;
- a checked guard can narrow to its proven predicate;
- a checked assertion can narrow on the normal continuation.

The fact source must itself be proven. Unchecked assertions are unsafe
boundaries.

### Unsafe Claim Change

An explicit force cast may export a concrete claim from `unknown`:

```text
force(x, T) : T
```

This is not narrowing and not evidence. It is an unsafe boundary and must appear
in the certificate.

## Consequences

### No Gradual Unknown

This rejects TypeScript-style "use unknown after assertion or narrowing" but
does not adopt gradual `any` behavior. `unknown` is safe top, not dynamic top.

### No Recovery Widening

When a rule fails, the checker must not replace the result with `unknown` to
continue. `unknown` can appear only from:

- explicit annotations;
- trusted external boundaries;
- conservative abstraction of values whose concrete type is intentionally not
  known;
- joins that semantically produce top.

It cannot appear as "the checker got confused".

### Trusted Boundaries Stay Contained

FFI, modules, dynamic require, and target stdlib declarations may expose
`unknown` when the boundary cannot prove a stronger claim. Users must narrow or
force before concrete use.

This keeps trust localized: a weak import type does not automatically infect the
program with unsound concrete operations.

### Unknown Calls Seal Open Tables

Passing an open table identity through an unknown call cannot preserve
construction facts. The callee could store, mutate, alias, or escape the table.

Therefore an unknown call, when admitted as an unsafe/trusted boundary, seals or
escapes relevant identities and invalidates dependent facts. A fully sound
first kernel may simply reject unknown calls.

## Required Kernel Shape

The kernel does not need a separate "unknown movement" rule if every operation
has an explicit domain. It does need named movement judgments for places where
`unknown` might otherwise be used as fallback:

- expression checking against a concrete type;
- call callee checking;
- field/index read and write;
- arithmetic/operator application;
- return movement;
- assignment to annotated targets;
- trusted boundary export;
- force casts.

Each judgment must either prove ordinary subtyping/domain membership, apply a
proven refinement fact, or emit an unsafe boundary.

## Rejected Alternatives

### Gradual Unknown

Rejected:

```text
unknown can be used at any operation and produces unknown
```

Reason: this is `any` under another name. It admits concrete runtime errors as
typed behavior and hides missing rules.

### Unknown-As-Implementation-Failure

Rejected:

```text
if inference fails, infer unknown
```

Reason: this makes `unknown` a recovery mechanism instead of a semantic claim.

### Concrete Consumption With Warning

Rejected:

```text
allow x.foo when x : unknown, but warn
```

Reason: warnings do not preserve soundness. The claim is either proved, unsafe,
or rejected.

## Adversarial Review

### Soundness Lens

The chosen rule is sound because every accepted elimination from `unknown` is
either total over all values, justified by a prior fact, or explicitly unsafe.
No operation may assume a concrete runtime shape merely because the value is
unknown.

Residual risk: the phrase "total observation" must be kept small. If a stdlib
function is classified as total without a runtime semantics proof, it becomes a
backdoor.

### Ad-Hocness Lens

The rule is not keyed to the spelling `unknown`. It follows from operation
domains. This is good: field access, calls, arithmetic, and returns do not need
special unknown cases.

Residual risk: implementation may be tempted to add `if type == unknown then
return unknown` branches. The spec must forbid that pattern except for
preserving movement or explicitly total observations.

### Usability Lens

This is stricter than gradual typing. Imported unknown values require narrowing
or force casts before concrete use.

This is acceptable under the v7 goal. Users who want unsafeness can write an
explicit boundary; users who want soundness get real narrowing obligations.

## Decision

Choose:

```text
unknown is denotational top; elimination is governed by each operation's domain
```

There is no separate permissive unknown elimination rule.

The next design pass should derive the place/binder model, because refinements
of `unknown` are only meaningful if facts have stable targets.
