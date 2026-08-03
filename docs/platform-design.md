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

### Layering: platform carriers vs app data

When an app is distributed as an image (PNG/JPEG/WebP), the image's metadata
chunks are divided across two distinct layers:

- **Platform layer** — `lua` iTXt chunk (base64(gzip(tarball))), `lua-manifest`
  iTXt chunk (raw manifest JSON as a fast-path read). These belong to the
  platform. Their presence and semantics are platform concerns. Every app
  distributed as an image uses these chunks regardless of what domain it
  operates in.
- **App layer** — chunks whose names and contents are defined by whatever
  format the app operates on (e.g. `chara` for a CCv2-aware app, `exif` for
  an image-metadata app). The platform treats these as opaque passthrough
  data.

**Platform payload never goes inside an app-format chunk.** Embedding the
platform tarball inside `chara.extensions.*` or any other app-layer namespace
inverts the layering — it makes the platform an extension of that one app
format instead of the other way around. The `lua` / `lua-manifest` chunks
are the right carrier: platform-scoped, app-format-agnostic, compatible
with any image app regardless of what else lives in the file.

### No "crescent format"

Crescent has no card format, no document format, no format at all. The
platform carries whatever formats the apps bring. The ccv2 app extends
CCv2 via `chara.extensions.*`, but those extensions are ccv2-app-scoped —
they're not a "crescent card format". A different image-handling app
could use entirely different chunks and formats. Apps innovate on format;
the platform does not.

When someone says "a crescent card" they are talking about a CCv2 card
that happens to be played by the ccv2 app. The crescent platform does
not endorse or require that specific pairing.

### Misframings to avoid

Past sessions have repeatedly reached for these wrong patterns. The answer
to each is "no, that's not what's happening":

- **"Crescent-format card."** Does not exist. There are crescent *apps*.
  A CCv2 card PNG with a crescent app embedded is a crescent app (which
  happens to contain CCv2 data). There is no separate "crescent format"
  to convert to or validate against. Stop reaching for this term.

- **"Tarball apps vs image-carried apps."** Not two schemes. A crescent
  app *is* a tarball; the `lua` iTXt chunk of a PNG-carried app *is*
  that tarball (base64'd). The image is an optional wrapper around the
  same bytes. Whatever is true of "tarball apps" is true of
  "image-carried apps" too, because they are the same object.

- **"The host's canonical version of the app vs the card's embedded
  copy."** No such canonical relationship. Each PNG's embedded runtime
  IS the app when that PNG is launched. The host's installed apps are
  peers. There is no "stale embedded vs fresh host" to arbitrate; the
  embedded tarball is the source of truth for its own PNG, period. Any
  version upgrade would have to be applied per-PNG (e.g. re-import).

- **"Pure CCv2 export" / "strip crescent extensions before sharing."**
  Pointless. The embedded app and `chara.extensions.*` are additive;
  the underlying `chara` CCv2 data is never altered. Plain CCv2 tools
  already read the card correctly. Nothing to strip.

- **"The app is a fallback if the host doesn't have one."** Inverted.
  The embedded app is the *primary* runtime for that PNG. The host's
  installed apps are for hosts that are also running *other* PNGs.

- **"Self-containment is a size tradeoff."** No. Self-containment is
  non-negotiable. Size is not a constraint that can override it; hosts
  (Chub 25MB+, catbox, etc.) are well above any reasonable app tarball.

## Launching apps

```
luajit lib/platform/cli.lua <app> [entrypoint] [-- args...]
```

`<app>` is a path to anything the platform can extract — directory, PNG, JPEG, WebP,
tarball, tar.gz. The platform figures out the format and unpacks accordingly.

`[entrypoint]` selects which entrypoint from the manifest to run (e.g. `server`,
`headless`). If omitted, the platform uses the manifest's `default_entry` field.
If `default_entry` is absent (or doesn't match a key in `entry`), the platform
errors with a list of available entrypoints.

`[-- args...]` are passed through to the app's `cli` cap (if granted). Everything
after `--` is the app's business; the platform doesn't interpret it.

There are no app-specific CLI flags. The platform doesn't know or care what the app
needs for configuration. App config is the app's problem — it reads settings through
its own caps (kv, db, etc.) and renders its own setup UI if anything is missing.

**No default app.** Running the platform with no arguments is an error. The platform
is a runtime, not a shell. The shell is an app like any other.

**First-time config.** When an app launches and needs settings that don't exist yet
(e.g. no LLM endpoint configured), the app's own UI handles it — a settings page,
a setup wizard, whatever the app author builds. The platform stores config persistently
via kv/db caps so the user only configures once.

**Persistent grants.** Cap grants are persisted per-app so the operator isn't prompted
every launch. The platform stores which caps were granted/denied and reuses those
decisions on subsequent runs. A `--reset-grants` flag (or similar) clears stored
grants and re-prompts.

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
    "llm":           { "type": "llm",         "required": true },
    "local_llm":     { "type": "llm",         "required": false },
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
caps.llm, revoke_fns.llm                = llm_cap({ provider = "gemini", key = "my-gemini-key" })
-- caps.local_llm = nil (denied)
caps.conversations, revoke_fns.conversations = db_cap(db_path)
caps.settings, revoke_fns.settings       = kv_cap(kv_path)  -- scope: [user, app]
caps.user_prefs, revoke_fns.user_prefs   = kv_cap(user_prefs_path, { readonly = true })  -- scope: [user]
caps.clock, revoke_fns.clock             = time_cap()  -- app accesses as caps.clock.now()

sandbox.run(script, sandbox.env(sandbox.stdlib, { globals = { caps = caps } }))
```

### Configurable caps

Cap declarations in `manifest.json` are authored by the app developer and read-only
after install. But some fields must vary by deployment — an `fs` root pointing to
`~/SillyTavern/public/characters` is wrong for anyone who installed SillyTavern
elsewhere. Configurable caps let the operator override specific fields without
touching the manifest.

**Mechanism.** The manifest marks which fields are operator-configurable:

```json
"characters": {
  "type": "fs",
  "root": "~/SillyTavern/public/characters",
  "readonly": true,
  "configurable_fields": ["root"]
}
```

`configurable_fields` is a UI hint: these are the fields the grant UI surfaces as
"expected to vary per deployment." Operators can also override any other known field
for a cap type via CLI — they're not locked out of fields the author didn't list.
What they cannot do is override fields the cap type doesn't define (validation rejects
unknown field names).

**Storage.** Overrides live in the index DB, separate from the app manifest:

```sql
CREATE TABLE app_cap_config (
  app_id       INTEGER NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
  cap_name     TEXT    NOT NULL,
  overrides_json TEXT  NOT NULL DEFAULT '{}',
  PRIMARY KEY (app_id, cap_name)
);
```

One row per (app, cap_name). The value is a flat JSON object of field overrides.
No schema for the JSON — the platform's cap factory validates fields when
constructing the cap.

**Merge semantics.** At cap construction time the platform:
1. Takes the manifest cap declaration as the base.
2. Reads the stored `overrides_json` for this (app_id, cap_name).
3. Shallow-merges overrides on top (override values win).
4. Validates all resulting fields against the cap type's known schema.
5. If validation fails, construction fails with a clear error naming the bad field
   and expected type — no silent fallback to the manifest default.

**Validation policy.** "The operator should always know what went wrong." Errors are
surfaced at both set time (unknown field name for cap type) and construction time
(type mismatch). Never silently ignore a bad override.

**Sensitive fields.** Some cap fields are credentials or secrets (API tokens,
passwords). The manifest can flag them:

```json
"llm_api": {
  "type": "http_client",
  "host": "api.openai.com",
  "api_key": "",
  "configurable_fields": ["api_key"],
  "sensitive_fields": ["api_key"]
}
```

`sensitive_fields` is currently a UI hint only — masked display in the grant UI,
no behavioral difference in storage. Future: encrypted at rest in a separate
`app_cap_secrets` table. Passwords stored as hashes (bcrypt/argon2) are fine in
`overrides_json` since the hash is the credential, not the plaintext.

**Grant UI relationship.** Grant decisions (allow/deny per cap) and cap config
(field overrides) are stored in separate tables. The grant UI shows them together:
one panel per cap, with the allow/deny toggle and any configurable fields below it.

**CLI surface** (minimal, until the grant UI lands):

```
crescent caps <app_id>
    -- list all caps with current manifest values and stored overrides

crescent caps <app_id> <cap_name> <field>=<value>
    -- set one field override; validates immediately, errors with field name + type

crescent caps <app_id> <cap_name> --reset
    -- clear all overrides for this cap (revert to manifest defaults)
```

### Grant presets and install UX

**The problem**: approving every cap individually per-app install is decision fatigue.
Approving a bundle once is opaque. The right answer is both: the full cap list is always
visible, but a preset provides a named starting configuration so the operator isn't
configuring from scratch each time.

**Grant presets** are named bundles of cap configurations stored by the operator. A
preset says "for an LLM cap, use provider X with model Y and key Z; for db, use the
default path; etc." Installing an app = selecting a preset + one confirm click. The cap
list is always rendered below the preset selector at reduced visual weight — never hidden,
never demanding.

**Preset selection** at install time is driven by conditional rules, not by the manifest
alone. Rules are structured data (s-expression style), editable in the UI:

```
(and (tag "charactercardv2") (cap "llm"))  →  use preset "ccv2-default"
(cap "llm")                                →  use preset "llm-default"
```

Rules are evaluated in order; first match wins. The operator builds and edits rules in a
structured editor — no code required. The selected preset is a suggestion; the operator
can change it before confirming.

**Security**: auto-selection is configuration convenience, not automatic approval. The
operator still explicitly confirms each install. The preset reduces configuration work,
not the approval step.

---

### `llm` cap — language model access

Apps that call language models declare `{ "type": "llm" }`. This is distinct from
`http_client` — it carries semantic meaning (the user is granting LLM access, not
arbitrary HTTP access) and enables provider-level abstraction.

**Provider drivers** live in `lib/platform/providers/`. Each driver knows the native API
for one provider (Gemini, Anthropic, OpenAI, etc.) and translates the standard `llm` cap
interface to the provider's wire format. OAI-compat shims are not used for providers that
have better native APIs.

**Interface** (what the app sees — no provider details):
```lua
caps.llm.call(messages, opts?)           -- returns content_string | nil, err
caps.llm.call_stream(messages, on_token, opts?)  -- streams tokens
caps.llm.count_tokens(text)              -- returns integer
```

**Key management**: API keys are stored in the platform keyring (`lib/keyring/`) by
user-assigned name (e.g. `"my-gemini-key"`), not by host pattern. The `llm` cap is
configured at grant time with a provider + named key. The app never accesses the keyring
directly — the platform reads the key and injects a pre-keyed client. Multiple keys per
provider are supported (one per named entry).

**Manifest declaration** — app declares intent only, no provider coupling:
```json
"llm": { "type": "llm", "required": true }
```

The operator selects provider + key when granting (typically via a preset). The app is
fully provider-agnostic.

---

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

### `caps.self_write` — writable app metadata

Read/write variant. Declared as a **separate named cap** (type `self`,
`writable: true`), not a flag on the read cap. This follows the cap-taxonomy rule
that each named cap is grant-or-deny with no partial grants — splitting read and
write into two caps lets the operator grant read while denying write.

```lua
caps.self_write.metadata(keyword)              -- same as caps.self.metadata
caps.self_write.entries()                      -- same as caps.self.entries
caps.self_write.entry(path)                    -- same as caps.self.entry
caps.self_write.write_metadata(keyword, bytes) -- write/replace image chunk
```

`write_metadata` is **atomic**: write to a temp file in the same directory, fsync,
rename. Partial writes cannot corrupt the app file. Errors if the app is
tar-only (no image container) — `write_metadata` is image-container-only. If the
format requires auxiliary chunks to stay in sync (e.g. the `lua-manifest` chunk
is authoritative when present), the cap updates those atomically alongside.

Use case: apps that want to persist state **inside the app file itself** so
sharing the file shares the state. See the `card-app-design.md` self-containment
rule for when this matters.

Convention: name the read cap `self` and the write cap `self_write`. Apps that
need write declare both; apps that only read declare just `self`.

### `caps.http_server` — inbound HTTP

The platform binds the port and owns the socket. The app provides a request handler.

The cap must support streaming responses (SSE) without giving the app raw socket
access. The app also needs to know its own URL (e.g. to open a browser).

**WARNING — unsandboxed browser JS.** Granting `http_server` lets the app serve
arbitrary HTML/JS to the user's browser at the app's own origin. That JS runs
**unsandboxed** with full webpage privileges (fetch within CSP, keystroke /
clipboard access for its own page, deceptive UI construction, etc.). The
platform's cap system does **not** mediate what the served JS does — it only
controls whether the app can serve at all. This is a structural gap, not a bug:
the browser is a separate execution environment outside the daemon-side sandbox.
The forthcoming `web_runtime` cap is the sandboxed alternative for apps that
just need browser UI; `http_server` should be reserved for apps that
legitimately need to expose an HTTP endpoint for external tools.

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

### `caps.shared_db` — shared SQLite database

A SQLite connection with per-app view isolation. Multiple apps access the same
underlying tables, but each app sees only its own rows via `_app_id()` filtering.
The platform registers an authorizer that blocks direct access to `_`-prefixed
base tables, DDL, and ATTACH — the app queries clean view names instead.

```lua
-- manifest declares shared_db with table list:
-- { "type": "shared_db", "tables": ["sessions", "messages"], "required": true }

cap.execute(sql)           -- true | nil, err (not present in readonly mode)
cap.query(sql, params?)    -- rows | nil, err
cap.close()                -- nil
```

The host calls `setup_schema()` to create base tables (`_sessions`), views
(`sessions`), and INSTEAD OF triggers that enforce `app_id` on every write.

#### Schema conflict detection

Apps vendor their own schema (e.g. `lib/conversation` vendored into the tarball) and
call `setup_schema()` on first run. Multiple apps can share the same `shared_db` tables
by convention — all ccv2 cards vendor the same `lib/conversation` and produce identical
DDL.

On launch, before running the entrypoint, the platform reads the existing DDL from
`sqlite_master` for each table the app declares and string-compares it against the DDL
the app would create. If they differ, the platform errors loudly rather than silently
corrupting data.

No version numbers, no parsing. `sqlite_master` gives the canonical DDL string; a string
compare is sufficient because DDL is generated from the same source. Matching DDL → safe
to share. Differing DDL → incompatible apps, operator must resolve before launch.

#### Schema input to `setup_schema()`

Apps pass DDL as raw SQL strings. SQL strings are the ground truth — structured
definitions, schema files, and type-safe builders all compile down to SQL anyway. A
structured definition layer is optional and app-level; the primitive the platform
accepts is always the string.

#### `setup()` method

The cap exposes a `setup(tables)` method the app calls once on first run to
initialize its schema:

```lua
caps.conversations.setup({
  { name = "sessions",  cols = "id TEXT PRIMARY KEY, created_at INTEGER NOT NULL, metadata TEXT" },
  { name = "messages",  cols = "id TEXT PRIMARY KEY, session_id TEXT NOT NULL, content TEXT NOT NULL" },
})
```

`tables` is an array of `{name, cols}`. `cols` is raw SQL column definitions —
the same primitive accepted by `setup_schema()`. Type-safe schema builders are
an app-level concern and compile down to this string.

`setup()` is one-shot: calling it more than once on the same cap instance errors
immediately. A `boolean` upvalue in the cap closure tracks whether it has fired;
once set, all subsequent calls return `nil, "setup() already called"`. This
prevents accidental re-initialization without adding any external state.

Platform-installed (operator-trusted) apps are implicitly trusted to call
`setup()` correctly. The authorizer still enforces row-level isolation on every
query regardless — trust in schema setup does not widen data access.

Schema conflict detection (string compare against `sqlite_master`) runs as part
of `setup()`. If the existing DDL for a table doesn't match what the app would
create, `setup()` errors loudly before touching any data. This is the same
check described above; `setup()` is the call site where it fires.

### `caps.time` — clock

```lua
caps.time.now()  -- returns Unix timestamp (integer) | nil, "capability revoked"
```

### `caps.fs` (optional) — file access

Scoped to a directory via `root` in the manifest declaration. All paths are
relative to `root`; path traversal (`../`, absolute paths) is blocked at the
cap level.

Permission is granular per operation, all independent `allow_*` booleans on
the manifest declaration. Read-side operations (`read`/`list`/`list_recursive`/
`stat`) default to granted; mutating operations (`write`/`mkdir`/`delete`/
`rename`) default to denied, same as `write` always has:

```lua
caps.my_fs.read(path)                 -- string | nil, err
caps.my_fs.write(path, content)       -- true | nil, err            (only if allow_write)
caps.my_fs.list(path?)                -- string[] | nil, err        (filenames, not full paths)
caps.my_fs.list_recursive(path?)      -- string[] | nil, err        (paths relative to `path`, "/"-separated,
                                       --   covers files and directories at every depth)
caps.my_fs.stat(path)                 -- { size, mtime, type: "file" | "directory" } | nil, err
caps.my_fs.mkdir(path)                -- true | nil, err            (only if allow_mkdir)
caps.my_fs.delete(path, opts?)        -- true | nil, err            (only if allow_delete;
                                       --   opts.recursive = true required to remove a non-empty directory)
caps.my_fs.rename(path_from, path_to) -- true | nil, err            (only if allow_rename; move within root)
```

`attenuate({ root, allow_read?, allow_write?, allow_list?, allow_list_recursive?,
allow_stat?, allow_mkdir?, allow_delete?, allow_rename? })` narrows a cap to a
subdirectory and/or a subset of its operations. Narrow-only: it can drop any
of the eight flags the parent holds, never grant one the parent lacks.

### `caps.cli` — command-line arguments

The app's portion of `arg` (everything after `--` on the command line). Grant/deny
controls whether the app can read CLI arguments at all. The value is a plain table
of strings.

### `caps.stdin` — standard input

Read access to the process's stdin. Grant/deny only.

### `caps.stdout` — standard output

Write access to the process's stdout. Grant/deny only. Separate from `http_server`
— a headless entrypoint might write to stdout without serving HTTP.

## Sandbox security

The sandbox is the security boundary. An app runs in a restricted Lua environment
with no access to `io`, `os`, `ffi`, `debug`, `dofile`, `loadfile`, `require`
(replaced with a whitelist loader), or `package`. Capabilities are the only way to
perform side effects.

**Module loading inside the sandbox.** The sandbox `require` never calls the host
`require`. For every module name:

1. Check sandbox-local `package.loaded` cache.
2. Tarball lookup → if found, load source with `load(source, "t", env)`.
3. Whitelist check → `package.searchpath` → read source → `load(source, "t", env)`.
4. Error if not found or not whitelisted.

All module code runs inside the sandbox env — their `require` calls also go through
the whitelist. "Vetted platform code" is not a security property; any module running
with host privileges is a potential sandbox escape.

**`caps` is entrypoint-only.** The `caps` global is present only in the entrypoint's
env. Modules loaded via `require` inside the sandbox receive an env without `caps`.
The entrypoint passes specific capabilities to internal modules explicitly as
constructor arguments or function parameters — the same caps-first discipline that
applies at the platform boundary applies within the app. This prevents caps from
leaking into arbitrary module scope.

**FFI is never grantable.** `ffi` is not a capability — it is the absence of a
sandbox. It must never appear on any whitelist. FFI-backed functionality is exposed
through the cap system only: declared in the app manifest, explicitly granted by the
platform, injected as `caps.*` globals in the entrypoint. The app calls
`caps.ffi_compress(data)`, not `require("lib.compress")`.

**Cap taxonomy.** Caps fall into two categories:

- **Primitive caps** — external read/write surfaces: `http_client`, `db`, `llm`, `fs`,
  `time`, etc. These carry the primary security weight: network access, disk access,
  LLM calls. Always require explicit grants.
- **FFI caps** — computational libraries that require native code and cannot run as
  sandboxed pure Lua source. Named with the `ffi_` prefix: `ffi_compress`, `ffi_regex`,
  etc. Pure Lua libraries do not need to be caps — vendor them into the tarball instead.

The cap system is not a general module injection mechanism. It exists for things that
cannot be expressed as sandboxable pure Lua source.

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
  reads data through `caps.self.metadata("chara")` (or whatever chunk it declares).

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
├── chara          (tEXt — base64 JSON, CCv2 format, untouched — if also a CCv2 card)
├── lua-manifest   (iTXt — raw JSON, the manifest only — fast access shortcut)
└── lua            (iTXt — base64(gzip(tar)))
    ├── manifest.json
    ├── (arbitrary .lua files and assets)
    └── ...
```

The `lua-manifest` chunk, when present, is **authoritative** — it takes priority
over `manifest.json` inside the tarball. This is necessary: if we read it first as
a fast path, we must trust it. Tools that update the manifest must update
`lua-manifest` (and keep the tarball's copy in sync). `lua-manifest` is optional —
when absent, the platform falls back to unpacking the tarball.

For raw tarballs (`.tar.gz`), there is no `lua-manifest` shortcut — the manifest
is read from inside the tarball.

### App import and indexing

The app file (PNG, tar.gz, etc.) is the canonical representation. There is no
"installed form" — the platform reads directly from the source file on launch.

**Import** is lightweight: copy the file into the app directory (`~/.crescent/apps/`),
extract the manifest (from `lua-manifest` chunk if available, otherwise from the
tarball), and upsert into an index database. No extraction or format conversion.

**Index database.** The library shell maintains a SQLite index of installed apps —
manifest fields stored for fast `json_extract` queries. This enables filtering and
search over hundreds of apps without re-parsing every file. The index is rebuilt
on demand if it gets out of sync.

### Export

Export between container formats (PNG, tar.gz, directory, etc.) is an app — not a
platform operation. The platform is a runtime; it doesn't do anything besides run
scripts with caps. A format conversion app reads a file via `caps.fs`, repacks it,
and writes the output. The library shell or CLI can invoke it, but the logic lives
in an app like anything else.

```
platform run export.app headless -- myapp.tar.gz myapp.png
platform run export.app headless -- myapp.png myapp.tar.gz
platform run export.app headless -- myapp.png myapp/
platform run export.app headless -- myapp.png --format=tar.gz out
```

Format is inferred from the output path's extension (`.png`, `.jpg`, `.webp`,
`.tar.gz`, `.tar`, trailing `/` for directory). `--format` overrides when the
extension is ambiguous or missing.

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
  "default_entry": "server",
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
        "fs":          { "type": "fs",          "required": false },
        "cli":         { "type": "cli",         "required": false },
        "stdout":      { "type": "stdout",      "required": true }
      }
    }
  }
}
```

**`default_entry`** — names the entrypoint to use when none is specified on the
command line. Must match a key in `entry`. If absent and no entrypoint is specified,
the platform errors with a list of available entrypoints.

**Capability declarations:**

- Top-level `caps` declares caps shared across all entrypoints (e.g. `db` above).
  Shorthand is supported: `"db": "required"` is equivalent to
  `"db": { "type": "db", "required": true }`. `"db": "optional"` sets
  `required: false`. When using shorthand, the cap name IS the type.
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
| Import/export between formats | App with `caps.fs` (container packing) |
| Card editor / lorebook editor | Internal views inside each app's frontend |
| Preset browser | Script with `caps.fs` |

These ship alongside the platform as first-party scripts. They are not platform code.
They are replaceable, forkable, and auditable — and distributed the same way as any
other card.

### Apps are cheap

When a new data layout, format variant, or use case appears, the default answer is
**a new app**, not a new abstraction inside an existing app. Apps in the `lib/platform/`
sense are structurally cheap: a directory, a `manifest.json`, some Lua, optional static
assets. They install independently, update independently, fail independently, and can
be deleted without touching anything else. Shared code lives in vendorable libraries
that any app requires like any other dep.

The alternative — one "universal" app with pluggable backends, configurable storage,
adapter interfaces, mode switches — is almost always wrong here. It forces the app to
design an abstraction over things the abstraction doesn't simplify, grows a settings
surface for choosing between modes, and entangles the core code with every supported
variant so that none of them can evolve freely. When the variant is foreign (legacy
format, third-party data store, external launcher) the entanglement also anchors the
core to whatever it's being compatible with, which is exactly the "keep the legacy
slop around" failure mode we want to avoid.

Concrete examples where the answer is two apps, not one configurable app:

- **Native vs legacy card storage.** `charactercardv2` (crescent-native, clean data
  model) and a separate `sillytavern` app (reads and writes `~/SillyTavern/public/`
  directly). Shared UI lives in a vendored lib. The canonical app evolves freely; the
  ST app is deletable legacy support.
- **Different launchers.** Steam, itch, RPG Maker, Ren'Py, Godot, `.desktop` files —
  one app per source, each trivially hackable, each disposable.
- **Different card formats.** CCv2, KoboldAI, charx, loose-PNG-folder — one app per
  format. Users install only the ones they care about.

Cost of an app, measured honestly: a directory, a manifest, a few hundred lines of Lua,
plus vendored shared libs (~50 KB) and per-card data. The vendored code is duplicated
on disk at install time (see "Vendoring"), and at 23k installs that's a bit over 1 GB —
negligible next to the user's PNG corpus. There is no per-app runtime cost until it's
actually launched.

This principle is specific to `lib/platform/` apps (Lua packages with manifests + caps).
At the wider library level ("should this crescent library split into two packages?")
the usual composability rules apply — don't create gratuitous splits. The two domains
are different: an `lib/` package is a unit of code reuse; a platform app is a unit of
install, isolation, and user choice.

### First-party apps

First-party apps compose the initial experience:

**Character Card v2** (`charactercardv2`) — a CCv2-compatible conversation/interaction
app. The backend (Lua) owns context assembly, macro substitution, lorebook triggering,
LLM calls, and conversation persistence. The frontend (HTML/CSS/JS) is a thin UI with
zero business logic — it renders messages, takes input, and calls backend endpoints.
Vendors `lib/formats/ccv2/` into the tarball for CCv2 format knowledge. Internal views:
conversation, card editor, lorebook editor, settings. Entrypoints: `server` (baked-in
card, serves HTTP), `import` (stamp CCv2 data + self into distribution PNG).

**Library app** — a general-purpose collection browser, configurable to show any
content type: character cards, Steam games, itch games, browser bookmarks, etc.
"Bookmarks" save the same app in different views — a character-focused bookmark
shows character-specific filters; a game-focused bookmark shows game metadata.
The library app has no format knowledge; it reads open metadata from adapters.

**Format conversion app** — container format conversion (PNG ↔ tar.gz ↔ directory,
etc.) as an app with `caps.fs`. CCv2-specific data (the `chara` chunk) is the
card app's internal concern — format conversion only repacks containers, it doesn't
interpret card data. The library shell can invoke the format conversion app for
import (copy + repack + index) and export (repack to chosen container).

**Admin app** — manages the daemon: key storage, app installs, and presenting cap
grants to the operator. A single app with multiple entrypoints (`server` for the
HTTP admin UI, `headless` for scripted/agent use). Uses regular caps with write
access explicitly enabled — no special cap type:

- `keyring` cap (write) — store and delete named secrets under `crescent/<name>`
- `fs` cap pointing to the apps dir (write) — install and uninstall app bundles

Grant management (modifying what caps other apps receive) stays in the daemon
itself. An app that can modify other apps' grants could silently escalate its own
privileges — there is no principled constraint that prevents this without the daemon
retaining final authority. The admin app can surface grant options in its UI, but
the daemon approves and executes every grant change. The admin app is the frontend;
the daemon is the decision-maker.

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
