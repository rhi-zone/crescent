if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

--- JSON Patch (RFC 6902) and JSON Pointer (RFC 6901) for structural data manipulation.
local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Deep-copy a value (tables only; primitives returned as-is).
--: (unknown) -> unknown
M.deep_copy = function(value)
  if type(value) ~= "table" then return value end
  local copy = {}
  for k, v in pairs(value) do
    copy[k] = M.deep_copy(v)
  end
  return copy
end

--- Shallow equality for primitives; deep equality for tables.
--: (unknown, unknown) -> boolean
local function deep_eq(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do
    if not deep_eq(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

-- ---------------------------------------------------------------------------
-- JSON Pointer (RFC 6901)
-- ---------------------------------------------------------------------------

--- Decode a single reference token: unescape ~1 → / and ~0 → ~.
--: (string) -> string
local function decode_token(tok)
  -- order matters: ~1 first, then ~0
  return (tok:gsub("~1", "/"):gsub("~0", "~"))
end

--- Encode a single reference token: escape ~ → ~0 and / → ~1.
--: (string) -> string
local function encode_token(tok)
  return (tok:gsub("~", "~0"):gsub("/", "~1"))
end

--- Parse a JSON Pointer string into an array of string keys.
--- Returns empty table for the root pointer "".
--: (string) -> ({ [number]: string } | nil, string | nil)
M.pointer_parse = function(ptr)
  if ptr == "" then return {} end
  if ptr:sub(1, 1) ~= "/" then
    return nil, "invalid JSON Pointer: must be empty or start with '/'"
  end
  local keys = {}
  for tok in (ptr:sub(2) .. "/"):gmatch("([^/]*)/") do
    keys[#keys + 1] = decode_token(tok)
  end
  return keys
end

--- Encode an array of keys into a JSON Pointer string.
--: ({ [number]: string }) -> string
M.pointer_encode = function(keys)
  if #keys == 0 then return "" end
  local parts = {}
  for i, k in ipairs(keys) do
    parts[i] = encode_token(k)
  end
  return "/" .. table.concat(parts, "/")
end

--- Resolve the parent table and final key for a pointer path.
--- Returns (parent_table, key, nil) or (nil, nil, errmsg).
--: (unknown, { [number]: string }) -> (unknown | nil, string | nil, string | nil)
local function resolve_parent(doc, keys)
  if #keys == 0 then
    return nil, nil, "cannot get parent of root pointer"
  end
  local node = doc
  for i = 1, #keys - 1 do
    local k = keys[i]
    if type(node) ~= "table" then
      return nil, nil, "path not found: not a table at key '" .. k .. "'"
    end
    -- numeric key: JSON Pointer uses 0-based array indices
    local idx = tonumber(k)
    if idx then
      node = node[idx + 1]
    else
      node = node[k]
    end
    if node == nil then
      return nil, nil, "path not found: key '" .. k .. "' does not exist"
    end
  end
  if type(node) ~= "table" then
    return nil, nil, "path not found: parent is not a table"
  end
  return node, keys[#keys], nil
end

--- Get the value at a JSON Pointer path within doc.
--: (unknown, string) -> (unknown | nil, string | nil)
M.get = function(doc, ptr)
  local keys, err = M.pointer_parse(ptr)
  if not keys then return nil, err end
  if #keys == 0 then return doc end
  local node = doc
  for _, k in ipairs(keys) do
    if type(node) ~= "table" then
      return nil, "path not found: not a table"
    end
    local idx = tonumber(k)
    if idx then
      node = node[idx + 1]
    else
      node = node[k]
    end
    if node == nil then
      return nil, "path not found: key '" .. k .. "' does not exist"
    end
  end
  return node
end

--- Set the value at a JSON Pointer path. Returns a deep copy with the value set.
--- Pass opts.inplace = true to mutate doc directly (no copy).
--: (unknown, string, unknown, { inplace: boolean | nil } | nil) -> (unknown | nil, string | nil)
M.set = function(doc, ptr, value, opts)
  local keys, err = M.pointer_parse(ptr)
  if not keys then return nil, err end
  local target = (opts and opts.inplace) and doc or M.deep_copy(doc)
  if #keys == 0 then
    -- replacing root: just return the new value
    return value
  end
  local parent, final_key, perr = resolve_parent(target, keys)
  if not parent then return nil, perr end
  local idx = tonumber(final_key)
  if idx then
    parent[idx + 1] = value
  else
    parent[final_key] = value
  end
  return target
end

--- Remove the value at a JSON Pointer path. Returns a deep copy with value removed.
--: (unknown, string) -> (unknown | nil, string | nil)
M.remove = function(doc, ptr)
  local keys, err = M.pointer_parse(ptr)
  if not keys then return nil, err end
  if #keys == 0 then
    return nil, "cannot remove root"
  end
  local target = M.deep_copy(doc)
  local parent, final_key, perr = resolve_parent(target, keys)
  if not parent then return nil, perr end
  local idx = tonumber(final_key)
  if idx then
    local arr_idx = idx + 1
    if parent[arr_idx] == nil then
      return nil, "array index " .. idx .. " does not exist"
    end
    table.remove(parent, arr_idx)
  else
    if parent[final_key] == nil then
      return nil, "key '" .. tostring(final_key) .. "' does not exist"
    end
    parent[final_key] = nil
  end
  return target
end

-- ---------------------------------------------------------------------------
-- JSON Patch helpers: add / remove on a mutable (already-copied) doc
-- ---------------------------------------------------------------------------

--- Add a value at path in a mutable document.
--- "-" as final token appends to array.
--: (unknown, { [number]: string }, unknown) -> (boolean | nil, string | nil)
local function patch_add(doc, keys, value)
  if #keys == 0 then
    return nil, "cannot add at root (use replace)"
  end
  local parent, final_key, perr = resolve_parent(doc, keys)
  if not parent then return nil, perr end
  if final_key == "-" then
    -- append to array
    parent[#parent + 1] = value
  else
    local idx = tonumber(final_key)
    if idx then
      -- insert at position (shift elements right)
      table.insert(parent, idx + 1, value)
    else
      parent[final_key] = value
    end
  end
  return true
end

--- Remove a value at path in a mutable document.
--: (unknown, { [number]: string }) -> (boolean | nil, string | nil)
local function patch_remove(doc, keys)
  if #keys == 0 then
    return nil, "cannot remove root"
  end
  local parent, final_key, perr = resolve_parent(doc, keys)
  if not parent then return nil, perr end
  local idx = tonumber(final_key)
  if idx then
    local arr_idx = idx + 1
    if parent[arr_idx] == nil then
      return nil, "array index " .. idx .. " does not exist"
    end
    table.remove(parent, arr_idx)
  else
    if parent[final_key] == nil then
      return nil, "key '" .. tostring(final_key) .. "' does not exist"
    end
    parent[final_key] = nil
  end
  return true
end

--- Get a value at path in a mutable document (no copy).
--: (unknown, { [number]: string }) -> (unknown | nil, string | nil)
local function patch_get(doc, keys)
  if #keys == 0 then return doc end
  local node = doc
  for _, k in ipairs(keys) do
    if type(node) ~= "table" then
      return nil, "path not found: not a table"
    end
    local idx = tonumber(k)
    if idx then
      node = node[idx + 1]
    else
      node = node[k]
    end
    if node == nil then
      return nil, "path not found: key '" .. k .. "' does not exist"
    end
  end
  return node
end

-- ---------------------------------------------------------------------------
-- JSON Patch (RFC 6902)
-- ---------------------------------------------------------------------------

--- Apply a sequence of patch operations to doc.
--- Returns (new_doc, nil) on success or (nil, errmsg) on failure.
--: (unknown, { [number]: { [string]: unknown } }) -> (unknown | nil, string | nil)
M.apply = function(doc, ops)
  local target = M.deep_copy(doc)
  for i, op_entry in ipairs(ops) do
    local op = op_entry.op
    local path = op_entry.path
    local keys, err = M.pointer_parse(path or "")
    if not keys then
      return nil, "op #" .. i .. " (" .. tostring(op) .. "): bad path: " .. tostring(err)
    end

    if op == "add" then
      local ok, aerr = patch_add(target, keys, M.deep_copy(op_entry.value))
      if not ok then return nil, "op #" .. i .. " (add): " .. tostring(aerr) end

    elseif op == "remove" then
      local ok, rerr = patch_remove(target, keys)
      if not ok then return nil, "op #" .. i .. " (remove): " .. tostring(rerr) end

    elseif op == "replace" then
      -- replace: path must exist
      local cur, gerr = patch_get(target, keys)
      if cur == nil and gerr then
        return nil, "op #" .. i .. " (replace): " .. gerr
      end
      -- set the value
      if #keys == 0 then
        target = M.deep_copy(op_entry.value)
      else
        local parent, final_key, perr = resolve_parent(target, keys)
        if not parent then return nil, "op #" .. i .. " (replace): " .. tostring(perr) end
        local idx = tonumber(final_key)
        if idx then
          parent[idx + 1] = M.deep_copy(op_entry.value)
        else
          parent[final_key] = M.deep_copy(op_entry.value)
        end
      end

    elseif op == "move" then
      local from_keys, ferr = M.pointer_parse(op_entry.from or "")
      if not from_keys then
        return nil, "op #" .. i .. " (move): bad from: " .. tostring(ferr)
      end
      local val, gerr = patch_get(target, from_keys)
      if val == nil and gerr then
        return nil, "op #" .. i .. " (move): " .. gerr
      end
      local saved = M.deep_copy(val)
      local ok, rerr = patch_remove(target, from_keys)
      if not ok then return nil, "op #" .. i .. " (move): " .. tostring(rerr) end
      local ok2, aerr = patch_add(target, keys, saved)
      if not ok2 then return nil, "op #" .. i .. " (move): " .. tostring(aerr) end

    elseif op == "copy" then
      local from_keys, ferr = M.pointer_parse(op_entry.from or "")
      if not from_keys then
        return nil, "op #" .. i .. " (copy): bad from: " .. tostring(ferr)
      end
      local val, gerr = patch_get(target, from_keys)
      if val == nil and gerr then
        return nil, "op #" .. i .. " (copy): " .. gerr
      end
      local ok, aerr = patch_add(target, keys, M.deep_copy(val))
      if not ok then return nil, "op #" .. i .. " (copy): " .. tostring(aerr) end

    elseif op == "test" then
      local cur, gerr = patch_get(target, keys)
      if cur == nil and gerr then
        return nil, "op #" .. i .. " (test): " .. gerr
      end
      if not deep_eq(cur, op_entry.value) then
        return nil, "op #" .. i .. " (test): value mismatch at " .. tostring(path)
      end

    else
      return nil, "op #" .. i .. ": unknown operation '" .. tostring(op) .. "'"
    end
  end
  return target
end

-- ---------------------------------------------------------------------------
-- Diff
-- ---------------------------------------------------------------------------

--- Generate a JSON Patch (array of ops) that transforms doc_a into doc_b.
--- For objects: per-key add/remove/replace.
--- For arrays: if different, emit a single replace.
--- For primitives: emit replace if different.
--: (unknown, unknown, string) -> { [number]: { [string]: unknown } }
local function diff_recurse(a, b, base_path)
  local ops = {}
  if type(a) == "table" and type(b) == "table" then
    -- determine if both are arrays (sequential integer keys from 1)
    local a_is_array = (#a > 0)
    local b_is_array = (#b > 0)
    -- also check for non-integer keys
    for k in pairs(a) do
      if type(k) ~= "number" or k % 1 ~= 0 or k < 1 then a_is_array = false end
    end
    for k in pairs(b) do
      if type(k) ~= "number" or k % 1 ~= 0 or k < 1 then b_is_array = false end
    end

    if a_is_array and b_is_array then
      -- simple approach: if lengths differ or any element differs, replace whole array
      -- (a full LCS diff would be more minimal but much more complex)
      if not deep_eq(a, b) then
        ops[#ops + 1] = { op = "replace", path = base_path, value = M.deep_copy(b) }
      end
    else
      -- object diff: find removed, added, and changed keys
      -- removed keys (in a but not b)
      for k in pairs(a) do
        if b[k] == nil then
          local key_path = base_path .. "/" .. encode_token(tostring(k))
          ops[#ops + 1] = { op = "remove", path = key_path }
        end
      end
      -- added or changed keys
      for k, bv in pairs(b) do
        local key_path = base_path .. "/" .. encode_token(tostring(k))
        if a[k] == nil then
          ops[#ops + 1] = { op = "add", path = key_path, value = M.deep_copy(bv) }
        elseif not deep_eq(a[k], bv) then
          -- recurse for nested objects
          local sub = diff_recurse(a[k], bv, key_path)
          for _, sop in ipairs(sub) do
            ops[#ops + 1] = sop
          end
        end
      end
    end
  else
    if not deep_eq(a, b) then
      if base_path == "" then
        -- replacing root primitive — use add at root... but RFC says replace
        ops[#ops + 1] = { op = "replace", path = base_path, value = M.deep_copy(b) }
      else
        ops[#ops + 1] = { op = "replace", path = base_path, value = M.deep_copy(b) }
      end
    end
  end
  return ops
end

--- Generate a JSON Patch that transforms doc_a into doc_b.
--: (unknown, unknown) -> { [number]: { [string]: unknown } }
M.diff = function(doc_a, doc_b)
  return diff_recurse(doc_a, doc_b, "")
end

return M
