if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local M = require("lib.money")

T.describe("lib.money", function()

  -- ── currency metadata ────────────────────────────────────────────────────

  T.describe("M.CURRENCIES / M.currency / M.is_valid_currency", function()
    T.it("USD has 2 decimals and symbol $", function()
      local c = M.currency("USD")
      T.ok(c ~= nil)
      T.eq(c.decimals, 2)
      T.eq(c.symbol, "$")
      T.eq(c.name, "US Dollar")
      T.ok(c.symbol_before)
    end)

    T.it("JPY has 0 decimals", function()
      local c = M.currency("JPY")
      T.ok(c ~= nil)
      T.eq(c.decimals, 0)
    end)

    T.it("EUR metadata", function()
      local c = M.currency("EUR")
      T.ok(c ~= nil)
      T.eq(c.decimals, 2)
      T.eq(c.symbol, "€")
    end)

    T.it("SEK symbol comes after amount", function()
      local c = M.currency("SEK")
      T.ok(c ~= nil)
      T.ok(not c.symbol_before)
    end)

    T.it("is_valid_currency true for known codes", function()
      T.ok(M.is_valid_currency("USD"))
      T.ok(M.is_valid_currency("JPY"))
      T.ok(M.is_valid_currency("KRW"))
    end)

    T.it("is_valid_currency false for unknown codes", function()
      T.ok(not M.is_valid_currency("XYZ"))
      T.ok(not M.is_valid_currency(""))
    end)
  end)

  -- ── constructors ─────────────────────────────────────────────────────────

  T.describe("M.new", function()
    T.it("integer minor units", function()
      local p = M.new(1099, "USD")
      T.eq(p.amount_minor, 1099)
      T.eq(p.currency, "USD")
    end)

    T.it("zero amount", function()
      local p = M.new(0, "USD")
      T.eq(p.amount_minor, 0)
    end)

    T.it("negative minor units", function()
      local p = M.new(-500, "USD")
      T.eq(p.amount_minor, -500)
    end)

    T.it("string decimal input", function()
      local p = M.new("12.34", "USD")
      T.eq(p.amount_minor, 1234)
    end)

    T.it("returns nil, err for unknown currency", function()
      local v, err = M.new(100, "XYZ")
      T.eq(v, nil)
      T.ok(type(err) == "string")
    end)

    T.it("returns nil, err for non-integer float", function()
      local v, err = M.new(10.99, "USD")
      T.eq(v, nil)
      T.ok(type(err) == "string")
    end)
  end)

  T.describe("M.of", function()
    T.it("M.of(12, 34, USD) -> 1234 cents", function()
      local p = M.of(12, 34, "USD")
      T.eq(p.amount_minor, 1234)
      T.eq(p.currency, "USD")
    end)

    T.it("M.of(0, 1, USD) -> 1 cent", function()
      local p = M.of(0, 1, "USD")
      T.eq(p.amount_minor, 1)
    end)

    T.it("M.of(0, 0, JPY) -> 0 yen", function()
      -- JPY has 0 decimals so minor_part must be 0
      local p = M.of(500, 0, "JPY")
      T.eq(p.amount_minor, 500)
    end)
  end)

  T.describe("M.from_string", function()
    T.it('"12.34" USD -> 1234', function()
      local p = M.from_string("12.34", "USD")
      T.eq(p.amount_minor, 1234)
    end)

    T.it('"0.01" USD -> 1', function()
      local p = M.from_string("0.01", "USD")
      T.eq(p.amount_minor, 1)
    end)

    T.it('"1000.00" USD -> 100000', function()
      local p = M.from_string("1000.00", "USD")
      T.eq(p.amount_minor, 100000)
    end)

    T.it("leading zeros in fraction", function()
      local p = M.from_string("1.09", "USD")
      T.eq(p.amount_minor, 109)
    end)

    T.it("trailing zeros in fraction", function()
      local p = M.from_string("1.10", "USD")
      T.eq(p.amount_minor, 110)
    end)

    T.it("negative amount", function()
      local p = M.from_string("-5.00", "USD")
      T.eq(p.amount_minor, -500)
    end)

    T.it("no decimal point", function()
      local p = M.from_string("7", "USD")
      T.eq(p.amount_minor, 700)
    end)

    T.it("JPY (0 decimals)", function()
      local p = M.from_string("500", "JPY")
      T.eq(p.amount_minor, 500)
    end)

    T.it("returns nil, err on bad string", function()
      local v, err = M.from_string("abc", "USD")
      T.eq(v, nil)
      T.ok(type(err) == "string")
    end)
  end)

  T.describe("M.from_float", function()
    T.it("12.34 USD -> 1234 (exact)", function()
      local p = M.from_float(12.34, "USD")
      T.eq(p.amount_minor, 1234)
    end)

    T.it("rounds to minor units", function()
      -- 0.005 * 100 = 0.5 -> rounds to 1
      local p = M.from_float(0.005, "USD")
      T.eq(p.amount_minor, 1)
    end)

    T.it("JPY from float", function()
      local p = M.from_float(500.9, "JPY")
      T.eq(p.amount_minor, 501)
    end)
  end)

  -- ── arithmetic ───────────────────────────────────────────────────────────

  T.describe("arithmetic", function()
    T.it("add same currency", function()
      local a = M.new(1000, "USD")
      local b = M.new(234, "USD")
      local s = a + b
      T.eq(s.amount_minor, 1234)
      T.eq(s.currency, "USD")
    end)

    T.it("subtract same currency", function()
      local a = M.new(2000, "USD")
      local b = M.new(1099, "USD")
      local d = a - b
      T.eq(d.amount_minor, 901)
    end)

    T.it("multiply by integer", function()
      local a = M.new(1099, "USD")
      local r = a * 3
      T.eq(r.amount_minor, 3297)
    end)

    T.it("multiply by float (rounds)", function()
      -- 1099 * 1.5 = 1648.5 -> 1649
      local a = M.new(1099, "USD")
      local r = a * 1.5
      T.eq(r.amount_minor, 1649)
    end)

    T.it("multiply commutative (number * money)", function()
      local a = M.new(100, "USD")
      local r = 2 * a
      T.eq(r.amount_minor, 200)
    end)

    T.it("divide by integer (exact)", function()
      local a = M.new(1000, "USD")
      local r = a / 2
      T.eq(r.amount_minor, 500)
    end)

    T.it("divide rounds half-up", function()
      -- 1099 / 2 = 549.5 -> 550
      local a = M.new(1099, "USD")
      local r = a / 2
      T.eq(r.amount_minor, 550)
    end)

    T.it("unary minus", function()
      local a = M.new(500, "USD")
      local r = -a
      T.eq(r.amount_minor, -500)
    end)

    T.it("currency mismatch add throws", function()
      local a = M.new(100, "USD")
      local b = M.new(100, "EUR")
      T.throws(function() return a + b end)
    end)

    T.it("currency mismatch sub throws", function()
      local a = M.new(100, "USD")
      local b = M.new(100, "EUR")
      T.throws(function() return a - b end)
    end)

    T.it("M.add returns nil, err on currency mismatch", function()
      local a = M.new(100, "USD")
      local b = M.new(100, "EUR")
      local v, err = M.add(a, b)
      T.eq(v, nil)
      T.ok(err:find("USD") ~= nil)
      T.ok(err:find("EUR") ~= nil)
    end)

    T.it("M.sub returns nil, err on currency mismatch", function()
      local a = M.new(100, "USD")
      local b = M.new(100, "EUR")
      local v, err = M.sub(a, b)
      T.eq(v, nil)
      T.ok(type(err) == "string")
    end)
  end)

  -- ── instance methods: negate / abs / predicates ──────────────────────────

  T.describe("negate / abs / predicates", function()
    T.it("negate positive", function()
      local a = M.new(500, "USD")
      T.eq(a:negate().amount_minor, -500)
    end)

    T.it("negate negative", function()
      local a = M.new(-300, "USD")
      T.eq(a:negate().amount_minor, 300)
    end)

    T.it("abs of negative", function()
      local a = M.new(-999, "USD")
      T.eq(a:abs().amount_minor, 999)
    end)

    T.it("abs of positive unchanged", function()
      local a = M.new(999, "USD")
      T.eq(a:abs().amount_minor, 999)
    end)

    T.it("is_zero", function()
      T.ok(M.new(0, "USD"):is_zero())
      T.ok(not M.new(1, "USD"):is_zero())
    end)

    T.it("is_positive", function()
      T.ok(M.new(1, "USD"):is_positive())
      T.ok(not M.new(0, "USD"):is_positive())
      T.ok(not M.new(-1, "USD"):is_positive())
    end)

    T.it("is_negative", function()
      T.ok(M.new(-1, "USD"):is_negative())
      T.ok(not M.new(0, "USD"):is_negative())
      T.ok(not M.new(1, "USD"):is_negative())
    end)
  end)

  -- ── comparison methods ────────────────────────────────────────────────────

  T.describe("comparison methods", function()
    T.it("eq same", function()
      local a = M.new(1000, "USD")
      local b = M.new(1000, "USD")
      T.ok(a:eq(b))
    end)

    T.it("eq different amount", function()
      local a = M.new(1000, "USD")
      local b = M.new(999, "USD")
      T.ok(not a:eq(b))
    end)

    T.it("eq different currency", function()
      local a = M.new(1000, "USD")
      local b = M.new(1000, "EUR")
      T.ok(not a:eq(b))
    end)

    T.it("lt", function()
      local a = M.new(500, "USD")
      local b = M.new(1000, "USD")
      T.ok(a:lt(b))
      T.ok(not b:lt(a))
    end)

    T.it("le equal", function()
      local a = M.new(500, "USD")
      T.ok(a:le(a))
    end)

    T.it("gt", function()
      local a = M.new(1000, "USD")
      local b = M.new(500, "USD")
      T.ok(a:gt(b))
    end)

    T.it("ge equal", function()
      local a = M.new(500, "USD")
      T.ok(a:ge(a))
    end)
  end)

  -- ── allocate ─────────────────────────────────────────────────────────────

  T.describe("allocate", function()
    T.it("[1,1,1] splits $1.00 three ways, remainder to first", function()
      -- 100 cents / 3: floor=33 each, 1 leftover -> first gets 34
      local p = M.new(100, "USD")
      local parts = p:allocate({1, 1, 1})
      T.eq(#parts, 3)
      T.eq(parts[1].amount_minor, 34)
      T.eq(parts[2].amount_minor, 33)
      T.eq(parts[3].amount_minor, 33)
      local total = 0
      for i = 1, 3 do total = total + parts[i].amount_minor end
      T.eq(total, 100)
    end)

    T.it("[50,25,25] splits 4:2:2", function()
      local p = M.new(800, "USD")  -- $8.00
      local parts = p:allocate({50, 25, 25})
      T.eq(parts[1].amount_minor, 400)
      T.eq(parts[2].amount_minor, 200)
      T.eq(parts[3].amount_minor, 200)
    end)

    T.it("sum always equals original", function()
      local p = M.new(1099, "USD")
      local parts = p:allocate({1, 2, 3})
      local total = 0
      for i = 1, #parts do total = total + parts[i].amount_minor end
      T.eq(total, 1099)
    end)

    T.it("remainder goes to first (largest-remainder) for [1,1,1] on 10 cents", function()
      -- 10 / 3 = 3.33... each; remainders equal so first 1 gets extra
      local p = M.new(10, "USD")
      local parts = p:allocate({1, 1, 1})
      T.eq(parts[1].amount_minor, 4)
      T.eq(parts[2].amount_minor, 3)
      T.eq(parts[3].amount_minor, 3)
    end)
  end)

  -- ── split ────────────────────────────────────────────────────────────────

  T.describe("split", function()
    T.it("even split: 1000 / 4 = 250 each", function()
      local p = M.new(1000, "USD")
      local parts = p:split(4)
      T.eq(#parts, 4)
      for i = 1, 4 do T.eq(parts[i].amount_minor, 250) end
    end)

    T.it("uneven split remainder to first: 1099 / 3", function()
      -- 366 * 3 = 1098, 1 leftover -> first gets 367
      local p = M.new(1099, "USD")
      local parts = p:split(3)
      T.eq(#parts, 3)
      T.eq(parts[1].amount_minor, 367)
      T.eq(parts[2].amount_minor, 366)
      T.eq(parts[3].amount_minor, 366)
      local total = 0
      for i = 1, 3 do total = total + parts[i].amount_minor end
      T.eq(total, 1099)
    end)

    T.it("split 2 with remainder: 101 / 2", function()
      local p = M.new(101, "USD")
      local parts = p:split(2)
      T.eq(parts[1].amount_minor, 51)
      T.eq(parts[2].amount_minor, 50)
    end)
  end)

  -- ── formatting ────────────────────────────────────────────────────────────

  T.describe("format", function()
    T.it("USD symbol before, 2 decimals", function()
      local p = M.new(1234, "USD")
      T.eq(p:format(), "$12.34")
    end)

    T.it("to_string includes currency code", function()
      local p = M.new(1234, "USD")
      T.eq(p:to_string(), "12.34 USD")
    end)

    T.it("EUR symbol", function()
      local p = M.new(500, "EUR")
      T.eq(p:format(), "€5.00")
    end)

    T.it("JPY no decimals", function()
      local p = M.new(1500, "JPY")
      T.eq(p:format(), "¥1500")
      T.eq(p:to_string(), "1500 JPY")
    end)

    T.it("thousands separator USD", function()
      local p = M.new(1234567, "USD")
      T.eq(p:format({ thousands = true }), "$12,345.67")
    end)

    T.it("SEK symbol after with space", function()
      local p = M.new(99900, "SEK")
      T.eq(p:format(), "999.00 kr")
    end)

    T.it("negative amount", function()
      local p = M.new(-1234, "USD")
      T.eq(p:format(), "-$12.34")
    end)
  end)

  -- ── to_float / to_minor ────────────────────────────────────────────────────

  T.describe("to_float / to_minor", function()
    T.it("to_minor returns raw integer", function()
      local p = M.new(1234, "USD")
      T.eq(p:to_minor(), 1234)
    end)

    T.it("to_float converts to major units", function()
      local p = M.new(1234, "USD")
      -- 1234 cents -> 12.34 (floating-point equality OK here — exact power-of-10)
      T.ok(math.abs(p:to_float() - 12.34) < 1e-9)
    end)

    T.it("to_float JPY is exact", function()
      local p = M.new(500, "JPY")
      T.eq(p:to_float(), 500)
    end)
  end)

  -- ── convert ─────────────────────────────────────────────────────────────

  T.describe("M.convert", function()
    T.it("USD->EUR at rate 0.92", function()
      -- $10.00 = 1000 cents; 1000 * 0.92 * 100/100 = 920 EUR cents
      local usd = M.new(1000, "USD")
      local eur = M.convert(usd, "EUR", 0.92)
      T.eq(eur.amount_minor, 920)
      T.eq(eur.currency, "EUR")
    end)

    T.it("USD->JPY (different decimals)", function()
      -- $1.00 = 100 cents; rate=150 JPY/USD -> 100 * 150 * 1/100 = 150 yen
      local usd = M.new(100, "USD")
      local jpy = M.convert(usd, "JPY", 150)
      T.eq(jpy.amount_minor, 150)
      T.eq(jpy.currency, "JPY")
    end)

    T.it("rate causes rounding", function()
      -- 1 cent * 1.005 * 100/100 = 1.005 -> rounds to 1
      local usd = M.new(1, "USD")
      local eur = M.convert(usd, "EUR", 1.005)
      T.eq(eur.amount_minor, 1)
    end)

    T.it("returns nil, err for unknown target currency", function()
      local usd = M.new(100, "USD")
      local v, err = M.convert(usd, "XYZ", 1.0)
      T.eq(v, nil)
      T.ok(type(err) == "string")
    end)
  end)

  -- ── M._tier ───────────────────────────────────────────────────────────────

  T.describe("M._tier", function()
    T.it("is 'pure'", function()
      T.eq(M._tier, "pure")
    end)
  end)

end)
