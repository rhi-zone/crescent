if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Bank-statement CSV import for lib/bookkeeping.
--
-- Each CSV row becomes one two-line journal entry: a line on the
-- caller-configured bank account, and an equal-and-opposite line on a
-- caller-configured default contra account (a single catch-all
-- expense/income account — this module does no categorization or
-- transaction matching; every row lands on the same contra account).
--
-- Column mapper: `opts.columns` maps this module's semantic fields (date,
-- description, and either a single signed `amount` column or a split
-- `debit`/`credit` pair) to the CSV's header names. Rows are decoded with
-- `csv.decode(text, { headers = true, ... })`, so the mapper always refers
-- to columns by header name, never by position.
--
-- Sign conventions (the part every bank CSV disagrees on):
--   - Single `amount` column: `opts.amount_sign` (default 1) is multiplied
--     into the parsed value before it becomes the bank line's amount. The
--     default (1) assumes the column is already signed the way this
--     module's domain model wants it (positive = debit = increase in an
--     asset-typed bank account) — it does not assume any bank-specific
--     convention, it just trusts the number as given.
--   - Split `debit`/`credit` columns: there is no neutral default here.
--     "Debit"/"credit" on a real bank statement are the bank's own
--     liability-account terms for *your* account, which are the mirror
--     image of this module's asset-account convention for a checking/
--     savings account (a bank "debit" typically means money left your
--     account, i.e. a *decrease*, the opposite of this model's
--     debit-normal asset convention) — but that mapping isn't universal
--     across banks or account types, so this module never assumes it.
--     `opts.debit_sign` (1 or -1) is required whenever `columns.debit`/
--     `columns.credit` are used: it is multiplied into a populated debit
--     column's value, and its negation is multiplied into a populated
--     credit column's value. Omitting it when debit/credit columns are
--     configured is a fatal error, not a silently-guessed default.
--
-- Currency: a single import only supports one CSV currency, which must
-- equal the journal's book currency. There is no per-row exchange-rate
-- conversion here — two independently-rounded conversions of a line and
-- its exact negation are not guaranteed to still sum to zero (see
-- money.convert's rounding), so cross-currency import is out of scope
-- rather than silently risking an unbalanced entry.
--
-- Bad rows (missing/unparseable date, amount, or account) are collected as
-- per-row errors, never thrown; a bad row does not stop the rest of the
-- import. Fatal, whole-import problems (misconfigured opts, unknown
-- accounts, currency mismatch) are reported as (nil, errmsg) before any row
-- is processed.
--
-- No duplicate-import detection: re-importing the same statement posts the
-- same rows again. That policy (how to detect/skip duplicates) wasn't
-- specified and isn't invented here.

local money   = require("lib.money")
local account = require("lib.bookkeeping.account")
local journal = require("lib.bookkeeping.journal")
local csv     = require("lib.csv")

local M = {}

--:: money_value = { amount_minor: number, currency: string }

-- Mirrors lib.bookkeeping.account / lib.bookkeeping.journal's shapes; see
-- journal.lua's header comment for why this can't be a non-duplicating
-- reference to another module's named type.
--:: account_type = "asset" | "liability" | "equity" | "revenue" | "expense"
--:: chart_account = {
--::   id: string, name: string, type: account_type,
--::   code: string | nil, description: string | nil, parent: string | nil,
--:: }
--:: chart = { by_id: { [string]: chart_account }, order: { [number]: string } }
--:: journal_line = { account: string, amount: money_value, rate: number | nil, book_amount: money_value }
--:: journal_entry = { id: string, date: string, description: string, lines: { [number]: journal_line } }
--:: bookkeeping_journal = { book_currency: string, entries: { [number]: journal_entry }, _by_id: { [string]: journal_entry }, _next_id: number }

-- Named `import_columns` (not `columns`) to avoid colliding with the
-- `import_opts.columns` field of the same name.
--:: import_columns = {
--::   date: string, description: string | nil,
--::   amount: string | nil, debit: string | nil, credit: string | nil,
--:: }
--:: import_opts = {
--::   bank_account: string, contra_account: string, currency: string,
--::   columns: import_columns,
--::   amount_sign: number | nil, debit_sign: number | nil,
--::   parse_date: ((string) -> (string | nil, string | nil)) | nil,
--::   parse_amount: ((string) -> (string | nil, string | nil)) | nil,
--::   csv_opts: { separator: string | nil, quote: string | nil } | nil,
--:: }
--:: row_error = { row: number, message: string }
--:: import_result = { entries: { [number]: journal_entry }, errors: { [number]: row_error } }

-- Default amount-string normalizer: trims surrounding whitespace and strips
-- thousands-separator commas ("1,234.56" -> "1234.56"). Does not treat
-- parenthesized amounts as negative or accept any other bank-specific
-- convention — pass a custom `opts.parse_amount` for those.
--: string -> (string | nil, string | nil)
local function default_parse_amount(s)
  local trimmed = s:match("^%s*(.-)%s*$")
  local stripped = trimmed:gsub(",", "")
  if stripped == "" then
    return nil, "empty amount"
  end
  return stripped
end

-- Default date normalizer: identity. Requires the CSV date to already be
-- ISO 8601 "YYYY-MM-DD" (journal.post validates this and will reject a row
-- otherwise); pass a custom `opts.parse_date` to convert another format.
--: string -> (string | nil, string | nil)
local function default_parse_date(s)
  return s
end

-- `row` is one decoded CSV record: `csv.decode(text, { headers = true })`
-- types every row as `unknown` (headers vary per call), so every field read
-- goes through this narrowing helper. `key` itself may be nil (an unset
-- optional column in the mapper), in which case there is nothing to read.
--: (unknown, string | nil) -> string | nil
local function row_string(row, key)
  if key == nil then return nil end
  if type(row) ~= "table" then return nil end
  local r = row --[[: { [string]: unknown } ]]
  local v = r[key]
  if type(v) ~= "string" then return nil end
  return v
end

-- Resolve one row's signed bank-line amount string (before parse_amount)
-- and its sign multiplier, from either the single `amount` column or the
-- `debit`/`credit` pair. All three return paths yield the same 3-tuple
-- shape (value, sign, err) so a caller only needs one narrowing pattern.
--: (import_columns, unknown, number | nil) -> (string | nil, number | nil, string | nil)
local function resolve_raw_amount(cols, row, debit_sign)
  local amount_col = cols.amount
  if amount_col ~= nil then
    local raw = row_string(row, amount_col)
    if raw == nil then return nil, nil, "missing amount column '" .. amount_col .. "'" end
    return raw, 1, nil
  end

  if cols.debit ~= nil and cols.credit ~= nil then
    if debit_sign == nil then
      return nil, nil, "columns.debit/columns.credit configured without opts.debit_sign"
    end
    local debit_raw  = row_string(row, cols.debit)
    local credit_raw = row_string(row, cols.credit)
    local debit_trim  = (debit_raw  and debit_raw:match("^%s*(.-)%s*$"))  or ""
    local credit_trim = (credit_raw and credit_raw:match("^%s*(.-)%s*$")) or ""
    local has_debit  = debit_trim  ~= ""
    local has_credit = credit_trim ~= ""
    if has_debit and has_credit then
      return nil, nil, "row has both a debit and a credit value"
    end
    if has_debit then
      return debit_trim, debit_sign, nil
    end
    if has_credit then
      return credit_trim, -debit_sign, nil
    end
    return nil, nil, "row has neither a debit nor a credit value"
  end

  return nil, nil, "columns must configure either 'amount', or both 'debit' and 'credit'"
end

-- Resolve one row's ISO 8601 date, applying parse_date. Returns (nil, err)
-- if the date column is missing or parse_date rejects it.
--: (unknown, import_columns, (string) -> (string | nil, string | nil)) -> (string | nil, string | nil)
local function resolve_date(row, cols, parse_date)
  local raw = row_string(row, cols.date)
  if raw == nil then return nil, "missing date column '" .. cols.date .. "'" end
  return parse_date(raw)
end

-- Resolve one row's description. Not required by the mapper — an unset
-- `columns.description` yields the empty string for every row.
--: (unknown, import_columns) -> string
local function resolve_description(row, cols)
  return row_string(row, cols.description) or ""
end

-- Resolve one row's fully-parsed, signed bank-line amount (a money_value in
-- `currency`), combining resolve_raw_amount, parse_amount, and amount_sign.
--: (import_columns, unknown, number | nil, number, (string) -> (string | nil, string | nil), string) -> (money_value | nil, string | nil)
local function resolve_bank_amount(cols, row, debit_sign, amount_sign, parse_amount, currency)
  local raw, sign, raw_err = resolve_raw_amount(cols, row, debit_sign)
  if raw_err then return nil, raw_err end
  if raw == nil or sign == nil then
    return nil, "bookkeeping.import: internal: resolve_raw_amount returned neither a value nor an error"
  end

  local amount_str, parse_err = parse_amount(raw)
  if amount_str == nil then return nil, "amount: " .. tostring(parse_err) end

  local bank_amount, merr = money.new(amount_str, currency)
  if bank_amount == nil then return nil, "amount: " .. tostring(merr) end

  return money.mul(bank_amount, sign * amount_sign)
end

--- Import already-decoded CSV rows (header-keyed record tables, as from
-- `csv.decode(text, { headers = true })`) as two-line journal entries.
-- Posts directly to `journal` against `chart`. Returns (nil, errmsg) for a
-- fatal, whole-import problem (bad opts, unknown accounts, currency
-- mismatch) before any row is processed; otherwise returns an
-- `import_result` whose `errors` list holds per-row problems that did not
-- stop the rest of the import.
--: ({ [number]: unknown }, bookkeeping_journal, chart, import_opts) -> (import_result | nil, string | nil)
M.rows_to_entries = function(rows, journal_, chart, opts)
  if type(opts.bank_account) ~= "string" then
    return nil, "bookkeeping.import: opts.bank_account must be a string"
  end
  if type(opts.contra_account) ~= "string" then
    return nil, "bookkeeping.import: opts.contra_account must be a string"
  end
  if not account.get(chart, opts.bank_account) then
    return nil, "bookkeeping.import: unknown bank_account: " .. opts.bank_account
  end
  if not account.get(chart, opts.contra_account) then
    return nil, "bookkeeping.import: unknown contra_account: " .. opts.contra_account
  end
  if type(opts.currency) ~= "string" or not money.is_valid_currency(opts.currency) then
    return nil, "bookkeeping.import: opts.currency must be a known currency code"
  end
  if opts.currency ~= journal_.book_currency then
    return nil, "bookkeeping.import: opts.currency (" .. opts.currency
      .. ") must equal the journal's book currency (" .. journal_.book_currency
      .. ") — cross-currency import is not supported"
  end
  local cols = opts.columns
  if type(cols) ~= "table" then
    return nil, "bookkeeping.import: opts.columns must be a table"
  end
  local cols_t = cols --[[: import_columns ]]
  if type(cols_t.date) ~= "string" then
    return nil, "bookkeeping.import: opts.columns.date must be a string (CSV header name)"
  end

  local bank_account   = opts.bank_account
  local contra_account = opts.contra_account
  local currency       = opts.currency
  local debit_sign     = opts.debit_sign
  local amount_sign    = opts.amount_sign or 1
  local parse_date     = opts.parse_date or default_parse_date
  local parse_amount   = opts.parse_amount or default_parse_amount

  local entries = {} --: { [number]: journal_entry }
  local errors  = {} --: { [number]: row_error }

  for i = 1, #rows do
    local row = rows[i]

    local date, date_err = resolve_date(row, cols_t, parse_date)
    local description = resolve_description(row, cols_t)
    local bank_amount, amount_err = resolve_bank_amount(cols_t, row, debit_sign, amount_sign, parse_amount, currency)

    if date_err then
      errors[#errors + 1] = { row = i, message = date_err }
    elseif amount_err then
      errors[#errors + 1] = { row = i, message = amount_err }
    elseif date == nil or bank_amount == nil then
      errors[#errors + 1] = { row = i, message = "bookkeeping.import: internal: no value and no error resolving row" }
    else
      local contra_amount = money.negate(bank_amount)
      local entry, post_err = journal.post(journal_, chart, {
        id = nil, date = date, description = description,
        lines = {
          { account = bank_account,   amount = bank_amount,   rate = nil },
          { account = contra_account, amount = contra_amount, rate = nil },
        },
      })
      if not entry then
        errors[#errors + 1] = { row = i, message = tostring(post_err) }
      else
        entries[#entries + 1] = entry
      end
    end
  end

  return { entries = entries, errors = errors }
end

--- Decode `text` as CSV (with headers) and import it via M.rows_to_entries.
-- `opts.csv_opts` is passed through to csv.decode (separator, quote).
--: (string, bookkeeping_journal, chart, import_opts) -> (import_result | nil, string | nil)
M.string_to_entries = function(text, journal_, chart, opts)
  local csv_opts = opts.csv_opts or {}
  --: { separator: string | nil, quote: string | nil, trim: boolean | nil, headers: boolean | nil, coerce: boolean | nil }
  local decode_opts = {
    separator = csv_opts.separator, quote = csv_opts.quote, headers = true,
    trim = nil, coerce = nil,
  }
  local rows, err = csv.decode(text, decode_opts)
  if not rows then return nil, "bookkeeping.import: csv decode: " .. tostring(err) end
  return M.rows_to_entries(rows, journal_, chart, opts)
end

return M
