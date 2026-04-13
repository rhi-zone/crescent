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

## Views (not yet designed)

- **Card editor** — CCv2 fields, persona, scenario, system prompt
- **Lorebook editor** — keyword rules, insertion settings
- **Settings** — LLM selection, impersonate prompt, generation params, UI prefs
