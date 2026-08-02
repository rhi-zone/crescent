# Prior art survey: Claude Code

Survey of Anthropic's Claude Code as prior art for a crescent agent harness
(`lib/platform/apps/` agent app, `lib/ai` expansion). Focus is on the
**decisions and their stated rationale**, not the feature list.

## Epistemic status of this document

Claude Code is **not open source**, contrary to how this survey was originally
framed. Verified against the npm registry (2026-08-02): `@anthropic-ai/claude-code`
v2.1.220, license field `"SEE LICENSE IN README.md"`, 7 files / 165 KB unpacked,
a `postinstall` that runs `install.cjs` to fetch per-platform binaries
(linux/win/darwin × x64/arm64, plus musl variants), `bin/claude.exe`. The
`github.com/anthropics/claude-code` repo is issues and docs, not source.

So there are three tiers of evidence behind this document, and claims are
labelled where the tier matters:

- **[docs]** — Anthropic's official documentation at `code.claude.com/docs`.
  Authoritative on *product intent and contract*; may not reflect implementation.
- **[paper-B]** — code-verified claims from *Dive into Claude Code: The Design
  Space of Today's and Future AI Agent Systems* (arXiv 2604.14228v1, VILA-Lab),
  derived from a **decompiled/extracted npm bundle of v2.1.88** (~1,884 files,
  ~512K LOC of TypeScript). File names, function names, and constants are
  strong evidence of *what exists*.
- **[paper-C]** — the paper's own reconstruction, analytic framing, or community
  analysis. The paper is explicit about this: *"Source code reveals implemented
  structure, control flow, dependencies, and feature gates. It cannot confirm
  design intent, enabled production flags, runtime prevalence, or unshipped
  behavior."* **Every "why" below is reconstruction**, even where the "what" is
  code-verified. Layer counts ("five compaction layers", "seven safety layers")
  are the paper's analytic decomposition, not Anthropic's vocabulary.

Where the docs and the paper disagree in emphasis or the paper's version (2.1.88)
has been overtaken by the docs' version (~2.1.220), the docs win. Gaps are listed
as gaps at the end rather than filled in.

---

## Overview

Claude Code is a terminal-first coding agent that Anthropic's own docs describe
as **"the agentic harness around Claude: it provides the tools, context
management, and execution environment that turn a language model into a capable
coding agent."** [docs]

The framing that makes it useful as prior art: it is explicitly *not* an attempt
to make the model smarter through scaffolding. The paper's headline framing is
that Claude Code is overwhelmingly operational infrastructure wrapped around a
trivial loop — a community measurement of the extracted source puts **~1.6% of
the codebase as AI decision logic and ~98.4% as infrastructure** [paper-C].
The paper's own summary of the resulting stance: *"the harness creates conditions
(tool routing, permission enforcement, context assembly, recovery logic) under
which the model can decide well… The engineering complexity exists not to
constrain the model's decisions but to enable them."* [paper-C]

Four framing questions organize the whole design [paper-C, §3.1]:

1. **Where does reasoning live?** → *Model reasons; harness enforces.* The model
   emits `tool_use` blocks; the harness parses, permission-checks, dispatches,
   collects. The model never touches the filesystem, shell, or network directly.
   The security consequence is stated as the point: because reasoning and
   enforcement are separate code paths, *"a compromised or adversarially
   manipulated model cannot override the sandboxing, permission checks, or
   deny-first rules implemented in the harness."*
2. **How many execution engines?** → *One.* A single loop function serves
   interactive terminal, headless CLI, Agent SDK, and IDE. Only rendering varies.
3. **What is the default safety posture?** → *Deny-first with human escalation.*
   Unrecognized actions escalate rather than silently allow.
4. **What is the binding resource constraint?** → *The context window.* Not
   compute, not latency.

Alternatives are named rather than strawmanned: Devin (explicit planning /
task-tracking scaffolds), LangGraph (developer-defined typed state graphs),
LATS (tree search over trajectories), SWE-Agent / OpenHands (container isolation
as the safety primitive), Aider (git rollback as the safety primitive).

---

## Architecture

### One loop, many surfaces

The core is `queryLoop()` in `query.ts` — an **async generator** yielding stream
events, messages, tombstones, and tool-use summaries [paper-B]. Stated rationale:
it *"enables streaming output to the UI layer while maintaining a single
synchronous control flow within the loop"* [paper-C]. One construct unifies
streaming (yield), termination (typed return), and error propagation, where a
state machine or event emitter would split them.

A `QueryEngine` class exists but is a red herring for anyone modelling the
layering. Its own doc comment: *"QueryEngine owns the query lifecycle and
session state for a conversation. It extracts the core logic from ask() into a
standalone class that can be used by both the headless/SDK path and (in a future
phase) the REPL."* The interactive CLI calls `query()` directly and bypasses it.
The paper's conclusion: **"The shared code path is the loop function, not the
engine class."** [paper-B/C, §3.4]

### The turn pipeline

Nine stages per iteration [paper-B, §4.1]:

1. Settings resolution — immutable params destructured once.
2. **Mutable state initialization** — a *single* `State` object holds all
   mutable state (messages, tool context, compaction tracking, recovery
   counters). The loop has **seven continue sites**, and each *"overwrite[s]
   this object in one whole-object assignment rather than mutating fields
   individually."* This is the most directly transferable structural idea in
   the paper: whole-object replacement at every continue point, not field
   mutation.
3. Context assembly — `getMessagesAfterCompactBoundary()` retrieves history
   from the last compaction boundary forward, so compacted content is
   represented by its summary, never the originals.
4. Pre-model context shapers — five, sequential (see Context/Memory).
5. Model call — assembled messages, system prompt, thinking config, tool set,
   abort signal, model spec, effort, fallback model.
6. Tool-use dispatch.
7. Permission gate, per tool request.
8. Tool execution and result collection; results appended as `tool_result`.
9. Stop condition: no `tool_use` blocks ⇒ turn complete.

The SDK docs define a *turn* precisely and consistently with this: *"one round
trip inside the loop: Claude produces output that includes tool calls, the SDK
executes those tools, and the results feed back to Claude automatically. This
happens without yielding control back to your code. Turns continue until Claude
produces output with no tool calls."* `maxTurns` counts tool-use turns only. [docs]

### The loop-shape tradeoff, stated plainly

It is a ReAct loop, and the paper names the cost in one sentence:

> **"The reactive design trades search completeness for simplicity and latency:
> each turn commits to one action sequence without backtracking."** [paper-C]

Of Anthropic's five composable workflow patterns, Claude Code *"primarily uses
the orchestrator-workers pattern for subagent delegation while keeping the core
loop reactive."*

Note this is a claim about **action selection**, not about history
representation. On disk the transcript is a chain: lines carry `parentUuid`s,
and fork/branch/rewind are first-class. The *in-flight* message array is flat.

### Five stop conditions, exactly

No tool use (primary) · `maxTurns` reached · `prompt_too_long` from the API ·
a `PostToolUse` hook setting `hook_stopped_continuation` · `abortController`
firing. [paper-B, §4.5]

### Recovery is part of the loop, not around it

Concrete, with constants [paper-B, §4.4]:

- **Max-output-token escalation** — retry with a raised limit, capped at
  `MAX_OUTPUT_TOKENS_RECOVERY_LIMIT = 3` attempts per turn.
- **Reactive compaction** (`REACTIVE_COMPACT`) — when context nears capacity,
  summarize *just enough to free space*; a `hasAttemptedReactiveCompact` flag
  limits it to **at most once per turn**.
- **`prompt_too_long` handling** — try context-collapse overflow recovery, then
  reactive compaction, and only then terminate with `reason: 'prompt_too_long'`.
- **Streaming fallback** and a **fallback model** parameter.

---

## Tool-Calling Protocol

### Tools are declared through MCP, including internal ones

The load-bearing decision: **MCP is both the extension mechanism and the
tool-definition path**. Custom tools in the SDK are declared via an *in-process*
MCP server, not a bespoke registry. [docs]

```typescript
const getTemperature = tool(
  "get_temperature",
  "Get the current temperature at a location",
  { latitude: z.number().describe("Latitude coordinate") },
  async (args) => ({ content: [{ type: "text", text: "..." }] }),
  { annotations: { readOnlyHint: true } }
);
const server = createSdkMcpServer({ name: "weather", version: "1.0.0", tools: [...] });
```

Naming convention `mcp__{server}__{tool}` (plugins:
`mcp__plugin_<plugin>_<server>__<tool>`) carries all the way through permission
rules, hook matchers, and `disallowedTools`. One convention, four consumers.

### Tool pool assembly

`assembleToolPool()` is *"the single source of truth for combining built-in
tools with MCP tools"* [paper-B, §6.2], in five steps: `getAllBaseTools()`
(**up to 54 tools; 19 always included, 35 conditional** on feature flags, env
vars, and user type) → mode filtering via `isEnabled()` → deny-rule
pre-filtering → MCP merge → **deduplication by name, built-ins winning over
MCP**. In practice the pool ranges from **3 tools in `CLAUDE_CODE_SIMPLE` mode
to 40+ in a full internal build**. Both the REPL and the subagent spawner call
the same function.

### Parallelism from static declaration, not runtime analysis

*"Read-only tools (like `Read`, `Glob`, `Grep`, and MCP tools marked as
read-only) can run concurrently. Tools that modify state (like `Edit`, `Write`,
and `Bash`) run sequentially to avoid conflicts. **Custom tools default to
sequential execution.**"* [docs] Opt in via `readOnlyHint`.

Of the four MCP annotations, **only `readOnlyHint` is load-bearing**;
`destructiveHint`, `idempotentHint`, `openWorldHint` are informational. The docs
say it outright: *"Annotations are metadata, not enforcement."*

The decision here is that concurrency safety is a **static property the tool
author declares**, defaulting to the safe answer. No dependency analysis, no
runtime conflict detection.

Two execution paths exist [paper-B, §4.2]: a primary `StreamingToolExecutor`
that *"begins executing tools as they stream in from the model response,
reducing latency for multi-tool responses"*, and a `runTools()` fallback. The
streaming executor adds a **sibling abort controller** (*"Fires when any Bash
tool errors, immediately terminating other in-flight subprocesses"*) and a
progress-available signal.

**The ordering invariant is explicit and non-negotiable:** *"Results are
buffered and emitted in the order tools were received, so output order stays
the same even when tools run in parallel. This is important because the model
expects tool results in the same order as its tool-use requests."*

The paper places this in the design space as *"concurrent-read, serial-write…
a middle ground between fully serial dispatch and more aggressive speculative
approaches such as PASTE, which speculatively pre-executes predicted future
tool calls while the model is still generating."*

### Results feeding back

Handler returns `{ content, structuredContent?, isError? }`; block types are
`text`, `image`, `audio`, `resource`, `resource_link`. Tool results arrive as
`UserMessage`s — **tool results are modelled as user turns, not a separate
channel**. [docs]

Two decisions worth noting:

- When `structuredContent` is set, *"Claude receives the JSON plus any image or
  resource blocks from `content`. **Text blocks in `content` are not
  forwarded**, since they are assumed to duplicate the structured data."*
- *"A handler error doesn't stop the agent loop.* The in-process MCP server
  catches uncaught exceptions and returns them as error results, so *"how you
  report an error determines what Claude reads, not whether the query fails."*

A subtle asymmetry between tool classes [paper-B, §5.3]: *"For non-MCP tools,
the `tool_result` is emitted before the `PostToolUse` hook fires. For MCP tools,
the result is delayed until after post hooks have run, enabling
`updatedMCPToolOutput` to take effect."* MCP results are mutable in flight;
built-in results are not.

**Denial is feedback, not a halt** [paper-C, §5.2]: *"When the classifier or a
deny rule blocks an action, the system treats the denial as a routing signal
rather than a hard stop: the model receives the denial reason, revises its
approach, and attempts a safer alternative in the next loop iteration…
permission enforcement shapes the agent's behavior rather than simply halting
it."*

### Result size: spill to disk, not truncate

Documented numbers are MCP-specific [docs]:

| Threshold | Value |
|---|---|
| Warning shown | output > **10,000 tokens** |
| Default max | **25,000 tokens** (`MAX_MCP_OUTPUT_TOKENS`) |
| Over threshold | *"results are persisted to disk and replaced with a file reference in the conversation"* |
| Per-tool ceiling | `_meta["anthropic/maxResultSizeChars"]`, hard-capped at **500,000 chars** |
| Tool descriptions / server instructions | truncated at **2 KB each** |

The decision — **spill-to-file with a reference, rather than truncate** — keeps
the data reachable while removing it from context. The same mechanism appears
in the loop as shaper #1 (`applyToolResultBudget()`, replacing oversized outputs
with *content references*, persisted so they can be reconstructed on resume)
[paper-B].

### Scaling past ~30 tools: defer the schemas

Two problems stated [docs]: *"Tool definitions can consume large portions of the
context window (50 tools can use 10-20K tokens)"* and *"Tool selection accuracy
degrades with more than 30-50 tools loaded at once."*

The mechanism withholds definitions; the model sees names plus server
instructions and calls a `ToolSearch` tool to pull schemas in. **Up to five of
the most relevant tools load per search and stay available for subsequent
turns.** Compaction can evict them, and the agent re-searches.

`ENABLE_TOOL_SEARCH`: unset = defer by default · `true` = always defer ·
`auto` = load upfront if definitions fit within **10% of the context window** ·
`auto:N` = custom percentage · `false` = load everything.

The honest cost note: *"Tool search adds one extra round-trip the first time
Claude discovers a tool… With fewer than ~10 tools, loading everything upfront
is typically faster."* And a design rule that generalizes: *"The search
mechanism matches queries against tool names and descriptions. Names like
`search_slack_messages` surface for a wider range of requests than
`query_slack`."*

---

## Context/Memory Management

The stated governing principle, appearing twice in the paper: **"apply the
least disruptive compression first, escalating only when cheaper strategies
prove insufficient."** Rationale for having a pipeline at all: *"no single
compaction strategy addresses all types of context pressure."* [paper-C, §4.3]

### Five pre-model shapers, each targeting a distinct pressure source

Each maps to a different *cause* of context pressure, not merely a different
aggressiveness [paper-B/C, `query.ts:365–453`]:

> *"Budget reduction targets individual tool outputs that overflow size limits.
> Snip handles temporal depth. Microcompact reacts to cache overhead. Context
> collapse manages very long histories. Auto-compact performs semantic
> compression as a last resort."*

| # | Shaper | Function | What it does |
|---|---|---|---|
| 1 | Budget reduction | `applyToolResultBudget()` | Per-result size caps; oversized outputs → content references, persisted for resume. Always active. |
| 2 | Snip | `snipCompactIfNeeded()` | Lightweight trim of older history segments. |
| 3 | Microcompact | — | Fine-grained, cache-aware compression keyed purely by `tool_use_id`. |
| 4 | Context collapse | `applyCollapsesIfNeeded()` | A **read-time projection**, not a mutation. |
| 5 | Auto-compact | `compactConversation()` | Full model-generated summary. Last resort. |

The non-obvious details are the valuable part:

- **Ordering rationale between 1 and 3 is structural, not arbitrary:**
  *"Budget reduction runs before microcompact because microcompact operates
  purely by `tool_use_id` and never inspects content; the two compose cleanly."*
- **A token-accounting leak, and its fix — the most transferable warning here.**
  `snipTokensFreed` must be plumbed explicitly into auto-compact *"because the
  main token counter derives context size from the `usage` field on the most
  recent assistant message, and that message survives snip with its pre-snip
  `input_tokens` still attached; snip's savings are therefore invisible to the
  counter unless passed through explicitly."* Any harness that derives context
  size from **provider-reported usage rather than measuring locally** inherits
  this bug class.
- **Context collapse is a projection over two stores.** Source comment:
  *"Nothing is yielded; the collapsed view is a read-time projection over the
  REPL's full history. Summary messages live in the collapse store, not the REPL
  array. This is what makes collapses persist across turns."* Full history stays
  available for reconstruction while the model sees a collapsed view.
- **Compaction never destroys the transcript.** The boundary marker carries
  chain-repair metadata (`headUuid`, `anchorUuid`, `tailUuid`) via
  `annotateBoundaryWithPreservedSegment()`, so *"preserved messages keep their
  original `parentUuid`s on disk, and the loader uses boundary metadata to link
  them correctly."* Consequence: **"compaction never modifies or deletes
  previously written transcript lines."**
- Post-compact message shape:
  `[boundaryMarker, ...summaryMessages, ...messagesToKeep, ...attachments, ...hookResults]`.
- **Runtime state is re-announced after compaction** from live app state (plans,
  skills, async agents), since compaction discards prior attachment messages but
  not the underlying state.
- Microcompact **defers its boundary message until after the API response** so
  it can use actual `cache_deleted_input_tokens` rather than estimates.
- A cache-reuse experiment left in a code comment (Jan 2026): the non-reusing
  path is *"98% cache miss, costs ~0.76% of fleet cache_creation."*

The docs describe the user-visible surface of the same thing more simply:
*"It clears older tool outputs first, then summarizes the conversation if
needed."* Plus a thrashing guard: *"If a single file or tool output is so large
that context refills immediately after each summary, Claude Code stops
auto-compacting after a few attempts and shows an error instead of looping."*

**The cost is admitted** [paper-C]: *"Five interacting compression layers,
several gated by feature flags, create behavior that is difficult for users to
fully predict… **context collapse operates without user-visible output.**"*

### What survives compaction — the cleanest invariant in the whole system

[docs, `/context-window#what-survives-compaction`]

| Mechanism | After compaction |
|---|---|
| System prompt, output style | Unchanged (not part of message history) |
| Project-root CLAUDE.md, unscoped rules | **Re-injected from disk** |
| Auto memory | **Re-injected from disk** |
| Rules with `paths:` frontmatter | **Lost** until a matching file is read again |
| Nested CLAUDE.md in subdirectories | **Lost** until a file there is read again |
| Invoked skill bodies | Re-injected, capped at **5,000 tokens/skill, 25,000 total**; oldest dropped first |
| Skill *listing* | **Not** re-injected — only invoked skills survive |
| Hooks | N/A — hooks run as code, not context |

The organizing rule: **anything loaded from disk at startup survives, because
it is re-read; anything that entered through message history is summarized
away.** That single invariant is what makes the rest predictable.

Corollary the docs draw for authors: skill truncation *"keeps the start of the
file, so put the most important instructions near the top of `SKILL.md`."*

### Instruction hierarchy: concatenation, not precedence

Four scopes — managed policy (`/etc/claude-code/CLAUDE.md` on Linux), user
(`~/.claude/CLAUDE.md`), project (`./CLAUDE.md`, `./.claude/CLAUDE.md`), local
(`./CLAUDE.local.md`). Critically [docs]:

> *"All discovered files are concatenated into context rather than overriding
> each other. Across the directory tree, content is ordered from the filesystem
> root down to your working directory… so instructions closer to where you
> launched Claude are read last."*

The paper adds the reason this ordering was chosen: *"later-loaded files receive
more model attention"* [paper-C]. Conflict resolution is explicitly **not
solved**: *"if two rules contradict each other, Claude may pick one
arbitrarily."* [docs]

**Guidance and enforcement are deliberately separated.** CLAUDE.md is delivered
*as a user message after the system prompt*, not as part of it, so *"model
compliance with these instructions is **probabilistic rather than
guaranteed**. Permission rules evaluated in deny-first order provide the
deterministic enforcement layer."* [paper-C] The docs say the same to users:
*"Claude treats them as context, not enforced configuration. To block an action
regardless of what Claude decides, use a PreToolUse hook instead."*

The paper flags a structural side effect: the system prompt goes through
`asSystemPrompt(...)` while user context is *prepended to the message array* via
`prependUserContext()`, so *"CLAUDE.md content occupies a different structural
position in the API request than the system prompt, potentially affecting model
attention patterns."*

### Laziness as the primary context lever

`.claude/rules/` with `paths:` frontmatter is the mechanism that actually
reduces baseline context — rules load only when Claude reads a matching file.
The same laziness governs nested CLAUDE.md files. The paper's observation:
*"the model's instruction set can evolve during a conversation as new parts of
the codebase are explored."* [paper-C]

Imports (`@path/to/file`) are **expanded at launch and therefore save nothing**:
*"Splitting into `@path` imports helps organization but doesn't reduce context,
since imported files load at launch."* Max depth **4 hops**; relative paths
resolve against the containing file; parsing skips code spans and fences;
missing files are silently ignored [paper-B]. A project-level import resolving
outside the working directory triggers a one-time approval dialog.

### Memory retrieval is not embeddings

Stated flatly [paper-C, §7.2]: *"The system does not use embeddings or a vector
similarity index for memory retrieval; instead it uses an **LLM-based scan of
memory-file headers to select up to five relevant files on demand**, surfacing
them at file granularity rather than entry granularity."*

Auto memory lives at `~/.claude/projects/<project>/memory/`, keyed on the **git
repository** (so worktrees share one directory), machine-local, never synced.
`MEMORY.md` is an index; **the first 200 lines or 25 KB, whichever comes first**,
load every session — and since v2.1.210 the tool measures after writes and
errors when over limit, *"because everything past the limit is dropped on the
next load."* [docs]

### Assembly is a memoized loader, and that has a cost

Nine context sources assembled in order: system prompt → environment/git status
→ CLAUDE.md hierarchy → path-scoped rules (lazy) → auto memory (async prefetch)
→ tool metadata → conversation history → tool results → compact summaries.
*"a memoized state loader, not a routing hub."* [paper-C, §7.1]

The context window is **not static at assembly time** — late injections during a
turn include relevant-memory prefetch, MCP instruction *deltas* (only new or
changed server instructions), agent-listing deltas, and background-agent
notifications.

Flagged cost [paper-C, §11.5]: `getSystemContext()` and `getUserContext()` both
use lodash `memoize`, so **git status and CLAUDE.md content are cached, not
recomputed per turn**; *"dynamic changes during a conversation may not be
reflected immediately."*

---

## Sandboxing & Permissions

### The behavioral premise

This is the empirical fact that drives the whole design [paper, Tier A]:
Anthropic's own analysis found users approve **~93% of permission prompts**, and
auto-approve rates rise from *"~20% at <50 sessions to >40% by 750 sessions"* —
*"the gradient is navigated not by deliberate mode selection but by gradual
habituation."*

The reading: *"approval fatigue renders interactive confirmation behaviorally
unreliable **as a sole safety mechanism**… the system must maintain safety
independently of human vigilance."* And the response is the decision worth
copying:

> *"the response was not to add more warnings but to restructure the problem:
> defined boundaries (sandboxing, auto-mode classifiers) within which the agent
> can work freely, rather than per-action approvals that users stop reviewing
> once habituated."*

Sandboxing reportedly reduced prompt frequency by an estimated **84%**.

### Seven independent safety layers

Ordered; *"a request must pass through all applicable layers, and any single
layer can block it"* [paper-C, §3.5]:

1. **Tool pre-filtering** (`tools.ts`) — blanket-denied tools removed from the
   model's view before any call.
2. **Deny-first rule evaluation** (`permissions.ts`) — deny always beats allow,
   *"even when the allow rule is more specific."*
3. **Permission mode constraints** — baseline for requests matching no rule.
4. **Auto-mode ML classifier** — *"potentially denying requests the rule system
   would allow."*
5. **Shell sandboxing** (`shouldUseSandbox.ts`).
6. **Not restoring permissions on resume** (`conversationRecovery.ts`) —
   counted as a *safety layer*, which is an unusual and reusable framing.
7. **Hook-based interception**.

### Rule syntax and evaluation

```json
{
  "permissions": {
    "allow": ["Bash(npm run *)", "Bash(git commit *)"],
    "deny":  ["Bash(git push *)", "Read(//**/.env)", "Agent(Explore)", "mcp__*"],
    "ask":   ["Bash(git push *)"],
    "additionalDirectories": ["../shared"]
  }
}
```

**Evaluation order: deny → ask → allow. First match wins; specificity does not
reorder.** The consequence is stated so nobody expects otherwise: *"A broad deny
rule like `Bash(aws *)` blocks every matching call, including calls that also
match a narrower allow rule like `Bash(aws s3 ls)`, so a deny rule can't carry
allowlist exceptions."* [docs]

A real semantic distinction between bare and scoped denies: *"A bare tool name
like `Bash` **removes the tool from Claude's context entirely**, so Claude never
sees it. A scoped rule like `Bash(rm *)` leaves the tool available and blocks
matching calls when Claude attempts them."*

Notable specifics [docs]:

- **Word-boundary semantics:** `Bash(ls *)` (with space) matches `ls -la` but
  not `lsof`; `Bash(ls*)` matches both.
- **Compound-command awareness:** separators `&&`, `||`, `;`, `|`, `|&`, `&`,
  newlines — *"A rule must match each subcommand independently."* Wrappers
  stripped before matching: `timeout`, `time`, `nice`, `nohup`, `stdbuf`,
  `command`, `builtin`, `noglob`, bare `xargs`. Explicitly **not** stripped and
  flagged as hazards: `direnv exec`, `devbox run`, `mise exec`, `npx`,
  `docker exec`.
- **Symlinks are asymmetric by design:** *"Allow rules apply only when **both**
  the symlink path and its target match… Deny rules apply when **either**
  matches."*
- **Domain wildcards are deliberately narrow:** wildcards other than a leading
  `*.` *"match only the text between two dots"* — `example.*` matches
  `example.org` but not `example.evil.com`, *"to keep a trailing wildcard from
  matching domains an attacker could register."*
- **Parameter matching deliberately excludes content fields.** `Agent(model:opus)`
  works; `Bash(command:rm *)` is **ignored with a startup warning**, because
  *"A rule like `Bash(command:rm *)` would be bypassable by a compound command."*
  Refusing to offer a rule that cannot be enforced is itself the decision.
- **Rules merge across settings scopes rather than override:** *"If a tool is
  denied at any level, no other level can allow it."*

### Modes as a graduated trust spectrum

`default` (reads only) · `acceptEdits` (edits plus a named list of filesystem
shell commands — `mkdir`, `rmdir`, `touch`, `rm`, `mv`, `cp`, `sed`) · `plan` ·
`auto` (classifier reviews each action) · `dontAsk` (pre-approved only,
everything else auto-denied) · `bypassPermissions`. Plus an internal-only
`bubble` mode for escalating a subagent's prompt to the parent terminal
[paper-B, §5.1].

Modes set a baseline; **rules apply in every mode including
`bypassPermissions`** — deny rules, explicit ask rules, and
`requiresUserInteraction` MCP tools all still fire.

### Anti-privilege-escalation: the config cannot grant itself power

The most quietly important cluster [docs]:

- **Protected paths** (`.git`, `.claude`, shell rc files, `.envrc`, `.npmrc`,
  `.mcp.json`, `.claude.json`, …) are never auto-approved, and *"The safety
  check runs **before** Claude Code evaluates allow rules from settings, so an
  entry such as `Edit(.claude/**)` does not change the per-mode outcome."*
  Self-modification of config is **structurally** blocked, not rule-blocked.
- `defaultMode: "auto"` is **ignored** when it comes from project settings *"so
  a repository cannot grant itself auto mode."*
- **Managed settings outrank command-line arguments** — the only level that does.
- **Workspace trust:** `permissions.allow` and `additionalDirectories` in
  *project* settings grant capability, so they apply only after a trust dialog
  listing exactly what they'd grant. *"`deny` and `ask` rules aren't affected,
  since they only restrict."* Capability-granting config requires consent;
  restricting config does not.
- Refuses to run as root/sudo. Under `bypassPermissions`, `rm -rf /` and
  `rm -rf ~` *still* prompt, including inside `$(...)`, backticks, `<(...)`.
- Auto mode **drops broad allow rules on entry** (blanket `Bash(*)`, wildcarded
  interpreters, package-manager run commands, `Agent` allow rules) and restores
  them on exit.
- The sandbox *"automatically denies write access to Claude Code's
  `settings.json` files at every scope and to the managed settings directory,
  so a sandboxed command can't modify its own policy."*

### Sandbox: authorization and isolation are different axes

*"A command can be permission-approved but still sandboxed, or permission-denied
and never reach the sandbox check. The two systems operate on different axes:
**authorization versus isolation**."* [paper-C, §5.4]

OS-level, Bash-only, two independent layers. Enforcement: macOS Seatbelt;
Linux/WSL2 `bubblewrap` + `socat` (+ optional seccomp filter). WSL1 and native
Windows unsupported. [docs]

Defaults: write = cwd + session temp dir (`$TMPDIR` redirected); read = the
entire computer minus denied dirs — and the docs say the quiet part:
*"Note that this default still allows reading credential files such as
`~/.aws/credentials` and `~/.ssh/`."*

Overlap resolution: *"When read rules overlap, the more specific path wins"* —
so a broad `allowRead` *"can't silently re-expose a secret"* protected by a
narrower `denyRead`.

**Credential masking** is a mechanism worth noting on its own: the sandboxed
command sees a per-session sentinel; the proxy substitutes the real value only
on requests to declared `injectHosts`. *"The command and anything it logs never
hold the real credential, but its requests still authenticate."* Fails closed
without TLS termination, and is honored only from user/managed settings — a repo
cannot grant itself credential injection.

### Hooks: the deterministic layer

`PreToolUse` returns `permissionDecision` ∈ `allow` | `deny` | `ask` | `defer`,
optionally with `updatedInput`. **Exit codes invert Unix convention:** 0 =
success (stdout parsed as JSON), **2 = blocking error** (stderr fed to Claude),
anything else = non-blocking. [docs]

Composition with rules is precisely specified and **asymmetric**:

> *"Hook decisions don't bypass permission rules. Claude Code evaluates deny and
> ask rules regardless of what a PreToolUse hook returns… A blocking hook also
> takes precedence over allow rules. A hook that exits with code 2 stops the
> tool call **before permission rules are evaluated**."*

Net order: **hook-deny → rule-deny → rule-ask → mode → rule-allow → hook-allow
→ prompt.** A hook can only ever *tighten* relative to the rules, never loosen.

The paper counts **27 hook events** in v2.1.88 (docs list 30 in current
versions), grouped into tool authorization, session lifecycle, user interaction,
subagent coordination, context management, workspace, notifications; **15 have
event-specific Zod-validated output schemas**. Five hook command types:
`command`, `prompt` (LLM), `http`, `agent` (agentic verifier), `mcp_tool`.
[paper-B / docs]

The `if` field on a hook (permission-rule syntax) *"fails open: unparseable Bash
runs hook anyway. Best-effort; use the permission system for hard enforcement."*
[docs] — the doc is explicit about which mechanism is the guarantee.

### The auto-mode classifier

`yoloClassifier.ts`, gated by a `TRANSCRIPT_CLASSIFIER` feature flag; loads a
base system prompt plus an external (or Anthropic-internal) permissions
template, evaluates the proposed invocation against the conversation transcript,
and returns allow / deny / request-manual-approval [paper-B, §5.3].

Its input boundary is a deliberate injection defense [docs]: *"The classifier
sees user messages, tool calls, and your CLAUDE.md content. **Tool results are
stripped**, so hostile content in a file or web page cannot manipulate it
directly."*

There is also a **speculative classifier path** in the permission handler: when
enabled and the tool is Bash, it *"races a pre-started classification result
against a timeout. If the classifier returns with high confidence, the tool is
approved instantly without user interaction."* [paper-B, §5.2]

And a candid limitation [docs]: *"Boundaries are not stored as rules. The
classifier re-reads them from the transcript on each check, so a boundary can be
lost if context compaction removes the message that stated it. For a hard
guarantee, add a deny rule instead."*

### Documented threat model — what is explicitly not protected

The docs are unusually direct, and this candor is itself a design decision worth
imitating:

- *"**Permission rules are enforced by Claude Code, not by the model.**
  Instructions in your prompt or `CLAUDE.md` shape what Claude tries to do, but
  they don't change what Claude Code allows."*
- *"`bypassPermissions` offers **no protection against prompt injection**."*
- Read/Edit deny rules *"**don't apply to arbitrary subprocesses** that read or
  write files indirectly, like a Python or Node script."*
- *"Using WebFetch alone doesn't prevent network access. If Bash is allowed,
  Claude can still use `curl`, `wget`, or other tools."*
- The network proxy *"does not terminate or inspect TLS… code running inside the
  sandbox can potentially use **domain fronting**."*
- *"Bash permission patterns that try to constrain command arguments are
  **fragile**."*

### Where defense-in-depth actually failed

The paper's sharpest empirical finding [paper, external/Tier C]: commands with
**more than 50 subcommands** fall back to a single generic approval prompt
instead of running per-subcommand deny-rule checks — *"because per-subcommand
parsing caused UI freezes."*

The generalization is the reusable part: defense-in-depth rests on an
**independence assumption**, and here the layers *"share common performance and
economic constraints"* (the classifier is an LLM call with token cost;
`bashSecurity.ts` runs sequential AST checks with parsing latency), so *"when
performance pressure pushes toward reducing these costs, layers can degrade
simultaneously."* The stated evaluation criterion:

> **"not whether any individual layer can be bypassed, but how many independent
> layers must fail simultaneously and whether they share failure modes."**

The second architectural finding is **pre-trust initialization ordering** —
hooks, MCP server connections, and settings resolution execute *before* the
interactive trust dialog is shown (CVE-2025-59536, CVSS 8.7; CVE-2026-21852;
all patched within weeks). The lesson generalizes past this product: *"the
permission pipeline depicts a spatial ordering of safety checks but does not
capture the temporal dimension: **when** during session initialization each
mechanism becomes active."*

---

## Multi-Agent Support

### Subagents are a tool, dispatched through the same factory

The Agent tool (`AgentTool.tsx`, with `Task` retained as a legacy alias) is
*"dispatched through the same `buildTool()` factory as all other tools,
re-entering the `queryLoop()` with an isolated context window and returning only
a summary to the parent."* [paper-B, §8] There is no separate orchestration
runtime — delegation is a tool call that recurses into the loop.

### Definition format

Markdown with YAML frontmatter; only `name` and `description` are required.

```markdown
---
name: code-reviewer
description: Expert code review specialist. Use immediately after writing code.
tools: Read, Grep, Glob, Bash
model: inherit
---
You are a senior code reviewer...
```

Full field set [docs]: `name`, `description` (the routing signal), `tools`
(allowlist), `disallowedTools` (denylist), `model` (incl. `inherit`, the
default), `permissionMode`, `maxTurns`, `skills` (preloaded in full),
`mcpServers` (inline defs connect on start, disconnect on finish), `hooks`
(agent-scoped; `Stop` auto-converts to `SubagentStop`), `memory` scope,
`background`, `effort`, `isolation`, `color`, `initialPrompt`.

**Plugin-provided subagents cannot use `hooks`, `mcpServers`, or
`permissionMode`** — *"For security reasons… These fields are ignored when
loading agents from a plugin."* Distribution channel determines what a
definition is allowed to declare.

### Isolation is about inputs, not outputs

*"Each subagent starts with a fresh, isolated context window. It doesn't see
your conversation history, the skills you've already invoked, or the files
Claude has already read."* [docs]

But **CLAUDE.md is a deliberate exception** — the entire hierarchy reaches
subagents, along with a git-status snapshot and preloaded skills. The reasoning
shows in the exception to the exception: Explore and Plan skip CLAUDE.md and git
status *"to keep research fast and inexpensive"*, justified as *"The main
conversation reads Explore and Plan results with full CLAUDE.md context, so most
rules don't need to reach the subagent itself."* Rules must reach whichever
agent is making the decision the rules govern.

A subtle one: *"a subagent's context window is sized by **its own model**, not
the parent's."*

### Two independent tool filters

The first strips from *every* subagent regardless of `tools`: `Agent` (at depth
limit), `AskUserQuestion`, `EndConversation`, `EnterPlanMode`, `ExitPlanMode`,
`ScheduleWakeup`, `TaskOutput`, `WaitForMcpServers`, `Workflow` — i.e. anything
that would let a subagent talk to the user or restructure the session.

The second applies to **background** subagents (the default since v2.1.198),
reducing built-ins to a fixed list. All MCP tools are kept. *"The same
definition can resolve to different tools in the foreground and the
background."* [docs]

Order: `disallowedTools` applies first, then `tools` resolves against the
remainder. If nothing resolves, the launch **fails with an error naming the
entries** rather than launching a toolless agent — a fix in v2.1.208, because
before that it launched empty and returned confusing results.

### Permission inheritance rules are precise

A subagent's declared `permissionMode` applies **unless the parent is already in
`bypassPermissions`, `acceptEdits`, or `auto`** — *"those modes always take
precedence because they represent explicit user decisions about the
safety/autonomy trade-off."* [paper-B, `runAgent.ts`]

Two-tier scoping: when `allowedTools` is explicitly passed (SDK path),
SDK-level permissions are preserved but **session-level rules are replaced**;
when it is not (the common tool path), **the parent's session rules are
inherited without replacement**.

Prompt-avoidance cascade: explicit `canShowPermissionPrompts` → bubble mode
(always show, since it escalates to the parent terminal) → default (**sync
agents show prompts, async agents do not**). Background agents that *can* prompt
set `awaitAutomatedChecksBeforeDialog: true`, *"ensuring the classifier and
hooks resolve before interrupting the user."*

Under auto mode the classifier checks subagents at **three points**: the task
description before spawn, each action during the run, and the full action
history on return — *"if that return check flags a concern, a security warning
is prepended to the subagent's results."* [docs]

### Only the final message returns

Each subagent writes its own `.jsonl` sidechain plus a `.meta.json`, so
*"Subagent histories are preserved for debugging and auditing but do not inflate
the parent's session file. **Only the subagent's final response text and
metadata return to the parent conversation context**; the full subagent history
never enters the parent's context window."* [paper-B, §8.3] Subagent transcripts
are also unaffected by main-conversation compaction [docs].

The admitted cost: *"most subagent invocations require a **self-contained
prompt**, because the default path does not inherit the parent's conversation
history… Conversation-based frameworks that share full transcript histories
avoid this cost but risk context explosion as the number of agents grows."*

Motivating datum [Tier A]: agent teams consume roughly **7× the tokens of a
standard session in plan mode**.

### Isolation modes

*in-process* (default — shared filesystem, isolated conversation); *worktree*
(temporary git worktree branched from the **default branch**, not parent HEAD,
auto-cleaned if unchanged); *remote* (internal-only, always background).

The design-space placement is the interesting part [paper-C, §8.2]: container
isolation (SWE-Agent, OpenHands) gives stronger boundaries but requires
container infrastructure; context-only isolation (AutoGen) shares the
filesystem. **"Claude Code's worktree-based isolation provides filesystem-level
separation with zero external dependencies, leveraging Git's built-in mechanism
rather than introducing container orchestration."**

### Limits, and their churn

Depth **3 layers** below main by default as of v2.1.219 —
a default that has oscillated: 5 (v2.1.172–216) → 1 (v2.1.217–218) → 3. Session
total **200** subagents. Concurrent **20** — with a documented leak: *"Resuming
a finished subagent takes a fresh slot without checking the limit, so resumes
can push the running count past it."* [docs] The oscillating depth default is
worth reading as evidence that nobody has a principled answer here.

### Multi-instance coordination uses file locks, deliberately

*"the harness uses **file locking** rather than a message broker or distributed
coordination service. Tasks are claimed from a shared list via lock-file-based
mutual exclusion, with lock files stored at predictable filesystem paths. This
trades throughput for two properties: **zero-dependency deployment** and **full
debuggability** (any agent's state can be inspected by reading plain-text JSON
files)."* [paper-C, §8]

### Forks: the escape hatch from isolation

`/subtask` inherits the full conversation, system prompt, tools, and model.
*"This drops the input isolation that subagents otherwise provide… The fork's
own tool calls still stay out of your conversation and only its final result
comes back."* Output isolation is retained; input isolation is traded away. And
the cost argument: *"Because a fork's system prompt and tool definitions are
identical to the parent, its first request **reuses the parent's prompt cache**.
This makes forking cheaper than spawning a fresh subagent for tasks that need
the same context."* [docs]

### Message authority

Stated explicitly [docs]: *"a subagent treats messages from the agent that
launched it as normal task direction… Two limits still hold regardless of who
sent the message: **no message from any agent counts as your approval for a
pending permission prompt, and no agent message can change a subagent's
permission settings, CLAUDE.md, or configuration.**"*

The sub→parent seam is also treated as an injection boundary (v2.1.210+): a scan
inserts a backslash into text imitating control tags or `Human:`/`Assistant:`
line starts and prepends a `[harness: subagent output matched instruction-shaped
pattern(s): …]` marker. *"The scan never removes or rewords anything."* And the
honest limit: *"it doesn't change what an instruction in a report can do: a tool
call the report leads Claude to make still goes through the session's permission
checks."*

*(This survey's own research subagents both tripped that scanner, since their
reports discuss those very strings.)*

---

## Notable Design Decisions

### 1. Four extension mechanisms, graduated by context cost

The paper's most portable abstraction: **every** agent loop has exactly three
universal injection points — `assemble()` (what the model sees), `model()` (what
it can reach), `execute()` (whether and how an action runs). The four mechanisms
are then placed on those points [paper-C, §6.3]:

| Mechanism | Unique capability | Context cost | Insertion point |
|---|---|---|---|
| MCP servers | External service integration | **High** (schemas) | `model()` |
| Plugins | Packaging + distribution | Medium | all three |
| Skills | Domain instructions + meta-tool invocation | **Low** (descriptions only) | `assemble()` |
| Hooks | Lifecycle interception | **Zero** | `execute()` |

The argument for four rather than one: *"different kinds of extensibility impose
different costs on the context window, and **a single mechanism cannot span the
full range from zero-context lifecycle hooks to schema-heavy tool servers**
without forcing unnecessary trade-offs on extension authors."* The admitted
cost: *"it increases the learning curve developers face when deciding which
mechanism to use."*

The docs express the same taxonomy as a decision table:

| Mechanism | Loads | Solves |
|---|---|---|
| CLAUDE.md | Every session, in full | Facts true in every session |
| `.claude/rules/` with `paths:` | When a matching file is read | Facts true for part of the tree |
| Skills | Description always, body on invoke | Procedures |
| Subagents | Fresh context per invocation | Isolating verbose work; enforcing tool constraints |
| Hooks | Never (runs as code) | Determinism |
| MCP | Names always, schemas deferred | External systems |
| Plugins | — | Distribution and versioning of the above |

Running through every page is one distinction: **CLAUDE.md, skills, and rules
are context and therefore advisory; hooks and permission rules are code and
therefore enforced.**

### 2. Progressive disclosure has a concrete, three-tier mechanic

Skills [docs]: (1) descriptions only at session start, `description` +
`when_to_use` truncated at **1,536 characters combined**; (2) full `SKILL.md`
body injected on invocation as a single message that persists for the session;
(3) supporting files in the skill directory, read on demand, never auto-loaded.
`disable-model-invocation: true` removes even the description.

The nicest small detail: `${CLAUDE_SKILL_DIR}` is substituted in **both** the
body and the `allowed-tools` Bash rules, so a skill can run a bundled script
without prompting:

```yaml
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/render.sh *)
```

And `allowed-tools` grants permission **for the invoking turn only** — *"The
grant clears when you send your next message"* — even though the injected
content persists. Capability and context have different lifetimes.

Dynamic injection via `` !`command` `` runs **before** content reaches the
model: *"This is preprocessing, not something Claude executes."* Single-pass —
*"Command output is inserted as plain text and is not re-scanned"* — which
closes an obvious injection loop.

Note also that **slash commands were merged into skills**: *"A file at
`.claude/commands/deploy.md` and a skill at `.claude/skills/deploy/SKILL.md`
both create `/deploy` and work the same way."* Two mechanisms collapsed into
one after the fact.

### 3. Append-only storage, favoring auditability over query power

*"The append-only JSONL format is a deliberate choice favoring auditability and
simplicity over query power. Every event is human-readable, version-controllable,
and reconstructable without specialized tooling. Database-backed alternatives
would enable richer queries over session history but introduce deployment
dependencies and reduce transparency."* The named cost: queries like *"show me
all tool calls that modified file X across sessions"* require post-hoc
reconstruction. [paper-C, §9]

Three independent persistence channels: session transcripts (project-scoped,
one JSONL per session — an *event* log, not a message log: compaction markers,
file-history snapshots, attribution snapshots, content-replacement records),
a global prompt history (`history.jsonl`, read in reverse for Up-arrow/ctrl+r),
and subagent sidechains.

Two slogans capture the intent: *"Conversations Outlive Context"* — *"A
session's useful life cannot be capped by the model's context window."* — and
*"Conversations Outgrow a Single Path"* — the append-only transcript enables
rewind, resume, and fork.

### 4. Sessions are isolated trust domains — permissions are NOT restored on resume

Counted as a *safety layer*, which is an unusual framing, and the rationale is
worth quoting whole [paper-C, §9]:

> *"**sessions are treated as isolated trust domains.** Restoring previously
> granted permissions on resume would create a convenience benefit but risk
> carrying stale trust decisions into a changed context. The architecture opts
> for re-granting over implicit persistence, **accepting user friction as the
> cost of maintaining the safety invariant that trust is always established in
> the current session**."*

Session-scoped permissions live in memory only and are never serialized; resume
rebuilds from CLI args and disk settings, and anything the rebuilt context
doesn't recognize falls back to deny-first prompting.

### 5. Guidance vs. enforcement is a hard architectural line

Restated because it is the single most reusable idea in the survey. Natural-language
instruction (CLAUDE.md, skills, rules) is **probabilistic**, delivered as a user
message, explicitly documented as advisory. Enforcement (permission rules, hooks,
sandbox) is **deterministic code**. The docs never blur it: *"To block an action
regardless of what Claude decides, use a PreToolUse hook instead."*

### 6. Compaction as read-time projection, never destructive edit

Context collapse produces a *view*; the full history stays in a separate store.
Compaction boundaries carry chain-repair metadata so the on-disk transcript is
never rewritten. Compression is reversible for the operator even when
irreversible for the model.

### 7. A whole-object `State` replaced at every continue site

Small, structural, and directly transferable to a Lua loop: one mutable state
object, seven continue points, whole-object assignment at each rather than
field-by-field mutation.

### 8. Architecturally-predicted failure mode, named by the authors

Bounded context plus subagent isolation implies *"agent-generated code will
exhibit higher rates of pattern duplication and convention violation than code
produced with full codebase visibility… **parallel agents can independently
re-implement solutions that already exist elsewhere**. The design philosophy
trusts the model to make good local decisions, but good local decisions can
produce poor global outcomes when the model lacks global context."* [paper-C, §11.4]

Related: *"silent failures (denied requests, elided context, sandboxed commands)
are invisible to the model"*, and the paper argues closing that gap *"likely
requires additional scaffolding… rather than model improvements alone."*

### 9. KAIROS — proactivity bound to presence and token economics

Feature-gated and explicitly *"cannot be confirmed as active in production
builds"* [paper-B/C, §11.6]. A persistent background agent driven by **tick-based
heartbeats**: when no user message is pending, inject a periodic `<tick>` prompt
and let the model decide act-or-sleep. Two throttles: **terminal focus
awareness** (more autonomy when the user is away) and **economic throttling via
a SleepTool**, motivated by the fact that the prompt cache expires after five
minutes of inactivity, making sleep/wake an explicit cost decision. The paper:
*"This binding of proactivity to both user presence and token economics is
uncommon among production agent systems."*

### 10. The forward bet

*"as frontier models converge in practical capability for coding tasks: **the
quality of the surrounding operational harness becomes the principal
differentiator**… investing in deterministic infrastructure such as context
management, safety layering, and recovery mechanisms may yield greater
reliability gains than adding planning scaffolding around increasingly capable
models."* The paper raises the OS analogy explicitly: *"the core loop serves as
the kernel and everything else constitutes the OS."* [paper-C, §11.7]

---

## Relevance to Crescent

This section maps prior art onto crescent's current state. It **raises design
questions rather than answering them** — none of these are decisions, and
nothing here should be read as settled.

### Current state (read 2026-08-02)

- `lib/ai/tools.lua` (79 lines) is a bounded ReAct loop: `mod.run(opts)` calls
  `ai.generate` up to `max_rounds` (default 10), dispatches `res.tool_calls`
  against an `opts.handlers` table keyed by tool name, `pcall`s each handler,
  JSON-encodes non-string returns, appends `role = "tool"` messages, and
  terminates on either no-tool-calls or `nil, "max rounds exceeded"`.
- `lib/ai/types.lua` defines a **provider-neutral** message/tool/response shape
  ("not OpenAI-shaped, not Anthropic-shaped"), with `ai_http_client` injected
  as a cap — already consistent with caps-first.
- `lib/taskgraph/` (~570 lines excl. tests) has `graph`, `frontier`, `exec`,
  `exec_graph`, `context`, `combinators`.
- `lib/platform/apps/` currently holds six non-agent apps.

### Where Claude Code's decisions bear directly

**Structural parallels that already hold.** The core loop shape is the same
ReAct loop, and both accept the same tradeoff (no backtracking, one action
sequence per turn). Both inject transport as a cap. Both use a provider-neutral
tool shape. The prior art suggests the loop is not where the work is —
*"98.4% infrastructure"* — so the interesting question for `lib/ai` is which
of the surrounding systems belong in `lib/`, which belong in the app, and which
are out of scope entirely.

**Decisions crescent has not yet had to make**, each with a Claude Code answer
available as one data point:

1. **Tool result ordering under any future parallelism.** `tools.lua` executes
   handlers serially in `tool_calls` order, so the invariant holds by
   construction today. If parallel execution is ever considered, the prior art
   is: classify statically via an author-declared read-only flag, default to
   sequential, and buffer results back into request order.
2. **Tool result size.** `tools.lua` appends handler output verbatim with no
   budget. Prior art's answer is spill-to-file-with-reference rather than
   truncate, and doing it as the *first and cheapest* shaper.
3. **Where context management lives.** Currently nowhere. Prior art's structure
   is five shapers ordered cheapest-first, each targeting a distinct pressure
   source, with the strong warning that deriving context size from
   provider-reported `usage` silently misses savings from any shaper that edits
   history without changing the last assistant message. Crescent's `ai_response`
   carries `usage: { input_tokens, output_tokens } | nil` — the same trap is
   reachable.
4. **Tool definition scaling.** No registry exists yet. Prior art: schemas cost
   10–20K tokens at 50 tools and selection accuracy degrades past 30–50, with
   deferred loading + search as the answer above ~10 tools.
5. **The guidance/enforcement line.** Crescent already has a strong caps-first
   posture, which is an *enforcement* mechanism in the prior art's sense — a tool
   handler that receives no cap cannot do the thing, regardless of what the model
   was told. This is arguably a stronger position than a permission-rule engine,
   since it is structural rather than pattern-matched. Whether an agent app needs
   an *additional* rule layer on top of caps is an open question, not one this
   survey answers.
6. **`lib/taskgraph` vs. subagents.** Prior art treats delegation as an
   ordinary tool call that recurses into the same loop, with summary-only return
   and per-subagent sidechain transcripts, explicitly *not* a separate
   orchestration runtime; and coordinates multiple instances with file locks
   chosen for **zero-dependency deployment and plain-text debuggability** — the
   same constraint crescent operates under. Whether crescent's agent delegation
   should route through `lib/taskgraph` or through a recursive `tools.run` call
   is a real branch point with tradeoffs on both sides, and is not decided here.
7. **`max_rounds` semantics.** `tools.lua` returns `nil, "max rounds exceeded"`
   — the loop's only non-success terminal state. Prior art has five stop
   conditions and treats context overflow as *recoverable* (escalate output
   tokens up to 3×, then reactive compaction, then terminate). Whether crescent's
   loop should distinguish "budget exhausted" from "failed" is undecided.

### Conventions worth noting for a crescent equivalent

- **Naming predicts routing.** Prior art's guidance that
  `search_slack_messages` outperforms `query_slack` for tool selection is the
  same principle as crescent's existing naming convention (function names
  predict their signature), arriving from a different direction: the model is a
  reader too.
- **Refusing to offer unenforceable configuration.** `Bash(command:rm *)` is
  accepted-and-ignored-with-a-warning because it cannot be enforced against
  compound commands. Declining to ship a knob that cannot hold is a
  no-compromises move of the same shape as crescent's hard constraints.
- **The independence criterion for layered defenses:** *"not whether any
  individual layer can be bypassed, but how many independent layers must fail
  simultaneously and whether they share failure modes."* The >50-subcommand
  bypass happened because performance pressure hit multiple layers at once.
- **Temporal ordering of safety checks is a distinct axis from spatial
  ordering.** The pre-trust-initialization CVEs came from *when* mechanisms
  became active, not from which checks existed.

### Explicitly not addressed by this survey

No recommendation is made here on: whether crescent's agent app should have a
permission layer at all beyond caps; whether context compaction belongs in
`lib/ai` or the app; whether delegation routes through `lib/taskgraph`; what a
crescent tool-declaration format should look like; or whether MCP is worth
supporting. Each is a real branch point requiring a decision this document is
not authorized to make.

---

## Gaps

Things this survey could not establish, listed rather than guessed:

- **No auto-compaction threshold is published.** `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`
  and `autoCompactEnabled` exist; the default percentage appears in neither the
  docs nor the paper. The paper says auto-compact *"fires only when the context
  still exceeds the pressure threshold"* without stating the value.
- **Non-MCP tool-result truncation is undocumented.** The 10K/25K/500K numbers
  are MCP-specific. What happens to an oversized `Read` or `Bash` result is not
  stated anywhere public.
- **No `maxResultSizeChars` default values, no `maxTurns` default.** The only
  hard loop constants in the paper are `MAX_OUTPUT_TOKENS_RECOVERY_LIMIT = 3`,
  the once-per-turn reactive-compact flag, and the >50-subcommand bypass.
- **Tool-search wire format** (`defer_loading`, `tool_reference` content blocks)
  is named but not specified in the Claude Code docs.
- **No steering-queue documentation.** The paper contains zero occurrences of
  "steer"/"steering"; there is no public description of mid-turn user input
  injection or ESC/interrupt semantics beyond `abortController` and the sibling
  abort controller. Any claim about a steering queue is unsourced.
- **No process/thread model discussion.** The "single loop" claim is about
  control-flow shape, not about threading. No parallelism cap is published.
- **The paper's version (2.1.88) trails the docs (~2.1.220).** Constants,
  hook-event counts (27 vs 30), tool counts, and defaults have moved; the
  subagent depth default has oscillated 5 → 1 → 3 within that window.
- **Every "why" in the paper is reconstruction.** The authors say so directly.
  Anthropic has published no architecture rationale document that this survey
  found.

---

## Sources

Official documentation (fetched 2026-08-02):

- [How Claude Code works](https://code.claude.com/docs/en/how-claude-code-works)
- [Memory](https://code.claude.com/docs/en/memory)
- [Context window](https://code.claude.com/docs/en/context-window)
- [Subagents](https://code.claude.com/docs/en/sub-agents)
- [Permissions](https://code.claude.com/docs/en/permissions)
- [Permission modes](https://code.claude.com/docs/en/permission-modes)
- [Sandboxing](https://code.claude.com/docs/en/sandboxing)
- [Security](https://code.claude.com/docs/en/security)
- [Hooks](https://code.claude.com/docs/en/hooks)
- [Settings](https://code.claude.com/docs/en/settings)
- [Skills](https://code.claude.com/docs/en/skills)
- [Plugins](https://code.claude.com/docs/en/plugins)
- [MCP](https://code.claude.com/docs/en/mcp)
- [Agent SDK — agent loop](https://code.claude.com/docs/en/agent-sdk/agent-loop)
- [Agent SDK — custom tools](https://code.claude.com/docs/en/agent-sdk/custom-tools)
- [Agent SDK — tool search](https://code.claude.com/docs/en/agent-sdk/tool-search)

Third-party analysis:

- Zhiqiang Shen et al. (VILA-Lab), *Dive into Claude Code: The Design Space of
  Today's and Future AI Agent Systems*, arXiv
  [2604.14228v1](https://arxiv.org/abs/2604.14228) —
  [HTML](https://arxiv.org/html/2604.14228v1) ·
  [repo](https://github.com/VILA-Lab/Dive-into-Claude-Code) ·
  [PDF](https://zhiqiangshen.com/projects/Claude_Code_Report/Claude_Code_Report.pdf).
  Based on an extracted npm bundle of **v2.1.88**. Self-declared evidence tiers
  in §16.1; method limits in §16.3.

Distribution verification:

- [npm registry: `@anthropic-ai/claude-code@2.1.220`](https://registry.npmjs.org/@anthropic-ai/claude-code/latest)
  — license `"SEE LICENSE IN README.md"`, 7 files / 165 KB unpacked, per-platform
  binaries fetched by a `postinstall` script. **Not open source.**
