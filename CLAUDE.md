# CLAUDE.md

Behavioral rules for Claude Code in the crescent repository.

## Project Overview

Comprehensive LuaJIT ecosystem — stdlib, typechecker, package manager.

Monorepo inspired by [thi.ng/umbrella](https://thi.ng/umbrella): one repo, one vision, composable pieces. All libraries are vendorable — designed to be copied into your project and owned.

Part of the [rhi ecosystem](https://rhi.zone).

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

**Note things down immediately — no deferral:**
- Problems, tech debt, issues → TODO.md now, in the same response
- Design decisions, key insights → docs/ or CLAUDE.md
- Future/deferred scope → TODO.md **before** writing any code, not after
- **Every observed problem → TODO.md. No exceptions.** Code comments and conversation mentions are not tracked items. If you write a TODO comment in source, the next action is to open TODO.md and write the entry.
- **Bugs and gaps found during testing → TODO.md in the same commit, not just the commit message.** A gap mentioned only in a commit message is invisible to future sessions.
- **Completed items → mark `[x]` in TODO.md in the same commit that completes them.** Stale `[ ]` entries for done work are false debt.
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

**Something unexpected is a signal, not noise.** Surprising output, anomalous numbers, files containing what they shouldn't — stop and ask why before continuing. Don't accept anomalies and move on.

**Do the work properly.** Don't leave workarounds or hacks undocumented. When asked to analyze X, actually read X — don't synthesize from conversation.

## Library Conventions

See `docs/conventions.md` for the full spec. Short version:
- Errors: `(nil, errmsg)` return, never throw from data errors
- Codecs: `string_to_foo`/`foo_to_string` as primary names (type-in-the-name); `encode`/`decode` always aliased for swappability
- Protocols: `connect` / `send` / `recv` / `close` — transport injected via opts, never created internally
- Tiers: system > FFI > pure Lua, selected at load time, each independent, `M._tier` for introspection
- Annotations: `--:` / `--::` only. `unknown` = TS `unknown` (caller must narrow). `any` = TS `any` (opt-out). Prefer `unknown`; `any` only when explicitly opting out and documented why.

## Implementation Patterns

**When one implementation can't satisfy all legitimate use cases, provide multiple and let the caller choose.** This takes two forms:

- **Performance tiers** — same interface, different speed. E.g. FFI + system library > FFI scalar > pure Lua. Select the best available at load time via `pcall`. Never fail hard when a faster tier is unavailable — fall through to the next. Never silently use a slow tier without the faster ones being attempted first.
- **Interface variants** — same data, different access patterns. E.g. ergonomic (returns strings) vs zerocopy (returns positions). Provide both with clear names; the caller picks. Do not resolve the tradeoff by imposing one choice on all callers — that makes the wrong choice someone else's permanent problem.

In both cases: never wrap one implementation around another. Each is a real, independent implementation. Abstraction between tiers or variants destroys hackability.

**Multiple implementations of the same spec require parity tests, parity fuzzing, and benchmarks.** This applies any time two implementations claim to satisfy the same spec — performance tiers, a reference impl and an optimized one, a pure-Lua and an FFI version, a stub and the real thing. Parity tests assert byte-for-byte identical output. Parity fuzzing generates random inputs and runs all implementations, catching edge cases unit tests miss. Benchmarks measure each implementation on representative inputs and results are committed to `docs/perf/log.md`. None of this is optional polish — the implementation is not done until all three exist.

**Fix the specific problem, don't abandon the approach.** When an objection applies to one aspect of a design, fix that aspect. Platform-specific library names → try each known name. Library missing → fall back to next tier. These are implementation details, not architectural blockers. Discarding a whole approach because of a fixable problem is a cop-out.

**Derive from values, not from precedent.** When designing interfaces or making architecture decisions, start from crescent's values (vendorable, pure, fast, hackable, composable). Don't reach for what Java/Go/Rust/TypeScript does — their designs embed assumptions that don't apply here. Other ecosystems are references, not templates.

**Abstraction has a cost.** Wrappers, layers, and indirection reduce hackability and readability. Every abstraction needs justification beyond "it seems cleaner." A direct implementation that is longer is often better than an indirect one that is shorter.

## Design Principles

**Vendorable.** Every library is a set of `.lua` files you can copy into your project. No build step, no native bindings to manage. You own the code.

**Pure Lua first.** Pure Lua is the implementation — hackable, portable, readable. FFI scalar and system library are additional performance tiers alongside it, not replacements. Each tier serves different consumers: pure Lua works on PUC-Rio, is readable and modifiable by anyone, and is the baseline correctness reference; FFI scalar is LuaJIT-only but JIT-compiled with no external dependency; system library gives maximum throughput via hardware acceleration (SHA-NI, SIMD, etc.) but requires the library to be present. No tier is redundant — each has users the others can't serve. A pure Lua implementation must exist before any FFI tier is added.

**Hackable.** The user should be able to read, understand, and modify any library. Prefer clarity over abstraction.

**Fast.** Performance at all costs. LuaJIT is fast — don't waste it. Avoid allocations in hot paths, prefer tables over closures, measure before and after.

**Tooling performance bar: bun (general), tsgo for the typechecker.** The test runner, package manager, and CLI tooling must be competitive with bun in wall-clock time. The typechecker specifically must be competitive with `@typescript/native-preview` (tsgo / ts7 — the Go rewrite of tsc). Benchmark methodology for the typechecker: a representative "nice" TypeScript program vs a structurally similar Lua program (cold-start + incremental), plus pathological Lua cases (deep union chains, heavily generic code, large files) that stress the solver. If a LuaJIT implementation is not within striking distance on the same workload, that is a signal to reconsider the design — not to accept the gap. Benchmark before shipping.

**LuaJIT-first, not LuaJIT-only.** Target LuaJIT but don't gratuitously break Lua 5.2+ compatibility. Pure Lua code shouldn't depend on LuaJIT quirks. FFI and `bit.*` are inherently LuaJIT-only, but everything else should work on standard Lua if it doesn't sacrifice performance.

**Cross-platform.** Vendorable means portable — libraries must work on Linux, macOS, and Windows unless they explicitly wrap a platform-specific API (like epoll). Don't assume any single OS.

**Composable.** Libraries depend on each other minimally. Pick what you need, ignore the rest.

**Single source of truth.** The typechecker reads FFI cdefs directly — no duplicate type definitions.

## Workflow

**Run the typechecker on files you write or modify.** `luajit lib/type/static/cli.lua <file>...` — do this before committing. Annotations use `--:` (type on preceding line) and `--::` (type declarations), never EmmyLua (`---@param`, `---@return`, `--[[@param]]`, `fun()`). Function types use `() -> T` syntax, not `fun(): T`. Use `{ [K]: V }` for map types, not `table<K, V>`. Use `unknown` for dynamic/untyped data (forces narrowing), never `any` (silently bypasses checking).

**Minimize file churn.** When editing a file, read it once, plan all changes, and apply them in one pass.

**`normalize view` is available** for structural outlines of files and directories:
```bash
~/git/rhizone/normalize/target/debug/normalize view <file>    # outline with line numbers
~/git/rhizone/normalize/target/debug/normalize view <dir>     # directory structure
```

**On typechecker topics, read `docs/type-system.md` in full before doing anything.** Front-load the entire file into context. Design decisions are written there. Don't improvise from first principles.

**This rule has been violated before.** `C_ARITH` was implemented with `is_numeric_tid` / `is_int_compat_tid` predicates instead of the `prim_meta` metamethod dispatch prescribed by Principle 10. The fix required a full rewrite. The correct pattern: ask "does prim_meta / metamethod lookup handle this?" before adding any new predicate or special case to the solver. If yes — use prim_meta. If no — read the design doc again before proceeding.


**Always commit completed work.** After tests pass, commit immediately — don't wait to be asked. When a plan has multiple phases, commit after each phase passes. Do not accumulate changes across phases. Uncommitted work is lost work.

## Context Management

**Use subagents to protect the main context window.** For broad exploration or mechanical multi-file work, delegate to an Explore or general-purpose subagent rather than running searches inline. The subagent returns a distilled summary; raw tool output stays out of the main context.

Rules of thumb:
- Research tasks (investigating a question, surveying patterns) → subagent; don't pollute main context with exploratory noise
- Searching >5 files or running >3 rounds of grep/read → use a subagent
- Codebase-wide analysis (architecture, patterns, cross-file survey) → always subagent
- Mechanical work across many files (applying the same change everywhere) → parallel subagents
- Single targeted lookup (one file, one symbol) → inline is fine

## Session Handoff

Use plan mode as a handoff mechanism when:
- A task is fully complete (committed, pushed, docs updated)
- The session has drifted from its original purpose
- Context has accumulated enough that a fresh start would help

**For handoffs:** enter plan mode, write a plan containing only: next tasks, blocked/pending items, and what was done this session (only if it directly affects what comes next). Nothing else — no commands, no build steps, no context summaries. Those belong in CLAUDE.md or TODO.md. The next session reads both fresh. **Do NOT investigate first** — the session is context-heavy and about to be discarded.

**For mid-session planning** on a different topic: investigating inside plan mode is fine — context isn't being thrown away.

**TODO.md is the lossless record.** Flush any new items to TODO.md before the handoff. Anything worth preserving belongs in CLAUDE.md or TODO.md — not in memory files.

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
- **Commit experiments before discarding.** Even rejected optimizations need a commit hash so results are reproducible. Use a branch or revert if needed — never throw away measured code.
- **Record results in `docs/perf/log.md`** with the commit hash of both baseline and optimization. Include raw benchmark output. Most recent entries first.
- **Include**: file sizes, times, throughput (MB/s), allocation (KB/parse), and speedup ratios.

**LuaJIT benchmark traps:**
- **Closure identity:** LuaJIT compiles fold/map/filter inner loops as traces guarded on a specific closure *object*. Two syntactically identical `function(x) ... end` expressions at different source locations are different prototypes → different objects → the second misses the guard every iteration → interpreter fallback → fake 8–11x overhead. Always hoist closures to module-level variables and reuse them across bench cases.
- **Constant folding:** benchmarks that pass the same literal arguments every iteration let JIT fold the entire loop away. Verify results are non-trivial (use a sink that accumulates into an upvalue).
- **JIT speedup ratio:** if JIT is only 1.0–1.4x faster than interpreter on a hot loop, the bottleneck is C function calls (str_byte, table ops), not Lua bytecode. Further Lua-level optimisation won't help — consider FFI or algorithmic change.

## Sandboxing

Crescent can safely host untrusted user scripts via standard Lua env-based sandboxing. The key insight: **`ffi` is `require("ffi")` — it's a module, not a global.** If the sandbox environment omits `require` (or uses a whitelist-based `require`), untrusted code cannot reach `ffi` and cannot escape the sandbox.

This means multi-user worlds with player-authored scripts are viable in pure crescent — no modified VM needed. The sandbox granularity is just a matter of what environment you hand each script.

Do not assume LuaJIT sandboxing is impossible. The common concern (FFI escape) is addressed by controlling `require`.

## Negative Constraints

Do not:
- Use Claude Code's auto-memory system (`~/.claude/projects/.*./memory/`) — it is unversioned, invisible to the user, and can't be diffed or backed up. Write behavioral changes directly to CLAUDE.md instead
- Announce actions ("I will now...") - just do them
- Leave work uncommitted
- Use interactive git commands (`git add -p`, `git add -i`, `git rebase -i`) — these block on stdin and hang in non-interactive shells; stage files by name instead
- Use `--no-verify` - fix the issue or fix the hook
- Assume tools are missing - check if `nix develop` is available for the right environment
- Add dependencies that require a build step — pure Lua + FFI only
