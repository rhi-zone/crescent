# Typechecker v2 — Performance-First Redesign

## Goals

- **Cold-start performance**: competitive with tsgo (Go port of TypeScript compiler)
- **Incremental performance**: sub-100ms for typical edits via content-addressed caching
- **Scale**: 1M+ LOC without degradation
- **LSP**: incremental reparse, daemon mode, same core as batch checker
- **Hackable**: pure LuaJIT + FFI, no build step, no native dependencies beyond libc
- **Complex type system**: generics, nominal types, tuples, narrowing, discriminated unions, match types, intrinsics, meta slots — comparable to TypeScript in expressiveness

## Non-goals

- Lua 5.2+ compatibility for the checker itself (it's a LuaJIT tool)
- Backwards compatibility with v1 internals (v1 is a 2-day-old prototype)

## Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│  crescent check  (batch)  │  crescent serve  (LSP)  │
└────────────────┬──────────┴──────────┬──────────────┘
                 │                     │
         fork N workers          daemon, persistent
         wave-front sched        in-memory state
         mmap interfaces         inotify/kqueue
                 │                     │
         ┌───────▼─────────────────────▼───────┐
         │           core checker              │
         │  dep graph → parse → infer → emit   │
         └───────────────┬─────────────────────┘
                         │
              ┌──────────▼──────────┐
              │  flat-array AST     │  ← integer node types
              │  FFI arena alloc    │  ← zero GC
              │  union-find tvars   │  ← O(α) resolution
              │  integer type tags  │  ← no string dispatch
              └──────┬──────────────┘
                     │
              ┌──────▼──────────────┐
              │  .cri interface     │  ← mmap-able, content-addressed
              │  Merkle DAG cache   │  ← incremental skip
              └─────────────────────┘
```

### Data flow (no intermediate representations)

```
source bytes
  → lexer (intern strings, emit integer tokens)
    → parser (recursive descent, write directly to flat AST arena)
      → annotation parser (write directly to flat type arena)
        → inference walk (Lua logic, reads flat arrays, writes flat types)
          → interface extraction (subset of type arena → .cri file)
            → SHA-256 → Merkle DAG
```

Every layer outputs directly to its final representation. No intermediate
tables. No flatten passes. No GC pressure.

## Foundation Layer

### String Interning

Every string in the system (identifiers, field names, type names) becomes an
integer ID. All comparisons become `==` on integers.

```lua
local intern_map = {}   -- string → id
local intern_strs = {}  -- id → string
local intern_next = 0

local function intern(s)
    local id = intern_map[s]
    if id then return id end
    id = intern_next
    intern_next = id + 1
    intern_map[s] = id
    intern_strs[id] = s
    return id
end
```

This stays in Lua — not a hot path (interning happens during lex, not during
inference). The intern table persists across files within a session.

### Arena Allocator

All flat arrays allocated via FFI. Per-file arena: allocate during parse+check,
free the whole slab when done. Zero GC pressure.

```lua
local nodes = ffi.new("ASTNode[?]", capacity)
local types = ffi.new("TypeSlot[?]", capacity)
local lists = ffi.new("int32_t[?]", capacity)
local fields = ffi.new("FieldEntry[?]", capacity)
```

Arena reset between files: just set the bump pointer back to 0. No per-object
free, no fragmentation, no GC.

For growable arenas: double capacity and `ffi.copy` to a new allocation when
full. Amortized O(1) allocation.

### List Pool

Variable-length sequences (function params, table fields, statement bodies,
union members) stored in a flat `int32_t` array. Referenced as `(start, len)`
pairs in parent nodes/types.

```lua
local list_next = 0

local function list_start()
    return list_next
end

local function list_push(value)
    lists[list_next] = value
    list_next = list_next + 1
end

local function list_since(start)
    return start, list_next - start  -- (start, len)
end
```

Iteration is a tight integer loop — JIT's bread and butter:

```lua
for i = start, start + len - 1 do
    local child_id = lists[i]
    -- process child
end
```

## AST Representation

Fixed-size 32-byte nodes. Two nodes per 64-byte cache line.

```c
typedef struct {
    uint8_t  kind;       /* ~25 node kinds, fits in a byte */
    uint8_t  flags;      /* vararg, locald, computed, etc. */
    uint16_t col;
    uint32_t line;
    int32_t  data[6];    /* meaning depends on kind */
} ASTNode;               /* 32 bytes */
```

### Node kinds

Integer constants, not strings:

```lua
local NODE_LITERAL         = 0
local NODE_IDENTIFIER      = 1
local NODE_BINARY_EXPR     = 2
local NODE_LOGICAL_EXPR    = 3
local NODE_UNARY_EXPR      = 4
local NODE_CONCAT_EXPR     = 5
local NODE_MEMBER_EXPR     = 6
local NODE_CALL_EXPR       = 7
local NODE_SEND_EXPR       = 8
local NODE_TABLE           = 9
local NODE_FUNCTION_EXPR   = 10
local NODE_VARARG          = 11
local NODE_EXPR_VALUE      = 12
local NODE_LOCAL_DECL      = 13
local NODE_ASSIGN_EXPR     = 14
local NODE_FUNCTION_DECL   = 15
local NODE_RETURN_STMT     = 16
local NODE_IF_STMT         = 17
local NODE_WHILE_STMT      = 18
local NODE_REPEAT_STMT     = 19
local NODE_FOR_STMT        = 20
local NODE_FOR_IN_STMT     = 21
local NODE_DO_STMT         = 22
local NODE_EXPR_STMT       = 23
local NODE_BREAK_STMT      = 24
local NODE_LABEL_STMT      = 25
local NODE_GOTO_STMT       = 26
local NODE_CHUNK           = 27
```

### Data slot layouts per kind

```
Literal:         [lit_kind, value_id, -, -, -, -]
Identifier:      [name_id, -, -, -, -, -]
BinaryExpr:      [operator, left, right, -, -, -]
LogicalExpr:     [operator, left, right, -, -, -]
UnaryExpr:       [operator, argument, -, -, -, -]
ConcatExpr:      [terms_start, terms_len, -, -, -, -]
MemberExpr:      [object, property_id, -, -, -, -]
                  flags.computed
CallExpr:        [callee, args_start, args_len, -, -, -]
SendExpr:        [receiver, method_id, args_start, args_len, -, -]
Table:           [keyvals_start, keyvals_len, -, -, -, -]
                  keyvals stored as (key_node, value_node) pairs in list pool
                  key_node = -1 for sequential (no explicit key)
FunctionExpr:    [params_start, params_len, body_start, body_len, lastline, -]
                  flags.vararg
Vararg:          [-, -, -, -, -, -]
ExprValue:       [value, -, -, -, -, -]
LocalDecl:       [names_start, names_len, exprs_start, exprs_len, -, -]
                  names stored as name_id values in list pool
AssignExpr:      [left_start, left_len, right_start, right_len, -, -]
FunctionDecl:    [id_node, params_start, params_len, body_start, body_len, lastline]
                  flags.vararg, flags.locald
ReturnStmt:      [args_start, args_len, -, -, -, -]
IfStmt:          [tests_start, tests_len, cons_start, cons_len, alternate, -]
                  tests/cons stored as parallel lists (test_i, consequent_body_i)
                  alternate = node_id or -1 for none
WhileStmt:       [test, body_start, body_len, lastline, -, -]
RepeatStmt:      [test, body_start, body_len, lastline, -, -]
ForStmt:         [init_id, init_val, last, step, body_start, body_len]
                  body_len doubles as indicator; lastline from data[5] context
                  step = -1 for no step
ForInStmt:       [names_start, names_len, exprs_start, exprs_len, body_start, body_len]
DoStmt:          [body_start, body_len, lastline, -, -, -]
ExprStmt:        [expression, -, -, -, -, -]
BreakStmt:       [-, -, -, -, -, -]
LabelStmt:       [label_id, -, -, -, -, -]
GotoStmt:        [label_id, -, -, -, -, -]
Chunk:           [body_start, body_len, chunkname_id, lastline, -, -]
```

### Memory budget

At 32 bytes per node, ~5 nodes per line of code:

| Scale     | Nodes  | AST size  |
|-----------|--------|-----------|
| 1K LOC    | ~5K    | 160 KB    |
| 10K LOC   | ~50K   | 1.6 MB    |
| 100K LOC  | ~500K  | 16 MB     |

Per-file arena, freed after checking. With 16 workers checking 10K-line files
concurrently: ~25 MB peak AST memory.

## Type Representation

Fixed-size 32-byte type slots in a flat FFI array.

```c
typedef struct {
    uint8_t  tag;        /* ~20 type tags */
    uint8_t  flags;      /* generic, recursive, optional */
    uint16_t reserved;
    int32_t  data[7];    /* tag-specific */
} TypeSlot;              /* 32 bytes */
```

### Type tags

```lua
local TAG_NIL          = 0
local TAG_BOOLEAN      = 1
local TAG_NUMBER       = 2
local TAG_INTEGER      = 3
local TAG_STRING       = 4
local TAG_ANY          = 5
local TAG_NEVER        = 6
local TAG_LITERAL      = 7
local TAG_FUNCTION     = 8
local TAG_TABLE        = 9
local TAG_UNION        = 10
local TAG_INTERSECTION = 11
local TAG_VAR          = 12
local TAG_ROWVAR       = 13
local TAG_TUPLE        = 14
local TAG_NOMINAL      = 15
local TAG_MATCH_TYPE   = 16
local TAG_INTRINSIC    = 17
local TAG_TYPE_CALL    = 18
local TAG_FORALL       = 19
local TAG_SPREAD       = 20
local TAG_NAMED        = 21
local TAG_CDATA        = 22
```

### Data slot layouts per tag

```
nil/boolean/number/integer/string/any/never:
    data unused (tag is the whole type)

literal:      [lit_kind, value_id, -, -, -, -, -]
               lit_kind: 0=string, 1=number, 2=boolean

function:     [params_start, params_len, returns_start, returns_len,
               vararg_type, type_params_start, type_params_len]

table:        [fields_start, fields_len, indexers_start, indexers_len,
               row_id, meta_start, meta_len]
               row_id: type_id of rowvar, or 0 for closed table

union:        [members_start, members_len, -, -, -, -, -]

intersection: [members_start, members_len, -, -, -, -, -]

var:          [id, level, bound, -, -, -, -]
               bound = 0 means unbound
               flags: generic (bit 0), recursive (bit 1)

rowvar:       [id, level, bound, -, -, -, -]

tuple:        [elems_start, elems_len, -, -, -, -, -]

nominal:      [name_id, identity, underlying, -, -, -, -]

match_type:   [param, arms_start, arms_len, -, -, -, -]
               arms as (pattern_type, result_type) pairs in list pool

intrinsic:    [name_id, -, -, -, -, -, -]

type_call:    [callee, args_start, args_len, -, -, -, -]

forall:       [type_params_start, type_params_len, body, -, -, -, -]

spread:       [inner, -, -, -, -, -, -]

named:        [name_id, args_start, args_len, -, -, -, -]

cdata:        [ctype_id, -, -, -, -, -, -]
```

### Table fields

Stored in a separate field pool:

```c
typedef struct {
    int32_t name_id;    /* interned string */
    int32_t type_id;    /* index into type arena */
    uint8_t optional;
    uint8_t padding[3];
} FieldEntry;           /* 12 bytes */
```

Table types reference `(fields_start, fields_len)` into this pool. Field lookup
by name is a linear scan with integer comparison on `name_id`. For typical table
sizes (< 20 fields), this beats a hash table due to cache locality.

Meta slots use the same FieldEntry pool (meta_start, meta_len). Indexers use the
list pool as `(key_type_id, value_type_id)` pairs.

### Union-find for type variables

```lua
local function find(types, type_id)
    local t = types[type_id]
    if t.tag ~= TAG_VAR and t.tag ~= TAG_ROWVAR then
        return type_id
    end
    local bound = t.data[2]  -- BOUND slot
    if bound == 0 then return type_id end
    local root = find(types, bound)
    t.data[2] = root  -- path compression
    return root
end

local function bind(types, var_id, target_id)
    types[var_id].data[2] = target_id  -- set BOUND
end
```

Integer array ops, no allocation, no GC. JIT compiles to a tight loop with
path compression.

## Parser

Custom recursive descent parser outputting directly to the flat AST arena.
No intermediate table representation.

### Lexer

- Reads source bytes directly (or via `ffi.cast("const uint8_t*", source)`)
- Interns identifier/string tokens immediately → integer IDs
- Emits integer token types (not string names)
- Tracks line and column for error reporting

### Parser functions

Each parse function returns a node index (int32):

```lua
local function parse_binary_expr(min_prec)
    local left = parse_unary_expr()
    while precedence[token_type] >= min_prec do
        local op = token_type
        advance()
        local right = parse_binary_expr(precedence[op] + 1)
        local node = alloc_node()
        nodes[node].kind = NODE_BINARY_EXPR
        nodes[node].line = token_line
        nodes[node].col = token_col
        nodes[node].data[0] = op
        nodes[node].data[1] = left
        nodes[node].data[2] = right
        left = node
    end
    return left
end
```

Variable-length children use the list pool:

```lua
local function parse_block()
    local start = list_next
    while not at_block_end() do
        lists[list_next] = parse_stmt()
        list_next = list_next + 1
    end
    return start, list_next - start  -- (start, len)
end
```

### Annotation parser

Same approach — parses `--:` / `--::` comments and writes directly to the type
arena. Returns type IDs (int32), not type tables.

The annotation map is a simple array indexed by line number:

```lua
local ann_types = ffi.new("int32_t[?]", max_lines)  -- line → type_id (0 = none)
local ann_kinds = ffi.new("uint8_t[?]", max_lines)  -- 0=none, 1=type, 2=decl, 3=args
```

## Inference Walk

The inference logic stays in Lua — this is where hackability matters. It reads
FFI data structures but the control flow (scoping, narrowing, error reporting)
is idiomatic Lua.

### Dispatch

Integer-indexed dispatch tables:

```lua
local ExprRule = {}
ExprRule[NODE_IDENTIFIER] = function(ctx, node_id) ... end
ExprRule[NODE_BINARY_EXPR] = function(ctx, node_id) ... end
-- ...

local function infer_expr(ctx, node_id)
    local kind = ctx.nodes[node_id].kind
    return ExprRule[kind](ctx, node_id)
end
```

### Reading node data

```lua
-- Example: infer binary expression
ExprRule[NODE_BINARY_EXPR] = function(ctx, node_id)
    local node = ctx.nodes[node_id]
    local op    = node.data[0]
    local left  = infer_expr(ctx, node.data[1])
    local right = infer_expr(ctx, node.data[2])
    -- ... type logic ...
end
```

### Type construction

Instead of `T.func(params, returns)` returning a table, allocate in the type
arena:

```lua
local function alloc_type(tag)
    local id = type_next
    type_next = type_next + 1
    types[id].tag = tag
    types[id].flags = 0
    return id
end

local function make_func(params_start, params_len, returns_start, returns_len)
    local id = alloc_type(TAG_FUNCTION)
    types[id].data[0] = params_start
    types[id].data[1] = params_len
    types[id].data[2] = returns_start
    types[id].data[3] = returns_len
    types[id].data[4] = 0  -- no vararg
    types[id].data[5] = 0  -- no type_params
    types[id].data[6] = 0
    return id
end
```

### Scoping

Scopes remain Lua tables (not hot path, and need dynamic key lookup):

```lua
{
    bindings = {},       -- interned_name_id → type_id
    type_bindings = {},  -- interned_name_id → type alias entry
    parent = parent_scope,
    level = depth,
}
```

Lookup walks the parent chain as before, but keys and values are integers.

## Interface Format (.cri)

Crescent Interface files. Binary, fixed-layout, mmap-able, content-addressed.

### File layout

```
┌──────────────────────────────────────────┐  0x00
│  Header (64 bytes)                       │
│    magic:       "CRIF" (4 bytes)         │
│    version:     uint32                   │
│    flags:       uint32                   │
│    hash:        uint8[32] (SHA-256)      │
│    str_offset:  uint32                   │
│    type_offset: uint32                   │
│    field_offset:uint32                   │
│    list_offset: uint32                   │
│    export_offset: uint32                 │
│    padding to 64 bytes                   │
├──────────────────────────────────────────┤
│  String Table                            │
│    count:   uint32                       │
│    offsets: uint32[count+1]              │  ← byte offset of each string
│    data:    packed bytes                 │  ← no null terminators
├──────────────────────── aligned to 32 ───┤
│  Type Table                              │
│    count:   uint32                       │
│    pad to 32-byte alignment              │
│    slots:   TypeSlot[count]              │  ← 32 bytes each, castable
├──────────────────────────────────────────┤
│  Field Pool                              │
│    count:   uint32                       │
│    entries: FieldEntry[count]            │  ← 12 bytes each
├──────────────────────────────────────────┤
│  List Pool                               │
│    count:   uint32                       │
│    data:    int32_t[count]               │
├──────────────────────────────────────────┤
│  Export Table                            │
│    count:   uint32                       │
│    exports: { name_id: u32,              │
│               type_id: u32 }[count]      │
└──────────────────────────────────────────┘
```

### Loading (zero-copy)

```lua
local fd = ffi.C.open(path, O_RDONLY)
local size = fstat(fd).st_size
local ptr = ffi.C.mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0)
ffi.C.close(fd)

local header  = ffi.cast("CRIFHeader*", ptr)
local types   = ffi.cast("TypeSlot*",   ptr + header.type_offset)
local fields  = ffi.cast("FieldEntry*", ptr + header.field_offset)
local exports = ffi.cast("ExportEntry*", ptr + header.export_offset)
-- done. no parsing. no allocation. no GC.
```

`MAP_PRIVATE` on a read-only file: multiple workers mmap the same interface,
OS shares physical pages. One copy in RAM regardless of worker count.

### String ID remapping

String IDs in .cri files are file-local. On first access, build a remap table:

```lua
local remap = ffi.new("int32_t[?]", cri_string_count)
for i = 0, cri_string_count - 1 do
    remap[i] = intern(cri_string_at(ptr, i))
end
-- then: session_name_id = remap[cri_name_id]
```

O(exported strings), done once per interface load.

### Content addressing

The SHA-256 of the .cri file bytes (excluding the hash field itself) is the
interface's content address. Same exports → same bytes → same hash.

## Incremental Checking (Merkle DAG)

### Cache structure

```
.crescentcache/
  <content-hash>.cri          ← interface file
  manifest.lua                ← source_hash → interface_hash mapping
```

### Dependency check flow

```
1. Hash source file content
2. Check manifest: same source hash?
   YES → interface unchanged, mmap cached .cri
   NO  → check if dependency interfaces changed:
         Walk Merkle DAG upward from changed files
         For each file whose deps' interface hashes are unchanged:
           → re-check ONLY this file (deps are stable)
         For each file whose deps' interface hashes changed:
           → re-check this file AND propagate to its dependents
3. Write updated .cri files and manifest entries
```

### Interface stability optimization

If a file's source changed but its exported interface is identical to the
cached version (same .cri content hash), dependents are NOT re-checked.
This is strictly stronger than TypeScript's .tsbuildinfo (which re-checks
dependents on any source change).

Example: rename a local variable → source hash changes → re-check file →
exported interface identical → interface hash unchanged → zero propagation.

## Parallelism

### Batch mode (cold start)

```
1. Pre-pass: scan all files for `require()` calls → build dependency DAG
2. Topological sort → identify wave-fronts (files with all deps satisfied)
3. Fork N workers (one per CPU core) via libc fork()
4. Each worker:
   a. mmap dependency interfaces (already checked by prior waves)
   b. Parse + check assigned files
   c. Write .cri interface files
   d. Report diagnostics via pipe to parent
5. Parent coordinates wave-front advancement
```

Workers communicate via:
- **Pipes** for diagnostics (small, structured messages)
- **Filesystem** for .cri files (written by producer, mmap'd by consumer)
- **No shared mutable state** — each worker has its own type arena

### Adaptive worker count

Three modes based on changed set size:

| Changed files | Strategy              | Workers |
|---------------|-----------------------|---------|
| 1-5           | Synchronous           | 0 (inline) |
| 6-50          | Small worker pool     | 2-4     |
| 50+           | Full parallel         | N cores |

Fork overhead dominates for small change sets. Synchronous checking of 3 files
is faster than fork + coordinate + collect.

### Memory management

- Per-file arena: allocate during parse+check, free entire slab when done
- Peak memory bounded by: max(concurrent workers × largest file arena)
- Dependency interfaces: mmap'd, shared across workers, OS manages pages
- After all dependents checked: interface can be munmap'd (topological order
  gives natural eviction points)

## LSP Daemon Mode

### Architecture

```
crescent serve
  → single long-lived process
  → JSON-RPC over stdio (LSP protocol)
  → persistent state:
      - file watcher (inotify on Linux, kqueue on BSD/Mac) via FFI
      - tiered in-memory cache
      - incremental re-check on file save
```

### Memory tiers

```
hot  (open files):    full AST + type arena, immediately queryable
warm (recently used): interface only, AST evicted
cold (unchanged):     on-disk .cri only, nothing in memory
```

Effectively an LRU over ASTs, with interfaces as the cheap fallback. Transition:
- File opened → promote to hot (parse + check, keep AST)
- File closed → demote to warm (extract interface, free AST arena)
- File unchanged for N minutes → demote to cold (munmap interface)

### Incremental on save

```
1. File saved → re-lex + re-parse (full file, into fresh arena)
2. Re-check with current dependency interfaces
3. Extract new interface → compare hash to previous
4. If interface hash changed:
   a. Write new .cri
   b. Re-check open dependents (hot files only — warm/cold are lazy)
   c. Push diagnostics for affected files
5. If interface hash unchanged:
   → push diagnostics for this file only, no propagation
```

### Query support

With the full AST + type arena in memory for hot files:
- **Hover**: walk AST to find node at cursor position → return its inferred type
- **Go to definition**: identifier → scope lookup → declaration site
- **Find references**: scan AST for matching identifier name_ids
- **Completions**: infer type of expression before `.` → list fields
- **Diagnostics**: pushed on check, cached per-file

## Implementation Order

### Phase 1: Foundation
1. FFI struct definitions (ASTNode, TypeSlot, FieldEntry)
2. String interning module
3. Arena allocator (alloc, reset, grow)
4. List pool

### Phase 2: Parser
5. Lexer (integer tokens, string interning, line/col tracking)
6. Recursive descent parser → flat AST
7. Annotation parser → flat type arena

### Phase 3: Checker
8. Type arena operations (alloc, find, bind, construct helpers)
9. Unification on flat types
10. Inference walk (port logic from v1, read flat AST, write flat types)
11. Error reporting

### Phase 4: Caching
12. Interface extraction (checker output → .cri file)
13. .cri writer (binary format, aligned)
14. .cri loader (mmap + cast)
15. Manifest + content-addressed hash
16. Incremental check driver (hash diff → Merkle propagation → minimal re-check)

### Phase 5: Parallelism
17. Dependency graph builder (scan for require)
18. Topological sort + wave-front scheduler
19. Fork-based worker pool (libc fork/pipe/waitpid via FFI)
20. Adaptive worker count

### Phase 6: LSP
21. JSON-RPC protocol handler
22. File watcher (inotify/kqueue via FFI)
23. Daemon mode with tiered cache
24. LSP methods (hover, goto-def, completions, diagnostics)

## Design Constraints

### JIT friendliness

LuaJIT's tracing JIT performs best on:
- **Monomorphic call sites**: same function called with same argument types
- **Integer-indexed array access**: `arr[i]` compiles to a single load
- **Tight loops without allocation**: no table creation, no string ops
- **Predictable branches**: type tag dispatch should be consistent

Patterns to avoid in hot paths:
- `pairs()` on tables (NYI in some traces)
- String comparison for dispatch
- Polymorphic function calls (different types at same call site)
- Table creation in loops

### Memory layout

- 32-byte ASTNode: two per 64-byte cache line
- 32-byte TypeSlot: two per cache line
- 12-byte FieldEntry: ~5 per cache line
- Sequential access patterns: parse walks forward, inference walks forward
- Union-find: random access but bounded depth (path compression)

### Hackability

The inference logic (Phase 3) is where users hack. This stays in idiomatic Lua:
- Dispatch tables are Lua tables indexed by integer
- Type construction uses helper functions
- Scoping uses Lua tables (not hot path)
- Error messages are Lua strings
- Narrowing rules are plain Lua functions

The representation layer (Phases 1-2) is FFI machinery. Users don't hack AST
node layouts or type slot formats — they hack type rules.
