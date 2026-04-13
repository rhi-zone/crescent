-- lib/platform/caps/kv.lua
-- kv_cap(path, opts) -> capability table
-- Lightweight persistent key-value store backed by SQLite.
--
-- opts.allow: string[] of allowed key prefixes (nil = unrestricted)
--   Prefix match: if an entry ends with ".", it matches any key starting with it.
--   Otherwise the entry is an exact match.
--
-- Capability API (passed to sandbox as caps.kv):
--   cap.get(key)         -> string | nil
--   cap.set(key, value)  -- value: string sets; nil deletes

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local sqlite = require("lib.sqlite")

local M = {}

-- kv_cap(path, opts?) -> {get, set}
--: string -> { allow: string[]? }? -> { get: (string) -> string?, set: (string, string?) -> nil }
function M.kv_cap(path, opts)
	opts = opts or {}
	local allow = opts.allow  -- nil = unrestricted; string[] = allowlist

	--: string -> nil
	local function check_allow(key)
		if not allow then return end
		for i = 1, #allow do
			local entry = allow[i]
			-- prefix match: entry ends with "."
			if entry:sub(-1) == "." then
				if key:sub(1, #entry) == entry then return end
			else
				-- exact match
				if key == entry then return end
			end
		end
		error("kv: key '" .. key .. "' not allowed", 3)
	end

	-- Open (or create) the database and set up the schema.
	local db, derr = sqlite.open(path)
	if not db then
		error("kv: cannot open database at " .. path .. ": " .. tostring(derr), 2)
	end

	local ok, serr = db:execute(
		"CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT NOT NULL)"
	)
	if not ok then
		error("kv: schema init failed: " .. tostring(serr), 2)
	end

	-- Pre-compile statements for hot paths.
	local stmt_get = assert(db:prepare("SELECT value FROM kv WHERE key = ?"))
	local stmt_set = assert(db:prepare("INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)"))
	local stmt_del = assert(db:prepare("DELETE FROM kv WHERE key = ?"))

	return {
		-- get(key) -> string | nil
		get = function(key)
			check_allow(key)
			local iter = stmt_get:rows(key)
			local val, err2 = iter()
			-- err2 == "sqlite: done" means no rows; val == nil and err2 == that means not found
			if val == nil then return nil end
			return val
		end,

		-- set(key, value) -- value: string sets; nil deletes
		set = function(key, value)
			check_allow(key)
			if value == nil then
				local ok2, err2 = stmt_del:exec(key)
				if not ok2 then
					error("kv: delete failed: " .. tostring(err2), 2)
				end
			else
				local ok2, err2 = stmt_set:exec(key, value)
				if not ok2 then
					error("kv: set failed: " .. tostring(err2), 2)
				end
			end
		end,
	}
end

return M
