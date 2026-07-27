if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

-- Top-level document container: a client id, a StructStore, and a set of
-- named root-level shared types. Mirrors yjs's Doc, scoped to what this
-- core data model needs -- no subdocs, no gc/observe config, no encoding.
--
-- SCOPE: get_text/get_array/get_map return bare SharedType records (see
-- shared_type.lua), not rich Y.Text/Y.Array/Y.Map wrappers -- those are a
-- separate library layered on top of this data model (see TODO.md).

local struct_store = require("lib.y_crdt.struct_store")
local transaction = require("lib.y_crdt.transaction")
local shared_type = require("lib.y_crdt.shared_type")

local M = {}

-- StructStore is non-recursive, so `typeof` captures it exactly (see
-- struct_store.lua/integrate.lua for the same reasoning).
local sample_store = struct_store.new()
--:: StructStore = typeof sample_store
local sample_shared = shared_type.new("text")
--:: SharedType = typeof sample_shared

-- `gc` mirrors yjs's `Doc({gc: true})` option (default true): whether
-- `M.transact`'s post-transaction cleanup replaces deleted items' content
-- with a bare length placeholder. See transaction.lua's `M.cleanup`.
--:: Doc = { client_id: number, store: StructStore, share: { [string]: SharedType }, clock: number, gc: boolean }
--:: DocOpts = { client_id?: number, gc?: boolean }

-- Client ids only need to be distinct with high probability across
-- replicas (yjs draws them from `lib0/random#uint32`); this uses Lua's PRNG
-- rather than a cryptographic source since collision resistance at that
-- strength is not this module's job. Caller can always pass opts.client_id
-- explicitly (e.g. in tests, or for a server assigning ids deterministically).
--: () -> number
local function random_client_id()
  return math.random(0, 2147483647)
end

--: (opts: DocOpts | nil) -> Doc
function M.new(opts)
  local o = opts or {}
  local gc_enabled = o.gc
  if gc_enabled == nil then gc_enabled = true end
  return {
    client_id = o.client_id or random_client_id(),
    store = struct_store.new(),
    share = {},
    clock = 0,
    gc = gc_enabled,
  } --[[: Doc]]
end

--: (d: Doc, name: string, type_name: string) -> SharedType | (nil, string)
local function get_or_create(d, name, type_name)
  local existing = d.share[name]
  if existing ~= nil then
    if existing.type_name ~= type_name then
      return nil, "shared type '" .. name .. "' already exists as '" .. existing.type_name .. "', requested '" .. type_name .. "'"
    end
    return existing
  end
  local t = shared_type.new(type_name)
  d.share[name] = t
  return t
end

--: (d: Doc, name: string) -> SharedType | (nil, string)
function M.get_text(d, name) return get_or_create(d, name, "text") end

--: (d: Doc, name: string) -> SharedType | (nil, string)
function M.get_array(d, name) return get_or_create(d, name, "array") end

--: (d: Doc, name: string) -> SharedType | (nil, string)
function M.get_map(d, name) return get_or_create(d, name, "map") end

-- Runs `fn(txn)` inside a fresh Transaction, then runs post-transaction
-- cleanup (item compaction + GC of deleted content -- see
-- transaction.lua's `M.cleanup`). Returns the Transaction (so the caller
-- can inspect new_items/deleted_items) on success, or (nil, errmsg) if `fn`
-- raised (a Lua `error`, not the library's data-error convention -- `fn` is
-- caller-supplied application code, not a library function).
--
-- SCOPE: does not yet emit an update event after `fn` returns -- needs an
-- observer/event system not built in this task. See TODO.md.
--: (d: Doc, fn: (txn: unknown) -> nil) -> unknown | (nil, string)
function M.transact(d, fn)
  local txn = transaction.new(d)
  local ok, err = pcall(fn, txn)
  if not ok then return nil, tostring(err) end
  transaction.cleanup(txn, d.store, d.gc)
  return txn
end

return M
