# Prior Art Survey: OpenAI Agents SDK

Survey date: 2026-08-02. Repo verified live:
<https://github.com/openai/openai-agents-python> (MIT, ~28.3k stars, ~4.4k
forks, created 2025-03-11, last pushed 2026-08-02 — actively maintained).
Predecessor verified live: <https://github.com/openai/swarm> (~21.9k stars,
created 2024-02-22, not archived but superseded; self-described as an
"Educational framework exploring ergonomic, lightweight multi-agent
orchestration. Managed by OpenAI Solution team.").

**Source confidence.** Claims below are tagged where provenance matters:

- **[primary]** — read from the official documentation site
  (`openai.github.io/openai-agents-python/*`), the repo README, the Swarm
  README, or the GitHub API.
- **[secondary]** — third-party analyses and migration write-ups. Directionally
  useful for *why* framing, but not read from source. Anything load-bearing for
  a crescent design decision should be re-verified against source.

No claim here was verified by running the SDK. Notably, the source tree itself
was not read — this survey is documentation-level. Where a behavioral detail
would change a crescent design decision, it is flagged as needing source
verification.

## Overview

The OpenAI Agents SDK is a Python framework for building agentic LLM
applications. Its README describes it as "a lightweight yet powerful framework
for building multi-agent workflows," explicitly "provider-agnostic, supporting
the OpenAI Responses and Chat Completions APIs, as well as 100+ other LLMs"
**[primary]**.

It is the production successor to **Swarm**, OpenAI's 2024 experimental
framework. The docs state plainly that the SDK is "a production-ready upgrade
of our previous experimentation for agents, Swarm" **[primary]**. Swarm's own
README labels it "experimental, educational," notes it "runs almost entirely on
the client" and is "stateless between calls," and directs users to the Agents
SDK for production **[primary]**.

The evolution is the most informative part of this survey, because Swarm was a
deliberate exercise in *minimalism first*: two primitives (Agents and
Handoffs), no state, no infrastructure. What the Agents SDK added is therefore a
precise, empirically-derived list of what minimalism actually cost. Third-party
migration analyses characterise Swarm's gaps as the production checklist: "no
tracing, no guardrails, no retries, no streaming-friendly architecture, no
session management" **[secondary]**. The SDK "keeps the routines + handoffs
core and adds the production layer" **[secondary]**.

The two stated design principles are quotable and worth taking literally
**[primary]**:

1. "Enough features to be worth using, but few enough primitives to make it
   quick to learn."
2. "Works great out of the box, but you can customize exactly what happens."

## Architecture

### Primitives

The docs name three fundamental building blocks **[primary]**:

- **Agents** — LLMs equipped with instructions and tools.
- **Handoffs** — agents delegating to other agents for specialized tasks.
- **Guardrails** — validation of agent inputs and outputs.

Sessions, tracing, and human-in-the-loop are presented as supporting systems
rather than core primitives, though the concept index lists ten components
overall (adding sandbox agents, realtime agents, voice agents, agents-as-tools,
tools, and human-in-the-loop) **[primary]**. The three-primitive framing is the
marketing surface; the ten-component list is the actual API surface. That gap is
itself a signal — see Notable Design Decisions.

### The Agent object

An `Agent` is a configuration record, not a running thing **[primary]**. Its
surface:

- `instructions` — static string *or* a function computing them from context at
  runtime.
- `model` / `model_settings` — including `tool_choice` (`auto` / `required` /
  `none` / a named tool).
- `tools`, `handoffs`.
- `output_type` — a Pydantic model, dataclass, or type-adapter-compatible
  schema; makes the agent produce structured output instead of text.
- context generic parameter (see Context/Memory Management).
- `hooks` (`AgentHooks`) — per-agent lifecycle callbacks.
- `input_guardrails` / `output_guardrails`.
- `tool_use_behavior` — `"run_llm_again"` (default), `"stop_on_first_tool"`,
  `StopAtTools(...)`, or a custom `ToolsToFinalOutputFunction`.
- `reset_tool_choice` — resets `tool_choice` after a tool call to prevent
  infinite tool-calling loops; configurable.
- `clone()` — duplicate with property overrides.

The separation matters: an agent holds no conversation state and no execution
state. It is a value.

### The Runner and the loop

`Runner.run()` / `run_sync()` / `run_streamed()` own execution **[primary]**.
The loop is: call the model with the current agent and input, then dispatch on
the response, with exactly three terminating or continuing outcomes:

1. **Final output** — "The LLM produces text output with the desired type, and
   there are no tool calls." Loop ends.
2. **Handoff** — the current agent and input are both replaced and the loop
   re-runs.
3. **Tool calls** — tools execute, results are appended, loop re-runs.

`max_turns` bounds the loop and raises `MaxTurnsExceeded`; `max_turns=None`
disables the bound entirely **[primary]**. `RunConfig` carries per-run global
settings: model override across all agents, `tool_execution` (concurrency and
error handling), input filters and guardrails, tracing metadata.

The important structural decision: **a handoff is not a nested call.** It
rebinds the loop's current agent in place. There is no stack, no return to the
delegating agent. This is what makes handoffs cheap and also what makes
"delegate and come back" a different mechanism entirely (agents-as-tools).

### Orchestration: LLM vs code

The docs treat orchestration strategy as an explicit, named choice rather than
a framework decision **[primary]**:

- **Orchestrating via LLM** — "the LLM can autonomously plan how it will tackle
  the task, using tools to take actions and acquire data, and using handoffs to
  delegate tasks to sub-agents." Recommended tactics include investing in
  prompts, self-critique loops, narrow specialist agents over generalists, and
  "Invest in evals."
- **Orchestrating via code** — "makes tasks more deterministic and predictable,
  in terms of speed, cost and performance." Patterns: structured outputs feeding
  conditional routing, sequential chaining, quality-gated feedback loops,
  parallel independent runs.

The stated tradeoff: LLM orchestration for open-ended reasoning tasks, code
orchestration for determinism and cost control. The SDK deliberately does not
provide a graph/workflow DSL for the code path — "complex agent orchestration
through Python rather than specialized abstractions" is listed as a *reason to
use* the SDK **[primary]**. This is the sharpest philosophical contrast with
LangGraph.

### Model layer

Two interfaces **[primary]**: `Model` (how an agent talks to a backend) and
`ModelProvider` (name → `Model` at runtime). Two OpenAI implementations:

- `OpenAIResponsesModel` (recommended) — Responses API; supports tool search /
  deferred tool loading, programmatic tool calling, **server-side context
  compaction**, WebSocket transport.
- `OpenAIChatCompletionsModel` — broader provider compatibility, fewer features.

Explicit warning: "we recommend using a single model shape for each workflow
because the two shapes support a different set of features and tools"
**[primary]**. Mixing risks runtime errors when a feature exists on one surface
only.

Three configuration tiers: global default client, run-level `ModelProvider`,
per-agent `model`. Third-party breadth comes from beta adapters (Any-LLM,
LiteLLM) rather than in-tree provider implementations, and the docs are candid
that "feature parity depends on the underlying provider's implementation"
**[primary]**.

## Tool-Calling Protocol

Tools are declared, not hand-written as schemas **[primary]**:

- `@function_tool` (docs also show a `@tool` decorator) converts a Python
  function into a tool. Sync or async.
- Schema generation is automatic: `inspect` reads the signature, Pydantic
  generates the JSON schema, and **`griffe` parses the docstring** to populate
  tool and argument descriptions — Google, Sphinx, and NumPy styles supported.
  Pydantic `Field` constraints (min/max, patterns) flow into the schema.
- `is_enabled` — a boolean or a predicate over context, evaluated at runtime, so
  the tool set presented to the model can vary per turn.
- `failure_error_function` — when a tool raises, this callback produces the
  message the model sees. A default exists; passing `None` re-raises for manual
  handling.
- **Hosted tools** — web search, file search over Vector Stores, sandboxed code
  execution, remote MCP servers, image generation, tool search. These execute
  server-side on `OpenAIResponsesModel`, not in the SDK's loop.
- `Agent.as_tool()` — expose an agent as a callable tool, with structured
  Pydantic input, approval gates, custom output extraction, and streaming event
  callbacks.

The decision worth naming: **the docstring is the tool description.** There is
no separate registration table mapping names to schemas to handlers. The
function *is* the declaration, the schema, and the implementation. That closes,
by construction, the class of bug where the schema and the handler drift apart.

`tool_use_behavior` on the agent controls what happens after tools run —
notably `"stop_on_first_tool"`, which makes a tool's return value the agent's
final output without another model call. That is a cost/latency lever, not just
a convenience.

## Context/Memory Management

The SDK splits "context" into two things that most frameworks conflate, and the
distinction is stated bluntly **[primary]**.

**Local context** (`RunContextWrapper[T]`) — a user-defined object (dataclass or
Pydantic model) threaded through the run. "The context object is not sent to the
LLM. It is purely a local object that you can read from, write to and call
methods on it." Tool functions, lifecycle hooks, and callbacks all receive
`RunContextWrapper[T]` and reach the object via `wrapper.context`. This is
dependency injection — DB handles, user identity, request-scoped state. One
constraint: "every agent, tool function, lifecycle etc for a given agent run
must use the same type of context." `ToolContext` extends it with `tool_name`,
`tool_call_id`, `tool_arguments`.

**LLM context** — "When an LLM is called, the only data it can see is from the
conversation history." Four channels get information into it: instructions
(static or dynamic), input messages, function tools that fetch on demand, and
retrieval/web-search tools.

**Sessions** are the persistence layer for LLM context **[primary]**. The
interface is four operations:

- `get_items(limit)` — retrieve history, optionally the most recent N.
- `add_items(items)` — persist new items after a run.
- `pop_item()` — remove and return the most recent item (corrections, undo).
- `clear_session()`.

Backends shipped: `SQLiteSession`, `AsyncSQLiteSession`, `RedisSession`,
`SQLAlchemySession`, `MongoDBSession`, `DaprSession`,
`OpenAIConversationsSession` (server-managed on OpenAI's infrastructure), and
`EncryptedSession` — a transparent encryption *wrapper over any backend*
**[primary]**. The wrapper-over-backend shape is the notable bit: encryption is
composed, not reimplemented per store.

Persistence semantics: the runner merges retrieved history with new input before
the model call, and "preserves only genuinely new items — reordering or
filtering historical context doesn't cause re-storage" **[primary]**. A
`session_input_callback` customises how history and new input combine without
altering what gets persisted — i.e. *what the model sees* and *what is stored*
are deliberately decoupled.

Four mutually-exclusive multi-turn strategies exist **[primary]**:
`to_input_list()` (manual), Sessions (SDK-managed storage), `conversation_id`
(OpenAI server-managed), `previous_response_id` (response chaining). The SDK
does not pick one for you.

Compaction: server-side context compaction is a Responses-API feature, not an
SDK-level algorithm **[primary]**. Sandbox agents list "compaction" among their
capabilities, and handoffs have a `nest_handoff_history` setting that "compacts
summarizable history into summary segments while preserving lossless messages"
**[primary]** — this is the one place the SDK itself implements summarisation,
and it would need source verification before being copied.

## Sandboxing & Permissions

Three distinct mechanisms, aimed at three different threats. Conflating them
would be a mistake.

### Guardrails — content validation

Guardrails validate *content*, not capability **[primary]**. Input guardrails
run on the user input; output guardrails on the agent's final response. Each
runs a function producing a `GuardrailFunctionOutput`; if it sets
`tripwire_triggered = true`, the SDK raises `InputGuardrailTripwireTriggered` or
`OutputGuardrailTripwireTriggered` and halts the run.

Two documented design decisions:

- **Input guardrails run only on the first agent; output guardrails only on the
  last.** Rationale: avoid duplicate checks, validate at workflow boundaries
  **[primary]**. Note the consequence — a mid-chain agent's input is not
  guardrailed, so guardrails are a perimeter, not a per-hop check.
- **Parallel by default, blocking optional.** Parallel gives best latency but
  "agents may consume tokens before guardrail completion." Blocking mode means
  "the agent never executes, preventing token consumption and tool execution"
  **[primary]**. The tradeoff is named explicitly rather than decided for you.

A common pattern is a cheap fast model as the guardrail checking a request
before an expensive model runs.

### Tool approval — the actual permission model

Human-in-the-loop is where capability gating lives **[primary]**:

- `needs_approval` on a tool: `True` to always require approval, or an async
  function deciding per call (so approval can depend on the *arguments* — e.g.
  writes outside a path, spend above a threshold).
- When triggered, the run pauses and surfaces `ToolApprovalItem` entries in
  `RunResult.interruptions`, carrying agent name, tool name, and arguments.
- The paused `RunState` serialises via `state.to_string()` / `to_json()` and
  reconstructs via `RunState.from_json(...)` / `from_string(...)`. The docs say
  "RunState is designed to be durable" — the pause can outlive the process
  **[primary]**.
- Resolve with `state.approve(interruption)` / `state.reject(interruption)`,
  then resume with `Runner.run(agent, state)`.
- Scope is run-wide: direct tool calls, handoffs, and nested `Agent.as_tool()`
  executions all route through it **[primary]**.

The durable-serialisable pause is the strongest single idea in this SDK for
crescent's purposes. It makes approval an *out-of-band, cross-process* protocol
rather than a blocking prompt on a terminal — the approver need not be the
process that started the run, or even alive at the same time.

### Sandbox agents — execution isolation (beta)

Sandbox agents give the model "a persistent workspace where it can search large
document sets, edit files, run commands, generate artifacts, and pick work back
up from saved sandbox state" **[primary]**. The stated motivation is bundling:
developers get this "without making you wire together file staging, filesystem
tools, shell access, sandbox lifecycle, snapshots, and provider-specific glue
yourself."

Backends: `UnixLocalSandboxClient` (local), Docker-backed (optional install),
and hosted providers. Bundled capabilities: filesystem edit/inspect including
patch application, shell execution, a skills system that lazy-loads tools from
local directories, cross-session memory, image inspection, compaction. Isolation
is by workspace boundary — a `Manifest` declares what gets staged in, and
permissions/capabilities are configured explicitly **[primary]**.

Note what this is *not*: there is no OS-level sandbox primitive (seccomp,
Landlock, Seatbelt) in the SDK itself. Isolation is delegated to the backend —
Docker, or a hosted provider. Compare Codex CLI, which needed native code
precisely to reach those primitives. The Agents SDK stays in Python and pushes
isolation out to a container boundary.

## Multi-Agent Support

Two mechanisms with genuinely different control-flow semantics, and the SDK
supports both rather than picking **[primary]**.

### Handoffs — control transfer

- A handoff is **exposed to the model as a tool.** An agent named "Refund Agent"
  becomes a tool named `transfer_to_refund_agent`. There is no separate routing
  protocol; delegation reuses the tool-calling channel the model already
  understands.
- `input_type` describes "the arguments for the handoff tool call itself" — the
  SDK validates the JSON before passing it to your callback, so a handoff can
  carry structured payload (e.g. a reason, an extracted entity).
- `on_handoff` callback fires at delegation time with the run context and the
  LLM-generated input — for logging, prefetching, side effects.
- **Input filters** control what history the receiving agent sees. They operate
  on `HandoffInputData` (prior history, pre-handoff items, current-turn items).
  `remove_all_tools` ships as a prebuilt filter. Default is: the receiving agent
  sees the entire prior conversation.
- `nest_handoff_history` compacts summarisable history into summary segments
  while preserving lossless messages.
- `RECOMMENDED_PROMPT_PREFIX` in `agents.extensions.handoff_prompt` — the SDK
  ships prompt text to teach models handoff mechanics **[primary]**.

That last point is a design admission worth noting: the mechanism does not work
reliably on prompt-free models. Part of the "framework" is a prompt.

### Agents as tools — subroutine call

`Agent.as_tool()` keeps the orchestrator in control: the specialist runs,
returns a value, and the manager continues **[primary]**. This is the
call-and-return shape that handoffs deliberately lack. Supports structured
Pydantic input, approval gates, custom output extraction, and streaming event
callbacks.

The docs frame the choice cleanly: handoffs when the specialist should *own* the
rest of the interaction (triage → specialist); agents-as-tools when a manager
should *consult* a specialist and retain control.

## Notable Design Decisions

1. **Handoff-as-tool-call.** Delegation reuses the tool channel rather than
   inventing a routing protocol. Zero new model-facing concepts; the model
   already knows how to call tools. Cost: the model must be prompted to
   understand what transfer means, hence `RECOMMENDED_PROMPT_PREFIX`.

2. **Handoff rebinds; as_tool nests.** Two multi-agent mechanisms because the
   control-flow shapes genuinely differ. Refusing to unify them is the decision.

3. **The function is the schema.** Signature + type hints + docstring generate
   the tool schema. No parallel registration table, so schema/handler drift is
   structurally impossible.

4. **Local context is explicitly not LLM context.** A typed dependency-injection
   object threaded through the run that the model never sees, stated in one
   unambiguous sentence. Most frameworks leave this implicit and end up leaking
   infrastructure handles into prompts or vice versa.

5. **Durable, serialisable interruptions.** `RunState.to_json()` /
   `from_json()` around a tool-approval pause makes approval a cross-process,
   cross-time protocol. The run is a value that can be stored and resumed.

6. **Guardrails as a perimeter, not a per-hop check** — first agent in, last
   agent out — with the duplicate-work rationale stated. Plus parallel-vs-
   blocking as a named latency/cost tradeoff rather than a hidden default.

7. **Sessions decouple "what is stored" from "what the model sees."**
   `session_input_callback` reshapes the model's view without affecting
   persistence, and the runner re-stores only genuinely new items.

8. **Encryption as a session wrapper**, not a per-backend feature.
   Cross-cutting concern composed over the interface.

9. **Orchestration is Python, not a DSL.** "Complex agent orchestration through
   Python rather than specialized abstractions" is pitched as a feature. No
   graph builder, no workflow language.

10. **Four mutually-exclusive multi-turn strategies, none defaulted.** Manual,
    Sessions, `conversation_id`, `previous_response_id`. The SDK exposes the
    choice rather than hiding it.

11. **`reset_tool_choice` by default.** A named mitigation for a specific
    empirical failure mode (models looping on `tool_choice="required"`).

12. **Provider-agnostic at the `Model` interface, but honest about parity.** The
    docs warn against mixing Responses and Chat Completions shapes in one
    workflow, and say third-party feature support depends on the provider. The
    abstraction is not claimed to be leak-free.

13. **Primitive count drifted.** Three headline primitives; ten documented
    concepts. Swarm had two and was unusable in production. The honest reading
    of the Swarm → SDK evolution is that *minimal primitives are a learnability
    property, not an architecture property* — the production surface grew
    regardless, and the SDK's response was to keep the *core loop* small while
    letting supporting systems accumulate around it. That is the actual lesson,
    and it is not the one the marketing states.

## Relevance to Crescent

Grounded against the current tree: `lib/ai` is a neutral type vocabulary
(`lib/ai/types.lua`) plus a dispatch facade (`lib/ai/init.lua`), per-provider
adapters, and one convenience loop (`lib/ai/tools.lua`, 79 lines);
`lib/taskgraph` is a demand-driven call tree with a single `ExecutorFn`,
pull-based `ctx:result()` forcing, and opt-in frontier/exec-graph tracking.

**Where crescent already agrees.** `ai_provider` as a plain table of five
functions is the same shape as `Model`/`ModelProvider` — a record, not a class,
resolved by name or passed directly. `types.lua` being deliberately "not
OpenAI-shaped, not Anthropic-shaped" is the same bet the SDK makes at its model
layer, and the SDK's honesty about parity leakage (Responses vs Chat
Completions) is a warning crescent's 32-entry `openai_compat.registry` should
take seriously: a neutral type that silently degrades per provider is worse than
one that reports what it cannot do.

**Where the SDK is ahead of `lib/ai/tools.lua`.** The current loop owns
everything and returns only the final `ai_response` — the transcript is
discarded, there are no hooks, no approval gate, no cancellation, no
resumability. Four SDK decisions map directly onto that gap:

- *Durable interruptions.* `RunState` serialisation around a tool-approval pause
  is the single most transferable idea here, and it lands on taskgraph
  particularly well: a paused run is already close to a graph node in `pending`
  with recorded arguments. Making the pause a value that survives the process
  would give crescent an approval model that a terminal-blocking prompt cannot.
- *Tool declaration and handler cannot drift.* `tools.lua` takes `opts.tools`
  and a *parallel* `opts.handlers` map, unlinked — a missing handler is
  discovered at dispatch and reported to the model as `unknown tool`. The SDK's
  function-is-the-schema approach makes this class of bug unrepresentable. Lua
  has no type hints or docstring parser, so the mechanism cannot be copied
  directly; the transferable part is *one declaration site, not two*.
  (Relatedly: `lib/taskgraph/executor/ai.lua` builds tool specs with
  `input_schema` while the compat converters read `parameters` — exactly the
  drift a single declaration site prevents.)
- *Local context vs LLM context.* Crescent's `ctx` in taskgraph is already
  local-context-shaped (spawn/result/log capabilities the model never sees).
  Naming that distinction explicitly, as the SDK does, would keep it from
  eroding as `lib/ai` grows.
- *Storage/view decoupling.* `session_input_callback` — reshape what the model
  sees without changing what is persisted — is a cleaner factoring than a single
  mutable `messages` array, and it is where compaction would eventually attach.

**Where crescent should probably diverge.** The SDK's handoff rebinds the loop's
current agent in place, which is a control-flow primitive taskgraph does not
have and arguably does not want: taskgraph's `spawn` + `result` is already the
call-and-return shape (`Agent.as_tool()`), and `executor/ai.lua`'s `tool_loop`
already turns every tool call into a real graph node with lineage — visibility
the SDK gets only via a separate tracing system. Adding a rebinding handoff
would introduce a second, stackless control-flow mode alongside the existing
one. That is a real branch point, not a settled call: the SDK carries both
mechanisms deliberately because the semantics differ, and whether crescent needs
the transfer semantics at all depends on whether "specialist owns the rest of
the interaction" is a shape the agent app must express.

Similarly, the SDK's guardrail perimeter (first agent in, last agent out) is a
weaker check than crescent could offer, since taskgraph's `opts.scaffolds`
already apply a hook to *every* task. The SDK's stated rationale for the
perimeter is duplicate-work avoidance — a cost argument, not a safety one.

**What the Swarm → SDK evolution says about the open TODO.** The registered
direction (`TODO.md`, "Beyond SOTA agent harness by deleting the concept of an
agent") is a minimalism bet, and Swarm is the closest available data point on
how such a bet ages: two primitives, widely admired, superseded within a year by
something with ten. The gaps that forced it were not conceptual — they were
tracing, guardrails, retries, streaming, and session management **[secondary]**.
Every one of those is infrastructure around the loop rather than a new
abstraction inside it. If crescent deletes the agent concept, that list is the
concrete set of things that still have to live somewhere; taskgraph already
supplies tracing (exec_graph), retries (`combinators.retry`), and lineage, which
is an argument that the substrate is the right place for them.

**Not surveyed, worth verifying before relying on it.** The `nest_handoff_history`
summarisation, the exact `RunState` serialisation format, and the
`tool_execution` concurrency semantics in `RunConfig` are all documentation-level
claims here; the Python source was not read.

## Sources

Primary:

- <https://github.com/openai/openai-agents-python> — repo README, verified live
  2026-08-02 via WebFetch and GitHub API (MIT, ~28.3k stars).
- <https://github.com/openai/swarm> — Swarm README, verified live 2026-08-02.
- <https://openai.github.io/openai-agents-python/> — design principles, core
  primitives, agent loop, Swarm relationship.
- <https://openai.github.io/openai-agents-python/agents/> — Agent configuration
  surface.
- <https://openai.github.io/openai-agents-python/running_agents/> — Runner, loop
  termination, `max_turns`, `RunConfig`, multi-turn strategies.
- <https://openai.github.io/openai-agents-python/tools/> — function tools, schema
  generation, hosted tools, agents-as-tools.
- <https://openai.github.io/openai-agents-python/handoffs/> — handoff-as-tool,
  input filters, `on_handoff`, recommended prompt prefix.
- <https://openai.github.io/openai-agents-python/guardrails/> — tripwires,
  first/last-agent rationale, parallel vs blocking.
- <https://openai.github.io/openai-agents-python/sessions/> — session protocol,
  backends, persistence semantics.
- <https://openai.github.io/openai-agents-python/context/> — local vs LLM
  context.
- <https://openai.github.io/openai-agents-python/human_in_the_loop/> —
  `needs_approval`, interruptions, `RunState` durability.
- <https://openai.github.io/openai-agents-python/multi_agent/> — LLM vs code
  orchestration.
- <https://openai.github.io/openai-agents-python/models/> — model layer,
  provider agnosticism, shape-mixing warning.
- <https://openai.github.io/openai-agents-python/sandbox_agents/> — sandbox
  agents, isolation model.

Secondary:

- <https://www.respan.ai/articles/openai-agents-sdk-vs-swarm> — Swarm → SDK
  migration framing; the "production checklist" characterisation of Swarm's
  gaps.
- <https://mem0.ai/blog/openai-agents-sdk-review> — third-party review.
- <https://www.botonomy.ai/blog/agentic-ai/open-ai-agents-sdk/> — architecture
  walkthrough.
- <https://lexogrine.com/blog/openai-swarm-multi-agent-framework-2026> — Swarm
  retrospective.
