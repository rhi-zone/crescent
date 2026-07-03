# v9 — the engine core: a monotone-fixpoint analysis engine

v9 is built around ONE validated idea (settled by the engine-core experiment —
`experiments/v9-spikes/{A-term-core,B-cfg-dataflow,C-constraint-graph}`, commits
`4aaee144`, `11a33cac`, `1e234cb3`):

> **The engine is a monotone worklist fixpoint over lattice CELLS, parameterized
> by `(per-cell lattice, transfer functions, dependency structure)`. "Constraint
> solving" and "dataflow" are not two modes — both are monotone fixpoints over
> cells.** Type INFERENCE is the instance where cells are UNKNOWNS (type
> variables whose lattice is type-bounds and whose transfer is subtyping
> propagation → annotation-free principal types). Flow analyses (liveness,
> constant propagation, narrowing) are instances where cells are program points.

So the central seam is **NOT** "type representation + subtyping". It is the
**engine** (domain-agnostic, knows zero type/liveness vocabulary) and the
**domain interface** `(lattice, transfer, dependencies)`. Type-representation and
subtyping are *one domain's lattice+transfer*, not the architecture.

This re-cut replaces the previous "type-checker seam" framing (a bidirectional
`synth`/`check` over a de-Bruijn IR as the centre). That code is **retained but
repositioned** — see "Legacy type-checking seams" below.

## Why this shape (the evidence)

The three spikes were thrown at the question "is the proof's `tm`/typing core
secretly type-shaped, or does it generalize to a multi-domain engine?". Their
NOTES are the evidence; the load-bearing findings:

- **Spike A (term-core).** A term-recursive evaluator hosts forward types + a
  join-at-merge for flow-sensitivity *for free*, but **cannot express loops'
  back-edges** and smuggles a forward domain's per-expression value through a
  "result register". Verdict: *keep the term as a lowering input, replace the
  iteration structure with a worklist/CFG.* v9 does exactly this — the surface
  AST is a lowering input; the iteration is the worklist.
- **Spike B (cfg-dataflow).** A worklist over a CFG hosts forward types AND
  backward liveness with **direction as a single predecessors-vs-successors
  swap**, never a special-case in the loop. v9's `dataflow.lua` is this swap, and
  *only* this swap.
- **Spike C (constraint-graph).** Cells-as-unknowns + constraints (reads/writes/
  apply) over one worklist hosts annotation-free inference (SSA/phi → union
  types) and gen/kill liveness as nothing but `(cells, lattice, constraints)`.
  v9's engine IS this loop. Crucially C showed **gen/kill's set-MINUS lives
  inside a transfer's `apply`, not in the lattice** — which is why the domain
  interface is *monotone transfer functions over a lattice*, not "subtyping
  constraints". A subtyping-constraint framing would have forced liveness's
  `kill` to hide somewhere dishonest; transfer-functions subsume BOTH
  subtyping-propagation and gen/kill.

The one gap all three shared: they *coincidentally* used set-union lattices. v9
closes it with a third domain on a genuinely different lattice (constant
propagation, below).

## The engine contract (`engine/engine.lua`)

```
solve(graph) -> (Solution | nil, errmsg)
  graph    = { lattice, rules }
  Solution = { values : { cellid -> value }, steps }
```

The engine seeds a worklist with every rule; pops a rule, runs its `apply`,
**joins** each proposed value into the target cell, and — if a cell changed —
re-schedules every rule that **reads** that cell. Termination is guaranteed by a
monotone `join` over an ascending chain; a step budget converts a non-monotone
domain (a bug) into an honest `(nil, errmsg)` rather than a hang.

Properties that are load-bearing, not incidental:

- **Zero domain vocabulary.** The engine mentions no atom, no "live"/"dead", no
  type, no direction. Grep it: the only domain words are in comments saying what
  it does *not* know.
- **Pure function of its graph.** `cells`/`work` are solve-local scratch, never a
  cross-call coordination channel. No singleton, no message bus, no stateful
  solver instance (the documented legacy rot — `docs/decisions/v9-versions-survey.md`).
- **Direction is not an engine concept.** Dependencies are explicit in each
  rule's `reads`/`writes`. "Forward vs backward" is a property of how a *flow*
  domain wires its rules (see the adapter), so the engine stays direction-free.
  This is a deliberate sharpening of the validated spec: the cell model
  *subsumes* direction (Spike C's insight), so direction is a lowering parameter,
  not an engine mode — which makes "both directions are instances of one engine"
  literally true rather than a special-case in the loop.

## The domain interface (`engine/defs.lua`)

This is the century-load-bearing seam. A **domain** provides:

```
Lattice    = { bottom, join, equal }            -- a join-semilattice over cell values
Rule       = { reads, writes, apply }           -- one monotone transfer; apply(get) -> { cell -> value }
FlowDomain = { lattice, direction, boundary, transfer }   -- a flow analysis (lowered to Rules by dataflow)
```

- `Lattice` is the per-cell lattice. `join` is the engine's merge; `equal` is the
  fixpoint test; `bottom` is every cell's start value. A multi-input merge needs
  **no fold** — emit one proposal `Rule` per input and the engine's monotone
  `join` over proposals IS the least-upper-bound.
- `Rule.apply` is the transfer function. It reads cells via `get` and proposes
  new cell values. Set-minus, arithmetic, subtyping propagation, gen/kill — all
  live *inside* `apply`; the lattice only ever sees `join`/`equal`/`bottom`.
- `FlowDomain` is the convenience shape for classical dataflow: `direction`
  selects the preds/succs swap, `transfer` is the per-block transfer, `boundary`
  is the entry (forward) / exit (backward) value. `dataflow.to_graph` lowers it
  to `Rule`s. A domain that is not block-structured (the type domain) skips this
  and builds `Rule`s directly.

### Why the cell type is `unknown`, not a generic parameter

The cleanest interface would be generic: `Lattice<V>`, `Graph<V>`, `solve<V>`.
The crescent typechecker cannot support that across this module layout, and that
is a genuine substrate finding, not a preference:

1. **Generics do not survive `require`.** A `solve<V>`/`to_graph<V>` imported into
   another module fails to instantiate `V` from a concrete argument — `V` stays
   an abstract skolem (minimal repro confirmed). Every domain is a separate
   module, so every call would cross this boundary.
2. **No force-casts, no `unknown`→record checked-casts.** `--[[:! T]]` is a hard
   error here; `--[[: T]]` from `unknown` is rejected ("must narrow first").

So the engine is **monomorphic over an opaque `unknown` cell value** — which is
exactly idiomatic `unknown` (the engine shuttles values it must not inspect) —
and each domain **narrows `unknown` to its concrete lattice type at its own
boundary via a type predicate** (`--: (x: unknown) -> x is LiveSet`). This is
force-cast-free and keeps the engine genuinely opaque. The narrowing is a few
lines per domain (`as_live`/`as_env`/`as_atoms`). This is the single place the
substrate dictated the interface's shape; it is recorded, not papered over.

## How Lua lowers into cells / CFG (`engine/surface.lua`, `engine/cfg.lua`)

The **pinned cell/op vocabulary (fork 1)** — the initial surface, deliberately
small and extensible toward full Lua:

- Expressions: `int` / `str` / `bool` / `nil` literals, `var` use, `add` (one
  binary op).
- Statements: `local`, `assign`, `if`/`else`, `call`, `return`.

`surface.lua` defines the constructors + ONE shared sample program. Lowering has
two paths, both from this single surface:

- **Flow analyses** lower the statement list to a **CFG of basic blocks**
  (`cfg.lua`); `dataflow.to_graph` wires each block's `in`/`out` cells into engine
  `Rule`s, doing the preds/succs swap once.
- **Type inference** walks the surface **directly**, minting an SSA cell per value
  and phi cells at `if`-merges, emitting engine `Rule`s. Cells are type unknowns;
  no CFG needed.

The vocabulary grows by adding a former in `surface.lua` (+ a `cfg.lua` arm if it
affects control flow) and a transfer arm in each interested domain — a local
change, never a cross-cutting edit. Loops (`while`/`for`) are the next increment:
a back-edge is just another `succs`/`preds` entry and the worklist already
iterates to fixpoint — the engine does not change.

## The three domains (the interface pressure-test)

All three run end-to-end on the SAME annotation-free program
(`engine/engine_test.lua`, 17 assertions):

| Domain (`engine/domain/`) | cells | lattice | direction | transfer |
|---|---|---|---|---|
| `types.lua` | type unknowns (SSA + phi) | atom-set, union | n/a (direct) | subtyping propagation (flow into assigned cell) |
| `liveness.lua` | program points | live-name set | **backward** | gen/kill (set-minus inside `apply`) |
| `constprop.lua` | program points | **⊥ / Num(n) / ⊤** | **forward** | abstract eval + fold |

- **Type inference is genuine and annotation-free.** `x : int | str` falls out of
  the engine's `join` at the phi cell of the `if`; `y = x + 1` infers `int`; the
  return type is inferred `int | str`. No annotation appears in the program.
- **The pressure test passed without flexing the interface.** Constant
  propagation is the case the spikes never ran: a **non-set-union** lattice with a
  real ⊤ and a join that **loses information** (`join(Num 1, Num 2) = ⊤`), plus a
  transfer that genuinely **computes** (`1 + 1 → Num 2`). It plugged into the SAME
  engine and the SAME `dataflow` adapter with **zero engine/interface changes** —
  the only domain-specific code is its lattice + transfer + the `as_env` narrowing
  predicate every domain has. This is the evidence that the interface is general,
  not type-shaped.

The one place the substrate (not the *interface*) flexed: the `unknown`-cell
decision above, forced by the checker's generics/`require` limitation. The
interface's *shape* — `(lattice, transfer, dependencies)` — did not change.

### Decoupling (shown, not asserted)

- No domain imports another (`grep` the `domain/` dir: zero cross-imports).
- The engine imports only `defs` (annotation-only); it names domain vocabulary
  only in comments describing what it does not know.
- The test drives ALL THREE lowered graphs through the SAME `engine.solve`.

## Adding a domain or a rule (incremental, local)

- **New analysis (new domain):** a new module under `engine/domain/` providing a
  `Lattice` + either a `FlowDomain` (block-structured: get the preds/succs swap
  for free) or direct `Rule` construction (cells-as-unknowns). Add a narrowing
  predicate for its value type. Nothing else moves; the engine is untouched.
- **New rule / transfer case:** one arm in a domain's `transfer`/`apply`. The
  engine and other domains do not change.
- **New surface former:** a constructor in `surface.lua` (+ `cfg.lua` arm if it
  affects control flow) + a transfer arm in each interested domain.

## Seam map

| Seam | File | Swappable behind | Knows about |
|---|---|---|---|
| **Engine** | `engine/engine.lua` | `Graph` = `(Lattice, Rule[])` | cells only — zero domain vocabulary |
| **Domain interface** | `engine/defs.lua` | `Lattice` / `Rule` / `FlowDomain` | the contract; no impls |
| **Flow adapter** | `engine/dataflow.lua` | `FlowDomain` → `Graph` | CFG (block/preds/succs/in/out); the direction swap; no analysis vocabulary |
| **Lowering** | `engine/surface.lua`, `engine/cfg.lua` | the surface AST → CFG / SSA | the cell/op vocabulary |
| **Type domain** | `engine/domain/types.lua` | a `Lattice` + SSA `Rule`s | atoms, unions, subtyping |
| **Liveness domain** | `engine/domain/liveness.lua` | a `FlowDomain` | live sets, gen/kill |
| **Constprop domain** | `engine/domain/constprop.lua` | a `FlowDomain` | the const lattice |

Every box is swappable; the engine depends only on the domain interface (DIP).
Multiple impls behind one interface is real: the three domains are three
independent `Lattice`/transfer instances over one engine, and a fourth (a
different inference lattice, an interval analysis, a must-analysis) is a new
module, not an engine edit.

## The Lua vertical slice (v0): real files -> real diagnostics

The engine + domain interface above is exercised by a REAL checker path
(July 2026): parse an actual `lib/**/*.lua` file, lower it TOTALLY, solve on
the engine, and emit line/col diagnostics.

| Seam | File | Contract |
|---|---|---|
| **Frontend** | `frontend/init.lua` | source -> plain-table AST (line/col on every node), `(nil, errmsg)` on syntax errors. Wraps the proven legacy parser (`lib/type/static/{lex,parse}`) + the v4 arena decoder, required in place — swappable behind this seam. The s-expr `parser.lua` is fenced as proof-oracle-only. |
| **v0 lattice** | `lattice.lua` | atoms (nil/**true/false literals** (boolean = their union; constructors normalize the spelling, show/excess collapse the pair; mutable-ref creation WIDENS a lone literal to the pair — the flag idiom `{ enabled = false }` stays writable — while flow values and annotated refs keep literal precision)/number/string + table/function tops) + STRUCTURAL OPEN RECORDS (width-subtyped; per-field read/write split — r joins up, w meets down — the engine-lattice encoding of the proof-dev's records-of-refs, making mutation sound: see the file header) + FUNCTION TYPES (`(params...) -> (results...)`: params as CELL IDS + annotation PINS — the contravariant face lives in pins/obligations because a meet-polarity component cannot ride the engine's join (the arrow analogue of the record r/w split); results as VALUES, covariant, rebuilt monotonically; join of two different arrows collapses to the `function` top; `clip` bounds recursion-created value cycles) + finite unions + absorbing `unknown`. `truthy`/`falsy` are the flow operations — EXACT under the literal split (falsy = nil \| false, so `cond and a or b` infers `type(a) \| type(b)`, no phantom boolean); `if`-narrowing and `and`/`or` both derive from them (`a and b : falsy(a) | type(b)`) — the historic hardcoded-`boolean|nil` bug is structurally impossible and pinned by tests. `tag_keep`/`tag_drop` are two more of the same shape: the `type(x) == "…"` guard filters over tag→atom-SET (the boolean tag covers the pair; keep narrows even `unknown` to the tag's atoms — how dynamic values enter the discipline; drop from `unknown` stays `unknown`, a stated upper approximation); `x == nil` / `x ~= nil` guards are the SAME filters at the nil tag. Field access adds `project`/`set_field`; ordering adds `leq` (fn_leq: params contravariant / results covariant; identity fast path for shared alias-DAG structure) and `leq_init` (initialization ascription for fresh constructors: field refs re-typed, absent fields read as nil). |
| **Annotation seam** | `annot/init.lua` | the `--:`/`--::` type-grammar STRING -> a v9-owned tree (NOT a lift of legacy `ann.lua`). Parses: atoms (integer -> number; literals UP-approximated to base atoms), `unknown`/`never`, unions, records (optional `x?:` / `readonly` / open `...`), function types (named params, multi-return, `...T` rest, `x is T` predicates as boolean results, `-> (T, U, ...)` result-OPEN tuples), `--:: Name = T` aliases (recursive ones unroll ONCE and cut to unknown at the knot — the clip discipline; expansion is MEMOIZED per parse so mutually-recursive alias graphs stay linear — the At is a DAG — with a hard expansion BUDGET as the honest `alias-budget` backstop, never a hang), `--:: declare name = T` global declarations (classified for the globals seam). Everything else is a NAMED per-feature bucket (`unsupported:annotation-{generic, intrinsic, typeof, intersection, complement, index-signature, array, meta-slot, cdata, any, unknown-name, alias-budget, ...}`); `--:: require` and runtime `require(...)` are `unsupported:cross-module`. |
| **Globals seam** | `globals/init.lua`, `globals/stdlib.lua` | `global name -> annotation tree`. Source (a): the STDLIB declarations — LuaJIT 5.1 globals as `--:: declare` DATA in v9's own grammar (mined from the legacy `lib/type/static/stdlib_types.lua`, translated to v0: generics/overloads widen to the widest concrete arrow, index signatures -> the `table` atom, pcall/select/string.find as result-OPEN arrows; `ffi` deliberately NOT declared — it is not a LuaJIT global, it rides `require`), parsed ONCE per process and shared (interning); a non-empty `problems` list is a checker bug, asserted empty by tests. Source (b): per-file `--:: declare name = T` lines (the house convention), wired in lower's pre-pass, shadowing stdlib. READS resolve typed (one lazily-minted pinned cell per referenced global per file; At->Val conversion is memoized on shared At nodes); WRITES stay the `global-write` policy diag; `undeclared-global` fires only for genuinely unknown names. |
| **Total lowering** | `lower.lua` | AST -> engine `Graph` + `Obligation`s + structural diags in ONE walk, ONE rule shape (seed / flow / filter / project / set_field / call / fn-rebuild + obligations). ALL 30 node kinds routed: v0-checked, or `unsupported:<construct>` with line/col (`M.ROUTE` is the roster; tests assert totality). Records: field reads/writes (incl. the `function M.f()` module idiom) and named-field constructors CHECKED; non-literal keys `unsupported:dynamic-index`. Functions: param cells seeded from call sites (cells-as-unknowns) AND/OR annotation pins; per-position multi-return with Lua truncation/nil-extension; recursion via bind-before-body + clip; a parameter with NO evidence (no call, no pin) is ONE `unsupported:unconstrained-param`, not a per-use flood. Annotations are PIN + CHECK (a pin is both a seed and an upper-bound obligation; inference must AGREE): locals/assignments/table-fields/field-writes pin cells; preceding-line arrow annotations pin params (checked per call site, incl. nil pads and contravariant callback seeding) and returns (per-position, at the return line); `--[[: T]]` checked casts narrow the flow, `--[[:! T]]` is the force-cast policy. A pin that DEGRADED to unknown through a bucket pins nothing (⊤ carries no checking value; explicit `unknown` stays a pin). CONTROL-FLOW PRECISION (July 2026): merges are reachability-aware — a branch ending in a definite jump (return / break / a declared-`never` call: the stdlib's `error`) contributes nothing to the phi, so `if type(x) ~= "string" then return end` narrows the fall-through; both arms diverging = bottom (dead code checked against no values). LOOPS are the same phi with a back edge: loop-head phi per rebindable decl (assigned-roots scan), CLIPPED back-edge proposals (the third cycle-closing site — loop-grown values terminate), condition narrowing into the body / complement onto the exit, reachable-exit merge (cond-false edge — absent for `while true` — plus break snapshots; break diverges and snapshots into its loop frame, reset across function boundaries). for-num: loop var seeded number, bounds obligated ⊑ number. for-in: the generic-for protocol as ONE ordinary call (vars = result positions, var 1 nil-dropped, control cycling through a phi as the nil-dropped result). repeat lowers `until` inside the body scope (the Lua quirk). The havoc fence is GONE — its last consumer was the loop boundary. |
| **Runner** | `check.lua` | `check_source`/`check_file` (caps-first) -> policy-stamped, position-sorted diags. THE POWER DIAL: named policy rules (`op-mismatch` / `call-non-function` / `call-mismatch` / `field-write-mismatch` / `annotation-mismatch` / `cast-mismatch` / `force-cast` = error; `missing-field` / `use-before-narrow` = warn; `new-field-on-write` = off — the ONE named open-record concession; per-bucket `unsupported:*`; "off" suppresses) — strictness is owner-decidable data, in one place. |
| **Smoke** | `smoke.lua` | tool entry: whole-`lib/` totality run + diagnostic histogram (the coverage roadmap). July 2026, with loops + control-flow precision: 1,563 files, ZERO crashes, full solve ~17.6s (back-edge cycles added and solve time still went DOWN vs 18.3s — the retired loop-boundary diag volume paid for the cycles). |

The histogram is the prioritized roadmap. With records (July 2026) the 314k
field/table family is retired. With FUNCTION TYPES + ANNOTATIONS (July 2026)
the totals moved 521,517 -> 495,478 and `use-before-narrow` 444,422 ->
389,417; `unsupported:cast-annotation` (6.7k) retired into checked/force
casts + per-feature annotation buckets; the two known
pending-annotations findings (keyring `_tier`, server_ws `res.body`)
resolve. With STDLIB/GLOBAL DECLARATIONS + `type()`-tag narrowing (July
2026) the totals moved 495,487 -> 440,652: `undeclared-global` 19,502 -> 33
(genuinely unknown names only), `use-before-narrow` 389,423 -> 351,109, and
the newly-typed surface converts silence into REAL findings — call-mismatch
1,673 -> 2,244 and op-mismatch 3,414 -> 4,073 (dominant new true-positive
class: `nil | string` / `nil | number` piped into stdlib pins —
`f:read()`/`tonumber()` results used unguarded); `unsupported:string-method`
1,522 -> 3,104 (string-typed values now flow further — wiring the string
metatable to the declared `string` table is the natural next cut).

With CONTROL-FLOW PRECISION (July 2026: true/false literal atoms +
nil-equality narrowing, reachability-at-merge, loops) the totals moved
440,651 -> 480,624 at 17.6s (was 18.3s) — the total went UP because ~11k
loop-boundary diags retired (`for-num` 5,205 / `for-in` 4,387 / `while`
1,449 / `repeat` 22 -> 0) and every loop BODY became checked surface:
`dynamic-index` 22,038 -> 43,708 (array indexing `t[i]` in loops — index
signatures are now clearly the top boundary), `use-before-narrow` 351,109
-> 375,842, `force-cast` 4,283 -> 5,907, `goto`/`label` 28/7 -> 112/53
(previously swallowed by the havoc fence with the loop around them). On
the same-surface classes precision WON: `op-mismatch` 4,073 -> 2,165 (the
boolean-literal class — `cond and a or b` no longer leaks `boolean`;
the recorded pagination:384 false positive resolves), `annotation-mismatch`
832 -> 720, and the recorded `lib/math/init.lua:11` `== nil` early-exit
false positive resolves (nil-equality + reachability). New TRUE-positive
classes: numeric-`for` bounds at `nil | number` (unguarded limits — most
are the and-chain narrowing gap below), loop-body field writes checked
(field-write-mismatch 83 -> 89 on net after the flag-idiom widening),
`for x in <non-function>` as call-non-function. Next increments: compound
CONDITION narrowing (`if limit and #x > limit`, `opts and opts.f` — the
and/or-chain arm of cond_target and RHS-of-`and` narrowing; it now gates
real for-num findings), index signatures in the lattice (dynamic-index
43.7k + annotation-index-signature 8.3k), cross-module summaries (3.2k +
`annotation-unknown-name` 3.4k). Known v0 imprecision: constructor
freshness is syntactic (a constructor routed through a local checks under
full leq, not initialization ascription); record tracking is
intraprocedural; goto is unmodeled (a backward goto's loop effects are
not fenced). All are domain-local lattice/lowering upgrades, not engine
changes — the engine has absorbed records, arrows, annotations, the
global environment + tag guards, and now BACK-EDGE CYCLES + reachability
with ZERO changes (fifth consecutive data point).

## Legacy type-checking seams (retained, repositioned)

The previous skeleton's bidirectional checker — `ir.lua` (de-Bruijn `tm`-shaped
IR with names-as-metadata), `subtype/` (the three-valued `DSub|DNotSub|DUnknown`
decider), `type_rep/`, `infer/bidir.lua`, `init.lua`, `type_defs.lua`,
`parity_test.lua` — is **retained** as the designated substrate the *type
domain's lattice will grow into*. The minimal type domain here uses an atom-set
lattice to prove the engine; a production type domain replaces that lattice's
`join`/transfer with the real subtyping decider and a richer `BTy`-shaped value,
behind the SAME `Lattice`/`Rule` interface. The de-Bruijn binder discipline
(names are non-semantic metadata) and the three-valued honest-deferral decider
are the ideas mined forward; they are not yet wired to the engine, and are fenced
here as legacy until that increment.

## Genuinely under-determined (flagged, not invented)

1. **Type-domain lattice depth.** The atom-set lattice is the minimal genuine
   inference lattice. The real one (records / arrows / negation / the proof's
   `BTy`, the three-valued decider as `equal`/`join`) is a domain-local upgrade —
   not designed here, because the engine validation does not need it.
2. **Cell-id scheme.** String cell ids (`ty:…#n`, `in:…`/`out:…`) are a
   convention; an integer/interned id scheme is a valid swap behind the engine
   (which treats ids opaquely).
3. **Generic engine.** If the checker gains `require`-surviving generic
   instantiation, `Lattice<V>`/`solve<V>` would remove the per-domain narrowing
   predicates. Until then `unknown` + predicate-narrowing is the force-cast-free
   bridge. Recorded as a substrate need, not worked around.
4. **Worklist order / widening.** FIFO worklist, no widening (the lattices here
   have finite height). An infinite-height lattice (intervals) would need a
   widening operator — a domain-local addition to the `Lattice` it needs it for,
   not an engine change.
