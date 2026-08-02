# Semantic Kernel — prior-art survey

Survey of `github.com/microsoft/semantic-kernel` as prior art for an AI agentic
harness. Repo existence verified by fetch (2026-08-02). Focus is on the
decisions the project made and the reasoning it recorded, not a feature list.

Semantic Kernel (SK) is unusually good prior art for one specific reason: it
keeps its architecture decision records **in the repo** at `docs/decisions/`
(MADR format, ADR 0001 establishes the practice), 77+ of them. Most of the
findings below are sourced from those ADRs rather than from marketing docs, so
the rejected options and drivers are visible, not just the outcomes.

## Overview

SK is Microsoft's "model-agnostic SDK … to build, orchestrate, and deploy AI
agents", shipped in three parallel language implementations: .NET 10+, Python
3.10+, Java 17+. Its enterprise framing (reliability, observability,
OpenTelemetry conventions, DI integration) shapes nearly every decision.

**Status caveat, important for reading anything about SK:** the project has
transitioned to **Microsoft Agent Framework (MAF)**, now at 1.0 with stable
APIs and long-term support. SK itself is in maintenance/consolidation.
Several headline SK concepts are already deprecated and removed (planners,
`AgentGroupChat`, the Math/Wait plugins, `Microsoft.SemanticKernel.Markdown`).
This makes SK valuable as a record of what a large team tried and *retracted* —
arguably more useful for crescent than the surviving surface.

## Architecture

**The Kernel.** Described in the .NET API docs as "provides state for use
throughout a Semantic Kernel workload"; an instance "is passed through to every
function invocation and service call throughout the system". Concretely the
`Kernel` class holds:

- `Services` — an `IServiceProvider`
- `Plugins` — a `KernelPluginCollection`
- `FunctionInvocationFilters`, `PromptRenderFilters`, `AutoFunctionInvocationFilters`
- `Data` — an ambient key/value dictionary
- `Culture`, `LoggerFactory`, `ServiceSelector`
- `Clone()` — cheap copy so a scope can mutate plugins/filters without
  affecting the parent

So in practice the Kernel *is* a DI container plus a plugin registry plus a
middleware pipeline, threaded through everything as an ambient context object.

**The Kernel-as-container decision was explicitly rejected, then reversed.**
ADR 0012 (`0012-kernel-service-registration.md`) considered exactly this
question — plugins needing dependencies (e.g. `TextMemoryPlugin` needing
`ISemanticTextMemory`) — and weighed: (1) manual resolution by the caller,
(2) a custom lightweight kernel service provider, (3) taking a hard dependency
on `Microsoft.Extensions.DependencyInjection`. It chose (1): *"Plugin
dependencies should be resolved before passing Plugin instance to the Kernel"*,
on the principle that the kernel should be "a unit of single responsibility"
rather than a service container. The shipping `Kernel` has `Services`,
`GetRequiredService<T>()`, `GetAllServices<T>()` and a constructor taking an
`IServiceProvider`. The stated principle lost to ecosystem pull. This is the
clearest recorded instance in the repo of an architectural boundary eroding
under pressure from the host platform's conventions.

**Control flow: no separate planner.** SK's original architecture had
*planners* — prompt-driven components that asked the model to emit a plan
(Stepwise = ReAct-ish loop, Handlebars = emit a whole templated program) which
SK then executed. All of them are deprecated and removed from Python, .NET and
Java. The stated reason: native function calling arrived in the models, "other
AI models like Gemini, Claude, and Mistral have since adopted function calling
as a core capability, making it a cross-model supported feature", and function
calling is "both more powerful and easier to use for most scenarios".

The replacement control flow is the plain **automatic function-calling loop**,
which the docs spell out as: build JSON schemas for each function → send
history + schemas → parse response → if a call, invoke and append the result →
repeat until the model stops or asks for help. SK's contribution is automating
that loop, not adding a layer above it. Everything (including agents) bottoms
out here.

**Processes.** ADR 0054 adds a separate `Processes` framework for modelling
long-running business workflows as structured graphs — deliberately *not* the
agent loop. SK's position is that deterministic multi-step business flow and
model-driven agentic flow are different mechanisms, not one generalized
"planner".

## Tool-Calling Protocol

**Plugins are the unit; functions are the callable.** A plugin is a named group
of functions. The docs are explicit that this is a departure: "Not all AI SDKs
have an analogous concept to plugins (most just have functions or tools)." The
justification is enterprise-shaped — a plugin "encapsulates a set of
functionality that mirrors how enterprise developers already develop services
and APIs", and plugins "play nicely with dependency injection": the plugin's
constructor takes the DB connection, HTTP client, etc.

**Both native and prompt functions are `KernelFunction`.** A function created
from a C#/Python method and a function created from a prompt template are the
same type, invoked the same way, filtered the same way, and advertised to the
model the same way. This uniformity is the core abstraction: a prompt is a
callable, a callable is a prompt-visible tool. Prompt functions can be authored
in Handlebars, Liquid, YAML, Prompty, or a prompt directory (one function per
subdirectory).

**Four import paths, one internal shape:** native code, OpenAPI specification,
MCP server, gRPC. The docs' guidance: start with native, move to OpenAPI when
sharing across language teams, and note that you can *expose a Kernel as an MCP
server* so other apps consume your plugins as a service. So SK treats MCP as
both an import and an export format (ADR 0069).

**Schemas come from language-level metadata.** `[KernelFunction]` +
`[Description]` attributes in C#; docstrings + `Annotated[...]` in Python. No
separate schema file. There is an explicit recommendation to use **snake_case
even in C# and Java** because "most LLMs have been trained with Python for
function calling" — a case of the protocol layer leaking naming conventions
back into host-language style.

**Fully-qualified names and hallucination (ADR 0063).** SK names tools
`Plugin-function` with a hyphen separator. Models hallucinate the separator —
substituting `_` or `.` — and `.` violates the provider's allowed-character
pattern, so the *error* SK returns is itself rejected by the API, breaking
auto-recovery. Options weighed: drop the plugin prefix (collision risk), make
the separator configurable, concatenate with no separator, write a tolerant FQN
parser that tries several separators. Decision: start with the two options that
require no public API change — put the function name into the error message
plus a system instruction ("If a tool call failed, correct yourself"), and
**strip disallowed characters from error messages before returning them to the
model**. Deeper fixes were deferred pending measurement. Worth reading as a
warning: the tool namespace separator is a protocol-design decision with a
measurable failure rate.

**Tool-count guidance is a first-class concern.** The docs quote OpenAI's
"no more than 20 tools, ideally no more than 10", and dedicate a section to the
tradeoff between many single-responsibility functions (reusable, but each call
costs a round-trip and tokens both ways) and few multi-responsibility functions
(cheaper, but complex parameters the model mismatches). They also recommend
returning **return-type schemas** to the model, and **function transforms** —
wrapping a function to rename/flatten parameters or to inject host-side context
(auth, current user) that the model must not see or supply.

**Local state / state-id passing.** For large or confidential payloads, the
guidance is that functions accept and return a *state id* rather than the data
itself, so documents never enter the context window. Privacy and token cost
addressed by one mechanism.

## Context/Memory Management

**Chat history is the primary state; reducers manage it.** Since 1.35.0 SK
ships `ChatHistoryTruncationReducer` (drop old messages) and
`ChatHistorySummarizationReducer` (summarize dropped messages and re-insert the
summary as one message). Both **always preserve system messages**. An
`auto_reduce` flag applies reduction on message add, keeping history under a
configured limit without caller involvement. Reducers were retrofitted into the
agent selection/termination strategies too.

**AgentThread abstracts *where* conversation state lives.** ADR-level decision:
some backends (Azure AI Agent service, OpenAI Assistants) hold the thread
server-side and you hold an id; others require the full history to be resent
each turn and the state lives in your process. `AgentThread` unifies these.
Notably, stateful agents **fail fast** with an exception on a mismatched thread
type rather than degrading — `AzureAIAgent` requires `AzureAIAgentThread`.

**Memory generalized into `AIContextBehavior` (ADR 0072).** The problem framed:
memory must work across in-process vs remote and stateful vs stateless agents,
across conversation scopes, without leaking information between users. The
naming debate is recorded — `ConversationStateExtension` (too verbose),
`MemoryComponent` (too narrow), `AIContextBehavior` (chosen, deliberately more
general than "memory"). A behavior can inspect messages, contribute context per
invocation, **and register plugins**, and has `OnSuspend`/`OnResume` lifecycle
hooks for persistence. They are attached to an `AgentThread` via an
`AIContextBehaviorManager`. The generalization matters: "memory" turned out to
be a special case of "something that observes the conversation and injects
context and tools per turn".

**Retrieval is a plugin, not a privileged subsystem.** RAG in SK (ADR 0034,
0058 vector search, 0059 text search, 0067 hybrid search) is exposed as data-
retrieval functions the model calls. The docs distinguish retrieval functions
(optimize with caching, cheaper intermediate models) from task-automation
functions (add human-in-the-loop approval) — same mechanism, different
operational treatment.

**RAG over the tool list itself (ADR 0072-context-based-function-selection).**
With many functions the model picks badly. Options weighed: caller-side
vectorize-and-search, a function-invocation filter doing the same, an
`IChatClient` decorator that filters by message context, a new
"function advertisement filter" type, and a callback on
`FunctionChoiceBehavior`. Decision: implement it for agents as an
`AIContextBehavior` performing retrieval-augmented generation *over functions*,
with a ChatClient decorator later for non-agent paths. The tool list becomes a
retrieval result computed per turn rather than a static registration.

## Sandboxing & Permissions

SK has **no isolation or sandboxing mechanism**. Functions are host-language
methods running in-process with full ambient authority; plugins are trusted
code the developer registered. Nothing in the surveyed documentation describes
process isolation, capability restriction, or a permission grant model for
tools.

What SK has instead is **Filters** (ADR 0033, replacing the earlier kernel
hooks/events of ADRs 0005 and 0018 — the `FunctionInvoking`/`FunctionInvoked`
events are now marked Obsolete). Filters are middleware: each receives a
`context` and a `next` delegate, and **not calling `next` means the operation
does not happen**. Three types:

- **Function invocation filter** — every `KernelFunction` call. Sees the
  function and its arguments; can block, override the result before (caching)
  or after (responsible-AI post-processing) execution, handle exceptions, and
  retry (the canonical sample retries against a different model).
- **Prompt render filter** — before the prompt goes to the model. View/modify
  the rendered prompt (PII redaction, RAG injection) or prevent submission
  entirely by supplying a result (semantic caching).
- **Auto function invocation filter** — inside the auto-calling loop only, with
  extra context: the chat history, the full list of functions about to run, and
  iteration counters. Can set `context.Terminate = true` to **end the agentic
  loop early** — e.g. once the answer is obtained from the second of three
  planned calls.

The docs' security framing is: filters "enhance security by providing control
and visibility over how and when functions run … so that you feel confident
your solution is enterprise ready", with the worked example being *permission
validation before an approval flow begins*. So the permission model is
"application-supplied middleware that can veto", not a declared policy.

Two details worth stealing or avoiding: filter **ordering** is guaranteed in
Python (registration order, onion-nested) but **explicitly not guaranteed** in
.NET when registered via DI — you must add them directly to the Kernel property
if order matters. And filters attach to the `Kernel`, so calling
`IChatCompletionService` directly **silently bypasses every filter** unless you
pass the Kernel in. A security boundary you can accidentally step around is a
weak boundary.

## Multi-Agent Support

**Agent abstraction.** An abstract `Agent` base with concrete types:
`ChatCompletionAgent` (in-process loop over SK's own chat completion),
`OpenAIAssistantAgent`, `AzureAIAgent`, `OpenAIResponsesAgent`,
`CopilotStudioAgent`. Stated goals: the framework is the foundation for agent
functionality; **agents of different types collaborate in one conversation**,
with human input integrated; and one agent handles multiple concurrent
conversations. Agent messages reuse the same `ChatMessageContent`/`KernelContent`
types as plain chat completion — a deliberate continuity decision so migrating
from chat to agents doesn't mean re-plumbing content types.

**Orchestration is actor-based (ADR 0071).** Agents are wrapped as actors that
send and receive messages within a shared runtime managing state and lifecycle.
The drivers cite AutoGen's runtime abstraction as proven prior art to build on.
Architectural principles recorded: orchestrations are **runtime-agnostic**;
runtime lifecycle is managed by the *application*, not the framework;
orchestrations are **lazy templates** — defining one doesn't execute anything,
invocation does; each invocation gets a unique id so concurrent invocations
don't collide; and input/output transforms let orchestrations carry non-chat
structured data between agents and external systems.

Five prebuilt patterns:

| Pattern | Shape |
| --- | --- |
| Concurrent | broadcast to N agents, collect results |
| Sequential | pipeline; each agent builds on the previous |
| Handoff | agents transfer control to whichever has the right expertise |
| GroupChat | conversation with a pluggable **manager** strategy choosing who speaks |
| Magentic | MagenticOne pattern from AutoGen — a dedicated manager plans and picks the next agent from evolving context/progress |

Some patterns support **human-in-the-loop as a participant** in the
orchestration.

**`AgentGroupChat` was retired** in favour of `GroupChatOrchestration` (with a
migration guide). The recorded difference is that the new pattern makes the
turn-taking *manager* a pluggable strategy rather than baked-in.

**Declarative agents (ADR 0070).** Agents can be defined in YAML and
instantiated via `AgentRegistry.create_from_yaml(...)`; custom agent classes
opt in with a `@register_agent_type("name")` decorator and a
`DeclarativeSpecMixin` supplying `from_yaml`/`from_dict`/`resolve_placeholders`
(the last being the hook for environment/runtime placeholder substitution).
Still experimental at time of survey.

Orchestration as a whole is still labelled **experimental** and subject to
breaking change.

## Notable Design Decisions

1. **Deleting the planner.** SK's original differentiator was planners; it
   removed them entirely once model-native function calling became
   cross-vendor. The bet: the loop belongs to the model, and the framework's
   job is to run the loop faithfully and get out of the way. Everything else in
   SK is now built on that one primitive.
2. **Prompt functions and native functions are the same type.** A prompt is a
   callable with a signature. This lets templating, filters, telemetry, and
   tool advertisement all be written once.
3. **Plugins as a grouping tier above functions,** justified by DI and by
   matching how enterprises already package services — but purchased at the
   cost of a two-part name that models hallucinate (ADR 0063).
4. **Middleware (filters), not policy, as the control point.** One `next`-based
   pipeline serves logging, caching, PII redaction, retry, content safety,
   approval gating, and early loop termination.
5. **"Memory" generalized to `AIContextBehavior`** — an observer that injects
   context *and tools* per invocation, with suspend/resume. Memory, RAG, and
   dynamic tool selection all became instances of the same abstraction.
6. **Tools as a retrieval problem.** Advertising a per-turn retrieved subset of
   functions rather than the full registry.
7. **State-id passing** to keep large/sensitive data out of the context window.
8. **Function transforms** to inject host-side context (identity, auth) that
   the model must never supply.
9. **Fail fast on backend/thread mismatch** rather than silently degrading.
10. **Orchestrations as lazy, runtime-agnostic, app-lifecycle-owned templates.**
11. **Three language implementations kept at parity**, with ADRs frequently
    recording per-language divergence (0002, 0010, 0046-java-repository-separation,
    0052) — a large recurring tax, visible in the ADR log.
12. **In-repo MADR ADRs from ADR 0001.** The reason this survey has drivers and
    rejected options instead of guesses.

## Relevance to Crescent

Crescent's current state (read at survey time): `lib/ai/init.lua` (120 lines) is
a lazy provider registry with `generate`/`stream`/`embed`/`embed_many`/
`generate_image` and a `register` hook; `lib/ai/tools.lua` (79 lines) is the
tool loop — copy messages, call `ai.generate`, dispatch `tc.name` through an
`opts.handlers` table, `pcall` each handler, append `role = "tool"` messages,
bail at `max_rounds`.

Points of contact, stated as observations rather than recommendations:

- **The loop crescent already has is the loop SK converged on** after deleting
  planners. `tools.lua` is structurally the "automatic planning loop" the SK
  docs enumerate. That is corroboration, not a gap.
- **Tool namespacing is an open decision.** `tools.lua` dispatches on a flat
  `tc.name`. SK's ADR 0063 is direct evidence that introducing a
  `plugin<sep>function` scheme carries a measured hallucination cost, and that
  the separator character interacts with provider-side name validation —
  including making error strings unreturnable. If crescent adds grouping,
  that ADR is the thing to read first.
- **Filters vs. crescent's caps-first rule.** SK's filters are runtime
  interception on a shared mutable `Kernel`; crescent's convention is injected
  capabilities. These solve overlapping problems (what may a tool do) by
  opposite means: SK vetoes at call time, caps withhold the ability. SK's own
  weakness is instructive — filters bind to the `Kernel` object, so a caller
  who reaches for the chat service directly bypasses them. A cap that was never
  injected cannot be bypassed. This is a real design divergence, not a gap to
  close.
- **Error text is part of the protocol.** `tools.lua` currently returns
  `'{"error": "unknown tool: ' .. tc.name .. '"}'`. SK's finding is that the
  content of that string materially determines whether the model recovers, and
  that unsanitized names inside it can make the *next* request invalid.
- **Context management is absent from crescent's loop.** `tools.lua` grows
  `messages` without bound until `max_rounds`. SK's reducers (truncate vs
  summarize, always preserve system messages, opt-in auto-apply) are a small,
  copyable design.
- **`AIContextBehavior` is the interesting shape for `lib/taskgraph` contact.**
  A per-turn hook that can observe messages, inject context, inject tools, and
  suspend/resume is close to what a persistent orchestrated agent needs, and it
  is one abstraction rather than three.
- **The Kernel is the anti-pattern to name explicitly.** An ambient object
  carrying services, plugins, filters, a logger, a culture, and a free-form
  `Data` dictionary, passed to every call, is maximal coupling — and ADR 0012
  shows the team *decided against* it and shipped it anyway. Crescent's
  low-coupling rule and its no-ambient-globals typechecking posture point the
  other way; SK is the documented cost of not holding that line.
- **Multi-agent patterns are enumerable and small.** Concurrent, sequential,
  handoff, group-chat-with-manager, planner-manager. If `lib/taskgraph` ends up
  expressing agent orchestration, that list is a reasonable coverage checklist,
  and the "lazy template, app owns the runtime lifecycle" principle fits a
  library that must not own a process.
- **Read SK as a retraction log.** Planners, kernel hook events, `AgentGroupChat`,
  and the Kernel's single-responsibility principle were all published and then
  walked back. For a project whose hard constraint is "no compromises, no
  laziness," the removals carry more signal than the features.

## Sources

- [microsoft/semantic-kernel (README)](https://github.com/microsoft/semantic-kernel)
- [semantic-kernel/docs/decisions (ADR index)](https://github.com/microsoft/semantic-kernel/tree/main/docs/decisions)
- [ADR 0012 — kernel service registration](https://raw.githubusercontent.com/microsoft/semantic-kernel/main/docs/decisions/0012-kernel-service-registration.md)
- [ADR 0063 — function calling reliability](https://raw.githubusercontent.com/microsoft/semantic-kernel/main/docs/decisions/0063-function-calling-reliability.md)
- [ADR 0071 — multi-agent orchestration](https://raw.githubusercontent.com/microsoft/semantic-kernel/main/docs/decisions/0071-multi-agent-orchestration.md)
- [ADR 0072 — agents with memory](https://raw.githubusercontent.com/microsoft/semantic-kernel/main/docs/decisions/0072-agents-with-memory.md)
- [ADR 0072 — context-based function selection](https://raw.githubusercontent.com/microsoft/semantic-kernel/main/docs/decisions/0072-context-based-function-selection.md)
- [What are Planners in Semantic Kernel](https://learn.microsoft.com/en-us/semantic-kernel/concepts/planning)
- [Plugins in Semantic Kernel](https://learn.microsoft.com/en-us/semantic-kernel/concepts/plugins/)
- [Semantic Kernel Filters](https://learn.microsoft.com/en-us/semantic-kernel/concepts/enterprise-readiness/filters)
- [Semantic Kernel Agent Architecture](https://learn.microsoft.com/en-us/semantic-kernel/frameworks/agent/agent-architecture)
- [Kernel Class (.NET API reference)](https://learn.microsoft.com/en-us/dotnet/api/microsoft.semantickernel.kernel?view=semantic-kernel-dotnet)
- [Semantic Kernel: Package previews, Graduations & Deprecations](https://devblogs.microsoft.com/semantic-kernel/semantic-kernel-package-previews-graduations-deprecations/)
- [Semantic Kernel: Multi-agent Orchestration](https://devblogs.microsoft.com/agent-framework/semantic-kernel-multi-agent-orchestration/)
- [Managing Chat History for LLMs](https://devblogs.microsoft.com/semantic-kernel/managing-chat-history-for-large-language-models-llms/)
- [Creating and managing a chat history object](https://learn.microsoft.com/en-us/semantic-kernel/concepts/ai-services/chat-completion/chat-history)
