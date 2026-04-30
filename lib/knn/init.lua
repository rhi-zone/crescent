if not package.path:find("./?/init.lua", 1, true) then package.path = "./?/init.lua;" .. package.path end

local vec = require("lib.vec")

local M = {}

--:: Vec = { data: unknown, n: integer }
--:: KnnIndex = { _k: integer, _dist: (Vec, Vec) -> number, _points: { [integer]: unknown }, _n: integer, _dims: integer | nil }

local index_mt = {}
index_mt.__index = index_mt

--: (a: Vec, b: Vec) -> number
local function dist_euclidean(a, b)
  return vec.distance(a, b)
end

--: (a: Vec, b: Vec) -> number
local function dist_cosine(a, b)
  return 1 - vec.cosine(a, b)
end

--: (a: Vec, b: Vec) -> number
local function dist_manhattan(a, b)
  return vec.norm1(vec.sub(a, b))
end

local builtin_distances = {
  euclidean = dist_euclidean,
  cosine = dist_cosine,
  manhattan = dist_manhattan,
}

--: (opts: ({ k: (number | nil), distance: string | (Vec, Vec) -> (number | nil) } | nil)) -> KnnIndex
function M.new(opts)
  opts = opts or {}
  local k = opts.k or 5
  local dist = opts.distance or "euclidean"
  if type(dist) == "string" then
    local fn = builtin_distances[dist]
    if not fn then
      return nil, "unknown distance function: " .. dist
    end
    dist = fn
  end
  return setmetatable({
    _k = k,
    _dist = dist,
    _points = {},   -- array of {label, vector}
    _n = 0,
    _dims = nil,
  }, index_mt)
end

--: (self: KnnIndex, label: unknown, vector: {[number]: number}) -> ()
function index_mt:add(label, vector)
  local v = vec.new(vector)
  local dims = vec.len(v)
  if not self._dims then
    self._dims = dims
  end
  self._n = self._n + 1
  self._points[self._n] = { label = label, vector = v }
end

--: (self: KnnIndex, batch: {{unknown, {[number]: number}}}) -> ()
function index_mt:add_batch(batch)
  for i = 1, #batch do
    local item = batch[i]
    self:add(item[1], item[2])
  end
end

--: (self: KnnIndex, label: unknown) -> boolean
function index_mt:remove(label)
  local points = self._points
  local n = self._n
  for i = 1, n do
    if points[i].label == label then
      -- shift down
      for j = i, n - 1 do
        points[j] = points[j + 1]
      end
      points[n] = nil
      self._n = n - 1
      return true
    end
  end
  return false
end

--: (self: KnnIndex) -> number
function index_mt:size()
  return self._n
end

--: (self: KnnIndex) -> {string}
function index_mt:labels()
  local result = {}
  local points = self._points
  for i = 1, self._n do
    result[i] = points[i].label
  end
  return result
end

--: (self: KnnIndex) -> (number | nil)
function index_mt:dimensions()
  return self._dims
end

--: (self: KnnIndex, target: {[number]: number}, opts: ({ k: (number | nil) } | nil)) -> {{label: unknown, distance: number}}
function index_mt:query(target, opts)
  local k = (opts and opts.k) or self._k
  local tv = vec.new(target)
  local dist_fn = self._dist
  local points = self._points
  local n = self._n

  if n == 0 then return {} end

  -- Build top-k via insertion into sorted array
  local result = {}
  local rn = 0
  for i = 1, n do
    local p = points[i]
    local d = dist_fn(tv, p.vector)
    if rn < k then
      -- Insert in sorted position
      local pos = rn + 1
      for j = 1, rn do
        if d < result[j].distance then
          pos = j
          break
        end
      end
      -- Shift right
      for j = rn, pos, -1 do
        result[j + 1] = result[j]
      end
      result[pos] = { label = p.label, distance = d }
      rn = rn + 1
    elseif d < result[rn].distance then
      -- Replace farthest, insert in sorted position
      local pos = rn
      for j = 1, rn - 1 do
        if d < result[j].distance then
          pos = j
          break
        end
      end
      -- Shift right from pos to rn-1
      for j = rn - 1, pos, -1 do
        result[j + 1] = result[j]
      end
      result[pos] = { label = p.label, distance = d }
    end
  end

  return result
end

--: (self: KnnIndex, target: {[number]: number}, opts: ({ k: (number | nil), weighted: (boolean | nil) } | nil)) -> (unknown, {[unknown]: number})
function index_mt:classify(target, opts)
  local weighted = opts and opts.weighted
  local neighbors = self:query(target, opts)

  local scores = {}
  for i = 1, #neighbors do
    local nb = neighbors[i]
    local label = nb.label
    local w
    if weighted then
      if nb.distance == 0 then
        return label, { [label] = 1 / 0 }
      end
      w = 1 / nb.distance
    else
      w = 1
    end
    scores[label] = (scores[label] or 0) + w
  end

  -- Find majority
  local best_label, best_score = nil, -1
  for label, score in pairs(scores) do
    if score > best_score then
      best_label = label
      best_score = score
    end
  end

  return best_label, scores
end

--: (self: KnnIndex, target: {[number]: number}, opts: ({ k: (number | nil), weighted: (boolean | nil) } | nil)) -> number
function index_mt:regress(target, opts)
  local weighted = opts and opts.weighted
  local neighbors = self:query(target, opts)

  if #neighbors == 0 then
    return nil, "no neighbors found"
  end

  if weighted then
    local wsum = 0
    local vsum = 0
    for i = 1, #neighbors do
      local nb = neighbors[i]
      if nb.distance == 0 then
        return nb.label
      end
      local w = 1 / nb.distance
      wsum = wsum + w
      vsum = vsum + nb.label * w
    end
    return vsum / wsum
  else
    local sum = 0
    for i = 1, #neighbors do
      sum = sum + neighbors[i].label
    end
    return sum / #neighbors
  end
end

return M
