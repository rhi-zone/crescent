-- lib/type/static/env.lua
-- Scoped symbol table for the static typechecker.
-- Linked-list of scopes: { bindings = { name -> type }, parent, level }

local types = require("lib.type.static.types")

local M = {}

function M.new(level)
  return { bindings = {}, parent = nil, level = level or 0, type_bindings = {} }
end

function M.child(parent)
  return { bindings = {}, parent = parent, level = parent.level + 1, type_bindings = {} }
end

function M.bind(scope, name, ty)
  scope.bindings[name] = ty
end

function M.bind_type(scope, name, ty)
  scope.type_bindings[name] = ty
end

function M.lookup(scope, name)
  local s = scope
  while s do
    if s.bindings[name] then
      return s.bindings[name]
    end
    s = s.parent
  end
  return nil
end

function M.lookup_type(scope, name)
  local s = scope
  while s do
    if s.type_bindings[name] then
      return s.type_bindings[name]
    end
    s = s.parent
  end
  return nil
end

-- Substitute named type parameters with provided type arguments.
-- mapping: { param_name -> type }
-- Returns a new type with all matching named references replaced.
function M.substitute(ty, mapping)
  if not ty then return ty end
  local tag = ty.tag

  if tag == "named" then
    -- If the name matches a type parameter, substitute it
    if mapping[ty.name] and #ty.args == 0 then
      return mapping[ty.name]
    end
    -- Otherwise substitute within args
    if ty.args and #ty.args > 0 then
      local new_args = {}
      for i = 1, #ty.args do
        new_args[i] = M.substitute(ty.args[i], mapping)
      end
      return { tag = "named", name = ty.name, args = new_args }
    end
    return ty
  end

  if tag == "function" then
    local params = {}
    for i = 1, #ty.params do
      params[i] = M.substitute(ty.params[i], mapping)
    end
    local returns = {}
    for i = 1, #ty.returns do
      returns[i] = M.substitute(ty.returns[i], mapping)
    end
    local vararg = ty.vararg and M.substitute(ty.vararg, mapping)
    return types.func(params, returns, vararg)
  end

  if tag == "table" then
    local fields = {}
    for name, f in pairs(ty.fields) do
      fields[name] = { type = M.substitute(f.type, mapping), optional = f.optional }
    end
    local indexers = {}
    for i = 1, #ty.indexers do
      indexers[i] = {
        key = M.substitute(ty.indexers[i].key, mapping),
        value = M.substitute(ty.indexers[i].value, mapping),
      }
    end
    return types.table(fields, indexers, ty.row)
  end

  if tag == "union" then
    local ts = {}
    for i = 1, #ty.types do
      ts[i] = M.substitute(ty.types[i], mapping)
    end
    return types.union(ts)
  end

  if tag == "intersection" then
    local ts = {}
    for i = 1, #ty.types do
      ts[i] = M.substitute(ty.types[i], mapping)
    end
    return types.intersection(ts)
  end

  if tag == "tuple" then
    local elems = {}
    for i = 1, #ty.elements do
      elems[i] = M.substitute(ty.elements[i], mapping)
    end
    return types.tuple(elems)
  end

  if tag == "spread" then
    return types.spread(M.substitute(ty.inner, mapping))
  end

  return ty
end

-- Resolve a named type reference by looking up its alias and substituting params.
-- alias_entry: { body = type, params = { { name = "T", constraint? }, ... } | nil }
-- args: list of type arguments provided at the usage site
-- Returns the resolved type, or nil + error message.
function M.resolve_named_type(scope, name, args)
  local alias = M.lookup_type(scope, name)
  if not alias then
    return nil, "undefined type '" .. name .. "'"
  end

  -- Simple alias (no params)
  if not alias.params or #alias.params == 0 then
    if args and #args > 0 then
      return nil, "type '" .. name .. "' does not take type arguments"
    end
    return alias.body
  end

  -- Generic alias — check arity
  if not args or #args ~= #alias.params then
    local expected = #alias.params
    local got = args and #args or 0
    return nil, "type '" .. name .. "' expects " .. expected .. " type argument(s), got " .. got
  end

  -- Build substitution mapping
  local mapping = {}
  for i = 1, #alias.params do
    mapping[alias.params[i].name] = args[i]
  end

  return M.substitute(alias.body, mapping)
end

-- Generalize: promote free type variables above `level` to generic vars
function M.generalize(ty, level)
  ty = types.resolve(ty)
  local tag = ty.tag

  if tag == "var" then
    if ty.level > level then
      ty.generic = true
    end
    return ty
  end

  if tag == "function" then
    for i = 1, #ty.params do
      M.generalize(ty.params[i], level)
    end
    for i = 1, #ty.returns do
      M.generalize(ty.returns[i], level)
    end
    if ty.vararg then M.generalize(ty.vararg, level) end
    return ty
  end

  if tag == "table" then
    for _, f in pairs(ty.fields) do
      M.generalize(f.type, level)
    end
    for i = 1, #ty.indexers do
      M.generalize(ty.indexers[i].key, level)
      M.generalize(ty.indexers[i].value, level)
    end
    return ty
  end

  if tag == "union" or tag == "intersection" then
    for i = 1, #ty.types do
      M.generalize(ty.types[i], level)
    end
    return ty
  end

  return ty
end

-- Instantiate: replace generic vars with fresh vars at current level
function M.instantiate(ty, level, mapping)
  ty = types.resolve(ty)
  mapping = mapping or {}
  local tag = ty.tag

  if tag == "var" then
    if ty.generic then
      if not mapping[ty.id] then
        mapping[ty.id] = types.typevar(level)
      end
      return mapping[ty.id]
    end
    return ty
  end

  if tag == "function" then
    local params = {}
    for i = 1, #ty.params do
      params[i] = M.instantiate(ty.params[i], level, mapping)
    end
    local returns = {}
    for i = 1, #ty.returns do
      returns[i] = M.instantiate(ty.returns[i], level, mapping)
    end
    local vararg = ty.vararg and M.instantiate(ty.vararg, level, mapping)
    return types.func(params, returns, vararg)
  end

  if tag == "table" then
    local fields = {}
    for name, f in pairs(ty.fields) do
      fields[name] = { type = M.instantiate(f.type, level, mapping), optional = f.optional }
    end
    local indexers = {}
    for i = 1, #ty.indexers do
      indexers[i] = {
        key = M.instantiate(ty.indexers[i].key, level, mapping),
        value = M.instantiate(ty.indexers[i].value, level, mapping),
      }
    end
    return types.table(fields, indexers, ty.row)
  end

  if tag == "union" then
    local ts = {}
    for i = 1, #ty.types do
      ts[i] = M.instantiate(ty.types[i], level, mapping)
    end
    return types.union(ts)
  end

  if tag == "intersection" then
    local ts = {}
    for i = 1, #ty.types do
      ts[i] = M.instantiate(ty.types[i], level, mapping)
    end
    return types.intersection(ts)
  end

  return ty
end

return M
