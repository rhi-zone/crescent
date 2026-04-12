if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local pl = require("lib.prolog")

-- Helper: sorted list of a specific field from solutions
local function collect(sols, field)
  local vals = {}
  for i = 1, #sols do
    vals[i] = sols[i][field]
  end
  table.sort(vals)
  return vals
end

T.describe("lib.prolog", function()

  T.describe("module", function()
    T.it("has _tier = pure", function()
      T.eq(pl._tier, "pure")
    end)

    T.it("database() returns a database", function()
      local db = pl.database()
      T.ok(db ~= nil)
    end)
  end)

  T.describe("facts", function()
    local db = pl.database()
    db:assert("parent(tom, bob)")
    db:assert("parent(tom, liz)")
    db:assert("parent(bob, ann)")
    db:assert("parent(bob, pat)")

    T.it("query_all returns all matching facts", function()
      local sols = db:query_all("parent(tom, X)")
      T.eq(#sols, 2)
      local names = collect(sols, "X")
      T.eq(names[1], "bob")
      T.eq(names[2], "liz")
    end)

    T.it("query_one returns first solution", function()
      local sol = db:query_one("parent(tom, X)")
      T.ok(sol ~= nil)
      T.ok(sol.X == "bob" or sol.X == "liz")
    end)

    T.it("satisfiable true for known fact", function()
      T.ok(db:satisfiable("parent(tom, bob)"))
    end)

    T.it("satisfiable false for unknown fact", function()
      T.ok(not db:satisfiable("parent(tom, ann)"))
    end)

    T.it("query with two variables", function()
      local sols = db:query_all("parent(X, Y)")
      T.eq(#sols, 4)
    end)
  end)

  T.describe("rules", function()
    local db = pl.database()
    db:assert("parent(tom, bob)")
    db:assert("parent(tom, liz)")
    db:assert("parent(bob, ann)")
    db:assert("parent(bob, pat)")
    db:assert("grandparent(X, Z) :- parent(X, Y), parent(Y, Z)")

    T.it("grandparent rule works", function()
      local sols = db:query_all("grandparent(tom, Who)")
      T.eq(#sols, 2)
      local names = collect(sols, "Who")
      T.eq(names[1], "ann")
      T.eq(names[2], "pat")
    end)

    T.it("grandparent satisfiable", function()
      T.ok(db:satisfiable("grandparent(tom, ann)"))
    end)

    T.it("grandparent unsatisfiable for wrong pair", function()
      T.ok(not db:satisfiable("grandparent(bob, tom)"))
    end)
  end)

  T.describe("recursive rules", function()
    local db = pl.database()
    db:assert("parent(tom, bob)")
    db:assert("parent(tom, liz)")
    db:assert("parent(bob, ann)")
    db:assert("parent(bob, pat)")
    db:assert("ancestor(X, Y) :- parent(X, Y)")
    db:assert("ancestor(X, Y) :- parent(X, Z), ancestor(Z, Y)")

    T.it("ancestor finds direct parent", function()
      T.ok(db:satisfiable("ancestor(tom, bob)"))
    end)

    T.it("ancestor finds grandchild", function()
      T.ok(db:satisfiable("ancestor(tom, ann)"))
      T.ok(db:satisfiable("ancestor(tom, pat)"))
    end)

    T.it("ancestor query_all from tom", function()
      local sols = db:query_all("ancestor(tom, Who)")
      T.eq(#sols, 4)
      local names = collect(sols, "Who")
      T.eq(names[1], "ann")
      T.eq(names[2], "bob")
      T.eq(names[3], "liz")
      T.eq(names[4], "pat")
    end)

    T.it("ancestor false for non-ancestor", function()
      T.ok(not db:satisfiable("ancestor(ann, tom)"))
    end)
  end)

  T.describe("unification", function()
    local db = pl.database()
    db:assert("foo(bar)")
    db:assert("eq_test(X, X)")

    T.it("X = foo gives X=foo", function()
      local sol = db:query_one("X = foo")
      T.eq(sol.X, "foo")
    end)

    T.it("unification with compound", function()
      local sol = db:query_one("f(X, b) = f(a, b)")
      T.eq(sol.X, "a")
    end)

    T.it("eq_test rule unification", function()
      T.ok(db:satisfiable("eq_test(hello, hello)"))
      T.ok(not db:satisfiable("eq_test(hello, world)"))
    end)
  end)

  T.describe("arithmetic", function()
    local db = pl.database()
    db:assert("double(X, Y) :- Y is X * 2")
    db:assert("sum3(A, B, C, S) :- S is A + B + C")

    T.it("Y is 3 + 4 gives Y=7", function()
      local sol = db:query_one("Y is 3 + 4")
      T.eq(sol.Y, "7")
    end)

    T.it("double rule", function()
      local sol = db:query_one("double(5, R)")
      T.eq(sol.R, "10")
    end)

    T.it("sum3 rule", function()
      local sol = db:query_one("sum3(1, 2, 3, S)")
      T.eq(sol.S, "6")
    end)

    T.it("modulo", function()
      local sol = db:query_one("X is 10 mod 3")
      T.eq(sol.X, "1")
    end)

    T.it("exponentiation", function()
      local sol = db:query_one("X is 2 ^ 10")
      T.eq(sol.X, "1024")
    end)

    T.it("abs", function()
      local sol = db:query_one("X is abs(-5)")
      T.eq(sol.X, "5")
    end)

    T.it("max and min", function()
      local sol1 = db:query_one("X is max(3, 7)")
      T.eq(sol1.X, "7")
      local sol2 = db:query_one("X is min(3, 7)")
      T.eq(sol2.X, "3")
    end)
  end)

  T.describe("comparison", function()
    T.it("3 < 5 succeeds", function()
      local db = pl.database()
      T.ok(db:satisfiable("3 < 5"))
    end)

    T.it("5 < 3 fails", function()
      local db = pl.database()
      T.ok(not db:satisfiable("5 < 3"))
    end)

    T.it("> succeeds", function()
      local db = pl.database()
      T.ok(db:satisfiable("5 > 3"))
    end)

    T.it("=< succeeds for equal", function()
      local db = pl.database()
      T.ok(db:satisfiable("3 =< 3"))
    end)

    T.it(">= succeeds", function()
      local db = pl.database()
      T.ok(db:satisfiable("7 >= 3"))
    end)

    T.it("== succeeds for same atom", function()
      local db = pl.database()
      T.ok(db:satisfiable("foo == foo"))
    end)

    T.it("== fails for different atoms", function()
      local db = pl.database()
      T.ok(not db:satisfiable("foo == bar"))
    end)

    T.it("\\== succeeds for different atoms", function()
      local db = pl.database()
      T.ok(db:satisfiable("foo \\== bar"))
    end)

    T.it("\\== fails for same atom", function()
      local db = pl.database()
      T.ok(not db:satisfiable("foo \\== foo"))
    end)
  end)

  T.describe("retract", function()
    local db = pl.database()
    db:assert("color(red)")
    db:assert("color(green)")
    db:assert("color(blue)")

    T.it("retract removes a fact", function()
      T.ok(db:satisfiable("color(red)"))
      db:retract("color(red)")
      T.ok(not db:satisfiable("color(red)"))
    end)

    T.it("other facts remain after retract", function()
      T.ok(db:satisfiable("color(green)"))
      T.ok(db:satisfiable("color(blue)"))
    end)
  end)

  T.describe("cut", function()
    local db = pl.database()
    -- max/3: max(X, Y, X) :- X >= Y, !.
    -- max/3: max(_, Y, Y).
    db:assert("my_max(X, Y, X) :- X >= Y, !")
    db:assert("my_max(_, Y, Y)")

    T.it("cut limits solutions to first clause", function()
      local sols = db:query_all("my_max(5, 3, M)")
      -- without cut both clauses would match when X >= Y
      -- with cut only first clause fires
      T.eq(#sols, 1)
      T.eq(sols[1].M, "5")
    end)

    T.it("cut: second clause fires when first fails", function()
      local sol = db:query_one("my_max(3, 5, M)")
      T.ok(sol ~= nil)
      T.eq(sol.M, "5")
    end)
  end)

  T.describe("not (negation as failure)", function()
    local db = pl.database()
    db:assert("member(X, [X|_])")
    db:assert("member(X, [_|T]) :- member(X, T)")
    db:assert("likes(alice, bob)")

    T.it("not fails when goal succeeds", function()
      T.ok(not db:satisfiable("not(likes(alice, bob))"))
    end)

    T.it("not succeeds when goal fails", function()
      T.ok(db:satisfiable("not(likes(alice, eve))"))
    end)

    T.it("\\+ form works", function()
      T.ok(db:satisfiable("\\+(likes(alice, eve))"))
      T.ok(not db:satisfiable("\\+(likes(alice, bob))"))
    end)
  end)

  T.describe("lists", function()
    local db = pl.database()
    db:assert("member(X, [X|_])")
    db:assert("member(X, [_|T]) :- member(X, T)")
    db:assert("append([], L, L)")
    db:assert("append([H|T], L, [H|R]) :- append(T, L, R)")
    db:assert("length([], 0)")
    db:assert("length([_|T], N) :- length(T, N1), N is N1 + 1")

    T.it("member query", function()
      T.ok(db:satisfiable("member(b, [a, b, c])"))
      T.ok(not db:satisfiable("member(d, [a, b, c])"))
    end)

    T.it("member returns all members", function()
      local sols = db:query_all("member(X, [a, b, c])")
      T.eq(#sols, 3)
      local names = collect(sols, "X")
      T.eq(names[1], "a")
      T.eq(names[2], "b")
      T.eq(names[3], "c")
    end)

    T.it("append two lists", function()
      local sol = db:query_one("append([1,2], [3,4], R)")
      T.eq(sol.R, "[1,2,3,4]")
    end)

    T.it("length of list", function()
      local sol = db:query_one("length([a,b,c], N)")
      T.eq(sol.N, "3")
    end)
  end)

  T.describe("nested compound terms", function()
    local db = pl.database()
    db:assert("point(pt(1, 2))")
    db:assert("point(pt(3, 4))")
    db:assert("x_coord(pt(X, _), X)")

    T.it("match nested compound", function()
      T.ok(db:satisfiable("point(pt(1, 2))"))
    end)

    T.it("extract component of nested term", function()
      local sol = db:query_one("point(P), x_coord(P, X)")
      T.ok(sol ~= nil)
      T.ok(sol.X == "1" or sol.X == "3")
    end)

    T.it("query nested variable binding", function()
      local sols = db:query_all("point(pt(X, Y))")
      T.eq(#sols, 2)
    end)
  end)

  T.describe("true and fail", function()
    local db = pl.database()

    T.it("true succeeds", function()
      T.ok(db:satisfiable("true"))
    end)

    T.it("fail fails", function()
      T.ok(not db:satisfiable("fail"))
    end)
  end)

end)
