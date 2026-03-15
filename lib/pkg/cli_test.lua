if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local cli = require("lib.pkg.cli")

T.describe("cli.parse_args", function()
	T.it("bare command only", function()
		local r = cli.parse_args({ "install" })
		T.eq(r.command, "install")
		T.eq(#r.args, 0)
		T.eq(r.verbose, false)
		T.eq(r.frozen, false)
		T.eq(r.registry, "https://pkg.crescent.run")
		T.eq(r.jobs, 1)
	end)

	T.it("command with positional arg", function()
		local r = cli.parse_args({ "add", "sha1" })
		T.eq(r.command, "add")
		T.eq(r.args[1], "sha1")
	end)

	T.it("--verbose flag", function()
		local r = cli.parse_args({ "install", "--verbose" })
		T.eq(r.command, "install")
		T.eq(r.verbose, true)
	end)

	T.it("--frozen flag", function()
		local r = cli.parse_args({ "install", "--frozen" })
		T.eq(r.frozen, true)
	end)

	T.it("--registry=URL flag", function()
		local r = cli.parse_args({ "install", "--registry=https://example.com" })
		T.eq(r.registry, "https://example.com")
	end)

	T.it("--jobs=N flag", function()
		local r = cli.parse_args({ "install", "--jobs=4" })
		T.eq(r.jobs, 4)
	end)

	T.it("--jobs=N ignores non-integer", function()
		local r = cli.parse_args({ "install", "--jobs=abc" })
		T.eq(r.jobs, 1)  -- unchanged
	end)

	T.it("multiple flags before command args", function()
		local r = cli.parse_args({ "add", "--verbose", "--registry=https://r.io", "lunajson" })
		T.eq(r.command, "add")
		T.eq(r.verbose, true)
		T.eq(r.registry, "https://r.io")
		T.eq(r.args[1], "lunajson")
	end)

	T.it("unknown flag treated as positional after command", function()
		local r = cli.parse_args({ "install", "--unknown-flag" })
		T.eq(r.command, "install")
		T.eq(r.args[1], "--unknown-flag")
	end)

	T.it("no command → command is nil", function()
		local r = cli.parse_args({})
		T.eq(r.command, nil)
	end)

	T.it("flags only, no command → command is nil", function()
		local r = cli.parse_args({ "--verbose", "--frozen" })
		T.eq(r.command, nil)
		T.eq(r.verbose, true)
		T.eq(r.frozen, true)
	end)

	T.it("remove with name arg", function()
		local r = cli.parse_args({ "remove", "sha1" })
		T.eq(r.command, "remove")
		T.eq(r.args[1], "sha1")
	end)

	T.it("update with no name → args empty", function()
		local r = cli.parse_args({ "update" })
		T.eq(r.command, "update")
		T.eq(#r.args, 0)
	end)

	T.it("update with name", function()
		local r = cli.parse_args({ "update", "lunajson" })
		T.eq(r.command, "update")
		T.eq(r.args[1], "lunajson")
	end)

	T.it("info with name", function()
		local r = cli.parse_args({ "info", "sha1" })
		T.eq(r.command, "info")
		T.eq(r.args[1], "sha1")
	end)
end)

T.describe("cli.parse_pkg_spec", function()
	T.it("bare name → constraint *", function()
		local name, constraint = cli.parse_pkg_spec("sha1")
		T.eq(name, "sha1")
		T.eq(constraint, "*")
	end)

	T.it("name@version → pinned constraint", function()
		local name, constraint = cli.parse_pkg_spec("sha1@1.0.0")
		T.eq(name, "sha1")
		T.eq(constraint, "=1.0.0")
	end)

	T.it("name@semver range", function()
		local name, constraint = cli.parse_pkg_spec("lunajson@^1.3.0")
		T.eq(name, "lunajson")
		T.eq(constraint, "=^1.3.0")
	end)

	T.it("name with hyphens", function()
		local name, constraint = cli.parse_pkg_spec("my-lib@2.1.0")
		T.eq(name, "my-lib")
		T.eq(constraint, "=2.1.0")
	end)

	T.it("bare hyphenated name", function()
		local name, constraint = cli.parse_pkg_spec("my-lib")
		T.eq(name, "my-lib")
		T.eq(constraint, "*")
	end)
end)

T.describe("cli.main error paths", function()
	T.it("unknown command returns false", function()
		-- Capture stderr to avoid polluting test output; redirect via temporary approach.
		-- We override io.stderr temporarily.
		local old_stderr = io.stderr
		local captured = {}
		-- io.stderr is a file handle; we can't easily replace it in pure Lua without a temp file.
		-- Instead, just verify the return value is false.
		local result = cli.main({ "nonexistent-command-xyz" })
		T.eq(result, false)
	end)

	T.it("no command returns false", function()
		local result = cli.main({})
		T.eq(result, false)
	end)
end)
