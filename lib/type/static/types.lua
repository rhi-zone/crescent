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

function M.table(fields, indexers, row, meta)
  return { tag = "table", fields = fields or {}, indexers = indexers or {}, row = row, meta = meta or {} }
end

function M.union(types)
  -- Flatten nested unions; eliminate `never` (bottom) and short-circuit on `any` (top).
  local flat = {}
  for i = 1, #types do
    local t = types[i]
    if t.tag == "any" then return M.ANY() end  -- any dominates union
    if t.tag == "union" then
      for j = 1, #t.types do
        local m = t.types[j]
        if m.tag == "any" then return M.ANY() end
        flat[#flat + 1] = m
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

function M.tuple(elements)
  return { tag = "tuple", elements = elements }
end

function M.field_descriptor(key, value, optional, readonly)
  return { tag = "field_descriptor", key = key, value = value, optional = optional or false, readonly = readonly or false }
end

function M.spread(inner)
  return { tag = "spread", inner = inner }
end

function M.nominal(name, identity, underlying)
  return { tag = "nominal", name = name, identity = identity, underlying = underlying }
end

function M.match_type(param, arms)
  return { tag = "match_type", param = param, arms = arms }
end

function M.intrinsic(name)
  return { tag = "intrinsic", name = name }
end

function M.type_call(callee, args)
  return { tag = "type_call", callee = callee, args = args }
end

-- Widen a literal type to its base type.
-- literal("number", 42) -> NUMBER(), literal("string", "x") -> STRING(), etc.
function M.widen(ty)
  ty = M.resolve(ty)
  if ty.tag == "literal" then
    if ty.kind == "number" then return M.NUMBER() end
    if ty.kind == "string" then return M.STRING() end
    if ty.kind == "boolean" then return M.BOOLEAN() end
  end
  return ty
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

-- Display a type as a string (for error messages).
-- seen: optional set of table types already being displayed (cycle detection).
function M.display(ty, seen)
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
      parts[#parts + 1] = M.display(ty.params[i], seen)
    end
    if ty.vararg then
      parts[#parts + 1] = "..." .. M.display(ty.vararg, seen)
    end
    local ret
    if #ty.returns == 0 then
      ret = "()"
    elseif #ty.returns == 1 then
      ret = M.display(ty.returns[1], seen)
    else
      local rs = {}
      for i = 1, #ty.returns do
        rs[#rs + 1] = M.display(ty.returns[i], seen)
      end
      ret = "(" .. table.concat(rs, ", ") .. ")"
    end
    return "(" .. table.concat(parts, ", ") .. ") -> " .. ret
  end

  if tag == "table" then
    -- Cycle detection: circular table types (e.g. M.__index = M) display as "{...}"
    seen = seen or {}
    if seen[ty] then return "{...}" end
    seen[ty] = true
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
      parts[#parts + 1] = name .. opt .. ": " .. M.display(f.type, seen)
    end
    for i = 1, #ty.indexers do
      local idx = ty.indexers[i]
      parts[#parts + 1] = "[" .. M.display(idx.key, seen) .. "]: " .. M.display(idx.value, seen)
    end
    local meta_names = {}
    for name in pairs(ty.meta or {}) do meta_names[#meta_names + 1] = name end
    table.sort(meta_names)
    for _, name in ipairs(meta_names) do
      local f = ty.meta[name]
      local opt = f.optional and "?" or ""
      parts[#parts + 1] = "#" .. name .. opt .. ": " .. M.display(f.type, seen)
    end
    seen[ty] = nil
    return "{ " .. table.concat(parts, ", ") .. " }"
  end

  if tag == "union" then
    local parts = {}
    for i = 1, #ty.types do
      parts[#parts + 1] = M.display(ty.types[i], seen)
    end
    return table.concat(parts, " | ")
  end

  if tag == "intersection" then
    local parts = {}
    for i = 1, #ty.types do
      parts[#parts + 1] = M.display(ty.types[i], seen)
    end
    return table.concat(parts, " & ")
  end

  if tag == "var" then
    return "'" .. ty.id
  end

  if tag == "rowvar" then
    return "...'" .. ty.id
  end

  if tag == "named" then
    if ty.args and #ty.args > 0 then
      local parts = {}
      for i = 1, #ty.args do
        parts[#parts + 1] = M.display(ty.args[i], seen)
      end
      return ty.name .. "<" .. table.concat(parts, ", ") .. ">"
    end
    return ty.name
  end

  if tag == "tuple" then
    local parts = {}
    for i = 1, #ty.elements do
      parts[#parts + 1] = M.display(ty.elements[i], seen)
    end
    return "{ " .. table.concat(parts, ", ") .. " }"
  end

  if tag == "spread" then
    return "..." .. M.display(ty.inner, seen)
  end

  if tag == "nominal" then
    return ty.name
  end

  if tag == "match_type" then
    return "match " .. M.display(ty.param, seen) .. " { ... }"
  end

  if tag == "intrinsic" then
    return "$" .. ty.name
  end

  if tag == "type_call" then
    local parts = {}
    for i = 1, #ty.args do
      parts[#parts + 1] = M.display(ty.args[i], seen)
    end
    return M.display(ty.callee, seen) .. "(" .. table.concat(parts, ", ") .. ")"
  end

  if tag == "field_descriptor" then
    local prefix = ty.readonly and "readonly " or ""
    local opt = ty.optional and "?" or ""
    return prefix .. M.display(ty.key, seen) .. opt .. ": " .. M.display(ty.value, seen)
  end

  if tag == "cdata" then
    return "cdata"
  end

  return "?"
end

-- Render `ty` (the expected type) with the field at `path` annotated as a
-- mismatch: ✗expected_type (got actual_type).
--
-- path    — list of field names leading to the mismatch, e.g. {"address","zip"}
-- got_ty  — the actual (wrong) type found at the end of the path
-- colors  — table {err, reset, ...} from errors.get_colors(); plain strings ok
--
-- Only table fields are walked; any other node type falls back to M.display.
function M.display_annotated(ty, path, got_ty, colors)
  ty = M.resolve(ty)
  local c = colors or {}
  local err_open  = c.err   or ""
  local reset     = c.reset or ""

  if #path == 0 then
    -- Mismatch site: ✗expected_type (got actual_type)
    return err_open .. "\xE2\x9C\x97" .. M.display(ty) ..
           " (got " .. M.display(M.resolve(got_ty)) .. ")" .. reset
  end

  if ty.tag == "table" then
    local target = path[1]
    local rest   = {}
    for i = 2, #path do rest[#rest + 1] = path[i] end

    local names = {}
    for name in pairs(ty.fields) do names[#names + 1] = name end
    table.sort(names)

    local parts = {}
    for _, name in ipairs(names) do
      local f   = ty.fields[name]
      local opt = f.optional and "?" or ""
      if name == target then
        parts[#parts + 1] = name .. opt .. ": " ..
          M.display_annotated(f.type, rest, got_ty, colors)
      else
        parts[#parts + 1] = name .. opt .. ": " .. M.display(f.type)
      end
    end
    for i = 1, #ty.indexers do
      local idx = ty.indexers[i]
      parts[#parts + 1] = "[" .. M.display(idx.key) .. "]: " .. M.display(idx.value)
    end
    return "{ " .. table.concat(parts, ", ") .. " }"
  end

  -- Can't follow path through a non-table — fall back to plain display
  return M.display(ty)
end

-- Subtract a type from a union: remove members that match `exclude`.
-- Returns the remaining type.
function M.subtract(ty, exclude)
  ty = M.resolve(ty)
  exclude = M.resolve(exclude)
  if ty.tag == "union" then
    local remaining = {}
    for i = 1, #ty.types do
      local member = M.resolve(ty.types[i])
      if not M.types_equal(member, exclude) then
        remaining[#remaining + 1] = member
      end
    end
    if #remaining == 0 then return M.NEVER() end
    if #remaining == 1 then return remaining[1] end
    return M.union(remaining)
  end
  -- Single type: if it matches exclude, return never
  if M.types_equal(ty, exclude) then return M.NEVER() end
  return ty
end

-- Narrow a union by a field discriminant: `x.field == lit_value`.
-- positive=true: keep members where field COULD be lit_value.
-- positive=false: remove members where field is DEFINITELY lit_value.
function M.narrow_by_field(ty, field, lit_value, positive)
  ty = M.resolve(ty)
  if ty.tag ~= "union" then
    -- Single (non-union) type: check if the field has a definite non-matching literal.
    -- If so, the branch is impossible → narrow to NEVER (dead code).
    if ty.tag == "table" then
      local f = ty.fields[field]
      if f then
        local fty = M.resolve(f.type)
        if fty.tag == "literal" and fty.kind == "string" then
          local definite_match = (fty.value == lit_value)
          if positive and not definite_match then return M.NEVER() end
          if not positive and definite_match then return M.NEVER() end
        end
      end
    end
    return ty
  end
  local result = {}
  for i = 1, #ty.types do
    local m = M.resolve(ty.types[i])
    local definite_match = false   -- field is definitely == lit_value
    local possible_match = true    -- field could be == lit_value
    if m.tag == "table" then
      local f = m.fields[field]
      if f then
        local fty = M.resolve(f.type)
        if fty.tag == "literal" and fty.kind == "string" then
          definite_match = (fty.value == lit_value)
          possible_match = definite_match
        end
      end
    elseif m.tag ~= "any" and m.tag ~= "var" then
      -- Non-table, non-any types don't have fields; they can't match.
      definite_match = false
      possible_match = false
    end
    if positive then
      if possible_match then result[#result + 1] = m end
    else
      if not definite_match then result[#result + 1] = m end
    end
  end
  if #result == 0 then return M.NEVER() end
  if #result == 1 then return result[1] end
  return M.union(result)
end

-- Narrow a type to only members that match `target`.
function M.narrow_to(ty, target)
  ty = M.resolve(ty)
  target = M.resolve(target)
  if ty.tag == "union" then
    local matching = {}
    for i = 1, #ty.types do
      local member = M.resolve(ty.types[i])
      if M.types_equal(member, target) or M.is_subtype_tag(member, target) then
        matching[#matching + 1] = member
      end
    end
    if #matching == 0 then return target end
    if #matching == 1 then return matching[1] end
    return M.union(matching)
  end
  return target
end

-- Check if two types are structurally equal (shallow).
function M.types_equal(a, b)
  a = M.resolve(a)
  b = M.resolve(b)
  if a.tag ~= b.tag then return false end
  if a.tag == "literal" then return a.kind == b.kind and a.value == b.value end
  -- For primitives, same tag = equal
  if a.tag == "nil" or a.tag == "boolean" or a.tag == "number"
    or a.tag == "integer" or a.tag == "string"
    or a.tag == "any" or a.tag == "never" then
    return true
  end
  return a == b -- reference equality for complex types
end

-- Check if a member's tag is compatible with a target type (for narrowing).
function M.is_subtype_tag(member, target)
  if target.tag == "number" and (member.tag == "integer" or (member.tag == "literal" and member.kind == "number")) then
    return true
  end
  if target.tag == "string" and (member.tag == "literal" and member.kind == "string") then
    return true
  end
  if target.tag == "boolean" and (member.tag == "literal" and member.kind == "boolean") then
    return true
  end
  return false
end

-- Map type() string results to type tags
M.typeof_map = {
  ["nil"] = "nil",
  ["boolean"] = "boolean",
  ["number"] = "number",
  ["string"] = "string",
  ["table"] = "table",
  ["function"] = "function",
}

-- Reset counter (for testing)
function M.reset_counter()
  var_counter = 0
end

return M
