if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local M = require("lib.money")

T.describe("lib.money", function()

  T.describe("M.currencies", function()
    T.it("contains USD, EUR, GBP", function()
      T.ok(M.currencies["USD"] ~= nil, "USD present")
      T.ok(M.currencies["EUR"] ~= nil, "EUR present")
      T.ok(M.currencies["GBP"] ~= nil, "GBP present")
      T.eq(M.currencies["USD"].symbol, "$")
      T.eq(M.currencies["USD"].decimals, 2)
      T.eq(M.currencies["EUR"].symbol, "€")
    end)
  end)

  T.describe("M.money construction", function()
    T.it("integer minor units", function()
      local p = M.money(1099, "USD")
      T.eq(p.amount, 1099)
      T.eq(p.currency, "USD")
    end)

    T.it("string decimal input", function()
      local p = M.money("10.99", "USD")
      T.eq(p.amount, 1099)
      T.eq(p.currency, "USD")
    end)

    T.it("zero-decimal currency (JPY)", function()
      local p = M.money(500, "JPY")
      T.eq(p.amount, 500)
    end)

    T.it("currency code normalised to upper", function()
      local p = M.money(100, "usd")
      T.eq(p.currency, "USD")
    end)

    T.it("rejects float minor units", function()
      T.throws(function() M.money(10.99, "USD") end)
    end)
  end)

  T.describe("M.parse", function()
    T.it("parses $10.99", function()
      local p = M.parse("$10.99")
      T.eq(p.amount, 1099)
      T.eq(p.currency, "USD")
    end)

    T.it("parses 10.99 USD", function()
      local p = M.parse("10.99 USD")
      T.eq(p.amount, 1099)
      T.eq(p.currency, "USD")
    end)

    T.it("parses EUR 5.00", function()
      local p = M.parse("EUR 5.00")
      T.eq(p.amount, 500)
      T.eq(p.currency, "EUR")
    end)

    T.it("parses €10.99", function()
      local p = M.parse("€10.99")
      T.eq(p.amount, 1099)
      T.eq(p.currency, "EUR")
    end)

    T.it("returns nil, errmsg on bad input", function()
      local v, err = M.parse("notmoney")
      T.eq(v, nil)
      T.ok(type(err) == "string", "error message returned")
    end)
  end)

  T.describe("M.currency", function()
    T.it("returns info for known currency", function()
      local info = M.currency("USD")
      T.ok(info ~= nil)
      T.eq(info.decimals, 2)
      T.eq(info.name, "US Dollar")
    end)

    T.it("is case-insensitive", function()
      local info = M.currency("usd")
      T.ok(info ~= nil)
    end)
  end)

  T.describe("arithmetic", function()
    T.it("addition: 1099 + 1099 = 2198 cents", function()
      local a = M.money(1099, "USD")
      local b = M.money(1099, "USD")
      local sum = a + b
      T.eq(sum.amount, 2198)
      T.eq(sum.currency, "USD")
    end)

    T.it("subtraction", function()
      local a = M.money(2000, "USD")
      local b = M.money(1099, "USD")
      local diff = a - b
      T.eq(diff.amount, 901)
    end)

    T.it("currency mismatch on addition errors", function()
      local a = M.money(1099, "USD")
      local b = M.money(1099, "EUR")
      T.throws(function() return a + b end)
    end)

    T.it("currency mismatch on subtraction errors", function()
      local a = M.money(1099, "USD")
      local b = M.money(500, "EUR")
      T.throws(function() return a - b end)
    end)

    T.it("multiply by scalar", function()
      local a = M.money(1099, "USD")
      local doubled = a * 2
      T.eq(doubled.amount, 2198)
      T.eq(doubled.currency, "USD")
    end)

    T.it("divide by scalar (rounds half-up)", function()
      -- 1099 / 2 = 549.5 → rounds to 550
      local a = M.money(1099, "USD")
      local half = a / 2
      T.eq(half.amount, 550)
    end)

    T.it("divide exact", function()
      local a = M.money(1000, "USD")
      local half = a / 2
      T.eq(half.amount, 500)
    end)
  end)

  T.describe("comparison", function()
    T.it("== same amount and currency", function()
      local a = M.money(1099, "USD")
      local b = M.money(1099, "USD")
      T.ok(a == b)
    end)

    T.it("== false for different amounts", function()
      local a = M.money(1099, "USD")
      local b = M.money(1100, "USD")
      T.ok(not (a == b))
    end)

    T.it("< ordering", function()
      local a = M.money(500, "USD")
      local b = M.money(1099, "USD")
      T.ok(a < b)
      T.ok(not (b < a))
    end)

    T.it("> ordering", function()
      local a = M.money(1099, "USD")
      local b = M.money(500, "USD")
      T.ok(a > b)
    end)

    T.it("<= and >=", function()
      local a = M.money(500, "USD")
      local b = M.money(500, "USD")
      T.ok(a <= b)
      T.ok(a >= b)
    end)

    T.it("comparison across currencies errors", function()
      local a = M.money(500, "USD")
      local b = M.money(500, "EUR")
      T.throws(function() return a < b end)
    end)
  end)

  T.describe("rounding", function()
    T.it("half_up on integer is identity", function()
      local a = M.money(1099, "USD")
      local r = a:round("half_up")
      T.eq(r.amount, 1099)
    end)

    T.it("half_even on integer is identity", function()
      local a = M.money(1000, "USD")
      local r = a:round("half_even")
      T.eq(r.amount, 1000)
    end)

    T.it("ceil on integer is identity", function()
      local a = M.money(1099, "USD")
      T.eq(a:round("ceil").amount, 1099)
    end)

    T.it("floor on integer is identity", function()
      local a = M.money(1099, "USD")
      T.eq(a:round("floor").amount, 1099)
    end)

    T.it("unknown mode errors", function()
      T.throws(function() M.money(100, "USD"):round("bogus") end)
    end)
  end)

  T.describe("format", function()
    T.it("default: $10.99", function()
      local p = M.money(1099, "USD")
      T.eq(tostring(p), "$10.99")
      T.eq(p:format(), "$10.99")
    end)

    T.it("symbol=false: 10.99 USD", function()
      local p = M.money(1099, "USD")
      T.eq(p:format({ symbol = false }), "10.99 USD")
    end)

    T.it("thousands separator", function()
      local p = M.money(123456, "USD")
      T.eq(p:format({ thousands = true }), "$1,234.56")
    end)

    T.it("thousands separator without symbol", function()
      local p = M.money(1234567, "USD")
      T.eq(p:format({ symbol = false, thousands = true }), "12,345.67 USD")
    end)

    T.it("zero-decimal currency (JPY)", function()
      local p = M.money(500, "JPY")
      T.eq(tostring(p), "¥500")
    end)
  end)

  T.describe("split", function()
    T.it("splits into n parts summing to original", function()
      local p = M.money(1099, "USD")
      local parts = p:split(3)
      T.eq(#parts, 3)
      local total = 0
      for _, part in ipairs(parts) do total = total + part.amount end
      T.eq(total, 1099)
    end)

    T.it("distributes remainder as single pennies to early parts", function()
      -- 1099 / 3 = 366 remainder 1 → first part is 367
      local p = M.money(1099, "USD")
      local parts = p:split(3)
      T.eq(parts[1].amount, 367)
      T.eq(parts[2].amount, 366)
      T.eq(parts[3].amount, 366)
    end)

    T.it("splits evenly when divisible", function()
      local p = M.money(1000, "USD")
      local parts = p:split(4)
      T.eq(#parts, 4)
      for _, part in ipairs(parts) do T.eq(part.amount, 250) end
    end)

    T.it("errors on non-integer n", function()
      T.throws(function() M.money(100, "USD"):split(1.5) end)
    end)
  end)

  T.describe("allocate", function()
    T.it("allocates by ratios summing to original", function()
      local p = M.money(1099, "USD")
      local parts = p:allocate({1, 2, 3})
      T.eq(#parts, 3)
      local total = 0
      for _, part in ipairs(parts) do total = total + part.amount end
      T.eq(total, 1099)
    end)

    T.it("last part absorbs rounding remainder", function()
      local p = M.money(100, "USD")
      local parts = p:allocate({1, 1, 1})
      -- 33 + 33 + 34 = 100
      T.eq(parts[1].amount, 33)
      T.eq(parts[2].amount, 33)
      T.eq(parts[3].amount, 34)
    end)

    T.it("errors on empty ratios", function()
      T.throws(function() M.money(100, "USD"):allocate({}) end)
    end)
  end)

  T.describe("predicates", function()
    T.it("is_zero", function()
      T.ok(M.money(0, "USD"):is_zero())
      T.ok(not M.money(1, "USD"):is_zero())
    end)

    T.it("is_positive", function()
      T.ok(M.money(1, "USD"):is_positive())
      T.ok(not M.money(0, "USD"):is_positive())
      T.ok(not M.money(-1, "USD"):is_positive())
    end)

    T.it("is_negative", function()
      T.ok(M.money(-1, "USD"):is_negative())
      T.ok(not M.money(0, "USD"):is_negative())
      T.ok(not M.money(1, "USD"):is_negative())
    end)
  end)

  T.describe("M.convert", function()
    T.it("converts USD to EUR at given rate", function()
      local usd = M.money(1000, "USD")  -- $10.00
      local eur = M.convert(usd, "EUR", { rate = 0.92 })
      -- 1000 * 0.92 = 920 EUR cents
      T.eq(eur.amount, 920)
      T.eq(eur.currency, "EUR")
    end)

    T.it("returns nil, err when rate missing", function()
      local v, err = M.convert(M.money(100, "USD"), "EUR", {})
      T.eq(v, nil)
      T.ok(type(err) == "string")
    end)
  end)

  T.describe("M._tier", function()
    T.it("is 'pure'", function()
      T.eq(M._tier, "pure")
    end)
  end)

end)
