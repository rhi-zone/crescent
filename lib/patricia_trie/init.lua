if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Patricia trie (radix trie / compressed trie).
-- Each node stores a common prefix substring, reducing memory for string sets
-- with long common prefixes. More space-efficient than a character-per-node trie.

local M = {}
M._tier = "pure"

--:: PatriciaTrie = { _root: unknown, _size: integer }

-- Returns the length of the longest common prefix of strings a and b.
local function common_prefix_len(a, b)
  local n = math.min(#a, #b)
  for i = 1, n do
    if a:byte(i) ~= b:byte(i) then return i - 1 end
  end
  return n
end

-- Create a new node.
local function make_node(prefix, value, has_value)
  return { prefix = prefix, value = value, has_value = has_value or false, children = {} }
end

-- Internal insert into node, where key is the remaining (unconsumed) portion.
-- Returns true if a new key was added, false if an existing key was updated.
local function node_insert(node, key, value)
  local first = key:sub(1, 1)
  local child = node.children[first]

  if child == nil then
    -- No edge with this first character: add a new leaf.
    node.children[first] = make_node(key, value, true)
    return true  -- new key
  end

  local cp = common_prefix_len(key, child.prefix)

  if cp == #child.prefix then
    if cp == #key then
      -- Exact match on this edge: update value at child.
      local is_new = not child.has_value
      child.has_value = true
      child.value = value
      return is_new
    else
      -- child.prefix is a proper prefix of key: recurse deeper.
      return node_insert(child, key:sub(cp + 1), value)
    end
  else
    -- Partial match: split child at cp.
    local old_suffix = child.prefix:sub(cp + 1)
    local new_suffix = key:sub(cp + 1)

    -- Create a new internal node with the common prefix.
    local split = make_node(child.prefix:sub(1, cp), nil, false)

    -- Old child gets the remaining suffix.
    child.prefix = old_suffix
    split.children[old_suffix:sub(1, 1)] = child

    -- New key's suffix (may be empty if key == common prefix).
    if #new_suffix == 0 then
      split.has_value = true
      split.value = value
    else
      split.children[new_suffix:sub(1, 1)] = make_node(new_suffix, value, true)
    end

    node.children[first] = split
    return true  -- new key
  end
end

-- Internal get: returns value, found_bool.
local function node_get(node, key)
  if key == "" then
    if node.has_value then return node.value, true end
    return nil, false
  end
  local first = key:sub(1, 1)
  local child = node.children[first]
  if child == nil then return nil, false end

  local cp = common_prefix_len(key, child.prefix)
  if cp < #child.prefix then
    -- key diverges before consuming the edge label.
    return nil, false
  end
  -- cp == #child.prefix; recurse with remaining key.
  return node_get(child, key:sub(cp + 1))
end

-- Internal remove. Returns removed_bool, subtree_is_empty_bool.
local function node_remove(node, key)
  if key == "" then
    if not node.has_value then return false, false end
    node.has_value = false
    node.value = nil
    -- Check if this node is now a pass-through with one child (could merge,
    -- but merging is optional for correctness; skip for simplicity).
    local empty = true
    for _ in pairs(node.children) do empty = false; break end
    return true, empty and not node.has_value
  end

  local first = key:sub(1, 1)
  local child = node.children[first]
  if child == nil then return false, false end

  local cp = common_prefix_len(key, child.prefix)
  if cp < #child.prefix then return false, false end

  local removed, child_empty = node_remove(child, key:sub(cp + 1))
  if removed and child_empty then
    node.children[first] = nil
  elseif removed then
    -- Optionally merge child with its sole child if child lost its value.
    -- Count children of child.
    if not child.has_value then
      local count = 0
      local only_key, only_child
      for k, v in pairs(child.children) do
        count = count + 1
        only_key = k
        only_child = v
      end
      if count == 1 then
        -- Merge: collapse child into only_child.
        only_child.prefix = child.prefix .. only_child.prefix
        node.children[first] = only_child
      end
    end
  end
  return removed, false
end

-- Collect all {key, value} pairs under node, prepending accumulated prefix.
local function collect(node, acc, results)
  if node.has_value then
    results[#results + 1] = { acc .. node.prefix, node.value }
  end
  -- Sort children for deterministic (lexicographic) output.
  local keys = {}
  for k in pairs(node.children) do keys[#keys + 1] = k end
  table.sort(keys)
  for i = 1, #keys do
    collect(node.children[keys[i]], acc .. node.prefix, results)
  end
end

-- Collect only keys under node.
local function collect_keys(node, acc, results)
  if node.has_value then
    results[#results + 1] = acc .. node.prefix
  end
  local keys = {}
  for k in pairs(node.children) do keys[#keys + 1] = k end
  table.sort(keys)
  for i = 1, #keys do
    collect_keys(node.children[keys[i]], acc .. node.prefix, results)
  end
end

-- Height of the subtree rooted at node (1-based: a leaf is height 1).
local function subtree_height(node)
  local max = 0
  for _, child in pairs(node.children) do
    local h = subtree_height(child)
    if h > max then max = h end
  end
  return max + 1
end

-- ── Trie object ────────────────────────────────────────────────────────────

-- Create a new Patricia trie.
--: () -> PatriciaTrie
function M.new()
  local self = {
    -- Sentinel root node; its prefix is always "" and it never holds a value
    -- (the empty string key is handled by has_value on root).
    _root = make_node("", nil, false),
    _size = 0,
  }
  return setmetatable(self, { __index = M })
end

-- Insert a key with an associated value (default true).
--: (key: string, value: (unknown | nil)) -> ()
function M:insert(key, value)
  if type(key) ~= "string" then return nil, "key must be a string" end
  if value == nil then value = true end

  -- Handle empty key directly on root.
  if key == "" then
    if not self._root.has_value then
      self._size = self._size + 1
    end
    self._root.has_value = true
    self._root.value = value
    return
  end

  local added = node_insert(self._root, key, value)
  if added then self._size = self._size + 1 end
end

-- Exact match lookup. Returns value or nil.
--: (key: string) -> (unknown | nil)
function M:get(key)
  if type(key) ~= "string" then return nil end
  if key == "" then
    if self._root.has_value then return self._root.value end
    return nil
  end
  local val, found = node_get(self._root, key)
  if found then return val end
  return nil
end

-- Returns true if the exact key exists.
--: (key: string) -> boolean
function M:contains(key)
  if type(key) ~= "string" then return false end
  if key == "" then return self._root.has_value end
  local _, found = node_get(self._root, key)
  return found
end

-- Remove a key. Returns true if removed, false if not found.
--: (key: string) -> boolean
function M:remove(key)
  if type(key) ~= "string" then return false end
  if key == "" then
    if not self._root.has_value then return false end
    self._root.has_value = false
    self._root.value = nil
    self._size = self._size - 1
    return true
  end
  local removed = node_remove(self._root, key)
  if removed then self._size = self._size - 1 end
  return removed
end

-- All keys that start with prefix, returned as {{key, value},...} sorted.
--: (prefix: string) -> { {string, unknown} }
function M:prefix_search(prefix)
  if type(prefix) ~= "string" then return {} end

  -- Walk down the trie consuming prefix.
  local node = self._root
  local consumed = 0  -- how many bytes of prefix we've consumed

  if prefix == "" then
    -- Return everything.
    local results = {}
    if node.has_value then results[#results + 1] = { "", node.value } end
    local keys = {}
    for k in pairs(node.children) do keys[#keys + 1] = k end
    table.sort(keys)
    for i = 1, #keys do
      collect(node.children[keys[i]], "", results)
    end
    return results
  end

  -- Navigate from root's children.
  local remaining = prefix
  while #remaining > 0 do
    local first = remaining:sub(1, 1)
    local child = node.children[first]
    if child == nil then return {} end

    local cp = common_prefix_len(remaining, child.prefix)

    if cp == #remaining then
      -- The prefix ends inside (or exactly at) this edge.
      -- Collect all keys in this subtree, prepending what we've consumed so far.
      local results = {}
      local base = prefix:sub(1, consumed)  -- prefix bytes before this edge
      -- The subtree root is child; we need to reconstruct full keys.
      -- child.prefix starts with 'remaining' (the unconsumed prefix part).
      -- So keys in child's subtree should be prefixed with (base + child.prefix[...]).
      -- We call collect but need to adjust: collect prepends acc + node.prefix.
      -- Let's traverse child directly.
      local partial = child.prefix:sub(cp + 1)  -- suffix of edge label after prefix ends
      -- The key at child (if has_value) is: consumed_prefix + child.prefix
      local child_full_prefix = prefix:sub(1, consumed) .. child.prefix

      if child.has_value then
        results[#results + 1] = { child_full_prefix, child.value }
      end
      local ckeys = {}
      for k in pairs(child.children) do ckeys[#ckeys + 1] = k end
      table.sort(ckeys)
      for i = 1, #ckeys do
        collect(child.children[ckeys[i]], child_full_prefix, results)
      end
      return results
    elseif cp < #child.prefix then
      -- Edge label diverges before we finish matching the prefix.
      return {}
    else
      -- cp == #child.prefix: consumed entire edge label, prefix continues.
      consumed = consumed + cp
      remaining = remaining:sub(cp + 1)
      node = child
    end
  end

  -- remaining is empty: collect all from node.
  local results = {}
  local base = prefix  -- everything consumed
  if node.has_value then
    results[#results + 1] = { base, node.value }
  end
  local keys = {}
  for k in pairs(node.children) do keys[#keys + 1] = k end
  table.sort(keys)
  for i = 1, #keys do
    collect(node.children[keys[i]], base, results)
  end
  return results
end

-- Longest prefix match: the longest key that is a prefix of query.
-- Returns key, value (or nil if none).
--: (query: string) -> ((string | nil), (unknown | nil))
function M:longest_prefix(query)
  if type(query) ~= "string" then return nil end

  local last_key, last_val
  if self._root.has_value then
    last_key = ""
    last_val = self._root.value
  end

  local node = self._root
  local consumed = 0

  while consumed < #query do
    local remaining = query:sub(consumed + 1)
    local first = remaining:sub(1, 1)
    local child = node.children[first]
    if child == nil then break end

    local cp = common_prefix_len(remaining, child.prefix)
    if cp < #child.prefix then break end  -- edge label extends beyond what query has

    consumed = consumed + cp
    node = child

    if node.has_value then
      last_key = query:sub(1, consumed)
      last_val = node.value
    end
  end

  return last_key, last_val
end

-- Autocomplete: all keys starting with prefix (just keys, sorted).
--: (prefix: string) -> {string}
function M:autocomplete(prefix)
  local pairs_list = self:prefix_search(prefix)
  local keys = {}
  for i = 1, #pairs_list do
    keys[i] = pairs_list[i][1]
  end
  return keys
end

-- Number of keys stored.
--: () -> number
function M:size()
  return self._size
end

-- Call fn(key, value) for every key in lexicographic order.
--: (fn: (key: string, value: unknown) -> ()) -> ()
function M:each(fn)
  local arr = self:to_array()
  for i = 1, #arr do
    fn(arr[i][1], arr[i][2])
  end
end

-- Sorted array of {key, value} pairs.
--: () -> { {string, unknown} }
function M:to_array()
  local results = {}
  if self._root.has_value then
    results[#results + 1] = { "", self._root.value }
  end
  local keys = {}
  for k in pairs(self._root.children) do keys[#keys + 1] = k end
  table.sort(keys)
  for i = 1, #keys do
    collect(self._root.children[keys[i]], "", results)
  end
  return results
end

-- Maximum depth of the trie.
--: () -> number
function M:height()
  local max = 0
  for _, child in pairs(self._root.children) do
    local h = subtree_height(child)
    if h > max then max = h end
  end
  return max
end

-- True if no keys are stored.
--: () -> boolean
function M:is_empty()
  return self._size == 0
end

return M
