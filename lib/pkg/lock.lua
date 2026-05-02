if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

-- lib/pkg/lock.lua — crescent.lock parser and serializer
--
-- Format: TOML-inspired, text, git-diffable
--   # comments ignored
--   blank lines ignored
--   [name]       starts a package entry
--   key = "val"  assigns a string field
--
-- Current lockfile format (v2):
--
--   [sha1]
--   version      = "1.0.0"
--   url          = "https://pkg.crescent.run/sha1/1.0.0.tar.gz"
--   tarball_hash = "sha256:abc123..."
--   tree_hash    = "sha256:def456..."
--   include      = "**"
--
-- Migration from v1 format:
--   Old key `checksum` is treated as `tarball_hash` on read.
--   Old lockfiles without `tree_hash` or `include` parse cleanly:
--   `tree_hash` defaults to nil, `include` defaults to "**".
--
-- Fields:
--   version      (required) semver string
--   url          (required) tarball download URL
--   tarball_hash (required) sha256 of the downloaded tarball: "sha256:<hex>"
--                (old key: checksum — accepted on read, written as tarball_hash)
--   tree_hash    (optional) sha256 of the extracted file tree: "sha256:<hex>"
--   include      (optional) glob pattern of installed files, default "**"

local lock = {}

-- Current lockfile format version.
lock.CURRENT_VERSION = 2

-- Keys accepted on parse. 'checksum' is the v1 alias for 'tarball_hash'.
local VALID_KEYS = {
	version      = true,
	url          = true,
	tarball_hash = true,
	checksum     = true,   -- v1 compat: silently aliased to tarball_hash
	tree_hash    = true,
	include      = true,
}

--:: LockEntry = { version: string | nil, url: string | nil, tarball_hash: string | nil, tree_hash: string | nil, include: string | nil, [string]: string | nil }
-- parse(content) → tbl | nil, err
-- tbl is { [name] = { version, url, tarball_hash, tree_hash, include }, ... }
-- tree_hash and include may be nil when absent from the lockfile.
-- checksum (v1) is mapped to tarball_hash transparently.
-- Lockfiles without a lockfile_version field are treated as v1 (migrated silently).
-- Lockfiles with lockfile_version = 2 are the current format.
-- Any other version value returns an error.
--: (content: string) -> ({ [string]: LockEntry } | nil, string | nil)
function lock.parse(content)
	local result = {} --: { [string]: LockEntry }
	local current_name = nil --: string | nil
	local current_pkg = nil --: LockEntry | nil
	local lnum = 0

	for line in (content .. "\n"):gmatch("([^\n]*)\n") do
		lnum = lnum + 1

		-- strip trailing whitespace
		line = line:match("^(.-)%s*$")

		-- skip blank lines and comments
		if line == "" or line:sub(1, 1) == "#" then
			-- nothing

		-- top-level lockfile_version field (before any section header)
		elseif not current_name and line:find("^lockfile_version%s*=") then
			local ver_str = line:match("^lockfile_version%s*=%s*(.+)$")
			local ver = tonumber(ver_str)
			if not ver then
				return nil, ("line %d: lockfile_version must be a number"):format(lnum)
			end
			if ver ~= 1 and ver ~= 2 then
				return nil, ("unsupported lockfile version: %d — upgrade crescent"):format(ver)
			end
			seen_version_field = true

		-- section header: [name]
		elseif line:sub(1, 1) == "[" then
			local name = line:match("^%[([%w_%-%.]+)%]$")
			if not name then
				return nil, ("line %d: invalid section header: %s"):format(lnum, line)
			end
			if result[name] then
				return nil, ("line %d: duplicate package %q"):format(lnum, name)
			end
			current_name = name
			current_pkg = {} --[[:! LockEntry]]
			result[name] = current_pkg

		-- key = "value"
		elseif line:find("=") then
			if not current_name then
				return nil, ("line %d: key-value before any section header"):format(lnum)
			end
			local key, val = line:match('^([%w_]+)%s*=%s*"(.-)"$')
			if not key then
				return nil, ("line %d: malformed key-value pair: %s"):format(lnum, line)
			end
			if not VALID_KEYS[key] then
				return nil, ("line %d: unknown key %q"):format(lnum, key)
			end
			-- Normalise v1 'checksum' to 'tarball_hash'
			local store_key = (key == "checksum") and "tarball_hash" or key
			if current_pkg[store_key] then
				return nil, ("line %d: duplicate key %q in [%s]"):format(lnum, key, current_name)
			end
			current_pkg[store_key] = val

		else
			return nil, ("line %d: unexpected line: %s"):format(lnum, line)
		end
	end

	-- Apply defaults for optional fields.
	for _, pkg in pairs(result) do
		if pkg.include == nil then
			pkg.include = "**"
		end
	end

	return result
end

-- load(path) → tbl | nil, err
function lock.load(path)
	local f, err = io.open(path, "r")
	if not f then
		return nil, err
	end
	local content = f:read("*a") or ""
	f:close()
	return lock.parse(content)
end

-- serialize(tbl) → string
-- Entries sorted alphabetically, deterministic output.
-- Writes all fields in canonical order: version, url, tarball_hash, tree_hash, include.
function lock.serialize(tbl)
	-- collect and sort package names
	local names = {}
	for name in pairs(tbl) do
		names[#names + 1] = name
	end
	table.sort(names)

	local parts = { "# crescent.lock\n\nlockfile_version = 2\n" }
	for i, name in ipairs(names) do
		if i > 1 then
			parts[#parts + 1] = "\n"
		end
		parts[#parts + 1] = ("[%s]\n"):format(name)
		local pkg = tbl[name]
		-- Canonical field order
		if pkg.version      then parts[#parts + 1] = ('version      = "%s"\n'):format(pkg.version)      end
		if pkg.url          then parts[#parts + 1] = ('url          = "%s"\n'):format(pkg.url)           end
		if pkg.tarball_hash then parts[#parts + 1] = ('tarball_hash = "%s"\n'):format(pkg.tarball_hash)  end
		if pkg.tree_hash    then parts[#parts + 1] = ('tree_hash    = "%s"\n'):format(pkg.tree_hash)     end
		-- Always write include (default "**") so the file is self-documenting
		local inc = pkg.include or "**"
		parts[#parts + 1] = ('include      = "%s"\n'):format(inc)
	end

	return table.concat(parts)
end

-- write(path, tbl) → true | nil, err
function lock.write(path, tbl)
	local f, err = io.open(path, "w")
	if not f then
		return nil, err
	end
	f:write(lock.serialize(tbl))
	f:close()
	return true
end

return lock
