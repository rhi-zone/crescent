# Task cap: pull-based PTY + background coroutines

## Context

The terminal mux needs a background coroutine (PTY reader that broadcasts to
clients) running concurrently with per-client WS handlers. The PTY reader
outlives any single WS connection — it runs as long as the PTY child process
is alive, regardless of how many clients are attached.

## Options considered

### 1. Push-based PTY cap (on_output callback, read loop internal to cap)

The PTY cap would own the reader loop internally and call an `on_output`
callback for each chunk. The app registers the callback at spawn time:

```lua
pty.spawn(cmd, { on_output = function(data) ... end })
```

**Pros:** No background-task substrate needed; the read loop is internal to the
cap, already running on the daemon's event loop.

**Cons:** Callback-based I/O traces poorly under LuaJIT — the JIT compiler
cannot trace across callback boundaries the way it traces straight-line code
between coroutine yields. Breaks the pull-based I/O convention that every other
cap in the codebase follows (`read()` → yields → returns data). The app cannot
control backpressure (callbacks arrive whether the app is ready or not).

### 2. Pull-based PTY + task cap for background coroutines (chosen)

The PTY cap stays pull-based (`handle.read()` yields until data arrives). A new
`task` cap lets apps spawn background coroutines on the daemon's event loop.
The terminal mux spawns a reader task per session:

```lua
caps.task.spawn(function()
  while true do
    local data = pty_handle.read()
    if not data then break end
    vt_term:feed(data)
    broadcast(session, data)
  end
end)
```

Task handles support cooperative cancellation via `async.cancellable`. Cap
revocation cancels all active tasks.

**Pros:** Pull API matches every other I/O primitive in the codebase. LuaJIT
traces straight-line code between yields better than callbacks. The task cap
is general substrate — not PTY-specific — usable by any app that needs
concurrent coroutines. Cancellation is explicit and cooperative.

**Cons:** Adds a new cap type to the platform. Apps must manage the lifecycle
of spawned tasks (though revocation provides a backstop).

### 3. Pull-based PTY + no cancel on day one

Same as (2) but without cancellation in the task cap. Simpler implementation;
tasks run until they return or error.

**Cons:** No way to clean up a stuck task. Cap revocation cannot stop running
tasks. A PTY whose child never exits and whose reader never errors would leak
the coroutine. Cancellation is cheap to add from the start and expensive to
retrofit (existing callers would need migration).

## Decision

Option 2: pull-based PTY + task cap with cancellable coroutines.

## Uncertainty

- Whether pull is measurably better than push for I/O-bound workloads. The
  LuaJIT tracing argument is sound for compute-heavy paths but terminal I/O
  is dominated by syscall latency, not interpreter overhead.
- Whether apps will abuse `task.spawn` (unbounded coroutine creation). The
  cap's revocation-cancels-all provides a coarse backstop; per-app task limits
  could be added later without API changes.
- Whether structured concurrency (task groups, join, nurseries) is eventually
  needed. The task cap's small surface (`spawn` → `TaskHandle` with `cancel` +
  `done`) is extensible if these concerns materialise — a `task.group()` method
  could return a handle that cancels children on scope exit.
