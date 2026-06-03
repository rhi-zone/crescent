# Typechecker v7 Design Pass: Setmetatable

This is an iterative first-principles pass. It is pre-spec design work, but it
chooses the setmetatable seal/fix fork.

## Question

Does `set_metatable` seal table construction, or only fix metatable state?

Older design notes disagreed. One line treated `setmetatable` as sealing the
in-construction table. The current v7 kernel sketched a no-seal rule but marked
it provisional.

## First-Principles Derivation

Runtime `setmetatable(t, mt)` does not seal `t`.

After setting a metatable, Lua still allows later assignments to `t`. The
semantic change is not "the table is now sealed"; the semantic change is:

```text
table identity id now has fixed metatable mt
```

Reads and writes after that point may be affected by metatable semantics:

- `__index` can affect absent-field reads;
- `__newindex` can affect absent-field writes;
- operator metamethods can affect non-field operations.

Therefore sealing on `setmetatable` is a checker convenience, not a runtime
fact. v7 should not use it as the semantic model.

## Decision

Choose:

```text
set_metatable fixes metatable state and does not by itself seal own-field
construction
```

The table may still later become sealed by observation, annotation, return,
escape, unknown call, or any other rule that requires a stable record view.

## Table States

The table identity state remains:

```text
TableState =
  open(own_record, metatable?)
  sealed(own_record, metatable?)
  escaped(own_record?, metatable?, reason)
```

`set_metatable(id, mt_claim)` transitions:

```text
open(own_record, none) -> open(own_record, mt_claim)
```

It rejects if:

- the identity is escaped;
- the identity already has a different metatable;
- the target does not have the trusted primitive capability;
- the metatable claim is not stable enough for the target profile's
  metatable rules.

UNRESOLVED: exact equivalence rule for "same metatable" claims.

## Writes After Setmetatable

The fact that construction remains open does not mean absent-field writes can
ignore the metatable.

After a metatable is fixed, field assignment must use the table assignment
judgment:

```text
AssignField(id, key, claim)
```

That judgment must decide whether the write is:

- a raw own-field write;
- a write to an existing own field;
- a `__newindex` dispatch;
- rejected because the checker cannot prove which semantics applies.

Until `__newindex` semantics are admitted, a sound checker may accept only:

- writes to existing own fields;
- writes when it can prove the metatable has no applicable `__newindex`;
- explicit raw writes through a raw primitive, once specified.

It must not blindly extend own fields after an unknown metatable is installed.

## Reads After Setmetatable

Absent-field reads after metatable assignment must use lookup semantics:

```text
LookupField(id, key)
```

Lookup must decide whether the result comes from:

- an own field;
- an `__index` table chain;
- an `__index` function call;
- rejection due to unknown/cyclic/metatable-imprecise lookup.

Until lookup semantics are admitted, metatable-backed reads are rejected. Own
field reads can still be accepted.

## Constructor Pattern

The common Lua pattern is:

```lua
local self = setmetatable({}, Class)
self.x = 1
```

This remains admissible in the full design if the checker proves `Class` has no
applicable `__newindex`, or if `self.x` is otherwise a raw own-field write.

If `Class.__newindex` is unknown, rejecting `self.x = 1` is conservative and
sound.

This is stricter than blindly allowing construction extension, but it matches
runtime semantics.

## Sealing

Sealing still exists. It just does not happen because the function named
`setmetatable` was called.

Sealing occurs when the checker needs a stable record observation:

- annotation export;
- return/export boundary;
- subtyping as a record;
- unknown call or escape;
- explicit seal operation, if surface syntax ever exposes one.

Sealing preserves metatable metadata:

```text
open(record, mt) -> sealed(record, mt)
```

## Interaction With Primitive Capabilities

`set_metatable` remains authorized only by:

```text
primitive_cap("$SetMetatable")
```

The runtime binding named `setmetatable` may have that type through a target
external declaration input. Aliases preserve the capability. Shadowing does not
acquire it.

## Interaction With Operators And Methods

This decision unblocks later metatable lookup design, but does not specify it.

Required later rules:

- terminating `__index` chain lookup;
- `__newindex` assignment semantics;
- method-call lowering through field lookup plus self argument;
- operator lookup through metamethods;
- raw operation primitives that bypass metamethods.

No operator or method-dispatch rule should be admitted before those are written.

## Rejected Alternative

### Seal On Setmetatable

Rejected as the semantic model:

```text
set_metatable(id, mt) => sealed(record, mt)
```

Reason: this does not match Lua runtime behavior. It can be a conservative
implementation restriction, but not the first-principles semantics.

If a staged checker wants to reject post-setmetatable construction writes until
metatable assignment semantics are implemented, it may do so by rejection, not
by claiming `setmetatable` sealed the table.

## Adversarial Review

### Soundness Lens

The decision is sound because it separates two facts:

- metatable state is fixed;
- stable record observation requires sealing.

Residual risk: allowing open construction after metatable assignment is unsound
unless writes become metatable-aware. The design explicitly requires rejection
or proof for absent-field writes when `__newindex` may apply.

### Runtime-Fidelity Lens

The decision matches Lua better than seal-on-setmetatable.

Residual risk: runtime fidelity increases the amount of metatable semantics the
checker must specify before accepting common OO idioms.

### Ad-Hocness Lens

The decision avoids making `setmetatable` a magical phase boundary. It is just
an identity transition authorized by a primitive capability.

Residual risk: implementing constructor ergonomics by special-casing
`setmetatable({}, Class)` would reintroduce ad-hocness. The correct route is
general `__newindex`/raw-write reasoning.

### Usability Lens

Users may expect `setmetatable({}, Class); self.x = 1` to work.

That can work once the checker can prove the write is raw. Until then, rejecting
is preferable to sealing fiction or unsound extension.

## Decision

Choose:

```text
set_metatable fixes metatable state; it does not seal own-field construction
```

The next design pass should tackle module/declaration environments or
metatable lookup. Module environments are broader, but metatable lookup is the
direct dependency for method dispatch and operators.
