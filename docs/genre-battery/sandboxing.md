# Control-stage sandboxing — design proposal

**Status: PROPOSAL awaiting owner sign-off. Nothing in this document is
settled direction.** It answers the open question `genre-battery-design.md`
names under "Explicitly open questions": *"What does 'sandbox it properly'
mean concretely for control-stage Lua? ... No sandboxing design exists."*
This document proposes candidates; it does not pick one. The authoring
*language* for control-stage code (plain Lua) is separately settled per
`genre-battery-design.md` — this document does not revisit that.

## What already exists (found before designing anything new)

Crescent is not starting from zero. Two pieces of real, tested, in-repo prior
art cover most of the mechanism this document would otherwise propose from
scratch:

- **`lib/sandbox/init.lua`** — a working capability-based script sandbox.
  `sandbox.env(cap, ...)` merges `{ globals = {...}, modules = {...} }`
  capability tables into a single env table and installs a whitelist
  `require`. `sandbox.run(code, env, opts)` loads code in text-only mode
  (`load(src, name, "t", env)` — no bytecode) and runs it under `pcall`,
  optionally with `opts.budget` (an instruction-count limit enforced via
  `debug.sethook`). Two built-in capability bundles ship: `sandbox.stdlib`
  (safe subset: no `io`/`os`/`ffi`/`debug`/loaders/`string.dump`) and
  `sandbox.pure` (stdlib minus `print`/`coroutine`, for pure computation).
  `sandbox.lock_string_metatable()` freezes the shared string metatable so
  sandboxed code can't poison `("x").upper` process-wide via
  `getmetatable("").__index`.
- **`lib/sandbox/sandbox_audit_test.lua`** — a regression audit, not just unit
  tests. It BFS-traverses everything reachable from `sandbox.stdlib` and
  `sandbox.pure` and asserts none of it `rawequal`s a blacklisted
  escape-vector function (`require`, `load`, `dofile`, `string.dump`, every
  `debug.*` introspection function, `os.execute`/`getenv`/`remove`/`exit`,
  `io.open`/`popen`/`read`, `getfenv`/`setfenv`, `newproxy`, every `ffi.*`
  function). It also verifies `_G` and `_ENV` are unreachable from inside a
  sandboxed script, and that the frozen string metatable holds both outside
  and inside a sandbox `env`. Any future addition to `sandbox.stdlib` that
  leaks one of these fails this test — the blacklist is enforced
  structurally, not by code review discipline.
- **`docs/daemon-isolation.md`** — a full isolation design for a *different*
  consumer of `lib/sandbox`: the platform daemon's per-installed-app
  isolation. It is not about control-stage mods, but it already worked
  through most of the same problem shape (untrusted Lua, capability
  injection, instruction budgets, LuaJIT-specific escape vectors) for
  HTTP-handler-shaped code, and reached a documented tier decision (below).
  This document treats it as the closest available precedent and reuses its
  vocabulary and its already-answered sub-questions rather than re-deriving
  them.

Concretely: the capability-injection half of this task (point 1 in the
brief) and a first cut at the bounded-execution half (point 2) are not
"undesigned" — they're built, and audited for one consumer. What's actually
open for control-stage is: (a) whether the game-mod calling shape (control
code invoked every tick, not per HTTP request) changes the tier tradeoff
`daemon-isolation.md` already made for its own workload, (b) wall-clock vs.
instruction-count budgeting, and (c) what capability bundle a control-stage
mod gets by default. Sections below address these; they do not re-litigate
what `lib/sandbox` already does.

## Prior art: Lua sandboxing mechanisms (brief)

- **`_ENV`/`setfenv` environment restriction.** Lua 5.2+ makes `_ENV` a
  first-class upvalue; sandboxing means compiling the chunk with a
  restricted `_ENV`. Lua 5.1 (and LuaJIT, which targets 5.1 syntax with
  selected 5.2 extensions) instead gives every function a *fenv* — a table
  used for global name resolution — settable at load time via the fourth
  argument to `load()`, or afterward via `setfenv`. `lib/sandbox` uses the
  `load(src, name, "t", env)` form, i.e. the 5.1-style mechanism, not a
  5.2-style `_ENV` upvalue. This matters for one specific reason: LuaJIT
  exposes `setfenv`/`getfenv` as globals, and either one reaching sandboxed
  code is a full sandbox escape (`getfenv(0)` returns the true globals
  table). `lib/sandbox`'s stdlib bundle omits both, and the audit test
  checks they're unreachable from inside a sandboxed env.
- **Coroutine-based cooperative time-slicing.** A common pattern for
  bounding untrusted Lua: run the untrusted chunk as a coroutine, install a
  `debug.sethook(co, fn, "", N)` count-hook that fires every N bytecode
  dispatches, and have `fn` check a deadline (wall-clock or instruction
  count) and `error()` out if it's exceeded. This is exactly what
  `daemon-isolation.md`'s tier-1 plan describes and what `lib/sandbox.run`'s
  `opts.budget` already implements in instruction-count form (not yet
  wall-clock — see below). The hook only fires between bytecode
  instructions; it cannot interrupt a single long-running C function call
  (a pathological `string.rep`, a catastrophic-backtracking pattern match,
  a big `table.sort` with a hostile comparator) or the underlying `load()`
  compile step itself.
- **LuaJIT-specific gotchas**, in order of how load-bearing crescent's
  choices already are:
  - `debug.sethook`'s count-hook interacts with JIT-compiled traces.
    `daemon-isolation.md` flags this as an open, unbenchmarked interaction
    ("Interaction with LuaJIT traces needs benchmarking before this
    lands" — build-order step 3, not yet done for the daemon either).
    Whether the hook fires reliably inside a hot JIT-compiled trace, and at
    what overhead, is not established anywhere in this codebase yet. This
    is a real gap this document inherits rather than resolves.
  - `string.dump` serializes a function to LuaJIT bytecode; loading crafted
    bytecode bypasses the VM's bytecode verifier in ways source-mode
    loading does not. `lib/sandbox` forces `load(..., "t", ...)` (text-only)
    and strips `string.dump` from the safe `string` copy — both already
    closing this for any reuse of `lib/sandbox`.
  - `ffi` is the sandbox escape hatch on LuaJIT specifically (no equivalent
    exists in stock PUC-Rio Lua sandboxes): with `ffi`, sandboxed code can
    call arbitrary C functions in the host process (`mmap`, `dlopen`, raw
    memory access). `lib/sandbox.stdlib` never includes `ffi` in its module
    whitelist; the audit test enumerates every function on the real `ffi`
    module and blacklists each one individually (not just the table),
    specifically so a future edit can't accidentally re-expose it through a
    partial re-export.
  - `newproxy` (LuaJIT-specific, absent from stock 5.1) can construct
    userdata with an arbitrary metatable — a documented escape primitive in
    some sandboxing writeups. Banned defensively in the audit blacklist even
    without a demonstrated concrete exploit in this codebase.
  - LuaJIT gives primitive types (`0`, `true`, `nil`) no metatable at all —
    `getmetatable(0)` is `nil` — so there's nothing to freeze there. Strings
    do share one global metatable across the whole process; `lib/sandbox`
    freezes it with `__metatable = false` at module load, verified from both
    outside and inside a sandbox env by the audit test.

## 1. Capability surface and injection

`lib/sandbox.env(cap, ...)` already implements caps-first injection exactly
as `CLAUDE.md`'s convention requires: default is nothing (an empty env has no
globals at all, not even `_G`), and every name a script can see — including
`require`-able module names — is named explicitly in a `{ globals, modules }`
cap table the host composes and passes in. Nothing is ambient.

For control-stage mods specifically, two decisions remain open (not decided
by anything read while researching this):

- **What capability bundle is the control-stage default?** `sandbox.stdlib`
  and `sandbox.pure` are generic, application-agnostic bundles built for the
  platform daemon's app-loader use case. Control-stage mods need engine-side
  capabilities that don't exist yet in any cap bundle — the "game/rendering/
  events API" `genre-battery-design.md` describes control stage as having
  full access to. Whether that becomes one broad `caps.engine` bundle, or
  several narrower caps (`caps.entities`, `caps.render`, `caps.events`)
  granted per-mod-manifest the way the platform daemon grants
  `caps.kv`/`caps.fs`/`caps.http_server` per app, is unresolved — it depends
  on what the engine substrate itself ends up exposing, which
  `genre-battery-design.md`'s "Prerequisites" section already flags as
  unbuilt (`lib/ecs` vs `lib/entity_component` gap, closed-dispatch-table
  libraries with no extension API).
- **Per-mod or per-manifest-declared caps?** The platform daemon model
  (`docs/daemon-isolation.md`) is: an app's manifest declares which caps it
  wants, the operator grants or denies at install time, and the daemon
  assembles exactly that cap set before constructing the app's env. Whether
  control-stage mods follow the same declare-then-grant flow, or get a
  fixed default bundle with no per-mod variance (closer to Factorio, where
  control stage just has "full API access" uniformly), is a mod-loader-shape
  question this document does not decide — it depends on the trust model for
  wherever mods come from (bundled-with-game vs. Workshop-style third-party
  distribution), which is itself unresolved in `genre-battery-design.md`.

## 2. Bounded execution

`sandbox.run`'s `opts.budget` already gives instruction-count bounding today:
a `debug.sethook` count-hook fires after `budget` instructions and raises a
Lua error, caught by the `pcall` inside `sandbox.run`, surfacing as
`(false, err)` — a return value, not a thrown exception out of `run` itself.
Adapting that to the project-wide `(nil, errmsg)` convention at the
mod-loader boundary is a thin wrapper (`if not ok then return nil, err end`),
not a design question.

What's genuinely open:

- **Instruction count vs. wall-clock.** An instruction-count budget is
  deterministic and cheap but means the same mod script runs a different
  *number of frames-worth of real time* depending on whether the JIT has
  compiled its hot loop yet — a script budgeted for "typical" JIT-compiled
  speed can blow way past its intended time slice while still
  interpreter-only, and one budgeted conservatively for interpreter speed
  wastes headroom once JIT-compiled. `daemon-isolation.md`'s build-order step
  3 (not yet landed there either) proposes a wall-clock check inside the
  same count-hook (`time_fn() - start_ns > budget_ns`, checked every N
  bytecodes) as the fix. That design is directly reusable here; it has not
  shipped anywhere in this codebase yet, so "reusable" means "same
  unbuilt work," not "already available."
- **What a violation means for a hung script vs. a script that merely errors.**
  A script that raises (including via budget-exceeded) is a normal
  `(nil, errmsg)` case for the mod loader — no different from a syntax error
  or a runtime `error()` call, and already handled by the pcall wrapping.
  The harder case the brief calls out — "a script that's genuinely hung may
  need a harder stop than a returned error" — is real and *not* solved by
  the count-hook at all: the hook fires between bytecode dispatches, so it
  cannot interrupt a single pathological C-level call (catastrophic-backtrack
  pattern match, huge `string.rep`, a hostile `table.sort` comparator that
  never terminates its own C-side probing, or a genuine infinite loop
  entirely inside a C function crescent doesn't control). `debug.sethook`
  never fires in that case; there is no bytecode dispatch to hook. This gap
  is inherited from `daemon-isolation.md`, which names the analogous
  "blocking-I/O cap limits" and "coroutine hijacking" cases as accepted
  non-goals for its own tier-1 answer, not as solved. Nothing in this
  codebase currently has a harder stop than "the count-hook fires, or it
  doesn't." A genuinely hard stop (kill the OS thread, kill the process)
  requires a boundary the count-hook approach doesn't have — see Option C
  below.
- **Tick-frequency changes the tradeoff `daemon-isolation.md` already made.**
  That document picked tier 1 (shared `lua_State`, in-process, `pcall` +
  instruction quota) for the platform daemon's workload: per-HTTP-request
  handler invocations. Control-stage code's calling shape is plausibly very
  different — invoked every game tick (e.g. 60/s), not per request — which
  changes the cost-per-invocation math for any tier that adds
  per-invocation overhead (tier 2's state-boundary cap calls, tier 3's IPC).
  Whether tier 1's overhead profile still holds at tick frequency, or
  whether a different tier is actually cheaper at that call rate, is not
  established by anything read for this document and needs its own
  measurement before being assumed either way.

## 3. LuaJIT interaction

Covered in "Prior art" above in detail. Summary of what's load-bearing for
this design specifically:

- The env-injection mechanism (`load(src, name, "t", env)`) is the LuaJIT
  5.1-style fenv, not a 5.2 `_ENV` upvalue — already how `lib/sandbox` works,
  carries over unchanged for control-stage use.
- `ffi`, `string.dump`, bytecode `load`, `debug.*`, `getfenv`/`setfenv`, and
  `newproxy` are the enumerated LuaJIT-specific (or LuaJIT-relevant)
  escape-vector set `sandbox_audit_test.lua` already blacklists structurally.
  Any control-stage cap bundle built on top of `lib/sandbox.env` inherits
  this for free as long as it's built from `sandbox.stdlib`/`sandbox.pure`
  or passes through the same audit; a bundle built from scratch would need
  its own audit-test coverage — the existing test only covers the two
  bundles that exist today.
- The count-hook / JIT-trace interaction is unbenchmarked anywhere in this
  codebase (daemon or otherwise). This is the single largest unresolved
  technical unknown underneath *any* instruction- or wall-clock-budget
  option below, and applies identically regardless of which option is
  chosen.

## Design options

Presented side by side per the brief; no recommendation. All three assume
`lib/sandbox.env`/`sandbox.stdlib`-shaped capability injection underneath
(Section 1) — they differ only in how execution is bounded and how far
isolation goes, since that's the axis with genuinely different unresolved
mechanisms.

### Option A — reuse `lib/sandbox.run` as-is, per-invocation instruction budget

Control-stage mod callbacks (however the mod loader ends up structuring
"the function this mod runs when X happens") are invoked through
`sandbox.run(code_or_fn, env, { budget = N })` directly, same as the daemon's
planned (not-yet-landed) `app_loader.lua` integration. No new mechanism.

- **Pros:** Already built and audited (`lib/sandbox/sandbox_audit_test.lua`).
  Zero new escape-vector surface to review. Zero per-call overhead beyond the
  hook itself — no state boundary, no serialization.
  Matches `daemon-isolation.md`'s tier-1 choice, so any future work closing
  that document's build-order step 3 (wall-clock check in the hook) benefits
  control-stage mods automatically without a separate implementation.
- **Cons:** Same tier-1 gaps as the daemon doc, inherited as-is: no memory
  quota, no defense against a single hung C-level call, shared `lua_State`
  means one mod's primitive-metatable mutation or GC pressure is visible to
  every other mod and the host engine. At tick frequency, an unbounded loop
  in *any* mod stalls the entire game loop, not just that mod's own update —
  worse blast radius than a stalled HTTP handler, since a stalled request
  only blocks the one client (in a single-threaded server, also blocks the
  loop — same shared-thread caveat `daemon-isolation.md` itself accepts for
  tier 1). Instruction-count budgeting (not yet wall-clock) means budget
  tuning is JIT-state-dependent, per Section 2.

### Option B — coroutine + wall-clock preemption

Same in-process model as A, but each control-stage callback runs as a
coroutine, and the count-hook installed on it checks wall-clock deadline
(`time_fn() - start_ns > budget_ns`) rather than a raw instruction count —
implementing `daemon-isolation.md`'s currently-unbuilt build-order step 3,
generalized to control-stage's per-tick calling shape instead of per-request.

- **Pros:** Time-based budget is what actually matters for a real-time game
  loop (a mod's control code needs to fit inside this tick's frame budget,
  regardless of whether the JIT has warmed up yet) — closes Option A's
  JIT-state-dependent tuning problem. Coroutine framing also gives mods a
  legitimate way to `coroutine.yield` across ticks for multi-tick behavior
  without being killed, if the mod loader chooses to expose that (a
  mod-loader-shape decision this document doesn't make).
- **Cons:** Still shares every tier-1 gap Option A has (no memory quota,
  hung-C-call blind spot, shared-state blast radius) — this option only
  changes *what* the budget measures, not what happens when a C-level call
  never returns control to a bytecode dispatch. The JIT-trace/count-hook
  interaction is unbenchmarked (Section 3) and this option depends on it
  more heavily, since a wall-clock check has to run frequently enough to
  catch overruns promptly without adding meaningful per-bytecode overhead —
  a tuning problem `daemon-isolation.md` explicitly deferred to its own
  future benchmarking, not solved. Building the coroutine-scheduling
  interaction correctly (an app's own internal `coroutine.*` calls must
  stay invisible to the outer quota coroutine, per `daemon-isolation.md`'s
  "Coroutine hijacking defense" non-goal note) is real engineering work,
  not a config flag.

### Option C — separate `lua_State` (or process) per mod, hybrid with A/B

Escalate to `daemon-isolation.md`'s tier 2 or tier 3 for control-stage
specifically, keeping Option A or B's in-process budget as the first line of
defense and adding a hard OS/VM-level boundary as backstop: each mod (or
each mod's control-stage entry point) runs in its own `lua_State`
(tier 2) or its own OS process (tier 3), so a hung C-level call or a
JIT-miscompile-triggered escape is contained to that mod's state/process and
can be forcibly killed from outside without corrupting the host engine's own
Lua state.

- **Pros:** The only option that actually answers "a script that's genuinely
  hung may need a harder stop than a returned error" from the brief — a
  count-hook cannot interrupt a stuck C call from inside the same OS thread,
  but an external supervisor (watching a per-mod deadline) can kill a
  separate `lua_State`'s host thread or an OS process outright. Also the
  only option that bounds memory per mod (an OS process has an OS-enforced
  memory ceiling; a shared `lua_State` structurally does not, per
  `daemon-isolation.md`'s own non-goals section). Matches Factorio's actual
  security posture more closely if third-party mod distribution is ever in
  scope (`genre-battery-design.md`'s mod-loader-shape section names Workshop-
  style paradigms as in scope for *some* mod-loading paradigm, though not
  necessarily control-stage specifically).
- **Cons:** This is exactly the tradeoff `daemon-isolation.md` measured and
  explicitly declined to build speculatively for its own workload ("Do not
  build tier 2 speculatively"). Every cap call a mod makes into engine state
  crosses a state or process boundary — serialization or `lua_xmove` for
  tier 2, IPC for tier 3 — and `daemon-isolation.md` estimates 5-10x overhead
  for a naive serialization bridge on cap-heavy workloads, unmeasured for a
  `lua_xmove`-based shim. At per-tick call frequency (Section 2's tick-rate
  point) this cost multiplies by however many ticks/second the engine runs,
  which is a fundamentally different call-volume profile than the daemon's
  per-HTTP-request case that produced the "don't build tier 2 speculatively"
  call — this option needs its own measurement against control-stage's
  actual calling shape before any tier decision transfers from the daemon
  context. Substantially more implementation and lifecycle complexity (state/
  process creation, teardown, crash telemetry) than A or B.

## What this document does not do

No recommendation between A/B/C. No decision on the control-stage default
capability bundle. No decision on per-mod-declared vs. fixed caps. No
benchmark of the count-hook/JIT-trace interaction — flagged as unresolved
everywhere it's relevant, not run. No mod-loader-shape decision. All of these
are named as open in the relevant section above rather than guessed at.
