# Typechecker v7 Design Pass: Stdlib Profiles

This pass decides how standard-library bindings enter v7.

Stdlib profiles are explicit environment inputs. They are not ambient checker
defaults, and they are not target semantics. A target profile says what the
runtime does. A stdlib profile says which runtime values are in scope, what
types they have, and which trusted or primitive capabilities they carry.

## Decision

Use named `StdlibProfile` variants for `luajit51-crescent`.

Initial variants:

```text
StdlibProfile("luajit51-crescent/core")
StdlibProfile("luajit51-crescent/ffi")
StdlibProfile("luajit51-crescent/app")
StdlibProfile("luajit51-crescent/debug")
```

Profiles compose only by explicit selection. There is no hidden "full Lua
globals" fallback.

## Profile Inputs

Every stdlib profile is a certificate input:

```text
StdlibProfile = {
  id,
  target_profile_id,
  bindings,
  type_bindings,
  modules,
  primitive_exports,
  trust_kind,
  provenance
}
```

Changing the profile invalidates certificates that depend on it.

## Core Profile

`luajit51-crescent/core` is the default for library checking.

It includes value bindings whose authority is ordinary computation or core Lua
control, not filesystem, process, debug, loader, or native-library authority.

Candidate core bindings:

```text
_VERSION
assert
error
getmetatable
ipairs
next
pairs
pcall
rawequal
rawget
rawset
require
select
setmetatable
tonumber
tostring
type
unpack
xpcall

coroutine
math
string
table
bit
jit
package metadata with no loader mutation authority
```

Core excludes `rawlen` for LuaJIT 5.1 because the target table shows no global.

`print` is not in core. It writes to stdout and is an output capability. Code
that wants printing should receive an output function or opt into an app
profile.

## Primitive Capability Bindings

Core may bind:

```text
setmetatable : primitive_cap("$SetMetatable")
getmetatable : primitive_cap("$GetMetatable")
rawget       : primitive_cap("$RawGet")
rawset       : primitive_cap("$RawSet")
rawequal     : primitive_cap("$RawEqual")
```

These names are not semantic hooks. They are ordinary profile bindings whose
values have primitive capability types. Shadowing or aliasing follows ordinary
value flow.

## Core Type-Level Bindings

The profile may include pure type-level aliases only when their semantics are
admitted by v7:

```text
Arr<T>
Ptr<T>
Keys<T>
Values<T>
PairsReturn<T>
IpairsReturn<T>
Open<T>
Closed<T>
PcallReturn<F>
```

Aliases that depend on unadmitted match/type-level machinery remain profile
entries only after that machinery has a complete `IntrinsicSpec` or type-level
rule. The profile cannot make an alias sound by declaration.

`$GlobalScope`, `$Require`, `$FfiC`, and `$Opaque` are not ordinary aliases.
They require their own intrinsic specs and environment/provenance rules.

## `require`

Runtime `require` and annotation `--:: require` are different surfaces, but both
must elaborate through explicit environments.

Core may bind runtime `require` only as a trusted module bridge:

```text
require : <S: string_literal>(S) -> ModuleEnv[S].runtime_export
```

If the module is absent from `ModuleEnv`, the call rejects unless an explicit
unsafe boundary is used. There is no `unknown` fallback.

The profile does not search the filesystem during certificate replay. Module
resolution is represented by `ModuleEnv` input digests.

## `type`

`type` is not special-cased by callee name.

Core may bind the value named `type` to a primitive predicate-capable function
or a trusted guard declaration:

```text
type : (unknown) -> "nil" | "boolean" | "number" | "string"
                  | "userdata" | "function" | "table" | "thread" | "cdata"
```

Narrowing from `type(x) == "string"` requires a proof-producing predicate rule
or primitive predicate spec for this binding. Shadowed functions named `type`
do not narrow.

## `assert`, `error`, `pcall`, And `xpcall`

These require contextual-control effects for full precision.

Core profiles may declare them only after the corresponding rules exist:

- `error` produces `throws(E)`;
- `assert` returns normally with a postcondition and may throw on failure;
- `pcall`/`xpcall` discharge `throws(E)` into correlated success/failure packs.

Until those rules are transcribed, a staged checker must either reject precise
uses or mark them as trusted boundaries. It must not implement name-keyed
handlers.

## Coroutines

Coroutine functions require `yields(Y, S)` effect rules for full precision.

The core profile may include coroutine bindings only when:

- `coroutine.yield` produces a yield effect;
- `coroutine.create` discharges a yielding body into a coroutine value;
- `coroutine.resume` preserves yield/resume/return pack correlation.

Otherwise coroutine precision remains outside the admitted subset.

## FFI Profile

`luajit51-crescent/ffi` adds the LuaJIT `ffi` module.

FFI is a trusted bridge over `FfiEnv`, not pure stdlib:

```text
ffi.cdef     : trusted declaration extension into FfiEnv
ffi.C        : $FfiC projection from FfiEnv
ffi.new      : FFI constructor rules
ffi.cast     : unsafe/trusted conversion rules
ffi.typeof   : C type constructor bridge
ffi.metatype : cdata metatable bridge
```

`ffi.load` is stronger than ordinary FFI typing because it loads a native
library. It should be in an additional native-load capability variant or require
explicit application profile trust, not in `core`.

## App Profile

`luajit51-crescent/app` is for application entrypoints that intentionally use
ambient process capabilities.

Candidate app bindings:

```text
print
io
os
dofile
loadfile
loadstring
load
collectgarbage
gcinfo
arg
```

These are not soundness-free. They may be safe for type preservation but they
carry authority and runtime effects outside the core theorem. The certificate
must show the app profile was selected.

## Debug Profile

`luajit51-crescent/debug` is separate.

Debug APIs can mutate metatables, inspect stack frames, bypass protected
metatables, and break assumptions about ordinary code. They require a distinct
profile so their presence is visible in certificates and audits.

No debug binding is admitted into `core`.

## Modules

LuaJIT modules such as `bit`, `ffi`, `jit`, and package-loaded libraries are
profile/module entries, not automatic globals.

Core may include the `bit` and `jit` bindings because they are part of the
LuaJIT runtime surface and do not grant filesystem/process/debug authority by
themselves. `package` must be restricted to metadata unless loader mutation and
search-path effects are specified.

## Rejected Alternatives

Rejected:

- one monolithic ambient stdlib file for all targets;
- loading current `lib/type/static/stdlib_types.lua` as v7 authority;
- exposing `io`, `os`, `debug`, loaders, or `ffi.load` in core;
- treating `type`, `pcall`, `require`, `setmetatable`, or `ffi.C` by source
  name;
- using absent stdlib entries as `unknown`.

The old v4/v3 stdlib files are symbol-surface evidence only.

## Adversarial Review

Soundness lens: stdlib declarations can lie. Every trusted declaration must be
visible in the certificate context with profile provenance.

Ad-hocness lens: the most tempting shortcut is name-keyed behavior for `type`,
`pcall`, `require`, and `setmetatable`. This design requires typed capabilities,
guard specs, effects, or environment bridges instead.

Caps lens: excluding `print`, `io`, `os`, `debug`, loaders, and `ffi.load` from
core is intentional. A library that needs authority should accept a value or opt
into a profile that makes that authority explicit.

Compatibility lens: current Crescent code may rely on the legacy stdlib file.
That is implementation migration pressure, not v7 semantic authority.

## Remaining Work

1. Write exact `core` binding types after effects, packs, and type-level aliases
   are transcribed enough to express them.
2. Define primitive predicate spec for `type`.
3. Define intrinsic specs for `$Require`, `$GlobalScope`, `$FfiC`, and `$Opaque`
   before profile aliases may use them.
4. Split FFI into safe declaration/projection capabilities and native-load
   authority.
5. Add certificate tests proving shadowed `type`/`setmetatable` names do not get
   primitive behavior.
