-- lib/sqlite/sqlite_test.lua
-- Test coverage for lib/sqlite (FFI wrapper around libsqlite3).
--
-- Platform note: on macOS the module currently calls error() at load time
-- ("os OSX not supported"). Tests are skipped gracefully if sqlite cannot
-- be loaded (missing libsqlite3 or unsupported OS).
--
-- Known bug: db:close() passes self.db (sqlite3 *[1]) to sqlite3_close_v2
-- which expects sqlite3 *. It should use self.db[0]. The bug is tested
-- explicitly below; all other tests omit db:close() to avoid the crash.
-- See TODO.md for the tracked fix.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")

-- Attempt to load sqlite; if it fails, emit a single skipped-style test and stop.
local ok_load, sqlite = pcall(require, "lib.sqlite")
if not ok_load then
	T.describe("sqlite: load", function()
		T.it("sqlite module loaded", function()
			-- Propagate the load error as a clear failure message.
			error("lib.sqlite failed to load: " .. tostring(sqlite))
		end)
	end)
	return
end

-- ── helpers ──────────────────────────────────────────────────────────────────

-- Open a fresh :memory: database or fail immediately.
-- NOTE: db:close() has a bug (passes sqlite3*[1] instead of sqlite3*[0] to
-- sqlite3_close_v2). Omit db:close() in all other tests until that is fixed.
local function mem()
	local db, err = sqlite.open(":memory:")
	assert(db, "sqlite.open(:memory:) failed: " .. tostring(err))
	return db
end

-- Collect all rows from a query iterator into a list of row-tables.
-- column_names is an ordered list; each row becomes { name = value, ... }.
local function collect(iter, column_names)
	local rows = {}
	while true do
		local vals = { iter() }
		-- iterator signals done as nil, "sqlite: done"
		if vals[1] == nil then break end
		local row = {}
		for i, name in ipairs(column_names) do
			row[name] = vals[i]
		end
		rows[#rows + 1] = row
	end
	return rows
end

-- ── open / close ─────────────────────────────────────────────────────────────

T.describe("sqlite: open/close", function()
	T.it("opens an in-memory database", function()
		local db, err = sqlite.open(":memory:")
		T.ok(db, err)
		-- db:close() is intentionally omitted: known bug — see file header.
	end)

	T.it("close() has a type bug (sqlite3*[1] vs sqlite3*)", function()
		-- This test documents the known bug in db:close().
		-- sqlite3_close_v2 expects sqlite3* but receives sqlite3*[1].
		-- When the bug is fixed this test should be updated to assert success.
		local db = mem()
		local ok, err = pcall(function() db:close() end)
		T.fail(ok) -- currently errors; expected to fail until bug is fixed
		T.ok(err:find("sqlite3_close_v2") or err:find("cannot convert"), err)
	end)
end)

-- ── execute: DDL and DML ─────────────────────────────────────────────────────

T.describe("sqlite: execute", function()
	T.it("CREATE TABLE succeeds", function()
		local db = mem()
		local ok, err = db:execute("CREATE TABLE t (id INTEGER PRIMARY KEY, val TEXT)")
		T.ok(ok, err)
	end)

	T.it("INSERT returns true", function()
		local db = mem()
		db:execute("CREATE TABLE t (id INTEGER PRIMARY KEY, val TEXT)")
		local ok, err = db:execute("INSERT INTO t VALUES (1, 'hello')")
		T.ok(ok, err)
	end)

	T.it("multiple statements in one execute call", function()
		local db = mem()
		local ok, err = db:execute(
			"CREATE TABLE a (x INTEGER);" ..
			"INSERT INTO a VALUES (42);" ..
			"INSERT INTO a VALUES (99);"
		)
		T.ok(ok, err)
		T.eq(db:changes(), 1) -- changes() reflects last statement
	end)

	T.it("bad SQL returns nil + error string", function()
		local db = mem()
		local ok, err = db:execute("THIS IS NOT SQL")
		T.fail(ok)
		T.ok(err)
		T.ok(type(err) == "string")
	end)

	T.it("INSERT on nonexistent table returns nil + error", function()
		local db = mem()
		local ok, err = db:execute("INSERT INTO nosuchtable VALUES (1)")
		T.fail(ok)
		T.ok(err)
	end)
end)

-- ── changes / last_insert_rowid ──────────────────────────────────────────────

T.describe("sqlite: changes and last_insert_rowid", function()
	T.it("changes() reflects affected row count", function()
		local db = mem()
		db:execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)")
		db:execute("INSERT INTO t VALUES (1, 10)")
		db:execute("INSERT INTO t VALUES (2, 20)")
		db:execute("UPDATE t SET v = 99")
		T.eq(db:changes(), 2)
	end)

	T.it("last_insert_rowid() returns rowid of most recent insert", function()
		local db = mem()
		db:execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
		db:execute("INSERT INTO t VALUES (7, 'x')")
		T.eq(db:last_insert_rowid(), 7)
		db:execute("INSERT INTO t VALUES (42, 'y')")
		T.eq(db:last_insert_rowid(), 42)
	end)
end)

-- ── query: row iteration ─────────────────────────────────────────────────────

T.describe("sqlite: query row iteration", function()
	T.it("iterates over SELECT results", function()
		local db = mem()
		db:execute("CREATE TABLE t (id INTEGER, name TEXT)")
		db:execute("INSERT INTO t VALUES (1, 'alice')")
		db:execute("INSERT INTO t VALUES (2, 'bob')")

		local iter, err = db:query("SELECT id, name FROM t ORDER BY id")
		T.ok(iter, err)

		local id1, name1 = iter()
		T.eq(id1, 1)
		T.eq(name1, "alice")

		local id2, name2 = iter()
		T.eq(id2, 2)
		T.eq(name2, "bob")

		-- exhausted: iterator returns nil, "sqlite: done"
		local v, msg = iter()
		T.fail(v)
		T.eq(msg, "sqlite: done")
	end)

	T.it("empty result set terminates immediately", function()
		local db = mem()
		db:execute("CREATE TABLE t (id INTEGER)")
		local iter, err = db:query("SELECT id FROM t")
		T.ok(iter, err)
		local v, msg = iter()
		T.fail(v)
		T.eq(msg, "sqlite: done")
	end)

	T.it("collect helper produces correct row list", function()
		local db = mem()
		db:execute("CREATE TABLE t (id INTEGER, val TEXT)")
		db:execute("INSERT INTO t VALUES (10, 'ten')")
		db:execute("INSERT INTO t VALUES (20, 'twenty')")
		local iter = db:query("SELECT id, val FROM t ORDER BY id")
		local rows = collect(iter, { "id", "val" })
		T.eq(#rows, 2)
		T.eq(rows[1].id, 10)
		T.eq(rows[1].val, "ten")
		T.eq(rows[2].id, 20)
		T.eq(rows[2].val, "twenty")
	end)

	T.it("bad SQL in query returns nil + error (not iterator)", function()
		local db = mem()
		local iter, err = db:query("SELECT * FROM nonexistent_table")
		T.fail(iter)
		T.ok(err)
	end)
end)

-- ── parameter binding ────────────────────────────────────────────────────────

T.describe("sqlite: parameter binding", function()
	T.it("binds integer parameter with ?", function()
		local db = mem()
		db:execute("CREATE TABLE t (id INTEGER, v TEXT)")
		db:execute("INSERT INTO t VALUES (1, 'a')")
		db:execute("INSERT INTO t VALUES (2, 'b')")
		local iter, err = db:query("SELECT v FROM t WHERE id = ?", 1)
		T.ok(iter, err)
		local v = iter()
		T.eq(v, "a")
	end)

	T.it("binds string parameter with ?", function()
		local db = mem()
		db:execute("CREATE TABLE t (id INTEGER, name TEXT)")
		db:execute("INSERT INTO t VALUES (1, 'alice')")
		db:execute("INSERT INTO t VALUES (2, 'bob')")
		local iter, err = db:query("SELECT id FROM t WHERE name = ?", "alice")
		T.ok(iter, err)
		local id = iter()
		T.eq(id, 1)
	end)

	T.it("binds multiple parameters", function()
		local db = mem()
		db:execute("CREATE TABLE t (a INTEGER, b INTEGER, c TEXT)")
		db:execute("INSERT INTO t VALUES (1, 2, 'match')")
		db:execute("INSERT INTO t VALUES (1, 3, 'no')")
		local iter, err = db:query("SELECT c FROM t WHERE a = ? AND b = ?", 1, 2)
		T.ok(iter, err)
		local c = iter()
		T.eq(c, "match")
		local v2, msg = iter()
		T.fail(v2)
		T.eq(msg, "sqlite: done")
	end)

	T.it("binds boolean: true → 1, false → 0", function()
		local db = mem()
		db:execute("CREATE TABLE t (flag INTEGER)")
		db:execute("INSERT INTO t VALUES (?)", true)
		db:execute("INSERT INTO t VALUES (?)", false)
		local iter = db:query("SELECT flag FROM t ORDER BY rowid")
		local v1 = iter()
		local v2 = iter()
		-- sqlite stores as INTEGER; returned as number via column_double
		T.eq(v1, 1)
		T.eq(v2, 0)
	end)

	T.it("binds nil as NULL", function()
		local db = mem()
		db:execute("CREATE TABLE t (x INTEGER, y INTEGER)")
		-- bind two params, second is nil (NULL)
		db:execute("INSERT INTO t VALUES (?, ?)", 5, nil)
		local iter = db:query("SELECT x, y FROM t")
		local x, y = iter()
		T.eq(x, 5)
		-- NULL comes back as nil from the SQLITE_NULL dispatch branch
		T.fail(y)
	end)

	T.it("execute with bound parameter", function()
		local db = mem()
		db:execute("CREATE TABLE t (id INTEGER, v TEXT)")
		db:execute("INSERT INTO t VALUES (1, 'old')")
		local ok, err = db:execute("UPDATE t SET v = ? WHERE id = ?", "new", 1)
		T.ok(ok, err)
		local iter = db:query("SELECT v FROM t WHERE id = 1")
		local v = iter()
		T.eq(v, "new")
	end)
end)

-- ── value round-trips ────────────────────────────────────────────────────────

T.describe("sqlite: value round-trips", function()
	T.it("integer round-trip", function()
		local db = mem()
		db:execute("CREATE TABLE t (v INTEGER)")
		db:execute("INSERT INTO t VALUES (?)", 12345)
		local iter = db:query("SELECT v FROM t")
		local v = iter()
		T.eq(v, 12345)
	end)

	T.it("float round-trip", function()
		local db = mem()
		db:execute("CREATE TABLE t (v REAL)")
		db:execute("INSERT INTO t VALUES (?)", 3.14)
		local iter = db:query("SELECT v FROM t")
		local v = iter()
		-- Doubles survive a sqlite round-trip exactly for well-represented values.
		T.eq(v, 3.14)
	end)

	T.it("string round-trip (plain ASCII)", function()
		local db = mem()
		db:execute("CREATE TABLE t (v TEXT)")
		db:execute("INSERT INTO t VALUES (?)", "hello, world!")
		local iter = db:query("SELECT v FROM t")
		local v = iter()
		T.eq(v, "hello, world!")
	end)

	T.it("string round-trip (UTF-8 multi-byte)", function()
		local db = mem()
		db:execute("CREATE TABLE t (v TEXT)")
		local s = "\227\129\147\227\130\147\227\129\171\227\129\161\227\129\175" -- こんにちは in UTF-8
		db:execute("INSERT INTO t VALUES (?)", s)
		local iter = db:query("SELECT v FROM t")
		local v = iter()
		T.eq(v, s)
	end)

	T.it("empty string round-trip", function()
		local db = mem()
		db:execute("CREATE TABLE t (v TEXT)")
		db:execute("INSERT INTO t VALUES (?)", "")
		local iter = db:query("SELECT v FROM t")
		local v = iter()
		T.eq(v, "")
	end)

	T.it("NULL value round-trip", function()
		local db = mem()
		db:execute("CREATE TABLE t (v INTEGER)")
		db:execute("INSERT INTO t VALUES (?)", nil)
		-- NULL columns come back as nil; query iterator signals done with nil too,
		-- so we use a sentinel first column and ignore it (as documented in query()).
		local iter = db:query("SELECT 1, v FROM t")
		local sentinel, v = iter()
		T.eq(sentinel, 1)
		T.fail(v) -- nil
	end)

	-- TODO: blob binding — the bind() function in init.lua has no branch for
	-- Lua strings passed as blobs (strings go through bind_text). sqlite3_bind_blob
	-- is declared in the FFI cdef but is not reachable from the Lua API. To support
	-- explicit blob binding a separate db:execute_blob() or a special wrapper type
	-- would be needed.
	T.it("blob stored via TEXT binding is retrieved as Lua string", function()
		local db = mem()
		db:execute("CREATE TABLE t (v BLOB)")
		-- Binary data stored as TEXT binding; SQLite will return it as BLOB or TEXT.
		local bin = "\0\1\2\3\255"
		db:execute("INSERT INTO t VALUES (?)", bin)
		-- BLOB columns are retrieved with column_blob + ffi.string, same as TEXT.
		local iter = db:query("SELECT v FROM t")
		local v = iter()
		T.eq(#v, #bin)
		T.eq(v, bin)
	end)
end)

-- ── tables() metadata ────────────────────────────────────────────────────────

T.describe("sqlite: tables() metadata", function()
	T.it("tables() returns created tables", function()
		local db = mem()
		db:execute("CREATE TABLE alpha (x INTEGER)")
		db:execute("CREATE TABLE beta (y TEXT)")

		local names = {}
		for t in db:tables() do
			names[#names + 1] = t.name
		end
		-- sqlite_schema returns tables ORDER BY name
		T.eq(#names, 2)
		T.eq(names[1], "alpha")
		T.eq(names[2], "beta")
	end)

	T.it("tables() is empty for a fresh database", function()
		local db = mem()
		local count = 0
		for _ in db:tables() do count = count + 1 end
		T.eq(count, 0)
	end)

	T.it("table metadata has expected fields", function()
		local db = mem()
		db:execute("CREATE TABLE mytest (id INTEGER PRIMARY KEY)")
		local t
		for row in db:tables() do t = row end
		T.ok(t)
		T.eq(t.name, "mytest")
		T.eq(t.type, "table")
		T.ok(t.sql)  -- the CREATE TABLE SQL
	end)
end)

-- ── get_autocommit ───────────────────────────────────────────────────────────

T.describe("sqlite: get_autocommit", function()
	T.it("autocommit is true by default (no open transaction)", function()
		local db = mem()
		T.ok(db:get_autocommit())
	end)

	T.it("autocommit is false inside BEGIN ... COMMIT", function()
		local db = mem()
		db:execute("BEGIN")
		T.fail(db:get_autocommit())
		db:execute("COMMIT")
		T.ok(db:get_autocommit())
	end)
end)

-- ── error paths ──────────────────────────────────────────────────────────────

T.describe("sqlite: error paths", function()
	T.it("error message is a non-empty string", function()
		local db = mem()
		local ok, err = db:execute("SELECT * FROM nonexistent")
		T.fail(ok)
		T.ok(type(err) == "string")
		T.ok(#err > 0)
	end)

	T.it("constraint violation returns nil + error", function()
		local db = mem()
		db:execute("CREATE TABLE t (id INTEGER PRIMARY KEY)")
		db:execute("INSERT INTO t VALUES (1)")
		local ok, err = db:execute("INSERT INTO t VALUES (1)") -- duplicate PK
		T.fail(ok)
		T.ok(err)
	end)

	T.it("binding wrong type errors with descriptive message", function()
		local db = mem()
		db:execute("CREATE TABLE t (v INTEGER)")
		T.throws(function()
			db:execute("INSERT INTO t VALUES (?)", {})  -- table is not bindable
		end)
	end)
end)
