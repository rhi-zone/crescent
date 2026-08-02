# CrewAI — Prior Art Survey

Survey date: 2026-08-02. Version observed: `crewai` 1.15.x (`crewai-core==1.15.10`).
Repo: <https://github.com/crewAIInc/crewAI> (verified live; MIT; ~56.5k stars, ~8k forks).

This document records the *decisions* CrewAI made and the reasoning visible in its
docs and source, for use in designing crescent's agent app and `lib/ai` expansion.
Where a claim could not be grounded in a fetched page it is marked as such.

## Overview

CrewAI is a Python framework (>=3.10, <3.14) for "orchestrating role-playing,
autonomous AI agents." Its stated positioning has two load-bearing claims:

1. **Standalone, not built on LangChain.** CrewAI was rewritten to be independent
   of LangChain. This is the framework's most-repeated marketing line and it shows
   in the codebase shape: its own executor, its own tool base class, its own memory
   layer. Early versions did depend on LangChain; the break was deliberate.
2. **"Experiment to production without changing frameworks."** The Crews/Flows
   duality (below) exists to serve this: the prototype-friendly abstraction and the
   production-grade abstraction ship in the same package and compose.

The repo is now a monorepo (`lib/crewai/`, `crewai-core`, `crewai-cli` as separate
distributions pinned to the same version). Notably, **`litellm` is no longer a core
dependency** — it is an optional extra (`litellm>=1.84.0,<2`), while `openai>=2.30.0`
is a hard dependency. Core deps also include `pydantic`, `chromadb~=1.1.0`,
`lancedb`, and three `opentelemetry-*` packages. Provider breadth is opt-in extras
(`anthropic`, `bedrock`, `google-genai`, `azure-ai-inference`, `watson`, `aws`,
`voyageai`, `mem0`, `qdrant`, `docling`, ...).

The dependency posture is the polar opposite of crescent's: a "zero-config"
experience purchased with a very large transitive dependency graph, including a
vector DB and an OTel exporter *by default*.

## Architecture

### The primitives

- **Agent** — `role`, `goal`, `backstory` (three natural-language strings that are
  templated directly into the system prompt), plus `llm`, `tools`, and behavioral
  knobs.
- **Task** — `description`, `expected_output` (also natural language), an assigned
  `agent`, an explicit `context` list of upstream tasks, and output/validation
  config.
- **Crew** — a set of agents + ordered tasks + a `process`.
- **Flow** — an event-driven, decorator-defined state machine that can invoke
  crews, agents, or plain Python as steps.

The decision worth noting: **the unit of work is a Task with a natural-language
`expected_output`, not a typed function signature.** The contract between steps is
prose. Structure is bolted on afterward via `output_pydantic` / `output_json` /
guardrails, not designed in.

### Crews vs Flows — the duality

This is CrewAI's most distinctive architectural decision, and it is best read as an
admission rather than a feature.

**Crews** are autonomous. Agents collaborate toward a goal; in hierarchical mode the
execution path is not predetermined at all — a manager LLM decides who does what.
Good for open-ended problems, inherently non-reproducible and hard to audit.

**Flows** are deterministic and event-driven. Defined with Python decorators:

- `@start()` — entry point(s); multiple allowed.
- `@listen(method)` — fires when the named method completes, receiving its output.
- `@router()` — returns a route label; downstream methods are selected by label.
- `or_(...)` / `and_(...)` — join semantics: fire on *any* vs on *all*.

State has two modes: **unstructured** (`self.state` as a dict, no schema) and
**structured** (a Pydantic `BaseModel`, typed and validated). Both get an
auto-injected UUID `state.id`. `@persist` writes state to SQLite, enabling
`kickoff(inputs={"id": uuid})` to resume and `restore_from_state_id` to fork from a
prior state. Flows also expose `self.remember()` / `self.recall()` /
`self.extract_memories()`, and `@human_feedback` to pause for approval.

**Why the duality exists.** The framework started as autonomous role-playing crews.
That model demos beautifully and is unshippable: you cannot audit, replay, or
guarantee a manager LLM's delegation choices. Rather than constrain crews, CrewAI
added a second, *orthogonal* control-flow layer where the graph is written by a
human in Python and the LLM autonomy is confined to individual nodes. Flows are
described in the docs as "the enterprise architecture for production deployments."

So: **the deterministic layer was added on top of the autonomous one, not the other
way round.** Crews remained the marketing surface; Flows became the production
answer. A designer starting today can read this as evidence that the deterministic
graph is the primitive and agent-autonomy is the special case — the reverse of
CrewAI's build order.

### Process types (within a Crew)

- **Sequential** (default) — tasks run in declared order; each task's output is
  automatically fed as context to the next.
- **Hierarchical** — requires `manager_llm` or `manager_agent`. Tasks are *not*
  pre-assigned; the manager allocates work by agent capability, reviews outputs, and
  assesses completion. Planning, delegation, and validation all live in the manager.

Only these two are documented. Crew-level `planning=True` inserts an `AgentPlanner`
that drafts a strategy before each iteration and appends it into task descriptions.

### Execution loop

`CrewAgentExecutor` (`lib/crewai/src/crewai/agents/crew_agent_executor.py`) runs
**dual-mode**:

- `_invoke_loop_native_tools()` — preferred when the LLM supports native function
  calling and tools exist. Structured tool definitions go over the wire.
- `_invoke_loop_react()` — fallback. Tool definitions are embedded in the prompt and
  the model emits `Action` / `Action Input` text which is parsed out.

Loop controls: `self.iterations` increments in a `finally` block;
`has_reached_max_iterations(iterations, max_iter)` gates, and
`handle_max_iterations_exceeded()` terminates with a formatted response rather than
throwing. `OutputParserError` is caught separately in ReAct mode and handled
(`handle_output_parser_exception()`) *without* re-raising — a bad parse becomes a
corrective message in the transcript, and only logs after `log_error_after`
iterations. Context-length errors are detected by `is_context_length_exceeded(e)` and
routed to `handle_context_length()`.

The decision here: **never let a recoverable model error terminate the run.** Parse
failures, overflow, and iteration exhaustion each degrade into a message or a
formatted final answer.

## Tool-Calling Protocol

Two authoring paths:

- Subclass `BaseTool`: set `name`, `description`, and `args_schema` (a Pydantic
  `BaseModel`), implement `_run()`. Sync and async `_run` both supported.
- `@tool` decorator on a plain function; schema is inferred from the signature.

The `description` field is explicitly documented as the thing the LLM reads to decide
usage ("It's vital for effective utilization") — i.e. the tool contract is
half-typed (args) and half-prose (when to use it).

Output handling is more considered than most:

- Tools may declare a Pydantic **output** model. Direct Python callers get the native
  object; the agent gets a structured JSON rendering. `format_output_for_agent()` is
  overridable so the agent-facing view (e.g. Markdown) can differ from the
  programmatic return value. **Two representations of one result, deliberately.**
- `ToolFailure` is a distinct class rather than an error string, so "the tool failed"
  is distinguishable from "the tool succeeded and returned text describing an error"
  — a real ambiguity in string-returning tool loops.
- Failure policy is `ignore` | `warn` (default) | `raise`, and **cascades
  tool → task → agent → crew → default**. Policy is layered, not per-call.
- `cache_function` allows per-result caching predicates; crew-level `cache=True`
  memoizes tool results by default.
- `result_as_answer` (agent/tool level) short-circuits the loop, returning the tool's
  output as the agent's final answer without another LLM turn.

Delegation is itself implemented as tools: when `allow_delegation=True`, delegation
and "ask question" tools are injected into the agent's toolset so coworker
communication travels the same path as any other call. **No separate agent-to-agent
message channel** — one mechanism.

## Context/Memory Management

CrewAI distinguishes three things that are often conflated:

1. **Context** — task-to-task data flow. Sequential process auto-passes the previous
   output; `context=[task_a, task_b]` declares explicit, possibly non-adjacent
   dependencies and forces a join on both.
2. **Knowledge** — static reference material (text, PDF, CSV/Excel, JSON, web, raw
   strings), auto-chunked with configurable overlap, embedded and retrieved.
   Scoped either **per-agent** (private, role-specific) or **per-crew** (shared),
   in *separate storage collections*, and an agent may hold both. Query rewriting
   optimizes the retrieval query before search. Defaults to OpenAI
   `text-embedding-3-small` **regardless of which LLM provider you use** —
   embeddings and generation are separately configured.
3. **Memory** — accumulated experience across runs.

The memory layer has been **rewritten into a single unified `Memory` class**,
replacing an earlier fragmented set (short-term / long-term / entity / contextual,
backed by ChromaDB + SQLite3). The current design:

- **Hierarchical scopes** — path-like strings (`/project/alpha`, `/agent/researcher`)
  forming a tree. If you save without a scope, **an LLM infers the placement**, along
  with categories and importance. The tree is meant to grow from usage rather than
  from an upfront schema.
- **Composite scoring on recall** — weighted blend of semantic similarity, recency
  (exponential decay), and importance, with the weights tunable per domain (recency
  for fast-moving projects, importance for knowledge bases).
- **`MemoryScope`** restricts operations to one subtree (agent privacy);
  **`MemorySlice`** spans branches ("my scope plus shared company knowledge").
- **Consolidation** — similar records merge/update to prevent duplicates;
  within-batch near-duplicates are caught by vector similarity *without* an LLM call.
- **Cost shaping** — long recall queries get LLM analysis, short ones skip it.
  `remember_many()` writes in the background; `recall()` blocks on pending writes for
  read-your-writes consistency.
- **Graceful degradation** — if LLM analysis fails, the memory still saves with safe
  defaults.
- Storage defaults to **LanceDB** under `./.crewai/memory` (a move off ChromaDB for
  memory, though `chromadb` remains a core dependency).

Separately, the in-loop context problem is handled by `respect_context_window`
(default `True`): on overflow the agent **summarizes** and continues rather than
failing. Turning it off makes overflow an exception.

## Sandboxing & Permissions

**This is the weakest area, and the direction of travel is the finding.**

CrewAI previously shipped `allow_code_execution` with `code_execution_mode`:

- `"safe"` — execute in a Docker container.
- `"unsafe"` — execute directly in the host process.

Both attributes are now **deprecated, and `CodeInterpreterTool` has been removed from
CrewAI tools.** The documented guidance is to use third-party services (E2B, Modal)
for secure code execution. CrewAI decided that **shipping a sandbox is not its job**
and withdrew from it entirely rather than maintain a security boundary.

There is no capability/permission model otherwise. Tools are plain Python objects
with unrestricted process authority: a tool in the list can do anything the process
can. The only "permissioning" primitives are indirect:

- Which tools appear in an agent's `tools` list.
- `allow_delegation` gating coworker access.
- `human_input=True` on a task / `@human_feedback` in a flow — human approval as a
  checkpoint, not an enforcement mechanism.
- Guardrails validating *output*, after the side effects have already happened.

Resource limits exist but are cost controls, not safety: `max_iter` (default 20),
`max_rpm`, `max_execution_time`, `max_retry_limit` (default 2).

**Telemetry is on by default.** Anonymous by default: CrewAI/Python version, a random
crew key/ID, process type, a boolean for memory usage, task and agent counts. Opt out
with `CREWAI_DISABLE_TELEMETRY=true` or `OTEL_SDK_DISABLED=true`. Setting
`share_crew=True` opts into sending **full execution data — goals, backstories,
context, and task outputs** — which the docs themselves flag as a GDPR concern.
Multiple GitHub issues (#241, #372, #2536, #2945) track difficulty actually disabling
it, including a period where CrewAI telemetry could not be disabled without disabling
OpenTelemetry globally.

## Multi-Agent Support

- **Agent identity is prose.** `role` / `goal` / `backstory` are three strings
  interpolated into a prompt template. There is no typed capability declaration, no
  machine-checkable statement of what an agent can do. In hierarchical mode, the
  manager LLM routes work by *reading these strings*. Agent selection is therefore a
  prompt-engineering problem, not a dispatch problem.
- **Delegation is opt-in per agent** (`allow_delegation`, default `False`) and, as
  above, implemented as injected tools.
- **Hierarchical** gives a manager agent planning + delegation + validation.
  `manager_agent` lets you supply a fully configured agent; `manager_llm` synthesizes
  one.
- **Async and fan-out**: `async_execution` on tasks; `kickoff_for_each` /
  `akickoff_for_each` map a crew over an input list; `akickoff()` for native async.
  `stream=True` for incremental output.
- **Output** is `CrewOutput` with `raw`, `json_dict`, `pydantic`, `tasks_output`, and
  `token_usage`.
- **Observability** hooks: `step_callback`, `task_callback`,
  `before_kickoff_callbacks` / `after_kickoff_callbacks`, plus typed events
  (`ToolUsageStartedEvent`, `ToolUsageFinishedEvent`, `ToolUsageErrorEvent`) and
  knowledge-retrieval events.
- **Checkpointing** (`checkpoint=True` or a `CheckpointConfig`) resumes without
  re-running completed tasks — the crew-level analogue of Flow `@persist`.
- **Configuration** has migrated from `config/agents.yaml` + `config/tasks.yaml` to a
  JSONC layout (`crew.jsonc` referencing per-agent files like
  `agents/researcher.jsonc`); the old layout is still available via `--classic`.
- **Training mode**: `crew._train` captures initial outputs plus human feedback keyed
  by agent ID and iteration, persisted for later prompt improvement.

## Notable Design Decisions

1. **Deterministic control flow was retrofitted, not designed in.** Flows exist
   because autonomous crews could not be shipped to production. The build order is
   the lesson.
2. **The manager is an LLM, and routing is prose-matching.** Hierarchical process
   delegates *scheduling itself* to a model reading role/backstory strings. Maximum
   flexibility, zero static analyzability — you cannot know the task graph before
   running it.
3. **Two control planes, one package, composable.** Flows can contain crews; crews
   cannot contain flows. The hierarchy is explicit and one-directional.
4. **Errors degrade rather than propagate.** Parse failure, context overflow, and
   iteration exhaustion each convert into a message or a formatted answer. Combined
   with the `warn` default failure policy, the system prefers a plausible answer over
   a loud failure.
5. **Failure policy cascades through the containment hierarchy** (tool → task → agent
   → crew → default). Policy is layered configuration, not a per-call argument.
6. **`ToolFailure` as a type, not a string.** Distinguishing genuine failure from
   text-that-mentions-an-error is a real correctness decision most tool loops skip.
7. **Dual result representation.** A tool's Python return value and its agent-facing
   rendering are separately controllable (`format_output_for_agent`).
8. **Delegation is a tool.** Agent-to-agent communication reuses the tool-call
   mechanism instead of adding a second channel.
9. **Memory placement is LLM-inferred.** No upfront schema; the model picks the scope
   path, category, and importance. Retrieval is a tuned blend of similarity, recency,
   and importance — an explicitly *lossy, heuristic* store, sold as such.
10. **Cost-shaped memory operations.** LLM analysis is skipped for short queries;
    dedup uses vector similarity before reaching for an LLM; writes are async with a
    read-your-writes barrier.
11. **Embeddings are configured independently of the LLM**, defaulting to OpenAI
    regardless of provider.
12. **Sandboxing was tried and abandoned.** Docker-based safe mode existed, then was
    deprecated and removed, with users redirected to E2B/Modal.
13. **Structured output is a validation layer, not a type system.** Prose
    `expected_output` is the contract; Pydantic models and guardrails (function-based
    *or* natural-language LLM-judged, retried up to `guardrail_max_retries`) are
    applied after generation.
14. **Provider access narrowed from LiteLLM to a direct OpenAI dependency**, with
    everything else an extra — a deliberate move away from a universal-adapter
    dependency toward a default path plus opt-ins.
15. **Telemetry on by default, with a documented full-payload opt-in** whose privacy
    implications the docs themselves warn about.

## Relevance to Crescent

Crescent's current state: `lib/ai/tools.lua` is a 79-line loop (`mod.run`) that calls
`ai.generate`, dispatches tool calls through a `handlers` table keyed by name,
`pcall`s each handler, JSON-encodes non-string returns, appends `role="tool"`
messages, and bails with `"max rounds exceeded"` after `max_rounds` (default 10).
`lib/taskgraph` provides orchestration. The comparisons that matter:

**Already aligned.** Crescent's loop uses native tool calls only, dispatches by name,
and returns `(nil, err)` rather than throwing — matching CrewAI's native path without
the ReAct fallback, and matching crescent's own error convention. CrewAI's fallback
exists to support weak/local models; whether crescent needs one is a real open
question, not a settled gap.

**Directly transferable, low cost:**

- `ToolFailure`-as-a-type. `tools.lua` currently encodes handler errors as
  `'{"error": ...}'` — a *string* the model cannot distinguish from a tool that
  legitimately returned an error document. CrewAI hit this and fixed it with a type.
- `result_as_answer` — a tool that ends the loop without another LLM round-trip.
- Explicit failure policy (`ignore`/`warn`/`raise`) instead of the current implicit
  always-continue-on-`pcall`-failure.
- Distinguishing "unknown tool" (a harness bug) from "tool raised" (a data error);
  both are currently the same shape.

**The Crews/Flows lesson, applied.** Crescent already has `lib/taskgraph`. CrewAI's
history suggests building the agent app *on* the deterministic graph from the start
and treating an autonomous multi-agent crew as a node type within it — rather than
building autonomy first and retrofitting a graph, which is what CrewAI had to do.
Whether crescent wants autonomous crews at all is an open design question this survey
does not answer.

**Where crescent's constraints force divergence:**

- *Caps-first.* CrewAI has no permission model; tools hold ambient process authority.
  Crescent's caps-first rule makes the tool-authority question unavoidable at design
  time — every tool must take its I/O caps as injected arguments. This is a place
  where crescent is *ahead* of the prior art, and CrewAI's retreat from sandboxing
  suggests nobody should expect the framework layer to retrofit it.
- *Zero-dependency.* CrewAI's memory/knowledge design assumes a vector DB (LanceDB /
  ChromaDB) and an embedding API. Neither is available to crescent for free. The
  *composite scoring* idea (similarity × recency-decay × importance) is portable; the
  storage substrate is not. A crescent memory layer needs its retrieval substrate
  decided before its API — substrate before consumers.
- *Prose contracts vs. types.* CrewAI's agents and tasks are natural-language strings
  with types applied afterward. Crescent has a real type system. Whether agent/task
  definitions should be typed structures rather than prose is the single biggest
  divergence available, and it is a design decision to be made, not one this survey
  settles.
- *Telemetry.* Default-on telemetry with a full-payload opt-in is a posture crescent
  should consciously reject rather than inherit by omission.

**Open questions this survey surfaces but does not answer** (each affects semantics
and needs an explicit decision):

1. Does crescent's agent app need a text-parsed fallback loop for models without
   native tool calling?
2. Are agent/task definitions typed structures or prose?
3. Is there a memory layer at all, and if so what retrieval substrate exists in a
   zero-dependency Lua environment?
4. Is autonomous delegation in scope, or is the deterministic graph the whole model?
5. What is the failure-policy default — continue, warn, or abort?

## Sources

- [crewAIInc/crewAI on GitHub](https://github.com/crewAIInc/crewAI) — README, positioning, stats, license.
- [crew_agent_executor.py](https://github.com/crewAIInc/crewAI/blob/main/lib/crewai/src/crewai/agents/crew_agent_executor.py) — read via `raw.githubusercontent.com`; dual-mode loop, iteration/overflow/parse-error handling, HITL, training mode.
- [lib/crewai/pyproject.toml](https://raw.githubusercontent.com/crewAIInc/crewAI/main/lib/crewai/pyproject.toml) — dependency graph, version, extras.
- [Flows — CrewAI docs](https://docs.crewai.com/en/concepts/flows) — decorators, state modes, `@persist`, routing, joins.
- [Crews — CrewAI docs](https://docs.crewai.com/en/concepts/crews) — crew attributes, kickoff variants, checkpointing, `CrewOutput`, `share_crew`.
- [Agents — CrewAI docs](https://docs.crewai.com/en/concepts/agents) — role/goal/backstory, constructor attributes, code-execution deprecation.
- [Tasks — CrewAI docs](https://docs.crewai.com/en/concepts/tasks) — task attributes, context flow, guardrails, structured outputs.
- [Processes — CrewAI docs](https://docs.crewai.com/en/concepts/processes) — sequential vs hierarchical, manager role.
- [Tools — CrewAI docs](https://docs.crewai.com/en/concepts/tools) — `BaseTool`, `@tool`, `ToolFailure`, failure policies, caching, output formatting.
- [Memory — CrewAI docs](https://docs.crewai.com/en/concepts/memory) — unified `Memory`, scopes/slices, composite scoring, consolidation, LanceDB default.
- [Knowledge — CrewAI docs](https://docs.crewai.com/en/concepts/knowledge) — sources, chunking, agent vs crew scope, embedder defaults.
- [Telemetry — CrewAI docs](https://docs.crewai.com/en/telemetry) and issues [#241](https://github.com/crewAIInc/crewAI/issues/241), [#372](https://github.com/crewAIInc/crewAI/issues/372), [#2536](https://github.com/crewAIInc/crewAI/issues/2536), [#2945](https://github.com/crewAIInc/crewAI/issues/2945).
- [Crew Configuration and Orchestration — DeepWiki](https://deepwiki.com/crewAIInc/crewAI/2.1-crew-configuration-and-orchestration) — JSONC vs `--classic` YAML layout.
- [CrewAI's Genuinely Unique Features (Vadim's blog)](https://vadim.blog/crewai-unique-features) and [CrewAI Explained (Atlan)](https://atlan.com/know/ai-agent/what-is-crewai/) — third-party framing of the Crews/Flows split.
