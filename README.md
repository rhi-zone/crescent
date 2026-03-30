# crescent

Comprehensive LuaJIT ecosystem — stdlib, typechecker, package manager.

A monorepo of composable LuaJIT libraries, inspired by [thi.ng/umbrella](https://thi.ng/umbrella). All libraries are vendorable: copy what you need into your project and own it.

Part of the [rhi ecosystem](https://rhi.zone).

## Structure

All packages live under `lib/`:

- **lib/** — standard library modules (http, websocket, dns, sqlite, fs, path, ...)
- **lib/type/static/** — static typechecker with constraint-based inference, LSP daemon, lint rule passes, type search
- **lib/pkg/** — vendor-first package manager (semver, manifest, lockfile)
- **lib/test/** — test runner, property testing, fuzz testing
- **lib/orchestration/** — task graph, executor registry, AI executor
- **lib/fp/** — functional programming typeclasses and optics
- **lib/ai/** — LLM provider dispatch (Anthropic, OpenAI, Google)

## Philosophy

LuaJIT is the fastest scripting runtime. It has the best FFI. It's the most hackable. What it doesn't have is an ecosystem.

Crescent is that ecosystem. Not a framework — a collection of libraries you can use together or apart, read and understand, copy and modify. Every C library LuaJIT can call is part of the ecosystem; crescent just makes them accessible.

## Development

```bash
nix develop                  # Enter dev shell
luajit lib/test/cli.lua      # Run tests
cd docs && bun dev           # Local docs
```
