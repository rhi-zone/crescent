if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local cli = require("lib.cli")

-- Helper: build a standard test app
local function test_app()
	return cli.app("myapp", "A test application")
		:version("1.0.0")
		:flag("verbose", { short = "v", desc = "Enable verbose output" })
		:option("output", { short = "o", desc = "Output file", default = "-" })
		:option("count", { short = "n", desc = "Repeat count", type = "number" })
		:positional("input", { desc = "Input file", required = true })
end

-- ── Flags ──────────────────────────────────────────────────────────────────

T.describe("flags", function()
	T.it("parses --verbose", function()
		local app = test_app()
		local args = app:parse({ "--verbose", "file.txt" })
		T.eq(args.verbose, 1)
	end)

	T.it("absent flag is nil", function()
		local app = test_app()
		local args = app:parse({ "file.txt" })
		T.eq(args.verbose, nil)
	end)

	T.it("parses short flag -v", function()
		local app = test_app()
		local args = app:parse({ "-v", "file.txt" })
		T.eq(args.verbose, 1)
	end)

	T.it("counts repeated -vvv", function()
		local app = test_app()
		local args = app:parse({ "-vvv", "file.txt" })
		T.eq(args.verbose, 3)
	end)

	T.it("counts repeated --verbose --verbose", function()
		local app = test_app()
		local args = app:parse({ "--verbose", "--verbose", "file.txt" })
		T.eq(args.verbose, 2)
	end)

	T.it("combined short flags -abc", function()
		local app = cli.app("test")
			:flag("alpha", { short = "a" })
			:flag("bravo", { short = "b" })
			:flag("charlie", { short = "c" })
		local args = app:parse({ "-abc" })
		T.eq(args.alpha, 1)
		T.eq(args.bravo, 1)
		T.eq(args.charlie, 1)
	end)
end)

-- ── Options ────────────────────────────────────────────────────────────────

T.describe("options", function()
	T.it("parses --output=foo", function()
		local app = test_app()
		local args = app:parse({ "--output=foo", "file.txt" })
		T.eq(args.output, "foo")
	end)

	T.it("parses --output foo", function()
		local app = test_app()
		local args = app:parse({ "--output", "foo", "file.txt" })
		T.eq(args.output, "foo")
	end)

	T.it("parses short -o foo", function()
		local app = test_app()
		local args = app:parse({ "-o", "foo", "file.txt" })
		T.eq(args.output, "foo")
	end)

	T.it("parses short -ofoo (attached value)", function()
		local app = test_app()
		local args = app:parse({ "-ofoo", "file.txt" })
		T.eq(args.output, "foo")
	end)

	T.it("applies default value", function()
		local app = test_app()
		local args = app:parse({ "file.txt" })
		T.eq(args.output, "-")
	end)

	T.it("coerces number type", function()
		local app = test_app()
		local args = app:parse({ "--count=3", "file.txt" })
		T.eq(args.count, 3)
	end)

	T.it("errors on bad number", function()
		local app = test_app()
		local args, err = app:parse({ "--count=abc", "file.txt" })
		T.eq(args, nil)
		T.ok(err:find("expected number"), "error should mention number coercion")
	end)

	T.it("errors when option missing value", function()
		local app = test_app()
		local args, err = app:parse({ "--output" })
		T.eq(args, nil)
		T.ok(err:find("requires a value"), "error should mention missing value")
	end)
end)

-- ── Array options ──────────────────────────────────────────────────────────

T.describe("array options", function()
	T.it("collects repeated options into array", function()
		local app = cli.app("test")
			:option("include", { short = "I", array = true })
		local args = app:parse({ "--include", "x", "--include", "y" })
		T.eq(#args.include, 2)
		T.eq(args.include[1], "x")
		T.eq(args.include[2], "y")
	end)

	T.it("defaults to empty array", function()
		local app = cli.app("test")
			:option("include", { array = true })
		local args = app:parse({})
		T.ok(type(args.include) == "table")
		T.eq(#args.include, 0)
	end)
end)

-- ── Positionals ────────────────────────────────────────────────────────────

T.describe("positionals", function()
	T.it("parses required positional", function()
		local app = test_app()
		local args = app:parse({ "file.txt" })
		T.eq(args.input, "file.txt")
	end)

	T.it("errors on missing required positional", function()
		local app = test_app()
		local args, err = app:parse({})
		T.eq(args, nil)
		T.ok(err:find("missing required argument"), "error should mention missing arg")
	end)

	T.it("optional positional absent is nil", function()
		local app = cli.app("test")
			:positional("file", { required = false })
		local args = app:parse({})
		T.eq(args.file, nil)
	end)
end)

-- ── Unknown flags ──────────────────────────────────────────────────────────

T.describe("unknown flags", function()
	T.it("errors on unknown long option", function()
		local app = test_app()
		local args, err = app:parse({ "--bogus", "file.txt" })
		T.eq(args, nil)
		T.ok(err:find("unknown option: --bogus", 1, true), "error should identify unknown flag")
	end)

	T.it("errors on unknown short option", function()
		local app = test_app()
		local args, err = app:parse({ "-z", "file.txt" })
		T.eq(args, nil)
		T.ok(err:find("unknown option: -z", 1, true), "error should identify unknown short flag")
	end)
end)

-- ── Double dash ────────────────────────────────────────────────────────────

T.describe("double dash", function()
	T.it("stops flag parsing after --", function()
		local app = test_app()
		local args = app:parse({ "--", "--verbose" })
		T.eq(args.input, "--verbose")
		T.eq(args.verbose, nil)
	end)
end)

-- ── Subcommands ────────────────────────────────────────────────────────────

T.describe("subcommands", function()
	T.it("parses parent flags and subcommand flags", function()
		local app = test_app()
		app:command("build", "Build the project")
			:flag("release", { desc = "Release mode" })
		local args = app:parse({ "-v", "build", "--release" })
		T.eq(args.verbose, 1)
		T.eq(args._command, "build")
		T.eq(args.release, 1)
	end)

	T.it("subcommand help", function()
		local app = cli.app("myapp", "desc")
		app:command("build", "Build the project")
			:flag("release", { desc = "Release mode" })
		local args, err = app:parse({ "build", "--help" })
		T.eq(args, nil)
		T.ok(err:find("build"), "help should mention subcommand name")
		T.ok(err:find("release"), "help should mention subcommand flags")
	end)
end)

-- ── Help ───────────────────────────────────────────────────────────────────

T.describe("help", function()
	T.it("--help returns nil + help text", function()
		local app = test_app()
		local args, help = app:parse({ "--help" })
		T.eq(args, nil)
		T.ok(help:find("myapp"), "help should contain app name")
		T.ok(help:find("Usage:"), "help should contain usage line")
		T.ok(help:find("Options:"), "help should contain options section")
		T.ok(help:find("%-v, %-%-verbose"), "help should list verbose flag")
	end)

	T.it("-h returns nil + help text", function()
		local app = test_app()
		local args, help = app:parse({ "-h" })
		T.eq(args, nil)
		T.ok(help:find("Usage:"), "help should contain usage line")
	end)
end)

-- ── Version ────────────────────────────────────────────────────────────────

T.describe("version", function()
	T.it("--version returns nil + version string", function()
		local app = test_app()
		local args, ver = app:parse({ "--version" })
		T.eq(args, nil)
		T.eq(ver, "1.0.0")
	end)
end)

-- ── Action / run ───────────────────────────────────────────────────────────

T.describe("run", function()
	T.it("invokes action callback", function()
		local captured
		local app = cli.app("test")
			:positional("file", {})
			:action(function(args) captured = args; return "ok" end)
		local result = app:run({ "hello.txt" })
		T.eq(result, "ok")
		T.eq(captured.file, "hello.txt")
	end)

	T.it("invokes subcommand action", function()
		local captured
		local app = cli.app("test")
		app:command("build", "Build")
			:flag("release", {})
			:action(function(args) captured = args; return "built" end)
		local result = app:run({ "build", "--release" })
		T.eq(result, "built")
		T.eq(captured._command, "build")
		T.eq(captured.release, 1)
	end)

	T.it("returns nil + error on parse failure", function()
		local app = cli.app("test")
			:positional("file", { required = true })
		local result, err = app:run({})
		T.eq(result, nil)
		T.ok(err:find("missing required"), "run should propagate parse errors")
	end)
end)

-- ── Shell completions ──────────────────────────────────────────────────────

T.describe("completions", function()
	T.it("bash completions are non-empty", function()
		local app = test_app()
		local comp = app:completions("bash")
		T.ok(type(comp) == "string" and #comp > 0, "bash completions should be non-empty")
		T.ok(comp:find("complete"), "bash completions should contain 'complete'")
	end)

	T.it("zsh completions are non-empty", function()
		local app = test_app()
		local comp = app:completions("zsh")
		T.ok(type(comp) == "string" and #comp > 0, "zsh completions should be non-empty")
		T.ok(comp:find("compdef"), "zsh completions should contain 'compdef'")
	end)

	T.it("fish completions are non-empty", function()
		local app = test_app()
		local comp = app:completions("fish")
		T.ok(type(comp) == "string" and #comp > 0, "fish completions should be non-empty")
		T.ok(comp:find("complete"), "fish completions should contain 'complete'")
	end)
end)

T.describe("edge cases", function()
	T.it("number coercion via short option", function()
		local app = test_app()
		local args, err = app:parse({ "-nabc", "file.txt" })
		T.eq(args, nil)
		T.ok(err:find("expected number"), "short option number coercion should error")
	end)

	T.it("mixed flags and positionals", function()
		local app = test_app()
		local args = app:parse({ "-v", "--output=out.txt", "--count=5", "in.txt" })
		T.eq(args.verbose, 1)
		T.eq(args.output, "out.txt")
		T.eq(args.count, 5)
		T.eq(args.input, "in.txt")
	end)
end)
