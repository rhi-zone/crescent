if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T    = require("lib.test.assert")
local help = require("lib.exec.help")

-- Realistic help text modelled on clap/normalize output.
local NORMALIZE_HELP = [[
Fast code intelligence CLI

Usage: normalize [OPTIONS] [COMMAND]

Commands:
  grep    Search for text patterns across the codebase using ripgrep regex syntax.
  view    View a node in the codebase tree, or navigate symbol relationships
  edit    Structural editing of code symbols
  help    Print this message or the help of the given subcommand(s)

Options:
      --pretty              Human-friendly output with colors and formatting
      --compact             Compact output without colors (overrides TTY detection)
      --json                Output machine-readable JSON
      --jq <jq>             Filter output through jq expression
  -h, --help                Print help
  -V, --version             Print version
]]

local SUBCOMMAND_HELP = [[
View a node in the codebase tree, or navigate symbol relationships

Usage: normalize view [OPTIONS] [target]

Arguments:
  [target]  Target: path, path/Symbol, or SymbolName

Options:
  -r, --root <root>    Root directory (defaults to current directory)
  -d, --depth <depth>  Depth of expansion (0=names only, -1=all)
  -n, --line-numbers   Show line numbers
      --full            Show full source code
  -h, --help            Print help
]]

local NO_SUBCOMMANDS_HELP = [[
Search for text patterns across the codebase using ripgrep regex syntax.

Usage: normalize grep [OPTIONS] [pattern]

Arguments:
  [pattern]  Regex pattern to search for

Options:
      --pretty                Human-friendly output with colors and formatting
  -r, --root <root>           Root directory (defaults to current directory)
  -l, --limit <limit>         Maximum number of matches to return
  -i, --ignore-case           Case-insensitive search
  -h, --help                  Print help
]]

local LUAJIT_HELP = [[
usage: luajit [options]... [script [args]...].
Available options are:
  -e chunk  Execute string 'chunk'.
  -l name   Require library 'name'.
  -v        Show version information.
  --        Stop handling options.
]]

T.describe("help.parse", function()
	T.describe("top-level tool with subcommands", function()
		local schema = help.parse(NORMALIZE_HELP)

		T.it("extracts description", function()
			T.eq(schema.description, "Fast code intelligence CLI")
		end)

		T.it("extracts name from Usage", function()
			T.eq(schema.name, "normalize")
		end)

		T.it("extracts usage string", function()
			T.ok(schema.usage ~= nil)
			T.ok(schema.usage:find("normalize"), "usage contains name")
		end)

		T.it("extracts subcommands (excluding 'help')", function()
			T.eq(#schema.subcommands, 3)
		end)

		T.it("subcommand names are correct", function()
			T.eq(schema.subcommands[1].name, "grep")
			T.eq(schema.subcommands[2].name, "view")
			T.eq(schema.subcommands[3].name, "edit")
		end)

		T.it("subcommand descriptions are non-empty", function()
			T.ok(schema.subcommands[1].description ~= "")
			T.ok(schema.subcommands[2].description ~= "")
		end)

		T.it("extracts flags", function()
			T.ok(#schema.flags >= 4, "at least 4 flags")
		end)

		T.it("--pretty flag (long only)", function()
			local pretty
			for _, f in ipairs(schema.flags) do
				if f.long == "--pretty" then pretty = f break end
			end
			T.ok(pretty ~= nil, "--pretty flag found")
			T.eq(pretty.short, nil)
			T.eq(pretty.arg, nil)
			T.ok(pretty.description ~= "")
		end)

		T.it("--jq flag with arg", function()
			local jq
			for _, f in ipairs(schema.flags) do
				if f.long == "--jq" then jq = f break end
			end
			T.ok(jq ~= nil, "--jq flag found")
			T.eq(jq.arg, "jq")
		end)

		T.it("-h/--help short+long flag", function()
			local h
			for _, f in ipairs(schema.flags) do
				if f.long == "--help" then h = f break end
			end
			T.ok(h ~= nil, "--help flag found")
			T.eq(h.short, "-h")
		end)
	end)

	T.describe("subcommand with positional and flags", function()
		local schema = help.parse(SUBCOMMAND_HELP)

		T.it("extracts description", function()
			T.ok(schema.description ~= nil)
			T.ok(schema.description:find("View"), "description starts with View")
		end)

		T.it("extracts positional arguments", function()
			T.eq(#schema.positional, 1)
			T.eq(schema.positional[1].name, "target")
			T.eq(schema.positional[1].required, false)
		end)

		T.it("no subcommands", function()
			T.eq(#schema.subcommands, 0)
		end)

		T.it("extracts -r/--root flag with arg", function()
			local root
			for _, f in ipairs(schema.flags) do
				if f.long == "--root" then root = f break end
			end
			T.ok(root ~= nil, "--root flag found")
			T.eq(root.short, "-r")
			T.eq(root.arg, "root")
		end)

		T.it("extracts -n/--line-numbers boolean flag", function()
			local ln
			for _, f in ipairs(schema.flags) do
				if f.long == "--line-numbers" then ln = f break end
			end
			T.ok(ln ~= nil, "--line-numbers flag found")
			T.eq(ln.short, "-n")
			T.eq(ln.arg, nil)
		end)
	end)

	T.describe("tool with no subcommands section", function()
		local schema = help.parse(NO_SUBCOMMANDS_HELP)

		T.it("extracts description", function()
			T.ok(schema.description ~= nil)
		end)

		T.it("subcommands is empty", function()
			T.eq(#schema.subcommands, 0)
		end)

		T.it("extracts positional", function()
			T.eq(#schema.positional, 1)
			T.eq(schema.positional[1].name, "pattern")
		end)

		T.it("extracts -i/--ignore-case flag", function()
			local ic
			for _, f in ipairs(schema.flags) do
				if f.long == "--ignore-case" then ic = f break end
			end
			T.ok(ic ~= nil, "--ignore-case flag found")
			T.eq(ic.short, "-i")
			T.eq(ic.arg, nil)
		end)

		T.it("extracts -l/--limit flag with arg", function()
			local lim
			for _, f in ipairs(schema.flags) do
				if f.long == "--limit" then lim = f break end
			end
			T.ok(lim ~= nil, "--limit flag found")
			T.eq(lim.arg, "limit")
		end)
	end)

	T.describe("empty / minimal input", function()
		T.it("empty string returns empty schema", function()
			local schema = help.parse("")
			T.eq(#schema.subcommands, 0)
			T.eq(#schema.flags, 0)
			T.eq(#schema.positional, 0)
		end)

		T.it("no flags section returns empty flags", function()
			local schema = help.parse("My tool\n\nUsage: mytool [args]\n")
			T.eq(#schema.flags, 0)
			T.eq(schema.name, "mytool")
			T.eq(schema.description, "My tool")
		end)
	end)

	-- Helper: read a fixture file.
	local function read_fixture(name)
		local path = "lib/exec/testdata/help/" .. name
		local f = io.open(path, "r")
		if not f then error("fixture not found: " .. path) end
		local text = f:read("*a")
		f:close()
		return text
	end

	-- Helper: find a flag by long name in schema.flags.
	local function find_flag(schema, long)
		for _, f in ipairs(schema.flags) do
			if f.long == long then return f end
		end
	end

	-- Helper: find a subcommand by name.
	local function find_sub(schema, name)
		for _, s in ipairs(schema.subcommands) do
			if s.name == name then return s end
		end
	end

	T.describe("help.parse — real fixtures", function()
		-- normalize: standard clap output, subcommands + flags
		T.describe("normalize (top-level)", function()
			local schema = help.parse(read_fixture("normalize.txt"))

			T.it("name is 'normalize'", function()
				T.eq(schema.name, "normalize")
			end)

			T.it("description is non-empty", function()
				T.ok(schema.description ~= nil and schema.description ~= "")
			end)

			T.it("has subcommands", function()
				T.ok(#schema.subcommands > 0, "expected subcommands, got 0")
			end)

			T.it("has 'view' subcommand", function()
				T.ok(find_sub(schema, "view") ~= nil, "'view' subcommand not found")
			end)

			T.it("has 'grep' subcommand", function()
				T.ok(find_sub(schema, "grep") ~= nil, "'grep' subcommand not found")
			end)

			T.it("has 'edit' subcommand", function()
				T.ok(find_sub(schema, "edit") ~= nil, "'edit' subcommand not found")
			end)

			T.it("'help' subcommand is excluded", function()
				T.eq(find_sub(schema, "help"), nil)
			end)

			T.it("has flags", function()
				T.ok(#schema.flags > 0, "expected flags, got 0")
			end)

			T.it("has --help flag with -h short", function()
				local f = find_flag(schema, "--help")
				T.ok(f ~= nil, "--help flag not found")
				T.eq(f.short, "-h")
			end)

			T.it("has --jq flag with arg", function()
				local f = find_flag(schema, "--jq")
				T.ok(f ~= nil, "--jq flag not found")
				T.eq(f.arg, "jq")
			end)

			T.it("no positional arguments at top level", function()
				T.eq(#schema.positional, 0)
			end)
		end)

		-- normalize view: subcommands + arguments + flags
		T.describe("normalize view", function()
			local schema = help.parse(read_fixture("normalize-view.txt"))

			T.it("name is 'normalize'", function()
				T.eq(schema.name, "normalize")
			end)

			T.it("description is non-empty", function()
				T.ok(schema.description ~= nil and schema.description ~= "")
			end)

			T.it("has subcommands (nested view commands)", function()
				T.ok(#schema.subcommands > 0, "expected nested subcommands")
			end)

			T.it("has positional 'target' argument", function()
				T.eq(#schema.positional, 1)
				T.eq(schema.positional[1].name, "target")
				T.eq(schema.positional[1].required, false)
			end)

			T.it("has -r/--root flag with arg", function()
				local f = find_flag(schema, "--root")
				T.ok(f ~= nil, "--root flag not found")
				T.eq(f.short, "-r")
				T.eq(f.arg, "root")
			end)

			T.it("has -n/--line-numbers boolean flag", function()
				local f = find_flag(schema, "--line-numbers")
				T.ok(f ~= nil, "--line-numbers flag not found")
				T.eq(f.short, "-n")
				T.eq(f.arg, nil)
			end)

			T.it("has --full boolean flag", function()
				local f = find_flag(schema, "--full")
				T.ok(f ~= nil, "--full flag not found")
				T.eq(f.arg, nil)
			end)
		end)

		-- normalize grep: no subcommands, has arguments + flags + trailing prose
		T.describe("normalize grep", function()
			local schema = help.parse(read_fixture("normalize-grep.txt"))

			T.it("name is 'normalize'", function()
				T.eq(schema.name, "normalize")
			end)

			T.it("no subcommands", function()
				T.eq(#schema.subcommands, 0)
			end)

			T.it("positional 'pattern' argument (optional)", function()
				T.eq(#schema.positional, 1)
				T.eq(schema.positional[1].name, "pattern")
				T.eq(schema.positional[1].required, false)
			end)

			T.it("has flags", function()
				T.ok(#schema.flags > 0)
			end)

			T.it("has -i/--ignore-case flag", function()
				local f = find_flag(schema, "--ignore-case")
				T.ok(f ~= nil, "--ignore-case flag not found")
				T.eq(f.short, "-i")
				T.eq(f.arg, nil)
			end)

			T.it("has -l/--limit flag with arg", function()
				local f = find_flag(schema, "--limit")
				T.ok(f ~= nil, "--limit flag not found")
				T.eq(f.arg, "limit")
			end)

			T.it("has --jq flag with arg", function()
				local f = find_flag(schema, "--jq")
				T.ok(f ~= nil, "--jq flag not found")
				T.eq(f.arg, "jq")
			end)
		end)

		-- normalize edit: subcommands + flags, no positional
		T.describe("normalize edit", function()
			local schema = help.parse(read_fixture("normalize-edit.txt"))

			T.it("name is 'normalize'", function()
				T.eq(schema.name, "normalize")
			end)

			T.it("has subcommands", function()
				T.ok(#schema.subcommands > 0)
			end)

			T.it("has 'delete' subcommand", function()
				T.ok(find_sub(schema, "delete") ~= nil)
			end)

			T.it("has 'rename' subcommand", function()
				T.ok(find_sub(schema, "rename") ~= nil)
			end)

			T.it("has flags", function()
				T.ok(#schema.flags > 0)
			end)

			T.it("has --help/-h flag", function()
				local f = find_flag(schema, "--help")
				T.ok(f ~= nil)
				T.eq(f.short, "-h")
			end)
		end)

		-- curl: non-standard format — no "Options:" header, flags listed directly below Usage.
		-- Parser cannot extract flags without a section header, but it must not error.
		T.describe("curl (non-standard: no Options header)", function()
			local schema = help.parse(read_fixture("curl.txt"))

			T.it("parses without error", function()
				T.ok(schema ~= nil)
			end)

			T.it("subcommands is empty (no Commands section)", function()
				T.eq(#schema.subcommands, 0)
			end)

			-- curl's help lacks "Options:" header so flags list is empty — document limitation
			T.it("flags list is empty (parser requires 'Options:' section header)", function()
				T.eq(#schema.flags, 0)
			end)
		end)

		-- git: non-standard lowercase group headers and 3-space indent — parser cannot
		-- extract subcommands but must not error.
		T.describe("git (non-standard section headers)", function()
			local schema = help.parse(read_fixture("git.txt"))

			T.it("parses without error", function()
				T.ok(schema ~= nil)
			end)

			T.it("subcommands empty (non-standard format — no uppercase 'Commands:' header)", function()
				T.eq(#schema.subcommands, 0)
			end)

			T.it("flags empty (no 'Options:' section)", function()
				T.eq(#schema.flags, 0)
			end)
		end)

		-- git log --help: man-page troff format, no useful structure for the parser
		T.describe("git-log (man page format)", function()
			local schema = help.parse(read_fixture("git-log.txt"))

			T.it("parses without error", function()
				T.ok(schema ~= nil)
			end)

			T.it("no subcommands", function()
				T.eq(#schema.subcommands, 0)
			end)
		end)

		-- luajit: lowercase "usage:", "Available options are:" — parser won't match sections
		T.describe("luajit (non-standard: lowercase usage, custom options header)", function()
			local schema = help.parse(read_fixture("luajit.txt"))

			T.it("parses without error", function()
				T.ok(schema ~= nil)
			end)

			T.it("no subcommands", function()
				T.eq(#schema.subcommands, 0)
			end)

			-- luajit uses lowercase "usage:" so parser won't extract name
			T.it("name is nil (lowercase 'usage:' not matched)", function()
				T.eq(schema.name, nil)
			end)

			-- flags: luajit uses 2-space indent but non-standard format without '--long'
			-- -e chunk, -l name etc. — short-only flags with a space-separated metavar.
			-- parse_flag_line won't match these since they lack '--' prefix.
			T.it("flags is empty (non-standard format: no '--long' flags)", function()
				T.eq(#schema.flags, 0)
			end)
		end)

		-- rg: ALLCAPS section headers (USAGE:, OPTIONS:) — parser only matches Title-case.
		-- Also has nix download noise prepended. Must not error.
		T.describe("rg (ALLCAPS sections + nix noise prefix)", function()
			local schema = help.parse(read_fixture("rg.txt"))

			T.it("parses without error", function()
				T.ok(schema ~= nil)
			end)

			T.it("no subcommands (no matching section header)", function()
				T.eq(#schema.subcommands, 0)
			end)

			-- ALLCAPS sections don't match %u%a+ pattern (requires lowercase tail)
			T.it("flags is empty (ALLCAPS 'OPTIONS:' not matched by section detector)", function()
				T.eq(#schema.flags, 0)
			end)
		end)

		-- jq: "Command options:" header matches parser, but flags use single-tab indent
		-- which is 1 byte — parse_flag_line requires 2+ whitespace chars, so flags are empty.
		T.describe("jq (tab-indented flags)", function()
			local schema = help.parse(read_fixture("jq.txt"))

			T.it("parses without error", function()
				T.ok(schema ~= nil)
			end)

			T.it("no subcommands", function()
				T.eq(#schema.subcommands, 0)
			end)

			-- jq flags use single-tab indent (1 byte); parse_flag_line requires 2+ spaces
			T.it("flags is empty (single-tab indent not matched by flag parser)", function()
				T.eq(#schema.flags, 0)
			end)
		end)
	end)

	T.describe("help.fetch uses injected popen", function()
		T.it("calls popen with --help and returns schema", function()
			local called_cmd
			local function fake_popen(cmd, _mode)
				called_cmd = cmd
				-- Simulate output with sentinel appended by exec.run
				local body = "My Tool\n\nUsage: mytool [OPTIONS]\n\nOptions:\n  -h, --help  Print help\n"
				return {
					read  = function(_, fmt)
						if fmt == "*a" then
							return body .. "\n__EXEC_EXIT__0\n"
						end
					end,
					close = function() end,
				}
			end

			local schema, err = help.fetch("mytool", { popen = fake_popen })
			T.eq(err, nil)
			T.ok(schema ~= nil)
			T.eq(schema.name, "mytool")
			T.eq(schema.description, "My Tool")
			T.ok(called_cmd ~= nil)
			T.ok(called_cmd:find("mytool"), "popen called with mytool")
			T.ok(called_cmd:find("--help"), "popen called with --help")
		end)

		T.it("returns nil + errmsg when exec fails", function()
			local function fake_popen(_, _)
				return {
					read  = function(_, fmt)
						if fmt == "*a" then return "\n__EXEC_EXIT__1\n" end
					end,
					close = function() end,
				}
			end
			local schema, err = help.fetch("badcmd", { popen = fake_popen })
			T.eq(schema, nil)
			T.ok(err ~= nil)
		end)
	end)
end)
