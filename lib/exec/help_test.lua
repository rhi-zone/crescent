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
			local count = 0
			for _ in pairs(schema.subcommands) do count = count + 1 end
			T.eq(count, 3)
		end)

		T.it("subcommand names are correct", function()
			T.ok(schema.subcommands["grep"] ~= nil, "grep subcommand present")
			T.ok(schema.subcommands["view"] ~= nil, "view subcommand present")
			T.ok(schema.subcommands["edit"] ~= nil, "edit subcommand present")
		end)

		T.it("subcommand descriptions are non-empty", function()
			T.ok(schema.subcommands["grep"].description ~= "")
			T.ok(schema.subcommands["view"].description ~= "")
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
			T.eq(next(schema.subcommands), nil)
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
			T.eq(next(schema.subcommands), nil)
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
			T.eq(next(schema.subcommands), nil)
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

	-- Helper: find a subcommand by name (map lookup).
	local function find_sub(schema, name)
		return schema.subcommands[name]
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
				T.ok(next(schema.subcommands) ~= nil, "expected subcommands, got 0")
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
				T.ok(next(schema.subcommands) ~= nil, "expected nested subcommands")
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
				T.eq(next(schema.subcommands), nil)
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
				T.ok(next(schema.subcommands) ~= nil)
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

		-- curl: inline flags with no "Options:" header, 1-space indent.
		-- Parser detects flags in the else branch (no section required).
		T.describe("curl (inline flags, no Options header)", function()
			local schema = help.parse(read_fixture("curl.txt"))

			T.it("parses without error", function()
				T.ok(schema ~= nil)
			end)

			T.it("name is 'curl'", function()
				T.eq(schema.name, "curl")
			end)

			T.it("subcommands is empty (no Commands section)", function()
				T.eq(next(schema.subcommands), nil)
			end)

			T.it("finds flags (inline, no Options: header)", function()
				T.ok(#schema.flags > 0, "expected flags, got 0")
			end)

			T.it("has -v/--verbose flag", function()
				local f = find_flag(schema, "--verbose")
				T.ok(f ~= nil, "--verbose flag not found")
				T.eq(f.short, "-v")
			end)

			T.it("has -d/--data flag with arg", function()
				local f = find_flag(schema, "--data")
				T.ok(f ~= nil, "--data flag not found")
				T.eq(f.short, "-d")
				T.eq(f.arg, "data")
			end)
		end)

		-- git: lowercase group headers ("start a working area", etc.) with 3-space indent.
		-- Parser detects unlabeled command sections via lookahead heuristic.
		T.describe("git (lowercase unlabeled group headers)", function()
			local schema = help.parse(read_fixture("git.txt"))

			T.it("parses without error", function()
				T.ok(schema ~= nil)
			end)

			T.it("name is 'git'", function()
				T.eq(schema.name, "git")
			end)

			T.it("finds subcommands (unlabeled group headers parsed via heuristic)", function()
				T.ok(next(schema.subcommands) ~= nil, "expected subcommands, got 0")
			end)

			T.it("has 'clone' subcommand", function()
				T.ok(find_sub(schema, "clone") ~= nil, "'clone' not found")
			end)

			T.it("has 'commit' subcommand", function()
				T.ok(find_sub(schema, "commit") ~= nil, "'commit' not found")
			end)

			T.it("has 'push' subcommand", function()
				T.ok(find_sub(schema, "push") ~= nil, "'push' not found")
			end)

			T.it("flags empty (no 'Options:' section)", function()
				T.eq(#schema.flags, 0)
			end)
		end)

		-- git log --help: man page format — graceful degradation, no error, minimal schema.
		T.describe("git-log (man page format — graceful degradation)", function()
			local schema = help.parse(read_fixture("git-log.txt"))

			T.it("parses without error", function()
				T.ok(schema ~= nil)
			end)

			T.it("returns a valid schema table", function()
				T.ok(schema.subcommands ~= nil)
				T.ok(schema.flags ~= nil)
				T.ok(schema.positional ~= nil)
			end)

			T.it("no subcommands (man page has no Commands section)", function()
				T.eq(next(schema.subcommands), nil)
			end)
		end)

		-- luajit: lowercase "usage:", "Available options are:" and short-only flags.
		T.describe("luajit (lowercase usage, 'Available options are:', short-only flags)", function()
			local schema = help.parse(read_fixture("luajit.txt"))

			T.it("parses without error", function()
				T.ok(schema ~= nil)
			end)

			T.it("no subcommands", function()
				T.eq(next(schema.subcommands), nil)
			end)

			T.it("name extracted (case-insensitive 'usage:')", function()
				T.eq(schema.name, "luajit")
			end)

			T.it("finds flags from 'Available options are:' section", function()
				T.ok(#schema.flags > 0, "expected flags, got 0")
			end)

			T.it("has -e short-only flag with 'chunk' arg", function()
				local found
				for _, f in ipairs(schema.flags) do
					if f.short == "-e" then found = f; break end
				end
				T.ok(found ~= nil, "-e flag not found")
				T.eq(found.arg, "chunk")
				T.eq(found.long, nil)
			end)

			T.it("has -v short-only boolean flag", function()
				local found
				for _, f in ipairs(schema.flags) do
					if f.short == "-v" then found = f; break end
				end
				T.ok(found ~= nil, "-v flag not found")
			end)
		end)

		-- rg: ALLCAPS section headers ("USAGE:", "INPUT OPTIONS:", etc.) and nix noise prefix.
		T.describe("rg (ALLCAPS sections + nix noise stripped)", function()
			local schema = help.parse(read_fixture("rg.txt"))

			T.it("parses without error", function()
				T.ok(schema ~= nil)
			end)

			T.it("name is 'rg' (nix noise stripped, USAGE: parsed)", function()
				T.eq(schema.name, "rg")
			end)

			T.it("no subcommands (rg has no subcommands section)", function()
				T.eq(next(schema.subcommands), nil)
			end)

			T.it("finds flags from ALLCAPS section headers", function()
				T.ok(#schema.flags > 0, "expected flags, got 0")
			end)

			T.it("has -i/--ignore-case flag", function()
				local f = find_flag(schema, "--ignore-case")
				T.ok(f ~= nil, "--ignore-case not found")
				T.eq(f.short, "-i")
			end)
		end)

		-- jq: "Command options:" section header, 2-space indented flags.
		T.describe("jq ('Command options:' header, 2-space flags)", function()
			local schema = help.parse(read_fixture("jq.txt"))

			T.it("parses without error", function()
				T.ok(schema ~= nil)
			end)

			T.it("no subcommands", function()
				T.eq(next(schema.subcommands), nil)
			end)

			T.it("finds flags from 'Command options:' section", function()
				T.ok(#schema.flags > 0, "expected flags, got 0")
			end)

			T.it("has -n/--null-input flag", function()
				local f = find_flag(schema, "--null-input")
				T.ok(f ~= nil, "--null-input not found")
				T.eq(f.short, "-n")
			end)

			T.it("has -h/--help flag", function()
				local f = find_flag(schema, "--help")
				T.ok(f ~= nil, "--help not found")
				T.eq(f.short, "-h")
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

		T.it("recursively fetches subcommand help", function()
			-- Responses keyed by command string (space-joined args without --help).
			local responses = {
				["mytool"] = table.concat({
					"My Tool\n",
					"Usage: mytool [OPTIONS] [COMMAND]\n",
					"\nCommands:\n",
					"  sub1  First subcommand\n",
					"  sub2  Second subcommand\n",
					"\nOptions:\n",
					"  -h, --help  Print help\n",
				}),
				["mytool sub1"] = table.concat({
					"Sub1 help\n",
					"Usage: mytool sub1 [OPTIONS]\n",
					"\nOptions:\n",
					"  -x, --extra  Extra flag\n",
					"  -h, --help   Print help\n",
				}),
				["mytool sub2"] = table.concat({
					"Sub2 help\n",
					"Usage: mytool sub2 [OPTIONS] [COMMAND]\n",
					"\nCommands:\n",
					"  leaf  A leaf subcommand\n",
					"\nOptions:\n",
					"  -h, --help  Print help\n",
				}),
				["mytool sub2 leaf"] = table.concat({
					"Leaf help\n",
					"Usage: mytool sub2 leaf [OPTIONS]\n",
					"\nOptions:\n",
					"  -z, --zzz  Zzz flag\n",
					"  -h, --help  Print help\n",
				}),
			}

			local function fake_popen(cmd, _mode)
				-- cmd is shell-quoted: "'mytool' 'sub1' '--help' 2>&1; printf ..."
				-- Extract unquoted tokens up to (but not including) '--help'.
				local tokens = {}
				for tok in cmd:gmatch("'([^']*)'") do
					if tok == "--help" then break end
					tokens[#tokens + 1] = tok
				end
				local key = table.concat(tokens, " ")
				local body = responses[key] or ""
				return {
					read  = function(_, fmt)
						if fmt == "*a" then return body .. "\n__EXEC_EXIT__0\n" end
					end,
					close = function() end,
				}
			end

			local schema, err = help.fetch("mytool", { popen = fake_popen })
			T.eq(err, nil)
			T.ok(schema ~= nil)

			-- Top level has sub1 and sub2.
			T.ok(schema.subcommands["sub1"] ~= nil, "sub1 present")
			T.ok(schema.subcommands["sub2"] ~= nil, "sub2 present")

			-- sub1: leaf, has -x/--extra flag filled in by recursive fetch.
			local sub1 = schema.subcommands["sub1"]
			T.ok(sub1 ~= nil)
			T.eq(next(sub1.subcommands), nil)  -- no subcommands
			local extra_flag
			for _, f in ipairs(sub1.flags) do
				if f.long == "--extra" then extra_flag = f; break end
			end
			T.ok(extra_flag ~= nil, "--extra flag found on sub1")
			T.eq(extra_flag.short, "-x")

			-- sub2: has leaf subcommand.
			local sub2 = schema.subcommands["sub2"]
			T.ok(sub2 ~= nil)
			T.ok(sub2.subcommands["leaf"] ~= nil, "leaf subcommand present under sub2")

			-- sub2.leaf: has -z/--zzz flag.
			local leaf = sub2.subcommands["leaf"]
			T.ok(leaf ~= nil)
			local zzz_flag
			for _, f in ipairs(leaf.flags) do
				if f.long == "--zzz" then zzz_flag = f; break end
			end
			T.ok(zzz_flag ~= nil, "--zzz flag found on leaf")
		end)

		T.it("keeps stub when subcommand fetch fails", function()
			local call_count = 0
			local function fake_popen(cmd, _mode)
				call_count = call_count + 1
				local body
				if cmd:find("mysub") then
					-- Fail with exit code 1.
					body = "\n__EXEC_EXIT__1\n"
				else
					body = table.concat({
						"My Tool\n",
						"Usage: mytool [OPTIONS] [COMMAND]\n",
						"\nCommands:\n",
						"  mysub  A subcommand\n",
						"\nOptions:\n",
						"  -h, --help  Print help\n",
					}) .. "\n__EXEC_EXIT__0\n"
				end
				return {
					read  = function(_, fmt)
						if fmt == "*a" then return body end
					end,
					close = function() end,
				}
			end

			local schema, err = help.fetch("mytool", { popen = fake_popen })
			T.eq(err, nil)  -- top-level success
			T.ok(schema ~= nil)
			-- Stub preserved: name + description from parent, empty flags/positional/subcommands.
			local sub = schema.subcommands["mysub"]
			T.ok(sub ~= nil, "stub preserved after failed fetch")
			T.eq(sub.name, "mysub")
			T.eq(sub.description, "A subcommand")
			T.ok(call_count >= 2, "attempted recursive fetch")
		end)

		T.it("respects max_depth limit", function()
			-- All help output looks the same: one subcommand "child".
			-- Without max_depth this would loop forever.
			local call_count = 0
			local function fake_popen(_, _mode)
				call_count = call_count + 1
				local body = table.concat({
					"Tool\n",
					"Usage: tool [OPTIONS] [COMMAND]\n",
					"\nCommands:\n",
					"  child  Nested\n",
					"\nOptions:\n",
					"  -h, --help  Print help\n",
				}) .. "\n__EXEC_EXIT__0\n"
				return {
					read  = function(_, fmt)
						if fmt == "*a" then return body end
					end,
					close = function() end,
				}
			end

			local schema, err = help.fetch("tool", { popen = fake_popen, max_depth = 2 })
			T.eq(err, nil)
			T.ok(schema ~= nil)
			-- max_depth=2: depth 0 (top) → depth 1 (child) → depth 2 (child.child) → stop.
			-- That's 3 fetches total (0, 1, 2); depth 2 is fetched but its children are not.
			T.eq(call_count, 3)
		end)
	end)
end)
