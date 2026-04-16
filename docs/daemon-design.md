# Platform Daemon Design

## Problem

The platform currently launches apps as one-shot CLI processes. Each app binds its
own HTTP port. Capability grants are prompted via CLI flags (`--grant`, `--deny`)
and persisted to JSON files. This works when the operator has terminal access.

It breaks when the operator accesses the platform remotely via browser — e.g.,
over Tailscale from a phone. There is no terminal to type `--grant=llm_api`. There
is no way to launch a second app from the first. There is no way to manage multiple
ports on mobile.

## Design goals

1. **Single port.** One HTTP port serves everything — library browser, grant UI,
   all running apps. No port juggling over Tailscale.
2. **Browser-native grants.** Capability consent happens in the browser, not the
   terminal. The operator sees what an app wants, approves or denies, and the app
   starts.
3. **Capability sandbox preserved.** Each app runs in its own sandbox with its own
   caps. The daemon is the trust boundary — apps never share caps, never access
   each other's state, and never bypass the grant flow.
4. **App lifecycle management.** The daemon starts and stops apps. A crashed app
   doesn't take down other apps or the daemon.
5. **No new dependencies.** Pure Lua + FFI, consistent with the rest of crescent.

## Architecture

```
┌─────────────────────────────────────────────┐
│                 Platform Daemon              │
│                (single process)              │
│                                             │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  │
│  │ Router   │  │ Grant UI │  │ App Mgr  │  │
│  │ /        │  │ /grant/* │  │          │  │
│  │ /app/:id │  │          │  │ start()  │  │
│  │ /api/*   │  │          │  │ stop()   │  │
│  └──────────┘  └──────────┘  └──────────┘  │
│       │                           │         │
│       │        ┌──────────────────┤         │
│       ▼        ▼                  ▼         │
│  ┌─────────┐ ┌─────────┐   ┌─────────┐    │
│  │ Library │ │ App "a"  │   │ App "b" │    │
│  │ (built  │ │ (sandboxed│   │(sandboxed│   │
│  │  in)    │ │  handler)│   │ handler)│    │
│  └─────────┘ └─────────┘   └─────────┘    │
└─────────────────────────────────────────────┘
```

### Single process, not multi-process

Apps run as **in-process sandboxed handlers**, not as child processes on separate
ports. Each app's `create(caps)` returns a `{ handler = fn(req, res) }` — the
daemon mounts that handler under `/app/<id>/`. This is the same contract apps
already implement for the BFF pattern.

Why not child processes:
- Port management is complexity for no security gain (the sandbox is the boundary)
- Child process lifecycle is OS-specific and fragile
- Reverse-proxying adds latency and failure modes
- In-process handlers share no state — each gets its own `caps` table

The daemon IS the platform. It replaces `lib/platform/cli.lua` for the
browser-access use case. The CLI remains for terminal-only workflows.

### Router

The daemon's HTTP server dispatches by path prefix:

| Path | Handler | Description |
|------|---------|-------------|
| `/` | Library app | Built-in app browser |
| `/api/daemon/*` | Daemon API | App lifecycle, grant management |
| `/grant/:app_id` | Grant UI | Capability consent page |
| `/app/:app_id/*` | App handler | Proxied to sandboxed app handler |

The library app is not a launched app — it's built into the daemon. It queries the
index DB directly (no cap indirection needed for the launcher itself).

### Grant flow

```
User clicks "Launch" in library
        │
        ▼
POST /api/daemon/launch { app_id: "alice" }
        │
        ▼
Daemon reads manifest, checks stored grants
        │
        ├── All caps decided? ──▶ Start app, redirect to /app/alice/
        │
        └── Undecided caps? ──▶ Redirect to /grant/alice
                                      │
                                      ▼
                              Browser shows grant page:
                              "Alice wants:
                               ✅ LLM API (http_client) — api.openai.com
                               ✅ Conversation storage (db)
                               ⬜ File system (fs) — optional
                               [Allow selected] [Deny all]"
                                      │
                                      ▼
                              POST /api/daemon/grant
                              { app_id: "alice", grants: { llm_api: true, ... } }
                                      │
                                      ▼
                              Daemon persists grants, starts app,
                              redirects to /app/alice/
```

Grant decisions are persisted to the same `grants.json` files the CLI uses.
A grant made in the browser works if the app is later launched from the CLI,
and vice versa.

### App lifecycle

**Launch:**
1. Daemon loads app (PNG or directory, same as `platform.load_app`)
2. Reads manifest, resolves entry point
3. Checks grant state — redirect to grant UI if needed
4. Calls `construct_caps()` with granted capabilities
5. Calls `entry_mod.create(caps)` → gets `{ handler = fn }`
6. Mounts handler at `/app/<app_id>/`
7. Returns app URL to browser

**Request routing:**
- Request to `/app/alice/api/messages` → strip prefix → `alice.handler({ path = "/api/messages", ... })`
- App sees paths relative to its own root, unaware of the daemon's mount point
- App's static files (HTML, JS, CSS) served via the same handler

**Stop:**
- `POST /api/daemon/stop { app_id: "alice" }`
- Daemon calls revocation closures for all caps
- Removes handler from router
- App's in-flight requests get `503`

**Crash isolation:**
- Each app handler runs in a `pcall`. If it errors, the daemon logs the error
  and returns `500` to the browser — other apps and the daemon are unaffected.
- Persistent crashes can trigger auto-stop with a UI notification.

### Path rewriting

Apps expect to be served at `/`. The daemon mounts them at `/app/<id>/`. This
requires rewriting:

- **Incoming requests:** Strip `/app/<id>` prefix before passing to handler
- **Outgoing HTML:** Not rewritten. Instead, apps use relative paths (`./api/foo`,
  `./style.css`), which the browser resolves correctly against the current URL.
  This is already the convention — `app.js` uses `fetch("/api/apps")` etc.

Wait — existing apps use absolute paths like `/api/apps`. This won't work under
a prefix mount. Two options:

1. **Apps use relative paths.** Change `fetch("/api/apps")` to `fetch("api/apps")`
   (no leading slash). The browser resolves relative to the current page URL.
   Requires the mounted path to end with `/` (i.e., `/app/alice/` not `/app/alice`).

2. **Inject a `<base>` tag.** The daemon rewrites the HTML `<head>` to include
   `<base href="/app/alice/">`. All relative URLs resolve against that base.
   More fragile, but apps don't need to change.

**Decision: option 1 (relative paths).** It's explicit, no magic rewriting, and
works identically in standalone mode (served at `/`) and daemon mode (served at
`/app/id/`). Apps should already avoid absolute paths — it's the portable default.

### Daemon API

```
POST /api/daemon/launch   { app_id }           → { url } | { redirect: grant_url }
POST /api/daemon/stop     { app_id }           → { ok }
POST /api/daemon/grant    { app_id, grants }   → { url } | { error }
GET  /api/daemon/apps                          → { apps: [...] }  (running apps)
GET  /api/daemon/status                        → { uptime, apps_running, ... }
POST /api/daemon/revoke   { app_id, cap_name } → { ok }
```

### Security considerations

**The daemon is the operator.** It makes grant decisions on behalf of the human.
The grant UI must clearly communicate what each cap allows — not just `"http_client"`
but `"HTTP access to api.openai.com"`.

**No app can launch another app.** Only the daemon API (triggered by the human via
the library UI) can start apps. An app has no cap to call `/api/daemon/launch`.

**No app can access another app's routes.** The daemon checks the `Origin`/`Referer`
header (or uses per-app CSRF tokens) to prevent cross-app request forgery. App "alice"
cannot `fetch("/app/bob/api/secrets")` from its frontend JS.

**Grant UI must not be frameable.** The grant page sets `X-Frame-Options: DENY` to
prevent clickjacking by a malicious app that iframes the grant UI.

**Cap display names.** The grant UI needs human-readable descriptions of each cap
type. These come from the cap type modules, not from the app's manifest (which the
app could lie about).

## What this replaces

- `lib/platform/cli.lua` launch flow → daemon handles it
- CLI grant prompting → browser grant UI
- Per-app port binding → single daemon port with path routing
- No app lifecycle management → daemon tracks running apps

The CLI still works for terminal use. The daemon is an alternative entry point,
not a replacement. Both use the same grant storage, cap factories, and sandbox.

## Open questions

1. **Authentication.** The daemon serves on a network port. Over Tailscale this is
   fine (Tailscale handles auth). On a LAN or public network, the daemon needs its
   own auth. Options: HTTP basic auth, bearer token, Tailscale identity headers.
   For v1, assume Tailscale (no auth needed).

2. **Concurrent requests.** LuaJIT is single-threaded. If app A's handler blocks
   (e.g., waiting on an LLM response), app B's requests queue behind it. Options:
   coroutine-based async (apps yield during I/O), fork per app (loses in-process
   simplicity), or accept the limitation for v1 (most apps are fast handlers +
   SSE streams). Coroutine async is the likely eventual answer — it's how the
   HTTP server already works for SSE.

3. **Hot reload.** Can the daemon reload an app without restarting? Lua's module
   system makes this possible (`package.loaded[mod] = nil` + re-require), but cap
   state (open DB connections, etc.) needs cleanup. Useful for development but not
   critical for v1.

4. **Multiple instances.** Can two users launch the same app with separate state?
   Yes — the app_id can include a session suffix (`alice-session1`), and
   `_resolve_data_path` already scopes storage per app_id. The grant UI would need
   to distinguish "same app, different session" from "different app."

## Implementation order

1. **Daemon skeleton** — HTTP server on one port, router dispatching by path prefix
2. **Library app integration** — mount at `/`, serve from index DB
3. **App launch** — load app, construct caps, mount handler at `/app/<id>/`
4. **Grant UI** — HTML page listing caps, POST to persist and launch
5. **Path rewriting** — strip prefix on incoming, verify relative paths work
6. **Lifecycle API** — stop, status, revoke
7. **Cross-app isolation** — CSRF protection, frame busting
