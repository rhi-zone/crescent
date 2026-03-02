# CLAUDE.md

Behavioral rules for Claude Code in the crescent repository.

## Project Overview

Comprehensive LuaJIT ecosystem — stdlib, typechecker, package manager.

Monorepo inspired by [thi.ng/umbrella](https://thi.ng/umbrella): one repo, one vision, composable pieces. All libraries are vendorable — designed to be copied into your project and owned.

Part of the [rhi ecosystem](https://rhi.zone).

## Architecture

```
lib/          — all packages (http, websocket, dns, sqlite, fs, ljsocket, ...)
lib/type/     — typechecker (parses LuaJIT FFI cdefs)
lib/pkg/      — package manager
lib/test/     — test runner
lib/cli/      — CLI tools
doc/          — documentation
```

**Every package is a directory** under `lib/` with an `init.lua` entry point. This gives each package room for LICENSE, tests, type definitions, and docs alongside the code. LuaJIT doesn't include `?/init.lua` in the default `package.path` (that's a Lua 5.2+ default), so entry points must conditionally add `./?/init.lua` to `package.path` (check before adding — Lua 5.2+ already includes it, and multiple entry points may be composed).

## Development

```bash
nix develop                  # Enter dev shell
luajit lib/test/cli.lua      # Run tests
cd docs && bun dev           # Local docs
```

## Core Rules

- **Note things down immediately:** problems, tech debt, or issues spotted MUST be added to TODO.md backlog. "Out of scope for now" is not a reason to skip this — if something was deferred, it goes in TODO.md right then.
- **Do the work properly.** Don't leave workarounds or hacks undocumented.

## Design Principles

**Vendorable.** Every library is a set of `.lua` files you can copy into your project. No build step, no native bindings to manage. You own the code.

**Pure Lua first.** Prefer pure Lua implementations for hackability. Use FFI only when pure Lua can't do it (syscalls, native libraries, performance-critical paths).

**Hackable.** The user should be able to read, understand, and modify any library. Prefer clarity over abstraction.

**Fast.** Performance at all costs. LuaJIT is fast — don't waste it. Avoid allocations in hot paths, prefer tables over closures, measure before and after.

**LuaJIT-first, not LuaJIT-only.** Target LuaJIT but don't gratuitously break Lua 5.2+ compatibility. Pure Lua code shouldn't depend on LuaJIT quirks. FFI and `bit.*` are inherently LuaJIT-only, but everything else should work on standard Lua if it doesn't sacrifice performance.

**Composable.** Libraries depend on each other minimally. Pick what you need, ignore the rest.

**Single source of truth.** The typechecker reads FFI cdefs directly — no duplicate type definitions.

## Workflow

**Minimize file churn.** When editing a file, read it once, plan all changes, and apply them in one pass.

**`normalize view` is available** for structural outlines of files and directories:
```bash
~/git/rhizone/normalize/target/debug/normalize view <file>    # outline with line numbers
~/git/rhizone/normalize/target/debug/normalize view <dir>     # directory structure
```

## Session Handoff

Use plan mode as a handoff mechanism when:
- A task is fully complete (committed, pushed, docs updated)
- The session has drifted from its original purpose
- Context has accumulated enough that a fresh start would help

Before entering plan mode:
- Update TODO.md with any remaining work
- Update memory files with anything worth preserving across sessions

Then enter plan mode and write a plan file that either:
- Proposes the next task if it's clear: "next up: X — see TODO.md"
- Flags that direction is needed: "task complete / session drifted — see TODO.md"

ExitPlanMode hands control back to the user to approve, redirect, or stop.

## Commit Convention

Use conventional commits: `type(scope): message`

Types:
- `feat` - New feature
- `fix` - Bug fix
- `refactor` - Code change that neither fixes a bug nor adds a feature
- `docs` - Documentation only
- `chore` - Maintenance (deps, CI, etc.)
- `test` - Adding or updating tests

Scope is the library or component name (e.g., `feat(http): add chunked transfer encoding`).

## Performance Work

When doing performance optimization:
- **Benchmark before and after.** Use `docs/perf/v2_parse.lua` for parser/lexer throughput.
- **Record results in `docs/perf/log.md`** with the commit hash of both baseline and optimization. Most recent entries first.
- **Include**: file sizes, times, throughput (MB/s), allocation (KB/parse), and speedup ratios.

## Typechecker Design Principles

**Prefer principled solutions over special cases.** When a check needs to accept a new category of type, ask whether the type system can be extended cleanly (e.g. declare the primitive's metamethods, extend unify) rather than tagging the predicate. Ad-hoc flags in `is_numeric`, `is_concat_compatible`, etc. erode correctness over time.

## Negative Constraints

Do not:
- Announce actions ("I will now...") - just do them
- Leave work uncommitted
- Use `--no-verify` - fix the issue or fix the hook
- Assume tools are missing - check if `nix develop` is available for the right environment
- Add dependencies that require a build step — pure Lua + FFI only
