if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Income statement (P&L) and balance sheet for lib/bookkeeping.
--
-- Both reports are, like lib.bookkeeping.trial_balance, derived purely by
-- summing each posted line's `book_amount` (already computed at posting
-- time in lib/bookkeeping/journal.lua) — never by re-deriving amounts from
-- scratch. This is what "report in book currency using stored book_amounts"
-- means in multi-currency terms: a line posted in any currency already
-- carries its book-currency-converted amount, so these reports never touch
-- `line.amount`/`line.currency` directly, only `line.book_amount`.
--
-- Sign presentation: the domain model's signed convention (positive =
-- debit) is kept internally, but both reports present revenue, liability,
-- and equity figures as positive numbers (their balances are negated before
-- display) — the conventional income-statement/balance-sheet presentation,
-- not a re-derived amount.
--
-- Balance sheet and the accounting equation: this module has no concept of
-- period-closing entries (there is no "close the books" operation anywhere
-- in lib.bookkeeping), so revenue and expense accounts are never zeroed out
-- into equity. A balance sheet computed by summing only asset/liability/
-- equity account balances would therefore not satisfy Assets = Liabilities
-- + Equity whenever there has been any revenue or expense activity.
-- M.balance_sheet includes a synthetic "Net Income" row under equity —
-- the same revenue-minus-expense figure M.income_statement computes, over
-- all activity up to `as_of` — so the reported total_equity always includes
-- unclosed net income. This is the standard textbook treatment for an
-- interim balance sheet without closing entries, and it is exactly the
-- decomposition lib.bookkeeping.trial_balance.accounting_equation already
-- documents (Assets + Expenses = Liabilities + Equity + Revenue).

local money   = require("lib.money")
local account = require("lib.bookkeeping.account")

local M = {}

--:: money_value = { amount_minor: number, currency: string }
--:: journal_line = { account: string, amount: money_value, rate: number | nil, book_amount: money_value }
--:: journal_entry = { id: string, date: string, description: string, lines: { [number]: journal_line } }
--:: bookkeeping_journal = { book_currency: string, entries: { [number]: journal_entry }, [string]: unknown }

-- Mirrors lib.bookkeeping.account's shapes; see journal.lua's header
-- comment for why this can't be a non-duplicating reference to another
-- module's named type.
--:: account_type = "asset" | "liability" | "equity" | "revenue" | "expense"
--:: chart_account = {
--::   id: string, name: string, type: account_type,
--::   code: string | nil, description: string | nil, parent: string | nil,
--:: }
--:: chart = { by_id: { [string]: chart_account }, order: { [number]: string } }

--:: report_row = { account_id: string, name: string, amount: money_value }
--:: income_statement = {
--::   book_currency: string, start_date: string, end_date: string,
--::   revenue_rows: { [number]: report_row }, expense_rows: { [number]: report_row },
--::   total_revenue: money_value, total_expenses: money_value, net_income: money_value,
--:: }
--:: balance_sheet = {
--::   book_currency: string, as_of: string,
--::   asset_rows: { [number]: report_row }, liability_rows: { [number]: report_row },
--::   equity_rows: { [number]: report_row }, net_income: money_value,
--::   total_assets: money_value, total_liabilities: money_value, total_equity: money_value,
--:: }

-- Sum every line's book_amount into a per-account-id total, restricted to
-- entries whose date satisfies `in_range(date)`. ISO 8601 "YYYY-MM-DD"
-- dates compare correctly with plain string ordering (same assumption
-- lib.bookkeeping.ledger already documents and relies on).
--: (bookkeeping_journal, (string) -> boolean) -> (money_value | nil, { [string]: money_value } | nil, string | nil)
local function sum_book_amounts_by_account(journal_, in_range)
  local zero = money.new(0, journal_.book_currency)
  if zero == nil then
    return nil, nil, "bookkeeping.report: unknown book currency: " .. journal_.book_currency
  end

  local totals = {} --: { [string]: money_value }
  local entries = journal_.entries
  for i = 1, #entries do
    local entry = entries[i]
    if in_range(entry.date) then
      local lines = entry.lines
      for j = 1, #lines do
        local line = lines[j]
        local prior = totals[line.account]
        if prior == nil then prior = zero end
        local sum, err = money.add(prior, line.book_amount)
        if not sum then return nil, nil, "bookkeeping.report: " .. tostring(err) end
        totals[line.account] = sum
      end
    end
  end

  return zero, totals, nil
end

-- Build one report_row per account of `wanted_type`, in chart order, using
-- `totals` (falling back to zero for an account with no activity in the
-- filtered range). `negate` flips the sign for credit-normal types so the
-- report presents a conventional positive figure.
--: (chart, account_type, { [string]: money_value }, money_value, boolean) -> ({ [number]: report_row }, money_value | nil, string | nil)
local function rows_for_type(chart, wanted_type, totals, zero, negate)
  local rows = {} --: { [number]: report_row }
  local total = zero
  local accounts = account.list(chart)
  for i = 1, #accounts do
    local acct = accounts[i]
    if acct.type == wanted_type then
      local balance = totals[acct.id]
      if balance == nil then balance = zero end
      local amount = negate and money.negate(balance) or balance
      rows[#rows + 1] = { account_id = acct.id, name = acct.name, amount = amount }
      local sum, err = money.add(total, amount)
      if not sum then return rows, nil, "bookkeeping.report: " .. tostring(err) end
      total = sum
    end
  end
  return rows, total, nil
end

-- Net income (revenue - expense, both restricted to `in_range`), and the
-- revenue/expense rows behind it. Shared by M.income_statement (its own
-- report) and M.balance_sheet (folded into a synthetic equity row, per this
-- module's header comment on the accounting equation).
--: (bookkeeping_journal, chart, (string) -> boolean) -> ({ [number]: report_row } | nil, { [number]: report_row } | nil, money_value | nil, money_value | nil, money_value | nil, string | nil)
local function compute_net_income(journal_, chart, in_range)
  local zero, totals, sum_err = sum_book_amounts_by_account(journal_, in_range)
  if zero == nil or totals == nil then return nil, nil, nil, nil, nil, sum_err end

  local revenue_rows, total_revenue, rev_err = rows_for_type(chart, "revenue", totals, zero, true)
  if total_revenue == nil then return nil, nil, nil, nil, nil, rev_err end
  local expense_rows, total_expenses, exp_err = rows_for_type(chart, "expense", totals, zero, false)
  if total_expenses == nil then return nil, nil, nil, nil, nil, exp_err end

  local net_income, add_err = money.sub(total_revenue, total_expenses)
  if net_income == nil then return nil, nil, nil, nil, nil, "bookkeeping.report: " .. tostring(add_err) end

  return revenue_rows, expense_rows, total_revenue, total_expenses, net_income, nil
end

--- Income statement (revenue - expenses) for entries dated in
-- [start_date, end_date] inclusive (ISO 8601 "YYYY-MM-DD" strings).
--: (bookkeeping_journal, chart, { start_date: string, end_date: string }) -> (income_statement | nil, string | nil)
M.income_statement = function(journal_, chart, opts)
  local start_date = opts.start_date
  local end_date   = opts.end_date
  --: (string) -> boolean
  local function in_range(date) return date >= start_date and date <= end_date end

  local revenue_rows, expense_rows, total_revenue, total_expenses, net_income, err =
    compute_net_income(journal_, chart, in_range)
  if err then return nil, err end
  if revenue_rows == nil or expense_rows == nil or total_revenue == nil
    or total_expenses == nil or net_income == nil then
    return nil, "bookkeeping.report: internal: compute_net_income returned neither a value nor an error"
  end

  return {
    book_currency = journal_.book_currency,
    start_date = start_date, end_date = end_date,
    revenue_rows = revenue_rows, expense_rows = expense_rows,
    total_revenue = total_revenue, total_expenses = total_expenses, net_income = net_income,
  }
end

--- Balance sheet (Assets = Liabilities + Equity) as of `as_of` (inclusive,
-- ISO 8601 "YYYY-MM-DD"). Includes a synthetic "Net Income" row under
-- equity — see this module's header comment.
--: (bookkeeping_journal, chart, { as_of: string }) -> (balance_sheet | nil, string | nil)
M.balance_sheet = function(journal_, chart, opts)
  local as_of = opts.as_of
  --: (string) -> boolean
  local function up_to(date) return date <= as_of end

  local zero, totals, sum_err = sum_book_amounts_by_account(journal_, up_to)
  if zero == nil or totals == nil then return nil, sum_err end

  local asset_rows, total_assets, asset_err = rows_for_type(chart, "asset", totals, zero, false)
  if total_assets == nil then return nil, asset_err end
  local liability_rows, total_liabilities, liab_err = rows_for_type(chart, "liability", totals, zero, true)
  if total_liabilities == nil then return nil, liab_err end
  local equity_rows, total_equity_own, equity_err = rows_for_type(chart, "equity", totals, zero, true)
  if total_equity_own == nil then return nil, equity_err end

  local _rev_rows, _exp_rows, _total_rev, _total_exp, net_income, ni_err =
    compute_net_income(journal_, chart, up_to)
  if net_income == nil then return nil, ni_err end

  local total_equity, add_err = money.add(total_equity_own, net_income)
  if total_equity == nil then return nil, "bookkeeping.report: " .. tostring(add_err) end

  return {
    book_currency = journal_.book_currency,
    as_of = as_of,
    asset_rows = asset_rows, liability_rows = liability_rows, equity_rows = equity_rows,
    net_income = net_income,
    total_assets = total_assets, total_liabilities = total_liabilities, total_equity = total_equity,
  }
end

--- Does this balance sheet satisfy Assets = Liabilities + Equity (which
-- already includes the synthetic net-income row)? Given M.balance_sheet's
-- construction this should always hold; a false result indicates a bug in
-- journal posting, not a normal validation failure a caller should expect
-- to handle (same role as lib.bookkeeping.trial_balance.verify).
--: balance_sheet -> (boolean, string | nil)
M.verify_balance_sheet = function(bs)
  local rhs, err = money.add(bs.total_liabilities, bs.total_equity)
  if rhs == nil then return false, "bookkeeping.report: " .. tostring(err) end
  if money.eq(bs.total_assets, rhs) then return true end
  return false, "bookkeeping.report: total assets " .. money.to_string(bs.total_assets)
    .. " != total liabilities + equity " .. money.to_string(rhs)
end

return M
