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

### Format compatibility

Two lorebook formats exist in the wild — both must be supported:

**CCv2 (`CharacterBook`)** — embedded in the card's `chara` PNG chunk alongside character data. Simple format: `entries[]` array, each entry has `keys[]`, `content`, `enabled`, `insertion_order`, `selective?`, `secondary_keys?`, `constant?`, `position?` ("before_char"/"after_char"), `case_sensitive?`, `priority?`. Detected by presence of `extensions` field on the book object.

**ST lorebook** — standalone `.json` file. `entries` is a string-keyed object (`{"0": {...}, "1": {...}}`). Richer format with many ST-specific fields beyond CCv2. Detected by absence of `extensions` field.

**Field mapping (CCv2 → ST):**

| CCv2 | ST |
|---|---|
| `keys` | `key` |
| `!enabled` | `disable` |
| `insertion_order` | `order` |
| `case_sensitive` | `caseSensitive` |
| `secondary_keys` | `keysecondary` |
| `position: "before_char"` | `position: 0` |
| `position: "after_char"` | `position: 1` |

**ST `position` integer values:**
```
0 = before          — before character definitions
1 = after           — after character definitions
2 = ANTop           — top of Author's Note
3 = ANBottom        — bottom of Author's Note
4 = atDepth         — injected at specific chat depth (uses `depth` + `role`)
5 = EMTop           — top of Example Messages
6 = EMBottom        — bottom of Example Messages
7 = outlet          — named outlet injection (uses `outletName`)
```

**`selectiveLogic` values:**
```
0 = AND_ANY  — any secondary key triggers (default)
1 = NOT_ALL  — triggers unless all secondary keys match
2 = NOT_ANY  — triggers unless any secondary key matches
3 = AND_ALL  — all secondary keys must match
```

**`role` values (used when position = 4 / atDepth):**
```
0 = system
1 = user
2 = assistant
```

**Implementation notes:**
- `selective: true` is now always set in ST (all entries are selective); `selectiveLogic` controls the behaviour.
- ST-specific fields with no CCv2 equivalent: `uid`, `selectiveLogic`, `vectorized`, `addMemo`, `ignoreBudget`, `excludeRecursion`, `preventRecursion`, `probability`, `useProbability`, `depth`, `scanDepth`, `group`, `groupOverride`, `groupWeight`, `useGroupScoring`, `sticky`, `cooldown`, `delay`, `triggers`, `displayIndex`, `characterFilter`, `automationId`, `matchWholeWords`, `match*` flags.
- When exporting to CCv2: ST-specific fields dropped, `extensions` set to `{}`, position integer → string.

Crescent uses ST format as the internal representation. CCv2 lorebooks are converted on import.

### Entry structure

Each entry has:
- **Name** (`comment`) — the entry's title
- **Keywords** (`key[]`) — primary trigger patterns; supports regex (e.g. `/pattern/i`)
- **Secondary keywords** (`keysecondary[]`) + `selectiveLogic` (AND/NOT/AND NOT)
- **Content** — prose injected into context when triggered
- **Meta** — open key-value object for search/filtering (not in ST format — stored in crescent's extended format, dropped on CCv2 export)
- **Settings** — all ST fields: position, depth, order, probability, sticky, cooldown, constant, ignoreBudget, role, group, characterFilter, etc.

### List view

Entries shown with name + keywords visible at a glance. Sorted by order field by
default; sortable by any metric (name, uid, enabled status, etc.). Projectional
search over all fields including `meta` — same search paradigm as the card library,
no separate search model to learn.

### Entry detail view

Full-screen on mobile. Content textarea, keyword chip input (tag-style), meta fields,
settings in a collapsible section.

## CCv2 card format

`spec: "chara_card_v2"`, `spec_version: "2.0"`, stored as base64 JSON in the PNG `chara` iTXt chunk.

**V1 fields** (all strings, required):
- `name`, `description`, `personality`, `scenario`, `first_mes`, `mes_example`

**V2 additions:**
- `creator_notes: string`
- `system_prompt: string`
- `post_history_instructions: string`
- `alternate_greetings: string[]`
- `character_book?: CharacterBook`
- `tags: string[]`
- `creator: string`
- `character_version: string`
- `extensions: object` — open record for ST extensions: `depth_prompt?`, `talkativeness?`, `fav?`, `world?`, `regex_scripts?`

**`mes_example` format:** blocks separated by `<START>`. Each message prefixed with `{{char}}:` or `{{user}}:`.

## Macro substitution

ST uses `{{macroName}}` syntax. Substitution happens before sending to the LLM.
Legacy aliases `<USER>`, `<BOT>`, `<CHAR>` also replaced.

Full list (98 macros, source: https://docs.sillytavern.app/usage/core-concepts/macros/):

**Names & participants:** `{{user}}`, `{{char}}`, `{{group}}`, `{{groupNotMuted}}`,
`{{charIfNotGroup}}`, `{{notChar}}`

**Character card & persona:** `{{description}}`, `{{personality}}`, `{{scenario}}`,
`{{persona}}`, `{{charPrompt}}`, `{{charInstruction}}`, `{{charDepthPrompt}}`,
`{{charCreatorNotes}}`, `{{charVersion}}`, `{{mesExamples}}`, `{{mesExamplesRaw}}`,
`{{charFirstMessage}}`, `{{original}}`

**Chat history:** `{{lastMessage}}`, `{{lastMessageId}}`, `{{lastUserMessage}}`,
`{{lastCharMessage}}`, `{{firstIncludedMessageId}}`, `{{firstDisplayedMessageId}}`,
`{{lastSwipeId}}`, `{{currentSwipeId}}`, `{{allChatRange}}`, `{{summary}}`

**Time & date:** `{{time}}`, `{{time::UTC±offset}}`, `{{date}}`, `{{weekday}}`,
`{{isotime}}`, `{{isodate}}`, `{{datetimeformat::format}}`, `{{idleDuration}}`,
`{{timeDiff::left::right}}`

**Variables (local):** `{{getvar::name}}`, `{{setvar::name::value}}`,
`{{addvar::name::value}}`, `{{incvar::name}}`, `{{decvar::name}}`,
`{{hasvar::name}}`, `{{deletevar::name}}`

**Variables (global):** `{{getglobalvar::name}}`, `{{setglobalvar::name::value}}`,
`{{addglobalvar::name::value}}`, `{{incglobalvar::name}}`, `{{decglobalvar::name}}`,
`{{hasglobalvar::name}}`, `{{deleteglobalvar::name}}`

**Randomization:** `{{random::a::b::c}}` (re-rolls each time),
`{{pick::a::b::c}}` (stable per chat/position), `{{roll::1d20}}`

**Runtime state:** `{{maxPrompt}}`, `{{maxContextTokens}}`, `{{maxResponseTokens}}`,
`{{model}}`, `{{isMobile}}`, `{{lastGenerationType}}`, `{{hasExtension::name}}`

**Prompt templates:** `{{systemPrompt}}`, `{{defaultSystemPrompt}}`,
`{{authorsNote}}`, `{{charAuthorsNote}}`, `{{defaultAuthorsNote}}`,
`{{instructUserPrefix}}`, `{{instructAssistantPrefix}}`, `{{instructSystemPrefix}}`,
`{{instructSeparator}}`, `{{instructStop}}`, `{{instructUserFiller}}`,
`{{instructFirstAssistantPrefix}}`, `{{instructLastAssistantPrefix}}`,
`{{instructFirstUserPrefix}}`, `{{instructLastUserPrefix}}`,
`{{instructStoryStringPrefix}}`, `{{instructStoryStringSuffix}}`,
`{{instructSystemInstructionPrefix}}`, `{{instructAssistantSuffix}}`,
`{{instructUserSuffix}}`, `{{instructSystemSuffix}}`,
`{{chatSeparator}}`, `{{chatStart}}`,
`{{reasoningPrefix}}`, `{{reasoningSuffix}}`, `{{reasoningSeparator}}`,
`{{charPrefix}}`, `{{charNegativePrefix}}`, `{{outlet::key}}`

**Utility:** `{{newline}}`, `{{newline::count}}`, `{{space}}`, `{{space::count}}`,
`{{noop}}`, `{{trim}}`, `{{reverse::text}}`, `{{input}}`, `{{banned::word}}`

## Views (not yet designed)

- **Card editor** — edit CCv2 fields (name, description, personality, scenario, first_mes, mes_example, system_prompt, post_history_instructions, alternate_greetings, creator_notes, tags)
- **Settings** — LLM selection, impersonate prompt, generation params, context
  composition ordering, lorebook budget %, pin_examples, show/hide continue+impersonate buttons, UI prefs
