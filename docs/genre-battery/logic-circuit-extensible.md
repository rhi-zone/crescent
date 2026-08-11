# Digital logic circuit simulation: extensible design proposal

**Status: DESIGN PROPOSAL, awaiting owner sign-off. Not implemented. Nothing
in this document is built.**

**Provenance note (required disclosure):** this design was produced without
reading, grepping, or otherwise inspecting anything under
`lib/logic_circuit/` — no source, no tests, no README. This is deliberate,
per the remediation approach in `docs/genre-battery-design.md` ("Remediation
approach for flagged libraries"): a redesign of a flawed library's
architecture must happen without the designing agent reading the existing
implementation, so the new design isn't anchored on the old one's
assumptions. The only knowledge this document has of the existing library's
flaws comes secondhand, from the audit already written into
`docs/genre-battery-design.md`'s "Quality audit" section, which names three
specific defects: a closed non-extensible `GATE_FNS` gate-dispatch table, a
`DEMUX` component that is a stub returning its first input rather than
demultiplexing, and vestigial `gate_n`/`bus` passthroughs that admit in their
own comments they don't implement real multi-bit evaluation. This document
does not otherwise characterize, critique, or make claims about the existing
file's contents, structure, or line numbers — it wasn't read.

This document is grounded in digital logic simulation theory and prior art
(hardware description language simulator architectures, teaching-tool
circuit simulators, and general discrete-event simulation theory), not in
crescent's existing code. It presents multiple design options with
tradeoffs, per the requesting task's instruction, and does not pick a
winner. Where a question has no single correct answer independent of intent
(performance vs. simplicity, strictness vs. permissiveness), it is left as
an explicit choice for the owner — filling it in silently would mint
semantics that downstream code (genre cores, puzzle content, tests) would
then treat as settled fact.

## 1. Grounding: how real simulators model this problem

Three bodies of prior art inform this design, at different levels:

- **HDL/EDA simulators** (Verilog/VHDL simulators such as Icarus Verilog,
  Verilator, commercial tools): the mature, load-bearing prior art for
  correctness. Two dominant simulation strategies exist there and map
  directly onto this library's Option A and Option B below: **event-driven
  simulation** (a scheduled event queue, values carry propagation delay,
  used by Icarus Verilog and most interpreted simulators) and **cycle-based /
  topological (level) simulation** (compile the combinational logic into a
  DAG, evaluate in topological order once per clock edge, no delay
  modeling — used by Verilator for speed). Both treat sequential elements
  (flip-flops/latches) as breaking combinational-cycle analysis: a flip-flop's
  output feeds back into logic that reaches its own input, and this is
  legitimate (it's how registers and counters exist) precisely because the
  flip-flop only updates on a clock edge, not combinationally.
- **Teaching/hobbyist circuit simulators** (Logisim/Logisim-Evolution, the
  `hneemann/Digital` simulator, CircuitVerse): the closest prior art to this
  library's actual audience (a genre battery targeting redstone/circuit-
  network-style puzzle and building games, not chip tapeout). These
  typically use event-driven propagation with a small fixed "gate delay" per
  component specifically so oscillating feedback (an unclocked NOT gate
  wired to its own input) is *detected* rather than infinite-looping, and
  expose truth-table generation and sometimes minimization as an explicit
  teaching feature — the same value crescent's existing library evidently
  had reason to build.
- **General discrete-event simulation theory**: the underlying scheduling
  model (event queue keyed by simulated time, causality/no-time-travel
  requirement) that any event-driven option here would be an instance of.

The two families (event-driven vs. topological/level-based) diverge exactly
on how they handle propagation order and cycle detection, which is why they
are presented as separate options in Section 6 rather than merged.

## 2. Core data model

A circuit is a **netlist**: a set of *components* (gates, flip-flops,
latches, custom user components, mux/demux) connected by *nets* (wires),
where each net carries a **bus** — an ordered vector of 1 or more single-bit
signals. A single-bit wire is a bus of width 1, not a distinct type; this is
what makes multi-bit support "real" rather than convention-only — there is
exactly one wire representation, and gates declare what width(s) they accept.

### 2.1 Signal value representation — open choice, not settled here

Digital logic simulators do not agree on how many logical values a signal
can hold, and the choice changes what "correct" evaluation means for every
gate:

- **2-value (`0`/`1` only)**: simplest, matches basic boolean-gate
  semantics, matches what a Quine-McCluskey minimizer natively wants
  (a truth table is over `{0,1}`). Cannot represent "uninitialized" or
  "unconnected" distinctly from `0`.
- **4-value (`0`/`1`/`X`-unknown/`Z`-high-impedance)**: matches IEEE 1364
  Verilog's `std_logic`-adjacent model, needed if the library ever wants to
  model tri-state buses (shared buses driven by multiple sources, relevant
  to Factorio-circuit-network-style "wire carries whichever value was last
  set" semantics) or to distinguish "never been driven" from "driven low."

This is a genuine semantic fork, not a detail: every gate's truth table,
every bus-combine operation, and the mux/demux "unselected inputs" behavior
all read differently depending on which is chosen. **This document does not
pick one.** Section 8 (open questions) restates this as the first item
requiring owner sign-off before implementation.

### 2.2 Bus width semantics — open choice, not settled here

Given an N-bit bus and an M-bit bus arriving at the same gate input (a
binary gate applied "elementwise" per the task's framing, or a bus-combining
operation), there are three structurally different policies a real
implementation could take, each defensible in different prior art:

- **Strict — reject on mismatch.** Any width mismatch between a gate's
  declared input width and the bus actually connected is a construction-time
  error: `(nil, "bus width mismatch: gate expects 4 bits, got 3")`. This is
  the HDL-simulator-strict stance (Verilog implicit-width-extension is a
  well-known footgun that strict linting rejects). Simplest to reason about,
  simplest to test, closest to "never silently do the wrong thing."
- **Zero/sign-extend the narrower bus.** Matches HDL arithmetic-operator
  semantics (Verilog/VHDL numeric extension rules): the shorter bus is
  padded to the wider bus's width, either with `0` (unsigned extension) or
  by replicating the sign bit (two's-complement signed extension). This
  requires the library to track, per bus, whether it is meant to be
  interpreted as signed or unsigned — a piece of state a pure "wires
  carrying bits" model does not otherwise need, and which only matters at
  points where a bus is interpreted as a number (arithmetic components,
  numeric truth-table dump) rather than as bits.
- **Truncate the wider bus.** The remaining prior-art option (some hardware
  description contexts truncate on assignment to a narrower target); listed
  for completeness, generally considered the most error-prone of the three
  and the least likely candidate.

Sign/unsigned interpretation is **only observable at the boundary where a
bus is read as a number** — bitwise gates (AND/OR/XOR/NOT applied per-bit)
never need to know signedness at all, since bitwise operations are
sign-agnostic. Signedness only matters for: (a) an optional numeric
truth-table/waveform dump that renders a bus as an integer for human
readability, and (b) if the library ever adds arithmetic components
(adder/comparator) — which is out of scope for this task's requirements but
worth naming so the bus abstraction doesn't paint itself into a corner.
Recommendation-shaped statement, not a decision: whichever width policy is
chosen, signedness should be a per-bus *interpretation tag* attached only at
read/render time, never a property that changes how bits propagate through
gates.

**This document does not pick a width policy.** It is Section 8's second
open item.

### 2.3 Components, pins, nets

- A **component instance** has a `type` (string key into the gate/component
  registry, see Section 4), a table of named **input pins** and **output
  pins**, each pin declaring a bus width (fixed, or `N` — parametric, resolved
  at instantiation time), and an **eval function** (for combinational
  components) or an **update function** keyed to clock/control edges (for
  sequential components).
- A **net** connects exactly one output pin (the driver) to one or more
  input pins (the loads) — standard single-driver netlist discipline. A net
  driven by more than one output pin is a construction-time error under the
  2-value model (`(nil, "net driven by multiple outputs: ...")`); under a
  4-value model with `Z` it could instead be valid tri-state bus contention,
  which is exactly why 2.1 is a real fork and not a formality.
- The circuit as a whole is represented as a **graph**: components are
  nodes, nets are edges. This is the structure both simulation-strategy
  options in Section 6 operate on, and the structure the truth-table/
  minimization tooling in Section 7 walks.

## 3. Standard gate and sequential-element baseline

Built-in, always available, never requiring registration:

**Combinational:** `AND`, `OR`, `NOT`, `XOR`, `NAND`, `NOR`, `XNOR` — each
defined once as an N-ary truth-table or reducing function over 1-bit
operands, then lifted to buses by the bus-evaluation rule from Section 5
(elementwise across bus positions, not a separate multi-bit implementation
per gate).

**Sequential:** at minimum, the two structurally distinct primitive
families digital logic theory treats separately, because conflating them is
a classic simulator bug:

- **Latches** (level-sensitive: output tracks input whenever an enable/gate
  signal is asserted, holds otherwise) — e.g. SR latch, gated D latch.
- **Flip-flops** (edge-sensitive: output changes only at a clock edge,
  ignores input the rest of the time) — e.g. D flip-flop, JK flip-flop, T
  flip-flop, with optional asynchronous set/reset.

The distinction matters for whichever simulation strategy is chosen
(Section 6): a latch is transparent within a clock phase and can
legitimately create what looks like a combinational path through it while
enabled, while a flip-flop is a hard synchronization boundary that every
cycle-based/topological strategy relies on to break feedback loops into
per-cycle DAGs.

## 4. Extensibility: gate registration API

This is a hard requirement per the task, and the specific defect this
design must not reproduce (the audit's description of the existing
library's closed `GATE_FNS` table with no registration function). The
registry is the single most load-bearing extensibility surface for the
stated audience — genre cores wanting custom redstone-contraption or
circuit-network components without forking library source.

Two registration shapes, not mutually exclusive — a real implementation
should support both, since they serve different caller needs:

- **Truth-table-defined registration**: caller supplies a name, an input
  arity (and per-input width, if parametric), and either a full truth table
  (a map or array from every input combination to an output combination) or
  a partial truth table plus a declared default for unlisted combinations.
  This is the natural fit for "arbitrary boolean logic block," is trivially
  serializable as game/mod data (fitting the Factorio-style data-stage
  model named in `docs/genre-battery-design.md`), and is what a truth-table
  dump/minimizer can introspect without needing to call back into caller
  code.
- **Function-defined registration**: caller supplies a name and a plain Lua
  function `(inputs) -> outputs` (operating on bus values per whatever
  representation Section 2.1 settles on). This is required for anything a
  finite truth table can't express cleanly at arbitrary width (e.g. a
  parametric N-bit adder-like component, if one is ever added) or where the
  caller wants to reuse existing Lua logic directly rather than re-encoding
  it as a table.

Registration is a plain function call against a module-level (or
per-circuit, see the open question below) registry, mirroring the pattern
crescent's conventions already establish for tiered/pluggable behavior
(`docs/conventions.md`'s implementation-tiers section, which is precedent
for "select behavior via a lookup, never a closed dispatch table"):

```
M.register_gate(name, spec) -> true | (nil, errmsg)
  spec.inputs  = { width = N, ... }        -- per-input pin declarations
  spec.outputs = { width = N, ... }        -- per-output pin declarations
  spec.truth_table = { ... }               -- OR:
  spec.eval = function(inputs) -> outputs  -- function form
```

Constructing a circuit that references an unregistered gate type name is a
construction-time error: `(nil, "unknown gate type: <name>")` — never a
runtime crash during simulation, per Section 8's error-handling
requirements below.

**Open question, not settled here:** is the registry global (module-level,
shared process-wide — simplest, but means two unrelated circuits/mods in
the same Lua state can collide on a gate-type name) or per-circuit-instance
(caller creates a circuit "session" object that owns its own registry,
seeded with the built-in baseline — avoids name collision across mods,
costs a small amount of extra API surface, e.g. `circuit.register_gate`
instead of `M.register_gate`)? This is exactly the kind of caps-first
question `CLAUDE.md`'s "no ambient globals by default" principle bears on —
a shared mutable module-level registry that arbitrary mod code can write
into is closer to an ambient global than an injected capability. Flagged
for owner sign-off, not decided here.

## 5. Multi-bit bus support

Given a width policy from Section 2.2 and a value representation from
Section 2.1, bus evaluation for the standard bitwise gates (AND/OR/XOR/NOT/
NAND/NOR/XNOR) has exactly one correct rule, independent of which options
above are chosen: **apply the 1-bit truth table independently to each bit
position of the (width-resolved) input buses, producing an output bus of
the same width.** This is what makes multi-bit support "real" rather than
convention-only — it is a single, actually-executed elementwise map over
bus contents at simulation time, not a comment promising the caller may
apply a scalar gate N times themselves.

Custom registered gates (Section 4) are **not** required to be bitwise-
elementwise — a function-defined gate can implement genuinely non-bitwise
bus behavior (e.g. a bus-width-changing component, or a component whose
per-bit outputs depend on more than the same-position input bits, such as a
priority encoder). The elementwise-lift rule is the *default* behavior for
the built-in baseline gates specifically, not a constraint imposed on every
possible registered component. This is what actually satisfies the "not a
single-bit gate applied element-wise by convention only" requirement:
elementwise lifting is one real, executed strategy among several a
component can implement, not the only shape the bus abstraction permits.

## 6. Multiplexer and demultiplexer: real semantics

Both defined for **arbitrary select-line width S**, generalizing the
textbook 2:1/4:1 mux to 2^S:1.

### Multiplexer (MUX)

- Inputs: `2^S` data buses, each of a declared common width `W`; a select
  bus of width `S`.
- Output: one bus of width `W`.
- Semantics: interpret the select bus as an unsigned binary index `i` in
  `[0, 2^S - 1]`; output = data input `i`. If any data input's width
  disagrees with the declared common width `W`, this is the same bus-width-
  mismatch case as Section 2.2 and resolved by whichever policy is chosen
  there — not a separate special case.
- If the select bus itself carries a value outside `[0, 2^S - 1]` (only
  possible under a value representation that admits `X`/`Z`, per 2.1 — a
  2-value bus of width S is always in range by construction): behavior
  depends on 2.1's resolution. Under 4-value semantics, standard practice
  (matching Verilog's `case` with unknown select) is that the output
  becomes `X` in every bit position, signaling "selection is
  indeterminate" rather than picking an arbitrary input. Not committed here
  independently of 2.1.

### Demultiplexer (DEMUX)

The audit names this component specifically as broken in the existing
library (a stub returning its first input), so its real semantics are
spelled out in full:

- Inputs: one data bus of width `W`; a select bus of width `S`.
- Outputs: `2^S` buses, each of width `W`.
- Semantics: interpret the select bus as an unsigned binary index `i`;
  output `i` = the data input, verbatim. **All other outputs are driven to
  the demultiplexer's declared "unselected" value** — this is the crux of
  what makes a demux actually demultiplex rather than degenerate into a
  fan-out buffer: exactly one output must ever carry the live data value at
  a time; the rest must be a well-defined inactive value, not a copy of the
  input and not left floating.
  - Under a 2-value model, "unselected" must be a concrete choice: `0`
    (all bits low) is the conventional default matching how a real
    demultiplexed control line reads as "not asserted," but this is a
    per-instantiation configurable default, not hardcoded — some redstone/
    circuit-network use cases legitimately want the unselected outputs to
    hold their last value (a latching demux) rather than reset to 0.
  - Under a 4-value model, `Z` (high-impedance) is the natural "unselected"
    value, matching how real demultiplexed tri-state buses behave, and
    would not need the configurable-default escape hatch a 2-value model
    needs — another way in which 2.1's resolution changes downstream
    component semantics rather than being a cosmetic representation
    choice.

This spec is a genuine demultiplexing behavioral contract — N outputs, at
most one carrying live data at any evaluation, driven by index — not a
truth table copied from a mux and relabeled.

## 7. Truth-table generation and logic minimization

Carried forward as real, load-bearing value per the task (this is
functionality the audit credits the existing library with having, tested
and solid, independent of the flaws elsewhere).

- **Truth-table generation**: given a combinational sub-circuit (a
  component or a composed subgraph with no sequential elements, verified by
  the same cycle/sequential-boundary analysis Section 6's simulation
  strategy already needs to do) and its declared input width, enumerate all
  `2^(total input bits)` input combinations, evaluate the circuit for each
  (via whichever simulation strategy from Section 8 is chosen), and record
  input→output. This directly reuses the eval machinery — it is not a
  separate evaluation path that could drift from the "real" simulator.
- **Logic minimization**: Quine-McCluskey (or an equivalent exact
  minimization algorithm, e.g. Espresso-style heuristic minimization as a
  documented alternative for larger input counts where Quine-McCluskey's
  worst-case cost becomes prohibitive) consumes a generated truth table and
  produces a minimized sum-of-products (or product-of-sums) boolean
  expression. This is a pure function over the truth table structure from
  the previous step — it has no dependency on which gate-representation or
  simulation-strategy option gets chosen elsewhere in this document, which
  is why it is presented here as settled machinery rather than a further
  branch point: minimization operates on the *output* of truth-table
  generation, not on the circuit graph directly, so it is insulated from
  the open choices above.
- Output form: the minimized expression should be representable both as a
  human-readable boolean expression string and as a re-instantiable
  circuit (a composition of the registered basic gates) so minimization
  results can be dropped back into a circuit, not just displayed — relevant
  to a puzzle-game genre core where minimization could plausibly be a
  player-facing scoring mechanic ("fewest gates").

## 8. Error handling

Per `docs/conventions.md`, every fallible library entry point returns
`(nil, errmsg)`, never throws, for data errors — malformed circuit
descriptions and invalid connections are data errors, not programming
errors, since they originate from caller/mod/player-authored circuit data,
not from misuse of the Lua API itself. Concretely, at minimum:

- **Undefined gate type** (Section 4): `(nil, "unknown gate type: <name>")`
  at circuit-construction time (component instantiation), not deferred to
  first evaluation.
- **Bus width mismatch** (Section 2.2/5): `(nil, "bus width mismatch: ...")`
  at connection time (wiring an output pin to an input pin), under whichever
  width policy (strict/extend/truncate) is chosen — even the extend/truncate
  policies still need a hard error for cases they can't resolve, e.g. a
  0-width bus.
- **Combinational cycle detection**: a combinational loop (a path of purely
  combinational components from a net back to itself, with no flip-flop/
  latch clock boundary breaking the loop) is a construction-time or first-
  evaluation-time error, `(nil, "combinational cycle detected: <path>")`,
  including the offending path/component chain in the message per
  `docs/conventions.md`'s "human-readable, function has variants" guidance.
  How this is actually detected is strategy-dependent — see Section 9,
  since Options A/B/C detect it via different mechanisms with different
  false-positive/false-negative shapes.
- **Multiple drivers on one net** under a 2-value model (Section 2.3):
  `(nil, "net driven by multiple outputs: ...")` at connection time.

None of these should ever surface as a raw Lua `error()`/crash from
malformed circuit data — a puzzle player or mod author wiring a bad circuit
is the primary expected failure mode this library will see, not an edge
case.

## 9. Simulation strategy options (the core "no forced winner" decision)

This is the central architectural fork the task asked to be presented
without a winner. All three options must satisfy the same contract:
correctly evaluate the built-in and registered gates over buses (Sections
3/5), correctly implement mux/demux (Section 6), support truth-table
generation (Section 7), and surface cycle/width/unknown-gate errors per
Section 8 rather than hanging or crashing. They differ in *how* they
propagate values and *how* they detect a bad (combinational-cycle) circuit
versus a legitimate sequential feedback loop.

### Option A — Event-driven discrete-event simulation

Each component evaluation, when triggered, schedules its output changes as
future events on a time-ordered event queue (optionally with a nominal
per-gate delay, as Logisim-family simulators do specifically to make
oscillation visible rather than silently infinite). The simulator pops
events in time order, applies them, and re-schedules downstream components
whose inputs changed.

- **Propagation order**: determined dynamically by the event queue, not
  precomputed — a component only re-evaluates when one of its actual inputs
  changed, which scales well when only a small part of a large circuit is
  "hot" per step (relevant to Factorio-circuit-network-scale simulations
  where most of the network is quiescent most ticks).
  - **Correction on the throughput claim above:** the scaling advantage
    just described (only re-evaluating changed regions) is a
    *structural property of event-driven simulation in general*
    (established in discrete-event simulation literature and borne out by
    real event-driven HDL simulators), not a measured property of this
    design, which does not exist yet. State it as an expected property, not
    a benchmarked one, until an implementation exists to benchmark.
- **Cycle/oscillation detection**: an unclocked combinational loop
  self-schedules forever (each event causes the next). Detection is
  therefore not structural/upfront — it requires a runtime guard: either a
  simulated-time or event-count budget per external stimulus, with
  "budget exceeded" treated as a detected combinational cycle and reported
  via Section 8's `(nil, errmsg)` contract rather than let the event loop
  spin. This means cycle detection is a *runtime heuristic* under this
  option (a real cycle always trips the budget eventually, but the budget
  value itself is a tuning parameter, and a very deep but legitimately
  non-oscillating chain could in principle need a larger budget than a
  small one) — a real cost relative to Option B's exact upfront detection.
- **Delay modeling**: this option is the only one of the three that can
  represent per-component propagation delay as a first-class concept at
  all (relevant if a genre core ever wants "signal takes N ticks to
  travel," a real redstone-adjacent mechanic).
- **Best fit**: circuits with sparse activity per step, or genre content
  that wants observable propagation delay as a mechanic.

### Option B — Topological-sort / level-based evaluation

Precompute a topological ordering of the combinational subgraph (components
between sequential-element boundaries) once per circuit structure change,
then evaluate every component exactly once per simulation step in that
fixed order. Sequential elements (flip-flops/latches) are the only nodes
allowed to have incoming edges from "later" in the order — they read their
data input from the current step and only publish their new output at the
next clock edge, which is precisely what allows the topological sort to
terminate on a circuit containing register feedback (the same technique
Verilator uses).

- **Propagation order**: static, computed once per structural change
  (component/wire added or removed), then reused across every simulation
  step until the structure changes again — cheaper per-step than Option A
  when the whole circuit is expected to re-evaluate every step anyway
  (e.g. every gate's output is read every tick regardless of whether its
  inputs changed), at the cost of doing full-circuit work even when only a
  small region is active.
- **Cycle detection**: exact and upfront. Topological sort on the
  combinational-only subgraph (with sequential-element pins treated as
  sort boundaries, not edges) either succeeds, producing a valid order, or
  fails because a cycle exists in the combinational portion — which *is*
  the error case from Section 8, detected as a direct byproduct of
  constructing the order (standard DFS-based topological sort with a
  "currently on this DFS path" marker set reports the exact cycle), not a
  runtime timeout guess. This is the option that gives an exact, not
  heuristic, answer to "is this circuit's combinational logic valid,"
  which is a meaningful correctness property.
- **No native delay modeling**: within a step, all combinational logic
  updates as if instantaneous (matches how most zachlike/puzzle circuit
  games actually want to present logic — a step is atomic, not "signal
  visibly crawling across the board mid-step" unless the genre core layers
  that presentation on top itself).
- **Best fit**: circuits with clear, regular per-tick evaluation (matches a
  turn/tick-based puzzle or building game's natural step model far more
  directly than continuous delay-based propagation), and any case where
  exact upfront cycle detection (rather than a runtime budget heuristic) is
  wanted.

### Option C — Naive iterative relaxation ("evaluate until stable")

Re-evaluate every component in an arbitrary (or arbitrary-but-fixed) order,
repeatedly, until either no output changes between passes (a fixed point —
the circuit has settled) or a pass-count cap is hit (treated as the
combinational-cycle error case). No topological analysis, no event queue.

- **Propagation order**: unspecified/arbitrary within a pass; correctness
  does not depend on ordering because the algorithm iterates to a fixed
  point regardless — this is also its main weakness, since a poorly-ordered
  pass can need many more iterations to converge than a topologically
  correct order would need (which converges in exactly one pass by
  construction).
- **Cycle detection**: heuristic via pass-count cap, same fundamental
  shape as Option A's runtime budget (a real combinational cycle never
  converges and always hits the cap eventually; the cap value is a tuning
  parameter, not an exact structural fact) — Option C shares Option A's
  cycle-detection weakness while forgoing Option A's delay-modeling
  benefit.
- **Simplicity**: by a wide margin the simplest of the three to implement
  and to reason about correctness-wise for a first version — no event
  queue, no topological-sort/DFS machinery, no delay bookkeeping. This is
  its actual selling point, not a claim about runtime performance, which
  is expected to be the worst of the three for any circuit large enough
  that iteration count matters (unverified — no implementation exists to
  benchmark, stated as expectation from the algorithm's shape, not
  measurement).
- **Best fit**: an initial/reference implementation prioritizing
  correctness-by-construction and implementation simplicity over
  performance or exact cycle diagnostics, with Option B as a natural
  later upgrade path once correctness is established (same combinational/
  sequential boundary concept carries over almost unchanged).

### Cross-option note on sequential elements

All three options rely on the same underlying discipline: a flip-flop or
latch is the boundary that makes feedback legitimate rather than a cycle.
What differs is only *how* each option's cycle-detection mechanism uses
that boundary — Option B uses it structurally (as a topological-sort
boundary, giving exact detection), while Options A and C use it
implicitly (a correctly-modeled sequential element simply doesn't
re-trigger its own combinational fan-in within a single step/tick, so it
doesn't feed the runaway budget/pass-count the way an actual combinational
cycle would) — meaning Options A/C's cycle detection is only as reliable as
each sequential component's own implementation correctly gating its update
to its clock/enable input, whereas Option B's correctness doesn't depend on
that.

## 10. Explicitly open questions (owner sign-off required before implementation)

Restated together, matching the halt-on-underspecification standard this
document was written under — each is a genuine semantic fork with more
than one defensible answer, not a detail this document is entitled to
silently pick:

1. **Signal value representation** (Section 2.1): 2-value (`0`/`1`) or
   4-value (`0`/`1`/`X`/`Z`)? Changes gate semantics, mux/demux
   "unselected"/"indeterminate select" behavior, and multi-driver-net
   legality throughout.
2. **Bus width mismatch policy** (Section 2.2): strict-reject,
   zero/sign-extend, or truncate? If extend is chosen, is signedness a
   per-bus tag set at construction, and what is the default when
   unspecified?
3. **Gate registry scope** (Section 4): one shared module-level registry,
   or per-circuit-instance registries seeded from the baseline? Bears
   directly on `CLAUDE.md`'s no-ambient-globals/caps-first principle.
4. **Demux "unselected" output default** (Section 6): fixed at `0`
   (2-value model) or configurable per-instantiation (reset-to-zero vs.
   latch-last-value)? Moot if the 4-value model is chosen, since `Z` is
   the natural unselected value there — this question is itself downstream
   of question 1.
5. **Simulation strategy** (Section 9): Option A, B, or C — or, since they
   are not mutually exclusive as a long-term shelf (per `CLAUDE.md`'s
   "when one implementation can't satisfy all legitimate use cases,
   provide multiple" principle, already the house pattern for FFI/pure-Lua
   tiers), which one ships first and whether more than one is intended
   ever to coexist as real independent implementations rather than one
   wrapping another.

This document does not recommend answers to these five. Each is presented
in the relevant section with its tradeoffs named side by side.
