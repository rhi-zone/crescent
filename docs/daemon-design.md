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

### Browser approve flow (concrete mechanics)

The grant flow is a redirect chain. Every step is stateless on the wire and
backed by the daemon's internal grant store and a short-lived launch-token map.

**Step 1: Launch request.**

User clicks an app in the library. Library JS sends:

```http
POST /api/daemon/launch
Content-Type: application/json
X-CSRF-Token: <session-csrf>

{ "app_id": "alice" }
```

Daemon loads the manifest, merges with stored grants in `~/.crescent/data/alice/grants.json`,
checks admin policy. Three possible outcomes:

1. **All required caps granted, no policy conflict:** daemon starts the app if
   not running, returns `{ "url": "/app/alice/" }`. Library JS redirects.
2. **Undecided caps (or manifest has new caps since last launch):** daemon
   mints a **launch token**, returns `{ "redirect": "/grant/alice?t=<token>" }`.
3. **Admin policy blocks a required cap:** daemon returns
   `{ "error": "policy_denied", "cap": "fs", "reason": "..." }`. Library shows
   an inline message; app does not start.

The launch token is a 16-byte random string stored in a server-side map:

```lua
launch_tokens[token] = {
  app_id = "alice",
  operator = session_id,       -- who initiated; checked on submit
  created_at = os.time(),
  expires_at = os.time() + 300,  -- 5 min
  undecided = { "llm_api", "conversations", "fs" },  -- snapshot at launch
}
```

Tokens are one-shot — consumed on grant submission — and expire if unused.

**Step 2: Grant UI.**

Browser GETs `/grant/alice?t=<token>`. Daemon:

1. Validates the token: exists, not expired, matches the session operator
2. Loads the app's manifest
3. Renders HTML with one form, no JavaScript needed

Response headers:
```
Content-Type: text/html; charset=utf-8
X-Frame-Options: DENY
Content-Security-Policy: default-src 'self'; frame-ancestors 'none'; form-action 'self'
Cache-Control: no-store
```

Page content (sketch):

```
┌──────────────────────────────────────────────┐
│  Alice wants to run                          │
│  ─────────────────                           │
│  Version 0.1.0                               │
│  Tags: charactercardv2, ai, llm, roleplay    │
│                                              │
│  Alice says:                                 │
│  "A friendly AI assistant for brainstorming" │
│                                              │
│  ─────────────────────────────────           │
│                                              │
│  Required capabilities                       │
│                                              │
│  ☐ Network access to api.openai.com          │
│     Anything Alice processes can be sent     │
│     to api.openai.com. Once sent, that data  │
│     is outside your control.                 │
│     [ Alice: "used for chat responses" ]     │
│                                              │
│  ☐ Private database (conversations)          │
│     Alice stores your messages in her own    │
│     isolated database. Other apps cannot     │
│     read it.                                 │
│                                              │
│  Optional capabilities                       │
│                                              │
│  ☐ File system: ~/Documents/alice/           │
│     Alice can read and write any file        │
│     under ~/Documents/alice/.                │
│                                              │
│  ─────────────────────────────────           │
│                                              │
│  [ Deny all ]   [ Allow selected ]           │
└──────────────────────────────────────────────┘
```

Details:
- **Deny is the primary button** (left, default focus, larger), allow is secondary
- Checkboxes default **unchecked**. No pre-selection.
- Required caps — if the user denies any required cap, the submit error-outs
  with "this app cannot run without X" and offers to go back to deny all or
  approve the required ones
- App's self-declared reason shown in brackets, visually marked as
  app-controlled text so operators don't confuse it with the platform's
  authoritative disclosure
- Risk descriptions come from the cap factory, not the manifest

Form:

```html
<form method="POST" action="/grant/alice">
  <input type="hidden" name="t" value="<token>">
  <input type="hidden" name="csrf" value="<session-csrf>">

  <input type="checkbox" name="allow" value="llm_api" id="cap-llm_api">
  <input type="checkbox" name="allow" value="conversations" id="cap-conv">
  <input type="checkbox" name="allow" value="fs" id="cap-fs">

  <button type="submit" name="decision" value="deny">Deny all</button>
  <button type="submit" name="decision" value="allow">Allow selected</button>
</form>
```

**Step 3: Grant submission.**

```http
POST /grant/alice
Content-Type: application/x-www-form-urlencoded

t=<token>&csrf=<csrf>&decision=allow&allow=llm_api&allow=conversations
```

Daemon:

1. Validates CSRF token against the session
2. Validates launch token: exists, not expired, operator matches
3. **Consumes** the launch token (delete from map, even on failure — one-shot)
4. If `decision=deny`: record `false` for every undecided cap, return error page
   "Alice was not allowed to start. [Back to library]"
5. If `decision=allow`:
   - For each undecided cap, record `true` if in the `allow[]` list, else `false`
   - Persist the updated `grants.json` atomically (temp file + rename)
   - Check admin policy again (defense in depth)
   - Construct caps, call `entry_mod.create(caps)`, mount handler
   - 303 redirect to `/app/alice/`

If any required cap ends up denied, construction fails, rollback, redirect to
an error page explaining which required cap was missing.

**Step 4: First request to the app.**

Browser follows the 303 to `GET /app/alice/`. Daemon router matches the prefix,
strips it, calls `alice.handler({ method = "GET", path = "/", ... })`. The app
responds with its HTML, which references relative paths that the browser
resolves under `/app/alice/`.

### Authentication

"Session" above assumes the daemon can identify the operator. Three supported
modes:

- **Tailscale mode (v1):** trust the connection. Tailscale handles auth at the
  network layer; the daemon reads a synthetic session id from the client IP. No
  login, no password.
- **Token mode:** operator configures a bearer token at setup (stored locally,
  required in `Authorization: Bearer <token>`). A login page sets a session
  cookie; subsequent requests use the cookie.
- **No-auth mode:** daemon binds to `127.0.0.1` only, trusts all local
  connections. For single-user development on a single machine.

Auth is orthogonal to the grant flow. The grant flow treats "the operator" as
an abstract principal — whichever auth mode is active maps to a session id.

### CSRF protection

Every HTML form and JSON API call includes a session-bound CSRF token:

- **Initial page load** sets a cookie `session=<sid>; SameSite=Strict; HttpOnly`
  and sends the matching CSRF token via a `<meta name="csrf" content="...">` tag
  (for JS) and a `<input type="hidden" name="csrf">` (for forms).
- **Library JS** reads the meta tag and attaches `X-CSRF-Token` to every
  fetch.
- **Daemon validates** that the CSRF header/field matches the cookie's session.
  Mismatch → 403.

`SameSite=Strict` alone would cover most cases, but CSRF tokens are belt-and-suspenders
and cost ~nothing.

### Revoke flow

The settings page `/settings` shows all apps with their granted caps:

```
Alice (running)
  ✓ llm_api (api.openai.com)  [Revoke]
  ✓ conversations (db)          [Revoke]
  [Stop app] [Stop & revoke all]

Bob (not running)
  ✓ kv                          [Revoke]
  [Launch] [Revoke all]
```

Revoke:
1. `POST /api/daemon/revoke { app_id, cap_name }`
2. Daemon calls the cap's revocation closure (sets `revoked = true`)
3. Updates `grants.json` to mark the cap denied
4. Next cap method call returns `nil, "capability revoked"`
5. App decides how to handle — typically shows an error to its user

Revoking a required cap effectively kills the app but the process keeps running
until the operator stops it explicitly. Apps should handle revocation of
required caps by surfacing an error, not crashing.

### Edge cases

**Launch a running app:** daemon returns `{ url: "/app/alice/" }` immediately,
no grant flow. The app is already sandboxed with its prior caps.

**Manifest changed since last launch:** detect by comparing the set of declared
caps to the set in `grants.json`. If new caps appeared, treat them as undecided
and go through the grant flow. Existing granted/denied decisions are preserved.

**Two concurrent launch attempts for the same app:** first one starts the app,
second gets `{ url: "/app/alice/" }` since it's already running. Token matchup
prevents the second browser tab from completing a grant flow meant for a
different session.

**Browser back button to grant page after submission:** token is already
consumed, page shows "this grant attempt already completed — [launch again]".

**Operator closes the grant tab:** token expires after 5 minutes. No cleanup
needed; `grants.json` is untouched.

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

### Cap scoping: per-app by default

Every cap is **scoped to the app that was granted it**. This is the principle of
least privilege and it's non-negotiable — the sandbox guarantee depends on it.

Concretely:
- `kv` and `db` storage paths are resolved via `_resolve_data_path(cap_name, scope, context)`
  where `context.app_id` makes each app's store isolated.
- `http_client` host whitelists come from the app's manifest — alice cannot call
  hosts that bob declared.
- `http_server` ports are never shared between apps (each app has its own handler
  mounted at its own prefix).
- `shared_db` uses an authorizer keyed on `context.app_id` so apps only see their
  own rows in shared tables.
- Revocation is per-app — revoking `llm_api` for alice has no effect on bob.

Two apps asking for "the same cap" get **two different cap instances** with
independent state, independent revocation, and independent authorization.

### Blanket allows: reducing grant fatigue

Forcing the operator to approve every cap for every app becomes noise — prompted
fifty times in a week, they start clicking "allow" reflexively. That erodes the
security model faster than any technical bug would.

The fix is **not** to grant more by default. The fix is to avoid prompting for
caps where prompting adds nothing.

Three mechanisms, in decreasing order of safety:

#### 1. Cap risk classes (opt-in during setup)

Some cap types have no plausible abuse vector. Granting `time` to an app lets it
read the system clock. There is no attack surface. Prompting the operator for
this is just noise — **but the operator should opt in to that shortcut, not
discover it after the fact**.

The platform defines risk classes as metadata. **Defaults prompt for everything.**
The setup flow (or a later settings page) can *recommend* enabling auto-grant for
inert caps, with a checkbox the operator explicitly ticks.

| Class | Caps | Recommended setup default |
|-------|------|---------------------------|
| **Inert** | `time`, `self`, `stdout` | Offered as "skip prompts for harmless caps" opt-in |
| **Scoped** | `kv`, `db` | Always prompt (per app); storage is app-scoped |
| **Local** | `http_server`, `cli`, `stdin` | Always prompt per app |
| **Network** | `http_client` (with host) | Always prompt per app + per host |
| **Shared** | `shared_db`, `fs` | Always prompt per app + show scope |

Classes are **defined by the platform**, not the app. The app cannot relabel
`http_client` as "inert." The risk class is a property of the cap type's
implementation, encoded in the cap factory module.

**Nothing auto-grants out of the box.** A freshly installed crescent prompts for
every cap of every app on first launch. The operator can reduce that through
explicit opt-ins (`auto_grant: ["time", "self"]` in config, or the setup wizard's
"streamline prompts" checkbox). The decision to suppress prompts is always the
operator's, made once and auditable in settings.

#### 2. Explicit trust grants (per-source allow lists)

The operator can mark a trust source as "auto-grant whatever it asks for." Sources:

- **First-party apps.** Apps that ship with crescent (`lib/platform/apps/*`).
  These are code the operator already trusts by installing crescent. Still subject
  to the manifest — a first-party app can't access caps it didn't declare.
- **Signed apps.** If an app PNG is signed by a key in the operator's trusted
  keyring, auto-grant its declared caps. (Requires signing infrastructure — not v1.)
- **Manually trusted apps.** `POST /api/daemon/trust { app_id }` marks a specific
  app as trusted for future cap requests, after the operator has reviewed it once.

Trust is always **per-source**, never per-cap-type across apps. "Auto-grant
http_client for anyone who claims to be an AI app" is exactly the attack we're
trying to prevent — tags are app-controlled metadata.

#### 3. Remembered decisions (status quo)

Grants already persist across launches via `grants.json`. The operator approves
once per (app, cap) pair, and subsequent launches don't re-prompt unless the
manifest changes (new cap added, scope widened). This is the baseline.

### Admin policy: hard ceilings

The mechanisms above assume a single operator who is their own admin. For
multi-user deployments (family server, small team, shared Tailscale node), an
**admin policy** sets hard limits that no user can override.

**Direction is always restrictive.** Admin policy can forbid or narrow caps. It
can never expand what a user can grant, and it can never grant on a user's
behalf — consent is still the user's to give.

| Admin can... | Admin cannot... |
|--------------|-----------------|
| Forbid a cap type entirely (`fs: denied`) | Auto-grant a cap on a user's behalf |
| Narrow a host whitelist (`http_client: only api.openai.com`) | Widen a host whitelist beyond the app's manifest |
| Forbid specific trust sources (`signed_apps: disabled`) | Force a user to trust a source they don't |
| Cap storage quotas per app | Move data between users |
| Forbid opt-in auto-grant classes (`no skip-prompt for anyone`) | Make every user's grants public |

Policy storage:
- `~/.crescent/admin/policy.json` (root-owned in multi-user setups; user-owned
  and self-policing in single-user setups)
- Loaded on daemon start, re-read on SIGHUP or API call
- Not editable via the daemon's HTTP API unless the request authenticates as
  admin (separate credential from regular user sessions)

Policy structure (sketch):
```json
{
  "cap_policy": {
    "fs":          { "state": "denied" },
    "http_client": { "state": "allowed", "hosts": ["api.openai.com", "api.anthropic.com"] },
    "shared_db":   { "state": "denied" },
    "kv":          { "state": "allowed", "max_size_mb": 100 }
  },
  "trust_sources": {
    "first_party": "allowed",
    "signed":      "denied",
    "manual":      "allowed"
  },
  "auto_grant_classes": {
    "inert": "user_choice",
    "scoped": "forbidden"
  }
}
```

Enforcement points:
- **Manifest load.** If the manifest declares a denied cap type, the app is
  rejected at load time with "blocked by admin policy." The grant UI never shows.
- **Grant construction.** When building a cap, check policy constraints. A
  `http_client` declaration with `host: "evil.example"` is rejected even if the
  user would otherwise grant it.
- **Trust check.** Before applying a user's "trust this app" decision, check
  whether the trust source is admin-allowed.
- **Auto-grant check.** Before applying a user's auto-grant preference for a
  class, check whether the class is admin-allowed.

Visibility: the grant UI must show "blocked by admin policy" when a cap is
denied, not silently hide it. The user deserves to know why their app didn't
launch, and to ask the admin for an exception if needed.

Single-user vs multi-user: in single-user mode, the admin policy file may not
exist, and the daemon runs with no ceiling. The mechanism is designed so
"single-user with no admin policy" is the default; multi-user just adds a file.

### What blanket allows must never do

- **Auto-grant based on app metadata.** Tags, name, description — all
  app-controlled. A malicious app claims any tag it wants.
- **Grant caps not in the manifest.** The manifest is the cap ceiling. Trust
  grants can auto-approve declared caps; they can never widen the declaration.
- **Bypass per-app scoping.** Even auto-granted caps get per-app storage, per-app
  revocation, per-app authorizer. Auto-grant means "don't prompt," not "share
  state."
- **Grant silently with no audit.** Every auto-granted cap should be logged and
  visible in the daemon status UI. The operator should be able to see what's been
  granted without prompts and revoke retroactively.

### Cap risk disclosure

The grant UI must communicate **what each cap actually enables an attacker to do**,
not just restate the cap name. "http_client to api.openai.com" is technically
accurate but conveys nothing to a non-technical operator. The prompt should read
something like:

> **Alice wants: Network access to api.openai.com**
>
> This app can send any text you give it — messages, pasted documents, uploaded
> files — to api.openai.com. Once sent, that data is outside your control. Only
> allow this if you trust both the app and api.openai.com with your inputs.

Every cap type ships with a **risk disclosure** — a short paragraph written for
a non-technical reader, covering:

1. **What the app can do** with this cap, in concrete user-facing terms
2. **What an attacker controlling this app could do** (the worst case)
3. **What the cap does NOT give access to** (to calibrate — e.g., `time` doesn't
   reveal the user's location, only the clock)
4. **What the user can do if they regret it** (revoke, wipe app storage, etc.)

Sketch per cap type:

| Cap | Risk disclosure summary |
|-----|-------------------------|
| `time` | Reads the system clock. Cannot fingerprint the user. |
| `self` | Reads the app's own bundled files. Cannot modify them or see other apps. |
| `stdout` | Writes to the terminal output. Visible to the operator; no side effects on other programs. |
| `stdin` | Reads keyboard input intended for the app. Can prompt you, so treat prompts like app UI. |
| `kv` | Stores data in this app's isolated key-value store. Other apps cannot read it. Storage grows until you delete it. |
| `db` | Stores data in this app's isolated SQL database. Other apps cannot read it. Can accumulate unbounded data; revoke to freeze writes. |
| `http_server` | Binds a local port inside the daemon. Other apps on the same daemon cannot see its requests. |
| `http_client` | Sends HTTP requests to the listed hosts. **Anything the app processes can be transmitted to those hosts.** Assume data sent this way is permanently outside your control. |
| `fs` | Reads and writes files under the declared root path. **Data in that path is visible to the app and may be modified or deleted.** |
| `shared_db` | Reads and writes rows in a shared database tagged with this app's id. **Other apps with shared_db can see rows tagged with their own ids — not this app's.** The schema is shared, so column presence leaks across apps. |
| `cli` | Reads command-line arguments passed when the app was launched. Limited to what the operator typed. |

These are **per-cap-type** disclosures, written once in the cap factory module,
surfaced in the grant UI. Apps can add an **app-specific reason** in their
manifest ("Alice uses LLM access to generate her dialogue"), which the grant UI
shows alongside the standard disclosure. The app's reason is app-controlled
text — the platform's disclosure is the authoritative risk description.

**Scope-specific details** get rendered into the disclosure. A `fs` cap with
`root: "~/Documents/alice/"` should show the exact path ("This app can read and
write any file under ~/Documents/alice/"), not a generic template.

The grant UI must default to the safe action. **Deny is the primary button, allow
is secondary.** No spinner that auto-allows after a timeout. No pre-ticked
"approve all" checkbox.

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
