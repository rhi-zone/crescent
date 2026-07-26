if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T       = require("lib.test.assert")
local money   = require("lib.money")
local account = require("lib.bookkeeping.account")
local journal = require("lib.bookkeeping.journal")
local ledger  = require("lib.bookkeeping.ledger")

local function usd_chart()
  local chart = account.new()
  account.add_account(chart, { id = "cash",    name = "Cash",    type = "asset" })
  account.add_account(chart, { id = "revenue", name = "Revenue", type = "revenue" })
  return chart
end

-- journal.new returns (nil, err) on an invalid currency; this test suite
-- only ever passes known-good ISO codes, so assert instead of threading
-- `| nil` through every call site.
local function new_journal(currency)
  local j, err = journal.new(currency)
  if j == nil then error(err) end
  return j
end

T.describe("lib.bookkeeping.ledger", function()

  T.describe("build / balance_in / rows", function()
    T.it("computes a running balance across entries", function()
      local j = new_journal("USD")
      local chart = usd_chart()
      journal.post(j, chart, {
        date = "2026-07-01", description = "sale 1",
        lines = {
          { account = "cash",    amount = money.new("100.00", "USD") },
          { account = "revenue", amount = money.new("-100.00", "USD") },
        },
      })
      journal.post(j, chart, {
        date = "2026-07-02", description = "sale 2",
        lines = {
          { account = "cash",    amount = money.new("50.00", "USD") },
          { account = "revenue", amount = money.new("-50.00", "USD") },
        },
      })

      local l, err = ledger.build(j)
      T.ok(l ~= nil, err)

      local bal = ledger.balance_in(l, "cash", "USD")
      T.eq(bal.amount_minor, 15000)

      local rows = ledger.rows(l, "cash", "USD")
      T.eq(#rows, 2)
      T.eq(rows[1].balance.amount_minor, 10000)
      T.eq(rows[2].balance.amount_minor, 15000)
    end)

    T.it("sorts rows by date, not posting order", function()
      local j = new_journal("USD")
      local chart = usd_chart()
      -- Post the later-dated entry first.
      journal.post(j, chart, {
        date = "2026-07-10", description = "later",
        lines = {
          { account = "cash",    amount = money.new("10.00", "USD") },
          { account = "revenue", amount = money.new("-10.00", "USD") },
        },
      })
      journal.post(j, chart, {
        date = "2026-07-01", description = "earlier",
        lines = {
          { account = "cash",    amount = money.new("5.00", "USD") },
          { account = "revenue", amount = money.new("-5.00", "USD") },
        },
      })

      local l = ledger.build(j)
      local rows = ledger.rows(l, "cash", "USD")
      T.eq(rows[1].date, "2026-07-01")
      T.eq(rows[1].balance.amount_minor, 500)
      T.eq(rows[2].date, "2026-07-10")
      T.eq(rows[2].balance.amount_minor, 1500)
    end)

    T.it("breaks same-date ties by posting order", function()
      local j = new_journal("USD")
      local chart = usd_chart()
      journal.post(j, chart, {
        date = "2026-07-01", description = "first posted",
        lines = {
          { account = "cash",    amount = money.new("1.00", "USD") },
          { account = "revenue", amount = money.new("-1.00", "USD") },
        },
      })
      journal.post(j, chart, {
        date = "2026-07-01", description = "second posted",
        lines = {
          { account = "cash",    amount = money.new("2.00", "USD") },
          { account = "revenue", amount = money.new("-2.00", "USD") },
        },
      })

      local l = ledger.build(j)
      local rows = ledger.rows(l, "cash", "USD")
      T.eq(rows[1].description, "first posted")
      T.eq(rows[2].description, "second posted")
    end)

    T.it("returns nil for an account/currency with no postings", function()
      local j = new_journal("USD")
      local chart = usd_chart()
      local l = ledger.build(j)
      T.eq(ledger.balance_in(l, "cash", "USD"), nil)
      T.eq(ledger.rows(l, "cash", "USD"), nil)
    end)
  end)

  T.describe("multi-currency accounts", function()
    T.it("keeps a separate balance per currency for the same account", function()
      local j = new_journal("USD")
      local chart = account.new()
      account.add_account(chart, { id = "cash",   name = "Cash",   type = "asset" })
      account.add_account(chart, { id = "equity", name = "Equity", type = "equity" })

      journal.post(j, chart, {
        date = "2026-07-01", description = "USD deposit",
        lines = {
          { account = "cash",   amount = money.new("100.00", "USD") },
          { account = "equity", amount = money.new("-100.00", "USD") },
        },
      })
      journal.post(j, chart, {
        date = "2026-07-02", description = "EUR deposit",
        lines = {
          { account = "cash",   amount = money.new("50.00", "EUR"), rate = 1.0 },
          { account = "equity", amount = money.new("-50.00", "EUR"), rate = 1.0 },
        },
      })

      local l = ledger.build(j)
      local by_currency = ledger.balance(l, "cash")
      T.eq(by_currency.USD.amount_minor, 10000)
      T.eq(by_currency.EUR.amount_minor, 5000)

      local currencies = ledger.currencies(l, "cash")
      T.eq(#currencies, 2)
      T.eq(currencies[1], "EUR")
      T.eq(currencies[2], "USD")
    end)
  end)
end)
