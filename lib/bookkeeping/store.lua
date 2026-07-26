if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- SQLite persistence for lib/bookkeeping.
--
-- Caps-first: the sqlite connection (a `lib.sqlite` handle, from
-- `require("lib.sqlite").open(path)`) is always passed in by the caller,
-- never opened internally.
--
-- Schema (three tables; see M.create_schema for the exact DDL):
--   accounts        (id, name, type, code, description, parent_id, metadata)
--   journal_entries (id, date, description, metadata)
--   journal_lines   (id, entry_id, account_id, amount_minor, currency, rate,
--                     book_amount_minor, book_currency)
--
-- `accounts.description` isn't part of a strict column list — it exists in
-- lib.bookkeeping.account's in-memory record (alongside `code`), so it is
-- persisted for a lossless round trip.
--
-- `metadata` columns exist for forward compatibility with the schema this
-- module was asked to implement, but neither lib.bookkeeping.account nor
-- lib.bookkeeping.journal currently has a metadata field on its records.
-- M.save always writes NULL there; M.load never reads it back into the
-- in-memory model. Nothing is lost in the round trip because there is
-- nothing to lose yet — the column is reserved, not wired to any behavior.
--
-- `journal_lines.book_currency` duplicates `journal.book_currency` per row
-- (the in-memory journal has exactly one book currency for all its lines).
-- This mirrors the schema as specified; it is redundant but harmless, and
-- may be useful for tools that query the tables directly without going
-- through this module.
--
-- Save/load semantics: M.save is a full snapshot — it deletes all rows in
-- all three tables and rewrites them from the given chart + journal. It is
-- not an incremental upsert; there is no merge or dedup policy, because none
-- was asked for. Round-tripping (save, then load) reproduces an equivalent
-- in-memory chart + journal.
--
-- M.load re-derives every entry via journal.post (not by trusting the
-- stored book_amount_minor/book_currency columns), so a loaded journal is
-- revalidated against the same invariants a freshly-posted one would be
-- (balances zero in the book currency, referenced accounts exist). The
-- journal's book currency itself is not recoverable from the schema when
-- the journal has zero entries (no table stores it independently of a
-- line), so M.load takes it as an explicit parameter — the same shape as
-- journal.new(book_currency) already requires.
--
-- Ordering: accounts must be loaded parent-before-child (lib.bookkeeping.account
-- enforces this on insert) and entries/lines must be loaded in original
-- posting order for ledger tie-breaks to reproduce. Both are recovered via
-- `ORDER BY rowid`, which reflects insertion order for an ordinary SQLite
-- rowid table (both tables use an explicit TEXT PRIMARY KEY, so SQLite still
-- allocates an implicit rowid) as long as M.save always deletes and
-- reinserts the full table (never updates rows in place).

local money   = require("lib.money")
local account = require("lib.bookkeeping.account")
local journal = require("lib.bookkeeping.journal")

local M = {}

--:: money_value = { amount_minor: number, currency: string }
--:: sqlite_db = {
--::   execute: (self: sqlite_db, string, ...unknown) -> (boolean | nil, string | nil),
--::   query: (self: sqlite_db, string, ...unknown) -> ((() -> unknown) | nil, string | nil),
--:: }

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

--:: loaded = { chart: chart, journal: bookkeeping_journal }

-- TYPECHECKER WORKAROUND: same class of bug documented in journal.lua's
-- build_line (the "unknown -> optional T" merge does not survive past a
-- guarding `if`). Values read back from db:query() are `unknown` per
-- column; an optional column (code, description, parent_id, rate) needs a
-- nil-check followed by a type-check, and the natural code would reuse one
-- narrowed local across both branches. Isolated here into single-purpose
-- helpers (one function, one guarded return per branch) so no caller needs
-- to thread an `unknown -> T | nil` narrow through its own branches. See
-- TODO.md; delete these helpers (inline the checks at each call site) once
-- guard-based narrowing survives a shared optional-typed local.
--: (unknown, string) -> (string | nil, string | nil)
local function opt_string(v, err_msg)
  if v == nil then return nil end
  if type(v) ~= "string" then return nil, err_msg end
  return v
end

--: (unknown, string) -> (number | nil, string | nil)
local function opt_number(v, err_msg)
  if v == nil then return nil end
  if type(v) ~= "number" then return nil, err_msg end
  return v
end

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------

--- Create the accounts / journal_entries / journal_lines tables if they do
-- not already exist. Safe to call on every open.
--: sqlite_db -> (true | nil, string | nil)
M.create_schema = function(db)
  local ok, err = db:execute([[
    CREATE TABLE IF NOT EXISTS accounts (
      id          TEXT PRIMARY KEY,
      name        TEXT NOT NULL,
      type        TEXT NOT NULL,
      code        TEXT,
      description TEXT,
      parent_id   TEXT REFERENCES accounts(id),
      metadata    TEXT
    );
  ]])
  if not ok then return nil, "bookkeeping.store: create accounts: " .. tostring(err) end

  ok, err = db:execute([[
    CREATE TABLE IF NOT EXISTS journal_entries (
      id          TEXT PRIMARY KEY,
      date        TEXT NOT NULL,
      description TEXT NOT NULL,
      metadata    TEXT
    );
  ]])
  if not ok then return nil, "bookkeeping.store: create journal_entries: " .. tostring(err) end

  ok, err = db:execute([[
    CREATE TABLE IF NOT EXISTS journal_lines (
      id                 INTEGER PRIMARY KEY AUTOINCREMENT,
      entry_id           TEXT NOT NULL REFERENCES journal_entries(id),
      account_id         TEXT NOT NULL REFERENCES accounts(id),
      amount_minor       INTEGER NOT NULL,
      currency           TEXT NOT NULL,
      rate               REAL,
      book_amount_minor  INTEGER NOT NULL,
      book_currency      TEXT NOT NULL
    );
  ]])
  if not ok then return nil, "bookkeeping.store: create journal_lines: " .. tostring(err) end

  return true
end

-- ---------------------------------------------------------------------------
-- Save
-- ---------------------------------------------------------------------------

--- Replace the full contents of the accounts / journal_entries /
-- journal_lines tables with `chart` and `journal`'s current state. Not
-- incremental — always wipes and rewrites all three tables. Call
-- M.create_schema first (or M.save will fail against a fresh db).
--: (sqlite_db, chart, bookkeeping_journal) -> (true | nil, string | nil)
M.save = function(db, chart, journal_)
  local ok, err = db:execute("BEGIN;")
  if not ok then return nil, "bookkeeping.store: begin: " .. tostring(err) end

  --: string -> (nil, string)
  local function fail(msg)
    db:execute("ROLLBACK;")
    return nil, msg
  end

  ok, err = db:execute("DELETE FROM journal_lines;")
  if not ok then return fail("bookkeeping.store: delete journal_lines: " .. tostring(err)) end
  ok, err = db:execute("DELETE FROM journal_entries;")
  if not ok then return fail("bookkeeping.store: delete journal_entries: " .. tostring(err)) end
  ok, err = db:execute("DELETE FROM accounts;")
  if not ok then return fail("bookkeeping.store: delete accounts: " .. tostring(err)) end

  local accounts = account.list(chart)
  for i = 1, #accounts do
    local acct = accounts[i]
    ok, err = db:execute(
      "INSERT INTO accounts (id, name, type, code, description, parent_id, metadata) VALUES (?, ?, ?, ?, ?, ?, ?);",
      acct.id, acct.name, acct.type, acct.code, acct.description, acct.parent, nil
    )
    if not ok then return fail("bookkeeping.store: insert account " .. acct.id .. ": " .. tostring(err)) end
  end

  local entries = journal.list(journal_)
  for i = 1, #entries do
    local entry = entries[i]
    ok, err = db:execute(
      "INSERT INTO journal_entries (id, date, description, metadata) VALUES (?, ?, ?, ?);",
      entry.id, entry.date, entry.description, nil
    )
    if not ok then return fail("bookkeeping.store: insert entry " .. entry.id .. ": " .. tostring(err)) end

    local lines = entry.lines
    for j = 1, #lines do
      local line = lines[j]
      ok, err = db:execute(
        "INSERT INTO journal_lines (entry_id, account_id, amount_minor, currency, rate, book_amount_minor, book_currency) "
          .. "VALUES (?, ?, ?, ?, ?, ?, ?);",
        entry.id, line.account, line.amount.amount_minor, line.amount.currency, line.rate,
        line.book_amount.amount_minor, journal_.book_currency
      )
      if not ok then return fail("bookkeeping.store: insert line for entry " .. entry.id .. ": " .. tostring(err)) end
    end
  end

  ok, err = db:execute("COMMIT;")
  if not ok then return fail("bookkeeping.store: commit: " .. tostring(err)) end
  return true
end

-- ---------------------------------------------------------------------------
-- Load
-- ---------------------------------------------------------------------------

--- Rebuild a chart of accounts and a journal (denominated in
-- `book_currency`) from the accounts / journal_entries / journal_lines
-- tables. `book_currency` must be supplied by the caller — it is not
-- recoverable from the schema alone when the journal has zero lines.
-- Every entry is re-posted via journal.post, so a loaded journal is
-- revalidated against the same balance/account-existence invariants a
-- freshly-posted one would be.
--: (sqlite_db, string) -> (loaded | nil, string | nil)
M.load = function(db, book_currency)
  local chart = account.new()

  local iter, err = db:query("SELECT id, name, type, code, description, parent_id FROM accounts ORDER BY rowid;")
  if not iter then return nil, "bookkeeping.store: query accounts: " .. tostring(err) end
  while true do
    local id, name, atype, code, description, parent_id = iter()
    if id == nil then break end
    if type(id) ~= "string" then return nil, "bookkeeping.store: account: id: expected string from db" end
    if type(name) ~= "string" then return nil, "bookkeeping.store: account " .. id .. ": name: expected string from db" end
    if type(atype) ~= "string" then return nil, "bookkeeping.store: account " .. id .. ": type: expected string from db" end
    local code_s, code_err = opt_string(code, "bookkeeping.store: account " .. id .. ": code: expected string or nil from db")
    if code_err then return nil, code_err end
    local description_s, description_err = opt_string(
      description, "bookkeeping.store: account " .. id .. ": description: expected string or nil from db"
    )
    if description_err then return nil, description_err end
    local parent_s, parent_err = opt_string(
      parent_id, "bookkeeping.store: account " .. id .. ": parent_id: expected string or nil from db"
    )
    if parent_err then return nil, parent_err end
    local acct, aerr = account.add_account(chart, {
      id = id, name = name, type = atype, code = code_s, description = description_s, parent = parent_s,
    })
    if not acct then return nil, "bookkeeping.store: load account " .. id .. ": " .. tostring(aerr) end
  end

  local j, jerr = journal.new(book_currency)
  if not j then return nil, "bookkeeping.store: " .. tostring(jerr) end

  local eiter, eerr = db:query("SELECT id, date, description FROM journal_entries ORDER BY rowid;")
  if not eiter then return nil, "bookkeeping.store: query journal_entries: " .. tostring(eerr) end
  while true do
    local entry_id, date, description = eiter()
    if entry_id == nil then break end
    if type(entry_id) ~= "string" then return nil, "bookkeeping.store: journal_entries: id: expected string from db" end
    if type(date) ~= "string" then return nil, "bookkeeping.store: entry " .. entry_id .. ": date: expected string from db" end
    if type(description) ~= "string" then
      return nil, "bookkeeping.store: entry " .. entry_id .. ": description: expected string from db"
    end

    local liter, lerr = db:query(
      "SELECT account_id, amount_minor, currency, rate FROM journal_lines WHERE entry_id = ? ORDER BY rowid;",
      entry_id
    )
    if not liter then return nil, "bookkeeping.store: query journal_lines for " .. entry_id .. ": " .. tostring(lerr) end

    local lines = {} --: { [number]: { account: string, amount: money_value, rate: number | nil } }
    while true do
      local account_id, amount_minor, currency, rate = liter()
      if account_id == nil then break end
      if type(account_id) ~= "string" then
        return nil, "bookkeeping.store: journal_lines for entry " .. entry_id .. ": account_id: expected string from db"
      end
      if type(amount_minor) ~= "number" then
        return nil, "bookkeeping.store: journal_lines for entry " .. entry_id .. ": amount_minor: expected number from db"
      end
      if type(currency) ~= "string" then
        return nil, "bookkeeping.store: journal_lines for entry " .. entry_id .. ": currency: expected string from db"
      end
      local rate_n, rate_err = opt_number(
        rate, "bookkeeping.store: journal_lines for entry " .. entry_id .. ": rate: expected number or nil from db"
      )
      if rate_err then return nil, rate_err end
      local amount, merr = money.new(amount_minor, currency)
      if not amount then return nil, "bookkeeping.store: line amount for entry " .. entry_id .. ": " .. tostring(merr) end
      lines[#lines + 1] = { account = account_id, amount = amount, rate = rate_n }
    end

    local entry, perr = journal.post(j, chart, {
      id = entry_id, date = date, description = description, lines = lines,
    })
    if not entry then return nil, "bookkeeping.store: load entry " .. entry_id .. ": " .. tostring(perr) end
  end

  return { chart = chart, journal = j }
end

return M
