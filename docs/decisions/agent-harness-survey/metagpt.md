# Prior Art Survey: MetaGPT

Survey of [MetaGPT](https://github.com/geekan/MetaGPT) as prior art for an AI agentic
harness. Focus is on the *decisions* the project made and the reasons — stated where the
project states them, inferred-and-marked where it does not. Structural claims below were
checked against a shallow clone at commit `11cdf466` (2026-01-21, `master`); paper claims
are cited to the ICLR 2024 paper. Where a claim rests only on the paper's prose rather
than on code that still exists, that is stated.

## Overview

MetaGPT is the "software company as a multi-agent system" framework: one line of natural
language in, a repo out. Repo verified live — the GitHub API now resolves
`geekan/MetaGPT` to `FoundationAgents/MetaGPT` (org rename), MIT, Python, ~69.6k stars /
~8.9k forks, last push recorded `2026-01-21` at time of survey.

The stated core philosophy, from the README, is a single equation:

> `Code = SOP(Team)` is the core philosophy. We materialize SOP and apply it to teams
> composed of LLMs.

That is the whole thesis. Where AutoGen said "agents are participants in a conversation"
and let an LLM decide who speaks, MetaGPT said the opposite: the *procedure* is the
artifact worth encoding, humans already discovered good procedures for building software,
and the framework's job is to make an LLM team walk one. The paper frames this as a
remedy for "logic inconsistencies due to cascading hallucinations" in naive LLM chaining.

Two facts frame everything below, and the second is the one most secondary write-ups
miss:

1. **The published system is a fixed waterfall.** Product Manager → Architect → Project
   Manager → Engineer → QA Engineer, wired statically by which upstream *action* each
   role subscribes to. Roles do not choose their collaborators; the SOP does.
2. **The shipping system is no longer that.** In the current tree, `RoleZero` — a
   tool-using ReAct agent with a JSON command protocol — is the base class of every
   headline role, and the flag that restores the paper's pipeline is
   `use_fixed_sop: bool = False` (`metagpt/roles/di/role_zero.py:98`). The default CLI
   team is `TeamLeader, ProductManager, Architect, Engineer2, DataAnalyst`, with the
   paper's `Engineer` and `QaEngineer` **commented out** in
   `metagpt/software_company.py:56-62`.

So MetaGPT is two systems in one repo, and the *migration between them* is the most
informative thing in it. The project that most famously argued "encode the procedure"
has, over two years, demoted the encoded procedure to an opt-in compatibility mode and
replaced it with an LLM-routed team of generalist tool-users. A survey that reports only
the paper describes a system the maintainers no longer run by default.

Research lineage continues in-tree under `metagpt/ext/`: AFlow (ICLR 2025 oral —
automated agentic *workflow* generation), SELA (MCTS over ML pipelines), SPO
(self-supervised prompt optimization). The commercial product is MGX (mgx.dev); `MGXEnv`
is in the open repo.

## Architecture

### The five nouns

`Environment, Memory, Role, Action, Tool`. A `Team` owns an `Environment` and a budget;
the `Environment` owns `Role`s and routes `Message`s between them; a `Role` owns
`Action`s and private `Memory`.

`Team.run` (`metagpt/team.py:123`) is the whole outer loop, and it is strikingly small:

```python
while n_round > 0:
    if self.env.is_idle: break
    n_round -= 1
    self._check_balance()
    await self.env.run()
```

`Environment.run` gathers `role.run()` for every non-idle role concurrently
(`asyncio.gather`), so a round is a *synchronous barrier over a parallel step*, not a
turn order. Termination is by quiescence (`is_idle` — no news, no todo, empty buffer) or
by exhausting `n_round` (default 5).

`_check_balance` deserves a name-check as a design decision: budget is denominated in
**dollars**, not tokens or steps. `Team.invest(3.0)` sets `cost_manager.max_budget`, and
exceeding it raises `NoMoneyException` mid-run. The user-facing CLI verb is
`--investment`. Cost is a first-class, per-run, currency-denominated resource.

### Role as a state machine over Actions

`Role` (`metagpt/roles/role.py`) is `_observe → _think → _act`, with `_think` selecting
which `Action` to run. Three react modes (`RoleReactMode`):

- `REACT` — LLM picks the next action each step, by emitting a bare integer index into
  the role's action list (`STATE_TEMPLATE`: *"Just answer a number between 0-{n_states}
  ... If you think you have completed your goal ... return -1"*). Capped by
  `max_react_loop`.
- `BY_ORDER` — run actions in declaration order. This is the SOP mode.
- `PLAN_AND_ACT` — write a plan, then execute tasks against it.

Note what `_think` is in `REACT` mode: an integer-emitting classifier over a *closed*
action list. Not tool-calling, not free-form. The action set is fixed at role
construction; the model only chooses among them or stops. That is a deliberately narrow
decision surface, and it is the SOP philosophy applied at the level of a single role.

### The SOP wiring, concretely

There is no pipeline object. The waterfall is an emergent property of five
`_watch(...)` declarations, each naming *action classes*:

| Role | watches (upstream action) | runs |
|---|---|---|
| ProductManager | `UserRequirement`, `PrepareDocuments` | `WritePRD` |
| Architect | `WritePRD` | `WriteDesign` |
| ProjectManager | `WriteDesign` | `WriteTasks` |
| Engineer | `WriteTasks`, `SummarizeCode`, `WriteCode`, `WriteCodeReview`, `FixBug`, `WriteCodePlanAndChange` | `WriteCode` |
| QaEngineer | `SummarizeCode`, `WriteTest`, `RunCode`, `DebugError` | `WriteTest` |

`_watch` stores `{any_to_str(t) for t in actions}` — *stringified class paths*, not
objects. A role subscribes to "messages caused by `WriteDesign`" without importing
`WriteDesign`. The dependency graph is therefore expressed in string identity, resolved
at message-delivery time, and never materialized anywhere as a graph. This is a real
decision with real consequences: adding a role to the pipeline means editing that role's
`_watch` list and nothing else — but there is also no object you can inspect, validate,
or visualize to answer "what is the pipeline?"

Note the Engineer's and QaEngineer's `_watch` lists contain *their own* actions
(`WriteCode` watches `WriteCode`). Cycles are how the executable-feedback loop is
expressed — see Sandboxing & Permissions below.

### ActionNode: schema-constrained generation as the anti-hallucination device

The paper's claim is that structured artifacts beat dialogue. The mechanism is
`ActionNode` (`metagpt/actions/action_node.py`), and it is more interesting than
"structured output."

An `ActionNode` is a *tree* whose leaves are `(key, expected_type, instruction,
example)`. From `write_prd_an.py`:

```python
PRODUCT_GOALS = ActionNode(
    key="Product Goals",
    expected_type=List[str],
    instruction="Provide up to three clear, orthogonal product goals.",
    example=["Create an engaging user experience", ...],
)
```

The same tree is compiled three ways: into prompt *instructions* (each key with its
instruction), into a prompt *example* (each key with its example), and — via
`create_model_class` — into a **dynamically generated Pydantic model** used to validate
the parse. One declaration, three consumers, no drift between "what we asked for" and
"what we accept." A PRD is ~15 such nodes.

Around it sits a full review/revise apparatus: `auto_review` (LLM critiques its own
filled node against the instructions, returning per-key comments), `auto_revise`
(re-fills using those comments), plus `human_review`/`human_revise` variants, and
`ReviewMode`/`ReviseMode` enums to pick. Output format is enforced by tag wrapping
(`FORMAT_CONSTRAINT = "Format: output wrapped inside [CONTENT][/CONTENT]"`), and
malformed output goes through `metagpt/utils/repair_llm_raw_output.py` — a layered
repairer with named failure classes (`RepairType.CS` case sensitivity, `RKPM` required
key pair missing, `SCM` special character missing, `JSON`).

That repair module is the tell. MetaGPT chose a text protocol over provider-native
structured output, and paid for it with a taxonomy of malformation and a repair pass per
class. It is a coherent trade (portability across ~30 providers), but it is a trade, not
a free lunch.

### RoleZero: what replaced the SOP

`RoleZero` (`metagpt/roles/di/role_zero.py`) overrides `_think` and `_act` entirely,
branching to the inherited SOP implementations only `if self.use_fixed_sop`. In the
default path:

- `_think` assembles one prompt from: role prefix + current time, task-type descriptions,
  **all** the role's tool schemas as `json.dumps`, a retrieved few-shot experience, plan
  status, and the last `memory_k = 200` messages. Then one LLM call producing free-text
  thought followed by a JSON command array.
- `_act` parses the commands, executes them in order via a `dict[str, Callable]`, and
  appends the outputs to memory as a user-role message.
- `max_react_loop = 50` (vs. `1` in the base `Role`).
- The action machine is collapsed to a single dummy action — `metagpt/actions/di/run_command.py`
  is five lines: *"A dummy RunCommand action used as a symbol only."* It exists so
  `cause_by=RunCommand` remains a usable provenance tag for message routing. Actions
  survive as message labels; scheduling moved into the model.

`_react` is also overridden to call `_observe()` *inside* the loop, so a long-running
agent picks up new messages mid-task rather than only at turn boundaries.

### MGXEnv: routing through a Team Leader

`MGXEnv` (`metagpt/environment/mgx/mgx_env.py`) replaces broadcast-plus-filter with a
hub. Its `publish_message` has one structural rule — *"every regular message goes through
team leader"* — with three exceptions (user's `@role` direct chat, a direct-chat reply
coming back, and messages the TL itself is publishing). `TeamLeader` is a `RoleZero`
whose distinguishing capability is a *tool*: `publish_team_message(content, send_to)`,
registered via `@register_tool`. Delegation is a tool call.

Two details worth stealing:

- `publish_team_message` calls `self._set_state(-1)` — *"each time publishing a message,
  pause to wait for the response."* Delegation is blocking by construction.
- Its docstring is a prompt: *"DONT omit any necessary info such as path, link,
  environment, programming language, framework, requirement, constraint from original
  content to team members because you are their sole info source."* The lossy-channel
  problem of delegation is addressed by telling the delegator it is the only channel.

`move_message_info_to_content` rewrites `[Message] from Alice to Bob: ...` into the
content string, because — as the comment says — the `role` field is reserved for the LLM
API's `system|user|assistant` and only `content` reaches the model. Sender/recipient
identity is smuggled through prose. Any harness with a richer message type hits this same
wall at the provider boundary.

## Tool-Calling Protocol

### Two generations, both text

Neither generation uses provider-native function calling for agent control flow.

**Generation 1 — code-as-action (Data Interpreter).** Tools are described to the model as
Python API documentation; the model's "tool call" is a ```python block executed in a
persistent Jupyter kernel. The prompt says *"When you call a tool, import the tool from
its path first"* — hence `Tool.path` and `Tool.code` being fields on the tool record.

**Generation 2 — JSON commands (`RoleZero`).** The contract, from
`metagpt/prompts/di/role_zero.py`:

```
You must output ONE and ONLY ONE json array.
```json
[
    {
        "command_name": "ClassName.method_name" or "function_name",
        "args": {"arg_name": arg_value, ...}
    },
    ...
]
```
Notice: your output JSON data section must start with **```json [**
```

Three properties, each a decision:

- **Batched.** Multiple calls per turn, executed sequentially. This is why
  `exclusive_tool_commands` exists (`Editor.edit_file_by_replace`,
  `insert_content_at_line`, `append_file`, `open_file`): if a batch contains more than
  one, all but the first are *dropped by the parser*, because line-number-based edits
  invalidate each other. Batching forced them to invent a protocol-level concurrency
  rule.
- **Thought and call fused** in one completion — free text before the block.
- **Flat dotted string keyspace** (`Class.method`), not nested objects.

Plus one hardcoded pseudo-command: `{"command_name": "end"}` to terminate.

### Registration: the docstring *is* the schema

`@register_tool(tags=[...], include_functions=[...])` (`metagpt/tools/tool_registry.py`)
wraps a class or function into a process-global singleton registry. Schema extraction
(`tool_convert.py`) has two paths that must agree: live `inspect` for decorated objects,
and an `ast.NodeVisitor` over a *source string*, so arbitrary user `.py` files can be
registered by path without importing them.

The emitted unit:

```python
{"type": "function" | "async_function",
 "description": overall_desc,      # docstring before "Args:"
 "signature": "(a: int, b: str = 'x') -> dict",
 "parameters": param_desc}         # the raw "Args:" docstring section
```

There is **no JSON Schema**, no per-parameter type object, no `required` list. The model
receives a literal Python signature string and the raw Google-style docstring text.
`GoogleDocstringParser` is a one-liner that splits on `"Args:"`. `ToolSchema` is a
Pydantic model with a single `description: str` field, and validation failure is swallowed
by a bare `except: pass`. Registration is deliberately permissive: the cost of adding a
tool is writing a good docstring, and nothing else.

### Tool selection: a name grammar

`validate_tool_names()` accepts a heterogeneous list where each entry is a tool name, a
*tag*, a *filesystem path* (registered on the fly), or a **method-subset selector**:

```python
tools: list[str] = ["Plan", "Editor", "RoleZero", "Terminal:run_command",
                    "Browser:goto,scroll", "git_create_pull", ...]   # Engineer2
```

The colon form deep-copies the `Tool` and filters `schemas["methods"]`, so a role can
expose 3 of `Editor`'s 15 methods. `["<all>"]` means the whole registry. This is the
per-role capability surface, declared as data — the closest thing MetaGPT has to a
permission model, though it is scoping for prompt economy and role coherence, not
security (see below).

### Recommendation exists but is switched off where it would matter

`tool_recommend.py` implements recall-then-rank: BM25 over `f"{name} {tags}:
{description}"` (tokenizer is literally `text.split()`, marked `# FIXME`), or exact
task-type-to-tag match, then an LLM reranker. But `RoleZero` constructs
`BM25ToolRecommender(tools=self.tools, force=True)`, and `force=True` short-circuits:

```python
if self.force or (not context and not plan):
    return list(self.tools.values())
```

So for the agent path, retrieval is **off** — the curated per-role list goes into the
system prompt wholesale, every turn. Dynamic retrieval survives only in the Data
Interpreter path, where a *second* unforced recommender picks tools for the code-writing
sub-call. The split is worth naming: **retrieval is used to build code-generation
context, not to gate command dispatch.** Having built the retrieval machinery, they chose
not to put it in the dispatch path.

### Parsing: a repair funnel with an LLM in it

`parse_commands` (`metagpt/utils/role_zero_utils.py`) is the price of a text protocol,
itemized:

1. `CodeParser.parse_code(lang="json")`
2. a hack prepending `[` if the block ends with `]` but doesn't start with one
3. `repair_llm_raw_output(RepairType.JSON)`
4. on `JSONDecodeError` — **an extra LLM call** with `JSON_REPAIR_PROMPT`, fed the decode
   error
5. `repair_escape_error` (backslashes in code, math, file paths)
6. give up; the error text is appended to memory as a user message and the model retries
   next turn

Dispatch is a plain dict lookup into `tool_execution_map: dict[str, Callable]`, built by a
model-validator that maps `"Editor.open_file" → self.editor.open_file`. Unknown command
or any exception → the batch **breaks** (fail-fast), and the full
`traceback.format_exc()` goes back to the model as output.

The **schema shown to the model** (from the registry, keyed by class/method name) and the
**executable** (from `tool_execution_map`, keyed by string) are maintained in two separate
places and agree only by convention. `TeamLeader` even registers an alias
(`"TeamLeader.publish_message" → publish_team_message`). This is a genuine structural
weakness worth not copying.

### Results re-entry: prose, and the prose is load-bearing

No call-id correlation, no structured tool-result blocks. Outputs come back as a plain
user-role message:

```
Command Editor.read executed: <result>
```

That human-readable string is then *parsed by later code*: `parse_browser_actions`
matches `r"Command Browser\.(\w+) executed"` to splice in a fresh page render;
`parse_editor_result` matches `r"Command Editor\.(\w+?) executed"` to truncate all but
the latest 5 editor outputs. Context compaction implemented as regex over the
transcript — and the transcript format is therefore an undeclared internal API.

### Action vs. Tool

They are orthogonal axes that got tangled, and the distinction matters:

- **`Action`** is the unit of work in a Role's *state machine* — `rc.state` indexes into
  `self.actions`, `rc.todo` is the current one. It is also **message provenance**:
  `cause_by=WriteDesign` is how routing works.
- **`Tool`** is a *description record for the LLM* — name, path, schemas, source, tags.
  It has no `run`. It never executes anything.

An Action becomes a Tool by having its `run` method registered
(`@register_tool(include_functions=["run"])` sits on `SearchEnhancedQA`, `WritePRD`,
`WriteDesign`, …): the class identity stays a provenance tag while the method becomes a
command. Non-Actions register identically — `Plan` (a Pydantic schema exposing
`append_task`/`finish_current_task`), `Browser`, `Editor`, `Terminal`, and `RoleZero`
itself (publishing `ask_human`/`reply_to_human` as commands the model can call).

One-line framing: **Action = a step the framework can schedule; Tool = a capability the
model can name.** Post-`RoleZero`, scheduling is the model's job, so Actions decayed into
provenance tags and Tool became the live abstraction.

### Why not native function calling

Not documented; the reasons are legible from the code **(inference)**: ~30 providers
behind a `str`-returning `aask` and all of them can emit text; the batch-plus-interleaved-
thought shape they wanted; a Python-signature-plus-prose schema that wouldn't round-trip
through JSON Schema without loss; and a code-as-action lineage where the "call" is
arbitrary Python. Native function calling *is* present but vestigial:
`metagpt/provider/constant.py` defines exactly one schema, `GENERAL_FUNCTION_SCHEMA`
(a single `execute(language, code)` with forced `tool_choice`, credited to
open-interpreter), used by one non-test caller in the whole repo.

### Anti-loop machinery

Distinctive, and rarely found in other harnesses at this level of explicitness:

- `check_duplicates` compares the raw response against the last 10. Exact repeat → inject
  `REGENERATE_PROMPT` and re-ask. Third repeat → either force-substitute a synthetic
  `END_COMMAND`, or **synthesize an `RoleZero.ask_human` command** — escalate to the
  human as a loop-breaker.
- `_quick_think` runs *before* the tool loop, classifying the request as
  QUICK / SEARCH / TASK / AMBIGUOUS and answering directly for the first three, skipping
  the harness entirely. (With a telling patch: if a "QUICK" answer contains the substring
  `"command_name"`, it is treated as a misclassified TASK, marked `FIXME`.)

## Context/Memory Management

### The unit is a routed Message, not a chat turn

```python
id: str
content: str                      # natural language, for user or agent
instruct_content: Optional[BaseModel]
role: str = "user"                # system / user / assistant
cause_by: str = ""
sent_from: str = ""
send_to: set[str] = {MESSAGE_ROUTE_TO_ALL}
metadata: Dict[str, Any] = {}
```

Two decisions here carry the whole design.

**Routing metadata is stringified class paths.** Validators run `any_to_str` on
assignment and `__setattr__` is overridden so later mutation coerces too. Cheap to index,
serialize, and compare; no import needed to subscribe.

**`instruct_content` is a structured side channel that never reaches the LLM.**
`to_dict()` returns only `{"role", "content"}`; `rag_key()` returns `content`. So
`instruct_content` — a dynamically-created Pydantic model — is machine-readable
inter-agent payload that costs *zero context tokens* unless someone explicitly renders it.
This is the substrate for the artifact strategy below, and it is the single cleanest idea
in MetaGPT's memory design.

### One index, by `cause_by`

`Memory` is a list plus exactly one index:

```python
storage: list[Message] = []
index: DefaultDict[str, list[Message]] = defaultdict(list)
```

`get_by_actions(actions)` unions index buckets; `get(k)` returns `storage[-k:]`.
Everything else (`get_by_role`, `get_by_content`, `try_remember`) is an O(n) scan. The
reasoning is visible: an SOP agent asks exactly two questions — *what happened recently*
and *what came out of the upstream action I'm waiting on* — so those two get support and
nothing else does.

### Per-role isolation is the default; the global log is "for debug"

Each role owns three stores plus an inbox:

- `msg_buffer: MessageQueue` — asyncio-backed inbox, `exclude=True` from serialization.
  The RFC-116 note in the module docstring is emphatic that this was *moved* out of the
  global env into the role.
- `memory: Memory` — private persistent memory.
- `working_memory: Memory` — scratch, discarded per task.

`Environment.history: Memory` exists, but the field comment is literally `# For debug`
and nothing reads it back into a prompt. **There is no shared context window.** The
paper's "shared message pool" is, in the implementation, a pub/sub bus over isolated
per-role stores. That distinction matters for anyone reading the paper and expecting a
blackboard.

### `_observe` is where context is actually controlled

```python
self.rc.news = [
    n for n in news if (n.cause_by in self.rc.watch or self.name in n.send_to)
                    and n not in old_messages
]
```

By default only the filtered news is written to memory — a role's memory contains only
what it subscribed to. `observe_all_msg_from_buffer` flips this to store everything with
the comment *"the role may not react to them but can be aware of them"*, making
**awareness vs. reaction an explicit dial**. `RoleZero` sets it `True`.

The decision worth naming: **context membership is decided at intake by a subscription
predicate, not at prompt-assembly time by relevance scoring.** Everything downstream
(the fixed 200-message window, the emergency token truncation) is cheap because the
intake filter already did the work.

### Two long-term memories with opposite purposes

**(a) `LongTermMemory` — a novelty filter.** Adds only watched messages to a FAISS store,
and `find_news` uses similarity to *drop* anything already seen: *"filter out messages
similar to those seen previously in ltm, only keep fresh news."* The embedding index
suppresses redundant work across restarts rather than injecting context.

**(b) `RoleZeroLongTermMemory` — an overflow spillway.** Short-term capacity is
`memory_k = 200`; on `add`, the message falling out of the recency window is pushed into
Chroma. "What becomes long-term" is decided purely by age-out — no scoring, no
summarization.

Retrieval is deliberately gated to three conditions:

```python
conds = [k != 0,
         self._is_last_message_from_user_requirement(),
         self.count() > self.memory_k]
```

The middle one means RAG fires **only at the top of a new user request**, never per step.
Retrieved items are re-sorted by `created_at` and *prepended*, so recalled history sits
chronologically before the recent window rather than interleaved. `similarity_top_k = 5`.
Both add and fetch are wrapped in `@handle_exception` — memory is best-effort and never
allowed to break a run. `enable_longterm_memory` defaults to **False**.

### Compression: three unrelated mechanisms, no unified budget

1. **Provider-level truncation** (`base_llm.compress_messages`) — `CompressType` offers
   pre/post cut by message or by token, default `NO_COMPRESS`. Budget is
   `TOKEN_MAX[model] * 0.8` (*"Reserve 20% of the token limit for completion"*). System
   messages are always kept, with the honest comment *"NOTE: Assume they do not exceed
   token limit"*. The base token counter is `len(content) * 0.5`, self-described as
   *"a huge overestimate for English text... should be overwritten"*.
2. **Fixed-window recency** — the actual working strategy. `memory_k = 200` messages. No
   token math.
3. **LLM summarization at boundaries** — `RoleZero.use_summary` (default True) summarizes
   at end of run; `BrainMemory` does the classic swap (`historical_summary = summary;
   history = []`) with Redis persistence and a 30-minute TTL. A fourth approach lives in
   `utils/text.py:reduce_message_length`: take a *generator of progressively shorter valid
   prompts* and pick the first that fits — degrade the prompt by design rather than by
   slicing.

Honest reading: there is no coherent token budget. There is an intake filter, a message
count, and an emergency truncator whose own comments admit it is inaccurate.

### The experience pool: cross-run learning as a scored cache

`metagpt/exp_pool/` is distinct from memory — memory is within-run, exp_pool is across
runs and processes. An `Experience` is `req`, `resp`, an optional `Metric` (time cost,
money cost, LLM-assigned `Score{val 1-10, reason}`), `exp_type ∈ {success, failure,
insight}`, and an aspirational `Trajectory` (plan/action/observation/reward).

The `@exp_cache` decorator's flow: fetch experiences → if a *perfect* one exists (exact
request match at score 10), **return it without calling the LLM at all** → else execute →
LLM-score the response → store. It is simultaneously a semantic cache and a few-shot
retrieval mechanism. When the match isn't perfect, retrieved experiences are injected by
**placeholder substitution** — `RoleZeroContextBuilder` replaces `EXPERIENCE_MASK` in the
prompt template rather than appending, so experiences land in a designated slot.

`similarity_top_k = 2` — deliberately tiny. And `RoleZeroSerializer._is_useful_content`,
which decides what of the prompt gets embedded, is startlingly narrow:

```python
if "Command Editor.read executed: file_path" in content:
    return True
return False
```

with the rationale that `req` "may be very lengthy and could cause embedding errors." The
pool stores a filtered *projection* of the prompt, not the prompt. All flags
(`enabled`/`enable_read`/`enable_write`) default False.

### Artifacts on the filesystem; messages carry filenames

The strongest context idea in the repo, and it is structural rather than in the memory
module. `Document` is `root_path + filename + content`, with `get_meta()` returning a
content-free copy — a handle. `ProjectRepo` is a git-backed tree of typed
`FileRepository`s (`docs/prd`, `docs/system_design`, `docs/task`, `docs/code_summary`,
`tests/`, srcs).

The inter-role protocol is then: write the artifact, publish a message with **empty
content** and paths in `instruct_content`:

```python
return AIMessage(
    content="",
    instruct_content=AIMessage.create_instruct_value(
        kvs={"project_path": ..., "requirements_filename": ...,
             "prd_filenames": [...]},
        class_name="PrepareDocumentsOutput"),
    cause_by=self, send_to=self.send_to)
```

The receiver does `self.input_args = with_messages[-1].instruct_content` and lazily loads
only what it needs. **PRDs, designs, and code never travel through anyone's message
history — only paths do.** `FileRepository.save(..., dependencies=[...])` additionally
records an artifact dependency graph, and `changed_dependency_files` computes what needs
regenerating: incremental recompute over the filesystem rather than over conversation
state. Because the repo is git-backed, artifact history is versioned outside memory
entirely.

### Persistence

`SerializationMixin` gives every `Role` (and `Team`) snapshot/restore to
`./workspace/storage/`. `MessageQueue.dump()` drains and re-pushes the asyncio queue.
Transient wiring (`msg_buffer`, `todo`, `news`, `env`) is `exclude=True`; `memory` and
`working_memory` persist. With `recovered` / `latest_observed_msg`, this gives
resume-from-snapshot at **message granularity** — `metagpt --recover-path`.

## Sandboxing & Permissions

**There is essentially no sandbox.** This needs to be stated plainly, because MetaGPT is
a code-writing, code-executing, package-installing agent framework and a reader could
reasonably assume otherwise.

Generated code executes as the same OS user, on the same filesystem, with the same
environment as the agent process. There is no capability model, no security-relevant
allowlist or denylist, no path confinement, and no pre-execution approval gate. Grepping
the tree for `sandbox|isolat|untrusted` returns only `--no-sandbox` Chromium flags and
`flake8 --isolated`.

Four execution backends, none isolated from the host:

**(a) `subprocess` for the SOP pipeline** — `RunCode.run_script` spawns
`subprocess.Popen(command, cwd=working_directory, env=self.context.new_environ())`, i.e.
a copy of the ambient environment including API keys. Before running anything it calls
`_install_dependencies`, which does `python -m pip install -r requirements.txt` from an
**LLM-authored `requirements.txt`**. The agent can cause arbitrary package installation
into the ambient Python environment as a side effect of "running the tests." Timeout: 10
seconds.

**(b) `exec()` in-process** — `RunCode.run_text`:

```python
namespace = {}
exec(code, namespace)
```

LLM-generated code running inside the MetaGPT process, with access to the interpreter,
loaded config objects, and credentials. This is the sharpest single citation for "no
sandbox."

**(c) A local Jupyter kernel** — `ExecuteNbCode` starts `nbclient`'s kernel with
`resources={"metadata": {"path": workspace.path}}`. A *process* boundary, not a security
boundary: same user, same environment. It buys a 600s timeout, `DeadKernelError`
recovery, and cross-turn state (dataframes, imports survive). Treat it as durability, not
isolation.

**(d) A persistent interactive shell** — `Terminal` keeps a long-lived `bash` via
`asyncio.create_subprocess_exec(..., env=os.environ.copy(), cwd=DEFAULT_WORKSPACE_ROOT)`
and writes the model's string into its stdin. `cwd` is the workspace *only at start*; the
shell is stateful, so any `cd /` permanently escapes it. `shell.py::shell_execute` runs
`subprocess.run(command, shell=True)` for string commands.

The only denylist is a UX nudge:

```python
self.forbidden_commands = {
    "run dev": "Use Deployer.deploy_to_public instead.",
    "serve ": "Use Deployer.deploy_to_public instead.",
}
```

— substring-matched, trivially bypassed, and there to stop the agent from starting a
blocking dev server. `exclusive_tool_commands` is deduplication, not authorization.

**Workspace confinement is a default directory, not a boundary.** `WorkspaceConfig.path`
is `mkdir`'d and used as an initial `cwd`; `Editor.read/write/create_file` take absolute
paths and call `.resolve()` for display only. There is no `is_relative_to(working_dir)`
check anywhere.

`SECURITY.md` is three lines: every version marked unsupported, plus a contact email. No
threat model, no "run generated code in a container" warning. The `Dockerfile` is a
*packaging* image — runs as root, ends `CMD tail -f /dev/null` for `docker exec`, and the
documented `docker run` bind-mounts the host workspace in. It reduces blast radius if you
use it; nothing checks that you did.

### Human-in-the-loop: present, post-hoc, and off by default

`AskReview` prompts on the console (`confirm/change …/exit`, where `exit` calls `exit()`).
It fires only from `Planner.ask_review`, only when `auto_run` is false — and the docstring
is explicit that it runs *after* execution:

> If human confirms the task result, then we deem the task completed, regardless of
> whether the code run succeeds; if auto mode, then the code run has to succeed for the
> task to be considered completed.

A post-hoc plan-acceptance gate, not a pre-execution approval. `DataInterpreter.auto_run`
defaults `True`; `RoleZero` hardcodes `Planner(..., auto_run=True)`. In the default
configuration **the human is never asked**. (A commented-out block in
`data_interpreter.py:144` shows an intended "ask a human after max_retry failures" path
that was disabled.)

The other two human seams are different constructs and worth distinguishing:
`RoleZero.ask_human` is *model-initiated* (the agent decides it is stuck — and the
anti-loop machinery can synthesize this call on its behalf); `Role.is_human = True` swaps
the role's LLM for `HumanProvider`, i.e. **a human occupies an agent seat**. That last one
is a genuinely elegant piece of factoring: the human is a provider implementing the same
`aask` interface, so no control-flow branch is needed anywhere.

### The executable feedback loop

The paper's headline mechanism, measured at +4.2% Pass@1 on HumanEval and +5.4% on MBPP.
Two implementations with different shapes.

**SOP loop (Engineer ↔ QaEngineer), message-passing, 5 rounds.** `QaEngineer._act`
dispatches on the `cause_by` of incoming news: `SummarizeCode → _write_test`,
`{WriteTest, DebugError} → _run_code`, `RunCode → _debug_error`. Each pass increments
`test_round`; hard stop at `test_round_allowed = 5`.

Two decisions stand out:

*Triage is done by the LLM, not by exit code.* `RunCode.run` never inspects a return
code. It formats dev code + test code + command + stdout + stderr and asks the model for
three fields: `## Status:` (`PASS`/`FAIL`, "WRITE ONLY ONE WORD"), `## File To Rewrite:`,
and `## Send To:` (`NoOne`/`Engineer`/`QaEngineer`). That last word is parsed by
`parse_recipient` and turned into a real message route — **"whose fault is this bug" is a
routing decision delegated to a one-word LLM answer**, and a parse failure silently
degrades to no recipient.

*Truncation is asymmetric and deliberate:* `outs[:500]` (with the comment "outs might be
long but they are not important") versus `errs[:10000]`.

`DebugError` short-circuits before spending a call by regexing unittest's success banner
out of stderr (`r"Ran (\d+) tests in ([\d.]+)s\n\nOK"`). Feedback reaches the Engineer
not through a call graph but through a *file*: `RunCodeResult` is persisted as JSON in
`repo.test_outputs` keyed by test filename, and `WriteCode.run` loads it and splices
`test_detail.stderr` into a `## Debug logs` prompt slot. The two roles are coupled only
through the repo.

**Data Interpreter loop, in-process, 3 retries with gated reflection.**

```python
while not success and counter < max_retry:      # max_retry = 3, hardcoded
    code, cause_by = await self._write_code(counter, plan_status, tool_info)
    self.working_memory.add(Message(content=code, role="assistant", cause_by=cause_by))
    result, success = await self.execute_code.run(code)
    self.working_memory.add(Message(content=result, role="user", cause_by=ExecuteNbCode))
    counter += 1
```

The working-memory discipline is the point: code enters as `assistant`, output as `user`.
**The failure transcript is the conversation.** Reflection is enabled only from the second
attempt (`use_reflection = counter > 0 and self.use_reflection`) — attempt 1 is a plain
retry-with-error-in-context; attempts 2–3 add a structured `[reflection on previous
impl]` → `[improved impl]` pass with a hand-written one-shot example. Don't pay for
structured self-critique on the first attempt.

Output processing (`parse_outputs`) carries several ideas worth stealing outright:

```python
# The useful information of the exception is at the end,
# the useful information of normal output is at the begining.
output_text = output_text[:keep_len] if is_success else output_text[-keep_len:]
```

Plus: strip ANSI escapes; **drop MetaGPT's own log lines** from captured output so the
agent doesn't read the harness's logs as program output; force `success = False` when
`"!pip" in code` and keep only the last 500 chars (a deliberate nudge away from installs);
head-500 + tail-500 for `git clone`; and replace a timeout with coaching prose
("consider optimizing your code for better performance") rather than a raw error.

**Budgets are scattered**, which is a real weakness: `test_round_allowed = 5` (role
field), `code_validate_k_times = 2` (config, and gated behind `use_code_review = False`),
`max_auto_summarize_code = 0` (config — the summarize→rewrite loop is *disabled by
default*), `max_retry = 3` (hardcoded default arg), `stop_after_attempt(6)` (tenacity
transport retry), `max_react_loop` (40–50), `n_round` (5), and a dollar budget. There is
no single place to reason about total work.

## Notable Design Decisions

1. **`Code = SOP(Team)`.** The procedure, not the conversation, is the artifact. The
   paper's argument is that encoding human workflow structure suppresses cascading
   hallucination. This is the thesis every other decision serves.

2. **The SOP was subsequently demoted to `use_fixed_sop: bool = False`.** The most
   informative fact in the repo. The team that argued hardest for encoded procedure
   replaced it, in production, with LLM-routed generalist tool-users. The paper's roles
   survive as *names, goals, and tool lists* on `RoleZero` subclasses — role
   specialization outlived role *sequencing*.

3. **Structured artifacts over dialogue.** Agents exchange PRDs, design docs, and file
   paths, not chat. The paper's stated target is "idle chatter like 'Hi, hello and how are
   you?'" Mechanized by `ActionNode` (one declaration compiled to instruction, example,
   and validator) and by `instruct_content` (a typed side channel invisible to the LLM).

4. **Subscription by stringified action identity.** `_watch({WritePRD})` — the pipeline is
   emergent from per-role subscriptions, never materialized as a graph. Cheap to extend;
   impossible to inspect.

5. **Artifacts live on the filesystem; messages carry handles.** Content-free messages
   with paths in `instruct_content`, against a git-backed typed repo with a recorded
   dependency graph. The cleanest context-management idea here, and it is architectural
   rather than a memory-module feature.

6. **Budget denominated in dollars.** `Team.invest(3.0)`, `NoMoneyException` mid-run,
   `--investment` as a CLI verb.

7. **Human as an LLM provider.** `Role.is_human = True` swaps in `HumanProvider`
   implementing the same `aask` interface. No control-flow branch anywhere; a human simply
   occupies an agent seat.

8. **Delegation is a tool call, and it blocks.** `TeamLeader.publish_team_message` is
   `@register_tool`-registered and calls `_set_state(-1)` to pause pending the reply.
   Multi-agent coordination reuses the command protocol rather than adding a channel.

9. **The docstring is the schema.** No JSON Schema anywhere; Python signature string plus
   raw Google-style docstring text, extracted by either `inspect` or an AST visitor.
   Permissive by design.

10. **A batch JSON command protocol, not native function calling.** Bought provider
    portability across ~30 backends and interleaved thought; paid for with a six-stage
    repair funnel that includes an extra LLM call.

11. **Retrieval built, then switched off in the dispatch path.** `force=True` dumps the
    whole curated tool list every turn. Retrieval was kept only for code-generation
    context.

12. **RAG gated to request boundaries.** Long-term memory fires only when the last message
    is a fresh user requirement — never per step. Avoids per-step retrieval churn.

13. **Explicit anti-loop machinery**, up to and including *synthesizing an `ask_human`
    call* when the model repeats itself three times.

14. **A pre-loop `_quick_think` router** that answers simple requests without entering the
    harness at all.

15. **Execution feedback truncated by direction of usefulness** — head for success, tail
    for failure — and the harness's own log lines stripped from captured output.

16. **No sandbox, no permission model, `exec()` in-process, and pip-install from
    LLM-authored requirements.** The permission model is implicit trust in the LLM. Stated
    here as a decision because it evidently was one: `SECURITY.md` declines to discuss it.

## Relevance to Crescent

Crescent's current state: `lib/ai/tools.lua` is a 79-line loop (`mod.run`) calling
`ai.generate`, dispatching native tool calls through a `handlers` table keyed by name,
`pcall`ing each handler, JSON-encoding non-string returns, appending `role="tool"`
messages, and bailing with `"max rounds exceeded"` after `max_rounds` (default 10).
`lib/ai/types.lua` defines a provider-neutral `ai_message`/`ai_tool`/`ai_tool_call`.
`lib/taskgraph` provides a typed task graph (`TaskDef`/`TaskNode`/`Graph`, spawn +
dependencies, frontier and exec-graph tracking).

**Where crescent is already past MetaGPT.**

- *Native tool calls with correlation ids.* `ai_tool_call` carries `id`, and results go
  back as `role="tool"` with `tool_call_id`. MetaGPT has neither, and pays for it: its
  `"Command X executed: …"` prose is parsed by regex downstream, making the transcript
  format an undeclared API. Crescent should not acquire a text command protocol.
- *A real task graph.* MetaGPT's pipeline exists only as scattered `_watch` string sets;
  `lib/taskgraph` already materializes what MetaGPT never did. If crescent wants
  SOP-shaped pipelines, it can express them as graphs that can be validated and inspected.
- *Caps-first.* MetaGPT's tools hold ambient process authority — `os.environ.copy()` into
  a shell, `exec()` in-process, pip-install from generated files. Crescent's caps rule
  makes every one of those an injected-capability decision at design time. This survey
  offers no reason to relax it and several to keep it.

**Directly transferable, low cost:**

- *Truncate by direction of usefulness.* Success → head; failure → tail. One line,
  measurable benefit, no substrate needed.
- *Strip the harness's own log lines from captured tool output* before it reaches the
  model.
- *Reflection gated on retry count.* First failure → plain retry with the error in
  context; later failures → a structured critique pass. Cheaper than always-reflect.
- *An `end`-style explicit termination command*, distinct from "no tool calls emitted".
- *Repeat detection.* Comparing the last N raw responses and escalating to a human on
  repetition is ~20 lines and addresses a failure mode `max_rounds` only papers over.
- *Distinguish "unknown tool" (a harness bug) from "tool raised" (a data error).*
  `tools.lua` currently renders both as `'{"error": ...}'` strings the model cannot tell
  apart — and MetaGPT makes exactly the same conflation, so this is a shared gap, not a
  borrowed fix.

**Ideas that need substrate, and should be scheduled as substrate:**

- *Artifacts on the filesystem, handles in messages.* MetaGPT's strongest context idea.
  For crescent this needs: a typed artifact-repo abstraction, a message type with a
  structured non-LLM-visible field (MetaGPT's `instruct_content`), and a decision about
  whether artifacts are git-backed. All three are substrate; none should be improvised
  inside an agent app.
- *Context membership decided at intake, not at assembly.* MetaGPT's `_observe`
  subscription predicate is why its prompt assembly can be as crude as "last 200
  messages". If crescent wants that simplicity downstream, the filter has to exist
  upstream — substrate before consumers.
- *Cross-run experience reuse.* The `@exp_cache` shape (perfect-match short-circuits the
  LLM entirely; imperfect matches inject into a designated prompt slot) is portable. Its
  storage substrate is not: MetaGPT assumes Chroma/FAISS and an embedding API, neither
  available to a zero-dependency Lua runtime. The retrieval substrate must be decided
  before any memory API is designed.

**Explicitly rejectable:**

- *Text command protocol with a repair funnel.* Six stages including an extra LLM call, to
  recover from a problem native tool calls do not have.
- *LLM keyword parsing as control flow.* `"PASS"`, `"LGTM"`, a bare integer for state
  selection, and a one-word `Send To:` deciding message routing. Crescent has a type
  system; control flow should not be decided by substring search on model prose.
- *Scattered budgets.* Seven-plus independent limits with no place to reason about total
  work. A single accounted budget object is cheaper to design now than to retrofit.
- *Dollar-denominated budget as the only budget* — though dollar accounting *alongside*
  step/token budgets is a genuinely good idea worth keeping.

**Open questions this survey surfaces but does not settle** (each affects semantics and
needs an explicit decision):

1. Does the agent app get role specialization at all? MetaGPT's evolution says role
   *sequencing* did not survive contact with reality but role *identity* (name, goal, tool
   subset) did. Whether crescent wants either is undecided.
2. If multiple agents: is coordination a hub (MGX's TeamLeader routes everything) or a
   bus (the paper's subscription model)? These have different failure modes and the choice
   is not implied by anything already in the repo.
3. Is delegation blocking (MetaGPT's `_set_state(-1)`) or concurrent? `lib/taskgraph`
   supports the latter; MetaGPT chose the former deliberately.
4. Does `lib/ai` grow a memory layer, and on what retrieval substrate given
   zero-dependency and no embedding API?
5. Is per-role tool scoping (`"Terminal:run_command"`-style method subsets) a prompt-economy
   feature, a capability boundary, or both? MetaGPT treats it as the first only; crescent's
   caps-first rule makes the second available, and conflating them silently would be a
   mistake.
6. Human-in-the-loop: pre-execution gate, post-hoc acceptance (MetaGPT's choice), or
   model-initiated escalation only? MetaGPT ships all three constructs and defaults to
   asking nobody.
7. Does the agent app run generated code at all, and if so behind which caps? Everything
   MetaGPT does here is a demonstration of what not to inherit by omission.

## Sources

- [geekan/MetaGPT on GitHub](https://github.com/geekan/MetaGPT) — README, `Code = SOP(Team)`
  framing, MGX/AFlow/SPO news. Redirects to `FoundationAgents/MetaGPT`; stats and MIT
  license read from the GitHub API.
- Shallow clone at commit `11cdf466` (2026-01-21) — all structural claims. Key files:
  `metagpt/roles/role.py`, `metagpt/team.py`, `metagpt/environment/base_env.py`,
  `metagpt/environment/mgx/mgx_env.py`, `metagpt/software_company.py`,
  `metagpt/roles/di/role_zero.py`, `metagpt/roles/di/team_leader.py`,
  `metagpt/roles/di/engineer2.py`, `metagpt/roles/{architect,product_manager,project_manager,engineer,qa_engineer}.py`,
  `metagpt/actions/action_node.py`, `metagpt/actions/write_prd_an.py`,
  `metagpt/actions/di/run_command.py`, `metagpt/strategy/{planner,task_type}.py`,
  `metagpt/schema.py`, `metagpt/memory/*.py`, `metagpt/exp_pool/*`,
  `metagpt/tools/{tool_registry,tool_convert,tool_recommend}.py`,
  `metagpt/utils/{role_zero_utils,repair_llm_raw_output,parse_docstring,project_repo}.py`,
  `metagpt/actions/{run_code,debug_error,write_code,summarize_code}.py`,
  `metagpt/actions/di/{execute_nb_code,ask_review,write_analysis_code}.py`,
  `metagpt/tools/libs/{terminal,editor,shell}.py`, `metagpt/prompts/di/role_zero.py`,
  `metagpt/config2.py`, `metagpt/configs/*`, `SECURITY.md`, `Dockerfile`.
- [MetaGPT: Meta Programming for A Multi-Agent Collaborative Framework (arXiv 2308.00352)](https://arxiv.org/abs/2308.00352)
  — ICLR 2024 oral. Read via [ar5iv HTML](https://ar5iv.labs.arxiv.org/html/2308.00352):
  shared message pool + publish-subscribe motivation, structured communication interfaces,
  role profile/goal/constraints, observe-think-act, short/long-term memory split,
  HumanEval 85.9% / MBPP 87.7% Pass@1, SoftwareDev benchmark, "idle chatter" quote.
- [ICLR 2024 proceedings entry](https://proceedings.iclr.cc/paper_files/paper/2024/hash/6507b115562bb0a305f1958ccc87355a-Abstract-Conference.html)
  and [OpenReview forum](https://openreview.net/forum?id=VtmBAGCN7o).
- Executable-feedback ablation figures (+4.2% HumanEval, +5.4% MBPP) and the
  "references non-existent resource files" limitation: located via web search over the
  paper text; **not independently verified against the PDF** (both PDF fetches exceeded the
  fetch size limit).
- [AFlow (ICLR 2025 oral)](https://openreview.net/forum?id=z5uVAKwmjf), [SPO](https://arxiv.org/pdf/2502.06855),
  [AOT](https://arxiv.org/pdf/2502.12018), [SELA](https://arxiv.org/abs/2410.17238) — the
  in-tree `metagpt/ext/` research lineage.
- Crescent files read for the relevance section: `lib/ai/tools.lua`, `lib/ai/types.lua`,
  `lib/ai/init.lua`, `lib/taskgraph/init.lua`, `lib/taskgraph/taskgraph_types.lua`.
