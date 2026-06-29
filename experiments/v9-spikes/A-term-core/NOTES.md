# Spike A — term-core + unified worklist (proof-faithful)

Throwaway experiment. Evaluates whether the proof-dev's `tm` term structure
(proof/typing.v) generalizes to a MULTI-DOMAIN static-analysis engine, or whether
it is secretly type-shaped.

## Run

```
bin/luajit experiments/v9-spikes/A-term-core/main.lua
```

## What's here

- `term.lua`      — the IR core (lit/var/call + seq/localdecl/assign/ifelse/ret).
- `lower.lua`     — hand-built surface AST for the fixed target program -> core.
- `engine.lua`    — the ONE domain-agnostic engine (abstract-interp driver).
- `domain_types.lua`     — forward, flow-sensitive type lattice (atoms+union+sub).
- `domain_liveness.lua`  — backward, 2-point live/dead lattice.
- `main.lua`      — wiring + required outputs.

## Honest findings

### 1. Domain decoupling — A-

The two domains share zero symbols (no cross-require, no cross-reference). The
engine mentions no atom, no "live"/"dead", no lattice element. It knows only the
IR's control-flow shape: `seq` ordering and `ifelse` split+join, both driven by
`dom.dir`/`dom.join`. Everything else is `dom.transfer[kind]` delegation.

The minus: the interface had to grow a `dir` flag and a `copy` op to host two
directions, and the engine special-cases `seq`/`ifelse` structurally. That's
honest (their control-flow meaning IS direction-dependent and domain-independent)
but it means the engine is not a pure fold — it's a fold that branches on `dir`.

### 2. Flow-sensitivity — A (clean)

`x : int | str` after the `if` falls out with ZERO special-casing. The engine
walks both branches from a copied state and calls `dom.join`; the type domain's
`join` is per-variable atom-set union. No "flow" machinery in the engine. This is
the paradigm's strongest result.

### 3. Scaling — mixed

(a) Full Lua surface: the term-core is fine as an IR, but two structural gaps
show immediately. (i) The proof core is EXPRESSION-oriented (`tlet` nests, `tif`
is a value); real Lua is statement-oriented with mutation. We had to graft
`seq`/`localdecl`/`assign`/`ret` on — the proof's let-core has no native
statement-mutation notion. (ii) LOOPS. This surface is a DAG, so a single pass
converges and the "fixpoint" loop in `engine.run` is theatre — it re-walks the
whole tree to compare. A real loop needs a CFG with back-edges and a genuine
worklist over basic blocks. The term-recursive structure does NOT give that; you
cannot express `while`'s back-edge as a tree fold. This is the biggest scaling
threat: term-recursion is the wrong shape for iterative dataflow.

(b) Unannotated inference: the type domain already infers — `localdecl` with no
annotation binds the synthesized type (see `local x = 1` -> int with no
annotation). For straight-line + if/else, synthesis-only inference works.
Bidirectional inference (unification across uses, polymorphism) is untested and
would need a constraint store the current "result register" state cannot hold.

### 4. Awkwardness — the result register

The load-bearing ugliness: a forward domain produces a VALUE per expression (the
type of a literal), but a backward domain produces none. The engine returns only
`state`, so the type domain smuggles its per-expression result through
`state.result` — a mutable register threaded by hand. It works, but it means the
"expression has a value" idea (central to typing, the proof's whole frame) is NOT
first-class in the engine; it's faked inside one domain. That is the concrete
sense in which the term-core is "secretly type-shaped": the proof's `tif : tm`
(an expression with a type) wants values-up; liveness wants facts-along-edges.
Forcing both through one `state -> state` transfer makes one of them awkward.

## Verdict

Fitness: PROMISING for the lattice/transfer/join seam, UNPROVEN for the engine
shape.

Carry forward:
- the domain interface (`dir` / `init` / `copy` / `join` / `equal` /
  `transfer[kind]`) — it cleanly hosted two maximally-different analyses;
- `join`-at-merge giving flow-sensitivity for free.

Drop / rework:
- term-recursion AS the engine. It cannot express loops' back-edges; the real
  engine should be a worklist over a CFG, with the term tree as a LOWERING input,
  not the iteration structure;
- the result-register hack. Either make the engine carry an explicit
  per-node value channel (forward domains use it, backward ignore it), or accept
  that "expression value" is a forward-only concept and don't pretend the engine
  is direction-symmetric.

Bottom line: the proof's `tm` is a fine IR and its `tif`-as-union instinct
generalizes to "join at merge". But the proof's expression-oriented, single-pass,
substitution-driven evaluation is NOT a multi-domain engine; the moment you add
backward analyses and loops, the term-fold stops being the right control
structure. Keep the data (the term), replace the iteration (worklist/CFG).
