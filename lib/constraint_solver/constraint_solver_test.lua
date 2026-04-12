if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local csp = require("lib.constraint_solver")

-- Helper: check that a coloring solution is valid (no adjacent same color)
local function valid_coloring(sol, adj)
  for _, pair in ipairs(adj) do
    if sol[pair[1]] == sol[pair[2]] then return false end
  end
  return true
end

-- Helper: check all-different
local function all_different_check(sol, vars)
  local seen = {}
  for _, v in ipairs(vars) do
    if seen[sol[v]] then return false end
    seen[sol[v]] = true
  end
  return true
end

T.describe("constraint_solver", function()

  T.it("map coloring: Australia with 4 colors", function()
    local colors = {"red", "green", "blue", "yellow"}
    local states = {"WA", "NT", "SA", "Q", "NSW", "V", "T"}
    local adj = {
      {"WA", "NT"}, {"WA", "SA"},
      {"NT", "SA"}, {"NT", "Q"},
      {"SA", "Q"}, {"SA", "NSW"}, {"SA", "V"},
      {"Q", "NSW"},
      {"NSW", "V"},
    }

    local p = csp.problem()
    for _, s in ipairs(states) do
      p:variable(s, colors)
    end
    for _, pair in ipairs(adj) do
      p:not_equal(pair[1], pair[2])
    end

    local sol = p:solve()
    T.ok(sol ~= nil, "should find a coloring")
    T.ok(valid_coloring(sol, adj), "coloring must be valid")
    -- Tasmania is isolated, can be any color
    T.ok(sol["T"] ~= nil, "all states assigned")
  end)

  T.it("all_different: 4-queens finds exactly 2 solutions", function()
    -- N-queens for N=4: place 4 queens on 4x4 board, one per row
    -- Variables: Q1..Q4 (column position of queen in row i)
    -- All different columns, and no two on same diagonal
    local n = 4
    local p = csp.problem()
    local vars = {}
    local domain = {}
    for i = 1, n do domain[i] = i end
    for i = 1, n do
      vars[i] = "Q" .. i
      p:variable("Q" .. i, domain)
    end
    p:all_different(vars)
    -- Diagonal constraints: |Qi - Qj| ~= |i - j|
    for i = 1, n do
      for j = i + 1, n do
        local diff = j - i
        p:constraint("Q" .. i, "Q" .. j, function(qi, qj)
          return math.abs(qi - qj) ~= diff
        end)
      end
    end

    local all = p:solve_all()
    T.eq(#all, 2, "4-queens has exactly 2 solutions")
    for _, sol in ipairs(all) do
      T.ok(all_different_check(sol, vars), "columns all different")
    end
  end)

  T.it("arithmetic constraint: X+Y=10 from domain 1..9", function()
    local domain = {1,2,3,4,5,6,7,8,9}
    local p = csp.problem()
    p:variable("X", domain)
    p:variable("Y", domain)
    p:constraint("X", "Y", function(x, y) return x + y == 10 end)

    local sol = p:solve()
    T.ok(sol ~= nil, "should find solution")
    T.eq(sol["X"] + sol["Y"], 10, "X+Y must equal 10")
  end)

  T.it("arithmetic constraint: solve_all finds all X+Y=10 pairs", function()
    local domain = {1,2,3,4,5,6,7,8,9}
    local p = csp.problem()
    p:variable("X", domain)
    p:variable("Y", domain)
    p:constraint("X", "Y", function(x, y) return x + y == 10 end)

    local all = p:solve_all()
    -- Pairs: (1,9),(2,8),(3,7),(4,6),(5,5),(6,4),(7,3),(8,2),(9,1) = 9 solutions
    T.eq(#all, 9, "should find all 9 X+Y=10 pairs")
    for _, sol in ipairs(all) do
      T.eq(sol["X"] + sol["Y"], 10, "each solution satisfies X+Y=10")
    end
  end)

  T.it("unary constraints: domain filtering", function()
    local p = csp.problem()
    p:variable("X", {1, 2, 3, 4, 5, 6, 7, 8, 9, 10})
    p:unary("X", function(v) return v % 2 == 0 end)  -- even only
    p:unary("X", function(v) return v > 4 end)        -- > 4

    local all = p:solve_all()
    -- Even values > 4 in 1..10: 6, 8, 10 → 3 solutions (single-variable)
    T.eq(#all, 3, "should have 3 solutions")
    for _, sol in ipairs(all) do
      T.ok(sol["X"] % 2 == 0, "X must be even")
      T.ok(sol["X"] > 4, "X must be > 4")
    end
  end)

  T.it("not_equal: basic constraint", function()
    local p = csp.problem()
    p:variable("X", {1, 2, 3})
    p:variable("Y", {1, 2, 3})
    p:not_equal("X", "Y")

    local all = p:solve_all()
    -- 3*3=9 pairs minus 3 equal pairs = 6 solutions
    T.eq(#all, 6, "should find 6 solutions")
    for _, sol in ipairs(all) do
      T.neq(sol["X"], sol["Y"], "X must not equal Y")
    end
  end)

  T.it("less_than: X < Y", function()
    local p = csp.problem()
    p:variable("X", {1, 2, 3, 4})
    p:variable("Y", {1, 2, 3, 4})
    p:less_than("X", "Y")

    local all = p:solve_all()
    -- Pairs where x<y: (1,2),(1,3),(1,4),(2,3),(2,4),(3,4) = 6
    T.eq(#all, 6, "should find 6 solutions")
    for _, sol in ipairs(all) do
      T.ok(sol["X"] < sol["Y"], "X must be less than Y")
    end
  end)

  T.it("greater_than: X > Y", function()
    local p = csp.problem()
    p:variable("X", {1, 2, 3, 4})
    p:variable("Y", {1, 2, 3, 4})
    p:greater_than("X", "Y")

    local all = p:solve_all()
    T.eq(#all, 6, "should find 6 solutions (symmetric with less_than)")
    for _, sol in ipairs(all) do
      T.ok(sol["X"] > sol["Y"], "X must be greater than Y")
    end
  end)

  T.it("unsatisfiable: returns nil", function()
    local p = csp.problem()
    p:variable("X", {1})
    p:variable("Y", {1})
    p:not_equal("X", "Y")

    local sol = p:solve()
    T.fail(sol, "unsatisfiable CSP should return nil")
  end)

  T.it("solve_all on small problem finds all solutions", function()
    local p = csp.problem()
    p:variable("A", {1, 2})
    p:variable("B", {1, 2})
    -- No constraints: 2*2 = 4 solutions
    local all = p:solve_all()
    T.eq(#all, 4, "should find all 4 combinations")
  end)

  T.it("solve_all with limit", function()
    local p = csp.problem()
    p:variable("A", {1, 2, 3})
    p:variable("B", {1, 2, 3})
    -- 9 total; limit to 3
    local all = p:solve_all({ limit = 3 })
    T.eq(#all, 3, "should stop at limit")
  end)

  T.it("AC-3 reduces domains: X in {1,2,3}, Y in {5,6}, X < Y", function()
    -- After AC-3, X's domain should still be {1,2,3} (all < 5 or 6)
    -- but verify by checking solve_all count = 3*2 = 6
    local p = csp.problem()
    p:variable("X", {1, 2, 3})
    p:variable("Y", {5, 6})
    p:less_than("X", "Y")

    local all = p:solve_all()
    -- All 3 X values are < both 5 and 6, so 6 solutions
    T.eq(#all, 6, "all combinations satisfy X<Y")

    -- Test that AC-3 removes values from domain when needed
    local p2 = csp.problem()
    -- X in {1,2,3,10}, Y in {5,6}, X < Y
    -- AC-3 should eliminate X=10 (no Y in {5,6} satisfies 10 < Y)
    p2:variable("X", {1, 2, 3, 10})
    p2:variable("Y", {5, 6})
    p2:less_than("X", "Y")

    local all2 = p2:solve_all()
    -- X=10 is eliminated, so 3*2=6 solutions
    T.eq(#all2, 6, "AC-3 should eliminate X=10 (no support in Y domain)")

    -- Verify X=10 never appears in solutions
    for _, sol in ipairs(all2) do
      T.neq(sol["X"], 10, "X=10 should be arc-inconsistent")
    end
  end)

  T.it("MRV: variable with smallest domain chosen first", function()
    -- Verify MRV by solving a problem where choosing the wrong variable first
    -- would fail quickly. We check solve() returns a valid solution.
    local p = csp.problem()
    -- X has domain {3}, Y has domain {1,2,3}, Z has domain {1,2,3}
    -- Constraint: X != Y, X != Z
    -- MRV should pick X first (domain size 1)
    p:variable("X", {3})
    p:variable("Y", {1, 2, 3})
    p:variable("Z", {1, 2, 3})
    p:not_equal("X", "Y")
    p:not_equal("X", "Z")

    local sol = p:solve()
    T.ok(sol ~= nil, "should find solution")
    T.eq(sol["X"], 3, "X must be 3")
    T.neq(sol["Y"], 3, "Y must not equal X")
    T.neq(sol["Z"], 3, "Z must not equal X")
  end)

  T.it("N-queens 6x6: finds valid placement", function()
    local n = 6
    local p = csp.problem()
    local vars = {}
    local domain = {}
    for i = 1, n do domain[i] = i end
    for i = 1, n do
      vars[i] = "Q" .. i
      p:variable("Q" .. i, domain)
    end
    p:all_different(vars)
    for i = 1, n do
      for j = i + 1, n do
        local diff = j - i
        p:constraint("Q" .. i, "Q" .. j, function(qi, qj)
          return math.abs(qi - qj) ~= diff
        end)
      end
    end

    local sol = p:solve()
    T.ok(sol ~= nil, "6-queens should have a solution")

    -- Verify solution is valid
    local cols = {}
    for i = 1, n do cols[i] = sol["Q" .. i] end

    -- Check all different columns
    local seen = {}
    for _, c in ipairs(cols) do
      T.fail(seen[c], "columns must all be different")
      seen[c] = true
    end

    -- Check no diagonal attacks
    for i = 1, n do
      for j = i + 1, n do
        T.neq(math.abs(cols[i] - cols[j]), j - i, "no diagonal attack between Q" .. i .. " and Q" .. j)
      end
    end
  end)

  T.it("arithmetic (ternary): X+Y=Z", function()
    local domain = {1,2,3,4,5}
    local p = csp.problem()
    p:variable("X", domain)
    p:variable("Y", domain)
    p:variable("Z", domain)
    p:arithmetic("X", "Y", "Z", function(x, y, z) return x + y == z end)

    local all = p:solve_all()
    T.ok(#all > 0, "should find solutions for X+Y=Z")
    for _, sol in ipairs(all) do
      T.eq(sol["X"] + sol["Y"], sol["Z"], "X+Y must equal Z")
    end
  end)

  T.it("three-variable chain: X!=Y, Y!=Z, X+Z=6", function()
    local domain = {1,2,3,4,5}
    local p = csp.problem()
    p:variable("X", domain)
    p:variable("Y", domain)
    p:variable("Z", domain)
    p:not_equal("X", "Y")
    p:not_equal("Y", "Z")
    p:constraint("X", "Z", function(x, z) return x + z == 6 end)

    local sol = p:solve()
    T.ok(sol ~= nil, "should find solution")
    T.neq(sol["X"], sol["Y"], "X != Y")
    T.neq(sol["Y"], sol["Z"], "Y != Z")
    T.eq(sol["X"] + sol["Z"], 6, "X+Z=6")
  end)

end)
