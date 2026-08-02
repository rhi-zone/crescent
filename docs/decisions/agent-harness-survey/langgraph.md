# LangGraph — agent harness prior art survey

Survey of `langchain-ai/langgraph` as prior art for an AI agentic harness. Focus
is on the decisions the project made and the reasoning it gives for them, not a
feature inventory. All claims are sourced (see Sources); where the docs did not
answer a question, that is stated as a gap rather than filled in.

## Overview

Repo confirmed live at `github.com/langchain-ai/langgraph` (~38.6k stars, ~7,000
commits at time of survey). It self-describes as a "low-level orchestration
framework for building, managing, and deploying long-running, stateful agents."

The positioning decision matters more than the feature set: LangGraph is
explicitly *not* the chain-composition layer. LangChain provides composable
components; LangGraph provides orchestration and durability underneath them.
The four pillars the README leads with are durable execution, human-in-the-loop,
memory (short-term + long-term as distinct mechanisms), and debuggability via
LangSmith tracing.

The framing consequence: LangGraph treats an agent as a *resumable distributed
computation that happens to call an LLM*, not as a loop with a model in it. Every
other decision below follows from that.

## Architecture

### Pregel / BSP, not a call stack

The execution engine is `Pregel` — an actor/channel model taken from Google's
Pregel and Apache Beam. Actors (`PregelNode`) read from and write to channels.
Execution proceeds in **super-steps**, each with three phases:

1. **Plan** — select actors whose subscribed channels were updated.
2. **Execution** — run the selected actors in parallel to completion, timeout, or failure.
3. **Update** — apply all channel writes *atomically* before the next step.

This is Bulk Synchronous Parallel. It repeats until no actor qualifies or the
recursion limit trips. Nodes in the same super-step run in parallel by
construction; sequential nodes occupy separate super-steps.

Channel types are the state primitives: `LastValue` (most recent value),
`Topic` (pub/sub, configurable dedup/accumulate), `BinaryOperatorAggregate`
(fold via a binary operator), `Context` (lifecycle of external resources with
setup/teardown).

The decision here is that **the atomic unit of progress is a super-step, not a
node call**. That choice is what makes checkpointing, parallelism, and
interruption fall out of one mechanism instead of three.

### StateGraph as the authoring surface

`StateGraph` is the user-facing API and compiles down to Pregel. Its parts:

- **State** — a `TypedDict` or Pydantic model. It is the input/output interface
  for every node and edge.
- **Nodes** — functions `(state, config, runtime) -> partial state update`.
  "Nodes do the work, edges tell what to do next."
- **Edges** — normal (`add_edge`, static) or conditional (`add_conditional_edges`,
  a routing function returning node name(s)). `START` / `END` are virtual nodes.

`.compile()` is a required, explicit step. It validates structure (no orphaned
nodes) and is where runtime concerns — checkpointer, store, breakpoints — get
bound. Separating *topology* from *runtime configuration* means the same graph
can be compiled with a memory saver in dev and Postgres in prod, and lets
subgraphs be compiled *without* a checkpointer while the parent has one.

### Reducers: state is merged, never overwritten

Each state key carries its own reducer. Absent one, an update overwrites. With
one, the update is folded in:

```python
class State(TypedDict):
    messages: Annotated[list[AnyMessage], add_messages]
```

`add_messages` appends new messages and updates existing ones by matching ID.

This is the load-bearing decision behind parallelism: because updates are
*incremental and per-key*, several nodes can run in the same super-step, each
touching different fields, and their results merge deterministically. An
overwrite-semantics state would have made parallel nodes a conflict problem.

### Routing beyond static edges

- **`Send`** — a conditional edge may return `[Send(node, state), ...]`, creating
  dynamic fan-out with *per-branch tailored state*, i.e. map-reduce. The
  destinations need not share the parent's state schema.
- **`Command`** — a node may return `Command(update={...}, goto="node")`,
  combining a state update and a routing decision in one value. This collapses
  the node/edge distinction where it is inconvenient, without removing it
  where it is useful. `Command(graph=Command.PARENT)` routes into the enclosing
  graph — the mechanism multi-agent handoff is built on.

### Graph migration

Checkpointed threads survive topology change. Completed threads accept arbitrary
node/edge edits. Interrupted threads accept everything except removal of a node
(which would break resumption). State keys can be added or removed; renames lose
saved values. That this is specified at all is notable — it treats the
checkpoint as a persisted schema with a migration story, not an opaque blob.

### Functional API as a second front-end

`@entrypoint` / `@task` lets the same runtime be driven by ordinary Python
control flow (`if`, `while`, `for`) instead of declared nodes and edges. `@task`
results are cached in the checkpoint. Both APIs compile to the same durable
engine — the graph is the *model*, not the only notation.

## Tool-Calling Protocol

There is no bespoke tool protocol. LangGraph delegates the wire format to the
model provider's native tool-calling and models the loop as graph structure:

- The model node emits an `AIMessage` which may carry `tool_calls`.
- `ToolNode` (in `langgraph.prebuilt`) reads `tool_calls` off the *last*
  `AIMessage`, dispatches to the matching function, and wraps each result in a
  `ToolMessage` appended to `messages`.
- `tools_condition` is the conditional edge: tool calls present → tool node;
  none → `END`.
- `create_react_agent` is the prebuilt two-node cycle (agent ↔ tools) over
  exactly that, looping until the model stops emitting tool calls.

Two decisions worth naming:

1. **Tool results live in shared state, not in a return value.** A `ToolMessage`
   is a state update like any other, so it is checkpointed, streamable,
   inspectable, and editable by a human before the next model call.
2. **The agent loop is not privileged.** ReAct is a *prebuilt graph*, not the
   framework's core. Anything the loop can do (retry, branch, escalate, hand off)
   is expressible as graph edges rather than as flags on an agent object.

## Context/Memory Management

The design splits memory along a scope axis, and this split is deliberate and
explicit in the docs:

| | Checkpointer | Store |
|---|---|---|
| Scope | one thread | cross-thread |
| Holds | graph state (checkpoints) | application-defined data |
| Purpose | continuity, HITL, time travel, fault tolerance | user preferences, facts, shared knowledge |
| Access | via `thread_id` in config | directly from nodes or app code |

```python
graph = builder.compile(checkpointer=InMemorySaver(), store=InMemoryStore())
```

### Checkpoint structure

The `Checkpoint` TypedDict is the durable unit: `v` (format version), `id`
(monotonically increasing), `ts` (ISO 8601), `channel_values`,
`channel_versions`, `versions_seen`, `updated_channels`. `versions_seen` maps
node → channel versions already observed, which is precisely what the Plan phase
consults to decide eligibility. `CheckpointMetadata` carries `source`
("input" | "loop" | "update" | "fork"), `step`, `parents`, `run_id`.

`BaseCheckpointSaver` is a small interface — `get_tuple`, `list`, `put`,
`put_writes`, `delete_thread`, plus `a*` async variants — with a pluggable
`SerializerProtocol` (default `JsonPlusSerializer`, optional
`EncryptedSerializer`). Backends: `InMemorySaver` (dev), `SqliteSaver`
(single-server), `PostgresSaver` (multi-instance).

`put_writes` existing separately from `put` is the durability tell: partial
writes from a super-step that has not completed are recorded so a crash mid-step
does not re-run already-completed tasks.

### Durability is a tunable, not a constant

Three modes, least to most durable:

- `"exit"` — checkpoint only when execution exits (success, error, or interrupt).
  Fastest; no recovery from a mid-execution crash.
- `"async"` — persist asynchronously while the next step runs. Good balance;
  small window where a crash loses the write.
- `"sync"` — persist before the next step starts. Every checkpoint written;
  costs throughput.

The complementary pattern for granularity: compile the hot interior loop as a
subgraph *without* a checkpointer, and the outer graph *with* one, so only the
decision boundaries pay the write cost.

### Context-window management is separate from persistence

What the model sees and what is persisted are deliberately different. Trimming
and summarization run as `@before_model` middleware — the checkpointer keeps
full history while the model receives a bounded window. Deletion is expressed as
a state update, `RemoveMessage(id=...)` or `RemoveMessage(id=REMOVE_ALL_MESSAGES)`,
which is exactly why `add_messages` requires message IDs: the reducer needs
identity to delete or supersede rather than only append.

State-schema guidance from the docs is a design rule, not a tip: put in the
minimum the conditional edges need to route, plus the accumulating artifacts the
model needs to reason. Not "everything, so nodes can reach it."

## Sandboxing & Permissions

**LangGraph itself has no sandbox and no permission model.** This is the clearest
scope boundary in the project. Isolation is delegated:

- **Interrupts** are the approval mechanism. `interrupt(value)` pauses the graph
  and surfaces a JSON-serializable payload; `Command(resume=...)` supplies the
  answer, which becomes the return value of `interrupt()`. Static breakpoints
  (`interrupt_before` / `interrupt_after` at compile or run time) exist but the
  docs explicitly say they are for stepping through execution, *not* for HITL.
- `HumanInTheLoopMiddleware` (LangChain layer) with `interrupt_on` maps specific
  tool calls to decision types: **approve**, **edit**, **reject**, **respond**.
  Placing `interrupt()` inside a tool function gates that tool at its own call
  site.
- Actual code sandboxing is a *separate project* — `langchain-ai/langchain-sandbox`,
  Pyodide on Deno, with the caveat stated up front that guarantees depend
  entirely on how narrowly you configure Deno's permissions.

### The re-execution rule, and why it is the sharp edge here

Resuming after an interrupt **restarts the whole node from the beginning** — not
from the interrupt line. Consequences the docs call out:

- Code before `interrupt()` must be idempotent. DB inserts and list appends
  before an interrupt duplicate on every resume. Put side effects *after* the
  interrupt, or in a downstream node.
- Multiple interrupts in one node are matched to resume values **by index**, so
  conditionally skipping an interrupt or using a non-deterministic loop
  misaligns them.
- Don't wrap `interrupt()` in a broad `try/except` — it pauses by raising a
  special exception.

This is the cost of the checkpoint-and-replay model: durability is bought with a
determinism obligation pushed onto node authors. Worth noting that external
critiques argue checkpoint-replay is not equivalent to true durable execution
(the Diagrid piece in Sources); that is a contested claim, recorded here as a
position rather than a finding.

## Multi-Agent Support

There is no "agent" primitive. A multi-agent system is a graph whose nodes are
graphs, and **handoff is a routing construct**:

```python
Command(goto="target_agent", update={...}, graph=Command.PARENT)
```

A handoff tool returns that value; `Command.PARENT` routes to the closest
enclosing graph, where the sibling agent's node lives. Destination + payload,
nothing more.

Documented architectures, all built from that one mechanism:

- **Network / swarm** — agents hand control to each other directly, based on
  specialization. Packaged as `langgraph-swarm`.
- **Supervisor** — a central agent owns all routing and delegation. Packaged as
  `langgraph-supervisor`.
- **Supervisor-as-tool** — sub-agents exposed to the supervisor as callable tools.
- **Hierarchical** — supervisors of supervisors.
- **Custom** — arbitrary topology.

Both packaged libraries are built on the same `Command` handoff; the difference
between "supervisor" and "swarm" is topology, not machinery.

Context sharing between agents is a real tradeoff the docs surface rather than
decide: pass the full message history, or pass only the final result. Subgraphs
may have their own state schema and communicate through a mapped subset, so
isolation is available but not imposed.

## Notable Design Decisions

1. **The durable unit is a super-step, not a node.** Atomic channel updates at
   step boundaries give parallelism, checkpointing, interruption, and time travel
   from a single mechanism. This is the load-bearing choice.
2. **Reducers make state merge-based.** Per-key folds are what permit parallel
   nodes at all; overwrite semantics would have forced conflict resolution.
3. **Persistence is split by scope, not by storage.** Checkpointer (thread) vs
   Store (cross-thread) is a semantic distinction, not two backends for one idea.
4. **Durability is a dial (`exit`/`async`/`sync`) plus a structural lever**
   (subgraph without checkpointer inside graph with one) — rather than a fixed
   policy.
5. **The agent loop is a prebuilt, not the core.** `create_react_agent` is one
   graph among many. Nothing in the runtime privileges it.
6. **Topology and runtime bind at `.compile()`.** Same graph, different
   checkpointer/store/breakpoints per environment.
7. **Interrupt is a first-class pause with typed resume**, and it is *also* the
   approval mechanism — one construct for debugging, HITL, and tool gating.
8. **The determinism obligation is stated, not hidden.** Node re-execution on
   resume, index-matched interrupts, and idempotency requirements are documented
   constraints on user code, not implementation details.
9. **Checkpoints have a migration policy.** Topology may change under a live
   thread within stated limits.
10. **Sandboxing is explicitly out of scope.** Approval gates in, isolation out —
    delegated to a separate project.

## Relevance to Crescent

Crescent's current state, from the source (`lib/ai/tools.lua`, `lib/taskgraph/`):

**`lib/ai/tools.lua` (79 lines)** — `mod.run(opts)` is a bounded loop
(`max_rounds`, default 10) over `ai.generate`. It copies `opts.messages` into a
local array, dispatches each `tc.name` to `opts.handlers[tc.name]` under `pcall`,
JSON-encodes non-string results, and appends `{ role = "tool", content, tool_call_id, name }`.
Handler errors and unknown-tool cases both become `{"error": ...}` strings fed
back to the model. There is no persistence, no approval hook, and no state beyond
the local `messages` array.

**`lib/taskgraph/`** — a *spawn tree with lazy demand-driven evaluation*, not a
BSP graph. `graph.add` creates `task_<n>` nodes with `parent_id`/`spawned`;
`ctx:spawn(task_def)` adds a child; `ctx:result(id)` records a dependency edge
and, if the target is still `pending`, executes it inline via `M._run_task`
(recursion, synchronous). `run_task` applies `hooks.scaffolds` to transform a
task def pre-execution, runs the executor under `pcall`, and sets
`status = "done" | "error"`. Optional `track` mode maintains a `frontier` and an
`exec_graph` log. Errors propagate by `error()` out of `ctx:result`.

Points of comparison, stated as observations — not recommendations:

- **Scheduling model differs at the root.** LangGraph plans a frontier per
  super-step and runs it in parallel; crescent's `ctx:result` pulls a dependency
  and runs it *inline on the caller's stack*. Crescent's `frontier.lua` tracks
  state but does not drive scheduling. Whether crescent wants a plan/execute/update
  loop is an open design question, and it is entangled with whether crescent has
  concurrency to exploit.
- **State locus differs.** LangGraph has one shared reducer-merged state; crescent
  has per-task `input`/`output` with no shared channel. Reducers are the
  mechanism LangGraph needed *because* it merges concurrent writes — the same
  need may not exist in a synchronous pull model.
- **No checkpoint boundary exists in crescent.** `TrackedGraph` is an in-memory
  record, not a resumable snapshot; there is no serialization, no `thread_id`
  analogue, no resume. LangGraph's `Checkpoint` shape (`channel_values` +
  `channel_versions` + `versions_seen`) and its `put_writes`/`put` split are the
  concrete prior art if resumability is ever wanted.
- **Crescent's `scaffolds` hook resembles LangChain middleware** (`@before_model`)
  in position — a pre-execution transform of the unit of work — though crescent's
  transforms a `TaskDef` while middleware transforms model input.
- **No approval mechanism in either crescent subsystem.** `lib/ai/tools.lua`
  invokes handlers unconditionally. LangGraph's answer (interrupt + typed
  approve/edit/reject/respond) is a persistence-dependent design; a
  non-persistent equivalent would be a synchronous callback, which is a
  different thing with different guarantees. Which crescent wants is undecided.
- **Caps-first is a divergence in crescent's favor.** LangGraph tools reach for
  ambient resources and bolt permission on via HITL gates; crescent's convention
  (injected caps, error if absent) constrains at construction. The two compose
  — a cap could itself be the gate — but that is a design question, not a
  finding.
- **The determinism obligation is the real transferable warning.** Any
  resume-by-replay design forces idempotency onto executor authors. LangGraph
  documents this cost openly; a crescent equivalent would inherit it.

## Sources

- [langchain-ai/langgraph (README)](https://github.com/langchain-ai/langgraph)
- [Pregel core source — `libs/langgraph/langgraph/pregel/main.py`](https://raw.githubusercontent.com/langchain-ai/langgraph/main/libs/langgraph/langgraph/pregel/main.py)
- [Checkpoint base source — `libs/checkpoint/langgraph/checkpoint/base/__init__.py`](https://raw.githubusercontent.com/langchain-ai/langgraph/main/libs/checkpoint/langgraph/checkpoint/base/__init__.py)
- [Graph API overview](https://docs.langchain.com/oss/python/langgraph/graph-api)
- [Persistence](https://docs.langchain.com/oss/python/langgraph/persistence)
- [Interrupts / human-in-the-loop](https://docs.langchain.com/oss/python/langgraph/interrupts)
- [Human-in-the-loop middleware](https://docs.langchain.com/oss/python/langchain/human-in-the-loop)
- [Short-term memory / context management](https://docs.langchain.com/oss/python/langchain/short-term-memory)
- [Durable execution](https://docs.langchain.com/oss/python/langgraph/durable-execution)
- [Multi-agent systems overview](https://docs.langchain.com/oss/python/multi-agent)
- [Use prebuilt multi-agent systems](https://docs.langchain.com/oss/python/multi-agent-prebuilts)
- [Handoffs](https://docs.langchain.com/oss/python/langchain/multi-agent/handoffs)
- [`create_react_agent` reference](https://reference.langchain.com/python/langgraph.prebuilt/chat_agent_executor/create_react_agent)
- [`Durability` reference](https://reference.langchain.com/python/langgraph/types/Durability)
- [langchain-ai/langchain-sandbox](https://github.com/langchain-ai/langchain-sandbox)
- [LangGraph state management: checkpointing, recovery, persistence-layer decision (ActiveWizards)](https://activewizards.com/blog/langgraph-state-management-checkpointing-recovery-and-the-persistence-layer-decision/) — third-party
- [Checkpoints are not durable execution (Diagrid)](https://www.diagrid.io/blog/checkpoints-are-not-durable-execution-why-langgraph-crewai-google-adk-and-others-fall-short-for-production-agent-workflows) — third-party critique
- Crescent source read directly: `/home/me/git/rhizone/crescent/lib/ai/tools.lua`, `/home/me/git/rhizone/crescent/lib/taskgraph/exec.lua`, `/home/me/git/rhizone/crescent/lib/taskgraph/graph.lua`, `/home/me/git/rhizone/crescent/lib/taskgraph/context.lua`
