-- lib/cr/init.lua
-- Unified crescent CLI dispatcher.
--
-- Dispatch order for `cr <cmd>`:
--   1. <cmd>.lua exists as a file → run it via dofile
--   2. <cmd> matches a key in pkg.lua scripts table → os.execute the script
--   3. <cmd> is a built-in command → lazy-load and dispatch

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- ── built-in command registry (lazy loaders) ──────────────────────────────────

local COMMANDS = {
	-- pkg
	install = function() return require("lib.pkg.cli") end,
	add     = function() return require("lib.pkg.cli") end,
	remove  = function() return require("lib.pkg.cli") end,
	update  = function() return require("lib.pkg.cli") end,
	info    = function() return require("lib.pkg.cli") end,
	publish = function() return require("lib.pkg.cli") end,
	-- tooling
	test    = function() return require("lib.test.cli") end,
	check   = function() return require("lib.type.static.cli") end,
	run     = function() return require("lib.cr.run") end,
}

-- ── global flags ──────────────────────────────────────────────────────────────

-- Global flags recognised at the top level; stripped before subcommand dispatch.
local GLOBAL_FLAGS = {
	verbose  = false,
	jobs     = nil,     -- nil = subcommand default
	registry = nil,     -- nil = subcommand default
	no_color = false,
}

--- Parse global flags out of argv.
-- Returns opts table and remaining args (command + subcommand args).
function M.parse_global_flags(argv)
	local opts = {
		verbose  = false,
		jobs     = nil,
		registry = nil,
		no_color = false,
	}
	local rest = {}

	for i = 1, #argv do
		local v = argv[i]
		if v == "--verbose" or v == "-v" then
			opts.verbose = true
		elseif v == "--no-color" then
			opts.no_color = true
		elseif v:match("^%-%-jobs=(%d+)$") then
			local n = tonumber(v:match("^%-%-jobs=(%d+)$"))
			if n and n >= 1 then opts.jobs = math.floor(n) end
		elseif v:match("^%-%-registry=(.+)$") then
			opts.registry = v:match("^%-%-registry=(.+)$")
		else
			rest[#rest + 1] = v
		end
	end

	return opts, rest
end

-- ── helpers ───────────────────────────────────────────────────────────────────

-- Check whether a path exists and is a readable file.
local function file_exists(path)
	local f = io.open(path, "r")
	if f then f:close(); return true end
	return false
end

-- Load pkg.lua from cwd and return the table, or nil.
local function load_pkg_lua()
	local ok, result = pcall(loadfile, "pkg.lua")
	if not ok or not result then return nil end
	local ok2, t = pcall(result)
	if not ok2 or type(t) ~= "table" then return nil end
	return t
end

-- Inject global opts back into an args list for subcommands that understand them.
-- Prepends --verbose, --jobs=N, --registry=URL, --no-color as appropriate.
local function inject_global_opts(opts, args)
	local injected = {}
	if opts.verbose  then injected[#injected + 1] = "--verbose" end
	if opts.no_color then injected[#injected + 1] = "--no-color" end
	if opts.jobs     then injected[#injected + 1] = "--jobs=" .. opts.jobs end
	if opts.registry then injected[#injected + 1] = "--registry=" .. opts.registry end
	for _, v in ipairs(args) do
		injected[#injected + 1] = v
	end
	return injected
end

-- ── usage ─────────────────────────────────────────────────────────────────────

local USAGE = [[
usage: cr [global-flags] <command> [args...]

commands:
  install [--frozen]        install all deps from pkg.lua / lockfile
  add <name[@version]>      add dep to pkg.lua, install, update lockfile
  remove <name>             remove dep, delete dep/<name>/, update lockfile
  update [name]             re-resolve to latest matching version(s)
  info <name>               show package info from registry
  publish                   publish to registry
  test [files...]           run test suite
  check [files...]          typecheck files
  run <file>                run a Lua file with lib/ on package.path

  <file>.lua                run a Lua file directly
  <script>                  run a script defined in pkg.lua scripts table

global flags:
  --verbose / -v            verbose output
  --jobs=N                  parallelism (test runner + package fetch)
  --registry=URL            prepend a registry for this invocation
  --no-color                disable ANSI output
]]

-- ── main ──────────────────────────────────────────────────────────────────────

--- Main entry point. argv is a 1-indexed list of arguments (e.g. the global arg).
function M.main(argv)
	local opts, rest = M.parse_global_flags(argv)
	local cmd = rest[1]

	if not cmd then
		io.stderr:write(USAGE)
		os.exit(1)
	end

	-- Remaining args after the command name.
	local sub_args = {}
	for i = 2, #rest do
		sub_args[#sub_args + 1] = rest[i]
	end

	-- ── dispatch order 1: file dispatch ───────────────────────────────────────

	-- If cmd looks like a .lua file or a bare name that maps to an existing file.
	local file_target
	if cmd:match("%.lua$") then
		file_target = cmd
	else
		-- Also try cmd .. ".lua" for convenience (bun-style).
		-- Only do this if no built-in matches, so check later. Skip here.
	end

	if file_target and file_exists(file_target) then
		-- Ensure cwd is on path so the script can require lib/ packages.
		if not package.path:find("./?.lua", 1, true) then
			package.path = "./?.lua;" .. package.path
		end
		if not package.path:find("./?/init.lua", 1, true) then
			package.path = "./?/init.lua;" .. package.path
		end
		dofile(file_target)
		return true
	end

	-- ── dispatch order 2: pkg.lua scripts ────────────────────────────────────

	-- Only attempt if cmd is not a built-in, to avoid shadowing cr test etc.
	if not COMMANDS[cmd] then
		local pkg = load_pkg_lua()
		if pkg and pkg.scripts and pkg.scripts[cmd] then
			local script = pkg.scripts[cmd]
			local exit_code = os.execute(script)
			-- os.execute returns true/0 on success in LuaJIT.
			if exit_code == true or exit_code == 0 then
				return true
			end
			os.exit(1)
		end
	end

	-- ── dispatch order 3: built-in commands ──────────────────────────────────

	local loader = COMMANDS[cmd]
	if not loader then
		io.stderr:write(("cr: unknown command %q\n"):format(cmd))
		io.stderr:write(USAGE)
		os.exit(1)
	end

	local mod = loader()
	if not mod or not mod.main then
		io.stderr:write(("cr: command %q has no main() export\n"):format(cmd))
		os.exit(1)
	end

	-- Pass sub_args with global opts injected (verbose, jobs, registry).
	local full_args = inject_global_opts(opts, sub_args)
	-- For pkg commands the first positional is the subcommand name itself.
	-- pkg/cli.lua.parse_args expects command as the first positional arg.
	-- For test and check, args are flags/filenames directly.
	-- Prepend the command name for pkg commands so pkg/cli.lua can route.
	local pkg_commands = { install=true, add=true, remove=true, update=true, info=true, publish=true }
	if pkg_commands[cmd] then
		table.insert(full_args, 1, cmd)
	end

	local ok, err = pcall(mod.main, full_args)
	if not ok then
		io.stderr:write(("cr: internal error in %q: %s\n"):format(cmd, tostring(err)))
		os.exit(1)
	end

	return true
end

return M
