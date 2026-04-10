-- lib/crypto/system.lua
-- System tier: FFI bindings to OpenSSL libcrypto (EVP interface).
-- Provides AES-256-GCM, ChaCha20-Poly1305, HKDF, and CSPRNG.

local ffi = require("ffi")

local M = {}
M._tier = "system-libcrypto"

-- ── Load libcrypto ──────────────────────────────────────────────────────────

local lib
do
	local names = { "crypto", "libcrypto", "libcrypto.so.3", "libcrypto.so.1.1",
		"libcrypto.dylib" }
	for _, name in ipairs(names) do
		local ok, l = pcall(ffi.load, name)
		if ok then lib = l; break end
	end
	-- NixOS/Guix: libraries are not in standard ld paths.
	-- Try extracting libdir from NIX_LDFLAGS or scanning NIX_PROFILES.
	if not lib then
		local ldflags = os.getenv("NIX_LDFLAGS") or ""
		for dir in ldflags:gmatch("-L(%S+)") do
			for _, suffix in ipairs({ "/libcrypto.so.3", "/libcrypto.so" }) do
				local ok, l = pcall(ffi.load, dir .. suffix)
				if ok then lib = l; break end
			end
			if lib then break end
		end
	end
	if not lib then
		-- Try common NixOS system profile paths
		local profiles = {
			"/run/current-system/sw/lib",
			os.getenv("HOME") and (os.getenv("HOME") .. "/.nix-profile/lib") or nil,
		}
		for _, dir in ipairs(profiles) do
			for _, suffix in ipairs({ "/libcrypto.so.3", "/libcrypto.so" }) do
				local ok, l = pcall(ffi.load, dir .. suffix)
				if ok then lib = l; break end
			end
			if lib then break end
		end
	end
end
if not lib then error("libcrypto not found") end

-- ── FFI declarations ────────────────────────────────────────────────────────

ffi.cdef[[
typedef struct evp_cipher_ctx_st EVP_CIPHER_CTX;
EVP_CIPHER_CTX *EVP_CIPHER_CTX_new(void);
void EVP_CIPHER_CTX_free(EVP_CIPHER_CTX *ctx);

const void *EVP_aes_256_gcm(void);
const void *EVP_chacha20_poly1305(void);

int EVP_EncryptInit_ex(EVP_CIPHER_CTX *ctx, const void *type, void *impl,
	const unsigned char *key, const unsigned char *iv);
int EVP_EncryptUpdate(EVP_CIPHER_CTX *ctx, unsigned char *out, int *outl,
	const unsigned char *in, int inl);
int EVP_EncryptFinal_ex(EVP_CIPHER_CTX *ctx, unsigned char *out, int *outl);
int EVP_CIPHER_CTX_ctrl(EVP_CIPHER_CTX *ctx, int type, int arg, void *ptr);

int EVP_DecryptInit_ex(EVP_CIPHER_CTX *ctx, const void *type, void *impl,
	const unsigned char *key, const unsigned char *iv);
int EVP_DecryptUpdate(EVP_CIPHER_CTX *ctx, unsigned char *out, int *outl,
	const unsigned char *in, int inl);
int EVP_DecryptFinal_ex(EVP_CIPHER_CTX *ctx, unsigned char *out, int *outl);

int RAND_bytes(unsigned char *buf, int num);
]]

-- EVP_CTRL constants
local EVP_CTRL_AEAD_SET_IVLEN = 0x9
local EVP_CTRL_AEAD_GET_TAG   = 0x10
local EVP_CTRL_AEAD_SET_TAG   = 0x11

local TAG_LEN = 16

-- Scratch buffers for outl parameter
local outl_buf = ffi.new("int[1]")

-- ── Internal helpers ────────────────────────────────────────────────────────

--: (cdata, string, string, string, string?) -> (string, nil) | (nil, string)
local function aead_encrypt(cipher, key, nonce, plaintext, aad)
	local ctx = lib.EVP_CIPHER_CTX_new()
	if ctx == nil then return nil, "failed to create cipher context" end

	-- Init cipher
	if lib.EVP_EncryptInit_ex(ctx, cipher, nil, nil, nil) ~= 1 then
		lib.EVP_CIPHER_CTX_free(ctx)
		return nil, "EVP_EncryptInit_ex failed (cipher)"
	end

	-- Set IV length
	if lib.EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_IVLEN, #nonce, nil) ~= 1 then
		lib.EVP_CIPHER_CTX_free(ctx)
		return nil, "failed to set IV length"
	end

	-- Set key and nonce
	if lib.EVP_EncryptInit_ex(ctx, nil, nil, key, nonce) ~= 1 then
		lib.EVP_CIPHER_CTX_free(ctx)
		return nil, "EVP_EncryptInit_ex failed (key/nonce)"
	end

	-- AAD
	if aad and #aad > 0 then
		if lib.EVP_EncryptUpdate(ctx, nil, outl_buf, aad, #aad) ~= 1 then
			lib.EVP_CIPHER_CTX_free(ctx)
			return nil, "EVP_EncryptUpdate failed (AAD)"
		end
	end

	-- Encrypt plaintext
	local ct_buf = ffi.new("unsigned char[?]", #plaintext + 16)
	if lib.EVP_EncryptUpdate(ctx, ct_buf, outl_buf, plaintext, #plaintext) ~= 1 then
		lib.EVP_CIPHER_CTX_free(ctx)
		return nil, "EVP_EncryptUpdate failed"
	end
	local ct_len = outl_buf[0]

	-- Finalize
	if lib.EVP_EncryptFinal_ex(ctx, ct_buf + ct_len, outl_buf) ~= 1 then
		lib.EVP_CIPHER_CTX_free(ctx)
		return nil, "EVP_EncryptFinal_ex failed"
	end
	ct_len = ct_len + outl_buf[0]

	-- Get tag
	local tag_buf = ffi.new("unsigned char[?]", TAG_LEN)
	if lib.EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_GET_TAG, TAG_LEN, tag_buf) ~= 1 then
		lib.EVP_CIPHER_CTX_free(ctx)
		return nil, "failed to get tag"
	end

	lib.EVP_CIPHER_CTX_free(ctx)
	return ffi.string(ct_buf, ct_len) .. ffi.string(tag_buf, TAG_LEN)
end

--: (cdata, string, string, string, string?) -> (string, nil) | (nil, string)
local function aead_decrypt(cipher, key, nonce, ciphertext_with_tag, aad)
	if #ciphertext_with_tag < TAG_LEN then
		return nil, "ciphertext too short"
	end

	local ct_len = #ciphertext_with_tag - TAG_LEN
	local ct = ciphertext_with_tag:sub(1, ct_len)
	local tag = ciphertext_with_tag:sub(ct_len + 1)

	local ctx = lib.EVP_CIPHER_CTX_new()
	if ctx == nil then return nil, "failed to create cipher context" end

	-- Init cipher
	if lib.EVP_DecryptInit_ex(ctx, cipher, nil, nil, nil) ~= 1 then
		lib.EVP_CIPHER_CTX_free(ctx)
		return nil, "EVP_DecryptInit_ex failed (cipher)"
	end

	-- Set IV length
	if lib.EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_IVLEN, #nonce, nil) ~= 1 then
		lib.EVP_CIPHER_CTX_free(ctx)
		return nil, "failed to set IV length"
	end

	-- Set key and nonce
	if lib.EVP_DecryptInit_ex(ctx, nil, nil, key, nonce) ~= 1 then
		lib.EVP_CIPHER_CTX_free(ctx)
		return nil, "EVP_DecryptInit_ex failed (key/nonce)"
	end

	-- AAD
	if aad and #aad > 0 then
		if lib.EVP_DecryptUpdate(ctx, nil, outl_buf, aad, #aad) ~= 1 then
			lib.EVP_CIPHER_CTX_free(ctx)
			return nil, "EVP_DecryptUpdate failed (AAD)"
		end
	end

	-- Decrypt ciphertext
	local pt_buf = ffi.new("unsigned char[?]", ct_len + 16)
	if lib.EVP_DecryptUpdate(ctx, pt_buf, outl_buf, ct, ct_len) ~= 1 then
		lib.EVP_CIPHER_CTX_free(ctx)
		return nil, "EVP_DecryptUpdate failed"
	end
	local pt_len = outl_buf[0]

	-- Set expected tag
	local tag_buf = ffi.new("unsigned char[?]", TAG_LEN)
	ffi.copy(tag_buf, tag, TAG_LEN)
	if lib.EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_TAG, TAG_LEN, tag_buf) ~= 1 then
		lib.EVP_CIPHER_CTX_free(ctx)
		return nil, "failed to set tag"
	end

	-- Finalize — this verifies the tag
	if lib.EVP_DecryptFinal_ex(ctx, pt_buf + pt_len, outl_buf) ~= 1 then
		lib.EVP_CIPHER_CTX_free(ctx)
		return nil, "authentication failed"
	end
	pt_len = pt_len + outl_buf[0]

	lib.EVP_CIPHER_CTX_free(ctx)
	return ffi.string(pt_buf, pt_len)
end

-- ── AES-256-GCM ─────────────────────────────────────────────────────────────

local aes_gcm_cipher = lib.EVP_aes_256_gcm()

--: (string, string, string, string?) -> (string, nil) | (nil, string)
function M.aes_gcm_encrypt(key, nonce, plaintext, aad)
	if #key ~= 32 then return nil, "key must be 32 bytes" end
	if #nonce ~= 12 then return nil, "nonce must be 12 bytes" end
	return aead_encrypt(aes_gcm_cipher, key, nonce, plaintext, aad)
end

--: (string, string, string, string?) -> (string, nil) | (nil, string)
function M.aes_gcm_decrypt(key, nonce, ciphertext_with_tag, aad)
	if #key ~= 32 then return nil, "key must be 32 bytes" end
	if #nonce ~= 12 then return nil, "nonce must be 12 bytes" end
	return aead_decrypt(aes_gcm_cipher, key, nonce, ciphertext_with_tag, aad)
end

-- ── ChaCha20-Poly1305 ──────────────────────────────────────────────────────

local chacha_cipher = lib.EVP_chacha20_poly1305()

--: (string, string, string, string?) -> (string, nil) | (nil, string)
function M.chacha20_encrypt(key, nonce, plaintext, aad)
	if #key ~= 32 then return nil, "key must be 32 bytes" end
	if #nonce ~= 12 then return nil, "nonce must be 12 bytes" end
	return aead_encrypt(chacha_cipher, key, nonce, plaintext, aad)
end

--: (string, string, string, string?) -> (string, nil) | (nil, string)
function M.chacha20_decrypt(key, nonce, ciphertext_with_tag, aad)
	if #key ~= 32 then return nil, "key must be 32 bytes" end
	if #nonce ~= 12 then return nil, "nonce must be 12 bytes" end
	return aead_decrypt(chacha_cipher, key, nonce, ciphertext_with_tag, aad)
end

-- ── HKDF (RFC 5869) using HMAC-SHA256 ───────────────────────────────────────

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local hmac = require("lib.hash.hmac")

-- Convert hex string to raw bytes.
--: (string) -> string
local function hex_to_bytes(hex)
	return (hex:gsub("..", function(h) return string.char(tonumber(h, 16)) end))
end

-- HMAC-SHA256 returning raw binary bytes.
--: (string, string) -> string
local function hmac_sha256_bin(key, msg)
	return hmac.sha256_binary(key, msg)
end

--: (string, string?, string?, number?) -> (string, nil) | (nil, string)
function M.hkdf(ikm, salt, info, length)
	length = length or 32
	info = info or ""
	if length > 255 * 32 then return nil, "length too large (max 8160)" end
	if length <= 0 then return nil, "length must be positive" end

	-- HKDF-Extract
	if not salt or #salt == 0 then
		salt = string.rep("\0", 32)
	end
	local prk = hmac_sha256_bin(salt, ikm)

	-- HKDF-Expand
	local t = ""
	local okm = {}
	local n = math.ceil(length / 32)
	for i = 1, n do
		t = hmac_sha256_bin(prk, t .. info .. string.char(i))
		okm[i] = t
	end
	local result = table.concat(okm)
	return result:sub(1, length)
end

-- ── Random bytes ────────────────────────────────────────────────────────────

--: (number) -> (string, nil) | (nil, string)
function M.random_bytes(n)
	if n <= 0 then return "" end
	local buf = ffi.new("unsigned char[?]", n)
	if lib.RAND_bytes(buf, n) ~= 1 then
		return nil, "RAND_bytes failed"
	end
	return ffi.string(buf, n)
end

return M
