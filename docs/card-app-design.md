# Card App Design

A card app is a self-contained crescent app (tarball format) that owns its own
conversation view, editor, and settings. The platform shell launches it; the app
handles all internal navigation.

> **Status: active design session.** Conversation view is roughed out below.
> Editor and settings views need their own design pass.

## Conversation view

The primary view. Minimal — the right things visible, nothing extra.

### Layout

- **Messages** fill the viewport, scrollable
- **Input row** pinned to the bottom
- No persistent top bar beyond what's strictly necessary

### Per-message UI

Every message (user and assistant) can have siblings (from edits/regenerations).

**Branch indicator** — shown when siblings exist. Displays current/total (e.g.
`2/3`). Always visible on messages with siblings so the user knows they're there.

**Gestures (touch):**
- Swipe left on left half of message → previous sibling
- Swipe right on left half of message → next sibling  
- Swipe left elsewhere on message → reveal actions (edit, delete)

**Hover (desktop):** actions appear on hover — edit, delete.

Actions are the same for user and assistant messages.

### Input row

Single-line text field that expands to a max height (~30% of viewport above
keyboard) before scrolling internally. Three action buttons alongside it:

- **Send** — sends the current input as a user message
- **Continue** *(hidden by default, configurable in settings)* — continues the last
  assistant message via prefill (passes existing message as assistant turn prefix).
  Only available when the active LLM supports prefill; dimmed otherwise.
- **Impersonate** *(hidden by default, configurable in settings)* — generates a
  user-side message using a configurable impersonate prompt. Cannot use prefill
  (prompt is different). Prompt is configurable in card settings, with a sensible
  default.

No regenerate button — swipe left on the last assistant message to regenerate.

### Keyboard (desktop)

- Enter → send
- Shift+Enter → newline

## Branching model

Backed by `lib/conversation` (vendored into the app tarball). Every regeneration
or edit inserts a new branch node; `canonical_child_id` tracks the active path.
Swiping updates `canonical_child_id` to a sibling. No duplication, no explicit
checkpoint concept — the tree IS the history.

Stored in a `shared_db` cap (see platform-design.md) so cross-card conversation
search works from the shell.

## Context assembly

The card script owns context assembly entirely — it builds the messages array and
calls `caps.llm.call(messages)`. The platform has no opinion about what goes in the
context.

### Block ordering

User-reorderable (stored in `caps.config`). Default order (matching ST):

1. System prompt (`main`)
2. Lorebook "before" entries
3. User persona
4. Character description
5. Character personality
6. Scenario
7. Lorebook "after" entries
8. Dialogue examples
9. Chat history
10. Post-history system prompt ("jailbreak")

Extension injections (author's note, summary, etc.) are inserted at absolute
positions within the chat history at a specified depth.

### Token budget

`max_context - max_response_tokens`. The card declares both; `caps.llm` exposes
`count_tokens(text)` backed by the backend's tokenizer endpoint.

### Trimming strategy (ST parity)

- **Fixed blocks** (system prompt, persona, description, scenario) — always included,
  consume budget unconditionally. No trimming.
- **Lorebook** — has its own percentage budget (default 25% of `max_context`). Entries
  are processed in priority order (sticky first, then by `order` field descending).
  Once budget overflows, new entries are skipped unless marked `ignoreBudget`.
- **Dialogue examples** — dropped as whole blocks when over budget. `pin_examples`
  option guarantees them at the cost of fewer history messages.
- **Chat history** — the only section truly trimmed. Newest-to-oldest iteration;
  oldest messages drop first when budget runs out.

### Lorebook scanning

Aho-Corasick (NFA) over all keywords — build the automaton once, scan recent
messages in a single pass. Scan depth (how many recent messages to check) is
user-configurable.

### `caps.llm` API

```lua
caps.llm.call(messages)          -- { role, content }[] -> response string
caps.llm.count_tokens(text)      -- -> integer (uses backend tokenizer endpoint)
```

## Lorebook editor

### Entry structure

Each entry has:
- **Name** — the entry's title
- **Keywords** — trigger patterns (Aho-Corasick matched against recent messages)
- **Content** — prose injected into context when triggered
- **Meta** — open key-value object, same pattern as card manifest `meta`. Author-defined fields for search/filtering: topic, faction, location, character, etc. No fixed schema.
- **Settings** — position, depth, order, probability, case sensitivity, sticky, constant, ignore budget (ST parity)

### List view

Entries shown with name + keywords visible at a glance. Sorted by order field by
default; sortable by any metric (name, uid, enabled status, etc.). Projectional
search over all fields including `meta` — same search paradigm as the card library,
no separate search model to learn.

### Entry detail view

Full-screen on mobile. Content textarea, keyword chip input (tag-style), meta fields,
settings in a collapsible section.

## Views (not yet designed)

- **Card editor** — CCv2 fields, persona, scenario, system prompt
- **Lorebook editor** — keyword rules, insertion settings
- **Settings** — LLM selection, impersonate prompt, generation params, context
  composition ordering, lorebook budget %, pin_examples, UI prefs
