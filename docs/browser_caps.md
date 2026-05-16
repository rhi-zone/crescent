# Browser Capabilities — Comprehensive Design

> *Draft. Enumerates the Web Platform surface and proposes a classification per API for the pack realm. Decisions framed as proposals; expect revision. Open questions are called out in §7 — do not read them as settled. Counterproposals, "you missed Y," and "the classification of X is wrong because Z" are all in scope.*

This doc is the design counterpart to [`platform_isolation.md`](platform_isolation.md). Where `platform_isolation.md` settles *how* the pack realm is isolated (allow-list lockdown, cap bridge, no ambient world-state), this doc settles *what* the pack realm can ask for: every Web Platform API enumerated, each classified, and the day-zero exposed surface specified in enough detail that an implementer can build the caps from this doc plus the bridge protocol alone.

The classification is conservative on purpose. Anything not in the day-zero exposed set is structurally absent from the realm and stays absent until a future revision of this doc explicitly schedules it.

## 1. What is a browser cap?

A **daemon cap** is a Lua-side capability, enforced by the platform daemon, mediating OS resources (filesystem, processes, network sockets, KV stores) on the operator's machine. The pack's daemon-side Lua code reaches the daemon cap through the platform's daemon API.

A **browser cap** is a JS-side capability, enforced by the host stub via [`lib/js_cap_bridge/bridge.js`](../lib/js_cap_bridge/bridge.js), exposed to the pack realm (a sandboxed iframe today, a ShadowRealm tomorrow) under `globalThis.__cap__.<name>`. The pack realm has been stripped of every Web Platform global by the [`lib/js_realm_sandbox/`](../lib/js_realm_sandbox/) bootstrap; the only way the realm reaches anything beyond pure JS computation is by calling a declared, granted cap.

The two are parallel, both flowing from the same manifest:

```
pack manifest
├── caps          → daemon caps, enforced daemon-side, OS resources
└── browser_caps  → browser caps, enforced host-stub-side, browser APIs / host UI
```

Some browser caps proxy a daemon cap (the `fetch_api` browser cap, for instance, routes through the daemon-side `http_client` cap rather than performing a direct browser `fetch`). Some are browser-only (clipboard, toast, navigate, Web Crypto). The browser-cap namespace is its own, parallel to and not subsumed by daemon caps.

### The cap-bridge protocol

Every browser cap is a function the pack realm calls with structured-clone-safe args; the host stub validates the call against the pack's grants, performs the side effect in its own realm (which has the real Web Platform surface), and ships the result back. The envelope is fixed (see [`bridge.js`](../lib/js_cap_bridge/bridge.js)):

```
realm → host: { id, kind: "call", cap: "<name>", args: [...] }
host → realm: { id, kind: "result", value: <structured-clone-safe> }
           or { id, kind: "error",  error: { type, message } }
```

Streaming caps (event-driven surfaces — WebSocket message arrival, Notification click, MediaSession action, etc.) extend the envelope with `event` frames against the same `id`, terminated by a final `result` or `error`. The exact event-frame shape is specified per cap kind in §4 where it applies.

### Key principle

**The realm has no ambient Web Platform APIs.** Everything packs can do that is not pure JS computation flows through a declared, granted cap. New cap kinds are added to this document, the bridge, and the host stub together; nothing reaches the realm by accident.

This principle is load-bearing: if any single API leaks into the realm without going through a cap, the entire ambient-capability problem from `platform_isolation.md` §1 reappears. The §4 enumeration is exhaustive for that reason — every Web Platform API gets a verdict, so nothing falls through "we forgot to think about it."

## 2. Cap schema pattern

A cap kind has six axes. Every cap kind in §4 (whether exposed-now, placeholder, or future) is described against the same six.

### 2.1 Name

A unique string identifier in the `browser_caps` namespace. Convention: `snake_case`, descriptive, no version suffix (versioning is a separate axis — see §6). Names are stable; if a cap's semantics change incompatibly, a new name is introduced rather than the old one being repurposed.

Examples: `fetch_api`, `kv_read`, `kv_write`, `clipboard_write`, `toast`, `web_crypto_random`, `set_timeout`.

### 2.2 Entry args type

The shape of the arguments the cap function accepts. Pack code calls `__cap__.<name>(arg1, arg2, ...)`; those args are placed into the call envelope's `args` array and arrive at the host impl as the impl's arguments.

The bridge **does not implicitly coerce** pack-supplied values (see `bridge.js` and `platform_isolation.md` §4). The host cap impl validates shape before doing anything with the args. Cap impls must:

- Validate types structurally before any operation that might trigger `Symbol.toPrimitive` / `valueOf` / `toString` (string concatenation, arithmetic, property access on a thenable, etc.).
- Treat all args as opaque structured-clone values until validated.
- Reject thenables in args (foreign-thenable hazard).
- Apply per-cap argument size limits.

Schema per cap is described in §4 in TypeScript-style notation (the `.d.ts` is the authoritative declaration — see `platform_isolation.md` §3 "Browser-side authoring").

### 2.3 Return type

What flows back to the realm. Three possibilities:

1. **Structured-clone-safe value.** Cleanest. The cap performs the effect and returns a primitive or plain object. Pack receives the result as a promise resolution.
2. **Handle to a host-side resource.** When the underlying browser primitive is stateful (an `IDBDatabase`, a `WebSocket` connection, an `AudioContext`, a `MediaStream`), the cap returns an opaque token (a fresh string or non-zero integer). Subsequent operations on the resource are separate cap calls that take the token as their first argument. The host keeps a `Map<handle, resource>` per pack realm; when the realm tears down (iframe unload), every handle's underlying resource is closed.
3. **Streaming.** Same as #1 or #2 plus a series of `event` frames carrying further data (e.g. WebSocket messages, MediaRecorder data chunks). See §2.4.

Returned objects' methods do **not** flow into the realm. If pack code wants to call a method on a returned resource, the cap protocol exposes that method as a separate cap operation. There is no transparent proxy from realm to host objects — the surface area is what the cap protocol says it is.

### 2.4 Async / event surface

Three flavours:

- **One-shot.** Call returns a single result. The promise resolves with the value or rejects with an error.
- **Streaming with subscriber registered at call time.** The pack passes a subscriber via a cap-bridge-token convention (e.g. `__cap__.ws_open({ url, on_message_token, on_close_token })` where `on_message_token` and `on_close_token` are strings the host uses in subsequent `event` frames). When the host sends `{ id, kind: "event", event_type: "ws_message", payload }`, the realm-side bridge dispatches to whichever pending subscriber the token references.
- **Pull-based listen.** Pack calls a "listen" cap (`ws_recv(handle)`) that resolves with the next event; loops to consume the stream. Simpler for the bridge but more bookkeeping for the pack author.

The default for streaming caps in §4 is the subscriber-at-call-time convention because it composes naturally with the existing promise-returning shells in `bridge.js`. The pull-based variant is offered for caps where back-pressure matters (large MediaRecorder streams) — open question whether the bridge protocol needs both forms or only one (§7).

### 2.5 Lockdown requirements

Every value returned to the realm must be **shape-checked** against what the realm's allow-listed primitives can safely receive. Concretely:

- Primitive types (`string`, `number`, `boolean`, `null`, `undefined`) are always safe.
- Plain objects and arrays containing only safe values are safe (recursive).
- `ArrayBuffer` / typed arrays are safe (the realm keeps them).
- Anything else — `Date`, `Map`, `Set`, `Blob`, `File`, `URL`, `Headers`, `Response`, `RegExp`, `Error` — must be marshalled to a plain-object representation by the cap impl, not passed across structured clone as-is. Why: structured clone preserves prototype identity for these built-ins, and the realm's bootstrap may have replaced or removed the corresponding constructor; a value arriving with a stale prototype identity is a vector.

The rule of thumb is "if a value is not what `JSON.parse(JSON.stringify(value))` would produce, the cap impl must marshal it explicitly." Exceptions for typed arrays and `ArrayBuffer` because those are the legitimate binary-data path.

Returned handle tokens must be opaque to the realm: random strings or non-guessable integers, not pointers or indices. The host keeps a `WeakMap` from token to underlying resource; the realm cannot forge a token.

### 2.6 Permission model

Three grant scopes; each cap kind picks one:

- **Per-install.** Operator grants the cap at pack install (or first launch). Grant stored in the daemon's grant table. Every invocation thereafter is permitted without prompting. Suitable for caps the pack legitimately uses many times per session (`kv_read`, `kv_write`, `toast`, `fetch_api` with declared origin).
- **Per-session.** Operator grants at first invocation of the session; grant survives the session but is re-prompted on reload. Suitable for caps that touch user-perceived UI state (clipboard read, fullscreen request).
- **Per-invocation.** Operator confirms each invocation. Suitable for caps that are rare and high-impact (system file picker, share sheet, payment request).

Browser permission prompts (geolocation, notifications, camera/microphone) are **mediated by the host stub**, not surfaced directly in the realm. The host stub holds the actual Web Platform permission grant; the pack realm sees only the cap's permission status as the host reports it. This means the operator's confusing "do you want to allow geolocation?" prompt comes from the host's origin, with the host's branding, not from the pack realm — phishing surface is contained.

The grant UI shape itself is out of scope for this doc; see `platform_isolation.md` §7 and the future grant-UI doc.

### 2.7 Audit shape

Every cap invocation logs a structured audit entry (already implemented in `lib/js_cap_bridge/bridge.js` via the `audit(entry)` callback the host stub passes). The default shape:

```
{
  cap: "<name>",
  args: <opaque-shape-digest>, // not full contents; see below
  ok: true | false,
  error: <error-value-if-failed>,
  denied: "<reason-if-denied>",
  timestamp: <ms-since-epoch>,
}
```

Args are recorded by **shape, not contents**, by default. The audit log is operator-readable and the args may contain user data the operator did not intend to surface in logs. Per-cap-kind overrides may opt into full-args logging where the args are non-sensitive by construction (`__cap__.toast({ text })` logging the toast text is reasonable; `__cap__.kv_write({ key, value })` logging the value is not).

Per-cap "shape digest" definitions live in §4 entries that need them. Default: record only the argument arity and the top-level types (`["string", "object", "number"]`).

## 3. Manifest entry format

Schema location: [`lib/platform/platform_types.lua`](../lib/platform/platform_types.lua) (canonical `BrowserCapDecl`, with duplicates in `lib/platform/init.lua` and `lib/platform/cli.lua` kept in sync).

Merge + validation logic: [`lib/platform/manifest_caps.lua`](../lib/platform/manifest_caps.lua) — `merge_browser_cap_declarations(manifest, entry_key)` mirrors the daemon-side `merge_cap_declarations` line-by-line (same shorthand `"required"` / `"optional"`, same default-required-true, same top-level-plus-per-entrypoint merge). `validate_browser_caps(manifest)` rejects unknown kinds at manifest-parse time against the day-zero set in §5; per-kind config validation is deferred to cap-impl time.

Each browser cap a pack uses is a manifest entry under `browser_caps`. The schema:

```lua
--:: type BrowserCap = {
--::   kind: string,    -- cap kind identifier; matches a kind in §4 of this doc
--::   config: unknown, -- kind-specific config; schema documented per cap kind
--:: }

--:: type ManifestTbl_BrowserCaps = { [string]: BrowserCap }
```

Wired into the existing `lib/pkg/manifest.lua`:

```lua
--:: ManifestTbl = {
--::   name: string,
--::   version: string,
--::   description: string | nil,
--::   license: string | nil,
--::   deps: { [string]: DepValue } | nil,
--::   registries: { [integer]: string } | nil,
--::   scripts: { [string]: string } | nil,
--::   caps: { [string]: unknown } | nil,
--::   browser_caps: { [string]: BrowserCap } | nil,
--:: }
```

The key in the `browser_caps` table is the **local cap name** the pack will call (`__cap__.<key>(...)`). The value's `kind` field names the cap kind. This permits a pack to declare two instances of the same cap kind with different configs — `fetch_api` against one origin and `fetch_api_secondary` against another. The host stub maintains separate cap impls per declared entry.

### Example manifest

```lua
return {
  name = "weather-pack",
  version = "1.0.0",
  caps = {
    -- daemon-side caps
    persistent_kv = "rw",
  },
  browser_caps = {
    fetch_api = {
      kind = "fetch_api",
      config = { allowed_origins = { "https://api.weather.example" } },
    },
    toast = {
      kind = "toast",
      config = {},
    },
    location = {
      kind = "geolocation",
      config = { accuracy = "coarse" },
    },
  },
}
```

### Config schema

Per-cap-kind config schemas are documented in §4. Some kinds need no config (`toast` is parameterless); some are dominated by config (`fetch_api`'s `allowed_origins` is load-bearing — without it, the cap is unattenuated). Where config is omitted in a manifest, the cap kind's default applies; where defaults would be unsafe (allowing any origin, for instance), the cap kind requires config and rejects the manifest at install if absent.

### Grant

User grants `kind`-level at install: yes/no for each entry in `browser_caps`. The grant decision is recorded against the manifest entry key, not just the kind, so the user can grant `fetch_api` (api.weather.example) and deny `fetch_api_secondary` (third-party.example) independently.

Per-invocation prompts (clipboard write, fullscreen) overlay on top: grant at install means "the pack can ask"; the prompt at invocation is "do you want to permit this specific ask now?". A per-install denial means the cap is structurally absent from `__cap__` — there is no prompt path.

## 4. Comprehensive enumeration

Classifications:

- **Exposed-now** — shipped on day zero. Cap kind name + day-zero schema sketch in this section.
- **Placeholder day-one** — declared as a future cap kind with a schema sketch but not yet implemented. The cap kind reservation prevents naming conflicts later.
- **Future** — not yet designed. Rationale.
- **Not shipping** — explicitly excluded. Rationale (deprecated / privileged-hardware / security-class-too-broad / etc.).
- **Realm-incompatible** — does not apply to the pack realm by construction (DOM APIs under the VNode rendering model, etc.).

### 4.1 Network

Network is the highest-stakes category — exfiltration is the headline confidentiality threat in `platform_isolation.md` §2.

#### 4.1.1 `fetch()` — **exposed-now** as `fetch_api`

```ts
// args
type FetchArgs = {
  url: string;                       // absolute URL; validated against allowed_origins
  method?: "GET" | "POST" | "PUT" | "PATCH" | "DELETE" | "HEAD" | "OPTIONS";
  headers?: { [name: string]: string };  // host-filtered against a denylist (Cookie, Authorization, etc.)
  body?: string | ArrayBuffer | Uint8Array;
  // No `credentials`, no `mode`, no `redirect` — host decides
};

// returns
type FetchResult = {
  status: number;
  status_text: string;
  headers: { [name: string]: string };  // response headers
  body: string | ArrayBuffer;           // pack picks via response_type in args; default text
};

// config (per manifest entry)
type FetchConfig = {
  allowed_origins: string[];      // load-bearing; required
  allowed_methods?: string[];     // default ["GET", "POST"]
  max_body_size?: number;         // default 16 MB
  max_response_size?: number;     // default 64 MB
  timeout_ms?: number;            // default 30000
};
```

Permission: per-install. Audit: shape only (no body in log). Lockdown: response body marshalled to `string` or `ArrayBuffer`; no `Response` object crosses the bridge. The host stub performs the fetch in its own realm with its own credentials posture, never the pack's.

This cap shadows the daemon's `http_client` cap; for many packs the daemon-side variant is preferable because it does not require the browser realm to be online. The browser-side `fetch_api` is for cases where the pack genuinely needs a request from the user's browser (CORS-bound APIs, sticky-session origins, geo-IP-dependent endpoints).

Status: shipped. Impl: `lib/js_caps/fetch_api.js`. Unlike the other day-zero caps it is **factory-shaped**: `makeFetchApi({ allowed_origins })` returns the cap function, with the origin allowlist bound at host-side instantiation rather than passed as a per-call arg (a pack-supplied allowlist would defeat the manifest grant). The host page reads `manifest.browser_caps.<entry>.config` and constructs the cap-impls Map by merging `dayZeroCaps` with `makeFetchApi(entry.config)` per `fetch_api`-kind entry. `lib/js_caps/index.js` documents the merge pattern. Day-zero only supports `allowed_origins`; the other config fields documented above (`allowed_methods`, `max_body_size`, `max_response_size`, `timeout_ms`) land in subsequent commits. Tests: `lib/js_caps/caps.test.js` (factory validation, non-constructable, URL/method/headers/responseFormat validation, origin-allowlist enforcement, happy path with mocked `globalThis.fetch`, JSON/text/arraybuffer response formats, AbortSignal propagation, graceful error when `fetch` is absent).

#### 4.1.2 `XMLHttpRequest` — **not shipping**

Superseded by `fetch`. Adding a second HTTP cap with overlapping semantics doubles audit surface and bridge complexity for no benefit. Packs that want streaming bodies, request progress, or other XHR-specific features get a future `fetch_api_stream` variant (placeholder, §4.1.4 below), not XHR.

#### 4.1.3 `WebSocket` — **placeholder day-one** as `websocket`

```ts
// open
type WsOpenArgs = {
  url: string;                            // ws:// or wss://; validated against allowed_origins
  protocols?: string[];
  on_message_token: string;               // event-frame token
  on_close_token: string;
  on_error_token: string;
};
type WsOpenResult = { handle: string };

// send (separate cap or method-on-handle; design TBD)
type WsSendArgs = { handle: string; data: string | ArrayBuffer };

// close
type WsCloseArgs = { handle: string; code?: number; reason?: string };

// config
type WsConfig = {
  allowed_origins: string[];
  max_message_size?: number;     // default 1 MB
  max_concurrent?: number;       // default 4
};
```

Event frames: `{ id, kind: "event", event_type: "ws_message" | "ws_close" | "ws_error", token, payload }`. Subscriber tokens are realm-side identifiers passed at open; host echoes them back on each event so the realm bridge can dispatch.

Permission: per-install with origin allowlist. Lockdown: no `WebSocket` object crosses the bridge; only the handle.

Placeholder because the streaming subscriber convention is not yet finalized in the bridge protocol (see §2.4 and §7). Implementation waits on that.

#### 4.1.4 `EventSource` (SSE) — **placeholder day-one** as `sse`

```ts
type SseOpenArgs = {
  url: string;
  on_message_token: string;
  on_open_token?: string;
  on_error_token?: string;
};
type SseOpenResult = { handle: string };
type SseCloseArgs = { handle: string };

type SseConfig = {
  allowed_origins: string[];
  max_message_size?: number;     // default 256 KB
};
```

Same streaming convention as WebSocket. Per-install grant with origin allowlist.

#### 4.1.5 `BroadcastChannel` — **not shipping**

Cross-tab same-origin messaging. The pack realm has a unique origin per iframe (`platform_isolation.md` §7) so there is by construction nothing to broadcast to. If multi-instance pack coordination is needed in future, a host-mediated cap (`coordinate`) is the right shape, not direct BroadcastChannel exposure.

#### 4.1.6 `RTCPeerConnection` / `RTCDataChannel` (WebRTC) — **future**

WebRTC is large surface: peer connections, ICE candidates, SDP offer/answer, data channels, media tracks, getStats. Wrapping it as caps is a substantial design exercise — every state transition is a separate cap surface, and the SDP itself is a privacy-sensitive payload. Defer until a pack genuinely needs P2P; the design will be its own doc.

Not shipping STUN/TURN config either; those are bundled into the WebRTC design.

#### 4.1.7 `MessageChannel` / `MessagePort` — **realm-incompatible**

The cap bridge *is* the realm's only message channel; exposing a second one would defeat the host-mediates-every-message invariant. If pack A needs to talk to pack B, that goes through the host as a coordination cap (future, see 4.1.5 rationale).

#### 4.1.8 `navigator.sendBeacon` — **not shipping**

Fire-and-forget POST on page unload. The pack realm has no ambient `navigator`, and the use case (analytics on unload) is exactly the exfiltration shape we want to prevent. Packs that need to flush data on unload use `fetch_api` with the host stub coordinating the timing.

#### 4.1.9 `structuredClone()` — **future**

Pure-computation API (no I/O), but the realm bootstrap removes it as part of the allow-list strip (it can reach `SharedArrayBuffer` transfer semantics, and the realm's structured-clone-safe subset is narrower than the spec's). A future `structured_clone` cap or a bootstrap-installed pure-Lua reimplementation can fill this gap if packs need deep cloning. For day zero, pack code does manual clone or uses `JSON.parse(JSON.stringify(x))`.

### 4.2 Storage

The realm has no ambient storage. The host stub partitions storage per pack.

#### 4.2.1 `localStorage` / `sessionStorage` — **exposed-now** as `kv_read` / `kv_write` / `kv_delete` / `kv_keys`

Implemented in `lib/js_caps/kv.js`. Factory-shaped:
`makeKvCaps({ pack_id })` returns the four cap functions bound to a
per-pack IndexedDB database (`pack_<pack_id>`) with a single object
store `kv`. Values are structured-clone (Uint8Array / Map / Set / Date
round-trip directly; no JSON.stringify hop).

```ts
// kv_read(key) -> stored value, or undefined if absent.
type KvRead = (key: string) => Promise<unknown>;

// kv_write({ key, value }) -> void. Structured-clone the value;
// non-cloneable values (functions, DOM nodes, ...) reject with the
// underlying DataCloneError.
type KvWrite = (args: { key: string; value: unknown }) => Promise<void>;

// kv_delete(key) -> void. No-op when the key is absent.
type KvDelete = (key: string) => Promise<void>;

// kv_keys() -> all keys, arbitrary order.
type KvKeys = () => Promise<string[]>;

// factory config
type KvConfig = { pack_id: string };  // db name = "pack_" + pack_id
```

Per-call validation: keys are non-empty strings up to 1024 chars.

Permission: per-install. Storage backend: IndexedDB in the host realm, one database per pack named by `pack_id`. The pack realm never touches `indexedDB` directly — the host stub is the only realm with that access, and partitioning is by database name (plus the surrounding origin scoping).

Why IndexedDB over localStorage:
- Quota: GB-scale vs the 5–10 MB localStorage cap.
- Async: no main-thread blocking on writes.
- Structured-clone values directly — Uint8Array / Map / Set / Date round-trip with no JSON.stringify hop, so packs storing binary blobs avoid the base64 detour.

The realm-facing protocol is async over the bridge regardless, so picking IndexedDB host-side does not change pack-side ergonomics.

Status: shipped. Impl: `lib/js_caps/kv.js`. Factory-shaped (like `fetch_api`): `makeKvCaps({ pack_id })` returns a record of the four cap functions bound to that pack's database. The four caps share a backend so the factory returns the whole record at once; the host page reads `manifest.browser_caps.<entry>.config` (or, more typically, derives `pack_id` from the manifest itself) and merges all four into the cap-impls Map per pack. `lib/js_caps/index.js` documents the merge pattern. Tests: `lib/js_caps/caps.test.js` (factory validation, non-constructable, read/write roundtrip, missing-key undefined, delete + delete-absent, kv_keys enumeration, structured-clone fidelity for Uint8Array, per-pack partitioning isolation, key validation: non-string / empty / oversized / null args).

Distinct from session: a `session_kv` variant tied to the realm's lifetime is a future placeholder. Day-zero `kv` is persistent.

#### 4.2.2 `IndexedDB` — **placeholder day-one** as `indexed_db`

Direct IndexedDB exposure is substantial: object stores, indexes, cursors, key ranges, transactions, version upgrades. The challenge is cursor lifecycle — a cursor is a long-lived host-side stateful resource the pack walks step by step, and the cap protocol must carry `cursor.continue()` round-trips without leaking the cursor's identity.

Sketch:

```ts
type IdbOpenArgs = { name: string; version?: number };
type IdbOpenResult = { handle: string };  // database handle

type IdbTxnArgs = { db: string; stores: string[]; mode: "readonly" | "readwrite" };
type IdbTxnResult = { txn: string };

type IdbGetArgs = { txn: string; store: string; key: any };
type IdbGetResult = { value: any };

// cursor: { txn, store, range?, direction? } → { handle }
// cursor_continue: { cursor } → { key, value } | { done: true }
// cursor is closed when txn closes or pack realm tears down
```

Defer to placeholder because the cursor-lifecycle design needs to be exercised against real usage (and may collapse to "just expose the kv-with-prefix-iteration subset of `kv_keys` we already have").

For day zero, packs that want structured storage layer their own format on top of `kv` (JSON in a value, key prefixes for indexes). When the layered cost is too high, the placeholder gets promoted.

#### 4.2.3 `Cache` (Cache API) — **future**

Tied to Service Workers conceptually; not needed without them. If a pack-side HTTP cache becomes useful, design as a separate cap that layers on `fetch_api`.

#### 4.2.4 Cookie Store API — **not shipping**

Cookies are an ambient-credential primitive precisely of the kind the realm is designed to remove. Pack-controlled cookie reads would re-introduce the cross-pack confidentiality problem; pack-controlled cookie writes would let packs impersonate the user against any origin the daemon ever fetches.

#### 4.2.5 File System Access API — **future** as `file_picker_open` / `file_picker_save`

```ts
// future schema sketch
type FilePickerOpenArgs = {
  accept?: { [mime: string]: string[] };  // {"text/*": [".txt", ".md"]}
  multiple?: boolean;
};
type FilePickerOpenResult = {
  files: Array<{
    handle: string;
    name: string;
    size: number;
    type: string;
  }>;
};

type FileReadArgs = { handle: string; offset?: number; length?: number };
type FileReadResult = { bytes: ArrayBuffer };
```

Per-invocation permission (the picker dialog is the prompt). Not day-zero because the use case is narrow (import-export flows) and the daemon-side filesystem caps cover most of what packs actually want; the browser File System Access is the right answer specifically when the user wants to point at a file the daemon cannot see.

#### 4.2.6 Storage Manager (`navigator.storage`) — **not shipping**

Quota, persistence, estimate. Per-pack quota is enforced by the host stub's KV cap config (`max_total_bytes`); exposing the browser's quota API in addition is redundant and gives the pack a sensor for global browser state. Future "quota_status" cap kind reservation if packs need to ask the host stub how full their KV is.

### 4.3 Workers / concurrency

#### 4.3.1 `Worker` (Dedicated Worker) — **future**

Workers in the pack realm are a real design exercise: each worker is its own JS realm and would need its own lockdown bootstrap, its own bridge to the host (since the original cap bridge is in the iframe's main thread), and its own grant context. The structural-isolation argument says the bridge cap should mediate, not the worker spawn.

Possible future shape: a `worker` cap that spawns a host-managed Worker preloaded with the lockdown bootstrap and a forwarded cap bridge. Defer until performance need is demonstrated; the realm's main thread is fast enough for the kind of UI work packs do today.

#### 4.3.2 `SharedWorker` — **not shipping**

Cross-tab same-origin worker. Same rationale as BroadcastChannel: per-iframe-origin makes "shared" empty by construction.

#### 4.3.3 `ServiceWorker` — **not shipping**

Service workers persist across realm tears-downs, intercept fetches, and run in their own scope. Every property is the opposite of what the cap model wants: ambient interception, long-lived state outside the operator's audit view, fetch authority detached from the manifest's `allowed_origins`. Hard exclusion.

#### 4.3.4 Web Locks (`navigator.locks`) — **future**

Mutex primitive across pages of the same origin. Useful for pack instances coordinating; deferred for the same reason BroadcastChannel is — per-iframe-origin removes the coordination set.

If multi-instance coordination becomes a need, a future `lock` cap kind layers on top of host-stub-side state.

#### 4.3.5 `SharedArrayBuffer` / `Atomics` — **not shipping**

Cross-thread shared memory and atomics are Spectre-prone and already disabled in cross-origin-isolated state per `platform_isolation.md` §3 ("`SharedArrayBuffer` removed"). The realm bootstrap structurally removes both. Hard exclusion.

### 4.4 DOM / page

All DOM APIs are **realm-incompatible** under the resolved rendering model (Option B in `platform_isolation.md` §5): the pack realm has no `document`, `Element`, `Node`, or related globals. Pack UI is described as VNode-shaped Lua tables (or JS objects in the JS+JSDoc authoring path) that the host paints in the host's realm. Event handling is via cap-bridge tokens, not DOM `Event` objects.

This section enumerates the APIs nonetheless, so the classification is exhaustive.

#### 4.4.1 `document` / `Element` / `Node` / `HTMLElement` (and all subclasses) — **realm-incompatible**

#### 4.4.2 `window` / `parent` / `top` / `frames` / `self` — **realm-incompatible**

The realm's `globalThis` is the curated namespace from the bootstrap (see `platform_isolation.md` §3); `window` and friends are absent.

#### 4.4.3 `location` — **not shipping**

Pack-controlled navigation away from the realm is a `window.open` / `location.href` exfiltration vector. The `navigate` cap (4.4.10) is the replacement for the legitimate use case.

#### 4.4.4 `history` (pushState / replaceState / back / forward) — **future** as `route`

Packs that want to expose deep-linkable internal state need a cap that maps pack-internal route names to host URL state. Schema sketch:

```ts
type RoutePushArgs = { route: string; state?: any };  // route is pack-namespaced
type RouteReplaceArgs = { route: string; state?: any };
type RouteBackArgs = {};
type RouteListenArgs = { on_change_token: string };
```

The host owns the actual URL; pack route names get serialized into a path-prefix or query parameter. Not day-zero because day-zero packs are single-screen.

#### 4.4.5 `screen` (screen.width, .height, .availWidth, etc.) — **not shipping**

Screen dimensions are fingerprintable. The pack receives a coarsened "viewport size" through the VNode rendering protocol if it needs to make layout decisions; the actual screen properties stay host-side.

#### 4.4.6 `customElements` (Web Components) — **realm-incompatible**

No DOM, no custom elements. The VNode tag set is host-defined; packs cannot register new tags. If pack-defined components are needed in future, the VNode protocol grows a "pack-composed component" notion — not a `customElements.define` analog.

#### 4.4.7 `MutationObserver` / `IntersectionObserver` / `ResizeObserver` / `PerformanceObserver` — **realm-incompatible**

No DOM nodes to observe. The host paints; if a pack wants visibility events on its own VNodes, the rendering protocol surfaces those as cap-bridge events at the protocol level (a future `vnode_visibility` event token, not an observer API).

#### 4.4.8 `Range` / `Selection` — **realm-incompatible**

Selection of DOM ranges; no DOM in realm. If pack UI needs "what did the user select?", the rendering protocol carries it as an event payload.

#### 4.4.9 `FocusEvent` / focus management — **placeholder day-one** as `focus`

Pack UI needs to programmatically request focus on a rendered control (open a modal, focus an input on appear). Schema sketch:

```ts
type FocusArgs = { vnode_id: string };  // pack-side identifier the host knows
type FocusResult = { ok: true };
```

Placeholder because the vnode-id contract between pack and host is not yet specified (the VNode rendering protocol is its own doc-to-be).

#### 4.4.10 `window.open` / `<a href>` / `location.href = "..."` — **exposed-now** as `navigate`

```ts
type NavigateArgs = {
  target: "self" | "new_tab";   // "self" replaces the host-shell's view, "new_tab" opens external
  url: string;                  // validated against allowed_navigations config
};
type NavigateResult = { ok: true };

type NavigateConfig = {
  allowed_navigations: Array<
    | { type: "external_url", url_pattern: string }      // external open
    | { type: "internal_route", route_pattern: string }  // host-shell pack route
  >;
};
```

Permission: per-install with allow-list. Audit: full URL recorded (it's already going to be visible to the user as a navigation). Lockdown: host validates `url` against `allowed_navigations` patterns before calling `window.open` or its own router.

Day-zero because the use case is concrete (a pack wants to link to an external doc, or to another pack's view in the same operator dashboard).

Status: shipped. Impl: `lib/js_caps/ui.js` via `makeUiCaps({ requestNavigate })`. The shipped cap is the simpler pure-routing form (`{ path: string } → Promise<void>`); the host app owns route validation and external-vs-internal disposition via its `requestNavigate` primitive. Tests: `lib/js_caps/caps.test.js`. The schema above (target/url/allowed_navigations) is the spec ceiling -- it lands when host-app routing semantics generalise enough to need a discriminant.

#### 4.4.11 View Transitions API — **future**

CSS-driven page transitions. Belongs in a future "VNode rendering protocol — animations" design, not as a standalone cap.

#### 4.4.12 Fullscreen API (`Element.requestFullscreen`) — **future** as `fullscreen`

Per-session permission (per-invocation if the browser also prompts). Schema:

```ts
type FullscreenArgs = { vnode_id?: string };  // optional: fullscreen this VNode subtree only
type FullscreenResult = { ok: true };
type ExitFullscreenArgs = {};
```

Not day-zero — narrow use case.

### 4.5 Sensors / hardware

Mostly **not shipping** for the day-zero pack ecosystem. Each gets a one-line rationale.

| API | Classification | Rationale |
|---|---|---|
| Geolocation (`navigator.geolocation`) | **placeholder day-one** as `geolocation` | Per-invocation permission; coarse/fine in config; host stub mediates browser permission prompt. Schema: `{ accuracy: "coarse"|"fine" }` → `{ lat, lng, accuracy }`. Defer impl. |
| DeviceOrientation / DeviceMotion | **not shipping** | Mobile-only, fingerprintable, narrow use case. |
| Web Bluetooth (`navigator.bluetooth`) | **not shipping** | Privileged hardware. Day-zero pack ecosystem has no need. |
| WebUSB (`navigator.usb`) | **not shipping** | Privileged hardware. |
| Web Serial (`navigator.serial`) | **not shipping** | Privileged hardware. |
| WebHID (`navigator.hid`) | **not shipping** | Privileged hardware. |
| Battery Status (`navigator.getBattery`) | **not shipping** | Fingerprintable; deprecated for that reason in most browsers. |
| Vibration (`navigator.vibrate`) | **not shipping** | Mobile-only, low value, ad-abused. |
| Gamepad API | **future** | Real use case (controller-driven pack UIs) but narrow; design as event-stream cap when needed. |
| Web NFC | **not shipping** | Privileged hardware, narrow. |
| Ambient Light Sensor | **not shipping** | Fingerprintable. |
| Magnetometer / Gyroscope / Accelerometer | **not shipping** | Fingerprintable, mobile-only. |
| Proximity Sensor | **not shipping** | Deprecated. |

When any of these flips to a real use case, the cap design follows: per-invocation or per-session permission, host mediates the browser prompt, return marshalled to plain JSON.

### 4.6 Media

| API | Classification | Notes |
|---|---|---|
| `getUserMedia` (camera/mic) | **future** as `media_record` | Per-invocation permission. Returns a recording handle; host manages MediaStream. Audit logs every start/stop. Significant privacy weight; design carefully when needed. |
| MediaSession (Media Session API) | **future** | OS-integrated media controls. Niche for the pack ecosystem. |
| `<audio>` / `<video>` HTML elements | **realm-incompatible** | Belong in the VNode protocol as host-rendered media VNodes, not as DOM elements in the realm. |
| Web Audio API (`AudioContext`, etc.) | **future** as `audio_play` (high-level) | Direct AudioContext exposure is huge surface; a high-level "play this audio buffer at this gain" cap covers most use cases. Defer until pack needs it. |
| Screen Capture (`getDisplayMedia`) | **future** | Per-invocation. Same shape as `media_record`. |
| MediaSource (MSE) / EME (Encrypted Media) | **not shipping** | DRM and adaptive-streaming primitives; out of scope for the pack ecosystem. |
| Picture-in-Picture | **future** | Niche; design when a pack needs it. |
| Wake Lock (`navigator.wakeLock`) | **future** as `wake_lock` | Per-session permission. Schema: `acquire()` → `{ handle }`; `release(handle)`. |
| Speech Synthesis (`window.speechSynthesis`) | **future** as `speak` | Per-session permission. Schema: `{ text, voice?, rate?, pitch? }`. |
| Speech Recognition (`SpeechRecognition`) | **future** | Per-invocation permission. Browser support varies; design when concrete need arises. |

### 4.7 Cryptography

#### 4.7.1 `crypto.getRandomValues` — **exposed-now** as `web_crypto_random`

```ts
type RandomArgs = { byte_length: number };  // bounded: 1 ≤ n ≤ 65536
type RandomResult = { bytes: ArrayBuffer };
```

Permission: per-install (default-grant; cap is presence-or-absence, no value in prompting). Audit: shape only. Lockdown: returns `ArrayBuffer`, which is allow-listed.

Day-zero because secure randomness is a baseline primitive every cryptographic library needs, and the realm has no ambient `crypto`.

#### 4.7.2 `crypto.subtle` (SubtleCrypto) — **exposed-now** as `web_crypto_subtle`

```ts
// One unified cap with an "op" discriminant; args mirror the
// corresponding SubtleCrypto method's parameter list, keyed by name.
type SubtleArgs =
  | { op: "encrypt",     algorithm: object | string, key: CryptoKey, data: BufferSource }
  | { op: "decrypt",     algorithm: object | string, key: CryptoKey, data: BufferSource }
  | { op: "sign",        algorithm: object | string, key: CryptoKey, data: BufferSource }
  | { op: "verify",      algorithm: object | string, key: CryptoKey, signature: BufferSource, data: BufferSource }
  | { op: "digest",      algorithm: object | string, data: BufferSource }
  | { op: "generateKey", algorithm: object, extractable: boolean, keyUsages: string[] }
  | { op: "deriveKey",   algorithm: object, baseKey: CryptoKey, derivedKeyType: object, extractable: boolean, keyUsages: string[] }
  | { op: "deriveBits",  algorithm: object, baseKey: CryptoKey, length: number }
  | { op: "importKey",   format: "raw" | "pkcs8" | "spki" | "jwk", keyData: BufferSource | JsonWebKey, algorithm: object | string, extractable: boolean, keyUsages: string[] }
  | { op: "exportKey",   format: "raw" | "pkcs8" | "spki" | "jwk", key: CryptoKey }
  | { op: "wrapKey",     format: string, key: CryptoKey, wrappingKey: CryptoKey, wrapAlgorithm: object | string }
  | { op: "unwrapKey",   format: string, wrappedKey: BufferSource, unwrappingKey: CryptoKey, unwrapAlgorithm: object | string, unwrappedKeyAlgorithm: object | string, extractable: boolean, keyUsages: string[] };

type SubtleResult =
  | ArrayBuffer       // encrypt, decrypt, sign, digest, deriveBits, wrapKey
  | boolean           // verify
  | CryptoKey         // generateKey (symmetric), deriveKey, importKey, unwrapKey
  | CryptoKeyPair     // generateKey (asymmetric)
  | ArrayBuffer       // exportKey (raw/pkcs8/spki)
  | JsonWebKey;       // exportKey (jwk)
```

`CryptoKey` is structured-clone-transferable per the Web Crypto spec, so the host returns CryptoKey objects directly across the cap-bridge `postMessage` boundary between same-origin realms (which is the pack-host configuration). The pack realm receives a real CryptoKey it can hand back to subsequent `web_crypto_subtle` calls. If a deployment ever targets a cross-origin boundary that does **not** structured-clone CryptoKey, pack code works around it by `exportKey`/`importKey` round-trips through a wire-safe format (`raw` / `pkcs8` / `spki` / `jwk`).

Validation in the cap impl is shallow: it checks that `args` is an object with a known `op` and that the per-op required fields are present. Detailed type checking (algorithm name validity, key-usage compatibility, etc.) is delegated to `crypto.subtle` itself — re-checking would duplicate the spec, and the host API surfaces clearer errors than a hand-rolled validator could.

Permission: per-install. Audit: shape only (do not log key material). The cap exposes every SubtleCrypto method, so RSA / ECDH / PBKDF2 / HKDF are all reachable on day zero; further algorithms become available automatically as the host's WebCrypto implementation gains them.

This is the largest day-zero schema, and it earns the size: cryptographic ops touch user secrets directly, and getting the boundary right is high-stakes.

Status: shipped. Impl: `lib/js_caps/web_crypto_subtle.js`. Tests: `lib/js_caps/caps.test.js` (digest, generateKey/encrypt/decrypt, sign/verify, importKey/exportKey, deriveKey, wrapKey/unwrapKey, CryptoKey structured-clone round-trip, validation failures).

### 4.8 Encoding / utilities

These are pure-computation APIs; many can be reimplemented in pack-author JS without a host round-trip. They are exposed as caps only when the browser's native implementation is materially faster or correctness-easier than a Lua/JS reimplementation.

| API | Classification | Notes |
|---|---|---|
| `TextEncoder` / `TextDecoder` | **exposed-now** as `text_encode` / `text_decode` | UTF-8 only at day zero. Schema: `text_encode({ text }) → { bytes }`, `text_decode({ bytes }) → { text }`. Pure computation; host-side fast path. |
| `URL` / `URLSearchParams` | **future** as `url_parse` | Pack-author JS or pure-Lua reimpl is fine for day zero; cap is justified only if the native parser's edge-case correctness matters (it usually does for security-sensitive URL handling). |
| `Blob` / `File` / `FileReader` | **realm-incompatible** | Blob and File are passed only as part of File System Access (4.2.5) and `getUserMedia` (4.6); they don't exist as standalone realm constructors. The cap returning bytes is `ArrayBuffer`, not `Blob`. |
| `FormData` | **realm-incompatible** | FormData is a `fetch` body shape; the `fetch_api` cap's body type is `string | ArrayBuffer` and packs serialize multipart themselves if needed. |
| `Headers` / `Request` / `Response` | **realm-incompatible** | These cross the bridge as plain `{ [name: string]: string }` and `{ status, body }` objects. Not as Web Platform constructors. |
| `btoa` / `atob` (base64) | **exposed-now** as part of the bootstrap-installed primitives | Pure computation, no host needed. Bootstrap installs polyfilled `btoa` / `atob` in the realm directly; no cap. (Listed here for completeness — the realm allow-list grows by one entry, but there is no bridge involvement.) |

### 4.9 Time / scheduling

#### 4.9.1 `setTimeout` — **exposed-now** as `set_timeout` (AbortSignal-cancellable)

```ts
type SetTimeoutOpts = { signal?: AbortSignal };
type set_timeout = (delay_ms: number, opts?: SetTimeoutOpts) => Promise<void>;
```

The Promise resolves after `delay_ms` elapses. If `opts.signal` is provided and `signal.aborted` becomes true before the timer fires, the Promise rejects with an `AbortError`. `delay_ms` is bounded by the browser's native `setTimeout` ceiling (INT32_MAX ms, ~24.8 days); there is no additional platform-side clamp — longer waits are out-of-scope and should be expressed as cap-chained scheduling.

Permission: per-install (default-grant). Lockdown: host-side timer, host-side fire; the pack realm sees only the awaited Promise. The pack's AbortSignal never crosses the wire — see [`platform_isolation.md`](platform_isolation.md) §4 "Cancellation via AbortSignal" for the bridge-layer protocol that intercepts the signal locally and emits a cancel message keyed to the call's correlation id. Per-pack concurrent-timer cap (default 64) prevents DoS.

Day-zero because nearly every pack needs scheduled work. The realm has no `setTimeout` ambient — the bridged version is the only path. There is no separate `clear_timeout` cap: cancellation is uniformly expressed via AbortSignal, the standard JS primitive, so packs do not learn a parallel cancel API per cap.

Status: shipped. The cap-bridge AbortSignal extension (`lib/js_cap_bridge/bridge.js`) handles wire translation; the impl in `lib/js_caps/set_timeout.js` consumes a host-realm AbortSignal supplied by the bridge. An earlier implementation (a Promise-returning `set_timeout` with a no-op `clear_timeout`) was reverted because it surfaced no cancellation handle to packs — half-measure.

#### 4.9.2 `setInterval` / `clearInterval` — **placeholder day-one** as `set_interval`

Same shape as `set_timeout` but the host repeats. Placeholder because most use cases are better expressed as `set_timeout` chains (avoiding the "interval handler ran while previous still running" pitfall); day-zero packs can compose without it.

#### 4.9.3 `requestAnimationFrame` / `cancelAnimationFrame` — **placeholder day-one** as `request_animation_frame`

Tied to the VNode rendering protocol — the host already runs a paint loop in its own realm, and pack-side animation hooks are best expressed as a per-frame event the rendering protocol delivers, not as a separate cap. Placeholder; resolves when the rendering-protocol animation design lands.

#### 4.9.4 `requestIdleCallback` / `cancelIdleCallback` — **future**

Niche; defer.

#### 4.9.5 `queueMicrotask` — **future** as part of bootstrap primitives, not a cap

Pure JS; the realm's `Promise.resolve().then(...)` already provides the same scheduling. If a dedicated `queueMicrotask` is needed, the bootstrap installs it as a non-cap primitive (similar to `btoa`).

#### 4.9.6 `performance.now` / `performance.timing` — **realm-incompatible** at the cap layer

The realm's `Date.now` and `performance.now` are kept from the bootstrap (see `platform_isolation.md` §3 "Date / performance.now"); they are not caps. The browser's Spectre-mitigation coarsening is the load-bearing privacy posture; an additional cap layer would be redundant.

`PerformanceObserver` and the per-entry-type performance APIs are **not shipping** — fingerprinting surface, and the use case (real user monitoring) is host-side concern, not pack-side.

#### 4.9.7 Prioritized Task Scheduling (`scheduler.postTask`) — **future**

Browser-side priority queue; defer.

### 4.10 Notifications / UI

#### 4.10.1 `Notification` (Web Notifications) — **future** as `notification`

```ts
type NotificationArgs = {
  title: string;
  body?: string;
  icon?: string;          // URL, validated against fetch_api's allowed_origins or host-served data:
  tag?: string;
  on_click_token?: string;
};
type NotificationResult = { handle: string };

type NotificationConfig = {
  max_per_minute?: number;   // default 6
};
```

Per-session permission with browser permission prompt mediated by host. Click events stream back via `on_click_token`. Not day-zero only because the use case (background-event surfacing) is narrower than a toast (foreground, in-shell) — `toast` covers the day-zero need.

#### 4.10.2 `Permissions` API (`navigator.permissions`) — **not shipping**

The pack realm has no view of browser-level permissions; the host mediates each per-cap permission status and reports it as part of the cap's call result (e.g., a geolocation call returns `{ status: "denied" }` instead of throwing). A pack-side "query permission" cap is redundant with that posture.

#### 4.10.3 `alert` / `confirm` / `prompt` — **exposed-now** as `dialog`

```ts
type DialogArgs =
  | { kind: "alert", message: string }
  | { kind: "confirm", message: string }
  | { kind: "prompt", message: string, default_value?: string };

type DialogResult =
  | { ok: true }                               // alert
  | { confirmed: boolean }                     // confirm
  | { confirmed: boolean, value?: string };    // prompt
```

Permission: per-install. Host renders the dialog in the host's realm with the host's chrome (no pack-controlled chrome — phishing prevention). The browser's native `alert`/`confirm`/`prompt` are *not* used because they'd come from the iframe's origin and could be styled to look like host UI; the host stub renders its own dialog.

Day-zero because dialogs are the simplest interaction primitive a pack might legitimately need.

Status: shipped. Impl: `lib/js_caps/ui.js` via `makeUiCaps({ renderDialog })`. The shipped cap is the simpler open-button-set form (`{ message: string, buttons: string[] } → Promise<string>` resolving to the selected button name); it subsumes alert (one button), confirm (two), and prompt (replaced by explicit-button choices). The host-supplied `renderDialog` is contractually required to return one of the input button strings; a mismatch surfaces as a `dialog: host returned unknown button` error. Tests: `lib/js_caps/caps.test.js`.

#### 4.10.4 `toast` (no W3C API, host-rendered primitive) — **exposed-now** as `toast`

```ts
type ToastArgs = {
  text: string;            // bounded length: 1 ≤ len ≤ 280
  kind?: "info" | "warn" | "error" | "success";
  duration_ms?: number;    // bounded: 1000 ≤ ms ≤ 10000
};
type ToastResult = { ok: true };

type ToastConfig = {
  max_per_minute?: number;  // default 12
};
```

Permission: per-install. Host renders in its own realm; pack cannot style. Audit: text logged (it's user-visible already).

Day-zero — foreground notification is a base UX need.

Status: shipped. Impl: `lib/js_caps/ui.js` via `makeUiCaps({ renderToast })`. The shipped signature is `{ message: string, level?: "info"|"warning"|"error", duration?: number } → Promise<void>` (defaults: `level="info"`, `duration=3000`; bounded: message ≤ 512 chars, duration ≤ 30 000 ms). The doc-spec `text`/`kind`/`duration_ms` names land at the manifest layer when the per-cap-kind config-schema design (§7) resolves; the cap interface here is the pack-facing one. Tests: `lib/js_caps/caps.test.js`.

#### 4.10.5 Clipboard API (`navigator.clipboard.readText` / `writeText`) — **exposed-now** as `clipboard_write`; clipboard_read **placeholder day-one**

```ts
// clipboard_write
type ClipboardWriteArgs = { text: string };  // bounded: ≤ 1 MiB
type ClipboardWriteResult = { ok: true };

// clipboard_read (placeholder)
type ClipboardReadArgs = {};
type ClipboardReadResult = { text: string };
```

Permission: per-invocation for both (browser's own permission prompts mediated by host). Day-zero is write-only because read leaks ambient user data; write is the common pack need (copy-this-link-style flows).

Status: shipped. Impl: `lib/js_caps/clipboard_write.js`. Tests: `lib/js_caps/caps.test.js` (validation, 1 MiB size cap, happy path / NotAllowedError / missing-API via mocked `navigator.clipboard`, non-constructable). The 1 MiB cap reflects clipboard usage in practice -- it is a UI primitive for paste-back flows (links, snippets, short text), not a bulk-data channel; multi-megabyte payloads are almost certainly a serialisation bug and should be surfaced at the cap call rather than handed to the OS clipboard.

#### 4.10.6 Fullscreen — see 4.4.12.

### 4.11 Background / lifecycle

| API | Classification | Notes |
|---|---|---|
| Page Visibility API (`document.visibilityState`) | **placeholder day-one** as `visibility_listen` | Streaming cap: host emits visibility-change events. Useful for packs to pause work when not visible. |
| Page Lifecycle (`freeze`, `resume`, `pagehide`) | **future** | Tied into visibility; defer. |
| Idle Detection (`IdleDetector`) | **not shipping** | User-presence sensing; privacy weight too high for the use cases. |
| Background Fetch | **not shipping** | Tied to ServiceWorker. |
| Background Sync | **not shipping** | Tied to ServiceWorker. |
| Periodic Background Sync | **not shipping** | Tied to ServiceWorker. |
| Push API | **not shipping** | Tied to ServiceWorker and an external push service. Push-notification needs route through the daemon, not the browser. |

### 4.12 Identity / payment

| API | Classification | Notes |
|---|---|---|
| Web Share (`navigator.share`) | **future** as `share` | Per-invocation; host invokes browser share sheet. |
| WebAuthn / FIDO2 (`navigator.credentials.get` / `create`) | **future** as `webauthn` | High-stakes; design when a pack needs it. Per-invocation. |
| Payment Request API | **not shipping** | High-stakes; pack-ecosystem payment flows route through daemon-side payment integrations, not browser-side. |
| Credential Management API | **not shipping** | Browser-managed credentials; pack-managed credentials route through daemon-side KV with explicit grants. |
| Federated Credential Management (FedCM) | **not shipping** | Tied to browser-mediated sign-in; out of scope. |

### 4.13 Trust / integrity

| API | Classification | Notes |
|---|---|---|
| Trusted Types | **realm-incompatible** | No DOM in realm, so no innerHTML-class sinks; Trusted Types' enforcement target is structurally absent. The host's realm uses Trusted Types when painting VNodes (separate concern, host-side). |

### 4.14 Miscellaneous

| API | Classification | Notes |
|---|---|---|
| `console` (console.log, console.error, etc.) | **exposed-now** as `console_log` | Bootstrap installs a console wrapper that bridges through. Schema: `{ level: "log"|"warn"|"error", args: any[] }` → `{ ok: true }`. Host stub may forward to operator-visible audit log or browser devtools (operator preference). |
| `WebGL` / `WebGL2` / `WebGPU` | **future** | Massive surface; defer until graphics-heavy packs exist. |
| Canvas 2D (`<canvas>` / `CanvasRenderingContext2D`) | **realm-incompatible at the API level; VNode-protocol-extension future** | If pack needs 2D drawing, it ships a "canvas VNode" in its render tree; the host renders. Direct CanvasRenderingContext2D in the realm is not exposed. |
| OffscreenCanvas | **future** | Tied to canvas + workers; doubly deferred. |
| SVG (as DOM) | **realm-incompatible at the DOM level; VNode-protocol-supported** | The VNode protocol's tag set includes SVG tags; pack ships an `svg` VNode tree, host paints. No `SVGElement` in realm. |
| HTML imports / `<link rel="import">` | **not shipping** | Deprecated. |
| Web Components shadow DOM | **realm-incompatible** | See 4.4.6. |
| `EyeDropper` API | **future** | Color picker; per-invocation. Niche. |
| Document Picture-in-Picture | **future** | Niche. |
| Window Controls Overlay | **not shipping** | PWA-specific. |
| Badging API | **future** | App badge counts; deferred. |
| Contact Picker API | **future** | Per-invocation, mediated by host. Niche. |
| WebTransport | **future** | QUIC-based bidirectional transport; future when a pack needs it. |
| Reporting API | **not shipping** | Reporting endpoints; pack-side reporting routes through daemon. |
| Network Information API (`navigator.connection`) | **not shipping** | Fingerprintable. |
| User-Agent Client Hints | **not shipping** | Fingerprintable. |
| Storage Access API | **not shipping** | Cross-origin cookie access; pack realm has no cookies. |
| Origin Private File System (`navigator.storage.getDirectory`) | **future** | Per-pack persistent FS; subsumed by `kv` for day zero. |
| Compression Streams (`CompressionStream` / `DecompressionStream`) | **exposed-now** as `compress` / `decompress` | Useful primitive; small, focused. Schema: `compress({ algorithm: "gzip"|"deflate", input: ArrayBuffer }) → { output: ArrayBuffer }`. Pure computation; host-side because the realm has no native streams API. |
| Streams API (`ReadableStream`, `WritableStream`, `TransformStream`) | **future** | Streaming primitive; pack-side reimpl is non-trivial. Future cap is bigger design exercise. |
| `addEventListener` on globals | **realm-incompatible** | No global event targets in realm; cap-bridge event tokens are the substitute. |
| `requestStorageAccess` | **not shipping** | See Storage Access API. |
| `Sanitizer` API | **future** | Sanitize untrusted HTML; only relevant if HTML rendering enters the VNode protocol, which it doesn't today. |
| WebCodecs | **future** | Encode/decode video frames; deferred. |
| `BarcodeDetector` / Shape Detection API | **not shipping** | Limited browser support; niche. |
| `WebOTP` | **not shipping** | SMS OTP autofill; mobile-only, niche. |
| `Window.print()` | **future** as `print` | Per-invocation; host stub invokes print dialog. Niche. |
| `navigator.clipboard.read` (rich) | **not shipping** | Reading clipboard images / files; if needed, future cap. Day-zero is text-only read placeholder (4.10.5). |
| `Selection.toString()` | **realm-incompatible** | No DOM, no selection. |
| `getComputedStyle` | **realm-incompatible** | No DOM. |
| CSS Custom Properties / CSSOM | **realm-incompatible** | No DOM. |
| CSS Houdini (Paint API, Layout API) | **realm-incompatible** | No DOM. |
| Web Animations API | **realm-incompatible** | No DOM. Animation hooks live in the VNode protocol. |
| `IntersectionObserver` v2 | **realm-incompatible** | See 4.4.7. |
| Element Internals (`ElementInternals`) | **realm-incompatible** | No custom elements. |
| ARIA / Accessibility Object Model | **realm-incompatible at API level; VNode-protocol-supported** | ARIA attributes are VNode prop fields; host applies them when painting. No AOM in realm. |

## 5. Day-zero exposed cap surface

Distilling §4 to the day-zero set:

| Cap kind | Purpose | Permission | Config required |
|---|---|---|---|
| `fetch_api` | Browser-side HTTP request with origin allowlist | per-install | yes (`allowed_origins`) |
| `kv_read` | Per-pack persistent key-value read | per-install | optional |
| `kv_write` | Per-pack persistent key-value write | per-install | optional |
| `kv_delete` | Per-pack persistent key-value delete | per-install | optional |
| `kv_keys` | Per-pack persistent key-value list (prefix) | per-install | optional |
| `navigate` | Programmatic navigation with allowlist | per-install | yes (`allowed_navigations`) |
| `dialog` | Host-rendered alert/confirm/prompt | per-install | optional |
| `toast` | Host-rendered ephemeral notification | per-install | optional |
| `clipboard_write` | Copy text to clipboard | per-invocation | optional |
| `web_crypto_random` | Cryptographically secure random bytes | per-install | none |
| `web_crypto_subtle` | SubtleCrypto (op-discriminated wrap; CryptoKey crosses the bridge via structured clone) | per-install | none |
| `text_encode` | UTF-8 encode | per-install | none |
| `text_decode` | UTF-8 decode | per-install | none |
| `compress` | gzip / deflate | per-install | none |
| `decompress` | gzip / deflate inverse | per-install | none |
| `console_log` | Pack-side console bridged to host | per-install | none |
| `set_timeout` | Delay-resolved Promise; cancel via AbortSignal | per-install | optional |

Seventeen caps. The set is small and deliberate: it covers basic HTTP, storage, navigation, simple UI primitives, cryptography, encoding, and timing — enough for a wide range of pack designs without exposing anything that needs a careful threat-model design (sensors, media, workers, WebRTC).

Cancellation is uniformly expressed via AbortController / AbortSignal (the standard JS cancellation primitive) — there is no per-cap "cancel" sibling. `set_timeout` and `fetch_api` both use this; future cancellable caps will follow the same pattern. Bridge-layer protocol in [`platform_isolation.md`](platform_isolation.md) §4 "Cancellation via AbortSignal".

Most day-zero caps are pure functions safe for every pack and live in `lib/js_caps/index.js#dayZeroCaps` directly. **Factory-shaped caps** — `fetch_api` (via `makeFetchApi({ allowed_origins })`) and the `kv_*` family (via `makeKvCaps({ pack_id })`, which returns the four caps at once because they share an IndexedDB backend), and future per-pack-configured kinds — carry manifest-supplied config that binds at host-side instantiation, not as a per-call arg. The host page constructs them per manifest entry and merges the results into the cap-impls Map; see `lib/js_caps/index.js` for the merge pattern.

Each `lib/platform/browser_caps/<kind>/` directory holds the host-side cap impl (Lua or JS depending on whether the impl runs in the daemon or in the host stub realm), the per-kind config schema validator, and tests. The single `lib/js_realm_sandbox/` continues to lock down the realm; the cap shells are installed onto `__cap__` per-pack from the granted manifest entries.

Note that the bootstrap also installs `btoa` / `atob` (and possibly `queueMicrotask`) as direct primitives — these are not caps, but they round out the "what's actually available in the realm" picture.

## 6. Versioning, discovery, composition

### 6.1 Versioning

**Per-cap-kind semantic version.** Each cap kind has a version (`fetch_api@1`, `kv_read@1`, etc.). Pack manifests may declare the version expected:

```lua
browser_caps = {
  fetch_api = {
    kind = "fetch_api",
    kind_version = "^1",      -- semver constraint; default "^current" if absent
    config = { allowed_origins = { ... } },
  },
}
```

The host stub:

- For an exact-version pack-declared constraint, serves that version of the cap impl if it has it; rejects the install otherwise.
- For a caret/tilde constraint, serves the highest-compatible version it has.
- For a missing constraint, serves the current major version.

The host stub may ship multiple major versions of a cap kind simultaneously during a transition window. Major-version transitions are documented per cap in §4 when they happen. Minor and patch versions are additive only (new optional config fields, new args fields with defaults that match prior behavior); these never break a pack.

A breaking change is a **new major version**. The old major is supported for a documented sunset window (suggested: two minor releases of the platform — open question, §7).

The rationale for per-cap-kind versioning rather than a single "browser_caps protocol version": cap kinds evolve independently. `fetch_api` may need a v2 in three years; `toast` may stay v1 forever. Coupling them into a single version forces all packs to re-validate against the platform release, even those touching only stable cap kinds.

### 6.2 Discovery

This document is the authoritative list. Pack authors read §4 + §5 to learn what cap kinds exist and what each accepts.

A future-state goal: generate a machine-readable manifest of cap kinds from a per-cap-kind module registry, served by the daemon at a stable URL. Pack-author tooling reads the manifest to provide autocomplete + type-checking against the live cap surface of the host. Not day-zero — the markdown doc is the source of truth until then.

The single shared `.d.ts` (see `platform_isolation.md` §3 "Browser-side authoring") gets the cap signatures of all current cap kinds as `__cap__.<name>(...)` typed entries. When this doc lists a new exposed-now cap, the `.d.ts` grows the corresponding signature in the same commit.

### 6.3 Composition / attenuation

**Day zero: no sub-pack delegation.** Sub-packs are not yet a supported pack-ecosystem feature (see `platform_isolation.md` §7 "Cross-pack composition"). The cap-attenuation pattern from `platform_isolation.md` §3 ("Cap function attenuation") — pack code wrapping `__cap__.fetch_api` in a narrower closure and passing it to its own sub-modules — works within a single pack today.

**Future: per-call constraint narrowing.** When sub-packs land, the design will need:

- A way for pack A to call `__cap__.<kind>` with narrower constraints than pack A's grant (e.g. `fetch_api` against a single URL prefix rather than the whole `allowed_origins` set), and pass the resulting attenuated cap to a sub-pack.
- A host-stub-side enforcement that the sub-pack cannot upgrade the attenuated cap back to the parent's.

The mechanism is open (proxy capabilities, signed-token caps, host-mediated child-bridge channels). Defer to the sub-pack-composition design.

## 7. Open questions

Explicit, deliberately not buried in prose:

- **Final day-zero cap surface.** §5 is the proposal. The actual day-zero set will be the intersection of "in §5" and "the first real pack's needs." Some §5 entries may slip out as YAGNI; some §4 placeholders may pull in if a pack needs them at install. Subject to revision through the first pack's design cycle.
- **Per-cap-kind config schema location.** Three candidates: (a) inline schema definitions in the manifest (verbose; every pack restates the schema), (b) per-cap-kind module that exports the schema (clean; the host stub registers cap kinds and their schemas together); (c) the schema lives in this doc and gets parsed-validated at install. Leaning toward (b), but the per-cap-kind module location and shape is unspecified.
- **Streaming subscriber convention.** Subscriber-tokens-at-call-time (§2.4 default) versus pull-based listen versus both. The bridge protocol in `bridge.js` does not yet have the `event` frame implemented; the design decision here lands when WebSocket / SSE / set_interval get implemented.
- **Permission UI / grant flow shape.** Out of scope for this doc. Cross-reference to a future `docs/permission_ui.md` that covers per-install grant UI, per-invocation prompts, per-session grant lifecycle, and revocation flow.
- **Sub-pack composition / attenuation.** See §6.3. Whole design owed.
- **Versioning sunset window.** §6.1 suggests "two minor releases" without committing. Real answer ties to the platform release cadence, which is itself unsettled.
- **Cap-kind audit-detail policy.** §2.7 says "shape only by default, per-kind overrides for opt-in full-args." The list of which kinds opt in is part of each cap-kind module; this doc only says they may. The actual list should be agreed before day-zero ship.
- **Bootstrap-installed non-cap primitives.** `btoa`/`atob`, possibly `queueMicrotask`, possibly `structuredClone` polyfill. The set is small but the *boundary* — "this is a primitive, not a cap" — needs an explicit list. The single shared `.d.ts` should declare them; this doc should call them out at the boundary.
- **Multiple cap entries of the same kind.** §3's design supports `fetch_api` and `fetch_api_secondary` as two manifest entries of the same kind. Whether the host stub instantiates separate impls per entry or shares impl + per-call config is an implementation detail not yet resolved.
- **VNode rendering protocol surface (canvas, audio, media)**. Several §4 entries punt to "the VNode protocol's tag set" for the answer (canvas, audio, video, SVG). That protocol is its own design doc-to-be; until it lands, packs that need pixel-pushed media are blocked.

## 8. Status

Draft. No code committed. The doc exists to (a) lock the schema pattern for browser caps against the hardest cases in the Web Platform before any cap kind ships, (b) commit the day-zero exposed surface deliberately rather than accreting it ad-hoc, and (c) ground the next design conversations (sub-pack composition, VNode rendering protocol, permission UI) in a shared frame of what already exists at this layer.

Comments, counterproposals, "you missed Y," and "the classification of X is wrong" are all in scope. Treat nothing here as decided.
