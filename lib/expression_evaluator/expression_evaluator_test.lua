if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local eval = require("lib.expression_evaluator")

T.describe("expression_evaluator", function()

  T.describe("basic arithmetic", function()
    T.it("addition", function()
      local r, err = eval.eval("2 + 3")
      T.ok(err == nil)
      T.eq(r, 5)
    end)

    T.it("subtraction", function()
      T.eq(eval.eval("10 - 4"), 6)
    end)

    T.it("multiplication", function()
      T.eq(eval.eval("3 * 4"), 12)
    end)

    T.it("division", function()
      local r = eval.eval("10 / 4")
      T.eq(r, 2.5)
    end)

    T.it("modulo", function()
      T.eq(eval.eval("10 % 3"), 1)
    end)

    T.it("exponentiation", function()
      T.eq(eval.eval("2 ^ 8"), 256)
    end)

    T.it("integer arithmetic stays integer", function()
      T.eq(eval.eval("6 / 2"), 3)
    end)
  end)

  T.describe("operator precedence", function()
    T.it("multiplication before addition", function()
      T.eq(eval.eval("2 + 3 * 4"), 14)
    end)

    T.it("parens override precedence", function()
      T.eq(eval.eval("(2 + 3) * 4"), 20)
    end)

    T.it("power before multiplication", function()
      T.eq(eval.eval("2 * 3 ^ 2"), 18)
    end)

    T.it("left-associative addition", function()
      T.eq(eval.eval("10 - 3 - 2"), 5)
    end)

    T.it("right-associative power", function()
      -- 2^3^2 = 2^(3^2) = 2^9 = 512
      T.eq(eval.eval("2 ^ 3 ^ 2"), 512)
    end)
  end)

  T.describe("unary operators", function()
    T.it("unary minus on literal", function()
      T.eq(eval.eval("-5"), -5)
    end)

    T.it("double unary minus", function()
      T.eq(eval.eval("-(-3)"), 3)
    end)

    T.it("unary minus in expression", function()
      T.eq(eval.eval("10 + -3"), 7)
    end)
  end)

  T.describe("variables", function()
    T.it("single variable", function()
      T.eq(eval.eval("x", {x = 7}), 7)
    end)

    T.it("two variables", function()
      T.eq(eval.eval("x * y + 1", {x = 3, y = 4}), 13)
    end)

    T.it("variable in comparison", function()
      T.eq(eval.eval("x + 1 == 5", {x = 4}), true)
    end)
  end)

  T.describe("boolean expressions", function()
    T.it("and - both true", function()
      T.eq(eval.eval("true and true"), true)
    end)

    T.it("and - one false", function()
      T.eq(eval.eval("true and false"), false)
    end)

    T.it("or - one true", function()
      T.eq(eval.eval("false or true"), true)
    end)

    T.it("or - both false", function()
      T.eq(eval.eval("false or false"), false)
    end)

    T.it("not true", function()
      T.eq(eval.eval("not true"), false)
    end)

    T.it("not false", function()
      T.eq(eval.eval("not false"), true)
    end)

    T.it("and with variables", function()
      T.eq(eval.eval("x > 5 and y < 10", {x = 6, y = 8}), true)
    end)

    T.it("or with not", function()
      T.eq(eval.eval("not active or count == 0", {active = false, count = 5}), true)
    end)

    T.it("and short-circuits", function()
      -- false and <unevaluated undefined> should return false without error
      T.eq(eval.eval("false and undefined_var"), false)
    end)

    T.it("or short-circuits", function()
      T.eq(eval.eval("true or undefined_var"), true)
    end)
  end)

  T.describe("comparison operators", function()
    T.it("==", function()
      T.eq(eval.eval("3 == 3"), true)
      T.eq(eval.eval("3 == 4"), false)
    end)

    T.it("!=", function()
      T.eq(eval.eval("3 != 4"), true)
      T.eq(eval.eval("3 != 3"), false)
    end)

    T.it("<", function()
      T.eq(eval.eval("2 < 3"), true)
      T.eq(eval.eval("3 < 3"), false)
    end)

    T.it(">", function()
      T.eq(eval.eval("4 > 3"), true)
      T.eq(eval.eval("3 > 4"), false)
    end)

    T.it("<=", function()
      T.eq(eval.eval("3 <= 3"), true)
      T.eq(eval.eval("4 <= 3"), false)
    end)

    T.it(">=", function()
      T.eq(eval.eval("3 >= 3"), true)
      T.eq(eval.eval("2 >= 3"), false)
    end)
  end)

  T.describe("string operations", function()
    T.it("string concatenation with ..", function()
      T.eq(eval.eval('"hello" .. " " .. "world"'), "hello world")
    end)

    T.it("string equality", function()
      T.eq(eval.eval('"foo" == "foo"'), true)
      T.eq(eval.eval('"foo" == "bar"'), false)
    end)

    T.it("len() on string", function()
      T.eq(eval.eval('len("hello")'), 5)
    end)

    T.it("single-quoted strings", function()
      T.eq(eval.eval("'world'"), "world")
    end)
  end)

  T.describe("built-in functions", function()
    T.it("abs of negative", function()
      T.eq(eval.eval("abs(-5)"), 5)
    end)

    T.it("abs of positive", function()
      T.eq(eval.eval("abs(3)"), 3)
    end)

    T.it("floor", function()
      T.eq(eval.eval("floor(3.7)"), 3)
    end)

    T.it("ceil", function()
      T.eq(eval.eval("ceil(3.2)"), 4)
    end)

    T.it("sqrt", function()
      T.eq(eval.eval("sqrt(16)"), 4)
    end)

    T.it("max of multiple args", function()
      T.eq(eval.eval("max(3, 7, 2)"), 7)
    end)

    T.it("min of multiple args", function()
      T.eq(eval.eval("min(3, 7, 2)"), 2)
    end)

    T.it("round up", function()
      T.eq(eval.eval("round(3.5)"), 4)
    end)

    T.it("round down", function()
      T.eq(eval.eval("round(3.4)"), 3)
    end)

    T.it("nested function calls", function()
      T.eq(eval.eval("max(abs(-3), sqrt(16))"), 4)
    end)

    T.it("log and exp", function()
      local r = eval.eval("log(exp(1))", {exp = math.exp})
      -- log(exp(1)) ≈ 1
      T.ok(math.abs(r - 1) < 1e-10)
    end)
  end)

  T.describe("compile()", function()
    T.it("returns a callable", function()
      local expr = eval.compile("x^2 + y^2")
      T.eq(type(expr), "function")
    end)

    T.it("produces correct results", function()
      local expr = eval.compile("x^2 + y^2")
      T.eq(expr({x = 3, y = 4}), 25)
    end)

    T.it("can be called multiple times", function()
      local expr = eval.compile("x^2 + y^2")
      T.eq(expr({x = 3,  y = 4}),  25)
      T.eq(expr({x = 5,  y = 12}), 169)
      T.eq(expr({x = 0,  y = 0}),  0)
    end)

    T.it("compile error propagated from call", function()
      local expr = eval.compile("(1 + 2")
      local r, err = expr({})
      T.ok(r == nil)
      T.ok(err ~= nil)
      T.ok(err:find("parse error") ~= nil)
    end)
  end)

  T.describe("custom functions in env", function()
    T.it("custom function is callable", function()
      local r, err = eval.eval("double(x)", {x = 5, double = function(n) return n * 2 end})
      T.ok(err == nil)
      T.eq(r, 10)
    end)

    T.it("custom function with multiple args", function()
      local r, err = eval.eval("add(a, b)", {a = 3, b = 7, add = function(x, y) return x + y end})
      T.ok(err == nil)
      T.eq(r, 10)
    end)
  end)

  T.describe("error cases", function()
    T.it("undefined variable returns nil errmsg", function()
      local r, err = eval.eval("unknown_var")
      T.ok(r == nil)
      T.ok(err ~= nil)
      T.ok(err:find("undefined variable") ~= nil)
    end)

    T.it("parse error on unbalanced paren", function()
      local r, err = eval.eval("(1 + 2")
      T.ok(r == nil)
      T.ok(err ~= nil)
      T.ok(err:find("parse error") ~= nil)
    end)

    T.it("parse error on extra closing paren", function()
      local r, err = eval.eval("1 + 2)")
      T.ok(r == nil)
      T.ok(err ~= nil)
    end)

    T.it("undefined function returns error", function()
      local r, err = eval.eval("nosuchfn(1)")
      T.ok(r == nil)
      T.ok(err ~= nil)
      T.ok(err:find("undefined function") ~= nil)
    end)

    T.it("runtime error in function propagates", function()
      local r, err = eval.eval('len(42)')
      T.ok(r == nil)
      T.ok(err ~= nil)
    end)

    T.it("empty expression is a parse error", function()
      local r, err = eval.eval("")
      T.ok(r == nil)
      T.ok(err ~= nil)
    end)
  end)

  T.describe("edge cases", function()
    T.it("nested parens", function()
      T.eq(eval.eval("((3 + 2) * (4 - 1))"), 15)
    end)

    T.it("zero division produces inf (lua semantics)", function()
      local r, err = eval.eval("1/0")
      -- Lua/LuaJIT: 1/0 = inf, not an error
      T.ok(err == nil)
      T.ok(r == math.huge)
    end)

    T.it("nil literal", function()
      local r, err = eval.eval("nil")
      -- nil result without an error string
      T.ok(err == nil)
      T.ok(r == nil)
    end)

    T.it("complex expression", function()
      local r, err = eval.eval("(x + y) * (x - y)", {x = 5, y = 3})
      T.ok(err == nil)
      T.eq(r, 16)
    end)

    T.it("chained string concat", function()
      T.eq(eval.eval('"a" .. "b" .. "c"'), "abc")
    end)

    T.it("negative exponent", function()
      T.eq(eval.eval("2 ^ -1"), 0.5)
    end)
  end)

end)
