-- lib/unified/unist_util_visit/init.lua
-- Depth-first tree visitor for unist-compatible ASTs (mdast, hast, nlcst, xast).
-- Port of https://github.com/syntax-tree/unist-util-visit
--
-- Usage:
--   local visit = require("lib.unified.unist_util_visit")
--   visit(tree, "text", function(node, index, parent) ... end)
--   visit(tree, {"text","strong"}, enter, exit)
--   visit(tree, enter)                          -- no type filter
--   visit.with_parents(tree, "text", function(node, ancestors) ... end)

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- ── Signals ───────────────────────────────────────────────────────────────────

M.CONTINUE = true    -- default: visit children, continue traversal
M.SKIP     = "skip"  -- don't visit children, but continue siblings
M.EXIT     = false   -- stop the entire traversal
M.REMOVE   = 1       -- remove this node from parent.children

-- ── Type matching ─────────────────────────────────────────────────────────────

-- Returns a predicate function from a type spec:
--   nil   -> match all nodes
--   string -> match nodes whose .type == string
--   table  -> match nodes whose .type is in the array
--: (any) -> (any) -> boolean
local function make_test(types)
  if types == nil then
    return function() return true end
  elseif type(types) == "string" then
    local t = types
    return function(node) return node.type == t end
  else
    -- array of strings
    local set = {}
    for i = 1, #types do set[types[i]] = true end
    return function(node) return set[node.type] == true end
  end
end

-- ── Core walker ───────────────────────────────────────────────────────────────

-- walk(node, index, parent, test, enter, exit) -> signal
-- Returns EXIT (false) to abort, REMOVE (1) if the node was removed,
-- a number if the caller's loop should jump to that index, or CONTINUE (true).
local function walk(node, index, parent, test, enter, exit)
  local enter_signal

  -- Enter phase
  if test(node) then
    if enter then
      enter_signal = enter(node, index, parent)
    end
  end

  if enter_signal == M.EXIT then return M.EXIT end

  -- Handle REMOVE: remove node from parent.children and return REMOVE so
  -- the caller adjusts its loop index.
  if enter_signal == M.REMOVE then
    if parent and parent.children then
      table.remove(parent.children, index)
    end
    return M.REMOVE
  end

  -- Visit children unless SKIP was returned.
  if enter_signal ~= M.SKIP and node.children then
    local i = 1
    while i <= #node.children do
      local child = node.children[i]
      local result = walk(child, i, node, test, enter, exit)
      if result == M.EXIT then return M.EXIT end
      if result == M.REMOVE then
        -- child already removed from node.children by the recursive call;
        -- don't increment: the next child is now at the same index.
      elseif type(result) == "number" then
        i = result
      else
        i = i + 1
      end
    end
  end

  -- Exit phase
  if exit and test(node) then
    local exit_signal = exit(node, index, parent)
    if exit_signal == M.EXIT then return M.EXIT end
    if exit_signal == M.REMOVE then
      if parent and parent.children then
        table.remove(parent.children, index)
      end
      return M.REMOVE
    end
    if type(exit_signal) == "number" then return exit_signal end
  end

  -- If enter returned a number (jump-to-index), propagate it to the caller.
  if type(enter_signal) == "number" then return enter_signal end

  return M.CONTINUE
end

-- ── Public visit function ─────────────────────────────────────────────────────

-- visit(tree, [type_or_types,] enter [, exit])
--   tree          : root node of any unist-compatible AST
--   type_or_types : string | string[] | nil  (nil = visit all nodes)
--   enter         : function(node, index, parent) -> signal | nil
--   exit          : function(node, index, parent) -> signal | nil  (optional)
setmetatable(M, {
  __call = function(_, tree, a, b, c)
    local types, enter, exit

    -- Determine argument layout: type_or_types is optional.
    if type(a) == "function" then
      -- visit(tree, enter [, exit])
      types = nil
      enter = a
      exit  = b
    else
      -- visit(tree, type_or_types, enter [, exit])
      types = a
      enter = b
      exit  = c
    end

    local test = make_test(types)
    walk(tree, nil, nil, test, enter, exit)
  end,
})

-- ── with_parents variant ──────────────────────────────────────────────────────

-- walk_parents(node, ancestors, test, enter, exit) -> signal
local function walk_parents(node, ancestors, test, enter, exit)
  local signal

  if test(node) then
    if enter then
      signal = enter(node, ancestors)
    else
      signal = M.CONTINUE
    end
  else
    signal = M.CONTINUE
  end

  if signal == M.EXIT then return M.EXIT end

  if signal == M.REMOVE then
    local parent = ancestors[#ancestors]
    if parent and parent.children then
      -- find and remove; we don't have the index here, so scan
      local children = parent.children
      for i = 1, #children do
        if children[i] == node then
          table.remove(children, i)
          break
        end
      end
    end
    return M.REMOVE
  end

  if signal ~= M.SKIP and node.children then
    -- Push this node as the next ancestor
    ancestors[#ancestors + 1] = node
    local i = 1
    while i <= #node.children do
      local child = node.children[i]
      local result = walk_parents(child, ancestors, test, enter, exit)
      if result == M.EXIT then
        ancestors[#ancestors] = nil
        return M.EXIT
      end
      if result == M.REMOVE then
        -- don't increment; child already removed
      elseif type(result) == "number" then
        i = result
      else
        i = i + 1
      end
    end
    ancestors[#ancestors] = nil
  end

  if exit and test(node) then
    signal = exit(node, ancestors)
    if signal == M.EXIT then return M.EXIT end
  end

  return M.CONTINUE
end

-- visit.with_parents(tree, [type_or_types,] enter [, exit])
--   enter(node, ancestors) where ancestors[#ancestors] is the direct parent.
function M.with_parents(tree, a, b, c)
  local types, enter, exit

  if type(a) == "function" then
    types = nil
    enter = a
    exit  = b
  else
    types = a
    enter = b
    exit  = c
  end

  local test = make_test(types)
  walk_parents(tree, {}, test, enter, exit)
end

return M
