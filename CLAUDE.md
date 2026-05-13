# CLAUDE.md

Behavioral rules for Claude Code in the crescent repository.

## Project Overview

Crescent is an operating system in Lua — a zero-dependency, vendoring-first ecosystem that covers the entire surface area of software. Not just stdlib basics: connection protocols, parsers, codecs, game primitives, package management, typechecking, all of it, as pure Lua libraries you own outright.

`git clone` and run. No installs, no build steps. LuaJIT binaries for all supported platforms are vendored in `bin/`. Dependencies are committed, not fetched.

The design is deliberately infectious: every library is copy-paste-ownable. Vendor it into your project, and it's yours — no upstream to break you, no version negotiation, no hidden coupling. This is what vendoring-first means: the unit of reuse is source you control, not a package you depend on.

Monorepo inspired by [thi.ng/umbrella](https://thi.ng/umbrella): one repo, one vision, composable pieces. Libraries are independent by design — each a directory under `lib/` with its own tests, types, and docs alongside the code.

Part of the [rhi ecosystem](https://rhi.zone).

### Scope

Crescent's ambition is the entire surface area of software, not just stdlib basics. If a concept exists as a Rust crate in the rhi ecosystem (or as a library anywhere), and it can be implemented in pure Lua with acceptable LuaJIT performance, it belongs in crescent. Connection protocols, structural analysis, expression evaluation, game primitives, grammar parsing, format conversion — all of it, as pure Lua libraries.

The Rust projects in the rhi ecosystem and the crescent libraries are parallel implementations of the same concepts, each first-class in their own ecosystem. This is not "Rust for the real thing, Lua for the toy version" — LuaJIT is fast enough that both are real implementations. The distinction is ecosystem, not performance.

**Crescent is not a language.** It has no syntax of its own beyond type annotations in comments (`--:`, `--::`). There is no transpiler, no compilation step. Code is standard Lua executed directly by LuaJIT. Do not propose "language-level" solutions that would require new syntax or a transpiler — the answer is always a library.

## Architecture

```
lib/          — all packages (http, websocket, dns, sqlite, fs, ljsocket, ...)
lib/type/     — typechecker (parses LuaJIT FFI cdefs)
lib/pkg/      — package manager
lib/test/     — test runner
lib/crescent_examples/ — small scripts demonstrating crescent (not a library)
lib/cli/      — CLI arg parsing library (future)
doc/          — documentation
```

**Every package is a directory** under `lib/` with an `init.lua` entry point. This gives each package room for LICENSE, tests, type definitions, and docs alongside the code. LuaJIT doesn't include `?/init.lua` in the default `package.path` (that's a Lua 5.2+ default), so entry points must conditionally add `./?/init.lua` to `package.path` (check before adding — Lua 5.2+ already includes it, and multiple entry points may be composed).

## References

Pointers to conditional context — read on demand, not loaded by default.

- `.github/workflows/build-vendored.yml` — produces `bin/luajit*`, `bin/ld-musl-*`, `dep/libsqlite3*`, `dep/libz*`. Triggered via `workflow_dispatch`; commits artifacts back to the repo.
- `.github/workflows/ci.yml`, `.github/workflows/ci-full.yml` — test CI.
- `.github/workflows/deploy-docs.yml` — docs site deploy.
- `bin/cr` — platform dispatch into vendored LuaJIT (Linux: loader + `luajit-bin`; macOS: native binary; Windows: `cr.bat`/`cr.ps1`).
- `flake.nix` — contributor dev shell only (bun for docs); not a runtime dependency.
- `docs/conventions.md`, `docs/batteries.md`, `docs/inventory.md`, `docs/inventory_summary.md` — already referenced elsewhere in this file.
- `docs/type-system.md`, `docs/typechecker-v3.md`, `docs/typechecker-v2.md` (historical), `docs/soundness-audit.md`, `docs/type-tag-matrix.md` — typechecker design. Grep these before answering type-system design questions; do not improvise from first principles.
- `docs/pkg-design.md` — package manager design (vendor-first via `dep/`, `pkg.lua` manifest, `crescent.lock`).
- `lib/test/` — test infrastructure: `assert.lua` (assertions), `gen.lua` + `prop.lua` (property testing), `fixture.lua` (fixture/snapshot, `UPDATE_SNAPSHOTS=1`), `fuzz.lua` (fuzz, `FUZZ_SEED` replay), `arb.lua` (integrated shrinking).
- `lib/type/static/lsp.lua` — LSP daemon (stdio JSON-RPC 2.0); run via `luajit lib/type/static/lsp.lua`.

## Development

```bash
bin/cr test                  # Run tests
bin/cr check <file>          # Typecheck a file
bin/cr check --summary <file>  # Root-cause-grouped error summary (use this first when diagnosing why a file has errors)
cd docs && bun dev           # Local docs (requires bun)
nix develop                  # Dev shell for contributors (bun, etc.)
```

## Core Rules

**Do the correct thing fully.** When the right approach is clear, implement it. Amount of work, scope, and convenience are never reasons to ship a known-wrong version. "Pragmatic but slightly unsound," "good enough for now," "we'll add X later," "out of scope," and "no half-measures with a TODO" are rejection categories, not design options — they all describe the same failure mode: choosing an incorrect solution and letting it accumulate. Half-measures and gradual migrations are context poisoning: every future session sees the wrong state, builds on it, and the error compounds. If a design needs X to be correct, ship with X or don't ship. The only legitimate reason to omit something is that it genuinely does not apply yet (no caller, no user, no data) — and that reason must survive scrutiny if challenged.

**Counterweight: don't fake confidence.** The rule above does not license bulldozing through uncertainty. If you don't know which approach is correct, "I don't know" and "stop" are first-class outputs, not failure states. Confident assertions require (1) adversarially reasoning through plausible alternatives and showing each is inferior, AND (2) verifying no downsides to the assertion. Without both, state your hypothesis as a hypothesis — flagged as such — and verify next. Do not hedge-word a guess into sounding like knowledge.

Context is poisoned the moment you confidently state something wrong. Retraction does not fully undo it; downstream reasoning is already shaped by the bad claim. Prevention is the only real mitigation — rules that fire after the assertion cannot recover it.

**Write things down immediately.** Problems and tech debt → TODO.md. Design decisions → docs/. Completed items → mark `[x]` in TODO.md in the same commit. Conversation evaporates — if it matters to a future session, write it now. Never delete unchecked TODO items.

**`docs/batteries.md` is the definitive ecosystem scope document.** Read it before discussing future libraries or roadmap.

**`docs/inventory_summary.md` is loaded at session start** — it lists what categories of library exist in crescent and roughly what's in each. Read it. **`docs/inventory.md` is the full per-library index** — grep it before designing or implementing anything reusable. If `inventory.md` doesn't list what you're looking for, spot-check `lib/` directly; the index can lag by a commit. **When adding a new library or `_types.lua` file, add a line to `docs/inventory.md` in the same commit. Add a line to `docs/inventory_summary.md` only if the new library belongs to a category not already there.**

**Something unexpected is a signal, not noise.** Stop and ask why before continuing.

**Don't add type aliases that legitimize laziness.** When N annotations fail because they used a vague type name (`table`, `function`, `any`), the fix is to correct each annotation to a specific type — not to add a permissive alias that makes them "pass". The errors are the typechecker doing its job; suppressing them by widening the type system silently accepts wrong code. Same family of mistake as `any` proliferation: reducing the error count is not the goal, accuracy is. If a type alias would change a strict check into a permissive one, do not add it.

**Lua code must not regress typechecking before commit.** The pre-commit hook in `.githooks/pre-commit` enforces this — to activate it, run `git config core.hooksPath .githooks` once per clone (the repo does not auto-activate hooks for safety). For each staged `lib/**/*.lua` file the hook runs `timeout 30 bin/cr check <file>` on both the staged blob and the `HEAD` blob and rejects the commit only when the staged version has MORE errors than `HEAD` (or when a new file has any errors). Pre-existing errors in a file you happen to edit are tolerated. Timeouts always reject. Do not bypass with `--no-verify` — fix the new error or fix the hook.

## Library Conventions

See `docs/conventions.md` for the full spec. Short version:
- Errors: `(nil, errmsg)` return, never throw from data errors
- Codecs: `string_to_foo`/`foo_to_string` as primary names (type-in-the-name); `encode`/`decode` always aliased for swappability
- Protocols: `connect` / `send` / `recv` / `close` — transport injected via opts, never created internally
- Tiers: system > FFI > pure Lua, selected at load time, each independent, `M._tier` for introspection
- Annotations: `--:` / `--::` only. `unknown` = TS `unknown` (caller must narrow). `any` does not exist — do not write it. If a type is genuinely unknown, use `unknown`. If the typechecker can't handle a case without `any`, that is a typechecker bug to fix.
- **Casts: `--[[: T]]` is the checked cast (full subtyping required). `--[[:! T]]` is the overlap-checked force cast — it is almost never correct. If `unknown` can't be narrowed with a type guard (`if type(x) == "string"`, discriminant check, etc.), the upstream producer has the wrong type annotation. Fix the producer. If `A | B` can't be narrowed to `A` with a discriminant check, that is a typechecker bug to fix. A force cast that papers over either case is wrong. `--[[:! any]]` is rejected — use `--[[: any]]` if you genuinely need an any cast.**
- **`...` vs index signatures** — these are distinct. `...` is a structural subtyping marker: `{ name: string, ... }` accepts any table with at least `name`. It says nothing about reading arbitrary fields. `{ [string]: T }` is an index signature: any string key maps to `T`. Confusing them leads to open types on concrete data objects (wrong) or expecting arbitrary field reads to work on `...`-typed values (also wrong).

## Type system

Crescent's type system is best-in-class. It is **safer than Rust and more powerful than Haskell.** Treat that as a load-bearing assertion: if you believe a feature is missing — a generic form, a narrowing form, a `match` pattern, an intrinsic, anything — the default hypothesis is that your repro is wrong or you've found a typechecker bug. It is **not** that crescent doesn't support it. Do not introduce `any`, force casts, or in-body narrowing to paper over an apparent gap. Stop, write a 5-line repro, and check.

- Per-feature reference: `docs/typechecker-reference.md` (syntax and semantics, grep this before claiming a feature is missing).
- Design rationale: `docs/type-system.md`.
- Confirm any "missing feature" suspicion with `timeout 30 bin/cr check <file>` on a minimal repro before reporting it.

If the reference and the repro agree that a feature is genuinely absent, that is a bug to design — stop and raise it, do not work around it.

## Implementation Patterns

**When one implementation can't satisfy all legitimate use cases, provide multiple and let the caller choose.** This takes two forms:

- **Performance tiers** — same interface, different speed. E.g. FFI + system library > FFI scalar > pure Lua. Select the best available at load time via `pcall`. Never fail hard when a faster tier is unavailable — fall through to the next. Never silently use a slow tier without the faster ones being attempted first.
- **Interface variants** — same data, different access patterns. E.g. ergonomic (returns strings) vs zerocopy (returns positions). Provide both with clear names; the caller picks. Do not resolve the tradeoff by imposing one choice on all callers — that makes the wrong choice someone else's permanent problem.

In both cases: never wrap one implementation around another. Each is a real, independent implementation. Abstraction between tiers or variants destroys hackability.

**Don't degrade runtime to surface CI gaps.** If a graceful fallback could mask a regression in the preferred tier, the fix is a CI assertion that the preferred tier took effect (`M._tier == "vendored"`, etc.) — not removing the fallback. Fallbacks exist for users on configurations you don't test; removing them shifts the cost from CI (fixable, observable) to user laptops (invisible, permanent). "We'll notice when it breaks" is not a reason to take away graceful behavior.

**Multiple implementations of the same spec require parity tests, parity fuzzing, and benchmarks.** This applies any time two implementations claim to satisfy the same spec — performance tiers, a reference impl and an optimized one, a pure-Lua and an FFI version, a stub and the real thing. Parity tests assert byte-for-byte identical output. Parity fuzzing generates random inputs and runs all implementations, catching edge cases unit tests miss. Benchmarks measure each implementation on representative inputs and results are committed to `docs/perf/log.md`. None of this is optional polish — the implementation is not done until all three exist.

**Fix the specific problem, don't abandon the approach.** When an objection applies to one aspect of a design, fix that aspect. Platform-specific library names → try each known name. Library missing → fall back to next tier. These are implementation details, not architectural blockers. Discarding a whole approach because of a fixable problem is a cop-out.

**Derive from values, not from precedent.** When designing interfaces or making architecture decisions, start from crescent's values (vendorable, pure, fast, hackable, composable). Don't reach for what Java/Go/Rust/TypeScript does — their designs embed assumptions that don't apply here. Other ecosystems are references, not templates.

This applies to *internal* precedent too. The existing repo is not a source of truth for design decisions either. Past sessions wrote patterns that are inconsistent or wrong. A pattern existing in `lib/`, `bin/`, or `docs/` is not by itself a justification — derive from values, not from what previous sessions happened to write. If a current-repo pattern conflicts with the values, the values win and the pattern is the thing to fix.

**No framework code in lib/.** Libraries provide functions callers invoke; they do not own the server, the serving strategy, or the application architecture. No HTTP servers, no cross-language code generation (Lua emitting JS strings), no generic dispatch/routing layers, no JSON-to-function-call adapters. If a "library" is wrapping something the caller could write in five lines, it does not belong in `lib/`.

**`dep/` is the vendor namespace for third-party packages.** `require("dep.foo")` is the convention (see existing `dep.sha1` in websocket). New vendored deps go under `dep/`, not `lib/`.

**Abstraction has a cost.** Wrappers, layers, and indirection reduce hackability and readability. Every abstraction needs justification beyond "it seems cleaner." A direct implementation that is longer is often better than an indirect one that is shorter.


**Capability-based I/O.** Libraries must not reach for `os`, `io`, or other global side-effect modules directly. Instead, accept I/O functions as parameters (constructor opts, function args). This is the foundation of sandbox safety: if a library grabs `os.time()` from a global, it can't run in a capability sandbox. If it accepts a `time_fn` parameter, the caller decides what time source to provide — or whether to provide one at all. This applies to ALL libraries, not just platform app code.

**Caps-first, everywhere.** Every library that performs I/O must accept its dependencies as injected caps, not import them from globals. "This runs outside the sandbox so it's fine" is never a justification for skipping injection. **Defaulting to globals is also a violation** — `opts.popen or io.popen` reaches for `io` just as directly as `io.popen` alone. If a cap is not injected, error; do not silently fall back to the global.

## Design Principles

**This repository is zero-dependency.** A user must be able to `git clone` and run immediately with no external installs — no package manager, no compiler, no runtime. LuaJIT binaries for all supported platforms are vendored in `bin/`. "Use Nix" or "install LuaJIT" are not acceptable answers. NixOS, musl, Alpine, and every other Linux variant are first-class targets. LuaJIT can't be statically linked (FFI needs `dlopen`), so the approach is: build against musl, vendor the matching loader alongside (`bin/ld-musl-*.so.1`), and invoke via the loader explicitly so the host's `/lib/ld-*` is irrelevant. `bin/cr` is the canonical entry point. `bin/luajit` and `bin/luajit-aarch64` are shell shims that exec the real ELFs (`bin/luajit-bin`, `bin/luajit-aarch64-bin`) through the vendored loader; the shims exist so anything that resolves bare `luajit` from PATH (the dev shell adds `$PWD/bin` to PATH) still works.

**Non-ubiquitous FFI dependencies must be vendored as compiled binaries in `dep/`.** `bin/cr test` must pass on a bare clone with no system libraries installed. If FFI code requires a library that isn't part of libc (sqlite3, etc.), compile it from its official source and commit the result to `dep/` for each supported platform — the sqlite3 amalgamation (`sqlite3.c`) is the model: one C file, compiles anywhere, no exotic deps. The nix dev shell (`buildInputs`) is for contributor tooling (bun, docs), not runtime dependencies — it is not a substitute for vendoring.

**Pure Lua is the baseline and must always work standalone.** No library may hard-depend on a system lib or vendored C lib being present. Ubiquitous system libs (libc, etc.) are an optional performance tier. Non-ubiquitous system libs require a pure Lua fallback. Vendored C libs are a last resort when pure Lua is genuinely nonviable for performance reasons. Nothing requires an external install step — must work on a barebones system.


**Target LuaJIT, don't require it.** Optimise for LuaJIT performance (avoid allocations in hot paths, prefer tables over closures, measure before and after) but pure Lua code must not depend on LuaJIT quirks — it should work on standard Lua if it doesn't sacrifice performance.

**Tooling performance bar: bun (general), tsgo for the typechecker.**


**Libraries must work on Linux, macOS, and Windows** unless they explicitly wrap a platform-specific API. Don't assume a single OS.

**Keep coupling low.** A change should require understanding only the local module to reason about correctly. If making a change requires understanding five other modules, that's an architectural smell. Low coupling also means local LLM context is sufficient — high coupling makes correct edits structurally impossible regardless of context window size.

**Never duplicate type definitions.** The typechecker reads FFI cdefs directly. Don't define types separately from cdefs.

## Workflow

**Run the typechecker on files you write or modify.** `bin/cr check <file>...` — do this before committing. See `lib/type/static/CLAUDE.md` for annotation syntax and type system rules. **When diagnosing why a file has many errors, run `bin/cr check --summary <file>` first** — it groups errors by root cause (unresolved requires, cascading unknowns, etc.) and is far more informative than piping raw output through grep/sed.

**Always run typecheck under a timeout.** Single file: `timeout 30 bin/cr check <file>`. Repo-wide: `timeout 120 bin/cr check ...`. A typecheck that exceeds these limits is hanging, not slow — there is a soundness or termination bug somewhere (occurs-check, union-find self-loop, exponential expansion). When this happens, **stop other work immediately**. Two options for subagents:
1. **Hand back to the orchestrator** — return a minimal report ("typecheck hung on <file>; aborting to keep context clean") so a fresh subagent can investigate without your accumulated context.
2. **Investigate inline only if the current task is itself typechecker work** — i.e. you were already in `lib/type/static/` and have the relevant context. Otherwise option 1.

Never silently work around a hang (skip the file, longer timeout, batch differently). The hang is the signal; suppressing it poisons every future session that encounters the same code path.

**Minimize file churn.** When editing a file, read it once, plan all changes, and apply them in one pass.

**`normalize view` is available** for structural outlines of files and directories:
```bash
~/git/rhizone/normalize/target/debug/normalize view <file>    # outline with line numbers
~/git/rhizone/normalize/target/debug/normalize view <dir>     # directory structure
```

**Always commit completed work.** After tests pass, commit immediately — don't wait to be asked. When a plan has multiple phases, commit after each phase passes. Do not accumulate changes across phases. Uncommitted work is lost work.

**When verifying a newly built library, run only that library's test file — not the full suite.** Use `bin/cr test lib/mylib/` or `bin/cr test lib/mylib/mylib_test.lua` directly. Only run the full suite (`bin/cr test`) when checking global regressions.

## Context Management

**Subagent prompts for git work must include: clone the repo locally, verify `git config user.name` and `git config user.email` match the target account before committing, commit with git directly, push with git. Never instruct subagents to use `gh api` to create commits — it bypasses git config and produces wrong authorship.**

**Subagent prompts must have a hard scope.** Every delegation prompt must specify exactly what the agent should do and when to stop — not "fix what you can" but "fix these N files, then stop." Open-ended prompts ("fix the clearly quick ones", "clean up what you find") produce agents that run for hours burning quota. If the scope is genuinely open-ended, break it into explicit batches before delegating.

**Never pre-load the answer in a delegation prompt.** Don't write "verify that X works" or "claim to verify: X" — write "what does X do?" or "find out whether X works". Pre-baked hypotheses in the prompt teach the agent to confirm, not investigate. If you have a hypothesis, name it as a hypothesis the agent should *attempt to falsify*, not as a thing to verify.

**"X works" and "X doesn't work" are claims of equal weight. Both require runnable evidence.** A claim grounded in code-tracing without a paste-able command and its output is a hypothesis, not a finding. If your investigation concluded "Y doesn't work" and you didn't actually run Y, your conclusion may be wrong — say so explicitly. The cost of running a 5-line `bin/cr check` repro is always lower than the cost of a wrong report.

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
- **Benchmark before and after.**
- **Commit experiments before discarding.** Even rejected optimizations need a commit hash so results are reproducible. Use a branch or revert if needed — never throw away measured code.
- **Record results in `docs/perf/log.md`** with the commit hash of both baseline and optimization. Include raw benchmark output. Most recent entries first.
- **Include**: file sizes, times, throughput (MB/s), allocation (KB/parse), and speedup ratios.



## Lua Gotchas

**LuaJIT is Lua 5.1 + extensions.** Use `unpack(t)`, not `table.unpack(t)`. Do not shadow the built-in `assert` — in test files, bind the assertion library to a local (e.g. `local T = require("lib.test.assert")`).

**Table construction: all data fields go in the literal, methods go on a prototype.**

LuaJIT shapes tables at construction time. Fields present in the literal become part of the hidden class; adding fields afterward transitions to a new hidden class and breaks JIT monomorphic dispatch. The correct pattern:

```lua
-- data fields inline — JIT sees the full shape at construction
local obj = { insns = {}, args = {}, next_id = 0 }
-- methods on a shared prototype, not on the instance
setmetatable(obj, { __index = Proto })
```

All shape-defining fields belong in the literal. Post-construction field assignment (`obj.field = value` for initialization) defeats the hidden-class optimization and puts the field outside the typechecker's view.

**`local x = expr` — `x` is NOT in scope inside `expr`.**

In Lua, a local variable is not in scope within its own initializer expression. A closure created inside `expr` that references `x` will see a global (or nil), not the local being declared.

This matters whenever you want a callback/executor to reference the object being created:

```lua
-- WRONG: rt is a global lookup inside the executor (nil if no global)
local rt = N.runtime({ executors = { foo = function() rt:bar() end } })

-- CORRECT: pre-declare rt so the closure captures the local variable slot
local rt
rt = N.runtime({ executors = { foo = function() rt:bar() end } })
```

The same applies to test code that passes executors inline to a constructor. Always pre-declare the variable, then assign.

## Verify state before acting on assumptions

The filesystem is ground truth, not your memory of it or an agent's narrative
output. Before acting on "the agent must have…", "the file should still be…",
"this failure must be from my change…": run `git status`/`git log`/re-Read
the file/`git stash` and re-test. Cost of one check is always lower than the
wrong action plus cleanup.

## Pause before guessing

If you can't state in one sentence the property your answer must satisfy,
you're guessing. Say so and ask, don't answer. Writing another variation of
what you just said — another interpretation, another proposal, another
framing — is the loop signal. Applies to any response: code, prose, design
answers, conversation.

## Negative Constraints

Do not:
- Announce actions ("I will now...") - just do them
- Leave work uncommitted
- Use interactive git commands (`git add -p`, `git add -i`, `git rebase -i`) — these block on stdin and hang in non-interactive shells; stage files by name instead
- Use `--no-verify` - fix the issue or fix the hook
- Assume tools are missing - check if `nix develop` is available for the right environment
- Add dependencies that require a build step — pure Lua + FFI only
