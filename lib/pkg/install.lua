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

ffi.cdef[[
	int link(const char *oldpath, const char *newpath);
	int mkdir(const char *pathname, unsigned int mode);
	int symlink(const char *target, const char *linkpath);
]]

local M = {}

-- ── helpers ───────────────────────────────────────────────────────────────────

local function log(opts, fmt, ...)
	if opts and opts.verbose then
		io.stderr:write(("[crescent] " .. fmt .. "\n"):format(...))
	end
end

-- Run a shell command, return stdout as string or nil, err.
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

-- Return the global cache directory root (~/.crescent/cache).
local function cache_root()
	local home = os.getenv("HOME") or "/tmp"
	return home .. "/.crescent/cache"
end

-- Return the path for a specific package version in the global cache.
local function cache_dir(name, version)
	return cache_root() .. "/" .. name .. "@" .. version
end

-- ── HTTP fetch (curl-based v1) ────────────────────────────────────────────────

-- Fetch URL and return body string, or nil, err.
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
--   2. For each file, compute sha256("<relative_path>:<file_contents>") by
--      piping through sha256sum/openssl.
--   3. Concatenate all per-file hex hashes (newline-separated) and hash the result.
-- Returns "sha256:<hex>" or nil, err.
function M.tree_hash(dir)
	-- Enumerate files sorted by relative path for determinism.
	local out, err = popen_read(("find %q -type f | sort"):format(dir))
	if not out then return nil, err end

	local prefix = dir:gsub("/$", "") .. "/"
	local entries = {}
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
	return "sha256:" .. hex
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
		local parts = {}
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
local function copy_file(src, dst)
	return run_cmd(("cp %q %q"):format(src, dst))
end

-- Hardlink src → dst. Falls back to copy if link() fails (e.g. cross-device).
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
local function parse_index(json_str)
	-- Minimal JSON object parser: we only need top-level structure.
	-- Each package entry looks like: "sha1": {"versions": ["1.0.0"], "latest": "1.0.0"}
	-- We use a simple hand-rolled parser since we can't depend on lunajson here.
	local result = {}

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
		local pkg = { versions = {}, latest = nil }
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
-- deps:           { [name] = constraint_str | {constraint=str, include=str}, ... }
-- locked:         lock entries table from lock.load(), or {}
-- registry_index: parsed /index.json table, or nil (backwards-compat single registry)
-- opts:           { frozen=bool, registry_indices={{index=tbl, url=str},...} }
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

	-- Helper: pick the best satisfying version from a single registry index entry.
	-- Returns best_version_str, or nil if not found.
	local function best_from_index(idx_entry, name, constraint)
		local pkg_info = idx_entry.index[name]
		if not pkg_info then return nil end
		local best = nil
		local best_parsed = nil
		for _, ver_str in ipairs(pkg_info.versions or {}) do
			local ver, _ = semver.parse(ver_str)
			if ver and semver.satisfies(ver, constraint) then
				if best_parsed == nil or semver.cmp(ver, best_parsed) > 0 then
					best = ver_str
					best_parsed = ver
				end
			end
		end
		return best
	end

	local resolved = {}

	for name, dep_value in pairs(deps) do
		-- dep_value is either a plain constraint string or { constraint=str, include=str }.
		local constraint = manifest.dep_constraint(dep_value)
		local locked_entry = locked and locked[name]

		if locked_entry then
			-- Fast path: locked version satisfies the constraint
			local locked_ver, parse_err = semver.parse(locked_entry.version)
			if not locked_ver then
				return nil, ("locked version for %q is invalid: %s"):format(name, tostring(parse_err))
			end
			if not semver.satisfies(locked_ver, constraint) then
				if opts.frozen then
					return nil, ("frozen: locked version %s of %q does not satisfy constraint %q"):format(
						locked_entry.version, name, constraint)
				end
				-- Need to re-resolve against registry
				if #indices == 0 then
					return nil, ("package %q: locked version %s does not satisfy %q and no registry index available"):format(
						name, locked_entry.version, constraint)
				end
				locked_entry = nil  -- fall through to registry resolution below
			else
				resolved[name] = {
					version      = locked_entry.version,
					url          = locked_entry.url,
					tarball_hash = locked_entry.tarball_hash,
					tree_hash    = locked_entry.tree_hash,
					include      = locked_entry.include,
				}
			end
		end

		if not resolved[name] then
			-- Registry resolution
			if opts.frozen then
				return nil, ("frozen: package %q not in lockfile"):format(name)
			end
			if #indices == 0 then
				return nil, ("package %q: not in lockfile and no registry index available"):format(name)
			end

			-- Scan registries in priority order; first satisfying registry wins.
			local best = nil
			local winning_registry_url = nil
			for _, idx_entry in ipairs(indices) do
				local ver = best_from_index(idx_entry, name, constraint)
				if ver then
					best = ver
					winning_registry_url = idx_entry.url
					break
				end
			end

			if not best then
				-- Collect all available versions across all registries for the error message.
				local all_versions = {}
				for _, idx_entry in ipairs(indices) do
					local pkg_info = idx_entry.index[name]
					if pkg_info then
						for _, v in ipairs(pkg_info.versions or {}) do
							all_versions[#all_versions + 1] = v
						end
					end
				end
				if #all_versions == 0 then
					return nil, ("package %q not found in any registry"):format(name)
				end
				return nil, ("no version of %q satisfies constraint %q (available: %s)"):format(
					name, constraint, table.concat(all_versions, ", "))
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
local function fetch_package(name, version, registry, opts)
	local base = registry:gsub("/$", "")
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
--   jobs       = 1       (v1: sequential only — parallel is a later phase)
--   verbose    = false
--
-- Effective registry list (highest priority first):
--   opts.registry (if set) → opts.registries → user ~/.crescent/config.lua → pkg.lua.registries → default
--
-- Returns: { ok=bool, errors={string,...}, installed={string,...}, skipped={string,...} }
function M.run(project_dir, opts)
	opts = opts or {}
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
		locked = l
	end

	-- 3. Fetch registry indices for any packages that aren't in the lockfile.
	-- Cache index fetches so each registry URL is only fetched once.
	local needs_registry = false
	for name, dep_value in pairs(deps) do
		local constraint = manifest.dep_constraint(dep_value)
		local entry = locked[name]
		if not entry then
			needs_registry = true
			break
		end
		-- Also check if locked version satisfies constraint; if not, need registry
		local ver, _ = semver.parse(entry.version)
		if not ver or not semver.satisfies(ver, constraint) then
			if not opts.frozen then
				needs_registry = true
				break
			end
		end
	end

	-- registry_indices: ordered list of {index=tbl, url=str} for resolve()
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
			local idx, parse_err = parse_index(idx_str)
			if not idx then
				fail("failed to parse registry index from " .. reg_url .. ": " .. tostring(parse_err))
				return result
			end
			registry_indices[#registry_indices + 1] = { index = idx, url = reg_url }
		end
	end

	-- 5. Resolve
	-- Build constraint-only deps table for resolve() (strips include globs).
	local constraint_deps = {}
	for name, dep_value in pairs(deps) do
		constraint_deps[name] = manifest.dep_constraint(dep_value)
	end

	local resolve_opts = {
		frozen           = opts.frozen,
		registry_indices = registry_indices,
	}
	local resolved, res_err = M.resolve(constraint_deps, locked, nil, resolve_opts)
	if not resolved then
		fail("resolution failed: " .. tostring(res_err))
		return result
	end

	-- Build initial glob_requests: name → union of requested include globs.
	-- Seeded from direct deps; extended during BFS as transitive deps declare their own requests.
	local glob_requests = {}
	for name, dep_value in pairs(deps) do
		local inc = manifest.dep_include(dep_value)
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
		local item = queue[qi]
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
			local locked_entry = new_lock[name]
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
					io.stderr:write(("warning: lib/%s/ has local modifications (run with --force to overwrite)\n"):format(name))
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
			-- Fetch from registry / cache
			local fetch_registry = info._winning_registry or primary_registry
			local fetch_info, fetch_err = fetch_package(name, version, fetch_registry, opts)
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
		local dep_manifest_path = project_dir .. "/lib/" .. name .. "/pkg.lua"
		local dep_m = manifest.load(dep_manifest_path)
		if dep_m and dep_m.deps and next(dep_m.deps) ~= nil then
			-- Accumulate include globs from transitive deps (union merge).
			for dep_name, dep_value in pairs(dep_m.deps) do
				local dep_inc = manifest.dep_include(dep_value)
				glob_requests[dep_name] = glob_union(glob_requests[dep_name] or "**", dep_inc)
			end

			-- Filter out already-visited deps before resolving.
			-- For already-visited deps, verify the selected version still satisfies
			-- this package's constraint — silent drops can hide version conflicts.
			local new_deps = {}
			for dep_name, dep_value in pairs(dep_m.deps) do
				local constraint = manifest.dep_constraint(dep_value)
				if not visited[dep_name] then
					new_deps[dep_name] = constraint
				else
					-- Already resolved — verify the selected version satisfies this constraint too.
					local entry = new_lock[dep_name]
					if entry then
						local ver = semver.parse(entry.version)
						if ver and not semver.satisfies(ver, constraint) then
							fail(("version conflict: %s@%s is selected but %s requires %s %s"):format(
								dep_name, entry.version, name, dep_name, constraint))
						end
					end
				end
			end

			if next(new_deps) ~= nil then
				-- Resolve these transitive deps using the same registry indices and locked data.
				local trans_resolved, trans_err = M.resolve(new_deps, new_lock, nil, resolve_opts)
				if not trans_resolved then
					fail(("transitive dep resolution failed for %s: %s"):format(name, tostring(trans_err)))
				else
					-- Enqueue newly-resolved transitive deps (sorted for determinism).
					local trans_names = {}
					for n in pairs(trans_resolved) do trans_names[#trans_names+1] = n end
					table.sort(trans_names)
					for _, n in ipairs(trans_names) do
						if not visited[n] then
							queue[#queue+1] = { name = n, info = trans_resolved[n] }
						end
					end
				end
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

-- ── internals exposed for testing ────────────────────────────────────────────
M._parse_index = parse_index
M.glob_union   = glob_union   -- exposed for tests; also used in BFS glob accumulation

return M
