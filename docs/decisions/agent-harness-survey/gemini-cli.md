# Gemini CLI (Google) — agent harness prior art

Survey date: 2026-08-02. Repo verified live: <https://github.com/google-gemini/gemini-cli>,
Apache-2.0, ~106k stars, actively developed (docs in-tree under `docs/`, source under
`packages/`).

**Source confidence.** Everything below is from the repo itself — in-tree docs fetched
via the GitHub contents API and TypeScript source under `packages/core/src/`. Where a
claim comes from a doc rather than code it is a documented behavior, not a read of the
implementation; those are the ones to re-verify if a crescent decision hinges on exact
semantics. No third-party write-ups are load-bearing here.

## Overview

Gemini CLI is a terminal agent for Google's Gemini models. It is a Node/TypeScript
monorepo whose primary split is `packages/cli` (user-facing: input, rendering, themes,
slash commands, ACP server) and `packages/core` (backend: model communication, prompt
construction, tool registry, tool execution, session state). The CLI package is one
front-end over the core; a second front-end is **ACP mode** (`gemini --acp`), a JSON-RPC
2.0 stdio protocol for IDE integration, and a third is **headless mode** (`-p`, or any
non-TTY invocation) emitting either a single JSON object or newline-delimited JSONL
events (`init`, `message`, `tool_use`, `tool_result`, `error`, `result`).

Unlike opencode's client/server split, the boundary here is a *library* boundary
(`core` is imported by `cli`), not a network one. Sessions do not survive terminal death
by architecture; they survive by transcript recording plus an explicit resume command.

## Architecture

The control loop lives in `packages/core/src/core/client.ts` (`GeminiClient`),
with `turn.ts` (`Turn`) modelling a single model exchange and `geminiChat.ts` holding
history. `sendMessageStream` is an async generator that yields typed events
(`GeminiEventType.*`) to whichever front-end is attached — this is how one loop serves
the TUI, ACP, and headless JSONL without three loops.

Order of operations inside one turn (read from `client.ts`):

1. Increment session turn counter; bail with `MaxSessionTurns` if over
   `getMaxSessionTurns()`. The loop is also bounded by a `boundedTurns` parameter that
   decrements on each recursive continuation.
2. Context management: if the new context manager is enabled, `contextManager.renderHistory()`
   produces both the durable history and an `apiHistory` override, and the pending user
   prompt is **late-bound** — appended only for the upcoming API call, with the raw
   version kept for display/recording and the processed version for the API and durable
   history. Otherwise, fall back to `tryCompressChat()`.
3. Overflow guard: estimate request tokens against `tokenLimit(model) - lastPromptTokenCount`;
   if it will not fit, emit `ContextWindowWillOverflow` and stop rather than truncating
   blindly.
4. IDE context injection — explicitly *skipped* when the last history message contains a
   `functionCall`, because the Gemini API requires a `functionResponse` to immediately
   follow a `functionCall`. Deferred, not dropped.
5. Loop detection (`turnStarted`, then `addAndCheck` on every streamed event).
6. Model routing: sticky per sequence (`currentSequenceModel`), otherwise
   `ModelRouterService.route()` decides.
7. `turn.run(...)` streams; each event passes through the loop detector before being
   yielded onward.
8. If the turn produced no pending tool calls, a **`checkNextSpeaker` LLM call** decides
   whether the model should keep going; if it answers `model`, the loop recurses with a
   synthetic `Please continue.` user message and `boundedTurns - 1`.

That last step is a real design decision: continuation is a *model judgment*, not a
syntactic "did it call a tool" check. It costs an extra utility call per turn and has an
explicit escape hatch (`getSkipNextSpeakerCheck()`, and it is skipped when a quota error
has occurred).

Supporting services in `packages/core/src/services/` are granular and injected via a
`Config` object that doubles as a DI container: `shellExecutionService`, `gitService`,
`fileDiscoveryService`, `sandboxManager` (+ `sandboxManagerFactory`,
`sandboxedFileSystemService`), `chatRecordingService`, `loopDetectionService`,
`modelConfigService`, `trackerService`, `worktreeService`.

## Tool-Calling Protocol

Tools are native Gemini function calls (declaration + `functionCall`/`functionResponse`
parts), not a text protocol. A `ToolRegistry` owns the set; extension points are MCP
servers, a `tools.discoveryCommand` setting, and in-tree tool classes.

Every tool carries a **`Kind`** annotation — `Read`, `Edit`, `Search`, `Execute`,
`Fetch`, `Communicate`, `Plan`, `Think`, `Other` — and tool metadata hints such as
`readOnlyHint`. These are not cosmetic: policy rules can match on `toolAnnotations`, and
mode restrictions are expressed in terms of them.

Built-in set: `run_shell_command`; filesystem (`glob`, `grep_search`, `list_directory`,
`read_file`, `read_many_files`, `replace`, `write_file`); interaction (`ask_user`,
`write_todos`); web (`google_web_search`, `web_fetch`); MCP resource access
(`list_mcp_resources`, `read_mcp_resource`); memory/expertise (`activate_skill`,
`get_internal_docs`); planning (`enter_plan_mode`, `exit_plan_mode`); a subagent-only
`complete_task`; and an experimental task tracker (`tracker_create_task`,
`tracker_update_task`, `tracker_get_task`, `tracker_list_tasks`,
`tracker_add_dependency`, `tracker_visualize`) plus `update_topic`.

Notable protocol-level choices:

- **User-triggered tools.** `@path` in a prompt is sugar for `read_many_files`; `!cmd` is
  sugar for `run_shell_command`. The user's shorthand and the model's tool call go
  through the same path.
- **The agent's own todo list is a tool** (`write_todos`), and the experimental tracker
  goes further: tasks with typed dependencies and topological execution, i.e. a task
  graph the model manipulates through tool calls.
- **`ask_user` is a tool.** Clarification is a modelled action with structured
  `questions` (question, header, type, options), not an out-of-band UI convention.
- **Mode transitions are tools** (`enter_plan_mode` / `exit_plan_mode`), so the model can
  request its own permission-envelope change and the user approves it like any other call.
- **Documented JSON argument keys per tool**, published specifically so policy authors
  can write `argsPattern` regexes against a stable-stringified argument object.
- **Tool output masking**: `tryMaskToolOutputs()` runs over history each turn — old tool
  outputs are managed as a distinct class of context.

## Context/Memory Management

Four distinct mechanisms, deliberately separated:

**1. Hierarchical context files (`GEMINI.md`).** Loaded from `~/.gemini/GEMINI.md`, then
workspace directories and their parents, then **just-in-time**: when a tool touches a
file or directory, the CLI scans that directory and its ancestors up to a trusted root
for context files and pulls them in. Filenames are configurable
(`context.fileName: ["AGENTS.md", "CONTEXT.md", "GEMINI.md"]`). The footer shows the
loaded-file count. `/memory show|reload|inbox`.

**2. Memory import processor.** `@./file.md` inside a context file inlines another file.
Relative and absolute paths, nested imports, circular-import detection, configurable max
depth (default 5), `validateImportPath` against an allowed-directory list, and code-fence
awareness (uses `marked` so `@` inside code blocks is not an import). Returns an import
*tree* for debugging. The doc itself notes the tree "has limited relevance to LLM
consumption" — it is a developer-facing artifact.

**3. Compression.** `packages/core/src/context/chatCompressionService.ts`:
`DEFAULT_COMPRESSION_TOKEN_THRESHOLD = 0.5` of the model limit triggers compression;
`COMPRESSION_PRESERVE_THRESHOLD = 0.3` keeps the most recent 30% of history uncompressed;
`findCompressSplitPoint` picks a boundary. Separately,
`COMPRESSION_FUNCTION_RESPONSE_TOKEN_BUDGET = 50_000` drives a **reverse token budget**:
walk history backwards, tally function-response tokens, keep recent tool outputs at full
fidelity and truncate older ones once the budget is spent. Compression outcomes are
statuses, not booleans — including `COMPRESSION_FAILED_INFLATED_TOKEN_COUNT`, i.e. the
system detects when summarizing made things *bigger* and reports it.

A newer `ContextManager` (`packages/core/src/context/`) supersedes flat compression for
sessions where it is enabled: context is a **graph of nodes** rendered into API history
through a pipeline orchestrator, with an event bus, a tracer, invariant checking
(`checkContextInvariants`), render caching keyed by a node hash, and hysteresis counters
(`lastTriggeredDeficit`) to stop utility-call churn. Token accounting is closed-loop —
after each turn the real `promptTokenCount` from usage metadata is fed back
(`emitTokenGroundTruth`) against the estimate.

**4. Agent Skills.** Implements the [agentskills.io](https://agentskills.io) open
standard. A skill is a directory with a `SKILL.md`. At session start only **name and
description** are injected into the system prompt; the body is loaded only when the model
calls `activate_skill`, which also requires user consent and *adds the skill directory to
the agent's allowed file paths*. Discovery tiers, lowest to highest precedence: built-in,
extension, user (`~/.gemini/skills/` or `~/.agents/skills/`), workspace (`.gemini/skills/`
or `.agents/skills/`) — the `.agents/` alias exists explicitly for cross-tool
interoperability and wins over `.gemini/` within a tier.

**Auto Memory** (experimental, off by default) closes the loop: a background agent mines
idle past sessions (≥3h idle, ≥10 user messages, sub-agent sessions excluded) and drafts
memory updates as unified-diff `.patch` files and new skills as `SKILL.md` drafts into a
review **inbox**. It cannot write active memory files, settings, credentials, or project
`GEMINI.md`; patches are parsed, target-allowlisted, dry-run, and applied atomically only
on approval via `/memory inbox`.

**Loop detection** (`loopDetectionService.ts`) is a hybrid: cheap deterministic checks —
identical tool call repeated 5× (`TOOL_CALL_LOOP_THRESHOLD`), identical 50-char content
chunk seen 10× with a periodicity analysis to distinguish real loops from legitimate
repetition — plus, after 30 turns, a periodic **LLM judge** (dedicated
`loop-detection-double-check` model alias, structured schema, confidence threshold 0.9)
running on a self-adjusting 5–15 turn interval. Detection has two severities: count 1
triggers `_recoverFromLoop` (attempt recovery), count > 1 aborts the turn.

**Session persistence**: transcripts under `~/.gemini/tmp/<project>/chats/`, resumable
from CLI or interactively; `/rewind`; and **checkpointing** (off by default), which
commits a snapshot to a *shadow git repo* at `~/.gemini/history/<project_hash>` before
any file-mutating tool, together with the conversation history and the pending tool call.
`/restore` reverts files, restores history, and **re-proposes the original tool call**.
Git worktrees are a first-class parallel-session mechanism (`worktreeService`).

## Sandboxing & Permissions

Three independent layers.

**Layer 1 — Trusted Folders** (off by default). Before any project config is loaded, the
CLI runs a *discovery phase* that enumerates what the folder would activate — custom
commands, MCP servers, hooks, skills, settings overrides — surfaces security warnings
(e.g. "this project disables the sandbox"), and asks you to trust the folder or its
parent. Decisions persist in `~/.gemini/trustedFolders.json`. An untrusted folder runs in
safe mode: no workspace `settings.json`, no `.env`, no MCP connections, no custom
commands, no extension management, no auto-accept. An IDE trust signal outranks the local
file. Headless + untrusted = `FatalUntrustedWorkspaceError` unless `--skip-trust`.

**Layer 2 — Policy Engine** (`packages/core/src/policy/`, TOML rules). Declarative rules
matching on `toolName` (with `*`, `mcp_server_*`, `mcp_*_toolName` wildcards), `mcpName`,
`toolAnnotations`, `argsPattern` (regex over a stable JSON stringification of arguments),
`commandPrefix`/`commandRegex` sugar for shell, `subagent` (which agent is calling),
`interactive` (interactive vs headless), and `modes`. Decisions: `allow`, `deny`,
`ask_user` (which degrades to `deny` in non-interactive mode), with an optional
`denyMessage` returned to the model explaining *why*.

Two decisions worth stealing:

- **A global `deny` removes the tool from the model's declarations entirely** — the model
  never sees the tool exists. Cited as both more secure and context-window cheaper. This
  is the stated replacement for the deprecated `tools.exclude` setting.
- **Priority is tiered and monotone.** Tiers Default(1) < Extension(2) < Workspace(3) <
  User(4) < Admin(5); an in-file priority of 0–999 becomes
  `final = tier_base + (priority / 1000)`. A tier can never be out-prioritized by a lower
  tier no matter what number an author writes. (Workspace tier is currently disabled —
  issue #18186.) Admin policy directories are validated for ownership/ACLs before being
  honored, and supplemental `--admin-policy` paths are ignored entirely if standard-location
  policies exist.

Approval modes form a permissiveness lattice — `plan` < `default` < `autoEdit` < `yolo` —
and "allow for all future sessions" grants only to the current mode *and more permissive
ones*. Approving something in `default` never weakens `plan`. Approving in `plan` is read
as deliberate global trust and grants all modes.

**Layer 3 — Process/OS sandbox.** `GEMINI_SANDBOX=true|docker|podman|sandbox-exec|runsc|lxc`,
or `-s`, or `tools.sandbox` in settings. Options:

- **macOS Seatbelt** via `sandbox-exec`, six named `.sb` profiles across two axes —
  permissive/restrictive/strict × open/proxied — selected by `SEATBELT_PROFILE`, default
  `permissive-open` (deny-by-default, writes confined to the project, broad reads,
  network allowed).
- **Docker/Podman**, default image `ghcr.io/google/gemini-cli:latest`; the workspace is
  mounted **at its exact host absolute path** inside the container, so every path the
  model reasons about is identical on both sides. Custom images via `GEMINI_SANDBOX_IMAGE`
  or an auto-built `.gemini/sandbox.Dockerfile` (`BUILD_SANDBOX=1`, source installs only).
- **gVisor/runsc** (Linux) — `docker run --runtime=runsc`, never auto-detected, must be
  named explicitly.
- **LXC/LXD** (Linux, experimental) for tools needing a full systemd userland
  (snapcraft/rockcraft); the container must already exist — the CLI will not create one.
- **Windows native**, using `icacls` low-integrity levels — with the documented caveat
  that the integrity change *persists on disk* after the session ends.

Two further decisions here:

- **Tool-level sandboxing** (`security.toolSandboxing`, on by default) sandboxes
  individual tool executions rather than the whole CLI process, so UI, config loading,
  and credentials stay on the host while shell/write go into the jail. Full-process
  isolation is the opt-out, not the default.
- **Sandbox expansion**: when a sandboxed command fails on a permission denial — or is
  proactively recognized as needing more (e.g. `npm install`) — the user gets a modal
  naming the specific extra permissions, granted **for that single run**. Escalation is
  incremental and scoped instead of forcing a restart under a looser profile.

`SANDBOX_MOUNTS` (`from:to:opts`, default `ro`) adds host paths; `SANDBOX_FLAGS` injects
raw container flags; `SANDBOX_SET_UID_GID` controls Linux UID/GID mapping.

**Hooks** are the fourth, user-programmable interception layer: external commands run
synchronously at `SessionStart`, `SessionEnd`, `BeforeAgent`, `AfterAgent`, `BeforeModel`,
`AfterModel`, `BeforeToolSelection`, `BeforeTool`, `AfterTool`, `PreCompress`,
`Notification`. JSON over stdin/stdout, stderr for logging, exit code 0 = parse stdout as
JSON (including `{"decision":"deny"}`), exit code 2 = hard block with stderr as reason,
anything else = warning and proceed. `BeforeToolSelection` can filter the tool set before
the model ever sees it. Project hooks are **fingerprinted by name+command**: a `git pull`
that changes a hook makes it untrusted again and re-prompts. Hooks get
`GEMINI_PROJECT_DIR`, `GEMINI_PLANS_DIR`, `GEMINI_SESSION_ID`, `GEMINI_CWD` — and
`CLAUDE_PROJECT_DIR` as a deliberate compatibility alias.

## Multi-Agent Support

Subagents are first-class (`packages/core/src/agents/`) and exposed to the main agent
**as tools named after the agent**, dispatched through a unified `invoke_agent` tool.

Definition format: Markdown with YAML frontmatter in `.gemini/agents/*.md` (project) or
`~/.gemini/agents/*.md` (user). Body = system prompt. Frontmatter: `name`, `description`
(required — this is what the main agent reads to decide delegation), `kind`
(`local`|`remote`), `tools` (list, wildcards `*` / `mcp_*` / `mcp_server_*`; **omitted
means inherit everything from the parent**), `mcpServers` (MCP servers scoped to *this
agent only*), `model` (default `inherit`), `temperature` (default 1), `max_turns`
(default 30), `timeout_mins` (default 10).

Built-ins: `codebase_investigator`, `cli_help`, `generalist` (inherits full parent
toolset; for multi-file edits and high-output command runs), and `browser_agent`
(off by default; drives `chrome-devtools-mcp` over the accessibility tree, with optional
`visualModel` for coordinate-based clicking, `allowedDomains`, `maxActionsPerTask` = 100,
mandatory confirmation on form fill, and automatic degradation under sandboxes —
forced `isolated`+`headless` under seatbelt, disabled under Docker unless attaching to a
host Chrome on `host.docker.internal:9222`).

Execution contract (`local-executor.ts`): a subagent must terminate by calling the
mandatory **`complete_task`** tool — the only way to return a result to the parent. If
the model simply stops calling tools without it, the run ends in
`AgentTerminateMode.ERROR_NO_COMPLETE_TASK_CALL`. Terminate modes are enumerated
(`GOAL`, `TIMEOUT`, `MAX_TURNS`, `ABORTED`, `ERROR`, `ERROR_NO_COMPLETE_TASK_CALL`), and
on any non-goal termination the executor injects a **grace-period message** — "you have
one final chance… you MUST call `complete_task` immediately with your best answer and
explain that your investigation was interrupted" — under a separate grace timeout, so a
timed-out or turn-capped agent still returns a usable partial answer instead of nothing.

Isolation is enforced in three ways: independent context loop (subagent history never
enters the parent's), an isolated tool registry per agent (explicitly described as moving
away from "a single global tool registry"), and policy rules keyed on the executing
`subagent`. **Recursion is banned**: subagents cannot invoke subagents even under the `*`
wildcard.

Invocation is either automatic (main agent picks based on `description` — the docs advise
tuning delegation reliability by rewriting the description, and even suggest asking the
model why it didn't pick your agent) or explicit via `@agent-name`, which injects a
system note nudging the model to call that tool immediately. Note the mechanism: even
"forced" delegation is a nudge to the model, not a bypass of it.

**Remote subagents** speak the **Agent2Agent (A2A)** protocol (`kind: remote`), with
agent cards (fetched or inline), proxy support, and four auth types: `apiKey`, `http`,
`google-credentials` (ADC), and `oauth` — with dynamic value substitution, validation,
and retry behavior. Delegation crosses machine boundaries over an open protocol.

Governance: `/agents` for interactive management, `agents.overrides` in `settings.json`
for `enabled`/`runConfig`/`modelConfig` per agent, `modelConfigs.overrides` with
`overrideScope` for per-agent generation settings, policy TOML for hard denial, and
`experimental.enableAgents: false` to kill the whole subsystem. Extensions can bundle and
distribute subagents.

## Notable Design Decisions

1. **Permission is data, not code.** The policy engine is declarative TOML with a
   monotone tier formula, evaluated in one place, matching on tool name, annotations,
   arguments, caller subagent, interactivity, and mode. Approval logic is not scattered
   through tool implementations.
2. **Denial edits the model's world, not just the outcome.** A global `deny` removes the
   tool declaration; the model cannot want what it cannot see. Security and context
   economy give the same answer.
3. **Trust is decided before config is loaded, with an inventory.** The trust dialog
   enumerates the commands, MCP servers, hooks, and skills a folder would activate and
   flags the dangerous ones. Consent is informed by discovery, not by a yes/no on a path.
4. **Permission relaxations flow one way along a mode lattice.** `plan < default <
   autoEdit < yolo`; a persistent approval propagates only toward more permissive modes.
5. **Escalate per-invocation, not per-session.** Sandbox expansion grants exactly the
   denied permission for exactly one run.
6. **Mode changes and clarification are tool calls.** `enter_plan_mode`, `exit_plan_mode`,
   `ask_user` — capability changes and human input go through the same approval path as
   everything else. Plan Mode's write allowance is scoped to `.md` files under the plans
   directory, so "writing the plan" needs no exception to the read-only rule.
7. **Sandbox the tools, not the process.** Default is per-tool-execution isolation; the
   UI, config, and credentials stay native. Whole-process isolation is available but opt-in.
8. **Path identity across the sandbox boundary.** Container mounts use the exact host
   absolute path, so no path translation layer exists to get wrong.
9. **Continuation is a model decision.** `checkNextSpeaker` spends a utility LLM call to
   ask whether the model should keep talking, with hard turn bounds underneath as the
   safety net.
10. **Loop detection is layered cheap-then-expensive.** Deterministic counters with
    periodicity analysis first; an LLM judge only after 30 turns, on an adaptive interval,
    behind a 0.9 confidence gate. And detection has a recovery path before it has an
    abort path.
11. **Subagents must explicitly finish, and are coerced into finishing.** `complete_task`
    is mandatory; timeout and max-turns trigger a grace period demanding a partial answer.
    Failure to terminate correctly is its own enumerated error mode.
12. **Delegation is described, not routed.** Which specialist runs is chosen by the model
    from `description` text. The documented tuning method is prose editing, and even
    `@agent` is a nudge. Cost of the choice: no deterministic dispatch.
13. **Recursion is banned outright** rather than depth-limited.
14. **Progressive disclosure of expertise.** Skills inject only name+description up front;
    bodies and file access arrive on activation, with consent, and activation *expands the
    filesystem allowlist* — capability and context are granted together.
15. **The agent's plan is structured state the agent mutates.** `write_todos`, and the
    experimental tracker with typed dependencies and topological ordering.
16. **Undo is a shadow git repo.** Snapshots never touch the user's repository, and
    `/restore` re-proposes the tool call it interrupted rather than just rolling files back.
17. **Compression reports failure modes, including inflation**, and preserves recent tool
    output at full fidelity via a reverse token budget rather than treating all history as
    uniform text.
18. **Token accounting is closed-loop** — real `promptTokenCount` is fed back against the
    estimator every turn.
19. **Memory can be mined from transcripts, but only into a review inbox** — patches are
    dry-run and target-allowlisted, and the extractor is forbidden from touching active
    memory, settings, credentials, or shared project context.
20. **Interoperability chosen over lock-in in three visible places**: the `.agents/skills/`
    path alias (which *outranks* `.gemini/`), the `CLAUDE_PROJECT_DIR` hook env alias, and
    `context.fileName` accepting `AGENTS.md`. Plus MCP, ACP, and A2A as the three external
    protocol surfaces.
21. **Failure has degraded modes, not just errors.** Rate limit → model fallback (with
    consent for the main model, silent for utility calls); high-reasoning model
    unavailable → silent downgrade; Plan Mode routes to Pro and implementation to Flash
    automatically based on whether an approved plan exists.
22. **Hooks are fingerprinted.** A project hook whose command changes under you becomes
    untrusted again.

## Relevance to Crescent

Read as input to designing an agent app under `lib/platform/apps/` and expanding
`lib/ai`. Crescent today has `lib/ai/tools.lua` (a single `run` agentic loop taking
`tools`, `handlers`, `max_rounds`) and `lib/taskgraph` (graph, frontier, executor,
combinators). Observations, not recommendations:

- **Permission-as-declarative-data is the cleanly separable piece.** A rule table matched
  on tool name / argument pattern / caller / mode, evaluated in one function, would sit
  naturally beside `lib/ai/tools.lua` without touching handler implementations. The
  monotone tier formula (`tier_base + priority/1000`) is a small trick that makes
  precedence unforgeable by rule authors. This is also the piece most at risk of becoming
  special-cased if grown incrementally per-tool.
- **Tool `Kind`/annotation metadata is the enabling substrate** for everything in the
  permission layer, plan mode, and subagent tool scoping. In Gemini CLI, mode restrictions
  and policy matching are both expressed over annotations. If crescent wants any of
  those consumers, the annotation field on the tool descriptor has to exist first.
- **Denial by declaration removal** (rather than post-hoc rejection) maps directly onto
  how `lib/ai/tools.lua` builds the tool list per round.
- **`complete_task` + enumerated terminate modes + a grace period** is a concrete contract
  for how a delegated agent returns a value — relevant if `lib/taskgraph` nodes are ever
  to host agents. Gemini CLI's version is a protocol, not a convention: "stopped calling
  tools" is an error, not a success.
- **Gemini CLI's task tracker overlaps `lib/taskgraph` directly** — typed dependencies,
  topological execution, visualization — but exposes it *to the model as tools* rather
  than driving the model from the graph. That is a genuine branch point for crescent
  (model-manipulates-graph vs graph-orchestrates-model), and it is a design question for
  the owner, not something this survey settles.
- **Caps-first alignment.** `sandboxedFileSystemService`, ACP's proxied filesystem, and
  skill activation expanding an explicit path allowlist are all capability-shaped: the
  agent gets a filesystem object, not ambient access. This matches crescent's caps rule
  more closely than the rest of the design does.
- **Poor fit, noted honestly.** Container/seatbelt/gVisor sandboxing conflicts with
  zero-dependency and "pure Lua is the baseline" — those are system tiers with no pure-Lua
  fallback, so at most a top tier under the usual tier discipline. The heavy context
  pipeline (node graph, event bus, tracer, hysteresis) is a large substrate to justify
  before there is a context problem to solve. `checkNextSpeaker` costs a model call per
  turn. And description-based delegation is the opposite of deterministic dispatch, which
  is what `lib/taskgraph` currently provides.

## Sources

All fetched 2026-08-02 from `google-gemini/gemini-cli`, branch `main`.

Docs (in-tree):

- `docs/core/index.md` — core role, compression, model fallback, discovery services
- `docs/core/subagents.md` — subagent format, isolation, built-ins, browser agent
- `docs/core/remote-agents.md` — A2A remote subagents, auth
- `docs/reference/policy-engine.md` — TOML rules, tiers, decisions, modes
- `docs/reference/tools.md` — tool inventory, kinds, JSON argument keys
- `docs/reference/memport.md` — memory import processor
- `docs/cli/sandbox.md` — sandbox modes, profiles, expansion, mounts
- `docs/cli/trusted-folders.md` — trust discovery and safe mode
- `docs/cli/gemini-md.md` — context hierarchy, JIT context
- `docs/cli/skills.md` — Agent Skills, discovery tiers
- `docs/cli/auto-memory.md` — transcript mining, review inbox
- `docs/cli/plan-mode.md` — plan mode restrictions, model routing
- `docs/cli/checkpointing.md`, `docs/cli/session-management.md`, `docs/cli/rewind.md`
- `docs/cli/model-routing.md`, `docs/cli/headless.md`, `docs/cli/acp-mode.md`
- `docs/hooks/index.md` — hook events, exit codes, fingerprinting

Source:

- `packages/core/src/core/client.ts` — main loop, compression trigger, routing,
  `checkNextSpeaker`, loop-detector integration
- `packages/core/src/core/turn.ts`, `packages/core/src/core/geminiChat.ts`
- `packages/core/src/agents/local-executor.ts` — `complete_task`, terminate modes,
  grace period
- `packages/core/src/services/loopDetectionService.ts` — thresholds, LLM judge
- `packages/core/src/context/chatCompressionService.ts` — compression + reverse token
  budget constants
- `packages/core/src/context/contextManager.ts` — context graph pipeline
- `packages/core/src/policy/`, `packages/core/src/services/` (file listing)

Repo landing page: <https://github.com/google-gemini/gemini-cli>
