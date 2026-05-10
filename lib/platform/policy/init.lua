-- lib/platform/policy/init.lua
-- Admin policy layer: hard cap ceilings for multi-user deployments.
--
-- Policy is loaded from a JSON file (default: nil → allow-all). The policy
-- can restrict cap types (deny them entirely) or narrow their parameters
-- (e.g. restrict http_client to a specific host allowlist, or cap kv storage).
--
-- Direction is always restrictive: admin policy can forbid or narrow caps.
-- It can never expand what a user can grant or auto-grant on a user's behalf.
--
-- API:
--   policy.load(path, opts)            -> pol | (nil, err)
--   pol:check_cap(cap_name)            -> "allowed" | "denied" | "restricted"
--   pol:check_cap_decl(cap_name, decl) -> true | (nil, string)
--   pol:reload()                       -> true | (nil, string)
--
-- opts:
--   read_fn: (path: string) -> string | nil   (default: io.open/read)
--
-- If path is nil or the file doesn't exist, an allow-all policy is returned.
-- A missing file is not an error — single-user deployments run without a policy
-- file by default.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local json = require("lib.format.json")

local M = {}

--:: policy_cap_entry = { state: string, hosts: { [integer]: string } | nil, max_size_mb: number | nil }
--:: policy_data = { cap_policy: { [string]: policy_cap_entry } | nil }
--:: policy = {
--::   check_cap: (policy, string) -> string,
--::   check_cap_decl: (policy, string, unknown) -> (boolean | nil, string | nil),
--::   reload: (policy) -> (boolean | nil, string | nil),
--::   _path: string | nil,
--::   _data: policy_data,
--::   _read_fn: (string) -> (string | nil),
--:: }

-- Default read_fn: reads the whole file via io.open. Returns content or nil.
--: (string) -> string | nil
local function default_read_fn(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local content = f:read("*a")
	f:close()
	return content
end

-- Parse raw JSON string into policy_data. Returns data table or nil on error.
--: (string) -> policy_data | nil
local function parse_policy(content)
	local ok, data = pcall(json.decode, content)
	if not ok or type(data) ~= "table" then return nil end
	return data --: policy_data
end

-- Build an allow-all policy_data (empty, no restrictions).
--: () -> policy_data
local function allow_all_data()
	return { cap_policy = {} }
end

local policy_mt = {}
policy_mt.__index = policy_mt

-- check_cap(cap_name) -> "allowed" | "denied" | "restricted"
-- Returns the state of a cap type according to admin policy.
-- If no cap_policy entry exists for the cap, it is "allowed".
--: (policy, string) -> string
function policy_mt:check_cap(cap_name)
	local cp = self._data.cap_policy
	if not cp then return "allowed" end
	local cp_ = cp --[[:! { [string]: policy_cap_entry }]]
	local entry = cp_[cap_name]
	if not entry then return "allowed" end
	local state = entry.state
	if state == "denied" then return "denied" end
	-- "allowed" with extra restrictions = "restricted"
	if state == "allowed" then
		if entry.hosts or entry.max_size_mb then
			return "restricted"
		end
		return "allowed"
	end
	-- Unknown state: treat as allowed (forward-compat).
	return "allowed"
end

-- check_cap_decl(cap_name, decl) -> true | (nil, string)
-- Checks a specific cap declaration against policy constraints.
-- decl is the manifest cap declaration table (or a non-table scalar).
--: (policy, string, unknown) -> (boolean | nil, string | nil)
function policy_mt:check_cap_decl(cap_name, decl)
	local cp = self._data.cap_policy
	if not cp then return true end
	local cp_ = cp --[[:! { [string]: policy_cap_entry }]]
	local entry = cp_[cap_name]
	if not entry then return true end

	-- Denied entirely.
	if entry.state == "denied" then
		return nil, "blocked by admin policy"
	end

	-- Not "allowed" (e.g. missing/unknown state) → pass through.
	if entry.state ~= "allowed" then
		return true
	end

	local decl_tbl = type(decl) == "table" and decl or nil

	-- http_client: host must be in the allowed hosts list (if restricted).
	if cap_name == "http_client" and entry.hosts then
		local host_val = decl_tbl and decl_tbl.host
		if host_val then
			local found = false
			local hosts = entry.hosts
			for i = 1, #hosts do
				if hosts[i] == host_val then
					found = true
					break
				end
			end
			if not found then
				return nil, "host not in admin policy allowlist"
			end
		end
	end

	-- kv / db: max_size_mb ceiling.
	if (cap_name == "kv" or cap_name == "db") and entry.max_size_mb then
		local decl_max = decl_tbl and decl_tbl.max_size_mb
		if decl_max and type(decl_max) == "number" then
			if decl_max > entry.max_size_mb then
				return nil, "exceeds admin policy storage limit"
			end
		end
	end

	return true
end

-- reload() -> true | (nil, string)
-- Re-reads the policy file from _path. If path is nil or file is missing,
-- resets to allow-all (same as initial load with no file).
--: (policy) -> (boolean | nil, string | nil)
function policy_mt:reload()
	if not self._path then
		self._data = allow_all_data() --[[:! policy_data]]
		return true
	end
	local path = self._path --[[:! string]]
	local content = self._read_fn(path)
	if not content then
		-- Missing file → allow-all (not an error).
		self._data = allow_all_data() --[[:! policy_data]]
		return true
	end
	local data = parse_policy(content)
	if not data then
		return nil, "policy: failed to parse JSON from " .. path
	end
	self._data = data --[[:! policy_data]]
	return true
end

-- load(path, opts) -> pol | (nil, err)
-- Load admin policy from a JSON file. Returns an allow-all policy if path is
-- nil or the file does not exist. Returns (nil, err) only on a parse failure
-- of an existing file.
--: (string | nil, { read_fn: ((string) -> (string | nil)) | nil } | nil) -> (policy | nil, string | nil)
function M.load(path, opts)
	local read_fn_raw = (opts and opts.read_fn) or default_read_fn
	local read_fn = read_fn_raw --[[:! (string) -> (string | nil)]]
	local data --: policy_data | nil

	if not path then
		data = allow_all_data()
	else
		local content = read_fn(path)
		if not content then
			-- File absent → allow-all (not an error).
			data = allow_all_data()
		else
			local parsed = parse_policy(content)
			if not parsed then
				return nil, "policy: failed to parse JSON from " .. path
			end
			data = parsed
		end
	end

	local pol = setmetatable({
		_path    = path,
		_data    = data,
		_read_fn = read_fn,
	}, policy_mt)
	return pol
end

return M
