if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

-- lib/pkg/lock.lua — crescent.lock parser and serializer
-- Format: TOML-inspired, text, git-diffable
--   # comments ignored
--   blank lines ignored
--   [name]       starts a package entry
--   key = "val"  assigns a string field (version, url, checksum)

local lock = {}

local VALID_KEYS = { version = true, url = true, checksum = true }

-- parse(content) → tbl | nil, err
-- tbl is { [name] = { version=..., url=..., checksum=... }, ... }
function lock.parse(content)
	local result = {}
	local current_name = nil
	local current_pkg = nil
	local lnum = 0

	for line in (content .. "\n"):gmatch("([^\n]*)\n") do
		lnum = lnum + 1

		-- strip trailing whitespace
		line = line:match("^(.-)%s*$")

		-- skip blank lines and comments
		if line == "" or line:sub(1, 1) == "#" then
			-- nothing

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
			current_pkg = {}
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
			if current_pkg[key] then
				return nil, ("line %d: duplicate key %q in [%s]"):format(lnum, key, current_name)
			end
			current_pkg[key] = val

		else
			return nil, ("line %d: unexpected line: %s"):format(lnum, line)
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
	local content = f:read("*a")
	f:close()
	return lock.parse(content)
end

-- serialize(tbl) → string
-- Entries sorted alphabetically, deterministic output.
function lock.serialize(tbl)
	-- collect and sort package names
	local names = {}
	for name in pairs(tbl) do
		names[#names + 1] = name
	end
	table.sort(names)

	local parts = { "# crescent.lock\n" }
	for i, name in ipairs(names) do
		if i > 1 then
			parts[#parts + 1] = "\n"
		end
		parts[#parts + 1] = ("[%s]\n"):format(name)
		local pkg = tbl[name]
		-- write in a fixed canonical order: version, url, checksum
		if pkg.version  then parts[#parts + 1] = ('version  = "%s"\n'):format(pkg.version)  end
		if pkg.url      then parts[#parts + 1] = ('url      = "%s"\n'):format(pkg.url)       end
		if pkg.checksum then parts[#parts + 1] = ('checksum = "%s"\n'):format(pkg.checksum)  end
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
