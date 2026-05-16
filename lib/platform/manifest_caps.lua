-- lib/platform/manifest_caps.lua
-- Manifest cap-declaration helpers: shorthand expansion and top-level +
-- per-entry merge.
--
-- This file holds the pure-data merge logic so it can be tested without
-- loading lib/platform/cli.lua (which auto-runs M.main when required).

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

--:: require "lib.platform.platform_types"

local M = {}

-- Build a CapDecl from the shorthand-string syntax. Isolated as a helper so
-- the return-type annotation gives the typechecker an explicit anchor for
-- the (partially-populated) literal — every other CapDecl field defaults to
-- nil, which is valid at runtime but cannot be inferred from a bare table
-- expression at the call site.
--: (string, boolean) -> CapDecl
local function shorthand_cap_decl(name, required)
	--: CapDecl
	local d = {
		type = name,
		required = required,
		host = nil,
		model = nil,
		path = nil,
		paths = nil,
		methods = nil,
		allow_write = nil,
		scope = nil,
		tables = nil,
		provider = nil,
		key_name = nil,
		base_url = nil,
		provider_default = nil,
		root = nil,
		binaries = nil,
		stderr = nil,
		port = nil,
	}
	return d
end

-- Merge top-level (`manifest.caps`) and per-entrypoint
-- (`manifest.entry[entry_key].caps`) cap declarations.
-- Shorthand strings ("required" / "optional") expand to a full table with
-- `type = name` and `required = (decl ~= "optional")`. Per-entrypoint caps
-- override top-level entries with the same name.
--: (unknown, string) -> { [string]: CapDecl }
function M.merge_cap_declarations(manifest_raw, entry_key)
	--: { [string]: CapDecl }
	local cap_declarations = {}
	if type(manifest_raw) ~= "table" then return cap_declarations end
	local manifest = manifest_raw --[[: Manifest]]

	local top_caps = manifest.caps
	if top_caps then
		for name, decl in pairs(top_caps) do
			if type(decl) == "string" then
				--: CapDecl
				local expanded = shorthand_cap_decl(tostring(name), decl ~= "optional")
				cap_declarations[name] = expanded
			elseif type(decl) == "table" then
				cap_declarations[name] = decl
			end
		end
	end

	local entry_map = manifest.entry
	if entry_map then
		local entry_def = entry_map[entry_key]
		if type(entry_def) == "table" and entry_def.caps then
			for name, decl in pairs(entry_def.caps) do
				if type(decl) == "table" then
					cap_declarations[name] = decl
				end
			end
		end
	end

	return cap_declarations
end

return M
