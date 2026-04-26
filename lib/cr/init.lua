-- lib/cr/init.lua
-- Unified crescent CLI dispatcher.
--
-- Dispatch order for `cr <cmd>`:
--   1. <cmd>.lua exists as a file → run it via dofile
--   2. <cmd> matches a key in pkg.lua scripts table → os.execute the script
--   3. cr-<cmd>.lua exists in bin_dir → load file, call .main(argv)
--   4. cr-<cmd>.lua found in a PATH directory → load file, call .main(argv)
--   5. Error

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

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

-- Split PATH env var into a list of directory strings.
local function path_dirs()
	local path_env = os.getenv("PATH") or ""
	local sep = package.config:sub(1, 1) == "\\" and ";" or ":"
	local dirs = {}
	for dir in (path_env .. sep):gmatch("([^" .. sep .. "]*)" .. sep) do
		if dir ~= "" then dirs[#dirs + 1] = dir end
	end
	return dirs
end

-- Try to load and return a cr-<cmd>.lua module from a directory.
-- Returns the module table, or nil if not found or no .main export.
local function try_load_cr_cmd(dir, cmd)
	-- Normalise trailing slash.
	local slash = dir:sub(-1) == "/" and "" or "/"
	local path = dir .. slash .. "cr-" .. cmd .. ".lua"
	if not file_exists(path) then return nil end
	local chunk, err = loadfile(path)
	if not chunk then
		io.stderr:write(("cr: error loading %q: %s\n"):format(path, tostring(err)))
		return nil
	end
	local ok, mod = pcall(chunk)
	if not ok then
		io.stderr:write(("cr: error in %q: %s\n"):format(path, tostring(mod)))
		return nil
	end
	if type(mod) ~= "table" or type(mod.main) ~= "function" then
		io.stderr:write(("cr: %q has no main() export\n"):format(path))
		return nil
	end
	return mod
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
  platform <app> [entry]    run a platform app
  daemon                    run the platform daemon
  doc [files...]            generate documentation

  <file>.lua                run a Lua file directly
  <script>                  run a script defined in pkg.lua scripts table

  (Additional commands are resolved as cr-<cmd>.lua files in bin/ or PATH.)

global flags:
  --verbose / -v            verbose output
  --jobs=N                  parallelism (test runner + package fetch)
  --registry=URL            prepend a registry for this invocation
  --no-color                disable ANSI output
]]

-- ── main ──────────────────────────────────────────────────────────────────────

--- Main entry point.
-- argv is a 1-indexed list of arguments (e.g. the global arg).
-- bin_dir is the directory containing the cr-*.lua files (e.g. bin/).
function M.main(argv, bin_dir)
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

	-- Pass sub_args with global opts injected (verbose, jobs, registry).
	local full_args = inject_global_opts(opts, sub_args)

	-- ── dispatch order 1: file dispatch ───────────────────────────────────────

	-- If cmd looks like a .lua file or a bare name that maps to an existing file.
	local file_target
	if cmd:match("%.lua$") then
		file_target = cmd
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

	-- ── dispatch order 3: bin_dir cr-<cmd>.lua ────────────────────────────────

	if bin_dir then
		local mod = try_load_cr_cmd(bin_dir, cmd)
		if mod then
			local ok, err = pcall(mod.main, full_args)
			if not ok then
				io.stderr:write(("cr: internal error in %q: %s\n"):format(cmd, tostring(err)))
				os.exit(1)
			end
			return true
		end
	end

	-- ── dispatch order 4: PATH cr-<cmd>.lua ───────────────────────────────────

	for _, dir in ipairs(path_dirs()) do
		local mod = try_load_cr_cmd(dir, cmd)
		if mod then
			local ok, err = pcall(mod.main, full_args)
			if not ok then
				io.stderr:write(("cr: internal error in %q: %s\n"):format(cmd, tostring(err)))
				os.exit(1)
			end
			return true
		end
	end

	-- ── dispatch order 5: error ───────────────────────────────────────────────

	io.stderr:write(("cr: unknown command %q\n"):format(cmd))
	io.stderr:write(USAGE)
	os.exit(1)
end

return M
