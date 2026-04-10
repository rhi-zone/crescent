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
if ok then
	return sys
end

return require("lib.crypto.pure")
