# BabyAGI — agent harness survey

Surveyed 2026-08-02. Prior art review for crescent's `lib/ai` expansion and a
planned agent app under `lib/platform/apps/`.

## Overview

BabyAGI (Yohei Nakajima, first published 2023-04-03) is the canonical minimal
"task-driven autonomous agent": roughly 100 lines of Python implementing a loop
that pops a task, executes it with an LLM, stores the result in a vector store,
then asks the LLM to generate follow-up tasks and re-prioritize the queue.
Its author states the intent was not a product but documentation of the
minimum pattern needed for an autonomous LLM agent.

**The repo named in the brief has been rewritten.** `github.com/yoheinakajima/babyagi`
today hosts an unrelated second-generation project — a "self-building agent"
built on a function-registry framework called *functionz*. The classic
task-loop code that BabyAGI is historically known for lives at
`github.com/yoheinakajima/babyagi_archive` (snapshot dated September 2024).
Both are covered below; unless stated otherwise, "BabyAGI" means the classic
archived loop, which is the architecturally relevant artifact for crescent.

Both versions carry an explicit non-production disclaimer from the author
("a framework built by Yohei who has never held a job as a developer"), and
the classic version warns that running the script continuously results in
high API usage.

## Architecture

### Classic BabyAGI (archive)

Four LLM-backed functions plus one storage class. No class hierarchy, no
plugin abstraction in the core, no async.

- `execution_agent(objective, task)` — retrieves the top 5 semantically
  similar prior results via `context_agent`, then prompts the model to
  perform the single task with the objective in view.
- `task_creation_agent(objective, result, task_description, task_list)` —
  reads the just-finished result and emits new tasks, instructed to avoid
  duplicating tasks already in the list.
- `prioritization_agent(this_task_id)` — re-ranks the *entire* pending queue
  by prerequisite ordering and goal relevance, returning a renumbered list.
- `context_agent(query, top_results_num)` — pure retrieval; queries the vector
  store for similar completed tasks. It is called an "agent" but issues no LLM
  call of its own.

`SingleTaskListStorage` is a `deque` with `append`, `replace`, `popleft`, a
monotonic task-id counter, and a method returning bare task names for prompt
interpolation.

Main loop:

```
while tasks remain:
    print the current task list
    task = tasks.popleft()
    result = execution_agent(OBJECTIVE, task.name)     # pulls context first
    store result in vector DB (namespace = RESULTS_STORE_NAME)
    new_tasks = task_creation_agent(...)               # appended to queue
    tasks = prioritization_agent(task.id)              # whole queue reordered
    sleep(5)
```

Note the loop has **no termination condition other than an empty queue**, and
the creation agent's job is to refill the queue — so absent an explicit
`ITERATIONS`/cooperative bound, it does not terminate on its own. The 5-second
sleep is the only rate control in the core loop. Error handling is retry-with-
10-second-backoff around OpenAI rate limits, timeouts, and connection errors.

Configuration is entirely environment-driven (`.env` via a `dotenvext`
extension): `LLM_MODEL` (default `gpt-3.5-turbo`; also GPT-4, llama via
llama-cpp, or `human`), `OPENAI_API_KEY`, `OBJECTIVE`, `INITIAL_TASK`,
`RESULTS_STORE_NAME`, `INSTANCE_NAME`, `COOPERATIVE_MODE`.

### Second-generation BabyAGI (current repo)

A completely different shape. The core is **functionz**, a function-management
framework: functions are registered via decorators carrying metadata (imports
required, other functions depended on, secret keys needed, description),
stored in a database, and related through a dependency graph that is resolved
automatically before execution. It ships a Flask dashboard on `:8080` for
registering/deregistering/updating functions, browsing execution logs, and
managing secrets, plus a trigger system that fires functions in response to
system events. Two experimental agents sit on top: `process_user_input`
(decide whether existing functions suffice, else write new ones) and
`self_build` (generate a set of user tasks, then author functions for them).
Packaged as `pip install babyagi`, Poetry-managed.

The through-line between generations is *decomposition into reusable units*;
what changed is that v1 decomposed into **tasks** (ephemeral, prompt-level)
and v2 decomposes into **functions** (persistent, code-level, graph-tracked).

## Tool-Calling Protocol

There is none in classic BabyAGI. This is the survey's most important
negative finding: the archived `babyagi.py` performs only LLM inference and
vector search. There is no tool schema, no function-calling API use, no shell
execution, no file I/O by the agent, no browser. "Executing a task" means
asking the model to emit text describing the task's completion, and storing
that text as if it were the outcome. The agent's entire effect on the world is
its printed transcript and its vector store.

Downstream forks (BabyAGI-as-a-Service, babyagi_assistant, LangChain's
`BabyAGI` chain) added tool use; the original did not have it.

The second-generation repo is where tool-calling appears, and in an unusual
form: rather than a fixed tool schema handed to the model, the registered
function database *is* the tool surface, and the model may **write new tools
into it at runtime**. AI function packs auto-generate descriptions and
embeddings for registered functions so that the agent can retrieve similar
existing functions before deciding to author a new one.

## Context/Memory Management

Classic BabyAGI's memory strategy is "embed every result, retrieve top-k by
similarity to the objective."

- Storage backends are selected by a fallback chain: Weaviate if configured,
  else Pinecone if an API key is present, else Chroma locally (the default).
  This is exactly a tier-selection pattern, chosen at init by config
  availability rather than by capability probing.
- Embeddings come from OpenAI's embedding endpoint, or a llama-based embedder
  when running local models.
- Each stored record is a vector of the enriched result text, with metadata
  `{"task": task_name, "result": result}`.
- Retrieval is `context_agent(query=OBJECTIVE, top_results_num=5)` — note the
  query is the *overall objective*, not the current task. Context is therefore
  "the 5 results most relevant to the goal," not "the 5 results most relevant
  to what I'm doing right now."

There is no conversation history in the classic loop. Each `execution_agent`
call is a fresh single-shot completion; continuity is carried entirely by
(a) the objective string, (b) the task queue, and (c) the retrieved top-5.
The vector store exists specifically to escape context-window limits — the
agent never accumulates a growing message array.

The second-generation system replaces this with a relational function database
plus execution logs (timing, inputs, outputs, errors) — durable structured
memory rather than semantic recall.

## Sandboxing & Permissions

Classic BabyAGI: **no sandbox, no permission model, and no need for one** —
because the agent has no side-effecting capabilities at all. Safety is a
property of the absence of tools, not of any containment mechanism. The only
documented risk in the README is financial (unbounded API spend from a loop
that never terminates), which is mitigated only by the operator stopping the
process.

Second-generation: the closest thing to a permission model is
**per-function secret-key declaration** — a registered function declares which
API keys it needs, and the framework manages those secrets and injects them.
That is credential scoping, not sandboxing; generated code still executes
in-process with full host privileges. The README explicitly warns that
triggers can cause unintended recursive execution and that the self-building
features are experimental and may not work as intended. No process isolation,
no capability gating, no approval gate before executing model-authored code.

## Multi-Agent Support

Classic BabyAGI's "agents" are prompt roles inside one process, not
independent actors — they share one queue, one objective, one vector
namespace, and run strictly in sequence. There is no concurrency, no
delegation, no sub-agent spawning, no inter-agent messaging.

What multi-agent support exists is instead **multi-instance**, via
`COOPERATIVE_MODE`:

- `none` — default; a single instance owns `SingleTaskListStorage`.
- `local` — swaps in `CooperativeTaskListStorage` backed by the `ray_tasks`
  extension, letting several BabyAGI processes on one machine share a task
  list and a results namespace (`INSTANCE_NAME` / `RESULTS_STORE_NAME`
  distinguish participants, and a "join existing objective" path lets a new
  instance attach to a running one).
- `distributed` — declared but unimplemented; a placeholder.

So coordination, where it exists, is through a **shared task queue and shared
vector namespace** rather than through agents talking to each other. Extensions
are loaded dynamically behind `can_import()` guards (`ray_tasks`,
`weaviate_storage`, `pinecone_storage`, `argparseext`, `human_mode`,
`dotenvext`).

## Notable Design Decisions

- **The task list is the entire agent state.** Reasoning, planning, and
  progress are all represented as one ordered queue of natural-language
  strings. Nothing else persists between iterations except embeddings. This is
  why the design is so widely copied — the state model fits in a sentence.
- **Re-prioritizing the whole queue every single iteration.** After each task,
  the full pending list is round-tripped through the LLM and returned
  renumbered. Expensive and lossy (the model can drop or mutate tasks), but it
  means the plan is continuously re-derived rather than fixed at the start —
  replanning is the default, not an exception path.
- **Tasks are strings, not structures.** No schema, no arguments, no
  dependencies, no success criteria, no completion check. Task identity is a
  sequential integer and a sentence. De-duplication is a prompt instruction
  ("avoid duplicating tasks"), not a mechanism.
- **`human` as an LLM model.** Setting `LLM_MODEL` to a value starting with
  `human` routes every would-be model call to `user_input_await(prompt)`.
  The human is not an approver bolted onto the loop; they are a drop-in
  implementation of the model interface. Costless to build, and it makes the
  whole loop debuggable and steppable with one env var.
- **Vector-store fallback chain by configuration.** Weaviate → Pinecone →
  local Chroma, resolved at startup, so the thing runs with zero external
  infrastructure by default while scaling up purely by adding credentials.
- **Extensions loaded behind import guards.** Optional capability degrades to
  absence instead of failing hard.
- **No termination condition.** The creation agent refills what the execution
  agent drains, so the natural state is perpetual motion. Frequently cited as
  the design's central practical flaw; forks almost universally add an
  iteration cap.
- **Results are asserted, not verified.** The model's text output *is* the
  outcome, stored as ground truth in the memory that conditions all later
  reasoning. Hallucinated results become durable context.

## Relevance to Crescent

- **`lib/ai/tools.lua` already occupies a strictly different point in the
  design space.** Its `mod.run` is a bounded (`max_rounds`, default 10)
  tool-calling loop with a growing `messages` array and named handlers — it
  is a conversational ReAct-style loop, where BabyAGI is a stateless
  task-queue loop with no tools. The two are complementary, not competing:
  a BabyAGI-shaped planner would sit *above* `tools.run`, calling it as the
  execution step. That layering is the concrete architectural takeaway.
- **`lib/taskgraph` is the structural correction to BabyAGI's weakest point.**
  Where BabyAGI's tasks are unstructured strings with prompt-level
  de-duplication, taskgraph has real nodes, a `frontier`, an `exec_graph`, and
  `combinators`. If crescent builds a task-driven agent, the open design
  question is whether LLM-proposed tasks enter as taskgraph nodes (gaining
  dependency tracking, tracking hooks, and inspectable execution) or as an
  unstructured queue alongside it. Those are genuinely different systems and
  the choice is not implied by existing code — it needs a decision.
- **The `human`-as-model trick maps directly onto crescent's provider
  registry.** A `human` provider in `lib/ai/providers` implementing the same
  interface would give a fully steppable agent loop for free, and doubles as
  a test double requiring no network. Low cost, high leverage; worth
  considering independent of any agent app.
- **Tier-by-config vs. tier-by-probe.** BabyAGI selects a vector backend by
  which credentials are present. Crescent's convention selects tiers by
  `pcall` capability probing at load. If crescent ever grows a vector/embedding
  store, note that credential presence and capability availability are
  different predicates and the crescent convention is the probe.
- **Caps-first is a real divergence.** BabyAGI reads API keys from the ambient
  environment throughout; crescent forbids that — an agent app must take its
  provider, HTTP client, and key as injected caps. `lib/ai/tools.lua` already
  threads `http_client`/`api_key`/`provider` through opts, which is the right
  shape to preserve.
- **What BabyAGI offers is the state model, not the code.** Objective +
  ordered task queue + retrieved context + continuous replanning is a pattern
  that fits in ~100 lines and is worth reaching for precisely because it is
  small. What it does not offer, and what crescent would have to supply
  itself: termination conditions, result verification, structured tasks,
  tool-calling, and any permission model whatsoever.

## Sources

- https://github.com/yoheinakajima/babyagi — current repo (functionz / self-building agent)
- https://github.com/yoheinakajima/babyagi_archive — archived classic task loop
- https://raw.githubusercontent.com/yoheinakajima/babyagi_archive/main/babyagi.py — classic source
- https://yoheinakajima.com/birth-of-babyagi/ — author's account of origin and intent
- https://www.ibm.com/think/topics/babyagi
- https://blog.parcha.ai/deep-dive-part-2-how-does-babyagi/
- https://www.noze.it/en/insights/babyagi-open-source/
- https://www.kdnuggets.com/2023/04/baby-agi-birth-fully-autonomous-ai.html
- Local grounding: `lib/ai/tools.lua`, `lib/taskgraph/init.lua` (read 2026-08-02)
