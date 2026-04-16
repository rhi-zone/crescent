# Platform Daemon — Per-App Isolation

## Scope

This doc is the focused record of how the platform daemon keeps one installed
app from reaching another app's data, the daemon's own authority, or the host
process's memory. It collects the intended VM-sandbox control set, the subset
that actually runs today, the tier decision for how far we take in-process
isolation, and the build order for the gap.

Everything else about the daemon — HTTP routing, session cookies, the launch
flow, the grant UI, CSRF, CSP derivation from manifests, admin policy,
fatigue-aware grant UX — lives in [`daemon-design.md`](daemon-design.md). That
document is the complete picture; this one only zooms in on isolation so a
reader with an isolation question does not have to read 1500 lines.

## Threat model

Crescent treats every installed app as potentially hostile from the moment it
is installed. Apps ship both a Lua backend (running inside the daemon's
LuaJIT VM) and frontend code (HTML/JS running in the operator's browser on
the app's own subdomain). Both halves have the same author and collude by
design. There is no scenario where one half is trusted and the other is not.

Against the daemon itself, a hostile app tries to:

1. **Exfiltrate another app's data** — read the other app's `kv`/`db`/`fs`
   storage, intercept its HTTP traffic, or read state the other app holds
   live in memory.
2. **Escalate to daemon authority** — mint launch tokens, write
   `grants.json`, alter the router, or otherwise act as if the operator had
   authorized it.
3. **Exfiltrate the operator's session** — read the daemon-origin session
   cookie or CSRF token from a position that lets it act as the operator.
4. **Denial of service** — hang the daemon's request thread with a busy
   loop, crash the process, or balloon memory until the host kills it.

Targets 1–3 are about confidentiality and integrity, and this doc's layered
controls aim at them. Target 4 is explicitly a lower priority — see
[Non-goals](#non-goals) below.

The dual-surface framing (backend ACE vs. frontend ACE vs. frontend XSS on
the daemon origin) is worked through in
[`daemon-design.md` — "Threat model: silent grant vs fatigue"](daemon-design.md)
and the XSS-resistance subsection there. This doc covers the backend half.

## Layers of defense

Isolation is not a single mechanism. It is four independent layers, each of
which should hold even if the others are bypassed.

- **VM sandbox** — the app's Lua code runs with a restricted `_ENV`, no
  `_G`, no `debug`, no `os`/`io`, no FFI, no bytecode loading, and no
  visibility of daemon internals. Prevents a backend ACE from becoming
  arbitrary code execution in the daemon process. Detailed below.
- **Origin isolation** — the app's frontend runs on
  `app-<id>.<daemon-host>` (or a distinct loopback IP). The daemon-origin
  session cookie is not sent to the app origin, so the app's JS cannot
  impersonate the operator against the daemon API. Covered in
  [`daemon-design.md` — "Origin isolation"](daemon-design.md).
- **Capability scoping** — every cap the app receives is constructed with
  `context.app_id` baked in. `kv`/`db` paths, `http_client` host lists,
  `shared_db` authorizers, and revocation are all per-app by construction.
  Two apps asking for "the same cap" get two independent cap instances.
  Covered in [`daemon-design.md` — "Cap scoping: per-app by default"](daemon-design.md).
- **CSP on app responses** — every HTTP response the daemon serves on an
  app's behalf carries a `Content-Security-Policy` derived from the app's
  manifest. The frontend's network reach matches the backend's host
  whitelist. Covered in
  [`daemon-design.md` — "Content-Security-Policy"](daemon-design.md).

The VM sandbox is the primary in-process defense; origin isolation and CSP
defend the browser half; capability scoping ensures that even a
well-behaved-but-curious app cannot widen its reach by accident.

## VM sandbox controls

These are the intended controls. Status (built vs. planned vs. audit-pending)
is in the next section — read both.

- **Env-based sandbox, no `_G` access.** Each app is loaded with a per-app
  environment table as its `_ENV`. The env contains exactly the caps the app
  was granted plus a narrow stdlib subset (`string`, `table`, `math`,
  `pairs`, `ipairs`, `tostring`, `tonumber`, `type`, `select`, `error`,
  `pcall`, `xpcall`, `rawequal`, `rawget`, `rawset`, `rawlen`). No `_G`, no
  `_ENV`, no `package`.
- **No `debug` library.** `debug.getupvalue`, `debug.setupvalue`,
  `debug.getregistry`, `debug.getlocal`, and `debug.sethook` each escape any
  env sandbox. `debug` is never in the app env under any cap.
- **No `os` or `io` globals.** File I/O, time, and subprocess are mediated
  through caps (`caps.fs`, `caps.time`, `caps.spawn`). Ambient `os.getenv`,
  `os.date`, and `io.open` are not reachable. This is the project-wide
  capability-based-I/O rule; the daemon enforces it at the boundary.
- **No FFI.** `ffi = require("ffi")` is the canonical LuaJIT sandbox escape
  — with FFI, an app can call `mmap`, `dlopen`, `system`, or any other C
  function in the process. `ffi` is never in the restricted `require`
  whitelist. First-party apps that need FFI must declare it as a cap (risk
  class: shared) and get an explicit operator grant.
- **No bytecode loading.** `load` / `loadstring` / `loadfile` are either
  absent or forced to text-only mode (`load(src, name, "t", env)`). Crafted
  LuaJIT bytecode can bypass VM-level type checks; only source loading is
  safe.
- **Frozen metatables on shared built-ins.** `getmetatable("")` would expose
  the string metatable; mutating its `__index` would poison every string
  operation in every app and in the daemon itself. Either freeze primitive
  metatables with a `__metatable` sentinel or omit `getmetatable` /
  `setmetatable` from the stdlib entirely.
- **Per-app `package.loaded`.** If two apps share a `package.loaded` table,
  one can poison a module the other requires. Each app gets its own fresh
  module cache at construction time, closed over by the restricted
  `require`.
- **Cap closures, not cap tables.** Caps are functions holding private-state
  upvalues. The app cannot reach into that upvalue, cannot rebind
  `caps.kv.get`, and cannot swap the `caps` table for a privileged one —
  because `caps` itself is a function or a frozen table with `__newindex`
  trapped.
- **No reference to daemon internals.** Grant store, router, launch-token
  map, cap factory — none of these are in any app's `require` whitelist.
  An app cannot `require("lib.platform.grants")` because that name is not in
  its manifest's declared deps, and the restricted `require` raises on any
  non-whitelisted name.

## Implementation status

Today's code (`lib/platform/daemon/app_loader.lua`) implements a subset. The
name "per-app VM host" in TODO.md overstates what's built: apps share a
single `lua_State` and differ only by env table.

| Control | Status | Notes |
|---|---|---|
| Per-app env table, no `_G`/`_ENV`/`package` | Implemented | `sandbox.env(sandbox.stdlib, { globals = { caps = … } })` |
| Per-app cap bundle with `context.app_id` baked in | Implemented | `platform.make_caps(app, decl, grants, ctx, …)` |
| `http_server` handler captured into daemon closure | Implemented | `cap.serve(h)` stored; dispatched by `Host` header |
| Stdlib excludes `require`, `ffi`, `debug`, `io`, `os`, `package`, `load`, `loadstring`, `dofile`, `string.dump` | Implemented by construction | Audit-pending: no regression test, no audit of whether the exposed stdlib leaks these via `string.gmatch`, `table.concat`, or similar |
| Per-app `package.loaded` cache | N/A today | `require` is not exposed at all; if it ever is, this becomes relevant |
| Frozen primitive metatables | Audit-pending | Undetermined whether `getmetatable`/`setmetatable` on `""`/`0`/`false` is reachable via any currently-exposed stdlib path |
| Cap closures (not mutable tables) | Implemented for most caps | Per-cap review still worth doing |
| Crash containment (`pcall` around handler) | Planned | Per-request handler invocation bubbles `error()` up past the daemon's request loop today |
| CPU quota (instruction count) | Planned | `while true do end` in a handler blocks the daemon request thread with no budget, no yielding, no kill |
| Separate `lua_State` per app | Not built | All apps share one state; any future FFI escape sees every other app's memory |

"Audit-pending" items are things the current code most likely gets right but
that have no test or audit confirming it. Closing them is a prerequisite for
treating the VM sandbox as the primary defense in production deployments.

## Tier decision

Three possible isolation tiers sit at increasing cost and strength. Each
would be a real implementation, not a wrapper over the next.

1. **Status quo + `pcall` + instruction quota.** Single `lua_State`, single
   thread. Wrap each handler invocation in `pcall`. Run it as a coroutine
   with `debug.sethook("", "", N)` checking a deadline every N bytecodes.
   Cap calls remain direct function calls (free). Worst-case ~20–30%
   overhead on hook-enabled traces; zero for handlers that don't trip the
   hook. Catches infinite loops, uncaught errors, and blocking-forever
   handlers. Misses memory DoS and primitive-metatable poisoning unless the
   stdlib audit closes that first.
2. **Separate `lua_State` per app.** One process, N states. State creation
   is ~1 ms and amortizes over the app's lifetime. An FFI escape in one
   state cannot read another state's Lua memory (native-code-reading-native
   is unchanged — they share the OS process). Cost: cap calls cross a
   state boundary. A pure-serialization bridge is likely 5–10× slower on
   cap-heavy workloads than a direct function call; a `CFunction` shim with
   `lua_xmove` on tables is faster but more code. Worth measuring before
   committing.
3. **Fork per app.** N processes, full OS isolation. The daemon is
   explicitly built as a single-process design, so this is held as a
   fallback for "apps try to steal each other's memory" scenarios we don't
   have yet.

**Chosen direction: tier 1, with the stdlib audit landing before tier 1's
hooks ship.** Tier 1 gets ~80% of the isolation value (crash containment +
spin containment) at 0% cap-call overhead. The main gap it accepts — a
hostile app using Lua-level introspection to read another app's memory — is
a threat we don't have evidence of yet.

Escalate to tier 2 if either:

- An adversarial app triggers a containable incident that a separate
  `lua_State` would have caught (e.g., one app mutates a primitive
  metatable and affects another, and freezing didn't stop it).
- Cap-call performance under tier 1 is measured and shown to have headroom
  for a boundary — at which point a state-per-app bridge becomes
  implementable without regressing the cap-heavy path.

Do not build tier 2 speculatively. Do not wrap tier 1 in an abstraction
that "makes it easy to swap in tier 2 later" — that abstraction is the
problem tier 2 would be solving, reinvented badly.

## Build order

None of the following is implemented yet. Treat as the v3 bring-up plan,
not a retrospective.

1. **Stdlib audit + regression test.** Enumerate every symbol reachable from
   `sandbox.stdlib` recursively (`string.gmatch`, `table.concat`, …). Assert
   no path leads to `require`, `ffi`, `debug`, `package`, `load`,
   `loadstring`, `dofile`, `string.dump`, or to `setmetatable` /
   `getmetatable` applied to primitive-typed values. Commit the assertion
   as a test so future stdlib additions cannot silently widen the surface.
2. **`pcall` wrap on per-request handler dispatch.** `daemon/init.lua`'s
   app-handler branch currently calls `handler(req, res)` directly. Wrap it
   in `pcall`; on failure, respond 500 with `Content-Type: text/plain` and
   log the traceback to the daemon's error channel (operator-visible only,
   never sent to the client). Zero-cost on the happy path.
3. **Coroutine-per-request + instruction quota.** Resume the handler as a
   coroutine with `debug.sethook(co, fn, "", N)` (count mode, every N
   bytecodes). `fn` checks `time_fn() - start_ns > budget_ns` and errors on
   overrun. Budget is per-request, not per-app-lifetime. First-party apps
   (library, card) can opt out of the hook at install; third-party apps
   get it by default. This also answers the concurrent-request question
   from [`daemon-design.md` — Open Question 2](daemon-design.md) — blocking
   handlers yield instead of hogging the request loop.
4. **Frozen primitive metatables.** Either set `__metatable` sentinels on
   `""`, `0`, `false` at daemon startup so `getmetatable` returns a
   non-actionable value, or omit `getmetatable`/`setmetatable` from the
   stdlib entirely. The audit in step 1 decides which.
5. **Revisit tier 2 if-and-only-if.** Track the escalation triggers above.
   Do not build a state-per-app bridge on speculation.

Steps 1–2 are cheap and unblock treating the sandbox as the primary defense.
Step 3 is where the real engineering lives — the hook interaction with
LuaJIT traces needs benchmarking. Step 4 is a line-item once the audit
settles.

## Non-goals

- **Memory quota per app.** LuaJIT does not expose a way to cap GC heap per
  env. Approximating it with counters on `table.new` / string concat does
  not stop FFI-level allocation and is a rabbit hole. If memory DoS becomes
  a real concern, the answer lives at tier 2/3, not tier 1.
- **Blocking-I/O cap limits.** A handler that calls `caps.http_client.get`
  on a slow endpoint is expected to be slow; the instruction quota does
  not fire on C-level blocking. Concurrent-request handling (coroutine
  yielding on I/O, not on bytecode count) is the right answer — tracked
  under [`daemon-design.md` — Open Question 2](daemon-design.md).
- **Concealing an app's own `app_id` or data-directory path.** The app is
  allowed to know which app it is; the isolation boundary is that it
  cannot reach any other app's storage or authority, not that it is
  ignorant of its own identity.
- **Defending the daemon against the operator.** The operator who grants a
  cap is authorizing its use; the sandbox does not try to prevent the
  operator from making bad grant decisions. That is the grant-UI and
  risk-disclosure layer's job, covered in
  [`daemon-design.md` — "Risk-tiered friction"](daemon-design.md) and
  "Cap risk disclosure".

## See also

- [`daemon-design.md`](daemon-design.md) — the complete platform daemon
  design. This isolation doc is a focused subset. In particular:
  - "Threat model: silent grant vs fatigue" — the dual-surface adversary
    framing this doc paraphrases.
  - "VM sandbox: the backend cannot reach the daemon's memory" — the
    original, longer prose version of the controls listed above.
  - "Origin isolation", "Session token confidentiality", "Daemon UI XSS
    resistance", "Content-Security-Policy" — the browser-side layers.
  - "Cap scoping: per-app by default" — the capability-layer enforcement.
  - "v3 per-app isolation notes" — the build-order source of truth; keep
    this doc and that section in sync when either changes.
- `lib/platform/daemon/app_loader.lua` — current per-app env + cap bundle
  construction.
- `lib/platform/daemon/init.lua` — request dispatch, where the `pcall`
  wrap and coroutine quota from the build order will land.
- `lib/sandbox/init.lua` — the `sandbox.stdlib` table and `sandbox.env`
  constructor audited in build-order step 1.
