# Prior art survey: Letta / MemGPT (letta-ai/letta)

Survey date: 2026-08-02. Sourcing convention used throughout: claims marked
**[src]** were read from a shallow clone of `github.com/letta-ai/letta` at
survey date; claims marked **[doc]** come from `docs.letta.com`; claims marked
**[paper]** come from the MemGPT paper (arXiv 2310.08560) read via its ar5iv
HTML rendering; claims marked **[2nd]** are secondary and unverified against
source.

## Overview

Letta (formerly MemGPT) is a Python platform for *stateful* agents — its
one-line pitch is "AI with advanced memory that can learn and self-improve over
time." Apache-2.0, ~24.1k stars, ~7.5k commits at survey time. [src README]

Its provenance is academic, not product-first: it began as the reference
implementation of the MemGPT paper (UC Berkeley, Oct 2023), which proposed
treating the LLM context window as a *paged virtual memory* managed by an
OS-like supervisor. The company productized that research into a server, and
the paper's abstractions (core/recall/archival memory, heartbeats, recursive
summarization) survive nearly intact in today's code. [paper] [src]

An important structural note before anything else: the surveyed repo is
explicitly labelled **legacy**. The README states "This repository contains the
legacy Letta server (the API server behind the Letta V1 API and SDKs). Active
development has moved to the Letta Agent repo (`letta-ai/letta-code`)," a
TypeScript CLI/SDK, with self-hosting now via an "App Server." [src README] So
this survey documents a mature, fully-realized-then-superseded design — which is
arguably *more* useful as prior art than a moving target, but the newest
decisions (skills, subagents, MemFS) are only partially visible here.

The single decision that defines Letta and separates it from every other harness
in this survey series: **the agent is a database row, not a process.** Agent
state — messages, memory blocks, tool attachments, LLM config — lives in
Postgres and is reconstructed per step. There is no long-lived in-memory
conversation object, and no "session file" that a CLI owns. Everything else
(multi-agent via shared memory rows, sleep-time agents, resumability) falls out
of that choice.

## Architecture

**Server-first, not CLI-first.** Letta is a REST service (`letta/server/`) with
ORM-backed persistence (`letta/orm/`, Alembic migrations in `alembic/`) plus
observability wiring (`letta/otel/`, ClickHouse trace backends). Clients — CLI,
SDKs, desktop — are thin. Contrast with Aider/Codex-CLI-style harnesses where
the agent *is* the local process. [src]

**Agent-state reconstruction per step.** Each step recompiles the system prompt
from persisted memory blocks rather than mutating an in-memory transcript. The
compilation path is `PromptGenerator.get_system_message_from_compiled_memory` →
injects a reserved `CORE_MEMORY` variable into the base system prompt, and if
the prompt template lacks the variable, appends it rather than failing.
[src `letta/prompts/prompt_generator.py`]

**Versioned agent loops living side by side.** `letta/agents/` contains
`letta_agent.py`, `letta_agent_v2.py`, `letta_agent_v3.py` (2134 lines),
`ephemeral_agent.py`, `ephemeral_summary_agent.py`, `voice_agent.py`,
`voice_sleeptime_agent.py`, `letta_agent_batch.py`, with dispatch through
`agent_loop.py`. Loop semantics are versioned rather than migrated — old agents
keep old control flow. This is a deliberate compatibility decision with an
obvious cost: several concurrent definitions of "what a step means." [src]

**Control flow, v3 (`_decide_continuation`, letta_agent_v3.py:1967):** the rule
is stated in a docstring as: *no tool call → loop ends; tool call → loop
continues*, including when the tool failed or when a tool rule was violated
(a violation still continues, with a `ToolRuleViolated:` feedback message
injected). Terminal tool rules stop the loop; child/continue rules force
continuation; `is_final_step` is a hard stop emitting `max_steps`;
`finish_reason == "length"` maps to `max_tokens_exceeded`. Uncalled
`required_before_exit` tools override an otherwise-ending turn and re-enter the
loop with an explicit instruction naming the missing tools. [src]

Note this is a *migration* in loop philosophy: MemGPT's original design ended
the loop unless the model explicitly opted in via `request_heartbeat=True`
[paper], whereas v3 continues by default and ends when the model stops calling
tools — v3's `_get_valid_tools` passes `request_heartbeat=False` with the
comment "NOTE: difference for v3 (don't add request heartbeat)". The v1 system
prompt now says plainly: "To continue: call another tool. To yield control: end
your response without calling a tool." [src `system_prompts/letta_v1.py`]

**Event-driven framing.** The original design frames the agent as run by an
event system — user events, timed heartbeat events, self-requested heartbeats —
rather than as a request/response function. The `memgpt_chat` system prompt
teaches the model this explicitly: "your brain is not continuously thinking, but
is run in short bursts... Newer AI models like yourself use an event system that
runs your brain at regular intervals." [src `system_prompts/memgpt_chat.py`]

## Tool-Calling Protocol

**Tools are native provider tool calls, with a synthetic parameter injected.**
The distinctive MemGPT-era addition is `request_heartbeat`, appended to every
tool schema, described to the model as: "Request an immediate heartbeat after
function execution. You MUST set this value to `True` if you want to send a
follow-up message or run a follow-up tool call (chain multiple tools together).
If set to `False` (the default), then the chain of execution will end
immediately after this function call."
[src `letta/constants.py:217-218`] Setting it inserts
`REQ_HEARTBEAT_MESSAGE = "Function called using request_heartbeat=true,
returning control"` into context; a failed call inserts
`FUNC_FAILED_HEARTBEAT_MESSAGE`, so a failure also re-enters the loop rather
than terminating it. [src `letta/constants.py:452-455`] The decision here is
that *continuation is a tool argument* — the model declares intent to keep
going in the same call that does the work, rather than the harness inferring it.

**No user-visible output except via a tool.** `send_message` is the only channel
to the user; assistant text is treated as private "inner monologue" (capped in
the prompt at 50 words). "'send_message' is the ONLY action that sends a
notification to the user. The user does not see anything else you do."
[src `system_prompts/memgpt_chat.py`] This makes reasoning and user-facing
speech structurally distinct message types rather than a rendering convention —
the same information other harnesses recover by parsing `<thinking>` tags.

**Tool schemas are generated from Python source, and the docstring format is
enforced.** `letta/functions/schema_generator.py` uses `docstring_parser` and
`validate_google_style_docstring`, which *raises* if a function has no
docstring, or has parameters but no `Args:` section, or has an undocumented
parameter. Schema descriptions come from the docstring; types from the Python
annotations. There is also `typescript_parser.py` for TS tools. The decision:
the tool definition has exactly one source of truth (the function), and
under-documented tools are a hard error rather than a degraded schema. [src]

**Tool rules: a declarative constraint DSL over the tool namespace.**
`letta/schemas/tool_rule.py` (373 lines) defines nine rule types, discriminated
union, each implementing
`get_valid_tools(tool_call_history, available_tools, last_function_response) -> set[str]`
plus `render_prompt()` and a `requires_force_tool_call` property: [src]

- `InitToolRule` (`run_first`) — plus optional prefilled `args` that override
  LLM-provided values.
- `ChildToolRule` (`constrain_child_tools`) — after tool X, only these tools;
  `child_arg_nodes` can prefill a chosen child's arguments.
- `ParentToolRule` (`parent_last_tool`) — children are *removed* from the
  available set unless the parent was just called.
- `ConditionalToolRule` — maps the tool's *output value* to the next tool, with
  `require_output_mapping` toggling strict mode (unmatched output → empty
  tool set) versus fallback to `default_child`.
- `TerminalToolRule` (`exit_loop`), `ContinueToolRule` (`continue_loop`).
- `RequiredBeforeExitToolRule` — cannot end the turn until called.
- `MaxCountPerStepToolRule` — budget per step.
- `RequiresApprovalToolRule` — human-in-the-loop gate.

Enforcement is dual: the allowed set is applied to the *request* (only permitted
schemas are sent, and `requires_force_tool_call` forces tool use), and each rule
renders a `<tool_rule>...</tool_rule>` line into the prompt. So constraints are
both mechanically enforced and explained to the model. Rendering is noted as
"fast built-in formatting for performance" with user `prompt_template` fields
explicitly *ignored* — a decision to close a customization surface for speed.
[src]

**Client tools override server tools by name.** In `_get_valid_tools`, server
tools whose names collide with client-provided tools are filtered out. MCP tools
are first-class (`letta/services/mcp/`, `mcp_tool_executor.py`), alongside
`builtin`, `core`, `files`, `composio`, and `sandbox` executors. [src]

## Context/Memory Management

This is the project's core contribution and the reason to survey it.

### The OS analogy, stated precisely

MemGPT's thesis: an LLM's fixed context window is *physical memory*, and an
LLM-driven supervisor can provide the illusion of unbounded memory by paging
data between the context window and external stores — with the crucial twist
that **the pager is the LLM itself, calling tools.** There is no learned or
heuristic eviction policy for what matters; the model decides what to promote
into the always-visible region and what to leave in searchable storage.
[paper]

### The tiers

**Main context** (what's in the prompt) is three regions: [paper]

1. **System instructions** — read-only, static; contains the control-flow and
   memory-usage rules quoted above.
2. **Working context / core memory** — fixed-size read-write block for persona,
   user facts, key state.
3. **FIFO queue** — rolling message history, with the recursive summary of all
   evicted messages pinned at the first index.

**External context** is two stores: [paper] [src]

- **Recall storage** — every message ever sent/received, searchable
  (`conversation_search`).
- **Archival storage** — arbitrary-length text objects, vector-indexed via
  pgvector; `archival_memory_insert` / `archival_memory_search`, with tag
  support in the current code.

### Memory blocks: the productized form of working context

Letta generalized MemGPT's fixed `persona`/`human` blocks into arbitrary
labelled **memory blocks**, each with `label`, `description`, `value`, and a
character `limit`; rendered into the system prompt in XML-ish form and always
visible. [doc] The `description` field is itself load-bearing — it tells the
agent *when and how* to write to that block, making a block a small policy
object rather than a string. Blocks can be `read_only: true` (shared policy that
agents may read but not rewrite). [doc] Limits in code:
`CORE_MEMORY_PERSONA_CHAR_LIMIT = 20000`, `CORE_MEMORY_HUMAN_CHAR_LIMIT = 20000`,
`CORE_MEMORY_BLOCK_CHAR_LIMIT = 100000`,
`DEFAULT_CORE_MEMORY_SOURCE_CHAR_LIMIT = 50000`. [src `letta/constants.py`]

Block-editing tools have evolved through three generations, all still present in
`letta/functions/function_sets/base.py`: [src]

- v1: `core_memory_append`, `core_memory_replace`
- v2: `rethink_memory(new_memory, target_block_label)`
- v3: `memory_replace(label, old_string, new_string)`,
  `memory_insert(label, new_string, insert_line=-1)`,
  `memory_apply_patch(label, patch)`, `memory_rethink(label, new_memory)`,
  `memory_finish_edits()`

The v3 set is deliberately *editor-shaped* — exact-string replacement, line
insertion, patch application — the same interaction model as a code-editing
tool, applied to memory. The sleep-time prompt teaches the pairing explicitly:
"use your precise tools to make narrow edits... and you can use your `rethink`
tool to reorganize the entire memory block at a single time," and warns that
displayed line numbers are for viewing only and must never be passed to the
tools. [src `system_prompts/sleeptime_v2.py`]

### Telling the model what it *cannot* see

`PromptGenerator.compile_memory_metadata_block` injects a `<memory_metadata>`
section listing `AGENT_ID`, `CONVERSATION_ID`, when the prompt was last
recompiled, how many prior messages sit in recall memory, how many archival
memories exist, and the available archival tags. [src] This is a small but
sharp decision: out-of-context data is advertised *by count and tag* so the
model knows retrieval is worthwhile, instead of silently not existing. Note the
`archival_memory_size` line is omitted entirely when zero — no dead affordance.

### Eviction and recursive summarization

Paper-era policy: a queue manager warns the model at roughly **70%** of context
capacity by inserting `MESSAGE_SUMMARY_WARNING_STR` — a message telling the
agent to save anything important to memory *before* trimming happens — and at
100% flushes about 50% of the window, generating a new recursive summary from
(previous recursive summary + newly evicted messages). Evicted messages persist
indefinitely in recall storage. [paper] [src `letta/constants.py:412-419`]

Current code, `letta/services/summarizer/`: [src]

- Two modes (`SummarizationMode`): `STATIC_MESSAGE_BUFFER` and
  `PARTIAL_EVICT_MESSAGE_BUFFER`.
- Trigger: `SUMMARIZATION_TRIGGER_MULTIPLIER = 0.9` — "using instead of 1.0 to
  avoid 'too many tokens in prompt' fallbacks". `thresholds.py` documents that
  GPT-5-family models compact proactively at 90% because runs were observed
  hitting max-output-token errors near the 272k input window, explicitly
  "align[ing] GPT-5 behavior with the codex harness' proactive 90% compaction
  policy."
- Partial evict (`_partial_evict_buffer_summarization`) is documented as
  "Summarization as implemented in the original MemGPT loop, but using message
  count instead of token count." Default
  `partial_evict_summarizer_percentage = 0.30`: retain the last 30% of messages.
  Because index 0 must remain the system message and index 2 must be an
  assistant message for provider validity, it walks forward from the target
  index to the first `assistant` message and cuts there. The summary is
  persisted as a **`user`-role message at index 1** — not a system message.
  Notably this path *cannot* be made async: "we're waiting on the summary to
  inject it into the context window, unlike the version that writes it to a
  block."

The message-count-instead-of-token-count substitution is worth flagging as an
honest simplification the code itself labels.

### Sleep-time compute

The most consequential post-paper memory decision: memory reorganization is
moved **off the critical path** into a separate background agent with its own
system prompt and its own tools. `Letta-Sleeptime-Memory` "run[s] in the
background, organizing and maintaining the memories of an agent assistant who
chats with the user," edits blocks until they are "comprehensive, readable, and
up to date," is told to be selective ("Not every observation warrants a memory
edit... but also aim to have high recall"), and is instructed to write absolute
dates rather than relative ones ("do not write 'today' or 'recently'... because
the memory is persisted indefinitely"). [src `system_prompts/sleeptime_v2.py`]

Scheduling: `SleeptimeManager.sleeptime_agent_frequency` — the group manager
bumps a persisted `turns_counter` and fires background runs when
`turns_counter % frequency == 0` (or every turn when frequency is unset), with
an explicit skip when no response messages were produced.
[src `letta/groups/sleeptime_multi_agent_v4.py:132-165`] There are four
generations of this file (`_v1`..`_v4`) plus a voice variant.

### MemFS: memory as a git repository

Newest generation, present in `letta/services/memory_repo/`: memory blocks are
stored as markdown in a per-agent git repo, with `git_operations.py` shelling
out to `git` (`_run_git`), `block_markdown.py` for block↔markdown mapping,
`path_mapping.py`, and a `MemfsClient` whose `get_blocks_async` takes a **ref**
— i.e. memory is readable at an arbitrary commit. There is also a parallel
`block_manager_git.py` alongside `block_manager.py` in services. [src] The
decision: memory gets version control semantics (history, refs, diffs) for free
by reusing git rather than modelling revisions in the database.

## Sandboxing & Permissions

**Tool execution is sandboxed by pluggable backend, and the backend is a
persisted org-level config row**, not a process flag.
`letta/schemas/sandbox_config.py` defines a discriminated
`LocalSandboxConfig | E2BSandboxConfig | ModalSandboxConfig`; implementations
live in `letta/services/tool_sandbox/`: `local_sandbox.py`, `e2b_sandbox.py`,
`modal_sandbox.py` / `modal_sandbox_v2.py`, plus `modal_deployment_manager.py`,
`modal_version_manager.py`, `typescript_generator.py`, and `safe_pickle.py`.
[src]

- **Local**: subprocess-based, "Uses a subprocess for multi-core parallelism";
  `use_venv` defaults to **False**, meaning the default local mode runs tool
  code in the same environment. Optional venv creation with pip requirements
  installed per sandbox (`create_venv_for_local_sandbox`,
  `install_pip_requirements_for_sandbox`), keyed by a config fingerprint
  (`sandbox_config_fingerprint`) so environments are rebuilt when config
  changes. [src]
- **E2B**: Firecracker microVM per sandbox — separate kernel, hardware-level
  isolation. [2nd]
- **Modal**: gVisor-isolated containers, supports both `python` and
  `typescript` languages and npm requirements. [src schema] [2nd]

The honest reading: isolation is *outsourced*. Letta's own local sandbox is a
subprocess with an optional venv — a dependency-isolation mechanism, not a
security boundary — and real isolation means depending on a third-party cloud
sandbox provider. There is no capability model, no filesystem allowlist, no
per-tool permission scope in the local path.

**Permissions are approval-based, not capability-based.**
`RequiresApprovalToolRule` marks a tool as gated; the protocol is a distinct
message role. `letta_agent_v3.py` handles an `approval` role in the persisted
message stream, pairs an `approval_request` with an `approval_response`, filters
`tool_calls` down to `approved_tool_call_ids`, constructs `ToolCallDenial`
objects carrying a `reason` for denied calls, and treats an approval response
with all-empty lists as a malformed/corrupted payload error. [src:283, 973-1013]
Two decisions worth noting: denial carries a *reason string back to the model*
(so refusal is informative rather than an opaque failure), and because approval
is a persisted message role, an approval can be answered across process
restarts — it is durable state, not a blocked in-memory prompt.

Secrets: `letta/schemas/secret.py`, `sandbox_credentials_service.py`, and
per-sandbox environment variable injection (`sandbox_env_vars`,
`environment_variables.py`) keep tool credentials out of the agent's context.
[src]

## Multi-Agent Support

Two mechanisms, deliberately distinct.

**1. Explicit messaging tools** (`function_sets/multi_agent.py`): [src]

- `send_message_to_agent_and_wait_for_reply(message, other_agent_id)` —
  synchronous, returns the reply.
- `send_message_to_agent_async(message, other_agent_id)` — fire-and-forget.
- `send_message_to_agents_matching_tags(message, match_all, match_some)` —
  broadcast by *tag query* rather than by explicit ID list, so the recipient set
  is defined declaratively and can change without rewiring the sender.

**2. Shared memory blocks.** A block is a row; attaching the same `block_id` to
several agents makes it shared state, and an update by one agent is immediately
visible to all others — coordination without message passing. [doc] The docs
also name the failure mode plainly: concurrent `memory_rethink` on the same
block causes **lost updates**. [doc] There is no transaction or CRDT story here;
the shared-state model is last-writer-wins.

**Groups** (`letta/schemas/group.py`, `letta/groups/`) are a persisted
orchestration primitive with a `manager_type`: [src]

- `round_robin` — fixed rotation, `max_turns`.
- `supervisor` — a `manager_agent_id` fans out and collects.
- `dynamic` — the manager agent *chooses the next speaker* via an injected
  `choose_next_participant(next_speaker_agent_id)` tool; the conversation ends
  when any message contains the group's `termination_token` (default `"DONE!"`)
  or `max_turns` is hit. Each participant is fed chat history from its own
  per-agent `message_index` watermark, so participants see only what they
  haven't seen. [src `dynamic_multi_agent.py`]
- `sleeptime` / `voice_sleeptime` — background memory agents as described above,
  with `max_message_buffer_length` / `min_message_buffer_length` bounds
  documented as "best effort, and may be off slightly due to user/assistant
  interleaving."

`shared_block_ids` on `Group` is marked **deprecated** — sharing moved to direct
block attachment rather than being a group property. [src]

The overall stance: multi-agent is a *persistence* feature. Agents are rows, so
a group is a row referencing agent rows, and shared memory is a foreign key.
Nothing needs a supervisor process.

## Notable Design Decisions

1. **The LLM is its own memory manager.** No retrieval heuristic decides what
   enters context; the model calls tools to promote/demote information. Memory
   management is prompted behavior over a tool API, and the quality ceiling is
   the model's judgment. [paper]

2. **Statefulness is the product.** Agents are database entities with durable
   identity; a "conversation" is a view over persisted messages. This is the
   root decision — resumability, multi-agent sharing, approval-across-restart,
   and background agents are all consequences.

3. **The system prompt is a mechanism explainer.** The `memgpt_chat` prompt
   spends most of its length teaching the model its own runtime — event system,
   heartbeats, which memory tiers exist, which are searchable and which are
   always visible, why overflow happens. Prompt text is treated as part of the
   architecture, not as tuning. (It also carries an anthropomorphic persona
   frame — "you are a real person," "a key part of what makes you a sentient
   person" — a product decision worth separating from the mechanism.)

4. **Continuation as an explicit protocol.** MemGPT: opt in via
   `request_heartbeat`. v3: opt out by not calling a tool. Both make loop
   termination a model-declared fact rather than a harness heuristic — and the
   reversal between versions is itself the interesting datum.

5. **Warn before evicting.** The model is told memory pressure is coming while
   it can still act on it. Compaction is not a silent harness event.

6. **Constraints declared as data.** Nine composable tool-rule types, evaluated
   as a set intersection over the available tool namespace, enforced on the
   request *and* rendered into the prompt. Control flow is configuration, not
   agent code.

7. **Move memory maintenance off the critical path.** Sleep-time agents pay the
   reorganization cost in the background rather than in the user's latency
   budget — and it is a full agent with its own prompt and tools, not a
   summarization function.

8. **Memory editing borrowed the code-editor interface.** Exact-string replace,
   line insert, patch apply, plus a whole-block rethink — narrow and broad tools
   in one set, with an explicit `memory_finish_edits` terminator.

9. **Reuse git for memory versioning** (MemFS) rather than modelling revisions
   in the schema; blocks are markdown files, reads take a ref.

10. **Isolation outsourced, dependency-isolation local.** Real security
    isolation means E2B/Modal; the local path is a subprocess with an optional
    venv, defaulting to `use_venv: False`.

11. **Loop versions coexist rather than migrate.** v1/v2/v3 agents live in the
    same tree. Compatibility preserved, coherence spent.

12. **Tool schemas cannot be under-documented.** Google-style docstring
    validation *raises* on missing `Args:` or an undocumented parameter.

13. **Approval is a message role.** Human-in-the-loop is persisted state with a
    denial reason returned to the model, not a UI-layer block.

## Relevance to Crescent

Observations only — no recommendations; the design call is the owner's.

**Where crescent stands.** `lib/ai/tools.lua` is currently a bounded
tool-calling loop: copy messages, call `ai.generate`, execute handlers by name
from a `handlers` table, append results, repeat until no tool calls or
`max_rounds` (default 10). There is no memory tier, no continuation protocol
beyond "did the model emit tool calls," and no constraint layer.

**Directly transferable, no substrate needed.**

- *Advertising out-of-context state by count.* The `<memory_metadata>` idea —
  telling the model what exists outside the window and how to reach it — is a
  prompt-construction convention, not machinery.
- *Warn-before-evict.* Signalling memory pressure to the model while it can
  still act is a threshold check plus an injected message.
- *Docstring-derived tool schemas that hard-error when under-documented.*
  Crescent already has `--:`/`--::` annotations carrying exactly the types a
  tool schema needs, and a typechecker that reads them. Generating tool schemas
  from annotations — and refusing to generate for an undocumented parameter —
  is the same decision expressed in crescent's native metadata, and it would
  satisfy "never duplicate type definitions" better than a hand-written schema
  table.
- *Separating inner monologue from user-visible output* by making the latter a
  tool call.

**Transferable but with a real substrate question.**

- *Tool rules as data.* Nine declarative rule types evaluated as set
  intersection is a clean, non-special-cased design and maps well onto Lua
  tables. But note the overlap with `lib/taskgraph`: `run_first`, `exit_loop`,
  `constrain_child_tools`, and `conditional` are edge constraints on an
  execution graph. Whether tool sequencing belongs in a new DSL inside `lib/ai`
  or is expressed with taskgraph's existing combinators/frontier is an open
  design question, not something this survey resolves.
- *Continuation protocol.* Letta ran both directions (opt-in heartbeat, then
  opt-out). Which suits crescent depends on whether an agent app is
  conversational or batch — and the two harnesses in `letta/agents/` coexisting
  is a warning about deciding this late.

**Requires substrate crescent does not have.**

- The stateful-agent core assumes durable structured storage; Letta uses
  Postgres + pgvector + Alembic. Crescent is zero-dependency, so persisted agent
  state means picking a storage substrate first (`docs/inventory.md` should be
  checked for what exists before anything is designed on top). Archival memory
  additionally assumes vector search and embeddings.
- Sleep-time agents assume background execution with its own scheduling
  (`turns_counter`, background task issuance).
- Sandboxing: Letta's answer is "outsource to a cloud microVM," which is
  unavailable to a zero-dependency local runtime. The local-subprocess-plus-venv
  fallback is a dependency boundary, not a security one — so crescent's
  tool-execution isolation story cannot be borrowed from here and is genuinely
  open. Crescent's caps-first rule is a *stronger* starting position than
  Letta's approval-gate model: an uninjected cap is unreachable, whereas an
  ungated tool in Letta is merely un-gated.

**Cautionary reads.**

- Three coexisting generations of memory tools and four of sleep-time managers
  are exactly the accumulation pattern crescent's hard constraints exist to
  prevent. The pattern is instructive as prior art *and* as a warning.
- Shared memory blocks with acknowledged lost updates: shared mutable state
  between agents needs a concurrency answer chosen deliberately, not discovered.
- The surveyed repo is legacy and the successor is a TypeScript CLI. The design
  documented here is complete and coherent, but the vendor has already moved.

## Sources

Primary (read directly):

- `github.com/letta-ai/letta` — shallow clone at survey date. Files cited
  inline: `README.md`, `letta/constants.py`, `letta/schemas/tool_rule.py`,
  `letta/schemas/group.py`, `letta/schemas/sandbox_config.py`,
  `letta/agents/letta_agent_v3.py`, `letta/prompts/prompt_generator.py`,
  `letta/prompts/system_prompts/{memgpt_chat,letta_v1,sleeptime_v2}.py`,
  `letta/services/summarizer/{summarizer,thresholds,enums}.py`,
  `letta/services/tool_sandbox/local_sandbox.py`,
  `letta/services/memory_repo/{memfs_client_base,git_operations}.py`,
  `letta/groups/{sleeptime_multi_agent_v4,dynamic_multi_agent}.py`,
  `letta/functions/{schema_generator,function_sets/base,function_sets/multi_agent}.py`.
- Packer et al., "MemGPT: Towards LLMs as Operating Systems", arXiv:2310.08560 —
  https://arxiv.org/abs/2310.08560 (read via ar5iv HTML rendering).

Documentation:

- https://docs.letta.com/concepts/letta
- https://docs.letta.com/guides/agents/memory-blocks
- https://docs.letta.com/guides/agents/multi-agent-shared-memory
- https://docs.letta.com/tutorials/shared-memory-blocks/

Secondary (unverified against source):

- https://www.leoniemonigatti.com/blog/memgpt.html
- https://vectorize.io/articles/mem0-vs-letta
- https://modal.com/resources/best-code-execution-sandboxes-tool-calling-ai-agents
- https://northflank.com/blog/e2b-vs-modal
