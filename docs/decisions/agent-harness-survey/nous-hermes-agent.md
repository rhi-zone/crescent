# Nous Hermes Agent — harness survey

Survey date: 2026-08-02. Prior-art research for `lib/ai` expansion and a
prospective agent app under `lib/platform/apps/`. Not a crescent design
decision — a record of what an external system does.

## Overview

**The project is real and the name is essentially right.** It is
`NousResearch/hermes-agent` ("Hermes Agent"), an MIT-licensed open-source
agent harness from Nous Research, distinct from the Hermes *model* series and
distinct from Atropos (their RL-environments framework). Hermes Agent is
model-agnostic — it runs against Nous Portal, OpenRouter, OpenAI, Anthropic,
Bedrock, Gemini, or self-hosted endpoints; the Hermes models are a default,
not a requirement. Atropos appears in the repo only as the `tinker-atropos`
submodule used for RL training, i.e. an adjunct, not the harness itself.

Positioning: a long-lived personal agent that "lives on your server,"
reachable from CLI plus messaging surfaces (Telegram, Discord, Slack,
WhatsApp, Signal, email), with persistent memory and self-authored skills.
Stack: Python 3.11+ core, Node/JS for TUI and frontend, SQLite for state and
memory, one-line curl/PowerShell installers.

Confidence note: the repo README, the official docs site, and the (third-party,
LLM-generated) DeepWiki agree on the broad shape. Code-level claims below —
file names, defaults like "max recursion depth 1", "50 iterations" — come from
DeepWiki and the docs site and were **not** verified against the source tree.
Treat those numbers as reported, not confirmed. One direct inconsistency: the
landing page says five terminal backends, the README says seven (adds Daytona,
Vercel) — likely a stale page.

## Architecture

- `agent/` — core runtime, ~150 Python modules. Notable: `conversation_loop.py`,
  `context_engine.py`, `context_compressor.py`, `prompt_builder.py`,
  `model_tools.py`, `learning_graph.py`, `skill_bundles.py`. Subdirectories for
  `lsp`, `monitoring`, `transports`, `secret_sources`, `proxy_sources`.
- An `AIAgent` orchestrator (`run_agent.py`) owns the loop: iteration budget,
  tool dispatch via `handle_function_call`, state persistence. Standard
  generate → tool-call → execute → append → repeat cycle, i.e. structurally the
  same shape as `lib/ai/tools.lua`'s `mod.run`, with the additions being budget,
  persistence, compression, and approval hooks.
- **Gateway** — a routing layer between the agent core and the messaging
  surfaces, so one agent identity/memory is shared across channels. The gateway
  also drives unattended scheduled runs (natural-language cron).
- **Terminal backends** — execution is abstracted behind a backend interface
  (local, Docker, SSH, Singularity, Modal, Daytona, Vercel), selected in
  `terminal` blocks of `config.yaml`. The agent's shell tool is not "run on this
  box"; the box is a swappable capability.
- Per-provider adapters (`anthropic_adapter.py`, `bedrock_adapter.py`,
  `gemini_native_adapter.py`, …) normalise into one internal message/tool
  representation.

## Tool-Calling Protocol

- ~40+ builtin tools (file ops, terminal, web search, image gen, TTS, vision,
  browser automation), registered dynamically at runtime and exposed to the LLM
  as function schemas via `model_tools.py`. Tools group into **toolsets** that
  can be enabled/disabled per deployment; skills can declare
  `requires_toolsets` / `fallback_for_toolsets`.
- Three integration paths: native Python tool implementations, MCP servers, and
  external API wrappers.
- Slash commands are a separate registry (`COMMAND_REGISTRY`: `/new`, `/model`,
  `/approve`, `/deny`), i.e. user-facing control verbs are not modelled as LLM
  tools.
- Tools carry a risk classification; dangerous invocations are gated behind
  `/approve` / `/deny` rather than executed.

## Context/Memory Management

Three tiers, deliberately distinct:

1. **Procedural memory (skills).** A skill is a directory with a `SKILL.md`
   (YAML frontmatter: `name`, `description` ≤60 chars, `version`, optional
   `platforms`, `category`, `requires_toolsets`, `required_environment_variables`;
   body sections "When to Use / Procedure / Pitfalls / Verification"). Format is
   compatible with the agentskills.io open standard. All skills live in
   `~/.hermes/skills/` as the single source of truth. Each installed skill
   automatically becomes a slash command; up to five can be stacked in one
   message (`/a /b request`), with the first non-skill token stopping the parse.
2. **Episodic recall.** SQLite FTS5 full-text search over past sessions, with
   LLM summarization of hits, so the agent can retrieve its own history.
   Sessions persist under `~/.hermes/sessions/`.
3. **User modelling.** Honcho dialectic profiling across conversations.

**Progressive disclosure** is the load-bearing idea: `skills_list()` returns
only metadata (~3k tokens); `skill_view(name)` loads a skill body on demand;
`skill_view(name, path)` fetches a specific reference file inside a skill. Full
content is never resident by default.

**Compression** (`context_compressor.py`) uses head–middle–tail: system prompt
and opening exchanges protected, recent tail protected, middle summarized when
tokens cross a `threshold_percent` of the model's discovered context length.
Large tool outputs are replaced with one-line descriptions *before* the LLM
summarization pass, as a cheap pre-filter. Summaries are framed as "reference
only … the latest user message is the single source of truth" so stale
instructions cannot hijack behaviour. Per-session DB locks (with a background
lease refresher) prevent concurrent compression from forking a transcript.

**Self-improvement loop.** After completing a complex workflow the agent may
distill it into a skill via `skill_manage` (`create`/`patch`/`edit`/`delete`/
`write_file`/`remove_file`; `patch` preferred for token efficiency). `/learn`
turns supplied material or a described workflow into a conforming skill without
hand-writing the `SKILL.md`.

## Sandboxing & Permissions

- Isolation is delegated to the terminal backend: local (none), Docker
  (container hardening, namespace isolation), SSH (blast radius = remote host),
  Singularity, Modal/Daytona/Vercel (ephemeral cloud). Choosing safety is a
  config choice, not a code path.
- Command approval: risky commands gate on `/approve` / `/deny`. Subagents
  auto-deny dangerous commands unless auto-approval is opted into.
- **Skills Guard** — a static analyzer over externally-sourced skills scanning
  for data exfiltration, prompt injection, destructive commands, and
  supply-chain patterns. Trust tiers: `builtin`, `official`, `trusted`
  (OpenAI/Anthropic/HuggingFace), `community`. Community skills with any
  caution/dangerous finding are blocked; non-dangerous findings are
  overridable with `--force`, dangerous ones are not.
- **Memory scanning** — content bound for persistent notes is checked for
  injection/exfiltration patterns *before* it can enter the system prompt. This
  treats memory as an untrusted-input channel, which it is.
- `skills.write_approval: true` stages agent-authored skill writes for human
  review before commit.
- Messaging surfaces require DM pairing; API keys and operations are
  allowlisted.

## Multi-Agent Support

`delegate_task` spawns isolated child agents:

- Fresh context — children do not inherit parent conversation history, context
  files, or memory.
- Own `task_id`, so terminal and file operations are session-isolated.
- Restricted toolset: `delegate_task`, `clarify`, `memory`, `send_message` are
  blocked in children.
- Synchronous mode blocks the parent (parallel batches via ThreadPoolExecutor,
  default 3 concurrent); `background=true` returns immediately, with results
  stored durably in `state.db` and delivered through a completion queue.
- Recursion depth default 1 (no grandchildren); child iteration budget ~50.
  Parent shutdown propagates interrupt to children.

Additionally, "Python scripts that call tools via RPC" are offered as a
zero-context-cost pipeline: the model writes a script that drives tools
directly instead of round-tripping every call through the transcript. Details
of that RPC were not found in the sources consulted.

## Notable Design Decisions

1. **Context cost is the primary design axis.** Progressive disclosure,
   tool-output pre-summarization, subagents as context firewalls, and RPC
   scripting are four independent mechanisms all aimed at the same budget.
2. **Skills as durable procedural artifacts on disk**, in a documented
   interoperable format, rather than in-weights or in-transcript learning.
   Adopting an existing open standard (agentskills.io) instead of minting a
   format.
3. **Execution environment as a pluggable capability.** Seven backends behind
   one interface; the agent never assumes it owns a machine.
4. **Untrusted-content boundaries are explicit and scanned** at both entry
   points that write into the prompt: installed skills and persistent memory.
5. **Blocking the delegation tool inside subagents** — capability restriction as
   the recursion bound, complementing the numeric depth limit.
6. **Compression output is demoted to "reference only"** with an explicit
   source-of-truth rule, treating summaries as data rather than instructions.
7. **User-facing verbs are slash commands, not tools** — the human control
   surface is kept out of the model's action space.

## Relevance to Crescent

Observations only; each is a candidate, not a recommendation, and several cut
against existing crescent constraints.

- `lib/ai/tools.lua:17` (`mod.run`) is the same loop skeleton minus four things
  Hermes has: an iteration budget that returns partial state rather than
  `"max rounds exceeded"` with the work discarded, transcript persistence,
  compression, and an approval hook between "model requested tool" and "handler
  invoked". The approval hook is the cheapest and most consequential addition —
  today a handler is called unconditionally at `tools.lua:58`.
- The caps-first rule already forces what Hermes achieves with terminal
  backends: a crescent agent app cannot reach `io.popen`, so the execution
  environment arrives injected. Hermes converged on this from the other
  direction, which is corroborating evidence rather than a new idea.
- Progressive disclosure (`skills_list` / `skill_view` levels) is a protocol
  shape, not a framework, so it does not collide with "no framework code in
  `lib/`" — it is two tool handlers over a directory. Whether crescent wants a
  skill format at all is open.
- Subagent-as-context-firewall maps onto `lib/taskgraph`: an isolated child with
  a fresh transcript and a restricted handler table is expressible with the
  existing pieces. The blocked-tool-list technique for bounding recursion is
  worth noting independently of the rest.
- The "RPC script instead of transcript round-trips" idea is a natural fit for a
  Lua host — the model emitting Lua that calls injected caps directly. It is
  also the largest sandboxing liability in the whole design and would need the
  permission question answered first.
- Hermes' gateway/messaging surface, Honcho profiling, and cloud backends are
  out of scope for anything crescent has stated.

## Sources

- https://github.com/NousResearch/hermes-agent (repo, README, `agent/` tree)
- https://hermes-agent.nousresearch.com/ (official docs/landing)
- https://hermes-agent.nousresearch.com/docs/user-guide/features/skills
- https://hermes-agent.nousresearch.com/docs/developer-guide/creating-skills
- https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/features/skills.md
- https://github.com/NousResearch/atropos (distinct project — RL environments)
- https://deepwiki.com/NousResearch/hermes-agent (third-party LLM-generated wiki
  — source of the code-level details flagged as unverified above), incl.
  `/5.7-subagent-delegation`, `/8-skills-system`,
  `/8.1-skills-management-and-security`, `/10.1-context-compression`
- https://www.marktechpost.com/2026/06/24/nous-research-adds-learn-to-hermes-agents-skills-system-capturing-workflows-as-slash-commands-without-hand-writing-skill-md/
- https://www.marktechpost.com/2026/07/31/nous-research-ships-three-integration-paths-for-hermes-agent-and-buzz-blocks-open-source-nostr-workspace-for-humans-and-agents/
