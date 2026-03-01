-- lib/type/static/builtins.lua
-- Loads stdlib type declarations from stdlib.d.lua into a type scope.

local types = require("lib.type.static.types")
local env = require("lib.type.static.env")

local M = {}

-- Walk a parsed type tree and resolve { tag = "named" } nodes against scope.
local function resolve_named(scope, ty)
  if not ty then return ty end
  ty = types.resolve(ty)
  if ty.tag == "named" then
    local resolved = env.resolve_named_type(scope, ty.name,
      ty.args and #ty.args > 0 and ty.args or nil)
    return resolved or ty
  end
  if ty.tag == "function" then
    local params, rets = {}, {}
    for i = 1, #ty.params do params[i] = resolve_named(scope, ty.params[i]) end
    for i = 1, #ty.returns do rets[i] = resolve_named(scope, ty.returns[i]) end
    return types.func(params, rets, ty.vararg and resolve_named(scope, ty.vararg))
  end
  if ty.tag == "table" then
    local fields, indexers = {}, {}
    for k, f in pairs(ty.fields) do
      fields[k] = { type = resolve_named(scope, f.type), optional = f.optional }
    end
    for i, idx in ipairs(ty.indexers) do
      indexers[i] = {
        key = resolve_named(scope, idx.key),
        value = resolve_named(scope, idx.value),
      }
    end
    return types.table(fields, indexers, ty.row, ty.meta)
  end
  if ty.tag == "union" then
    local parts = {}
    for i, t in ipairs(ty.types) do parts[i] = resolve_named(scope, t) end
    return types.union(parts)
  end
  if ty.tag == "intersection" then
    local parts = {}
    for i, t in ipairs(ty.types) do parts[i] = resolve_named(scope, t) end
    return types.intersection(parts)
  end
  return ty
end

-- Load declarations from a source string into scope.
-- Handles type_decl (--::), value_decl (--: declare), and extend_decl (--: extend).
function M.load_declarations(scope, source)
  local annotations = require("lib.type.static.annotations")
  local map = annotations.build_map(source)

  -- First pass: bind type aliases so value_decl can reference them.
  for _, ann in pairs(map) do
    if ann.kind == "type_decl" then
      env.bind_type(scope, ann.name, { body = ann.type, params = ann.params })
    end
  end

  -- Second pass: bind value declarations.
  for _, ann in pairs(map) do
    if ann.kind == "value_decl" then
      env.bind(scope, ann.name, resolve_named(scope, ann.type))
    elseif ann.kind == "extend_decl" then
      local existing = env.lookup(scope, ann.name)
      if existing then
        existing = types.resolve(existing)
        local ext = resolve_named(scope, ann.type)
        ext = types.resolve(ext)
        if existing.tag == "table" and ext.tag == "table" then
          for fname, fval in pairs(ext.fields) do
            existing.fields[fname] = fval
          end
          if ext.meta then
            existing.meta = existing.meta or {}
            for mname, mval in pairs(ext.meta) do
              existing.meta[mname] = mval
            end
          end
        end
      end
    end
  end
end

-- Load declarations from a file.
function M.load_file(scope, path)
  local f = io.open(path, "r")
  if not f then return nil, "cannot open " .. path end
  local src = f:read("*a")
  f:close()
  M.load_declarations(scope, src)
  return true
end

function M.create_env()
  local scope = env.new(0)

  -- Load stdlib.d.lua from the same directory as this file.
  local src_path = debug.getinfo(1, "S").source
  src_path = src_path:gsub("^@", "")
  local dir = src_path:match("^(.+/)[^/]+$") or "./"
  M.load_file(scope, dir .. "stdlib.d.lua")

  -- Special values that can't be expressed in annotation syntax (open tables).
  env.bind(scope, "_G", types.table({}, {}, types.rowvar(0)))

  return scope
end

return M
