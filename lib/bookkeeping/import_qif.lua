if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- QIF (Quicken Interchange Format) bank-statement import for lib/bookkeeping.
--
-- QIF is line-based, not a structured format: a required `!Type:<kind>`
-- header (e.g. `!Type:Bank`, `!Type:CCard`, `!Type:Cash`) marks the start of
-- one account's transaction section, followed by transaction records. Each
-- record is a run of prefixed lines (`D` date, `T` amount, `P` payee, `M`
-- memo, `N` check/reference number, plus category/split/address lines this
-- module does not use) terminated by a line containing only `^`.
--
-- Any `!Type:` value is accepted (Bank, CCard, Cash, ...) — they are all
-- legitimate single-account transaction sections, and the caller already
-- states which accounts to post against via `opts.bank_account`/
-- `opts.contra_account`, the same trust-the-caller model CSV import uses
-- for its column mapper. A `!Type:` header is nonetheless *required*:
-- headerless input is rejected as malformed rather than guessed at.
--
-- A QIF file may contain more than one `!Type:` section concatenated
-- together (e.g. a bank register followed by a credit-card register). This
-- module refuses that outright: a second `!Type:` header anywhere after the
-- first is a fatal, whole-import error. Parsing every record in the file
-- regardless of section would silently commingle transactions from a
-- different account into whatever single `bank_account`/`contra_account`
-- the caller configured for this import — a wrong-account data problem, not
-- just a missing field, so it is never guessed past.
--
-- Every well-formed transaction record found is converted into a synthetic
-- CSV-import "row" (a plain `{ date, description, amount }` table) and
-- handed to lib.bookkeeping.import.rows_to_entries, so posting, per-row
-- error collection, and the two-line bank/contra-account entry shape are
-- not reimplemented here — see import.lua for that logic and its header
-- comment for the sign/currency/no-dedup policy, all of which apply
-- unchanged to QIF import.
--
-- Field mapping (per transaction record):
--   D -> date. Quicken's own T-field sign convention (see below) is a
--     format-level standard, not a bank-specific quirk, but its date
--     formats are not: real exports vary between `MM/DD/YYYY` and an
--     apostrophe two-digit-year form like `MM/DD'YY`, and the apostrophe
--     form's century is not universally agreed (some tools read `'26` as
--     2026, others use a sliding window against 1900). Rather than guess a
--     century, this module supports only the unambiguous `MM/DD/YYYY`
--     (also `M/D/YYYY`) form; any other date, including the apostrophe
--     form, is rejected as a per-row error naming exactly what was
--     rejected and why, never silently misdated.
--   T -> amount. QIF's T field is signed the same direction this module's
--     asset-account convention wants (positive = deposit = increase),
--     which is Quicken's own fixed definition of the field for a bank-style
--     register, not a per-exporter convention — so `opts.amount_sign`
--     defaults to 1, exactly like CSV import's single-`amount`-column
--     default and OFX import's TRNAMT default.
--   P, M -> description. P (payee) is preferred; M (memo) is used only
--     when P is absent or empty. Never combined, matching OFX's NAME/MEMO
--     precedence for the same reason: QIF does not specify a combined
--     display format, so this module does not fabricate one.
--   N and all other line prefixes (L category, S/E/$ splits, A address,
--     C cleared-status, ...) -> unused. This module posts every record as a
--     single two-line entry against one caller-configured contra account,
--     the same "no categorization, no transaction matching" scope
--     import.lua's header comment documents for CSV; split-transaction
--     category breakdowns are out of scope for the same reason.
--
-- Malformed input: a transaction record that starts (has at least one
-- prefixed field) but is never closed by a `^` line before end of input —
-- e.g. a file truncated mid-download — does not fail the whole import and
-- does not silently drop the unparsed tail either. This mirrors OFX
-- import's unterminated-<STMTTRN> policy exactly: every record closed
-- before the break is still imported; a synthetic entry is appended to the
-- result's `errors` list whose `row` is the 1-based index the broken
-- record would have had, and whose `message` states exactly how many
-- trailing bytes (from the start of the unterminated record) were left
-- unscanned.

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
-- `row` is the entry's 1-based position among this file's own parsed QIF
-- records (the same numbering `row_error.row` and the truncation error
-- already use) -- see lib/bookkeeping/import.lua's matching restatement for
-- why a caller needs this.
--:: dated_entry = { row: number, entry: journal_entry }
--:: import_result = { entries: { [number]: dated_entry }, errors: { [number]: row_error } }

--:: qif_opts = {
--::   bank_account: string, contra_account: string, currency: string,
--::   amount_sign: number | nil,
--:: }

--:: qif_row = { date: string | nil, description: string, amount: string | nil }
--:: qif_line = { text: string, start_pos: integer }

-- Split `text` into lines (accepting both "\n" and "\r\n"), keeping each
-- line's 1-based byte offset into `text` so a caller can report byte counts
-- for unterminated trailing content.
--: string -> { [number]: qif_line }
local function split_lines(text)
  local lines = {} --: { [number]: qif_line }
  local pos = 1
  local len = #text
  while pos <= len do
    local nl = text:find("\n", pos, true)
    local line_end = (nl or (len + 1)) - 1
    local raw = text:sub(pos, line_end)
    local content = raw:gsub("\r$", "")
    lines[#lines + 1] = { text = content, start_pos = pos }
    pos = nl and (nl + 1) or (len + 1)
  end
  return lines
end

-- QIF D field -> ISO 8601 "YYYY-MM-DD". Only the unambiguous MM/DD/YYYY (or
-- M/D/YYYY) form is accepted; see module header comment for why the
-- apostrophe two-digit-year form is rejected rather than guessed.
--: string -> (string | nil, string | nil)
local function qif_date_to_iso(raw)
  local trimmed = raw:match("^%s*(.-)%s*$")
  local mo, d, y = trimmed:match("^(%d%d?)/(%d%d?)/(%d%d%d%d)$")
  if mo == nil or d == nil or y == nil then
    return nil, "unsupported QIF date (only MM/DD/YYYY is supported; "
      .. "two-digit-year forms like MM/DD'YY are rejected rather than "
      .. "guessed at — see lib/bookkeeping/import_qif.lua): '" .. raw .. "'"
  end
  local mn = tonumber(mo)
  local dy = tonumber(d)
  local yr = tonumber(y)
  if mn == nil or dy == nil or yr == nil then
    return nil, "invalid QIF date: '" .. raw .. "'"
  end
  if mn < 1 or mn > 12 or dy < 1 or dy > 31 then
    return nil, "invalid QIF date: '" .. raw .. "'"
  end
  return string.format("%04d-%02d-%02d", yr, mn, dy)
end

-- Find every `!Type:...` header line. Returns the list of (1-based line
-- index, header value) pairs found, in file order.
--: { [number]: qif_line } -> { [number]: { line: integer, value: string } }
local function find_type_headers(lines)
  local headers = {} --: { [number]: { line: integer, value: string } }
  for i = 1, #lines do
    local value = lines[i].text:match("^!Type:%s*(.-)%s*$")
    if value ~= nil then
      headers[#headers + 1] = { line = i, value = value }
    end
  end
  return headers
end

-- Parse every `D/T/P/M/N/^`-style transaction record found in `lines`
-- starting at `from_line` (the line immediately after the `!Type:` header).
-- Mirrors OFX import's parse_transactions: a record that accumulates at
-- least one field but never sees a closing `^` line before the end of
-- input stops the scan there rather than guessing whether it's complete;
-- `truncated_at`/`trailing_bytes` describe exactly what was left unscanned
-- (both nil when every opened record was properly closed).
--: ({ [number]: qif_line }, integer, string) -> ({ [number]: qif_row }, integer | nil, integer | nil)
local function parse_transactions(lines, from_line, text)
  local rows = {} --: { [number]: qif_row }
  local cur_date        --: string | nil
  local cur_amount      --: string | nil
  local cur_payee       --: string | nil
  local cur_memo        --: string | nil
  local has_content = false
  local record_start_pos --: integer | nil

  for i = from_line, #lines do
    local raw = lines[i].text
    local trimmed = raw:match("^%s*(.-)%s*$")
    if trimmed == "^" then
      if has_content then
        local description = cur_memo or ""
        if cur_payee ~= nil and cur_payee ~= "" then description = cur_payee end
        rows[#rows + 1] = { date = cur_date, description = description, amount = cur_amount }
      end
      cur_date, cur_amount, cur_payee, cur_memo = nil, nil, nil, nil
      has_content = false
      record_start_pos = nil
    elseif trimmed ~= "" then
      if not has_content then record_start_pos = lines[i].start_pos end
      has_content = true
      local prefix = trimmed:sub(1, 1)
      local rest = trimmed:sub(2):match("^%s*(.-)%s*$")
      if prefix == "D" then cur_date = rest
      elseif prefix == "T" then cur_amount = rest
      elseif prefix == "P" then cur_payee = rest
      elseif prefix == "M" then cur_memo = rest
      end
    end
  end

  if has_content and record_start_pos ~= nil then
    local truncated_at = #rows + 1
    local trailing_bytes = #text - record_start_pos + 1
    return rows, truncated_at, trailing_bytes
  end
  return rows, nil, nil
end

--- Import a QIF statement's transaction records as two-line journal entries
-- (bank account + contra account), delegating to
-- lib.bookkeeping.import.rows_to_entries for posting and per-row error
-- collection. Returns (nil, errmsg) for a fatal, whole-import problem: bad
-- opts, unknown accounts, currency mismatch (see import.lua), a missing
-- `!Type:` header, or more than one `!Type:` section in the file. Otherwise
-- returns an `import_result` whose `errors` may include row-level date/
-- amount problems and, if the input was truncated, a trailing synthetic
-- error describing exactly what was left unscanned (see module header
-- comment).
--: (string, bookkeeping_journal, chart, qif_opts) -> (import_result | nil, string | nil)
M.string_to_entries = function(text, journal_, chart, opts)
  local lines = split_lines(text)
  local headers = find_type_headers(lines)

  if #headers == 0 then
    return nil, "bookkeeping.import_qif: missing required !Type: header"
  end
  if #headers > 1 then
    return nil, "bookkeeping.import_qif: file contains multiple account sections "
      .. "(found !Type:" .. headers[2].value .. " after !Type:" .. headers[1].value
      .. "); split before importing"
  end

  local rows, truncated_at, trailing_bytes = parse_transactions(lines, headers[1].line + 1, text)
  -- TYPECHECKER WORKAROUND: the natural code passes `qif_date_to_iso`
  -- directly as the `parse_date` field below. Confirmed by minimal repro
  -- (see lib/bookkeeping/import_ofx.lua, same fix): a local function with
  -- more than one `return` statement is not accepted where an optional
  -- function-typed field (`(...) -> (...) | nil`) is expected on a
  -- cross-module call, even though its declared signature matches exactly.
  -- Rebinding through an explicit checked cast (full subtyping verified,
  -- not a force cast) resolves it. See TODO.md.
  local parse_date_fn = qif_date_to_iso --[[: (string) -> (string | nil, string | nil) ]]

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
        .. ": unterminated QIF record (missing trailing '^'), " .. tostring(trailing_bytes)
        .. " bytes of trailing input not scanned.",
    }
  end

  return result
end

return M
