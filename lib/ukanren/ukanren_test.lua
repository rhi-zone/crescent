if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local uk = require("lib.ukanren")

T.describe("ukanren", function()

  T.describe("var", function()
    T.it("creates logic variables", function()
      local x = uk.var("x")
      T.ok(uk.is_var(x))
      T.eq(x.name, "x")
    end)

    T.it("is_var returns false for non-variables", function()
      T.fail(uk.is_var(42))
      T.fail(uk.is_var("hello"))
      T.fail(uk.is_var({}))
      T.fail(uk.is_var(nil))
    end)
  end)

  T.describe("eq", function()
    T.it("simple unification succeeds", function()
      local x = uk.var("x")
      local results = uk.run(uk.eq(x, 42), nil)
      T.eq(#results, 1)
      T.eq(uk.walk(x, results[1]), 42)
    end)

    T.it("conflicting unification fails", function()
      local x = uk.var("x")
      local g = uk.conj(uk.eq(x, 1), uk.eq(x, 2))
      local results = uk.run(g, nil)
      T.eq(#results, 0)
    end)
  end)

  T.describe("conj", function()
    T.it("both goals succeed", function()
      local x = uk.var("x")
      local y = uk.var("y")
      local g = uk.conj(uk.eq(x, 1), uk.eq(y, 2))
      local results = uk.run(g, nil)
      T.eq(#results, 1)
      T.eq(uk.walk(x, results[1]), 1)
      T.eq(uk.walk(y, results[1]), 2)
    end)

    T.it("one fails means no results", function()
      local x = uk.var("x")
      local g = uk.conj(uk.eq(x, 1), uk.eq(x, 2))
      local results = uk.run(g, nil)
      T.eq(#results, 0)
    end)
  end)

  T.describe("disj", function()
    T.it("both alternatives returned", function()
      local x = uk.var("x")
      local g = uk.disj(uk.eq(x, "a"), uk.eq(x, "b"))
      local results = uk.run(g, nil)
      T.eq(#results, 2)
      local vals = {}
      for _, sub in ipairs(results) do
        vals[uk.walk(x, sub)] = true
      end
      T.ok(vals["a"])
      T.ok(vals["b"])
    end)
  end)

  T.describe("fresh", function()
    T.it("scoped fresh variables", function()
      local g = uk.fresh(function(a, b)
        return uk.conj(uk.eq(a, 10), uk.eq(b, 20))
      end)
      local results = uk.run(g, nil)
      T.eq(#results, 1)
    end)
  end)

  T.describe("run_fresh", function()
    T.it("with limit", function()
      local results = uk.run_fresh(1, function(q)
        return uk.disj(uk.eq(q, "cat"), uk.eq(q, "dog"))
      end)
      T.eq(#results, 1)
    end)

    T.it("with nil (all results)", function()
      local results = uk.run_fresh(nil, function(q)
        return uk.disj_all(uk.eq(q, 1), uk.eq(q, 2), uk.eq(q, 3))
      end)
      T.eq(#results, 3)
      local vals = {}
      for _, r in ipairs(results) do vals[r._q1] = true end
      T.ok(vals[1])
      T.ok(vals[2])
      T.ok(vals[3])
    end)
  end)

  T.describe("structural unification", function()
    T.it("cons(x,y) = cons(1,2)", function()
      local x = uk.var("x")
      local y = uk.var("y")
      local g = uk.eq(uk.cons(x, y), uk.cons(1, 2))
      local results = uk.run(g, nil)
      T.eq(#results, 1)
      T.eq(uk.walk(x, results[1]), 1)
      T.eq(uk.walk(y, results[1]), 2)
    end)
  end)

  T.describe("transitive unification", function()
    T.it("x=y, y=42 implies x=42", function()
      local x = uk.var("x")
      local y = uk.var("y")
      local g = uk.conj(uk.eq(x, y), uk.eq(y, 42))
      local results = uk.run(g, nil)
      T.eq(#results, 1)
      T.eq(uk.walk(x, results[1]), 42)
    end)
  end)

  T.describe("conde", function()
    T.it("multiple clauses", function()
      local x = uk.var("x")
      local y = uk.var("y")
      local g = uk.conde(
        { uk.eq(x, 1), uk.eq(y, "one") },
        { uk.eq(x, 2), uk.eq(y, "two") },
        { uk.eq(x, 3), uk.eq(y, "three") }
      )
      local results = uk.run(g, nil)
      T.eq(#results, 3)
    end)
  end)

  T.describe("membero", function()
    T.it("finds all members", function()
      local x = uk.var("x")
      local g = uk.membero(x, { 10, 20, 30 })
      local results = uk.run(g, nil)
      T.eq(#results, 3)
      local vals = {}
      for _, sub in ipairs(results) do vals[uk.walk(x, sub)] = true end
      T.ok(vals[10])
      T.ok(vals[20])
      T.ok(vals[30])
    end)
  end)

  T.describe("appendo", function()
    T.it("splits a list all possible ways", function()
      local x = uk.var("x")
      local y = uk.var("y")
      local g = uk.appendo(x, y, uk.list(1, 2, 3))
      local results = uk.run(g, 10)
      -- 4 ways: nil++[1,2,3], [1]++[2,3], [1,2]++[3], [1,2,3]++nil
      T.ok(#results >= 4)
    end)
  end)

  T.describe("list helpers", function()
    T.it("list/cons/car/cdr", function()
      local l = uk.list(1, 2, 3)
      T.ok(uk.is_pair(l))
      T.eq(uk.car(l), 1)
      T.eq(uk.car(uk.cdr(l)), 2)
      T.eq(uk.car(uk.cdr(uk.cdr(l))), 3)
      T.eq(uk.cdr(uk.cdr(uk.cdr(l))), nil)
    end)

    T.it("empty list is nil", function()
      local l = uk.list()
      T.eq(l, nil)
    end)
  end)

  T.describe("recursive relation", function()
    T.it("ancestor via fresh+conde", function()
      -- parent(tom, bob), parent(bob, ann), parent(bob, pat)
      local function parent(p, c)
        return uk.conde(
          { uk.eq(p, "tom"), uk.eq(c, "bob") },
          { uk.eq(p, "bob"), uk.eq(c, "ann") },
          { uk.eq(p, "bob"), uk.eq(c, "pat") }
        )
      end
      -- ancestor(x, y) = parent(x, y) OR (parent(x, z) AND ancestor(z, y))
      local function ancestor(x, y)
        return uk.disj(
          parent(x, y),
          uk.fresh(function(z)
            return uk.conj(parent(x, z), uk.delay(function() return ancestor(z, y) end))
          end)
        )
      end
      local q = uk.var("q")
      -- Who are tom's descendants?
      local results = uk.run(ancestor("tom", q), 10)
      local vals = {}
      for _, sub in ipairs(results) do vals[uk.walk(q, sub)] = true end
      T.ok(vals["bob"])
      T.ok(vals["ann"])
      T.ok(vals["pat"])
      T.eq(#results, 3)
    end)
  end)

  T.describe("fair interleaving", function()
    T.it("infinite streams do not block finite ones", function()
      local x = uk.var("x")
      -- fives: infinite stream of x=5
      local function fives(x)
        return uk.disj(
          uk.eq(x, 5),
          function(sub)
            return function() return fives(x)(sub) end
          end
        )
      end
      -- disj of eq(x,6) and fives: should get 6 among first few results
      local g = uk.disj(uk.eq(x, 6), fives(x))
      local results = uk.run(g, 5)
      T.ok(#results >= 2)
      local found_six = false
      local found_five = false
      for _, sub in ipairs(results) do
        local v = uk.walk(x, sub)
        if v == 6 then found_six = true end
        if v == 5 then found_five = true end
      end
      T.ok(found_six, "should find 6 (finite goal)")
      T.ok(found_five, "should find 5 (infinite goal)")
    end)
  end)

  T.describe("neq", function()
    T.it("disequality constraint filters", function()
      local x = uk.var("x")
      local g = uk.conj(
        uk.disj_all(uk.eq(x, 1), uk.eq(x, 2), uk.eq(x, 3)),
        uk.neq(x, 2)
      )
      local results = uk.run(g, nil)
      T.eq(#results, 2)
      local vals = {}
      for _, sub in ipairs(results) do vals[uk.walk(x, sub)] = true end
      T.ok(vals[1])
      T.ok(vals[3])
      T.fail(vals[2])
    end)
  end)

  T.describe("succeed and fail goals", function()
    T.it("succeed always produces a result", function()
      local results = uk.run(uk.succeed, nil)
      T.eq(#results, 1)
    end)

    T.it("fail_goal produces no results", function()
      local results = uk.run(uk.fail_goal, nil)
      T.eq(#results, 0)
    end)
  end)

end)

T._summary()
