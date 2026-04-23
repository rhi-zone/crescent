-- lib/platform/cli.lua
-- CLI entry point for launching a crescent platform app.
--
-- Usage:
--   luajit lib/platform/cli.lua <app> [entrypoint] [-- args...]
--   luajit lib/platform/cli.lua import <card.png> [--runtime=path] [--apps-dir=path]
--   luajit lib/platform/cli.lua list [--apps-dir=path] [--tag=TAG]
--   luajit lib/platform/cli.lua caps [--apps-dir=path] <app_id> [<cap_name> [key=value...] [--reset]]
--
-- Platform flags (before --):
--   --port=N            HTTP port for http_server cap (default 7860)
--   --data-dir=PATH     Directory for persistent data (default ~/.crescent/data)
--   --grant=NAME        Grant a specific capability (repeatable)
--   --deny=NAME         Deny a specific capability (repeatable)
--   --reset-grants      Clear stored grants
--   --cap.NAME.KEY=VAL  Override a cap declaration field (e.g. --cap.fs.root=./cards)
--
-- Everything after -- is passed to the app's cli cap.
-- There are no app-specific CLI flags. App config is the app's problem.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local json = require("lib.json")
local platform = require("lib.platform")

-- ── LLM env-var key resolution ────────────────────────────────────────────────
-- At cap construction time, check well-known env vars in priority order and
-- inject into opts so app code can pick them up via opts.api_key.
-- The server layer then tries keyring before falling back to nil (local model).
local function resolve_llm_api_key_from_env()
	return os.getenv("OPENAI_API_KEY")
		or os.getenv("ANTHROPIC_API_KEY")
		or os.getenv("LLM_API_KEY")
		or nil
end

-- ── Arg parsing ────────────────────────────────────────────────────────────

local function parse_args(args)
	local opts = {
		port = 7860,
		data_dir = nil,
		reset_grants = false,
		grant_caps = {},
		deny_caps = {},
		cap_overrides = {},  -- cap_overrides["fs"]["root"] = "/some/path"
	}
	local positional = {}
	local app_args = {}
	local past_separator = false

	for i = 1, #args do
		local a = args[i]
		if past_separator then
			app_args[#app_args + 1] = a
		elseif a == "--" then
			past_separator = true
		else
			local key, val = a:match("^%-%-([^=]+)=(.*)")
			if key then
				if key == "port" then
					opts.port = tonumber(val) or opts.port
				elseif key == "data-dir" then
					opts.data_dir = val
				elseif key == "grant" then
					opts.grant_caps[#opts.grant_caps + 1] = val
				elseif key == "deny" then
					opts.deny_caps[#opts.deny_caps + 1] = val
				else
					-- --cap.NAME.KEY=VALUE overrides a cap declaration field.
					local cap_name, cap_key = key:match("^cap%.([^.]+)%.(.+)$")
					if cap_name then
						if not opts.cap_overrides[cap_name] then
							opts.cap_overrides[cap_name] = {}
						end
						opts.cap_overrides[cap_name][cap_key] = val
					else
						io.stderr:write("unknown option: --" .. key .. "\n")
						os.exit(1)
					end
				end
			elseif a == "--reset-grants" then
				opts.reset_grants = true
			elseif a:sub(1, 1) == "-" then
				io.stderr:write("unknown flag: " .. a .. "\n")
				os.exit(1)
			else
				positional[#positional + 1] = a
			end
		end
	end

	if #positional < 1 then
		io.stderr:write("usage: luajit lib/platform/cli.lua <app> [entrypoint] [-- args...]\n")
		os.exit(1)
	end

	opts.app = positional[1]
	opts.entrypoint = positional[2]  -- may be nil
	opts.app_args = app_args
	return opts
end

-- ── Helpers ────────────────────────────────────────────────────────────────

local function expand_home(path)
	if path:sub(1, 1) == "~" then
		local home = os.getenv("HOME") or ""
		return home .. path:sub(2)
	end
	return path
end

local function is_dir(path)
	local f = io.open(path .. "/.", "r")
	if f then f:close(); return true end
	return false
end

local function file_exists(path)
	local f = io.open(path, "rb")
	if f then f:close(); return true end
	return false
end

local function read_file(path)
	local f, err = io.open(path, "rb")
	if not f then return nil, err end
	local content = f:read("*a")
	f:close()
	return content
end

local function write_file(path, content)
	local f, err = io.open(path, "wb")
	if not f then return nil, err end
	f:write(content)
	f:close()
	return true
end

local function mkdir_p(path)
	os.execute('mkdir -p "' .. path .. '"')
end

-- List files recursively under a directory, returning relative paths.
local function list_files(dir, prefix)
	prefix = prefix or ""
	local results = {}
	local p = io.popen('ls -1 "' .. dir .. '" 2>/dev/null')
	if not p then return results end
	for name in p:lines() do
		local full = dir .. "/" .. name
		local rel = prefix == "" and name or (prefix .. "/" .. name)
		if is_dir(full) then
			local sub = list_files(full, rel)
			for i = 1, #sub do
				results[#results + 1] = sub[i]
			end
		else
			results[#results + 1] = rel
		end
	end
	p:close()
	return results
end

-- ── Directory mode app loading ────────────────────────────────────────────

-- Load an app from a directory (development mode).
-- Returns an app-like table compatible with platform.run_entry / cap factories.
local function load_dir_app(dir)
	local manifest_path = dir .. "/manifest.json"
	local manifest_src, err = read_file(manifest_path)
	if not manifest_src then
		return nil, "cannot read manifest: " .. tostring(err)
	end
	local manifest, jerr = json.decode(manifest_src)
	if not manifest then
		return nil, "manifest.json parse failed: " .. tostring(jerr)
	end
	return {
		path = dir,
		chunks = nil,
		entries = nil,  -- directory mode: no tarball entries
		manifest = manifest,
		-- Directory mode flag for cap factories that need to know.
		_dir_mode = true,
	}
end

-- ── Self cap for directory mode ───────────────────────────────────────────

local function make_dir_self_cap(app_dir)
	local png_mod = require("lib.png")

	-- Look for card PNG lazily.
	local card_path
	local chunks_cache
	local function get_chunks()
		if chunks_cache then return chunks_cache end
		if not card_path then
			-- Find first .png in the directory.
			local p = io.popen('ls -1 "' .. app_dir .. '" 2>/dev/null')
			if p then
				for name in p:lines() do
					if name:match("%.png$") then
						card_path = app_dir .. "/" .. name
						break
					end
				end
				p:close()
			end
		end
		if not card_path or not file_exists(card_path) then return nil end
		local bytes, err = read_file(card_path)
		if not bytes then return nil end
		local chunks, perr = png_mod.read(bytes)
		if not chunks then return nil end
		chunks_cache = chunks
		return chunks
	end

	local revoked = false

	local cap = {
		metadata = function(keyword)
			if revoked then return nil, "capability revoked" end
			local chunks = get_chunks()
			if not chunks then return nil end
			return png_mod.get_text(chunks, keyword)
		end,

		entries = function()
			if revoked then return nil, "capability revoked" end
			return list_files(app_dir)
		end,

		entry = function(path)
			if revoked then return nil, "capability revoked" end
			local full = app_dir .. "/" .. path
			return read_file(full)
		end,
	}

	local function revoke() revoked = true end

	return cap, revoke
end

-- ── Grant persistence ─────────────────────────────────────────────────────
-- NOTE: grant persistence format is provisional. Future: tarball filesystem
-- browser + syntax-highlighted code viewer for informed grant decisions.

local function grants_path(data_dir, app_id)
	return data_dir .. "/" .. app_id .. "/grants.json"
end

local function load_grants(data_dir, app_id)
	local path = grants_path(data_dir, app_id)
	local content = read_file(path)
	if not content then return nil end
	local grants, err = json.decode(content)
	if not grants then return nil end
	return grants
end

local function save_grants(data_dir, app_id, grants)
	local dir = data_dir .. "/" .. app_id
	mkdir_p(dir)
	local content = json.encode(grants)
	write_file(grants_path(data_dir, app_id), content)
end

-- ── Entrypoint resolution ─────────────────────────────────────────────────

-- Merge top-level and per-entrypoint cap declarations.
local function merge_cap_declarations(manifest, entry_key)
	local cap_declarations = {}

	-- Top-level caps: may be shorthand ("required"/"optional") or full tables.
	local top_caps = manifest.caps
	if top_caps then
		for name, decl in pairs(top_caps) do
			if type(decl) == "string" then
				-- Shorthand: "required" or "optional"
				cap_declarations[name] = {
					type = name,
					required = decl ~= "optional",
				}
			elseif type(decl) == "table" then
				cap_declarations[name] = decl
			end
		end
	end

	-- Per-entrypoint caps override/merge with top-level.
	local entry_map = manifest.entry
	if entry_map then
		local entry_def = entry_map[entry_key]
		if type(entry_def) == "table" and entry_def.caps then
			for name, decl in pairs(entry_def.caps) do
				cap_declarations[name] = decl
			end
		end
	end

	return cap_declarations
end

-- ── Cap construction ──────────────────────────────────────────────────────
-- Maps cap type strings to factory modules. Uses . calling convention.

local CAP_TYPE_MODULES = {
	self        = "lib.platform.caps.self",
	self_write  = "lib.platform.caps.self",
	http_server = "lib.platform.caps.http_server",
	http_client = "lib.platform.caps.http_client",
	kv          = "lib.platform.caps.kv",
	db          = "lib.platform.caps.db",
	shared_db   = "lib.platform.caps.shared_db",
	time        = "lib.platform.caps.time",
	cli         = "lib.platform.caps.cli",
	stdin       = "lib.platform.caps.stdin",
	stdout      = "lib.platform.caps.stdout",
	fs          = "lib.platform.caps.fs",
	llm = "lib.platform.caps.llm",
}

local function build_cap(cap_name, decl, app, context, platform_opts)
	local cap_type = decl.type or cap_name

	-- self cap: directory mode uses our custom builder, archive mode uses the factory.
	if cap_type == "self" then
		if app._dir_mode then
			return make_dir_self_cap(app.path)
		else
			local mod = require(CAP_TYPE_MODULES.self)
			return mod.self_cap(app)
		end
	end

	-- self_write cap: archive mode only — directory-mode apps don't have a real
	-- image file to atomically rewrite. Dev/dir workflow should re-export the
	-- tarball+PNG before granting self_write.
	if cap_type == "self_write" then
		if app._dir_mode then
			return nil, "self_write not supported in directory mode"
		end
		local mod = require(CAP_TYPE_MODULES.self_write)
		return mod.self_write_cap(app)
	end

	-- http_server: inject port from platform flags.
	if cap_type == "http_server" then
		local mod = require(CAP_TYPE_MODULES.http_server)
		return mod.http_server_cap({ port = platform_opts.port or 0 })
	end

	-- http_client: pass through host and any extra fields from declaration.
	if cap_type == "http_client" then
		local mod = require(CAP_TYPE_MODULES.http_client)
		return mod.http_client_cap({
			host  = decl.host,
			model = decl.model,
			path  = decl.path,
			paths = decl.paths,
		})
	end

	-- Storage caps: resolve data path from scope dimensions.
	-- If decl.path is set explicitly (e.g. via --cap.NAME.path=FILE), use it directly.
	if cap_type == "kv" or cap_type == "db" or cap_type == "shared_db" then
		local data_path = decl.path and expand_home(decl.path) or platform._resolve_data_path(cap_name, decl.scope, context)
		-- Ensure parent directory exists for the backing store file.
		local parent_dir = data_path:match("^(.*)/[^/]+$")
		if parent_dir then mkdir_p(parent_dir) end
		if cap_type == "kv" then
			local mod = require(CAP_TYPE_MODULES.kv)
			return mod.kv_cap(data_path)
		elseif cap_type == "db" then
			local mod = require(CAP_TYPE_MODULES.db)
			return mod.db_cap(data_path, { readonly = decl.readonly })
		elseif cap_type == "shared_db" then
			local mod = require(CAP_TYPE_MODULES.shared_db)
			return mod.shared_db_cap(data_path, context.app_id, decl.tables or {}, {
				readonly = decl.readonly,
			})
		end
	end

	-- time: no args.
	if cap_type == "time" then
		local mod = require(CAP_TYPE_MODULES.time)
		return mod.time_cap()
	end

	-- cli: pass app args.
	if cap_type == "cli" then
		local mod_path = CAP_TYPE_MODULES.cli
		local ok, mod = pcall(require, mod_path)
		if ok and mod.cli_cap then
			return mod.cli_cap(platform_opts.app_args or {})
		end
		-- Fallback: plain table.
		return { args = function() return platform_opts.app_args or {} end }
	end

	-- stdin: grant access to process stdin.
	if cap_type == "stdin" then
		local mod_path = CAP_TYPE_MODULES.stdin
		local ok, mod = pcall(require, mod_path)
		if ok and mod.stdin_cap then
			return mod.stdin_cap()
		end
		return nil, "stdin cap module not available"
	end

	-- stdout: grant access to process stdout.
	if cap_type == "stdout" then
		local mod_path = CAP_TYPE_MODULES.stdout
		local ok, mod = pcall(require, mod_path)
		if ok and mod.stdout_cap then
			return mod.stdout_cap()
		end
		return nil, "stdout cap module not available"
	end

	-- fs: scoped filesystem access. Root is REQUIRED — unrestricted fs is never safe.
	if cap_type == "fs" then
		local root = decl.root
		if not root then
			return nil, "fs cap '" .. cap_name .. "' has no root — use --cap." .. cap_name .. ".root=PATH"
		end
		root = expand_home(root)
		mkdir_p(root)
		local mod = require(CAP_TYPE_MODULES.fs)
		return mod.fs_cap({ root = root, allow_write = not decl.readonly })
	end

	-- llm: provider-agnostic LLM access.
	-- The manifest declares provider + key_name; the platform resolves the key
	-- from the keyring. The app never sees the raw key.
	if cap_type == "llm" then
		local provider = decl.provider
		local key_name = decl.key_name
		local api_key

		if key_name then
			local ok_kr, keyring = pcall(require, "lib.keyring")
			if ok_kr and keyring then
				local kr_key = keyring.get("crescent/" .. key_name)
				if kr_key then
					api_key = kr_key
				else
					-- Key not in keyring yet; try env var and auto-enroll it.
					local env_key = resolve_llm_api_key_from_env()
					if env_key then
						keyring.set("crescent/" .. key_name, env_key)
						api_key = env_key
					end
				end
			end
		end

		-- Final fallback: env var (when keyring is unavailable, e.g. no libsecret).
		if not api_key then
			api_key = resolve_llm_api_key_from_env()
		end

		-- Provider may be nil for manifest declarations that leave it to the
		-- operator; default to "openai" as the most common case.
		provider = provider or decl.provider_default or "openai"

		local mod = require(CAP_TYPE_MODULES.llm)
		return mod.llm_cap({
			provider = provider,
			key      = api_key,
			model    = decl.model,
			base_url = decl.base_url,
		})
	end

	return nil, "unknown cap type: " .. tostring(cap_type)
end

local function construct_caps(cap_declarations, grants, app, context, platform_opts)
	local caps = {}
	local revoke_fns = {}

	for name, decl in pairs(cap_declarations) do
		local required = decl.required ~= false  -- default true

		if not grants[name] then
			if required then
				return nil, "required cap '" .. name .. "' not granted by operator"
			end
			-- Optional and not granted: skip (app gets nil).
		else
			local ok, cap, revoke_or_err = pcall(build_cap, name, decl, app, context, platform_opts)
			if not ok then
				-- build_cap threw an error (cap holds the error message).
				if required then
					return nil, "failed to build cap '" .. name .. "': " .. tostring(cap)
				end
				-- Optional cap threw: skip.
			elseif not cap then
				-- build_cap returned nil, err.
				if required then
					return nil, "failed to build cap '" .. name .. "': " .. tostring(revoke_or_err)
				end
				-- Optional cap failed to build: skip.
			else
				caps[name] = cap
				if type(revoke_or_err) == "function" then
					revoke_fns[name] = revoke_or_err
				end
			end
		end
	end

	-- Wrap caps in a strict proxy: accessing an undeclared cap name errors
	-- immediately instead of returning nil silently.
	local declared = {}
	for name in pairs(cap_declarations) do declared[name] = true end
	local caps_proxy = setmetatable({}, {
		__index = function(_, k)
			if caps[k] ~= nil then return caps[k] end
			if declared[k] then return nil end -- declared optional, not granted
			error("cap '" .. tostring(k) .. "' accessed but not declared in manifest", 2)
		end,
		__newindex = function() error("caps table is read-only", 2) end,
		__pairs = function() return next, caps, nil end,
	})

	return caps_proxy, revoke_fns
end

-- ── Entrypoint execution (directory mode) ─────────────────────────────────

-- make_dir_loader(app_dir, env) -> function(modname)
-- Returns a package.loaders-compatible function that resolves require() against
-- the app directory on disk. Loads files in the sandbox env (text mode only).
-- Module cache is local to this loader — no host pollution.
local function make_dir_loader(app_dir, env)
	local loaded = {}
	-- Build the module prefix that corresponds to app_dir so that fully-qualified
	-- sibling requires like require("lib.platform.apps.charactercardv2.presets")
	-- resolve to "presets.lua" inside the app dir instead of a double path.
	local dir_prefix = app_dir:gsub("^%./", ""):gsub("/", ".") .. "."
	return function(modname)
		if loaded[modname] then return function() return loaded[modname] end end
		local relname = modname
		if relname:sub(1, #dir_prefix) == dir_prefix then
			relname = relname:sub(#dir_prefix + 1)
		end
		local relpath = relname:gsub("%.", "/")
		local candidates = {
			relpath .. ".lua",
			relpath .. "/init.lua",
		}
		for _, candidate in ipairs(candidates) do
			local full = app_dir .. "/" .. candidate
			local src = read_file(full)
			if src then
				return function()
					local fn, lerr = load(src, "@" .. candidate, "t", env)
					if not fn then error("platform: error loading '" .. candidate .. "': " .. tostring(lerr), 2) end
					local result = fn()
					loaded[modname] = result or true
					return result
				end
			end
		end
		return "\n\tno file '" .. candidates[1] .. "' or '" .. candidates[2] .. "' in app directory"
	end
end

local function run_dir_entrypoint(app, entry_path, caps)
	local sandbox = require("lib.sandbox")
	local cap_bundle = { globals = { caps = caps }, modules = {} }
	local env = sandbox.env(sandbox.stdlib, cap_bundle)

	-- Mirror daemon mode: dir_loader serves the app's own files first; the
	-- whitelist require (modules={}) is the fallback — nothing from the host
	-- is reachable unless explicitly added to modules. This matches what
	-- platform.run_entry does for archive apps (tar_loader + whitelist fallback).
	local dir_loader = make_dir_loader(app.path, env)
	local whitelist_require = env.require  -- whitelist built by sandbox.env
	env.require = function(modname)
		local loader_or_err = dir_loader(modname)
		if type(loader_or_err) == "function" then
			return loader_or_err()
		end
		-- Fall back to whitelist require; rejects anything not in modules.
		return whitelist_require(modname)
	end

	-- Read and run the entrypoint file in the sandbox.
	local full_path = app.path .. "/" .. entry_path
	local src, rerr = read_file(full_path)
	if not src then
		return nil, "could not read entrypoint: " .. tostring(rerr)
	end

	local ok, result = sandbox.run(src, env, { name = "@" .. entry_path })
	if not ok then
		return nil, "could not load entrypoint: " .. tostring(result)
	end
	return result, nil
end

-- ── Shared index helpers ──────────────────────────────────────────────────

-- Open the app index DB; writes error + exits on failure.
local function open_index(apps_dir_arg)
	local apps_dir = expand_home(apps_dir_arg or "~/.crescent/apps")
	mkdir_p(apps_dir)
	local app_index_mod = require("lib.platform.index")
	local idx, ierr = app_index_mod.open(apps_dir .. "/index.db")
	if not idx then
		io.stderr:write("error: cannot open index: " .. tostring(ierr) .. "\n")
		os.exit(1)
	end
	return idx
end

-- Collect all cap declarations across top-level and all entry sections.
-- Returns { [cap_name]: decl_table }.
local function all_cap_decls(manifest)
	local caps = {}
	if type(manifest.caps) == "table" then
		for k, v in pairs(manifest.caps) do caps[k] = v end
	end
	if type(manifest.entry) == "table" then
		for _, entry_def in pairs(manifest.entry) do
			if type(entry_def) == "table" and type(entry_def.caps) == "table" then
				for k, v in pairs(entry_def.caps) do caps[k] = v end
			end
		end
	end
	return caps
end

-- Sorted keys of a table.
local function sorted_keys(t)
	local keys = {}
	for k in pairs(t) do keys[#keys + 1] = k end
	table.sort(keys)
	return keys
end

-- ── list subcommand ────────────────────────────────────────────────────────

local function cmd_list(args)
	-- Usage: luajit lib/platform/cli.lua list [--apps-dir=PATH] [--tag=TAG]
	local apps_dir_arg, tag_filter
	for i = 2, #args do
		local a = args[i]
		local key, val = a:match("^%-%-([^=]+)=(.*)")
		if key == "apps-dir" then apps_dir_arg = val
		elseif key == "tag" then tag_filter = val
		elseif a:sub(1,1) == "-" then
			io.stderr:write("unknown flag: " .. a .. "\n"); os.exit(1)
		end
	end

	local idx = open_index(apps_dir_arg)
	local rows = tag_filter and idx:list({ tag = tag_filter }) or idx:list()
	idx:close()

	if #rows == 0 then
		io.write("(no apps installed)\n")
		return
	end
	for _, row in ipairs(rows) do
		local tags = row.tags and #row.tags > 0 and ("  [" .. table.concat(row.tags, ", ") .. "]") or ""
		io.write(string.format("%4d  %s%s\n", row.id, row.name, tags))
	end
end

-- ── caps subcommand ────────────────────────────────────────────────────────

local function cmd_caps(args)
	-- Usage:
	--   luajit lib/platform/cli.lua caps [--apps-dir=PATH] <app_id>
	--       Show all caps with manifest defaults and stored overrides.
	--   luajit lib/platform/cli.lua caps [--apps-dir=PATH] <app_id> <cap_name> [key=value ...]
	--       Show or set overrides for one cap.
	--   luajit lib/platform/cli.lua caps [--apps-dir=PATH] <app_id> <cap_name> --reset
	--       Clear all overrides for one cap.

	local apps_dir_arg
	local positional = {}
	local do_reset = false
	local kv_pairs = {}

	for i = 2, #args do
		local a = args[i]
		local key, val = a:match("^%-%-([^=]+)=(.*)")
		if key == "apps-dir" then
			apps_dir_arg = val
		elseif a == "--reset" then
			do_reset = true
		elseif a:sub(1,1) == "-" then
			io.stderr:write("unknown flag: " .. a .. "\n"); os.exit(1)
		elseif a:find("=", 1, true) then
			kv_pairs[#kv_pairs + 1] = a
		else
			positional[#positional + 1] = a
		end
	end

	if #positional < 1 then
		io.stderr:write("usage: luajit lib/platform/cli.lua caps [--apps-dir=PATH] <app_id> [<cap_name> [key=value...] [--reset]]\n")
		os.exit(1)
	end

	local idx = open_index(apps_dir_arg)
	local app_id = tonumber(positional[1])
	if not app_id then
		io.stderr:write("error: app_id must be a number — run 'list' to see installed apps\n")
		idx:close(); os.exit(1)
	end

	local row = idx:get(app_id)
	if not row then
		io.stderr:write("error: no app with id " .. tostring(app_id) .. "\n")
		idx:close(); os.exit(1)
	end

	local cap_name = positional[2]
	local decls = all_cap_decls(row.manifest or {})

	-- Helper: print one cap's fields with override annotations.
	local function print_cap(cname, decl)
		local cap_type = type(decl) == "table" and (decl.type or cname) or cname
		local overrides = idx:get_cap_config(app_id, cname)
		io.write("  " .. cname .. "  (" .. cap_type .. ")\n")
		-- Collect fields: manifest fields (minus meta-keys) + any extra override keys.
		local skip = { type=true, required=true, configurable_fields=true, sensitive_fields=true }
		local fields = {}
		local seen = {}
		if type(decl) == "table" then
			for k in pairs(decl) do
				if not skip[k] then fields[#fields + 1] = k; seen[k] = true end
			end
		end
		for k in pairs(overrides) do
			if not seen[k] then fields[#fields + 1] = k end
		end
		table.sort(fields)
		if #fields == 0 then
			io.write("    (no configurable fields)\n")
		else
			for _, fk in ipairs(fields) do
				local mval = type(decl) == "table" and decl[fk] or nil
				local oval = overrides[fk]
				if oval ~= nil then
					io.write(string.format("    %-20s %s  [override]\n", fk, tostring(oval)))
				else
					io.write(string.format("    %-20s %s\n", fk, tostring(mval)))
				end
			end
		end
	end

	if not cap_name then
		-- Show all caps.
		io.write("app: " .. tostring(row.name) .. "  (id " .. tostring(app_id) .. ")\n")
		for _, cname in ipairs(sorted_keys(decls)) do
			print_cap(cname, decls[cname])
		end
		idx:close()
		return
	end

	-- Validate cap exists in manifest.
	if not decls[cap_name] then
		io.stderr:write("error: cap '" .. cap_name .. "' not declared in manifest\n")
		io.stderr:write("declared caps: " .. table.concat(sorted_keys(decls), ", ") .. "\n")
		idx:close(); os.exit(1)
	end

	if do_reset then
		local ok, err = idx:reset_cap_config(app_id, cap_name)
		if not ok then
			io.stderr:write("error: " .. tostring(err) .. "\n")
			idx:close(); os.exit(1)
		end
		io.write("reset: " .. cap_name .. " overrides cleared\n")
		idx:close()
		return
	end

	if #kv_pairs == 0 then
		-- Show this one cap.
		io.write("app: " .. tostring(row.name) .. "  (id " .. tostring(app_id) .. ")\n")
		print_cap(cap_name, decls[cap_name])
		idx:close()
		return
	end

	-- Set field overrides.
	local existing = idx:get_cap_config(app_id, cap_name)
	for _, kv in ipairs(kv_pairs) do
		local k, v = kv:match("^([^=]+)=(.*)")
		if not k then
			io.stderr:write("error: invalid key=value pair: " .. kv .. "\n")
			idx:close(); os.exit(1)
		end
		-- Coerce: boolean > number > string.
		local coerced
		if     v == "true"  then coerced = true
		elseif v == "false" then coerced = false
		elseif tonumber(v)  then coerced = tonumber(v)
		else                     coerced = v
		end
		existing[k] = coerced
	end
	local ok, err = idx:set_cap_config(app_id, cap_name, existing)
	if not ok then
		io.stderr:write("error: " .. tostring(err) .. "\n")
		idx:close(); os.exit(1)
	end
	for _, kv in ipairs(kv_pairs) do
		io.write("set: " .. cap_name .. "." .. kv .. "\n")
	end
	idx:close()
end

-- ── set-key subcommand ────────────────────────────────────────────────────
-- Usage: luajit lib/platform/cli.lua set-key <name> <value>
-- Stores an API key in the keyring as "crescent/<name>".
-- Example: luajit lib/platform/cli.lua set-key anthropic sk-ant-...

local function cmd_set_key(args)
	local key_name  = args[2]
	local key_value = args[3]
	local ok_kr, keyring = pcall(require, "lib.keyring")
	if not ok_kr then
		io.stderr:write("error: keyring unavailable: " .. tostring(keyring) .. "\n")
		os.exit(1)
	end
	-- No args: list all crescent/* keys.
	if not key_name then
		local keys, err = keyring.list("crescent/")
		if not keys then
			io.write("usage: luajit lib/platform/cli.lua set-key <name> [value]\n")
			io.write("  set-key <name> <value>  -- store key\n")
			io.write("  set-key <name>          -- show current value\n")
			if err ~= "not supported" then
				io.stderr:write("(list unavailable: " .. tostring(err) .. ")\n")
			end
			return
		end
		if #keys == 0 then
			io.write("(no keys stored)\n")
		else
			for _, k in ipairs(keys) do
				io.write(k:gsub("^crescent/", "") .. "\n")
			end
		end
		return
	end
	-- One arg: show masked value.
	if not key_value then
		local val, err = keyring.get("crescent/" .. key_name)
		if val then
			local visible = val:sub(1, 8)
			local masked = visible .. string.rep("*", math.max(0, #val - 8))
			io.write(key_name .. " = " .. masked .. "\n")
		else
			io.write(key_name .. ": not set\n")
		end
		return
	end
	-- Two args: set key.
	local ok, err = keyring.set("crescent/" .. key_name, key_value)
	if not ok then
		io.stderr:write("error storing key: " .. tostring(err) .. "\n")
		os.exit(1)
	end
	io.write("stored: crescent/" .. key_name .. "\n")
end

-- ── Import subcommand ──────────────────────────────────────────────────────

local function cmd_import(args)
	-- Usage: luajit lib/platform/cli.lua import <card.png> [--runtime=path] [--apps-dir=path]
	local png_path, runtime_dir, apps_dir
	for i = 2, #args do
		local a = args[i]
		local key, val = a:match("^%-%-([^=]+)=(.*)")
		if key == "runtime" then
			runtime_dir = val
		elseif key == "apps-dir" then
			apps_dir = val
		elseif a:sub(1, 1) ~= "-" then
			png_path = a
		end
	end

	if not png_path then
		io.stderr:write("usage: luajit lib/platform/cli.lua import <card.png> [--runtime=path] [--apps-dir=path]\n")
		os.exit(1)
	end

	runtime_dir = runtime_dir or "lib/platform/apps/charactercardv2"
	apps_dir = expand_home(apps_dir or "~/.crescent/apps")
	mkdir_p(apps_dir)

	-- Read the card PNG.
	local png_bytes, perr = read_file(png_path)
	if not png_bytes then
		io.stderr:write("error: cannot read " .. png_path .. ": " .. tostring(perr) .. "\n")
		os.exit(1)
	end

	-- Read the runtime manifest.
	local manifest_src, merr = read_file(runtime_dir .. "/manifest.json")
	if not manifest_src then
		io.stderr:write("error: cannot read runtime manifest: " .. tostring(merr) .. "\n")
		os.exit(1)
	end
	local runtime_manifest = json.decode(manifest_src)
	if not runtime_manifest then
		io.stderr:write("error: cannot parse runtime manifest\n")
		os.exit(1)
	end

	-- Collect all runtime files (non-test, non-manifest) recursively.
	local runtime_files = {}
	local all_files = list_files(runtime_dir)
	for _, relpath in ipairs(all_files) do
		if relpath ~= "manifest.json" and not relpath:match("_test%.lua$") then
			local content = read_file(runtime_dir .. "/" .. relpath)
			if content then
				runtime_files[#runtime_files + 1] = { name = relpath, data = content }
			end
		end
	end

	-- Open or create the index database.
	local app_index = require("lib.platform.index")
	local idx_path = apps_dir .. "/index.db"
	local idx, ierr = app_index.open(idx_path)
	if not idx then
		io.stderr:write("error: cannot open index: " .. tostring(ierr) .. "\n")
		os.exit(1)
	end

	-- Run import.
	local import_mod = require("lib.platform.import")
	local app_path, result_or_err = import_mod.import_card({
		png_bytes = png_bytes,
		runtime_files = runtime_files,
		runtime_manifest = runtime_manifest,
		apps_dir = apps_dir,
		index = idx,
		timestamp = os.time(),
		write_fn = function(path, data) return write_file(path, data) end,
	})

	idx:close()

	if not app_path then
		io.stderr:write("error: " .. tostring(result_or_err) .. "\n")
		os.exit(1)
	end

	io.stdout:write("installed: " .. app_path .. "\n")
	io.stdout:write("name: " .. (result_or_err.name or "?") .. "\n")
	local tags = result_or_err.meta and result_or_err.meta.tags or {}
	if #tags > 0 then
		io.stdout:write("tags: " .. table.concat(tags, ", ") .. "\n")
	end
end

-- ── Main ───────────────────────────────────────────────────────────────────

-- Check for subcommands before parsing args (subcommands have their own arg format).
if arg[1] == "import" then
	cmd_import(arg)
	return
elseif arg[1] == "list" then
	cmd_list(arg)
	return
elseif arg[1] == "caps" then
	cmd_caps(arg)
	return
elseif arg[1] == "set-key" then
	cmd_set_key(arg)
	return
end

local opts = parse_args(arg)

-- Load the app. Currently supports directory mode; future: PNG, tar.gz, etc.
local app, err
if is_dir(opts.app) then
	app, err = load_dir_app(opts.app)
else
	-- Try platform.load_app for archive formats.
	app, err = platform.load_app(opts.app)
end

if not app then
	io.stderr:write("error: " .. tostring(err) .. "\n")
	os.exit(1)
end

local manifest = app.manifest

-- Resolve entrypoint.
local entry_map = manifest.entry
if not entry_map or not next(entry_map) then
	-- No entry table in manifest — legacy app or misconfigured.
	io.stderr:write("error: manifest has no 'entry' table\n")
	io.stderr:write("The manifest must declare entrypoints. Example:\n")
	io.stderr:write('  "entry": { "server": { "main": "server.lua", "caps": {...} } }\n')
	os.exit(1)
end

if not opts.entrypoint then
	-- Try default_entry from manifest.
	if manifest.default_entry and entry_map[manifest.default_entry] then
		opts.entrypoint = manifest.default_entry
	else
		io.stderr:write("error: no entrypoint specified\n")
		io.stderr:write("available entrypoints:\n")
		for key, def in pairs(entry_map) do
			local main = type(def) == "table" and def.main or tostring(def)
			io.stderr:write("  " .. key .. "  (" .. main .. ")\n")
		end
		io.stderr:write("\nusage: luajit lib/platform/cli.lua " .. opts.app .. " <entrypoint> [-- args...]\n")
		os.exit(1)
	end
end

local entry_def = entry_map[opts.entrypoint]
if not entry_def then
	io.stderr:write("error: unknown entrypoint '" .. opts.entrypoint .. "'\n")
	io.stderr:write("available entrypoints:\n")
	for key, def in pairs(entry_map) do
		local main = type(def) == "table" and def.main or tostring(def)
		io.stderr:write("  " .. key .. "  (" .. main .. ")\n")
	end
	os.exit(1)
end

local entry_path = type(entry_def) == "table" and entry_def.main or entry_def
if not entry_path then
	io.stderr:write("error: entrypoint '" .. opts.entrypoint .. "' has no 'main' field\n")
	os.exit(1)
end

-- Resolve app identity and data directory.
local app_id = manifest.name or opts.app:gsub("/$", ""):match("[^/]+$") or "app"
-- Sanitize app_id for filesystem use.
app_id = app_id:gsub("[^%w._-]", "_")
local data_dir = expand_home(opts.data_dir or "~/.crescent/data")
mkdir_p(data_dir)

-- Context for cap construction.
local context = {
	user_id = "default",
	app_id = app_id,
	data_dir = data_dir,
}

-- Merge cap declarations from manifest (top-level + per-entrypoint).
local cap_declarations = merge_cap_declarations(manifest, opts.entrypoint)

-- Apply --cap.NAME.KEY=VALUE overrides from CLI.
for cap_name, overrides in pairs(opts.cap_overrides) do
	if cap_declarations[cap_name] then
		for k, v in pairs(overrides) do
			cap_declarations[cap_name][k] = v
		end
	else
		io.stderr:write("warning: --cap." .. cap_name .. ".* does not match any declared cap\n")
	end
end

-- Resolve grants.
local grants
local has_saved_grants
if opts.reset_grants then
	grants = {}
	has_saved_grants = false
else
	local saved = load_grants(data_dir, app_id)
	has_saved_grants = saved ~= nil
	grants = saved or {}
end

-- Apply --grant and --deny flags.
for _, name in ipairs(opts.grant_caps) do
	if not cap_declarations[name] then
		io.stderr:write("warning: --grant=" .. name .. " does not match any declared cap\n")
	else
		grants[name] = true
	end
end
for _, name in ipairs(opts.deny_caps) do
	if cap_declarations[name] then
		grants[name] = false
	end
end

-- Check for caps with no grant decision yet.
local missing = {}
for name in pairs(cap_declarations) do
	if grants[name] == nil then
		missing[#missing + 1] = name
	end
end

if #missing > 0 then
	-- First run (no saved grants, no --grant flags): auto-grant all declared caps
	-- so the developer doesn't have to enumerate every cap manually.
	if not has_saved_grants and #opts.grant_caps == 0 then
		io.stderr:write("no grants on record for " .. app_id
			.. "; auto-granting all declared caps (first run)\n")
		for _, name in ipairs(missing) do
			grants[name] = true
		end
	else
		io.stderr:write("capabilities not yet granted or denied for " .. app_id .. ":\n")
		for _, name in ipairs(missing) do
			local decl = cap_declarations[name]
			local cap_type = decl.type or name
			local req = decl.required ~= false and "required" or "optional"
			io.stderr:write("  " .. name .. " (" .. cap_type .. ", " .. req .. ")\n")
		end
		io.stderr:write("\ngrant individually with --grant=NAME or deny with --deny=NAME\n")
		os.exit(1)
	end
end

-- Construct capabilities.
local platform_opts = {
	port = opts.port,
	app_args = opts.app_args,
}

local caps, revoke_fns_or_err = construct_caps(
	cap_declarations, grants, app, context, platform_opts
)
if not caps then
	io.stderr:write("error: " .. tostring(revoke_fns_or_err) .. "\n")
	os.exit(1)
end
local revoke_fns = revoke_fns_or_err

-- Persist grant decisions so future runs don't need --grant flags.
save_grants(data_dir, app_id, grants)

-- Run the entrypoint.
if app._dir_mode then
	-- Directory mode: require the module directly.
	local entry_mod, load_err = run_dir_entrypoint(app, entry_path, caps)
	if not entry_mod then
		io.stderr:write("error: " .. tostring(load_err) .. "\n")
		os.exit(1)
	end

	if entry_mod.create then
		-- Module exports create(caps, opts) -> app instance.
		-- Inject any LLM API key found in the environment so the app can use it
		-- without the operator having to pre-load it into the keyring.
		local app_opts = {}
		local env_api_key = resolve_llm_api_key_from_env()
		if env_api_key then app_opts.api_key = env_api_key end
		local result = entry_mod.create(caps, app_opts)
		if not result then
			io.stderr:write("error: create() returned nil\n")
			os.exit(1)
		end
		-- CLI mode: app_args after '--' → invoke CLI handler instead of HTTP server.
		if result.cli and opts.app_args and #opts.app_args > 0 then
			result.cli(opts.app_args)
			return
		end
		-- If the result has a handler and we have an http_server cap, serve it.
		if result.handler then
			-- Find any http_server cap (may be named "server" or anything else).
			-- LuaJIT (Lua 5.1) does not call __pairs, so iterate cap_declarations
			-- and index through the proxy to find caps with a .serve method.
			local serve_cap
			for name in pairs(cap_declarations) do
				local cap = caps[name]
				if type(cap) == "table" and cap.serve then
					serve_cap = cap
					break
				end
			end
			if serve_cap then
				local url = "http://localhost:" .. tostring(opts.port)
				io.write(url .. "\n")
				io.flush()
				-- This blocks until the server is stopped.
				serve_cap.serve(result.handler)
			else
				io.stderr:write("error: entrypoint returned a handler but no http_server cap is available\n")
				os.exit(1)
			end
		else
			-- Entrypoint returned but didn't produce an HTTP handler.
			-- This is fine for non-server entrypoints; for server entrypoints
			-- it likely means the app needs configuration.
			io.stderr:write("note: entrypoint returned without a handler (app may need configuration)\n")
		end
	elseif type(entry_mod) == "function" then
		-- Module is a plain function: call it with caps.
		entry_mod(caps)
	else
		io.stderr:write("error: entrypoint module has no create() function and is not callable\n")
		os.exit(1)
	end
else
	-- Archive mode: use platform.run_entry with sandbox.
	local sandbox = require("lib.sandbox")
	local cap_bundle = { globals = { caps = caps }, modules = {} }
	local env = sandbox.env(sandbox.stdlib, cap_bundle)
	local ok, result = platform.run_entry(app, opts.entrypoint, env)
	if not ok then
		io.stderr:write("error: " .. tostring(result) .. "\n")
		os.exit(1)
	end
end
