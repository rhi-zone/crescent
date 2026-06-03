# Typechecker v7 Design Pass: Target Profile

This pass decides the first target-profile shape and the first concrete target.

Target profiles are not stdlib declarations. They are the runtime semantic
parameters needed by kernel rules: scalar operation domains, numeric policy,
metamethod keys, equality restrictions, truthiness, raw operation behavior,
protected metatable behavior, and target features such as LuaJIT FFI.

## Decision

The first concrete target is:

```text
TargetProfile("luajit51-crescent")
```

Reason: Crescent vendors LuaJIT, the runtime entrypoint dispatches to LuaJIT,
the current static checker has Lua 5.1/LuaJIT preludes, and FFI is core project
surface. A later Lua 5.4 profile should be a separate input, not a mutation of
this profile.

The target profile may be conservative. It may reject runtime-valid programs
when a static rule is not yet specified. It must not accept a program unless the
accepted claim is sound for the selected runtime target.

The concrete target table is transcribed in
`docs/typechecker-v7-luajit51-target-table.md`.

## Target Profile Schema

```text
TargetProfile = {
  id,
  runtime_family,
  scalar_domains,
  truthiness,
  primitive_ops,
  metamethod_keys,
  equality_policy,
  length_policy,
  raw_policy,
  metatable_policy,
  pack_adjustment_policy,
  feature_flags
}
```

The profile is a certificate input. It has a stable digest. A certificate
checked under `luajit51-crescent` is not valid under `lua54` unless replayed
against that profile.

## Runtime Family

`luajit51-crescent` means LuaJIT-compatible Lua 5.1 semantics plus Crescent's
explicit profile choices.

It does not mean:

- ambient globals are available;
- all `debug` functionality is safe;
- every LuaJIT FFI value is precisely modeled;
- pure-Lua libraries may rely on unannotated LuaJIT quirks.

Runtime availability is split:

- `TargetProfile` owns runtime semantic rules;
- external declaration/config inputs own which runtime values are in scope and
  their declared types;
- `FfiEnv` owns C declarations and symbols.

## Scalar And Numeric Policy

The generic kernel keeps only:

```text
integer <: number
```

In `luajit51-crescent`, `integer` is a semantic refinement of Lua numeric values
that are exactly integral in the checker model. It is not a separate Lua 5.3+
runtime tag.

Primitive arithmetic starts conservative:

```text
number op number => number
integer op integer => number       -- unless the profile rule proves integer preservation
```

Integer-preserving results require explicit profile rules. Examples that may be
admitted after transcription:

- integer literals without fractional syntax;
- bit operations returning signed 32-bit integral numeric values;
- selected floor/truncation-like external declarations;
- constant-folded arithmetic only when exactness and range are proven.

Rejected shortcuts:

- treating every integer-looking arithmetic result as `integer`;
- treating LuaJIT cdata integers as ordinary Lua `integer`;
- using host Lua numeric behavior as the proof of target behavior.

LuaJIT FFI integer and unsigned integer cdata values are `cdata`/nominal FFI
values, not automatically `integer`. Their arithmetic, if admitted, must use
FFI/nominal/metamethod rules rather than numeric scalar rules.

## Primitive Operation Table

`primitive_ops` maps semantic operator tags to admissible operand/result rules.

Initial conservative table:

```text
add/sub/mul/div/mod/pow/unm:
  number, number -> number
  number -> number                -- for unary minus

bit operations:
  admitted only through LuaJIT bit-library declarations or later target rules;
  not generic Lua scalar operators.

concat:
  string, string -> string
  literal numeric string coercions remain deferred unless exactly specified.

len:
  string -> integer
  table -> integer only with a target length proof over stable table state;
  otherwise use __len if target supports it or reject.

eq:
  total boolean-like result over all values, but flow facts require the
  equality policy below.

lt/le:
  number, number -> boolean
  string, string -> boolean
```

This table is intentionally incomplete. It is better to reject string arithmetic
or sparse-table length precision than to encode an approximate rule.

## Truthiness

For `luajit51-crescent`:

```text
falsey = nil | false
truthy = complement(nil | false)
```

This is stable enough to be a profile constant. `TruthinessNode` can replay it
without consulting external declarations.

`and` and `or` use this truthiness policy but are not primitive operators.

## Metamethod Keys

Metamethod keys are target semantics:

```text
add    -> "__add"
sub    -> "__sub"
mul    -> "__mul"
div    -> "__div"
mod    -> "__mod"
pow    -> "__pow"
unm    -> "__unm"
concat -> "__concat"
len    -> "__len"       -- only in target profiles that support table __len
eq     -> "__eq"
lt     -> "__lt"
le     -> "__le"
call   -> "__call"
index  -> "__index"
newindex -> "__newindex"
```

The key table lives in `TargetProfile`. Frontend code must not implement
source-token-specific lookup outside `OpCheck`, `CallCheck`, `LookupField`, or
`AssignField`.

If LuaJIT compatibility for a key is uncertain or version-dependent, the first
profile must either pin the exact behavior or reject the dependent feature until
verified.

The concrete `luajit51-crescent` table pins table `__len` as unsupported by the
probed runtime.

## Equality Policy

Primitive equality returns a boolean-like value for all operands.

Flow facts from equality require more:

```text
EqFactsAllowed(a, b) iff
  primitive equality is the selected case
  and no applicable __eq metamethod can affect the result
  and the compared domains have a target-profile total equality relation
```

`x == nil` may narrow only because nil comparison is primitive and no table,
userdata, cdata, or metatable rule can make a non-nil value equal to nil under
the selected profile. If a future target admits stranger equality behavior, the
profile must remove that narrowing.

Table equality is identity equality. It never proves structural record equality.

Cdata equality is not automatically primitive scalar equality. It needs FFI
rules or conservative rejection for facts.

## Length Policy

`#s` for string gives an integer length.

`#t` for tables is target-defined and sensitive to holes and mutation. The
profile may admit:

- exact length for fresh sealed array-like tables with stable contiguous integer
  keys;
- widened `integer` length for table states where target length is defined but
  exact value is not proven;
- rejection when the table state is sparse, mutable, escaped, or metatable
  behavior is unresolved.

`rawlen` bypasses `__len` but still uses target length policy and table/string
state.

## Protected Metatable Policy

Lua-style protected metatables are profile behavior.

For `luajit51-crescent`:

- public `getmetatable` capability returns the protected `__metatable` value
  when present;
- otherwise it returns the actual metatable claim when visible;
- public `setmetatable` capability rejects if the current metatable has a
  protected `__metatable` field;
- debug capabilities that bypass protection require explicit capability/trust
  decisions.

The kernel may still track internal metatable identity for soundness and
dependency invalidation. The public observation returned by `$GetMetatable` is
not necessarily the internal metatable.

## Metatable Clearing

Lua permits clearing a table metatable with `setmetatable(t, nil)`.

v7 does not admit that transition yet. `luajit51-crescent` conservatively
rejects public `$SetMetatable` calls whose new metatable claim is `nil` until a
`clear_metatable(id)` identity transition, invalidation rule, and certificate
node are specified.

This is incompleteness, not a claim about Lua runtime behavior.

## Raw Policy

Raw operations are primitive capabilities whose behavior is target-profiled:

```text
$RawGet
$RawSet
$RawEqual
$RawLen
```

They bypass metamethod dispatch. They do not bypass:

- table identity state;
- target scalar equality/length policy;
- dependency tracking;
- unsafe-boundary visibility for imprecise claims.

`$RawEqual` may produce equality facts only under the same primitive-domain
restrictions as ordinary equality, minus metamethod dispatch.

## Pack Adjustment Policy

Lua expression-list adjustment is target-stable for the profile:

- missing assignment values become `nil`;
- surplus assignment values are discarded;
- call arguments adjust by position with last-expression spread;
- returns preserve last-expression spread.

This policy belongs in target/profile replay because non-Lua targets or future
surface dialects might differ, but v7's Lua profile treats it as fixed.

## Stdlib Boundary

An external declaration environment may bind names such as:

```text
setmetatable : primitive_cap("$SetMetatable")
getmetatable : primitive_cap("$GetMetatable")
rawget       : primitive_cap("$RawGet")
rawset       : primitive_cap("$RawSet")
rawequal     : primitive_cap("$RawEqual")
```

For the probed LuaJIT 5.1 runtime, declarations should not bind `rawlen` as a
runtime global because the target has no `rawlen` global. `$RawLen` remains a
candidate primitive for other target profiles.

The target profile does not make these names ambient. If a program shadows
`setmetatable`, it shadows an ordinary binding. Primitive behavior follows the
value's `primitive_cap` type, not the spelling.

## Adversarial Review

Soundness lens: the largest risk is overclaiming numeric precision. The initial
LuaJIT profile therefore widens ordinary arithmetic to `number` unless a
profile rule proves integer preservation.

Target-portability lens: LuaJIT-first is justified by the repository, but it
must not erase target identity. Certificates include the target digest, and Lua
5.4 is a separate future profile.

Metatable lens: public protected-metatable behavior and internal metatable
state are different. The design keeps both: public capability results follow
the target profile; kernel dependencies still track the real state.

Ad-hocness lens: target-profile tables are allowed because they are runtime
semantics inputs. They become ad-hoc if frontend code bypasses kernel judgments
and directly branches on source names or tokens.

Completeness lens: rejecting `setmetatable(t, nil)` and imprecise table length
will reject real Lua. That is acceptable until the corresponding identity and
length rules are specified.

## Remaining Work

1. Specify table length proofs for fresh/sealed array-like table states.
2. Add `clear_metatable(id)` if metatable clearing is worth supporting.
3. Add stale-certificate tests that replay a proof under a different target
   digest and reject it.
