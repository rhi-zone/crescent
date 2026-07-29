if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Bidirectional bridge for the finance app: bookkeeping domain model (chart
-- of accounts + journal, lib/bookkeeping) <-> yjs (lib/y_crdt, sync
-- transport) <-> SQLite (lib/bookkeeping/store.lua, source of truth).
--
-- Architecture (see docs/overview.md and this app's own architecture notes):
--   - SQLite is the source of truth; yjs is sync transport only.
--   - Local operations: validate via lib.bookkeeping -> save to SQLite ->
--     mirror into the relevant Y.Doc -> notify the sync manager (if any).
--   - Remote sync: a Y.Doc changed by an incoming update -> diffed against
--     SQLite -> applied via lib.bookkeeping (so the same invariants a local
--     write gets are enforced); an update that would violate an invariant is
--     logged as a conflict, never silently applied.
--   - Queries read SQLite directly; no yjs involved.
--
-- Accounts-table persistence caveat: lib.bookkeeping.store.save always
-- rewrites the *entire* accounts table, but is keyed to a single
-- `period_id` for the journal_entries/journal_lines rows it also touches
-- (store.lua's save_entries_for_period deletes+reinserts only that
-- period_id's rows, from whatever in-memory journal is passed in -- period
-- membership does not exist on the in-memory `entry` record at all, only as
-- a column in the DB). So persisting an accounts-only change (add/update/
-- delete account, no journal change) safely -- i.e. without either
-- corrupting or silently dropping any other period's entries -- requires
-- calling store.save once per period *that currently has any rows in
-- SQLite* (found via a direct `SELECT DISTINCT period_id`, not via
-- doc_registry's "periods" metadata map, which tracks explicitly-registered
-- periods and is not guaranteed to enumerate every period_id lib.bookkeeping
-- entries have ever been posted under), passing back that same period's own
-- freshly-loaded (and therefore unchanged) journal each time -- see
-- save_chart_to_all_periods below.

local account       = require("lib.bookkeeping.account")
local journal        = require("lib.bookkeeping.journal")
local store          = require("lib.bookkeeping.store")
local ledger_mod     = require("lib.bookkeeping.ledger")
local trial_balance  = require("lib.bookkeeping.trial_balance")
local report         = require("lib.bookkeeping.report")
local money          = require("lib.money")
local doc_registry   = require("lib.platform.apps.finance.doc_registry")
local doc_mod        = require("lib.y_crdt.doc")
local map            = require("lib.y_crdt.map")
local arr            = require("lib.y_crdt.array")
local update         = require("lib.y_crdt.update")

local M = {}

-- Doc/Registry are non-recursive, so `typeof` captures them exactly -- same
-- reasoning doc_registry.lua/sync_manager.lua both use. `typeof` only
-- accepts a bare identifier (journal.lua's header comment), so each sample
-- is bound to its own local first.
local sample_reg = doc_registry.new({ client_id = 0 })
--:: Registry = typeof sample_reg
local sample_doc = doc_registry.accounts_doc(sample_reg)
--:: Doc = typeof sample_doc

-- Restated lib.bookkeeping.account/journal shapes -- mirrors those modules'
-- own header comments verbatim (this codebase's established precedent for
-- why: the checker infers require() return types from `return M` but does
-- not expose a required module's `--::` aliases under a namespace, so
-- there is no non-duplicating way to reference e.g. `account.account` from
-- here -- see journal.lua's header comment for the full rationale).
--:: AccountType = "asset" | "liability" | "equity" | "revenue" | "expense"
--:: Account = { id: string, name: string, type: AccountType, code: string | nil, description: string | nil, parent: string | nil }
--:: Chart = { by_id: { [string]: Account }, order: { [number]: string } }
--:: MoneyValue = { amount_minor: number, currency: string }
--:: JournalLine = { account: string, amount: MoneyValue, rate: number | nil, book_amount: MoneyValue }
--:: JournalEntry = { id: string, date: string, description: string, lines: { [number]: JournalLine } }
--:: BkJournal = { book_currency: string, entries: { [number]: JournalEntry }, _by_id: { [string]: JournalEntry }, _next_id: number }

-- Restated Transaction/Item/Content shape -- see lib/y_crdt/map.lua's own
-- header restatement (this is the same type, copied verbatim per that
-- file's own precedent: `typeof` doesn't survive `require()` and these
-- types are self-referential, so `typeof` can't capture them from a sample
-- value even in-file). Needed for the same reason
-- lib/platform/apps/finance/doc_registry.lua's own copy is: narrowing the
-- `unknown` transaction handle `lib.y_crdt.doc`'s `M.transact` callback
-- receives into the concrete shape `map.set`/`array.insert`/`array.delete`
-- require -- see `run_transaction`'s TYPECHECKER WORKAROUND comment below.
--:: Id = { client: integer, clock: integer }
--:: ParentPendingId = { kind: "pending_parent_id", client: integer, clock: integer }
--:: Content = { kind: "deleted", ref: integer, len: integer } | { kind: "string", ref: integer, str: string } | { kind: "json", ref: integer, arr: unknown[] } | { kind: "embed", ref: integer, embed: unknown } | { kind: "any", ref: integer, arr: unknown[] } | { kind: "format", ref: integer, key: string, value: unknown } | { kind: "type", ref: integer, shared_type: unknown } | { kind: "doc", ref: integer, guid: string, opts: unknown } | { kind: "binary", ref: integer, bytes: string }
--:: SharedTypeRaw = { kind: "shared_type", type_name: string, start: Item | nil, map: { [string]: Item }, length: number, item: Item | nil }
--:: Item = {
--::   kind: "item",
--::   id: Id,
--::   origin: Id | nil,
--::   origin_right: Id | nil,
--::   left: Item | nil,
--::   right: Item | nil,
--::   parent: SharedTypeRaw | ParentPendingId | nil,
--::   parent_sub: string | nil,
--::   content: Content,
--::   length: integer,
--::   deleted: boolean,
--::   keep: boolean,
--:: }
-- Two distinct Transaction restatements are needed, not one: map.lua's own
-- `Transaction.doc` is `{ client_id, store: { clients: { [number]: unknown } } }`
-- (no `share` field, `clients` untyped) while lib/y_crdt/update.lua's own
-- `Transaction.doc` is the *full* Doc (`share` present, `clients:
-- { [number]: Struct[] }` concretely typed, since encode_v1 actually walks
-- the structs). Confirmed by minimal repro that this checker's record
-- typing is exact here, not width-subtyped: giving `Transaction.doc` the
-- `share` field satisfies `update.encode_v1` but then fails map.set/
-- array.insert/array.delete's own narrower `Transaction` with "excess field
-- 'share' not in target type" -- so one shared restatement cannot serve
-- both call shapes; each cast site below uses whichever of the two
-- following aliases matches the function it's calling.
--:: Gc = { kind: "gc", id: Id, length: integer, deleted: true }
--:: Skip = { kind: "skip", id: Id, length: integer, deleted: false }
--:: Struct = Item | Gc | Skip
--:: SharedTypeShare = { [string]: SharedTypeRaw }

-- For map.set/map.delete/array.insert/array.delete (this file's `apply`
-- closures).
--:: MapStructStore = { clients: { [number]: unknown } }
--:: Transaction = { doc: { client_id: number, store: MapStructStore, clock: number }, new_items: Item[], deleted_items: Item[], merge_structs: Item[] }

-- For update.encode_v1 (this file's `run_transaction`/`mutate_doc` return
-- value).
--:: EncodeStructStore = { clients: { [number]: Struct[] } }
--:: EncodeTransaction = { doc: { client_id: number, store: EncodeStructStore, share: SharedTypeShare, clock: number, gc: boolean }, new_items: Item[], deleted_items: Item[], merge_structs: Item[] }

--:: DbCap = {
--::   execute: (self: DbCap, string, ...unknown) -> (boolean | nil, string | nil),
--::   query: (self: DbCap, string, ...unknown) -> ((() -> unknown) | nil, string | nil),
--::   ...
--:: }
--:: SyncManagerCap = { broadcast_change: (unknown, string, string) -> (true | nil, string | nil), ... }
--:: BridgeOpts = { registry: Registry, db: DbCap, sync_manager?: SyncManagerCap, book_currency?: string }
--:: Bridge = { registry: Registry, db: DbCap, sync_manager: SyncManagerCap | nil, book_currency: string }

--:: WireLine = { account_id: string, amount: number, currency: string, rate: number | nil }
--:: WireEntry = { id: string | nil, date: string, description: string, lines: { [number]: WireLine } }
--:: AccountData = { id: string, name: string, type: string, code: string | nil, description: string | nil, parent: string | nil }

-- ---------------------------------------------------------------------------
-- Transaction-under-unknown workaround (shared by every Y.Doc mutation below)
-- ---------------------------------------------------------------------------

-- TYPECHECKER WORKAROUND: see lib/platform/apps/finance/doc_registry.lua's
-- `transact_set_in_map` for the full writeup (same root cause, same fix).
-- Every function in this file that mutates a Y.Doc receives that Doc via a
-- Bridge/Registry field (never a value freshly constructed by `doc_mod.new`
-- in the same local scope), which is exactly the shape confirmed by minimal
-- repro to make `doc_mod.transact`'s inline-closure argument infer
-- incorrectly. Centralized here as a single helper so every call site below
-- gets the fix once: a named local `apply` function (not an inline closure
-- expression) whose parameter is explicitly `unknown` (matching
-- `doc_mod.transact`'s own declared callback type, so no inference pinning
-- occurs), immediately narrowed via the established `type(x) == "table"`
-- guard + checked cast to `Transaction` this codebase already uses for
-- "unknown must become a concrete record" (map.lua's own M.set/M.delete).
-- Returns the Transaction (concretely typed, ready to pass to
-- `update.encode_v1`) on success. See TODO.md; collapse back to an inline
-- closure once this inference gap is root-caused.
--: (Doc, (unknown) -> nil) -> (EncodeTransaction | nil, string | nil)
local function run_transaction(d, apply)
  local txn_result, terr = doc_mod.transact(d, apply)
  if txn_result == nil then
    if terr == nil then return nil, "bridge: transact failed with no error message" end
    if type(terr) ~= "string" then return nil, "bridge: transact failed with a non-string error" end
    return nil, terr
  end
  if type(txn_result) ~= "table" then
    return nil, "bridge: internal invariant: doc_mod.transact returned a non-table transaction"
  end
  return txn_result --[[: EncodeTransaction]]
end

-- Runs `apply` inside a transaction on `d`, then encodes the resulting
-- change as a v1 update -- the bytes lib.y_crdt.sync/lib.platform.apps
-- .finance.sync_manager broadcast to peers.
--: (Doc, (unknown) -> nil) -> (string | nil, string | nil)
local function mutate_doc(d, apply)
  local txn, terr = run_transaction(d, apply)
  if txn == nil then return nil, terr end
  return update.encode_v1(d, txn)
end

-- Broadcasts `update_bytes` for `doc_id` via the bridge's sync manager, if
-- one was injected. A bridge with no sync manager is a valid, fully local
-- configuration (per this app's "sync policy is pluggable" architecture
-- note) -- silently skipping the broadcast, not erroring, when none is
-- configured.
--: (Bridge, string, string) -> (true | nil, string | nil)
local function notify_sync(bridge, doc_id, update_bytes)
  local sm = bridge.sync_manager
  if sm == nil then return true end
  return sm.broadcast_change(sm, doc_id, update_bytes)
end

-- ---------------------------------------------------------------------------
-- Account <-> Y.Map("accounts") serialization
-- ---------------------------------------------------------------------------

--: Account -> AccountData
local function account_to_wire(acct)
  return {
    id          = acct.id,
    name        = acct.name,
    type        = acct.type,
    code        = acct.code,
    description = acct.description,
    parent      = acct.parent,
  }
end

-- ---------------------------------------------------------------------------
-- Accounts-table persistence across every period currently in SQLite
-- ---------------------------------------------------------------------------

-- Every distinct period_id with at least one row in journal_entries. This is
-- the SQL-level source of truth for "which periods exist" -- deliberately
-- not doc_registry.list_periods (see this file's header comment for why).
--: DbCap -> ({ [number]: string } | nil, string | nil)
local function known_period_ids(db)
  local iter, err = db:query("SELECT DISTINCT period_id FROM journal_entries WHERE period_id IS NOT NULL;")
  if iter == nil then return nil, "bridge: known_period_ids: " .. tostring(err) end
  local out = {} --: { [number]: string }
  while true do
    local pid = iter()
    if pid == nil then break end
    if type(pid) == "string" then out[#out + 1] = pid end
  end
  return out
end

-- Persists `chart` (and, incidentally, the book currency config -- see
-- store.save) without touching any period's journal entries: re-saves each
-- period currently in SQLite using that same period's own freshly-loaded
-- (and therefore unchanged) journal, so store.save's delete+reinsert of that
-- period_id's rows is a no-op for entries while still rewriting the
-- accounts table. If no period has any rows yet, uses a single throwaway
-- period_id with an empty journal -- store.save's delete+reinsert only ever
-- touches rows for the given period_id, and inserts nothing when the
-- journal passed in is empty, so this is safe regardless of which id
-- string is used (and leaves no trace: zero rows are ever inserted under
-- it).
-- Re-saves a single period's own (unchanged) journal alongside `chart` --
-- isolated into its own small function (rather than inlined in the loop
-- below) for the same "whole-function inference instability" reason
-- `post_wire_entry` above is: this function's own destructured multi-return
-- locals (`j`, `pid`) need to never coexist, in the same scope, with the
-- surrounding loop/`known_period_ids` call that also produces one.
--: (DbCap, Chart, string) -> (true | nil, string | nil)
local function resave_period_with_chart(db, chart, pid)
  local j, _chart_ignored, _bc_ignored, lerr = store.load_period(db, pid)
  if j == nil then return nil, "load_period(" .. pid .. "): " .. tostring(lerr) end
  return store.save(db, j, chart, pid)
end

--: (Bridge, Chart) -> (true | nil, string | nil)
local function save_chart_to_all_periods(bridge, chart)
  local db = bridge.db
  local period_ids, perr = known_period_ids(db)
  if period_ids == nil then return nil, "bridge: save_chart_to_all_periods: " .. tostring(perr) end
  if type(period_ids) ~= "table" then return nil, "bridge: internal invariant: known_period_ids returned a non-table" end
  local ids = period_ids --[[: { [number]: string } ]]

  if #ids == 0 then
    local j, jerr = journal.new(bridge.book_currency)
    if j == nil then return nil, "bridge: save_chart_to_all_periods: " .. tostring(jerr) end
    return store.save(db, j, chart, "__bridge_accounts_only__")
  end

  for i = 1, #ids do
    local ok, serr = resave_period_with_chart(db, chart, ids[i])
    if not ok then return nil, "bridge: save_chart_to_all_periods: " .. tostring(serr) end
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Constructor
-- ---------------------------------------------------------------------------

--- Create a new bridge. `opts.db` must already exist (a lib.sqlite handle,
-- or any cap exposing the same execute/query surface -- see lib.platform
-- .caps.db). Ensures the schema exists and the book currency is configured:
-- if the db has no book_currency yet, `opts.book_currency` is required and
-- is persisted via store.save_config; if the db already has one configured,
-- `opts.book_currency` is ignored (the db's existing config wins -- it is
-- the source of truth, not the constructor argument).
--: BridgeOpts -> (Bridge | nil, string | nil)
M.new = function(opts)
  local db = opts.db
  local ok, cerr = store.create_schema(db)
  if not ok then return nil, "bridge.new: " .. tostring(cerr) end

  local existing_currency = store.load_config(db)
  local book_currency = existing_currency
  if book_currency == nil then
    local opt_currency = opts.book_currency
    if type(opt_currency) ~= "string" then
      return nil, "bridge.new: db has no book_currency configured and opts.book_currency was not given"
    end
    local configured, config_err = store.save_config(db, opt_currency)
    if not configured then return nil, "bridge.new: " .. tostring(config_err) end
    book_currency = opt_currency
  end
  if type(book_currency) ~= "string" then
    return nil, "bridge.new: internal invariant: book_currency resolved to a non-string"
  end

  return {
    registry      = opts.registry,
    db            = db,
    sync_manager  = opts.sync_manager,
    book_currency = book_currency,
  }
end

-- ---------------------------------------------------------------------------
-- Local operations: accounts
-- ---------------------------------------------------------------------------

--- Add an account: validates via lib.bookkeeping.account, persists to
-- SQLite (across every period, see save_chart_to_all_periods), mirrors it
-- into the accounts Y.Doc, and notifies the sync manager.
--: (Bridge, { id: string, name: string, type: string, code: string | nil, description: string | nil, parent: string | nil }) -> (Account | nil, string | nil)
M.add_account = function(bridge, account_data)
  local _j, chart, _bc, lerr = store.load(bridge.db)
  if chart == nil then return nil, "bridge.add_account: " .. tostring(lerr) end

  local acct, aerr = account.add_account(chart, account_data)
  if acct == nil then return nil, "bridge.add_account: " .. tostring(aerr) end

  local saved, serr = save_chart_to_all_periods(bridge, chart)
  if not saved then return nil, serr end

  local accounts_doc = doc_registry.accounts_doc(bridge.registry)
  local accounts_map, merr = doc_mod.get_map(accounts_doc, "accounts")
  if accounts_map == nil then return nil, "bridge.add_account: " .. tostring(merr) end
  local wire = account_to_wire(acct)

  --: (unknown) -> nil
  local function apply(txn_raw)
    if type(txn_raw) ~= "table" then error("bridge: transact gave a non-table txn", 2) end
    local txn = txn_raw --[[: Transaction]]
    local set_ok, set_err = map.set(accounts_map, txn, acct.id, wire)
    if not set_ok then error(set_err or "bridge.add_account: map.set failed", 2) end
  end
  local update_bytes, uerr = mutate_doc(accounts_doc, apply)
  if update_bytes == nil then return nil, uerr end

  local notified, nerr = notify_sync(bridge, "accounts", update_bytes)
  if not notified then return nil, nerr end

  return acct
end

--- Update an existing account's mutable fields. See
-- lib.bookkeeping.account.update_account for `changes`' shape (including
-- account.CLEAR for explicitly clearing code/description).
--: (Bridge, string, { name: string | nil, code: unknown, description: unknown, type: string | nil, parent: string | nil }) -> (Account | nil, string | nil)
M.update_account = function(bridge, account_id, changes)
  local _j, chart, _bc, lerr = store.load(bridge.db)
  if chart == nil then return nil, "bridge.update_account: " .. tostring(lerr) end

  local acct, aerr = account.update_account(chart, account_id, changes)
  if acct == nil then return nil, "bridge.update_account: " .. tostring(aerr) end

  local saved, serr = save_chart_to_all_periods(bridge, chart)
  if not saved then return nil, serr end

  local accounts_doc = doc_registry.accounts_doc(bridge.registry)
  local accounts_map, merr = doc_mod.get_map(accounts_doc, "accounts")
  if accounts_map == nil then return nil, "bridge.update_account: " .. tostring(merr) end
  local wire = account_to_wire(acct)

  --: (unknown) -> nil
  local function apply(txn_raw)
    if type(txn_raw) ~= "table" then error("bridge: transact gave a non-table txn", 2) end
    local txn = txn_raw --[[: Transaction]]
    local set_ok, set_err = map.set(accounts_map, txn, account_id, wire)
    if not set_ok then error(set_err or "bridge.update_account: map.set failed", 2) end
  end
  local update_bytes, uerr = mutate_doc(accounts_doc, apply)
  if update_bytes == nil then return nil, uerr end

  local notified, nerr = notify_sync(bridge, "accounts", update_bytes)
  if not notified then return nil, nerr end

  return acct
end

-- True if any journal_lines row anywhere in SQLite (any period) references
-- `account_id` -- account.lua has no dependency on journal.lua by design
-- (see account.delete_account's own comment), so this cross-check is this
-- bridge's job. Shared by M.delete_account (local delete) and
-- M.apply_remote_accounts (remote-delete conflict check) so both enforce
-- the same invariant.
--: (DbCap, string) -> (boolean | nil, string | nil)
local function account_has_journal_references(db, account_id)
  local iter, qerr = db:query("SELECT COUNT(*) FROM journal_lines WHERE account_id = ?;", account_id)
  if iter == nil then return nil, tostring(qerr) end
  local count = iter()
  return type(count) == "number" and count > 0
end

--- Delete an account. Fails if lib.bookkeeping.account.delete_account's own
-- invariant fails (the account has children) or if any journal_lines row
-- anywhere in SQLite (any period) still references it.
--: (Bridge, string) -> (true | nil, string | nil)
M.delete_account = function(bridge, account_id)
  local db = bridge.db
  local referenced, rerr = account_has_journal_references(db, account_id)
  if referenced == nil then return nil, "bridge.delete_account: " .. tostring(rerr) end
  if referenced then
    return nil, "bridge.delete_account: account " .. account_id .. " is referenced by one or more journal lines"
  end

  local _j, chart, _bc, lerr = store.load(db)
  if chart == nil then return nil, "bridge.delete_account: " .. tostring(lerr) end

  local ok, derr = account.delete_account(chart, account_id)
  if not ok then return nil, "bridge.delete_account: " .. tostring(derr) end

  local saved, serr = save_chart_to_all_periods(bridge, chart)
  if not saved then return nil, serr end

  local accounts_doc = doc_registry.accounts_doc(bridge.registry)
  local accounts_map, merr = doc_mod.get_map(accounts_doc, "accounts")
  if accounts_map == nil then return nil, "bridge.delete_account: " .. tostring(merr) end

  --: (unknown) -> nil
  local function apply(txn_raw)
    if type(txn_raw) ~= "table" then error("bridge: transact gave a non-table txn", 2) end
    local txn = txn_raw --[[: Transaction]]
    local del_ok, del_err = map.delete(accounts_map, txn, account_id)
    if not del_ok then error(del_err or "bridge.delete_account: map.delete failed", 2) end
  end
  local update_bytes, uerr = mutate_doc(accounts_doc, apply)
  if update_bytes == nil then return nil, uerr end

  return notify_sync(bridge, "accounts", update_bytes)
end

-- ---------------------------------------------------------------------------
-- Local operations: journal entries
-- ---------------------------------------------------------------------------

-- WireLine[] -> lib.bookkeeping.journal line_input[] (money.new re-attaches
-- the currency to the line's plain amount_minor integer -- see
-- lib/platform/apps/finance/doc_registry.lua's header comment on why the
-- wire shape is flat rather than a nested money_value).
--: { [number]: WireLine } -> ({ [number]: { account: string, amount: MoneyValue, rate: number | nil } } | nil, string | nil)
local function wire_lines_to_line_inputs(lines)
  local out = {} --: { [number]: { account: string, amount: MoneyValue, rate: number | nil } }
  for i = 1, #lines do
    local line = lines[i]
    local amount, merr = money.new(line.amount, line.currency)
    if amount == nil then return nil, "bridge: line " .. i .. ": " .. tostring(merr) end
    out[i] = { account = line.account_id, amount = amount, rate = line.rate }
  end
  return out
end

-- True if `id` doesn't (yet) name a posted entry in `j` -- `id == nil` (no
-- id assigned yet) always counts as new. Isolated into its own function
-- rather than `wire_id == nil or journal.get(j, wire_id) == nil` inline:
-- confirmed by minimal repro that short-circuit "or" does not narrow
-- `wire_id` to non-nil for its own right-hand operand in this checker, even
-- for a plain local (not a field access) -- an early return per branch
-- avoids ever needing that narrow.
--: (BkJournal, string | nil) -> boolean
local function entry_is_new(j, id)
  if id == nil then return true end
  return journal.get(j, id) == nil
end

-- TYPECHECKER WORKAROUND: the natural code inlines this directly in
-- M.post_entry/M.apply_remote_entries (both already have several other
-- multi-return calls in scope: store.load_period, store.save_period,
-- doc_registry.get_or_create_period, ...). Confirmed this is the same
-- "whole-function inference instability" class already logged in TODO.md
-- for lib/bookkeeping/store.lua's read_book_currency/build_journal_from_rows
-- split: `wire_lines_to_line_inputs`'s destructured `line_inputs` local
-- reverts to its source call's full 2-tuple return type by the time it's
-- used in `journal.post`'s `lines` field, even after nil + type(x)=="table"
-- guards, whenever this logic shares a function scope with the caller's
-- other calls. Isolated into its own small function (line_inputs' entire
-- lifecycle -- call, guard, use -- never coexists with unrelated code in a
-- bigger scope) resolves it, matching store.lua's own precedent exactly.
--: (BkJournal, Chart, WireEntry) -> (JournalEntry | nil, string | nil)
local function post_wire_entry(j, chart, entry_data)
  local line_inputs, lierr = wire_lines_to_line_inputs(entry_data.lines)
  if line_inputs == nil then return nil, lierr end
  if type(line_inputs) ~= "table" then return nil, "bridge: internal invariant: bad line_inputs" end
  return journal.post(j, chart, {
    id = entry_data.id, date = entry_data.date, description = entry_data.description, lines = line_inputs,
  })
end

-- JournalEntry -> WireEntry (flattening each line's money_value back into
-- the wire's flat account_id/amount/currency/rate fields).
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
  return { id = entry.id, date = entry.date, description = entry.description, lines = lines }
end

-- Appends `wire_entry` to period doc `d`'s "entries" Y.Array and returns the
-- encoded update bytes.
--: (Doc, WireEntry) -> (string | nil, string | nil)
local function append_entry_to_doc(d, wire_entry)
  local entries_array, aerr = doc_mod.get_array(d, "entries")
  if entries_array == nil then return nil, "bridge: " .. tostring(aerr) end

  --: (unknown) -> nil
  local function apply(txn_raw)
    if type(txn_raw) ~= "table" then error("bridge: transact gave a non-table txn", 2) end
    local txn = txn_raw --[[: Transaction]]
    local at_end = math.floor(arr.length(entries_array))
    local ins_ok, ins_err = arr.insert(entries_array, txn, at_end, { wire_entry })
    if not ins_ok then error(ins_err or "bridge: array.insert failed", 2) end
  end
  return mutate_doc(d, apply)
end

--- Post a new journal entry. `entry_data` is the wire shape documented in
-- lib/platform/apps/finance/doc_registry.lua's header comment: { id?, date,
-- description, lines: [{ account_id, amount (signed amount_minor), currency,
-- rate? }] }.
--: (Bridge, string, WireEntry) -> (JournalEntry | nil, string | nil)
M.post_entry = function(bridge, period_id, entry_data)
  local j, chart, _bc, lerr = store.load_period(bridge.db, period_id)
  if j == nil then return nil, "bridge.post_entry: " .. tostring(lerr) end
  if chart == nil then return nil, "bridge.post_entry: " .. tostring(lerr) end

  local entry, perr = post_wire_entry(j, chart, entry_data)
  if entry == nil then return nil, "bridge.post_entry: " .. tostring(perr) end

  local saved, serr = store.save_period(bridge.db, j, chart, period_id)
  if not saved then return nil, "bridge.post_entry: " .. tostring(serr) end

  local d, derr = doc_registry.get_or_create_period(bridge.registry, period_id)
  if d == nil then return nil, "bridge.post_entry: " .. tostring(derr) end

  local update_bytes, uerr = append_entry_to_doc(d, entry_to_wire(entry))
  if update_bytes == nil then return nil, uerr end

  local notified, nerr = notify_sync(bridge, period_id, update_bytes)
  if not notified then return nil, nerr end

  return entry
end

--- Void a posted entry: posts a reversing entry dated `void_date` (see
-- lib.bookkeeping.journal.void_entry) and mirrors that reversing entry into
-- the period Y.Doc the same way M.post_entry does (voiding never mutates or
-- removes the original entry).
--: (Bridge, string, string, string) -> (JournalEntry | nil, string | nil)
M.void_entry = function(bridge, period_id, entry_id, void_date)
  local j, chart, _bc, lerr = store.load_period(bridge.db, period_id)
  if j == nil then return nil, "bridge.void_entry: " .. tostring(lerr) end
  if chart == nil then return nil, "bridge.void_entry: " .. tostring(lerr) end

  local reversing, verr = journal.void_entry(j, chart, entry_id, void_date)
  if reversing == nil then return nil, "bridge.void_entry: " .. tostring(verr) end

  local saved, serr = store.save_period(bridge.db, j, chart, period_id)
  if not saved then return nil, "bridge.void_entry: " .. tostring(serr) end

  local d, derr = doc_registry.get_or_create_period(bridge.registry, period_id)
  if d == nil then return nil, "bridge.void_entry: " .. tostring(derr) end

  local update_bytes, uerr = append_entry_to_doc(d, entry_to_wire(reversing))
  if update_bytes == nil then return nil, uerr end

  local notified, nerr = notify_sync(bridge, period_id, update_bytes)
  if not notified then return nil, nerr end

  return reversing
end

--- Delete a posted entry outright (no reversing entry) -- see
-- lib.bookkeeping.journal.delete_entry's own comment: this exists for CRDT
-- sync conflict resolution as much as for local use. Removes the matching
-- entry from the period Y.Doc's "entries" array by scanning for its id (Y
-- .Array has no keyed lookup); if the Y.Doc doesn't currently have a
-- matching entry (already absent, e.g. a prior partial sync), the SQLite
-- delete still stands -- SQLite is the source of truth -- and this returns
-- success without modifying the Y.Doc further.
--: (Bridge, string, string) -> (true | nil, string | nil)
M.delete_entry = function(bridge, period_id, entry_id)
  local j, chart, _bc, lerr = store.load_period(bridge.db, period_id)
  if j == nil then return nil, "bridge.delete_entry: " .. tostring(lerr) end
  if chart == nil then return nil, "bridge.delete_entry: " .. tostring(lerr) end

  local ok, derr = journal.delete_entry(j, entry_id)
  if not ok then return nil, "bridge.delete_entry: " .. tostring(derr) end

  local saved, serr = store.save_period(bridge.db, j, chart, period_id)
  if not saved then return nil, "bridge.delete_entry: " .. tostring(serr) end

  local d, drerr = doc_registry.get_or_create_period(bridge.registry, period_id)
  if d == nil then return nil, "bridge.delete_entry: " .. tostring(drerr) end
  local entries_array, aerr = doc_mod.get_array(d, "entries")
  if entries_array == nil then return nil, "bridge.delete_entry: " .. tostring(aerr) end

  -- TYPECHECKER WORKAROUND: `array.to_array`'s declared return is
  -- `unknown[]`; taking `#` of that bare declared shape is rejected
  -- ("cannot take length of type unknown") even though a concrete
  -- `{ [number]: unknown }` (the same shape, restated) supports `#` fine --
  -- confirmed by minimal repro. See TODO.md; drop this cast once `unknown[]`
  -- supports `#` directly.
  local current = arr.to_array(entries_array) --[[: { [number]: unknown } ]]
  local found_index = nil --: integer | nil
  for i = 1, #current do
    local e = current[i]
    if type(e) == "table" then
      local et = e --[[: { id: unknown } ]]
      local et_id = et.id
      if et_id == entry_id then
        found_index = i - 1  -- array.lua uses 0-based visible positions
        break
      end
    end
  end
  if found_index == nil then return true end

  --: (unknown) -> nil
  local function apply(txn_raw)
    if type(txn_raw) ~= "table" then error("bridge: transact gave a non-table txn", 2) end
    local txn = txn_raw --[[: Transaction]]
    local del_ok, del_err = arr.delete(entries_array, txn, found_index, 1)
    if not del_ok then error(del_err or "bridge.delete_entry: array.delete failed", 2) end
  end
  local update_bytes, uerr = mutate_doc(d, apply)
  if update_bytes == nil then return nil, uerr end

  return notify_sync(bridge, period_id, update_bytes)
end

-- ---------------------------------------------------------------------------
-- Remote sync: yjs change -> validate -> SQLite
-- ---------------------------------------------------------------------------

--: unknown -> AccountData | nil
local function account_data_from_wire(v)
  if type(v) ~= "table" then return nil end
  local t = v --[[: { id: unknown, name: unknown, type: unknown, code: unknown, description: unknown, parent: unknown } ]]
  local id_ = t.id
  local name_ = t.name
  local type_ = t.type
  if type(id_) ~= "string" or type(name_) ~= "string" or type(type_) ~= "string" then return nil end
  local code_ = t.code
  local description_ = t.description
  local parent_ = t.parent
  local code = type(code_) == "string" and code_ or nil
  local description = type(description_) == "string" and description_ or nil
  local parent = type(parent_) == "string" and parent_ or nil
  return { id = id_, name = name_, type = type_, code = code, description = description, parent = parent }
end

--- Apply the accounts Y.Map's current state to SQLite: any account present
-- remotely but not locally is added; any account present in both with
-- differing fields is updated; any account present locally but not
-- remotely is deleted IF that's safe (no children, no journal references --
-- the same invariants M.delete_account itself enforces), otherwise the
-- removal is logged as a conflict and the local account is left in place
-- (never silently dropped). Every invariant violation (malformed remote
-- data, an add/update/delete that lib.bookkeeping rejects) is likewise
-- logged as a conflict rather than applied.
--: (Bridge, Doc) -> ({ [number]: string } | nil, string | nil)
M.apply_remote_accounts = function(bridge, accounts_doc)
  local _j, chart, _bc, lerr = store.load(bridge.db)
  if chart == nil then return nil, "bridge.apply_remote_accounts: " .. tostring(lerr) end

  local accounts_map, merr = doc_mod.get_map(accounts_doc, "accounts")
  if accounts_map == nil then return nil, "bridge.apply_remote_accounts: " .. tostring(merr) end

  local conflicts = {} --: { [number]: string }
  local remote_ids = {} --: { [string]: boolean }
  local changed = false

  for remote_id, raw in map.entries(accounts_map) do
    if type(remote_id) == "string" then
      remote_ids[remote_id] = true
      local wire = account_data_from_wire(raw)
      if wire == nil then
        conflicts[#conflicts + 1] = "malformed remote account data for id " .. remote_id
      else
        local existing = account.get(chart, remote_id)
        local wire_name = wire.name
        local wire_type = wire.type
        local wire_code = wire.code
        local wire_description = wire.description
        if existing == nil then
          local acct, aerr = account.add_account(chart, wire)
          if acct == nil then
            conflicts[#conflicts + 1] = "remote add_account(" .. remote_id .. ") rejected: " .. tostring(aerr)
          else
            changed = true
          end
        else
          local ex = existing
          if ex.name ~= wire_name or ex.type ~= wire_type or ex.code ~= wire_code or ex.description ~= wire_description then
            local acct, uerr = account.update_account(chart, remote_id, {
              name        = wire_name,
              type        = wire_type,
              code        = wire_code == nil and account.CLEAR or wire_code,
              description = wire_description == nil and account.CLEAR or wire_description,
              parent      = nil,
            })
            if acct == nil then
              conflicts[#conflicts + 1] = "remote update_account(" .. remote_id .. ") rejected: " .. tostring(uerr)
            else
              changed = true
            end
          end
        end
      end
    end
  end

  local locals = account.list(chart)
  for i = 1, #locals do
    local acct = locals[i]
    if not remote_ids[acct.id] then
      local referenced, rerr = account_has_journal_references(bridge.db, acct.id)
      if referenced == nil then
        conflicts[#conflicts + 1] = "remote delete of account " .. acct.id .. " skipped (" .. tostring(rerr) .. ")"
      elseif referenced then
        conflicts[#conflicts + 1] = "remote delete of account " .. acct.id .. " skipped (referenced by one or more journal lines)"
      else
        local ok, derr = account.delete_account(chart, acct.id)
        if not ok then
          conflicts[#conflicts + 1] = "remote delete of account " .. acct.id .. " skipped (" .. tostring(derr) .. ")"
        else
          changed = true
        end
      end
    end
  end

  if changed then
    local saved, serr = save_chart_to_all_periods(bridge, chart)
    if not saved then return nil, serr end
  end

  return conflicts
end

--: unknown -> WireEntry | nil
local function wire_entry_from_raw(v)
  if type(v) ~= "table" then return nil end
  local t = v --[[: { id: unknown, date: unknown, description: unknown, lines: unknown } ]]
  local id_ = t.id
  local date_ = t.date
  local description_ = t.description
  local lines_ = t.lines
  if type(id_) ~= "string" or type(date_) ~= "string" or type(description_) ~= "string" then return nil end
  if type(lines_) ~= "table" then return nil end
  local raw_lines = lines_ --[[: { [number]: unknown } ]]
  local lines = {} --: { [number]: WireLine }
  for i = 1, #raw_lines do
    local rl = raw_lines[i]
    if type(rl) ~= "table" then return nil end
    local lt = rl --[[: { account_id: unknown, amount: unknown, currency: unknown, rate: unknown } ]]
    local account_id_ = lt.account_id
    local amount_ = lt.amount
    local currency_ = lt.currency
    local rate_ = lt.rate
    if type(account_id_) ~= "string" or type(amount_) ~= "number" or type(currency_) ~= "string" then
      return nil
    end
    local rate = type(rate_) == "number" and rate_ or nil
    lines[i] = { account_id = account_id_, amount = amount_, currency = currency_, rate = rate }
  end
  return { id = id_, date = date_, description = description_, lines = lines }
end

--- Apply a period Y.Array's current state to SQLite: any entry present
-- remotely but not locally is posted (via journal.post, so it gets the same
-- balance/account-existence validation any local post_entry gets); any
-- entry present locally but not remotely is removed via
-- journal.delete_entry (its own documented purpose -- see that function's
-- comment). Every invariant violation is logged as a conflict rather than
-- applied.
--: (Bridge, string, Doc) -> ({ [number]: string } | nil, string | nil)
M.apply_remote_entries = function(bridge, period_id, period_doc)
  local j, chart, _bc, lerr = store.load_period(bridge.db, period_id)
  if j == nil then return nil, "bridge.apply_remote_entries: " .. tostring(lerr) end
  if chart == nil then return nil, "bridge.apply_remote_entries: " .. tostring(lerr) end

  local entries_array, aerr = doc_mod.get_array(period_doc, "entries")
  if entries_array == nil then return nil, "bridge.apply_remote_entries: " .. tostring(aerr) end

  local conflicts = {} --: { [number]: string }
  local remote_ids = {} --: { [string]: boolean }
  local changed = false

  -- See M.delete_entry's matching comment on why `array.to_array`'s
  -- `unknown[]` needs this cast before `#` works on it.
  local raw_entries = arr.to_array(entries_array) --[[: { [number]: unknown } ]]
  for i = 1, #raw_entries do
    local wire = wire_entry_from_raw(raw_entries[i])
    if wire == nil then
      conflicts[#conflicts + 1] = "malformed remote entry at index " .. i
    else
      local wire_id = wire.id
      remote_ids[wire_id or ""] = true
      if entry_is_new(j, wire_id) then
        local entry, perr = post_wire_entry(j, chart, wire)
        if entry == nil then
          conflicts[#conflicts + 1] = "remote entry " .. tostring(wire_id) .. " rejected: " .. tostring(perr)
        else
          changed = true
        end
      end
    end
  end

  local locals = journal.list(j)
  for i = 1, #locals do
    local entry = locals[i]
    if not remote_ids[entry.id] then
      local ok, derr = journal.delete_entry(j, entry.id)
      if not ok then
        conflicts[#conflicts + 1] = "remote delete of entry " .. entry.id .. " skipped (" .. tostring(derr) .. ")"
      else
        changed = true
      end
    end
  end

  if changed then
    local saved, serr = store.save_period(bridge.db, j, chart, period_id)
    if not saved then return nil, serr end
  end

  return conflicts
end

-- ---------------------------------------------------------------------------
-- Queries: SQLite only, no yjs involved
-- ---------------------------------------------------------------------------

--- The full chart of accounts. See lib.bookkeeping.account.list.
--: Bridge -> (unknown | nil, string | nil)
M.list_accounts = function(bridge)
  local _j, chart, _bc, lerr = store.load(bridge.db)
  if chart == nil then return nil, "bridge.list_accounts: " .. tostring(lerr) end
  return account.list(chart)
end

--- The full ledger (all periods): per-account, per-currency transaction
-- history with running balances. See lib.bookkeeping.ledger.build.
--: Bridge -> (unknown | nil, string | nil)
M.get_ledger = function(bridge)
  local j, _chart, _bc, lerr = store.load(bridge.db)
  if j == nil then return nil, "bridge.get_ledger: " .. tostring(lerr) end
  return ledger_mod.build(j)
end

--- Every posted entry across every period currently in SQLite, each tagged
-- with the period_id it was posted under (WireEntry has no period_id field
-- of its own -- see this file's header comment on why period membership
-- lives only as a SQLite column, never on the in-memory entry record -- so
-- any caller needing "which period is entry X in", e.g. to call
-- M.void_entry/M.delete_entry, has to get it from here rather than from
-- M.get_ledger, whose ledger_row shape also carries no period_id). Entries
-- are returned in no particular cross-period order; sort by `date` at the
-- call site if a specific order is required.
--: Bridge -> ({ [number]: { period_id: string, entry: JournalEntry } } | nil, string | nil)
M.list_entries = function(bridge)
  local period_ids, perr = known_period_ids(bridge.db)
  if period_ids == nil then return nil, "bridge.list_entries: " .. tostring(perr) end
  if type(period_ids) ~= "table" then return nil, "bridge.list_entries: internal invariant: known_period_ids returned a non-table" end
  local ids = period_ids --[[: { [number]: string } ]]

  local out = {} --: { [number]: { period_id: string, entry: JournalEntry } }
  for i = 1, #ids do
    local pid = ids[i]
    local j, _chart, _bc, lerr = store.load_period(bridge.db, pid)
    if j == nil then return nil, "bridge.list_entries: load_period(" .. pid .. "): " .. tostring(lerr) end
    local entries = journal.list(j)
    for k = 1, #entries do
      out[#out + 1] = { period_id = pid, entry = entries[k] }
    end
  end
  return out
end

--- The trial balance (all periods). See lib.bookkeeping.trial_balance.build.
--: Bridge -> (unknown | nil, string | nil)
M.get_trial_balance = function(bridge)
  local j, chart, _bc, lerr = store.load(bridge.db)
  if j == nil then return nil, "bridge.get_trial_balance: " .. tostring(lerr) end
  if chart == nil then return nil, "bridge.get_trial_balance: " .. tostring(lerr) end
  return trial_balance.build(j, chart)
end

--- Income statement for [start_date, end_date] (all periods -- date range
-- alone determines inclusion). See lib.bookkeeping.report.income_statement.
--: (Bridge, string, string) -> (unknown | nil, string | nil)
M.get_income_statement = function(bridge, start_date, end_date)
  local j, chart, _bc, lerr = store.load(bridge.db)
  if j == nil then return nil, "bridge.get_income_statement: " .. tostring(lerr) end
  if chart == nil then return nil, "bridge.get_income_statement: " .. tostring(lerr) end
  return report.income_statement(j, chart, { start_date = start_date, end_date = end_date })
end

--- Balance sheet as of `as_of_date` (all periods up to that date). See
-- lib.bookkeeping.report.balance_sheet.
--: (Bridge, string) -> (unknown | nil, string | nil)
M.get_balance_sheet = function(bridge, as_of_date)
  local j, chart, _bc, lerr = store.load(bridge.db)
  if j == nil then return nil, "bridge.get_balance_sheet: " .. tostring(lerr) end
  if chart == nil then return nil, "bridge.get_balance_sheet: " .. tostring(lerr) end
  return report.balance_sheet(j, chart, { as_of = as_of_date })
end

return M
