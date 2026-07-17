# Terminal Multiplexer — Design

## Motivation

Remote access to multiple concurrent terminal sessions (e.g. ~10 claude code sessions) from phone/TV/browser. Part of the display substrate — first real consumer of the async/io_poll integration.

## Decided

- **lib/pty_ffi/** — new library, thin FFI-only bindings: forkpty, openpty, termios (tcsetattr/tcgetattr/cfmakeraw), ioctl TIOCSWINSZ for resize. No higher-level helpers (those go in a separate lib).
- **Naming convention**: FFI wrapper libraries get `_ffi` suffix unconditionally. (Existing libs like epoll, kqueue, inotify to be renamed eventually.)
- **Browser frontend**: xterm.js vendored in dep/. Receives raw PTY bytes for real-time rendering.
- **Server-side screen state**: Server maintains canonical terminal state for reconnect. Simple replicated state machine — not a CRDT. On reconnect, client gets current screen state (not a full replay).
- **Real-time path**: raw PTY bytes over WebSocket → xterm.js.
- **Browser sandboxing**: Server enforces capability restrictions at serve time (parses emitted JS, rejects/rewrites disallowed constructs). The typechecker handles structural correctness, not security.
- **Platform app**: lives in lib/platform/apps/terminal_mux/ (working name).
- **Sync substrate**: y.js protocol compatibility (lib/y-crdt) tracked as future ecosystem substrate for the creation substrate. Not needed for terminal mux — terminal state is a replicated state machine with a single authoritative writer (the PTY output stream), not a concurrent-editing problem.

## Architecture

```
Browser                          Server
┌─────────────┐                 ┌──────────────────┐
│  xterm.js   │◄──WebSocket───►│  terminal_mux     │
│  (renders)  │   raw bytes +   │                    │
│             │   sync msgs     │  ┌──────────────┐ │
└─────────────┘                 │  │ screen state  │ │
                                │  │ (VT parser)   │ │
                                │  └──────┬───────┘ │
                                │         │          │
                                │  ┌──────┴───────┐ │
                                │  │   PTY pool    │ │
                                │  │ (pty_ffi +    │ │
                                │  │  io_poll +    │ │
                                │  │  async loop)  │ │
                                │  └──────────────┘ │
                                └──────────────────┘
```

- Server uses lib/async loop + lib/io_poll to multiplex PTY fds and WebSocket connections
- Each terminal session: one PTY master fd, one or more WebSocket clients
- PTY output → broadcast to connected clients (raw bytes) + update server screen state
- Client input → write to PTY master fd
- On reconnect → server sends screen snapshot, then resumes raw byte streaming

## Open Questions

- **Wire protocol details**: Reconnect handshake, state snapshot format, input encoding. Need to define the WebSocket message types (raw PTY data vs control messages like resize, attach, detach).
- **Server-side VT parser scope**: How much of VT100/xterm to implement for screen snapshots. Claude code is a modern CLI app — needs at least: cursor positioning, basic SGR (colors/bold/underline), alternate screen buffer, line wrapping. Probably doesn't need: mouse tracking, Sixel graphics, OSC hyperlinks.
- **xterm.js vendoring**: Where does it go? dep/xterm-js/? How does the server serve static files (the HTML page + xterm.js bundle)?
- **Authentication**: Who can connect? Token-based? Password? SSH keys? The initial use case is personal (same user, same machine or LAN), but the design should be able to grow.
- **App name**: "terminal_mux" is a working name. Not user-facing enough.
- **lua2ts ESM gap #2**: The declared-global → import gap remains open with two candidate approaches. Not blocking the terminal mux directly, but relevant for the broader browser story.

## Dependencies

Libraries that exist and are ready:
- lib/http/ (server, TLS)
- lib/websocket/ (RFC 6455, epoll-integrated)
- lib/http/server_ws.lua (HTTP+WebSocket hybrid)
- lib/io_poll/ (cross-platform readiness dispatch)
- lib/async/ (promises, event loop, poller-driven)
- lib/ansi/ (ANSI escape code generation — output only)

Libraries to build:
- **lib/pty_ffi/** — POSIX PTY FFI bindings (first)
- **lib/vt/** or similar — VT/ANSI parser + screen buffer model (for server-side state)
- **lib/platform/apps/terminal_mux/** — the app itself

## Implementation sequence

1. lib/pty_ffi/ — thin FFI bindings
2. Server-side VT parser (lib/vt/ or similar) — enough for screen snapshots
3. Terminal mux server — PTY pool + WebSocket + async loop
4. Browser frontend — xterm.js + minimal HTML
5. Reconnect protocol
6. Authentication
