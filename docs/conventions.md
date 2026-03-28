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

Every format library exposes:

```lua
M.encode(value, opts?) -> string | (nil, errmsg)
M.decode(string, opts?) -> value | (nil, errmsg)
```

- `encode`/`decode` are the canonical slot names. This is the interface you program
  against when swapping codecs or passing one as a value.
- Internal helpers may use descriptive names (`headers_to_string`, `parse_frame`, etc.)
  but the public interface is always `encode`/`decode`.
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

## Naming

- Functions: `snake_case`.
- Types/constructors: `PascalCase` (rare in Lua; use only for FFI structs or OO types).
- Constants: `UPPER_SNAKE` for true constants; `lower_snake` for configuration tables.
- Private (module-internal): `_` prefix.
- Module table: always `M` or the library name. Never `self` at module level.

## Type annotations

- Use `--:` (inline, preceding line) and `--::` (declarations). Never EmmyLua.
- `unknown` for dynamic/untyped data — forces narrowing at use sites.
- `any` only when explicitly opting out of checking (document why).
- Annotate all public API functions. Internal helpers are encouraged but not required.

## Performance

- No string concatenation (`..`) in loops. Build with a table, `table.concat` at end.
- No closures in hot paths. Hoist to module level or use upvalues.
- No allocations in hot paths where avoidable.
- Constants at module level, computed once.
- Measure before and after any optimization claim.
