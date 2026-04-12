if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T = require("lib.test.assert")
local F = require("lib.curry")

T.describe("curry", function()

  T.describe("curry 2-arg", function()
    T.it("both args at once", function()
      local add = F.curry(function(a, b) return a + b end)
      T.eq(add(3, 5), 8)
    end)

    T.it("one arg at a time", function()
      local add = F.curry(function(a, b) return a + b end)
      local add5 = add(5)
      T.eq(add5(3), 8)
    end)

    T.it("partial application reusable", function()
      local add = F.curry(function(a, b) return a + b end)
      local add10 = add(10)
      T.eq(add10(1), 11)
      T.eq(add10(2), 12)
    end)
  end)

  T.describe("curry 3-arg", function()
    local mul3 = F.curry(function(a, b, c) return a * b * c end)

    T.it("all at once", function()
      T.eq(mul3(2, 3, 4), 24)
    end)

    T.it("two then one", function()
      T.eq(mul3(2, 3)(4), 24)
    end)

    T.it("one then two", function()
      T.eq(mul3(2)(3, 4), 24)
    end)

    T.it("one at a time", function()
      T.eq(mul3(2)(3)(4), 24)
    end)
  end)

  T.describe("partial", function()
    T.it("binds prefix args", function()
      local greet = F.partial(string.format, "Hello, %s!")
      T.eq(greet("World"), "Hello, World!")
    end)

    T.it("multiple prefix args", function()
      local sub = function(a, b, c) return a - b - c end
      local sub_from_10 = F.partial(sub, 10)
      T.eq(sub_from_10(3, 2), 5)
    end)

    T.it("no extra args needed", function()
      local always_hello = F.partial(string.format, "%s", "hello")
      T.eq(always_hello(), "hello")
    end)
  end)

  T.describe("compose", function()
    T.it("right-to-left order", function()
      local f = F.compose(
        function(x) return x * 2 end,
        function(x) return x + 1 end
      )
      T.eq(f(3), 8)  -- (3+1)*2
    end)

    T.it("three functions", function()
      local f = F.compose(
        function(x) return x .. "!" end,
        function(x) return x .. "world" end,
        function(x) return "hello, " .. x end
      )
      T.eq(f(""), "hello, world!")
    end)

    T.it("zero functions returns identity", function()
      local id = F.compose()
      T.eq(id(42), 42)
    end)

    T.it("one function returns itself", function()
      local double = function(x) return x * 2 end
      local f = F.compose(double)
      T.eq(f(5), 10)
    end)
  end)

  T.describe("pipe", function()
    T.it("left-to-right order", function()
      local f = F.pipe(
        function(x) return x + 1 end,
        function(x) return x * 2 end
      )
      T.eq(f(3), 8)  -- (3+1)*2
    end)

    T.it("multiple stages", function()
      local pipeline = F.pipe(
        function(x) return x + 1 end,
        function(x) return x * 3 end,
        function(x) return x - 2 end
      )
      T.eq(pipeline(4), 13)  -- ((4+1)*3)-2
    end)

    T.it("zero functions returns identity", function()
      local id = F.pipe()
      T.eq(id(99), 99)
    end)
  end)

  T.describe("memoize", function()
    T.it("fn called once per unique arg", function()
      local count = 0
      local fn = F.memoize(function(n)
        count = count + 1
        return n * n
      end)
      T.eq(fn(4), 16)
      T.eq(fn(4), 16)
      T.eq(fn(4), 16)
      T.eq(count, 1)
    end)

    T.it("different args call fn separately", function()
      local count = 0
      local fn = F.memoize(function(n)
        count = count + 1
        return n + 10
      end)
      T.eq(fn(1), 11)
      T.eq(fn(2), 12)
      T.eq(fn(1), 11)
      T.eq(count, 2)
    end)

    T.it("works for recursive fib", function()
      local fib
      fib = F.memoize(function(n)
        if n <= 1 then return n end
        return fib(n - 1) + fib(n - 2)
      end)
      T.eq(fib(10), 55)
    end)
  end)

  T.describe("flip", function()
    T.it("swaps first two arguments", function()
      local sub = function(a, b) return a - b end
      local rsub = F.flip(sub)
      T.eq(rsub(3, 10), 7)  -- 10 - 3
    end)

    T.it("passes remaining args through", function()
      local fn = function(a, b, c) return a .. b .. c end
      T.eq(F.flip(fn)("B", "A", "C"), "ABC")
    end)
  end)

  T.describe("identity", function()
    T.it("returns its argument unchanged", function()
      T.eq(F.identity(5), 5)
      T.eq(F.identity("hello"), "hello")
      T.eq(F.identity(nil), nil)
    end)
  end)

  T.describe("const", function()
    T.it("always returns the fixed value", function()
      local always5 = F.const(5)
      T.eq(always5(), 5)
      T.eq(always5(1, 2, 3), 5)
      T.eq(always5("anything"), 5)
    end)
  end)

  T.describe("once", function()
    T.it("fn called exactly once", function()
      local count = 0
      local init = F.once(function()
        count = count + 1
        return 42
      end)
      T.eq(init(), 42)
      T.eq(init(), 42)
      T.eq(init(), 42)
      T.eq(count, 1)
    end)

    T.it("returns first call result on subsequent calls", function()
      local n = 0
      local fn = F.once(function()
        n = n + 1
        return n
      end)
      T.eq(fn(), 1)
      T.eq(fn(), 1)
    end)
  end)

  T.describe("juxt", function()
    T.it("collects results from multiple fns", function()
      local stats = F.juxt(math.min, math.max)
      local r = stats(3, 1, 4, 1, 5)
      T.eq(r[1], 1)
      T.eq(r[2], 5)
    end)

    T.it("three functions", function()
      local r = F.juxt(
        function(x) return x + 1 end,
        function(x) return x * 2 end,
        function(x) return x ^ 2 end
      )(4)
      T.eq(r[1], 5)
      T.eq(r[2], 8)
      T.eq(r[3], 16)
    end)
  end)

  T.describe("apply", function()
    T.it("spreads array as arguments", function()
      T.eq(F.apply(math.max, {1, 5, 3, 2}), 5)
    end)

    T.it("passes all elements", function()
      local sum = function(a, b, c) return a + b + c end
      T.eq(F.apply(sum, {10, 20, 30}), 60)
    end)
  end)

  T.describe("complement", function()
    T.it("negates predicate", function()
      local is_even = function(n) return n % 2 == 0 end
      local is_odd = F.complement(is_even)
      T.eq(is_odd(3), true)
      T.eq(is_odd(4), false)
    end)

    T.it("negates truthy/falsy", function()
      local always_true = function() return true end
      T.eq(F.complement(always_true)(), false)
    end)
  end)

  T.describe("thread", function()
    T.it("chains value through functions", function()
      local result = F.thread(5,
        function(x) return x + 1 end,
        function(x) return x * 2 end
      )
      T.eq(result, 12)
    end)

    T.it("single function", function()
      T.eq(F.thread(3, function(x) return x * 10 end), 30)
    end)

    T.it("no functions returns value", function()
      T.eq(F.thread(7), 7)
    end)
  end)

  T.describe("arity", function()
    T.it("returns number of parameters", function()
      local fn0 = function() end
      local fn1 = function(a) return a end
      local fn3 = function(a, b, c) return a + b + c end
      T.eq(F.arity(fn0), 0)
      T.eq(F.arity(fn1), 1)
      T.eq(F.arity(fn3), 3)
    end)
  end)

  T.describe("unary", function()
    T.it("limits fn to 1 argument", function()
      local received = {}
      local fn = F.unary(function(a)
        received[1] = a
        return a
      end)
      T.eq(fn(10, 20, 30), 10)
    end)
  end)

  T.describe("binary", function()
    T.it("limits fn to 2 arguments", function()
      local fn = F.binary(function(a, b)
        return a + b
      end)
      T.eq(fn(3, 4, 100), 7)
    end)
  end)

  T.describe("spread", function()
    T.it("spreads array as args to fn", function()
      local sum3 = function(a, b, c) return a + b + c end
      local spread_sum = F.spread(sum3)
      T.eq(spread_sum({1, 2, 3}), 6)
    end)
  end)

end)
