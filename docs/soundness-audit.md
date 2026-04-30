# Soundness Audit — `lib/type/static/`

Written: 2026-03-15

A soundness gap is a case where the typechecker accepts code that is
demonstrably wrong — a false negative. This document enumerates known gaps,
their severity, and the constraints that make them hard to close.

A false positive (over-rejection) is noted where relevant but is secondary —
the checker is unsound if it misses real errors, not if it occasionally rejects
valid code.

---

## Gap 1 — TAG_VAR permissiveness in `try_unify` — FIXED 2026-03-15

**File:** `unify.lua:601-602` (fixed: ta.tag == TAG_VAR now falls through to false)
**Severity:** Critical (false negative) — **FIXED**

**Fix (session 21):** Changed `try_unify` so that `ta.tag == TAG_VAR` (actual type is a free
unbound variable) no longer returns `true`. Only `tb.tag == TAG_VAR` (expected type is a free
var — needed for generic param instantiation) keeps `return true`. `ta.tag == TAG_ROWVAR` also
kept as `true` for open-table structural matching.

Result: unbound forward-declared variables no longer silently satisfy union/intersection dispatch.
Tests added: "unbound forward-decl variable fails union dispatch" and "unbound variable does not
match intersection overload" in type_test.lua.

---

**Original description (kept for reference):**

```lua
if ta.tag == TAG_VAR or ta.tag == TAG_ROWVAR or
   tb.tag == TAG_VAR or tb.tag == TAG_ROWVAR then return true end
```

`try_unify` is the non-mutating "could these types unify?" predicate used in:

1. **Union-of-function call dispatch** (`infer.lua:1267–1307`) — each union
   member is checked with `try_call_args` which uses `try_unify`. An argument
   whose type is a free `TAG_VAR` trivially satisfies every union member.

2. **Intersection overload resolution** (`infer.lua:1310–1328`) — first
   candidate that passes `try_call_args` wins. Same problem.

**Root cause:** Unannotated function parameters are bound as fresh `TAG_VAR`
(see Gap 2). If that variable hasn't been further constrained by body
inference when the call site is checked, `try_unify` treats it as a wildcard.

**Example:**

```lua
--: f: ((x: string) -> nil) | ((x: number) -> nil)
local function wrong(y) end   -- y is TAG_VAR, unconstrained
f(wrong)   -- should fail: wrong doesn't satisfy either branch
           -- actual: try_unify(TAG_VAR, string) → true, passes
```

**Workaround:** Use annotated functions or declare the variable type explicitly.

**Fix direction:** `try_unify` should treat unbound `TAG_VAR` on the LHS as
"unknown, not yet compatible" and return false (or require the var to have a
bound type). Doing this naively would break legitimate call-site inference, so
it requires distinguishing "inferred var with an upper bound" vs. "free var
with no constraints at all".

---

## Gap 2 — Unannotated function parameters accept any type

**File:** `infer.lua:1556–1567` (parameter binding in `infer_function`)
**Severity:** High (false negative, by design)

Unannotated parameters are bound to fresh `TAG_VAR` type variables. These
variables are then unified with actual argument types at call sites:

```lua
function f(x)        -- x: TAG_VAR 'a
  return x + 1       -- body use constrains 'a → number
end
f("hello")           -- try_unify("hello", 'a) → true (Gap 1)
                     -- then unify binds 'a = string | number → no error
```

This is intentional — the checker infers parameter types from usage. But the
result is that the inferred type accumulates all call-site types, which may
not match what the function body actually requires.

**Interaction with Gap 1:** Union/intersection dispatch is especially
permissive because `try_unify` never rejects a `TAG_VAR` argument.

**Known:** Documented in TODO.md. The correct fix is to require annotations for
"type-safe" code and emit a warning for unannotated params that receive
multiple incompatible types. The `implicit-any` warning catches fully
unconstrained params; cross-call-site mutation catches some cases.

---

## Gap 3 — Covariant/contravariant generics not enforced

**Severity:** High (false negative for generic type parameters)

Generic type parameters (forall vars, `<T>` annotations) have no variance
annotation. The checker instantiates them at call sites by substitution, but
the positions they appear in are not checked for variance:

- A `T` appearing only in return position should be covariant in `T`.
- A `T` appearing only in parameter position should be contravariant.
- Bivariant when in both.

Without enforced variance, code like:

```lua
--:: Container<T> = { get: () -> T, set: (v: T) -> nil }
local c: Container<number> = make_string_container()  -- should fail
```

may silently pass if the structural unification of the table fields succeeds
due to loose var binding.

**Fix direction:** Add variance inference (flow through all param/return
positions) or explicit annotations (`+T` covariant, `-T` contravariant). Low
priority for LuaJIT target where generics are already advisory.

---

## Gap 4 — Recursive types: well-handled, mostly not a gap

**File:** `unify.lua:43–100` (`occurs`), `unify.lua:146–190` (`bind_var`), `types.lua:660–699`
**Severity:** Very low

`bind_var` has an `occurs()` check. `display()` has a `seen` cycle guard for
tables (lines 660–699: `if seen[tid] then return "{...}" end`).

**Remaining edge case:** Mutual recursion via non-table types (e.g., two function
types pointing to each other) is not covered by the table `seen` guard. In practice,
mutual recursive function types are extremely rare in the Lua patterns this
checker handles; this is not a priority.

---

## Gap 5 — `make_intersection` does not deduplicate members

**File:** `types.lua:384–408`
**Severity:** Low (correctness, not soundness)

Unlike `make_union` (which has a `seen` dedup table), `make_intersection` only
flattens nested intersections and skips `TAG_ANY`. Duplicate members accumulate:

```lua
-- make_intersection({T_NUMBER, T_NUMBER}) → { number & number }
-- not: { number }
```

This inflates arena size and can affect equality checks that compare
intersection types structurally. Not a soundness issue (wrong code is still
rejected), but wastes space and may cause spurious type-display noise.

**Fix:** Add a `seen` table in `make_intersection`, same pattern as `make_union`.

---

## Gap 6 — Function arity: nil-padding in unify

**File:** `unify.lua:362–383`
**Severity:** Low (by-design Lua semantics)

When two function types have different arities, missing parameters are padded
with `T_NIL` before the contravariant check:

```lua
-- f: (x: string) -> T  vs  g: () -> T
-- unify f <: g: checks unify(T_NIL, string) → FAIL (correct)
-- unify g <: f: checks unify(string, T_NIL) → FAIL (correct)
```

This correctly rejects plain mismatches. However, for optional parameters
(`string?` = `string | nil`):

```lua
-- f: (x: string?) -> T  vs  g: () -> T
-- unify g <: f: checks unify(string?, T_NIL) ...
--   → unify(string|nil, T_NIL) — each union member must assign to nil
--   → string <: nil → FAIL (correct: g doesn't accept string arg)
```

Lua's actual runtime semantics allow calling any function with fewer args
(extras become nil). The type system models this correctly via `string?`
parameters. The only soundness gap is that the type system does not emit a
warning when a function with required params is called with optional-param
expectations — this is acceptable given Lua's dynamic nature.

---

## Gap 7 — Narrowing does not track literal integers per-file

**File:** `narrow.lua`, `types.lua`
**Severity:** Low (incompleteness, not unsoundness)

`LIT_INTEGER` literals use their numeric value as `data[1]` (int32). Two
separate references to the same integer literal in the same file produce the
same `LIT_INTEGER` type and compare equal. However, integer literal types
created from different `ctx` instances (e.g., cross-file) are not canonicalized
— they compare by pointer, not by value.

This means `x == 5` narrowing works within a file but cross-file literal
comparisons may not narrow correctly.

**Impact:** Low — cross-file narrowing by integer literal is uncommon. Deferred
until `.cri` format fully supports literal type serialization.

---

## Gap 8 — `local x --: T = expr` does not enforce the subtype check — FIXED

**Status:** Fixed (incidental side-effect of Gap 10 parser totality work,
commit `4d711af`). Regression tests live in
`lib/type/static/type_soundness_test.lua` under `"Gap 8: annotated local-init
enforces subtyping"`.

**Resolution.** The originally-reported syntax `local x --: T = expr` is now a
parse error: the annotation parser is total and rejects the trailing `= expr`
content as not part of the annotation (this is exactly what Gap 10 was about).
The canonical equivalent — a leading `--: T` line above `local x = expr` —
emits `C_SUB(typeof(expr), T)` and is solved by `unify` like any other
subtype check. The asymmetry the gap described ("local form silently passes
where function-return form errors") no longer exists because the buggy syntax
no longer parses, and the surviving `--: T \n local x = expr` form was
already correctly enforced by `unify.lua:283-294` (TAG_UNKNOWN target accepts
anything, TAG_UNKNOWN actual rejects with "must be narrowed").

All four originally-documented repros now error: literal mismatch, variable
mismatch, function-return mismatch, and unknown source. See the regression
tests for verbatim coverage.

**Original report follows for archival reference.**

**File:** `constrain.lua:2440` (the `C_SUB(rhs_tid, ann_tid)` emission for
annotated locals).
**Severity:** High (false negative; broad)

**Repro 1 (literal mismatch):**

```lua
local x --: integer = "hello"   -- accepted; should error
```

**Repro 2 (variable mismatch):**

```lua
local s --: string = "hi"
local x --: integer = s         -- accepted; should error
```

**Repro 3 (function call mismatch):**

```lua
local function f() --: () -> string return "hi" end
local x --: integer = f()       -- accepted; should error
```

**Repro 4 (`unknown`):**

```lua
--:: declare get_unk = () -> unknown
local y --: integer = get_unk() -- accepted; should error
```

The cast form catches all four — `local x = --[[: integer]] "hello"`,
`--[[: integer]] s`, `--[[: integer]] f()`, `--[[: integer]] get_unk()`
each correctly produce a type error. Both code paths emit
`C_SUB(typeof(expr), T)` in `constrain.lua`, but the local-annotated form
silently passes. Function return annotations (`local function f() --: () -> T`)
also enforce correctly. So the bug is specific to the `local x --: T = ...`
constraint emission or its solving path.

**Already noted as a gotcha** in `lib/type/static/CLAUDE.md` ("annotation
enforcement gotcha"): the workaround for tests is to use a function-return
annotation. But it's not just a testing inconvenience — it's a real soundness
hole and should be fixed, not worked around.

**Why fuzzers missed it:** the annotation-soundness invariants in
`fuzz_test.lua` use function return annotations as the harness for structural
equivalence assertions. The local-init path is not exercised. Add an
invariant that uses `local x --: T = expr_of_type_U` and asserts the
expected error iff `U </: T`. Also, `fuzz_arb.lua`'s type generator does not
produce `unknown` (see `lib/type/static/CLAUDE.md` "Generator coverage") —
adding it would extend coverage to the unknown-specific case (Repro 4).

**Status:** Open. Three follow-ups:
1. Find and close the bypass path in the local-init `C_SUB` so all four repros error.
2. Add a fuzz invariant exercising `local x --: T = expr` annotation enforcement.
3. Add `unknown` to `fuzz_arb.lua`'s type generator.

---

## Gap 9 — `local x --: T` (no initializer) silently accepted — FIXED

**Status:** Fixed. The rejection rule documented under "Expected behaviour"
below is now in effect: `local x --: T` (no initializer) errors when
`nil` is not a subtype of `T`. Regression tests live in
`lib/type/static/type_soundness_test.lua` under `"Gap 9: annotated local
without initializer requires nil ∈ T"`.

**Resolution.** `constrain.lua` `StmtRule[NODE_LOCAL_STMT]` now checks, for
the no-initializer + annotated case, whether `nil <: ann_tid` via
`unify_mod.try_unify(ctx, ctx.T_NIL, ann_tid)`. If false, the declaration
emits `E.LOCAL_NEEDS_INIT` with a message naming the variable, the declared
type, and the suggested fixes (`T | nil` or initializer). `unknown` and
`any` both contain nil, so existing patterns like
`local advapi32 --: any` and `local tls_lib --: unknown` continue to work.

The repo-wide cleanup found zero new violations in non-test source: the
previously-existing `local x --: T` sites all used `unknown`, `any`, or
already had `| nil`. Test fixtures were migrated en masse: most tests that
used `local x --: T` as a type-anchor for a probe `x` were converted to
either `--: T \n local x = <init>` (when an initializer makes sense) or
`--:: declare x = T` (when the test only needs the symbol to be in scope).

**Original report follows for archival reference.**

**File:** `constrain.lua` around line 2440 (same code path as Gap 8: annotated local binding).
**Severity:** High (false negative; same family as Gap 8)

**Repro:**

```lua
local y --: integer
print(y + 1)   -- typechecks; runtime: attempt to perform arithmetic on local 'y' (a nil value)
```

The annotation declares `y: integer`, but with no initializer the runtime
value is `nil`. The checker accepts every subsequent read of `y` as if it were
an `integer`. This is the same family as Gap 8 — an annotated local binding
whose declared type is not enforced against the actual binding — and likely
shares the same code path in `constrain.lua` near line 2440.

### Exacerbated by Gap 10 (parser bug)

The line *looks like* an annotated assignment but isn't. Lua `--` runs to
end-of-line, so `local y --: integer = x` parses as `local y` (no
initializer) plus a comment `--: integer = x`. The annotation parser then
silently accepts `integer = x` as a valid annotation — see Gap 10. Until
that parser bug is fixed, programmers writing what they think is "annotated
assignment" silently land in this no-initializer gap with no diagnostic.

The correct annotated-assignment forms are:

```lua
local y = --[[: integer]] x         -- block-comment cast
local y --:: ann_decl_local         -- not yet implemented
```

…neither of which most authors will reach for first. The `local y --: T = x`
form is the obvious thing to type, parses without complaint, and silently
breaks. Until Gap 10 is fixed, this is a footgun *that looks like correct
code* — but Gap 10 is itself a parser bug, not a fundamental syntax trap.

**Expected behaviour:** match TypeScript's definite-assignment analysis —
reject reads of `local y --: T` (no initializer) before assignment. The
practical first step is the strictly-weaker rule "reject the declaration when
`nil` is not in `T` and there is no initializer". Full TS-style flow analysis
(allowing the declaration but tracking definite assignment along each path)
is out of scope for an immediate fix.

A weaker fallback would be to widen the declared type to `T | nil` so reads
must narrow before use. This matches Lua's runtime semantics but loses the
intent the annotation expressed; prefer rejection.

**Status:** Open. Fix together with Gap 8 and Gap 10 (Gap 10 is
load-bearing — fixing Gap 9 alone still leaves silent-mis-parse cases
because Gap 10 means the trailing `= x` is dropped before Gap 9's check ever
runs).

---

## Gap 10 — Parser silently accepts invalid syntax in `--:` annotations

**File:** `ann.lua:1153–1155` (the `ANN_TYPE` branch returns immediately after
`parse_type(s)` without checking for end-of-input).
**Severity:** High (parser accepts ill-formed input)

**Repro:**

```lua
local y --: integer = "string literal"     -- 0 errors
local y --: integer ! ! ! garbage          -- 0 errors
local y --: integer = totally_undefined    -- 0 errors
```

`integer = x` is **not a valid type expression**. The annotation grammar for
`--:` is a single type, period. But `parse_type` consumes the valid prefix
(`integer`), returns, and the rest of the annotation content (`= "string
literal"`, `! ! ! garbage`, `= totally_undefined`) is silently discarded.
`lex.lua:586–595` captures the entire rest of the source line as
`ann.content`; `ann.lua` then parses one type and returns without checking
that the scanner reached the end of that content.

This is a parser bug, plain and simple: the parser must reject what it
cannot understand. Accepting a valid prefix and ignoring the rest violates
that invariant. It is not a "syntax trap" — calling it a trap implies the
syntax is valid-but-misleading; the syntax is in fact invalid and the parser
is wrong to accept it.

It also makes Gap 9 dangerous: the user's `= x` is consumed by the line
comment, the annotation parser silently accepts the malformed `integer = x`,
and the result is a no-initializer declaration with no diagnostic. A correct
parser would emit "unexpected `=` after type annotation" and the user would
immediately see that `--: T = x` does not mean what they thought.

**Expected behaviour:** REJECT with a parse error pointing at the first
unexpected token after the parsed type. No warning-instead-of-error, no
weaker fallback — the annotation is syntactically invalid and the diagnostic
must say so.

**Fix:** in `ann.lua` after `parse_type(s)` for `ANN_TYPE` (and analogously
for `ANN_TYPE_ARGS` / the type tail of `ANN_DECL` / `--:: declare` /
`--:: newtype`), assert the scanner has consumed all non-whitespace content
and emit a parse error pointing at the unexpected token otherwise.

**Status:** Open. Fix before or together with Gap 9 — fixing Gap 9 alone
still leaves the silent-mis-parse path in place.

---

## Gap 11 — `--[[: any]] expr` launders any type, including `unknown`

**File:** `constrain.lua:2138-2147` (cast emits `C_SUB(inner, cast_tid)` and
returns `cast_tid`); `unify.lua:269-276` (`TAG_ANY` is bilateral — `unify`
returns `true` whenever either side is `any`).
**Severity:** High (false negative; contradicts a documented guarantee)

**Repro:**

```lua
local x --: unknown
x = nil
local n = --[[: any]] x          -- accepted; n: any
local r = n + 1                  -- accepted; runtime: arithmetic on nil
```

The cast `--[[: any]] x` emits `C_SUB(unknown, any)`. In `unify.lua:273-276`
`tb.tag == TAG_ANY` returns `true` unconditionally, so the constraint passes
and the cast expression's surface type becomes `any`. Every subsequent use
treats the value as `any`, which is bilaterally assignable to anything —
including `integer` for the arithmetic check.

This contradicts the documented invariant in `docs/type-syntax.md`:

> `unknown` cannot be cast away ... Because the cast is a checked subtype
> assertion, it cannot rescue a value of type `unknown`.

The guarantee holds only for *concrete* target types — `--[[: string]] v`
where `v: unknown` is correctly rejected (`unify.lua:287-294`). It does not
hold when the target is `any`, which is the *one* type the user can write to
opt out. The type system treats `any` as a deliberate escape hatch, but the
cast form makes the escape pointwise and silent: a single `--[[: any]]`
launders one expression with no annotation on the surrounding binding to flag
the opt-out.

**Distinct from Gap 8.** Gap 8 is about `local x --: T = expr` not enforcing
the subtype check at all (the constraint emission path is broken). Gap 11 is
about the constraint emitting correctly and `unify` accepting it because
`TAG_ANY` short-circuits. Fixing Gap 8 does not affect Gap 11; fixing Gap 11
does not affect Gap 8.

**Generalisation.** The repro uses `unknown` because it is the most
load-bearing case — the type system's "must narrow" boundary. The same
laundering applies for any source type:

```lua
local s = "hello"
local n = --[[: any]] s          -- n: any
local r = n + 1                  -- accepted; runtime: arith on string
```

Here the user is explicit: they wrote `--[[: any]]`, opting out. That is
defensible. The unknown case is not — `unknown` is the one type whose whole
purpose is to force narrowing, and `--[[: any]]` defeats it without any
warning that the source type was `unknown`.

**Fix direction:** Reject `unknown <: any` in the cast path. Two shapes:

1. *Conservative:* in the cast solver path (`solve.lua:436-450` already
   distinguishes `c[6] == is_cast`), additionally reject when the actual
   widened type is `unknown` and the expected is `any` — emit "cannot cast
   `unknown` to `any`; narrow first". Other paths that emit `C_SUB` to `any`
   (e.g. assignment to an `any`-typed binding) are not the same problem and
   should remain bilateral.
2. *Stricter (recommended):* make `unknown <: any` always fail in `unify`
   regardless of context. `any` is an opt-out the user must declare on the
   *binding* (e.g. `local x --: any`), not on a single use site. This
   matches the spirit of "unknown must be narrowed before use" — `any` is a
   form of "use" and should not be an exit valve.

The stricter fix is consistent with the existing rule in `unify.lua:287-294`
that `unknown <: T` for any concrete `T` is rejected. Treating `any` like
any other concrete `T` for this one check closes the laundering path
without weakening `any`'s general bilateral semantics elsewhere.

**Cross-reference.** Trailing-form casts (`expr --[[: T]]`) do not actually
attach to `expr` — the parser treats the block annotation as a *prefix* cast
on the next simple expression (`parse.lua:282-339`). When a statement
boundary follows, the trailing cast is silently dropped (`parse.lua:689`
clears `_pending_cast_id` before a statement keyword). This is a separate
parser-level footgun: code like `local n = "hello" --[[: integer]]` looks
like a cast on `"hello"` but is a no-op, and `n` binds to `"hello"`. It is
not Gap 11 (which is about the prefix cast's behaviour when target is
`any`); it belongs in a future gap or a `docs/type-syntax.md` clarification.
The current type-syntax doc correctly shows only the prefix form, so users
following the documentation will not hit the trailing-form trap.

**Status:** **FIXED** (2026-04-30, Phase D3 of typechecker hygiene plan).

`unify.lua:M.unify` and `M.try_unify` now reject `unknown <: any` explicitly,
ahead of the bilateral `TAG_ANY` rules. The check applies regardless of the
constraint's origin (cast, parameter pass, return, local-init annotation,
field/index assignment), so every reachable path is closed in one place. The
asymmetric rule is: `any <: unknown` still passes (any is bilaterally
assignable to anything, unknown is the top type), but `unknown <: any` fails
with a "must be narrowed before use" diagnostic that mentions `--[[:! T]]`
as the documented escape hatch.

Regression tests live in `lib/type/static/type_soundness_test.lua` under
`describe("Gap 11: unknown cannot be laundered through any", ...)` and cover
all five reachable paths (cast, callee param, function return, local
annotation, force-cast escape hatch).

Tests at `lib/type/static/type_test.lua:3643` and `:3678` previously asserted
the broken behaviour and have been rewritten to assert rejection.

---

## Not-a-gap: TAG_NAMED permissiveness in try_unify

`unify.lua:603` returns `true` for `TAG_NAMED` on either side. Named types
(newtypes, opaques) are resolved before try_unify in the normal check path, so
this branch applies only to forward-referenced type names that haven't been
resolved yet. It's conservative (assumes a named type might match) and is
replaced by full structural checking once resolution completes.

---

## Priority Summary

| # | Gap | Severity | Impact on user code |
|---|-----|----------|---------------------|
| 1 | TAG_VAR in try_unify | ~~Critical~~ **FIXED** | Union/intersection function dispatch silently passes wrong types |
| 2 | Unannotated params | High | By design; mitigated by implicit-any warnings |
| 3 | Generic variance | High | Type params in generic containers not variance-checked |
| 4 | Recursive types | Medium | Self-referential types may cause display loops |
| 5 | Intersection dedup | Low | Arena bloat, no soundness impact |
| 6 | Function arity nil-padding | Low | Correct for Lua semantics |
| 7 | LIT_INTEGER cross-file | Low | Edge case, deferred |
| 8 | `local x --: T = expr_of_unknown` | ~~High~~ **FIXED** | Resolved as side-effect of Gap 10 parser totality (commit `4d711af`); regression tests in `type_soundness_test.lua` |
| 9 | `local x --: T` (no initializer) | ~~High~~ **FIXED** | TS-style rule: declaration rejected when `nil </: T` and there is no initializer. Diagnostic `E.LOCAL_NEEDS_INIT`. Regression tests under `"Gap 9: annotated local without initializer requires nil ∈ T"` in `type_soundness_test.lua`. |
| 10 | Parser accepts invalid `--:` syntax | High | `--: integer = x` is not a valid type but parser silently accepts the `integer` prefix and drops the rest; enables the Gap 9 footgun |
| 11 | `--[[: any]] expr` launders `unknown` | ~~High~~ **FIXED** | Closed by Phase D3 (2026-04-30): `unify.lua` rejects `unknown <: any` in both `M.unify` and `M.try_unify`; covers cast, param, return, and annotation paths. Force cast `--[[:! T]]` is the documented escape. |

**Recommended fix order:**
1. Gap 5 (trivial: add `seen` table to `make_intersection`)
2. Gap 10 (small, ann.lua: reject when scanner has unconsumed content after parse_type) — must precede or accompany Gap 9
3. Gap 9 (TS-style "no initializer + nil ∉ T → reject" rule in constrain.lua)
4. Gap 11 (small, unify.lua: reject `unknown <: any`)
5. Gap 1 (requires distinguishing constrained vs. unconstrained TAG_VAR in try_unify)
6. Gap 4 (occurs check in bind_var)
7. Gap 3 (variance annotations — design required before implementation)
