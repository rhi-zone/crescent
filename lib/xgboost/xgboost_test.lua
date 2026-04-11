if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local xgb = require("lib.xgboost")

local function approx(a, b, tol)
  tol = tol or 0.1
  T.ok(math.abs(a - b) < tol, "expected " .. a .. " ~ " .. b .. " (tol=" .. tol .. ")")
end

-- ── 1. Simple linear data ───────────────────────────────────────────────────

T.describe("xgboost", function()

  T.it("trains on simple linear data", function()
    local X = {}
    local y = {}
    for i = 1, 50 do
      X[i] = { i }
      y[i] = 2 * i + 1
    end
    local model = xgb.train(X, y, { n_estimators = 50, max_depth = 4, learning_rate = 0.3 })
    local preds = model:predict(X)
    -- predictions should be roughly correct
    for i = 1, 50 do
      approx(preds[i], y[i], 2.0)
    end
  end)

  -- ── 2. MSE decreases ───────────────────────────────────────────────────────

  T.it("regression MSE decreases with training", function()
    local X = {}
    local y = {}
    for i = 1, 30 do
      X[i] = { i, i * 0.5 }
      y[i] = i * 3
    end
    local model1 = xgb.train(X, y, { n_estimators = 1, max_depth = 3 })
    local model2 = xgb.train(X, y, { n_estimators = 50, max_depth = 3 })
    local mse1, mse2 = 0, 0
    local p1 = model1:predict(X)
    local p2 = model2:predict(X)
    for i = 1, 30 do
      mse1 = mse1 + (p1[i] - y[i])^2
      mse2 = mse2 + (p2[i] - y[i])^2
    end
    T.ok(mse2 < mse1, "more trees should reduce MSE")
  end)

  -- ── 3. Logistic: linearly separable ───────────────────────────────────────

  T.it("classifies linearly separable data", function()
    local X = {}
    local y = {}
    for i = 1, 20 do
      X[i] = { i }
      y[i] = 0
    end
    for i = 1, 20 do
      X[20 + i] = { 20 + i }
      y[20 + i] = 1
    end
    local model = xgb.train(X, y, { n_estimators = 50, objective = "logistic", max_depth = 3 })
    local labels = model:predict_class(X)
    local correct = 0
    for i = 1, 40 do
      if labels[i] == y[i] then correct = correct + 1 end
    end
    T.ok(correct >= 35, "accuracy should be high: " .. correct .. "/40")
  end)

  -- ── 4. predict_one ────────────────────────────────────────────────────────

  T.it("predict_one returns a single number", function()
    local X = { { 1, 2 }, { 3, 4 }, { 5, 6 } }
    local y = { 10, 20, 30 }
    local model = xgb.train(X, y, { n_estimators = 10, max_depth = 2 })
    local p = model:predict_one({ 3, 4 })
    T.eq(type(p), "number")
  end)

  -- ── 5. predict_class returns 0/1 ─────────────────────────────────────────

  T.it("predict_class returns 0/1 labels", function()
    local X = { { 0 }, { 1 }, { 10 }, { 11 } }
    local y = { 0, 0, 1, 1 }
    local model = xgb.train(X, y, { n_estimators = 30, objective = "logistic", max_depth = 2 })
    local labels = model:predict_class(X)
    for i = 1, #labels do
      T.ok(labels[i] == 0 or labels[i] == 1, "label must be 0 or 1")
    end
  end)

  -- ── 6. Feature importance ─────────────────────────────────────────────────

  T.it("informative feature has higher importance", function()
    local X = {}
    local y = {}
    for i = 1, 50 do
      X[i] = { i, 0 }  -- feature 1 is informative, feature 2 is constant
      y[i] = i * 2
    end
    local model = xgb.train(X, y, { n_estimators = 20, max_depth = 3 })
    local imp = model:feature_importance()
    T.ok((imp[1] or 0) > (imp[2] or 0), "feature 1 should be more important")
  end)

  -- ── 7. max_depth=1: stumps ────────────────────────────────────────────────

  T.it("max_depth=1 produces stumps", function()
    local X = { { 1 }, { 2 }, { 3 }, { 4 } }
    local y = { 1, 2, 3, 4 }
    local model = xgb.train(X, y, { n_estimators = 5, max_depth = 1 })
    -- each tree should have at most one split (depth 1)
    for _, tree in ipairs(model.trees) do
      if tree.left then
        -- left and right should be leaves
        T.ok(tree.left.value ~= nil, "left child should be a leaf")
        T.ok(tree.right.value ~= nil, "right child should be a leaf")
      end
    end
  end)

  -- ── 8. n_estimators=1 ────────────────────────────────────────────────────

  T.it("n_estimators=1 builds a single tree", function()
    local X = { { 1 }, { 2 }, { 3 } }
    local y = { 10, 20, 30 }
    local model = xgb.train(X, y, { n_estimators = 1, max_depth = 3 })
    T.eq(#model.trees, 1)
    T.eq(model.n_estimators, 1)
  end)

  -- ── 9. Learning rate effect ───────────────────────────────────────────────

  T.it("lower learning rate converges slower", function()
    local X = {}
    local y = {}
    for i = 1, 20 do
      X[i] = { i }
      y[i] = i * 5
    end
    local model_fast = xgb.train(X, y, { n_estimators = 10, learning_rate = 0.5, max_depth = 3 })
    local model_slow = xgb.train(X, y, { n_estimators = 10, learning_rate = 0.01, max_depth = 3 })
    -- fast learner should have lower MSE after same number of rounds
    local mse_fast, mse_slow = 0, 0
    local pf = model_fast:predict(X)
    local ps = model_slow:predict(X)
    for i = 1, 20 do
      mse_fast = mse_fast + (pf[i] - y[i])^2
      mse_slow = mse_slow + (ps[i] - y[i])^2
    end
    T.ok(mse_fast < mse_slow, "fast learner should have lower MSE")
  end)

  -- ── 10. Lambda regularization ─────────────────────────────────────────────

  T.it("higher lambda produces smaller leaf weights", function()
    local X = { { 1 }, { 2 }, { 3 }, { 4 }, { 5 } }
    local y = { 100, 200, 300, 400, 500 }
    local model_low = xgb.train(X, y, { n_estimators = 1, lambda = 0.01, max_depth = 2 })
    local model_high = xgb.train(X, y, { n_estimators = 1, lambda = 100, max_depth = 2 })
    -- collect all leaf values
    local function max_leaf(tree)
      if tree.value then return math.abs(tree.value) end
      return math.max(max_leaf(tree.left), max_leaf(tree.right))
    end
    local max_low = max_leaf(model_low.trees[1])
    local max_high = max_leaf(model_high.trees[1])
    T.ok(max_high < max_low, "high lambda should shrink leaf weights")
  end)

  -- ── 11. Gamma: fewer splits ───────────────────────────────────────────────

  T.it("higher gamma produces fewer splits", function()
    local X = {}
    local y = {}
    for i = 1, 20 do
      X[i] = { i }
      y[i] = i + 0.01 * i  -- nearly linear, small gain per split
    end
    local function count_nodes(tree)
      if tree.value then return 1 end
      return 1 + count_nodes(tree.left) + count_nodes(tree.right)
    end
    local model_low = xgb.train(X, y, { n_estimators = 1, gamma = 0, max_depth = 6 })
    local model_high = xgb.train(X, y, { n_estimators = 1, gamma = 1e6, max_depth = 6 })
    local nodes_low = count_nodes(model_low.trees[1])
    local nodes_high = count_nodes(model_high.trees[1])
    T.ok(nodes_high <= nodes_low, "high gamma should produce fewer or equal nodes")
  end)

  -- ── 12. min_samples_split ─────────────────────────────────────────────────

  T.it("min_samples_split prevents over-splitting", function()
    local X = {}
    local y = {}
    for i = 1, 10 do
      X[i] = { i }
      y[i] = i
    end
    local function count_nodes(tree)
      if tree.value then return 1 end
      return 1 + count_nodes(tree.left) + count_nodes(tree.right)
    end
    local model_split2 = xgb.train(X, y, { n_estimators = 1, min_samples_split = 2, max_depth = 10 })
    local model_split8 = xgb.train(X, y, { n_estimators = 1, min_samples_split = 8, max_depth = 10 })
    local n2 = count_nodes(model_split2.trees[1])
    local n8 = count_nodes(model_split8.trees[1])
    T.ok(n8 <= n2, "higher min_samples_split should produce fewer or equal nodes")
  end)

  -- ── 13. Serialization round-trip ──────────────────────────────────────────

  T.it("to_table + from_table round-trip", function()
    local X = { { 1, 2 }, { 3, 4 }, { 5, 6 }, { 7, 8 } }
    local y = { 10, 20, 30, 40 }
    local model = xgb.train(X, y, { n_estimators = 10, max_depth = 3 })
    local t = model:to_table()
    local model2 = xgb.from_table(t)
    local p1 = model:predict(X)
    local p2 = model2:predict(X)
    for i = 1, #X do
      T.eq(p1[i], p2[i])
    end
  end)

  -- ── 14. XOR problem ──────────────────────────────────────────────────────

  T.it("logistic can fit XOR with enough trees", function()
    -- Use distinct feature values with noise so splits have nonzero gain
    local X_rep, y_rep = {}, {}
    local rng_state = 123
    local function cheap_rand()
      rng_state = (rng_state * 1103515245 + 12345) % 2147483648
      return (rng_state / 2147483648) * 0.2 - 0.1  -- small noise in [-0.1, 0.1]
    end
    local base_X = { { 0, 0 }, { 0, 1 }, { 1, 0 }, { 1, 1 } }
    local base_y = { 0, 1, 1, 0 }
    for rep = 1, 50 do
      for i = 1, 4 do
        X_rep[#X_rep + 1] = { base_X[i][1] + cheap_rand(), base_X[i][2] + cheap_rand() }
        y_rep[#y_rep + 1] = base_y[i]
      end
    end
    local model = xgb.train(X_rep, y_rep, {
      n_estimators = 200, objective = "logistic", max_depth = 4, learning_rate = 0.3, lambda = 0.01,
    })
    local labels = model:predict_class(base_X)
    local correct = 0
    for i = 1, 4 do
      if labels[i] == base_y[i] then correct = correct + 1 end
    end
    T.ok(correct >= 3, "XOR: at least 3/4 correct, got " .. correct)
  end)

  -- ── 15. Single feature regression ─────────────────────────────────────────

  T.it("single feature regression works", function()
    local X = { { 5 }, { 10 }, { 15 } }
    local y = { 5, 10, 15 }
    local model = xgb.train(X, y, { n_estimators = 50, max_depth = 3 })
    local preds = model:predict(X)
    for i = 1, 3 do
      approx(preds[i], y[i], 2.0)
    end
  end)

  -- ── 16. All-same targets ──────────────────────────────────────────────────

  T.it("all-same targets predicts the constant", function()
    local X = { { 1 }, { 2 }, { 3 }, { 4 } }
    local y = { 7, 7, 7, 7 }
    local model = xgb.train(X, y, { n_estimators = 10, max_depth = 3 })
    local preds = model:predict(X)
    for i = 1, 4 do
      approx(preds[i], 7, 0.5)
    end
  end)

  -- ── 17. Two-class balanced beats baseline ─────────────────────────────────

  T.it("two-class balanced beats 50% baseline", function()
    local X = {}
    local y = {}
    for i = 1, 30 do
      X[i] = { i }
      y[i] = i <= 15 and 0 or 1
    end
    local model = xgb.train(X, y, { n_estimators = 30, objective = "logistic", max_depth = 2 })
    local labels = model:predict_class(X)
    local correct = 0
    for i = 1, 30 do
      if labels[i] == y[i] then correct = correct + 1 end
    end
    T.ok(correct > 15, "should beat random: " .. correct .. "/30")
  end)

  -- ── 18. Subsample < 1.0 ──────────────────────────────────────────────────

  T.it("subsample < 1.0 still trains", function()
    local X = {}
    local y = {}
    for i = 1, 30 do
      X[i] = { i }
      y[i] = i * 2
    end
    local model = xgb.train(X, y, { n_estimators = 30, subsample = 0.5, max_depth = 3 })
    local preds = model:predict(X)
    local mse = 0
    for i = 1, 30 do
      mse = mse + (preds[i] - y[i])^2
    end
    mse = mse / 30
    T.ok(mse < 100, "subsampled model should still learn, MSE=" .. mse)
  end)

  -- ── 19. Zero estimators ───────────────────────────────────────────────────

  T.it("zero estimators predicts base value", function()
    local X = { { 1 }, { 2 }, { 3 } }
    local y = { 10, 20, 30 }
    local model = xgb.train(X, y, { n_estimators = 0 })
    local preds = model:predict(X)
    -- base prediction for MSE is mean = 20
    for i = 1, 3 do
      approx(preds[i], 20, 0.01)
    end
  end)

  -- ── 20. predict matches predict_one per sample ────────────────────────────

  T.it("predict matches predict_one per sample", function()
    local X = { { 1, 2 }, { 3, 4 }, { 5, 6 }, { 7, 8 } }
    local y = { 10, 20, 30, 40 }
    local model = xgb.train(X, y, { n_estimators = 20, max_depth = 3 })
    local preds = model:predict(X)
    for i = 1, #X do
      T.eq(preds[i], model:predict_one(X[i]))
    end
  end)

end)

-- ── Report ──────────────────────────────────────────────────────────────────

local s = T._summary()
print(string.format("\n%d passed, %d failed", s.pass, s.fail))
for _, t in ipairs(s.tests) do
  if not t.ok then
    print("FAIL: " .. t.name .. (t.err and (" — " .. t.err) or ""))
  end
end
if s.fail > 0 then os.exit(1) end
