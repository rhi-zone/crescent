if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

M._tier = "pure"

--:: LabelCounts = { [string]: integer }
--:: LeafNode = { type: string, label: any, counts: LabelCounts, total: integer }
--:: BranchNode = { type: string, feature: string, children: { [any]: any }, default_label: any, counts: LabelCounts, total: integer }
--:: TreeNode = { type: string, label: any, counts: LabelCounts, total: integer, feature: string, children: { [any]: any }, default_label: any }

-- Math helpers

local function log2(x)
  return math.log(x) / math.log(2)
end

-- Count label occurrences in a dataset
local function count_labels(dataset)
  local counts = {} --: LabelCounts
  for _, ex in ipairs(dataset) do
    local lbl = tostring(ex.label)
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
      best_lbl = lbl --[[: any]]
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
  local h = 0 --: number
  for _, cnt in pairs(counts) do
    local p = cnt / n
    h = h - p * log2(p)
  end
  return h
end

-- Split dataset by feature value
local function split_by_feature(dataset, feature)
  local splits = {} --: { [any]: { [integer]: any } }
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
  local cond_h = 0 --: number
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
  local si = 0 --: number
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
  local best_feature = nil
  local best_score = -math.huge --: number
  local best_splits = nil --: { [any]: { [integer]: any } } | nil
  for _, f in ipairs(features) do
    local score, splits
    if algorithm == "c45" then
      score, splits = gain_ratio(dataset, f)
    else
      score, splits = information_gain(dataset, f)
    end
    local score_ = score --[[:! number]]
    if score_ > best_score then
      best_score = score_
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

  local children = {} --: { [any]: any }
  local best_splits_ = best_splits --[[:! { [any]: { [integer]: any } }]]
  for val, subset in pairs(best_splits_) do
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
  local node_ = node --[[:! TreeNode]]
  if node_.type == "leaf" then
    return node_.label
  end
  local v = example[node_.feature]
  if v == nil then v = "__nil__" end
  local child = node_.children[v]
  if not child then
    return node_.default_label
  end
  return traverse(child --[[:! TreeNode]], example)
end

-- Traverse to get probability distribution
local function traverse_proba(node, example)
  local node_ = node --[[:! TreeNode]]
  if node_.type == "leaf" then
    -- Return counts as proba
    local proba = {} --: { [string]: number }
    local total = node_.total
    if total == 0 then return proba end
    for lbl, cnt in pairs(node_.counts) do
      proba[lbl] = cnt / total
    end
    return proba
  end
  local v = example[node_.feature]
  if v == nil then v = "__nil__" end
  local child = node_.children[v]
  if not child then
    -- Return distribution from this node
    local proba = {} --: { [string]: number }
    local total = node_.total
    if total == 0 then return proba end
    for lbl, cnt in pairs(node_.counts) do
      proba[lbl] = cnt / total
    end
    return proba
  end
  return traverse_proba(child --[[:! TreeNode]], example)
end

-- Compute max depth of a tree
local function tree_depth(node)
  local node_ = node --[[:! TreeNode]]
  if node_.type == "leaf" then return 0 end
  local max_d = 0
  for _, child in pairs(node_.children) do
    local d = tree_depth(child --[[:! TreeNode]])
    if d > max_d then max_d = d end
  end
  return 1 + max_d
end

-- Count total nodes
local function tree_node_count(node)
  local node_ = node --[[:! TreeNode]]
  if node_.type == "leaf" then return 1 end
  local cnt = 1
  for _, child in pairs(node_.children) do
    cnt = cnt + tree_node_count(child --[[:! TreeNode]])
  end
  return cnt
end

-- Feature importance: sum of weighted information gain at each split
-- importance[feature] += (node.total / root.total) * IG contributed
local function collect_importance(node, root_total, importance)
  local node_ = node --[[:! TreeNode]]
  if node_.type == "leaf" then return end
  local f = node_.feature
  -- Compute IG at this node
  -- We already know the feature; approximate contribution as weighted entropy reduction
  local h_parent = 0 --: number
  for _, cnt in pairs(node_.counts) do
    local p = cnt / node_.total
    h_parent = h_parent - p * log2(p)
  end
  local h_children = 0 --: number
  for _, child_any in pairs(node_.children) do
    local child = child_any --[[:! TreeNode]]
    local p_child = child.total / node_.total
    local h_child = 0 --: number
    for _, cnt in pairs(child.counts) do
      local p = cnt / child.total
      h_child = h_child - p * log2(p)
    end
    h_children = h_children + p_child * h_child
  end
  local ig = h_parent - h_children
  local weight = node_.total / root_total
  importance[f] = (importance[f] or 0) + weight * ig

  for _, child_any in pairs(node_.children) do
    collect_importance(child_any --[[:! TreeNode]], root_total, importance)
  end
end

-- Normalize a table of scores to sum to 1
local function normalize_scores(t)
  local t_ = t --[[:! { [string]: number }]]
  local total = 0 --: number
  for _, v in pairs(t_) do total = total + v end
  if total == 0 then return t_ end
  local out = {} --: { [string]: number }
  for k, v in pairs(t_) do out[k] = v / total end
  return out
end

-- Convert tree to if-then rules (depth-first, collect path)
local function collect_rules(node, path, rules)
  local node_ = node --[[:! TreeNode]]
  if node_.type == "leaf" then
    local conds = {}
    for _, cond in ipairs(path) do
      conds[#conds + 1] = cond
    end
    local rule
    if #conds == 0 then
      rule = "IF TRUE THEN " .. tostring(node_.label)
    else
      rule = "IF " .. table.concat(conds, " AND ") .. " THEN " .. tostring(node_.label)
    end
    rules[#rules + 1] = rule
    return
  end
  -- Sort values for deterministic output
  local vals = {} --: { [integer]: string }
  for v in pairs(node_.children) do vals[#vals + 1] = tostring(v) end
  table.sort(vals)
  for _, v in ipairs(vals) do
    local display_v = v == "__nil__" and "nil" or v
    path[#path + 1] = node_.feature .. "=" .. display_v
    collect_rules(node_.children[v] --[[:! TreeNode]], path, rules)
    path[#path] = nil --[[: any]]
  end
end

-- Print tree as string
--: (TreeNode, integer | nil, { [integer]: string } | nil) -> string
local function tree_to_string(node, indent, lines)
  local node_ = node --[[:! TreeNode]]
  local indent_ = indent or 0
  local lines_ = lines or {} --: { [integer]: string }
  local prefix = string.rep("  ", indent_)
  if node_.type == "leaf" then
    lines_[#lines_ + 1] = prefix .. "[" .. tostring(node_.label) .. "] (" .. tostring(node_.total) .. " samples)"
  else
    lines_[#lines_ + 1] = prefix .. node_.feature .. ":"
    local vals = {} --: { [integer]: string }
    for v in pairs(node_.children) do vals[#vals + 1] = tostring(v) end
    table.sort(vals)
    for _, v in ipairs(vals) do
      local display_v = v == "__nil__" and "nil" or v
      lines_[#lines_ + 1] = prefix .. "  " .. display_v .. " ->"
      tree_to_string(node_.children[v] --[[:! TreeNode]], indent_ + 2, lines_)
    end
  end
  return table.concat(lines_, "\n")
end

-- Serialize tree to plain Lua table (recursive)
local function serialize_node(node)
  local node_ = node --[[:! TreeNode]]
  if node_.type == "leaf" then
    local counts = {} --: LabelCounts
    for k, v in pairs(node_.counts) do counts[k] = v end
    return {type="leaf", label=node_.label, counts=counts, total=node_.total}
  end
  local children = {} --: { [any]: any }
  for v, child in pairs(node_.children) do
    children[v] = serialize_node(child --[[:! TreeNode]])
  end
  local counts = {} --: LabelCounts
  for k, v in pairs(node_.counts) do counts[k] = v end
  return {
    type = "branch",
    feature = node_.feature,
    children = children,
    default_label = node_.default_label,
    counts = counts,
    total = node_.total,
  }
end

-- Deserialize from plain Lua table
local function deserialize_node(t)
  local t_ = t --[[:! TreeNode]]
  if t_.type == "leaf" then
    return {type="leaf", label=t_.label, counts=t_.counts, total=t_.total}
  end
  local children = {} --: { [any]: any }
  for v, child in pairs(t_.children) do
    children[v] = deserialize_node(child --[[:! TreeNode]])
  end
  return {
    type = "branch",
    feature = t_.feature,
    children = children,
    default_label = t_.default_label,
    counts = t_.counts,
    total = t_.total,
  }
end

-- Reduced-error pruning (recursive)
-- Returns new node; prunes if replacing subtree with leaf improves/maintains val accuracy
local function prune_node(node, val_dataset)
  local node_ = node --[[:! TreeNode]]
  if node_.type == "leaf" then return node_ end

  -- Prune children first
  local pruned_children = {} --: { [any]: any }
  for v, child in pairs(node_.children) do
    -- Get subset of val_dataset reaching this child
    local subset = {}
    for _, ex in ipairs(val_dataset) do
      local ev = ex[node_.feature]
      if ev == nil then ev = "__nil__" end
      if ev == v then subset[#subset + 1] = ex end
    end
    pruned_children[v] = prune_node(child --[[:! TreeNode]], subset)
  end

  -- Build pruned branch node
  local pruned = {
    type = "branch",
    feature = node_.feature,
    children = pruned_children,
    default_label = node_.default_label,
    counts = node_.counts,
    total = node_.total,
    label = nil, --[[: any]]
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
  local root_ = self._root --[[:! TreeNode]]
  return traverse(root_, example)
end

function Tree:predict_proba(example)
  local root_ = self._root --[[:! TreeNode]]
  return traverse_proba(root_, example)
end

function Tree:predict_all(examples)
  local root_ = self._root --[[:! TreeNode]]
  local results = {}
  for i, ex in ipairs(examples) do
    results[i] = traverse(root_, ex)
  end
  return results
end

function Tree:accuracy(test_dataset)
  local root_ = self._root --[[:! TreeNode]]
  local correct = 0
  local total = #test_dataset
  if total == 0 then return 1.0 end
  for _, ex in ipairs(test_dataset) do
    if traverse(root_, ex) == ex.label then
      correct = correct + 1
    end
  end
  return correct / total
end

function Tree:depth()
  local root_ = self._root --[[:! TreeNode]]
  return tree_depth(root_)
end

function Tree:node_count()
  local root_ = self._root --[[:! TreeNode]]
  return tree_node_count(root_)
end

function Tree:feature_importance()
  local root_ = self._root --[[:! TreeNode]]
  local importance = {} --: { [string]: number }
  collect_importance(root_, root_.total, importance)
  return normalize_scores(importance)
end

function Tree:print()
  local root_ = self._root --[[:! TreeNode]]
  return tree_to_string(root_, nil, nil)
end

function Tree:to_rules()
  local root_ = self._root --[[:! TreeNode]]
  local rules = {} --: { [integer]: string }
  local path = {} --: { [integer]: string }
  collect_rules(root_, path, rules)
  return rules
end

function Tree:serialize()
  local root_ = self._root --[[:! TreeNode]]
  return serialize_node(root_)
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
  local features_ = features --[[:! { [integer]: string }]]

  local root = build_tree(dataset, features_, 0, max_depth, min_samples, algorithm)
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
  local trees_ = self._trees --[[:! { [integer]: any }]]
  local votes = {} --: { [string]: integer }
  for _, tree in ipairs(trees_) do
    local tree_ = tree --[[: any]]
    local lbl = tostring(tree_:predict(example))
    votes[lbl] = (votes[lbl] or 0) + 1
  end
  local best_lbl, best_cnt = nil, -1
  for lbl, cnt in pairs(votes) do
    if cnt > best_cnt then
      best_lbl = lbl --[[: any]]
      best_cnt = cnt
    end
  end
  return best_lbl
end

function Forest:predict_proba(example)
  local trees_ = self._trees --[[:! { [integer]: any }]]
  local sum_proba = {} --: { [string]: number }
  local n = #trees_
  for _, tree in ipairs(trees_) do
    local tree_ = tree --[[: any]]
    local proba = tree_:predict_proba(example) --[[:! { [string]: number }]]
    for lbl, p in pairs(proba) do
      sum_proba[lbl] = (sum_proba[lbl] or 0) + p
    end
  end
  local avg = {} --: { [string]: number }
  for lbl, total in pairs(sum_proba) do
    avg[lbl] = total / n
  end
  return avg
end

function Forest:accuracy(test_dataset)
  local trees_ = self._trees --[[:! { [integer]: any }]]
  local correct = 0
  local total = #test_dataset
  if total == 0 then return 1.0 end
  for _, ex in ipairs(test_dataset) do
    -- predict by voting directly to avoid self-type issue
    local votes = {} --: { [string]: integer }
    for _, tree in ipairs(trees_) do
      local tree_ = tree --[[: any]]
      local lbl = tostring(tree_:predict(ex))
      votes[lbl] = (votes[lbl] or 0) + 1
    end
    local best_lbl, best_cnt = nil, -1
    for lbl, cnt in pairs(votes) do
      if cnt > best_cnt then best_lbl = lbl; best_cnt = cnt end
    end
    if best_lbl == ex.label then
      correct = correct + 1
    end
  end
  return correct / total
end

function Forest:feature_importance()
  local trees_ = self._trees --[[:! { [integer]: any }]]
  local sum_importance = {} --: { [string]: number }
  local n = #trees_
  for _, tree in ipairs(trees_) do
    local tree_ = tree --[[: any]]
    local imp = tree_:feature_importance() --[[:! { [string]: number }]]
    for f, score in pairs(imp) do
      sum_importance[f] = (sum_importance[f] or 0) + score
    end
  end
  local avg = {} --: { [string]: number }
  for f, total in pairs(sum_importance) do
    avg[f] = total / n
  end
  return normalize_scores(avg)
end

-- Simple LCG RNG (no external deps)
--: (integer | nil) -> any
local function make_rng(seed)
  local state = (seed or 12345) --[[:! integer]]
  return {
    next = function(self)
      state = math.floor((state * 1664525 + 1013904223) % (2^32)) --[[:! integer]]
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

  local all_features_raw = opts.features or get_all_features(dataset)
  local all_features = all_features_raw --[[:! { [integer]: string }]]
  local k = resolve_max_features(max_features_spec, #all_features)

  local seed_ = (seed or 42) --[[:! integer]]
  local rng = make_rng(seed_)
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
