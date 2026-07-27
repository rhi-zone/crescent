if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Sync orchestration for the finance app: drives lib/y_crdt/sync.lua's
-- 3-message handshake across every Y.Doc a doc_registry manages (the
-- accounts doc plus one doc per period), under a caller-supplied policy
-- deciding *which* docs to sync and *when*.
--
-- doc_id convention: "accounts" always refers to the accounts doc
-- (doc_registry.accounts_doc); any other doc_id is looked up (and, per
-- doc_registry.get_or_create_period's own semantics, lazily created if
-- absent) as a period id.
--
-- Transport is caps-first: `opts.transport` is injected by the caller, never
-- constructed here, and this module only ever calls `transport.send(doc_id,
-- bytes)` -- it does not read `transport.recv`; feeding inbound bytes to
-- M.on_message is the caller's job (e.g. a websocket/http handler that owns
-- the actual socket), matching this module's public contract (M.new,
-- M.sync, M.set_policy, M.on_message, M.broadcast_change) which lists
-- on_message as the sole inbound path.

local doc_registry = require("lib.platform.apps.finance.doc_registry")
local sync         = require("lib.y_crdt.sync")

local M = {}

-- Doc is non-recursive, so `typeof` captures it exactly -- same reasoning
-- doc_registry.lua itself uses. `typeof` only accepts a bare identifier
-- (confirmed elsewhere in this codebase, e.g. journal.lua's header comment),
-- so the accounts doc is bound to its own local first.
local sample_reg = doc_registry.new({ client_id = 0 })
--:: Registry = typeof sample_reg
local sample_doc = doc_registry.accounts_doc(sample_reg)
--:: Doc = typeof sample_doc

--:: SyncContext = { periods: { [number]: { id: string, start_date: string, end_date: string } }, active_period: string | nil }
--:: PolicyFn = (context: SyncContext) -> { [number]: string }
--:: TransportCap = { send: (string, string) -> (true | nil, string | nil), ... }
--:: ManagerOpts = { registry: Registry, transport: TransportCap, policy?: PolicyFn }
--:: Manager = { registry: Registry, transport: TransportCap, policy: PolicyFn | nil }

-- Default policy: sync nothing unless the caller supplies one. A manager
-- with no policy is inert (M.sync is a no-op) rather than guessing which
-- docs matter -- sync policy is explicitly product-owner-decided (see this
-- app's architecture notes), not something this module should default to a
-- guess like "sync everything."
--: SyncContext -> { [number]: string }
local function no_op_policy(_context)
  return {}
end

-- resolve_doc(registry, doc_id) -> the Doc for `doc_id` ("accounts", or a
-- period id -- lazily created via doc_registry.get_or_create_period if it
-- doesn't exist yet, matching that function's own semantics).
--: (Registry, string) -> (Doc | nil, string | nil)
local function resolve_doc(registry, doc_id)
  if doc_id == "accounts" then
    return doc_registry.accounts_doc(registry)
  end
  return doc_registry.get_or_create_period(registry, doc_id)
end

--- Create a new sync manager. `opts.registry` and `opts.transport` are
-- required caps/state; `opts.policy`, if omitted, defaults to a no-op
-- policy (M.sync then does nothing until M.set_policy installs a real one).
--: (ManagerOpts) -> Manager
M.new = function(opts)
  return {
    registry  = opts.registry,
    transport = opts.transport,
    policy    = opts.policy or no_op_policy,
  }
end

--- Replace the manager's sync policy at runtime.
--: (Manager, PolicyFn) -> nil
M.set_policy = function(manager, policy_fn)
  manager.policy = policy_fn
end

-- build_context(registry) -> the SyncContext handed to the policy function:
-- every registered period plus the currently active period id.
--: Registry -> SyncContext
local function build_context(registry)
  return {
    periods       = doc_registry.list_periods(registry),
    active_period = doc_registry.active_period(registry),
  }
end

--- Evaluate the manager's policy against the registry's current state and
-- initiate sync (a SyncStep1 handshake message) for every doc_id the policy
-- returns. Returns the list of doc_ids a step1 was successfully sent for;
-- (nil, err) only if `transport.send` itself fails or a doc_id cannot be
-- resolved -- to keep partial progress visible even under failure, this
-- stops at the first error rather than best-effort continuing past it (a
-- transport failure for one doc likely means the transport itself is down,
-- so continuing to attempt further sends would just accumulate the same
-- failure silently).
--: Manager -> ({ [number]: string } | nil, string | nil)
M.sync = function(manager)
  local policy = manager.policy or no_op_policy
  local doc_ids = policy(build_context(manager.registry))

  local sent = {} --: { [number]: string }
  for i = 1, #doc_ids do
    local doc_id = doc_ids[i]
    local d, derr = resolve_doc(manager.registry, doc_id)
    if d == nil then return nil, "sync_manager.sync: " .. tostring(derr) end

    local step1 = sync.write_step1(d)
    local ok, serr = manager.transport.send(doc_id, step1)
    if not ok then
      return nil, "sync_manager.sync: transport.send failed for '" .. doc_id .. "': " .. tostring(serr)
    end
    sent[#sent + 1] = doc_id
  end
  return sent
end

--- Route an incoming sync-protocol message (step1/step2/update) to the doc
-- named `doc_id`. If handling the message produces a reply (step1 always
-- does, per lib/y_crdt/sync.lua's handle_message contract; step2/update
-- never do), sends it back out over the transport addressed to the same
-- doc_id.
--: (Manager, string, string) -> (true | nil, string | nil)
M.on_message = function(manager, doc_id, bytes)
  local d, derr = resolve_doc(manager.registry, doc_id)
  if d == nil then return nil, "sync_manager.on_message: " .. tostring(derr) end

  local reply, herr = sync.handle_message(d, bytes)
  if reply == nil and herr ~= nil then
    return nil, "sync_manager.on_message: " .. herr
  end
  if reply ~= nil then
    local ok, serr = manager.transport.send(doc_id, reply)
    if not ok then
      return nil, "sync_manager.on_message: transport.send failed for '" .. doc_id .. "': " .. tostring(serr)
    end
  end
  return true
end

--- Broadcast an already-encoded local change (from lib/y_crdt/update's
-- encode_v1/encode_diff_v1) for `doc_id` to peers, wrapping it in an
-- Update sync message first.
--: (Manager, string, string) -> (true | nil, string | nil)
M.broadcast_change = function(manager, doc_id, update_bytes)
  local msg = sync.write_update(update_bytes)
  local ok, err = manager.transport.send(doc_id, msg)
  if not ok then
    return nil, "sync_manager.broadcast_change: transport.send failed for '" .. doc_id .. "': " .. tostring(err)
  end
  return true
end

return M
