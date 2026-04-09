# TODO

## CRITICAL: fuzz the typechecker against the full type system spec as invariants

**Prerequisite: typechecker must be in a non-broken state before starting.**

The test suite tests behaviors, not invariants. The invariants must encode the **spirit** of the type system from first principles — not mirror the implementation, which is likely wrong in places.

The full type system expressed as invariants (not exhaustive, but the spirit):
- **Subtyping**: if `A <: B`, every program that typechecks with a value of type B must also typecheck with a value of type A in its place
- **Union introduction**: a value of type A is assignable to `A | B`; a value of type B is assignable to `A | B`
- **Union elimination**: code that handles both A and B handles `A | B`
- **Intersection**: a value of type `A & B` is usable as both A and B independently
- **Function**: calling `(A) -> B` with a value of type A always produces a value of type B; calling with a non-A is always rejected
- **Narrowing**: after a nil check on `T | nil`, the type in the non-nil branch is `T`; `T` is a subtype of the original
- **Annotation soundness**: a function whose body is accepted with return type `T` annotation cannot produce a value outside `T`
- **Multi-return**: slot N of a multi-return must be the declared type for that slot; extra slots are nil

Every feature needs its own invariant class:
- **Spread multi-return**: slot extraction, narrowing propagation across slots, spread in argument position
- **HKTs**: applying a type constructor to a type argument produces the correct instantiation; HKT + generic constraints compose correctly
- **Every intrinsic** — full list, each with its own contract. Type-level intrinsics: `$Keys<T>` (union of string literal field names), `$EachField<T, F>` (maps F over each field), `$EachUnion<T, F>` (maps F over each union arm), `$Opaque<T>` / `$Opaque<T, U>` (nominal newtype with optional exposed view), `$FfiC` (closed table from ffi.cdef calls), `$GlobalScope` (closed table of declared globals), `$Name` (string literal of declaration name), `$Require<T>` (module type from string literal).
  - **Note: builtins must not be special-cased.** `require`, `pcall`/`xpcall`, `pairs`/`ipairs`, `type()`, `assert`, `error`, `select`, and stdlib functions like `string.find`/`io.open`/`string.byte` are currently hardcoded in constrain.lua. Each special case is a missing type system feature — the goal is to eliminate all of them by making stdlib.d.lua declarations expressive enough. The fuzz suite should verify each builtin's contract holds AND that the contract is expressible without special-casing. Removing a special case and replacing it with a stdlib.d.lua declaration is a correctness win, not just cleanup.
- **Match/narrowing patterns**: `if type(x) == "string"`, `if x then`, `if not x`, `if x == nil`, `and`/`or` chains — each must narrow to exactly what the spec says, no more, no less
- **Generic constraints**: a generic `<T: Constraint>` rejects instantiations that violate the constraint; accepts all that satisfy it
- **Literal types**: `1` is assignable to `integer` and `1` but not `2`; literal widening is explicit not implicit
- **Generic constraints on HKTs**: `<F: Functor>` where F is itself a type constructor — fmap must typecheck correctly for any valid F

Use `lib/test/fuzz.lua` + `lib/test/arb.lua` to generate programs and assert these invariants hold across random inputs. Fuzz targets derived from the spec, not the implementation.

**Performance**: include a benchmark gate — if typechecking throughput on a fixed corpus regresses beyond a threshold, the fuzz suite should flag it. The typechecker has a performance bar and regressions are as bad as correctness failures.

The bar to beat is `@typescript/native-preview` (tsgo / ts7 — the Go rewrite of tsc). Benchmark methodology: construct a representative "nice" TypeScript program and a structurally similar Lua program, compare cold-start + incremental throughput. Also include pathological Lua cases (deep union chains, heavily generic code, large files) that have no TS equivalent — these stress the solver and expose regressions invisible in the nice-program comparison.

**Performance note on multi-return redesign**: always wrapping rl=0 and rl=1 returns in TAG_TUPLE adds allocation + C_INDEX destructuring overhead on every call site. We may want to re-specialize these cases (bind directly, skip the tuple barrier) after measuring. Don't assume the overhead is acceptable — benchmark first.

## ~~CRITICAL: write docs/semantics.md~~ DONE (8ec327c)

`docs/semantics.md` now covers: all type tags + data layouts, the complete
subtyping relation (19 cases), expression typing rules, the constraint solver,
narrowing, annotation syntax, invariants (incl. untested blind spots), and
intrinsic contracts. Read it before touching typechecker internals.

## CRITICAL: write implementer specs before delegating

Each item below needs a self-contained spec in `docs/` (or inline in TODO) that a subagent can implement from without reading session history. Design decisions scattered across TODO.md + docs/type-system.md + session notes are not enough — an implementer needs: what to build, what files to touch, what the data representation is, what tests to write.

Items that currently lack an implementer-ready spec:
- [x] **TAG_SPREAD in return position** — spec written: `docs/tag-spread-spec.md`. Ready to delegate.
- [x] **`$Opaque<T, U>` two-arg form** — implemented (ae91a98). Fields in U accessible; fields not in U error; one-arg opaque field access errors. `ctx._opaque_nominals` + `ctx._opaque_view` side tables.
- [x] **`--:: unseal`** — implemented (6805930). Rebinds opaque variable to inner type T from declaration point forward. Line-by-line application in gen_block; block scoping via child scope; rejects newtype nominals.
- [x] **Argument literal widening at typevar binding** — was already handled by `widen_for_sub` in `solve_callable`. Clarified with explicit `widen_literal` helper + comments + 10 tests confirming the behavior (ad58bc6).
- [x] **GAP-HKT3 fix: `$Opaque` keys in lib/fp/** — applied to all 10 typeclass modules + 9 instance modules. `fa[Mappable.key]` now resolves via FLAG_OPAQUE_KEY. (2026-03-29, 839610f)
- [x] **`$Require<T>` as parameterized intrinsic** — implemented (9d92308). `expand_require` in intrinsic.lua; `resolve_deferred_intrinsic` in solve.lua evaluates TAG_TYPE_CALL on TAG_INTRINSIC callees after arg solving. Module declaration processing moved to pass 0. constrain.lua special case preserved pending full de-specialcase.
- [ ] **De-specialcase builtins** — `require` (f468b72), `pcall`/`xpcall` (d7950de), `pairs`/`ipairs` (d7950de) done. All stdlib tables (string/table/math/io/os/coroutine/debug + primitive meta types) now declared in stdlib.d.lua (33640d0). Remaining special-casing: `type()` narrowing in narrow.lua (justified, can stay), `require()` side effects in constrain.lua (architectural). Still too-loose: `select()` (needs overloads or literal matching), `string.match`/`gmatch`/`gsub` (need pattern introspection). `assert` and `error` are clean.
- [x] **Eliminate intrinsics via `match` arm patterns** — MOSTLY DONE. Function-type arms, indexer arms, spread-in-tuple-position, all-fields pattern, and capture sigil all implemented (2026-03-29–30). `$PcallReturn`, `$PairsReturn`, `$IpairsReturn`, `$Keys`, `$Values`, `$IpairsValues` all deleted and replaced with pure match aliases in stdlib.d.lua.
  **Remaining intrinsics (permanent or blocked):**
  - `$Require<T>` — permanent; module system, needs literal type propagation through generics
  - `$Opaque<T>` — permanent; nominal identity
  - `$FfiC` — permanent; builds closed table from ffi.cdef call sites
  - `$EachField<T, F>` — blocked on HKT application in result position. F is a type constructor (`* -> *`); `$EachField` calls `F(field_descriptor)` per field. Match types can destructure but can't apply an arbitrary type constructor parameter. Eliminating this requires higher-kinded type application, not more match patterns.
  - `$GlobalScope` — undocumented; used for typing `_G`. Document or replace.
- [x] **Invariant-based fuzz suite** — implemented (e3d5f96): `lib/type/static/fuzz_test.lua` + `fuzz_arb.lua`. 6 invariants + performance gate (≥500 programs/sec).
- [ ] **Fuzz suite gaps** — comprehensive gap list at `docs/fuzz-gaps.md`. Three tiers: algebra (A1–A4), eval (E1–E11, some need G1 generator), grammar (P1–P5). Implementation order listed in doc. Items A1–A2 and E1/E6/E7 are ready to implement now; G1+E5 require new function-type generator.
- [x] **Parser stack overflow on deeply-nested types** — fixed (5150a5a, 2026-03-29): added depth counter to scanner; parse_type fires "too deeply nested" diagnostic at depth>64 (MAX_TYPE_DEPTH). depth_limit_hit flag distinguishes this from silenced syntax errors. fuzz_test.lua pre-check skips these cleanly.
- [x] **fuzz_arb.lua sub_size halving reduces deep-type coverage** — added `M.arb_type_deep` (2026-03-29): uses `sub_size = min(size-1, 8)` for deeper trees, capped at 8 to prevent 2^N blowup. Used in fuzz_alg.lua invariants 15-18 (deep reflexivity, deep union intro, deep inter elim, deep intersection intro). Grammar-level tests still use halved arb_type (must parse strings).
- [x] **`pcall`/`xpcall` de-specialcase** — implemented (d7950de): `$PcallReturn<F>` intrinsic.
- [x] **`pairs`/`ipairs` de-specialcase** — implemented (d7950de): `$PairsReturn<T>`/`$IpairsReturn<T>` intrinsics.
- [x] **Self-check regression: constrain.lua 60 errors** — fixed (5c23738): `--:` annotations added across constrain.lua, narrow.lua, check.lua, solve.lua, lsp.lua, ctx.d.lua, type_soundness_test.lua. All now self-check at 0 errors.
- [x] **Self-check: match.lua annotation pass** — fixed (6740aeb, 2026-03-30): added Ctx type to function signatures; --: integer for lists/fields:get(); --: any for merge_bindings. 0 errors, 6 intentional any warnings.

## typechecker soundness gaps (found by type_soundness_test.lua)

- [x] **`unknown` was not strict** — `TAG_UNKNOWN` was behaving like `TAG_ANY`: field access, calls, and arithmetic silently passed through. Fixed in solve.lua: all three now emit errors. `unknown` requires narrowing first.
- [x] **Coinductive cycle detection in unify.lua** — `lib/fp/maybe` and `lib/fp/either` caused stack overflow during typechecking. Fixed by adding `seen` parameter with `copy_seen()` for disjunctive iterations.
- [x] **`match` type adversarial coverage** — non-exhaustive match on union, wrong arm result type downstream, unreachable arm, match on `never` → `never`, nested match types (concrete inner args), and `--:: module` declaration / require basic coverage all tested. Note: unreachable arm does not warn (no diagnostic emitted).
- [x] **Typechecker: nested match typevar not forwarded to inner type call** — fixed (85c92d6). Root cause: `substitute_inner`'s TAG_MATCH_TYPE handler didn't defer when subject was TAG_NAMED (only deferred for TAG_VAR/TAG_ROWVAR). Fix: added TAG_NAMED to the deferred-evaluation guard in env.lua.

- [x] **Soundness gap: optional field not rejected in required position** — `{ x?: T }` is currently accepted where `{ x: T }` (required) is expected. `unify.lua` skips source fields that are absent but does not check FLAG_OPTIONAL on *source* fields vs required target. `{ x?: T } </: { x: T }` should fail. Found while adding fuzz_eval.lua invariants (2026-03-30).

- [x] **Field access on nil/boolean** — fixed f1a9882
- [x] **Annotation on M.field assignment not enforced** — fixed 08fd6a4
- [x] **`and` RHS not narrowed** — fixed 11cf377
- [x] **Readonly not enforced through intersection** — fixed 0b40861
- [x] **Literal table not assignable to indexer type** — fixed 0b40861
- [x] **Missing return detection** — fixed; `is_definitely_returning` analysis in constrain.lua emits implicit nil C_RETURN for non-definitely-returning annotated functions.

## typechecker match semantics gaps

- [ ] **`Parameters<typeof f>` captures only first param** — `Parameters<F> = match F { (...%P) -> %R => P }` gives `integer` instead of `(integer, string)` when F = `typeof f` and f: `(integer, string) -> boolean`. `(...%P)` rest capture in function patterns should bind P to a tuple of all params. Broken specifically when the function type comes from `typeof` (i.e. the concrete function type is available at match time). Tracked by fuzz_test.lua P2a/P2b (pre-existing failure).

- [x] **Intersection types are opaque in match arms** — FIXED properly (521226a). DNF normalization in `M.evaluate`: `to_dnf` expands `A|(B&C)` and `A&(B|C)` into terms; each term dispatched independently. For pure-table intersections, `flatten_to_table` merges all member fields into one TAG_TABLE so structural patterns see all fields. Band-aid (0ace6b0) replaced.

## typechecker missing features

- [x] **Record spread types** — `{ ...T, k: V }`, `{ ...T, ...U }`, `{ k: V, ...T }` as type-level operations. Unification added (33640d0): unify.lua checks spread fields by expanding inner TAG_TABLE and verifying each required field exists in the actual. Gap: **spread-union distribution** — when the spread inner type is a TAG_UNION (`{ ...(A | B), k: V }`), env.lua `substitute_inner` keeps a placeholder instead of distributing. Correct fix: distribute over union members in `env.lua:substitute_inner`, then handle in `solve.lua` field lookup and unify.lua. Needed for builder pattern and mapped-type aliases instantiated with union types.

## typechecker stdlib / module typing

- [x] **`module "name": T` syntax** — `--:: module "name": T` declares the type returned by `require("name")`. Implemented in ann.lua (ANN_MODULE), constrain.lua (module_types registry), prelude.lua (loaded from .d.lua files). Undeclared modules → `unknown`. stdlib.d.lua now declares `"ffi"` and `"bit"` properly.
- [ ] **`$Require<Path>` intrinsic** — `require()` is currently special-cased in constrain.lua: when the arg is a string literal, it does the `ctx.module_types` lookup inline. The aspirational form `--:: declare require: <T: string>(module: T): $Require<T>` needs two features not yet implemented:
  1. **Literal type propagation through generics** — calling `require("lib.json")` must bind `T` to `LIT_STRING "lib.json"`, not widened `string`. This is in tension with the argument-widening rule (literals widen to base type at call sites to avoid pinning typevars). The intrinsic doesn't need a special bound — `$Require<T>` evaluates to `module_types[T.literal_value]` if T resolved to a string literal, else `unknown`. The constraint `<T: string>` means "T must be assignable to string" (same semantics as TS `extends string`) — not "must be a literal", which is the bound's correct meaning and is already enforced by C_BOUND.
  2. **Parameterized intrinsics** — `$Require<T>` where `T` is a type variable, resolvable only when T is a bound literal. `resolve_named_type` currently only handles TAG_NAMED (concrete names), not TAG_TYPE_CALL on type variables.
  Until both are done, `require()` stays special-cased. Milestone: `--:: declare require: <T: string>(module: T): $Require<T>` in stdlib.d.lua typechecks and produces correct module types.
- [x] **`$FfiC` intrinsic** — implemented. `TAG_FFIC = 26`, deferred resolution in solve.lua, cdef.lua makes `T_FFI_C` closed (undeclared C symbols error), stdlib.d.lua declares `C: $FfiC`.

## stdlib.d.lua coverage gaps (audit 2026-04-01)

- [x] **Over-broad `any` return types** — PARTIALLY FIXED (06c6b38). Tightened 7: `coroutine.status` (literal union), `string.gmatch` (`function`), `table.remove` (`any | nil`), `coroutine.create`/`wrap`/`resume`/`yield` (function params + multi-return). Remaining:
  - `assert` → needs `typeof(val)` (type-level computation)
  - `string.match` → needs pattern-dependent captures
  - `os.date` → format-dependent return (`string | { [string]: integer }`)
  - `io.open` / `io.popen` → needs file handle opaque type
  - Parser limitation: function types in table field return positions break the annotation parser silently
- [x] **Missing stdlib functions** — FIXED (819179f). Added `io.flush`/`input`/`output` + 8 `ffi.*` functions. Remaining:
  - `os.setlocale` (low)
  - `debug.getupvalue`, `debug.setupvalue` (low)
- [ ] **`$GlobalScope` intrinsic undocumented** — used in stdlib.d.lua but not listed as a permanent intrinsic in CLAUDE.md. Document or replace.

## typechecker type guards and assertions

TypeScript's type guards can lie — `function isString(x): x is string { return true }` typechecks fine. We should do better.

- [x] **User-defined type guards** — implemented (0e3be6f, 2026-03-30). `(x: unknown) -> x is T` return type: ann.lua parses the predicate, stores in pool._type_predicates; narrow.lua `guard_check` kind narrows the argument at call sites (truthy/falsy/negated). Body return type is enforced as boolean.

- [x] **Assertion functions** — implemented (6740aeb, 2026-03-30): `(x: T) -> asserts x is GuardType` parses in ann.lua, unconditional scope narrowing in StmtRule[NODE_EXPR_STMT]. Also fixed latent bug: predicate IDs now propagated from annotation arena to ctx.types arena.

- [ ] **Verified type guards** — rather than trusting the annotation, verify that the function body actually performs checks consistent with the declared predicate. If the body provably returns true for non-T values, emit a warning. This is beyond TS — TS never verifies guards, it just trusts them. Even partial verification (detecting trivially lying guards) would be a win.

- [x] **Predicate narrowing from `type()` calls** — implemented in `narrow.lua` (extract_narrowing detects `type(x) == "string"` pattern; apply_narrowing filters union members). All forms: `type(x) == "string"`, `type(x) ~= "string"`, multi-branch, `any`, `unknown`.

- [x] **`assert()` as a built-in assertion** — `assert(x)` and `assert(x, msg)` both narrow `x` to non-nil/non-false in the continuation.

## typechecker warnings / quality-of-life

- [x] **Redundant type assertion warning** — implemented. `NODE_CAST_EXPR` emits a warning when a `--[[: T]]` cast asserts a structurally identical type; excludes `any` on either side.
- [x] **Error message quoting audit** — fixed in `unify.lua` (2026-03-30): 8 error strings used single quotes around type names; converted to backtick style. All type names in error messages now use backticks.

## typechecker narrowing gaps

- [ ] **Optional field narrowing** — `if opts.f then opts.f(x) end` does not narrow `opts.f` to non-nil for the call. The second field read is checked independently and still returns the union type. Workaround: extract to a local first (`local f = opts.f; if f then f(x) end`) — but this only works if the local is assigned before the check, not from a call return.
- [x] **`ffi.C` typed from file-local cdefs** — implemented via `$FfiC`. `ffi.C` resolves to `ctx.T_FFI_C`, a closed table accumulated from `ffi.cdef(...)` calls in the file. Undeclared C symbols are errors.
- [ ] **lib/ljsocket type declarations** — `lib/ljsocket` has no `--::` crescent annotations. Any library that uses ljsocket objects (lib/socket, lib/tcp, lib/websocket, lib/https) cannot be fully typechecked. Fix: add `--:: luajitsocket = { ... }` declarations to `lib/ljsocket/init.lua`.
- [ ] **Narrowing doesn't apply to locals assigned from function call returns** — at narrowing time during constraint generation, locals assigned from function calls are still TAG_VAR (unsolved constraint variables). `types.subtract(TAG_VAR, T_NIL)` returns TAG_VAR unchanged. Workaround: add `--: T | nil` annotation to the receiving local so it gets a concrete type. Affects all `if not x then return end` patterns where `x` comes from a function call.
  **Architecture investigation (2026-04-01):** Flow typing is not inference — separate concerns. Current narrowing is cleanly split: `extract_narrowing` (structural, pure) and `apply_narrowing` (type transformation). The multi-return mechanism (`propagate_multi_ret_narrowing`) already works as a post-solve pattern. Separation is feasible — narrowing is a scope-binding side effect, not core constraint logic.
  **Complication:** constraints from narrowed scopes reference the un-narrowed TAG_VAR. After solving, `?A = string | nil`. If narrowing would have given `string`, the constraint `?A:upper()` fails against `string | nil` but would have succeeded against `string`. This is NOT just conservative — it produces false errors. Constraints from narrowed scopes need the narrowed type, not the original.
  **Options:** (a) defer constraint generation inside narrowed scopes until after solving + narrowing — re-walk those AST nodes with concrete narrowed types. Closest to a clean two-pass but requires tracking which AST regions to re-process. (b) Emit constraints against TAG_VAR as now, post-solve apply narrowing, then re-verify only the constraints that reference narrowed variables. (c) Make narrowing a solver-integrated operation: when the solver resolves a TAG_VAR that has a pending narrowing, immediately apply the narrowing and update the scope binding before evaluating dependent constraints.
  **Current status:** needs design decision on which option before implementation.
- [x] **`or` condition narrowing overwrites previous narrowing for same variable** — `if not x or x == 0 then return end` failed to narrow `x` because the second `record_narrowing` call overwrote the first. Fixed: `record_narrowing` now chains through `narrowed[name_id]`.
- [x] **Multi-return annotation on single-var capture** — fixed in solve_sub: when actual is TAG_TUPLE and expected is scalar, project first element. Annotated `local x --: string; x = f()` where f returns (string, number) now type-checks correctly.
- [x] **Multi-return aliased-call narrowing** — `local find = string.find; local s, e = find(...)` didn't narrow after `if not s then return end` because `ExprRule[NODE_FIELD_EXPR]` returned a fresh TAG_VAR; `peek_callee_ret_union` found TAG_VAR instead of TAG_FUNCTION. Fixed: `ctx._var_origin[res]` populated in NODE_FIELD_EXPR; peek traces through it. Same for ASSIGN_STMT. Call-site contamination fixed by `call_uid` on each `_multi_ret` entry. `peek_callee_ret_union` now always wraps rl=1 returns in a 1-tuple so `eager_slot` always succeeds. (2026-03-29, commits 588f56d–e0980ac)
- [ ] **`eager_slot` out-of-range should be a type error** — `slot > 0` on a concrete single-value return currently silently binds to `nil` instead of emitting a diagnostic "function returns 1 value, cannot capture slot N". The two meanings of `eager_slot` returning nil ("not a tuple" vs "out of bounds") are conflated. Blocked on TAG_SPREAD (once returns are always explicit tuples, the check is trivial).
- [ ] **Union-of-tuples detection is shape-based** — `peek_callee_ret_union` distinguishes `string.find`-style multi-returns by checking whether ALL arms are TAG_TUPLE. This is a structural hack: any function returning a single-value-union-of-tuples will be misidentified as multi-return. Correct fix: explicit `-> ...((T, T) | (nil, string))` spread syntax (TAG_SPREAD). Until then, the hack survives but is known-unsound for the edge case. See TAG_SPREAD item in CRITICAL section.
- [x] **Optional field absence in structural assignment** — already works. `{x=1}` satisfies `{x: number, y?: number}` because unify.lua skips absent optional fields (line 470: `if band(bfe.flags, FLAG_OPTIONAL) == 0 then`).

## libraries needing rewrite from scratch

These exist in `lib/` but are legacy/stubs — not crescent-native (wrong annotation style,
no init.lua, no tests, incomplete, or just placeholder files). Do not rely on them as-is;
they need to be rewritten before use.

- [ ] **`lib/mud_cp/`** — MUD Client Protocol (moo.mud.org/mcp/mcp2.html). Stubs with FIXME/TODO throughout, wrong annotation style, no tests. Low priority; rewrite if/when MUD substrate needs it.
- [x] **`lib/github/`** — rewritten with crescent annotations and tests (9 assertions).
- [ ] **`lib/markdown/`** — incomplete parser, FIXME comments, no tests. Rewrite when needed (Lumen, docs site).
- [ ] **`lib/imap/`** — EmmyLua style, incomplete RFC 9051 parser, no init.lua, no tests. Low priority.
- [x] **`lib/wave/`** — rewritten with init.lua + wave_test.lua (32 assertions).
- [ ] **`lib/socket/`** — effectively a stub (client.lua is 1 line). Superseded by `lib/ljsocket` + `lib/tcp`. Can be deleted or left until needed.
- [ ] **`lib/https/`** — client.lua and init.lua done (callbacks on instance, receive added, per-request TLS context). serverx.lua deleted (was broken stub). Certificate verification still disabled by default.
- [ ] **`lib/posix/`** — 6-line execv/execlp stub. Absorb into `lib/process/` or expand when needed.

Not libraries (do not rewrite, repurpose instead):
- `lib/crescent_examples/` — collection of small scripts demonstrating crescent. Not a unified library.
- `lib/linux/` — raw OS FFI definitions. Keep as a definitions file, not a library.
- `lib/stdlib/` — compliance linter. Keep as a linter, not a library.

## near-term (next sessions)

- [ ] **`lib/asm/emit/arm64.lua`** — NEON machine code emitter. Same structure as `emit/x64.lua`
  but NEON encoding (A64 instruction format). Gate tests on `cpu.neon` (always true on arm64).
- [ ] **`lib/asm/` convenience wrapper** — `lib/asm/init.lua` single-call API:
  `asm.compile(kernel_fn, ctype)` → selects abi (cpu.arch), calls `ra.allocate`, calls `emit.compile`.
  Hides the ra/abi/emit wiring from callers.
- [ ] **`lib/reactive/`** — signal primitives. See entry in future libraries section.
  Start point: `signal`, `computed`, `effect`, `batch`. Rainbow is the API reference.
- [x] **Fuzz suite gaps** — `docs/fuzz-gaps.md` fully done (all A/E/G/P tiers checked off).
- [ ] **`Parameters<typeof f>` rest capture** — pre-existing `fuzz_test.lua` failure (P2a/P2b).
  `(...%P) ->` in match arm binds only first param when F comes from `typeof`. Fix in match.lua
  or env.lua rest-capture logic for concrete function types.
- [ ] **Spread-union distribution** — `{ ...(A | B), k: V }` keeps a placeholder instead of
  distributing. Fix in `env.lua:substitute_inner`: distribute over union members, handle in
  `solve.lua` field lookup and `unify.lua`. Needed for builder pattern + mapped-type aliases.
- [ ] **Optional field narrowing** — `if opts.f then opts.f(x) end` still errors: second read
  of `opts.f` returns the union type, not narrowed non-nil. Workaround (extract to local) is
  known; real fix requires field-access narrowing in narrow.lua.
- [ ] **Narrowing for function-call return locals** — `local x = f(); if not x then return end`
  does not narrow `x` in the continuation because `x` is TAG_VAR at narrowing time. Three
  architectural options in TODO (a/b/c); needs a design decision before implementation.
- [x] **`$GlobalScope` documented** — added to permanent intrinsics list in `lib/type/static/CLAUDE.md`.
  Synthesizes a closed TAG_TABLE from all `--:: declare` globals; same pattern as `$FfiC` but for `_G`.
- [ ] **`lib/bundle/`** — Lua module bundler. Entry point → resolve static requires → inline →
  treeshake → constant fold `--define` values → single file output. Discussed 2026-04-10.
  See design notes: no dynamic `require()` support (warn/error), uses `lib/type/static/` AST.

## lib/asm — SIMD kernel compiler

- [x] `lib/asm/cpu.lua` — CPU feature detection (sse2/avx/avx2/neon, arch)
- [x] `lib/asm/ra.lua` — linear scan register allocator with aliasing model (51 assertions)
- [x] `lib/asm/ir.lua` — virtual register IR builder, live interval computation, loop backedge extension
- [x] `lib/asm/abi/x64.lua` — SysV AMD64 + Win64 register files (407 assertions)
- [x] `lib/asm/abi/arm64.lua` — AAPCS64 register file
- [x] `lib/asm/emit/x64.lua` — x86-64 machine code emitter: VEX-encoded AVX instructions,
  mmap executable memory, full vmulps/vaddps/vsubps/vdivps/vfmadd213ps + loop (27 assertions, AVX-gated)
- [ ] `lib/asm/emit/arm64.lua` — NEON emitter (A64 encoding)
- [ ] `lib/asm/init.lua` — convenience wrapper: `asm.compile(kernel_fn, ctype)`

## lib/stb — image decode/resize (vendored stb)

- [x] Package scaffold: tier selection (vendored > system-vips > pure-lua), `lib/stb/init.lua`, `lib/stb/ffi.lua`, `lib/stb/pure/resize.lua` (nearest-neighbor, full), `lib/stb/pure/image.lua` (PNG stub), `lib/stb/build.lua`, `lib/stb/src/README.md`, `lib/stb/stb_test.lua` (80 assertions)
- [ ] Download stb headers and compile vendored binaries for all 5 platforms via CI (`lib/stb/build.lua`)
- [ ] Implement pure Lua PNG decoder in `lib/png/` and wire into `lib/stb/pure/image.lua`
- [ ] Implement system-vips decode/resize wrappers in `lib/stb/init.lua` try_system_vips()
- [ ] Parity tests: vendored vs pure-lua resize on random pixel buffers (identical output)
- [ ] Benchmarks: vendored stbir vs pure-lua nearest-neighbor; record in `docs/perf/log.md`

## future libraries

See `docs/batteries.md` for the full ecosystem scope. Key entries below; batteries.md is authoritative.

- [x] **`lib/orchestration/`** — implemented: graph.lua, context.lua, exec.lua, combinators.lua (map/retry/refine), init.lua, executor/ai.lua, orchestration_test.lua (27 assertions).
- [ ] **`lib/cli/`** — arg-parsing library. Namespace freed (old `lib/cli/` renamed to `lib/crescent_examples/`). Not yet implemented.
- [ ] **`lib/datetime/`** — date/time parsing, formatting, arithmetic. Critical missing primitive.
- [ ] **`lib/regex/`** — PCRE or LPEG wrapper with crescent-native API.
- [ ] **`lib/uuid/`** — UUID v4/v7 generation.
- [ ] **`lib/log/`** — structured logging/tracing with levels and sinks.
- [ ] **`lib/compress/`** — zlib/gzip/zstd via FFI.
- [ ] **`lib/ansi/`** — ANSI escape codes (colours, cursor movement). Foundation for `lib/tui/`.
- [ ] **`lib/tui/`** — TUI widget layer (boxes, tables, input fields).
- [ ] **`lib/reactive/`** — reactive signal primitives. Push-based, no implicit tracking scheduler.
  Core API: `signal(init)` → `{get, set, update}`, `computed(fn, deps)`, `effect(fn)`, `batch(fn)`.
  No dependencies outside crescent — not even on Rainbow.
  **Rainbow** (`~/git/rhizone/rainbow/`) is a parallel TypeScript implementation of the same algebra,
  maintained separately. It defines the intended API surface and semantics (`Signal<A>`, `computed()`,
  `cond()`, `batch()`, `product()`, `stateful()`). The Lua and TS implementations are peers —
  neither depends on the other. `lib/lua2ts/` can transpile this to standalone TS that is
  API-compatible with Rainbow but does not import from it.

- [ ] **`lib/reactive_optics/`** — signals focused through optics. `signal:focus(lens)` produces a
  derived signal that reads/writes structurally; lens laws (get-set, set-get, set-set) guarantee
  state consistency by construction. Combines `lib/reactive/` with `lib/fp/optics/` (already built).
  Key combinator: `focus(signal, optic)` → `{get(), set(v), update(fn)}`.
  Parallel TS implementation: Rainbow's optics layer (`~/git/rhizone/rainbow/src/optics/`).
  Again: no dependency on Rainbow — same algebra, separate codebases.
- [ ] **`lib/ml/`** — ML vertical: `lib/vec` (dense vectors FFI), `lib/tfidf`, `lib/knn`, `lib/xgboost` (pure Lua reference + FFI).
- [ ] **`lib/ukanren/`** / **`lib/datalog/`** — logic programming vertical.
- [ ] **`lib/parse/`** / **`lib/ir/`** — language tooling vertical (compiler IR, parser combinator).
- [x] **`lib/asm/`** — SIMD kernel compiler: cpu detection, linear scan RA, virtual IR, x64 emitter. See `## lib/asm` section above.

- [ ] **`lib/lua2ts/`** — Lua → TypeScript transpiler. The typechecker already builds an AST;
  emitting TS syntax instead of Lua syntax is mostly mechanical. Prior art: `dep/lua2js.lua`
  (AST printer that outputs JS syntax). Metatables are the awkward mapping; FFI doesn't cross.
  Crescent's type annotations map directly to TS types — typed Lua → typed TS with no extra
  annotation work. Primary use case: write `lib/reactive_optics/` logic in Lua, emit typed TS,
  run in browser alongside Rainbow components. Rainbow (`~/git/rhizone/rainbow/`) is the
  deployment target — `lib/lua2ts/` output is designed to compose with Rainbow's signal/optics layer.

- [ ] **`lib/jsonrpc/`** — request/response dispatch over stdio or TCP. Substrate for LSP, Model Context Protocol, and any JSON-RPC protocol. Transport abstraction, method registry, typed handler registration.

- [ ] **`lib/lsp/`** — LSP method bindings on top of `lib/jsonrpc`. Every method pre-typed from the LSP spec; you register handlers. Currently `lib/type/static/lsp.lua` rolls its own JSON-RPC — this replaces that.

- [ ] **`lib/mcp/`** — Model Context Protocol client/server on top of `lib/jsonrpc`. (Note: `lib/mud_cp/` is the old MUD Client Protocol implementation — unrelated.)

- [ ] **`lib/ecs/`** — entity-component substrate. Named entities, typed components, spatial containment (entities inside entities), mutable state store. User-defined schemas — no hardcoded concepts like "room" or "inventory". The primitive for building world simulations, games, or any entity-centric stateful system. Turn loop, perception rules, mutation rules, and renderers (RP prose, MUD-style, etc.) are built on top by the user.

## typechecker type-level features (designed this session, needs implementation)

- [x] **`$EachField<T, F>` intrinsic** — flatMap semantics implemented (fbb00f5, 2026-03-30).
  F returns a brace-tuple: `{}` = drop, `{ D }` = keep/transform, `{ D1, D2 }` = expand.
  Detection: empty TAG_TABLE → drop; positional-indexer TAG_TABLE → multi-element tuple;
  anything else → backward-compat single-descriptor. Grammar gap fixed (124c438):
  `{ { optional: true, ...Rest } }` now parses — root cause was `else break` in the
  field loop not handling `{`-started positional entries. `...Rest` splice already
  worked. `MakeOptional`, `MakeReadonly`, `DropOptional`, `Partial<T>` all tested.

- [x] **Interface declaration syntax `--:: Name: Base`** — implemented (551cbdb, 2026-03-30).
  `--:: Name<T>: Constraint<T> = body`: (1) checks `body <: Constraint<T>` at definition,
  emits E.CONSTRAINT_MISMATCH = 26 on failure; (2) registers ctx.declared_subtypes oracle
  so try_unify(Name<X>, Constraint<X>) short-circuits in O(1). ann.lua parses `: Constraint`
  before `=`; constrain.lua resolves + registers + checks; unify.lua oracle-first for TAG_NAMED pairs.

- [x] **Partial application of generic aliases** — implemented (22f1e8f, 2026-03-30). TAG_PARTIAL_APP = 31.
  Under-arity alias call (1–N-1 args) returns TAG_PARTIAL_APP(name_id, partial_args).
  apply_type_fn completes the call. substitute_inner re-evaluates when args become concrete.
  match.lua TAG_UNION pattern added (needed for `match K { Keys => ... }` where Keys is a union).
  Enables Pick<T, Keys> and Omit<T, Keys> via $EachField + PickKey<Keys> partial app.

- [x] **`{ ...[%K]: %V }` table-pattern rest capture** — `{ field: %X, ...%Rest }` in
  match patterns: captures remaining fields into Rest; `...Rest` in result splices them
  back. Specced in docs/capture-sigil-spec.md. Needed for $EachField F aliases.
  Implementation: ann.lua + match.lua. Done 2026-03-30.

- [x] **`(...%P) -> T` and `(A, ...%P) -> T` param captures** — specced in
  docs/capture-sigil-spec.md. Enables Parameters<F>, Tail<F>, Last<F>, Init<F>.
  At most one `...%P` per param list, may appear anywhere. Implementation: ann.lua +
  match.lua. Done 2026-03-30.

- [x] **`{ #...%M }` meta-slot spread** — specced in docs/meta-spread-spec.md.
  `setmetatable = <T, MT>(t: T, mt: MT) -> T & { #...MT }`. `MetaOf<T>` alias.
  Implementation: ann.lua + match.lua + types.lua + constrain.lua + env.lua + defs.lua.
  Done 2026-03-30.

- [ ] **Literal type ops** — see docs/literal-type-ops-spec.md. Conclusion: none needed
  now. Implement on demand. Boolean ops expressible as match aliases (no primitives needed).
  String `..` has no crescent use case (JS-heritage motivation doesn't apply). `#tuple`
  and `LIT_INTEGER` arithmetic have no concrete use cases yet.

## priorities (medium horizon)

- [ ] **Registry + docs site** (`pkg.crescent.run`) — see `docs/registry-design.md` for full vision.
  Key pieces: static JSON index (GitHub Pages), install fetches from GitHub releases directly,
  no server required. Docs site renders auto-generated type signatures from typechecker output.
  Uniquely: **Hoogle-style type search** — parse a query type annotation, unify against every
  exported binding in the index using the existing unify.lua engine. The hard part (type inference)
  is already done. Three sub-projects:
  - [x] Docgen tool (`lib/doc/`) — extract `---` doc comments + inferred types → JSON/Markdown.
    `doc.generate(file)` / `doc.generate_string(src)` / `doc.generate_package(dir)`.
    CLI: `luajit lib/doc/cli.lua [--format json|text|markdown] [--package dir] <file>...`
    Filters `_`-prefixed exports, extracts parameter names, batch mode.
  - [x] Type search library (`lib/type/search/`) — Hoogle-style: parse query type annotation,
    unify against exports using try_unify. `search.build_index(files)` / `search.query(type_str, index)`.
    CLI: `luajit lib/type/search/cli.lua "(string) -> string" <files...>`
  - [ ] Type search improvements:
    - Unseal mode (`{ unseal = true }`) — search through $Opaque wrappers
    - Opaque pattern queries — `$Opaque<string>` means "any opaque wrapping string"
    - Accept type_id + ctx as query (programmatic, not just strings)
    - Acceleration structures for registry-scale indexes (bloom filter, inverted index)
    - [x] Subtype ranking (exact > subtype > supertype) — 3-level scoring
    - [x] Arity pre-filtering before check_string
    - [x] Persistent index — save_index/load_index JSON, CLI --save-index/--load-index
  - [x] Stabilise `--dump` output as machine-readable JSON (exported bindings + type sigs) — `--dump --format json` emits `[{file, bindings:[{name,type}], return}]`; M.dump_one/dump_json testable exports (edaaf6f)
  - [ ] Static docs site (bun) — renders docgen JSON; search calls type-search endpoint or
    runs unification client-side via WASM build of the typechecker.
  - [ ] GitHub Action — on release tag: run typechecker + docgen, publish JSON to index.
  - [ ] `cr add <name>` — resolve short name via index.json, fetch GitHub release tarball,
    extract to `dep/<name>/`, resolve transitive deps.

- [ ] **Test runner performance** — benchmark against bun; must be at parity or better.
  Current runner shells out to `find` + `sort`, then `dofile`s each file sequentially.
  Profile first: startup cost, require() overhead, per-file execution. Candidates:
  native file discovery (FFI readdir), parallel execution (fork + collect), preloaded
  module cache, LuaJIT JIT warm-up tuning. Target: same program runs comparably fast
  in bun and luajit; if not, the design needs revisiting.

- [x] **Package manager** (`lib/pkg/`) — core implementation done. See design docs for full detail.
  - [x] semver, manifest, lockfile, install (resolve/fetch/hardlink), config, CLI (install/add/remove/update/info/publish/eject/diff)
  - [x] Transitive dep resolution (BFS, cycle detection, diamond dedup)
  - [x] Version conflict detection (two-pass MVS resolver, constraint collection)
  - [x] `dep/` → `lib/` migration; lockfile v2 (include, tarball_hash, tree_hash)
  - [x] Include glob filtering + union merge across dependents
  - [x] Tree hash verification + local modification detection
  - [x] `cr diff`, `cr eject`, `cr update --merge`
  - [x] Pure Lua three-way merge (`lib/merge3/`) — Myers diff, no external deps
  - [ ] **Phantom dep linting** — `cr check`/`cr publish` scans require paths vs own `pkg.lua`
  - [ ] **Parallel fetch** (`--jobs`) — fork-based, I/O-bound, significant on large dep trees
  - [ ] **Workspaces** — single `crescent.lock` covering all packages in a monorepo; MVS resolver takes union of all workspace `pkg.lua` roots
  - [ ] **Lockfile format freeze** — add `lockfile_version` field, stabilise before v1 registry use
  - [ ] **`cr add` / `cr publish`** — blocked on live registry infrastructure

- [ ] **Typechecker** — large ongoing backlog; dedicated sessions welcome.
  Near-term candidates: access control design (see below), module-level LSP cache,
  soundness gap 3 (generic variance). See typechecker section below for full list.
  - [x] **Overload checking against body** — implemented: `collect_preceding_run` in
    constrain.lua accumulates consecutive `--:` annotations into intersection types;
    `check_body_against_intersection` runs N inference passes (one per overload member).

- [ ] **Stdlib rewrites** — vendored packages currently in `lib/` violate the ownership
  rule (docs/stdlib-design.md). Each needs a fresh crescent-native rewrite before the
  registry exists and the vendored copy can be removed:
  - [x] `lib/format/json/` — crescent-native JSON, three tiers (pure/ffi/simd stub).
    Parity tests + benchmarks done. pure: 72 MB/s, ffi: ~same. See docs/perf/log.md.
  - [ ] `lib/format/json_sax/` — SAX + zerocopy variant (separate library, different interface).
    Design: `scan(src, cb(key,val))` and `scan_pos(src, cb(ks,ke,vs,ve))`. Pure tier only
    (no table alloc = no bottleneck to tier away). Benchmarked: 247 ns / 254 MB/s (SAX) and
    155 ns / 405 MB/s (zerocopy) on 90B object — 2.1x faster than Node.js JSON.parse.
    Implement when HTTP layer needs streaming/large JSON parsing. Design notes: docs/perf/log.md.
  - [ ] `lib/format/cbor/` — rewrite vendored CBOR. Low priority until cbor sees more use.
  - [x] `lib/encode/base64/` — rewritten. Three-tier (simd stub > ffi > pure), RFC 4648 §4+§5, 108-line tests.
  - [ ] `lib/hash/sha1/` — rewrite mpeterv/sha1. Already heavily patched; sha256 shows
    the tiered pattern to follow.
  - [ ] `lib/ljsocket/` — largest and most complex. Blocked on registry (http/websocket
    depend on it); rewrite as cross-platform `lib/socket/` (POSIX + winsock via FFI).
  - [x] `lib/cparser/`, `lib/cmark/`, `lib/plterm/` + `lib/crescent_examples/ple.lua` — deleted (unused vendored code).

- [ ] **Stdlib buildout** — see `docs/stdlib-roadmap.md`. Phase 1–3 done (2026-03-20):
  path guards, init.lua entry points, error convention sweep, tests for core packages,
  new packages (process, iter, rand, signal, format/msgpack, format/toml, hash/hmac).
  46 app-specific packages archived. Remaining: dep.* coupling resolution, type
  annotations across Tier A (done for 24 owned packages; vendored code skipped),
  tests for ljsocket/tls/dns/inotify.
  [x] dep.* coupling resolved (a79167d) — 8 dep paths across 28 files updated.
  [x] HTML docgen output (582247c) — `--format html` with inline CSS.

- [x] **Typechecker: multiline `--::` declarations** — lexer now concatenates
  continuation `--::` lines when brackets are unbalanced. Forward references between
  `--::` types in the same file work via the existing two-pass design.
  **Note**: multi-return function types in record fields must use parens:
  `generate: (req: T) -> (R?, string?)` not `-> R?, string?` (comma is ambiguous
  with field separator).

- [ ] **Typechecker: annotation parser multi-return in record fields** — bare
  `-> R?, string?` inside `{ ... }` is ambiguous (`,` could be field separator or
  multi-return separator). Workaround: parenthesize returns `-> (R?, string?)`.
  Could fix by parsing return types greedily until `,` followed by an identifier + `:`.

- [ ] **Typechecker: type-level imports** — `--:: import "lib.ai.types"` or similar,
  analogous to TypeScript's `import type`. The checker already resolves `require()` for
  cross-module types; this would be the annotation-only equivalent for files that only
  need the types, not the runtime module.

- [ ] **Typechecker: nested generic alias application** — `Partial<Partial<T>>`
  produces `never` even though `Partial<{a: string|nil}>` (the inner result)
  works fine directly. The bug is in how a generic alias application passes its
  result as the type argument to an outer alias application. Manifests with any
  two-level `$EachField` composition. Discovered via type_complex_test.lua.

- [ ] **Typechecker: recursive structural type checking** — `{ head=1, tail=99 }`
  is accepted where `List<number>` (tail must be `List<number>?`) is expected.
  The recursive field constraint is not enforced at depth. Likely the unification
  of the recursive type hits the cycle guard before checking the concrete field.

- [ ] **Runtime type validator** (`lib/type/runtime/`) — Zod/Typebox/Arktype-style
  schema library: `T.string()`, `T.number()`, `T.object({...})`, `T.union([...])`,
  `T.array(T.string())`. Returns a validator function `(value) -> true | nil, err`.
  Pure Lua, no codegen. Key design: validators compose via the same combinators as
  the static type system. Long-term: static typechecker infers validator types so
  `local x = T.string():parse(v)` gives `x: string` after the call.

- [ ] **Typeclass dispatch key pattern** — `lib/fp/` dispatch tables annotated `{ [any]: any }` today.
  Correct design: each typeclass module exposes a `.key` field declared `--:: FooKey: $Opaque`,
  dispatch table annotated `{ [FooKey]: FooImpl, [BarKey]: BarImpl, ... }`, and
  `fa[Mappable.key]` in code resolves via the existing FLAG_OPAQUE_KEY mechanism keyed by
  the nominal `$Opaque` type instead of just the variable name string. Requires:
  (1) `$Opaque` declaration in each typeclass module (mappable, applicable, etc.),
  (2) cross-file type alias resolution in bracket-key annotation position already works
  via the existing FLAG_OPAQUE_KEY + LIT_OPAQUE_KEY path once the key IS a declared type.
  Eliminates `{ [any]: any }` from fp dispatch tables.

- [x] **Typechecker: table-valued dispatch key (GAP-HKT3)** — applied to all lib/fp/ typeclass and instance modules. `fa[Mappable.key]` resolves via FLAG_OPAQUE_KEY to the instance type. Callers annotate parameters with `{ [MappableKey]: { map: ... } }` for type-checked dispatch. (2026-03-29, 839610f)

- [x] **Typechecker: argument literal widening** — implemented in `solve.lua` (`widen_literal` applied at typevar binding; `ret_uses_tv_in_intrinsic` exempts `$Require<T>` to preserve string literal for module lookup). Confirmed: `id(0); id(1)` and `id(0); id('x')` both work.

- [ ] **Refinement types / control-flow narrowing system** — type guards, assertions, and
  `type()` narrowing are all instances of a general `refine_true`/`refine_false` algebra.
  Needed: (1) `assert(e)` narrows after the call (`x: T` in continuation); (2) `x is T`
  return type syntax for bool guards — checker *verifies* body, unlike TS which trusts;
  (3) `asserts x is T` return type for void assertions; (4) `T & asserts x is T` for
  functions that both return a value AND narrow a parameter (TS cannot express this);
  (5) `and`/`or`/`not` compose refinements automatically; (6) `getmetatable(x) == MT`
  narrows to MT's registered type; (7) exhaustiveness on `if type(x) == ...` chains.
  Design doc: `docs/type-system.md` § "Refinement types: the general system".

- [ ] **Difference types `T \ U`** — false branch of any narrowing produces `T \ U`, not
  open `~T`. Expressible as `Exclude<T, U> = match T { U => never, _ => T }`. Standalone
  `~T` only valid within Lua's closed `type()` universe (8 known values). Implement as
  false-branch refinement in constrain.lua + `Exclude` in the type prelude.

- [ ] **Type operations standard library** — `docs/type-system.md` § "Type operations are
  library aliases". Ship in prelude: `Exclude`, `Extract`, `NonNil`, `ReturnType`,
  `ElemType`, `UnwrapMaybe`, `Flatten`, `Partial`, `Required`, `Pick`, `Omit`.
  All expressible as `--::` aliases over `match` — no new compiler intrinsics needed.

- [ ] **Typechecker: HKT type argument extraction** — when `<F, A>(fa: F<A>)` is called
  with `Maybe<number>`, the solver can't extract `F = Maybe, A = number` from the
  expanded structural type. Once expanded, constructor/argument decomposition is lost.
  Constraints like `<F, A: Semigroup>(fa: F<A>)` are unenforceable — `A` is unbound.
  Blocks: typed `fmap`, typeclass-polymorphic functions, `lib/fp/` full type safety.
  Fix requires nominal type preservation or bidirectional inference before expansion.
  See `docs/type-system.md` line 862.
  **GAP-HKT1 (found 2026-03-29)**: chained fmap result is not re-usable as an HKT argument — the return type of `fmap(f, ma)` loses its constructor identity and cannot be passed to another HKT-parameterised function. Demonstrated in lib/fp/ type_complex_test.lua.

- [ ] **Typechecker: `{ [K]: V }` type param not substituted as indexer key** — when a
  generic type parameter is used as the key type of an indexer (`{ [K]: V }`), the
  parameter is not substituted at instantiation. The indexer key stays as the raw type
  variable rather than the concrete argument. Found 2026-03-29 via lib/fp/ testing.

- [ ] **Typechecker: generic variance** — all generics are currently invariant.
  `Box<Dog>` is not a subtype of `Box<Animal>`. Blocks HKT subtype relationships
  (`F<A> <: G<A>`) and natural covariant container usage. Needs design before
  implementation — declaration-site vs use-site, inference vs annotation.
  See `docs/type-system.md` line 864, `docs/soundness-audit.md` gap 3.

## security (fix soon)
- [x] http/router: path traversal via symlinks — `path.safe_resolve()` with FFI `realpath()`
- [x] http/server: reads one packet, not until headers complete — loop until `\r\n\r\n`, then read body by Content-Length
- [x] http/router/staticx: pattern `.gz$` should be `%.gz$` (Lua pattern, `.` matches any char)
- [x] http/router/staticx: opens files in `"r"` mode — should be `"rb"` to avoid newline mangling
- [ ] Full security audit of all imported libraries

## correctness
- [x] http/router/staticx: `Content-Length = ""` is invalid HTTP — omit header entirely
- [ ] http/router/staticx: detects directories via `read("*all") == nil` — fragile, use lfs or stat
- [ ] http/router/staticx: reads entire files into memory — needs size cap or streaming for large files

## stdlib

### sha256 FFI tier performance
- [ ] `lib/sha256` FFI tier benchmarks at 72 MB/s vs theoretical ~200-500 MB/s. Known causes: `compress` is a closure (JIT can't inline), `u32_to_hex8` allocates a table per call (8× per hash), zeroing loop should use `ffi.fill`, mixed Lua number/FFI integer arithmetic in schedule extension. Not a blocker for CRI workload but worth fixing before the system tier is wired up.

### crypto / hashing stdlib design
- [ ] Design a coherent `lib/hash/` or `lib/crypto/` namespace before adding more algorithms. Questions to answer: how do tiered implementations (system lib > FFI scalar > pure Lua) get shared across blake3, xxhash, md5, sha256, etc.? How are parity tests and benchmarks structured per-algorithm vs shared? Does each algorithm live in `lib/hash/sha256/`, `lib/hash/xxhash/`, etc., or is there a single `lib/hash/` with a dispatch table? `lib/sha256/` exists as a prototype — treat it as a reference, not the final shape.

### dep.* import resolution
- [ ] Many packages in `lib/` reference `dep.ljsocket`, `dep.lunajson`, `dep.epoll`, `dep.tls`, `dep.ljltk`, etc. — these resolve against `~/git/lua/dep/` in the parent monorepo, not against anything in crescent. Affected: `lib/http/client.lua`, `lib/http/serverx.lua`, `lib/https/`, `lib/codetree/`, `lib/dns/tcp_client.lua`, `lib/discord/`, `lib/lsp/`, `lib/markdown/`, and others. These packages are not self-contained and cannot be vendored. Each needs its dependencies either pulled into `lib/` properly or declared in a manifest and resolved via the package manager.

### package audit
103+ packages surveyed. Most predate the ecosystem design and were written without crescent's conventions in mind. Many will need partial or full rewrites to meet the bar — not just cleanup. Treat the audit findings as a roadmap, not a checklist.

**Verdict summary:** type/static, test, sqlite, ljsocket, lunajson, cbor, base64, sha1, urlencode, fs/dir_list, cparser, git → `clean`. http, pkg, websocket, cli → `needs-work`.

**Wrong-home (belong in registry, not stdlib):**
- [ ] `lib/glua/` — OpenGL bindings, application-specific
- [ ] `lib/mock/` — large mock library (2.6 MB), not foundational
- [ ] `lib/love/` — game framework bindings
- [ ] `lib/tree_sitter/` — parse library bindings
- [ ] `lib/ljltk/` — Lua parser/compiler (third-party origin)
- [ ] `lib/crescent_examples/` — collection of small scripts demonstrating crescent

**Missing init.lua (35+ packages):** http, https, fs, socket, tcp, dns, imap, irc, test, and others — violates "every package is a directory with init.lua entry point". Many of these also need rewrites, so add init.lua as part of the rewrite, not as a standalone fix.

**Missing spec traceability:** ~70+ packages lack RFC/spec citations. Add as part of rewrites, not retrofitted onto existing code that may be replaced anyway.

**Missing conformance tests:** dns, irc, imap, websocket, http (partial) — no tests at all for protocol behavior. Add as part of rewrites.

#### http
- [x] No `init.lua` — re-export `format`, `client`, `status` from a top-level init
- [x] `http/client`: replace `assert(socket.create(...))` with `return nil, err` — fails with unhelpful message on socket error
- [ ] `http/format`: silently drops unparseable headers — log or return error
- [ ] extract network layer (client.lua, server.lua) — needs lib/ljsocket, lib/epoll, lib/socket/server.lua
- [ ] extract routers — needs lib/path, lib/mimetype, lib/fs, lib/lunajson

#### https
- [ ] `lib/https/client.lua`: module-level TLS state (single concurrent connection) — acceptable for now but needs per-request TLS context for concurrency
- [ ] `lib/https/client.lua`: certificate verification disabled by default — `tls.config_verify()` should be the default; current code omits it for compatibility
- [ ] `lib/https/serverx.lua`: non-functional (FIXME placeholders, wrong imports) — needs full rewrite

#### ai (`lib/ai/`)
- [ ] `lib/ai/init.lua`: no retry/backoff on transient errors (429, 5xx)
- [ ] `lib/ai/providers/anthropic.lua`: tool call streaming only emits on content_block_stop — no partial tool call deltas
- [ ] `lib/ai/providers/openai.lua`: only flushes first accumulated tool call on finish — multi-tool-call streaming incomplete
- [ ] `lib/ai/tools.lua`: assistant message in tool loop doesn't carry tool_calls metadata — some providers need it for multi-turn tool conversations
- [ ] `lib/http/stream.lua`: buffer growth via string concat in hot path — should use table accumulator or FFI buffer
- [ ] **low-prio** providers needing custom adapters (not OpenAI-compatible):
  - Azure OpenAI (`api-key` header instead of `Authorization: Bearer`)
  - Amazon Bedrock (SigV4 signing)
  - Google Vertex AI (GCP OAuth, different endpoint from Gemini API)
  - Replicate (predictions API, polling model)
  - Cloudflare Workers AI (`account_id` in URL path)
  - Reka (own request format)

#### websocket
- [x] 15 TODOs — resolved/categorised (perf/api/extensions/policy/refactor); aa5a4e0
- [x] Tests — 118 assertions: frame encode/decode, masking, close/ping/pong, error cases
- [x] `package.path` guard added
- [ ] Error return convention: int → string (breaking API change, deferred)
- [ ] Packet size limit enforcement (caller policy decision, deferred)

#### sqlite
- [x] No tests — add coverage for query, parameter binding, iteration, error paths (sqlite_test.lua, 72 assertions)
- [x] `db:close()` bug: passes `self.db` (`sqlite3 *[1]`) to `sqlite3_close_v2` which expects `sqlite3 *`; should be `self.db[0]` — fixed (4b9ae58)
- [ ] blob support missing (TODO in source) — `sqlite3_bind_blob` declared in FFI cdef but unreachable from Lua API
- [x] macOS: dlopen path for libsqlite3 — fixed with pcall-based multi-name fallback (commit 4f67ac9)

#### pkg
- [x] `install.lua`: resolver and downloader — implemented (resolve, fetch, link, run)
- [x] `config.lua`: `~/.crescent/config.lua` loading with defaults

#### cli (lib/crescent_examples/)
- [ ] Scripts mix `main()` logic with library code — not composable
- [ ] Many scripts have implicit dep on lib/ layout; add path fixups or document
- [ ] Review lib/crescent_examples/ scripts — sort into per-library homes or keep as demos

#### cross-cutting
- [ ] Standardise error return style: prefer `nil, err` for recoverable errors; `error()` only for invariant violations. Affected: http/client (uses assert), cbor/lunajson (uses error() for encode failures — acceptable but document the choice)
- [ ] LICENSE files: most vendored packages have headers but no LICENSE file — add or verify (ljsocket, lunajson, cbor, sha1, base64, cparser, git)
- [ ] `package.path` guard missing from websocket and http submodules — add where standalone use is expected
- [ ] Review and polish all libraries pulled from ~/git/lua (bulk import done)
- [ ] lib/todo/: conflicts with dep/todo/ (stubs for jpeg, png, xcb, soloud + a sqlitex.lua (old naming), webp.lua) — decide what to keep
- [ ] Remove or integrate duplicate/overlapping libs (e.g., mock.lua vs mock/, lil.lua vs lil/)
- [ ] replx: add provenance tracking for lazy-loaded globals (symbol → source module)
- [ ] FFI bindings: add ABI sanity checks (sizeof/offsetof assertions for wlroots version skew)
- [ ] Formalize C header ingestion pipeline (update_wlroots.sh pattern) as reusable tooling

## typechecker

### self-hosting blockers (run clean on own codebase)
- [x] Widen literal types on reassignment (`local k = 1; k = k + 1` should work)
- [x] Multi-return unpacking (`local a, b, c = f()` should assign all three)
- [x] Forward-declared locals (`local f; f = 42` — use typevar, not nil)
- [x] Integer literal inference (hex `0x36` should be integer, not number)
- [x] Arithmetic on integers returns integer, not number
- [x] String method resolution (`s:gsub(...)` resolves via string metatable)
- [x] `number` assignable to `integer` parameter (safe widening direction)
- [x] Union-typed operands (`x and "y" or "z"` produces union — concat/arithmetic now accept)
- [x] Reassignment of literal-typed bindings (`ret = "()"` then `ret = "..."` — fixed by T.widen)
- [x] Forward references in `local M = {}` / `function M.foo()` pattern (prescan)
- [x] Dict-style computed access `t[key]` checks string-keyed fields (literal and general)
- [x] Empty table `{}` assignable to array-typed parameter (absorbs indexers in unify)
- [x] `x = x or default` pattern — strip self-ref var from union in bind_var
- [x] Cross-call-site typevar mutation — generalize params + FunctionDeclaration writes raw table
- [x] Recursive `local function f()` — pre-bind name as typevar before body inference
- [x] Discriminated union narrowing (`if t.kind == "literal" then ...`)

### unify.lua blockers
- [x] Structural narrowing after `if ty.tag == "var" then` (adjust_levels/bind_var expect level/id fields on resolved vars) — fixed: `and/or` idiom nil-union, assignment-narrowing ops annotation, d.path[i] with `--: [string]?` guard

### output formats
- [x] `--format json` structured output (file, line, severity, message)
- [x] `--format sarif` for GitHub Code Scanning / CI integration
- [x] Column numbers in error positions
- [x] SARIF column off-by-one: typechecker cols are 1-indexed; `errors.format_sarif` uses `e.col+1` → outputs col+1 (2-indexed). Should use `e.col` for 1-indexed SARIF. Fixed 2026-03-15.

### done
- [x] Full require() return type tracking (infer module return type)
- [x] Implicit any error reporting (every ANY fallback site)
- [x] `--dump` CLI mode (print inferred bindings)
- [x] `--annotate` CLI mode (emit source with --: annotations)
- [x] Type inference for local bindings
- [x] Structural typing for tables
- [x] Angle-bracket generics (`Name<T, U>`) with constraint support
- [x] Named type resolution with two-pass forward references
- [x] Tuple types (`{ number, string }`) and spread (`{ ...Base }`)
- [x] Flow-sensitive type narrowing (type(), nil checks, truthiness, assert)
- [x] Module resolver + prelude system (Array, Dict, Set, Optional)
- [x] Nominal types (newtype, opaque)
- [x] Match types (`match T { pattern => result }`)
- [x] Intrinsics ($Keys, $EachField, $EachUnion)
- [x] Overload resolution (best-match scoring)
- [x] setmetatable __index merging, __call metamethod
- [x] `#field` metatable slot syntax — separate `meta` dict on table types; `#__add: fn` in annotations; setmetatable populates META_OPS into meta; unification checks meta fields

### known false positives
- [x] **Assignment narrowing**: assigning `nil` to a variable inside `if x then` is flagged — typechecker checks against narrowed type, not declared type. Fixed: narrowing-escape generalized from nil-only to any value; checks outer scope binding for the pre-narrowing type.
- [x] **Nil method call not caught**: `local x; x:match("pattern")` — fixed by nil_vars side-channel; `testdata/errors/nil_method.expected` now captures the error.

### access control (design complete, implementation pending)
- [x] **Design field access control model** — written to `docs/access-control.md` (2026-03-19)
- [ ] **Resolve open questions in access-control.md before implementation**: (1) annotation syntax for exported type vs internal type; (2) opt-in syntax at use site for intentional private access; (3) read/write independence in annotation syntax; (4) split FLAG_READONLY into FLAG_IMMUTABLE + FLAG_WRITE_PRIVATE in FieldEntry
- [ ] **Remove FLAG_PRIVATE** — current `_`-prefix enforcement (session 25) is wrong model. Privacy = absence from exported type + `$Opaque<T>` + `--:: unseal` opt-in. No definition-site whitelist.

### nominal type identity across files (bug)
- [x] **`newtype` and `$Opaque<T>` identity is now content-addressed**
  — nominal IDs are now derived from `fnv31(filename:ann_tid)` for `$Opaque` and
  `fnv31(filename:newtype:name)` for `newtype`, making them deterministic for the
  same source content across runs. The stable hash is stored in TAG_TYPE_CALL.data[3]
  and persisted through .cri files so cross-file aliases resolve consistently.
  **Remaining gap**: two *different* files declaring the same alias (e.g.
  `--:: Schema<T> = $Opaque<T>` in both init.lua and check.lua) still produce
  distinct types. The fix requires module type imports — when check.lua does
  `require("lib.type")`, its annotations should resolve `Schema` from init.lua's
  exported type aliases, not from a re-declaration. Tracked below.
- [x] **Module type imports**: type aliases from required modules are now in scope for annotations.
  CRI Section 6 serializes/deserializes type aliases. When `require()` resolves via
  cri_loader, aliases are returned alongside exports and injected into scope via
  `inject_imported_aliases` in constrain.lua. Local declarations take precedence.
  Fixed: cri_write now registers alias name/param strings in the string table.

### known false negatives (v2)
- [x] **nil/boolean concat**: `nil .. "a"` silently passed — fixed by replacing is_concat_scalar tag whitelist with `__concat` metamethod presence check via meta_op_ret/prim_meta. nil and boolean have no __concat → correctly fail. string|nil union member fails correctly.
- [x] **`_G` should be an intrinsic reflecting the global scope**: synthesized as `$GlobalScope` — closed TAG_TABLE (no fallback indexer), named fields per declared global, declared in stdlib.d.lua. TAG_INTRINSIC resolution in constrain.lua checks type aliases first so `$Name` works as a regular type reference when registered. (2026-03-19, 5a42a48)
- [x] **`ctx.d.lua` leaks internal bindings into user scope**: `populate()` now only loads stdlib.d.lua; `populate_checker()` loads both. (2026-03-19, 9c9f788)

### annotation syntax gaps
- [x] **Open table syntax in .d.lua**: `{ ... }` bare spread in table annotation creates a row variable; `{ fields..., ... }` = open table. `_G` now declared in stdlib.d.lua. (2026-03-03, commit 6e197c5)
- [x] **`typeof` annotation**: `typeof x` captures the inferred type of binding `x`. TAG_TYPEOF = 25; ann.lua recognises `typeof <ident>`; resolve_annotation_type does scope lookup. Top-level `--::` decls with typeof are deferred until after gen_block. (2026-03-19, 913110e)
- [x] **`typeof` in function signatures**: pre-bind param names as TAG_VAR placeholders before resolving annotations. All cases work: forward refs, backward refs, return refs, mutual refs.

### performance (v2 redesign)
**Full redesign in progress. See `docs/typechecker-v2.md` for architecture.**

v1 is a proof-of-concept for the type system semantics. v2 is the production
implementation targeting tsgo-competitive cold-start performance and sub-100ms
incremental checking at 1M+ LOC scale.

Key design decisions:
- Flat-array AST (32-byte FFI nodes, arena-allocated, zero GC)
- Integer type tags + union-find (no string dispatch, O(α) resolution)
- Custom parser → flat AST directly (no intermediate tables)
- mmap-able .cri interface files (zero-copy, content-addressed)
- Merkle DAG incremental cache (interface-hash propagation)
- Fork-based parallelism via libc FFI (wave-front scheduling)
- LSP daemon with tiered memory (hot/warm/cold)

**v2 checker Phase 3 — implemented (2026-03-02).**
Types: flat TypeSlot arenas + union-find. Env: let-polymorphism (generalize/instantiate).
Unify: structural, bidirectional, row polymorphism. Infer: full AST walk, annotations, narrowing.
Files: types.lua, env.lua, unify.lua, errors.lua, match.lua, narrow.lua, infer.lua, check.lua.
Tests: 721 assertions in v2_test.lua (1123 total across all suites).

Known gaps / Phase 4 deferred work:

**Phase 4 preamble complete (2026-03-02, commit 663e90a):**
- [x] cli.lua — thin CLI runner
- [x] prelude.lua — Lua 5.1 stdlib bindings (string, table, math, io, os, coroutine)
- [x] open-table extension — `function M.foo()` adds field via table_add_field
- [x] prescan: function M.foo() pre-populates M's field list before inference
- [x] prescan: `local M = {}` preserves prescanned type (no clobber on infer)
- [x] iterator type inference — `for k, v in pairs(t)` uses iter func return types
- [x] string method calls — `s:gsub()` looks up string prelude table

**Known false positives in v2 (catalogued 2026-03-02 against v2 source):**

Cat A — Forward-declared nil locals (large impact on infer.lua): **FIXED 2026-03-02**
- `local f; f = function()` — now binds a fresh type var instead of T_NIL when no RHS
- Fixed in StmtRule[NODE_LOCAL_STMT]: el==0 → make_var; last_rhs_is_call → T_ANY
- Remaining: `local x = nil` (explicit nil literal) still binds T_NIL — Cat A variant

Cat B — Multi-return assignment loses values: **FIXED 2026-03-02**
- Fixed in StmtRule[NODE_LOCAL_STMT] and StmtRule[NODE_ASSIGN_STMT]:
  when last RHS is a call, missing return slots → T_ANY instead of T_NIL
- Remaining: fully generic multi-return arity tracking (future)

Cat C — Literal table vs indexed type mismatch: **FIXED 2026-03-02**
- Fixed in unify.lua: when b has a numeric indexer and a has no matching indexer, check
  a's sequential integer-named fields ("1", "2", ...) and unify each value with the indexer value type.

Cat D — Boolean literal widen on reassignment: **FIXED 2026-03-02**
- Fixed in StmtRule[NODE_LOCAL_STMT]: boolean literal binds widen to `boolean`
- Fixed in StmtRule[NODE_ASSIGN_STMT]: existing binding widened before unify

Cat E — Nil-narrowing after early return: **FIXED 2026-03-02**
- narrow.lua: bare identifier treated as nil-check; guard clauses apply negated narrowing
- narrow.lua: TAG_VAR not narrowed to T_NEVER (prevent "never" in branched code)
- StmtRule[NODE_IF_STMT]: after unconditional-exit clause, apply negated narrow to continuation
- ASSIGN_STMT: skip unify when existing resolves to T_NEVER (narrowed-out branches)
- OP_AND short-circuit narrowing: `a and a.field` narrows `a` before evaluating `a.field`.
  narrow_scope handles OP_AND in truthy branch; infer.lua OP_AND early-returns with narrowing.
- OP_OR guard narrowing (2026-03-02): `if not x or not y then return end` — falsy branch of
  `A or B` applies De Morgan: narrow_scope handles OP_OR with is_truthy=false, extracting
  narrowings from both arms. Also added NODE_FIELD_EXPR support in extract_narrowing:
  `x.field` is a "field_presence" check; after `if not x.field then return end`, x.field
  is narrowed to non-nil in the continuation via narrow_field_non_nil (rebuilds table type).

Cat F — `intern_mod.get()` returns `string|nil`, `or "?"` not narrowed to `string`: **FIXED 2026-03-02**
- Fixed in ExprRule[NODE_BINARY_EXPR] OP_OR: strip nil from left side before union with right.
- Also fixed `is_concat_ok` to handle unions (all members must be concat-compatible).
- `string|nil or "?"` now produces `string|"?"` (concat-safe union), not `string|nil|"?"`.

Cat J — **FIXED 2026-03-02** (commit 0a91819):
- Removed `constrain()` / `meta_constraint()` — free typevars in arithmetic stay free.
- Added `prescan_block` call inside `infer_function` (forward-decl'd) to pre-bind nested
  `local function f()` before body inference (fixes self-recursive nested locals).
- Added `and`-short-circuit narrowing in ExprRule[OP_AND] (infer.lua) and narrow_scope
  (narrow.lua) — `ann and ann.field` no longer fails before entering the truthy branch.
- Added `seen` dedup table in `make_union` (types.lua) — prevents `'v | 'v` unions that
  broke field access after stripping nil from `nil | 'v | 'v`.
- Trade-off: arithmetic on unannotated params is no longer constrained (e.g. `add({}, {})` with
  unannotated `add(x,y) = x+y` won't error). Annotated code is unaffected.
- All 9 previously-clean v2 source files now self-check at 0 errors.

Cat G — string meta architecture: **FIXED 2026-03-02**
- `ctx.prim_index` (TAG_* → __index TID) for method dispatch; `ctx.prim_meta` (TAG_* → op-metamethods TID) for operator dispatch.
- Both populated by prelude.populate() from stdlib.d.lua aliases (number_meta, integer_meta, string_meta_ops, string var).
- infer.lua NODE_METHOD_CALL: generic prim_index[tag] lookup; literal strings normalized to TAG_STRING.
- infer.lua meta_op_ret: extended to check prim_meta for primitives — unary `-integer` now returns integer (not number).
- infer.lua binary dispatch (ARITH/CMP/CONCAT): TAG_TABLE guard prevents prim_meta from short-circuiting error checks and mixed-type arithmetic.
- unify.lua: replaced if/elseif tag switch with prim_meta[ptag] lookup (TAG_LITERAL normalized inline).
- Known gap: `nil .. "a"` not flagged — TAG_NIL is in is_concat_scalar (pre-existing, separate fix needed).

Integer literal typing: **FIXED 2026-03-03** (commit bb0c2e8 era)
- `NODE_LITERAL` handler was using numval index as a pool intern ID (IDs 0-21 are keywords).
- Fix: store `pr.lexer.numvals` in `ctx.numvals`; check `num % 1 == 0` for integer classification.
- integer <: number is now unidirectional (integer assignable to number, NOT vice versa).

Cross-type comparison: **FIXED 2026-03-03** (commit bb0c2e8)
- `"a" < 1` and `1 < "a"` silently passed because each operand individually had __lt in prim_meta.
- Fix: meta_fn_tid helper returns the full metamethod function TID. In CMP_META dispatch, after
  has_metamethod passes for both operands, look up the __lt/__le function (left first, then right
  per Lua calling rules) and validate both operands against its declared parameter types via try_unify.
- Bonus fix: try_unify union-LHS case: all members must be assignable to b (previously fell through
  to false, causing false positives for `integer | number > number` patterns in unify.lua self-check).

Cat H (new) — Optional function parameter typed as required: **FIXED 2026-03-02**
- Fixed in infer_function: scan first 10 body statements for `param = param or default`.
- After body inference, widen matched params to union(bound_type, T_NIL).
- `resolve_annotation_type(ctx, id)` (2 args) now accepted where 3rd param has default.

Cat I (new) — Explicit `local x = nil` still binds T_NIL: **FIXED 2026-03-02**
- Fixed in NODE_LOCAL_STMT: when rhs resolves to TAG_NIL, bind fresh typevar (same as Cat A).
- `local arg_ids = nil; arg_ids = {}` now works correctly.

Recursive function return type inference: **FIXED 2026-03-03** (commit 192b878)
- Prescan now creates `(T_ANY,...) → β` stubs (not bare TAG_VAR). β is shared across all recursive
  call sites (not FLAG_GENERIC → instantiate passes it through unchanged). add_return eagerly binds
  β on first return statement; all later recursive calls resolve via find(). ctx.return_stub_vars
  stack threads stub return vars into nested function scopes. Annotated functions skip eager binding.
- Limitation: unannotated params are TAG_VAR; arithmetic falls to T_NUMBER. Annotated params work.

**Phase 4 proper:**
- [x] .cri interface files (zero-copy module loading, content-addressed) — 2026-03-03: sha256.lua, cri_write.lua, cri_read.lua, cache.lua, check.lua integration
- [ ] Fork-based parallelism (Phase 5)
- [ ] LSP daemon integration (Phase 6)

**Next high-value false-positive fixes (from catalogue above):**
- [x] Cat A: forward-declared nil locals → make_var (unblocks most of infer.lua false positives)
- [x] Cat B: multi-return in assignments (right-hand side)
- [x] Cat D: boolean literal widen on reassignment
- [x] Cat E: guard/early-return nil narrowing (full fix: includes OP_OR De Morgan + field_presence)
- [x] Cat C: positional table vs indexed type — FIXED 2026-03-02
- [x] Cat F: `A or B` result narrowing — FIXED 2026-03-02
- [x] Cat H: optional function parameters (seen arg pattern) — FIXED 2026-03-02
- [x] Cat I: explicit `local x = nil` treated as forward declaration — FIXED 2026-03-02

- [x] Infinite recursion in resolve_require: fixed with `_globally_resolving` module-level table.

Lexer optimization (see `docs/perf/log.md` for measurements):
- [x] Kill `_buf` mechanism — pointer arithmetic + `ffi.string` at end (1.4x speedup)
- [x] Source-referencing intern pool — FNV-1a hash + memcmp, zero Lua strings in lex path (5.3x total vs baseline)
- [ ] (stretch) Full FFI struct hash table for intern entries — current impl uses Lua tables per entry with FNV-1a + memcmp; a flat FFI array could reduce GC pressure further but 5.3x is good enough to move on

### v2 → v3 migration (constraint-based inference)

Design: `docs/typechecker-v3.md`. Implementation: `lib/type/static/constrain.lua` + `solve.lua`.
Entrypoint: `check.check_string_v3(src)`. Status: Phase 1 (parallel) — v3 runs alongside v2.

**Phase 1 blockers (reach parity with v2):**
- [x] String method dispatch (`s:gsub(...)` via prim_meta) — prim_index lookup in solve_has_field
- [x] prim_index / metamethod lookup for primitives — same
- [x] Narrowing (type(), nil checks, `if x.tag == "foo"`) — narrow_scope/apply_narrowed in constrain.lua
- [x] pcall / xpcall — already correct via stdlib.d.lua `any` param declarations
- [x] Iterator inference (`for k, v in pairs(t)`) — already implemented in constrain.lua
- [x] `or`-expression union inference (`x or default` → `T | U`) — already implemented in constrain.lua
- [x] Correlated multi-return narrowing — C_INDEX + filter_tuple_union_arms + pcall intrinsic; io.open/string.find union-of-tuples stdlib types (2026-03-19)

**Phase 2 — cutover:**
- [x] Replace `check.check_string` with v3 pipeline — done; check.lua fully on v3 (commit 848ea56)
- [x] All existing tests must pass — 838/838 pass against v3 (2026-03-16)
- [x] Delete `infer.lua` — done (commit 2e33c62); type_test.lua migrated to check_mod

**Phase 3 — annotation pass (after Phase 2 cutover):**
- [x] Rewrite remaining sumneko-syntax `.d.lua` files in crescent annotation syntax
  (`--:` / `--::`). Files: `lib/http/format.d.lua`, `lib/lsp/types.d.lua`,
  `lib/imap/format.d.lua`, `lib/matrix/format.d.lua`. Done: commit `2a9ec10`.
- [ ] Strip all `--:` annotations from own codebase, run v3, record error set
- [ ] Re-annotate only where errors appear (load-bearing annotations)
- [ ] Mark inference-gap annotations with `-- TODO: v3 gap` comment so they're removable in bulk when the gap closes
- [ ] Keep annotations on public API functions regardless (they're contracts, not just inference hints)
- [ ] Goal: minimal annotation set where every annotation either fixes an error or documents a public contract

### v1 → v2 cutover status (2026-03-10)

v2 is architecturally superior but v1 CLI has QoL features v2 still needs before cutover:

| Feature | v1 | v2 |
|---|---|---|
| Source line + caret in errors | ✓ | ✓ (2026-03-10) |
| `--format sarif` | ✓ | ✓ (2026-03-10) |
| `--dump` mode (print inferred bindings) | ✓ | ✓ (2026-03-10) |
| `--annotate` mode (emit source + annotations) | ✓ | ✓ (2026-03-10) |
| Auto-glob `lib/*.lua` when no args | ✓ | ✓ (2026-03-10) |
| `.cri` cross-file require() types | ✗ | ✓ |
| Correct integer <: number | ✗ | ✓ |
| pcall/xpcall narrowing | ✗ | ✓ |
| Branch-join merging | ✗ | ✓ |
| Recursive fn return inference | ✗ | ✓ |

Blocking items for cutover:
- [x] `--dump` mode in v2 CLI — 2026-03-10
- [x] Auto-glob fallback in v2 CLI — 2026-03-10
- [x] `--annotate` mode in v2 CLI — 2026-03-10

### backlog
- [x] **Object narrowing via field access** — `if foo.x then aaa(foo)` narrows `foo` itself so `aaa(foo)` typechecks. Implemented via `field_presence` narrowing in `apply_narrowing` (narrow.lua): `narrowed[obj_name_id]` is set to `narrow_field_non_nil(obj_type, field_name_id)`, which rebuilds the table type with nil subtracted from the named field. Works for plain tables and unions. Tests added in type_test.lua ("checker: object narrowing via field access").
- [x] **Type system completeness audit** — tag × operation matrix written to `docs/type-tag-matrix.md` (2026-03-15, commit b51f976). Fixed: `x == "literal"` direct variable narrowing (lit_eq kind, LIT_STRING + LIT_BOOLEAN), boolean field discriminant narrowing, TAG_ROWVAR in try_unify/unify, TAG_TUPLE literal indexing. Known remaining gaps documented in the matrix: integer discriminants (numval per-file), covariant/contravariant generics, recursive types, TAG_MATCH_TYPE/FORALL/TYPE_CALL/SPREAD not handled in unify (by-design: meta-level constructs not expected in value position).
- [x] **Soundness audit** — 2026-03-15. Full audit written to `docs/soundness-audit.md`. Gaps enumerated: (1) TAG_VAR permissiveness in try_unify — union/intersection dispatch silently accepts free-var args; (2) unannotated params by design; (3) generic variance not enforced; (4) no occurs check for recursive types; (5) intersection dedup — FIXED 2026-03-15 (added `seen` table to make_intersection); (6) nil-padding in arity check — correct for Lua semantics; (7) LIT_INTEGER cross-file — deferred.
- [x] **Soundness fix: try_unify TAG_VAR** — `try_unify` no longer returns true for `ta.tag == TAG_VAR` (free actual type). Only `tb.tag == TAG_VAR` (free expected, for generic instantiation) stays true. `ta.tag == TAG_ROWVAR` kept true for open-table structural matching. (2026-03-15, session 21). See `docs/soundness-audit.md` Gap 1.
- [ ] **Soundness gap: `try_unify` does not check meta fields** — `try_unify` (used for generic constraint checks, oracle lookup, fuzz algebra) only checks regular table fields; meta fields are only checked in `M.unify` (constrain.lua path). Consequence: `<T: { #__add: T }>` generic constraints silently accept types without the required metamethod. Fix: extend the TAG_TABLE branch of `try_unify` to also iterate meta fields. Found while attempting A4 algebra fuzz invariants (2026-03-30).

- [ ] **Soundness fix: mutual recursion via non-table types** — `bind_var` has occurs() for simple self-ref; `display()` has seen guard for tables. Mutual recursion through function types (very rare in Lua) is not protected. Very low priority. See `docs/soundness-audit.md` Gap 4.
- [ ] **Soundness fix: generic variance** — type params in `<T>` generics have no variance annotation; covariant/contravariant positions not enforced. Requires design. See `docs/soundness-audit.md` Gap 3.
- [ ] **Error message quality audit** — bar is Rust-level helpfulness. Specific gaps identified:
  - Source line + caret: **DONE** (2026-03-10) — errors.lua set_source/format_plain/format_ansi
  - "missing required argument" now shows expected type: **DONE** (2026-03-10) — `argument 1: missing required argument (expected 'string', got nil)`
  - Long type truncation: **DONE** (2026-03-10) — display_short() at 120 chars with …
  - "missing required argument" now includes parameter name: **DONE** (2026-03-10) — `argument 1 'opts': missing required argument...`; param name IDs stored in TypeSlot data[5]/data[6], threaded through instantiate/substitute
  - Named params in annotations: **DONE** (2026-03-10) — `(x: integer, y: string) -> boolean` syntax in ann.lua; stdlib.d.lua updated to use named params throughout; resolve_annotation_type passes names to make_func via data[5]/data[6]
  - Warn on annotation-only functions missing param names: **DONE** (2026-03-10) — `process_type_decls` in infer.lua emits a warning for `--:: declare fn = (T1, T2) -> ret` where the function type has params but no names; inline `--:` annotations on real functions don't warn (names come from AST)
  - [x] Overload mismatch: show *which* overload candidates existed and why each one failed (candidate-by-candidate diff) — **DONE** (2026-03-11): try_call_args (non-mutating) tries each candidate; first match wins; if none match, reports "no matching overload" with per-candidate argument errors
  - **DONE** (2026-03-15): Error message wording overhaul — natural English, no jargon. Patterns: `` `name` is `X`, but this location expects `Y` `` (field re-assign); `` `foo.baz` doesn't exist `` (field not found, no field listing); `` `arg` is `X`, but `fn` expects `Y` `` (call mismatch, uniform regardless of whether X is unknown). Secondary spans for field errors via reparse-on-error (same-file: AST walk; cross-module: reparse from disk). "Did you mean" and "consider annotating" suggestions removed — exact error is enough.
  - ctx.d.lua — **DONE** (2026-03-15): `lib/type/static/ctx.d.lua` declares `Ctx` type alias; loaded by prelude.lua; ~30 functions in infer.lua annotated; self-check 0 errors.
  - Field re-assignment type-check — **DONE** (2026-03-15): `` `name` is `X`, but this location expects `Y` `` with secondary "set to `X` here:" span.
  - Remaining gap: suggestions still listed as open below — actually dropped; error messages are intentionally minimal ("exact error, no more, no less")
- [ ] High-perf SHA-256 for .cri content addressing: current pure-Lua impl is correct but slow
  (~10 MB/s). For 1M LOC scale, SHA-256 should be done via FFI (libssl EVP_DigestInit or
  kernel crypto via syscall). Profile first — .cri files are small (kB range) so this may
  not matter until we're hashing source files at scale.
- [x] Generic function inference (infer type params from call site args)
- [x] `<T>` explicit generic annotation syntax — `--: <T>(T) -> T` on a function; forall vars are generic typevars, freshened at each call site; composes with type-alias params (`--:: Name<T> = …`)
- [x] Partially inferred / partially specified generics — `f --[[:<json.Format, _>]] (val)` where `_` means infer. Annotation on any line `[callee.line, node.line]` (node.line = `(` line). Lua 5.1/LuaJIT constraint: `(` cannot be on a new line from the callee (ambiguous call syntax), so annotation must share the callee's line in practice. Lua 5.2+ compat removes this restriction.
- [x] Parse LuaJIT FFI cdef blocks
- [x] **stdlib.d.lua: type `bit.*` library** — all bit.* fns typed, return integer
- [ ] **stdlib.d.lua: multi-target support** — stdlib types differ by runtime/version (LuaJIT vs Lua 5.1/5.2/5.3/5.4); currently stdlib.d.lua targets LuaJIT but isn't labelled as such; design needed: separate .d.lua files per target, or conditional sections, or CLI `--target` flag that selects which prelude to load
- [x] Field assignment `M.foo = val` now adds the field to M's table type via NODE_FIELD_EXPR handling in NODE_ASSIGN_STMT. Structural-inference guard: skip when existing field type is TAG_VAR (prevents Cat J regression where `s.pos = s.pos + 1` binds the structural typevar).
- [x] **Index assignment type-check** (`t[k] = v`) — 2026-03-15: string literal keys handled as field assignment (add/check named field); non-literal keys checked against matching indexer if present; TAG_VAR tables constrained to have `[key_type]: val_type` indexer. Conservative: no indexer added to extensible tables with no matching indexer (avoids false positives on `returns[#returns+1] = v` patterns). Field re-assignment for index exprs now matches field-expr behavior.
  - Session 15 (2026-03-15, 8486a33): enforcement tightened — error on type mismatch for concrete key types (literal, integer, etc.); skip check only when indexer key is T_ANY/T_UNKNOWN (dynamic dispatch tables). `{ [1]: string }` with `arr[1] = 42` now errors correctly.
- [x] **LIT_INTEGER literal type** — Session 15 (2026-03-15, 8486a33): `LIT_INTEGER = 4` kind added. Integer literals get globally-comparable type (value in data[1] as int32). Number annotations produce LIT_INTEGER for integers. `x == 5` narrowing, TAG_TUPLE indexing, dispatch table slot typing all benefit.
- [x] **LIT_NUMBER float fix** — Session 16 (2026-03-15, b00b27b): `double_to_i32x2`/`i32x2_to_double` helpers in defs.lua. Lex, parse, ann, types, infer, cri all updated. numvals side-array removed. Non-integer floats now produce `LIT_NUMBER` (not `T_NUMBER`), enabling `x == 3.14` narrowing.
- [x] **`x == 3.14` narrowing** — (2026-03-15, b629ef6): `make_lit_eq` in narrow.lua extended to handle LIT_NUMBER non-integer floats via `i32x2_to_double`. `M.unify`/`M.try_unify` in unify.lua fixed to compare `data[2]` for LIT_NUMBER literals (was only comparing `data[1]`).
- [x] **Enum inference** — Session 16 (2026-03-15): `TAG_ENUM_MEMBER = 24` (defs/types/unify/narrow/infer). All-literal same-kind table fields promoted to enum members via `try_promote_enum` in `StmtRule[NODE_LOCAL_STMT]`. `Status.OK` displays as `Status.OK`, `EnumMember <: integer/string` in unify. `x == Status.OK` narrowing via `enum_eq` kind in narrow.lua. Mixed-kind tables not promoted. Tests: 5 new assertions.
- [x] **Newtype IDs for type/intern/node IDs** — Session 16 (2026-03-15, f0cc150): `TypeId`, `InternId`, `NodeId`, `ListIdx` declared in ctx.d.lua. `load_decls` pass 2 in prelude.lua assigns unique `nominal_id` per newtype (was all 0, making them unify).
- [x] **Explicit `any` warning** — Session 16 (2026-03-15): DONE. `resolve_annotation_type` emits a warning when `TAG_ANY` is encountered in an explicit annotation (`ctx._ann_warn_line` set at call sites in LOCAL_STMT, FUNC_EXPR, FUNC_DECL). infer.lua annotations fixed (55 → 0 warnings).
- [x] **Structured diagnostics** — Session 16 (2026-03-15, 3cfd4b2): `M.E` table with 22 integer error codes in defs.lua. `errors.format_diag(code, args)` with per-code template closures. `report`/`warn` now take `(ctx, line, col, code, args)`. All 28 call sites updated.
- [x] v2 stdlib.d.lua: stdlib.d.lua created (2026-03-02); prelude.lua replaced with load_decls().
  `--:: declare name = type` for variable bindings; `--[[:: name = { ... }]]` for type aliases.
  Primitive meta types (number_meta, integer_meta, string_meta_ops) declared in stdlib.d.lua;
  derived into ctx fields after load_decls runs.
- [x] ann.lua: `declare` keyword added to ANN_DECL parser for variable bindings (vs type aliases).
- [x] ann.lua: function data[4] (vararg) fixed — trailing `...T` SPREAD now extracted correctly.
- [x] ann.lua: table data[4] (row_var) fixed — closed by default (-1), was accidentally open (0).
- [x] ann.lua: skip_ws fixed to handle newlines (B_NL, B_CR) for multi-line block annotations.
- [x] `pcall`/`xpcall` return type narrowing — FIXED 2026-03-02: detect pcall/xpcall in ExprRule, extract wrapped fn return types, give `local ok, val = pcall(fn)` val: ret_type|nil; `if ok then`/`if not ok then return end` narrows val to ret_type via propagate_pcall_narrowing in record_narrowing.
- [x] For-in iterator return type tracking — `for k, v in pairs(t)` always gives `any` for k/v; need iterator protocol inference (ipairs/pairs over typed tables, custom iterators)
  - FIXED 2026-03-02 (commit 4efcd5a): detect pairs(t)/ipairs(t) single-call in NODE_FOR_IN; extract [K]:V indexer from actual table arg; typed loop variables. Falls back to iter-func-return extraction for other iterators.
- [x] Metatable slot syntax: `#field` in type annotations — done (see above)
- [x] Structural operator dispatch — BinaryExpression/UnaryExpression/ConcatenateExpression check `meta["__add"]` etc. on operand types via `meta_op_ret`; metamethod return type used instead of primitive check. Unlocks linalg / custom numeric types.
- [x] Structural constraint propagation for send — `x:method(args)` on a var should constrain x to `{ method: (self, args...) -> T, ...row }` (mirrors field access on var).
- [x] Implicit-any warnings on unannotated params — warn if param typevar still completely unbound after body inference; skip `self` and `_`.
- [x] Arithmetic/concat constraint propagation — `a + b` on vars should constrain to "numeric OR has `#__add`"; cannot naively bind to `number` (rejects custom types). Needs a typeclass-style "Numeric" constraint or union of `number | { #__add: ... }`. Same for concat and `#__concat`.
- [x] Branch-join / post-if type merging — FIXED 2026-03-02 (commit 19a6b19). Nil-default pattern,
  exhaustive if/else assignment, if-only assignment all handled. lookup_declared skips narrowing
  scopes; ASSIGN_STMT rebinds branch-locally; NODE_IF_STMT diffs branch scope and unions results.
  **DONE (v3, 2026-03-17, session 25)**: post-if branch-join narrowing ported to v3.
  `branch_scope_diff` + Cat E guard + union of per-branch end types. All branch-join
  tests passing. See commit `feat(type): v3 branch-join`.
- [x] Private field visibility enforcement — DONE 2026-03-17 (session 25). `_`-prefix fields
  get FLAG_PRIVATE. Cross-file access rejected in solve_has_field. ctx.type_origins maps type IDs
  to source filenames via CRI load tagging.
- [x] **Monomorphic callsite inference** — DONE (2026-03-19, commit 6cff48f): removed automatic
  `generalize` for unannotated functions. Params stay as free TAG_VARs; call-site C_CALLABLE binds
  them. Body constraints (C_ARITH etc.) defer until params are concrete. `add("hello", 2)` with
  body `a+b` now correctly errors. `self` param in methods still gets FLAG_GENERIC (avoids recursive
  type cycle). Prescan stub mutated in-place (not C_UNIFY). `unify(var, T_UNKNOWN)` now binds var.
- [x] pcall v3 narrowing — DONE (2026-03-19): C_INDEX multi-return + C_OR deferred or-expression
  fix now correctly types `s` as the pcall'd fn's return type. `s + 1` in `if ok then` errors
  with "cannot perform arithmetic on 'string'". Commits: 4976104 (C_OR), ca871ba (union subsumption).
- [x] `(string|nil) or "fallback"` not narrowing — DONE (2026-03-19): C_OR = 10 deferred constraint.
  OP_OR handler now emits `{C_OR, left, right, result}` instead of computing eagerly. solve_or
  defers while left is TAG_VAR, then runs subtract(left, nil) | right. Commit: 4976104.
- [x] `integer | 0` / `number | integer` union noise — DONE (2026-03-19): make_union now collapses
  literals subsumed by their primitive (LIT_INTEGER → integer, LIT_INTEGER → number), and integer
  into number. Fixes self-check false positives in arithmetic expression types. Commit: ca871ba.
- [ ] unnamed-params warn in --:: declare — `--:: declare fn = (T1, T2) -> R` should warn when
  param types are unnamed. Feature exists in v2 path but not v3 process_type_decls. Test fails
  after 2026-03-17 silent-crash fix.
- [x] $EachField descriptor `optional` flag — already implemented; `optional: true` in descriptor sets FLAG_OPTIONAL on output fields. Tests added (e31c6bd).
- [x] $EachField / $EachUnion full transform evaluation — descriptors, union distribution, any input all working (2026-03-19)
- [ ] Typed holes / completions
- [x] **Match type pattern-bound variables** — fixed 2026-03-19 (commit 13e9603)
- [x] **Recursive generic type crash** — fixed 2026-03-19 (commit d1bb4b9)
- [x] **`never` type not enforced** — fixed 2026-03-19 (commit bf776ff)
- [x] **`any` through `Box<any>`** — fixed 2026-03-19 (commit bf776ff + annotation authority fix)
- [x] **Tag-exclusion in else branch** — fixed 2026-03-19: else branch now applies accumulated negated narrowings from all preceding if/elseif conditions (both Cat-E exiting and pass-through). See `fix(type): tag-exclusion narrowing in else branch`.
- [x] **Tag-exclusion in else with multiple exiting elseif arms** — fixed 2026-03-20: `filter_union` added to types.lua; `guard_narrowings` fallback (when `arm_info` is nil) now uses `filter_union(guard, neg)` instead of last-write-wins, correctly intersecting the accumulated guard with each new exiting arm's negation. See `fix(typechecker): accumulate else-branch negations across all exiting elseif arms`.
- [ ] Variadic `pipe`/`compose` typing — fixed-arity overloads work but variadic needs design; blocked on generic inference + possibly variadic generics or dependent types. Low priority, pending design.

## performance

- [ ] Bench infrastructure (pure Lua, handgrown) — micro + macro; latency histograms; compare before/after on HTTP request path. v2 parser bench: `docs/perf/v2_parse.lua`; perf log: `docs/perf/log.md`
- [ ] Write buffering — HTTP response assembly currently does many small `sock:send()` calls; gather into an iovec or corked buffer before flushing (TCP_CORK / TCP_NOPUSH via setsockopt FFI)
- [ ] Zero-copy static file serving — `sendfile(2)` FFI wrapper for staticx; avoids read-into-Lua-string + write round-trip; meaningful for large files
- [ ] `writev` / scatter-gather — single syscall for header + body chunks; pairs with write buffering above; FFI wrapper + iovec builder helper
- [ ] Buffer pool — reusable fixed-size byte buffers (FFI `uint8_t[N]`) to eliminate hot-path string allocations in HTTP parser and response serialiser
- [ ] Header serialisation fast path — avoid `table.concat` + string interning on every response; pre-serialise static headers once, memcpy into buffer
- [ ] Profile-guided allocation reduction — run under `jit.p` / `jit.dump` to find top allocation sites before committing to specific optimisations

## testing

### property testing (`lib/test/prop.lua`)
- [x] QuickCheck-style property runner: `prop.check(desc, gen, fn)` / `prop.it(desc, gen, fn)` — 2026-03-11 (commit a5c2799)
- [x] Core generators: `gen.int(min, max)`, `gen.uint`, `gen.float`, `gen.bool`, `gen.byte`, `gen.string`, `gen.list(elem_gen)`, `gen.table(k_gen, v_gen)`, `gen.one_of(...)`, `gen.frequency({weight, gen}...)`, `gen.sized(fn)`, `gen.map(g, fn)`, `gen.filter(g, pred)`, `gen.constant(v)`, `gen.nil_or(g)`, `gen.tuple(gens)`
- [x] Shrinking: binary search on int ranges, element removal for lists/strings, field removal for tables
- [x] N configurable trials (default 100); on failure: print original + shrunk + seed for reproducibility
- [x] Integration with test runner: failures show in the same format as `it()` blocks; property names in output
- [x] Seed override via PROP_SEED env var for deterministic replay

### fuzz testing (`lib/test/fuzz.lua`)
- [x] Corpus-based mutation fuzzer: byte-flip, insert, delete, splice on seed inputs (2026-03-15)
- [x] Coverage-guided mode: track which branches fire (debug.sethook + branch bitmap); prefer mutations that hit new branches (2026-03-15)
- [x] Crash/error detection: wrap target in pcall; distinguish expected errors from panics (2026-03-15)
- [x] Corpus persistence: save interesting inputs to disk; resume across runs (2026-03-15)
- [x] AFL-style queue: round-robin queue; guided mode prioritises inputs that hit new branches (2026-03-15)
- [x] Integration with test runner: `fuzz.it(desc, fn, opts)` — failures appear in standard test output (2026-03-15)
- [x] Two modes: "fast" (pure random, no sethook overhead) and "guided" (coverage-guided) (2026-03-15)
- [ ] Integration with property testing: `prop.fuzz(gen, fn)` — use mutations instead of random generation when a corpus exists
- [ ] Shrinking: mutate + binary-search toward a minimal crashing input (currently reports first crash, not shrunk)

### coverage

Current: `luajit lib/test/cli.lua --coverage` does line coverage via `debug.sethook`. Gaps:

- [ ] **Statement coverage**: count each statement executed (finer than line — multiple stmts per line)
- [ ] **Branch coverage**: track both arms of every `if`/`elseif`/`else`, `and`/`or` short-circuit, `repeat`/`while`/`for` loop entry vs skip — report uncovered branches explicitly
- [ ] **MC/DC (Modified Condition/Decision Coverage)**: each boolean sub-condition independently affects the overall decision; required for aviation/automotive safety standards; needs AST instrumentation or symbolic execution
- [ ] **Path coverage**: enumerate feasible execution paths through a function; exponential in theory, approximate with DFS + budget
- [ ] **Coverage-gated CI**: fail if coverage drops below threshold; report per-file and per-function coverage delta

Branch coverage implementation sketch: instrument the AST (add synthetic nodes around branch points) or use `debug.sethook("l", ...)` + a per-function line→branch-id table derived from the parser. The v2 parser already produces a full AST, so AST instrumentation is the natural path.

### fixture / snapshot testing (`lib/test/fixture.lua`)
- [x] `fixture.run_dir(dir, runner, opts)`: discover `*.input` / `*.expected` pairs; run `runner(input)` → actual; diff vs expected; report failures with unified diff — 2026-03-11 (commit f5e9c7a)
- [x] `UPDATE_SNAPSHOTS=1` / `opts.update` mode: overwrite `.expected` files with actual output (snapshot update workflow)
- [x] Pluggable normalizers: `fixture.normalize.{strip_ws, crlf, sort_lines, compose}`
- [x] Binary fixture support: hex-dump diff on mismatch when content has non-printable bytes
- [x] Named fixture groups: `fixture.group(name, dir, runner)` wraps `run_dir` in describe
- [x] `fixture.check(in, exp, runner, opts)` — low-level single-fixture check without it() registration
- [x] `fixture.diff(expected, actual)` — LCS unified diff (pure Lua, O(n*m), capped at 600 lines)

## infra
- [ ] Formalize code style conventions — don't assume ~/git/lua conventions are correct, decide fresh
- [ ] `cr` binary entry point
- [ ] Third-party libs under lib/ must preserve original LICENSE

## LSP
- [x] LSP server (JSON-RPC over stdio) — `lib/type/static/lsp.lua`; stdio framing, initialize/shutdown/exit, textDocument/didOpen+didChange+didSave+didClose → publishDiagnostics. Full text sync. (2026-03-15)
- [x] Position → type query — `ctx.type_at` flat array {line,col,tid,...} populated by `infer_expr`; `type_at_lookup` in lsp.lua finds best match; `textDocument/hover` returns markdown type string. (2026-03-15)
- [ ] Incremental re-check — cheap scope invalidation so full reparse isn't needed on every keystroke
- [ ] Module-level type cache — avoid re-typechecking stdlib/imports on every edit; currently `check.clear_cache()` on every file change is correct but slow for large projects
- [x] Completion — scope-level name enumeration (module + stdlib + locals visible at module level); cursor-local scope completions need position-tracking infrastructure not yet built. (2026-03-15)
- [x] Completion: field completions after `foo.` — extract identifier before trigger, resolve in scope, enumerate table fields. (2026-03-15)
- [x] Completion: union/intersection field completions — table_field_items recurses into TAG_UNION/TAG_INTERSECTION members. (2026-03-15)
- [x] Go-to-def — `ctx.def_sites` (name_id → {line,col}) + `ctx.name_at` for identifier use positions; textDocument/definition handler in lsp.lua. (2026-03-15, within-file only; cross-file requires cri_loader integration)
- [x] Cross-file go-to-def for `require()` bindings — `ctx.require_sources` (name_id → module_name string) populated whenever `local x = require("mod")` is inferred. LSP go-to-def resolves module name to .lua / /init.lua file path and navigates there. Uses `rootUri`/`rootPath` from initialize. (2026-03-15)
- [x] Cross-module type resolution in LSP — `check.check_string_with_deps` added; resolves require() deps one level deep from disk (tries .lua then /init.lua). LSP uses this so hover/completions reflect actual module export types. (2026-03-15)
- [x] Signature help — `textDocument/signatureHelp` on `(` and `,` triggers; extracts callee from line prefix (simple, field, method calls), looks up function type in scope, returns SignatureInformation. (2026-03-15)
- [x] Cross-file go-to-def for fields — `x.bar` where x is a required module: navigate to where `bar` is defined in the module. Implemented via ctx.field_at flat array (stride 4: line/col/field_id/obj_id) populated in ExprRule[NODE_FIELD_EXPR]; find_field_in_ctx() scans AST; cross-file interns field name in module pool then scans module AST. (2026-03-15, commit 38f9a07)

## package manager
See `docs/pkg-design.md` for full design.
- [x] `pkg.lua` manifest format + parser — `lib/pkg/manifest.lua` (2026-03-16)
- [x] `crescent.lock` lockfile format + parser (hand-written TOML-like) — `lib/pkg/lock.lua` (2026-03-16)
- [x] Registry HTTP protocol (`pkg.rhi.zone` — simple GET index + tarballs) — curl-based v1 in `lib/pkg/install.lua` (2026-03-16)
- [x] Global cache (`~/.crescent/cache/<name>@<version>/`) — `lib/pkg/install.lua` (2026-03-16)
- [x] Install algorithm: resolve → fetch → link (hardlinks) → write lockfile — `lib/pkg/install.lua` (2026-03-16)
- [x] Lockfile fast path: dep/ name+version check → skip network entirely — `dep_ok` check in `lib/pkg/install.lua` (2026-03-16)
- [x] `--frozen-lockfile` for CI — `opts.frozen` in `lib/pkg/install.lua` (2026-03-16)
- [x] CLI: `cr add / install / remove / update / info` — `lib/pkg/cli.lua` (2026-03-16); `publish` not yet done
- [x] Semver parser (pure Lua, small) — `lib/pkg/semver.lua` (2026-03-16)
- [x] Multi-registry support with priority ordering and per-registry auth — `lib/pkg/config.lua` (2026-03-16)
- [ ] Fork-based parallel fetch with `--jobs=N` (default: CPU count) — v1 fetch is sequential
- [ ] `cr publish` — not yet implemented
- [ ] Package manifest `files` field — declare which files get installed (source only; tests, benchmarks, fixtures, docs stay in the repo). Installed footprint should be just the `.lua` files needed to run. Key to avoiding node_modules-scale bloat when vendoring.

## protocol rewrites — deferred

- [ ] **HTTP/1.1 server rewrite** — async, keep-alive (Connection: keep-alive), persistent connections. Blocked on socket layer rewrite.
- [ ] **HTTP/1.1 client rewrite** — connection pooling, redirect following, proper error recovery.
- [ ] **HTTPS rewrite** — module-level TLS state bug, `ffi.new("FIXME")` in serverx. Blocked on socket + TLS.
- [ ] **HTTP/2** (RFC 9113) — HPACK header compression, binary framing, stream multiplexing, flow control, server push. Major new implementation.
- [ ] **HTTP/3** (RFC 9114) + **QUIC** (RFC 9000) — UDP-based transport, 0-RTT, connection migration. Requires QUIC implementation first.
- [ ] **HTTP trailer fields** (RFC 9112 §7) — currently ignored in stream.lua chunks().
- [ ] **Transfer-Encoding: gzip/deflate** decompression in stream.lua.
- [x] **Path traversal audit** — `lib/http/router/static.lua` and `staticx.lua` use `path.safe_resolve()` (realpath + prefix check). No vulnerabilities found.
- [ ] **WebSocket: permessage-deflate** (RFC 7692) — compression extension.
- [ ] **WebSocket: max frame/message size policy** — currently unbounded, memory exhaustion risk.
- [ ] **WebSocket: client-side** — initiating connections (currently server-side only).
- [ ] **WebSocket: subprotocol negotiation** (RFC 6455 §4.2.2).
- [ ] **DNS: UDP client** (RFC 1035 §4.2.1) — 512-byte limit, TC flag, fallback to TCP.
- [ ] **DNS: EDNS(0)** (RFC 6891) — OPT pseudo-record, larger responses.
- [ ] **DNS: server implementation** — `lib/dns/server.lua` stub exists.
- [ ] **DNS: master file parser** (RFC 1035 §5) — `lib/dns/format_master_file.lua` stub exists.
- [ ] **DNS-over-HTTPS** (RFC 8484), **DNS-over-TLS** (RFC 7858).
- [ ] **Socket layer rewrite** — replace vendored ljsocket with cross-platform `lib/socket/` (POSIX + Winsock FFI). Prerequisite for proper async server, keep-alive, connection pooling.

## stretch goals (low priority, high reward)

- [ ] **Backend framework** (`lib/web/`) — high-quality, typed, idiomatic Lua web framework.
  HTTP server + router (lib/http already exists) + middleware pipeline + request/response types +
  SQLite ORM layer + templating. API inspired by Lapis/Sinatra but first-class crescent types
  throughout. Goal: write a web app in Lua that a Rails/Express developer finds familiar.

- [ ] **Reactive frontend** — Lua implementation + optional TS deployment:
  1. `lib/reactive/` + `lib/reactive_optics/` are self-contained Lua libraries
  2. `lib/lua2ts/` can transpile them to standalone TypeScript (no Rainbow import)
  3. The transpiled TS is API-compatible with Rainbow so it drops into Rainbow-based apps,
     but crescent has zero runtime dependency on Rainbow — not even as an optional dep
  Rainbow (`~/git/rhizone/rainbow/`) is a parallel implementation of the same algebra in TS,
  maintained in the rhi ecosystem. Same relationship as Rust crates ↔ crescent libraries:
  peers, not wrappers. ~90 tests in Rainbow serve as a cross-implementation parity reference.
  TUI variant: `lib/tui/reactive` — same `lib/reactive_optics/` model, terminal renderer.
  Depends on `lib/tui/` and `lib/ansi/` first.
