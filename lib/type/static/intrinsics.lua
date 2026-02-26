-- lib/type/static/intrinsics.lua
-- Built-in type intrinsics: $EachField, $EachUnion, $Keys, etc.

local types = require("lib.type.static.types")

local M = {}

-- $Keys<T> — extract keys of a table type as a union of literal strings.
function M.Keys(args)
  if #args ~= 1 then return types.NEVER() end
  local t = types.resolve(args[1])
  if t.tag ~= "table" then return types.NEVER() end
  local keys = {}
  for name in pairs(t.fields) do
    keys[#keys + 1] = types.literal("string", name)
  end
  if #keys == 0 then return types.NEVER() end
  if #keys == 1 then return keys[1] end
  return types.union(keys)
end

-- $EachField<T, Transform> — apply Transform to each field of T.
-- Transform should be a type alias that takes (key, value) and returns new value.
-- For simplicity, evaluates Transform as a match type or type call.
function M.EachField(args)
  if #args < 1 then return types.NEVER() end
  local t = types.resolve(args[1])
  if t.tag ~= "table" then return types.NEVER() end

  local transform = args[2]
  if not transform then
    -- Without transform, return the type as-is
    return t
  end

  -- Apply transform to each field (simplified: wrap each value with optional marker)
  local fields = {}
  for name, f in pairs(t.fields) do
    -- For now, we pass through — full transform evaluation comes with match types
    fields[name] = { type = f.type, optional = f.optional }
  end
  return types.table(fields, t.indexers, t.row)
end

-- $EachUnion<T, Transform> — apply Transform to each member of a union.
function M.EachUnion(args)
  if #args < 2 then return types.NEVER() end
  local t = types.resolve(args[1])
  if t.tag ~= "union" then return t end

  -- Simplified: return the union as-is
  -- Full implementation requires evaluating transform per member
  return t
end

-- Dispatch table
M.dispatch = {
  Keys = M.Keys,
  EachField = M.EachField,
  EachUnion = M.EachUnion,
}

-- Evaluate an intrinsic with given args.
function M.evaluate(name, args)
  local handler = M.dispatch[name]
  if handler then
    return handler(args)
  end
  return types.ANY()
end

return M
