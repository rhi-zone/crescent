# Platform Isolation — Browser-Side App Isolation

> *Draft. Starting-point design doc. Decisions are framed as proposals with rationale; expect revision. Open questions are called out explicitly in their own section — do not read them as settled. Comments and counterproposals welcome before any of this is treated as load-bearing.*

## Terminology

**App** is the only unit of installable code. Each app lives at
`lib/platform/apps/<name>/` with a `manifest.json` declaring caps and
entrypoints (per `lib/platform/platform_types.lua`: `Manifest`,
`EntryDef`, `CapDecl`). Apps shipped in the crescent source tree
(`charactercardv2`, `library`, `sillytavern`, `system_dashboard`) are
not architecturally privileged; they are user code that crescent's
team happened to author. The threat model treats them equivalently to
any user-installed app — the sandbox and cap bridge described below
apply uniformly, with no grandfathering for source-tree apps.

Earlier drafts of this doc used "pack" to mean "app." That was a
misnomer. In the current codebase, **pack** is reserved for a
declarative data structure inside `system_dashboard`
(`{ name, caps, aliases }`, see
`lib/platform/apps/system_dashboard/packs.lua`) — alias and command
config bundled inside an app's tarball, not an installable unit.
This doc now uses **app** consistently for the installable unit; the
legacy "pack" data-structure meaning is qualified explicitly wherever
it appears.

An app may ship browser-side JS (in which case it runs in a sandboxed
iframe with the cap bridge described below) OR be daemon-side-only
(no JS shipped; its UI, if any, is rendered by a separate host app
consuming structured data the app's BFF emits). That is an authoring
choice, not a trust tier. Every app that ships JS goes through the
same sandbox; the source-tree apps that today serve plain `<script>`
content from `static/` (notably `charactercardv2`) are slated for the
same migration as any third-party app — their current state is a
not-yet-migrated implementation detail, not a privilege.

This doc covers browser-side isolation for app-shipped UI. The daemon-side
sandbox is described in [`daemon-isolation.md`](daemon-isolation.md); the
browser half is the parallel concern this doc opens up. Both halves are
required for the app ecosystem; neither is sufficient alone.

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
  `Object.freeze` is applied to built-in prototypes at boot so app-author
  JS cannot mutate them after the fact.

This is a credible baseline for trusted single-app development. It is
insufficient the moment apps ship browser UI.

### The ambient-capability problem

Browser JavaScript has **ambient access** to whatever the page's origin and
CSP permit. A app-author script running inside the app's origin:

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
App-author code today executes with the page's full ambient authority —
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

This is a precondition for the app ecosystem, not a projection-specific
concern. Any app that ships browser UI — projections today, full app apps
tomorrow, future card/library/import UIs — is browser-author code with
ambient page authority. The current model is acceptable while every script
on the page is host-controlled. It is not acceptable once a third app
author's code runs on the same origin.

Initiative B (app-load pipeline for projection Lua sources, see TODO.md)
is downstream of this design: its output has to land *into* whatever
rendering and isolation model we pick.

## 2. Threat model

Authors are **user-installed**. Trust here is closer to "browser extension"
than to "arbitrary web code" — the operator chose to install the app and is
implicitly extending some trust. But that trust is bounded, not blanket:

- Granted caps must match declared caps. An app must not silently acquire
  capabilities it did not declare.
- No escalation across app boundaries. App A's UI must not be able to
  exfiltrate app B's data, drive app B's caps, or impersonate app B
  to the operator.
- Bugs in one app must not affect others. A crashed projection in app A
  must not freeze the dashboard or corrupt app B's state.
- The operator must be able to audit and kill apps. Every cap invocation
  is observable; revocation is enforceable; a runaway app can be stopped.

**Latency requirement.** UX must remain responsive even when the
browser↔daemon channel runs through VPNs and proxies (50ms to
multi-second link latency, not just loopback). This rules out architectures where every
interaction is a round-trip (vanilla LiveView/Hotwire pattern). Reactive
logic that needs sub-100ms response runs in the app's browser realm;
daemon round-trips happen async with optimistic concurrency where
applicable. The §8 server-rendering rejection follows from this.

Columns of concern:

### Confidentiality

- **Direct exfiltration** — fetching to an arbitrary host. Today: blocked
  by `connect-src` for hosts not on the allowlist. Missing: per-cap
  attenuation. If app A declared `http_client(api.x.com)`, any code on
  the page can use that host, including app B's code if both run in the
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

- **Cross-app DOM interference** — app A's script mutates app B's
  rendered nodes, intercepts app B's event handlers, or replaces app B's
  cap-call results before they render.
- **Persistent state poisoning** — writing into shared storage that another
  app reads. Today: per-app storage scoping limits this between apps;
  unmanaged within an app.
- **Capability misuse** — calling a granted cap with arguments outside what
  the operator imagined when granting. The cap impl is responsible for
  argument validation, but the page itself today is *one* trust principal
  per origin, not per-app-within-an-origin.

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
  doesn't help. Even app-author-trusted regexes can have ReDoS by
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
runaway tabs; that is not app-aware. These vectors point at the need for
resource quotas at multiple layers — transpile-time bounded-method rewrites
for known DoS APIs, a realm-side wall-clock watchdog, stub-side validation
limits — rather than relying on any single mechanism.

### UI deception

- **Phishing** — app renders fake daemon UI ("grant this cap?") and the
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

**Every app-served browser app runs in a sandboxed realm with no ambient
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

The app realm has, by construction:

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

### Allow-list realm, not deny-list

The realm starts with JS language primitives only — `Object`, `Array`,
`Math`, `JSON`, the primitive constructors — and **nothing** of the host
environment. No `document`, `Element`, `Node`, `fetch`, `setTimeout`,
`navigator`, `location`, `history`. Whatever the app realm needs comes
through capabilities the host explicitly bridges in.

The bootstrap script enforces this structurally:

```js
for (const k of Object.getOwnPropertyNames(globalThis))
  if (!allow.has(k)) delete globalThis[k];
// then seal what remains
```

The framing is "allow only X, Y, Z; everything else is structurally absent,"
not "block X, Y, Z." Deny-lists rot as the browser ships new APIs; an
allow-list does not. When ShadowRealm ships, it provides the same shape
natively via the realm primitive itself, in place of bootstrap-stripping.

Per-app-page-instance origin is desirable so that even two instances of the
same app don't share storage in unintended ways. Mechanism is an open
question (see §7).

### Bootstrap script

The first (and possibly only) script loaded into the iframe is host-controlled,
served by the daemon, and admitted via the CSP nonce. It runs *before*
app-author code and:

- Applies the allow-list strip described above: deletes every property of
  `globalThis` not on the explicit allow-list, then seals what remains.
  After this runs the realm has language primitives and nothing else.
- Sets up the postMessage protocol with the host frame.
- Installs `globalThis.__cap__` — the bridge-backed cap call table.
- Re-installs controlled equivalents of trust-relevant primitives that the
  app legitimately needs (`console`, `alert`, `prompt`, `confirm`,
  bridge-mediated timing primitives) — these are cap-bridge tokens, not the
  host globals.
- Then loads the app-author entry, also via the nonce.

The bootstrap is the only code that needs to fully trust the host. App
author code never sees the raw postMessage channel.

**URL convention for browser-side platform code.** The daemon serves the
browser-side platform libraries (`lib/js_pack_host/`, `lib/js_realm_sandbox/`,
`lib/js_cap_bridge/`, `lib/js_safe_regex/`, `lib/js_caps/`) under the prefix
`/_platform/lib/<js_pkg>/<file>.js`. Both the daemon origin and the per-app
subdomains expose the same URL space — app iframes are cross-origin by
construction, so a stable address reachable from every origin is mandatory.
Responses are served as `text/javascript; charset=utf-8` with
`Access-Control-Allow-Origin: *` (these files are bootstrap glue, not
secrets). Only `js_*` packages and `.js` files match; Lua source is
unreachable through this route and path traversal is rejected before any
filesystem read. Cache-busting query strings (`?v=<hash>`) are accepted but
ignored for resolution. This is Phase A; later phases attach app-script
strict-mode prepend, per-app HTML stubs, and CSP headers.

### Realm lockdown (allow-list)

**Resolved: in-house allow-list lockdown.** The realm is defined
positively — bootstrap installs exactly the intrinsics listed in the
allow-list specification (next subsection) and the host-bridged caps,
and structurally deletes everything else. SES becomes *reference
material*: its safe-intrinsics whitelist and neutralisation logic are
the authoritative engineering source to read while implementing
crescent's lockdown, not a runtime dependency to vendor.

**Bootstrap-delete-globals alone is insufficient.** The `Function`
constructor is reachable via prototype chain even after `delete
globalThis.Function`:

```js
const F = ({}).__proto__.constructor.constructor;
F("return 1")(); // works — F is Function
// also: (function(){}).constructor === Function
// AsyncFunction, GeneratorFunction, AsyncGeneratorFunction — similar shadows
```

Closing this requires walking every kept intrinsic prototype,
neutralising `.constructor` slots, and removing the
`AsyncFunction` / `GeneratorFunction` / `AsyncGeneratorFunction`
shadow constructors. The allow-list framing makes this a positive
construction: the constructors aren't in the list, so they're absent;
the prototype-chain escape class is closed by *absence*, not by
patching a known-list of dangerous slots.

**Why allow-list, not SES.** The "TC39 catch-up gap" only exists for
deny-list approaches: SES enumerates dangerous intrinsics, and new
features can ship outside the list. Allow-list inverts the framing —
the realm has exactly the primitives we declare, and new TC39
features are absent by construction. The "code outside the lockdown
context" failure mode that recurs in SES post-mortems is a
mixed-trust-app deployment hazard; crescent's deployment has one
trust boundary (the iframe bootstrap), and we own the whole iframe.
SES's deny-list framing exists for backwards-compat with existing JS
libraries that use the wider intrinsic surface — app code targets
*our* allow-list, so we don't carry that compat tax.

WASM-based approaches become unnecessary for the structural-isolation
argument: once the allow-list realm is structurally tight, the
prototype-chain escape class is already closed. WASM's 500kb bundle
no longer earns its keep. (WASM remains an option if a future threat
model genuinely needs it — see §8.)

**Alternatives considered** are catalogued in §8.

### Allow-list specification (draft)

> *Draft. This is the spec the bootstrap implements — per-intrinsic
> kept/removed lists, bootstrap order, escape-test corpus. The
> per-intrinsic lists are the starting point an implementer reads,
> not the final word; expect tightening as the corpus grows.*

#### Declared intent

The realm bootstrap removes everything from `globalThis` and from
every reachable intrinsic prototype except the items below. Kept
slots are sealed (non-configurable, non-writable) after installation.
Anything not listed is deleted; non-deletable host-provided slots are
replaced with `undefined`-returning getters.

#### Intrinsics

- **`Object` constructor.** Kept: `keys`, `values`, `entries`,
  `freeze`, `isFrozen`, `assign` (shallow-only semantics). Removed:
  `create`, `defineProperty`, `defineProperties`, `getPrototypeOf`,
  `setPrototypeOf`, `getOwnPropertyDescriptor`,
  `getOwnPropertyDescriptors`, `getOwnPropertyNames`,
  `getOwnPropertySymbols`, `preventExtensions`, `seal`, `isSealed`,
  `isExtensible`, `fromEntries`. Justification: every removed method
  is a reflection or constructor-reach path.
- **`Object.prototype`.** Kept: `toString`, `hasOwnProperty`. Removed:
  `__proto__` getter/setter, `__defineGetter__`, `__defineSetter__`,
  `__lookupGetter__`, `__lookupSetter__`, `propertyIsEnumerable`,
  `isPrototypeOf`. Justification: prototype-access / mutation reach.
- **`Function` constructor.** Removed entirely. Closes
  `new Function("...")`.
- **`Function.prototype`.** Kept: `call`, `apply`. `bind` replaced
  (see below). `.constructor` neutralised (`undefined`,
  non-configurable). `toString` removed (function-source leak).
  **`Function.prototype.bind`**: replaced with a non-constructable
  wrapper. The wrapper preserves call semantics, `.length`, and
  `.name` (per native bind spec), but its returned function has no
  `[[Construct]]` slot. `new bound()` and `class X extends bound {}`
  both throw `TypeError`. Achieved via concise method syntax
  (`{ bound(...args) {...} }.bound`) or arrow function — both produce
  callables without `[[Construct]]`. Reference: endo's
  `makeEvalFunction` (`packages/ses/src/make-eval-function.js`) uses
  the same pattern for `eval`. (Supersedes the earlier "bind kept
  after adversarial review" verdict — that was conditional on
  daemon-side parser enforcement of the `class` ban, which is no
  longer assumed; see "App-source validation".)

##### Non-constructable wrapper pattern

Any callable installed into the realm that doesn't need to be a
constructor SHOULD have its `[[Construct]]` slot removed. This is a
uniform application of least-privilege at the function-shape level.
Reduces attack surface against any future class-extends-`X` vector.

Apply this to:

- **`Function.prototype.bind` replacement** (above).
- **Host-bridged caps**: when installing `opts.caps` onto the curated
  `__cap__` namespace, wrap each in a non-constructable shell:
  ```js
  const safeCap = { [name](...args) { return cap(...args); } }[name];
  ```
  App code can't `new __cap__.foo(...)` to trigger constructor
  semantics on a function the host didn't intend to be constructable.
- **All bootstrap-installed wrappers** (bounded methods, regex
  wrappers, etc.): authored as concise method syntax or arrow
  functions, NOT as `function () {...}` (which has `[[Construct]]`).
  Audit-required.
- **`eval` equivalents** if any exposed (none currently; pattern
  applies if it ever becomes one).

Two equivalent techniques: arrow function (no `[[Construct]]`, no own
`this`) and concise method syntax (no `[[Construct]]`, has own
`this`). Pick concise method when caller's `this` matters; arrow
function for pure delegation.
- **`AsyncFunction` / `GeneratorFunction` / `AsyncGeneratorFunction`
  constructors.** Removed entirely; the corresponding
  `.prototype.constructor` slots neutralised to close shadow paths.
  Source-level `async function` / `await` remain allowed (see
  "Language-level constraints"); only the dynamic-construction-from-string
  path is closed.
- **`Array` constructor.** Kept, wrapped: throws if `n > SIZE_CAP`.
  Most prototype methods kept;
  `join` / `fill` / `flat` / `flatMap` replaced with bounded versions.
- **`String` constructor and prototype.** Kept; bounded
  `padStart` / `padEnd` / `repeat` / `normalize` (output-length cap
  `SIZE_CAP`).
  Regex methods (`match`, `matchAll`, `replace`, `split`) wrapped
  with an input-size cap and optional regex-shape check.
- **`Number`, `Boolean`, `BigInt`.** Kept full.
- **`Math`.** Kept full (no security-relevant state).
- **`JSON`.** `stringify` / `parse` wrapped with input-size cap,
  output-size cap (both `SIZE_CAP`), depth cap.
- **Size cap (`SIZE_CAP`).** Single canonical value. Default: **128M
  (`2^27 = 134_217_728`)**. Configurable per-app via manifest entry; a
  app manifest may declare a *lower* cap to constrain itself further,
  but cannot exceed the default. Enforced uniformly on every known
  amplifier path:
  - `Array(n)` constructor.
  - `Array.from(arrayLike)` and `Array.from(iterable, mapFn)` — check
    `arrayLike.length` or iterator count against the cap.
  - `Array.of(...args)` — cap argument count.
  - `String.fromCharCode(...args)` / `String.fromCodePoint(...args)`
    — cap argument count.
  - `String.prototype.repeat` / `padStart` / `padEnd` — cap output
    length.
  - `Array.prototype.join` / `flat` / `flatMap` — cap output length.
  - `JSON.stringify` (output size) and `JSON.parse` (input size +
    depth).

  `SIZE_CAP` is per-operation, not a realm-wide live-allocation
  budget. An app issuing many cap-sized operations can still exhaust
  the tab; the wall-clock + memory watchdog (§2) is the
  defence-in-depth for that.
- **`Date` / `performance.now` / `Date.now`.** Kept as the browser
  provides them — no custom coarsening layer. The realm relies on the
  browser's built-in Spectre-mitigation coarsening of `performance.now`
  (~5μs or ~100μs depending on COOP/COEP cross-origin-isolated state).
  Adding our own coarsening on top is redundant with the browser's
  protection and reduces UX fidelity.
- **`Promise`.** Kept. Microtask scheduling is a timing channel; we
  accept this (no JS sandbox defends against it).
- **`Map`, `Set`, `WeakMap`, `WeakSet`.** Kept. `WeakRef` and
  `FinalizationRegistry` removed (GC observation).
- **`Symbol`.** Kept; `Symbol.unscopables` and any reflection-relevant
  well-known symbols neutralised. **`Symbol.for` and `Symbol.keyFor`
  removed** — the well-known symbol registry is process-wide and
  cross-realm, and a covert side-channel between two app realms in
  the same agent cluster has no legitimate use. Local symbols
  (`Symbol("desc")`) remain available.
- **`Object.prototype.toString`** is kept (callers rely on
  `.toString()` working on arbitrary values). It leaks `[[Class]]`
  brand info (e.g. `Object.prototype.toString.call([])` returns
  `"[object Array]"`). Accepted as a side channel; no attempt to
  mask. If brand-fingerprinting of bridged values becomes a concern,
  replace with a brand-agnostic version returning `"[object Object]"`
  for everything.
- **`Error` / `TypeError` / `SyntaxError` / `RangeError` /
  `ReferenceError` / `URIError` / `EvalError` / `AggregateError`.**
  Kept as types. `.stack` neutralised on each prototype — getter
  returns an empty string (or a fixed placeholder) so app code
  cannot introspect bootstrap or bridge source paths.
  `Error.captureStackTrace`, `Error.stackTraceLimit`, and
  `Error.prepareStackTrace` (V8) are removed. `.prototype.constructor`
  neutralised like every other kept prototype.
- **`RegExp` static legacy properties** (`$1`–`$9`, `input`,
  `leftContext`, `rightContext`, `lastMatch`, `lastParen`, plus the
  `$_` / `$&` / `` $` `` / `$'` / `$+` aliases): all neutralised —
  getter returns empty string or `undefined`. These are global
  state shared across every regex operation in the realm, including
  bootstrap and bridge code, and would leak last-match contents.
  `RegExp.prototype.compile` removed.
- **Anonymous iterator prototypes** (e.g. `%IteratorPrototype%`,
  `%ArrayIteratorPrototype%`, `%StringIteratorPrototype%`,
  `%MapIteratorPrototype%`, `%SetIteratorPrototype%`,
  `%RegExpStringIteratorPrototype%`, `%TypedArrayPrototype%`): walk
  reachable via `Symbol.iterator` calls on allowed intrinsics; freeze
  and neutralise their `.constructor` slot like other prototypes.
  (Generator and async iterator prototypes are inert because their
  constructors are removed.)
- **`Proxy`, `Reflect`.** Removed entirely. Powerful reflection; app
  code does not need these.
- **`ArrayBuffer`, `DataView`, typed-array family.** Kept (real use
  cases). `SharedArrayBuffer` removed (cross-thread / Spectre).
- **`eval`, `Function`, dynamic `import()`.** Removed.
- **Module / loader globals.** None in this realm.
- **`globalThis`.** Curated namespace object — a fresh object
  containing only the allow-listed names, constructed by the
  bootstrap *before* app code loads. App-side references to
  `globalThis` resolve to this curated object, never to the real
  realm global (which would leak `eval`, `Function`, and the rest).
  The curated `globalThis` is itself `Object.freeze`d at the end of
  bootstrap (see step 6) so app code cannot add, replace, or shadow
  host-installed slots on it. `__cap__` is installed via
  `defineProperty` with `writable:false, configurable:false` *before*
  the freeze. App code can still create its own local variables; it
  just cannot mutate the realm root.
- **Host-bridged caps.** Installed by name as declared in the app
  manifest, after lockdown completes.

**Library location.** The lockdown library lives at
`lib/js_realm_sandbox/`. Convention: **`lib/js_*/` prefix for
browser-side libraries**, parallel to plain `lib/<name>/` for
daemon/general libraries.

#### App-source validation (author-side hygiene)

**Resolved: the daemon enforces no parser-side rules. The runtime
sandbox (`lib/js_realm_sandbox/`) is the security boundary, period.**
An earlier revision called for daemon-side parse-and-validate at
app-load using a vendored JS parser (acorn or equivalent). Rejected
because:

- Bundling bun (or any JS interpreter) into crescent's runtime
  distribution violates zero-dependency.
- A Lua-native JS parser is multi-week effort and a maintenance
  burden.
- Acorn-as-WASM has no clean off-the-shelf path.

Therefore: **daemon enforces no parser-side rules.** All
language-level constraints that the parser-side rules covered are
either handled at runtime (eval, Function constructor, dynamic import
via CSP, `with` via strict mode, class-extends-bind via patched-bind),
OR become author hygiene (no daemon enforcement, recommended-tool
only).

A `lib/js_pack_validator/` library (author hygiene tool, JS+bun,
optional) will exist for authors to validate during dev/CI before
publishing. It is NOT in the daemon critical path.

**Prior art: hologram.** `~/git/exoplace/hologram/src/logic/expr-compiler.ts`
validates expressions against a restricted grammar at compile time;
the attack surface is enumerable from the grammar definition itself.
The app-JS subset documented below is the *recommended* author-side
shape the optional validator enforces — same allow-list-of-AST-shapes
principle, but applied as author hygiene rather than a daemon gate.

#### App JS subset (draft)

> *Draft. The app-author's recommended subset, enforced by the
> optional `lib/js_pack_validator/` author tool. Not a daemon
> requirement — the daemon serves whatever the author ships; the
> runtime sandbox is the security boundary. Invites revision.*

**Allowed AST node types:**

- Function declarations and expressions (including arrow functions).
- Variable declarations: `let`, `const`, `var`.
- Control flow: `if` / `else`, `for` (C-style, `for-of`, `for-in`),
  `while`, `do-while`, `switch`, `try` / `catch` / `finally`,
  `break`, `continue`, `return`, `throw`.
- Literals: numeric, string, template (untagged), boolean, null,
  regex literal, array literal, object literal.
- Operators: arithmetic, comparison, logical, bitwise, ternary,
  nullish, optional chaining, spread (in calls and literals).
- Member access: dot notation.
- Member access: bracket notation **with literal-string or
  numeric-literal keys only** (no dynamic keys).
- Call expressions.
- `new` expressions **against allow-listed constructor identifiers
  only** (allowed constructors enumerated below).
- `async function` / `await`.
- Destructuring (object + array).
- Modules: `export` / `import` (static only, no dynamic `import()`).

**Banned AST node types:**

- `ClassDeclaration` / `ClassExpression` — banned in both forms;
  `extends <any-expression>` is the load-bearing ban (see
  `Function.prototype` bind rationale).
- `MetaProperty` of kind `import.meta` (or any other unspecified
  meta).
- `WithStatement` — legacy reflection.
- `YieldExpression` / generator function syntax (`function*`,
  `async function*`).
- Tagged template literals — `String.raw` is benign but custom tags
  execute arbitrary code per template; eval-equivalent in some
  idioms.
- Dynamic `import()` — `ImportExpression` node.
- `Identifier` nodes resolving to banned globals (`eval`, `Function`,
  `AsyncFunction`, etc.) in *any* context — the validator walks
  identifier references and rejects.

**Restricted forms:**

- Bracket member access (`obj[expr]`) where `expr` is not a literal
  is rejected. Forces all dynamic property access through explicit
  app code (or the cap bridge).
- `new SomeName(...)` where `SomeName` is not in the allow-listed
  constructor set is rejected. Allow list: `Array`, `Object`,
  `String`, `Number`, `Boolean`, `Map`, `Set`, `Date`, `Promise`,
  `RegExp`, `Error` (and its subclasses), `ArrayBuffer`, `DataView`,
  `Uint8Array` and the TypedArray family — plus any app-side
  function names defined in the same module (these become
  constructable; app-author responsibility for those).

**Open questions for the subset:**

- Object spread / rest patterns with computed property keys — allow,
  or restrict to literal keys?
- `Proxy` / `Reflect` are runtime-removed; their identifiers should
  also be rejected at parse time for early failure.
- Symbol literals — only well-known symbols whose identifier is
  whitelisted, or any local `Symbol("desc")`?
- Top-level `await` — allowed in ESM; decide.

#### Regex validation

Three sites turn strings into regex patterns; all three are validated
by the same safe-regex check.

**Validator algorithm.** Hologram-style single-pass parser enforcing
"no quantifier (`*`, `+`, `?`, `{n,m}`) may be applied to an
expression that itself contains a quantifier." Catches
catastrophic-backtracking patterns like `(a+)+b`. Stronger variants
(alternation overlap analysis, full Thompson-NFA construction with
state-explosion check) are a future improvement; the simple
invariant covers the common attack class. Reference implementation:
`~/git/exoplace/hologram/src/logic/safe-regex.ts`.

**Site 1: Regex literals (`/pattern/flags`).** Runtime. The realm's
`RegExp` constructor wrapper sees literal-built regex objects through
the same path it sees `new RegExp` calls (via `.source`). The
optional `lib/js_pack_validator/` author tool may additionally walk
every `Literal` node with a `regex` field at author time for early
feedback, but the load-bearing check is runtime.

**Site 2: `new RegExp(pat, flags)`.** Runtime. The realm-installed
`RegExp` constructor wrapper runs the safe-regex check on `pat`
before delegating to the native constructor. (Author-side static
hygiene via the optional validator is welcome but not load-bearing.)

**Site 3: `String.prototype.match(pat)`, `.matchAll(pat)`,
`.search(pat)`.** These methods implicitly coerce a string `pat` to
a regex via `new RegExp(pat)` internally. Validate at runtime via
the realm-installed prototype-method wrapper. (Note: `.replace` /
`.replaceAll` / `.split` treat string args as literal, not regex —
they do NOT need this check.)

**Shared verdict cache.** Realm-installed at bootstrap:

- Key: pattern string.
- Value: `safe` | `unsafe`.
- LRU-bounded (default ~1024 entries; tune if needed). Eviction
  prevents app-driven memory growth.
- Sealed in the bootstrap closure; app cannot read or mutate.
- Used by the `new RegExp` wrapper, the `match` / `matchAll` /
  `search` wrappers, and any future site that needs pattern
  validation.
- **Verdict only, not compiled object.** Regex objects have mutable
  `lastIndex`; caching and sharing instances would corrupt
  iteration state across app callers. Construction is cheap; only
  validation is worth caching.

A single helper `validatePattern(patternString) -> safe | throws`
is consulted by all wrappers. After verdict-safe, the wrapper builds
a fresh regex per call (or, for the `String.prototype.*` path,
delegates to the underlying native method which builds its own).

#### Language-level constraints

The bootstrap-side runtime defends against the load-bearing
language-level vectors (bind patched non-constructable closes
class-extends-bind; strict mode forced via daemon-side prepend
closes `with` and sloppy-`this`); the rest become author hygiene,
recommended via `lib/js_pack_validator/` but not daemon-enforced.

- `class` syntax — author hygiene only (recommended off). The
  load-bearing `extends <bound>` vector is closed structurally by
  the non-constructable bind wrapper (see `Function.prototype`
  entry), so the class ban is no longer security-load-bearing.
  `extends <any-expression>` against other reachable values
  remains a recommended-against pattern; the validator flags it.
- Generators / `function*` — author hygiene only. Source-level
  generators are inert because `GeneratorFunction` is removed and
  the iterator prototypes are neutralised; generator syntax in
  source has no escape path, but is recommended-against for
  consistency.
- `async function` / `await` — kept (source-level allowed;
  `AsyncFunction` constructor removed, so dynamic construction from
  string is blocked while normal async/await syntax remains
  available).
- `with` statement — closed structurally by strict-mode loading
  (strict mode forbids `with`). No author-side check needed; the
  syntax errors at parse time inside a strict script.
- `eval` keyword and `Function` constructor in source — already
  removed at runtime; author validator may flag for early feedback.
- **Strict mode is daemon-side enforced.** The daemon prepends
  `'use strict';` to every served app JS file (string concat at
  serve time), OR serves with `Content-Type: text/javascript`
  inside a `<script type='module'>` (ESM is strict by default).
  Either path is absolute and trivial; app-author can't opt out.
  This is the load-bearing strict-mode mechanism. Non-strict mode
  is forbidden because `this` in a sloppy-mode function returns the
  realm's `globalThis`, which the curated-namespace approach
  assumes is unreachable as a free `this`. The bootstrap *assumes*
  strict; it does not have to enforce it.

#### Bootstrap order

1. Capture references to original intrinsics in a closure, before
   any modification.
2. Delete or replace global slots not on the allow-list.
3. Walk every kept intrinsic prototype; replace methods with the
   wrapped/bounded versions or `undefined`.
4. Neutralise `.constructor` slots on every kept prototype.
5. Install host-bridged caps under their declared names.
6. `Object.freeze` every kept intrinsic and its prototype, **and the
   curated `globalThis` namespace object itself**, so app code
   cannot add, replace, or shadow host-installed properties on it.
   `__cap__` is installed via `defineProperty` with `writable:false,
   configurable:false` *before* this freeze.
7. Load app code (in strict mode — see "Language-level constraints").

#### Escape-test corpus

The implementation MUST defeat all of these. This corpus is *the*
spec the lockdown must satisfy; these are the regression tests, and
the implementation isn't done until each one either throws or
returns a safe value.

- `({}).__proto__.constructor.constructor`
- `({}).constructor.constructor`
- `(function(){}).constructor`
- `(async function(){}).constructor`
- `(function*(){}).constructor`
- `(async function*(){}).constructor`
- `Object.getPrototypeOf({}).constructor`
- `Reflect.getPrototypeOf({}).constructor`
- `Object.create({}).__proto__.constructor`
- `[].constructor.constructor`
- `"".constructor.constructor`
- `(/x/).constructor.constructor`
- `(new Error()).constructor.constructor`
- All `__proto__` mutation attempts
- All `Object.setPrototypeOf` calls
- String / Array DoS: `"x".repeat(1e9)`, `Array(1e9).fill(0)`,
  deep JSON, ReDoS regex
- Dynamic `import("data:...")`
- Source-level `eval("...")`, `new Function("...")`
- `new Error().stack` — must return `""` or a fixed placeholder.
- `"abc".match(/(a)/); RegExp.$1` — must return `""` or `undefined`.
- `Array.from({length: 1e9}, () => 0)` — must throw above `SIZE_CAP`.
- `Array.of(...Array(1e9))` — must throw above `SIZE_CAP`.
- `String.fromCharCode.apply(null, Array(1e9))` — must throw above
  `SIZE_CAP`.
- `Symbol.for("x")` — must throw or return `undefined` (removed).
- `globalThis.__cap__ = "evil"` — must throw (curated `globalThis`
  frozen).
- `class X extends [].constructor.bind() {}` — must throw at class
  evaluation (the bound function has no `[[Construct]]` slot, so
  `extends` rejects it).
- `new ([].constructor.bind())()` — must throw `TypeError` (bound
  wrapper non-constructable).

### Browser-side authoring

**Primary source format: JS + JSDoc.** Standard JS with type annotations
in JSDoc comments. Runs in the browser directly with no transpile step
(comments stripped at parse). Type-checked in the author's dev
environment via the TypeScript Language Server with `// @ts-check` (TS
LSP natively supports JSDoc). No bundled compiler; no `tsc` shipped
with apps; no Lua typechecker shipped with apps.

**lua2ts is an optional source path.** Authors who prefer Lua can
transpile via lua2ts; the output target should be JS + JSDoc so the
distributed form is uniform regardless of source. Existing lua2ts
harden mode contributes when Lua is the source; for JS + JSDoc sources,
harden's role is the static authoring-hygiene checks (banned-API source
patterns) at `bin/cr check` time. lua2ts is *free* — we maintain it for
other reasons; using it is opt-in for browser-side authoring.

**Why not TypeScript with `.ts` source format?** App distribution would
need to ship the TS compiler (~10MB) or require app authors to
pre-build. JS + JSDoc gets the same type-safety benefits with zero
toolchain cost (browsers run JS; TS LSP type-checks JSDoc in the
author's dev env).

**Why not Lua as mandatory source?** Would require shipping a Lua
typechecker plus transpiler bundle with the platform. Authors who
already know JS shouldn't be forced through that ceremony. Lua remains
crescent's daemon language.

**Single shared `.d.ts`** (not per-app) declares: the JS language
primitives in the realm allow-list, the cap signatures (signed by the
host), the VNode / `Element` type for return values, and the cap-bridge
protocol message shape. App authors reference this `.d.ts` to get
type-checking against the actual realm shape. Single source of truth —
when the allow-list or cap protocol evolves, one file changes and apps
re-typecheck against the updated declarations. Location TBD; candidates
include `lib/platform/browser_types.d.ts` or a daemon-served static
asset. Open question.

### Capability bridge

`postMessage` (or `MessageChannel` for a cleaner protocol) connects the
sandboxed iframe to the *stub page* served by the daemon at a host-controlled
origin. The stub:

- Holds the user's cap grants for this app.
- Validates every inbound message against the app manifest's declared
  browser caps.
- Performs the side effect in its own realm — which has the real fetch
  authority for the granted hosts, the real DOM if it's painting, etc.
- Sends the result, error, or event back.

The stub is the only code with the real cap surface. The app iframe holds
only `__cap__` proxies that round-trip through it.

### Cap function attenuation

A granted cap is exposed inside the iframe as `globalThis.__cap__.<name>(...)`.
App code can compose narrower wrappers and pass them on to sub-components:

```js
const fetchApi = (path, body) => __cap__.http_client({path, body});
// app code passes fetchApi to its sub-modules; they cannot reach the
// underlying cap except via the same bridge.
```

App code cannot reach the original cap-fn except by going through the same
postMessage channel — and that channel only enacts caps the stub agrees the
app declared.

### lua2ts harden mode (defense-in-depth)

Harden mode is **defense-in-depth plus authoring hygiene**, not a security
boundary. CSP (no `'unsafe-eval'`) and realm isolation do the heavy
runtime lifting. Harden's still-load-bearing pieces:

- **Statically banned APIs.** `eval`, `new Function`, `Function`
  constructor, string-form `setTimeout`/`setInterval`, dynamic `import()`,
  direct DOM APIs (`document.createElement`, `innerHTML`/`outerHTML`
  setters, `setAttribute` on event-handler keys), `__proto__` mutation,
  `Object.setPrototypeOf`. The justification is *not* "bootstrap can't
  replace these at runtime" — bootstrap can (with
  `Object.defineProperty` non-configurable on the relevant slots, plus
  the prototype-chain neutralisation discussed under "Realm lockdown"
  above). The actual justifications are:
  - **Authoring DX.** Error at `bin/cr check` time rather than runtime
    in browser devtools. Shorter feedback loop, pre-deploy.
  - **Belt-and-braces / defense in depth.** Bootstrap is one
    independent layer; the static check is another. If a future browser
    ships a new escape path, the static block still catches obvious
    patterns.
  - **Smell flagging.** `eval(...)` in source is a code smell regardless
    of whether runtime blocks it. Static block forces authors to surface
    intent (and optionally a manifest-declared exception).

  Direct DOM API access lands in the banned set, not in "preferred
  patterns" — bypassing the structured builder (`dom.span()` and
  similar) bypasses prop validation, the cap-bridge for events, and the
  rendering-model invariants.
- **Null-prototype record creation** (`__rec({...})`) — intra-realm
  prototype-pollution defense.
- **Bounded-method patches — once-per-realm in bootstrap.** The
  *primary* mitigation for known DoS-prone APIs is bootstrap-installed
  bounded versions on the relevant prototypes:
  `String.prototype.padStart`/`padEnd`/`repeat`,
  `Array.prototype.join`, the `Array` constructor, `JSON.stringify` /
  `JSON.parse`. Replaced once at realm bootstrap with bounded versions,
  sealed (non-configurable) so an adversary inside the realm cannot
  re-patch them. Per-call-site rewrites in lua2ts harden become
  belt-and-braces (catch the call at source level too); the
  load-bearing defense is the realm-level patch. Regex ReDoS
  mitigation is resolved separately — see "Regex validation" under
  §3 (three sites, shared verdict cache, hologram-shaped
  quantifier-on-quantifier check).
- **Authoring hygiene** — failures land at `bin/cr check` time rather
  than as runtime CSP refusals in browser devtools.

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

Apps declare browser-side caps in the manifest, parallel to the existing
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

1. Looks up `msg.cap` in the app's `browser_caps`. If absent → reject.
2. Looks up the operator's grant for that cap. If denied → reject.
3. Validates `msg.args` against the cap's argument schema.
4. Performs the effect.
5. Logs an entry (cap name, arg digest, timestamp, result kind) to the
   daemon audit log.

**No implicit coercion of app-supplied values.** A cap implementation
that receives an app value and does `String(value)`, `"" + value`, or
arithmetic on it triggers `Symbol.toPrimitive` / `valueOf` /
`toString` callbacks, which run synchronously back in the app realm
on the host's stack. Always treat app values as opaque: validate
shape against the declared cap argument type before any operation
that might trigger coercion, and prefer structured-clone semantics
(`postMessage`-style) at the bridge boundary so coercion cannot
occur. Symmetrically, stub→app values must be pre-serialised
JSON-safe values, never thenables the stub did not construct
itself — `Promise.resolve(thenable)` invokes `thenable.then` and
foreign thenables are app-controlled callable surface.

### App-side API

Synchronous-feeling, async-implemented:

```js
const data = await __cap__.fetch_api({ path: "/items" });
```

`__cap__.X(args)` returns a `Promise` that resolves on `result`, rejects on
`error`, and (for streaming caps) accepts an optional `onEvent` callback.

### Cap types (initial sketch)

- `http_client` — proxy daemon-side `http_client` cap, host-attenuated.
- `kv_read` / `kv_write` — per-app key-value storage in the stub's realm.
- `clipboard_write` — copy to clipboard; requires explicit user gesture.
- `dialog` — host-rendered confirm/prompt with app-supplied prompt text.
- `ui_toast` — host-rendered ephemeral notification.
- `navigate` — request the host navigate to a app-internal route.
- `stream_subscribe` — bind to a daemon SSE source (already app-declared).

Initial list. Expected to grow. **See [`browser_caps.md`](browser_caps.md)** for the comprehensive Web-Platform-API enumeration, per-cap schema pattern (entry args, return type, async/event surface, lockdown, permission, audit), the day-zero exposed cap surface, and versioning/discovery/composition decisions. Every "cap" reference in this doc should be read against that enumeration; this section is the protocol sketch, `browser_caps.md` is the cap-kind catalog.

### Cancellation via AbortSignal

Cap calls with AbortSignal args support cancellation. The realm-side bridge intercepts AbortSignal instances in cap args before sending the call message: it stores the signal locally, sets up an abort listener, and replaces the signal in the wire-args with a marker (`{__cap_signal: true, ref: <local-id>}`). On `signal.aborted`, the bridge sends a `{id, kind: "cancel"}` message keyed to the call's correlation id. The host-side bridge receives the call, creates a fresh `AbortController` on the host side, replaces the marker with `controller.signal` in the args passed to the impl, and stores the controller keyed by correlation id. On `{kind: "cancel"}` for that id, the host aborts the controller; the cap impl's underlying operation responds (e.g. `fetch(url, {signal})` rejects; a setTimeout wrapper calls `clearTimeout`). The app-realm Promise rejects with an `AbortError`.

This applies to any long-running cap. AbortSignal is the standard JS primitive for cancellation; using it consistently avoids inventing a parallel cancel API and matches what app authors already know. There is no separate `clear_<cap>` cap surface — the design space collapses to one cancellation primitive across the bridge.

Implementation status: bridge protocol extension not yet shipped. `set_timeout` and `fetch_api` are the first caps that will use it; both are blocked on this extension landing. Future cancellable caps default to AbortSignal-cancellable where applicable.

## 5. Rendering model — resolved: Option B

The proposal above isolates *execution*. The remaining question was how
app UI *reaches the screen*. **Resolved to Option B: the app realm
produces virtual structures; the host paints them in the host's realm.**

### Rationale

- **Consistent with the allow-list realm.** §3's bootstrap removes
  `document`, `Element`, `Node`, and the rest of the DOM surface from the
  app realm. There is no DOM in there to render into.
- **"Direct DOM access banned" from §2 lands here naturally** — there is
  no DOM to access. The static block in harden mode and the structural
  absence in the realm are the same decision viewed from two layers.
- **`Element` Lua-side is a structural VNode shape**, not the browser DOM
  `Element`. `dom.lua`-style libraries describe a plain table
  `{ tag, props, children }`; nothing in app-author code needs the
  browser DOM type. No cross-realm type alignment problem.
- **Event handling via cap-bridge tokens.** The app's virtual structure
  declares handler intents as cap-bridge tokens (`{ onClick: "<cap-id>" }`
  or similar); the host wires real DOM events to dispatch the named cap.
  The app never sees a DOM `Event` object.

### Trade-off, named

Any app-author behavior not expressible in the VNode + cap-bridge
protocol requires extending the protocol. Extensions are host-controlled
and additive — not app-author-controlled. This is the cost of structural
isolation: rich-editor / canvas / audio-visualizer use cases need
protocol extensions rather than free DOM access. The decision accepts that
cost as the price of the threat model.

### Options considered (for posterity)

- **Option A — app owns its iframe DOM.** App iframe contains rendered
  UI directly; stub composes iframes into a layout. Easy authoring and
  full DOM API, but iframes are heavy, composition across iframe
  boundaries is awkward (no flex/grid), and inter-app DOM interaction
  requires explicit inter-iframe protocols. Conflicts with the allow-list
  realm.
- **Option C — hybrid.** Simple apps use B, complex apps use A. Two
  rendering models to maintain; app authors pick wrong; cap surface
  differs between them. Rejected for the same reason A is: A's DOM-in-realm
  shape conflicts with §3's allow-list bootstrap.

## 6. Migration from current state

The existing prototype work does not disappear. It moves into a different
position in the stack.

### Current state, in stack order (bottom up)

1. Daemon serves HTML / JS / CSS with per-app CSP.
2. Host JS loads via `<script type="module">` directly in the page.
3. `harden.js` freezes prototypes.
4. `projections/registry.js` and per-tag projection modules render envelopes.
5. lua2ts harden mode (planned) transpiles app-shipped projection-Lua into
   JS that registers into the registry at runtime.

All four upper layers share the page's realm. The boundary between
host code and app code is *type-system shaped*, not runtime shaped.

### Target state

1. Daemon serves a *stub page* per app instance.
2. Stub page CSP allows it to render UI, hold caps, and round-trip
   postMessage with sandboxed iframes.
3. Stub page creates one sandboxed iframe per app realm with strict CSP
   and the bootstrap script.
4. App code runs in the iframe; calls `__cap__.X(...)` for anything
   beyond local computation.
5. Rendering model A / B / C lands between the iframe and the screen.

### Migration steps (rough, not committed)

1. Add `browser_caps` field to manifest schema (`lib/pkg/manifest.lua`). Schema and per-kind config conventions in [`browser_caps.md`](browser_caps.md) §3.
2. Build daemon stub-page generator (per app, per instance).
3. Build the sandboxed-iframe host with bootstrap script and the bridge.
4. Implement initial bridge cap handlers daemon-side (`http_client`,
   `ui_toast`, `dialog`, `clipboard_write`, `kv_read/write`).
5. Port `system_dashboard` to the resolved rendering model (Option B —
   app realm emits virtual structures, host paints). The existing
   projection registry maps cleanly.
6. Resume Initiative B with the rendering model in hand. lua2ts harden mode
   stays as a backstop, but the *primary* isolation boundary is the iframe,
   not the transpile.

Each step is independently committable. The earlier steps are
manifest/schema work and stub-page authoring; they do not break existing
flows. The cutover for `system_dashboard` is the big step and gates
Initiative B's resumption.

## 7. Open questions

These are explicit. They are not buried in prose because they need
decision-level attention, not skimming.

- **Shared `.d.ts` location.** Single host-served declaration file for
  the realm allow-list, cap signatures, VNode shape, and bridge
  protocol. `lib/platform/browser_types.d.ts` or a daemon-served static
  asset — open.
- **ShadowRealm vs iframe primitive.** Today: iframe only. Future: maybe
  both? Is the architecture worth restating in terms of "the realm primitive"
  with two backends, or do we commit to iframe forever and treat ShadowRealm
  as a non-event?
- **Per-app origins.** Real subdomains
  (`pack-<id>.<n>.localhost`)? Unique `srcdoc` iframes? `blob:` URLs?
  Each has tradeoffs:
  - Subdomains require DNS or hosts-file cooperation; cleanest origin
    isolation but operationally heavier.
  - `srcdoc` gives a unique origin per load but no stable origin identity
    for storage scoping.
  - `blob:` URLs are origin-tied to the creating document; storage and
    revocation semantics need a close read.
- **Storage scope.** Per-app-instance? Per-app-version? What survives a
  app reinstall? What survives a app upgrade? The choice ties into the
  per-app-origin choice above.
- **Cap revocation propagation.** When the operator revokes a granted cap,
  how does the active iframe learn? Polling? Stub forces an iframe reload?
  Heartbeat from stub to iframe with a "you've been revoked" message that
  the bootstrap script handles? Force-reload is simplest but disruptive
  mid-task.
- **Cross-app composition.** App A renders app B's content (e.g.
  nesting, embedding, "include this app's projection here"). How do caps
  compose? *Principle* answer: attenuation — app A passes app B only a
  subset of its own caps via the bridge. *Protocol* answer: TBD. Does app
  B get its own iframe inside app A's iframe? Does app A's bridge proxy
  to app B's bridge? Who validates against whose grants?
- **Failure modes.** When the bridge times out or the iframe crashes, what
  does the operator see? What does the rest of the dashboard do? The
  current single-realm model doesn't have to answer this; the new one does.
- **Performance budget.** Each app iframe is real memory (~1-5 MB
  baseline). At what number of concurrent apps does this become operator-
  visible? Are there strategies for sharing realms across "trusted"
  app-bundles?
- **Testing.** What does a app author's local development experience look
  like? They have to test their app inside the sandbox model; the harness
  has to replicate the runtime.
- **Safe-regex algorithm.** Stick with the
  quantifier-on-quantifier ban (cheap, hologram-shaped) or upgrade
  to alternation-overlap analysis / Thompson-NFA
  state-explosion check? Cost-benefit unevaluated.
- **`lib/js_pack_validator/` packaging.** Where does the optional
  author-hygiene validator live, and does it ship with crescent or
  as a separate package? It is JS+bun, runs in author dev/CI, and
  is explicitly outside the daemon critical path — that makes its
  packaging location a real question rather than a default.
- **AbortSignal handling: opt-in per cap, or universal?** §4
  "Cancellation via AbortSignal" extends the bridge so any AbortSignal
  in cap args is intercepted and translated into a cancel message.
  Should this be opt-in per cap (the cap kind's schema declares
  `cancellable: true` and only those calls scan args for signals), or
  universal (every cap call scans args, free for any cap to accept a
  signal)? Universal is simpler and matches the standard-primitive
  framing; opt-in is more conservative (audit list of cancellable caps
  is explicit). Default leaning: universal — the scan is cheap, the
  authoring story is one rule across all caps, and apps cannot
  smuggle anything by attaching a signal to a non-cancellable cap
  (the host just ignores it).

## 8. Alternatives considered

### Lockdown technologies — superseded by in-house allow-list

The §3 lockdown decision was previously open across five options.
All five are recorded here as considered-and-superseded:

- **SES / Lockdown (vendored from Endo) — superseded.** Battle-tested
  JS-on-JS lockdown, ~100–200kb minified. Deny-list framing means it
  periodically has to catch up to new TC39 features; mixed-trust
  deployment caveats apply to its typical usage. In-house allow-list
  lockdown avoids the framing tax. SES remains *reference material*
  for the safe-intrinsics whitelist and neutralisation logic.
- **Tightened SES — superseded.** Stripping `Object.create`,
  `Reflect`, classes, generators down to a smaller surface inside an
  SES-style frame helps, but the underlying framing remains
  deny-list. Allow-list achieves the structural-absence property
  directly.
- **WASM-based sandbox (AssemblyScript / Lua→WASM) — overkill.**
  Structurally stronger than any pure-JS lockdown (no prototypes, no
  host objects, explicit imports), but the allow-list lockdown
  already closes the prototype-chain escape class by construction.
  WASM brings a toolchain plus runtime (~50kb baseline,
  authoring-format reversal) for an isolation property the cheaper
  approach already gives us.
- **JS-in-WASM (QuickJS-in-WASM) — cost without unique benefit.**
  ~300–500kb runtime bundle. Two layers of isolation, JS authoring
  intact, but the structural-isolation argument it offers is
  redundant with allow-list lockdown.
- **Process isolation (Web Worker per app) — orthogonal.** Strong
  boundary; still needs an in-realm lockdown inside the worker to
  close the prototype-chain escape. Can be layered on top of the
  allow-list approach if a future threat model demands it; not a
  substitute.

### Server-side rendering (LiveView / Hotwire pattern) — rejected

Considered an architecture where app Lua runs in the daemon and the
browser is a thin host-controlled painter consuming a daemon-pushed
render stream. Eliminates lua2ts and most browser-side isolation work.
Rejected because: (a) the latency requirement (see §2) is "minimal
latency regardless of network conditions, including through
VPNs/proxies" — every-interaction-is-a-roundtrip breaks under
50ms to multi-second link latency, and
(b) the requirement is full app-author flexibility, which a
host-shipped primitive set cannot cover. The cleaner local-first variant
(rich host primitives + optimistic concurrency) covers some cases but
caps flexibility to the host's primitive set, violating (b).
Browser-side app execution with full isolation is required.

### Dusklight's trusted-in-realm renderer model — rejected

Dusklight (`~/git/rhizone/dusklight`) runs renderer plugins in-realm with
the host, with direct DOM access and no isolation; this works for
dusklight because its plugins don't reach OS capabilities. Crescent's
apps *do* reach OS capabilities (FS, processes, network) through the
daemon's grant model, so the "user installed it = trusted" assumption
does not transfer. Every app is untrusted user code with capability
surface; in-realm execution is unsafe.

### Daemon-side parser-level enforcement (acorn vendored, JS-parser-from-Lua, etc.) — rejected

An earlier revision called for daemon-side parse-and-validate at
app-load using acorn (or a Lua-native JS parser, or a WASM JS
parser). Rejected because:

- Bundling bun or any JS interpreter into crescent's runtime
  distribution violates zero-dependency.
- A Lua-native JS parser is multi-week effort and a continuing
  maintenance burden against an evolving language.
- Acorn-as-WASM has no clean off-the-shelf path.

The runtime sandbox (`lib/js_realm_sandbox/`) is therefore the only
security boundary. Language-level constraints either get a runtime
fallback (class-extends-bind closed by non-constructable bind;
`with` and sloppy-`this` closed by daemon-prepended strict mode;
`eval` / `Function` / dynamic `import()` closed by deletion + CSP) or
become author hygiene via the optional `lib/js_pack_validator/`.

### Language-level constraints enforced only at runtime — accepted (with runtime fallbacks for the load-bearing cases)

An earlier revision listed this option as rejected on the grounds
that runtime cannot un-define syntax. That framing was wrong: the
load-bearing syntactic vectors all have runtime fallbacks. `class X
extends boundBuiltin {}` is closed not by banning the `class`
keyword but by making `boundBuiltin` non-constructable, so
`extends` rejects it at class-evaluation time. `with` and
sloppy-`this` are closed by forcing strict mode at serve time
(strict scripts SyntaxError on `with`). Generator syntax is inert
because the relevant constructors and iterator prototypes are
removed. The runtime allow-list + non-constructable wrappers +
daemon-side strict-mode prepend, together, close every
load-bearing syntactic vector without parser-side enforcement.

## 9. Non-goals

- **This is not a security-against-adversarial-internet-code spec.**
  The threat model is user-installed apps (extension-grade trust), not
  arbitrary web content. If adversarial app distribution becomes a
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

## 10. Status

Draft. No code committed. No manifest schema changes. No daemon changes.
The doc exists to (a) ground the next session's design conversation in a
shared frame, (b) explicitly mark Initiative B and other browser-side app
work as gated on this design being settled, and (c) collect the open
questions in one place so they can be picked off deliberately.

Comments, counterproposals, "this is wrong because X", and "you missed Y"
are all in scope. Treat nothing here as decided.
