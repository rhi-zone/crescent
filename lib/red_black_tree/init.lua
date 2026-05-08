-- Red-black tree: self-balancing BST with O(log n) insert/delete/search
-- Pure LuaJIT implementation. Reference: CLRS Chapter 13.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

--:: RBNode = { key: unknown, value: unknown, color: integer, left: RBNode, right: RBNode, parent: RBNode }
--:: RBTree = { _root: RBNode, _nil: RBNode, _size: number, _cmp: (unknown, unknown) -> boolean, ... }

-- Color constants
local RED   = 0
local BLACK = 1

-- Sentinel nil-node (black) - all nil pointers point here
-- We use a single shared sentinel per tree instance to simplify code
local function make_sentinel()
  return { key = nil, value = nil, color = BLACK, left = nil, right = nil, parent = nil }
end

-- Default comparator
local function default_cmp(a, b)
  return a < b
end

-- Create a new red-black tree
-- opts.cmp: optional comparator function(a, b) -> bool (a < b)
--:: RBTreeOpts = { cmp: ((unknown, unknown) -> boolean) | nil }
function M.new(opts)
  local o = opts or {} --[[:! RBTreeOpts]]
  local NIL = make_sentinel() --[[:! RBNode]]
  NIL.left = NIL
  NIL.right = NIL
  NIL.parent = NIL

  local cmp = (o.cmp or default_cmp) --[[:! (unknown, unknown) -> boolean]]
  local tree = {
    _root = NIL,
    _nil  = NIL,
    _size = 0,
    _cmp  = cmp,
  } --[[:! RBTree]]

  setmetatable(tree, { __index = M })
  return tree
end

-- Left rotate around node x
--: (RBTree, RBNode) -> nil
local function left_rotate(tree, x)
  local NIL = tree._nil
  local y = x.right
  x.right = y.left
  if y.left ~= NIL then
    y.left.parent = x
  end
  y.parent = x.parent
  if x.parent == NIL then
    tree._root = y
  elseif x == x.parent.left then
    x.parent.left = y
  else
    x.parent.right = y
  end
  y.left = x
  x.parent = y
end

-- Right rotate around node y
--: (RBTree, RBNode) -> nil
local function right_rotate(tree, y)
  local NIL = tree._nil
  local x = y.left
  y.left = x.right
  if x.right ~= NIL then
    x.right.parent = y
  end
  x.parent = y.parent
  if y.parent == NIL then
    tree._root = x
  elseif y == y.parent.left then
    y.parent.left = x
  else
    y.parent.right = x
  end
  x.right = y
  y.parent = x
end

-- Fix red-black properties after insert
--: (RBTree, RBNode) -> nil
local function insert_fixup(tree, z)
  local NIL = tree._nil
  while z.parent.color == RED do
    if z.parent == z.parent.parent.left then
      local y = z.parent.parent.right -- uncle
      if y.color == RED then
        -- Case 1: uncle is red
        z.parent.color = BLACK
        y.color = BLACK
        z.parent.parent.color = RED
        z = z.parent.parent
      else
        if z == z.parent.right then
          -- Case 2: uncle is black, z is right child
          z = z.parent
          left_rotate(tree, z)
        end
        -- Case 3: uncle is black, z is left child
        z.parent.color = BLACK
        z.parent.parent.color = RED
        right_rotate(tree, z.parent.parent)
      end
    else
      -- Mirror cases (right subtree)
      local y = z.parent.parent.left -- uncle
      if y.color == RED then
        -- Case 1 mirror
        z.parent.color = BLACK
        y.color = BLACK
        z.parent.parent.color = RED
        z = z.parent.parent
      else
        if z == z.parent.left then
          -- Case 2 mirror
          z = z.parent
          right_rotate(tree, z)
        end
        -- Case 3 mirror
        z.parent.color = BLACK
        z.parent.parent.color = RED
        left_rotate(tree, z.parent.parent)
      end
    end
  end
  tree._root.color = BLACK
end

-- Insert key-value pair (updates value if key exists)
--: (RBTree, unknown, unknown) -> nil
function M:insert(key, value)
  if value == nil then value = true end
  local NIL = self._nil
  local cmp = self._cmp

  local y = NIL
  local x = self._root

  while x ~= NIL do
    y = x
    if cmp(key, x.key) then
      x = x.left
    elseif cmp(x.key, key) then
      x = x.right
    else
      -- Key already exists: update value
      x.value = value
      return
    end
  end

  local z = { key = key, value = value, color = RED, left = NIL, right = NIL, parent = y }
  self._size = self._size + 1

  if y == NIL then
    self._root = z
  elseif cmp(key, y.key) then
    y.left = z
  else
    y.right = z
  end

  insert_fixup(self, z)
end

-- Find node by key, return node or NIL
--: (RBTree, unknown) -> RBNode
local function find_node(tree, key)
  local NIL = tree._nil
  local cmp = tree._cmp
  local x = tree._root
  while x ~= NIL do
    if cmp(key, x.key) then
      x = x.left
    elseif cmp(x.key, key) then
      x = x.right
    else
      return x
    end
  end
  return NIL
end

-- Get value by key
--: (RBTree, unknown) -> unknown | nil
function M:get(key)
  local node = find_node(self, key)
  if node == self._nil then return nil end
  return node.value
end

-- Check if key exists
--: (RBTree, unknown) -> boolean
function M:has(key)
  return find_node(self, key) ~= self._nil
end

-- Return current size
--: (RBTree) -> number
function M:size()
  return self._size
end

-- Find minimum node in subtree rooted at x
--: (RBTree, RBNode) -> RBNode
local function tree_min(tree, x)
  local NIL = tree._nil
  while x.left ~= NIL do
    x = x.left
  end
  return x
end

-- Find maximum node in subtree rooted at x
--: (RBTree, RBNode) -> RBNode
local function tree_max(tree, x)
  local NIL = tree._nil
  while x.right ~= NIL do
    x = x.right
  end
  return x
end

-- Return minimum key, value (nil, nil if empty)
--: (RBTree) -> (unknown | nil, unknown | nil)
function M:min()
  if self._root == self._nil then return nil, nil end
  local node = tree_min(self, self._root)
  return node.key, node.value
end

-- Return maximum key, value (nil, nil if empty)
--: (RBTree) -> (unknown | nil, unknown | nil)
function M:max()
  if self._root == self._nil then return nil, nil end
  local node = tree_max(self, self._root)
  return node.key, node.value
end

-- Transplant: replace subtree rooted at u with subtree rooted at v
--: (RBTree, RBNode, RBNode) -> nil
local function transplant(tree, u, v)
  local NIL = tree._nil
  if u.parent == NIL then
    tree._root = v
  elseif u == u.parent.left then
    u.parent.left = v
  else
    u.parent.right = v
  end
  v.parent = u.parent
end

-- Fix red-black properties after delete
--: (RBTree, RBNode) -> nil
local function delete_fixup(tree, x)
  local NIL = tree._nil
  while x ~= tree._root and x.color == BLACK do
    if x == x.parent.left then
      local w = x.parent.right -- sibling
      if w.color == RED then
        -- Case 1: sibling is red
        w.color = BLACK
        x.parent.color = RED
        left_rotate(tree, x.parent)
        w = x.parent.right --[[:! RBNode]]
      end
      local ww = w --[[:! RBNode]]
      if ww.left.color == BLACK and ww.right.color == BLACK then
        -- Case 2: sibling's children are both black
        ww.color = RED
        x = x.parent --[[:! RBNode]]
      else
        if ww.right.color == BLACK then
          -- Case 3: sibling's right child is black
          w.left.color = BLACK
          w.color = RED
          right_rotate(tree, w)
          w = x.parent.right --[[:! RBNode]]
        end
        -- Case 4: sibling's right child is red
        w.color = x.parent.color
        x.parent.color = BLACK
        w.right.color = BLACK
        left_rotate(tree, x.parent)
        x = tree._root
      end
    else
      -- Mirror cases
      local w = x.parent.left -- sibling
      if w.color == RED then
        -- Case 1 mirror
        w.color = BLACK
        x.parent.color = RED
        right_rotate(tree, x.parent)
        w = x.parent.left --[[:! RBNode]]
      end
      local ww2 = w --[[:! RBNode]]
      if ww2.right.color == BLACK and ww2.left.color == BLACK then
        -- Case 2 mirror
        ww2.color = RED
        x = x.parent --[[:! RBNode]]
      else
        if ww2.left.color == BLACK then
          -- Case 3 mirror
          w.right.color = BLACK
          w.color = RED
          left_rotate(tree, w)
          w = x.parent.left --[[:! RBNode]]
        end
        -- Case 4 mirror
        w.color = x.parent.color
        x.parent.color = BLACK
        w.left.color = BLACK
        right_rotate(tree, x.parent)
        x = tree._root
      end
    end
  end
  x.color = BLACK
end

-- Delete key from tree, return true if found, false if not found
--: (RBTree, unknown) -> boolean
function M:delete(key)
  local NIL = self._nil
  local z = find_node(self, key)
  if z == NIL then return false end

  self._size = self._size - 1

  local y = z
  local y_orig_color = y.color
  local x = NIL --[[:! RBNode]]

  if z.left == NIL then
    x = z.right
    transplant(self, z, z.right)
  elseif z.right == NIL then
    x = z.left
    transplant(self, z, z.left)
  else
    -- Node has two children: find successor (minimum of right subtree)
    y = tree_min(self, z.right) --[[:! RBNode]]
    y_orig_color = y.color
    x = y.right --[[:! RBNode]]
    if y.parent == z then
      x.parent = y
    else
      transplant(self, y, y.right --[[:! RBNode]])
      y.right = z.right
      y.right.parent = y
    end
    transplant(self, z, y)
    y.left = z.left --[[:! RBNode]]
    y.left.parent = y
    y.color = z.color
  end

  if y_orig_color == BLACK then
    delete_fixup(self, x)
  end

  return true
end

-- In-order traversal helper
--: (RBTree, RBNode, (unknown, unknown) -> nil) -> nil
local function inorder(tree, node, fn)
  local NIL = tree._nil
  if node == NIL then return end
  inorder(tree, node.left, fn)
  fn(node.key, node.value)
  inorder(tree, node.right, fn)
end

-- In-order traversal with range check
--: (RBTree, RBNode, unknown, unknown, (unknown, unknown) -> nil) -> nil
local function inorder_range(tree, node, lo, hi, fn)
  local NIL = tree._nil
  local cmp = tree._cmp
  if node == NIL then return end
  -- Only go left if lo <= node.key (there might be keys >= lo in left subtree)
  if not cmp(node.key, lo) then -- node.key >= lo
    inorder_range(tree, node.left, lo, hi, fn)
  end
  -- Visit node if lo <= node.key <= hi
  if not cmp(node.key, lo) and not cmp(hi, node.key) then
    fn(node.key, node.value)
  end
  -- Only go right if node.key <= hi (there might be keys <= hi in right subtree)
  if not cmp(hi, node.key) then -- node.key <= hi
    inorder_range(tree, node.right, lo, hi, fn)
  end
end

-- Iterator: ordered traversal of all key-value pairs
--: (RBTree) -> (() -> unknown | nil)
function M:pairs()
  -- Collect into array first (simpler than stateful iterator)
  local arr = {}
  inorder(self, self._root, function(k, v)
    arr[#arr + 1] = { k, v }
  end)
  local i = 0
  return function()
    i = i + 1
    if arr[i] then
      return arr[i][1], arr[i][2]
    end
  end
end

-- Range iterator: ordered traversal of keys in [lo, hi] inclusive
--: (RBTree, unknown, unknown) -> (() -> unknown | nil)
function M:range(lo, hi)
  local arr = {}
  inorder_range(self, self._root, lo, hi, function(k, v)
    arr[#arr + 1] = { k, v }
  end)
  local i = 0
  return function()
    i = i + 1
    if arr[i] then
      return arr[i][1], arr[i][2]
    end
  end
end

-- Floor: largest key <= k
--: (RBTree, unknown) -> (unknown | nil, unknown | nil)
function M:floor(k)
  local NIL = self._nil
  local cmp = self._cmp
  local x = self._root
  local best = NIL
  while x ~= NIL do
    if cmp(k, x.key) then
      -- k < x.key: go left
      x = x.left
    elseif cmp(x.key, k) then
      -- x.key < k: x is a candidate, go right for something closer
      best = x
      x = x.right
    else
      -- x.key == k: exact match
      return x.key, x.value
    end
  end
  if best == NIL then return nil, nil end
  return best.key, best.value
end

-- Ceiling: smallest key >= k
--: (RBTree, unknown) -> (unknown | nil, unknown | nil)
function M:ceiling(k)
  local NIL = self._nil
  local cmp = self._cmp
  local x = self._root
  local best = NIL
  while x ~= NIL do
    if cmp(x.key, k) then
      -- x.key < k: go right
      x = x.right
    elseif cmp(k, x.key) then
      -- k < x.key: x is a candidate, go left for something closer
      best = x
      x = x.left
    else
      -- x.key == k: exact match
      return x.key, x.value
    end
  end
  if best == NIL then return nil, nil end
  return best.key, best.value
end

-- Convert to sorted array of {key, value} pairs
--: (RBTree) -> { [integer]: { [integer]: unknown } }
function M:to_array()
  local arr = {}
  inorder(self, self._root, function(k, v)
    arr[#arr + 1] = { k, v }
  end)
  return arr
end

-- Verify all red-black invariants
-- Returns (true) on success or (nil, errmsg) on violation
--: (RBTree) -> (boolean | nil, string | nil)
function M:verify()
  local NIL = self._nil

  -- Invariant 2: root is black
  if self._root ~= NIL and self._root.color ~= BLACK then
    return nil, "invariant 2 violated: root is not black"
  end

  -- Check sentinel is black
  if NIL.color ~= BLACK then
    return nil, "sentinel node is not black"
  end

  -- Recursive check
  --: (RBNode) -> (boolean | nil, integer | string | nil)
  local function check(node)
    if node == NIL then
      return true, 1 -- black-height of nil leaf = 1
    end

    -- Invariant 1: every node is red or black
    if node.color ~= RED and node.color ~= BLACK then
      return nil, "invariant 1 violated: node has invalid color"
    end

    -- Invariant 4: if node is red, both children are black
    if node.color == RED then
      if node.left.color ~= BLACK then
        return nil, "invariant 4 violated: red node has red left child (key=" .. tostring(node.key) .. ")"
      end
      if node.right.color ~= BLACK then
        return nil, "invariant 4 violated: red node has red right child (key=" .. tostring(node.key) .. ")"
      end
    end

    -- Check parent pointer consistency
    if node.left ~= NIL and node.left.parent ~= node then
      return nil, "parent pointer inconsistency at key=" .. tostring(node.key) .. " (left child)"
    end
    if node.right ~= NIL and node.right.parent ~= node then
      return nil, "parent pointer inconsistency at key=" .. tostring(node.key) .. " (right child)"
    end

    -- Recursively check subtrees
    local ok_l, bh_l = check(node.left)
    if not ok_l then return nil, bh_l end
    local bhl = bh_l --[[:! integer]]

    local ok_r, bh_r = check(node.right)
    if not ok_r then return nil, bh_r end
    local bhr = bh_r --[[:! integer]]

    -- Invariant 5: all paths have the same black-height
    if bhl ~= bhr then
      return nil, "invariant 5 violated: black-height mismatch at key=" .. tostring(node.key) ..
        " (left=" .. bhl .. ", right=" .. bhr .. ")"
    end

    local bh = bhl + (node.color == BLACK and 1 or 0)
    return true, bh
  end

  local ok, result = check(self._root)
  if not ok then return nil, result --[[:! string | nil]] end

  return true
end

return M
