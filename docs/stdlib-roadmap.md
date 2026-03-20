# Stdlib Roadmap

Comprehensive plan for bringing `lib/` to stdlib quality. Based on an audit of
all ~90 packages (2026-03-20).

## Quality bar

A stdlib-quality package must have all of:

1. **`init.lua` entry point** — the package is `require("lib.foo")`-able
2. **`package.path` guard** — `if not package.path:find(...)` at the top
3. **Tests** — `foo_test.lua` with meaningful coverage
4. **`nil, err` error convention** — at all public boundaries; `error()` only
   for programmer errors (invariant violations)
5. **Type annotations** — crescent-style `--:` / `--::`, not LuaLS `@param`
6. **No unresolved external deps** — no `require("dep.*")` unless the dep is
   also in `lib/` (or declared in a manifest)
7. **Snake_case naming** — already 100% consistent, just maintain it

Currently: 3 packages meet the bar (cr, http, websocket — partially). 0 are
fully compliant.

## Current state

### What works

- **Naming**: snake_case everywhere, no exceptions
- **Module pattern**: `local M = {}` / `return M` universally
- **Namespaces**: `lib/hash/`, `lib/format/`, `lib/encode/` established

### What doesn't

| Problem                  | Scope              |
|--------------------------|--------------------|
| No `init.lua`            | 44 of ~90 packages |
| No tests                 | ~82 of ~90         |
| No path guard            | ~87 of ~90         |
| No type annotations      | ~90 of ~90         |
| Mixed error conventions  | ~34 packages       |
| `dep.*` coupling         | 10 packages        |

## Package triage

### Tier A — stdlib core (keep, invest)

Packages that belong in a general-purpose stdlib. Bring to quality bar.

**Already namespaced:**
- `hash/sha256`, `hash/sha1` — need parity tests, type annotations
- `format/json` (lunajson), `format/cbor`, `format/toml` — toml is new, others need tests
- `encode/base64`, `encode/urlencode`, `encode/utf8` — need type annotations

**System:**
- `path` — has tests, needs path guard + annotations
- `fs` — no init.lua, needs proper entry point
- `env` — tiny, needs tests
- `time` — needs tests, annotations
- `get_cwd` — merge into `fs` or `path`

**Network:**
- `http` — most mature, has tests; submodules need audit
- `websocket` — has tests, good shape
- `dns` — no init.lua, needs entry point
- `tls` — needs tests

**Data:**
- `merge` — has tests, tiny
- `pretty_print` — useful utility, needs tests
- `mimetype` — no init.lua, solid data tables

**Concurrency:**
- `epoll` — foundational, needs tests
- `async` — needs tests, design review
- `inotify` — needs tests
- `timerfd` — needs tests

**FFI infrastructure:**
- `ljsocket` — foundational for network stack, needs tests
- `dynamic_library` — needs tests
- `ffi_unload` — tiny utility

**Functional programming:**
- `fp/` — 21 subpackages: typeclasses (Mappable, Applicable, Chainable, Foldable,
  Traversable, Semigroup, Monoid, etc.), data types (Maybe, Either, Fn), optics
  (lens, prism, iso, traversal), ADT constructors. Designed to stress-test the
  typechecker's HKT and constraint support — see `docs/fp-design.md` and
  `docs/typeclass-design.md`. 18 test files, 402 assertions. Needs root `init.lua`
  and crescent-style type annotations.

**Missing (to build):**
- `process` — subprocess spawn/pipes/wait
- `signal` — POSIX signal handling
- `iter` — combinator utilities
- `format/msgpack` — common serialization format
- `hash/hmac` — HMAC construction
- `rand` — CSPRNG via `/dev/urandom` or `getrandom(2)`

### Tier B — domain libraries (keep, lower priority)

Useful for specific domains but not general-purpose stdlib.

- `sqlite` — has tests, error convention needs fixing (error() → nil,err)
- `cmark` — CommonMark, dep.* coupling
- `qrencode` — QR codes, large but standalone
- `argon2` — password hashing, needs tests
- `html` — HTML builder
- `markdown` — no init.lua
- `imap`, `irc`, `dns` — protocol implementations
- `cparser` — C header parsing (used by typechecker)

### Tier C — application-specific (move out or archive)

Not stdlib material. Either move to a separate repo or archive.

- `glua` — OpenGL bindings, vendored
- `lovr` — VR framework bindings
- `game` — game-specific
- `3d` — empty
- `discord` — Discord client
- `activitypub`, `activitystreams` — federation protocols
- `wayland`, `wlroots`, `xlib`, `xft`, `xkbcommon`, `x11_keysym` — desktop/WM
- `pulseaudio`, `soloud` — audio
- `glb` — 3D model format
- `textbar`, `text_world`, `gmcp` — application-specific
- `tree_sitter` — external binding
- `ljltk` — third-party Lua parser
- `mock` — large mock library
- `myowtype` — unclear purpose
- `todo` — stubs (jpeg, png, xcb, soloud)
- `lsif`, `lsp` — language tooling (separate from lib/type/static/lsp.lua)
- `codetree` — code analysis
- `webview` — native webview binding
- `lua2js`, `js` — transpiler
- `ui` — UI framework

### Tier D — merge or delete

- `null` — 7 lines, merge into a core utils module or inline
- `weakref` — 12 lines, same
- `memory` — 25 lines, same
- `oauth` — 0 lines (empty file)
- `htaccess` — 36 lines, Apache-specific
- `make` — 44 lines, build tool fragment
- `base` — 40 lines, number base conversion
- `it_eval`, `it_fn` — point-free expression builders, superseded by `lib/iter`
- `functional` — no init.lua, superseded by `lib/fp` + `lib/iter`
- `lil` — 10 lines, wrapper

## Priority order

### Phase 1 — Foundation (immediate) ✓ done 2026-03-20

1. ✓ Add `init.lua` to all Tier A packages that lack one (fs, dns, mimetype)
2. ✓ Add path guard to all Tier A packages (~23 packages)
3. ✓ Error convention sweep — `dynamic_library` fixed; others already correct

### Phase 2 — Test coverage (partial, 2026-03-20)

Done:
- ✓ `epoll` — 22 assertions
- ✓ `timerfd` — 18 assertions
- ✓ `time` — 7 assertions
- ✓ `env` — skips gracefully (needs compiled .so)
- ✓ `fs` — 26 assertions
- ✓ `mimetype` — 32 assertions
- ✓ Hash parity (sha1/sha256) — 67 assertions

Remaining (need network/system state, harder to test in isolation):
1. `ljsocket` — everything network depends on it
2. `tls` — HTTPS depends on it
3. `dns` — name resolution
4. `inotify` — file watching

### Phase 3 — Missing packages ✓ done 2026-03-20

1. ✓ `process` — subprocess spawn/exec via POSIX FFI (873463b)
2. ✓ `iter` — combinator utilities, 21 functions (committed)
3. ✓ `rand` — CSPRNG via getrandom(2) + /dev/urandom (306aa1b)
4. ✓ `hash/hmac` — HMAC construction, RFC test vectors (25918c3)
5. ✓ `format/msgpack` — pure Lua encode/decode (21a86b1)
6. ✓ `signal` — POSIX signal handling via FFI (9b50ede)

### Phase 4 — Cleanup (partial, 2026-03-20)

1. ✓ Archive Tier C/D packages — 46 moved to archive/ (1f84ced); fp/ restored
   to lib/ (Tier A — typechecker stress test, not application-specific)
2. Resolve `dep.*` coupling in Tier A/B packages
3. Type annotations across all Tier A packages

### Phase 5 — Namespace expansion

As packages accumulate, evaluate whether new namespaces are needed:
- `lib/net/` — if protocol count grows beyond http/websocket/dns/tls
- `lib/sys/` — if system primitives grow beyond fs/process/signal/env
- `lib/crypto/` — if crypto grows beyond hash/ (key derivation, AEAD, etc.)

## Conventions (reference)

Detailed in `docs/stdlib-design.md`:
- Iterator protocol: Lua's built-in triple; closures are degenerate case
- Error convention: `nil, err` at boundaries
- Concurrency: sans-I/O, injectable scheduler
- Layering: pure-data layer under every I/O module
- Namespacing: when 2+ of noise/shared-interface/parent-value apply
