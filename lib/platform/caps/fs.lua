-- lib/platform/caps/fs.lua
-- fs_cap(opts) -> cap_table, revoke_fn
-- Scoped filesystem access. All paths are relative to opts.root.
-- Path traversal (../, absolute paths) is blocked at the cap level.
--
-- opts.root        : (required) base directory
-- opts.allow_write : boolean, default false
--
-- Capability API:
--   cap.read(path)           -> string | nil, err
--   cap.write(path, content) -> true  | nil, err   (only if allow_write)
--   cap.list(path?)          -> string[] | nil, err (filenames, not full paths)
--
-- NOTE: list() uses io.popen("ls") — Linux/macOS only. A proper readdir FFI
-- binding is tracked in TODO.md (lib/fs or lib/socket layer rewrite).

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- Resolve path relative to root; reject traversal and absolute paths.
--: (string, string | nil) -> (string | nil, string | nil)
local function resolve(root, path)
	if not path then return nil, "fs: nil path" end
	if path:find("^/") then return nil, "fs: absolute path not allowed" end
	-- Block any component that is ".." (with optional surrounding slashes)
	if path:find("^%.%.$") or path:find("^%.%./") or path:find("/%.%.$") or path:find("/%.%./") then
		return nil, "fs: path traversal not allowed"
	end
	return root .. "/" .. path
end

-- fs_cap(opts) -> cap_table, revoke_fn
function M.fs_cap(opts)
	opts = opts or {}
	local root = opts.root
	if not root then error("fs_cap: opts.root is required") end
	root = root:gsub("/$", "")  -- strip trailing slash
	local allow_write = opts.allow_write or false

	local revoked = false

	local cap = {
		_type = "fs",
		read = function(path)
			if revoked then return nil, "fs: capability revoked" end
			local full, err = resolve(root, path)
			if not full then return nil, err end
			local f, ferr = io.open(full, "rb")
			if not f then return nil, "fs: cannot read " .. tostring(path) .. ": " .. tostring(ferr) end
			local content = f:read("*a")
			f:close()
			return content
		end,

		write = function(path, content)
			if revoked then return nil, "fs: capability revoked" end
			if not allow_write then return nil, "fs: write not granted" end
			local full, err = resolve(root, path)
			if not full then return nil, err end
			local f, ferr = io.open(full, "wb")
			if not f then return nil, "fs: cannot write " .. tostring(path) .. ": " .. tostring(ferr) end
			f:write(content)
			f:close()
			return true
		end,

		-- list(path?) -> string[] of filenames in that directory
		list = function(path)
			if revoked then return nil, "fs: capability revoked" end
			local dir = path and path ~= "" and path or "."
			local full, err = resolve(root, dir)
			if not full then return nil, err end
			-- TODO: replace with native readdir FFI when lib/fs exists (Linux/macOS popen for now)
			local cmd = 'ls -1 "' .. full .. '" 2>/dev/null'
			local p, perr = io.popen(cmd)
			if not p then return nil, "fs: list failed: " .. tostring(perr) end
			local result = {}
			for line in p:lines() do result[#result + 1] = line end
			p:close()
			return result
		end,

		attenuate = function(sub_opts)
			if revoked then return nil, "fs: capability revoked" end
			sub_opts = sub_opts or {}
			local new_root = sub_opts.root
			if not new_root then return nil, "fs.attenuate: root required" end
			new_root = new_root:gsub("/$", "")
			-- new_root must be current root, or start with root .. "/"
			local cur_root = root --: string
			if new_root ~= cur_root and new_root:sub(1, #cur_root + 1) ~= cur_root .. "/" then
				return nil, "fs.attenuate: root escapes current scope"
			end
			-- allow_write can only go true→false, never false→true
			local new_allow_write
			if sub_opts.allow_write == nil then
				new_allow_write = allow_write
			elseif sub_opts.allow_write and not allow_write then
				return nil, "fs.attenuate: cannot grant write not held"
			else
				new_allow_write = sub_opts.allow_write
			end
			local fs_mod = --[[:! any]] require("lib.platform.caps.fs")
			return fs_mod.fs_cap({ root = new_root, allow_write = new_allow_write })
		end,
	}

	local function revoke() revoked = true end

	return cap, revoke
end

-- ── Risk classification ────────────────────────────────────────────────────

local path_util = require("lib.platform.path_util")

-- Build sensitive path table.
-- Each entry: { path, class, label }
-- Sorted longest-first so most-specific prefix wins.
local function build_sensitive(env)
	local HOME        = env("HOME")        or ""
	local XDG_CONFIG  = env("XDG_CONFIG_HOME")  or (HOME ~= "" and HOME .. "/.config" or "")
	local XDG_DATA    = env("XDG_DATA_HOME")    or (HOME ~= "" and HOME .. "/.local/share" or "")
	local USERPROFILE = env("USERPROFILE") or ""
	local LOCALAPPDATA = env("LOCALAPPDATA") or ""
	local APPDATA     = env("APPDATA")     or ""

	local function norm(p)
		if p == "" then return "" end
		return p:gsub("\\", "/")
	end

	local entries = {
		{ norm("/"),              "root_fs",        "the entire filesystem" },
		{ norm("/etc"),           "etc",            "system configuration (/etc)" },
		{ norm("/home"),          "all_user_homes", "all users' home directories (/home)" },
		{ norm("/tmp"),           "tmp_dir",        "temporary directory (/tmp)" },
		{ norm("/var/tmp"),       "tmp_dir",        "temporary directory (/var/tmp)" },
		{ norm("C:/Users"),       "all_user_homes", "all users' home directories (C:/Users)" },
		{ norm("C:/Windows"),     "windows_dir",    "Windows system directory" },
		{ norm("C:/Program Files"), "program_files","installed programs (Program Files)" },
	}

	if HOME ~= "" then
		entries[#entries+1] = { norm(HOME .. "/.ssh"),   "ssh_keys",         "SSH private keys (~/.ssh)" }
		entries[#entries+1] = { norm(HOME .. "/.gnupg"), "gpg_keys",         "GPG private keys (~/.gnupg)" }
		entries[#entries+1] = { norm(HOME .. "/.local"), "xdg_local_parent", "parent of XDG data/state dirs (~/.local)" }
		entries[#entries+1] = { norm(HOME),              "user_home",        "the user home directory (~)" }
	end
	if XDG_CONFIG ~= "" then
		entries[#entries+1] = { norm(XDG_CONFIG), "xdg_config", "application credentials/settings (" .. XDG_CONFIG .. ")" }
	end
	if XDG_DATA ~= "" then
		entries[#entries+1] = { norm(XDG_DATA), "xdg_data", "application data including browser profiles (" .. XDG_DATA .. ")" }
	end
	if USERPROFILE ~= "" then
		entries[#entries+1] = { norm(USERPROFILE .. "/AppData"), "appdata_parent", "parent of all AppData dirs" }
		entries[#entries+1] = { norm(USERPROFILE), "user_home", "Windows user profile" }
	end
	if LOCALAPPDATA ~= "" then
		entries[#entries+1] = { norm(LOCALAPPDATA), "localappdata", "LOCALAPPDATA (browser profiles, app state)" }
	end
	if APPDATA ~= "" then
		entries[#entries+1] = { norm(APPDATA), "roaming_appdata", "APPDATA (roaming application settings)" }
	end

	-- sort longest-first for most-specific prefix match
	table.sort(entries, function(a, b) return #a[1] > #b[1] end)
	return entries
end

-- SENSITIVE is built once at module load with real os.getenv
local SENSITIVE = build_sensitive(os.getenv)

local SEVERITY_TABLE = {
	root_fs          = { read = "critical", write = "critical" },
	all_user_homes   = { read = "high",     write = "critical" },
	windows_dir      = { read = "high",     write = "critical" },
	program_files    = { read = "medium",   write = "high"     },
	ssh_keys         = { read = "high",     write = "critical" },
	gpg_keys         = { read = "high",     write = "critical" },
	xdg_local_parent = { read = "high",     write = "critical" },
	user_home        = { read = "high",     write = "critical" },
	xdg_config       = { read = "high",     write = "critical" },
	xdg_data         = { read = "medium",   write = "high"     },
	appdata_parent   = { read = "high",     write = "critical" },
	localappdata     = { read = "high",     write = "critical" },
	roaming_appdata  = { read = "high",     write = "critical" },
	etc              = { read = "high",     write = "critical" },
	tmp_dir          = { read = "low",      write = "medium"   },
	specific         = { read = "medium",   write = "high"     },
}

-- _classify_root(path, env_fn) -> class, matched_label, ancestor_labels[]|nil
-- env_fn: function(name) -> string|nil  (pass os.getenv for production; stub for tests)
-- Returns:
--   class           — one of the keys in SEVERITY_TABLE, or "specific"
--   matched_label   — human label for the matched sensitive dir (nil if class=="specific")
--   ancestor_labels — list of label strings for sensitive dirs UNDER path (nil if none)
function M._classify_root(path, env_fn)
	local sensitive = env_fn == os.getenv and SENSITIVE or build_sensitive(env_fn)

	-- Expand tilde using env_fn so tests can stub HOME
	local function expand(p)
		if p:sub(1, 1) == "~" then
			local home = env_fn("HOME") or ""
			return home .. p:sub(2)
		end
		return p
	end

	local function norm(p)
		p = expand(p)
		p = p:gsub("\\", "/")
		-- Normalize root "/" specially: strip trailing slash only when path is not "/"
		if p ~= "/" then p = p:gsub("/$", "") end
		return p
	end

	local npath = norm(path)
	if npath == "" then
		return "specific", nil, nil
	end

	-- Check if npath is at or below a sensitive dir (longest match wins).
	-- "/" only matches on exact equality — it means "the root was granted as /".
	-- It does NOT act as a catch-all for every absolute path; that would make
	-- every path "root_fs" and eliminate the "specific" class.
	local matched_class, matched_label
	for _, entry in ipairs(sensitive) do
		local sdir, sclass, slabel = entry[1], entry[2], entry[3]
		if sdir ~= "" then
			if npath == sdir then
				matched_class = sclass
				matched_label = slabel
				break  -- exact match; sorted longest-first so most specific wins
			elseif sdir ~= "/" and npath:sub(1, #sdir + 1) == sdir .. "/" then
				matched_class = sclass
				matched_label = slabel
				break  -- prefix match; sorted longest-first so most specific wins
			end
		end
	end

	-- Check ancestor: collect all sensitive dirs that START with npath + "/"
	-- (i.e., the declared root is an ancestor of those dirs).
	-- Special case: if npath is "/" it is an ancestor of all absolute paths.
	local ancestor_labels = nil
	for _, entry in ipairs(sensitive) do
		local sdir, _, slabel = entry[1], entry[2], entry[3]
		if sdir ~= "" and sdir ~= "/" then
			local is_ancestor
			if npath == "/" then
				is_ancestor = sdir:sub(1, 1) == "/"
			else
				is_ancestor = sdir:sub(1, #npath + 1) == npath .. "/"
			end
			if is_ancestor then
				ancestor_labels = ancestor_labels or {}
				ancestor_labels[#ancestor_labels + 1] = slabel
			end
		end
	end

	local class = matched_class or "specific"
	return class, matched_label, ancestor_labels
end

function M.risk(decl)
	local raw_root = decl.root or ""
	local allow_write = decl.allow_write and true or false
	local read_or_write = allow_write and "Reads and writes" or "Reads"

	if raw_root == "" then
		if not allow_write then
			return { severity = "medium", text = "Reads files under a configured directory." }
		end
		return { severity = "high", text = "Reads and writes files under a configured directory. Can modify or delete anything in that directory tree." }
	end

	local class, matched_label, ancestor_labels = M._classify_root(raw_root, os.getenv)
	local sev_entry = SEVERITY_TABLE[class] or SEVERITY_TABLE.specific
	local severity = allow_write and sev_entry.write or sev_entry.read

	local label
	if class == "specific" then
		label = "files under " .. raw_root
	else
		label = matched_label or ("files under " .. raw_root)
	end

	local text
	if ancestor_labels and #ancestor_labels > 0 then
		text = read_or_write .. " " .. label .. " (encompasses " .. table.concat(ancestor_labels, ", ") .. ")."
	else
		text = read_or_write .. " " .. label .. "."
		if allow_write and class == "specific" then
			text = text .. " Can modify or delete anything in that directory tree."
		end
	end

	return { severity = severity, text = text }
end

return M
