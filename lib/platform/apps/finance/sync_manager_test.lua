if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local doc_registry = require("lib.platform.apps.finance.doc_registry")
local sync_manager  = require("lib.platform.apps.finance.sync_manager")
local doc_mod       = require("lib.y_crdt.doc")
local map           = require("lib.y_crdt.map")

-- A mock transport cap: records every send() and lets a test inject what
-- the "peer" would send back for a given doc_id by pre-registering a
-- handler. This is the caps-first substitute for a real network transport
-- in tests -- see CLAUDE.md's caps-first discipline.
--: () -> { send: (string, string) -> (true | nil, string | nil), sent: { [number]: { doc_id: string, bytes: string } } }
local function mock_transport()
  local sent = {} --: { [number]: { doc_id: string, bytes: string } }
  return {
    sent = sent,
    send = function(doc_id, bytes)
      sent[#sent + 1] = { doc_id = doc_id, bytes = bytes }
      return true
    end,
  }
end

T.describe("finance.sync_manager", function()

  T.describe("M.new / M.set_policy", function()
    T.it("defaults to a no-op policy: M.sync sends nothing", function()
      local reg = doc_registry.new({ client_id = 1 })
      local transport = mock_transport()
      local manager = sync_manager.new({ registry = reg, transport = transport })

      local sent_ids, err = sync_manager.sync(manager)
      T.ok(sent_ids ~= nil, err)
      T.eq(#sent_ids, 0)
      T.eq(#transport.sent, 0)
    end)

    T.it("set_policy installs a new policy used by the next M.sync", function()
      local reg = doc_registry.new({ client_id = 1 })
      local transport = mock_transport()
      local manager = sync_manager.new({ registry = reg, transport = transport })

      sync_manager.set_policy(manager, function(_context) return { "accounts" } end)
      local sent_ids, err = sync_manager.sync(manager)
      T.ok(sent_ids ~= nil, err)
      T.eq(#sent_ids, 1)
      T.eq(sent_ids[1], "accounts")
    end)
  end)

  T.describe("M.sync", function()
    T.it("evaluates the policy with the registry's periods/active_period", function()
      local reg = doc_registry.new({ client_id = 1 })
      doc_registry.add_period(reg, "2026-Q3", { start_date = "2026-07-01", end_date = "2026-09-30" })
      doc_registry.set_active_period(reg, "2026-Q3")

      local seen_context
      local transport = mock_transport()
      local manager = sync_manager.new({
        registry = reg,
        transport = transport,
        policy = function(context)
          seen_context = context
          return {}
        end,
      })
      sync_manager.sync(manager)

      T.ok(seen_context ~= nil)
      T.eq(seen_context.active_period, "2026-Q3")
      T.eq(#seen_context.periods, 1)
      T.eq(seen_context.periods[1].id, "2026-Q3")
    end)

    T.it("sends a step1 message via transport.send for each doc_id the policy returns", function()
      local reg = doc_registry.new({ client_id = 1 })
      doc_registry.add_period(reg, "2026-Q3", { start_date = "2026-07-01", end_date = "2026-09-30" })

      local transport = mock_transport()
      local manager = sync_manager.new({
        registry = reg,
        transport = transport,
        policy = function(_context) return { "accounts", "2026-Q3" } end,
      })
      local sent_ids, err = sync_manager.sync(manager)
      T.ok(sent_ids ~= nil, err)
      T.eq(#sent_ids, 2)
      T.eq(#transport.sent, 2)
      T.eq(transport.sent[1].doc_id, "accounts")
      T.eq(transport.sent[2].doc_id, "2026-Q3")
    end)

    T.it("lazily creates a period doc named by the policy if it doesn't exist yet", function()
      local reg = doc_registry.new({ client_id = 1 })
      local transport = mock_transport()
      local manager = sync_manager.new({
        registry = reg,
        transport = transport,
        policy = function(_context) return { "2026-Q1" } end,
      })
      local sent_ids, err = sync_manager.sync(manager)
      T.ok(sent_ids ~= nil, err)
      T.eq(#sent_ids, 1)
      -- the period doc now exists in the registry (get_or_create_period is idempotent)
      local d = doc_registry.get_or_create_period(reg, "2026-Q1")
      T.ok(d ~= nil)
    end)

    T.it("propagates a transport.send failure without sending further doc_ids", function()
      local reg = doc_registry.new({ client_id = 1 })
      local calls = 0
      --: (string, string) -> (true | nil, string | nil)
      local function failing_send(_doc_id, _bytes)
        calls = calls + 1
        return nil, "transport down"
      end
      local manager = sync_manager.new({
        registry = reg,
        transport = { send = failing_send },
        policy = function(_context) return { "accounts", "accounts" } end,
      })
      local sent_ids, err = sync_manager.sync(manager)
      T.eq(sent_ids, nil)
      T.ok(err ~= nil)
      T.eq(calls, 1)
    end)
  end)

  T.describe("M.on_message", function()
    T.it("routes a step1 message to the accounts doc and replies via transport.send", function()
      local reg_a = doc_registry.new({ client_id = 1 })
      local reg_b = doc_registry.new({ client_id = 2 })

      -- Give A's accounts doc some content to converge.
      local accounts_a = doc_registry.accounts_doc(reg_a)
      local periods_map_a, pmerr = doc_mod.get_map(accounts_a, "periods")
      if periods_map_a == nil then error("test setup: " .. tostring(pmerr)) end
      doc_mod.transact(accounts_a, function(txn)
        map.set(periods_map_a, txn, "2026-Q3", { start_date = "2026-07-01", end_date = "2026-09-30" })
      end)

      local transport_b = mock_transport()
      local manager_b = sync_manager.new({ registry = reg_b, transport = transport_b })

      -- A sends step1 (its state vector) to B via on_message; B should reply
      -- with step2 over transport_b, addressed back to "accounts".
      local sync = require("lib.y_crdt.sync")
      local step1_from_a = sync.write_step1(accounts_a)
      local ok, err = sync_manager.on_message(manager_b, "accounts", step1_from_a)
      T.ok(ok, err)
      T.eq(#transport_b.sent, 1)
      T.eq(transport_b.sent[1].doc_id, "accounts")
    end)

    T.it("propagates a decode error without sending a reply", function()
      local reg = doc_registry.new({ client_id = 1 })
      local transport = mock_transport()
      local manager = sync_manager.new({ registry = reg, transport = transport })
      local ok, err = sync_manager.on_message(manager, "accounts", "")
      T.eq(ok, nil)
      T.ok(err ~= nil)
      T.eq(#transport.sent, 0)
    end)

    T.it("routes messages to a period doc by doc_id, creating it if needed", function()
      local reg = doc_registry.new({ client_id = 1 })
      local transport = mock_transport()
      local manager = sync_manager.new({ registry = reg, transport = transport })

      local sync = require("lib.y_crdt.sync")
      local other_reg = doc_registry.new({ client_id = 2 })
      local other_period = doc_registry.get_or_create_period(other_reg, "2026-Q3")
      local step1 = sync.write_step1(other_period)

      local ok, err = sync_manager.on_message(manager, "2026-Q3", step1)
      T.ok(ok, err)
      T.eq(#transport.sent, 1)
      T.eq(transport.sent[1].doc_id, "2026-Q3")
    end)
  end)

  T.describe("M.broadcast_change", function()
    T.it("wraps update bytes in an Update message and sends via transport", function()
      local reg = doc_registry.new({ client_id = 1 })
      local transport = mock_transport()
      local manager = sync_manager.new({ registry = reg, transport = transport })

      local ok, err = sync_manager.broadcast_change(manager, "accounts", "fake-update-bytes")
      T.ok(ok, err)
      T.eq(#transport.sent, 1)
      T.eq(transport.sent[1].doc_id, "accounts")

      local sync = require("lib.y_crdt.sync")
      local msg_type, payload = sync.read_message(transport.sent[1].bytes)
      T.eq(msg_type, "update")
      T.eq(payload, "fake-update-bytes")
    end)

    T.it("propagates a transport.send failure", function()
      local reg = doc_registry.new({ client_id = 1 })
      --: (string, string) -> (true | nil, string | nil)
      local function failing_send(_doc_id, _bytes) return nil, "transport down" end
      local manager = sync_manager.new({
        registry = reg,
        transport = { send = failing_send },
      })
      local ok, err = sync_manager.broadcast_change(manager, "accounts", "bytes")
      T.eq(ok, nil)
      T.ok(err ~= nil)
    end)
  end)

end)
