# Agent Harness Survey: Cross-Project Synthesis

## 1. Overview

This document synthesizes findings from 26 individual prior-art surveys, each covering
one open-source AI agent harness or agentic framework: Aider, AutoGen, AutoGPT, BabyAGI,
browser-use, CAMEL, Claude Code, Cline, Codex CLI, Continue.dev, CrewAI, Gemini CLI,
Goose, LangGraph, Letta (MemGPT), LlamaIndex (Workflows/AgentWorkflow), MetaGPT, Nous
Hermes Agent, OpenAI Agents SDK (and its predecessor Swarm), opencode, OpenHands (V0 and
V1), Open Interpreter (Python era and Rust-fork era), pi, Semantic Kernel, smolagents,
and SWE-agent (and its successor mini-swe-agent).

Collectively these projects span the whole design space that has emerged around
"an LLM that takes actions in a loop": single-file minimal loops (BabyAGI) up through
enterprise orchestration platforms (Semantic Kernel, LangGraph); terminal coding
assistants (Aider, Claude Code, Codex CLI, Cline, opencode, Gemini CLI, Goose, pi);
research artifacts that became production systems and then were rewritten or retired
(CAMEL, MetaGPT, AutoGen, OpenHands, Letta, Open Interpreter, OpenAI's Swarm→Agents SDK);
multi-agent orchestration frameworks (CrewAI, LangGraph, AutoGen, Semantic Kernel,
LlamaIndex); and specialized single-domain agents (browser-use for web automation,
SWE-agent for software engineering). Several of the projects surveyed have already gone
through at least one complete architectural rewrite, and in a few cases (AutoGen,
MetaGPT, OpenHands, Letta) the original published design is explicitly superseded by a
different one in the same repository. That churn is itself part of what this survey
captures — see Section 5.

Every claim below traces to something stated in one of the 26 source files. Where two
source files disagree, or where one is confident and another silent on the same axis,
that is noted explicitly rather than resolved by picking a side.

## 2. Comparison Matrix

Cells are terse paraphrases of what each survey states about that project. "Not
specified in source" is used where the survey did not establish an answer, rather than
guessing one.

| Project | Tool-calling protocol | Context/memory management | Sandboxing/permission model | Multi-agent support |
|---|---|---|---|---|
| **Aider** | No tool calling for edits — benchmarked and rejected for code payloads; prose-adjacent formats (SEARCH/REPLACE, udiff, whole-file) chosen per model, parsed with a permissive matching cascade | Repo map via tree-sitter tags + PageRank personalized per turn, binary-search token fitting; two-tier file model (in-chat/read-only/mapped); recursive LLM summarization of old history | No sandbox; git is the safety net (auto-commit, dirty-commit-first, `/undo`); `confirm_ask` gates file writes and shell commands, with `explicit_yes_required` exempting shell from blanket auto-confirm | None; only a two-model architect/editor composition (prose planner → format-reliable editor), not a general mechanism |
| **AutoGen** | Native tool calling via `FunctionTool`, schema derived from type hints/docstring; v0.4 collapsed caller/executor into one agent; handoffs are tool calls | `ChatCompletionContext` as an injected window-policy object (unbounded/buffered/token-limited/head-and-tail); `Memory` protocol separate from context, `ListMemory` the reference impl, vector backends optional | No isolation model beyond Docker-vs-local code executor choice; `InterventionHandler`s inspect messages at the runtime chokepoint (allow/deny/drop) | Multiple team presets (RoundRobin, Selector, Swarm, MagenticOne, GraphFlow) spanning static to fully model-driven; own docs recommend starting single-agent |
| **AutoGPT** | Classic: hand-rolled JSON, later migrated to native tool calls; Platform: orchestrator block synthesizes tool schemas from graph topology, normalizes across OpenAI/Anthropic dialects | Classic: dropped vector DBs in favor of recency window + LLM summarization of tail, oversized results treated as failures; Platform: `conversation_history` as graph data with compaction | Classic: Docker-or-withhold for code exec, shell allow/denylist, human confirmation per step; Platform: no local execution, delegates to E2B; permissions monotonically narrow down nesting chain | Hierarchical/structural only: sub-agents are saved graphs (blocks) invoked by an orchestrator block; no peer-to-peer messaging |
| **BabyAGI (classic)** | None — no tools, no shell, no file I/O; the agent's only effect is a printed transcript and vector store entries | Embed-every-result, retrieve-top-5 against the objective via a vector-store fallback chain (Weaviate→Pinecone→Chroma); no conversation history, single-shot completions | None needed — no side-effecting capabilities exist; only risk is unbounded API spend | Not agents but instances: `COOPERATIVE_MODE` shares a task queue/vector namespace across processes; `distributed` mode unimplemented |
| **browser-use** | Native tool calls via a registry; dynamic per-step, URL-filtered action surface; batched multi-action turns with static (`terminates_sequence`) and runtime (URL/focus-changed) abort guards | Rebuilds the prompt every step from a typed history log rather than an accumulating transcript; two-tier result split (full vs. long-term-memory summary); opt-in LLM compaction labeled "unverified context" | Domain allowlist/denylist enforced at the navigation layer; sensitive data substituted post-LLM via placeholders; filesystem confined to a base dir; no per-action human approval by design | None by design — no subagent spawning; parallelism is caller-driven multiple `Browser` instances, explicitly experimental |
| **CAMEL** | OpenAI function-calling verbatim; `_external_tool_schemas` route calls back to the caller instead of executing (harness-in-the-loop for designated tools); optional LLM-synthesized schemas/outputs | Three-layer memory (storage/`MemoryBlock`, retrieval+scoring/`ContextRecord`, window-packing/`ContextCreator`), each independently swappable | No permission model; safety is choice of one of five interpreters (in-process AST-restricted, subprocess, Docker, Jupyter, E2B), trust-based guidance only | Two generations: `RolePlaying` (fixed two-agent alternation enforced by prompt discipline, caller owns the loop) superseded by `Workforce` (hierarchical async task-channel routing with typed retry/replan/reassign/decompose recovery) |
| **Claude Code** | Native calls declared via in-process MCP servers (MCP is both extension and tool-definition mechanism); static `readOnlyHint` gates parallel-vs-serial execution; oversized results spill to disk with a file reference; tool schemas deferred/searched past ~30 tools | Five ordered pre-model context shapers (budget reduction → snip → microcompact → context-collapse projection → auto-compact summary), cheapest-first; compaction never destroys the on-disk transcript; anything loaded from disk survives compaction, anything from message history does not | Seven independent, ordered safety layers (tool pre-filter, deny-first rules, mode baseline, ML classifier, OS sandbox, no-restore-on-resume, hooks); deny beats allow always; OS-level sandbox (Seatbelt/bubblewrap) separate axis from permission rules | Subagents are a tool dispatched through the same loop factory, isolated input context but not isolated output; only final response returns to parent; worktree/in-process/remote isolation modes; depth and count capped |
| **Cline** | Reversed decision: originally XML-in-text for maximal model reach, migrated to native tool calling for reliability/parallelism/token cost, but both paths kept permanently, selected per model family | Threshold-triggered compaction (0.9 trigger / 0.7 target hysteresis), two strategies (deterministic vs. LLM-summarized) user-selectable; `.clinerules/` as agent-writable version-controlled memory | No sandbox; approval + reversibility only — eight-category approval taxonomy, model self-classifies command risk (`requires_approval`); shadow-git checkpointing (not the user's repo) for undo | Late addition: skills/subagents as a tool call, lead/coordinator delegates to specialists, isolation via separate git worktrees (OS-level, not in-process) |
| **Codex CLI** | Native tool schemas via a `ToolRegistry`/`ToolRouter`; `apply_patch` uses a custom V4A diff grammar the models are trained on; parallel execution where tools declare support | `AGENTS.md` instruction chain merged root-down with an `.override.md` sibling and a byte budget; compaction is full extraction-and-replacement (not append), prior summaries excluded from re-summarization | Two explicitly orthogonal axes: sandbox mode (OS-enforced: read-only/workspace-write/full-access) vs. approval policy (when to ask); network denied by default; Seatbelt/bubblewrap+seccomp/Windows restricted tokens; declarative Starlark exec-policy language with strictest-match-wins composition | Subagents as tools (`spawn_agent`/`wait_agent`/`send_message`); custom agents are standalone TOML files; bounded fan-out and capped recursion depth; permission inheritance with per-agent override |
| **Continue.dev** | Native tools plus a full second text-fallback protocol (`SystemMessageToolsFramework`, line-delimited args) selected per-model as an injected strategy object; tools addressed by URI scheme (built-in/`mcp://`/`http(s)://`) | Context providers resolve once, eagerly (no re-resolution); indexing is content-addressed and branch-tagged (branch switch = re-tag, not re-embed); IDE mode drops-oldest-and-reports, CLI mode summarizes at 80% — different answers per surface | No sandbox; policy is a lattice (`disabled`>`allowedWithPermission`>`allowedWithoutPermission`) evaluated per call on preprocessed arguments, clamped to only ever narrow a user-declared ceiling; shell commands analyzed via a real tokenizer, most-restrictive-wins | Shallow: a subagent is a model config entry with a `subagent` role and a system message, no separate format, no parallel fan-out, no nesting policy, present only in the CLI |
| **CrewAI** | Dual-mode executor (native tool calling preferred, ReAct text fallback); `ToolFailure` as a distinct type from a string error; failure policy (`ignore`/`warn`/`raise`) cascades tool→task→agent→crew | Three distinct concepts kept separate: Context (task-to-task data flow), Knowledge (static RAG), Memory (cross-run, hierarchical scope paths inferred by an LLM, composite similarity/recency/importance scoring) | Sandboxing (`allow_code_execution`, Docker mode) was shipped, then deprecated and removed entirely, with users redirected to third-party sandboxes (E2B, Modal); otherwise no permission model, tools hold ambient process authority | Two orthogonal control planes: autonomous Crews (sequential or manager-LLM-routed hierarchical) and deterministic event-driven Flows (decorator-based state machine), added specifically because autonomous crews could not be shipped to production |
| **Gemini CLI** | Native Gemini function calls; every tool carries a `Kind` annotation used by policy matching; user shorthand (`@path`, `!cmd`) and model tool calls share one path; mode transitions and clarification are themselves tools | Four separated mechanisms: hierarchical `GEMINI.md` (eager + just-in-time on file touch), import processor, threshold/reverse-token-budget compression (with an inflation-detection failure status), and Agent Skills (progressive disclosure) | Three independent layers: trusted-folder discovery gate (off by default), declarative TOML policy engine with monotone tiered priority and global-deny-removes-the-declaration, and OS-level sandbox (Seatbelt/Docker/gVisor/LXC), defaulting to per-tool rather than whole-process isolation | Subagents exposed as tools via a unified `invoke_agent`; markdown+frontmatter definitions; mandatory `complete_task` termination contract with a grace period on timeout; recursion explicitly banned (not just depth-capped); remote subagents over A2A protocol |
| **Goose** | Every tool reaches the model through MCP — "MCP or nothing" for third parties, with typed `platform`/`frontend` escape hatches in the same config enum; oversized results spill to a temp file | Two tiers (auto-compaction at 80% threshold, then a configurable fallback strategy); compaction summary is a typed record with most-important-first ordering and deliberately lenient parsing | No OS sandbox by default; a pluggable `ToolInspector` pipeline (permissions, prompt-injection scanner, egress/exfiltration detector, adversary detector) each returning allow/deny/require-approval with a confidence score; all non-permission scanners off by default | Two distinct, deliberately un-unified mechanisms: durable file-based "recipes"/sub-recipes (tool set pinned by the workflow author, not chosen by the agent) vs. ephemeral natural-language subagents (no shared state, capped concurrency, cannot recurse) |
| **LangGraph** | No bespoke protocol — delegates wire format to provider-native tool calling; tool results are ordinary state updates (`ToolMessage`), not a privileged return channel; the ReAct loop is a prebuilt graph, not core | Split by scope: Checkpointer (per-thread, durability-tunable exit/async/sync) vs. Store (cross-thread); context-window trimming/summarization run as middleware separate from what is persisted, using `RemoveMessage` for identity-aware deletion | No sandbox and no permission model in the framework itself; `interrupt()` pauses the graph for typed human approve/edit/reject/respond, with a documented determinism obligation (resume replays the whole node) | No "agent" primitive — a multi-agent system is a graph of graphs; handoff is a `Command(goto=..., graph=Command.PARENT)` routing construct underlying network/supervisor/hierarchical patterns, all built from the same mechanism |
| **Letta (MemGPT)** | Native tool calls plus a synthetic `request_heartbeat` parameter (MemGPT era) that the model sets to explicitly opt into continuing; reversed in v3 to opt-out (no tool call = stop); tool schemas hard-error on missing docstrings; nine composable declarative tool-rule types constrain the available set | OS-paging analogy made literal: fixed main context (system + core memory block + FIFO queue) plus external recall/archival storage, with the LLM itself as the paging policy via memory-editing tools; sleep-time background agents move reorganization off the critical path | Tool execution sandboxed by pluggable backend (local subprocess/E2B microVM/Modal container), local mode not a security boundary by the survey's own reading; approval is a persisted message role (`RequiresApprovalToolRule`) surviving process restarts, denial carries a reason | Explicit messaging tools (sync/async/tag-broadcast) plus shared memory blocks (same block attached to multiple agents = shared state, with acknowledged lost-update races); persisted `Group` orchestration with round-robin/supervisor/dynamic-manager modes |
| **LlamaIndex (Workflows)** | Tool schemas always derived from Python signatures/docstrings, never hand-written; `Context`-typed parameters and `partial_params` are excluded from the emitted schema (hidden from the model); `return_direct` short-circuits the loop | Token-budgeted buffer with a waterfall eviction into pluggable, priority-ordered long-term memory blocks (static/fact-extraction/vector) — described as a budget-allocation problem with pluggable eviction policy, not a fixed strategy | No built-in permission or approval model; `can_handoff_to` restricts routing targets but is not a security boundary; human-in-the-loop via `wait_for_event`, implemented as pause-via-exception with a documented replay-before-the-wait cost | Agent is explicitly demoted to a configuration of a general orchestration engine (not a primitive); three ranked patterns (handoff, agents-as-tools, custom planner) presented on a complexity/flexibility axis without a recommended winner |
| **MetaGPT** | Two generations, both text, never native: code-as-action (Data Interpreter) and a batched JSON command array (`RoleZero`) with a six-stage repair funnel including an extra LLM call for JSON repair; docstring-derived schema with no JSON Schema anywhere | `instruct_content` is a structured side channel that never reaches the LLM (zero context cost); artifacts persist on the filesystem with messages carrying only paths/handles; per-role memory intake filtered by subscription (`_watch`) predicate, not relevance-scored at assembly | Effectively none — `exec()` in-process, LLM-authored `requirements.txt` piped to pip install, ambient environment copied into subprocess/shell; only mitigation is a substring-matched forbidden-commands nudge; human review is post-hoc and off by default in the shipped configuration | The published thesis (`Code = SOP(Team)`, fixed waterfall pipeline wired by stringified action subscriptions) was demoted to `use_fixed_sop: bool = False` in the current default, replaced by an LLM-routed generalist tool-using team led by a `TeamLeader` hub |
| **Nous Hermes Agent** | ~40+ builtin tools via native function schemas, MCP, and API wrappers; user-facing verbs are a separate slash-command registry, not modeled as LLM tools; tools carry a risk classification gating `/approve`/`/deny` | Three tiers: procedural skills with progressive disclosure (metadata-only listing, full body loaded on demand), episodic SQLite FTS5 recall with LLM summarization, and cross-conversation user modeling; head-middle-tail compression with tool-output pre-summarization before the LLM pass | Isolation delegated to a swappable "terminal backend" (local/Docker/SSH/Singularity/Modal/Daytona/Vercel); risky commands gate on `/approve`/`/deny`; a static analyzer ("Skills Guard") scans externally-sourced skills for exfiltration/injection/destructive patterns before trust | `delegate_task` spawns isolated children with fresh context, restricted toolset (delegation tool itself blocked in children), synchronous or background mode, recursion depth capped at 1 |
| **OpenAI Agents SDK** | Tool schema derived entirely from function signature + docstring (via `griffe`), no separate registration table; `needs_approval` gates a tool per-call, pausing the run into a durable, cross-process-serializable `RunState` | Local context (`RunContextWrapper[T]`, never sent to the model) explicitly separated from LLM context; four mutually exclusive multi-turn persistence strategies (manual, Sessions, `conversation_id`, `previous_response_id`), none defaulted; Sessions wrap with a composable `EncryptedSession` | Three distinct mechanisms not to conflate: Guardrails (content validation, perimeter-only — first agent in, last agent out), tool approval (the actual capability gate, durable/resumable), and beta Sandbox Agents (workspace-boundary isolation via Docker or hosted backend, no OS-level primitive in the SDK itself) | Two mechanisms kept deliberately distinct: Handoffs (control transfer, rebinds the loop's current agent, exposed to the model as a tool) vs. Agents-as-tools (call-and-return, orchestrator retains control); successor to Swarm, which had only two primitives and no production layer |
| **opencode** | Tools defined as description+Zod-schema+execute, framework-level automatic argument validation and output truncation; results split into UI channel (`title`/`metadata`) and model channel (`output`); custom tools shadow built-ins by name | `AGENTS.md` walked up from cwd with a Claude-Code-compatible fallback; automatic threshold-triggered compaction with a dedicated summary prompt; todo state re-rendered each turn rather than recalled; undo via git `write-tree` snapshots | No OS-level sandbox; policy-based mediation at the tool boundary — every rule resolves to allow/ask/deny, wildcard patterns, last-match-wins, permission targets extend to non-tool *behaviors* (`doom_loop`, `external_directory`) not just capabilities | Two categories distinguished by invoker: primary agents (user-switched) vs. subagents (invoked via a `task` tool or `@` mention); each subagent = prompt+model+tools+permissions+step budget in one file; subagent recursion capped at one level |
| **OpenHands** | V0: code-as-the-only-action (CodeAct thesis — Python/bash/browser-DSL, no discrete tool catalogue); V1: typed `Action`/`ToolExecutor`/`Observation` triple serializing to three API shapes (ChatCompletions/Responses/MCP) from one declaration; MCP schemas auto-convert to the same `Action` model as native tools | V0: pub/sub `EventStream` as the sole state; V1 kept event-sourcing (append-only `EventLog`, deterministic replay) but deleted the pub/sub bus entirely; `Condenser` produces a logged, reconstructable view (never destructive) via a cost ladder — several zero-LLM-call strategies chained before a summarizer | V0: mandatory per-session Docker sandbox with a REST Action Execution Server inside it; V1 reversed this to in-process-by-default with Docker opt-in via a workspace swap, citing crash-coupling and multi-tenant resource exhaustion; V1 splits risk assessment (`SecurityAnalyzer`, model self-annotates `security_risk`) from enforcement (`ConfirmationPolicy`) | V0: `AgentDelegateAction` hands control to a named sub-agent, tracked in the shared event log; V1 demoted delegation to an ordinary tool implemented with no core modifications, presented as the load-bearing proof that coordination behaviors belong in userland tools, not the core |
| **Open Interpreter** | Python era: one "tool" — execute code in any language, discrete capabilities exposed as a pre-imported Python library whose docstrings are the schema (no JSON Schema anywhere); function-calling models get the same code-block output via a different transport; malformed model output is repaired *and rewritten into history*; Rust-fork era: harness emulation switches prompt/schema/message-handling per target model | Python era: no compaction/summarization/retrieval — pure edge truncation (tail-biased output truncation with a remedy banner, keep-ends image eviction, image→caption degradation for non-vision models, token-window trim); skills are executable `.py` files taught interactively and exec'd into the live runtime | Python era: explicitly no sandbox — system prompt asserts "full and complete permission"; the only gate is a per-code-block human confirmation implemented as a generator-suspension/`GeneratorExit` handshake (approval includes in-place amendment via `$EDITOR`); optional advisory-only semgrep scan; Rust-fork era reversed this to native OS sandboxing as the README's first listed feature | Python era: none — no spawn/delegate primitive found in source; only a same-process `computer.ai` sub-call (no own history/loop) and best-effort state sync between parent/child Python runtimes |
| **pi** | Tools declared with TypeBox schemas (compile-time types + runtime JSON Schema from one declaration); per-tool declared concurrency (`sequential`/`parallel`, not a global switch); truncated-arguments guard fails all tool calls in a message if `stopReason === "length"`; explicitly no MCP (argued position, not an omission) | Session is a JSONL **tree**, not a log — branching in place, versioned entry format with automatic migration; compaction produces a self-contained checkpoint embedding a materialized retained tail; separate branch-summarization mechanism preserves context from abandoned tree paths | Explicitly no built-in permission system or sandbox by design — argued in `docs/security.md` that a partial in-process sandbox is worse than none because it reads as a boundary while not being one; only a project-trust input-loading gate; real isolation delegated to three documented external patterns (micro-VM tool routing, Docker, policy-controlled gateway) | Explicitly excluded from core ("no sub-agents... build your own with extensions"); reference implementation ships as an example extension: separate OS processes per subagent for genuine context isolation, markdown agent definitions, project-local agents not loaded by default (security) |
| **Semantic Kernel** | Native automatic function-calling loop is the only control flow — planners (prompt-driven plan generation) were built, then deprecated and removed once cross-vendor native function calling arrived; prompt functions and native functions are the same callable type; ADR records a measured hallucination cost from the `Plugin-function` naming separator | Chat-history reducers (`Truncation`/`Summarization`) with an opt-in auto-apply flag; `AgentThread` abstracts server-held vs. client-held conversation state and fails fast on a type mismatch; "memory" generalized into `AIContextBehavior`, an observer that can inject context, inject tools, and suspend/resume | No isolation or sandboxing mechanism; **Filters** (middleware with a `next` delegate) are the sole control point for blocking, retrying, or overriding function calls and prompts — but filters attach to the `Kernel` object and are silently bypassable by calling the underlying chat service directly | Actor-based orchestration (agents wrapped as message-passing actors in a shared runtime, explicitly built on AutoGen's prior art); five prebuilt patterns (Concurrent/Sequential/Handoff/GroupChat/Magentic) as lazy, runtime-agnostic templates; `AgentGroupChat` was retired in favor of a pluggable-manager successor |
| **smolagents** | Central thesis: the LLM's action is a Python code block, not a JSON tool call, executed in a custom AST-walking interpreter (not `eval`/`exec`); `ToolCallingAgent` (native JSON) kept as a first-class alternative chosen per role, not deprecated; termination via a `final_answer` tool wrapped to raise an exception | Typed step-object log (`AgentMemory`), not a message array — messages are derived on demand via `to_messages(summary_mode=...)`, letting the same history render differently for different consumers (e.g. hiding old plans from a new planning step) | Explicit, published risk enumeration (LLM error, supply-chain, prompt injection via browsed content, exposed-agent exploitation); tiered sandbox menu from a hardened local AST interpreter (import allowlist, dunder-access blocking, operation caps) through remote-snippet execution to whole-system container isolation, with an explicit disclaimer that no local option is a real boundary; no per-action human approval | Sub-agents are exposed as ordinary tools (mandatory `name`/`description`) to a manager agent; hierarchy only (manager→workers, no peer messaging); sub-agents are context-isolated by construction, returning only a text report; heterogeneous protocol choice per role (JSON for a single-timeline web worker, code for the planning manager) |
| **SWE-agent** | Curated command set (search/navigate/view/edit) layered *on top of* raw bash, empirically tuned via ablation (a purpose-built editor with linting outperforms bash edits by 7.7 points; a naive IDE-style iterative search underperforms having no search tool at all); eleven pluggable action parsers (ReAct text, XML, native function-calling, JSON, …) over one internal representation; tools are filesystem bundles (executable + schema in one directory), not in-process registrations | Composable history-processor pipeline (elide old observations but keep actions/plan intact, drop superseded file-viewer windows, dedupe repeated error messages, hard length cap before any processing); out-of-band `state_command` runs after every action to inject state without spending an agent turn | Execution delegated wholesale to a separate library (SWE-ReX) — local/Docker/AWS/Modal/Fargate backends behind one interface; permission model is coarse and static (container is the boundary plus an execution blocklist), no per-tool grant or interactive approval — explicitly built for unattended benchmark runs with no human present | No peer/role-specialized team; multi-*attempt* with model-based selection instead — N sequential full-task retries, a reviewer model scores or a chooser model picks among completed submissions, shared budget re-divided across attempts; framed as best-of-N sampling, not collaboration |

## 3. Cross-Cutting Patterns

**Native tool calling displacing text/JSON protocols, with one prominent holdout.**
Cline, SWE-agent, and MetaGPT all describe migrating (or maintaining parallel support)
from text-based or hand-rolled JSON tool protocols toward provider-native function
calling, citing reliability, parallelism, and token cost (Cline: ~15% fewer tokens;
SWE-agent's default config now uses native calling). Semantic Kernel deleted its
prompt-driven planners specifically because "other AI models like Gemini, Claude, and
Mistral have since adopted function calling as a core capability." Aider is the
deliberate counter-example: it benchmarked JSON tool calling against markdown-fenced
edit formats for *code payloads specifically* and found every tested model scored worse
in JSON, including under OpenAI's strict schema mode — its conclusion is narrower than
"avoid tool calling," it is "avoid tool calling for code bodies." smolagents and
OpenHands V0 (CodeAct) push this further, treating code-as-the-only-action as the
default rather than an edge case, though both keep a native-JSON-calling path available
for other roles (smolagents' `ToolCallingAgent`, OpenHands V1's typed Action).

**Code-execution-as-tool-calling.** smolagents, Open Interpreter (Python era), and
OpenHands V0 (CodeAct) independently converge on the same move: instead of a
discrete tool catalogue, give the model a code interpreter and expose capabilities as
library functions the model calls by writing code. All three name the same advantages
(composability, free object/state management across steps, generality) and the same
cost (the security boundary and the capability boundary collapse into one, since a
model that can write code can reach anything the interpreter can reach). smolagents is
explicit that it built a custom AST-walking interpreter specifically to make this
survivable; Open Interpreter's Python era shipped no such hardening and instead relied
on a per-block human confirmation.

**Deprecating or demoting the dedicated planner/orchestrator component.** Semantic
Kernel deleted its planners (Stepwise/Handlebars) once native function calling arrived,
stating the replacement is "the automatic function-calling loop," not a planner above
it. AutoGPT's classic prompt-strategy zoo (ReWOO, PlanExecute, Reflexion, Tree of
Thoughts) was superseded by the block/graph platform, where planning is either absent
or a wired node like any other. MetaGPT's SOP pipeline (the paper's central thesis) is
now switched off by default (`use_fixed_sop: bool = False`) in favor of a
`RoleZero` ReAct loop. LangGraph and LlamaIndex both state that the agent loop
(`create_react_agent`, `AgentWorkflow`) is a *prebuilt* built from the same primitives
as everything else, not a privileged core. The common thread across AutoGPT, MetaGPT,
Semantic Kernel, LangGraph, and LlamaIndex is that a bespoke planning/orchestration
layer above the tool loop was tried, and in every one of these five cases the project
either removed it or explicitly demoted it to "one configuration among several."

**ReAct-style loops as the converged-upon default control flow.** Despite the
diversity of surrounding machinery, the innermost loop — generate, dispatch tool
calls, append results, repeat until no more tool calls or a bound is hit — appears
essentially unchanged across Claude Code, Cline, Codex CLI, Continue.dev, CrewAI,
Gemini CLI, Goose, LangGraph's `create_react_agent`, LlamaIndex's `AgentWorkflow`, Nous
Hermes Agent, OpenAI Agents SDK's `Runner`, opencode, pi's `agentLoop`, Semantic
Kernel's automatic function-calling loop, smolagents, and SWE-agent. Several sources
name this shape explicitly as ReAct or state it is functionally equivalent to ReAct.
Claude Code's own survey states the tradeoff directly: "the reactive design trades
search completeness for simplicity and latency: each turn commits to one action
sequence without backtracking."

**Sub-agent spawning as a tool call, not a separate orchestration channel.** Claude
Code, Codex CLI, Gemini CLI, Nous Hermes Agent, opencode, OpenAI Agents SDK
(agents-as-tools), Goose (subagents), smolagents, CrewAI (delegation tools), and
MetaGPT's `TeamLeader.publish_team_message` all implement delegation as an ordinary
tool the model calls, executed by the same dispatch path as any other tool, rather than
inventing a parallel control-flow primitive. LangGraph and the OpenAI Agents SDK's
*handoff* mechanism are the partial exception — both implement delegation as a special
routing construct (`Command(goto=...)`, `transfer_to_<agent>`) that rebinds control
rather than nesting a call-and-return, but even the Agents SDK exposes that construct
to the model as a tool call on the wire.

**Diff-based/patch-based edits vs. whole-file rewrites, chosen per model or per
task.** Aider explicitly benchmarks and selects among `whole`, `diff`
(SEARCH/REPLACE), `udiff`, and `patch` formats per model capability. Codex CLI
standardizes on a single custom diff grammar (V4A) because "the models are trained on
this exact format." Claude Code, Cline, and opencode all expose dedicated edit/patch
tools (`Edit`, `edit_file`, `apply_patch`) alongside whole-file write tools. The
recurring finding (Aider's benchmarks, SWE-agent's ablation showing a purpose-built
linted editor beating raw bash `sed` by 7.7 points) is that a dedicated, narrow edit
format measurably outperforms asking the model to emit or manipulate whole files via
general-purpose means.

**Permission/approval gating implemented as a middleware/filter chokepoint rather
than scattered checks.** AutoGen's `InterventionHandler`s inspect every message
crossing the runtime; Semantic Kernel's `Filters` wrap every function/prompt call with
a `next`-based pipeline; Goose's `ToolInspector` pipeline runs a list of pluggable
analyzers producing a uniform allow/deny/require-approval verdict; Continue.dev's
`ToolPolicy` lattice is evaluated per call and can only narrow, never widen, a
user-declared ceiling; Gemini CLI's TOML policy engine and OpenHands V1's
`SecurityAnalyzer`/`ConfirmationPolicy` split both centralize risk assessment as a
single evaluated function. The recurring shape is: one central evaluation point,
several independent policies compose deterministically (most-restrictive-wins,
strictest-match, or monotone narrowing), and the decision is separable from
enforcement.

**Memory/context management as an explicitly staged or tiered pipeline, cheapest
strategy first.** Claude Code names its rule directly: "apply the least disruptive
compression first, escalating only when cheaper strategies prove insufficient," and
runs five ordered shapers. OpenHands' `CondenserPipeline` chains a zero-LLM-call
`BrowserOutputCondenser` before the expensive `LLMSummarizingCondenser`. SWE-agent's
`history_processors` chain elides observations before anything token-expensive
happens. Cline offers two compaction strategies (deterministic vs. LLM) as an explicit
determinism/fidelity tradeoff rather than picking one. Gemini CLI's compression
pipeline reports failure statuses including detected inflation. The common move is
treating context reduction as a composable pipeline of increasingly expensive
strategies rather than a single fixed algorithm.

**Reads or interoperates with a competitor's convention files.** opencode falls back
to `~/.claude/CLAUDE.md` when no `AGENTS.md` is found (disableable via an env var).
Gemini CLI's `context.fileName` setting accepts `AGENTS.md`/`CONTEXT.md`/`GEMINI.md`
interchangeably and its skills path alias `.agents/skills/` deliberately *outranks*
`.gemini/skills/`; its hooks also accept `CLAUDE_PROJECT_DIR` as a compatibility env
var alias. pi reads both `AGENTS.md` and `CLAUDE.md` regardless of project trust and
documents importing `~/.claude/skills` and `~/.codex/skills` directly. OpenHands lists
`AGENTS.md`/`repo.md`/`.cursorrules` as static context sources it loads without
modification. This is at least four independent, unaffiliated projects treating
cross-harness interoperability of on-disk convention files as worth the engineering
cost.

**Approval prompts erode under habituation, and at least two projects responded by
restructuring rather than adding more warnings.** Claude Code's survey cites
Anthropic's own measurement that users approve ~93% of permission prompts and that
auto-approve rates rise with session count, terming the response "not... more
warnings" but "defined boundaries... within which the agent can work freely, rather
than per-action approvals." Cline's survey independently observes the same erosion
from the product side: a UI simplification pass removed the max-requests cap and the
auto-approve master toggle as "unnecessarily complex," which the survey reads as
"evidence that approval-fatigue pressure erodes approval-based safety models over
time." Both projects are unaffiliated and reach the same empirical conclusion from
different vantage points (a controlled internal study vs. observed product evolution).

## 4. Notable Divergences

**Sandbox everything by default vs. sandbox nothing by default vs. sandbox is not the
harness's job.** OpenHands V0 made per-session Docker isolation mandatory; SWE-agent
and smolagents' tiered-container option assume the agent runs inside a container for
any serious use. At the opposite pole, Aider, Cline, CrewAI (after removing its Docker
mode), Continue.dev, LangGraph, LlamaIndex, Semantic Kernel, MetaGPT, and Open
Interpreter's Python era all run with the full privileges of the host process and rely
entirely on human confirmation and/or reversibility (git) as the safety mechanism. A
third position argues sandboxing should not be attempted at the harness's own layer at
all: pi's `docs/security.md` states a partial in-process sandbox is actively worse than
none because "it [would be] easy to misunderstand as a security boundary" without being
one, and delegates real isolation to external patterns (micro-VM, container, gateway).
What each side gives up: mandatory sandboxing costs infrastructure complexity and (per
OpenHands V1's own reversal) crash-coupling and multi-tenant resource contention; no
sandbox costs a real security boundary and depends on human vigilance that multiple
sources document eroding; declining to build a partial sandbox costs users a built-in
answer and pushes the isolation decision onto deployment.

**Container/process isolation vs. capability injection as the security primitive.**
OpenHands, SWE-agent, and smolagents' tiered menu treat *where code runs* (which
process, which container) as the security boundary. Aider, Continue.dev, and Codex
CLI's approach layer differently: Codex CLI keeps container/OS-level sandboxing (via
bubblewrap/Seatbelt) as the enforced boundary but adds a *separate, orthogonal*
approval-policy axis on top, explicitly arguing these should not be collapsed into one
"permission level." pi's `ExecutionEnv` and Continue.dev's `ContextProviderExtras`
both make filesystem/process access an injected capability object rather than an
ambient import, independently converging on the same discipline without necessarily
adding OS-level isolation underneath it. The tradeoff: OS/container isolation is a
real security boundary against adversarial code but expensive and sometimes
unavailable (no Docker, no root); capability injection constrains what *honestly
written* handler code can reach but, as multiple surveys note (Open Interpreter,
smolagents), does not stop code that can `require`/`load`/`eval` arbitrary strings
from escaping the boundary.

**Model self-classifies risk vs. static declared policy vs. no per-action gate at
all.** Cline's `requires_approval` flag has the model attach its own risk assessment to
each command it proposes to run — the survey calls this "the entity being restricted
is also the entity classifying the risk," maximally flexible and only as trustworthy as
the model's judgment and its resistance to injection. OpenHands V1's default
`LLMSecurityAnalyzer` does the same (`security_risk` self-annotated by the model) but
keeps it structurally separate from the enforcement decision (`ConfirmationPolicy`).
Codex CLI, Gemini CLI, and Continue.dev instead use author-declared, data-driven policy
(Starlark rules, TOML rules, a `ToolPolicy` lattice) evaluated independent of anything
the model says about itself. SWE-agent and browser-use dispense with per-action human
gating entirely by design, since their target deployments (unattended benchmark runs,
autonomous web tasks) have no human present to ask. The tradeoff: self-classification
adapts to novel commands with no rule-authoring burden but trusts the same actor being
restricted; static policy is auditable and cannot be talked out of its position but
requires anticipating command shapes in advance.

**Conversation history as an ever-growing append-only transcript vs. a rebuilt/derived
view.** The default posture across most projects (Aider prior to summarization,
CrewAI, Continue.dev's IDE mode, MetaGPT's per-role memory, Semantic Kernel's chat
history) is a message array that grows and is trimmed or summarized in place.
browser-use takes the sharpest opposite position: its `MessageManager` keeps only one
system message plus a *rebuilt* per-step state message, with history represented as a
rendered string derived from a typed log rather than an accumulating array — the
harness, not the message list, owns exactly what the model remembers. smolagents and
pi land near the same position by different routes: smolagents renders messages
on-demand from a typed step log (`to_messages(summary_mode=...)`), and pi models a
session as a branching *tree* of entries with two-phase context construction (walk the
tree, then project to messages) rather than a flat log. OpenHands V1's event-sourced
`ConversationState` with derived `View`s and Codex CLI's compaction-as-full-replacement
sit in between: the underlying store is append-only, but what reaches the model is
always a computed projection. The tradeoff named explicitly in the browser-use survey:
rebuilding costs prompt-cache friendliness (a fresh prefix each turn) but buys full
harness control over exactly what the model sees.

**Autonomous, model-driven multi-agent coordination vs. deterministic,
developer-authored orchestration.** CrewAI's own history is the sharpest single
data point: it shipped autonomous Crews first (an LLM manager routes work by reading
free-text role/backstory strings) and only later added deterministic, decorator-based
Flows specifically because, per the survey, "autonomous crews could not be shipped to
production" — audited, replayed, or guaranteed. LangGraph and the OpenAI Agents SDK
both present this as a named, undecided choice rather than resolving it: LangGraph has
no "agent" primitive at all (a multi-agent system is just a graph), and the Agents SDK
docs explicitly describe "orchestrating via LLM" and "orchestrating via code" as two
named strategies with different tradeoffs, declining to build a graph DSL for the
deterministic path. CAMEL's two generations recapitulate the same arc independently:
`RolePlaying` enforces cooperation purely through prompt discipline (a system message
saying "never flip roles"), and `Workforce` replaced it with a typed task channel,
retry budgets, and an explicit recovery ladder — the survey calls this "the same
project shipped the thesis and its rebuttal." What each side gives up: LLM-routed
coordination is flexible and requires no upfront topology design but is unauditable
and, per CAMEL's own inception-prompt catalogue, prone to role-flipping, echoing, and
non-terminating politeness loops; developer-authored orchestration is reproducible and
debuggable but requires the topology to be known and encoded in advance.

**Code-as-the-tool-interface vs. discrete typed tool catalogue.** smolagents,
Open Interpreter, and OpenHands V0 argue the model should write code that calls
library functions, citing composability and free object/state management. The
discrete-tool position (nearly every other project surveyed, and OpenHands' own V1
rewrite) argues for typed, individually-declared, individually-permissionable
functions. The tradeoff each side names: code-as-tool buys composition and state
persistence across steps at one round-trip, but forfeits per-call argument validation,
structured error reporting, and — the point OpenHands V1 and smolagents both make
explicitly — per-capability permission scoping, since once a model can write general
code it can reach anything the interpreter can reach.

## 5. Historical Arc

The two earliest projects surveyed, AutoGPT and BabyAGI (both March/April 2023),
share a common shape and a common failure mode that later projects were built
specifically to correct.

**What the earliest projects looked like.** BabyAGI's classic loop (archived version)
is roughly 100 lines: a single task queue, no tools, no side effects beyond a
transcript and vector-store writes, embedding-based retrieval of the top-5 most
similar past results, and — critically — "no termination condition other than an empty
queue," with the task-creation step actively refilling what execution drains. Its own
author states the intent was "documentation of the minimum pattern," not a product,
and the README warns that continuous operation causes high API usage. AutoGPT's
classic era (`classic/`) added tool use (a hand-rolled JSON command protocol, later
migrated to native calls), pluggable vector-database long-term memory (Pinecone,
Milvus, Redis, Weaviate), and a `propose_action()`/`execute()` loop with only optional
human confirmation (`--continuous` mode removed it).

**What broke, as stated by the projects themselves.** AutoGPT's own survey documents
the outcome plainly: "they abandoned autonomy" — the project that defined "give it a
goal and walk away" concluded, with named and now well-documented failure modes (goal
drift, non-termination, unbounded cost, no reproducible or debuggable trace), that
unbounded recursive planning is not a product. The stated replacement thesis is
explicit in the product that followed: "humans design the boundaries, the LLM makes
choices inside them" — realized as a visual block/graph platform where the agent loop,
when present at all, is a literal drawn cycle in a dataflow graph with per-node cost
charging, typed I/O, and a scheduler that isolates node failure. AutoGPT's survey also
documents the specific, cited reason the vector-database long-term memory was dropped:
"retrieved fragments were rarely the ones that mattered, and the recency/causality
structure of an agent trajectory is not what similarity search preserves" — replaced by
an ordered episodic log plus recency-window-and-summarization, which the survey states
"works better" while being "structurally simpler."

**The same arc repeats, independently, in several later projects that started with
comparable ambitions.** MetaGPT's paper thesis (`Code = SOP(Team)`, a fixed
five-role waterfall pipeline wired by static message subscriptions) is, per that
survey, "no longer the default" in the current codebase — it is switched off
(`use_fixed_sop: bool = False`) in favor of `RoleZero`, an LLM-routed ReAct agent with
a JSON command protocol. AutoGen's v0.2 conversation-first design (an LLM decides who
speaks and what runs) was rewritten from the ground up for v0.4 after community
feedback identified three concrete problems, stated in the v0.4 architecture-preview
post: "limited flexibility" (developers wanted "predictable, ordered workflows," which
the conversation metaphor made awkward), "debugging complexity" (behavior scattered
across `register_reply` callbacks with no single observation point), and
"customization constraints" (agent identity tied to an in-process Python object).
AutoGen is now itself in maintenance mode, its orchestration abstractions absorbed into
Microsoft Agent Framework while the distributed actor runtime did not survive — a
transition the survey reads as evidence "the elaborate runtime was over-built for what
agent applications actually needed," explicitly marked as inference rather than a
stated fact from Microsoft. OpenHands' V0→V1 rewrite states its reasons directly for
deleting the pub/sub `EventStream`: "no clear message-ordering guarantees,"
"threading bugs and hard-to-debug interleaving," and that it was "designed... before
things like tool use and MCP were even invented" and no longer matched the domain — but
notably V1 *kept* event-sourcing itself (the append-only log with deterministic replay
was "strengthened," per that survey; only the asynchronous multi-publisher delivery on
top of it was cut). OpenHands V1 also reversed mandatory Docker sandboxing to
in-process-by-default, citing crash-coupling between agent and sandbox and multi-tenant
resource exhaustion under shared containers. CAMEL's `RolePlaying`→`Workforce`
transition and OpenAI's Swarm→Agents SDK transition (Swarm's own README calls itself
"experimental, educational," explicitly directing production users to the SDK, whose
gaps are characterized in the survey as "no tracing, no guardrails, no retries, no
streaming-friendly architecture, no session management") both follow the identical
shape: a minimal, elegant core is shipped first, and the production system that
replaces or wraps it is a documented list of exactly the infrastructure the minimal
version lacked.

**A partial counter-current: SWE-agent's own successor questions whether the
correction was still needed once models improved.** SWE-agent's central 2024 thesis —
that models need a small, heavily curated, empirically-tuned agent-computer interface
because raw bash and human-optimized tools are the wrong substrate for an LLM — is the
inverse move from the AutoGPT/AutoGen/OpenHands arc: it is *added* scaffolding, backed
by ablations showing measurable score deltas (a purpose-built linted editor beating raw
bash edits by 7.7 points; a naive IDE-style iterative search underperforming *no
search tool at all* by 6.0 points). But the same team's later `mini-swe-agent`
(explicitly by the SWE-agent authors) removes nearly all of that curated interface —
bash only, stateless per-call `subprocess.run`, linear unprocessed message history —
and reports higher SWE-bench Verified scores than the original curated-ACI numbers.
The survey states the authors' own framing: they "questioned whether the complex
architecture was still necessary as models improved," and reads the shift as evidence
that "the deficits [the ACI] compensated for were model deficits, and models moved" —
not that the original ablation findings were wrong for the models they were measured
against.

**What the arc collectively shows, grounded in what the surveyed projects say about
themselves.** Every project in this survey that documents a full rewrite or retraction
(AutoGPT, AutoGen, MetaGPT, OpenHands, CAMEL, OpenAI's Swarm→SDK, Semantic Kernel's
removal of planners) names infrastructure and control-flow concerns — termination,
cost bounds, debuggability, reproducibility, session management, observability — as
the reason, not model capability or prompt quality. The Claude Code survey's own
framing of that project's design (written to explain a project built well after this
arc had already played out at least once elsewhere) makes the same claim as a stated
premise rather than a discovered lesson: it measures the surveyed codebase as
"~1.6% AI decision logic and ~98.4% infrastructure," and states the harness exists to
create "conditions... under which the model can decide well," predicting that "as
frontier models converge in practical capability... the quality of the surrounding
operational harness becomes the principal differentiator." Whether that forward claim
holds is not something any of the 26 surveys can establish; what they do establish, in
each project's own documented history, is that every attempt to let the model own more
of the control flow than a bounded, observable, reproducible loop eventually
accumulated the same list of missing infrastructure and was walked back or wrapped.
