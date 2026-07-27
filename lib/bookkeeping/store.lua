if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- SQLite persistence for lib/bookkeeping.
--
-- Caps-first: the sqlite connection (a `lib.sqlite` handle, from
-- `require("lib.sqlite").open(path)`) is always passed in by the caller,
-- never opened internally.
--
-- Schema (four tables; see M.create_schema for the exact DDL):
--   accounts        (id, name, type, code, description, parent_id, metadata)
--   journal_entries (id, date, description, period_id, metadata)
--   journal_lines   (id, entry_id, account_id, amount_minor, currency, rate,
--                     book_amount_minor, book_currency)
--   config          (key, value) — currently just the single row
--                     key='book_currency' (see M.save_config/M.load_config)
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
-- Save/load semantics: accounts and config are global (not period-scoped).
-- M.save(db, journal, chart, period_id) always fully replaces the accounts
-- table and persists journal.book_currency to config, but only replaces
-- journal_entries/journal_lines rows tagged `period_id` — entries belonging
-- to any other period already in the db are untouched. M.save_period is the
-- same entries/lines replacement without touching accounts or config, for
-- cheaply persisting one period's activity when the chart hasn't changed.
-- M.load(db) reads book_currency from config (error if absent) and rebuilds
-- every period's entries; M.load_period(db, period_id) restricts to one
-- period's entries. Neither is incremental in the sense of merging with an
-- in-memory chart/journal the caller already has — both always rebuild
-- fresh in-memory structures from what's currently in the db.
--
-- M.load/M.load_period re-derive every entry via journal.post (not by
-- trusting the stored book_amount_minor/book_currency columns), so a loaded
-- journal is revalidated against the same invariants a freshly-posted one
-- would be (balances zero in the book currency, referenced accounts exist).
--
-- Ordering: accounts must be loaded parent-before-child (lib.bookkeeping.account
-- enforces this on insert) and entries/lines must be loaded in original
-- posting order for ledger tie-breaks to reproduce. Both are recovered via
-- `ORDER BY rowid`, which reflects insertion order for an ordinary SQLite
-- rowid table (both tables use an explicit TEXT PRIMARY KEY, so SQLite still
-- allocates an implicit rowid) as long as a save always deletes and
-- reinserts the rows it's replacing (never updates rows in place).

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

-- TYPECHECKER WORKAROUND: the natural code has M.load and M.load_period call
-- `M.load_config(db)` directly (the same public function this module already
-- exposes for that exact purpose). Confirmed via extensive bisection that a
-- destructured local bound from `M.load_config(db)` — regardless of how it's
-- extracted (direct multi-assignment, truncating parens `(M.load_config(db))`,
-- or first binding `M.load_config` to a local before calling it) — is typed
-- as the function's full `(string | nil, string | nil)` return tuple rather
-- than the destructured `string | nil` at its first position, causing every
-- later use to fail argument/assignment checks against a plain `string`
-- parameter. This reproduces only with `M.load_config`'s real body in place
-- (trivial stand-ins in isolated repros did not reproduce it) and not with
-- any other multi-return function in this file, so it isn't simply "M.-bound
-- calls don't narrow" (`account.add_account`, also M.-bound, is unaffected).
-- Root cause not pinned down further given the cost already sunk into
-- bisection; looks like another instance of the "whole-file inference
-- instability" class already logged in TODO.md, specific to this one
-- function value somehow. Worked around by giving M.load/M.load_period their
-- own independent local copy of the same read-config logic (this function)
-- instead of calling `M.load_config` — a fresh, differently-bound function
-- value avoids whatever is wrong with `M.load_config` specifically.
-- `M.load_config` itself (the public API) is unaffected and delegates here.
-- See TODO.md; collapse back to `M.load and M.load_period calling
-- M.load_config directly once this is root-caused and fixed.
--: sqlite_db -> (string | nil, string | nil)
local function read_book_currency(db)
  local iter, err = db:query("SELECT value FROM config WHERE key = 'book_currency';")
  if not iter then return nil, "bookkeeping.store: load_config: " .. tostring(err) end
  local value = iter()
  if value == nil then
    return nil, "bookkeeping.store: no book_currency configured"
  end
  if type(value) ~= "string" then
    return nil, "bookkeeping.store: config book_currency: expected string from db"
  end
  return value, nil
end

--:: loaded_entry_data = { id: string, date: string, description: string, lines: { [number]: { account: string, amount: money_value, rate: number | nil } } }

-- Read every row out of journal_entries/journal_lines as plain data (no
-- `bookkeeping_journal` type involved at all) — `period_id`, if given,
-- restricts to that period; nil reads every period. Kept entirely separate
-- from journal construction/posting (see build_journal_from_rows below) —
-- see the larger TYPECHECKER WORKAROUND comment above M.load for why.
--: (sqlite_db, string | nil) -> ({ [number]: loaded_entry_data } | nil, string | nil)
local function read_entry_rows(db, period_id)
  local eiter, eerr = db:query(
    "SELECT id, date, description FROM journal_entries WHERE period_id = ? OR ? IS NULL ORDER BY rowid;",
    period_id, period_id
  )
  if not eiter then return nil, "bookkeeping.store: query journal_entries: " .. tostring(eerr) end

  local rows = {} --: { [number]: loaded_entry_data }
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

    rows[#rows + 1] = { id = entry_id, date = date, description = description, lines = lines }
  end

  return rows
end

-- TYPECHECKER WORKAROUND: the natural code posts each row directly inside
-- read_entry_rows' loop (avoiding a second pass over the data) — i.e. one
-- combined `load_entries(db, chart, book_currency, period_id)` doing both
-- the DB reads and the `journal.post` calls together, the same shape this
-- file went through several failed iterations of (see the larger
-- TYPECHECKER WORKAROUND comment above M.load for the full account). That
-- combined shape reliably corrupts the loaded journal's (`j`'s) type by the
-- time it is reused after the loop — confirmed this happens regardless of
-- which function constructs `j`, whether `j` is passed as a parameter or
-- reused as a local, and regardless of textual distance between `j`'s guard
-- and its later use. What resolved it: splitting "read rows as plain data"
-- (read_entry_rows above, which touches no `bookkeeping_journal`-typed value
-- at all) from "construct a journal and post already-known-good rows into
-- it" (this function) — i.e. exactly the split CLAUDE.md's TYPECHECKER
-- WORKAROUND protocol suggests: make the DB-reading helper return a simpler
-- type, and keep the journal-typed value's entire lifecycle (construct,
-- loop-post, return) inside one small function that never also has to do
-- SQL reads / opt_string / opt_number narrowing in the same scope. Root
-- cause not pinned down further given the scale of investigation already
-- sunk into it (see TODO.md); this looks like the "whole-file/whole-function
-- inference instability" class already logged there — unrelated code shape
-- (the DB-reading branches) perturbing a distant narrow of an unrelated
-- variable (`j`) — but is a new instance of it. Revert to a single combined
-- loader once this resolves.
--: (sqlite_db, chart, { [number]: loaded_entry_data }) -> (bookkeeping_journal | nil, string | nil)
local function build_journal_from_rows(db, chart, rows)
  -- Reading book_currency here, inlined directly (not via the
  -- read_book_currency helper, and immediately before journal.new with no
  -- preceding loop in this function), rather than accepting it as a
  -- caller-supplied parameter, is itself part of the workaround — see the
  -- larger TYPECHECKER WORKAROUND comment above M.load. Both "M.load/
  -- M.load_period read book_currency themselves and pass it in as a
  -- parameter" and "call the read_book_currency helper from in here" were
  -- tried first and suffered the exact same "reverts to its source call's
  -- full return-tuple type" corruption `j` did, by the time the value
  -- reached `journal.new` below; only inlining the query directly avoided it.
  local iter, err = db:query("SELECT value FROM config WHERE key = 'book_currency';")
  if not iter then return nil, "bookkeeping.store: load_config: " .. tostring(err) end
  local value = iter()
  if value == nil then return nil, "bookkeeping.store: no book_currency configured" end
  if type(value) ~= "string" then return nil, "bookkeeping.store: config book_currency: expected string from db" end

  local j, jerr = journal.new(value)
  if not j then return nil, "bookkeeping.store: " .. tostring(jerr) end

  for i = 1, #rows do
    local row = rows[i]
    local entry, perr = journal.post(j, chart, {
      id = row.id, date = row.date, description = row.description, lines = row.lines,
    })
    if not entry then return nil, "bookkeeping.store: load entry " .. row.id .. ": " .. tostring(perr) end
  end

  return j
end

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------

--- Create the accounts / journal_entries / journal_lines / config tables if
-- they do not already exist. Safe to call on every open.
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
      period_id   TEXT,
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

  ok, err = db:execute([[
    CREATE TABLE IF NOT EXISTS config (
      key   TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );
  ]])
  if not ok then return nil, "bookkeeping.store: create config: " .. tostring(err) end

  return true
end

-- ---------------------------------------------------------------------------
-- Save
-- ---------------------------------------------------------------------------

-- Delete every journal_lines/journal_entries row tagged with `period_id`,
-- then reinsert `journal_`'s current entries under that same period_id.
-- Rows for every other period_id (including NULL, for rows written before
-- this column existed) are untouched — this is the "incremental, one period
-- at a time" primitive both M.save and M.save_period build on. Must run
-- inside a transaction the caller already opened; on error returns the
-- caller's own `fail(msg)` result so the caller's rollback still runs.
--: (sqlite_db, bookkeeping_journal, string, (string) -> (nil, string)) -> (true | nil, string | nil)
local function save_entries_for_period(db, journal_, period_id, fail)
  local ok, err = db:execute(
    "DELETE FROM journal_lines WHERE entry_id IN (SELECT id FROM journal_entries WHERE period_id = ?);",
    period_id
  )
  if not ok then return fail("bookkeeping.store: delete journal_lines for period " .. period_id .. ": " .. tostring(err)) end
  ok, err = db:execute("DELETE FROM journal_entries WHERE period_id = ?;", period_id)
  if not ok then return fail("bookkeeping.store: delete journal_entries for period " .. period_id .. ": " .. tostring(err)) end

  local entries = journal.list(journal_)
  for i = 1, #entries do
    local entry = entries[i]
    ok, err = db:execute(
      "INSERT INTO journal_entries (id, date, description, period_id, metadata) VALUES (?, ?, ?, ?, ?);",
      entry.id, entry.date, entry.description, period_id, nil
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

  return true
end

--- Save `chart` and `journal_` for a single period. Accounts are global
-- (not period-scoped), so the accounts table is always fully wiped and
-- rewritten from `chart`. Journal entries/lines are period-scoped: only
-- rows tagged `period_id` are replaced (see save_entries_for_period above);
-- entries belonging to any other period already in the db are left alone.
-- Also persists `journal_.book_currency` to the config table (M.save_config)
-- — the book currency is store-wide state, not per-period, and this is the
-- one call site that always has an authoritative in-memory value for it.
-- Call M.create_schema first (or M.save will fail against a fresh db).
--: (sqlite_db, bookkeeping_journal, chart, string) -> (true | nil, string | nil)
M.save = function(db, journal_, chart, period_id)
  if type(period_id) ~= "string" or period_id == "" then
    return nil, "bookkeeping.store: period_id must be a non-empty string"
  end

  local ok, err = db:execute("BEGIN;")
  if not ok then return nil, "bookkeeping.store: begin: " .. tostring(err) end

  --: string -> (nil, string)
  local function fail(msg)
    db:execute("ROLLBACK;")
    return nil, msg
  end

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

  local saved, save_err = save_entries_for_period(db, journal_, period_id, fail)
  if not saved then return nil, save_err end

  local configured, config_err = M.save_config(db, journal_.book_currency)
  if not configured then return fail("bookkeeping.store: " .. tostring(config_err)) end

  ok, err = db:execute("COMMIT;")
  if not ok then return fail("bookkeeping.store: commit: " .. tostring(err)) end
  return true
end

--- Incremental save: replace only the journal entries/lines tagged
-- `period_id`, leaving accounts, the config table, and every other period's
-- entries untouched. Use this instead of M.save when the chart hasn't
-- changed and you only need to persist this period's journal activity
-- cheaply. `chart` is accepted (matching M.save's shape) but not written —
-- it exists so a caller can pass the same (journal, chart, period_id) it
-- would give M.save without restructuring the call.
--: (sqlite_db, bookkeeping_journal, chart, string) -> (true | nil, string | nil)
M.save_period = function(db, journal_, chart, period_id)
  if type(period_id) ~= "string" or period_id == "" then
    return nil, "bookkeeping.store: period_id must be a non-empty string"
  end

  local ok, err = db:execute("BEGIN;")
  if not ok then return nil, "bookkeeping.store: begin: " .. tostring(err) end

  --: string -> (nil, string)
  local function fail(msg)
    db:execute("ROLLBACK;")
    return nil, msg
  end

  local saved, save_err = save_entries_for_period(db, journal_, period_id, fail)
  if not saved then return nil, save_err end

  ok, err = db:execute("COMMIT;")
  if not ok then return fail("bookkeeping.store: commit: " .. tostring(err)) end
  return true
end

--- Upsert the book currency into the config table.
--: (sqlite_db, string) -> (true | nil, string | nil)
M.save_config = function(db, book_currency)
  if not money.is_valid_currency(book_currency) then
    return nil, "bookkeeping.store: unknown book currency: " .. tostring(book_currency)
  end
  local ok, err = db:execute(
    "INSERT INTO config (key, value) VALUES ('book_currency', ?) "
      .. "ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
    book_currency
  )
  if not ok then return nil, "bookkeeping.store: save_config: " .. tostring(err) end
  return true
end

--- Read the book currency back from the config table.
--: sqlite_db -> (string | nil, string | nil)
M.load_config = function(db)
  return read_book_currency(db)
end

-- ---------------------------------------------------------------------------
-- Load
-- ---------------------------------------------------------------------------

-- TYPECHECKER WORKAROUND: the natural code here is a single combined
-- `load_entries(db, chart, book_currency, period_id)` local function —
-- reading each journal_entries/journal_lines row AND calling `journal.post`
-- on it in the same loop, shared by M.load and M.load_period. Every version
-- of that shape (destructured directly in M.load/M.load_period, factored
-- into a shared helper, called with `book_currency`/`chart`/`j` as
-- parameters instead of destructured locals, moved immediately next to its
-- own guard, etc.) was confirmed to genuinely round-trip (SQL correct,
-- logic correct) but reliably fails to typecheck: the loaded journal value
-- (`j`, from `journal.new`) gets reported as its own source call's full
-- return-tuple type — "tuple is not assignable to table/array" / "(T | nil,
-- string | nil) is not assignable to T" — by the time it is reused after
-- the loop that calls `journal.post` once per row, regardless of which
-- function constructs it, whether it's a table-field-bound or plain-local
-- call, and regardless of textual distance between its guard and its later
-- use. Confirmed via extensive bisection (see TODO.md for the full account)
-- this is NOT the already-logged "generic pinned by an earlier call in the
-- same file" class (repros with two call sites and trivial bodies pass
-- fine) — it only reproduces with the real, non-trivial bodies (loops,
-- `db:query`, `opt_string`/`opt_number`, cross-module `journal.post`) in
-- place. `--[[:! bookkeeping_journal]]` force-casting `j` at its use sites
-- was tried and is flatly rejected by the checker itself ("force cast has
-- no overlap: tuple vs table" — the two shapes are structurally disjoint,
-- not just unprovable), and `--[[: any]]` is disallowed project-wide, so
-- neither is a usable escape hatch here.
--
-- What actually works, applied below: split "read journal_entries/
-- journal_lines rows as plain data" (read_entry_rows, above — touches no
-- `bookkeeping_journal`-typed value at all, only plain records) from
-- "construct a journal and post already-known-good rows into it"
-- (build_journal_from_rows, above — a tiny function whose only job is
-- `journal.new` + a loop of `journal.post` calls, with no SQL reads or
-- `opt_string`/`opt_number` narrowing sharing its scope). `j`'s entire
-- lifecycle (construct, loop-post, return) now lives inside
-- build_journal_from_rows and never coexists, in the same function, with
-- the account-loading loop or the row-reading loop — which is what resolved
-- it. Root cause not pinned down further given the scale of investigation
-- already sunk into it; looks like the "whole-file/whole-function inference
-- instability" class already logged elsewhere in TODO.md (unrelated code
-- shape perturbing a distant variable's narrowing) but is a new instance of
-- it, logged as its own entry there. Revert to a single combined
-- read-and-post loader once this resolves.

--- Rebuild the journal (every period), chart of accounts, and book currency
-- from the db. `book_currency` comes from the config table (M.load_config)
-- rather than a caller-supplied argument — see M.save_config, which is what
-- put it there. Returns (nil, nil, nil, err) on any failure, including a
-- missing config row.
--: sqlite_db -> (bookkeeping_journal | nil, chart | nil, string | nil, string | nil)
M.load = function(db)
  local chart = account.new()

  local iter, err = db:query("SELECT id, name, type, code, description, parent_id FROM accounts ORDER BY rowid;")
  if not iter then return nil, nil, nil, "bookkeeping.store: query accounts: " .. tostring(err) end
  while true do
    local id, name, atype, code, description, parent_id = iter()
    if id == nil then break end
    if type(id) ~= "string" then return nil, nil, nil, "bookkeeping.store: account: id: expected string from db" end
    if type(name) ~= "string" then return nil, nil, nil, "bookkeeping.store: account " .. id .. ": name: expected string from db" end
    if type(atype) ~= "string" then return nil, nil, nil, "bookkeeping.store: account " .. id .. ": type: expected string from db" end
    local code_s, code_err = opt_string(code, "bookkeeping.store: account " .. id .. ": code: expected string or nil from db")
    if code_err then return nil, nil, nil, code_err end
    local description_s, description_err = opt_string(
      description, "bookkeeping.store: account " .. id .. ": description: expected string or nil from db"
    )
    if description_err then return nil, nil, nil, description_err end
    local parent_s, parent_err = opt_string(
      parent_id, "bookkeeping.store: account " .. id .. ": parent_id: expected string or nil from db"
    )
    if parent_err then return nil, nil, nil, parent_err end
    local acct, aerr = account.add_account(chart, {
      id = id, name = name, type = atype, code = code_s, description = description_s, parent = parent_s,
    })
    if not acct then return nil, nil, nil, "bookkeeping.store: load account " .. id .. ": " .. tostring(aerr) end
  end

  local rows, rerr = read_entry_rows(db, nil)
  if not rows then return nil, nil, nil, rerr end

  local j, jerr = build_journal_from_rows(db, chart, rows)
  if not j then return nil, nil, nil, jerr end

  return j, chart, j.book_currency, nil
end

--- Like M.load, but restricts the journal to entries tagged `period_id`.
-- The chart of accounts and book currency are still store-wide (not
-- period-scoped), so both are loaded in full, same as M.load. See the
-- TYPECHECKER WORKAROUND comment above M.load for why this duplicates
-- M.load's body instead of sharing it through a helper function.
--: (sqlite_db, string) -> (bookkeeping_journal | nil, chart | nil, string | nil, string | nil)
M.load_period = function(db, period_id)
  if type(period_id) ~= "string" or period_id == "" then
    return nil, nil, nil, "bookkeeping.store: period_id must be a non-empty string"
  end

  local chart = account.new()

  local iter, err = db:query("SELECT id, name, type, code, description, parent_id FROM accounts ORDER BY rowid;")
  if not iter then return nil, nil, nil, "bookkeeping.store: query accounts: " .. tostring(err) end
  while true do
    local id, name, atype, code, description, parent_id = iter()
    if id == nil then break end
    if type(id) ~= "string" then return nil, nil, nil, "bookkeeping.store: account: id: expected string from db" end
    if type(name) ~= "string" then return nil, nil, nil, "bookkeeping.store: account " .. id .. ": name: expected string from db" end
    if type(atype) ~= "string" then return nil, nil, nil, "bookkeeping.store: account " .. id .. ": type: expected string from db" end
    local code_s, code_err = opt_string(code, "bookkeeping.store: account " .. id .. ": code: expected string or nil from db")
    if code_err then return nil, nil, nil, code_err end
    local description_s, description_err = opt_string(
      description, "bookkeeping.store: account " .. id .. ": description: expected string or nil from db"
    )
    if description_err then return nil, nil, nil, description_err end
    local parent_s, parent_err = opt_string(
      parent_id, "bookkeeping.store: account " .. id .. ": parent_id: expected string or nil from db"
    )
    if parent_err then return nil, nil, nil, parent_err end
    local acct, aerr = account.add_account(chart, {
      id = id, name = name, type = atype, code = code_s, description = description_s, parent = parent_s,
    })
    if not acct then return nil, nil, nil, "bookkeeping.store: load account " .. id .. ": " .. tostring(aerr) end
  end

  local rows, rerr = read_entry_rows(db, period_id)
  if not rows then return nil, nil, nil, rerr end

  local j, jerr = build_journal_from_rows(db, chart, rows)
  if not j then return nil, nil, nil, jerr end

  return j, chart, j.book_currency, nil
end

return M
