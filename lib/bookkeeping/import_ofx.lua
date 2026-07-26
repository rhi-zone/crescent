if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- OFX (Open Financial Exchange) bank-statement import for lib/bookkeeping.
--
-- OFX 1.x is SGML, not well-formed XML: leaf elements (e.g. <NAME>John Doe)
-- are conventionally left unclosed, relying on the next tag or a newline to
-- terminate the value. lib/xml assumes well-formed XML and would reject or
-- mis-parse real-world OFX, so this module parses OFX with its own tolerant,
-- tag-oriented scanner instead of reusing lib/xml. Container elements (e.g.
-- <STMTTRN>) ARE always explicitly closed per the OFX spec, so only leaf
-- tags need unclosed-tag tolerance; <STMTTRN>...</STMTTRN> pairs are found
-- by an ordinary balanced scan.
--
-- Every well-formed transaction found is converted into a synthetic
-- CSV-import "row" (a plain `{ date, description, amount }` table) and
-- handed to lib.bookkeeping.import.rows_to_entries, so posting, per-row
-- error collection, and the two-line bank/contra-account entry shape are
-- not reimplemented here — see import.lua for that logic and its header
-- comment for the sign/currency/no-dedup policy, all of which apply
-- unchanged to OFX import.
--
-- Field mapping (per transaction, from <STMTTRN>):
--   DTPOSTED -> date (YYYYMMDD, optionally followed by a time and/or a
--     "[offset:TZ]" suffix per the OFX spec; only the leading 8-digit
--     YYYYMMDD is used — no intraday time or timezone handling).
--   TRNAMT   -> amount. OFX defines TRNAMT as already signed the same
--     direction this module's asset-account convention wants (positive =
--     money in = increase), so `opts.amount_sign` defaults to 1, exactly
--     like CSV import's single-`amount`-column default. This is the OFX
--     spec's own convention, not a bank-specific guess (contrast with
--     CSV's debit/credit split, which genuinely varies bank to bank).
--   NAME, MEMO -> description. NAME (payee/transaction description) is
--     preferred; MEMO (the spec's "extra information" field) is used only
--     when NAME is absent or empty. Never combined — this module makes no
--     attempt to fabricate a display format not specified by OFX.
--   TRNTYPE, FITID -> unused. TRNTYPE carries no information TRNAMT's sign
--     doesn't already carry for posting purposes. FITID would be needed for
--     duplicate-import detection, which import.lua's header comment already
--     documents as out of scope; the same policy applies here.
--
-- CURDEF (the statement's currency, found outside <STMTTRN>) is not read or
-- cross-checked against `opts.currency`; like CSV import, the caller states
-- the currency explicitly and this module trusts it rather than parsing
-- statement-level aggregates it doesn't otherwise need.
--
-- Malformed input: an unterminated <STMTTRN> block (no matching </STMTTRN>
-- before end of input) does not fail the whole import and does not silently
-- drop the unparsed tail either. Every transaction found before the break is
-- still imported; a synthetic entry is appended to the result's `errors`
-- list whose `row` is the 1-based index the broken transaction would have
-- had, and whose `message` states exactly how many trailing bytes were left
-- unscanned, so a caller can see and investigate rather than silently lose
-- data past the break.

local import = require("lib.bookkeeping.import")

local M = {}

-- Mirrors lib.bookkeeping.account / lib.bookkeeping.journal / lib.bookkeeping.import's
-- shapes; see journal.lua's header comment for why this can't be a
-- non-duplicating reference to another module's named type.
--:: account_type = "asset" | "liability" | "equity" | "revenue" | "expense"
--:: chart_account = {
--::   id: string, name: string, type: account_type,
--::   code: string | nil, description: string | nil, parent: string | nil,
--:: }
--:: chart = { by_id: { [string]: chart_account }, order: { [number]: string } }
--:: money_value = { amount_minor: number, currency: string }
--:: journal_line = { account: string, amount: money_value, rate: number | nil, book_amount: money_value }
--:: journal_entry = { id: string, date: string, description: string, lines: { [number]: journal_line } }
--:: bookkeeping_journal = { book_currency: string, entries: { [number]: journal_entry }, _by_id: { [string]: journal_entry }, _next_id: number }
--:: row_error = { row: number, message: string }
--:: import_result = { entries: { [number]: journal_entry }, errors: { [number]: row_error } }

--:: ofx_opts = {
--::   bank_account: string, contra_account: string, currency: string,
--::   amount_sign: number | nil,
--:: }

--:: ofx_row = { date: string | nil, description: string, amount: string | nil }

-- Build a case-insensitive Lua pattern matching the literal tag name `s`
-- (OFX tag names are conventionally uppercase, but this tolerates any
-- case). `s` must contain only letters.
--: string -> string
local function ci_pattern(s)
  local pat, _ = s:gsub("%a", function(c) return "[" .. c:lower() .. c:upper() .. "]" end)
  return pat
end

-- Extract one leaf tag's value from an OFX fragment: everything after
-- `<TAG>` up to the next `<` (an explicit close tag, the next open tag, or
-- end of fragment), trimmed. Returns nil if the tag is not present at all;
-- returns "" (not nil) if the tag is present but empty, so callers can tell
-- "absent" from "present but blank" if they need to.
--: (string, string) -> string | nil
local function extract_tag(fragment, tag)
  local pat = "<%s*" .. ci_pattern(tag) .. "%s*>([^<]*)"
  local v = fragment:match(pat)
  if v == nil then return nil end
  return v:match("^%s*(.-)%s*$")
end

--: string -> ofx_row
local function extract_row(fragment)
  local name = extract_tag(fragment, "NAME")
  local memo = extract_tag(fragment, "MEMO")
  local description = memo or ""
  if name ~= nil and name ~= "" then description = name end
  return {
    date = extract_tag(fragment, "DTPOSTED"),
    description = description,
    amount = extract_tag(fragment, "TRNAMT"),
  }
end

-- Scan `text` for <STMTTRN>...</STMTTRN> blocks and extract one ofx_row per
-- block found. If a <STMTTRN> is opened but never closed, scanning stops at
-- that point; `truncated_at` is the 1-based index the broken transaction
-- would have had (i.e. #rows + 1) and `trailing_bytes` is how much of
-- `text`, from the unterminated <STMTTRN> onward, was never scanned. Both
-- are nil when every opened block was properly closed.
--: string -> ({ [number]: ofx_row }, integer | nil, integer | nil)
local function parse_transactions(text)
  local open_pat  = "<%s*" .. ci_pattern("STMTTRN") .. "%s*>"
  local close_pat = "<%s*/%s*" .. ci_pattern("STMTTRN") .. "%s*>"
  local rows = {} --: { [number]: ofx_row }
  local pos = 1
  local truncated_at    --: integer | nil
  local trailing_bytes  --: integer | nil
  while true do
    local open_start, open_end = text:find(open_pat, pos)
    if open_start == nil or open_end == nil then break end
    local close_start, close_end = text:find(close_pat, open_end + 1)
    if close_start == nil or close_end == nil then
      truncated_at = #rows + 1
      trailing_bytes = #text - open_start + 1
      break
    end
    rows[#rows + 1] = extract_row(text:sub(open_end + 1, close_start - 1))
    pos = close_end + 1
  end
  return rows, truncated_at, trailing_bytes
end

-- OFX DTPOSTED -> ISO 8601 "YYYY-MM-DD". DTPOSTED is YYYYMMDD optionally
-- followed by a time and/or "[offset:TZ]" suffix per the OFX spec; only the
-- leading 8 digits are used. Anything else is rejected as a per-row error
-- (never guessed at) via the same `parse_date` hook CSV import uses.
--: string -> (string | nil, string | nil)
local function ofx_date_to_iso(raw)
  local trimmed = raw:match("^%s*(.-)%s*$")
  local y, mo, d = trimmed:match("^(%d%d%d%d)(%d%d)(%d%d)")
  if y == nil then
    return nil, "invalid OFX DTPOSTED (expected leading YYYYMMDD): '" .. raw .. "'"
  end
  local mn = tonumber(mo)
  local dy = tonumber(d)
  if mn == nil or dy == nil then
    return nil, "invalid OFX DTPOSTED: '" .. raw .. "'"
  end
  if mn < 1 or mn > 12 or dy < 1 or dy > 31 then
    return nil, "invalid OFX DTPOSTED: '" .. raw .. "'"
  end
  return y .. "-" .. mo .. "-" .. d
end

--- Import an OFX statement's <STMTTRN> transactions as two-line journal
-- entries (bank account + contra account), delegating to
-- lib.bookkeeping.import.rows_to_entries for posting and per-row error
-- collection. Returns (nil, errmsg) for a fatal, whole-import problem (bad
-- opts, unknown accounts, currency mismatch — see import.lua); otherwise an
-- `import_result` whose `errors` may include row-level date/amount problems
-- and, if the input was truncated, a trailing synthetic error describing
-- exactly what was left unscanned (see module header comment).
--: (string, bookkeeping_journal, chart, ofx_opts) -> (import_result | nil, string | nil)
M.string_to_entries = function(text, journal_, chart, opts)
  local rows0, truncated_at0, trailing_bytes0 = parse_transactions(text)
  -- TYPECHECKER WORKAROUND: the natural code uses `rows0`/`truncated_at0`/
  -- `trailing_bytes0` directly. Confirmed by minimal repro that when a
  -- 3-return local function's result is destructured (`local a, b, c =
  -- f()`), EVERY one of the bound locals — not just the first — can retain
  -- the full 3-element return-tuple type instead of narrowing to its own
  -- element type, depending on how it's later used: passing such a binding
  -- to a call expecting a plain table fails as "tuple is not assignable to
  -- table/array"; concatenating one fails as "cannot concatenate type
  -- (T1, T2, T3)"; nil-narrowing one before use can even collapse it to
  -- `never`. Rebinding each through an explicit checked cast (full
  -- subtyping verified, not a force cast) resolves it. See TODO.md.
  local rows = rows0 --[[: { [number]: ofx_row } ]]
  local truncated_at = truncated_at0 --[[: integer | nil ]]
  local trailing_bytes = trailing_bytes0 --[[: integer | nil ]]

  -- TYPECHECKER WORKAROUND: the natural code passes `ofx_date_to_iso`
  -- directly as the `parse_date` field below. Confirmed by minimal repro
  -- that a local function with more than one `return` statement (i.e. any
  -- branching control flow), even when its declared signature exactly
  -- matches, is not accepted where an *optional* function-typed field
  -- (`(...) -> (...) | nil`) is expected on a cross-module call — a
  -- single-`return`-statement function with the identical declared
  -- signature is accepted in the same position without issue. Rebinding
  -- through an explicit checked cast (full subtyping verified, not a force
  -- cast) resolves it. See TODO.md.
  local parse_date_fn = ofx_date_to_iso --[[: (string) -> (string | nil, string | nil) ]]

  local result, err = import.rows_to_entries(rows, journal_, chart, {
    bank_account = opts.bank_account,
    contra_account = opts.contra_account,
    currency = opts.currency,
    columns = { date = "date", description = "description", amount = "amount", debit = nil, credit = nil },
    amount_sign = opts.amount_sign,
    debit_sign = nil,
    parse_date = parse_date_fn,
    parse_amount = nil,
    csv_opts = nil,
  })
  if result == nil then return nil, err end

  if truncated_at ~= nil then
    result.errors[#result.errors + 1] = {
      row = truncated_at,
      message = "parsing stopped at transaction " .. truncated_at
        .. ": unterminated STMTTRN block, " .. tostring(trailing_bytes)
        .. " bytes of trailing input not scanned.",
    }
  end

  return result
end

return M
