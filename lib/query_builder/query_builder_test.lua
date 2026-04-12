if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local QB = require("lib.query_builder")

-- Deep equality for params arrays (T.eq uses == which is reference for tables).
local function peq(actual, expected, label)
	T.eq(#actual, #expected, (label or "params") .. " length")
	for i = 1, #expected do
		T.eq(actual[i], expected[i], (label or "params") .. "[" .. i .. "]")
	end
end

-- ── SELECT basic ─────────────────────────────────────────────────────────────

T.describe("SELECT basic", function()
	T.it("select all columns (no columns call)", function()
		local sql, params = QB.select("users"):build()
		T.eq(sql, "SELECT * FROM users")
		peq(params, {})
	end)

	T.it("select with explicit columns", function()
		local sql, params = QB.select("users"):columns("id", "name", "email"):build()
		T.eq(sql, "SELECT id, name, email FROM users")
		peq(params, {})
	end)

	T.it("select with columns_raw", function()
		local sql, params = QB.select("users")
			:columns_raw("id, name, strftime('%Y', created_at) AS year")
			:build()
		T.eq(sql, "SELECT id, name, strftime('%Y', created_at) AS year FROM users")
		peq(params, {})
	end)

	T.it("columns_raw overrides columns", function()
		local sql = QB.select("users")
			:columns("id", "name")
			:columns_raw("COUNT(*) AS n")
			:build()
		T.ok(sql:find("COUNT%(%*%) AS n"))
	end)
end)

-- ── WHERE ─────────────────────────────────────────────────────────────────────

T.describe("WHERE", function()
	T.it("single where clause", function()
		local sql, params = QB.select("users"):where("age > ?", 18):build()
		T.eq(sql, "SELECT * FROM users WHERE age > ?")
		peq(params, {18})
	end)

	T.it("multiple where clauses (AND)", function()
		local sql, params = QB.select("users")
			:where("age > ?", 18)
			:where("active = ?", true)
			:build()
		T.eq(sql, "SELECT * FROM users WHERE age > ? AND active = ?")
		peq(params, {18, true})
	end)

	T.it("where_or produces OR connector", function()
		local sql, params = QB.select("users")
			:where("age > ?", 18)
			:where_or("age < ?", 5)
			:build()
		T.eq(sql, "SELECT * FROM users WHERE age > ? OR age < ?")
		peq(params, {18, 5})
	end)

	T.it("mix of AND and OR", function()
		local sql, params = QB.select("users")
			:where("a = ?", 1)
			:where_or("b = ?", 2)
			:where("c = ?", 3)
			:build()
		T.eq(sql, "SELECT * FROM users WHERE a = ? OR b = ? AND c = ?")
		peq(params, {1, 2, 3})
	end)

	T.it("where_in with array", function()
		local sql, params = QB.select("users"):where_in("status", {"active", "pending"}):build()
		T.eq(sql, "SELECT * FROM users WHERE status IN (?, ?)")
		peq(params, {"active", "pending"})
	end)

	T.it("where_not_in with array", function()
		local sql, params = QB.select("users"):where_not_in("role", {"banned", "deleted"}):build()
		T.eq(sql, "SELECT * FROM users WHERE role NOT IN (?, ?)")
		peq(params, {"banned", "deleted"})
	end)

	T.it("where_null", function()
		local sql, params = QB.select("users"):where_null("deleted_at"):build()
		T.eq(sql, "SELECT * FROM users WHERE deleted_at IS NULL")
		peq(params, {})
	end)

	T.it("where_not_null", function()
		local sql, params = QB.select("users"):where_not_null("email"):build()
		T.eq(sql, "SELECT * FROM users WHERE email IS NOT NULL")
		peq(params, {})
	end)

	T.it("where_between", function()
		local sql, params = QB.select("users"):where_between("age", 18, 65):build()
		T.eq(sql, "SELECT * FROM users WHERE age BETWEEN ? AND ?")
		peq(params, {18, 65})
	end)

	T.it("where_like", function()
		local sql, params = QB.select("users"):where_like("name", "%alice%"):build()
		T.eq(sql, "SELECT * FROM users WHERE name LIKE ?")
		peq(params, {"%alice%"})
	end)

	T.it("where_raw with multiple params", function()
		local sql, params = QB.select("users")
			:where_raw("latitude BETWEEN ? AND ?", -90, 90)
			:build()
		T.eq(sql, "SELECT * FROM users WHERE latitude BETWEEN ? AND ?")
		peq(params, {-90, 90})
	end)
end)

-- ── JOIN ──────────────────────────────────────────────────────────────────────

T.describe("JOIN", function()
	T.it("inner join", function()
		local sql, params = QB.select("users u")
			:join("orders o", "o.user_id = u.id")
			:columns("u.name", "o.total")
			:build()
		T.eq(sql, "SELECT u.name, o.total FROM users u INNER JOIN orders o ON o.user_id = u.id")
		peq(params, {})
	end)

	T.it("left join", function()
		local sql = QB.select("users u")
			:left_join("profiles p", "p.user_id = u.id")
			:build()
		T.ok(sql:find("LEFT JOIN profiles p ON p%.user_id = u%.id"))
	end)

	T.it("right join", function()
		local sql = QB.select("a"):right_join("b", "b.id = a.id"):build()
		T.ok(sql:find("RIGHT JOIN b ON b%.id = a%.id"))
	end)

	T.it("full join", function()
		local sql = QB.select("a"):full_join("b", "b.id = a.id"):build()
		T.ok(sql:find("FULL JOIN b ON b%.id = a%.id"))
	end)

	T.it("multiple joins", function()
		local sql = QB.select("users u")
			:join("orders o", "o.user_id = u.id")
			:left_join("profiles p", "p.user_id = u.id")
			:build()
		T.ok(sql:find("INNER JOIN orders o"))
		T.ok(sql:find("LEFT JOIN profiles p"))
	end)
end)

-- ── ORDER BY / LIMIT / OFFSET ─────────────────────────────────────────────────

T.describe("ORDER BY / LIMIT / OFFSET", function()
	T.it("order_by single column", function()
		local sql = QB.select("users"):order_by("name"):build()
		T.eq(sql, "SELECT * FROM users ORDER BY name")
	end)

	T.it("order_by multiple columns", function()
		local sql = QB.select("users"):order_by("name ASC", "age DESC"):build()
		T.eq(sql, "SELECT * FROM users ORDER BY name ASC, age DESC")
	end)

	T.it("limit", function()
		local sql = QB.select("users"):limit(10):build()
		T.eq(sql, "SELECT * FROM users LIMIT 10")
	end)

	T.it("offset", function()
		local sql = QB.select("users"):offset(20):build()
		T.eq(sql, "SELECT * FROM users OFFSET 20")
	end)

	T.it("limit and offset together", function()
		local sql = QB.select("users"):limit(10):offset(20):build()
		T.eq(sql, "SELECT * FROM users LIMIT 10 OFFSET 20")
	end)

	T.it("full select with all clauses", function()
		local sql, params = QB.select("users")
			:columns("id", "name", "email")
			:where("age > ?", 18)
			:where("active = ?", true)
			:order_by("name")
			:limit(10)
			:offset(20)
			:build()
		T.eq(sql, "SELECT id, name, email FROM users WHERE age > ? AND active = ? ORDER BY name LIMIT 10 OFFSET 20")
		peq(params, {18, true})
	end)
end)

-- ── GROUP BY / HAVING ─────────────────────────────────────────────────────────

T.describe("GROUP BY / HAVING", function()
	T.it("group_by single column", function()
		local sql = QB.select("orders"):columns("user_id", "COUNT(*) AS n"):group_by("user_id"):build()
		T.eq(sql, "SELECT user_id, COUNT(*) AS n FROM orders GROUP BY user_id")
	end)

	T.it("group_by multiple columns", function()
		local sql = QB.select("orders"):group_by("year", "month"):build()
		T.ok(sql:find("GROUP BY year, month"))
	end)

	T.it("having clause", function()
		local sql, params = QB.select("users u")
			:join("orders o", "o.user_id = u.id")
			:columns("u.name", "COUNT(o.id) AS order_count")
			:where("u.active = ?", true)
			:group_by("u.id", "u.name")
			:having("COUNT(o.id) > ?", 5)
			:build()
		T.ok(sql:find("GROUP BY u%.id, u%.name"))
		T.ok(sql:find("HAVING COUNT%(o%.id%) > %?"))
		peq(params, {true, 5})
	end)
end)

-- ── INSERT ────────────────────────────────────────────────────────────────────

T.describe("INSERT", function()
	T.it("single row values — sorted column order", function()
		local sql, params = QB.insert("users")
			:values({name = "Alice", email = "alice@example.com", age = 30})
			:build()
		-- columns sorted: age, email, name
		T.eq(sql, "INSERT INTO users (age, email, name) VALUES (?, ?, ?)")
		peq(params, {30, "alice@example.com", "Alice"})
	end)

	T.it("multi-row insert", function()
		local sql, params = QB.insert("users")
			:rows({
				{name = "Alice", age = 30},
				{name = "Bob",   age = 25},
			})
			:build()
		-- columns: age, name (sorted)
		T.eq(sql, "INSERT INTO users (age, name) VALUES (?, ?), (?, ?)")
		peq(params, {30, "Alice", 25, "Bob"})
	end)

	T.it("single-column insert", function()
		local sql, params = QB.insert("tags"):values({name = "lua"}):build()
		T.eq(sql, "INSERT INTO tags (name) VALUES (?)")
		peq(params, {"lua"})
	end)
end)

-- ── UPDATE ────────────────────────────────────────────────────────────────────

T.describe("UPDATE", function()
	T.it("set with where", function()
		local sql, params = QB.update("users")
			:set({name = "Alice Smith", updated_at = "NOW()"})
			:where("id = ?", 42)
			:build()
		-- columns sorted: name, updated_at
		T.eq(sql, "UPDATE users SET name = ?, updated_at = ? WHERE id = ?")
		peq(params, {"Alice Smith", "NOW()", 42})
	end)

	T.it("update without where", function()
		local sql, params = QB.update("settings"):set({value = "dark"}):build()
		T.eq(sql, "UPDATE settings SET value = ?")
		peq(params, {"dark"})
	end)

	T.it("multiple where conditions", function()
		local sql, params = QB.update("users")
			:set({active = false})
			:where("role = ?", "guest")
			:where("age < ?", 13)
			:build()
		T.eq(sql, "UPDATE users SET active = ? WHERE role = ? AND age < ?")
		peq(params, {false, "guest", 13})
	end)
end)

-- ── DELETE ────────────────────────────────────────────────────────────────────

T.describe("DELETE", function()
	T.it("delete with where", function()
		local sql, params = QB.delete("users"):where("id = ?", 42):build()
		T.eq(sql, "DELETE FROM users WHERE id = ?")
		peq(params, {42})
	end)

	T.it("delete without where", function()
		local sql, params = QB.delete("temp_logs"):build()
		T.eq(sql, "DELETE FROM temp_logs")
		peq(params, {})
	end)

	T.it("delete multiple conditions", function()
		local sql, params = QB.delete("sessions")
			:where("user_id = ?", 7)
			:where("expired = ?", true)
			:build()
		T.eq(sql, "DELETE FROM sessions WHERE user_id = ? AND expired = ?")
		peq(params, {7, true})
	end)
end)

-- ── SUBQUERY in where_in ──────────────────────────────────────────────────────

T.describe("subquery", function()
	T.it("where_in with subquery", function()
		local subq = QB.select("orders"):columns("user_id"):where("total > ?", 100)
		local sql, params = QB.select("users"):where_in("id", subq):build()
		T.eq(sql, "SELECT * FROM users WHERE id IN (SELECT user_id FROM orders WHERE total > ?)")
		peq(params, {100})
	end)

	T.it("where_not_in with subquery", function()
		local subq = QB.select("banned"):columns("user_id")
		local sql, params = QB.select("users"):where_not_in("id", subq):build()
		T.eq(sql, "SELECT * FROM users WHERE id NOT IN (SELECT user_id FROM banned)")
		peq(params, {})
	end)
end)

-- ── COUNT / EXISTS ────────────────────────────────────────────────────────────

T.describe("count / exists", function()
	T.it("count shorthand", function()
		local sql, params = QB.select("users"):count():where("active = ?", true):build()
		T.eq(sql, "SELECT COUNT(*) FROM users WHERE active = ?")
		peq(params, {true})
	end)

	T.it("exists shorthand", function()
		local sql, params = QB.select("users"):exists():where("id = ?", 1):build()
		T.eq(sql, "SELECT EXISTS(SELECT 1 FROM users WHERE id = ?)")
		peq(params, {1})
	end)

	T.it("count without where", function()
		local sql, params = QB.select("orders"):count():build()
		T.eq(sql, "SELECT COUNT(*) FROM orders")
		peq(params, {})
	end)
end)

-- ── UNION ─────────────────────────────────────────────────────────────────────

T.describe("union", function()
	T.it("basic union", function()
		local sql, params = QB.union(
			QB.select("active_users"):columns("id", "name"),
			QB.select("archived_users"):columns("id", "name")
		):build()
		T.eq(sql, "SELECT id, name FROM active_users UNION SELECT id, name FROM archived_users")
		peq(params, {})
	end)

	T.it("union all", function()
		local sql = QB.union(
			QB.select("a"):columns("x"),
			QB.select("b"):columns("x")
		):all():build()
		T.ok(sql:find("UNION ALL"))
	end)

	T.it("union with params", function()
		local sql, params = QB.union(
			QB.select("a"):columns("id"):where("active = ?", true),
			QB.select("b"):columns("id"):where("score > ?", 10)
		):build()
		T.ok(sql:find("UNION"))
		peq(params, {true, 10})
	end)

	T.it("union with table arg", function()
		local q1 = QB.select("foo"):columns("id")
		local q2 = QB.select("bar"):columns("id")
		local sql = QB.union({q1, q2}):build()
		T.ok(sql:find("UNION"))
	end)
end)

-- ── IMMUTABILITY ──────────────────────────────────────────────────────────────

T.describe("immutability", function()
	T.it("chaining does not mutate original", function()
		local base = QB.select("users")
		local q1   = base:where("a = ?", 1)
		local q2   = base:where("b = ?", 2)
		local s1   = q1:build()
		local s2   = q2:build()
		T.ok(s1:find("a = %?"))
		T.ok(s2:find("b = %?"))
		-- base has no where clause
		local s0 = base:build()
		T.ok(not s0:find("WHERE"))
	end)
end)
