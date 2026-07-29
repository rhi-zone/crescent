if not package.path:find("?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Finance app headless entry point: wires doc_registry + bridge + sync_manager
-- together and exposes the operations tui.lua/dom.lua call.
--
-- Caps: only `db` is required (see manifest.json). The entrypoint reads the
-- sandboxed `caps` global (present only at entrypoint scope -- modules
-- loaded via require never see it, per lib/platform/init.lua's module_env
-- split) and passes caps.db through explicitly rather than letting any
-- downstream module reach for it ambiently.
--
-- Sync is a documented no-op right now: there is no `transport` cap type in
-- lib/platform/init.lua's CAP_FACTORIES yet, so the sync_manager here is
-- constructed with a stub transport whose send() succeeds without doing
-- anything and whose recv() always returns nil. M.sync therefore never
-- actually reaches a peer -- this is a known limitation, not a bug, and the
-- app is fully usable locally without it. Swap no_op_transport for a real
-- transport cap once lib/platform/init.lua grows one.
--
-- book_currency: lib.platform.apps.finance.bridge's own constructor already
-- handles "is this the first run" (store.load_config(db) returns nil) by
-- requiring opts.book_currency and persisting it via store.save_config; if
-- the db already has one configured, bridge.new ignores opts.book_currency
-- and keeps the db's existing value. This module does not duplicate that
-- check -- it just forwards opts.book_currency through.

local doc_registry = require("lib.platform.apps.finance.doc_registry")
local bridge_mod   = require("lib.platform.apps.finance.bridge")
local sync_manager = require("lib.platform.apps.finance.sync_manager")

local M = {}

--:: DbCap = { execute: (self: DbCap, string, ...unknown) -> (boolean | nil, string | nil), query: (self: DbCap, string, ...unknown) -> ((() -> unknown) | nil, string | nil), ... }
--:: AppOpts = { db: DbCap, book_currency?: string, client_id?: number }

-- Registry is non-recursive (same reasoning bridge.lua/sync_manager.lua's own
-- headers give for restating it via typeof rather than duplicating its
-- field list by hand), so it's bound to its own local first (typeof only
-- accepts a bare identifier).
local sample_reg = doc_registry.new({ client_id = 0 })
--:: Registry = typeof sample_reg

-- Restated from lib/platform/apps/finance/bridge.lua's own header (typeof
-- doesn't survive require(), and Bridge isn't exported under a namespace --
-- same reasoning that file's own header gives for restating doc_registry's
-- Registry/Doc). Needed so make_bridge below can be typed to return the
-- concrete Bridge record rather than `unknown` -- a nil-check narrows
-- `Bridge | nil` to `Bridge`, but does not narrow a bare `unknown`.
--:: SyncManagerCap = { broadcast_change: (unknown, string, string) -> (true | nil, string | nil), ... }
--:: Bridge = { registry: Registry, db: DbCap, sync_manager: SyncManagerCap | nil, book_currency: string, _next_entry_id: number }

-- Restated from lib/platform/apps/finance/sync_manager.lua's own header
-- (typeof doesn't survive require(), and this shape is needed to annotate
-- default_policy below -- same reasoning that file's own header gives for
-- restating lib/platform/apps/finance/doc_registry.lua's Registry/Doc).
--:: SyncContext = { periods: { [number]: { id: string, start_date: string, end_date: string } }, active_period: string | nil }

-- Restated from lib/platform/apps/finance/bridge.lua's own header (AccountData,
-- WireLine, WireEntry) and lib/platform/apps/finance/doc_registry.lua's own
-- header (PeriodMeta) -- same "typeof doesn't survive require(), and these
-- names aren't exported under a namespace" reasoning both of those files'
-- own headers already give for restating each other's/their dependencies'
-- shapes. Needed here so the app-API closures below can be typed by the
-- exact shape bridge_mod/doc_registry's functions expect, instead of by
-- `unknown` (which the checker rejects as an argument to a concretely-typed
-- parameter without a runtime narrowing guard).
--:: AccountData = { id: string, name: string, type: string, code: string | nil, description: string | nil, parent: string | nil }
--:: AccountChanges = { name: string | nil, code: unknown, description: unknown, type: string | nil, parent: string | nil }
--:: WireLine = { account_id: string, amount: number, currency: string, rate: number | nil }
--:: WireEntry = { id: string | nil, date: string, description: string, lines: { [number]: WireLine } }
--:: PeriodMeta = { start_date: string, end_date: string }

-- A no-op transport cap: send() succeeds without doing anything, recv()
-- always returns nil. See this file's header comment on why (no `transport`
-- cap type exists in the platform yet).
--: () -> { send: (string, string) -> (true | nil, string | nil), recv: () -> (string | nil, string | nil) }
local function no_op_transport()
  --: (string, string) -> (true | nil, string | nil)
  local function send(_doc_id, _bytes) return true end
  --: () -> (string | nil, string | nil)
  local function recv() return nil end
  return { send = send, recv = recv }
end

-- Default sync policy: sync the accounts doc plus whichever period is
-- currently active. A registry with no active period yet just syncs
-- "accounts" alone.
--: SyncContext -> { [number]: string }
local function default_policy(context)
  local doc_ids = { "accounts" } --: { [number]: string }
  local active = context.active_period
  if type(active) == "string" then
    doc_ids[#doc_ids + 1] = active
  end
  return doc_ids
end

--- Construct the finance app: a doc_registry (client_id from opts.client_id,
-- or a fresh random one), a bridge over opts.db (see this file's header
-- comment on book_currency/first-run handling), and a sync_manager wired
-- with a no-op transport (see this file's header comment on why) and the
-- default policy (sync accounts + active period).
-- Builds the bridge_mod.new opts table. Needed because BridgeOpts declares
-- `book_currency` as an *optional* field (`book_currency?: string`), which a
-- table literal assigning it a `string | nil`-typed value does not satisfy --
-- same reasoning and same fix as lib/platform/apps/finance/doc_registry.lua's
-- own `doc_opts` helper (confirmed there by minimal repro: an optional field
-- accepts the field being absent, not the field being present with a
-- nilable value; omitting the key entirely is the only way to satisfy it
-- from a value that might itself be nil).
--: (Registry, DbCap, string | nil) -> (Bridge | nil, string | nil)
local function make_bridge(registry, db, book_currency)
  if book_currency == nil then
    return bridge_mod.new({ registry = registry, db = db })
  end
  return bridge_mod.new({ registry = registry, db = db, book_currency = book_currency })
end

--: AppOpts -> (unknown | nil, string | nil)
M.new = function(opts)
  local client_id = opts.client_id or math.random(1, 2147483647)
  local registry = doc_registry.new({ client_id = client_id })

  local bridge, berr = make_bridge(registry, opts.db, opts.book_currency)
  if bridge == nil then return nil, "finance.init: " .. tostring(berr) end

  local sm = sync_manager.new({
    registry  = registry,
    transport = no_op_transport(),
    policy    = default_policy,
  })

  --: (AccountData) -> (unknown | nil, string | nil)
  local function add_account(data) return bridge_mod.add_account(bridge, data) end
  --: (string, AccountChanges) -> (unknown | nil, string | nil)
  local function update_account(id, changes) return bridge_mod.update_account(bridge, id, changes) end
  --: (string) -> (true | nil, string | nil)
  local function delete_account(id) return bridge_mod.delete_account(bridge, id) end
  --: () -> (unknown | nil, string | nil)
  local function list_accounts() return bridge_mod.list_accounts(bridge) end

  -- Every posted entry across every period, each tagged with its period_id
  -- (see lib/platform/apps/finance/bridge.lua's own doc comment on
  -- M.list_entries: this is the only way to recover the period_id
  -- void_entry/delete_entry require, since neither WireEntry nor
  -- get_ledger's ledger_row carry it).
  --: () -> (unknown | nil, string | nil)
  local function list_entries() return bridge_mod.list_entries(bridge) end

  --: (string, WireEntry) -> (unknown | nil, string | nil)
  local function post_entry(period_id, data) return bridge_mod.post_entry(bridge, period_id, data) end
  --: (string, string, string) -> (unknown | nil, string | nil)
  local function void_entry(period_id, id, date) return bridge_mod.void_entry(bridge, period_id, id, date) end
  --: (string, string) -> (true | nil, string | nil)
  local function delete_entry(period_id, id) return bridge_mod.delete_entry(bridge, period_id, id) end

  --: () -> { [number]: { id: string, start_date: string, end_date: string } }
  local function list_periods() return doc_registry.list_periods(registry) end
  --: (string, PeriodMeta) -> (true | nil, string | nil)
  local function add_period(id, meta) return doc_registry.add_period(registry, id, meta) end
  --: (string) -> (true | nil, string | nil)
  local function set_active_period(id) return doc_registry.set_active_period(registry, id) end

  --: () -> (unknown | nil, string | nil)
  local function get_ledger() return bridge_mod.get_ledger(bridge) end
  --: () -> (unknown | nil, string | nil)
  local function get_trial_balance() return bridge_mod.get_trial_balance(bridge) end
  --: (string, string) -> (unknown | nil, string | nil)
  local function get_income_statement(s, e) return bridge_mod.get_income_statement(bridge, s, e) end
  --: (string) -> (unknown | nil, string | nil)
  local function get_balance_sheet(d) return bridge_mod.get_balance_sheet(bridge, d) end

  --: () -> ({ [number]: string } | nil, string | nil)
  local function sync() return sync_manager.sync(sm) end

  return {
    add_account = add_account,
    update_account = update_account,
    delete_account = delete_account,
    list_accounts = list_accounts,
    list_entries = list_entries,

    post_entry = post_entry,
    void_entry = void_entry,
    delete_entry = delete_entry,

    list_periods = list_periods,
    add_period = add_period,
    set_active_period = set_active_period,

    get_ledger = get_ledger,
    get_trial_balance = get_trial_balance,
    get_income_statement = get_income_statement,
    get_balance_sheet = get_balance_sheet,

    sync = sync,
  }
end

--- Entrypoint convention this platform's runner (lib/platform/cli.lua,
-- lib/platform/init.lua) expects: the entry file's top-level chunk returns
-- a module with `create(caps, opts?)`. The runner calls it, and (per
-- lib/platform/cli.lua's own run: "entrypoint returned without a handler"
-- is just a note, not an error) a headless app with no `handler` field is
-- valid -- the returned table is used directly instead, not served over
-- HTTP.
-- Builds the AppOpts table passed to M.new. Needed for the same reason
-- make_bridge above needs its own two-branch construction (and
-- lib/platform/apps/finance/doc_registry.lua's `doc_opts` before either of
-- them): `book_currency`/`client_id` are *optional* fields on AppOpts, which
-- a table literal assigning them `string | nil`/`number | nil`-typed values
-- does not satisfy -- omitting the key entirely is the only way to satisfy
-- an optional field from a value that might itself be nil. Four branches
-- (one per combination of the two independently-nilable fields), each a
-- complete literal, rather than incremental field assignment onto a shared
-- table -- matching this codebase's established "each branch is a complete
-- literal" precedent exactly.
--: (DbCap, string | nil, number | nil) -> AppOpts
local function new_app_opts(db, book_currency, client_id)
  if book_currency == nil then
    if client_id == nil then return { db = db } end
    return { db = db, client_id = client_id }
  end
  if client_id == nil then return { db = db, book_currency = book_currency } end
  return { db = db, book_currency = book_currency, client_id = client_id }
end

--: (unknown, unknown) -> (unknown | nil, string | nil)
M.create = function(caps, opts)
  if type(caps) ~= "table" then return nil, "finance.init: caps must be a table" end
  local c = caps --[[: { db: DbCap, ... } ]]
  local o = (type(opts) == "table" and opts or {}) --[[: { book_currency: string | nil, client_id: number | nil } ]]
  return M.new(new_app_opts(c.db, o.book_currency, o.client_id))
end

return M
