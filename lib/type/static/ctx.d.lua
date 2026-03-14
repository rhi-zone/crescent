-- lib/type/static/ctx.d.lua
-- Type declaration for the checker context (ctx) struct.
-- Loaded by prelude.populate() alongside stdlib.d.lua.
--
-- ctx is the central state object threaded through every typechecker function.
-- It holds all arenas, the intern pool, scope, and per-check bookkeeping.
--
-- All arena/pool fields are declared as `any` because they are opaque FFI
-- objects (TypeSlot*, FieldEntry*, int32_t*) whose methods cannot be described
-- in the annotation language without full FFI ctype support.

--[[::
Ctx = {
  types:        any,
  fields:       any,
  lists:        any,
  ast_lists:    any,
  nodes:        any,
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
  var_counter:    number,
  nominal_id:     number,
  level:          number,
  T_NIL:          number,
  T_BOOLEAN:      number,
  T_NUMBER:       number,
  T_STRING:       number,
  T_ANY:          number,
  T_NEVER:        number,
  T_INTEGER:      number,
  T_UNKNOWN:      number,
  filename:       string,
  ...
}
]]
