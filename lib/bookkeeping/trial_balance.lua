if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Trial balance for lib/bookkeeping.
--
-- Every journal line already carries a `book_amount` (computed at posting
-- time in lib/bookkeeping/journal.lua, via each line's recorded exchange
-- rate). Because every posted entry's book_amounts sum to zero by
-- construction (the posting invariant), a trial balance built by summing
-- book_amount per account is *guaranteed* to balance — trial_balance.verify
-- is a regression check on that invariant, not an independent computation.
--
-- No rate table is needed here: conversion already happened at posting
-- time, using the rate each entry recorded. This does not require ledger.lua
-- (which reports native-currency balances); trial_balance reads the journal
-- directly.

local money   = require("lib.money")
local account = require("lib.bookkeeping.account")

local M = {}

--:: money_value = { amount_minor: number, currency: string }
--:: journal_line = { account: string, amount: money_value, rate: number | nil, book_amount: money_value }
--:: journal_entry = { id: string, date: string, description: string, lines: { [number]: journal_line } }
--:: journal = { book_currency: string, entries: { [number]: journal_entry }, [string]: unknown }

-- Mirrors lib.bookkeeping.account's shapes; see lib/bookkeeping/journal.lua
-- for why this can't be a non-duplicating reference to account.lua's alias.
--:: account_type = "asset" | "liability" | "equity" | "revenue" | "expense"
--:: chart_account = {
--::   id: string, name: string, type: account_type,
--::   code: string | nil, description: string | nil, parent: string | nil,
--:: }
--:: chart = { by_id: { [string]: chart_account }, order: { [number]: string } }

--:: trial_balance_row = {
--::   account_id: string, name: string, type: account_type,
--::   balance: money_value, debit: money_value | nil, credit: money_value | nil,
--:: }
--:: trial_balance = {
--::   book_currency: string,
--::   rows: { [number]: trial_balance_row },
--::   total_debit: money_value, total_credit: money_value,
--:: }

--- Build a trial balance (one row per chart account, book-currency balance)
-- as of all entries currently posted to `journal`. Accounts with no
-- postings appear with a zero balance.
--: (journal, chart) -> (trial_balance | nil, string | nil)
M.build = function(journal, chart)
  local book_currency = journal.book_currency
  local zero = money.new(0, book_currency)
  if zero == nil then
    return nil, "trial_balance.build: unknown book currency: " .. book_currency
  end

  local totals = {} --: { [string]: money_value }
  local entries = journal.entries
  for _, entry in ipairs(entries) do
    for _, line in ipairs(entry.lines) do
      local prior = totals[line.account]
      if prior == nil then prior = zero end
      local sum, err = money.add(prior, line.book_amount)
      if not sum then return nil, "trial_balance.build: " .. tostring(err) end
      totals[line.account] = sum
    end
  end

  local rows = {} --: { [number]: trial_balance_row }
  local total_debit  = zero
  local total_credit = zero
  local accounts = account.list(chart)
  for i = 1, #accounts do
    local acct = accounts[i]
    local balance = totals[acct.id]
    if balance == nil then balance = zero end

    local debit  --: money_value | nil
    local credit --: money_value | nil
    if balance.amount_minor > 0 then
      debit = balance
      local sum, err = money.add(total_debit, balance)
      if not sum then return nil, "trial_balance.build: " .. tostring(err) end
      total_debit = sum
    elseif balance.amount_minor < 0 then
      local neg = money.negate(balance)
      credit = neg
      local sum, err = money.add(total_credit, neg)
      if not sum then return nil, "trial_balance.build: " .. tostring(err) end
      total_credit = sum
    end

    rows[i] = {
      account_id = acct.id,
      name       = acct.name,
      type       = acct.type,
      balance    = balance,
      debit      = debit,
      credit     = credit,
    }
  end

  return {
    book_currency = book_currency,
    rows          = rows,
    total_debit   = total_debit,
    total_credit  = total_credit,
  }
end

--- Does this trial balance's total debits equal total credits? Given
-- M.build's construction this should always hold; a false result indicates
-- a bug in journal posting, not a normal validation failure a caller should
-- expect to handle.
--: trial_balance -> (boolean, string | nil)
M.verify = function(trial_balance)
  if money.eq(trial_balance.total_debit, trial_balance.total_credit) then
    return true
  end
  return false, "trial_balance.verify: total debit " .. money.to_string(trial_balance.total_debit)
    .. " != total credit " .. money.to_string(trial_balance.total_credit)
end

--- Restate the trial balance as the extended accounting equation
-- (pre-closing-entries form): Assets + Expenses = Liabilities + Equity +
-- Revenue. Debit-normal balances (asset, expense) are compared against the
-- negated sum of credit-normal balances (liability, equity, revenue).
-- This is a corollary of M.verify's debit=credit check, restated by account
-- type; it does not perform an independent computation.
--: trial_balance -> (boolean, string | nil)
M.accounting_equation = function(trial_balance)
  local zero = money.new(0, trial_balance.book_currency)
  if zero == nil then
    return false, "trial_balance.accounting_equation: unknown book currency: " .. trial_balance.book_currency
  end
  local debit_side  = zero
  local credit_side = zero
  local rows = trial_balance.rows
  for i = 1, #rows do
    local row = rows[i]
    local is_debit_normal, err = account.is_debit_normal(row.type)
    if is_debit_normal == nil then
      return false, "trial_balance.accounting_equation: " .. tostring(err)
    end
    if is_debit_normal then
      local sum, add_err = money.add(debit_side, row.balance)
      if not sum then return false, "trial_balance.accounting_equation: " .. tostring(add_err) end
      debit_side = sum
    else
      local sum, add_err = money.add(credit_side, row.balance)
      if not sum then return false, "trial_balance.accounting_equation: " .. tostring(add_err) end
      credit_side = sum
    end
  end

  local negated_credit = money.negate(credit_side)
  if money.eq(debit_side, negated_credit) then
    return true
  end
  return false, "trial_balance.accounting_equation: asset+expense " .. money.to_string(debit_side)
    .. " != -(liability+equity+revenue) " .. money.to_string(negated_credit)
end

return M
