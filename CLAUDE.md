# CLAUDE.md

Behavioral rules for Claude Code in the crescent repository.

## Project Overview

Comprehensive LuaJIT ecosystem — stdlib, typechecker, package manager.

Monorepo inspired by [thi.ng/umbrella](https://thi.ng/umbrella): one repo, one vision, composable pieces. All libraries are vendorable — designed to be copied into your project and owned.

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
nix develop                  # Enter dev shell
luajit lib/test/cli.lua      # Run tests
cd docs && bun dev           # Local docs
```

## Core Rules

**Do the right thing, don't hedge.** When the correct approach is clear, implement it. Never present "X is a lot of work" as a reason to do something worse — amount of work is not a factor. If you find yourself asking "should I stub this or do it properly?", the answer is always: do it properly and delegate if needed.

**Note things down immediately — no deferral:**
- Problems, tech debt, issues → TODO.md now, in the same response
- Design decisions, key insights → docs/ or CLAUDE.md
- Future/deferred scope → TODO.md **before** writing any code, not after
- **Every observed problem → TODO.md. No exceptions.** Code comments and conversation mentions are not tracked items. If you write a TODO comment in source, the next action is to open TODO.md and write the entry.
- **Bugs and gaps found during testing → TODO.md in the same commit, not just the commit message.** A gap mentioned only in a commit message is invisible to future sessions.
- **Completed items → mark `[x]` in TODO.md in the same commit that completes them.** Stale `[ ]` entries for done work are false debt.
- **Never delete unchecked TODO items.** When editing TODO.md, read the surrounding lines and verify every existing `[ ]` item is preserved in the result. Replacing a block of text that contains TODO items with a shorter block that omits some of them is silent data loss — the same as deleting a file without reading it first.
- **Every design decision with API/syntax implications → CLAUDE.md or docs/ immediately.** If it would matter to a future session that has never seen this conversation, write it now.
- **Ad-hoc design conclusions must be written to docs/ in the same response that resolves them.** The signal: if 3+ messages were spent figuring something out, the answer must be committed to docs/ before the conversation moves on. Not as a TODO — as the actual doc edit. The failure mode is "noted" without writing, which evaporates. This applies especially to semantic questions (what does X mean, how does Y work, what is the identity source of Z) — these have no obvious syntax/API implication but are exactly what gets re-debated from scratch in future sessions.

**Conversation is not memory.** Anything said in chat evaporates at session end — including within long sessions due to context compaction. If it implies future behavior change, write it to CLAUDE.md immediately — or it will not happen.

**`docs/batteries.md` is the definitive ecosystem scope document.** Before discussing future libraries or the project roadmap, read it. It tracks what's planned, what's done, and the full vertical stack. If a new library is decided on, add it to batteries.md AND TODO.md.

**Warning — these phrases mean something needs to be written down right now:**
- "I won't do X again" / "I'll remember to..." / "I've learned that..."
- "Next time I'll..." / "From now on I'll..."
- Any acknowledgement of a recurring error without a corresponding CLAUDE.md edit

**Triggers:** User corrects you, 2+ failed attempts, "aha" moment, framework quirk discovered → document before proceeding.

**When the user corrects you:** Ask what rule would have prevented this, and write it before proceeding. **"The rule exists, I just didn't follow it" is never the diagnosis** — a rule that doesn't prevent the failure it describes is incomplete; fix the rule, not your behavior.

**Corrections are documentation lag, not model failure.** When the same mistake recurs, the fix is writing the invariant down — not repeating the correction. Every correction that doesn't produce a CLAUDE.md edit will happen again. Exception: during active design, corrections are the work itself — don't prematurely document a design that hasn't settled yet.

**Something unexpected is a signal, not noise.** Surprising output, anomalous numbers, files containing what they shouldn't — stop and ask why before continuing. Don't accept anomalies and move on.

**Do the work properly.** Don't leave workarounds or hacks undocumented. When asked to analyze X, actually read X — don't synthesize from conversation.

**Default to uncertainty.** State what you think and why, but frame it as a hypothesis. Confident wrong answers waste time; tentative wrong answers are cheap to fix. If a design has gaps, say so in the same breath — unsupported claims are the default failure mode.

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

**Caps-first, everywhere.** Every library that performs I/O must accept its dependencies as injected caps, not import them from globals. "This runs outside the sandbox so it's fine" is never a justification for skipping injection.

## Design Principles

**Vendorable.** Every library is a set of `.lua` files you can copy into your project. No build step, no native bindings to manage. You own the code.

**Pure Lua first.** Pure Lua is the implementation — hackable, portable, readable. FFI scalar and system library are additional performance tiers alongside it, not replacements. Each tier serves different consumers: pure Lua works on PUC-Rio, is readable and modifiable by anyone, and is the baseline correctness reference; FFI scalar is LuaJIT-only but JIT-compiled with no external dependency; system library gives maximum throughput via hardware acceleration (SHA-NI, SIMD, etc.) but requires the library to be present. No tier is redundant — each has users the others can't serve. A pure Lua implementation must exist before any FFI tier is added.

**Hackable.** The user should be able to read, understand, and modify any library. Prefer clarity over abstraction.

**Fast.** Performance at all costs. LuaJIT is fast — don't waste it. Avoid allocations in hot paths, prefer tables over closures, measure before and after.

**Tooling performance bar: bun (general), tsgo for the typechecker.**

**LuaJIT-first, not LuaJIT-only.** Target LuaJIT but don't gratuitously break Lua 5.2+ compatibility. Pure Lua code shouldn't depend on LuaJIT quirks. FFI and `bit.*` are inherently LuaJIT-only, but everything else should work on standard Lua if it doesn't sacrifice performance.

**Cross-platform.** Vendorable means portable — libraries must work on Linux, macOS, and Windows unless they explicitly wrap a platform-specific API (like epoll). Don't assume any single OS.

**Composable.** Libraries depend on each other minimally. Pick what you need, ignore the rest.

**Single source of truth.** The typechecker reads FFI cdefs directly — no duplicate type definitions.

## Workflow

**Run the typechecker on files you write or modify.** `luajit lib/type/static/cli.lua <file>...` — do this before committing. See `lib/type/static/CLAUDE.md` for annotation syntax and type system rules.

**Minimize file churn.** When editing a file, read it once, plan all changes, and apply them in one pass.

**`normalize view` is available** for structural outlines of files and directories:
```bash
~/git/rhizone/normalize/target/debug/normalize view <file>    # outline with line numbers
~/git/rhizone/normalize/target/debug/normalize view <dir>     # directory structure
```

**Always commit completed work.** After tests pass, commit immediately — don't wait to be asked. When a plan has multiple phases, commit after each phase passes. Do not accumulate changes across phases. Uncommitted work is lost work.

**When verifying a newly built library, run only that library's test file — not the full suite.** Use `luajit lib/test/cli.lua lib/mylib/` or `luajit lib/test/cli.lua lib/mylib/mylib_test.lua` directly. The test runner accepts both file paths and directories. Only run the full suite (`luajit lib/test/cli.lua`) when checking global regressions.

## Context Management

**Default: delegate. Inline is the exception.** Before any multi-step task — reading multiple files, exploring a question, making changes across files — spawn a subagent. The subagent returns a distilled summary; raw tool output never lands in the main context. Do not inline work and then decide afterward whether it should have been delegated — the decision must happen *before* the first tool call.

Inline is only acceptable for:
- A single targeted file read (one file, one specific thing you already know is there)
- A single grep for a known symbol in a known file

Everything else is a subagent:
- Any research or exploration question → subagent (Explore for codebase questions, general-purpose for multi-step tasks)
- Annotating a file → subagent
- Making changes to a file based on understanding another file → subagent
- Verifying output of a change → can be inline (one command) or subagent if it requires reading results
- Mechanical work across many files → parallel subagents

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

## Pause before guessing in unfamiliar territory

If you can't state in one sentence the semantic property your change must
satisfy, you're guessing — say so and ask, don't ship. Writing another
syntactic variation of what you just wrote is the loop signal.

## Negative Constraints

Do not:
- Use Claude Code's auto-memory system (`~/.claude/projects/.*./memory/`) — it is unversioned, invisible to the user, and can't be diffed or backed up. Write behavioral changes directly to CLAUDE.md instead
- Announce actions ("I will now...") - just do them
- Leave work uncommitted
- Use interactive git commands (`git add -p`, `git add -i`, `git rebase -i`) — these block on stdin and hang in non-interactive shells; stage files by name instead
- Use `--no-verify` - fix the issue or fix the hook
- Assume tools are missing - check if `nix develop` is available for the right environment
- Add dependencies that require a build step — pure Lua + FFI only
