if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T    = require("lib.test.assert")
local expr = require("lib.expr")

local function near(a, b, tol)
  tol = tol or 1e-9
  return math.abs(a - b) <= tol
end

T.describe("expr", function()

  -- ── basic arithmetic ──────────────────────────────────────────────────
  T.it("addition", function()
    local v, err = expr.eval("1 + 2")
    T.ok(not err, err)
    T.eq(v, 3)
  end)

  T.it("subtraction", function()
    T.eq(expr.eval("10 - 3"), 7)
  end)

  T.it("multiplication", function()
    T.eq(expr.eval("4 * 5"), 20)
  end)

  T.it("division", function()
    T.eq(expr.eval("10 / 4"), 2.5)
  end)

  T.it("exponentiation", function()
    T.eq(expr.eval("2^10"), 1024)
  end)

  T.it("modulo", function()
    T.eq(expr.eval("17 % 5"), 2)
  end)

  T.it("unary minus", function()
    T.eq(expr.eval("-3"), -3)
    T.eq(expr.eval("--3"), 3)
    T.eq(expr.eval("-(2+3)"), -5)
  end)

  -- ── operator precedence ───────────────────────────────────────────────
  T.it("precedence: 2+3*4 = 14", function()
    T.eq(expr.eval("2 + 3 * 4"), 14)
  end)

  T.it("precedence: mul before add", function()
    T.eq(expr.eval("1 + 2 * 3 + 4"), 11)
  end)

  T.it("precedence: power before mul", function()
    T.eq(expr.eval("2 * 3^2"), 18)
  end)

  -- ── parentheses ───────────────────────────────────────────────────────
  T.it("parentheses override precedence", function()
    T.eq(expr.eval("(2 + 3) * 4"), 20)
  end)

  T.it("nested parentheses", function()
    T.eq(expr.eval("((2 + 3) * (1 + 1))"), 10)
  end)

  -- ── variables ─────────────────────────────────────────────────────────
  T.it("single variable", function()
    T.eq(expr.eval("x", {x=7}), 7)
  end)

  T.it("x + y with env", function()
    T.eq(expr.eval("x + y", {x=3, y=4}), 7)
  end)

  T.it("x^2 + y^2", function()
    T.eq(expr.eval("x^2 + y^2", {x=3, y=4}), 25)
  end)

  -- ── built-in functions ────────────────────────────────────────────────
  T.it("sin", function()
    T.ok(near(expr.eval("sin(0)"), 0))
    T.ok(near(expr.eval("sin(pi/2)"), 1, 1e-9))
  end)

  T.it("cos", function()
    T.ok(near(expr.eval("cos(0)"), 1))
  end)

  T.it("sqrt", function()
    T.ok(near(expr.eval("sqrt(4)"), 2))
    T.ok(near(expr.eval("sqrt(2)"), math.sqrt(2)))
  end)

  T.it("abs", function()
    T.eq(expr.eval("abs(-5)"), 5)
    T.eq(expr.eval("abs(3)"), 3)
  end)

  T.it("floor and ceil", function()
    T.eq(expr.eval("floor(3.7)"), 3)
    T.eq(expr.eval("ceil(3.2)"), 4)
  end)

  T.it("atan2", function()
    T.ok(near(expr.eval("atan2(1, 1)"), math.atan2(1,1)))
  end)

  T.it("log and exp", function()
    T.ok(near(expr.eval("exp(1)"), math.exp(1)))
    T.ok(near(expr.eval("log(e)"), 1, 1e-9))
  end)

  -- ── constants ─────────────────────────────────────────────────────────
  T.it("pi constant", function()
    T.ok(near(expr.eval("pi"), math.pi))
  end)

  T.it("e constant", function()
    T.ok(near(expr.eval("e"), math.exp(1)))
  end)

  T.it("sin(pi) ≈ 0", function()
    T.ok(near(expr.eval("sin(pi)"), 0, 1e-14))
  end)

  T.it("sin(pi)+cos(0) ≈ 1", function()
    T.ok(near(expr.eval("sin(pi) + cos(0)"), 1, 1e-14))
  end)

  -- ── comparisons ───────────────────────────────────────────────────────
  T.it("comparison less-than", function()
    T.eq(expr.eval("1 < 2"), 1)
    T.eq(expr.eval("2 < 1"), 0)
  end)

  T.it("comparison equal", function()
    T.eq(expr.eval("3 == 3"), 1)
    T.eq(expr.eval("3 == 4"), 0)
  end)

  T.it("comparison not-equal", function()
    T.eq(expr.eval("3 != 4"), 1)
    T.eq(expr.eval("3 != 3"), 0)
  end)

  T.it("comparison >=", function()
    T.eq(expr.eval("4 >= 4"), 1)
    T.eq(expr.eval("3 >= 4"), 0)
  end)

  -- ── ternary ───────────────────────────────────────────────────────────
  T.it("ternary true branch", function()
    T.eq(expr.eval("1 > 0 ? 42 : -1"), 42)
  end)

  T.it("ternary false branch", function()
    T.eq(expr.eval("0 > 1 ? 42 : -1"), -1)
  end)

  T.it("ternary abs via ternary", function()
    T.eq(expr.eval("x > 0 ? x : -x", {x=-5}), 5)
    T.eq(expr.eval("x > 0 ? x : -x", {x=3}), 3)
  end)

  -- ── compile ───────────────────────────────────────────────────────────
  T.it("compile: reusable function", function()
    local fn, err = expr.compile("x^2 + 2*x + 1")
    T.ok(not err, err)
    T.eq(fn({x=5}), 36)
    T.eq(fn({x=10}), 121)
    T.eq(fn({x=0}), 1)
  end)

  T.it("compile: error on bad expression", function()
    local fn, err = expr.compile("x + (")
    T.ok(fn == nil)
    T.ok(type(err) == "string")
  end)

  -- ── parse + eval_ast ──────────────────────────────────────────────────
  T.it("parse then eval_ast", function()
    local ast, err = expr.parse("3 * (1 + 2)")
    T.ok(not err, err)
    local v, verr = expr.eval_ast(ast, {})
    T.ok(not verr, verr)
    T.eq(v, 9)
  end)

  T.it("parse + eval_ast with variable", function()
    local ast = expr.parse("x^2")
    local v = expr.eval_ast(ast, {x=7})
    T.eq(v, 49)
  end)

  -- ── to_string ─────────────────────────────────────────────────────────
  T.it("to_string round-trips simple expr", function()
    local ast = expr.parse("x + y * 2")
    local s = expr.to_string(ast)
    -- re-parse and re-eval to confirm round-trip semantics
    local v = expr.eval(s, {x=1, y=3})
    T.eq(v, 7)
  end)

  T.it("to_string preserves unary minus", function()
    local ast = expr.parse("-x")
    local s = expr.to_string(ast)
    T.ok(s:find("-") ~= nil)
    T.eq(expr.eval(s, {x=3}), -3)
  end)

  T.it("to_string parenthesises correctly", function()
    local ast = expr.parse("(a + b) * c")
    local s = expr.to_string(ast)
    -- must preserve the semantics
    T.eq(expr.eval(s, {a=1, b=2, c=4}), 12)
  end)

  T.it("to_string function call", function()
    local ast = expr.parse("sin(x)")
    local s = expr.to_string(ast)
    T.ok(s == "sin(x)" or s:find("sin") ~= nil)
    T.ok(near(expr.eval(s, {x=0}), 0))
  end)

  -- ── simplify ──────────────────────────────────────────────────────────
  T.it("simplify constant folding: 2+3 → 5", function()
    local ast = expr.parse("2 + 3")
    local s = expr.simplify(ast)
    T.eq(s.op, "num")
    T.eq(s.value, 5)
  end)

  T.it("simplify folds nested constants", function()
    local ast = expr.parse("2 * 3 + 4 * 5")
    local s = expr.simplify(ast)
    T.eq(s.op, "num")
    T.eq(s.value, 26)
  end)

  T.it("simplify leaves variables unchanged", function()
    local ast = expr.parse("x + 1")
    local s = expr.simplify(ast)
    T.eq(s.op, "add")
    T.eq(s.left.op, "var")
  end)

  T.it("simplify folds constant subtree", function()
    local ast = expr.parse("x + (2 + 3)")
    local s = expr.simplify(ast)
    T.eq(s.op, "add")
    T.eq(s.right.op, "num")
    T.eq(s.right.value, 5)
  end)

  -- ── diff ─────────────────────────────────────────────────────────────
  T.it("diff: d/dx(x) = 1", function()
    local ast = expr.parse("x")
    local d = expr.simplify(expr.diff(ast, "x"))
    T.eq(d.op, "num")
    T.eq(d.value, 1)
  end)

  T.it("diff: d/dx(c) = 0", function()
    local ast = expr.parse("5")
    local d = expr.simplify(expr.diff(ast, "x"))
    T.eq(d.op, "num")
    T.eq(d.value, 0)
  end)

  T.it("diff: d/dx(x^2) = 2*x", function()
    local ast = expr.parse("x^2")
    local d = expr.simplify(expr.diff(ast, "x"))
    -- evaluate at x=3: should be 6
    T.ok(near(expr.eval_ast(d, {x=3}), 6))
    T.ok(near(expr.eval_ast(d, {x=5}), 10))
  end)

  T.it("diff: d/dx(x^3) evaluated", function()
    local ast = expr.parse("x^3")
    local d = expr.simplify(expr.diff(ast, "x"))
    -- d/dx(x^3) = 3*x^2; at x=2 → 12
    T.ok(near(expr.eval_ast(d, {x=2}), 12))
  end)

  T.it("diff: d/dx(sin(x)) = cos(x)", function()
    local ast = expr.parse("sin(x)")
    local d = expr.simplify(expr.diff(ast, "x"))
    -- at x=0: cos(0)=1
    T.ok(near(expr.eval_ast(d, {x=0}), 1, 1e-9))
    -- at x=pi/2: cos(pi/2)=0
    T.ok(near(expr.eval_ast(d, {x=math.pi/2}), 0, 1e-9))
  end)

  T.it("diff: d/dx(cos(x)) = -sin(x)", function()
    local ast = expr.parse("cos(x)")
    local d = expr.simplify(expr.diff(ast, "x"))
    -- at x=0: -sin(0)=0
    T.ok(near(expr.eval_ast(d, {x=0}), 0, 1e-9))
    -- at x=pi/2: -sin(pi/2)=-1
    T.ok(near(expr.eval_ast(d, {x=math.pi/2}), -1, 1e-9))
  end)

  T.it("diff: d/dx(x^2 + 2*x + 1) = 2*x+2", function()
    local ast = expr.parse("x^2 + 2*x + 1")
    local d = expr.simplify(expr.diff(ast, "x"))
    -- at x=0: 2; at x=3: 8
    T.ok(near(expr.eval_ast(d, {x=0}), 2, 1e-9))
    T.ok(near(expr.eval_ast(d, {x=3}), 8, 1e-9))
  end)

  T.it("diff: chain rule exp(x)", function()
    local ast = expr.parse("exp(x)")
    local d = expr.simplify(expr.diff(ast, "x"))
    -- d/dx exp(x) = exp(x); at x=1 ≈ e
    T.ok(near(expr.eval_ast(d, {x=1}), math.exp(1), 1e-9))
  end)

  T.it("diff: d/dy independent variable = 0", function()
    local ast = expr.parse("x^2")
    local d = expr.simplify(expr.diff(ast, "y"))
    T.eq(d.op, "num")
    T.eq(d.value, 0)
  end)

  -- ── vars ──────────────────────────────────────────────────────────────
  T.it("vars: extracts variable names", function()
    local ast = expr.parse("x^2 + y * z")
    local v = expr.vars(ast)
    T.ok(v["x"])
    T.ok(v["y"])
    T.ok(v["z"])
  end)

  T.it("vars: does not include constants pi/e", function()
    local ast = expr.parse("pi * e")
    local v = expr.vars(ast)
    T.ok(not v["pi"])
    T.ok(not v["e"])
  end)

  T.it("vars: empty for pure literal", function()
    local ast = expr.parse("2 + 3")
    local v = expr.vars(ast)
    local count = 0
    for _ in pairs(v) do count = count + 1 end
    T.eq(count, 0)
  end)

  -- ── power associativity ───────────────────────────────────────────────
  T.it("power is right-associative: 2^3^2 = 512", function()
    -- right-assoc: 2^(3^2) = 2^9 = 512
    T.eq(expr.eval("2^3^2"), 512)
  end)

  -- ── errors ────────────────────────────────────────────────────────────
  T.it("error: unbalanced open paren", function()
    local v, err = expr.eval("(1 + 2")
    T.ok(v == nil)
    T.ok(type(err) == "string")
  end)

  T.it("error: unbalanced close paren", function()
    local v, err = expr.eval("1 + 2)")
    T.ok(v == nil)
    T.ok(type(err) == "string")
  end)

  T.it("error: unknown function", function()
    local v, err = expr.eval("foobar(1)")
    T.ok(v == nil)
    T.ok(type(err) == "string")
  end)

  T.it("error: missing operand (trailing op)", function()
    local v, err = expr.eval("1 +")
    T.ok(v == nil)
    T.ok(type(err) == "string")
  end)

  T.it("error: undefined variable", function()
    local v, err = expr.eval("x + 1")
    T.ok(v == nil)
    T.ok(type(err) == "string")
  end)

  T.it("error: empty expression", function()
    local v, err = expr.eval("")
    T.ok(v == nil)
    T.ok(type(err) == "string")
  end)

  -- ── _tier ─────────────────────────────────────────────────────────────
  T.it("_tier is 'pure'", function()
    T.eq(expr._tier, "pure")
  end)

end)
