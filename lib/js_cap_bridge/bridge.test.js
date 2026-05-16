// lib/js_cap_bridge/bridge.test.js
//
// Self-tests for createRealmBridge / createHostBridge. To run:
//
//   bun lib/js_cap_bridge/bridge.test.js
//
// Test groups (mirrored by needles in parity_test.lua):
//   - happy path        : echo, concurrent ids, host-Promise return
//   - authorization     : denied (not granted), missing (granted but no impl)
//   - error propagation : impl throws, impl returns rejected Promise
//   - malformed         : alien response, host-side malformed call
//   - non-constructable : `new caps.foo()` throws TypeError
//   - no implicit coercion: host never triggers Symbol.toPrimitive on args

import { createRealmBridge, createHostBridge } from "./bridge.js";

// ---------------------------------------------------------------------
// Tiny test harness.
// ---------------------------------------------------------------------

/** @type {{ name: string, fn: () => Promise<void> | void }[]} */
const TESTS = [];

/** @param {string} name @param {() => Promise<void> | void} fn */
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

async function rejects(promise, label) {
  try {
    await promise;
  } catch (e) {
    return e;
  }
  throw new Error("expected rejection: " + (label || ""));
}

// ---------------------------------------------------------------------
// Paired-bridge fixture.
//
// Build a realm bridge and a host bridge whose postMessages route to
// each other's dispatch. This models the real iframe<->stub wiring
// where one side's postMessage triggers the other side's message-event
// handler. No structured-clone is performed (bun's `node:vm` would
// strip functions, but we want some tests -- e.g. the coercion test --
// to verify the host bridge itself never reaches into args).
// ---------------------------------------------------------------------

/**
 * @param {{ capNames: string[], grantedCaps: Set<string>,
 *           capImpls: Map<string, (...args: any[]) => any>,
 *           audit?: (entry: any) => void }} cfg
 */
function pair(cfg) {
  /** @type {(msg: any) => void} */
  let realmDispatch = () => { /* set below */ };
  /** @type {(msg: any) => void} */
  let hostDispatch = () => { /* set below */ };

  /** @type {any[]} */
  const auditLog = [];
  const audit = cfg.audit || ((e) => auditLog.push(e));

  const host = createHostBridge({
    grantedCaps: cfg.grantedCaps,
    capImpls: cfg.capImpls,
    audit,
    postMessage: (msg) => realmDispatch(msg),
  });
  hostDispatch = host.dispatch;

  const realm = createRealmBridge({
    capNames: cfg.capNames,
    postMessage: (msg) => hostDispatch(msg),
    registerMessageHandler: (handler) => { realmDispatch = handler; },
  });

  return { realm, host, auditLog };
}

// ---------------------------------------------------------------------
// Happy path.
// ---------------------------------------------------------------------

test("happy path: echo returns host value", async () => {
  const { realm, auditLog } = pair({
    capNames: ["echo"],
    grantedCaps: new Set(["echo"]),
    capImpls: new Map([["echo", (s) => s + "-resp"]]),
  });
  const out = await realm.caps.echo("hi");
  eq(out, "hi-resp", "echo round-trip");
  eq(auditLog.length, 1, "one audit entry");
  ok(auditLog[0].ok === true, "audit ok=true");
  eq(auditLog[0].cap, "echo");
});

test("happy path: multiple concurrent calls correlate by id", async () => {
  let delayCount = 0;
  const { realm } = pair({
    capNames: ["slow"],
    grantedCaps: new Set(["slow"]),
    capImpls: new Map([["slow", async (n) => {
      // Resolve out-of-order: first call yields more microtasks than second.
      const yields = (delayCount++ === 0) ? 5 : 1;
      for (let i = 0; i < yields; i++) await Promise.resolve();
      return n * 10;
    }]]),
  });
  const [a, b, c] = await Promise.all([
    realm.caps.slow(1),
    realm.caps.slow(2),
    realm.caps.slow(3),
  ]);
  eq(a, 10);
  eq(b, 20);
  eq(c, 30);
});

test("happy path: host returns a Promise", async () => {
  const { realm } = pair({
    capNames: ["async_echo"],
    grantedCaps: new Set(["async_echo"]),
    capImpls: new Map([["async_echo", (s) => Promise.resolve(s + "-async")]]),
  });
  const out = await realm.caps.async_echo("zz");
  eq(out, "zz-async");
});

// ---------------------------------------------------------------------
// Authorization.
// ---------------------------------------------------------------------

test("auth: cap not in grantedCaps rejects with denied", async () => {
  const { realm, auditLog } = pair({
    capNames: ["http_client"],
    grantedCaps: new Set(), // nothing granted
    capImpls: new Map([["http_client", () => "should not run"]]),
  });
  const err = /** @type {any} */ (await rejects(
    realm.caps.http_client("/get"), "denied cap should reject",
  ));
  eq(err.type, "denied");
  ok(err.message.indexOf("http_client") >= 0, "denied message names cap");
  eq(auditLog.length, 1);
  eq(auditLog[0].denied, "not granted");
});

test("auth: cap granted but impl missing rejects with missing", async () => {
  const { realm, auditLog } = pair({
    capNames: ["clipboard"],
    grantedCaps: new Set(["clipboard"]),
    capImpls: new Map(), // grant present but impl absent
  });
  const err = /** @type {any} */ (await rejects(realm.caps.clipboard("x")));
  eq(err.type, "missing");
  ok(err.message.indexOf("clipboard") >= 0);
  eq(auditLog[0].denied, "missing impl");
});

// ---------------------------------------------------------------------
// Error propagation.
// ---------------------------------------------------------------------

test("error: impl throws", async () => {
  const { realm, auditLog } = pair({
    capNames: ["boom"],
    grantedCaps: new Set(["boom"]),
    capImpls: new Map([["boom", () => { throw new Error("kaboom"); }]]),
  });
  const err = /** @type {any} */ (await rejects(realm.caps.boom()));
  eq(err.type, "throw");
  eq(err.message, "kaboom");
  eq(auditLog[0].ok, false);
});

test("error: impl returns rejected promise", async () => {
  const { realm } = pair({
    capNames: ["boom"],
    grantedCaps: new Set(["boom"]),
    capImpls: new Map([["boom", () => Promise.reject(new Error("rejected!"))]]),
  });
  const err = /** @type {any} */ (await rejects(realm.caps.boom()));
  eq(err.type, "throw");
  eq(err.message, "rejected!");
});

// ---------------------------------------------------------------------
// Malformed protocol.
// ---------------------------------------------------------------------

test("malformed: realm drops alien response with unknown id", async () => {
  // Build only the realm bridge so we can inject crafted host messages.
  const sent = /** @type {any[]} */ ([]);
  /** @type {(msg: any) => void} */
  let _handler = () => {};
  const { caps, dispatch } = createRealmBridge({
    capNames: ["echo"],
    postMessage: (m) => sent.push(m),
    registerMessageHandler: (h) => { _handler = h; },
  });
  // Issue a real call to register a pending entry with id=1.
  const pendingPromise = caps.echo("k");
  // Now drop an alien response with id=999. Should NOT resolve pendingPromise.
  dispatch({ kind: "result", id: 999, value: "WRONG" });
  // Drop malformed garbage. Should be silently ignored.
  dispatch(null);
  dispatch({ kind: "what" });
  dispatch("not even an object");
  // Now legitimately resolve id=1.
  dispatch({ kind: "result", id: 1, value: "ok-1" });
  const out = await pendingPromise;
  eq(out, "ok-1", "alien messages did not corrupt pending entry");
});

test("malformed: host responds with malformed when id is recoverable", async () => {
  /** @type {any[]} */
  const sent = [];
  const host = createHostBridge({
    grantedCaps: new Set(["echo"]),
    capImpls: new Map([["echo", () => "ok"]]),
    audit: () => {},
    postMessage: (m) => sent.push(m),
  });
  // Send a half-formed envelope: id present but no cap/args.
  host.dispatch({ id: 42, kind: "call" });
  eq(sent.length, 1);
  eq(sent[0].id, 42);
  eq(sent[0].kind, "error");
  eq(sent[0].error.type, "malformed");
});

test("malformed: host drops envelope with no recoverable id", async () => {
  /** @type {any[]} */
  const sent = [];
  const host = createHostBridge({
    grantedCaps: new Set(["echo"]),
    capImpls: new Map([["echo", () => "ok"]]),
    audit: () => {},
    postMessage: (m) => sent.push(m),
  });
  host.dispatch(null);
  host.dispatch({ kind: "call", cap: "echo", args: [] }); // no id
  host.dispatch("garbage");
  eq(sent.length, 0, "nothing to send when id unrecoverable");
});

test("malformed: alien second response for same id is dropped", async () => {
  /** @type {any[]} */
  const sent = [];
  /** @type {(m: any) => void} */
  let _h = () => {};
  const { caps, dispatch } = createRealmBridge({
    capNames: ["echo"],
    postMessage: (m) => sent.push(m),
    registerMessageHandler: (h) => { _h = h; },
  });
  const p = caps.echo("a");
  dispatch({ id: 1, kind: "result", value: "first" });
  // Second response for same id -- should be silently dropped.
  dispatch({ id: 1, kind: "result", value: "second" });
  dispatch({ id: 1, kind: "error", error: { type: "throw", message: "no" } });
  eq(await p, "first");
});

// ---------------------------------------------------------------------
// Non-constructability.
// ---------------------------------------------------------------------

test("non-constructable: `new caps.echo()` throws TypeError", async () => {
  const { realm } = pair({
    capNames: ["echo"],
    grantedCaps: new Set(["echo"]),
    capImpls: new Map([["echo", (s) => s]]),
  });
  let threw = false;
  try {
    // @ts-ignore -- intentional misuse
    new realm.caps.echo();
  } catch (e) {
    threw = e instanceof TypeError;
  }
  ok(threw, "new on cap shell must throw TypeError");
});

// ---------------------------------------------------------------------
// No implicit coercion of args.
// ---------------------------------------------------------------------

test("no implicit coercion: host never triggers Symbol.toPrimitive on args", async () => {
  // Build a tripwire object that would record any coercion attempt.
  let coercionCalled = false;
  const tripwire = {
    [Symbol.toPrimitive]() {
      coercionCalled = true;
      return "tripped";
    },
    valueOf() { coercionCalled = true; return "tripped-valueOf"; },
    toString() { coercionCalled = true; return "tripped-toString"; },
  };
  // We inject the tripwire directly through the host dispatch path,
  // bypassing structured-clone (which would strip the symbol keys).
  // The host bridge MUST NOT touch the value before handing it to the
  // impl; the impl below verifies it received the same identity.
  /** @type {any} */
  let received = null;
  /** @type {any[]} */
  const sent = [];
  const host = createHostBridge({
    grantedCaps: new Set(["sink"]),
    capImpls: new Map([["sink", (arg) => { received = arg; return "ok"; }]]),
    audit: () => { /* must not coerce args either */ },
    postMessage: (m) => sent.push(m),
  });
  host.dispatch({ id: 1, kind: "call", cap: "sink", args: [tripwire] });
  // Yield microtasks for the Promise.resolve().then chain to run.
  for (let i = 0; i < 5; i++) await Promise.resolve();
  ok(received === tripwire, "impl received the exact tripwire instance");
  ok(!coercionCalled, "no implicit coercion on args inside the host bridge");
  eq(sent.length, 1);
  eq(sent[0].kind, "result");
});

// ---------------------------------------------------------------------
// Bonus: synchronous postMessage failure on the realm side.
// ---------------------------------------------------------------------

test("realm: postMessage that throws rejects the returned promise", async () => {
  const { caps } = createRealmBridge({
    capNames: ["echo"],
    postMessage: () => { throw new Error("transport down"); },
  });
  const err = /** @type {any} */ (await rejects(caps.echo("x")));
  ok(/transport down/.test(err.message), "rejection carries underlying error");
});

// ---------------------------------------------------------------------
// Driver.
// ---------------------------------------------------------------------

(async () => {
  let pass = 0;
  let fail = 0;
  const failures = [];
  for (const t of TESTS) {
    try {
      await t.fn();
      pass++;
    } catch (e) {
      fail++;
      failures.push({ name: t.name, error: e });
    }
  }
  // eslint-disable-next-line no-console
  console.log("js_cap_bridge tests: " + pass + " passed, " + fail + " failed");
  for (const f of failures) {
    // eslint-disable-next-line no-console
    console.error("  FAIL " + f.name + ": " + (f.error && f.error.stack || f.error));
  }
  if (fail > 0) process.exit(1);
})();
