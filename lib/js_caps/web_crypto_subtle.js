// lib/js_caps/web_crypto_subtle.js
//
// Day-zero `web_crypto_subtle` cap implementation. Exposes the host
// realm's `crypto.subtle` (SubtleCrypto) to pack realms as a single
// op-discriminated cap function.
//
// Spec: docs/browser_caps.md §4.7.2 / §5. A single cap rather than one
// cap per SubtleCrypto method because:
//   - Single cap-bridge entry stays clean.
//   - Adding new ops is additive (a new `op` value, no new bridge entry).
//   - The doc's schema is op-discriminated; this mirrors it.
//
// Validation is shallow: we check that `args` is a non-null object with
// a known `op` field and that the required per-op fields are present.
// Detailed type-checking (algorithm name validity, key usages, etc.) is
// delegated to crypto.subtle itself -- the host API surfaces clearer
// errors than a hand-rolled validator could, and re-checking would
// duplicate the spec.
//
// CryptoKey across the bridge:
//   `CryptoKey` is structured-clone-transferable per the Web Crypto
//   spec, and `globalThis.structuredClone(cryptoKey)` works in modern
//   engines (Chromium, Firefox, Safari, Node, bun's runtime). It is
//   therefore safe to return CryptoKey objects through the cap-bridge
//   postMessage boundary between same-origin realms (which is the
//   pack-host configuration). If a deployment targets a cross-origin
//   boundary that does NOT structured-clone CryptoKey, pack code can
//   work around it by using `exportKey`/`importKey` to round-trip
//   through a wire-safe format (raw/pkcs8/spki/jwk) explicitly.
//
// See caps.test.js for the round-trip verification.

const OPS = {
  __proto__: null,
  encrypt: ({ algorithm, key, data }) =>
    globalThis.crypto.subtle.encrypt(algorithm, key, data),
  decrypt: ({ algorithm, key, data }) =>
    globalThis.crypto.subtle.decrypt(algorithm, key, data),
  sign: ({ algorithm, key, data }) =>
    globalThis.crypto.subtle.sign(algorithm, key, data),
  verify: ({ algorithm, key, signature, data }) =>
    globalThis.crypto.subtle.verify(algorithm, key, signature, data),
  digest: ({ algorithm, data }) =>
    globalThis.crypto.subtle.digest(algorithm, data),
  generateKey: ({ algorithm, extractable, keyUsages }) =>
    globalThis.crypto.subtle.generateKey(algorithm, extractable, keyUsages),
  deriveKey: ({ algorithm, baseKey, derivedKeyType, extractable, keyUsages }) =>
    globalThis.crypto.subtle.deriveKey(
      algorithm, baseKey, derivedKeyType, extractable, keyUsages,
    ),
  deriveBits: ({ algorithm, baseKey, length }) =>
    globalThis.crypto.subtle.deriveBits(algorithm, baseKey, length),
  importKey: ({ format, keyData, algorithm, extractable, keyUsages }) =>
    globalThis.crypto.subtle.importKey(
      format, keyData, algorithm, extractable, keyUsages,
    ),
  exportKey: ({ format, key }) =>
    globalThis.crypto.subtle.exportKey(format, key),
  wrapKey: ({ format, key, wrappingKey, wrapAlgorithm }) =>
    globalThis.crypto.subtle.wrapKey(format, key, wrappingKey, wrapAlgorithm),
  unwrapKey: ({
    format, wrappedKey, unwrappingKey, unwrapAlgorithm,
    unwrappedKeyAlgorithm, extractable, keyUsages,
  }) =>
    globalThis.crypto.subtle.unwrapKey(
      format, wrappedKey, unwrappingKey, unwrapAlgorithm,
      unwrappedKeyAlgorithm, extractable, keyUsages,
    ),
};

const OP_REQUIRED = {
  __proto__: null,
  encrypt:     ["algorithm", "key", "data"],
  decrypt:     ["algorithm", "key", "data"],
  sign:        ["algorithm", "key", "data"],
  verify:      ["algorithm", "key", "signature", "data"],
  digest:      ["algorithm", "data"],
  generateKey: ["algorithm", "extractable", "keyUsages"],
  deriveKey:   ["algorithm", "baseKey", "derivedKeyType", "extractable", "keyUsages"],
  deriveBits:  ["algorithm", "baseKey", "length"],
  importKey:   ["format", "keyData", "algorithm", "extractable", "keyUsages"],
  exportKey:   ["format", "key"],
  wrapKey:     ["format", "key", "wrappingKey", "wrapAlgorithm"],
  unwrapKey:   [
    "format", "wrappedKey", "unwrappingKey", "unwrapAlgorithm",
    "unwrappedKeyAlgorithm", "extractable", "keyUsages",
  ],
};

const VALID_OPS = Object.keys(OP_REQUIRED);

export const web_crypto_subtle = async (args) => {
  if (args === null || typeof args !== "object") {
    throw new TypeError("web_crypto_subtle: args must be { op, ... }");
  }
  const op = args.op;
  if (typeof op !== "string") {
    throw new TypeError("web_crypto_subtle: args must be { op, ... }");
  }
  const handler = OPS[op];
  if (!handler) {
    throw new TypeError(
      "web_crypto_subtle: unknown op: " + op +
      " (valid: " + VALID_OPS.join(", ") + ")",
    );
  }
  const required = OP_REQUIRED[op];
  for (let i = 0; i < required.length; i++) {
    const field = required[i];
    if (!(field in args)) {
      throw new TypeError(
        "web_crypto_subtle: op " + op + " missing required field: " + field,
      );
    }
  }
  return handler(args);
};
