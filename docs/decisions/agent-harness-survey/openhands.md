# OpenHands — Agent Harness Survey

Survey of `github.com/All-Hands-AI/OpenHands` (now redirecting to
`github.com/OpenHands/OpenHands`), formerly OpenDevin, as prior art for an
agentic harness. Researched 2026-08-02.

**Verification note.** The repo exists and is active, but the name now covers
*three* distinct artifacts, and conflating them produces a wrong picture:

1. **V0 (2024–2025, deprecated)** — the Python monolith described in the
   OpenDevin/OpenHands paper (arXiv 2407.16741). This is the EventStream +
   AgentController + mandatory-Docker-Runtime design most secondary sources
   still describe.
2. **V1 SDK (late 2025–)** — `github.com/OpenHands/software-agent-sdk`, a
   deliberate rewrite that *deletes* the EventStream and AgentController.
   Described in arXiv 2511.03690.
3. **`OpenHands/OpenHands` today** — "Agent Canvas", a TypeScript/Node
   self-hosted control center for running OpenHands/Claude Code/Codex/Gemini
   and any ACP-compatible agent across local/remote/cloud backends. The Python
   agent core no longer lives here.

The most valuable prior art is the **delta between V0 and V1**, because the V1
paper states explicitly which V0 decisions failed and why. A survey of V0
alone would recommend patterns its own authors abandoned.

Unverified in this pass: `docs.openhands.dev/openhands/usage/architecture/runtime`
timed out on fetch, so V0 runtime port/persistence specifics below come from
the paper and DeepWiki rather than first-party docs.

---

## Overview

OpenHands is an open-source (MIT) platform for software-engineering agents that
act the way a developer does — writing code, running a shell, browsing the web.
It began as OpenDevin, an academic-community reproduction of Devin, and grew to
~400 contributors at ~60 commits/week over 18 months. It is best known for
SWE-Bench results and for being the reference open implementation of the
**CodeAct** ("code as action") agent formulation.

Its stated design pillars in V0 were generality, extensibility, and safety —
the last delivered by mandatory sandboxing plus human-in-the-loop rather than
by autonomous operation.

---

## Architecture

### V0: EventStream + AgentController + Runtime

The V0 control flow is a loop over a central append-only event log:

```
User Message -> Agent.step(State) -> LLM -> Action
             -> Runtime (Docker sandbox) -> Observation -> back into stream
```

- **Agent** is a near-minimal abstraction: a single `step(state) -> action`
  function. State carries the event history plus bookkeeping (accumulated LLM
  cost, delegation metadata). The rationale was explicitly social: a tiny
  surface lowers the barrier for community agent contributions.
- **EventStream** is a pub/sub hub shared by agent, user, and runtime. Every
  action and observation is recorded chronologically. The stream *is* the
  state — what the agent perceives is a fold over the log.
- **AgentController** drives the loop, owns agent state transitions, budget and
  iteration limits, and delegation.
- **Runtime** is a separate abstraction executing each action in a per-session
  Docker container.

### V1: Conversation + Workspace, event-sourced

V1 collapsed AgentController and Runtime into `Conversation` + `Workspace` on
the grounds that the controller "didn't earn its keep", and **removed the
EventStream entirely**. The stated reasons for killing pub/sub:

- No clear message-ordering guarantees.
- Threading bugs and hard-to-debug interleaving.
- It was designed "in the first few weeks of OpenHands — before things like
  tool use and MCP were even invented", and no longer matched the domain.

V1 replaces it with **synchronous conversations**, with async/threading
available opt-in for long-running operations.

The V1 component model:

- `Agent`, `Tool`, `LLM`, `Condenser` are **immutable Pydantic models**,
  validated at construction.
- `ConversationState` is the **single mutable entity**, holding metadata plus
  an append-only `EventLog`.
- State changes happen only by appending events — never by mutating objects.
  This buys deterministic replay and crash recovery: reload `base_state.json`,
  replay events to the last processed one, detect incomplete sessions.
- `Conversation` is a factory: constructed with a path it returns
  `LocalConversation` (in-process); constructed with a `RemoteWorkspace` it
  returns `RemoteConversation` delegating over HTTP/WebSocket. Same agent code
  either way.

V1 also split the monorepo into four independently releasable packages:
`openhands.sdk` (abstractions + events), `openhands.tools`,
`openhands.workspace`, `openhands.agent_server`. The stated V0 failure being
corrected: agent core, eval suite, and applications shared one repo, so the
core absorbed application-specific branches, benchmarks, and environment hacks.

---

## Tool-Calling Protocol

### V0: code as the universal action

CodeAct's thesis is that you don't need a broad tool schema because **code is
the tool interface**. V0's action space was essentially three primitives:

- `IPythonRunCellAction` — arbitrary Python in a persistent Jupyter kernel
- `CmdRunAction` — bash in the sandbox
- `BrowseInteractiveAction` — browser control via BrowserGym's DSL

Rationale: code is "powerful and flexible enough to perform any task with tools
in different forms" while staying reliable and maintainable, and it lets the
agent *invent* tools at runtime when no API exists.

The supporting **AgentSkills** library is a Python package auto-imported into
the IPython environment (`edit_file`, `scroll_up`/`scroll_down`, `parse_image`,
`parse_pdf`). Its inclusion policy is a sharp, transferable rule: a skill is
added **only** when (1) the LLM cannot readily write the equivalent code
itself, or (2) it requires calling an external model. Explicitly *not* a
wrapper layer over existing libraries.

### V1: typed Action/Observation triple

V1 formalises tools as a three-part separation:

- `Action` — Pydantic schema, validates LLM-supplied arguments
- `ToolExecutor` — performs the effect
- `Observation` — formats the result back into the log

The LLM emits JSON tool calls; these parse into typed `Action` objects or fail
before any execution. One tool definition serialises three ways —
`to_openai_tool()` (ChatCompletions), `to_responses_tool()` (OpenAI Responses
API), `to_mcp_tool()` (MCP) — so the same tool works across API shapes.

Two decisions worth noting:

- **MCP tools are not a special case.** An MCP tool's JSON schema is
  auto-converted into an `Action` model, so external tools travel the identical
  path as native ones.
- **Tool *specs* are separated from tool *implementations*.** A spec carries
  only a registered name and JSON-serializable parameters, so it can cross a
  process boundary; the far side reconstructs the implementation from a
  registry resolver. This is what makes local/remote transparency work.

For models without native function calling, `NonNativeToolCallingMixin`
renders tool schemas as text instructions and parses replies with regex —
an explicit fallback tier rather than a hard requirement.

---

## Context/Memory Management

The **Condenser** is OpenHands' most reusable contribution here. The event log
is always complete; the condenser controls only the *view* sent to the LLM.

Mechanism: when history grows past a threshold, the condenser emits a
`Condensation` event into the log containing `forgotten_event_ids`, a
`summary`, and a `summary_offset`. `View.from_events()` reconstructs what the
LLM sees by filtering the forgotten IDs and splicing the summary in at the
offset. **Nothing is destroyed** — compaction is a derived view, and it is
itself an event, so it replays deterministically.

`RollingCondenser` supplies threshold-based triggering: past `max_size`
(default 120 events) it partitions history into `keep_first` events (typically
the ~4 system/setup events), a compressed middle, and a recent tail, targeting
roughly half the original size.

Implementations span a cost/fidelity ladder, and several need no LLM call at
all:

| Condenser | Strategy |
| --- | --- |
| `NoOpCondenser` | pass-through |
| `ObservationMaskingCondenser` | replace old observations with masked text (no API call) |
| `BrowserOutputCondenser` | keep only the N most recent browser screenshots/trees |
| `RecentEventsCondenser` | first N + most recent M |
| `AmortizedForgettingCondenser` | drop the middle, keep head + tail |
| `ConversationWindowCondenser` | default window drop, no LLM |
| `LLMSummarizingCondenser` | rolling text summary, aware of the previous summary |
| `StructuredSummaryCondenser` | structured output via forced function call |
| `LLMAttentionCondenser` | rank events by importance, keep top-N |

`CondenserPipeline` chains them — the default configuration runs
`BrowserOutputCondenser` (cheap, targeted, drops the biggest blobs) *before*
`LLMSummarizingCondenser`. The paper claims the summarizing condenser cuts API
cost up to 2x without measured performance loss.

Separately, **static context** loads from files the ecosystem already uses —
`AGENTS.md`, `repo.md`, `.cursorrules` — into `AgentContext`, alongside
system/user message prefixes, without touching agent logic.

---

## Sandboxing & Permissions

### V0: mandatory Docker, sandbox-as-a-service

Each session spun up an isolated Docker container. Inside it ran an **Action
Execution Server** — a REST server owning the stateful subprocesses: bash
shells, the Jupyter IPython kernel, and Chromium. The backend spoke to it over
HTTP, sending actions and receiving observations; the workspace directory was
mounted in. Runtime images were built by `openhands/runtime/utils/runtime_build.py`
with `force_rebuild` / `enable_browser` options, supporting arbitrary base
images so an agent could run against a user's own OS and toolchain.

Operational details: host ports are allocated from a configured range using
file-locked allocation (`find_available_port_with_lock`) for concurrency
safety; the sandbox is only marked `RUNNING` after polling the execution
server's `/alive` endpoint; per-session API keys are injected as environment
variables (`OH_SESSION_API_KEYS_0`), with webhook base URLs and CORS origins
injected the same way. Remote implementations store only a SHA-256 hash of the
session API key.

Note that the *stateful* pieces (shell, kernel, browser) live server-side. An
"action" is not a fresh process — it is a message to a long-lived session.
That is what makes `cd` and Python variables persist across steps.

### V1: sandboxing becomes opt-in — the most consequential reversal

V1 runs **in-process locally by default**, with containerization opt-in by
swapping `LocalWorkspace` for `DockerWorkspace` and changing no agent code.
The paper's reasons for backing out mandatory sandboxing:

- Agent and sandbox were independent processes; one crashing corrupted the
  session.
- Multi-tenant deployments hit resource exhaustion when one user's actions
  saturated shared containers.
- Supporting local execution *anyway* required duplicating MCP and tool logic
  along a second path.
- MCP's own assumptions are in-process, and fighting them cost more than it
  bought.

The security story moved from "isolation is the mechanism" to an explicit,
composable permission layer with **risk assessment separated from
enforcement**:

- `SecurityAnalyzer` assigns each tool call a risk level: LOW, MEDIUM, HIGH,
  UNKNOWN.
- `ConfirmationPolicy` decides whether that risk requires human approval;
  `ConfirmRisky()` blocks above a threshold (default HIGH).
- On block, the agent enters `WAITING_FOR_CONFIRMATION` and halts until
  explicit approval or rejection.

Either half can be replaced without touching executors or core logic.

`LLMSecurityAnalyzer` (now the default) has the model attach a `security_risk`
field to its own tool calls — assessment rides along with the call rather than
costing a second inference. Because it sees history, it can reason about
*cumulative* risk ("this is the third `rm -rf`"). It supersedes the earlier
rule-based Invariant analyzer, which is documented as broken and off by
default. When multiple analyzers run, the **highest concrete risk wins** (no
averaging); UNKNOWN is filtered out if any analyzer returned a concrete level,
unless `propagate_unknown=True` makes any single UNKNOWN trigger confirmation.

`SecretRegistry` handles credentials separately: late-bound and per-session
isolated, resolved only at execution time, values masked in all outputs,
supplied as static values or callables (token refreshers), and rotatable
mid-conversation without a restart.

---

## Multi-Agent Support

**V0** used `AgentDelegateAction`: an agent emits a delegation action, and the
controller hands control to a named sub-agent — canonically CodeActAgent
delegating a web task to BrowsingAgent. Delegation metadata lived in the shared
State/EventStream, so a delegated run remained visible in one auditable log.
**AgentHub** collected 10+ agents (CodeActAgent, BrowsingAgent, GPTSwarm, and
"micro agents" that reuse the generalist implementation with only a different
prompt).

**V1 demoted delegation to an ordinary tool.** Sub-agent spawning is
implemented in `openhands.tools` with *no core modifications*; sub-agents
inherit the parent's model config and workspace. The current implementation is
blocking parallel execution. The paper presents this as the load-bearing
demonstration of the architecture: "complex coordination behaviors" should be
expressible entirely as user-defined tools, and if they aren't, the core is
wrong.

**Microagents** (V0 vocabulary; "Skills" in V1) are markdown files with
optional YAML frontmatter, discovered under `.openhands/microagents/` in the
target repo. Two modes:

- **No frontmatter / no triggers** → always loaded. `repo.md` is the canonical
  case: directory layout, build commands, test conventions, known gotchas.
- **`triggers: [keyword, ...]`** → loaded only when a trigger keyword appears
  in the conversation.

The keyword trigger is the point: narrow domain knowledge can be installed
without paying for it in every prompt. In V1 these became `Skill` objects in
`AgentContext`, either markdown-loaded or programmatic, with `trigger=None`
meaning always-on.

---

## Notable Design Decisions

1. **The rewrite is the finding.** OpenHands' own authors, with 18 months of
   production data, discarded pub/sub event streaming, a dedicated agent
   controller, and mandatory sandboxing. Any survey that recommends those
   because "OpenHands does it" is citing a superseded design.
2. **Event sourcing survived the rewrite; pub/sub did not.** The append-only
   log with deterministic replay was kept and strengthened. What was cut was
   the *asynchronous multi-publisher delivery* on top of it. The log is the
   good idea; the bus was not.
3. **Immutable everything, one mutable cell.** Agent/Tool/LLM/Condenser
   immutable; `ConversationState` the sole mutable entity. The V0 failure this
   fixes is quantified: 140+ config fields across 15 classes and 2.8K LOC, with
   CLI, Web UI, and GitHub App each patching config in place so identical
   parameters diverged between runs.
4. **Compaction as a logged, reconstructable view.** Condensation writes an
   event recording *what was forgotten and what replaced it*, so the reduced
   context is derived, auditable, and replayable — not a destructive edit.
5. **A cost ladder for context reduction.** Several condensers cost zero LLM
   calls (masking, windowing, browser-output trimming) and run before the
   expensive summarizer in a pipeline. Summarization is the last resort, not
   the default reflex.
6. **Risk assessment split from enforcement.** `SecurityAnalyzer` and
   `ConfirmationPolicy` are independent and separately replaceable, and the
   default analyzer gets risk for free by having the model self-annotate the
   tool call it is already emitting.
7. **AgentSkills' negative inclusion rule.** Add a skill only if the LLM can't
   write the code itself or an external model is required. An explicit defense
   against a tool library that grows into a wrapper for the standard library.
8. **Tool spec/implementation split as the transparency mechanism.** Specs are
   serializable names + JSON params; implementations resolve from a registry on
   whichever side executes. This — not an RPC layer — is what makes the same
   agent code run local or remote.
9. **MCP as a peer, not an adapter.** MCP schemas become the same `Action`
   models as native tools, so there is no second code path to keep in sync.
10. **Trigger-keyword context loading.** Microagents/Skills make repo-specific
    knowledge conditional on keywords, keeping the always-on prompt small.

---

## Relevance to Crescent

Read as prior art against the current state of `lib/ai` (a provider registry
plus `lib/ai/tools.lua`, a 79-line loop that calls `ai.generate`, dispatches
`opts.handlers[tc.name]`, appends `role="tool"` messages, and stops at
`max_rounds`) and `lib/taskgraph`.

**Directly applicable, and cheap:**

- **The condenser's shape.** `lib/ai/tools.lua` currently grows `messages`
  unboundedly and has no context strategy at all. The transferable idea is not
  "add summarization" — it is *separating the stored history from the view sent
  to the model*, so reduction is a pure function over a log. The zero-LLM
  strategies (window, mask old observations, drop stale large outputs) are pure
  Lua and need no provider call.
- **Risk assessment separated from enforcement.** For a caps-first codebase
  this maps unusually well: the analyzer is a pure function `action -> risk`,
  the policy is a pure function `risk -> allow | confirm | deny`, and only the
  confirmation channel is a cap. Neither needs I/O.
- **AgentSkills' inclusion rule** is a defensible policy for whatever tool set
  an agent app under `lib/platform/apps/` exposes, and it aligns with the
  existing "no framework code in `lib/`" constraint.
- **Trigger-keyword conditional context** is a small, self-contained mechanism
  (frontmatter + keyword match) with a good size/benefit ratio.

**Applicable with a real tension to resolve:**

- **Event log vs. `taskgraph`.** OpenHands converged on a linear append-only
  log as the single source of truth. `lib/taskgraph` is a graph executor. These
  are different state models, and OpenHands offers no evidence about the graph
  case — its one experiment with concurrency-friendly messaging (EventStream)
  is the piece it deleted. Whether an agent loop should be a taskgraph node, or
  own a separate linear log, is an open design question this survey does not
  settle.
- **Sandboxing.** OpenHands' V1 reversal was driven by multi-tenant hosting and
  crash-isolation costs that a local zero-dependency Lua tool does not obviously
  share. But its underlying observation transfers: mandatory isolation forced a
  duplicate execution path, and the duplication was the real cost. Crescent's
  caps-first rule is arguably a *stronger* answer to the same problem —
  restricting what a tool handler can reach without needing a container — and
  the tiering convention (system > FFI > pure Lua) is the same shape as
  Local/Docker workspaces. Worth noting Crescent has no Docker dependency
  available at all, so the V0 model is not on the table regardless.

**Explicitly not recommended:**

- The V0 EventStream pub/sub design, and a dedicated AgentController object.
  Both were removed by their authors for stated reasons (ordering guarantees,
  threading bugs, no earned keep).
- Mandatory container sandboxing, which conflicts with the zero-dependency
  design principle and was itself backed out.

**Unresolved / needs an owner decision** (flagged rather than filled in):

- Whether the agent loop's history is a taskgraph structure or a separate
  linear event log.
- Whether tool specs need the serializable-spec/registry-resolver split, which
  only pays off if remote or cross-process execution is a goal.
- Whether confirmation is a cap injected into the loop or a caller-side
  concern outside `lib/ai` entirely.

---

## Sources

- [github.com/All-Hands-AI/OpenHands → OpenHands/OpenHands](https://github.com/OpenHands/OpenHands) — current repo (Agent Canvas, TypeScript)
- [github.com/OpenHands/software-agent-sdk](https://github.com/OpenHands/software-agent-sdk) — V1 Python SDK
- [The OpenHands Software Agent SDK: A Composable and Extensible Foundation for Production Agents (arXiv 2511.03690)](https://arxiv.org/html/2511.03690v1) — primary source for V1 architecture, tool protocol, security model, and V0→V1 rationale
- [OpenHands: An Open Platform for AI Software Developers as Generalist Agents (arXiv 2407.16741)](https://arxiv.org/html/2407.16741v3) — primary source for V0 agent abstraction, CodeAct, AgentSkills, delegation, sandboxed runtime
- [The Path to OpenHands v1](https://www.openhands.dev/blog/the-path-to-openhands-v1) — EventStream removal and AgentController replacement rationale
- [OpenHands Docs — Condenser](https://docs.openhands.dev/sdk/arch/condenser)
- [OpenHands Docs — Security & Action Confirmation](https://docs.openhands.dev/sdk/guides/security)
- [OpenHands Docs — Skills](https://docs.openhands.dev/overview/skills)
- [DeepWiki — Runtime Plugins](https://deepwiki.com/OpenHands/OpenHands/4.5-runtime-plugins)
- [openhands/runtime/utils/runtime_build.py](https://github.com/All-Hands-AI/OpenHands/blob/main/openhands/runtime/utils/runtime_build.py)
- [Issue #7547 — Proposal: Simplify microagents + support MCP natively](https://github.com/OpenHands/OpenHands/issues/7547)
- [Issue #5264 — Security analyzer (invariant) is broken](https://github.com/OpenHands/OpenHands/issues/5264)
- [PR #7867 — Combining condensers](https://github.com/OpenHands/OpenHands/pull/7867)
- [PR #6578 — Condenser for Browser Output Observations](https://github.com/OpenHands/OpenHands/pull/6578)
- [Issue #7311 — AgentCondensationAction to track condensation events](https://github.com/OpenHands/OpenHands/pull/7311)
- Not fetched (timeout): `docs.openhands.dev/openhands/usage/architecture/runtime`
