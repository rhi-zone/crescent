if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Trie (prefix tree) data structure.
-- Efficient string prefix lookup, autocomplete, prefix counting.
-- Useful for routing, command completion, dictionary operations.

local M = {}

-- opts.compressed: if true, logically a radix/Patricia trie (no-op at this tier; same interface)
--: (opts?: { compressed: boolean | nil }) -> Trie
function M.new(opts)
  local self = {
    _root = { children = {} },
    _size = 0,
    _compressed = opts and opts.compressed or false,
  }
  return setmetatable(self, { __index = M })
end

-- Navigate to the node for the given prefix.
-- Returns the node or nil if the prefix path does not exist.
local function walk(root, str)
  local node = root
  for i = 1, #str do
    local ch = str:byte(i)
    node = node.children[ch]
    if not node then return nil end
  end
  return node
end

-- Insert a key with an associated value (default true).
--: (key: string, value?: unknown) -> ()
function M:insert(key, value)
  if type(key) ~= "string" then return nil, "key must be a string" end
  if value == nil then value = true end
  local node = self._root
  for i = 1, #key do
    local ch = key:byte(i)
    if not node.children[ch] then
      node.children[ch] = { children = {} }
    end
    node = node.children[ch]
  end
  if node.value == nil then
    self._size = self._size + 1
  end
  node.value = value
  node.has_value = true
end

-- Exact match lookup. Returns value or nil.
--: (key: string) -> unknown?
function M:get(key)
  if type(key) ~= "string" then return nil, "key must be a string" end
  local node = walk(self._root, key)
  if node and node.has_value then return node.value end
  return nil
end

-- Returns true if the exact key exists.
--: (key: string) -> boolean
function M:has(key)
  if type(key) ~= "string" then return false end
  local node = walk(self._root, key)
  return node ~= nil and node.has_value == true
end

-- Remove a key. Returns old value or nil.
--: (key: string) -> unknown?
function M:remove(key)
  if type(key) ~= "string" then return nil, "key must be a string" end
  local node = walk(self._root, key)
  if not node or not node.has_value then return nil end
  local old = node.value
  node.value = nil
  node.has_value = nil
  self._size = self._size - 1
  return old
end

-- Number of keys stored.
--: () -> number
function M:size()
  return self._size
end

-- Returns true if any stored key starts with prefix.
--: (prefix: string) -> boolean
function M:has_prefix(prefix)
  if type(prefix) ~= "string" then return false end
  local node = walk(self._root, prefix)
  if not node then return false end
  -- The subtree is non-empty if this node has a value or has children with values.
  if node.has_value then return true end
  -- BFS/DFS to check for any value in subtree.
  local stack = { node }
  while #stack > 0 do
    local n = stack[#stack]
    stack[#stack] = nil
    for _, child in pairs(n.children) do
      if child.has_value then return true end
      stack[#stack + 1] = child
    end
  end
  return false
end

-- Collect all key-value pairs in the subtree rooted at node.
-- buf is the byte buffer for the current prefix, results is the output array.
local function collect(node, buf, results)
  if node.has_value then
    results[#results + 1] = { string.char(unpack(buf)), node.value }
  end
  -- Sort children by byte value for deterministic (sorted) output.
  local keys = {}
  for ch in pairs(node.children) do
    keys[#keys + 1] = ch
  end
  table.sort(keys)
  for i = 1, #keys do
    buf[#buf + 1] = keys[i]
    collect(node.children[keys[i]], buf, results)
    buf[#buf] = nil
  end
end

-- Collect keys only (sorted) in the subtree.
local function collect_keys(node, buf, results)
  if node.has_value then
    results[#results + 1] = string.char(unpack(buf))
  end
  local keys = {}
  for ch in pairs(node.children) do
    keys[#keys + 1] = ch
  end
  table.sort(keys)
  for i = 1, #keys do
    buf[#buf + 1] = keys[i]
    collect_keys(node.children[keys[i]], buf, results)
    buf[#buf] = nil
  end
end

-- Collect up to limit keys (sorted) in the subtree.
local function collect_keys_limited(node, buf, results, limit)
  if #results >= limit then return end
  if node.has_value then
    results[#results + 1] = string.char(unpack(buf))
    if #results >= limit then return end
  end
  local keys = {}
  for ch in pairs(node.children) do
    keys[#keys + 1] = ch
  end
  table.sort(keys)
  for i = 1, #keys do
    if #results >= limit then return end
    buf[#buf + 1] = keys[i]
    collect_keys_limited(node.children[keys[i]], buf, results, limit)
    buf[#buf] = nil
  end
end

-- Count all keys in the subtree.
local function count_subtree(node)
  local c = 0
  if node.has_value then c = 1 end
  for _, child in pairs(node.children) do
    c = c + count_subtree(child)
  end
  return c
end

-- Array of {key, value} for all keys starting with prefix (sorted).
--: (prefix: string) -> { {string, unknown} }
function M:find_prefix(prefix)
  if type(prefix) ~= "string" then return {} end
  local node = walk(self._root, prefix)
  if not node then return {} end
  local buf = {}
  for i = 1, #prefix do buf[i] = prefix:byte(i) end
  local results = {}
  collect(node, buf, results)
  return results
end

-- Number of keys starting with prefix.
--: (prefix: string) -> number
function M:count_prefix(prefix)
  if type(prefix) ~= "string" then return 0 end
  local node = walk(self._root, prefix)
  if not node then return 0 end
  return count_subtree(node)
end

-- Longest stored key that is a prefix of str.
-- Returns (key, value) or nil.
--: (str: string) -> string?, unknown?
function M:longest_prefix(str)
  if type(str) ~= "string" then return nil end
  local node = self._root
  local last_key, last_val
  if node.has_value then
    last_key = ""
    last_val = node.value
  end
  for i = 1, #str do
    local ch = str:byte(i)
    node = node.children[ch]
    if not node then break end
    if node.has_value then
      last_key = str:sub(1, i)
      last_val = node.value
    end
  end
  return last_key, last_val
end

-- Up to limit keys starting with prefix (sorted). Default limit: all.
--: (prefix: string, limit?: number) -> {string}
function M:autocomplete(prefix, limit)
  if type(prefix) ~= "string" then return {} end
  local node = walk(self._root, prefix)
  if not node then return {} end
  local buf = {}
  for i = 1, #prefix do buf[i] = prefix:byte(i) end
  local results = {}
  if limit then
    collect_keys_limited(node, buf, results, limit)
  else
    collect_keys(node, buf, results)
  end
  return results
end

-- Array of all keys (sorted).
--: () -> {string}
function M:keys()
  local results = {}
  collect_keys(self._root, {}, results)
  return results
end

-- Array of all values (key-sorted order).
--: () -> {unknown}
function M:values()
  local results = {}
  collect(self._root, {}, results)
  local vals = {}
  for i = 1, #results do
    vals[i] = results[i][2]
  end
  return vals
end

-- Iterator: key, value (sorted order).
--: () -> () -> string?, unknown?
function M:pairs()
  local results = {}
  collect(self._root, {}, results)
  local i = 0
  return function()
    i = i + 1
    if results[i] then
      return results[i][1], results[i][2]
    end
  end
end

-- Remove all keys.
--: () -> ()
function M:clear()
  self._root = { children = {} }
  self._size = 0
end

-- Aliases for spec-compatible API names.
-- delete: alias for remove. Returns true if key existed, false if not.
--: (key: string) -> boolean
function M:delete(key)
  local old = self:remove(key)
  return old ~= nil
end

-- completions: alias for autocomplete. Returns sorted key list with given prefix.
--: (prefix: string, limit?: number) -> {string}
M.completions = M.autocomplete

-- all: alias for keys. Returns all keys sorted.
--: () -> {string}
M.all = M.keys

-- iter: alias for pairs. Iterator over (key, value) in sorted order.
--: () -> () -> string?, unknown?
M.iter = M.pairs

M._tier = "pure"

return M
