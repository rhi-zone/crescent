# Typechecker v4 — stdlib types design

## 0. Frame

This doc designs the **v0 contents** of `lib/type/static-v4/stdlib_types_v4.lua` — the Lua module that constructs the `StdlibBindings = { bindings: { [string]: V4Type }, aliases: { [string]: V4Type } }` record the driver injects into every walk. It picks the symbol set, gives each symbol an explicit V4Type signature in `V.fn` / `V.rec` / `V.forall` / `V.match` / `V.union` constructor syntax, decides the encoding of the `$Require<T>` family of intrinsics, and decides how the file is loaded.

What this is **not**: the implementation; an annotation-parser bridge (legacy `--::` text → V4Type) — that is Phase J. Re-mentions of "the legacy file" refer to `lib/type/static/stdlib_types.lua`, used here as a *symbol surface* reference, never as an implementation template (its representation is v3-arena IDs).

What v4 already provides (taken from `lib/type/static-v4/init.lua` and walker/env.lua):

- Constructors: `V.top`, `V.bot`, `V.prim`, `V.literal`, `V.fn(params, ret, effects)`, `V.rec(fields, open, indexer)`, `V.indexer(K, V)`, `V.union`, `V.inter`, `V.neg`, `V.var`, `V.fix`, `V.mu`, `V.forall(name_or_names, body[, bounds])`, `V.skolem`.
- `V.match(scrutinee, arms)`, `V.arm(pattern, result)`.
- `V.index(t, k)` (indexed access reducer).
- Effects: a string set; the only two named atoms exposed at the API are `V.EFFECT_YIELD = "yield"` and `V.EFFECT_THROW = "throw"`.

What v4 does **not** yet have (load-bearing for several decisions below):

- No first-class intrinsic-type constructor (`V.intrinsic("Require", T)` does not exist).
- No spread param syntax for `V.fn` (variadic `...T` in a Lua-source param list maps to a single positional `top`/T param at the V4Type level; multi-return spread is encoded as a positional record).
- No first-class "tuple result with spread" expression at the constructor layer; effects.lua's `pcall_return_type` already shows the workaround (union of two closed records with positional `"1"`, `"2"` keys).
- No annotation-parser bridge; this file is hand-built V4Type values.

## 1. MVP scope

### 1.1 IN (with reasoning)

Walker-mandatory (handlers dispatch on the name):

1. `error` — effects.lua identifier dispatch; the binding's type is **shadow-irrelevant** (the walker uses the name, not the type), but the binding must exist so that lookup of `error` does not produce an unresolved-identifier diagnostic.
2. `pcall` — same.
3. `xpcall` — same.
4. `require` — require_resolve.lua identifier dispatch; same "name not type" comment. See §3.
5. `type` — control_flow.lua uses `type(x) == "literal"` for narrowing; the binding must be present and typed as a function from `unknown` to the **literal-union of Lua's `type()` return strings**, so the narrowing's positive atom is well-formed when the type system later refines.
6. `coroutine` (table binding with field `yield`) — effects.lua §10.1 says `coroutine.yield` accumulates the `yield` effect via the **standard binding-driven path**, i.e. the field's V.fn must carry `{ [V.EFFECT_YIELD] = true }` in its `effects`. No name dispatch — the effect rides on the type.
7. `ffi` (table binding with field `cdef` and field `C`) — ffi_cdef.lua walks the binding via `env.bindings["ffi"].fields["C"]` and rewrites it; the *initial* `ffi` binding must exist with `cdef: (string) -> nil` and `C` = empty closed rec (`V.rec({}, false, nil)`). See §4 ($FfiC).

Obvious-needed-for-tests / used pervasively across `lib/`:

8. `tostring` : `(unknown) -> string`
9. `tonumber` : `(unknown, integer | nil) -> number | nil`
10. `assert` : `<T>(T, ...unknown) -> T & ~(nil | false)` — see §2 for the narrowing form.
11. `select` : intersection of `(("#") -> integer) & ((integer, ...unknown) -> ...unknown)` — see §2.
12. `next` : `<T>(T, Keys<T> | nil) -> (Keys<T> | nil, Values<T> | nil)` — depends on `Keys` / `Values` aliases (§1.3).
13. `ipairs`, `pairs` — depend on `IpairsReturn` / `PairsReturn` aliases (§1.3).
14. `setmetatable`, `getmetatable` — depend on `MetaOf` alias.
15. `rawget`, `rawset`, `rawequal`, `rawlen`, `unpack`, `print` — pure shape, no exotic deps.
16. `_VERSION` (string), `_G` ($GlobalScope — see §4).

Tables (bound as `V.rec` of `V.fn` fields):

17. `string` — fields: `format`, `match`, `find`, `sub`, `byte`, `char`, `lower`, `upper`, `rep`, `gsub`, `gmatch`, `len`, `reverse`.
18. `table` — fields: `insert`, `concat`, `remove`, `sort`, `unpack`, `move`, `maxn`.
19. `math` — fields: `abs`, `floor`, `ceil`, `min`, `max`, `huge`, `pi`, `random`, `randomseed`, `sqrt`, `sin`, `cos`, `tan`, `exp`, `log`, `pow`, `fmod`, `modf`.
20. `coroutine` — fields: `create`, `resume`, `yield`, `wrap`, `status`, `running`, `isyieldable`.
21. `bit` (LuaJIT) — fields: `tobit`, `tohex`, `bnot`, `band`, `bor`, `bxor`, `lshift`, `rshift`, `arshift`, `bswap`, `rol`, `ror`.
22. `ffi` — fields: `cdef`, `C`, plus `new`, `cast`, `sizeof`, `typeof`, `string`, `gc`, `metatype`, `istype`, `alignof`, `offsetof`, `abi`, `errno`, `load`, `copy`, `fill`. (Many of these reference `Ctype<T>` / `Ptr<T>` / `Arr<T>` aliases — §1.3.)
23. `jit` — fields: `version`, `version_num`, `os`, `arch` (constants).
24. `package` — fields: `path`, `cpath`, `loaded` (open), `preload` (open).

### 1.2 OUT — caps-injected, NOT in ambient stdlib

**Per CLAUDE.md "Caps-first, everywhere"** and the v4 driver's `io_caps` cap, the following Lua stdlib tables are deliberately **not** in `stdlib_types_v4.lua`:

- `io` — `io.read`, `io.write`, `io.open`, `io.close`, `io.lines`, `io.popen`, `io.stdin`, `io.stdout`, `io.stderr`.
- `os` (mostly) — `os.time`, `os.clock`, `os.date`, `os.getenv`, `os.execute`, `os.exit`, `os.rename`, `os.remove`, `os.tmpname`.
- `debug` (mostly) — `debug.sethook`, `debug.getinfo` (these are reflection caps).
- `dofile`, `loadfile`, `loadstring`, `load`, `newproxy`, `collectgarbage`, `gcinfo`.

Reasoning: if a library reads time, env, or files, it must accept those as injected functions. Making `os.time` an ambient global teaches *every* library that came after to grab it from the global table, which destroys sandboxability for the whole ecosystem. The legacy stdlib_types.lua declares these because v3 was permissive; v4 declines.

**Consequence**: a Lua program that says `os.time()` produces an `unresolved identifier` diagnostic from the walker. The fix is either (a) accept a `time_fn` capability parameter, or (b) for application-level scripts that truly need ambient I/O, opt in with a `--caps full` flag at the driver level that loads a *secondary* stdlib file `stdlib_types_v4_caps.lua` containing exactly these declarations. The default driver invocation loads only `stdlib_types_v4.lua`.

This means a project-wide `bin/cr check` cutover requires every library that touches I/O to be cap-converted first. That work item is real, not theoretical — but it's the work the values demand. Documenting the exclusion here is the forcing function; the alternative ("we'll add caps later") is the failure mode CLAUDE.md's "minimal change" rule names by name.

### 1.3 Aliases (the `aliases` half of StdlibBindings)

These are the named `--::` aliases the legacy stdlib pre-defines. v4 needs them as V4Type values bound in `env.aliases` so user annotations like `Arr<T>` resolve. Every one of these is a *match-type* or a simple parametric record:

- `Arr<T> = { [integer]: T, ... }` — open rec with integer indexer.
- `Ptr<T> = T & { [0]: T }` — intersection.
- `Keys<T> = match T { { ...[%K]: %V } => K }`.
- `Values<T> = match T { { ...[%K]: %V } => V }`.
- `PairsReturn<T> = match T { { ...[%K]: %V } => (K, V) }`.
- `IpairsReturn<T> = match T { { ...[%K]: %V } => match K { number => (integer, V), _ => never } }`.
- `Open<T> = match T { { ...%Rest } => { ...Rest, ... } }`.
- `Closed<T> = match T { { ...%Rest } => { ...Rest } }`.
- `MetaOf<T> = match T { { #...%M } => M, _ => nil }`.
- `Ctype<T> = $Opaque<T> & ((...unknown) -> T)` — see §4 ($Opaque).
- `PcallReturn<F> = match F { (...%P) -> %R => (true, ...R) | (false, string) }` — used by `pcall`'s declared type once §3's encoding lands; today's effects.lua synthesises the result type ad-hoc so we don't strictly need this alias in the MVP, but having it lets a user write `PcallReturn<F>` in their own annotations.

These aliases are built by hand with `V.match(V.var("T"), { V.arm(<pattern>, <result>), … })`. The pattern constructors (`{ ...[%K]: %V }`, `{ ...%Rest }`, `{ #...%M }`) need to be expressible as V4Type pattern values — confirmed at the constructor level by `V.arm`'s contract (per the v4 init exports).

## 2. Per-symbol signatures

Notation: `V.fn(params, ret, effects)` written as `(P1, P2, …) -[effects]-> R` for brevity. `V.forall("T", body)` written as `<T> body`. `V.literal("string", "x")` written `"x"`. `V.union({A, B})` written `A | B`. `V.neg(T)` written `~T`. `V.match` written as `match`. Tuple results in pcall-style returns are unions of positional closed recs per effects.lua §0 (the design accepts this until v4 grows a tuple-result constructor).

### Walker-mandatory

```
error       : <T>(unknown, integer | nil) -[throw]-> never
pcall       : <F: (...unknown) -> unknown>(F, ...unknown) -> PcallReturn<F>
xpcall      : <F: (...unknown) -> unknown>(F, (string) -> string, ...unknown) -> PcallReturn<F>
require     : (string) -> unknown            -- placeholder; see §3
type        : (unknown) -> ("nil" | "boolean" | "number" | "string" | "userdata" | "function" | "table" | "thread" | "cdata")
```

Notes:
- `error`'s return type is `never` (`V.bot()`); the walker also stamps `effects = {throw}` so the call-site accumulates throw even when the walker's identifier dispatch doesn't fire (e.g. a `local err = error; err(...)` alias).
- `pcall` / `xpcall` carry no effect themselves; the effect *consumption* logic is in effects.lua's special-cased synth, not in the type.
- `type` returns a *literal union*, not `string`. This is load-bearing: control_flow.lua's `type(x) == "string"` narrowing extracts the comparison RHS's literal and intersects against the argument; the LHS being `string` rather than a literal union would block any subsequent reasoning about exhaustiveness of `type` switches. `"cdata"` is included for LuaJIT.

### Effects-carrying

```
coroutine.yield : (...unknown) -[yield]-> ...unknown
coroutine.create : ((...never) -> unknown) -> thread       -- thread = $Opaque<"Thread">
coroutine.resume : (thread, ...unknown) -> (boolean, ...unknown)   -- positional rec encoding
coroutine.wrap   : ((...never) -> unknown) -> ((...never) -> unknown)
coroutine.status : (thread) -> ("running" | "suspended" | "normal" | "dead")
coroutine.running : () -> (thread | nil, boolean)
coroutine.isyieldable : () -> boolean
```

### Plain-shape utility

```
tostring     : (unknown) -> string
tonumber     : (unknown, integer | nil) -> number | nil
assert       : <T>(T, ...unknown) -> T & ~(nil | false)
                                              -- narrows-via-type via the intersection-with-complement
                                              -- pattern (typechecker-reference.md narrowing forms).
                                              -- Note: this differs from legacy's `<T>(T, ...unknown) -> T`
                                              -- — v4 can encode the runtime guarantee that assert never
                                              -- returns nil/false because that would have raised.
select       : ((s: "#") -> integer)
             & ((idx: integer, ...unknown) -> ...unknown)
                                              -- DESIGN-CHALLENGE: select's true type is
                                              -- "if the first arg is the literal "#" return integer,
                                              -- else return the tail of the varargs starting at idx".
                                              -- The intersection above captures the two call shapes
                                              -- but loses the "idx selects tail position" computation.
                                              -- A `match`-encoded "select integer literal idx out of
                                              -- a varargs tuple" needs tuple-index-by-literal at the
                                              -- match-pattern level, which v4 4a does not yet have.
                                              -- Accepting the wider intersection for MVP; flagged in §7.
next         : <T>(T, Keys<T> | nil) -> (Keys<T> | nil, Values<T> | nil)
ipairs       : <T>(T) -> IpairsReturn<T>      -- iterator (no spread; the multi-return tuple is the alias's body)
pairs        : <T>(T) -> PairsReturn<T>
setmetatable : <T, MT>(T, MT) -> T & MT & { #...MT }
getmetatable : <T>(T) -> MetaOf<T>
rawget       : <T>(T, unknown) -> Values<T> | nil
rawset       : <T>(T, unknown, unknown) -> T
rawequal     : (unknown, unknown) -> boolean
rawlen       : (string | { [integer]: unknown, ... }) -> integer
unpack       : <V>({ [integer]: V, ... }, integer | nil, integer | nil) -> ...unknown
                                              -- DESIGN-CHALLENGE: legacy says `-> ...(V)` (a real
                                              -- multi-return of V). v4 has no spread-fn-result yet.
                                              -- Encoding `...unknown` is the honest fallback —
                                              -- callers who use `local a, b = unpack(t)` will get
                                              -- `unknown` for a, b instead of V. Flagged in §7.
print        : (...unknown) -> nil
_VERSION     : string                          -- value-typed binding (V.string_)
```

### `string` (bound as `V.rec({...}, false, nil)`)

```
format  : (string, ...unknown) -> string
len     : (string) -> integer
sub     : (string, integer, integer | nil) -> string
find    : <P: string>(string, P, integer | nil, boolean | nil) -> $FindReturn<P>
match   : <P: string>(string, P, integer | nil) -> $PatternReturn<P>
gmatch  : <P: string>(string, P) -> (() -> $PatternReturn<P>)
gsub    : (string, string, string | ((string) -> string | nil) | { [string]: string, ... }, integer | nil) -> (string, integer)
rep     : (string, integer, string | nil) -> string
byte    : ((string, integer | nil) -> integer | nil)
        & ((string, integer, integer) -> ...integer)
char    : (...integer) -> string
upper   : (string) -> string
lower   : (string) -> string
reverse : (string) -> string
```

### `table`

```
insert  : <V>({ [integer]: V, ... }, V) -> nil
remove  : <V>({ [integer]: V, ... }, integer | nil) -> V | nil
concat  : ({ [integer]: string | number, ... }, string | nil, integer | nil, integer | nil) -> string
sort    : <V>({ [integer]: V, ... }, ((V, V) -> boolean) | nil) -> nil
unpack  : (alias of top-level `unpack`)
move    : <V>({ [integer]: V, ... }, integer, integer, integer, { [integer]: V, ... } | nil) -> { [integer]: V, ... }
maxn    : ({ [integer]: unknown, ... }) -> integer
```

### `math`

```
abs        : (number) -> number
floor      : (number) -> integer
ceil       : (number) -> integer
sqrt       : (number) -> number
min        : ((integer, ...integer) -> integer) & ((number, ...number) -> number)
max        : ((integer, ...integer) -> integer) & ((number, ...number) -> number)
random     : (integer | nil, integer | nil) -> number
randomseed : (number) -> nil
huge       : number
pi         : number
sin, cos, tan, exp, log, pow, fmod : (number, …) -> number
modf       : (number) -> (number, number)     -- positional rec, same caveat as multi-return above
```

### `ffi` (the initial binding before any `ffi.cdef` call rewrites it)

```
cdef    : (string) -> nil
C       : V.rec({}, false, nil)                -- empty closed rec; ffi_cdef.lua rewrites this
new     : (intersection — see legacy)
cast    : (intersection — see legacy)
sizeof  : (string | Ctype<unknown>) -> integer
typeof  : ((Ctype<unknown>) -> Ctype<unknown>) & ((string) -> Ctype<unknown>)
string_ : (Ptr<integer>, integer | nil) -> string   -- bound under field name "string"
gc      : <T>(T, ((T) -> nil) | nil) -> T
metatype: <T>(Ctype<T>, { [string]: unknown, ... }) -> Ctype<T>
istype  : (string | Ctype<unknown>, unknown) -> boolean
alignof : (string | Ctype<unknown>) -> integer
offsetof: (string | Ctype<unknown>, string) -> integer
abi     : (string) -> boolean
errno   : (integer | nil) -> integer
load    : (string, boolean | nil) -> $FfiC          -- see §4
copy    : <T, U>(Ptr<T>, Ptr<U>, integer) -> nil
fill    : <T>(Ptr<T>, integer, integer | nil) -> nil
```

(`ffi.new` and `ffi.cast` retain their legacy intersection shape; the encoding is direct.)

### `coroutine` — see Effects-carrying above.

### `bit`, `jit`, `package` — mechanical from legacy. No design issues.

## 3. `$Require<T>` encoding — Option B (walker override + thin declaration)

**Decision**: `require` is declared as `(string) -> unknown` in the stdlib bindings, and **require_resolve.lua's identifier dispatch overrides the call-site** to produce the real cached export type.

Why not Option A (`V.intrinsic("Require", T)` as a generic intrinsic constructor):

- It is a new type-level constructor with its own reducer rules, its own subtyping rules, its own match-pattern integration. v4 currently has no intrinsic-as-type machinery; adding one for `$Require` alone introduces a class of constructor that the algebra has to reason about everywhere.
- The legacy reasoning ("`$Require<T>` propagates a string literal through generic instantiation") is achieved by the walker dispatching on the *call site*, not by carrying a `$Require` constructor through the type lattice. The walker already does this: `require_resolve.synth_call` matches `require("<literal>")` and synthesises the resolved type directly, bypassing apply_arrow.

Why not Option C (deferred indexed access on a module-namespace table):

- Would require a global `Modules` table type containing every requirable path. Building that statically means the stdlib file enumerates every module in the repo — coupling stdlib to the project's module layout, exactly the kind of poison-by-coupling CLAUDE.md rejects.

Why Option B works:

- `require_resolve.lua` already does the work. The stdlib's declared `require : (string) -> unknown` is the **fallback type** for the case where `require` is *aliased* to a local and called indirectly: `local r = require; r("lib.foo")`. The fallback yields `unknown`, the user is forced to cast — which is exactly the loss in resolve-ability they accepted by aliasing.
- The walker dispatch produces the correct concrete type when the call is direct (`require("lib.foo")` with a string-literal arg).
- No new intrinsic type constructor; the algebra is unchanged.

**Concretely**: stdlib_types_v4.lua binds `require` to `V.fn({ V.string_ }, V.top(), nil)`. The walker dispatches on the name *and* on the string-literal argument; both must hold to produce the resolved type, matching require_resolve's existing `is_require_call` predicate.

Other `$`-intrinsics' encoding falls into the same family — see §4.

## 4. Other crescent intrinsics

Per typechecker-reference.md's "Permanent intrinsics". Each row: encoding choice, MVP-in?

- **`$Opaque<T>` / `$Opaque<T, U>`** — Nominal newtype. v4 has no nominal-type tag in `V.prim` / `V.rec`. **Encoding**: `V.rec({ __opaque = V.literal("string", "<unique-key>"), value = T }, false, nil)` — a closed rec with a sentinel field that prevents structural equality with bare T. **MVP**: required for `Ctype<T>` and `thread`. **In**.

- **`$FfiC`** — Closed rec built from cdef call sites. **Encoding**: a plain `V.rec({}, false, nil)` at stdlib init; ffi_cdef.lua's `process_cdef_string` rewrites the binding into a closed rec containing the parsed declarations. No intrinsic constructor needed. **In**.

- **`$GlobalScope`** — Mirror of all `--:: declare` globals. **Encoding**: a `V.rec(<map>, false, nil)` whose fields enumerate every top-level binding in `bindings`. **MVP question**: who builds it? Two options: (a) the stdlib file declares `_G` as `V.var("$GlobalScope")` and the driver post-populates after stdlib load; (b) the stdlib file builds it inline as the *closure* of its own `bindings` map at the bottom of the file. Recommend (b) — the file's last act is `bindings._G = V.rec(<copy of bindings without _G>, false, nil)`. **In**.

- **`$Throw<T>` / `$Catch<T, Default>`** — Type-level error/pcall. v4 expresses these via the `throw` effect on `V.fn` and pcall's union-of-records return. **Decision**: neither `$Throw` nor `$Catch` exists as a type constructor in v4. Users who need "raise an error in a type computation" use a `match` with no matching arm (which yields `never` per the design) or annotate the function with `throw` in its effects. **OUT of MVP** as intrinsic-types; their *runtime* counterparts (error / pcall) are in.

- **`$EachField<T, F>`** — Per-field flatMap with descriptor access. Not expressible by `{ ...[%K]: %V }` distribution alone. **Decision**: encode as `V.match` over `{ ...[%K]: %V }` for the value/key distribution; the flag-access (`optional`/`readonly`) is **NOT in MVP** — fewer than 5 sites in the existing codebase rely on it. Document as a known gap. **OUT of MVP**.

- **`$PatternReturn<P>` / `$FindReturn<P>`** — Computed from a literal Lua pattern. Requires walking the pattern string. **Decision**: neither `match` nor a generic V4Type constructor can compute these — pattern-string parsing has to be runtime code. v4 must provide a walker-side intrinsic call (the walker spots `string.match(s, "<literal>")` and synthesises the return type by parsing the literal). **MVP encoding**: the stdlib declares `string.match : <P: string>(string, P, integer | nil) -> unknown` as fallback; the walker overrides on literal-pattern call sites. Same shape as the `require` decision (§3). Walker hook is *not yet implemented* — flagged in §7 as required for MVP completeness, but the stdlib declaration is stable today. **In** at the declaration layer; walker hook tracked separately.

## 5. Stdlib loading mechanism — eager at driver init, re-injected per call

Driver design §3 puts the loading decision here. Two options were on the table:

- **Eager at driver init**: top-level `require("lib.type.static-v4.stdlib_types_v4")` runs once per `bin/cr` invocation, produces the StdlibBindings record, the driver re-uses it across every `drive()` call.
- **Lazy per-lookup**: walker triggers stdlib resolution on first reference.

**Choice**: eager.

Reasoning:

- The file is **pure data construction** — V4Type values built from constructors. There is no I/O, no parsing, no side effects. Construction cost is paid once at startup; reuse is free.
- Lazy loading saves nothing measurable (the bindings table is small — a few kilobytes of V4Type structure) and introduces a partially-initialised stdlib state during walks (some bindings resolved, others not), which is exactly the kind of "wrongly-shaped intermediate state" CLAUDE.md's "ad-hoc conditions" rule warns about.
- Eager fits the driver's caps-first opts shape (`opts.stdlib` is a record, passed by value-or-reference per call) — the bindings are external to the driver, the driver doesn't own their lifecycle.

The injection step `inject_stdlib(env, bindings)` walks `bindings.bindings` and `bindings.aliases`, calling `E.bind` / `E.bind_alias` for each entry. Linear in the number of stdlib symbols (~80 with table fields counted), trivial cost.

## 6. Effects encoding

The walker accumulates an effect set on `env.effects`; `V.fn` carries an `effects` field that contributes to the accumulator at apply_arrow time. Named effect atoms (as string keys in the V.fn's `effects` table) used by the MVP stdlib:

- `V.EFFECT_THROW = "throw"` — `error` only. (pcall and xpcall MASK throw at the call site; the inner function's annotation carries throw; pcall/xpcall do not.)
- `V.EFFECT_YIELD = "yield"` — `coroutine.yield`. Any other coroutine function called from a coroutine body inherits this transitively at the call site.

Effects NOT in MVP:

- No `io`, `clock`, `random` effect atoms despite their being I/O — because §1.2 excludes those symbols from the default stdlib. A future caps-aware stdlib (the `--caps full` variant) will need new atoms (`io`, `time`, `env`, etc.); reserving the names now would be premature.

Walker expectation: the walker uses the *string keys* of the effects table directly (effects.lua line 232: `for name in pairs(effects) do if name ~= V.EFFECT_THROW and type(name) == "string" then ...`). The stdlib MUST use the exact atom strings `"throw"` and `"yield"` — the API's `V.EFFECT_*` constants are the source of truth.

## 7. Open questions

1. **Spread-fn-result encoding.** `unpack`, `coroutine.resume`, `coroutine.yield`, `string.byte` (multi-byte form), `math.modf` all *truly* multi-return with spread semantics. The legacy syntax `...(V)` has no V4Type constructor today. Effects.lua's positional-record encoding (`{ "1" = …, "2" = … }`) works for *fixed-arity* multi-returns but not for `...V`. The MVP signatures above degrade to `...unknown` where spread is unavoidable. The principled fix is to add a tuple-or-spread result type at the V4Type level. **Not designed here.**

2. **`select` literal-discriminated return.** Captured in §2 inline; current encoding is the wider intersection that loses idx-driven tail typing. A `match` pattern that indexes into a variadic tuple at a literal position would close this; doesn't exist yet.

3. **`$PatternReturn<P>` walker hook.** §4 names this as required for `string.match` / `string.gmatch` / `string.find` precision. The walker must spot `string.match(s, "<string-literal>")` calls, parse the pattern, and synthesise the return type. **Not implemented in any walker sub-phase yet.** Tracking item.

4. **Caps-secondary stdlib file (`stdlib_types_v4_caps.lua`).** §1.2 commits to the exclusion of `io` / `os` / etc.; the secondary file's structure (which atoms, which signatures, how the driver flag-gates it) is not designed here.

5. **`_G` ($GlobalScope) construction order.** §4 (b) proposes the stdlib file closes over its own bindings at the bottom. If a user binding later overrides a stdlib name, `_G` will not see the override. Acceptable for MVP (no test depends on this) but worth flagging.

6. **Generic constraint syntax for `<F: (...unknown) -> unknown>` in `pcall` / `xpcall`.** `V.forall` accepts a bounds parameter; the exact shape (single type bound vs. multi-bound list) at the constructor level needs verification against the v4 API before commit. If `V.forall("F", body, { ["F"] = bound })` is not the spelling, the actual spelling is mechanically substitutable.

7. **`Ctype<T>`'s `(…unknown) -> T` callability.** Legacy declares `Ctype<T> = $Opaque<T> & ((...unknown) -> T)`. v4's `$Opaque` encoding (§4) is a closed rec with a sentinel; intersection with a fn type produces a value that is both a record and a function. v4's apply_arrow needs to handle "callable record" — confirm this is a current capability or design path.

8. **Augment vs. inline declaration.** Legacy uses `--:: augment string { ... }` to merge fields into a pre-existing primitive binding. v4's stdlib file builds the `string` table binding inline (no augment); the cost is that user `--:: augment string { ... }` annotations need a merge step in the walker that doesn't exist yet. Flagging — out of MVP.
