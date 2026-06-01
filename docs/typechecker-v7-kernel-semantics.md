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
arrow(params: Pack, effects: Effect, returns: Pack)
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
  arrow(params: Pack, returns: Pack)
  record(fields, indexes, row)
  nominal(name)
  union(T, T)
  intersection(T, T)
  complement(T)
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
function(f) ∈ [[arrow(P, R)]]σ
```

means that calling `f` with any argument list in `[[P]]σ` either produces a
return list in `[[R]]σ` or reaches an explicit unsafe/runtime boundary admitted
by the operational semantics. The checker proves this for user functions by
checking their bodies under the arrow. Trusted external functions require an
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

### Return

A return statement consumes a `PackAlt` against the current function return
pack. Return checking uses covariant pack movement and preserves correlation
until the return movement site.

### Guard

A guard claim is exported only if every true-return path proves the predicate.
Guard-produced flow facts are scoped to the true edge and invalidated by writes,
alias escapes, and calls that may mutate relevant identities.

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
