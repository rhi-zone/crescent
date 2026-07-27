if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Journal entries for lib/bookkeeping: double-entry transactions.
--
-- Amount convention: each line carries a *signed* money value. Positive =
-- debit, negative = credit. There is no separate debit/credit field.
--
-- Multi-currency: lines may be in any currency. A line whose currency
-- differs from the journal's book currency must carry a `rate` (units of
-- book currency per 1 unit of the line's currency); the line's contribution
-- to the balance invariant is `book_amount = money.convert(amount, book_currency, rate)`.
-- A line already in the book currency needs no rate; its book_amount is its
-- amount, unconverted (so no rounding is introduced where none is needed).
--
-- Invariant: for every posted entry, the sum of all lines' book_amount is
-- exactly zero (checked in the book currency, where all book_amounts live).

local money   = require("lib.money")
local account = require("lib.bookkeeping.account")

local M = {}

--:: money_value = { amount_minor: number, currency: string }

-- Mirrors lib.bookkeeping.account's `account_type`/`account`/`chart` shapes
-- exactly. crescent's checker infers require() return types from `return M`;
-- it does not expose a required module's `--::` type aliases under a
-- namespace (confirmed: `typeof account.new` and similar field-access forms
-- are rejected — `typeof` only accepts a bare identifier). There is
-- currently no non-duplicating way to reference another module's named
-- type, so this is a deliberate structural echo of account.lua's types, not
-- an independent redefinition — keep in sync if account.lua's shape changes.
--:: account_type = "asset" | "liability" | "equity" | "revenue" | "expense"
--:: chart_account = {
--::   id: string, name: string, type: account_type,
--::   code: string | nil, description: string | nil, parent: string | nil,
--:: }
--:: chart = { by_id: { [string]: chart_account }, order: { [number]: string } }

--:: line_input = { account: string, amount: money_value, rate: number | nil }
--:: line = { account: string, amount: money_value, rate: number | nil, book_amount: money_value }
--:: entry = { id: string, date: string, description: string, lines: { [number]: line } }
--:: post_opts = { date: string, description: string, lines: { [number]: line_input }, id: string | nil }
--:: journal = { book_currency: string, entries: { [number]: entry }, _by_id: { [string]: entry }, _next_id: number }

-- ISO 8601 calendar date: "YYYY-MM-DD". No time component.
local DATE_PATTERN = "^%d%d%d%d%-%d%d%-%d%d$"

--: string -> boolean
local function is_valid_date(s)
  if not s:match(DATE_PATTERN) then return false end
  local mm = tonumber(s:sub(6, 7))
  local dd = tonumber(s:sub(9, 10))
  if mm == nil then return false end
  if mm < 1 or mm > 12 then return false end
  if dd == nil then return false end
  if dd < 1 or dd > 31 then return false end
  return true
end

-- Duck-type check for a lib/money value: a table with a valid currency code
-- and a numeric amount_minor. lib/money does not export a metatable or an
-- `is_money` predicate, so this is the only available check.
--: (v: unknown) -> v is money_value
local function is_money_value(v)
  if type(v) ~= "table" then return false end
  local t = v --[[: { currency: unknown, amount_minor: unknown } ]]
  local currency = t.currency
  if type(currency) ~= "string" then return false end
  if not money.is_valid_currency(currency) then return false end
  if type(t.amount_minor) ~= "number" then return false end
  return true
end

--- Create a new, empty journal denominated in `book_currency`.
--: string -> (journal | nil, string | nil)
M.new = function(book_currency)
  if not money.is_valid_currency(book_currency) then
    return nil, "journal.new: unknown book currency: " .. tostring(book_currency)
  end
  return { book_currency = book_currency, entries = {}, _by_id = {}, _next_id = 1 }
end

-- Validate+convert a single line_input into a posted `line` (with book_amount
-- filled in), against `chart` and `book_currency`. Returns (nil, err) if the
-- line is malformed or references an unknown account.
--: (chart, string, integer, unknown) -> (line | nil, string | nil)
local function build_line(chart, book_currency, idx, line_in)
  if type(line_in) ~= "table" then
    return nil, "journal: line " .. idx .. ": expected a table"
  end
  local li = line_in --[[: { account: unknown, amount: unknown, rate: unknown } ]]

  local acct_id = li.account
  if type(acct_id) ~= "string" then
    return nil, "journal: line " .. idx .. ": account must be a string"
  end
  if not account.get(chart, acct_id) then
    return nil, "journal: line " .. idx .. ": unknown account: " .. acct_id
  end

  local amount = li.amount
  if not is_money_value(amount) then
    return nil, "journal: line " .. idx .. ": amount must be a lib.money value"
  end

  -- TYPECHECKER WORKAROUND: the natural code narrows `rate` once
  -- ("nil, or must be a number") and reuses that narrowed value in both
  -- branches below. Confirmed by minimal repro that narrowing an `unknown`
  -- value toward an *optional* target type (`number | nil`) via a nil-check
  -- followed by a nested type-check does not survive past the guarding `if`
  -- block — even though the identical pattern narrowing toward a
  -- non-optional `T` (single type-check, no nil branch) works fine, and
  -- sequential *atomic* single-condition checks narrowing straight through
  -- to non-nil `number` (no `T | nil` merge involved) also work fine. Only
  -- the "unknown -> optional T" merge is affected. Worked around by
  -- resolving the nil-vs-not-nil split first (each side returns its own
  -- concretely-typed literal instead of threading one shared `rate`
  -- variable through both), so no branch ever needs an `unknown -> T | nil`
  -- narrow. See TODO.md; revert to a single shared narrow once this merges.
  local rate = li.rate
  if rate == nil then
    if amount.currency == book_currency then
      return {
        account     = acct_id,
        amount      = amount,
        rate        = nil,
        book_amount = amount,
      }
    end
    return nil, "journal: line " .. idx .. ": rate required (amount currency "
      .. amount.currency .. " differs from book currency " .. book_currency .. ")"
  end
  if type(rate) ~= "number" then
    return nil, "journal: line " .. idx .. ": rate must be a number"
  end

  if amount.currency == book_currency then
    return {
      account     = acct_id,
      amount      = amount,
      rate        = rate,
      book_amount = amount,
    }
  end

  if rate <= 0 then
    return nil, "journal: line " .. idx .. ": rate must be positive"
  end
  local converted, err = money.convert(amount, book_currency, rate)
  if not converted then
    return nil, "journal: line " .. idx .. ": " .. tostring(err)
  end

  return {
    account     = acct_id,
    amount      = amount,
    rate        = rate,
    book_amount = converted,
  }
end

--- Validate a candidate entry (opts) against `chart` without posting it.
-- Returns the built lines (with book_amount filled in) on success.
--: (journal, chart, post_opts) -> ({ [number]: line } | nil, string | nil)
M.validate = function(journal, chart, opts)
  if not is_valid_date(opts.date) then
    return nil, "journal.validate: date must be an ISO 8601 'YYYY-MM-DD' string, got " .. tostring(opts.date)
  end
  if type(opts.description) ~= "string" then
    return nil, "journal.validate: description must be a string"
  end
  if type(opts.lines) ~= "table" or #opts.lines < 2 then
    return nil, "journal.validate: entry needs at least 2 lines"
  end

  local lines = {} --: { [number]: line }
  local total --: money_value | nil
  for i = 1, #opts.lines do
    local line, err = build_line(chart, journal.book_currency, i, opts.lines[i])
    if not line then return nil, err end
    lines[i] = line
    if total == nil then
      total = line.book_amount
    else
      local sum, add_err = money.add(total, line.book_amount)
      if not sum then return nil, "journal.validate: " .. tostring(add_err) end
      total = sum
    end
  end

  if total == nil then
    return nil, "journal.validate: entry has no lines"
  end
  if not money.is_zero(total) then
    return nil, "journal.validate: entry does not balance in " .. journal.book_currency
      .. " (sum = " .. money.to_string(total) .. ")"
  end

  return lines
end

--- Validate and post a new entry to the journal.
-- If `opts.id` is omitted, an id is auto-assigned ("1", "2", ... in posting
-- order).
--: (journal, chart, post_opts) -> (entry | nil, string | nil)
M.post = function(journal, chart, opts)
  local id = opts.id
  if id ~= nil then
    if id == "" then
      return nil, "journal.post: id must be a non-empty string"
    end
    if journal._by_id[id] then
      return nil, "journal.post: duplicate entry id: " .. id
    end
  end

  local lines, err = M.validate(journal, chart, opts)
  if not lines then return nil, err end

  if id == nil then
    id = tostring(journal._next_id)
    while journal._by_id[id] do
      journal._next_id = journal._next_id + 1
      id = tostring(journal._next_id)
    end
  end
  journal._next_id = journal._next_id + 1

  local entry = {
    id          = id,
    date        = opts.date,
    description = opts.description,
    lines       = lines,
  }

  journal.entries[#journal.entries + 1] = entry
  journal._by_id[id] = entry
  return entry
end

--- All posted entries, in posting order.
--: journal -> { [number]: entry }
M.list = function(journal)
  return journal.entries
end

--- Look up a posted entry by id.
--: (journal, string) -> entry | nil
M.get = function(journal, id)
  return journal._by_id[id]
end

--- Void a posted entry: posts a new reversing entry (same lines, each
-- amount negated) dated `void_date`, rather than mutating or removing the
-- original — the traditional double-entry treatment, so the original entry
-- remains in the journal for audit purposes. Requires `chart` because
-- posting the reversal goes through the normal M.post validation path (same
-- account-existence and balance checks any other posted entry gets).
-- Reversal lines carry the original line's `rate` unchanged, so a
-- multi-currency line reverses using the same exchange rate it was
-- originally posted at (not a rate looked up fresh for `void_date`).
--: (journal, chart, string, string) -> (entry | nil, string | nil)
M.void_entry = function(journal, chart, entry_id, void_date)
  local orig = journal._by_id[entry_id]
  if not orig then
    return nil, "journal.void_entry: unknown entry id: " .. tostring(entry_id)
  end

  local reversing_lines = {} --: { [number]: line_input }
  local orig_lines = orig.lines
  for i = 1, #orig_lines do
    local line = orig_lines[i]
    reversing_lines[i] = { account = line.account, amount = money.negate(line.amount), rate = line.rate }
  end

  return M.post(journal, chart, {
    id          = nil,
    date        = void_date,
    description = "Void of entry " .. entry_id .. ": " .. orig.description,
    lines       = reversing_lines,
  })
end

--- Remove a posted entry from the journal entirely (no reversing entry, no
-- audit trail) — violates conventional double-entry bookkeeping norms
-- (M.void_entry above is the traditional operation), but is needed for CRDT
-- sync conflict resolution, where a genuinely-deleted remote entry must be
-- able to disappear locally too.
--: (journal, string) -> (true | nil, string | nil)
M.delete_entry = function(journal, entry_id)
  if not journal._by_id[entry_id] then
    return nil, "journal.delete_entry: unknown entry id: " .. tostring(entry_id)
  end
  journal._by_id[entry_id] = nil

  -- TYPECHECKER WORKAROUND: the natural code is `table.remove(journal.entries, i)`.
  -- Same substrate gap logged in TODO.md for lib/bookkeeping/account.lua's
  -- delete_account: `table.remove` rejects a `{ [number]: V }`-typed array
  -- ("missing indexer for integer") even though `{ [number]: V }` should
  -- structurally satisfy `{ [integer]: V }`. Worked around with a hand-written
  -- shift-left removal. Revert once `{ [number]: V }` is accepted where
  -- `{ [integer]: V }` is expected.
  local entries = journal.entries
  for i = 1, #entries do
    if entries[i].id == entry_id then
      local n = #entries
      for j = i, n - 1 do
        entries[j] = entries[j + 1]
      end
      entries[n] = nil
      break
    end
  end
  return true
end

--- Update a posted entry's description in place. Metadata-only: does not
-- touch lines, amounts, or the balance invariant, so no re-validation
-- against `chart` is needed.
--: (journal, string, string) -> (entry | nil, string | nil)
M.update_entry_description = function(journal, entry_id, new_description)
  local entry = journal._by_id[entry_id]
  if not entry then
    return nil, "journal.update_entry_description: unknown entry id: " .. tostring(entry_id)
  end
  if type(new_description) ~= "string" then
    return nil, "journal.update_entry_description: new_description must be a string"
  end
  entry.description = new_description
  return entry
end

return M
