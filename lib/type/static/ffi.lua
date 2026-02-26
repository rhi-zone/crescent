-- lib/type/static/ffi.lua
-- Bridge between cparser and the static typechecker.
-- Detects ffi.cdef calls and converts C type AST to checker types.

local types = require("lib.type.static.types")

local T = types

local M = {}

-- Convert a cparser type node to a checker type
function M.convert_ctype(cnode)
  if not cnode then return T.ANY() end
  local tag = cnode.tag

  if tag == "Type" then
    local name = cnode.name
    if name == "void" then return T.NIL() end
    if name == "int" or name == "long" or name == "short"
      or name == "unsigned" or name == "signed"
      or name == "int8_t" or name == "int16_t" or name == "int32_t" or name == "int64_t"
      or name == "uint8_t" or name == "uint16_t" or name == "uint32_t" or name == "uint64_t"
      or name == "size_t" or name == "ssize_t" or name == "ptrdiff_t"
      or name == "intptr_t" or name == "uintptr_t" then
      return T.INTEGER()
    end
    if name == "float" or name == "double" then
      return T.NUMBER()
    end
    if name == "char" then
      return T.INTEGER()
    end
    if name == "bool" or name == "_Bool" then
      return T.BOOLEAN()
    end
    -- Typedef — follow the chain
    if cnode._def then
      return M.convert_ctype(cnode._def)
    end
    return T.cdata(cnode)
  end

  if tag == "Qualified" then
    return M.convert_ctype(cnode.t)
  end

  if tag == "Pointer" then
    -- Pointer to char => string (common pattern)
    local inner = cnode.t
    if inner and inner.tag == "Type" and inner.name == "char" then
      return T.STRING()
    end
    if inner and inner.tag == "Qualified" and inner.t
      and inner.t.tag == "Type" and inner.t.name == "char" then
      return T.STRING()
    end
    return T.cdata(cnode)
  end

  if tag == "Array" then
    return T.cdata(cnode)
  end

  if tag == "Function" then
    local params = {}
    for i = 1, #cnode do
      local param = cnode[i]
      if param then
        params[i] = M.convert_ctype(param[1])
      end
    end
    local returns = { M.convert_ctype(cnode.t) }
    return T.func(params, returns)
  end

  if tag == "Struct" or tag == "Union" then
    local fields = {}
    for i = 1, #cnode do
      local field = cnode[i]
      if field and field[2] then
        fields[field[2]] = { type = M.convert_ctype(field[1]), optional = false }
      end
    end
    return T.table(fields, {})
  end

  if tag == "Enum" then
    return T.INTEGER()
  end

  return T.cdata(cnode)
end

-- Extract ffi.cdef string from an AST CallExpression node
-- Returns the cdef string or nil
function M.extract_cdef_string(node)
  if node.kind ~= "CallExpression" then return nil end
  local callee = node.callee
  if callee.kind ~= "MemberExpression" then return nil end
  if callee.computed then return nil end
  if callee.property.name ~= "cdef" then return nil end
  if callee.object.kind ~= "Identifier" or callee.object.name ~= "ffi" then return nil end
  if #node.arguments < 1 then return nil end
  local arg = node.arguments[1]
  if arg.kind == "Literal" and type(arg.value) == "string" then
    return arg.value
  end
  return nil
end

-- Process a cdef string and return a table of { name -> type }
function M.process_cdef(cdef_str)
  local results = {}
  local ok, cparser = pcall(require, "cparser")
  if not ok then return results end

  local line_iter = cdef_str:gmatch("[^\n]+")
  local pok, iter, symbols = pcall(cparser.declarationIterator, { silent = true }, line_iter)
  if not pok then return results end

  -- Drain the iterator to populate symbols
  if iter then
    for action in iter do
      -- Just iterate to populate symbols table
    end
  end

  if symbols then
    for name, sym in pairs(symbols) do
      if sym.type then
        results[name] = M.convert_ctype(sym.type)
      end
    end
  end

  return results
end

return M
