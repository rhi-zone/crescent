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

## Development

```bash
bin/cr test                  # Run tests
bin/cr check <file>          # Typecheck a file
cd docs && bun dev           # Local docs (requires bun)
nix develop                  # Dev shell for contributors (bun, etc.)
```

## Core Rules

**Do the right thing, don't hedge.** When the correct approach is clear, implement it. Amount of work is never a reason to do something worse.

**No half-measures.** A design that requires X to be safe must ship with X. Implementing the unsafe version "for now" and deferring X is not a step toward the right design — it's a lie that accumulates. If X is hard, do X. If X is genuinely separable (the current code is correct without it, not just less capable), say so explicitly and put it in TODO.md. "We'll add it later" with no TODO entry means it never happens.

**"Out of scope" is not a reason to omit.** Scope is not a budget for correctness. If a security property, invariant, or design constraint applies to the thing being built, it is in scope by definition. Deferring it because it's inconvenient is not scoping — it's avoidance. The only legitimate reason to omit something is that it genuinely does not apply yet (no caller, no user, no data). That reason must survive scrutiny: if challenged, justify it, don't just re-assert it.

**Write things down immediately.** Problems and tech debt → TODO.md. Design decisions → docs/ or CLAUDE.md. Completed items → mark `[x]` in TODO.md in the same commit. Conversation evaporates — if it matters to a future session, write it now. Never delete unchecked TODO items.

**`docs/batteries.md` is the definitive ecosystem scope document.** Read it before discussing future libraries or roadmap.

**`docs/inventory_summary.md` is loaded at session start** — it lists what categories of library exist in crescent and roughly what's in each. Read it. **`docs/inventory.md` is the full per-library index** — grep it before designing or implementing anything reusable. If `inventory.md` doesn't list what you're looking for, spot-check `lib/` directly; the index can lag by a commit. **When adding a new library or `_types.lua` file, add a line to `docs/inventory.md` in the same commit. Add a line to `docs/inventory_summary.md` only if the new library belongs to a category not already there.**

**Corrections mean a rule is missing or wrong.** When the user corrects you, ask what rule would have prevented it and write it before proceeding. "The rule exists, I just didn't follow it" is never the diagnosis.

**Something unexpected is a signal, not noise.** Stop and ask why before continuing.

**Confident assertions require proof of work.** Assert confidently only after (1) adversarially reasoning through every plausible alternative and showing each is inferior, AND (2) verifying no downsides to the assertion. If either step is incomplete, say "I don't know" or state an explicitly-flagged hypothesis — then the immediate next step is to verify, not to hedge-word a guess into sounding like knowledge.

Context is poisoned the moment you confidently state something wrong. Retraction does not fully undo it; downstream reasoning is already shaped by the bad claim. Prevention is the only real mitigation — rules that fire after the assertion cannot recover it.

## Library Conventions

See `docs/conventions.md` for the full spec. Short version:
- Errors: `(nil, errmsg)` return, never throw from data errors
- Codecs: `string_to_foo`/`foo_to_string` as primary names (type-in-the-name); `encode`/`decode` always aliased for swappability
- Protocols: `connect` / `send` / `recv` / `close` — transport injected via opts, never created internally
- Tiers: system > FFI > pure Lua, selected at load time, each independent, `M._tier` for introspection
- Annotations: `--:` / `--::` only. `unknown` = TS `unknown` (caller must narrow). `any` = TS `any` (opt-out). Prefer `unknown`; `any` only when explicitly opting out and documented why.
- **`...` vs index signatures** — these are distinct. `...` is a structural subtyping marker: `{ name: string, ... }` accepts any table with at least `name`. It says nothing about reading arbitrary fields. `{ [string]: T }` is an index signature: any string key maps to `T`. Confusing them leads to open types on concrete data objects (wrong) or expecting arbitrary field reads to work on `...`-typed values (also wrong).

## Implementation Patterns

**When one implementation can't satisfy all legitimate use cases, provide multiple and let the caller choose.** This takes two forms:

- **Performance tiers** — same interface, different speed. E.g. FFI + system library > FFI scalar > pure Lua. Select the best available at load time via `pcall`. Never fail hard when a faster tier is unavailable — fall through to the next. Never silently use a slow tier without the faster ones being attempted first.
- **Interface variants** — same data, different access patterns. E.g. ergonomic (returns strings) vs zerocopy (returns positions). Provide both with clear names; the caller picks. Do not resolve the tradeoff by imposing one choice on all callers — that makes the wrong choice someone else's permanent problem.

In both cases: never wrap one implementation around another. Each is a real, independent implementation. Abstraction between tiers or variants destroys hackability.

**Multiple implementations of the same spec require parity tests, parity fuzzing, and benchmarks.** This applies any time two implementations claim to satisfy the same spec — performance tiers, a reference impl and an optimized one, a pure-Lua and an FFI version, a stub and the real thing. Parity tests assert byte-for-byte identical output. Parity fuzzing generates random inputs and runs all implementations, catching edge cases unit tests miss. Benchmarks measure each implementation on representative inputs and results are committed to `docs/perf/log.md`. None of this is optional polish — the implementation is not done until all three exist.

**Fix the specific problem, don't abandon the approach.** When an objection applies to one aspect of a design, fix that aspect. Platform-specific library names → try each known name. Library missing → fall back to next tier. These are implementation details, not architectural blockers. Discarding a whole approach because of a fixable problem is a cop-out.

**Derive from values, not from precedent.** When designing interfaces or making architecture decisions, start from crescent's values (vendorable, pure, fast, hackable, composable). Don't reach for what Java/Go/Rust/TypeScript does — their designs embed assumptions that don't apply here. Other ecosystems are references, not templates.

**Abstraction has a cost.** Wrappers, layers, and indirection reduce hackability and readability. Every abstraction needs justification beyond "it seems cleaner." A direct implementation that is longer is often better than an indirect one that is shorter.


**No gradual migrations.** When a design decision changes the convention (e.g. "libraries must not use `os`/`io` globals, accept injected functions instead"), apply it to the entire codebase in one pass. A half-migrated codebase is context poisoning: every future session encounters both the old and new pattern, wastes time figuring out which is canonical, and risks propagating the wrong one. If the migration is too large to do at once, that's a signal to reconsider the design, not to spread the migration across sessions.

**This applies to CLAUDE.md conventions too.** Partial adoption of a new local CLAUDE.md structure, a new naming rule, or any new convention is worse than not adopting it at all. An agentic AI encountering two conflicting conventions will confidently follow the wrong one. Do the whole thing or don't start.

**Capability-based I/O.** Libraries must not reach for `os`, `io`, or other global side-effect modules directly. Instead, accept I/O functions as parameters (constructor opts, function args). This is the foundation of sandbox safety: if a library grabs `os.time()` from a global, it can't run in a capability sandbox. If it accepts a `time_fn` parameter, the caller decides what time source to provide — or whether to provide one at all. This applies to ALL libraries, not just platform app code.

**Caps-first, everywhere.** Every library that performs I/O must accept its dependencies as injected caps, not import them from globals. "This runs outside the sandbox so it's fine" is never a justification for skipping injection. **Defaulting to globals is also a violation** — `opts.popen or io.popen` reaches for `io` just as directly as `io.popen` alone. If a cap is not injected, error; do not silently fall back to the global.

## Design Principles

**This repository is zero-dependency.** A user must be able to `git clone` and run immediately with no external installs — no package manager, no compiler, no runtime. LuaJIT binaries for all supported platforms are vendored in `bin/`. "Use Nix" or "install LuaJIT" are not acceptable answers. NixOS, musl, Alpine, and every other Linux variant are first-class targets — the vendored binaries must be statically linked so the ELF interpreter is not a constraint.

**Non-ubiquitous FFI dependencies must be vendored as compiled binaries in `dep/`.** `bin/cr test` must pass on a bare clone with no system libraries installed. If FFI code requires a library that isn't part of libc (sqlite3, etc.), compile it from its official source and commit the result to `dep/` for each supported platform — the sqlite3 amalgamation (`sqlite3.c`) is the model: one C file, compiles anywhere, no exotic deps. The nix dev shell (`buildInputs`) is for contributor tooling (bun, docs), not runtime dependencies — it is not a substitute for vendoring.

**Pure Lua is the baseline and must always work standalone.** No library may hard-depend on a system lib or vendored C lib being present. Ubiquitous system libs (libc, etc.) are an optional performance tier. Non-ubiquitous system libs require a pure Lua fallback. Vendored C libs are a last resort when pure Lua is genuinely nonviable for performance reasons. Nothing requires an external install step — must work on a barebones system.


**Target LuaJIT, don't require it.** Optimise for LuaJIT performance (avoid allocations in hot paths, prefer tables over closures, measure before and after) but pure Lua code must not depend on LuaJIT quirks — it should work on standard Lua if it doesn't sacrifice performance.

**Tooling performance bar: bun (general), tsgo for the typechecker.**


**Libraries must work on Linux, macOS, and Windows** unless they explicitly wrap a platform-specific API. Don't assume a single OS.

**Keep coupling low.** A change should require understanding only the local module to reason about correctly. If making a change requires understanding five other modules, that's an architectural smell. Low coupling also means local LLM context is sufficient — high coupling makes correct edits structurally impossible regardless of context window size.

**Never duplicate type definitions.** The typechecker reads FFI cdefs directly. Don't define types separately from cdefs.

## Workflow

**Run the typechecker on files you write or modify.** `bin/cr check <file>...` — do this before committing. See `lib/type/static/CLAUDE.md` for annotation syntax and type system rules.

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

**Default: delegate. Inline is the exception.** Before any multi-step task — reading multiple files, exploring a question, making changes across files — spawn a subagent. The subagent returns a distilled summary; raw tool output never lands in the main context. Do not inline work and then decide afterward whether it should have been delegated — the decision must happen *before* the first tool call.

Inline is only acceptable for:
- A single targeted file read (one file, one specific thing you already know is there)
- A single grep for a known symbol in a known file

**Edits: delegate implementation, inline surgical fixes.** Implementation work goes to a subagent — anything that needs reading surrounding code first, writing nontrivial new code, or is likely to iterate. The subagent's summary back is shorter than the raw tool output and exploration would be in main context. Surgical edits stay inline: a 1–5 line change in a location you already know, no exploration, no iteration expected.

The axis is steps + exploration + iteration risk, NOT lines changed. A 3-line edit that requires reading three files first is delegation work. A 50-line mechanical rename in a file you've already fully read is not.

Subagent cases (non-exhaustive):
- Any research or exploration question → subagent (Explore for codebase questions, general-purpose for multi-step tasks)
- Writing a new file or new function from scratch → subagent
- Adding a feature that needs reading other files to understand → subagent
- Mechanical work across many files → parallel subagents
- Any edit that's likely to iterate (typecheck might fail, tests might fail) → subagent

Inline cases:
- A single targeted file read (one file, one specific thing you already know is there)
- A single grep for a known symbol in a known file
- A surgical 1–5 line edit in a file you already understand, with no expected iteration
- Verifying output of a change with one command

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
- Use Claude Code's auto-memory system (`~/.claude/projects/.*./memory/`) — it is unversioned, invisible to the user, and can't be diffed or backed up. Write behavioral changes directly to CLAUDE.md instead
- Announce actions ("I will now...") - just do them
- Leave work uncommitted
- Use interactive git commands (`git add -p`, `git add -i`, `git rebase -i`) — these block on stdin and hang in non-interactive shells; stage files by name instead
- Use `--no-verify` - fix the issue or fix the hook
- Edit files inline because the change "seems small" or is "just one function" — size in lines is the wrong axis. If the edit needs exploration or might iterate, delegate.
- Assume tools are missing - check if `nix develop` is available for the right environment
- Add dependencies that require a build step — pure Lua + FFI only
