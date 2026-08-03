# Agent harness survey vs. agent-design.md

Status: synthesis. Maps the 26-project prior-art survey in
`docs/decisions/agent-harness-survey/` onto the draft decisions and open
questions in `docs/agent-design.md`. This document makes no design calls. It
lays out which surveyed projects bear on each open question and how, which
projects converge or diverge on agent-design.md's staked positions (carrying
their stated reasoning, not just the verdict), and what the survey surfaces
that the draft does not address at all. Every "recommendation" a survey file
made toward crescent is preserved here as an option with its cost, never
promoted to a verdict.

Grounding: `docs/agent-design.md` (draft, not implemented), the 26 files in
`docs/decisions/agent-harness-survey/`, `lib/ai/tools.lua` (79-line bounded
ReAct loop: `ai.generate` → dispatch `opts.handlers[tc.name]` under `pcall` →
append `role="tool"` messages → repeat to `max_rounds`, default 10, returning
`nil, "max rounds exceeded"` on exhaustion), and `lib/taskgraph/` (`graph`,
`frontier`, `exec`, `exec_graph`, `context`, `combinators`, plus an
`executor/` directory — a demand-driven spawn tree, not a BSP/event-bus
engine).

---

## Part 1 — agent-design.md's 8 open questions

### 1. Note value encoding

agent-design.md leaves open whether note values need a convention (short
strings vs. structured tables) beyond "whatever the LLM decides is useful."

- **Letta** (`letta.md`) is the closest structural analogue and cuts toward a
  convention existing regardless of what agent-design.md decides: memory
  blocks carry `label`, `description`, `value`, and a character `limit`, and
  the `description` field is "itself load-bearing — it tells the agent *when
  and how* to write to that block, making a block a small policy object
  rather than a string." That is evidence for structured metadata around a
  note's value, not for constraining the value's content type — compatible
  with agent-design.md's stance, but suggesting the *note key* itself might
  eventually want a description/purpose field alongside its content.
- **CAMEL**'s `ContextRecord` (`camel.md`) pairs every stored record with a
  relevance score at retrieval time — a orthogonal axis (retrieval scoring)
  that note-key replace-semantics doesn't need, since agent-design.md's
  design has no retrieval step by construction (notes are always in the set,
  never searched).
- **smolagents** (`smolagents.md`) keeps a *typed* step log (`SystemPromptStep`,
  `TaskStep`, `PlanningStep`, `ActionStep`, `FinalAnswerStep`) rather than
  untyped notes, and renders messages from it on demand
  (`to_messages(summary_mode=…)`). This is a structured-schema position
  directly opposed to agent-design.md's "content type is not prescribed" —
  smolagents' rationale is that a typed log enables re-rendering the same
  history differently per purpose (e.g., hiding old plans from the planner).
  agent-design.md's own note in the doc — that this is "open... not something
  to decide upfront" — means the smolagents alternative (schema now, not
  later) is a live option the draft has already considered and deferred.
- Silent/orthogonal: most other surveys don't have an atemporal-set analogue
  at all (see Part 2), so they have nothing to say about note *value*
  encoding specifically — their memory is chronological, so the question
  doesn't arise in their vocabulary.

### 2. Scale (does set-not-chronology hold on a 20-file refactor)

agent-design.md flags this as unproven beyond small-task evidence.

- **MetaGPT** (`metagpt.md`) is the most direct data point against pure
  in-context scaling: its strongest context idea is *not* a bigger or
  better-managed set — it's moving state **off the LLM's context entirely**
  onto the filesystem, with messages carrying only paths
  (`instruct_content`) and a git-backed artifact repo tracking a dependency
  graph. Their framing: "PRDs, designs, and code never travel through
  anyone's message history — only paths do." This is compatible with
  agent-design.md's set-not-chronology thesis (the set can hold a path, not
  the content) but suggests that at 20-file scale, the interesting design
  question shifts from "how big can the set get" to "what belongs in the set
  vs. on disk" — a question agent-design.md's notes mechanism doesn't yet
  distinguish.
- **Aider** (`aider.md`) offers a different scale answer for the same
  problem: a PageRank-ranked repo map re-computed per turn from a
  personalization vector biased toward files in the chat / mentioned by name.
  This is structural retrieval, explicitly rejected as a v1 scope item in
  agent-design.md ("Vector / embedding retrieval — structured queries via
  normalize first"), but Aider's map isn't embeddings — it's a
  tree-sitter-tags graph, closer to what crescent's own typechecker already
  builds. Whether that counts as "structured docs retrieval" (open question 5,
  below) or as evidence on the scale question is itself ambiguous and not
  resolved by either document.
- **LlamaIndex** (`llamaindex-agents.md`) is the sharpest *opposing* data
  point: its `Memory` design (token-budgeted buffer + pluggable eviction
  blocks: static, fact-extraction, vector) is presented explicitly as "the
  most complete in this survey" for a transcript-based design, and the survey
  itself says it should be read "as the strongest available statement of the
  case crescent's draft rejects: if the transcript model is kept, the
  budget/ratio/priority machinery is what keeping it costs." This is direct
  evidence *against* agent-design.md's anti-accumulation thesis being free —
  LlamaIndex's answer to scale is sophisticated eviction machinery over a
  transcript, which is exactly what agent-design.md is designed to avoid
  needing. Neither side has been measured against the other on the same
  task; the survey explicitly declines to say which is right.
- **browser-use** (`browser-use.md`) validates the general direction: its
  `MessageManager` rebuilds the prompt every step from a rendered
  `HistoryItem` log rather than appending to a transcript, explicitly to let
  "the harness — not the provider's message list — own exactly what the
  model remembers." This is architecturally the same move as
  render(set)→prompt, arrived at independently, and it's presented as a
  sharp divergence from the append-forever mainstream (including crescent's
  own `lib/ai/tools.lua` today).

### 3. Small-model feasibility

- **Nous Hermes Agent** (`nous-hermes-agent.md`) and **Gemini CLI**
  (`gemini-cli.md`) both validate skeleton-with-slots as a real, shipped
  pattern for weaker models: Gemini CLI ships a dedicated
  `AgentOutputFlashMode` schema reducing structured output to
  `{memory, action}` only, and **browser-use** goes further — three prompt
  variants (24 KB / 22 KB / ~1 KB) plus schema variants
  (`AgentOutputNoThinking`, flash mode `{memory, action}`) selected per model
  capability, stated as "the prompt is treated as a per-model artifact, and
  the response schema shrinks with it." This directly validates
  agent-design.md's "skeleton-with-slots... is a plausible middle ground" —
  multiple shipped systems already do exactly this, keyed on model tier
  rather than manually per-preset.
- **Continue.dev** (`continue-dev.md`) and **Cline** (`cline.md`) both
  maintain a *parallel text-based tool-calling protocol* for models without
  native function calling (`SystemMessageToolsFramework` in Continue,
  XML-in-text retained permanently in Cline "because reach for weak models
  was not sacrificed to get quality on strong ones"). This bears on grammar-
  constrained generation specifically: both harnesses found that native
  structured output is a *capability tier*, not a universal assumption —
  which is a direct challenge to agent-design.md's `llm` cap description
  ("grammar-constrained generation; takes a set, returns structured output")
  if that cap is meant to be uniform across model tiers. Neither harness
  resolves this by dropping structure for weak models; both add a second
  *protocol*, which is a different move than agent-design.md's skeleton
  fallback (protocol swap vs. schema simplification).
- **CrewAI** (`crewai.md`) documents the same fork as an open question
  crescent hasn't answered either: "does crescent's agent app need a
  text-parsed fallback loop for models without native tool calling?"

### 4. Render benchmarking per model

- **Aider** (`aider.md`) is the single most detailed data point: benchmarked
  JSON-tool-call code payloads against markdown fenced formats across
  multiple models, found JSON worse for every model tested (not just an
  average), and attributed the gap partly to escaping/formatting burden
  consuming problem-solving capacity, not just to malformed output. This
  directly validates agent-design.md's stance that render format should be
  "measured not assumed" — Aider is existing evidence that model-specific
  measurement changes the answer, not just the magnitude.
- **Cline** (`cline.md`) reversed direction over time: shipped XML-in-text
  first ("any model that can generate text can drive the agent"), later
  added native tool calling for models trained on it, citing measured
  reductions in malformed responses and ~15% fewer tokens. Kept both
  permanently, selected by model family. This is evidence that the "which
  render wins" answer is not static even for one project — it shifts as
  models are trained differently, reinforcing agent-design.md's "pick
  measured not assumed" but adding that the measurement needs to be
  re-run periodically, not once.
- **MetaGPT** (`metagpt.md`) chose the text-protocol side deliberately and
  paid a documented, itemized cost: a six-stage repair funnel including an
  extra LLM call for malformed JSON. This is a concrete cost profile for one
  render choice crescent could weigh against Aider's/Cline's native-calling
  numbers if `render(set)` is ever benchmarked.

### 5. Structured docs retrieval

agent-design.md states no `normalize docs` subcommand exists and leaves this
unresolved.

- Silent from almost every survey — this is a crescent-specific tooling
  question (normalize integration) that no external project has an opinion
  on by construction.
- The closest external analogue is **Aider**'s repo map (tree-sitter tags →
  PageRank → binary-search token-budget fit), flagged in `aider.md` as
  potentially buildable on crescent's own typechecker output ("a *stronger*
  source than tree-sitter tags... whether that information is exposed in a
  form a map builder could consume is unknown to this survey"). This bears
  on structured docs retrieval only if "docs" is read broadly enough to
  include code-structure retrieval, which agent-design.md's phrasing doesn't
  make explicit either way.
- **SK**'s ADR 0072 (`semantic-kernel.md`, context-based function selection)
  generalizes retrieval to *tool* selection, not docs — SK weighed
  caller-side vectorization, an invocation filter, and a "function
  advertisement filter" before landing on treating it as an
  `AIContextBehavior`. Orthogonal to the docs-retrieval question but
  structurally similar in shape (a per-turn retrieval-and-inject step) if
  crescent ever needs to retrieve *either* docs or tool schemas dynamically.

### 6. (Note: agent-design.md's list skips from 5 to 7 in the source file —
this is the document's own numbering, reproduced as-is, not a gap introduced
here.)

### 7. Failure semantics (retry / abandon-subtree / escalate-to-parent)

- **SWE-agent** (`swe-agent.md`) has the most granular enumerated exit-status
  model in the survey: ten terminal states (`submitted`, `exit_command`,
  `exit_command_timeout`, `exit_total_execution_time`, `exit_context`,
  `exit_cost`, `exit_format`, `exit_api`, `exit_environment_error`,
  `exit_error`), plus **autosubmission** on requery/cost exhaustion — "partial
  work is still work" rather than discarding a run. This directly bears on
  whether `lib/ai/tools.lua`'s current binary success/`"max rounds exceeded"`
  should become an enumeration, and offers a concrete list to enumerate
  against if crescent wants one.
- **CAMEL's `Workforce`** (`camel.md`) has the most structured *recovery
  ladder* in the survey: retry → replan (rewrite the task content) →
  reassign (different worker) → decompose (split into subtasks, re-inserted
  at the head of the pending deque) → create a new worker — bounded by
  `MAX_TASK_RETRIES` and a `halt_on_max_retries` circuit breaker, with a
  parallel `quality_score` triggering the same ladder even on nominal
  success. This is presented in the survey as the rebuttal CAMEL's own later
  generation wrote against its earlier "prompt discipline is enough"
  position — directly relevant if agent-design.md's failure semantics ever
  need more than binary success/fail per preset.
- **AutoGPT's abandonment of autonomy** (`autogpt.md`) is the sharpest
  counter-evidence for *not* over-building this: the project's own postmortem
  names "no termination criterion, no cost ceiling, no reproducible trace, no
  place for a human to intervene" as the root cause of its failure —
  suggesting failure semantics wants a hard structural answer per preset
  (crescent's stated lean, since agent-design.md defers this until "a real
  preset hits real failure") but that deferring the *category* of answer
  (not just its parameters) risks the same failure mode.
- **Goose** (`goose.md`) offers the most conservative default worth noting:
  turn-budget exhaustion yields to the human with a fixed message rather
  than aborting — "would you like me to continue?" — treating budget
  exhaustion as a UX event, not a failure state. This is one option on the
  spectrum agent-design.md's "deferred until a real preset hits real
  failure" leaves open.

### 8. First concrete app (narrow preset-only vs. small generalist)

**Resolved since this document was written.** agent-design.md no longer
frames this as a choice between narrow-first and small-generalist — the
owner decision recorded there is to build both as separate first apps: a
narrow preset-only instance (a file-management library exposing filesystem
operations behind a cap, sequenced before any UI or agent projection onto
it, per the one-authoritative-store principle) and a small generalist app
(scope still open). The narrow-first *lean* that the analysis below was
written against is now specifically the narrow instance of a two-app plan,
not the sole first app; the survey's convergence/countervailing evidence
below still applies to that narrow instance and, for the CAMEL point, to
what the still-unscoped generalist app may cost.

- **smolagents**' published agency ladder (`smolagents.md`) is the strongest
  direct validation of "narrow first" as a general design stance, not just a
  scheduling call: "For the sake of simplicity and robustness, it's advised
  to regularize towards not using any agentic behaviour," and the docs
  actively argue *against* using the framework for router/chain cases the
  developer could hand-write. This validates agent-design.md's "Non-goals:
  General AI assistant. Agents are narrow, auditable" and its narrow-first
  lean for the first app, from a project whose docs make the same argument
  as policy rather than as a one-off scheduling choice.
- **AutoGen's own docs** (`autogen.md`) argue the identical direction from
  the opposite side of the industry (an enterprise multi-agent framework
  telling users to "start with a single agent for simpler tasks, and
  transition to a multi-agent team when a single agent proves inadequate,
  because teams demand more scaffolding"). Two very differently-positioned
  projects converge on the same ordering.
- **Pi** (`pi.md`) is the sharpest validation of narrow-first taken to an
  extreme: no sub-agents, no MCP, no plan mode, no built-in to-dos in core —
  "every one is reachable via extension," described in the survey as "the
  clearest example in the survey of a harness treating 'what not to build'
  as the primary design work." This bears on *how* narrow the first app
  should be, not just whether: Pi's core omissions are all things
  agent-design.md's non-goals section already excludes (Chat UI, general
  assistant, frameworks-before-primitives), so Pi is corroborating evidence
  for the non-goals list specifically, not just the narrow-first lean.
- Countervailing (not a direct challenge, but a scoping note): **CAMEL**'s
  generation-1→generation-2 arc (`camel.md`) shows that starting narrow
  (two-agent role-play with prompt-enforced protocol) doesn't guarantee the
  *next* step is small — CAMEL's own fix required a coordinator, planner,
  typed task channel, retry budgets, and a summarizer. This doesn't argue
  against narrow-first for the *first* app, but it's evidence that "narrow
  first" doesn't bound how much substrate the *second* app costs if it needs
  coordination — relevant context for reading agent-design.md's "one narrow
  agent per task class, not one mega-agent" line as an ongoing policy, not a
  one-time decision.

---

## Part 2 — Already-staked decisions: convergence and divergence

### Memory as an atemporal set of facts (rejecting conversational accumulation)

**Converge, independently arrived:**

- **browser-use** (`browser-use.md`) is the single clearest independent
  convergence in the whole survey. Its `MessageManager` keeps *two* messages
  (system + a rebuilt-per-step state message) rather than an accumulating
  transcript, explicitly because "the harness — not the provider's message
  list — own[s] exactly what the model remembers, and can compress, elide,
  or reorder it freely." The survey calls this "the sharpest divergence from
  the mainstream tool-calling loop (including crescent's current
  `lib/ai/tools.lua`)." This is architecturally the same move as
  render(set)→prompt at every call, reached from browser-DOM-grounding
  pressure rather than from a stated anti-accumulation thesis.
- **smolagents** (`smolagents.md`) reaches a related but not identical
  position: a *typed step log* (not a flat message array) with
  `to_messages()` rendering on demand and `summary_mode` producing different
  renders for different consumers (e.g., hiding old plans from the
  planner). This is compatible with "the set is canonical, the render is
  derived," but the underlying structure is still a chronological list of
  typed steps, not an unordered set with replace semantics — closer to
  agent-design.md's *pragmatic* claim (render as turns) than its *load-bearing*
  claim (context is atemporal).
- **MetaGPT**'s `Memory` (`metagpt.md`) uses per-role subscription filtering
  at *intake* ("context membership is decided at intake by a subscription
  predicate, not at prompt-assembly time by relevance scoring") — a role's
  memory contains only what it subscribed to. This converges with
  agent-design.md's instinct that irrelevant content shouldn't accumulate,
  but the mechanism (subscription-based filtering of an ever-growing log) is
  a different solution to a related problem than field-level replace
  semantics.

**Diverge, with stated rationale carried:**

- **LlamaIndex** (`llamaindex-agents.md`) is the most explicit and complete
  divergence, and the survey names it as such directly: "LlamaIndex is best
  read here as the strongest available statement of the case crescent's
  draft rejects: if the transcript model is kept, the budget/ratio/priority
  machinery is what keeping it costs." Their `Memory` design treats context
  management as "a budget allocation problem with a pluggable eviction
  policy" — three interchangeable long-term memory blocks (static,
  fact-extraction, vector), each with a `priority`, truncated in priority
  order when the budget is still exceeded after flushing. Their stated
  position is that this is "the most fully-specified memory design among the
  harnesses surveyed" — i.e., their argument isn't that transcripts are
  free, it's that transcripts plus well-designed eviction beat the
  alternative on their own terms. Neither this document nor
  `llamaindex-agents.md` claims to have resolved which is actually better;
  the two positions have not been measured against each other on the same
  task, per agent-design.md's own open question 2 (scale).
- **AutoGen**'s `ChatCompletionContext` (`autogen.md`) is explicitly "a
  strategy object injected into the agent, not a heuristic buried in the
  agent" — `UnboundedChatCompletionContext`, `BufferedChatCompletionContext`
  (MRU), `TokenLimitedChatCompletionContext`, `HeadAndTailChatCompletionContext`.
  This is a transcript-preserving design (all four variants operate over a
  message window), but the *reason given* — decoupling "what the model
  sees" from a single hardcoded policy — is the same motivating concern
  agent-design.md's render-as-a-pure-function claim addresses, applied to a
  chronological rather than atemporal substrate.
- **Semantic Kernel**'s reducers (`semantic-kernel.md`) — truncation vs.
  summarization, always preserving system messages — are a smaller-scale
  version of the same divergence: managing a transcript rather than
  replacing it with a set.
- **Letta/MemGPT** (`letta.md`) diverges from a different angle: its memory
  blocks *are* structured, replaceable, addressable state (closer to
  agent-design.md's notes than a transcript), but the mechanism for
  *deciding* what to write is "the LLM is its own memory manager" — no
  retrieval heuristic decides what enters context, the model calls tools
  (`memory_replace`, `memory_rethink`, etc.) to promote/demote information
  explicitly. This partially converges with agent-design.md's note()
  primitive (LLM-authored, addressable, replace-semantics for `rethink`) but
  diverges on scope: Letta's blocks are cross-session persistent identity
  state, while agent-design.md's notes are explicitly per-task and not
  shared across tasks. The stated Letta rationale for cross-session
  persistence — "statefulness is the product... resumability, multi-agent
  sharing, approval-across-restart... are all consequences" — is a goal
  agent-design.md's "Out of scope for v1: Persistent daemon agents" appears
  to exclude, making this divergence more a scope difference than a design
  disagreement.

### Presets as the primary composition surface (not per-run LLM-authored code)

**Converge:**

- **SWE-agent's ACI thesis** (`swe-agent.md`) is the closest structural
  analogue: a small curated command set, arrived at by "manual inspection of
  agent trajectories... and a grid search," with the paper's own ablation
  data showing a *hand-designed* iterative search interface performed worse
  than no search tool at all, because "an interface copied directly from
  what works for humans... performed worse than having no search tool at
  all" — agents exhaustively called `next` until budget exhausted. This
  validates agent-design.md's "correctness... presets have parity tests,
  known failure modes, fixes committed and durable" argument for
  battle-tested presets over ad hoc constructs, with quantified evidence
  that "obviously good" interfaces can be measurably worse without testing.
  Caveat carried from the same survey: SWE-agent's own successor
  (mini-swe-agent) *removed* the curated ACI, arguing the deficits it
  compensated for were 2024-era model deficits, not permanent facts about
  interfaces — a live tension the survey states plainly and does not
  resolve, and directly relevant to how durable any given crescent preset's
  design choices will be as models improve.
- **AutoGPT's abandonment of autonomy** (`autogpt.md`) is the sharpest
  historical validation: the original recursive goal-loop agent was
  discontinued specifically because "unbounded recursive planning is not a
  product," replaced by "humans design the boundaries, the LLM makes
  choices inside them" — a block/graph platform where tool availability is
  *defined by canvas wiring*, not runtime LLM code generation. This
  corroborates the correctness/audit argument in agent-design.md ("Ran
  preset P with inputs I" is a tight audit line" vs. "Ran these 40 lines of
  LLM-generated Lua" is opaque") almost verbatim — AutoGPT's own postmortem
  names debuggability and reproducibility as exactly what the autonomous
  version lacked.
- **Semantic Kernel's planner deletion** (`semantic-kernel.md`) converges
  from a different direction: SK's original planners (Stepwise/ReAct-style,
  Handlebars/emit-a-whole-program) were deleted entirely once native
  function calling arrived across providers, on the grounds that "function
  calling is both more powerful and easier to use for most scenarios." This
  is not quite the same axis as presets-vs-LLM-code (SK's planners generated
  *plans*, not arbitrary code), but it's a data point that a framework
  which tried "let the LLM write the control flow" walked it back in favor
  of a fixed automatic loop plus declared functions — closer to
  agent-design.md's preset model than to per-run code generation.

**Diverge, with stated rationale carried:**

- **smolagents** (`smolagents.md`) is the most direct and best-argued
  divergence in the entire survey. Its central thesis is the opposite of
  agent-design.md's: "the LLM's action is a block of Python code, not a JSON
  tool call," with four *stated* advantages — composability (loops,
  conditionals, reusable definitions are free in code but not in a fixed
  tool schema), object management (code keeps output in a variable; JSON
  must serialize or invent a handle scheme), generality (code expresses
  anything a computer can do; a tool schema only expresses what was
  pre-declared), and training-data representation (models have seen far
  more Python than bespoke action formats). The measured cost claim: "~30%
  fewer LLM calls" than JSON tool-calling, because one code block can fan
  out where JSON needs one round-trip per call. smolagents does *not* argue
  this is free — its largest engineering investment is a custom AST-walking
  Python interpreter built specifically to make code-as-action safe enough
  to ship (import allowlist, dunder-attribute blocking, operation caps),
  which the survey frames as "a strong signal about what the thesis actually
  costs." This is presets-over-code's mirror-image argument, made with
  benchmark numbers, and it is not addressed anywhere in agent-design.md.
- **Open Interpreter** (`open-interpreter.md`) makes the code-as-action
  argument even more radically: not discrete tools reflected from code, but
  *one tool, and the tool is a language* — the model writes arbitrary Python
  against a pre-imported `computer` object, with no JSON Schema anywhere in
  the path. The survey's own framing of the tradeoff: "composition and
  state are free, the catalogue is one generated block, but there is no
  argument validation, errors are tracebacks, and — the load-bearing part —
  per-capability permission becomes impossible, because once the model can
  write Python it can reach anything the interpreter can reach." This is
  the sharpest statement in the whole survey of code-as-action's actual
  cost: it is fundamentally in tension with any capability-scoped
  permission model, which bears directly on crescent's caps-first
  discipline specifically (not just on agent-design.md's presets stance) —
  the survey names this as "the load-bearing part" of the tradeoff.
- **MetaGPT's Data Interpreter / `RunCommand`** (`metagpt.md`) began as
  code-as-action (Python API documentation, model writes a ```python block
  executed in a persistent kernel) and *also* migrated toward more
  structure over time (`ActionNode`s, a JSON command protocol) — but never
  fully to presets; MetaGPT's structure is closer to typed, schema-validated
  natural-language-instruction artifacts than to reusable typed
  input/output/cap-manifest presets. A third point on the spectrum between
  agent-design.md's presets and smolagents'/Open Interpreter's code-as-action.
- **CrewAI**, **AutoGen**, and **LangGraph** (`crewai.md`, `autogen.md`,
  `langgraph.md`) all converge on a middle position not directly named by
  either presets-vs-code: developer-authored deterministic control flow
  (Flows, GraphFlow, `Command`/`Send` routing) as the production answer,
  with LLM-driven routing as an available but secondary mode. This is
  closer to agent-design.md's presets-as-primary-composition-surface stance
  than to smolagents' code-as-action, but the *unit of composition* in
  these three is a graph/flow object authored by a developer at design
  time, not a preset selected/parameterized by an LLM at run time —
  a real difference agent-design.md's "presets... selected, parameterized,
  and composed" doesn't disambiguate for itself.

### Agents as platform apps (lib/platform, caps, per-app tarball)

**Converge:**

- **Cline**'s host-provider abstraction (`cline.md`) and **pi**'s
  `ExecutionEnv` injection (`pi.md`) both converge, independently, on
  exactly the shape agent-design.md's "Caps are the only side-effect
  surface → tools are caps" line describes. pi's version is described in
  its own survey as "functionally the same discipline crescent calls
  caps-first" — all filesystem/process access for built-in tools goes
  through one injected `ExecutionEnv`, isolated in a single file, which is
  what makes pi's Gondolin pattern (routing tool execution into a
  micro-VM while keeping the model/credentials on the host) possible as an
  *extension* rather than a fork.
- **Continue.dev**'s `ContextProviderExtras` (`continue-dev.md`) is named in
  its own survey as "the same caps-first shape, arrived at independently" —
  `ide`, `fetch`, `llm`, `embeddingsProvider` are injected, never reached
  for globally.
- **openai-agents-sdk**'s local-context/LLM-context split
  (`openai-agents-sdk.md`) — `RunContextWrapper[T]` explicitly "not sent to
  the LLM," a typed dependency-injection object for DB handles, identity,
  etc. — converges on the same caps-injection principle applied to what a
  tool function receives, though the SDK's own survey notes this remains
  weaker than crescent's stance in one respect: cap *presence* in these
  systems is a convention tool authors must follow, not a structural
  guarantee. Multiple surveys (`autogen.md`, `semantic-kernel.md`) name this
  same gap explicitly as a place crescent's structural cap-absence-errors
  model is *ahead* of the prior art, not merely equivalent to it.

**No genuine divergence found** — no surveyed project argues *against*
capability injection as a principle. The divergence that exists is about
*how much* is caps-first: CrewAI (`crewai.md`), CAMEL (`camel.md`), MetaGPT
(`metagpt.md`), and Letta's local sandbox path (`letta.md`) all give tools
ambient process authority by default, but none of these projects *argue for*
ambient authority as correct — CrewAI's own trajectory (deprecating and
removing `CodeInterpreterTool`, redirecting users to E2B/Modal) and Letta's
"isolation outsourced... local path is a subprocess with an optional venv,
defaulting to `use_venv: False`" read as unresolved gaps in those projects
rather than as counter-arguments. The "agents as platform apps" framing
itself (tarball as canonical form, operator grants caps per-app, "apps are
cheap") has no close analogue in any surveyed project — the nearest partial
match is **opencode**'s agent-as-frontmatter-file (`opencode.md`: prompt +
model + tools + permissions + step budget declared in one file,
discoverable at project or global scope), which converges on "an agent is a
declarative, diffable artifact" but has no tarball/sandbox/installer
apparatus around it — opencode has no equivalent to crescent's "operator
grants caps per-app → permission dialog for free" because opencode has no
platform-app installation model at all.

---

## Part 3 — What the survey surfaces that agent-design.md does not address

These are gaps in the draft — things multiple independent projects treat as
load-bearing that agent-design.md's text does not mention at all, not
restatements of the 8 already-open questions above.

1. **Tool-result size / spill-to-file — resolved since this document was
   written, superseding what follows as a "gap."** Claude Code (10K/25K-token
   thresholds, spill to disk with a reference), Goose (`GOOSE_MAX_TOOL_RESPONSE_SIZE`,
   default 200,000 chars, spilled to a temp file with the model told the
   path), browser-use (two-tier `extracted_content`/`long_term_memory`
   split, 60,000-char hard cap), and AutoGPT ("a large output is treated as
   a *failure of the call*, not as data to be squeezed") all treat oversized
   tool output as a first-class problem with a named mechanism. At the time
   this comparison was written, agent-design.md's "current tool result is
   one slot, not a growing list" described the *lifetime* of a tool result
   but said nothing about its *size* — a tool call returning 200KB still
   occupied that one slot in full. agent-design.md has since resolved this
   explicitly. (The "current tool result" slot itself was also removed as a
   special case in the same round of edits — tool results now go through the
   ordinary add/remove/replace field-op path like any other set contributor,
   with no source getting a hardcoded slot other sources don't.) An oversized
   result is always
   exactly one of two things — **legitimately large and relevant**, handled
   by the ordinary field-op path (the leaf reads it once, extracts what
   matters via `note()`, the rest disappears structurally when the field is
   removed, no size-specific handling needed), or **never supposed to reach
   the agent whole**, in which case an oversized-and-opaque result is a
   defect in the tool/cap's own contract, fixed at the cap, not patched
   around in the harness. Truncation and bounded-output contracts are
   rejected outright, not left open, as artifacts of the conversational-
   accumulation model this design replaces. This is a real point of
   divergence from every mechanism named above, all of which are exactly the
   truncation/spill-to-file/hard-cap machinery agent-design.md now rejects by
   name — worth reading as a considered position against the survey's
   consensus, not a silent gap.

2. **Approval/permission gating as a control-flow mechanism distinct from
   caps.** agent-design.md's caps-first framing (a tool handler errors if a
   cap wasn't injected) is a *static* authorization boundary decided at app-
   install time. Nearly every surveyed harness additionally has a *dynamic*,
   per-call approval mechanism sitting on top of whatever authorization
   exists underneath: Claude Code's seven-layer permission pipeline,
   openai-agents-sdk's durable serializable `RunState` pause/resume around
   `needs_approval`, Letta's approval-as-a-persisted-message-role (denial
   carries a reason back to the model, and can be answered across process
   restarts), OpenHands V1's `SecurityAnalyzer`/`ConfirmationPolicy` split
   (risk assessment separated from enforcement, replaceable independently),
   and Goose's `ToolInspector` pipeline (ordered list of inspectors, each
   returning `Allow | Deny | RequireApproval` with a confidence score).
   agent-design.md is silent on whether a granted cap can still require
   *per-call* human sign-off, and if so, whether that's a preset-level
   knob, an app-level default, or (per openai-agents-sdk's strongest single
   idea in this space) a durable, resumable, out-of-process pause. This is
   a genuine gap: caps-first answers "can this app reach the filesystem at
   all," not "does this specific write need a human to look at it first."

3. **What crosses a leaf boundary when a preset composes with a task graph
   node that fails partway.** agent-design.md states "nothing mutable
   crosses a leaf boundary... retries re-run from inputs," but several
   surveys converge on richer failure-recovery machinery that re-runs *less
   than the whole leaf*: SWE-agent's ten-way exit-status enum plus
   autosubmission of partial work, CAMEL's `Workforce` recovery ladder
   (retry → replan → reassign → decompose, in that order, with the failed
   task's content rewritten rather than only re-run verbatim), and Codex
   CLI's response-id bookmarking/forking (any earlier point in a
   conversation can become the root of a new branch). agent-design.md's
   "retries re-run from inputs" is a clean, simple answer, but it is also
   the position several other projects moved away from after finding
   verbatim re-run insufficient — worth flagging as a gap since
   agent-design.md doesn't cite or rule out the richer alternatives, and its
   open question 7 (failure semantics) is scoped to "retry / abandon-subtree
   / escalate-to-parent" without mentioning replan/decompose as options.

4. **Context-window overflow as a distinct, structural failure mode with its
   own recovery path**, separate from ordinary tool-loop failure. Claude
   Code's five compaction shapers (each targeting a *different cause* of
   context pressure — budget reduction, snip, microcompact, context
   collapse, auto-compact — ordered cheapest-first) and its documented
   `prompt_too_long` API-level recovery sequence, Gemini CLI's explicit
   `ContextWindowWillOverflow` pre-check *before* sending a request rather
   than discovering overflow from an API error, and Continue.dev's explicit
   "non-negotiable set" (system message, tools, trailing tool sequence never
   pruned; overflow of those alone throws rather than degrades) are all
   treating "the set doesn't fit in the model's context window" as a
   category of failure requiring dedicated handling. agent-design.md's
   thesis (atemporal set, rendered fresh each call) sidesteps *accumulation*-
   caused overflow by construction, but says nothing about what happens
   when a *single* render — one legitimately large set, e.g. from a big
   note or a large eval result — doesn't fit the window on its own. This is
   a real gap: the draft's mechanism for avoiding growth doesn't by itself
   guarantee any given render fits, and none of the 8 open questions name
   this failure mode.

5. **Cost/budget accounting as a resource distinct from step count or
   context tokens.** MetaGPT denominates budget in dollars
   (`Team.invest(3.0)`, a `NoMoneyException` that must propagate through
   every `except` clause and can never be silently swallowed by a retry
   handler), AutoGPT's platform charges per-node pre-flight and reconciles
   post-flight against real provider usage, and browser-use measures real
   token cost per LLM instance rather than estimating it. agent-design.md's
   success criteria mention nothing about cost, and none of the 8 open
   questions raise it. Given crescent's "no compromises" ethos and the fact
   that several surveyed projects treat unbounded-cost as the concrete
   failure mode that ended their unbounded-autonomy phase (AutoGPT
   explicitly), the absence of any cost-accounting mention in agent-design.md
   is worth naming as a gap rather than an oversight this document should
   paper over.

6. **Whether an agent's own decision-making transcript (as opposed to notes
   and tool results) needs a persisted, replayable audit format**, and if
   so what its granularity is. agent-design.md states "exec_graph — audit
   trail. Every tool call, LLM decision, and curated note, recorded as
   data. Never pushed back into any subsequent LLM's prompt" — this
   addresses *whether* an audit trail exists but not its *format*
   properties that multiple surveys treat as load-bearing: append-only vs.
   mutable (Claude Code: "compaction never modifies or deletes previously
   written transcript lines"; Codex CLI: JSONL rollout as truth with a
   rebuildable SQLite index derived from it), forkable-from-any-point (Codex
   CLI's `response_id` bookmarking; pi's session-as-tree with branch
   labels), and whether the audit format is itself versioned with a stated
   migration policy (LangGraph's checkpoint migration rules: renamed state
   keys lose saved values, node removal is disallowed on interrupted
   threads). `lib/taskgraph`'s `exec_graph` already exists as a mechanism,
   so this may already be substrate rather than a gap — but agent-design.md
   doesn't state whether `exec_graph`'s existing format has (or needs) these
   properties, which is a real unstated assumption if any preset author
   later wants to resume, fork, or replay a run.

---

## Summary table (for orientation only — not a scoring mechanism)

| agent-design.md item | Validates | Challenges | Silent/orthogonal |
|---|---|---|---|
| Q1 note value encoding | Letta (structured metadata around notes) | smolagents (typed step schema now) | most others (no set analogue) |
| Q2 scale | browser-use, MetaGPT (filesystem-as-memory) | LlamaIndex (transcript+eviction is well-specified and untested against the alternative) | — |
| Q3 small-model feasibility | Gemini CLI, browser-use, Nous Hermes (skeleton-with-slots shipped) | Cline, Continue.dev (protocol swap, not schema swap, for weak models) | — |
| Q4 render benchmarking | Aider (measured JSON vs. text, model-specific) | — | — |
| Q5 structured docs retrieval | — | — | nearly all (crescent-specific) |
| Q7 failure semantics | SWE-agent, CAMEL (enumerated states, recovery ladder) | AutoGPT (deferring the *category* of answer is itself risky) | — |
| Q8 first concrete app — resolved (build both: narrow file-mgmt library + small generalist, scope of latter still open) | smolagents, AutoGen, pi (narrow-first as policy, validates the narrow instance) | CAMEL (narrow-first doesn't bound app 2's cost) | — |
| Atemporal-facts memory | browser-use, smolagents (independent convergence) | LlamaIndex, AutoGen, SK (transcript+policy-object as a complete, considered alternative) | — |
| Presets over code | SWE-agent (with caveat), AutoGPT, SK | smolagents, Open Interpreter (code-as-action, argued and measured) | CrewAI/AutoGen/LangGraph (a third position: developer-graph, neither) |
| Agents as platform apps | Cline, pi, Continue.dev, openai-agents-sdk | none found | opencode (partial: declarative agent, no tarball/install model) |
| Tool-result size — resolved (a/b: promote-via-note vs. cap-contract defect; truncation rejected) | agent-design.md's resolution | Claude Code, Goose, browser-use, AutoGPT (all use truncation/spill/hard-cap machinery agent-design.md now rejects by name) | — |
| Gap: approval as control flow | — | — | most harnesses have this; draft's caps-first is orthogonal to it |
| Gap: partial-failure recovery granularity | — | — | SWE-agent, CAMEL, Codex CLI all richer than "retry from inputs" |
| Gap: single-render overflow | — | — | Claude Code, Gemini CLI, Continue.dev all handle it explicitly |
| Gap: cost accounting | — | — | MetaGPT, AutoGPT platform, browser-use all treat it as first-class |
| Gap: audit-trail format properties | — | — | Claude Code, Codex CLI, pi, LangGraph all specify append-only/fork/migration |
