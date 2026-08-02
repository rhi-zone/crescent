# Prior art survey: Goose (block/goose)

Survey date: 2026-08-02. Sourcing convention used throughout: claims marked
**[src]** were read from the repository source via the GitHub API; claims marked
**[doc]** come from official docs; claims marked **[2nd]** come from DeepWiki or
blog posts and are secondary — treat them as unverified against source.

## Overview

Goose is an open-source, general-purpose AI agent runtime from Block (Square),
Apache 2.0, written in Rust, ~52k GitHub stars at survey time. It ships as a
native desktop app, a CLI, and an API/SDK, running entirely on the user's
machine and connecting out to any of 15+ LLM providers (Anthropic, OpenAI,
Google, Ollama, OpenRouter, Azure, Bedrock, and ACP-based subscription
providers). It is now governed under the Agentic AI Foundation at the Linux
Foundation. [doc]

The positioning decision that shapes everything else: Goose is deliberately
*not* a coding agent. It is a small configurable agent runtime whose entire tool
surface is MCP servers, so "adding a capability" is a config entry rather than a
code change. Coding is one workload among research, writing, automation, and
data analysis. [doc]

Workspace layout is a Rust cargo workspace of ~13 crates: `goose` (core
runtime), `goose-cli`, `goose-mcp`, `goose-providers` / `goose-provider-types`,
`goose-sdk` / `goose-sdk-types`, `goose-local-inference`, `goose-acp-macros`,
`goose-download-manager`, plus test-support crates. [src]

## Architecture

Three-part split: **interface** (desktop or CLI) collects input and renders
output; **agent** runs the core interactive loop; **extensions** provide tools.
[doc]

The loop, as documented: user request → send request + tool schemas to provider
→ provider emits tool calls → Goose executes them and collects results → results
returned to model → context revision drops irrelevant material → model produces
the final response, repeating whenever more tool calls appear. [doc]

Source-level detail on the loop, from `crates/goose/src/agents/agent.rs` [src]:

- `Agent::reply` → `reply_impl` → `reply_internal`, with the driving `loop {}` at
  roughly line 2092 in a ~4700-line file.
- Turn budget: `DEFAULT_MAX_TURNS: u32 = 1000`, overridable per session config
  or via `GOOSE_MAX_TURNS`. On exhaustion the agent does not abort silently — it
  emits a fixed message ("I've reached the maximum number of actions I can do
  without user input. Would you like me to continue?") and yields to the user.
- Empty-turn handling is explicit: `MAX_EMPTY_TURN_RETRIES: u32 = 3` retries a
  turn where the model returned nothing rather than treating it as completion.
- A free function `categorize_tool(tool_name: &str) -> ToolCategory` classifies
  tool calls into `Shell` / `Read` / `Write` / `Other`. Its tests assert it works
  off *conventional naming*, not a registry: `developer__shell` → Shell,
  `filesystem__write` and `filesystem__edit` → Write, `filesystem__read`,
  `filesystem__view`, `filesystem__cat` → Read, `scheduler__list` → Other. This
  is a naming-convention-driven classifier over an open tool namespace — a
  notable tradeoff (works for unknown third-party MCP servers, but is a
  heuristic over strings).

Error handling is a deliberate decision: rather than aborting the loop, Goose
"captures and handles traditional errors along with execution errors" and feeds
them back as tool responses so the model can self-correct. [doc]

Additional runtime concerns that live in the core crate, visible from the module
list [src]: `hooks/`, `scheduler.rs` + `scheduler_trait.rs` (cron-style
scheduled runs), `elicitation.rs` and `action_required_manager.rs` (structured
requests back to the human mid-run), `retry.rs`, `otel/` + `posthog.rs` +
`gen_ai_telemetry.rs` (observability), `token_counter.rs`, `skills/`,
`plugins/`, `gateway/`, `acp/`.

## Tool-Calling Protocol

Every tool reaches the model through MCP. There is no separate native tool
plugin API for third parties — the decision is "MCP or nothing," with 70+
documented extensions. [doc] Internally the runtime speaks `rmcp` types
(`rmcp::model::Tool`, `CallToolResult`, `ContentBlock`, `ToolAnnotations`)
throughout, so built-in tools and remote MCP servers are the same type. [src]

`ExtensionConfig` in `crates/goose/src/agents/extension.rs` is a serde-tagged
enum with these variants [src]:

- `stdio` — subprocess MCP server (`cmd`, `args`, `envs`, `env_keys`, `timeout`,
  `cwd`, `bundled`, `available_tools`).
- `streamable_http` — MCP Streamable HTTP, with `uri`, `headers`, and notably an
  optional `socket` field routing the HTTP connection over a Unix domain socket
  (`@name` for Linux abstract sockets) while `uri` still supplies the Host
  header and path.
- `builtin` — part of the bundled goose MCP server.
- `platform` — runs *in the agent process* with direct access to the agent
  itself. This is the escape hatch for tools that need runtime introspection.
- `frontend` — tools whose implementation lives in the UI and are called back
  through the frontend.
- `inline_python` — Python source embedded in config, executed via `uvx`, with a
  `dependencies` list.
- `sse` — retained only for config-file backwards compatibility; explicitly
  marked no longer supported.

Two cross-cutting decisions visible in that enum: `available_tools` on every
variant allows narrowing a server's exposed tool set (context-budget control at
the config layer, not the prompt layer), and `timeout` is per-extension.

Notable hardening in the same file: `Envs::DISALLOWED_KEYS` is a hardcoded
31-entry denylist of environment variables an extension config may not override
— `PATH`, `PATHEXT`, `SystemRoot`, `windir`, the whole `LD_*` family
(`LD_PRELOAD`, `LD_AUDIT`, `LD_LIBRARY_PATH`, …), the macOS `DYLD_*` family,
runtime-hijack vars (`PYTHONPATH`, `PYTHONHOME`, `NODE_OPTIONS`, `RUBYOPT`,
`GEM_PATH`, `GEM_HOME`, `CLASSPATH`, `GO111MODULE`, `GOROOT`), and Windows
process/DLL vectors (`APPINIT_DLLS`, `ComSpec`, `TEMP`, `TMP`, `LOCALAPPDATA`,
`USERPROFILE`, `HOMEDRIVE`, `HOMEPATH`). Disallowed keys are skipped with a
warning rather than rejected. [src] The threat model here is explicitly *a
malicious or compromised extension config*, not a malicious model.

Platform extensions registered in `PLATFORM_EXTENSIONS` (a `Lazy<HashMap>` of
`PlatformExtensionDef { name, display_name, description, default_enabled,
unprefixed_tools, hidden, client_factory }`) [src]:

| name | default on | purpose |
| --- | --- | --- |
| `analyze` | yes | tree-sitter code structure: dir overviews, file detail, symbol call graphs |
| `todo` | yes | agent-maintained todo list |
| `apps` | yes | create/manage HTML/CSS/JS "Goose apps" that run in sandboxed windows |
| `chatrecall` | no | search past conversations, load session summaries as contextual memory |
| `extensionmanager` | yes | discover/enable/disable extensions at runtime |
| `summon` | yes | load knowledge and delegate tasks to subagents |
| `summarize` | no | load files/dirs and get an LLM summary in one call |
| `code_execution` ("Code Mode") | no, feature-gated | make extension calls through generated code instead of individual tool calls, to save tokens |

`unprefixed_tools` is a per-extension flag controlling whether tools appear as
`ext__tool` or bare — i.e. the namespacing convention that `categorize_tool`
keys off is itself configurable.

Large tool results are handled outside the model's context. `large_response_handler.rs`
[src]: any text content block over `GOOSE_MAX_TOOL_RESPONSE_SIZE` (default
`200_000` characters) is written to a temp file, and the model receives a
message stating the size and the file path, told to use other tools to examine
or search it. Non-text content blocks pass through unchanged. If the file write
fails, it falls back to inlining the full content with a warning — a deliberate
choice to never lose data to a spill failure.

Code Mode (`platform_extensions/code_execution.rs`) [src] is the most unusual
tool-calling decision: instead of the model emitting one tool call per action,
it emits TypeScript or bash to run against a registry of tool bindings
(`pctx_code_mode` with `ExecuteTypescriptInput`, `ExecuteBashInput`,
`GetFunctionDetailsInput`, `ToolDisclosure` levels for progressive schema
disclosure). The input type carries an explicit `tool_graph: Vec<ToolGraphNode>`
— each node is `{ tool: "server/tool", description, depends_on: Vec<usize> }` —
so the model declares the DAG of tool calls its code will perform. That
declared DAG is what the permission and audit layers can inspect, which is the
answer to the obvious objection that code-mode defeats per-call approval.

## Context/Memory Management

Two tiers, by design [doc]:

1. **Auto-compaction.** Proactive summarization of older conversation when
   approaching the token limit. Threshold is 80% by default —
   `DEFAULT_COMPACTION_THRESHOLD: f64 = 0.8` in
   `crates/goose/src/context_mgmt/mod.rs` [src] — tunable via
   `GOOSE_AUTO_COMPACT_THRESHOLD`, disabled with `0.0`.
2. **Context strategies**, the fallback if the limit is still exceeded after
   compaction: `summarize`, `truncate` (drop oldest, CLI only), `clear` (reset
   session, CLI only), or `prompt` (ask the user). Selected via
   `GOOSE_CONTEXT_STRATEGY`; interactive mode defaults to prompting, headless
   defaults to summarization. [doc]

Compaction is structured, not free-text. `context_mgmt/structured.rs` defines
`StructuredSummary` [src] with fields `user_intent`, `technical_concepts`,
`files: Vec<FileActivity { path, summary, key_code }>`, `errors_and_fixes`,
`problem_solving`, `user_messages`, `pending_tasks`, `current_work`,
`next_step`, plus a `#[serde(flatten)] extra` map. Two decisions are documented
in that file's comments and worth stealing:

- Every list is **ordered most-important-first**, explicitly so that consumers
  (the render template, truncation experiments) can cut from the tail.
- Deserialization is **deliberately lenient**: omitted fields default to empty,
  and an object or number where a string was expected is stringified rather than
  erroring, "because models routinely enrich the schema … and one such field
  must not discard a good summary." The `extra` flatten map exists so a
  user-customized compaction prompt that adds fields can still reach them from a
  customized render template.

Compaction is not just history-wide: `TOOLCALL_SUMMARIZATION_BATCH_SIZE = 10`
and a `GOOSE_TOOL_PAIR_SUMMARIZATION` flag (default on) summarize
request/response tool pairs in batches. [src] `CompactionResult` separates
*billable* usage of the summarization call from `retained_context_tokens`, the
agent-visible context actually kept — an accounting distinction that matters
because the raw model output is rewritten to a rendered structured summary. [src]

After compaction the agent is injected with one of three continuation strings
depending on situation (conversation continuation, tool-loop continuation,
manual `/compact` continuation), each instructing the model *not to mention*
that summarization occurred and to continue naturally. [src]

Longer-term memory is a separate, opt-in concern: the `chatrecall` platform
extension searches past conversations and loads session summaries; it is
`default_enabled: false`. [src]

Sessions persist in **SQLite** (`sessions.db`) via `sqlx` with incremental
schema migrations (v13 at the time DeepWiki indexed it), storing conversation
history, token usage, working directory, associated recipes, provider metadata,
extension state, and accumulated cost. Session IDs are `YYYYMMDD_N`. Lifecycle
operations are create / resume / **fork** (`copy_session()`, optionally
truncating at a timestamp) / delete. Sessions export to JSON and can be shared
over encrypted Nostr via `goose://sessions/nostr` deeplinks. [2nd]

## Sandboxing & Permissions

There is no OS-level sandbox by default. The model's tool calls run with the
user's own privileges; safety is enforced by an approval pipeline plus
inspectors. (`agents/container.rs` is a two-field newtype wrapping a Docker
container ID [src] — container support exists but is not the ambient isolation
model.)

**GooseMode**, session-wide, four levels [2nd, consistent with `GooseMode` uses
in source]:

- `Chat` — tool use disabled entirely.
- `Auto` — all tools run unrestricted.
- `Approve` — every tool call needs explicit confirmation unless pre-approved.
- `SmartApprove` — read-only tools auto-approve; state-changing ones ask.

`SmartApprove` is the interesting one. Read-only-ness is determined two ways:
first from MCP `read_only_hint` tool annotations (`apply_tool_annotations`
updates the cache from tool metadata), and where annotations are absent, by a
**PermissionJudge** — a separate LLM call that classifies the specific tool call
semantically (a `SELECT` is safe, an `INSERT` or a file write is not), receiving
its verdict through a temporary tool named
`platform__tool_by_tool_permission`. [2nd]

`PermissionManager` holds state in a `RwLock<HashMap>` and persists to
`$CONFIG_DIR/permission.yaml` (typically `~/.config/goose/permission.yaml`),
splitting entries into `user` (explicit human choices) and `smart_approve`
(cached LLM/annotation decisions) — so a machine-inferred verdict is never
confused with a human one. Levels are `always_allow`, `ask_before`,
`never_allow`. [2nd]

Above permissions sits a **general tool-inspection pipeline**, and this is the
structurally cleanest part of the design [src, `crates/goose/src/tool_inspection.rs`]:

```rust
pub enum InspectionAction { Allow, Deny, RequireApproval(Option<String>) }

pub struct InspectionResult {
    pub tool_request_id: String,
    pub action: InspectionAction,
    pub reason: String,
    pub confidence: f32,
    pub inspector_name: String,
    pub finding_id: Option<String>,
}

#[async_trait]
pub trait ToolInspector: Send + Sync {
    fn name(&self) -> &'static str;
    async fn inspect(&self, session_id: &str, tool_requests: &[ToolRequest],
                     messages: &[Message], goose_mode: GooseMode)
        -> Result<Vec<InspectionResult>>;
    fn is_enabled(&self) -> bool { true }
    fn as_any(&self) -> &dyn std::any::Any;
}
```

`ToolInspectionManager` holds `Vec<Box<dyn ToolInspector>>` and runs them **in
registration order**, collecting all results; an inspector that errors is logged
and does not abort the pipeline. Permissions are just one inspector
(`PermissionInspector`) among several. Every verdict carries a `confidence: f32`
and an optional `finding_id`, so decisions are auditable rather than opaque
booleans.

Registered inspectors in `crates/goose/src/security/` [src]: `security_inspector`
(prompt-injection detection over tool requests *and* prior messages, escalating
to `RequireApproval` with a "🔒 Security Alert" message carrying the explanation
and finding ID), `adversary_inspector`, `egress_inspector` (regex-extracts URLs
and network destinations out of shell commands and classifies them
outbound/inbound/unknown — i.e. data-exfiltration detection at the command-text
level), plus `scanner` (`PromptInjectionScanner`), `patterns`, and
`classification_client` (an ML classifier). All of the security scanning is
**off by default**: `SECURITY_PROMPT_ENABLED`, `SECURITY_PROMPT_CLASSIFIER_ENABLED`,
`SECURITY_COMMAND_CLASSIFIER_ENABLED` all default to `false`, each with a
`*_OVERRIDE` env var. [src]

Separately, `agents/extension_malware_check.rs` [src] and
`Recipe::check_for_security_warnings` [src] — the latter scans a recipe's
`instructions`, `prompt`, and `activities` for **Unicode tag characters**, the
invisible-character prompt-injection vector, since recipes are meant to be
downloaded and shared.

## Multi-Agent Support

Goose deliberately ships **two distinct** delegation mechanisms rather than one
general one, and the docs treat choosing between them as a real decision. [2nd]

**Recipes** are the durable unit: a portable YAML document. From
`crates/goose/src/recipe/mod.rs` [src], `Recipe` carries `version` (semver of the
file format), `title`, `description`, `instructions`, `prompt`, `extensions:
Vec<ExtensionConfig>`, `settings: Settings { goose_provider, goose_model,
temperature, max_turns }`, `activities` (UI suggestion pills), `author`,
`parameters: Vec<RecipeParameter { key, input_type, requirement, description,
default, options }>`, `response: Response { json_schema }` for structured
output, `sub_recipes`, and `retry: RetryConfig`.

The load-bearing decision, stated plainly in the ecosystem writeups: **the agent
does not decide which tools to load — the recipe does.** [2nd] Tool surface is a
static property of the workflow definition, not something the model negotiates
at runtime. A recipe pins its provider and model too, so a workflow is
reproducible across machines and people. Block reportedly scaled Goose to ~60%
of the company on the strength of the recipe file being the shareable unit. [2nd]

`SubRecipe { name, path, values: HashMap<String,String>,
sequential_when_repeated: bool, description }` [src] — a sub-recipe is a *path
reference plus bound parameter values*, and the only concurrency control is one
boolean forcing sequential execution when the same sub-recipe is repeated.
Sub-recipes run in isolated worker processes. [2nd]

**Subagents** are the ephemeral unit: spawned Goose instances that inherit the
current session's context and extensions, invoked by natural language ("use 2
subagents to create hello.html and goodbye.html in parallel") with no config
step. Constraints, per docs [2nd/doc]: subagents **cannot spawn subagents**
(explicit recursion prevention), cannot modify extensions, cap at **10
concurrent** instances, and share no state — the stated reason no-shared-state is
a feature, since it removes conflicts under parallelism. Extensions are
inherited by default but can be narrowed by natural language or recipe config.
Return mode is configurable: full detail (all tool executions) or summary only,
so the parent's context isn't flooded. Both mechanisms are still labelled
experimental. [2nd]

The delegation surface itself is a platform extension, `summon` ("Load knowledge
and delegate tasks to subagents", `default_enabled: true`) [src], with wiring in
`agents/subagent_handler.rs`, `subagent_task_config.rs`, and
`subagent_execution_tool/`. `Recipe::ensure_summon_for_subrecipes` auto-injects
the `summon` extension whenever a recipe declares `sub_recipes` [src] — a
recipe author never has to remember the plumbing. The parallel decision
`ensure_analyze_for_developer` auto-injects the `analyze` extension when a recipe
uses the legacy builtin `developer` extension without it. Both are migration
affordances baked into deserialization.

A separate axis is **lead/worker model splitting**: `GOOSE_LEAD_MODEL` (with
optional `GOOSE_LEAD_PROVIDER`, defaulting to the main provider) plus
`GOOSE_WORKER_MODEL` route planning to an expensive model and execution to a
cheap one, within a single agent. `GOOSE_PLANNER_PROVIDER` / `GOOSE_PLANNER_MODEL`
do the same for the CLI `/plan` command. [2nd]

## Notable Design Decisions

1. **MCP as the only tool surface, with graduated escape hatches.** Third
   parties get MCP or nothing, which keeps the extension ecosystem portable. But
   the runtime keeps `platform` extensions that run in-process with direct agent
   access, and `frontend` extensions implemented in the UI — the escape hatches
   are typed variants of the same enum rather than a parallel plugin API.
2. **Tool inspection is a pluggable pipeline, not a permission check.**
   Permissions, prompt-injection scanning, egress/exfiltration detection, and
   adversary detection are all `ToolInspector`s over a shared
   `Allow | Deny | RequireApproval` verdict carrying a confidence score and a
   finding ID. New safety concerns are added as inspectors.
3. **LLM-in-the-loop as a policy engine.** `SmartApprove` uses a second model
   call (PermissionJudge) to classify a tool call's read-only-ness when
   annotations are missing, and caches the verdict separately from human
   decisions.
4. **Structured compaction with an explicit importance ordering and
   deliberately lenient parsing.** The summary is a typed record with
   most-important-first lists so truncation has a defined cut point, and schema
   drift from the model degrades a field rather than discarding the summary.
5. **Large tool outputs spill to disk, not to context.** Over 200k chars, the
   model gets a path and is told to search the file with other tools.
6. **Code Mode with a declared tool DAG.** The model writes TypeScript/bash
   against tool bindings instead of emitting individual calls, and declares
   `tool_graph: [{ tool, description, depends_on }]` alongside — preserving
   inspectability of a batched execution.
7. **Recipes pin the tool set, provider, and model; the agent doesn't choose.**
   Reproducibility over autonomy for the durable workflow unit.
8. **Two delegation primitives, kept distinct.** Ephemeral in-session subagents
   (natural-language, inherit context, no recursion, ≤10 concurrent) vs durable
   file-based subrecipes (isolated processes, bound parameters). Neither is
   expressed in terms of the other.
9. **Extension configs are treated as an attack surface.** A 31-entry
   environment-variable denylist blocks linker/interpreter hijacking, recipes are
   scanned for invisible Unicode tag characters, and extensions get a malware
   check.
10. **Security scanning ships off by default.** Every prompt-injection and
    command classifier defaults to `false` with an explicit override env var — a
    cost/latency call, and a notable admission that the scanners aren't
    accurate enough to be ambient.
11. **Turn budget yields to the human rather than aborting.** 1000 turns by
    default, then a fixed "would you like me to continue?" message; empty model
    turns get 3 retries rather than being read as completion.
12. **Errors are conversation, not control flow.** Tool and execution errors go
    back to the model as tool responses so it can self-correct.
13. **Tool classification by naming convention.** `categorize_tool` derives
    Shell/Read/Write/Other from the tool name string across an open namespace —
    scales to unknown MCP servers, but is a heuristic, and the `unprefixed_tools`
    per-extension flag means the convention it keys on is itself configurable.
14. **Lead/worker model split as configuration.** Cost control by routing
    planning and execution to different models via env vars, no code change.
15. **Sessions in SQLite with fork.** Migration-versioned schema, forking at a
    timestamp, cost accumulation as a first-class field. [2nd]

## Relevance to Crescent

Crescent's current state, for grounding: `lib/ai/` is a lazy provider registry
(`init.lua`, `providers/{anthropic,openai,openai_compat,google}.lua`,
`types.lua`) plus `lib/ai/tools.lua`, whose `mod.run` is a bounded loop —
`max_rounds` default 10 — that calls `ai.generate`, dispatches tool calls
through an `opts.handlers` table keyed by tool name via `pcall`, appends results
as messages, and stops when a response carries no tool calls. `lib/taskgraph/`
provides graph/exec/frontier/combinators, and `lib/platform/apps/` already hosts
six apps.

Observations relevant to designing an agent app and expanding `lib/ai`. These
are read-offs from Goose's decisions, not recommendations — the tradeoffs are
listed, the calls are not made here.

- **The gap between `tools.lua` and a harness is mostly non-loop machinery.**
  Goose's loop is recognizably the same shape as `mod.run`; what surrounds it —
  inspection pipeline, compaction, session persistence, turn budgeting with
  human handback, error-as-tool-response — is where the 4700 lines went. The
  decomposition question for crescent is which of those become separate `lib/`
  modules versus parts of the app.
- **`ToolInspector` is directly expressible in Lua and matches crescent's
  conventions.** A list of inspectors, each `(tool_calls, messages, mode) ->
  results`, each result `{ action = "allow" | "deny" | "require_approval",
  reason, confidence, inspector }`, run in order, errors logged not fatal. It
  keeps permissions from being special-cased into the loop, which is the
  structural failure the no-special-casing constraint targets. Cost: a second
  abstraction layer over what is currently a direct handler dispatch.
- **Caps-first is a sharper answer than Goose has.** Goose's env-var denylist
  and inspector stack are mitigations for tools that inherit the user's full
  privileges. Crescent's injected-caps rule means a tool handler can only reach
  what it was handed. Goose's inspection pipeline and crescent's cap injection
  solve overlapping problems from opposite ends; whether crescent needs
  inspection *as well* depends on whether the model can select which caps a
  handler receives.
- **`max_rounds = 10` versus Goose's 1000-plus-handback are different products.**
  A hard low cap is a library default; a high cap with a human-facing "continue?"
  message is a harness affordance. If `lib/ai/tools.lua` stays a library and the
  harness lives in an app, the handback belongs in the app.
- **Structured compaction is the transferable memory idea.** A typed summary
  record with most-important-first lists and lenient parsing is a design that
  survives being reimplemented in Lua; the SQLite session store is not (crescent
  is zero-dependency, and Goose's sqlx/migrations stack has no analogue).
  Whether crescent needs persistence at all, and in what format, is an open
  question this survey does not answer.
- **Large-response spill-to-file needs a cap.** The pattern (over N chars, write
  to a path, hand the model the path) is cheap, but under caps-first the writer
  needs an injected filesystem cap, and the model then needs a read/search tool
  pointed at the same place.
- **The recipe/subagent split maps onto taskgraph unevenly.** `lib/taskgraph`
  already has the durable-graph half — nodes, dependencies, a frontier — which
  is closer to subrecipes (declared DAG, bound parameters, isolated execution)
  than to subagents (ephemeral, natural-language, context-inheriting). Goose's
  decision to keep the two mechanisms distinct rather than expressing one in
  terms of the other is the point worth weighing before assuming taskgraph
  should carry both.
- **Recipe-pins-the-tool-set versus model-selects-tools is a genuine open
  branch.** Goose picked reproducibility. It costs autonomy, and it requires a
  recipe format with a version field and a migration story (the
  `ensure_summon_for_subrecipes` / `ensure_analyze_for_developer` auto-injection
  is what that migration story looks like in practice).
- **Code Mode's declared `tool_graph` is the notable idea for a taskgraph-shaped
  system.** It is a model-emitted DAG of intended tool calls, which is both the
  execution plan and the audit surface — structurally close to what
  `lib/taskgraph` already represents.

## Sources

Repository and source files (read via the GitHub contents API, 2026-08-02):

- https://github.com/block/goose
- `crates/goose/src/agents/agent.rs`
- `crates/goose/src/agents/extension.rs`
- `crates/goose/src/agents/platform_extensions/mod.rs`
- `crates/goose/src/agents/platform_extensions/code_execution.rs`
- `crates/goose/src/agents/large_response_handler.rs`
- `crates/goose/src/agents/container.rs`
- `crates/goose/src/tool_inspection.rs`
- `crates/goose/src/security/{mod,security_inspector,egress_inspector}.rs`
- `crates/goose/src/context_mgmt/{mod,structured}.rs`
- `crates/goose/src/recipe/mod.rs`

Official documentation:

- https://goose-docs.ai/
- https://goose-docs.ai/docs/goose-architecture/
- https://goose-docs.ai/docs/guides/sessions/smart-context-management/
- https://goose-docs.ai/docs/guides/recipes/
- https://goose-docs.ai/docs/guides/context-engineering/subagents/
- https://block.github.io/goose/docs/guides/tool-permissions/

Secondary (unverified against source):

- https://deepwiki.com/block/goose/6.1-permission-system-architecture
- https://deepwiki.com/block/goose/6.2-permission-modes-and-tool-approval
- https://deepwiki.com/block/goose/4.3-session-management
- https://block.github.io/goose/blog/2025/09/26/subagents-vs-subrecipes/
- https://www.pulsemcp.com/building-agents-with-goose
- https://maxamillion.sh/blog/stop-building-agents-start-harnessing-goose/
- https://the-agent-report.com/2026/05/block-goose-ai-agent-recipe-runner-scaled-60-percent/
