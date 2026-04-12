-- lib/reactive_db/reactive_db_test.lua
-- Tests for the reactive in-memory relational database.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local rdb = require("lib.reactive_db")
local T   = require("lib.test.assert")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function make_db()
  local db    = rdb.database()
  local users = db:table("users", {
    schema      = { id = "number", name = "string", age = "number", active = "boolean" },
    primary_key = "id",
  })
  return db, users
end

-- ── Insert and get ────────────────────────────────────────────────────────────

T.describe("insert and get", function()
  T.it("inserts a row and retrieves it by primary key", function()
    local _, users = make_db()
    users:insert({ id = 1, name = "Alice", age = 30, active = true })
    local row = users:get(1)
    T.ok(row ~= nil, "row should exist")
    T.eq(row.name, "Alice")
    T.eq(row.age, 30)
    T.eq(row.active, true)
  end)

  T.it("returns nil for unknown primary key", function()
    local _, users = make_db()
    T.eq(users:get(99), nil)
  end)

  T.it("returns error on duplicate primary key", function()
    local _, users = make_db()
    users:insert({ id = 1, name = "Alice", age = 30, active = true })
    local ok, err = users:insert({ id = 1, name = "Duplicate", age = 0, active = false })
    T.eq(ok, nil)
    T.ok(err ~= nil, "should return error message")
  end)
end)

-- ── where (table predicate) ───────────────────────────────────────────────────

T.describe("where table predicate", function()
  T.it("filters rows matching all fields", function()
    local _, users = make_db()
    users:insert({ id = 1, name = "Alice", age = 30, active = true })
    users:insert({ id = 2, name = "Bob",   age = 25, active = false })
    users:insert({ id = 3, name = "Carol", age = 28, active = true })

    local result = users:where({ active = true }):select()
    T.eq(#result, 2)
    -- names should be Alice and Carol (order may vary, sort for determinism)
    local names = {}
    for _, r in ipairs(result) do names[#names + 1] = r.name end
    table.sort(names)
    T.eq(names[1], "Alice")
    T.eq(names[2], "Carol")
  end)

  T.it("returns empty table when nothing matches", function()
    local _, users = make_db()
    users:insert({ id = 1, name = "Alice", age = 30, active = true })
    local result = users:where({ active = false }):select()
    T.eq(#result, 0)
  end)
end)

-- ── where (function predicate) ───────────────────────────────────────────────

T.describe("where function predicate", function()
  T.it("filters rows using function", function()
    local _, users = make_db()
    users:insert({ id = 1, name = "Alice", age = 30, active = true })
    users:insert({ id = 2, name = "Bob",   age = 25, active = false })
    users:insert({ id = 3, name = "Carol", age = 28, active = true })

    local result = users:where(function(row) return row.age > 27 end):select()
    T.eq(#result, 2)
    local names = {}
    for _, r in ipairs(result) do names[#names + 1] = r.name end
    table.sort(names)
    T.eq(names[1], "Alice")
    T.eq(names[2], "Carol")
  end)
end)

-- ── order_by ─────────────────────────────────────────────────────────────────

T.describe("order_by", function()
  T.it("sorts ascending by default", function()
    local _, users = make_db()
    users:insert({ id = 1, name = "Alice", age = 30, active = true })
    users:insert({ id = 2, name = "Bob",   age = 25, active = false })
    users:insert({ id = 3, name = "Carol", age = 28, active = true })

    local result = users:order_by("age"):select()
    T.eq(result[1].name, "Bob")
    T.eq(result[2].name, "Carol")
    T.eq(result[3].name, "Alice")
  end)

  T.it("sorts descending with 'desc'", function()
    local _, users = make_db()
    users:insert({ id = 1, name = "Alice", age = 30, active = true })
    users:insert({ id = 2, name = "Bob",   age = 25, active = false })
    users:insert({ id = 3, name = "Carol", age = 28, active = true })

    local result = users:order_by("age", "desc"):select()
    T.eq(result[1].name, "Alice")
    T.eq(result[2].name, "Carol")
    T.eq(result[3].name, "Bob")
  end)
end)

-- ── limit + offset ────────────────────────────────────────────────────────────

T.describe("limit and offset", function()
  T.it("limit returns only first N rows", function()
    local _, users = make_db()
    for i = 1, 5 do
      users:insert({ id = i, name = "User" .. i, age = 20 + i, active = true })
    end
    local result = users:order_by("age"):limit(3):select()
    T.eq(#result, 3)
    T.eq(result[1].age, 21)
    T.eq(result[3].age, 23)
  end)

  T.it("offset skips rows", function()
    local _, users = make_db()
    for i = 1, 5 do
      users:insert({ id = i, name = "User" .. i, age = 20 + i, active = true })
    end
    local result = users:order_by("age"):offset(2):select()
    T.eq(#result, 3)
    T.eq(result[1].age, 23)
  end)

  T.it("limit + offset combined", function()
    local _, users = make_db()
    for i = 1, 5 do
      users:insert({ id = i, name = "User" .. i, age = 20 + i, active = true })
    end
    local result = users:order_by("age"):offset(1):limit(2):select()
    T.eq(#result, 2)
    T.eq(result[1].age, 22)
    T.eq(result[2].age, 23)
  end)
end)

-- ── count() and first() ───────────────────────────────────────────────────────

T.describe("count and first", function()
  T.it("count returns number of matching rows", function()
    local _, users = make_db()
    users:insert({ id = 1, name = "Alice", age = 30, active = true })
    users:insert({ id = 2, name = "Bob",   age = 25, active = false })
    T.eq(users:where({ active = true }):count(), 1)
    T.eq(users:count(), 2)
  end)

  T.it("first returns the first matching row or nil", function()
    local _, users = make_db()
    users:insert({ id = 1, name = "Alice", age = 30, active = true })
    users:insert({ id = 2, name = "Bob",   age = 25, active = false })
    local row = users:order_by("age"):first()
    T.ok(row ~= nil)
    T.eq(row.name, "Bob")
    local none = users:where({ age = 99 }):first()
    T.eq(none, nil)
  end)
end)

-- ── update ────────────────────────────────────────────────────────────────────

T.describe("update", function()
  T.it("patches specific fields and leaves others unchanged", function()
    local _, users = make_db()
    users:insert({ id = 1, name = "Alice", age = 30, active = true })
    users:update(1, { age = 31 })
    local row = users:get(1)
    T.eq(row.age, 31)
    T.eq(row.name, "Alice")   -- unchanged
    T.eq(row.active, true)    -- unchanged
  end)

  T.it("returns error for missing primary key", function()
    local _, users = make_db()
    local ok, err = users:update(999, { age = 1 })
    T.eq(ok, nil)
    T.ok(err ~= nil)
  end)
end)

-- ── upsert ────────────────────────────────────────────────────────────────────

T.describe("upsert", function()
  T.it("inserts a new row when pk does not exist", function()
    local _, users = make_db()
    users:upsert({ id = 1, name = "Alice", age = 30, active = true })
    T.ok(users:get(1) ~= nil)
    T.eq(users:count(), 1)
  end)

  T.it("updates existing row when pk exists", function()
    local _, users = make_db()
    users:insert({ id = 1, name = "Alice", age = 30, active = true })
    users:upsert({ id = 1, name = "Alice", age = 31, active = true })
    T.eq(users:count(), 1)
    T.eq(users:get(1).age, 31)
  end)
end)

-- ── delete ────────────────────────────────────────────────────────────────────

T.describe("delete", function()
  T.it("removes a row so it is not found after", function()
    local _, users = make_db()
    users:insert({ id = 1, name = "Alice", age = 30, active = true })
    users:delete(1)
    T.eq(users:get(1), nil)
    T.eq(users:count(), 0)
  end)

  T.it("returns error when row does not exist", function()
    local _, users = make_db()
    local ok, err = users:delete(99)
    T.eq(ok, nil)
    T.ok(err ~= nil)
  end)
end)

-- ── subscribe ─────────────────────────────────────────────────────────────────

T.describe("subscribe", function()
  T.it("fires on insert with event='insert' and correct row", function()
    local _, users = make_db()
    local events = {}
    users:subscribe(function(event, row, old_row)
      events[#events + 1] = { event = event, row = row, old_row = old_row }
    end)
    users:insert({ id = 1, name = "Alice", age = 30, active = true })
    T.eq(#events, 1)
    T.eq(events[1].event, "insert")
    T.eq(events[1].row.name, "Alice")
    T.eq(events[1].old_row, nil)
  end)

  T.it("fires on update with old and new rows", function()
    local _, users = make_db()
    local events = {}
    users:insert({ id = 1, name = "Alice", age = 30, active = true })
    users:subscribe(function(event, row, old_row)
      events[#events + 1] = { event = event, row = row, old_row = old_row }
    end)
    users:update(1, { age = 31 })
    T.eq(#events, 1)
    T.eq(events[1].event, "update")
    T.eq(events[1].row.age, 31)
    T.eq(events[1].old_row.age, 30)
  end)

  T.it("fires on delete with old row", function()
    local _, users = make_db()
    local events = {}
    users:insert({ id = 1, name = "Alice", age = 30, active = true })
    users:subscribe(function(event, row, old_row)
      events[#events + 1] = { event = event, row = row, old_row = old_row }
    end)
    users:delete(1)
    T.eq(#events, 1)
    T.eq(events[1].event, "delete")
    T.eq(events[1].row, nil)
    T.eq(events[1].old_row.name, "Alice")
  end)

  T.it("unsub stops callbacks", function()
    local _, users = make_db()
    local count = 0
    local unsub = users:subscribe(function() count = count + 1 end)
    users:insert({ id = 1, name = "Alice", age = 30, active = true })
    T.eq(count, 1)
    unsub()
    users:insert({ id = 2, name = "Bob", age = 25, active = false })
    T.eq(count, 1)  -- no new calls after unsub
  end)
end)

-- ── live_query ────────────────────────────────────────────────────────────────

T.describe("live_query", function()
  T.it("called immediately with current matching rows", function()
    local _, users = make_db()
    users:insert({ id = 1, name = "Alice", age = 30, active = true })
    users:insert({ id = 2, name = "Bob",   age = 25, active = false })

    local calls = {}
    local live = users:live_query({ active = true }, function(rows)
      calls[#calls + 1] = rows
    end)
    T.eq(#calls, 1)
    T.eq(#calls[1], 1)
    T.eq(calls[1][1].name, "Alice")
    live:destroy()
  end)

  T.it("updates when a matching row is inserted", function()
    local _, users = make_db()
    users:insert({ id = 1, name = "Alice", age = 30, active = true })

    local last_rows
    local live = users:live_query({ active = true }, function(rows)
      last_rows = rows
    end)
    T.eq(#last_rows, 1)

    users:insert({ id = 2, name = "Carol", age = 28, active = true })
    T.eq(#last_rows, 2)
    live:destroy()
  end)

  T.it("updates when a matching row is deleted", function()
    local _, users = make_db()
    users:insert({ id = 1, name = "Alice", age = 30, active = true })
    users:insert({ id = 2, name = "Bob",   age = 25, active = false })

    local last_rows
    local live = users:live_query({ active = true }, function(rows)
      last_rows = rows
    end)
    T.eq(#last_rows, 1)

    users:delete(1)
    T.eq(#last_rows, 0)
    live:destroy()
  end)

  T.it("destroy stops further updates", function()
    local _, users = make_db()
    local call_count = 0
    local live = users:live_query({ active = true }, function(_)
      call_count = call_count + 1
    end)
    T.eq(call_count, 1)  -- immediate call
    live:destroy()
    users:insert({ id = 1, name = "Alice", age = 30, active = true })
    T.eq(call_count, 1)  -- no further calls after destroy
  end)
end)

-- ── join ──────────────────────────────────────────────────────────────────────

T.describe("join", function()
  T.it("merges rows from two tables on matching fields", function()
    local db, users = make_db()
    local orders = db:table("orders", {
      schema      = { id = "number", user_id = "number", total = "number" },
      primary_key = "id",
    })

    users:insert({ id = 1, name = "Alice", age = 30, active = true })
    users:insert({ id = 2, name = "Bob",   age = 25, active = false })
    orders:insert({ id = 101, user_id = 1, total = 50 })
    orders:insert({ id = 102, user_id = 1, total = 75 })
    orders:insert({ id = 103, user_id = 2, total = 20 })

    local result = users:join(orders, "id", "user_id"):select()
    T.eq(#result, 3)

    -- Collect totals for Alice (user_id=1)
    local alice_totals = {}
    for _, r in ipairs(result) do
      if r.name == "Alice" then alice_totals[#alice_totals + 1] = r.total end
    end
    table.sort(alice_totals)
    T.eq(alice_totals[1], 50)
    T.eq(alice_totals[2], 75)

    -- Bob has one order
    local bob_rows = {}
    for _, r in ipairs(result) do
      if r.name == "Bob" then bob_rows[#bob_rows + 1] = r end
    end
    T.eq(#bob_rows, 1)
    T.eq(bob_rows[1].total, 20)
  end)
end)

-- ── index ─────────────────────────────────────────────────────────────────────

T.describe("index", function()
  T.it("indexed query returns same results as full scan", function()
    local _, users = make_db()
    users:insert({ id = 1, name = "Alice", age = 30, active = true })
    users:insert({ id = 2, name = "Bob",   age = 25, active = false })
    users:insert({ id = 3, name = "Carol", age = 28, active = true })

    -- Get results without index (full scan)
    local before = users:where({ active = true }):select()
    local before_names = {}
    for _, r in ipairs(before) do before_names[#before_names + 1] = r.name end
    table.sort(before_names)

    -- Create index
    users:index("active")

    -- Get results with index present
    local after = users:where({ active = true }):select()
    local after_names = {}
    for _, r in ipairs(after) do after_names[#after_names + 1] = r.name end
    table.sort(after_names)

    T.eq(#before_names, #after_names)
    for i = 1, #before_names do
      T.eq(before_names[i], after_names[i])
    end
  end)

  T.it("index reflects new insertions", function()
    local _, users = make_db()
    users:index("age")
    users:insert({ id = 1, name = "Alice", age = 30, active = true })
    users:insert({ id = 2, name = "Bob",   age = 25, active = false })

    local result = users:where({ age = 30 }):select()
    T.eq(#result, 1)
    T.eq(result[1].name, "Alice")
  end)
end)

-- ── transaction ───────────────────────────────────────────────────────────────

T.describe("transaction", function()
  T.it("commit: all mutations applied", function()
    local db, users = make_db()
    users:insert({ id = 1, name = "Alice", age = 30, active = true })

    db:transaction(function()
      users:insert({ id = 4, name = "Dave", age = 35, active = true })
      users:delete(1)
    end)

    T.eq(users:get(1), nil)
    T.ok(users:get(4) ~= nil)
    T.eq(users:get(4).name, "Dave")
  end)

  T.it("rollback: no mutations on error", function()
    local db, users = make_db()
    users:insert({ id = 1, name = "Alice", age = 30, active = true })

    db:transaction(function()
      users:insert({ id = 4, name = "Dave", age = 35, active = true })
      error("something went wrong")
    end)

    -- Alice still present
    T.ok(users:get(1) ~= nil)
    T.eq(users:get(1).name, "Alice")
    -- Dave was rolled back
    T.eq(users:get(4), nil)
    T.eq(users:count(), 1)
  end)
end)
