// lib/js_caps/caps.test.js
//
// Self-tests for the day-zero cap implementations in lib/js_caps/. Run:
//
//   bun lib/js_caps/caps.test.js
//
// Each cap gets happy-path, validation-failure, and boundary tests.
// The dayZeroCaps aggregator is verified to contain exactly the 6
// names listed in docs/browser_caps.md §5 that this commit ships.

import {
  dayZeroCaps,
  text_encode,
  text_decode,
  compress,
  decompress,
  console_log,
  web_crypto_random,
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
// dayZeroCaps aggregation
// ---------------------------------------------------------------------

test("dayZeroCaps: contains the 6 trivial caps", () => {
  ok(dayZeroCaps instanceof Map, "is a Map");
  const expected = [
    "text_encode", "text_decode", "compress", "decompress", "console_log",
    "web_crypto_random",
  ];
  eq(dayZeroCaps.size, expected.length, "size matches");
  for (const name of expected) {
    ok(dayZeroCaps.has(name), "has " + name);
    ok(typeof dayZeroCaps.get(name) === "function", name + " is function");
  }
});

test("dayZeroCaps: does not contain the deferred caps", () => {
  // set_timeout is day-zero but blocked on AbortSignal bridge extension
  // (docs/platform_isolation.md §4); it lands in a follow-up commit.
  const deferred = [
    "fetch_api", "web_crypto_subtle", "kv_read", "kv_write", "kv_delete",
    "kv_keys", "navigate", "dialog", "toast", "clipboard_write",
    "set_timeout",
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
