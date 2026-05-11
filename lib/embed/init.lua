if not package.path:find("./?/init.lua", 1, true) then package.path = "./?/init.lua;" .. package.path end

local vec = require("lib.vec")

local M = {}

--:: Vec = { data?: unknown, n: integer, [integer]: number }
--:: Metadata = { [string]: unknown }
--:: Entry = { id: string, vector: Vec, metadata: (Metadata | nil) }
--:: SearchResult = { id: string, score: number, metadata: (Metadata | nil) }
--:: SerializedItem = { id: string, vector: { number }, metadata: (Metadata | nil) }
--:: Serialized = { dims: integer, metric: string, items: { SerializedItem } }
--:: Index = { _dims: integer, _metric: string, _entries: { [string]: unknown }, _ids: { [integer]: string }, _id_set: { [string]: integer } }

local idx_mt = {}
idx_mt.__index = idx_mt

--: (opts: { dims: number, metric: (string | nil) }) -> (Index | nil, string | nil)
function M.index(opts)
  local dims = opts.dims
  if not dims or dims < 1 then
    return nil, "dims must be a positive integer"
  end
  local metric = opts.metric or "cosine"
  if metric ~= "cosine" and metric ~= "euclidean" and metric ~= "dot" then
    return nil, "metric must be 'cosine', 'euclidean', or 'dot'"
  end
  local result = setmetatable({
    _dims = dims,
    _metric = metric,
    _entries = {},  -- id -> { id, vector, metadata }
    _ids = {},      -- ordered list of ids for iteration
    _id_set = {},   -- id -> index in _ids
  }, idx_mt) --[[: unknown]]
  return result --[[:! Index]]
end

--: (self: Index, id: string, vector: Vec, metadata: (Metadata | nil)) -> (boolean | nil, string | nil)
function idx_mt:add(id, vector, metadata)
  if vec.len(vector) ~= self._dims then
    return nil, "vector dimension mismatch: expected " .. self._dims .. ", got " .. vec.len(vector)
  end
  local existing = self._id_set[id]
  if existing then
    -- overwrite: replace entry, keep position in _ids
    self._entries[id] = { id = id, vector = vector, metadata = metadata }
  else
    self._entries[id] = { id = id, vector = vector, metadata = metadata }
    local n = #self._ids + 1
    self._ids[n] = id
    self._id_set[id] = n
  end
  return true
end

--: (self: Index, items: { Entry }) -> (boolean | nil, string | nil)
function idx_mt:add_batch(items)
  local self_ = (self --[[:! { add: (unknown, unknown, unknown, unknown) -> (unknown, string | nil) }]])
  for i = 1, #items do
    local item = items[i]
    local ok, err = self_:add(item.id, item.vector, item.metadata)
    if not ok then
      return nil, "item " .. i .. ": " .. (err or "")
    end
  end
  return true
end

--: (self: Index, query: Vec, k: number, opts: ({ filter: (((meta: (Metadata | nil)) -> boolean) | nil) } | nil)) -> ({ [integer]: SearchResult } | nil, string | nil)
function idx_mt:search(query, k, opts)
  if vec.len(query) ~= self._dims then
    return nil, "query dimension mismatch: expected " .. self._dims .. ", got " .. vec.len(query)
  end
  local filter = opts and opts.filter
  local metric = self._metric
  local score_fn --: ((Vec, Vec) -> number) | nil
  if metric == "cosine" then
    score_fn = vec.cosine
  elseif metric == "dot" then
    score_fn = vec.dot
  else
    -- euclidean: negate distance so higher = better for sorting
    score_fn = function(a, b) return -vec.distance(a, b) end
  end
  local score_fn_ = score_fn --[[:! (Vec, Vec) -> number]]

  -- Collect candidates
  local candidates = {}
  local n = 0
  local entries = self._entries
  local ids = self._ids
  for i = 1, #ids do
    local entry = entries[ids[i]]
    if not filter or (filter --[[:! (unknown) -> boolean]])(entry.metadata) then
      local s = score_fn_(query, entry.vector)
      n = n + 1
      candidates[n] = { id = entry.id, score = s, metadata = entry.metadata }
    end
  end

  -- Sort descending by score (higher = more similar)
  table.sort(candidates, function(a, b) return a.score > b.score end)

  -- Return top-k
  local results = {}
  local count = k < n and k or n
  for i = 1, count do
    results[i] = candidates[i]
  end
  return results
end

--: (self: Index, id: string) -> (Entry | nil)
function idx_mt:get(id)
  local entry = self._entries[id]
  if not entry then return nil end
  return { id = entry.id, vector = entry.vector, metadata = entry.metadata }
end

--: (self: Index, id: string) -> boolean
function idx_mt:remove(id)
  if not self._entries[id] then return false end
  self._entries[id] = nil
  local pos = self._id_set[id]
  self._id_set[id] = nil
  -- Remove from _ids by shifting
  local ids = self._ids
  local total = #ids
  for i = pos, total - 1 do
    ids[i] = ids[i + 1]
    self._id_set[ids[i]] = i
  end
  ids[total] = nil
  return true
end

--: (self: Index) -> number
function idx_mt:count()
  return #self._ids
end

--: (self: Index) -> { string }
function idx_mt:ids()
  local result = {}
  local ids = self._ids
  for i = 1, #ids do
    result[i] = ids[i]
  end
  return result
end

--: (self: Index) -> Serialized
function idx_mt:serialize()
  local items = {}
  local ids = self._ids
  for i = 1, #ids do
    local entry = self._entries[ids[i]]
    items[i] = {
      id = entry.id,
      vector = vec.to_table(entry.vector),
      metadata = entry.metadata,
    }
  end
  return {
    dims = self._dims,
    metric = self._metric,
    items = items,
  }
end

--: (data: Serialized) -> (Index | nil, string | nil)
function M.deserialize(data)
  if not data.dims then return nil, "missing dims" end
  local idx, err = M.index({ dims = data.dims, metric = data.metric or "cosine" })
  if not idx then return nil, err end
  local idx_ = (idx --[[:! { add: (unknown, unknown, unknown, unknown) -> (unknown, string | nil) }]])
  local items = data.items
  if items then
    for i = 1, #items do
      local item = items[i]
      local v = vec.new(item.vector)
      local ok, add_err = idx_:add(item.id, v, item.metadata)
      if not ok then return nil, add_err end
    end
  end
  return idx
end

return M
