-- lib/platform/apps/system_dashboard/packs.lua
-- Alias pack loader.
--
-- packs.load_builtin(self_cap) -> alias[], pack_meta[]
--   Loads packs/*.lua from tarball via self_cap.entry()
--
-- packs.load_user(fs_cap) -> alias[], pack_meta[]
--   Loads *.lua files from user packs dir via fs_cap.list() + fs_cap.read()
--   Returns {}, {} if fs_cap is nil
--
-- packs.merge(builtin_aliases, user_aliases) -> alias[]
--   User aliases override builtins by id. Returns merged list.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- Validate a single cap decl table.
-- Returns true on success, or nil, errmsg on failure.
--: (unknown, string) -> (true | nil, string | nil)
local function validate_cap_decl(decl, ctx)
	if type(decl) ~= "table" then
		return nil, ctx .. ": decl must be a table"
	end
	local decl_t = decl --: any
	if type(decl_t.type) ~= "string" then
		return nil, ctx .. ": decl.type must be a string"
	end
	return true
end

-- Validate pack-level caps table.
-- Returns true on success, or nil, errmsg on failure.
--: (unknown, string) -> (true | nil, string | nil)
local function validate_pack_caps(pack_caps, pack_name)
	if pack_caps == nil then return true end
	if type(pack_caps) ~= "table" then
		return nil, string.format("pack %s: caps must be a table", pack_name)
	end
	for name, decl in pairs(pack_caps) do
		local ctx = string.format("pack %s: cap %q", pack_name, tostring(name))
		local ok, err = validate_cap_decl(decl, ctx)
		if not ok then return nil, err end
	end
	return true
end

-- Resolve effective caps for an action by merging pack-level caps with
-- action-level caps. Action-level wins on name collision.
-- Returns the merged caps table (always a table, never nil).
--: (any, any) -> { [string]: any }
local function resolve_action_caps(action_caps, pack_caps)
	local out = {} --: { [string]: any }
	if type(pack_caps) == "table" then
		for k, v in pairs(pack_caps) do out[k] = --[[:! any]] v end
	end
	if type(action_caps) == "table" then
		for k, v in pairs(action_caps) do out[k] = --[[:! any]] v end
	end
	return out
end

-- Validate cap declarations and exec field on an action, after pack-level
-- caps have been merged in. Returns true on success, or nil, errmsg.
--: (unknown, { [string]: any }, string, integer) -> (true | nil, string | nil)
local function validate_action(action, effective_caps, alias_id, action_idx)
	local action_t = --[[:! any]] action
	-- An action may declare no caps inline; effective_caps may still be empty
	-- if the pack also declared none. In that case there's nothing to dispatch
	-- and the action is treated as a no-op container (matches prior behavior:
	-- no caps = nothing to validate).
	local has_any = false
	for name, decl in pairs(effective_caps) do
		has_any = true
		local ctx = string.format("alias %s action %d: cap %q",
			alias_id, action_idx, tostring(name))
		local ok, err = validate_cap_decl(decl, ctx)
		if not ok then return nil, err end
	end
	if not has_any then return true end
	if type(action_t.exec) ~= "table" then
		return nil, string.format(
			"alias %s action %d: caps present but exec is not a table",
			alias_id, action_idx)
	end
	local exec_t = action_t.exec --: any
	if type(exec_t.cap) ~= "string" then
		return nil, string.format(
			"alias %s action %d: exec.cap must be a string",
			alias_id, action_idx)
	end
	if not effective_caps[exec_t.cap] then
		return nil, string.format(
			"alias %s action %d: exec.cap %q references undeclared cap (not in action.caps or pack.caps)",
			alias_id, action_idx, tostring(exec_t.cap))
	end
	return true
end

-- Execute a pack source string and return the pack table, or nil, err.
--: (string, string) -> ({ [string]: unknown } | nil, string | nil)
local function exec_pack(src, chunkname)
	local fn, err = load(src, chunkname, "t")
	if not fn then return nil, "packs: load error in " .. chunkname .. ": " .. tostring(err) end
	local ok, result = pcall(fn)
	if not ok then return nil, "packs: runtime error in " .. chunkname .. ": " .. tostring(result) end
	if type(result) ~= "table" then
		return nil, "packs: " .. chunkname .. " did not return a table"
	end
	return result
end

-- Flatten a pack table into (aliases[], pack_meta).
-- Each alias gets .pack_name set to the pack's name field.
-- warn_fn(msg), if provided, is called for each skipped invalid action.
local function flatten_pack(pack, pack_name, warn_fn)
	local pack_t = pack --: any
	local name = tostring(pack_t.name or pack_name)
	local meta = {
		name        = name,
		description = tostring(pack_t.description or ""),
		version     = tostring(pack_t.version or "0.0.0"),
		author      = tostring(pack_t.author or ""),
	}
	-- Validate pack-level caps shorthand. If invalid, skip the entire pack —
	-- the actions referencing it would all be broken.
	local pack_caps = pack_t.caps
	local pack_ok, pack_err = validate_pack_caps(pack_caps, name)
	if not pack_ok then
		if warn_fn then
			warn_fn("system_dashboard: skipping pack " .. name
				.. ": " .. tostring(pack_err) .. "\n")
		end
		return {}, meta
	end
	local aliases = pack_t.aliases or {}
	local result  = {}
	for idx, alias in ipairs(aliases) do
		local alias_t = alias --: any
		local alias_id = tostring(alias_t.id or idx)
		-- Resolve and validate each action: merge pack-level caps with
		-- action-level caps (action wins), then validate. Mutate the action
		-- in place so server.lua sees the resolved caps directly.
		local actions = alias_t.actions
		local valid = true
		if type(actions) == "table" then
			for action_idx, action in ipairs(actions) do
				local action_t = action --: any
				local effective = resolve_action_caps(action_t.caps, pack_caps)
				local ok, err = validate_action(action, effective, alias_id, action_idx)
				if not ok then
					if warn_fn then
						warn_fn("system_dashboard: skipping alias " .. alias_id
							.. " in pack " .. name .. ": " .. tostring(err) .. "\n")
					end
					valid = false
					break
				end
				-- Stash resolved caps onto the action; server.lua reads .caps.
				action_t.caps = effective
			end
		end
		if valid then
			local a = {}
			for k, v in pairs(alias) do a[k] = v end
			a.pack_name = name
			result[#result + 1] = a
		end
	end
	return result, meta
end

-- load_builtin(self_cap, stdout_cap) -> alias[], pack_meta[]
function M.load_builtin(self_cap, stdout_cap)
	local cap = self_cap --: any
	local all_aliases = {}
	local all_meta    = {}

	local stdout_t = stdout_cap --: any
	local warn_fn = stdout_t and function(msg) stdout_t.write(msg) end or nil

	local entries = cap.entries()
	if not entries then return all_aliases, all_meta end

	for _, entry in ipairs(entries) do
		local entry_s = tostring(entry)
		if entry_s:match("^packs/[^/]+%.lua$") then
			local src = cap.entry(entry_s)
			if src then
				local pack_name = entry_s:match("^packs/(.-)%.lua$") or entry_s
				local pack = exec_pack(tostring(src), "@" .. entry_s)
				if pack then
					local aliases, meta = flatten_pack(pack, pack_name, warn_fn)
					for _, a in ipairs(aliases) do all_aliases[#all_aliases + 1] = a end
					all_meta[#all_meta + 1] = meta
				end
			end
		end
	end

	return all_aliases, all_meta
end

-- load_user(fs_cap, stdout_cap) -> alias[], pack_meta[]
function M.load_user(fs_cap, stdout_cap)
	local all_aliases = {}
	local all_meta    = {}

	if not fs_cap then return all_aliases, all_meta end

	local cap = fs_cap --: any
	local stdout_t = stdout_cap --: any
	local warn_fn = stdout_t and function(msg) stdout_t.write(msg) end or nil
	local files = cap.list()
	if not files then return all_aliases, all_meta end

	for _, fname in ipairs(files) do
		local fname_s = tostring(fname)
		if fname_s:match("%.lua$") then
			local src = cap.read(fname_s)
			if src then
				local pack_name = fname_s:match("^(.-)%.lua$") or fname_s
				local pack = exec_pack(tostring(src), "@user:" .. fname_s)
				if pack then
					local aliases, meta = flatten_pack(pack, pack_name, warn_fn)
					for _, a in ipairs(aliases) do all_aliases[#all_aliases + 1] = a end
					all_meta[#all_meta + 1] = meta
				end
			end
		end
	end

	return all_aliases, all_meta
end

-- merge(builtin_aliases, user_aliases) -> alias[]
-- User aliases with the same id override builtins.
function M.merge(builtin_aliases, user_aliases)
	local by_id  = {} --: { [string]: unknown }
	local order  = {}
	local anon_by_idx = {}

	for _, a in ipairs(builtin_aliases) do
		local a_t = a --: any
		local id = a_t.id
		if id then
			local id_s = tostring(id)
			if not by_id[id_s] then order[#order + 1] = id_s end
			by_id[id_s] = a
		else
			anon_by_idx[#anon_by_idx + 1] = a
		end
	end

	for _, a in ipairs(user_aliases) do
		local a_t = a --: any
		local id = a_t.id
		if id then
			local id_s = tostring(id)
			if not by_id[id_s] then order[#order + 1] = id_s end
			by_id[id_s] = a
		else
			anon_by_idx[#anon_by_idx + 1] = a
		end
	end

	local result = {}
	local seen   = {} --: { [string]: boolean }
	for _, key in ipairs(order) do
		if not seen[key] then
			seen[key] = true
			result[#result + 1] = by_id[key]
		end
	end
	for _, a in ipairs(anon_by_idx) do
		result[#result + 1] = a
	end
	return result
end

return M
