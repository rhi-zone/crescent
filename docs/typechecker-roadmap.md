# Typechecker Roadmap

Two parallel tracks:

1. **V4 cutover track (K-series)** — finishing the AST walker rework, reaching
   parity with the legacy typechecker, and retiring `lib/type/static/`.
2. **Type-system power track (A/B-series)** — closing the soundness and
   expressiveness gaps that back (or narrow) the CLAUDE.md claim
   ("safer than Rust and more powerful than Haskell").

The two tracks interact at the edges (K6 parity work will surface power-track
items as concrete bugs) but are otherwise independent. The V4 track is more
urgent because every session that touches the typechecker is currently
maintaining two implementations; collapsing that is high leverage.

See `TODO-typecheck.md` for the full per-item checklist with commit hashes.
This document is the prioritization/ordering view.

---

## Near future (next 1–2 sessions)

The V4 walker is feature-complete through sub-phases A–J. CLI integration
(`bin/cr check --v4`) and `--summary` rendering are in place. Stdlib types
are live (K3). What's blocking declaring parity is **knowing where the
divergences are**.

### N1. K5b — `--compare` mode

Single flag that runs both legacy and v4 on the same file and reports
divergences (missing errors, extra errors, different categories at the same
source position). Output should be diff-shaped, not interleaved, so K6 can
script over it.

This is small (a few hundred lines) and unblocks everything downstream.

### N2. Parametric aliases walker hook

K3 stored `Arr<T>`, `Ptr<T>`, etc. as Lua functions in `parametric_aliases`,
but the walker has no hook to call them when users write `Arr<T>` in an
annotation. Without this, the existing test corpus cannot run under v4 —
many tests use `Arr<T>` syntax. Highest-leverage walker-limitation fix
before K6.

### N3. K6 — Parity discovery pass

Once N1 + N2 land, run `bin/cr check --v4 --compare` across `lib/**/*.lua`.
Expected outcomes per file:

- **Identical** — no action.
- **V4 has fewer errors** — usually means v4 is missing a check. Fix v4.
- **V4 has more errors** — usually means v4 is correctly stricter (legacy
  had a soundness gap). Document as intentional divergence.
- **Different categories** — per-case judgment.

This is multi-step and likely spans multiple sessions. **Decision point:
the user must approve each "intentional divergence" classification** —
these are the cases where v4 is intentionally stricter than legacy and
existing user code will start failing on the cutover.

---

## Mid future (after parity is mostly met)

### M1. K7 — Cutover

When v4 reaches the parity threshold defined in the driver design doc §10
gates, `lib/type/static-v4/` becomes `lib/type/static/` and the old impl is
retired in the same commit. Cutover is conditional on K6 closure: do not
attempt until the divergence list has been resolved or explicitly
documented.

### M2. Walker-limitation cleanup (in K6 order)

The "Walker limitations surfaced" list in `TODO-typecheck.md` orders these
by parity impact, not by intrinsic difficulty. Likely order:

- `$PatternReturn<P>` / `$FindReturn<P>` walker hook (blocks many stdlib
  call-sites).
- Non-empty table literals (currently rejects loudly).
- Chained indexed-LHS `a.b.c = ...`.
- Vararg-in-return position.
- Annotation parser bridge for `ann.lua` → V4Type (so users can write
  annotations against v4 directly).
- Effect-annotation parsing in `ann.lua` (`(A) -[yield]-> B`).
- Spread-fn-result encoding (`...V` result form) — currently degrades to
  `...unknown`.

Each is sized small-to-medium. Order opportunistically by which one is
blocking the next K6 file.

### M3. Test corpus migration

Port `type_test.lua` and `type_soundness_test.lua` to v4. Bundled with K6 in
practice — every divergence that's "fix v4" produces a pinned test in this
corpus.

### M4. D-series cleanup

- D1 follow-up flow-sensitivity audit (function-body fix landed; top-level
  flow check still suspect).
- Fourth cross-file `--::` resolution case (env.lua direct-consumer trap).
- TAG_SPREAD test revision per D4 (test expected a now-incorrect error).
- PRIM_CACHE / TV bound-graph interaction audit.

These are not blocking K7 but should be cleared while the typechecker is
still hot in context.

---

## Far future

These items survive after V4 is the only implementation. They are the
type-system *power* track and are independent of the cutover. They were
previously the body of this roadmap (Phases A/B/C); A1/A2 landed, the rest
remain.

### F1. Higher-kinded types (was B1)

The single biggest deficit vs. Haskell. Blocks every functor/monad/
traversable-shaped abstraction. `<F: SomeGeneric>` parses but does not
compose — `F` is treated as a type variable, not a type constructor.

Highest power-track leverage; if only one power axis is closed, this is the
one.

### F2. Effect tracking (was B2)

`docs/effects.md` is a design exploration, currently Level 0.5 (deferred).
Async / coroutines are `any` today. Finishing this would put crescent
**ahead of mainstream Haskell** on a recognized axis. Walker H landed the
yield/throw/pcall plumbing; the missing piece is the full effect-row
inference.

### F3. V.intrinsic constructor

K3 wanted `V.intrinsic(name, args)` for `$Throw`, `$EachField`, etc. Not in
v4 core today. Surfaces as ad-hoc dispatch in the walker; consolidating
into a first-class form would clean that up. Medium-sized refactor.

### F4. Lazy match evaluation

`V.match(V.var("T"), arms)` evaluates eagerly and suspends on free vars
instead of producing a parametric value. Blocks several pattern-driven
designs.

### F5. Performance work

`docs/perf/log.md` is the system of record. Walker hot paths haven't been
benchmarked end-to-end since K1 landed. After K7, baseline the full
typecheck, then attack the dominant cost. Performance bar per CLAUDE.md is
"tsgo for the typechecker" — currently far from it.

### F6. Variance (was A.5)

Demoted from soundness to expressiveness after the variance audit
(`docs/typechecker-variance.md`). Implement when a user writes the first
heavily-generic library that wants `ReadOnlyMap`-style types. Design
committed; implementation deferred. Not blocking anything.

### F7. Impredicativity (was B3)

Instantiating a type variable with a polymorphic type. May fall partially
out of A1 done right (QuickLook-style). Revisit after F1.

### F8. GADT-strength flow typing (was B4)

Match types cover part of this. The gap is type-variable equations exposed
by discriminant narrowing. Narrower use cases than F1/F2.

### F9. Refinement types (was B5)

Predicate subtyping (`{x: number | x > 0}`). LiquidHaskell territory. Only
justified if the project explicitly wants that mantle.

### Non-goals

- Linear / affine types — Lua table semantics make linearity ill-fitting.
- Dependent types in the Idris/Lean sense — out of scope.
- Removing structural subtyping in favor of nominal — structural is one of
  the wins, deliberately preserved.

---

## Cross-cutting

Items that aren't on either track but matter:

- **`ann.lua` is its own thing.** Parser idiosyncrasies are done (commits
  `e077ae18`, `7df7de27`, `b090e84d`); the next `ann.lua` work is the
  annotation-parser bridge (mid-future M2) plus effect-annotation parsing.
- **Per-file error cleanup queue.** Tracked in the body of
  `TODO-typecheck.md`. Independent of the K-track; workers can pick from
  the queue at any time. The cleanup queue does *not* gate K7 — cutover is
  about implementation parity, not annotated-code error count.
- **CLAUDE.md doc honesty.** The "safer than Rust and more powerful than
  Haskell" claim is currently underwritten by A1/A2 (landed) plus row
  polymorphism, match types, and discriminated unions. Until F1 (HKT)
  lands, the claim is overstated on the power axis. Narrow or fund.

---

## Decision points

Cases where the user needs to make calls (not session-internal):

- **Each K6 divergence** — when v4 is intentionally stricter, the user
  decides whether to accept the resulting downstream churn or relax v4.
- **K7 cutover gate** — driver design doc §10 lists the gates; the user
  signs off when they read as met.
- **CLAUDE.md claim wording** — when to narrow vs. when to leave standing
  pending F1.
- **F1 (HKT) priority vs. M-track cleanup** — power vs. polish. Default is
  polish first (M-track) so the cutover is clean; the user can flip this.

---

## Order of work (proposed)

V4 track: **K5b → parametric aliases hook → K6 (multi-session) → M-track
cleanup → K7 cutover.**

Power track (runs independently, lower priority unless explicitly elevated):
**F1 → F2 → F3 → F4 → F5 (perf) → F6 → F7 → F8 → F9.**

Rationale: the V4 track collapses two-implementation maintenance, which
compounds over every future session. Power-track items add capability but
don't reduce the cost of every subsequent typechecker change the way K7
does.
