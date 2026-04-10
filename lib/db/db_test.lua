if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")

local ok_load, db_mod = pcall(require, "lib.db")
if not ok_load then
	T.describe("db: load", function()
		T.it("db module loaded", function()
			error("lib.db failed to load: " .. tostring(db_mod))
		end)
	end)
	return
end

local sqlite = require("lib.sqlite")

-- ── helpers ─────────────────────────────────────────────────────────────────

local function fresh()
	local conn, err = db_mod.connect(":memory:")
	assert(conn, "db.connect(:memory:) failed: " .. tostring(err))
	return conn
end

local function seed(conn)
	conn:exec([[
		CREATE TABLE users (
			id INTEGER PRIMARY KEY,
			name TEXT NOT NULL,
			email TEXT UNIQUE,
			active INTEGER DEFAULT 1
		)
	]])
	conn:exec("INSERT INTO users (name, email, active) VALUES ('Alice', 'alice@example.com', 1)")
	conn:exec("INSERT INTO users (name, email, active) VALUES ('Bob', 'bob@example.com', 1)")
	conn:exec("INSERT INTO users (name, email, active) VALUES ('Carol', 'carol@example.com', 0)")
end

-- ── tests ───────────────────────────────────────────────────────────────────

T.describe("db: connect", function()
	T.it("opens a database", function()
		local conn, err = db_mod.connect(":memory:")
		T.ok(conn, "connect should succeed")
		conn:close()
	end)
end)

T.describe("db: exec", function()
	T.it("runs raw SQL", function()
		local conn = fresh()
		local ok, err = conn:exec("CREATE TABLE t (x INTEGER)")
		T.ok(ok, "exec should succeed")
		ok, err = conn:exec("INSERT INTO t VALUES (42)")
		T.ok(ok, "insert should succeed")
		conn:close()
	end)
end)

T.describe("db: query", function()
	T.it("returns array of row tables", function()
		local conn = fresh()
		seed(conn)
		local rows, err = conn:query("SELECT id, name FROM users ORDER BY id")
		T.ok(rows, "query should succeed: " .. tostring(err))
		T.eq(#rows, 3)
		T.eq(rows[1].name, "Alice")
		T.eq(rows[2].name, "Bob")
		T.eq(rows[3].name, "Carol")
		conn:close()
	end)
end)

T.describe("db: query_one", function()
	T.it("returns single row", function()
		local conn = fresh()
		seed(conn)
		local row, err = conn:query_one("SELECT name FROM users WHERE id = 1")
		T.ok(row, "query_one should return a row: " .. tostring(err))
		T.eq(row.name, "Alice")
		conn:close()
	end)
end)

T.describe("db: migrations", function()
	T.it("runs migrations and creates tables", function()
		local conn = fresh()
		local ok, err = conn:migrate({
			{ version = 1, up = "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT UNIQUE)" },
			{ version = 2, up = "ALTER TABLE users ADD COLUMN active INTEGER DEFAULT 1" },
			{ version = 3, up = "CREATE INDEX idx_users_email ON users(email)" },
		})
		T.ok(ok, "migrate should succeed: " .. tostring(err))
		-- Verify table exists by inserting
		ok, err = conn:exec("INSERT INTO users (name, email) VALUES ('Test', 'test@test.com')")
		T.ok(ok, "insert into migrated table should work: " .. tostring(err))
		conn:close()
	end)

	T.it("re-running is idempotent", function()
		local conn = fresh()
		local migrations = {
			{ version = 1, up = "CREATE TABLE t1 (id INTEGER PRIMARY KEY)" },
			{ version = 2, up = "CREATE TABLE t2 (id INTEGER PRIMARY KEY)" },
		}
		local ok, err = conn:migrate(migrations)
		T.ok(ok, "first migrate: " .. tostring(err))
		ok, err = conn:migrate(migrations)
		T.ok(ok, "second migrate should be idempotent: " .. tostring(err))
		conn:close()
	end)

	T.it("migration_version returns current version", function()
		local conn = fresh()
		T.eq(conn:migration_version(), 0)
		conn:migrate({
			{ version = 1, up = "CREATE TABLE t1 (id INTEGER PRIMARY KEY)" },
			{ version = 2, up = "CREATE TABLE t2 (id INTEGER PRIMARY KEY)" },
		})
		T.eq(conn:migration_version(), 2)
		conn:close()
	end)

	T.it("error in migration rolls back", function()
		local conn = fresh()
		local ok, err = conn:migrate({
			{ version = 1, up = "CREATE TABLE t1 (id INTEGER PRIMARY KEY)" },
			{ version = 2, up = "INVALID SQL THAT WILL FAIL" },
		})
		T.fail(ok, "migrate with bad SQL should fail")
		T.ok(err, "should have error message")
		-- t1 should not exist because transaction was rolled back
		T.eq(conn:migration_version(), 0)
		conn:close()
	end)
end)

T.describe("db: select builder", function()
	T.it("basic select:all()", function()
		local conn = fresh()
		seed(conn)
		local rows, err = conn:select("users"):columns("id", "name"):all()
		T.ok(rows, "select should succeed: " .. tostring(err))
		T.eq(#rows, 3)
		T.eq(rows[1].name, "Alice")
		conn:close()
	end)

	T.it("select with where clause", function()
		local conn = fresh()
		seed(conn)
		local rows, err = conn:select("users"):columns("name"):where("active = ?", 1):all()
		T.ok(rows, "select with where: " .. tostring(err))
		T.eq(#rows, 2)
		conn:close()
	end)

	T.it("select with multiple where clauses (AND)", function()
		local conn = fresh()
		seed(conn)
		local rows, err = conn:select("users")
			:columns("name")
			:where("active = ?", 1)
			:where("name = ?", "Alice")
			:all()
		T.ok(rows, "select with multiple wheres: " .. tostring(err))
		T.eq(#rows, 1)
		T.eq(rows[1].name, "Alice")
		conn:close()
	end)

	T.it("select with order, limit, offset", function()
		local conn = fresh()
		seed(conn)
		local rows, err = conn:select("users")
			:columns("name")
			:order("name ASC")
			:limit(2)
			:offset(1)
			:all()
		T.ok(rows, "select with order/limit/offset: " .. tostring(err))
		T.eq(#rows, 2)
		T.eq(rows[1].name, "Bob")
		T.eq(rows[2].name, "Carol")
		conn:close()
	end)

	T.it(":first() returns single row", function()
		local conn = fresh()
		seed(conn)
		local row, err = conn:select("users"):columns("name"):order("name ASC"):first()
		T.ok(row, "first should return a row: " .. tostring(err))
		T.eq(row.name, "Alice")
		conn:close()
	end)

	T.it(":count() returns number", function()
		local conn = fresh()
		seed(conn)
		local n, err = conn:select("users"):where("active = ?", 1):count()
		T.ok(n, "count should return a number: " .. tostring(err))
		T.eq(n, 2)
		conn:close()
	end)
end)

T.describe("db: insert builder", function()
	T.it("inserts a row, verify with select", function()
		local conn = fresh()
		conn:exec("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")
		local ok, err = conn:insert("items"):values({ name = "Widget" }):exec()
		T.ok(ok, "insert should succeed: " .. tostring(err))
		local rows = conn:select("items"):columns("name"):all()
		T.eq(#rows, 1)
		T.eq(rows[1].name, "Widget")
		conn:close()
	end)

	T.it("insert with returning", function()
		local conn = fresh()
		conn:exec("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")
		local row, err = conn:insert("items")
			:values({ name = "Gadget" })
			:returning("id", "name")
			:first()
		T.ok(row, "insert returning should return a row: " .. tostring(err))
		T.eq(row.name, "Gadget")
		T.ok(row.id, "should have an id")
		conn:close()
	end)
end)

T.describe("db: update builder", function()
	T.it("updates a row, verify change", function()
		local conn = fresh()
		seed(conn)
		local ok, err = conn:update("users"):set({ name = "Bobby" }):where("id = ?", 2):exec()
		T.ok(ok, "update should succeed: " .. tostring(err))
		local row = conn:select("users"):columns("name"):where("id = ?", 2):first()
		T.eq(row.name, "Bobby")
		conn:close()
	end)
end)

T.describe("db: delete builder", function()
	T.it("deletes a row, verify gone", function()
		local conn = fresh()
		seed(conn)
		local ok, err = conn:delete("users"):where("id = ?", 3):exec()
		T.ok(ok, "delete should succeed: " .. tostring(err))
		local n = conn:select("users"):count()
		T.eq(n, 2)
		conn:close()
	end)
end)

T.describe("db: transaction", function()
	T.it("successful commit", function()
		local conn = fresh()
		conn:exec("CREATE TABLE t (x INTEGER)")
		local result, err = conn:transaction(function(c)
			c:exec("INSERT INTO t VALUES (1)")
			c:exec("INSERT INTO t VALUES (2)")
			return "ok"
		end)
		T.eq(result, "ok")
		local rows = conn:select("t"):columns("x"):all()
		T.eq(#rows, 2)
		conn:close()
	end)

	T.it("rollback on error", function()
		local conn = fresh()
		conn:exec("CREATE TABLE t (x INTEGER)")
		conn:exec("INSERT INTO t VALUES (0)")
		local result, err = conn:transaction(function(c)
			c:exec("INSERT INTO t VALUES (1)")
			error("intentional failure")
		end)
		T.fail(result, "transaction should fail")
		local n = conn:select("t"):count()
		T.eq(n, 1) -- only the row inserted before the transaction
		conn:close()
	end)
end)

T.describe("db: query builder immutability", function()
	T.it("base query unaffected by chain", function()
		local conn = fresh()
		seed(conn)
		local base = conn:select("users"):columns("name")
		local q1 = base:where("active = ?", 1)
		local q2 = base:where("active = ?", 0)
		local r1 = q1:all()
		local r2 = q2:all()
		T.eq(#r1, 2, "q1 should have 2 active users")
		T.eq(#r2, 1, "q2 should have 1 inactive user")
		-- base should still return all 3
		local r0 = base:all()
		T.eq(#r0, 3, "base should still return all 3 users")
		conn:close()
	end)
end)

T.describe("db: wrap", function()
	T.it("wraps existing sqlite connection", function()
		local raw_db, err = sqlite.open(":memory:")
		assert(raw_db, "sqlite.open failed: " .. tostring(err))
		raw_db:execute("CREATE TABLE t (x INTEGER)")
		raw_db:execute("INSERT INTO t VALUES (99)")
		local conn = db_mod.wrap(raw_db)
		local rows = conn:select("t"):columns("x"):all()
		T.eq(#rows, 1)
		T.eq(rows[1].x, 99)
		conn:close()
	end)
end)

T.describe("db: multiple column select", function()
	T.it("selects multiple specific columns", function()
		local conn = fresh()
		seed(conn)
		local rows, err = conn:select("users"):columns("name", "email"):order("id ASC"):all()
		T.ok(rows, "should succeed: " .. tostring(err))
		T.eq(#rows, 3)
		T.eq(rows[1].name, "Alice")
		T.eq(rows[1].email, "alice@example.com")
		T.eq(rows[2].name, "Bob")
		T.eq(rows[2].email, "bob@example.com")
		conn:close()
	end)
end)
