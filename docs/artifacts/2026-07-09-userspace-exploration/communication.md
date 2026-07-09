# Communication as a crescent facet

Speculative exploration. Nothing here is a commitment; it's a survey of the
space and where crescent's philosophy (caps-first, zero-dep, browser-native,
tools-not-libraries) would produce something different from the incumbents.

## 1. What people actually do

- Send a message, expect delivery even if the recipient is offline (store
  and forward — email, XMPP offline queues, Signal's server-held ciphertext).
- React to a message with an emoji without sending a new message (Slack,
  Discord — a mutation on an existing message, not a new event).
- See "typing..." and green dots (presence, ephemeral, no persistence
  expected, high frequency, must not clog the durable log).
- Edit or delete a sent message and have it propagate (mutable-looking
  history over an append-only transport).
- Thread a reply so a fast-moving channel stays legible (Slack threads,
  Zulip's topic-per-thread by default, email's `In-Reply-To`).
- Share a screen, or co-edit a doc, and see the other person's cursor move
  in real time (low-latency, lossy-tolerant streams, not durable messages).
- Get pinged only for the things that matter (@mentions, keyword filters,
  digest emails, notification fatigue is the actual UX battle, not delivery).
- Move a conversation across devices/apps without re-auth or losing history
  (account = identity + key material + a place the server can find you).
- Talk to someone on a different server/app without either side installing
  the same client (federation, or its absence — this is the actual line
  between "the web" and "walled gardens").
- Know a message was actually written by who it claims (signing) and that
  nobody in the middle can read it (E2E) — and separately, prove it *wasn't*
  altered after the fact, which most E2E chat apps quietly don't guarantee
  (no non-repudiation, by design, and that's a feature for chat, a bug for
  contracts).
- Post something once and have it show up in many places you don't control
  (crosspost to Mastodon + Bluesky + a Discord webhook — the modern "syndicate,
  don't centralize" workflow, held together by duct-taped bots).
- Search years of history instantly (mutt/aerc power users; also the thing
  Slack paywalls).

## 2. Prior art, and what each actually teaches

- **IRC** — the message is the protocol. No history, no read receipts, no
  offline delivery, and it's still alive 35 years later because the transport
  is embarrassingly simple: line-delimited text over a socket. Complexity
  moved to bouncers (ZNC) for the "offline delivery" problem IRC itself
  refuses to solve.
- **Email (SMTP/IMAP)** — the only truly federated, decades-stable messaging
  system in daily use by billions, and crescent already has `lib/smtp`,
  `lib/imap`, `lib/email` (RFC 5322/MIME). Its lesson: store-and-forward plus
  a dumb, universally-implemented wire format outlives every "smarter"
  successor. Its failure: no live presence, no cheap reactions, threading is
  a client-side heuristic (`References` header) not a protocol primitive.
- **XMPP** — tried to be IRC-plus-presence-plus-federation with extensible
  stanzas (XEPs). Died of extension sprawl: every serious feature (E2E, MUC,
  file transfer) is an optional XEP, so two "XMPP-compliant" clients often
  can't actually talk. Lesson: federation needs a small mandatory core, not
  an infinitely extensible one.
- **Matrix** — solves offline delivery + federation + E2E by making the room
  itself a CRDT-like event DAG that every homeserver replicates. Correct
  architecture, heavy implementation (Synapse is a large Python service with
  a real DB). Directly relevant: crescent already has `lib/crdt`. A
  Matrix-shaped room-as-replicated-log is the kind of thing `lib/crdt` +
  `lib/actor` + `lib/pubsub` could compose into, at a fraction of the
  operational weight, if someone wanted to build it.
- **Signal** — the E2E bar (Double Ratchet + X3DH). Deliberately
  non-federated: one server, controlled clients, because key-management UX
  is where federated E2E has always broken (see Matrix's cross-signing pain,
  or PGP's 25-year unusability). Lesson for crescent: E2E and federation are
  in tension, and pretending otherwise is how you get Autocrypt-tier
  half-solutions.
- **Delta Chat** — E2E chat *over plain email transport* (Autocrypt). No new
  server needed — piggybacks on the SMTP/IMAP infrastructure that already
  exists everywhere. This is the closest existing thing to "crescent
  philosophy applied to chat": don't build a new protocol, compose
  primitives you already have (`lib/smtp` + `lib/imap` + a crypto lib) into
  a new *experience*.
- **Scuttlebutt (SSB)** — offline-first, gossip-replicated, append-only feed
  per identity, no server at all. Closest analogue to "the log is local
  files, sync is opportunistic." Directly resonates with a zero-dependency,
  runs-anywhere ecosystem: the sync layer is just "copy the log," which is
  a smaller problem than "run a server."
- **Etherpad / Google Docs / Figma multiplayer** — real-time co-editing is a
  CRDT or OT problem wearing a UI. Figma's specific insight: the CRDT
  doesn't need to be generic-text; a *structured* CRDT over a scene graph
  is a different and harder shape than Etherpad's flat-text OT.
- **Mastodon / ActivityPub** — federation via a shared HTTP+JSON activity
  vocabulary and server-to-server webhooks (inbox/outbox). Proof that
  federation can be built on boring HTTP `lib/http` primitives rather than a
  bespoke wire protocol — no custom transport needed, just a documented
  content shape.
- **Zulip** — topic-per-thread as the organizing unit instead of flat
  channels or ad-hoc reply-threads. A UX decision, not a protocol one, but
  it changes what's greppable later — closest in spirit to crescent's
  "greppable, plaintext" bias.

## 3. What crescent already covers

The transport and encoding layer is largely there:
`lib/tcp` (wip), `lib/udp`, `lib/tls` (wip), `lib/websocket`, `lib/dns`
(stub), `lib/http`, `lib/smtp`, `lib/imap` (wip, no init.lua), `lib/email`
(RFC 5322/MIME, stable), `lib/ssh`, `lib/mqtt`, `lib/json`, `lib/msgpack`,
`lib/protobuf`, `lib/markdown`, `lib/html`, `lib/template`.

The concurrency/state layer that a chat app's *server-side* logic would
actually be built from is unusually well-stocked for a "systems" ecosystem:
`lib/actor` (coroutine actors with supervision/links/monitors — this is
basically Erlang's process model, which is what every serious chat backend
converges on), `lib/chan` (Go-style channels), `lib/pubsub` (topic patterns +
middleware), `lib/crdt` (CRDT primitives), `lib/reactive` /
`lib/reactive_var` / `lib/reactive_store` / `lib/signals` (five different
push/pull reactivity flavors — presence and typing-indicators are exactly a
"push-based signal with no persistence" use case), `lib/event` (implied
emitter), `lib/oauth2` + `lib/jwt` (identity/auth).

What's conspicuously *not* here, searched directly: no `lib/chat`, no
notification/inbox primitive, no E2E ratchet (Double Ratchet / MLS), no
CRDT-for-text (an OT/RGA/Peritext-shaped sequence CRDT distinct from the
generic `lib/crdt` primitives), no calendar/scheduling beyond `lib/calendar`
(unexplored here), no voice/video (WebRTC has no pure-Lua story — it's
inherently a browser-API cap, not a protocol crescent can implement itself).

## 4. Where the philosophy makes this genuinely different

**Caps-first turns "which server do I trust" into a wiring question, not an
architecture question.** Every existing chat app bakes in its server
topology: Signal is one server you must trust, Matrix is federated servers,
IRC is federated-but-ancient servers. If a crescent chat library's transport
is an injected cap (`opts.transport`, matching the documented
`connect/send/recv/close` protocol convention), the *same* client logic runs
over `lib/tcp` to a hosted daemon, over `lib/websocket` in-browser, or
peer-to-peer over WebRTC datachannels — without the library caring. That's
not available to Signal or Matrix clients, whose transport is load-bearing
in the protocol design itself.

**Tools-not-libraries plus zero-backend changes what "run a chat app" means.**
Crescent's stated bar — a tool that works 100% in-browser with no backend —
is not how any existing chat system works; they all assume a server that
holds state you don't control. A crescent-native chat tool pushes towards
Scuttlebutt's model by necessity: the log is local (IndexedDB via
`lib/js_caps` kv caps), sync is a pluggable cap (could be a relay, could be
WebRTC, could be dragging a file). "Serverless chat" stops being a stunt and
becomes the default shape.

**The CRDT-primitives-already-exist fact raises a real design question,
not a guessed answer:** should a sequence CRDT for collaborative text live
under `lib/crdt` as another primitive, or as its own `lib/rope_crdt`-shaped
library the way `signals` sits parallel to `reactive`? That's a genuine open
call for whoever designs it — `lib/crdt`'s existing primitives and their
docs would need reading first to know if the existing abstraction already
generalizes or if text-sequence semantics (tombstones, interleaving anomalies
that RGA/Peritext specifically solve) need their own module. Flagging as a
design question rather than answering it.

**E2E and federation being in real tension (Signal's lesson) is a question
crescent inherits, not solves for free.** Caps-first composability doesn't
dissolve the Double-Ratchet-needs-a-single-key-authority problem; MLS (the
IETF's federated-group-E2E answer, RFC 9420) is the modern attempt and it's
a substantial state machine, not a wrapper. Whether that's in scope reads as
a `docs/batteries.md` scoping question, not something to resolve here.

**Delta Chat's move — E2E chat riding on plain SMTP/IMAP — is the most
"crescent-shaped" precedent in this whole survey**, because it's exactly
"compose existing primitives into a new experience" rather than "invent a
new protocol." `lib/smtp` + `lib/imap` + a signing/encryption lib (crescent
has `lib/blake2`, `lib/chacha20`, `lib/argon2` — an Autocrypt-style
mailbox-based E2E chat is buildable today from parts that already exist,
without inventing new wire format.

**Notification/presence is a reactivity problem, not a messaging problem** —
and crescent already has five reactive libraries. A "typing indicator" or
"unread badge" primitive plausibly isn't a new communication library at all;
it's `lib/reactive_var` or `lib/signals` wired to a pubsub topic, which is a
composition exercise, not new substrate. Worth someone checking whether
that composition is actually smooth in practice before assuming it.

## 5. Open threads worth recording (not decided here)

- Is a `lib/chat` (client-agnostic thread/message/reaction model over an
  injected transport cap) in scope, or does it violate "no framework code
  in `lib/`" the way a dispatch/routing layer would? Genuinely unclear from
  the stated rules and worth a direct question to whoever owns scope.
- Does collaborative-text CRDT belong under `lib/crdt` or as a sibling
  library — open design call, not resolved here.
- Is voice/video in scope at all, given WebRTC has no pure-Lua tier and is
  inherently a browser-cap-only feature — this cuts against "pure Lua is
  the baseline" and needs an explicit scoping decision, not an assumption.
