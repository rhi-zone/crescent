-- lib/type/static/unify.lua
-- HM unification extended for structural types.

local types = require("lib.type.static.types")

local M = {}

-- Occurs check: does var `v` appear in type `ty`?
local function occurs(v, ty)
  ty = types.resolve(ty)
  if ty.tag == "var" then return ty.id == v.id end
  if ty.tag == "function" then
    for i = 1, #ty.params do
      if occurs(v, ty.params[i]) then return true end
    end
    for i = 1, #ty.returns do
      if occurs(v, ty.returns[i]) then return true end
    end
    if ty.vararg and occurs(v, ty.vararg) then return true end
    return false
  end
  if ty.tag == "table" then
    for _, f in pairs(ty.fields) do
      if occurs(v, f.type) then return true end
    end
    for i = 1, #ty.indexers do
      if occurs(v, ty.indexers[i].key) or occurs(v, ty.indexers[i].value) then return true end
    end
    return false
  end
  if ty.tag == "union" or ty.tag == "intersection" then
    for i = 1, #ty.types do
      if occurs(v, ty.types[i]) then return true end
    end
    return false
  end
  return false
end

-- Adjust levels: lower the level of free vars in `ty` to `max_level`
local function adjust_levels(ty, max_level)
  ty = types.resolve(ty)
  if ty.tag == "var" then
    if ty.level > max_level then ty.level = max_level end
    return
  end
  if ty.tag == "function" then
    for i = 1, #ty.params do adjust_levels(ty.params[i], max_level) end
    for i = 1, #ty.returns do adjust_levels(ty.returns[i], max_level) end
    if ty.vararg then adjust_levels(ty.vararg, max_level) end
    return
  end
  if ty.tag == "table" then
    for _, f in pairs(ty.fields) do adjust_levels(f.type, max_level) end
    for i = 1, #ty.indexers do
      adjust_levels(ty.indexers[i].key, max_level)
      adjust_levels(ty.indexers[i].value, max_level)
    end
    return
  end
  if ty.tag == "union" or ty.tag == "intersection" then
    for i = 1, #ty.types do adjust_levels(ty.types[i], max_level) end
    return
  end
end

-- Bind a type variable to a type
local function bind_var(v, ty)
  if occurs(v, ty) then
    return false, "recursive type"
  end
  adjust_levels(ty, v.level)
  v.bound = ty
  return true
end

-- Check if a is a subtype of b (for assignability).
-- Returns true if a is assignable to b, or (false, message).
function M.unify(a, b)
  a = types.resolve(a)
  b = types.resolve(b)

  -- Named types should be resolved before unification.
  -- If we still see a named type here, treat it as any (unresolved alias).
  if a.tag == "named" then return true end
  if b.tag == "named" then return true end

  -- Same reference
  if a == b then return true end

  -- any is bilateral
  if a.tag == "any" or b.tag == "any" then return true end

  -- never is bottom: assignable to everything
  if a.tag == "never" then return true end

  -- Type variable binding
  if a.tag == "var" then
    return bind_var(a, b)
  end
  if b.tag == "var" then
    return bind_var(b, a)
  end

  -- Nominal types: identity-based comparison
  if a.tag == "nominal" and b.tag == "nominal" then
    if a.identity == b.identity then return true end
    return false, "nominal type '" .. a.name .. "' is not '" .. b.name .. "'"
  end
  -- Nominal on one side only: not directly assignable
  if a.tag == "nominal" and b.tag ~= "nominal" then
    return false, "nominal type '" .. a.name .. "' is not assignable to '" .. types.display(b) .. "'"
  end
  if b.tag == "nominal" and a.tag ~= "nominal" then
    return false, "'" .. types.display(a) .. "' is not assignable to nominal type '" .. b.name .. "'"
  end

  -- integer <: number and number <: integer (Lua doesn't distinguish at runtime)
  if a.tag == "integer" and b.tag == "number" then return true end
  if a.tag == "number" and b.tag == "integer" then return true end

  -- Literal <: base type
  if a.tag == "literal" then
    if b.tag == "literal" then
      if a.kind == b.kind and a.value == b.value then return true end
      return false, "'" .. types.display(a) .. "' is not '" .. types.display(b) .. "'"
    end
    -- Literal widens to base
    if (a.kind == "string" and b.tag == "string")
      or (a.kind == "number" and (b.tag == "number" or b.tag == "integer"))
      or (a.kind == "boolean" and b.tag == "boolean") then
      return true
    end
  end

  -- Same primitive tags
  if a.tag == b.tag and (a.tag == "nil" or a.tag == "boolean" or a.tag == "number"
    or a.tag == "integer" or a.tag == "string") then
    return true
  end

  -- Union on LHS: each member must be assignable to RHS
  if a.tag == "union" then
    for i = 1, #a.types do
      local ok, err = M.unify(a.types[i], b)
      if not ok then
        return false, types.display(a.types[i]) .. " in union is not assignable to " .. types.display(b)
      end
    end
    return true
  end

  -- Union on RHS: LHS must be assignable to at least one member
  if b.tag == "union" then
    for i = 1, #b.types do
      local ok = M.unify(types.resolve(a), b.types[i])
      if ok then return true end
    end
    return false, "'" .. types.display(a) .. "' is not assignable to '" .. types.display(b) .. "'"
  end

  -- Intersection on RHS: LHS must be assignable to all members
  if b.tag == "intersection" then
    for i = 1, #b.types do
      local ok, err = M.unify(a, b.types[i])
      if not ok then return false, err end
    end
    return true
  end

  -- Intersection on LHS: at least one member must be assignable to RHS
  if a.tag == "intersection" then
    for i = 1, #a.types do
      local ok = M.unify(a.types[i], b)
      if ok then return true end
    end
    return false, "'" .. types.display(a) .. "' is not assignable to '" .. types.display(b) .. "'"
  end

  -- Function types: contravariant params, covariant returns
  if a.tag == "function" and b.tag == "function" then
    -- Check param count (allow fewer params on LHS — Lua convention)
    local max_params = math.max(#a.params, #b.params)
    for i = 1, max_params do
      local ap = a.params[i] or types.NIL()
      local bp = b.params[i] or types.NIL()
      -- Contravariant: b's param must be assignable to a's param
      local ok, err = M.unify(bp, ap)
      if not ok then
        return false, "parameter " .. i .. ": " .. (err or "type mismatch")
      end
    end
    -- Covariant returns
    local max_rets = math.max(#a.returns, #b.returns)
    for i = 1, max_rets do
      local ar = a.returns[i] or types.NIL()
      local br = b.returns[i] or types.NIL()
      local ok, err = M.unify(ar, br)
      if not ok then
        return false, "return " .. i .. ": " .. (err or "type mismatch")
      end
    end
    return true
  end

  -- Table types: structural subtyping
  if a.tag == "table" and b.tag == "table" then
    -- Every required field in b must exist in a
    for name, bf in pairs(b.fields) do
      local af = a.fields[name]
      if not af then
        if not bf.optional then
          -- Check a's indexers for string keys
          local found = false
          for j = 1, #a.indexers do
            if a.indexers[j].key.tag == "string" then
              local ok = M.unify(a.indexers[j].value, bf.type)
              if ok then found = true; break end
            end
          end
          if not found then
            return false, "missing field '" .. name .. "'"
          end
        end
      else
        local ok, err = M.unify(af.type, bf.type)
        if not ok then
          return false, "field '" .. name .. "': " .. (err or "type mismatch")
        end
      end
    end
    -- Unify indexers
    for i = 1, #b.indexers do
      local bi = b.indexers[i]
      local matched = false
      for j = 1, #a.indexers do
        local ai = a.indexers[j]
        local key_ok = M.unify(ai.key, bi.key)
        if key_ok then
          local val_ok, err = M.unify(ai.value, bi.value)
          if not val_ok then
            return false, "indexer value: " .. (err or "type mismatch")
          end
          matched = true
          break
        end
      end
      if not matched then
        -- Empty table absorbs indexers (structural subtyping: {} is a valid empty array/dict)
        if not next(a.fields) and #a.indexers == 0 then
          a.indexers[#a.indexers + 1] = { key = bi.key, value = bi.value }
          matched = true
        elseif bi.key.tag ~= "string" then
          -- Row var could absorb this
          if not a.row then
            return false, "missing indexer for " .. types.display(bi.key)
          end
        end
      end
    end
    return true
  end

  -- Tuple types
  if a.tag == "tuple" and b.tag == "tuple" then
    if #a.elements ~= #b.elements then
      return false, "tuple length mismatch: " .. #a.elements .. " vs " .. #b.elements
    end
    for i = 1, #a.elements do
      local ok, err = M.unify(a.elements[i], b.elements[i])
      if not ok then
        return false, "tuple element " .. i .. ": " .. (err or "type mismatch")
      end
    end
    return true
  end

  -- Tuple is NOT assignable to array (different semantics)
  if a.tag == "tuple" and b.tag == "table" then
    return false, "tuple is not assignable to table/array"
  end
  if a.tag == "table" and b.tag == "tuple" then
    return false, "table/array is not assignable to tuple"
  end

  -- cdata: structural comparison not implemented, use any
  if a.tag == "cdata" or b.tag == "cdata" then
    return true
  end

  return false, "cannot assign '" .. types.display(a) .. "' to '" .. types.display(b) .. "'"
end

-- Read-only unification: checks assignability without mutating type variables.
-- Returns (score, ok) where score is a specificity measure (lower = more specific match).
-- Score 0 = exact match, score N = N type variables or widenings.
function M.try_unify(a, b)
  a = types.resolve(a)
  b = types.resolve(b)

  -- any is bilateral but not specific
  if a.tag == "any" or b.tag == "any" then return 100, true end
  if a.tag == "never" then return 50, true end

  -- Skip var binding (read-only)
  if a.tag == "var" or b.tag == "var" then return 50, true end

  -- Named types: pass through
  if a.tag == "named" or b.tag == "named" then return 50, true end

  -- Same primitive
  if a.tag == b.tag and (a.tag == "nil" or a.tag == "boolean" or a.tag == "number"
    or a.tag == "integer" or a.tag == "string") then
    return 0, true
  end

  -- integer <: number and number <: integer
  if a.tag == "integer" and b.tag == "number" then return 1, true end
  if a.tag == "number" and b.tag == "integer" then return 1, true end

  -- Literal match
  if a.tag == "literal" then
    if b.tag == "literal" and a.kind == b.kind and a.value == b.value then return 0, true end
    if (a.kind == "string" and b.tag == "string")
      or (a.kind == "number" and b.tag == "number")
      or (a.kind == "boolean" and b.tag == "boolean") then
      return 1, true
    end
  end

  -- Union on RHS
  if b.tag == "union" then
    for i = 1, #b.types do
      local score, ok = M.try_unify(a, b.types[i])
      if ok then return score, true end
    end
    return 0, false
  end

  -- Function types
  if a.tag == "function" and b.tag == "function" then
    local total_score = 0
    local max_params = math.max(#a.params, #b.params)
    for i = 1, max_params do
      local ap = a.params[i] or types.NIL()
      local bp = b.params[i] or types.NIL()
      local score, ok = M.try_unify(bp, ap)
      if not ok then return 0, false end
      total_score = total_score + score
    end
    return total_score, true
  end

  -- Table types
  if a.tag == "table" and b.tag == "table" then
    local total_score = 0
    for name, bf in pairs(b.fields) do
      local af = a.fields[name]
      if not af and not bf.optional then return 0, false end
      if af then
        local score, ok = M.try_unify(af.type, bf.type)
        if not ok then return 0, false end
        total_score = total_score + score
      end
    end
    return total_score, true
  end

  -- Nominal
  if a.tag == "nominal" and b.tag == "nominal" then
    if a.identity == b.identity then return 0, true end
    return 0, false
  end

  return 0, false
end

-- Convenience: check assignability without binding vars (read-only check)
-- For now, unify is used directly; a separate is_subtype could be added later.
M.is_assignable = M.unify

return M
