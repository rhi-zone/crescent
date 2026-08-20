if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local sat = require("lib.sat")

-- ---------------------------------------------------------------------------
-- Basic solve
-- ---------------------------------------------------------------------------

T.describe("sat.solve", function()
  T.it("simple 2-variable SAT", function()
    -- x1 OR x2
    local r = sat.solve({ clauses = { {1, 2} }, vars = 2 })
    T.ok(r.sat, "should be satisfiable")
    T.ok(r.assignment ~= nil, "should have assignment")
    -- Verify assignment satisfies the clause
    T.ok(r.assignment[1] or r.assignment[2], "x1 or x2 must be true")
  end)

  T.it("UNSAT formula", function()
    -- x AND NOT x
    local r = sat.solve({
      clauses = { {1}, {-1} },
      vars = 1,
    })
    T.ok(not r.sat, "should be unsatisfiable")
  end)

  T.it("empty formula (no clauses) is SAT", function()
    local r = sat.solve({ clauses = {}, vars = 2 })
    T.ok(r.sat, "empty formula is trivially satisfiable")
    T.ok(r.assignment ~= nil, "should have assignment")
  end)

  T.it("unit clause forces variable", function()
    -- x1 must be true
    local r = sat.solve({ clauses = { {1} }, vars = 1 })
    T.ok(r.sat, "should be satisfiable")
    T.eq(r.assignment[1], true, "x1 must be true")
  end)

  T.it("unit clause forces negation", function()
    local r = sat.solve({ clauses = { {-1} }, vars = 1 })
    T.ok(r.sat, "should be satisfiable")
    T.eq(r.assignment[1], false, "x1 must be false")
  end)
end)

-- ---------------------------------------------------------------------------
-- 3-coloring of a triangle graph
-- ---------------------------------------------------------------------------
-- Three nodes: 0,1,2 (edges 0-1, 1-2, 0-2)
-- Three colors: R, G, B
-- Variable encoding: node i, color c → var(i*3 + c + 1)
-- node 0: vars 1(R), 2(G), 3(B)
-- node 1: vars 4(R), 5(G), 6(B)
-- node 2: vars 7(R), 8(G), 9(B)

T.describe("3-coloring", function()
  T.it("triangle graph is 3-colorable", function()
    local clauses = {}

    -- Each node gets at least one color
    local function node_vars(n) return {n*3+1, n*3+2, n*3+3} end
    for n = 0, 2 do
      -- at_least_one
      local alo = sat.encodings.at_least_one(node_vars(n))
      for _, c in ipairs(alo) do clauses[#clauses+1] = c end
      -- at_most_one
      local amo = sat.encodings.at_most_one(node_vars(n))
      for _, c in ipairs(amo) do clauses[#clauses+1] = c end
    end

    -- Adjacent nodes differ: for each edge and each color,
    -- NOT (nodeA_color AND nodeB_color)
    local edges = { {0,1}, {1,2}, {0,2} }
    for _, e in ipairs(edges) do
      local a, b = e[1], e[2]
      for c = 1, 3 do
        clauses[#clauses+1] = { -(a*3+c), -(b*3+c) }
      end
    end

    local r = sat.solve({ clauses = clauses, vars = 9 })
    T.ok(r.sat, "triangle should be 3-colorable")

    -- Verify: each node has exactly one color and adjacent nodes differ
    for n = 0, 2 do
      local nv = node_vars(n)
      local color = nil
      for _, v in ipairs(nv) do
        if r.assignment[v] then
          T.ok(color == nil, "node should have at most one color")
          color = v
        end
      end
      T.ok(color ~= nil, "node should have at least one color")
    end
    -- Check edges
    for _, e in ipairs(edges) do
      local a, b = e[1], e[2]
      for c = 1, 3 do
        T.ok(not (r.assignment[a*3+c] and r.assignment[b*3+c]),
          "adjacent nodes must differ on color " .. c)
      end
    end
  end)
end)

-- ---------------------------------------------------------------------------
-- Pigeonhole principle (3 pigeons, 2 holes) — UNSAT
-- ---------------------------------------------------------------------------
-- var(p, h) = p*2 + h + 1  (p in 0..2, h in 0..1)

T.describe("pigeonhole", function()
  T.it("3 pigeons 2 holes is UNSAT", function()
    local clauses = {}
    local np, nh = 3, 2

    -- Each pigeon in at least one hole
    for p = 0, np-1 do
      local lits = {}
      for h = 0, nh-1 do lits[#lits+1] = p*nh + h + 1 end
      clauses[#clauses+1] = lits
    end

    -- No two pigeons share a hole
    for h = 0, nh-1 do
      for p1 = 0, np-1 do
        for p2 = p1+1, np-1 do
          clauses[#clauses+1] = { -(p1*nh + h + 1), -(p2*nh + h + 1) }
        end
      end
    end

    local r = sat.solve({ clauses = clauses, vars = np*nh })
    T.ok(not r.sat, "pigeonhole should be UNSAT")
  end)
end)

-- ---------------------------------------------------------------------------
-- Named formula API
-- ---------------------------------------------------------------------------

T.describe("formula builder", function()
  T.it("named variables work", function()
    local f = sat.formula()
    local x = f:var("x")
    local y = f:var("y")
    local z = f:var("z")
    f:clause(x, y)      -- x OR y
    f:clause(-x, z)     -- NOT x OR z
    f:clause(-y, -z)    -- NOT y OR NOT z

    local r = f:solve()
    T.ok(r.sat, "should be satisfiable")
    -- Verify named assignment satisfies clauses
    local ax = r.assignment.x
    local ay = r.assignment.y
    local az = r.assignment.z
    T.ok(ax or ay,         "x OR y")
    T.ok((not ax) or az,   "NOT x OR z")
    T.ok((not ay) or (not az), "NOT y OR NOT z")
  end)
end)

-- ---------------------------------------------------------------------------
-- Encodings
-- ---------------------------------------------------------------------------

T.describe("encodings.at_most_one", function()
  T.it("allows zero or one true", function()
    local f = sat.formula()
    local a = f:var("a")
    local b = f:var("b")
    local c = f:var("c")
    local amo = sat.encodings.at_most_one({a, b, c})
    for _, cl in ipairs(amo) do f:clause(unpack(cl)) end
    -- Force a=true to check b and c must be false
    f:clause(a)
    local r = f:solve()
    T.ok(r.sat, "SAT with a=true")
    T.eq(r.assignment.a, true, "a is true")
    T.eq(r.assignment.b, false, "b must be false")
    T.eq(r.assignment.c, false, "c must be false")
  end)
end)

T.describe("encodings.exactly_one", function()
  T.it("exactly one of three vars is true", function()
    -- enumerate all solutions and check each has exactly one true
    local vars = 3
    local eo = sat.encodings.exactly_one({1, 2, 3})
    local solutions = sat.solve_all({ clauses = eo, vars = vars })
    T.eq(#solutions, 3, "exactly 3 solutions for exactly_one of 3")
    for _, asgn in ipairs(solutions) do
      local count = 0
      for v = 1, vars do if asgn[v] then count = count + 1 end end
      T.eq(count, 1, "exactly one variable true per solution")
    end
  end)
end)

-- ---------------------------------------------------------------------------
-- solve_all and count
-- ---------------------------------------------------------------------------

T.describe("solve_all", function()
  T.it("finds all solutions for small formula", function()
    -- x1 OR x2, with 2 vars → 3 solutions (TT, TF, FT)
    local formula = { clauses = { {1, 2} }, vars = 2 }
    local solutions = sat.solve_all(formula)
    T.eq(#solutions, 3, "should find 3 solutions")
    -- Each solution satisfies x1 OR x2
    for _, asgn in ipairs(solutions) do
      T.ok(asgn[1] or asgn[2], "each solution satisfies x1 OR x2")
    end
  end)
end)

T.describe("count", function()
  T.it("count matches solve_all length", function()
    local formula = { clauses = { {1, 2} }, vars = 2 }
    local n = sat.count(formula)
    local solutions = sat.solve_all(formula)
    T.eq(n, #solutions, "count should match solve_all length")
    T.eq(n, 3, "should be 3")
  end)
end)

-- ---------------------------------------------------------------------------
-- N-queens 4×4
-- ---------------------------------------------------------------------------
-- var(row, col) = (row-1)*4 + col   (1-indexed, 4x4 board)

T.describe("n-queens 4x4", function()
  T.it("finds a valid 4-queens placement", function()
    local N = 4
    local function vv(r, c) return (r-1)*N + c end
    local clauses = {}

    -- Each row has at least one queen
    for r = 1, N do
      local lits = {}
      for c = 1, N do lits[#lits+1] = vv(r, c) end
      clauses[#clauses+1] = lits
    end

    -- No two queens in the same row
    for r = 1, N do
      for c1 = 1, N do
        for c2 = c1+1, N do
          clauses[#clauses+1] = { -vv(r, c1), -vv(r, c2) }
        end
      end
    end

    -- No two queens in the same column
    for c = 1, N do
      for r1 = 1, N do
        for r2 = r1+1, N do
          clauses[#clauses+1] = { -vv(r1, c), -vv(r2, c) }
        end
      end
    end

    -- No two queens on the same diagonal
    for r1 = 1, N do
      for c1 = 1, N do
        for r2 = r1+1, N do
          for c2 = 1, N do
            local dr = r2 - r1
            local dc = c2 - c1
            if dc == dr or dc == -dr then
              clauses[#clauses+1] = { -vv(r1, c1), -vv(r2, c2) }
            end
          end
        end
      end
    end

    local r = sat.solve({ clauses = clauses, vars = N*N })
    T.ok(r.sat, "4-queens should be satisfiable")

    -- Verify exactly one queen per row
    local asgn = r.assignment
    for row = 1, N do
      local count = 0
      for col = 1, N do
        if asgn[vv(row, col)] then count = count + 1 end
      end
      T.eq(count, 1, "row " .. row .. " should have exactly one queen")
    end
    -- Verify exactly one queen per column
    for col = 1, N do
      local count = 0
      for row = 1, N do
        if asgn[vv(row, col)] then count = count + 1 end
      end
      T.eq(count, 1, "col " .. col .. " should have exactly one queen")
    end
  end)
end)
