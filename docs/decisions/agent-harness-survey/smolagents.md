# smolagents — Agent Harness Survey

Survey of `github.com/huggingface/smolagents` (Hugging Face) as prior art for an
agentic harness. Focus is on the *decisions* the project made and the reasoning
it published, not a feature catalogue.

Repo existence verified by fetching `https://github.com/huggingface/smolagents`
("🤗 smolagents: a barebones library for agents that think in code"). It is the
successor to the deprecated `transformers.agents`.

Evidence quality: primary sources are the GitHub README, the official docs
(`huggingface.co/docs/smolagents`), the launch blog post, and direct reads of
`src/smolagents/{agents,memory,tools,local_python_executor}.py` and
`src/smolagents/prompts/code_agent.yaml` on `main`. Source reads were done via
summarising fetches rather than line-by-line reading, so structural claims are
reliable but exact line-level behaviour should be re-verified before being
copied. Anything marked *(secondary)* comes from third-party write-ups.

## Overview

smolagents is a small Python agent library whose thesis is a single inversion of
the industry default: **the LLM's action is a block of Python code, not a JSON
tool call**. Tools are ordinary Python functions; the model writes a snippet
that calls them, and the harness executes that snippet in a restricted
interpreter. Everything else in the design — the custom AST interpreter, the
sandbox menu, the state dictionary that persists across steps — follows from
taking that inversion seriously.

The second stated value is minimal abstraction: the README claims the core agent
logic is roughly a thousand lines, and the launch post frames this restraint as
deliberate ("~thousands lines of code") so the framework stays readable rather
than becoming a graph-DSL.

It is model-agnostic (local models, HF Inference Providers, OpenAI, Anthropic,
100+ more via LiteLLM), modality-agnostic (text/vision/video/audio), and
tool-agnostic (MCP servers, LangChain tools, Hub Spaces).

## Architecture

**One loop, two step implementations.** `MultiStepAgent` is the base class and
owns the ReAct loop; `CodeAgent` and `ToolCallingAgent` differ only in their
`_step_stream()` implementation. The conceptual guide gives the loop in five
lines:

```python
memory = [user_defined_task]
while llm_should_continue(memory):
    action = llm_get_next_action(memory)
    observations = execute_action(action)
    memory += [action, observations]
```

The run loop lives in `_run_stream()`, a generator that yields steps as they
execute, so streaming and non-streaming modes are the same code path — the
non-streaming caller just drains the generator. `stream=True` hands the
generator to the caller instead.

**Explicit agency spectrum.** The docs refuse a binary definition of "agent" and
publish a ladder instead, which is the framing device for the whole library:

| Agency | Description | Short name |
| --- | --- | --- |
| ☆☆☆ | LLM output has no impact on program flow | Simple processor |
| ★☆☆ | LLM output controls an if/else switch | Router |
| ★★☆ | LLM output controls function execution | Tool call |
| ★★☆ | LLM output controls iteration and continuation | Multi-step agent |
| ★★★ | One agentic workflow can start another | Multi-agent |
| ★★★ | LLM acts in code, can define its own tools / start other agents | Code agents |

Paired with an explicit anti-recommendation: *"For the sake of simplicity and
robustness, it's advised to regularize towards not using any agentic
behaviour."* Agents are for when a predetermined workflow "falls short too
often" — the library actively argues against its own use for router/chain cases,
because "you can write all the code yourself. You'll be much better that way."

**Loop control knobs.** `step_number` runs 1..`max_steps`; on overrun,
`_handle_max_steps_reached()` calls `provide_final_answer()` to synthesise
something from memory and logs `AgentMaxStepsError` — the run always produces an
answer rather than raising into the caller. `planning_interval` inserts an
explicit planning step at step 1 and every N steps thereafter.
`final_answer_checks` is a list of callbacks receiving (answer, memory, agent);
an assertion failure raises `AgentError` and the loop continues, so validators
push the agent to retry rather than terminating the run. `interrupt_switch`
allows external interruption.

**Error taxonomy is the interesting decision.** `AgentGenerationError`
(harness/implementation faults) propagates immediately and kills the run;
`AgentError` (model faults — bad code, tool exception, failed validation) is
recorded *into the current memory step* and the loop continues. The error text
becomes the next observation, so the model sees its own failure and corrects.
Harness bugs are never fed back to the model as if they were the model's
problem.

**Tool abstraction.** A `Tool` declares `name`, `description`, `inputs` (dict of
name → `{type, description}`), and `output_type`, drawn from a closed
`AUTHORIZED_TYPES` set (`string`, `boolean`, `integer`, `number`, `image`,
`audio`, `array`, `object`, `any`, `null`). Validation at init is strict: the
`forward()` signature must match the declared input keys exactly, names must be
valid non-reserved Python identifiers, every input needs a description, and
nullable parameters must be marked in both places. A `@tool` decorator derives
all of this from type hints and the docstring. `setup()` provides lazy one-shot
initialisation for expensive tools (model loading) separate from construction.

Notably, tools render themselves *differently per agent type*:
`to_code_prompt()` emits a Python function signature with docstring;
`to_tool_calling_prompt()` emits a concise typed description. The same tool
object serves both protocols without the caller choosing.

Interop is a first-class surface: `from_mcp()`, `from_langchain()`,
`from_space()` / `from_gradio()`, `from_hub()` (gated behind
`trust_remote_code=True`), plus `push_to_hub()` which publishes a tool as a
Space with code, requirements, and a Gradio demo. Tools are treated as a
shareable artifact type, not just a local function registry.

## Tool-Calling Protocol

This is the project's central thesis, so it gets the most space here.

### The claim

From the docs, restated nearly verbatim in three places:

> Why is code better? Well, because we crafted our code languages specifically
> to be great at expressing actions performed by a computer. If JSON snippets
> were a better way, this package would have been written in JSON snippets and
> the devil would be laughing at us.

Four named advantages, cited to *Executable Code Actions Elicit Better LLM
Agents* (arXiv 2402.01030) plus 2411.01747 and 2401.00812:

- **Composability** — "could you nest JSON actions within each other, or define
  a set of JSON actions to re-use later, the same way you could just define a
  python function?" Loops, conditionals, and intermediate variables are free.
- **Object management** — "how do you store the output of an action like
  `generate_image` in JSON?" Code keeps the object in a variable; JSON protocols
  must serialise it or invent a handle scheme.
- **Generality** — code expresses anything a computer can do; the tool schema
  only expresses what was pre-declared.
- **Representation in training data** — models have seen vastly more Python than
  bespoke JSON action formats, so the format is already in-distribution.

The README's quantitative claim is **~30% fewer LLM calls** than dict-based tool
calling, because one code block can fan out (a `for` loop over several searches)
where JSON tool-calling needs one round-trip per call. The launch post's
benchmarks show CodeAgent ahead of tool-calling agents across model
architectures; exact per-benchmark percentages were not recoverable from the
fetched text, so treat the direction as sourced and the magnitude as
unconfirmed.

### The mechanism

The `CodeAgent` system prompt (`prompts/code_agent.yaml`) defines a
Thought → Code → Observation cycle. The model emits a `Thought:` sequence and
then code between templated opening/closing tags (templated, because different
models are steered toward different delimiters). The harness regex-extracts the
code block, executes it, and `print()` output becomes the next observation.

Ten numbered rules are given to the model, the load-bearing ones being: use only
variables you defined; never re-do an identical tool call; don't shadow a tool
name with a variable; no notional variables; imports only from the authorized
list; and **"The state persists between code executions"** — variables survive
across steps, which is what makes object management work at all. Two rules
split on whether a tool declares a JSON output schema: without one, "take care
to not chain too many sequential tool calls" (the model can't predict the
result's shape); with one, "you can confidently chain multiple tool calls." That
is a genuinely subtle design point — the schema exists to license chaining
depth, not to validate output.

`final_answer` is a *tool*, and termination is detected structurally: the local
executor wraps `final_answer` so that calling it raises `FinalAnswerException`,
caught separately from real errors, flagging `is_final_answer=True`. The model
never emits a "done" token; it calls a function, and control flow does the rest.

`ToolCallingAgent` remains for the JSON path — `model.generate()` with
`tools_to_call_from`, native structured tool calls parsed and dispatched, final
answer detected by tool name `== "final_answer"`. The docs do not treat this as
legacy: the multi-agent tutorial explicitly picks `ToolCallingAgent` for the web
agent because "web browsing is a single-timeline task that does not require
parallel tool calls, so JSON tool calling works well for that," and `CodeAgent`
for the manager "since this agent is the one tasked with the planning and
thinking." The thesis is a default, not a monoculture.

## Context/Memory Management

Memory is a **typed list of step objects**, not a message array. `AgentMemory`
holds `SystemPromptStep`, `TaskStep` (task text + images), `PlanningStep`,
`ActionStep`, and `FinalAnswerStep`. `ActionStep` is the rich one: model inputs
and outputs, tool calls with arguments, observations (text and images), errors,
timing, and token usage.

The consequential decision is that **messages are derived, not stored**. Each
step type implements `to_messages()`, and the prompt is rebuilt from the typed
log every turn. That means the harness can re-render the same history
differently for different purposes — and it does: `to_messages(summary_mode=…)`
drops certain message types, which is how planning steps see a condensed history
without prior plans being echoed back (the docs note this is to avoid biasing
the new plan toward the old one). `get_succinct_steps()` omits model inputs;
`get_full_steps()` keeps everything, for logging and replay. `memory.replay()`
pretty-prints the run.

There is no automatic summarisation or token-budget compaction in the memory
layer as read — context control is exerted through `max_steps`, the
summary-mode rendering, `max_print_outputs_length` truncation on observations,
and `memory.reset()` (which clears steps but preserves the system prompt).
Callers wanting compaction hook `CallbackRegistry`, which fires registered
functions per step type and can mutate steps in place — the documented route for
things like dropping old images from memory.

Sub-agent context is deliberately not shared: a managed agent returns a text
report, optionally with `provide_run_summary` appending its working detail.
Isolation by default, escalation by flag.

## Sandboxing & Permissions

smolagents is unusually candid that its thesis creates the risk. The docs
enumerate four attack paths: plain LLM error, supply-chain (compromised model),
**prompt injection via browsed web content injected into agent memory**, and
exploitation of publicly exposed agents. And they state the structural
consequence directly: "code agents give much higher agency to the LLM on your
system than other less agentic setups: this goes hand-in-hand with higher risk."

The permission model is a ladder of increasing security at increasing setup
cost, with the framing "no solution will be 100% safe."

**Tier 0 — `LocalPythonExecutor`.** Rather than `eval`/`exec`, they rebuilt a
Python interpreter that walks the AST node by node (`evaluate_ast()`), with a
handler per node type; any construct without an explicit handler errors. Its
controls:

- Imports denied by default; allowed only via an authorization list, with
  submodules requiring separate authorization (`numpy.*` wildcards supported).
  The docs call out that "some seemingly innocuous packages like `random` can
  give access to potentially harmful submodules, as in `random._os`."
- A hard `DANGEROUS_MODULES` blocklist (os, subprocess, socket, sys, …) and
  `DANGEROUS_FUNCTIONS` (`compile`, `eval`, `exec`, `globals`, `__import__`)
  that error even if reached indirectly.
- Dunder attribute access (`__class__`, `__dict__`) blocked via a
  `nodunder_getattr()` wrapper — closing the standard Python sandbox-escape
  chain.
- Operation caps: `MAX_OPERATIONS` (10M) and `MAX_WHILE_ITERATIONS` (1M) against
  infinite loops and resource exhaustion.
- Three tool namespaces: `static_tools` (assignment to them raises — the model
  cannot shadow or replace a tool), `custom_tools` (mutable), and
  `BASE_PYTHON_TOOLS` (math, conversions, iteration builtins).
- `print()` is intercepted into a `PrintContainer` in state rather than reaching
  stdout, so observations are captured, bounded, and attributable.

And an explicit disclaimer that this is a hardening layer, not a boundary: "no
local python sandbox can ever be completely secure… The only way to run
LLM-generated code with truly robust security isolation is to use remote
execution options like E2B or Docker." The README says flatly: "Do not use it to
run untrusted code."

**Tier 1 — snippet in a remote sandbox.** `executor_type="e2b" | "docker" |
"modal" | "blaxel"`. Agent, model, and tools stay local; only the generated code
crosses into the sandbox, and only its output comes back. Agent state is shipped
to the sandbox at the start of each `run()`. Cost: no secrets in the sandbox, so
**managed agents don't work** — a sub-agent needs to call a model, and the
credentials aren't there. Agents are context managers (`with CodeAgent(...)`) so
the sandbox is torn down deterministically; `cleanup()` otherwise.

**Tier 2 — whole agentic system in the sandbox.** Everything (agent, model
client, tools) runs inside E2B or Docker. Supports multi-agent and gives full
isolation, at the cost of manual setup and shipping API keys into the sandbox.
Their reference Dockerfile runs as `USER nobody` with `mem_limit=512m`,
`cpu_quota=50000`, `pids_limit=100`, `security_opt=["no-new-privileges"]`,
`cap_drop=["ALL"]`.

The two-tier split is presented as an explicit trade table, not a
recommendation: tier 1 is easier and keeps secrets out; tier 2 is the only way
to get multi-agent under isolation.

Notably absent: there is **no per-action human approval step**. Permission is
enforced by capability boundary (what the interpreter and sandbox permit) rather
than by interactive consent — the opposite pole from Cline's approve-each-edit
model.

## Multi-Agent Support

Sub-agents are **tools**. A `CodeAgent` or `ToolCallingAgent` given `name` and
`description` (both mandatory for this) can be passed in a manager's
`managed_agents=[...]` list; the framework synthesises `inputs` and
`output_type` for it, giving it a `task` parameter (a detailed natural-language
brief) plus optional `additional_args` for structured context like images.
Invoking it runs its own `run()`; `provide_run_summary` optionally appends its
working detail to the returned text.

Consequences of that single decision:

- The manager delegates by **writing a function call in Python** — so
  delegation, iteration over sub-agents, and combining their results are all
  just code, with no separate orchestration DSL. This is the top rung of the
  agency ladder ("one agentic workflow can start another") reached without new
  machinery.
- Hierarchy only. The documented topology is manager → workers; there is no
  peer-to-peer messaging or shared blackboard.
- Sub-agents are context-isolated by construction: the manager sees a text
  report, never the sub-agent's step history.
- The interface between agents is prose. A dedicated `managed_agent` prompt
  block instructs the worker to return a short version, an extremely detailed
  version, and additional context.
- Heterogeneous by design — the tutorial pairs a `ToolCallingAgent` web worker
  under a `CodeAgent` manager, choosing protocol per role.

The sandbox interaction above is the honest cost: multi-agent and
snippet-level sandboxing are mutually exclusive.

## Notable Design Decisions

1. **Writing a Python interpreter to make the thesis safe enough to ship.**
   Committing to code-as-action forced building an AST-walking interpreter with
   an import allowlist, dunder blocking, and operation caps. This is the
   library's largest engineering investment and it exists purely to service the
   protocol choice — a strong signal about what the thesis actually costs.
2. **Publishing the anti-recommendation.** The docs tell you not to use agents
   when a fixed workflow will do, and tell you that for routers and chains
   hand-written code will serve you better. Framework docs that argue against
   the framework are rare and worth copying.
3. **Agency as a spectrum with a published ladder**, rather than "agent" as a
   binary product category. It gives users a vocabulary for choosing the least
   agency that solves the problem.
4. **Two protocols, chosen per role, sharing one loop and one tool object.** The
   code-vs-JSON argument is a default, not an exclusion; the same `Tool`
   renders into either prompt form.
5. **Termination as a tool call implemented via exception.** `final_answer` is
   an ordinary tool; the executor wraps it to raise, so completion is detected
   by control flow rather than by parsing a sentinel out of model text.
6. **Typed step log as the memory primitive, messages rendered on demand**, with
   `summary_mode` letting the same history be re-rendered differently per
   purpose (notably: hiding old plans from the planner).
7. **Harness errors and model errors handled oppositely.** Model errors go into
   memory as observations to learn from; harness errors propagate and stop the
   run. The model is never asked to debug the framework.
8. **Tools declare an optional output schema whose purpose is to license
   chaining depth**, not to validate. Without a schema, the prompt tells the
   model to chain conservatively.
9. **Static tools are immutable inside the interpreter** — assignment to a tool
   name errors, so the model cannot rebind `final_answer` or a search tool.
10. **Sandbox lifetime bound to a context manager**, making teardown a language
    guarantee rather than a documented obligation.
11. **Tools as a distributable artifact** (`push_to_hub`, Spaces, MCP,
    LangChain adapters) — the tool, not the agent, is the unit of sharing.

## Relevance to Crescent

Grounded against the current tree: `lib/ai/init.lua` is a lazy provider registry
resolving `req.provider` (string name or table) to a provider module with
`generate`/`stream`/`embed`/`generate_image`, plus `mod.register` for custom
providers. `lib/ai/tools.lua` is a 79-line JSON tool loop: `mod.run(opts)` calls
`ai.generate` in a loop up to `max_rounds` (default 10), dispatches each
`tool_call` to `opts.handlers[name]` under `pcall`, JSON-encodes the result into
a `role="tool"` message, and returns `nil, "max rounds exceeded"` on overrun.
`lib/taskgraph` provides `run(task_def, executor, opts)` over a graph with
frontier and exec-graph tracking, combinators, and scaffold hooks.

Points of contact — these are observations, not recommendations:

- **The code-as-action thesis has a natural Lua form.** Crescent already has a
  Lua interpreter and a typechecker; "the model writes Lua that calls tool
  functions" is nearer to hand here than it was for smolagents in Python.
  Restricted execution would need a sandboxed environment table plus a hook-based
  instruction budget (`debug.sethook`), which is a very different — and in some
  respects cheaper — mechanism than AST walking. This is a design branch, not a
  settled direction; the JSON path in `lib/ai/tools.lua` already works and
  smolagents itself keeps both.
- **Capability injection vs. import allowlist.** smolagents' `authorized_imports`
  is doing, for a language with ambient globals, roughly what crescent's
  caps-first rule already does structurally. A crescent code-agent sandbox would
  start from an empty `_ENV` and receive exactly the caps the agent was granted —
  the allowlist would be the cap set, not a parallel mechanism.
- **`lib/ai/tools.lua` currently keeps a flat message array; smolagents keeps a
  typed step log and renders messages from it.** The typed-log approach is what
  enables summary-mode rendering, replay, and per-step callbacks. Whether
  crescent's loop should own that shape or delegate step tracking to
  `lib/taskgraph` (which already tracks a frontier and exec graph) is an open
  question — the two designs overlap and the boundary is undecided.
- **Errors.** `tools.lua` already returns handler failures to the model as
  `{"error": …}` observations, matching smolagents' model-error handling. It does
  not currently distinguish harness faults from model faults; smolagents' split
  is the cheap version of that distinction.
- **Termination.** `tools.lua` terminates on "no tool calls in the response",
  which is model-text-shaped. smolagents' `final_answer`-as-tool is structural.
- **Sub-agents as tools** composes with the existing handler table without new
  machinery, and would let `lib/taskgraph` own the multi-agent topology while
  `lib/ai` stays a single loop.
- **Absent from smolagents and present in crescent's stated posture:**
  per-action human approval. smolagents enforces permission at the sandbox
  boundary only. If an agent app under `lib/platform/apps/` wants interactive
  consent, that mechanism has no prior art here — see `cline.md` in this
  directory for the opposite pole.

## Sources

- [huggingface/smolagents (GitHub README)](https://github.com/huggingface/smolagents)
- [Introduction to Agents — conceptual guide](https://huggingface.co/docs/smolagents/conceptual_guides/intro_agents)
- [Secure code execution — tutorial](https://huggingface.co/docs/smolagents/tutorials/secure_code_execution)
- [Orchestrate a multi-agent system — example](https://huggingface.co/docs/smolagents/examples/multiagents)
- [smolagents launch blog post](https://huggingface.co/blog/smolagents)
- Source on `main`: [`agents.py`](https://raw.githubusercontent.com/huggingface/smolagents/main/src/smolagents/agents.py),
  [`memory.py`](https://raw.githubusercontent.com/huggingface/smolagents/main/src/smolagents/memory.py),
  [`tools.py`](https://raw.githubusercontent.com/huggingface/smolagents/main/src/smolagents/tools.py),
  [`local_python_executor.py`](https://raw.githubusercontent.com/huggingface/smolagents/main/src/smolagents/local_python_executor.py),
  [`prompts/code_agent.yaml`](https://raw.githubusercontent.com/huggingface/smolagents/main/src/smolagents/prompts/code_agent.yaml)
- Cited research: [Executable Code Actions Elicit Better LLM Agents (2402.01030)](https://huggingface.co/papers/2402.01030),
  [2411.01747](https://huggingface.co/papers/2411.01747),
  [2401.00812](https://huggingface.co/papers/2401.00812)
- Crescent tree reads: `lib/ai/init.lua`, `lib/ai/tools.lua`, `lib/taskgraph/init.lua`
