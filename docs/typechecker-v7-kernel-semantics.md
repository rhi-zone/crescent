# Typechecker v7 Kernel Semantics

This document starts the v7 semantic kernel. It is the prose target for later
mechanization and certificate checking.

v7 is not "v6 with more tests." v7 means:

- unsoundness is fatal;
- accepted programs must be justified by kernel rules;
- implementation progress is not soundness evidence unless it can produce or
  validate those justifications.

This document defines the first semantic objects: runtime values, value types,
packs, subtyping, claims, and movement sites. It intentionally does not define a
production checker architecture.

## Scope

The first kernel admits only the constructs required to expose the historical
failure points:

- scalar Lua values;
- first-class functions;
- value-list packs for calls and returns;
- union, intersection, complement, `unknown`, and `never`;
- records as table observations;
- table identity, mutation, sealing, and alias invalidation;
- flow facts and checked guards;
- overload declarations;
- explicit unsafe boundaries.

The first kernel does not admit:

- effects;
- HKTs;
- refinement types beyond guard-exported facts;
- metatable precision beyond the table-identity seam;
- module IO or require resolution;
- stdlib name magic;
- parser or diagnostic behavior.

Those features may be added only by extending the kernel.

## Deferred Feature Classification

The excluded features are not all the same kind of thing. v7 should classify
them before admitting any of them.

### Effects

Effects are properties of computations, not properties of single runtime values.
They do not belong in `Type`.

If admitted, effects extend arrows:

```text
arrow(params: Pack, effects: Effect, returns: Pack, post: Postcondition)
```

The first effect system must answer:

- how effects compose through calls and sequencing;
- how effects are discharged or handled;
- how effects interact with overload branch selection;
- whether effects participate in arrow subtyping;
- whether effect polymorphism exists;
- whether effect inference is allowed or annotations are required.

Untyped effects are labels such as `throws`, `io`, or `mutates`.

Typed effects carry payloads:

```text
throws(E)
yields(Pack)
mutates(region)
requires(capability)
```

Typed effects are more than labels. They introduce new semantic domains whose
payloads may contain value types or packs. They therefore need their own
subtyping/equality rules and certificate nodes. They are not admitted by merely
adding a string set to arrows.

Effect unsoundness examples:

- treating a throwing function as total;
- losing the payload type of a thrown error;
- selecting an overload branch while ignoring that only some branches perform a
  required effect;
- allowing a typed mutation effect to escape its region.

### Mutation Of References

Table identity is the only mutable-reference model in the first kernel.

General references, cells, boxes, upvalues-as-refs, or region variables are a
state extension. They should reuse the same soundness shape as tables:

```text
RefId
RefState = { contents: Type, phase/capability/region metadata }
```

Required rules:

- reads produce the current content claim;
- writes check against an invariant content type unless the reference is proven
  uniquely owned;
- aliases invalidate narrowed facts;
- readonly views may be covariant;
- mutable views are invariant;
- escaping references lose precision or require region/capability proof.

Reference mutation may also be represented as a typed effect:

```text
mutates(region)
reads(region)
```

That is an extension decision. The core rule is that mutation must be accounted
for either by explicit state transition rules or by typed effects whose
semantics include those transitions. It cannot be a side effect hidden in a
function type.

### Rank-N Polymorphism

Rank-N polymorphism is not an effect. It is a quantifier/scoping extension to the
type language and typing judgments.

Admitting rank-N requires:

- `forall` types;
- skolemization for checking polymorphic values;
- instantiation for using polymorphic values;
- escape checks so skolems do not leak;
- certificate nodes for `forall` introduction and elimination.

Rank-N interacts with overloads and guards because a branch or predicate may be
polymorphic. It also interacts with mutation because storing a polymorphic value
in a mutable location is usually restricted by a value restriction or equivalent
capability rule.

The first kernel therefore excludes rank-N. Monomorphic arrows are enough to
validate calls, packs, records, identity, and guards.

### HKTs

HKTs are not effects. They are a kind system and type-level computation
extension.

Admitting HKTs requires:

- kinds, at least `Type`, `Pack`, and constructor arrows;
- kind checking before subtyping;
- type-level application;
- beta reduction or another definitional equality;
- termination bounds for type-level computation;
- certificate nodes for kinding and reduction.

HKTs interact with records and effects if they can construct record types,
effect rows, or pack types. They also interact with complement/normalization if
type-level reduction must happen before emptiness decisions.

The first kernel excludes HKTs. If later admitted, the kind checker becomes a
precondition for the value-type denotation: only kind-`Type` terms can enter
`Type`.

### Type Guards

Type guards are not effects in the first kernel.

A guard is a proof-producing predicate declaration:

```text
guard(params) proves Predicate on true returns
```

Calling a verified guard may produce a flow fact on a branch edge. The guard
does not mutate the value type of a variable globally; it exports scoped facts
that can be invalidated.

If the guard function has runtime behavior such as throwing, IO, or mutation,
that behavior is an ordinary arrow effect once effects are admitted. The
predicate-exporting part is still a fact transition, not itself an effect.

Assertion signatures are the same category: fact transitions, not value types.

Kernel shape:

```text
AssertSig(place, Predicate)
AssertTypeSig(place, Type)        -- sugar for AssertSig(place, HasType(place, Type))
```

Surface syntax may look like `asserts x is T`, but the kernel should not encode
that as `asserts(place is Type)`. `is` belongs to the predicate syntax, not to
function application.

An assertion signature is a type-level contract for a function. It does not mean
the type checker executes the assertion. It means: if a call to a function with
this signature returns normally, the continuation may assume the asserted
predicate. If the assertion fails at runtime, control does not continue normally.

Therefore the signature has two semantic components:

- a normal-continuation fact transition;
- a possible nonlocal exit on failure.

Assertion signatures are not return types and cannot be intersected with value
types. A function type such as:

```text
() -> (T & asserts x is U)
```

is ill-kinded in the kernel: `T` classifies a returned value, while
`asserts x is U` classifies a continuation fact transition.

The kernel form is an arrow with both a return pack and a postcondition:

```text
arrow(params: Pack, returns: Pack, post: Postcondition)
Postcondition = true | assert(place, Predicate) | post_and(Postcondition, Postcondition)
```

Surface syntax may choose a compact spelling, but the semantic shape must keep
returned values and continuation facts in separate fields. Intersecting them
would let ordinary value-type algebra manipulate control-flow facts, which is a
category error and a likely unsoundness source.

Multiple assertion signatures are conjunctions in the postcondition domain, not
repeated return-type suffixes. A surface spelling such as:

```text
() -> T asserts x is U asserts y is V
```

would elaborate to:

```text
arrow(
  params = pack([]),
  returns = pack([T]),
  post = post_and(assert(x, HasType(x, U)), assert(y, HasType(y, V)))
)
```

The postcondition conjunction is not `T & ...`; it combines facts that must all
hold on the normal continuation. If either assertion cannot be proved for a user
function body, the assertion signature is not exported.

In the first kernel, the fact transition may be admitted only after the
assertion implementation is verified or the assertion function is marked as a
trusted/unsafe boundary. The failure behavior is represented as "does not return
normally on failed predicate" in the assertion rule. If a full effect system is
later admitted, that failure behavior can also be reflected as a typed effect
such as `throws(E)` or `exits`, but the narrowing part remains a fact
transition.

Soundness condition:

```text
If assert_p(x) returns normally, then Predicate(x) holds on the continuation.
```

This is the assertion analogue of a boolean guard's true-branch condition:

```text
If guard_p(x) returns true, then Predicate(x) holds on the true edge.
```

### Type Assertions

There are two different constructs that should not be conflated.

Checked type assertion:

```text
assert_type(expr, T)
```

This emits an obligation `typeof(expr) <: T` or a runtime-test proof, then
exports `expr : T` only after proof. This is a movement/fact rule.

Runtime assertion:

```text
assert(predicate)
```

This may narrow the continuation path if the predicate is a verified guard or a
recognized primitive predicate. It may also throw on failure. The narrowing is a
flow fact; the possible throw is an effect only if the effect system is admitted.

Unchecked type assertion / force cast:

```text
force(expr, T)
```

This is an unsafe boundary. It is not a guard, not an effect discharge, and not a
proof. It exports a claim only with an explicit unsafe certificate node.

## Runtime Domains

The kernel models a Lua execution state as:

```text
Store σ      = table identity -> table object
Env  ρ       = variable -> value
Value v      =
  nil
  boolean(b)
  integer(i)
  number(n)
  string(s)
  function(f)
  table(id)
  thread(id)
  userdata(id)
  cdata(id)

ValueList vs = finite sequence of Value
```

`integer(i)` is also a `number`. The exact LuaJIT numeric representation is not
the first kernel's concern; the only pinned lattice edge is
`integer <: number`.

Tables are identities. A table value is `table(id)`, not a structural record.
Records are observations of table identities after the checker has established a
stable view.

## Type Domains

`Type` classifies single values.

```text
Type T =
  never
  unknown
  nil
  boolean
  integer
  number
  string
  thread
  userdata
  cdata
  literal(base, value)
  arrow(params: Pack, returns: Pack, post: Postcondition)
  record(fields, indexes, row)
  nominal(name)
  union(T, T)
  intersection(T, T)
  complement(T)
```

`Postcondition` classifies normal-continuation fact transitions attached to an
arrow. It is not a value type.

```text
Postcondition Q =
  true
  assert(place, Predicate)
  post_and(Q, Q)
```

`Pack` classifies value lists.

```text
Pack P = pack(items: Type*, rest: Type?)
```

The optional `rest` means zero or more additional values of that type. There is
one terminal rest position only. A pack is not a value type.

`PackAlt` classifies correlated alternatives of whole value lists.

```text
PackAlt A =
  one(Pack)
  either(PackAlt, PackAlt)
```

`PackAlt` exists because overloads and branches can produce correlated return
lists. It is not a type-level union of slots. A movement site may collapse or
adjust a `PackAlt`; ordinary type algebra may not.

`any` is not in `Type`. Unsafe boundaries may export unchecked claims, but that
is a certificate/audit event outside the sound type algebra.

## Denotation

The intended denotation is:

```text
[[T]]σ       ⊆ Value
[[P]]σ       ⊆ ValueList
[[PackAlt]]σ ⊆ ValueList
```

Selected clauses:

```text
[[never]]σ                 = ∅
[[unknown]]σ               = Value
[[nil]]σ                   = { nil }
[[integer]]σ               = all integer values
[[number]]σ                = all number values, including integers
[[literal(base, x)]]σ       = { x } when x has base
[[union(A, B)]]σ            = [[A]]σ ∪ [[B]]σ
[[intersection(A, B)]]σ     = [[A]]σ ∩ [[B]]σ
[[complement(A)]]σ          = Value \ [[A]]σ
[[pack([T1..Tn], nil)]]σ    = lists [v1..vn] where vi ∈ [[Ti]]σ
[[pack([T1..Tn], R)]]σ      = lists [v1..vn, r1..rk] where vi ∈ [[Ti]]σ and rj ∈ [[R]]σ
[[one(P)]]σ                 = [[P]]σ
[[either(A, B)]]σ           = [[A]]σ ∪ [[B]]σ
```

Arrow denotation is intentionally abstract in the first kernel:

```text
function(f) ∈ [[arrow(P, R, Q)]]σ
```

means that calling `f` with any argument list in `[[P]]σ` either produces a
return list in `[[R]]σ` and establishes postcondition `Q` on the normal
continuation, or reaches an explicit unsafe/runtime boundary admitted by the
operational semantics. The checker proves this for user functions by checking
their bodies under the arrow. Trusted external functions require an
unsafe/trusted certificate boundary.

Record denotation is also store-indexed:

```text
table(id) ∈ [[record(F, I, row)]]σ
```

means the current sealed observable table state for `id` satisfies the record
predicate: required fields are present with values in their field types,
readonly/mutable capabilities are respected, index signatures are respected, and
row policy is respected. An open construction identity is not in this
denotation until sealed.

## Subtyping

Subtyping is semantic inclusion:

```text
σ ⊨ A <: B  iff  [[A]]σ ⊆ [[B]]σ
```

The implementation and certificate checker may use a syntax-directed algorithm,
but the rule is justified only if it preserves this meaning.

Pinned algebraic rules:

```text
never <: T
T <: unknown
T <: T
literal(integer, i) <: integer
integer <: number
literal(string, s) <: string
A | B <: C        iff A <: C and B <: C
A <: B & C        iff A <: B and A <: C
A <: ~B           iff A & B is empty
```

Right-union and left-intersection require bounded emptiness or another admitted
decision procedure. If the procedure cannot prove the relation within the
kernel's budget, the checker rejects. It must not widen to `unknown` or `any`.

Type equality is both directions:

```text
A = B  iff  A <: B and B <: A
```

## Kernel Judgments

The prose rules above must eventually become judgments. The initial judgment
set is:

```text
WFType(Δ, T)                         -- T is a well-formed value type
WFPack(Δ, P)                         -- P is a well-formed value-list type
WFPost(Δ, Q)                         -- Q is a well-formed postcondition
Sub(Δ, T1, T2)                       -- T1 <: T2
EqType(Δ, T1, T2)                    -- T1 = T2
PackMove(Δ, dir, PackAlt, Pack)      -- value-list movement succeeds
ExprSynth(Γ, e) => Claim             -- synthesize expression claim
ExprCheck(Γ, e, T) => Proof          -- check expression against T
StmtCheck(Γ, s) => Γ'                -- statement fact transition
CallCheck(Γ, callee, args) => PackAlt, Postcondition
PostApply(Γ, Q) => Γ'                -- apply normal-continuation facts
GuardValid(Γ, f, Predicate)          -- true returns prove predicate
AssertValid(Γ, f, Postcondition)     -- normal returns prove postcondition
IdentityStep(Γ, op) => Γ'            -- table identity transition
CertOK(kernel, cert, claim)          -- certificate validates claim
```

`Δ` is the type-level context. In the first kernel it is mostly empty because
rank-N, HKTs, and type-level variables are not admitted. It exists so later
extensions have a named place to add binders instead of modifying every
judgment ad hoc.

`Γ` is the term/fact context:

```text
Γ = {
  bindings: symbol -> ValueClaim,
  flow: edge/place -> ValueClaim,
  identities: id -> TableState,
  unsafe: UnsafeBoundary*
}
```

All checker behavior must be expressible as one of these judgments or as an
explicit extension to this list.

### Well-Formedness

Well-formedness is the first anti-ad-hoc barrier.

Rules:

- packs are well-formed only if every item/rest is a well-formed `Type`;
- postconditions are well-formed only if their places are in scope and their
  predicates are well-formed;
- `arrow(P, R, Q)` is well-formed only if `P`, `R`, and `Q` are well-formed;
- `record(F, I, row)` is well-formed only if every field/index component is a
  well-formed `Type`;
- `Pack` and `Postcondition` are not well-formed as `Type`;
- effects, HKTs, rank-N binders, and refinement predicates are not well-formed
  until admitted by an extension.

This is where `T & asserts x is U` is rejected: the right operand is not a
`Type`, so the intersection is ill-formed.

### Subtyping And Equality Judgments

`Sub(Δ, A, B)` is defined only for well-formed value types.

`EqType(Δ, A, B)` is `Sub(Δ, A, B)` and `Sub(Δ, B, A)`.

Arrow subtyping:

```text
Sub(Δ, arrow(Pa, Ra, Qa), arrow(Pb, Rb, Qb))
```

requires:

- `PackMove(Δ, contra, one(Pb), Pa)` for parameters;
- `PackMove(Δ, co, one(Ra), Rb)` for returns;
- `PostImplies(Δ, Qa, Qb)` for postconditions.

`PostImplies(Qa, Qb)` means every fact guaranteed by the producer's normal
continuation is sufficient for the consumer's expected postcondition. For the
initial kernel:

```text
PostImplies(Q, true)
PostImplies(assert(p, A), assert(p, B)) if PredicateImplies(A, B)
PostImplies(post_and(A, B), A)
PostImplies(post_and(A, B), B)
PostImplies(Q, post_and(A, B)) if PostImplies(Q, A) and PostImplies(Q, B)
```

Predicate implication is initially limited to type predicates:

```text
PredicateImplies(HasType(place, A), HasType(place, B)) if Sub(A, B)
```

No other predicate implication is admitted until specified.

## Pack Interaction

Packs interact only at value-list movement sites.

Pack subtyping is not ordinary type subtyping. It is parameterized by the
movement direction:

```text
P <:pack[co] Q      -- producer returns usable as consumer returns
P <:pack[contra] Q  -- callee parameter pack substitutability
```

Closed covariant return packs use Lua return adjustment:

- surplus produced values may be discarded;
- missing produced values are `nil`;
- each consumed slot must be satisfied after that adjustment.

Closed contravariant parameter packs require exact arity unless an explicit rest
is present. A function that accepts a different fixed number of parameters is
not substitutable.

`PackAlt` preserves whole-list correlation until a movement site consumes it.
For example:

```text
either(pack(["ok", number]), pack(["err", string]))
```

is not the same as:

```text
pack(["ok" | "err", number | string])
```

The latter is an admitted widening only at a named correlation-loss movement
site, if such a site is added to the kernel.

### Pack Movement Judgment

`PackMove(Δ, dir, A, P)` consumes a `PackAlt` producer `A` at a movement site
expecting pack `P`.

Alternative rule:

```text
PackMove(Δ, dir, either(A, B), P)
  iff PackMove(Δ, dir, A, P) and PackMove(Δ, dir, B, P)
```

Closed scalar list adjustment is a helper inside `PackMove`, not a general type
operation:

```text
adjust(pack([A1..An], nil), m)[i] =
  Ai   when i <= n
  nil  when i > n
```

Covariant return movement:

```text
PackMove(Δ, co, one(pack([A1..An], nil)), pack([B1..Bm], nil))
  iff for each i in 1..m, Sub(Δ, adjust(A, m)[i], Bi)
```

Surplus producer returns are ignored by the adjustment.

Contravariant parameter movement:

```text
PackMove(Δ, contra, one(pack([A1..An], nil)), pack([B1..Bm], nil))
  iff n = m and for each i in 1..n, Sub(Δ, Bi, Ai)
```

Open packs, varargs, and rest interaction are not admitted until the rest rules
are mechanized. A checker may reject them before that point.

Scalar extraction is also a named movement:

```text
ScalarOf(either(A, B)) = union(ScalarOf(A), ScalarOf(B))
ScalarOf(one(pack([], nil))) = nil
ScalarOf(one(pack([A1..An], rest))) = A1
```

This is an explicit correlation-loss site. It is allowed for scalar expression
contexts, not for return-pack checking or destructuring that claims to preserve
correlation.

## Records

A record type is:

```text
Field = { type: Type, optional: boolean, readonly: boolean }
Index = { key: Type, value: Type, readonly: boolean }
Record = { fields: name -> Field, indexes: Index*, row: closed | open }
```

Rows and indexers are distinct:

- `row = open` means unlisted named fields may exist;
- an indexer `{ [K]: V }` means keys in `K` map to values in `V`;
- row openness does not type arbitrary keys;
- an indexer does not mean structural width openness.

Record subtyping is structural decomposition:

- for every supertype required field, the subtype must provide a named field or
  a covering indexer;
- a supertype optional field may be absent;
- an optional subtype field does not satisfy a required supertype field;
- readonly supertype fields are covariant;
- mutable supertype fields are invariant and require mutable subtype fields;
- index keys are contravariant;
- index values follow the same readonly/mutable rule.

This is a rule over sealed record observations. It is not a rule over open table
construction states.

### Record Subtyping Judgment

`Sub(Δ, record(Fa, Ia, rowa), record(Fb, Ib, rowb))` decomposes into named-field
and index obligations.

Named fields:

- for every `k` in `Fb`, if `Fa[k]` exists, check presence/modifier/value rules;
- if `Fb[k]` is optional and absent from `Fa`, accept;
- if `Fb[k]` is required and absent from `Fa`, a covering subtype indexer may
  satisfy it;
- otherwise reject.

Field value rule for subtype field `a` and supertype field `b`:

```text
if b.optional = false then a.optional must be false
if b.readonly = false then a.readonly must be false
if b.readonly = true  then Sub(Δ, a.type, b.type)
if b.readonly = false then EqType(Δ, a.type, b.type)
```

Index rule:

```text
Sub(Δ, super_index.key, sub_index.key)      -- key contravariance
Sub(Δ, sub_index.value, super_index.value)  -- readonly value covariance
EqType(Δ, sub_index.value, super_index.value) -- mutable value invariance
```

Row openness affects unknown extra fields only. It does not grant write
permission and does not type arbitrary keys.

## Table Identity

The table identity state is not a type.

```text
TableState =
  open(own_record)
  sealed(own_record, metatable?)
  escaped(own_record?, reason)
```

Open table identities are construction facts. They are not lattice values and
must not be passed to subtyping as records.

Operations:

```text
fresh_table         : Store -> id, Store
write_open_field    : id, key, ValueClaim -> Store -> Store or error
seal                : id -> Store -> RecordClaim or error
read_field          : id, key -> Store -> ValueClaim or error
write_sealed_field  : id, key, ValueClaim -> Store -> Store or error
escape              : id, reason -> Store -> Store
```

Rules:

- fresh table literals create open identities;
- direct writes to open identities extend or equate their own record;
- any observation requiring a stable value type seals first;
- sealed identities reject absent-field writes and readonly writes;
- escaped identities cannot be extended;
- writes and escapes invalidate dependent flow facts for aliases of the same
  identity.

### Identity Transition Judgment

`IdentityStep(Γ, op) => Γ'` is the only judgment that can change table identity
facts.

Fresh:

```text
IdentityStep(Γ, fresh_table) =>
  Γ[identities[id] = open(empty_record)]
```

Open write:

```text
IdentityStep(Γ, write(id, key, claim)) =>
  Γ[identities[id] = open(record + key)]
```

requires `id` to be open and unescaped. If `key` already exists, the new claim
must be equal to the existing field type. If `key` is new, the field is added to
the construction record.

Seal:

```text
IdentityStep(Γ, seal(id)) =>
  Γ[identities[id] = sealed(record)]
```

returns a `ValueClaim` whose type is the sealed `record` and whose identity is
`id`.

Sealed write:

```text
IdentityStep(Γ, write(id, key, claim)) => Γ'
```

requires:

- `id` is sealed;
- `key` exists;
- field is mutable;
- `claim.type` equals the field type;
- field/alias facts for `id` are invalidated in `Γ'`.

Escape:

```text
IdentityStep(Γ, escape(id, reason)) =>
  Γ[identities[id] = escaped(record?, reason)]
```

invalidates field/alias facts for `id` and prevents further construction
extension.

## Claims, Facts, And Obligations

A `ValueClaim` is:

```text
ValueClaim = { type: Type, identity: id? }
```

The `type` component is the value-set claim. The optional `identity` component
is provenance/capability for table-sensitive operations. It is not a type
member.

Facts are scoped claims:

```text
ExprFact     : expr -> ValueClaim
BindingFact  : symbol -> ValueClaim
FlowFact     : edge, place -> ValueClaim
IdentityFact : id -> TableState
```

An obligation is:

```text
Obligation = producer Type, consumer Type, site, reason
```

Annotations, overloads, guards, returns, assignments, and module boundaries
export facts only after their obligations are proven or explicitly marked as an
unsafe/trusted boundary.

## Movement Sites

Movement sites are the only places where claims are consumed or transformed.

### Scalar Expression

If a scalar context consumes a value-list producer, it takes the first produced
value. If none is produced, it consumes `nil`. Surplus values are discarded.

This is a correlation-loss site when applied to `PackAlt`.

### Binding And Assignment

A binding or assignment consumes a `PackAlt` according to the target arity. Each
target slot receives the adjusted type for that position. An annotated target
emits a subtype obligation before exporting the annotation as the binding fact.

Assignment to an existing table field routes through table identity operations,
not direct record subtyping.

### Call

To call a value with callee claim `C` and argument producer `A`:

1. prove `C` has one or more arrow branches;
2. adjust argument values to each branch parameter pack;
3. prove the adjusted arguments satisfy the branch parameters;
4. return a `PackAlt` of the matching branch return packs.

For an overload declaration, the implementation body must be checked under every
declared arrow branch before the overloaded claim is exported.

Call judgment sketch:

```text
CallCheck(Γ, callee, args) => PackAlt, Q
```

Steps:

1. `ExprSynth(Γ, callee) => C`.
2. Collect arrow branches from `C.type`. For the first kernel, branches are
   either a single `arrow` or an intersection of arrows.
3. For each branch `arrow(P, R, Q)`:
   - compute argument producer `A` from the argument expression list;
   - require `PackMove(Δ, contra, A, P)`;
   - if successful, include `R` in the result alternatives and `Q` in the
     matching postconditions.
4. If no branch matches, reject.
5. If multiple branches match, return `PackAlt` over whole return packs and
   postcondition disjunction is not admitted. Until postcondition disjunction is
   specified, multiple matching branches must have equivalent postconditions or
   the call is rejected.

This last rule prevents losing facts from overloaded assertion signatures.

### Template Calls

The first kernel does not infer exported shape-extension summaries for ordinary
functions.

For a function body such as:

```lua
function foo(x)
  x.foo = 1
end
```

the internal field write is still a normal identity/fact transition. The
question is whether that transition becomes a reusable callable summary.
Exporting the summary is risky because it must quantify over caller identities,
alias invalidation, allowed writes, overload branches, and postconditions.

The initial admitted alternative is an explicit template function:

```lua
--:: template
function foo(x)
  x.foo = 1
end
```

Template calls are checked by instantiating the body at the call site against
the actual argument facts:

```text
TemplateCallCheck(Γ, foo, args) => Γ', PackAlt
```

Rules:

- template functions are not first-class values unless a later rule
  monomorphizes or summarizes them;
- each call rechecks the body in a context where parameters are aliases of the
  actual argument claims;
- an optional template signature may be used as a fast precheck or expected
  parameter/return shape, but it is not an exported mutation summary;
- passing the optional signature is not sufficient for acceptance: the
  instantiated body still has to check against the actual caller facts;
- field writes in the body use `IdentityStep` on the caller's identities;
- internal postconditions become ordinary caller-context fact transitions;
- no exported mutation/postcondition summary is inferred from the template.

This supports local construction patterns:

```lua
local t = {}
foo(t)       -- body checked with t's fresh open identity; may extend t.foo
```

without pretending that `foo` has a general arrow type that creates `foo` for
all possible table arguments.

Non-template functions may still be given stricter precondition types, for
example:

```text
foo : <T <: { foo: integer, ... }>(x: T) -> nil
```

That type requires an existing writable `foo` field. It does not claim that the
function extends arbitrary table shapes.

Template signatures are therefore a shortcut path for fast rejection and better
errors, not a trust boundary. If a template signature says the call is
impossible, the checker may reject without instantiating the body. If it says
the call is possible, the checker still instantiates the body unless a later
certificate rule proves the signature is a complete summary.

### Return

A return statement consumes a `PackAlt` against the current function return
pack. Return checking uses covariant pack movement and preserves correlation
until the return movement site.

### Guard

A guard claim is exported only if every true-return path proves the predicate.
Guard-produced flow facts are scoped to the true edge and invalidated by writes,
alias escapes, and calls that may mutate relevant identities.

Guard validity:

```text
GuardValid(Γ, f, Predicate)
```

requires every path that returns literal `true` from `f` to prove `Predicate` in
that path's fact context. Paths returning `false` do not need to prove the
predicate. Paths that do not return normally do not export the predicate.

Assertion validity:

```text
AssertValid(Γ, f, Q)
```

requires every normal return path from `f` to prove postcondition `Q`.
Non-returning failure paths do not need to prove `Q`, but they also cannot reach
the normal continuation.

Postcondition application:

```text
PostApply(Γ, true) = Γ
PostApply(Γ, assert(place, HasType(place, T))) =
  Γ with place narrowed to current_type(place) & T
PostApply(Γ, post_and(A, B)) =
  PostApply(PostApply(Γ, A), B)
```

Fact application can fail if the place is not stable, not in scope, or its
identity-dependent fact has been invalidated.

### Unsafe Boundary

An unsafe boundary may export a claim without proof only if the certificate marks
the boundary explicitly. Unsafe boundaries are not type rules.

## Certificate Obligations

An accepted program must be explainable as a finite proof DAG whose nodes are
instances of kernel rules.

The certificate checker must verify at least:

- every exported annotation has a discharged subtype obligation;
- every overload body was checked under every branch;
- every overload call result is a `PackAlt` over matching branches, not a
  slotwise union unless a named correlation-loss site appears;
- every user guard proves its predicate on true returns;
- every record subtype proof uses sealed record observations;
- every table write goes through identity rules and invalidates relevant facts;
- every unsafe fact is marked as an unsafe/trusted boundary.

The certificate checker does not infer missing rules. If the proof object omits
a required step, validation fails.

### Certificate Node Families

Certificates are DAGs. Nodes reference prior nodes by ID and contain enough data
for the verifier to replay the kernel rule deterministically.

Minimum node families:

```text
WFTypeNode(T)
WFPackNode(P)
WFPostNode(Q)
SubNode(producer: Type, consumer: Type, rule, premises: proof*)
EqNode(left: Type, right: Type, sub_lr: proof, sub_rl: proof)
PackMoveNode(dir, producer: PackAlt, consumer: Pack, premises: proof*)
ExprNode(expr_id, claim: ValueClaim, rule, premises: proof*)
StmtNode(stmt_id, before: ContextId, after: ContextId, rule, premises: proof*)
CallNode(callee_expr, arg_exprs, result: PackAlt, post: Postcondition, premises: proof*)
PostNode(post: Postcondition, before: ContextId, after: ContextId, premises: proof*)
IdentityNode(op, before: ContextId, after: ContextId, premises: proof*)
GuardNode(function_id, predicate: Predicate, true_return_proofs: proof*)
AssertNode(function_id, post: Postcondition, normal_return_proofs: proof*)
UnsafeNode(site, exported_claim, boundary_kind)
```

The verifier checks node-local correctness only. It must not search for a
different overload branch, invent a missing subtype proof, or reinterpret an
unsafe node as a proof.

Required determinism:

- every referenced type, pack, postcondition, expression, statement, and context
  has a stable ID;
- normalization, if used, is either part of the kernel or represented by an
  explicit proof node;
- budget failure is not a certificate node for success;
- unsafe nodes are accepted only where the kernel allows an unsafe/trusted
  boundary.

### Certificate Examples

Checked annotation:

```text
ExprNode(e, claim = A, ...)
WFTypeNode(T)
SubNode(A.type, T, ...)
StmtNode(local x: T = e, before = Γ, after = Γ[x -> { type = T }], ...)
```

Overload declaration:

```text
WFTypeNode(arrow(P1, R1, Q1))
WFTypeNode(arrow(P2, R2, Q2))
StmtNode(body checked under arrow(P1, R1, Q1), ...)
StmtNode(body checked under arrow(P2, R2, Q2), ...)
ExprNode(f, claim = intersection(arrow(P1, R1, Q1), arrow(P2, R2, Q2)), ...)
```

Assertion call:

```text
CallNode(assert_string, { x }, result = one(pack([])), post = assert(x, HasType(x, string)), ...)
PostNode(assert(x, HasType(x, string)), before = Γ, after = Γ[x -> Γ[x] & string], ...)
```

Table seal:

```text
IdentityNode(fresh_table, Γ0, Γ1, ...)
IdentityNode(write(id, "tag", "ok"), Γ1, Γ2, ...)
IdentityNode(seal(id), Γ2, Γ3, ...)
ExprNode(t, claim = { type = record({ tag = "ok" }, [], closed), identity = id }, ...)
```

## Proof Targets

The first mechanized kernel should aim for these statements:

1. **Type denotation soundness.** If the kernel proves `v : T` in store `σ`,
   then `v ∈ [[T]]σ`.
2. **Subtyping soundness.** If the kernel proves `A <: B`, then
   `[[A]]σ ⊆ [[B]]σ`.
3. **Movement soundness.** If a movement site accepts producer claims for a
   consumer, then all runtime values/lists produced by the producer are safe for
   that consumer, except at explicit unsafe boundaries.
4. **Identity soundness.** Open table construction states are never observed as
   sealed record values; mutation after sealing cannot violate exported record
   claims.
5. **Certificate soundness.** If the certificate verifier accepts a proof for an
   exported claim, that claim follows from the kernel rules.

## Open Questions

These are not admitted yet:

- whether complement is mechanized as set complement directly or via a bounded
  normal form;
- whether `unknown` should be a denotational top only, with a separate movement
  restriction judgment for concrete consumers;
- the exact operational semantics for functions before recursion and closures
  are admitted;
- the minimal table/metatable semantics needed for real Crescent code;
- whether certificate checking is implemented in the proof assistant, generated
  from it, or written separately against extracted kernel definitions.
