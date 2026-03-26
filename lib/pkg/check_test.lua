if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T     = require("lib.test.assert")
local check = require("lib.pkg.check")

-- ── helpers ───────────────────────────────────────────────────────────────────

local function make_tmpdir()
	local path = os.tmpname()
	os.remove(path)
	os.execute(("mkdir -p %q"):format(path))
	return path
end

local function rm_tmpdir(path)
	os.execute(("rm -rf %q"):format(path))
end

local function write_file(path, content)
	local f, err = io.open(path, "w")
	if not f then error("write_file failed for " .. path .. ": " .. tostring(err)) end
	f:write(content)
	f:close()
end

-- Write a minimal pkg.lua for a package.
-- deps is a table of { name = constraint_string }.
local function write_pkg(dir, name, deps)
	local lines = { "return {" }
	lines[#lines + 1] = ("  name    = %q,"):format(name)
	lines[#lines + 1] = '  version = "1.0.0",'
	lines[#lines + 1] = "  deps = {"
	for dep_name, constraint in pairs(deps or {}) do
		lines[#lines + 1] = ('    %s = %q,'):format(dep_name, constraint)
	end
	lines[#lines + 1] = "  },"
	lines[#lines + 1] = "}"
	write_file(dir .. "/pkg.lua", table.concat(lines, "\n") .. "\n")
end

-- ── tests ─────────────────────────────────────────────────────────────────────

T.describe("check.scan — clean package", function()

	T.it("no phantom deps: clean package returns ok=true, empty phantoms", function()
		local tmp = make_tmpdir()
		write_pkg(tmp, "mypkg", { foo = "^1.0" })
		write_file(tmp .. "/init.lua", 'local foo = require("lib.foo")\nreturn {}\n')
		local r = check.scan(tmp)
		T.eq(r.ok, true)
		T.eq(#r.phantoms, 0)
		rm_tmpdir(tmp)
	end)

	T.it("no source files → ok=true, no phantoms", function()
		local tmp = make_tmpdir()
		write_pkg(tmp, "mypkg", {})
		-- no .lua files besides pkg.lua (which is not scanned as source)
		local r = check.scan(tmp)
		T.eq(r.ok, true)
		T.eq(#r.phantoms, 0)
		rm_tmpdir(tmp)
	end)

end)

T.describe("check.scan — phantom detection", function()

	T.it("single phantom: file requires lib.foo, foo not in deps", function()
		local tmp = make_tmpdir()
		write_pkg(tmp, "mypkg", {})
		write_file(tmp .. "/init.lua", 'local foo = require("lib.foo")\nreturn {}\n')
		local r = check.scan(tmp)
		T.eq(r.ok, false)
		T.eq(#r.phantoms, 1)
		local p = r.phantoms[1]
		T.eq(p.name, "foo")
		T.eq(p.require_path, "lib.foo")
		T.ok(p.file:find("init%.lua$"), "file field ends with init.lua")
		rm_tmpdir(tmp)
	end)

	T.it("declared dep: file requires lib.foo, foo IS in deps → no phantom", function()
		local tmp = make_tmpdir()
		write_pkg(tmp, "mypkg", { foo = "^1.0" })
		write_file(tmp .. "/init.lua", 'local foo = require("lib.foo")\nreturn {}\n')
		local r = check.scan(tmp)
		T.eq(r.ok, true)
		T.eq(#r.phantoms, 0)
		rm_tmpdir(tmp)
	end)

	T.it("self-require: package bar requires lib.bar.util → not a phantom", function()
		local tmp = make_tmpdir()
		write_pkg(tmp, "bar", {})
		write_file(tmp .. "/init.lua", 'local util = require("lib.bar.util")\nreturn {}\n')
		local r = check.scan(tmp)
		T.eq(r.ok, true)
		T.eq(#r.phantoms, 0)
		rm_tmpdir(tmp)
	end)

	T.it("multiple files: phantoms from multiple files all collected", function()
		local tmp = make_tmpdir()
		write_pkg(tmp, "mypkg", {})
		write_file(tmp .. "/a.lua", 'local foo = require("lib.foo")\n')
		write_file(tmp .. "/b.lua", 'local bar = require("lib.bar")\n')
		local r = check.scan(tmp)
		T.eq(r.ok, false)
		T.eq(#r.phantoms, 2)
		-- Collect names for order-independent check
		local names = {}
		for _, p in ipairs(r.phantoms) do names[p.name] = true end
		T.ok(names["foo"], "foo phantom recorded")
		T.ok(names["bar"], "bar phantom recorded")
		rm_tmpdir(tmp)
	end)

	T.it("test files skipped: phantom in foo_test.lua not reported", function()
		local tmp = make_tmpdir()
		write_pkg(tmp, "mypkg", {})
		-- test file: should be skipped
		write_file(tmp .. "/mypkg_test.lua", 'local dev = require("lib.devonly")\n')
		-- source file: clean
		write_file(tmp .. "/init.lua", 'return {}\n')
		local r = check.scan(tmp)
		T.eq(r.ok, true)
		T.eq(#r.phantoms, 0)
		rm_tmpdir(tmp)
	end)

	T.it("line numbers correct: phantom recorded at the right line", function()
		local tmp = make_tmpdir()
		write_pkg(tmp, "mypkg", {})
		write_file(tmp .. "/init.lua", "-- line 1\n-- line 2\nlocal x = require(\"lib.ghost\")\n")
		local r = check.scan(tmp)
		T.eq(r.ok, false)
		T.eq(#r.phantoms, 1)
		T.eq(r.phantoms[1].line, 3)
		rm_tmpdir(tmp)
	end)

	T.it("require without parens: require \"lib.foo\" also detected", function()
		local tmp = make_tmpdir()
		write_pkg(tmp, "mypkg", {})
		write_file(tmp .. "/init.lua", "local x = require \"lib.noparen\"\nreturn {}\n")
		local r = check.scan(tmp)
		T.eq(r.ok, false)
		T.eq(#r.phantoms, 1)
		T.eq(r.phantoms[1].name, "noparen")
		T.eq(r.phantoms[1].require_path, "lib.noparen")
		rm_tmpdir(tmp)
	end)

	T.it("require with single quotes: require('lib.foo') also detected", function()
		local tmp = make_tmpdir()
		write_pkg(tmp, "mypkg", {})
		write_file(tmp .. "/init.lua", "local x = require('lib.singlequote')\nreturn {}\n")
		local r = check.scan(tmp)
		T.eq(r.ok, false)
		T.eq(#r.phantoms, 1)
		T.eq(r.phantoms[1].name, "singlequote")
		rm_tmpdir(tmp)
	end)

	T.it("full require path recorded: lib.foo.v2.util → name=foo", function()
		local tmp = make_tmpdir()
		write_pkg(tmp, "mypkg", {})
		write_file(tmp .. "/init.lua", 'local x = require("lib.foo.v2.util")\nreturn {}\n')
		local r = check.scan(tmp)
		T.eq(r.ok, false)
		T.eq(#r.phantoms, 1)
		T.eq(r.phantoms[1].name, "foo")
		T.eq(r.phantoms[1].require_path, "lib.foo.v2.util")
		rm_tmpdir(tmp)
	end)

	T.it("multiple requires on same line: all detected", function()
		local tmp = make_tmpdir()
		write_pkg(tmp, "mypkg", {})
		-- Two separate requires on the same line (unusual but valid Lua)
		write_file(tmp .. "/init.lua", 'local a, b = require("lib.aaa"), require("lib.bbb")\n')
		local r = check.scan(tmp)
		T.eq(r.ok, false)
		local names = {}
		for _, p in ipairs(r.phantoms) do names[p.name] = true end
		T.ok(names["aaa"], "aaa detected")
		T.ok(names["bbb"], "bbb detected")
		rm_tmpdir(tmp)
	end)

	T.it("commented-out require on its own line is not reported", function()
		local tmp = make_tmpdir()
		write_pkg(tmp, "mypkg", {})
		-- full-line comment: skipped by the line-comment heuristic
		write_file(tmp .. "/init.lua", '-- local x = require("lib.ghost")\nreturn {}\n')
		local r = check.scan(tmp)
		T.eq(r.ok, true)
		T.eq(#r.phantoms, 0)
		rm_tmpdir(tmp)
	end)

	T.it("non-lib require is ignored", function()
		local tmp = make_tmpdir()
		write_pkg(tmp, "mypkg", {})
		write_file(tmp .. "/init.lua", 'local ffi = require("ffi")\nlocal bit = require("bit")\nreturn {}\n')
		local r = check.scan(tmp)
		T.eq(r.ok, true)
		T.eq(#r.phantoms, 0)
		rm_tmpdir(tmp)
	end)

	T.it("same phantom from multiple lines reported once per occurrence", function()
		local tmp = make_tmpdir()
		write_pkg(tmp, "mypkg", {})
		-- require lib.ghost twice at different lines
		write_file(tmp .. "/init.lua",
			'local a = require("lib.ghost")\nlocal b = require("lib.ghost")\n')
		local r = check.scan(tmp)
		T.eq(r.ok, false)
		-- Both occurrences are reported (line numbers are distinct)
		T.eq(#r.phantoms, 2)
		T.eq(r.phantoms[1].line, 1)
		T.eq(r.phantoms[2].line, 2)
		rm_tmpdir(tmp)
	end)

	T.it("missing pkg.lua returns ok=false with a warning", function()
		local tmp = make_tmpdir()
		-- No pkg.lua written
		local r = check.scan(tmp)
		T.eq(r.ok, false)
		T.ok(#r.warnings > 0, "warning produced for missing pkg.lua")
		rm_tmpdir(tmp)
	end)

end)
