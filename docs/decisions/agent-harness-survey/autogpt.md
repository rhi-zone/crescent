# AutoGPT — prior-art survey

Survey of `github.com/Significant-Gravitas/AutoGPT` as prior art for an agent
harness. Read for the *decisions* and the *lessons*, not the feature list.
Findings below are grounded in the repo's README, docs, and source files fetched
at survey time (2026-08-02, `master`); see Sources.

## Overview

AutoGPT is historically the first widely-visible autonomous-loop LLM agent
(March 2023). Its trajectory is the interesting artifact: it began as a
*recursive self-prompting goal loop* and today ships as a *visual, block-based
workflow platform* where the loop, when present at all, is an explicit,
user-drawn cycle in a dataflow graph.

The repository is split accordingly, and the split is itself a decision:

- `classic/` — the original agent, plus `forge` (agent-building framework),
  `agbenchmark`/`direct_benchmark`. MIT licensed. Maintained but not the focus.
- `autogpt_platform/` — the current product (backend, frontend, blocks).
  **Polyform Shield** licensed, i.e. deliberately *not* OSI-open. The pivot
  came with a license change on the new code while the historical agent stayed
  MIT.

The README describes the platform as four surfaces: **AutoPilot**
(conversational agent-builder), **Agents** (run/cost/status dashboard),
**Marketplace** (shareable agent templates), **Build** (visual canvas). Agents
run on demand, on a schedule, or on an event trigger.

The single most important thing to take from AutoGPT is *why* the second
architecture exists: the first one did not work in production. See Notable
Design Decisions.

## Architecture

### Era 1 — the classic autonomous loop (2023, `classic/`)

The classic agent is a `propose_action()` → `execute()` cycle
(`classic/original_autogpt/autogpt/agents/agent.py`). Each turn:

1. Gather directives (constraints, resources, best practices) and the list of
   available commands.
2. Build messages from the *event history* (see Context/Memory).
3. Ask the LLM for a structured proposal — historically `thoughts` +
   `reasoning` + `plan` + `criticism` + a `command` with args, emitted as JSON
   (the "GENERATE NEXT COMMAND JSON" prompt); later migrated to native
   provider tool-calling.
4. Execute the command, append the result to history, repeat.

The agent owns a workspace directory (files persist across sessions), and
`--continuous` mode removes the per-step human confirmation.

Two structural ideas from `forge` are worth stealing independent of the loop:

- **Components + protocols.** An agent is assembled from `AgentComponent`
  instances discovered by *type* from `self.*` assignments in `__init__`.
  Components implement one or more protocols — `DirectiveProvider`,
  `MessageProvider`, `CommandProvider`, plus lifecycle hooks (`after_parse`,
  `after_execute`) — and the base agent runs each protocol as a *pipeline* over
  all enabled components. Capabilities compose rather than being hardcoded into
  the loop. Components are individually enable/disable-able and orderable, and
  each carries its own pydantic config model (`ConfigurableComponent[BM]`),
  with secrets declared as `UserConfigurable(from_env=..., exclude=True)`.
- **Pluggable prompt strategies.** `build_prompt()` / `parse_response_content()`
  is an interface, with implementations for OneShot (default), ReWOO,
  PlanExecute, Reflexion, TreeOfThoughts, LATS, MultiAgentDebate. The reasoning
  policy is swappable without touching the loop.

Also from this era: **Agent Protocol** (a standard HTTP surface for
task/step/artifact so any agent could be driven and benchmarked uniformly) and
`agbenchmark` — an early recognition that agents need a *harness-independent
evaluation* story.

### Era 2 — the block/graph platform (`autogpt_platform/`)

An agent is a **graph** of **nodes**; each node is an instance of a **block**.
A block is a Python class (`backend/blocks/_base.py`, `class Block(ABC, Generic[
BlockSchemaInputType, BlockSchemaOutputType])`) with:

- a stable UUID `id` (persisted; blocks are synced into an `AgentBlock` table at
  startup, with input/output JSON Schema stored alongside — `backend/data/block.py`),
- pydantic `Input`/`Output` schemas exposed as JSON Schema (this is what draws
  the pins on the canvas *and* what becomes an LLM tool schema — one schema,
  three consumers),
- an async generator `run()` yielding `(output_name, value)` tuples — a block
  emits **N values on M pins**, streaming, not a single return value,
- declarative test material carried *on the block itself*: `test_input`,
  `test_output`, `test_mock`, `test_credentials`, so every block is executable
  as a test case by a generic runner,
- metadata: `categories`, `contributors`, `disabled`, `static_output`,
  `block_type` (`STANDARD | INPUT | OUTPUT | NOTE | WEBHOOK | WEBHOOK_MANUAL |
  AGENT | AI | HUMAN_IN_THE_LOOP | MCP_TOOL`), `webhook_config`,
  `is_sensitive_action`, and a per-block `execution_timeout_seconds`.

Execution (`backend/executor/manager.py`) is a priority-queued dispatcher over a
worker pool, not a DAG topological sort:

- Nodes are enqueued when their inputs are *complete*; completion is decided per
  node via `get_missing_input` / `get_missing_links`, which blocks can override.
  This is what permits **cycles**: the loop-carrying edges are legal because
  completion is a predicate, not an acyclic ordering.
- `static` links can be reused across multiple incomplete executions of a
  downstream node, and their arrival re-evaluates previously incomplete nodes.
- Node failure is isolated: the node goes `FAILED` and emits an error output;
  the graph does not necessarily die. `InsufficientBalanceError` is the
  exception — it halts everything, and the orchestrator block documents an
  explicit contract that IBE must re-raise through *every* `except` clause so a
  loop can never continue doing unpaid work.
- Costs are charged pre-flight per node and reconciled post-flight against
  actual provider usage (`SECOND`, `ITEMS`, `COST_USD`, `TOKENS` billing types).
- Nested runs are tracked with `root_execution_id` / `parent_execution_id`;
  killing a parent skips its children.
- Concurrency is bounded per user/graph, and a cluster-wide lock prevents
  duplicate processing across pods.

Notable serialization constraint: *a given set of credentials may only be in use
by one running block at a time*, enforced by Redis-backed read-write locks.
Credentials are a scheduling resource, not just a config value.

## Tool-Calling Protocol

### Classic

Originally a hand-rolled JSON protocol: the model was instructed to emit a JSON
object with a `command` name and arguments, parsed and repaired by the harness.
This predated reliable native function calling and was a major source of
brittleness (parse failures, hallucinated command names, argument type drift).
The codebase later moved to provider-native tool calling; `execute()` supports
both a single tool call and parallel tool calls, aggregating results.

Commands reach the model through the `CommandProvider` pipeline, filtered by a
disabled-command list, and every proposed call passes a **permission manager**
check before execution — a denial is returned to the model as feedback rather
than raising.

### Platform — tools *are* graph edges

This is the distinctive part. `backend/blocks/orchestrator.py`
(`OrchestratorBlock`, successor to `SmartDecisionMakerBlock`) turns the graph
topology into the tool schema:

- For every node connected downstream of the orchestrator via a *tool pin*, it
  synthesizes a function definition from that sink block's input JSON Schema
  (`_create_block_function_signature`), sanitizing names (`cleanup`),
  disambiguating collisions (`_disambiguate_tool_names`), and stashing
  `_field_mapping` and `_sink_node_id` on the definition so the returned
  arguments can be mapped back onto the real block's input pins.
- The user therefore *defines the toolset by wiring the canvas*. There is no
  separate tool registry to keep in sync with the workflow.
- The block normalizes across provider dialects: it understands OpenAI Chat
  Completions (`tool_calls` / `role: "tool"` / `tool_call_id`), the OpenAI
  Responses API, and Anthropic (`tool_use` / `tool_result` / `tool_use_id`), via
  `_get_tool_requests`, `_get_tool_responses`, `_create_tool_response`, and
  `_combine_tool_responses` (Anthropic requires multiple `tool_result` items to
  be merged into one user message). Pending calls are tracked by diffing
  requests against responses (`get_pending_tool_calls`).

Three execution modes coexist, selected per node:

- `agent_mode_max_iterations = 0` — **traditional mode**: one LLM call; the
  block *yields the tool calls as graph outputs* and the loop closes through the
  canvas. Downstream nodes run the tools, and their results feed back into the
  orchestrator's `conversation_history` and `last_tool_output` inputs. The input
  validator enforces this pairing: those two pins must be connected together,
  `last_tool_output` may not come from a static link, and the node refuses to
  run when there are pending tool calls but no `last_tool_output` (and vice
  versa). **The agent loop is a visible cycle in the dataflow graph, executed by
  the same scheduler as everything else.**
- `agent_mode_max_iterations = -1 | 1+` — the loop runs *inside* the block via
  `backend/util/tool_call_loop.py`, a provider-agnostic loop parameterized by
  `LLMCaller`, `ToolExecutor`, and `ConversationUpdater` protocols, with
  `max_iterations` (-1 infinite, 0 none) and a terminal
  `"Completed after N iterations (limit reached)"` response.
- `execution_mode = extended_thinking` — delegates to an external Agent SDK
  (Anthropic/OpenRouter), exposing the graph's tools to it as an **MCP server**
  named `graph_tools`. There is also a first-class `MCP_TOOL` block type and a
  `blocks/mcp/` package with its own OAuth flow: external MCP servers are
  imported as blocks.

Other tool-protocol details: `multiple_tool_calls` is opt-in (default single
call), `retry` (default 3) covers malformed responses, and the default system
prompt explicitly demands complete, schema-typed arguments and offers a "finish
message" as the terminating move.

## Context/Memory Management

**The most-cited lesson of the classic era: AutoGPT removed its vector
databases.** Early versions supported Pinecone, Milvus, Redis, and Weaviate as
pluggable long-term memory backends. All were dropped. Embedding-retrieval over
the agent's own action history did not pay for its complexity — retrieved
fragments were rarely the ones that mattered, and the recency/causality
structure of an agent trajectory is not what similarity search preserves.

What replaced it is structurally simpler and works better:

- **`EpisodicActionHistory`** — an ordered log of (proposal, result) episodes,
  which is the agent's memory. Not a store to be queried; a transcript to be
  rendered.
- **Recency window + LLM summarization of the tail.** `ActionHistoryComponent`
  keeps the latest N episodes verbatim and replaces older ones with
  LLM-generated per-episode summaries, walking backwards and stopping at a
  `max_tokens` budget (default 1024). Compression is *lazy* — performed in
  `prepare_messages()`, only when the history is actually needed — and can be
  disabled outright (`enable_compression`, off for ReWOO/benchmarks, where
  faithful history matters more than budget).
- **Result truncation at the source.** A single tool result exceeding one-third
  of the send-token limit is replaced with an error message rather than
  truncated silently — a large output is treated as a *failure of the call*, not
  as data to be squeezed.
- The **workspace/file system** is the real long-term memory: the agent writes
  files and reads them back by name. Explicit, addressable, debuggable.

On the platform side, memory is per-orchestrator-node `conversation_history`
flowing as ordinary graph data, with `conversation_compaction` (default on) for
automatic context-window compaction. There is also a `mem0` block for callers
who genuinely want a hosted memory service — i.e. memory became an *opt-in
block*, not a core subsystem.

## Sandboxing & Permissions

The two eras answer this completely differently.

**Classic — local Docker, with a shell allow/deny list.**
`classic/forge/forge/components/code_executor/code_executor.py` detects whether
it is itself inside a container (`/.dockerenv`) or has a working Docker daemon;
Python execution goes into a container (default name `agent_sandbox`). Shell
execution is gated by `execute_local_commands`, defaulting **off**, and by
`shell_command_control: "allowlist" | "denylist"` with `shell_allowlist` /
`shell_denylist`. If neither in-container nor Docker-available, the code
execution commands are simply not offered to the model — capability is withheld
at the tool-listing layer, which is the right place. File access is scoped to a
`FileStorage` workspace. Non-continuous mode requires human confirmation per
step.

**Platform — no local execution at all.** Code execution is delegated to **E2B**
(`e2b_code_interpreter`), a third-party remote sandbox service, with sandbox
lifecycle exposed as blocks (`ExecuteCodeBlock` creates+runs+disposes,
`InstantiateCodeSandboxBlock` returns a `sandbox_id`, `ExecuteCodeStepBlock`
reconnects to it), per-run timeouts, and `sandbox.kill()` on error. The platform
never runs model-authored code on its own machines; it buys isolation.

Permissions on the platform are layered:

- **Credentials as first-class typed inputs.** Fields must be named `credentials`
  or `*_credentials` and typed `CredentialsMetaInput`, validated at class
  definition time; provider, credential type, and OAuth scopes are declared in
  the schema. The secret value is never in the graph — the graph holds a
  reference the executor resolves.
- **`is_sensitive_action`** on blocks, marking operations (send email, post,
  place order) that need stronger gating.
- **`HumanInTheLoopBlock`** — a block whose whole purpose is to suspend the
  execution and wait for approve/reject/edit, then route the data out of an
  `approved_data` or `rejected_data` pin. Approval is a *node in the workflow*,
  not a modal dialog bolted onto the runtime. Gated by
  `execution_context.human_in_the_loop_safe_mode`; with safe mode off it
  auto-approves and says so in `review_message`.
- **`CopilotPermissions`** (`backend/copilot/permissions.py`) — a capability
  filter over both tool names and block ids for a single copilot/AutoPilot run,
  with allow/deny resolution, validation of tool and block identifiers against
  the registry, and — importantly — `merged_with_parent()`, which guarantees a
  child execution is *at most as permissive as its parent*. Inheritance is
  carried through a `contextvars.ContextVar`, and permissions are built and
  validated **eagerly, before the session is created**, so an
  over-broad request fails before any capability exists.
- Rate limits, per-user balance checks, and per-block execution timeouts are
  enforced by the executor rather than by the agent's good behavior.

## Multi-Agent Support

There is no peer-to-peer agent society. Composition is strictly **hierarchical
and structural**:

- **`AgentExecutorBlock`** — a saved graph appears in the block palette and can
  be dropped into another graph. Sub-agents are just blocks; nesting is
  arbitrary depth. The executor gives such blocks special treatment: reshaped
  input (node inputs merged with graph input defaults) and
  `execution_timeout_seconds = None`, since the inner graph enforces its own
  bounds. Parent/child runs are linked by `root_execution_id` /
  `parent_execution_id`, and cancelling the parent skips the children.
- **`OrchestratorBlock`** is the "delegating agent" pattern — it chooses among
  its wired-up tools, some of which may themselves be `AgentExecutorBlock`s.
- **`AutoPilotBlock`** is a conversational agent that *builds and edits graphs*,
  and it can nest: permissions are inherited and narrowed down the chain.
- The classic era had `MultiAgentDebate` as a *prompt strategy* — multiple
  personas inside one agent's reasoning, not multiple processes.

The decision worth noting: **composition is over saved artifacts (graphs), not
over live message-passing between agents.** A sub-agent has a schema, a version,
a cost, and a permission envelope, because it is a block like any other.

## Notable Design Decisions

1. **They abandoned autonomy.** This is the headline. The project that defined
   "give it a goal and walk away" concluded that unbounded recursive planning is
   not a product. The failure modes were concrete and are now well documented:
   goal drift (the agent forgets its objective and pursues tangents),
   non-termination (loops with no completion criterion), unbounded cost, and no
   way to reproduce or debug a run. The replacement thesis is explicit in the
   product: **humans design the boundaries, the LLM makes choices inside them.**
   The graph is the boundary.

2. **The loop, when you want one, is drawn — not hidden.** Traditional mode
   makes the agent loop a literal cycle of edges on the canvas. Every iteration
   is a scheduled node execution with its own persisted inputs, outputs, status,
   and cost. Debuggability, replay, and cost attribution come free from the
   substrate rather than from agent-specific tracing. This is the inverse of the
   usual harness, where the loop is opaque runtime and the graph is a metaphor.

3. **One schema, three consumers.** A block's pydantic input schema is
   simultaneously the canvas UI, the runtime validator, and the LLM tool
   definition. Adding a tool for the LLM and adding a node type for the user are
   the same act. `_field_mapping` exists precisely to make the LLM-facing
   projection (sanitized names) reversible onto the real schema.

4. **Tools are defined by topology.** The orchestrator's toolset is whatever is
   wired to it. There is no registry to drift out of sync with the workflow, and
   scoping a tool to an agent is a wiring decision the user can see.

5. **Determinism is opt-in per node, not global.** A graph freely mixes
   deterministic blocks with LLM-decided routing (`OrchestratorBlock`,
   `ai_condition`). You pay for nondeterminism only where you asked for it —
   the classic agent charged for it everywhere.

6. **Cost is a first-class runtime concern.** Pre-flight charge, post-flight
   reconciliation, balance checks before accepting a run, and a documented
   invariant that the balance exception must never be swallowed by a retry
   handler. Cost control lives in the executor, where it cannot be reasoned
   away by a model.

7. **Credentials are scheduling resources.** The one-block-at-a-time lock per
   credential set is an unusual call — it trades parallelism for avoiding
   provider-side rate-limit and state conflicts, and it means the permission
   model and the scheduler are coupled by design.

8. **Approval is a node.** `HumanInTheLoopBlock` makes "ask a human" a
   composable graph element with typed approve/reject branches, rather than an
   out-of-band interrupt. Pausing and resuming is just the executor's normal
   incomplete-input handling.

9. **Permissions narrow monotonically down the nesting chain.**
   `merged_with_parent()` is the sort of invariant that has to be in the
   substrate; a child agent cannot escalate.

10. **Blocks carry their own tests.** `test_input`/`test_output`/`test_mock` on
    the class means a generic runner can execute every block in the catalog.
    With hundreds of community-contributed integrations, per-block bespoke test
    files would not have scaled.

11. **They dropped the vector database.** Recency + summarization + a file
    workspace beat embedding retrieval for agent trajectories. Memory later
    returned as an optional third-party block.

12. **The license changed with the pivot.** New platform code is Polyform Shield,
    not MIT. Worth knowing before treating the platform code as reusable prior
    art in a permissively-licensed project — read for ideas, not for copying.

13. **What survived the pivot is the *packaging*, not the loop.** Agent Protocol,
    `agbenchmark`, forge's component protocols, and the block schema all outlived
    the autonomous agent itself. The reusable part of an agent harness turned out
    to be the interface and evaluation machinery, not the reasoning loop.

## Relevance to Crescent

Read as input to a `lib/platform/apps/` agent app and to expanding `lib/ai`.
These are observations and open questions, not decisions.

**The strongest structural echo is `lib/taskgraph`.** AutoGPT's history says the
durable artifact of an agent system is the *execution graph*, not the loop —
and crescent already has a task graph with a frontier, an exec-graph, tracking,
and combinators (`lib/taskgraph/{graph,frontier,exec_graph,combinators}.lua`).
The question AutoGPT's design poses to crescent is whether the agent loop should
be *implemented on* taskgraph rather than beside it — i.e. whether a tool call
is a task node, so that tracking, the frontier, and scaffolds apply to agent
turns for free. That is an open design question with a real tradeoff (uniform
observability vs. coupling `lib/ai` to `lib/taskgraph`, which the current
dependency-free `lib/ai/tools.lua` avoids); it needs to be decided
deliberately, not inherited.

**`lib/ai/tools.lua` is currently the classic-era shape.** `mod.run` is an
in-process loop with `max_rounds` (default 10), a `handlers` table keyed by tool
name, JSON-encoded results appended as `role = "tool"` messages, and
`"max rounds exceeded"` on exhaustion. That is a reasonable minimum and matches
`tool_call_loop.py` in spirit. The specific gaps AutoGPT's version has closed,
each of which is a candidate work item rather than an obvious yes:

- *Provider dialect normalization.* `tools.lua` assumes one tool-call/tool-result
  shape. AutoGPT needed four functions (`_get_tool_requests`,
  `_get_tool_responses`, `_create_tool_response`, `_combine_tool_responses`) to
  span OpenAI Chat, OpenAI Responses, and Anthropic — including Anthropic's
  requirement that parallel `tool_result`s be merged into one message. If
  `lib/ai` keeps a provider registry, this normalization has to live somewhere.
- *Context growth.* `tools.lua` grows `messages` without bound. AutoGPT's answers
  — recency window plus summarization of older episodes, lazy compaction, and
  rejecting oversized tool results outright — are cheap to implement and do not
  require embeddings. The "oversized result is an error, not data" rule is the
  cheapest and most valuable of the three.
- *Loop exhaustion semantics.* `tools.lua` returns an error on exhaustion,
  discarding the work done. AutoGPT returns a completion response noting the
  limit was hit. Which is right depends on the caller; it is a real branch point.
- *Cost/token accounting.* AutoGPT aggregates token counts across all iterations
  into one charge and treats budget exhaustion as non-swallowable. crescent has
  no cost concept in `lib/ai` yet.

**Caps-first is already crescent's answer to AutoGPT's permission model.** The
project's rule that I/O libraries take injected caps and never reach for globals
is structurally what `CopilotPermissions` implements at runtime. Two ideas from
the platform are worth considering on top: `merged_with_parent()`'s guarantee
that a sub-agent's capability set is a subset of its parent's — which for
crescent means a spawned sub-agent gets a *restricted cap table*, not the same
one — and withholding a capability at the *tool-listing* layer (classic simply
does not offer code execution when no sandbox exists) rather than failing at
call time.

**Sandboxing is the least transferable part.** The platform's answer is "pay E2B",
which contradicts crescent's zero-dependency, works-on-a-bare-clone constraint.
The classic answer (Docker when available, an explicit shell allowlist, tools
withheld when isolation is absent) degrades more gracefully and is closer to
what a local-first Lua ecosystem can do. If an agent app needs to run
model-authored code, the isolation mechanism is unresolved substrate and should
be recorded as such rather than approximated.

**Approval-as-a-node and typed sub-agents are cheap wins.** `HumanInTheLoopBlock`
suggests human approval belongs in the task graph with typed approve/reject
edges rather than as an ad-hoc prompt, and `AgentExecutorBlock` suggests a
sub-agent should be an addressable, schema-bearing artifact rather than a
closure. Both fit crescent's existing structures without new substrate.

**The lesson to actually internalize:** AutoGPT's autonomous loop failed not
because the models were weak but because *nothing in the architecture bounded
it* — no termination criterion, no cost ceiling, no reproducible trace, no place
for a human to intervene. Any crescent agent app should decide where each of
those four lives before it writes the loop.

## Sources

Repo, fetched 2026-08-02 at `master`:

- `README.md` — platform surfaces, repo layout, licensing split.
- `classic/original_autogpt/README.md` — classic agent status and disclaimer.
- `classic/original_autogpt/autogpt/agents/agent.py` — propose/execute cycle,
  prompt strategies, component wiring, permission check on proposed calls.
- `classic/forge/forge/components/README.md` — component/protocol model,
  configuration, secret handling.
- `classic/forge/forge/components/action_history/action_history.py` — recency
  window, LLM compression, `max_tokens` budget, lazy `prepare_messages`.
- `classic/forge/forge/components/code_executor/code_executor.py` — Docker
  detection, shell allowlist/denylist, capability withholding.
- `autogpt_platform/backend/backend/blocks/_base.py` — `Block` base class,
  schemas, block types, test material, `is_sensitive_action`, credentials
  field rules.
- `autogpt_platform/backend/backend/data/block.py` — block DB sync, `BlockOutput`
  async-generator typing.
- `autogpt_platform/backend/backend/executor/manager.py` — dispatcher, input
  completion, static links, cost charge/reconcile, credential locks, nested
  executions, cancellation.
- `autogpt_platform/backend/backend/blocks/orchestrator.py` — tool synthesis from
  graph links, provider dialect normalization, three execution modes, IBE
  contract, feedback-edge validation.
- `autogpt_platform/backend/backend/util/tool_call_loop.py` — provider-agnostic
  loop protocols and iteration limits.
- `autogpt_platform/backend/backend/blocks/human_in_the_loop.py` — approval as a
  block, safe-mode bypass.
- `autogpt_platform/backend/backend/blocks/autopilot.py`,
  `autogpt_platform/backend/backend/copilot/permissions.py` — capability filter,
  eager validation, parent-narrowing inheritance.
- `autogpt_platform/backend/backend/blocks/code_executor.py` — E2B sandbox
  lifecycle.
- `autogpt_platform/backend/backend/blocks/mcp/` — MCP servers imported as blocks.

Secondary (used for the pivot narrative and the vector-DB removal, both
corroborated by the repo's own structure):

- https://www.mmntm.net/articles/autogpt-lessons
- https://dariuszsemba.com/blog/why-autogpt-engineers-ditched-vector-databases/
- https://github.com/vectara/awesome-agent-failures/blob/main/docs/case-studies/autogpt-planning-failures.md
- https://www.georgesung.com/ai/autogpt-arch
- https://github.com/Significant-Gravitas/AutoGPT/pull/8533 (AgentExecutorBlock),
  https://github.com/Significant-Gravitas/AutoGPT/pull/8710
