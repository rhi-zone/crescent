if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

M._tier = "pure"

-- Math helpers

local function log2(x)
  return math.log(x) / math.log(2)
end

-- Count label occurrences in a dataset
local function count_labels(dataset)
  local counts = {}
  for _, ex in ipairs(dataset) do
    local lbl = ex.label
    counts[lbl] = (counts[lbl] or 0) + 1
  end
  return counts
end

-- Return the majority label (ties broken by first encountered)
local function majority_label(dataset)
  local counts = count_labels(dataset)
  local best_lbl, best_cnt = nil, -1
  for lbl, cnt in pairs(counts) do
    if cnt > best_cnt then
      best_lbl = lbl
      best_cnt = cnt
    end
  end
  return best_lbl
end

-- Compute entropy of a dataset
local function entropy(dataset)
  local n = #dataset
  if n == 0 then return 0 end
  local counts = count_labels(dataset)
  local h = 0
  for _, cnt in pairs(counts) do
    local p = cnt / n
    h = h - p * log2(p)
  end
  return h
end

-- Split dataset by feature value
local function split_by_feature(dataset, feature)
  local splits = {}  -- value -> subset
  for _, ex in ipairs(dataset) do
    local v = ex[feature]
    if v == nil then v = "__nil__" end
    if not splits[v] then splits[v] = {} end
    local sub = splits[v]
    sub[#sub + 1] = ex
  end
  return splits
end

-- Information gain for a feature
local function information_gain(dataset, feature)
  local n = #dataset
  local h = entropy(dataset)
  local splits = split_by_feature(dataset, feature)
  local cond_h = 0
  for _, subset in pairs(splits) do
    cond_h = cond_h + (#subset / n) * entropy(subset)
  end
  return h - cond_h, splits
end

-- Gain ratio for C4.5
local function gain_ratio(dataset, feature)
  local n = #dataset
  local ig, splits = information_gain(dataset, feature)
  -- Split info
  local si = 0
  for _, subset in pairs(splits) do
    local p = #subset / n
    if p > 0 then
      si = si - p * log2(p)
    end
  end
  if si == 0 then return 0, splits end
  return ig / si, splits
end

-- Get all distinct values for each feature across the dataset
local function get_feature_values(dataset, features)
  local vals = {}
  for _, f in ipairs(features) do vals[f] = {} end
  for _, ex in ipairs(dataset) do
    for _, f in ipairs(features) do
      local v = ex[f]
      if v == nil then v = "__nil__" end
      vals[f][v] = true
    end
  end
  return vals
end

-- Collect all feature names from dataset (excluding "label")
local function get_all_features(dataset)
  local seen = {}
  local features = {}
  for _, ex in ipairs(dataset) do
    for k in pairs(ex) do
      if k ~= "label" and not seen[k] then
        seen[k] = true
        features[#features + 1] = k
      end
    end
  end
  table.sort(features)
  return features
end

-- Build a tree node recursively
-- node = {type="leaf", label=..., counts=..., total=...}
--      | {type="branch", feature=..., children={value->node}, default_label=..., counts=..., total=...}
local function build_tree(dataset, features, depth, max_depth, min_samples, algorithm)
  local n = #dataset
  local counts = count_labels(dataset)
  local total = n

  -- All same label?
  local only_label = nil
  local num_labels = 0
  for lbl in pairs(counts) do
    num_labels = num_labels + 1
    only_label = lbl
  end

  if num_labels == 1 then
    return {type="leaf", label=only_label, counts=counts, total=total}
  end

  -- Too few samples or no features or max_depth reached?
  if n < (min_samples or 1) or #features == 0 or (max_depth and depth >= max_depth) then
    return {type="leaf", label=majority_label(dataset), counts=counts, total=total}
  end

  -- Choose best feature
  local best_feature, best_score, best_splits = nil, -math.huge, nil
  for _, f in ipairs(features) do
    local score, splits
    if algorithm == "c45" then
      score, splits = gain_ratio(dataset, f)
    else
      score, splits = information_gain(dataset, f)
    end
    if score > best_score then
      best_score = score
      best_feature = f
      best_splits = splits
    end
  end

  -- No improvement possible (all features constant)
  if best_feature == nil or best_score <= 0 then
    return {type="leaf", label=majority_label(dataset), counts=counts, total=total}
  end

  -- Build remaining features (remove chosen one)
  local remaining = {}
  for _, f in ipairs(features) do
    if f ~= best_feature then
      remaining[#remaining + 1] = f
    end
  end

  local children = {}
  for val, subset in pairs(best_splits) do
    children[val] = build_tree(subset, remaining, depth + 1, max_depth, min_samples, algorithm)
  end

  return {
    type = "branch",
    feature = best_feature,
    children = children,
    default_label = majority_label(dataset),
    counts = counts,
    total = total,
  }
end

-- Traverse the tree to predict a label
local function traverse(node, example)
  if node.type == "leaf" then
    return node.label
  end
  local v = example[node.feature]
  if v == nil then v = "__nil__" end
  local child = node.children[v]
  if not child then
    return node.default_label
  end
  return traverse(child, example)
end

-- Traverse to get probability distribution
local function traverse_proba(node, example)
  if node.type == "leaf" then
    -- Return counts as proba
    local proba = {}
    local total = node.total
    if total == 0 then return proba end
    for lbl, cnt in pairs(node.counts) do
      proba[lbl] = cnt / total
    end
    return proba
  end
  local v = example[node.feature]
  if v == nil then v = "__nil__" end
  local child = node.children[v]
  if not child then
    -- Return distribution from this node
    local proba = {}
    local total = node.total
    if total == 0 then return proba end
    for lbl, cnt in pairs(node.counts) do
      proba[lbl] = cnt / total
    end
    return proba
  end
  return traverse_proba(child, example)
end

-- Compute max depth of a tree
local function tree_depth(node)
  if node.type == "leaf" then return 0 end
  local max_d = 0
  for _, child in pairs(node.children) do
    local d = tree_depth(child)
    if d > max_d then max_d = d end
  end
  return 1 + max_d
end

-- Count total nodes
local function tree_node_count(node)
  if node.type == "leaf" then return 1 end
  local cnt = 1
  for _, child in pairs(node.children) do
    cnt = cnt + tree_node_count(child)
  end
  return cnt
end

-- Feature importance: sum of weighted information gain at each split
-- importance[feature] += (node.total / root.total) * IG contributed
local function collect_importance(node, root_total, importance)
  if node.type == "leaf" then return end
  local f = node.feature
  -- Compute IG at this node
  -- We already know the feature; approximate contribution as weighted entropy reduction
  local h_parent = 0
  for _, cnt in pairs(node.counts) do
    local p = cnt / node.total
    h_parent = h_parent - p * log2(p)
  end
  local h_children = 0
  for _, child in pairs(node.children) do
    local p_child = child.total / node.total
    local h_child = 0
    for _, cnt in pairs(child.counts) do
      local p = cnt / child.total
      h_child = h_child - p * log2(p)
    end
    h_children = h_children + p_child * h_child
  end
  local ig = h_parent - h_children
  local weight = node.total / root_total
  importance[f] = (importance[f] or 0) + weight * ig

  for _, child in pairs(node.children) do
    collect_importance(child, root_total, importance)
  end
end

-- Normalize a table of scores to sum to 1
local function normalize_scores(t)
  local total = 0
  for _, v in pairs(t) do total = total + v end
  if total == 0 then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = v / total end
  return out
end

-- Convert tree to if-then rules (depth-first, collect path)
local function collect_rules(node, path, rules)
  if node.type == "leaf" then
    local conds = {}
    for _, cond in ipairs(path) do
      conds[#conds + 1] = cond
    end
    local rule
    if #conds == 0 then
      rule = "IF TRUE THEN " .. tostring(node.label)
    else
      rule = "IF " .. table.concat(conds, " AND ") .. " THEN " .. tostring(node.label)
    end
    rules[#rules + 1] = rule
    return
  end
  -- Sort values for deterministic output
  local vals = {}
  for v in pairs(node.children) do vals[#vals + 1] = v end
  table.sort(vals)
  for _, v in ipairs(vals) do
    local display_v = v == "__nil__" and "nil" or tostring(v)
    path[#path + 1] = node.feature .. "=" .. display_v
    collect_rules(node.children[v], path, rules)
    path[#path] = nil
  end
end

-- Print tree as string
local function tree_to_string(node, indent, lines)
  indent = indent or 0
  lines = lines or {}
  local prefix = string.rep("  ", indent)
  if node.type == "leaf" then
    lines[#lines + 1] = prefix .. "[" .. tostring(node.label) .. "] (" .. node.total .. " samples)"
  else
    lines[#lines + 1] = prefix .. node.feature .. ":"
    local vals = {}
    for v in pairs(node.children) do vals[#vals + 1] = v end
    table.sort(vals)
    for _, v in ipairs(vals) do
      local display_v = v == "__nil__" and "nil" or tostring(v)
      lines[#lines + 1] = prefix .. "  " .. display_v .. " ->"
      tree_to_string(node.children[v], indent + 2, lines)
    end
  end
  return table.concat(lines, "\n")
end

-- Serialize tree to plain Lua table (recursive)
local function serialize_node(node)
  if node.type == "leaf" then
    local counts = {}
    for k, v in pairs(node.counts) do counts[k] = v end
    return {type="leaf", label=node.label, counts=counts, total=node.total}
  end
  local children = {}
  for v, child in pairs(node.children) do
    children[v] = serialize_node(child)
  end
  local counts = {}
  for k, v in pairs(node.counts) do counts[k] = v end
  return {
    type = "branch",
    feature = node.feature,
    children = children,
    default_label = node.default_label,
    counts = counts,
    total = node.total,
  }
end

-- Deserialize from plain Lua table
local function deserialize_node(t)
  if t.type == "leaf" then
    return {type="leaf", label=t.label, counts=t.counts, total=t.total}
  end
  local children = {}
  for v, child in pairs(t.children) do
    children[v] = deserialize_node(child)
  end
  return {
    type = "branch",
    feature = t.feature,
    children = children,
    default_label = t.default_label,
    counts = t.counts,
    total = t.total,
  }
end

-- Reduced-error pruning (recursive)
-- Returns new node; prunes if replacing subtree with leaf improves/maintains val accuracy
local function prune_node(node, val_dataset)
  if node.type == "leaf" then return node end

  -- Prune children first
  local pruned_children = {}
  for v, child in pairs(node.children) do
    -- Get subset of val_dataset reaching this child
    local subset = {}
    for _, ex in ipairs(val_dataset) do
      local ev = ex[node.feature]
      if ev == nil then ev = "__nil__" end
      if ev == v then subset[#subset + 1] = ex end
    end
    pruned_children[v] = prune_node(child, subset)
  end

  -- Build pruned branch node
  local pruned = {
    type = "branch",
    feature = node.feature,
    children = pruned_children,
    default_label = node.default_label,
    counts = node.counts,
    total = node.total,
  }

  -- Count correct predictions with current subtree
  local correct_tree = 0
  for _, ex in ipairs(val_dataset) do
    if traverse(pruned, ex) == ex.label then
      correct_tree = correct_tree + 1
    end
  end

  -- Count correct predictions with leaf replacement
  local leaf_label = majority_label(val_dataset) or node.default_label
  local correct_leaf = 0
  for _, ex in ipairs(val_dataset) do
    if leaf_label == ex.label then
      correct_leaf = correct_leaf + 1
    end
  end

  -- Replace with leaf if leaf is at least as good
  if correct_leaf >= correct_tree then
    local counts = count_labels(val_dataset)
    return {type="leaf", label=leaf_label, counts=counts, total=#val_dataset}
  end
  return pruned
end

-- Tree object methods

local Tree = {}
Tree.__index = Tree

function Tree:predict(example)
  return traverse(self._root, example)
end

function Tree:predict_proba(example)
  return traverse_proba(self._root, example)
end

function Tree:predict_all(examples)
  local results = {}
  for i, ex in ipairs(examples) do
    results[i] = traverse(self._root, ex)
  end
  return results
end

function Tree:accuracy(test_dataset)
  local correct = 0
  local total = #test_dataset
  if total == 0 then return 1.0 end
  for _, ex in ipairs(test_dataset) do
    if traverse(self._root, ex) == ex.label then
      correct = correct + 1
    end
  end
  return correct / total
end

function Tree:depth()
  return tree_depth(self._root)
end

function Tree:node_count()
  return tree_node_count(self._root)
end

function Tree:feature_importance()
  local importance = {}
  collect_importance(self._root, self._root.total, importance)
  return normalize_scores(importance)
end

function Tree:print()
  return tree_to_string(self._root)
end

function Tree:to_rules()
  local rules = {}
  collect_rules(self._root, {}, rules)
  return rules
end

function Tree:serialize()
  return serialize_node(self._root)
end

-- Main train function

function M.train(dataset, opts)
  opts = opts or {}
  local algorithm = opts.algorithm or "id3"
  local max_depth = opts.max_depth
  local min_samples = opts.min_samples or 1
  local features = opts.features

  if not features then
    features = get_all_features(dataset)
  end

  local root = build_tree(dataset, features, 0, max_depth, min_samples, algorithm)
  local tree = setmetatable({_root = root}, Tree)
  return tree
end

function M.deserialize(t)
  local root = deserialize_node(t)
  return setmetatable({_root = root}, Tree)
end

function M.prune(tree, val_dataset)
  local new_root = prune_node(tree._root, val_dataset)
  return setmetatable({_root = new_root}, Tree)
end

-- Random Forest

local Forest = {}
Forest.__index = Forest

function Forest:predict(example)
  local votes = {}
  for _, tree in ipairs(self._trees) do
    local lbl = tree:predict(example)
    votes[lbl] = (votes[lbl] or 0) + 1
  end
  local best_lbl, best_cnt = nil, -1
  for lbl, cnt in pairs(votes) do
    if cnt > best_cnt then
      best_lbl = lbl
      best_cnt = cnt
    end
  end
  return best_lbl
end

function Forest:predict_proba(example)
  local sum_proba = {}
  local n = #self._trees
  for _, tree in ipairs(self._trees) do
    local proba = tree:predict_proba(example)
    for lbl, p in pairs(proba) do
      sum_proba[lbl] = (sum_proba[lbl] or 0) + p
    end
  end
  local avg = {}
  for lbl, total in pairs(sum_proba) do
    avg[lbl] = total / n
  end
  return avg
end

function Forest:accuracy(test_dataset)
  local correct = 0
  local total = #test_dataset
  if total == 0 then return 1.0 end
  for _, ex in ipairs(test_dataset) do
    if self:predict(ex) == ex.label then
      correct = correct + 1
    end
  end
  return correct / total
end

function Forest:feature_importance()
  local sum_importance = {}
  local n = #self._trees
  for _, tree in ipairs(self._trees) do
    local imp = tree:feature_importance()
    for f, score in pairs(imp) do
      sum_importance[f] = (sum_importance[f] or 0) + score
    end
  end
  local avg = {}
  for f, total in pairs(sum_importance) do
    avg[f] = total / n
  end
  return normalize_scores(avg)
end

-- Simple LCG RNG (no external deps)
local function make_rng(seed)
  local state = seed or 12345
  return {
    next = function(self)
      state = (state * 1664525 + 1013904223) % (2^32)
      return state
    end,
    float = function(self)
      return self:next() / (2^32)
    end,
    int = function(self, lo, hi)
      return lo + math.floor(self:float() * (hi - lo + 1))
    end,
  }
end

-- Bootstrap sample (sample with replacement)
local function bootstrap_sample(dataset, rng)
  local n = #dataset
  local sample = {}
  for i = 1, n do
    local idx = rng:int(1, n)
    sample[i] = dataset[idx]
  end
  return sample
end

-- Randomly select k features
local function sample_features(features, k, rng)
  -- Fisher-Yates partial shuffle
  local pool = {}
  for i, f in ipairs(features) do pool[i] = f end
  local n = #pool
  k = math.min(k, n)
  for i = 1, k do
    local j = rng:int(i, n)
    pool[i], pool[j] = pool[j], pool[i]
  end
  local selected = {}
  for i = 1, k do selected[i] = pool[i] end
  return selected
end

-- Determine number of features to use per split
local function resolve_max_features(max_features, total_features)
  if max_features == nil or max_features == "sqrt" then
    return math.max(1, math.floor(math.sqrt(total_features)))
  elseif max_features == "log2" then
    return math.max(1, math.floor(log2(total_features)))
  elseif type(max_features) == "number" then
    return math.max(1, math.floor(max_features))
  end
  return total_features
end

function M.forest(dataset, opts)
  opts = opts or {}
  local num_trees = opts.num_trees or 10
  local max_features_spec = opts.max_features  -- "sqrt", "log2", or integer
  local max_depth = opts.max_depth
  local bootstrap = opts.bootstrap
  if bootstrap == nil then bootstrap = true end
  local algorithm = opts.algorithm or "id3"
  local min_samples = opts.min_samples or 1
  local seed = opts.seed or 42

  local all_features = opts.features or get_all_features(dataset)
  local k = resolve_max_features(max_features_spec, #all_features)

  local rng = make_rng(seed)
  local trees = {}

  for i = 1, num_trees do
    local sample = bootstrap and bootstrap_sample(dataset, rng) or dataset
    local feats = sample_features(all_features, k, rng)
    local tree = M.train(sample, {
      algorithm = algorithm,
      max_depth = max_depth,
      min_samples = min_samples,
      features = feats,
    })
    trees[i] = tree
  end

  return setmetatable({_trees = trees}, Forest)
end

return M
