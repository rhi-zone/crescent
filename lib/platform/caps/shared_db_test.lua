-- lib/platform/caps/shared_db_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")

local ok_load, sdb = pcall(require, "lib.platform.caps.shared_db")
if not ok_load then
	T.describe("shared_db_cap: load", function()
		T.it("module loaded", function()
			error("lib.platform.caps.shared_db failed to load: " .. tostring(sdb))
		end)
	end)
	return
end

local db_mod = require("lib.platform.caps.db")

-- ── helpers ──────────────────────────────────────────────────────────────────

local function setup_shared_db()
	local path = os.tmpname()
	-- Create schema using setup_schema.
	local ok, err = sdb.setup_schema(path, {
		{ name = "sessions", cols = "id TEXT PRIMARY KEY, app_id TEXT NOT NULL, title TEXT" },
		{ name = "messages", cols = "id TEXT PRIMARY KEY, session_id TEXT NOT NULL, app_id TEXT NOT NULL, role TEXT NOT NULL, content TEXT NOT NULL" },
	})
	assert(ok, "setup_schema failed: " .. tostring(err))
	-- Seed data directly into base tables.
	local cap = assert(db_mod.db_cap(path, { allow_write = true }))
	cap.execute("INSERT INTO _sessions VALUES ('s1', 'app_a', 'Session A')")
	cap.execute("INSERT INTO _sessions VALUES ('s2', 'app_b', 'Session B')")
	cap.execute("INSERT INTO _sessions VALUES ('s3', 'app_a', 'Another A')")
	cap.execute("INSERT INTO _messages VALUES ('m1', 's1', 'app_a', 'user', 'hello from A')")
	cap.execute("INSERT INTO _messages VALUES ('m2', 's2', 'app_b', 'user', 'hello from B')")
	cap.execute("INSERT INTO _messages VALUES ('m3', 's1', 'app_a', 'assistant', 'reply from A')")
	cap.close()
	return path
end

-- ── read isolation ──────────────────────────────────────────────────────────

T.describe("shared_db_cap: read isolation", function()
	T.it("opens successfully", function()
		local path = setup_shared_db()
		local cap, err = sdb.shared_db_cap(path, "app_a", {"sessions", "messages"})
		T.ok(cap, err)
		cap.close()
		os.remove(path)
	end)

	T.it("app_a only sees its own sessions", function()
		local path = setup_shared_db()
		local cap = assert(sdb.shared_db_cap(path, "app_a", {"sessions", "messages"}))
		local rows, err = cap.query("SELECT id, title FROM sessions ORDER BY id")
		T.ok(rows, err)
		T.eq(#rows, 2)
		T.eq(rows[1].id, "s1")
		T.eq(rows[1].title, "Session A")
		T.eq(rows[2].id, "s3")
		T.eq(rows[2].title, "Another A")
		cap.close()
		os.remove(path)
	end)

	T.it("app_b only sees its own sessions", function()
		local path = setup_shared_db()
		local cap = assert(sdb.shared_db_cap(path, "app_b", {"sessions", "messages"}))
		local rows, err = cap.query("SELECT id, title FROM sessions ORDER BY id")
		T.ok(rows, err)
		T.eq(#rows, 1)
		T.eq(rows[1].id, "s2")
		T.eq(rows[1].title, "Session B")
		cap.close()
		os.remove(path)
	end)

	T.it("app_a only sees its own messages", function()
		local path = setup_shared_db()
		local cap = assert(sdb.shared_db_cap(path, "app_a", {"sessions", "messages"}))
		local rows, err = cap.query("SELECT id, content FROM messages ORDER BY id")
		T.ok(rows, err)
		T.eq(#rows, 2)
		T.eq(rows[1].id, "m1")
		T.eq(rows[2].id, "m3")
		cap.close()
		os.remove(path)
	end)

	T.it("query with params works through views", function()
		local path = setup_shared_db()
		local cap = assert(sdb.shared_db_cap(path, "app_a", {"sessions", "messages"}))
		local rows, err = cap.query("SELECT title FROM sessions WHERE id = ?", {"s1"})
		T.ok(rows, err)
		T.eq(#rows, 1)
		T.eq(rows[1].title, "Session A")
		cap.close()
		os.remove(path)
	end)
end)

-- ── authorizer ──────────────────────────────────────────────────────────────

T.describe("shared_db_cap: authorizer", function()
	T.it("blocks direct read of base table", function()
		local path = setup_shared_db()
		local cap = assert(sdb.shared_db_cap(path, "app_a", {"sessions", "messages"}))
		local rows, err = cap.query("SELECT * FROM _sessions")
		T.fail(rows)
		T.ok(type(err) == "string")
		cap.close()
		os.remove(path)
	end)

	T.it("blocks direct INSERT on base table", function()
		local path = setup_shared_db()
		local cap = assert(sdb.shared_db_cap(path, "app_a", {"sessions", "messages"}, { allow_write = true }))
		local ok, err = cap.execute("INSERT INTO _sessions VALUES ('sx', 'app_a', 'hacked')")
		T.fail(ok)
		T.ok(type(err) == "string")
		cap.close()
		os.remove(path)
	end)

	T.it("blocks DDL on main schema", function()
		local path = setup_shared_db()
		local cap = assert(sdb.shared_db_cap(path, "app_a", {"sessions", "messages"}, { allow_write = true }))
		local ok, err = cap.execute("CREATE TABLE evil (x TEXT)")
		T.fail(ok)
		T.ok(type(err) == "string")
		cap.close()
		os.remove(path)
	end)

	T.it("blocks DROP TABLE", function()
		local path = setup_shared_db()
		local cap = assert(sdb.shared_db_cap(path, "app_a", {"sessions", "messages"}, { allow_write = true }))
		local ok, err = cap.execute("DROP TABLE sessions")
		T.fail(ok)
		T.ok(type(err) == "string")
		cap.close()
		os.remove(path)
	end)

	T.it("blocks ATTACH", function()
		local path = setup_shared_db()
		local cap = assert(sdb.shared_db_cap(path, "app_a", {"sessions", "messages"}, { allow_write = true }))
		local ok, err = cap.execute("ATTACH DATABASE ':memory:' AS other")
		T.fail(ok)
		T.ok(type(err) == "string")
		cap.close()
		os.remove(path)
	end)
end)

-- ── writes through views ────────────────────────────────────────────────────

T.describe("shared_db_cap: writes through views", function()
	T.it("INSERT via view auto-sets app_id", function()
		local path = setup_shared_db()
		local cap = assert(sdb.shared_db_cap(path, "app_a", {"sessions", "messages"}, { allow_write = true }))
		local ok, err = cap.execute("INSERT INTO sessions (id, app_id, title) VALUES ('s4', 'ignored', 'New Session')")
		T.ok(ok, err)
		-- Visible through the filtered view.
		local rows = assert(cap.query("SELECT id, title FROM sessions WHERE id = 's4'"))
		T.eq(#rows, 1)
		T.eq(rows[1].title, "New Session")
		cap.close()
		-- Verify app_id was forced to app_a (not 'ignored').
		local host = assert(db_mod.db_cap(path))
		local app_id_val = host.query("SELECT app_id FROM _sessions WHERE id = 's4'")()
		T.eq(app_id_val, "app_a")
		host.close()
		os.remove(path)
	end)

	T.it("DELETE only affects own rows", function()
		local path = setup_shared_db()
		local cap_a = assert(sdb.shared_db_cap(path, "app_a", {"sessions", "messages"}, { allow_write = true }))
		local ok, err = cap_a.execute("DELETE FROM sessions WHERE id = 's1'")
		T.ok(ok, err)
		-- s1 gone from app_a's view.
		local rows = assert(cap_a.query("SELECT id FROM sessions ORDER BY id"))
		T.eq(#rows, 1)
		T.eq(rows[1].id, "s3")
		cap_a.close()
		-- app_b's data is untouched.
		local host = assert(db_mod.db_cap(path))
		local b_id = host.query("SELECT id FROM _sessions WHERE app_id = 'app_b'")()
		T.eq(b_id, "s2")
		host.close()
		os.remove(path)
	end)

	T.it("cannot delete another app's rows", function()
		local path = setup_shared_db()
		local cap_a = assert(sdb.shared_db_cap(path, "app_a", {"sessions", "messages"}, { allow_write = true }))
		-- Try to delete app_b's session — the trigger's app_id constraint prevents it.
		cap_a.execute("DELETE FROM sessions WHERE id = 's2'")
		cap_a.close()
		-- s2 still exists.
		local host = assert(db_mod.db_cap(path))
		local s2_id = host.query("SELECT id FROM _sessions WHERE id = 's2'")()
		T.eq(s2_id, "s2")
		host.close()
		os.remove(path)
	end)

	T.it("UPDATE only affects own rows", function()
		local path = setup_shared_db()
		local cap_a = assert(sdb.shared_db_cap(path, "app_a", {"sessions", "messages"}, { allow_write = true }))
		local ok, err = cap_a.execute("UPDATE sessions SET title = 'Updated' WHERE id = 's1'")
		T.ok(ok, err)
		local rows = assert(cap_a.query("SELECT title FROM sessions WHERE id = 's1'"))
		T.eq(#rows, 1)
		T.eq(rows[1].title, "Updated")
		cap_a.close()
		-- app_b's session untouched.
		local host = assert(db_mod.db_cap(path))
		local b_title = host.query("SELECT title FROM _sessions WHERE id = 's2'")()
		T.eq(b_title, "Session B")
		host.close()
		os.remove(path)
	end)

	T.it("cannot update another app's rows", function()
		local path = setup_shared_db()
		local cap_a = assert(sdb.shared_db_cap(path, "app_a", {"sessions", "messages"}, { allow_write = true }))
		cap_a.execute("UPDATE sessions SET title = 'Hacked' WHERE id = 's2'")
		cap_a.close()
		-- s2 still has original title.
		local host = assert(db_mod.db_cap(path))
		local s2_title = host.query("SELECT title FROM _sessions WHERE id = 's2'")()
		T.eq(s2_title, "Session B")
		host.close()
		os.remove(path)
	end)
end)

-- ── readonly mode (allow_write = false) ─────────────────────────────────────

T.describe("shared_db_cap: readonly (allow_write=false)", function()
	T.it("query works when allow_write is false", function()
		local path = setup_shared_db()
		local cap, err = sdb.shared_db_cap(path, "app_a", {"sessions", "messages"})
		T.ok(cap, err)
		local rows = assert(cap.query("SELECT id FROM sessions ORDER BY id"))
		T.eq(#rows, 2)
		cap.close()
		os.remove(path)
	end)

	T.it("execute is not exposed when allow_write is false", function()
		local path = setup_shared_db()
		local cap = assert(sdb.shared_db_cap(path, "app_a", {"sessions", "messages"}))
		T.eq(cap.execute, nil)
		cap.close()
		os.remove(path)
	end)
end)

-- ── multiple concurrent caps ────────────────────────────────────────────────

T.describe("shared_db_cap: concurrent caps", function()
	T.it("two apps have isolated views of the same db", function()
		local path = setup_shared_db()
		local cap_a = assert(sdb.shared_db_cap(path, "app_a", {"sessions", "messages"}, { allow_write = true }))
		local cap_b = assert(sdb.shared_db_cap(path, "app_b", {"sessions", "messages"}))

		local a_rows = assert(cap_a.query("SELECT id FROM sessions ORDER BY id"))
		local b_rows = assert(cap_b.query("SELECT id FROM sessions ORDER BY id"))
		T.eq(#a_rows, 2)  -- s1, s3
		T.eq(#b_rows, 1)  -- s2

		-- app_a inserts; app_b doesn't see it.
		cap_a.execute("INSERT INTO sessions (id, app_id, title) VALUES ('s5', 'app_a', 'A only')")
		local a2 = assert(cap_a.query("SELECT id FROM sessions WHERE id = 's5'"))
		T.eq(#a2, 1)
		local b2 = assert(cap_b.query("SELECT id FROM sessions WHERE id = 's5'"))
		T.eq(#b2, 0)

		cap_a.close()
		cap_b.close()
		os.remove(path)
	end)
end)

T.describe("caps.shared_db risk", function()
	T.it("writable shared_db has medium severity", function()
		local result = sdb.risk({ type = "shared_db", allow_write = true })
		T.eq(result.severity, "medium")
	end)

	T.it("readonly shared_db has low severity", function()
		local result = sdb.risk({ type = "shared_db" })
		T.eq(result.severity, "low")
	end)
end)
