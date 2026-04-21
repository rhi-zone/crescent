-- lib/keyring/init.lua
-- Secure API key storage.  Three tiers tried in order at load time:
--   1. Linux:   libsecret via libsecret-1.so
--   2. macOS:   Security.framework keychain APIs
--   3. Fallback: authenticated encryption using SHA-256-CTR + HMAC-SHA256
--               stored in ~/.crescent/keyring.enc.  Key derived from
--               machine-id (Linux) or IOPlatformUUID (macOS).
--               Requires lib.hash.sha256 (ships with crescent).
--
-- API:
--   keyring.set(service, key)  -> true | nil, err
--   keyring.get(service)       -> value | nil, err
--   keyring.delete(service)    -> true | nil, err
--
-- Service name convention: "crescent/<name>"
-- M._tier: "libsecret" | "keychain" | "file" | nil (no tier loaded)

if package and not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local ffi = require("ffi")

local M = {}
M._tier = nil

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function expand_home(path)
	if path:sub(1, 1) == "~" then
		local home = os.getenv("HOME") or ""
		return home .. path:sub(2)
	end
	return path
end

local function mkdir_p(path)
	os.execute('mkdir -p "' .. path:gsub('"', '\\"') .. '"')
end

-- ── Tier 1: libsecret (Linux) ─────────────────────────────────────────────────

local function try_libsecret()
	local ok, lib = pcall(ffi.load, "secret-1")
	if not ok then return nil end

	local ok2 = pcall(ffi.cdef, [[
		typedef int            GError;
		typedef int            gboolean;
		typedef unsigned int   guint32;
		typedef void*          gpointer;

		typedef struct {
			const char *name;
			const char *description;
			const char *label;
			guint32     flags;
		} SecretSchema;

		gboolean secret_password_store_sync(
			const SecretSchema *schema,
			const char         *collection,
			const char         *label,
			const char         *password,
			gpointer            cancellable,
			GError            **error,
			const char         *attribute_name,
			const char         *attribute_value,
			...
		);

		char *secret_password_lookup_sync(
			const SecretSchema *schema,
			gpointer            cancellable,
			GError            **error,
			const char         *attribute_name,
			const char         *attribute_value,
			...
		);

		gboolean secret_password_clear_sync(
			const SecretSchema *schema,
			gpointer            cancellable,
			GError            **error,
			const char         *attribute_name,
			const char         *attribute_value,
			...
		);

		void secret_password_free(char *password);
	]])
	if not ok2 then return nil end

	local schema = ffi.new("SecretSchema", {
		name        = "zone.rhi.crescent",
		description = "Crescent API key",
		label       = "Crescent secret",
		flags       = 0,
	})

	local COLLECTION_DEFAULT = "default"

	local function err_ptr()
		return ffi.new("GError*[1]", { nil })
	end

	local tier = {}

	function tier.set(service, value)
		local errp = err_ptr()
		local label = "crescent: " .. service
		local ok = lib.secret_password_store_sync(
			schema, COLLECTION_DEFAULT, label, value, nil, errp,
			"service", service, nil
		)
		if ok == 0 then
			return nil, "libsecret: store failed"
		end
		return true
	end

	function tier.get(service)
		local errp = err_ptr()
		local pw = lib.secret_password_lookup_sync(
			schema, nil, errp,
			"service", service, nil
		)
		if pw == nil then
			return nil
		end
		local s = ffi.string(pw)
		lib.secret_password_free(pw)
		return s
	end

	function tier.delete(service)
		local errp = err_ptr()
		local ok = lib.secret_password_clear_sync(
			schema, nil, errp,
			"service", service, nil
		)
		if ok == 0 then
			return nil, "libsecret: clear failed"
		end
		return true
	end

	return tier
end

-- ── Tier 2: macOS Security.framework ─────────────────────────────────────────

local function try_keychain()
	local ok, lib = pcall(ffi.load, "Security")
	if not ok then return nil end

	local ok2 = pcall(ffi.cdef, [[
		typedef int            OSStatus;
		typedef unsigned int   UInt32;
		typedef void*          SecKeychainRef;
		typedef void*          SecKeychainItemRef;

		OSStatus SecKeychainAddGenericPassword(
			SecKeychainRef  keychain,
			UInt32          serviceNameLength,
			const char     *serviceName,
			UInt32          accountNameLength,
			const char     *accountName,
			UInt32          passwordLength,
			const void     *passwordData,
			SecKeychainItemRef *itemRef
		);

		OSStatus SecKeychainFindGenericPassword(
			SecKeychainRef   keychain,
			UInt32           serviceNameLength,
			const char      *serviceName,
			UInt32           accountNameLength,
			const char      *accountName,
			UInt32          *passwordLength,
			void           **passwordData,
			SecKeychainItemRef *itemRef
		);

		OSStatus SecKeychainItemDelete(SecKeychainItemRef itemRef);

		void SecKeychainItemFreeContent(void *attrList, void *data);

		void CFRelease(void *cf);
	]])
	if not ok2 then return nil end

	local errSecDuplicateItem = -25299
	local ACCOUNT = "crescent"

	local tier = {}

	function tier.set(service, value)
		local vlen = #value
		local slen = #service
		local alen = #ACCOUNT
		local item_ref = ffi.new("SecKeychainItemRef[1]")
		local st = lib.SecKeychainAddGenericPassword(
			nil, slen, service, alen, ACCOUNT, vlen, value, item_ref
		)
		if st == errSecDuplicateItem then
			local plen  = ffi.new("UInt32[1]")
			local pdata = ffi.new("void*[1]")
			local iref  = ffi.new("SecKeychainItemRef[1]")
			local fst = lib.SecKeychainFindGenericPassword(
				nil, slen, service, alen, ACCOUNT, plen, pdata, iref
			)
			if fst ~= 0 then return nil, "keychain: find for update failed: " .. fst end
			lib.SecKeychainItemFreeContent(nil, pdata[0])
			lib.SecKeychainItemDelete(iref[0])
			lib.CFRelease(iref[0])
			st = lib.SecKeychainAddGenericPassword(
				nil, slen, service, alen, ACCOUNT, vlen, value, nil
			)
		end
		if st ~= 0 then return nil, "keychain: add failed: " .. st end
		return true
	end

	function tier.get(service)
		local slen  = #service
		local alen  = #ACCOUNT
		local plen  = ffi.new("UInt32[1]")
		local pdata = ffi.new("void*[1]")
		local st = lib.SecKeychainFindGenericPassword(
			nil, slen, service, alen, ACCOUNT, plen, pdata, nil
		)
		if st ~= 0 then return nil end
		local s = ffi.string(ffi.cast("const char*", pdata[0]), plen[0])
		lib.SecKeychainItemFreeContent(nil, pdata[0])
		return s
	end

	function tier.delete(service)
		local slen  = #service
		local alen  = #ACCOUNT
		local iref  = ffi.new("SecKeychainItemRef[1]")
		local st = lib.SecKeychainFindGenericPassword(
			nil, slen, service, alen, ACCOUNT, nil, nil, iref
		)
		if st ~= 0 then return nil, "keychain: item not found" end
		local dst = lib.SecKeychainItemDelete(iref[0])
		lib.CFRelease(iref[0])
		if dst ~= 0 then return nil, "keychain: delete failed: " .. dst end
		return true
	end

	return tier
end

-- ── Tier 3: Encrypted file fallback (SHA-256-CTR + HMAC-SHA-256, pure LuaJIT) ─
--
-- Uses lib.hash.sha256 (ships with crescent — pure Lua fallback always available).
--
-- Encryption scheme:
--   key   = SHA-256(machine_id)                         (32 bytes)
--   enc_k = SHA-256(key || "enc")                       (32 bytes, encryption subkey)
--   mac_k = SHA-256(key || "mac")                       (32 bytes, MAC subkey)
--   iv    = 16 random bytes (from os.time + math.random, not cryptographically
--           strong, but sufficient given the key is already machine-specific)
--   keystream[n] = SHA-256(enc_k || iv || uint32_le(n)) (32 bytes per block)
--   ciphertext   = plaintext XOR keystream
--   tag          = HMAC-SHA256(mac_k, iv || ciphertext) (32 bytes)
--   payload      = tag (32) || iv (16) || ciphertext
--
-- Layout of ~/.crescent/keyring.enc (binary):
--   4 bytes  magic "CKR2"
--   4 bytes  number of entries (uint32 LE)
--   [per entry]:
--     2 bytes  service length (uint16 LE)
--     N bytes  service name (UTF-8)
--     4 bytes  payload length (uint32 LE)
--     P bytes  payload (tag || iv || ciphertext)

local function try_file_tier()
	local ok, sha256_mod = pcall(require, "lib.hash.sha256")
	if not ok then return nil end
	local sha256_hex = sha256_mod.sha256
	if not sha256_hex then return nil end

	local bit = require("bit")
	local bxor  = bit.bxor
	local band  = bit.band
	local rshift = bit.rshift

	-- hex_to_bin(hex) -> binary string (32 bytes for a sha256 output)
	local function hex_to_bin(hex)
		return (hex:gsub("%x%x", function(h)
			return string.char(tonumber(h, 16))
		end))
	end

	-- sha256_bin(s) -> 32-byte binary string
	local function sha256_bin(s)
		return hex_to_bin(sha256_hex(s))
	end

	-- hmac_sha256_bin(key, msg) -> 32-byte binary string
	-- Standard HMAC construction: H((k XOR opad) || H((k XOR ipad) || msg))
	local function hmac_sha256_bin(key, msg)
		-- Normalise key to 32 bytes (sha256 block = 64, key is always 32 here).
		if #key > 64 then key = sha256_bin(key) end
		while #key < 64 do key = key .. "\0" end

		local ipad_k = {}
		local opad_k = {}
		for i = 1, 64 do
			local b = key:byte(i)
			ipad_k[i] = string.char(bxor(b, 0x36))
			opad_k[i] = string.char(bxor(b, 0x5c))
		end
		local ipad = table.concat(ipad_k)
		local opad = table.concat(opad_k)
		local inner = sha256_bin(ipad .. msg)
		return sha256_bin(opad .. inner)
	end

	-- pack_u32_le(n) -> 4-byte string
	local function pack_u32_le(n)
		local b0 = band(n, 0xff)
		local b1 = band(rshift(n, 8), 0xff)
		local b2 = band(rshift(n, 16), 0xff)
		local b3 = band(rshift(n, 24), 0xff)
		return string.char(b0, b1, b2, b3)
	end

	local MAGIC   = "CKR2"
	local IV_LEN  = 16
	local TAG_LEN = 32  -- HMAC-SHA256

	-- Pseudo-random IV: combine os.time + math.random + an ever-increasing
	-- counter.  Not cryptographically strong, but each key is already
	-- machine-derived so attacker needs local access anyway.
	local iv_counter = 0
	local function make_iv()
		iv_counter = iv_counter + 1
		math.randomseed(os.time() + iv_counter)
		local parts = {}
		for i = 1, IV_LEN do
			parts[i] = string.char(math.random(0, 255))
		end
		return table.concat(parts)
	end

	local keyring_dir  = expand_home("~/.crescent")
	local keyring_path = keyring_dir .. "/keyring.enc"

	-- machine_key() -> 32-byte binary string
	local function machine_key()
		local id
		local f = io.open("/etc/machine-id", "r")
		if f then
			id = f:read("*l") or ""
			f:close()
		else
			local p = io.popen("ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | awk '/IOPlatformUUID/{print $3}'")
			if p then
				id = p:read("*l") or ""
				p:close()
			end
		end
		return sha256_bin(id or "")
	end

	local _key_cache
	local function get_key()
		if not _key_cache then _key_cache = machine_key() end
		return _key_cache
	end

	-- encrypt(plaintext, key) -> payload | nil, err
	-- payload = tag(32) || iv(16) || ciphertext
	local function encrypt(plaintext, key)
		local enc_k = sha256_bin(key .. "enc")
		local mac_k = sha256_bin(key .. "mac")

		local iv = make_iv()

		-- Generate keystream and XOR with plaintext.
		local pt_len = #plaintext
		local ct_parts = {}
		local pos = 1
		local blk = 0
		while pos <= pt_len do
			local ks = sha256_bin(enc_k .. iv .. pack_u32_le(blk))
			local chunk_end = math.min(pos + 31, pt_len)
			local chunk = {}
			for i = pos, chunk_end do
				local ks_byte = ks:byte(i - pos + 1)
				chunk[#chunk + 1] = string.char(bxor(plaintext:byte(i), ks_byte))
			end
			ct_parts[#ct_parts + 1] = table.concat(chunk)
			pos = chunk_end + 1
			blk = blk + 1
		end
		local ct = table.concat(ct_parts)

		local tag = hmac_sha256_bin(mac_k, iv .. ct)
		return tag .. iv .. ct
	end

	-- decrypt(payload, key) -> plaintext | nil, err
	local function decrypt(payload, key)
		if #payload < TAG_LEN + IV_LEN then
			return nil, "keyring: payload too short"
		end
		local tag_stored = payload:sub(1, TAG_LEN)
		local iv         = payload:sub(TAG_LEN + 1, TAG_LEN + IV_LEN)
		local ct         = payload:sub(TAG_LEN + IV_LEN + 1)

		local enc_k = sha256_bin(key .. "enc")
		local mac_k = sha256_bin(key .. "mac")

		-- Verify MAC before decrypting (authenticate-then-decrypt).
		local tag_expected = hmac_sha256_bin(mac_k, iv .. ct)
		if tag_expected ~= tag_stored then
			return nil, "keyring: authentication failed (bad key or corrupted data)"
		end

		-- Decrypt.
		local ct_len = #ct
		local pt_parts = {}
		local pos = 1
		local blk = 0
		while pos <= ct_len do
			local ks = sha256_bin(enc_k .. iv .. pack_u32_le(blk))
			local chunk_end = math.min(pos + 31, ct_len)
			local chunk = {}
			for i = pos, chunk_end do
				chunk[#chunk + 1] = string.char(bxor(ct:byte(i), ks:byte(i - pos + 1)))
			end
			pt_parts[#pt_parts + 1] = table.concat(chunk)
			pos = chunk_end + 1
			blk = blk + 1
		end
		return table.concat(pt_parts)
	end

	-- ── File format helpers ───────────────────────────────────────────────────

	local function pack_u16_le(n)
		return string.char(n % 256, math.floor(n / 256) % 256)
	end

	local function unpack_u16_le(s, pos)
		local b0, b1 = s:byte(pos, pos + 1)
		return b0 + b1 * 256, pos + 2
	end

	local function unpack_u32_le(s, pos)
		local b0, b1, b2, b3 = s:byte(pos, pos + 3)
		return b0 + b1 * 256 + b2 * 65536 + b3 * 16777216, pos + 4
	end

	local function load_entries()
		local f = io.open(keyring_path, "rb")
		if not f then return {} end
		local data = f:read("*a")
		f:close()

		if #data < 8 then return {} end
		if data:sub(1, 4) ~= MAGIC then return {} end

		local nentries, pos = unpack_u32_le(data, 5)
		local entries = {}
		for _ = 1, nentries do
			if pos + 2 > #data + 1 then break end
			local slen; slen, pos = unpack_u16_le(data, pos)
			if pos + slen - 1 > #data then break end
			local service = data:sub(pos, pos + slen - 1)
			pos = pos + slen
			if pos + 4 > #data + 1 then break end
			local plen; plen, pos = unpack_u32_le(data, pos)
			if pos + plen - 1 > #data then break end
			local payload = data:sub(pos, pos + plen - 1)
			pos = pos + plen
			entries[service] = payload
		end
		return entries
	end

	local function save_entries(entries)
		mkdir_p(keyring_dir)
		local parts = { MAGIC }
		local count = 0
		for _ in pairs(entries) do count = count + 1 end
		parts[#parts + 1] = pack_u32_le(count)
		for service, payload in pairs(entries) do
			parts[#parts + 1] = pack_u16_le(#service)
			parts[#parts + 1] = service
			parts[#parts + 1] = pack_u32_le(#payload)
			parts[#parts + 1] = payload
		end
		local blob = table.concat(parts)
		local tmp = keyring_path .. ".tmp"
		local f, err = io.open(tmp, "wb")
		if not f then return nil, "keyring: cannot write: " .. tostring(err) end
		f:write(blob)
		f:close()
		os.rename(tmp, keyring_path)
		return true
	end

	local tier = {}

	function tier.set(service, value)
		local key = get_key()
		local payload, err = encrypt(value, key)
		if not payload then return nil, err end
		local entries = load_entries()
		entries[service] = payload
		return save_entries(entries)
	end

	function tier.get(service)
		local key = get_key()
		local entries = load_entries()
		local payload = entries[service]
		if not payload then return nil end
		local value, err = decrypt(payload, key)
		if not value then return nil, err end
		return value
	end

	function tier.delete(service)
		local entries = load_entries()
		if not entries[service] then
			return nil, "keyring: key not found: " .. service
		end
		entries[service] = nil
		return save_entries(entries)
	end

	return tier
end

-- ── Tier selection ────────────────────────────────────────────────────────────

local backend

local function load_backend()
	if backend then return backend end

	local t = try_libsecret()
	if t then M._tier = "libsecret"; backend = t; return backend end

	t = try_keychain()
	if t then M._tier = "keychain"; backend = t; return backend end

	t = try_file_tier()
	if t then M._tier = "file"; backend = t; return backend end

	return nil
end

-- ── Public API ────────────────────────────────────────────────────────────────

function M.set(service, value)
	local b = load_backend()
	if not b then return nil, "keyring: no backend available" end
	return b.set(service, value)
end

function M.get(service)
	local b = load_backend()
	if not b then return nil, "keyring: no backend available" end
	return b.get(service)
end

function M.delete(service)
	local b = load_backend()
	if not b then return nil, "keyring: no backend available" end
	return b.delete(service)
end

return M
