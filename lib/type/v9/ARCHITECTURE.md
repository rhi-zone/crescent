# v9 — modular Lua typechecker: SEAM CONTRACTS

v9 is the runnable typechecker built against the mechanized proof-dev
(`proof/*.v`) as its **proven spec and parity oracle**. Its one non-negotiable
property is **Dependency Inversion everywhere**: every part is a SEAM behind an
interface with swappable implementations. Interfaces are the load-bearing,
must-be-right-forever part; implementations are cheap, swappable, grown
incrementally — "implement as little or as much as we want and keep adding as we
go." Adding a typing rule or a new impl is a LOCAL change behind an interface,
never a cross-cutting edit.

Motivation and the fresh-vs-salvage decision: `docs/decisions/v9-versions-survey.md`.
The survey's key finding — **the proof-dev already is the seam map**: each Coq
relation becomes one Lua interface, with the proof as the parity oracle.

The interface contracts live as types in `type_defs.lua` (annotation-only). This
document is the prose contract: for each seam, the interface, its proof oracle,
how multiple impls plug in, and why adding a rule/feature stays local.

## What we are NOT doing (the documented rot — avoided by construction)

- **No `ctx._foo` message-bus fields.** Cross-phase data rides on the IR and on
  the first-class `Deriv` (typed payloads), never on a mutable context. The
  `Caps` bundle is a READ-ONLY capability record (function tables), not scratch.
- **No if-elif-on-tag dispatch as the architecture.** Dispatch is local to one
  seam's impl and keyed on the proof's node/type families; adding a family does
  not edit a shared decider.
- **No fail-optimistic deciders.** The subtyping decider is THREE-VALUED;
  `unknown` is explicit deferral (the proof's `gdecide` DUnknown), never a guess.
- **No stateful solver singletons.** Impls are pure modules; the only state is a
  pure interning cache in the (optional) interned rep, which cannot affect verdicts.
- **No globals.** Every dependency is injected (caps-first). Inference receives
  `Caps = { rep, sub, diag }`; the checker is assembled in `init.new(impls)`.

## The DIP mechanism

A `Checker` is **assembled** from an `Impls` record (`init.new(impls)`); pass
`nil` for `defaults()`. Every seam is a field; swapping one (a different rep, a
different subtyping backend, a constraint engine, a real certificate emitter)
touches nothing else. The proof that this is real, not aspirational, is
`parity_test.lua`: tagged-vs-interned reps and structural-vs-reflexive deciders
swap behind one interface, and a full pipeline assembled from swapped impls runs.

---

## Seam 1 — Type representation (`type_rep/`)

- **Proof oracle:** `BTy` + `denote` (`subtype.v:645`). Each `kind` string is a
  `BTy` constructor head (`atom/top/bot/union/inter/neg/arrow/rec/ref/anyref/tuple`).
- **Interface (`TypeRep`):** constructors (`atom`, `top`, `bot`, `union`, `inter`,
  `neg`, `arrow`, `rec`, `ref`, `anyref`, `tuple`), a destructor `kind`, partial
  accessors (`atom_name`, `union_left/right`, `inter_left/right`, `neg_of`,
  `arrow_dom/cod`, `ref_of`, `tuple_items`, `rec_fields`), and `equal` / `show`.
- **Opacity (the load-bearing contract):** `Ty = unknown`. A consumer holds an
  opaque handle and may ONLY inspect it through `TypeRep` functions — never by
  field access. This is what lets two impls coexist without the consumer knowing
  which is in use.
- **Two impls admitted:** `tagged.lua` (immutable-structural, DEFAULT — built
  now) and `interned.lua` (arena-interned, the start of the reserved
  interned-arena impl — different internal node shape + atom hash-consing). They
  give byte-identical verdicts under any consumer (`parity_test.lua`), proving
  the seam does not leak.
- **Adding a feature stays local:** a new `BTy` former = one `kind` + its
  constructor/accessors in each rep impl, plus arms in the decider/show. No
  consumer changes shape.

## Seam 2 — Subtyping decider (`subtype/`)

- **Proof oracle:** `decide_ssub` / `ssub` (`ssub.v`, structural decider, total +
  sound/complete vs `ssub`) and `gdecide` / `dsub` (`subtype.v`, semantic
  value-set decider, three-valued `DSub | DNotSub | DUnknown`).
- **Interface (`SubtypeDecider`):** `{ name, decide(rep, a, b) -> Decision }`
  where `Decision = "sub" | "notsub" | "unknown"`. THREE-VALUED by contract:
  honest deferral, never fail-optimistic. The decider takes `rep` so it is
  representation-agnostic (DIP both ways).
- **Dual-engine admitted:** the contract admits BOTH proof backends
  (`decide_ssub` structural and `gdecide` semantic) — two independent impls
  cross-checked for parity. Built now: `structural.lua` (mirrors `decide_ssub`
  with the `subtype.v` atom base order, connective routing, arrow variance,
  record width; defers ref/anyref/tuple/neg as `unknown` — exactly the `gdecide`
  DUnknown cases). Reserved: the semantic `gdecide` backend, slotting in behind
  the same interface. `reflexive.lua` is a third, trivial backend proving the
  seam swaps.
- **Adding a rule stays local:** a new decidable shape = one arm in the decider
  impl; nothing else moves. Deferral is the safe default, so an unhandled shape
  is `unknown`, never wrong.

## Seam 3 — IR / AST (`ir.lua`)

- **Proof oracle:** `tm` de-Bruijn term + `step` (`typing.v:109`). The lowering
  target is the de-Bruijn core.
- **Interface (`IrNode`):** tagged de-Bruijn nodes (`lit/var/lam/app/let` now,
  mirroring the `tm` subset). The CANONICAL semantic identity is the de-Bruijn
  structure; source names ride in `names` as NON-SEMANTIC metadata for
  diagnostics. `var.index` 0 = innermost binder (`nth_error G n`).
- **Contract:** alpha-equivalent terms have identical IR up to `names` — renaming
  a binder never changes typing (`slice_test.lua` asserts this).
- **Adding a former stays local:** a constructor here + a `synth`/`check` arm.

## Seam 4 — Inference strategy (`infer/`)

- **Proof oracle:** `synth` / `check` (`check.v:187`), proven `synth_sound` /
  `check_sound` vs `has_type`, `synth_principal` (least type).
- **Interface (`Inference`):** `synth(caps, ctx, e)` and `check(caps, ctx, e, T)`,
  each returning `(Deriv | nil, Diag | nil)`. Bidirectional now.
- **CRITICAL — evidence is first-class (cannot be deferred):** every result
  carries a `Deriv = { node, type, rule, premises }` — the derivation tree naming
  which `has_type` rule fired over which premises. There is no consumer yet, but
  this is precisely what lets a certificate emitter be added later with ZERO
  re-engineering. Deferring it would force re-plumbing the whole engine.
- **Swap not precluded:** a constraint-based engine is a different module with the
  same `Inference` contract; `Caps` is injected, so consumers are untouched.
- **Adding a rule stays local:** one arm in `synth` (and its `Deriv`), citing the
  `has_type` constructor it implements.

## Seam 5 — Narrowing / facts (`facts.lua`)

- **Proof oracle:** truthiness narrowing `tifn` (increment 13) and type-test
  narrowing `ttypetest` (increment 15).
- **Interface (`Facts`):** immutable `empty` / `assume` / `lookup` over de-Bruijn
  places. Present but unexercised by the minimal slice (no conditionals yet); the
  seam exists so adding `tif`/`tifn` is a local change (a fact assumption at the
  binder + a synth arm).

## Seam 6 — Diagnostics (`diagnostics.lua`)

- **Proof oracle:** none (diagnostics are outside the proof).
- **Interface (`Diagnostics`):** `mismatch` (definite `notsub`), `unprovable`
  (honest `unknown` surfaced, not silently accepted), `make`. Errors are DATA,
  returned as `(nil, diag)`, never thrown.

## Seam 7 — Certificate emitter (`certificate.lua`)

- **Proof oracle:** the `synth`/`check` derivation DAG (`check.v`).
- **Interface (`CertEmitter`):** `{ name, emit(deriv) -> (Cert | nil, errmsg) }`.
  RESERVED; `noop` impl now (echoes the Deriv). A real emitter serializes the
  first-class `Deriv` into a content-addressed, replayable certificate — added
  HERE with no change to inference.

## Seam 8 — Parser → IR (`parser.lua`)

- **Proof oracle:** the lowering target `tm` (`typing.v`).
- **Interface (`Parser`):** `parse(src) -> SExpr`, `lower(rep, sexpr) -> IrNode`
  (resolves names to de-Bruijn, keeping names as metadata), `parse_type(rep, src)
  -> Ty`. A deliberately tiny Lisp-style surface; the frontend is swappable.

---

## Genuinely under-determined seam contracts (flagged, not invented)

These are open forks from the survey (§"Open design forks") that the SKELETON
does not resolve; it picks a minimal default and leaves the seam able to take the
other branch. Calling them out rather than hardcoding a choice:

1. **Three-valued vs two-valued public API.** The decider seam is three-valued
   internally (correct, matches `gdecide`). What the *top-level checker* should do
   with `unknown` — surface it (current: `subtype_unprovable`) vs first fall to a
   semantic backend before any verdict — is undecided. Current behavior surfaces
   it; the survey's lean is "try semantic backend first." Not resolved because the
   semantic backend is not built yet.
2. **Atom naming.** The skeleton uses lowercase atom names (`"int"`, `"num"`,
   `"float"`, `"str"`, `"bool"`, `"nil"`) mapping to the proof's `AInt/ANum/...`.
   This string-keyed atom table is a convention, not derived from the proof; if
   atoms grow, a non-string atom representation may be warranted.
3. **Certificate schema.** Reserved. The `Deriv` shape is fixed (first-class), but
   the serialized `Cert` format (content addressing, replay protocol — cf.
   v7_mr0) is undetermined and deliberately a no-op until the engine stabilizes.
4. **Context representation.** De-Bruijn context is a Lua array (last = index 0),
   O(n) functional extend. An interned/persistent context is a valid swap behind
   the same `Context` shape; not chosen because the slice does not need it.

These are recorded so a future increment fills the substrate, never papers over
it with a special case.
