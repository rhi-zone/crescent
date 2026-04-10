if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local cli = require("lib.cli")

-- Standard test spec reused across tests.
local function test_spec()
	return {
		name = "myapp", desc = "A test application", version = "1.0.0",
		flags   = { verbose = { short = "v", desc = "Enable verbose output" } },
		options = {
			output = { short = "o", desc = "Output file", default = "-" },
			count  = { short = "n", desc = "Repeat count", type = "number" },
		},
		positionals = {
			{ name = "input", desc = "Input file", required = true },
		},
	}
end

-- ── Flags ─────────────────────────────────────────────────────────────────

T.describe("flags", function()
	T.it("parses --verbose", function()
		local args = cli.parse({ "--verbose", "file.txt" }, test_spec())
		T.eq(args.verbose, 1)
	end)

	T.it("absent flag is nil", function()
		local args = cli.parse({ "file.txt" }, test_spec())
		T.eq(args.verbose, nil)
	end)

	T.it("parses short flag -v", function()
		local args = cli.parse({ "-v", "file.txt" }, test_spec())
		T.eq(args.verbose, 1)
	end)

	T.it("counts repeated -vvv", function()
		local args = cli.parse({ "-vvv", "file.txt" }, test_spec())
		T.eq(args.verbose, 3)
	end)

	T.it("counts repeated --verbose --verbose", function()
		local args = cli.parse({ "--verbose", "--verbose", "file.txt" }, test_spec())
		T.eq(args.verbose, 2)
	end)

	T.it("combined short flags -abc", function()
		local args = cli.parse({ "-abc" }, {
			name = "test",
			flags = { alpha = { short = "a" }, bravo = { short = "b" }, charlie = { short = "c" } },
		})
		T.eq(args.alpha, 1)
		T.eq(args.bravo, 1)
		T.eq(args.charlie, 1)
	end)
end)

-- ── Options ───────────────────────────────────────────────────────────────

T.describe("options", function()
	T.it("parses --output=foo", function()
		local args = cli.parse({ "--output=foo", "file.txt" }, test_spec())
		T.eq(args.output, "foo")
	end)

	T.it("parses --output foo", function()
		local args = cli.parse({ "--output", "foo", "file.txt" }, test_spec())
		T.eq(args.output, "foo")
	end)

	T.it("parses short -o foo", function()
		local args = cli.parse({ "-o", "foo", "file.txt" }, test_spec())
		T.eq(args.output, "foo")
	end)

	T.it("parses short -ofoo (attached value)", function()
		local args = cli.parse({ "-ofoo", "file.txt" }, test_spec())
		T.eq(args.output, "foo")
	end)

	T.it("applies default value", function()
		local args = cli.parse({ "file.txt" }, test_spec())
		T.eq(args.output, "-")
	end)

	T.it("coerces number type", function()
		local args = cli.parse({ "--count=3", "file.txt" }, test_spec())
		T.eq(args.count, 3)
	end)

	T.it("errors on bad number", function()
		local args, err = cli.parse({ "--count=abc", "file.txt" }, test_spec())
		T.eq(args, nil)
		T.ok(err:find("expected number"), "error should mention number coercion")
	end)

	T.it("errors when option missing value", function()
		local args, err = cli.parse({ "--output" }, test_spec())
		T.eq(args, nil)
		T.ok(err:find("requires a value"), "error should mention missing value")
	end)
end)

-- ── Array options ─────────────────────────────────────────────────────────

T.describe("array options", function()
	T.it("collects repeated options into array", function()
		local args = cli.parse({ "--include", "x", "--include", "y" }, {
			name = "test",
			options = { include = { short = "I", array = true } },
		})
		T.eq(#args.include, 2)
		T.eq(args.include[1], "x")
		T.eq(args.include[2], "y")
	end)

	T.it("defaults to empty array", function()
		local args = cli.parse({}, {
			name = "test",
			options = { include = { array = true } },
		})
		T.ok(type(args.include) == "table")
		T.eq(#args.include, 0)
	end)
end)

-- ── Positionals ───────────────────────────────────────────────────────────

T.describe("positionals", function()
	T.it("parses required positional", function()
		local args = cli.parse({ "file.txt" }, test_spec())
		T.eq(args.input, "file.txt")
	end)

	T.it("errors on missing required positional", function()
		local args, err = cli.parse({}, test_spec())
		T.eq(args, nil)
		T.ok(err:find("missing required argument"), "error should mention missing arg")
	end)

	T.it("optional positional absent is nil", function()
		local args = cli.parse({}, {
			name = "test",
			positionals = { { name = "file", required = false } },
		})
		T.eq(args.file, nil)
	end)
end)

-- ── Unknown flags ─────────────────────────────────────────────────────────

T.describe("unknown flags", function()
	T.it("errors on unknown long option", function()
		local args, err = cli.parse({ "--bogus", "file.txt" }, test_spec())
		T.eq(args, nil)
		T.ok(err:find("unknown option: --bogus", 1, true))
	end)

	T.it("errors on unknown short option", function()
		local args, err = cli.parse({ "-z", "file.txt" }, test_spec())
		T.eq(args, nil)
		T.ok(err:find("unknown option: -z", 1, true))
	end)
end)

-- ── Double dash ───────────────────────────────────────────────────────────

T.describe("double dash", function()
	T.it("stops flag parsing after --", function()
		local args = cli.parse({ "--", "--verbose" }, test_spec())
		T.eq(args.input, "--verbose")
		T.eq(args.verbose, nil)
	end)
end)

-- ── Subcommands ───────────────────────────────────────────────────────────

T.describe("subcommands", function()
	T.it("parses parent flags and subcommand flags", function()
		local spec = test_spec()
		spec.commands = {
			build = { desc = "Build the project", flags = { release = { desc = "Release mode" } } },
		}
		local args = cli.parse({ "-v", "build", "--release" }, spec)
		T.eq(args.verbose, 1)
		T.eq(args._command, "build")
		T.eq(args.release, 1)
	end)

	T.it("subcommand help", function()
		local spec = {
			name = "myapp", desc = "desc",
			commands = {
				build = { desc = "Build the project", flags = { release = { desc = "Release mode" } } },
			},
		}
		local args, err = cli.parse({ "build", "--help" }, spec)
		T.eq(args, nil)
		T.ok(err:find("build"), "help should mention subcommand name")
		T.ok(err:find("release"), "help should mention subcommand flags")
	end)
end)

-- ── Help ──────────────────────────────────────────────────────────────────

T.describe("help", function()
	T.it("--help returns nil + help text", function()
		local args, help = cli.parse({ "--help" }, test_spec())
		T.eq(args, nil)
		T.ok(help:find("myapp"), "help should contain app name")
		T.ok(help:find("Usage:"), "help should contain usage line")
		T.ok(help:find("Options:"), "help should contain options section")
		T.ok(help:find("%-v, %-%-verbose"), "help should list verbose flag")
	end)

	T.it("-h returns nil + help text", function()
		local args, help = cli.parse({ "-h" }, test_spec())
		T.eq(args, nil)
		T.ok(help:find("Usage:"), "help should contain usage line")
	end)

	T.it("cli.help() returns help text directly", function()
		local help = cli.help(test_spec())
		T.ok(help:find("myapp"), "help should contain app name")
		T.ok(help:find("Usage:"), "help should contain usage line")
	end)
end)

-- ── Version ───────────────────────────────────────────────────────────────

T.describe("version", function()
	T.it("--version returns nil + version string", function()
		local args, ver = cli.parse({ "--version" }, test_spec())
		T.eq(args, nil)
		T.eq(ver, "1.0.0")
	end)
end)

-- ── Action / run ──────────────────────────────────────────────────────────

T.describe("run", function()
	T.it("invokes action callback", function()
		local captured
		local result = cli.run({ "hello.txt" }, {
			name = "test",
			positionals = { { name = "file" } },
			action = function(args) captured = args; return "ok" end,
		})
		T.eq(result, "ok")
		T.eq(captured.file, "hello.txt")
	end)

	T.it("invokes subcommand action", function()
		local captured
		local result = cli.run({ "build", "--release" }, {
			name = "test",
			commands = {
				build = {
					desc = "Build",
					flags = { release = {} },
					action = function(args) captured = args; return "built" end,
				},
			},
		})
		T.eq(result, "built")
		T.eq(captured._command, "build")
		T.eq(captured.release, 1)
	end)

	T.it("returns nil + error on parse failure", function()
		local result, err = cli.run({}, {
			name = "test",
			positionals = { { name = "file", required = true } },
		})
		T.eq(result, nil)
		T.ok(err:find("missing required"), "run should propagate parse errors")
	end)
end)

-- ── Shell completions ─────────────────────────────────────────────────────

T.describe("completions", function()
	T.it("bash completions are non-empty", function()
		local comp = cli.completions(test_spec(), "bash")
		T.ok(type(comp) == "string" and #comp > 0)
		T.ok(comp:find("complete"))
	end)

	T.it("zsh completions are non-empty", function()
		local comp = cli.completions(test_spec(), "zsh")
		T.ok(type(comp) == "string" and #comp > 0)
		T.ok(comp:find("compdef"))
	end)

	T.it("fish completions are non-empty", function()
		local comp = cli.completions(test_spec(), "fish")
		T.ok(type(comp) == "string" and #comp > 0)
		T.ok(comp:find("complete"))
	end)
end)

-- ── Edge cases ────────────────────────────────────────────────────────────

T.describe("edge cases", function()
	T.it("number coercion via short option", function()
		local args, err = cli.parse({ "-nabc", "file.txt" }, test_spec())
		T.eq(args, nil)
		T.ok(err:find("expected number"), "short option number coercion should error")
	end)

	T.it("mixed flags and positionals", function()
		local args = cli.parse({ "-v", "--output=out.txt", "--count=5", "in.txt" }, test_spec())
		T.eq(args.verbose, 1)
		T.eq(args.output, "out.txt")
		T.eq(args.count, 5)
		T.eq(args.input, "in.txt")
	end)
end)
