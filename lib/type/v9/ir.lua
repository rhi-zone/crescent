-- lib/type/v9/ir.lua
-- IR / AST seam — de-Bruijn CANONICAL core, mirrors proof `tm` (typing.v).
--
-- The semantic identity of a node is its de-Bruijn structure (`tag` + `index` +
-- children). Source names ride along in `names` as NON-SEMANTIC metadata for
-- diagnostics only: two terms that are alpha-equivalent have identical IR up to
-- `names`, so renaming a binder NEVER changes typing. Adding a new term former
-- is a LOCAL change: a constructor here + a `synth`/`check` arm + (optionally) a
-- diagnostic — no cross-cutting edit.

--:: require "lib.type.v9.type_defs"

local M = {}

--: (string | nil) -> Names
local function names(source)
    if source == nil then return {} end
    return { source = source }
end
M.names = names

--: (string | nil) -> IrNode
function M.lit_int(source) return { tag = "lit", lit = { kind = "int" }, names = names(source) } end
--: (string, string | nil) -> IrNode
function M.lit_str(value, source) return { tag = "lit", lit = { kind = "str", value = value }, names = names(source) } end
--: (boolean, string | nil) -> IrNode
function M.lit_bool(value, source) return { tag = "lit", lit = { kind = "bool", value = value }, names = names(source) } end
--: (string | nil) -> IrNode
function M.lit_nil(source) return { tag = "lit", lit = { kind = "nil" }, names = names(source) } end

-- De-Bruijn variable. `index` 0 = innermost binder (matches proof `tvar n` with
-- `nth_error G n`). `source` is the original surface name, for diagnostics only.
--: (integer, string | nil) -> IrNode
function M.var(index, source) return { tag = "var", index = index, names = names(source) } end

--: (Ty, IrNode, string | nil) -> IrNode
function M.lam(param_type, body, source) return { tag = "lam", param_type = param_type, body = body, names = names(source) } end

--: (IrNode, IrNode) -> IrNode
function M.app(fn, arg) return { tag = "app", fn = fn, arg = arg, names = {} } end

--: (IrNode, IrNode, string | nil) -> IrNode
function M.let_(value, body, source) return { tag = "let", value = value, body = body, names = names(source) } end

return M
