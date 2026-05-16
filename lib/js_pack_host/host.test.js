// lib/js_pack_host/host.test.js
//
// Self-tests for mountPack (lib/js_pack_host/host.js -- the outside-
// iframe host-page wiring). Run with:
//
//   bun lib/js_pack_host/host.test.js
//
// Real iframes require a browser; bun has no DOM. We simulate the
// browser surface that mountPack touches:
//
//   - A fake Document.createElement("iframe") returns a synthetic
//     iframe whose `contentWindow` is a node:vm context running the
//     inlined bootstrap.
//   - A fake host Window.addEventListener("message", h) records the
//     listener; tests then fire synthetic MessageEvents through it.
//   - A fake iframe.contentWindow.postMessage(msg, origin) routes
//     into the vm's realm-side dispatch (the same routing the test
//     harness in bootstrap.test.js uses).
//
// Real-browser smoke (real iframe + real postMessage) is a manual
// follow-up; the bridge protocol itself is exercised end-to-end in
// lib/js_cap_bridge/bridge.test.js and lib/js_pack_host/
// bootstrap.test.js so this file's responsibility is the host-page
// gluing: cap validation, origin check, source check, mount audit,
// unmount cleanup.

import { readFileSync } from "node:fs";
import vm from "node:vm";
import { mountPack } from "./host.js";

// =====================================================================
// Inlined bootstrap (same recipe as bootstrap.test.js).
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

function throws(fn, label) {
  try { fn(); }
  catch (e) { return e; }
  throw new Error("expected throw: " + (label || ""));
}

// =====================================================================
// DOM stubs.
//
// The point of these stubs is to expose JUST the surface mountPack
// touches: container.appendChild, container.ownerDocument.createElement,
// container.ownerDocument.defaultView.addEventListener, the iframe's
// setAttribute / contentWindow / parentNode, and the iframe's
// contentWindow.postMessage.
// =====================================================================

/**
 * Build a fake host window + container + iframe-factory triple. The
 * created iframe's `contentWindow.postMessage` routes into the
 * supplied `onRealmMessage(msg, origin)` callback, and the host
 * window's message listeners can be invoked via the returned
 * `fireMessage(event)` helper.
 *
 * @param {{ onRealmMessage: (msg: any, origin: string) => void }} cfg
 */
function makeFakeDom(cfg) {
  /** @type {{ type: string, handler: (e: any) => void }[]} */
  const listeners = [];
  const hostWindow = {
    addEventListener(type, handler) {
      listeners.push({ type, handler });
    },
    removeEventListener(type, handler) {
      for (let i = 0; i < listeners.length; i++) {
        if (listeners[i].type === type && listeners[i].handler === handler) {
          listeners.splice(i, 1);
          return;
        }
      }
    },
  };

  /** @type {any} */
  let currentIframe = null;
  const ownerDocument = {
    defaultView: hostWindow,
    createElement(tag) {
      if (tag !== "iframe") throw new Error("only iframe expected, got " + tag);
      const attrs = { __proto__: null };
      const contentWindow = {
        // The realm-side postMessage is just a callback the test
        // forwards into a paired host (via cfg.onRealmMessage).
        postMessage(msg, origin) {
          cfg.onRealmMessage(msg, origin);
        },
      };
      const iframe = {
        __proto__: null,
        setAttribute(k, v) { attrs[k] = v; },
        getAttribute(k) { return attrs[k]; },
        contentWindow,
        parentNode: null,
      };
      currentIframe = iframe;
      return iframe;
    },
  };

  /** @type {any[]} */
  const containerChildren = [];
  const container = {
    ownerDocument,
    appendChild(node) {
      containerChildren.push(node);
      node.parentNode = container;
      return node;
    },
    removeChild(node) {
      const idx = containerChildren.indexOf(node);
      if (idx >= 0) {
        containerChildren.splice(idx, 1);
        node.parentNode = null;
      }
      return node;
    },
  };

  /**
   * Fire a synthetic MessageEvent at every "message" listener.
   * @param {{ data: any, origin: string, source: any }} event
   */
  function fireMessage(event) {
    // Snapshot listeners so a listener that removes itself doesn't
    // perturb iteration.
    const snapshot = listeners.slice();
    for (let i = 0; i < snapshot.length; i++) {
      if (snapshot[i].type === "message") snapshot[i].handler(event);
    }
  }

  return {
    hostWindow,
    container,
    ownerDocument,
    fireMessage,
    getIframe: () => currentIframe,
    listenersAfter: () => listeners.length,
    childrenAfter: () => containerChildren.length,
  };
}

// =====================================================================
// vm-resident realm wiring. Returns a `{ ctx, fireIntoHost }` where
// `ctx` has the bootstrap run inside and `fireIntoHost` is a callback
// the host's iframe.contentWindow.postMessage routes into (it becomes
// the realm-side bridge's inbound message handler).
// =====================================================================

/**
 * @param {{ capNames: string[] }} cfg
 */
function makeRealm(cfg) {
  const ctx = vm.createContext({});
  /** @type {(msg: any) => void} */
  let realmInbound = () => { /* set by registerMessageHandler */ };
  /** @type {(msg: any) => void} */
  let realmOutbound = () => { /* set after vm runs */ };

  ctx.__wiring__ = {
    post: (msg) => realmOutbound(msg),
    reg: (h) => { realmInbound = h; },
  };

  vm.runInContext(
    INLINED +
    "\n(function () {\n" +
    "  var w = __wiring__;\n" +
    "  globalThis.__bootstrapResult__ = runBootstrap({\n" +
    "    capNames: " + JSON.stringify(cfg.capNames) + ",\n" +
    "    postMessage: function postMessage(msg) { w.post(msg); },\n" +
    "    registerMessageHandler: function reg(h) { w.reg(h); },\n" +
    "    _skipGlobalFreeze: true,\n" +
    "  });\n" +
    "})();\n",
    ctx,
  );

  return {
    ctx,
    // realmOutbound is what the realm-side bridge invokes on every
    // outbound `call` envelope; the test wires this to host
    // bridge.dispatch via the fake iframe.contentWindow.postMessage
    // bookkeeping below.
    setRealmOutbound: (fn) => { realmOutbound = fn; },
    realmInbound: (msg) => realmInbound(msg),
  };
}

// =====================================================================
// Tests.
// =====================================================================

test("mountPack: rejects capNames without matching capImpls", () => {
  const dom = makeFakeDom({ onRealmMessage: () => {} });
  const err = throws(() => mountPack({
    container: dom.container,
    packBootstrapUrl: "https://pack.example/boot",
    capNames: ["foo"],
    capImpls: new Map(),
    audit: () => {},
  }), "missing impl should throw");
  ok(/no capImpls entry/.test(String(err.message)),
    "error message names the misconfig: " + String(err.message));
});

test("mountPack: returns iframe + unmount + audit handle", () => {
  const dom = makeFakeDom({ onRealmMessage: () => {} });
  /** @type {any[]} */
  const auditLog = [];
  const handle = mountPack({
    container: dom.container,
    packBootstrapUrl: "https://pack.example/boot",
    capNames: ["toast"],
    capImpls: new Map([["toast", () => "ok"]]),
    audit: (e) => auditLog.push(e),
    origin: "https://pack.example",
  });
  ok(handle.iframe, "iframe returned");
  eq(typeof handle.unmount, "function", "unmount is a function");
  eq(typeof handle.audit, "function", "audit is a function");
  // Iframe is appended.
  eq(dom.childrenAfter(), 1, "iframe appended to container");
  // sandbox set correctly.
  eq(handle.iframe.getAttribute("sandbox"), "allow-scripts",
    "sandbox is allow-scripts only");
  eq(handle.iframe.getAttribute("referrerpolicy"), "no-referrer");
  eq(handle.iframe.getAttribute("src"), "https://pack.example/boot");
  // Audit recorded mount.
  eq(auditLog.length, 1);
  eq(auditLog[0].kind, "mount");
  eq(auditLog[0].capNames, ["toast"]);
});

test("mountPack: end-to-end cap call routes realm -> host impl -> back", async () => {
  // Wire host <-> realm. The fake iframe.contentWindow.postMessage
  // delivers messages into the realm's inbound handler; the realm's
  // outbound postMessage fires a synthetic MessageEvent at the host's
  // window listeners.
  /** @type {{ realmInbound: (m: any) => void, setRealmOutbound: (f: any) => void } | null} */
  let realmHandle = null;
  /** @type {ReturnType<typeof makeFakeDom> | null} */
  let domHandle = null;

  const dom = makeFakeDom({
    onRealmMessage: (msg, _origin) => {
      // Host -> iframe: deliver into realm's inbound dispatch.
      if (realmHandle) realmHandle.realmInbound(msg);
    },
  });
  domHandle = dom;

  const realm = makeRealm({ capNames: ["echo"] });
  realmHandle = realm;
  realm.setRealmOutbound((msg) => {
    // Iframe -> host: fire a synthetic message event on the host
    // window from the iframe's contentWindow source.
    const iframe = domHandle ? domHandle.getIframe() : null;
    dom.fireMessage({
      data: msg,
      origin: "https://pack.example",
      source: iframe ? iframe.contentWindow : null,
    });
  });

  /** @type {any[]} */
  const auditLog = [];
  mountPack({
    container: dom.container,
    packBootstrapUrl: "https://pack.example/boot",
    capNames: ["echo"],
    capImpls: new Map([["echo", (s) => s + "-resp"]]),
    audit: (e) => auditLog.push(e),
    origin: "https://pack.example",
  });

  // Invoke __cap__.echo from inside the realm.
  const promise = vm.runInContext(
    "(function(){ 'use strict'; return __cap__.echo('hi'); })()",
    realm.ctx,
  );
  const out = await promise;
  eq(out, "hi-resp", "round trip returns host value");
  // mount + one cap invocation = 2 entries.
  eq(auditLog.length, 2);
  eq(auditLog[0].kind, "mount");
  eq(auditLog[1].cap, "echo");
  ok(auditLog[1].ok === true, "cap audit ok=true");
});

test("mountPack: origin enforcement drops messages from wrong origin", () => {
  /** @type {any[]} */
  const auditLog = [];
  const dom = makeFakeDom({ onRealmMessage: () => {} });
  const handle = mountPack({
    container: dom.container,
    packBootstrapUrl: "https://pack.example/boot",
    capNames: ["echo"],
    capImpls: new Map([["echo", () => "should-not-run"]]),
    audit: (e) => auditLog.push(e),
    origin: "https://pack.example",
  });
  // Fire a message claiming to be a valid call but from the wrong origin.
  dom.fireMessage({
    data: { id: 1, kind: "call", cap: "echo", args: [] },
    origin: "https://attacker.example",
    source: handle.iframe.contentWindow,
  });
  // Only the mount audit should be present; the wrong-origin message
  // was dropped before reaching the bridge.
  eq(auditLog.length, 1);
  eq(auditLog[0].kind, "mount");
});

test("mountPack: source enforcement drops messages from wrong source", () => {
  /** @type {any[]} */
  const auditLog = [];
  const dom = makeFakeDom({ onRealmMessage: () => {} });
  mountPack({
    container: dom.container,
    packBootstrapUrl: "https://pack.example/boot",
    capNames: ["echo"],
    capImpls: new Map([["echo", () => "should-not-run"]]),
    audit: (e) => auditLog.push(e),
    origin: "https://pack.example",
  });
  // Fire a message with correct origin but wrong source.
  dom.fireMessage({
    data: { id: 1, kind: "call", cap: "echo", args: [] },
    origin: "https://pack.example",
    source: { not: "the iframe" },
  });
  eq(auditLog.length, 1);
  eq(auditLog[0].kind, "mount");
});

test("mountPack: unmount removes iframe and listener, audits unmount", () => {
  /** @type {any[]} */
  const auditLog = [];
  const dom = makeFakeDom({ onRealmMessage: () => {} });
  const handle = mountPack({
    container: dom.container,
    packBootstrapUrl: "https://pack.example/boot",
    capNames: [],
    capImpls: new Map(),
    audit: (e) => auditLog.push(e),
    origin: "https://pack.example",
  });
  eq(dom.childrenAfter(), 1, "iframe present pre-unmount");
  eq(dom.listenersAfter(), 1, "message listener installed");

  handle.unmount();

  eq(dom.childrenAfter(), 0, "iframe removed by unmount");
  eq(dom.listenersAfter(), 0, "listener removed by unmount");
  // mount + unmount.
  eq(auditLog.length, 2);
  eq(auditLog[0].kind, "mount");
  eq(auditLog[1].kind, "unmount");

  // Further synthetic messages must not reach the bridge (listener
  // removed) -- audit count stays at 2.
  dom.fireMessage({
    data: { id: 1, kind: "call", cap: "echo", args: [] },
    origin: "https://pack.example",
    source: handle.iframe.contentWindow,
  });
  eq(auditLog.length, 2, "no further audits after unmount");
});

test("mountPack: audit captures every cap invocation", async () => {
  /** @type {{ realmInbound: (m: any) => void, setRealmOutbound: (f: any) => void } | null} */
  let realmHandle = null;
  const dom = makeFakeDom({
    onRealmMessage: (msg) => { if (realmHandle) realmHandle.realmInbound(msg); },
  });
  const realm = makeRealm({ capNames: ["a", "b"] });
  realmHandle = realm;
  realm.setRealmOutbound((msg) => {
    const iframe = dom.getIframe();
    dom.fireMessage({
      data: msg,
      origin: "https://pack.example",
      source: iframe ? iframe.contentWindow : null,
    });
  });

  /** @type {any[]} */
  const auditLog = [];
  mountPack({
    container: dom.container,
    packBootstrapUrl: "https://pack.example/boot",
    capNames: ["a", "b"],
    capImpls: new Map([
      ["a", () => "A"],
      ["b", () => "B"],
    ]),
    audit: (e) => auditLog.push(e),
    origin: "https://pack.example",
  });

  const ra = await vm.runInContext(
    "(function(){ 'use strict'; return __cap__.a(); })()", realm.ctx,
  );
  const rb = await vm.runInContext(
    "(function(){ 'use strict'; return __cap__.b(); })()", realm.ctx,
  );
  eq(ra, "A");
  eq(rb, "B");
  // mount + a + b.
  eq(auditLog.length, 3);
  eq(auditLog[0].kind, "mount");
  eq(auditLog[1].cap, "a");
  eq(auditLog[2].cap, "b");
});

// =====================================================================
// Driver.
// =====================================================================

(async () => {
  let pass = 0;
  let fail = 0;
  /** @type {{ name: string, error: any }[]} */
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
  console.log("js_pack_host host tests: " + pass + " passed, " + fail + " failed");
  for (const f of failures) {
    // eslint-disable-next-line no-console
    console.error("  FAIL " + f.name + ": " + (f.error && f.error.stack || f.error));
  }
  if (fail > 0) process.exit(1);
})();
