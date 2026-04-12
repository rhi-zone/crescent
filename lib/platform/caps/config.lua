-- lib/platform/caps/config.lua
-- config_cap(opts?) -> capability table
-- Exposes user-level configuration as reactive signals. Reads from a config
-- directory (default ~/.crescent/). Changes are reflected via cap.set() and
-- cap.reload(). No filesystem watching — signals update on explicit mutation.
--
-- opts.dir : string (default "~/.crescent")
--
-- Capability API (passed to sandbox as caps.config):
--   cap.theme        : Signal<string>      — from config/theme.txt
--   cap.ui           : Signal<table>       — from config/ui.json
--   cap.presets      : Signal<table[]>     — from config/presets.json
--   cap.lorebooks    : Signal<table[]>     — from config/lorebooks.json
--   cap.get(key)     : Signal<string|nil>  — arbitrary key from config/<key>.json or .txt
--   cap.set(key, val): nil                 — write config/<key>.json (or .txt for strings)
--   cap.reload(key)  : nil                 — re-read config/<key> from disk

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local reactive = require("lib.reactive")
local json     = require("lib.json")

local M = {}

-- Expand ~ in a path to the user's home directory.
--: (string) -> string
local function expand_home(path)
	if path:sub(1, 1) == "~" then
		local home = os.getenv("HOME") or ""
		return home .. path:sub(2)
	end
	return path
end

-- Ensure a directory exists (creates it if missing).
-- Returns true on success, nil + errmsg on failure.
--: (string) -> true | nil, string
local function mkdir_p(dir)
	local ok = os.execute('mkdir -p "' .. dir .. '" 2>/dev/null')
	if ok == 0 or ok == true then return true end
	return nil, "config: could not create directory: " .. dir
end

-- Read a file, returning its contents as a string.
-- Returns nil + errmsg if missing or unreadable.
--: (string) -> string | nil, string
local function read_file(path)
	local f, err = io.open(path, "rb")
	if not f then return nil, err end
	local content = f:read("*a")
	f:close()
	return content
end

-- Write a string to a file, creating parent dir as needed.
-- Returns true on success, nil + errmsg on failure.
--: (string, string) -> true | nil, string
local function write_file(path, content)
	local f, err = io.open(path, "wb")
	if not f then return nil, "config: cannot write " .. path .. ": " .. tostring(err) end
	f:write(content)
	f:close()
	return true
end

-- Determine the file path for a given key (prefers .json, falls back to .txt).
-- When the key is known to be a string value, .txt is used.
--: (string, string) -> string, boolean
local function key_path(config_dir, key)
	local json_path = config_dir .. "/" .. key .. ".json"
	local txt_path  = config_dir .. "/" .. key .. ".txt"
	-- Check whether json file exists
	local f = io.open(json_path, "rb")
	if f then
		f:close()
		return json_path, true
	end
	return txt_path, false
end

-- Load a value for a key from disk. Returns the decoded value and whether it
-- was JSON. Missing files return sensible defaults.
--: (string, string) -> unknown, boolean
local function load_key(config_dir, key)
	local json_path = config_dir .. "/" .. key .. ".json"
	local txt_path  = config_dir .. "/" .. key .. ".txt"

	-- Try JSON first
	local f = io.open(json_path, "rb")
	if f then
		local content = f:read("*a")
		f:close()
		if content and #content > 0 then
			local val, err = json.decode(content)
			if val ~= nil then return val, true end
			-- Decode failed — return nil with error surfaced through signal default
			return nil, true
		end
		-- Empty JSON file: return empty table as default
		return {}, true
	end

	-- Try .txt
	local g = io.open(txt_path, "rb")
	if g then
		local content = g:read("*a")
		g:close()
		-- Strip trailing newline if present (common in text files)
		content = content:gsub("\n$", "")
		return content, false
	end

	-- Missing file: return default by key convention
	local json_keys = { ui = true, presets = true, lorebooks = true }
	if json_keys[key] then return {}, true end
	if key == "theme" then return "", false end
	return nil, false
end

-- config_cap(opts?) -> cap table
function M.config_cap(opts)
	opts = opts or {}
	local dir = expand_home(opts.dir or "~/.crescent")
	local config_dir = dir .. "/config"

	-- Cache of signals by key name — created lazily on first access.
	local _signals = {}

	-- Get or create the signal for a key.
	--: (string) -> Signal
	local function get_signal(key)
		if _signals[key] then return _signals[key] end
		local val = load_key(config_dir, key)
		local s = reactive.signal(val)
		_signals[key] = s
		return s
	end

	local cap = {}

	-- cap.get(key) -> Signal<unknown>
	-- Returns a signal for an arbitrary config key.
	function cap.get(key)
		return get_signal(key)
	end

	-- cap.set(key, val) -> true | nil, errmsg
	-- Write to disk and update the signal. Strings go to .txt, others to .json.
	function cap.set(key, val)
		-- Ensure config dir exists
		local ok, err = mkdir_p(config_dir)
		if not ok then return nil, err end

		local path, content
		if type(val) == "string" then
			path = config_dir .. "/" .. key .. ".txt"
			content = val
		else
			path = config_dir .. "/" .. key .. ".json"
			local encoded, eerr = json.encode(val)
			if not encoded then return nil, "config: JSON encode failed: " .. tostring(eerr) end
			content = encoded
		end

		local wrote, werr = write_file(path, content)
		if not wrote then return nil, werr end

		-- Update signal in-place (create if first access)
		local s = get_signal(key)
		s.set(val)
		return true
	end

	-- cap.reload(key) -> true | nil, errmsg
	-- Re-read the key from disk and update the signal.
	function cap.reload(key)
		local val = load_key(config_dir, key)
		local s = get_signal(key)
		s.set(val)
		return true
	end

	-- Lazy property access for well-known keys.
	-- cap.theme, cap.ui, cap.presets, cap.lorebooks are signals accessed directly.
	local _mt = {
		__index = function(t, k)
			local known = { theme = true, ui = true, presets = true, lorebooks = true }
			if known[k] then
				local s = get_signal(k)
				rawset(t, k, s)
				return s
			end
		end,
	}
	setmetatable(cap, _mt)

	return cap
end

return M
