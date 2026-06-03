# Typechecker v7 Design Pass: Places And Binders

This is an iterative first-principles pass. It is pre-spec design work, but it
chooses a direction for facts, refinements, guards, and assertion
postconditions.

## Question

What can a fact be about?

The `unknown` movement pass requires proven refinements before concrete use.
Refinements are only meaningful if facts have stable targets. If facts attach
to arbitrary expressions or source names, writes, aliases, destructuring,
imports, and function calls can make them unsound.

## First-Principles Derivation

A fact is a scoped claim about a stable semantic location.

Therefore:

```text
fact target != source expression
fact target != source spelling
fact target = Place
```

A place is a semantic handle that the checker can track through control flow
and invalidate when the underlying value may have changed.

## Place Model

Choose semantic place IDs.

```text
Place =
  local(slot_id)
  param(param_id)
  upvalue(cell_id)
  result(result_id)
  field(identity_id, key)
  imported(binding_id)
```

This is a design model, not final syntax. Surface names, destructuring patterns,
and annotation binders resolve to these place IDs.

### Local Places

A local binding has a stable slot identity for its lifetime.

Assignment to the local invalidates facts about that local. It does not
invalidate facts about the old value's table identity unless the assignment also
mutates that table.

### Parameter Places

Function types bind parameter places, not source parameter names.

Source annotation names are binder syntax only. They desugar to parameter IDs
inside the arrow:

```text
arrow(params = [param p0: unknown], post = assert(p0, HasType(p0, string)))
```

This prevents exported function types from depending on caller-visible source
spelling.

### Upvalue Places

Captured variables are mutable cells. A closure that can write an upvalue
invalidates facts about that upvalue.

UNRESOLVED: exact closure analysis is deferred, but the place category must
exist so captured-local facts are not treated like immutable lexical facts.

### Result Places

Result places are ephemeral binders used inside arrow postconditions only if a
postcondition needs to relate returned values to input places.

Example design pressure:

```text
returns (result y: T) post assert(result(y), HasType(result(y), NonNil))
```

UNRESOLVED: whether result binders are needed in the first full design or can be
represented by return-pack types plus caller destructuring facts.

### Field Places

A field place is anchored to a table identity, not to a source path:

```text
field(id, "foo")
```

This matters because aliases share identity:

```lua
local a = t
local b = t
if a.foo ~= nil then
  -- fact is about field(id(t), "foo"), not spelling a.foo
end
b.foo = nil -- invalidates the same field fact
```

A field place is stable only when:

- the base expression has a known table identity;
- the key is a stable exact key;
- the table identity has not escaped in a way that can mutate the field;
- no write/call invalidates that identity/key fact.

### Imported Places

Imported declarations and module bindings can be places only through a
declaration or module environment with provenance.

Until those environments exist, imported facts are trusted-boundary facts, not
ordinary local facts.

## Facts

A fact refines the current claim for a place:

```text
Fact = place -> ValueClaim
```

Fact application is intersection with the current value claim:

```text
current(place) = A
fact(place is T)
current'(place) = A & T
```

If `A & T` is empty, the branch is unreachable.

Facts are scoped. They flow through edges, join at control-flow joins, and are
invalidated by writes, escapes, and calls with unknown mutation behavior.

## Binder-Aware Arrows

Choose binder-aware arrows as the design direction.

The full arrow shape is:

```text
arrow(params: BinderPack, effects, returns: Pack, post: Postcondition)
```

`BinderPack` is a pack whose fixed positions may bind parameter IDs:

```text
BinderPack =
  binder_pack(items: ParamBinding*, rest: RestBinding?)

ParamBinding =
  { id: param_id, type: Type }
```

The binder IDs are in scope for the arrow's postcondition. They are not source
names and are alpha-renamable.

## Call-Site Substitution

At a call, callee parameter places are substituted with caller places when the
corresponding argument expression has a stable place.

```text
callee post: assert(param p0, HasType(p0, string))
actual arg: x
substitution: p0 -> local(slot_x)
caller post: assert(local(slot_x), HasType(local(slot_x), string))
```

If an actual argument has no stable place, the value can still be passed if its
type satisfies the parameter, but place facts about that parameter cannot be
exported to the caller.

Example:

```lua
assert_string(make_value())
```

The call may typecheck, but it does not narrow a caller place because there is
no caller place to narrow.

Dropping an inapplicable postcondition is sound only as weakening. The
certificate must record that the postcondition was not exported because no
stable caller place existed.

## Field Facts Across Destructuring

Post-destructuring correlation is not only a pack issue. Table aliases also
carry correlated identity facts.

Example:

```lua
local a, b = pair()
if a.kind == "ok" then
  -- fact may be about field(id(a), "kind")
end
```

If `pair()` returns correlated table identities, destructuring must preserve
the identity correlation until a movement site explicitly loses it. Slotwise
type unions are insufficient because field facts may depend on which identity
alternative was returned.

Therefore place/fact design depends on pack correlation:

- value-list alternatives preserve identity alternatives;
- destructuring binds places to claims that may still be correlated;
- scalar correlation loss must also drop or weaken dependent identity facts.

## Invalidation

Facts are invalidated by semantic effects, not by syntax.

Invalidation sources:

- assignment to the same local/upvalue place;
- field write to the same identity/key;
- write through an alias of the same identity;
- call that may mutate or escape the identity;
- passing a place to an unsafe/trusted boundary with unknown mutation behavior;
- control-flow join with a predecessor that lacks the fact;
- closure/upvalue mutation.

Unknown calls are especially dangerous. A call through an unknown callee cannot
preserve facts about reachable mutable identities unless the call is rejected or
the relevant identities are sealed/escaped and facts invalidated.

## Guards And Assertions

Guard signatures refer to parameter binders.

```text
is_string : arrow([p0: unknown], effects, returns ["boolean"], post = true)
guard true-post: assert(p0, HasType(p0, string))
```

Assertion signatures are normal-continuation posts:

```text
assert_string : arrow([p0: unknown], effects, returns [], post = assert(p0, HasType(p0, string)))
```

At call sites, `p0` is substituted with the caller place if stable.

This keeps guard/assertion facts fully sound:

- the function body must prove the fact for its parameter binder;
- the caller receives the fact only for a stable actual place;
- mutation invalidates the fact through normal place rules.

## Rejected Alternatives

### Source-Name Facts

Rejected:

```text
Fact = "x" is T
```

Reason: source names are not stable across shadowing, imports, aliases,
modules, or function boundaries.

### Expression Facts

Rejected:

```text
Fact = expr is T
```

Reason: arbitrary expressions can have effects, allocate new values, call
functions, or read mutable state. Only resolved stable places may carry facts.

### Caller-Name Assertion Types

Rejected:

```text
asserts x is T
```

as a semantic form where `x` is a free source name.

Allowed only as surface syntax that resolves to a parameter binder in the
function type.

### Path Facts Without Identity

Rejected:

```text
Fact = a.foo is T
```

when `a.foo` is stored as a source path rather than a field place anchored to a
table identity.

Reason: aliases can mutate the same field through a different path.

## Adversarial Review

### Soundness Lens

The design is sound-oriented because facts attach only to stable semantic
places, and every place category has invalidation obligations.

Residual risk: field places depend on accurate identity tracking. If the checker
loses aliases or lets escaped identities keep field facts, the place model gives
false confidence.

### Ad-Hocness Lens

The design avoids source-spelling dispatch. Names, parameters, fields, and
imports all resolve to semantic handles before facts attach.

Residual risk: call-site postcondition weakening can become ad hoc if the
checker silently drops facts. Certificates must explicitly record postcondition
substitution, export, weakening, or rejection.

### Ergonomics Lens

Users can still write named assertion syntax. The names are annotation binders,
not semantic global names.

Residual risk: if non-place arguments to assertion functions typecheck but do
not narrow anything, diagnostics must explain that no stable place existed.

### Correlation Lens

The design correctly generalizes the earlier pack-correlation concern to table
identity facts. Facts about fields can be correlated with which table identity
alternative was returned.

Residual risk: if pack movement loses correlation before place binding, field
facts after destructuring become unsound or useless.

## Decision

Choose:

```text
facts target semantic places; arrows bind parameter places; call sites
substitute parameter places with stable caller places
```

The next design pass should derive primitive capabilities, because
`setmetatable` and other non-arrow primitives need to target identity
transitions without source-name magic.
