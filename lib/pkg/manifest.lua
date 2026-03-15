if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local manifest = {}

-- Validate a manifest table. Returns true on success or nil, err on failure.
function manifest.validate(tbl)
	if type(tbl) ~= "table" then
		return nil, "manifest must be a table"
	end

	-- name: required, string, [a-z0-9_-], non-empty
	if tbl.name == nil then
		return nil, "manifest missing required field: name"
	end
	if type(tbl.name) ~= "string" then
		return nil, "manifest field 'name' must be a string"
	end
	if tbl.name == "" then
		return nil, "manifest field 'name' must be non-empty"
	end
	if tbl.name:find("[^a-z0-9_%-]") then
		return nil, "manifest field 'name' contains invalid characters (only [a-z0-9_-] allowed)"
	end

	-- version: required, string, M.N.P semver format
	if tbl.version == nil then
		return nil, "manifest missing required field: version"
	end
	if type(tbl.version) ~= "string" then
		return nil, "manifest field 'version' must be a string"
	end
	if not tbl.version:match("^%d+%.%d+%.%d+$") then
		return nil, "manifest field 'version' must be in M.N.P format (e.g. 1.0.0)"
	end

	-- description: optional, string
	if tbl.description ~= nil and type(tbl.description) ~= "string" then
		return nil, "manifest field 'description' must be a string"
	end

	-- license: optional, string
	if tbl.license ~= nil and type(tbl.license) ~= "string" then
		return nil, "manifest field 'license' must be a string"
	end

	-- deps: optional, table of {string = string}
	if tbl.deps ~= nil then
		if type(tbl.deps) ~= "table" then
			return nil, "manifest field 'deps' must be a table"
		end
		for k, v in pairs(tbl.deps) do
			if type(k) ~= "string" then
				return nil, "manifest field 'deps' keys must be strings"
			end
			if type(v) ~= "string" then
				return nil, "manifest field 'deps' values must be strings (constraint strings)"
			end
		end
	end

	return true
end

-- Load a pkg.lua manifest from disk. Returns the table on success or nil, err.
function manifest.load(path)
	local chunk, load_err = loadfile(path)
	if not chunk then
		return nil, "failed to load manifest file '" .. path .. "': " .. tostring(load_err)
	end

	local ok, result = pcall(chunk)
	if not ok then
		return nil, "failed to execute manifest file '" .. path .. "': " .. tostring(result)
	end

	local valid, err = manifest.validate(result)
	if not valid then
		return nil, "invalid manifest '" .. path .. "': " .. err
	end

	return result
end

-- Escape a string for use as a Lua string literal.
local function lua_string(s)
	return string.format("%q", s)
end

-- Write a manifest table to a pkg.lua file at path. Returns true or nil, err.
function manifest.write(path, tbl)
	local valid, err = manifest.validate(tbl)
	if not valid then
		return nil, "cannot write invalid manifest: " .. err
	end

	local lines = {}
	lines[#lines + 1] = "return {"
	lines[#lines + 1] = "  name        = " .. lua_string(tbl.name) .. ","
	lines[#lines + 1] = "  version     = " .. lua_string(tbl.version) .. ","

	if tbl.description ~= nil then
		lines[#lines + 1] = "  description = " .. lua_string(tbl.description) .. ","
	end

	if tbl.license ~= nil then
		lines[#lines + 1] = "  license     = " .. lua_string(tbl.license) .. ","
	end

	-- deps block (always written, empty or not, to make the file self-documenting)
	lines[#lines + 1] = "  deps = {"

	if tbl.deps ~= nil then
		-- Sort keys for deterministic output
		local dep_keys = {}
		for k in pairs(tbl.deps) do
			dep_keys[#dep_keys + 1] = k
		end
		table.sort(dep_keys)
		for _, k in ipairs(dep_keys) do
			-- Use bare identifier syntax if valid, bracket notation otherwise (e.g. names with hyphens)
			local key_str
			if k:match("^[a-zA-Z_][a-zA-Z0-9_]*$") then
				key_str = k
			else
				key_str = "[" .. lua_string(k) .. "]"
			end
			lines[#lines + 1] = "    " .. key_str .. " = " .. lua_string(tbl.deps[k]) .. ","
		end
	end

	lines[#lines + 1] = "  },"
	lines[#lines + 1] = "}"
	lines[#lines + 1] = ""  -- trailing newline

	local content = table.concat(lines, "\n")

	local fh, open_err = io.open(path, "w")
	if not fh then
		return nil, "failed to open '" .. path .. "' for writing: " .. tostring(open_err)
	end

	local write_ok, write_err = fh:write(content)
	fh:close()

	if not write_ok then
		return nil, "failed to write manifest to '" .. path .. "': " .. tostring(write_err)
	end

	return true
end

return manifest
