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
  const deferred = [
    "fetch_api", "kv_read", "kv_write", "kv_delete",
    "kv_keys", "navigate", "dialog", "toast",
  ];
  for (const name of deferred) {
    ok(!dayZeroCaps.has(name), "does not have " + name);
  }
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
