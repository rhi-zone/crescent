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

-- Execute a pack source string and return the pack table, or nil, err.
--: (string, string) -> { [string]: unknown } | nil, string | nil
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
local function flatten_pack(pack, pack_name)
	local pack_t = pack --: any
	local name = tostring(pack_t.name or pack_name)
	local meta = {
		name        = name,
		description = tostring(pack_t.description or ""),
		version     = tostring(pack_t.version or "0.0.0"),
		author      = tostring(pack_t.author or ""),
	}
	local aliases = pack_t.aliases or {}
	local result  = {}
	for _, alias in ipairs(aliases) do
		local a = {}
		for k, v in pairs(alias) do a[k] = v end
		a.pack_name = name
		result[#result + 1] = a
	end
	return result, meta
end

-- load_builtin(self_cap) -> alias[], pack_meta[]
function M.load_builtin(self_cap)
	local cap = self_cap --: any
	local all_aliases = {}
	local all_meta    = {}

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
					local aliases, meta = flatten_pack(pack, pack_name)
					for _, a in ipairs(aliases) do all_aliases[#all_aliases + 1] = a end
					all_meta[#all_meta + 1] = meta
				end
			end
		end
	end

	return all_aliases, all_meta
end

-- load_user(fs_cap) -> alias[], pack_meta[]
function M.load_user(fs_cap)
	local all_aliases = {}
	local all_meta    = {}

	if not fs_cap then return all_aliases, all_meta end

	local cap = fs_cap --: any
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
					local aliases, meta = flatten_pack(pack, pack_name)
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
