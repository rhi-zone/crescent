# Plan — Typed Accessor Cleanup for `Type.data` and Constraint Payloads

Decomposition of the two cleanup TODOs (added in commit `9599884e`) into a
sequence of small, hook-passing commits.

## Status — COMPLETE (2026-05-17, commit range `a644d0aa`..`dfaf8233`)

The cleanup landed across 14 commits (Phase A: C2–C5; Phase B: C6–C16;
Phase C: C18; C19 sweep) plus 3 prerequisite/by-product bug fixes
(`bb930ab5` FFI element typing, `58d10766` tuple positional-slot fix in
`ann.lua`/`constrain.lua`, `0c2939d2` tuple expression-side fix).

### Outcome vs plan estimates

| Dimension                    | Plan estimate              | Actual                                |
|------------------------------|----------------------------|----------------------------------------|
| Commits                      | 20–24 over ~2 sessions     | 14 cleanup + 3 prerequisite by-products |
| `Type.data` read sites       | ~1580 (table at §1)        | Far fewer — the §1 count conflated reads, writes, Node-arena accesses, and accessors covered by AST-side work |
| Error-count reduction        | "hundreds across the dir"  | ~1300 from FFI fix (`bb930ab5`) alone; ~50 more from C18 cast cleanup in `solve.lua`; tens more across other files |
| Force casts removed (C18)    | (not enumerated)           | 51 in `solve.lua` at migrated payload sites |
| Force casts removed (C19)    | (sweep)                    | 6: solve x4, env x1, unify x1                       |

Final per-file error counts at end of series: types=13, env=3, constrain=31,
solve=38, unify=0.

### Surfaced findings (followup work, not blocking)

- `TAG_TYPE_CALL.data[3]` (stable_id slot) — **§2 updated, accessor added
  (`tycall_stable_id`)**; reads migrated in match.lua, env.lua, solve.lua,
  cri_write.lua. Force casts at env.lua and solve.lua call sites became
  redundant and were removed (1 fewer force-cast error in solve.lua, 1 fewer
  error in env.lua).
- `TAG_VAR.data[3..4]` (skolem `name_id`, `rank_n_call_id`) — **§2 updated,
  accessors added (`var_skolem_name_id`, `var_skolem_call_id`)**; reads
  migrated in unify.lua, env.lua, solve.lua. The two `constrain.lua` write
  sites (and one read paired with a write) remain direct: any accessor use
  there triggers the C14 flow-sensitivity quirk (+5 cascading narrowing
  errors), so the local pattern was kept with an explanatory comment.
- `TAG_FORALL.data[3..4]` (`bounds_start`, `bounds_len`) — **§2 updated,
  accessors added (`forall_bounds_start`, `forall_bounds_len`)**. The single
  `constrain.lua` read site also tripped the C14 flow-sensitivity quirk (+2
  errors), so reads are bound to locals (`bounds_start`, `bounds_len`) but
  kept as direct `at.data[N]` access with a comment.
- Flow-sensitivity quirk: two `TAG_TYPE_CALL` sites in `constrain.lua`
  and five in `solve.lua` triggered cascading errors when migrated to
  accessors; kept as direct `t.data[N]` access with explanatory comments.
  Root cause is likely an `unknown`-tagged accessor return interacting
  with downstream union widening; worth a dedicated investigation.

## Status (historical) — Both prerequisites landed; cleanup unblocked (2026-05-17)

Both prerequisites are now fixed: the FFI fixed-size-array element typing
(below) and the brace-tuple positional-slot typing bug (the C4 blocker
identified in this doc's review pass). The latter was fixed via a parser
change in `ann.lua` (positional brace-tuple entries now emit
`TAG_LITERAL(LIT_INTEGER, N)` keys instead of bare `TAG_NUMBER`) and a
small constraint-routing change in `constrain.lua` NODE_INDEX_EXPR (defers
literal-integer access on TAG_TABLE to `C_INDEX` so `solve_index`'s
slot-aware branch handles it instead of the legacy "first indexer wins"
shortcut). See TODO.md entry for full details.

The FFI-element-typing prerequisite has been fixed. Root cause was in
`lib/type/static/solve.lua` `solve_index`: the LIT_INTEGER branch handled
`TAG_TUPLE` but had no `TAG_TABLE` case, so a `t.data[N]` access on a field
typed as `{ [integer]: T }` fell through to the slot-0-is-self fallback
(`unify(res, obj_tid)`) and bound the result to the whole array type
instead of the element type. Fixed by adding a `TAG_TABLE` branch that
(1) checks for an integer-named positional field, (2) consults
integer/number indexers and returns the value type, (3) preserves the
slot-0-is-self fallback only when neither matches (so multi-return slot
extraction via `local x = require("mod")` still works when `mod`'s return
is a plain TAG_TABLE).

The fix also closed >1000 pre-existing errors across `lib/type/static/`:
constrain.lua 388→38, solve.lua 333→114, types.lua 129→30, env.lua
138→12, unify.lua 144→5, narrow.lua 42→6, match.lua 113→3, intrinsic.lua
50→1, cri_write.lua 176→20, cri_read.lua 53→11. No file gained errors;
all type tests and the full `bin/cr test` suite pass with the same
runtime-failure set as baseline (pre-existing FFI/runtime issues unrelated
to typing).

The discriminant-narrowing prerequisite (§4) was probed and **passes**, so
the constraint-payload half is also viable. The plan below executes as
originally written.

## 1. Verified inventory

Site counts (non-test `lib/type/static/`):

| File          | `.data[` sites | force-cast sites | pre-existing errors |
|---------------|----------------|-------------------|---------------------|
| constrain.lua | 339            | 5                 | 383                 |
| solve.lua     | 227            | 34                | 323                 |
| types.lua     | 137            | 8                 | 112                 |
| env.lua       | 132            | 2                 | 129                 |
| unify.lua     | 124            | 0                 | 140                 |
| parse.lua     | 117            | 6                 | n/a (AST `.data`)   |
| ann.lua       | 89             | 3                 | n/a                 |
| match.lua     | 82             | 2                 | n/a                 |
| narrow.lua    | 69             | 0                 | n/a                 |
| cri_write.lua | 65             | 0                 | n/a                 |
| intrinsic.lua | 52             | 1                 | n/a                 |
| **Total**     | **~1580**      | **~70**           | hundreds            |

**Honesty note on the TODO's "~75 sites" / "+13 errors" claims:** those
numbers are wrong. Actual `t.data[N]`-on-`Type` read sites that produce
typecheck errors today are in the hundreds per file (env.lua alone has 129;
constrain/solve/unify each have 100+). The 75/13 numbers count only the
force-cast sites the rank-N work added; they undercount the latent error
surface. Plan accordingly: multi-week cleanup, not an afternoon.

`parse.lua`, `ann.lua`, `match.lua`, `narrow.lua`, `cri_*.lua`,
`intrinsic.lua` touch `t.data[N]` heavily too. Scope decision in §5.

## 2. `Type.data` slot layout (transcribed from `types.lua:55–123`)

| TAG | d[0] | d[1] | d[2] | d[3] | d[4] | d[5] | d[6] |
|---|---|---|---|---|---|---|---|
| VAR / ROWVAR | var_id | level | parent_tid (-1=unbound) | skolem name_id (only if FLAG_SKOLEM or annotation-introduced FLAG_GENERIC; 0=unset) | rank_n_call_id (only if FLAG_SKOLEM; 0=unset) | — | — |
| LITERAL | lit_kind | str: intern_id; bool: 0/1; num: lo i32 | num: hi i32 | — | — | — | — |
| FUNCTION | params_start | params_len | returns_start | returns_len | vararg_tid (-1) | param_names_start | param_names_len |
| TABLE | fields_start | fields_len | indexers_start | indexers_len | row_var_id (-1) | meta_start | meta_len |
| UNION / INTERSECTION / TUPLE | members_start | members_len | — | — | — | — | — |
| NOMINAL | name_id | identity | underlying_tid | — | — | — | — |
| NAMED | name_id | args_start | args_len | — | — | — | — |
| MATCH_TYPE | param_tid | arms_start | arms_len | — | — | — | — |
| FORALL | type_params_start | type_params_len | body_tid | bounds_start (parallel list; -1 entries = no bound) | bounds_len (== params_len when bounds present; 0=no bounds) | — | — |
| SPREAD | inner_tid | — | — | — | — | — | — |
| INTRINSIC | name_id | — | — | — | — | — | — |
| TYPE_CALL | callee_id | args_start | args_len | stable call-site hash (fnv31; 0=unset) | — | — | — |
| ENUM_MEMBER | enum_name_id | member_name_id | lit_kind | value | — | — | — |
| TYPEOF | name_id | — | — | — | — | — | — |
| CAPTURE | name_id | — | — | — | — | — | — |
| PAT_ALL_FIELDS | k_name_id | v_name_id | — | — | — | — | — |
| PAT_REST_FIELDS | name_id | — | — | — | — | — | — |
| PAT_META_SPREAD | name_id | — | — | — | — | — | — |
| PARTIAL_APP | name_id | list_start | list_len | — | — | — | — |
| INDEX_TYPE | subject_tid | key_tid | — | — | — | — | — |
| Atomics (NIL, BOOL, NUM, STR, ANY, NEVER, INT, UNKNOWN, CDATA, FFIC) | — | — | — | — | — | — | — |

**Rank-N additions:** TAG_VAR with FLAG_SKOLEM stores its `name_id` in
data[3] and the per-call `rank_n_call_id` in data[4] (see TAG_VAR row above).
Annotation-introduced FLAG_GENERIC TVs also use data[3] for their source
name (used by `collect_rank_n_generics` to distinguish them from
HM-generalized TVs). The `C_ESCAPE_CHECK` constraint payload also carries a
call_id (slot 2) that is matched against the skolem's data[4] at solve time.

## 3. C_TAG payload layout (transcribed from `constrain.lua:125–159`)

All payloads have `c[1] = C_TAG`. Common tail: `line, col` (last 2).

| C_TAG | c[2] | c[3] | c[4] | c[5] |
|---|---|---|---|---|
| C_UNIFY | t1 | t2 | line | col |
| C_SUB | actual | expected | line | col |
| C_CALLABLE | callee_tid | arg_tids_list_id | ret_tid | line, col |
| C_ARITH | op_str | lhs_tid | rhs_tid | result_tid, line, col |
| C_RETURN | val_tid | expected_tid | line | col |
| C_COMPARE | lhs_tid | rhs_tid | line | col |
| C_INDEX | obj_tid | key_tid | result_tid | line, col |
| C_BOUND | fresh_tv_id | bound_type_id | line | col |
| C_OR | left_tid | right_tid | result_tid | line, col |
| C_BIND_GENERICS | callee_tid | arg_tids_list | ret_tid | line, col |
| C_CHECK_ARGS | callee_tid | arg_tids_list | ret_tid | line, col |
| C_OVERLAP | actual | expected | line | col |
| C_NARROW_NIL | input_tid | result_tid | keep_nil | line, col |
| C_ESCAPE_CHECK | ret_tid | call_id | line | col |

`C_ARITH.c[2]` is a string, not an integer — the existing tuple type
`{[integer]: unknown}` is the only way that shape parses today. Typed
accessors will need non-homogeneous tuples, e.g. `{integer, string,
integer, integer, integer, integer, integer}`.

## 4. Accessor naming scheme

**Style:** module-local functions in `types.lua` (for `Type.data`) and
`constrain.lua` (for payloads). Co-located with the layout comment.
One-line bodies; LuaJIT inlines.

**Naming:** `<tag-shortname>_<slot-meaning>`, lowercase. Reader form only —
writers continue with direct `t.data[N] = v` since assignment has no
type-check pressure.

### `Type.data` accessors (~60 functions)

```
-- VAR / ROWVAR (shared body)
var_id, var_level, var_parent
-- LITERAL
lit_kind, lit_str_id, lit_bool, lit_num_lo, lit_num_hi
-- FUNCTION
fn_params_start, fn_params_len,
fn_returns_start, fn_returns_len, fn_vararg,
fn_param_names_start, fn_param_names_len
-- TABLE
tbl_fields_start, tbl_fields_len,
tbl_indexers_start, tbl_indexers_len,
tbl_row_var, tbl_meta_start, tbl_meta_len
-- UNION / INTERSECTION / TUPLE (shared)
agg_members_start, agg_members_len
-- NOMINAL
nom_name_id, nom_identity, nom_underlying
-- NAMED
named_name_id, named_args_start, named_args_len
-- MATCH_TYPE
match_param, match_arms_start, match_arms_len
-- FORALL
forall_params_start, forall_params_len, forall_body
-- SPREAD
spread_inner
-- INTRINSIC
intrinsic_name_id
-- TYPE_CALL
tycall_callee, tycall_args_start, tycall_args_len
-- ENUM_MEMBER
enum_name_id, enum_member_id, enum_lit_kind, enum_value
-- TYPEOF / CAPTURE / PARTIAL_APP / pat_* / INDEX_TYPE
typeof_name_id, capture_name_id,
pat_all_k_id, pat_all_v_id,
pat_rest_name_id, pat_meta_name_id,
partial_name_id, partial_args_start, partial_args_len,
index_subject, index_key
```

Each declared `--: (TypeSlot) -> integer`.

### Constraint payload accessors (~50 functions)

```
unify_lhs, unify_rhs, unify_line, unify_col
sub_actual, sub_expected, sub_line, sub_col
callable_callee, callable_args_list, callable_ret, callable_line, callable_col
arith_op, arith_lhs, arith_rhs, arith_result, arith_line, arith_col
return_val, return_expected, return_line, return_col
compare_lhs, compare_rhs, compare_line, compare_col
index_obj, index_key, index_result, index_line, index_col
bound_tv, bound_type, bound_line, bound_col
or_left, or_right, or_result, or_line, or_col
bindgen_callee, bindgen_args, bindgen_ret, bindgen_line, bindgen_col
checkargs_callee, checkargs_args, checkargs_ret, checkargs_line, checkargs_col
overlap_actual, overlap_expected, overlap_line, overlap_col
narrowNil_input, narrowNil_result, narrowNil_keep, narrowNil_line, narrowNil_col
escape_ret, escape_call_id, escape_line, escape_col
```

Constraint payload accessors must be typed against per-C_TAG tuple types.
Define a named alias per C_TAG:

```lua
--:: ConstraintUnify = { integer, integer, integer, integer, integer }
--:: ConstraintArith = { integer, string, integer, integer, integer, integer, integer }
-- ...
```

Constructors (e.g. `M.make_unify`) build the tuple; the solver dispatch
(`if c[1] == C_UNIFY then ...`) narrows by discriminant, then the typed
accessors are valid. **This requires the typechecker to narrow on `c[1] ==
LITERAL_INT` for tuple shape selection.** If it doesn't, that's a
typechecker bug per CLAUDE.md and must be fixed first.

### Pre-cleanup blocker check

Before commit 0 of the cleanup proper, run this on `bin/cr check`:

```lua
--:: A = { 1, integer }
--:: B = { 2, string }
--: (c: A | B) -> nil
local function f(c)
    if c[1] == 1 then
        local _x --: integer = c[2]  -- must typecheck
    else
        local _y --: string = c[2]   -- must typecheck
    end
end
```

If it fails, **stop the cleanup and file a discriminant-narrowing bug
instead.** The constraint-payload half (C3–C5, C17, C18 below) depends on
it; the `Type.data` half does not.

## 5. Commit decomposition

Realistic: **20–24 commits over ~2 sessions of focused work.** Target
~100 sites per migration commit; split if a file exceeds 300 lines diff.

### Phase A — accessor introduction (no migration)

- **C1** — `types(static): document Type.data slot layout in header`. Header
  comment already exists at lines 55–123; add rank-N additions paragraph.
  ~20 lines. Touches: `types.lua`.
- **C2** — `types(static): add typed Type.data accessors`. ~60 accessors
  from §4, added to `types.lua`, exported on `M`. No migration. ~150 lines
  additive.
- **C3** — `constrain(static): add typed per-C_TAG tuple aliases`. ~80
  lines.
- **C4** — `constrain(static): add typed payload accessors`. ~50 accessors,
  ~120 lines additive.
- **C5** — `constrain(static): route constructors through typed builders`.
  Modify `M.make_unify`, `M.make_sub`, etc. (if they exist; otherwise
  inline `{C_UNIFY, ...}` literals) to return values typed as the new
  aliases. ~60 lines. Expect 0–10 producer-site fixes.

### Phase B — `Type.data` migration (one commit per file, smallest first)

- **C6** — `narrow.lua` (69 sites)
- **C7** — `match.lua` (82 sites)
- **C8** — `ann.lua` (89 sites)
- **C9** — `intrinsic.lua` (52 sites)
- **C10** — `parse.lua` (117 sites) — **careful**: operates on AST `.data`
  too (different struct). Filter to Type-arena sites only; defer the file
  if AST sites dominate.
- **C11** — `unify.lua` (124 sites)
- **C12** — `env.lua` (132 sites) — closes ~80 of the 129 pre-existing
  errors. Split `C12a`/`C12b` if diff exceeds 300 lines.
- **C13** — `types.lua` self-migration (137 sites) — touch last; don't
  recursively self-reference accessors. Likely `C13a`/`C13b`.
- **C14** — `constrain.lua` Type.data sites (subset of 339)
- **C15** — `solve.lua` Type.data sites (subset of 227)
- **C16** — `cri_read.lua`, `cri_write.lua`, `cdef.lua` mop-up

### Phase C — constraint payload migration

- **C17** — `constrain.lua` payload sites. ~150 lines diff.
- **C18** — `solve.lua` payload sites (54 reads + 34 force-casts). Split
  `C18a`/`C18b` if exceeds 300 lines.

### Phase D — closeout

- **C19** — Force-cast sweep (clean any remaining `--[[:! integer]]` casts).
- **C20** — Update TODO.md: check off both items, link to this plan, note
  commit range.

## 6. Migration risks (latent bugs the indexer hides)

Sites to scrutinize:

1. **`env.lua:427`** — `for k = 0, 6 do rrt.data[k] = nrt.data[k] end`
   polymorphic clone, not per-tag access. Keep direct `.data[k]` with a
   justifying comment.
2. **`intrinsic.lua:82-83`** — context-dependent struct field copy. Verify
   tags before migrating.
3. **`solve.lua:255`** — `intrinsic_mod.expand(...)` returns `unknown` and
   gets force-cast. Migration needs `expand`'s return type fixed too;
   out-of-scope. Leave cast + add TODO.
4. **`solve.lua:400,407`** — `fe.type_id`, `fe.flags` are FieldEntry FFI
   struct fields, not Type.data. Different struct. Out of scope.
5. **Any site reading `data[N]` for N not in §2 for that tag** — bugs
   masked by the indexer. Migration will surface them as type errors. List
   in the commit message and fix the root cause; do NOT paper over with
   `--[[:! T]]`.

## 7. Test files: out of scope

`lib/type/static/*_test.lua` files probably contain small white-box `.data`
access for assertions. Tests run against the public API; if a test pokes
at internals, it's testing implementation. Leave them. If a test breaks
during migration (signature change on `M.make_unify`, etc.), fix in the
same commit as the producing change.

## 8. First-commit specification (C2 — drop-in)

**Title:** `types(static): add typed Type.data accessors`

**File:** `lib/type/static/types.lua`

**Insertion point:** after `M.alloc_type` (line 202), before `M.find`
(line 210). New section comment: `-- Typed Type.data accessors. One per
slot per tag. LuaJIT inlines.`

**Body:** the 60 functions from §4 under "Type.data accessors", each as a
one-liner:

```lua
--: (TypeSlot) -> integer
function M.var_id(t) return t.data[0] end
--: (TypeSlot) -> integer
function M.var_level(t) return t.data[1] end
--: (TypeSlot) -> integer
function M.var_parent(t) return t.data[2] end
-- ... and so on for all 60
```

**Migration:** none. Strictly additive.

**Verify:**
1. `timeout 30 bin/cr check lib/type/static/types.lua` — error count must
   equal HEAD (currently 112). New accessors should add no errors. If any
   do, the slot type is wrong (likely the slot is `integer | nil` because
   the layout doc lies, or the C struct field isn't `int32_t`). Fix the
   doc, not the accessor.
2. `bin/cr test` — full suite green.
3. `git diff --stat` — should show only `lib/type/static/types.lua`
   modified, ~+150 lines.
4. **Pre-commit hook must pass without `--no-verify`.**

## Total commit count, blockers

- **Estimated commits:** 20–24 (not the 5–12 the TODO suggested).
- **Blockers preventing start today:**
  1. The discriminant-narrowing-on-tuple repro in §4 must typecheck. If it
     doesn't, the constraint-payload half (C3–C5, C17, C18) is blocked on
     a typechecker bug-fix. The `Type.data` half is unblocked regardless.
  2. The `parse.lua` AST vs Type ambiguity needs a quick categorization
     pass before C10 — could push C10 to "skip" if AST-dominant.

## Critical files for implementation

- `lib/type/static/types.lua`
- `lib/type/static/constrain.lua`
- `lib/type/static/solve.lua`
- `lib/type/static/env.lua`
- `lib/type/static/defs.lua`
