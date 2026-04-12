if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local flow = require("lib.flow_network")

-- ========================
-- HELPERS
-- ========================

local function set_from_array(arr)
  local s = {}
  for _, v in ipairs(arr) do s[v] = true end
  return s
end

-- ========================
-- TESTS
-- ========================

T.describe("flow_network", function()

  T.describe("max_flow", function()

    T.it("simple 2-path network: max flow = 20", function()
      -- s->a cap 10, s->b cap 10, a->t cap 10, b->t cap 10
      -- Two disjoint paths, each capacity 10 => total 20
      local net = flow.network()
      net:add_edge("s", "a", 10)
      net:add_edge("s", "b", 10)
      net:add_edge("a", "t", 10)
      net:add_edge("b", "t", 10)
      local mf = net:max_flow("s", "t")
      T.eq(mf, 20, "2-path max flow")
    end)

    T.it("bottleneck network: max flow limited by min edge", function()
      -- s->a cap 100, a->b cap 3, b->t cap 100
      -- Bottleneck at a->b means max flow = 3
      local net = flow.network()
      net:add_edge("s", "a", 100)
      net:add_edge("a", "b", 3)
      net:add_edge("b", "t", 100)
      local mf = net:max_flow("s", "t")
      T.eq(mf, 3, "bottleneck max flow")
    end)

    T.it("parallel edges: capacities sum correctly", function()
      -- Two parallel edges s->t: cap 4 and cap 6 => max flow 10
      local net = flow.network()
      net:add_edge("s", "t", 4)
      net:add_edge("s", "t", 6)
      local mf = net:max_flow("s", "t")
      T.eq(mf, 10, "parallel edges")
    end)

    T.it("self-loop does not affect flow", function()
      local net = flow.network()
      net:add_edge("s", "t", 5)
      net:add_edge("a", "a", 10)  -- self-loop, irrelevant
      local mf = net:max_flow("s", "t")
      T.eq(mf, 5, "self-loop ignored")
    end)

    T.it("disconnected graph: max flow = 0", function()
      local net = flow.network()
      net:add_edge("a", "b", 10)  -- no path from s to t
      net:add_edge("c", "d", 10)
      local mf = net:max_flow("s", "t")
      T.eq(mf, 0, "disconnected: max flow 0")
    end)

    T.it("node acting as cut vertex: flow constrained", function()
      -- s->m cap 5, m->t cap 5, plus s->a cap 10, a->t cap 10
      -- but also s->m cap limits one path
      -- Actually test: single bottleneck node by forcing all flow through one edge
      -- s -> x cap 7, x -> t cap 7 (only path) => max flow 7
      local net = flow.network()
      net:add_edge("s", "x", 7)
      net:add_edge("x", "t", 7)
      local mf = net:max_flow("s", "t")
      T.eq(mf, 7, "cut vertex")
    end)

    T.it("edge flows sum correctly at intermediate nodes", function()
      local net = flow.network()
      net:add_edge("s", "a", 10)
      net:add_edge("s", "b", 10)
      net:add_edge("a", "t", 10)
      net:add_edge("b", "t", 10)
      net:add_edge("a", "b", 5)
      local mf, flows = net:max_flow("s", "t")
      T.eq(mf, 20, "diamond max flow")
      -- Verify flows is a table
      T.ok(type(flows) == "table", "flows is table")
      -- Verify total outflow from s = max flow
      local s_out = 0
      for _, f in ipairs(flows) do
        if f.from == "s" then s_out = s_out + f.flow end
      end
      T.eq(s_out, 20, "s outflow = max flow")
    end)

    T.it("reset() clears flow state for re-computation", function()
      local net = flow.network()
      net:add_edge("s", "a", 5)
      net:add_edge("a", "t", 5)
      local mf1 = net:max_flow("s", "t")
      T.eq(mf1, 5)
      net:reset()
      -- After reset, re-adding same edges and recomputing should give same result
      net:add_edge("s", "a", 5)
      net:add_edge("a", "t", 5)
      local mf2 = net:max_flow("s", "t")
      T.eq(mf2, 5, "after reset same result")
    end)

  end)  -- max_flow

  T.describe("min_cut", function()

    T.it("max flow = min cut theorem: values agree", function()
      local net = flow.network()
      net:add_edge("s", "a", 10)
      net:add_edge("s", "b", 10)
      net:add_edge("a", "t", 10)
      net:add_edge("b", "t", 10)
      net:add_edge("a", "b", 5)
      local mf = net:max_flow("s", "t")
      -- Re-create for min_cut (min_cut internally calls max_flow)
      local net2 = flow.network()
      net2:add_edge("s", "a", 10)
      net2:add_edge("s", "b", 10)
      net2:add_edge("a", "t", 10)
      net2:add_edge("b", "t", 10)
      net2:add_edge("a", "b", 5)
      local cut_val, s_side, t_side = net2:min_cut("s", "t")
      T.eq(cut_val, mf, "max flow = min cut")
      -- s in s_side, t in t_side
      local ss = set_from_array(s_side)
      local ts = set_from_array(t_side)
      T.ok(ss["s"], "source in s_side")
      T.ok(ts["t"], "sink in t_side")
    end)

    T.it("min cut partitions all nodes", function()
      local net = flow.network()
      net:add_edge("s", "a", 3)
      net:add_edge("s", "b", 2)
      net:add_edge("a", "t", 2)
      net:add_edge("b", "t", 3)
      net:add_edge("a", "b", 1)
      local _, s_side, t_side = net:min_cut("s", "t")
      -- All nodes appear in exactly one side
      local all = set_from_array({"s", "a", "b", "t"})
      local ss = set_from_array(s_side)
      local ts = set_from_array(t_side)
      for n in pairs(all) do
        local in_s = ss[n] and 1 or 0
        local in_t = ts[n] and 1 or 0
        T.eq(in_s + in_t, 1, n .. " in exactly one side")
      end
    end)

    T.it("bottleneck cut matches bottleneck flow", function()
      local net = flow.network()
      net:add_edge("s", "a", 100)
      net:add_edge("a", "b", 3)
      net:add_edge("b", "t", 100)
      local cut_val = net:min_cut("s", "t")
      T.eq(cut_val, 3, "bottleneck cut = 3")
    end)

  end)  -- min_cut

  T.describe("bipartite_matching", function()

    T.it("finds maximum matching in simple bipartite graph", function()
      -- a can match x or y, b can match y, c can match z
      -- Maximum: a->x (or a->y), b->y, c->z => 3 pairs (or 2 if forced)
      -- a-x, a-y, b-y, c-z: max matching = 3 (a->x, b->y, c->z)
      local matching = flow.bipartite_matching({
        left = {"a", "b", "c"},
        right = {"x", "y", "z"},
        edges = {{"a","x"},{"a","y"},{"b","y"},{"c","z"}},
      })
      T.eq(#matching, 3, "max matching size = 3")
    end)

    T.it("complete bipartite K3,3 has matching of size 3", function()
      local edges = {}
      for _, l in ipairs({"a","b","c"}) do
        for _, r in ipairs({"x","y","z"}) do
          edges[#edges+1] = {l, r}
        end
      end
      local matching = flow.bipartite_matching({
        left = {"a","b","c"},
        right = {"x","y","z"},
        edges = edges,
      })
      T.eq(#matching, 3, "K3,3 matching size = 3")
      -- Verify no left or right node is matched twice
      local used_l = {}
      local used_r = {}
      for _, m in ipairs(matching) do
        T.ok(not used_l[m.left], "left node " .. m.left .. " not duplicated")
        T.ok(not used_r[m.right], "right node " .. m.right .. " not duplicated")
        used_l[m.left] = true
        used_r[m.right] = true
      end
    end)

    T.it("partial matching when right side is limiting", function()
      -- 3 left nodes, 2 right nodes, one can match each
      local matching = flow.bipartite_matching({
        left = {"a","b","c"},
        right = {"x","y"},
        edges = {{"a","x"},{"b","y"},{"c","x"}},
      })
      -- At most 2 matches (only 2 right nodes)
      T.eq(#matching, 2, "partial matching limited by right side")
    end)

    T.it("no edges = empty matching", function()
      local matching = flow.bipartite_matching({
        left = {"a","b"},
        right = {"x","y"},
        edges = {},
      })
      T.eq(#matching, 0, "empty matching")
    end)

    T.it("max_matching_size returns count", function()
      local size = flow.max_matching_size({
        left = {"a","b","c"},
        right = {"x","y","z"},
        edges = {{"a","x"},{"b","y"},{"c","z"}},
      })
      T.eq(size, 3, "max_matching_size = 3")
    end)

    T.it("perfect matching when possible", function()
      -- Perfect 1-1 matching available
      local matching = flow.bipartite_matching({
        left = {"1","2","3"},
        right = {"4","5","6"},
        edges = {{"1","4"},{"2","5"},{"3","6"}},
      })
      T.eq(#matching, 3, "perfect matching")
    end)

  end)  -- bipartite_matching

  T.describe("min_cost_flow", function()

    T.it("prefers cheaper paths", function()
      -- Two paths s->t:
      --   s->a->t: capacity 5, cost 1 per unit
      --   s->b->t: capacity 5, cost 10 per unit
      -- Min cost flow should use the cheap path first
      local net = flow.network()
      net:add_edge("s", "a", 5, {cost=1})
      net:add_edge("a", "t", 5, {cost=1})
      net:add_edge("s", "b", 5, {cost=10})
      net:add_edge("b", "t", 5, {cost=10})
      local fval, cost = net:min_cost_flow("s", "t", {max_flow=5})
      T.eq(fval, 5, "flow value = 5")
      T.eq(cost, 10, "cost = 10 (cheap path: 5 units * cost 2)")
    end)

    T.it("uses expensive path when cheap is saturated", function()
      local net = flow.network()
      net:add_edge("s", "a", 3, {cost=1})
      net:add_edge("a", "t", 3, {cost=1})
      net:add_edge("s", "b", 5, {cost=5})
      net:add_edge("b", "t", 5, {cost=5})
      -- Send 6 units: 3 cheap (cost 6) + 3 expensive (cost 30) = 36
      local fval, cost = net:min_cost_flow("s", "t", {max_flow=6})
      T.eq(fval, 6, "flow value = 6")
      T.eq(cost, 3*2 + 3*10, "cost = 36")
    end)

    T.it("zero flow when disconnected", function()
      local net = flow.network()
      net:add_edge("a", "b", 10, {cost=1})
      local fval, cost = net:min_cost_flow("s", "t")
      T.eq(fval, 0, "no flow when disconnected")
      T.eq(cost, 0, "zero cost")
    end)

  end)  -- min_cost_flow

  T.describe("module", function()

    T.it("has _tier = pure", function()
      T.eq(flow._tier, "pure")
    end)

  end)

end)  -- flow_network
