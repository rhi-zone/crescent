# Platform Design

The crescent platform is a substrate for running sandboxed Lua scripts with explicit
capability grants. It is not LLM-specific, not character-card-specific, and has no
hardcoded knowledge of any external format (CCv2, charx, etc.). Format knowledge lives
entirely in scripts.

## Core model

An **app** is a gzipped tar archive containing a `manifest.json` and Lua source files.
It may be distributed as a raw `.tar.gz` or embedded in an image file (PNG, JPEG, WebP)
for the "distributable as an image" use case. The image is optional decoration.

The platform:
1. Loads an app (unpacks the tarball, parses the manifest)
2. Selects the appropriate entrypoint for the current host
3. Decides which capabilities to grant (operator approves declared caps)
4. Runs the entrypoint in a sandbox (`lib/sandbox`) with those capabilities

The platform has no opinion about what the script does. The script is the program.

## Capability surface

Capabilities are plain Lua tables passed to the sandbox. The platform owns the
implementations; the script receives exactly what it's granted.

**Two kinds of cap:**
- **State caps** expose `Signal<T>` values — reactive cells the script reads and
  subscribes to. Changes propagate instantly; no polling, no restart.
- **Action caps** expose functions — imperative calls like `llm.call`, `fs.write`.

This means live cap swapping (e.g. switching LLM backend mid-session) works without
restart for state caps — the script holds a signal reference and the host pushes a
new value through it.

```lua
-- example grant
sandbox.run(script, sandbox.env(
  sandbox.stdlib,
  { globals = {
    png    = png_cap({ allow = {"chara"} }),
    llm    = llm_cap(model_config),   -- action cap: llm.call(messages)
    config = config_cap(user_dir),    -- state cap: config.theme, config.presets, ...
  }}
))
```

### `caps.png` — chunk access

Read and write metadata chunks in the app's image file by name.

```lua
caps.png.text(name)           -- read chunk, returns string | nil
caps.png.set_text(name, val)  -- write chunk
```

The `png_cap` constructor accepts an optional allowlist:

```lua
png_cap({ allow = {"chara"} })  -- only these chunks accessible
png_cap()                        -- unrestricted (trusted scripts only)
```

Denied chunk access errors immediately. All format parsing (JSON, base64, etc.) is
the script's responsibility. The platform never interprets chunk contents.

### `caps.llm` — LLM oracle (action cap)

A stateless function call. The LLM is not a participant; it is a tool.

```lua
local response = caps.llm.call(messages)  -- messages: array of {role, content}
```

Model selection, API keys, and retry logic are the capability implementation's concern.
The script assembles the messages array however it wants.

### `caps.render` — UI surface (action cap)

Push content to the render surface.

```lua
caps.render.push(content)
```

### `caps.db` — SQLite database handle (action cap)

A pre-opened SQLite connection. The app writes raw SQL — no structured query
API. Two isolation tiers:

**Per-app db files** (`"type": "db"`) — the host opens a file scoped to the
app (`~/.crescent/data/<user_id>/<app_id>/<name>.db`). Isolation is at the
file level. Use for app-private data (cache, local state).

**Shared db with view isolation** (`"type": "shared_db"`) — the host opens a
shared platform db (e.g. the conversations db), registers a SQLite authorizer
that blocks direct access to underlying tables, then creates per-connection
temp views pre-filtered to `app_id`. The app queries the views with full SQL
expressiveness; the underlying tables are unreachable. The host (which owns the
connection without an authorizer) can query across all apps for cross-card
search.

```
host setup per app connection:
  1. open shared.db
  2. register authorizer → SQLITE_DENY for raw table access
  3. CREATE TEMP VIEW sessions AS SELECT * FROM sessions WHERE app_id = '<id>'
  4. CREATE TEMP VIEW messages AS SELECT * FROM messages WHERE app_id = '<id>'
  5. hand connection to app
```

The authorizer callback is JIT-compiled via `lib/asm/` — zero LuaJIT trampoline
overhead, no C dependency.

Multiple db caps with different names if the app needs separate concerns:

```json
"caps": {
  "conversations": { "type": "shared_db", "required": true },
  "cache":         { "type": "db",        "required": false }
}
```

The optional `"readonly": true` flag opens the file with `SQLITE_OPEN_READONLY`.
Use this when an app needs read access to a db it doesn't own — e.g. the shell
app reading the platform's metadata db:

```json
"caps": {
  "library": { "type": "db", "required": true, "readonly": true }
}
```

The same `readonly` flag applies to `caps.fs` — the host opens the scoped
directory read-only, write attempts error immediately.

### `caps.kv` — key-value store (action cap)

Lightweight persistent storage for small values: current position, per-app
preferences, flags. The host allowlists which keys/prefixes the app may
access; denied keys error immediately.

```lua
caps.kv.get(key)         -- returns string | nil
caps.kv.set(key, value)  -- value must be string; nil deletes
```

This is the canonical mechanism for saved state — the app writes its current
position here on every navigation; the host reads it on next launch and passes
it back as a startup argument. Apps that only need to remember where they were
get `caps.kv`, not a full db connection.

### `caps.fs` (optional) — file access (action cap)

Granted only to explicitly trusted scripts. Scoped to a directory.

### `caps.config` (optional) — user-level config (state cap)

Exposes user-owned configuration as signals: UI preferences, global presets, global
lorebooks, theme. Scoped to a user config directory (`~/.crescent/` by default).

```lua
caps.config.theme        -- Signal<string>: current theme name
caps.config.presets      -- Signal<Preset[]>: user's global presets
caps.config.lorebooks    -- Signal<Lorebook[]>: user's global lorebooks
caps.config.ui           -- Signal<table>: arbitrary UI layout/pref overrides
```

Apps that don't declare `caps.config` never read user config and are fully
self-contained. Apps that do declare it get live-updating user preferences with no
extra plumbing — the signal propagates changes to every subscribed component
automatically.

## Script / data separation

The script and data chunks are strictly independent:

- **Script**: pure logic. Never written by the editor, never modified by tooling.
  Reads its inputs through capabilities. The same script can run against different
  data — useful for multi-character scenarios or persona swaps.

- **Data**: content and configuration. Owned entirely by the editor. The script
  reads data through `caps.png.text("data")` (or whatever chunk it declares).

This means editors never do writeback into script source. Diffs stay clean.
Users keep their edits. Tooling that modifies script text is explicitly out of scope.

## Format agnosticism

The platform has zero knowledge of CCv2, charx, or any other card format. A script
that reads CCv2 data does so itself:

```lua
-- CCv2 knowledge lives here, in the script — not in the platform
local raw      = caps.png.text("chara")          -- CCv2 stores data in "chara" chunk
local ccv2     = json.decode(base64.decode(raw))
local name     = ccv2.data.name
local persona  = ccv2.data.description
```

CCv2 import is therefore free: the CCv2 card editor is a script that knows how to
read the `chara` chunk. The platform just provides chunk access.

The data capability is the abstraction layer. CCv2 fields are one implementation.
Crescent structured data is another. The script sees one API either way — whatever
the capability implementation returns from `caps.png.text(name)`.

## App internal routing

An app's `dom` entrypoint owns its entire UI — conversation, editor, lorebook editor,
settings, all of it. Navigation between views is internal to the app, not external
entrypoints. This gives smooth transitions, shared state across views, and no
reload between them.

The shell has no knowledge of what views an app contains. It launches `dom` and the
app handles its own routing. A "edit this app" button in the shell just opens the
app's `dom` entrypoint — the app decides whether to show the editor first or the
conversation first based on context.

Format-specific tooling (CCv2 editor, lorebook editor) lives inside the app that
knows the format. The shell has no idea what CCv2 is and never will.

### CCv2 app internal views

A first-party CCv2-compatible app ships with these internal views under `dom`:

**Conversation view** — the interaction loop. LLM calls, worldstate, context
assembly. The user-facing primary view.

**CCv2 card editor** — rich-text editing of CCv2 fields (description, personality,
scenario, etc.). `{{char}}`, `{{user}}` macros render as live inline components;
cursor entry expands to raw macro text for editing. Extension field: structured
sub-blocks stored in `extensions.crescent`, flattened to plain text for CCv2 export.

**CCv2 lorebook editor** — hard-optimized for CCv2's lorebook shape: keyword lists,
case sensitivity, scan depth, probability, priority, insertion position. Familiar to
SillyTavern users.

Crescent-native context construction is arbitrary script logic. There is no
"crescent lorebook" concept — scripts that need dynamic context injection write it
in code. The lorebook editor exists only for CCv2 compatibility.

## Conversation tree schema

The conversation history is a tree stored in SQLite. Each node is a message; branches
are created by regenerating or editing a turn.

```sql
CREATE TABLE sessions (
  id         TEXT PRIMARY KEY,   -- uuid
  app_id     TEXT NOT NULL,      -- which app/card this belongs to
  created_at INTEGER NOT NULL,   -- unix timestamp
  metadata   TEXT                -- open JSON: title, summary, preview image, etc.
);

CREATE TABLE messages (
  id                 TEXT PRIMARY KEY,
  session_id         TEXT NOT NULL REFERENCES sessions(id),
  parent_id          TEXT REFERENCES messages(id),  -- NULL = root
  role               TEXT NOT NULL,  -- 'user' | 'assistant' | 'system'
  content            TEXT NOT NULL,
  created_at         INTEGER NOT NULL,
  canonical_child_id TEXT REFERENCES messages(id),  -- saved swipe: last visited child
  metadata           TEXT  -- open JSON: model used, token count, timing, etc.
);
```

**`canonical_child_id`** — every node remembers which child you last navigated to.
Following `canonical_child_id` from the root reconstructs the active path. Navigating
into any branch and back out resumes from where you left in that branch. This applies
to all branches, not just the active one.

**Root**: `SELECT * FROM messages WHERE session_id = ? AND parent_id IS NULL`.
No `first_message_id` on sessions needed.

**Branching**: insert new child message, update parent's `canonical_child_id` to the
new child. **Swiping**: change parent's `canonical_child_id` to an existing sibling.

## Preset library

A preset is a starter script you copy into a card and edit. The script is
data-driven — config tables near the top, behavior derived from them below — so
customization means editing data, not restructuring code.

Presets are `.lua` files with metadata. No runtime machinery: the platform browses
the preset library, the user picks one, it drops into the card's script chunk.
Users fork presets freely; the platform has no opinion about what they do next.

## Saved state pattern

The core idea: every meaningful state the platform can render is addressable and
returnable. There is no distinction between "current app" and "saved state." The
current session is itself a saved state; reboot restores it automatically.

**Mechanism.** The app writes its current position to `caps.kv` on every navigation
(e.g. `caps.kv.set("state", json.encode({ session_id = "...", branch_id = "..." })`).
On next launch, the host reads this value and passes it back as a startup argument.
The app interprets its own state — the platform stores it opaquely.

**Multi-user.** The host is a server; multiple users access it over the network
(Tailscale or similar). `user_id` is on all persistent data. `caps.kv` and `caps.db`
are scoped per user per app — users never see each other's state.

**Data layout.** Each app gets a directory on the host:
```
~/.crescent/data/<user_id>/<app_id>/
  kv.db          ← caps.kv backing store
  conversations.db  ← caps.db("conversations"), if declared
  cache.db          ← caps.db("cache"), if declared
  ...
```

**Everything navigable is a saved state.** The card library viewer, the card editor,
an interaction session, a chat tree branch — navigating between them is writing a new
`state` key to `caps.kv`. Restore is reading it back. No platform concept of "which
app is open" beyond this.

## Self-contained apps

The crescent app format is a **gzipped tar archive** containing a `manifest.json` and
arbitrary Lua files, shared libraries, and assets. The image wrapper is optional — the
core format is just the tarball.

**Distribution formats** — the platform accepts all of these:

```
myapp.tar.gz              — raw tarball, no image wrapper
myapp.png                 — PNG with lua iTXt chunk: base64(gzip(tar))
myapp.jpg / myapp.webp    — JPEG/WebP with XMP metadata: same base64(gzip(tar))
```

For image-embedded apps, the `lua` metadata key contains `base64(gzip(tar))`, following
the same convention as CCv2 (`chara` is base64-encoded JSON). The image is decoration —
the app is the tarball. gzip compression more than offsets the base64 overhead for Lua
source.

```
myapp.png
├── chara   (tEXt — base64 JSON, CCv2 format, untouched — if this app is also a CCv2 card)
└── lua     (iTXt — base64(gzip(tar)))
    ├── manifest.json
    ├── (arbitrary .lua files and assets)
    └── ...
```

### Manifest

`manifest.json` declares the app's entrypoints, capability requirements, and metadata.
JSON so that external tools (`exiftool`, `tar`, `jq`) can inspect apps without a Lua
runtime.

```json
{
  "name": "My Character",
  "version": "1.0.0",
  "meta": {
    "hair.color": "blonde",
    "species": "elf",
    "tags": ["fantasy", "adventure"],
    "creator": "someone",
    "rating": "SFW"
  },
  "caps": {
    "db": "required"
  },
  "entry": {
    "dom": {
      "main": "ui/dom.lua",
      "caps": {
        "llm_main":    { "type": "llm", "required": true },
        "llm_summary": { "type": "llm", "required": false },
        "render":      { "type": "render", "required": true }
      }
    },
    "mcp": {
      "main": "mcp/main.lua",
      "caps": {
        "llm": { "type": "llm", "required": true }
      }
    },
    "headless": {
      "main": "run/batch.lua",
      "caps": {
        "llm": { "type": "llm", "required": true },
        "fs":  { "type": "fs",  "required": false }
      }
    }
  }
}
```

**Capability declarations:**

- Top-level `caps` declares caps shared across all entrypoints (e.g. `db` above).
- Top-level `meta` is an open key-value object — author-defined, no fixed schema.
  Any fields the author wants to expose for search/filtering go here: `hair.color`,
  `species`, `tags`, `rating`, etc. The shell's projectional search indexes whatever
  is present. Source adapters (chub, itch) populate this from their native metadata
  when importing. Tags are just a conventional field in `meta`, not special.
- Per-entrypoint `caps` declares additional caps specific to that entrypoint.
- Each cap has a `type` (the capability kind the host must provide), `required`
  (if `false`, the cap may be absent — the script receives `nil` for that slot and
  must handle it), and an optional `readonly` flag (if `true`, the host opens the
  resource read-only — writes error immediately).
- Cap names are the keys the script uses to access them (e.g. `caps.llm_main`).
  Multiple caps of the same type are supported — names disambiguate them.

**Capability protocol:**

Caps are plain Lua tables. The format makes no assumption about reactivity. If a host
wants to support live cap swapping without restarting the entrypoint (e.g. switching
which LLM backend is active), it may wrap caps in signals and pass a signal-aware env
— but this is a host/script agreement. Scripts that don't need live swapping use caps
as plain values.

Entrypoint keys are conventions the host understands; unrecognised keys are ignored.
An app need not implement all entrypoints — it declares only what it supports.

The host reads the manifest, selects the entrypoint it needs, grants the declared caps
(prompting the operator for approval if needed), and runs the entrypoint sandboxed.
Shared code between entrypoints is just files in the tarball — `require` resolves
against the tarball root via a custom loader injected into `package.loaders`.
Host `lib.*` is always available as a fallback; the tarball loader runs first, so
any file in the tarball shadows the equivalent host library if paths match.

### Vendoring

Apps should be as self-contained as possible. Pure logic the app owns
(conversation tree, context assembly, format parsers) is vendored into the
tarball. Ubiquitous host utilities (`lib.json`, `lib.base64`, `lib.sqlite`)
can be required from the host — every crescent host ships them, and vendoring
them adds size with no portability benefit.

**Namespace convention.** The tarball root is the app's implicit namespace —
`require("conversation")` resolves to `conversation.lua` at the tarball root.
There is no enforced prefix. If you want `require("app.conversation")` for
clarity, put the file at `app/conversation.lua` in the tarball. First-party
apps use `app/` by convention. Someone reading the code sees the path and knows
where to look.

Sharing a card shares the exact scripts that produced it. No separate install step;
the card is the complete application.

The platform can optionally upgrade embedded scripts to a newer version, but the
upgrade logic is itself a script — the platform does not hardcode any migration policy.

## Library shell

The first-party library shell is an app (in the same format) that browses and launches
other apps. It is a **unified library browser** over multiple heterogeneous data
sources, each with an adapter.

**Adapter interface:**
```lua
source.list()              -> { id, metadata, open }[]
source.search(query)       -> { id, metadata, open }[]
source.write(id, metadata) -> ok | nil, err  -- optional, for writable sources
```

**Built-in adapters:**
- Crescent app directory — reads `manifest.json` from installed `.tar.gz`/`.png` files
- itch butler.db — maps `games` schema to open metadata (read + write)
- Steam — parses `libraryfolders.vdf` + `appmanifest_*.acf`
- Filesystem — any directory, entries are files with whatever metadata is extractable
- Browser bookmarks — Chrome `Bookmarks` JSON, Firefox `places.sqlite`
- Obsidian / Dendron — frontmatter YAML from `.md` files

**Metadata is open JSON.** Each adapter maps its native format to a `metadata` blob.
The shell queries it via `json_extract`. No fixed schema — the shell decides what
fields it knows how to filter on.

**Shells are lenses.** The same underlying library can be viewed through different
shells:
- A SillyTavern-style shell queries `$.characters[*].hair.color`, renders a character
  grid, shows character-specific filters
- A Steam-style shell queries `$.genre`, `$.playtime`, renders a storefront layout
- An itch-style shell queries `$.tags`, `$.rating`, renders a game library

Multiple shells can be installed; switching between them is selecting a different app
to run over the same data. The underlying `saved_states` / installed-apps table is
shared.

**The shell has no format knowledge.** It launches an app's `dom` entrypoint and the
app handles its own internal routing (conversation, editor, settings, etc.). An "edit"
button in the shell just opens `dom` — the app decides what to show.

**Filtering is a projectional editor.** The filter state is a `Signal<Query>` — a
structured value composed via widget combinators (`narrow`, `focus`, `each`), not a
text search box or flat tag list. The query widget lets users compose conditions
(`hair.color = "blonde" AND cup_size = "D"`). Results are
`computed(() => db.query(to_sql(query.get())))` — reactive, instant. Natural language
input ("blonde D cup") is the primary construction mechanism; the projectional view
is the inspector and tweaker.

## HTTP server wiring

The `dom` entrypoint is Lua source. The HTTP server transpiles it to JS on first
request via `lib/lua2ts`, caches the result in memory, and serves it statically.
No build step, no `dist/` directory in the tarball.

```
GET /          → minimal HTML bootstrap shell (inline string, no file)
GET /app.js    → lua2ts(dom_entrypoint_source), cached after first run
GET /static/*  → files from the tarball by path
GET /api/*     → routed to app request handlers (Lua, sandboxed)
```

The HTML bootstrap is ~5 lines: `<!DOCTYPE html>` + `<script src="/app.js">`. The JS
bootstraps the reactive DOM from there. Dependencies (`lib/reactive`, `lib/widget`,
`lib/web/reactive_dom`) are included in the lua2ts output — they are part of the
tarball and transpiled together with the entrypoint.

The cache invalidates on app reload (tarball changes). On first request there is a
one-time transpilation cost; subsequent requests are instant.

**Type checking browser-target code** requires `--:: require "lib.web.js_types"` at
the top of browser-facing Lua files. The typechecker loads it as declarations; the
runtime ignores it (it's a comment).

## UI design principles

These apply to all first-party app UIs (library shell, conversation app, editors).

**Affordances reflect state, not convention.** Don't add buttons because they are
conventional — derive the affordance set from the state machine. Ask: what does the
user most likely want *right now*? Only that is shown active. Affordances that don't
exist in the current state are not invented.

**Three affordance levels, fixed positions:**
- **Active** — valid and likely given current state/context
- **Dimmed** — valid but low probability (e.g. "regenerate" before the model has warmed up, or a rarely-used action)
- **Disabled** — invalid in current state; shown for muscle memory, blocked from use

Dimming and disabling are distinct. Dimmed means "you could, but probably don't want
to." Disabled means "you can't right now." Pure removal is only correct when an
affordance is *never* relevant in a given context (e.g. "regenerate" in the library
browser). Otherwise, keep it in place — spatial consistency builds muscle memory.

**State machine first.** The UI vocabulary is the set of transitions between states.
Keyboard shortcuts and gestures fire transitions; components render the current state.
Undo/redo is state history, not a separate stack.

## Everything else is scripts

The platform is not a library browser, an import pipeline, or a card manager. Those
are first-party scripts:

| What it feels like | What it actually is |
|---|---|
| App library / search UI | Library shell app (described above) |
| CCv2 import pipeline | Script with `caps.fs` + `caps.png` |
| Mutate-on-import logic | Script (stamps app tarball on import) |
| Card editor / lorebook editor | Internal views inside each app's `dom` entrypoint |
| Preset browser | Script with `caps.fs` |

These ship alongside the platform as first-party scripts. They are not platform code.
They are replaceable, forkable, and auditable — and distributed the same way as any
other card.

The platform owns exactly two things:
1. Run a script with the capabilities the host decides to grant
2. Provide a render surface

Everything else is user-land.

## What the platform does not own

- **World state model**: the script chooses its storage. If it wants SQLite it requests
  `caps.db`. If it wants in-memory tables it uses them. The platform provides
  capability implementations for common backends; scripts pick what they need.
- **Context construction**: always the script's job. No built-in prompt assembly.
- **Conversation history**: the script decides whether to accumulate, how much to keep,
  and how to structure it. Accumulation is a choice, not a default.
- **Any external format**: CCv2, charx, TOML, YAML — all parsed by scripts.
- **Card management**: no built-in library, search, tagging, or import UI. These are
  scripts with filesystem capabilities.
- **Migration policy**: upgrade logic for embedded editor scripts is a script, not a
  platform concern.
