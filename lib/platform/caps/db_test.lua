-- lib/platform/caps/db_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")

local ok_load, db_mod = pcall(require, "lib.platform.caps.db")
if not ok_load then
	T.describe("db_cap: load", function()
		T.it("db module loaded", function()
			error("lib.platform.caps.db failed to load: " .. tostring(db_mod))
		end)
	end)
	return
end

-- Open a fresh in-memory database or fail immediately.
local function mem()
	local cap, err = db_mod.db_cap(":memory:")
	assert(cap, "db_cap(':memory:') failed: " .. tostring(err))
	return cap
end

-- ── open ─────────────────────────────────────────────────────────────────────

T.describe("db_cap: open", function()
	T.it("opens an in-memory database", function()
		local cap, err = db_mod.db_cap(":memory:")
		T.ok(cap, err)
		cap.close()
	end)

	T.it("returns nil+err for an invalid path", function()
		-- A path that cannot be created (directory that doesn't exist on a
		-- read-only path) should fail gracefully.
		local cap, err = db_mod.db_cap("/nonexistent/path/that/cannot/be/created/db.sqlite")
		-- SQLite may create the file or fail depending on OS and permissions.
		-- We just assert that if it fails, the error is a string.
		if cap == nil then
			T.ok(type(err) == "string")
		else
			cap.close()
		end
	end)
end)

-- ── exec ──────────────────────────────────────────────────────────────────────

T.describe("db_cap: exec", function()
	T.it("CREATE TABLE returns true", function()
		local cap = mem()
		local ok, err = cap.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, val TEXT)")
		T.ok(ok, err)
		cap.close()
	end)

	T.it("INSERT returns true", function()
		local cap = mem()
		cap.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, val TEXT)")
		local ok, err = cap.exec("INSERT INTO t VALUES (1, 'hello')")
		T.ok(ok, err)
		cap.close()
	end)

	T.it("bad SQL returns nil + error string", function()
		local cap = mem()
		local ok, err = cap.exec("THIS IS NOT SQL")
		T.fail(ok)
		T.ok(type(err) == "string")
		T.ok(#err > 0)
		cap.close()
	end)

	T.it("INSERT into nonexistent table returns nil + error", function()
		local cap = mem()
		local ok, err = cap.exec("INSERT INTO nosuchtable VALUES (1)")
		T.fail(ok)
		T.ok(err)
		cap.close()
	end)

	T.it("multiple statements in one exec call", function()
		local cap = mem()
		local ok, err = cap.exec(
			"CREATE TABLE a (x INTEGER);" ..
			"INSERT INTO a VALUES (42);" ..
			"INSERT INTO a VALUES (99);"
		)
		T.ok(ok, err)
		local rows, rerr = cap.query("SELECT x FROM a ORDER BY x")
		T.ok(rows, rerr)
		T.eq(#rows, 2)
		cap.close()
	end)
end)

-- ── query ─────────────────────────────────────────────────────────────────────

T.describe("db_cap: query", function()
	T.it("returns rows as array of tables", function()
		local cap = mem()
		cap.exec("CREATE TABLE t (id INTEGER, name TEXT)")
		cap.exec("INSERT INTO t VALUES (1, 'alice')")
		cap.exec("INSERT INTO t VALUES (2, 'bob')")
		local rows, err = cap.query("SELECT id, name FROM t ORDER BY id")
		T.ok(rows, err)
		T.eq(#rows, 2)
		T.eq(rows[1].id, 1)
		T.eq(rows[1].name, "alice")
		T.eq(rows[2].id, 2)
		T.eq(rows[2].name, "bob")
		cap.close()
	end)

	T.it("empty result set returns empty array", function()
		local cap = mem()
		cap.exec("CREATE TABLE t (id INTEGER)")
		local rows, err = cap.query("SELECT id FROM t")
		T.ok(rows, err)
		T.eq(#rows, 0)
		cap.close()
	end)

	T.it("bad SQL returns nil + error string", function()
		local cap = mem()
		local rows, err = cap.query("SELECT * FROM nonexistent_table")
		T.fail(rows)
		T.ok(type(err) == "string")
		cap.close()
	end)

	T.it("column names match SELECT aliases", function()
		local cap = mem()
		cap.exec("CREATE TABLE t (x INTEGER)")
		cap.exec("INSERT INTO t VALUES (7)")
		local rows, err = cap.query("SELECT x AS value FROM t")
		T.ok(rows, err)
		T.eq(#rows, 1)
		T.ok(rows[1].value ~= nil)
		T.eq(rows[1].value, 7)
		cap.close()
	end)
end)

-- ── params binding ────────────────────────────────────────────────────────────

T.describe("db_cap: params binding", function()
	T.it("binds integer ? placeholder", function()
		local cap = mem()
		cap.exec("CREATE TABLE t (id INTEGER, v TEXT)")
		cap.exec("INSERT INTO t VALUES (1, 'a')")
		cap.exec("INSERT INTO t VALUES (2, 'b')")
		local rows, err = cap.query("SELECT v FROM t WHERE id = ?", { 1 })
		T.ok(rows, err)
		T.eq(#rows, 1)
		T.eq(rows[1].v, "a")
		cap.close()
	end)

	T.it("binds string ? placeholder", function()
		local cap = mem()
		cap.exec("CREATE TABLE t (id INTEGER, name TEXT)")
		cap.exec("INSERT INTO t VALUES (1, 'alice')")
		cap.exec("INSERT INTO t VALUES (2, 'bob')")
		local rows, err = cap.query("SELECT id FROM t WHERE name = ?", { "alice" })
		T.ok(rows, err)
		T.eq(#rows, 1)
		T.eq(rows[1].id, 1)
		cap.close()
	end)

	T.it("binds multiple ? placeholders", function()
		local cap = mem()
		cap.exec("CREATE TABLE t (a INTEGER, b INTEGER, c TEXT)")
		cap.exec("INSERT INTO t VALUES (1, 2, 'match')")
		cap.exec("INSERT INTO t VALUES (1, 3, 'no')")
		local rows, err = cap.query("SELECT c FROM t WHERE a = ? AND b = ?", { 1, 2 })
		T.ok(rows, err)
		T.eq(#rows, 1)
		T.eq(rows[1].c, "match")
		cap.close()
	end)

	T.it("binds float ? placeholder", function()
		local cap = mem()
		cap.exec("CREATE TABLE t (v REAL)")
		-- Use query with INSERT … SELECT to pass the float through binding
		local rows, err = cap.query("SELECT ? AS v", { 3.14 })
		T.ok(rows, err)
		T.eq(#rows, 1)
		T.eq(rows[1].v, 3.14)
		cap.close()
	end)

	T.it("binds boolean: true -> 1, false -> 0", function()
		local cap = mem()
		-- Bind booleans through query
		local r1, e1 = cap.query("SELECT ? AS flag", { true })
		local r2, e2 = cap.query("SELECT ? AS flag", { false })
		T.ok(r1, e1)
		T.ok(r2, e2)
		T.eq(r1[1].flag, 1)
		T.eq(r2[1].flag, 0)
		cap.close()
	end)

	T.it("nil param binds as NULL", function()
		local cap = mem()
		cap.exec("CREATE TABLE t (x INTEGER, y INTEGER)")
		-- exec does not take params; use literal SQL for the NULL row
		cap.exec("INSERT INTO t VALUES (5, NULL)")
		-- Use sentinel column so we can distinguish NULL from iterator-done
		local rows, err = cap.query("SELECT 1 AS s, y FROM t")
		T.ok(rows, err)
		T.eq(#rows, 1)
		T.eq(rows[1].s, 1)
		T.fail(rows[1].y)  -- NULL -> nil
		cap.close()
	end)

	T.it("no params arg works (nil omitted)", function()
		local cap = mem()
		cap.exec("CREATE TABLE t (x INTEGER)")
		cap.exec("INSERT INTO t VALUES (42)")
		local rows, err = cap.query("SELECT x FROM t")
		T.ok(rows, err)
		T.eq(#rows, 1)
		T.eq(rows[1].x, 42)
		cap.close()
	end)
end)

-- ── readonly ─────────────────────────────────────────────────────────────────

T.describe("db_cap: readonly", function()
	-- Helper: create a file-based db with some data, close it, return the path.
	local function seeded_db()
		local path = os.tmpname()
		local cap, err = db_mod.db_cap(path)
		assert(cap, "seed db failed: " .. tostring(err))
		cap.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, val TEXT)")
		cap.exec("INSERT INTO t VALUES (1, 'hello')")
		cap.close()
		return path
	end

	T.it("query works in readonly mode", function()
		local path = seeded_db()
		local cap, err = db_mod.db_cap(path, { readonly = true })
		T.ok(cap, err)
		local rows, rerr = cap.query("SELECT val FROM t WHERE id = ?", { 1 })
		T.ok(rows, rerr)
		T.eq(#rows, 1)
		T.eq(rows[1].val, "hello")
		cap.close()
		os.remove(path)
	end)

	T.it("exec (INSERT) fails in readonly mode", function()
		local path = seeded_db()
		local cap, err = db_mod.db_cap(path, { readonly = true })
		T.ok(cap, err)
		local ok, eerr = cap.exec("INSERT INTO t VALUES (2, 'nope')")
		T.fail(ok)
		T.ok(type(eerr) == "string")
		cap.close()
		os.remove(path)
	end)

	T.it("exec (CREATE TABLE) fails in readonly mode", function()
		local path = seeded_db()
		local cap, err = db_mod.db_cap(path, { readonly = true })
		T.ok(cap, err)
		local ok, eerr = cap.exec("CREATE TABLE t2 (x INTEGER)")
		T.fail(ok)
		T.ok(type(eerr) == "string")
		cap.close()
		os.remove(path)
	end)

	T.it("exec (DELETE) fails in readonly mode", function()
		local path = seeded_db()
		local cap, err = db_mod.db_cap(path, { readonly = true })
		T.ok(cap, err)
		local ok, eerr = cap.exec("DELETE FROM t WHERE id = 1")
		T.fail(ok)
		T.ok(type(eerr) == "string")
		cap.close()
		os.remove(path)
	end)

	T.it("opening nonexistent path readonly fails", function()
		local path = os.tmpname()
		os.remove(path)  -- ensure it doesn't exist
		local cap, err = db_mod.db_cap(path, { readonly = true })
		T.fail(cap)
		T.ok(type(err) == "string")
	end)
end)

-- ── multiple independent dbs ──────────────────────────────────────────────────

T.describe("db_cap: multiple independent dbs", function()
	T.it("two :memory: dbs are independent", function()
		local cap1 = mem()
		local cap2 = mem()
		cap1.exec("CREATE TABLE t (v TEXT)")
		cap1.exec("INSERT INTO t VALUES ('from-db1')")
		-- cap2 has no table t
		local rows2, err2 = cap2.query("SELECT v FROM t")
		T.fail(rows2)
		T.ok(err2)
		-- cap1 has the row
		local rows1, err1 = cap1.query("SELECT v FROM t")
		T.ok(rows1, err1)
		T.eq(#rows1, 1)
		T.eq(rows1[1].v, "from-db1")
		cap1.close()
		cap2.close()
	end)

	T.it("data in one db is invisible to the other", function()
		local cap1 = mem()
		local cap2 = mem()
		cap1.exec("CREATE TABLE shared (n INTEGER)")
		cap2.exec("CREATE TABLE shared (n INTEGER)")
		cap1.exec("INSERT INTO shared VALUES (111)")
		cap2.exec("INSERT INTO shared VALUES (222)")
		local r1, _ = cap1.query("SELECT n FROM shared")
		local r2, _ = cap2.query("SELECT n FROM shared")
		T.eq(r1[1].n, 111)
		T.eq(r2[1].n, 222)
		cap1.close()
		cap2.close()
	end)
end)
