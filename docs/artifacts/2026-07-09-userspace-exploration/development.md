# Crescent as the entire computer: development tools

Facet: editors/IDEs, debugging, VCS, deployment, CI/CD, REPLs, docs, API
exploration, DB tools, profiling, linting, formatting, refactoring, codegen,
language servers, build systems, dep management, containerization, dev envs.

## 1. What people actually do

- Jump to definition, find references, rename symbol across a project.
- Set a breakpoint, step over/into, inspect a variable, watch an expression,
  evaluate in the paused frame.
- `git blame` a confusing line, then `git log -p` that line's history, then
  `git bisect` to find which commit broke it.
- Run the test suite, see red/green, jump from a failure straight to the
  assertion line.
- Open a REPL, poke at a live value, promote the working snippet into a file.
- Read a stack trace, click through frames, inspect locals at each frame.
- `curl` an API to see what it actually returns before writing the client.
- Open a DB shell, run a query, eyeball the result, tweak, rerun.
- Profile a slow path with a flamegraph, find the hot function.
- Lint on save, auto-format on save, never think about style again.
- Extract a function, inline a variable, rename-and-propagate.
- `docker run` something to avoid installing it on the host.
- `nix develop` / `direnv allow` and the right toolchain just appears.
- Deploy: push to a branch, watch CI, watch the deploy, watch the rollback
  button exist just in case.
- Generate code from a schema (protobuf, OpenAPI) instead of hand-writing
  bindings.

## 2. Prior art worth stealing from

- **Smalltalk browser / Lisp machines** — the environment IS the program.
  No edit-compile-run cycle; you're always inside a live image, inspecting
  and mutating running objects. Debugger-as-REPL: an error drops you into a
  live context, you fix the function, execution resumes.
- **Acme (Plan 9) / sam** — the whole screen is a namespace of text; any
  visible text is executable (chord-click to run it as a command, or to
  look it up). No modes, no plugin ecosystem — the OS shell IS the editor's
  extension language.
- **Kakoune / Helix** — selection-first ("verb-noun" inverted to
  "noun-verb": select the object, then act on it), structural regex,
  everything composable via pipes to external processes.
- **tree-sitter** — incremental, error-tolerant parsing that stays valid
  keystroke-by-keystroke, shared by editor, highlighter, and structural
  navigation. One grammar, many consumers.
- **Language Server Protocol / Debug Adapter Protocol** — decoupled the
  N editors × M languages problem into N+M implementations. The protocol
  is the reusable asset, not any one client.
- **nREPL / SLIME / Jupyter** — a REPL as a *server*, addressable by any
  client (editor plugin, notebook, terminal) over a wire protocol, so the
  live process outlives and out-scopes any single UI.
- **Observable notebooks** — reactive cells: every cell is a pure function
  of its dependencies, editing one re-runs its downstream automatically.
  Closer to a spreadsheet than a script.
- **SQLite CLI / pgAdmin** — the DB tool doubles as a REPL over structured
  data; `.schema`, `.tables`, tab completion on column names.
- **Chrome DevTools** — inspector, profiler, network tab, console, all
  talking to the *same live runtime* over one protocol (CDP). Also proof
  that "debug tools live in the browser, for free, for everyone" works.
- **Nix / direnv** — the dev environment as a reproducible, declarative,
  hash-addressed artifact instead of "run this setup script and hope."

## 3. What crescent already covers

Crescent is unusually far along here already — this facet overlaps its own
substrate more than most:

- `lib/type/static/` — a real structural typechecker (v5) with narrowing,
  generics, unions, a CLI (`bin/cr check`), and an LSP daemon
  (`lib/type/static/lsp.lua`) already speaking a standard protocol.
- `lib/test/` — runner, assertions, coverage, fixtures/snapshots
  (`UPDATE_SNAPSHOTS=1`), fast + guided fuzzing, property testing, arb with
  integrated shrinking. This is a mature test harness, not a toy.
- `lib/bench/` — micro-benchmarks, feeding `docs/perf/log.md`.
- `lib/diff/`, `lib/text_diff/`, `lib/merge3/` — the primitives behind
  `git diff` / three-way merge, already in pure Lua.
- `lib/tracing/` (OTel-shaped) and `lib/metric/` (Prometheus-shaped) —
  observability primitives a profiler or APM tool would sit on top of.
- `lib/hex_dump/`, `lib/pretty_print/`, `lib/log/` — inspection/output
  primitives.
- `lib/git/` (wip) — talks to git itself, not just the CLI.
- `lib/parser_combinators/`, `lib/peg/`, `lib/grammar/`, `lib/regex*` —
  the parsing layer a language-aware tool would need, though none of them
  is tree-sitter's incremental/error-tolerant model.
- `lib/pkg/` — package manager design exists (foundation only, no install
  algorithm yet) — see `docs/pkg-design.md`.
- `lib/doc/`, `lib/lsp/`, `lib/mcp/` — wip: doc generation, a second LSP
  effort, and MCP (tool-calling protocol for LLMs) surface.
- `lib/platform/` — the sandboxed app runner apps ship through; already
  the substrate a browser-based dev tool would deploy on.
- `lib/vm/`, `lib/ir/` — wip low-level pieces that a debugger or bytecode
  inspector would want.
- No entries for: DAP-style breakpoint/step debugging, containerization,
  CI/CD orchestration, code coverage-driven mutation testing, structural
  (tree-sitter-like) incremental parsing, dependency graph resolution
  (pkg has the foundation, not the algorithm).

## 4. What's missing or interesting

**Crescent already IS a dev environment, in the Smalltalk sense, more than
it's been given credit for.** It has a typechecker, an LSP, a test runner,
a package foundation, and a sandboxed app platform, all in one
zero-dependency clone. The interesting move isn't "add an IDE," it's
noticing the IDE is a *consequence* of what's already there, wired together
and given a face.

- **No debugger.** This is the most conspicuous gap for a language
  ecosystem this complete. LuaJIT has no built-in DAP-shaped hook, but
  `debug.sethook` + a coroutine-based stepper is enough to build a
  from-scratch debug adapter: `lib/debug_adapter/` speaking DAP so any
  DAP-capable frontend (including a crescent-native one) can drive it.
  Given `lib/actor` and `lib/async`, a debugger could be presented as a
  *coroutine you can single-step*, which is closer to the Lisp-machine
  break-loop model than to gdb.

- **A crescent-native IDE is a browser app on `lib/platform/`, not a
  separate program.** The pieces already exist as libraries: LSP daemon
  for diagnostics/completion, `lib/diff`/`lib/merge3` for version control
  UI, `lib/test` for a red/green panel, `lib/tracing`/`lib/metric` for a
  DevTools-style inspector panel. What's missing is the *editor surface*
  itself — text buffer + rendering + tree-sitter-equivalent incremental
  parse for structural nav/highlight. That's the one genuinely new,
  nontrivial library: an incremental, error-tolerant Lua parser usable
  keystroke-by-keystroke, which the existing PEG/parser-combinator/regex
  libraries don't provide (they're all "parse a whole buffer" tools).

- **The REPL question.** Crescent has no REPL yet. `bin/cr` dispatches to
  a language; a `bin/cr repl` in the nREPL tradition — a long-lived process
  a client attaches to over the existing `lib/jsonrpc` — would let the LSP,
  a browser IDE, and a terminal all share one live Lua state. This is the
  connective tissue between "typechecker as static tool" and "typechecker
  as thing you interrogate live," matching the Smalltalk image model more
  than a stateless CLI.

- **Structural editing over textual editing.** Given crescent has a real
  typechecker with narrowing and a parser already, "select the enclosing
  expression" / "extract this to a function and crescent infers the
  signature" is more reachable here than it would be bolting the same
  feature onto an untyped-Lua tool. Refactoring tools that are
  *type-aware by construction* (rename that knows it can't collide,
  extract-function that infers a correct annotation using the existing
  `--:`/`--::` grammar) are a distinctive crescent angle other Lua
  tooling doesn't have.

- **CI/CD is conspicuously absent as a library**, and per `CLAUDE.md`
  ("No framework code in `lib/`... no HTTP servers, generic dispatch/
  routing layers") it should probably *stay* absent as a library — CI
  orchestration is exactly the kind of framework-shaped thing the
  no-framework-code rule is guarding against. The existing
  `.github/workflows/*.yml` is the right layer for that, not `lib/`.
  Worth being explicit about, since "development tools" as a facet
  invites scope creep toward "build a Jenkins."

- **Containerization is the other likely non-goal.** Zero-dependency /
  vendored-binary is close to what containers solve (reproducible
  environment) by a different, lighter mechanism — crescent's whole pitch
  (`git clone` and run, vendored LuaJIT, no installs) is arguably a
  *rebuttal* to needing containers for this ecosystem specifically. A
  `lib/dev_env` library that wraps Docker would be pulling in the exact
  dependency weight crescent exists to avoid; more interesting is
  crescent apps *not needing* a container in the first place.

- **Docs tooling exists partially** (`lib/doc/`, wip) but a
  Jupyter/Observable-style literate notebook — Lua cells, typechecked,
  re-run on dependency change, rendered via `lib/platform` — would marry
  three things crescent already has (typechecker, reactive signals in
  `lib/reactive`/`lib/signals`, browser app platform) into something none
  of the existing libraries individually provide.

- **Profiling** has `lib/bench` (micro-bench) and `lib/tracing`/`lib/metric`
  (macro observability), but nothing at the "flamegraph of one slow test
  run" grain — a sampling or hook-based profiler is a plausible small
  addition once `lib/debug_adapter`-style hooks into `debug.sethook` exist,
  since the two would share the same instrumentation primitive.

## 5. Shape of crescent-native versions (sketch, not a plan)

- `bin/cr repl` — nREPL-shaped, `lib/jsonrpc` transport, one live state
  shared by editor/browser IDE/terminal.
- `lib/debug_adapter/` — DAP server over `debug.sethook` + coroutines;
  break-loop feels like "drop into a REPL at this frame," Lisp-machine
  style, not gdb style.
- A browser IDE app under `lib/platform/apps/` that is mostly composition:
  LSP client + `lib/diff`/`lib/merge3` for a VCS panel + `lib/test` for a
  results panel + the new incremental parser for structural nav/highlight.
- Type-aware refactors (rename, extract-function-with-inferred-signature)
  as a thin layer over the existing v5 typechecker's narrowing/unification,
  not a new type engine.
- Explicitly *not*: a CI orchestrator, a container runtime, or a Docker
  wrapper — those cut against `docs/overview.md`'s zero-dependency,
  vendored-binary premise rather than extending it.
