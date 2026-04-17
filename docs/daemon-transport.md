# Daemon transport and perf

Reference for "when does WebSocket / HTTP/2 / HTTP/3 / QUIC become worth
adding to the platform daemon?" The short answer is: not yet, and the
reasoning below is meant to short-circuit future re-derivation.

Cross-references: [`daemon-design.md`](daemon-design.md) covers the v1
design, threat model, CSP, launch flow, and TLS stance.
[`daemon-isolation.md`](daemon-isolation.md) covers the Lua-level sandbox
model (tier 1 shared state + pcall wrap).

## What the daemon actually does

One user, one daemon process, one browser tab at a time (usually). The
traffic shape is:

- A small number of static GET responses (HTML, CSS, JS bundle).
- A handful of XHR / fetch calls per app session (cap calls: LLM, KV, DB,
  PNG decode, etc.).
- Optionally one long-lived stream per open app (SSE for LLM token
  streaming, chat updates).

It is not a CDN, not a concurrent-load optimizer, not a collaboration
server. Transport picks should be judged against this shape, not against
generic web-app assumptions.

## Conclusions

### 1. SSE covers the card app's chat pattern; WebSocket only earns keep for real bidirectional needs

Chat UIs stream assistant tokens *server → client*. That's SSE's exact
shape. The client → server direction is a handful of discrete fetch calls
(send message, regenerate, etc.) — not a hot bidirectional channel.

WebSocket becomes worth the extra surface area when a concrete feature
needs it: voice turn-taking, multi-user live collab, a drawing app
forwarding pointer events. Until a real use case arrives, SSE + fetch
keeps the daemon simpler (no frame-level parsing on the hot path, no
ping/pong bookkeeping, no upgrade handshake).

`lib/websocket` already exists, so adding later is a wiring question, not
a net-new protocol project.

### 2. WebSocket for the daemon's own UI is overkill

The library / launch / settings pages are zero-JS HTML forms. They don't
need push. They don't need bidirectional anything. Standard GET/POST with
Location redirects is the right tool.

### 3. On loopback, SSE and WebSocket are effectively identical for server → client push

Local TCP connection setup is microseconds. Both transports sit on the
same kernel pipe after setup; the per-message overhead is dominated by
Lua code, not framing bytes. For the common "localhost dev" case,
transport choice is not a perf lever.

### 4. Tailscale intercontinental: half-RTT per message is a floor that no transport fixes

Tailscale + remote daemon at ~150–300ms RTT (e.g. US ↔ EU) changes the
shape of the problem. At that distance:

- Every request/response pair pays ≥ one RTT.
- SSE and WebSocket both pay half-RTT per message from server to client.
  There is no transport-level fix for speed-of-light.
- WebSocket's *only* structural win is on bursty client → server
  messages: it amortizes the TLS handshake across many sends. With
  keep-alive HTTP/1.1 and a small number of XHRs per app session, the
  handshake cost is already amortized.

At 200ms RTT the useful latency work is at the UX layer, not the
transport layer: optimistic UI, prefetch, speculative reads, colocate
the daemon with the user. Transport choice is noise next to those.

### 5. HTTP/2 doesn't help this traffic shape

HTTP/2's wins are concurrent resource multiplexing over one TCP
connection — loading 60 static assets for a fat webpage. The daemon
serves one app at a time: a handful of XHRs and one SSE stream. HTTP/1.1
keep-alive is adequate for that.

Head-of-line blocking matters when you have tens of in-flight requests
competing for one TCP connection. We don't.

### 6. HTTP/3 / QUIC help on lossy or mobile links, but it's a much-later project

Real wins:

- No TCP head-of-line blocking — a dropped packet in one stream doesn't
  stall the others. Matters on lossy links (cellular, bad wifi).
- 0-RTT connection resumption — reconnects start sending data
  immediately. Matters for short-lived reconnecting clients.
- Connection migration — survives IP change (network hand-off).

All real, all real-ish matters for a remote-Tailscale user on mobile.
But:

- Pure-Lua QUIC is a substantial project (crypto, packet pacing,
  congestion control, loss recovery). Bigger than the current daemon.
- TLS is not even wired up at the daemon yet. QUIC without TLS doesn't
  exist.
- The loopback case — which is 99% of current use — sees zero benefit.

Revisit when (a) TLS is wired and (b) real users report lossy-link pain.

### 7. Where perf effort actually belongs right now

Measure-first priorities, in rough order:

1. **Cap-call overhead.** Every LLM / KV / DB / PNG call crosses the
   Lua-app-to-daemon boundary. That round-trip is the hot path for a
   running app.
2. **SSE framing.** Per-token serialization cost on the LLM stream.
   String concat vs. buffer reuse.
3. **Handler dispatch.** Request → app-handler lookup (`app_handlers`
   LRU cache, per-app session sweep costs).
4. **Startup / handler compile time.** First request into an app cold
   loads and compiles.

None of these are transport problems. Benchmark before changing
anything, and record results in `docs/perf/log.md` per the project's
perf convention.

## How to use this doc

When a future session asks "should we switch to WebSocket / HTTP/2 /
HTTP/3?", the answer is almost always "not yet, and here's why." If the
question has a new concrete trigger — a feature that needs
bidirectional, a user on a lossy link, measured handshake-cost
dominance — update this doc with the trigger and revise the conclusion.

Until then: keep the daemon on HTTP/1.1 + SSE, put perf effort into the
cap-call and framing hot paths, and let concrete bottlenecks drive
transport decisions.
