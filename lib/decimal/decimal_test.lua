if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local M = require("lib.decimal")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function d(v, scale) return M.new(v, scale) end

T.describe("decimal._tier", function()
  T.it("is pure", function()
    T.eq(M._tier, "pure")
  end)
end)

-- ── M.new construction ────────────────────────────────────────────────────────

T.describe("M.new", function()
  T.it("parses '1.23' → coeff=123, scale=2", function()
    local x = d("1.23")
    T.eq(x.coeff, 123)
    T.eq(x.exp, -2)
    T.eq(M.scale(x), 2)
  end)

  T.it("parses '0.1' → coeff=1, exp=-1", function()
    local x = d("0.1")
    T.eq(x.coeff, 1)
    T.eq(x.exp, -1)
  end)

  T.it("parses '0.2' → coeff=2, exp=-1", function()
    local x = d("0.2")
    T.eq(x.coeff, 2)
    T.eq(x.exp, -1)
  end)

  T.it("parses '0.3' → coeff=3, exp=-1", function()
    local x = d("0.3")
    T.eq(x.coeff, 3)
    T.eq(x.exp, -1)
  end)

  T.it("parses '100' → coeff=1, exp=2", function()
    local x = d("100")
    T.eq(x.coeff, 1)
    T.eq(x.exp, 2)
  end)

  T.it("parses '-1.5' → coeff=-15, exp=-1", function()
    local x = d("-1.5")
    T.eq(x.coeff, -15)
    T.eq(x.exp, -1)
  end)

  T.it("parses '0' → coeff=0, exp=0", function()
    local x = d("0")
    T.eq(x.coeff, 0)
    T.eq(x.exp, 0)
  end)

  T.it("parses integer string '42'", function()
    local x = d("42")
    T.eq(x.coeff, 42)
    T.eq(x.exp, 0)
  end)

  T.it("number 1.5 → exact representation", function()
    local x = d(1.5)
    T.eq(M.to_string(x), "1.5")
  end)

  T.it("number 0 → zero", function()
    local x = d(0)
    T.ok(M.is_zero(x))
  end)

  T.it("with scale pads to given decimal places", function()
    -- M.new(100, 2) → 100.00 → coeff=10000, exp=-2
    local x = d("100", 2)
    T.eq(x.exp, -2)
    T.eq(x.coeff, 10000)
    T.eq(M.to_string(x), "100.00")
  end)

  T.it("parses '1.23e5' (sci notation) → 123000", function()
    local x = d("1.23e5")
    T.eq(M.to_string(x), "123000")
  end)

  T.it("parses '1.5e-3' → 0.0015", function()
    local x = d("1.5e-3")
    T.eq(M.to_string(x), "0.0015")
  end)
end)

-- ── M.parse strict parsing ────────────────────────────────────────────────────

T.describe("M.parse", function()
  T.it("parses valid string", function()
    local x = M.parse("3.14")
    T.ok(x ~= nil)
    T.eq(M.to_string(x), "3.14")
  end)

  T.it("returns nil,err for 'abc'", function()
    local x, err = M.parse("abc")
    T.eq(x, nil)
    T.ok(err ~= nil)
  end)

  T.it("returns nil,err for empty string", function()
    local x, err = M.parse("")
    T.eq(x, nil)
    T.ok(err ~= nil)
  end)

  T.it("returns nil,err for '1.2.3'", function()
    local x, err = M.parse("1.2.3")
    T.eq(x, nil)
    T.ok(err ~= nil)
  end)

  T.it("returns nil,err for non-string input", function()
    local x, err = M.parse(123)
    T.eq(x, nil)
    T.ok(err ~= nil)
  end)
end)

-- ── THE classic float test ────────────────────────────────────────────────────

T.describe("0.1 + 0.2 == 0.3", function()
  T.it("exact decimal addition avoids float error", function()
    local result = M.add(d("0.1"), d("0.2"))
    T.ok(M.eq(result, d("0.3")))
    T.eq(M.to_string(result), "0.3")
    -- Contrast with IEEE 754:
    T.ok(0.1 + 0.2 ~= 0.3)
  end)
end)

-- ── Addition ──────────────────────────────────────────────────────────────────

T.describe("add", function()
  T.it("1.23 + 4.56 = 5.79", function()
    T.ok(M.eq(M.add(d("1.23"), d("4.56")), d("5.79")))
  end)

  T.it("different scales: 1.5 + 0.25 = 1.75", function()
    T.ok(M.eq(M.add(d("1.5"), d("0.25")), d("1.75")))
  end)

  T.it("negative + positive: -1 + 3 = 2", function()
    T.ok(M.eq(M.add(d("-1"), d("3")), d("2")))
  end)

  T.it("x + 0 = x", function()
    T.ok(M.eq(M.add(d("3.14"), M.ZERO), d("3.14")))
  end)
end)

-- ── Subtraction ───────────────────────────────────────────────────────────────

T.describe("sub", function()
  T.it("5 - 3 = 2", function()
    T.ok(M.eq(M.sub(d("5"), d("3")), d("2")))
  end)

  T.it("1 - 1.5 = -0.5", function()
    T.ok(M.eq(M.sub(d("1"), d("1.5")), d("-0.5")))
  end)

  T.it("1.00 - 0.01 = 0.99", function()
    T.ok(M.eq(M.sub(d("1.00"), d("0.01")), d("0.99")))
  end)
end)

-- ── Multiplication ────────────────────────────────────────────────────────────

T.describe("mul", function()
  T.it("1.5 * 2 = 3", function()
    T.ok(M.eq(M.mul(d("1.5"), d("2")), d("3")))
  end)

  T.it("1.23 * 1.00 = 1.23", function()
    T.ok(M.eq(M.mul(d("1.23"), d("1.00")), d("1.23")))
  end)

  T.it("0.1 * 0.1 = 0.01", function()
    T.ok(M.eq(M.mul(d("0.1"), d("0.1")), d("0.01")))
  end)

  T.it("negative: -3 * 4 = -12", function()
    T.ok(M.eq(M.mul(d("-3"), d("4")), d("-12")))
  end)

  T.it("negative * negative: -3 * -4 = 12", function()
    T.ok(M.eq(M.mul(d("-3"), d("-4")), d("12")))
  end)
end)

-- ── Division ──────────────────────────────────────────────────────────────────

T.describe("div", function()
  T.it("10 / 3 with scale=4 → 3.3333", function()
    local result = M.div(d("10"), d("3"), 4)
    T.eq(M.to_string(result), "3.3333")
  end)

  T.it("1 / 4 = 0.25 (exact)", function()
    local result = M.div(d("1"), d("4"), 4)
    T.ok(M.eq(result, d("0.25")))
  end)

  T.it("7 / 2 = 3.5", function()
    local result = M.div(d("7"), d("2"), 4)
    T.ok(M.eq(result, d("3.5")))
  end)

  T.it("divide by zero returns nil,err", function()
    local r, err = M.div(d("1"), d("0"), 2)
    T.eq(r, nil)
    T.ok(err ~= nil)
  end)

  T.it("negative division: -10 / 4 with scale=2 → -2.5", function()
    local result = M.div(d("-10"), d("4"), 2)
    T.ok(M.eq(result, d("-2.5")))
  end)
end)

-- ── neg / abs ─────────────────────────────────────────────────────────────────

T.describe("neg and abs", function()
  T.it("neg(1.5) = -1.5", function()
    T.ok(M.eq(M.neg(d("1.5")), d("-1.5")))
  end)

  T.it("neg(-2) = 2", function()
    T.ok(M.eq(M.neg(d("-2")), d("2")))
  end)

  T.it("abs(-3.14) = 3.14", function()
    T.ok(M.eq(M.abs_val(d("-3.14")), d("3.14")))
  end)

  T.it("abs(3.14) = 3.14", function()
    T.ok(M.eq(M.abs_val(d("3.14")), d("3.14")))
  end)
end)

-- ── Rounding ──────────────────────────────────────────────────────────────────

T.describe("round half_up", function()
  T.it("2.345 round 2 → 2.35", function()
    T.eq(M.to_string(M.round(d("2.345"), 2, "half_up")), "2.35")
  end)

  T.it("2.344 round 2 → 2.34", function()
    T.eq(M.to_string(M.round(d("2.344"), 2, "half_up")), "2.34")
  end)

  T.it("-2.345 round 2 half_up → -2.35", function()
    T.eq(M.to_string(M.round(d("-2.345"), 2, "half_up")), "-2.35")
  end)
end)

T.describe("round half_down", function()
  T.it("2.345 round 2 → 2.34", function()
    T.eq(M.to_string(M.round(d("2.345"), 2, "half_down")), "2.34")
  end)

  T.it("2.346 round 2 → 2.35", function()
    T.eq(M.to_string(M.round(d("2.346"), 2, "half_down")), "2.35")
  end)
end)

T.describe("round half_even (banker's rounding)", function()
  T.it("2.345 round 2 → 2.34 (4 is even)", function()
    T.eq(M.to_string(M.round(d("2.345"), 2, "half_even")), "2.34")
  end)

  T.it("2.355 round 2 → 2.36 (6 is even)", function()
    T.eq(M.to_string(M.round(d("2.355"), 2, "half_even")), "2.36")
  end)

  T.it("2.365 round 2 → 2.36 (6 is even)", function()
    T.eq(M.to_string(M.round(d("2.365"), 2, "half_even")), "2.36")
  end)
end)

T.describe("round floor", function()
  T.it("2.9 round 0 floor → 2", function()
    T.eq(M.to_string(M.round(d("2.9"), 0, "floor")), "2")
  end)

  T.it("-2.1 round 0 floor → -3", function()
    T.eq(M.to_string(M.round(d("-2.1"), 0, "floor")), "-3")
  end)

  T.it("2.0 round 0 floor → 2", function()
    T.eq(M.to_string(M.round(d("2.0"), 0, "floor")), "2")
  end)
end)

T.describe("round ceil", function()
  T.it("2.1 round 0 ceil → 3", function()
    T.eq(M.to_string(M.round(d("2.1"), 0, "ceil")), "3")
  end)

  T.it("-2.9 round 0 ceil → -2", function()
    T.eq(M.to_string(M.round(d("-2.9"), 0, "ceil")), "-2")
  end)
end)

T.describe("round truncate", function()
  T.it("2.9 round 0 truncate → 2", function()
    T.eq(M.to_string(M.round(d("2.9"), 0, "truncate")), "2")
  end)

  T.it("-2.9 round 0 truncate → -2", function()
    T.eq(M.to_string(M.round(d("-2.9"), 0, "truncate")), "-2")
  end)
end)

-- ── Comparison ────────────────────────────────────────────────────────────────

T.describe("cmp / eq / lt / le", function()
  T.it("1 < 2", function()
    T.ok(M.lt(d("1"), d("2")))
  end)

  T.it("2 > 1 (not lt)", function()
    T.ok(not M.lt(d("2"), d("1")))
  end)

  T.it("1.0 == 1 (different scale, same value)", function()
    T.ok(M.eq(d("1.0"), d("1")))
  end)

  T.it("1.23 le 1.23", function()
    T.ok(M.le(d("1.23"), d("1.23")))
  end)

  T.it("1.22 le 1.23", function()
    T.ok(M.le(d("1.22"), d("1.23")))
  end)

  T.it("cmp(1, 2) = -1", function()
    T.eq(M.cmp(d("1"), d("2")), -1)
  end)

  T.it("cmp(2, 1) = 1", function()
    T.eq(M.cmp(d("2"), d("1")), 1)
  end)

  T.it("cmp(1, 1) = 0", function()
    T.eq(M.cmp(d("1"), d("1")), 0)
  end)

  T.it("negative vs positive", function()
    T.ok(M.lt(d("-1"), d("1")))
    T.ok(not M.lt(d("1"), d("-1")))
  end)
end)

-- ── to_string ─────────────────────────────────────────────────────────────────

T.describe("to_string", function()
  T.it("1.23 → '1.23'", function()
    T.eq(M.to_string(d("1.23")), "1.23")
  end)

  T.it("100 → '100'", function()
    T.eq(M.to_string(d("100")), "100")
  end)

  T.it("-0.05 → '-0.05'", function()
    T.eq(M.to_string(d("-0.05")), "-0.05")
  end)

  T.it("0 → '0'", function()
    T.eq(M.to_string(d("0")), "0")
  end)

  T.it("0.001 → '0.001'", function()
    T.eq(M.to_string(d("0.001")), "0.001")
  end)

  T.it("10.00 after adding scale → '10.00'", function()
    local x = d("10", 2)
    T.eq(M.to_string(x), "10.00")
  end)
end)

-- ── Metamethods ───────────────────────────────────────────────────────────────

T.describe("metamethods", function()
  T.it("+ operator", function()
    local r = d("1") + d("2")
    T.ok(M.eq(r, d("3")))
  end)

  T.it("- operator", function()
    local r = d("5") - d("3")
    T.ok(M.eq(r, d("2")))
  end)

  T.it("* operator", function()
    local r = d("2") * d("3")
    T.ok(M.eq(r, d("6")))
  end)

  T.it("== operator", function()
    T.ok(d("1.0") == d("1"))
  end)

  T.it("< operator", function()
    T.ok(d("1") < d("2"))
  end)

  T.it("<= operator (equal)", function()
    T.ok(d("1") <= d("1"))
  end)

  T.it("<= operator (less)", function()
    T.ok(d("1") <= d("2"))
  end)

  T.it("tostring metamethod", function()
    T.eq(tostring(d("1.23")), "1.23")
  end)

  T.it("unary minus", function()
    local r = -d("3.14")
    T.ok(M.eq(r, d("-3.14")))
  end)

  T.it("method-style: d:add(b)", function()
    local x = d("1.5")
    local y = d("2.5")
    T.ok(M.eq(x:add(y), d("4")))
  end)

  T.it("method-style: d:round(2)", function()
    local x = d("3.145")
    T.eq(M.to_string(x:round(2)), "3.15")
  end)
end)

-- ── is_zero / is_negative / sign ──────────────────────────────────────────────

T.describe("properties", function()
  T.it("is_zero: zero is zero", function()
    T.ok(M.is_zero(d("0")))
  end)

  T.it("is_zero: non-zero is not zero", function()
    T.ok(not M.is_zero(d("1")))
  end)

  T.it("is_negative: -1 is negative", function()
    T.ok(M.is_negative(d("-1")))
  end)

  T.it("is_negative: 1 is not negative", function()
    T.ok(not M.is_negative(d("1")))
  end)

  T.it("sign: positive → 1", function()
    T.eq(M.sign(d("3.14")), 1)
  end)

  T.it("sign: negative → -1", function()
    T.eq(M.sign(d("-0.5")), -1)
  end)

  T.it("sign: zero → 0", function()
    T.eq(M.sign(d("0")), 0)
  end)
end)

-- ── to_number / to_integer / scale ────────────────────────────────────────────

T.describe("conversions", function()
  T.it("to_number: 1.5 → 1.5", function()
    T.eq(M.to_number(d("1.5")), 1.5)
  end)

  T.it("to_integer: 3.7 → 3", function()
    T.eq(M.to_integer(d("3.7")), 3)
  end)

  T.it("to_integer: -3.7 → -4 (floor)", function()
    T.eq(M.to_integer(d("-3.7")), -4)
  end)

  T.it("scale: 1.23 → 2", function()
    T.eq(M.scale(d("1.23")), 2)
  end)

  T.it("scale: 100 → 0", function()
    T.eq(M.scale(d("100")), 0)
  end)
end)

-- ── sum / average ─────────────────────────────────────────────────────────────

T.describe("sum", function()
  T.it("sum of [1, 2, 3] = 6", function()
    local r = M.sum({ d("1"), d("2"), d("3") })
    T.ok(M.eq(r, d("6")))
  end)

  T.it("sum of empty list = 0", function()
    local r = M.sum({})
    T.ok(M.is_zero(r))
  end)

  T.it("sum of [0.1, 0.2, 0.3] = 0.6 (exact)", function()
    local r = M.sum({ d("0.1"), d("0.2"), d("0.3") })
    T.ok(M.eq(r, d("0.6")))
  end)
end)

T.describe("average", function()
  T.it("average of [1, 2, 3] = 2", function()
    local r = M.average({ d("1"), d("2"), d("3") })
    T.ok(M.eq(r, d("2")))
  end)

  T.it("average of [1, 2] = 1.5", function()
    local r = M.average({ d("1"), d("2") })
    T.ok(M.eq(r, d("1.5")))
  end)

  T.it("average of empty list returns nil,err", function()
    local r, err = M.average({})
    T.eq(r, nil)
    T.ok(err ~= nil)
  end)
end)

-- ── max / min ─────────────────────────────────────────────────────────────────

T.describe("max / min", function()
  T.it("max(1, 2) = 2", function()
    T.ok(M.eq(M.max(d("1"), d("2")), d("2")))
  end)

  T.it("max(-1, -2) = -1", function()
    T.ok(M.eq(M.max(d("-1"), d("-2")), d("-1")))
  end)

  T.it("min(1, 2) = 1", function()
    T.ok(M.eq(M.min(d("1"), d("2")), d("1")))
  end)

  T.it("min(-1, -2) = -2", function()
    T.ok(M.eq(M.min(d("-1"), d("-2")), d("-2")))
  end)
end)

-- ── Constants ─────────────────────────────────────────────────────────────────

T.describe("constants", function()
  T.it("ZERO is zero", function()
    T.ok(M.is_zero(M.ZERO))
  end)

  T.it("ONE equals 1", function()
    T.ok(M.eq(M.ONE, d("1")))
  end)
end)
