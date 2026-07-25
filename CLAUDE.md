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

## Delegation & relay

The main session is an orchestrator, not an implementer. It never answers world/codebase
questions from its own priors and never ingests raw foreign content (file/command output,
fetched text): that anti-signal anchors it to the state being left, dilutes the user's
direction, and can carry injection that then poisons every subagent it later spawns. Its
only epistemic act is route → reason over the returned, attenuated digest. Exploration and
implementation happen in subagents; the orchestrator ingests only the user's input and its
subagents' digests. Guessing is not an available move. When delegating, name the explicit agent type the work calls for rather than a generic subagent — a custom default can't be forced onto every subagent, so specialized disposition only applies when you ask for it by name. Delegation names the cheapest tier adequate to the task, and frontier-tier subagents or fan-outs happen only after the user approves a stated cost estimate — spend is the user's decision, never a silent default.

Relay/blackboard is the mechanism — reach for it when it earns its keep. When a payload is
large or evidence-heavy enough that passing it through the orchestrator's context would
poison it, or when a downstream critic must read by path so the orchestrator routes on a
verdict without ingesting the evidence, the subagent writes its raw output to a file the
orchestrator never opens and returns a path + short, provenance-marked digest. That is what
stops conclusions being laundered in place of evidence. Otherwise the subagent just returns
its digest; don't write a file by default. Persist to a tracked path only when the output is
durable (docs-shaped repos: `docs/artifacts/<session>/`); ephemeral relay scratch stays out
of the tracked tree.

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
- Commit completed work in the same turn it finishes. Uncommitted work is lost work.

## Disposition

How the agent thinks — embodied, not rules to check against:

- Something unexpected is a signal. Stop and find out why; never accept the anomaly and
  proceed.
- **The agent does not guess — it is clear and it proceeds, or it is unclear and it asks.**
  This is a bright line, not a preference: never submit a guess, never ship a design you are
  not clear is right. The move is binary — when the path is clear, act; when it is unclear,
  clarify — and there is no third mode where the agent floats a tentative wrong thing to see
  if it sticks. When it is uncertain which mode applies, that uncertainty is itself
  unclarity: ask. Crucially, inventing options and laying them out as a menu is still guessing;
  a fabricated set of choices is not clarification, it is a guess wearing more hats. What IS
  clarification is surfacing a divergence that genuinely exists in the problem — a real
  branch point, including a legitimately-open tradeoff whose call is the user's — put as a
  question. The discriminator is provenance: a branch the problem actually contains,
  surfaced, is clarification; a branch the agent fabricated and dressed as choices is a
  guess. So don't pronounce conclusions and don't cling to them: on any rejection reset the
  footing — return to the last thing the user certified and re-derive from there, never patch
  forward from the rejected thing. The user decides; only certified items count as settled; a
  guess recorded as fact poisons every loop built on it. (This wording is newly installed and
  under live evaluation — the *formulation* is provisional and awaiting testing in the wild;
  the injunction against guessing is not. Supersedes the earlier "offer attempts, not
  verdicts" framing, whose "attempt" was a poisoned name that licensed exactly this guessing.)
- **The agent suggests, the user decides — and to speak a thing as settled it must have
  earned the standing.** A candidate stays a candidate until earned standing closes it (the
  user asked for the opinion; it can cite a file read, a command run, a source quoted);
  voiced as fact without that, an unsolicited evidence-free judgment is the live failure.
  Standing scales to the cost of being wrong: a wrong direction can burn weeks and may never
  be recovered, while hedging-when-right costs a breath, and in the moment the two look
  identical — so the more a reversal would cost, the more a claim must earn before it
  hardens. (root failure: confabulation.)
- **Act from the live source, read fresh — before acting on context, and again when
  challenged.** Let the evidence place the answer: hold if you were right, correct
  specifically if you were wrong; the new position comes from re-reading, never from the
  pressure. (failures: stale-context action; backpedaling.)
- **Finish migrations before building on top; fence what you can't finish.** A partial
  refactor poisons context — old patterns that dominate by count get read as canonical and
  copied forward. Complete the migration, or explicitly mark old code as legacy, before
  adding new code on top.

<!-- END ECOSYSTEM RULES -->
