# opencode (SST) — agent harness prior art

Survey date: 2026-08-02. Repo verified live: <https://github.com/sst/opencode>, MIT,
actively developed, ~192k stars at time of survey.

**Source confidence.** Claims below are tagged where they rest on secondary sources.
Official docs (`opencode.ai/docs`) and repo source are primary; a third-party deep-dive
and DeepWiki are secondary and may lag the codebase. Anything marked [secondary] should
be re-verified against source before it drives a crescent decision.

## Overview

opencode is a terminal-first AI coding agent. The product surface is a TUI, but the TUI
is not the program — it is one client of a headless server that owns all state, provider
communication, and tool execution. The same server backs a desktop (Electron) app, a web
console, IDE integrations, and a generated SDK.

Runtime split: the server is JavaScript on Bun using Hono for HTTP; the TUI is Go using
Bubble Tea. Two processes, two languages, one HTTP boundary. Provider access goes through
the Vercel AI SDK, so the harness is provider-agnostic across Anthropic/OpenAI/Gemini and
a long tail of others rather than being written against one vendor's API shape.

## Architecture

The central decision is the **client/server split**, and everything else follows from it.

- `opencode serve` starts a headless HTTP server (default `127.0.0.1:4096`). Auth is HTTP
  basic via `OPENCODE_SERVER_PASSWORD`; `--cors` allowlists browser origins.
- The server exposes an **OpenAPI 3.1 spec at `/doc`**, and the client SDKs are *generated
  from that spec* (Stainless generates `opencode-sdk-go`). The API is the contract, not an
  afterthought — the Go TUI consumes the same generated surface a third-party integrator
  would.
- Endpoint families: global (health, event stream), sessions, messages, files, config,
  commands, agents, LSP/MCP/formatter status, auth.
- State changes propagate to clients over **Server-Sent Events**. Clients are pure
  renderers over a server-owned event log; multiple clients can attach to the same session
  simultaneously and stay consistent.
- Because the agent loop lives server-side, sessions survive terminal disconnects, SSH
  drops, and machine sleep. Detach/reattach is a property of the architecture, not a
  feature someone had to add. [secondary]
- Monorepo (Bun workspaces + Turbo): `opencode` (CLI+server), `@opencode-ai/sdk`,
  `@opencode-ai/plugin`, `@opencode-ai/ui` (Solid+Tailwind), desktop, web, and a
  console/team subsystem. A V2 CLI package is being written in Effect. [secondary]
- Sessions and messages persist through Drizzle ORM over a database backend, giving
  resumable conversations and an audit trail. [secondary]

Messages are **structured as parts**, not flat strings: a message is a sequence of text
parts, tool-call parts, and tool-result parts. This is what makes streaming, partial
rendering, and replay-to-a-new-client tractable.

The agent loop is `SessionPrompt.loop()`, built on the AI SDK's `streamText`: assemble
system prompt (provider-specific base + custom rules) + tool definitions + history, stream
the response, dispatch tool-call events to executors, feed results back, repeat until
`stopWhen` fires or a step budget is exhausted. [secondary]

## Tool-Calling Protocol

Tools are defined by a three-part structure — description (natural language), parameters
(Zod schema), execute function — and registered through a `Tool.define(id, init)` helper.
The framework wraps every tool with **automatic argument validation and automatic output
truncation**, so no individual tool implements either.

The execute context carries: session id, message id, agent name, an **abort signal**, the
session's message history, a `metadata()` callback to record a title and structured
metadata as the tool runs, and an `ask()` callback to request permission mid-execution.

The result shape is uniform:

```
{ title: string, output: string, metadata: object, attachments?: FilePart[] }
```

`title` is what the UI shows; `output` is what the model sees; `metadata` is what the UI
renders richly (diffs, counts, truncation flags). Splitting the human-facing and
model-facing channels of a tool result is a deliberate design choice — one field cannot
serve both without degrading one of them.

Built-in tools (13): `read`, `write`, `edit`, `apply_patch`, `glob`, `grep`, `bash`,
`lsp` (experimental), `skill`, `webfetch`, `websearch`, `question`, `todowrite`. The
`question` tool is notable — asking the user is itself a tool call, so a clarifying
question is a first-class, permissioned, loggable step rather than an out-of-band UI hack.

Extension paths:

- **Custom tools**: `.opencode/tools/` (project) or `~/.config/opencode/tools/` (global).
  Filename becomes the tool name; multiple named exports become `<file>_<export>`. Custom
  tools **override built-ins of the same name**, which is the sanctioned way to restrict or
  replace built-in behavior.
- **MCP servers**: local or remote, over JSON-RPC. MCP tools land in the same namespace and
  are subject to the same permission rules (`"mymcp_*": "deny"`).

## Context/Memory Management

- **Automatic compaction.** When token usage crosses a threshold, a dedicated summary
  prompt asks the model to distill prior work into actionable state, and the summary
  replaces the compacted history. [secondary]
- **`AGENTS.md` as the rules file**, resolved by walking up from cwd, then
  `~/.config/opencode/AGENTS.md`, then `~/.claude/CLAUDE.md` as a Claude Code fallback
  (disable with `OPENCODE_DISABLE_CLAUDE_CODE=1`). First match wins; project overrides
  global. `/init` generates one by scanning the repo. Reading a competitor's config file is
  a deliberate adoption-friction decision.
- **`instructions` field** in `opencode.json` takes globs *and remote URLs*, so shared
  org-wide rules can be pulled from a URL rather than vendored per repo.
- The docs explicitly recommend **on-demand loading** over preemptive loading: rather than
  inlining referenced docs, `AGENTS.md` should tell the agent to read them when needed.
- **`skill` tool + SKILL.md**: capability bundles loaded into the conversation on demand,
  i.e. context paging driven by the model's own tool call.
- **Todo state** (`todowrite`) is session-scoped in-memory task tracking — plan state that
  survives compaction because it is re-rendered, not recalled.
- **Git snapshot tracking**: `git write-tree` captures filesystem state before each step,
  enabling rollback. Undo is built on git plumbing rather than a bespoke journal.
  [secondary]

## Sandboxing & Permissions

There is no OS-level sandbox. The model is **policy-based mediation at the tool boundary**.

- Every rule resolves to one of three actions: `allow`, `ask`, `deny`.
- Configuration is a wildcard default (`*`) plus per-tool overrides; values are either a
  bare string or an object of pattern → action. Patterns support `*` and `?`, and `~` /
  `$HOME` expansion. **Last matching rule wins.**
- Granularity reaches inside tools: specific bash command patterns (`"git *": "ask"`) and
  specific file paths, not just whole tools.
- Permission targets include the tool set plus two non-tool guards: `doom_loop` (repetitive
  self-cycling) and `external_directory` (access outside the project root). Both are
  *behaviors*, not tools — permissioning a behavior is a distinct move from permissioning a
  capability.
- Checks run before execution; a denial sets a `shouldStop` flag that halts the agent loop
  rather than returning an error the model can route around. [secondary]
- `--auto` inverts the default to approve-unless-denied, so deny rules remain load-bearing
  in unattended runs.
- Agents carry permission overrides, so the restriction lives with the role.

## Multi-Agent Support

Two categories, distinguished by who invokes them:

- **Primary agents** — what the user talks to directly, switched with Tab. Built-ins:
  **build** (full tool access) and **plan** (analysis-only; `edit` denied, `bash` gated to
  ask).
- **Subagents** — invoked by a primary agent via the `task` tool, or by the user via `@`
  mention. Built-ins: **general** (full access), **explore** (read-only codebase),
  **scout** (read-only external research).

Invocation is `Task(description, prompt, subagent_type)`. Each subagent runs in a **new
session** with its own system prompt, tool restrictions, and optionally a different model.
It returns text. **Subagents cannot invoke subagents** — recursion is cut at depth one to
bound fan-out. [secondary]

Agents are configured either in `opencode.json` or as markdown files with YAML frontmatter
in `~/.config/opencode/agents/` or `.opencode/agents/`:

```yaml
---
description: Agent purpose
mode: subagent
model: provider/model-id
temperature: 0.1
steps: 40
permission:
  edit: deny
  "git *": ask
---
System prompt body.
```

`opencode agent create` walks the user through generating one. Prompt, model, temperature,
step budget, and permissions are all per-agent — an agent is a *policy bundle*, not just a
prompt.

## Notable Design Decisions

1. **The server is the product; the TUI is a client.** Stated inversion of the usual CLI
   agent shape. Buys: multi-client (TUI/desktop/web/IDE), detach-survivable sessions,
   scriptability, and a testable core with no terminal in the loop.
2. **The API contract is generated, not hand-maintained.** OpenAPI 3.1 at `/doc` → SDKs
   via Stainless. The first-party Go TUI eats the same generated client third parties get,
   so the public API cannot rot relative to the internal one.
3. **Two languages chosen per-layer.** Bun/TS server for AI SDK ecosystem access; Go TUI
   for a fast, single-binary terminal client. The HTTP boundary is what makes the mismatch
   affordable.
4. **Messages are parts, not strings.** Prerequisite for streaming, rich tool rendering,
   and reattaching a fresh client mid-run.
5. **Tool results carry a UI channel and a model channel separately** (`title`/`metadata`
   vs `output`).
6. **Validation and truncation are framework concerns**, applied by `define()` to every
   tool uniformly rather than per-tool.
7. **Asking the user is a tool** (`question`), inside the permission and logging system.
8. **Permissions extend to behaviors** (`doom_loop`, `external_directory`), not only to
   capabilities.
9. **Agent = prompt + model + tools + permissions + step budget**, declared in one
   frontmatter file, discoverable at project or global scope.
10. **Subagent recursion capped at one level.** [secondary]
11. **Undo via git plumbing** (`write-tree` snapshots) rather than a bespoke mechanism.
    [secondary]
12. **Reads `CLAUDE.md`.** Deliberate compatibility with the incumbent's context file to
    remove switching cost.
13. **Custom tools shadow built-ins by name** — the override mechanism is the extension
    mechanism.

## Relevance to Crescent

Current crescent state (read 2026-08-02): `lib/ai/` is 5 files — `init.lua`, `types.lua`,
`tools.lua` (79 lines), and `providers/{anthropic,google,openai,openai_compat}.lua`.
`lib/ai/tools.lua` exposes a single `mod.run(opts)` that loops `ai.generate`, dispatches
tool calls to a `handlers` table of `(args) -> string`, and stops at `max_rounds`.
`lib/taskgraph/` exists with graph/exec/frontier/context modules. `lib/platform/apps/`
holds six apps, none an agent.

Points of contact:

- **Tool result shape.** crescent's handlers return a bare `string`. opencode's
  `{title, output, metadata, attachments}` separates the model channel from the UI channel.
  If an agent app under `lib/platform/apps/` is to render tool activity at all, that split
  is needed before handlers proliferate — retrofitting a return type across handlers later
  is exactly the migration the disposition rules warn about.
- **Framework-level validation and truncation.** `tools.lua` currently does neither. Doing
  it once at the loop boundary is the opencode move; doing it per-handler is the thing to
  avoid.
- **Abort/cancellation.** opencode threads an abort signal through every tool context.
  crescent's `mod.run` has no cancellation path. Relevant to whether the agent loop can be
  driven by `lib/taskgraph`, which owns its own execution frontier.
- **Caps-first alignment.** opencode's injected execute-context (session, abort, `ask`,
  `metadata`) is structurally the same idea as crescent's injected caps, and its permission
  layer sits exactly where crescent already forces I/O to be injected. A crescent
  permission model can be enforced at cap-construction time rather than at call time —
  a stronger position than opencode's, since an unpermitted cap need not exist at all.
  (Design observation, not a decision — open question for the agent-app design.)
- **Client/server split.** opencode's case for it is multi-client + detach survival. Open
  question for crescent: whether an agent app wants a server boundary at all, given
  `lib/taskgraph` already provides orchestration and crescent has no multi-client
  requirement on the table. This is a genuine branch point, not a recommendation — the
  costs (IPC, serialization, a second process, an API contract to maintain) are real and
  crescent's zero-dependency constraint changes the math versus a Bun/Go monorepo.
- **Agent-as-frontmatter-file.** Prompt + model + tools + permissions + step budget in one
  declarative file is a cheap, testable format that maps onto crescent conventions without
  needing a server.
- **What does not transfer.** The AI SDK dependency, Zod, Drizzle, Effect, Stainless
  codegen, Electron, and the Solid/Tailwind UI stack are all excluded by crescent's
  zero-dependency rule. The *decisions* transfer; none of the substrate does.

## Sources

- <https://github.com/sst/opencode> — repo, README (verified live)
- <https://opencode.ai/docs/> — docs index
- <https://opencode.ai/docs/server/> — server, OpenAPI, SDK generation
- <https://opencode.ai/docs/permissions/> — permission model
- <https://opencode.ai/docs/agents/> — primary agents, subagents, frontmatter config
- <https://opencode.ai/docs/rules/> — AGENTS.md, precedence, `instructions`
- <https://opencode.ai/docs/tools/> — built-in tool list
- <https://opencode.ai/docs/custom-tools/> — custom tool authoring
- <https://raw.githubusercontent.com/sst/opencode/dev/packages/opencode/src/tool/tool.ts> —
  `Tool.define`, execute context, `ExecuteResult`
- <https://cefboud.com/posts/coding-agents-internals-opencode-deepdive/> — [secondary]
  agent loop, compaction, snapshots, subagent recursion cap
- <https://deepwiki.com/sst/opencode> — [secondary] monorepo layout, storage, event bus
- <https://pkg.go.dev/github.com/sst/opencode-sdk-go> — generated Go SDK surface
