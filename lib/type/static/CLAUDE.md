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
- function-type arms: `() -> %R` — **implemented** (match.lua, 2026-03-29). `() -> %R` with 0 params in the pattern matches ANY function (param count not constrained). R binds to single return type, or tuple for multi-return. `(A, B) -> %R` with explicit params still requires exact param count match. `(...%P) -> T` — **implemented** (2026-03-30). Rest capture in param position, binds all params as a tuple to P (enables `Parameters<F>`). `(A, ...%P) -> T` — **implemented** (2026-03-30). Concrete prefix/suffix params + rest capture, binds middle params as tuple to P (enables `Tail<F>`, `Init<F>`, `Last<F>`). At most one `...%P` per param list; may appear anywhere — evaluator matches concrete params from both ends, `...%P` captures the middle. Always produces a TAG_TUPLE (even for 0- or 1-element captures).
- spread-in-tuple-position: `(true, ...R)` — **implemented** (2026-03-30). `...R` in the last position of a tuple result expression splices R's elements. `R = integer` → `(true, integer)`. `R = (integer, string)` → `(true, integer, string)`. `R = never` (void fn) → `(true)`. Enabled `$PcallReturn` to be deleted and replaced by `PcallReturn<F> = match F { () -> %R => (true, ...R) | (false, string) }` in stdlib.d.lua. Implementation: env.lua TAG_TUPLE splice (preserves TAG_SPREAD when inner is TAG_VAR/TAG_NAMED for deferred evaluation); constrain.lua eager_slot unwraps TAG_SPREAD; narrow.lua propagate_multi_ret_narrowing unwraps TAG_SPREAD when extracting slots.
- indexer arms: `{ [%K]: %V }` — **implemented** (match.lua, 2026-03-29). Matches the table's indexer (one structural element). K = indexer key type, V = indexer value type. `{ ["foo"]: %V }` matches a named field. `{ [string]: %V }` matches a string-keyed indexer. No distribution — each pattern matches one structural element, consistent with `{ %X }` matching positional entry [1].
- all-fields pattern: `{ ...[%K]: %V }` — **implemented** (match.lua, 2026-03-30). **Per-field distribution**: the `...` means iteration, NOT rest/spread. For each field entry in the input, K and V are bound to that entry's key and value types, the result expression is evaluated, and results are unioned. This is the ONLY iteration mechanism in match syntax — it's the `...` in `{ ... }` applied to `[%K]: %V`. Named fields: K = integer literal for integer-named fields, string literal for string-named fields. Indexers: K/V are the indexer types. Empty closed table → never. Value types are widened. Enables `Keys<T>`, `Values<T>`, `PairsReturn<T>`, `IpairsReturn<T>` as pure library aliases. Does NOT expose optional/readonly flags — flag manipulation requires `$EachField`. **Design note**: `...` here is NOT consistent with expression-level `...` (rest/spread). It's a deliberate type-level-only overload for "iterate all fields." This is the one place where type syntax diverges from expression syntax.
- capture sigil: `%Name` — **implemented** (match.lua, ann.lua, defs.lua, constrain.lua, 2026-03-30). A name in a match pattern is a capture iff prefixed with `%`. Result expressions use bare names. No implicit unbound-name fallback. `_` is a wildcard (always matches, no binding). Bare names in pattern position are concrete type lookups (fail if not in scope). `TAG_CAPTURE(name_id)` vs `TAG_NAMED(name_id)` in pattern position. `() -> R =>` single-return position: TAG_NAMED is still treated as capture for backward compat (see match.lua special case). constrain.lua: `resolve_annotation_type` preserves TAG_CAPTURE (copies to checker arena).
- table-pattern rest capture: `{ field: %X, ...%Rest }` — **implemented** (ann.lua + match.lua + constrain.lua + defs.lua, 2026-03-30). `TAG_PAT_REST_FIELDS = 29`; field entry `name_id == -2` marks rest-capture in field lists. `...%Rest` in pattern captures remaining unmatched fields into a synthetic closed table; `...Rest` (TAG_SPREAD(TAG_NAMED)) in result position splices them back via existing substitute_inner mechanics. Used in `$EachField` F aliases to pass unchanged descriptor fields through without enumerating them. Note: brace-tuple result `{ { ...Rest } }` requires a separate grammar extension (nested table literals in brace-tuple position — not yet implemented); use flat descriptor `{ key: K, value: V?, ...Rest }` instead.
- meta-slot spread in table types: `{ #...T }` — **implemented** (ann.lua + constrain.lua + env.lua + types.lua, 2026-03-30). Spreads all meta slots from type T into the table. Represented as a meta field entry with `name_id == -1` holding a `TAG_SPREAD` node. `table_meta_field` in types.lua follows spread placeholders. `instantiate_inner` / `substitute_inner` in env.lua expand the spread when the inner type is a known TAG_TABLE, or keep the placeholder for deferred expansion. `resolve_annotation_type` eagerly expands spread when the inner type resolves to TAG_TABLE. Enables `setmetatable` to type as `<T, MT>(t: T, mt: MT) -> T & { #...MT }`.
- meta-spread capture pattern: `{ #...%M }` — **implemented** (ann.lua + match.lua + constrain.lua + defs.lua, 2026-03-30). `TAG_PAT_META_SPREAD = 30`; meta field entry with `name_id == -3` holding a `TAG_PAT_META_SPREAD` node. Pattern fails if the input has no meta slots. On success, binds the capture name to a synthetic closed table containing the input's named meta slots. `MetaOf<T> = match T { { #...%M } => M, _ => nil }` — enables typed `getmetatable`. Also fixed latent bug: `peek_callee_ret_union` now skips generic functions (returns nil if any param has FLAG_GENERIC), preventing the generic template return type from being used instead of the per-call-site instantiated one.

The permanent intrinsics are `$Require` (module system), `$Opaque`
(nominal identity), `$FfiC` (builds closed table from ffi.cdef call sites),
`$Throw` / `$Catch` (type-level error/pcall — diagnostic side effects, not
expressible as pure computation), and `$EachField` (per-field gather/map with
flag/descriptor access — complements `{ ...[%K]: %V }` but is not replaceable by it).

**`{ ...[%K]: %V }` vs `$EachField` — complementary primitives, not redundant:**
- `{ ...[%K]: %V }` — **distribution**: iterates fields, evaluates a result
  expression per field, unions results. For PairsReturn, Keys, Values.
  Does NOT expose optional/readonly flags. Result is a union, not a table.
- `$EachField<T, F>` — **per-field flatMap**: iterates fields, passes a full
  descriptor `{ key, value, optional, readonly }` to F (a **named alias passed
  unapplied** — no inline match expressions). F returns a **brace-tuple of
  descriptors**: `{}` drops the field, `{ D }` keeps/transforms it.
  Required for flag manipulation: `Partial<T>`, `Required<T>`, `Readonly<T>`.
  Cannot be replaced by distribution.

If you find yourself writing a new `$` intrinsic, stop and ask what
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

- Reflexivity: `T <: T` (algebra + grammar + deep)
- Union introduction: `A <: A | B` and `B <: A | B` (both orderings, algebra + grammar + deep)
- Union idempotent: `A | A <: A`
- Intersection elimination: `A & B <: A` and `A & B <: B` (algebra + deep)
- Intersection introduction: `T <: T & T` (algebra + deep)
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
- **Annotation soundness (positive)**: `(T)->T` identity body always typechecks (grammar)
- **Annotation soundness (negative)**: `(A)->B` body rejected when `A </: B` (grammar)
- **Narrowing precision**: after `if type(x) == "string"`, `x` is usable as `string` (grammar)
- **Generic constraint acceptance**: `<T: C>(T)->T` called with C value typechecks (grammar)
- **Generic constraint rejection**: `<T: C>(T)->T` called with non-C value is rejected (grammar)
- **Multi-return slot types**: `() -> (A, B)`; `x, y = f()` gives `x: A`, `y: B` (grammar)
- **Overload dispatch (acceptance)**: `(A)->nil & (B)->nil` called with A value typechecks (grammar)
- **Overload dispatch (rejection)**: `(A)->nil & (B)->nil` called with C (C not A, not B) is rejected (grammar)
- Performance gate: ≥500 programs/sec throughput

### Invariants not yet tested (each = a blind spot)

### Generator coverage

`fuzz_arb.lua` generates: base types, literals, nil, never, unknown, union,
intersection, function (single- and multi-return), record, indexer.

Not generated: `any`, type variables (`<T>`), `match` types, nominal/opaque
types, enum members, spread types, named aliases.

These are not covered because they require syntax or context the current
generator doesn't support — not because they're unimportant. `never` and
`unknown` are particularly valuable additions: `never` enables exhaustiveness
testing, `unknown` tests the narrowing-required boundary.

### Three levels of fuzz

- **`fuzz_alg.lua`** (algebra-level): constructs type IDs directly, no parsing.
  Runs 2000 trials per invariant. Fast. Tests the type algebra in isolation.
- **`fuzz_eval.lua`** (eval-level): fixed mini-programs with pre-declared type
  aliases. Tests type-level computation contracts: EachField, match, $Throw/$Catch,
  generic defaults, interface oracle, partial application. 500 trials for random
  invariants; fixed programs for deterministic ones. Uses `fuzz_eval_arb.lua` for
  table type string generation.
- **`fuzz_test.lua`** (grammar-level): parses annotation strings through the
  full pipeline. Runs 500 trials per invariant. Slower; exercises parsing,
  annotation handling, and constraint generation together.

All three must pass. See `docs/fuzz-gaps.md` for the full gap list.

**Annotation enforcement gotcha**: `local x --: T` does NOT enforce structural
field-level compatibility on assignment — it only narrows the variable's type.
To test that a type `T` structurally satisfies `U`, use a function return
annotation: `local function f() --: U ... end` where the body returns a `T`
value. This is why fuzz_eval.lua uses function return patterns for structural
equivalence assertions.

### Known generator limitations

- `sub_size = floor(size/2)` in `arb_type` bounds type depth to ~6 levels to
  prevent exponential string blowup. This may under-test deep
  intersection-of-union cases. A separate `arb_type_deep` using `size - 1` for
  the algebra suite (where no parsing is needed) would give better coverage
  there. See TODO.md.
- Deeply-nested types beyond MAX_TYPE_DEPTH (64) now produce a diagnostic
  ("type annotation too deeply nested") instead of a stack overflow. Grammar-level
  tests pre-check and skip these by testing for any error. Fixed 2026-03-29.
