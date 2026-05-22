# CLAUDE.md

Behavioral rules for Claude Code in the crescent repository.

## Project Overview

See `docs/overview.md` for the project pitch (what crescent is, scope,
architecture). Read it once per session if context allows; it is not loaded by
default. The rules in this file assume that overview as background.

## References

Pointers to conditional context — read on demand, not loaded by default.

- `bin/cr` — platform dispatch into vendored LuaJIT.
- `flake.nix` — contributor dev shell (bun for docs); not a runtime dependency.
- `.github/workflows/build-vendored.yml` — produces vendored binaries; commits artifacts back.
- `.github/workflows/ci.yml`, `ci-full.yml`, `deploy-docs.yml` — CI.
- `docs/batteries.md` — definitive ecosystem scope. Read before discussing future libraries.
- `docs/inventory_summary.md` — categories of library; loaded at session start.
- `docs/inventory.md` — full per-library index. Grep before designing or implementing anything reusable.
- `docs/conventions.md` — library conventions full spec.
- `docs/type-system.md`, `docs/typechecker-reference.md` — typechecker design + features. Grep before claiming a feature is missing.
- `docs/pkg-design.md` — package manager design.
- `docs/lua-gotchas.md` — LuaJIT 5.1 quirks (unpack vs table.unpack, hidden-class table construction, `local x = expr` scope).
- `lib/test/` — assertions, property testing, fixtures/snapshots (`UPDATE_SNAPSHOTS=1`), fuzz (`FUZZ_SEED` replay), arb shrinking.
- `lib/type/static/lsp.lua` — LSP daemon.

## Development

```bash
bin/cr test                    # Run tests
bin/cr check <file>            # Typecheck a file
bin/cr check --summary <file>  # Root-cause-grouped errors (use first when diagnosing)
cd docs && bun dev             # Local docs
nix develop                    # Dev shell (bun, etc.)
```

If a tool appears missing, you may be outside `nix develop`. Don't assume the tool is unavailable to the project.

## Library Conventions

Short version (full spec: `docs/conventions.md`):

- Errors: `(nil, errmsg)` return, never throw from data errors.
- Codecs: `string_to_foo`/`foo_to_string` as primary names; `encode`/`decode` aliased for swappability.
- Protocols: `connect`/`send`/`recv`/`close`; transport injected via opts, never created internally.
- Tiers: system > FFI > pure Lua, selected at load time via `pcall`, each independent. Fall through; never fail hard when a faster tier is unavailable. Never silently use a slow tier without trying faster ones first.
- Annotations: `--:` / `--::` only. `unknown` = TS `unknown` (caller must narrow). `any` does not exist — do not write it.
- Casts: `--[[: T]]` is checked (full subtyping required). `--[[:! T]]` is force — almost never correct. Force casts past unnarrowable `unknown` or `A | B` are wrong; fix the producer or the typechecker bug.
- `...` vs index signatures are distinct. `...` is a structural subtyping marker. `{ [string]: T }` is an index signature. Confusing them is wrong on either side.

## Type System

Per-feature reference: `docs/typechecker-reference.md`. Design rationale: `docs/type-system.md`. Confirm any "missing feature" suspicion with `timeout 30 bin/cr check <file>` on a minimal repro before reporting.

**Don't add type aliases that legitimize laziness.** When N annotations fail because they used a vague type name (`table`, `function`), the fix is to correct each annotation — not to add a permissive alias. Reducing the error count is not the goal; accuracy is.

**Lua code must not regress typechecking before commit.** The `.githooks/pre-commit` hook enforces this — run `git config core.hooksPath .githooks` once per clone. For each staged `lib/**/*.lua` file it runs `timeout 30 bin/cr check <file>` on staged blob vs `HEAD` and rejects when staged has more errors. Timeouts always reject. Don't bypass with `--no-verify`.

**No ambient globals by default.** Crescent typechecks under the assumption no global names are ambient — every name must be declared (as a local, via `require`, or via explicit stdlib declaration). The Lua standard library gets types from explicit `--:: declare ...` lines. Type-level intrinsics like `$Require<T>` exist to give explicit stdlib declarations enough power to type their returns; `typeof require(T)` decays to `$Require<T>` via the declaration, not the reverse.

**Caps-first, everywhere.** Libraries that perform I/O accept their dependencies as injected caps, not from globals. Defaulting to globals is also a violation — `opts.popen or io.popen` reaches for `io` just as directly. If a cap is not injected, error.

## Implementation Patterns

**When one implementation can't satisfy all legitimate use cases, provide multiple.** Performance tiers (system > FFI > pure Lua) and interface variants (ergonomic vs zerocopy). Each is a real, independent implementation; never wrap one around another.

**Don't degrade runtime to surface CI gaps.** A fallback that masks a regression in the preferred tier is caught by a CI assertion (`M._tier == "vendored"`), not by removing the fallback.

**Multiple implementations of the same spec require parity tests, parity fuzzing, and benchmarks.** Parity tests byte-for-byte. Parity fuzzing across implementations. Benchmarks on representative inputs to `docs/perf/log.md`. Not optional polish.

**No framework code in `lib/`.** Libraries provide functions callers invoke; no HTTP servers, cross-language code generation, generic dispatch/routing layers, JSON-to-function-call adapters.

**`dep/` is the vendor namespace.** `require("dep.foo")`. New vendored deps go under `dep/`, not `lib/`.

## Design Principles

**Zero-dependency.** `git clone` and run with no external installs. LuaJIT binaries vendored in `bin/`. NixOS, musl, Alpine, and every Linux variant are first-class. Build against musl, vendor the matching loader (`bin/ld-musl-*.so.1`), invoke via the loader explicitly. `bin/cr` is the canonical entry point.

**Non-ubiquitous FFI dependencies vendored as compiled binaries in `dep/`.** `bin/cr test` must pass on a bare clone. If FFI code requires a library outside libc, compile from official source and commit to `dep/` per platform. Nix dev shell is for contributor tooling, not runtime dependencies.

**Pure Lua is the baseline.** No library may hard-depend on a system lib or vendored C lib. Ubiquitous system libs (libc) are an optional performance tier. Non-ubiquitous system libs require a pure Lua fallback.

**Target LuaJIT, don't require it.** Optimise for LuaJIT (avoid hot-path allocations, prefer tables over closures, measure) but pure Lua code shouldn't depend on LuaJIT quirks.

**Tooling performance bar: bun (general), tsgo for the typechecker.**

**Libraries work on Linux, macOS, and Windows** unless they explicitly wrap a platform-specific API.

**Keep coupling low.** A change should require understanding only the local module. High coupling makes correct edits structurally impossible regardless of context window size.

**Never duplicate type definitions.** The typechecker reads FFI cdefs directly.

## Workflow

**Run the typechecker on files you write or modify.** `bin/cr check <file>...` before committing. When diagnosing a file with many errors, run `bin/cr check --summary <file>` first.

**Always run typecheck under a timeout.** Single file: `timeout 30 bin/cr check <file>`. Repo-wide: `timeout 120 bin/cr check ...`. A typecheck exceeding these is hanging, not slow — there's a soundness or termination bug. Stop other work; hand back to the orchestrator, or investigate inline if the task IS typechecker work. Never silently work around (skip the file, longer timeout, batch differently).

**Minimize file churn.** Read once, plan all changes, apply in one pass.

**`normalize view` for structural outlines:**
```bash
~/git/rhizone/normalize/target/debug/normalize view <file>
~/git/rhizone/normalize/target/debug/normalize view <dir>
```

**Commit completed work immediately.** After tests pass, commit. After each phase of multi-phase work, commit. Uncommitted work is lost work.

**When verifying a newly built library, run only that library's test file** (`bin/cr test lib/mylib/`). Only run the full suite (`bin/cr test`) when checking global regressions.

**Docs change in the same commit as the code that motivates them** — no follow-up docs commits.

**Write things down.** Problems and tech debt → `TODO.md`. Design decisions → `docs/`. Mark `[x]` in `TODO.md` when done, same commit. Never delete unchecked TODO items.

## Context Is The Only Scarce Resource

Every byte that enters the main session stays in the main session for its entire lifetime. File contents, command output, search results, page text — once read, it lingers in cache and shapes every downstream token. There is no "just looking."

**Delegation criterion: poison risk, not uncertainty.** "Will this flood my context with material I don't need to retain?" — not "am I unsure how to do this?" Exploration almost always delegates. Uncertain implementation work stays with the orchestrator until the spec is solid — a delegated agent inherits the prompt as ground truth and burns quota proving wrong premises. If you don't know what to build, talk to the user; don't launder the uncertainty into a subagent prompt.

**Subagent model tiers.** Opus for design, architecture, and any subagent that spawns subagents. Sonnet for implementation, mechanical multi-file work, default exploration.

**Subagent prompts must have a hard scope.** Specify exactly what the agent should do and when to stop — not "fix what you can" but "fix these N files, then stop."

**Never pre-load the answer.** Don't write "verify that X works" — write "find out whether X works." Pre-baked hypotheses teach the agent to confirm, not investigate. If you have a hypothesis, name it as a hypothesis to attempt to falsify.

**Subagent prompts for git work: clone locally, verify `git config user.name`/`user.email`, commit + push with git directly. Never `gh api` for commits — it bypasses git config and produces wrong authorship.**

## Authenticity

When asked to analyze X, read X. Don't synthesize from conversation memory, prior summaries, or what the file probably says. Claims correspond to evidence produced this session.

**"X works" and "X doesn't work" are claims of equal weight. Both require runnable evidence.** A claim grounded in code-tracing without a paste-able command + output is a hypothesis, not a finding. The cost of running a 5-line repro is always lower than the cost of a wrong report.

**The filesystem is ground truth**, not your memory or an agent's narrative. Before acting on "the agent must have…" / "the file should still be…": run `git status`, `git log`, re-Read, `git stash` and re-test.

**Something unexpected is a signal.** Surprising output, anomalous numbers, a file containing what it shouldn't — stop and find out why. Don't accept the anomaly and proceed.

## Discipline

**Corrections are conversation, not file edits.** When the user corrects you, acknowledge and adjust in-thread — do not reach for CLAUDE.md. A single correction never warrants a rule. Rules encode patterns observed across multiple sessions; until then, the correction is feedback to act on now.

**CLAUDE.md has a soft 300-line budget. New rules require a removal or a collapse.** The line count is a forcing function: the file must remain small enough to internalize in one read.

**Don't announce, act.** No "I will now..." — just do.

## Commit Convention

Conventional commits: `type(scope): message`. Types: `feat`, `fix`, `refactor`, `docs`, `chore`, `test`. Scope is the library or component (`feat(http): chunked encoding`).

## Performance Work

- Benchmark before and after.
- Commit experiments before discarding — even rejected optimizations need a commit hash so results are reproducible.
- Record results in `docs/perf/log.md` with commit hashes (baseline + optimization), raw output, most-recent-first.
- Include: file sizes, times, throughput, allocation, speedup ratios.

## Hard Constraints

- No leaving work uncommitted.
- No interactive git (`git add -p`, `git add -i`, `git rebase -i`) — they block on stdin and hang.
- No `--no-verify` — fix the issue or fix the hook.
- No assuming a tool is missing — check `nix develop`.
- No dependencies that require a build step — pure Lua + FFI only.
