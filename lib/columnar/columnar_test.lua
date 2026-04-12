if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local col = require("lib.columnar")

local function make_table()
  return col.table({
    columns = {
      {name = "id",     type = "integer"},
      {name = "name",   type = "string"},
      {name = "score",  type = "number"},
      {name = "active", type = "boolean"},
    }
  })
end

T.describe("columnar", function()

  T.it("create table and insert rows, count", function()
    local t = make_table()
    T.ok(t ~= nil)
    T.eq(t:count(), 0)
    t:insert({id = 1, name = "Alice", score = 95.5, active = true})
    T.eq(t:count(), 1)
    t:insert({id = 2, name = "Bob", score = 87.2, active = false})
    T.eq(t:count(), 2)
  end)

  T.it("insert_many", function()
    local t = make_table()
    t:insert_many({
      {id = 1, name = "Alice", score = 95.5, active = true},
      {id = 2, name = "Bob",   score = 87.2, active = false},
      {id = 3, name = "Carol", score = 91.0, active = true},
    })
    T.eq(t:count(), 3)
  end)

  T.it("column() returns correct array", function()
    local t = make_table()
    t:insert({id = 1, name = "Alice", score = 95.5, active = true})
    t:insert({id = 2, name = "Bob",   score = 87.2, active = false})
    local scores = t:column("score")
    T.eq(#scores, 2)
    T.eq(scores[1], 95.5)
    T.eq(scores[2], 87.2)
    local names = t:column("name")
    T.eq(names[1], "Alice")
    T.eq(names[2], "Bob")
  end)

  T.it("column() returns nil for unknown column", function()
    local t = make_table()
    local result, err = t:column("nope")
    T.eq(result, nil)
    T.ok(err ~= nil)
  end)

  T.it("row() returns correct table", function()
    local t = make_table()
    t:insert({id = 1, name = "Alice", score = 95.5, active = true})
    t:insert({id = 2, name = "Bob",   score = 87.2, active = false})
    local r1 = t:row(1)
    T.eq(r1.id, 1)
    T.eq(r1.name, "Alice")
    T.eq(r1.score, 95.5)
    T.eq(r1.active, true)
    local r2 = t:row(2)
    T.eq(r2.id, 2)
    T.eq(r2.name, "Bob")
    T.eq(r2.active, false)
  end)

  T.it("row() returns nil for out-of-range index", function()
    local t = make_table()
    local result, err = t:row(1)
    T.eq(result, nil)
    T.ok(err ~= nil)
  end)

  T.it("select() with where filter", function()
    local t = make_table()
    t:insert_many({
      {id = 1, name = "Alice", score = 95.5, active = true},
      {id = 2, name = "Bob",   score = 87.2, active = false},
      {id = 3, name = "Carol", score = 91.0, active = true},
    })
    local result = t:select({ where = function(row) return row.score > 90 end })
    T.eq(#result, 2)
    T.eq(result[1].name, "Alice")
    T.eq(result[2].name, "Carol")
  end)

  T.it("select() with columns projection", function()
    local t = make_table()
    t:insert_many({
      {id = 1, name = "Alice", score = 95.5, active = true},
      {id = 2, name = "Bob",   score = 87.2, active = false},
    })
    local result = t:select({ columns = {"name", "score"} })
    T.eq(#result, 2)
    T.eq(result[1].name, "Alice")
    T.eq(result[1].score, 95.5)
    T.eq(result[1].id, nil)
    T.eq(result[1].active, nil)
  end)

  T.it("select() with order_by ascending", function()
    local t = make_table()
    t:insert_many({
      {id = 1, name = "Alice", score = 95.5, active = true},
      {id = 2, name = "Bob",   score = 87.2, active = false},
      {id = 3, name = "Carol", score = 91.0, active = true},
    })
    local result = t:select({ order_by = "score" })
    T.eq(result[1].score, 87.2)
    T.eq(result[2].score, 91.0)
    T.eq(result[3].score, 95.5)
  end)

  T.it("select() with order_by descending", function()
    local t = make_table()
    t:insert_many({
      {id = 1, name = "Alice", score = 95.5, active = true},
      {id = 2, name = "Bob",   score = 87.2, active = false},
      {id = 3, name = "Carol", score = 91.0, active = true},
    })
    local result = t:select({ order_by = "score", desc = true })
    T.eq(result[1].score, 95.5)
    T.eq(result[2].score, 91.0)
    T.eq(result[3].score, 87.2)
  end)

  T.it("select() with limit", function()
    local t = make_table()
    t:insert_many({
      {id = 1, name = "Alice", score = 95.5, active = true},
      {id = 2, name = "Bob",   score = 87.2, active = false},
      {id = 3, name = "Carol", score = 91.0, active = true},
    })
    local result = t:select({ limit = 2 })
    T.eq(#result, 2)
  end)

  T.it("select() with where + order_by + limit combined", function()
    local t = make_table()
    t:insert_many({
      {id = 1, name = "Alice", score = 95.5, active = true},
      {id = 2, name = "Bob",   score = 87.2, active = false},
      {id = 3, name = "Carol", score = 91.0, active = true},
      {id = 4, name = "Dave",  score = 78.0, active = true},
    })
    local result = t:select({
      where = function(row) return row.active end,
      order_by = "score",
      desc = true,
      limit = 2,
    })
    T.eq(#result, 2)
    T.eq(result[1].name, "Alice")
    T.eq(result[2].name, "Carol")
  end)

  T.it("aggregate() count per group", function()
    local t = make_table()
    t:insert_many({
      {id = 1, name = "Alice", score = 95.5, active = true},
      {id = 2, name = "Bob",   score = 87.2, active = false},
      {id = 3, name = "Carol", score = 91.0, active = true},
    })
    local agg = t:aggregate({
      group_by = "active",
      aggregations = { count = col.count() }
    })
    T.eq(#agg, 2)
    -- Find the true group
    local true_group, false_group
    for _, g in ipairs(agg) do
      if g.active == true then true_group = g
      elseif g.active == false then false_group = g
      end
    end
    T.ok(true_group ~= nil)
    T.ok(false_group ~= nil)
    T.eq(true_group.count, 2)
    T.eq(false_group.count, 1)
  end)

  T.it("aggregate() avg/sum/min/max per group", function()
    local t = make_table()
    t:insert_many({
      {id = 1, name = "Alice", score = 95.5, active = true},
      {id = 2, name = "Bob",   score = 87.2, active = false},
      {id = 3, name = "Carol", score = 91.0, active = true},
    })
    local agg = t:aggregate({
      group_by = "active",
      aggregations = {
        total = col.sum("score"),
        avg   = col.avg("score"),
        best  = col.max("score"),
        worst = col.min("score"),
      }
    })
    local true_group
    for _, g in ipairs(agg) do
      if g.active == true then true_group = g end
    end
    T.ok(true_group ~= nil)
    -- Alice=95.5, Carol=91.0
    T.eq(true_group.total, 186.5)
    T.eq(true_group.avg, 93.25)
    T.eq(true_group.best, 95.5)
    T.eq(true_group.worst, 91.0)
  end)

  T.it("stats() on a numeric column", function()
    local t = make_table()
    t:insert_many({
      {id = 1, name = "Alice", score = 10.0, active = true},
      {id = 2, name = "Bob",   score = 20.0, active = false},
      {id = 3, name = "Carol", score = 30.0, active = true},
    })
    local s = t:stats("score")
    T.eq(s.min, 10.0)
    T.eq(s.max, 30.0)
    T.eq(s.sum, 60.0)
    T.eq(s.mean, 20.0)
    T.eq(s.count, 3)
    T.eq(s.nulls, 0)
    T.ok(s.stddev ~= nil)
    -- stddev of [10,20,30] sample = 10
    T.eq(math.floor(s.stddev + 0.5), 10)
  end)

  T.it("stats() counts nulls", function()
    local t = col.table({
      columns = {
        {name = "val", type = "number"},
      }
    })
    t:insert({val = 5.0})
    t:insert({val = nil})
    t:insert({val = 15.0})
    local s = t:stats("val")
    T.eq(s.count, 2)
    T.eq(s.nulls, 1)
    T.eq(s.sum, 20.0)
  end)

  T.it("add_column with default fills existing rows", function()
    local t = make_table()
    t:insert_many({
      {id = 1, name = "Alice", score = 95.5, active = true},
      {id = 2, name = "Bob",   score = 87.2, active = false},
    })
    t:add_column({name = "grade", type = "string", default = "C"})
    T.eq(t:count(), 2)
    local r1 = t:row(1)
    T.eq(r1.grade, "C")
    local r2 = t:row(2)
    T.eq(r2.grade, "C")
    -- schema includes new column
    local schema = t:schema()
    local found = false
    for _, col_def in ipairs(schema) do
      if col_def.name == "grade" then found = true end
    end
    T.ok(found)
  end)

  T.it("drop_column removes column from rows and schema", function()
    local t = make_table()
    t:insert({id = 1, name = "Alice", score = 95.5, active = true})
    t:drop_column("score")
    local r1 = t:row(1)
    T.eq(r1.score, nil)
    T.eq(r1.id, 1)
    local schema = t:schema()
    local found = false
    for _, col_def in ipairs(schema) do
      if col_def.name == "score" then found = true end
    end
    T.ok(not found)
  end)

  T.it("drop_column returns error for unknown column", function()
    local t = make_table()
    local ok, err = t:drop_column("nonexistent")
    T.eq(ok, nil)
    T.ok(err ~= nil)
  end)

  T.it("delete() removes matching rows", function()
    local t = make_table()
    t:insert_many({
      {id = 1, name = "Alice", score = 95.5, active = true},
      {id = 2, name = "Bob",   score = 87.2, active = false},
      {id = 3, name = "Carol", score = 91.0, active = true},
    })
    t:delete(function(row) return not row.active end)
    T.eq(t:count(), 2)
    local ids = t:column("id")
    T.eq(ids[1], 1)
    T.eq(ids[2], 3)
  end)

  T.it("delete() removes all rows when all match", function()
    local t = make_table()
    t:insert_many({
      {id = 1, name = "Alice", score = 95.5, active = true},
      {id = 2, name = "Bob",   score = 87.2, active = false},
    })
    t:delete(function(_) return true end)
    T.eq(t:count(), 0)
  end)

  T.it("schema() returns column definitions", function()
    local t = make_table()
    local schema = t:schema()
    T.eq(#schema, 4)
    T.eq(schema[1].name, "id")
    T.eq(schema[1].type, "integer")
    T.eq(schema[2].name, "name")
    T.eq(schema[2].type, "string")
    T.eq(schema[3].name, "score")
    T.eq(schema[3].type, "number")
    T.eq(schema[4].name, "active")
    T.eq(schema[4].type, "boolean")
  end)

  T.it("large table (1000 rows) select correctness", function()
    local t = col.table({
      columns = {
        {name = "i",   type = "integer"},
        {name = "val", type = "number"},
      }
    })
    local rows = {}
    for i = 1, 1000 do
      rows[i] = { i = i, val = i * 1.5 }
    end
    t:insert_many(rows)
    T.eq(t:count(), 1000)

    -- Select even indices
    local result = t:select({ where = function(row) return row.i % 2 == 0 end })
    T.eq(#result, 500)
    T.eq(result[1].i, 2)
    T.eq(result[500].i, 1000)
  end)

  T.it("large table (1000 rows) aggregate correctness", function()
    local t = col.table({
      columns = {
        {name = "bucket", type = "integer"},
        {name = "val",    type = "number"},
      }
    })
    local rows = {}
    for i = 1, 1000 do
      rows[i] = { bucket = (i - 1) % 5 + 1, val = i }
    end
    t:insert_many(rows)

    local agg = t:aggregate({
      group_by = "bucket",
      aggregations = {
        cnt = col.count(),
        s   = col.sum("val"),
      }
    })
    T.eq(#agg, 5)
    local total = 0
    for _, g in ipairs(agg) do
      T.eq(g.cnt, 200)
      total = total + g.s
    end
    -- sum of 1..1000 = 500500
    T.eq(total, 500500)
  end)

  T.it("type validation rejects wrong types", function()
    local t = make_table()
    local ok, err = t:insert({id = "not_a_number", name = "X", score = 1.0, active = true})
    T.eq(ok, nil)
    T.ok(err ~= nil)
  end)

  T.it("aggregate() with no group_by aggregates all rows", function()
    local t = make_table()
    t:insert_many({
      {id = 1, name = "Alice", score = 10.0, active = true},
      {id = 2, name = "Bob",   score = 20.0, active = false},
      {id = 3, name = "Carol", score = 30.0, active = true},
    })
    local agg = t:aggregate({
      aggregations = {
        cnt   = col.count(),
        total = col.sum("score"),
      }
    })
    T.eq(#agg, 1)
    T.eq(agg[1].cnt, 3)
    T.eq(agg[1].total, 60.0)
  end)

end)
