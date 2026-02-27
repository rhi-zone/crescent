# TODO

## security (fix soon)
- [x] http/router: path traversal via symlinks — `path.safe_resolve()` with FFI `realpath()`
- [x] http/server: reads one packet, not until headers complete — loop until `\r\n\r\n`, then read body by Content-Length
- [x] http/router/staticx: pattern `.gz$` should be `%.gz$` (Lua pattern, `.` matches any char)
- [x] http/router/staticx: opens files in `"r"` mode — should be `"rb"` to avoid newline mangling
- [ ] Full security audit of all imported libraries

## correctness
- [x] http/router/staticx: `Content-Length = ""` is invalid HTTP — omit header entirely
- [ ] http/router/staticx: detects directories via `read("*all") == nil` — fragile, use lfs or stat
- [ ] http/router/staticx: reads entire files into memory — needs size cap or streaming for large files

## stdlib
- [ ] http: extract network layer (client.lua, server.lua) — needs lib/ljsocket, lib/epoll, lib/socket/server.lua
- [ ] http: extract routers — needs lib/path, lib/mimetype, lib/fs, lib/lunajson
- [ ] Review and polish all libraries pulled from ~/git/lua (bulk import done)
- [ ] lib/todo/: conflicts with dep/todo/ (stubs for jpeg, png, xcb, soloud + a sqlitex.lua, webp.lua) — decide what to keep
- [ ] Audit vendored third-party libs (ljsocket, lunajson, sqlite, cparser, etc.) — ensure LICENSE files present
- [ ] Review lib/cli/ scripts — many have implicit dep on lib/ layout, may need path fixups
- [ ] Remove or integrate duplicate/overlapping libs (e.g., mock.lua vs mock/, lil.lua vs lil/)
- [ ] replx: add provenance tracking for lazy-loaded globals (symbol → source module)
- [ ] FFI bindings: add ABI sanity checks (sizeof/offsetof assertions for wlroots version skew)
- [ ] Formalize C header ingestion pipeline (update_wlroots.sh pattern) as reusable tooling

## typechecker

### self-hosting blockers (run clean on own codebase)
- [ ] Widen literal types on reassignment (`local k = 1; k = k + 1` should work)
- [ ] Multi-return unpacking (`local a, b, c = f()` should assign all three)
- [ ] Forward-declared locals (`local f; f = 42` — use typevar, not nil)
- [ ] Integer literal inference (hex `0x36` should be integer, not number)
- [ ] Arithmetic on integers returns integer, not number
- [ ] String method resolution (`s:gsub(...)` resolves via string metatable)
- [ ] `number` assignable to `integer` parameter (safe widening direction)

### output formats
- [ ] `--format json` structured output (file, line, col, severity, message)
- [ ] `--format sarif` for GitHub Code Scanning / CI integration
- [ ] Column numbers in error positions (currently line-only)

### done
- [x] Type inference for local bindings
- [x] Structural typing for tables
- [x] Angle-bracket generics (`Name<T, U>`) with constraint support
- [x] Named type resolution with two-pass forward references
- [x] Tuple types (`{ number, string }`) and spread (`{ ...Base }`)
- [x] Flow-sensitive type narrowing (type(), nil checks, truthiness, assert)
- [x] Module resolver + prelude system (Array, Dict, Set, Optional)
- [x] Nominal types (newtype, opaque)
- [x] Match types (`match T { pattern => result }`)
- [x] Intrinsics ($Keys, $EachField, $EachUnion)
- [x] Overload resolution (best-match scoring)
- [x] setmetatable __index merging, __call metamethod

### backlog
- [ ] Parse LuaJIT FFI cdef blocks
- [ ] Full require() return type tracking (infer module return type)
- [ ] Prelude: migrate Lua 5.1 stdlib from builtins.lua to .d.lua
- [ ] Prelude: LuaJIT-specific (ffi, bit, jit) .d.lua
- [ ] Private field visibility enforcement
- [ ] $EachField / $EachUnion full transform evaluation
- [ ] Typed holes / completions
- [ ] Discriminated union narrowing (`if t.kind == "literal" then ...`)
- [ ] `pcall`/`xpcall` return type narrowing
- [ ] Generic function inference (infer type params from call site args)

## infra
- [ ] Bench infrastructure (pure Lua, handgrown)
- [ ] Fuzz infrastructure (pure Lua, handgrown)
- [ ] Formalize code style conventions — don't assume ~/git/lua conventions are correct, decide fresh
- [ ] `cr` binary entry point
- [ ] Third-party libs under lib/ must preserve original LICENSE

## package manager
- [ ] Vendor-first install (copy .lua files into project)
- [ ] Registry / index format
