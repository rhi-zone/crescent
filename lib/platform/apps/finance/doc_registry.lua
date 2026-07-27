if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Y.Doc registry for the finance app: one accounts doc (chart of accounts,
-- period index, app config) plus one Y.Doc per user-defined period
-- (journal entries for that period). See docs/overview.md and
-- lib/platform/apps/finance/bridge.lua for how this fits into the
-- SQLite-is-source-of-truth / yjs-is-sync-transport split.
--
-- Accounts doc structure (three root maps, created up front by M.new):
--   Y.Map("accounts") -- account id -> serialized account data (plain table)
--   Y.Map("periods")  -- period id -> { start_date, end_date }
--   Y.Map("config")   -- app-level config (book_currency, active_period, ...)
--
-- Period doc structure (one root array, created by M.get_or_create_period):
--   Y.Array("entries") -- journal entries for that period, each a plain
--     table { id, date, description, lines: [{ account_id, amount, currency, rate }] }
--     (amount is the line's signed amount_minor, matching lib.money's
--     integer-minor-units convention; the nested lib.money object itself is
--     never stored in the doc -- lib.platform.apps.finance.bridge is what
--     translates between this flat wire shape and lib.bookkeeping's
--     money_value tables).

local doc_mod = require("lib.y_crdt.doc")
local map     = require("lib.y_crdt.map")

local M = {}

-- Doc is non-recursive (a client id, a StructStore, and a name->SharedType
-- map), so `typeof` captures it exactly -- same reasoning as
-- lib/y_crdt/sync.lua's own `Doc = typeof sample_doc`.
local sample_doc = doc_mod.new({ client_id = 0 })
--:: Doc = typeof sample_doc
-- SharedType is non-recursive from this file's point of view (it never
-- touches Item internals directly, only map.lua's public get/set/has/entries
-- API), so `typeof` captures it exactly too -- same reasoning doc.lua itself
-- uses for StructStore.
local sample_map = doc_mod.get_map(doc_mod.new({ client_id = 0 }), "sample")
--:: MapType = typeof sample_map

-- Restated Transaction/Item/Content shape (mirrors lib/y_crdt/map.lua's own
-- header restatement verbatim -- see that file's comment for why this can't
-- be a non-duplicating cross-module reference: `typeof` doesn't survive
-- `require()`, and these types are self-referential so `typeof` couldn't
-- capture them from a sample value even in-file). Needed so
-- `transact_set_in_map` below can narrow the `unknown` transaction handle
-- `lib.y_crdt.doc`'s `M.transact` callback receives into the concrete shape
-- `map.set` requires -- see that function's TYPECHECKER WORKAROUND comment.
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
--:: StructStore = { clients: { [number]: unknown } }
--:: Transaction = { doc: { client_id: number, store: StructStore, clock: number }, new_items: Item[], deleted_items: Item[], merge_structs: Item[] }

--:: PeriodMeta = { start_date: string, end_date: string }
--:: PeriodEntry = { id: string, start_date: string, end_date: string }
--:: Registry = { client_id: number | nil, accounts_doc: Doc, periods: { [string]: Doc } }
--:: RegistryOpts = { client_id: number | nil }

-- Builds a lib.y_crdt.doc `DocOpts` table. Needed because DocOpts declares
-- `client_id` as an *optional* field (`client_id?: number`), which a table
-- literal assigning it a `number | nil`-typed value does not satisfy --
-- confirmed by minimal repro: an optional field accepts the field being
-- absent, not the field being present with a nilable value. Omitting the
-- key entirely (rather than assigning it `nil`) is the only way to satisfy
-- an optional field from a value that might itself be nil.
--: (number | nil) -> { client_id?: number }
local function doc_opts(client_id)
  if client_id == nil then return {} end
  return { client_id = client_id }
end

-- get_root_map(d, name) -> the root Y.Map `name` on doc `d`. M.new/
-- M.get_or_create_period always create "accounts"/"periods"/"config"/
-- "entries" as maps (never any other type_name) before this module hands
-- the doc back to a caller, so `doc_mod.get_map`'s "already exists as a
-- different type" failure mode is unreachable here -- callers of this
-- module have no way to register a root under one of these reserved names
-- as a different shared-type kind. Throws on that unreachable case instead
-- of threading a `(nil, string)` error arm through every call site, matching
-- this codebase's existing precedent for "the failure branch cannot happen
-- given how this module already constructed its own state" (see e.g.
-- lib/y_crdt/array.lua's find_pos/insert_item).
--: (Doc, string) -> MapType
local function get_root_map(d, name)
  local m, err = doc_mod.get_map(d, name)
  if m == nil then
    error("doc_registry: internal invariant: root '" .. name .. "' is not a map: " .. tostring(err), 2)
  end
  return m
end

-- TYPECHECKER WORKAROUND: the natural code at each of this file's two
-- `map.set`-under-transaction call sites (M.add_period, M.set_active_period)
-- is an inline `doc_mod.transact(d, function(txn) ... map.set(m, txn, ...)
-- ... end)` closure with an upvalue-captured result, matching
-- lib/y_crdt/map_test.lua's own established pattern for this exact call
-- shape. Confirmed via extensive minimal-repro bisection that this
-- reliably fails to typecheck whenever the `d` passed as `doc_mod.transact`'s
-- first argument is itself a function parameter (or derived from one, e.g.
-- `registry.accounts_doc`) rather than a value freshly constructed by a
-- `doc_mod.new(...)` call in the same local scope -- inline closures over a
-- fresh local (the shape every test in lib/y_crdt/map_test.lua/array_test.lua
-- uses) infer correctly; the identical closure body over a parameter-derived
-- `d` gets its `txn` parameter pinned to the concrete Transaction record
-- (from internal usage) which then fails to satisfy `doc_mod.transact`'s
-- own declared callback type `(unknown) -> nil` (a function requiring a
-- concrete input can't be passed where one accepting `unknown` is
-- expected). This reproduces regardless of whether the enclosing function
-- carries an explicit `--:` signature, whether `d` is cast to `Doc`
-- immediately, or whether the closure captures its result via an upvalue vs.
-- raising a Lua error -- i.e. it is not any of the other several
-- "whole-function/whole-file inference instability" cases already logged in
-- TODO.md, though it looks like the same general class (unrelated code shape
-- perturbing inference of a distant, structurally-unrelated value). Every
-- function in this module that needs a transaction receives its Doc via a
-- Registry field, so the "fresh local" shape that avoids the bug is not
-- available here.
--
-- What resolved it: factoring the `map.set`-under-transaction operation into
-- this single shared helper, where the transact callback is a *named local
-- function* (`apply`, not an inline closure passed directly as the
-- argument expression) whose parameter is explicitly annotated `unknown`
-- (matching `doc_mod.transact`'s own declared callback type exactly, so no
-- inference pinning occurs), and immediately narrowed via the
-- `type(txn_raw) ~= "table"` runtime guard + checked cast to `Transaction`
-- that this codebase's established precedent already uses for "unknown must
-- become a concrete record" (see map.lua's own `M.set`/`M.delete` write-ups).
-- `d` genuinely cannot fail this guard (a real `doc_mod.transact` call
-- always constructs a Transaction), so the guard's `error()` branch is
-- unreachable in practice, mirroring lib/y_crdt/array.lua's
-- insert_item/delete_item precedent for "this failure mode cannot actually
-- happen at this call site." See TODO.md; collapse back to an inline
-- closure with upvalue capture once this inference gap is root-caused.
--: (Doc, MapType, string, unknown) -> (true | nil, string | nil)
local function transact_set_in_map(d, m, key, value)
  --: (unknown) -> nil
  local function apply(txn_raw)
    if type(txn_raw) ~= "table" then
      error("doc_registry: internal invariant: doc_mod.transact gave a non-table transaction", 2)
    end
    local txn = txn_raw --[[: Transaction]]
    local ok, err = map.set(m, txn, key, value)
    if not ok then error(err or "doc_registry: map.set failed", 2) end
  end

  local txn_result, terr = doc_mod.transact(d, apply)
  if txn_result == nil then
    if terr == nil then return nil, "doc_registry: transact failed with no error message" end
    if type(terr) ~= "string" then return nil, "doc_registry: transact failed with a non-string error" end
    return nil, terr
  end
  return true
end

--- Create a new registry: constructs the accounts doc (with its three root
-- maps already present) and an empty period-doc table. `opts.client_id`, if
-- given, is used both for the accounts doc and every period doc this
-- registry creates later (matching yjs convention: one client id per
-- replica, shared across that replica's docs).
--: (RegistryOpts | nil) -> Registry
M.new = function(opts)
  local o = opts or {}
  local accounts_doc = doc_mod.new(doc_opts(o.client_id))
  get_root_map(accounts_doc, "accounts")
  get_root_map(accounts_doc, "periods")
  get_root_map(accounts_doc, "config")
  return {
    client_id    = o.client_id,
    accounts_doc = accounts_doc,
    periods      = {},
  }
end

--- The accounts Y.Doc. Always exists once M.new has run.
--: Registry -> Doc
M.accounts_doc = function(registry)
  return registry.accounts_doc
end

--- Look up (or lazily create) the Y.Doc for `period_id`. A newly-created
-- period doc always has its "entries" root array present already.
--: (Registry, string) -> (Doc | nil, string | nil)
M.get_or_create_period = function(registry, period_id)
  if type(period_id) ~= "string" or period_id == "" then
    return nil, "doc_registry.get_or_create_period: period_id must be a non-empty string"
  end
  local existing = registry.periods[period_id]
  if existing ~= nil then return existing end

  local d = doc_mod.new(doc_opts(registry.client_id))
  doc_mod.get_array(d, "entries")
  registry.periods[period_id] = d
  return d
end

--- All registered periods (from the accounts doc's "periods" map), in no
-- particular order (Y.Map has no ordering guarantee -- see map.lua's
-- M.entries).
--: Registry -> { [number]: PeriodEntry }
M.list_periods = function(registry)
  local periods_map = get_root_map(registry.accounts_doc, "periods")
  local out = {} --: { [number]: PeriodEntry }
  for period_id, meta in map.entries(periods_map) do
    -- `map.entries`'s iterator is declared `() -> (string, unknown) | nil`;
    -- the `nil` arm (loop end) leaves `period_id` typed `string | nil` here
    -- even though the generic-for protocol never runs this body once the
    -- iterator yields nil. Redundant-at-runtime guard re-establishes `string`.
    if type(period_id) == "string" and type(meta) == "table" then
      local m = meta --[[: { start_date: unknown, end_date: unknown } ]]
      local start_date = m.start_date
      local end_date = m.end_date
      out[#out + 1] = {
        id         = period_id,
        start_date = type(start_date) == "string" and start_date or "",
        end_date   = type(end_date) == "string" and end_date or "",
      }
    end
  end
  return out
end

--- Register a new period in the accounts doc's "periods" map. Fails if
-- `period_id` is already registered -- this function is add-only, matching
-- lib.bookkeeping.account's add_account precedent of rejecting duplicate
-- ids rather than upserting.
--: (Registry, string, PeriodMeta) -> (true | nil, string | nil)
M.add_period = function(registry, period_id, metadata)
  if type(period_id) ~= "string" or period_id == "" then
    return nil, "doc_registry.add_period: period_id must be a non-empty string"
  end
  if type(metadata.start_date) ~= "string" then
    return nil, "doc_registry.add_period: metadata.start_date must be a string"
  end
  if type(metadata.end_date) ~= "string" then
    return nil, "doc_registry.add_period: metadata.end_date must be a string"
  end

  local periods_map = get_root_map(registry.accounts_doc, "periods")
  if map.has(periods_map, period_id) then
    return nil, "doc_registry.add_period: period already registered: " .. period_id
  end

  return transact_set_in_map(registry.accounts_doc, periods_map, period_id, {
    start_date = metadata.start_date,
    end_date   = metadata.end_date,
  })
end

--- The currently active period id, or nil if none has been set.
--: Registry -> string | nil
M.active_period = function(registry)
  local config_map = get_root_map(registry.accounts_doc, "config")
  local v = map.get(config_map, "active_period")
  if type(v) == "string" then return v end
  return nil
end

--- Set the active period id (stored in the accounts doc's "config" map).
--: (Registry, string) -> (true | nil, string | nil)
M.set_active_period = function(registry, period_id)
  if type(period_id) ~= "string" or period_id == "" then
    return nil, "doc_registry.set_active_period: period_id must be a non-empty string"
  end
  local config_map = get_root_map(registry.accounts_doc, "config")
  return transact_set_in_map(registry.accounts_doc, config_map, "active_period", period_id)
end

return M
