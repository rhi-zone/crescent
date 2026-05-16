// lib/js_pack_host/bootstrap.js
//
// Iframe-side bootstrap for pack realms. ESM module.
//
// This is the first JS module that runs inside a pack's sandboxed
// iframe (the inside-iframe piece). The outside-iframe host page (the
// stub page that creates the iframe, instantiates the host-side bridge,
// serves pack source, and brokers postMessage) is a separate library
// that calls into this one; that piece lives elsewhere.
//
// The bootstrap's responsibility, in order:
//
//   1. Build the realm-side cap bridge via
//      lib/js_cap_bridge/bridge.js#createRealmBridge. The caller
//      supplies the transport (`postMessage`, `registerMessageHandler`)
//      and the names of caps the user has granted; the bridge produces
//      a `{ caps, dispatch }` pair where `caps[name]` is a
//      non-constructable async shell that postMessages calls to the
//      host and resolves on response.
//   2. Install the realm lockdown via
//      lib/js_realm_sandbox/sandbox.js#installLockdown, passing the
//      bridge's `caps` as the `caps` option. The lockdown:
//        - strips every non-allow-listed global,
//        - wraps the bridge's cap shells in non-constructable `__cap__`
//          entries,
//        - freezes everything.
//      After this returns, the realm is sealed: nothing ambient
//      remains; only allow-listed intrinsics and `globalThis.__cap__`
//      are reachable.
//   3. Return the `{ caps, dispatch }` pair. The outer host page is
//      responsible for invoking pack source after lockdown — typically
//      by appending a `<script type="module">` tag in the iframe
//      document whose source closes over `globalThis.__cap__`.
//      Pack source is NOT loaded here; the bootstrap's contract is
//      "lockdown + bridge setup".
//
// Sequencing rationale. The lockdown deletes `Function`, `eval`,
// `Object.create`, and walks every kept intrinsic prototype. Anything
// that needs those primitives must capture them BEFORE lockdown runs.
// The bridge is built first (step 1) so its internal `Map` /
// `Promise` / `Array.prototype.concat` references are bound while the
// intrinsics are still vanilla, then lockdown runs (step 2) and seals
// the realm. The bridge's closure-captured machinery is unaffected by
// the prune. Pack source runs LAST (orchestrated by the outer host
// page), in the locked-down realm.
//
// Strict mode. This file is an ESM module, which is strict by default.
// The pack source the outer host loads after the bootstrap must also
// be strict — either ESM (`<script type="module">`) or a non-module
// script with a `'use strict';` prelude. See
// docs/platform_isolation.md §3 "Bootstrap script".
//
// Test wiring. `postMessage` and `registerMessageHandler` are
// caller-injected, so the same code path runs in `node:vm` test
// contexts (paired with a manual host-side bridge via callback
// transport — see bootstrap.test.js) and in real iframes wired to
// `window.parent.postMessage(msg, "*")` /
// `window.addEventListener("message", e => handler(e.data))`.

import { createRealmBridge } from "../js_cap_bridge/bridge.js";
import { installLockdown } from "../js_realm_sandbox/sandbox.js";

/**
 * Run the iframe-side bootstrap.
 *
 * Order of operations:
 *   1. createRealmBridge({capNames, postMessage, registerMessageHandler})
 *      -> { caps, dispatch }
 *   2. installLockdown({ caps, sizeCap, _skipGlobalFreeze })
 *      -- installs `caps` onto `globalThis.__cap__` (the lockdown
 *      additionally wraps each entry in a non-constructable shell, so
 *      the resulting `__cap__.foo` is a non-constructable async
 *      function that delegates to the bridge shell built in step 1).
 *   3. Return `{ caps, dispatch }`.
 *
 * After return, `globalThis.__cap__[name]` is callable for every
 * granted cap. Pack source loaded later by the outer host page invokes
 * those caps; results are correlated through `dispatch`, which the
 * caller-supplied `registerMessageHandler` already wired up in step 1.
 *
 * @param {{
 *   capNames: string[],
 *   postMessage: (msg: unknown) => void,
 *   registerMessageHandler: (handler: (msg: unknown) => void) => void,
 *   sizeCap?: number,
 *   _skipGlobalFreeze?: boolean,
 * }} opts
 *
 * `capNames` is the strict subset of caps the pack declared AND the
 *   user granted (per `docs/browser_caps.md` §3 / §5). Names beyond
 *   the grant set must NOT appear here; the bootstrap installs exactly
 *   what it is told.
 *
 * `postMessage` is invoked by the realm-side bridge for every outbound
 *   call envelope. In a real iframe this is
 *   `msg => window.parent.postMessage(msg, "*")` (or a specific
 *   target origin); in tests it is a callback that forwards into a
 *   paired host-side bridge's dispatch.
 *
 * `registerMessageHandler` is invoked exactly once by the realm-side
 *   bridge to install its message handler. In a real iframe this is
 *   `handler => window.addEventListener("message", e => handler(e.data))`;
 *   in tests it stores the callback for the paired host bridge to
 *   invoke.
 *
 * `sizeCap` (optional) overrides the lockdown's size cap on amplifier
 *   methods (String.prototype.repeat output length, JSON.stringify
 *   output length, Array(n), etc.). Default is 128 MiB; see
 *   lib/js_realm_sandbox/sandbox.js.
 *
 * `_skipGlobalFreeze` (optional, underscore-prefixed -- not for
 *   production) skips the final `Object.freeze(globalThis)` step. This
 *   only exists so tests running under bun's `node:vm` emulation can
 *   verify the rest of the lockdown; that emulation does not implement
 *   realm-global freeze in a way consistent with real browser realms.
 *   Production callers MUST NOT pass this flag.
 *
 * @returns {{
 *   caps: { [name: string]: (...args: unknown[]) => Promise<unknown> },
 *   dispatch: (msg: unknown) => void,
 * }}
 *
 * The returned `caps` is the bridge's shell map (each entry an async
 * concise-method shell). After lockdown those same shells are also
 * reachable through `globalThis.__cap__` (wrapped one more time by the
 * lockdown's non-constructable cap-shell pattern). Pack source uses
 * `__cap__.<name>(...)`. The returned value is for the bootstrap's
 * caller (the outer host orchestration, or tests).
 */
export function runBootstrap(opts) {
  if (!opts || typeof opts !== "object") {
    throw new TypeError("runBootstrap: opts is required");
  }
  if (!Array.isArray(opts.capNames)) {
    throw new TypeError("runBootstrap: opts.capNames must be an array");
  }
  if (typeof opts.postMessage !== "function") {
    throw new TypeError("runBootstrap: opts.postMessage must be a function");
  }
  if (typeof opts.registerMessageHandler !== "function") {
    throw new TypeError(
      "runBootstrap: opts.registerMessageHandler must be a function",
    );
  }

  // Step 1: build the realm-side bridge. This must happen before
  // lockdown so the bridge's internal closures capture vanilla
  // intrinsics (Map, Promise, Array.prototype.concat, ...).
  const { caps, dispatch } = createRealmBridge({
    capNames: opts.capNames,
    postMessage: opts.postMessage,
    registerMessageHandler: opts.registerMessageHandler,
  });

  // Step 2: lock down the realm, installing the bridge's cap shells
  // under `globalThis.__cap__`. The lockdown's own non-constructable
  // cap-shell wrapper composes with the bridge's concise-method
  // shells; the resulting `__cap__.<name>` is callable, returns the
  // bridge's Promise, and throws TypeError on `new __cap__.<name>()`.
  /** @type {{ caps: typeof caps, sizeCap?: number, _skipGlobalFreeze?: boolean }} */
  const lockdownOpts = { caps };
  if (typeof opts.sizeCap === "number") lockdownOpts.sizeCap = opts.sizeCap;
  if (opts._skipGlobalFreeze === true) lockdownOpts._skipGlobalFreeze = true;
  installLockdown(lockdownOpts);

  // Step 3: pack source loading is NOT part of the bootstrap. The
  // outer host page is responsible for executing pack code in the
  // locked-down realm (typically via a `<script type="module">` tag
  // appended after this bootstrap module loads). Returning here gives
  // the caller (orchestration code, or tests) a handle on the bridge
  // for diagnostics; pack code itself reaches caps through
  // `globalThis.__cap__`.
  return { caps, dispatch };
}
