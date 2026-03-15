if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

-- lib/pkg/cli.lua — crescent package manager CLI dispatcher
--
-- Usage: luajit lib/pkg/cli.lua <command> [args...]
--
-- Commands:
--   install [--frozen]          install all deps from pkg.lua / lockfile
--   add <name[@version]>        add dep to pkg.lua, install, update lockfile
--   remove <name>               remove dep, delete dep/<name>/, update lockfile
--   update [name]               re-resolve to latest matching version(s)
--   info <name>                 show package info from registry
--
-- Global flags:
--   --verbose                   enable verbose output
--   --registry=URL              override default registry (https://pkg.crescent.run)
--   --jobs=N                    parallelism (default: 1)

local manifest = require("lib.pkg.manifest")
local lock     = require("lib.pkg.lock")
local install  = require("lib.pkg.install")

local M = {}

-- ── constants ────────────────────────────────────────────────────────────────

local DEFAULT_REGISTRY = "https://pkg.crescent.run"

-- ── helpers ──────────────────────────────────────────────────────────────────

local function stderr(fmt, ...)
	io.stderr:write(("error: " .. fmt .. "\n"):format(...))
end

local function info(fmt, ...)
	io.stdout:write((fmt .. "\n"):format(...))
end

-- Run a shell command for side effects. Returns true or nil, err.
local function run_cmd(cmd)
	local ok = os.execute(cmd)
	if ok ~= 0 and ok ~= true then
		return nil, "command failed: " .. cmd
	end
	return true
end

-- Fetch URL and return body string, or nil, err.
local function http_get(url)
	local fh, err = io.popen(("curl -fsSL %q"):format(url), "r")
	if not fh then
		return nil, "popen failed: " .. tostring(err)
	end
	local out = fh:read("*a")
	fh:close()
	return out
end

-- Check whether a path exists.
local function path_exists(path)
	local f = io.open(path, "r")
	if f then f:close(); return true end
	return false
end

-- ── argument parsing ─────────────────────────────────────────────────────────

--- Parse argv into { command, args, flags }.
-- Global flags (--verbose, --registry=X, --jobs=N, --frozen) are extracted.
-- Remaining positional args are left in the args list.
function M.parse_args(argv)
	local result = {
		command  = nil,
		args     = {},
		verbose  = false,
		frozen   = false,
		registry = DEFAULT_REGISTRY,
		jobs     = 1,
	}

	local i = 0
	-- argv may be 0-indexed (arg table from luajit) or 1-indexed
	-- Normalise: collect into a plain 1-indexed list starting after index 0.
	local list = {}
	-- Support both arg[1..n] (test callers) and raw tables
	for j = 1, #argv do
		list[#list + 1] = argv[j]
	end

	for _, v in ipairs(list) do
		if v == "--verbose" then
			result.verbose = true
		elseif v == "--frozen" then
			result.frozen = true
		elseif v:sub(1, 11) == "--registry=" then
			result.registry = v:sub(12)
		elseif v:sub(1, 7) == "--jobs=" then
			local n = tonumber(v:sub(8))
			if n and n >= 1 then
				result.jobs = math.floor(n)
			end
		elseif v:sub(1, 2) == "--" then
			-- unknown flag — pass through as positional (commands may handle it)
			result.args[#result.args + 1] = v
		elseif result.command == nil then
			result.command = v
		else
			result.args[#result.args + 1] = v
		end
	end

	return result
end

--- Parse a package specifier like "sha1" or "sha1@1.0.0".
-- Returns name, constraint where constraint is "*" for bare names or "=1.0.0" for pinned.
function M.parse_pkg_spec(spec)
	local at = spec:find("@", 1, true)
	if at then
		local name    = spec:sub(1, at - 1)
		local version = spec:sub(at + 1)
		return name, "=" .. version
	end
	return spec, "*"
end

-- ── commands ─────────────────────────────────────────────────────────────────

--- cr install [--frozen]
local function cmd_install(project_dir, parsed)
	local opts = {
		frozen   = parsed.frozen,
		registry = parsed.registry,
		jobs     = parsed.jobs,
		verbose  = parsed.verbose,
	}

	local result = install.run(project_dir, opts)

	for _, name in ipairs(result.installed) do
		info("installed %s", name)
	end
	for _, name in ipairs(result.skipped) do
		if parsed.verbose then
			info("up to date %s", name)
		end
	end

	if not result.ok then
		for _, e in ipairs(result.errors) do
			stderr("%s", e)
		end
		return false
	end

	if #result.installed == 0 and #result.skipped == 0 then
		info("nothing to install")
	end

	return true
end

--- cr add <name[@version]>
local function cmd_add(project_dir, parsed)
	local spec = parsed.args[1]
	if not spec then
		stderr("add: missing package name")
		stderr("usage: cr add <name[@version]>")
		return false
	end

	local name, constraint = M.parse_pkg_spec(spec)

	-- Validate name roughly (matches manifest rules)
	if name == "" or name:find("[^a-z0-9_%-]") then
		stderr("add: invalid package name %q (only [a-z0-9_-] allowed)", name)
		return false
	end

	-- Load or create pkg.lua
	local pkg_path = project_dir .. "/pkg.lua"
	local m, m_err

	if path_exists(pkg_path) then
		m, m_err = manifest.load(pkg_path)
		if not m then
			stderr("add: failed to load pkg.lua: %s", tostring(m_err))
			return false
		end
	else
		-- Bootstrap a minimal manifest from the directory name
		local dir_name = project_dir:match("([^/]+)$") or "project"
		m = {
			name    = dir_name:gsub("[^a-z0-9_%-]", "-"):lower(),
			version = "0.1.0",
			deps    = {},
		}
	end

	m.deps = m.deps or {}

	if m.deps[name] then
		info("updating %s constraint: %s → %s", name, m.deps[name], constraint)
	else
		info("adding %s (%s)", name, constraint)
	end

	m.deps[name] = constraint

	local write_ok, write_err = manifest.write(pkg_path, m)
	if not write_ok then
		stderr("add: failed to write pkg.lua: %s", tostring(write_err))
		return false
	end

	-- Run install to fetch + update lockfile
	return cmd_install(project_dir, parsed)
end

--- cr remove <name>
local function cmd_remove(project_dir, parsed)
	local name = parsed.args[1]
	if not name then
		stderr("remove: missing package name")
		stderr("usage: cr remove <name>")
		return false
	end

	-- Load pkg.lua
	local pkg_path = project_dir .. "/pkg.lua"
	local m, m_err = manifest.load(pkg_path)
	if not m then
		stderr("remove: failed to load pkg.lua: %s", tostring(m_err))
		return false
	end

	m.deps = m.deps or {}

	if not m.deps[name] then
		stderr("remove: %q is not a direct dependency", name)
		return false
	end

	m.deps[name] = nil

	local write_ok, write_err = manifest.write(pkg_path, m)
	if not write_ok then
		stderr("remove: failed to write pkg.lua: %s", tostring(write_err))
		return false
	end

	-- Delete dep/<name>/ directory
	local dep_dir = project_dir .. "/dep/" .. name
	if path_exists(dep_dir .. "/pkg.lua") or path_exists(dep_dir) then
		local rm_ok, rm_err = run_cmd(("rm -rf %q"):format(dep_dir))
		if not rm_ok then
			stderr("remove: failed to delete dep/%s: %s", name, tostring(rm_err))
			return false
		end
		info("deleted dep/%s/", name)
	end

	-- Remove from crescent.lock
	local lock_path = project_dir .. "/crescent.lock"
	if path_exists(lock_path) then
		local entries, l_err = lock.load(lock_path)
		if not entries then
			stderr("remove: failed to parse crescent.lock: %s", tostring(l_err))
			return false
		end
		if entries[name] then
			entries[name] = nil
			local w_ok, w_err = lock.write(lock_path, entries)
			if not w_ok then
				stderr("remove: failed to write crescent.lock: %s", tostring(w_err))
				return false
			end
		end
	end

	info("removed %s", name)
	return true
end

--- cr update [name]
local function cmd_update(project_dir, parsed)
	local target = parsed.args[1]  -- nil means update all

	-- Load lockfile
	local lock_path = project_dir .. "/crescent.lock"
	local entries = {}
	if path_exists(lock_path) then
		local l, l_err = lock.load(lock_path)
		if not l then
			stderr("update: failed to parse crescent.lock: %s", tostring(l_err))
			return false
		end
		entries = l
	end

	if target then
		-- Drop only the specified package from the lockfile so install re-resolves it
		if entries[target] then
			entries[target] = nil
			local w_ok, w_err = lock.write(lock_path, entries)
			if not w_ok then
				stderr("update: failed to write crescent.lock: %s", tostring(w_err))
				return false
			end
			info("unpinned %s, re-resolving...", target)
		else
			info("update: %s is not in the lockfile, will resolve fresh", target)
		end
	else
		-- Drop all entries — full re-resolve
		if path_exists(lock_path) then
			local w_ok, w_err = lock.write(lock_path, {})
			if not w_ok then
				stderr("update: failed to reset crescent.lock: %s", tostring(w_err))
				return false
			end
			info("unpinned all packages, re-resolving...")
		end
	end

	-- Re-run install (no frozen — we want fresh resolution)
	local opts_copy = {
		frozen   = false,
		registry = parsed.registry,
		jobs     = parsed.jobs,
		verbose  = parsed.verbose,
	}
	local result = install.run(project_dir, opts_copy)

	for _, n in ipairs(result.installed) do
		info("updated %s", n)
	end
	for _, n in ipairs(result.skipped) do
		if parsed.verbose then
			info("unchanged %s", n)
		end
	end

	if not result.ok then
		for _, e in ipairs(result.errors) do
			stderr("%s", e)
		end
		return false
	end

	return true
end

--- cr info <name>
local function cmd_info(project_dir, parsed)
	local name = parsed.args[1]
	if not name then
		stderr("info: missing package name")
		stderr("usage: cr info <name>")
		return false
	end

	local registry = parsed.registry:gsub("/$", "")
	local url = registry .. "/index.json"

	local body, fetch_err = http_get(url)
	if not body then
		stderr("info: failed to fetch registry index: %s", tostring(fetch_err))
		return false
	end

	-- Minimal parse: find the entry for `name`
	-- Pattern: "name": { ... }
	-- Use install's exposed _parse_index if available, else a quick search.
	local idx, parse_err = install._parse_index(body)
	if not idx then
		stderr("info: failed to parse registry index: %s", tostring(parse_err))
		return false
	end

	local pkg = idx[name]
	if not pkg then
		stderr("info: package %q not found in registry", name)
		return false
	end

	info("package: %s", name)
	info("latest:  %s", tostring(pkg.latest))
	if pkg.versions and #pkg.versions > 0 then
		info("versions:")
		-- Print in reverse order (newest first) — versions are presumed ascending in registry
		for i = #pkg.versions, 1, -1 do
			info("  %s", pkg.versions[i])
		end
	else
		info("versions: (none)")
	end

	return true
end

-- ── main dispatcher ───────────────────────────────────────────────────────────

local COMMANDS = {
	install = cmd_install,
	add     = cmd_add,
	remove  = cmd_remove,
	update  = cmd_update,
	info    = cmd_info,
}

local USAGE = [[
usage: cr <command> [options]

commands:
  install [--frozen]        install all deps from pkg.lua / lockfile
  add <name[@version]>      add dep to pkg.lua, install, update lockfile
  remove <name>             remove dep, delete dep/<name>/, update lockfile
  update [name]             re-resolve to latest matching version(s)
  info <name>               show package info from registry

global options:
  --verbose                 enable verbose logging
  --registry=URL            registry base URL (default: https://pkg.crescent.run)
  --jobs=N                  parallel jobs (default: 1)
]]

--- Main entry point. argv is the arg table (1-indexed positional args).
-- Returns true on success, false on failure.
function M.main(argv)
	-- Determine project dir from CWD
	local project_dir = "."

	local parsed = M.parse_args(argv)

	if not parsed.command then
		io.stderr:write(USAGE)
		return false
	end

	local handler = COMMANDS[parsed.command]
	if not handler then
		stderr("unknown command %q", parsed.command)
		io.stderr:write(USAGE)
		return false
	end

	local ok, result = pcall(handler, project_dir, parsed)

	if not ok then
		stderr("internal error: %s", tostring(result))
		return false
	end

	return result == true
end

-- ── entry point ───────────────────────────────────────────────────────────────

if arg and arg[0] and arg[0]:match("pkg/cli%.lua$") then
	os.exit(M.main(arg) and 0 or 1)
end

return M
