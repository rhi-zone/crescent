-- lib/event_sourcing/event_sourcing_test.lua
-- Tests for the event_sourcing library using a bank-account domain.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local ES = require("lib.event_sourcing")
local T  = require("lib.test.assert")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function make_store()
    return ES.store()
end

-- Bank account aggregate handlers.
local account_handlers = {
    account_created = function(state, event)
        return {
            owner   = event.payload.owner,
            balance = event.payload.initial_deposit or 0,
            open    = true,
        }
    end,
    deposit = function(state, event)
        state.balance = state.balance + event.payload.amount
        return state
    end,
    withdrawal = function(state, event)
        state.balance = state.balance - event.payload.amount
        return state
    end,
    account_closed = function(state, event)
        state.open = false
        return state
    end,
}

-- ── Store: append ─────────────────────────────────────────────────────────────

T.describe("store:append", function()
    T.it("returns an event with required fields", function()
        local store = make_store()
        local ev = store:append("user-1", "account_created", { owner = "Alice", initial_deposit = 100 })
        T.ok(ev ~= nil)
        T.ok(ev.id ~= nil)
        T.eq(ev.aggregate_id, "user-1")
        T.eq(ev.event_type, "account_created")
        T.eq(ev.payload.owner, "Alice")
        T.eq(ev.sequence, 1)
        T.eq(ev.global_sequence, 1)
    end)

    T.it("increments sequence per aggregate", function()
        local store = make_store()
        store:append("user-1", "account_created", { owner = "Alice" })
        local ev2 = store:append("user-1", "deposit", { amount = 50 })
        T.eq(ev2.sequence, 2)
        T.eq(ev2.global_sequence, 2)
    end)

    T.it("global_sequence increments across aggregates", function()
        local store = make_store()
        store:append("user-1", "account_created", { owner = "Alice" })
        local ev2 = store:append("user-2", "account_created", { owner = "Bob" })
        T.eq(ev2.global_sequence, 2)
        -- But per-aggregate sequence resets.
        T.eq(ev2.sequence, 1)
    end)

    T.it("returns error for empty aggregate_id", function()
        local store = make_store()
        local ev, err = store:append("", "deposit", {})
        T.eq(ev, nil)
        T.ok(err ~= nil)
    end)

    T.it("returns error for empty event_type", function()
        local store = make_store()
        local ev, err = store:append("user-1", "", {})
        T.eq(ev, nil)
        T.ok(err ~= nil)
    end)

    T.it("stores metadata", function()
        local store = make_store()
        local ev = store:append("user-1", "deposit", { amount = 10 }, { user_id = "admin", correlation_id = "c-1" })
        T.eq(ev.metadata.user_id, "admin")
        T.eq(ev.metadata.correlation_id, "c-1")
    end)

    T.it("defaults metadata to empty table", function()
        local store = make_store()
        local ev = store:append("user-1", "deposit", { amount = 10 })
        T.ok(type(ev.metadata) == "table")
    end)
end)

-- ── Store: events_for ─────────────────────────────────────────────────────────

T.describe("store:events_for", function()
    T.it("returns events in order for aggregate", function()
        local store = make_store()
        store:append("user-1", "account_created", { owner = "Alice" })
        store:append("user-1", "deposit", { amount = 100 })
        store:append("user-1", "deposit", { amount = 50 })
        local evs = store:events_for("user-1")
        T.eq(#evs, 3)
        T.eq(evs[1].event_type, "account_created")
        T.eq(evs[2].payload.amount, 100)
        T.eq(evs[3].payload.amount, 50)
    end)

    T.it("returns empty table for unknown aggregate", function()
        local store = make_store()
        local evs = store:events_for("nobody")
        T.eq(#evs, 0)
    end)

    T.it("does not include events from other aggregates", function()
        local store = make_store()
        store:append("user-1", "account_created", { owner = "Alice" })
        store:append("user-2", "account_created", { owner = "Bob" })
        store:append("user-2", "deposit", { amount = 200 })
        local evs1 = store:events_for("user-1")
        local evs2 = store:events_for("user-2")
        T.eq(#evs1, 1)
        T.eq(#evs2, 2)
    end)
end)

-- ── Store: events_after ───────────────────────────────────────────────────────

T.describe("store:events_after", function()
    T.it("returns events with global_sequence > given sequence", function()
        local store = make_store()
        store:append("user-1", "account_created", { owner = "Alice" })
        store:append("user-1", "deposit", { amount = 50 })
        store:append("user-2", "account_created", { owner = "Bob" })
        local evs = store:events_after(1)
        T.eq(#evs, 2)
        T.eq(evs[1].global_sequence, 2)
        T.eq(evs[2].global_sequence, 3)
    end)

    T.it("returns all events when sequence is 0", function()
        local store = make_store()
        store:append("user-1", "account_created", {})
        store:append("user-1", "deposit", { amount = 10 })
        local evs = store:events_after(0)
        T.eq(#evs, 2)
    end)

    T.it("returns empty when sequence is at max", function()
        local store = make_store()
        store:append("user-1", "account_created", {})
        local evs = store:events_after(1)
        T.eq(#evs, 0)
    end)
end)

-- ── Store: events_of_type ─────────────────────────────────────────────────────

T.describe("store:events_of_type", function()
    T.it("returns only events matching the type", function()
        local store = make_store()
        store:append("user-1", "account_created", { owner = "Alice" })
        store:append("user-1", "deposit", { amount = 100 })
        store:append("user-2", "account_created", { owner = "Bob" })
        store:append("user-2", "deposit", { amount = 200 })
        local deposits = store:events_of_type("deposit")
        T.eq(#deposits, 2)
        T.eq(deposits[1].payload.amount, 100)
        T.eq(deposits[2].payload.amount, 200)
    end)

    T.it("returns empty for unknown type", function()
        local store = make_store()
        store:append("user-1", "deposit", { amount = 10 })
        local evs = store:events_of_type("withdrawal")
        T.eq(#evs, 0)
    end)
end)

-- ── Store: event_count and latest_sequence ────────────────────────────────────

T.describe("store:event_count", function()
    T.it("returns total across all aggregates", function()
        local store = make_store()
        T.eq(store:event_count(), 0)
        store:append("user-1", "account_created", {})
        store:append("user-2", "account_created", {})
        store:append("user-1", "deposit", { amount = 10 })
        T.eq(store:event_count(), 3)
    end)
end)

T.describe("store:latest_sequence", function()
    T.it("returns 0 for unknown aggregate", function()
        local store = make_store()
        T.eq(store:latest_sequence("nobody"), 0)
    end)

    T.it("returns highest per-aggregate sequence", function()
        local store = make_store()
        store:append("user-1", "account_created", {})
        store:append("user-1", "deposit", { amount = 50 })
        store:append("user-1", "withdrawal", { amount = 20 })
        T.eq(store:latest_sequence("user-1"), 3)
    end)

    T.it("independent sequences for different aggregates", function()
        local store = make_store()
        store:append("user-1", "account_created", {})
        store:append("user-2", "account_created", {})
        store:append("user-2", "deposit", { amount = 10 })
        T.eq(store:latest_sequence("user-1"), 1)
        T.eq(store:latest_sequence("user-2"), 2)
    end)
end)

-- ── Aggregate ─────────────────────────────────────────────────────────────────

T.describe("aggregate:apply", function()
    T.it("applies a single event", function()
        local store = make_store()
        local ev = store:append("user-1", "account_created", { owner = "Alice", initial_deposit = 500 })
        local agg = ES.aggregate("user-1", {
            handlers      = account_handlers,
            initial_state = {},
        })
        agg:apply(ev)
        T.eq(agg:state().owner, "Alice")
        T.eq(agg:state().balance, 500)
        T.eq(agg:version(), 1)
    end)

    T.it("version increments even for unknown event types", function()
        local store = make_store()
        local ev = store:append("user-1", "unknown_event", {})
        local agg = ES.aggregate("user-1", { handlers = {}, initial_state = {} })
        agg:apply(ev)
        T.eq(agg:version(), 1)
    end)
end)

T.describe("aggregate:replay", function()
    T.it("rebuilds balance correctly", function()
        local store = make_store()
        store:append("user-1", "account_created", { owner = "Alice", initial_deposit = 1000 })
        store:append("user-1", "deposit",         { amount = 200 })
        store:append("user-1", "withdrawal",      { amount = 150 })
        store:append("user-1", "deposit",         { amount = 75 })

        local agg = ES.aggregate("user-1", {
            handlers      = account_handlers,
            initial_state = {},
        })
        agg:replay(store:events_for("user-1"))

        T.eq(agg:state().balance, 1000 + 200 - 150 + 75)
        T.eq(agg:version(), 4)
    end)

    T.it("initial_state is used as the starting point", function()
        local agg = ES.aggregate("user-1", {
            handlers      = account_handlers,
            initial_state = { balance = 0, open = true, owner = "Alice" },
        })
        T.eq(agg:state().owner, "Alice")
        T.eq(agg:version(), 0)
    end)

    T.it("account_closed sets open = false", function()
        local store = make_store()
        store:append("user-1", "account_created", { owner = "Alice", initial_deposit = 100 })
        store:append("user-1", "account_closed",  {})

        local agg = ES.aggregate("user-1", {
            handlers      = account_handlers,
            initial_state = {},
        })
        agg:replay(store:events_for("user-1"))
        T.eq(agg:state().open, false)
        T.eq(agg:version(), 2)
    end)
end)

-- ── Projection ────────────────────────────────────────────────────────────────

T.describe("projection", function()
    T.it("builds cross-aggregate total balance", function()
        local store = make_store()
        store:append("user-1", "account_created", { owner = "Alice", initial_deposit = 500 })
        store:append("user-2", "account_created", { owner = "Bob",   initial_deposit = 300 })
        store:append("user-1", "deposit",         { amount = 100 })
        store:append("user-2", "withdrawal",      { amount = 50 })

        local proj = ES.projection("total_balance", {
            initial_state = { total = 0, accounts = {} },
            handlers = {
                account_created = function(state, event)
                    state.accounts[event.aggregate_id] = event.payload.initial_deposit or 0
                    state.total = state.total + (event.payload.initial_deposit or 0)
                    return state
                end,
                deposit = function(state, event)
                    state.accounts[event.aggregate_id] = (state.accounts[event.aggregate_id] or 0) + event.payload.amount
                    state.total = state.total + event.payload.amount
                    return state
                end,
                withdrawal = function(state, event)
                    state.accounts[event.aggregate_id] = (state.accounts[event.aggregate_id] or 0) - event.payload.amount
                    state.total = state.total - event.payload.amount
                    return state
                end,
            },
        })

        proj:handle_all(store:all_events())

        T.eq(proj:state().total, 500 + 300 + 100 - 50)
        T.eq(proj:state().accounts["user-1"], 600)
        T.eq(proj:state().accounts["user-2"], 250)
    end)

    T.it("checkpoint tracks last processed global_sequence", function()
        local store = make_store()
        store:append("user-1", "account_created", { owner = "Alice" })
        store:append("user-2", "account_created", { owner = "Bob" })
        store:append("user-1", "deposit", { amount = 10 })

        local proj = ES.projection("test_proj", { handlers = {}, initial_state = {} })
        T.eq(proj:checkpoint(), 0)

        proj:handle_all(store:all_events())
        T.eq(proj:checkpoint(), 3)
    end)

    T.it("checkpoint only advances for events with global_sequence", function()
        local proj = ES.projection("test_proj", { handlers = {}, initial_state = {} })
        -- Handle event without global_sequence — checkpoint stays 0.
        proj:handle({ event_type = "foo", payload = {} })
        T.eq(proj:checkpoint(), 0)
    end)

    T.it("incremental handle_all advances checkpoint correctly", function()
        local store = make_store()
        store:append("user-1", "account_created", {})
        store:append("user-1", "deposit", { amount = 10 })
        store:append("user-1", "deposit", { amount = 20 })

        local proj = ES.projection("inc_proj", { handlers = {}, initial_state = {} })
        -- Process only first two.
        local first_two = store:events_after(0)
        -- Slice to first two manually.
        proj:handle(first_two[1])
        proj:handle(first_two[2])
        T.eq(proj:checkpoint(), 2)

        -- Now process the rest.
        local remaining = store:events_after(proj:checkpoint())
        proj:handle_all(remaining)
        T.eq(proj:checkpoint(), 3)
    end)
end)

-- ── Snapshot Store ────────────────────────────────────────────────────────────

T.describe("snapshot_store", function()
    T.it("save and load round-trip", function()
        local snaps = ES.snapshot_store()
        snaps:save("user-1", { balance = 500, open = true }, 5)
        local loaded = snaps:load("user-1")
        T.ok(loaded ~= nil)
        T.eq(loaded.version, 5)
        T.eq(loaded.state.balance, 500)
        T.eq(loaded.state.open, true)
    end)

    T.it("load returns nil for unknown aggregate", function()
        local snaps = ES.snapshot_store()
        T.eq(snaps:load("nobody"), nil)
    end)

    T.it("latest returns the most recently saved snapshot", function()
        local snaps = ES.snapshot_store()
        snaps:save("user-1", { balance = 100 }, 3)
        snaps:save("user-2", { balance = 200 }, 7)
        snaps:save("user-3", { balance = 50 },  2)
        local lat = snaps:latest()
        T.ok(lat ~= nil)
        T.eq(lat.aggregate_id, "user-2")
        T.eq(lat.version, 7)
    end)

    T.it("latest returns nil when store is empty", function()
        local snaps = ES.snapshot_store()
        T.eq(snaps:latest(), nil)
    end)

    T.it("clear removes a snapshot", function()
        local snaps = ES.snapshot_store()
        snaps:save("user-1", { balance = 100 }, 3)
        snaps:clear("user-1")
        T.eq(snaps:load("user-1"), nil)
    end)

    T.it("clear recomputes latest correctly", function()
        local snaps = ES.snapshot_store()
        snaps:save("user-1", { balance = 100 }, 5)
        snaps:save("user-2", { balance = 200 }, 3)
        -- user-1 is latest (version=5); clear it.
        snaps:clear("user-1")
        local lat = snaps:latest()
        T.ok(lat ~= nil)
        T.eq(lat.aggregate_id, "user-2")
        T.eq(lat.version, 3)
    end)

    T.it("latest returns nil after clearing all snapshots", function()
        local snaps = ES.snapshot_store()
        snaps:save("user-1", {}, 1)
        snaps:clear("user-1")
        T.eq(snaps:latest(), nil)
    end)
end)

-- ── Saga ──────────────────────────────────────────────────────────────────────

T.describe("saga", function()
    -- Saga: CreateAccount → Deposit (initial funds) → done.
    local function make_account_onboarding_saga()
        return ES.saga("account_onboarding", {
            initial_state = { account_id = nil, funded = false },
            steps = {
                {
                    event_type = "account_created",
                    handler = function(state, event)
                        local new_state = { account_id = event.aggregate_id, funded = false }
                        local commands = {
                            ES.command("Deposit", { aggregate_id = event.aggregate_id, amount = 50 }),
                        }
                        return new_state, commands
                    end,
                },
                {
                    event_type = "deposit",
                    handler = function(state, event)
                        local new_state = { account_id = state.account_id, funded = true }
                        return new_state, {}
                    end,
                },
            },
        })
    end

    T.it("starts not done", function()
        local saga = make_account_onboarding_saga()
        T.eq(saga:done(), false)
    end)

    T.it("advances through steps and returns commands", function()
        local saga = make_account_onboarding_saga()
        local store = make_store()
        local ev1 = store:append("user-1", "account_created", { owner = "Alice" })

        local cmds = saga:handle(ev1)
        T.eq(#cmds, 1)
        T.eq(cmds[1].type, "Deposit")
        T.eq(cmds[1].payload.amount, 50)
        T.eq(saga:state().account_id, "user-1")
        T.eq(saga:done(), false)
    end)

    T.it("completes after final step", function()
        local saga = make_account_onboarding_saga()
        local store = make_store()
        local ev1 = store:append("user-1", "account_created", { owner = "Alice" })
        local ev2 = store:append("user-1", "deposit", { amount = 50 })

        saga:handle(ev1)
        saga:handle(ev2)

        T.eq(saga:done(), true)
        T.eq(saga:state().funded, true)
    end)

    T.it("ignores events for wrong step", function()
        local saga = make_account_onboarding_saga()
        local store = make_store()
        -- Send deposit before account_created — should be ignored.
        local ev_deposit = store:append("user-1", "deposit", { amount = 50 })
        local cmds = saga:handle(ev_deposit)
        T.eq(#cmds, 0)
        T.eq(saga:done(), false)
    end)

    T.it("does nothing when already done", function()
        local saga = make_account_onboarding_saga()
        local store = make_store()
        local ev1 = store:append("user-1", "account_created", { owner = "Alice" })
        local ev2 = store:append("user-1", "deposit", { amount = 50 })
        saga:handle(ev1)
        saga:handle(ev2)
        T.ok(saga:done())
        -- Extra event after done returns empty commands.
        local ev3 = store:append("user-1", "withdrawal", { amount = 10 })
        local cmds = saga:handle(ev3)
        T.eq(#cmds, 0)
    end)

    T.it("empty saga is immediately done", function()
        local saga = ES.saga("empty", { steps = {} })
        T.eq(saga:done(), true)
    end)
end)

-- ── Command ───────────────────────────────────────────────────────────────────

T.describe("command", function()
    T.it("has a unique id", function()
        local c1 = ES.command("CreateAccount", { owner = "Alice" })
        local c2 = ES.command("CreateAccount", { owner = "Bob" })
        T.ok(c1.id ~= nil)
        T.ok(c2.id ~= nil)
        T.ok(c1.id ~= c2.id)
    end)

    T.it("has a timestamp", function()
        local c = ES.command("Deposit", { amount = 100 })
        T.ok(type(c.timestamp) == "number")
        T.ok(c.timestamp > 0)
    end)

    T.it("stores type and payload", function()
        local c = ES.command("Withdraw", { amount = 50 }, { user_id = "admin" })
        T.eq(c.type, "Withdraw")
        T.eq(c.payload.amount, 50)
        T.eq(c.metadata.user_id, "admin")
    end)

    T.it("defaults payload and metadata to empty tables", function()
        local c = ES.command("Noop")
        T.ok(type(c.payload) == "table")
        T.ok(type(c.metadata) == "table")
    end)
end)

-- ── ES._tier ──────────────────────────────────────────────────────────────────

T.describe("module", function()
    T.it("_tier is pure", function()
        T.eq(ES._tier, "pure")
    end)
end)
