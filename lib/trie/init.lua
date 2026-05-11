if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Trie (prefix tree) data structure.
-- Efficient string prefix lookup, autocomplete, prefix counting.
-- Useful for routing, command completion, dictionary operations.

local M = {}

--:: TrieNode = { children: { [integer]: TrieNode }, has_value: boolean | nil, value: unknown | nil }
--:: Trie = { _root: TrieNode, _size: integer, _compressed: boolean }

-- opts.compressed: if true, logically a radix/Patricia trie (no-op at this tier; same interface)
--: (opts: ({ compressed: boolean | nil } | nil)) -> Trie
function M.new(opts)
  local self = {
    _root = { children = {}, has_value = nil, value = nil },
    _size = 0,
    _compressed = opts and opts.compressed or false,
  }
  local t = setmetatable(self, { __index = M }) --[[: unknown]]
  return t --[[:! Trie]]
end

-- Navigate to the node for the given prefix.
-- Returns the node or nil if the prefix path does not exist.
--: (TrieNode, string) -> (TrieNode | nil)
local function walk(root, str)
  local node = root --: TrieNode | nil
  for i = 1, #str do
    local ch = str:byte(i)
    local node_ = node --[[:! TrieNode]]
    node = node_.children[ch]
    if not node then return nil end
  end
  return node
end

-- Insert a key with an associated value (default true).
--: (self: Trie, key: string, value: (unknown | nil)) -> ()
function M:insert(key, value)
  if type(key) ~= "string" then return nil, "key must be a string" end
  if value == nil then value = true end
  local node = self._root
  for i = 1, #key do
    local ch = key:byte(i)
    local node_ = node --[[:! TrieNode]]
    if not node_.children[ch] then
      node_.children[ch] = { children = {}, has_value = nil, value = nil }
    end
    node = node_.children[ch]
  end
  local node_ = node --[[:! TrieNode]]
  if node_.value == nil then
    self._size = self._size + 1
  end
  node_.value = value
  node_.has_value = true
end

-- Exact match lookup. Returns value or nil.
--: (self: Trie, key: string) -> (unknown | nil)
function M:get(key)
  if type(key) ~= "string" then return nil, "key must be a string" end
  local node = walk(self._root, key)
  if node and node.has_value then return node.value end
  return nil
end

-- Returns true if the exact key exists.
--: (self: Trie, key: string) -> boolean
function M:has(key)
  if type(key) ~= "string" then return false end
  local node = walk(self._root, key)
  return (node ~= nil and node.has_value == true) and true or false
end

-- Remove a key. Returns old value or nil.
--: (self: Trie, key: string) -> (unknown | nil)
function M:remove(key)
  if type(key) ~= "string" then return nil, "key must be a string" end
  local node = walk(self._root, key)
  if not node or not node.has_value then return nil end
  local old = node.value
  node.value = nil
  node.has_value = false
  self._size = self._size - 1
  return old
end

-- Number of keys stored.
--: (self: Trie) -> number
function M:size()
  return self._size
end

-- Returns true if any stored key starts with prefix.
--: (self: Trie, prefix: string) -> boolean
function M:has_prefix(prefix)
  if type(prefix) ~= "string" then return false end
  local node = walk(self._root, prefix)
  if not node then return false end
  -- The subtree is non-empty if this node has a value or has children with values.
  if node.has_value then return true end
  -- BFS/DFS to check for any value in subtree.
  local stack = { node } --: { [integer]: TrieNode }
  while #stack > 0 do
    local n = stack[#stack]
    stack[#stack] = nil --[[: unknown]]
    for _, child in pairs(n.children) do
      local child_ = child --[[:! TrieNode]]
      if child_.has_value then return true end
      stack[#stack + 1] = child_
    end
  end
  return false
end

-- Collect all key-value pairs in the subtree rooted at node.
-- buf is the byte buffer for the current prefix, results is the output array.
--: (TrieNode, { [integer]: integer }, { [integer]: { [integer]: unknown } }) -> nil
local function collect(node, buf, results)
  if node.has_value then
    results[#results + 1] = { string.char(unpack(buf)) --[[:! string]], node.value }
  end
  -- Sort children by byte value for deterministic (sorted) output.
  local keys = {} --: { [integer]: integer }
  for ch in pairs(node.children) do
    keys[#keys + 1] = ch --[[:! integer]]
  end
  table.sort(keys)
  for i = 1, #keys do
    buf[#buf + 1] = keys[i]
    collect(node.children[keys[i]], buf, results)
    buf[#buf] = nil --[[: unknown]]
  end
end

-- Collect keys only (sorted) in the subtree.
--: (TrieNode, { [integer]: integer }, { [integer]: string }) -> nil
local function collect_keys(node, buf, results)
  if node.has_value then
    results[#results + 1] = string.char(unpack(buf)) --[[:! string]]
  end
  local keys = {} --: { [integer]: integer }
  for ch in pairs(node.children) do
    keys[#keys + 1] = ch --[[:! integer]]
  end
  table.sort(keys)
  for i = 1, #keys do
    buf[#buf + 1] = keys[i]
    collect_keys(node.children[keys[i]], buf, results)
    buf[#buf] = nil --[[: unknown]]
  end
end

-- Collect up to limit keys (sorted) in the subtree.
--: (TrieNode, { [integer]: integer }, { [integer]: string }, integer) -> nil
local function collect_keys_limited(node, buf, results, limit)
  if #results >= limit then return end
  if node.has_value then
    results[#results + 1] = string.char(unpack(buf)) --[[:! string]]
    if #results >= limit then return end
  end
  local keys = {} --: { [integer]: integer }
  for ch in pairs(node.children) do
    keys[#keys + 1] = ch --[[:! integer]]
  end
  table.sort(keys)
  for i = 1, #keys do
    if #results >= limit then return end
    buf[#buf + 1] = keys[i]
    collect_keys_limited(node.children[keys[i]], buf, results, limit)
    buf[#buf] = nil --[[: unknown]]
  end
end

-- Count all keys in the subtree.
--: (TrieNode) -> integer
local function count_subtree(node)
  local c = 0
  if node.has_value then c = 1 end
  for _, child in pairs(node.children) do
    local child_ = child --[[:! TrieNode]]
    c = c + count_subtree(child_)
  end
  return c
end

-- Array of {key, value} for all keys starting with prefix (sorted).
--: (self: Trie, prefix: string) -> { [integer]: { [integer]: unknown } }
function M:find_prefix(prefix)
  if type(prefix) ~= "string" then return {} end
  local node = walk(self._root, prefix)
  if not node then return {} end
  local buf = {} --: { [integer]: integer }
  for i = 1, #prefix do buf[i] = prefix:byte(i) or 0 end
  local results = {} --: { [integer]: { [integer]: unknown } }
  collect(node, buf, results)
  return results
end

-- Number of keys starting with prefix.
--: (self: Trie, prefix: string) -> number
function M:count_prefix(prefix)
  if type(prefix) ~= "string" then return 0 end
  local node = walk(self._root, prefix)
  if not node then return 0 end
  return count_subtree(node)
end

-- Longest stored key that is a prefix of str.
-- Returns (key, value) or nil.
--: (self: Trie, str: string) -> ((string | nil), (unknown | nil))
function M:longest_prefix(str)
  if type(str) ~= "string" then return nil end
  local node = self._root --: TrieNode | nil
  local last_key --: string | nil
  local last_val --: unknown | nil
  local node0 = node --[[:! TrieNode]]
  if node0.has_value then
    last_key = ""
    last_val = node0.value
  end
  for i = 1, #str do
    local ch = str:byte(i)
    local node_ = node --[[:! TrieNode]]
    node = node_.children[ch]
    if not node then break end
    local noden = node --[[:! TrieNode]]
    if noden.has_value then
      last_key = str:sub(1, i)
      last_val = noden.value
    end
  end
  return last_key, last_val
end

-- Up to limit keys starting with prefix (sorted). Default limit: all.
--: (self: Trie, prefix: string, limit: (integer | nil)) -> { [integer]: string }
function M:autocomplete(prefix, limit)
  if type(prefix) ~= "string" then return {} end
  local node = walk(self._root, prefix)
  if not node then return {} end
  local buf = {} --: { [integer]: integer }
  for i = 1, #prefix do buf[i] = prefix:byte(i) or 0 end
  local results = {} --: { [integer]: string }
  if limit then
    collect_keys_limited(node, buf, results, limit)
  else
    collect_keys(node, buf, results)
  end
  return results
end

-- Array of all keys (sorted).
--: (self: Trie) -> { [integer]: string }
function M:keys()
  local results = {} --: { [integer]: string }
  collect_keys(self._root, {}, results)
  return results
end

-- Array of all values (key-sorted order).
--: (self: Trie) -> { [integer]: unknown }
function M:values()
  local results = {} --: { [integer]: { [integer]: unknown } }
  collect(self._root, {}, results)
  local vals = {} --: { [integer]: unknown }
  for i = 1, #results do
    vals[i] = results[i][2]
  end
  return vals
end

-- Iterator: key, value (sorted order).
--: (self: Trie) -> () -> ((string | nil), (unknown | nil))
function M:pairs()
  local results = {} --: { [integer]: { [integer]: unknown } }
  collect(self._root, {}, results)
  local i = 0
  --: () -> ((string | nil), (unknown | nil))
  return function()
    i = i + 1
    local r = results[i]
    if r then
      return r[1] --[[:! string]], r[2]
    end
    return nil, nil
  end
end

-- Remove all keys.
--: (self: Trie) -> ()
function M:clear()
  self._root = { children = {}, has_value = nil, value = nil }
  self._size = 0
end

-- Aliases for spec-compatible API names.
-- delete: alias for remove. Returns true if key existed, false if not.
--: (self: Trie, key: string) -> boolean
function M:delete(key)
  local old = M.remove(self, key)
  return old ~= nil
end

-- completions: alias for autocomplete. Returns sorted key list with given prefix.
M.completions = M.autocomplete

-- all: alias for keys. Returns all keys sorted.
M.all = M.keys --[[: unknown]]

-- iter: alias for pairs. Iterator over (key, value) in sorted order.
M.iter = M.pairs --[[: unknown]]

M._tier = "pure"

return M
