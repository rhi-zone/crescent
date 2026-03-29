# lib/type/static — Typechecker

Rules specific to working on the static typechecker. The project-wide rules in
`/CLAUDE.md` still apply; this file adds or sharpens them for this directory.

## Before touching anything

**Read `docs/type-system.md` in full first.** Front-load the entire file into
context before making any change. Design decisions are written there. Don't
improvise from first principles — every session that has skipped this step has
caused a rewrite.

The typechecker has a formal semantics being built up in `docs/semantics.md`
(in progress). When that file covers the relevant construct, read it too.

## Solver rules (learned from rewrites)

**Never add a new predicate or special case to the solver.** The pattern is
always: does `prim_meta` / metamethod lookup handle this? If yes, use it. If
no, read the design doc before proceeding.

Violated once: `C_ARITH` was implemented with `is_numeric_tid` /
`is_int_compat_tid` predicates instead of the `prim_meta` dispatch prescribed
by Principle 10. The fix required a full rewrite. The predicate approach feels
simpler but it diverges from the metamethod model and silently breaks edge
cases. Principle 10 exists for a reason.

**No new `$`-prefixed intrinsics.** The `$` sigil marks type operations that
need compiler support because `match` arm patterns don't yet cover them. Adding
a new `$Whatever` is wrong — the right answer is to extend `match` patterns so
the operation becomes user-definable. Current `$`-prefixed types are
provisional and will be eliminated as `match` gains:
- function-type arms: `(...) -> R` — not yet implemented
- indexer arms: `{ [K]: V }` — **implemented** (match.lua, 2026-03-29). Binds K → indexer key type, V → indexer value type. Alias-param substitution happens before match evaluation, so T in result expressions is already concrete. `$PairsReturn<{ [string]: integer }>` CAN be expressed as a match alias for indexer tables. Full replacement of `$PairsReturn`/`$IpairsReturn`/`$Keys` needs named-field fallback arms (K=string, V=union of all field values) which requires either `$EachField`-level iteration or a dedicated pattern — not yet possible.

The only permanent intrinsics are `$Require` (module system), `$Opaque`
(nominal identity), and `$FfiC` (builds closed table from ffi.cdef call
sites). If you find yourself writing a new `$` intrinsic, stop and ask what
`match` pattern is missing instead.

## Performance bar

The typechecker must be competitive with `@typescript/native-preview` (tsgo /
ts7 — the Go rewrite of tsc). Benchmark methodology:

- A representative "nice" TypeScript program vs a structurally similar Lua
  program: cold-start + incremental throughput.
- Pathological Lua cases: deep union chains, heavily generic code, large files.
  These stress the solver in ways that have no TS equivalent.

If a LuaJIT implementation is not within striking distance on the same
workload, that is a signal to reconsider the design — not to accept the gap.
Benchmark before shipping. Record results in `docs/perf/log.md`.

## Fuzz suite

**The fuzz suite is a spec-oracle, not a coverage tool.**

`fuzz_test.lua` and `fuzz_alg.lua` check mathematical invariants of the type
system — properties that must hold for *all* types, derived from type theory,
not from the implementation. The implementation is currently the de-facto spec,
which means it encodes its own bugs. The fuzz suite's job is to be an
independent ground truth that catches violations regardless of how the
implementation works.

**Each missing invariant is a permanent blind spot for unknown bugs.** A bug
that only violates an untested invariant can live in the codebase forever,
surviving every refactor, because no test exercises the property it breaks. The
intersection/union ordering bug found in 2026-03 was caught because it happened
to violate reflexivity and union intro. A bug that only violated transitivity
would have gone completely undetected.

**When fixing a bug, add the invariant that would have caught it.** The fix
without the invariant just moves the bug class from "known" to "unknown again
after the next refactor."

### Invariants currently tested

- Reflexivity: `T <: T` (algebra + grammar)
- Union introduction: `A <: A | B` and `B <: A | B` (both orderings)
- Union idempotent: `A | A <: A`
- Intersection elimination: `A & B <: A` and `A & B <: B`
- Intersection introduction: `T <: T & T`
- Optional: `T <: T | nil` and `nil <: T | nil`
- Transitivity: `A <: A|B` and `A|B <: A|B|C` implies `A <: A|B|C` (via union chain)
- Literal subtyping: `lit_int <: integer`, `lit_int <: number`, `lit_str <: string`, `lit_bool <: boolean`
- Literal asymmetry: `lit_int(n) <: integer` but `integer </: lit_int(n)`
- Function covariant return: `(A)->C <: (A)->(C|B)` (algebra + grammar)
- Function contravariant param: `(A|B)->C <: (A)->C`
- Function: correct arg accepted, wrong arg rejected (grammar)
- Narrowing: `if x then` excludes nil (grammar)
- Literal precision: `42` has type `42`, not just `integer` (grammar)
- Generic instantiation: `<T>(T) -> T` preserves type (grammar)
- Performance gate: ≥500 programs/sec throughput

### Invariants not yet tested (each = a blind spot)

- **Annotation soundness**: a function body accepted under return type `T` cannot produce non-`T`
- **Narrowing precision**: after `if type(x) == "string"`, `x` is exactly `string`, not a supertype
- **Overload dispatch**: calling an intersection of function types routes to the correct member
- **Generic constraint checking**: `<T: Constraint>` rejects violating instantiations
- **Multi-return subtyping**: slot N of a multi-return is the declared type; extra slots are nil

### Generator coverage

`fuzz_arb.lua` generates: base types, literals, nil, never, unknown, union,
intersection, function (single- and multi-return), record, indexer.

Not generated: `any`, type variables (`<T>`), `match` types, nominal/opaque
types, enum members, spread types, named aliases.

These are not covered because they require syntax or context the current
generator doesn't support — not because they're unimportant. `never` and
`unknown` are particularly valuable additions: `never` enables exhaustiveness
testing, `unknown` tests the narrowing-required boundary.

### Two levels of fuzz

- **`fuzz_alg.lua`** (algebra-level): constructs type IDs directly, no parsing.
  Runs 2000 trials per invariant. Fast. Tests the type algebra in isolation.
- **`fuzz_test.lua`** (grammar-level): parses annotation strings through the
  full pipeline. Runs 500 trials per invariant. Slower; exercises parsing,
  annotation handling, and constraint generation together.

Both must pass. The algebra suite tests structural properties that should hold
regardless of how types are parsed. The grammar suite tests end-to-end
correctness including the pipeline before the solver.

### Known generator limitations

- `sub_size = floor(size/2)` in `arb_type` bounds type depth to ~6 levels to
  prevent exponential string blowup. This may under-test deep
  intersection-of-union cases. A separate `arb_type_deep` using `size - 1` for
  the algebra suite (where no parsing is needed) would give better coverage
  there. See TODO.md.
- Deeply-nested types (depth >~30) trigger a parser stack overflow, producing
  nil-message errors. Grammar-level tests pre-check and skip these. This is a
  parser bug, not a generator design choice. See TODO.md.
