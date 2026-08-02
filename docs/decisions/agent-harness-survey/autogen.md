# AutoGen (microsoft/autogen) — prior-art survey

Survey of AutoGen as prior art for an agentic harness. Focus is on the
*decisions* the project made and the stated reasons, not a feature list.
Everything below is sourced from the repo README and the official
`microsoft.github.io/autogen` docs; see Sources. Where a claim is inference
rather than something the docs state, it is marked **(inference)**.

## Overview

AutoGen is a Microsoft Research–originated framework for building multi-agent
AI applications that "can act autonomously or work alongside humans". Its
historically notable contribution is the *conversable agent* model: agents as
participants in a conversation, with an LLM deciding who speaks and what tool
runs, rather than a developer writing an explicit control-flow graph.

Two facts frame the whole survey:

1. **AutoGen was rewritten from the ground up for v0.4.** The v0.2 design —
   `ConversableAgent`, `register_reply`, `GroupChatManager` — was replaced with
   an asynchronous, event-driven, actor-model runtime under a layered API. This
   is the single most instructive thing about the project: it is a framework
   that ran the "conversation-first" design at scale, hit its limits, and
   published what broke.
2. **AutoGen is now in maintenance mode.** The README states it "is in
   maintenance mode and no longer receives new features" and directs new
   projects to Microsoft Agent Framework (MAF), which merges AutoGen's
   multi-agent orchestration with Semantic Kernel's production foundations.
   AutoGen continues to receive bug fixes, security patches, and stability
   updates. So AutoGen is a *complete* case study — a design arc with a start,
   a documented rewrite, and an endpoint — which is more useful as prior art
   than a live project mid-flight.

Current shape: three Python libraries (`autogen-core`, `autogen-agentchat`,
`autogen-ext`) plus AutoGen Studio (no-code GUI) and AutoGen Bench
(benchmarking). Python and .NET are both supported at the Core layer.

## Architecture

### The layered API decision

AutoGen v0.4 splits into three libraries with deliberately different contracts:

- **Core** — event-driven message passing, agent lifecycle, local *and*
  distributed runtime. Unopinionated. The actor model lives here.
- **AgentChat** — a "simplified, opinionated" high-level API for rapid
  prototyping; implements common multi-agent patterns. Closest in spirit to
  v0.2.
- **Extensions** — third-party and first-party integrations: model clients
  (OpenAI, Azure), code executors, memory backends.

The decision worth noting is that AgentChat is *built on* Core rather than
being a separate track, and Core is documented as the escape hatch: when the
opinionated patterns don't fit, you drop a layer without leaving the framework.
The docs frame the two as prototyping-vs-production rather than
beginner-vs-expert.

### Why the rewrite (stated reasons)

The v0.4 architecture-preview post attributes the redesign to community
feedback identifying three problems with the v0.2 conversation-first design:

- **Limited flexibility.** Chat-based agent communication was "intuitive for
  beginners", but developers needed "more flexibility in collaboration
  patterns" and wanted to "build predictable, ordered workflows." The
  conversation metaphor made deterministic workflows awkward to express.
- **Debugging complexity.** "Debugging and scaling agent teams applications
  proved more challenging" as systems grew. Behavior was distributed across
  `register_reply` callbacks with no single place to observe message flow.
- **Customization constraints.** Users wanted to "integrate custom agents built
  using other programming languages or frameworks" — impossible when agent
  identity is a Python class and communication is in-process method calls.

The Microsoft Research post adds: "architectural constraints, an inefficient
API compounded by rapid growth, and limited debugging and intervention
functionality."

Note the shape of these complaints: none of them are about model quality or
prompt engineering. All three are about **the harness being the wrong
substrate** — too coupled, too opaque, too language-bound.

### The actor model as the answer

v0.4 "embraces the actor model of computing to support distributed, highly
scalable, event-driven agentic systems." The key structural claim:

> The design decouples how messages are delivered between agents from how
> agents handle them.

Concretely:

- **Agent runtime** is a first-class object with three responsibilities:
  facilitating agent communication, managing agent identities and lifecycles,
  and enforcing security/privacy boundaries. Agents do not call each other;
  they hand messages to the runtime.
- **Two runtime implementations, one agent contract.**
  `SingleThreadedAgentRuntime` for in-process single-language apps; a
  distributed runtime (host servicer + workers connected via gateways) for
  multi-process, multi-machine, multi-language deployments. Developers "can
  switch between the two runtime types with no change to their agent
  implementation." The agent code is written once against the runtime
  interface.
- **Observability falls out of centralization.** "Event-driven communication
  moves message delivery away from agents to a centralized component, making it
  easier to observe and debug their activities." Debuggability was not bolted
  on; it is a consequence of routing every message through one component.
  OpenTelemetry support, message tracing, and metric tracking sit on this.

### Addressing (topics and subscriptions)

Core supports both direct messaging (send to an agent ID) and publish/subscribe.
The pub/sub design is unusually thought through:

- A **TopicId** is `(topic_type, topic_source)` rendered `Type/Source`. Type is
  an application-defined category (`"GitHub_Issues"`); source is a
  data-dependent identifier (`"github.com/{repo}/issues/{number}"`).
- **TypeSubscription** maps a topic *type* to an agent *type*, without naming
  sources or instance keys. The runtime derives the concrete agent ID by
  combining the agent type with the topic source. The docs call this "portable
  and data-independent" — you never hardcode an agent ID.
- The consequence is **automatic multi-tenancy**: because the agent instance
  key comes from the topic source, one subscription declaration yields one
  agent instance per data item (per user session, per GitHub issue), running in
  parallel. The docs give the tell: "A good indication that you are in a
  multi-tenant scenario is that you need multiple instances of the same agent
  type."

This is the piece with the least equivalent in most agent harnesses: agent
*instance identity* is derived from data, not allocated by the caller.

### Composition over inheritance

The v0.2→v0.4 migration guide documents the shift explicitly: v0.2's
`ConversableAgent` customized via `register_reply` callbacks is replaced by
explicit agent classes. Custom agents subclass `BaseChatAgent` and implement
`on_messages` — one method, one place, "more transparent and testable".
Similarly `llm_config` (a dict) became `model_client` (an injected object).

## Tool-Calling Protocol

**Schema from types, not hand-written JSON.** All tools derive from `BaseTool`,
which "automatically generates JSON schemas". `FunctionTool` wraps a plain
Python function, deriving the schema from type annotations and the docstring:
"The description provides context about the function's purpose and intended use
cases, while type annotations inform the LLM about the expected parameters and
return type." Per-parameter descriptions come from `Annotated[str, "..."]`.

**The loop is three phases** — generation (model emits structured calls),
execution (agent parses arguments and runs the tool), reflection (model
receives results and produces a response).

**The most consequential v0.4 tool decision: tools execute where they are
defined.** In v0.2, `register_function()` registered a tool on *two* agents — a
caller (which had the schema) and an executor (which had the implementation) —
because the conversation model made a UserProxyAgent the only thing allowed to
execute. v0.4 eliminates this: you pass functions via the `tools` parameter to
an agent, and that agent "handles both calling and execution internally." A
whole category of two-agent boilerplate disappeared.

**Reflection is opt-in.** `AssistantAgent` exposes `reflect_on_tool_use`. When
off, the tool result is surfaced directly as a `ToolCallSummaryMessage`; when
on, the model gets another turn to interpret results. This is a real fork —
paying an extra model round-trip is a cost, and the framework declines to
decide for you.

**`max_tool_iterations`** bounds tool invocations within a single run —
the loop-termination guard.

**Everything is a typed message, including intermediate steps.**
`TextMessage`, `ToolCallRequestEvent`, `ToolCallExecutionEvent`,
`ToolCallSummaryMessage`, `HandoffMessage`. A `Response` carries both
`chat_message` (the answer) and `inner_messages` (the full reasoning trace).
The distinction between *messages* (things that are part of the conversation)
and *events* (things that happened) is maintained in the type system, so a UI
can render the trace without parsing text.

**Handoffs are tool calls.** In a Swarm team, the `handoffs` parameter on an
agent generates an implicit `transfer_to_<agent>` tool; the docs state "the
`AssistantAgent` uses the tool calling capability of the model to generate
handoffs." Control transfer is expressed in the *same* mechanism as tool use
rather than a parallel channel — one protocol for "do a thing" and "give the
work to someone else."

## Context/Memory Management

AutoGen makes a distinction that is easy to collapse and that it deliberately
keeps separate:

**`ChatCompletionContext` — what the model sees this turn.** A pluggable policy
object owning the message window, with `add_message`, `get_messages`, `clear`,
`save_state`, `load_state`. Variants:

- `UnboundedChatCompletionContext` — everything.
- `BufferedChatCompletionContext` — last *n* messages (MRU).
- `TokenLimitedChatCompletionContext` (experimental) — bounded by a token
  budget using the model client's token counter, not by message count.
- `HeadAndTailChatCompletionContext` — first *n* plus last *m*, so early
  instructions survive a long conversation.

The decision: **context-window management is a strategy object injected into
the agent, not a heuristic buried in the agent.** The migration guide says this
gives applications "direct control over what messages reach the model."

**`Memory` — a retrieval protocol that mutates the context.** Five methods:
`add`, `query`, `update_context`, `clear`, `close`. The load-bearing one is
`update_context`, which retrieves relevant entries and injects them into the
model context — concretely, concatenating retrieved entries into a
`SystemMessage` prepended to history. Content is `MemoryContent` carrying a
`MemoryMimeType`, so memory is not assumed to be text.

Implementations: `ListMemory` (chronological, no retrieval — the reference
implementation), `ChromaDBVectorMemory` (embeddings, configurable embedder,
similarity threshold, top-k), `RedisMemory` (vector retrieval, for distributed
deployments), `Mem0Memory` (external memory service).

The design point: `Memory` is a *protocol*, and `ListMemory` proves the
protocol does not presuppose a vector database. v0.2's "teachable agent with
database config" — memory as a feature of a specific agent class — was replaced
by memory as an injected capability any agent can have.

**State persistence is separate from both.** v0.2 had no built-in state
management; v0.4 puts `save_state()`/`load_state()` on agents *and* teams,
enabling serialization, resumption, and reverting to a previous state.

## Sandboxing & Permissions

This is the weakest area of the framework relative to its other design work,
and the docs are fairly honest about it.

**Code executors are an abstraction with two default implementations:**

- `DockerCommandLineCodeExecutor` — code runs in a container.
- `LocalCommandLineCodeExecutor` — code runs on the host, carrying the docs'
  warning: "The local version will run code on your local system. Use it with
  caution."

Both write code blocks to files in a `work_dir` and execute them as separate
processes. The Docker variant manages container lifecycle (`auto_remove`,
`stop_container`, usable as a context manager, `atexit` fallback). Local
execution can be confined to a virtualenv via `virtual_env_context` —
dependency isolation, explicitly not a security boundary. v0.4 added async
support and `CancellationToken` for timeouts. `ACADynamicSessionsCodeExecutor`
executes in Azure Container Apps dynamic sessions — a hosted sandbox.

**The isolation model is binary and coarse: container or no container.** There
is no capability model, no filesystem/network allowlist, no per-tool
permission. Docker is the recommended default and the recommendation *is* the
security story.

**Permissions are a runtime concern, not a tool concern.** Approval is done via
`InterventionHandler`s registered on the runtime
(`SingleThreadedAgentRuntime(intervention_handlers=[...])`), with `on_send`,
`on_publish`, and `on_response` hooks. A handler inspects messages in flight —
e.g. matches `FunctionCall` — prompts the user, and either lets the message
through, returns `DropMessage`, or raises to deny.

The architecturally interesting choice: **gating happens at the message layer,
not at the call site.** Because every message crosses the runtime, an
intervention handler is a single chokepoint covering all agents and all tools
uniformly, with no cooperation required from tool authors. That is the same
centralization dividend that produced observability. The cost is that the
handler sees *messages*, so policy is expressed in terms of message shapes
rather than a declared capability set, and the mechanism is a cookbook recipe
rather than a first-class policy system.

## Multi-Agent Support

**AgentChat ships teams as presets**, each a different answer to "who speaks
next":

- **`RoundRobinGroupChat`** — fixed rotation, each agent broadcasting to all.
  Deterministic. The reflection pattern (primary + critic) is built on it.
- **`SelectorGroupChat`** — an LLM picks the next speaker after each message.
  Centralized, dynamic.
- **`Swarm`** — the next speaker is whoever the most recent `HandoffMessage`
  names. Decentralized: "agents locally decide when to hand off rather than
  waiting for central coordination."
- **`MagenticOneGroupChat`** — a generalist orchestration for open-ended web and
  file tasks.
- **`GraphFlow`** — explicit workflow-graph orchestration, the direct answer to
  the v0.4 complaint that users wanted "predictable, ordered workflows."

The set is a spectrum from fully-static (GraphFlow, RoundRobin) to
fully-model-driven (Selector, Swarm). AutoGen declines to pick one — a
reversal of v0.2, where the conversation *was* the framework.

**Termination is a composable object, not an agent callback.** v0.2 put
`is_termination_msg` on agents; v0.4 passes a `termination_condition` to the
*team* (`TextMentionTermination`, `TextMessageTermination`,
`ExternalTermination`, plus max-message and token-budget conditions), and they
compose with `|` and `&`. The migration guide is explicit that this decouples
termination logic from agent definitions — the agent no longer needs to know
what the team is trying to achieve.

**`GroupChatManager` and the mandatory user proxy are gone.** v0.2 required "a
participant that is a user proxy to initiate the chat" and a manager with
custom speaker-selection logic. v0.4 makes teams first-class objects you call
`run()` / `run_stream()` on. `UserProxyAgent` survives but is narrowed to one
job: accepting user input. `human_input_mode` configuration was removed — the
migration guide notes this shifts "the burden of interaction patterns to
application logic."

**Teams compose.** A team satisfies the same interface as an agent, so teams
nest inside teams.

**And the docs argue against using them.** The tutorial: "start with a single
agent for simpler tasks, and transition to a multi-agent team when a single
agent proves inadequate," because teams "demand more scaffolding." A
multi-agent framework whose own documentation tells you to optimize a single
agent first is a strong signal about where the value actually is.

## Notable Design Decisions

1. **Message delivery decoupled from message handling.** The one-sentence
   summary of the rewrite. Observability, distribution, cross-language agents,
   and approval interception are all downstream of this single move.

2. **Agent instance identity derived from data via topic source.** Multi-tenancy
   as a consequence of the addressing scheme rather than a feature.

3. **The runtime is a security/privacy boundary by charter,** listed alongside
   communication and lifecycle as a core responsibility — even though the
   realized mechanism (intervention handlers) is thinner than the charter.

4. **Components are declaratively serializable — but as blueprints, not
   snapshots.** `dump_component()` / `load_component()` round-trip a component
   through a `{"provider": ..., "config": ...}` object validated by a Pydantic
   schema, with version fields. The docs draw the line sharply: "Component
   configuration should be thought of as the blueprint for an object" — *not*
   state serialization, no message history, no runtime state. Blueprints stamp
   out instances; `save_state`/`load_state` handles state, separately. Secrets
   use `SecretStr` so dumping cannot leak keys. This split is what makes
   AutoGen Studio (no-code GUI) possible without a second object model: the GUI
   edits configs, the runtime loads them.

5. **Two APIs, one substrate, and a documented ladder between them.** Most
   frameworks pick low-level-and-verbose or high-level-and-trapped. AutoGen
   shipped both and made the lower one the escape hatch.

6. **Cross-language agents as a design goal, not an integration.** Python and
   .NET agents in one system, because agent identity is a runtime-managed
   address rather than a language object.

7. **Handoff unified with tool calling** rather than given a separate control
   channel.

8. **The rewrite was published with its reasons.** The architecture-preview
   post, the research blog, and the migration guide state what broke and why.
   For prior-art purposes this is the actual asset.

9. **The endpoint: converged into Microsoft Agent Framework.** AutoGen supplied
   the multi-agent orchestration abstractions; Semantic Kernel supplied
   session-based state management, filters, telemetry, and model breadth. The
   read **(inference)** is that AutoGen's research-grade orchestration was
   easier to merge into a production substrate than to grow one — the
   abstractions survived; the runtime did not.

## Relevance to Crescent

Crescent's current state (`lib/ai/`, 800 lines total): `init.lua` (provider
dispatch), `providers/{anthropic,openai,openai_compat,google}.lua`,
`types.lua`, and `tools.lua` — a 79-line `mod.run` implementing exactly the
three-phase loop above (generate → execute via `opts.handlers` → append →
repeat, bounded by `max_rounds`, default 10). Plus `lib/taskgraph` for
orchestration.

Observations, framed as tradeoffs rather than recommendations:

**The loop shape is already right.** `lib/ai/tools.lua` matches AutoGen's
generation/execution/reflection cycle, including the iteration bound
(`max_rounds` ≈ `max_tool_iterations`). Nothing in the survey suggests that
core is wrong.

**Two divergences worth an explicit decision:**

- *Handlers as a table vs. tools as objects.* Crescent takes `tools` (schemas)
  and `handlers` (implementations) as two parallel tables keyed by name.
  AutoGen's `FunctionTool` binds schema and implementation in one object and
  derives the schema from types. Crescent has a typechecker that already knows
  the signature of every handler, so deriving JSON Schema from `--:` annotations
  is available in a way it is not for most languages — a schema-from-annotation
  path would remove the parallel-table drift risk. Cost: the annotation→schema
  mapping is new substrate and needs to handle the type-system features that
  JSON Schema cannot express. This is a real open question, not a settled call.
- *Result reflection is unconditional.* Crescent always loops back to the model
  after tool results. AutoGen makes this `reflect_on_tool_use` because the extra
  round-trip is sometimes pure cost. Whether that fork is worth exposing is a
  product call.

**Two things AutoGen's rewrite argues for doing early:**

- *Model context as an injected policy object.* Crescent's loop currently
  appends to a flat `messages` array with no window policy — fine until it
  isn't. AutoGen's `ChatCompletionContext` (unbounded / buffered / token-limited
  / head-and-tail) is a small, well-factored interface, and the reason to
  introduce it early is that retrofitting a window policy into callers that
  assume a plain array is the expensive version. Per crescent's
  substrate-before-consumers rule, this is the shape of thing that goes in
  before the agent app, not after.
- *Structured events, not text.* AutoGen's separation of `chat_message` from
  `inner_messages`, and its typed `ToolCallRequestEvent` /
  `ToolCallExecutionEvent`, are what let a UI render a trace without parsing.
  Any agent app under `lib/platform/apps/` will want this, and it is much
  cheaper to emit typed events from the start than to reconstruct them.

**The centralization lesson maps onto crescent's caps-first rule.** AutoGen got
observability *and* approval gating from one decision: route every message
through a component that can see it. Crescent's caps discipline (I/O
dependencies injected, never ambient) is the same idea applied to effects
rather than messages — and it is a stronger version, because a cap can be
withheld whereas an intervention handler can only inspect a message after the
decision to send it exists. AutoGen's binary Docker/local sandbox is the part
of its design least worth copying; crescent's cap injection is already a finer
instrument than anything AutoGen offers. **(inference)**

**On multi-agent:** AutoGen's own docs say start with one agent. Crescent
already has `lib/taskgraph` for orchestration, so the question of whether agent
teams belong in `lib/ai` at all — versus agents being taskgraph nodes — is a
genuine fork. AutoGen's answer (teams satisfy the agent interface, so they
nest) is one option; taskgraph-as-the-only-orchestrator is another; they differ
in whether speaker selection is model-driven or graph-driven. No basis in this
survey for calling it.

**On declarative component configs:** AutoGen's blueprint/state split is clean
and would be cheap in Lua (a table with `provider` + `config`). Whether
crescent needs it depends entirely on whether anything will construct agents
from data rather than from code — currently nothing does. **(inference)** Worth
noting only so the split (blueprint ≠ state snapshot) is known if the need
arises.

**Finally, the maintenance-mode outcome is itself data.** The abstractions that
survived into Microsoft Agent Framework were the orchestration ones — agents,
tools, handoffs, termination conditions. The distributed actor runtime did not.
That is at least weak evidence that the elaborate runtime was over-built for
what agent applications actually needed. **(inference — Microsoft has not
stated this rationale.)**

## Sources

- [microsoft/autogen (README)](https://github.com/microsoft/autogen)
- [New AutoGen Architecture Preview](https://microsoft.github.io/autogen/0.2/blog/2024/10/02/new-autogen-architecture-preview/)
- [AutoGen v0.4: Reimagining the foundation of agentic AI for scale, extensibility, and robustness — Microsoft Research](https://www.microsoft.com/en-us/research/blog/autogen-v0-4-reimagining-the-foundation-of-agentic-ai-for-scale-extensibility-and-robustness/)
- [Migration Guide for v0.2 to v0.4](https://microsoft.github.io/autogen/dev//user-guide/agentchat-user-guide/migration-guide.html)
- [Core — Agent Runtime Architecture](https://microsoft.github.io/autogen/stable/user-guide/core-user-guide/core-concepts/architecture.html)
- [Core — Topic and Subscription](https://microsoft.github.io/autogen/stable/user-guide/core-user-guide/core-concepts/topic-and-subscription.html)
- [Core — Tools](https://microsoft.github.io/autogen/stable/user-guide/core-user-guide/components/tools.html)
- [Core — Model Context](https://microsoft.github.io/autogen/stable/user-guide/core-user-guide/components/model-context.html)
- [Core — Command Line Code Executors](https://microsoft.github.io/autogen/stable/user-guide/core-user-guide/components/command-line-code-executors.html)
- [Core — Component Config](https://microsoft.github.io/autogen/stable/user-guide/core-user-guide/framework/component-config.html)
- [Core Cookbook — User Approval for Tool Execution using Intervention Handler](https://microsoft.github.io/autogen/stable/user-guide/core-user-guide/cookbook/tool-use-with-intervention.html)
- [AgentChat — Agents](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/tutorial/agents.html)
- [AgentChat — Teams](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/tutorial/teams.html)
- [AgentChat — Swarm](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/swarm.html)
- [AgentChat — Memory](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/memory.html)
- [autogen_core.model_context API reference](https://microsoft.github.io/autogen/stable/reference/python/autogen_core.model_context.html)
- [Microsoft retires AutoGen and debuts Agent Framework — VentureBeat](https://venturebeat.com/ai/microsoft-retires-autogen-and-debuts-agent-framework-to-unify-and-govern)
- [Microsoft Agent Framework Overview — Microsoft Learn](https://learn.microsoft.com/en-us/agent-framework/overview/)
