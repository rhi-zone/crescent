# Platform Design

The crescent platform is a substrate for running sandboxed Lua scripts with explicit
capability grants. It is not LLM-specific, not character-card-specific, and has no
hardcoded knowledge of any external format (CCv2, charx, etc.). Format knowledge lives
entirely in scripts.

## Core model

An **app** is a gzipped tar archive containing a `manifest.json`, a **backend**
(Lua source), and a **frontend** (HTML/CSS/JS). It may be distributed as a raw
`.tar.gz` or embedded in an image file (PNG, JPEG, WebP) for the "distributable as
an image" use case. The image is optional decoration.

The backend is a Lua script that runs on the host. It uses caps (LLM, database,
config, file I/O) and exposes an HTTP API — a **backend for frontend** (BFF). The
frontend is static HTML/CSS/JS served from the tarball. It contains zero business
logic — it renders what the backend tells it to render and sends back what the user
did. The frontend could be rewritten without understanding any of the app's domain.

**Apps can vendor their Lua dependencies.** If the tarball includes a dep, it's used.
If not, the platform resolves `require` calls against the host's crescent installation.
Users with a full crescent distribution can write lightweight apps that `require` host
libs directly — no vendoring needed.

**First-party apps vendor everything.** Our own apps are fully self-contained — they
run on vanilla LuaJIT with nothing pre-installed. Every Lua dependency (json, base64,
format libs, etc.) is included as plain Lua source. A typical app with full backend +
frontend + all transitive deps is ~50KB gzipped. This makes them viral: a PNG
containing a complete, readable, modifiable application that anyone can run, read, and
hack.

Security comes from the capability sandbox, not from restricting what code ships in
the tarball. The app only gets the caps it's explicitly granted — a modified `json.lua`
can't exfiltrate data because the app has no network access unless granted
`caps.http_client` with an appropriate domain whitelist. The sandbox is the security boundary, not the code review of bundled deps.

Because the platform resolves `require` as tarball-first then host-fallback, vendored
deps can be stripped from the tarball without breaking the app — it falls back to the
host's version. This is rarely a concern: most users never modify the tarball, and
those who strip vendored deps generally know what they're doing. The tradeoff is the
same as any vendoring system: pinned (works as tested) vs floating (gets host fixes).
Stable APIs minimize the risk of silent breakage.

Our first-party apps vendor deps under `lib/` inside the tarball, mirroring crescent's
require paths. A `require("lib.reactive")` resolves to `lib/reactive/init.lua` inside
the tarball. The app's own code lives at the tarball root alongside `manifest.json`.
Third-party apps can use any layout — the platform just adds the tarball root to
`package.path`.

```
manifest.json
server.lua                      ← backend entrypoint (BFF)
static/                         ← frontend (served as-is)
  index.html
  app.js
  style.css
lib/                            ← vendored Lua deps
  formats/ccv2/card.lua
  format/json/init.lua
  ...
```

The platform's require loader searches the tarball root first, then falls back to the
host's crescent installation. This means `require("server")` finds the app's own
module, `require("lib.formats.ccv2.card")` finds the vendored copy (or the host's if
stripped).

In the monorepo, vendored deps are symlinks to the canonical sources (always in sync,
zero duplication). `tar -h` dereferences them for distribution.

The platform:
1. Loads an app (unpacks the tarball, parses the manifest)
2. Selects the appropriate entrypoint for the current host
3. Decides which capabilities to grant (operator approves declared caps)
4. Runs the entrypoint in a sandbox (`lib/sandbox`) with those capabilities

The platform has no opinion about what the script does. The script is the program.

## Capability surface

Capabilities are plain Lua tables passed into the sandbox. The platform owns the
implementations; the script receives exactly what it's granted. Caps are primitives —
they do one thing. Apps compose them into higher-level behavior.

### Permissions model

Every cap goes through a permissions dialog. The operator **grants or denies** each
named cap independently — no partial grants, no narrowing. The app's manifest
declaration *is* the scope; the operator either trusts it or doesn't.

**Granularity via multiple named caps.** An app that needs two HTTP endpoints declares
two separate `http_client` caps. The operator can grant one and deny the other:

```json
"caps": {
  "llm_api":    { "type": "http_client", "host": "api.openai.com", "required": true },
  "analytics":  { "type": "http_client", "host": "telemetry.example.com", "required": false }
}
```

The app receives `caps.llm_api` and `caps.analytics` as separate tables. If the
operator denies `analytics`, the app gets nil for that cap and degrades gracefully.

**Split along degradation boundaries.** The app author decides where to split. Each
optional cap requires dedicated handling — a nil check *and* a fallback path. This
is real code, not free, so authors are incentivized to split only where it matters.
The granularity is self-regulating: too many optional caps = too many fallback paths
to maintain; too few = the operator can't selectively deny.

**Required vs optional.** `"required": true` means the app won't launch without it.
`"required": false` means the app handles absence. The platform refuses to run the
app if any required cap is denied.

### Revocation

Caps can be revoked mid-session. Each cap function is a closure over internal state
including a `revoked` boolean flag. The platform holds a revoke handle (a function
that sets the flag). On revocation, every subsequent call to that cap returns
`nil, "capability revoked"`. No proxy or metatable needed — just a boolean check
at the top of each closure.

```lua
-- cap factory returns (cap_table, revoke_fn)
local revoked = false
local cap = {
  get = function(key)
    if revoked then return nil, "capability revoked" end
    -- ...
  end,
}
local function revoke() revoked = true end
return cap, revoke  -- platform keeps revoke; app gets cap
```

The app must handle revocation the same way it handles an optional cap being absent —
check for nil/error returns. Apps that don't handle it will error, which is correct
behavior for a revoked capability.

### Example manifest

```json
{
  "name": "CCv2 Card",
  "caps": {
    "self":          { "type": "self",        "required": true },
    "server":        { "type": "http_server", "required": true },
    "llm_api":       { "type": "http_client", "host": "api.openai.com", "required": true },
    "local_llm":     { "type": "http_client", "host": "localhost:11434", "required": false },
    "conversations": { "type": "db",          "required": true },
    "settings":      { "type": "kv",          "required": false },
    "user_prefs":    { "type": "kv",          "scope": ["user"], "readonly": true, "required": false },
    "clock":         { "type": "time",        "required": true }
  }
}
```

`settings` uses default scope `["user", "app"]` — private to this card for this user.
`user_prefs` uses scope `["user"]` — shared across apps for this user (read-only).

### Example grant

```lua
-- Platform reads manifest, presents permissions dialog to operator.
-- Operator grants all except "local_llm". Platform constructs caps:
local caps, revoke_fns = {}, {}
caps.self, revoke_fns.self               = self_cap(app)
caps.server, revoke_fns.server           = http_server_cap({ port = 7860 })
caps.llm_api, revoke_fns.llm_api        = http_client_cap({ host = "api.openai.com" })
-- caps.local_llm = nil (denied)
caps.conversations, revoke_fns.conversations = db_cap(db_path)
caps.settings, revoke_fns.settings       = kv_cap(kv_path)  -- scope: [user, app]
caps.user_prefs, revoke_fns.user_prefs   = kv_cap(user_prefs_path, { readonly = true })  -- scope: [user]
caps.clock, revoke_fns.clock             = time_cap()

sandbox.run(script, sandbox.env(sandbox.stdlib, { globals = { caps = caps } }))
```

### `caps.self` — app package access

Read-only access to the app's own package contents: image metadata chunks and
tarball entries. The app was loaded from an image file (PNG/JPEG/WebP) wrapping
a tarball — this cap exposes both layers.

```lua
caps.self.metadata(keyword)   -- read image chunk by name, returns string | nil
caps.self.entries()           -- list tarball entry paths
caps.self.entry(path)         -- read a tarball entry by path, returns string | nil
```

The card data lives in `caps.self.metadata("chara")`. Static assets (HTML/CSS/JS)
live in tarball entries. Format parsing (JSON, base64, etc.) is the app's job —
the cap returns raw bytes.

### `caps.http_server` — inbound HTTP

The platform binds the port and owns the socket. The app provides a request handler.

The cap must support streaming responses (SSE) without giving the app raw socket
access. The app also needs to know its own URL (e.g. to open a browser).

### `caps.http_client` — outbound HTTP

Makes HTTP requests to whitelisted domains. The platform controls which hosts the
app can reach — the allowlist is set by the platform operator, not the app.

```lua
caps.http_client.request({
  method  = "POST",
  url     = "http://api.openai.com/v1/chat/completions",
  headers = { ["Content-Type"] = "application/json" },
  body    = json_string,
})
```

LLM protocol libraries (OpenAI, Anthropic, Ollama, etc.) are app-vendored code
that uses `caps.http_client` internally. The platform has no LLM knowledge — it
just controls network access.

### Scope dimensions

The platform provides a set of **context dimensions** — currently `{user, app}`.
Every storage cap (kv, db) has a **scope**: a subset of dimensions that determines
isolation. Each included dimension adds isolation; each excluded one shares wider.

```json
{ "type": "kv", "scope": ["user", "app"] }   // default — fully isolated
{ "type": "kv", "scope": ["user"] }           // cross-app, per-user
{ "type": "kv", "scope": ["app"] }            // cross-user, per-app
{ "type": "kv", "scope": [] }                 // global
```

Default is maximum isolation (all dimensions included). Removing a dimension widens
access and requires operator approval. This applies uniformly to kv, db, and any
future storage cap type.

Adding new dimensions later (team, room, tenant) is just adding them to the set —
no special cases, no hierarchy. It's a subset selection.

### `caps.kv` — key-value store

Lightweight persistent storage for small values: current position, per-app
preferences, flags.

```lua
caps.my_store.get(key)         -- returns string | nil
caps.my_store.set(key, value)  -- value must be string; nil deletes
```

### `caps.db` — SQLite database

A pre-opened SQLite connection. The app writes raw SQL — no structured query API.
Scope dimensions control isolation (see above).

For shared databases where multiple apps access the same tables, the platform
registers a SQLite authorizer that blocks direct access to underlying tables,
then creates per-connection temp views pre-filtered by the relevant dimension
values. The app queries the views with full SQL expressiveness; the underlying
tables are unreachable.

```
host setup per app connection (scope: ["user"]):
  1. open shared.db
  2. register authorizer → SQLITE_DENY for raw table access
  3. CREATE TEMP VIEW sessions AS SELECT * FROM sessions WHERE app_id = '<id>'
  4. CREATE TEMP VIEW messages AS SELECT * FROM messages WHERE app_id = '<id>'
  5. hand connection to app
```

The authorizer callback is JIT-compiled via `lib/asm/` — zero LuaJIT trampoline
overhead, no C dependency.

The optional `"readonly": true` flag opens the file with `SQLITE_OPEN_READONLY`.

### `caps.time` — clock

```lua
caps.clock()  -- returns Unix timestamp (integer)
```

### `caps.fs` (optional) — file access

Scoped to a directory. Per-directory read/write granularity. Scope dimensions
apply — an fs cap scoped to `["user", "app"]` gives each app its own directory;
scoped to `["user"]` gives a shared directory per user.

## Sandbox security

The sandbox is the security boundary. An app runs in a restricted Lua environment
with no access to `io`, `os`, `ffi`, `debug`, `dofile`, `loadfile`, `require`
(replaced with a whitelist loader), or `package`. Capabilities are the only way to
perform side effects.

**Cap implementation safety.** Caps are plain tables with closure-based function
values. The closures capture real IO primitives (sqlite handles, sockets, etc.)
internally, but without `debug.getupvalue` (which requires the `debug` library,
excluded from sandbox), closure upvalues are unreachable. The app cannot inspect
a cap function's internals.

**Metatable protection.** `getmetatable` is available in the sandbox (needed for
normal Lua programming). To prevent metatable-based escape:

- Cap tables must not use metatables on anything reachable by the app.
- The string metatable (shared between host and sandbox) is locked before any
  sandboxed code runs:

  ```lua
  local mt = getmetatable("")
  mt.__metatable = false  -- getmetatable("") now returns false; setmetatable errors
  ```

  This prevents the app from modifying the shared string metatable to affect the
  host. `string:method()` calls still work — `__metatable` only affects
  `getmetatable`/`setmetatable`, not `__index` dispatch.

**Bytecode loading.** `load()` is called with mode `"t"` (text only) — pre-compiled
bytecode is rejected. This prevents bytecode-based sandbox escapes.

**Instruction budget.** Optional `debug.sethook`-based instruction limit prevents
infinite loops. The hook is set by the host before running sandboxed code and cleared
after.

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
local raw      = caps.self.metadata("chara")      -- CCv2 stores data in "chara" chunk
local ccv2     = json.decode(base64.decode(raw))
local name     = ccv2.data.name
local persona  = ccv2.data.description
```

CCv2 import is therefore free: the CCv2 card editor is a script that knows how to
read the `chara` chunk. The platform just provides package access.

The data capability is the abstraction layer. CCv2 fields are one implementation.
Crescent structured data is another. The script sees one API either way — whatever
the capability implementation returns from `caps.self.metadata(name)`.

## App internal routing

An app owns its entire UI — conversation, editor, lorebook editor, settings, all of
it. Navigation between views is internal to the app. The frontend handles client-side
routing; the backend handles API routing. Both live in the same tarball.

The shell has no knowledge of what views an app contains. It launches the app and the
app handles its own routing. An "edit this app" button in the shell just opens the
app — the app decides whether to show the editor first or the conversation first based
on context.

Format-specific tooling (CCv2 editor, lorebook editor) lives inside the app that
knows the format. The shell has no idea what CCv2 is and never will.

### CCv2 app internal views

A first-party CCv2-compatible app ships with these internal views:

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
    "db": "required",
    "self": "required"
  },
  "entry": {
    "server": {
      "main": "server.lua",
      "caps": {
        "http_server": { "type": "http_server", "required": true },
        "http_client": { "type": "http_client", "required": true },
        "time":        { "type": "time",        "required": true }
      }
    },
    "headless": {
      "main": "run/batch.lua",
      "caps": {
        "http_client": { "type": "http_client", "required": true },
        "fs":          { "type": "fs",          "required": false }
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

**The shell has no format knowledge.** It launches an app and the app handles its own
internal routing (conversation, editor, settings, etc.). An "edit" button in the shell
just opens the app — the app decides what to show.

**Filtering is a projectional editor.** The filter state is a `Signal<Query>` — a
structured value composed via widget combinators (`narrow`, `focus`, `each`), not a
text search box or flat tag list. The query widget lets users compose conditions
(`hair.color = "blonde" AND cup_size = "D"`). Results are
`computed(() => db.query(to_sql(query.get())))` — reactive, instant. Natural language
input ("blonde D cup") is the primary construction mechanism; the projectional view
is the inspector and tweaker.

## Backend for frontend (BFF)

Each app's backend exposes an HTTP API tailored to its frontend. The API is
domain-specific — a card app exposes endpoints like `POST /message` and `GET /card`,
not generic cap proxies. The frontend knows nothing about caps, LLM protocols, or
database schemas — it talks to its own backend.

The app provides a request handler function. The platform serves it via
`caps.http_server` — the app never binds a port or touches a socket. Static assets
are served from tarball entries via `caps.self`.

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
| Card editor / lorebook editor | Internal views inside each app's frontend |
| Preset browser | Script with `caps.fs` |

These ship alongside the platform as first-party scripts. They are not platform code.
They are replaceable, forkable, and auditable — and distributed the same way as any
other card.

### First-party apps

Three distinct apps compose the first-party experience:

**Card app** — the conversation/interaction app. The backend (Lua) owns context
assembly, macro substitution, lorebook triggering, LLM calls, and conversation
persistence. The frontend (HTML/CSS/JS) is a thin UI with zero business logic — it
renders messages, takes input, and calls backend endpoints. Vendors
`lib/formats/ccv2/` into the tarball for CCv2 format knowledge. Internal views:
conversation, card editor, lorebook editor, settings.

**Library app** — a general-purpose collection browser, configurable to show any
content type: character cards, Steam games, itch games, browser bookmarks, etc.
"Bookmarks" save the same app in different views — a character-focused bookmark
shows character-specific filters; a game-focused bookmark shows game metadata.
The library app has no format knowledge; it reads open metadata from adapters.

**Adapter apps** — format-specific import/export as separate apps. CCv2 import
reads a PNG/JSON card, extracts the `chara` chunk, and produces a crescent app
tarball (stamping the card app's script + the card's data). CCv2 export reverses
this — extracts card data and writes a standard CCv2 PNG. Import and export are
separate apps because their capability requirements differ (`caps.fs` + `caps.png`
for import; `caps.png` for export). Adapters vendor `lib/formats/ccv2/` for
format parsing.

### Vendoring format libraries

Format knowledge (`lib/formats/ccv2/`) is vendored into app tarballs — not loaded
from the host. This ensures the card's format parser travels with the card; sharing
a card shares the exact code that produced it. Host-side `lib.*` utilities
(`lib.json`, `lib.base64`, `lib.aho_corasick`) are available as fallback requires
since every crescent host ships them.

In the repo, format libraries live under `lib/formats/` for development and testing.
At build time they're copied into the app tarball. The app's `require` sees the
vendored copy first (tarball loader runs before host loader).

The platform owns exactly one thing: run a script with the capabilities the host
decides to grant.

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
