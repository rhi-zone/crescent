# Continue.dev — prior-art survey

Survey of `github.com/continuedev/continue` as prior art for an agentic harness.
Read against a shallow clone at HEAD `5522c6f4` (2026-07-20). All file paths below
are relative to that repo, not to crescent.

## Overview

Continue is a coding agent shipped as three front-ends over one shared TypeScript
core: a VS Code extension, a JetBrains plugin, and a CLI (`extensions/vscode`,
`extensions/intellij`, `extensions/cli`). Apache-2.0, ~35k stars.

**The repository is archived.** The README states: "the `continuedev/continue`
repository is no longer actively maintained and is read-only for all users",
following a final 2.0.0 release of all three front-ends. This matters for a survey:
what is in the tree is the *end state* of ~2 years of iteration, including its
unresolved internal contradictions (see "Two harnesses" below), and no further
convergence will happen.

Top-level layout:

- `core/` — shared engine: LLM providers, context providers, tools, indexing, config.
- `gui/` — React + Redux webview; the IDE agent loop lives here, in Redux thunks.
- `extensions/{vscode,intellij,cli}` — hosts.
- `packages/` — separately-published npm packages: `config-yaml`, `config-types`,
  `openai-adapters`, `llm-info`, `fetch`, `terminal-security`, `continue-sdk`.
- `sync/` — a Rust component (Cargo workspace) alongside the TS core.

## Architecture

### The IDE agent loop lives in the UI's state manager

The chat/agent loop is not a library function in `core/`. It is a set of Redux
thunks in `gui/src/redux/thunks/`, principally `streamNormalInput.ts` and
`streamResponseAfterToolCall.ts`. The cycle is mutual recursion between two thunks:

- `streamNormalInput({ depth })` assembles tools, system message, and messages;
  streams the completion; then marks generated tool calls and dispatches execution.
- `streamResponseAfterToolCall({ toolCallId, depth })` appends the `role: "tool"`
  message, checks `areAllToolsDoneStreaming(...)`, and if so calls
  `streamNormalInput({ depth: depth + 1 })`.

So conversation state *is* Redux state, and "agent step" is a dispatched action.
This is a real architectural decision with a real cost: the loop is not reusable
outside the webview, which is why the CLI had to grow its own (below).

**The loop is effectively unbounded.** The only depth check is test-only:

```ts
if (process.env.NODE_ENV === "test" && depth > 50) { ... throw ... }
```

In production there is no max-turn cap; termination is "the model stopped emitting
tool calls" plus user cancellation. Cancellation is cooperative and checked per
chunk against Redux state, not only the abort signal:

```ts
while (!next.done) {
  if (!getState().session.isStreaming) { dispatch(abortStream()); break; }
  dispatch(streamUpdate(next.value));
  next = await gen.next();
}
```

### Two harnesses in one repo

The CLI (`extensions/cli/src/`) does **not** reuse the GUI loop. It has its own
stream driver (`src/stream/streamChatResponse.ts`), its own tool set
(`src/tools/allBuiltIns.ts`, PascalCase names: `Read`, `Write`, `Edit`, `Bash`,
`Search`, `Fetch`, `Skills`, `Checklist`, `AskQuestion`, `Exit`, `Task`-style
`subagent`), its own permission system (`src/permissions/`, vocabulary
`allow`/`ask`/`exclude`), and its own compaction (`src/compaction.ts`).

The core/GUI side has a *different* tool set (`core/tools/builtIn.ts`, snake_case:
`read_file`, `edit_existing_file`, `run_terminal_command`, `grep_search`, …) and a
*different* permission vocabulary (`allowedWithoutPermission` / `allowedWithPermission`
/ `disabled`, from `packages/terminal-security`).

These are two independent implementations of the same concept that never merged.
Shared substrate stops at the type definitions (`core/index.d.ts`), the provider
layer, and config parsing.

### Model/provider layer: two levels, deliberately

`core/llm/llms/` holds 81 provider entries — the "smart" layer that knows about
templates, capabilities, context lengths, dynamic API bases. Underneath,
`packages/openai-adapters` is a deliberately dumb translation layer. Its README
states the split explicitly:

> They are purely a translation layer, and are not concerned with: Templates /
> Whether a model supports tools, images, etc. / Dynamically changing API base …
> The goal is for this to change as infrequently as possible. It should only require
> updating when the actual API format changes.

The normalized wire format is the OpenAI chat-completions shape; every provider
converts in and out of it. The stated rationale for the separation is **rate of
change**: API wire formats change rarely, model metadata changes constantly, so
they are isolated so the stable thing does not get churned by the volatile thing.
Static model metadata is further split into `packages/llm-info`.

## Tool-Calling Protocol

### Tool type carries UI, policy, and prompt affordances together

`core/index.d.ts:1132` — the `Tool` interface wraps an OpenAI-shaped
`function: { name, description, parameters, strict }` with harness metadata:

```ts
displayTitle: string;
wouldLikeTo?: string;      // "read {{{ filepath }}}"    — pending phrasing
isCurrently?: string;      // "reading {{{ filepath }}}" — in-flight phrasing
hasAlready?: string;       // "read {{{ filepath }}}"    — completed phrasing
readonly: boolean;
isInstant?: boolean;
group: string;             // "Built-In" or MCP server name
systemMessageDescription?: { prefix: string; exampleArgs?: [string, string|number][] };
defaultToolPolicy?: ToolPolicy;
preprocessArgs?: (args, { ide }) => Promise<Record<string, unknown>>;
evaluateToolCallPolicy?: (basePolicy, parsedArgs, processedArgs?) => ToolPolicy;
mcpMeta?: McpToolMeta;
```

Three decisions are packed in here:

1. **Tense-triplet display strings** (`wouldLikeTo`/`isCurrently`/`hasAlready`) —
   the tool definition owns its own UI narration for all three lifecycle states,
   rather than the UI switching on tool name.
2. **`preprocessArgs`** — a per-tool argument-normalization hook that runs *before*
   policy evaluation, given IDE access (e.g. resolving a relative path to absolute
   so the policy can ask "is this inside the workspace?").
3. **`evaluateToolCallPolicy`** — permission is a *function of the arguments*, not
   a property of the tool. See Sandboxing.

### Tool result type is the same type as context-provider output

Tools return `ContextItem[]` (`core/index.d.ts:459`), which is exactly what context
providers return. Result rendering into a `role: "tool"` message goes through
`renderContextItems(toolOutput)`. Tool output and @-mention context are one type,
so anything that can be attached can also be returned by a tool.

### Tools are addressed by URI, which unifies built-in / MCP / HTTP

`core/tools/callTool.ts` dispatches on a URI scheme:

```ts
export function encodeMCPToolUri(mcpId: string, toolName: string): string {
  return `mcp://${encodeURIComponent(mcpId)}/${encodeURIComponent(toolName)}`;
}
```

`http:`/`https:` → POST `{ arguments }` to the URL, expecting `{ output: ContextItem[] }`.
`mcp:` → route through `MCPManagerSingleton`. Everything else → the built-in
implementation table. A remote tool and a local tool are the same kind of thing,
distinguished by URI scheme. A subset (`CLIENT_TOOLS_IMPLS`: the three edit tools)
is marked as executing client-side rather than in core.

### The distinctive one: a text fallback protocol for models without function calling

`core/tools/systemMessageTools/` is a complete second tool-calling protocol,
selected when `modelSupportsNativeTools(selectedChatModel)` is false
(`core/llm/toolSupport.ts` — a per-provider predicate table over model-name patterns):

```ts
const useNativeTools = state.config.config.experimental?.onlyUseSystemMessageTools
  ? false : modelSupportsNativeTools(selectedChatModel);
const systemToolsFramework = !useNativeTools
  ? new SystemMessageToolCodeblocksFramework() : undefined;
```

Wire format is a fenced code block with line-oriented delimiters, *not* JSON:

````
```tool
TOOL_NAME: read_file
BEGIN_ARG: filepath
"src/index.ts"
END_ARG
```
````

Tool *definitions* are injected the same way, as ```` ```tool_definition ```` blocks
with `TOOL_ARG: name (type, required)` lines — a hand-rolled schema serialization
rather than inlined JSON Schema.

The design choices inside this are the interesting part:

- **Line-delimited args instead of JSON** because multiline values (file contents,
  patches) survive without escaping. `BEGIN_ARG`/`END_ARG` framing lets an argument
  contain arbitrary newlines.
- **Streaming detection is prefix-based and forgiving.** `acceptedToolCallStarts`
  is a list of `[detected, rewritten]` pairs with a comment stating the rationale:

  ```ts
  // Poor models are really bad at following instructions, alternate starts allowed:
  acceptedToolCallStarts: [string, string][] = [
    ["```tool\n", "```tool\n"],
    ["tool_name:", "```tool\nTOOL_NAME:"],
  ];
  ```

  `detectToolCallStart.ts` distinguishes `isInToolCall` from `isInPartialStart`
  (buffer is a prefix of a start marker) so text is held back rather than leaked to
  the UI while a marker might still be forming. Malformed output is *repaired into*
  the canonical form rather than rejected.
- **Parallel tool calls were deliberately dropped** in this mode:
  `// TODO - include tool call id for parallel. Confuses dumb models`. Capability
  was traded away for reliability on weak models.
- `interceptSystemToolCalls.ts` wraps the raw stream generator and emits normal
  `ToolCallDelta`s, so the rest of the loop cannot tell which protocol was used.
  Synthetic OpenAI-style tool-call IDs are generated locally
  (`generateOpenAIToolCallId`). The parse state machine
  (`ToolCallParseState`, `types.ts`) is explicit and serializable.

This is the single most transferable idea in the repo: **the tool-calling protocol
is an injected strategy object (`SystemMessageToolsFramework`), not a hardcoded
assumption**, and the native path is just the case where no strategy is installed.

### Per-model tool overrides

`core/tools/applyToolOverrides.ts` + `ModelDescription.toolOverrides` lets a model
entry disable a tool or rewrite its description. Errors are classified fatal vs
non-fatal; non-fatal ones warn and continue.

## Context/Memory Management

### The context-provider contract

`core/context/index.ts` is 38 lines — the whole abstraction:

```ts
export abstract class BaseContextProvider implements IContextProvider {
  static description: ContextProviderDescription;
  abstract getContextItems(query: string, extras: ContextProviderExtras): Promise<ContextItem[]>;
  async loadSubmenuItems(args: LoadSubmenuItemsArgs): Promise<ContextSubmenuItem[]> { return []; }
  get deprecationMessage(): string | null { return null; }
}
```

A comment on `getContextItems` states the key invariant:

> Should never have to go back to the context provider once you have the information.

**Context resolution is one-shot and eager.** A provider is called once, returns
plain text items, and is then out of the picture — no lazy handles, no re-resolution
on later turns. Items are frozen into history at the turn where they were added.

Three provider types (`core/index.d.ts:181`) determine UI and invocation shape:

- `"normal"` — resolves immediately on @-mention (e.g. `@terminal`, `@problems`, `@os`).
- `"query"` — takes free-text after the mention (e.g. `@google <query>`).
- `"submenu"` — first `loadSubmenuItems()` populates a searchable list (files,
  docs, GitHub issues), then `getContextItems` resolves the picked id.

`dependsOnIndexing?: ContextIndexingType[]` lets a provider declare it needs
`"chunk" | "embeddings" | "fullTextSearch" | "codeSnippets"` so the UI can gate it
while indexing is incomplete.

`ContextProviderExtras` is the injected capability bundle — `config`, `llm`,
`embeddingsProvider`, `reranker`, `ide`, `fetch`, `selectedCode`, `isInAgentMode`.
Providers never reach for globals; the `fetch` and `ide` caps are passed in. (Note
for crescent: this is the same caps-first shape, arrived at independently.)

~30 built-in providers live in `core/context/providers/`.

### Extension seams, and the retreat from in-process providers

Three ways to add a provider: `CustomContextProvider` (a JS object with
`getContextItems`, from `config.ts`), `HttpContextProvider` (POST to a URL, return
`ContextItem[]`), and `MCPContextProvider`.

Continue's docs deprecate the bespoke in-process ones in favor of HTTP and MCP —
`GitHubIssuesContextProvider` is marked deprecated with a pointer to the GitHub MCP
server, and `docs/reference/deprecated-context-providers.mdx` exists. The
trajectory is: hand-written first-party providers → generic transports (HTTP, MCP).
The maintenance cost of ~30 first-party integrations was the forcing function.

### Retrieval is a pipeline, and it is both a provider and a tool

`core/context/retrieval/retrieval.ts` composes
`RerankerRetrievalPipeline` or `NoRerankerRetrievalPipeline`
(`pipelines/`) based on whether a reranker model is configured. Budgeting is
explicit and derived from the model rather than fixed:

```ts
const tokensPerSnippet = 512;
const nFinal = options?.nFinal ?? Math.min(DEFAULT_N_FINAL /* 25 */,
                                           contextLength / tokensPerSnippet / 2);
const nRetrieve = useReranking ? options?.nRetrieve || 2 * nFinal : nFinal;
```

"Fill at most half the context window with retrieved snippets; over-fetch 2× when a
reranker can cut it back down." Retrieval degrades rather than fails: with no
embeddings model configured it silently skips the embeddings leg and still returns
FTS results.

The same capability is exposed **twice**: as `CodebaseContextProvider` (user-driven
`@codebase`) and as `core/tools/implementations/codebaseTool.ts` (model-driven).
Same underlying pipeline, two invocation modalities — the human decides in chat
mode, the model decides in agent mode.

### Indexing: content-addressed, branch-tagged, four artifacts

`core/indexing/README.md` documents the design directly. Files are keyed by
`cacheKey` = hash of contents; a SQLite catalog tracks per-file mtimes; a diff
against the catalog yields four lists — `compute`, `delete`, `addTag`, `removeTag`
— which every `CodebaseIndex` implementation consumes.

The decision worth stealing: **branch switching is a tagging operation, not a
re-index**. If a file's content hash already exists from another branch, indexing it
on this branch only adds a tag. Progress is yielded incrementally so a mid-indexing
crash does not falsely record completion.

Four artifacts: `ChunkCodebaseIndex` (structure-aware recursive chunking),
`LanceDbIndex` (embeddings; one LanceDB table per tag), `FullTextSearchCodebaseIndex`
(SQLite FTS5), `CodeSnippetsCodebaseIndex` (tree-sitter queries for top-level
declarations). LanceDB is a native module and is imported dynamically behind a CPU-
target check (`isSupportedLanceDbCpuTargetForLinux`) so an unsupported host loses
embeddings but keeps FTS. The README also lists known problems honestly — FTS does
not differentiate tags, so results may leak across branches.

### Two different memory strategies, one per harness

**IDE (`core/llm/countTokens.ts`, `compileChatMessages`): drop oldest, never
summarize.** The budget is computed as

```
inputTokensAvailable = contextLength − countingSafetyBuffer − minOutputTokens
                       − toolTokens − systemMsgTokens − lastMessagesTokens
```

where `lastMessagesTokens` covers a "tool sequence" extracted from the tail
(`extractToolSequence`). Those four subtractions are the **non-negotiable** set —
if they alone overflow, it throws "Not enough context…" rather than degrading, and
the UI surfaces `out-of-context`. Otherwise messages are `shift()`ed off the front
until under budget, with an important invariant repair:

```ts
while (historyWithTokens[0]?.role === "tool") { /* drop orphaned tool results */ }
```

A tool result whose originating call was just pruned is dropped too, so the history
never contains a dangling `role: "tool"`. The function returns
`{ compiledChatMessages, didPrune, contextPercentage }` — pruning is *reported to
the UI*, not silent, and `contextPercentage` drives a live context-usage meter.

**CLI (`extensions/cli/src/compaction.ts`): summarize.** Auto-compaction triggers
at `AUTO_COMPACT_BUFFER_RATIO = 0.8` of the limit, buffer capped at
`AUTO_COMPACT_BUFFER_CAP = 15_000` tokens. A dedicated prompt asks the model to
summarize the conversation, explicitly instructing it to preserve *the current
stream of work at the end* so the agent can resume without losing its place, and to
skip the system message since that persists. The result yields a
`compactionIndex` into history. Token counting uses `gpt-tokenizer` directly.
There are dedicated regression tests for `compaction.infiniteLoop` and
`compaction.pruneLastMessage`.

Interactive editing (drop oldest, human is present to notice) versus autonomous
long-running (summarize, nobody is watching) get genuinely different answers.

### Rules: glob- and regex-scoped, plus model-requested

`core/llm/rules/getSystemMessageWithRules.ts` selects rules by matching file paths
against `globs` (minimatch, with `!`-prefixed negative patterns) and by
`contentMatchesRegex`. Paths come from the user message's attached context items
*and from code blocks in the message* (`extractPathsFromCodeBlocks`) — rules
activate on files the model is currently looking at.

Rules are a config block type, and three further mechanisms exist:
`RulesContextProvider` (manual attach), the `request_rule` tool (the *model* asks
for a rule it was told exists but whose body was withheld — lazy loading of
instructions), and `create_rule_block` (the model writes a new persistent rule).
`read_skill` + `skills/` extend the same idea to larger instruction bundles.
Applied rules are recorded per-history-index (`setAppliedRulesAtIndex`) for display.

## Sandboxing & Permissions

**There is no sandbox.** No container, no seccomp, no filesystem jail. Tools run
in-process or as ordinary child processes. The entire safety story is *approval
gating plus argument analysis*. Naming it plainly: `packages/terminal-security`
is a static command analyzer, not an isolation boundary.

### Policy is a lattice evaluated per call, not a per-tool flag

`packages/terminal-security/src/types.ts`:

```ts
export type ToolPolicy = "allowedWithPermission" | "allowedWithoutPermission" | "disabled";
```

Ordered most→least restrictive: `disabled` > `allowedWithPermission` >
`allowedWithoutPermission`. `getMostRestrictive(...policies)` combines. The base
policy comes from user settings, falling back to the tool's `defaultToolPolicy`,
falling back to a global default (`gui/src/redux/thunks/evaluateToolPolicies.ts`):

```ts
const basePolicy =
  toolPolicies[name] ?? activeTools.find(t => t.function.name === name)?.defaultToolPolicy
  ?? DEFAULT_TOOL_SETTING;
```

Then the tool's own `evaluateToolCallPolicy` runs on the parsed args — and the
result is **clamped so it can only tighten**:

```ts
if (basePolicy === "disabled") return { policy: "disabled", ... };
if (basePolicy === "allowedWithPermission" && dynamicPolicy === "allowedWithoutPermission")
  return { policy: "allowedWithPermission", ... };
```

Dynamic evaluation is a monotone narrowing of a user-declared ceiling. A tool can
never argue its way to *more* permission than configured. This is the correct shape
and is worth copying verbatim.

### Argument-dependent policy: two concrete evaluators

`core/tools/policies/fileAccess.ts` — the workspace boundary:

```ts
// Files within workspace use the base policy (typically "allowedWithoutPermission")
if (isWithinWorkspace) return basePolicy;
// Files outside workspace always require permission for security
return "allowedWithPermission";
```

The trust boundary is the workspace, and it is enforced at *policy* time on
preprocessed (absolutized) arguments — which is exactly why `preprocessArgs` exists
and runs first.

`packages/terminal-security/src/evaluateTerminalCommandSecurity.ts` — shell command
analysis. It tokenizes with `shell-quote` rather than regexing the string, splits
on newlines *and* on shell operators (`&&`, `||`, `|`, `;`, `>`, `>>`, `<`, `&`),
evaluates each segment independently, and takes the most restrictive result. Any
unparseable construct downgrades toward `allowedWithPermission`. The header calls
it "defense-in-depth" — an honest framing, since a static analyzer over shell
syntax is a heuristic, not a guarantee.

### The CLI's parallel system, with a different vocabulary

`extensions/cli/src/permissions/` uses `allow` / `ask` / `exclude`, where `exclude`
is qualitatively different from `disabled`: excluded tools are **filtered out
before the tool list is sent to the model**, so the model never learns they exist.
That is a prompt-level rather than execution-level control, and it is the CLI's
answer to mode restriction.

Precedence is explicit and documented in `precedenceResolver.ts` — CLI flags
(`--allow`/`--ask`/`--exclude`) > `config.yaml` permissions > `~/.continue/permissions.yaml`
> defaults, with "earlier sources completely override later ones on a per-tool
basis". Policies are an ordered list matched first-wins, with `{ tool: "*" }` as
the terminal catch-all — a routing table, not a map.

**Headless changes defaults, not mechanism** (`defaultPolicies.ts`):

```ts
if (isHeadless) { policies.push({ tool: "Bash", permission: "allow" });
                  policies.push({ tool: "*", permission: "allow" }); }
else            { policies.push({ tool: "Bash", permission: "ask" });
                  policies.push({ tool: "*", permission: "ask" }); }
```

Unattended mode auto-approves everything, including unknown MCP tools. That is a
deliberate, documented trade — with no sandbox underneath it, headless mode is
"trust the workspace".

Modes are wholesale policy replacements rather than filters: `PLAN_MODE_POLICIES`
`exclude`s `Edit`/`MultiEdit`/`Write` while allowing `Bash` (with an admitted TODO:
"address bash read only concerns"), and `AUTO_MODE_POLICIES` is just
`[{ tool: "*", permission: "allow" }]`. Core-side modes are
`MessageModes = "chat" | "agent" | "plan" | "background"` (`core/index.d.ts:495`),
feeding both `getBaseSystemMessage(mode, …)` and tool selection.

Edit tools are special-cased to skip permission entirely
(`isEditTool(...) → "allowedWithoutPermission"`) because approval happens later at
the diff-application UI instead — approval is moved, not removed.

## Multi-Agent Support

Present in the CLI only, and shallow by design.

**A subagent is a model config entry with the `subagent` role.** `ModelRole`
(`packages/config-yaml/src/schemas/models.ts:23`) is
`chat | autocomplete | embed | rerank | edit | apply | summarize | subagent`.
`getSubagentModels()` filters on that role; the agent's persona is the model's
`chatOptions.baseSystemMessage`. There is no separate agent-definition file format —
declaring a subagent is declaring a model with a role and a system message.

`extensions/cli/src/tools/subagent.ts` builds the spawn tool **dynamically at
config-load**, injecting the roster into its own schema:

```ts
subagent_name: { type: "string",
  description: `The type of specialized agent to use for this task. Available agents: ${getSubagentNames(modelServiceState).join(", ")}` }
```

Execution (`src/subagent/executor.ts`) takes `{ agent, prompt, parentSessionId,
abortController, onOutputUpdate }`. The child streams partial output back into the
parent's tool-result slot with status `"calling"`, so the parent UI shows progress
live rather than blocking opaquely. The return value is the child's final response
plus a metadata envelope:

```
<task_metadata>
status: completed|failed
</task_metadata>
```

What is *not* there: no parallel fan-out primitive, no nesting policy, no separate
permission scope for the child, no worktree isolation for subagents. Subagent
invocation is one synchronous tool call that happens to run a nested loop.

Adjacent but distinct: `BackgroundJobService` (`MAX_CONCURRENT_JOBS = 5`,
`MAX_OUTPUT_LINES = 1000`) manages detached *shell processes* with a
`CheckBackgroundJob` tool — background work, not background agents. And
`worktree-config.yaml` at the repo root is a developer convenience for copying
`node_modules` into git worktrees via copy-on-write; it is Continue's own build
tooling, not an agent isolation feature.

Multiple named assistants are selected via config (`AgentFileService`,
`ConfigService`), and `Session.mode` persists a per-session mode.

## Notable Design Decisions

1. **The tool-calling protocol is a strategy object.** `SystemMessageToolsFramework`
   makes "how a tool call is expressed on the wire" pluggable; native function
   calling is the degenerate case where no strategy is installed. Downstream code is
   protocol-agnostic because the intercepting generator normalizes to `ToolCallDelta`.

2. **Line-delimited text tool calls beat JSON for weak models.**
   `BEGIN_ARG`/`END_ARG` framing sidesteps escaping entirely for multiline
   arguments, and the parser deliberately accepts malformed starts and rewrites them.
   Parallel tool calls were dropped in this mode because they confused small models —
   capability traded for reliability, explicitly.

3. **Permission is a function of arguments, clamped to a user-declared ceiling.**
   `evaluateToolCallPolicy(basePolicy, parsedArgs)` can only narrow. Combined with
   `preprocessArgs` running first, the policy sees normalized arguments.

4. **The workspace directory is the trust boundary**, enforced in policy code
   (`fileAccess.ts`) rather than in each tool.

5. **Static shell analysis via a real tokenizer**, split on operators, most-restrictive
   wins — and named "defense-in-depth", not "sandboxing". No isolation anywhere.

6. **Tool results and context items are the same type** (`ContextItem[]`), so tools
   and @-mentions are interchangeable producers of context.

7. **Tools are URI-addressed** (`mcp://`, `http(s)://`, built-in), making local and
   remote tools uniform.

8. **Context providers resolve once, eagerly, and are then done.** Simple and
   predictable, at the cost of never refreshing stale context.

9. **Retrieval budget is derived from the model's context window**, not fixed:
   at most half the window, over-fetch 2× when a reranker exists.

10. **Indexing is content-addressed and branch-tagged**, so branch switches re-tag
    rather than re-embed. Four independent artifact indexes over one diff engine.

11. **Compaction and pruning are different answers for different modes** —
    interactive drops oldest and *reports* it (`didPrune`, `contextPercentage`);
    autonomous summarizes at 80%.

12. **The non-negotiable set is explicit**: system message, tools, and the trailing
    tool sequence are never pruned; overflow of those throws rather than degrades.
    Orphaned tool results are dropped with their calls.

13. **Config indirection via blocks**: `uses:` / `with:` / `override:` on registry
    slugs. `packages/config-yaml/src/load/unroll.ts` resolves a `ConfigYaml` into an
    `AssistantUnrolled` (every entry inlined; nullable entries mark unresolvable
    blocks so one broken block does not fail the whole config —
    `assistantUnrolledSchema` vs `assistantUnrolledSchemaNonNullable`). A `Block` is
    schema-enforced as *exactly one* item of exactly one type
    (`z.array(modelSchema).length(1)`), which makes blocks independently
    publishable and composable.

14. **Provider layer split by rate of change** — `openai-adapters` (wire format,
    changes rarely) vs `core/llm/llms` (metadata, changes constantly) vs `llm-info`
    (static facts).

15. **Model *roles* rather than model *slots*** — `chat`/`edit`/`apply`/`embed`/
    `rerank`/`summarize`/`autocomplete`/`subagent`. A subagent is a role, not a
    subsystem.

16. **A subagent is a model + system message.** No separate agent format. Child
    output streams into the parent's tool-result slot; a `<task_metadata>` envelope
    carries status.

17. **The IDE agent loop lives in Redux thunks** — arguably the repo's largest
    structural mistake, since it forced the CLI to reimplement the loop, the tool
    set, and the permission model independently. Two vocabularies for the same
    concepts (`allow`/`ask`/`exclude` vs
    `allowedWithoutPermission`/`allowedWithPermission`/`disabled`) is the visible
    scar.

18. **No production turn limit.** The depth guard is `NODE_ENV === "test"` only.

## Relevance to Crescent

Directly applicable to `lib/ai` and a `lib/platform/apps/` agent app. These are
observations about transferability, not recommendations — the calls are open.

**Where Continue independently reached crescent's existing conventions:**

- `ContextProviderExtras` is caps-first: `ide`, `fetch`, `llm`, `embeddingsProvider`
  are injected, never reached for. Same principle as crescent's cap injection rule.
- The tiering instinct appears in retrieval (embeddings + FTS, degrade to FTS when
  no embed model) and in LanceDB's dynamic import behind a CPU-target check — the
  same "fall through, never fail hard" shape as crescent's system > FFI > pure Lua.
  Note the difference: Continue's tiers are *capability* tiers, not performance
  tiers of one spec, so no parity testing applies.

**Ideas that would need crescent-shaped substrate to adopt:**

- *Protocol-as-strategy for tool calls.* `lib/ai/tools.lua` currently assumes one
  calling convention. Making the wire protocol an injected object — with the native
  path as "no strategy installed" — is the highest-value structural idea here, and
  it is what would let a local/small model be a first-class provider rather than a
  second-class one. This is substrate (a protocol interface), and by crescent's
  substrate-before-consumers rule it would need to land before provider-specific
  tool support is expanded.
- *Argument-dependent, monotonically-narrowing permission.* A `ToolPolicy` lattice
  with `evaluate(base, args) → policy` clamped to never widen is small, declarative,
  and has no name-keyed special-casing — each tool supplies its own evaluator. The
  workspace-boundary evaluator is ~10 lines.
- *`preprocessArgs` before policy evaluation.* Path absolutization must happen
  before "is this inside the workspace?" can be asked. Ordering is load-bearing.
- *Explicit non-negotiable set in context assembly*, with overflow as an error
  rather than a silent degrade, and `didPrune`/`contextPercentage` surfaced. Crescent's
  `(nil, errmsg)` convention fits the overflow case exactly.
- *Orphaned-tool-result repair.* Any history-pruning code must maintain the
  call/result pairing invariant or the provider rejects the request.

**Open questions this survey surfaces rather than answers:**

- Where does the agent loop live relative to `lib/taskgraph`? Continue's answer
  (in the UI state manager) cost it a second implementation. Whether a crescent
  agent loop should be a taskgraph node, a library function, or something else is
  undecided and consequential.
- Whether an agent app needs retrieval/indexing at all. Continue's four-index,
  content-addressed, branch-tagged design is substantial machinery
  (`core/indexing/` is large), and its own trajectory was toward the model driving
  `grep`/`glob` tools rather than toward RAG. Note that `codebaseTool.ts` and
  `@codebase` coexist — they did not pick.
- Sandboxing. Continue has none, and its headless mode auto-approves everything.
  Crescent has no sandbox substrate either. This is a gap to record as a substrate
  need, not something to paper over with an approval prompt and call solved.
- Subagent shape. Continue's "subagent = model + system message + role" is the
  minimal answer and has no permission scoping, no parallelism, and no nesting
  policy. Whether that minimalism is right depends on what `lib/taskgraph` already
  provides for concurrency and isolation.

**Caveat on all of the above:** the repo is archived. What is described here is a
frozen end state, and its unfinished seams (two harnesses, two permission
vocabularies, `bin`-level TODOs like "address bash read only concerns") are
permanent. Its decisions are informative; its convergence is not evidence of
correctness.

## Sources

Primary — shallow clone of `github.com/continuedev/continue` at HEAD `5522c6f4`
(2026-07-20), read locally:

- `README.md` (archival notice, 2.0.0 final release)
- `core/index.d.ts` — `Tool` (1132), `ContextItem` (459), `MessageModes` (495),
  `ContextProviderType`/`ContextProviderDescription`/`ContextProviderExtras` (181–272)
- `core/context/index.ts` — `BaseContextProvider` / `IContextProvider`
- `core/context/providers/` — ~30 built-ins, `HttpContextProvider`, `MCPContextProvider`
- `core/context/retrieval/retrieval.ts`, `core/context/retrieval/pipelines/`
- `core/indexing/README.md`, `core/indexing/LanceDbIndex.ts`
- `core/tools/builtIn.ts`, `core/tools/callTool.ts`, `core/tools/constants.ts`,
  `core/tools/applyToolOverrides.ts`, `core/tools/implementations/`
- `core/tools/policies/fileAccess.ts`
- `core/tools/systemMessageTools/` — `types.ts`, `buildToolsSystemMessage.ts`,
  `detectToolCallStart.ts`, `interceptSystemToolCalls.ts`,
  `toolCodeblocks/index.ts`, `toolCodeblocks/parseSystemToolCall.ts`
- `core/llm/countTokens.ts` (`compileChatMessages`, ~line 422)
- `core/llm/toolSupport.ts`, `core/llm/llms/` (81 providers)
- `core/llm/rules/getSystemMessageWithRules.ts`
- `gui/src/redux/thunks/` — `streamNormalInput.ts`, `streamResponseAfterToolCall.ts`,
  `evaluateToolPolicies.ts`, `cancelStream.ts`, `preprocessToolCallArgs.ts`
- `packages/terminal-security/src/` — `types.ts`, `evaluateTerminalCommandSecurity.ts`
- `packages/config-yaml/src/schemas/index.ts`, `src/schemas/models.ts`,
  `src/load/unroll.ts`, `src/load/getBlockType.ts`
- `packages/openai-adapters/README.md`
- `extensions/cli/src/permissions/` — `README.md`, `defaultPolicies.ts`,
  `precedenceResolver.ts`
- `extensions/cli/src/compaction.ts`
- `extensions/cli/src/tools/` (CLI tool set), `src/subagent/` — `get-agents.ts`,
  `executor.ts`
- `extensions/cli/src/services/BackgroundJobService.ts`
- `worktree-config.yaml`

Secondary:

- <https://docs.continue.dev/customize/deep-dives/custom-providers>
- <https://docs.continue.dev/customize/deep-dives/configuration>
- <https://docs.continue.dev/reference/deprecated-context-providers>
- <https://github.com/continuedev/continue>
