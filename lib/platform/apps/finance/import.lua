if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Bank-statement import (CSV/OFX/QIF) for the finance app, routed through
-- lib.platform.apps.finance.bridge so every imported entry gets the exact
-- same validate -> SQLite -> yjs -> sync path a manually-entered entry gets
-- (see bridge.lua's own header comment). This module never posts directly
-- to a bookkeeping journal itself: parsing/validation is delegated to
-- lib.bookkeeping.import / import_ofx / import_qif (against a throwaway
-- scratch journal, used only to get each row through the same
-- balance/account-existence checks a real post would apply), and every
-- entry that survives parsing is then handed to bridge.post_entry one at a
-- time, into whichever period its date belongs to.
--
-- Period assignment: monthly, id "YYYY-MM" (e.g. "2026-07"), start = the
-- 1st of that month, end = that month's last day. If an entry's date falls
-- in a month with no registered period yet, one is registered (via
-- doc_registry.add_period, through bridge.registry) before that entry is
-- posted. This is this module's own policy, not implied by doc_registry or
-- bridge (neither has any period-granularity concept) -- confirmed with
-- the app owner rather than invented.
--
-- Duplicate detection ("skipped", as opposed to "errors"): before posting,
-- an entry is compared against every entry already in its destination
-- period (loaded straight from SQLite via lib.bookkeeping.store, the
-- source of truth). A match on date + description + the bank line's signed
-- amount/currency (the account named by `opts.default_account_id`) counts
-- as a duplicate and is skipped -- not posted, not counted as an error.
-- This is deliberately narrower than the FITID/dedup policy
-- lib.bookkeeping.import*'s header comments describe as "out of scope
-- there": those modules parse one file in isolation and have no access to
-- what's already posted; this module sits above bridge and does, so it is
-- the layer the app owner chose to put same-import and re-import duplicate
-- detection in.
--
-- Error numbering (`errors[i].entry_idx`): every one of
-- lib.bookkeeping.import/import_ofx/import_qif's parsed entries now carries
-- the source row/transaction/record index it came from (see those modules'
-- `dated_entry` type, added alongside this module so the numbering is
-- consistent across both parse-time errors -- bad date, bad amount -- and
-- post-time errors from this module -- unknown account, period rejected,
-- bridge failure). `entry_idx` is always that source-position number, never
-- a position among only the entries that made it through some earlier
-- stage.

local bk_import   = require("lib.bookkeeping.import")
local import_ofx  = require("lib.bookkeeping.import_ofx")
local import_qif  = require("lib.bookkeeping.import_qif")
local journal     = require("lib.bookkeeping.journal")
local store       = require("lib.bookkeeping.store")
local doc_registry = require("lib.platform.apps.finance.doc_registry")
local bridge_mod  = require("lib.platform.apps.finance.bridge")

local M = {}

-- Registry is non-recursive from this file's point of view (it never
-- touches Doc internals directly, only doc_registry's own public API), so
-- `typeof` captures it exactly -- same reasoning bridge.lua itself uses for
-- this exact type, via this exact technique (a throwaway sample value:
-- `typeof` doesn't survive `require()`, so a required module's own type
-- alias can't be referenced directly from here).
local sample_reg = doc_registry.new({ client_id = 0 })
--:: Registry = typeof sample_reg

-- Restated lib.bookkeeping.account/journal/store and
-- lib.platform.apps.finance.bridge shapes -- mirrors those modules' own
-- header comments verbatim, per this codebase's established precedent (see
-- e.g. bridge.lua's own restatement comment) for why this can't be a
-- non-duplicating cross-module reference.
--:: AccountType = "asset" | "liability" | "equity" | "revenue" | "expense"
--:: Account = { id: string, name: string, type: AccountType, code: string | nil, description: string | nil, parent: string | nil }
--:: Chart = { by_id: { [string]: Account }, order: { [number]: string } }
--:: MoneyValue = { amount_minor: number, currency: string }
--:: JournalLine = { account: string, amount: MoneyValue, rate: number | nil, book_amount: MoneyValue }
--:: JournalEntry = { id: string, date: string, description: string, lines: { [number]: JournalLine } }
--:: BkJournal = { book_currency: string, entries: { [number]: JournalEntry }, _by_id: { [string]: JournalEntry }, _next_id: number }
--:: DatedEntry = { row: number, entry: JournalEntry }
--:: RowError = { row: number, message: string }
--:: BkImportResult = { entries: { [number]: DatedEntry }, errors: { [number]: RowError } }

--:: DbCap = {
--::   execute: (self: DbCap, string, ...unknown) -> (boolean | nil, string | nil),
--::   query: (self: DbCap, string, ...unknown) -> ((() -> unknown) | nil, string | nil),
--::   ...
--:: }
--:: SyncManagerCap = { broadcast_change: (unknown, string, string) -> (true | nil, string | nil), ... }
-- `_next_entry_id` mirrors bridge.lua's own Bridge alias exactly (not just
-- the fields this file happens to read): this checker's record typing is
-- exact, not width-subtyped (see bridge.lua's own Transaction-restatement
-- comment for the same point made about a different type) -- passing a
-- real bridge_mod.new(...) value into a function declared over a Bridge
-- alias missing this field is rejected as "missing field '_next_entry_id'"
-- even though this file never reads or writes it itself.
--:: Bridge = { registry: Registry, db: DbCap, sync_manager: SyncManagerCap | nil, book_currency: string, _next_entry_id: number }

--:: WireLine = { account_id: string, amount: number, currency: string, rate: number | nil }
--:: WireEntry = { id: string | nil, date: string, description: string, lines: { [number]: WireLine } }

-- Mirrors lib.bookkeeping.import's `import_columns` (the CSV column
-- mapper) verbatim.
--:: ImportColumns = {
--::   date: string, description: string | nil,
--::   amount: string | nil, debit: string | nil, credit: string | nil,
--:: }

--:: ImportFormat = "csv" | "ofx" | "qif"

--- Opts for M.from_string. `default_account_id` is the bank/statement
-- account every imported entry's first line posts against;
-- `contra_account_id` is the single catch-all contra account the second
-- line posts against (see lib.bookkeeping.import's header comment: no
-- categorization or transaction matching is done here either). `mapper` is
-- required for `format = "csv"` (ignored otherwise) and is exactly
-- lib.bookkeeping.import's `opts.columns`. `amount_sign`/`debit_sign`/
-- `parse_date`/`parse_amount`/`csv_opts` are passed straight through to
-- whichever underlying lib.bookkeeping.import* module handles the detected
--/given format (`debit_sign`/`csv_opts` only mean anything for CSV; the
-- others apply to all three).
--:: FromStringOpts = {
--::   format: ImportFormat | nil,
--::   mapper: ImportColumns | nil,
--::   default_account_id: string,
--::   contra_account_id: string,
--::   amount_sign: number | nil,
--::   debit_sign: number | nil,
--::   parse_date: ((string) -> (string | nil, string | nil)) | nil,
--::   parse_amount: ((string) -> (string | nil, string | nil)) | nil,
--::   csv_opts: { separator: string | nil, quote: string | nil } | nil,
--:: }

--:: ImportError = { entry_idx: number, errmsg: string }
--:: ImportSummary = { imported: number, skipped: number, errors: { [number]: ImportError } }

-- ---------------------------------------------------------------------------
-- Format auto-detection
-- ---------------------------------------------------------------------------

--- OFX starts with "OFXHEADER" or "<?OFX"; QIF starts with "!Type:";
-- anything else is tried as CSV. Only the first few dozen bytes are
-- inspected (a leading run of whitespace is tolerated before the marker,
-- real-world OFX/QIF exports occasionally have one).
--: string -> ImportFormat
local function detect_format(text)
  local head = text:sub(1, 64)
  if head:match("^%s*OFXHEADER") or head:match("^%s*<%?OFX") then return "ofx" end
  if head:match("^%s*!Type:") then return "qif" end
  return "csv"
end

-- ---------------------------------------------------------------------------
-- Monthly period assignment
-- ---------------------------------------------------------------------------

local DAYS_IN_MONTH = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

--: number -> boolean
local function is_leap_year(y)
  return (y % 4 == 0 and y % 100 ~= 0) or (y % 400 == 0)
end

--: (number, number) -> number
local function last_day_of_month(year, month)
  if month == 2 and is_leap_year(year) then return 29 end
  return DAYS_IN_MONTH[month]
end

--:: MonthPeriod = { id: string, start_date: string, end_date: string }

-- The monthly period an ISO 8601 "YYYY-MM-DD" date belongs to: id "YYYY-MM",
-- start_date the 1st of that month, end_date that month's last day. Returns
-- nil if `date` isn't a well-formed enough ISO date to read a year/month
-- from (bk_import/import_ofx/import_qif already validate the date before an
-- entry is ever produced, so this should not actually fail in practice --
-- guarded anyway rather than assumed, matching this codebase's "never fail
-- hard, report" convention).
--: string -> MonthPeriod | nil
local function month_period_for_date(date)
  local y = tonumber(date:sub(1, 4))
  local m = tonumber(date:sub(6, 7))
  if y == nil or m == nil then return nil end
  if m < 1 or m > 12 then return nil end
  local id = date:sub(1, 7)
  return {
    id = id,
    start_date = id .. "-01",
    end_date = string.format("%s-%02d", id, last_day_of_month(y, m)),
  }
end

-- Registers `period` in the bridge's registry if it isn't already there.
-- Add-only (doc_registry.add_period rejects a duplicate id), so this always
-- checks list_periods first rather than relying on that rejection as
-- control flow.
--: (Bridge, MonthPeriod) -> (true | nil, string | nil)
local function ensure_period_registered(bridge, period)
  local periods = doc_registry.list_periods(bridge.registry)
  for i = 1, #periods do
    if periods[i].id == period.id then return true end
  end
  return doc_registry.add_period(bridge.registry, period.id, {
    start_date = period.start_date, end_date = period.end_date,
  })
end

-- ---------------------------------------------------------------------------
-- Duplicate detection
-- ---------------------------------------------------------------------------

-- True if `existing` (an entry already in the destination period, per
-- SQLite) matches `date`/`description` and has a line on `bank_account_id`
-- equal to `bank_amount` (both amount_minor and currency) -- see this
-- file's header comment for why these three fields are the chosen
-- duplicate key.
--: (JournalEntry, string, string, string, MoneyValue) -> boolean
local function entry_matches(existing, date, description, bank_account_id, bank_amount)
  if existing.date ~= date or existing.description ~= description then return false end
  for i = 1, #existing.lines do
    local line = existing.lines[i]
    if line.account == bank_account_id
      and line.amount.amount_minor == bank_amount.amount_minor
      and line.amount.currency == bank_amount.currency then
      return true
    end
  end
  return false
end

--: ({ [number]: JournalEntry }, string, string, string, MoneyValue) -> boolean
local function is_duplicate(existing_entries, date, description, bank_account_id, bank_amount)
  for i = 1, #existing_entries do
    if entry_matches(existing_entries[i], date, description, bank_account_id, bank_amount) then
      return true
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Parsing dispatch
-- ---------------------------------------------------------------------------

--: (string, ImportFormat, FromStringOpts, BkJournal, Chart, string) -> (BkImportResult | nil, string | nil)
local function parse_text(text, format, opts, scratch_journal, chart, currency)
  if format == "csv" then
    local mapper = opts.mapper
    if mapper == nil then
      return nil, "finance.import: opts.mapper is required for CSV import"
    end
    return bk_import.string_to_entries(text, scratch_journal, chart, {
      bank_account = opts.default_account_id,
      contra_account = opts.contra_account_id,
      currency = currency,
      columns = mapper,
      amount_sign = opts.amount_sign,
      debit_sign = opts.debit_sign,
      parse_date = opts.parse_date,
      parse_amount = opts.parse_amount,
      csv_opts = opts.csv_opts,
    })
  elseif format == "ofx" then
    return import_ofx.string_to_entries(text, scratch_journal, chart, {
      bank_account = opts.default_account_id,
      contra_account = opts.contra_account_id,
      currency = currency,
      amount_sign = opts.amount_sign,
    })
  else
    return import_qif.string_to_entries(text, scratch_journal, chart, {
      bank_account = opts.default_account_id,
      contra_account = opts.contra_account_id,
      currency = currency,
      amount_sign = opts.amount_sign,
    })
  end
end

-- ---------------------------------------------------------------------------
-- Wire conversion (mirrors bridge.lua's own entry_to_wire, in reverse)
-- ---------------------------------------------------------------------------

--: JournalEntry -> WireEntry
local function entry_to_wire(entry)
  local lines = {} --: { [number]: WireLine }
  for i = 1, #entry.lines do
    local line = entry.lines[i]
    lines[i] = {
      account_id = line.account,
      amount     = line.amount.amount_minor,
      currency   = line.amount.currency,
      rate       = line.rate,
    }
  end
  -- `id = nil`: this entry was posted into a throwaway scratch journal only
  -- to get it through validation (see this file's header comment); its id
  -- there is meaningless for the real per-period journal, so bridge.post_entry
  -- is asked to assign a fresh one, exactly as it would for a brand-new
  -- manually-entered entry.
  return { id = nil, date = entry.date, description = entry.description, lines = lines }
end

-- ---------------------------------------------------------------------------
-- Routing one parsed entry through the bridge
-- ---------------------------------------------------------------------------

--:: RouteOutcome = { kind: "imported" } | { kind: "skipped" } | { kind: "error", message: string }

-- Isolated into its own function -- not inlined into route_entry -- matching
-- this codebase's established "a multi-return call's destructured locals
-- must not share a function scope with another unrelated multi-return call"
-- precedent (see e.g. bridge.lua's post_wire_entry/resave_period_with_chart
-- comments, store.lua's read_book_currency/build_journal_from_rows split).
-- `store.load_period`'s own 4-value destructure (`existing_j`/`_chart`/`_bc`/
-- `loaderr`) never coexists, in one scope, with `route_entry`'s other
-- multi-return calls (`ensure_period_registered`, `bridge_mod.post_entry`).
--: (Bridge, string) -> ({ [number]: JournalEntry } | nil, string | nil)
local function load_existing_entries(bridge, period_id)
  local existing_j, _chart, _bc, loaderr = store.load_period(bridge.db, period_id)
  if existing_j == nil then return nil, loaderr end
  return journal.list(existing_j)
end

--- Isolated into its own function -- not inlined into M.from_string's loop --
-- matching the same precedent as load_existing_entries above: this
-- function's own destructured locals (`period`, `existing_entries`,
-- `posted`) never coexist, in one scope, with M.from_string's own
-- parse_text/store.load calls.
--: (Bridge, DatedEntry, string, string) -> RouteOutcome
local function route_entry(bridge, dated, default_account_id, contra_account_id)
  local _ = contra_account_id
  local entry = dated.entry
  local period = month_period_for_date(entry.date)
  if period == nil then
    return { kind = "error", message = "finance.import: could not determine a period for date " .. tostring(entry.date) }
  end

  local ensured, eerr = ensure_period_registered(bridge, period)
  if not ensured then
    return { kind = "error", message = "finance.import: " .. tostring(eerr) }
  end

  local existing_entries, loaderr = load_existing_entries(bridge, period.id)
  if existing_entries == nil then
    return { kind = "error", message = "finance.import: " .. tostring(loaderr) }
  end

  local bank_line = entry.lines[1]
  if is_duplicate(existing_entries, entry.date, entry.description, default_account_id, bank_line.amount) then
    return { kind = "skipped" }
  end

  local posted, poerr = bridge_mod.post_entry(bridge, period.id, entry_to_wire(entry))
  if posted == nil then
    return { kind = "error", message = "finance.import: " .. tostring(poerr) }
  end
  return { kind = "imported" }
end

-- ---------------------------------------------------------------------------
-- Public entry point
-- ---------------------------------------------------------------------------

--- Parse `text` (a full bank-statement file: CSV, OFX, or QIF) and route
-- every entry it yields through `bridge.post_entry`, one entry per
-- destination period (see this file's header comment for period
-- assignment and duplicate-detection policy). Returns (nil, errmsg) only
-- for a fatal, whole-import problem (bad opts, unknown format, an unknown
-- account, a chart/journal load failure) before any entry is routed;
-- otherwise always returns an ImportSummary, whose `errors` may include
-- both parse-time row errors and post-time routing errors.
--: (Bridge, string, FromStringOpts) -> (ImportSummary | nil, string | nil)
M.from_string = function(bridge, text, opts)
  if type(opts.default_account_id) ~= "string" or opts.default_account_id == "" then
    return nil, "finance.import: opts.default_account_id must be a non-empty string"
  end
  if type(opts.contra_account_id) ~= "string" or opts.contra_account_id == "" then
    return nil, "finance.import: opts.contra_account_id must be a non-empty string"
  end

  local format = opts.format
  if format == nil then format = detect_format(text) end
  if format ~= "csv" and format ~= "ofx" and format ~= "qif" then
    return nil, "finance.import: unknown format: " .. tostring(format)
  end

  local _j, chart, _bc, lerr = store.load(bridge.db)
  if chart == nil then return nil, "finance.import: " .. tostring(lerr) end

  local scratch_journal, jerr = journal.new(bridge.book_currency)
  if scratch_journal == nil then return nil, "finance.import: " .. tostring(jerr) end

  local result, perr = parse_text(text, format, opts, scratch_journal, chart, bridge.book_currency)
  if result == nil then return nil, "finance.import: " .. tostring(perr) end

  local imported = 0
  local skipped = 0
  local errors = {} --: { [number]: ImportError }

  for i = 1, #result.errors do
    local row_err = result.errors[i]
    errors[#errors + 1] = { entry_idx = row_err.row, errmsg = row_err.message }
  end

  local entries = result.entries
  for i = 1, #entries do
    local dated = entries[i]
    local outcome = route_entry(bridge, dated, opts.default_account_id, opts.contra_account_id)
    if outcome.kind == "imported" then
      imported = imported + 1
    elseif outcome.kind == "skipped" then
      skipped = skipped + 1
    elseif outcome.kind == "error" then
      errors[#errors + 1] = { entry_idx = dated.row, errmsg = outcome.message }
    end
  end

  return { imported = imported, skipped = skipped, errors = errors }
end

return M
