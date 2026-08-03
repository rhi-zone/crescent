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

- **Poisoning is a relevance property, not a size or provenance property.** Any context — external (tool output, retrieved docs) or internal (a prior model response, a user message, a note) — that is not directly relevant to the current decision is poisoning, full stop. This is the general form of the point made below about preset context ("noise causes hallucination... not just a speed lever"): it is not a cache-efficiency concern, it's a correctness concern, and nothing is exempt by virtue of where it came from. The set's field-ops already treat model output and tool output symmetrically (both go through add/remove/replace); this states that symmetry as an explicit invariant instead of leaving it implicit.
- **The set is canonical, the render is derived.** Anything the model "knows" about the task must live in the set. Information that exists only in the rendered turns is lost at the next render and may as well not exist. Render is lossless-to-set by construction.
- **Notes are `(key, value)` pairs with replace semantics, not log entries.** Written by `note(key, value)` in the LLM's output, merged into the set for downstream calls. The key makes a note addressable and replaceable — a second `note("hypothesis", ...)` replaces the first, it doesn't append. Value is whatever the LLM decides is useful; content type is not prescribed. Notes exist for the unexpected: if the preset author knew upfront what to record, it would be a task input. Constraining note schemas per-preset would predetermine what the LLM can observe and remember, defeating the point.
- **`drop(note_id)` is a field unset, not a retraction.** Next render doesn't include that note. The model has no idea it ever "existed." Conversation structurally cannot do this — you can append "ignore what I said" but the tokens remain.
- **Tool results get no special slot.** An earlier draft of this doc gave the tool result an architecturally distinguished "current tool result" field, populated for exactly the decision immediately after a call and cleared otherwise. That was itself a special case — the same mistake the no-special-casing convention forbids at the typechecker level, reappearing here in the context model. A tool result is one more contributor to the set, going through the identical field-op path (add/remove/replace) as a note, a user message, or a model output; nothing in the mechanism is aware "this one came from a tool." What was true of the old framing — that a fresh result is added, may prompt `note()` writes that promote what's relevant out of it, and is then removed before the next decision — still holds, but as an ordinary *use* of add/remove, not as bespoke machinery. No source gets a hardcoded slot that other sources don't.
- **Retries are field edits, not reruns-with-history.** A retry is a call with a set whose `typecheck_error` field (or whatever) is now populated. No "previous attempts" sequence.
- **System prompt is a field, too.** Rendered into the system turn each call. Policy changes take effect on the next render. Not "baked in."

## What this enables

With set-not-chronology in place, the things an agent intuitively ought to do are all fine:

- **Retrieval decisions.** LLM says "view `foo`" → graph fetches → result is added to the set through the ordinary field-op path, present for the immediately-following decision → LLM may write any notes it wants, promoting what's relevant → the field is removed before the next decision. Repeat freely. No poisoning because nothing accumulates, and no bespoke retrieval mechanism either — it's the same add/remove any other contributor to the set uses.
- **Iteration within a leaf.** Multiple tool calls in sequence, each ephemeral in the set. The "conversation with the graph" shape works.
- **Computation via eval.** `eval("#results")` is a computation cap for things LLMs hallucinate on at the token level — counting, arithmetic, filter/map, string transforms. Ephemeral like any other tool call.
- **Picking and parameterizing presets.** Just another decision.

Retrieval and computation are both allowed because neither is the bug. The bug is chronological accumulation of raw results. A retrieval that's added to the set for the next decision and then removed is fine.

**Tool-result size is not a sizing problem.** It can look like oversized results need their own management mechanism — truncation, a bounded-output contract, spill-to-file. They don't. An oversized result is always exactly one of two things:

- **Legitimately large and relevant.** Handled the same way as anything else under the field-op mechanism above: the leaf reads it once, in whatever scope that read has, extracts what's actually relevant via `note()`, and lets the rest disappear structurally when the field is removed. No special-cased size handling is required, because nothing about size was special to begin with.
- **Never supposed to reach the agent whole.** If a result is oversized *and* opaque to that extraction — nothing in it can be pulled out as a targeted note — that's a defect in the tool/cap's own contract. It should have returned something scoped, queryable, or pre-summarized by design. That's a fix to the cap, not a harness-level patch applied after the fact.

Truncation is rejected outright, not left as an open gap: cutting a result at an arbitrary byte or token boundary is a symptom of the conversational-accumulation mental model (pile everything up, then clip when it gets too big), not a fix compatible with this one. Under set-not-chronology there is nothing to clip after the fact — either the leaf's own read scope already bounds what comes back, or the cap needs fixing.

## One authoritative store, not synced copies

The context-poisoning invariant above is the LLM-facing instance of a broader principle that governs this design wherever it touches harness or tooling architecture — not only what an LLM call sees. An agent isn't only its context. For any piece of logical state the harness manages — task lists, notes, run state, whatever else accumulates as the system grows — there is exactly one authoritative store. Any other representation of that state — a rendered file, a UI view, a cache — must be a derived, read-through mirror: refreshed deterministically from the authoritative store, never independently writable.

The failure mode is not "more than one copy exists." A disk-backed store with an in-process cache for latency is fine, because the cache is never directly authored — only ever repopulated from the store. The failure mode is more than one independently-writable surface for the same logical state. That's what makes "syncing" necessary in the first place, and syncing two writable copies is a workaround for the design mistake, not a fix for it — the same relationship truncation has to conversational accumulation, above.

Concrete instance: a task list is conceptually a set of records with state (add a task / mark done / drop) and operations over that set, not a text file to be hand-edited by inserting and removing lines. Treating "add a task" as "open the markdown file, find a spot, insert a line" is the same category error the thesis rejects for context — a chronological artifact standing in for structured facts with operations. If a project renders its task list as a markdown file (this repo's own `TODO.md`, say) while a separate tool exposes its own independent write surface over overlapping state (a session-scoped task-tracking tool used by an agent harness), those are two independently-writable copies of the same logical state — the anti-pattern exactly — and they drift for the identical structural reason unmanaged context drifts: stale entries, tribal knowledge nobody prunes, tasks nobody removes.

A third instance, at the scale of a whole app rather than a single piece of state: an app's core logic and behavior should live in exactly one place — a library — with every surface it's presented through (web UI, terminal UI, native UI, an agent driving it via tool calls, whatever else shows up) implemented as a thin projection that renders or drives that library, never holding independent logic or state of its own. A second UI that re-implements a rule the library already enforces, or keeps its own copy of state the library owns, is the same independently-writable-surface failure as the markdown-vs-tracker case above, just at the scale of a whole app instead of one list.

There's verified prior art for this pattern at a stronger level than "one core, N thin skins," in the sibling repo `~/git/rhizone/fractal`. Fractal is a TypeScript framework where an API is authored once as a declarative tree (the `Node` type — handler, children, an open metadata bag — defined in `packages/api-tree/src/node.ts`), and that tree carries zero knowledge of any transport. Separate "projector" packages (`http-api-projector`, `graphql-api-projector`, `mcp-api-projector`, `cli-api-projector`, `json-rpc-api-projector`) each independently walk and interpret that same tree to produce an HTTP server, a GraphQL server, an MCP server, a CLI, and so on; none of them carries its own business logic, and none references any of the others — the tree is the only thing they share. Fractal's own design-philosophy doc (quoted in `CONTRIBUTING.md`) states this as an explicit architectural law: "projections don't know which combinators produced the tree; combinators don't know which projections exist" — the tree (a `Node<P,Res>` discriminated union) is the contract between the authoring layer and every interpreter, and nothing else. That's a stronger shape than a typical one-core-plus-one-UI-skin split: one declarative structure, N independent, swappable interpreters, with the structure itself as the explicit boundary.

Crescent's version of this would be architecturally analogous — a Lua library as the one authoritative source of behavior and state, with N UI surfaces (including an eventual agent-driven one) as projections over it — not a literal code-sharing or dependency relationship with fractal. Fractal is TypeScript solving the transport-fanout case of this shape; the structural lesson transfers, the code does not.

## Presets are the primary surface

A preset is a battle-tested task type: declared input schema, output schema, cap manifest, note-slot schema, and implementation (pure code, a single curated LLM leaf, or a small task graph of both). Agent apps are mostly built by selecting, parameterizing, and composing presets.

Why presets over per-run LLM-authored code:

- **Correctness.** Presets have parity tests, known failure modes, fixes committed and durable. LLM-generated per-task code has none of that.
- **Audit.** "Ran preset P with inputs I" is a tight audit line. "Ran these 40 lines of LLM-generated Lua" is opaque.
- **Cost.** Picking and parameterizing a preset costs far fewer tokens than generating a working program.
- **Composability.** Typed I/O makes presets first-class building blocks.

Eval exists for cases where a full preset would be overkill — quick in-line computation that's more reliable than token-level reasoning. Not a replacement for preset design.

Preset authors should pursue aggressive context minimization. A 200-line context containing only the target function and its local helpers produces better output than a 2000-line file dump. Noise causes hallucination; minimization is a model-quality lever, not just a speed lever — the specific case of the poisoning invariant stated above.

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
2. **Scale.** The only empirical evidence for set-rendered-as-turns in practice (`normalize/docs/archive/agent-dogfooding.md`) is small-task. Whether the shape holds on a 20-file refactor — where note-set size grows and cross-view correlation matters — is unproven. Tool-result *size* specifically is addressed above (legitimately-large-and-relevant vs. cap-contract defect, never truncation) and isn't part of this open question; what's still unproven is note-set growth and cross-view correlation across many leaves over a long-running task, not raw result size.
3. **Small-model feasibility.** Grammar-constrained output, note-schema discipline, and atemporal rendering all ask more than free prose. llama.cpp at `127.0.0.1:8081` is the test bed. Skeleton-with-slots (pre-written structure, LLM fills gaps) is a plausible middle ground.
4. **Render benchmarking per model.** `render(set)` is a pure function at the cap boundary; different models may prefer different formats (turns today; maybe structured records later). Pick measured not assumed.
5. **Structured docs retrieval.** `lib/doc/` index that normalize queries, or something else? No `normalize docs` subcommand exists. Unresolved.
7. **Failure semantics.** Retry / abandon-subtree / escalate-to-parent as a per-preset knob. Deferred until a real preset hits real failure.
8. **First concrete app — resolved (owner decision).** Not a choice between narrow preset-only (shakes out substrate) and small generalist with curated leaves (proves the thesis end-to-end): build both, as two separate concrete first apps.
   - **Narrow instance: a file-management app.** A file browser was raised as the very likely narrow/preset-only instance. What makes it more than a plain file browser is that it's intent-driven: a prompt like "put my screenshots from last week in a folder" or "find the config mentioning X" has an agent plan and execute multi-step filesystem operations through a tool-calling loop over a filesystem cap, with confirm-before-mutate gating on destructive actions — a pattern that's near-universal across the harnesses surveyed in `docs/decisions/agent-harness-survey/` (cline, claude-code, goose, etc. all gate mutation behind approval). Sequencing, per the owner: build the file-management *library* first — deterministic, agent-agnostic, just fs operations behind a cap, consistent with the one-authoritative-store instance above and this repo's caps-first convention. A plain UI is one projection onto that library, buildable now; an agent-driven UI is a later projection onto the *same* library, and doesn't need to wait on the rest of this doc's context-model work, because the library itself doesn't care who calls it — a human through the UI, or an agent through tool-calling. What's decided here: build the library now, with UI projections (plain now, agent-driven later) on top. What's still open: the exact scope of the small-generalist second app — not decided, left open below alongside the rest of the unresolved items.
9. **TODO.md as authoritative store.** Does crescent's own `TODO.md` become a rendered mirror of some other authoritative store, and if so, what store? Still open — not resolved. Owner's current lean, tentative: probably not as-is — plain markdown is likely too impoverished a format to *be* the authoritative store. If anything, a richer structured store should be authoritative, with `TODO.md` (or no rendered file at all) as a read-through mirror of it, per the one-authoritative-store principle above. This is a direction, not a decision — the store's shape, and whether `TODO.md` survives as a rendering of it, are unresolved.

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
