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
--   keyring.set(service, key)     -> true | nil, err
--   keyring.get(service)          -> value | nil, err
--   keyring.delete(service)       -> true | nil, err
--   keyring.list(prefix?)         -> { service, ... } | nil, err
--
-- Service name convention: "crescent/<name>"
-- M._tier: "libsecret" | "keychain" | "file" | nil (no tier loaded)

if package and not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local ffi = require("ffi")

local M = {}
M._tier = nil --: string | nil

-- ── Helpers ──────────────────────────────────────────────────────────────────

--: (path: string) -> string
local function expand_home(path)
	if path:sub(1, 1) == "~" then
		local home = os.getenv("HOME") or ""
		return home .. path:sub(2)
	end
	return path
end

--: (path: string) -> nil
local function mkdir_p(path)
	local escaped = path:gsub('"', '\\"')
	os.execute('mkdir -p "' .. escaped .. '"')
end

-- ── Tier 1: libsecret (Linux) ─────────────────────────────────────────────────

local function try_libsecret()
	local ok, lib_raw = pcall(ffi.load, "secret-1")
	if not ok then return nil end
	local lib = lib_raw --[[: any]]

	-- glib is a separate shared object; try a few names.  libsecret links glib,
	-- but LuaJIT's ffi.load uses RTLD_LOCAL so glib symbols are not visible via
	-- the libsecret handle.
	local glib --: any
	for _, name in ipairs({ "glib-2.0", "libglib-2.0.so.0", "libglib-2.0.so" }) do
		local gok, g = pcall(ffi.load, name)
		if gok then glib = g; break end
	end
	-- glib is only needed for list(); set/get/delete work without it.

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

		typedef struct _GList {
			gpointer        data;
			struct _GList  *next;
			struct _GList  *prev;
		} GList;

		typedef struct _GHashTable GHashTable;
		typedef void (*GDestroyNotify)(gpointer data);

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

		/* Search / enumeration */
		GList *secret_password_search_sync(
			const SecretSchema *schema,
			int                 flags,
			gpointer            cancellable,
			GError            **error,
			...
		);

		GHashTable *secret_retrievable_get_attributes(gpointer retrievable);

		/* glib */
		gpointer g_hash_table_lookup(GHashTable *ht, const void *key);
		void     g_hash_table_unref(GHashTable *ht);
		void     g_list_free_full(GList *list, GDestroyNotify free_func);
		void     g_object_unref(gpointer object);
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

	function tier.list(prefix)
		if not glib then
			return nil, "libsecret: glib-2.0 not loadable (required for list)"
		end
		-- Use secret_password_search_sync with no attributes and SECRET_SEARCH_ALL
		-- (bit 1) to enumerate every item matching this schema.  Each GList node's
		-- data is a SecretRetrievable*; we read its attributes hash table and
		-- extract the "service" value.  Chosen over secret_service_search_sync to
		-- keep FFI surface small (no SecretItem methods, no SecretService object).
		local errp = err_ptr()
		local glist = lib.secret_password_search_sync(
			schema, 2, nil, errp, nil
		)
		if glist == nil then
			return nil, "libsecret: search failed"
		end
		local names = {}
		local node = glist
		while node ~= nil do
			local retrievable = node.data
			if retrievable ~= nil then
				local ht = lib.secret_retrievable_get_attributes(retrievable)
				if ht ~= nil then
					local v = glib.g_hash_table_lookup(ht, "service")
					if v ~= nil then
						local s = ffi.string(ffi.cast("const char*", v) --[[: any]])
						if prefix == nil or s:sub(1, #prefix) == prefix then
							names[#names + 1] = s
						end
					end
					glib.g_hash_table_unref(ht)
				end
			end
			node = node.next
		end
		glib.g_list_free_full(glist, glib.g_object_unref)
		table.sort(names)
		return names
	end

	return tier
end

-- ── Tier 2: macOS Security.framework ─────────────────────────────────────────

local function try_keychain()
	local ok, lib_raw = pcall(ffi.load, "Security")
	if not ok then return nil end
	local lib = lib_raw --[[: any]]

	local ok2 = pcall(ffi.cdef, [[
		typedef int            OSStatus;
		typedef unsigned int   UInt32;
		typedef int            SInt32;
		typedef unsigned int   FourCharCode;
		typedef FourCharCode   SecItemClass;
		typedef FourCharCode   SecKeychainAttrType;
		typedef void*          SecKeychainRef;
		typedef void*          SecKeychainItemRef;
		typedef void*          SecKeychainSearchRef;

		typedef struct SecKeychainAttribute {
			SecKeychainAttrType tag;
			UInt32              length;
			void               *data;
		} SecKeychainAttribute;

		typedef struct SecKeychainAttributeList {
			UInt32                 count;
			SecKeychainAttribute  *attr;
		} SecKeychainAttributeList;

		typedef struct SecKeychainAttributeInfo {
			UInt32  count;
			UInt32 *tag;
			UInt32 *format;
		} SecKeychainAttributeInfo;

		OSStatus SecKeychainAddGenericPassword(
			SecKeychainRef  keychain,
			UInt32          serviceNameLength,
			const char     *serviceName,
			UInt32          accountNameLength,
			const char      *accountName,
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

		OSStatus SecKeychainSearchCreateFromAttributes(
			void                            *keychainOrArray,
			SecItemClass                     itemClass,
			const SecKeychainAttributeList  *attrList,
			SecKeychainSearchRef            *searchRef
		);

		OSStatus SecKeychainSearchCopyNext(
			SecKeychainSearchRef  searchRef,
			SecKeychainItemRef   *itemRef
		);

		OSStatus SecKeychainItemCopyAttributesAndData(
			SecKeychainItemRef          itemRef,
			SecKeychainAttributeInfo   *info,
			SecItemClass               *itemClass,
			SecKeychainAttributeList  **attrList,
			UInt32                     *length,
			void                      **outData
		);

		OSStatus SecKeychainItemFreeAttributesAndData(
			SecKeychainAttributeList *attrList,
			void                     *data
		);

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
		local s = ffi.string(ffi.cast("const char*", pdata[0]) --[[: any]], plen[0])
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

	function tier.list(prefix)
		-- Enumerate items of class kSecGenericPasswordItemClass ('genp') using
		-- the pre-CFDictionary SecKeychainSearch API.  This avoids needing extern
		-- CFStringRef constants (kSecClass, kSecAttrService, ...) which are not
		-- trivial to resolve via plain dlsym.  For each item, request the
		-- 'svce' (kSecServiceItemAttr) attribute and decode its bytes.
		local kSecGenericPasswordItemClass = 0x67656E70 -- 'genp'
		local kSecServiceItemAttr          = 0x73766365 -- 'svce'

		local search = ffi.new("SecKeychainSearchRef[1]")
		local st = lib.SecKeychainSearchCreateFromAttributes(
			nil, kSecGenericPasswordItemClass, nil, search
		)
		if st ~= 0 then return nil, "keychain: search create failed: " .. st end

		-- Ask for just the service attribute.  format=0 (kSecFormatUnknown)
		-- which returns raw bytes — good enough for a UTF-8 service name.
		local info_tags   = ffi.new("UInt32[1]", kSecServiceItemAttr)
		local info_fmts   = ffi.new("UInt32[1]", 0)
		local info        = ffi.new("SecKeychainAttributeInfo", { 1, info_tags, info_fmts })

		local names = {}
		while true do
			local iref = ffi.new("SecKeychainItemRef[1]")
			local nst  = lib.SecKeychainSearchCopyNext(search[0], iref)
			if nst ~= 0 then break end

			local attr_list = ffi.new("SecKeychainAttributeList*[1]")
			local ast = lib.SecKeychainItemCopyAttributesAndData(
				iref[0], info, nil, attr_list, nil, nil
			)
			if ast == 0 and attr_list[0] ~= nil and attr_list[0].count >= 1 then
				local a = attr_list[0].attr[0]
				if a.data ~= nil and a.length > 0 then
					local s = ffi.string(ffi.cast("const char*", a.data) --[[: any]], a.length)
					if prefix == nil or s:sub(1, #prefix) == prefix then
						names[#names + 1] = s
					end
				end
				lib.SecKeychainItemFreeAttributesAndData(attr_list[0], nil)
			end
			lib.CFRelease(iref[0])
		end
		lib.CFRelease(search[0])
		table.sort(names)
		return names
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
	local sha256_hex = (sha256_mod --[[: any]]).sha256
	if not sha256_hex then return nil end
	--: (s: string) -> string
	local function _sha256_call(s) return sha256_hex(s) end

	local bit = require("bit")
	local bxor  = bit.bxor
	local band  = bit.band
	local rshift = bit.rshift

	-- hex_to_bin(hex) -> binary string (32 bytes for a sha256 output)
	--: (hex: string) -> string
	local function hex_to_bin(hex)
		local r = hex:gsub("%x%x", function(h)
			return string.char(tonumber(h, 16) or 0)
		end) --[[: string]]
		return r
	end

	-- sha256_bin(s) -> 32-byte binary string
	--: (s: string) -> string
	local function sha256_bin(s)
		return hex_to_bin(_sha256_call(s))
	end

	-- hmac_sha256_bin(key, msg) -> 32-byte binary string
	-- Standard HMAC construction: H((k XOR opad) || H((k XOR ipad) || msg))
	--: (key: string, msg: string) -> string
	local function hmac_sha256_bin(key, msg)
		-- Normalise key to 32 bytes (sha256 block = 64, key is always 32 here).
		local k = key
		if #k > 64 then k = sha256_bin(k) end
		while #k < 64 do k = k .. "\0" end
		key = k

		local ipad_k = {}
		local opad_k = {}
		for i = 1, 64 do
			local b = key:byte(i) or 0
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
	--: (plaintext: string, key: string) -> (string | nil, string | nil)
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
				local ks_byte = ks:byte(i - pos + 1) or 0
				chunk[#chunk + 1] = string.char(bxor(plaintext:byte(i) or 0, ks_byte))
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
	--: (payload: string, key: string) -> (string | nil, string | nil)
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
				chunk[#chunk + 1] = string.char(bxor(ct:byte(i) or 0, ks:byte(i - pos + 1) or 0))
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

	--: (s: string, pos: integer) -> (integer, integer)
	local function unpack_u16_le(s, pos)
		local b0, b1 = s:byte(pos, pos + 1)
		return (b0 or 0) + (b1 or 0) * 256, pos + 2
	end

	--: (s: string, pos: integer) -> (integer, integer)
	local function unpack_u32_le(s, pos)
		local b0, b1, b2, b3 = s:byte(pos, pos + 3)
		return (b0 or 0) + (b1 or 0) * 256 + (b2 or 0) * 65536 + (b3 or 0) * 16777216, pos + 4
	end

	local function load_entries()
		local f = io.open(keyring_path, "rb")
		if not f then return {} end
		local data = f:read("*a")
		f:close()
		if data == nil then return {} end

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
		if not key then return nil, "no key" end
		local payload, err = encrypt(value, key)
		if not payload then return nil, err end
		local entries = load_entries()
		entries[service] = payload
		return save_entries(entries)
	end

	function tier.get(service)
		local key = get_key()
		if not key then return nil end
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

	function tier.list(prefix)
		local entries = load_entries()
		local names = {}
		for service in pairs(entries) do
			if prefix == nil or service:sub(1, #prefix) == prefix then
				names[#names + 1] = service
			end
		end
		table.sort(names)
		return names
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

function M.list(prefix)
	local b = load_backend()
	if not b then return nil, "keyring: no backend available" end
	if not b.list then return nil, "not supported" end
	return b.list(prefix)
end

return M
