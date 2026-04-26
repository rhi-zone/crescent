if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T        = require("lib.test.assert")
local make_api = require("lib.exec.make_api")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Build a minimal HelpSchema with one leaf subcommand.
--: () -> HelpSchema
local function leaf_schema()
	return {
		name = "tool",
		description = "A tool",
		usage = "tool view <path>",
		flags = {},
		flag_idents = {},
		positional = {},
		subcommands = {
			view = {
				name = "view",
				description = "view a file",
				ident = "view",
				flags = {
					{ short = nil, long = "--json",   arg = nil,    description = "json output", ident = "json" },
					{ short = nil, long = "--format", arg = "fmt",  description = "format",       ident = "format" },
					{ short = nil, long = "--limit",  arg = "n",    description = "limit",        ident = "limit" },
					{ short = nil, long = "--verbose",arg = "boolean", description = "verbose",   ident = "verbose" },
				},
				flag_idents = { json = 1, format = 2, limit = 3, verbose = 4 },
				positional = {
					{ name = "path", required = true, ident = "path" },
				},
				subcommands = {},
				subcommand_idents = {},
			},
		},
		subcommand_idents = { view = "view" },
	}
end

-- Build a namespace-only schema (parent has no flags, only subcommands).
--: () -> HelpSchema
local function namespace_schema()
	return {
		name = "git",
		description = "git",
		usage = "git",
		flags = {},
		flag_idents = {},
		positional = {},
		subcommands = {
			remote = {
				name = "remote",
				description = "manage remotes",
				ident = "remote",
				flags = {},
				flag_idents = {},
				positional = {},
				subcommands = {
					add = {
						name = "add",
						description = "add remote",
						ident = "add",
						flags = {},
						flag_idents = {},
						positional = {
							{ name = "name", required = true,  ident = "name" },
							{ name = "url",  required = true,  ident = "url"  },
						},
						subcommands = {},
						subcommand_idents = {},
					},
				},
				subcommand_idents = { add = "add" },
			},
		},
		subcommand_idents = { remote = "remote" },
	}
end

-- Build a "both" schema: root has flags AND subcommands.
--: () -> HelpSchema
local function both_schema()
	return {
		name = "myprog",
		description = "my prog",
		usage = "myprog",
		flags = {
			{ short = nil, long = "--version", arg = nil, description = "show version", ident = "version" },
		},
		flag_idents = { version = 1 },
		positional = {},
		subcommands = {
			sub = {
				name = "sub",
				description = "a subcommand",
				ident = "sub",
				flags = {},
				flag_idents = {},
				positional = {},
				subcommands = {},
				subcommand_idents = {},
			},
		},
		subcommand_idents = { sub = "sub" },
	}
end

-- ---------------------------------------------------------------------------
-- Mock popen factory: captures the last command string.
-- ---------------------------------------------------------------------------
--: () -> { popen: function, last_cmd: string | nil }
local function make_mock_popen(stdout_result)
	local mock = { last_cmd = nil }
	mock.popen = function(cmdstr, _mode)
		mock.last_cmd = cmdstr
		local result = stdout_result or ""
		-- Return a fake file handle.
		local pos = 0
		local content = result .. "\n__EXEC_EXIT__0\n"
		return {
			read = function(self, fmt)
				if fmt == "*a" then
					return content
				end
				return nil
			end,
			close = function() end,
		}
	end
	return mock
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

T.describe("make_api.make", function()

	-- 1. Leaf node: schema with one subcommand (flags + positionals) → callable function.
	T.it("leaf node produces a callable function", function()
		local schema = leaf_schema()
		local mock = make_mock_popen("hello")
		local api, decls = make_api.make(schema, "tool", { popen = mock.popen })

		T.ok(type(api) == "table", "api is a table")
		T.ok(type(api.view) == "function", "api.view is a function")
		T.ok(type(decls) == "string", "decls is a string")
	end)

	-- 2. Namespace node: plain table, child callable, parent NOT callable.
	T.it("namespace node is a plain table (not callable)", function()
		local schema = namespace_schema()
		local mock = make_mock_popen("")
		local api, _ = make_api.make(schema, "git", { popen = mock.popen })

		T.ok(type(api) == "table", "api is a table")
		T.ok(getmetatable(api) == nil, "namespace has no metatable")
		T.ok(type(api.remote) == "table", "api.remote is a table")
		T.ok(type(api.remote.add) == "function", "api.remote.add is a function")
	end)

	-- 3. Both node: callable AND has subcommand keys.
	T.it("both node is callable and has subcommand keys", function()
		local schema = both_schema()
		local mock = make_mock_popen("")
		local api, _ = make_api.make(schema, "myprog", { popen = mock.popen })

		T.ok(type(api) == "table", "api is a table")
		T.ok(getmetatable(api) ~= nil, "both node has metatable")
		T.ok(type(getmetatable(api).__call) == "function", "__call is a function")
		T.ok(type(api.sub) == "function" or type(api.sub) == "table", "api.sub exists")
	end)

	-- 4a. Flag expansion: boolean true → "--flag".
	T.it("flag expansion: boolean true → --flag in args", function()
		local schema = leaf_schema()
		local mock = make_mock_popen("")
		local api, _ = make_api.make(schema, "tool", { popen = mock.popen })

		api.view("/some/path", { json = true })

		T.ok(mock.last_cmd ~= nil, "popen was called")
		T.ok(mock.last_cmd:find("--json", 1, true) ~= nil, "command contains --json")
	end)

	-- 4b. Flag expansion: boolean false with boolean-pair flag → --no-flag.
	T.it("flag expansion: boolean false on boolean-pair → --no-verbose", function()
		local schema = leaf_schema()
		local mock = make_mock_popen("")
		local api, _ = make_api.make(schema, "tool", { popen = mock.popen })

		api.view("/some/path", { verbose = false })

		T.ok(mock.last_cmd ~= nil, "popen was called")
		T.ok(mock.last_cmd:find("--no-verbose", 1, true) ~= nil, "command contains --no-verbose")
	end)

	-- 4c. Flag expansion: string value → "--flag" "value".
	T.it("flag expansion: string value → --format value in args", function()
		local schema = leaf_schema()
		local mock = make_mock_popen("")
		local api, _ = make_api.make(schema, "tool", { popen = mock.popen })

		api.view("/some/path", { format = "json" })

		T.ok(mock.last_cmd ~= nil, "popen was called")
		T.ok(mock.last_cmd:find("--format", 1, true) ~= nil, "command contains --format")
		T.ok(mock.last_cmd:find("json",     1, true) ~= nil, "command contains json value")
	end)

	-- 4d. Flag expansion: integer value → "--limit" "5".
	T.it("flag expansion: integer value → --limit 5 in args", function()
		local schema = leaf_schema()
		local mock = make_mock_popen("")
		local api, _ = make_api.make(schema, "tool", { popen = mock.popen })

		api.view("/some/path", { limit = 5 })

		T.ok(mock.last_cmd ~= nil, "popen was called")
		T.ok(mock.last_cmd:find("--limit", 1, true) ~= nil, "command contains --limit")
		T.ok(mock.last_cmd:find("'5'",     1, true) ~= nil, "command contains '5'")
	end)

	-- 4e. Flag expansion: nil value → omitted entirely.
	T.it("flag expansion: nil value omits flag", function()
		local schema = leaf_schema()
		local mock = make_mock_popen("")
		local api, _ = make_api.make(schema, "tool", { popen = mock.popen })

		api.view("/some/path", { json = nil })

		T.ok(mock.last_cmd ~= nil, "popen was called")
		T.ok(mock.last_cmd:find("--json", 1, true) == nil, "command does NOT contain --json")
	end)

	-- 5. Unknown flag key → nil, errmsg.
	T.it("unknown flag key returns nil, errmsg", function()
		local schema = leaf_schema()
		local mock = make_mock_popen("")
		local api, _ = make_api.make(schema, "tool", { popen = mock.popen })

		local out, err = api.view("/some/path", { nosuchflag = true })
		T.ok(out == nil, "result is nil on unknown flag")
		T.ok(type(err) == "string", "error message is a string")
		T.ok(err:find("nosuchflag", 1, true) ~= nil, "error mentions the bad key")
	end)

	-- 6. Correct CLI args constructed for a known schema.
	T.it("builds correct arg list for leaf call", function()
		local schema = leaf_schema()
		local mock = make_mock_popen("")
		local api, _ = make_api.make(schema, "tool", { popen = mock.popen })

		api.view("/my/path", { format = "plain" })

		-- Command must contain 'tool', 'view', '/my/path', '--format', 'plain'.
		local cmd = mock.last_cmd
		T.ok(cmd:find("'tool'",     1, true) ~= nil, "cmd contains tool")
		T.ok(cmd:find("'view'",     1, true) ~= nil, "cmd contains view")
		T.ok(cmd:find("'/my/path'", 1, true) ~= nil, "cmd contains /my/path")
		T.ok(cmd:find("'--format'", 1, true) ~= nil, "cmd contains --format")
		T.ok(cmd:find("'plain'",    1, true) ~= nil, "cmd contains plain")
	end)

	-- 6b. Namespace leaf: subcommand path is correctly assembled.
	T.it("namespace leaf builds correct path for nested subcommand", function()
		local schema = namespace_schema()
		local mock = make_mock_popen("")
		local api, _ = make_api.make(schema, "git", { popen = mock.popen })

		api.remote.add("origin", "https://example.com")

		local cmd = mock.last_cmd
		T.ok(cmd:find("'git'",                 1, true) ~= nil, "cmd contains git")
		T.ok(cmd:find("'remote'",              1, true) ~= nil, "cmd contains remote")
		T.ok(cmd:find("'add'",                 1, true) ~= nil, "cmd contains add")
		T.ok(cmd:find("'origin'",              1, true) ~= nil, "cmd contains origin")
		T.ok(cmd:find("'https://example.com'", 1, true) ~= nil, "cmd contains url")
	end)

	-- 7. decls_string is non-empty and contains valid --:: lines.
	T.it("decls_string is non-empty and has --:: lines", function()
		local schema = leaf_schema()
		local mock = make_mock_popen("")
		local _, decls = make_api.make(schema, "tool", { popen = mock.popen })

		T.ok(type(decls) == "string", "decls is string")
		T.ok(#decls > 0, "decls is non-empty")
		T.ok(decls:find("^%-%-::", 1) ~= nil or decls:find("\n%-%-::", 1) ~= nil,
			"decls contains --:: lines")
		-- Should mention flag names.
		T.ok(decls:find("json",   1, true) ~= nil, "decls mentions json flag")
		T.ok(decls:find("format", 1, true) ~= nil, "decls mentions format flag")
	end)

	-- 7b. Parity: two calls with identical inputs produce identical arg lists.
	T.it("parity: two identical calls produce identical arg lists", function()
		local schema = leaf_schema()
		local mock1 = make_mock_popen("")
		local mock2 = make_mock_popen("")
		local api1, _ = make_api.make(schema, "tool", { popen = mock1.popen })
		local api2, _ = make_api.make(schema, "tool", { popen = mock2.popen })

		api1.view("/p", { json = true, format = "text" })
		api2.view("/p", { json = true, format = "text" })

		-- Both commands should be identical strings.
		T.eq(mock1.last_cmd, mock2.last_cmd)
	end)

	-- 8. both node: __call dispatches correctly.
	T.it("both node: __call invokes the binary directly", function()
		local schema = both_schema()
		local mock = make_mock_popen("")
		local api, _ = make_api.make(schema, "myprog", { popen = mock.popen })

		api({ version = true })

		T.ok(mock.last_cmd ~= nil, "popen was called via __call")
		T.ok(mock.last_cmd:find("'myprog'",   1, true) ~= nil, "cmd contains myprog")
		T.ok(mock.last_cmd:find("--version",  1, true) ~= nil, "cmd contains --version")
	end)

end)
