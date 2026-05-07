if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local manifest = {}

--:: ManifestTbl = { name: string, version: string, description: string | nil, license: string | nil, deps: { [string]: unknown } | nil, registries: { [integer]: string } | nil, scripts: { [string]: string } | nil }

-- Validate a manifest table. Returns true on success or nil, err on failure.
--: (unknown) -> (boolean | nil, string | nil)
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

	-- deps: optional, table of { name = constraint_str } or { name = { constraint=str, include=str } }
	if tbl.deps ~= nil then
		if type(tbl.deps) ~= "table" then
			return nil, "manifest field 'deps' must be a table"
		end
		for k, v in pairs(tbl.deps) do
			if type(k) ~= "string" then
				return nil, "manifest field 'deps' keys must be strings"
			end
			if type(v) == "string" then
				-- plain constraint string: ok
			elseif type(v) == "table" then
				-- { constraint = "^1.0", include = "v2/**" } form
				if type(v.constraint) ~= "string" then
					return nil, ("manifest field 'deps[%s].constraint' must be a string"):format(k)
				end
				if v.include ~= nil and type(v.include) ~= "string" then
					return nil, ("manifest field 'deps[%s].include' must be a string"):format(k)
				end
			else
				return nil, ("manifest field 'deps[%s]' must be a string or {constraint,include} table"):format(k)
			end
		end
	end

	-- registries: optional, list of URL strings
	if tbl.registries ~= nil then
		if type(tbl.registries) ~= "table" then
			return nil, "manifest field 'registries' must be a table (list of URL strings)"
		end
		for i, v in ipairs(tbl.registries) do
			if type(v) ~= "string" then
				return nil, ("manifest field 'registries'[%d] must be a string"):format(i)
			end
		end
	end

	-- scripts: optional, table of {string = string}
	if tbl.scripts ~= nil then
		if type(tbl.scripts) ~= "table" then
			return nil, "manifest field 'scripts' must be a table"
		end
		for k, v in pairs(tbl.scripts) do
			if type(k) ~= "string" then
				return nil, "manifest field 'scripts' keys must be strings"
			end
			if type(v) ~= "string" then
				return nil, "manifest field 'scripts' values must be strings (shell commands)"
			end
		end
	end

	return true
end

--:: DepValue = string | { constraint: string, include?: string }

--- Return the constraint string for a dep entry.
-- dep_value may be a plain string or { constraint=str, include=str }.
--: (DepValue) -> string
function manifest.dep_constraint(dep_value)
	if type(dep_value) == "string" then
		return dep_value
	end
	return dep_value.constraint
end

--- Return the include glob for a dep entry. Defaults to "**" when not specified.
--: (DepValue) -> string
function manifest.dep_include(dep_value)
	if type(dep_value) == "string" then
		return "**"
	end
	return dep_value.include or "**"
end

-- Load a pkg.lua manifest from disk. Returns the table on success or nil, err.
--: (string) -> (ManifestTbl | nil, string | nil)
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
		return nil, "invalid manifest '" .. path .. "': " .. (err or "")
	end

	return result --[[:! ManifestTbl]]
end

-- Escape a string for use as a Lua string literal.
local function lua_string(s)
	return string.format("%q", s)
end

-- Write a manifest table to a pkg.lua file at path. Returns true or nil, err.
--: (string, ManifestTbl) -> (boolean | nil, string | nil)
function manifest.write(path, tbl)
	local valid, err = manifest.validate(tbl)
	if not valid then
		return nil, "cannot write invalid manifest: " .. (err or "")
	end

	local lines = {}
	lines[#lines + 1] = "return {"
	lines[#lines + 1] = "  name        = " .. lua_string(tbl.name) .. ","
	lines[#lines + 1] = "  version     = " .. lua_string(tbl.version) .. ","

	if tbl.description ~= nil then
		lines[#lines + 1] = "  description = " .. lua_string(tbl.description --[[:! string]]) .. ","
	end

	if tbl.license ~= nil then
		lines[#lines + 1] = "  license     = " .. lua_string(tbl.license --[[:! string]]) .. ","
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
			local key_str = k:match("^[a-zA-Z_][a-zA-Z0-9_]*$") and k or ("[" .. lua_string(k) .. "]")
			local v = tbl.deps and tbl.deps[k] --[[: any]]
			if type(v) == "string" then
				lines[#lines + 1] = "    " .. key_str .. " = " .. lua_string(v --[[:! string]]) .. ","
			else
				-- { constraint = "^1.0", include = "v2/**" } form
				local vt = v --[[:! { constraint: string, include: string | nil }]]
				local inc = vt.include or "**"
				lines[#lines + 1] = "    " .. key_str .. " = { constraint = " .. lua_string(vt.constraint) .. ", include = " .. lua_string(inc) .. " },"
			end
		end
	end

	lines[#lines + 1] = "  },"

	-- registries block (only written when non-empty)
	local regs = tbl.registries
	if regs ~= nil then
		local regs_ = regs --[[:! { [integer]: string }]]
		if #regs_ > 0 then
			lines[#lines + 1] = "  registries = {"
			for _, url in ipairs(regs_) do
				lines[#lines + 1] = "    " .. lua_string(url) .. ","
			end
			lines[#lines + 1] = "  },"
		end
	end

	-- scripts block (only written when non-empty)
	if tbl.scripts ~= nil then
		local script_keys = {}
		for k in pairs(tbl.scripts) do
			script_keys[#script_keys + 1] = k
		end
		if #script_keys > 0 then
			table.sort(script_keys)
			lines[#lines + 1] = "  scripts = {"
			local scripts_ = tbl.scripts --[[:! { [string]: string }]]
			for _, k in ipairs(script_keys) do
				local key_str = k:match("^[a-zA-Z_][a-zA-Z0-9_]*$") and k or ("[" .. lua_string(k) .. "]")
				lines[#lines + 1] = "    " .. key_str .. " = " .. lua_string(scripts_[k]) .. ","
			end
			lines[#lines + 1] = "  },"
		end
	end

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
