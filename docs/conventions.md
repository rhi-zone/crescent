# Crescent Library Conventions

Rules every `lib/` library is held to. These are not suggestions — they are the interface
contract that makes libraries composable without glue code.

## Error handling

**Return `(nil, errmsg)` on failure; return the value on success.**

```lua
local value, err = json.decode(s)
if not value then error(err) end
```

- Never throw from a library function unless the call is a programming error
  (wrong argument type, nil where disallowed). Data errors are not programming errors.
- `errmsg` is a string. No error objects, no error codes. If the caller needs to
  distinguish error kinds, the string is human-readable and the function has variants.
- The raw/unwrapped variant (if it exists) may throw — name it `_raw` and document it.
  The public API always returns `(nil, errmsg)`.

## Codec interface (formats)

Every format library exposes both a descriptive name and uniform slot names:

```lua
M.string_to_foo(s, opts?) -> foo | (nil, errmsg)      -- descriptive primary
M.foo_to_string(v, opts?) -> string | (nil, errmsg)   -- descriptive primary
M.decode(s, opts?) -> foo | (nil, errmsg)              -- uniform alias
M.encode(v, opts?) -> string | (nil, errmsg)           -- uniform alias
```

- `a_to_b` names are the primary — they say exactly what goes in and what comes out.
  `parse_request` is ambiguous (from bytes? from a file?). `string_to_request` is not.
- `encode`/`decode` are always aliased as the uniform slot names for swappability —
  when passing a codec as a value or writing code that works across formats.
- Null sentinels: if the format distinguishes null from absent, expose `M.null` as a
  sentinel value. Callers use `value == M.null` to test.
- Options: pass as a trailing table `opts`. Never positional booleans.
- Streaming: if the format supports streaming, expose `M.encoder()` / `M.decoder()`
  returning stateful objects with `push(bytes)` / `flush()` / `result()` methods.
  The one-shot `encode`/`decode` always exists alongside.

## Protocol interface

Every protocol library exposes a connection object with:

```lua
conn = M.connect(host, port, opts?) -> conn | (nil, errmsg)
conn:send(msg) -> true | (nil, errmsg)
conn:recv() -> msg | (nil, errmsg)
conn:close()
```

- For server-side, expose `M.listen(port, handler, opts?)` where
  `handler(conn)` is called per accepted connection.
- Transport abstraction: protocols accept an optional `transport` in opts so the
  caller can inject a TLS wrapper, a test double, etc. without subclassing.
- Async integration: if the protocol integrates with epoll, take `epoll` as a
  parameter — never create one internally. Caller owns the event loop.
- Lifecycle hooks: `on_connect`, `on_close`, `on_error` in opts where useful.

## Implementation tiers

When multiple implementation tiers exist (system library > FFI > pure Lua):

- Select the best available tier **at load time** via `pcall`. No runtime switching.
- Each tier is a **real, independent implementation** — no wrapping one around another.
- Never fail hard when a faster tier is unavailable — fall through to the next.
- Expose `M._tier` (string: `"system"`, `"ffi"`, `"pure"`) for introspection/testing.
- Pure Lua tier must exist before any FFI tier is added. It is the correctness reference.
- Parity tests assert byte-for-byte identical output across tiers.

## Module structure

```
lib/foo/
  init.lua          -- entry point; adds ./?/init.lua to package.path if needed
  foo_test.lua      -- tests live alongside the library, not in a separate dir
  pure.lua          -- pure Lua implementation (if tiered)
  ffi.lua           -- FFI implementation (if tiered)
```

- Every library is a directory with `init.lua`. Single-file libraries still get a
  directory for room to grow.
- Tests are named `<lib>_test.lua` and live in the library directory.
- No `src/`, no `test/`, no `lib/` subdirectory inside a library.

## Browser-side library prefix

Libraries whose contents target the browser realm (JS type declarations,
runtime sandbox, host-bridged cap shims) use the prefix `lib/js_*/`.
Examples: `lib/js_types/`, `lib/js_realm_sandbox/`. This signals at the
library boundary that the package is part of the browser-side surface area,
distinct from daemon-side libraries (`lib/<name>/` with no prefix). See
`docs/platform_isolation.md` for the platform model.

## Naming

- Functions: `snake_case`.
- Types/constructors: `PascalCase` (rare in Lua; use only for FFI structs or OO types).
- Constants: `UPPER_SNAKE` for true constants; `lower_snake` for configuration tables.
- Private (module-internal): `_` prefix.
- Module table: always `M` or the library name. Never `self` at module level.

## Type annotations

- Use `--:` (inline, preceding line) and `--::` (declarations). Never EmmyLua.
- `unknown` is TypeScript `unknown`: the type is not statically known, caller must narrow
  before use. Use for genuinely dynamic data, external values whose shape isn't declared,
  or values that could be anything at runtime.
- `any` is TypeScript `any`: opts out of checking entirely. Use only as an explicit
  escape hatch — document why. Never use `any` just to silence a type error.
- Annotate all public API functions. Internal helpers are encouraged but not required.

## Performance

- No string concatenation (`..`) in loops. Build with a table, `table.concat` at end.
- No closures in hot paths. Hoist to module level or use upvalues.
- No allocations in hot paths where avoidable.
- Constants at module level, computed once.
- Measure before and after any optimization claim.
