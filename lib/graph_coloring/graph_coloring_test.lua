if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local GC = require("lib.graph_coloring")

-- ========================
-- TEST GRAPHS
-- ========================

-- K3 (triangle): 3 nodes, all connected; chromatic number = 3
local k3 = {
  [1] = { 2, 3 },
  [2] = { 1, 3 },
  [3] = { 1, 2 },
}

-- K4 (complete 4): chromatic number = 4
local k4 = {
  [1] = { 2, 3, 4 },
  [2] = { 1, 3, 4 },
  [3] = { 1, 2, 4 },
  [4] = { 1, 2, 3 },
}

-- C5 (5-cycle): chromatic number = 3 (odd cycle)
local c5 = {
  [1] = { 2, 5 },
  [2] = { 1, 3 },
  [3] = { 2, 4 },
  [4] = { 3, 5 },
  [5] = { 4, 1 },
}

-- C6 (6-cycle): chromatic number = 2 (even cycle, bipartite)
local c6 = {
  [1] = { 2, 6 },
  [2] = { 1, 3 },
  [3] = { 2, 4 },
  [4] = { 3, 5 },
  [5] = { 4, 6 },
  [6] = { 5, 1 },
}

-- Path graph P4: 1-2-3-4, bipartite, chromatic number = 2
local p4 = {
  [1] = { 2 },
  [2] = { 1, 3 },
  [3] = { 2, 4 },
  [4] = { 3 },
}

-- Single node, no edges: chromatic number = 1
local single = {
  [1] = {},
}

-- Petersen graph: 10 nodes, 3-regular, chromatic number = 3
-- Outer 5-cycle: 1-2-3-4-5-1
-- Inner pentagram: 6-8-10-7-9-6
-- Spokes: 1-6, 2-7, 3-8, 4-9, 5-10
local petersen = {
  [1]  = { 2, 5, 6 },
  [2]  = { 1, 3, 7 },
  [3]  = { 2, 4, 8 },
  [4]  = { 3, 5, 9 },
  [5]  = { 4, 1, 10 },
  [6]  = { 1, 8, 9 },
  [7]  = { 2, 9, 10 },
  [8]  = { 3, 6, 10 },
  [9]  = { 4, 6, 7 },
  [10] = { 5, 7, 8 },
}

-- Empty graph (no nodes)
local empty = {}

-- ========================
-- HELPER: check edge coloring validity
-- Returns true if no two edges incident on the same vertex share a color.
local function edge_color_valid(graph, ec)
  -- for each node, collect colors of all incident edges
  for u, neighbors in pairs(graph) do
    local seen = {}
    for _, v in ipairs(neighbors) do
      local a, b = u, v
      if a > b then a, b = b, a end
      local key = a .. "," .. b
      local c = ec[key]
      if c then
        if seen[c] then return false end
        seen[c] = true
      end
    end
  end
  return true
end

-- Max degree of graph
local function max_degree(graph)
  local m = 0
  for _, neighbors in pairs(graph) do
    if #neighbors > m then m = #neighbors end
  end
  return m
end

-- Count distinct colors in edge coloring
local function edge_color_count(ec)
  local seen = {}
  local n = 0
  for _, c in pairs(ec) do
    if not seen[c] then seen[c] = true; n = n + 1 end
  end
  return n
end

-- ========================
-- TESTS: _tier
-- ========================

T.describe("graph_coloring module", function()
  T.it("has _tier = pure", function()
    T.eq(GC._tier, "pure")
  end)
end)

-- ========================
-- TESTS: greedy
-- ========================

T.describe("greedy coloring", function()
  T.it("produces valid coloring for K3", function()
    local c = GC.greedy(k3)
    T.ok(GC.valid(k3, c))
  end)

  T.it("uses exactly 3 colors for K3", function()
    local c = GC.greedy(k3)
    T.eq(GC.num_colors(c), 3)
  end)

  T.it("produces valid coloring for K4", function()
    local c = GC.greedy(k4)
    T.ok(GC.valid(k4, c))
  end)

  T.it("uses exactly 4 colors for K4", function()
    local c = GC.greedy(k4)
    T.eq(GC.num_colors(c), 4)
  end)

  T.it("produces valid coloring for C5", function()
    local c = GC.greedy(c5)
    T.ok(GC.valid(c5, c))
  end)

  T.it("uses ≤ 3 colors for C5", function()
    local c = GC.greedy(c5)
    T.ok(GC.num_colors(c) <= 3)
  end)

  T.it("produces valid coloring for C6", function()
    local c = GC.greedy(c6)
    T.ok(GC.valid(c6, c))
  end)

  T.it("produces valid coloring for Petersen graph", function()
    local c = GC.greedy(petersen)
    T.ok(GC.valid(petersen, c))
  end)

  T.it("handles single node", function()
    local c = GC.greedy(single)
    T.eq(c[1], 1)
    T.ok(GC.valid(single, c))
  end)

  T.it("handles empty graph", function()
    local c = GC.greedy(empty)
    T.eq(GC.num_colors(c), 0)
  end)

  T.it("produces valid coloring for path P4", function()
    local c = GC.greedy(p4)
    T.ok(GC.valid(p4, c))
  end)
end)

-- ========================
-- TESTS: dsatur
-- ========================

T.describe("DSatur coloring", function()
  T.it("produces valid coloring for K3", function()
    local c = GC.dsatur(k3)
    T.ok(GC.valid(k3, c))
  end)

  T.it("uses exactly 3 colors for K3", function()
    local c = GC.dsatur(k3)
    T.eq(GC.num_colors(c), 3)
  end)

  T.it("produces valid coloring for K4", function()
    local c = GC.dsatur(k4)
    T.ok(GC.valid(k4, c))
  end)

  T.it("uses exactly 4 colors for K4", function()
    local c = GC.dsatur(k4)
    T.eq(GC.num_colors(c), 4)
  end)

  T.it("produces valid coloring for C5", function()
    local c = GC.dsatur(c5)
    T.ok(GC.valid(c5, c))
  end)

  T.it("uses ≤ greedy colors for C5", function()
    local dsat = GC.num_colors(GC.dsatur(c5))
    local greedy = GC.num_colors(GC.greedy(c5))
    T.ok(dsat <= greedy)
  end)

  T.it("produces valid coloring for C6", function()
    local c = GC.dsatur(c6)
    T.ok(GC.valid(c6, c))
  end)

  T.it("uses 2 colors for C6 (bipartite)", function()
    local c = GC.dsatur(c6)
    T.eq(GC.num_colors(c), 2)
  end)

  T.it("produces valid coloring for Petersen graph", function()
    local c = GC.dsatur(petersen)
    T.ok(GC.valid(petersen, c))
  end)

  T.it("uses ≤ greedy colors for Petersen graph", function()
    local dsat = GC.num_colors(GC.dsatur(petersen))
    local greedy = GC.num_colors(GC.greedy(petersen))
    T.ok(dsat <= greedy)
  end)

  T.it("handles empty graph", function()
    local c = GC.dsatur(empty)
    T.eq(GC.num_colors(c), 0)
  end)
end)

-- ========================
-- TESTS: backtrack
-- ========================

T.describe("backtrack coloring", function()
  T.it("K3 is 3-colorable", function()
    local c, ok = GC.backtrack(k3, 3)
    T.ok(ok)
    T.ok(GC.valid(k3, c))
  end)

  T.it("K3 is not 2-colorable", function()
    local _, ok = GC.backtrack(k3, 2)
    T.ok(not ok)
  end)

  T.it("K4 is 4-colorable", function()
    local c, ok = GC.backtrack(k4, 4)
    T.ok(ok)
    T.ok(GC.valid(k4, c))
  end)

  T.it("K4 is not 3-colorable", function()
    local _, ok = GC.backtrack(k4, 3)
    T.ok(not ok)
  end)

  T.it("C5 is 3-colorable", function()
    local c, ok = GC.backtrack(c5, 3)
    T.ok(ok)
    T.ok(GC.valid(c5, c))
  end)

  T.it("C5 is not 2-colorable", function()
    local _, ok = GC.backtrack(c5, 2)
    T.ok(not ok)
  end)

  T.it("C6 is 2-colorable", function()
    local c, ok = GC.backtrack(c6, 2)
    T.ok(ok)
    T.ok(GC.valid(c6, c))
  end)

  T.it("C6 is not 1-colorable", function()
    local _, ok = GC.backtrack(c6, 1)
    T.ok(not ok)
  end)

  T.it("single node is 1-colorable", function()
    local c, ok = GC.backtrack(single, 1)
    T.ok(ok)
    T.eq(c[1], 1)
  end)

  T.it("empty graph returns empty coloring", function()
    local c, ok = GC.backtrack(empty, 1)
    T.ok(ok)
    T.eq(GC.num_colors(c), 0)
  end)
end)

-- ========================
-- TESTS: chromatic_number
-- ========================

T.describe("chromatic_number", function()
  T.it("K3 has chromatic number 3", function()
    T.eq(GC.chromatic_number(k3), 3)
  end)

  T.it("K4 has chromatic number 4", function()
    T.eq(GC.chromatic_number(k4), 4)
  end)

  T.it("C5 has chromatic number 3", function()
    T.eq(GC.chromatic_number(c5), 3)
  end)

  T.it("C6 has chromatic number 2", function()
    T.eq(GC.chromatic_number(c6), 2)
  end)

  T.it("single node has chromatic number 1", function()
    T.eq(GC.chromatic_number(single), 1)
  end)

  T.it("path P4 has chromatic number 2", function()
    T.eq(GC.chromatic_number(p4), 2)
  end)
end)

-- ========================
-- TESTS: valid
-- ========================

T.describe("valid coloring check", function()
  T.it("correctly validates a good K3 coloring", function()
    T.ok(GC.valid(k3, { [1]=1, [2]=2, [3]=3 }))
  end)

  T.it("correctly rejects a bad K3 coloring (two adjacent same color)", function()
    T.ok(not GC.valid(k3, { [1]=1, [2]=1, [3]=2 }))
  end)

  T.it("correctly validates a good C6 2-coloring", function()
    T.ok(GC.valid(c6, { [1]=1, [2]=2, [3]=1, [4]=2, [5]=1, [6]=2 }))
  end)

  T.it("correctly rejects adjacent same-color in C6", function()
    T.ok(not GC.valid(c6, { [1]=1, [2]=1, [3]=2, [4]=1, [5]=2, [6]=1 }))
  end)

  T.it("empty graph with empty coloring is valid", function()
    T.ok(GC.valid(empty, {}))
  end)
end)

-- ========================
-- TESTS: num_colors
-- ========================

T.describe("num_colors", function()
  T.it("counts 3 colors", function()
    T.eq(GC.num_colors({ [1]=1, [2]=2, [3]=3 }), 3)
  end)

  T.it("counts 1 color", function()
    T.eq(GC.num_colors({ [1]=1, [2]=1, [3]=1 }), 1)
  end)

  T.it("counts 0 for empty", function()
    T.eq(GC.num_colors({}), 0)
  end)

  T.it("counts 2 distinct colors correctly", function()
    T.eq(GC.num_colors({ [1]=1, [2]=2, [3]=1, [4]=2 }), 2)
  end)
end)

-- ========================
-- TESTS: is_bipartite
-- ========================

T.describe("is_bipartite", function()
  T.it("C6 is bipartite", function()
    local bip, _ = GC.is_bipartite(c6)
    T.ok(bip)
  end)

  T.it("C6 bipartite coloring uses 2 colors", function()
    local bip, col = GC.is_bipartite(c6)
    T.ok(bip)
    T.eq(GC.num_colors(col), 2)
    T.ok(GC.valid(c6, col))
  end)

  T.it("K3 is not bipartite", function()
    local bip, col = GC.is_bipartite(k3)
    T.ok(not bip)
    T.ok(col == nil)
  end)

  T.it("path P4 is bipartite", function()
    local bip, col = GC.is_bipartite(p4)
    T.ok(bip)
    T.ok(GC.valid(p4, col))
  end)

  T.it("path P4 2-coloring is valid", function()
    local _, col = GC.is_bipartite(p4)
    T.eq(GC.num_colors(col), 2)
  end)

  T.it("single node is bipartite", function()
    local bip, col = GC.is_bipartite(single)
    T.ok(bip)
    T.ok(col ~= nil)
  end)

  T.it("C5 is not bipartite", function()
    local bip, _ = GC.is_bipartite(c5)
    T.ok(not bip)
  end)

  T.it("empty graph is bipartite", function()
    local bip, col = GC.is_bipartite(empty)
    T.ok(bip)
    T.ok(col ~= nil)
  end)
end)

-- ========================
-- TESTS: edge_color
-- ========================

T.describe("edge coloring", function()
  T.it("K3 edge coloring is valid", function()
    local ec = GC.edge_color(k3)
    T.ok(edge_color_valid(k3, ec))
  end)

  T.it("K3 edge coloring uses Δ or Δ+1 colors", function()
    local ec = GC.edge_color(k3)
    local delta = max_degree(k3)  -- 2
    local nc = edge_color_count(ec)
    T.ok(nc >= delta and nc <= delta + 1)
  end)

  T.it("K4 edge coloring is valid", function()
    local ec = GC.edge_color(k4)
    T.ok(edge_color_valid(k4, ec))
  end)

  T.it("K4 edge coloring uses Δ or Δ+1 colors", function()
    local ec = GC.edge_color(k4)
    local delta = max_degree(k4)  -- 3
    local nc = edge_color_count(ec)
    T.ok(nc >= delta and nc <= delta + 1)
  end)

  T.it("C5 edge coloring is valid", function()
    local ec = GC.edge_color(c5)
    T.ok(edge_color_valid(c5, ec))
  end)

  T.it("C5 edge coloring uses Δ or Δ+1 colors", function()
    local ec = GC.edge_color(c5)
    local delta = max_degree(c5)  -- 2
    local nc = edge_color_count(ec)
    T.ok(nc >= delta and nc <= delta + 1)
  end)

  T.it("C6 edge coloring is valid", function()
    local ec = GC.edge_color(c6)
    T.ok(edge_color_valid(c6, ec))
  end)

  T.it("C6 edge coloring uses 2 colors (bipartite, Δ=2)", function()
    local ec = GC.edge_color(c6)
    T.eq(edge_color_count(ec), 2)
  end)

  T.it("Petersen edge coloring is valid", function()
    local ec = GC.edge_color(petersen)
    T.ok(edge_color_valid(petersen, ec))
  end)

  T.it("Petersen edge coloring uses Δ or Δ+1 colors", function()
    local ec = GC.edge_color(petersen)
    local delta = max_degree(petersen)  -- 3
    local nc = edge_color_count(ec)
    T.ok(nc >= delta and nc <= delta + 1)
  end)

  T.it("empty graph has no edge colors", function()
    local ec = GC.edge_color(empty)
    T.eq(edge_color_count(ec), 0)
  end)
end)

-- ========================
-- TESTS: map_color
-- ========================

T.describe("map coloring", function()
  T.it("K3 map coloring is valid", function()
    local c = GC.map_color(k3)
    T.ok(GC.valid(k3, c))
  end)

  T.it("K4 map coloring is valid and uses ≤ 4 colors", function()
    local c = GC.map_color(k4)
    T.ok(GC.valid(k4, c))
    T.ok(GC.num_colors(c) <= 4)
  end)

  T.it("C6 map coloring is valid", function()
    local c = GC.map_color(c6)
    T.ok(GC.valid(c6, c))
  end)
end)

-- ========================
-- TESTS: register_alloc
-- ========================

T.describe("register allocation", function()
  -- interference graph: 3 variables, all interfere (triangle)
  local ig3 = {
    [1] = { 2, 3 },
    [2] = { 1, 3 },
    [3] = { 1, 2 },
  }

  T.it("fits K3 in 3 registers", function()
    local alloc, spilled = GC.register_alloc(ig3, 3)
    T.eq(#spilled, 0)
    T.ok(GC.valid(ig3, alloc))
  end)

  T.it("K3 with 3 registers uses exactly 3 registers", function()
    local alloc, _ = GC.register_alloc(ig3, 3)
    T.eq(GC.num_colors(alloc), 3)
  end)

  T.it("K3 with 2 registers spills at least 1 variable", function()
    local _, spilled = GC.register_alloc(ig3, 2)
    T.ok(#spilled >= 1)
  end)

  T.it("spilled variables have nil register", function()
    local alloc, spilled = GC.register_alloc(ig3, 2)
    for _, v in ipairs(spilled) do
      T.ok(alloc[v] == nil)
    end
  end)

  -- path interference (chain): can fit in 2 registers
  local ig_path = {
    [1] = { 2 },
    [2] = { 1, 3 },
    [3] = { 2, 4 },
    [4] = { 3 },
  }

  T.it("path interference graph fits in 2 registers", function()
    local alloc, spilled = GC.register_alloc(ig_path, 2)
    T.eq(#spilled, 0)
    T.ok(GC.valid(ig_path, alloc))
  end)

  T.it("non-interfering variables can share a register", function()
    -- 1 and 3 don't interfere, so they can share a register
    local alloc, spilled = GC.register_alloc(ig_path, 2)
    T.eq(#spilled, 0)
    T.ok(alloc[1] == alloc[3] or alloc[2] == alloc[4])
  end)

  T.it("K4 with 4 registers: no spills", function()
    local alloc, spilled = GC.register_alloc(k4, 4)
    T.eq(#spilled, 0)
    T.ok(GC.valid(k4, alloc))
  end)

  T.it("K4 with 3 registers: spills at least 1", function()
    local _, spilled = GC.register_alloc(k4, 3)
    T.ok(#spilled >= 1)
  end)

  T.it("empty interference graph: no spills", function()
    local alloc, spilled = GC.register_alloc(empty, 4)
    T.eq(#spilled, 0)
    T.eq(GC.num_colors(alloc), 0)
  end)
end)
