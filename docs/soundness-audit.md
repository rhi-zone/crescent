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

## Gap 8 — `local x --: T = expr` does not enforce the subtype check

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

## Gap 9 — `local x --: T` (no initializer) silently accepted

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

### Syntax trap (exacerbating factor)

The line *looks like* an annotated assignment but isn't. Lua `--` runs to
end-of-line, so:

```lua
local y --: integer = x       -- looks like: local y of type integer, initialised from x
```

actually parses as:

- `local y` — declaration with **no initializer**
- `--: integer = x` — line comment; the annotation parser reads the content
  as `integer = x`, the type-parser consumes `integer`, and the trailing `= x`
  is silently dropped (see Gap 10).

So a programmer writing what they think is "annotated assignment" silently
gets the no-initializer form, hits this gap, and `y` is `nil` at runtime
while typed as `integer`. Verified 2026-04-29: even
`local y --: integer = "string literal"` and `local y --: integer ! ! ! garbage`
typecheck with 0 diagnostics.

The correct annotated-assignment forms are:

```lua
local y = --[[: integer]] x         -- block-comment cast
local y --:: ann_decl_local         -- not yet implemented
```

…neither of which most authors will reach for first. The `local y --: T = x`
form is the obvious thing to type, parses without complaint, and silently
breaks. Until Gap 10 is fixed, this is a footgun *that looks like correct
code*.

**Expected behaviour:** match TypeScript's definite-assignment analysis —
reject reads of `local y --: T` (no initializer) before assignment. The
practical first step is the strictly-weaker rule "reject the declaration when
`nil` is not in `T` and there is no initializer". Full TS-style flow analysis
(allowing the declaration but tracking definite assignment along each path)
is out of scope for an immediate fix.

A weaker fallback would be to widen the declared type to `T | nil` so reads
must narrow before use. This matches Lua's runtime semantics but loses the
intent the annotation expressed; prefer rejection.

**Status:** Open. Fix together with Gap 8 and Gap 10 (the syntax trap is
load-bearing — fixing Gap 9 alone still leaves silent-mis-parse cases
because Gap 10 means the trailing `= x` is dropped before Gap 9's check ever
runs).

---

## Gap 10 — Annotation parser silently drops trailing tokens

**File:** `ann.lua:1153–1155` (the `ANN_TYPE` branch returns immediately after
`parse_type(s)` without checking for end-of-input).
**Severity:** High (false negative; enables the Gap 9 syntax trap)

**Repro:**

```lua
local y --: integer = "string literal"     -- 0 errors
local y --: integer ! ! ! garbage          -- 0 errors
local y --: integer = totally_undefined    -- 0 errors (identifier never resolved)
```

After `parse_type` consumes the `integer` token, the scanner still has
content (`= "string literal"`, `! ! ! garbage`, `= totally_undefined`)
that is silently discarded. `lex.lua:586–595` captures the entire rest of
the source line as `ann.content`, then `ann.lua` parses one type and returns.
There is no "expected end of annotation" check.

This is what makes Gap 9 dangerous: the user's `= x` initializer is consumed
by the comment, the annotation parser silently accepts it, and the result is
a no-initializer declaration that nothing flags. Without Gap 10 the user
would at least see "unexpected `=` after type annotation" and realise the
syntax doesn't do what they thought.

**Fix:** in `ann.lua` after `parse_type(s)` for `ANN_TYPE` (and analogously
for `ANN_TYPE_ARGS` / the type tail of `ANN_DECL`), assert the scanner has
consumed all non-whitespace content and emit a diagnostic otherwise.
Comparable check should cover `ANN_DECL` after the trailing type and
`--:: declare` / `--:: newtype` forms.

**Status:** Open. Fix before or together with Gap 9 — fixing Gap 9 alone
still leaves the silent-mis-parse path in place.

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
| 8 | `local x --: T = expr_of_unknown` | High | `unknown` silently passes annotated local-init |
| 9 | `local x --: T` (no initializer) | High | Annotated local with no initializer is `nil` at runtime but typed as `T`; compounded by Gap 10's syntax trap |
| 10 | Annotation parser drops trailing tokens | High | `local y --: T = x` silently parses as no-initializer + dropped `= x`; enables the Gap 9 footgun |

**Recommended fix order:**
1. Gap 5 (trivial: add `seen` table to `make_intersection`)
2. Gap 10 (small, ann.lua: assert scanner end-of-content after parse_type) — must precede or accompany Gap 9
3. Gap 9 (TS-style "no initializer + nil ∉ T → reject" rule in constrain.lua)
4. Gap 1 (requires distinguishing constrained vs. unconstrained TAG_VAR in try_unify)
5. Gap 4 (occurs check in bind_var)
6. Gap 3 (variance annotations — design required before implementation)
