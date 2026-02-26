-- lib/type/static/match.lua
-- Match type evaluation engine.
-- Evaluates match types: match T { pattern => result, ... }

local types = require("lib.type.static.types")

local M = {}

-- Check if a type matches a pattern (for match type arms).
-- Returns (true, bindings) or (false, nil).
-- Bindings is a table of { name -> type } for type variables in the pattern.
function M.match_pattern(ty, pattern)
  ty = types.resolve(ty)
  pattern = types.resolve(pattern)

  -- Any pattern matches everything
  if pattern.tag == "any" then return true, {} end

  -- Named pattern (type variable in match context): binds to the type
  if pattern.tag == "named" and #pattern.args == 0 then
    return true, { [pattern.name] = ty }
  end

  -- Exact primitive match
  if ty.tag == pattern.tag then
    if ty.tag == "nil" or ty.tag == "boolean" or ty.tag == "number"
      or ty.tag == "integer" or ty.tag == "string" then
      return true, {}
    end
    if ty.tag == "literal" then
      if ty.kind == pattern.kind and ty.value == pattern.value then
        return true, {}
      end
      return false, nil
    end
  end

  -- Subtype matching
  if ty.tag == "integer" and pattern.tag == "number" then
    return true, {}
  end
  if ty.tag == "literal" then
    if ty.kind == "string" and pattern.tag == "string" then return true, {} end
    if ty.kind == "number" and pattern.tag == "number" then return true, {} end
    if ty.kind == "boolean" and pattern.tag == "boolean" then return true, {} end
  end

  return false, nil
end

-- Evaluate a match type.
-- match_ty: { tag = "match_type", param = type, arms = { { pattern, result }, ... } }
-- Returns the result type of the first matching arm, or never.
function M.evaluate(match_ty, seen)
  seen = seen or {}

  -- Cycle detection
  local key = tostring(match_ty)
  if seen[key] then return types.NEVER() end
  seen[key] = true

  local param = types.resolve(match_ty.param)

  for i = 1, #match_ty.arms do
    local arm = match_ty.arms[i]
    local ok, bindings = M.match_pattern(param, arm.pattern)
    if ok then
      -- Substitute bindings into result
      if bindings and next(bindings) then
        local env = require("lib.type.static.env")
        return env.substitute(arm.result, bindings)
      end
      return arm.result
    end
  end

  return types.NEVER()
end

return M
