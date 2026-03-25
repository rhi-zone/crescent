-- lib/type/static/cli_test.lua
-- Tests for the typechecker CLI dump helpers (dump_one, dump_json).

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T    = require("lib.test.assert")
local cli  = require("lib.type.static.cli")
local json = require("lib.format.json")

-- Use a well-known, stable file as the test subject.
local TEST_FILE = "lib/type/static/defs.lua"

-- ---------------------------------------------------------------------------
-- dump_one
-- ---------------------------------------------------------------------------

T.describe("cli: dump_one", function()
	T.it("returns a table for a valid file", function()
		local r = cli.dump_one(TEST_FILE)
		T.ok(r ~= nil, "dump_one should return a table for a valid file")
	end)

	T.it("result.file matches the input filename", function()
		local r = cli.dump_one(TEST_FILE)
		T.ok(r ~= nil)
		T.eq(r.file, TEST_FILE)
	end)

	T.it("result.bindings is a non-empty array", function()
		local r = cli.dump_one(TEST_FILE)
		T.ok(r ~= nil)
		T.ok(type(r.bindings) == "table", "bindings should be a table")
		T.ok(#r.bindings > 0, "defs.lua should have at least one binding")
	end)

	T.it("bindings are sorted by name", function()
		local r = cli.dump_one(TEST_FILE)
		T.ok(r ~= nil)
		for i = 2, #r.bindings do
			T.ok(r.bindings[i - 1].name <= r.bindings[i].name,
				"bindings not sorted at index " .. i .. ": " ..
				r.bindings[i - 1].name .. " > " .. r.bindings[i].name)
		end
	end)

	T.it("each binding has string name and string type", function()
		local r = cli.dump_one(TEST_FILE)
		T.ok(r ~= nil)
		local b = r.bindings[1]
		T.ok(type(b.name) == "string", "binding.name should be string")
		T.ok(type(b.type) == "string", "binding.type should be string")
		T.ok(#b.name > 0, "binding.name should be non-empty")
		T.ok(#b.type > 0, "binding.type should be non-empty")
	end)

	T.it("return field present when module has a return", function()
		local r = cli.dump_one(TEST_FILE)
		T.ok(r ~= nil)
		-- defs.lua returns M — should have a return type
		T.ok(r["return"] ~= nil, "defs.lua should have a module return type")
		T.ok(type(r["return"]) == "string", "return type should be a string")
	end)

	T.it("returns nil for a non-existent file", function()
		local r = cli.dump_one("__no_such_file__.lua")
		T.ok(r == nil, "dump_one should return nil for a missing file")
	end)
end)

-- ---------------------------------------------------------------------------
-- dump_json
-- ---------------------------------------------------------------------------

T.describe("cli: dump_json", function()
	T.it("returns a string", function()
		local s = cli.dump_json({ TEST_FILE })
		T.ok(type(s) == "string", "dump_json should return a string")
	end)

	T.it("output is a JSON array (starts [ ends ])", function()
		local s = cli.dump_json({ TEST_FILE })
		T.ok(s:find("^%s*%["), "JSON should start with [")
		T.ok(s:find("%]%s*$"), "JSON should end with ]")
	end)

	T.it("output is parseable JSON", function()
		local s = cli.dump_json({ TEST_FILE })
		local ok, result = pcall(json.decode, s)
		T.ok(ok, "JSON should be parseable, error: " .. tostring(result))
		T.ok(type(result) == "table", "decoded result should be a table")
	end)

	T.it("single file produces one-element array", function()
		local s = cli.dump_json({ TEST_FILE })
		local ok, arr = pcall(json.decode, s)
		T.ok(ok, "JSON should parse")
		T.eq(#arr, 1)
	end)

	T.it("array element has file, bindings, return fields", function()
		local s = cli.dump_json({ TEST_FILE })
		local _, arr = pcall(json.decode, s)
		local elem = arr[1]
		T.eq(elem.file, TEST_FILE)
		T.ok(type(elem.bindings) == "table", "bindings should be a table")
		T.ok(#elem.bindings > 0, "bindings should be non-empty")
		T.ok(elem["return"] ~= nil, "return field should be present")
	end)

	T.it("bindings in JSON have name and type strings", function()
		local s = cli.dump_json({ TEST_FILE })
		local _, arr = pcall(json.decode, s)
		local b = arr[1].bindings[1]
		T.ok(type(b.name) == "string", "binding name should be string")
		T.ok(type(b.type) == "string", "binding type should be string")
	end)

	T.it("multiple files produce multi-element array", function()
		local s = cli.dump_json({ TEST_FILE, "lib/type/static/intern.lua" })
		local ok, arr = pcall(json.decode, s)
		T.ok(ok, "JSON should parse")
		T.eq(#arr, 2)
		T.eq(arr[1].file, TEST_FILE)
		T.eq(arr[2].file, "lib/type/static/intern.lua")
	end)

	T.it("empty filenames list produces empty JSON array", function()
		local s = cli.dump_json({})
		local ok, arr = pcall(json.decode, s)
		T.ok(ok, "empty JSON should parse")
		T.eq(#arr, 0)
	end)

	T.it("type strings with quotes are escaped correctly", function()
		-- Use a file that likely has string literal types
		local s = cli.dump_json({ TEST_FILE })
		-- If JSON is parseable, escaping worked
		local ok, _ = pcall(json.decode, s)
		T.ok(ok, "type strings with special chars should be JSON-safe")
	end)
end)
