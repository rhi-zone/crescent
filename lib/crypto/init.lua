-- lib/crypto/init.lua
-- Cryptographic primitives: AES-256-GCM, ChaCha20-Poly1305, HKDF, random bytes.
-- Tier selection: system-libcrypto (FFI) > pure-lua. Best available wins.
--
-- Public API:
--   M.aes_gcm_encrypt(key, nonce, plaintext, aad)      -> string | (nil, errmsg)
--   M.aes_gcm_decrypt(key, nonce, ct_with_tag, aad)    -> string | (nil, errmsg)
--   M.chacha20_encrypt(key, nonce, plaintext, aad)      -> string | (nil, errmsg)
--   M.chacha20_decrypt(key, nonce, ct_with_tag, aad)    -> string | (nil, errmsg)
--   M.hkdf(ikm, salt, info, length)                     -> string | (nil, errmsg)
--   M.random_bytes(n)                                    -> string | (nil, errmsg)
--   M._tier -> "system-libcrypto" | "pure-lua"

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local ok, sys = pcall(require, "lib.crypto.system")
local impl --: unknown
if ok then
	impl = sys
else
	impl = require("lib.crypto.pure")
end
local impl_t = impl --[[:! { aes_gcm_encrypt: unknown, aes_gcm_decrypt: unknown, chacha20_encrypt: unknown, chacha20_decrypt: unknown, hkdf: unknown, random_bytes: unknown, _tier: unknown, ... }]]

--:: AeadEncrypt = (key: string, nonce: string, plaintext: string, aad: string | nil) -> (string | nil, string | nil)
--:: AeadDecrypt = (key: string, nonce: string, ct_with_tag: string, aad: string | nil) -> (string | nil, string | nil)
--:: Hkdf = (ikm: string, salt: string | nil, info: string | nil, length: integer | nil) -> (string | nil, string | nil)
--:: CryptoModule = {
--::     aes_gcm_encrypt:  AeadEncrypt,
--::     aes_gcm_decrypt:  AeadDecrypt,
--::     chacha20_encrypt: AeadEncrypt,
--::     chacha20_decrypt: AeadDecrypt,
--::     hkdf:             Hkdf,
--::     random_bytes:     unknown,
--::     _tier:            string,
--:: }
--: CryptoModule
local M = {
	aes_gcm_encrypt  = impl_t.aes_gcm_encrypt  --[[:! AeadEncrypt]],
	aes_gcm_decrypt  = impl_t.aes_gcm_decrypt  --[[:! AeadDecrypt]],
	chacha20_encrypt = impl_t.chacha20_encrypt --[[:! AeadEncrypt]],
	chacha20_decrypt = impl_t.chacha20_decrypt --[[:! AeadDecrypt]],
	hkdf             = impl_t.hkdf             --[[:! Hkdf]],
	-- random_bytes intentionally untyped: system tier takes (n), pure tier
	-- takes (random_bytes_fn, n). Callers should branch on _tier or use the
	-- implementation directly.
	random_bytes     = impl_t.random_bytes,
	_tier            = impl_t._tier            --[[:! string]],
}

return M
