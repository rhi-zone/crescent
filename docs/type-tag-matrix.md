# Type Tag × Operation Matrix

For each tag, every cell is either **✓ impl+tested**, **P partial**, **N/A by design**, or **✗ missing**.

Last updated: 2026-03-31

---

## Tags

| Value | Tag | Description |
|-------|-----|-------------|
| 0 | TAG_NIL | nil singleton |
| 1 | TAG_BOOLEAN | boolean type |
| 2 | TAG_NUMBER | number type |
| 3 | TAG_STRING | string type |
| 4 | TAG_ANY | top escape-hatch (bilateral) |
| 5 | TAG_NEVER | bottom type |
| 6 | TAG_INTEGER | LuaJIT integer subtype |
| 7 | TAG_UNKNOWN | unknown top type (must narrow) |
| 8 | TAG_LITERAL | string/number/boolean/nil literal |
| 9 | TAG_FUNCTION | function with params/returns |
| 10 | TAG_TABLE | structural table |
| 11 | TAG_UNION | A \| B sum type |
| 12 | TAG_INTERSECTION | A & B overload/constraint set |
| 13 | TAG_VAR | type variable (unification target) |
| 14 | TAG_ROWVAR | row variable (open table tail) |
| 15 | TAG_TUPLE | fixed-length tuple |
| 16 | TAG_NOMINAL | newtype (identity-based) |
| 17 | TAG_MATCH_TYPE | pattern-match type |
| 18 | TAG_INTRINSIC | built-in type function |
| 19 | TAG_TYPE_CALL | type constructor application |
| 20 | TAG_FORALL | universally quantified (generic) |
| 21 | TAG_SPREAD | variadic type (`...T`) |
| 22 | TAG_NAMED | unresolved type name |
| 23 | TAG_CDATA | FFI cdata (opaque) |
| 24 | TAG_ENUM_MEMBER | Named enum member (EnumName.MemberName literal) |
| 25 | TAG_TYPEOF | Annotation-only: `typeof <ident>` deferred lookup |
| 26 | TAG_FFIC | FFI C table resolved from `ffi.cdef` call sites |
| 27 | TAG_CAPTURE | Pattern-position capture variable `%Name` (annotation arena only) |
| 28 | TAG_PAT_ALL_FIELDS | `{ ...[%K]: %V }` all-fields pattern (annotation arena only) |
| 29 | TAG_PAT_REST_FIELDS | `{ ...[%Rest] }` rest-field capture pattern (annotation arena only) |
| 30 | TAG_PAT_META_SPREAD | `{ #...%M }` meta-slot spread pattern (annotation arena only) |
| 31 | TAG_PARTIAL_APP | Partially-applied generic alias (deferred instantiation) |

---

## Matrix

Operations:
- **field** — `obj.field` access
- **index** — `obj[key]` indexing
- **call** — function call
- **unify** — M.unify (mutating, binds vars)
- **try_unify** — M.try_unify (read-only check)
- **narrow** — control-flow narrowing
- **display** — human-readable string
- **serial** — CRI serialize/deserialize
- **inst** — instantiate (fresh vars for generics)
- **gen** — generalize (mark free vars as generic)
- **ann** — resolve_annotation_type (ann arena → checker arena)

| Tag | field | index | call | unify | try_unify | narrow | display | serial | inst | gen | ann |
|-----|-------|-------|------|-------|-----------|--------|---------|--------|------|-----|-----|
| TAG_NIL | N/A | N/A | N/A | ✓ | ✓ | ✓ (nil-check) | ✓ | ✓ | N/A | N/A | ✓ |
| TAG_BOOLEAN | N/A | N/A | N/A | ✓ | ✓ | ✓ (type-check) | ✓ | ✓ | N/A | N/A | ✓ |
| TAG_NUMBER | N/A | N/A | N/A | ✓ | ✓ | ✓ (type-check) | ✓ | ✓ | N/A | N/A | ✓ |
| TAG_STRING | N/A | N/A | N/A | ✓ | ✓ | ✓ (type-check) | ✓ | ✓ | N/A | N/A | ✓ |
| TAG_ANY | ✓ | ✓ | ✓ | ✓ | ✓ | N/A | ✓ | ✓ | N/A | N/A | ✓ |
| TAG_NEVER | ✓ | ✓ | ✓ | ✓ | ✓ | N/A | ✓ | ✓ | N/A | N/A | ✓ |
| TAG_INTEGER | N/A | N/A | N/A | ✓ (<: number) | ✓ | ✓ (type-check) | ✓ | ✓ | N/A | N/A | ✓ |
| TAG_UNKNOWN | ✓ | ✓ | ✓ | ✓ (top type) | ✓ | ✓ | ✓ | ✓ | N/A | N/A | ✓ |
| TAG_LITERAL | N/A | N/A | N/A | ✓ (<: base) | ✓ | ✓ (lit-eq, field-disc) | ✓ | ✓ | N/A | N/A | ✓ |
| TAG_FUNCTION | N/A | N/A | ✓ | ✓ | ✓ | N/A | ✓ | ✓ | ✓ | ✓ | ✓ |
| TAG_TABLE | ✓ | ✓ | N/A | ✓ | ✓ | ✓ (field-presence, disc) | ✓ | ✓ | ✓ | ✓ | ✓ |
| TAG_UNION | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| TAG_INTERSECTION | ✓ | ✓ | ✓ | ✓ | ✓ | N/A | ✓ | ✓ | ✓ | ✓ | ✓ |
| TAG_VAR | ✓ | ✓ | ✓ | ✓ (bind) | ✓ (passthrough) | N/A | ✓ | N/A (internal) | ✓ | ✓ | ✓ |
| TAG_ROWVAR | N/A (row tail) | N/A | N/A | ✓ (bind) | ✓ (passthrough) | N/A | ✓ | N/A (internal) | ✓ | ✓ | ✓ |
| TAG_TUPLE | N/A | ✓ (literal idx) | N/A | ✓ | ✓ | N/A | ✓ | ✓ | ✓ | ✓ | ✓ |
| TAG_NOMINAL | ✓ | ✓ | N/A | ✓ (identity) | ✓ | N/A | ✓ | ✓ | N/A | N/A | ✓ |
| TAG_MATCH_TYPE | N/A | N/A | N/A | P (falls to error) | P (false) | N/A | ✓ | ✓ | N/A | N/A | ✓ (evaluates) |
| TAG_INTRINSIC | N/A | N/A | ✓ (special) | P (falls to error) | P (false) | N/A | ✓ | ✓ | N/A | N/A | ✓ |
| TAG_TYPE_CALL | N/A | N/A | N/A | P (falls to error) | P (false) | N/A | ✓ | ✓ | N/A | N/A | ✓ (applies) |
| TAG_FORALL | N/A | N/A | N/A | P (falls to error) | P (false) | N/A | ✓ | ✓ | N/A | N/A | ✓ (subscope) |
| TAG_SPREAD | N/A | N/A | N/A | P (falls to error) | P (false) | N/A | ✓ | ✓ | ✓ | ✓ | ✓ |
| TAG_NAMED | ✓ (treat as any) | ✓ (treat as any) | ✓ (treat as any) | ✓ (treat as any) | ✓ (passthrough) | N/A | ✓ | N/A (resolve first) | N/A | N/A | ✓ (resolves) |
| TAG_CDATA | N/A | N/A | N/A | ✓ (universal) | ✓ (universal) | N/A | ✓ | ✓ | N/A | N/A | ✓ |
| TAG_ENUM_MEMBER | N/A | N/A | N/A | ✓ (literal-eq) | ✓ | ✓ (lit-eq disc) | ✓ | ✓ | N/A | N/A | ✓ |
| TAG_TYPEOF | N/A | N/A | N/A | N/A | N/A | N/A | ✓ | N/A | N/A | N/A | ✓ (resolves in ann pass) |
| TAG_FFIC | ✓ | ✓ | N/A | ✓ (cdef-backed) | ✓ | N/A | ✓ | N/A (internal) | N/A | N/A | ✓ |
| TAG_CAPTURE | N/A | N/A | N/A | N/A | N/A | N/A | ✓ | N/A (pattern) | N/A | N/A | N/A (ann-only) |
| TAG_PAT_ALL_FIELDS | N/A | N/A | N/A | N/A | N/A | N/A | ✓ | N/A (pattern) | N/A | N/A | N/A (ann-only) |
| TAG_PAT_REST_FIELDS | N/A | N/A | N/A | N/A | N/A | N/A | ✓ | N/A (pattern) | N/A | N/A | N/A (ann-only) |
| TAG_PAT_META_SPREAD | N/A | N/A | N/A | N/A | N/A | N/A | ✓ | N/A (pattern) | N/A | N/A | N/A (ann-only) |
| TAG_PARTIAL_APP | N/A | N/A | N/A | P (falls to error) | P (false) | N/A | ✓ | N/A (deferred) | N/A | N/A | ✓ (deferred inst) |

**P = partial** means the tag reaches a generic fall-through that returns false/error rather than a correct rule.

---

## Narrowing sub-operations

Narrowing is handled separately from unify. The narrowing system (narrow.lua) supports:

| Pattern | Tags narrowed | Status |
|---------|--------------|--------|
| `x == nil` / `x ~= nil` | any | ✓ |
| `if x then` / `if not x then` | any | ✓ (truthiness = nil-check) |
| `x == "lit"` / `x ~= "lit"` | union of string literals, string | ✓ (2026-03-15) |
| `x == true/false` / `x ~= true/false` | boolean | ✓ (2026-03-15) |
| `x.field == "lit"` (string) | union of tables (field-disc) | ✓ |
| `x.field == true/false` | union of tables (field-disc) | ✓ (2026-03-15) |
| `x.field == integer_literal` | union of tables | ✗ (numval indices are per-file, not globally comparable) |
| `type(x) == "string"` etc. | any | ✓ |
| `if x.field then` | tables with optional field | ✓ (field-presence) |
| discriminated union after pcall ok | ret-type union | ✓ |

**Known limitation**: integer discriminants (`x.kind == 1`) are not supported because
numval indices (used to store number literals) are per-file, not globally comparable across
annotation files and source files. String and boolean discriminants work because their IDs
are globally interned.

---

## Known gaps by category

### Unify/try_unify (P cells above)

`TAG_MATCH_TYPE`, `TAG_INTRINSIC`, `TAG_TYPE_CALL`, `TAG_FORALL`, `TAG_SPREAD` all fall to
the generic `return false, "cannot assign..."` at the bottom of M.unify. This means code that
contains these types in value position may produce spurious errors.

**Assessment**: These tags are meta-level constructs (type-language, not value-language).
They should only appear inside annotations and type arenas, never as the inferred type of a
runtime value. If they appear, it signals a bug in annotation resolution. Current behavior
(fall to error) is safe. They do not need unify rules for correctness.

### Covariant/contravariant positions in generics

TAG_FORALL params are bound in a subscope during `resolve_annotation_type` but variance
is not tracked or enforced. `(T) -> T` is correctly instantiated, but `(Array<T>) -> Array<T>`
covariance/contravariance is not verified.

**Assessment**: Deferred until variance annotations are designed. Not blocking.

### Recursive types

TAG_NOMINAL can appear recursively (linked-list node type). The occurs check in bind_var
handles the immediate `x = x or default` case but not full structural recursion. The union-find
representation makes cycles possible if not guarded.

**Assessment**: Tracked separately, not blocking for current use cases.

### Tuple indexing (added 2026-03-15)

TAG_TUPLE now supports `t[1]` style literal numeric indexing. Non-literal keys (e.g., `t[i]`
where i is a variable) return T_UNKNOWN — no indexer type for the whole range.

---

## Audit history

- **2026-03-15**: Initial matrix written. Fixed: lit_eq narrowing (x == "val"), boolean
  field discriminant, TAG_ROWVAR in try_unify, TAG_TUPLE indexing.
