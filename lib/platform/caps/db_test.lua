-- lib/platform/caps/db_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local db_mod = require("lib.platform.caps.db")

T.describe("db_cap", function()

	T.it("opens an in-memory database", function()
		local cap, revoke = db_mod.db_cap(":memory:")
		T.ok(cap ~= nil, "cap should not be nil")
		T.ok(revoke ~= nil, "revoke should not be nil")
		cap.close()
	end)

	T.it("executes DDL statements", function()
		local cap, revoke = db_mod.db_cap(":memory:")
		local ok, err = cap.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
		T.ok(ok, "DDL should succeed: " .. tostring(err))
		cap.close()
	end)

	T.it("prepare + exec inserts rows", function()
		local cap = db_mod.db_cap(":memory:")
		cap.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")

		local stmt, err = cap.prepare("INSERT INTO t (name) VALUES (?)")
		T.ok(stmt ~= nil, "prepare should succeed: " .. tostring(err))
		local ok, eerr = stmt.exec("alice")
		T.ok(ok, "exec should succeed: " .. tostring(eerr))
		ok, eerr = stmt.exec("bob")
		T.ok(ok, "exec should succeed: " .. tostring(eerr))
		stmt.close()

		T.eq(cap.last_insert_rowid(), 2)
		cap.close()
	end)

	T.it("prepare + rows iterates results", function()
		local cap = db_mod.db_cap(":memory:")
		cap.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
		cap.execute("INSERT INTO t (name) VALUES ('alice')")
		cap.execute("INSERT INTO t (name) VALUES ('bob')")

		local stmt, err = cap.prepare("SELECT id, name FROM t ORDER BY id")
		T.ok(stmt ~= nil, "prepare should succeed: " .. tostring(err))

		local results = {}
		for id, name in stmt.rows() do
			results[#results + 1] = { id = id, name = name }
		end
		stmt.close()

		T.eq(#results, 2)
		T.eq(results[1].name, "alice")
		T.eq(results[2].name, "bob")
		T.eq(results[1].id, 1)
		T.eq(results[2].id, 2)
		cap.close()
	end)

	T.it("query returns an iterator", function()
		local cap = db_mod.db_cap(":memory:")
		cap.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, val TEXT)")
		cap.execute("INSERT INTO t (val) VALUES ('x')")
		cap.execute("INSERT INTO t (val) VALUES ('y')")

		local iter, err = cap.query("SELECT val FROM t ORDER BY id")
		T.ok(iter ~= nil, "query should return iterator: " .. tostring(err))

		local vals = {}
		for val in iter do
			vals[#vals + 1] = val
		end
		T.eq(#vals, 2)
		T.eq(vals[1], "x")
		T.eq(vals[2], "y")
		cap.close()
	end)

	T.it("changes returns affected row count", function()
		local cap = db_mod.db_cap(":memory:")
		cap.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, val TEXT)")
		cap.execute("INSERT INTO t (val) VALUES ('a')")
		cap.execute("INSERT INTO t (val) VALUES ('b')")
		cap.execute("INSERT INTO t (val) VALUES ('c')")
		cap.execute("UPDATE t SET val = 'z' WHERE id > 1")
		T.eq(cap.changes(), 2)
		cap.close()
	end)

	T.describe("revocation", function()
		T.it("blocks execute after revoke", function()
			local cap, revoke = db_mod.db_cap(":memory:")
			cap.execute("CREATE TABLE t (id INTEGER PRIMARY KEY)")
			revoke()
			local ok, err = cap.execute("INSERT INTO t VALUES (1)")
			T.eq(ok, nil)
			T.ok(err:find("revoked"), "error should mention revoked: " .. tostring(err))
		end)

		T.it("blocks prepare after revoke", function()
			local cap, revoke = db_mod.db_cap(":memory:")
			revoke()
			local stmt, err = cap.prepare("SELECT 1")
			T.eq(stmt, nil)
			T.ok(err:find("revoked"), "error should mention revoked")
		end)

		T.it("blocks query after revoke", function()
			local cap, revoke = db_mod.db_cap(":memory:")
			revoke()
			local iter, err = cap.query("SELECT 1")
			T.eq(iter, nil)
			T.ok(err:find("revoked"), "error should mention revoked")
		end)

		T.it("blocks prepared stmt after revoke", function()
			local cap, revoke = db_mod.db_cap(":memory:")
			cap.execute("CREATE TABLE t (id INTEGER PRIMARY KEY)")
			local stmt = cap.prepare("INSERT INTO t VALUES (?)")
			T.ok(stmt ~= nil)
			revoke()
			local ok, err = stmt.exec(1)
			T.eq(ok, nil)
			T.ok(err:find("revoked"), "error should mention revoked")
		end)

		T.it("blocks last_insert_rowid after revoke", function()
			local cap, revoke = db_mod.db_cap(":memory:")
			revoke()
			local val, err = cap.last_insert_rowid()
			T.eq(val, nil)
			T.ok(err:find("revoked"), "error should mention revoked")
		end)

		T.it("blocks changes after revoke", function()
			local cap, revoke = db_mod.db_cap(":memory:")
			revoke()
			local val, err = cap.changes()
			T.eq(val, nil)
			T.ok(err:find("revoked"), "error should mention revoked")
		end)

		T.it("revoke is idempotent", function()
			local cap, revoke = db_mod.db_cap(":memory:")
			revoke()
			revoke()  -- should not error
			local ok, err = cap.execute("SELECT 1")
			T.eq(ok, nil)
		end)
	end)

	T.describe("readonly mode", function()
		T.it("allows reads", function()
			local cap = db_mod.db_cap(":memory:", { readonly = true })
			-- query_only still allows reading
			local iter, err = cap.query("SELECT 1")
			T.ok(iter ~= nil, "read should work: " .. tostring(err))
			local val = iter()
			T.eq(val, 1)
			cap.close()
		end)

		T.it("blocks writes", function()
			-- Need to create the table first on a writable connection, then
			-- reopen readonly. But :memory: can't be reopened, so we test
			-- that CREATE TABLE itself fails under query_only.
			local cap = db_mod.db_cap(":memory:", { readonly = true })
			local ok, err = cap.execute("CREATE TABLE t (id INTEGER PRIMARY KEY)")
			T.eq(ok, nil)
			T.ok(err ~= nil, "write should fail in readonly mode")
			cap.close()
		end)
	end)

end)

T.describe("caps.db risk", function()
	T.it("writable db has low severity", function()
		local result = db_mod.risk({ type = "db" })
		T.eq(result.severity, "low")
		T.ok(result.text:find("Reads and writes"), "text mentions reads and writes")
	end)

	T.it("readonly db has low severity", function()
		local result = db_mod.risk({ type = "db", readonly = true })
		T.eq(result.severity, "low")
		T.ok(result.text:find("No writes"), "text mentions no writes")
	end)
end)
