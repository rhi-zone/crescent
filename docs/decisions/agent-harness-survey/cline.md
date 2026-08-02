# Cline — Agent Harness Survey

Survey of `github.com/cline/cline` as prior art for an agentic harness. Focus is
on the *decisions* the project made and the reasoning it published for them, not
a feature catalogue.

Repo existence verified by fetching `https://github.com/cline/cline` (Apache-2.0,
"Autonomous coding agent as an SDK, IDE extension, or CLI assistant"; formerly
"Claude Dev").

Caveat on evidence quality: primary source reads here are the GitHub README,
`cline/prompts` architecture rules, the official docs site, and Cline's own
release blog. Structural detail about internal classes comes from DeepWiki, an
LLM-generated code wiki over the repo — directionally reliable for naming and
layering, but not a substitute for reading the source. Statements sourced only
from DeepWiki or third-party write-ups are marked *(secondary)*. Cline is also
moving fast; several described mechanisms replaced earlier ones within the last
year, so version drift is a real risk for anything below.

## Overview

Cline started as a VS Code extension ("Claude Dev") that put a single autonomous
coding agent in a sidebar webview. It has since been restructured into a
**core runtime with multiple frontends**: VS Code extension, JetBrains plugin,
CLI (Ink-based TUI plus a headless CI mode), an SDK (`@cline/sdk`), and a
web Kanban board. All frontends share one `ClineCore` runtime *(secondary)*.

The product's defining stance is **human-in-the-loop by default**: the agent
proposes; the human approves each file edit and each command, unless approval is
explicitly delegated per-category. Everything else in the design — Plan/Act
modes, shadow-git checkpoints, the approval taxonomy — follows from taking that
stance seriously and then trying to reduce its friction without abandoning it.

Model-agnostic by design: Anthropic, OpenAI, Gemini, Bedrock, Ollama and local
models, plus ~200 more via OpenRouter, behind a unified provider gateway.

## Architecture

**Three-tier separation (VS Code extension):** `WebviewProvider → Controller →
Task`.

- `WebviewProvider` owns IDE integration and lifecycle.
- `Controller` is "the single source of truth for the extension's state" —
  global state, workspace state, secrets — and manages the lifecycle of tasks.
- `Task` is one AI work session: it runs the agentic loop, issuing API requests
  and executing tools.

The decision worth noting is that **state authority sits above the agent loop,
not inside it**. A `Task` can be created, interrupted, resumed, or discarded
without the state layer being disturbed; conversation history and checkpoints are
persisted per-task as files rather than living in the loop's memory.

**Package layering** *(secondary)*: `@cline/shared` (utilities), `@cline/llms`
(model catalog + provider gateway), `@cline/agents` (`ToolOrchestrator`,
dispatch), `@cline/core` (orchestration).

**Host bridge / platform abstraction.** File operations, terminal integration,
and browser automation are accessed through a host-provider abstraction rather
than called directly. This is what makes the same core logic run under VS Code,
the CLI, and the SDK. Frontend↔backend communication is typed: protobuf schemas
with a gRPC service layer, and `postMessage` for the webview boundary
*(secondary)*.

**The loop itself is described as stateless** *(secondary)*: session init →
stream LLM response → dispatch tools → suspend for approval → feed results back.
State that must survive lives in the Controller and on disk, not in loop-local
variables. This is the structural reason task resumption works at all.

**Streaming with a presentation lock.** Model output is parsed incrementally
(reasoning / text / tool invocations) as it streams, and a lock serializes
stream-chunk → parse → state-update → UI-present to avoid races between the
streaming parser and the UI *(secondary)*. File edits stream into VS Code's
native diff viewer as they arrive rather than landing atomically at the end.

**Error recovery** is explicitly designed for: automatic retry on transient API
failures, user-prompted retry on persistent ones, and defined handling for tool
executions interrupted mid-flight when a task is resumed.

## Tool-Calling Protocol

This is the clearest *reversed decision* in the project, and the reversal is
instructive.

**Original design — XML-in-text.** Tools were described in the system prompt and
the model emitted XML-tagged calls in its ordinary text output:

```
<tool_name>
  <parameter1_name>value1</parameter1_name>
</tool_name>
```

with the hard rule "you can use one tool per message, and will receive the result
of that tool use in the user's response, with each tool use informed by the
result of the previous tool use." The rationale was **reach**: any model that can
generate text can drive the agent, including models with no native tool-calling
API. Strict one-tool-per-message also made the loop trivially serializable and
made each approval gate correspond to exactly one action.

**Current design — native tool calling** (shipped v3.35). Tool definitions are
sent as JSON schemas through the provider's native tool API. Cline's published
reasons:

1. Models "were specifically trained to produce" their native JSON format, so
   fewer malformed/invalid responses.
2. It enables **parallel tool execution**, which one-tool-per-message forbade.
3. ~15% fewer tokens per request, since tool descriptions leave the prompt body.

**Both paths are kept.** Native calling is used for model families that support
it well (Claude 4+, Gemini 2.5, Grok 4/Grok Code, GPT-5 excluding gpt-5-chat);
older models fall back to the XML text protocol. The protocol is a property of
the model family, not of the harness.

**Tool set consolidation** *(secondary)*. The current default tool set is small
and multi-target: `read_files` (multiple files, line ranges), `run_commands`
(non-interactive shell), `search_codebase` (regex), `edit_file` (exact match or
insertion), `skills` (invoke specialized sub-agents/skills). This is a
significant narrowing from the earlier one-file-at-a-time `read_file` /
`write_to_file` / `replace_in_file` trio, and pairs with the parallel-execution
capability native tool calling unlocked.

**Loose schemas as a compatibility layer** *(secondary)*. Tool inputs are Zod
schemas written deliberately permissively — a model may emit `path`, `file_path`,
or `filePath` and all are accepted. The harness absorbs cross-model naming
variance instead of requiring every model to conform. This is a conscious
decision to make the tool boundary tolerant rather than strict.

**MCP tools are namespaced on injection** so dynamically-loaded external tools
cannot collide with built-ins.

**Prompt variants are selected by model family and mode** via a `ModelFamily`
enum at task init, with mustache placeholders (`{{PLATFORM_NAME}}`,
`{{CURRENT_DATE}}`, `{{IDE_NAME}}`, `{{CWD}}`, `{{CLINE_RULES}}`) filled at
runtime. There is a separate `YOLO_CLINE_SYSTEM_PROMPT` for autonomous operation
which restricts user communication, mandates test verification, and requires a
`submit_and_exit` call — i.e. the *prompt* changes, not just the permission
settings, when the human leaves the loop *(secondary)*.

## Context/Memory Management

**Threshold-triggered compaction, not continuous trimming** *(secondary)*.
Compaction fires at `COMPACTION_TRIGGER_RATIO = 0.9` of the effective limit and
targets `DEFAULT_TARGET_RATIO = 0.7`. The effective limit is derived by comparing
the model's `maxInputTokens` against its `contextWindow`, defaulting to 90% of
context size when `maxInputTokens` is unknown — a buffer for response generation
and overhead, with per-model adjustments (DeepSeek and Claude are called out).

The hysteresis (trigger 90%, target 70%) is the decision: compacting to *just
under* the trigger would cause repeated compaction on every subsequent turn.

**Two compaction strategies, user-selectable:**

- **Basic** — deterministic. Collapses adjacent user messages, strips older file
  attachments, and replaces dropped work with system-generated summaries of tool
  activity. Keeps the most recent assistant responses (default: 3). No model
  call, no nondeterminism.
- **Agentic** — a secondary LLM call produces a condensed summary of the session,
  explicitly emphasising detailed next steps, before the main request continues.

Offering both is a real tradeoff acknowledgement: deterministic compaction is
cheap and predictable but lossy in ways the agent can't recover from; LLM
compaction preserves intent better but costs a call and can hallucinate.

**Deduplication via file/model tracking** *(secondary)*. The system records
historical file operations so already-referenced content is not re-expanded into
context. The `@`-mention system (`@file`, `@url`, `@problems`, `@terminal`)
resolves references into expanded content blocks, and dedup applies to those
expansions.

**Concurrency discipline around compaction** *(secondary)*: an exclusive lock
holds during the read-compact-persist sequence so no new messages interleave.
Compacted state is written as a sidecar file for resumption. This is the kind of
detail that only shows up after the naive version corrupted someone's session.

**Handoff instead of infinite context.** When context pressure meets conditions
the user defined in `.clinerules`, Cline finishes the current step and invokes
its `new_task` tool, *proposing* a fresh session and showing the structured
context it intends to preload. The decision here is that context exhaustion is
handled by a visible, user-approved boundary rather than by silently degrading.

**Persistent project memory** lives in `.clinerules/` — a directory of `.md`/
`.txt` files in the project root, merged into a single context block. It is
version-controlled, human-editable, and editable by the agent itself. Layered on
top: "memory bank" files (project brief, architecture patterns, active context)
and file-context scoring by recency/frequency/modification *(secondary)*.

## Sandboxing & Permissions

Cline does **not** sandbox. There is no container, no syscall filter, no
filesystem jail. The entire safety model is **approval plus reversibility**, and
this is the deliberate architectural bet: the agent runs with the user's full
privileges, and safety comes from the human gate in front of each action and the
undo behind it.

**The approval taxonomy** — eight categories, with "outside workspace" as a
separate escalation from "inside workspace":

1. Read project files (workspace only)
2. Read all files (outside workspace; requires the base toggle)
3. Edit project files (workspace only)
4. Edit all files (outside workspace; requires the base toggle)
5. Execute safe commands
6. Execute all commands (requires the base toggle)
7. Use the browser
8. Use MCP servers

The workspace boundary being a *permission dimension* rather than a hard
enforcement boundary is the notable choice — crossing it is a thing the user
grants, not a thing the runtime prevents.

**Model-declared risk.** Cline does not maintain a fixed command allowlist.
Instead the model marks each command with a `requires_approval` flag based on the
command and its arguments; "Execute safe commands" auto-approves only what the
model flagged as safe. Build commands and read-only queries are cited as typical
safe cases; deletions and dependency installs typically require approval.

This is the most consequential and most debatable decision in the whole design:
**the entity being restricted is also the entity classifying the risk.** It buys
enormous flexibility over an allowlist — no rule needs to anticipate every shell
invocation — at the cost of a trust boundary that is only as good as the model's
judgement and only as robust as the prompt is to injection.

**YOLO mode** removes all gates: files, commands, browser, MCP tools, and even
Plan→Act transitions execute without intervention. The docs are blunt that this
"disables all safety checks" and recommend isolated environments and version
control as the compensating controls — an explicit acknowledgement that the
safety model is *not* in the runtime.

**Simplification over configurability** (v3.35). The auto-approve UI moved from a
popup to an inline expanding menu, "Read" and "Read (all)" were consolidated,
auto-approve became enabled by default, and the main toggle switch, the favorites
system, and the **max-requests limit** were removed as "unnecessarily complex for
typical workflows." Deleting the max-requests cap is a real safety-surface
reduction traded for UX; worth flagging rather than copying uncritically.

**Checkpoints are the reversibility half of the bet.** Cline maintains a
**shadow git repository**, separate from the user's own git history, and commits
workspace state after each tool use. Each snapshot links to a `ClineMessage` by
timestamp. Three restore modes:

| Mode | Value | Effect |
|---|---|---|
| Files & Task | `taskAndWorkspace` | Revert files and truncate messages after the checkpoint |
| Files Only | `workspace` | Revert files, keep conversation |
| Task Only | `task` | Truncate messages, leave files |

Untracked files are captured. Nested `.git` directories are temporarily renamed
to `.git_disabled` during staging to avoid submodule conflicts, and workspaces
are keyed by a 13-character numeric hash of their absolute path *(secondary)*.

The decision to use a *shadow* repo rather than the project's own git is what
makes autonomous operation tolerable: the agent can commit constantly without
polluting history the user cares about, and rollback never fights the user's own
staged work.

## Multi-Agent Support

Multi-agent arrived late and sits above the single-agent core rather than being
woven through it.

- **Skills / subagents.** The `skills` tool invokes specialized sub-agents. This
  is the in-loop form of delegation: a tool call that happens to run another
  agent, so it needs no change to the loop's control flow.
- **Multi-agent teams.** A lead/coordinator agent decomposes work into subtasks
  and delegates to specialist agents, each with its own tools and context. Team
  state persists across sessions.
- **Kanban board + worktrees.** Parallel work is backed by separate git
  worktrees, one per card. Isolation between concurrent agents is achieved by
  giving each a physically separate checkout rather than by any in-process
  mechanism.
- **`new_task`** is the sequential form of the same idea: hand structured context
  to a fresh session instead of growing one forever.
- **Scheduled agents** run on cron; messaging integrations (Slack, Telegram,
  Discord) let a human interact from chat.

The pattern: **isolation is achieved with filesystem and process boundaries the
OS already provides** (worktrees, separate sessions), not with a bespoke
in-process agent runtime.

## Notable Design Decisions

1. **Approval + reversibility instead of sandboxing.** The safety model is
   entirely social/procedural, backed by shadow-git undo. No isolation
   primitive is used anywhere.
2. **The model classifies its own actions' risk** (`requires_approval`) in place
   of a static allowlist. Maximum flexibility, minimum enforceability.
3. **Plan/Act as separate prompts and separate tool sets**, not a mood. Plan mode
   is read-only and its main escalation capability is the `switch_to_act_mode`
   tool — the agent must *ask* to gain write access. Mid-task switching rebuilds
   the session runtime and injects a `<mode_notice>` ("The user switched from
   plan mode to act mode before sending this message") so the model is told
   explicitly that its authority changed. Mode persists in `global-settings.json`
   under `planActMode` *(secondary)*. Cline also markets Plan mode on cost:
   planning is far cheaper than generating implementations the user then rejects.
4. **Tool protocol is a property of the model family.** XML-in-text and native
   JSON coexist permanently; the harness picks per model. Reach for weak models
   was not sacrificed to get quality on strong ones.
5. **Loose input schemas** absorb cross-model parameter-naming variance rather
   than demanding conformance.
6. **Shadow git**, not the user's git, for checkpoints.
7. **Stateless loop, external state authority** — the precondition for resume,
   rollback, and running the same core under four different frontends.
8. **Host-provider abstraction as the portability seam**, with protobuf/gRPC
   typing the frontend boundary.
9. **Hysteresis in compaction** (0.9 trigger / 0.7 target) and **two compaction
   strategies** with different determinism/fidelity tradeoffs.
10. **Context exhaustion surfaces as a proposed handoff**, not as silent
    truncation.
11. **`.clinerules` as an agent-writable, version-controlled system prompt.**
    Project memory is a file in the repo, reviewable in PRs.
12. **UI simplification has removed safety affordances** (max-requests cap,
    auto-approve master toggle). Evidence that approval-fatigue pressure erodes
    approval-based safety models over time.

## Relevance to Crescent

Crescent's current state (`lib/ai/tools.lua`, 79 lines): `mod.run` is a bounded
loop — copy messages, call `ai.generate`, if `res.tool_calls` is empty return,
else dispatch each call through `opts.handlers[tc.name]` under `pcall`, append
results, repeat up to `max_rounds` (default 10). Providers exist for Anthropic,
Google, and OpenAI-compatible endpoints. `lib/taskgraph/` provides graph, exec,
frontier, and context modules.

Points of contact, stated as observations rather than recommendations:

- **The loop shape already matches.** Cline's core cycle is the same
  generate → dispatch → append → repeat that `tools.lua` implements. What Cline
  has that `tools.lua` does not is everything *around* the loop: state authority
  outside it, approval suspension inside it, and persistence beneath it. If an
  agent app is built under `lib/platform/apps/`, the question of whether loop
  state lives in the loop or in an external owner is the first fork, and Cline's
  answer (external) is what buys resume and rollback.
- **Approval is a suspension point in the loop, not a wrapper around it.** In
  Cline the loop halts mid-tool-dispatch awaiting a decision. `tools.lua`
  currently dispatches unconditionally. Adding approval later is a control-flow
  change, not a config change.
- **Crescent's caps-first rule is a stronger position than Cline's.** Cline's
  entire permission model exists because its tools reach for ambient capability
  (fs, shell, network) and must be gated after the fact. Crescent libraries take
  caps by injection and error when a cap is absent — which means the "what can
  this agent touch" question can be answered by *what caps were handed to the
  tool handlers*, structurally, rather than by an approval prompt. The eight-way
  category taxonomy and the `requires_approval` self-classification are both
  workarounds for not having that. This is worth noting as a place where copying
  the prior art would be a downgrade.
- **The `requires_approval` decision is the one to examine hardest.** It is
  distinctive, it is why Cline feels fluid, and it makes the model both the
  actor and the risk assessor. Any crescent design that gates on model-declared
  intent inherits that property.
- **Shadow-git checkpointing is orthogonal to everything else** and is the
  mechanism that makes autonomous runs recoverable. It requires no agent
  cooperation, which is precisely why it works when the agent misbehaves.
- **`lib/taskgraph` and Cline's multi-agent layer solve overlapping problems
  from opposite directions.** Cline bolted coordination on top of a single-agent
  loop late (coordinator agent + worktrees + Kanban). Crescent already has a
  graph/frontier/exec substrate. Whether the agent loop becomes a taskgraph node
  or taskgraph becomes a tool the agent calls is a design fork Cline's history
  does not resolve — but its outcome (isolation via worktrees, not via
  in-process machinery) is a data point.
- **Protocol pluralism.** Cline maintains two tool-call encodings permanently
  because model capability is not uniform. `lib/ai/providers/` already has
  per-provider modules; whether tool-call encoding is a provider concern or a
  loop concern is the analogous decision.
- **Compaction is absent from `tools.lua`.** `max_rounds` is the only bound, and
  it bounds iterations, not tokens. Cline's 0.9/0.7 hysteresis and its
  deterministic-vs-LLM strategy split are the concrete prior art if that gap is
  closed.

## Sources

- [github.com/cline/cline (README)](https://github.com/cline/cline) — primary
- [cline/prompts — .clinerules/cline-architecture.md](https://github.com/cline/prompts/blob/main/.clinerules/cline-architecture.md) — primary
- [Cline docs — Auto Approve & YOLO Mode](https://docs.cline.bot/features/auto-approve) — primary
- [Cline docs — Checkpoints](https://docs.cline.bot/core-workflows/checkpoints) — primary
- [Cline blog — v3.35: Native Tool Calling, Auto-Approve Menu](https://cline.bot/blog/cline-v3-35) — primary
- [Cline blog — Context Window Explained](https://cline.bot/blog/clines-context-window-explained-maximize-performance-minimize-cost) — primary
- [Cline blog — v3.31: Voice Mode, YOLO Mode](https://cline.bot/blog/cline-v3-31) — primary
- [Cline on X — native tool calling migration](https://x.com/cline/status/1984334385626411397) — primary
- [DeepWiki — cline/cline overview](https://deepwiki.com/cline/cline) — secondary (LLM-generated)
- [DeepWiki — Plan and Act Modes](https://deepwiki.com/cline/cline/3.4-plan-and-act-modes) — secondary
- [DeepWiki — Context Management](https://deepwiki.com/cline/cline/3.5-context-management) — secondary
- [DeepWiki — System Prompts and Tool Definitions](https://deepwiki.com/cline/cline/4.6-system-prompts-and-tool-definitions) — secondary
- [DeepWiki — Checkpoints and Snapshots](https://deepwiki.com/cline/cline/10.1-checkpoints-and-snapshots) — secondary
- [Dwarves Memo — Cline breakdown](https://memo.d.foundation/breakdown/cline) — third-party
- [Latent Space — Cline: The Open Source Code Agent](https://www.latent.space/p/cline) — third-party
- [cline/cline Discussion #2253 — Command Auto-Approval Rules](https://github.com/cline/cline/discussions/2253) — primary (community)
- [cline/cline Discussion #1007 — Multi-Agent Software Development](https://github.com/cline/cline/discussions/1007) — primary (community)
- [Medium — Dissecting Cline: Context Management](https://medium.com/@balajibal/dissecting-cline-cline-context-management-260aec3d84cb) — third-party
