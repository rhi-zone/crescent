if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local DT = require("lib.decision_tree")

-- Classic "play tennis" dataset (14 examples)
local tennis = {
  {outlook="sunny",    temperature="hot",  humidity="high",   wind="weak",   label="no"},
  {outlook="sunny",    temperature="hot",  humidity="high",   wind="strong", label="no"},
  {outlook="overcast", temperature="hot",  humidity="high",   wind="weak",   label="yes"},
  {outlook="rain",     temperature="mild", humidity="high",   wind="weak",   label="yes"},
  {outlook="rain",     temperature="cool", humidity="normal", wind="weak",   label="yes"},
  {outlook="rain",     temperature="cool", humidity="normal", wind="strong", label="no"},
  {outlook="overcast", temperature="cool", humidity="normal", wind="strong", label="yes"},
  {outlook="sunny",    temperature="mild", humidity="high",   wind="weak",   label="no"},
  {outlook="sunny",    temperature="cool", humidity="normal", wind="weak",   label="yes"},
  {outlook="rain",     temperature="mild", humidity="normal", wind="weak",   label="yes"},
  {outlook="sunny",    temperature="mild", humidity="normal", wind="strong", label="yes"},
  {outlook="overcast", temperature="mild", humidity="high",   wind="strong", label="yes"},
  {outlook="overcast", temperature="hot",  humidity="normal", wind="weak",   label="yes"},
  {outlook="rain",     temperature="mild", humidity="high",   wind="strong", label="no"},
}

T.describe("decision_tree metadata", function()
  T.it("_tier is pure", function()
    T.eq(DT._tier, "pure")
  end)
end)

T.describe("ID3 train on tennis dataset", function()
  local tree = DT.train(tennis)

  T.it("returns a tree object", function()
    T.ok(tree ~= nil)
    T.ok(type(tree) == "table")
  end)

  T.it("tree depth >= 1", function()
    T.ok(tree:depth() >= 1)
  end)

  T.it("tree depth is reasonable (<= 5)", function()
    T.ok(tree:depth() <= 5)
  end)

  T.it("node_count >= 3", function()
    T.ok(tree:node_count() >= 3)
  end)

  T.it("overcast always predicts yes", function()
    T.eq(tree:predict({outlook="overcast", temperature="hot",  humidity="high",   wind="weak"}),   "yes")
    T.eq(tree:predict({outlook="overcast", temperature="cool", humidity="normal", wind="strong"}), "yes")
    T.eq(tree:predict({outlook="overcast", temperature="mild", humidity="high",   wind="strong"}), "yes")
  end)

  T.it("sunny + normal humidity predicts yes", function()
    T.eq(tree:predict({outlook="sunny", temperature="cool", humidity="normal", wind="weak"}), "yes")
    T.eq(tree:predict({outlook="sunny", temperature="mild", humidity="normal", wind="strong"}), "yes")
  end)

  T.it("sunny + high humidity predicts no", function()
    T.eq(tree:predict({outlook="sunny", temperature="hot", humidity="high", wind="weak"}), "no")
    T.eq(tree:predict({outlook="sunny", temperature="hot", humidity="high", wind="strong"}), "no")
  end)

  T.it("predict_all returns array of same length", function()
    local preds = tree:predict_all(tennis)
    T.eq(#preds, #tennis)
  end)

  T.it("training accuracy is 1.0 (no noise in data)", function()
    T.eq(tree:accuracy(tennis), 1.0)
  end)

  T.it("predict_proba returns table with label keys", function()
    local proba = tree:predict_proba({outlook="overcast", temperature="hot", humidity="high", wind="weak"})
    T.ok(type(proba) == "table")
    T.ok(proba["yes"] ~= nil)
    -- Probability for overcast should strongly favor yes
    T.ok(proba["yes"] > 0.5)
  end)

  T.it("predict_proba probabilities are between 0 and 1", function()
    local proba = tree:predict_proba({outlook="sunny", temperature="hot", humidity="high", wind="weak"})
    for _, p in pairs(proba) do
      T.ok(p >= 0 and p <= 1)
    end
  end)
end)

T.describe("feature_importance", function()
  local tree = DT.train(tennis)

  T.it("returns a table", function()
    local imp = tree:feature_importance()
    T.ok(type(imp) == "table")
  end)

  T.it("outlook appears in feature_importance (ID3 classic result)", function()
    local imp = tree:feature_importance()
    -- ID3 always splits on outlook first for this dataset; it must appear in importance
    T.ok(imp["outlook"] ~= nil)
    T.ok(imp["outlook"] > 0)
  end)

  T.it("ID3 root split is on outlook", function()
    -- The classic ID3 result: outlook has highest IG at root
    T.eq(tree._root.feature, "outlook")
  end)

  T.it("all importance values are >= 0", function()
    local imp = tree:feature_importance()
    for _, v in pairs(imp) do
      T.ok(v >= 0)
    end
  end)

  T.it("importance values sum to ~1", function()
    local imp = tree:feature_importance()
    local sum = 0
    for _, v in pairs(imp) do sum = sum + v end
    T.ok(math.abs(sum - 1.0) < 1e-9)
  end)
end)

T.describe("to_rules", function()
  local tree = DT.train(tennis)
  local rules = tree:to_rules()

  T.it("returns non-empty array", function()
    T.ok(#rules > 0)
  end)

  T.it("each rule is a string", function()
    for _, r in ipairs(rules) do
      T.ok(type(r) == "string")
    end
  end)

  T.it("rules contain IF...THEN", function()
    for _, r in ipairs(rules) do
      T.ok(r:find("IF") ~= nil)
      T.ok(r:find("THEN") ~= nil)
    end
  end)

  T.it("rules contain label values", function()
    local has_yes, has_no = false, false
    for _, r in ipairs(rules) do
      if r:find("yes") then has_yes = true end
      if r:find("no") then has_no = true end
    end
    T.ok(has_yes)
    T.ok(has_no)
  end)
end)

T.describe("tree:print", function()
  local tree = DT.train(tennis)
  T.it("returns a non-empty string", function()
    local s = tree:print()
    T.ok(type(s) == "string")
    T.ok(#s > 0)
  end)
  T.it("contains feature names", function()
    local s = tree:print()
    T.ok(s:find("outlook") ~= nil)
  end)
end)

T.describe("serialize/deserialize", function()
  local tree = DT.train(tennis)
  local t = tree:serialize()
  local tree2 = DT.deserialize(t)

  T.it("serialize returns a table", function()
    T.ok(type(t) == "table")
  end)

  T.it("deserialized tree predicts same as original", function()
    for _, ex in ipairs(tennis) do
      T.eq(tree2:predict(ex), tree:predict(ex))
    end
  end)

  T.it("deserialized tree has same depth", function()
    T.eq(tree2:depth(), tree:depth())
  end)

  T.it("deserialized tree has same node_count", function()
    T.eq(tree2:node_count(), tree:node_count())
  end)
end)

T.describe("max_depth constraint", function()
  T.it("max_depth=1 produces a depth-1 tree", function()
    local tree = DT.train(tennis, {max_depth=1})
    T.eq(tree:depth(), 1)
  end)

  T.it("max_depth=2 produces depth <= 2", function()
    local tree = DT.train(tennis, {max_depth=2})
    T.ok(tree:depth() <= 2)
  end)

  T.it("depth-limited tree is shallower than unlimited", function()
    local tree_full = DT.train(tennis)
    local tree_lim  = DT.train(tennis, {max_depth=1})
    T.ok(tree_lim:depth() <= tree_full:depth())
  end)
end)

T.describe("min_samples constraint", function()
  T.it("min_samples=100 produces a leaf (single node)", function()
    local tree = DT.train(tennis, {min_samples=100})
    T.eq(tree:depth(), 0)
    T.eq(tree:node_count(), 1)
  end)

  T.it("min_samples=1 produces full tree", function()
    local tree = DT.train(tennis, {min_samples=1})
    T.ok(tree:depth() >= 1)
  end)
end)

T.describe("C4.5 algorithm", function()
  local tree = DT.train(tennis, {algorithm="c45"})

  T.it("trains successfully", function()
    T.ok(tree ~= nil)
  end)

  T.it("training accuracy is 1.0", function()
    T.eq(tree:accuracy(tennis), 1.0)
  end)

  T.it("overcast predicts yes", function()
    T.eq(tree:predict({outlook="overcast", temperature="hot", humidity="high", wind="weak"}), "yes")
  end)

  T.it("depth >= 1", function()
    T.ok(tree:depth() >= 1)
  end)
end)

T.describe("selected features subset", function()
  local tree = DT.train(tennis, {features={"outlook", "humidity"}})

  T.it("trains with subset of features", function()
    T.ok(tree ~= nil)
  end)

  T.it("produces non-trivial tree", function()
    T.ok(tree:depth() >= 1)
  end)

  T.it("can predict", function()
    local lbl = tree:predict({outlook="overcast", humidity="high"})
    T.ok(lbl == "yes" or lbl == "no")
  end)
end)

T.describe("pruning", function()
  -- Use half as training, half as validation
  local train_set = {}
  local val_set = {}
  for i, ex in ipairs(tennis) do
    if i % 2 == 0 then
      val_set[#val_set + 1] = ex
    else
      train_set[#train_set + 1] = ex
    end
  end

  local tree = DT.train(train_set)
  local pruned = DT.prune(tree, val_set)

  T.it("returns a tree", function()
    T.ok(pruned ~= nil)
    T.ok(type(pruned) == "table")
  end)

  T.it("pruned tree depth <= original depth", function()
    T.ok(pruned:depth() <= tree:depth())
  end)

  T.it("pruned tree can predict", function()
    local lbl = pruned:predict({outlook="overcast", temperature="hot", humidity="high", wind="weak"})
    T.ok(lbl == "yes" or lbl == "no")
  end)
end)

T.describe("random forest on tennis", function()
  local forest = DT.forest(tennis, {num_trees=10, seed=42})

  T.it("creates a forest", function()
    T.ok(forest ~= nil)
  end)

  T.it("predicts a label", function()
    local lbl = forest:predict({outlook="overcast", temperature="hot", humidity="high", wind="weak"})
    T.ok(lbl == "yes" or lbl == "no")
  end)

  T.it("overcast predicts yes (majority vote)", function()
    T.eq(forest:predict({outlook="overcast", temperature="hot", humidity="high", wind="weak"}), "yes")
  end)

  T.it("accuracy on training set is reasonable (>= 0.5)", function()
    local acc = forest:accuracy(tennis)
    T.ok(acc >= 0.5)
  end)

  T.it("predict_proba returns table", function()
    local proba = forest:predict_proba({outlook="overcast", temperature="hot", humidity="high", wind="weak"})
    T.ok(type(proba) == "table")
  end)

  T.it("predict_proba values are in [0,1]", function()
    local proba = forest:predict_proba({outlook="sunny", temperature="hot", humidity="high", wind="strong"})
    for _, p in pairs(proba) do
      T.ok(p >= 0 and p <= 1)
    end
  end)

  T.it("feature_importance returns table", function()
    local imp = forest:feature_importance()
    T.ok(type(imp) == "table")
  end)
end)

T.describe("random forest on noisy synthetic data", function()
  -- XOR-like dataset: label = (A xor B)
  -- Noise: some labels flipped
  local function make_dataset(n, seed)
    local rng_state = seed or 1
    local function next_rand()
      rng_state = (rng_state * 1664525 + 1013904223) % (2^32)
      return rng_state
    end
    local data = {}
    for i = 1, n do
      local a = next_rand() % 2 == 0 and "0" or "1"
      local b = next_rand() % 2 == 0 and "0" or "1"
      local correct = ((a == "1") ~= (b == "1")) and "yes" or "no"
      -- Flip ~10% labels for noise
      local label = (next_rand() % 10 == 0) and (correct == "yes" and "no" or "yes") or correct
      data[i] = {a=a, b=b, label=label}
    end
    return data
  end

  local train = make_dataset(100, 7)
  local test  = make_dataset(50, 99)

  local single_tree = DT.train(train)
  local forest = DT.forest(train, {num_trees=15, seed=77, max_features="sqrt"})

  T.it("single tree can predict", function()
    local lbl = single_tree:predict(test[1])
    T.ok(lbl == "yes" or lbl == "no")
  end)

  T.it("forest can predict", function()
    local lbl = forest:predict(test[1])
    T.ok(lbl == "yes" or lbl == "no")
  end)

  T.it("forest accuracy is above chance (>= 0.5)", function()
    local acc = forest:accuracy(test)
    T.ok(acc >= 0.5)
  end)

  T.it("both single tree and forest return valid accuracy values", function()
    local acc_tree   = single_tree:accuracy(test)
    local acc_forest = forest:accuracy(test)
    T.ok(acc_tree   >= 0 and acc_tree   <= 1)
    T.ok(acc_forest >= 0 and acc_forest <= 1)
  end)
end)

T.describe("edge cases", function()
  T.it("single-class dataset produces leaf immediately", function()
    local data = {
      {x="a", label="yes"},
      {x="b", label="yes"},
      {x="c", label="yes"},
    }
    local tree = DT.train(data)
    T.eq(tree:depth(), 0)
    T.eq(tree:predict({x="a"}), "yes")
    T.eq(tree:predict({x="z"}), "yes")
  end)

  T.it("single example trains correctly", function()
    local data = {{x="hello", label="world"}}
    local tree = DT.train(data)
    T.eq(tree:predict({x="hello"}), "world")
  end)

  T.it("unknown feature value uses default label", function()
    local tree = DT.train(tennis)
    local lbl = tree:predict({outlook="unknown_value", temperature="hot", humidity="high", wind="weak"})
    T.ok(lbl == "yes" or lbl == "no")
  end)

  T.it("accuracy on empty dataset returns 1.0", function()
    local tree = DT.train(tennis)
    T.eq(tree:accuracy({}), 1.0)
  end)

  T.it("predict_all on empty input returns empty table", function()
    local tree = DT.train(tennis)
    local results = tree:predict_all({})
    T.eq(#results, 0)
  end)
end)
