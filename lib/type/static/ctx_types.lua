-- lib/type/static/ctx_types.lua
-- Type declaration for the checker context (ctx) struct.
-- Loaded by prelude.populate_checker() when self-checking typechecker source files.
--
-- ctx is the central state object threaded through every typechecker function.
-- It holds all arenas, the intern pool, scope, and per-check bookkeeping.

--:: newtype TypeId = integer
--:: newtype InternId = integer
--:: newtype NodeId = integer
--:: newtype ListIdx = integer

---------------------------------------------------------------------------
-- FFI struct types: ASTNode, TypeSlot, FieldEntry
-- These mirror the ffi.cdef structs in defs.lua.
-- data fields use { [integer]: integer, ... } to type indexed access.
---------------------------------------------------------------------------

--:: ASTNode = { kind: integer, flags: integer, col: integer, line: integer, data: { [integer]: integer, ... } }
--:: TypeSlot = { tag: integer, flags: integer, reserved: integer, data: { [integer]: integer, ... } }
--:: FieldEntry = { name_id: integer, type_id: integer, flags: integer }

---------------------------------------------------------------------------
-- Arena types: wrap FFI flat-array arenas.
-- :get(i) returns a pointer to the struct (mutably accessible).
-- Index parameter is always integer (arena slot index).
---------------------------------------------------------------------------

--:: ASTNodeArena    = { get: (ASTNodeArena,    integer) -> ASTNode,    alloc: (ASTNodeArena)    -> integer, len: integer, ... }
--:: TypeSlotArena   = { get: (TypeSlotArena,   integer) -> TypeSlot,   alloc: (TypeSlotArena)   -> integer, len: integer, ... }
--:: FieldEntryArena = { get: (FieldEntryArena, integer) -> FieldEntry, alloc: (FieldEntryArena) -> integer, len: integer, ... }

-- List pool: flat int32_t array. :get(i) returns integer.
--:: ListPool = { get: (ListPool, integer) -> integer, len: integer, cap: integer, items: Ptr<integer>, mark: (ListPool) -> integer, push: (ListPool, integer) -> (), since: (ListPool, integer) -> (integer, integer), grow: (ListPool) -> (), reset: (ListPool) -> (), ... }

-- Intern pool: string interning table with hash map.
-- Mirrors StringPool in intern.lua so values flow without casts.
--:: InternPool = { ht_cap: integer, ht_mask: integer, ht_count: integer, next_id: integer, buf_count: integer, entries: { [integer]: unknown, ... }, bufs: { [integer]: unknown, ... }, rev: { [integer]: unknown, ... }, map: { [string]: integer, ... }, _anchors: { [integer]: string, ... }, _type_predicates: { [integer]: { param_idx: integer, type_id: integer }, ... } | nil, _assert_predicates: { [integer]: { param_idx: integer, type_id: integer }, ... } | nil, _pending_predicate: { param_idx: integer, type_id: integer, ... } | nil, _pending_assert_predicate: { param_idx: integer, type_id: integer, ... } | nil, ... }

-- Annotation arena result returned by ann.parse_annotations().
-- Types/fields/lists use the same arena shapes as the main checker.
--:: AnnResult = { types: TypeSlotArena, fields: FieldEntryArena, lists: ListPool, results: { [integer]: { kind: integer, name_id: integer, type_id: integer, decl_var: boolean, newtype: boolean, ... }, ... }, warnings: { [integer]: { line: integer, col: integer, msg: string, ... }, ... }, parse_errors: { [integer]: { line: integer, col: integer, msg: string, ... }, ... }, pool: InternPool, make_intersection: ({ [integer]: integer, ... }) -> integer }

-- Error context from errors.lua.
--:: DiagEntry = { kind: string, filename: string, line: integer, col: integer, msg: string, notes: { [integer]: { filename: string, line: integer, col: integer, msg: string }, ... } }
--:: ErrCtx = { errors: { [integer]: DiagEntry, ... }, warnings: { [integer]: DiagEntry, ... }, source_lines: { [string]: { [integer]: string, ... }, ... } }

-- Type alias table stored in scope.type_bindings.
--:: TypeAlias = { body: integer, params: { [integer]: integer, ... } | nil, raw_bounds: { [integer]: integer, ... } | nil, resolved_bounds: { [integer]: integer | nil, ... } | nil, raw_defaults: { [integer]: integer, ... } | nil, resolved_defaults: { [integer]: integer | nil, ... } | nil, nominal: boolean, ... }

-- Scope frame: linked list of binding tables.
--:: Scope = { bindings: { [integer]: integer, ... }, type_bindings: { [integer]: TypeAlias, ... }, annotation_types: { [integer]: integer, ... }, parent: Scope | nil, level: integer, narrowed_names: { [integer]: boolean, ... } | nil, ... }

-- Entry in ctx._multi_ret: tracks which source tuple a binding came from.
-- call_uid is the AST node ID of the call expression; used to correlate all bindings
-- from the same call site so narrowing is applied consistently across all return slots.
--:: MultiRetEntry = { source_tid: integer, slot: integer, call_uid: integer | nil }

-- Detail table returned by M.unify on error (for nested error paths).
--:: UnifyDetail = { kind: string, path: { [integer]: unknown, ... } | nil, got: integer, expected: integer, ... }

---------------------------------------------------------------------------
-- Diagnostic error codes (defs.E)
---------------------------------------------------------------------------

--:: DiagCodes = { FIELD_NOT_FOUND: integer, CALL_ARG_MISMATCH: integer, CALL_ARG_MISSING: integer, ARITH_TYPE: integer, LENGTH_TYPE: integer, COMPARE_TYPE: integer, COMPARE_CROSS: integer, CONCAT_TYPE: integer, UNHANDLED_EXPR: integer, UNKNOWN_IDENTIFIER: integer, VARARG_OUTSIDE_FN: integer, BINARY_OP_UNKNOWN: integer, TYPE_MISMATCH: integer, ASSIGN_MISMATCH: integer, FIELD_REASSIGN: integer, INDEX_ASSIGN_MISMATCH: integer, NO_MATCHING_OVERLOAD: integer, UNION_CALL_MISMATCH: integer, CANNOT_CALL: integer, METHOD_NOT_FOUND: integer, UNNAMED_PARAMS: integer, EXPLICIT_ANY: integer, FIELD_READONLY: integer, NON_EXHAUSTIVE: integer, FIELD_ON_PRIMITIVE: integer, CONSTRAINT_MISMATCH: integer, INDEX_KEY_NOT_FOUND: integer, FORCE_CAST_TO_ANY: integer, LOCAL_NEEDS_INIT: integer }

---------------------------------------------------------------------------
-- defs module type: all integer constants plus the E table.
-- Declaring `defs` here pre-populates the scope so that
--   local defs = require("lib.type.static.defs")
-- in constrain.lua uses this type (prescan wins over inferred type).
---------------------------------------------------------------------------

--[[::
DefsModule = {
  E: DiagCodes,
  ANN_TYPE: integer, ANN_DECL: integer, ANN_TYPE_ARGS: integer,
  FLAG_VARARG: integer, FLAG_LOCAL: integer, FLAG_COMPUTED: integer,
  FLAG_GENERIC: integer, FLAG_RECURSIVE: integer,
  FLAG_READONLY: integer, FLAG_OPTIONAL: integer, FLAG_PRIVATE: integer,
  TAG_NIL: integer, TAG_BOOLEAN: integer, TAG_NUMBER: integer,
  TAG_STRING: integer, TAG_ANY: integer, TAG_NEVER: integer,
  TAG_INTEGER: integer, TAG_UNKNOWN: integer, TAG_LITERAL: integer,
  TAG_FUNCTION: integer, TAG_TABLE: integer, TAG_UNION: integer,
  TAG_INTERSECTION: integer, TAG_VAR: integer, TAG_ROWVAR: integer,
  TAG_TUPLE: integer, TAG_NOMINAL: integer, TAG_MATCH_TYPE: integer,
  TAG_INTRINSIC: integer, TAG_TYPE_CALL: integer, TAG_FORALL: integer,
  TAG_SPREAD: integer, TAG_NAMED: integer, TAG_CDATA: integer,
  TAG_ENUM_MEMBER: integer, TAG_TYPEOF: integer,
  TAG_FFIC: integer, TAG_PAT_ALL_FIELDS: integer,
  TAG_PAT_REST_FIELDS: integer, TAG_PAT_META_SPREAD: integer,
  TAG_CAPTURE: integer,
  NODE_LITERAL: integer, NODE_IDENTIFIER: integer, NODE_UNARY_EXPR: integer,
  NODE_BINARY_EXPR: integer, NODE_INDEX_EXPR: integer, NODE_FIELD_EXPR: integer,
  NODE_METHOD_CALL: integer, NODE_CALL_EXPR: integer, NODE_FUNC_EXPR: integer,
  NODE_TABLE_EXPR: integer, NODE_TABLE_FIELD: integer, NODE_VARARG_EXPR: integer,
  NODE_ASSIGN_STMT: integer, NODE_LOCAL_STMT: integer, NODE_DO_STMT: integer,
  NODE_WHILE_STMT: integer, NODE_REPEAT_STMT: integer, NODE_IF_STMT: integer,
  NODE_IF_CLAUSE: integer, NODE_FOR_NUM: integer, NODE_FOR_IN: integer,
  NODE_RETURN_STMT: integer, NODE_BREAK_STMT: integer, NODE_GOTO_STMT: integer,
  NODE_LABEL_STMT: integer, NODE_EXPR_STMT: integer, NODE_FUNC_DECL: integer,
  NODE_CHUNK: integer, NUM_KEYWORDS: integer,
  LIT_STRING: integer, LIT_NUMBER: integer, LIT_BOOLEAN: integer,
  LIT_NIL: integer, LIT_INTEGER: integer,
  OP_ADD: integer, OP_SUB: integer, OP_MUL: integer, OP_DIV: integer,
  OP_MOD: integer, OP_POW: integer, OP_CONCAT: integer, OP_EQ: integer,
  OP_NE: integer, OP_LT: integer, OP_LE: integer, OP_GT: integer,
  OP_GE: integer, OP_AND: integer, OP_OR: integer, OP_UNM: integer,
  OP_NOT: integer, OP_LEN: integer,
  FLAG_OPAQUE_KEY: integer, LIT_OPAQUE_KEY: integer,
  NODE_CAST_EXPR: integer,
  fnv31: (string) -> integer,
  i32x2_to_double: (integer, integer) -> number,
  double_to_i32x2: (number) -> (integer, integer),
  keywords: { [integer]: string, ... },
  TK_AND: integer, TK_BREAK: integer, TK_DO: integer,
  TK_ELSE: integer, TK_ELSEIF: integer, TK_END: integer,
  TK_FALSE: integer, TK_FOR: integer, TK_FUNCTION: integer,
  TK_GOTO: integer, TK_IF: integer, TK_IN: integer,
  TK_LOCAL: integer, TK_NIL: integer, TK_NOT: integer,
  TK_OR: integer, TK_REPEAT: integer, TK_RETURN: integer,
  TK_THEN: integer, TK_TRUE: integer, TK_UNTIL: integer,
  TK_WHILE: integer, TK_CONCAT: integer, TK_DOTS: integer,
  TK_EQ: integer, TK_GE: integer, TK_LE: integer,
  TK_NE: integer, TK_LABEL: integer, TK_PLUS: integer,
  TK_MINUS: integer, TK_STAR: integer, TK_SLASH: integer,
  TK_PERCENT: integer, TK_CARET: integer, TK_HASH: integer,
  TK_AMPERSAND: integer, TK_TILDE: integer, TK_PIPE: integer,
  TK_LSHIFT: integer, TK_RSHIFT: integer, TK_DSLASH: integer,
  TK_LT: integer, TK_GT: integer, TK_ASSIGN: integer,
  TK_LPAREN: integer, TK_RPAREN: integer, TK_LBRACE: integer,
  TK_RBRACE: integer, TK_LBRACKET: integer, TK_RBRACKET: integer,
  TK_DCOLON: integer, TK_SEMICOLON: integer, TK_COLON: integer,
  TK_COMMA: integer, TK_DOT: integer, TK_NAME: integer,
  TK_NUMBER: integer, TK_STRING: integer, TK_EOF: integer,
  char_to_token: { [integer]: integer, ... },
  token_name: { [integer]: string, ... },
  ...
}
]]

--:: declare defs = DefsModule

---------------------------------------------------------------------------
-- Local functions declared in constrain.lua that are referenced before
-- their definition (prescan must see a typed stub, not an inferred var).
-- `report` returns the DiagEntry allocated by errors_mod.error(); callers
-- ignore the return value so -> () is the correct external signature.
---------------------------------------------------------------------------

--:: declare report = (ctx: Ctx, line: integer | nil, col: integer | nil, code: integer, args: { [string]: any, ... }) -> ()
--:: declare warn = (ctx: Ctx, line: integer | nil, col: integer | nil, code: integer, args: { [string]: any, ... }) -> ()
--:: declare warn_raw = (ctx: Ctx, line: integer | nil, col: integer | nil, msg: string) -> ()
-- snapshot_table: (ctx, TAG_TABLE type_id) -> (field_ids, indexer_pairs, row_var_id, meta_field_ids)
--:: declare snapshot_table = (ctx: Ctx, type_id: integer) -> ({ [integer]: integer, ... }, { [integer]: integer, ... }, integer, { [integer]: integer, ... })

---------------------------------------------------------------------------
-- Ctx: the central checker state object.
---------------------------------------------------------------------------

--[[::
Ctx = {
  types:        TypeSlotArena,
  fields:       FieldEntryArena,
  lists:        ListPool,
  ast_lists:    ListPool,
  nodes:        ASTNodeArena,
  pool:         InternPool,
  ann:          AnnResult | nil,
  err:          ErrCtx,
  scope:        Scope,
  numvals:      { [integer]: number, ... },
  prim_index:   { [integer]: integer, ... },
  prim_meta:    { [integer]: integer, ... },
  module_types: { [string]: integer, ... },
  module_return_tids: { [integer]: { [integer]: integer, ... }, ... } | nil,
  cri_loader:   ((Ctx, string) -> integer) | nil,
  ffi_hooks:    { process: (unknown, string) -> (), init: (unknown) -> (), ... } | nil,
  _last_multi_return:          { [integer]: integer, ... } | nil,
  _last_multi_return_override: integer | nil,
  _multi_ret:      { [integer]: MultiRetEntry, ... },
  _ann_warn_line:  integer,
  _ann_consumed:   { [integer]: boolean, ... } | nil,
  -- Constraint arrays are intentionally heterogeneous: values may be integer,
  -- string (op_name in C_ARITH), or { [integer]: integer, ... } (arg_tids in C_CALLABLE).
  -- Using any here because the type system cannot track per-index types in a table array.
  constraints:     { [integer]: { [integer]: any, ... }, ... },
  var_counter:  integer,
  nominal_id:   integer,
  level:        integer,
  T_NIL:        integer,
  T_BOOLEAN:    integer,
  T_NUMBER:     integer,
  T_STRING:     integer,
  T_ANY:        integer,
  T_NEVER:      integer,
  T_INTEGER:    integer,
  T_UNKNOWN:    integer,
  T_FFI_C:      integer | nil,
  filename:     string,
  -- LSP / annotation data fields populated by constrain.lua
  return_vars:     { [integer]: integer, ... },
  type_at:         { [integer]: integer, ... },
  name_at:         { [integer]: integer, ... },
  field_at:        { [integer]: integer, ... },
  def_sites:       { [integer]: { line: integer, col: integer, ... }, ... },
  require_sources: { [integer]: string, ... },
  type_origins:    { [integer]: string, ... },
  _resolving_func_ann_scope: boolean | nil,
  _in_match_arm:             boolean | nil,
  _allow_unapplied_constructors: boolean | nil,
  _forall_bounds:  { [integer]: integer, ... },
  lit_cache:       { [integer]: integer, ... },
  ...
}
]]
