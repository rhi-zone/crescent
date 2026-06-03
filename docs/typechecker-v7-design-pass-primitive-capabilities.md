# Typechecker v7 Design Pass: Primitive Capabilities

This is an iterative first-principles pass. It is pre-spec design work, but it
chooses a direction for primitive callable cutouts.

## Question

Are primitive capabilities value types or claim metadata?

This matters because some runtime values authorize checker-modeled transitions
that are not ordinary pure arrows. `setmetatable` is the motivating example:
calling the trusted stdlib value mutates table identity state in a way ordinary
user functions cannot acquire by sharing the same source name.

## First-Principles Derivation

Primitive authority is carried by runtime values.

If a value can be assigned, aliased, imported, passed through parameters, or
stored in a table, then its authority must move with the value. That argues for
representing primitive capability as a value type:

```text
primitive_cap(name)
```

This type classifies runtime values that have a trusted primitive authority
token. It is not an arrow, not an operation term, and not a source-name rule.

## Decision

Choose primitive capabilities as value types.

```text
Type includes primitive_cap(name)
```

`ValueClaim` metadata may still record provenance and identity, but primitive
call authority is visible in the value type.

## Why Not Claim Metadata?

Rejected:

```text
ValueClaim = { type: T, primitive_capability?: name }
```

Reason: this hides semantic authority outside the type algebra. Hidden metadata
would need bespoke movement rules for assignment, return, field storage,
imports, overloads, and aliases. That is exactly the kind of untracked checker
state v7 is trying to avoid.

If authority is a value type, ordinary movement preserves it by preserving the
value claim. If a function accepts or returns a primitive value, that is visible
in the arrow type and certificate.

## Denotation

`primitive_cap(name)` denotes trusted runtime values with that primitive token:

```text
[[primitive_cap(name)]] = { v | PrimitiveToken(v) = name }
```

Normal Lua code cannot synthesize such a token. It can only receive one through
a trusted boundary, such as an external declaration environment.

Subtyping:

```text
primitive_cap(A) <: primitive_cap(B) iff A = B
primitive_cap(A) <: unknown
```

No primitive cap is a subtype of an ordinary arrow. A primitive value is
callable only through the primitive-call judgment.

## Primitive Call Judgment

Primitive calls are explicit movement sites:

```text
PrimitiveCallCheck(Γ, callee_claim, args) => Γ', Effect, PackAlt, Postcondition
```

Requirements:

- `callee_claim.type` proves `primitive_cap(name)`;
- `PrimitiveSpec(name)` exists;
- argument packs satisfy the primitive spec's domain;
- the primitive spec's state transition succeeds;
- the result pack and postcondition are produced by the primitive spec;
- the certificate contains a `PrimitiveCallNode`.

This is not normal call dispatch. Ordinary `CallCheck` may branch to
`PrimitiveCallCheck` only after proving the callee has `primitive_cap(name)`.
It must not inspect the callee's source text.

## PrimitiveSpec

Every primitive capability has a contract:

```text
PrimitiveSpec = {
  name,
  domain,
  effects,
  transition,
  returns,
  post,
  failure,
  certificate_node
}
```

The spec authorizes exactly one semantic primitive operation. If a runtime
stdlib function needs multiple behaviors, those behaviors must be expressed
inside one primitive spec or by an ordinary checked/trusted wrapper function.

## Initial Candidate

`primitive_cap("$SetMetatable")` is the initial candidate because
`setmetatable` changes table identity state.

It authorizes:

```text
IdentityStep(set_metatable(id, mt_claim))
```

The setmetatable design pass chooses the transition direction: fix metatable
state and keep own-field construction open. `$SetMetatable` authorizes that
identity transition, but it does not by itself admit full metatable lookup,
`__newindex`, or method/operator semantics.

## Interaction With Aliasing

Primitive capability values alias like ordinary values:

```lua
local sm = setmetatable
sm(t, mt)
```

This works only if `sm`'s claim preserves `primitive_cap("$SetMetatable")`.
The checker must not require the spelling `setmetatable`.

Conversely:

```lua
local function setmetatable(t, mt) end
setmetatable(t, mt)
```

does not acquire primitive behavior. The function's source name is irrelevant.

## Interaction With Modules And External Declarations

External declaration environments introduce primitive capability values through
trusted boundaries:

```text
DeclEnv.binding("setmetatable") =
  primitive_cap("$SetMetatable")
```

Alternative declaration inputs may omit or replace the binding. The primitive
authority comes from the declaration certificate, not from a hardcoded global
name.

Modules may import and re-export primitive capability values only if provenance
tracks the trusted source.

## Interaction With Overloads

A primitive capability is not an overload branch.

If a value has type:

```text
primitive_cap("$SetMetatable") | arrow(...)
```

then a call must prove which callable mode is available or reject ambiguity.
The checker must not silently prefer the primitive branch.

Intersection with arrows is allowed only if a value is proven to satisfy both
claims. That requires a trusted declaration or an explicit wrapper design.

## Interaction With Unsafe Boundaries

An unsafe boundary may claim a value has `primitive_cap(name)`, but that must be
visible as an unsafe certificate event.

This is powerful. A forged primitive capability can authorize kernel state
transitions. Therefore unsafe primitive-cap exports should be high-severity in
audits.

## Rejected Alternatives

### Source-Name Dispatch

Rejected:

```text
if callee text is "setmetatable" then IdentityStep(set_metatable)
```

Reason: aliases would fail, shadowing would become unsound, imports would be
ambiguous, and user functions could accidentally or maliciously acquire
primitive behavior by name.

### Arrow Encoding

Rejected as the primitive substrate:

```text
setmetatable : (table, table) -> table
```

Reason: ordinary arrows summarize value returns and postconditions. They do not
authorize non-arrow identity transitions unless those transitions are hidden
inside the checker. A checked wrapper may have an arrow type, but the primitive
it calls still needs a primitive spec.

### Hidden Capability Metadata

Rejected as the primary representation.

Reason: it forces every movement site to remember to preserve or drop hidden
metadata. That is an ad-hocness trap.

## Adversarial Review

### Soundness Lens

The design is sound if `primitive_cap(name)` values can originate only from
trusted boundaries or checked primitive declarations, and if every use is
validated against `PrimitiveSpec(name)`.

Residual risk: unsafe exports of primitive caps are extremely powerful. They
must be explicit, grep-able, and probably forbidden outside target-profile or
FFI/declaration code unless the user opts into unsafety.

### Ad-Hocness Lens

The design avoids source-name dispatch and hidden claim metadata. Primitive
behavior follows ordinary value flow and one explicit primitive-call judgment.

Residual risk: adding many primitive specs could become an ad-hoc stdlib
encoding. The admission rule must require each primitive to authorize a kernel
operation that cannot be expressed by ordinary arrows.

### Modularity Lens

The design composes with modules because imported primitive values carry normal
types and provenance.

Residual risk: module environments must preserve provenance; otherwise an
ordinary module could launder unsafe primitive-cap claims.

### Implementation Lens

The checker can implement primitive calls as a separate branch after callee type
checking proves `primitive_cap(name)`.

Residual risk: a convenient implementation shortcut might still dispatch on AST
callee names. Tests and certificate validation should include alias and
shadowing cases specifically to catch this.

## Decision

Choose:

```text
primitive capabilities are value types, represented as primitive_cap(name)
```

The next design pass should resolve whether the full arrow includes contextual
effects from the start, because primitive specs may need to produce or discharge
effects.
