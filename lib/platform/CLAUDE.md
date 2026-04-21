# CLAUDE.md

Read `docs/platform-design.md` before making any changes here.

## Load-bearing invariants

**The platform owns exactly one thing**: run a script in a sandbox with the caps the
operator granted. No format knowledge, no LLM knowledge, no card/library/import logic
in the platform. Those are apps. If you're tempted to add domain logic here, stop —
it belongs in an app.

**No default app.** Running the platform with no arguments is an error. The shell is
an app like any other.

## App format

A gzipped tar archive with `manifest.json` + Lua + static assets. Distributable as
raw `.tar.gz` OR embedded in PNG/JPEG/WebP (image is optional decoration; app IS the
tarball). PNG uses `lua` iTXt chunk = `base64(gzip(tar))`. Optional `lua-manifest`
iTXt chunk is **authoritative** when present (fast path; tools updating manifest must
keep both in sync).

App file is canonical — no "installed form." Import = copy file into
`~/.crescent/apps/` + upsert into SQLite index. Launch reads directly from the file.

`require` resolution inside an app: tarball root first, then host `lib.*` fallback.
First-party apps vendor everything under `lib/` in the tarball (symlinked to canonical
sources in the monorepo; `tar -h` dereferences).

## Sandbox is the security boundary

The sandbox env has no `io`, `os`, `ffi`, `debug`, `dofile`, `loadfile`, `package`, or
host `require`. Caps are the only side-effect surface.

**Module loading inside sandbox** (`lib/sandbox` require):
1. Check sandbox-local `package.loaded`.
2. Tarball lookup → `load(source, "t", env)`.
3. Whitelist → `package.searchpath` → `load(source, "t", env)`.
4. Else error.

All loaded modules run in the sandbox env. "Vetted platform code" is NOT a security
property — any module with host privileges is an escape.

**`load()` mode is `"t"` only.** Bytecode rejected.

**`caps` is entrypoint-only.** Modules loaded via sandbox `require` get an env
WITHOUT `caps`. The entrypoint passes caps to internal modules as explicit
parameters — caps-first discipline applies inside the app too.

**Lock the shared string metatable** before running sandboxed code:
`getmetatable("").__metatable = false`. Otherwise the app can mutate it and attack
the host. `getmetatable` stays available in sandbox (needed for normal Lua).

## FFI is never a capability

`ffi` is the ABSENCE of a sandbox, not a cap. Never on any whitelist, never grantable.
FFI-backed functionality goes through the cap system — declared in manifest, granted
by operator, injected as `caps.ffi_*`. App calls `caps.ffi_compress(data)`, never
`require("lib.compress")` for FFI code.

## Cap taxonomy

- **Primitive caps** — external read/write surfaces (`http_client`, `http_server`,
  `db`, `shared_db`, `kv`, `llm`, `fs`, `time`, `cli`, `stdin`, `stdout`, `self`).
  Carry the security weight.
- **FFI caps** — `ffi_`-prefixed. Pure Lua libs are NOT caps; vendor them in the
  tarball instead. Caps exist only for things that cannot be sandboxable pure Lua.

The cap system is NOT a general module injection mechanism.

## Caps are plain tables with closures

No metatables on anything the app can reach. Closure upvalues are unreachable without
`debug` (excluded). Each cap function checks a `revoked` flag at top and returns
`nil, "capability revoked"` — revocation is a boolean, no proxies.

Cap factory returns `(cap_table, revoke_fn)`. Platform keeps `revoke`, app gets `cap`.

## Permissions model

Each named cap is grant-or-deny, no partial grants. Granularity comes from declaring
multiple named caps of the same type (e.g. two `http_client` caps with different
hosts). `required: true` → platform refuses to launch if denied. `required: false` →
app must handle nil.

**Grants persist per-app.** `--reset-grants` re-prompts.

**Configurable caps.** `configurable_fields` in manifest = UI hint for operator-varying
fields (e.g. `fs` root path). Overrides stored in `app_cap_config` table, shallow-merged
onto manifest at construction, validated against cap type schema (unknown field name =
error, type mismatch = error, never silent fallback). `sensitive_fields` = UI masking
hint (currently no storage difference).

## Scopes

Storage caps (`kv`, `db`) take `scope` = subset of context dimensions (currently
`{user, app}`). Default `["user", "app"]` = fully isolated. Removing a dimension
widens access and requires operator approval. Adding new dimensions later is just
adding to the set — no hierarchy.

## Apps are cheap — prefer a new app over a new abstraction

For `lib/platform/` apps specifically: new data layout / format variant / legacy
compat target → new app, NOT a pluggable-backend interface in an existing app. Apps
install/update/fail/delete independently. Shared code = vendored libs. "One universal
app with adapters" anchors canonical apps to legacy and forces the core to design
around every variant.

This rule is platform-app specific. At the `lib/` package level the usual
composability rules apply (don't gratuitously split).

## Script / data / frontend separation

- **Script (backend)**: pure Lua logic, reads inputs via caps, exposes BFF HTTP API.
- **Data**: `caps.self.metadata(chunk)` — raw bytes; format parsing is the app's job.
- **Frontend**: static HTML/CSS/JS in tarball entries, served via `caps.http_server`.
  Zero business logic — renders what backend says, posts user actions back.

Editors never writeback into script source. Tooling that modifies script text is
out of scope.

## Easy mistakes to avoid

- Don't add format knowledge (CCv2, charx, etc.) anywhere under `lib/platform/`. It
  lives in apps or in `lib/formats/`.
- Don't make `caps` visible to sandbox-loaded modules.
- Don't let caps carry metatables the app can reach.
- Don't add `ffi` to any whitelist, ever.
- Don't build "one configurable app" — build N apps sharing vendored libs.
- Don't silently fall back when a cap config override fails validation — error with
  field name and expected type.
- Don't assume the app directory layout: tarball root is the namespace; host `lib.*`
  is fallback only.
- Don't let the admin app execute grant changes directly. Daemon retains final
  authority; admin app is frontend only.
