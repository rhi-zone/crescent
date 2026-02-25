# crescent

Comprehensive LuaJIT ecosystem — stdlib, typechecker, package manager.

A monorepo of composable LuaJIT libraries, inspired by [thi.ng/umbrella](https://thi.ng/umbrella). All libraries are vendorable: copy what you need into your project and own it.

Part of the [rhi ecosystem](https://rhi.zone).

## Structure

- **lib/** — standard library modules (http, websocket, dns, sqlite, fs, ...)
- **type/** — typechecker with FFI cdef parsing
- **pkg/** — vendor-first package manager
- **cli/** — command-line tools built on lib/
- **dep/** — vendored third-party code

## Philosophy

LuaJIT is the fastest scripting runtime. It has the best FFI. It's the most hackable. What it doesn't have is an ecosystem.

Crescent is that ecosystem. Not a framework — a collection of libraries you can use together or apart, read and understand, copy and modify. Every C library LuaJIT can call is part of the ecosystem; crescent just makes them accessible.

## Development

```bash
nix develop              # Enter dev shell
luajit cli/test.lua      # Run tests
```
