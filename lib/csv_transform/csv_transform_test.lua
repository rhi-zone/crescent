if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local CT = require("lib.csv_transform")

local describe, it = T.describe, T.it

-- ── parse ──────────────────────────────────────────────────────────────────────

describe("csv_transform.parse", function()
	it("parses simple CSV", function()
		local rows = CT.parse("name,age\nAlice,30\nBob,25\n")
		T.eq(#rows, 2)
		T.eq(rows[1].name, "Alice")
		T.eq(rows[1].age, "30")
		T.eq(rows[2].name, "Bob")
		T.eq(rows[2].age, "25")
	end)

	it("parses CSV without trailing newline", function()
		local rows = CT.parse("name,age\nAlice,30")
		T.eq(#rows, 1)
		T.eq(rows[1].name, "Alice")
	end)

	it("parses quoted fields containing commas", function()
		local rows = CT.parse('city,note\nNYC,"big, city"\nLA,sunny\n')
		T.eq(rows[1].note, "big, city")
		T.eq(rows[2].note, "sunny")
	end)

	it("parses quoted fields containing embedded newlines", function()
		local rows = CT.parse('name,bio\nAlice,"line1\nline2"\nBob,plain\n')
		T.eq(rows[1].bio, "line1\nline2")
		T.eq(rows[2].bio, "plain")
	end)

	it("parses escaped quotes (\"\")", function()
		local rows = CT.parse('name,quote\nAlice,"say ""hello"""\n')
		T.eq(rows[1].quote, 'say "hello"')
	end)

	it("returns empty table for header-only CSV", function()
		local rows = CT.parse("name,age\n")
		T.eq(#rows, 0)
	end)

	it("returns (nil, errmsg) for non-string input", function()
		local result, err = CT.parse(42)
		T.eq(result, nil)
		T.ok(type(err) == "string")
	end)
end)

-- ── serialize ──────────────────────────────────────────────────────────────────

describe("csv_transform.serialize", function()
	it("serializes rows to CSV string", function()
		local rows = { { name = "Alice", age = "30" }, { name = "Bob", age = "25" } }
		local csv = CT.serialize(rows, { "name", "age" })
		T.ok(type(csv) == "string")
		T.ok(csv:find("Alice"))
		T.ok(csv:find("30"))
	end)

	it("round-trips parse → serialize → parse", function()
		local original = "name,age,city\nAlice,30,NYC\nBob,25,LA\n"
		local rows = CT.parse(original)
		local csv = CT.serialize(rows, { "name", "age", "city" })
		local rows2 = CT.parse(csv)
		T.eq(#rows2, #rows)
		T.eq(rows2[1].name, rows[1].name)
		T.eq(rows2[1].age, rows[1].age)
		T.eq(rows2[2].name, rows[2].name)
	end)

	it("quotes fields containing commas", function()
		local rows = { { note = "big, city" } }
		local csv = CT.serialize(rows, { "note" })
		T.ok(csv:find('"big, city"'))
	end)

	it("quotes fields containing newlines", function()
		local rows = { { note = "line1\nline2" } }
		local csv = CT.serialize(rows, { "note" })
		T.ok(csv:find('"'))
	end)

	it("escapes embedded quotes", function()
		local rows = { { q = 'say "hi"' } }
		local csv = CT.serialize(rows, { "q" })
		T.ok(csv:find('""'))
	end)
end)

-- ── select ─────────────────────────────────────────────────────────────────────

describe("pipeline:select", function()
	it("keeps only specified columns", function()
		local rows = CT.parse("name,age,city\nAlice,30,NYC\n")
		local result = CT.from(rows):select({ "name", "city" }):to_array()
		T.eq(#result, 1)
		T.eq(result[1].name, "Alice")
		T.eq(result[1].city, "NYC")
		T.eq(result[1].age, nil)
	end)
end)

-- ── rename ─────────────────────────────────────────────────────────────────────

describe("pipeline:rename", function()
	it("renames columns", function()
		local rows = CT.parse("name,city\nAlice,NYC\n")
		local result = CT.from(rows):rename({ city = "location" }):to_array()
		T.eq(result[1].location, "NYC")
		T.eq(result[1].city, nil)
	end)
end)

-- ── cast ───────────────────────────────────────────────────────────────────────

describe("pipeline:cast", function()
	it("casts string column values to numbers", function()
		local rows = CT.parse("name,age\nAlice,30\nBob,25\n")
		local result = CT.from(rows):cast({ age = tonumber }):to_array()
		T.eq(result[1].age, 30)
		T.eq(result[2].age, 25)
		T.ok(type(result[1].age) == "number")
	end)
end)

-- ── filter ─────────────────────────────────────────────────────────────────────

describe("pipeline:filter", function()
	it("removes rows that do not match predicate", function()
		local rows = CT.parse("name,age\nAlice,30\nBob,25\n")
		local result = CT.from(rows):filter(function(r)
			return tonumber(r.age) >= 30
		end):to_array()
		T.eq(#result, 1)
		T.eq(result[1].name, "Alice")
	end)

	it("returns empty table when no rows match", function()
		local rows = CT.parse("name,age\nAlice,30\n")
		local result = CT.from(rows):filter(function(r)
			return tonumber(r.age) > 100
		end):to_array()
		T.eq(#result, 0)
	end)
end)

-- ── map ────────────────────────────────────────────────────────────────────────

describe("pipeline:map", function()
	it("transforms each row", function()
		local rows = CT.parse("name,age\nAlice,30\n")
		local result = CT.from(rows):map(function(row)
			row.name = row.name:upper()
			return row
		end):to_array()
		T.eq(result[1].name, "ALICE")
	end)
end)

-- ── sort ───────────────────────────────────────────────────────────────────────

describe("pipeline:sort", function()
	it("sorts ascending by default", function()
		local rows = CT.parse("name,age\nAlice,30\nBob,25\nCarol,28\n")
		local result = CT.from(rows):sort("age"):to_array()
		T.eq(result[1].name, "Bob")
		T.eq(result[2].name, "Carol")
		T.eq(result[3].name, "Alice")
	end)

	it("sorts descending", function()
		local rows = CT.parse("name,age\nAlice,30\nBob,25\nCarol,28\n")
		local result = CT.from(rows):sort("age", "desc"):to_array()
		T.eq(result[1].name, "Alice")
		T.eq(result[2].name, "Carol")
		T.eq(result[3].name, "Bob")
	end)
end)

-- ── limit ──────────────────────────────────────────────────────────────────────

describe("pipeline:limit", function()
	it("keeps at most n rows", function()
		local rows = CT.parse("name,age\nA,1\nB,2\nC,3\nD,4\n")
		local result = CT.from(rows):limit(2):to_array()
		T.eq(#result, 2)
	end)

	it("returns all rows when limit >= count", function()
		local rows = CT.parse("name,age\nA,1\n")
		local result = CT.from(rows):limit(100):to_array()
		T.eq(#result, 1)
	end)
end)

-- ── group_by + agg ─────────────────────────────────────────────────────────────

describe("pipeline group_by + agg", function()
	local csv = "city,name,age\nNYC,Alice,30\nNYC,Bob,25\nLA,Carol,28\n"

	it("count", function()
		local result = CT.from(CT.parse(csv))
			:group_by("city")
			:agg({ count = CT.count() })
			:sort("city")
			:to_array()
		-- find LA and NYC
		local nyc, la
		for _, r in ipairs(result) do
			if r.city == "NYC" then nyc = r end
			if r.city == "LA" then la = r end
		end
		T.eq(nyc.count, 2)
		T.eq(la.count, 1)
	end)

	it("sum", function()
		local result = CT.from(CT.parse(csv))
			:group_by("city")
			:agg({ total = CT.sum("age") })
			:to_array()
		local nyc
		for _, r in ipairs(result) do
			if r.city == "NYC" then nyc = r end
		end
		T.eq(nyc.total, 55)
	end)

	it("avg", function()
		local result = CT.from(CT.parse(csv))
			:group_by("city")
			:agg({ avg_age = CT.avg("age") })
			:to_array()
		local nyc
		for _, r in ipairs(result) do
			if r.city == "NYC" then nyc = r end
		end
		T.eq(nyc.avg_age, 27.5)
	end)

	it("min", function()
		local result = CT.from(CT.parse(csv))
			:group_by("city")
			:agg({ min_age = CT.min("age") })
			:to_array()
		local nyc
		for _, r in ipairs(result) do
			if r.city == "NYC" then nyc = r end
		end
		T.eq(nyc.min_age, 25)
	end)

	it("max", function()
		local result = CT.from(CT.parse(csv))
			:group_by("city")
			:agg({ max_age = CT.max("age") })
			:to_array()
		local nyc
		for _, r in ipairs(result) do
			if r.city == "NYC" then nyc = r end
		end
		T.eq(nyc.max_age, 30)
	end)

	it("first and last", function()
		local result = CT.from(CT.parse(csv))
			:group_by("city")
			:agg({
				first_name = CT.first("name"),
				last_name  = CT.last("name"),
			})
			:to_array()
		local nyc
		for _, r in ipairs(result) do
			if r.city == "NYC" then nyc = r end
		end
		T.eq(nyc.first_name, "Alice")
		T.eq(nyc.last_name, "Bob")
	end)

	it("collect", function()
		local result = CT.from(CT.parse(csv))
			:group_by("city")
			:agg({ names = CT.collect("name") })
			:to_array()
		local nyc
		for _, r in ipairs(result) do
			if r.city == "NYC" then nyc = r end
		end
		T.eq(#nyc.names, 2)
		T.eq(nyc.names[1], "Alice")
		T.eq(nyc.names[2], "Bob")
	end)
end)

-- ── join ───────────────────────────────────────────────────────────────────────

describe("pipeline:join", function()
	it("inner join basic", function()
		local orders = { { user_id = "1", amount = "100" }, { user_id = "2", amount = "50" } }
		local users  = { { id = "1", name = "Alice" }, { id = "2", name = "Bob" } }
		local result = CT.from(orders):join(users, "user_id", "id"):to_array()
		T.eq(#result, 2)
		-- find Alice's order
		local alice
		for _, r in ipairs(result) do
			if r.name == "Alice" then alice = r end
		end
		T.ok(alice ~= nil)
		T.eq(alice.amount, "100")
	end)

	it("excludes rows with no matching key", function()
		local orders = {
			{ user_id = "1", amount = "100" },
			{ user_id = "99", amount = "999" },
		}
		local users = { { id = "1", name = "Alice" } }
		local result = CT.from(orders):join(users, "user_id", "id"):to_array()
		T.eq(#result, 1)
		T.eq(result[1].name, "Alice")
	end)

	it("select after join", function()
		local orders = { { user_id = "1", amount = "100" } }
		local users  = { { id = "1", name = "Alice" } }
		local result = CT.from(orders)
			:join(users, "user_id", "id")
			:select({ "name", "amount" })
			:to_array()
		T.eq(result[1].name, "Alice")
		T.eq(result[1].amount, "100")
		T.eq(result[1].user_id, nil)
	end)
end)

-- ── add_column ─────────────────────────────────────────────────────────────────

describe("pipeline:add_column", function()
	it("adds a computed column to each row", function()
		local rows = CT.parse("name,age\nAlice,30\nBob,25\n")
		local result = CT.from(rows):add_column("initial", function(row)
			return row.name:sub(1, 1)
		end):to_array()
		T.eq(result[1].initial, "A")
		T.eq(result[2].initial, "B")
	end)
end)

-- ── distinct ───────────────────────────────────────────────────────────────────

describe("pipeline:distinct", function()
	it("keeps only first occurrence of each distinct value", function()
		local rows = CT.parse("name,city\nAlice,NYC\nBob,LA\nCarol,NYC\n")
		local result = CT.from(rows):distinct("city"):to_array()
		T.eq(#result, 2)
		T.eq(result[1].city, "NYC")
		T.eq(result[2].city, "LA")
	end)
end)

-- ── explode ────────────────────────────────────────────────────────────────────

describe("pipeline:explode", function()
	it("expands single-value column unchanged", function()
		local rows = { { name = "Alice", tag = "a" } }
		local result = CT.from(rows):explode("tag", ","):to_array()
		T.eq(#result, 1)
		T.eq(result[1].tag, "a")
	end)

	it("expands multi-value column into multiple rows", function()
		local rows = { { name = "Alice", tags = "a,b,c" } }
		local result = CT.from(rows):explode("tags", ","):to_array()
		T.eq(#result, 3)
		T.eq(result[1].tags, "a")
		T.eq(result[2].tags, "b")
		T.eq(result[3].tags, "c")
		-- name preserved on all rows
		T.eq(result[1].name, "Alice")
		T.eq(result[3].name, "Alice")
	end)

	it("handles multiple rows with different tag counts", function()
		local rows = {
			{ name = "Alice", tags = "a,b" },
			{ name = "Bob",   tags = "x" },
		}
		local result = CT.from(rows):explode("tags", ","):to_array()
		T.eq(#result, 3)
	end)
end)

-- ── describe ──────────────────────────────────────────────────────────────────

describe("pipeline:describe", function()
	it("returns correct stats for known data", function()
		local rows = CT.parse("val\n10\n20\n30\n40\n50\n")
		local stats = CT.from(rows):describe("val")
		T.eq(stats.count, 5)
		T.eq(stats.min, 10)
		T.eq(stats.max, 50)
		T.eq(stats.mean, 30)
		-- p50 = median = 30
		T.eq(stats.p50, 30)
	end)

	it("handles a single value", function()
		local rows = CT.parse("val\n42\n")
		local stats = CT.from(rows):describe("val")
		T.eq(stats.count, 1)
		T.eq(stats.min, 42)
		T.eq(stats.max, 42)
		T.eq(stats.mean, 42)
		T.eq(stats.std, 0)
	end)

	it("returns nil stats for empty column", function()
		local rows = CT.parse("val\n")
		-- parse produces 0 data rows (only header), so describe sees empty data
		local stats = CT.from(rows):describe("val")
		T.eq(stats.count, 0)
		T.eq(stats.mean, nil)
	end)
end)

-- ── chaining ──────────────────────────────────────────────────────────────────

describe("pipeline chaining", function()
	it("chains multiple operations", function()
		local csv = "name,age,city\nAlice,30,NYC\nBob,25,LA\nCarol,28,NYC\n"
		local result = CT.from(CT.parse(csv))
			:filter(function(r) return tonumber(r.age) >= 28 end)
			:select({ "name", "city" })
			:sort("name")
			:to_array()
		T.eq(#result, 2)
		T.eq(result[1].name, "Alice")
		T.eq(result[2].name, "Carol")
		T.eq(result[1].age, nil)
	end)
end)
