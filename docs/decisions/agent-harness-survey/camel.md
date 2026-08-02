# CAMEL — Prior Art Survey

Survey date: 2026-08-02. Version observed: `camel-ai` 0.2.91a5 (from `pyproject.toml`
on `master`). Repo: <https://github.com/camel-ai/camel> (verified live; Apache-2.0;
~17.5k stars, 2280+ commits). Paper: *CAMEL: Communicative Agents for "Mind"
Exploration of Large Language Model Society*, NeurIPS 2023 (arXiv 2303.17760).

This document records the *decisions* CAMEL made and the reasoning visible in its
paper, docs, and source, for use in designing crescent's agent app and `lib/ai`
expansion. Where a claim could not be grounded in a fetched page it is marked as
such.

## Overview

CAMEL is the oldest of the surveyed multi-agent frameworks (March 2023) and the only
one that began as a **research artifact rather than a product**. Its original purpose
was not to build a useful agent; it was to *generate conversational data* between two
LLM agents in order to study "the behaviors and capabilities of a society of agents."
Task automation was a downstream consequence of the data-generation apparatus, not
the starting point.

That origin explains nearly every design decision in the codebase. The README frames
the current project as studying "the scaling laws of agents," with simulation of up to
1M agents as an explicit target, and names four design principles: **evolvability,
scalability, statefulness, and "code-as-prompt."** The three advertised use cases are
data generation, task automation, and world simulation — in that order, and data
generation is genuinely first-class (CoT, Self-Instruct, Source2Synth generators ship
in the package).

Dependency posture: the *core* dependency set is unusually restrained for this
category — `openai`, `pydantic`, `httpx`, `tiktoken`, `jsonschema`,
`docstring-parser`, `mcp`, `astor`, `pillow`, `psutil`, `pyyaml`, `websockets`,
`colorama`, `google-search-results`. Everything heavy (vector DBs, RAG, model
platforms, browser tooling, communication integrations) lives behind 19 optional
extras groups. Note `mcp` is *core*, and `google-search-results` is core (an odd
inclusion for a base install).

## Architecture

### The primitives

- **`BaseMessage`** — the universal currency. Every agent, society, and memory
  operation traffics in `BaseMessage`, converted to provider format at the edge.
- **`ChatAgent`** — the single agent implementation. Everything else (critic,
  task specifier, task planner, coordinator, summarizer, worker) is a `ChatAgent`
  with a different system message, or a thin subclass.
- **`RolePlaying`** — a *society*: a pairing of two `ChatAgent`s plus optional
  helper agents, driving a conversation.
- **`Workforce`** — a hierarchical, async task-routing structure whose leaves are
  workers (a `ChatAgent`, a `RolePlaying` session, or another `Workforce`).

The decision worth naming up front: **CAMEL has no "orchestrator" primitive in the
LangGraph sense — no user-authored graph, no state machine.** Control flow is either
(a) a fixed two-party alternation (`RolePlaying`), or (b) LLM-decided routing over an
async message channel (`Workforce`). There is no third mode where the developer draws
the edges. This is a deliberate consequence of the research framing: the point was to
observe what agents do when *they* decide, not to encode what the developer already
knows.

### `ChatAgent.step()`

`step()` takes one input message and runs a model call → tool call → model call loop
internally, returning a `ChatAgentResponse` with `msgs`, a `terminated` flag, and an
`info` dict (token usage, `ToolCallingRecord` list, structured-output results).

Notable decisions in the loop:

- **`max_iteration: Optional[int]`, defaulting to `None` = unbounded.** The docstring
  states `1` performs a single model call and `N > 1` allows up to N. The default is
  *no limit* on internal model calls per `step()`. Bounding is pushed outward, to the
  society's `chat_turn_limit`.
- **Internal vs external tools is an explicit split.** Tools in `_internal_tools` are
  executed by the agent; tools registered as `_external_tool_schemas` cause `step()`
  to *return a `ToolCallRequest` to the caller instead of executing*. This is CAMEL's
  answer to "the harness owns dangerous tools, not the agent" — the mechanism exists,
  but as an opt-in per-tool routing decision, not as a permission model.
- **`response_terminators`** — a pluggable list of terminator objects that can end
  iteration and populate `info['termination_reasons']`; a terminator signal overrides
  `max_iteration`.
- Context is fetched via `_get_context_with_summarization()`, respecting `token_limit`;
  failure to fit raises `ModelProcessingError` rather than silently dropping.

## Tool-Calling Protocol

The protocol is **OpenAI function-calling, verbatim**, with no framework-level
abstraction over it. `FunctionTool` wraps a Python callable and produces an
OpenAI-shaped schema via `get_openai_tool_schema()`.

Schema generation pipeline:

1. Read parameter type annotations (missing annotation → `Any`).
2. Parse the docstring with `docstring-parser` for parameter descriptions.
3. Build an intermediate Pydantic model.
4. Emit JSON Schema from it.
5. `sanitize_and_enforce_required()` adapts it to OpenAI strict mode — strips invalid
   `default` fields, rewrites optionals as `[type, "null"]`, recursively sets
   `"additionalProperties": false`.

Explicitly unsupported: `*args` and `**kwargs`. The docstring says so directly. A tool
is a fixed-arity typed function or it is not a tool.

Two decisions here are genuinely unusual and worth flagging:

- **LLM-synthesized schemas (`synthesize_schema=True`).** If a function lacks a usable
  docstring, `synthesize_openai_tool_schema()` asks a model to *write a PEP-257
  docstring for the function*, then derives the schema from the generated docstring,
  retrying up to `synthesize_schema_max_retries` before falling back. The tool contract
  the model sees can be a model-authored artifact.
- **LLM-synthesized *outputs* (`synthesize_output=True`).** The tool is not executed at
  all; an LLM agent reads the function body and arguments and *fabricates a plausible
  return value*. Intended for prototyping and simulation, but it is a first-class
  configuration flag on the same object that executes real tools.

`BaseToolkit` groups related tools, and **any toolkit can be exposed over MCP via
`run_mcp_server()`** — CAMEL treats MCP as an export surface for its own toolkits, not
only as a client-side integration. `mcp` being a core dependency reflects this.

**There is no human-confirmation mechanism in `FunctionTool`.** Confirmation, where it
exists, lives in the interpreters (below), not in the tool layer.

## Context/Memory Management

Memory is the most carefully factored subsystem in CAMEL, and the only one with a
clean layering story.

- **`MemoryRecord`** — the storage unit: a `BaseMessage`, a `role_at_backend`, a UUID,
  optional metadata. Serializable; converts to OpenAI message format.
- **`ContextRecord`** — a `MemoryRecord` plus a **relevance score**. Retrieval always
  returns scored records, never bare messages.
- **`MemoryBlock`** — abstract storage (composite pattern): write one, write many,
  clear.
- **`AgentMemory`** — a `MemoryBlock` that also retrieves and owns a context creator.

Two blocks ship: `ChatHistoryBlock` (recency-windowed KV storage, with a `keep_rate`
of 0.9 weighting older messages down) and `VectorDBBlock` (embeddings, Qdrant by
default). Three `AgentMemory` implementations compose them: `ChatHistoryMemory`,
`VectorDBMemory` (`retrieve_limit`, default 3), and `LongtermAgentMemory` which
queries *both* and merges.

**The load-bearing decision: `BaseContextCreator` / `ScoreBasedContextCreator`.**
Deciding what goes into the prompt is a *separate, swappable object* from deciding
what gets stored. The default strategy ranks `ContextRecord`s by score and fills the
window greedily until `token_limit` is hit. Token counting is real (`tiktoken` is a
core dep), not an estimate.

This is a cleaner separation than most peers achieve: *storage*, *retrieval+scoring*,
and *window packing* are three distinct interfaces, each independently replaceable.
`Mem0Storage` adds cloud persistence with cross-session sync as a drop-in backend.

The cost: relevance scoring means the prompt is not a faithful transcript. A message
can be silently dropped from context while remaining in memory. For a data-generation
tool that is fine; for a debuggable agent harness it is a real hazard.

## Sandboxing & Permissions

CAMEL has **no permission model.** It has an *interpreter selection* model, and the
distinction matters: safety is a property of which executor you constructed, not a
policy evaluated per action.

Five interpreters:

- **`InternalPythonInterpreter`** — executes in-process using an AST walker (`astor`
  is a core dep). In strict safe mode only *expressions* are permitted, not statements,
  and the code must evaluate to a string. This is the only interpreter with an
  intrinsic restriction mechanism.
- **`SubprocessInterpreter`** — process separation, multi-language (bash/python/shell).
- **`DockerInterpreter`** — container isolation; requires Docker on the host.
- **`JupyterKernelInterpreter`** — stateful kernel, variables persist across calls.
- **`E2BInterpreter`** — remote cloud sandbox.

A `require_confirm` parameter exists (seen on the Jupyter interpreter, defaulted to
`False` in the documented example) — so a human-in-the-loop gate is available but is
per-interpreter and off in the documented path. Docs do not describe whitelists,
capability grants, or per-tool policy.

The guidance is trust-based and stated as such: internal for trusted code, Docker for
untrusted, E2B for scale without local risk. Nothing prevents a `Workforce` coordinator
from routing an arbitrary LLM-generated task to a worker equipped with
`CodeExecutionToolkit`; in fact the default `new_worker_agent` template *includes*
`CodeExecutionToolkit`. Dynamically-created workers get code execution by default.

## Multi-Agent Support

This is CAMEL's core contribution and comes in two generations that embody opposite
philosophies. Reading them together is the most instructive thing in the project.

### Generation 1: `RolePlaying` + inception prompting (2023)

The paper's thesis: chat models succeed at complex tasks but depend on a human to keep
supplying the next instruction. Remove the human by **making the instructor an agent
too.**

The setup:

1. A **task specifier** agent (`TaskSpecifyAgent`, optional via `with_task_specify`)
   takes a vague `task_prompt` and rewrites it into a concrete, specific one. This
   happens once, before the conversation. An optional `TaskPlannerAgent`
   (`with_task_planner`) appends a plan to the prompt.
2. `SystemMessageGenerator` builds two system messages from `assistant_role_name`,
   `user_role_name`, and the specified task — **inception prompting**: the roles and
   the cooperation protocol are embedded in the system prompt, and nothing steers the
   conversation afterward.
3. `init_chat()` resets both agents and emits the opening message, by default:
   `"Now start to give me instructions one by one. Only reply with Instruction and
   Input."`
4. `step(assistant_msg)` runs one full exchange: `user_agent.step(assistant_msg)` →
   `assistant_agent.step(user_msg)`. The **AI User** issues instructions; the **AI
   Assistant** executes them. Note the inversion — the "user" is the planner, the
   "assistant" is the worker.

The inception prompts are the actual mechanism, and their content is a catalogue of
observed failure modes. From `camel/prompts/ai_society.py`:

- `"Never forget you are a {assistant_role} and I am a {user_role}. Never flip
  roles!"` — both prompts carry this; the user prompt adds `"You will always instruct
  me."`
- The assistant must answer `"Solution: <YOUR_SOLUTION>"` and close with
  `"Next request."` — a rigid response format.
- The user emits `<CAMEL_TASK_DONE>` and only that, and only once the task is
  genuinely solved.

The paper names four failure modes these prompts exist to suppress: **role flipping**
(agents swap instructor/executor), **assistant repeats instruction** (echoing rather
than solving), **flake replies** (non-substantive acknowledgement), and **infinite
loop of messages** (mutual politeness with no progress).

**The decision this represents: cooperation is enforced by prompt discipline, not by
program structure.** Every constraint that a graph framework would encode as an edge
or a state transition, CAMEL encodes as a sentence in a system prompt. That is
"code-as-prompt" taken literally. It is fragile by construction — and the paper is
honest that the failure modes are what motivated each rule.

Termination is triply redundant, which is itself telling: either agent's
`terminated` flag; the `CAMEL_TASK_DONE` string appearing in the user's message
(checked by the *caller*, not the framework); and an outer `chat_turn_limit` in the
caller's `while` loop (50 in the canonical docs example). The framework does not own
the loop — the user writes it.

`with_critic_in_the_loop` adds a third agent: when the agents are configured with
`n > 1` (multiple candidate completions), `critic.reduce_step(messages)` selects one.
The critic is a `CriticAgent`, or — if the role name is `"human"` — a `Human` agent
that prompts at the terminal. This is a one-ply tree search over candidate replies,
with the framework's only real human-in-the-loop hook hiding inside it.

### Generation 2: `Workforce` (later)

`Workforce` abandons fixed two-party alternation for **hierarchical async task
routing**, and it is where CAMEL converges with the rest of the field.

Structure: a `Workforce` is a `BaseNode` with `_children`. Three node types:
`SingleAgentWorker`, `RolePlayingWorker`, and a nested `Workforce` — so a role-playing
pair becomes *a worker inside a larger organization*, and organizations nest
recursively. `RolePlayingWorker` runs a bounded `RolePlaying` session
(`chat_turn_limit`, default 20; early exit on `CAMEL_TASK_DONE`) and then hands the
transcript to a **summarizer agent** which returns a structured `TaskResult` with
success/failure. Generation 1 is thereby demoted to an implementation detail of a
single node, and its unbounded prose output is forcibly reduced to a typed result.

Three coordinating agents:

- **Coordinator** — assigns tasks to workers or creates new ones. System message:
  *"You are coordinating a group of workers... Your job includes assigning tasks to
  existing worker, creating a new worker for a task, etc."*
- **Task planner** — decomposes tasks into subtasks (referencing child-node
  capabilities so subtasks are actually assignable) and composes results.
- **Dynamic workers** — instantiated at runtime from a `new_worker_agent` template,
  defaulting to `SearchToolkit` + `CodeExecutionToolkit` + `ThinkingToolkit`.

**`TaskChannel` is the substrate, and it is the most reusable idea in the project.**
Nodes do not call each other. A task is wrapped in a `Packet` carrying the task, its
assignee, and its status; the channel keeps `_task_by_assignee` and `_task_by_publisher`
deques, a `_task_dict` hash for O(1) lookup, and a `_task_by_status` index. Statuses:
`SENT` → `PROCESSING` → `RETURNED` → `ARCHIVED` (archived = frozen as a dependency for
other tasks). Coordination is an `asyncio.Condition`; workers call
`get_assigned_task_by_assignee(id)`, which blocks until a `SENT` task appears and
**atomically transitions it to `PROCESSING`**, explicitly to prevent two concurrent
callers claiming the same task.

This is a blackboard / work-queue architecture, not a call graph. It is what makes
"1M agents" a coherent goal rather than a slogan, and it is directly comparable to
crescent's `lib/taskgraph` frontier.

**Failure handling is the sharpest departure from Generation 1.** A `TaskAnalysisResult`
drives a graduated recovery ladder in `_apply_recovery_strategy()`:

1. **Retry** — repost the same task to the same worker.
2. **Replan** — rewrite the task content (`modified_task_content`), then retry.
3. **Reassign** — route to a different worker via the coordinator.
4. **Decompose** — break into subtasks; these are inserted at the *head* of the pending
   deque, and `_task_dependencies` is updated to preserve ordering. Decomposition can
   happen mid-execution.
5. **Create worker** — spawn a new specialized worker for a task type nobody handles.

Bounded by `MAX_TASK_RETRIES` (default 3), `FailureHandlingConfig` (which strategies
are enabled, retry caps), `halt_on_max_retries` (stop the whole workforce), and
`graceful_shutdown_timeout`. `stop_gracefully()` / `stop_immediately()` are explicit.
In-flight work is tracked in `_in_flight_tasks`; pending in a `deque`.

The same analysis pipeline also produces a **`quality_score` (0–100)**; a low score
triggers the recovery ladder even when the task nominally succeeded. Failure and
mediocrity are the same event.

`share_memory=True` syncs conversation history across agents via
`_sync_shared_memory()` so context survives handoffs.

### What the two generations say together

Generation 1 says: give two agents roles and a good prompt, and cooperation emerges.
Generation 2 says: cooperation needs a coordinator, a planner, a typed task channel,
retry budgets, decomposition, quality scoring, and a summarizer to force prose back
into structure. **The same project shipped the thesis and its rebuttal.** Every
mechanism in `Workforce` is a structural answer to a failure that inception prompting
tried to answer with a sentence. That trajectory is the single most useful thing in
this survey.

## Notable Design Decisions

1. **Research artifact first, harness second.** Data generation is a headline use case,
   not an afterthought — `synthesize_output` (fake tool results) and the CoT/Self-Instruct
   generators only make sense in that light. Some "features" are dataset machinery.
2. **The instructor is an agent, and it is called the *user*.** Naming the planner
   "user" and the executor "assistant" was the original insight: it lets an off-the-shelf
   chat model play the human's part with no fine-tuning.
3. **Failure modes are documented in the prompt text.** `ai_society.py` reads as a bug
   list. Valuable as an empirical record of what breaks in agent-to-agent conversation.
4. **Bounds live outside the framework.** `max_iteration` defaults to unbounded;
   `chat_turn_limit` is in the *caller's* `while` loop; `CAMEL_TASK_DONE` is checked by
   the caller. Generation 1 gives the developer the rope. `Workforce` reverses this and
   owns its own limits.
5. **Recursive homogeneity.** A `Workforce` is a worker. A `RolePlaying` pair is a
   worker. A `ChatAgent` is a worker. One interface at every level of the hierarchy.
6. **Task channel over direct calls.** Nodes never invoke nodes; they publish and claim
   packets with atomic status transitions. This is what makes concurrency and scale
   tractable.
7. **Quality score reuses the failure path.** A single analysis produces both
   "did it fail" and "was it good", feeding one recovery ladder.
8. **Memory factored into storage / scoring / window-packing.** Three independent
   interfaces where most frameworks have one blob.
9. **MCP as an export surface.** Toolkits *serve* MCP, not just consume it; `mcp` is a
   core dependency.
10. **LLM-generated tool contracts.** `synthesize_schema` lets a model write the
    docstring the schema is derived from. Convenient; means the tool contract is not
    necessarily human-authored.
11. **Safety is executor choice, not policy.** Five interpreters at different isolation
    levels, chosen at construction. No per-action permission check anywhere.

## Relevance to Crescent

Crescent's current state: `lib/ai/tools.lua` is a 79-line loop —
`ai.generate` → dispatch `tool_calls` against a `handlers` table → append `role="tool"`
messages → repeat, capped at `max_rounds` (default 10), returning
`nil, "max rounds exceeded"` on exhaustion. `lib/taskgraph` provides graph, frontier,
executor, and combinators.

Points of contact, stated as observations rather than recommendations:

- **`lib/ai/tools.lua` is already CAMEL's `ChatAgent.step()` minus the memory layer**,
  and crescent's version is *better bounded* — `max_rounds` defaults to 10 where
  CAMEL's `max_iteration` defaults to unbounded. The bound is the harness's business,
  and crescent already treats it that way.
- **`TaskChannel` and `lib/taskgraph/frontier.lua` occupy the same slot.** CAMEL's
  packet-with-status + atomic claim (`SENT`→`PROCESSING` under a condition variable)
  is a concrete design for the concurrency problem a frontier faces once workers are
  parallel. Worth reading against `frontier.lua` and `exec_graph.lua` before designing
  the agent app's execution model. Whether crescent wants LLM-decided routing over
  that substrate at all is a separate, open question.
- **The generation-1 → generation-2 arc is the transferable lesson.** If crescent
  builds anything resembling multi-agent collaboration, CAMEL is evidence that
  prompt-enforced protocol (role stability, response format, termination token) does
  not hold, and that the eventual fixes are structural: typed task results, a
  summarizer that forces prose to structure, retry budgets, explicit decomposition.
  Building the structure first skips a documented dead end.
- **Memory layering maps onto crescent conventions cleanly.** Storage / scoring /
  window-packing as three functions with `(nil, errmsg)` returns is a natural
  factoring, and it keeps the token-budget decision out of the agent loop. The
  caveat is real though: score-based dropping makes the prompt non-reproducible from
  the transcript, which conflicts with debuggability.
- **Sandboxing is the clearest place CAMEL offers nothing.** Trust-by-executor-choice
  is incompatible with crescent's caps-first rule. Under caps-first, an agent's ability
  to execute code is an injected capability, and the interesting design question — which
  CAMEL never asks — is what a *capability-scoped tool handler* looks like, i.e. tools
  that receive their caps from the harness rather than reaching for globals. CAMEL's
  internal/external tool split (`_external_tool_schemas` returning a `ToolCallRequest`
  to the caller rather than executing) is the one mechanism here worth stealing: it puts
  the harness, not the agent, in the execution path for designated tools.
- **`synthesize_output` and `synthesize_schema` are anti-patterns for crescent.** Both
  substitute a model's guess for a real contract or a real result. They collide directly
  with "no compromises" and with typed tool signatures. Noted so they are not
  accidentally reinvented as conveniences.
- **Dependency contrast is milder than with CrewAI**: CAMEL's core install is
  comparatively lean and pushes weight into 19 extras. The pattern — a small core with
  capability groups opted into explicitly — is closer to crescent's tiering instinct
  than most peers in this survey.

## Sources

- <https://github.com/camel-ai/camel> — README (stars, license, design principles, module list).
- <https://arxiv.org/abs/2303.17760> — paper abstract (role-playing, inception prompting).
- <https://arxiv.org/pdf/2303.17760v2> — paper PDF (task specifier / AI user / AI assistant, four failure modes, termination, dataset generation).
- <https://proceedings.neurips.cc/paper_files/paper/2023/hash/a3621ee907def47c1b952ade25c67698-Abstract-Conference.html> — NeurIPS 2023 record (fetch of the PDF from this host timed out; content obtained via arXiv).
- <https://raw.githubusercontent.com/camel-ai/camel/master/camel/societies/role_playing.py> — `RolePlaying` constructor, `init_chat`, `step`, critic, termination.
- <https://raw.githubusercontent.com/camel-ai/camel/master/camel/prompts/ai_society.py> — inception prompt text (`Never flip roles!`, `Solution:`/`Next request.`, `<CAMEL_TASK_DONE>`).
- <https://raw.githubusercontent.com/camel-ai/camel/master/camel/societies/workforce/workforce.py> — coordinator/planner, node types, recovery ladder, retry limits, shared memory, quality score.
- <https://raw.githubusercontent.com/camel-ai/camel/master/camel/societies/workforce/task_channel.py> — `Packet`, statuses, async claim semantics.
- <https://raw.githubusercontent.com/camel-ai/camel/master/camel/societies/workforce/role_playing_worker.py> — `chat_turn_limit`, summarizer, `TaskResult`.
- <https://raw.githubusercontent.com/camel-ai/camel/master/camel/toolkits/function_tool.py> — schema generation, sanitization, `synthesize_schema`, `synthesize_output`.
- <https://raw.githubusercontent.com/camel-ai/camel/master/camel/agents/chat_agent.py> — `step()` loop, `max_iteration`, internal/external tools, terminators.
- <https://raw.githubusercontent.com/camel-ai/camel/master/pyproject.toml> — version, license, core deps, extras.
- <https://docs.camel-ai.org/key_modules/memory> — `MemoryRecord`/`ContextRecord`/`MemoryBlock`/`AgentMemory`, context creators.
- <https://docs.camel-ai.org/key_modules/tools> — `FunctionTool`, `BaseToolkit`, MCP server export.
- <https://docs.camel-ai.org/key_modules/interpreters> — five interpreters, `require_confirm`, trust guidance.
- <https://docs.camel-ai.org/key_modules/agents> — `ChatAgent`, structured output, other agent types.
- <https://docs.camel-ai.org/key_modules/societies> — canonical `chat_turn_limit` loop, `CAMEL_TASK_DONE` check, task specify.

### Grounding caveats

- The PDF summarizer described critic-in-the-loop as involving human reviewers. The
  source (`role_playing.py`) shows the critic is a `CriticAgent` by default, with a
  `Human` agent used only when the critic role name is `"human"`. The source reading is
  authoritative here.
- `require_confirm` was observed only in a `JupyterKernelInterpreter` doc example. Its
  availability on other interpreters was not verified.
- Star count and commit count are as reported by the GitHub page on the survey date.
