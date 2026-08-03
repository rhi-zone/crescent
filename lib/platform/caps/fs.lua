-- lib/platform/caps/fs.lua
-- fs_cap(opts) -> cap_table, revoke_fn
-- Scoped filesystem access. All paths are relative to opts.root.
-- Path traversal (../, absolute paths) is blocked at the cap level.
--
-- opts.root                  : (required) base directory
-- opts.allow_read            : boolean, default true
-- opts.allow_write           : boolean, default false
-- opts.allow_list            : boolean, default true
-- opts.allow_list_recursive  : boolean, default true
-- opts.allow_stat            : boolean, default true
-- opts.allow_mkdir           : boolean, default false
-- opts.allow_delete          : boolean, default false
-- opts.allow_rename          : boolean, default false
--
-- Read-side operations (read/list/list_recursive/stat) default open, same as
-- before this cap had any permission surface for them — this preserves every
-- existing caller's behavior. Mutating operations (write/mkdir/delete/rename)
-- default closed, same as write always has. attenuate() can narrow any of the
-- eight flags independently; it can never grant one the parent cap lacks.
--
-- Capability API:
--   cap.read(path)              -> string | nil, err
--   cap.write(path, content)    -> true  | nil, err   (only if allow_write)
--   cap.list(path?)             -> string[] | nil, err (filenames, not full paths)
--   cap.list_recursive(path?)   -> string[] | nil, err (paths relative to `path`,
--                                  "/"-separated, both files and directories)
--   cap.stat(path)              -> { size: number, mtime: number, type: "file" | "directory" } | nil, err
--   cap.mkdir(path)             -> true | nil, err     (only if allow_mkdir)
--   cap.delete(path, opts?)     -> true | nil, err     (only if allow_delete;
--                                  opts.recursive = true required to remove a
--                                  non-empty directory)
--   cap.rename(from, to)        -> true | nil, err     (only if allow_rename;
--                                  both paths scoped to root)

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

local dir_list = require("lib.fs.dir_list")
local fs_ops   = require("lib.fs.ops")

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

-- Narrow-only boolean attenuation: nil inherits the parent's value, false
-- always narrows, true is only allowed if the parent already holds it.
--: (boolean, boolean | nil, string) -> (boolean | nil, string | nil)
local function narrow_bool(parent_value, requested, field_name)
	if requested == nil then return parent_value end
	if requested and not parent_value then
		return nil, "fs.attenuate: cannot grant " .. field_name .. " not held"
	end
	return requested and true or false
end

--: (boolean | nil) -> boolean
local function default_true(v)
	if v == nil then return true end
	return v and true or false
end

-- fs_cap(opts) -> cap_table, revoke_fn
function M.fs_cap(opts)
	opts = opts or {}
	local root = opts.root
	if not root then error("fs_cap: opts.root is required") end
	root = root:gsub("/$", "")  -- strip trailing slash

	local allow_read           = default_true(opts.allow_read)
	local allow_write          = opts.allow_write and true or false
	local allow_list           = default_true(opts.allow_list)
	local allow_list_recursive = default_true(opts.allow_list_recursive)
	local allow_stat           = default_true(opts.allow_stat)
	local allow_mkdir          = opts.allow_mkdir and true or false
	local allow_delete         = opts.allow_delete and true or false
	local allow_rename         = opts.allow_rename and true or false

	local revoked = false

	local cap = {
		_type = "fs",
		read = function(path)
			if revoked then return nil, "fs: capability revoked" end
			if not allow_read then return nil, "fs: read not granted" end
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
			if not allow_list then return nil, "fs: list not granted" end
			local dir = path and path ~= "" and path or "."
			local full, err = resolve(root, dir)
			if not full then return nil, err end
			local iter, state = dir_list.dir_list(full)
			if not iter then return nil, "fs: list failed: " .. tostring(state) end
			local result = {}
			for entry in iter, state do
				result[#result + 1] = entry.name
			end
			return result
		end,

		-- list_recursive(path?) -> string[] of paths relative to `path`,
		-- "/"-separated, covering both files and directories at every depth.
		list_recursive = function(path)
			if revoked then return nil, "fs: capability revoked" end
			if not allow_list_recursive then return nil, "fs: list_recursive not granted" end
			local dir = path and path ~= "" and path or "."
			local full, err = resolve(root, dir)
			if not full then return nil, err end

			local results = {}
			--: (string, string) -> (true | nil, string | nil)
			local function walk(rel_dir, full_dir)
				local iter, state = dir_list.dir_list(full_dir)
				if not iter then return nil, "fs: list_recursive failed: " .. tostring(state) end
				for entry in iter, state do
					local rel = rel_dir == "" and entry.name or (rel_dir .. "/" .. entry.name)
					results[#results + 1] = rel
					if entry.is_dir then
						local ok, werr = walk(rel, full_dir .. "/" .. entry.name)
						if not ok then return nil, werr end
					end
				end
				return true
			end

			local ok, werr = walk("", full)
			if not ok then return nil, werr end
			return results
		end,

		-- stat(path) -> { size, mtime, type } for a file or directory.
		-- Only fields reliably populatable on every supported tier are
		-- included: creation time (birthtime) is omitted because statx's
		-- STATX_BTIME is unsupported on many Linux filesystems and would
		-- silently read as zero rather than "unknown".
		stat = function(path)
			if revoked then return nil, "fs: capability revoked" end
			if not allow_stat then return nil, "fs: stat not granted" end
			local full, err = resolve(root, path)
			if not full then return nil, err end
			local info, serr = dir_list.stat(full)
			if not info then return nil, "fs: cannot stat " .. tostring(path) .. ": " .. tostring(serr) end
			return {
				size  = info.size,
				mtime = info.modified,
				type  = info.is_dir and "directory" or "file",
			}
		end,

		mkdir = function(path)
			if revoked then return nil, "fs: capability revoked" end
			if not allow_mkdir then return nil, "fs: mkdir not granted" end
			local full, err = resolve(root, path)
			if not full then return nil, err end
			return fs_ops.mkdir(full)
		end,

		-- delete(path, opts?) -> true | nil, err
		-- Files and empty directories are removed outright. A non-empty
		-- directory is refused unless opts.recursive == true, since that's
		-- the only irreversible bulk-destructive path this cap exposes.
		-- allow_delete gates delete() at all; opts.recursive is a per-call
		-- confirmation on top of that grant, not a separate capability —
		-- the operator already consented to deletion by granting allow_delete,
		-- recursive=true just guards against deleting a tree by accident.
		delete = function(path, del_opts)
			if revoked then return nil, "fs: capability revoked" end
			if not allow_delete then return nil, "fs: delete not granted" end
			local full, err = resolve(root, path)
			if not full then return nil, err end
			local info, serr = dir_list.stat(full)
			if not info then return nil, "fs: cannot delete " .. tostring(path) .. ": " .. tostring(serr) end

			if not info.is_dir then
				return fs_ops.unlink(full)
			end

			local recursive = del_opts and del_opts.recursive or false
			if not recursive then
				local ok, derr = fs_ops.rmdir(full)
				if ok then return true end
				if derr and tostring(derr):find("not empty", 1, true) then
					return nil, "fs: " .. tostring(path) ..
						" is a non-empty directory (pass { recursive = true } to delete its contents)"
				end
				return nil, derr
			end

			--: (string) -> (true | nil, string | nil)
			local function walk_delete(full_dir)
				local iter, state = dir_list.dir_list(full_dir)
				if not iter then return nil, "fs: list failed during recursive delete: " .. tostring(state) end
				for entry in iter, state do
					local child_full = full_dir .. "/" .. entry.name
					local ok, werr
					if entry.is_dir then
						ok, werr = walk_delete(child_full)
					else
						ok, werr = fs_ops.unlink(child_full)
					end
					if not ok then return nil, werr end
				end
				return fs_ops.rmdir(full_dir)
			end
			return walk_delete(full)
		end,

		-- rename(path_from, path_to) -> true | nil, err
		-- Both endpoints must resolve within root; covers move within the
		-- same root (a cross-root move is a read+write+delete by the caller).
		rename = function(path_from, path_to)
			if revoked then return nil, "fs: capability revoked" end
			if not allow_rename then return nil, "fs: rename not granted" end
			local full_from, ferr = resolve(root, path_from)
			if not full_from then return nil, ferr end
			local full_to, terr = resolve(root, path_to)
			if not full_to then return nil, terr end
			local ok, rerr = os.rename(full_from, full_to)
			if not ok then
				return nil, "fs: cannot rename " .. tostring(path_from) .. " to " .. tostring(path_to) ..
					": " .. tostring(rerr)
			end
			return true
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

			local new_allow_read, read_err = narrow_bool(allow_read, sub_opts.allow_read, "read")
			if read_err then return nil, read_err end
			local new_allow_write, write_err = narrow_bool(allow_write, sub_opts.allow_write, "write")
			if write_err then return nil, write_err end
			local new_allow_list, list_err = narrow_bool(allow_list, sub_opts.allow_list, "list")
			if list_err then return nil, list_err end
			local new_allow_list_recursive, list_recursive_err =
				narrow_bool(allow_list_recursive, sub_opts.allow_list_recursive, "list_recursive")
			if list_recursive_err then return nil, list_recursive_err end
			local new_allow_stat, stat_err = narrow_bool(allow_stat, sub_opts.allow_stat, "stat")
			if stat_err then return nil, stat_err end
			local new_allow_mkdir, mkdir_err = narrow_bool(allow_mkdir, sub_opts.allow_mkdir, "mkdir")
			if mkdir_err then return nil, mkdir_err end
			local new_allow_delete, delete_err = narrow_bool(allow_delete, sub_opts.allow_delete, "delete")
			if delete_err then return nil, delete_err end
			local new_allow_rename, rename_err = narrow_bool(allow_rename, sub_opts.allow_rename, "rename")
			if rename_err then return nil, rename_err end

			return M.fs_cap({
				root                 = new_root,
				allow_read           = new_allow_read,
				allow_write          = new_allow_write,
				allow_list           = new_allow_list,
				allow_list_recursive = new_allow_list_recursive,
				allow_stat           = new_allow_stat,
				allow_mkdir          = new_allow_mkdir,
				allow_delete         = new_allow_delete,
				allow_rename         = new_allow_rename,
			})
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

	--: (string) -> string
	local function norm(p)
		if p == "" then return "" end
		local s, _ = p:gsub("\\", "/")
		return s
	end

	local entries = {} --: { [integer]: { [integer]: string }, ... }
	entries[#entries+1] = { norm("/"),              "root_fs",        "the entire filesystem" }
	entries[#entries+1] = { norm("/etc"),           "etc",            "system configuration (/etc)" }
	entries[#entries+1] = { norm("/home"),          "all_user_homes", "all users' home directories (/home)" }
	entries[#entries+1] = { norm("/tmp"),           "tmp_dir",        "temporary directory (/tmp)" }
	entries[#entries+1] = { norm("/var/tmp"),       "tmp_dir",        "temporary directory (/var/tmp)" }
	entries[#entries+1] = { norm("C:/Users"),       "all_user_homes", "all users' home directories (C:/Users)" }
	entries[#entries+1] = { norm("C:/Windows"),     "windows_dir",    "Windows system directory" }
	entries[#entries+1] = { norm("C:/Program Files"), "program_files","installed programs (Program Files)" }
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
--: (string, (string) -> string | nil) -> (string, string | nil, { [integer]: string, ... } | nil)
function M._classify_root(path, env_fn)
	local sensitive = env_fn == os.getenv and SENSITIVE or build_sensitive(env_fn)

	-- Expand tilde using env_fn so tests can stub HOME
	--: (string) -> string
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

--: ({ root: string | nil, allow_write: boolean | nil, allow_mkdir: boolean | nil, allow_delete: boolean | nil, allow_rename: boolean | nil, ... }) -> { severity: string, text: string }
function M.risk(decl)
	local raw_root = decl.root or ""
	-- mkdir/delete/rename are all write-level destructive operations for risk
	-- purposes — an operator who wouldn't grant write access to a tree
	-- wouldn't grant permission to rename or delete things in it either.
	local allow_write = (decl.allow_write or decl.allow_mkdir or decl.allow_delete or decl.allow_rename) and true or false
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
