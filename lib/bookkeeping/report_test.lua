if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T       = require("lib.test.assert")
local money   = require("lib.money")
local account = require("lib.bookkeeping.account")
local journal = require("lib.bookkeeping.journal")
local report  = require("lib.bookkeeping.report")

local function new_journal(currency)
  local j, err = journal.new(currency)
  if j == nil then error(err) end
  return j
end

local function full_chart()
  local chart = account.new()
  account.add_account(chart, { id = "cash",         name = "Cash",         type = "asset" })
  account.add_account(chart, { id = "loan-payable",  name = "Loan Payable", type = "liability" })
  account.add_account(chart, { id = "owner-equity",  name = "Owner Equity", type = "equity" })
  account.add_account(chart, { id = "sales",         name = "Sales",        type = "revenue" })
  account.add_account(chart, { id = "rent-expense",  name = "Rent Expense", type = "expense" })
  return chart
end

T.describe("lib.bookkeeping.report", function()

  T.describe("income_statement", function()
    T.it("computes revenue - expenses for a date range, excluding entries outside it", function()
      local chart = full_chart()
      local j = new_journal("USD")
      journal.post(j, chart, {
        date = "2026-01-05", description = "Sale",
        lines = {
          { account = "cash",  amount = money.new("1000.00", "USD") },
          { account = "sales", amount = money.new("-1000.00", "USD") },
        },
      })
      journal.post(j, chart, {
        date = "2026-01-10", description = "Rent",
        lines = {
          { account = "rent-expense", amount = money.new("300.00", "USD") },
          { account = "cash",         amount = money.new("-300.00", "USD") },
        },
      })
      -- Outside the reported range — must not affect the totals.
      journal.post(j, chart, {
        date = "2026-02-01", description = "Next month's sale",
        lines = {
          { account = "cash",  amount = money.new("500.00", "USD") },
          { account = "sales", amount = money.new("-500.00", "USD") },
        },
      })

      local is_, err = report.income_statement(j, chart, { start_date = "2026-01-01", end_date = "2026-01-31" })
      T.ok(is_ ~= nil, err)
      T.eq(is_.total_revenue.amount_minor, 100000)
      T.eq(is_.total_expenses.amount_minor, 30000)
      T.eq(is_.net_income.amount_minor, 70000)
      T.eq(is_.net_income.currency, "USD")
    end)

    T.it("includes every revenue/expense account, even with zero activity in range", function()
      local chart = full_chart()
      local j = new_journal("USD")
      local is_, err = report.income_statement(j, chart, { start_date = "2026-01-01", end_date = "2026-01-31" })
      T.ok(is_ ~= nil, err)
      T.eq(#is_.revenue_rows, 1)
      T.eq(#is_.expense_rows, 1)
      T.eq(is_.revenue_rows[1].amount.amount_minor, 0)
      T.eq(is_.expense_rows[1].amount.amount_minor, 0)
      T.eq(is_.net_income.amount_minor, 0)
    end)
  end)

  T.describe("balance_sheet", function()
    T.it("balances (Assets = Liabilities + Equity) including unclosed net income", function()
      local chart = full_chart()
      local j = new_journal("USD")
      -- Owner invests, borrows, makes a sale, pays rent.
      journal.post(j, chart, {
        date = "2026-01-01", description = "Owner investment",
        lines = {
          { account = "cash",         amount = money.new("1000.00", "USD") },
          { account = "owner-equity", amount = money.new("-1000.00", "USD") },
        },
      })
      journal.post(j, chart, {
        date = "2026-01-02", description = "Bank loan",
        lines = {
          { account = "cash",        amount = money.new("500.00", "USD") },
          { account = "loan-payable", amount = money.new("-500.00", "USD") },
        },
      })
      journal.post(j, chart, {
        date = "2026-01-05", description = "Sale",
        lines = {
          { account = "cash",  amount = money.new("200.00", "USD") },
          { account = "sales", amount = money.new("-200.00", "USD") },
        },
      })
      journal.post(j, chart, {
        date = "2026-01-10", description = "Rent",
        lines = {
          { account = "rent-expense", amount = money.new("50.00", "USD") },
          { account = "cash",         amount = money.new("-50.00", "USD") },
        },
      })

      local bs, err = report.balance_sheet(j, chart, { as_of = "2026-01-31" })
      T.ok(bs ~= nil, err)
      T.eq(bs.total_assets.amount_minor, 165000)
      T.eq(bs.total_liabilities.amount_minor, 50000)
      T.eq(bs.net_income.amount_minor, 15000)
      T.eq(bs.total_equity.amount_minor, 100000 + 15000)

      local ok, verr = report.verify_balance_sheet(bs)
      T.ok(ok, verr)
    end)

    T.it("excludes entries dated after as_of", function()
      local chart = full_chart()
      local j = new_journal("USD")
      journal.post(j, chart, {
        date = "2026-01-01", description = "Owner investment",
        lines = {
          { account = "cash",         amount = money.new("1000.00", "USD") },
          { account = "owner-equity", amount = money.new("-1000.00", "USD") },
        },
      })
      journal.post(j, chart, {
        date = "2026-02-01", description = "Later sale",
        lines = {
          { account = "cash",  amount = money.new("100.00", "USD") },
          { account = "sales", amount = money.new("-100.00", "USD") },
        },
      })

      local bs, err = report.balance_sheet(j, chart, { as_of = "2026-01-31" })
      T.ok(bs ~= nil, err)
      T.eq(bs.total_assets.amount_minor, 100000)
      T.eq(bs.net_income.amount_minor, 0)
    end)

    T.it("still balances with only accounts and no postings", function()
      local chart = full_chart()
      local j = new_journal("USD")
      local bs, err = report.balance_sheet(j, chart, { as_of = "2026-12-31" })
      T.ok(bs ~= nil, err)
      T.eq(bs.total_assets.amount_minor, 0)
      T.eq(bs.total_liabilities.amount_minor, 0)
      T.eq(bs.total_equity.amount_minor, 0)
      local ok, verr = report.verify_balance_sheet(bs)
      T.ok(ok, verr)
    end)
  end)

  T.describe("multi-currency", function()
    T.it("reports in book currency using stored book_amounts", function()
      local chart = full_chart()
      local j = new_journal("USD")
      journal.post(j, chart, {
        date = "2026-01-05", description = "EUR sale",
        lines = {
          { account = "cash",  amount = money.new("100.00", "USD") },
          { account = "sales", amount = money.new("-92.00", "EUR"), rate = 100 / 92 },
        },
      })

      local is_, err = report.income_statement(j, chart, { start_date = "2026-01-01", end_date = "2026-01-31" })
      T.ok(is_ ~= nil, err)
      T.eq(is_.book_currency, "USD")
      T.eq(is_.total_revenue.currency, "USD")
      T.eq(is_.total_revenue.amount_minor, 10000)
    end)
  end)

end)
