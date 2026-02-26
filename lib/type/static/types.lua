-- lib/type/static/types.lua
-- Type representation for the static typechecker.
-- Every type is a plain table with a `tag` field. Pattern-match on `tag`.

local M = {}

local var_counter = 0

-- Constructors

function M.NIL()
  return { tag = "nil" }
end

function M.BOOLEAN()
  return { tag = "boolean" }
end

function M.NUMBER()
  return { tag = "number" }
end

function M.INTEGER()
  return { tag = "integer" }
end

function M.STRING()
  return { tag = "string" }
end

function M.ANY()
  return { tag = "any" }
end

function M.NEVER()
  return { tag = "never" }
end

function M.literal(kind, value)
  return { tag = "literal", kind = kind, value = value }
end

function M.func(params, returns, vararg)
  return { tag = "function", params = params, returns = returns, vararg = vararg }
end

function M.table(fields, indexers, row)
  return { tag = "table", fields = fields or {}, indexers = indexers or {}, row = row }
end

function M.union(types)
  -- Flatten nested unions and deduplicate
  local flat = {}
  for i = 1, #types do
    local t = types[i]
    if t.tag == "union" then
      for j = 1, #t.types do
        flat[#flat + 1] = t.types[j]
      end
    elseif t.tag ~= "never" then
      flat[#flat + 1] = t
    end
  end
  if #flat == 0 then return M.NEVER() end
  if #flat == 1 then return flat[1] end
  return { tag = "union", types = flat }
end

function M.intersection(types)
  local flat = {}
  for i = 1, #types do
    local t = types[i]
    if t.tag == "intersection" then
      for j = 1, #t.types do
        flat[#flat + 1] = t.types[j]
      end
    elseif t.tag ~= "any" then
      flat[#flat + 1] = t
    end
  end
  if #flat == 0 then return M.ANY() end
  if #flat == 1 then return flat[1] end
  return { tag = "intersection", types = flat }
end

function M.typevar(level)
  var_counter = var_counter + 1
  return { tag = "var", id = var_counter, level = level or 0 }
end

function M.rowvar(level)
  var_counter = var_counter + 1
  return { tag = "rowvar", id = var_counter, level = level or 0 }
end

function M.cdata(ctype)
  return { tag = "cdata", ctype = ctype }
end

function M.array(elem)
  return M.table({}, {{ key = M.NUMBER(), value = elem }})
end

function M.dict(key_ty, val_ty)
  return M.table({}, {{ key = key_ty, value = val_ty }})
end

function M.optional(ty)
  return M.union({ ty, M.NIL() })
end

-- Resolve union-find chain for type variables
function M.resolve(ty)
  while ty.tag == "var" and ty.bound and ty.bound.tag == "var" do
    ty = ty.bound
  end
  if ty.tag == "var" and ty.bound then
    return ty.bound
  end
  return ty
end

-- Display a type as a string (for error messages)
function M.display(ty)
  ty = M.resolve(ty)
  local tag = ty.tag

  if tag == "nil" or tag == "boolean" or tag == "number"
    or tag == "integer" or tag == "string"
    or tag == "any" or tag == "never" then
    return tag
  end

  if tag == "literal" then
    if ty.kind == "string" then
      return '"' .. tostring(ty.value) .. '"'
    end
    return tostring(ty.value)
  end

  if tag == "function" then
    local parts = {}
    for i = 1, #ty.params do
      parts[#parts + 1] = M.display(ty.params[i])
    end
    if ty.vararg then
      parts[#parts + 1] = "..." .. M.display(ty.vararg)
    end
    local ret
    if #ty.returns == 0 then
      ret = "()"
    elseif #ty.returns == 1 then
      ret = M.display(ty.returns[1])
    else
      local rs = {}
      for i = 1, #ty.returns do
        rs[#rs + 1] = M.display(ty.returns[i])
      end
      ret = "(" .. table.concat(rs, ", ") .. ")"
    end
    return "(" .. table.concat(parts, ", ") .. ") -> " .. ret
  end

  if tag == "table" then
    local parts = {}
    -- Sort field names for stable output
    local names = {}
    for name in pairs(ty.fields) do
      names[#names + 1] = name
    end
    table.sort(names)
    for _, name in ipairs(names) do
      local f = ty.fields[name]
      local opt = f.optional and "?" or ""
      parts[#parts + 1] = name .. opt .. ": " .. M.display(f.type)
    end
    for i = 1, #ty.indexers do
      local idx = ty.indexers[i]
      parts[#parts + 1] = "[" .. M.display(idx.key) .. "]: " .. M.display(idx.value)
    end
    return "{ " .. table.concat(parts, ", ") .. " }"
  end

  if tag == "union" then
    local parts = {}
    for i = 1, #ty.types do
      parts[#parts + 1] = M.display(ty.types[i])
    end
    return table.concat(parts, " | ")
  end

  if tag == "intersection" then
    local parts = {}
    for i = 1, #ty.types do
      parts[#parts + 1] = M.display(ty.types[i])
    end
    return table.concat(parts, " & ")
  end

  if tag == "var" then
    return "'" .. ty.id
  end

  if tag == "rowvar" then
    return "...'" .. ty.id
  end

  if tag == "cdata" then
    return "cdata"
  end

  return "?"
end

-- Reset counter (for testing)
function M.reset_counter()
  var_counter = 0
end

return M
