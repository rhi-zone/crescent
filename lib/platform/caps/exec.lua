-- lib/platform/caps/exec.lua
-- Subprocess capability wrapping lib/exec with a manifest-declared binary
-- whitelist and optional per-binary subcommand grant restrictions.
--
-- manifest_entry fields:
--   binaries : { [string]: { schema: "auto" | HelpSchema | nil, allow: string[] | nil } }
--   stderr   : string | nil  ("merge" | "discard" | nil)
--
-- Construction:
--   M.new(manifest_entry) -> cap, revoke_fn
--
-- Cap invocation — two forms:
--   1. Fluent (typed):  cap[binary_name].subcommand(pos, {flags})
--   2. Raw (escape):    cap.exec(binary_name, args)
--
-- ExecArgsTable = { [1]: string[] (subcommand path), [string]: flag value }
-- allow list (per binary): prefix match on first subcommand name in args.
-- allow = nil => all subcommands allowed.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local help     = require("lib.exec.help")
local make_api = require("lib.exec.make_api")
local exec     = require("lib.exec")

local M = {}

-- Build a lookup set from an allow list.
-- Returns nil if allow is nil (meaning unrestricted).
--: (string[] | nil) -> { [string]: boolean } | nil
local function build_allow_set(allow)
	if allow == nil then return nil end
	local set = {}
	for i = 1, #allow do
		set[allow[i]] = true
	end
	return set
end

-- Expand an ExecArgsTable (args[1] is a string[] subcommand path;
-- remaining string keys are flag fields) into a flat CLI arg list,
-- optionally validated against a HelpSchema.
-- Returns expanded args or nil + errmsg.
--: (any, any | nil) -> string[] | nil, string | nil
local function expand_args_table(args_tbl, schema)
	--: any
	local path = args_tbl[1]
	local result = {}

	-- Add subcommand path elements.
	if type(path) == "table" then
		for i = 1, #path do
			result[#result + 1] = tostring(path[i])
		end
	end

	-- Collect string flag keys (all string keys other than positional [1]).
	local flag_keys = {}
	for k, _ in pairs(args_tbl) do
		if type(k) == "string" then
			flag_keys[#flag_keys + 1] = k
		end
	end

	if #flag_keys == 0 then
		return result
	end

	-- Walk the schema to the subcommand node matching the path.
	--: any | nil
	local node = schema
	if node ~= nil and type(path) == "table" then
		for i = 1, #path do
			if node ~= nil and type(node) == "table" and
			   type(node.subcommands) == "table" then
				--: any
				local subs = node.subcommands
				node = subs[path[i]]
			else
				node = nil
				break
			end
		end
	end

	if node ~= nil and type(node) == "table" and
	   type(node.flag_idents) == "table" and
	   type(node.flags) == "table" then
		-- Schema-validated flag expansion (mirrors make_api.expand_flags logic).
		--: any
		local flag_idents = node.flag_idents
		--: any
		local flags_list  = node.flags
		for _, key in ipairs(flag_keys) do
			local val = args_tbl[key]
			local idx = flag_idents[key]
			if not idx then
				return nil, "unknown flag: " .. key
			end
			local flag = flags_list[idx]
			local is_boolean_pair = flag.arg == "boolean"
			--: string | nil
			local flong  = flag.long
			--: string | nil
			local fshort = flag.short
			--: string
			local token
			if flong then
				token = flong
			elseif fshort then
				token = fshort
			else
				token = "--" .. key
			end

			if val == true then
				result[#result + 1] = token
			elseif val == false then
				if is_boolean_pair and flong then
					local bare = flong:match("^%-%-(.+)$") or flong
					result[#result + 1] = "--no-" .. bare
				end
				-- simple false => omit
			elseif val ~= nil then
				result[#result + 1] = token
				result[#result + 1] = tostring(val)
			end
		end
	else
		-- No schema: naive --key [value] passthrough.
		for _, key in ipairs(flag_keys) do
			local val = args_tbl[key]
			if val == true then
				result[#result + 1] = "--" .. key
			elseif val ~= nil and val ~= false then
				result[#result + 1] = "--" .. key
				result[#result + 1] = tostring(val)
			end
		end
	end

	return result
end

-- Detect whether args is an ExecArgsTable (args[1] is a table).
--: (any) -> boolean
local function is_args_table(args)
	return type(args[1]) == "table"
end

--:: ExecManifestEntry = {
--::   binaries: { [string]: { schema: "auto" | unknown | nil, allow: string[] | nil } },
--::   stderr: string | nil,
--:: }

-- M.new(manifest_entry) -> cap, revoke_fn
--: (ExecManifestEntry) -> any, () -> nil
function M.new(manifest_entry)
	--: any
	local entry = manifest_entry or {}
	--: any
	local binaries_spec = entry.binaries or {}
	local stderr = entry.stderr

	local revoked = false

	-- Per-binary caches built at construction time.
	local schemas    = {}   -- [name] = HelpSchema | nil
	local allow_sets = {}   -- [name] = { [string]: boolean } | nil

	for name, spec in pairs(binaries_spec) do
		--: string
		local sname = tostring(name)
		--: any
		local s = spec
		allow_sets[sname] = build_allow_set(s.allow)

		--: any
		local schema_val = s.schema
		if schema_val == "auto" then
			--: any
			local fetch_opts = { popen = io.popen, max_depth = 4 }
			local fetched, _ = help.fetch(sname, fetch_opts)
			schemas[sname] = fetched  -- nil if binary absent; raw mode fallback
		elseif type(schema_val) == "table" then
			schemas[sname] = schema_val
		else
			schemas[sname] = nil
		end
	end

	-- Build the revoke-checked popen wrapper used for fluent API nodes.
	-- Every fluent call goes through exec.run(... popen = checked_popen ...).
	local function checked_popen(cmd_str, mode)
		if revoked then
			-- Return a fake file handle that immediately errors.
			-- exec.run checks fh:read() — we need something that won't panic.
			-- Simplest: return nil + errmsg from popen itself so exec.run
			-- propagates "popen: capability revoked".
			return nil, "capability revoked"
		end
		return io.popen(cmd_str, mode)
	end

	-- Build fluent API nodes using the revoke-checked popen.
	local apis = {}
	for name, schema in pairs(schemas) do
		--: string
		local sname = tostring(name)
		--: any
		local s = schema
		if s ~= nil then
			local api, _ = make_api.make(s, sname, {
				popen  = checked_popen,
				stderr = stderr,
			})
			apis[sname] = api
		end
	end

	-- cap.exec: raw call form.
	-- Validates binary whitelist and allow list, then calls exec.run.
	local function raw_call(binary_name, args)
		if revoked then return nil, "capability revoked" end

		if type(binary_name) ~= "string" then
			return nil, "binary name must be a string"
		end

		if binaries_spec[binary_name] == nil then
			return nil, "binary not in whitelist: " .. binary_name
		end

		-- Normalise args to a flat string list.
		local flat_args
		if args == nil or
		   (type(args) == "table" and next(args) == nil) then
			flat_args = {}
		elseif type(args) == "table" and is_args_table(args) then
			local expanded, err = expand_args_table(args, schemas[binary_name])
			if not expanded then return nil, err end
			flat_args = expanded
		else
			-- Plain list.
			flat_args = args
		end

		-- Subcommand allow-list check.
		local allow_set = allow_sets[binary_name]
		if allow_set ~= nil then
			local subcommand = flat_args[1]
			if subcommand == nil or not allow_set[subcommand] then
				return nil, "subcommand not allowed: " .. tostring(subcommand)
			end
		end

		return exec.run(binary_name, flat_args, { popen = io.popen, stderr = stderr })
	end

	-- Assemble the cap table.
	-- cap.exec   = raw call function
	-- cap[name]  = fluent API node for each binary with a schema
	local cap = { exec = raw_call }
	for name, api in pairs(apis) do
		cap[name] = api
	end

	local function revoke()
		revoked = true
	end

	return cap, revoke
end

return M
