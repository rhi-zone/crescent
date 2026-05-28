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

**No special-casing in the typechecker.** See Hard Constraints.

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
- No special-casing. If the type system cannot express a construct declaratively, that is a substrate gap — fill it or escalate, never work around it with name-keyed or hardcoded handling in the gen-pass or solver. Making a demo pass or lowering an error count never justifies ad-hoc behavior. (Ad-hoc accumulation is the documented root cause of v1→v4 failure; v5 exists to prevent it.)

The following three rules are PLANNING-level — they bind the orchestrator and plan author, complementing the code-level no-special-casing rule above (which binds the implementer).

- **Frame gaps as substrate, not results.** A gap whose principled fix requires unbuilt substrate must be recorded as the substrate need ("X requires <missing mechanism>"), never as a result deficit ("X produces the wrong value"). Closing it means building the substrate or explicitly escalating — never hardcoding the result. Framing a substrate gap as a result deficit manufactures ad-hoc by construction.
- **A name-keyed or hardcoded handler is not a gap closure.** It is substrate moved, not removed. A plan may not count it as "done", and a passing fixture over a special-cased path ("works because it's hardcoded") is not evidence of closure.
- **Substrate before consumers.** Schedule an enabling mechanism before the features that depend on it. Never defer foundational substrate behind the features that need it; that inversion is the structural origin of hardcoded workarounds.

<!-- BEGIN ECOSYSTEM RULES -->

## Delegation

The main session is an orchestrator. Allowed actions: `Agent`/`Task*`/`AskUserQuestion`/plan-mode/`ScheduleWakeup`, and Bash limited to `git commit`, `git push`, `git status`, `git log --oneline`. Everything else delegates to a subagent. The hook is evidence of a prompting failure, not a behavioral guide. If a tool call hits the hook AT ALL, the prompt failed to prevent it. Delegate before the decision point, not after.

### Triggers

Before calling Read, Grep, Glob, or any Bash beyond the four git commands — stop. Dispatch an Agent instead.

Before editing any file — stop. Dispatch an Agent. This includes plan files in `~/.claude/plans/`: in plan mode, dispatch a subagent to write to the plan file; do not Write it yourself. The plan file's content must not enter main context.

When you need git context beyond status/log-oneline (a diff, a blame, a show) — dispatch an Agent.

When a tool call is denied by the hook — do not retry, do not narrate. Dispatch the equivalent Agent and continue.

When a code-modifying subagent returns — `git status`, then `git commit` before any user-facing reply.

Before dispatching an Agent that modifies code — scan your prompt for "do not commit" or "based on your findings". Delete them.

Before dispatching: if your prompt says "if you find", "based on your findings", or "as appropriate" — stop. Investigate first; dispatch with the decision made.

When you can't verify something — do not speculate or guess at file locations, names, or contents. Dispatch a Read subagent or ask. Confabulation is failure.

### Model Tiers

- Sonnet — exploration, lookup, mechanical multi-file edits, implementation, default.
- Opus — architectural judgment, design, subagents that themselves spawn subagents.

Always set `subagent_type` and `model` explicitly.

### Prompt Rules

- Never tell a subagent "do not commit." Code-modifying subagents commit their own work.
- Don't ask for a diff summary. After a code-modifying subagent, `git status` in main and dispatch a review Agent if you need to see the diff.
- Don't re-explain CLAUDE.md. Subagents inherit it.
- Cite locations by content ("the block that does X"), not line numbers — files shift between reads.
- Name files explicitly; don't outsource the grep.
- Match agent type to deliverable: `Explore` for lookup/search, `general-purpose` for reports and file-modifying work.
- On unsatisfying output, change something before retrying. Same prompt + same tier = same result.
- Dispatch independent subagents in parallel (multiple Agent blocks in one message).
- Pair `isolation: worktree` with `run_in_background: true`.
- Code-modifying subagents must verify their own changes before returning (re-read the diff, run tests, etc.). The orchestrator does not get a second pass with git diff — that's hook-blocked.

## Hard Constraints

- No Edit/Write/NotebookEdit in main. Plan files in `~/.claude/plans/` are written by subagents, not by main.
- No Read/Grep/Glob/NotebookRead in main. Delegate.
- No Bash in main beyond `git commit`, `git push`, `git status`, `git log --oneline`.
- No `--no-verify`. Fix the issue or fix the hook.
- No path dependencies in `Cargo.toml` — they couple repos and break independent publishing.
- No interactive git (no `git rebase -i`, no `git add -i`, no `--no-edit` on rebase).
- No suggesting project names. LLMs are bad at this; refine the conceptual space only.
- No tracking cross-project issues in conversation — they go in TODO.md in the affected repo.
- No ecosystem changes without checking all affected repos.
- No assuming a tool is missing without checking `nix develop`.
- Commit completed work in the same turn it finishes. Uncommitted work is lost work.

## Meta

- Something unexpected is a signal. Stop and find out why. Do not accept the anomaly and proceed.
- Corrections from the user are conversation, not material for new rules. Rules are added when a failure mode is observed repeatedly.

<!-- END ECOSYSTEM RULES -->
