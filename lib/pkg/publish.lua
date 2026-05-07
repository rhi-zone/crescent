if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

-- lib/pkg/publish.lua — cr publish command implementation
--
-- Steps:
--   1. Load and validate pkg.lua in the given directory
--   2. Collect files to package (manifest.files if present; else all .lua
--      files excluding *_test.lua, bench.lua, fixtures/, docs/)
--   3. Build a tar.gz tarball in a temp file
--   4. Compute sha256 of the tarball
--   5. Upload tarball + checksum to the registry
--      Registry protocol (PUT):
--        PUT /<name>/<version>.tar.gz       body: tarball bytes
--        PUT /<name>/<version>.sha256       body: hex checksum newline
--      Auth: Bearer token from ~/.crescent/config.lua
--        config.auth["<registry-host>"].token
--   6. Print success message

local manifest = require("lib.pkg.manifest")
local config   = require("lib.pkg.config")

local M = {}

-- ── helpers ───────────────────────────────────────────────────────────────────

--: ({ verbose?: boolean, ... } | nil, string, ...unknown) -> nil
local function log(opts, fmt, ...)
	if opts and opts.verbose then
		io.stderr:write(("[crescent] " .. fmt .. "\n"):format(...))
	end
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

-- Run a command and capture stdout. Returns string or nil, err.
local function popen_read(cmd)
	local fh, err = io.popen(cmd, "r")
	if not fh then
		return nil, "popen failed: " .. tostring(err)
	end
	local out = fh:read("*a")
	fh:close()
	return out
end

-- Check whether a path exists.
local function path_exists(path)
	local f = io.open(path, "r")
	if f then f:close(); return true end
	return false
end

-- ── file collection ───────────────────────────────────────────────────────────

-- Default exclusion patterns (relative path prefixes/suffixes).
local DEFAULT_EXCLUDE_PATTERNS = {
	"_test%.lua$",    -- *_test.lua
	"/bench%.lua$",   -- bench.lua anywhere under a subdir
	"^bench%.lua$",   -- bench.lua at root
	"^fixtures/",     -- fixtures/ directory
	"^docs/",         -- docs/ directory
	"^dep/",          -- legacy dep/ directory (packages now install to lib/; keep for compat)
	"^%.git/",        -- .git
}

-- Return true if the given relative path should be excluded by default rules.
local function is_excluded(rel_path)
	for _, pat in ipairs(DEFAULT_EXCLUDE_PATTERNS) do
		if rel_path:match(pat) then
			return true
		end
	end
	return false
end

-- Collect files relative to dir.
-- If m.files is a list, use it directly (relative paths as-is).
-- Otherwise walk dir for *.lua files applying default exclusion rules.
-- Returns a sorted list of relative paths, or nil, err.
--: (string, { files?: string[], ... }) -> (string[] | nil, string | nil)
function M.collect_files(dir, m)
	-- Explicit files list from manifest takes precedence.
	if m.files ~= nil then
		if type(m.files) ~= "table" then
			return nil, "manifest field 'files' must be a list of strings"
		end
		local result = {}
		for i, f in ipairs(m.files) do
			if type(f) ~= "string" then
				return nil, ("manifest field 'files'[%d] must be a string"):format(i)
			end
			-- Normalise: strip leading ./
			local rel = f:gsub("^%./", "")
			result[#result + 1] = rel
		end
		table.sort(result)
		return result
	end

	-- Walk the directory for .lua files via find.
	-- Always include pkg.lua (it's the manifest, not a code file).
	local out, err = popen_read(("find %q -name '*.lua' -not -type d"):format(dir))
	if not out then
		return nil, "failed to enumerate files: " .. tostring(err)
	end

	local files = {}
	local trimmed = dir:gsub("/$", "")
	local prefix = trimmed .. "/"
	for path in out:gmatch("[^\n]+") do
		if path ~= "" then
			-- Compute relative path
			local rel = path
			if path:sub(1, #prefix) == prefix then
				rel = path:sub(#prefix + 1)
			end
			-- Apply exclusions
			if not is_excluded(rel) then
				files[#files + 1] = rel
			end
		end
	end

	-- pkg.lua is always included (find already picks it up if present, but
	-- just in case the manifest itself is the only .lua file in a minimal pkg).
	-- The exclusion rules don't touch pkg.lua so it's already in the list.

	table.sort(files)
	return files
end

-- ── tarball creation ──────────────────────────────────────────────────────────

-- Build a .tar.gz from a list of relative paths rooted at dir.
-- dest_path: where to write the tarball.
-- Returns true or nil, err.
--: (string, string[], string) -> (boolean | nil, string | nil)
function M.build_tarball(dir, files, dest_path)
	if #files == 0 then
		return nil, "no files to package"
	end

	-- Write the file list to a temp file to avoid argv limits on large packages.
	local list_path = os.tmpname()
	local fh, open_err = io.open(list_path, "w")
	if not fh then
		return nil, "failed to create file list: " .. tostring(open_err)
	end
	for _, f in ipairs(files) do
		fh:write(f .. "\n")
	end
	fh:close()

	-- tar -czf <dest> -C <dir> --files-from=<list>
	-- Use --no-recursion so each path is taken literally.
	local cmd = ("tar -czf %q -C %q --no-recursion --files-from=%q"):format(
		dest_path, dir, list_path
	)
	local ok, err = run_cmd(cmd)
	os.remove(list_path)

	if not ok then
		return nil, "tar failed: " .. tostring(err)
	end
	return true
end

-- ── checksum ──────────────────────────────────────────────────────────────────

-- Compute sha256 hex of a file. Returns hex string or nil, err.
--: (string) -> (string | nil, string | nil)
function M.sha256_file(path)
	local out, err = popen_read(("sha256sum %q 2>/dev/null"):format(path))
	if out and out ~= "" then
		local hex = out:match("^(%x+)")
		if type(hex) == "string" and #hex == 64 then return hex end
	end
	out, err = popen_read(("openssl dgst -sha256 %q 2>/dev/null"):format(path))
	if out and out ~= "" then
		local hex = out:match("(%x+)$")
		if type(hex) == "string" and #hex == 64 then return hex end
	end
	return nil, "could not compute sha256 for " .. tostring(path)
end

-- ── registry upload ───────────────────────────────────────────────────────────

-- Extract the hostname from a URL for auth lookup.
-- e.g. "https://pkg.crescent.run/..." → "pkg.crescent.run"
local function url_host(url)
	return url:match("^https?://([^/]+)")
end

-- Upload a tarball and its checksum to the registry.
--
-- Protocol (not yet finalised — stub for when the server is live):
--   PUT <registry>/<name>/<version>.tar.gz
--     Content-Type: application/octet-stream
--     Authorization: Bearer <token>   (if auth configured)
--     Body: tarball bytes
--
--   PUT <registry>/<name>/<version>.sha256
--     Content-Type: text/plain
--     Authorization: Bearer <token>
--     Body: "<hex>\n"
--
-- Returns true or nil, err.
--
-- TODO(registry): Replace this stub once the registry server implements PUT.
--   The upload endpoint is not yet live at pkg.crescent.run.
--   When it is, this function should:
--     1. PUT the tarball with -T flag (curl), check HTTP 200/201.
--     2. PUT the checksum file.
--     3. Retry once on transient 5xx errors.
--     4. Return a structured error on 409 Conflict (version already published).
--   The function signature and return contract are stable; only the body needs
--   replacing.
--: (string, string, string, string, string, string | nil, { verbose?: boolean } | nil) -> (boolean | nil, string | nil)
local function upload(name, version, tarball_path, checksum_hex, registry, auth_token, opts)
	local base = (registry:gsub("/$", ""))
	local tarball_url  = ("%s/%s/%s.tar.gz"):format(base, name, version)
	local checksum_url = ("%s/%s/%s.sha256"):format(base, name, version)

	log(opts, "upload: PUT %s", tarball_url)
	log(opts, "upload: PUT %s", checksum_url)

	-- Build curl auth flag if token is available.
	local auth_flag = ""
	if auth_token and auth_token ~= "" then
		auth_flag = ("-H %q"):format("Authorization: Bearer " .. auth_token)
	end

	-- PUT tarball
	local tarball_cmd = ("curl -fsSL -X PUT -T %q -H 'Content-Type: application/octet-stream' %s %q"):format(
		tarball_path, auth_flag, tarball_url
	)
	local t_ok, t_err = run_cmd(tarball_cmd)
	if not t_ok then
		return nil, ("failed to upload tarball to %s: %s"):format(tarball_url, tostring(t_err))
	end

	-- PUT checksum
	local cs_body = checksum_hex .. "\n"
	local cs_tmp  = os.tmpname()
	local csf, csf_err = io.open(cs_tmp, "w")
	if not csf then
		return nil, "failed to write checksum temp file: " .. tostring(csf_err)
	end
	csf:write(cs_body)
	csf:close()

	local cs_cmd = ("curl -fsSL -X PUT -T %q -H 'Content-Type: text/plain' %s %q"):format(
		cs_tmp, auth_flag, checksum_url
	)
	local cs_ok, cs_err2 = run_cmd(cs_cmd)
	os.remove(cs_tmp)
	if not cs_ok then
		return nil, ("failed to upload checksum to %s: %s"):format(checksum_url, tostring(cs_err2))
	end

	return true
end

-- ── main publish entry point ──────────────────────────────────────────────────

--- Publish the package in project_dir to the registry.
-- opts:
--   registry = "https://pkg.crescent.run"
--   dry_run  = false  (collect + pack but do not upload)
--   verbose  = false
--
-- Returns { ok=bool, name=str, version=str, tarball=str, checksum=str, error=str|nil }
--:: PublishOpts = { registry?: string, dry_run?: boolean, verbose?: boolean, auth_token?: string }
--:: PublishResult = { ok: boolean, name?: string, version?: string, tarball?: string, checksum?: string, error?: string }
--: (string, PublishOpts | nil) -> PublishResult
function M.run(project_dir, opts)
	opts = opts or {} --[[: PublishOpts]]
	local result = { ok = false } --[[: PublishResult]]

	-- 1. Load manifest
	local pkg_path = project_dir .. "/pkg.lua"
	if not path_exists(pkg_path) then
		result.error = "no pkg.lua found in " .. project_dir
		return result
	end

	local m_, m_err = manifest.load(pkg_path)
	if not m_ then
		result.error = tostring(m_err)
		return result
	end
	local m = m_ --[[:! ManifestTbl]]

	result.name    = m.name
	result.version = m.version

	log(opts, "publishing %s@%s", m.name, m.version)

	-- 2. Collect files
	local files, fc_err = M.collect_files(project_dir, m)
	if not files then
		result.error = "file collection failed: " .. tostring(fc_err)
		return result
	end

	if #files == 0 then
		result.error = "no files to publish (check 'files' field or add .lua files)"
		return result
	end

	log(opts, "packaging %d file(s)", #files)
	if opts.verbose then
		for _, f in ipairs(files) do
			log(opts, "  %s", f)
		end
	end

	-- 3. Build tarball in a temp file
	local tarball_path = os.tmpname() .. ".tar.gz"
	local tar_ok, tar_err = M.build_tarball(project_dir, files, tarball_path)
	if not tar_ok then
		result.error = tostring(tar_err)
		return result
	end

	-- 4. Compute checksum
	local hex, cs_err = M.sha256_file(tarball_path)
	if not hex then
		os.remove(tarball_path)
		result.error = cs_err or "checksum failed"
		return result
	end

	result.tarball  = tarball_path
	result.checksum = "sha256:" .. hex

	log(opts, "tarball: %s", tarball_path)
	log(opts, "checksum: sha256:%s", hex)

	-- 5. Upload (unless dry run)
	if opts.dry_run then
		result.ok = true
		return result
	end

	-- Determine registry
	local registry = opts.registry or "https://pkg.crescent.run"

	-- Look up auth token from user config
	local cfg = config.load()
	local host = url_host(registry)
	local token = nil
	if host and cfg.auth and cfg.auth[host] then
		token = cfg.auth[host].token
	end

	local up_ok, up_err = upload(m.name, m.version, tarball_path, hex, registry, token, opts)
	os.remove(tarball_path)

	if not up_ok then
		result.error = up_err or "upload failed"
		return result
	end

	result.ok = true
	return result
end

return M
