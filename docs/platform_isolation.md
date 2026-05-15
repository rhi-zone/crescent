# Platform Isolation — Browser-Side Pack Isolation

> *Draft. Starting-point design doc. Decisions are framed as proposals with rationale; expect revision. Open questions are called out explicitly in their own section — do not read them as settled. Comments and counterproposals welcome before any of this is treated as load-bearing.*

This doc covers browser-side isolation for pack-shipped UI. The daemon-side
sandbox is described in [`daemon-isolation.md`](daemon-isolation.md); the
browser half is the parallel concern this doc opens up. Both halves are
required for the pack ecosystem; neither is sufficient alone.

## 1. Problem statement

### Today's posture

The platform daemon already does several things right at the browser layer:

- **Per-app CSP** — every response served on behalf of an app carries a
  `Content-Security-Policy` derived from that app's manifest. `connect-src`
  is restricted to `'self'` plus any operator-approved `http_client` hosts.
  `default-src 'self'` blocks ambient remote script/style. `frame-ancestors
  'none'` prevents clickjacking. `form-action 'self'` prevents form-based
  CSRF to other origins. See `lib/platform/daemon/init.lua` `build_app_csp`.
- **Origin isolation** — each app runs on `app-<id>.<daemon-host>` (or a
  distinct loopback IP). The daemon-origin session cookie is `__Host-`-prefixed
  and not sent to app origins. The app cannot impersonate the operator
  against the daemon API by virtue of being a different origin.
- **Capability scoping** — every cap the app receives is constructed with
  `context.app_id` baked in. Two apps asking for "the same cap" get two
  independent cap instances; one app's `kv` cannot read another's data.
- **Launch token flow** — apps are launched through a daemon-mediated
  grant page; the operator's grant decisions are recorded before the app
  origin gets any traffic.
- **Prototype freeze (`harden.js`)** — for the bundled system_dashboard,
  `Object.freeze` is applied to built-in prototypes at boot so pack-author
  JS cannot mutate them after the fact.

This is a credible baseline for trusted single-app development. It is
insufficient the moment packs ship browser UI.

### The ambient-capability problem

Browser JavaScript has **ambient access** to whatever the page's origin and
CSP permit. A pack-author script running inside the app's origin:

- Can `fetch()` any `connect-src` host the daemon allowed. There is no
  per-function attenuation; if any code in the page may reach a host, all
  code in the page may reach it.
- Can read and modify the entire DOM, including UI rendered by other code
  loaded into the same page.
- Has free use of `console`, `alert`, `prompt`, `confirm`, `window.open`,
  `document.title`, `history`, `location`, timing primitives, storage
  (`localStorage`, `sessionStorage`, `IndexedDB`, cookies bound to the
  origin), `navigator.*`, and every other ambient global.
- Can register event listeners, install service workers (depending on CSP),
  schedule timers, hold references that survive the user navigating away
  from the panel that needed them.

CSP narrows the *outer envelope* of what the origin can reach. It does not
partition the *inner surface* available to scripts loaded into the page.
Pack-author code today executes with the page's full ambient authority —
the same authority the host-shipped trusted code runs with.

### The current rendering boundary is not a security boundary

`lib/platform/apps/system_dashboard/static/projections/registry.js` and the
surrounding projection runtime are a *rendering* abstraction: shape-dispatch,
per-tag projections, harden-mode transpile. The lua2ts harden mode is a
JS-runtime-hazard backstop, not an isolation boundary — the transpiled
output runs in the *same* realm as the host JS, sharing globals, the same
event loop, and the same fetch authority.

`harden.js` freezes prototypes but runs *after* the first script tag. It is
hygiene against accidental mutation, not a defense against an adversary who
controls a `<script>` tag.

### Stake

This is a precondition for the pack ecosystem, not a projection-specific
concern. Any pack that ships browser UI — projections today, full pack apps
tomorrow, future card/library/import UIs — is browser-author code with
ambient page authority. The current model is acceptable while every script
on the page is host-controlled. It is not acceptable once a third pack
author's code runs on the same origin.

Initiative B (pack-load pipeline for projection Lua sources, see TODO.md)
is downstream of this design: its output has to land *into* whatever
rendering and isolation model we pick.

## 2. Threat model

Authors are **user-installed**. Trust here is closer to "browser extension"
than to "arbitrary web code" — the operator chose to install the pack and is
implicitly extending some trust. But that trust is bounded, not blanket:

- Granted caps must match declared caps. A pack must not silently acquire
  capabilities it did not declare.
- No escalation across pack boundaries. Pack A's UI must not be able to
  exfiltrate pack B's data, drive pack B's caps, or impersonate pack B
  to the operator.
- Bugs in one pack must not affect others. A crashed projection in pack A
  must not freeze the dashboard or corrupt pack B's state.
- The operator must be able to audit and kill packs. Every cap invocation
  is observable; revocation is enforceable; a runaway pack can be stopped.

Columns of concern:

### Confidentiality

- **Direct exfiltration** — fetching to an arbitrary host. Today: blocked
  by `connect-src` for hosts not on the allowlist. Missing: per-cap
  attenuation. If pack A declared `http_client(api.x.com)`, any code on
  the page can use that host, including pack B's code if both run in the
  same origin.
- **Side-channel exfiltration** — timing attacks, DOM-coupling, observable
  resource hints. Largely out of scope at this layer; partially mitigated by
  cross-origin isolation (which the proposal below tightens).
- **Render-as-encoding** — encoding exfiltrated bytes as link targets,
  navigation, `window.open`, focus changes, etc. Today: only `form-action`
  is constrained. `window.open` and `location.href` are not.
- **Storage scraping** — reading `localStorage` / `IndexedDB` from any
  script on the origin. Today: per-app origin isolates between apps, but
  *within* an app origin, all scripts share storage.

### Integrity

- **Cross-pack DOM interference** — pack A's script mutates pack B's
  rendered nodes, intercepts pack B's event handlers, or replaces pack B's
  cap-call results before they render.
- **Persistent state poisoning** — writing into shared storage that another
  pack reads. Today: per-app storage scoping limits this between apps;
  unmanaged within an app.
- **Capability misuse** — calling a granted cap with arguments outside what
  the operator imagined when granting. The cap impl is responsible for
  argument validation, but the page itself today is *one* trust principal
  per origin, not per-pack-within-an-origin.

### Availability

- **Resource abuse** — infinite loops, allocating until the tab dies,
  flooding the daemon with cap calls.
- **UI lockup** — synchronous work on the main thread that blocks the
  host shell.
- **DoS against the daemon** — a misbehaving page driving its caps faster
  than the daemon can serve them.
- **Catastrophic-backtracking regexes (ReDoS)** — an author can write or
  load a regex that takes super-linear time on adversarial input. Hits the
  iframe's main thread; sandbox doesn't help because the work is real. CSP
  doesn't help. Even pack-author-trusted regexes can have ReDoS by
  accident — `(a+)+b` style patterns.
- **String/array amplification** — `"x".repeat(1e9)`, `Array(1e9).fill(...)`,
  `JSON.stringify` on deeply-nested structures. Allocates until the tab
  dies; sandbox doesn't help. Bounded-method transpile mitigation (already
  in lua2ts harden) covers some specific cases (`padStart`/`padEnd`/`join`)
  but not `repeat`/`Array(n)`/etc.
- **Pathological JSON / parser inputs** — feeding the cap bridge or any
  host-bridged parser a deeply-nested structure that explodes during
  validation. Stub-side concern, not realm-side; worth flagging here.

Mitigations today are mostly absent. The browser's own watchdog kills
runaway tabs; that is not pack-aware. These vectors point at the need for
resource quotas at multiple layers — transpile-time bounded-method rewrites
for known DoS APIs, a realm-side wall-clock watchdog, stub-side validation
limits — rather than relying on any single mechanism.

### UI deception

- **Phishing** — pack renders fake daemon UI ("grant this cap?") and the
  operator confirms thinking it's the daemon.
- **Clickjacking** — `frame-ancestors 'none'` blocks the app being framed
  by other origins. Within the app origin, layered UI is not constrained.
- **Lookalike origins** — `pack-abc.localhost` vs `pack-abd.localhost`.
  Origin labelling and persistent grant UI is part of the answer; not
  load-bearing in this doc.

### Summary of structural gaps

CSP gates the **outer envelope** (which hosts the origin may reach). The
sandbox attribute gates which ambient browser features the document may use.
Neither partitions the **inner surface** between scripts on the page. The
proposal below targets that gap.

## 3. Architecture proposal

**Every pack-served browser app runs in a sandboxed realm with no ambient
world-state. Capabilities are bridged in by declaration plus grant.**

### Realm primitive

A cross-origin iframe with `sandbox="allow-scripts"` (and only `allow-scripts`)
plus a strict CSP:

```
default-src 'none';
script-src 'nonce-<per-load>';
connect-src 'none';
img-src 'none';
style-src 'nonce-<per-load>';
font-src 'none';
form-action 'none';
frame-ancestors 'self';
base-uri 'none';
```

The pack realm has, by construction:

- No DOM access to the host page (different origin, sandboxed).
- No fetch authority of its own (`connect-src 'none'`). All I/O goes through
  the bridge.
- No external resource loading (images, fonts, frames, forms).
- No top-level navigation (sandbox without `allow-top-navigation`).
- No same-origin storage shared with the host (sandbox without
  `allow-same-origin` produces a unique origin; `localStorage` is
  per-origin, so the host's storage is invisible).
- No popups (sandbox without `allow-popups`).

The set of `allow-*` tokens is the explicit "additive" surface. We start with
`allow-scripts` only. Anything beyond requires a written rationale tied to a
specific cap.

Per-pack-page-instance origin is desirable so that even two instances of the
same pack don't share storage in unintended ways. Mechanism is an open
question (see §7).

### Bootstrap script

The first (and possibly only) script loaded into the iframe is host-controlled,
served by the daemon, and admitted via the CSP nonce. It runs *before*
pack-author code and:

- Removes or stubs ambient globals that are not security-relevant but are
  trust-relevant: `console`, `alert`, `prompt`, `confirm`. (Routed through
  the bridge so the host can render them in a controlled way if it chooses.)
- Sets up the postMessage protocol with the host frame.
- Installs `globalThis.__cap__` — the bridge-backed cap call table.
- Optionally hardens timing primitives (`performance.now`, `Date.now`,
  `setTimeout`) where threat-model warrants.
- Then loads the pack-author entry, also via the nonce.

The bootstrap is the only code that needs to fully trust the host. Pack
author code never sees the raw postMessage channel.

### Capability bridge

`postMessage` (or `MessageChannel` for a cleaner protocol) connects the
sandboxed iframe to the *stub page* served by the daemon at a host-controlled
origin. The stub:

- Holds the user's cap grants for this pack.
- Validates every inbound message against the pack manifest's declared
  browser caps.
- Performs the side effect in its own realm — which has the real fetch
  authority for the granted hosts, the real DOM if it's painting, etc.
- Sends the result, error, or event back.

The stub is the only code with the real cap surface. The pack iframe holds
only `__cap__` proxies that round-trip through it.

### Cap function attenuation

A granted cap is exposed inside the iframe as `globalThis.__cap__.<name>(...)`.
Pack code can compose narrower wrappers and pass them on to sub-components:

```js
const fetchApi = (path, body) => __cap__.http_client({path, body});
// pack code passes fetchApi to its sub-modules; they cannot reach the
// underlying cap except via the same bridge.
```

Pack code cannot reach the original cap-fn except by going through the same
postMessage channel — and that channel only enacts caps the stub agrees the
pack declared.

### lua2ts harden mode (defense-in-depth)

Harden mode is **defense-in-depth plus authoring hygiene**, not a security
boundary. CSP (no `'unsafe-eval'`) handles `eval`/`new Function` at runtime
regardless of source. Realm isolation handles `fetch`/network globals —
they are literally absent inside the iframe. The still-load-bearing pieces
of harden are: null-prototype record creation (defends intra-realm
prototype pollution), bounded-method rewrites for known DoS-prone APIs
(`padStart`, `padEnd`, `join`, and extending to `repeat`, `Array(n).fill`,
deeply-nested JSON), and authoring-hygiene blocking of hazard identifiers
so failures land at `bin/cr check` time rather than as runtime CSP
refusals.

### Future option: ShadowRealm

When ShadowRealm ships across target browsers, the same architecture
collapses to a JS-level boundary: the realm primitive becomes a ShadowRealm
rather than an iframe, the bridge becomes a callable boundary rather than
postMessage, the bootstrap becomes the realm's first executed code. The
*shape* of the design — cap declaration, grant, bridged invocation,
attenuated reference — is unchanged. The iframe is the today-shippable
substrate; ShadowRealm is the future tightening.

## 4. Capability bridge protocol (proposal — open for revision)

### Message envelope

Iframe → stub:

```
{ id: <opaque correlation id>, cap: <string>, args: <JSON-safe value> }
```

Stub → iframe:

```
{ id, result: <JSON-safe value> }
or
{ id, error: { code: <string>, message: <string> } }
or
{ id, event: <string>, value: <JSON-safe value> }  // for streaming caps
```

Per-message correlation via `id`. Streaming caps emit multiple `event`
frames against the same `id`, terminated by a final `result` (success) or
`error` (failure).

### Cap declaration

Packs declare browser-side caps in the manifest, parallel to the existing
daemon-side cap declarations:

```
{
  "name": "my-pack",
  "caps": { "http_client": { "type": "http_client", "host": "api.x.com" } },
  "browser_caps": {
    "fetch_api": { "type": "http_client", "host": "api.x.com" },
    "toast":     { "type": "ui_toast" },
    "clipboard": { "type": "clipboard_write" }
  }
}
```

The browser-cap list is its own namespace. Some entries shadow daemon caps
(`http_client` that is actually a daemon-cap call routed through the stub);
others are browser-only (`clipboard`, `ui_toast`, `dialog`).

### Grant

The operator grants browser caps at install time, same UI flow as daemon
caps (or unified). First request without a grant triggers a grant prompt;
later requests pull from stored grants.

### Validation

The stub:

1. Looks up `msg.cap` in the pack's `browser_caps`. If absent → reject.
2. Looks up the operator's grant for that cap. If denied → reject.
3. Validates `msg.args` against the cap's argument schema.
4. Performs the effect.
5. Logs an entry (cap name, arg digest, timestamp, result kind) to the
   daemon audit log.

### Pack-side API

Synchronous-feeling, async-implemented:

```js
const data = await __cap__.fetch_api({ path: "/items" });
```

`__cap__.X(args)` returns a `Promise` that resolves on `result`, rejects on
`error`, and (for streaming caps) accepts an optional `onEvent` callback.

### Cap types (initial sketch)

- `http_client` — proxy daemon-side `http_client` cap, host-attenuated.
- `kv_read` / `kv_write` — per-pack key-value storage in the stub's realm.
- `clipboard_write` — copy to clipboard; requires explicit user gesture.
- `dialog` — host-rendered confirm/prompt with pack-supplied prompt text.
- `ui_toast` — host-rendered ephemeral notification.
- `navigate` — request the host navigate to a pack-internal route.
- `stream_subscribe` — bind to a daemon SSE source (already pack-declared).

Initial list. Expected to grow.

## 5. Rendering model — open question

The proposal above isolates *execution*. It does not pick how pack UI
*reaches the screen*. Three plausible models:

### Option A — pack owns its iframe DOM

The pack iframe contains the pack's rendered UI directly. The stub composes
iframes into a layout (CSS grid, splitter widgets, etc.).

- **Pros**: easy to author — pack writes DOM directly. Familiar mental model.
  Full DOM API available inside the realm.
- **Cons**: iframes are heavy (memory, layout). Composition between
  iframes is awkward (no native flex/grid across the boundary).
  Inter-pack DOM interaction (e.g. dragging an item from pack A into pack B)
  requires explicit inter-iframe protocols.

### Option B — pack emits virtual structure via postMessage

The pack iframe runs *no DOM at all*. It emits a virtual structure
(the projection tree, more or less) via postMessage. The stub paints it
into the host DOM, in the stub's realm.

- **Pros**: lightweight. Layout composition is trivial (it's all host DOM).
  Inter-pack interaction is host-controlled and observable.
  Natural match for the existing projection registry.
- **Cons**: the virtual-structure protocol becomes the *only* surface pack
  UI can express through. Anything the protocol doesn't allow, the pack
  can't do. Complex UIs (rich editors, canvas, audio visualizers) may not
  fit.

### Option C — hybrid

Small packs / simple projections use (B). Larger packs that need full DOM
get (A). Selection per-pack or per-route within a pack.

- **Pros**: matches the actual range of UI needs.
- **Cons**: two rendering models to maintain; pack authors pick wrong; cap
  surface differs between them.

**This is an open question. Do not pick yet.** The choice has consequences
for Initiative B (which is currently aimed at Option B by virtue of the
projection registry shape), the pack manifest schema (per-rendering-model
declarations?), and the host shell's complexity.

## 6. Migration from current state

The existing prototype work does not disappear. It moves into a different
position in the stack.

### Current state, in stack order (bottom up)

1. Daemon serves HTML / JS / CSS with per-app CSP.
2. Host JS loads via `<script type="module">` directly in the page.
3. `harden.js` freezes prototypes.
4. `projections/registry.js` and per-tag projection modules render envelopes.
5. lua2ts harden mode (planned) transpiles pack-shipped projection-Lua into
   JS that registers into the registry at runtime.

All four upper layers share the page's realm. The boundary between
host code and pack code is *type-system shaped*, not runtime shaped.

### Target state

1. Daemon serves a *stub page* per pack instance.
2. Stub page CSP allows it to render UI, hold caps, and round-trip
   postMessage with sandboxed iframes.
3. Stub page creates one sandboxed iframe per pack realm with strict CSP
   and the bootstrap script.
4. Pack code runs in the iframe; calls `__cap__.X(...)` for anything
   beyond local computation.
5. Rendering model A / B / C lands between the iframe and the screen.

### Migration steps (rough, not committed)

1. Add `browser_caps` field to manifest schema (`lib/pkg/manifest.lua`).
2. Build daemon stub-page generator (per pack, per instance).
3. Build the sandboxed-iframe host with bootstrap script and the bridge.
4. Implement initial bridge cap handlers daemon-side (`http_client`,
   `ui_toast`, `dialog`, `clipboard_write`, `kv_read/write`).
5. Pick rendering model (Option A/B/C).
6. Port `system_dashboard` to the new model. The existing projection
   registry maps cleanly to Option B; Option A requires more surgery.
7. Resume Initiative B with the rendering model in hand. lua2ts harden mode
   stays as a backstop, but the *primary* isolation boundary is the iframe,
   not the transpile.

Each step is independently committable. The earlier steps are
manifest/schema work and stub-page authoring; they do not break existing
flows. The cutover for `system_dashboard` is the big step and gates
Initiative B's resumption.

## 7. Open questions

These are explicit. They are not buried in prose because they need
decision-level attention, not skimming.

- **ShadowRealm vs iframe primitive.** Today: iframe only. Future: maybe
  both? Is the architecture worth restating in terms of "the realm primitive"
  with two backends, or do we commit to iframe forever and treat ShadowRealm
  as a non-event?
- **Rendering model.** Option A / B / C above. Has downstream consequences
  for Initiative B, manifest schema, host shell complexity.
- **DOM API surface inside the pack realm.** If we pick Option B, the pack
  realm has *no* DOM. Pack code writes pure virtual structures. If we pick
  Option A, the pack realm has the full DOM in an isolated origin. If
  hybrid, packs declare which mode in the manifest.
- **Per-pack origins.** Real subdomains
  (`pack-<id>.<n>.localhost`)? Unique `srcdoc` iframes? `blob:` URLs?
  Each has tradeoffs:
  - Subdomains require DNS or hosts-file cooperation; cleanest origin
    isolation but operationally heavier.
  - `srcdoc` gives a unique origin per load but no stable origin identity
    for storage scoping.
  - `blob:` URLs are origin-tied to the creating document; storage and
    revocation semantics need a close read.
- **Storage scope.** Per-pack-instance? Per-pack-version? What survives a
  pack reinstall? What survives a pack upgrade? The choice ties into the
  per-pack-origin choice above.
- **Cap revocation propagation.** When the operator revokes a granted cap,
  how does the active iframe learn? Polling? Stub forces an iframe reload?
  Heartbeat from stub to iframe with a "you've been revoked" message that
  the bootstrap script handles? Force-reload is simplest but disruptive
  mid-task.
- **Cross-pack composition.** Pack A renders pack B's content (e.g.
  nesting, embedding, "include this pack's projection here"). How do caps
  compose? *Principle* answer: attenuation — pack A passes pack B only a
  subset of its own caps via the bridge. *Protocol* answer: TBD. Does pack
  B get its own iframe inside pack A's iframe? Does pack A's bridge proxy
  to pack B's bridge? Who validates against whose grants?
- **Failure modes.** When the bridge times out or the iframe crashes, what
  does the operator see? What does the rest of the dashboard do? The
  current single-realm model doesn't have to answer this; the new one does.
- **Performance budget.** Each pack iframe is real memory (~1-5 MB
  baseline). At what number of concurrent packs does this become operator-
  visible? Are there strategies for sharing realms across "trusted"
  pack-bundles?
- **Testing.** What does a pack author's local development experience look
  like? They have to test their pack inside the sandbox model; the harness
  has to replicate the runtime.

## 8. Non-goals

- **This is not a security-against-adversarial-internet-code spec.**
  The threat model is user-installed packs (extension-grade trust), not
  arbitrary web content. If adversarial pack distribution becomes a
  concern, that's a separate doc with stricter assumptions.
- **This does not claim the typechecker is a sandbox.** Type-level
  hardening (lua2ts harden mode, projection prelude, JS hazard blocklist)
  is *hygiene*: it catches mistakes at build time. It is not a runtime
  boundary. Treating it as one is one of the failure modes this doc exists
  to prevent.
- **This does not address daemon-side isolation.** That's
  `daemon-isolation.md`. The two layers compose; they are designed
  independently.
- **This does not subsume CSP, origin isolation, or capability scoping.**
  Those layers stay. This proposal is *additive* — a new realm boundary
  inside the existing per-app origin, not a replacement for it.

## 9. Status

Draft. No code committed. No manifest schema changes. No daemon changes.
The doc exists to (a) ground the next session's design conversation in a
shared frame, (b) explicitly mark Initiative B and other browser-side pack
work as gated on this design being settled, and (c) collect the open
questions in one place so they can be picked off deliberately.

Comments, counterproposals, "this is wrong because X", and "you missed Y"
are all in scope. Treat nothing here as decided.
