-- lib/unified/unist_util_find/init.lua
-- Returns the first node in a unist-compatible AST that matches a test.
-- Port of https://github.com/syntax-tree/unist-util-find
--
-- Usage:
--   local find = require("lib.unified.unist_util_find")
--   local node = find(tree, "text")
--   local node = find(tree, function(node) return node.value == "hello" end)

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local visit = require("lib.unified.unist_util_visit") --[[: any]]

local M = {}

-- Returns a predicate from a string type name or function.
--:: UnistNode = { type: string, ... }
--: (string | (UnistNode) -> boolean) -> (UnistNode) -> boolean
local function make_test(spec)
  if type(spec) == "string" then
    local t = spec
    return function(node) return node.type == t end
  else
    return spec --[[:! (UnistNode) -> boolean]]
  end
end

-- find(tree, test) -> node | nil
-- Depth-first pre-order search. Returns the first matching node, or nil.
setmetatable(M, {
  __call = function(_, tree, spec)
    local test = make_test(spec)
    local found = nil
    visit(tree, function(node)
      if test(node) then
        found = node
        return visit.EXIT
      end
    end)
    return found
  end,
})

return M
