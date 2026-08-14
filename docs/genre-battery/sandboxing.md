# Control-stage sandboxing — design status

**Status: mixed.** Architecture direction is DECIDED for the shape (multiple
independent implementations, no single "correct" answer — see "Decided
direction" below); several load-bearing mechanism choices from the original
proposal are REJECTED with sourced reasoning (see "Rejected" below);
significant implementation detail remains genuinely OPEN and is called out
explicitly, not filled in. This document is no longer "awaiting sign-off" in
the sense of picking between A/B/C — that pick happened, and the answer was
"build more than one, per crescent's own multi-implementation convention" —
but it is also not a finished design: several sections below still need real
design work before anything in them is implementable. Treat each section's
own status marker as authoritative over this paragraph.

It answers the open question `genre-battery-design.md` names under
"Explicitly open questions": *"What does 'sandbox it properly' mean
concretely for control-stage Lua? ... No sandboxing design exists."* The
authoring *language* for control-stage code (plain Lua) is separately settled
per `genre-battery-design.md` — this document does not revisit that.

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
  HTTP-handler-shaped code, and reached a documented tier decision. This
  document treats it as a precedent for vocabulary, and inherits its cap
  taxonomy (`http_client`, `db`, `kv`, `llm`, `fs`, ffi caps, `exec`/`shell`/
  `pty`) as the reference for what counts as a genuine external-resource
  crossing (see "Decided direction" below) — but its tier-1 budget mechanism
  (`debug.sethook` count-hook) is the thing this document now has sourced,
  reproduced evidence is broken on LuaJIT specifically (see "Rejected"
  below), so its tier decision does not transfer uncritically.

Concretely: the capability-injection half of this task is not "undesigned" —
it's built, and audited for one consumer, and this document keeps it as the
substrate every implementation below builds on (Section 1 is unchanged from
the original proposal). What changed is the bounded-execution half: the
original proposal's Options A and B assumed `debug.sethook` count-hook
budgets were a real bounding mechanism on LuaJIT. Investigation since found,
and reproduced against the vendored binary in this repo, that they are not —
see "Rejected" below for the sourced reasoning, and "Decided direction" for
what replaces them.

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
- **Coroutine-based cooperative time-slicing.** The general pattern: run
  untrusted Lua as a coroutine, install a `debug.sethook(co, fn, "", N)`
  count-hook that fires every N bytecode dispatches, and have `fn` check a
  deadline and `error()` out if it's exceeded. This is what
  `lib/sandbox.run`'s `opts.budget` already implements in instruction-count
  form. **This mechanism is now CONFIRMED broken as a security boundary on
  LuaJIT** — see "Rejected: count-hook budgets" below. It remains useful as
  a *cooperative* bound (catches bugs and slow-but-not-adversarial scripts
  before they get JIT-hot), just not as a hostile-script defense.
- **LuaJIT-specific gotchas**, in order of how load-bearing crescent's
  choices already are:
  - `debug.sethook`'s count-hook interacts with JIT-compiled traces — **this
    interaction is now CONFIRMED, not just flagged as unbenchmarked** (the
    original text here said "not established anywhere in this codebase
    yet"; it has since been established — see "Rejected" below for the
    sourced, reproduced finding).
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
    partial re-export. A related, separate escape was found and fixed
    (already committed, `a71874aa`): the module whitelist used to include
    `"jit"`, letting sandboxed code `require("jit")` and get the entire
    unrestricted jit module (`jit.on/off/flush/attach` — process-wide
    DoS/introspection levers), bypassing the already-curated `safe_jit`
    table sitting next to it in globals. `"bit"` was investigated at the
    same time and kept — confirmed pure/side-effect-free, `globals.bit`
    already assigns the identical real module, no whitelist-bypass risk.
    Noted here as resolved context; not re-litigated by this document.
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
cap table the host composes and passes in. Nothing is ambient. Unchanged from
the original proposal.

**DECIDED:** game-state operations (reading/writing world/entity data) are
NOT capability-gated at all. They are not I/O crossing out of the sandbox, so
no cap applies. Only genuine external-resource crossings need a
capability/mediation mechanism — matching `lib/platform`'s existing cap
taxonomy: `http_client`, `db`, `kv`, `llm`, `fs`, ffi caps, `exec`/`shell`/
`pty`. This narrows what "capability bundle" even means for control-stage
mods: most of what a mod does (reading/writing entities, subscribing to
events) is not a cap surface at all under this decision.

**STILL OPEN — what a game-state-affecting cap (if any is even needed)
actually gates over.** An earlier framing floated during design discussion
was "one attenuatable cap type" for game-state mutation — this was
explicitly rejected as ungrounded when put to the owner directly ("i dont
know? sounds made up"). It is not established that game-state mutation needs
any cap at all beyond the "not I/O, not gated" decision above; if some
narrower concern turns out to need gating (e.g. one mod overwriting another
mod's owned entities), what that boundary concretely is has not been
designed. Do not treat "one attenuatable cap" as settled vocabulary — it
isn't.

**Still open, unchanged from the original proposal:**

- **What capability bundle is the control-stage default** for the genuine
  I/O caps that *do* apply (the `lib/platform` taxonomy above) — whether
  that's one broad `caps.engine` bundle or several narrower caps granted
  per-mod-manifest depends on what the engine substrate itself ends up
  exposing, which `genre-battery-design.md`'s "Prerequisites" section
  already flags as unbuilt (`lib/ecs` vs `lib/entity_component` gap,
  closed-dispatch-table libraries with no extension API).
- **Per-mod or per-manifest-declared caps?** Whether control-stage mods
  follow the platform daemon's declare-then-grant flow, or get a fixed
  default bundle with no per-mod variance, depends on the trust model for
  wherever mods come from (bundled-with-game vs. Workshop-style third-party
  distribution) — itself unresolved in `genre-battery-design.md`.

## 2. Bounded execution

### Rejected: `debug.sethook` count-hook / wall-clock budgets as a security mechanism

The original proposal's Options A and B (below, kept for record with a
REJECTED marker) both assumed a `debug.sethook` count-hook — instruction-count
or wall-clock-checking — is a real bound on a hostile or hung script.
**This is false on LuaJIT and has been confirmed two ways: by reading LuaJIT
`v2.1` source, and by reproducing the failure against the vendored binary in
this repo.**

- **Source-level:** trace recording in `lj_trace.c` only checks for GC and
  vmevent hooks before compiling a hot loop to a trace — it does not check
  for an active count or line hook. Once LuaJIT compiles a trace (after
  roughly 56 loop back-edges by default), the trace is native machine code
  (`lj_dispatch.c`, `vm_x64.dasc`) with zero dispatch-table/hook involvement.
  `hookcount` is frozen at whatever value it had at compile time; it is never
  decremented again while the trace runs.
- **Empirical, reproduced against the vendored LuaJIT in `bin/`:** an
  unconditional loop with no natural exit (`local i = 0; while true do i =
  i + 1 end`) run through `sandbox.run` with `opts.budget = 150` hits the
  hook and errors correctly. The same loop with `budget = 200` hangs
  forever — no error, no timeout, immune to the budget entirely. Calling
  `jit.off()` before the loop makes `budget = 200` fire correctly again,
  isolating the cause specifically to tracing (not to hook mechanics in
  general). This crossover — between LuaJIT's ~56-back-edge hot-loop
  threshold and this loop's ~3 bytecodes/iteration — is also documented as
  its own `TODO.md` entry (search "does not reliably fire"), filed
  independently before this document was updated; that entry is the
  canonical record of the reproduction, this document just carries the
  security-design consequence of it.

**Consequence:** a count-hook or wall-clock-check-inside-a-count-hook budget
is not a defense against an adversarial or genuinely hung script — a hostile
mod author (or a buggy one) can write a tight infinite loop that JIT-traces
past the hook and runs forever, unbounded, with no error surfaced anywhere.
It remains useful as a *cooperative* bound — catching non-adversarial bugs
and slow scripts before they get hot enough to trace — but it is not load-
bearing for anything that needs to survive a hostile mod. Options A and B
below are REJECTED on this basis, not merely deprioritized.

A separate, already-resolved bug in the same code path (commit `a71874aa`,
noted for completeness, not part of this document's open items): the
budget-hook cleanup used to call `debug.sethook(nil, "", nil)`
unconditionally on exit, clobbering any outer hook when `sandbox.run` calls
nest — now saves and restores the previous hook state.

### Rejected: async signal-based preemption

Floated as a candidate for a genuine hard interrupt (fire a signal handler
at an arbitrary point, `longjmp` out mid-execution, no cooperation from the
script required). **Rejected as unsupported and hazardous, not merely
undesirable:**

- LuaJIT's own unwind path (`lj_err_throw`) calls `lj_trace_abort()` before
  any `longjmp`, deliberately bringing trace state to a safe point first — an
  async signal handler firing at an arbitrary instruction cannot arrange
  this same safety.
- No source found of anyone shipping true async mid-trace interruption for
  LuaJIT.
- The closest real-world discussion found (Tarantool issue #4748) had a
  maintainer directly object to the premise ("who said sethook is
  async-signal-safe?") and converge instead on a flag-set-by-signal,
  synchronously-consumed-elsewhere pattern — which is what LuaJIT's own
  `LUAJIT_ENABLE_CHECKHOOK` does. That flag itself is unsupported/off-by-
  default upstream, and Mike Pall has confirmed it costs real per-iteration
  time in tight loops — rejected here on cost grounds as a separate,
  additional reason on top of the safety concern.

### Still open (unchanged from the original proposal, restated for the mechanisms that remain relevant)

- **Tick-frequency changes the cost tradeoff any process/state-boundary
  option makes.** `daemon-isolation.md` picked its tier for per-HTTP-request
  invocation. Control-stage code runs every game tick (e.g. 60/s) — a
  fundamentally different call-volume profile. Whether any given isolation
  tier's per-invocation overhead is acceptable at tick frequency has not
  been measured and needs its own benchmark, not an assumption carried over
  from the daemon's numbers.
- **What a violation means for a hung script vs. one that merely errors.** A
  script that raises (including via a cooperative budget) is a normal
  `(nil, errmsg)` case, already handled by `pcall` wrapping. A script that's
  genuinely hung (or adversarially avoiding the cooperative hook per
  "Rejected" above) needs a harder stop — this is exactly what "Decided
  direction" below addresses with process/thread-level interruption
  mechanisms, since no in-VM mechanism can do it.

## 3. LuaJIT interaction

- The env-injection mechanism (`load(src, name, "t", env)`) is the LuaJIT
  5.1-style fenv, not a 5.2 `_ENV` upvalue — already how `lib/sandbox` works,
  carries over unchanged for control-stage use.
- `ffi`, `string.dump`, bytecode `load`, `debug.*`, `getfenv`/`setfenv`, and
  `newproxy` are the enumerated LuaJIT-specific (or LuaJIT-relevant)
  escape-vector set `sandbox_audit_test.lua` already blacklists structurally.
  Any control-stage cap bundle built on top of `lib/sandbox.env` inherits
  this for free as long as it's built from `sandbox.stdlib`/`sandbox.pure`
  or passes through the same audit; a bundle built from scratch would need
  its own audit-test coverage.
- The count-hook / JIT-trace interaction, previously flagged here as
  unbenchmarked, is now resolved to a negative result: it's not a viable
  security mechanism (see "Rejected" above). This changes the shape of
  Section 2 from "needs a benchmark before any option can be chosen" to
  "the in-VM option is off the table; hard interruption needs an OS-level
  boundary."
- **`fork()`-without-`exec()` safety on LuaJIT is undocumented upstream** —
  searched the LuaJIT mailing list and issue tracker for `fork()` as a
  syscall; zero hits. Silence, not endorsement. This is a real substrate gap
  for any fork-based implementation under "Decided direction" below — see
  that section's caveats.

## Decided direction

**No single "correct" architecture. Multiple independent implementations,
per this repo's own convention** ("When one implementation can't satisfy all
legitimate use cases, provide multiple... each is a real, independent
implementation; never wrap one around another" — `CLAUDE.md`, invoked
directly for this decision). Concretely:

- **Process isolation, as at least two genuinely separate implementations:**
  - **(a) Direct `fork()` from the host process itself.** Cheap (page-table
    copy, COW-deferred), precedented (Chromium's zygote forks without exec
    specifically to skip re-paying dynamic-linker cost per spawn). Only safe
    when the host process is single-threaded at fork time — if the host has
    any other live thread, any lock that thread held stays locked forever in
    the forked child (POSIX law, `pthread_atfork(3)`: "in practice, this
    task is generally too difficult to be practicable" to fix generically),
    and POSIX also restricts the child to async-signal-safe calls only,
    which never lifts for a fork-without-exec child's entire life. Whether a
    given game host is single- or multi-threaded is a downstream game
    author's per-game decision, not something crescent can verify or
    enforce — so this is an opt-in path with a documented precondition, not
    a default. `fork()`'s LuaJIT-safety is itself undocumented upstream (see
    Section 3) — a real open substrate risk this implementation carries, not
    a solved problem being reused.
  - **(b) A minimal, deliberately single-threaded external supervisor
    process that forks mod children on the host's behalf.** Sidesteps the
    multithreaded-fork hazard entirely regardless of what the host does
    (the supervisor controls its own threading), and enables a pre-warmed
    process pool amortizing spawn cost the same way Chromium's zygote does.
  - These are not variants of one thing — build them as two independent
    implementations per the tiering convention, not one wrapping the other.
- **Thread-based isolation (separate `lua_State` per OS thread, same
  process) as a third independent implementation.** Weaker guarantees — no
  fault containment (an FFI/C bug in one mod corrupts the whole process
  regardless of separate Lua states, since the address space is shared) and
  no cheap forced-stop (`pthread_cancel`'s deferred-mode cancellation points
  are never hit by a tight compute loop with no blocking syscalls; async
  cancellation is documented unsafe for arbitrary code) — but cheaper, for
  callers who accept "isolate mods from corrupting each other's Lua state"
  rather than "defend against a hostile script."
- **The interruption/stop mechanism is also multiple independent,
  user-selectable implementations, not one chosen mechanism:**
  - **(a) Process kill (SIGKILL)** — real, but only for actual separate OS
    processes. On Linux, SIGKILL and any signal with terminate/stop/continue
    disposition only isolate at process granularity, not thread granularity
    (`pthread_kill(3)`: "if the disposition of the signal is 'stop',
    'continue', or 'terminate', this action will affect the whole process";
    `ptrace(2)`: a stopping signal to any thread of a multithreaded process
    stops all its threads). `tgkill()` only controls delivery *targeting*,
    not the *scope of effect* for these dispositions. This means "just
    SIGKILL the stuck mod's thread" is not a real per-mod primitive for the
    thread-based implementation above — only a genuinely separate process
    gets a clean, kernel-enforced kill.
  - **(b) `ptrace`-based single-thread suspend, for the thread-based
    implementation.** `PTRACE_SEIZE` + `PTRACE_INTERRUPT` is genuinely
    per-thread (distinct from SIGSTOP's whole-process group-stop). Real and
    usable **against a genuinely separate process** (fork_direct/
    fork_supervisor pid), but debugger/checkpoint-tool-grade (the pattern
    gdb non-stop mode, `rr`, and CRIU use) — heavy for an everyday
    primitive, and only one tracer may attach to a tracee at a time, which
    breaks if the process is already being debugged or profiled by
    something else. **CORRECTION (2026-08-14, superseding the claim this
    bullet originally made):** self-attach from a sibling thread in the
    same process is NOT permitted, contrary to what this bullet said when
    written. The sentence being quoted from `ptrace(2)` ("If the calling
    thread and the target thread are in the same thread group, access is
    always allowed") describes the permission-check HELPER
    (`__ptrace_may_access()`, also used for `/proc` access), not the attach
    syscall as a whole — Linux's `ptrace_attach()` (`kernel/ptrace.c`)
    contains its own, separate, unconditional
    `if (same_thread_group(task, current)) return -EPERM;` ahead of that
    helper, so a thread can never `PTRACE_SEIZE`/`PTRACE_ATTACH` a sibling
    thread in its own thread group, on any kernel, at any privilege level.
    This was diagnosed empirically (kernel source read + a bare-C, no-Lua
    reproduction) while investigating `interrupt_ptrace.lua`'s observed
    `EPERM` against `thread.lua` targets — see that module's "Implemented"
    entry below for the full citation. Consequence for THIS mechanism: (b)
    is real and usable only against implementation (a)'s separate-process
    targets (fork_direct/fork_supervisor); it cannot suspend a thread-based
    implementation's own units from the process that spawned them, at all
    — the parenthetical this bullet used to end with ("no separate tracer
    process required") is exactly backwards for that case, a separate
    tracer process is the only thing that could ever make (b) apply to a
    thread.lua unit, and doing so is a different architecture, not
    implemented here.
  - **(c) Manually-instrumented loop checks (cooperative).** In-code budget
    checks the mod/game author opts into and pays the per-iteration cost
    for. Earlier explored and rejected as a *mandatory universal* mechanism
    (a hard 10% overhead ceiling on tiny loops makes that untenable), but as
    an *optional* mechanism for callers who want it and accept the cost,
    it's legitimate and should be offered, not foreclosed by the mandatory-
    case rejection.

These decisions concern architecture shape and which mechanisms are real vs.
dead. They do not specify pool sizing, IPC wire format, cap-call latency
budget, or any other implementation parameter — those are open, below.

## Implemented: `lib/os_isolation`

The isolation/interruption mechanisms above are built, as `lib/os_isolation/`
— a new module, deliberately separate from `lib/sandbox` (which keeps its
existing name and scope unchanged: in-process capability restriction via a
`require` whitelist + curated globals, same OS process/thread as the
caller). The split is not a rename; it is two genuinely different failure
domains kept visibly apart per the repo owner's explicit instruction, not
defaulted into one module: `lib/sandbox` restricts what code can *reach*;
`lib/os_isolation` restricts what a failure or a hang can *do to the rest of
the process*. They compose — run `lib.sandbox`-restricted code inside an
`lib.os_isolation`-isolated child for both properties at once.

- **`fork_direct.lua`** — implementation (a) above. Direct `fork()`, no
  `exec()`, same LuaJIT image; `spawn(fn)` runs a Lua closure in the child
  (COW gives it the caller's captured state for free — no serialization for
  inputs), `handle.join()` blocks for the result. The single-threaded
  precondition is checked on Linux via `/proc/self/status`'s `Threads:`
  line and REFUSED (not silently risked) when violated — confirmed
  end-to-end: a real second OS thread (via `thread.lua`) calling
  `fork_direct.spawn` while the main thread is still alive is detected and
  rejected with an explanatory error, not a silent corruption. Best-effort
  only (a thread starting between the check and the syscall is still a real
  gap, and the check doesn't run at all off Linux) — the module header says
  so plainly.
- **`fork_supervisor.lua`** — implementation (b) above, plus
  `supervisor_main.lua` (the supervisor's own entry point, run via
  `bin/cr`). Resolves the "process-pool sizing and lifecycle" item that was
  open below: v1 is deliberately simple — one supervisor process per
  `start()` call, no pre-warmed pool, spawn-on-demand. `spawn()` does not
  block on the child (the supervisor forks and replies with the pid
  immediately), so multiple children spawned through one supervisor run
  concurrently; only the supervisor's own request/response bookkeeping is
  serial. This is a first-implementation default, not a claim that pooling
  or pre-warming is unnecessary — a caller wanting either builds it on top.
  Only Lua source text + JSON-representable args cross the boundary (no
  closures — genuinely a different process image).
- **`thread.lua`** — the separate-`lua_State`-per-OS-thread implementation.
  Built via a pure-FFI callback pattern (create a second `lua_State` with
  `luaL_newstate()`, run a bootstrap chunk on it from the calling thread
  that builds an FFI callback, hand the callback's raw pointer to
  `pthread_create()`) — no vendored C shim, following the pattern LuaJIT's
  author (Mike Pall) described directly for this scenario and that
  `github.com/luapower/pthread` + `luapower/luastate` implement as real,
  running code. Verified against this repo's own vendored LuaJIT binary:
  `luaL_newstate`/`luaL_openlibs`/`luaL_loadstring`/`lua_pcall`/`lua_close`
  and the string/field accessors used to move code, args, and results
  across are all reachable via `ffi.C`. **One open safety question is
  carried, narrowed by follow-up but not resolved**: no primary source (not
  the mailing-list post, not LuaJIT's FFI docs, not `lj_ccallback.c`)
  confirms or rules out a GC-phase or reentrancy hazard specific to the
  callback's first invocation happening on a brand-new OS thread LuaJIT's
  runtime has never seen. Follow-up investigation searched
  `github.com/luapower/pthread`'s own issue tracker (empty, nothing
  relevant) and `LuaJIT/LuaJIT`'s issue tracker directly, and found a real,
  confirmed, FIXED bug in the closest matching category:
  [LuaJIT/LuaJIT#1498](https://github.com/LuaJIT/LuaJIT/issues/1498), "FFI
  callback invoked from C leaves `cur_L` stale — crash in `lj_trace_exit`
  when the compiled callback takes a trace exit" (filed 2026-07-31, fixed
  2026-08-01). Its precondition is a shared `global_State` whose `cur_L`
  (last thread to enter the VM, not updated by the FFI callback entry path)
  points at a different coroutine/thread than the one the callback actually
  fires on. Structural analysis of `thread.lua`'s own shape (not the
  upstream fix itself) shows this precondition doesn't arise there: each
  `spawn()` owns an independent `global_State` (its own `luaL_newstate()`,
  never shared with another `spawn()` or given coroutines by this module),
  and the bootstrap's synchronous `lua_pcall` — run on the calling thread,
  before `pthread_create` — already sets that `global_State`'s `cur_L` to
  the only `lua_State` it will ever have, before the new pthread exists.
  This rules out this SPECIFIC known bug for this SPECIFIC code shape by
  source-grounded reasoning, not just absence of a report — but does not
  cover every possible hazard (notably not
  [#1506](https://github.com/LuaJIT/LuaJIT/issues/1506), "`store to dead GC
  object` in FFI callback," a different GC-liveness mechanism, still open
  upstream as of 2026-08-14, not analyzed to the same depth here). This
  repo's own vendored LuaJIT (`bin/luajit-bin`, tracking the `v2.1` branch,
  last updated 2026-07-25) predates the #1498 fix (2026-08-01) by about a
  week — re-running `.github/workflows/build-vendored.yml` would pick it
  up, but that workflow re-vendors LuaJIT/sqlite3/zlib/libressl/wepoll
  together across every supported platform, a repo-wide call left as an
  explicit recommendation rather than made unilaterally here. **Empirically**,
  a new permanent regression test,
  `lib/os_isolation/thread_stress_test.lua`, exercises concurrent spawns
  under deliberate GC pressure on both parent and child sides and asserts
  exact per-thread result correctness (cross-thread corruption would show as
  a wrong value, not require a crash). Beyond its own runs, this
  investigation additionally ran it by hand repeatedly (20 serial + 8
  parallel invocations) plus a heavier one-off variant (150 concurrent
  threads under GC pressure, singly and as 6 parallel copies) — several
  thousand additional spawn/join cycles under deliberate concurrent GC
  pressure, on top of the earlier "dozens of spawn/join cycles, trivial to
  200M+ loop iterations" testing. Zero crashes, zero corruption, zero wrong
  results in any run — still not a safety proof, but real adversarial
  exercise of the exact mechanism, not merely "nobody has written about
  this." **A second, distinct finding from the original testing**: the full
  `lib/os_isolation` test suite occasionally took far longer to complete
  than its normal sub-few-seconds run time — most reliably reproduced by
  running several full copies of the suite in parallel (an artificial
  stress case), but also observed, less often, on a single serial `bin/cr
  test` invocation. Each individual workload run in isolation (up to tens
  of millions of loop iterations) consistently completed in well under a
  second on its own; the slowdowns showed up specifically running the FULL
  suite (many spawns across many test files), which points at ordinary CPU
  contention across many concurrently forked processes and pthreads rather
  than a hang in the mechanism itself — but this is circumstantial timing
  evidence, not a proof, and it is not ruled out as something worse. The
  additional parallel stress runs above did NOT reproduce this slowdown, a
  further data point against it being that hazard, but not a resolution —
  it was rare before, so its absence in a handful of runs doesn't rule it
  back in or out. A caller running many `thread.lua` units concurrently
  should not assume a short fixed timeout is safe. Gives GC/heap separation
  between units, explicitly NOT fault containment (shared address space —
  an FFI/C bug in one unit can still corrupt the whole process) and NOT a
  cheap forced-stop, exactly as this section already said above.
- **`interrupt_kill.lua`** — mechanism (a). `SIGKILL` against a real pid.
  Confirmed to actually stop an unconditional infinite loop in a
  `fork_direct`/`fork_supervisor` child (not merely documented as
  process-granularity-only — exercised).
- **`interrupt_ptrace.lua`** — mechanism (b). `PTRACE_SEIZE` +
  `PTRACE_INTERRUPT` suspend, `PTRACE_CONT` resume, `PTRACE_DETACH`. Linux
  only, reports unavailable via `(nil, errmsg)` elsewhere, per this repo's
  tiering convention (no pure-Lua fallback exists — ptrace is inherently a
  syscall). **Confirmed working against a real `fork_direct` child pid**
  with no special privilege needed (parent/child ptrace is always allowed).
  **`EPERM` against a `thread.lua` unit's own tid is now ROOT-CAUSED, not
  merely observed (2026-08-14 follow-up investigation) — and the cause is
  permanent, not environmental.** Linux's `kernel/ptrace.c` `ptrace_attach()`
  (the function backing both `PTRACE_ATTACH` and `PTRACE_SEIZE`) contains,
  before it calls the `__ptrace_may_access()` permission helper:
  `if (unlikely(task->flags & PF_KTHREAD)) return -EPERM;` then
  `if (same_thread_group(task, current)) return -EPERM;` — an unconditional
  refusal to let one thread `ptrace`-attach a sibling thread in its own
  thread group, regardless of privilege, capabilities, or Yama
  `ptrace_scope`. This is a DIFFERENT code path from the "ptrace access mode
  checking" algorithm `ptrace(2)` documents with "If the calling thread and
  the target thread are in the same thread group, access is always
  allowed" — that sentence is true of `__ptrace_may_access()` (also used for
  `/proc/<pid>/mem`-style checks) but does not describe the attach syscall's
  own separate, earlier, unconditional same-thread-group rejection. Verified
  two independent ways, not assumed: (1) read the actual kernel source for
  `ptrace_attach()` and confirmed the `same_thread_group()` check quoted
  above; (2) reproduced in bare C with no Lua/FFI involved — a pthread
  sibling obtained its own tid via a raw `syscall(SYS_gettid)`, and the
  main thread's `PTRACE_SEIZE` against that genuine tid failed with `EPERM`
  every time (`strace` confirmed the syscall itself returns it), while a
  control test in the same investigation confirmed real
  parent-process-to-child-process `ptrace` (the `fork_direct`/
  `fork_supervisor` case above) succeeds with no special privilege, and a
  second control confirmed a genuinely separate (forked, non-ancestor)
  process attempting the same sibling-thread tid is independently denied
  by Yama's `ptrace_scope` (`1` on this machine, restricted-to-descendants)
  — a different, config-dependent EPERM cause than the unconditional
  same-thread-group one, correctly distinguishable only by knowing which
  relationship the target has to the caller, not from errno alone. Also
  ruled out during this investigation: a container/seccomp boundary (this
  shell is not containerized — no `/.dockerenv`, host `init.scope` cgroup,
  `Seccomp: 0`) and a `pthread_t`-vs-kernel-tid confusion in `thread.lua`'s
  own code (`thread.lua` already captures the real kernel tid via a raw
  `syscall(SYS_gettid)`, not `pthread_self()` — confirmed correct by
  reading the code, and independently by the pure-C reproduction using no
  Lua/FFI path at all yet hitting the identical `EPERM`). **Practical
  consequence: there is no deployment/config knob that makes
  `interrupt_ptrace.lua` suspend a `thread.lua` unit from the process that
  spawned it — that specific pairing is a permanent architectural dead
  end, not a "verify in your deployment target" caveat.** The module's
  error message and header now state this plainly instead of blaming an
  environment/sandbox layer. The only way `ptrace` could ever suspend a
  `thread.lua` unit is a genuinely separate OS process acting as tracer
  (not the spawning process) — which then falls under the ordinary
  cross-process rules (Yama/capabilities) this module already handles
  correctly for `fork_direct`/`fork_supervisor` pids — a different
  architecture (a dedicated tracer-process helper), not implemented here.
- **`interrupt_cooperative.lua`** — mechanism (c). Opt-in `checker:tick()`
  calls the author places inline in their own loop; verified it bounds
  exactly the loop shape this document's "Rejected: `debug.sethook`
  count-hook budgets" section documents as escaping a hook-based budget
  once JIT-traced (an inline call is ordinary code the trace must include).

Tests: each implementation has its own `*_test.lua`
(`fork_direct_test.lua`, `fork_supervisor_test.lua`, `thread_test.lua`,
`interrupt_kill_test.lua`, `interrupt_ptrace_test.lua`,
`interrupt_cooperative_test.lua`), plus `os_isolation_parity_test.lua`
exercising the same logical programs (success, JSON-args-round-trip, error
propagation) across all three isolation implementations and asserting
convergent `(ok, result)` outcomes, per this repo's "parity tests... not
optional polish" convention, plus `thread_stress_test.lua` (see
`thread.lua`'s implementation note above) as a permanent regression check
for the callback-on-a-foreign-thread open safety question specifically. No
benchmarks yet — see "still genuinely open" below.

## Still genuinely open

Do not treat any of these as decided; none of them were.

- **What a game-state-affecting cap (if any) gates over.** See Section 1.
  The "one attenuatable cap" framing floated in design discussion was not
  grounded and should not be read as settled vocabulary.
- **Cap-call IPC mechanism for the genuine I/O caps**, for whichever
  process-isolated implementation is used: shared-memory ring buffer vs.
  Unix domain socket vs. something else is not chosen. Only rough latency
  numbers have been sourced (shared memory ~270ns, UDS ~4.6–5.9µs, one blog
  benchmark) — with a methodology caveat: it's unclear whether that measured
  a blocking wait or a busy-spin, which matters significantly for a design
  where a caller actually blocks on the call.
- **Process-pool sizing and lifecycle beyond `fork_supervisor.lua`'s v1**
  — v1 (one supervisor process per `start()`, spawn-on-demand, no
  pre-warming — see "Implemented" above) is a deliberately simple first
  default, not a claim that pre-warmed pools or multi-supervisor scaling
  are unneeded. Sizing/warm-pool policy for callers that need higher
  throughput is still open.
- **Whether a given game host is single- or multi-threaded is explicitly not
  crescent's call.** It's a downstream game author's per-game decision, not
  something this document (or any future one) should resolve on their
  behalf — implementation (a) above documents the precondition rather than
  assuming an answer.
- **What capability bundle is the control-stage default**, and **per-mod vs.
  per-manifest-declared caps** — both restated from Section 1, unresolved by
  anything decided above; they depend on engine substrate that doesn't exist
  yet (`genre-battery-design.md`'s "Prerequisites") and on a mod-distribution
  trust model that's separately unresolved.
- **Tick-frequency overhead of any process/thread-boundary implementation**
  — not measured; `daemon-isolation.md`'s per-request numbers do not transfer
  to a per-tick calling shape without new measurement. No benchmarks exist
  yet for `lib/os_isolation`'s three implementations at all (single-shot
  spawn/join timing was observed informally while testing — sub-second even
  for a 200M-iteration workload — but nothing recorded to
  `docs/perf/log.md`, and per-CLAUDE.md convention it should be before any
  tick-frequency viability claim is made).
- **`thread.lua`'s behavior under heavy concurrent spawn load is not fully
  diagnosed**, only observed — see "Implemented" above. Circumstantial
  evidence points at CPU contention (isolated/serial runs of the identical
  workload were consistently fast; many-way-parallel runs of the same
  workload were not), not a hang in the mechanism itself, but this was not
  proven, and it was not ruled out as the GC-phase/reentrancy hazard the
  callback-on-a-foreign-thread open safety question already names. Needs
  real profiling (not more manual `timeout`-wrapped trials) before any
  claim stronger than "works in the common case, degrades unpredictably
  under self-constructed extreme concurrent load" is warranted.
- ~~`interrupt_ptrace.lua` against a `thread.lua` tid is environment-
  dependent~~ — **RESOLVED (2026-08-14), moved out of "open": it is not
  environment-dependent, it is permanently impossible for that specific
  pairing.** See `interrupt_ptrace.lua`'s "Implemented" entry above for the
  full root-cause citation (an unconditional `same_thread_group()` check in
  Linux's own `ptrace_attach()`, verified via kernel source and a bare-C
  reproduction). Nothing remains open here to diagnose further.

## Design options (historical — superseded)

The three options below are the original proposal's framing, kept for
record. **A and B are REJECTED** — their bounding mechanism (`debug.sethook`
count-hook / wall-clock-in-count-hook) is confirmed non-viable as a security
boundary on LuaJIT (see Section 2, "Rejected"). **C is subsumed** by
"Decided direction" above, which resolves its "hybrid with A/B, no
recommendation" framing into concrete, named, independent implementations —
read that section instead of this one for anything actionable. This section
is retained only so the reasoning trail (why A/B looked plausible before the
count-hook finding) isn't lost.

### Option A (REJECTED) — reuse `lib/sandbox.run` as-is, per-invocation instruction budget

Control-stage mod callbacks invoked through `sandbox.run(code_or_fn, env,
{ budget = N })` directly, no new mechanism. Rejected because the
`opts.budget` count-hook does not fire once a hot loop gets JIT-traced (see
Section 2) — a hostile or genuinely buggy tight loop is not bounded by this
at all, unconditionally. Remains valid as a *cooperative* bound (see
"Decided direction," interruption mechanism (c)), just not as the sole or
primary defense this option originally proposed it as.

### Option B (REJECTED) — coroutine + wall-clock preemption

Same in-process model as A, with the count-hook checking wall-clock deadline
instead of raw instruction count. Rejected for the identical reason as A:
the underlying `debug.sethook` mechanism stops firing once the loop is
JIT-traced, regardless of what the hook body checks. A wall-clock check
inside a hook that may never fire again provides no additional bound over A.

### Option C (superseded) — separate `lua_State` (or process) per mod

Originally framed as "hybrid with A/B... no recommendation between tier 2 and
tier 3." "Decided direction" above replaces this framing: both process
isolation and thread-based `lua_State` isolation are now named as concrete,
independent implementations (not a single "escalate to tier N" choice), and
interruption is itself multiple selectable mechanisms rather than bundled
into the isolation tier choice. The specific overhead and lifecycle
questions this option raised (serialization/IPC cost at tick frequency,
process-pool sizing) are carried forward as open items above, not resolved.

## What this document does not do

No IPC mechanism chosen for cap calls. No pool sizing or lifecycle design
for the supervisor implementation. No definition of what a game-state cap
(if one is even needed) gates over — an earlier "one attenuatable cap"
framing was floated and explicitly not grounded; do not read it as settled.
No decision on the control-stage default capability bundle for the caps that
do apply. No decision on per-mod-declared vs. fixed caps. No measurement of
any isolation tier's overhead at control-stage's per-tick calling frequency.
No mod-loader-shape decision. All of these are named as open in the relevant
section above rather than guessed at.
