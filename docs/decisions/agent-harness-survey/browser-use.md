# browser-use — Agent Harness Survey

Survey of `github.com/browser-use/browser-use` as prior art for an agentic
harness. Focus is on the *decisions* the project made and the reasoning it
published for them, not a feature catalogue.

Repo existence verified by fetching `https://github.com/browser-use/browser-use`
(MIT, Python 3.11+, "Make websites accessible for AI agents"). Source reads were
done against `raw.githubusercontent.com/browser-use/browser-use/main/...` on
2026-08-02.

Evidence quality: most structural claims below come from direct reads of `main`
source files (`agent/service.py` ~4166 lines, `dom/service.py`,
`dom/serializer/*`, `tools/service.py`, `tools/registry/service.py`,
`actor/element.py`, `mcp/*`, `filesystem/file_system.py`, `browser/profile.py`).
Some large files were read through a summarizing fetch rather than line-by-line;
claims that rest only on a summarizer are marked *(summarized)*. Two specific
details are marked **unverified**. The project moves fast — it rewrote its entire
browser layer in Aug 2025 and renamed most of its actions since — so anything
here is a snapshot, and older write-ups about browser-use describe a materially
different system.

## Overview

browser-use is a Python library that lets an LLM drive a real Chrome browser:
you give an `Agent` a natural-language task and an LLM, and it clicks, types,
scrolls, and extracts until it calls `done`.

```python
agent = Agent(task="Find the number of stars of the browser-use repo",
              llm=ChatBrowserUse(model='openai/gpt-5.5'))
history = await agent.run()
```

Its actual contribution is not the loop — that part is conventional — it is the
**grounding layer**: turning a live web page into a compact, indexed text
representation that an LLM can address unambiguously, and turning an index the
LLM returns back into a click on the right node inside the right (possibly
cross-origin) frame. Everything distinctive in the codebase is downstream of
taking that problem seriously.

The project is dual-shaped: MIT open-source library, plus a hosted cloud product
(proxies, stealth, CAPTCHA solving, live-view URLs) and a set of house models
(`ChatBrowserUse`, `bu-*`) claimed to be 3-5x faster on browser tasks. The README
claims #1 on the Odysseys leaderboard at 87.4% average. Treat the benchmark and
speed claims as vendor claims.

## Architecture

**Four top-level components** (from the repo's own `CLAUDE.md`):

- `Agent` — orchestrator; owns the step loop and the LLM conversation.
- `BrowserSession` — owns the CDP connection, coordinates watchdogs over an
  event bus.
- `Tools` (registry) — maps LLM action decisions to browser operations.
- `DomService` — extracts and serializes page state.

Plus `llm/` (15+ provider adapters behind one interface), `tokens/`,
`filesystem/`, `mcp/`, `sandbox/`, `actor/` (low-level element/page ops).
Module convention throughout: `service.py` for logic, `views.py` for Pydantic
models.

**Decision: drop Playwright, speak raw CDP.** In Aug 2025 the project removed
Playwright entirely and moved to the Chrome DevTools Protocol via its own
`cdp-use` typed bindings. The published reasoning:

- Playwright inserts a second network hop through a Node.js websocket server —
  "a meaningful amount of latency when we do thousands of CDP calls."
- Three-system state drift (browser / Node relay / Python client); edge cases
  could hang the relay with no recovery but process kill.
- A tail of unfixable-from-outside bugs: crashes on >16000px full-page
  screenshots, dialog handling, file upload/download, crashed-tab management.
- Cross-origin iframe (OOPIF) support and element extraction speed both improved
  once they addressed CDP directly.

The general form of this decision — *the convenience adapter hides exactly the
details an agent harness needs* — is the most portable lesson in the repo. An
automation library optimized for short readable QA scripts is optimized against
the needs of a long-running agent that must observe everything and recover from
anything.

**Decision: event-driven watchdogs instead of polling between actions.** The
`bubus` event bus fans CDP events out to independent services — `DownloadsWatchdog`,
`PopupsWatchdog` (JS dialogs), `SecurityWatchdog` (domain enforcement),
`DOMWatchdog` (snapshots/screenshots), `AboutBlankWatchdog`, and more (13+
modules in `browser/watchdogs/`). Each owns an isolated slice of session state.
The stated philosophy: for truly massive refactors, decompose into small
services coordinated by event buses and job queues rather than one god-object.
The consequence for the agent is that spontaneous page events (a download
starting, a tab crashing, a dialog appearing) are handled *between* LLM turns
without the agent having to poll for them.

**`browser/session_manager.py` is CDP session bookkeeping, not agent
orchestration** — `_sessions: dict[SessionID, CDPSession]`, `_targets`,
`start_monitoring()`, `_handle_target_attached/_detached`,
`_recover_agent_focus(crashed_target_id)`. Two locks, no semaphores or
concurrency limits.

## Tool-Calling Protocol

### Declaration and schema generation

Actions register on a `Tools` object's registry:

```python
def action(self, description: str, param_model: type[BaseModel] | None = None,
           domains: list[str] | None = None, allowed_domains: list[str] | None = None,
           terminates_sequence: bool = False)
```

If `param_model` is omitted, the registry synthesizes one from the function
signature with Pydantic's `create_model()`. Param models are small and flat, e.g.
`ClickElementAction{index, coordinate_x, coordinate_y}`,
`InputTextAction{index, text, clear=True}`,
`ScrollAction{down=True, pages=1.0, index}`.

**Decision: dependency injection via reserved parameter names.** Parameters named
`browser_session`, `page_extraction_llm`, `file_system`, `available_file_paths`
(and others) are *never shown to the LLM*; they are injected at execution time.
A user action that names a parameter the same way is rejected:
`"parameter '{name}' conflicts with special argument injected by tools"`. This
cleanly separates "what the model chooses" from "what the harness supplies",
without a separate context object in the signature.

### Default action set (verified names on `main`)

`search`, `navigate`, `go_back`, `wait`, `click`, `input`, `upload_file`,
`switch`, `close`, `extract`, `search_page`, `find_elements`, `scroll`,
`send_keys`, `find_text`, `screenshot`, `save_as_pdf`, `dropdown_options`,
`select_dropdown`, `write_file`, `replace_file`, `read_file`, `evaluate`, `done`.

Note these were renamed from the widely-cited older names
(`go_to_url`, `click_element_by_index`, `input_text`, `extract_structured_data`).
Third-party articles describing browser-use's action set are mostly stale.

**Decision: give the agent zero-LLM-cost escapes from the perception loop.**
`search_page` is documented as "Search page text for a pattern (like grep). Zero
LLM cost, instant"; `find_elements` is "Query DOM elements by CSS selector (like
find). Zero LLM cost." Only `extract` spends an LLM call (it runs a secondary
model over the page's markdown rendering). The harness deliberately exposes cheap
deterministic primitives alongside the expensive semantic one, and says so in the
tool description so the model can choose on cost.

### Dynamic, URL-filtered action surface

The action set the LLM sees is rebuilt per step:
`create_action_model(page_url=...)` builds one Pydantic model per *available*
action and wraps them in a `RootModel`; `get_prompt_description(page_url=...)`
renders matching docs into the prompt. Availability is filtered by the action's
`domains`/`allowed_domains` glob patterns matched against the current URL
(`match_url_with_domain_pattern`). Capability gating can also change a schema:
`_register_click_action()` registers `ClickElementAction` (with coordinates) or
`ClickElementActionIndexOnly` depending on configuration.

So: **the tool schema is a function of state, not a static manifest.** This is a
real design commitment — it costs prompt-cache friendliness on navigation but
keeps the model from seeing actions that cannot apply.

### Multi-action batches, and how they abort

The LLM returns `action: list[ActionModel]` — up to `max_actions_per_step`
(default 5) actions per turn. `multi_act` documents "two layers of protection
against stale DOM":

1. **Static**: an action registered with `terminates_sequence=True` (navigate,
   search, go_back, switch) drops the rest of the batch —
   `Action "{name}" terminates sequence — skipping {n} remaining action(s)`.
2. **Runtime**: URL and `agent_focus_target_id` are captured before each action;
   if either changed afterwards, the rest of the batch is dropped —
   `Page changed after "{name}" — skipping {n} remaining action(s)`.

Also enforced: `done` is valid only as a single action; `wait_between_actions`
sleep between steps of a batch; break on any `result.error`.

Worth noting what this *doesn't* do: the guard compares URL and focus target
only. It does **not** diff the selector map, even though a cached selector map is
available at that point. So a same-URL DOM mutation (an SPA re-render) can leave
later actions in a batch pointing at stale indices. That is a considered
cost-of-batching tradeoff, not an oversight, but it is a real soundness hole in
the batch model.

### Termination with structured output

`done` has two registered variants chosen at `Tools` construction:

- plain: `DoneAction{text, success=True, files_to_display}`
- structured: `StructuredOutputAction[T]{success, data: T, files_to_display}`
  when the caller passed `output_model_schema=MyModel`; read back as
  `history.structured_output`.

Both produce `ActionResult(is_done=True, success=..., extracted_content=...,
long_term_memory=..., attachments=...)`.

### DOM extraction and element indexing — the core contribution

This is where the project's real engineering sits.

**Three CDP sources, fused.** Per step, issued in parallel (10s timeout, one
retry):

1. `DOM.getDocument{depth: -1, pierce: True}` — full tree, piercing shadow roots.
2. `Accessibility.getFullAXTree` — run per frame by
   `_get_ax_tree_for_all_frames(target_id)` and merged.
3. `DOMSnapshot.captureSnapshot` over `REQUIRED_COMPUTED_STYLES` with
   `includePaintOrder: True, includeDOMRects: True`.

`_construct_enhanced_node()` fuses them into `EnhancedDOMTreeNode`, joining on
`backendDOMNodeId`. A fourth, narrow signal is JS-side: DevTools'
`getEventListeners()` gives `js_click_listener_backend_ids`, capped at 100
elements (`_MAX_JS_CLICK_LISTENER_ELEMENTS`).

So the answer to "AX tree or injected JS?" is *both, with different weights*: the
AX tree and DOM snapshot are the backbone; JS is a bounded probe for listeners.
This is a direct consequence of the CDP migration — the previous design was one
big injected script, `dom/buildDomTree.js`, present at tag `v0.2.5` and **absent
from `main`**.

**Interactivity heuristics** (`ClickableElementDetector.is_interactive`, an OR
over):

- tag: `button, input, select, textarea, a, details, summary, option, optgroup`
- ARIA role: `button, link, menuitem, option, radio, checkbox, tab, textbox,
  combobox, slider, spinbutton, search, searchbox, row, cell, gridcell`
- AX state/props: `checked/expanded/pressed/selected`, or
  `focusable/editable/settable/required/autocomplete/keyshortcuts`
  (disabled or hidden short-circuits to false)
- `cursor_style == 'pointer'`
- `has_js_click_listener`, or inline `onclick/onmousedown/onmouseup/onkeydown/onkeyup`
- shape heuristics: search-ish class/id/data attributes; form controls nested in
  `label`/`span`; icon-sized elements (10-50px) carrying a class, role, or
  onclick; iframes over 100px

The old JS keyed mainly off a wide cursor set
(`pointer, move, text, grab, ...`) with explicit `not-allowed`/`no-drop`
exclusions; the rewrite narrowed cursor to `pointer` and shifted weight onto the
accessibility tree. No `pointer-events` check exists in the current detector.

**Occlusion by paint-order geometry, not hit-testing.** The old design called
`document.elementFromPoint(centerX, centerY)` per candidate (`isTopElement`). The
current one processes elements in descending paint order and marks
`node.ignored_by_paint_order = True` when `rect_unions[context].contains(rect)`
— fully covered by already-painted geometry. Coverage is tracked per
`(session_id, frame_id)` so cross-document occlusion doesn't leak; transparent
painters (background `rgba(0,0,0,0)` or opacity < 0.8) are excluded from the
union; `RectUnionPure` keeps disjoint rects via `_split_diff` with a 5000-rect
cap. This replaces N round-trips to the page with one geometric pass over a
snapshot — the concrete form of "CDP made extraction fast."

**Containment propagation kills index explosion.** `PROPAGATING_ELEMENTS`
(anchor, button, div/span with button/combobox roles, input with combobox role)
propagate their bounds to descendants; a child ≥ `DEFAULT_CONTAINMENT_THRESHOLD
= 0.99` contained in that box is `excluded_by_parent`, unless it is a form
element, a nested propagating element, or carries onclick/aria-label/interactive
role. This is what stops "icon inside button inside link" from producing three
indices for one visual affordance.

**Off-viewport elements become a hint, not indices.**
`_count_hidden_elements_in_iframes()` (with `viewport_threshold: int | None =
1000`) records off-screen interactive elements — tag, label, scroll distance in
page units — as information for the agent rather than addressable indices. The
old `viewportExpansion` knob (with `-1` meaning "everything counts as in
viewport") does not survive in that form.

**Decision: index == `backend_node_id`.** `_allocate_selector_index()` uses the
element's CDP `backend_node_id` directly as its LLM-facing index when free,
falling back to synthetic ids above `max(reserved) + 1` on collision. Result:
`DOMSelectorMap = dict[int, EnhancedDOMTreeNode]`. Since backend node ids are
stable per-document, **indices are stable across steps for elements that
persist** — a real departure from the old sequential `highlightIndex` that
renumbered everything every step. Index stability means the model's memory of
"the submit button is [42]" survives a step, which is exactly the kind of
cross-step continuity a text-grounded agent needs.

(**Unverified**: a `self._interactive_counter = 1` field also exists on the
serializer class; whether it is live or vestigial was not established.)

Novelty marking is a set difference over `(session_id, backend_node_id)` against
the previous cached selector map; anything not present gets `is_new = True`.
Separately, `EnhancedDOMTreeNode.__hash__` is a SHA256 over parent branch path +
static attributes + AX name, and `compute_stable_hash()` strips dynamic classes
matching `focus`/`hover`/`active`; `DOMInteractedElement` records
`element_hash`, `stable_hash`, `x_path` for what was actually clicked.

**Serialized format.** One tab per depth level; the element line is built as:

```python
line = f'{depth_str}{shadow_prefix}{new_prefix}{scroll_prefix}{node.selector_index}]<{node.original_node.tag_name}'
```

with `new_prefix = '*'` for new elements, `scroll_prefix = '|scroll element['`
for scrollables (else `'['`), and `shadow_prefix` of `|SHADOW(open)|` /
`|SHADOW(closed)|`; the tag self-closes with `' />'`. Text is **not** inlined —
text nodes are emitted as their own indented lines, filtered to visible,
non-empty, length > 1. SVG subtrees collapse to `<!-- SVG content collapsed -->`;
password values are never emitted. Real output looks like:

```
	[42]<button type="button" aria-label="Submit" />
		Click me
	|scroll element[51]<div role="listbox" compound_components=(...) />
```

Attributes are whitelisted (~55 entries in `DEFAULT_INCLUDE_ATTRIBUTES`, heavily
ARIA- and form-semantics-weighted, overridable via
`AgentSettings.include_attributes`), and the serializer *synthesizes* a few
attributes the DOM doesn't carry: `format=YYYY-MM-DD` for date inputs, a
`placeholder` for datepickers, `compound_components` for `<select>` and range
inputs. That last move is the interesting one — the serializer's job is framed
as "describe the affordance to a model", not "faithfully render the DOM."

**Resolution at action time.** `actor/element.py` goes index →
`DOM.pushNodesByBackendIdsToFrontend{backendNodeIds:[id]}` → `DOM.resolveNode` →
`objectId` → `Runtime.callFunctionOn`. Clicks first
`DOM.scrollIntoViewIfNeeded{backendNodeId}`. Staleness is not silently absorbed;
it surfaces as an error the agent sees:
`'Failed to find DOM element based on backendNodeId, maybe page content
changed?'` and `RuntimeError('Element has no remote object ID (element may be
detached from DOM)')`.

The CDP blog post adds that cross-origin routing uses "super-selectors" carrying
target id, frame id, backend node id, position, and fallback selectors, so an
interaction is routed to the frame that actually owns the node — the thing
Playwright's relay made opaque.

**Screenshots are captured clean.** `_capture_clean_screenshot()` runs first;
highlight overlays are applied afterwards via
`add_highlights(content.selector_map)`. So the LLM receives an *unhighlighted*
screenshot plus the indexed text tree — a deliberate reversal of the old
`buildDomTree.js` behavior, where numbered colored boxes were painted into the
page before capture. Independent evaluation supports the de-emphasis of pixels:
the D2Snap paper measured GUI-grounded success at 65% with screenshots vs 63%
without.

**Caching.** `DOMWatchdog` holds `selector_map`, `current_dom_state`,
`enhanced_dom_tree`; `BrowserSession` holds `_cached_browser_state_summary` and
`_cached_selector_map`. The previous state is threaded into
`get_serialized_dom_tree(previous_cached_state=...)` — this drives `*` markers
only, not incremental tree reuse. Cache is invalidated on `AgentFocusChangedEvent`
and on scroll, "because it only includes visible elements."

## Context/Memory Management

**Decision: the conversation is two messages, not a transcript.** The
`MessageManager` keeps one system message (set once) plus a *rebuilt* state
message per step, plus transient context messages. History is not an accumulating
message list — it is a rendered string, `agent_history_description`, joined from
`HistoryItem.to_string()`. Each `HistoryItem` carries `step_number`,
`evaluation_previous_goal`, `memory`, `next_goal`, `action_results`.

This is the sharpest divergence from the mainstream tool-calling loop (including
crescent's current `lib/ai/tools.lua`), which appends assistant + tool messages
forever. Rebuilding means the harness — not the provider's message list — owns
exactly what the model remembers, and can compress, elide, or reorder it freely.

**Structured output schema** (`AgentOutput`, `extra='forbid'`), flat:

- `thinking: str | None`
- `evaluation_previous_goal: str | None`
- `memory: str | None`
- `next_goal: str | None`
- `current_plan_item: int | None`, `plan_update: list[str] | None`
- `action: list[ActionModel]` (required, min 1)

`AgentBrain` (the old nested `current_state`) survives only as a
backward-compatibility property. Two schema variants are produced by subclassing
and rewriting `model_json_schema`: `AgentOutputNoThinking` drops `thinking`, and
`AgentOutputFlashMode` reduces the whole schema to `{memory, action}`.

The decision embedded here: **self-evaluation and memory are schema fields, not
prose conventions.** The model is structurally required to say how the last step
went and what to carry forward, every step. That makes the reflection loop
enforceable rather than hoped-for.

**Two-tier action results.** `ActionResult` distinguishes `extracted_content`
(full, this step) from `long_term_memory` (compact, persists). With
`include_extracted_content_only_once=True`, full content is shown once inside
`<read_state_i>…</read_state_i>` and dropped next step, while the compact form
persists in history. Both are hard-capped at `MAX_CONTENT_SIZE = 60000` with
`'... [Content truncated at 60k characters]'`. Errors are middle-elided at 200
chars (`error[:100] + '......' + error[-100:]`).

**History elision.** With `max_history_items` set: keep item[0] (initialization)
+ a literal `<sys>[... N previous steps omitted...]</sys>` marker + the last
`max_history_items - 1` items. The elision is *visible to the model*, not silent.

**Opt-in LLM compaction.** `maybe_compact_messages` fires on
`compact_every_n_steps` AND history ≥ `trigger_char_count or 40000`, summarizes
via a separate LLM into `state.compacted_memory`, and renders it as
`<compacted_memory>` with an explicit **"Treat as unverified context"** caveat
before truncating history to `[first] + last keep_last_items`. Labelling
lossy-summarized memory as unverified inside the prompt is a small decision worth
copying.

**Screenshots: only the current one, ever.** `use_vision=True` always attaches;
`'auto'` attaches only when an action result sets
`metadata['include_screenshot']`; `False` never. `vision_detail_level` is
`auto|low|high`. `use_vision != 'auto'` also removes the `screenshot` tool from
the action set. DeepSeek and some XAI models force `use_vision=False` with a
warning. Notably, the screenshot is *captured* every step regardless, "so that
cloud sync is useful" — capture and inclusion are separate decisions.

**Filesystem as durable memory.** `FileSystem` creates `todo.md` by default;
`describe()` renders file contents into `<agent_state>` truncated at
`DISPLAY_CHARS = 400` (head/tail ~200 each plus `... N more lines ...`), and
excludes `todo.md` because the todo is rendered separately. Extraction output
spills to `extracted_content_{N}.md`. So long-lived task state lives on disk in a
file the model edits, not in the prompt. *(summarized)*

**Prompt layout** *(summarized)*: `<user_request>`, `<agent_history>`,
`<agent_state>` (file system, todo, plan), `<browser_state>`, `<read_state>`,
`<page_specific_actions>`, `<step_info>`, with `cache=True`.

**Step loop and failure handling.** `run(max_steps=500)` loops while
`n_steps <= max_steps`, checking pause → consecutive-failure ceiling → stop flag
→ `_execute_step`. `step()` has three phases: `_prepare_context()` (browser state
+ per-URL action models + message assembly + compaction), `_get_next_action()` /
`_execute_actions()`, `_post_process()` / `_finalize()`. Defaults:
`max_failures = 5`, `final_response_after_failure = True` (one extra attempt),
`llm_timeout = 60`, `step_timeout = 180`, `max_actions_per_step = 5`,
`loop_detection_enabled = True` with `loop_detection_window = 20`,
`enable_planning = True`, `planning_replan_on_stall = 3`,
`planning_exploration_limit = 5`, `max_clickable_elements_length = 40000`.

**Decision: steer the model by injecting prompt nudges, not by changing code
paths.** Phase 1 runs a chain of conditional injections —
`_inject_budget_warning`, `_inject_replan_nudge`, `_inject_exploration_nudge`,
`_inject_loop_detection_nudge`, `_force_done_after_last_step`,
`_force_done_after_failure`. At max steps the injected text is explicit: *"You
reached max_steps - this is your last step. Your only tool available is the
`done` tool…"*. Even the CAPTCHA wait result is fed back as
`ActionResult(long_term_memory=msg)`. Harness-detected conditions become
first-class prompt content rather than silent behavior changes — which keeps the
model's world-model consistent with the harness's.

Degenerate-output handling: an empty action list appends
`UserMessage("You forgot to return an action…")` and retries once; still empty
synthesizes `done{success: False, text: 'No next action returned by LLM!'}`.
Between phases 1 and 2 `last_model_output` and `last_result` are cleared so a
timeout cannot leave stale data behind.

**Token cost** is measured, not estimated: `TokenCost` monkey-patches `ainvoke`
per LLM instance id and records real `ChatInvokeUsage`, with pricing resolved
`CUSTOM_MODEL_PRICING` → OpenRouter → LiteLLM's price JSON (cached a day),
handling cache-read and cache-creation tiers separately. `calculate_cost` is
`False` by default. *(summarized)*

**A judge, that does not overrule.** `use_judge = True` by default; `judge_llm`
defaults to the main LLM. After `done`, it produces `JudgementResult{reasoning,
verdict, failure_reason, impossible_task, reached_captcha}` attached to
`ActionResult.judgement` — and explicitly **does not** override the agent's
self-reported `success`. Evaluation is recorded alongside the claim rather than
replacing it. *(summarized)*

**Model-specific system prompts.** `system_prompts/` holds `system_prompt.md`
(24.1 KB), `system_prompt_no_thinking.md` (22.1 KB), `system_prompt_flash.md`
(2.4 KB), Anthropic-specific flash variants, and three ~1 KB `browser_use_*`
prompts for their own hosted models — which carry the playbook in-weights.
Selection keys off `is_browser_use_model`, Anthropic-vs-other, flash mode, and
`use_thinking`. *(summarized)* The size spread is the decision: a 24 KB playbook
for general models, 2 KB and a `{memory, action}`-only schema for fast ones, ~1 KB
for models fine-tuned on the harness. **The prompt is treated as a per-model
artifact, and the response schema shrinks with it.**

## Sandboxing & Permissions

**Domain allowlists on the browser profile.** `BrowserProfile.allowed_domains` /
`prohibited_domains` take glob patterns (`*.google.com`,
`https://example.com`, `chrome-extension://*`); allowed takes precedence over
prohibited. Enforcement lives in `SecurityWatchdog` on the event bus, i.e. at the
navigation layer, not in each action. One sharp edge: "lists with 100+ items are
auto-optimized to sets (no pattern matching)" — a silent-ish semantic downgrade
that only logs a warning.

**Sensitive data never reaches the model.** `Registry.execute_action(...,
sensitive_data=...)` calls `_replace_sensitive_data(params, sensitive_data,
current_url)` *after* the LLM has produced the action. The model emits
`<secret>label</secret>` placeholders; substitution happens at execution, scoped
per-domain via `match_url_with_domain_pattern` (a legacy flat dict applies
everywhere). A `bu_2fa_code` key suffix triggers TOTP generation. A missing key
is a warning, not an error — the action proceeds with the placeholder unresolved,
which is a fail-open choice.

**Filesystem confinement.** `FileSystem(base_dir)` confines everything to
`base_dir / browseruse_agent_data`. `_resolve_filename()` "normalizes to basename
first to prevent directory traversal (e.g. `../secret.md`)", filenames are
regex-restricted, extensions limited to `md, txt, json, jsonl, csv, pdf, docx,
html, xml` with a binary blocklist. The one escape hatch is
`read_file(full_filename, external_file=True)`, gated by the injected
`available_file_paths` list — i.e. an explicit capability grant from the caller.

**No human-in-the-loop approval gate.** This is the big absence, and it is a
deliberate position: browser-use is built for autonomous runs, not
propose-and-approve. `agent.pause()` / `resume()` / `add_new_task()` exist and
lifecycle hooks can call them, but there is no per-action confirmation
mechanism; it is an open feature request (issues #3341, #221). Hooks run on the
agent thread, so blocking for a human means raising `step_timeout`. The cloud
product's "human in the loop" is coarser still: end a run, hand the human a
`live_view_url` from the `browser.ready` event, then start a *new* run with the
same `session_id` and the task "Continue from the current page."

Contrast with Cline's approve-every-edit stance: browser-use puts its safety
budget into *scoping the blast radius* (domain allowlists, filesystem jail,
secrets the model never sees) rather than into *interrupting for consent*. For a
harness whose actions are mostly reads and clicks on the open web, that is a
coherent trade; it would not be for a harness that writes files or runs commands.

**`sandbox/` is remote execution, not local isolation.** A `@sandbox()` decorator
on `async def func(browser: BrowserSession, ...)` extracts the function's source
via AST, its closure vars/globals and used imports, base64-encodes them, and
POSTs to `https://sandbox.api.browser-use.com/sandbox-stream` with an
`X-API-Key`. Results stream back as SSE events (`BROWSER_CREATED` yielding a live
view URL, `INSTANCE_READY`, `LOG`, `RESULT`, `ERROR`). Shipping the function body
to the cloud is an unusual API shape — it makes "run this locally" and "run this
in our cloud" a one-line diff, at the cost of a fragile source/closure capture.

## Multi-Agent Support

**Essentially none, on purpose.** Findings:

- **No subagent spawning.** No default action creates another agent. The only
  agent-as-tool surface is the MCP server's `retry_with_browser_use_agent`, i.e.
  an *external* client invoking an agent — an agent cannot recursively spawn one.
- **Parallelism is caller-driven `asyncio.gather`**, one `Browser(user_data_dir=
  f'./temp-profile-{i}')` per agent. The docs carry an explicit caveat: "This is
  experimental, and agents might conflict each other."
- **`session_manager.py` manages CDP sessions, not agents** (see Architecture),
  and imposes no concurrency limits.
- **`skills/service.py` is not a subagent mechanism**: `SkillService` lists and
  executes pre-built capabilities from the hosted Browser Use API
  (`skills.list_skills()`, `skills.execute_skill()`), each with a UUID, title,
  description, and Pydantic parameter schema. No `@registry.action` decorators
  appear in that module; how skills are surfaced into an agent's action set was
  **not established** — treat as an open question.

**MCP in both directions** is where composition actually happens:

- *As a server* (`mcp/server.py`): `BrowserUseServer` exposes a flattened,
  hand-written tool surface — `browser_navigate`, `browser_click`,
  `browser_type`, `browser_get_state`, `browser_extract_content`,
  `browser_get_html`, `browser_screenshot`, `browser_scroll`, `browser_go_back`,
  tab/session management, plus `retry_with_browser_use_agent(task, max_steps,
  model, allowed_domains, use_vision)`. **This surface is not auto-generated from
  the internal registry** — different names, different granularity. The external
  contract is designed separately from the internal one, which is a deliberate
  decoupling (the internal registry churns; the MCP contract shouldn't).
  Sessions expire: `_cleanup_expired_sessions()` runs every 2 minutes, closing
  sessions idle past ~10 minutes.
- *As a client* (`mcp/client.py`): `MCPClient(server_name, command, args, env)`
  spawns stdio servers, and `register_to_tools(tools, tool_filter=None,
  prefix=None)` injects discovered tools into the agent's registry, converting
  JSON Schema → Python types via `_json_schema_to_python_type()` →
  `create_model()`. `prefix` provides namespacing (e.g. `playwright_`). Note:
  domain filtering of MCP-derived tools was removed, so external tools are not
  URL-gated the way native ones are.

## Notable Design Decisions

Ranked by how much they'd change a design that didn't know about them:

1. **Index the DOM by CDP `backend_node_id`, not a per-step counter.** Stable
   cross-step handles for free, from an id the browser already maintains. The
   general principle: when grounding an LLM to an external world, look for an
   identifier the world already guarantees before inventing one.
2. **Serialize *affordances*, not the DOM.** Attribute whitelist, containment
   propagation, SVG collapse, text as separate lines, plus *synthesized*
   attributes (`format=YYYY-MM-DD`, `compound_components`) that the DOM never
   had. The representation is designed for the consumer's decision, not for
   fidelity to the source.
3. **Rebuild the prompt every step instead of appending to a transcript.** The
   harness owns memory; history is a rendered artifact with explicit elision
   markers and a two-tier (`extracted_content` / `long_term_memory`) result split.
4. **Delete the convenience adapter when it hides what you need.** Playwright →
   raw CDP, with a published account of exactly which failures forced it.
5. **Make self-evaluation a required schema field.** `evaluation_previous_goal` /
   `memory` / `next_goal` are structurally mandatory, so reflection can't be
   skipped by a compliant model.
6. **Occlusion via a paint-order rectangle union** rather than per-element
   `elementFromPoint` — one geometric pass over a snapshot replaces N round-trips.
7. **The tool schema is a function of current state** (URL filters, capability
   gating rewriting the click schema), rebuilt per step.
8. **Batched actions with two independent staleness aborts** — a static
   `terminates_sequence` flag and a runtime URL/target-change check.
9. **Advertise cost in the tool description** — `search_page` and `find_elements`
   are marked "Zero LLM cost", so the model can pick the cheap primitive.
10. **Harness conditions enter as prompt injections**, not silent behavior
    changes (`_inject_*` nudges, forced-done text, CAPTCHA wait fed back as
    memory).
11. **Event-bus watchdogs** own spontaneous browser events, keeping the agent
    loop free of polling.
12. **Prompt and schema scale with the model** — 24 KB / 22 KB / 2.4 KB / ~1 KB
    variants, with flash mode dropping the schema to `{memory, action}`.
13. **Secrets are substituted post-LLM**, per-domain; the model only ever sees
    `<secret>label</secret>`.
14. **The judge records but does not overrule.**
15. **Compacted memory is labelled "unverified context"** inside the prompt.
16. **The MCP surface is hand-written, not generated from the internal registry.**

## Relevance to Crescent

Mapping to what exists today — `lib/ai/tools.lua` (79 lines: a loop calling
`ai.generate`, dispatching `handlers[tc.name]`, appending `role="tool"` messages,
`max_rounds` default 10) and `lib/taskgraph` (graph, frontier, exec, context,
combinators):

**Directly relevant to `lib/ai`:**

- The **transcript-vs-rebuilt-prompt** decision is the fork in the road.
  `tools.lua` currently appends forever, which is the right minimal thing but has
  no answer for long runs. browser-use shows the alternative: a `MessageManager`
  that owns history as a rendered string with explicit elision. Both are viable;
  the rebuilt-prompt design costs prompt caching and gains full control. Naming
  note for crescent conventions: a "message manager" is not a verb phrase — the
  crescent-shaped version would be functions like `messages_from_history(...)`.
- The **two-tier result split** (`extracted_content` vs `long_term_memory`) is
  cheap to adopt and pays immediately: a tool handler that returns 200 KB of page
  text shouldn't put 200 KB into every subsequent turn. Today `tools.lua` puts the
  handler's full return string into the message list permanently.
- **Structured reflection fields.** If crescent's agent app wants an enforceable
  loop rather than a hope-based one, `evaluation_previous_goal` / `memory` /
  `next_goal` as required response fields is the mechanism — and it needs the
  provider layer to support constrained/structured output, which is a `lib/ai`
  question worth settling before the app is designed.
- **Injected caps as reserved parameter names** is a pattern crescent has an
  opinion about already (caps-first, everywhere). browser-use's version
  (`browser_session`, `file_system` injected by name, never shown to the LLM,
  collision = error) is a concrete precedent for how tool handlers receive caps
  without the model seeing them. Crescent's current `handlers` signature
  `(args) -> string` has no cap channel at all — that is a real gap to close
  before the agent app, not after.
- **Measured, not estimated, token accounting**, with per-provider cache tiers,
  belongs in `lib/ai` rather than in each app.

**Relevant to a `lib/platform/apps/` agent:**

- **Scope the blast radius rather than interrupt for consent** is one coherent
  position (browser-use); **approve every action** is the other (Cline). This is
  a genuine open decision for crescent, not something to inherit by default — and
  the right answer likely differs by tool class, since crescent's agent would have
  filesystem and process caps, not just clicks.
- **Harness state as prompt injection** rather than silent control flow is a
  low-cost, high-value convention to adopt from step one.

**Relevant to `lib/taskgraph`:**

- browser-use is *not* prior art for multi-agent orchestration — it has none, by
  choice. Its `planning`/`replan_on_stall`/`loop_detection` machinery is
  single-agent adaptive control (nudges, budgets, stall detection), which is a
  different axis from taskgraph's dependency-graph execution. If crescent wants
  the adaptive-control behaviors, they belong in the agent loop, not in
  taskgraph.

**Not applicable:** the DOM extraction work itself, unless crescent ever grounds
an agent to a live UI. The transferable part is the *method* — fuse several
authoritative sources the environment already exposes, dedupe by containment,
key by an identifier the environment guarantees, and serialize for the
consumer's decision rather than for fidelity.

## Sources

Primary (source, `main` unless noted):

- [github.com/browser-use/browser-use](https://github.com/browser-use/browser-use) — repo, README, MIT license
- [CLAUDE.md](https://raw.githubusercontent.com/browser-use/browser-use/main/CLAUDE.md) — architecture and design philosophy in the project's own words
- `browser_use/agent/service.py`, `agent/views.py`, `agent/prompts.py`, `agent/system_prompts/*`, `agent/judge.py`
- `browser_use/agent/message_manager/service.py`
- `browser_use/dom/service.py`, `dom/views.py`, `dom/serializer/clickable_elements.py`, `dom/serializer/paint_order.py`, `dom/serializer/serializer.py`, `dom/markdown_extractor.py`
- `browser_use/dom/buildDomTree.js` at tag `v0.2.5` (absent from `main`) — the pre-CDP approach
- `browser_use/actor/element.py`, `actor/page.py`
- [tools/service.py](https://raw.githubusercontent.com/browser-use/browser-use/main/browser_use/tools/service.py), [tools/registry/service.py](https://raw.githubusercontent.com/browser-use/browser-use/main/browser_use/tools/registry/service.py), [tools/views.py](https://raw.githubusercontent.com/browser-use/browser-use/main/browser_use/tools/views.py)
- [sandbox/sandbox.py](https://raw.githubusercontent.com/browser-use/browser-use/main/browser_use/sandbox/sandbox.py), [browser/profile.py](https://raw.githubusercontent.com/browser-use/browser-use/main/browser_use/browser/profile.py), [browser/session_manager.py](https://raw.githubusercontent.com/browser-use/browser-use/main/browser_use/browser/session_manager.py)
- [filesystem/file_system.py](https://raw.githubusercontent.com/browser-use/browser-use/main/browser_use/filesystem/file_system.py), [skills/service.py](https://raw.githubusercontent.com/browser-use/browser-use/main/browser_use/skills/service.py)
- [mcp/server.py](https://raw.githubusercontent.com/browser-use/browser-use/main/browser_use/mcp/server.py), [mcp/client.py](https://raw.githubusercontent.com/browser-use/browser-use/main/browser_use/mcp/client.py)
- `browser_use/tokens/service.py`

Published rationale:

- [Closer to the Metal: Leaving Playwright for CDP](https://browser-use.com/posts/playwright-to-cdp) — the migration's reasoning
- [Changelog: We switched from Playwright to CDP (2025-08-19)](https://browser-use.com/changelog/19-8-2025)

Docs:

- [docs.browser-use.com](https://docs.browser-use.com/) — [quickstart](https://docs.browser-use.com/quickstart), [hooks](https://docs.browser-use.com/customize/hooks), [output format](https://docs.browser-use.com/customize/agent/output-format), [parallel browsers](https://docs.browser-use.com/customize/examples/parallel-browser), [cloud human-in-the-loop](https://docs.browser-use.com/cloud/agent/human-in-the-loop)

Third-party:

- [Beyond Pixels: Exploring DOM Downsampling for LLM-Based Web Agents (arXiv 2508.04412)](https://arxiv.org/html/2508.04412v1) — characterizes browser-use's "element extraction" and grounded GUI snapshots; measures 65% vs 63% success with/without screenshots; argues extraction discards hierarchy that LLMs can use
- Issues [#3341](https://github.com/browser-use/browser-use/issues/3341), [#221](https://github.com/browser-use/browser-use/issues/221) — human-in-the-loop approval as an open request
