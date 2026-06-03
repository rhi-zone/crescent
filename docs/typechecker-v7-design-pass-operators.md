# Typechecker v7 Design Pass: Operators And Metamethods

This pass decides the operator substrate.

The goal is not to enumerate implementation branches for every Lua token. The
goal is to define one semantic shape that covers primitive scalar operations,
metamethod-backed operations, raw bypass operations, target-specific numeric
policy, equality, and the value-producing control-flow expressions that look
operator-like in source.

## Load-Bearing Question

Can v7 type operators without reintroducing the v4/v5 pattern of local
predicates such as "is numeric", name-keyed builtin dispatch, and fallback
widening?

Decision: yes, if operators are operation judgments over typed operands and
target-profile operation tables.

The checker admits an operator result only when it can derive one of:

- a primitive operation rule from `TargetProfile`;
- a metamethod operation rule from the metatable lookup relation;
- a raw primitive rule that explicitly bypasses metamethod lookup;
- a control-flow expression rule for non-overloadable forms such as `and` and
  `or`.

If none applies, the operator is rejected. `unknown` does not supply a fallback
operator branch.

## Operator Judgment

Ordinary overloadable operators use:

```text
OpCheck(Γ, op, operands) => Γ', Effect, ValueClaim, Postcondition
```

`op` is a semantic operator tag, not a source token string:

```text
op ::= add | sub | mul | div | idiv | mod | pow
     | unm | band | bor | bxor | bnot | shl | shr
     | concat | len
     | eq | lt | le
```

The result is a single value claim because Lua operators produce one value.
Calls are not ordinary operators; callable table/userdata behavior is handled by
the call judgment, whose callee collection may include a `__call` metamethod
candidate.

`OpCheck` is the only admission point for overloadable operator expressions.
Individual operator implementations may have specialized premises, but they are
premises of this judgment, not independent checker shortcuts.

Certificate node:

```text
OpNode(
  op,
  operands,
  case = primitive | metamethod | raw,
  target_profile_id,
  dependencies,
  before = Γ,
  after = Γ',
  effect,
  result,
  post
)
```

The verifier checks the selected case against the corresponding kernel rule.

## Primitive Operator Case

Primitive scalar semantics are target-profile facts:

```text
TargetProfile.primitive_op(op, operand_types) => Effect, ValueClaim, Postcondition
```

Examples:

- LuaJIT and Lua 5.4 may disagree about integer/float details;
- `/`, `%`, bit operations, and integer literal preservation are target-specific;
- string coercion behavior, if any target admits it, belongs in the target
  profile, not in the generic type algebra.

The generic kernel may know stable lattice facts such as `integer <: number`,
but it must not hardcode a complete numeric tower that is false for some
selected runtime target.

Primitive operator failure is explicit:

```text
If TargetProfile.primitive_op has no derivation, the primitive case fails.
```

It does not widen operands or result to `unknown`.

## Metamethod Operator Case

If the primitive case does not derive, an overloadable operator may derive
through metatable lookup:

```text
MetamethodLookup(Γ, op, operands) => Γ_lookup, CallableClaim, dependencies
CallCheck(Γ_lookup, CallableClaim, operands_as_pack(op, operands)) => Γ', Effect, PackClaim, Postcondition
FirstValue(PackClaim) => ValueClaim
```

The operator-specific metamethod key is part of the target profile:

```text
TargetProfile.metamethod_key(add) = "__add"
TargetProfile.metamethod_key(eq) = "__eq"
...
```

That map is not source-name dispatch. It is the runtime semantics of the target.
The lookup relation is the same metatable substrate used for `__index` and
`__newindex`: table/userdata identity state, dependency tracking, termination
bounds, protected metatable behavior when relevant, and invalidation after
receiver/metatable/metamethod mutation.

Metamethod lookup failure is explicit:

```text
If no applicable metamethod is derivable, the metamethod case fails.
```

The checker must not invent a synthetic callable or use a field named `__add`
without going through the metatable relation.

## Equality

Equality is an operator, but it is the highest-risk operator because it is also
a common source of flow facts.

Primitive equality is target-profile semantics over value identity and primitive
value comparison. Table/userdata identity equality is not structural record
equality.

Metamethod equality is admitted only under the target's exact equality rule. For
Lua variants where equality metamethod dispatch has extra restrictions, such as
requiring compatible or identical `__eq` handlers, those restrictions live in
`TargetProfile.eq_metamethod_rule`.

Flow facts from equality are allowed only when the checker proves the result is
from primitive total equality and no applicable metamethod can change the
answer.

Examples:

- `x == nil` can narrow only if the non-nil alternatives cannot use an equality
  metamethod for that comparison under the target profile;
- literal equality can narrow only on primitive literal domains;
- table equality can produce identity facts, not structural field facts.

`~=` is `not (==)` at the expression level. It does not get a separate ad-hoc
operator rule.

## Ordering And Concatenation

`<` and `<=` derive from primitive target rules or metamethod lookup. If a
target defines `<=` in terms of `<` plus negation in some cases, that rewrite is
a target-profile operation rule with its own certificate evidence. It is not a
frontend fallback.

Concatenation derives from primitive target rules or `__concat`. Any implicit
string/number conversion policy belongs to `TargetProfile`.

## Length

`#x` derives from primitive target rules or `__len`.

The primitive length of tables is target-specific when array holes are present.
The kernel should avoid claiming exact literal lengths for mutable or sparse
tables unless the target rule and table-state proof justify it.

`rawlen` is not the `len` operator. It is a primitive capability that bypasses
`__len` and observes raw table/string length under the target profile.

## Raw Operations

Raw operations are primitive capabilities, not source-name semantics.

Examples:

```text
primitive_cap("$RawEqual")
primitive_cap("$RawLen")
primitive_cap("$RawGet")
primitive_cap("$RawSet")
```

The stdlib profile may bind the runtime names `rawequal`, `rawlen`, `rawget`,
and `rawset` to these capabilities. Aliases of those values preserve capability
behavior. The checker must not inspect the callee's source name.

Raw operations bypass metamethod lookup, but they still depend on target
primitive semantics and table identity state. They also still participate in
invalidation: observing or mutating raw table state can invalidate facts derived
from previous raw or metatable-aware operations.

## Calls And `__call`

Function call checking first collects callable candidates from the callee value.

Candidate sources:

- ordinary `arrow` values;
- overload intersections of arrows;
- primitive capabilities;
- table/userdata metatable `__call` lookup.

`__call` is therefore call-substrate behavior, not a separate operator token.
It must still use the same metatable dependency and invalidation machinery as
operator metamethod lookup.

## Method Syntax

Method calls are already decided by the metatable lookup pass:

```text
obj:method(a, b)
```

elaborates to:

```text
tmp = LookupField(obj, "method")
CallCheck(tmp, obj, a, b)
```

No method-name special casing is admitted. This pass preserves that decision.

## `and`, `or`, And Truthiness

Lua `and` and `or` are not boolean-only operators and are not metamethods. They
are value-producing control-flow expressions.

They require separate expression judgments:

```text
Truthiness(Γ, value) => true_edge_fact, false_edge_fact
AndExpr(Γ, lhs, rhs) => Γ', ValueClaim
OrExpr(Γ, lhs, rhs) => Γ', ValueClaim
```

`Truthiness` is target-profile stable for Lua-like targets:

```text
falsey = nil | false
truthy = complement(nil | false)
```

`and` returns the first falsey value or the right-hand value. `or` returns the
first truthy value or the right-hand value. The result must preserve the
control-flow split long enough to avoid premature unioning that would lose
facts.

These forms should produce certificates distinct from `OpNode`:

```text
TruthinessNode(...)
AndExprNode(...)
OrExprNode(...)
```

Treating them as ordinary boolean operators is rejected.

## Unknown Movement

`unknown` may pass through operators only when the operation is defined for all
values and the result claim is sound for all values. Most Lua operators do not
meet that bar.

Therefore:

- arithmetic on `unknown` rejects unless narrowed or forced through unsafe;
- concatenation on `unknown` rejects unless narrowed or target-profile total;
- `#unknown` rejects unless narrowed or target-profile total;
- equality on `unknown` may be observed as a boolean-like result only if the
  target operation is total for all values, but it must not export narrowing
  facts unless primitive/no-metamethod premises are proved;
- `and`/`or` may consume `unknown` through truthiness control flow only with the
  conservative split permitted by the truthiness rule.

This keeps `unknown` as denotational top instead of turning it into `any`.

## Mutation And Invalidation

An operator result can depend on:

- operand value claims;
- table/userdata identity state;
- receiver metatable state;
- traversed metatable/index tables;
- metamethod field values;
- target-profile operation tables.

If any mutable dependency changes before a derived fact is used, the fact must
be invalidated or re-derived.

Metatable mutation examples:

- assigning a new metatable to a table identity invalidates operator facts that
  depended on the old metatable;
- mutating `mt.__add` invalidates `+` derivations that used that metamethod;
- raw-setting a metatable field invalidates dependent lookup facts even though
  the raw operation bypassed metamethod dispatch;
- protected-metatable behavior affects what can be observed, not whether the
  underlying dependency exists in a trusted target model.

The checker must reject if it cannot prove the dependency remains stable across
the fact's lifetime.

## Rejected Alternatives

Rejected:

- per-operator predicates such as `is_numeric(T)` as the actual typing rule;
- hardcoded frontend branches for `__add`, `__eq`, or `__call`;
- source-name dispatch for `getmetatable`, `setmetatable`, `rawget`, `rawset`,
  `rawequal`, or `rawlen`;
- treating metatable fields as ordinary record fields without the metatable
  lookup relation;
- treating `and`/`or` as boolean algebra;
- using `unknown` or `any` as the fallback result for unsupported operators.

These alternatives are not just incomplete. They are the organic-growth failure
mode v7 is meant to prevent.

## Adversarial Review

Soundness lens: equality narrowing is the danger zone. The design therefore
allows equality-derived facts only when primitive/no-metamethod premises are
proved. This may be conservative, but it avoids unsound narrowing for values
whose equality result can be user-defined.

Ad-hocness lens: the operator key map is a possible loophole. It is allowed only
inside `TargetProfile` as runtime semantics. Frontend code must not create
independent branches keyed by source token plus local predicates.

Target-profile lens: numeric and length semantics are not portable across
LuaJIT/Lua versions. The generic kernel pins only semantic categories and
lattice edges; exact operator tables are trusted target-profile inputs.

Aliasing/invalidation lens: metatable lookup is not a pure structural read. Any
operator certificate that uses a metamethod must name the table/metatable field
dependencies whose mutation invalidates the result.

Ergonomics lens: this design will reject some code that Lua accepts dynamically,
especially operations on `unknown` or on tables with imprecise metatables. That
is acceptable under the soundness-fatal rule; users can add annotations, guards,
or explicit unsafe boundaries.

## Remaining Work

This pass chooses the substrate. It does not fully transcribe every target
operator table.

Next detailed work:

1. write `TargetProfile` primitive operator tables for the first supported Lua
   target;
2. define exact equality metamethod restrictions for that target;
3. define `Truthiness`, `AndExpr`, and `OrExpr` certificates;
4. integrate `__call` candidate collection into the call judgment;
5. add raw primitive capability specs for `rawget`, `rawset`, `rawequal`, and
   `rawlen`.
