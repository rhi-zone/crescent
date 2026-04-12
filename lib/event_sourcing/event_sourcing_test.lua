-- lib/event_sourcing/event_sourcing_test.lua
-- Tests for the event_sourcing library.
-- Domain: BankAccount aggregate with Deposit/Withdraw events.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local ES = require("lib.event_sourcing")
local T  = require("lib.test.assert")

-- ---------------------------------------------------------------------------
-- BankAccount aggregate (used across many test groups)
-- ---------------------------------------------------------------------------

local BankAccount = ES.aggregate("BankAccount", {
  Opened = function(state, ev)
    return { owner = ev.data.owner, balance = ev.data.initial_deposit or 0, open = true }
  end,
  Deposited = function(state, ev)
    state.balance = state.balance + ev.data.amount
    return state
  end,
  Withdrawn = function(state, ev)
    state.balance = state.balance - ev.data.amount
    return state
  end,
  Closed = function(state, ev)
    state.open = false
    return state
  end,
})

-- ---------------------------------------------------------------------------
-- M.event
-- ---------------------------------------------------------------------------

T.describe("M.event", function()
  T.it("creates an event with required fields", function()
    local ev = ES.event("Deposited", { amount = 50 }, {
      aggregate_id   = "acct-1",
      aggregate_type = "BankAccount",
      version        = 3,
      metadata       = { user = "alice" },
    })
    T.eq(ev.type,           "Deposited")
    T.eq(ev.data.amount,    50)
    T.eq(ev.aggregate_id,   "acct-1")
    T.eq(ev.aggregate_type, "BankAccount")
    T.eq(ev.version,        3)
    T.eq(ev.metadata.user,  "alice")
    T.ok(ev.id ~= nil)
    T.ok(ev.timestamp ~= nil)
  end)

  T.it("defaults data, metadata, and version", function()
    local ev = ES.event("Noop")
    T.eq(ev.type,    "Noop")
    T.eq(ev.version, 0)
    T.ok(type(ev.data)     == "table")
    T.ok(type(ev.metadata) == "table")
  end)

  T.it("ids are unique", function()
    local a = ES.event("A")
    local b = ES.event("B")
    T.neq(a.id, b.id)
  end)
end)

-- ---------------------------------------------------------------------------
-- store:append / store:load
-- ---------------------------------------------------------------------------

T.describe("store:append basic", function()
  T.it("appends events and stamps version and position", function()
    local store = ES.store()
    local ev1 = ES.event("Opened",    { owner = "Alice", initial_deposit = 100 })
    local ev2 = ES.event("Deposited", { amount = 50 })
    local ok, err = store:append("acct-1", { ev1, ev2 })
    T.ok(ok)
    T.eq(err, nil)
    local events = store:load("acct-1")
    T.eq(#events, 2)
    T.eq(events[1].version, 1)
    T.eq(events[2].version, 2)
    T.eq(events[1].position, 1)
    T.eq(events[2].position, 2)
  end)

  T.it("positions are globally unique across aggregates", function()
    local store = ES.store()
    store:append("acct-1", { ES.event("Opened", {}) })
    store:append("acct-2", { ES.event("Opened", {}) })
    local e1 = store:load("acct-1")[1]
    local e2 = store:load("acct-2")[1]
    T.neq(e1.position, e2.position)
  end)

  T.it("returns error when aggregate_id is missing", function()
    local store = ES.store()
    local ok, err = store:append(nil, { ES.event("Noop") })
    T.eq(ok, nil)
    T.ok(err ~= nil)
  end)

  T.it("returns error when events is not a table", function()
    local store = ES.store()
    local ok, err = store:append("acct-1", "bad")
    T.eq(ok, nil)
    T.ok(err ~= nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- optimistic concurrency
-- ---------------------------------------------------------------------------

T.describe("store optimistic concurrency", function()
  T.it("expected_version=0 succeeds on new stream", function()
    local store = ES.store()
    local ok, err = store:append("acct-1", { ES.event("Opened", {}) }, 0)
    T.ok(ok)
    T.eq(err, nil)
  end)

  T.it("expected_version=0 fails on existing stream", function()
    local store = ES.store()
    store:append("acct-1", { ES.event("Opened", {}) })
    local ok, err = store:append("acct-1", { ES.event("Deposited", { amount = 10 }) }, 0)
    T.eq(ok, nil)
    T.ok(err ~= nil)
  end)

  T.it("expected_version=n succeeds when stream is at n", function()
    local store = ES.store()
    store:append("acct-1", { ES.event("Opened", {}) })
    local ok, err = store:append("acct-1", { ES.event("Deposited", { amount = 10 }) }, 1)
    T.ok(ok)
    T.eq(err, nil)
  end)

  T.it("expected_version=n fails on version mismatch", function()
    local store = ES.store()
    store:append("acct-1", { ES.event("Opened", {}) })
    store:append("acct-1", { ES.event("Deposited", { amount = 10 }) })
    local ok, err = store:append("acct-1", { ES.event("Deposited", { amount = 20 }) }, 1)
    T.eq(ok, nil)
    T.ok(err ~= nil)
  end)

  T.it("nil expected_version skips the check", function()
    local store = ES.store()
    store:append("acct-1", { ES.event("Opened", {}) })
    local ok = store:append("acct-1", { ES.event("Deposited", { amount = 5 }) }, nil)
    T.ok(ok)
  end)
end)

-- ---------------------------------------------------------------------------
-- store:load with opts
-- ---------------------------------------------------------------------------

T.describe("store:load opts", function()
  local function filled_store()
    local store = ES.store()
    store:append("acct-1", {
      ES.event("Opened",    { initial_deposit = 1000 }),
      ES.event("Deposited", { amount = 100 }),
      ES.event("Deposited", { amount = 200 }),
      ES.event("Withdrawn", { amount = 50 }),
    })
    return store
  end

  T.it("loads all events by default", function()
    local store = filled_store()
    local evs = store:load("acct-1")
    T.eq(#evs, 4)
  end)

  T.it("from_version filters out earlier events", function()
    local store = filled_store()
    local evs = store:load("acct-1", { from_version = 3 })
    T.eq(#evs, 2)
    T.eq(evs[1].version, 3)
  end)

  T.it("to_version caps the result", function()
    local store = filled_store()
    local evs = store:load("acct-1", { to_version = 2 })
    T.eq(#evs, 2)
    T.eq(evs[2].version, 2)
  end)

  T.it("limit caps the result", function()
    local store = filled_store()
    local evs = store:load("acct-1", { limit = 2 })
    T.eq(#evs, 2)
  end)

  T.it("returns empty for unknown aggregate", function()
    local store = ES.store()
    local evs = store:load("nobody")
    T.eq(#evs, 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- store:load_all
-- ---------------------------------------------------------------------------

T.describe("store:load_all", function()
  T.it("returns all events ordered by position", function()
    local store = ES.store()
    store:append("acct-1", { ES.event("Opened",    { owner = "Alice" }) })
    store:append("acct-2", { ES.event("Opened",    { owner = "Bob"   }) })
    store:append("acct-1", { ES.event("Deposited", { amount = 10     }) })
    local all = store:load_all()
    T.eq(#all, 3)
    T.ok(all[1].position < all[2].position)
    T.ok(all[2].position < all[3].position)
  end)

  T.it("from_position filters earlier events", function()
    local store = ES.store()
    store:append("acct-1", { ES.event("Opened", {}) })
    store:append("acct-1", { ES.event("Deposited", { amount = 5 }) })
    local all = store:load_all({ from_position = 2 })
    T.eq(#all, 1)
    T.eq(all[1].position, 2)
  end)

  T.it("limit caps the result", function()
    local store = ES.store()
    store:append("acct-1", {
      ES.event("Opened",    {}),
      ES.event("Deposited", { amount = 1 }),
      ES.event("Deposited", { amount = 2 }),
    })
    local all = store:load_all({ limit = 2 })
    T.eq(#all, 2)
  end)

  T.it("aggregate_type filter works", function()
    local store = ES.store()
    local ev1 = ES.event("Opened", {})
    ev1.aggregate_type = "BankAccount"
    local ev2 = ES.event("Created", {})
    ev2.aggregate_type = "Order"
    store:append("acct-1",  { ev1 })
    store:append("order-1", { ev2 })
    local all = store:load_all({ aggregate_type = "BankAccount" })
    T.eq(#all, 1)
    T.eq(all[1].aggregate_type, "BankAccount")
  end)
end)

-- ---------------------------------------------------------------------------
-- store:subscribe
-- ---------------------------------------------------------------------------

T.describe("store:subscribe", function()
  T.it("fires handler for each appended event", function()
    local store = ES.store()
    local seen = {}
    store:subscribe(function(ev) seen[#seen + 1] = ev end)
    store:append("acct-1", {
      ES.event("Opened",    {}),
      ES.event("Deposited", { amount = 50 }),
    })
    T.eq(#seen, 2)
    T.eq(seen[1].type, "Opened")
    T.eq(seen[2].type, "Deposited")
  end)

  T.it("multiple subscribers all fire", function()
    local store = ES.store()
    local a, b = 0, 0
    store:subscribe(function() a = a + 1 end)
    store:subscribe(function() b = b + 1 end)
    store:append("acct-1", { ES.event("Opened", {}) })
    T.eq(a, 1)
    T.eq(b, 1)
  end)
end)

-- ---------------------------------------------------------------------------
-- store:snapshot / store:load_snapshot
-- ---------------------------------------------------------------------------

T.describe("store snapshots", function()
  T.it("stores and loads a snapshot", function()
    local store = ES.store()
    store:snapshot("acct-1", { balance = 500, open = true }, 5)
    local snap = store:load_snapshot("acct-1")
    T.ok(snap ~= nil)
    T.eq(snap.version, 5)
    T.eq(snap.state.balance, 500)
  end)

  T.it("returns nil for unknown aggregate", function()
    local store = ES.store()
    T.eq(store:load_snapshot("nobody"), nil)
  end)

  T.it("overwriting a snapshot replaces it", function()
    local store = ES.store()
    store:snapshot("acct-1", { balance = 100 }, 3)
    store:snapshot("acct-1", { balance = 999 }, 10)
    local snap = store:load_snapshot("acct-1")
    T.eq(snap.state.balance, 999)
    T.eq(snap.version, 10)
  end)
end)

-- ---------------------------------------------------------------------------
-- Aggregate: raise / apply / pending_events / version / state
-- ---------------------------------------------------------------------------

T.describe("aggregate:raise", function()
  T.it("raise stages an event and applies it locally", function()
    local acct = BankAccount.new("acct-1")
    acct:raise("Opened", { owner = "Alice", initial_deposit = 300 })
    T.eq(acct.version, 1)
    T.eq(acct.state.owner,   "Alice")
    T.eq(acct.state.balance, 300)
    T.eq(#acct.pending_events, 1)
    T.eq(acct.pending_events[1].type, "Opened")
  end)

  T.it("chaining raise increments version", function()
    local acct = BankAccount.new("acct-1")
    acct:raise("Opened",    { owner = "Bob", initial_deposit = 500 })
        :raise("Deposited", { amount = 100 })
        :raise("Withdrawn", { amount = 50  })
    T.eq(acct.version, 3)
    T.eq(acct.state.balance, 550)
    T.eq(#acct.pending_events, 3)
  end)

  T.it("raised events carry the aggregate_id", function()
    local acct = BankAccount.new("acct-42")
    acct:raise("Opened", {})
    T.eq(acct.pending_events[1].aggregate_id, "acct-42")
  end)
end)

T.describe("aggregate:apply", function()
  T.it("apply rebuilds state from stored events", function()
    local store = ES.store()
    store:append("acct-1", {
      ES.event("Opened",    { owner = "Alice", initial_deposit = 1000 }),
      ES.event("Deposited", { amount = 200 }),
      ES.event("Withdrawn", { amount = 150 }),
      ES.event("Deposited", { amount = 75  }),
    })
    local evs  = store:load("acct-1")
    local acct = BankAccount.new("acct-1")
    acct:apply(evs)
    T.eq(acct.state.balance, 1000 + 200 - 150 + 75)
    T.eq(acct.version, 4)
  end)

  T.it("apply returns self for chaining", function()
    local acct = BankAccount.new("acct-1")
    local ret  = acct:apply({})
    T.ok(ret == acct)
  end)

  T.it("unknown event types are skipped without error", function()
    local store = ES.store()
    store:append("acct-1", { ES.event("UnknownEvent", {}) })
    local evs  = store:load("acct-1")
    local acct = BankAccount.new("acct-1")
    acct:apply(evs)
    T.eq(acct.version, 1) -- version still advances
  end)

  T.it("Closed sets open = false", function()
    local store = ES.store()
    store:append("acct-1", {
      ES.event("Opened", { owner = "Alice", initial_deposit = 100 }),
      ES.event("Closed", {}),
    })
    local acct = BankAccount.new("acct-1")
    acct:apply(store:load("acct-1"))
    T.eq(acct.state.open, false)
    T.eq(acct.version, 2)
  end)
end)

-- ---------------------------------------------------------------------------
-- Projection
-- ---------------------------------------------------------------------------

T.describe("projection", function()
  local function total_balance_proj()
    return ES.projection({
      Opened = function(state, ev)
        state.accounts = state.accounts or {}
        state.accounts[ev.aggregate_id] = ev.data.initial_deposit or 0
        state.total = (state.total or 0) + (ev.data.initial_deposit or 0)
        return state
      end,
      Deposited = function(state, ev)
        state.accounts[ev.aggregate_id] = (state.accounts[ev.aggregate_id] or 0) + ev.data.amount
        state.total = state.total + ev.data.amount
        return state
      end,
      Withdrawn = function(state, ev)
        state.accounts[ev.aggregate_id] = (state.accounts[ev.aggregate_id] or 0) - ev.data.amount
        state.total = state.total - ev.data.amount
        return state
      end,
    })
  end

  T.it("handles a single event", function()
    local proj = total_balance_proj()
    local ev   = ES.event("Opened", { initial_deposit = 500 }, { aggregate_id = "acct-1" })
    ev.aggregate_id = "acct-1"
    proj:handle(ev)
    T.eq(proj.state.total, 500)
  end)

  T.it("handle_all builds correct state across aggregates", function()
    local store = ES.store()
    local ev1 = ES.event("Opened",    { initial_deposit = 500 })
    local ev2 = ES.event("Opened",    { initial_deposit = 300 })
    local ev3 = ES.event("Deposited", { amount = 100 })
    local ev4 = ES.event("Withdrawn", { amount = 50  })
    store:append("acct-1", { ev1, ev3 })
    store:append("acct-2", { ev2, ev4 })

    local proj = total_balance_proj()
    proj:handle_all(store:load_all())

    T.eq(proj.state.total,                   500 + 300 + 100 - 50)
    T.eq(proj.state.accounts["acct-1"],      600)
    T.eq(proj.state.accounts["acct-2"],      250)
  end)

  T.it("handle_all returns self for chaining", function()
    local proj = total_balance_proj()
    local ret  = proj:handle_all({})
    T.ok(ret == proj)
  end)

  T.it("unknown event types are ignored", function()
    local proj = total_balance_proj()
    proj:handle(ES.event("UnknownEvent", {}))
    T.eq(proj.state.total, nil) -- no initialisation triggered
  end)
end)

-- ---------------------------------------------------------------------------
-- Saga
-- ---------------------------------------------------------------------------

T.describe("saga", function()
  -- Onboarding saga: account opened → issue welcome bonus deposit command.
  local OnboardingSaga
  OnboardingSaga = ES.saga({
    Opened = function(state, ev)
      return {
        state    = { account_id = ev.aggregate_id, welcomed = false },
        commands = {
          { type = "IssueBonus", aggregate_id = ev.aggregate_id, amount = 50 },
        },
      }
    end,
    Deposited = function(state, ev)
      -- Only mark welcomed once the bonus deposit arrives.
      if ev.data.amount == 50 then
        return {
          state    = { account_id = state.account_id, welcomed = true },
          commands = {},
        }
      end
      return { state = state, commands = {} }
    end,
  })

  T.it("returns commands for a handled event", function()
    local saga = OnboardingSaga.new()
    local ev   = ES.event("Opened", {}, { aggregate_id = "acct-1" })
    ev.aggregate_id = "acct-1"
    local result = saga:handle(ev)
    T.eq(#result.commands, 1)
    T.eq(result.commands[1].type, "IssueBonus")
    T.eq(result.commands[1].amount, 50)
    T.eq(saga.state.account_id, "acct-1")
  end)

  T.it("returns empty commands for unhandled event type", function()
    local saga   = OnboardingSaga.new()
    local ev     = ES.event("Withdrawn", { amount = 10 })
    local result = saga:handle(ev)
    T.eq(#result.commands, 0)
  end)

  T.it("state updates accumulate across events", function()
    local saga = OnboardingSaga.new()
    local ev1  = ES.event("Opened",    {}, { aggregate_id = "acct-1" })
    ev1.aggregate_id = "acct-1"
    local ev2  = ES.event("Deposited", { amount = 50 }, { aggregate_id = "acct-1" })
    saga:handle(ev1)
    saga:handle(ev2)
    T.eq(saga.state.welcomed, true)
  end)

  T.it("different instances are independent", function()
    local s1 = OnboardingSaga.new()
    local s2 = OnboardingSaga.new()
    local ev = ES.event("Opened", {}, { aggregate_id = "acct-x" })
    ev.aggregate_id = "acct-x"
    s1:handle(ev)
    T.eq(s1.state.account_id, "acct-x")
    T.eq(s2.state.account_id, nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- M.load_aggregate (snapshot-aware)
-- ---------------------------------------------------------------------------

T.describe("M.load_aggregate", function()
  T.it("loads from events when no snapshot exists", function()
    local store = ES.store()
    store:append("acct-1", {
      ES.event("Opened",    { owner = "Alice", initial_deposit = 100 }),
      ES.event("Deposited", { amount = 50 }),
    })
    local acct, err = ES.load_aggregate(store, BankAccount, "acct-1")
    T.ok(acct ~= nil)
    T.eq(err,  nil)
    T.eq(acct.version,       2)
    T.eq(acct.state.balance, 150)
  end)

  T.it("uses snapshot then replays subsequent events", function()
    local store = ES.store()
    -- Simulate three events already snapshotted.
    store:append("acct-1", {
      ES.event("Opened",    { owner = "Alice", initial_deposit = 1000 }),
      ES.event("Deposited", { amount = 100 }),
      ES.event("Deposited", { amount = 200 }),
    })
    -- Take a snapshot at version 3.
    store:snapshot("acct-1", { owner = "Alice", balance = 1300, open = true }, 3)
    -- Append more events after the snapshot.
    store:append("acct-1", {
      ES.event("Withdrawn", { amount = 400 }),
    })

    local acct = ES.load_aggregate(store, BankAccount, "acct-1")
    T.eq(acct.version,       4)
    T.eq(acct.state.balance, 900)
  end)

  T.it("returns (nil, err) when store is missing", function()
    local acct, err = ES.load_aggregate(nil, BankAccount, "acct-1")
    T.eq(acct, nil)
    T.ok(err ~= nil)
  end)

  T.it("returns (nil, err) when aggregate_class is missing", function()
    local store     = ES.store()
    local acct, err = ES.load_aggregate(store, nil, "acct-1")
    T.eq(acct, nil)
    T.ok(err ~= nil)
  end)

  T.it("returns (nil, err) when id is missing", function()
    local store     = ES.store()
    local acct, err = ES.load_aggregate(store, BankAccount, nil)
    T.eq(acct, nil)
    T.ok(err ~= nil)
  end)

  T.it("returns aggregate with empty state for new id", function()
    local store     = ES.store()
    local acct, err = ES.load_aggregate(store, BankAccount, "new-acct")
    T.ok(acct ~= nil)
    T.eq(err,  nil)
    T.eq(acct.version, 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- M._tier
-- ---------------------------------------------------------------------------

T.describe("module metadata", function()
  T.it("_tier is pure", function()
    T.eq(ES._tier, "pure")
  end)
end)
