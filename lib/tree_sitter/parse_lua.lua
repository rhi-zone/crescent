#!/usr/bin/env luajit
local arg = arg --[[@type unknown[] ]]
if pcall(debug.getlocal, 4, 1) then
  arg = { ... }
else
  package.path = arg[0]:gsub("lua/.+$", "lua/?.lua", 1) .. ";" .. package.path
end

local ffi = require('ffi')
local ts = require('dep.tree_sitter.ffi')

---@param code string The Lua code to parse
---@param parser ptr_c<TSParser> The parser to use
---@return ptr_c<TSTree> tree The parsed tree
local function parse_lua_file(code, parser)
  local tree = ffi.gc(assert(ts.ts_parser_parse_string(parser, nil, code, #code), "failed to parse file"), function(tree)
    -- WARNING: This means the tree needs to be kept alive until its nodes are no longer in use
    ts.ts_tree_delete(tree)
  end)
  assert(tree ~= nil, "failed to parse file")
  return tree
end

local function read_file(file_path)
  local f = assert(io.open(file_path, "rb"))
  local content = f:read("*a")
  f:close()
  return content
end

local lua_path = assert(arg[1], "usage: lua parse_lua.lua <path_to_lua_file>")
local lua_code = read_file(lua_path)
local lua_language = require("dep.tree_sitter.load").load_grammar("lua")
local parser = ffi.gc(assert(ts.ts_parser_new()), function(p)
  ts.ts_parser_delete(p)
end)
ts.ts_parser_set_language(parser, lua_language)
local tree = parse_lua_file(lua_code, parser)
require("dep.tree_sitter.util").print_tree(ts.ts_tree_root_node(tree), lua_code)
