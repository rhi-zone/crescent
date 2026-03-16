-- lib/type/static/ctx.d.lua
-- Type declaration for the checker context (ctx) struct.
-- Loaded by prelude.populate() alongside stdlib.d.lua.
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
--:: FieldEntry = { name_id: integer, type_id: integer, optional: integer }

---------------------------------------------------------------------------
-- Arena types: wrap FFI flat-array arenas.
-- :get(i) returns a pointer to the struct (mutably accessible).
---------------------------------------------------------------------------

--:: ASTNodeArena = { get: (ASTNodeArena, any) -> ASTNode, len: integer, ... }
--:: TypeSlotArena = { get: (TypeSlotArena, any) -> TypeSlot, len: integer, ... }
--:: FieldEntryArena = { get: (FieldEntryArena, any) -> FieldEntry, len: integer, ... }

-- List pool: flat int32_t array. :get(i) returns integer.
--:: ListPool = { get: (ListPool, any) -> integer, len: integer, ... }

---------------------------------------------------------------------------
-- Diagnostic error codes (defs.E)
---------------------------------------------------------------------------

--:: DiagCodes = { FIELD_NOT_FOUND: integer, CALL_ARG_MISMATCH: integer, CALL_ARG_MISSING: integer, ARITH_TYPE: integer, LENGTH_TYPE: integer, COMPARE_TYPE: integer, COMPARE_CROSS: integer, CONCAT_TYPE: integer, UNHANDLED_EXPR: integer, UNKNOWN_IDENTIFIER: integer, VARARG_OUTSIDE_FN: integer, BINARY_OP_UNKNOWN: integer, TYPE_MISMATCH: integer, ASSIGN_MISMATCH: integer, FIELD_REASSIGN: integer, INDEX_ASSIGN_MISMATCH: integer, NO_MATCHING_OVERLOAD: integer, UNION_CALL_MISMATCH: integer, CANNOT_CALL: integer, METHOD_NOT_FOUND: integer, UNNAMED_PARAMS: integer, EXPLICIT_ANY: integer }

---------------------------------------------------------------------------
-- defs module type: all integer constants plus the E table.
-- Declaring `defs` here pre-populates the scope so that
--   local defs = require("lib.type.static.defs")
-- in infer.lua / constrain.lua uses this type (prescan wins over inferred any).
---------------------------------------------------------------------------

--[[::
DefsModule = {
  E: DiagCodes,
  ANN_TYPE: integer, ANN_DECL: integer, ANN_TYPE_ARGS: integer,
  FLAG_VARARG: integer, FLAG_LOCAL: integer, FLAG_COMPUTED: integer,
  FLAG_GENERIC: integer, FLAG_RECURSIVE: integer,
  TAG_NIL: integer, TAG_BOOLEAN: integer, TAG_NUMBER: integer,
  TAG_STRING: integer, TAG_ANY: integer, TAG_NEVER: integer,
  TAG_INTEGER: integer, TAG_UNKNOWN: integer, TAG_LITERAL: integer,
  TAG_FUNCTION: integer, TAG_TABLE: integer, TAG_UNION: integer,
  TAG_INTERSECTION: integer, TAG_VAR: integer, TAG_ROWVAR: integer,
  TAG_TUPLE: integer, TAG_NOMINAL: integer, TAG_MATCH_TYPE: integer,
  TAG_INTRINSIC: integer, TAG_TYPE_CALL: integer, TAG_FORALL: integer,
  TAG_SPREAD: integer, TAG_NAMED: integer, TAG_CDATA: integer,
  TAG_ENUM_MEMBER: integer,
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
  ...
}
]]

--:: declare defs = DefsModule

---------------------------------------------------------------------------
-- Local functions in infer.lua that have `-> unknown` return annotations.
-- Pre-declaring them here prevents the prescan from creating a generic
-- `(any, ...) -> TypeVar_` stub, which would conflict with the annotation's
-- `-> unknown` return type during constraint solving.
-- Using `-> any` instead of `-> unknown` is compatible because:
--   unify(any, T_UNKNOWN) succeeds (TAG_ANY check fires first).
---------------------------------------------------------------------------

--:: declare report = (Ctx, any, any, integer, any) -> any
--:: declare warn = (Ctx, any, any, integer, any) -> ()
--:: declare warn_raw = (Ctx, any, any, string) -> ()
--:: declare find_field_definition = (Ctx, any, any) -> any
--:: declare pop_return_collector = (Ctx) -> any
--:: declare infer_expr_multi = (Ctx, integer) -> any
--:: declare try_call_args = (Ctx, integer, any) -> any
--:: declare snapshot_table = (Ctx, any) -> (any, any, any, any)

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
  pool:         any,
  ann:          any,
  err:          any,
  scope:        any,
  numvals:      any,
  prim_index:   any,
  prim_meta:    any,
  return_types:       any,
  return_stub_vars:   any,
  module_types:       any,
  module_return_tids: any,
  cri_loader:         any,
  ffi_hooks:          any,
  _last_multi_return:        any,
  _last_pcall_success_types: any,
  _pcall_info:    any,
  inferred_anns:  any,
  var_counter:    integer,
  nominal_id:     integer,
  level:          integer,
  T_NIL:          integer,
  T_BOOLEAN:      integer,
  T_NUMBER:       integer,
  T_STRING:       integer,
  T_ANY:          integer,
  T_NEVER:        integer,
  T_INTEGER:      integer,
  T_UNKNOWN:      integer,
  filename:       string,
  ...
}
]]
