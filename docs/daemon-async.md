# Async-First Daemon Architecture

Status: design — no code has been rewritten yet. This document describes the target
architecture and the migration path from the current daemon. It does not resolve
every question (see "Open questions" below); those are recorded so they aren't
silently decided by whoever implements a given phase.

## Motivation

`lib/platform/daemon/init.lua` (see `docs/daemon-design.md`) is synchronous
request-response: `lib/http/server.lua` drives one blocking accept loop, and
`d.handle(req, res)` runs a handler to completion before the socket is read
again. This is sufficient for today's daemon — HTML pages, JSON API calls,
grant flow — because every request is a single round trip with no reason to
hold the connection open.

It cannot support what's coming next:

- **WebSocket connections** (`lib/websocket`, `lib/http/server_ws.lua` exist as
  a standalone prototype, not integrated into the platform daemon). A WS
  connection is long-lived; the current daemon has no notion of a connection
  that outlives one handler call.
- **PTY fd multiplexing** for a terminal mux app — the daemon needs to watch
  N pty master fds plus M client sockets concurrently, in the same process, on
  the same event loop.
- **Server-initiated push** — an app needs to write to a client without the
  client having just sent a request (terminal output arriving async, PTY
  data, notifications).

Bolting long-lived connections onto a per-request blocking-accept loop means
either a thread/process per connection (contradicts "zero-dependency, single
process" and complicates cap revocation) or hand-rolled multiplexing bypassing
`lib/async` entirely (duplicates what `lib/async` + `lib/io_poll` already do).
Instead: rebuild the daemon's I/O core around `lib/async.loop()` driven by
`lib/io_poll`, so HTTP, WebSocket, and cap-owned fds (PTYs, timers) are all
just participants on one poller.

## Architecture

The new daemon is a single async event loop —
`local loop = async.loop(io_poll_instance)` (see `lib/async/init.lua` —
`M.loop(poller, opts)` returns a `LoopObj` with `queue`, `sleep`,
`await_readable`, `await_writable`, `run_until`). One process, one poller
(`lib/io_poll` dispatches to `lib/epoll` on Linux/Windows, `lib/kqueue` on
macOS — see `lib/io_poll/init.lua`), one loop drives all of:

- HTTP connection handling — each accepted connection is a coroutine.
- WebSocket connections — long-lived coroutines, no request timeout.
- Cap I/O — PTY fds, timers, whatever else a cap needs to watch, registered
  on the same shared poller instead of each cap running its own loop.

Key principles:

- **One poller, one event loop, everything multiplexed.** No cap, no
  connection type, and no app gets its own poller or its own thread. This is
  what makes N PTYs + M WS connections + HTTP all coexist in one process
  without contention or duplicated wakeups.
- **Each connection is a coroutine that can yield.** `lib/async.async(fn)`
  wraps a function as a coroutine-backed promise; inside it, `async.await(p)`
  suspends until `p` settles. A connection's lifecycle (read request → route →
  handle → write response, or: upgrade → message loop) is written as
  straight-line code that yields at I/O points, not as a callback chain.
- **Caps can register fds with the shared poller.** The "daemon context"
  (below) is the seam: it's passed to cap factories (not exposed to apps) so
  a cap that owns an fd — PTY master, a timer, anything — can multiplex on
  the daemon's poller instead of managing its own I/O.
- **App handlers run inside coroutines.** A handler can call an async cap
  (one that internally does `async.await(...)`) and yield through it; from
  the app's perspective this may be transparent (see open question below) or
  may require the handler itself to be async-aware — that's not yet decided.

## Connection lifecycle

### HTTP

1. Accept → spawn a coroutine for this connection (via `async.async`).
2. Read request headers — `loop:await_readable(fd)`, then parse once data
   arrives (framing logic ports from `lib/http/format.lua` /
   `lib/socket/server.lua`, adapted to pull bytes only when the promise
   resolves rather than blocking on `recv`).
3. Route to the app handler (Host-based dispatch, same as today's
   `M.classify_host` / `handle_daemon` / `handle`).
4. App handler runs. It may call async caps that yield the coroutine back to
   the loop; the loop keeps servicing other connections meanwhile.
5. Write response — `loop:await_writable(fd)` before/while writing, so a slow
   client with a full send buffer doesn't block other connections.
6. Close, or keep the coroutine alive and go back to step 2 on keep-alive
   (see open question on keep-alive semantics).

### WebSocket

1. Accept → spawn a coroutine.
2. Read the HTTP upgrade request (same read path as HTTP step 2, up to the
   point of determining `Upgrade: websocket`).
3. Route to the app's WS handler, registered via a `ws_server` cap (naming
   TBD — see `lib/websocket/init.lua`'s `mod.websocket(sock, req, read, close,
   epoll)` for the shape being adapted: it takes a socket, the parsed request,
   an `on_message` callback, an `on_close` callback, and something exposing
   `:modify(fd, on_readable, on_close)` — currently an `epoll` instance
   directly; the async rebuild replaces that direct epoll dependency with the
   shared `DaemonCtx`).
4. Upgrade response sent (`101 Switching Protocols`, `Sec-WebSocket-Accept`
   computed via `lib/hash/sha1` + `lib/encode/base64`, exactly as
   `lib/websocket/init.lua` does today).
5. Connection stays open. Unlike today's `epoll:modify`-driven callback model
   in `lib/websocket/init.lua`, the coroutine itself drives the message loop —
   `loop:await_readable(fd)` in a loop, decoding frames as they arrive
   (`lib/websocket/frame.lua`'s `_decode_full` / `_unmask`, same codec, new
   driver).
6. The app's `on_message` callback fires per decoded frame (mirrors
   `WsHandler.ws` in `lib/http/server_ws.lua` today).
7. The app can push at any time — `cap.send(msg)` writes a frame
   independent of the read loop; this is the main new capability the
   sync daemon cannot offer (nothing today lets a handler write outside of
   its single request/response call).
8. Close on client disconnect (fd close callback, same `is_close` shape
   `Loop:await_readable` already reports) or when the app calls
   `cap.close()`.

## Daemon context

A `DaemonCtx` is constructed once at daemon startup and threaded through cap
construction — never exposed to apps (this preserves the
`lib/platform/CLAUDE.md` invariant that caps are the only side-effect
surface apps see; `DaemonCtx` is host-side wiring, one level further in than
even a cap factory's own `opts`):

```lua
DaemonCtx = {
    poller: io_poll instance,   -- e.g. lib/epoll or lib/kqueue, from lib/io_poll
    loop: async.loop instance,  -- lib/async's LoopObj
    register_fd: (fd, on_readable) -> unregister_fn,
    schedule: (fn) -> nil,      -- queue work on the event loop (Loop:queue)
}
```

`register_fd` and `schedule` are thin, cap-facing wrappers over the
lower-level `Poller:add` / `Loop:queue` primitives already in `lib/async` and
`lib/io_poll` — the wrapping exists so a cap factory doesn't need direct
access to the raw poller/loop objects (matching the caps-first discipline:
a cap gets exactly the surface it needs, not the whole daemon).

**New cap factory calling convention:**

```lua
function M.cap(opts, daemon_ctx) -> (cap_table, revoke_fn)
```

This adds a second parameter to every cap factory. All existing caps accept
it but most ignore it — a `kv` or `http_client` cap has no fd to register and
no reason to touch the loop. PTY and WS caps are the ones that use it: a PTY
cap calls `daemon_ctx.register_fd(pty_master_fd, on_readable)` to get woken
when the child writes; a WS-server cap uses `daemon_ctx` to hook into the
same upgrade-routing / message-loop machinery described above rather than
running its own epoll instance (which is what `lib/websocket/init.lua` /
`lib/http/server_ws.lua` do today, standalone).

## Migration path

The rewrite preserves all existing features — nothing here is a scope cut:

- HTTP routing (Host-based app dispatch — `M.classify_host`, the router in
  `handle_daemon`, loopback-IP and subdomain forms).
- Session management (SQLite-backed via `lib/platform/session_store`, or the
  in-memory table fallback).
- Cap construction + revocation (`(cap_table, revoke_fn)` factories).
- App loading + sandboxing (`lib/platform/daemon/app_loader`, the sandbox
  model in `lib/platform/CLAUDE.md`).
- Rate limiting (`lib/rate_limiter`, today's per-session token buckets on
  `/launch` and `POST /grant`).

What changes is **how** they're implemented, not their behavior at the app
or operator-facing boundary:

| Today (sync)                                              | After (async)                                                  |
|-------------------------------------------------------------|-------------------------------------------------------------|
| Socket accept blocks in `lib/http/server`'s loop            | Accept goes through the poller; each accept spawns a coroutine |
| Request parsing reads synchronously to completion           | Parsing happens inside a coroutine, yielding on `await_readable` |
| Response writing is one synchronous write                   | Writing yields on `await_writable` in the same coroutine        |
| App handler is called inline, must return before next request | App handler is called inside the coroutine; can yield via async caps |

## What's NOT changing

- Manifest format.
- Cap interfaces from the app's perspective (an app calling `caps.kv.get(k)`
  sees the same signature; only cap *factories*, which apps never see, gain
  the `daemon_ctx` parameter).
- App sandbox model (`lib/platform/CLAUDE.md`'s invariants — no `io`/`os`/
  `ffi`/`debug`/host `require` in the sandbox env, caps as the only
  side-effect surface).
- The platform CLI (`lib/platform/daemon/cli.lua`'s flags and startup
  sequence — `--host`, `--port`, `--apps-dir`, `--status`, etc.).

## Open questions

These are open, not resolved here — listed so implementation phases don't
quietly invent an answer:

- **Sandbox / coroutine interaction.** Does the app handler need to be
  written coroutine-aware (e.g. call `async.await` itself), or is yielding
  meant to be transparent — the app calls what looks like a plain blocking
  cap function, and the cap internally suspends the coroutine without the
  app's code needing to know? These imply different sandbox env shapes and
  different constraints on what "async cap" means from inside the sandbox.
- **Keep-alive / connection pooling semantics.** Does the async HTTP path
  keep a coroutine alive across multiple requests on the same socket, and if
  so, what bounds (idle timeout, max requests per connection) apply? Not
  decided.
- **Graceful shutdown.** How in-flight coroutines drain (or don't) on daemon
  stop/restart — wait for completion, hard-cancel, or something in between —
  is unresolved.
- **Error handling in coroutines.** An unhandled error inside a handler
  coroutine must not crash the daemon (today's `invoke_app_handler` uses
  `xpcall` per request for this). What the equivalent boundary is per
  coroutine, and how it's enforced without every cap/handler author having
  to remember it, isn't decided.
- **Rate limiting under concurrency.** Today's limiters are per-session
  token buckets keyed by request. Whether async introduces a need to also
  cap concurrent coroutines per app (as distinct from request rate) is open.

## Implementation phases

1. Core event loop + HTTP accept + request parsing (replaces
   `lib/socket/server` usage in the daemon's listener path).
2. HTTP routing + app dispatch (port `handle` / `handle_daemon` /
   `classify_host` from the current daemon onto the coroutine-per-connection
   model).
3. WebSocket upgrade handling (port the upgrade + frame-codec logic from
   `lib/websocket/init.lua`, driven by the shared loop instead of a
   standalone epoll instance).
4. `DaemonCtx` + the `(opts, daemon_ctx) -> (cap, revoke)` cap factory
   calling convention update, applied across existing caps (most ignore the
   new parameter).
5. PTY cap, using `DaemonCtx.register_fd`.
6. WS-server cap, using `DaemonCtx` for upgrade routing.
7. Terminal mux app, using both caps together.
