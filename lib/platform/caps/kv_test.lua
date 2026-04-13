-- lib/platform/caps/kv_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local kv = require("lib.platform.caps.kv")

-- ── helpers ───────────────────────────────────────────────────────────────────

-- Create a temp file path for an in-memory-like SQLite db (unique per test).
local function tmpdb()
	local path = os.tmpname()
	-- os.tmpname creates the file; SQLite will overwrite it, so this is fine.
	return path
end

local function rmfile(path)
	os.remove(path)
end

-- ── tests ─────────────────────────────────────────────────────────────────────

T.describe("kv_cap", function()

	T.describe("basic ops", function()
		T.it("get returns nil for missing key", function()
			local path = tmpdb()
			local cap = kv.kv_cap(path)
			T.eq(cap.get("missing"), nil)
			rmfile(path)
		end)

		T.it("set and get round-trips a value", function()
			local path = tmpdb()
			local cap = kv.kv_cap(path)
			cap.set("foo", "bar")
			T.eq(cap.get("foo"), "bar")
			rmfile(path)
		end)

		T.it("set nil deletes the key", function()
			local path = tmpdb()
			local cap = kv.kv_cap(path)
			cap.set("x", "hello")
			T.eq(cap.get("x"), "hello")
			cap.set("x", nil)
			T.eq(cap.get("x"), nil)
			rmfile(path)
		end)

		T.it("delete on absent key does not error", function()
			local path = tmpdb()
			local cap = kv.kv_cap(path)
			cap.set("absent", nil)  -- should not throw
			T.eq(cap.get("absent"), nil)
			rmfile(path)
		end)

		T.it("overwrite: second set wins", function()
			local path = tmpdb()
			local cap = kv.kv_cap(path)
			cap.set("k", "first")
			cap.set("k", "second")
			T.eq(cap.get("k"), "second")
			rmfile(path)
		end)
	end)

	T.describe("persistence", function()
		T.it("value survives a new cap opened on same path", function()
			local path = tmpdb()
			local cap1 = kv.kv_cap(path)
			cap1.set("persist", "yes")
			-- Open a second cap on the same file
			local cap2 = kv.kv_cap(path)
			T.eq(cap2.get("persist"), "yes")
			rmfile(path)
		end)
	end)

	T.describe("allowlist: nil = unrestricted", function()
		T.it("allows any key when allow is nil", function()
			local path = tmpdb()
			local cap = kv.kv_cap(path)  -- no opts.allow
			cap.set("anything", "value")
			T.eq(cap.get("anything"), "value")
			rmfile(path)
		end)
	end)

	T.describe("allowlist: exact match", function()
		T.it("allows an exact-match key", function()
			local path = tmpdb()
			local cap = kv.kv_cap(path, { allow = { "state", "flag" } })
			cap.set("state", "on")
			T.eq(cap.get("state"), "on")
			rmfile(path)
		end)

		T.it("denies a key not in allowlist", function()
			local path = tmpdb()
			local cap = kv.kv_cap(path, { allow = { "state" } })
			local ok, err = pcall(function() cap.get("secret") end)
			T.ok(not ok, "expected error for denied key")
			T.ok(err:find("not allowed") ~= nil, "error message contains 'not allowed'")
			rmfile(path)
		end)

		T.it("denies set on a denied key", function()
			local path = tmpdb()
			local cap = kv.kv_cap(path, { allow = { "state" } })
			local ok = pcall(function() cap.set("secret", "value") end)
			T.ok(not ok, "expected error for denied key on set")
			rmfile(path)
		end)

		T.it("exact entry does not match key with same prefix", function()
			-- allow "state" should NOT allow "state.foo"
			local path = tmpdb()
			local cap = kv.kv_cap(path, { allow = { "state" } })
			local ok = pcall(function() cap.get("state.foo") end)
			T.ok(not ok, "exact entry should not match longer key")
			rmfile(path)
		end)
	end)

	T.describe("allowlist: prefix match", function()
		T.it("allows key matching prefix entry", function()
			local path = tmpdb()
			local cap = kv.kv_cap(path, { allow = { "prefs." } })
			cap.set("prefs.theme", "dark")
			T.eq(cap.get("prefs.theme"), "dark")
			rmfile(path)
		end)

		T.it("allows key exactly equal to prefix (with trailing dot)", function()
			-- "prefs." entry matches key "prefs.x"; key "prefs." itself also matches
			local path = tmpdb()
			local cap = kv.kv_cap(path, { allow = { "prefs." } })
			cap.set("prefs.", "val")
			T.eq(cap.get("prefs."), "val")
			rmfile(path)
		end)

		T.it("denies key not matching the prefix", function()
			local path = tmpdb()
			local cap = kv.kv_cap(path, { allow = { "prefs." } })
			local ok = pcall(function() cap.get("other.key") end)
			T.ok(not ok, "expected denial for non-matching prefix")
			rmfile(path)
		end)

		T.it("prefix and exact in same allowlist both work", function()
			local path = tmpdb()
			local cap = kv.kv_cap(path, { allow = { "state", "prefs." } })
			cap.set("state", "active")
			cap.set("prefs.lang", "en")
			T.eq(cap.get("state"), "active")
			T.eq(cap.get("prefs.lang"), "en")
			-- denied key still errors
			local ok = pcall(function() cap.get("other") end)
			T.ok(not ok)
			rmfile(path)
		end)
	end)

	T.describe("readonly", function()
		T.it("get works in readonly mode", function()
			local path = tmpdb()
			-- Seed data with a writable cap first.
			local cap_rw = kv.kv_cap(path)
			cap_rw.set("k", "v")
			-- Open readonly on same file.
			local cap_ro = kv.kv_cap(path, { readonly = true })
			T.eq(cap_ro.get("k"), "v")
			rmfile(path)
		end)

		T.it("set errors in readonly mode", function()
			local path = tmpdb()
			local cap = kv.kv_cap(path, { readonly = true })
			local ok, err = pcall(function() cap.set("k", "v") end)
			T.ok(not ok, "expected error for readonly set")
			T.ok(tostring(err):find("readonly") ~= nil, "error mentions readonly")
			rmfile(path)
		end)

		T.it("delete (set nil) errors in readonly mode", function()
			local path = tmpdb()
			local cap = kv.kv_cap(path, { readonly = true })
			local ok = pcall(function() cap.set("k", nil) end)
			T.ok(not ok, "expected error for readonly delete")
			rmfile(path)
		end)

		T.it("readonly check happens before allowlist check", function()
			local path = tmpdb()
			local cap = kv.kv_cap(path, { readonly = true, allow = { "safe" } })
			-- Even an allowed key should fail on set with "readonly", not "not allowed"
			local ok, err = pcall(function() cap.set("safe", "v") end)
			T.ok(not ok)
			T.ok(tostring(err):find("readonly") ~= nil)
			rmfile(path)
		end)
	end)

	T.describe("error message format", function()
		T.it("error contains the denied key name", function()
			local path = tmpdb()
			local cap = kv.kv_cap(path, { allow = { "safe" } })
			local ok, err = pcall(function() cap.get("forbidden") end)
			T.ok(not ok)
			T.ok(err:find("forbidden") ~= nil, "error should contain key name")
			rmfile(path)
		end)
	end)

end)
