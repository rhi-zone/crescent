if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

-- lib/pkg/install.lua — crescent package install algorithm
--
-- Steps:
--   1. Parse pkg.lua (direct deps + constraints)
--   2. Load crescent.lock if present
--   3. Fetch registry indices for packages not in lockfile
--   4. Resolve direct deps against lockfile + registry
--   5. Fast-path check: compare tree hash of lib/<name>/ against lockfile.
--      On mismatch, warn and skip (unless --force).
--   6. BFS work queue: fetch + link each package; read its pkg.lua; enqueue
--      transitive deps (visited set prevents re-install and circular loops)
--   7. Write crescent.lock

local ffi = require("ffi")
local semver  = require("lib.pkg.semver")
local manifest = require("lib.pkg.manifest")
local lock     = require("lib.pkg.lock")
local config   = require("lib.pkg.config")
local merge3   = require("lib.merge3")

ffi.cdef[[
	int link(const char *oldpath, const char *newpath);
	int mkdir(const char *pathname, unsigned int mode);
	int symlink(const char *target, const char *linkpath);
]]

-- ── Fork/pipe FFI (for parallel fetch) ───────────────────────────────────────

local fork_available = false
pcall(function()
	ffi.cdef[[
		int fork(void);
		int waitpid(int pid, int *status, int options);
		int pipe(int fds[2]);
		ssize_t read(int fd, void *buf, size_t count);
		ssize_t write(int fd, const void *buf, size_t count);
		int close(int fd);
		long sysconf(int name);
	]]
end)
-- cdef errors if already declared (re-require); probe fork symbol directly.
pcall(function()
	fork_available = (ffi.C.fork ~= nil)
end)

--- Return the number of available CPU cores, or 1 on error / non-Linux.
-- Uses sysconf(_SC_NPROCESSORS_ONLN) = 84 on Linux.
local function cpu_count()
	if not fork_available then return 1 end
	local ok, n = pcall(function() return ffi.C.sysconf(84) end)
	if ok and type(n) == "number" and (n --[[:! number]]) > 0 then return tonumber(n) end
	return 1
end

local M = {}

-- ── helpers ───────────────────────────────────────────────────────────────────

--: ({ verbose?: boolean, ... } | nil, string, ...unknown) -> nil
local function log(opts, fmt, ...)
	if opts and opts.verbose then
		io.stderr:write(("[crescent] " .. fmt .. "\n"):format(...))
	end
end

-- Run a shell command, return stdout as string or nil, err.
--: (string) -> (string | nil, string | nil)
local function popen_read(cmd)
	local fh, err = io.popen(cmd, "r")
	if not fh then
		return nil, "popen failed: " .. tostring(err)
	end
	local out = fh:read("*a")
	fh:close()
	return out
end

-- Run a shell command for side effects. Returns true or nil, err.
--: (string) -> (boolean | nil, string | nil)
local function run_cmd(cmd)
	local ok = os.execute(cmd)
	if ok ~= 0 and ok ~= true then
		return nil, "command failed: " .. cmd
	end
	return true
end

-- Check whether a path exists (file or directory).
local function path_exists(path)
	local f = io.open(path, "r")
	if f then
		f:close()
		return true
	end
	return false
end

-- Read entire file contents. Returns string or nil, err.
--: (string) -> (string | nil, string | nil)
local function read_file(path)
	local f, err = io.open(path, "r")
	if not f then return nil, err end
	local s = f:read("*a")
	f:close()
	return s
end

-- Write string to file. Returns true or nil, err.
local function write_file(path, content)
	local f, err = io.open(path, "w")
	if not f then return nil, err end
	f:write(content)
	f:close()
	return true
end

-- Ensure a directory exists (mkdir -p equivalent via shell).
local function mkdir_p(path)
	return run_cmd(("mkdir -p %q"):format(path))
end

-- Return the global cache directory root.
-- Follows XDG Base Directory: $XDG_CACHE_HOME/crescent/pkg
-- (default $HOME/.cache/crescent/pkg). Resolved via lib.platform.xdg.
local _xdg = require("lib.platform.xdg")
local _migration_warned = false
local function _maybe_warn_legacy()
	if _migration_warned then return end
	_migration_warned = true
	local home = os.getenv("HOME")
	if not home or home == "" then return end
	local legacy = home .. "/.crescent/cache"
	local f = io.open(legacy, "r")
	local exists = false
	if f then f:close(); exists = true
	else
		local esc = (legacy:gsub('"','\\"'))
		exists = (os.execute('test -d "' .. esc .. '"') == 0)
	end
	if not exists then return end
	io.stderr:write("note: legacy " .. legacy .. " detected; pkg cache now expected at "
		.. _xdg.cache_home() .. "/pkg (no automatic migration)\n")
end
local function cache_root()
	_maybe_warn_legacy()
	return _xdg.cache_home() .. "/pkg"
end

-- Return the path for a specific package version in the global cache.
local function cache_dir(name, version)
	return cache_root() .. "/" .. name .. "@" .. version
end

-- ── HTTP fetch (curl-based v1) ────────────────────────────────────────────────

-- Fetch URL and return body string, or nil, err.
--: (string) -> (string | nil, string | nil)
local function http_get(url)
	local out, err = popen_read(("curl -fsSL %q"):format(url))
	if out == nil then
		return nil, err
	end
	-- curl exits non-zero on HTTP errors when -f is set; if we got here, it succeeded
	return out
end

-- Download URL to a file path. Returns true or nil, err.
local function http_download(url, dest_path)
	local ok = os.execute(("curl -fsSL -o %q %q"):format(dest_path, url))
	if ok ~= 0 and ok ~= true then
		return nil, "download failed for " .. url
	end
	return true
end

-- ── Checksum verification ─────────────────────────────────────────────────────

-- Compute sha256 of a file. Returns hex string or nil, err.
--: (string) -> (string | nil, string | nil)
local function sha256_file(path)
	-- Try sha256sum first (Linux), fall back to openssl (macOS/BSD)
	local out, err = popen_read(("sha256sum %q 2>/dev/null"):format(path))
	if out and out ~= "" then
		local hex = out:match("^(%x+)")
		if hex then return hex end
	end
	out, err = popen_read(("openssl dgst -sha256 %q 2>/dev/null"):format(path))
	if out and out ~= "" then
		local hex = out:match("(%x+)$")
		if hex and #hex == 64 then return hex end
	end
	return nil, "could not compute sha256 for " .. path
end

-- Verify a file against an expected checksum string.
-- checksum may be "sha256:<hex>" or plain "<hex>".
--: (string, string) -> (boolean | nil, string | nil)
local function verify_checksum(path, expected)
	local hex_expected = expected:match("^sha256:(%x+)$") or expected:match("^(%x+)$")
	if not hex_expected then
		return nil, "unrecognised checksum format: " .. expected
	end
	local actual, err = sha256_file(path)
	if not actual then return nil, err end
	if actual:lower() ~= hex_expected:lower() then
		return nil, ("checksum mismatch for %s: expected %s, got %s"):format(path, hex_expected, actual)
	end
	return true
end

-- ── Tree hash ─────────────────────────────────────────────────────────────────

--- Compute a deterministic sha256 hash of the installed file tree at dir.
--
-- Algorithm:
--   1. Walk dir recursively; collect all regular files, sorted by relative path.
--   2. Build a manifest string by concatenating, for each file in sorted order:
--        "<relative_path>:<file_contents>\n"
--   3. sha256 the entire manifest string in one pass.
--
-- This means the hash is over the full manifest blob — same files in the same
-- directory structure always produce the same hash regardless of filesystem order.
-- Adding, removing, or modifying any file changes the hash.
--
-- Returns "sha256:<hex>" or nil, err.
--: (string) -> (string | nil, string | nil)
function M.tree_hash(dir)
	-- Enumerate files sorted by relative path for determinism.
	local out, err = popen_read(("find %q -type f | sort"):format(dir))
	if not out then return nil, err end

	local trimmed_dir = dir:gsub("/$", "")
	local prefix = trimmed_dir .. "/"
	local entries = {} --: { rel: string, path: string }[]
	for path in out:gmatch("[^\n]+") do
		if path ~= "" then
			local rel = path
			if path:sub(1, #prefix) == prefix then
				rel = path:sub(#prefix + 1)
			end
			entries[#entries + 1] = { rel = rel, path = path }
		end
	end

	if #entries == 0 then
		-- Empty directory: hash of the empty string.
		local empty_hash, h_err = popen_read("printf '' | sha256sum 2>/dev/null || printf '' | openssl dgst -sha256 2>/dev/null")
		if empty_hash then
			local hex = empty_hash:match("^(%x+)") or empty_hash:match("(%x+)$")
			if hex and #hex == 64 then return "sha256:" .. hex end
		end
		return nil, "could not compute sha256 for empty tree: " .. tostring(h_err)
	end

	-- For each file, compute hash of "<relative_path>:<file_contents>".
	-- We write a small shell pipeline for this: printf "<rel>:" | cat - <file> | sha256sum
	-- To avoid spawning N processes, concatenate all "<rel>:<contents>" into one
	-- temp file then hash that.
	local tmp = os.tmpname()
	local tf, tf_err = io.open(tmp, "w")
	if not tf then return nil, "tree_hash: cannot open temp file: " .. tostring(tf_err) end

	for _, e in ipairs(entries) do
		-- Write "<rel_path>:" header then file contents.
		tf:write(e.rel .. ":")
		local contents, r_err = read_file(e.path)
		if contents == nil then
			tf:close()
			os.remove(tmp)
			return nil, ("tree_hash: cannot read %s: %s"):format(e.path, tostring(r_err))
		end
		tf:write(contents)
		tf:write("\n")
	end
	tf:close()

	local hex, h_err = sha256_file(tmp)
	os.remove(tmp)
	if not hex then return nil, h_err end
	return "sha256:" .. (hex --[[:! string]])
end

-- ── Glob matching ─────────────────────────────────────────────────────────────

--- Match a single glob pattern against a relative file path.
-- Supported wildcards:
--   **  — matches zero or more path segments (e.g. v2/** matches v2/init.lua)
--   *   — matches any sequence of non-'/' characters within one segment
--   ?   — matches a single non-'/' character
-- The pattern may not contain captures or character classes.
-- Returns true if the pattern matches the full path.
local function glob_match_single(pattern, path)
	-- Build a Lua pattern from the glob pattern.
	-- We convert segment by segment to handle ** correctly.
	-- Split pattern on '/' boundaries, handling ** specially.

	-- Escape a literal string segment for Lua pattern matching.
	local function esc(s)
		return (s:gsub("([%^%$%(%)%%%.%[%]%+%-%?])", "%%%1"))
	end

	-- Convert a single non-** glob segment to a Lua pattern fragment.
	-- * → [^/]* , ? → [^/]
	local function seg_to_pattern(seg)
		local parts = {} --: { [integer]: string }
		local i = 1
		while i <= #seg do
			local c = seg:sub(i, i)
			if c == "*" then
				parts[#parts + 1] = "[^/]*"
			elseif c == "?" then
				parts[#parts + 1] = "[^/]"
			else
				parts[#parts + 1] = esc(c)
			end
			i = i + 1
		end
		return table.concat(parts)
	end

	-- Split a string by '/' into a list of segments (preserving empty strings).
	local function split_slash(s)
		local segs = {}
		for seg in (s .. "/"):gmatch("([^/]*)/") do
			segs[#segs + 1] = seg
		end
		return segs
	end

	local pat_segs = split_slash(pattern)
	local path_segs = split_slash(path)

	-- Recursive match over segment lists.
	-- pi = 1-based index into pat_segs; vi = 1-based index into path_segs.
	local function match_segs(pi, vi)
		-- Both exhausted → match.
		if pi > #pat_segs and vi > #path_segs then return true end
		-- Pattern exhausted but path still has segments → no match.
		if pi > #pat_segs then return false end

		local pseg = pat_segs[pi]

		if pseg == "**" then
			-- ** consumes zero or more path segments.
			-- Try consuming 0 segments first, then 1, 2, ...
			for skip = 0, #path_segs - vi + 1 do
				if match_segs(pi + 1, vi + skip) then
					return true
				end
			end
			return false
		else
			-- Regular segment: must match exactly one path segment.
			if vi > #path_segs then return false end
			local vseg = path_segs[vi]
			local lua_pat = "^" .. seg_to_pattern(pseg) .. "$"
			if vseg:match(lua_pat) then
				return match_segs(pi + 1, vi + 1)
			end
			return false
		end
	end

	return match_segs(1, 1)
end

--- Match path against a glob pattern or a comma-separated union of glob patterns.
-- Returns true if the path matches any member of the union.
--
-- Examples:
--   M.glob_match("**", "v2/init.lua")          → true
--   M.glob_match("v2/**", "v2/util/foo.lua")   → true
--   M.glob_match("v2/**", "v1/init.lua")        → false
--   M.glob_match("*.lua", "foo.lua")            → true
--   M.glob_match("*.lua", "foo/bar.lua")        → false
--   M.glob_match("v1/**,v2/**", "v1/init.lua")  → true
function M.glob_match(pattern, path)
	-- Fast path: ** matches everything.
	if pattern == "**" then return true end
	-- Split on commas and test each member.
	for member in (pattern .. ","):gmatch("([^,]*),") do
		member = member:match("^%s*(.-)%s*$")  -- trim whitespace
		if member ~= "" then
			if member == "**" or glob_match_single(member, path) then
				return true
			end
		end
	end
	return false
end

--- Compute the union of two include glob strings.
-- If either is "**", the result is "**".
-- Otherwise, join unique members with ",".
local function glob_union(a, b)
	if a == "**" or b == "**" then return "**" end
	if a == b then return a end
	-- Build a set of members from both.
	local seen = {}
	local parts = {}
	local function add_members(s)
		for member in (s .. ","):gmatch("([^,]*),") do
			member = member:match("^%s*(.-)%s*$")
			if member ~= "" and not seen[member] then
				seen[member] = true
				parts[#parts + 1] = member
			end
		end
	end
	add_members(a)
	add_members(b)
	return table.concat(parts, ",")
end

-- ── Hardlink / copy ───────────────────────────────────────────────────────────

-- Copy src to dst using cp. Returns true or nil, err.
--: (string, string) -> (boolean | nil, string | nil)
local function copy_file(src, dst)
	return run_cmd(("cp %q %q"):format(src, dst))
end

-- Hardlink src → dst. Falls back to copy if link() fails (e.g. cross-device).
--: (string, string) -> (boolean | nil, string | nil)
local function hardlink_file(src, dst)
	local rc = ffi.C.link(src, dst)
	if rc == 0 then return true end
	-- fallback: copy
	return copy_file(src, dst)
end

--- Walk src_dir recursively and hardlink matching files into dst_dir.
-- include: optional glob string (default "**" = all files). Files whose
-- relative path does not match the glob are skipped.
-- Directories are created as needed.
--: (string, string, string | nil) -> (boolean | nil, string | nil)
local function hardlink_tree(src_dir, dst_dir, include)
	include = include or "**"

	-- Use find to enumerate all files
	local out, err = popen_read(("find %q -type f"):format(src_dir))
	if not out then return nil, err end

	local ok, mk_err = mkdir_p(dst_dir)
	if not ok then return nil, mk_err end

	for src_path in out:gmatch("[^\n]+") do
		if src_path ~= "" then
			-- Compute relative path
			local rel = src_path:sub(#src_dir + 2)  -- strip "src_dir/"

			-- Skip files that do not match the include glob.
			if not M.glob_match(include, rel) then
				goto next_file
			end

			local dst_path = dst_dir .. "/" .. rel

			-- Ensure parent dir exists
			local dst_parent = dst_path:match("^(.+)/[^/]+$")
			if dst_parent and dst_parent ~= dst_dir then
				local mk_ok, mk_e = mkdir_p(dst_parent)
				if not mk_ok then return nil, mk_e end
			end

			local link_ok, link_err = hardlink_file(src_path, dst_path)
			if not link_ok then
				return nil, ("failed to link %s → %s: %s"):format(src_path, dst_path, tostring(link_err))
			end

			::next_file::
		end
	end
	return true
end

-- ── Registry index parsing ────────────────────────────────────────────────────

-- Parse /index.json response.
-- Returns table { [name] = { versions = [...], latest = "x.y.z" } } or nil, err.
--: (string) -> ({ [string]: { versions: string[], latest: string | nil } } | nil, string | nil)
local function parse_index(json_str)
	-- Minimal JSON object parser: we only need top-level structure.
	-- Each package entry looks like: "sha1": {"versions": ["1.0.0"], "latest": "1.0.0"}
	-- We use a simple hand-rolled parser since we can't depend on lunajson here.
	local result = {} --: { [string]: { versions: string[], latest: string | nil } }

	-- Strip outer braces
	local body = json_str:match("^%s*%{(.*)%}%s*$")
	if not body then
		return nil, "index.json: not a JSON object"
	end

	-- Tokenise: find each "name": {...} pair.
	-- We rely on the fact that package entries don't contain nested objects deeper than one level.
	local pos = 1
	local len = #body

	local function skip_ws()
		while pos <= len and body:sub(pos, pos):match("%s") do pos = pos + 1 end
	end

	local function read_string()
		if body:sub(pos, pos) ~= '"' then return nil end
		pos = pos + 1
		local s = {}
		while pos <= len do
			local c = body:sub(pos, pos)
			if c == '"' then pos = pos + 1; return table.concat(s) end
			if c == '\\' then
				pos = pos + 1
				local e = body:sub(pos, pos)
				if e == '"' or e == '\\' or e == '/' then s[#s+1] = e
				elseif e == 'n' then s[#s+1] = '\n'
				elseif e == 't' then s[#s+1] = '\t'
				else s[#s+1] = e end
			else
				s[#s+1] = c
			end
			pos = pos + 1
		end
		return nil
	end

	local function read_array_of_strings()
		-- Expects "[" already consumed. Read comma-separated strings until "]".
		local arr = {}
		skip_ws()
		if body:sub(pos, pos) == ']' then pos = pos + 1; return arr end
		while pos <= len do
			skip_ws()
			local s = read_string()
			if s then arr[#arr+1] = s end
			skip_ws()
			local c = body:sub(pos, pos)
			pos = pos + 1
			if c == ']' then return arr end
			-- if c == ',' continue
		end
		return arr
	end

	local function read_pkg_object()
		-- Expects "{" already consumed.
		local pkg = { versions = {}, latest = nil } --: { versions: string[], latest: string | nil }
		skip_ws()
		if body:sub(pos, pos) == '}' then pos = pos + 1; return pkg end
		while pos <= len do
			skip_ws()
			local key = read_string()
			if not key then pos = pos + 1; break end
			skip_ws()
			if body:sub(pos, pos) ~= ':' then break end
			pos = pos + 1
			skip_ws()
			local c = body:sub(pos, pos)
			if c == '[' then
				pos = pos + 1
				local arr = read_array_of_strings()
				if key == "versions" then pkg.versions = arr end
			elseif c == '"' then
				local val = read_string()
				if key == "latest" then pkg.latest = val end
			else
				-- skip unknown value: scan to next comma or }
				while pos <= len do
					local ch = body:sub(pos, pos)
					if ch == ',' or ch == '}' then break end
					pos = pos + 1
				end
			end
			skip_ws()
			c = body:sub(pos, pos)
			pos = pos + 1
			if c == '}' then return pkg end
			-- c == ',' → continue
		end
		return pkg
	end

	skip_ws()
	-- Expect comma-separated "name": {...} pairs
	while pos <= len do
		skip_ws()
		if pos > len then break end
		local c = body:sub(pos, pos)
		if c == '}' then break end
		if c == ',' then pos = pos + 1 end
		skip_ws()
		if pos > len then break end

		local name = read_string()
		if not name then break end
		skip_ws()
		if body:sub(pos, pos) ~= ':' then break end
		pos = pos + 1
		skip_ws()
		if body:sub(pos, pos) ~= '{' then break end
		pos = pos + 1
		local pkg = read_pkg_object()
		result[name] = pkg

		skip_ws()
	end

	return result
end

-- ── Resolution ────────────────────────────────────────────────────────────────

--- Resolve versions for a deps table against a lockfile and registry indices.
--
-- deps: { [name] = constraint_str
--                | {constraint=str, include=str}         (manifest form)
--                | {{constraint=str, from=str}, ...}     (MVS multi-constraint form)
--       }
-- locked:         lock entries table from lock.load(), or {}
-- registry_index: parsed /index.json table, or nil (backwards-compat single registry)
-- opts:           { frozen=bool, registry_indices={{index=tbl, url=str},...} }
--
-- Multi-constraint form: deps[name] is an array of {constraint=str, from=str} tables.
-- All constraints must be satisfied simultaneously; the highest satisfying version wins.
-- When no version satisfies all constraints, the error names every imposing package.
--
-- opts.registry_indices overrides registry_index when present.
-- Each entry is tried in order; the first that satisfies the constraint wins.
--
-- Returns: { [name] = { version=str, url=str, tarball_hash=str } } or nil, err
function M.resolve(deps, locked, registry_index, opts)
	opts = opts or {}

	-- Build ordered list of {index, url} pairs from opts or fallback to single registry_index.
	-- opts.registry_indices = { {index=tbl, url=str}, ... }
	local indices = opts.registry_indices
	if not indices then
		if registry_index then
			indices = { { index = registry_index, url = nil } }
		else
			indices = {}
		end
	end

	-- Helper: pick the best version satisfying ALL constraints from a single registry index.
	-- constraints: array of {constraint=str, from=str}
	-- Returns best_version_str, winning_registry_url, or nil if not found.
	local function best_satisfying_all(name, constraints)
		-- Collect all versions across registries (union, preserving first-registry priority).
		-- We need candidates that satisfy ALL constraints.
		local best = nil
		local best_parsed = nil
		local winning_registry_url = nil

		-- Try each registry in priority order.
		for _, idx_entry in ipairs(indices) do
			local pkg_info = idx_entry.index[name]
			if pkg_info then
				for _, ver_str in ipairs(pkg_info.versions or {}) do
					local ver_ = semver.parse(ver_str)
					if ver_ ~= nil then
						local ver = ver_
						-- Check ALL constraints.
						local ok = true
						for _, c in ipairs(constraints) do
							if not semver.satisfies(ver, c.constraint) then
								ok = false
								break
							end
						end
						if ok then
							if best_parsed == nil or semver.cmp(ver, best_parsed --[[:! { major: integer, minor: integer, patch: integer, pre: ({ [number]: integer | string }) | nil }]]) > 0 then
								best = ver_str
								best_parsed = ver
								winning_registry_url = idx_entry.url
							end
						end
					end
				end
			end
		end

		return best, winning_registry_url
	end

	-- Helper: collect all available versions across all registries for error messages.
	local function all_available_versions(name)
		local seen = {}
		local vers = {}
		for _, idx_entry in ipairs(indices) do
			local pkg_info = idx_entry.index[name]
			if pkg_info then
				for _, v in ipairs(pkg_info.versions or {}) do
					if not seen[v] then
						seen[v] = true
						vers[#vers + 1] = v
					end
				end
			end
		end
		return vers
	end

	local resolved = {}

	for name, dep_value in pairs(deps) do
		-- Normalise dep_value into a constraints array: [{constraint=str, from=str}, ...]
		-- Accepted forms:
		--   ">=1.0"                           → single string
		--   {constraint=">=1.0", include="*"} → manifest form (dep_constraint extracts str)
		--   {{constraint=">=1.0", from="A"}, {constraint=">=2.0", from="B"}}  → MVS form
		local constraints   -- array of {constraint=str, from=str}

		if type(dep_value) == "table" and #dep_value > 0 and type(dep_value[1]) == "table" then
			-- MVS multi-constraint form: array of {constraint, from} tables.
			constraints = dep_value
		else
			-- Legacy single-constraint form: string or {constraint=str, include=str}.
			local c_str = manifest.dep_constraint(dep_value)
			constraints = { { constraint = c_str, from = "direct" } }
		end

		local locked_entry = locked and locked[name]

		if locked_entry then
			-- Fast path: check if the locked version satisfies ALL constraints.
			local locked_ver_ = semver.parse(locked_entry.version)
			if locked_ver_ == nil then
				return nil, ("locked version for %q is invalid"):format(name)
			end
			local locked_ver = locked_ver_

			local all_ok = true
			local failing_constraint = nil
			for _, c in ipairs(constraints) do
				if not semver.satisfies(locked_ver, c.constraint) then
					all_ok = false
					failing_constraint = c
					break
				end
			end

			if all_ok then
				resolved[name] = {
					version      = locked_entry.version,
					url          = locked_entry.url,
					tarball_hash = locked_entry.tarball_hash,
					tree_hash    = locked_entry.tree_hash,
					include      = locked_entry.include,
				}
			else
				if opts.frozen then
					return nil, ("version conflict (frozen): locked version %s of %q does not satisfy constraint %q (required by %s)"):format(
						locked_entry.version, name, failing_constraint.constraint, failing_constraint.from)
				end
				-- Fall through to registry resolution below.
				locked_entry = nil
			end
		end

		if not resolved[name] then
			-- Registry resolution: find highest version satisfying all constraints.
			if opts.frozen then
				return nil, ("frozen: package %q not in lockfile"):format(name)
			end
			if #indices == 0 then
				return nil, ("package %q: not in lockfile and no registry index available"):format(name)
			end

			local best, winning_registry_url = best_satisfying_all(name, constraints)

			if not best then
				-- Build a detailed conflict error message naming every imposing package.
				local all_vers = all_available_versions(name)
				local parts = {}
				for _, c in ipairs(constraints) do
					parts[#parts + 1] = ("  %s requires %s %s"):format(c.from, name, c.constraint)
				end
				local available_str = #all_vers > 0
					and ("available versions: %s"):format(table.concat(all_vers, ", "))
					or ("package %q not found in any registry"):format(name)
				if #constraints > 1 then
					return nil, ("version conflict for %s:\n%s\n  %s\n  no version satisfies all constraints"):format(
						name, table.concat(parts, "\n"), available_str)
				else
					-- Single constraint, no version found.
					if #all_vers == 0 then
						return nil, ("package %q not found in any registry"):format(name)
					end
					return nil, ("no version of %q satisfies constraint %q (available: %s)"):format(
						name, constraints[1].constraint, table.concat(all_vers, ", "))
				end
			end

			-- Build URL and checksum URL (these will be fetched for real during install)
			-- We don't have the checksum yet at resolve time; it will be filled in during fetch.
			resolved[name] = {
				version           = best,
				url               = nil,   -- populated by caller after fetch
				tarball_hash      = nil,   -- populated after download
				_needs_fetch      = true,
				_winning_registry = winning_registry_url,
			}
		end
	end

	return resolved
end

--- Pass 1: collect all version constraints across the full dependency graph.
--
-- Starting from direct_deps (from the project's pkg.lua), walks transitive
-- dependencies using the lockfile and installed lib/<name>/pkg.lua files.
-- Does NOT fetch from the registry.
--
-- direct_deps: { [name] = dep_value, ... }  — raw deps table from pkg.lua
-- locked:      lock entries table, or {}
-- project_dir: project root path (used to read lib/<name>/pkg.lua)
-- from_label:  string label for the project (used in constraint attribution, e.g. "myproject")
--
-- Returns: { [name] = [{constraint=str, from=str}, ...] }
-- Each array entry records one constraint on that package, with `from` naming the requirer.
function M.collect_constraints(direct_deps, locked, project_dir, from_label)
	from_label = from_label or "project"
	local all_constraints = {}   -- name → [{constraint, from}, ...]
	local visited = {}           -- package names already processed

	local function add_constraint(name, constraint, from)
		if not all_constraints[name] then
			all_constraints[name] = {}
		end
		all_constraints[name][#all_constraints[name] + 1] = { constraint = constraint, from = from }
	end

	-- Seed with direct deps.
	local queue = {}  -- [{name, from_label}] — packages whose transitive deps we still need to walk
	for dep_name, dep_value in pairs(direct_deps) do
		local c = manifest.dep_constraint(dep_value)
		add_constraint(dep_name, c, from_label)
		queue[#queue + 1] = dep_name
	end

	-- BFS: for each queued package, read its own deps from installed pkg.lua or lockfile.
	local qi = 1
	while qi <= #queue do
		local name = queue[qi]
		qi = qi + 1

		if visited[name] then goto continue_collect end
		visited[name] = true

		-- Try to read this package's own pkg.lua (from lib/<name>/pkg.lua if installed).
		local dep_manifest = nil
		if project_dir then
			local dep_m_path = project_dir .. "/lib/" .. name .. "/pkg.lua"
			dep_manifest = manifest.load(dep_m_path)
		end

		if dep_manifest and dep_manifest.deps and next(dep_manifest.deps) ~= nil then
			-- Determine the requirer label (name@version if we know the version).
			local entry = locked and locked[name]
			local requirer = entry and (name .. "@" .. entry.version) or name

			for dep_name, dep_value in pairs(dep_manifest.deps) do
				local c = manifest.dep_constraint(dep_value --[[:! string | { constraint: string, include?: string }]])
				add_constraint(--[[:! string]] dep_name, c, requirer)
				if not visited[dep_name] then
					queue[#queue + 1] = dep_name
				end
			end
		end

		::continue_collect::
	end

	return all_constraints
end

-- ── lib/ fast-path check ──────────────────────────────────────────────────────

--- Check whether lib/<name>/pkg.lua exists and matches the expected name+version.
-- Returns true if the installed package matches; false otherwise.
function M.dep_ok(project_dir, name, version)
	local pkg_path = project_dir .. "/lib/" .. name .. "/pkg.lua"
	local m, _ = manifest.load(pkg_path)
	if not m then return false end
	return m.name == name and m.version == version
end

-- ── Fetch + extract ───────────────────────────────────────────────────────────

-- Fetch a single package: download tarball, verify checksum, extract to cache.
-- Returns { version, url, tarball_hash } or nil, err.
--: (string, string, string, { verbose?: boolean, ... } | nil) -> ({ version: string, url: string, tarball_hash: string } | nil, string | nil)
local function fetch_package(name, version, registry, opts)
	local trimmed_reg = registry:gsub("/$", "")
	local base = trimmed_reg
	local tarball_url  = ("%s/%s/%s.tar.gz"):format(base, name, version)
	local checksum_url = ("%s/%s/%s.sha256"):format(base, name, version)

	local cdir = cache_dir(name, version)
	local tarball_path = cdir .. ".tar.gz"

	-- Skip download if already cached
	if path_exists(cdir .. "/pkg.lua") then
		log(opts, "cache hit: %s@%s", name, version)
		-- We still need the checksum for the lockfile entry
		local cs_path = cdir .. ".sha256"
		if path_exists(cs_path) then
			local cs_content = read_file(cs_path)
			if cs_content then
				local hex = cs_content:match("^%s*(%x+)%s*$")
				if hex then
					return { version = version, url = tarball_url, tarball_hash = "sha256:" .. hex }
				end
			end
		end
		-- Compute checksum from downloaded tarball if still present
		if path_exists(tarball_path) then
			local hex, err = sha256_file(tarball_path)
			if hex then
				return { version = version, url = tarball_url, tarball_hash = "sha256:" .. hex }
			end
		end
		-- Re-download checksum only
		local cs, _ = http_get(checksum_url)
		if cs then
			local hex = cs:match("^%s*(%x+)%s*$")
			if hex then
				return { version = version, url = tarball_url, tarball_hash = "sha256:" .. hex }
			end
		end
		return { version = version, url = tarball_url, tarball_hash = "unknown" }
	end

	log(opts, "fetching %s@%s", name, version)

	-- Fetch checksum first
	local cs_str, cs_err = http_get(checksum_url)
	if not cs_str then
		return nil, ("failed to fetch checksum for %s@%s: %s"):format(name, version, tostring(cs_err))
	end
	local expected_hex = cs_str:match("^%s*(%x+)%s*$")
	if not expected_hex or #expected_hex ~= 64 then
		return nil, ("invalid checksum response for %s@%s: %q"):format(name, version, cs_str:sub(1, 80))
	end

	-- Download tarball
	local dl_ok, dl_err = http_download(tarball_url, tarball_path)
	if not dl_ok then
		return nil, ("failed to download %s@%s: %s"):format(name, version, tostring(dl_err))
	end

	-- Verify checksum
	local verify_ok, verify_err = verify_checksum(tarball_path, "sha256:" .. expected_hex)
	if not verify_ok then
		os.remove(tarball_path)
		return nil, verify_err
	end

	-- Extract tarball into cache dir
	local mk_ok, mk_err = mkdir_p(cdir)
	if not mk_ok then return nil, mk_err end

	local extract_ok, extract_err = run_cmd(
		("tar -xzf %q -C %q"):format(tarball_path, cdir)
	)
	if not extract_ok then
		return nil, ("failed to extract %s@%s: %s"):format(name, version, tostring(extract_err))
	end

	-- Save checksum file alongside cache dir for future cache hits
	write_file(cdir .. ".sha256", expected_hex .. "\n")

	return { version = version, url = tarball_url, tarball_hash = "sha256:" .. expected_hex }
end

--- Link a package from the global cache into lib/<name>/ in the project.
-- include: glob string controlling which files are linked (default "**").
-- The global cache always holds the full unfiltered extraction; the include
-- glob is applied here during the link step so the cache can be reused when
-- a different consumer requests a different subset.
local function link_package(project_dir, name, version, opts, include)
	include = include or "**"
	local cdir = cache_dir(name, version)
	local lib_pkg_dir = project_dir .. "/lib/" .. name

	-- Remove existing lib dir if present (stale version or glob widening).
	if path_exists(lib_pkg_dir) then
		local rm_ok, rm_err = run_cmd(("rm -rf %q"):format(lib_pkg_dir))
		if not rm_ok then return nil, rm_err end
	end

	log(opts, "linking %s@%s into lib/ (include=%s)", name, version, include)
	return hardlink_tree(cdir, lib_pkg_dir, include)
end

-- ── Parallel fetch ────────────────────────────────────────────────────────────

-- Run fetch_package for each item in `work` in parallel using fork+pipe.
-- work: array of { name=str, version=str, registry=str }
-- jobs: max concurrent workers
-- opts: passed through to fetch_package (for logging)
--
-- Returns: { [name] = fetch_info } on success, { [name] = {err=str} } on failure.
-- Falls back to sequential execution silently if fork is unavailable.
--:: FetchResult = { version: string, url: string, tarball_hash: string } | { err: string }
--: ({ name: string, version: string, registry: string }[], integer, { verbose?: boolean, ... } | nil) -> { [string]: FetchResult }
local function parallel_fetch(work, jobs, opts)
	local results = {} --: { [string]: FetchResult }

	if #work == 0 then return results end

	-- Sequential fallback when fork is unavailable or jobs==1.
	if not fork_available or jobs <= 1 then
		for _, item in ipairs(work) do
			local info, err = fetch_package(item.name, item.version, item.registry, opts)
			if info then
				results[item.name] = info
			else
				results[item.name] = { err = tostring(err) }
			end
		end
		return results
	end

	-- Fork-based parallel fetch.
	-- For each package: fork a child, child fetches and writes one line to a pipe,
	-- parent collects up to `jobs` children before waiting for one to finish.

	local pending = {} --: Arr<{ pid: integer, name: string, read_fd: integer }>
	local wi = 1        -- index into work

	local status_buf = ffi.new("int[1]")
	local pipe_fds   = ffi.new("int[2]")

	local function reap_one()
		-- Wait for any one child to finish, read its result line, return it.
		local pid = ffi.C.waitpid(-1, status_buf, 0)
		if pid <= 0 then return end

		-- Find the pending entry for this pid.
		local entry_ = nil
		local entry_idx = nil
		for i, p in ipairs(pending) do
			if p.pid == pid then
				entry_ = p
				entry_idx = i
				break
			end
		end
		if not entry_ then return end
		local entry = entry_ --[[:! { name: string, read_fd: integer, pid: integer }]]

		-- Remove from pending list.
		table.remove(pending, entry_idx)

		-- Read result line from pipe.
		local buf = ffi.new("uint8_t[4096]")
		local n = ffi.C.read(entry.read_fd, buf, 4095)
		ffi.C.close(entry.read_fd)

		if n <= 0 then
			results[entry.name] = { err = "child produced no output" }
			return
		end

		local line_ = ffi.string(buf, n):match("^([^\n]*)")
		if line_ == nil then
			results[entry.name] = { err = "child produced empty line" }
			return
		end
		local line = line_ --[[:! string]]

		if line:sub(1, 3) == "ok " then
			-- "ok <name> <version> <url> <tarball_hash>"
			local ver, url, tarball_hash = line:sub(4 + #entry.name + 1):match("^(%S+) (%S+) (%S+)$")
			if ver then
				results[entry.name] = {
					version      = ver,
					url          = url,
					tarball_hash = tarball_hash,
				}
			else
				results[entry.name] = { err = "child response parse failed: " .. line }
			end
		elseif line:sub(1, 4) == "err " then
			local msg = line:sub(5 + #entry.name + 1)
			results[entry.name] = { err = msg }
		else
			results[entry.name] = { err = "unexpected child output: " .. line:sub(1, 80) }
		end
	end

	while wi <= #work or #pending > 0 do
		-- Fork new children while we have capacity and work remaining.
		while wi <= #work and #pending < jobs do
			local item = work[wi]
			wi = wi + 1

			local rc_pipe = ffi.C.pipe(pipe_fds)
			if rc_pipe ~= 0 then
				-- pipe() failed — fall back to sequential for this item.
				local info, err = fetch_package(item.name, item.version, item.registry, opts)
				if info then
					results[item.name] = info
				else
					results[item.name] = { err = tostring(err) }
				end
			else
				local read_fd  = pipe_fds[0]
				local write_fd = pipe_fds[1]

				local pid = ffi.C.fork()
				if pid < 0 then
					-- fork() failed — close pipe and run sequentially.
					ffi.C.close(read_fd)
					ffi.C.close(write_fd)
					local info, err = fetch_package(item.name, item.version, item.registry, opts)
					if info then
						results[item.name] = info
					else
						results[item.name] = { err = tostring(err) }
					end
				elseif pid == 0 then
					-- Child: close read end, run fetch, write result, exit.
					ffi.C.close(read_fd)

					local info, err = fetch_package(item.name, item.version, item.registry, opts)
					local line
					if info then
						line = ("ok %s %s %s %s\n"):format(
							item.name, info.version, info.url or "", info.tarball_hash or "")
					else
						local msg = tostring(err):gsub("\n", " ")
						line = ("err %s %s\n"):format(item.name, msg)
					end

					ffi.C.write(write_fd, line, #line)
					ffi.C.close(write_fd)
					os.exit(0)
				else
					-- Parent: close write end, record pending child.
					ffi.C.close(write_fd)
					pending[#pending + 1] = { pid = pid, name = item.name, read_fd = read_fd }
				end
			end
		end

		-- If we have no capacity left (or no more work), wait for a child to finish.
		if #pending > 0 and (#pending >= jobs or wi > #work) then
			reap_one()
		end
	end

	return results
end

-- ── Main install entry point ──────────────────────────────────────────────────

-- Deduplicate a list of registry URLs, preserving order (first occurrence wins).
local function dedup_registries(list)
	local seen = {}
	local out = {}
	for _, url in ipairs(list) do
		if not seen[url] then
			seen[url] = true
			out[#out + 1] = url
		end
	end
	return out
end

--- Install all deps listed in pkg.lua in the given project directory.
-- opts:
--   frozen     = false   error if pkg.lua diverges from lockfile
--   force      = false   overwrite lib/<name>/ even if tree hash differs (local modifications)
--   registry   = "https://pkg.crescent.run"  (single registry, backwards-compat)
--   registries = { url, ... }                (list; merged with user config + pkg registries)
--   jobs       = 0       parallelism: 0 = cpu_count(), 1 = sequential, N = N workers
--   verbose    = false
--
-- Effective registry list (highest priority first):
--   opts.registry (if set) → opts.registries → user $XDG_CONFIG_HOME/crescent/config.lua → pkg.lua.registries → default
--
-- Returns: { ok=bool, errors={string,...}, installed={string,...}, skipped={string,...} }
function M.run(project_dir, opts)
	opts = opts or {}
	-- Resolve jobs=0 (auto) to cpu_count() here so all downstream code sees a real number.
	local jobs = ((opts.jobs or 1) --[[:! integer]]) --: integer
	if jobs == 0 then jobs = cpu_count() --[[:! integer]] end

	local result = { ok = true, errors = {}, installed = {}, skipped = {} }

	local function fail(msg)
		result.ok = false
		result.errors[#result.errors + 1] = msg
	end

	-- 1. Parse pkg.lua
	local pkg_path = project_dir .. "/pkg.lua"
	local m, m_err = manifest.load(pkg_path)
	if not m then
		fail("failed to load pkg.lua: " .. tostring(m_err))
		return result
	end

	local deps = m.deps or {}
	if next(deps) == nil then
		log(opts, "no dependencies declared in pkg.lua")
		return result
	end

	-- Build effective registry list.
	-- Priority: cli_registry > opts.registries > user_config.registries > pkg.registries > default
	local user_cfg = config.load()
	local DEFAULT_REGISTRY = "https://pkg.crescent.run"

	local raw_registries = {}
	if opts.registry then
		raw_registries[#raw_registries + 1] = opts.registry
	end
	if opts.registries then
		for _, url in ipairs(opts.registries) do
			raw_registries[#raw_registries + 1] = url
		end
	end
	for _, url in ipairs(user_cfg.registries or {}) do
		raw_registries[#raw_registries + 1] = url
	end
	for _, url in ipairs(m.registries or {}) do
		raw_registries[#raw_registries + 1] = url
	end
	raw_registries[#raw_registries + 1] = DEFAULT_REGISTRY

	local registries = dedup_registries(raw_registries)
	-- Use the first registry as the primary one for fetch_package (single-registry fetch).
	local primary_registry = registries[1]

	-- 2. Load crescent.lock if present
	local lock_path = project_dir .. "/crescent.lock"
	local locked = {}
	if path_exists(lock_path) then
		local l, l_err = lock.load(lock_path)
		if not l then
			fail("failed to parse crescent.lock: " .. tostring(l_err))
			return result
		end
		locked = l --[[:! { [string]: unknown }]]
	end

	-- 3. Two-pass MVS resolution.
	--
	-- Pass 1 (constraint collection): walk the full dependency graph using the
	-- lockfile and installed lib/<name>/pkg.lua files to collect EVERY version
	-- constraint on every package.  No registry fetch happens here.
	--
	-- Pass 2 (resolution): resolve all packages simultaneously, satisfying all
	-- collected constraints at once.  This avoids spurious conflicts that arise
	-- when a direct dep is resolved first against a weak constraint, and a
	-- stricter transitive constraint is discovered only later.

	-- Pass 1: collect all constraints.
	local all_constraints = M.collect_constraints(deps, locked, project_dir, m.name or "project")

	-- Determine whether any package needs registry resolution.
	-- A package needs the registry if it is absent from the lockfile OR if the
	-- locked version does not satisfy all collected constraints.
	local needs_registry = false
	if not opts.frozen then
		for name, constraints in pairs(all_constraints) do
			local entry = locked[name]
			if not entry then
				needs_registry = true
				break
			end
			local ver = semver.parse(entry.version)
			if not ver then
				needs_registry = true
				break
			end
			local ver_ = ver --[[:! { major: integer, minor: integer, patch: integer, pre: { [number]: integer | string } | nil }]]
			for _, c in ipairs(constraints) do
				if not semver.satisfies(ver_, c.constraint) then
					needs_registry = true
					break
				end
			end
			if needs_registry then break end
		end
	end

	-- Fetch registry indices (one fetch per registry URL, shared for all packages).
	local registry_indices = nil
	if needs_registry then
		registry_indices = {}
		for _, reg_url in ipairs(registries) do
			log(opts, "fetching registry index from %s", reg_url)
			local idx_str, idx_err = http_get(reg_url .. "/index.json")
			if not idx_str then
				fail("failed to fetch registry index from " .. reg_url .. ": " .. tostring(idx_err))
				return result
			end
			local idx, parse_err = parse_index((idx_str --[[: unknown]]) --[[:! string]])
			if not idx then
				fail("failed to parse registry index from " .. reg_url .. ": " .. tostring(parse_err))
				return result
			end
			registry_indices[#registry_indices + 1] = { index = idx, url = reg_url }
		end
	end

	-- Pass 2: resolve all packages at once using the multi-constraint form.
	-- all_constraints[name] is already [{constraint, from}, ...] — the MVS form.
	local resolve_opts = {
		frozen           = opts.frozen,
		registry_indices = registry_indices,
	}
	local resolved, res_err = M.resolve(all_constraints, locked, nil, resolve_opts)
	if not resolved then
		fail("resolution failed: " .. tostring(res_err))
		return result
	end

	-- Build initial glob_requests: name → union of requested include globs.
	-- Seeded from direct deps; extended during BFS as transitive deps declare their own requests.
	local glob_requests = {}
	for name, dep_value in pairs(deps) do
		local inc = manifest.dep_include(dep_value --[[:! string | { constraint: string, include?: string }]])
		glob_requests[name] = inc
	end

	-- Ensure global cache root exists
	local cache_ok, cache_err = mkdir_p(cache_root())
	if not cache_ok then
		fail("failed to create cache dir: " .. tostring(cache_err))
		return result
	end

	-- Ensure lib/ dir exists
	local lib_ok, lib_err = mkdir_p(project_dir .. "/lib")
	if not lib_ok then
		fail("failed to create lib/ dir: " .. tostring(lib_err))
		return result
	end

	-- 6. Fetch + link each package (with transitive dependency resolution)
	local new_lock = {}

	-- Carry over all existing locked entries (transitive deps etc.)
	for k, v in pairs(locked) do
		new_lock[k] = v
	end

	-- 6a. Parallel pre-fetch: collect all packages that need fetching and run them
	-- concurrently (up to `jobs` workers). The link step and BFS remain sequential.
	-- Only packages with _needs_fetch=true are candidates; packages already in cache
	-- or already installed are handled inline in the BFS below (no fork needed).
	local fetch_work = {}
	local sorted_resolved = {}
	for name in pairs(resolved) do sorted_resolved[#sorted_resolved+1] = name end
	table.sort(sorted_resolved)
	for _, name in ipairs(sorted_resolved) do
		local info = resolved[name]
		if info._needs_fetch then
			fetch_work[#fetch_work+1] = {
				name     = name,
				version  = info.version,
				registry = info._winning_registry or primary_registry,
			}
		end
	end

	-- Run fetches in parallel (falls back to sequential when fork unavailable or jobs==1).
	local prefetch_results = parallel_fetch(fetch_work, jobs, opts)

	-- visited: tracks packages that have been processed (fetched+linked or skipped)
	-- in this run, to avoid re-installing or infinite loops from circular deps.
	local visited = {}

	-- Work queue: start with directly-resolved packages.
	-- Each entry is { name=str, info={version,url,...} }
	local queue = {}
	local names = {}
	for name in pairs(resolved) do names[#names+1] = name end
	table.sort(names)
	for _, name in ipairs(names) do
		queue[#queue+1] = { name = name, info = resolved[name] }
	end

	local qi = 1  -- queue read index (breadth-first)
	while qi <= #queue do
		local item = queue[qi] --[[:! { name: string, info: { version: string, url?: string, tarball_hash?: string, _needs_fetch?: boolean, [string]: unknown } }]]
		qi = qi + 1
		local name = item.name
		local info = item.info
		local version = info.version

		-- Skip if already processed in this run
		if visited[name] then
			goto continue
		end
		visited[name] = true

		-- Compute the effective include glob for this package: union of all requests.
		local effective_include = glob_requests[name] or "**"

		-- lib/ fast path: skip if already correct
		if M.dep_ok(project_dir, name, version) and not info._needs_fetch then
			-- Check whether the include glob has widened since last install.
			-- If so, re-link from cache with the wider glob (no re-download needed).
			local locked_entry = new_lock[name] --[[:! { include?: string, url?: string, tarball_hash?: string, tree_hash?: string, version?: string, [string]: unknown } | nil]]
			local locked_include = (locked_entry and locked_entry.include) or "**"
			local glob_widened = (effective_include ~= locked_include)

			if glob_widened then
				log(opts, "re-linking %s@%s: include widened from %q to %q", name, version, locked_include, effective_include)
				local lnk_ok, lnk_err = link_package(project_dir, name, version, opts, effective_include)
				if not lnk_ok then
					fail(("failed to re-link %s@%s: %s"):format(name, version, tostring(lnk_err)))
					goto continue
				end
				-- Update lockfile entry with new include and refreshed tree hash.
				local lib_dir = project_dir .. "/lib/" .. name
				local t_hash, _ = M.tree_hash(lib_dir)
				new_lock[name] = {
					version      = version,
					url          = (locked_entry and locked_entry.url) or info.url or "",
					tarball_hash = (locked_entry and locked_entry.tarball_hash) or info.tarball_hash or "",
					tree_hash    = t_hash,
					include      = effective_include,
				}
				result.installed[#result.installed + 1] = name
				goto process_deps
			end

			-- Check tree hash for local modifications (unless --force).
			if locked_entry and locked_entry.tree_hash and not opts.force then
				local lib_dir = project_dir .. "/lib/" .. name
				local actual_hash, hash_err = M.tree_hash(lib_dir)
				if actual_hash and actual_hash ~= locked_entry.tree_hash then
					io.stderr:write(("warning: lib/%s/ has local modifications — skipping (use --force to overwrite, cr eject %s to keep changes)\n"):format(name, name))
					result.skipped[#result.skipped + 1] = name
					-- Preserve existing lockfile entry unchanged
					if not new_lock[name] then
						new_lock[name] = {
							version      = version,
							url          = info.url or "",
							tarball_hash = info.tarball_hash or "",
							include      = effective_include,
						}
					end
					goto continue
				end
			end

			log(opts, "skipping %s@%s (already installed)", name, version)
			result.skipped[#result.skipped + 1] = name
			-- Ensure lockfile entry is present
			if not new_lock[name] then
				new_lock[name] = {
					version      = version,
					url          = info.url or "",
					tarball_hash = info.tarball_hash or "",
					include      = effective_include,
				}
			else
				-- Update include in existing lockfile entry (may be same, but keep in sync).
				new_lock[name].include = effective_include
			end
		else
			-- Fetch from registry / cache.
			-- If a parallel pre-fetch ran for this package, use its cached result.
			-- Otherwise (e.g. a transitive dep discovered during BFS that wasn't
			-- in the initial resolved set), fall back to an inline sequential fetch.
			local fetch_info, fetch_err
			local pre = prefetch_results[name]
			if pre then
				if pre.err then
					fetch_err = pre.err
				else
					fetch_info = pre
				end
			else
				local fetch_registry = info._winning_registry or primary_registry
				fetch_info, fetch_err = fetch_package(name, version, fetch_registry, opts)
			end
			if not fetch_info then
				fail(("failed to fetch %s@%s: %s"):format(name, version, tostring(fetch_err)))
				goto continue
			end
			-- Link into lib/ with the effective include glob.
			local lnk_ok, lnk_err = link_package(project_dir, name, version, opts, effective_include)
			if not lnk_ok then
				fail(("failed to link %s@%s: %s"):format(name, version, tostring(lnk_err)))
				goto continue
			end

			-- Compute tree hash of freshly installed package
			local lib_dir = project_dir .. "/lib/" .. name
			local t_hash, _ = M.tree_hash(lib_dir)

			result.installed[#result.installed + 1] = name
			new_lock[name] = {
				version      = fetch_info.version,
				url          = fetch_info.url,
				tarball_hash = fetch_info.tarball_hash,
				tree_hash    = t_hash,
				include      = effective_include,
			}
		end

		::process_deps::
		-- Read the installed package's own pkg.lua to discover transitive deps.
		-- All packages are already resolved (Pass 2 above); we only need to:
		--   1. Accumulate include globs (union merge).
		--   2. Enqueue transitive deps for the BFS install loop.
		-- No re-resolution is needed here — MVS collected all constraints upfront.
		local dep_manifest_path = project_dir .. "/lib/" .. name .. "/pkg.lua"
		local dep_m = manifest.load(dep_manifest_path)
		if dep_m and dep_m.deps and next(dep_m.deps) ~= nil then
			-- Accumulate include globs from transitive deps (union merge).
			local trans_names = {}
			for dep_name, dep_value in pairs(dep_m.deps) do
				local dep_inc = manifest.dep_include(dep_value --[[:! string | { constraint: string, include?: string }]])
				glob_requests[dep_name] = glob_union(glob_requests[dep_name] or "**", dep_inc)
				if not visited[dep_name] then
					trans_names[#trans_names + 1] = dep_name
				end
			end

			-- Enqueue unvisited transitive deps (sorted for determinism).
			-- resolved[] contains every package from Pass 2; new transitive deps
			-- discovered here were also collected in Pass 1 and resolved already.
			table.sort(trans_names)
			for _, dep_name in ipairs(trans_names) do
				local dep_info = resolved[dep_name]
				if dep_info then
					queue[#queue + 1] = { name = dep_name, info = dep_info }
				end
				-- If dep_info is nil the dep was not in the dependency graph collected
				-- during Pass 1 (e.g. a package installed outside the package manager).
				-- Skip silently — it will not be in the lockfile and is not our concern.
			end
		end

		::continue::
	end

	-- 7. Write crescent.lock
	if result.ok then
		local write_ok, write_err = lock.write(lock_path, new_lock)
		if not write_ok then
			fail("failed to write crescent.lock: " .. tostring(write_err))
		end
	end

	return result
end

-- ── Three-way merge ───────────────────────────────────────────────────────────

--- Detect whether a file is binary by scanning for null bytes.
-- Returns true if the file appears to be binary.
local function is_binary_file(path)
	local f = io.open(path, "rb")
	if not f then return false end
	-- Read the first 8 KB — sufficient heuristic for null-byte detection.
	local chunk = f:read(8192)
	f:close()
	if not chunk then return false end
	return chunk:find("\0", 1, true) ~= nil
end

--- Enumerate files in a directory recursively.
-- Returns a table { [rel_path] = true } with paths relative to dir.
-- Returns nil, err on failure.
--: (dir: string) -> ({ [string]: true } | nil, string | nil)
local function enum_files(dir)
	local out, err = popen_read(("find %q -type f | sort"):format(dir))
	if not out then return nil, err end
	local cleaned = dir:gsub("/$", "")
	local prefix = cleaned .. "/"
	local files = {}
	for abs_path in out:gmatch("[^\n]+") do
		if abs_path ~= "" then
			local rel = abs_path
			if abs_path:sub(1, #prefix) == prefix then
				rel = abs_path:sub(#prefix + 1)
			end
			files[rel] = true
		end
	end
	return files
end

--- Perform a three-way merge of a single package.
--
-- Three inputs:
--   base  = $XDG_CACHE_HOME/crescent/pkg/<name>@<old_version>/  (must exist)
--   ours  = project_dir/lib/<name>/                  (local modifications)
--   theirs = $XDG_CACHE_HOME/crescent/pkg/<name>@<new_version>/ (fetched if not already cached)
--
-- For each file in the union of all three trees (filtered by include_glob):
--   - exists in all three → diff3 -m ours base theirs → write back to ours
--   - only in theirs      → copy into ours (new file in new version)
--   - only in ours        → leave alone (locally added file)
--   - deleted in theirs but modified in ours → warn, leave ours in place
--   - unchanged base→ours → take theirs (no conflict possible)
--
-- Returns { ok=bool, conflicts=N, files_merged=N } or nil, err.
--: (project_dir: string, name: string, old_version: string, new_version: string, include_glob: string | nil, opts: { [string]: unknown, ... } | nil) -> ({ ok: boolean, conflicts: integer, files_merged: integer } | nil, string | nil)
function M.merge_package(project_dir, name, old_version, new_version, include_glob, opts)
	opts = opts or {}
	include_glob = include_glob or "**"

	local base_dir   = cache_dir(name, old_version) --[[:! string]]
	local ours_dir   = project_dir .. "/lib/" .. name
	local theirs_dir = cache_dir(name, new_version) --[[:! string]]

	-- Base cache must exist (needed for three-way merge base).
	if not path_exists(base_dir) then
		return nil, ("cache for %s@%s not found — cannot merge (try cr update --overwrite)"):format(name, old_version)
	end

	-- Theirs cache must also exist (caller should have fetched before calling).
	if not path_exists(theirs_dir) then
		return nil, ("cache for %s@%s not found — fetch the new version first"):format(name, new_version)
	end

	-- Enumerate files in all three trees.
	local base_files,   b_err = enum_files(base_dir)
	if not base_files   then return nil, "merge_package: enum base: "   .. tostring(b_err) end
	local ours_files,   o_err = enum_files(ours_dir)
	if not ours_files   then return nil, "merge_package: enum ours: "   .. tostring(o_err) end
	local theirs_files, t_err = enum_files(theirs_dir)
	if not theirs_files then return nil, "merge_package: enum theirs: " .. tostring(t_err) end

	-- Build the union of all file paths, filtered by the include glob.
	local all_files = {} --[[: { [string]: true }]]
	local function add_files(tbl)
		for rel in pairs(tbl) do
			if M.glob_match(include_glob, rel) then
				all_files[rel] = true
			end
		end
	end
	add_files(base_files)
	add_files(ours_files)
	add_files(theirs_files)

	-- Collect sorted file list for determinism.
	local sorted = {} --[[: Arr<string>]]
	for rel in pairs(all_files) do sorted[#sorted + 1] = rel end
	table.sort(sorted)

	local conflicts    = 0
	local files_merged = 0

	local ok, pcall_err = pcall(function()
		for _, rel in ipairs(sorted) do
			local in_base   = base_files[rel]   ~= nil
			local in_ours   = ours_files[rel]   ~= nil
			local in_theirs = theirs_files[rel] ~= nil

			local ours_path   = ours_dir   .. "/" .. rel
			local base_path   = base_dir   .. "/" .. rel
			local theirs_path = theirs_dir .. "/" .. rel

			if in_theirs and not in_base and not in_ours then
				-- New file added in new version: copy into ours.
				local dst_parent = ours_path:match("^(.+)/[^/]+$")
				if dst_parent then
					mkdir_p(dst_parent)
				end
				local cp_ok, cp_err = copy_file(theirs_path, ours_path)
				if not cp_ok then
					error(("merge_package: failed to copy new file %s: %s"):format(rel, tostring(cp_err)))
				end

			elseif in_ours and not in_theirs and in_base then
				-- File deleted in new version but present (possibly modified) in ours.
				-- Compare base vs ours to detect local modification.
				local base_content = read_file(base_path)
				local ours_content = read_file(ours_path)
				if base_content ~= ours_content then
					io.stderr:write(("warning: merge %s: %s deleted in new version but locally modified — leaving ours in place\n"):format(name, rel))
				else
					-- Unmodified in ours, deleted in theirs: remove from ours.
					os.remove(ours_path)
				end

			elseif in_ours and not in_theirs and not in_base then
				-- Locally added file, not in either upstream tree: leave alone.

			elseif in_base and in_ours and in_theirs then
				-- All three exist: perform three-way merge.

				-- Binary file check: skip merge for binary files.
				if is_binary_file(ours_path) or is_binary_file(theirs_path) or is_binary_file(base_path) then
					io.stderr:write(("warning: merge %s: %s appears to be binary — skipping merge, leaving ours in place\n"):format(name, rel))
				else
					-- Check if ours == base (no local modification): just take theirs.
					local base_c = read_file(base_path)
					local ours_c = read_file(ours_path)
					if base_c == ours_c then
						-- No local change: take theirs unconditionally (no conflict possible).
						local cp_ok, cp_err = copy_file(theirs_path, ours_path)
						if not cp_ok then
							error(("merge_package: failed to update unchanged file %s: %s"):format(rel, tostring(cp_err)))
						end
					else
						-- Local modification: three-way merge with pure Lua.
						local theirs_c = read_file(theirs_path)
						if not theirs_c then
							error(("merge_package: cannot read theirs %s"):format(rel))
						end

						local bc = (base_c --[[: unknown]]) --[[:! string]]
						local oc = (ours_c --[[: unknown]]) --[[:! string]]
						local tc = (theirs_c --[[: unknown]]) --[[:! string]]
						local merged_content, file_conflicts = merge3.merge3(bc, oc, tc)

						-- Write merged result back.
						local wf_ok, wf_err = write_file(ours_path, merged_content)
						if not wf_ok then
							error(("merge_package: failed to write merged %s: %s"):format(rel, tostring(wf_err)))
						end

						conflicts = conflicts + ((file_conflicts --[[: unknown]]) --[[:! integer]])
						files_merged = files_merged + 1
					end
				end

			elseif in_theirs and in_base and not in_ours then
				-- File was in base, unchanged in theirs, deleted locally: leave deleted.
				-- (ours intentionally removed it; honour that.)

			elseif in_theirs and not in_base and in_ours then
				-- New file in theirs that also exists in ours (coincidental add).
				-- Merge with an empty synthetic base.
				if is_binary_file(ours_path) or is_binary_file(theirs_path) then
					io.stderr:write(("warning: merge %s: %s appears to be binary — skipping merge, leaving ours in place\n"):format(name, rel))
				else
					local ours_c   = read_file(ours_path)
					local theirs_c = read_file(theirs_path)
					if ours_c and theirs_c then
						local oc2 = (ours_c --[[: unknown]]) --[[:! string]]
						local tc2 = (theirs_c --[[: unknown]]) --[[:! string]]
						local merged_content, file_conflicts = merge3.merge3("", oc2, tc2)
						write_file(ours_path, merged_content)
						conflicts    = conflicts    + ((file_conflicts --[[: unknown]]) --[[:! integer]])
						files_merged = files_merged + 1
					end
				end
			end
			-- Remaining cases (file only in base, not in ours/theirs) → nothing to do.
		end
	end)

	if not ok then
		return nil, tostring(pcall_err)
	end

	return { ok = (conflicts == 0), conflicts = conflicts, files_merged = files_merged }
end

-- ── internals exposed for testing ────────────────────────────────────────────
M._parse_index = parse_index
M.glob_union   = glob_union   -- exposed for tests; also used in BFS glob accumulation
M.cpu_count    = cpu_count    -- exposed for testability
-- M.collect_constraints is already a public method (used by tests)

return M
