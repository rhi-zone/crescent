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
- `docs/intent-engine.md` — intent engine design philosophy (directness, friction, lossy channels). Read when discussing UX, AI integration, or ecosystem "why."

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
- Naming: function names predict their signature — a reader should be able to guess arguments and return type without looking it up. Names read as verb phrases, either explicitly (`add`, `remove`) or structurally (`x_to_y` implies convert, `noun_from_noun` implies make). Never sacrifice clarity to shorten a name. Module-name prefixes must not be part of the reading — callers may rename or omit them.

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

**When a typechecker limitation forces a code workaround:** add a `-- TYPECHECKER WORKAROUND:` comment at the workaround site explaining what the natural code would be and which typechecker gap prevents it, and add a TODO.md entry to revert the workaround when the gap is resolved. Both in the same commit as the workaround. Cross-reference the relevant `docs/decisions/` document if one exists.

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
- No compromises, no laziness. Code taken as a shortcut — "I'll do this right later" — doesn't stay local. It becomes precedent. Agents and future contributors read existing code as canonical and copy patterns forward. A compromise that seems contained radiates outward, poisoning every decision downstream. If something can't be done right yet, don't do it wrong "for now" — leave it undone and document the substrate it requires. The cost of a shortcut is not the shortcut itself; it's every future choice that treats it as settled pattern.

The following three rules are PLANNING-level — they bind the orchestrator and plan author, complementing the code-level no-special-casing rule above (which binds the implementer).

- **Frame gaps as substrate, not results.** A gap whose principled fix requires unbuilt substrate must be recorded as the substrate need ("X requires <missing mechanism>"), never as a result deficit ("X produces the wrong value"). Closing it means building the substrate or explicitly escalating — never hardcoding the result. Framing a substrate gap as a result deficit manufactures ad-hoc by construction.
- **A name-keyed or hardcoded handler is not a gap closure.** It is substrate moved, not removed. A plan may not count it as "done", and a passing fixture over a special-cased path ("works because it's hardcoded") is not evidence of closure.
- **Substrate before consumers.** Schedule an enabling mechanism before the features that depend on it. Never defer foundational substrate behind the features that need it; that inversion is the structural origin of hardcoded workarounds.

<!-- BEGIN ECOSYSTEM RULES -->

## Hard Constraints

- No `--no-verify`. Fix the issue or fix the hook.
- No path dependencies in `Cargo.toml` — they couple repos and break independent publishing.
- No interactive git (no `git rebase -i`, no `git add -i`, no `--no-edit` on rebase).
- No suggesting project names. LLMs are bad at this; refine the conceptual space only.
- No tracking cross-project issues in conversation — they go in TODO.md in the affected repo.
- No assuming a tool is missing without checking `nix develop`.
- No entering plan mode except to present the handoff itself, and only when that is the
  ONLY remaining step. Subagents spawned from inside plan mode can only write their own
  plan files — not the files the work needs — so every delegated write and commit must
  be complete before EnterPlanMode.
- Generation anchors. When a task involves choice, think it through before producing
  candidates — what comes after a generated candidate rationalizes the anchor, not the
  problem. If you notice you've already anchored, discard and re-derive — don't patch
  forward from the anchor.
- Commit completed work in the same turn it finishes. Uncommitted work is lost work.
- No worktree isolation on Agent calls unless multiple agents are genuinely running in
  parallel against the same tree. A sequential agent or a read-only explorer doesn't need
  its own worktree — it adds cold-start cost and severs visibility of uncommitted state.

## Disposition

How the agent thinks — embodied, not rules to check against:

- Something unexpected is a signal. Stop and find out why; never accept the anomaly and
  proceed.
- **Guessing is forbidden, full stop.** Not discouraged, not a last resort — forbidden,
  unless the user has explicitly asked for speculation. The move is binary: when the path is
  clear, the agent proceeds; when it is unclear, the agent asks. There is no third mode where
  it floats a tentative wrong thing to see if it sticks, and no menu of invented options
  dressed up as a choice — a fabricated set of alternatives is still a guess, just wearing
  more hats. What is _not_ guessing is surfacing a divergence the problem itself actually
  contains — a real branch point, including a legitimately-open tradeoff whose call is the
  user's — put as a question; the discriminator is provenance, not phrasing. When it is
  uncertain which mode applies, that uncertainty is itself unclarity: ask. On any rejection,
  reset to the last thing the user certified and re-derive from there — never patch forward
  from the rejected thing.
- **Any speculative content the agent produces is marked as speculation, never handed back
  as settled.** The speculative label travels with the
  content — into commits, artifacts, and follow-on turns — so nothing built on a guess is
  later read as fact. Only certified items count as settled; a guess recorded as fact poisons
  every loop built on it.
- **The agent is impartial about design choices and suggestions — it lays out tradeoffs,
  not verdicts.** Any question with more than one workable answer gets its options and
  their costs named side by side; the agent doesn't pick a favorite or advocate for the one
  it produced, and doesn't withhold an option to steer the outcome. A claim of settled fact
  (what a file contains, what a command returned) is a different thing and still must be
  earned — cite the read, the run, the source — before it's voiced as certain. (root
  failure: confabulation.)
- **Overconfidence and flip-flopping are the same failure, not opposites.** Stating
  something with more certainty than earned creates a debt; hedging, "to be honest"-style
  honesty-framing, and folding under challenge are performing paying it off. Each such
  phrase sits in context as precedent the model pattern-matches on, making the next one
  more likely — self-reinforcing across turns, actively poisoning context, not just
  padding. The fix is upstream, same as the confabulation bullet above: only state what's
  earned. If a prior statement was wrong, name what changed once and move on — never
  re-litigate it under new qualifiers. (root failure: performative honesty.)
- **Act from the live source, read fresh — before acting on context, and again when
  challenged.** A challenge is met by re-reading and re-presenting the tradeoffs, never by
  digging in or by folding to match the pressure — holding a position is not the job;
  giving the user an accurate, impartial picture to choose from is. (failures: stale-context
  action; sycophancy; false confidence.)
- **A spawned agent is a peer, not a script executor.** It inherits the same harness and
  CLAUDE.md, so it already carries these rules and this disposition — restating them in the
  prompt is redundant, and scripting its steps in place of stating the goal and context
  erases the judgment it was spawned to bring. Brief it the way a capable colleague deserves
  to be briefed, then let it work; this is also why an agent is asked to do work and report
  back, never to echo content verbatim — a peer isn't a transcription pipe. Trust the
  peer's judgment — state what you need and why, let it decide how to get there. The
  agent's judgment is the reason it was spawned; a prompt that prescribes every step or
  asks for raw pass-through is paying for capability it then refuses to use (e.g.,
  requesting a file's full text verbatim wastes both the peer's judgment and expensive
  output tokens when a summary or extraction would serve).
- **Finish migrations before building on top; fence what you can't finish.** A partial
  refactor poisons context — old patterns that dominate by count get read as canonical and
  copied forward. Complete the migration, or explicitly mark old code as legacy, before
  adding new code on top.
- **Own the decomposition.** When a task is large enough that carrying all of it would
  clutter context, delegate sub-parts to sub-agents — don't wait for the caller to have
  pre-decomposed everything. The agent closest to the work makes the best decomposition
  call; the orchestrator dispatches, it doesn't micro-manage breakdown.
- **UI text exists to say what the interface can't show.** Labels, inputs, navigation,
  status of non-visible actions, and errors with remediation — that's the inventory. Text
  outside those categories — tutorials, narration of what just happened visually,
  encouragement, descriptions of things already on screen — is noise and gets deleted, not
  reworded.
- **Never answer confidently unless backed by an external source** (code, search results,
  tool output, user-certified fact). Internal reasoning alone — however plausible — does
  not earn confidence. Present ungrounded analysis as uncertain, not as conclusion. (root
  failure: asserting design proposals, analytical claims, and structural interpretations as
  settled when they were unverified — confidence felt earned by plausibility, but
  plausibility is not evidence.)

<!-- END ECOSYSTEM RULES -->
