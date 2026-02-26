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
