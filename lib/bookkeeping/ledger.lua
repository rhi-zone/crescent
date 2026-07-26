if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Ledger derivation for lib/bookkeeping: per-account transaction history
-- with running balances, derived from a journal's posted entries.
--
-- Accounts have no fixed currency (lib/bookkeeping/account.lua), so a
-- single account's balance is a map from currency code to a lib.money
-- value, e.g. { USD = money(...), EUR = money(...) }. Running balances are
-- kept and reported per currency — there is no single "the balance" for an
-- account that has received postings in more than one currency.
--
-- Ordering: rows for an account+currency are sorted by the entry's `date`
-- field (ISO 8601 "YYYY-MM-DD", lexicographically sortable), ties broken by
-- posting order (the order entries were passed to journal.post).

local money = require("lib.money")

local M = {}

--:: money_value = { amount_minor: number, currency: string }
--:: journal_line = { account: string, amount: money_value, rate: number | nil, book_amount: money_value }
--:: journal_entry = { id: string, date: string, description: string, lines: { [number]: journal_line } }
--:: journal = { book_currency: string, entries: { [number]: journal_entry }, [string]: unknown }

--:: ledger_row = { entry_id: string, date: string, description: string, amount: money_value, balance: money_value }
--:: account_ledger = { [string]: { balance: money_value, rows: { [number]: ledger_row } } }
--:: ledger = { [string]: account_ledger }

--:: txn = { entry_id: string, date: string, description: string, amount: money_value, posting_index: integer }

--- Build a ledger (per-account, per-currency transaction history with
-- running balances) from all entries currently posted to `journal`.
--: journal -> (ledger | nil, string | nil)
M.build = function(journal)
  -- Gather every (account, currency) line with enough info to sort and
  -- accumulate, tagging each with its posting order for stable tie-break.
  local by_account = {} --: { [string]: { [string]: { [integer]: txn } } }
  local entries = journal.entries

  for posting_index = 1, #entries do
    local entry = entries[posting_index]
    for _, line in ipairs(entry.lines) do
      local acct_id = line.account
      local currency = line.amount.currency

      local by_currency = by_account[acct_id]
      if by_currency == nil then
        by_currency = {}
        by_account[acct_id] = by_currency
      end
      local bucket = by_currency[currency]
      if bucket == nil then
        bucket = {}
        by_currency[currency] = bucket
      end
      bucket[#bucket + 1] = {
        entry_id      = entry.id,
        date          = entry.date,
        description   = entry.description,
        amount        = line.amount,
        posting_index = posting_index,
      }
    end
  end

  local result = {} --: ledger
  for acct_id, by_currency in pairs(by_account) do
    local account_ledger = {} --: account_ledger
    result[acct_id] = account_ledger
    for currency, txns in pairs(by_currency) do
      table.sort(txns, function(a, b)
        if a.date ~= b.date then return a.date < b.date end
        return a.posting_index < b.posting_index
      end)

      local running = money.new(0, currency)
      if running == nil then
        return nil, "ledger.build: unknown currency: " .. currency
      end
      local rows = {} --: { [number]: ledger_row }
      for i = 1, #txns do
        local txn = txns[i]
        local sum, err = money.add(running, txn.amount)
        if not sum then
          return nil, "ledger.build: " .. tostring(err)
        end
        running = sum
        rows[i] = {
          entry_id    = txn.entry_id,
          date        = txn.date,
          description = txn.description,
          amount      = txn.amount,
          balance     = running,
        }
      end

      account_ledger[currency] = { balance = running, rows = rows }
    end
  end

  return result
end

--- The balance map for an account: { [currency]: money }, or nil if the
-- account has no postings in this ledger.
--: (ledger, string) -> ({ [string]: money_value } | nil)
M.balance = function(ledger, account_id)
  local acct = ledger[account_id]
  if acct == nil then return nil end
  local out = {} --: { [string]: money_value }
  for currency, cl in pairs(acct) do
    out[currency] = cl.balance
  end
  return out
end

--- Balance of `account_id` in a specific `currency`, or nil if the account
-- has no postings in that currency.
--: (ledger, string, string) -> money_value | nil
M.balance_in = function(ledger, account_id, currency)
  local acct = ledger[account_id]
  if acct == nil then return nil end
  local cl = acct[currency]
  if cl == nil then return nil end
  return cl.balance
end

--- Ordered (date, then posting order) transaction rows for `account_id` in
-- `currency`, or nil if the account has no postings in that currency.
--: (ledger, string, string) -> ({ [number]: ledger_row } | nil)
M.rows = function(ledger, account_id, currency)
  local acct = ledger[account_id]
  if acct == nil then return nil end
  local cl = acct[currency]
  if cl == nil then return nil end
  return cl.rows
end

-- TYPECHECKER WORKAROUND: the natural code is `table.sort(out)`. Same class
-- of bug as the `table.sort`/`table.remove` entries already logged in
-- TODO.md ("Typechecker substrate gaps ... lib/vt/init.lua" /
-- "... lib/pdf/write.lua"): a generic stdlib function instantiated at one
-- element type earlier in this file (`table.sort(txns, ...)` in M.build,
-- over `txn` records) has its type variable reused for a later call at a
-- different element type (`{ [integer]: string }` here), so the second call
-- is checked against the first call's resolved type and fails with a
-- spurious "indexer value: string has no field 'entry_id'". Worked around
-- with a hand-written insertion sort over strings instead of a second
-- `table.sort` call. Revert to `table.sort(out)` once generic stdlib
-- functions are instantiated fresh per call site.
--: { [integer]: string } -> nil
local function sort_strings(arr)
  for i = 2, #arr do
    local v = arr[i]
    local j = i - 1
    while j >= 1 and arr[j] > v do
      arr[j + 1] = arr[j]
      j = j - 1
    end
    arr[j + 1] = v
  end
end

--- Every currency an account has been posted in, within this ledger.
--: (ledger, string) -> { [integer]: string }
M.currencies = function(ledger, account_id)
  local acct = ledger[account_id]
  local out = {} --: { [integer]: string }
  if acct == nil then return out end
  for currency in pairs(acct) do
    out[#out + 1] = currency
  end
  sort_strings(out)
  return out
end

return M
