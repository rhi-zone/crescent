-- lib/type/static/init.lua
-- Public API for the static typechecker.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- ljltk internally requires "dep.ljltk.*" — map "dep." to "lib."
if not package.preload["dep.ljltk.id_generator"] then
  local dep_loader = function(mod)
    local path = mod:gsub("^dep%.", "lib."):gsub("%.", "/") .. ".lua"
    local f = io.open(path, "r")
    if not f then return nil, "cannot find " .. path end
    local src = f:read("*a")
    f:close()
    local chunk, err = loadstring(src, "@./" .. path)
    if not chunk then return nil, err end
    return chunk
  end
  table.insert(package.loaders or package.searchers, 2, function(mod)
    if mod:match("^dep%.") then return dep_loader(mod) end
    return nil
  end)
end

local reader = require("lib.ljltk.reader")
local lua_ast = require("lib.ljltk.lua_ast")
local parse = require("lib.ljltk.parser")
local lexer = require("lib.ljltk.lexer")
local types = require("lib.type.static.types")
local env = require("lib.type.static.env")
local builtins = require("lib.type.static.builtins")
local infer = require("lib.type.static.infer")
local errors = require("lib.type.static.errors")

local M = {}

-- Check a Lua source string. Returns error context.
function M.check_string(source, filename)
  filename = filename or "<string>"
  local err_ctx = errors.new()

  -- Parse
  local ast = lua_ast.New()
  local ls = lexer(reader.string(source), filename)
  local ok, chunk = pcall(parse, ast, ls)
  if not ok then
    errors.error(err_ctx, filename, 0, "parse error: " .. tostring(chunk))
    return err_ctx
  end

  -- Create scope with builtins
  local scope = builtins.create_env()

  -- Infer
  local ctx = infer.infer_chunk(chunk, err_ctx, source, filename, scope)

  return err_ctx
end

-- Check a Lua file. Returns error context.
function M.check_file(filename)
  local f = io.open(filename, "r")
  if not f then
    local err_ctx = errors.new()
    errors.error(err_ctx, filename, 0, "cannot open file")
    return err_ctx
  end
  local source = f:read("*a")
  f:close()
  return M.check_string(source, filename)
end

-- Convenience: check and return formatted errors string
function M.check(source, filename)
  local err_ctx = M.check_string(source, filename)
  if errors.has_errors(err_ctx) then
    -- Build source lines map
    local source_lines = {}
    local line_num = 0
    for line in (source .. "\n"):gmatch("([^\n]*)\n") do
      line_num = line_num + 1
      source_lines[line_num] = line
    end
    return false, errors.format(err_ctx, source_lines)
  end
  return true, nil
end

return M
