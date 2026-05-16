// lib/js_pack_host/bootstrap.test.js
//
// Self-tests for runBootstrap. The bootstrap stitches the realm-side
// cap bridge (lib/js_cap_bridge) and the realm lockdown
// (lib/js_realm_sandbox) into one call. We simulate the iframe<->host
// boundary by:
//
//   - running `runBootstrap` inside a fresh `node:vm` context
//     (the realm side),
//   - instantiating `createHostBridge` outside the vm (the host side),
//   - wiring postMessage/registerMessageHandler so the realm's
//     postMessage routes to the host's dispatch and vice versa.
//
// To run:
//
//   bun lib/js_pack_host/bootstrap.test.js
//
// Tests pass `_skipGlobalFreeze: true` to runBootstrap because bun's
// `node:vm` emulation does not implement `Object.freeze(globalThis)`
// consistently with a real browser realm -- mirrors the workaround in
// lib/js_realm_sandbox/sandbox.test.js. Every load-bearing lockdown
// barrier (`__cap__` non-writable + non-configurable, intrinsic props
// sealed via defineProperty) is installed independently of the freeze.

import { readFileSync } from "node:fs";
import vm from "node:vm";
import { createHostBridge } from "../js_cap_bridge/bridge.js";

// =====================================================================
// Inlined-source bootstrap text.
//
// node:vm cannot resolve ESM `import` statements inside a context, so
// we read the three modules (safe_regex, sandbox, bridge, bootstrap),
// strip their `export` / cross-module `import` lines, and concatenate
// into a single Script.
// =====================================================================

const SAFE_REGEX_SRC = readFileSync(
  "lib/js_safe_regex/safe_regex.js", "utf8",
).replace(/^export\s+function\s+validatePattern/m, "function validatePattern");

const SANDBOX_SRC = readFileSync(
  "lib/js_realm_sandbox/sandbox.js", "utf8",
)
  .replace(/^import\s+\{[^}]+\}\s+from\s+"[^"]+";?\s*$/m, "")
  .replace(/^export\s+function\s+installLockdown/m, "function installLockdown")
  .replace(/^export\s+\{[^}]+\};?\s*$/m, "");

const BRIDGE_SRC = readFileSync(
  "lib/js_cap_bridge/bridge.js", "utf8",
)
  .replace(/^export\s+function\s+createRealmBridge/m, "function createRealmBridge")
  .replace(/^export\s+function\s+createHostBridge/m, "function createHostBridge");

const BOOTSTRAP_SRC = readFileSync(
  "lib/js_pack_host/bootstrap.js", "utf8",
)
  .replace(/^import\s+\{[^}]+\}\s+from\s+"[^"]+";?\s*$/mg, "")
  .replace(/^export\s+function\s+runBootstrap/m, "function runBootstrap");

const INLINED =
  SAFE_REGEX_SRC + "\n" +
  SANDBOX_SRC + "\n" +
  BRIDGE_SRC + "\n" +
  BOOTSTRAP_SRC + "\n";

// =====================================================================
// Tiny test harness.
// =====================================================================

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

// =====================================================================
// Paired-bridge fixture.
//
// Build a fresh vm context, run the bootstrap inside it (wiring the
// realm's postMessage/registerMessageHandler through callbacks), and
// pair it with a host-side bridge outside the context. The two
// dispatches form a closed loop -- realm.caps.<name>(...) routes:
//
//   realm-side caps[name] -> postMessage cb (outside vm) ->
//     host.dispatch -> impl(...) -> host.postMessage cb ->
//       realm-side dispatch -> Promise resolution
//
// No structured-clone is performed -- this mirrors the
// lib/js_cap_bridge/bridge.test.js pair() shape exactly.
// =====================================================================

/**
 * @param {{
 *   capNames: string[],
 *   grantedCaps: Set<string>,
 *   capImpls: Map<string, (...args: any[]) => any>,
 *   audit?: (entry: any) => void,
 * }} cfg
 */
function pairedBootstrap(cfg) {
  const ctx = vm.createContext({});

  // Install transport bridges in the vm context as host-side globals
  // so the bootstrap (running inside the context) can call them.
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
    // Host posts back into the realm by invoking the realm's dispatch.
    postMessage: (msg) => realmDispatch(msg),
  });
  hostDispatch = host.dispatch;

  // The vm context needs to call OUT to the host. We expose two
  // callables on its globalThis BEFORE bootstrap runs; the lockdown
  // step will prune them out of globalThis itself (since they are not
  // on the JS-language allow-list), but they will already be captured
  // in the bootstrap's local references by then.
  //
  // Strategy: build the bootstrap call inside the vm using
  // function-expression arguments whose closures reach back to
  // outside-the-vm via a pre-installed pair of slots. node:vm
  // sandboxes do allow attaching host-provided values to the context
  // globalThis pre-execution.
  /** @type {{ post: (msg: any) => void, reg: (h: any) => void }} */
  const wiring = {
    post: (msg) => hostDispatch(msg),
    reg: (handler) => { realmDispatch = handler; },
  };
  // Attach the wiring before contextification's freeze step happens.
  // The wiring slot is named `__wiring__` -- chosen so the lockdown's
  // allow-list walk strips it (it is NOT in the JS-language
  // allow-list) after the bootstrap has already closed over it.
  ctx.__wiring__ = wiring;

  const capNamesJSON = JSON.stringify(cfg.capNames);
  // The bootstrap closure captures __wiring__ BEFORE installLockdown
  // runs (lockdown then strips __wiring__ from globalThis, but the
  // closure references survive — the bridge's `postMessage` slot
  // already holds a function value whose closure points at the local
  // `wiring` IIFE variable, not at the global). We model this by
  // wrapping the runBootstrap call in an IIFE that pulls __wiring__
  // into a local before invoking runBootstrap.
  vm.runInContext(
    INLINED +
    "\n" +
    "(function () {\n" +
    "  var w = __wiring__;\n" +
    "  globalThis.__bootstrapResult__ = runBootstrap({\n" +
    "    capNames: " + capNamesJSON + ",\n" +
    "    postMessage: function postMessage(msg) { w.post(msg); },\n" +
    "    registerMessageHandler: function reg(h) { w.reg(h); },\n" +
    "    _skipGlobalFreeze: true,\n" +
    "  });\n" +
    "})();\n",
    ctx,
  );

  return { ctx, auditLog };
}

// =====================================================================
// Tests.
// =====================================================================

test("paired bridges: realm call round-trips through host impl", async () => {
  const { ctx, auditLog } = pairedBootstrap({
    capNames: ["echo"],
    grantedCaps: new Set(["echo"]),
    capImpls: new Map([["echo", (s) => s + "-resp"]]),
  });
  // From inside the locked-down realm, invoke __cap__.echo and resolve
  // its promise back into a synchronous return for the harness.
  const promise = vm.runInContext(
    "(function(){ 'use strict'; return __cap__.echo('hi'); })()",
    ctx,
  );
  const out = await promise;
  eq(out, "hi-resp", "echo round-trip via __cap__");
  eq(auditLog.length, 1);
  ok(auditLog[0].ok === true);
  eq(auditLog[0].cap, "echo");
});

test("cap subset: only granted capNames appear on __cap__", async () => {
  // Pack declared two caps; bootstrap is told only toast was granted.
  const { ctx } = pairedBootstrap({
    capNames: ["toast"],
    grantedCaps: new Set(["toast"]),
    capImpls: new Map([["toast", () => "toasted"]]),
  });
  const hasToast = vm.runInContext(
    "(function(){ 'use strict'; return typeof __cap__.toast === 'function'; })()",
    ctx,
  );
  const fetchUndef = vm.runInContext(
    "(function(){ 'use strict'; return typeof __cap__.fetch_api === 'undefined'; })()",
    ctx,
  );
  ok(hasToast, "granted cap toast is installed on __cap__");
  ok(fetchUndef, "ungranted cap fetch_api is absent from __cap__");
});

test("lockdown effective after bootstrap: eval / Function / Object.create gone", async () => {
  const { ctx } = pairedBootstrap({
    capNames: [],
    grantedCaps: new Set(),
    capImpls: new Map(),
  });
  // Reuse a slice of the escape-corpus from lib/js_realm_sandbox: each
  // expression must evaluate to true. eval / Function / Object.create
  // are stripped; the prototype-chain constructor reach is closed.
  const checks = [
    "typeof eval === 'undefined'",
    "typeof Function === 'undefined'",
    "typeof Object.create === 'undefined'",
    "typeof Reflect === 'undefined'",
    "typeof Proxy === 'undefined'",
    "({}).__proto__ === undefined",
    "({}).constructor === undefined",
    "(function(){}).constructor === undefined",
    "[].constructor === undefined",
    "\"\".constructor === undefined",
    "(/x/).constructor === undefined",
    "(new Error()).constructor === undefined",
    "typeof Object.setPrototypeOf === 'undefined'",
    "typeof Object.getPrototypeOf === 'undefined'",
    "typeof Symbol.for === 'undefined'",
  ];
  for (let i = 0; i < checks.length; i++) {
    const v = vm.runInContext(
      "(function(){ 'use strict'; return " + checks[i] + "; })()",
      ctx,
    );
    ok(v === true, "lockdown check failed: " + checks[i] + " -> " + v);
  }
});

test("bridge wiring: call envelope shape is correct", async () => {
  // Capture host-side received envelopes to inspect their shape.
  /** @type {any[]} */
  const received = [];
  const { ctx } = pairedBootstrap({
    capNames: ["someCap"],
    grantedCaps: new Set(["someCap"]),
    capImpls: new Map([["someCap", (...args) => {
      // Reach the most-recent call's shape via a side channel: the
      // host bridge invoked us with the args; record both args and a
      // synthesised envelope shape that mirrors what the host bridge
      // observed before dispatching. The real envelope-shape proof is
      // covered structurally by lib/js_cap_bridge tests; here we
      // sanity-check the realm-side serialisation by asserting the
      // impl receives the same args the realm sent.
      received.push({ args });
      return "ok";
    }]]),
  });
  const promise = vm.runInContext(
    "(function(){ 'use strict'; return __cap__.someCap('arg'); })()",
    ctx,
  );
  const out = await promise;
  eq(out, "ok", "round trip returns host value");
  eq(received.length, 1);
  eq(received[0].args, ["arg"], "host impl received the realm-supplied args");
});

test("envelope id is a number, kind is 'call', cap matches name, args is an array", async () => {
  // Drop into the realm-side bridge directly via the bootstrap's
  // return value: postMessage is invoked once per outbound call.
  /** @type {any[]} */
  const captured = [];
  const ctx = vm.createContext({});
  ctx.__wiring__ = {
    post: (msg) => captured.push(msg),
    reg: (_h) => { /* no inbound responses needed for this test */ },
  };
  vm.runInContext(
    INLINED +
    "\n(function () {\n" +
    "  var w = __wiring__;\n" +
    "  runBootstrap({\n" +
    "    capNames: ['greet'],\n" +
    "    postMessage: function p(m) { w.post(m); },\n" +
    "    registerMessageHandler: function r(h) { w.reg(h); },\n" +
    "    _skipGlobalFreeze: true,\n" +
    "  });\n" +
    "})();\n" +
    "(function(){ 'use strict'; __cap__.greet('hello', 42); })();\n",
    ctx,
  );
  eq(captured.length, 1);
  ok(typeof captured[0].id === "number", "envelope.id is a number");
  eq(captured[0].kind, "call", "envelope.kind is 'call'");
  eq(captured[0].cap, "greet", "envelope.cap matches");
  eq(captured[0].args, ["hello", 42], "envelope.args mirrors call arguments");
});

test("__cap__.<name> is non-constructable: `new __cap__.toast()` throws TypeError", async () => {
  const { ctx } = pairedBootstrap({
    capNames: ["toast"],
    grantedCaps: new Set(["toast"]),
    capImpls: new Map([["toast", () => "ok"]]),
  });
  const v = vm.runInContext(
    "(function(){ 'use strict';\n" +
    "  try { new __cap__.toast(); return 'NO_THROW'; }\n" +
    "  catch (e) { return e instanceof TypeError ? 'TYPE_ERROR' : 'OTHER'; }\n" +
    "})()",
    ctx,
  );
  eq(v, "TYPE_ERROR", "new __cap__.toast() must throw TypeError");
});

test("denied cap rejects with error.type === 'denied'", async () => {
  // capNames includes 'fetch_api' but the host has not granted it.
  // This shouldn't happen via normal orchestration (capNames is the
  // grant set), but proves the host bridge enforces grants
  // independently. We model it by installing the shell realm-side
  // while the host's grantedCaps set excludes the cap.
  const { ctx } = pairedBootstrap({
    capNames: ["fetch_api"],
    grantedCaps: new Set(), // not granted
    capImpls: new Map([["fetch_api", () => "should-not-run"]]),
  });
  const promise = vm.runInContext(
    "(function(){ 'use strict'; return __cap__.fetch_api('/x'); })()",
    ctx,
  );
  const err = /** @type {any} */ (await rejects(promise, "denied call"));
  // The thrown Error inside the realm carries a `.type` annotation.
  // We get the outside-the-vm rejection here directly because the
  // Promise was returned via runInContext.
  ok(err && (err.type === "denied" || /denied/.test(String(err.message))),
    "denied cap rejection should be typed denied: " + JSON.stringify({
      type: err && err.type, message: err && err.message,
    }));
});

// =====================================================================
// Driver.
// =====================================================================

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
  console.log("js_pack_host tests: " + pass + " passed, " + fail + " failed");
  for (const f of failures) {
    // eslint-disable-next-line no-console
    console.error("  FAIL " + f.name + ": " + (f.error && f.error.stack || f.error));
  }
  if (fail > 0) process.exit(1);
})();
