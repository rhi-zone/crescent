if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T             = require("lib.test.assert")
local money         = require("lib.money")
local account       = require("lib.bookkeeping.account")
local journal       = require("lib.bookkeeping.journal")
local trial_balance = require("lib.bookkeeping.trial_balance")

local function new_journal(currency)
  local j, err = journal.new(currency)
  if j == nil then error(err) end
  return j
end

-- Asset = Liability + Equity + (Revenue - Expense), single currency.
local function full_chart()
  local chart = account.new()
  account.add_account(chart, { id = "cash",         name = "Cash",           type = "asset" })
  account.add_account(chart, { id = "loan-payable",  name = "Loan Payable",  type = "liability" })
  account.add_account(chart, { id = "owner-equity",  name = "Owner Equity",  type = "equity" })
  account.add_account(chart, { id = "sales",         name = "Sales",         type = "revenue" })
  account.add_account(chart, { id = "rent-expense",  name = "Rent Expense",  type = "expense" })
  return chart
end

T.describe("lib.bookkeeping.trial_balance", function()

  T.describe("build / verify (single currency)", function()
    T.it("balances after a simple set of entries", function()
      local j = new_journal("USD")
      local chart = full_chart()

      -- Owner invests $1000 cash.
      journal.post(j, chart, {
        date = "2026-01-01", description = "owner investment",
        lines = {
          { account = "cash",        amount = money.new("1000.00", "USD") },
          { account = "owner-equity", amount = money.new("-1000.00", "USD") },
        },
      })
      -- Take out a $500 loan.
      journal.post(j, chart, {
        date = "2026-01-02", description = "loan",
        lines = {
          { account = "cash",        amount = money.new("500.00", "USD") },
          { account = "loan-payable", amount = money.new("-500.00", "USD") },
        },
      })
      -- $300 in sales.
      journal.post(j, chart, {
        date = "2026-01-03", description = "sales",
        lines = {
          { account = "cash",  amount = money.new("300.00", "USD") },
          { account = "sales", amount = money.new("-300.00", "USD") },
        },
      })
      -- $200 rent expense paid in cash.
      journal.post(j, chart, {
        date = "2026-01-04", description = "rent",
        lines = {
          { account = "rent-expense", amount = money.new("200.00", "USD") },
          { account = "cash",         amount = money.new("-200.00", "USD") },
        },
      })

      local tb, err = trial_balance.build(j, chart)
      T.ok(tb ~= nil, err)
      T.eq(tb.book_currency, "USD")

      local ok, verr = trial_balance.verify(tb)
      T.ok(ok, verr)

      local eok, eerr = trial_balance.accounting_equation(tb)
      T.ok(eok, eerr)

      -- cash = 1000 + 500 + 300 - 200 = 1600
      local cash_row
      for _, row in ipairs(tb.rows) do
        if row.account_id == "cash" then cash_row = row end
      end
      T.ok(cash_row ~= nil)
      T.eq(cash_row.balance.amount_minor, 160000)
      T.eq(cash_row.debit.amount_minor, 160000)
      T.eq(cash_row.credit, nil)
    end)

    T.it("reports a zero balance for an untouched account", function()
      local j = new_journal("USD")
      local chart = full_chart()
      journal.post(j, chart, {
        date = "2026-01-01", description = "x",
        lines = {
          { account = "cash",         amount = money.new("10.00", "USD") },
          { account = "owner-equity", amount = money.new("-10.00", "USD") },
        },
      })

      local tb = trial_balance.build(j, chart)
      local sales_row
      for _, row in ipairs(tb.rows) do
        if row.account_id == "sales" then sales_row = row end
      end
      T.ok(sales_row ~= nil)
      T.eq(sales_row.balance.amount_minor, 0)
      T.eq(sales_row.debit, nil)
      T.eq(sales_row.credit, nil)
    end)

    T.it("includes every chart account even with no entries posted", function()
      local j = new_journal("USD")
      local chart = full_chart()
      local tb = trial_balance.build(j, chart)
      T.eq(#tb.rows, 5)
      local ok = trial_balance.verify(tb)
      T.ok(ok)
    end)
  end)

  T.describe("build / verify (multi-currency)", function()
    T.it("balances the coordinator's worked FX example via book_amount", function()
      local j = new_journal("USD")
      local chart = account.new()
      account.add_account(chart, { id = "cash-usd", name = "Cash USD", type = "asset" })
      account.add_account(chart, { id = "cash-eur", name = "Cash EUR", type = "asset" })

      journal.post(j, chart, {
        date = "2026-07-26", description = "Buy EUR with USD",
        lines = {
          { account = "cash-usd", amount = money.new("-100.00", "USD") },
          { account = "cash-eur", amount = money.new("92.00", "EUR"), rate = 1.0870 },
        },
      })

      local tb, err = trial_balance.build(j, chart)
      T.ok(tb ~= nil, err)
      local ok, verr = trial_balance.verify(tb)
      T.ok(ok, verr)

      T.eq(tb.total_debit.amount_minor, tb.total_credit.amount_minor)
      T.eq(tb.total_debit.currency, "USD")
    end)
  end)
end)
