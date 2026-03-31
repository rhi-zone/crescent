# Crescent Typechecker — Formal Semantics

Semi-formal specification of the type system. Each rule is precise enough
that two implementers reading it independently would write the same code.
This is the ground truth for the fuzz suite and for delegation.

See `docs/type-system.md` for *why* these choices were made. This document
defines *what* the rules are.

---

## 1. Types

Every type is represented as a slot in a flat arena (`TypeSlot`, 32 bytes).
The `tag` field determines the kind; `data[0..3]` carry kind-specific
payload. All type IDs are arena indices (integers ≥ 1).

### 1.1 Tag Reference

| Tag | Constant | Description |
|-----|----------|-------------|
| 0  | `TAG_NIL`          | The nil type. No data. |
| 1  | `TAG_BOOLEAN`      | Boolean type. No data. |
| 2  | `TAG_NUMBER`       | Float/number type. No data. |
| 3  | `TAG_STRING`       | String type. No data. |
| 4  | `TAG_ANY`          | Bilateral escape hatch. Assignable to/from everything. |
| 5  | `TAG_NEVER`        | Bottom type. Assignable to all; nothing assignable to it. |
| 6  | `TAG_INTEGER`      | Integer type (subtype of number). No data. |
| 7  | `TAG_UNKNOWN`      | Top type. Everything assignable to it; must narrow before use. |
| 8  | `TAG_LITERAL`      | Singleton literal type. See §1.2. |
| 9  | `TAG_FUNCTION`     | Function type. See §1.3. |
| 10 | `TAG_TABLE`        | Table type with fields, indexers, row var. See §1.4. |
| 11 | `TAG_UNION`        | Disjunction A\|B. See §1.5. |
| 12 | `TAG_INTERSECTION` | Conjunction A&B. See §1.5. |
| 13 | `TAG_VAR`          | Unbound type variable. See §1.6. |
| 14 | `TAG_ROWVAR`       | Open-table row variable. See §1.6. |
| 15 | `TAG_TUPLE`        | Ordered fixed-length heterogeneous tuple. See §1.7. |
| 16 | `TAG_NOMINAL`      | Identity-based (opaque/newtype) type. See §1.8. |
| 17 | `TAG_MATCH_TYPE`   | Match/dispatch type alias. |
| 18 | `TAG_INTRINSIC`    | Compiler-supported intrinsic type operation. |
| 19 | `TAG_TYPE_CALL`    | Unapplied generic type constructor call. |
| 20 | `TAG_FORALL`       | Universally quantified type `<T> ...`. |
| 21 | `TAG_SPREAD`       | Spread field marker `{ ...T }`. data[0] = inner type ID. |
| 22 | `TAG_NAMED`        | Unresolved alias reference (resolved during annotation pass). |
| 23 | `TAG_CDATA`        | FFI cdata (opaque; always compatible). |
| 24 | `TAG_ENUM_MEMBER`  | Enum table member. See §1.9. |
| 25 | `TAG_TYPEOF`       | Deferred identifier type-of lookup. |
| 26 | `TAG_FFIC`         | FFI C table (resolved from ffi.cdef call sites). |
| 27 | `TAG_CAPTURE`      | Pattern-position capture variable `%Name`. Matches anything; binds in match result. |
| 28 | `TAG_PAT_ALL_FIELDS` | `{ ...[%K]: %V }` pattern: distributes over all fields; K binds key type, V binds value type. |
| 29 | `TAG_PAT_REST_FIELDS` | `{ ...[%Rest] }` pattern: rest-field capture in table pattern position. |
| 30 | `TAG_PAT_META_SPREAD` | `{ #...%M }` pattern: captures all meta slots of input as a table. |
| 31 | `TAG_PARTIAL_APP`  | Partially-applied generic alias `Alias<A>` with fewer args than required. |

Tags 27–31 are **annotation-arena-only** (pattern AST nodes produced by the annotation
parser; TAG_CAPTURE, TAG_PAT_ALL_FIELDS, TAG_PAT_REST_FIELDS, TAG_PAT_META_SPREAD are
never written to the main type arena). TAG_PARTIAL_APP appears in the type arena as a
deferred instantiation resolved during solve.

### 1.2 TAG_LITERAL

Singleton type representing exactly one value.

```
data[0] = LIT_kind
data[1] = value (kind-dependent)
data[2] = value_hi (LIT_NUMBER only)
```

| Kind | Constant | Value encoding |
|------|----------|----------------|
| 0 | `LIT_STRING`     | `data[1]` = intern ID of the string |
| 1 | `LIT_NUMBER`     | `data[1..2]` = int32×2 encoding of a float64 (`i32x2_to_double`) |
| 2 | `LIT_BOOLEAN`    | `data[1]` = 0 (false) or 1 (true) |
| 4 | `LIT_INTEGER`    | `data[1]` = int32 value (globally comparable, not a float) |
| 5 | `LIT_OPAQUE_KEY` | `data[1]` = intern ID of the opaque key variable name |

Two literals are equal iff kind is equal AND `data[1]` equal (AND `data[2]`
equal for LIT_NUMBER).

### 1.3 TAG_FUNCTION

```
data[0] = param list start (list pool index)
data[1] = param count
data[2] = return list start
data[3] = return count
data[4] = vararg type ID, or -1 if none
data[5] = param name IDs list start (intern IDs, for error messages)
data[6] = param name count
```

Each entry in the param/return lists is a type ID. Returns are always
wrapped in TAG_TUPLE by the solver (see §4).

### 1.4 TAG_TABLE

```
data[0] = field list start (list pool index of FieldEntry arena IDs)
data[1] = field count
data[2] = indexer list start (alternating key-type, value-type pairs)
data[3] = indexer count (number of key-value pairs, so list length = 2×count)
data[4] = row variable type ID (TAG_ROWVAR), or -1 if closed
data[5] = meta field list start
data[6] = meta field count
```

**FieldEntry** (12 bytes, separate arena):
```c
int32_t name_id;   // intern ID, or -1 for spread placeholder
int32_t type_id;
uint8_t flags;
```

Field flags:
- `FLAG_OPTIONAL  (0x01)`: field may be absent; access returns `T | nil`
- `FLAG_READONLY  (0x02)`: stored, not enforced (future)
- `FLAG_PRIVATE   (0x04)`: accessible only from the file that defines the type
- `FLAG_OPAQUE_KEY (0x08)`: key is a variable name, not a string; typeclass dispatch

A table with `data[4] >= 0` (row variable present) is **open**: it may have
additional fields beyond those declared. A table with `data[4] == -1` is
**closed**: no undeclared fields are permitted.

Spread placeholders (`name_id == -1`) in the field list indicate `{ ...T }`.
The `type_id` for a spread field is TAG_SPREAD with `data[0]` = the inner
type. Spread fields are expanded during alias instantiation; if the inner
type is still unresolved at unification time, the unification rule handles
it (see §2.8).

### 1.5 TAG_UNION and TAG_INTERSECTION

Both use the same layout:
```
data[0] = member list start
data[1] = member count
```

Invariants maintained by `make_union` / `make_intersection`:
- No nested unions/intersections (flattened).
- No duplicate members.
- TAG_ANY in a union short-circuits to TAG_ANY.
- TAG_NEVER in a union is dropped.
- Union with one member collapses to that member.
- TAG_UNKNOWN in a union short-circuits to TAG_UNKNOWN.

### 1.6 TAG_VAR and TAG_ROWVAR

```
data[0] = (unused / future)
data[1] = scope level (integer ≥ 0)
data[2] = bound target type ID, or -1 if unbound
```

A type variable is **bound** when `data[2] >= 0`. `find(ctx, tid)` follows
the union-find chain to the root. All operations use the root ID.

TAG_ROWVAR behaves identically to TAG_VAR in unification **except** that
unifying `TAG_ROWVAR <: TAG_TABLE` (actual is open table) succeeds (the row
variable represents the possibility of additional fields).

Binding (via `bind_var`):
1. Occurs check: reject if var appears inside the target (infinite type).
   - Exception: `x = x | nil` — strip the var from the union and bind to the
     remainder (handles `x = x or default`).
2. Level adjustment: set var level to min(var level, target max level).
3. Write target ID into `data[2]`.

### 1.7 TAG_TUPLE

```
data[0] = element list start
data[1] = element count
```

Tuples are the return-value carrier. A function that returns `(integer,
string)` has return type `TAG_TUPLE { integer, string }`. Single-value
returns are wrapped in a 1-tuple. Zero-return functions have a 0-tuple.
Tuple slots not present are implicitly nil.

Tuples are NOT structural subtypes of tables or vice versa.

### 1.8 TAG_NOMINAL

```
data[0] = name intern ID
data[1] = nominal identity (FNV31 hash, unique per declaration site)
data[2] = underlying type ID
```

Two nominal types are equal iff `data[1]` is equal (identity-based, not
name-based). The underlying type is accessible after `--:: unseal`.

### 1.9 TAG_ENUM_MEMBER

```
data[0] = enum name intern ID
data[1] = member name intern ID
data[2] = LIT_kind (same constants as TAG_LITERAL)
data[3] = value
```

Enum members are the types inferred for fields of `{ A=1, B=2, C=3 }`-style
tables. `try_promote_enum` in constrain.lua converts a table whose fields are
all literals of the same kind into a table of enum-member types.

---

## 2. Subtyping: `A <: B`

`M.unify(ctx, a, b)` checks `a <: b` and binds free type variables.
Returns `(true)` or `(false, error_string, detail?)`.

All rules below operate on the roots (`find(ctx, a)` and `find(ctx, b)`).

### 2.1 Reflexivity

```
a == b  →  true
```

### 2.2 TAG_ANY (bilateral)

```
TAG_ANY <: T  →  true  (for all T)
T <: TAG_ANY  →  true  (for all T)
```

If one side is TAG_ANY and the other is a free TAG_VAR/TAG_ROWVAR, bind the
variable to TAG_ANY (prevents leaking `Box<any>` into the type graph).

### 2.3 TAG_UNKNOWN (top type)

```
T <: TAG_UNKNOWN  →  true  (all types are subtypes of unknown)
TAG_UNKNOWN <: T  →  false  ("must narrow before use")
```

If the expected type (`b`) is TAG_UNKNOWN and the actual (`a`) is a free
TAG_VAR/TAG_ROWVAR, bind the variable to TAG_UNKNOWN (prevents later
narrowing from overriding the "must narrow" contract).

### 2.4 TAG_NEVER (bottom type)

```
TAG_NEVER <: T  →  true  (for all T)
T <: TAG_NEVER  →  false  (for T ≠ TAG_NEVER)
```

### 2.5 Type Variables

If `a` is TAG_VAR or TAG_ROWVAR (actual is free): call `bind_var(a, b)`.
If `b` is TAG_VAR or TAG_ROWVAR (expected is free): call `bind_var(b, a)`.

In read-only unification (`M.try_unify`):
- `a = TAG_VAR` → false (actual type unresolved; can't accept without binding)
- `a = TAG_ROWVAR` → true (open-table structural match is OK)
- `b = TAG_VAR` or `b = TAG_ROWVAR` → true (generic instantiation)

### 2.6 TAG_NOMINAL (identity-based)

```
TAG_NOMINAL(id1) <: TAG_NOMINAL(id2)  →  id1 == id2
TAG_NOMINAL(id1) <: T               →  false (T is not a nominal with same id)
T <: TAG_NOMINAL(id)                →  false (T is not the same nominal)
```

The underlying type is NOT a subtype of the nominal. Unsealing is required.

### 2.7 TAG_LITERAL

```
LIT_INTEGER(n) <: TAG_INTEGER   →  true
LIT_INTEGER(n) <: TAG_NUMBER    →  true  (integers ⊆ numbers)
LIT_NUMBER(f)  <: TAG_NUMBER    →  true
LIT_STRING(s)  <: TAG_STRING    →  true
LIT_BOOLEAN(b) <: TAG_BOOLEAN   →  true

LIT_INTEGER(n) <: LIT_INTEGER(m)  →  n == m  (data[1] equal)
LIT_NUMBER(f)  <: LIT_NUMBER(g)   →  f == g  (data[1] AND data[2] equal)
LIT_STRING(s)  <: LIT_STRING(t)   →  s == t  (data[1] = intern IDs equal)
LIT_BOOLEAN(b) <: LIT_BOOLEAN(c)  →  b == c

LIT_*  <: primitive base type  →  true (as above)
primitive base type <: LIT_*   →  false  (base is wider than literal)
```

### 2.8 TAG_INTEGER ⊂ TAG_NUMBER

```
TAG_INTEGER <: TAG_NUMBER  →  true
TAG_NUMBER  <: TAG_INTEGER →  false
```

### 2.9 TAG_ENUM_MEMBER

```
ENUM(e, m) <: ENUM(e', m')  →  e == e' AND m == m'
ENUM(e, m) with LIT_INTEGER kind <: TAG_INTEGER  →  true
ENUM(e, m) with LIT_INTEGER kind <: TAG_NUMBER   →  true
ENUM(e, m) with LIT_STRING  kind <: TAG_STRING   →  true
ENUM(e, m) <: LIT_*(kind, v)  →  kind matches AND value matches
```

### 2.10 Primitive Equality

```
TAG_NIL     <: TAG_NIL     →  true
TAG_BOOLEAN <: TAG_BOOLEAN →  true
TAG_STRING  <: TAG_STRING  →  true
TAG_NUMBER  <: TAG_NUMBER  →  true
TAG_INTEGER <: TAG_INTEGER →  true
```

### 2.11 TAG_UNION on the left (actual is union)

```
A | B <: T  →  (A <: T) AND (B <: T)
```

Every member of the actual union must be a subtype of the expected type.
Uses a fresh copy of `seen` per member to prevent cycle-guard cross-contamination.

### 2.12 TAG_UNION on the right (expected is union)

```
T <: A | B  →  (T <: A) OR (T <: B)
```

Try each union member (disjunctive). Use `copy_seen` before each attempt
so that a failed attempt doesn't contaminate the next. If all fail, collect
the best-match error detail.

### 2.13 TAG_INTERSECTION on the left (actual is intersection)

```
A & B <: T  →  (A <: T) OR (B <: T)  [step 1: single-member]
```

If no single member works:
- `T = TAG_UNION`: try full intersection against each union member.
- `T = TAG_INTERSECTION`: intersection must satisfy ALL members of T.
- `T = TAG_TABLE`: merged-field check — for each required field in T, at
  least one intersection member must have it with a compatible type.

### 2.14 TAG_INTERSECTION on the right (expected is intersection)

```
T <: A & B  →  (T <: A) AND (T <: B)
```

Must satisfy every constraint.

### 2.15 TAG_FUNCTION subtyping

```
(A1, A2) -> R1  <:  (B1, B2) -> R2
```

- Parameters **contravariant**: `B_i <: A_i` (direction flips).
- Returns **covariant**: `R1 <: R2` (same direction).
- Arity mismatch: extra parameters on either side are paired with TAG_NIL.

### 2.16 TAG_TABLE structural subtyping

Let `a` be the actual table, `b` the expected table.

**Required fields:** for each named field `f: T` in `b` (i.e., `FLAG_OPTIONAL` not set):
1. Look up `f` in `a` by `table_field(a, f)`. If found, check `actual_type <: T`.
2. If not found in named fields: check `a`'s string indexer (if any) against `T`.
3. If not found: check if `a` is open (has row variable). If open, pass (row var can absorb).
4. If none of the above: error "missing field `f`".

**Optional fields:** if `f` is FLAG_OPTIONAL in `b`, the field need not exist in `a`.
If it does exist in `a`, check `actual_type <: T | nil`.

**Spread fields:** if `b` has a spread placeholder (`name_id == -1`) with inner type `S`:
- If `S` is TAG_TABLE: expand `S`'s fields and check each as required fields of `b`.
- If `S` is TAG_UNION of TAG_TABLEs: for each field in any arm, verify it exists in `a`
  (optional if absent from some arms). See env.lua `substitute_inner` for pre-expansion.

**Indexers:** for each indexer `[K]: V` in `b`:
- `a` must have an indexer whose key type is a supertype of `K` and value type is a
  subtype of `V` (or a numeric indexer for integer-keyed tables).
- If no matching indexer and neither table is open: error "missing indexer".

**Excess field check** (closed → closed only):
If both `a` and `b` are closed (no row var), every field in `a` must exist in `b`
or be covered by a `b` indexer. This makes `{ x: integer, extra: boolean }` NOT
assignable to `{ x: integer }` when both are closed.

**Meta fields:** for each meta field in `b`, check via `table_meta_field`.

**Primitive metamethods:** if `b` is a table with only meta fields (no named fields,
no indexers) — i.e., a "meta constraint" — and `a` is a primitive (number, integer,
literal number/integer, string, literal string), look up `ctx.prim_meta[a.tag]` and
check that the actual primitive's declared metamethod type satisfies `b`.

### 2.17 TAG_TUPLE subtyping

```
(A1, A2) <: (B1, B2)  →  len(A) == len(B)  AND  A_i <: B_i  for all i
```

Tuples of different lengths are incompatible.

TAG_TUPLE and TAG_TABLE are always incompatible with each other.

### 2.18 TAG_CDATA

```
TAG_CDATA <: T  →  true  (for all T)
T <: TAG_CDATA  →  true  (for all T)
```

FFI cdata is opaque; all compatibility checks pass.

### 2.19 Coinductive cycle guard

`seen` is a 2D table: `seen[a][b] = true` means "(a, b) is currently being
unified." If a cycle is detected, return `true` immediately (assume compatible
— coinductive). This handles recursive / mutually-referential table types.

---

## 3. Expression Typing

The constraint generator (`constrain.lua`) walks the AST and emits
constraints. Each expression rule maps an AST node to a type ID.

### 3.1 Literals

```
nil           →  T_NIL
true          →  LIT_BOOLEAN(1)
false         →  LIT_BOOLEAN(0)
"hello"       →  LIT_STRING(intern("hello"))
42            →  LIT_INTEGER(42)     (if fits int32)
3.14          →  LIT_NUMBER(3.14)    (float, stored as i32×2)
0x10000000000 →  LIT_NUMBER(...)     (int too large for int32 → float)
```

Integer-valued float literals that fit in int32 are LIT_INTEGER (e.g.
`2.0` → LIT_INTEGER(2)). Otherwise they are LIT_NUMBER.

### 3.2 Identifiers

```
x  →  lookup(scope, intern("x"))
```

If `x` is not in scope: error UNKNOWN_IDENTIFIER, return T_ANY.

### 3.3 Unary expressions

```
not x   →  T_BOOLEAN  (always, regardless of x)
-x      →  emit C_ARITH("__unm", x, x, res); return fresh var
#x      →  emit C_ARITH("__len", x, x, res); return fresh var
```

### 3.4 Binary expressions

```
a + b   →  emit C_ARITH("__add", a, b, res)
a - b   →  emit C_ARITH("__sub", a, b, res)
a * b   →  emit C_ARITH("__mul", a, b, res)
a / b   →  emit C_ARITH("__div", a, b, res)
a % b   →  emit C_ARITH("__mod", a, b, res)
a ^ b   →  emit C_ARITH("__pow", a, b, res)
a .. b  →  emit C_ARITH("__concat", a, b, res)
a < b   →  emit C_COMPARE(a, b); return T_BOOLEAN
a <= b  →  emit C_COMPARE(a, b); return T_BOOLEAN
a > b   →  emit C_COMPARE(a, b) [operands swapped]; return T_BOOLEAN
a >= b  →  emit C_COMPARE(a, b) [operands swapped]; return T_BOOLEAN
a == b  →  T_BOOLEAN  (no constraint; structural equality always valid)
a ~= b  →  T_BOOLEAN  (no constraint)
```

**`a and b`:**
1. Type-check `a`.
2. In a narrowed scope where `a` is truthy (nil and false removed), type-check `b`.
3. Result type: `nil | typeof(b)` (if `a` is falsy, result is nil; if truthy, result is b).

**`a or b`:**
- Emit C_OR constraint (deferred). Resolved at solve time once `a`'s type is known.
- If `a` is known non-nil: result = typeof(a).
- If `a` can be nil: result = typeof(b).
- Returns a fresh var (bound at solve time).

### 3.5 Field access `obj.field`

```
obj.field  →  emit C_INDEX(obj, LIT_STRING(intern("field")), res); return fresh var
```

Field access on nil, booleans, or literal booleans/numbers is a type error.

### 3.6 Index access `obj[key]`

**Opaque key** (key is an identifier whose type is a table): use LIT_OPAQUE_KEY
for typeclass dispatch.

**String literal key** `obj["field"]`: same as `obj.field`.

**General index**: emit C_INDEX(obj, key_tid, res); return fresh var.

### 3.7 Table constructors

```
{ a = 1, b = "x", [k] = v, 10, 20 }
```

- Named fields (`k = v`): field with name_id=intern("k"), type=typeof(v).
- Positional fields (no key): field with name_id=intern("1"), intern("2"), etc.
- Computed fields (`[k] = v`): add to indexers list as (typeof(k), typeof(v)).
- Field names starting with `_` get FLAG_PRIVATE automatically.
- If all fields are literals of the same kind, `try_promote_enum` may convert
  to enum-member types (e.g. `{ A=1, B=2 }` → `{ A: ENUM(tbl, A), B: ENUM(tbl, B) }`).

### 3.8 Function expressions

```
function(a, b) body end
```

1. Create child scope.
2. Bind parameters:
   - If annotated `--: T`: bind with that type.
   - If not annotated: bind with fresh TAG_VAR.
3. Bind `...` as T_ANY or the annotated vararg type.
4. Push a return variable (annotated concrete type, or fresh var if unannotated).
5. Generate body.
6. If annotated return type and body is not definitely-returning: emit
   `C_RETURN(T_NIL, return_type)` for the implicit nil path.
7. Return `make_func(params, returns, vararg, param_names)`.

**Unannotated parameters are TAG_VAR.** They bind to whatever type is passed
at call sites, making the function implicitly generic. Annotated parameters
are not generic — passing the wrong type is an error.

### 3.9 Function calls

```
f(a, b, c)
```

1. Type-check `f` → `callee_tid`.
2. If `f` is generic (TAG_FORALL), instantiate: replace generic vars with fresh
   vars at current scope level. Emit C_BOUND for each constraint.
3. Type-check each argument.
4. Emit `C_CALLABLE(callee_tid, arg_tids, result_tid, line, col)`.
5. If callee is `$PcallReturn`-typed: eagerly evaluate for narrowing support.
6. Return `result_tid` (a fresh var; bound by C_CALLABLE solver).

For multi-return calls (last position in a local statement): the result is a
TAG_TUPLE (or inferred from the callee's return annotation); slots are
extracted via C_INDEX.

### 3.10 Local statements

```
local x --: T = expr
local a, b = f()
```

- If annotated: the declared type is the permanent type for `x`. Emit
  `C_SUB(typeof(expr), T)` to check the initializer.
- If unannotated: `x` gets the type of the initializer expression.
- Multi-return: if the last RHS is a call, use the call's tuple result;
  extract each slot via C_INDEX. Slots beyond the call's return count are nil.

### 3.11 Return statements

```
return a, b
```

Emit `C_RETURN(typeof(a), expected_return_type)` for the first value (or
each value in annotated multi-return functions). The expected return type
comes from the enclosing function's return variable.

---

## 4. The Solver

Constraints are emitted during the AST walk and solved after. The solver
(`solve.lua`) processes each constraint kind:

**C_UNIFY(a, b):** call `M.unify(ctx, a, b)`.

**C_SUB(actual, expected):** call `M.unify(ctx, actual, expected)`.

**C_CALLABLE(callee, args, result):**
- Resolve callee type (may be union or intersection → try each member).
- Match args to params (unify each arg with the corresponding param type;
  extra args may be ignored or cause errors based on callee strictness).
- Unify result with callee's return type.

**C_INDEX(obj, key, result):**
- `obj = TAG_TABLE, key = LIT_STRING(f)`:
  1. Look up field `f` directly via `table_field`.
  2. If not found: check spread placeholders (TAG_SPREAD with TAG_TABLE or
     TAG_UNION inner type) — see §2.16.
  3. If not found: check string indexer.
  4. If not found and table is open: return T_UNKNOWN.
  5. If not found and table is closed: error "field `f` doesn't exist".
- `obj = TAG_UNION`: solve_index on each union member; result = union of each.
- `obj = TAG_INTERSECTION`: find any member with the field.
- `obj = TAG_VAR/TAG_ROWVAR`: bind obj to `{ f: fresh_var, ...rowvar }`.

**C_ARITH(op, lhs, rhs, result):**
- Dispatch via `prim_meta` for primitive types (number, integer, string).
- For user types: look up `__op` metamethod via structural meta constraint.
- Result type comes from the metamethod's declared return type.

**C_COMPARE(lhs, rhs):** check that `lhs` and `rhs` have compatible ordering
via `__lt`/`__le` metamethods. Result is always T_BOOLEAN.

**C_RETURN(val, expected):** unify `val <: expected`. Errors report
"return type mismatch".

**C_OR(left, right, result):** once `left` is bound:
- If left can only be falsy (nil, false): result = right.
- If left cannot be falsy: result = left.
- Otherwise: result = (non-nil left) | right.

**C_BOUND(tv, bound):** once `tv` is bound, check that its binding `<: bound`.

---

## 5. Type Narrowing

Narrowing is flow-sensitive. `narrow.lua` computes narrowed type bindings
for identifiers after conditional tests.

### 5.1 Nil check `if x then`

In the true branch: remove nil from x's type. If `x: T | nil`, narrow to T.
In the false branch: x may be nil (or false).

### 5.2 Equality check `if x == nil then` / `if x ~= nil then`

`x == nil` → true branch has `x: nil`, false branch has `x` without nil.
`x ~= nil` → true branch has `x` without nil.

### 5.3 Type guard `if type(x) == "string" then`

In the true branch: narrow `x` to the corresponding primitive type (string,
number, boolean, table, function, nil, thread, userdata).
In the false branch: subtract the primitive type from `x`.

This is hardcoded in `narrow.lua`; the `type()` function has special-case
narrowing logic that cannot currently be expressed as a user-defined predicate.

### 5.4 Discriminant check `if x.kind == "foo" then`

If `x` is a union of tables where a string-literal field discriminates the
union members, narrow `x` to the members that match. Requires the field to
be present and a literal type in the table types.

### 5.5 `and`/`or` short-circuit

`a and b`: in the expression context for `b`, `a` is narrowed to truthy.
`a or b`: in the expression context for `b`, `a` is narrowed to falsy.

---

## 6. Annotation Syntax

Type annotations appear in Lua comments. Two forms:

```lua
--: T          -- type of the preceding expression or next local
--:: Name = T  -- type alias declaration
--:: declare Name = T  -- global variable declaration
--:: module "name": T  -- declares the type returned by require("name")
```

### 6.1 Type Expression Grammar (simplified)

```
T ::= primitive | "nil" | "never" | "unknown" | "any"
    | T "|" T          -- union
    | T "&" T          -- intersection
    | "(" T ")"        -- grouping
    | "(" params ")" "->" T       -- function type
    | "(" params ")" "->" "..." "(" T ")"  -- multi-return spread
    | "{" fields "}"   -- table type
    | "<" typevars ">" T  -- generic
    | Name "<" T* ">"  -- generic instantiation
    | Name             -- named type or type variable
    | LIT_STRING       -- string literal type
    | LIT_NUMBER       -- number literal type
    | LIT_BOOL         -- boolean literal type
    | LIT_INT          -- integer literal type

primitive ::= "nil" | "boolean" | "number" | "string" | "integer"
            | "any" | "never" | "unknown"

params ::= (name ":" T ("," name ":" T)* ("," "..." T)?)?
fields ::= (field ("," field)* ","?)?
field  ::= name ":" T         -- named required field
         | name "?" ":" T     -- named optional field
         | "[" K "]" ":" V    -- indexer
         | "..." T            -- spread
         | "#" name ":" T     -- meta field
         | "..." /* bare */   -- open-table row variable
```

### 6.2 `--:: unseal name`

After this declaration, `name` is rebound from its nominal (opaque) type to
the underlying concrete type. Applies from that line forward within the
enclosing block scope.

---

## 7. Invariants (Ground Truth for the Fuzz Suite)

These must hold for ALL types, regardless of implementation:

1. **Reflexivity**: `T <: T` for all T.
2. **Union intro**: `A <: A|B` and `B <: A|B` for all A, B.
3. **Union idempotent**: `A|A <: A` for all A.
4. **Union elim**: `A|B <: C` iff `A <: C` and `B <: C`.
5. **Intersection elim**: `A&B <: A` and `A&B <: B` for all A, B.
6. **Intersection intro**: `T <: A` and `T <: B` implies `T <: A&B`.
7. **Transitivity**: `A <: B` and `B <: C` implies `A <: C`.
8. **Literal subtyping**: `LIT_INTEGER(n) <: integer`, `LIT_INTEGER(n) <: number`,
   `LIT_STRING(s) <: string`, `LIT_BOOLEAN(b) <: boolean`.
9. **Literal asymmetry**: `integer </: LIT_INTEGER(n)` (base is not a subtype of literal).
10. **Integer ⊂ number**: `integer <: number` but `number </: integer`.
11. **Never bottom**: `never <: T` for all T.
12. **Unknown top**: `T <: unknown` for all T; `unknown </: T` for primitive T.
13. **Function covariance**: `(A)->C <: (A)->(C|D)`.
14. **Function contravariance**: `(A|B)->C <: (A)->C`.
15. **Annotation soundness (positive)**: a function body of the form
    `function(x --: T): T return x end` typechecks without error.
16. **Annotation soundness (negative)**: `function(x --: A): B return x end`
    produces a type error when `A </: B`.
17. **Multi-return**: slot N of a multi-return is the declared type; extra slots
    are nil; fewer slots than expected do not add errors for the missing tail.

### 7.1 Invariants NOT yet tested (each = a blind spot)

- **Narrowing precision**: after `if type(x) == "string"`, x is exactly `string`,
  not a supertype.
- **Overload dispatch**: calling an intersection of function types routes to the
  correct member.
- **Generic constraint checking**: `<T: C>` rejects instantiations where T </: C.
- **Spread multi-return slot extraction**: slot N has exactly the declared type.

---

## 8. Intrinsics

Intrinsics (`$Name<T>`) are type operations that require compiler support because
they cannot yet be expressed as user-defined match aliases. Each has a precise
contract.

| Intrinsic | Contract |
|-----------|----------|
| `$Require<T>` | T must be a string literal; result = the type declared for module T via `--:: module "T": ...`; T_UNKNOWN if not declared. |
| `$Opaque<T>` | Nominal newtype over T. Field access errors. Only accessible after `--:: unseal`. |
| `$Opaque<T, U>` | Like `$Opaque<T>` but fields in U are accessible without unsealing. |
| `$FfiC` | Closed table built from `ffi.cdef` call sites. Each declared symbol becomes a field. |
| `$GlobalScope` | Closed table of all globals declared via `--:: declare`. |
| `$Keys<T>` | Union of string literal types for all named field names in T. Equivalent to TypeScript `keyof T`. |
| `$Values<T>` | Union of widened value types for all fields/entries in T. For `{ [K]: V }`: returns V. For named-field table: returns union of `widen(field_type)` for each field. For `TAG_UNION`: union of `$Values<arm>`. Counterpart to `$Keys<T>`. |
| `$IpairsValues<T>` | Like `$Values<T>` but restricted to numeric/positional entries. For `{ [integer]: V }` or `{ [number]: V }`: returns V. For array-like named fields (keys "1", "2", ...): returns union of their value types. |
| `$EachField<T, F>` | Maps type alias F over each field descriptor of T. F is called with a descriptor table `{ name, type, optional, readonly }`; F must return a tuple of field descriptor(s). Result is a new table type assembled from all returned descriptors. Implements `Readonly<T>`, `Partial<T>`, `Required<T>`, `Pick<T, K>`, etc. |
| `$Throw<E>` | Type-level error: signals an unresolvable match arm. Never assignable to/from any type. E is the error message literal. Used inside match arms to enforce exhaustiveness. |
| `$Catch<T, E>` | Evaluates T; if T resolves to `$Throw<...>`, returns E instead. Type-level pcall pair for `$Throw`. Only meaningful at annotation boundaries (not inside inference). |

`$Values` and `$IpairsValues` together replace the former `$PairsReturn<T>` and
`$IpairsReturn<T>` compiler intrinsics.  Those are now expressed as user-definable
match aliases in `stdlib.d.lua`:

```lua
--:: PairsReturn<T> = match T {
--::   { [K]: V } => (K, V),
--::   T          => (string, $Values<T>)
--:: }

--:: IpairsReturn<T> = match T {
--::   T => (integer, $IpairsValues<T>)
--:: }
```

`PcallReturn<F>` is also now a match alias in `stdlib.d.lua` (implemented via
`(true, ...R)` spread-in-tuple-position syntax, 2026-03-30).

Permanent intrinsics (will not be eliminated): `$Require`, `$Opaque`, `$FfiC`,
`$GlobalScope`, `$Throw`, `$Catch`. Remaining provisional (may become user-definable
match aliases once the type system matures): `$Keys`, `$Values`, `$IpairsValues`,
`$EachField`, `$EachUnion`.
