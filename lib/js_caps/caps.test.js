// lib/js_caps/caps.test.js
//
// Self-tests for the day-zero cap implementations in lib/js_caps/. Run:
//
//   bun lib/js_caps/caps.test.js
//
// Each cap gets happy-path, validation-failure, and boundary tests.
// The dayZeroCaps aggregator is verified to contain exactly the
// names listed in docs/browser_caps.md §5 that this commit ships.

import {
  dayZeroCaps,
  text_encode,
  text_decode,
  compress,
  decompress,
  console_log,
  web_crypto_random,
  web_crypto_subtle,
  set_timeout,
  clipboard_write,
  makeFetchApi,
  makeKvCaps,
  makeUiCaps,
  buildDayZeroCapImpls,
} from "./index.js";

// ---------------------------------------------------------------------
// Tiny test harness (matches the style used in lib/js_cap_bridge tests).
// ---------------------------------------------------------------------

/** @type {{ name: string, fn: () => Promise<void> | void }[]} */
const TESTS = [];

function test(name, fn) { TESTS.push({ name, fn }); }

function eq(actual, expected, label) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) {
    throw new Error("assert eq failed (" + (label || "") + "): " +
      "expected " + e + " got " + a);
  }
}

function ok(cond, label) {
  if (!cond) throw new Error("assert ok failed: " + (label || ""));
}

function throws(fn, label) {
  try { fn(); }
  catch (e) { return e; }
  throw new Error("expected throw: " + (label || ""));
}

async function rejects(promise, label) {
  try { await promise; }
  catch (e) { return e; }
  throw new Error("expected rejection: " + (label || ""));
}

function arrayEq(a, b, label) {
  if (a.length !== b.length) {
    throw new Error("arrayEq length mismatch (" + (label || "") + "): " +
      a.length + " vs " + b.length);
  }
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) {
      throw new Error("arrayEq index " + i + " mismatch (" + (label || "") +
        "): " + a[i] + " vs " + b[i]);
    }
  }
}

// ---------------------------------------------------------------------
// text_encode
// ---------------------------------------------------------------------

test("text_encode: ascii happy path", () => {
  const out = text_encode("hello");
  ok(out instanceof Uint8Array, "returns Uint8Array");
  arrayEq(Array.from(out), [104, 101, 108, 108, 111], "ascii bytes");
});

test("text_encode: utf-8 multi-byte", () => {
  const out = text_encode("héllo");
  // é = 0xC3 0xA9
  arrayEq(Array.from(out), [104, 0xC3, 0xA9, 108, 108, 111], "utf-8 bytes");
});

test("text_encode: empty string", () => {
  const out = text_encode("");
  ok(out instanceof Uint8Array, "returns Uint8Array");
  eq(out.length, 0, "empty length");
});

test("text_encode: non-string throws TypeError", () => {
  const e = throws(() => text_encode(42), "non-string number");
  ok(e instanceof TypeError, "TypeError instance");
});

test("text_encode: null throws TypeError", () => {
  const e = throws(() => text_encode(null), "null");
  ok(e instanceof TypeError, "TypeError instance");
});

// ---------------------------------------------------------------------
// text_decode
// ---------------------------------------------------------------------

test("text_decode: ascii happy path", () => {
  const bytes = new Uint8Array([104, 105]);
  eq(text_decode(bytes), "hi", "ascii decode");
});

test("text_decode: utf-8 multi-byte", () => {
  const bytes = new Uint8Array([0xC3, 0xA9]);
  eq(text_decode(bytes), "é", "utf-8 decode");
});

test("text_decode: empty Uint8Array", () => {
  eq(text_decode(new Uint8Array(0)), "", "empty");
});

test("text_decode: fatal opt rejects invalid utf-8", async () => {
  const bytes = new Uint8Array([0xFF, 0xFF]);
  const e = throws(() => text_decode(bytes, { fatal: true }), "fatal invalid");
  ok(e !== undefined, "throws on fatal invalid input");
});

test("text_decode: non-Uint8Array throws TypeError", () => {
  const e = throws(() => text_decode("not bytes"), "string arg");
  ok(e instanceof TypeError, "TypeError instance");
});

test("text_decode: bad opts type throws TypeError", () => {
  const e = throws(() => text_decode(new Uint8Array(0), 42), "number opts");
  ok(e instanceof TypeError, "TypeError instance");
});

// ---------------------------------------------------------------------
// compress / decompress round trip
// ---------------------------------------------------------------------

test("compress + decompress: gzip round trip", async () => {
  const original = text_encode("the quick brown fox jumps over the lazy dog");
  const compressed = await compress(original, "gzip");
  ok(compressed instanceof Uint8Array, "compress returns Uint8Array");
  const back = await decompress(compressed, "gzip");
  ok(back instanceof Uint8Array, "decompress returns Uint8Array");
  eq(text_decode(back), text_decode(original), "round-trip text");
});

test("compress + decompress: deflate round trip", async () => {
  const original = text_encode("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
  const back = await decompress(await compress(original, "deflate"), "deflate");
  eq(text_decode(back), text_decode(original), "round-trip deflate");
});

test("compress + decompress: deflate-raw round trip", async () => {
  const original = text_encode("hello world");
  const back = await decompress(
    await compress(original, "deflate-raw"),
    "deflate-raw",
  );
  eq(text_decode(back), text_decode(original), "round-trip deflate-raw");
});

test("compress: bad format throws TypeError", async () => {
  const e = await rejects(compress(new Uint8Array(0), "bzip2"), "bad format");
  ok(e instanceof TypeError, "TypeError instance");
});

test("compress: non-Uint8Array throws TypeError", async () => {
  const e = await rejects(compress("text", "gzip"), "string arg");
  ok(e instanceof TypeError, "TypeError instance");
});

test("decompress: bad format throws TypeError", async () => {
  const e = await rejects(
    decompress(new Uint8Array(0), "bzip2"),
    "bad format",
  );
  ok(e instanceof TypeError, "TypeError instance");
});

test("decompress: non-Uint8Array throws TypeError", async () => {
  const e = await rejects(decompress("text", "gzip"), "string arg");
  ok(e instanceof TypeError, "TypeError instance");
});

// ---------------------------------------------------------------------
// console_log
// ---------------------------------------------------------------------

test("console_log: returns undefined", () => {
  // Capture console.log to avoid polluting the test output.
  const orig = globalThis.console.log;
  const captured = [];
  globalThis.console.log = (...args) => { captured.push(args); };
  try {
    const r = console_log("hello", 42, { a: 1 });
    eq(r, undefined, "returns undefined");
    eq(captured.length, 1, "one log call");
    eq(captured[0][0], "[pack]", "prefix is [pack]");
    eq(captured[0][1], "hello", "string passthrough");
    eq(captured[0][2], "42", "number stringified");
    eq(captured[0][3], '{"a":1}', "object stringified");
  } finally {
    globalThis.console.log = orig;
  }
});

test("console_log: cycles do not throw", () => {
  const orig = globalThis.console.log;
  globalThis.console.log = () => {};
  try {
    const cycle = {};
    cycle.self = cycle;
    const r = console_log(cycle);
    eq(r, undefined, "returns undefined on cycle");
  } finally {
    globalThis.console.log = orig;
  }
});

// ---------------------------------------------------------------------
// web_crypto_random
// ---------------------------------------------------------------------

test("web_crypto_random: small length", () => {
  const out = web_crypto_random(16);
  ok(out instanceof Uint8Array, "returns Uint8Array");
  eq(out.length, 16, "length matches");
});

test("web_crypto_random: max length 65536", () => {
  const out = web_crypto_random(65536);
  eq(out.length, 65536, "max length");
});

test("web_crypto_random: length 0 rejected", () => {
  const e = throws(() => web_crypto_random(0), "zero");
  ok(e instanceof TypeError, "TypeError instance");
});

test("web_crypto_random: length 65537 rejected", () => {
  const e = throws(() => web_crypto_random(65537), "overflow");
  ok(e instanceof TypeError, "TypeError instance");
});

test("web_crypto_random: non-integer rejected", () => {
  const e = throws(() => web_crypto_random(1.5), "fractional");
  ok(e instanceof TypeError, "TypeError instance");
});

test("web_crypto_random: non-number rejected", () => {
  const e = throws(() => web_crypto_random("16"), "string");
  ok(e instanceof TypeError, "TypeError instance");
});

test("web_crypto_random: independent draws differ", () => {
  // Probabilistic but overwhelmingly safe at 32 bytes.
  const a = web_crypto_random(32);
  const b = web_crypto_random(32);
  let same = true;
  for (let i = 0; i < 32; i++) if (a[i] !== b[i]) { same = false; break; }
  ok(!same, "two draws are not identical");
});

// ---------------------------------------------------------------------
// set_timeout
// ---------------------------------------------------------------------

test("set_timeout: resolves after delay", async () => {
  const t0 = Date.now();
  await set_timeout(50);
  const elapsed = Date.now() - t0;
  ok(elapsed >= 40, "elapsed >= 40ms (got " + elapsed + ")");
  ok(elapsed < 200, "elapsed < 200ms (got " + elapsed + ")");
});

test("set_timeout: zero delay resolves promptly", async () => {
  const t0 = Date.now();
  await set_timeout(0);
  const elapsed = Date.now() - t0;
  ok(elapsed < 100, "zero delay elapsed < 100ms (got " + elapsed + ")");
});

test("set_timeout: negative delay throws TypeError", () => {
  const e = throws(() => set_timeout(-1), "negative");
  ok(e instanceof TypeError, "TypeError instance");
});

test("set_timeout: Infinity delay throws TypeError", () => {
  const e = throws(() => set_timeout(Infinity), "infinity");
  ok(e instanceof TypeError, "TypeError instance");
});

test("set_timeout: NaN delay throws TypeError", () => {
  const e = throws(() => set_timeout(NaN), "nan");
  ok(e instanceof TypeError, "TypeError instance");
});

test("set_timeout: string delay throws TypeError", () => {
  const e = throws(() => set_timeout("100"), "string");
  ok(e instanceof TypeError, "TypeError instance");
});

test("set_timeout: AbortSignal cancellation rejects with AbortError", async () => {
  const controller = new AbortController();
  const p = set_timeout(5000, { signal: controller.signal });
  globalThis.setTimeout(() => controller.abort(), 50);
  const e = await rejects(p, "cancellation");
  ok(e instanceof Error, "Error instance");
  eq(e.name, "AbortError", "name is AbortError");
});

test("set_timeout: pre-aborted signal rejects immediately", async () => {
  const controller = new AbortController();
  controller.abort();
  const t0 = Date.now();
  const e = await rejects(
    set_timeout(5000, { signal: controller.signal }),
    "pre-aborted",
  );
  const elapsed = Date.now() - t0;
  eq(e.name, "AbortError", "name is AbortError");
  ok(elapsed < 100, "rejects without waiting (got " + elapsed + "ms)");
});

test("set_timeout: signal aborted after fire is a no-op", async () => {
  const controller = new AbortController();
  await set_timeout(20, { signal: controller.signal });
  // Timer already resolved; aborting now should not throw or affect the
  // already-settled promise.
  controller.abort();
  // Sleep a beat to let any erroneous microtasks fire.
  await set_timeout(10);
  ok(true, "no throw after post-fire abort");
});

test("set_timeout: invalid opts.signal throws TypeError", () => {
  const e = throws(
    () => set_timeout(100, { signal: "not a signal" }),
    "string signal",
  );
  ok(e instanceof TypeError, "TypeError instance");
});

test("set_timeout: non-constructable", () => {
  // Arrow functions and concise methods lack [[Construct]] -- new must throw.
  const e = throws(() => { new set_timeout(0); }, "new set_timeout");
  ok(e instanceof TypeError, "TypeError instance");
});

// ---------------------------------------------------------------------
// dayZeroCaps aggregation
// ---------------------------------------------------------------------

// ---------------------------------------------------------------------
// web_crypto_subtle
// ---------------------------------------------------------------------

test("web_crypto_subtle: digest happy path SHA-256", async () => {
  const data = text_encode("hello");
  const digest = await web_crypto_subtle({
    op: "digest", algorithm: "SHA-256", data,
  });
  ok(digest instanceof ArrayBuffer, "returns ArrayBuffer");
  eq(digest.byteLength, 32, "SHA-256 is 32 bytes");
});

test("web_crypto_subtle: unknown op throws TypeError", async () => {
  const e = await rejects(
    web_crypto_subtle({ op: "bogus" }),
    "unknown op",
  );
  ok(e instanceof TypeError, "TypeError instance");
});

test("web_crypto_subtle: null args throws TypeError", async () => {
  const e = await rejects(web_crypto_subtle(null), "null args");
  ok(e instanceof TypeError, "TypeError instance");
});

test("web_crypto_subtle: missing op throws TypeError", async () => {
  const e = await rejects(web_crypto_subtle({}), "no op");
  ok(e instanceof TypeError, "TypeError instance");
});

test("web_crypto_subtle: missing required field throws TypeError", async () => {
  const e = await rejects(
    web_crypto_subtle({ op: "digest", algorithm: "SHA-256" }),
    "missing data",
  );
  ok(e instanceof TypeError, "TypeError instance");
});

test("web_crypto_subtle: generateKey + encrypt + decrypt round trip", async () => {
  const key = await web_crypto_subtle({
    op: "generateKey",
    algorithm: { name: "AES-GCM", length: 256 },
    extractable: false,
    keyUsages: ["encrypt", "decrypt"],
  });
  ok(key !== null && typeof key === "object", "key is an object");
  const iv = web_crypto_random(12);
  const plaintext = text_encode("attack at dawn");
  const ciphertext = await web_crypto_subtle({
    op: "encrypt",
    algorithm: { name: "AES-GCM", iv },
    key,
    data: plaintext,
  });
  ok(ciphertext instanceof ArrayBuffer, "ciphertext is ArrayBuffer");
  const recovered = await web_crypto_subtle({
    op: "decrypt",
    algorithm: { name: "AES-GCM", iv },
    key,
    data: ciphertext,
  });
  eq(
    text_decode(new Uint8Array(recovered)),
    "attack at dawn",
    "round-trip plaintext matches",
  );
});

test("web_crypto_subtle: sign + verify HMAC", async () => {
  const key = await web_crypto_subtle({
    op: "generateKey",
    algorithm: { name: "HMAC", hash: "SHA-256" },
    extractable: true,
    keyUsages: ["sign", "verify"],
  });
  const data = text_encode("message to authenticate");
  const sig = await web_crypto_subtle({
    op: "sign", algorithm: { name: "HMAC" }, key, data,
  });
  ok(sig instanceof ArrayBuffer, "signature is ArrayBuffer");
  const okSig = await web_crypto_subtle({
    op: "verify",
    algorithm: { name: "HMAC" },
    key,
    signature: sig,
    data,
  });
  eq(okSig, true, "signature verifies");
  const tampered = text_encode("message tampered with");
  const badSig = await web_crypto_subtle({
    op: "verify",
    algorithm: { name: "HMAC" },
    key,
    signature: sig,
    data: tampered,
  });
  eq(badSig, false, "tampered data fails verify");
});

test("web_crypto_subtle: importKey + exportKey jwk round trip", async () => {
  const original = await web_crypto_subtle({
    op: "generateKey",
    algorithm: { name: "HMAC", hash: "SHA-256" },
    extractable: true,
    keyUsages: ["sign", "verify"],
  });
  const jwk = await web_crypto_subtle({
    op: "exportKey", format: "jwk", key: original,
  });
  ok(jwk !== null && typeof jwk === "object", "jwk is an object");
  const reimported = await web_crypto_subtle({
    op: "importKey",
    format: "jwk",
    keyData: jwk,
    algorithm: { name: "HMAC", hash: "SHA-256" },
    extractable: true,
    keyUsages: ["sign", "verify"],
  });
  // Use both keys to sign the same data; signatures must match.
  const data = text_encode("compare");
  const s1 = await web_crypto_subtle({
    op: "sign", algorithm: { name: "HMAC" }, key: original, data,
  });
  const s2 = await web_crypto_subtle({
    op: "sign", algorithm: { name: "HMAC" }, key: reimported, data,
  });
  arrayEq(
    Array.from(new Uint8Array(s1)),
    Array.from(new Uint8Array(s2)),
    "reimported key produces same HMAC",
  );
});

test("web_crypto_subtle: deriveKey via PBKDF2", async () => {
  const password = text_encode("correct horse battery staple");
  const baseKey = await web_crypto_subtle({
    op: "importKey",
    format: "raw",
    keyData: password,
    algorithm: { name: "PBKDF2" },
    extractable: false,
    keyUsages: ["deriveKey", "deriveBits"],
  });
  const salt = web_crypto_random(16);
  const derived = await web_crypto_subtle({
    op: "deriveKey",
    algorithm: {
      name: "PBKDF2", salt, iterations: 1000, hash: "SHA-256",
    },
    baseKey,
    derivedKeyType: { name: "AES-GCM", length: 256 },
    extractable: false,
    keyUsages: ["encrypt", "decrypt"],
  });
  ok(derived !== null && typeof derived === "object",
    "derived key is an object");
  // Use it to round-trip something so we know it's a valid AES-GCM key.
  const iv = web_crypto_random(12);
  const ct = await web_crypto_subtle({
    op: "encrypt",
    algorithm: { name: "AES-GCM", iv },
    key: derived,
    data: text_encode("ok"),
  });
  const pt = await web_crypto_subtle({
    op: "decrypt",
    algorithm: { name: "AES-GCM", iv },
    key: derived,
    data: ct,
  });
  eq(text_decode(new Uint8Array(pt)), "ok", "derived key encrypts/decrypts");
});

test("web_crypto_subtle: wrapKey + unwrapKey round trip", async () => {
  // Wrapping key (AES-KW).
  const wrappingKey = await web_crypto_subtle({
    op: "generateKey",
    algorithm: { name: "AES-KW", length: 256 },
    extractable: false,
    keyUsages: ["wrapKey", "unwrapKey"],
  });
  // Subject key (HMAC, extractable so it can be wrapped).
  const subject = await web_crypto_subtle({
    op: "generateKey",
    algorithm: { name: "HMAC", hash: "SHA-256" },
    extractable: true,
    keyUsages: ["sign", "verify"],
  });
  const wrapped = await web_crypto_subtle({
    op: "wrapKey",
    format: "raw",
    key: subject,
    wrappingKey,
    wrapAlgorithm: { name: "AES-KW" },
  });
  ok(wrapped instanceof ArrayBuffer, "wrapped is ArrayBuffer");
  const unwrapped = await web_crypto_subtle({
    op: "unwrapKey",
    format: "raw",
    wrappedKey: wrapped,
    unwrappingKey: wrappingKey,
    unwrapAlgorithm: { name: "AES-KW" },
    unwrappedKeyAlgorithm: { name: "HMAC", hash: "SHA-256" },
    extractable: true,
    keyUsages: ["sign", "verify"],
  });
  // Sign with both, signatures must match (HMAC is deterministic over key+data).
  const data = text_encode("wrap-test");
  const s1 = await web_crypto_subtle({
    op: "sign", algorithm: { name: "HMAC" }, key: subject, data,
  });
  const s2 = await web_crypto_subtle({
    op: "sign", algorithm: { name: "HMAC" }, key: unwrapped, data,
  });
  arrayEq(
    Array.from(new Uint8Array(s1)),
    Array.from(new Uint8Array(s2)),
    "unwrapped key signs identically",
  );
});

test("web_crypto_subtle: non-constructable", () => {
  const e = throws(() => { new web_crypto_subtle({ op: "digest" }); },
    "new web_crypto_subtle");
  ok(e instanceof TypeError, "TypeError instance");
});

test("web_crypto_subtle: CryptoKey survives structured clone", async () => {
  // Per the Web Crypto spec, CryptoKey is structured-clone-transferable.
  // The cap-bridge ferries cap return values through postMessage, which
  // uses the structured-clone algorithm. Verify the host runtime
  // implements that contract -- if it doesn't, packs must round-trip
  // through exportKey/importKey on a wire-safe format instead.
  const key = await web_crypto_subtle({
    op: "generateKey",
    algorithm: { name: "HMAC", hash: "SHA-256" },
    extractable: true,
    keyUsages: ["sign", "verify"],
  });
  let cloned;
  try {
    cloned = globalThis.structuredClone(key);
  } catch (e) {
    throw new Error(
      "CryptoKey did NOT survive structured clone in this runtime: " +
      (e && e.message || e) +
      " -- packs in this environment must use exportKey/importKey to " +
      "cross the cap-bridge boundary.",
    );
  }
  ok(cloned !== null && typeof cloned === "object",
    "cloned value is an object");
  // The cloned key must still work for crypto.subtle calls.
  const data = text_encode("clone-test");
  const sig = await web_crypto_subtle({
    op: "sign", algorithm: { name: "HMAC" }, key: cloned, data,
  });
  ok(sig instanceof ArrayBuffer, "cloned key signs successfully");
});

// ---------------------------------------------------------------------
// clipboard_write
// ---------------------------------------------------------------------
//
// bun's node:vm host does not expose a real `navigator.clipboard`. Tests
// either stub `globalThis.navigator` for happy-path / permission /
// missing-API cases, or exercise pre-stub validation paths that throw
// synchronously before the host API is consulted.

function withMockClipboard(impl, fn) {
  const origNav = globalThis.navigator;
  globalThis.navigator = { clipboard: { writeText: impl } };
  try { return fn(); }
  finally {
    if (origNav === undefined) delete globalThis.navigator;
    else globalThis.navigator = origNav;
  }
}

test("clipboard_write: non-string number throws TypeError", async () => {
  const e = await rejects(clipboard_write(123), "number arg");
  ok(e instanceof TypeError, "TypeError instance");
});

test("clipboard_write: non-string object throws TypeError", async () => {
  const e = await rejects(clipboard_write({}), "object arg");
  ok(e instanceof TypeError, "TypeError instance");
});

test("clipboard_write: null throws TypeError", async () => {
  const e = await rejects(clipboard_write(null), "null arg");
  ok(e instanceof TypeError, "TypeError instance");
});

test("clipboard_write: oversized text rejects with RangeError", async () => {
  // 1 MiB cap; 2_000_000 chars is well over it. Validation fires before
  // the host API is consulted, so no navigator stub is needed.
  const e = await rejects(
    clipboard_write("x".repeat(2_000_000)),
    "oversized text",
  );
  ok(e instanceof RangeError, "RangeError instance");
});

test("clipboard_write: happy path writes through to navigator.clipboard.writeText", async () => {
  let captured = null;
  let callCount = 0;
  const spy = (s) => {
    callCount++;
    captured = s;
    return Promise.resolve();
  };
  await withMockClipboard(spy, async () => {
    const r = await clipboard_write("hello");
    eq(r, undefined, "returns undefined");
    eq(callCount, 1, "writeText called once");
    eq(captured, "hello", "writeText received the string");
  });
});

test("clipboard_write: NotAllowedError propagates", async () => {
  const reject_impl = () =>
    Promise.reject(new DOMException("denied", "NotAllowedError"));
  await withMockClipboard(reject_impl, async () => {
    const e = await rejects(
      clipboard_write("hi"),
      "permission denied",
    );
    ok(e instanceof DOMException, "DOMException instance");
    eq(e.name, "NotAllowedError", "name is NotAllowedError");
  });
});

test("clipboard_write: missing navigator.clipboard throws clear error", async () => {
  const origNav = globalThis.navigator;
  globalThis.navigator = { clipboard: undefined };
  try {
    const e = await rejects(clipboard_write("hi"), "no clipboard");
    ok(e instanceof Error, "Error instance");
    ok(/clipboard API not available/.test(String(e.message)),
      "error mentions clipboard API");
  } finally {
    if (origNav === undefined) delete globalThis.navigator;
    else globalThis.navigator = origNav;
  }
});

test("clipboard_write: non-constructable", () => {
  // Arrow functions lack [[Construct]] -- new must throw.
  const e = throws(() => { new clipboard_write("x"); }, "new clipboard_write");
  ok(e instanceof TypeError, "TypeError instance");
});

// ---------------------------------------------------------------------
// fetch_api (factory)
// ---------------------------------------------------------------------
//
// fetch_api is config-bound at host-side instantiation (see
// docs/browser_caps.md §4.1.1 and lib/js_caps/index.js comment on the
// factory pattern). bun's node:vm host has no real network; tests stub
// `globalThis.fetch` with a minimal Response-shaped mock that exposes
// `status`, `statusText`, `headers.forEach`, and an
// `arrayBuffer()/json()/text()` body method.

function withMockFetch(impl, fn) {
  const orig = globalThis.fetch;
  globalThis.fetch = impl;
  try { return fn(); }
  finally {
    if (orig === undefined) delete globalThis.fetch;
    else globalThis.fetch = orig;
  }
}

function makeMockResponse({
  status = 200,
  statusText = "OK",
  headers = {},
  body = new Uint8Array(0),
} = {}) {
  const headersForwarder = {
    forEach(cb) {
      for (const [k, v] of Object.entries(headers)) cb(v, k);
    },
  };
  const ab = body instanceof Uint8Array ? body.buffer.slice(
    body.byteOffset, body.byteOffset + body.byteLength) : body;
  return {
    status,
    statusText,
    headers: headersForwarder,
    arrayBuffer: async () => ab,
    text: async () => new TextDecoder().decode(new Uint8Array(ab)),
    json: async () => JSON.parse(new TextDecoder().decode(new Uint8Array(ab))),
  };
}

test("fetch_api factory: null config throws TypeError", () => {
  const e = throws(() => makeFetchApi(null), "null config");
  ok(e instanceof TypeError, "TypeError instance");
});

test("fetch_api factory: non-array allowed_origins throws TypeError", () => {
  const e = throws(
    () => makeFetchApi({ allowed_origins: "not array" }),
    "string allowed_origins",
  );
  ok(e instanceof TypeError, "TypeError instance");
});

test("fetch_api factory: non-string allowed_origins entry throws TypeError", () => {
  const e = throws(
    () => makeFetchApi({ allowed_origins: [123] }),
    "number entry",
  );
  ok(e instanceof TypeError, "TypeError instance");
});

test("fetch_api: non-constructable", () => {
  const cap = makeFetchApi({ allowed_origins: [] });
  const e = throws(() => { new cap({ url: "https://x.example" }); }, "new cap");
  ok(e instanceof TypeError, "TypeError instance");
});

test("fetch_api: invalid url throws TypeError", async () => {
  const cap = makeFetchApi({ allowed_origins: ["https://api.example.com"] });
  const e = await rejects(cap({ url: "not-a-url" }), "bad url");
  ok(e instanceof TypeError, "TypeError instance");
});

test("fetch_api: missing url throws TypeError", async () => {
  const cap = makeFetchApi({ allowed_origins: ["https://api.example.com"] });
  const e = await rejects(cap({}), "no url");
  ok(e instanceof TypeError, "TypeError instance");
});

test("fetch_api: origin not in allowlist throws TypeError", async () => {
  const cap = makeFetchApi({ allowed_origins: ["https://api.example.com"] });
  const e = await rejects(
    cap({ url: "https://evil.example/x" }),
    "disallowed origin",
  );
  ok(e instanceof TypeError, "TypeError instance");
  ok(/origin not allowed/.test(String(e.message)), "message mentions origin");
});

test("fetch_api: invalid method throws TypeError", async () => {
  const cap = makeFetchApi({ allowed_origins: ["https://api.example.com"] });
  await withMockFetch(async () => makeMockResponse(), async () => {
    const e = await rejects(
      cap({ url: "https://api.example.com/x", method: "TRACE" }),
      "bad method",
    );
    ok(e instanceof TypeError, "TypeError instance");
  });
});

test("fetch_api: non-object headers throws TypeError", async () => {
  const cap = makeFetchApi({ allowed_origins: ["https://api.example.com"] });
  const e = await rejects(
    cap({ url: "https://api.example.com/x", headers: "x" }),
    "bad headers",
  );
  ok(e instanceof TypeError, "TypeError instance");
});

test("fetch_api: non-string header value throws TypeError", async () => {
  const cap = makeFetchApi({ allowed_origins: ["https://api.example.com"] });
  const e = await rejects(
    cap({ url: "https://api.example.com/x", headers: { foo: 42 } }),
    "non-string header value",
  );
  ok(e instanceof TypeError, "TypeError instance");
});

test("fetch_api: happy path returns arraybuffer body by default", async () => {
  const cap = makeFetchApi({ allowed_origins: ["https://api.example.com"] });
  let capturedUrl = null;
  let capturedInit = null;
  const mockFetch = async (url, init) => {
    capturedUrl = url;
    capturedInit = init;
    return makeMockResponse({
      status: 201,
      statusText: "Created",
      headers: { "content-type": "application/octet-stream" },
      body: new Uint8Array([1, 2, 3, 4]),
    });
  };
  await withMockFetch(mockFetch, async () => {
    const r = await cap({
      url: "https://api.example.com/path",
      method: "POST",
      headers: { "x-test": "yes" },
    });
    eq(capturedUrl, "https://api.example.com/path", "url forwarded");
    eq(capturedInit.method, "POST", "method forwarded");
    eq(capturedInit.headers["x-test"], "yes", "header forwarded");
    eq(r.status, 201, "status");
    eq(r.statusText, "Created", "statusText");
    eq(r.headers["content-type"], "application/octet-stream", "headers");
    ok(r.body instanceof ArrayBuffer, "body is ArrayBuffer");
    eq(r.body.byteLength, 4, "body length");
  });
});

test("fetch_api: responseFormat json returns decoded JSON", async () => {
  const cap = makeFetchApi({ allowed_origins: ["https://api.example.com"] });
  const payload = new TextEncoder().encode(JSON.stringify({ ok: true, n: 7 }));
  await withMockFetch(
    async () => makeMockResponse({ body: payload }),
    async () => {
      const r = await cap({
        url: "https://api.example.com/x",
        responseFormat: "json",
      });
      eq(r.body.ok, true, "json ok");
      eq(r.body.n, 7, "json n");
    },
  );
});

test("fetch_api: responseFormat text returns string", async () => {
  const cap = makeFetchApi({ allowed_origins: ["https://api.example.com"] });
  const payload = new TextEncoder().encode("hello, world");
  await withMockFetch(
    async () => makeMockResponse({ body: payload }),
    async () => {
      const r = await cap({
        url: "https://api.example.com/x",
        responseFormat: "text",
      });
      eq(typeof r.body, "string", "body is string");
      eq(r.body, "hello, world", "text body");
    },
  );
});

test("fetch_api: invalid responseFormat throws TypeError", async () => {
  const cap = makeFetchApi({ allowed_origins: ["https://api.example.com"] });
  await withMockFetch(async () => makeMockResponse(), async () => {
    const e = await rejects(
      cap({ url: "https://api.example.com/x", responseFormat: "xml" }),
      "bad responseFormat",
    );
    ok(e instanceof TypeError, "TypeError instance");
  });
});

test("fetch_api: AbortSignal propagates abort to fetch", async () => {
  const cap = makeFetchApi({ allowed_origins: ["https://api.example.com"] });
  const controller = new AbortController();
  // Mock fetch that resolves only when the signal aborts.
  const mockFetch = (url, init) => new Promise((_resolve, reject) => {
    if (init.signal && init.signal.aborted) {
      const err = new Error("aborted");
      err.name = "AbortError";
      reject(err);
      return;
    }
    init.signal && init.signal.addEventListener("abort", () => {
      const err = new Error("aborted");
      err.name = "AbortError";
      reject(err);
    }, { once: true });
  });
  await withMockFetch(mockFetch, async () => {
    const p = cap({
      url: "https://api.example.com/x",
      signal: controller.signal,
    });
    globalThis.setTimeout(() => controller.abort(), 20);
    const e = await rejects(p, "abort");
    eq(e.name, "AbortError", "AbortError");
  });
});

test("fetch_api: invalid signal throws TypeError", async () => {
  const cap = makeFetchApi({ allowed_origins: ["https://api.example.com"] });
  const e = await rejects(
    cap({ url: "https://api.example.com/x", signal: "not a signal" }),
    "bad signal",
  );
  ok(e instanceof TypeError, "TypeError instance");
});

test("fetch_api: missing globalThis.fetch throws clear error", async () => {
  const cap = makeFetchApi({ allowed_origins: ["https://api.example.com"] });
  const orig = globalThis.fetch;
  delete globalThis.fetch;
  try {
    const e = await rejects(
      cap({ url: "https://api.example.com/x" }),
      "no fetch",
    );
    ok(e instanceof Error, "Error instance");
    ok(/globalThis\.fetch is not available/.test(String(e.message)),
      "error mentions fetch");
  } finally {
    if (orig !== undefined) globalThis.fetch = orig;
  }
});

// ---------------------------------------------------------------------
// dayZeroCaps aggregation
// ---------------------------------------------------------------------

test("dayZeroCaps: contains the 9 shipped caps", () => {
  ok(dayZeroCaps instanceof Map, "is a Map");
  const expected = [
    "text_encode", "text_decode", "compress", "decompress", "console_log",
    "web_crypto_random", "web_crypto_subtle", "set_timeout", "clipboard_write",
  ];
  eq(dayZeroCaps.size, expected.length, "size matches");
  for (const name of expected) {
    ok(dayZeroCaps.has(name), "has " + name);
    ok(typeof dayZeroCaps.get(name) === "function", name + " is function");
  }
});

test("dayZeroCaps: does not contain the deferred caps", () => {
  // The eight factory-shaped caps (fetch_api / four kv_* / toast /
  // dialog / navigate) are intentionally absent from dayZeroCaps -- they
  // are config-bound per pack or per host app and the host page must
  // construct them via the factory and merge into the Map (see
  // buildDayZeroCapImpls). All seventeen day-zero caps ship as of this
  // commit; the name "deferred" survives for historical continuity but
  // really means "factory-bound, not in dayZeroCaps".
  const deferred = [
    "fetch_api", "kv_read", "kv_write", "kv_delete",
    "kv_keys", "navigate", "dialog", "toast",
  ];
  for (const name of deferred) {
    ok(!dayZeroCaps.has(name), "does not have " + name);
  }
});

// ---------------------------------------------------------------------
// kv_* (factory)
// ---------------------------------------------------------------------
//
// bun's `node:vm` realm does not expose `indexedDB`. Rather than pull
// in `fake-indexeddb` (an npm dep -- this repo has no package.json,
// adding one for one test would violate the vendoring-first rule),
// install a minimal in-memory IndexedDB mock that covers the subset
// the kv impl actually uses: `indexedDB.open` (with onupgradeneeded /
// onsuccess / onerror), `db.transaction` / `objectStore.get / put /
// delete / getAllKeys`. Structured clone is approximated by
// `structuredClone` (available in bun).

function installIdbMock() {
  /** @type {Map<string, Map<string, unknown>>} */
  const databases = new Map();

  function makeRequest() {
    const req = {
      result: /** @type {unknown} */ (undefined),
      error: /** @type {unknown} */ (null),
      onsuccess: /** @type {(() => void) | null} */ (null),
      onerror: /** @type {(() => void) | null} */ (null),
      onupgradeneeded: /** @type {(() => void) | null} */ (null),
    };
    return req;
  }

  function fireAsync(req, ok, value) {
    queueMicrotask(() => {
      if (ok) {
        req.result = value;
        if (req.onsuccess) req.onsuccess();
      } else {
        req.error = value;
        if (req.onerror) req.onerror();
      }
    });
  }

  function makeDb(name) {
    return {
      objectStoreNames: {
        contains: (n) => databases.get(name).has(n),
      },
      createObjectStore: (n) => {
        if (!databases.get(name).has(n)) databases.get(name).set(n, new Map());
        return null;
      },
      transaction: (_storeName, _mode) => {
        const data = databases.get(name).get("kv");
        return {
          objectStore: () => ({
            get: (k) => {
              const req = makeRequest();
              fireAsync(req, true, data.get(k));
              return req;
            },
            put: (value, k) => {
              const req = makeRequest();
              let cloned;
              try {
                cloned = typeof structuredClone === "function"
                  ? structuredClone(value)
                  : value;
              } catch (e) {
                fireAsync(req, false, e);
                return req;
              }
              data.set(k, cloned);
              fireAsync(req, true, undefined);
              return req;
            },
            delete: (k) => {
              const req = makeRequest();
              data.delete(k);
              fireAsync(req, true, undefined);
              return req;
            },
            getAllKeys: () => {
              const req = makeRequest();
              fireAsync(req, true, Array.from(data.keys()));
              return req;
            },
          }),
        };
      },
    };
  }

  globalThis.indexedDB = {
    open: (name, _version) => {
      const req = makeRequest();
      const isNew = !databases.has(name);
      if (isNew) databases.set(name, new Map());
      queueMicrotask(() => {
        req.result = makeDb(name);
        if (!databases.get(name).has("kv")) {
          if (req.onupgradeneeded) req.onupgradeneeded();
        }
        if (req.onsuccess) req.onsuccess();
      });
      return req;
    },
  };
  return () => { delete globalThis.indexedDB; databases.clear(); };
}

test("kv factory: null config throws TypeError", () => {
  const e = throws(() => makeKvCaps(null), "null");
  ok(e instanceof TypeError, "TypeError instance");
});

test("kv factory: non-string pack_id throws TypeError", () => {
  const e = throws(() => makeKvCaps({ pack_id: 123 }), "numeric pack_id");
  ok(e instanceof TypeError, "TypeError instance");
});

test("kv factory: empty pack_id throws TypeError", () => {
  const e = throws(() => makeKvCaps({ pack_id: "" }), "empty pack_id");
  ok(e instanceof TypeError, "TypeError instance");
});

test("kv_read: non-constructable", () => {
  const uninstall = installIdbMock();
  try {
    const caps = makeKvCaps({ pack_id: "p1" });
    const e = throws(() => new caps.kv_read("k"), "new kv_read");
    ok(e instanceof TypeError, "TypeError instance");
    const e2 = throws(() => new caps.kv_write({ key: "k", value: 1 }), "new kv_write");
    ok(e2 instanceof TypeError, "TypeError instance");
    const e3 = throws(() => new caps.kv_delete("k"), "new kv_delete");
    ok(e3 instanceof TypeError, "TypeError instance");
    const e4 = throws(() => new caps.kv_keys(), "new kv_keys");
    ok(e4 instanceof TypeError, "TypeError instance");
  } finally { uninstall(); }
});

test("kv_read: write then read roundtrip", async () => {
  const uninstall = installIdbMock();
  try {
    const caps = makeKvCaps({ pack_id: "p1" });
    await caps.kv_write({ key: "k", value: "v" });
    const got = await caps.kv_read("k");
    eq(got, "v", "roundtrip value");
  } finally { uninstall(); }
});

test("kv_read: missing key returns undefined", async () => {
  const uninstall = installIdbMock();
  try {
    const caps = makeKvCaps({ pack_id: "p1" });
    const got = await caps.kv_read("absent");
    eq(got, undefined, "absent key");
  } finally { uninstall(); }
});

test("kv_delete: removes a key", async () => {
  const uninstall = installIdbMock();
  try {
    const caps = makeKvCaps({ pack_id: "p1" });
    await caps.kv_write({ key: "k", value: "v" });
    await caps.kv_delete("k");
    const got = await caps.kv_read("k");
    eq(got, undefined, "deleted");
  } finally { uninstall(); }
});

test("kv_delete: absent key is a no-op", async () => {
  const uninstall = installIdbMock();
  try {
    const caps = makeKvCaps({ pack_id: "p1" });
    await caps.kv_delete("never-written");
    // no throw
    ok(true, "no throw");
  } finally { uninstall(); }
});

test("kv_keys: enumerates all keys", async () => {
  const uninstall = installIdbMock();
  try {
    const caps = makeKvCaps({ pack_id: "p1" });
    await caps.kv_write({ key: "a", value: 1 });
    await caps.kv_write({ key: "b", value: 2 });
    await caps.kv_write({ key: "c", value: 3 });
    const keys = await caps.kv_keys();
    eq(keys.length, 3, "three keys");
    const sorted = keys.slice().sort();
    arrayEq(sorted, ["a", "b", "c"], "all present");
  } finally { uninstall(); }
});

test("kv: structured clone preserves Uint8Array and nested shape", async () => {
  const uninstall = installIdbMock();
  try {
    const caps = makeKvCaps({ pack_id: "p1" });
    const value = { a: [1, 2], b: new Uint8Array([1, 2, 3]) };
    await caps.kv_write({ key: "blob", value });
    const got = await caps.kv_read("blob");
    ok(got && typeof got === "object", "object back");
    arrayEq(got.a, [1, 2], "array a roundtrip");
    ok(got.b instanceof Uint8Array, "Uint8Array preserved");
    arrayEq(Array.from(got.b), [1, 2, 3], "Uint8Array bytes preserved");
  } finally { uninstall(); }
});

test("kv: per-pack partitioning isolates writes by pack_id", async () => {
  const uninstall = installIdbMock();
  try {
    const a = makeKvCaps({ pack_id: "alpha" });
    const b = makeKvCaps({ pack_id: "beta" });
    await a.kv_write({ key: "shared", value: "from-alpha" });
    await b.kv_write({ key: "shared", value: "from-beta" });
    eq(await a.kv_read("shared"), "from-alpha", "alpha sees alpha");
    eq(await b.kv_read("shared"), "from-beta", "beta sees beta");
    const aKeys = await a.kv_keys();
    const bKeys = await b.kv_keys();
    eq(aKeys.length, 1, "alpha has one key");
    eq(bKeys.length, 1, "beta has one key");
  } finally { uninstall(); }
});

test("kv_read: non-string key throws TypeError", async () => {
  const uninstall = installIdbMock();
  try {
    const caps = makeKvCaps({ pack_id: "p1" });
    const e = await rejects(caps.kv_read(123), "numeric key");
    ok(e instanceof TypeError, "TypeError instance");
  } finally { uninstall(); }
});

test("kv_write: non-string key throws TypeError", async () => {
  const uninstall = installIdbMock();
  try {
    const caps = makeKvCaps({ pack_id: "p1" });
    const e = await rejects(
      caps.kv_write({ key: 1, value: 2 }),
      "numeric key",
    );
    ok(e instanceof TypeError, "TypeError instance");
  } finally { uninstall(); }
});

test("kv_write: empty key throws TypeError", async () => {
  const uninstall = installIdbMock();
  try {
    const caps = makeKvCaps({ pack_id: "p1" });
    const e = await rejects(
      caps.kv_write({ key: "", value: 1 }),
      "empty key",
    );
    ok(e instanceof TypeError, "TypeError instance");
  } finally { uninstall(); }
});

test("kv_write: oversized key throws TypeError", async () => {
  const uninstall = installIdbMock();
  try {
    const caps = makeKvCaps({ pack_id: "p1" });
    const e = await rejects(
      caps.kv_write({ key: "x".repeat(2000), value: "y" }),
      "long key",
    );
    ok(e instanceof TypeError, "TypeError instance");
  } finally { uninstall(); }
});

test("kv_write: null args throws TypeError", async () => {
  const uninstall = installIdbMock();
  try {
    const caps = makeKvCaps({ pack_id: "p1" });
    const e = await rejects(caps.kv_write(null), "null args");
    ok(e instanceof TypeError, "TypeError instance");
  } finally { uninstall(); }
});

// ---------------------------------------------------------------------
// makeUiCaps factory + toast / dialog / navigate
// ---------------------------------------------------------------------

function makeFakeUi() {
  /** @type {{ kind: string, args: unknown, returned?: unknown }[]} */
  const calls = [];
  /** @type {{ dialogReturn?: string, dialogReturnNonString?: unknown }} */
  const ctl = {};
  const ui = {
    renderToast: (args) => {
      calls.push({ kind: "renderToast", args });
    },
    renderDialog: async (args) => {
      const ret = ctl.dialogReturnNonString !== undefined
        ? ctl.dialogReturnNonString
        : (ctl.dialogReturn !== undefined ? ctl.dialogReturn : args.buttons[0]);
      calls.push({ kind: "renderDialog", args, returned: ret });
      return ret;
    },
    requestNavigate: (args) => {
      calls.push({ kind: "requestNavigate", args });
    },
  };
  return { ui, calls, ctl };
}

test("makeUiCaps factory: null uiPrimitives throws TypeError", () => {
  const e = throws(() => makeUiCaps(null), "null primitives");
  ok(e instanceof TypeError, "TypeError instance");
});

test("makeUiCaps factory: missing renderToast throws TypeError", () => {
  const e = throws(() => makeUiCaps({
    renderDialog: async () => "ok",
    requestNavigate: () => {},
  }), "missing renderToast");
  ok(e instanceof TypeError, "TypeError instance");
});

test("makeUiCaps factory: missing renderDialog throws TypeError", () => {
  const e = throws(() => makeUiCaps({
    renderToast: () => {},
    requestNavigate: () => {},
  }), "missing renderDialog");
  ok(e instanceof TypeError, "TypeError instance");
});

test("makeUiCaps factory: missing requestNavigate throws TypeError", () => {
  const e = throws(() => makeUiCaps({
    renderToast: () => {},
    renderDialog: async () => "ok",
  }), "missing requestNavigate");
  ok(e instanceof TypeError, "TypeError instance");
});

test("makeUiCaps factory: returns object with three caps", () => {
  const { ui } = makeFakeUi();
  const caps = makeUiCaps(ui);
  ok(typeof caps.toast === "function", "toast is function");
  ok(typeof caps.dialog === "function", "dialog is function");
  ok(typeof caps.navigate === "function", "navigate is function");
});

// toast --------------------------------------------------------------

test("toast: happy path calls renderToast with defaults", async () => {
  const { ui, calls } = makeFakeUi();
  const caps = makeUiCaps(ui);
  await caps.toast({ message: "hi" });
  eq(calls.length, 1, "one call");
  eq(calls[0].kind, "renderToast", "right primitive");
  eq(calls[0].args, { message: "hi", level: "info", duration: 3000 }, "default args");
});

test("toast: forwards level and duration", async () => {
  const { ui, calls } = makeFakeUi();
  const caps = makeUiCaps(ui);
  await caps.toast({ message: "warn", level: "warning", duration: 5000 });
  eq(calls[0].args, { message: "warn", level: "warning", duration: 5000 }, "forwarded");
});

test("toast: null args throws TypeError", async () => {
  const { ui } = makeFakeUi();
  const caps = makeUiCaps(ui);
  const e = await rejects(caps.toast(null), "null args");
  ok(e instanceof TypeError, "TypeError instance");
});

test("toast: missing message throws TypeError", async () => {
  const { ui } = makeFakeUi();
  const caps = makeUiCaps(ui);
  const e = await rejects(caps.toast({}), "missing message");
  ok(e instanceof TypeError, "TypeError instance");
});

test("toast: empty message throws TypeError", async () => {
  const { ui } = makeFakeUi();
  const caps = makeUiCaps(ui);
  const e = await rejects(caps.toast({ message: "" }), "empty message");
  ok(e instanceof TypeError, "TypeError instance");
});

test("toast: oversized message rejects with RangeError", async () => {
  const { ui } = makeFakeUi();
  const caps = makeUiCaps(ui);
  const e = await rejects(
    caps.toast({ message: "x".repeat(1024) }),
    "oversized",
  );
  ok(e instanceof RangeError, "RangeError instance");
});

test("toast: invalid level throws TypeError", async () => {
  const { ui } = makeFakeUi();
  const caps = makeUiCaps(ui);
  const e = await rejects(
    caps.toast({ message: "x", level: "critical" }),
    "bad level",
  );
  ok(e instanceof TypeError, "TypeError instance");
});

test("toast: negative duration rejects with RangeError", async () => {
  const { ui } = makeFakeUi();
  const caps = makeUiCaps(ui);
  const e = await rejects(
    caps.toast({ message: "x", duration: -1 }),
    "negative duration",
  );
  ok(e instanceof RangeError, "RangeError instance");
});

test("toast: Infinity duration throws TypeError", async () => {
  const { ui } = makeFakeUi();
  const caps = makeUiCaps(ui);
  const e = await rejects(
    caps.toast({ message: "x", duration: Infinity }),
    "Infinity duration",
  );
  ok(e instanceof TypeError, "TypeError instance");
});

test("toast: oversized duration rejects with RangeError", async () => {
  const { ui } = makeFakeUi();
  const caps = makeUiCaps(ui);
  const e = await rejects(
    caps.toast({ message: "x", duration: 60_000 }),
    "oversized duration",
  );
  ok(e instanceof RangeError, "RangeError instance");
});

test("toast: non-constructable", () => {
  const { ui } = makeFakeUi();
  const caps = makeUiCaps(ui);
  const e = throws(() => { new caps.toast({ message: "x" }); }, "new toast");
  ok(e instanceof TypeError, "TypeError instance");
});

// dialog -------------------------------------------------------------

test("dialog: happy path returns selected button", async () => {
  const { ui, calls, ctl } = makeFakeUi();
  ctl.dialogReturn = "yes";
  const caps = makeUiCaps(ui);
  const result = await caps.dialog({
    message: "Confirm?", buttons: ["yes", "no"],
  });
  eq(result, "yes", "returned button");
  eq(calls[0].kind, "renderDialog", "primitive called");
  eq(calls[0].args.message, "Confirm?", "message forwarded");
  arrayEq(calls[0].args.buttons, ["yes", "no"], "buttons forwarded");
});

test("dialog: host returned unknown button rejects", async () => {
  const { ui, ctl } = makeFakeUi();
  ctl.dialogReturn = "maybe";
  const caps = makeUiCaps(ui);
  const e = await rejects(
    caps.dialog({ message: "Q", buttons: ["yes", "no"] }),
    "unknown button",
  );
  ok(/host returned unknown button/.test(String(e.message)),
    "error message mentions unknown button");
});

test("dialog: host returned non-string rejects", async () => {
  const { ui, ctl } = makeFakeUi();
  ctl.dialogReturnNonString = 42;
  const caps = makeUiCaps(ui);
  const e = await rejects(
    caps.dialog({ message: "Q", buttons: ["yes"] }),
    "non-string host return",
  );
  ok(/non-string/.test(String(e.message)), "error message mentions non-string");
});

test("dialog: null args throws TypeError", async () => {
  const { ui } = makeFakeUi();
  const caps = makeUiCaps(ui);
  const e = await rejects(caps.dialog(null), "null args");
  ok(e instanceof TypeError, "TypeError instance");
});

test("dialog: missing message throws TypeError", async () => {
  const { ui } = makeFakeUi();
  const caps = makeUiCaps(ui);
  const e = await rejects(caps.dialog({ buttons: ["ok"] }), "missing message");
  ok(e instanceof TypeError, "TypeError instance");
});

test("dialog: empty buttons throws TypeError", async () => {
  const { ui } = makeFakeUi();
  const caps = makeUiCaps(ui);
  const e = await rejects(
    caps.dialog({ message: "x", buttons: [] }),
    "empty buttons",
  );
  ok(e instanceof TypeError, "TypeError instance");
});

test("dialog: non-array buttons throws TypeError", async () => {
  const { ui } = makeFakeUi();
  const caps = makeUiCaps(ui);
  const e = await rejects(
    caps.dialog({ message: "x", buttons: "ok" }),
    "non-array buttons",
  );
  ok(e instanceof TypeError, "TypeError instance");
});

test("dialog: too many buttons rejects with RangeError", async () => {
  const { ui } = makeFakeUi();
  const caps = makeUiCaps(ui);
  const e = await rejects(
    caps.dialog({ message: "x", buttons: ["a","b","c","d","e","f","g","h","i"] }),
    "9 buttons",
  );
  ok(e instanceof RangeError, "RangeError instance");
});

test("dialog: non-string button throws TypeError", async () => {
  const { ui } = makeFakeUi();
  const caps = makeUiCaps(ui);
  const e = await rejects(
    caps.dialog({ message: "x", buttons: ["ok", 1] }),
    "numeric button",
  );
  ok(e instanceof TypeError, "TypeError instance");
});

test("dialog: empty button name throws TypeError", async () => {
  const { ui } = makeFakeUi();
  const caps = makeUiCaps(ui);
  const e = await rejects(
    caps.dialog({ message: "x", buttons: ["ok", ""] }),
    "empty button name",
  );
  ok(e instanceof TypeError, "TypeError instance");
});

test("dialog: oversized message rejects with RangeError", async () => {
  const { ui } = makeFakeUi();
  const caps = makeUiCaps(ui);
  const e = await rejects(
    caps.dialog({ message: "x".repeat(2000), buttons: ["ok"] }),
    "oversized message",
  );
  ok(e instanceof RangeError, "RangeError instance");
});

test("dialog: non-constructable", () => {
  const { ui } = makeFakeUi();
  const caps = makeUiCaps(ui);
  const e = throws(
    () => { new caps.dialog({ message: "x", buttons: ["ok"] }); },
    "new dialog",
  );
  ok(e instanceof TypeError, "TypeError instance");
});

// navigate -----------------------------------------------------------

test("navigate: happy path calls requestNavigate", async () => {
  const { ui, calls } = makeFakeUi();
  const caps = makeUiCaps(ui);
  await caps.navigate({ path: "/settings" });
  eq(calls.length, 1, "one call");
  eq(calls[0].kind, "requestNavigate", "right primitive");
  eq(calls[0].args, { path: "/settings" }, "forwarded args");
});

test("navigate: null args throws TypeError", async () => {
  const { ui } = makeFakeUi();
  const caps = makeUiCaps(ui);
  const e = await rejects(caps.navigate(null), "null args");
  ok(e instanceof TypeError, "TypeError instance");
});

test("navigate: missing path throws TypeError", async () => {
  const { ui } = makeFakeUi();
  const caps = makeUiCaps(ui);
  const e = await rejects(caps.navigate({}), "missing path");
  ok(e instanceof TypeError, "TypeError instance");
});

test("navigate: empty path throws TypeError", async () => {
  const { ui } = makeFakeUi();
  const caps = makeUiCaps(ui);
  const e = await rejects(caps.navigate({ path: "" }), "empty path");
  ok(e instanceof TypeError, "TypeError instance");
});

test("navigate: non-string path throws TypeError", async () => {
  const { ui } = makeFakeUi();
  const caps = makeUiCaps(ui);
  const e = await rejects(caps.navigate({ path: 123 }), "numeric path");
  ok(e instanceof TypeError, "TypeError instance");
});

test("navigate: oversized path rejects with RangeError", async () => {
  const { ui } = makeFakeUi();
  const caps = makeUiCaps(ui);
  const e = await rejects(
    caps.navigate({ path: "x".repeat(3000) }),
    "oversized path",
  );
  ok(e instanceof RangeError, "RangeError instance");
});

test("navigate: non-constructable", () => {
  const { ui } = makeFakeUi();
  const caps = makeUiCaps(ui);
  const e = throws(() => { new caps.navigate({ path: "/" }); }, "new navigate");
  ok(e instanceof TypeError, "TypeError instance");
});

// ---------------------------------------------------------------------
// buildDayZeroCapImpls
// ---------------------------------------------------------------------

test("buildDayZeroCapImpls: with all configs returns 17-entry Map", () => {
  const uninstall = installIdbMock();
  try {
    const { ui } = makeFakeUi();
    const map = buildDayZeroCapImpls({
      fetchConfig: { allowed_origins: ["https://example.com"] },
      kvConfig: { pack_id: "p1" },
      uiPrimitives: ui,
    });
    ok(map instanceof Map, "is a Map");
    eq(map.size, 17, "17 entries total");
    const all = [
      "text_encode", "text_decode", "compress", "decompress", "console_log",
      "web_crypto_random", "web_crypto_subtle", "set_timeout", "clipboard_write",
      "fetch_api", "kv_read", "kv_write", "kv_delete", "kv_keys",
      "toast", "dialog", "navigate",
    ];
    for (const name of all) {
      ok(map.has(name), "has " + name);
      ok(typeof map.get(name) === "function", name + " is function");
    }
  } finally { uninstall(); }
});

test("buildDayZeroCapImpls: missing uiPrimitives omits toast/dialog/navigate", () => {
  const map = buildDayZeroCapImpls({});
  ok(!map.has("toast"), "no toast");
  ok(!map.has("dialog"), "no dialog");
  ok(!map.has("navigate"), "no navigate");
  ok(!map.has("fetch_api"), "no fetch_api");
  ok(!map.has("kv_read"), "no kv_read");
  eq(map.size, 9, "only the 9 pure caps");
});

test("buildDayZeroCapImpls: null opts throws TypeError", () => {
  const e = throws(() => buildDayZeroCapImpls(null), "null opts");
  ok(e instanceof TypeError, "TypeError instance");
});

test("buildDayZeroCapImpls: ui-only composition includes 12 caps", () => {
  const { ui } = makeFakeUi();
  const map = buildDayZeroCapImpls({ uiPrimitives: ui });
  eq(map.size, 12, "9 pure + 3 ui");
  ok(map.has("toast") && map.has("dialog") && map.has("navigate"),
    "ui caps present");
});

// ---------------------------------------------------------------------
// Run.
// ---------------------------------------------------------------------

let failed = 0;
let passed = 0;
for (const t of TESTS) {
  try {
    await t.fn();
    passed++;
  } catch (e) {
    failed++;
    console.error("FAIL", t.name, "\n  ", e && e.stack || e);
  }
}
console.log("js_caps tests: " + passed + " passed, " + failed + " failed");
if (failed > 0) process.exit(1);
