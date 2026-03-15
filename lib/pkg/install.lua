if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

-- lib/pkg/install.lua — crescent package install algorithm
--
-- Steps:
--   1. Parse pkg.lua (direct deps + constraints)
--   2. Load crescent.lock if present
--   3. Resolve: check lockfile for pinned versions; query registry for new/changed deps
--   4. Verify dep/ fast path: skip packages already installed at the right version
--   5. Fetch missing packages (sequential for v1):
--        - Check global cache (~/.crescent/cache/<name>@<version>/)
--        - Download tarball if not cached; verify checksum
--   6. Extract: untar into global cache, then hardlink (or copy) into dep/<name>/
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

-- Walk src_dir recursively and hardlink every file into dst_dir.
-- Directories are created as needed.
local function hardlink_tree(src_dir, dst_dir)
	-- Use find to enumerate all files
	local out, err = popen_read(("find %q -type f"):format(src_dir))
	if not out then return nil, err end

	local ok, mk_err = mkdir_p(dst_dir)
	if not ok then return nil, mk_err end

	for src_path in out:gmatch("[^\n]+") do
		if src_path ~= "" then
			-- Compute relative path
			local rel = src_path:sub(#src_dir + 2)  -- strip "src_dir/"
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
-- deps:           { [name] = constraint_str, ... }
-- locked:         lock entries table from lock.load(), or {}
-- registry_index: parsed /index.json table, or nil (backwards-compat single registry)
-- opts:           { frozen=bool, registry_indices={{index=tbl, url=str},...} }
--
-- opts.registry_indices overrides registry_index when present.
-- Each entry is tried in order; the first that satisfies the constraint wins.
--
-- Returns: { [name] = { version=str, url=str, checksum=str } } or nil, err
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

	for name, constraint in pairs(deps) do
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
					version  = locked_entry.version,
					url      = locked_entry.url,
					checksum = locked_entry.checksum,
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
				version          = best,
				url              = nil,   -- populated by caller after fetch
				checksum         = nil,   -- populated after download
				_needs_fetch     = true,
				_winning_registry = winning_registry_url,
			}
		end
	end

	return resolved
end

-- ── dep/ fast-path check ──────────────────────────────────────────────────────

--- Check whether dep/<name>/pkg.lua exists and matches the expected name+version.
-- Returns true if the installed package matches; false otherwise.
function M.dep_ok(project_dir, name, version)
	local pkg_path = project_dir .. "/dep/" .. name .. "/pkg.lua"
	local m, _ = manifest.load(pkg_path)
	if not m then return false end
	return m.name == name and m.version == version
end

-- ── Fetch + extract ───────────────────────────────────────────────────────────

-- Fetch a single package: download tarball, verify checksum, extract to cache.
-- Returns { version, url, checksum } or nil, err.
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
					return { version = version, url = tarball_url, checksum = "sha256:" .. hex }
				end
			end
		end
		-- Compute checksum from downloaded tarball if still present
		if path_exists(tarball_path) then
			local hex, err = sha256_file(tarball_path)
			if hex then
				return { version = version, url = tarball_url, checksum = "sha256:" .. hex }
			end
		end
		-- Re-download checksum only
		local cs, _ = http_get(checksum_url)
		if cs then
			local hex = cs:match("^%s*(%x+)%s*$")
			if hex then
				return { version = version, url = tarball_url, checksum = "sha256:" .. hex }
			end
		end
		return { version = version, url = tarball_url, checksum = "unknown" }
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

	return { version = version, url = tarball_url, checksum = "sha256:" .. expected_hex }
end

-- Link a package from the global cache into dep/<name>/ in the project.
local function link_package(project_dir, name, version, opts)
	local cdir = cache_dir(name, version)
	local dep_pkg_dir = project_dir .. "/dep/" .. name

	-- Remove existing dep dir if present (stale version)
	if path_exists(dep_pkg_dir) then
		local rm_ok, rm_err = run_cmd(("rm -rf %q"):format(dep_pkg_dir))
		if not rm_ok then return nil, rm_err end
	end

	log(opts, "linking %s@%s into dep/", name, version)
	return hardlink_tree(cdir, dep_pkg_dir)
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

	-- 3. Fast path: if every dep is already installed correctly, done.
	local all_ok = true
	for name, _ in pairs(deps) do
		local entry = locked[name]
		if not entry or not M.dep_ok(project_dir, name, entry.version) then
			all_ok = false
			break
		end
	end
	if all_ok and not opts.frozen then
		log(opts, "all dependencies up to date (fast path)")
		for name in pairs(deps) do
			result.skipped[#result.skipped + 1] = name
		end
		return result
	end

	-- 4. Fetch registry indices for any packages that aren't in the lockfile.
	-- Cache index fetches so each registry URL is only fetched once.
	local needs_registry = false
	for name, constraint in pairs(deps) do
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
	local resolve_opts = {
		frozen           = opts.frozen,
		registry_indices = registry_indices,
	}
	local resolved, res_err = M.resolve(deps, locked, nil, resolve_opts)
	if not resolved then
		fail("resolution failed: " .. tostring(res_err))
		return result
	end

	-- Ensure global cache root exists
	local cache_ok, cache_err = mkdir_p(cache_root())
	if not cache_ok then
		fail("failed to create cache dir: " .. tostring(cache_err))
		return result
	end

	-- Ensure dep/ dir exists
	local dep_ok2, dep_err = mkdir_p(project_dir .. "/dep")
	if not dep_ok2 then
		fail("failed to create dep/ dir: " .. tostring(dep_err))
		return result
	end

	-- 6. Fetch + link each package
	local new_lock = {}

	-- Carry over all existing locked entries (transitive deps etc.)
	for k, v in pairs(locked) do
		new_lock[k] = v
	end

	-- Sort names for deterministic processing
	local names = {}
	for name in pairs(resolved) do names[#names+1] = name end
	table.sort(names)

	for _, name in ipairs(names) do
		local info = resolved[name]
		local version = info.version

		-- dep/ fast path: skip if already correct
		if M.dep_ok(project_dir, name, version) and not info._needs_fetch then
			log(opts, "skipping %s@%s (already installed)", name, version)
			result.skipped[#result.skipped + 1] = name
			-- Ensure lockfile entry is present
			if not new_lock[name] then
				new_lock[name] = {
					version  = version,
					url      = info.url or "",
					checksum = info.checksum or "",
				}
			end
		else
			-- Fetch from registry / cache
			local fetch_registry = info._winning_registry or primary_registry
			local fetch_info, fetch_err = fetch_package(name, version, fetch_registry, opts)
			if not fetch_info then
				fail(("failed to fetch %s@%s: %s"):format(name, version, tostring(fetch_err)))
			else
				-- Link into dep/
				local lnk_ok, lnk_err = link_package(project_dir, name, version, opts)
				if not lnk_ok then
					fail(("failed to link %s@%s: %s"):format(name, version, tostring(lnk_err)))
				else
					result.installed[#result.installed + 1] = name
					new_lock[name] = {
						version  = fetch_info.version,
						url      = fetch_info.url,
						checksum = fetch_info.checksum,
					}
				end
			end
		end
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

-- ── parse_index exposed for testing ──────────────────────────────────────────
M._parse_index = parse_index

return M
