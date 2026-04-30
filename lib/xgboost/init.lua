if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

--:: Model = { ... }

-- ── LCG random number generator ─────────────────────────────────────────────

local RNG = {}
RNG.__index = RNG

local function rng_new(seed)
  return setmetatable({ state = seed or 42 }, RNG)
end

function RNG:next_int()
  -- LCG parameters (Numerical Recipes)
  self.state = (self.state * 1664525 + 1013904223) % 4294967296
  return self.state
end

function RNG:float()
  return self:next_int() / 4294967296
end

-- Fisher-Yates shuffle, return first k elements as indices
local function sample_indices(rng, n, k)
  local idx = {}
  for i = 1, n do idx[i] = i end
  for i = 1, k do
    local j = i + math.floor(rng:float() * (n - i + 1))
    idx[i], idx[j] = idx[j], idx[i]
  end
  local result = {}
  for i = 1, k do result[i] = idx[i] end
  return result
end

-- ── Sigmoid ─────────────────────────────────────────────────────────────────

local function sigmoid(x)
  if x >= 0 then
    local ez = math.exp(-x)
    return 1 / (1 + ez)
  else
    local ez = math.exp(x)
    return ez / (1 + ez)
  end
end

-- ── Tree building ───────────────────────────────────────────────────────────

--: { feature: (number | nil), threshold: (number | nil), left: (any | nil), right: (any | nil), value: (number | nil), gain: (number | nil) }

local function make_leaf(indices, grads, hessians, lambda)
  local G, H = 0, 0
  for i = 1, #indices do
    local idx = indices[i]
    G = G + grads[idx]
    H = H + hessians[idx]
  end
  return { value = -G / (H + lambda) }
end

local function find_best_split(X, indices, grads, hessians, feature_subset, lambda, gamma, min_samples_leaf)
  local n = #indices
  local best_gain = 0
  local best_feature, best_threshold
  local best_left, best_right

  -- total G, H for this node
  local G_total, H_total = 0, 0
  for i = 1, n do
    local idx = indices[i]
    G_total = G_total + grads[idx]
    H_total = H_total + hessians[idx]
  end

  for _, feat in ipairs(feature_subset) do
    -- sort indices by feature value
    local sorted = {}
    for i = 1, n do sorted[i] = indices[i] end
    table.sort(sorted, function(a, b) return X[a][feat] < X[b][feat] end)

    local G_L, H_L = 0, 0
    for i = 1, n - 1 do
      local idx = sorted[i]
      G_L = G_L + grads[idx]
      H_L = H_L + hessians[idx]
      local G_R = G_total - G_L
      local H_R = H_total - H_L

      -- skip if same feature value as next (no valid split point)
      if X[sorted[i]][feat] < X[sorted[i + 1]][feat] then
        -- check min_samples_leaf
        if i >= min_samples_leaf and (n - i) >= min_samples_leaf then
          local gain = 0.5 * (
            G_L * G_L / (H_L + lambda)
            + G_R * G_R / (H_R + lambda)
            - G_total * G_total / (H_total + lambda)
          ) - gamma

          if gain > best_gain then
            best_gain = gain
            best_feature = feat
            best_threshold = (X[sorted[i]][feat] + X[sorted[i + 1]][feat]) / 2
            -- split indices
            best_left = {}
            best_right = {}
            for j = 1, i do best_left[#best_left + 1] = sorted[j] end
            for j = i + 1, n do best_right[#best_right + 1] = sorted[j] end
          end
        end
      end
    end
  end

  if best_feature then
    return best_gain, best_feature, best_threshold, best_left, best_right
  end
  return nil
end

local function build_tree(X, indices, grads, hessians, feature_subset, opts, depth)
  local n = #indices
  local lambda = opts.lambda
  local gamma = opts.gamma
  local max_depth = opts.max_depth
  local min_samples_split = opts.min_samples_split
  local min_samples_leaf = opts.min_samples_leaf

  -- leaf conditions
  if n < min_samples_split or depth >= max_depth then
    return make_leaf(indices, grads, hessians, lambda)
  end

  local gain, feat, thresh, left_idx, right_idx =
    find_best_split(X, indices, grads, hessians, feature_subset, lambda, gamma, min_samples_leaf)

  if not gain then
    return make_leaf(indices, grads, hessians, lambda)
  end

  local left = build_tree(X, left_idx, grads, hessians, feature_subset, opts, depth + 1)
  local right = build_tree(X, right_idx, grads, hessians, feature_subset, opts, depth + 1)

  return {
    feature = feat,
    threshold = thresh,
    left = left,
    right = right,
    gain = gain,
  }
end

-- ── Tree prediction ─────────────────────────────────────────────────────────

local function tree_predict_one(tree, x)
  if tree.value then return tree.value end
  if x[tree.feature] < tree.threshold then
    return tree_predict_one(tree.left, x)
  else
    return tree_predict_one(tree.right, x)
  end
end

-- ── Model ───────────────────────────────────────────────────────────────────

local Model = {}
Model.__index = Model

function Model:predict_one(x)
  local raw = self.base_prediction
  for i = 1, #self.trees do
    raw = raw + self.learning_rate * tree_predict_one(self.trees[i], x)
  end
  if self.objective == "logistic" then
    return sigmoid(raw)
  end
  return raw
end

function Model:predict(X)
  local preds = {}
  for i = 1, #X do
    preds[i] = self:predict_one(X[i])
  end
  return preds
end

function Model:predict_class(X, opts)
  local threshold = (opts and opts.threshold) or 0.5
  local preds = self:predict(X)
  local labels = {}
  for i = 1, #preds do
    labels[i] = preds[i] >= threshold and 1 or 0
  end
  return labels
end

function Model:feature_importance()
  local importance = {}
  local function walk(node)
    if not node or node.value then return end
    local feat = node.feature
    importance[feat] = (importance[feat] or 0) + (node.gain or 0)
    walk(node.left)
    walk(node.right)
  end
  for _, tree in ipairs(self.trees) do
    walk(tree)
  end
  return importance
end

-- ── Serialization ───────────────────────────────────────────────────────────

local function tree_to_table(node)
  if not node then return nil end
  if node.value then
    return { value = node.value }
  end
  return {
    feature = node.feature,
    threshold = node.threshold,
    gain = node.gain,
    left = tree_to_table(node.left),
    right = tree_to_table(node.right),
  }
end

local function tree_from_table(t)
  if not t then return nil end
  if t.value then
    return { value = t.value }
  end
  return {
    feature = t.feature,
    threshold = t.threshold,
    gain = t.gain,
    left = tree_from_table(t.left),
    right = tree_from_table(t.right),
  }
end

function Model:to_table()
  local trees = {}
  for i = 1, #self.trees do
    trees[i] = tree_to_table(self.trees[i])
  end
  return {
    trees = trees,
    n_estimators = self.n_estimators,
    learning_rate = self.learning_rate,
    objective = self.objective,
    base_prediction = self.base_prediction,
  }
end

function M.from_table(t)
  local trees = {}
  for i = 1, #t.trees do
    trees[i] = tree_from_table(t.trees[i])
  end
  return setmetatable({
    trees = trees,
    n_estimators = t.n_estimators,
    learning_rate = t.learning_rate,
    objective = t.objective,
    base_prediction = t.base_prediction,
  }, Model)
end

-- ── Training ────────────────────────────────────────────────────────────────

--: (X: number[][], y: number[], opts: (table | nil)) -> Model
function M.train(X, y, opts)
  opts = opts or {}
  local n_estimators = opts.n_estimators or 100
  local max_depth = opts.max_depth or 6
  local learning_rate = opts.learning_rate or 0.3
  local min_samples_split = opts.min_samples_split or 2
  local min_samples_leaf = opts.min_samples_leaf or 1
  local subsample = opts.subsample or 1.0
  local colsample = opts.colsample or 1.0
  local lambda = opts.lambda or 1.0
  local gamma = opts.gamma or 0.0
  local objective = opts.objective or "mse"
  local seed = opts.seed or 42

  local n = #X
  if n == 0 then
    return setmetatable({
      trees = {},
      n_estimators = 0,
      learning_rate = learning_rate,
      objective = objective,
      base_prediction = 0,
    }, Model)
  end

  local n_features = #X[1]
  local rng = rng_new(seed)

  -- tree building options
  local tree_opts = {
    max_depth = max_depth,
    min_samples_split = min_samples_split,
    min_samples_leaf = min_samples_leaf,
    lambda = lambda,
    gamma = gamma,
  }

  -- base prediction
  local base_prediction = 0
  if objective == "mse" then
    local sum = 0
    for i = 1, n do sum = sum + y[i] end
    base_prediction = sum / n
  end
  -- for logistic, start at 0 (log-odds of 0.5)

  -- current raw predictions
  local preds = {}
  for i = 1, n do preds[i] = base_prediction end

  local grads = {}
  local hessians = {}
  local trees = {}

  for round = 1, n_estimators do
    -- compute gradients and hessians
    if objective == "mse" then
      for i = 1, n do
        grads[i] = preds[i] - y[i]
        hessians[i] = 1.0
      end
    elseif objective == "logistic" then
      for i = 1, n do
        local p = sigmoid(preds[i])
        grads[i] = p - y[i]
        hessians[i] = p * (1 - p)
      end
    end

    -- row subsampling
    local row_indices
    if subsample < 1.0 then
      local k = math.max(1, math.floor(n * subsample))
      row_indices = sample_indices(rng, n, k)
    else
      row_indices = {}
      for i = 1, n do row_indices[i] = i end
    end

    -- column subsampling
    local feature_subset
    if colsample < 1.0 then
      local k = math.max(1, math.floor(n_features * colsample))
      feature_subset = sample_indices(rng, n_features, k)
      table.sort(feature_subset)
    else
      feature_subset = {}
      for i = 1, n_features do feature_subset[i] = i end
    end

    -- build tree
    local tree = build_tree(X, row_indices, grads, hessians, feature_subset, tree_opts, 0)
    trees[round] = tree

    -- update predictions
    for _, idx in ipairs(row_indices) do
      preds[idx] = preds[idx] + learning_rate * tree_predict_one(tree, X[idx])
    end
    -- also update non-sampled rows if subsampling
    if subsample < 1.0 then
      local sampled = {}
      for _, idx in ipairs(row_indices) do sampled[idx] = true end
      for i = 1, n do
        if not sampled[i] then
          preds[i] = preds[i] + learning_rate * tree_predict_one(tree, X[i])
        end
      end
    end
  end

  return setmetatable({
    trees = trees,
    n_estimators = n_estimators,
    learning_rate = learning_rate,
    objective = objective,
    base_prediction = base_prediction,
  }, Model)
end

return M
