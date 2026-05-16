// lib/js_caps/web_crypto_random.js
//
// Day-zero `web_crypto_random` cap implementation. Returns a fresh
// Uint8Array filled with cryptographically secure random bytes.
//
// Spec: docs/browser_caps.md §4.7.1 / §5. byte_length is bounded
// 1 <= n <= 65536 (the Web Crypto API's own max for getRandomValues).

const MAX_BYTES = 65536;

export const web_crypto_random = (byteLength) => {
  if (typeof byteLength !== "number" || !Number.isInteger(byteLength)) {
    throw new TypeError("web_crypto_random: byteLength must be an integer");
  }
  if (byteLength < 1 || byteLength > MAX_BYTES) {
    throw new TypeError(
      "web_crypto_random: byteLength must be in [1, 65536]",
    );
  }
  const buf = new Uint8Array(byteLength);
  globalThis.crypto.getRandomValues(buf);
  return buf;
};
