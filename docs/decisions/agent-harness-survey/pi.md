# Prior art: `earendil-works/pi`

Survey date: 2026-08-02. Researched against a shallow clone of `main`
(`pushed_at` 2026-08-02T07:04:52Z).

## Overview

**The repository exists and is squarely agent-related.**

`github.com/earendil-works/pi` — "AI agent toolkit: unified LLM API, agent loop,
TUI, coding agent CLI". TypeScript monorepo, MIT, created 2025-08-09,
82,070 stars / 10,146 forks at survey time. ~136k lines of non-test TypeScript
across `packages/`. Project website `pi.dev`; primary author appears to be
Mario Zechner (`badlogicgames` / mariozechner.at) based on linked blog posts
and session-sharing datasets in the README.

Published packages:

| Package | Role |
| --- | --- |
| `@earendil-works/pi-ai` | Unified multi-provider LLM API |
| `@earendil-works/pi-agent-core` | Agent runtime: loop, tools, session, harness |
| `@earendil-works/pi-coding-agent` | Interactive coding agent CLI |
| `@earendil-works/pi-tui` | Terminal UI library, differential rendering |

Internal-only packages: `protocol`, `server`, `client`, `storage`, `evals`.

The stated philosophy is a deliberately minimal core plus aggressive
extensibility — "adapts to your workflows without having to fork and modify pi
internals." Notably, several features that peer harnesses treat as core are
explicitly *excluded* (see Notable Design Decisions).

## Architecture

Three layers, cleanly separated.

**Layer 1 — `pi-ai` (provider abstraction).** A `Models` collection registers
provider factories; `models.getModel(provider, id)` is a sync lookup.
`streamSimple()` / `stream()` take a `Context { systemPrompt, messages, tools }`
and return an event stream. Roughly 28 providers built in (OpenAI, Anthropic,
Google, Vertex, Bedrock, Groq, Cerebras, xAI, OpenRouter, DeepSeek, Mistral,
Moonshot, MiniMax, ZAI, Copilot, Codex, plus any OpenAI-compatible endpoint).
Deliberate scope restriction: *only models that support tool calling are
included*, since anything else is useless for agentic work. Cross-provider
handoff mid-session is a first-class feature, as is auth resolution (env vars,
credential store, OAuth for Copilot/Codex/Vertex), token+cost tracking, and a
`registerFauxProvider()` test double for deterministic tests without network.

**Layer 2 — `packages/agent/src/agent-loop.ts` (low-level loop, 792 lines).**
Pure function over messages; no I/O ownership. Signature:

```ts
function agentLoop(
  prompts: AgentMessage[], context: AgentContext, config: AgentLoopConfig,
  signal: AbortSignal | undefined, streamFn: StreamFn,
): EventStream<AgentEvent, AgentMessage[]>
```

Control flow is a nested double loop:

- *Inner loop* runs while `hasMoreToolCalls || pendingMessages.length > 0`:
  inject pending steering messages → stream assistant response → filter
  `toolCall` content blocks → execute → append results → emit `turn_end` →
  call `prepareNextTurn` (save point) → check `shouldStopAfterTurn` → drain
  steering queue.
- *Outer loop* re-enters when `getFollowUpMessages()` returns work after the
  agent would otherwise have stopped.

Events: `agent_start`, `turn_start`, `message_start`, `message_end`,
`turn_end`, `agent_end`. The loop works on `AgentMessage[]` throughout and only
converts to provider `Message[]` at the LLM call boundary via
`config.convertToLlm` — with an optional `config.transformContext` hook applied
first. `agentLoopContinue()` resumes from existing context without a new prompt
(used for retries), and validates that the last message is not `assistant`.

**Layer 3 — `AgentHarness` (`packages/agent/src/harness/agent-harness.ts`,
1185 lines).** The orchestration layer: session persistence, runtime config,
resource resolution, operation locking, extension-facing mutation semantics.
It calls `runAgentLoop()` directly (the intermediate `Agent` dependency was
removed).

Its central idea is a **four-way state split**:

1. *Harness config* — latest runtime configuration (model, thinking level,
   tools, active tools, resources, stream options, system prompt). Getters
   return this, not in-flight state. Setters take effect immediately but apply
   to the *next* turn.
2. *Turn snapshot* — the concrete state used for one LLM turn, built by
   `createTurnState()`. Resource arrays are shallow-copied; system-prompt
   providers are invoked exactly once per snapshot. All logic for that turn
   reads the same snapshot.
3. *Session* — persisted entries only; reads never include queued writes.
4. *Pending session writes* — writes requested while an operation is active,
   queued and flushed deterministically.

An explicit phase machine guards structural operations:

```ts
type AgentHarnessPhase = "idle" | "turn" | "compaction" | "branch_summary" | "retry";
```

`prompt`, `skill`, `promptFromTemplate`, `compact`, and `navigateTree` require
`phase === "idle"` and set the phase synchronously before the first `await`;
starting one while busy rejects with `AgentHarnessError` code `"busy"`.
`steer`, `followUp`, `nextTurn`, `abort`, and runtime config setters are legal
mid-turn.

**Save points** are the reconciliation mechanism: after an assistant turn and
its tool results complete, the harness flushes pending writes, builds a fresh
turn snapshot, and applies new context/model/thinking-level/stream-options
before the next provider request. This is how mid-run model switches take
effect without ever mutating an in-flight request.

`AssistantMessageStream` decouples provider transport reads (SSE/websocket)
from downstream event consumption, so the harness can `await` listeners, hooks,
and persistence without stalling the transport or needing an ad-hoc event
queue.

**Error handling is split by layer** and stated as policy: low-level
capabilities (`ExecutionEnv`, filesystem/shell, resource loading, compaction
helpers) return `Result<TValue, TError>` and must not throw; high-level
mutation APIs (`Session`, `AgentHarness`) reject/throw, normalized to
`AgentHarnessError` with the subsystem error preserved as `cause`.

**Execution capability injection.** All filesystem and process access goes
through an `ExecutionEnv` supplied in the tool context. Node-specific code is
isolated in `src/harness/env/nodejs.ts` (675 lines) and deliberately excluded
from browser-safe root exports; generic utilities avoid Node globals
(`Buffer` replaced with runtime-neutral UTF-8 handling). This is functionally
the same discipline crescent calls caps-first.

**Four run modes:** interactive TUI; print/`-p`; `--mode json`; `--mode rpc`
(LF-delimited JSONL over stdin/stdout, with an explicit warning not to use
Node `readline`, which splits on Unicode separators inside JSON payloads); plus
an embeddable SDK (`createAgentSessionRuntime()`).

**Durability is designed but not built.** `docs/durable-harness.md` and item 5
of the harness TODO describe resuming a harness from session entries via
reducers. Two blockers are recorded honestly: provider streams are not
resumable, so recovery must restart from durable boundaries or mark the
operation interrupted; and unfinished tool calls are unsafe to retry unless
tools declare idempotency.

## Tool-Calling Protocol

Tools are declared with **TypeBox schemas** (`Type.Object({...})`), which give
both compile-time TypeScript types and runtime JSON Schema for the provider.
`Tool<TParameters extends TSchema>` in `pi-ai` carries `name`, `description`,
`parameters`. `AgentTool` extends it with execution:

```ts
export interface AgentTool<TParameters extends TSchema = TSchema, TDetails = any>
  extends Tool<TParameters> {
  execute: (..., onUpdate?: AgentToolUpdateCallback<TDetails>) => Promise<AgentToolResult<TDetails>>;
}
```

`onUpdate` lets a long-running tool stream partial results; the callback is
scoped to the current `execute()` invocation.

Arguments are validated against the schema by `validateToolArguments()` before
execution.

**Concurrency is declared per tool**, not globally. Each tool declares
`"sequential"` (must run alone) or `"parallel"` (may run concurrently), and the
loop has a matching batch mode: sequential prepares/executes/finalizes each
call in order, parallel prepares all calls sequentially then executes allowed
ones concurrently. A `file-mutation-queue.ts` serializes conflicting writes.

**Truncated-arguments guard:** if the assistant message's `stopReason` is
`"length"`, *every* tool call in that message is failed via
`failToolCallsFromTruncatedMessage()` rather than executed, because any of them
may carry cut-off JSON arguments. This is a subtle correctness detail worth
copying.

Results are `ToolResultMessage { role, toolCallId, toolName, content:
(TextContent|ImageContent)[], details?, usage?, isError, timestamp }`.
`details` carries tool-specific metadata not sent to the model; `usage` records
nested LLM work performed *inside* a tool, so sub-agent cost rolls up.

Built-in tools in `packages/agent`: `createReadTool()`, `createWriteTool()`,
`createEditTool()`, `createBashTool()` — each structurally requires only the
context fields it uses (`ExecutionToolContext { env: ExecutionEnv }`).
`createBashTool()` takes an async `prepare` hook that can rewrite the command,
cwd, environment, and inheritance policy. `createReadTool()` takes an optional
image processor so the agent package need not depend on an image library.
The coding-agent adds `find`, `grep`, `ls` (`packages/coding-agent/src/core/tools/`).

Hooks around execution: `beforeToolCall` (after validation, can block) and
`afterToolCall` (returns `AfterToolCallResult` to override parts of the result;
omitted fields keep the executed values).

**No MCP.** This is an explicit, argued position, not an omission — the README
links to a post titled "what if you don't need MCP" and says to build CLI tools
with READMEs (i.e. skills) or write an extension that adds MCP.

**Extensions** are the tool-extension mechanism: TypeScript modules with a
default (optionally async) export receiving an `ExtensionAPI`.

```ts
export default function (pi: ExtensionAPI) {
  pi.registerTool({ name: "deploy", ... });
  pi.registerCommand("stats", { ... });
  pi.on("tool_call", async (event, ctx) => { ... });
}
```

The API surface (~2984 lines of docs) includes `registerTool`,
`registerCommand`, `registerShortcut`, `registerFlag`, `registerProvider`,
`registerMessageRenderer`/`registerEntryRenderer`/`registerMarkdownTransformer`,
`sendMessage`, `appendEntry`, `setActiveTools`, `setModel`, `compact`,
`newSession`/`fork`/`navigateTree`/`switchSession`. Event families:
startup, resource, session, agent, model, tool, user-bash, and input events.
Built-in tools can be replaced wholesale.

**Skills** implement the [Agent Skills standard](https://agentskills.io/specification):
directories containing `SKILL.md`, discovered from `~/.pi/agent/skills/`,
`~/.agents/skills/`, project `.pi/skills/` and `.agents/skills/`, packages, and
`--skill`. Names and descriptions are injected into the system prompt as XML;
the agent then uses the ordinary `read` tool to load the full body on demand.
Pi deliberately relaxes one spec rule (skill name must match directory name) so
skill directories can be shared across harnesses — and documents importing
`~/.claude/skills` and `~/.codex/skills` directly.

## Context/Memory Management

**Sessions are JSONL trees.** One file per session at
`~/.pi/agent/sessions/--<cwd-with-slashes-as-dashes>--/<timestamp>_<uuid>.jsonl`.
The first line is a `session` header (version, id, cwd, optional
`parentSession`). Every later line is an entry with an 8-char hex `id` and a
`parentId`, forming a **tree**, so branching happens in place without new files.
Format is versioned (v1 linear → v2 tree → v3 `hookMessage` renamed `custom`)
with automatic migration on load.

Entry types: `message`, `model_change`, `thinking_level_change`, `compaction`,
`branch_summary`, `custom` (extension state, *not* in LLM context),
`custom_message` (extension state that *is* in LLM context), `label`
(user bookmarks), `session_info` (display name), `leaf`,
`active_tools_change`.

The `custom` / `custom_message` split is the notable bit: extensions get
durable per-session state that is explicitly outside the model's context,
alongside a separate channel for injected context — the distinction is in the
entry type, not in convention.

`AgentMessage` is a union of `UserMessage | AssistantMessage |
ToolResultMessage | BashExecutionMessage | CustomMessage | BranchSummaryMessage
| CompactionSummaryMessage`. Content blocks: `text`, `image` (base64 +
mimeType), `thinking`, `toolCall`. Every assistant message carries
`api`, `provider`, `model`, `usage`, `stopReason` — so a session records
exactly which model produced each message, which is what makes mid-session
model handoff replayable.

`Usage` tracks `input`, `output`, `cacheRead`, `cacheWrite`, `totalTokens` and
a parallel `cost` breakdown — prompt caching is accounted for explicitly, not
inferred.

**Context construction** is two-phase. `buildContextEntries()` walks leaf → root
producing the active entry list while honoring compaction; `buildContext()` /
`buildSessionContext()` projects those entries to `AgentMessage[]`. Custom
entries are omitted from model context by default; applications may supply
`entryProjectors` to project selected ones, and stacked `entryTransforms` that
run after the default compaction transform to filter or reorder.

**Compaction** triggers when `contextTokens > contextWindow - reserveTokens`
(`reserveTokens` default 16384), or manually via `/compact [instructions]`.
Algorithm: walk backwards accumulating token estimates until `keepRecentTokens`
(default 20k) is reached to find the cut point; collect messages from the
previous kept boundary up to the cut; call the LLM for a structured summary,
passing the *previous* summary as iterative context; append a `CompactionEntry`.

Two refinements are worth noting:

- Newer compaction entries embed a materialized `retainedTail:
  AgentMessage[]`, making the entry a **self-contained checkpoint** — context
  can be rebuilt without walking entries older than the compaction. The legacy
  `firstKeptEntryId` pointer is kept only for backward compatibility.
- On repeated compaction, the summarized span starts at the *previous*
  compaction's kept boundary, not at the compaction entry, so messages that
  survived the earlier pass are re-summarized rather than silently dropped.
- Cuts normally land on turn boundaries (a turn = user message plus everything
  until the next user message). When one turn alone exceeds `keepRecentTokens`,
  the cut lands mid-turn at an assistant message — an explicitly handled
  "split turn" case.
- Compaction and branch-summary requests use *fresh routing session IDs* and
  disable prompt-cache writes where the provider supports it, since these
  one-off prompts will not be reused.

**Branch summarization** is the sibling mechanism: navigating the session tree
(`/tree`) generates an LLM summary of the abandoned branch up to the common
ancestor, stored as a `BranchSummaryEntry`, so context from the path not taken
is not simply lost.

Both mechanisms track file operations cumulatively (`details: { readFiles,
modifiedFiles }`).

**Context files.** `AGENTS.md` and `CLAUDE.md` are loaded regardless of project
trust (unless context loading is disabled) — pi reads the other harnesses'
convention files rather than inventing its own.

Storage is pluggable: `jsonl-store.ts`, `memory-store.ts`, and a separate
`packages/storage/sqlite-node`. A `keyed-operation-queue.ts` serializes writes
per key. `readTextLines()` exists so listing sessions reads only the header line.

## Sandboxing & Permissions

**Pi has no permission system and no sandbox, by explicit design.** The README
states it plainly: "Pi does not include a built-in permission system for
restricting filesystem, process, network, or credential access. By default, it
runs with the permissions of the user and process that launched it."

The rationale in `docs/security.md` is worth quoting because it is an argument,
not a disclaimer: "A partial in-process sandbox would be easy to misunderstand
as a security boundary while still depending on the host shell, filesystem,
package managers, credentials, and extension code. Real isolation needs to come
from the operating system or a virtualization/container boundary." Prompt
injection from repo files is named as "expected local-agent risk" that pi
cannot reliably prevent, and is explicitly outside the security boundary.

What *does* exist is **project trust** — an input-loading guard, not a sandbox.
Pi checks for `.pi/settings.json`, `.pi/extensions|skills|prompts|themes`,
`.pi/SYSTEM.md`, `.pi/APPEND_SYSTEM.md`, or project `.agents/skills`. If any
are present and no decision is saved, it follows `defaultProjectTrust`
(default `"ask"`). Decisions are stored by canonical directory in
`~/.pi/agent/trust.json`; the closest saved decision on the current or parent
path wins over the global default. Non-interactive modes (`-p`, `json`, `rpc`)
never prompt; `--approve`/`--no-approve` override per run. Before trust
resolves, only context files, user/global extensions, and CLI `-e` extensions
load — and a user/global extension can handle the `project_trust` event to own
the decision programmatically.

Real isolation is delegated to three documented patterns:

| Pattern | Isolates | Notes |
| --- | --- | --- |
| **Gondolin extension** | Built-in tools and `!` commands | `pi` and provider auth stay on host; a local Linux micro-VM (QEMU) runs the tools. Mounts host cwd at `/workspace`; overrides `read`, `write`, `edit`, `bash`, `grep`, `find`, `ls`. Writes under `/workspace` write through to host. |
| **Plain Docker** | Whole `pi` process | Simplest boundary; provider API keys enter the container. |
| **NVIDIA OpenShell** | Whole `pi` process | Policy-controlled sandbox with filesystem/process/network/credential/inference controls, local (Docker/Podman/VM) or remote (Kubernetes) gateway. Can keep raw API keys *outside* the sandbox by routing inference through `https://inference.local` with gateway-injected credentials. |

The Gondolin pattern — host process, VM-routed tools, host-held credentials — is
the architecturally interesting one, and it is only possible because tools take
their filesystem/process capability from an injected `ExecutionEnv` rather than
importing `node:fs` directly.

Caveat documented honestly: extensions run wherever the `pi` process runs, so
with host-`pi` + tool-routing, custom extension tools still execute on the host
unless they delegate too. And pi packages "run with full system access."

## Multi-Agent Support

**Not in core, by explicit decision.** The README: "**No sub-agents.** There's
many ways to do this. Spawn pi instances via tmux, or build your own with
extensions, or install a package that does it your way."

A reference implementation ships as an *example extension*
(`packages/coding-agent/examples/extensions/subagent/`). Its model:

- Each subagent runs as a **separate `pi` process**, giving a genuinely
  isolated context window rather than a shared one.
- Agent definitions are markdown files (`scout.md`, `planner.md`,
  `reviewer.md`, `worker.md`) in `~/.pi/agent/agents/` or `.pi/agents/`.
- Workflows are prompt templates chaining agents: `scout -> planner -> worker`,
  `scout -> planner`, `worker -> reviewer -> worker`.
- Parallel execution is supported, with all parallel tasks streaming updates
  simultaneously; `Ctrl+C` propagates to kill subagent processes.
- Usage (turns, tokens, cost, context) is tracked per agent — this is what the
  `usage?` field on `ToolResultMessage` is for.
- Security: project-local agents are *not* loaded by default (they are
  repo-controlled prompts that can instruct arbitrary tool use). Opt in via
  `agentScope: "both" | "project"`, with an interactive confirmation prompt
  unless `confirmProjectAgents: false`.

Separately, the session **tree** is a form of single-agent branching
concurrency: multiple explored paths coexist in one file, with LLM-generated
summaries preserving context across branch switches.

## Notable Design Decisions

1. **Deliberate core omissions, each with a published rationale.** No MCP, no
   sub-agents, no permission popups, no plan mode, no built-in to-dos ("they
   confuse models" — use `TODO.md`), no background bash ("use tmux — full
   observability, direct interaction"). Every one is reachable via extension.
   This is the clearest example in the survey of a harness treating "what not
   to build" as the primary design work.

2. **Session as a tree, not a log.** Branching in place, LLM-summarized branch
   abandonment, labels, and self-contained compaction checkpoints. Most
   harnesses model a session as an append-only list; pi's tree makes fork,
   navigate, and resume-from-anywhere structural rather than bolted on.

3. **Snapshot/config split as an explicit concurrency discipline.** "Getters
   return harness config, not the snapshot used by an in-flight provider
   request." Mutations during a turn are legal and land at the next save point.
   This is a real answer to the mid-turn-reconfiguration problem that most
   loops handle by forbidding it or by racing.

4. **Layered error policy.** `Result<T, E>` below, throw above, normalized at
   the public boundary with `cause` preserved. Stated as policy in
   `agent-harness.md` and enforced across `ExecutionEnv`, session storage, and
   compaction helpers.

5. **Capability-injected execution.** `ExecutionEnv` is the sole filesystem and
   process access path for built-in tools, Node specifics are quarantined to
   one file, and the package is kept browser-importable. This directly enables
   the Gondolin remote-execution pattern.

6. **Per-tool concurrency declarations** rather than a global sequential/
   parallel switch, with a file-mutation queue for conflicting writes.

7. **Honest, versioned design docs with TODO state in-repo.** `harness.md`
   (2390 lines), `harness-v2.md` (1827), `agent-harness.md` (506) carry
   numbered items with `Status: Done / In progress / Planned`, explicit
   "Remaining" lists, and known-unsound areas called out ("Abort barrier
   semantics still need an audit", "listeners/hooks currently receive no
   facade; ... they can deadlock"). Design intent and current reality are kept
   separate rather than blurred.

8. **Provider breadth as a separate, reusable package** with a stated inclusion
   filter (tool-calling models only) and a faux provider for deterministic
   tests.

9. **Supply-chain hardening treated as a first-class concern**: exact-pinned
   direct deps, `min-release-age=2` in `.npmrc` to avoid same-day releases,
   lockfile as ground truth with a pre-commit block, generated
   `npm-shrinkwrap.json` for published CLI users, `--ignore-scripts` on
   installs, an allowlist for dependency lifecycle scripts, and scheduled
   `npm audit`.

10. **Interop over invention** for resource conventions: Agent Skills standard
    compliance (with one documented deviation for cross-harness sharing),
    reading `AGENTS.md` *and* `CLAUDE.md`, and documented import of
    `~/.claude/skills` / `~/.codex/skills`.

11. **Session data as a public good.** The README asks users to publish OSS
    coding sessions to Hugging Face to improve agents on real tasks "instead of
    toy benchmarks."

## Relevance to Crescent

Crescent has `lib/ai/` (provider registry in `lib/ai/providers/`, a tool-calling
loop in `lib/ai/tools.lua`, `lib/ai/types.lua`) and `lib/taskgraph/`, and is
surveying prior art before designing an agent app under `lib/platform/apps/`.
Points of contact, stated as observations rather than recommendations:

- **The three-layer split (provider API / pure loop / stateful harness) maps
  onto crescent's existing division.** `lib/ai` is already roughly pi's
  layers 1–2. What crescent has no counterpart for is layer 3 — the harness
  that owns session persistence, phase locking, and save-point
  reconciliation. That layer is where most of pi's complexity lives, and pi's
  own docs say it is still not finished.

- **`ExecutionEnv` is pi's version of crescent's caps-first rule**, arrived at
  independently and for the same reasons (testability, browser portability,
  remote execution). The Gondolin pattern is concrete evidence of the payoff:
  because tools never import `fs` directly, routing every built-in tool into a
  micro-VM is an extension, not a fork. Crescent's caps discipline is already
  stricter (globals-are-a-violation); pi shows what it buys.

- **Session-as-tree vs session-as-log is a real, undecided design choice** for
  any crescent agent app, and it interacts with `lib/taskgraph`: pi's branch
  tree and a taskgraph both model divergent execution paths, but at different
  layers. Whether an agent app's history should be a taskgraph, a JSONL tree,
  or both is an open question this survey does not resolve.

- **Compaction with a materialized `retainedTail`** — making the compaction
  entry a self-contained checkpoint rather than a pointer into older entries —
  is a design detail that is cheap to adopt early and expensive to retrofit,
  since it changes the persisted format.

- **The truncated-arguments guard** (fail all tool calls when `stopReason ===
  "length"`) is a small correctness fix that `lib/ai/tools.lua` can adopt
  independently of any larger architectural decision.

- **Per-tool `"sequential" | "parallel"` declarations** are a schema-level
  concern; if crescent's tool definitions are still being shaped, this is a
  field worth deciding on before there are callers.

- **The "what not to build" list is the transferable artifact.** Pi's argument
  that a partial in-process sandbox is worse than none — because it reads as a
  boundary while not being one — bears directly on how a crescent agent app
  should present its safety story. Whether crescent agrees is a design call;
  the argument is at least well-formed.

- **Divergence to note:** pi is a ~136k-line TypeScript monorepo with 28
  provider integrations, an npm package ecosystem, and a differential-rendering
  TUI. Crescent is zero-dependency Lua with a vendored LuaJIT. Pi's
  *decomposition* transfers; its *scope* does not, and treating feature parity
  as a target would be a category error.

## Sources

All findings verified against a shallow clone of `main` on 2026-08-02 unless
otherwise noted. Repository metadata retrieved via `gh api repos/earendil-works/pi`.

- <https://github.com/earendil-works/pi> — repository, README
- `README.md`, `SECURITY.md`, `CONTRIBUTING.md`, `AGENTS.md` (repo root)
- `packages/agent/docs/agent-harness.md` — harness lifecycle, state model,
  phases, save points, error policy, implementation TODO
- `packages/agent/docs/harness.md`, `harness-v2.md`, `durable-harness.md`,
  `hooks.md`, `observability.md`, `models.md`
- `packages/agent/src/agent-loop.ts` — loop control flow
- `packages/agent/src/types.ts` — `AgentTool`, `AgentToolResult`, concurrency modes
- `packages/agent/src/harness/` — `agent-harness.ts`, `session/`, `compaction/`,
  `env/nodejs.ts`, `tools/`
- `packages/coding-agent/docs/security.md` — trust model, no-sandbox rationale
- `packages/coding-agent/docs/containerization.md` — Gondolin / Docker / OpenShell
- `packages/coding-agent/docs/session-format.md` — JSONL tree format, entry types,
  message types, context building, `SessionManager` API
- `packages/coding-agent/docs/compaction.md` — compaction and branch summarization
- `packages/coding-agent/docs/skills.md` — Agent Skills standard implementation
- `packages/coding-agent/docs/extensions.md` — `ExtensionAPI` surface, event families
- `packages/coding-agent/docs/rpc.md`, `sdk.md`, `json.md` — run modes
- `packages/coding-agent/README.md` — philosophy, explicit omissions
- `packages/coding-agent/examples/extensions/subagent/README.md` — subagent model
- `packages/ai/README.md` — provider list, tool schemas, auth, handoffs
- <https://pi.dev> — project website (referenced, not fetched)
- <https://mariozechner.at/posts/2025-11-02-what-if-you-dont-need-mcp/> — MCP
  rationale (referenced from README, not fetched)
- <https://mariozechner.at/posts/2025-11-30-pi-coding-agent/> — full rationale
  (referenced from README, not fetched)
- <https://rfc.earendil.com/keyword/pi/> — longer-term RFCs (referenced, not fetched)
