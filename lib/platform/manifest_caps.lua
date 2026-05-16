-- lib/platform/manifest_caps.lua
-- Manifest cap-declaration helpers: shorthand expansion, top-level + per-entry
-- merge, and browser-cap kind validation.
--
-- This file holds the pure-data merge/validation logic so it can be tested
-- without loading lib/platform/cli.lua (which auto-runs M.main when required).
--
-- Daemon caps (`manifest.caps`) and browser caps (`manifest.browser_caps`) use
-- identical declaration shape — same shorthand ("required" / "optional"), same
-- default-required-true semantics, same top-level-plus-per-entrypoint merge —
-- but live in separate namespaces enforced on different sides of the realm
-- boundary. See docs/browser_caps.md §3 for the browser-cap design rationale.

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

--: (string, boolean) -> BrowserCapDecl
local function shorthand_browser_cap_decl(name, required)
	--: BrowserCapDecl
	local d = {
		type = name,
		required = required,
		allowed_origins = nil,
		allowed_methods = nil,
		allowed_navigations = nil,
		max_body_size = nil,
		max_response_size = nil,
		timeout_ms = nil,
		max_keys = nil,
		max_value_bytes = nil,
		max_total_bytes = nil,
		max_per_minute = nil,
	}
	return d
end

-- ── Daemon caps ───────────────────────────────────────────────────────────

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

-- ── Browser caps ──────────────────────────────────────────────────────────

-- Day-zero browser-cap kinds (docs/browser_caps.md §5). Extend this set when
-- a new kind is promoted from "placeholder day-one" / "future" in §4 of that
-- doc. Unknown kinds are rejected at manifest-validation time so a typo or a
-- not-yet-implemented kind cannot reach the host stub.
--: { [string]: boolean }
M.BROWSER_CAP_KINDS = {
	fetch_api          = true,
	kv_read            = true,
	kv_write           = true,
	kv_delete          = true,
	kv_keys            = true,
	navigate           = true,
	dialog             = true,
	toast              = true,
	clipboard_write    = true,
	web_crypto_random  = true,
	web_crypto_subtle  = true,
	text_encode        = true,
	text_decode        = true,
	compress           = true,
	decompress         = true,
	console_log        = true,
	set_timeout        = true,
}

-- Merge top-level (`manifest.browser_caps`) and per-entrypoint
-- (`manifest.entry[entry_key].browser_caps`) browser-cap declarations.
-- Mirrors merge_cap_declarations line-by-line: same shorthand expansion
-- ("required" / "optional"), same default-required-true, same top-level
-- plus per-entrypoint nesting.
--: (unknown, string) -> { [string]: BrowserCapDecl }
function M.merge_browser_cap_declarations(manifest_raw, entry_key)
	--: { [string]: BrowserCapDecl }
	local decls = {}
	if type(manifest_raw) ~= "table" then return decls end
	local manifest = manifest_raw --[[: Manifest]]

	local top_caps = manifest.browser_caps
	if top_caps then
		for name, decl in pairs(top_caps) do
			if type(decl) == "string" then
				--: BrowserCapDecl
				local expanded = shorthand_browser_cap_decl(tostring(name), decl ~= "optional")
				decls[name] = expanded
			elseif type(decl) == "table" then
				decls[name] = decl
			end
		end
	end

	local entry_map = manifest.entry
	if entry_map then
		local entry_def = entry_map[entry_key]
		if type(entry_def) == "table" and entry_def.browser_caps then
			for name, decl in pairs(entry_def.browser_caps) do
				if type(decl) == "string" then
					--: BrowserCapDecl
					local expanded = shorthand_browser_cap_decl(tostring(name), decl ~= "optional")
					decls[name] = expanded
				elseif type(decl) == "table" then
					decls[name] = decl
				end
			end
		end
	end

	return decls
end

-- Validate a manifest's browser_caps section. Catches structural malformations
-- and unknown kind names at manifest-parse time so they cannot reach the host
-- stub. Per-kind config-detail validation is deferred to cap-impl time.
--: (unknown) -> (boolean | nil, string | nil)
function M.validate_browser_caps(manifest_raw)
	if manifest_raw == nil then return true end
	if type(manifest_raw) ~= "table" then return true end
	local manifest = manifest_raw --[[: Manifest]]
	--: (unknown, string) -> (boolean | nil, string | nil)
	local function check_section(section, section_label)
		if section == nil then return true end
		if type(section) ~= "table" then
			return nil, "browser_caps in " .. section_label .. " must be a table, got " .. type(section)
		end
		for name, decl in pairs(section) do
			if type(name) ~= "string" then
				return nil, "browser_caps key in " .. section_label .. " must be a string"
			end
			local kind
			if type(decl) == "string" then
				if decl ~= "required" and decl ~= "optional" then
					return nil, "browser_cap '" .. name .. "' shorthand must be 'required' or 'optional', got '" .. decl .. "'"
				end
				kind = name
			elseif type(decl) == "table" then
				local t = decl.type or name
				if type(t) ~= "string" then
					return nil, "browser_cap '" .. name .. "' has non-string type field"
				end
				kind = t
			else
				return nil, "browser_cap '" .. name .. "' must be a string or table, got " .. type(decl)
			end
			if not M.BROWSER_CAP_KINDS[kind] then
				return nil, "browser_cap '" .. name .. "' (in " .. section_label .. ") has unknown type '" .. tostring(kind)
					.. "' — add to BROWSER_CAP_KINDS in lib/platform/manifest_caps.lua (see docs/browser_caps.md §5 for the day-zero set)"
			end
		end
		return true
	end
	local ok, err = check_section(manifest.browser_caps, "top-level")
	if not ok then return nil, err end
	if type(manifest.entry) == "table" then
		for entry_key, entry_def in pairs(manifest.entry) do
			if type(entry_def) == "table" then
				local sub_ok, sub_err = check_section(entry_def.browser_caps, "entry '" .. tostring(entry_key) .. "'")
				if not sub_ok then return nil, sub_err end
			end
		end
	end
	return true
end

return M
