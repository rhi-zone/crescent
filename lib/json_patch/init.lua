-- lib/json_patch/init.lua
-- RFC 6901 JSON Pointer and RFC 6902 JSON Patch for LuaJIT.
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local concat = table.concat
local type, pairs, ipairs, tostring = type, pairs, ipairs, tostring
local floor = math.floor

-- ---------------------------------------------------------------------------
-- Array detection
-- ---------------------------------------------------------------------------

-- Returns true if t is a Lua table that represents a JSON array.
-- An array has only consecutive integer keys starting at 1 (or is empty {}).
--: (unknown) -> boolean
local function is_array(t)
  if type(t) ~= "table" then return false end
  local n = #(t --[[: { [integer]: any }]])
  -- Check no non-integer or out-of-range keys exist
  local count = 0
  for k in pairs(t --[[: { [any]: any }]]) do
    if type(k) ~= "number" or k ~= floor(k --[[: number]]) or (k --[[: number]]) < 1 or (k --[[: number]]) > n then
      return false
    end
    count = count + 1
  end
  return count == n
end

-- ---------------------------------------------------------------------------
-- Deep copy
-- ---------------------------------------------------------------------------

local function deep_copy(val)
  if type(val) ~= "table" then return val end
  local copy = {}
  for k, v in pairs(val) do
    copy[k] = deep_copy(v)
  end
  return copy
end

M.deep_copy = deep_copy

-- ---------------------------------------------------------------------------
-- Deep equality
-- ---------------------------------------------------------------------------

local function deep_equal(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  -- Check every key in a exists in b with same value
  for k, v in pairs(a) do
    if not deep_equal(v, b[k]) then return false end
  end
  -- Check b has no extra keys
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

M.deep_equal = deep_equal

-- ---------------------------------------------------------------------------
-- RFC 6901 JSON Pointer
-- ---------------------------------------------------------------------------

-- Unescape a single pointer token: ~1 → /, ~0 → ~
-- Order matters: ~1 first, then ~0 (per spec).
--: (string) -> string
function M.unescape(token)
  -- Replace ~1 first (must not re-process the ~)
  token = token:gsub("~1", "/")
  token = token:gsub("~0", "~")
  return token
end

-- Escape a single token: ~ → ~0, / → ~1
--: (string) -> string
function M.escape(token)
  token = token:gsub("~", "~0")
  token = token:gsub("/", "~1")
  return token
end

-- Parse a JSON Pointer string into an array of (unescaped) tokens.
-- "" → {} (root)
-- "/foo/bar" → {"foo", "bar"}
--: (string) -> ({ [integer]: string } | nil, string | nil)
function M.parse(ptr)
  if ptr == "" then return {} end
  if ptr:sub(1, 1) ~= "/" then
    return nil, "json pointer must be empty or start with '/'"
  end
  local parts = {}
  -- Split on "/" and unescape
  for token in (ptr:sub(2) .. "/"):gmatch("([^/]*)/") do
    parts[#parts + 1] = M.unescape(token)
  end
  return parts
end

-- Build a JSON Pointer string from an array of tokens (will be escaped).
function M.build(parts)
  if #parts == 0 then return "" end
  local out = {}
  for i, p in ipairs(parts) do
    out[i] = M.escape(tostring(p))
  end
  return "/" .. concat(out, "/")
end

-- Internal: resolve pointer on doc, returning (parent, key, value) or (nil, nil, nil, errmsg)
-- parent is the containing table, key is the key in that table.
-- For the root pointer, parent=nil, key=nil, value=doc.
local function resolve(doc, ptr)
  if ptr == "" then
    return nil, nil, doc
  end
  local parts, err = M.parse(ptr)
  if not parts then return nil, nil, nil, err end
  if #parts == 0 then
    return nil, nil, doc
  end

  local node = doc
  for i = 1, #parts - 1 do
    local token = parts[i]
    if type(node) ~= "table" then
      return nil, nil, nil, "path not found: /" .. concat(parts, "/", 1, i)
    end
    -- array index (0-based in JSON → 1-based in Lua)
    if is_array(node) then
      local idx = tonumber(token)
      if idx == nil then
        return nil, nil, nil, "invalid array index: " .. token
      end
      node = node[idx + 1]
    else
      node = node[token]
    end
    if node == nil then
      return nil, nil, nil, "path not found at token: " .. token
    end
  end

  local last = parts[#parts]
  local last_idx = tonumber(last)
  local key = (is_array(node) and last_idx ~= nil) and (last_idx + 1) or last
  return node, last, node[key]
end

-- pointer_get: get value at JSON Pointer path in doc.
-- Returns (value, nil) or (nil, errmsg).
function M.pointer_get(doc, ptr)
  if ptr == "" then return doc, nil end
  local parts, err = M.parse(ptr)
  if not parts then return nil, err end
  if #parts == 0 then return doc, nil end

  local node = doc
  for i, token in ipairs(parts) do
    if type(node) ~= "table" then
      return nil, "path not found at step " .. i .. ": " .. token
    end
    local key
    if is_array(node) then
      local idx = tonumber(token)
      if idx == nil then
        return nil, "invalid array index: " .. token
      end
      key = idx + 1
    else
      key = token
    end
    node = node[key]
    if node == nil then
      return nil, "path not found at token: " .. token
    end
  end
  return node, nil
end

-- Internal: get parent table and the key within it for the final token.
-- Returns (parent, key, err) where key is already converted for arrays.
local function get_parent_key(doc, ptr)
  if ptr == "" then
    return nil, nil, "cannot target root for set/del"
  end
  local parts, err = M.parse(ptr)
  if not parts then return nil, nil, err end
  if #parts == 0 then return nil, nil, "cannot target root for set/del" end

  local node = doc
  for i = 1, #parts - 1 do
    local token = parts[i]
    if type(node) ~= "table" then
      return nil, nil, "path not found at step " .. i
    end
    if is_array(node) then
      local idx = tonumber(token)
      if idx == nil then return nil, nil, "invalid array index: " .. token end
      node = node[idx + 1]
    else
      node = node[token]
    end
    if node == nil then
      return nil, nil, "path not found at token: " .. token
    end
  end

  local last = parts[#parts]
  if type(node) ~= "table" then
    return nil, nil, "parent is not a table"
  end
  local key
  if is_array(node) then
    if last == "-" then
      key = #node + 1  -- append position
    else
      local idx = tonumber(last)
      if idx == nil then return nil, nil, "invalid array index: " .. last end
      key = idx + 1
    end
  else
    key = last
  end
  return node, key, nil
end

-- pointer_set: set value at JSON Pointer path in doc (modifies in place).
-- Returns (true, nil) or (nil, errmsg).
function M.pointer_set(doc, ptr, value)
  local parent, key, err = get_parent_key(doc, ptr)
  if err then return nil, err end
  parent[key] = value
  return true, nil
end

-- pointer_del: delete value at JSON Pointer path in doc (modifies in place).
-- For arrays, shifts elements left. Returns (true, nil) or (nil, errmsg).
function M.pointer_del(doc, ptr)
  local parent, key, err = get_parent_key(doc, ptr)
  if err then return nil, err end
  if parent[key] == nil then
    return nil, "path does not exist"
  end
  if is_array(parent) then
    -- Remove element at position key, shifting rest
    table.remove(parent, key)
  else
    parent[key] = nil
  end
  return true, nil
end

-- ---------------------------------------------------------------------------
-- RFC 6902 JSON Patch
-- ---------------------------------------------------------------------------

-- validate_patch: check all ops have required fields.
-- Returns (true, nil) or (nil, errmsg).
--: (unknown) -> (boolean | nil, string | nil)
function M.validate_patch(patch)
  if type(patch) ~= "table" then
    return nil, "patch must be an array"
  end
  for i, op in ipairs(patch --[[: { [integer]: { op?: unknown, path?: unknown, value?: unknown, from?: unknown } } ]]) do
    if type(op) ~= "table" then
      return nil, "operation " .. i .. " must be a table"
    end
    local o = op.op
    if o == nil then
      return nil, "operation " .. i .. " missing 'op' field"
    end
    if o == "add" or o == "replace" or o == "test" then
      if op.path == nil then return nil, "op '" .. o .. "' missing 'path'" end
      if op.value == nil then return nil, "op '" .. o .. "' missing 'value'" end
    elseif o == "remove" then
      if op.path == nil then return nil, "op 'remove' missing 'path'" end
    elseif o == "move" or o == "copy" then
      if op.from == nil then return nil, "op '" .. o .. "' missing 'from'" end
      if op.path == nil then return nil, "op '" .. o .. "' missing 'path'" end
    else
      return nil, "unknown op: " .. tostring(o)
    end
  end
  return true, nil
end

-- Internal: apply a single operation to doc (modified in place).
-- Returns (true, nil) or (nil, errmsg).
--: (unknown, { op: string, path: string, from?: string, value?: unknown }) -> (unknown, string | nil)
local function apply_one(doc, op)
  local o = op.op
  if o == "add" then
    -- Special case: add to root
    if op.path == "" then
      return nil, "cannot 'add' to root (use replace)"
    else end
    -- For array parent, insert at index rather than overwrite
    local parts, err = M.parse(op.path)
    if not parts then return nil, err end

    -- Navigate to parent
    local node = doc
    for i = 1, #parts - 1 do
      local token = parts[i]
      if type(node) ~= "table" then
        return nil, "add: path not found at step " .. i
      end
      if is_array(node) then
        local idx = tonumber(token)
        if idx == nil then return nil, "add: invalid array index: " .. token end
        node = node[idx + 1]
      else
        node = node[token]
      end
      if node == nil then
        return nil, "add: path not found at token: " .. token
      end
    end

    local last = parts[#parts]
    if type(node) ~= "table" then
      return nil, "add: parent is not a table"
    end

    -- Decide how to insert: only do array-mode insert when the key is
    -- numeric or "-" AND the table is actually an array (non-empty or empty
    -- but the key is numeric/"-"). If the key is a non-numeric string,
    -- always do object-mode assignment (handles empty-table-becomes-object case).
    local is_numeric_key = (last == "-") or (tonumber(last) ~= nil)
    if is_array(node) and is_numeric_key then
      if last == "-" then
        node[#node + 1] = op.value
      else
        local idx = tonumber(last)
        if idx == nil then return nil, "add: invalid array index: " .. last end
        local lua_idx = idx + 1
        if lua_idx < 1 or lua_idx > #node + 1 then
          return nil, "add: array index out of range: " .. last
        end
        table.insert(node, lua_idx, op.value)
      end
    else
      node[last] = op.value
    end
    return true, nil

  elseif o == "remove" then
    return M.pointer_del(doc, op.path)

  elseif o == "replace" then
    -- Target must exist
    local cur, err = M.pointer_get(doc, op.path)
    if err then return nil, "replace: " .. err end
    if cur == nil and op.path ~= "" then
      return nil, "replace: path does not exist"
    end
    if op.path == "" then
      return nil, "replace: cannot replace root"
    else
      return M.pointer_set(doc, op.path, op.value)
    end

  elseif o == "move" then
    local from = op.from
    if from == nil then return nil, "move: missing 'from'" end
    if from == op.path then return true, nil end
    -- Check from doesn't start with path (can't move into child)
    if op.path:sub(1, #from) == from and
       (op.path:sub(#from + 1, #from + 1) == "/" or op.path == from) then
      return nil, "move: cannot move to child of from"
    end
    local val, err = M.pointer_get(doc, from)
    if err then return nil, "move: " .. tostring(err) end
    local ok, e2 = M.pointer_del(doc, from)
    if not ok then return nil, "move del: " .. tostring(e2) end
    return apply_one(doc, { op = "add", path = op.path, value = val })

  elseif o == "copy" then
    local from = op.from
    if from == nil then return nil, "copy: missing 'from'" end
    local val, err = M.pointer_get(doc, from)
    if err then return nil, "copy: " .. tostring(err) end
    return apply_one(doc, { op = "add", path = op.path, value = deep_copy(val) })

  elseif o == "test" then
    local val, err = M.pointer_get(doc, op.path)
    if err then return nil, "test: " .. err end
    if not deep_equal(val, --[[:! boolean | number | string | nil | { ... }]] op.value) then
      return nil, "test failed at " .. op.path
    end
    return true, nil

  else
    return nil, "unknown op: " .. tostring(o)
  end
end

-- apply: apply a JSON Patch to a document.
-- Works on a deep copy; returns the patched copy on success,
-- or (nil, errmsg) on failure (original is not modified).
function M.apply(doc, patch)
  local ok, err = M.validate_patch(patch)
  if not ok then return nil, err end

  local copy = deep_copy(doc)
  for i, op in ipairs(patch) do
    local res, e = apply_one(copy, op)
    if not res then
      return nil, "op " .. i .. " (" .. tostring(op.op) .. "): " .. tostring(e)
    end
  end
  return copy, nil
end

-- ---------------------------------------------------------------------------
-- Diff (generate patch from two documents)
-- ---------------------------------------------------------------------------

-- Forward declaration
local diff_val

-- Diff two arrays: element-by-element LCS-based diff.
-- Emits operations into `ops` with the given `base_path` prefix.
-- For simplicity, we use a straightforward approach:
--   find common prefix and suffix, then handle the middle with remove/add.
local function diff_array(ops, base_path, a, b)
  -- Find common prefix
  local prefix = 0
  local na, nb = #a, #b
  while prefix < na and prefix < nb and deep_equal(a[prefix+1], b[prefix+1]) do
    prefix = prefix + 1
  end

  -- Find common suffix (within remaining elements)
  local suffix = 0
  while suffix < (na - prefix) and suffix < (nb - prefix) and
        deep_equal(a[na - suffix], b[nb - suffix]) do
    suffix = suffix + 1
  end

  local a_mid_start = prefix + 1
  local a_mid_end   = na - suffix
  local b_mid_start = prefix + 1
  local b_mid_end   = nb - suffix

  local a_mid_len = a_mid_end - a_mid_start + 1
  local b_mid_len = b_mid_end - b_mid_start + 1

  -- Remove excess elements from a (remove from back to front to preserve indices)
  -- After prefix, middle of a has a_mid_len elements.
  -- We need b_mid_len elements there.
  if a_mid_len > b_mid_len then
    -- Remove extra a elements (from the end of middle, working backwards keeps indices stable)
    for i = a_mid_end, a_mid_start + b_mid_len, -1 do
      ops[#ops+1] = { op = "remove", path = base_path .. "/" .. (i - 1) }
    end
  end

  -- Replace/add in middle
  for i = 0, b_mid_len - 1 do
    local ai = a_mid_start + i   -- 1-based index into a
    local bi = b_mid_start + i   -- 1-based index into b
    local json_idx = prefix + i  -- 0-based JSON index
    local elem_path = base_path .. "/" .. json_idx
    if ai <= a_mid_end then
      -- Both have this position — recurse diff
      diff_val(ops, elem_path, a[ai], b[bi])
    else
      -- b has more elements: insert
      ops[#ops+1] = { op = "add", path = elem_path, value = deep_copy(b[bi]) }
    end
  end
end

-- Diff two objects (non-array tables).
local function diff_object(ops, base_path, a, b)
  -- Keys in a but not b → remove
  for k in pairs(a) do
    if b[k] == nil then
      ops[#ops+1] = { op = "remove", path = base_path .. "/" .. M.escape(tostring(k)) }
    end
  end
  -- Keys in b but not a → add; keys in both → recurse
  for k, bv in pairs(b) do
    local key_path = base_path .. "/" .. M.escape(tostring(k))
    if a[k] == nil then
      ops[#ops+1] = { op = "add", path = key_path, value = deep_copy(bv) }
    else
      diff_val(ops, key_path, a[k], bv)
    end
  end
end

-- Diff two arbitrary values.
diff_val = function(ops, path, a, b)
  if deep_equal(a, b) then return end
  if type(a) == "table" and type(b) == "table" then
    local a_arr = is_array(a)
    local b_arr = is_array(b)
    if a_arr and b_arr then
      diff_array(ops, path, a, b)
      return
    elseif not a_arr and not b_arr then
      diff_object(ops, path, a, b)
      return
    end
    -- Type changed (array ↔ object): just replace
  end
  ops[#ops+1] = { op = "replace", path = path, value = deep_copy(b) }
end

-- diff: generate a JSON Patch that transforms doc_a into doc_b.
-- Returns an array of patch operations.
function M.diff(doc_a, doc_b)
  if deep_equal(doc_a, doc_b) then return {} end
  local ops = {} --[[: { op: string, path: string, value?: unknown, from?: string }[] ]]
  if type(doc_a) == "table" and type(doc_b) == "table" then
    local a_arr = is_array(doc_a)
    local b_arr = is_array(doc_b)
    if a_arr and b_arr then
      diff_array(ops, "", doc_a, doc_b)
    elseif not a_arr and not b_arr then
      diff_object(ops, "", doc_a, doc_b)
    else
      -- Can't patch root type change meaningfully with standard ops
      -- Emit individual add/remove for each key
      if a_arr then
        -- a is array, b is object
        for i = #doc_a, 1, -1 do
          ops[#ops+1] = { op = "remove", path = "/" .. (i-1) }
        end
        for k, v in pairs(doc_b) do
          ops[#ops+1] = { op = "add", path = "/" .. M.escape(tostring(k)), value = deep_copy(v) }
        end
      else
        for k in pairs(doc_a) do
          ops[#ops+1] = { op = "remove", path = "/" .. M.escape(tostring(k)) }
        end
        for i, v in ipairs(doc_b --[[: { [integer]: unknown } ]]) do
          ops[#ops+1] = { op = "add", path = "/" .. (i-1), value = deep_copy(v) }
        end
      end
    end
  else
    -- Scalar root replacement: not standard RFC 6902 but pragmatic
    ops[#ops+1] = { op = "replace", path = "", value = deep_copy(doc_b) }
  end
  return ops
end

return M
