# Typechecker v7 LuaJIT 5.1 Target Table

This document transcribes the first concrete `TargetProfile` table:

```text
TargetProfile("luajit51-crescent")
```

It is subordinate to `docs/typechecker-v7-design-pass-target-profile.md`. The
profile schema lives there; this file records concrete target facts for the
vendored LuaJIT runtime.

Observed baseline:

```text
_VERSION = Lua 5.1
jit.version = LuaJIT 2.1.1774896198
```

These observations are runtime evidence for this repository's vendored target,
not portable Lua facts.

## Static Admission Principle

The target table can be conservative.

If LuaJIT accepts a runtime operation only for some values of a broad static
type, v7 may reject the broad type and admit only provable subcases.

Example:

```lua
"1" + "2" -- runtime succeeds
"a" + "b" -- runtime error
```

Therefore `string + string` is not generally admissible. Numeric string literals
may be admitted only after the literal parser proves the conversion.

## Operators Present In Source

LuaJIT 5.1 source operators:

```text
+ - * / % ^ unary-
..
#
== ~= < <= > >=
and or not
```

Lua 5.3 operators are absent:

```text
// << >> & | ~ unary~
```

Bitwise behavior belongs to LuaJIT's `bit` library declarations, not generic
source operators.

## Truthiness

```text
falsey = nil | false
truthy = complement(nil | false)
```

No metamethod participates in truthiness.

## Primitive Arithmetic

Runtime behavior:

- numbers participate in arithmetic;
- strings are converted with Lua numeric conversion when possible;
- non-numeric strings fail;
- cdata arithmetic exists but is FFI/cdata behavior, not ordinary Lua numeric
  behavior.

Static admission table:

```text
number op number -> number
number op numeric_string_literal -> number
numeric_string_literal op number -> number
numeric_string_literal op numeric_string_literal -> number
unm(number) -> number
unm(numeric_string_literal) -> number
```

where:

```text
op in add | sub | mul | div | mod | pow
```

`integer op integer -> integer` is not admitted by default. It requires a
separate exactness/range proof. Ordinary arithmetic widens to `number`.

General `string` operands reject for arithmetic. This is incompleteness for
some runtime values and sound for all strings.

## Concatenation

Runtime behavior:

- strings and numbers concatenate by converting to strings;
- non-string/non-number operands may use `__concat`.

Static primitive table:

```text
string .. string -> string
string .. number -> string
number .. string -> string
number .. number -> string
```

Literal preservation is optional and must be exact if admitted. The first table
may widen all primitive concatenation results to `string`.

## Length

Runtime behavior:

- `#string` returns a numeric Lua value representing length;
- `#table` uses Lua 5.1 table length behavior;
- table `__len` is ignored by the probed LuaJIT runtime;
- `rawlen` is not a global in this target.

Static primitive table:

```text
#string -> integer
#fresh_sealed_contiguous_array_table -> integer
#table -> integer only with a stable table-length proof
```

Sparse or escaped table length may be rejected or widened to `integer` only if
the target length rule is specified for the table state. Exact length claims
require stable contiguous table evidence.

There is no LuaJIT 5.1 runtime `rawlen` global for an external declaration set
to bind.

## Equality

Primitive equality is total and returns a boolean-like value.

Static result:

```text
eq(any_value, any_value) -> boolean
```

Flow facts are narrower:

```text
EqFactsAllowed(a, b) iff
  primitive equality is selected
  and no applicable __eq can affect the result
  and the compared domains have primitive total equality facts
```

Important cases:

- `x == nil` may narrow nil/non-nil;
- literal equality may narrow primitive literal domains;
- table equality is identity equality only;
- cdata equality facts require FFI/cdata rules and are not primitive scalar
  facts by default.

`~=` is `not (==)`.

## Equality Metamethod

LuaJIT uses `__eq` only when both operands expose the same `__eq` function.

Static metamethod rule:

```text
EqMetamethodAllowed(a, b, f) iff
  LookupMetamethod(a, "__eq") = f
  and LookupMetamethod(b, "__eq") = f
```

If the `__eq` functions differ or only one side has `__eq`, primitive identity
equality applies for tables/userdata-like domains.

Any equality expression that uses `__eq` produces a value claim but must not
export primitive equality narrowing facts.

## Ordering

Primitive table:

```text
number <  number -> boolean
number <= number -> boolean
string <  string -> boolean
string <= string -> boolean
```

Mixed `number`/`string` ordering rejects unless a target conversion rule is
specified. Numeric string ordering is not admitted initially.

Metamethod rule:

```text
LtMetamethodAllowed(a, b, f) iff
  LookupMetamethod(a, "__lt") = f
  and LookupMetamethod(b, "__lt") = f

LeMetamethodAllowed(a, b, f) iff
  LookupMetamethod(a, "__le") = f
  and LookupMetamethod(b, "__le") = f
```

If `__le` is absent, LuaJIT may use the opposite `__lt` fallback:

```text
a <= b  ==>  not (b < a)
```

This fallback is admissible only when both operands expose the same `__lt`
function for the reversed comparison and the certificate records the rewrite.

`>` and `>=` are source-level rewrites through `<` and `<=` with operands
swapped. They do not need separate target primitive rows.

## Arithmetic And Concat Metamethod Dispatch

For arithmetic and concatenation, LuaJIT tries the left operand's metamethod
first and then the right operand's metamethod.

Static rule:

```text
BinaryMetamethod(op, a, b):
  if LookupMetamethod(a, key(op)) = f then use f
  else if LookupMetamethod(b, key(op)) = f then use f
  else reject
```

This applies to:

```text
add sub mul div mod pow concat
```

Unary minus uses the operand's `__unm`.

## Table Field Metamethods

`__index` and `__newindex` behavior is owned by the metatable lookup pass:

- absent-field read uses `__index`;
- absent-field assignment uses `__newindex`;
- own-field reads/writes use table identity state;
- raw operations bypass these metamethods.

The target table only supplies the key names and protected metatable behavior.

## Calls

`__call` participates in callable candidate collection:

```text
LookupMetamethod(callee, "__call") = f
```

The call judgment then checks `f(callee, ...)` according to LuaJIT semantics.
The exact self/argument pack rule must be recorded in `CallNode`.

## Protected Metatables

Public behavior:

```text
getmetatable(t) returns mt.__metatable when present
setmetatable(t, mt2) errors when current mt.__metatable is present
```

Kernel behavior:

- internal metatable state remains tracked for soundness;
- public `$GetMetatable` returns the protected public value;
- public `$SetMetatable` rejects protected targets;
- debug bypasses require explicit external declarations/trust.

## Metatable Clearing

Runtime LuaJIT permits:

```lua
setmetatable(t, nil)
```

v7 rejects this until `clear_metatable(id)` is specified. This is a deliberate
conservative gap.

## Raw Operations

LuaJIT 5.1 has:

```text
rawget
rawset
rawequal
```

LuaJIT 5.1 does not expose:

```text
rawlen
```

External declaration environments may bind:

```text
rawget   : primitive_cap("$RawGet")
rawset   : primitive_cap("$RawSet")
rawequal : primitive_cap("$RawEqual")
```

No LuaJIT 5.1 runtime global:

```text
rawlen
```

`$RawLen` may remain a candidate primitive for other target profiles.

## Cdata

LuaJIT FFI cdata has target-specific arithmetic and comparison behavior.

The target table does not collapse cdata into ordinary scalar `number` or
`integer`:

- `type(cdata)` is `"cdata"`;
- cdata integer arithmetic may produce cdata;
- cdata pointer arithmetic and comparisons need FFI type rules;
- cdata metamethods may exist through FFI metatypes.

Therefore cdata operations are admitted only through FFI/nominal/cdata rules,
not through the primitive Lua scalar operator table.

## Certificate Requirements

Every target-dependent proof node records:

```text
target_profile_id = "luajit51-crescent"
target_profile_digest = ...
target_rule = ...
```

For probed behavior that is version-sensitive, the digest must change when the
vendored LuaJIT changes.

Target-dependent nodes include:

- `OpNode`;
- `ControlFlowNode` for truthiness;
- `MetamethodNode`;
- `PrimitiveCallNode` for raw/get/set metatable operations;
- table length proof nodes;
- external declaration import nodes.

## Remaining Unknowns

This table is enough to prevent obvious ad-hoc operator work. It is not yet a
complete LuaJIT formalization.

Remaining exact transcriptions:

1. full numeric string grammar accepted by LuaJIT conversion;
2. NaN and signed-zero behavior for equality/order facts;
3. precise table length theorem for sparse/mutable tables;
4. FFI cdata operator families;
5. coroutine/yield target details;
6. debug library capability profile.
