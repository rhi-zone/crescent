-- lib/cr/cr_test.lua — tests for lib/cr/init.lua pure logic

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local cr = require("lib.cr")

-- ── global flag parsing ───────────────────────────────────────────────────────

T.describe("parse_global_flags", function()
	T.it("strips --verbose", function()
		local opts, rest = cr.parse_global_flags({ "--verbose", "test" })
		T.eq(opts.verbose, true)
		T.eq(#rest, 1)
		T.eq(rest[1], "test")
	end)

	T.it("strips -v shorthand", function()
		local opts, rest = cr.parse_global_flags({ "-v", "check" })
		T.eq(opts.verbose, true)
		T.eq(#rest, 1)
		T.eq(rest[1], "check")
	end)

	T.it("strips --no-color", function()
		local opts, rest = cr.parse_global_flags({ "--no-color", "test" })
		T.eq(opts.no_color, true)
		T.eq(#rest, 1)
		T.eq(rest[1], "test")
	end)

	T.it("parses --jobs=4", function()
		local opts, rest = cr.parse_global_flags({ "--jobs=4", "test" })
		T.eq(opts.jobs, 4)
		T.eq(#rest, 1)
		T.eq(rest[1], "test")
	end)

	T.it("parses --registry=URL", function()
		local url = "https://my.registry.example"
		local opts, rest = cr.parse_global_flags({ "--registry=" .. url, "install" })
		T.eq(opts.registry, url)
		T.eq(#rest, 1)
		T.eq(rest[1], "install")
	end)

	T.it("defaults: verbose=false, no_color=false, jobs=nil, registry=nil", function()
		local opts, rest = cr.parse_global_flags({ "test" })
		T.eq(opts.verbose,  false)
		T.eq(opts.no_color, false)
		T.eq(opts.jobs,     nil)
		T.eq(opts.registry, nil)
		T.eq(#rest, 1)
		T.eq(rest[1], "test")
	end)

	T.it("strips multiple global flags, preserves sub-args", function()
		local opts, rest = cr.parse_global_flags({
			"--verbose", "--jobs=2", "--no-color", "test", "--coverage",
		})
		T.eq(opts.verbose,  true)
		T.eq(opts.jobs,     2)
		T.eq(opts.no_color, true)
		T.eq(#rest, 2)
		T.eq(rest[1], "test")
		T.eq(rest[2], "--coverage")
	end)

	T.it("passes unknown flags through as positional", function()
		local _, rest = cr.parse_global_flags({ "check", "--format", "plain" })
		T.eq(#rest, 3)
		T.eq(rest[1], "check")
		T.eq(rest[2], "--format")
		T.eq(rest[3], "plain")
	end)

	T.it("ignores --jobs with non-integer value", function()
		local opts, _ = cr.parse_global_flags({ "--jobs=abc", "test" })
		T.eq(opts.jobs, nil)
	end)

	T.it("ignores --jobs=0 (must be >= 1)", function()
		local opts, _ = cr.parse_global_flags({ "--jobs=0", "test" })
		T.eq(opts.jobs, nil)
	end)
end)

-- ── file dispatch detection ───────────────────────────────────────────────────

T.describe("file dispatch detection", function()
	T.it("cmd ending in .lua is identified as file target", function()
		local _, rest = cr.parse_global_flags({ "myscript.lua" })
		T.eq(rest[1], "myscript.lua")
		T.ok(rest[1]:match("%.lua$") ~= nil)
	end)

	T.it("bare command name is not identified as lua file", function()
		local _, rest = cr.parse_global_flags({ "test" })
		T.eq(rest[1]:match("%.lua$"), nil)
	end)
end)

-- ── command routing ───────────────────────────────────────────────────────────

T.describe("command routing", function()
	-- Verify that known command names pass through parse_global_flags unmodified.
	local known = { "install", "add", "remove", "update", "info", "publish",
	                "test", "check", "run" }

	for _, name in ipairs(known) do
		T.it("known command passes through rest[1]=" .. name, function()
			local _, rest = cr.parse_global_flags({ name })
			T.eq(rest[1], name)
		end)
	end
end)

-- ── run: script_dir extraction ───────────────────────────────────────────────

T.describe("run: script_dir", function()
	-- Mirror the logic in lib/cr/run.lua script_dir().
	local function script_dir(path)
		return path:match("^(.*[/\\])") or "."
	end

	T.it("extracts dir from absolute path", function()
		T.eq(script_dir("/home/user/project/foo.lua"), "/home/user/project/")
	end)

	T.it("extracts dir from relative path with directory", function()
		T.eq(script_dir("scripts/run.lua"), "scripts/")
	end)

	T.it("returns '.' for bare filename", function()
		T.eq(script_dir("foo.lua"), ".")
	end)

	T.it("handles nested path", function()
		T.eq(script_dir("a/b/c/d.lua"), "a/b/c/")
	end)

	T.it("handles Windows-style backslash separator", function()
		T.eq(script_dir("a\\b\\c.lua"), "a\\b\\")
	end)
end)

-- ── run: arg-building logic ───────────────────────────────────────────────────

T.describe("run: arg building", function()
	-- Mirror the arg-building in M.main: argv[1]=file, argv[2..n]=script args.
	local function build_arg(argv)
		local a = { [0] = argv[1] }
		for i = 2, #argv do
			a[i - 1] = argv[i]
		end
		return a
	end

	T.it("arg[0] is the script path", function()
		local a = build_arg({ "foo.lua" })
		T.eq(a[0], "foo.lua")
	end)

	T.it("no extra args → arg length is 0", function()
		local a = build_arg({ "foo.lua" })
		T.eq(#a, 0)
	end)

	T.it("extra args land at arg[1], arg[2], ...", function()
		local a = build_arg({ "foo.lua", "hello", "world" })
		T.eq(a[0], "foo.lua")
		T.eq(a[1], "hello")
		T.eq(a[2], "world")
		T.eq(#a, 2)
	end)
end)

-- ── scripts lookup (mock) ─────────────────────────────────────────────────────

T.describe("scripts lookup logic", function()
	-- The scripts dispatch in M.main calls load_pkg_lua() which reads from disk.
	-- We test the pure table-lookup logic directly here without filesystem.

	local function scripts_has(scripts, cmd)
		return scripts ~= nil and scripts[cmd] ~= nil
	end

	T.it("finds a script that exists", function()
		local scripts = { build = "luajit build.lua", serve = "luajit server.lua" }
		T.ok(scripts_has(scripts, "build"))
		T.ok(scripts_has(scripts, "serve"))
	end)

	T.it("returns falsy for unknown script", function()
		local scripts = { build = "luajit build.lua" }
		T.ok(not scripts_has(scripts, "deploy"))
	end)

	T.it("handles nil scripts table gracefully", function()
		T.ok(not scripts_has(nil, "build"))
	end)

	T.it("handles empty scripts table", function()
		T.ok(not scripts_has({}, "build"))
	end)
end)
