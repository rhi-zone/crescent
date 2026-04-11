if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local M = require("lib.csv_query")

-- ---------------------------------------------------------------------------
-- Test data
-- ---------------------------------------------------------------------------

local data = M.from_rows({
  { name = "Alice", age = 30, dept = "eng", salary = 90000 },
  { name = "Bob",   age = 25, dept = "mkt", salary = 60000 },
  { name = "Carol", age = 35, dept = "eng", salary = 110000 },
  { name = "Dave",  age = 28, dept = "mkt", salary = 65000 },
  { name = "Eve",   age = 30, dept = "eng", salary = 95000 },
})

-- ---------------------------------------------------------------------------
-- Basics
-- ---------------------------------------------------------------------------

T.describe("from_rows / count / columns", function()
  T.it("count", function()
    T.eq(data:count(), 5)
  end)
  T.it("columns returns array", function()
    local cols = data:columns()
    T.eq(type(cols), "table")
    T.ok(#cols >= 4)
  end)
  T.it("row access", function()
    local r = data:row(1)
    T.ok(r ~= nil)
    T.ok(r.name == "Alice" or r.name ~= nil)  -- first row has a name
  end)
  T.it("out of bounds row returns nil", function()
    T.eq(data:row(100), nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- from_arrays
-- ---------------------------------------------------------------------------

T.describe("from_arrays", function()
  T.it("basic", function()
    local df = M.from_arrays(
      { { "x", 1 }, { "y", 2 } },
      { "letter", "num" }
    )
    T.eq(df:count(), 2)
    local cols = df:columns()
    T.eq(cols[1], "letter")
    T.eq(cols[2], "num")
    T.eq(df:row(1).letter, "x")
    T.eq(df:row(2).num, 2)
  end)
end)

-- ---------------------------------------------------------------------------
-- SELECT
-- ---------------------------------------------------------------------------

T.describe("select", function()
  T.it("keeps only specified columns", function()
    local df = data:select("name", "age")
    T.eq(df:count(), 5)
    local cols = df:columns()
    T.eq(#cols, 2)
    T.eq(cols[1], "name")
    T.eq(cols[2], "age")
  end)
  T.it("drops other columns from rows", function()
    local df = data:select("name", "age")
    local r = df:row(1)
    T.eq(r.dept, nil)
    T.eq(r.salary, nil)
    T.ok(r.name ~= nil)
    T.ok(r.age ~= nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- WHERE
-- ---------------------------------------------------------------------------

T.describe("where", function()
  T.it("filters rows", function()
    local df = data:where(function(row) return row.age > 28 end)
    T.ok(df:count() < data:count())
    -- Alice(30), Carol(35), Eve(30) pass; Bob(25) and Dave(28) don't
    T.eq(df:count(), 3)
  end)
  T.it("all column values correct after filter", function()
    local df = data:where(function(row) return row.dept == "eng" end)
    T.eq(df:count(), 3)
    for _, row in ipairs(df:rows()) do
      T.eq(row.dept, "eng")
    end
  end)
  T.it("empty result", function()
    local df = data:where(function(row) return row.age > 100 end)
    T.eq(df:count(), 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- ORDER BY
-- ---------------------------------------------------------------------------

T.describe("order_by", function()
  T.it("sorts asc by default", function()
    local df = data:order_by("salary")
    local vals = df:col_values("salary")
    for i = 2, #vals do
      T.ok(vals[i] >= vals[i-1])
    end
  end)
  T.it("sorts desc", function()
    local df = data:order_by("salary", "desc")
    local vals = df:col_values("salary")
    T.eq(vals[1], 110000)
    T.eq(vals[#vals], 60000)
    for i = 2, #vals do
      T.ok(vals[i] <= vals[i-1])
    end
  end)
  T.it("sorts by function key", function()
    local df = data:order_by(function(row) return -row.age end)
    local ages = df:col_values("age")
    -- descending age
    for i = 2, #ages do
      T.ok(ages[i] <= ages[i-1])
    end
  end)
end)

-- ---------------------------------------------------------------------------
-- LIMIT / OFFSET
-- ---------------------------------------------------------------------------

T.describe("limit / offset", function()
  T.it("limit returns at most n rows", function()
    local df = data:limit(3)
    T.eq(df:count(), 3)
  end)
  T.it("limit larger than count returns all", function()
    local df = data:limit(100)
    T.eq(df:count(), data:count())
  end)
  T.it("offset skips rows", function()
    local df = data:offset(2)
    T.eq(df:count(), 3)
  end)
  T.it("offset then limit", function()
    local df = data:offset(1):limit(2)
    T.eq(df:count(), 2)
  end)
  T.it("offset beyond end", function()
    local df = data:offset(10)
    T.eq(df:count(), 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- COL VALUES
-- ---------------------------------------------------------------------------

T.describe("col_values", function()
  T.it("returns all values for a column", function()
    local names = data:col_values("name")
    T.eq(#names, 5)
    -- Check all names present
    local set = {}
    for _, n in ipairs(names) do set[n] = true end
    T.ok(set["Alice"])
    T.ok(set["Bob"])
    T.ok(set["Carol"])
    T.ok(set["Dave"])
    T.ok(set["Eve"])
  end)
end)

-- ---------------------------------------------------------------------------
-- GROUP BY
-- ---------------------------------------------------------------------------

T.describe("group_by", function()
  T.it("groups by dept with count", function()
    local df = data:group_by("dept", { cnt = { "count", nil } })
    T.eq(df:count(), 2)
    -- Build dept -> count map
    local m = {}
    for _, row in ipairs(df:rows()) do
      m[row.dept] = row.cnt
    end
    T.eq(m["eng"], 3)
    T.eq(m["mkt"], 2)
  end)
  T.it("groups with avg", function()
    local df = data:group_by("dept", { avg_sal = { "avg", "salary" } })
    local m = {}
    for _, row in ipairs(df:rows()) do m[row.dept] = row.avg_sal end
    -- eng: (90000+110000+95000)/3 = 98333.33...
    T.ok(m["eng"] > 98000 and m["eng"] < 99000)
    -- mkt: (60000+65000)/2 = 62500
    T.eq(m["mkt"], 62500)
  end)
  T.it("groups with sum", function()
    local df = data:group_by("dept", { total = { "sum", "salary" } })
    local m = {}
    for _, row in ipairs(df:rows()) do m[row.dept] = row.total end
    T.eq(m["eng"], 295000)
    T.eq(m["mkt"], 125000)
  end)
  T.it("groups with min/max", function()
    local df = data:group_by("dept", {
      mn = { "min", "salary" },
      mx = { "max", "salary" },
    })
    local m = {}
    for _, row in ipairs(df:rows()) do m[row.dept] = row end
    T.eq(m["eng"].mn, 90000)
    T.eq(m["eng"].mx, 110000)
    T.eq(m["mkt"].mn, 60000)
    T.eq(m["mkt"].mx, 65000)
  end)
  T.it("group by preserves group col in output", function()
    local df = data:group_by("dept", { cnt = { "count", nil } })
    local cols = df:columns()
    local has_dept = false
    for _, c in ipairs(cols) do if c == "dept" then has_dept = true end end
    T.ok(has_dept)
  end)
end)

-- ---------------------------------------------------------------------------
-- JOIN
-- ---------------------------------------------------------------------------

local dept_info = M.from_rows({
  { dept = "eng", budget = 500000 },
  { dept = "mkt", budget = 200000 },
  { dept = "hr",  budget = 100000 },
})

T.describe("join", function()
  T.it("inner join on dept", function()
    local df = data:join(dept_info, "dept")
    -- All 5 employees have dept in dept_info (eng/mkt), so 5 rows
    T.eq(df:count(), 5)
  end)
  T.it("join adds right columns", function()
    local df = data:join(dept_info, "dept")
    local r = df:row(1)
    T.ok(r.budget ~= nil)
  end)
  T.it("inner join excludes rows without match", function()
    -- Add an employee in dept "fin" which has no entry in dept_info
    local with_extra = M.from_rows({
      { name = "Frank", age = 40, dept = "fin", salary = 120000 },
    })
    local combined = M.from_rows({
      { name = "Alice", age = 30, dept = "eng", salary = 90000 },
      { name = "Frank", age = 40, dept = "fin", salary = 120000 },
    })
    local df = combined:join(dept_info, "dept")
    T.eq(df:count(), 1)  -- only Alice matches
    T.eq(df:row(1).name, "Alice")
  end)
  T.it("join with {left_col, right_col}", function()
    local other = M.from_rows({
      { department = "eng", floor = 3 },
      { department = "mkt", floor = 2 },
    })
    local df = data:join(other, { "dept", "department" })
    T.eq(df:count(), 5)
    local r = df:row(1)
    T.ok(r.floor ~= nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- LEFT JOIN
-- ---------------------------------------------------------------------------

T.describe("left_join", function()
  T.it("keeps all left rows", function()
    local left = M.from_rows({
      { name = "Alice", dept = "eng" },
      { name = "Zara",  dept = "unknown" },
    })
    local df = left:left_join(dept_info, "dept")
    T.eq(df:count(), 2)
  end)
  T.it("nil for missing right columns on unmatched rows", function()
    local left = M.from_rows({
      { name = "Alice", dept = "eng" },
      { name = "Zara",  dept = "unknown" },
    })
    local df = left:left_join(dept_info, "dept")
    -- Find Zara's row
    local zara_row
    for _, row in ipairs(df:rows()) do
      if row.name == "Zara" then zara_row = row end
    end
    T.ok(zara_row ~= nil)
    T.eq(zara_row.budget, nil)
  end)
  T.it("matched rows have right column values", function()
    local left = M.from_rows({
      { name = "Alice", dept = "eng" },
    })
    local df = left:left_join(dept_info, "dept")
    T.eq(df:row(1).budget, 500000)
  end)
end)

-- ---------------------------------------------------------------------------
-- DISTINCT
-- ---------------------------------------------------------------------------

T.describe("distinct", function()
  T.it("distinct on column removes duplicates", function()
    local df = data:distinct("dept")
    T.eq(df:count(), 2)
  end)
  T.it("distinct nil uses all columns", function()
    local df = M.from_rows({
      { a = 1, b = 2 },
      { a = 1, b = 2 },
      { a = 1, b = 3 },
    })
    T.eq(df:distinct():count(), 2)
  end)
  T.it("distinct preserves columns", function()
    local df = data:distinct("dept")
    local cols = df:columns()
    T.ok(#cols >= 4)
  end)
end)

-- ---------------------------------------------------------------------------
-- ADD COLUMN
-- ---------------------------------------------------------------------------

T.describe("add_column", function()
  T.it("adds computed column", function()
    local df = data:add_column("bonus", function(row) return row.salary * 0.1 end)
    T.eq(df:count(), 5)
    local r = df:row(1)
    T.ok(r.bonus ~= nil)
    -- Alice salary=90000, bonus=9000
    local alice
    for _, row in ipairs(df:rows()) do
      if row.name == "Alice" then alice = row end
    end
    T.eq(alice.bonus, 9000)
  end)
  T.it("original df unmodified", function()
    local _ = data:add_column("bonus", function(row) return row.salary * 0.1 end)
    T.eq(data:row(1).bonus, nil)
  end)
  T.it("new column appears in columns()", function()
    local df = data:add_column("bonus", function(row) return row.salary * 0.1 end)
    local cols = df:columns()
    local found = false
    for _, c in ipairs(cols) do if c == "bonus" then found = true end end
    T.ok(found)
  end)
end)

-- ---------------------------------------------------------------------------
-- DROP
-- ---------------------------------------------------------------------------

T.describe("drop", function()
  T.it("removes specified columns", function()
    local df = data:drop("salary")
    T.eq(df:row(1).salary, nil)
    T.ok(df:row(1).name ~= nil)
  end)
  T.it("columns() reflects drop", function()
    local df = data:drop("salary", "dept")
    local cols = df:columns()
    for _, c in ipairs(cols) do
      T.ok(c ~= "salary")
      T.ok(c ~= "dept")
    end
  end)
  T.it("count unchanged", function()
    local df = data:drop("salary")
    T.eq(df:count(), 5)
  end)
end)

-- ---------------------------------------------------------------------------
-- RENAME
-- ---------------------------------------------------------------------------

T.describe("rename", function()
  T.it("renames a column", function()
    local df = data:rename({ dept = "department" })
    T.eq(df:count(), 5)
    local r = df:row(1)
    T.ok(r.department ~= nil)
    T.eq(r.dept, nil)
  end)
  T.it("columns() reflects rename", function()
    local df = data:rename({ dept = "department" })
    local cols = df:columns()
    local found_new = false
    for _, c in ipairs(cols) do
      T.ok(c ~= "dept")
      if c == "department" then found_new = true end
    end
    T.ok(found_new)
  end)
  T.it("values preserved", function()
    local df = data:rename({ dept = "department" })
    -- Find Alice
    for _, row in ipairs(df:rows()) do
      if row.name == "Alice" then
        T.eq(row.department, "eng")
      end
    end
  end)
end)

-- ---------------------------------------------------------------------------
-- AGG (whole-table)
-- ---------------------------------------------------------------------------

T.describe("agg", function()
  T.it("sum of salaries", function()
    local result = data:agg({ total = { "sum", "salary" } })
    T.eq(result.total, 420000)
  end)
  T.it("count", function()
    local result = data:agg({ n = { "count", nil } })
    T.eq(result.n, 5)
  end)
  T.it("avg", function()
    local result = data:agg({ avg_age = { "avg", "age" } })
    -- (30+25+35+28+30)/5 = 148/5 = 29.6
    T.ok(math.abs(result.avg_age - 29.6) < 0.001)
  end)
  T.it("min/max", function()
    local result = data:agg({
      min_sal = { "min", "salary" },
      max_sal = { "max", "salary" },
    })
    T.eq(result.min_sal, 60000)
    T.eq(result.max_sal, 110000)
  end)
end)

-- ---------------------------------------------------------------------------
-- DESCRIBE
-- ---------------------------------------------------------------------------

T.describe("describe", function()
  T.it("returns stats for numeric columns", function()
    local stats = data:describe()
    T.ok(stats["age"] ~= nil)
    T.ok(stats["salary"] ~= nil)
    -- Non-numeric columns should not appear
    T.eq(stats["name"], nil)
    T.eq(stats["dept"], nil)
  end)
  T.it("age stats correct", function()
    local stats = data:describe()
    local s = stats["age"]
    T.eq(s.count, 5)
    T.eq(s.min, 25)
    T.eq(s.max, 35)
    T.ok(math.abs(s.mean - 29.6) < 0.001)
    T.ok(s.stddev > 0)
  end)
  T.it("salary stats correct", function()
    local stats = data:describe()
    local s = stats["salary"]
    T.eq(s.min, 60000)
    T.eq(s.max, 110000)
    T.eq(s.count, 5)
  end)
end)

-- ---------------------------------------------------------------------------
-- FROM CSV / TO CSV
-- ---------------------------------------------------------------------------

T.describe("from_csv / to_csv", function()
  T.it("from_csv parses correctly", function()
    local csv_str = "name,age,score\nAlice,30,9.5\nBob,25,8.0\n"
    local df, err = M.from_csv(csv_str)
    T.ok(err == nil)
    T.ok(df ~= nil)
    T.eq(df:count(), 2)
  end)
  T.it("from_csv values coerced", function()
    local csv_str = "name,age\nAlice,30\nBob,25\n"
    local df = M.from_csv(csv_str)
    local ages = df:col_values("age")
    T.eq(type(ages[1]), "number")
    T.eq(ages[1], 30)
  end)
  T.it("to_csv produces header row", function()
    local df = data:select("name", "dept")
    local csv_out = df:to_csv()
    T.ok(type(csv_out) == "string")
    T.ok(csv_out:find("name") ~= nil)
    T.ok(csv_out:find("dept") ~= nil)
  end)
  T.it("to_csv round-trip preserves row count", function()
    local df = data:select("name", "age")
    local csv_out = df:to_csv()
    local df2, err = M.from_csv(csv_out)
    T.ok(err == nil)
    T.eq(df2:count(), df:count())
  end)
  T.it("to_csv round-trip preserves values", function()
    local simple = M.from_rows({
      { x = "hello", y = 42 },
      { x = "world", y = 7  },
    })
    local csv_out = simple:to_csv()
    local df2 = M.from_csv(csv_out)
    T.eq(df2:count(), 2)
    local xs = df2:col_values("x")
    local ys = df2:col_values("y")
    T.eq(xs[1], "hello")
    T.eq(xs[2], "world")
    T.eq(ys[1], 42)
    T.eq(ys[2], 7)
  end)
  T.it("from_csv error on non-string", function()
    local df, err = M.from_csv(42)
    T.eq(df, nil)
    T.ok(err ~= nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- Chained operations
-- ---------------------------------------------------------------------------

T.describe("chained operations", function()
  T.it("where + order_by + limit", function()
    local df = data
      :where(function(row) return row.dept == "eng" end)
      :order_by("salary", "desc")
      :limit(2)
    T.eq(df:count(), 2)
    local sals = df:col_values("salary")
    T.ok(sals[1] >= sals[2])
  end)
  T.it("add_column + group_by", function()
    local df = data
      :add_column("bonus", function(row) return row.salary * 0.1 end)
      :group_by("dept", { total_bonus = { "sum", "bonus" } })
    local m = {}
    for _, row in ipairs(df:rows()) do m[row.dept] = row.total_bonus end
    T.ok(m["eng"] > 0)
    T.ok(m["mkt"] > 0)
  end)
  T.it("select + rename + distinct", function()
    local df = data
      :select("dept")
      :rename({ dept = "department" })
      :distinct("department")
    T.eq(df:count(), 2)
    local cols = df:columns()
    T.eq(cols[1], "department")
  end)
  T.it("join + where + select", function()
    local df = data
      :join(dept_info, "dept")
      :where(function(row) return row.budget > 300000 end)
      :select("name", "budget")
    T.eq(df:count(), 3)  -- 3 eng employees
    local r = df:row(1)
    T.ok(r.name ~= nil)
    T.ok(r.budget ~= nil)
    T.eq(r.dept, nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- Immutability
-- ---------------------------------------------------------------------------

T.describe("immutability", function()
  T.it("where does not modify original", function()
    local orig_count = data:count()
    local _ = data:where(function(row) return row.age > 100 end)
    T.eq(data:count(), orig_count)
  end)
  T.it("add_column does not modify original", function()
    local _ = data:add_column("x", function() return 1 end)
    T.eq(data:row(1).x, nil)
  end)
  T.it("drop does not modify original", function()
    local _ = data:drop("name")
    T.ok(data:row(1).name ~= nil)
  end)
end)
