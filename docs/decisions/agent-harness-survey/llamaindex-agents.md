# LlamaIndex (Workflows / AgentWorkflow) — agent harness prior art survey

Survey of `run-llama/llama_index` and its extracted orchestration engine
`run-llama/workflows-py` as prior art for an AI agentic harness. Focus is on the
decisions the project made and the reasoning it gives for them, not a feature
inventory. The RAG/retrieval half of LlamaIndex is deliberately out of scope.
All claims are sourced (see Sources); where the docs did not answer a question,
that is stated as a gap rather than filled in.

## Overview

LlamaIndex began as a retrieval library. Its agent layer arrived later and, over
2024–2025, went through a decision that is the most interesting thing about it
as prior art: the agent abstractions were **deleted as the primary interface and
replaced by a general-purpose orchestration engine**, with agents demoted to a
preconfigured instance of that engine.

Three layers exist today:

1. **Workflows** — an event-driven, async-first, step-based execution engine.
   Extracted into standalone packages (`llama-index-workflows` for Python,
   plus a TypeScript port) at version 1.0, explicitly to "highlight Workflows
   independence from `llama_index`" — the blog states you can use it "to write
   the orchestration logic of any Python and TypeScript application." It does
   not depend on the LLM or retrieval layers.
2. **`AgentWorkflow` / `FunctionAgent`** — a `Workflow` subclass preconfigured
   with steps that understand LLM calls, tool-calling, agent state, and handoff.
   It is not a separate engine; it is roughly six `@step` methods.
3. **`llama-agents-server` / `llamactl`** — deployment wrappers turning a
   workflow into a REST service or a CLI-shipped agent.

The stated framing: start as a callable function in a notebook, evolve into a
REST API, then scale with durability backends, "all without rewriting code."

The consequence worth carrying forward: LlamaIndex concluded that **an agent is
not a primitive**. The primitive is the orchestration engine; "agent" is a
configuration of it. Everything below follows from that.

## Architecture

### Steps and events, not nodes and edges

A workflow is a class whose methods are decorated with `@step`. A step is an
async function that takes one event and returns another:

```python
class HelloWorkflow(Workflow):
    @step
    async def greet(self, ev: StartEvent) -> StopEvent:
        return StopEvent(result=f"Hello, {ev.name}")
```

Events are user-defined Pydantic models. `StartEvent` and `StopEvent` are the
two reserved ones.

**The edges are not written down.** Routing is by *type dispatch on the returned
event*: the engine reads the step's Python type annotations, builds a map from
event type to consuming step, and delivers each emitted event to whatever step
declares it as its parameter. The docs make the contrast explicit — there is "no
need to explicitly define the paths between nodes." A branch is an ordinary
`if` returning one of two event types. A loop is a step returning an event that
an earlier step consumes. Neither requires engine support.

This is the deliberate rejection of the DAG. The reasoning given: DAG-based
approaches "are designed to prevent cycles and ensure a one-way flow of
information, making it difficult to revisit or modify previous steps." Agentic
control flow is inherently cyclic — retry, reflect, re-plan — so the graph
formalism was discarded rather than worked around.

### Static validation of a dynamic graph

Because the wiring lives in type annotations, the engine can reconstruct the
graph statically. Before any run, `validate()` checks that a `StartEvent`
consumer and a `StopEvent` producer exist, that every produced event type has a
consumer, and that there are no dead ends. `disable_validation=True` exists and
the docs call it "not recommended." `skip_graph_checks` allows selective bypass.

This is the compensating mechanism for having no explicit edges. The tradeoff is
that **the annotations are load-bearing runtime metadata, not documentation** —
a missing return annotation is a validation failure, not a style issue.

### Concurrency: fan-out via the event bus

Three mechanisms, all event-shaped:

- A step returning `list[Event]` fans out.
- `ctx.send_event(ev)` emits an event mid-step without returning, so a step can
  dispatch N events and continue.
- `ctx.collect_events(ev, [TypeA, TypeB, ...])` is the join: it buffers arriving
  events and returns `None` until the full set has arrived, at which point the
  collecting step proceeds. The step is re-entered per arriving event and
  no-ops until complete.

`@step(num_workers=4)` sets per-step concurrency (default 4). Note the design:
the join is **explicit and inside a step**, not a graph construct. There is no
"parallel node" concept.

### Retry and timeout

`@step(retry_policy=...)` attaches a per-step retry policy; absent one, there is
no automatic retry. `ctx.retry_info()` exposes attempt number, elapsed time, and
prior exceptions to the step itself. The `Workflow` constructor takes
`timeout` (default 45 seconds, `None` to disable) and `num_concurrent_runs`.

### Context: the only shared mutable state

`Context` is per-run and passed to steps that annotate for it. It carries:

- `ctx.store` — "type-safe, async state store shared across steps." At 1.0 this
  became **typed**: a Pydantic model, or `DictState` for dynamic
  dictionary-style access. Default backend `InMemoryStateStore` — lockless
  reads, serialized writes.
- `ctx.send_event` / `ctx.collect_events` / `ctx.wait_for_event`.
- `ctx.write_event_to_stream(ev)` — publishes to the streaming channel.
- `ctx.to_dict()` / `Context.from_dict(workflow, d)` — serialization.

Serializers are pluggable: `JsonSerializer` (JSON-first, Pydantic-aware) and
`PickleSerializer` (JSON first, Pickle fallback for objects JSON cannot hold).
The existence of the Pickle fallback is an admission that arbitrary Python
objects in state cannot be durably serialized in general.

### Streaming and the handler

`wf.run(...)` returns a `WorkflowHandler` immediately rather than a result. The
caller can `await` it for the final result or iterate `handler.stream_events()`
for intermediate events. Anything written to the stream by any step is
observable live — so progress reporting is the *same* mechanism as control flow,
just a different channel, not a separate callback system.

### Durability: bolted on, not intrinsic

`WorkflowCheckpointer` wraps `Workflow.run()` and injects a callback that
records, per completed step: the step name, its input event, its output event,
and a snapshot of the `Context`. In-memory by default; the docs describe
extending it to a `PersistentWorkflowCheckpointer` for durability across process
executions. There is an open feature request for built-in file-backed
checkpoint persistence, which is itself the evidence that this is not core.

**This is a real difference from LangGraph**, where durable execution is the
foundational claim. In Workflows, durability is a decorator over an engine that
was designed to run in memory. The extracted-package README lists "durability &
persistence (pluggable backends)" as a feature, not as the architecture.

### Resource injection

`@step` inspects `typing.Annotated` parameters for `Resource(factory)` wrappers:

```python
async def my_step(self, ev: E, memory: Annotated[Memory, Resource(get_memory)]) -> F: ...
```

The factory is called by a `ResourceManager` and the value injected. This is
dependency injection at step granularity — a step declares what it needs rather
than reaching for a module global. Directly comparable in spirit to crescent's
caps-first rule, though it is a convenience feature here rather than an enforced
constraint.

### `AgentWorkflow` is just six steps

The agent layer is a `Workflow` subclass (`AgentWorkflow`, combining
`WorkflowMeta` and `ABCMeta` metaclasses, mixing in `PromptMixin`) whose step
chain is:

```
AgentWorkflowStartEvent
  → init_run          (init Context + memory, process user message)
  → setup_agent       (pick duty agent, merge its system_prompt + state into chat history)
  → run_agent_step    (resolve that agent's tools, call the LLM)
  → parse_agent_output(count iteration, structured output, route to tools or stop)
  → call_tool         (execute, one event per call)
  → aggregate_tool_results (collect, apply handoff, loop back to AgentInput)
```

Event types in flight: `AgentInput`, `AgentSetup`, `AgentOutput`, `ToolCall`,
`ToolCallResult`, `AgentStream`, `AgentStreamStructuredOutput`. The loop back
from `aggregate_tool_results` to `AgentInput` is an ordinary cycle in the event
graph — the agent loop uses no machinery a user workflow could not use.

This is the payoff of the decision. There is no privileged agent runtime to
escape from: a user who outgrows `AgentWorkflow` rewrites those six steps in
their own workflow, with the same engine, same Context, same streaming.

## Tool-Calling Protocol

Tools are `FunctionTool` objects, normally built by `FunctionTool.from_defaults`
or by passing bare Python functions to an agent.

**Schema derivation is automatic and three-sourced:**

1. `create_schema_from_function` builds a Pydantic schema from type hints.
2. Docstrings are parsed for parameter descriptions — Sphinx, Google, and
   Javadoc formats, via regex.
3. Name and description default from the function name and docstring, both
   overridable.

The decision here is that **the tool schema is derived, never hand-written**.
The function signature is the single source of truth for the wire schema. There
is no separate declaration to drift out of sync.

Other protocol details:

- **Sync/async parity is forced.** Both `call()` and `acall()` always exist; a
  sync function is wrapped with `sync_to_async` and vice versa. Callers never
  branch on which kind of function a tool wraps.
- **Context injection.** If a tool's signature declares a `Context` parameter,
  the engine detects it, requires the context in kwargs, and *excludes that
  parameter from the generated JSON schema*. So a tool can read and write
  workflow state without the LLM ever seeing that capability. Missing context
  raises `"Context is required for this tool"`.
- **`partial_params`** pre-binds arguments and removes them from the schema —
  the mechanism for injecting caller-controlled values (a user id, a tenant)
  that the model must not choose.
- **`return_direct`** on tool metadata terminates the workflow with the tool's
  output instead of feeding it back to the LLM. A per-tool escape from the loop.
- **Callbacks** run after the function and before the return, and may replace
  the string content or override the whole `ToolOutput`.
- **Error handling.** In `AgentWorkflow.call_tool`, exceptions are caught and
  wrapped as a `ToolOutput` with `is_error=True`, then fed back to the model.
  The model is the retry mechanism at the tool level; `retry_policy` is the
  mechanism at the step level. These are separate and do not interact.
- `ToolOutput` retains raw input and raw output alongside the string content,
  for debugging and for structured consumers.

The whole tool interaction is also visible as events (`ToolCall`,
`ToolCallResult`) on the stream, so tool traffic is observable without
instrumentation hooks.

## Context/Memory Management

Two distinct things share the word "context" here, and the project keeps them
separate:

- **`Context`** — workflow run state (above). Not the LLM's context window.
- **`Memory`** — the chat history and its long-term extensions.

### Short-term: token-budgeted buffer

The `Memory` class holds a token-limited message buffer. Documented defaults:

- `token_limit` — 30,000, the total budget.
- `chat_history_token_ratio` — 0.7, the share reserved for recent raw chat.
- `token_flush_size` — 3,000, how much is evicted at a time when the limit trips.

Eviction is a **waterfall**: overflow does not vanish, it flushes *into* long-term
memory blocks.

### Long-term: composable memory blocks

Blocks implement `BaseMemoryBlock` and receive flushed messages:

- `StaticMemoryBlock` — fixed content (user profile, standing instructions).
- `FactExtractionMemoryBlock` — an LLM extracts durable facts from evicted
  messages, and condenses its own fact list when that exceeds its limit.
- `VectorMemoryBlock` — writes evicted message batches to a vector store,
  retrieves by semantic similarity against the current turn.

Each block has a `priority`. When total memory still exceeds the budget after
flushing, blocks are truncated in priority order; `priority=0` is never
truncated. `insert_method` decides whether retrieved long-term content is
spliced into the system message or into the latest user message.

`memory.get()` merges short-term and long-term into one message list.

**The decision worth noting:** LlamaIndex treats context management as a
*budget allocation problem with a pluggable eviction policy*, not as a fixed
strategy. Summarization, fact extraction, and vector recall are three
interchangeable implementations of one interface, and their token shares are
explicit numbers a user tunes. It is the most fully-specified memory design
among the harnesses surveyed here.

**It is still a chat transcript underneath.** The unit is the message; the
ordering is chronological; long-term memory is a lossy compressor over an
append-only turn log. It does not question the transcript model — it manages it
well.

In `AgentWorkflow`, memory lives in `ctx.store` and **all agents share one
memory object**. Handoff does not reset history.

## Sandboxing & Permissions

**There is no built-in permission or approval model.** Reading
`multi_agent_workflow.py`, the tool-call path goes straight from
`parse_agent_output` to `call_tool` with no gate. The docs describe no tool
allow/deny mechanism, no confirmation prompt, no capability scoping.

What exists instead:

- **`can_handoff_to`** restricts *which agents* an agent may transfer to. This
  is a routing constraint, not a security boundary — it is enforced by only
  generating handoff `FunctionTool`s for eligible targets, so it constrains the
  model's menu rather than checking at execution.
- **Sandboxing is delegated to external infrastructure.** LlamaIndex's own
  guidance points at Azure Container Apps dynamic sessions for code execution,
  and third-party sandbox vendors publish integration guides. The framework's
  position is that isolation is the deployment's job.
- Human-in-the-loop (below) *can* be used to build approval, since a step may
  block on a `HumanResponseEvent` before calling a tool, but nothing ships that
  wires it to tool calls.

Gap: I found no documentation of a filesystem or network policy layer in the
framework itself, and no per-tool trust annotation.

### Human-in-the-loop

The mechanism is worth recording precisely because it is where durability and
control flow meet:

```python
response = await ctx.wait_for_event(
    HumanResponseEvent,
    waiter_event=InputRequiredEvent(prefix="Approve? "),
    waiter_id="unique_id",
    requirements={"user_name": "alice"},
)
```

`waiter_event` is written to the stream so the caller knows input is needed.
`waiter_id` distinguishes multiple waits in one step. `requirements` route the
right response to the right waiter when several steps await the same event type.
Pausing is implemented by raising an internal exception at the `wait_for_event`
call; the caller snapshots `handler.ctx.to_dict()`, stores it, cancels the
handler to avoid an orphaned in-memory process, and later rebuilds via
`Context.from_dict(workflow, d)`.

**The critical documented caveat:** "The step always runs at least once up to
the waiter" — on resume, everything before the wait *replays*. Step code
preceding a wait must be idempotent. This is the cost of implementing pause via
exception-and-replay rather than continuation capture, and the docs state it
outright rather than hiding it.

## Multi-Agent Support

The docs present three patterns and, unusually, **rank them on two axes rather
than recommending one** — code complexity (⭐ / ⭐⭐ / ⭐⭐⭐) against flexibility
(★★ / ★★★ / ★★★★★):

1. **`AgentWorkflow` handoff** — peer agents transfer control. Least code,
   least flexible. Implementation: for each eligible target an async `handoff()`
   is exposed as a generated `FunctionTool`; calling it writes `"next_agent"`
   into `ctx.store`, and `aggregate_tool_results` reads that and switches the
   duty agent on the next loop. Agents must have unique names *and unique
   descriptions* — validated at construction, because the descriptions are what
   the handoff tool schema shows the model.
2. **Agents as tools (orchestrator)** — specialists do not know about each
   other; their `run` methods become tools on a top-level agent. Moderate code,
   moderate flexibility. All routing decisions funnel through one model.
3. **Custom planner** — prompt the LLM for a structured plan (XML/JSON) and
   execute it imperatively in a hand-written workflow. Most code, any topology.

Shared state across agents is the same `ctx.store`, and shared memory is the
same `Memory` — so a handoff is a change of system prompt and tool set, not a
context reset. `state_prompt` optionally renders workflow state into the agent's
prompt each turn.

Termination is by iteration counting in `parse_agent_output` plus the workflow
`timeout`.

## Notable Design Decisions

1. **The agent abstraction was subordinated to a general orchestration engine,
   and then that engine was extracted from the project.** `AgentWorkflow` has no
   privileged machinery. This is the most distinctive decision here: LlamaIndex
   concluded its own agent abstraction was the wrong primitive and rebuilt
   beneath it, accepting that the orchestration engine would be usable — and
   marketed — entirely without LlamaIndex.

2. **Edges are inferred from type annotations, not declared.** Buys cycles for
   free and eliminates a wiring DSL; costs the ability to read control flow
   without reading every step signature, mitigated by mandatory pre-run graph
   validation.

3. **The DAG was rejected explicitly.** Stated reason: agentic control flow
   needs to revisit prior steps, and acyclicity forbids it.

4. **Join is a step-local operation (`collect_events`), not a graph construct.**
   Fan-in is written in the consuming step, which keeps the engine simple at the
   cost of the join condition being invisible to static tooling.

5. **Tool schemas are derived from Python signatures and docstrings — never
   authored.** One source of truth; no drift possible.

6. **Tool parameters can be hidden from the model** — `Context` injection and
   `partial_params` both remove parameters from the emitted schema. A clean
   separation between what a tool needs and what the model may choose.

7. **Memory is a token budget with pluggable eviction, not a strategy.** Named
   ratios, a flush size, priority-ordered truncation, and interchangeable
   long-term blocks.

8. **Pause is exception-and-replay, and the idempotency requirement is
   documented rather than papered over.**

9. **Durability is a wrapper (`WorkflowCheckpointer`), not the foundation** —
   the opposite of LangGraph's choice, and the clearest fork in the road between
   the two.

10. **The multi-agent docs decline to pick a winner**, publishing a
    complexity/flexibility ranking instead.

11. **No security model, by choice.** Isolation is deferred to the deployment
    environment; the framework ships no permission layer at all.

## Relevance to Crescent

Crescent's `lib/taskgraph` and Workflows solve the same problem from opposite
ends, which makes the comparison unusually sharp.

**Where they differ structurally.** `lib/taskgraph` is a demand-driven spawn
tree: `ctx:result(id)` *is* the scheduler, execution order is the Lua call
stack, and the dependency edge is discovered by the act of demanding a result.
Workflows is a push-based event bus: a step emits, the engine routes by type.
Crescent's model gets memoization, lineage, and a natural audit graph for free
and needs no graph validation pass, because there is no declared graph to
validate. Workflows gets cycles, fan-out, and mid-step emission for free, and
needs the validation pass precisely because its graph is implicit.

Neither model obviously dominates. What is worth extracting is that Workflows'
*loop* — the thing crescent's `lib/ai/tools.lua` hardcodes — is expressible in
its substrate rather than built into it. `lib/taskgraph/executor/ai.lua` already
gestures at the same move by spawning each tool call as a task node, which is
the crescent-shaped version of "the agent loop is not privileged." That the
`llm.tool_loop` executor is a *reimplementation* of `lib/ai/tools.lua` rather
than a call into it is the symptom LlamaIndex resolved by making the general
engine primary and the agent a configuration of it.

**Directly applicable, low-cost:**

- **Derive tool schemas rather than declaring them twice.** `lib/ai/tools.lua`
  currently requires parallel `tools` and `handlers` tables bound only by a
  string name at dispatch, with nothing validating agreement — and
  `executor/ai.lua` has already drifted to a different key name
  (`input_schema` vs `parameters`) for the same field. LlamaIndex's answer is
  one source of truth. Lua lacks type hints, so full derivation is unavailable,
  but a single tool record carrying schema *and* handler together closes the
  drift.
- **Hidden parameters.** `Context` injection and `partial_params` — parameters a
  tool needs but the model may not choose — map cleanly onto crescent's
  caps-first rule and would let a task-graph `ctx` be handed to a handler
  without appearing in the wire schema.
- **`return_direct`.** A per-tool loop-exit flag is a few lines and removes a
  class of wasted round-trip.
- **Errors as `is_error` tool results.** Crescent already does this. LlamaIndex
  additionally keeps step-level retry as a *separate* mechanism from
  model-level recovery; crescent has retry only as a userland combinator
  (`combinators.exec_retry`), which is arguably the cleaner placement given
  taskgraph's spawn-per-attempt lineage.

**Worth deliberating, not copying:**

- **Memory.** LlamaIndex's token-budget-with-eviction design is the most
  complete in this survey, but it is a compressor over a chat transcript. The
  draft `docs/agent-design.md` (in an unmerged worktree, status "draft / not
  implemented") argues the opposite thesis — context as an atemporal *set of
  facts* with replace semantics, chronology living only in the audit graph, and
  names "conversational accumulation" as the anti-pattern. These are
  incompatible positions. LlamaIndex is best read here as the strongest
  available statement of the case crescent's draft rejects: if the transcript
  model is kept, the budget/ratio/priority machinery is what keeping it costs.
  I have not verified whether that draft is current; it should not be treated as
  settled either way.
- **Durability.** Crescent's `lib/taskgraph` has no persistence, no resume, no
  cancellation — verified by grep, zero hits. Workflows' `WorkflowCheckpointer`
  (last step, its input event, its output event, Context snapshot) is a
  well-scoped shape to copy *if* durability is wanted. The exception-and-replay
  pause with a documented idempotency requirement is the honest cheap version;
  LangGraph's foundational durability is the expensive one. That is a real
  open tradeoff, not a settled call.
- **Concurrency.** `collect_events` presupposes concurrency; taskgraph is
  strictly single-threaded (no `coroutine` usage at all). The join-inside-a-step
  idea does not transfer until that changes.

**Explicitly not applicable:** the Pydantic/type-annotation-driven wiring has no
LuaJIT analogue and would require exactly the kind of framework machinery
`CLAUDE.md` bars from `lib/`. The deployment layer (`llama-agents-server`,
`llamactl`) is out of scope — that is HTTP-server framework code.

**The one architectural question this survey raises for crescent's agent app:**
LlamaIndex's central move was refusing to let "agent" be a primitive. Crescent
has the engine already (`lib/taskgraph`) and a separate hardcoded agent loop
(`lib/ai/tools.lua`), with a partial third implementation bridging them
(`executor/ai.lua`). Whether the planned `lib/platform/apps/` agent is built
*on* taskgraph as a configuration of it, or beside it as its own loop, is the
same fork LlamaIndex faced. This survey does not answer it; it records that the
project which faced it chose the engine, and paid for that choice by rewriting
its agent layer.

## Sources

- [Workflows 1.0: Lightweight Agentic Framework Guide — LlamaIndex blog](https://www.llamaindex.ai/blog/announcing-workflows-1-0-a-lightweight-framework-for-agentic-systems)
- [run-llama/workflows-py (README)](https://github.com/run-llama/workflows-py)
- [run-llama/llama-agents](https://github.com/run-llama/llama-agents)
- [`multi_agent_workflow.py` source](https://github.com/run-llama/llama_index/blob/main/llama-index-core/llama_index/core/agent/workflow/multi_agent_workflow.py)
- [`function_tool.py` source](https://github.com/run-llama/llama_index/blob/main/llama-index-core/llama_index/core/tools/function_tool.py)
- [Understanding Workflows — docs](https://developers.llamaindex.ai/python/framework/understanding/workflows/)
- [Workflow class API reference](https://developers.llamaindex.ai/python/workflows-api-reference/workflow/)
- [Context API reference](https://developers.llamaindex.ai/python/workflows-api-reference/context/)
- [`@step` decorator API reference](https://developers.llamaindex.ai/python/workflows-api-reference/decorators/)
- [Human in the Loop — docs](https://developers.llamaindex.ai/python/llamaagents/workflows/human_in_the_loop/)
- [Multi-agent patterns in LlamaIndex — docs](https://developers.llamaindex.ai/python/framework/understanding/agent/multi_agent/)
- [Agent Memory — docs](https://developers.llamaindex.ai/python/framework/module_guides/deploying/agents/memory/)
- [Checkpointing Workflow Runs — docs](https://developers.llamaindex.ai/python/examples/workflow/checkpointing_workflows/)
- [Workflow Resources — docs](https://docs.llamaindex.ai/en/latest/understanding/workflows/resources/)
- [Feature request: persist file checkpoint (issue #19858)](https://github.com/run-llama/llama_index/issues/19858)
- [Secure Code Execution in LlamaIndex with Azure Container Apps — LlamaIndex blog](https://www.llamaindex.ai/blog/secure-code-execution-in-llamaindex-with-azure-container-apps-dynamic-sessions)
- [Deep Dive into LlamaIndex Workflow: Event-driven LLM architecture](https://www.dataleadsfuture.com/deep-diving-into-llamaindex-workflow-event-driven-llm-architecture/)
- [Diving into LlamaIndex AgentWorkflow](https://www.dataleadsfuture.com/diving-into-llamaindex-agentworkflow-a-nearly-perfect-multi-agent-orchestration-solution/)
- [LlamaIndex Workflows: Navigating a New Way To Build Cyclical Agents — Arize AI](https://arize.com/blog/llamaindex-workflows-a-new-way-to-build-cyclical-agents/)
