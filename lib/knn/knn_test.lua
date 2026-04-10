if not package.path:find("./?/init.lua", 1, true) then package.path = "./?/init.lua;" .. package.path end

local T = require("lib.test.assert")
local knn = require("lib.knn")

local describe, it = T.describe, T.it

local function approx(a, b, tol)
  tol = tol or 1e-6
  return math.abs(a - b) < tol
end

describe("knn", function()

  describe("new", function()
    it("creates index with default options", function()
      local idx = knn.new()
      T.ok(idx, "index created")
      T.eq(idx:size(), 0)
    end)

    it("creates index with custom options", function()
      local idx = knn.new({ k = 3, distance = "cosine" })
      T.ok(idx, "index created")
      T.eq(idx:size(), 0)
    end)

    it("returns error for unknown distance", function()
      local idx, err = knn.new({ distance = "unknown" })
      T.eq(idx, nil)
      T.ok(err:find("unknown distance"), "error message mentions unknown distance")
    end)
  end)

  describe("add and size", function()
    it("adds points and tracks size", function()
      local idx = knn.new()
      idx:add("a", {1, 2, 3})
      T.eq(idx:size(), 1)
      idx:add("b", {4, 5, 6})
      T.eq(idx:size(), 2)
    end)

    it("infers dimensions from first add", function()
      local idx = knn.new()
      T.eq(idx:dimensions(), nil)
      idx:add("a", {1, 2, 3})
      T.eq(idx:dimensions(), 3)
    end)

    it("bulk add_batch", function()
      local idx = knn.new()
      idx:add_batch({
        {"a", {1, 2}},
        {"b", {3, 4}},
        {"c", {5, 6}},
      })
      T.eq(idx:size(), 3)
    end)
  end)

  describe("labels", function()
    it("returns all labels", function()
      local idx = knn.new()
      idx:add("cat", {1, 0})
      idx:add("dog", {0, 1})
      local labs = idx:labels()
      T.eq(#labs, 2)
      T.eq(labs[1], "cat")
      T.eq(labs[2], "dog")
    end)
  end)

  describe("remove", function()
    it("removes a point by label", function()
      local idx = knn.new()
      idx:add("a", {1, 2})
      idx:add("b", {3, 4})
      idx:add("c", {5, 6})
      T.eq(idx:size(), 3)
      local ok = idx:remove("b")
      T.ok(ok, "remove returned true")
      T.eq(idx:size(), 2)
      local labs = idx:labels()
      T.eq(labs[1], "a")
      T.eq(labs[2], "c")
    end)

    it("point no longer appears in query results", function()
      local idx = knn.new({ k = 5 })
      idx:add("a", {1, 0})
      idx:add("b", {2, 0})
      idx:add("c", {3, 0})
      idx:remove("b")
      local res = idx:query({1, 0})
      for i = 1, #res do
        T.neq(res[i].label, "b", "removed point should not appear")
      end
    end)
  end)

  describe("query", function()
    it("returns empty array for empty index", function()
      local idx = knn.new({ k = 3 })
      local res = idx:query({1, 2, 3})
      T.eq(#res, 0)
    end)

    it("single point returns it", function()
      local idx = knn.new({ k = 3 })
      idx:add("only", {1, 2, 3})
      local res = idx:query({0, 0, 0})
      T.eq(#res, 1)
      T.eq(res[1].label, "only")
    end)

    it("returns k nearest neighbors sorted by distance", function()
      local idx = knn.new({ k = 2 })
      idx:add("near", {1, 0})
      idx:add("far", {10, 0})
      idx:add("mid", {5, 0})
      local res = idx:query({0, 0})
      T.eq(#res, 2)
      T.eq(res[1].label, "near")
      T.eq(res[2].label, "mid")
      T.ok(res[1].distance <= res[2].distance, "sorted ascending")
    end)

    it("nearest neighbor is correct with known data", function()
      local idx = knn.new({ k = 1 })
      idx:add("origin", {0, 0, 0})
      idx:add("far", {10, 10, 10})
      local res = idx:query({0.1, 0.1, 0.1})
      T.eq(#res, 1)
      T.eq(res[1].label, "origin")
    end)

    it("k=1 returns single neighbor", function()
      local idx = knn.new({ k = 5 })
      idx:add("a", {1, 0})
      idx:add("b", {2, 0})
      idx:add("c", {3, 0})
      local res = idx:query({1.1, 0}, { k = 1 })
      T.eq(#res, 1)
      T.eq(res[1].label, "a")
    end)

    it("custom k overrides default", function()
      local idx = knn.new({ k = 1 })
      idx:add("a", {1, 0})
      idx:add("b", {2, 0})
      idx:add("c", {3, 0})
      local res = idx:query({0, 0}, { k = 3 })
      T.eq(#res, 3)
    end)

    it("identical points have distance 0", function()
      local idx = knn.new({ k = 1 })
      idx:add("same", {1, 2, 3})
      local res = idx:query({1, 2, 3})
      T.eq(res[1].label, "same")
      T.ok(approx(res[1].distance, 0), "distance is 0")
    end)
  end)

  describe("distance functions", function()
    it("euclidean: known values", function()
      local idx = knn.new({ k = 1, distance = "euclidean" })
      idx:add("a", {3, 0})
      idx:add("b", {0, 4})
      -- distance from origin to (3,0) is 3, to (0,4) is 4
      local res = idx:query({0, 0})
      T.eq(res[1].label, "a")
      T.ok(approx(res[1].distance, 3), "distance is 3")
    end)

    it("cosine: similar vectors have low distance", function()
      local idx = knn.new({ k = 2, distance = "cosine" })
      idx:add("same_dir", {2, 0})
      idx:add("ortho", {0, 1})
      local res = idx:query({1, 0})
      T.eq(res[1].label, "same_dir")
      T.ok(approx(res[1].distance, 0), "same direction = 0 distance")
      T.ok(approx(res[2].distance, 1), "orthogonal = 1 distance")
    end)

    it("manhattan: known values", function()
      local idx = knn.new({ k = 1, distance = "manhattan" })
      idx:add("a", {3, 4})
      local res = idx:query({0, 0})
      T.ok(approx(res[1].distance, 7), "manhattan distance is 7")
    end)

    it("custom distance function", function()
      -- Chebyshev distance (L-infinity)
      local function chebyshev(a, b)
        local vec_mod = require("lib.vec")
        local d = vec_mod.sub(a, b)
        local t = vec_mod.to_table(d)
        local mx = 0
        for i = 1, #t do
          local v = math.abs(t[i])
          if v > mx then mx = v end
        end
        return mx
      end

      local idx = knn.new({ k = 1, distance = chebyshev })
      idx:add("a", {3, 1})
      idx:add("b", {1, 5})
      -- Chebyshev from (0,0): a = max(3,1) = 3, b = max(1,5) = 5
      local res = idx:query({0, 0})
      T.eq(res[1].label, "a")
      T.ok(approx(res[1].distance, 3), "chebyshev distance is 3")
    end)
  end)

  describe("classify", function()
    local function make_idx()
      local idx = knn.new({ k = 5 })
      idx:add("cat", {0.1, 0.9, 0.3})
      idx:add("cat", {0.15, 0.85, 0.35})
      idx:add("cat", {0.12, 0.88, 0.32})
      idx:add("dog", {0.8, 0.2, 0.5})
      idx:add("dog", {0.75, 0.25, 0.55})
      idx:add("fish", {0.1, 0.1, 0.9})
      return idx
    end

    it("majority vote correct", function()
      local idx = make_idx()
      local label, votes = idx:classify({0.11, 0.89, 0.31}, { k = 5 })
      T.eq(label, "cat")
      T.ok(votes["cat"] >= votes["dog"], "cat has more votes than dog")
    end)

    it("weighted voting", function()
      local idx = make_idx()
      local label, scores = idx:classify({0.11, 0.89, 0.31}, { k = 5, weighted = true })
      T.eq(label, "cat")
      T.ok(scores["cat"] > 0, "cat has positive score")
    end)

    it("tie-breaking: first label seen wins", function()
      -- Two labels each with one neighbor at equal distance
      local idx = knn.new({ k = 2 })
      idx:add("alpha", {1, 0})
      idx:add("beta", {-1, 0})
      -- query from origin: both at distance 1
      local label, votes = idx:classify({0, 0})
      T.ok(label == "alpha" or label == "beta", "returns one of the labels")
      T.eq(votes["alpha"], 1)
      T.eq(votes["beta"], 1)
    end)

    it("identical point: weighted returns label immediately", function()
      local idx = knn.new({ k = 3 })
      idx:add("exact", {1, 2, 3})
      idx:add("other", {10, 20, 30})
      local label, scores = idx:classify({1, 2, 3}, { k = 2, weighted = true })
      T.eq(label, "exact")
    end)
  end)

  describe("regress", function()
    it("returns average of nearest labels", function()
      local idx = knn.new({ k = 3 })
      idx:add(10, {1, 0})
      idx:add(20, {2, 0})
      idx:add(30, {3, 0})
      local val = idx:regress({2, 0})
      T.ok(approx(val, 20), "average of 10,20,30 is 20")
    end)

    it("weighted regression", function()
      local idx = knn.new({ k = 2 })
      idx:add(10, {1, 0})
      idx:add(100, {10, 0})
      -- Query at (2,0): dist to 10 is 1, dist to 100 is 8
      -- weighted = (10/1 + 100/8) / (1/1 + 1/8) = (10 + 12.5) / 1.125 = 20
      local val = idx:regress({2, 0}, { k = 2, weighted = true })
      T.ok(type(val) == "number", "returns a number")
      -- Closer to 10 than 100
      T.ok(val < 55, "weighted result biased toward closer point")
    end)

    it("exact match in weighted regression", function()
      local idx = knn.new({ k = 2 })
      idx:add(42, {1, 0})
      idx:add(99, {10, 0})
      local val = idx:regress({1, 0}, { k = 2, weighted = true })
      T.eq(val, 42)
    end)
  end)

end)
