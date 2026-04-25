# Agent Design

Status: draft. Not implemented.

## The thesis

Two claims at different commitment levels.

**Load-bearing (semantic, durable):** context is an atemporal set of facts, not a sequence of turns. Every LLM call receives a constructed set; every LLM output contributes to the next call's set via field operations (add, remove, replace). Chronology exists in the audit graph — never in a prompt.

**Pragmatic (operational, swappable):** the set is rendered as conversation turns at inference time, because current instruct-tuned models perform best on that format. The render is a pure function `render(set) -> prompt`, confined to the LLM cap boundary. If a future model ships trained on structured records, we swap renderers and nothing else changes. Benchmarking `render` across formats is a real tunable per-model, not an assumption.

The single anti-pattern this design is built against: **conversational accumulation** — raw tool output piled up in a chronologically-ordered transcript that's persisted and re-fed across LLM calls. The chronology is the bug, not the tool use. Every failure mode people identify in current agents (context poisoning, pre-answering, view loops, the necessity of handoff rituals, "new session per task" folk wisdom, the advice to rewind when things go wrong) is downstream of accumulation. Drop accumulation, the pathologies stop being pathologies.

## Non-goals

- **Chat UI.** An app could drive the graph from a chat surface, but the graph is the substrate, not the wrapper.
- **General AI assistant.** Agents are narrow, auditable.
- **New language or DSL.** Plain Lua tables; no transpiler. (Crescent invariant.)
- **Frameworks before primitives.** Ship composable libs. Patterns that recur twice become vendored libs.

## What the thesis implies directly

- **The set is canonical, the render is derived.** Anything the model "knows" about the task must live in the set. Information that exists only in the rendered turns is lost at the next render and may as well not exist. Render is lossless-to-set by construction.
- **Notes are `(key, value)` pairs with replace semantics, not log entries.** Written by `note(key, value)` in the LLM's output, merged into the set for downstream calls. The key makes a note addressable and replaceable — a second `note("hypothesis", ...)` replaces the first, it doesn't append. Value is whatever the LLM decides is useful; content type is not prescribed. Notes exist for the unexpected: if the preset author knew upfront what to record, it would be a task input. Constraining note schemas per-preset would predetermine what the LLM can observe and remember, defeating the point.
- **`drop(note_id)` is a field unset, not a retraction.** Next render doesn't include that note. The model has no idea it ever "existed." Conversation structurally cannot do this — you can append "ignore what I said" but the tokens remain.
- **"Current tool result" is one slot, not a growing list.** Populated for exactly the decision that immediately follows a call; cleared otherwise. The model never sees "the history of tool results."
- **Retries are field edits, not reruns-with-history.** A retry is a call with a set whose `typecheck_error` field (or whatever) is now populated. No "previous attempts" sequence.
- **System prompt is a field, too.** Rendered into the system turn each call. Policy changes take effect on the next render. Not "baked in."

## What this enables

With set-not-chronology in place, the things an agent intuitively ought to do are all fine:

- **Retrieval decisions.** LLM says "view `foo`" → graph fetches → result occupies the current-tool-result slot for the immediately-following decision → LLM may write any notes it wants → result evaporates from the set. Repeat freely. No poisoning because nothing accumulates.
- **Iteration within a leaf.** Multiple tool calls in sequence, each ephemeral in the set. The "conversation with the graph" shape works.
- **Computation via eval.** `eval("#results")` is a computation cap for things LLMs hallucinate on at the token level — counting, arithmetic, filter/map, string transforms. Ephemeral like any other tool call.
- **Picking and parameterizing presets.** Just another decision.

Retrieval and computation are both allowed because neither is the bug. The bug is chronological accumulation of raw results. A retrieval that drops its raw result back into the set-slot for the next decision and then evaporates is fine.

## Presets are the primary surface

A preset is a battle-tested task type: declared input schema, output schema, cap manifest, note-slot schema, and implementation (pure code, a single curated LLM leaf, or a small task graph of both). Agent apps are mostly built by selecting, parameterizing, and composing presets.

Why presets over per-run LLM-authored code:

- **Correctness.** Presets have parity tests, known failure modes, fixes committed and durable. LLM-generated per-task code has none of that.
- **Audit.** "Ran preset P with inputs I" is a tight audit line. "Ran these 40 lines of LLM-generated Lua" is opaque.
- **Cost.** Picking and parameterizing a preset costs far fewer tokens than generating a working program.
- **Composability.** Typed I/O makes presets first-class building blocks.

Eval exists for cases where a full preset would be overkill — quick in-line computation that's more reliable than token-level reasoning. Not a replacement for preset design.

Preset authors should pursue aggressive context minimization. A 200-line context containing only the target function and its local helpers produces better output than a 2000-line file dump. Noise causes hallucination; minimization is a model-quality lever, not just a speed lever.

## The graph holds inter-task state

`lib/taskgraph/` already provides the substrate: frontier, exec_graph, `ctx.spawn`, executor registry. This design doesn't add task-graph mechanism; it specifies what runs at leaves and what crosses leaf boundaries.

- **exec_graph** — audit trail. Every tool call, LLM decision, and curated note, recorded as data. Never pushed back into any subsequent LLM's prompt.
- **Notes** — per-task set state, visible only within that task's leaves. Not shared across tasks.
- **Task outputs** — inter-task state, passed explicitly as inputs to downstream tasks.

Nothing mutable crosses a leaf boundary. Decomposed tasks are independent. Retries re-run from inputs.

## Agents are platform apps

Platform invariants (`lib/platform/CLAUDE.md`) align with what agents need:

- Caps are the only side-effect surface → tools are caps.
- Operator grants caps per-app → permission dialog for free.
- Tarball is canonical form → agents are diffable, reproducible artifacts.
- "Apps are cheap" → one narrow agent per task class, not one mega-agent.
- Sandbox + `load("t")`-only → eval expressions and any LLM-authored artifacts are safe by construction.

Concrete division:

- **Vendored pure Lua** (no caps): `lib/taskgraph/` (exists), `lib/agent/presets/`, `lib/agent/curate/` (note primitives, render function), `lib/agent/author/` (emit new-app tarball).
- **New caps**: `llm` (grammar-constrained generation; takes a set, returns structured output), `exec` (subprocess with a manifest-declared binary whitelist; gradual typing — per-binary schema either auto-derived by parsing `--help` output at cap construction time and cached, manually specified as a Lua table in the manifest for tools without parseable help, or absent for untyped raw-stdout fallback; normalize is not special, any binary gets the same treatment), `eval` (sandboxed Lua computation; typecheck via `check.check_string` before running — the static typechecker already exposes a clean programmatic API used by the LSP daemon, no design work needed), `app_author` (meta-agents only).

## Meta: agents authoring agents

An agent app holding `caps.app_author` + `caps.llm` can produce a new agent tarball and submit it to the daemon for install. The daemon shows the operator: *agent wants to install `foo` requesting caps `[llm, fs(~/project)]` — allow?* The child's cap grants go through the same prompt; meta-agents cannot privilege-escalate their children.

Platform invariants survive: installed apps stay immutable, every spawned agent is a diffable `.tar.gz`, audit trail is literal files. Object-level and meta-level are the same level; no runtime script mutation.

## Conversational anti-patterns, as evidence

These aren't practices to import; they're workarounds people discovered for the accumulation bug, offered here as evidence that accumulation is the thing to design against:

- **`/handoff`.** Transfers state because conversations die at session end with poisoned context. In a set-based design there is nothing to hand off — state is always explicit artifacts, and "the next session" is the next graph run reading the same artifacts.
- **Rewind advice.** Exists because one bad assertion biases all subsequent reasoning in a chronological context. A set-based context supports `drop`, which is strictly stronger.
- **New session per task.** Users independently converged on "each task should be fresh" and hacked session boundaries to get there. Tasks as the primitive resolves it cleanly.
- **System prompt inflation.** Conversational agents patch every turn forever. Per-preset narrow prompts have no cross-contamination; each is a field in that preset's set.
- **Pre-answering.** Model emits command plus conclusion because the prose channel is always open. Grammar-constrained structured output closes it.

Default test for any proposed feature: *what conversational anti-pattern is this a workaround for?* If it's a workaround, it's unneeded here.

## Open questions

1. **Note value encoding.** Content type is not prescribed — values can be strings, tables, whatever. Open question is whether there's a useful convention (e.g. short strings only, or structured tables for machine-readable notes) that emerges from the first real preset, not something to decide upfront.
2. **Scale.** The only empirical evidence for set-rendered-as-turns in practice (`normalize/docs/archive/agent-dogfooding.md`) is small-task. Whether the shape holds on a 20-file refactor — where note-set size grows and cross-view correlation matters — is unproven.
3. **Small-model feasibility.** Grammar-constrained output, note-schema discipline, and atemporal rendering all ask more than free prose. llama.cpp at `127.0.0.1:8081` is the test bed. Skeleton-with-slots (pre-written structure, LLM fills gaps) is a plausible middle ground.
4. **Render benchmarking per model.** `render(set)` is a pure function at the cap boundary; different models may prefer different formats (turns today; maybe structured records later). Pick measured not assumed.
5. **Structured docs retrieval.** `lib/doc/` index that normalize queries, or something else? No `normalize docs` subcommand exists. Unresolved.
7. **Failure semantics.** Retry / abandon-subtree / escalate-to-parent as a per-preset knob. Deferred until a real preset hits real failure.
8. **First concrete app.** Narrow preset-only agent (shakes out substrate) or small generalist with curated leaves (proves the thesis end-to-end). Current lean: narrow first.

## Out of scope for v1

- Distributed execution across machines.
- Persistent daemon agents — use existing scheduler driving an agent app.
- Cross-agent messaging beyond parent-child.
- Streaming output from leaves — grammar-constrained outputs come out whole.
- Vector / embedding retrieval — structured queries via normalize first; revisit with evidence if insufficient.

## Success criteria

- A narrow agent app under 200 lines of Lua, vendoring taskgraph + presets + curate.
- A curated leaf on a small local model produces useful output with set-not-chronology context.
- A meta-agent produces a runnable narrow-agent tarball that survives operator approval without hand-editing.
- Audit trail for a run is `exec_graph` snapshot + tarball hash. Reproducible modulo LLM nondeterminism.
