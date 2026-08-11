# Multi-node stack VM: design proposal for zachlike puzzle games

**Status: DESIGN PROPOSAL, awaiting owner sign-off. Nothing here is built.**

**Provenance note (read first):** this design was produced *without reading*
`lib/vm/` — not its source, tests, or docs — per the owner's stated
remediation process for flagged libraries in
`docs/genre-battery-design.md` ("Remediation approach for flagged
libraries"): a redesign that patches an existing library's architecture
must be designed by an agent that has not read that library's existing
implementation, to avoid anchoring the redesign on the old architecture's
assumptions. This document is grounded in TIS-100 and adjacent assembly-
puzzle-game prior art plus crescent's own conventions
(`CLAUDE.md`, `docs/conventions.md`), not in the existing `lib/vm/` code.
Whether the eventual implementation supersedes `lib/vm/` in place or ships
as a new parallel library is an owner decision this document does not make
(see "Open questions" at the end).

This document presents design options with tradeoffs. It does not pick a
winner where a real tradeoff exists — that choice belongs to the library's
owner.

## 1. Domain grounding

TIS-100 (Zachtronics, 2015) is the direct prior-art reference named in the
task and is treated as the primary source of domain truth here. Its
defining mechanic, confirmed by the game's own documented design: a grid of
independent nodes, each a small assembly-like computer with its own
instruction memory, executing concurrently; the *only* way nodes exchange
data is by reading/writing directional ports (UP/DOWN/LEFT/RIGHT) that map
to a fixed adjacency between grid cells. A read or write blocks until the
matching neighbor performs the complementary operation. There is no shared
memory, no global address space — port I/O *is* the entire inter-node
communication surface, and puzzles are solved by choreographing which node
reads/writes which port on which cycle. Other games in the same design
lineage (Zachtronics' own SHENZHEN I/O, and community TIS-100-likes)
preserve this shape: small isolated execution units, explicit blocking
channels, no shared state.

This grounds two hard requirements for the design below:
- Blocking port I/O is not an optional feature bolted onto a single-VM
  stepper — it is the mechanic the whole library exists to serve. A design
  that treats ports as an afterthought fails the brief.
- Deadlock (every node blocked on a port with no counterpart ready) is a
  *reachable, normal, expected player outcome* — a player can absolutely
  author a program that deadlocks the grid — not a host bug. It must be
  detected and reported through the same `(nil, errmsg)` channel as any
  other player-triggered error, never left to hang the host.

## 2. Instruction set: stack-based, not register-based

**Chosen shape: stack-based**, with the register-based alternative (which
is what TIS-100 itself actually uses — a single ACC accumulator plus a BAK
backup register, no general stack) named explicitly as the road not taken,
because the reasons for the choice only make sense in contrast to it.

### Why stack-based

The hard extensibility requirement (design point 3: register/add custom
opcodes without forking the library) is the deciding factor. A stack
machine expresses every opcode's operand contract uniformly: an opcode
declares how many values it pops and how many it pushes, and that's the
whole interface. A custom opcode registered by a genre core needs no
special-cased knowledge of the base ISA to compose correctly — it just
consumes N stack cells and produces M.

A register machine (TIS-100's actual shape) does not have this uniformity.
Registers are named, finite, and some are reserved by the base ISA (ACC,
BAK). A custom opcode wanting to read or write "the accumulator" has to
name it explicitly, which means the extension API must expose the base
machine's specific register set as part of its surface — new opcodes are
coupled to the existing register vocabulary rather than composing through
a single generic operand convention. That coupling is exactly the kind of
extension-surface leakage the redesign is meant to avoid (this is the same
failure class named in `docs/genre-battery-design.md`'s audit of the
existing `lib/vm`-shaped problem: closed, non-generic extension surfaces).

Stack-based state is also simpler to snapshot: a node's full execution
state is `(stack contents, program counter, pending port operation)`. A
register machine's snapshot additionally needs to enumerate whichever
registers the base ISA plus every registered custom opcode may have
introduced — again, an open-ended set that isn't fixed at design time.

### Cost, named honestly

This is a real tradeoff, not a free win. TIS-100 players' muscle memory
(`MOV`, `ACC`, `BAK`) doesn't map cleanly onto stack manipulation — moving a
value from one place to another becomes a `DUP`/`SWAP` dance instead of a
single `MOV`. A genre core aiming for TIS-100 authenticity specifically
(as opposed to "a TIS-100-*like* mechanic") pays a legibility cost here.
Nothing prevents a genre core from layering a `MOV`-flavored surface
mnemonic on top that compiles to `DUP`/`SWAP` sequences, but that's a
composition-layer concern, not something this library provides natively.

### Instruction inventory (illustrative, not exhaustive)

Values: single numeric type per stack cell (real Lua numbers; whether to
constrain to integers and to a TIS-100-style bounded range like
[-999, 999] is a genre-core/game-data decision, not a VM-core one — the
core imposes no range by default).

- **Stack**: `PUSH n`, `POP`, `DUP`, `SWAP`
- **Arithmetic**: `ADD`, `SUB`, `MUL`, `DIV`, `MOD`, `NEG` — `DIV`/`MOD` by
  zero is a player-triggerable data error, reported as `(nil, errmsg)` from
  the step function, never a Lua runtime error
- **Comparison**: `EQ`, `LT`, `GT` — push `0`/`1`
- **Control flow**: labels resolved at assemble time; `JMP label`,
  `JZ label` (pop, jump if zero), `JNZ label` (pop, jump if nonzero)
- **Port I/O**: `READ port` (blocks, pushes received value on unblock),
  `WRITE port` (blocks, pops and sends value on unblock) — see section 3
- **Halt**: `HALT`

`CALL`/`RET` (a call stack separate from the operand stack) are left as an
open question — TIS-100 itself has no subroutine mechanism, so whether
this library should offer one beyond what a puzzle genre needs is a scope
call for the owner, not inferred here.

## 3. Inter-node port model and blocking execution

### How a blocking read/write actually works

Per node, execution is driven by a resumable unit (concretely: a Lua
coroutine, or an equivalent explicit continuation — see the execution
model options below) that runs until it hits a `READ`/`WRITE` on a port
with no ready counterpart, at which point it suspends and reports what
it's waiting on: `{op = "read"|"write", port = <port id>, value = <value, for write>}`.

The engine that owns all nodes drives ticks. On each tick, it:

1. Collects the current suspend-state of every node (already-halted nodes
   are skipped).
2. For every pair of nodes whose current pending operation targets each
   other's shared port in complementary directions (one blocked on
   `write port` where the neighbor is blocked on `read` of the same
   logical channel), transfers the value and marks both as resumable this
   tick.
3. Resumes every node that became resumable (either because it wasn't
   blocked at all, or because its port operation was just satisfied), and
   lets each run until it hits its next block, halts, or errors.
4. If a tick completes a full pass over every still-running node and *no*
   port transfer happened and *no* node was newly resumed, the grid is
   deadlocked: every remaining node is permanently blocked on a channel
   with no matching counterpart ready, and no further tick can change
   that. This is reported as `(nil, errmsg)`, never a hang — the errmsg
   names every blocked node and the port/direction it's waiting on, since
   that's exactly the information a player needs to debug their own
   program.

Lockstep tick-by-tick stepping (rather than free-running each node until
the whole grid quiesces) is necessary here regardless of which execution
model is chosen, because it's what makes deadlock detection a decidable,
bounded check (`no progress in one full pass`) instead of an open-ended
"did we hang" guess.

### Topology: two options, real tradeoff

**Option A — fixed grid.** Nodes are arranged in a 2D grid; each node has
up to four named ports (`UP`, `DOWN`, `LEFT`, `RIGHT`) that are wired
automatically to the adjacent grid cell's opposite port. This is TIS-100's
actual topology and is the most legible, most "authentic" choice for a
zachlike genre core aiming at that exact puzzle feel — the grid *is* the
level layout, and the puzzle is literally about programming physical
neighbors. Cost: any puzzle design that wants a node connected to a
non-adjacent node, or a topology that isn't a rectangle (a ring, a tree,
an irregular board), has no way to express it without faking it through
pass-through nodes.

**Option B — arbitrary graph via declared port connections.** Nodes have
named ports, but the wiring between a node's port and another node's port
is declared as data (a list of `(node_a, port_a, node_b, port_b)` edges)
rather than implied by grid adjacency. This subsumes option A (a fixed
grid is just one specific edge list a genre core can generate) and also
supports non-grid puzzle boards — SHENZHEN I/O–style layouts with
irregular connections, or wiring-focused puzzles where the connection
topology is itself part of what the player configures. Cost: loses the
"the grid *is* the puzzle" implicit legibility TIS-100 gets for free — a
genre core using option B has to render the topology explicitly for
players to reason about it, since it's no longer inferable from cell
adjacency.

Nothing about the port-blocking/deadlock-detection mechanism in this
section depends on which topology option is chosen — topology only
determines how the edge list is produced (grid-derived vs. explicit data).

## 4. Execution model: two options, real tradeoff

**Option 1 — coroutine-per-node.** Each node's program runs inside a Lua
coroutine; `READ`/`WRITE` call `coroutine.yield` with the pending-operation
descriptor, and the engine's tick loop resumes coroutines per the algorithm
in section 3. This is the natural, low-effort mapping of "a node is an
independently-running sequential program that blocks" onto Lua's actual
concurrency primitive — the node's program logic can be written as
ordinary straight-line/loop code with no manual continuation-passing.
Cost: a suspended Lua coroutine's internal state (its call stack, active
locals) is opaque and cannot be serialized. If a genre core wants
save/load mid-execution, or a rewind/undo/replay feature (common in
zachlike puzzle UX — TIS-100 and SHENZHEN I/O both let players step
backward and rerun), coroutine state can't be captured as plain data; the
only way to "restore" a mid-execution state is to replay all instructions
from the start.

**Option 2 — explicit state-machine stepping.** A node's execution state
is plain data: `{pc, stack, pending_op}`. Instead of a coroutine, a
`step(node_state, opcode_table)` function executes one instruction and
returns updated state, or a pending-op descriptor when it hits a blocking
port instruction, or `(nil, errmsg)` on error. The engine's tick loop calls
`step` on every node once per tick (or repeatedly per node up to its next
block, depending on whether "one instruction per tick" or "run to next
block per tick" is the chosen tick granularity — an open question, see
below) instead of resuming coroutines. Because node state is a plain Lua
table with no coroutine involved, it can be `deep-copied`, serialized, or
diffed directly — rewind/undo/replay and save/load become straightforward
data operations. Cost: every opcode handler, including custom ones
registered by a genre core, must be written as an explicit state
transition (`(state) -> state'`) rather than straight-line imperative code
with implicit control flow — a `JMP` handler explicitly sets `pc` rather
than the interpreter loop's natural fallthrough handling it, and any
opcode wanting loop-like or multi-step internal logic has to encode that
as extra fields in the node's state table rather than local variables.
This is more mechanical, more verbose to author, and a genuinely harder
mental model for a genre-core author writing a new opcode than option 1's
"just write normal code."

### Three concrete combined packages, no forced winner

Since topology and execution model are independent axes, they compose
into distinct concrete packages a genre core could actually build against.
Three worth naming explicitly:

- **Package A — grid + coroutine-per-node.** Most TIS-100-authentic,
  least implementation effort, no serializable mid-execution state.
  Best fit if the target genre core wants "TIS-100, but crescent" and
  doesn't need rewind/undo.
- **Package B — arbitrary graph + coroutine-per-node.** Same execution
  model tradeoffs as A, but supports non-grid puzzle boards (wiring
  puzzles, irregular layouts). Best fit if topology-as-puzzle-content
  matters more than TIS-100's specific grid feel.
- **Package C — arbitrary graph + explicit state machine.** Highest
  implementation and opcode-authoring effort, but the only package that
  gets serializable mid-execution node state "for free" — relevant if a
  genre core's puzzle UX plan includes stepping backward, replaying a run
  frame-by-frame, or persisting a paused puzzle across a save/load
  boundary. (A grid + explicit-state-machine package is also possible —
  it's the fourth combination — but isn't named as a separate package
  above since it offers no advantage over C beyond a fixed topology, which
  package A already covers with less execution-model cost.)

## 5. Extensibility: registering custom opcodes without forking source

Per `CLAUDE.md`'s no-ambient-global / caps-first convention, the opcode
table is **not** module-level closed state — it is owned by each VM
instance (or shared registry object passed explicitly), so two genre cores
loaded in the same host process cannot collide by mutating a shared table.

Proposed public shape:

```lua
local registry = vm.new_opcode_registry()  -- starts pre-loaded with the base ISA (section 2)

registry:register("SCAN", {
  arity_in = 1,   -- pops this many stack cells
  arity_out = 1,  -- pushes this many stack cells
  exec = function(operands, ctx)
    -- operands: array of `arity_in` popped values (in pop order)
    -- ctx: { node_id, caps } — caps per section 6
    -- returns: array of `arity_out` values | (nil, errmsg)
  end,
})

local node = vm.new_node(program_source, { opcodes = registry, ports = {...}, caps = {...} })
```

The assembler/parser accepts the same registry so that a custom opcode's
mnemonic is recognized in program source — a genre core cannot register a
runtime handler for `SCAN` without also being able to write `SCAN` in a
player-authored program; the registry is the single source of truth for
both parsing and execution, so there is no separate "known mnemonics" list
to keep in sync by hand.

Port-blocking opcodes (`READ`/`WRITE`) are themselves just entries in the
base registry with a third capability beyond `arity_in`/`arity_out`: the
ability to yield a pending-op descriptor instead of returning immediately.
Whether custom opcodes should also be allowed to declare *their own*
blocking/port-interacting behavior (a custom opcode that blocks on
something other than a plain port read/write) is a real extension-surface
question this document does not resolve — see "Open questions."

## 6. Error handling: `(nil, errmsg)` for every player-triggerable failure

Per `docs/conventions.md`, every error a player's authored program can
cause returns `(nil, errmsg)` from the relevant function — `step`/
`tick`/`run`, never a thrown Lua error. Enumerated failure sites:

- Stack underflow (opcode's `arity_in` exceeds available stack depth)
- Unknown label (`JMP`/`JZ`/`JNZ` to an undeclared label)
- Division/modulo by zero
- Unknown opcode mnemonic (not present in the active registry)
- Invalid port reference (`READ`/`WRITE` naming a port the node doesn't
  have, or that has no declared connection in the topology)
- Deadlock (section 3) — reported at the engine/tick level, naming every
  blocked node and the port each is waiting on
- Numeric overflow, if the genre core's game data imposes a bounded range
  (e.g. TIS-100's [-999, 999]) — the VM core itself imposes no range by
  default (section 2), so this is only a failure site if a genre core
  opts into a bound; whether the *core* should offer an optional built-in
  bound-checking mode versus leaving it entirely to a registered opcode
  wrapper is unresolved, see "Open questions."

Per convention, `error()`/throwing is reserved for genuine host/programmer
errors that a player's program text cannot trigger — e.g. a genre core
registering a malformed opcode spec (missing `exec`, non-numeric arity) at
setup time, which is a host integration bug, not a data error.

## 7. I/O: capability injection, never a direct global call

Any observable side effect a node's program can produce beyond port
values — the TIS-100-esque `PRINT`/debug-output instruction named in the
task — goes through an explicitly injected capability, never a call to
Lua's global `print` or any other ambient global. Proposed shape,
consistent with `CLAUDE.md`'s caps-first rule ("if a cap is not injected,
error"):

```lua
vm.new_node(program_source, {
  opcodes = registry,
  ports = {...},
  caps = {
    debug_print = function(node_id, value) ... end,  -- injected by the host/genre core
  },
})
```

A `PRINT` opcode (itself just a registered opcode per section 5, part of
an optional standard-library registry rather than the mandatory base ISA)
calls `ctx.caps.debug_print`. If a program executes `PRINT` and no
`debug_print` cap was injected for that node, that is itself a reported
`(nil, errmsg)` failure ("no `debug_print` capability injected for node
`<id>`") — not a silent no-op and not a fallback to a global, per the
caps-first convention's explicit rule that defaulting to an ambient global
is itself a violation.

## 8. Proposed module shape (advisory, not binding)

Sketched per `docs/conventions.md`'s module-structure convention, for
whoever eventually implements this design — not a commitment made by this
document:

```
lib/<name>/
  init.lua        -- entry point
  isa.lua         -- base opcode registry (section 2)
  assembler.lua   -- program source -> instruction list + label resolution
  topology.lua    -- grid and arbitrary-graph edge-list construction (section 3)
  engine.lua      -- tick loop, port transfer, deadlock detection (section 3)
  <name>_test.lua -- tests
```

Whether this supersedes `lib/vm/` in place or ships as a new
parallel-implementation library under a different name is an owner
decision (see below) — this document does not resolve it and the shape
above works either way.

## Open questions (not guessed at in this document)

- **Package choice.** Which of the three concrete packages in section 4
  (or the unnamed fourth combination) the owner wants built — this is the
  central sign-off decision this document exists to inform, not to make.
- **Supersede vs. new parallel library.** Whether the implementation
  replaces `lib/vm/`'s existing architecture in place or ships as a new,
  independently-named library under the "multiple implementations"
  convention. `docs/genre-battery-design.md`'s remediation section states
  this is a per-library, not-yet-made call.
- **Tick granularity for the explicit-state-machine option (package C):**
  one instruction per node per tick, or run-to-next-block per node per
  tick. Affects step-by-step debugger/rewind UX resolution but not
  correctness of deadlock detection.
- **`CALL`/`RET` subroutine support** — TIS-100 itself has none; whether
  this library should add a call stack beyond the base ISA in section 2 is
  an unresolved scope call.
- **Whether custom opcodes may declare their own blocking behavior**
  beyond the built-in `READ`/`WRITE` port primitives (section 5) — not
  resolved here.
- **Whether the VM core should offer an optional bounded-numeric-range
  mode** (e.g. TIS-100's [-999, 999]) as a built-in feature versus leaving
  range enforcement entirely to a genre-core-registered opcode wrapper
  (section 6) — not resolved here.
