-- lib/platform/caps/registry.lua
-- registry_cap(opts) -> cap_table, revoke_fn
-- Windows-only registry access. All key paths are relative to opts.root.
-- Path traversal (..) is blocked at the cap level.
--
-- opts.root        : (required) registry path prefix e.g. "HKCU\\Control Panel"
-- opts.allow_write : boolean, default false
--
-- Capability API:
--   cap.get(subkey, name)               -> value, type | nil, err
--   cap.set(subkey, name, value, vtype)  -> true | nil, err  (requires allow_write)
--   cap.list_keys(subkey)               -> string[] | nil, err
--   cap.list_values(subkey)             -> {name, type}[] | nil, err

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- ffi is nil on non-Windows or when LuaJIT FFI is unavailable.
-- `any` opt-out: ffi module access is gated by IS_WINDOWS runtime check;
-- the type checker cannot follow the implication IS_WINDOWS → ffi ~= nil.
local ffi_ok
local ffi = nil --[[: any]]
do
	local ok, mod = pcall(require, "ffi")
	ffi_ok = ok
	if ok then ffi = mod end
end

local IS_WINDOWS = ffi ~= nil and ffi.os == "Windows"

-- ── Constants ──────────────────────────────────────────────────────────────

local HIVES = {
	HKCR = 0x80000000,
	HKCU = 0x80000001,
	HKLM = 0x80000002,
	HKU  = 0x80000003,
}

local KEY_READ  = 0x20019
local KEY_WRITE = 0x20006

local REG_SZ         = 1
local REG_EXPAND_SZ  = 2
local REG_BINARY     = 3
local REG_DWORD      = 4
local REG_MULTI_SZ   = 7
local REG_QWORD      = 11

local TYPE_NAMES = {
	[REG_SZ]        = "REG_SZ",
	[REG_EXPAND_SZ] = "REG_EXPAND_SZ",
	[REG_BINARY]    = "REG_BINARY",
	[REG_DWORD]     = "REG_DWORD",
	[REG_MULTI_SZ]  = "REG_MULTI_SZ",
	[REG_QWORD]     = "REG_QWORD",
}

-- ── Path helpers ───────────────────────────────────────────────────────────

-- Parse "HKCU\Control Panel\Desktop" -> hive integer + base subkey string.
-- Returns nil, err on unknown hive.
--: (string) -> (number | nil, string | nil)
local function parse_root(root)
	local root_s = tostring(root)
	local hive_name, rest = root_s:match("^([^\\]+)\\?(.*)")
	if not hive_name then return nil, "registry: invalid root: " .. root_s end
	local hname = hive_name --: string
	local hive = HIVES[hname:upper()]
	if not hive then return nil, "registry: unknown hive: " .. hname end
	local hive_n = tonumber(hive) or 0
	return hive_n, rest or ""
end

-- Block path traversal.
--: (string) -> boolean
local function has_traversal(path)
	return path:find("^%.%.$") ~= nil
		or path:find("^%.%.[/\\]") ~= nil
		or path:find("[/\\]%.%.$") ~= nil
		or path:find("[/\\]%.%.[/\\]") ~= nil
end

-- Join base + subkey.
--: (string, string) -> string
local function join_key(base, sub)
	if sub == "" then return base end
	if base == "" then return sub end
	return base .. "\\" .. sub
end

-- ── UTF-16LE helpers ───────────────────────────────────────────────────────

-- Read a single byte from a string at position i, or 0 if out of range.
--: (string, integer) -> integer
local function byte_at(s, i)
	return s:byte(i) or 0
end

-- Convert UTF-16LE bytes to UTF-8. Stops at null codepoint.
--: (string, integer) -> string
local function utf16le_to_utf8(raw, len)
	local codepoints = {} --: { [integer]: integer }
	local i = 1
	while i + 1 <= len do
		local lo = byte_at(raw, i)
		local hi = byte_at(raw, i + 1)
		local cp = hi * 256 + lo
		if cp == 0 then break end
		codepoints[#codepoints + 1] = cp
		i = i + 2
	end
	local chars = {}
	for _, cp in ipairs(codepoints) do
		local c = cp --: integer
		if c < 0x80 then
			chars[#chars + 1] = string.char(c)
		elseif c < 0x800 then
			local n1 = 0xC0 + math.floor(c / 64) --: integer
			local n2 = 0x80 + c % 64 --: integer
			chars[#chars + 1] = string.char(n1)
			chars[#chars + 1] = string.char(n2)
		else
			local n1 = 0xE0 + math.floor(c / 4096) --: integer
			local n2 = 0x80 + math.floor(c % 4096 / 64) --: integer
			local n3 = 0x80 + c % 64 --: integer
			chars[#chars + 1] = string.char(n1)
			chars[#chars + 1] = string.char(n2)
			chars[#chars + 1] = string.char(n3)
		end
	end
	return table.concat(chars)
end

-- Encode UTF-8 to null-terminated UTF-16LE bytes.
--: (string) -> string
local function utf8_to_utf16le(s)
	local byte_vals = {}
	local i = 1
	while i <= #s do
		local b = byte_at(s, i)
		local cp
		if b < 0x80 then
			cp = b; i = i + 1
		elseif b < 0xE0 then
			local b2 = byte_at(s, i + 1)
			cp = (b % 32) * 64 + (b2 % 64); i = i + 2
		else
			local b2 = byte_at(s, i + 1)
			local b3 = byte_at(s, i + 2)
			cp = (b % 16) * 4096 + (b2 % 64) * 64 + (b3 % 64); i = i + 3
		end
		byte_vals[#byte_vals + 1] = cp % 256
		byte_vals[#byte_vals + 1] = math.floor(cp / 256) % 256
	end
	local parts = {}
	for j = 1, #byte_vals do
		parts[j] = string.char(byte_vals[j])
	end
	parts[#parts + 1] = "\0"
	parts[#parts + 1] = "\0"
	return table.concat(parts)
end

-- ── advapi32 FFI setup ─────────────────────────────────────────────────────

-- `any` opt-out: advapi32 is a Windows FFI library handle; ffi.load returns cdata.
local advapi32 = nil --[[: any]]
local ffi_ready = false

if IS_WINDOWS then
	local ok = pcall(function()
		ffi.cdef [[
			typedef void*          HKEY;
			typedef long           LONG;
			typedef unsigned long  DWORD;
			typedef unsigned short WCHAR;
			typedef unsigned char  BYTE;

			LONG RegOpenKeyExW(HKEY hKey, const WCHAR* lpSubKey,
				DWORD ulOptions, DWORD samDesired, HKEY* phkResult);
			LONG RegCloseKey(HKEY hKey);
			LONG RegQueryValueExW(HKEY hKey, const WCHAR* lpValueName,
				DWORD* lpReserved, DWORD* lpType, BYTE* lpData, DWORD* lpcbData);
			LONG RegSetValueExW(HKEY hKey, const WCHAR* lpValueName,
				DWORD Reserved, DWORD dwType, const BYTE* lpData, DWORD cbData);
			LONG RegEnumKeyExW(HKEY hKey, DWORD dwIndex, WCHAR* lpName, DWORD* lpcName,
				DWORD* lpReserved, WCHAR* lpClass, DWORD* lpcClass, void* lpftLastWriteTime);
			LONG RegEnumValueW(HKEY hKey, DWORD dwIndex, WCHAR* lpValueName,
				DWORD* lpcchValueName, DWORD* lpReserved, DWORD* lpType,
				BYTE* lpData, DWORD* lpcbData);
		]]
		advapi32 = ffi.load("advapi32")
		ffi_ready = true
	end)
end

-- ── Cap factory ────────────────────────────────────────────────────────────

function M.registry_cap(opts)
	local opts_ = (opts or {}) --[[:! { root: string | nil, allow_write: boolean | nil }]]

	if not IS_WINDOWS then
		error("registry_cap: Windows only")
	end

	if not ffi_ready or advapi32 == nil then
		return nil, "registry cap: advapi32 FFI unavailable"
	end

	local root = opts_.root
	if not root then error("registry_cap: opts.root is required") end
	local root_path = root  -- preserve original string for attenuate comparisons
	local allow_write = opts_.allow_write or false

	local hive_int, maybe_base = parse_root(root)
	if not hive_int then
		return nil, maybe_base
	end
	local base_key = maybe_base or "" --: string

	local revoked = false

	local function open_key(subkey, want_write)
		local full = join_key(base_key, subkey or "")
		local access = want_write and KEY_WRITE or KEY_READ
		local hkey_out = ffi.new("HKEY[1]") --: cdata
		local wfull = ffi.cast("const unsigned short*", utf8_to_utf16le(full)) --: cdata
		local rc = advapi32.RegOpenKeyExW(
			ffi.cast("void*", ffi.cast("uintptr_t", hive_int)),
			wfull, 0, access, hkey_out)
		if rc ~= 0 then return nil, "registry: RegOpenKeyExW failed: " .. rc end
		return hkey_out[0]
	end

	local function close_key(hkey)
		advapi32.RegCloseKey(hkey)
	end

	local function decode_value(vtype, buf, size)
		if vtype == REG_DWORD then
			if size < 4 then return nil, "registry: short DWORD" end
			return buf[0] + buf[1]*256 + buf[2]*65536 + buf[3]*16777216,
				TYPE_NAMES[REG_DWORD]
		elseif vtype == REG_QWORD then
			if size < 8 then return nil, "registry: short QWORD" end
			local lo = buf[0] + buf[1]*256 + buf[2]*65536 + buf[3]*16777216
			local hi = buf[4] + buf[5]*256 + buf[6]*65536 + buf[7]*16777216
			return hi * 4294967296 + lo, TYPE_NAMES[REG_QWORD]
		elseif vtype == REG_BINARY then
			return ffi.string(buf, size), TYPE_NAMES[REG_BINARY]
		elseif vtype == REG_SZ or vtype == REG_EXPAND_SZ then
			return utf16le_to_utf8(ffi.string(buf, size), size), TYPE_NAMES[vtype]
		elseif vtype == REG_MULTI_SZ then
			local raw = ffi.string(buf, size)
			local result = {}
			local pos = 1
			while pos + 1 <= size do
				local s = utf16le_to_utf8(raw:sub(pos), size - pos + 1)
				if s == "" then break end
				result[#result + 1] = s
				pos = pos + #s * 2 + 2
			end
			return result, TYPE_NAMES[REG_MULTI_SZ]
		else
			return ffi.string(buf, size), "REG_UNKNOWN_" .. tostring(vtype)
		end
	end

	local cap = {
		_type = "registry",
		get = function(subkey, name)
			if revoked then return nil, "registry: capability revoked" end
			if subkey and has_traversal(subkey) then
				return nil, "registry: path traversal not allowed"
			end
			local hkey, err = open_key(subkey, false)
			if not hkey then return nil, err end
			local wname = ffi.cast("const unsigned short*", utf8_to_utf16le(name or ""))
			local vtype = ffi.new("unsigned long[1]") --: cdata
			local size  = ffi.new("unsigned long[1]") --: cdata
			local rc = advapi32.RegQueryValueExW(hkey, wname, nil, vtype, nil, size)
			if rc ~= 0 then
				close_key(hkey)
				return nil, "registry: RegQueryValueExW failed: " .. rc
			end
			local buf = ffi.new("unsigned char[?]", size[0]) --: cdata
			rc = advapi32.RegQueryValueExW(hkey, wname, nil, vtype, buf, size)
			close_key(hkey)
			if rc ~= 0 then
				return nil, "registry: RegQueryValueExW (data) failed: " .. rc
			end
			return decode_value(vtype[0], buf, size[0])
		end,

		set = function(subkey, name, value, vtype)
			if revoked then return nil, "registry: capability revoked" end
			if not allow_write then return nil, "registry: write not granted" end
			if subkey and has_traversal(subkey) then
				return nil, "registry: path traversal not allowed"
			end
			local hkey, err = open_key(subkey, true)
			if not hkey then return nil, err end
			local wname    = ffi.cast("const unsigned short*", utf8_to_utf16le(name or ""))
			local type_int = vtype or REG_SZ
			local data --: cdata | nil
			local data_size
			if type_int == REG_DWORD then
				local v = tonumber(value) or 0
				data = ffi.new("unsigned char[4]",
					{ v % 256, math.floor(v/256) % 256,
					  math.floor(v/65536) % 256, math.floor(v/16777216) % 256 })
				data_size = 4
			elseif type_int == REG_SZ or type_int == REG_EXPAND_SZ then
				local encoded = utf8_to_utf16le(tostring(value))
				data = ffi.cast("const unsigned char*", encoded)
				data_size = #encoded
			else
				local s = tostring(value)
				data = ffi.cast("const unsigned char*", s)
				data_size = #s
			end
			local rc = advapi32.RegSetValueExW(hkey, wname, 0, type_int, data, data_size)
			close_key(hkey)
			if rc ~= 0 then return nil, "registry: RegSetValueExW failed: " .. rc end
			return true
		end,

		list_keys = function(subkey)
			if revoked then return nil, "registry: capability revoked" end
			if subkey and has_traversal(subkey) then
				return nil, "registry: path traversal not allowed"
			end
			local hkey, err = open_key(subkey, false)
			if not hkey then return nil, err end
			local result = {}
			local name_buf  = ffi.new("unsigned short[256]") --: cdata
			local name_size = ffi.new("unsigned long[1]")    --: cdata
			local idx = 0
			while true do
				name_size[0] = 256
				local rc = advapi32.RegEnumKeyExW(hkey, idx, name_buf, name_size,
					nil, nil, nil, nil)
				if rc ~= 0 then break end
				result[#result + 1] = utf16le_to_utf8(
					ffi.string(name_buf, name_size[0] * 2), name_size[0] * 2)
				idx = idx + 1
			end
			close_key(hkey)
			return result
		end,

		list_values = function(subkey)
			if revoked then return nil, "registry: capability revoked" end
			if subkey and has_traversal(subkey) then
				return nil, "registry: path traversal not allowed"
			end
			local hkey, err = open_key(subkey, false)
			if not hkey then return nil, err end
			local result = {}
			local BUF       = 16384
			local name_buf  = ffi.new("unsigned short[256]") --: cdata
			local name_size = ffi.new("unsigned long[1]")    --: cdata
			local vtype     = ffi.new("unsigned long[1]")    --: cdata
			local data_buf  = ffi.new("unsigned char[?]", BUF) --: cdata
			local data_size = ffi.new("unsigned long[1]")    --: cdata
			local idx = 0
			while true do
				name_size[0] = 256
				data_size[0] = BUF
				local rc = advapi32.RegEnumValueW(hkey, idx, name_buf, name_size,
					nil, vtype, data_buf, data_size)
				if rc ~= 0 then break end
				local n = utf16le_to_utf8(
					ffi.string(name_buf, name_size[0] * 2), name_size[0] * 2)
				result[#result + 1] = {
					name = n,
					type = TYPE_NAMES[vtype[0]] or ("REG_" .. tostring(vtype[0])),
				}
				idx = idx + 1
			end
			close_key(hkey)
			return result
		end,

		attenuate = function(sub_opts)
			if revoked then return nil, "registry: capability revoked" end
			local sub_opts_ = (sub_opts or {}) --[[:! { root: string | nil, allow_write: boolean | nil }]]
			local new_root = sub_opts_.root
			if not new_root then return nil, "registry.attenuate: root required" end
			-- Compare case-insensitively (registry paths are case-insensitive)
			local cur_lower = root_path:lower()
			local new_lower = new_root:lower()
			if new_lower ~= cur_lower and new_lower:sub(1, #cur_lower + 1) ~= cur_lower .. "\\" then
				return nil, "registry.attenuate: root escapes current scope"
			end
			local new_allow_write
			if sub_opts_.allow_write == nil then
				new_allow_write = allow_write
			elseif sub_opts_.allow_write and not allow_write then
				return nil, "registry.attenuate: cannot grant write not held"
			else
				new_allow_write = sub_opts_.allow_write
			end
			local reg_mod = --[[:! { registry_cap: (opts: { root: string, allow_write: boolean | nil }) -> (unknown, unknown) }]] require("lib.platform.caps.registry")
			return reg_mod.registry_cap({ root = new_root, allow_write = new_allow_write })
		end,
	}

	local function revoke() revoked = true end

	return cap, revoke
end

function M.risk(decl)
	if decl.allow_write == false or decl.allow_write == nil then
		return { severity = "medium", text = "Reads Windows Registry keys under a configured root." }
	end
	return { severity = "high", text = "Reads and writes Windows Registry keys under a configured root. Registry writes can affect system behavior." }
end

return M
