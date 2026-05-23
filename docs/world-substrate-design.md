# World Substrate Design

The core library. Objects, messages, handlers, effects, event log, fork, capability refs. Genre-neutral; not specific to RP or any other application.

## Goals

- Genre-neutral object/message substrate.
- Statically typed via crescent's typechecker (row types, match types, effect rows as they land).
- Effects as data: handler computation is pure (or types its impurity); world mutations are returned as effect values applied by the substrate.
- Event log as source of truth: state is a fold over the log; replay and fork are first-class.
- Persistence via crescent's `db` / `kv` / `self_write` caps.
- Capability discipline at the type level: a `Ref<{walk}>` cannot invoke verbs outside its row.
- One world = one crescent platform app.

## Non-goals

- No engine privilege. The substrate is a library, not a runtime extension. Anything the substrate does, a user library could replicate.
- No cross-world references (yet). Deferred to a future transport doc.
- No opinion on rendering. World state → prose is a separate layer (`narrate` ops in the operations library).
- No opinion on what an object *is*. Rooms, NPCs, items, dialogues — all conventions on top, not built in.

## Primitives

### Object

A Lua table with these conventions:

- `properties: { [string]: any }` — state.
- `handlers: { [Verb]: Handler }` — verb dispatch.
- `prototype?: Ref<Object>` — delegation target.
- `interface?: { [Verb]: VerbSignature }` — declared verbs, for typechecking and editor introspection.
- `meta?: { ... }` — editor hints, documentation, etc. (presentation, not semantics).

Objects are addressed by Ref (capability), not by raw id. The substrate maintains an internal id↔ref map but exposes only refs to user code. Inside the substrate, ids are opaque integers; outside, only refs flow.

### Message

A value sent to a ref:

```
{ verb: Verb, payload: P }
```

The substrate looks up the handler for `verb` on the recipient (walking the prototype chain), runs it, collects effects, applies them, and appends an event-log entry.

### Handler

A pure function with signature:

```
(self: Self, sender: Ref<Sender>, payload: P) -> { Effect }
```

Handlers are pure: same inputs, same effects. All mutation happens by returning effects. This makes handlers testable, replayable, and analyzable. The typechecker tracks any non-pure effects (throws, yields, oracle calls) through its effect system (currently `Coroutine<Yield, Send, Return>`; will broaden as the effect work lands).

### Effect

First-class data. Closed set:

- `{ kind: "set", target: Ref, key: string, value: any }` — mutate a property.
- `{ kind: "send", target: Ref, verb: Verb, payload: any }` — dispatch another message.
- `{ kind: "schedule", target: Ref, verb: Verb, payload: any, at: Time }` — delayed message.
- `{ kind: "spawn", prototype: Ref<Object>, props: {...} }` — create new object; returns a ref.
- `{ kind: "remove", target: Ref }` — destroy object.
- `{ kind: "reply", value: any }` — return a value to the sender (synchronous flow).
- `{ kind: "ask", oracle: Ref<Oracle>, prompt: Prompt }` — invoke an oracle (see operations).
- `{ kind: "log", level: Level, message: any }` — diagnostic, persisted to event log.

Effects are applied atomically per top-level message dispatch (a single transaction; failure rolls back partial effects).

### Event Log

Append-only sequence of records:

```
{
  index: integer,
  timestamp: Time,
  sender: Ref,
  target: Ref,
  verb: Verb,
  payload: any,
  effects_applied: { Effect },
  oracle_calls: { OracleCall },  -- prompt, backend, response, for replay determinism
  visible_to: Query,             -- visibility metadata for perception filtering
}
```

Serializable, queryable, replayable.

Forking: choose a log index N, take the first N entries, replay against a fresh world, diverge. The new world has all state up to N and continues independently. Useful for branching narratives, what-if analysis, parallel timelines.

Oracle calls are recorded so replay is deterministic — replayed oracle calls return the cached response, not a fresh oracle invocation. Forking past an oracle call may either reuse the cached response (deterministic re-derivation) or re-invoke (genuine divergence); the fork op selects.

### Ref

A capability-shaped reference to an object. Carries an attenuation row: the subset of verbs the holder can dispatch.

`Ref<{walk, look}>` is a subtype of `Ref<{walk}>` by row narrowing — passing a wider ref where a narrower one is expected is free; the reverse requires explicit unsafe widening (which the substrate may forbid in user-facing surfaces, allowing it only in cap-granting machinery).

Attenuation enables capability-style access control:
- The player's body ref grants `{walk, look, take, give, say}`.
- The author's world ref additionally grants `{create_object, edit_property, retcon, ...}`.
- An NPC's body grants different verbs depending on the NPC's role.

Refs are first-class values, can be stored in properties, passed in payloads, and revoked.

### Query

A predicate over objects (and over the log). Examples:

- `query(world, { has_prototype: Container })` → all containers.
- `query(world, { has_property: { open: true } })` → all open things.
- `query(log, { verb: "say", since: t0 })` → all utterances since t0.
- `query(log, { visible_to_contains: alice_ref })` → events Alice perceived.

Queries are the basis of perception (belief layer), scope-of-effects (which objects an op may touch), search (editor), and listing (UI).

### Schedule

A queue of pending messages, indexed by time. The world loop advances the clock and delivers due messages. Same dispatch path as immediate sends; just delayed.

Scheduled messages persist in the event log on insert, so they survive world restart and are visible to replay.

## Type system usage

Crescent's typechecker does the heavy lifting. No substrate-specific typechecker extensions are required.

- **Object shapes as rows.** An object is `{ name: string, hp: integer, ...Prototype }`. Inheritance and override fall out of row unification. The editor reads the row type to generate property-edit forms.
- **Verb dispatch via match types.** `match Verb { Walk => Direction, Take => Ref<Object>, ... }` types the payload-by-verb relation. Senders can be type-checked against the receiver's interface.
- **Handlers' effects in the type signature.** A handler's type declares which side effects it may produce. Pure handlers are statically distinguishable from impure ones. The substrate's `apply_effects` is typed to accept exactly the effect set the handler may produce.
- **Cap attenuation via row narrowing.** `Ref<{walk}>` is `{ walk: WalkHandler }`-shaped at the type level (single-field row). Verbs outside the row are not callable. The substrate's `send` is typed to require the verb be in the recipient's row.

The substrate doesn't extend the typechecker. The typechecker as it exists, plus the effect-system work it needs anyway (for `error()` and `coroutine.yield()`), is sufficient.

## Persistence

Each world owns a `db` cap. The substrate uses it for:

- **Event log table:** `events(index, timestamp, sender_id, target_id, verb, payload_json, effects_json, oracle_calls_json, visible_to_json)`. Append-only.
- **Object snapshot table:** periodic full dump of object state, for fast load. Replaying the log from scratch would be slow on old worlds; snapshot + tail-replay is the standard pattern.
- **Object current-state table:** denormalized per-object current properties, for fast queries. Rebuildable from log + snapshot.
- **Indexes:** object-by-prototype, object-by-property — incrementally maintained.

Load: replay from latest snapshot's log index to current. Save: append events as they happen; snapshot on schedule (e.g., every 1000 events or every 10 minutes, whichever first).

`kv` cap for ephemeral scratch: cached query results, runtime indices that can be rebuilt.

`self_write` cap for world-definition mutations (changes to prototypes, handlers, interfaces) — these are tracked as substrate events too, but the canonical world-definition file gets updated for distribution.

## Crescent platform app shape

A world's `manifest.json`:

```json
{
  "name": "my-world",
  "entrypoint": "main.lua",
  "caps": {
    "db": { "required": true, "scope": ["app"] },
    "kv": { "required": false },
    "http_server": { "required": false },
    "llm": { "required": false },
    "fs": { "required": false, "root": "assets/", "allow_write": false }
  }
}
```

`main.lua`:

```lua
local substrate = require("world.substrate")
local world = substrate.boot({
  db = caps.db,
  kv = caps.kv,
  llm = caps.llm,
})
-- wire up world definition: prototypes, handlers, initial objects
require("world_def")(world)
-- start the loop
world:run()
```

Worlds with no oracle calls don't request the `llm` cap. Worlds with no frontend don't request `http_server`. Caps are scoped tightly per-world.

## Concurrency

Within a world, message dispatch is single-threaded by default (deterministic, sequential, atomic-per-top-level-message). Concurrent dispatch needs careful semantics (which order? which atomicity? which effects observable mid-dispatch?). Defer until cross-app or true multiplayer.

Across worlds, each world is its own crescent app — separate process, separate state, isolated. Cross-world messaging is a future transport problem.

## Failure semantics

If a handler errors (Lua error, type error, contract violation), the top-level message's entire effect set is discarded. The event log records the failure but no state changes apply. The sender sees an error reply.

If a `send` effect's inner handler fails mid-application, the outer transaction rolls back. Pick "atomic per top-level message" for v0; revisit if too restrictive.

Oracle-call failures (cap unavailable, timeout, malformed response) are handled at the oracle adapter layer (see operations doc), not as substrate-level errors.

## Open questions

- **Effect application order.** Sequential within a handler's returned effect list is the obvious answer. Whether to parallelize across independent effects is a future optimization, not a v0 concern.
- **Snapshot policy.** When to snapshot, how to GC old snapshots, whether to compress. Pick reasonable defaults; expose as cap config.
- **Effect set evolution.** Adding new effect kinds is a breaking change for old logs. Decide upfront: either close the effect set (no future kinds) or version the log format.
- **Cross-world refs.** Out of scope for v0 but the substrate should not preclude them. Refs should remain location-transparent in the dispatch model so a future transport doesn't require substrate surgery.
