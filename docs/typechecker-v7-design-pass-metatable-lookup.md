# Typechecker v7 Design Pass: Metatable Lookup And Assignment

This is an iterative first-principles pass. It is pre-spec design work, but it
chooses the direction for metatable-aware field lookup, assignment, raw
operations, and invalidation.

## Question

How do table field reads and writes interact with metatables?

The setmetatable pass chose:

```text
set_metatable fixes metatable state; it does not seal own-field construction
```

That creates the next obligation: field reads and writes after metatable
assignment must account for `__index` and `__newindex`. Also, `getmetatable` and
`setmetatable` must not be special-cased by source name. Metatable semantics can
be builtin; the functions that expose them are ordinary values with primitive
capabilities.

## First-Principles Derivation

Metatable behavior is a semantic relation over table identity state.

```text
LookupField(Store, id, key) => ValueClaim or reject
AssignField(Store, id, key, claim) => Store or reject
```

These relations are built into the table/object semantics. They are not derived
from the spelling of a callee named `getmetatable`, `setmetatable`, `rawget`, or
`rawset`.

Primitive functions merely expose or bypass these relations:

- `primitive_cap("$SetMetatable")` authorizes metatable-state transition;
- `primitive_cap("$GetMetatable")` observes metatable state;
- raw primitives perform raw own-table operations that bypass metamethods.

## Decision

Choose structural metatable lookup/assignment judgments:

```text
LookupField(Γ, id, key) => ValueClaim
AssignField(Γ, id, key, claim) => Γ'
RawLookupField(Γ, id, key) => ValueClaim
RawAssignField(Γ, id, key, claim) => Γ'
```

Field syntax uses `LookupField`/`AssignField`. Raw primitives use
`RawLookupField`/`RawAssignField`. None of these dispatch on source names.

## Table State

Use metatable-preserving table states:

```text
TableState =
  open(own_record, metatable?)
  sealed(own_record, metatable?)
  escaped(own_record?, metatable?, reason)
```

Escaped tables still have metatable state. Escape limits precision and
construction extension; it does not erase runtime metatable identity.

## Metatable Claims

A metatable claim must be stable enough to support lookup.

Useful cases:

- no metatable;
- known sealed metatable record;
- known metatable identity with stable facts;
- unknown/escaped metatable.

If the metatable claim is unknown or escaped and the operation depends on a
metamethod absence/presence proof, reject or use an explicit unsafe boundary.

## LookupField

`LookupField(Γ, id, key)` resolves ordinary field reads.

Algorithmic shape:

1. If `key` exists in the table's own record, return the own-field claim.
2. If the table has no metatable, reject absent-field reads or return nil only
   when the table's row/index policy proves nil.
3. If metatable has no `__index`, use the own-record absent-field rule.
4. If metatable `__index` is a table identity, continue lookup in that table.
5. If metatable `__index` is a function, model the call with arguments
   `(table, key)`.
6. If lookup is cyclic, imprecise, or exceeds the proof budget, reject.

The lookup relation must record a dependency on:

- the receiver identity;
- the receiver metatable slot;
- every metatable identity traversed;
- each `__index` field observed;
- any function call effects/posts used during lookup.

## AssignField

`AssignField(Γ, id, key, claim)` resolves ordinary field writes.

Algorithmic shape:

1. If `key` exists in the table's own record, write the own field if mutable.
2. If the table is open, has no metatable, and the key is absent, extend the own
   record.
3. If the table has a metatable with no `__newindex`, an open table may extend
   the own record.
4. If metatable `__newindex` is a table identity, assign into that table.
5. If metatable `__newindex` is a function, model the call with arguments
   `(table, key, value)`.
6. If `__newindex` presence/absence is unknown, reject.

This is the critical consequence of the setmetatable decision. Open
construction may continue after metatable assignment only when the checker can
prove the assignment is raw own-field extension or otherwise model the
`__newindex` path.

## Raw Operations

Raw operations bypass metamethods and operate on own table state.

```text
RawLookupField(Γ, id, key)
RawAssignField(Γ, id, key, claim)
RawLen(Γ, id)
RawEqual(Γ, a, b)
```

They should be exposed through primitive capabilities or trusted stdlib
declarations, not source-name checks.

Raw writes still invalidate field facts and lookup dependencies. "Raw" means
bypass metamethod dispatch, not bypass soundness accounting.

## Getmetatable

`getmetatable` is not semantically special by name.

An external declaration input may bind the runtime value named `getmetatable` to:

```text
primitive_cap("$GetMetatable")
```

The primitive spec observes table metatable state:

```text
PrimitiveSpec("$GetMetatable").transition = observe_metatable
```

Decision direction after the target-profile pass: `luajit51-crescent` models
public protected-metatable behavior. If the actual metatable has a stable
`__metatable` field, public `$GetMetatable` returns that protected value rather
than the internal metatable. The kernel may still track the internal metatable
state for lookup dependencies and invalidation.

See `docs/typechecker-v7-design-pass-target-profile.md`.

## Setmetatable

`setmetatable` remains:

```text
primitive_cap("$SetMetatable")
```

Its primitive spec performs:

```text
IdentityStep(set_metatable(id, mt_claim))
```

It does not dispatch by source name and does not seal own-field construction.

Decision direction after the target-profile pass: under `luajit51-crescent`,
public `$SetMetatable` rejects when the current metatable has a stable protected
`__metatable` field. Debug capabilities that bypass this are not in the default
external declaration input.

Metatable clearing with `setmetatable(t, nil)` remains outside v7 until a
`clear_metatable(id)` identity transition and certificate rule are specified.
The first LuaJIT profile conservatively rejects it.

See `docs/typechecker-v7-design-pass-target-profile.md`.

## Invalidation

Metatable lookup creates dependencies beyond the receiver field.

Invalidate dependent facts when:

- receiver own field `key` is written;
- receiver metatable is changed;
- any traversed metatable table is written at `__index` or `__newindex`;
- any traversed `__index` table has relevant fields changed;
- a raw write changes an own field observed by lookup;
- an unsafe/unknown call may mutate or escape a relevant identity;
- a metatable function used for lookup has effects that invalidate facts.

Mutation of the metatable table matters. If `Class.__index` changes, facts about
instances that depended on the old `Class.__index` are invalid.

## Method Dispatch

Method syntax is not separate semantics:

```lua
obj:method(a, b)
```

lowers to:

```lua
tmp = LookupField(obj, "method")
tmp(obj, a, b)
```

The call uses ordinary pack movement with `self` inserted as the first argument.
No method-name special casing is admitted.

## Operators

Operator metamethod lookup is the same design family but not fully specified in
this pass.

The operator pass should use:

- primitive scalar operator rules where applicable;
- metatable lookup for `__add`, `__eq`, `__len`, etc.;
- rejection on unknown/cyclic/imprecise lookup;
- no per-operator local predicates as substitutes for lookup.

## Rejected Alternatives

### Name-Special Get/Set

Rejected:

```text
if callee text is "getmetatable" then observe metatable
if callee text is "setmetatable" then set metatable
```

Reason: aliases, shadowing, imports, and target profiles would be unsound or
inconsistent. Primitive capability values expose built-in semantics; names do
not.

### Blind Own-Field Extension After Setmetatable

Rejected:

```text
open(record, mt).write_absent(k, v) => open(record + k, mt)
```

unless absence of applicable `__newindex` or raw-write behavior is proved.

Reason: Lua may route absent writes through `__newindex`.

### Metatable Lookup As Record Width Subtyping

Rejected:

```text
table with __index fields <: record with those fields
```

as ordinary record subtyping.

Reason: metatable lookup is operational, may call functions, may be cyclic, and
depends on mutable metatable state. It must be a lookup judgment with
dependencies and invalidation.

## Adversarial Review

### Soundness Lens

The design is sound-oriented because it treats metatable lookup as an
operational relation with explicit dependencies. It does not smuggle
metatable-provided fields into sealed own-record subtyping.

Residual risk: `__index` functions can have effects, mutation, and arbitrary
return behavior. The checker must model those calls or reject them.

### Ad-Hocness Lens

The design keeps built-in metatable semantics separate from source-name
special-casing. `getmetatable`, `setmetatable`, `rawget`, and `rawset` are
ordinary values with primitive capabilities.

Residual risk: method-call ergonomics may tempt `obj:foo`-specific logic. The
lowering must go through lookup plus ordinary call.

### Mutation/Invalidation Lens

The design explicitly invalidates lookup facts when receiver, metatable, or
traversed tables mutate.

Residual risk: dependency tracking can become expensive. A conservative checker
may invalidate broadly, but it must not keep stale lookup facts.

### Termination Lens

Metatable chains can be cyclic.

Residual risk: lookup must carry a visited set or proof budget. Budget failure
is rejection, not fallback to `unknown`.

## Decision

Choose:

```text
metatable semantics are built-in lookup/assignment relations over table
identity state; getmetatable/setmetatable/raw operations expose those relations
only through primitive capabilities, never by source-name dispatch
```

The next design pass should tackle module/declaration environments, because
primitive capability values, external declarations, FFI declarations, and imports all
need provenance.
