# Userspace exploration: AI & agents

Facet of the "crescent as the entire computer" exploration. What do people
actually do with LLMs, what exists already in crescent, what's missing.

## 1. What people actually do

- **Chat-with-context.** Paste a doc/codebase excerpt into a chat window, ask
  for a summary, a rewrite, a diff. The entire interaction is: assemble
  context, send, read reply, maybe iterate. No memory beyond the visible
  transcript.
- **Roleplay / character chat.** Load a character card (personality,
  scenario, example dialogue, lorebook/"world info" entries that get
  keyword-triggered into context). Converse turn by turn. Regenerate,
  swipe, edit past turns, branch the conversation tree. This is SillyTavern's
  entire world — and it's a UI/context-assembly problem, not a model
  problem.
- **Agent loop / tool use.** User states a goal; the model proposes a tool
  call (read file, run shell, search web); the harness executes it and feeds
  the result back; repeat until done. Claude Code, Cursor, Aider, OpenAI's
  Codex CLI all do variations of this. The defining move is: model output ->
  structured action -> real-world effect -> observation -> next model call.
- **RAG.** Chunk a corpus, embed the chunks, store vectors, retrieve
  top-k by similarity for a query, stuff into the prompt. Used for
  "chat with your docs," search-augmented answers, character lorebooks
  (SillyTavern's World Info is literally keyword-triggered RAG, no
  embeddings needed).
- **Multi-agent coordination.** Split a task across role-specialized
  model instances (planner/coder/reviewer, or debate-style
  agree/disagree) that pass messages or a shared scratchpad. AutoGen,
  CrewAI, and a hundred hobby frameworks built around this.
- **Model/provider comparison.** Send the same prompt to two or three
  models, read outputs side by side, sometimes vote (LMSYS Chatbot Arena
  crowdsources exactly this at scale). Used both for picking a model and for
  building eval sets.
- **Local inference management.** Pull a GGUF, pick a quant, load it into
  llama.cpp/Ollama/LM Studio, point a chat UI at the local server. The
  entire workflow is model-file lifecycle + a serving process + an
  OpenAI-compatible endpoint other tools point at.
- **Prompt/preset engineering.** Iterating on a system prompt, few-shot
  examples, or a "preset" (temperature, top-p, stop sequences, prompt
  template) and saving it for reuse — SillyTavern's whole preset system,
  PromptFoo's eval-driven version of the same loop.
- **AI-assisted coding.** Inline completion (Copilot-style), agentic
  edit-and-verify loops (Claude Code, Cursor, Aider), and "ask about this
  codebase" chat. All three need the same substrate: file read/write,
  search, and a way to show the model a diff before it lands.

## 2. Prior art, briefly

- **SillyTavern / Kobold / Oobabooga** — chat/RP frontends over a
  swappable backend. SillyTavern's real contribution is the *context
  assembly pipeline*: character card + persona + world info (keyword RAG)
  + chat history + author's note, all folded into one prompt per turn,
  with token-budget trimming. Crescent already has an adapter
  (`lib/platform/apps/sillytavern/`) and a native card frontend
  (`lib/platform/apps/charactercardv2/`).
- **Claude Code / Cursor / Aider** — the agent loop plus environment
  affordances (file tools, shell, diffs, git). Aider is notable for
  being terminal-only and git-native; Cursor for IDE integration; Claude
  Code for running the loop headless/scriptable.
- **llama.cpp / Ollama / LM Studio / vLLM / MLX** — inference engines and
  their process-management wrappers. Different tiering (CPU GGUF vs
  Apple Silicon vs GPU-batched serving) — same shape as crescent's own
  system>FFI>pure-Lua tiering philosophy.
- **LangChain / DSPy / Rivet** — orchestration frameworks. LangChain is the
  cautionary tale: an ever-growing abstraction stack (chains, agents,
  memory classes) that papers over "call an LLM, do something with the
  result" until nobody can trace what actually ran. DSPy's contrast is
  interesting: it treats prompts as *compiled* artifacts optimized against
  a metric, not hand-authored strings — a discipline crescent's preset
  system (below) rhymes with.
- **AutoGen / CrewAI** — multi-agent-as-conversation frameworks: named
  agents exchange chat messages, and the "coordination" is just more
  chronological transcript, now with more participants. This is the
  pattern crescent's `docs/agent-design.md` explicitly rejects.
- **PromptFoo / LMSYS Chatbot Arena** — evaluation. Promptfoo is
  assertion-based prompt regression testing; Arena is pairwise human
  preference at scale. Neither exists in crescent yet.
- **MCP (Model Context Protocol)** — the emerging standard for exposing
  tools/resources/prompts to a model over JSON-RPC. Crescent has a
  server implementation (`lib/mcp/`, built on `lib/jsonrpc`) already.

## 3. What crescent already has

- **`lib/ai/`** — provider registry (anthropic, openai, google,
  openai-compatible generic) behind a uniform `generate`/`stream`
  interface, resolved by name at call time. This is the "send a prompt,
  get text back" primitive everything else sits on.
- **`lib/embed/`** — a vector index (cosine/euclidean/dot, add/search),
  the storage half of RAG. No chunking or embedding-model integration
  layer yet — that would compose `lib/ai/` (embeddings call) with this.
- **`lib/mcp/`** — MCP server on `lib/jsonrpc`: register tools, resources,
  prompts, handle the protocol handshake. This is crescent's tool-calling
  *transport*, already speaking the standard other agent hosts expect.
- **`lib/taskgraph/`** — a DAG executor with a `spawn`/`result` context
  API, frontier + exec-graph tracking for introspection. Task-shaped, not
  agent-shaped: nodes are typed tasks with dependencies, not a chat loop.
- **`lib/agent/`** (wip, small: `set.lua`, `leaf.lua`, `preset.lua`,
  `render.lua`) — the beginnings of the context-set substrate described
  in `docs/agent-design.md` (see section 4).
- **Adjacent ML that composes into agent behavior without being
  "agentic" itself**: `bayesian_filter`, `decision_tree`,
  `gradient_descent`, `knn`, `tfidf`, `markov_chain`, `neural`/`neural_net`,
  `behavior_tree`. These are classical/small-model tools — relevant
  because not every "AI" task in an app needs an LLM call; a
  `tfidf`+`knn` classifier is a legitimate, cap-free, zero-latency
  alternative for routing/classification that LLM-pilled ecosystems
  reach for a model call to do.
- **`lib/platform/apps/charactercardv2/`** — a working RP frontend: chat
  + chat-stream endpoints, conversation persistence (shared SQLite or
  in-memory fallback), card import (PNG metadata chunks + JSON), preset
  management via `kv`. Its manifest is a clean illustration of the cap
  model applied to an LLM app: `llm` cap keyed to a keyring entry
  (`crescent/anthropic`), `shared_db` optional with in-memory fallback,
  `self_write` so the card PNG stays a self-contained, shareable file.
- **`lib/platform/apps/sillytavern/`** — wip adapter, presumably for
  importing SillyTavern-format cards/presets into the native app rather
  than reimplementing SillyTavern.

## 4. The interesting part: deleting the concept of an agent

`docs/agent-design.md` (draft, unimplemented) makes a specific claim worth
restating because it's the actual answer to "what does crescent do
differently here": **context is an atemporal set of facts, not a sequence
of turns.**

Every other agent framework — AutoGen, LangChain agents, the "ReAct loop"
pattern everyone reimplements — represents state as a growing transcript:
system prompt, then a chronological list of (thought, action, observation)
turns, replayed in full on every model call. Crescent's design argues this
transcript-as-memory *is* the source of the well-known failure modes
(context poisoning from stale tool output, the model re-deriving or
contradicting its own earlier reasoning, context window bloat, the folk
wisdom of "start a new session when it goes sideways"). The chronology
isn't incidental to those problems, the design argues — it's the direct
cause, because nothing in a flat transcript can be un-said or
superseded; you can only append more tokens on top.

The fix crescent proposes: state lives in a **keyed set** (`note(key,
value)`, `drop(key)`, replace-not-append semantics). Every LLM call
constructs a fresh render of the current set. Tool results occupy exactly
one ephemeral slot — populated for the decision immediately following the
call, cleared after. Nothing accumulates by default; only what the model
explicitly `note`s into a named key survives to the next call, and a later
`note` on the same key *replaces* rather than piling on. Chronology, if
it's needed for audit, lives in a separate graph (`lib/taskgraph/`-shaped),
never in the prompt.

This is why "delete the concept of an agent" is the right description
architecturally, not just rhetorically: there's no persistent "agent
object" accumulating a history. There's a set (data), a render function
(pure, swappable per model), and **presets** — curated, tested task types
with declared input/output/note schemas — that are the actual unit of
reuse. An "agent app" is built by composing presets, not by writing a
bigger loop. That directly answers where taskgraph fits: taskgraph is the
DAG/audit substrate underneath the set (dependency tracking, spawn/result,
frontier introspection); the agent-set is the *what the model sees* layer
on top. Two different concerns that conversational-accumulation
frameworks conflate into one growing blob.

## 5. Crescent's cap model applied to AI tool use

The cap system is a genuinely good fit for the "tool use" problem that
every agent framework hand-rolls its own ad-hoc permissioning for
(LangChain's tool allow-lists, Claude Code's own permission prompts, MCP's
per-server trust). In crescent, an agent app's manifest already *is* the
tool-use policy:

- `llm` cap, keyed to a keyring entry — the app can't reach any provider
  it wasn't explicitly wired to, and the API key never touches app code.
- `exec` cap (per `agent-impl.md`'s plan) wraps `lib/exec` with a
  manifest whitelist — so "the model can run shell commands" is a
  declared, auditable capability grant, not an implicit `os.execute`
  reachable from anywhere.
- Every other tool the model can call is just another injected cap
  (`fs`, `kv`, `shared_db`, `http`...) — meaning an "agent" in crescent
  has *exactly* the blast radius its manifest declares, visible in one
  file, before any code runs. Compare to MCP servers today, which
  typically get all-or-nothing process-level access to whatever the host
  process can reach.
- The grammar-constrained `llm` generation cap mentioned in
  `agent-impl.md` (structured output enforced at the cap boundary, not
  by prompt-and-hope) means tool-call arguments can be typed and
  validated the same way any other crescent function boundary is —
  no bespoke JSON-schema-to-regex layer per framework, no silent
  malformed-tool-call retries.

The interesting design question this raises, not yet answered anywhere in
the repo: does a **preset** get its own cap manifest independent of the
app that hosts it (so a "summarize" preset declares it needs no caps at
all, while a "run tests and report" preset declares `exec`), letting cap
minimality be enforced per-preset rather than per-app? That would let an
app compose presets from different trust levels without hand-auditing
each one — genuinely novel relative to every other agent framework, all
of which grant tools at the agent-instance level, not the task-type level.

## 6. Gaps / open questions

- **RAG has storage (`lib/embed/`) and generation (`lib/ai/`) but no
  chunking/pipeline glue** connecting a document to an indexed,
  queryable set of embeddings. Given "no framework code in lib/," this
  probably wants to be a preset (agent-impl sense) rather than a new
  library — chunk-and-embed is a task type, not a primitive.
- **No local-inference story.** Every provider in `lib/ai/providers/` is
  a hosted API. Given crescent's zero-dependency, vendor-binaries-in-`dep/`
  posture, a llama.cpp-compatible local tier (FFI to a vendored
  `libllama.so` per platform, same pattern as `dep/` binaries elsewhere)
  would be consistent with the project's own rules — but is a real
  build-and-vendor undertaking, not a quick add.
- **No eval/comparison tooling.** Nothing like PromptFoo (assertion-based
  regression over prompts) or Arena-style pairwise comparison exists.
  Given presets are meant to be "battle-tested" with parity tests, an
  eval harness that runs a preset against a fixed input set and diffs
  outputs across model/provider swaps seems like the natural next
  library — and ties directly into crescent's existing fixture/snapshot
  test infra (`lib/test/`) rather than needing new machinery.
- **`lib/agent/` is genuinely unfinished** (`set`, `leaf`, `preset`,
  `render` exist; the exec/llm caps described in `agent-impl.md` do not
  appear built yet, per the doc's own "Status: not implemented"). This is
  priority 3 on the roadmap and the design doc is unusually
  well-specified for something unbuilt — worth treating `agent-impl.md`
  as closer to a spec-ready backlog than exploratory.
- **Multi-agent coordination** has no crescent story at all yet, and the
  design thesis argues most of what other frameworks call "multi-agent"
  (agents chatting with each other) is chronological accumulation with
  extra steps. What a set-based multi-agent primitive looks like —
  separate sets per role with explicit note-passing between them, maybe
  — is an open design question the current docs don't address.
