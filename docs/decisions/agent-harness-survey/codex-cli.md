# Prior Art Survey: OpenAI Codex CLI

Survey date: 2026-08-02. Repo verified live: <https://github.com/openai/codex>
(Apache-2.0, ~103k stars, ~8.8k commits at time of survey).

**Source confidence.** Claims below are tagged where provenance matters:

- **[primary]** — read from the repo itself (`README.md`,
  `codex-rs/docs/protocol_v1.md`, `codex-rs/linux-sandbox/README.md`,
  `codex-rs/execpolicy/README.md`) or official OpenAI docs
  (`learn.chatgpt.com/docs/*`, formerly `developers.openai.com/codex/*`).
- **[secondary]** — DeepWiki's generated index of the repo, or third-party
  analyses. Directionally reliable, structurally detailed, but not read from
  source. Anything load-bearing for a crescent design decision should be
  re-verified against source before being treated as settled.

No claim here was verified by running Codex.

## Overview

Codex CLI is OpenAI's local coding agent: a terminal application (plus IDE
extension, desktop app, and cloud variant) that runs an LLM agent loop against
the user's real filesystem and shell. Originally shipped as a TypeScript/Node
CLI, it was rewritten in Rust; the current implementation lives in `codex-rs/`,
a Cargo workspace of ~70–120 member crates built with Bazel **[secondary]**.
The npm package `@openai/codex` now distributes prebuilt platform binaries
rather than JS **[primary]**.

The rewrite is itself the first design signal: the project chose a single
statically-linked native binary with vendored platform helpers over a runtime-
dependent script. Sandboxing is the stated reason it needed native code —
Seatbelt, Landlock, seccomp, and Windows restricted tokens are not reachable
from a portable scripting runtime.

## Architecture

**Submission Queue / Event Queue (SQ/EQ)** **[primary,
`codex-rs/docs/protocol_v1.md`]**. The core engine is not a library the UI calls
into; it is a queue-driven service. The client (TUI, headless exec, SDK, MCP
server) pushes `Op` messages onto the Submission Queue, each tagged with a
client-chosen `sub_id`; the engine streams `EventMsg` values back on the Event
Queue carrying the originating `sub_id`. The documented rationale is transport
independence — the same protocol is stated to work over "cross-thread channels,
IPC, stdin/stdout, TCP, HTTP2, gRPC" — which decouples the agent engine from any
particular front end.

The entity hierarchy is explicit **[primary]**:

- **Session** — configuration + runtime state, established by the first
  `Op::ConfigureSession`.
- **Task** — a unit of work triggered by user input. Sessions run Tasks
  sequentially.
- **Turn** — one model round-trip inside a Task: send prompt → collect streamed
  response → execute commands / apply patches → await approval if required →
  produce output for the next Turn. *"A Turn yielding no output terminates the
  Task."*

Selected `Op` variants: `UserTurn` (carries per-turn context — cwd, model,
approval policy, sandbox policy), `Interrupt` (abort current Task),
`ExecApproval` (grant/deny a specific command), `UserInputAnswer` (answer a
tool's question). Selected `EventMsg` variants: `TurnStarted`/`TurnComplete`,
`AgentMessageContentDelta` (streamed text), `ExecApprovalRequest`,
`Error`/`Warning`.

**Per-turn context, not per-session context.** `Op::UserTurn` carries model,
cwd, and both policies. Approval mode and sandbox policy are therefore turn-
scoped values, not global mutable state — a user can widen or narrow permissions
between turns without tearing down the session.

**Response bookmarking / forking** **[primary]**. Every event carries a
`response_id`. Supplying an earlier `response_id` in a future user turn forks the
thread from that point. Conversation history is a rewindable log, not a stack.

**Crate layout** **[secondary, DeepWiki]**: `codex-cli` (single binary,
subcommand dispatch to all modes), `codex-core` (engine: `ThreadManager`,
`CodexThread`, `ModelClient`, `RolloutRecorder`, `McpManager`), `codex-tui`
(ratatui frontend), `codex-exec` (headless), `codex-mcp-server` /
`codex-mcp-client`, `codex-execpolicy`, `codex-linux-sandbox`, apply-patch,
file-search, login, OTel. One binary, many entry points — all non-primary modes
are subcommands of `codex`.

## Tool-Calling Protocol

Tools are declared to the model as `ToolSpec` + JSON Schema; a `ToolRegistry`
maps names to handlers and a `ToolRouter` is the dispatch entry point,
constructed from `ToolRouterParams` that computes availability from session
config, connected MCP servers, and dynamic tools **[secondary]**. Built-in tool
families **[secondary, corroborated by official docs for `apply_patch` and
subagent tools]**:

- **`shell`** — standard one-shot command execution.
- **`apply_patch`** — the single file-mutation mechanism. Uses **V4A**, a
  purpose-built diff grammar (not unified diff, not search/replace). OpenAI
  states the models are *trained on this exact format* and recommends third-party
  harnesses adopt their implementation verbatim **[primary, prompting guide]**.
  Supports heredoc bodies for large patches and returns an `AppliedPatchDelta`
  naming exactly which hunks landed.
- **`unified_exec`** — PTY-backed persistent interactive processes with LRU
  pruning of live sessions; opt-in via `[features].unified_exec` or
  `codex --enable unified_exec`.
- **Code Mode** — a JavaScript REPL where tools are injected as JS bindings that
  bridge back into the Rust tool system; the model writes code that calls tools
  instead of emitting one tool call per step.
- **Multi-agent** — `SpawnAgentHandler`, `WaitAgentHandler`, `SendMessageHandler`.
- **Discovery/extension** — web search, image generation, and MCP tools via an
  `ExtensionToolAdapter`.

Execution is not serialized by default: a `ToolCallRuntime` runs calls in
parallel where `tool_supports_parallel` holds, coordinating with sequential tools
through the same dispatch path **[secondary]**.

**Dispatch pipeline** **[secondary]**: approval check → sandbox selection →
execution attempt → retry-with-escalation-on-denial. Sandbox denials are
*detected*, not just propagated: the runtime recognizes Landlock exit codes and
stderr signatures such as `bubblewrap is unavailable`, and converts them into a
retry or an escalation prompt rather than surfacing a raw failure to the model.

**MCP in both directions.** Codex is an MCP client (`mcp_servers` in config) and
also ships an MCP *server* mode, so another agent can drive Codex as a tool.

## Context/Memory Management

**Instruction files: `AGENTS.md`** **[primary, official guide]**. Codex builds an
instruction chain once per run:

1. Global scope: in `$CODEX_HOME` (default `~/.codex`), read `AGENTS.override.md`
   if present, else `AGENTS.md` — first non-empty file only.
2. Project scope: from the project root (usually the Git root) walking *down* to
   cwd; in each directory, `AGENTS.override.md`, then `AGENTS.md`, then names in
   `project_doc_fallback_filenames`. At most one file per directory.
3. Concatenate root-first, joined by blank lines, skipping empties, stopping at
   `project_doc_max_bytes` (32 KiB default).

Two decisions worth noting: the `.override.md` sibling lets a user shadow shared
guidance without deleting it, and the byte budget is a hard truncation of the
*chain*, not per-file — deep directory nesting silently costs the leaf files.
`--print-instructions` dumps the merged result, making the chain auditable.

**Compaction** **[secondary, corroborated by config reference [primary]]**.
`model_auto_compact_token_limit` sets the trigger threshold against
`model_context_window`; values above 90% of the window are silently ignored.
Compaction fires at two points: before sending a new user message, and mid-turn
during a long tool-call chain. The mechanism is *full extraction and
replacement*: a `SUMMARIZATION_PROMPT` is appended as a user message, the same
model at the same endpoint produces a summary, and the history is discarded and
rebuilt from that summary — not appended to. Prior summary messages are detected
and excluded when gathering messages to preserve, so summaries do not accumulate
across compactions. The last user message is preserved as the final item.

**Rollout persistence** **[secondary]**. `RolloutRecorder` appends newline-
delimited JSON to `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`; each
line is a `RolloutLine` (UTC timestamp + ordinal) wrapping a `RolloutItem`.
`RolloutItem` variants observed: `ResponseItem`, `EventMsg`, `SessionMeta`,
`TurnContext`, `Compacted`, `InterAgentCommunication`, `WorldState`. A SQLite
index (`state_5.sqlite`) sits over the JSONL for querying/listing, and can be
backfilled from the filesystem — the log is the source of truth, the database is
a derived cache. Resume reconstructs cwd, model, and sandbox policy by replaying
`SessionMeta` + `TurnContext`, and *appends to the existing file* rather than
starting a new one.

## Sandboxing & Permissions

This is the part of Codex most worth studying. The design separates two axes
that are commonly conflated:

- **Sandbox mode** — what the OS will *physically permit* the process to do.
- **Approval policy** — when the agent *pauses to ask a human*.

**Sandbox modes** **[primary]**: `read-only` (inspect only; no writes, no
commands without approval), `workspace-write` (read anywhere, write inside the
project boundary, run routine commands; the default), `danger-full-access` (no
filesystem or network restriction).

**Approval policies** **[primary]**: `untrusted` (ask before any unfamiliar
command), `on-request` (agent works freely inside sandbox limits and asks only
when it needs to cross a boundary), `never` (no prompts at all). The config
reference also lists `on-failure` and per-category granular settings.

**Network is denied by default** inside the sandbox, independent of filesystem
policy; `sandbox_workspace_write.network_access` re-enables it. Other keys:
`writable_roots`, `exclude_tmpdir_env_var`, `exclude_slash_tmp`.

**macOS — Seatbelt** **[secondary]**. `sandbox-exec` with an SBPL profile
*generated per invocation* from the active `SandboxPolicy` rather than a static
file. `.git`, `.agents`, and `.codex` are forced read-only even inside otherwise
writable roots — the agent cannot rewrite git history or edit its own permission
config.

**Linux — Bubblewrap primary, Landlock legacy** **[primary,
`codex-rs/linux-sandbox/README.md`]**. Current design prefers `bwrap`:
`--unshare-user`, `--unshare-pid`, `--ro-bind / /` as the baseline with explicit
writable binds carved out, network namespace unshared when network is denied,
and sensitive paths (`.git`, `gitdir:` pointers, `.codex`) re-protected after the
writable binds are applied. In-process it additionally applies
`PR_SET_NO_NEW_PRIVS` and a seccomp filter blocking network syscalls
(`connect`, `bind`; `ptrace` also blocked). A "managed proxy" mode routes
TCP→UDS→TCP through a bridge when network is allowed but must be mediated, and
in that mode seccomp additionally blocks creating new `AF_UNIX`/`socketpair`
endpoints so the guest cannot escape the bridge. Landlock is retained only as an
explicit fallback behind `features.use_legacy_landlock = true`.

**bwrap acquisition is tiered and version-probed** **[primary]**: prefer the
first system `bwrap` on `PATH` *outside the cwd* (an anti-planting measure); if
it is too old for `--argv0`, use a compatibility path; if it lacks `--perms`,
reject it; if absent entirely, use the **vendored bubblewrap binary shipped with
Codex**. WSL2 behaves as Linux; WSL1 is explicitly unsupported because it cannot
create user namespaces.

**The helper is the same binary under a different argv0** **[primary]**. There is
no separate `codex-linux-sandbox` executable to install: the dispatcher inspects
argv0, and if invoked under that alias jumps straight into sandbox execution,
otherwise proceeds with normal CLI startup while knowing the path to itself for
re-exec. Both `codex-exec` and the `codex` multitool honor the alias, so
sandboxing is identical across entry points.

**Windows** **[secondary]**: restricted tokens, synthetic SIDs, a dedicated
sandbox user, ACL denials for the sandbox identity, firewall rules, a preflight
audit for world-writable directories that would defeat the ACLs, and an elevated
IPC runner reached over framed pipes with credential-refresh retry.

**execpolicy: command permission as a declarative language, not a hardcoded
allowlist** **[primary, `codex-rs/execpolicy/README.md`]**. Rules are written in
Starlark — chosen because it evaluates without side effects (no filesystem
access from rule evaluation). The primitives are `prefix_rule()` and
`host_executable()`:

```starlark
prefix_rule(
    pattern = ["cmd", ["alt1", "alt2"]],
    decision = "prompt",
    justification = "explain why",
    match = [["cmd", "alt1"]],
    not_match = [["cmd", "oops"]],
)
```

Tokens match in order; a list element denotes alternatives. Decisions are
`allow` / `prompt` / `forbidden`, and *"the effective decision is the strictest
severity across all matches"* — rules compose by taking the maximum severity, so
adding a rule can never accidentally widen permission. `match`/`not_match` are
inline unit tests validated **at rule-load time**, so a malformed policy fails
loudly at startup rather than silently mismatching at runtime. `justification`
is a first-class field surfaced in approval prompts and rejection messages —
a denial can tell the model *why* and suggest an alternative.

**Debuggability**: `codex debug seatbelt` and `codex debug landlock` run an
arbitrary command through the sandbox so the policy can be tested directly,
outside an agent session **[secondary]**.

**Known weak point**: exec-policy matching has been reported bypassable via
Unicode confusable characters (openai/codex#13095) — evidence that token-level
pattern matching over shell strings is a leaky abstraction for a security
boundary, and part of why the OS-level sandbox is the real boundary and
execpolicy only decides *whether to ask*.

## Multi-Agent Support

**[primary, official subagents doc; corroborated secondary]**

Subagents are first-class and expressed as tools the model calls
(`spawn_agent`, `wait_agent`, `send_message`), not as an external orchestration
script. Design points:

- **Stated motivation is context pollution**, not parallelism: noisy
  intermediate work (codebase exploration, verification runs) is moved off the
  main thread so the main thread's context holds requirements and decisions.
  Parallel speedup is a secondary benefit.
- **Custom agents are standalone TOML files** in `~/.codex/agents/` requiring
  `name`, `description` (*when Codex should use this agent* — i.e. the routing
  signal is data, not code), and `developer_instructions`. They may additionally
  override `model`, `sandbox_mode`, and `mcp_servers`.
- **Permission inheritance with per-agent override.** Subagents inherit the
  parent's approval mode and sandbox policy by default; a custom agent may
  narrow (or widen) its own sandbox config.
- **Bounded fan-out.** `[agents]` config: `agents.enabled`,
  `agents.max_concurrent_threads_per_session`, `agents.default_subagent_model`,
  `agents.default_subagent_reasoning_effort`. Reported defaults in the CLI
  include `max_threads = 6` and `max_depth = 1` **[secondary]** — recursion depth
  is capped, so subagents cannot spawn arbitrarily deep trees by default.
- **Collection is blocking and consolidated**: the orchestrator waits for all
  requested results and folds them into one response on the main thread.
- **Delegation is explicit at most tiers** — the model delegates when asked or
  when `AGENTS.md`/skill instructions request it; proactive autonomous
  delegation is gated to the highest intelligence tier.
- `/agent` inspects and switches between live agent threads mid-run, and
  `InterAgentCommunication` rollout items make inter-agent messages replayable.

## Notable Design Decisions

1. **Sandbox mode and approval policy are orthogonal axes.** Most harnesses
   collapse these into one "permission level". Codex keeps "what the kernel
   allows" separate from "when to interrupt the human", which is what makes
   `on-request` coherent: work freely inside a hard boundary, and the *boundary
   violation itself* is the interrupt trigger.
2. **Denial is a control-flow signal, not an error.** Commands are run
   optimistically inside the sandbox; the harness recognizes sandbox-specific
   denial exit codes and stderr patterns and converts them into an escalation
   prompt. No pre-classification of every command is required for safety —
   the OS decides, and the harness reacts.
3. **Engine as a queue service, not a library.** SQ/EQ with transport-agnostic
   messages makes TUI, headless, IDE, SDK, and MCP-server modes the *same*
   engine, and makes recording trivially equivalent to tapping the queues.
4. **Conversation state is an append-only log with a derived index.** JSONL
   rollout is truth; SQLite is a rebuildable cache; `response_id` bookmarks make
   the log forkable. Resume appends to the original file.
5. **Compaction replaces history rather than appending to it**, and explicitly
   evicts prior summaries so summaries never stack.
6. **One trained-on patch format, not a diff dialect zoo.** V4A is a
   model-training decision surfaced as a tool contract; the harness owns the
   format because the weights do.
7. **The sandbox helper is the main binary under a different argv0.** Zero extra
   install artifacts, and no possibility of helper/binary version skew.
8. **Vendor the sandbox dependency, and version-probe the system one.** System
   `bwrap` is used only if found outside cwd *and* advertising the required
   flags; otherwise a bundled bwrap runs. Capability detection, not version
   strings.
9. **Command policy is a side-effect-free declarative language with inline
   tests and machine-checked composition** (strictest-match-wins,
   `match`/`not_match` validated at load). Policy is data with a test suite,
   not `if` statements in the executor.
10. **Denials carry justifications** intended for the model and the user, so a
    refusal is actionable rather than opaque.
11. **Self-protecting paths.** `.git`, `.codex`, and `.agents` are forced
    read-only inside otherwise-writable roots — the agent cannot edit the config
    that constrains it, nor rewrite history to hide what it did.
12. **Subagents exist to protect context, and are capped in both width and
    depth.**
13. **Instruction files merge root-down with an override sibling and a byte
    budget**, and the merged result is printable for audit.

## Relevance to Crescent

Observations only — none of these are decisions, and each names a real branch
point rather than a recommendation.

**Where crescent stands today** (read from source): `lib/ai/tools.lua` is a
79-line loop — `ai.generate` → dispatch `tc.name` through an `opts.handlers`
table → append `role = "tool"` messages → repeat to `max_rounds` (default 10).
It has no approval hook, no sandbox, no persistence, no compaction, and
`lib/platform/apps/` has no agent app yet. Every Codex mechanism above is
therefore additive rather than a migration.

**Directly transferable, cheap:**

- The two-axis split (sandbox mode × approval policy) is a data-model decision
  costing nothing to adopt early and expensive to retrofit once callers assume
  a single permission enum.
- Append-only JSONL rollout with a derived index matches crescent's existing
  bias toward plain-file truth, and gives resume/fork/audit from one mechanism.
- The instruction-chain merge (root-down, one file per directory, override
  sibling, byte budget, printable) is pure file logic — no substrate needed.
- `justification` on a denial is a one-field decision with outsized effect on
  loop quality.

**Structurally interesting, larger:**

- SQ/EQ maps onto `lib/taskgraph` territory. The open question is whether the
  agent loop *is* a taskgraph node (turns as graph execution, approvals as
  frontier suspension) or a separate engine that taskgraph merely schedules.
  Both are workable; they differ in whether approval-suspension machinery is
  built once in taskgraph or twice.
- Subagents-as-tools versus subagents-as-orchestrator-API is a genuine fork.
  Codex chose tools (the model decides to delegate); taskgraph's existence makes
  the orchestrator-API shape equally natural (the graph decides). These produce
  different tool surfaces and different failure modes.
- A Starlark-style declarative exec policy has no crescent analogue — but the
  *properties* (side-effect-free evaluation, strictest-match composition, tests
  validated at load) are achievable in a Lua data-table policy without a new
  language. Whether that policy is Lua data or a parsed DSL is an open call.

**Blocked on substrate, not adoptable now:**

- OS-level sandboxing is out of reach from pure Lua. Seatbelt, Landlock,
  seccomp, and bwrap all require either process-spawn with specific argv/env or
  direct syscalls. Crescent's tiering rule (system > FFI > pure Lua, each
  independent, never fail hard) points at: spawn `bwrap`/`sandbox-exec` as an
  outer process where available; there is **no pure-Lua fallback that provides a
  security boundary**, which means the pure-Lua tier can only be
  "unsandboxed + approval-gated". That is a substrate limit to state plainly,
  not to paper over — an approval prompt is not a sandbox.
- Consequently, Codex's "run optimistically, escalate on denial" pattern is
  unavailable in the pure-Lua tier: with no enforcement there is no denial
  signal to react to, and permission decisions must be made *before* execution.
  The two tiers therefore want genuinely different control flow, not one wrapped
  around the other.
- The V4A lesson does not transfer as a format (it is tied to OpenAI's training
  data); it transfers as a *question*: whose patch format does crescent's edit
  tool speak, given `lib/ai` targets multiple providers whose models are trained
  on different ones. That is provider-registry-shaped, and unresolved.

## Sources

Primary (repo / official docs):

- <https://github.com/openai/codex> — repository, README
- <https://raw.githubusercontent.com/openai/codex/main/codex-rs/docs/protocol_v1.md> — SQ/EQ protocol, Session/Task/Turn, Op & EventMsg variants
- <https://raw.githubusercontent.com/openai/codex/main/codex-rs/linux-sandbox/README.md> — bwrap/Landlock/seccomp, argv0 helper, vendored bwrap
- <https://raw.githubusercontent.com/openai/codex/main/codex-rs/execpolicy/README.md> — Starlark rules, decisions, strictest-match, load-time tests
- <https://learn.chatgpt.com/docs/sandboxing> — sandbox modes, approval policies, platform mechanisms
- <https://learn.chatgpt.com/docs/agent-configuration/subagents> — subagent config, isolation, inheritance
- <https://learn.chatgpt.com/docs/config-file/config-reference> — config keys
- <https://developers.openai.com/codex/guides/agents-md> — AGENTS.md discovery/merge
- <https://developers.openai.com/codex/exec-policy> — exec policy rules
- <https://developers.openai.com/cookbook/examples/gpt-5/codex_prompting_guide> — apply_patch/V4A recommendation

Secondary (generated wikis, third-party analysis):

- <https://deepwiki.com/openai/codex/5.6-sandboxing-implementation>
- <https://deepwiki.com/openai/codex/5-tool-system-and-execution>
- <https://deepwiki.com/openai/codex/3.5.2-rollout-persistence-and-replay>
- <https://deepwiki.com/openai/codex/1.2-repository-structure>
- <https://simonwillison.net/2025/Nov/9/codex-sandbox-investigation/>
- <https://codex.danielvaughan.com/2026/03/31/codex-cli-context-compaction-architecture/>
- <https://codex.danielvaughan.com/2026/03/31/codex-cli-apply-patch-v4a-diff-format/>
- <https://codex.danielvaughan.com/2026/05/14/codex-cli-windows-sandbox-engineering-restricted-tokens-acls-elevated-architecture/>
- <https://github.com/openai/codex/issues/13095> — Unicode confusable exec-policy bypass
- <https://github.com/openai/codex/issues/15507>, <https://github.com/openai/codex/pull/20628> — bwrap `--argv0`/`--perms` capability probing

Local files read for the Relevance section: `lib/ai/tools.lua`,
`lib/ai/` and `lib/taskgraph/` listings, `lib/platform/apps/` listing.
