# Crescent — Overview

Crescent is an operating system in Lua — a zero-dependency, vendoring-first
ecosystem that covers the entire surface area of software. Not just stdlib
basics: connection protocols, parsers, codecs, game primitives, package
management, typechecking, all of it, as pure Lua libraries you own outright.

`git clone` and run. No installs, no build steps. LuaJIT binaries for all
supported platforms are vendored in `bin/`. Dependencies are committed, not
fetched.

Every library is copy-paste-ownable. Vendor it into your project and it's yours
— no upstream to break you, no version negotiation, no hidden coupling.

Monorepo inspired by [thi.ng/umbrella](https://thi.ng/umbrella): one repo, one
vision, composable pieces. Libraries are independent — each a directory under
`lib/` with its own tests, types, and docs.

Part of the [rhi ecosystem](https://rhi.zone).

## Scope

Crescent's ambition is the entire surface area of software. If a concept exists
as a Rust crate in the rhi ecosystem (or as a library anywhere) and it can be
implemented in pure Lua with acceptable LuaJIT performance, it belongs in
crescent. The Rust projects and the crescent libraries are parallel
implementations of the same concepts; LuaJIT is fast enough that both are real.

**Crescent is not a language.** It has no syntax beyond type annotations in
comments (`--:`, `--::`). There is no transpiler. The answer is always a
library.

## Architecture

```
lib/          — all packages (http, websocket, dns, sqlite, fs, ljsocket, ...)
lib/type/     — typechecker (parses LuaJIT FFI cdefs)
lib/pkg/      — package manager
lib/test/     — test runner
lib/crescent_examples/ — small scripts demonstrating crescent
doc/          — documentation
```

**Every package is a directory** under `lib/` with an `init.lua` entry point.
LuaJIT doesn't include `?/init.lua` in default `package.path` (Lua 5.2+ does),
so entry points conditionally add `./?/init.lua` to `package.path` (check
before adding; composable entry points must not double-add).

## Principles

See `docs/principles.md` for the north star: make the computer small, make
interactive anything small, discoverability in the tool not in tutorials, no
online resources in the loop.
