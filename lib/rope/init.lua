-- lib/rope: rope data structure for efficient large-string editing
-- Binary tree of string chunks; O(log n) insert/delete.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- Depth threshold for auto-rebalance in concat
local REBALANCE_DEPTH = 30

--:: Node = { type: string, str: string, len: integer, depth: integer, left: any, right: any }
--:: Rope = { _node: Node, ... }

-- node constructors
--: (s: string) -> Node
local function leaf(s)
  return { type = "leaf", str = s, len = #s, depth = 1, left = nil, right = nil } --[[: Node ]]
end

--: (l: Node, r: Node) -> Node
local function concat_node(l, r)
  local d = l.depth
  if r.depth > d then d = r.depth end
  return { type = "concat", left = l, right = r, len = l.len + r.len, depth = d + 1, str = "" } --[[: Node ]]
end

-- collect all leaf strings in order into array t
--: (node: Node, t: string[]) -> nil
local function collect_leaves(node, t)
  if node.type == "leaf" then
    if node.len > 0 then
      t[#t + 1] = node.str
    end
  else
    collect_leaves(node.left, t)
    collect_leaves(node.right, t)
  end
end

-- build a balanced tree from an array of leaf nodes
--: (leaves: Node[], lo: integer, hi: integer) -> Node
local function build_balanced(leaves, lo, hi)
  if lo > hi then
    return leaf("")
  end
  if lo == hi then
    return leaves[lo]
  end
  local mid = lo + math.floor((hi - lo) / 2)
  local l = build_balanced(leaves, lo, mid)
  local r = build_balanced(leaves, mid + 1, hi)
  return concat_node(l, r)
end

-- rebalance a node: collect leaves, rebuild balanced
--: (node: Node) -> Node
local function rebalance_node(node)
  local strs = {} --[[: string[] ]]
  collect_leaves(node, strs)
  if #strs == 0 then
    return leaf("")
  end
  local leaves = {}
  for i = 1, #strs do
    leaves[i] = leaf(strs[i])
  end
  return build_balanced(leaves, 1, #leaves)
end

-- smart concat: auto-rebalance if depth imbalance exceeds threshold
--: (l: Node, r: Node) -> Node
local function smart_concat(l, r)
  if l.len == 0 then return r
  elseif r.len == 0 then return l
  else
    local node = concat_node(l, r)
    local diff = l.depth - r.depth
    if diff < 0 then diff = -diff end
    if node.depth > REBALANCE_DEPTH or diff > 2 then
      return rebalance_node(node)
    end
    return node
  end
end

-- walk tree to find char at 1-based position i; returns byte value
--: (node: Node, i: integer) -> string
local function node_char_at(node, i)
  if node.type == "leaf" then
    return node.str:sub(i, i)
  else
    if i <= node.left.len then
      return node_char_at(node.left, i)
    else
      return node_char_at(node.right, i - node.left.len)
    end
  end
end

-- split node after position pos (1-based)
-- returns left (chars 1..pos), right (chars pos+1..end)
--: (node: Node, pos: integer) -> (Node, Node)
local function split_node(node, pos)
  if pos <= 0 then
    return leaf(""), node
  end
  if pos >= node.len then
    return node, leaf("")
  end
  if node.type == "leaf" then
    return leaf(node.str:sub(1, pos)), leaf(node.str:sub(pos + 1))
  else
    -- concat node
    if pos <= node.left.len then
      local ll, lr = split_node(node.left, pos)
      return ll, smart_concat(lr, node.right)
    elseif pos == node.left.len then
      return node.left, node.right
    else
      local rl, rr = split_node(node.right, pos - node.left.len)
      return smart_concat(node.left, rl), rr
    end
  end
end

-- to_string: concatenate all leaves
--: (node: Node) -> string
local function node_to_string(node)
  if node.type == "leaf" then
    return node.str
  else
    local parts = {}
    collect_leaves(node, parts)
    return table.concat(parts)
  end
end

-- Rope object metatable
local Rope = {}
Rope.__index = Rope

local function wrap(node)
  return setmetatable({ _node = node }, Rope)
end

--: (s: string | nil) -> Rope
function M.new(s)
  if s == nil then s = "" end
  return wrap(leaf(s))
end

-- M.concat(a, b): concat two ropes (or strings) as a module-level function
--: (a: Rope | string, b: Rope | string) -> Rope
function M.concat(a, b)
  if type(a) == "string" then a = M.new(a) end
  if type(b) == "string" then b = M.new(b) end
  return wrap(smart_concat(a._node, b._node))
end

function Rope:length()
  return self._node.len
end

-- spec alias
Rope.len = Rope.length

function Rope:to_string()
  return node_to_string(self._node)
end

-- spec alias
Rope.str = Rope.to_string

Rope.__tostring = function(self)
  return node_to_string(self._node)
end

-- Note: __len is a Lua 5.2+ feature; LuaJIT does not invoke it on plain
-- tables, so `#rope` returns the raw table length (0). Use :len() instead.

function Rope:char_at(i)
  if i < 1 or i > self._node.len then
    return nil, "index out of range"
  end
  return node_char_at(self._node, i)
end

--: (self: Rope, i: integer, j: integer) -> Rope
function Rope:sub(i, j)
  local len = self._node.len
  -- normalize like string.sub
  if i < 0 then i = len + i + 1 end
  if j < 0 then j = len + j + 1 end
  if i < 1 then i = 1 end
  if j > len then j = len end
  if i > j then return wrap(leaf("")) end
  -- split at j to get left (1..j), then split at i-1 to get right (i..j)
  local left_j, _ = split_node(self._node, j)
  local _, right_i = split_node(left_j, i - 1)
  return wrap(right_i)
end

function Rope:concat(other)
  return wrap(smart_concat(self._node, other._node))
end

Rope.__concat = function(a, b)
  -- allow rope .. rope
  return wrap(smart_concat(a._node, b._node))
end

Rope.__eq = function(a, b)
  -- structural equality via string comparison
  return node_to_string(a._node) == node_to_string(b._node)
end

function Rope:split(pos)
  local l, r = split_node(self._node, pos)
  return wrap(l), wrap(r)
end

function Rope:insert(pos, s)
  -- insert string s before position pos+1 (i.e., after char pos)
  -- per spec: insert(6, ", dear") on "hello world" → "hello, dear world"
  -- means: split after pos-1 so new text goes at position pos
  local left, right = split_node(self._node, pos - 1)
  local new_leaf = leaf(s)
  return wrap(smart_concat(smart_concat(left, new_leaf), right))
end

function Rope:delete(start_pos, end_pos)
  -- delete chars from start_pos to end_pos (inclusive, 1-based)
  local left, rest = split_node(self._node, start_pos - 1)
  local _, right = split_node(rest, end_pos - start_pos + 1)
  return wrap(smart_concat(left, right))
end

function Rope:rebalance()
  return wrap(rebalance_node(self._node))
end

function Rope:iter()
  -- DFS left-to-right, yield each leaf's string (non-empty)
  local stack = {}
  local top = 0
  -- push root
  top = top + 1
  stack[top] = self._node
  return function()
    while top > 0 do
      local n = stack[top]
      top = top - 1
      if n.type == "leaf" then
        if n.len > 0 then
          return n.str
        end
        -- empty leaf: skip, continue loop
      else
        -- push right first so left is processed first
        top = top + 1
        stack[top] = n.right
        top = top + 1
        stack[top] = n.left
      end
    end
  end
end

return M
