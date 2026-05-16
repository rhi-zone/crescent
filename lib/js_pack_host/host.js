// lib/js_pack_host/host.js
//
// Outside-iframe host-page wiring for pack realms. ESM module.
//
// This is the outer-page side of the pack-iframe pipeline. It creates a
// cross-origin sandboxed iframe (sandbox="allow-scripts" only -- no
// allow-same-origin, no allow-forms, no allow-modals, no allow-popups,
// no allow-top-navigation), loads a daemon-served bootstrap page inside
// it (which in turn loads lib/js_pack_host/bootstrap.js + pack source),
// and wires the host-side cap bridge (lib/js_cap_bridge/bridge.js
// #createHostBridge) to the iframe's window via postMessage.
//
// Pairs with lib/js_pack_host/bootstrap.js, which performs the
// inside-iframe half (realm-side bridge + lockdown). The two halves
// communicate exclusively via the postMessage envelope protocol
// documented in lib/js_cap_bridge/bridge.js.
//
// Security contract (see docs/platform_isolation.md §3 "Realm primitive"
// and §3 "Bootstrap script"):
//
//   - The iframe is created with sandbox="allow-scripts" ONLY. Any other
//     allow-* token (allow-same-origin, allow-forms, allow-modals, ...)
//     breaks the realm primitive and is rejected at mount time.
//   - The bootstrap URL MUST be daemon-controlled. The host page does
//     not synthesise pack HTML inline -- it points the iframe at a URL
//     the daemon serves, which carries its own CSP. We do not set CSP
//     on the iframe element (no such attribute exists in HTML); the
//     server-supplied response headers are authoritative.
//   - `referrerpolicy="no-referrer"` -- pack iframes never leak the
//     host page's URL via Referer.
//   - Origin validation. If `opts.origin` is supplied, every inbound
//     message whose `event.origin !== opts.origin` is dropped, and every
//     outbound postMessage targets that origin explicitly. If omitted,
//     the host operates in loose mode (origin "*" outbound, no origin
//     check inbound). Loose mode is for development only; production
//     callers MUST pass `opts.origin`.
//   - Source validation. Every inbound message whose
//     `event.source !== iframe.contentWindow` is dropped
//     unconditionally, regardless of `opts.origin`. This prevents
//     cross-frame contamination (a sibling iframe in the same host
//     page cannot impersonate this pack).
//
// Audit. The supplied `audit` callback is invoked for:
//   - mount   ({ kind: "mount",   packBootstrapUrl, capNames })
//   - unmount ({ kind: "unmount" })
//   - every cap invocation (delegated to createHostBridge; entries have
//     shape { cap, args, ok|denied|error } per bridge.js).
// The audit channel is the operator's only ground truth for what packs
// did; do not bypass it.

import { createHostBridge } from "../js_cap_bridge/bridge.js";

/**
 * Mount a pack iframe and wire its capability bridge.
 *
 * @param {{
 *   container: Element,
 *   packBootstrapUrl: string,
 *   capNames: string[],
 *   capImpls: Map<string, (...args: unknown[]) => unknown>,
 *   audit: (entry: unknown) => void,
 *   onError?: (err: Error) => void,
 *   origin?: string,
 * }} opts
 *
 * `container` -- the DOM element to append the pack iframe to. Must be
 *   a real Element (has `appendChild`). The iframe is the only child
 *   this function creates; the container may already hold siblings.
 *
 * `packBootstrapUrl` -- the URL of the daemon-served stub page that
 *   loads bootstrap.js + pack source. This URL's origin should be
 *   distinct from the host page's origin (per-pack subdomain ideal);
 *   the iframe sandbox guarantees a unique opaque origin even when the
 *   URL origin matches, but a distinct URL origin is the
 *   defence-in-depth posture documented in
 *   docs/platform_isolation.md §3.
 *
 * `capNames` -- the names of caps the user granted for this pack. MUST
 *   be a subset of `capImpls.keys()`; mismatch throws a configuration
 *   error at mount time (silent acceptance would mean the iframe
 *   advertises caps the host cannot actually service).
 *
 * `capImpls` -- the host-side cap implementations. Map<name, fn>. May
 *   contain more entries than `capNames`; entries not in `capNames` are
 *   ignored at mount time and rejected at invocation time by the
 *   bridge's grant check (since `grantedCaps` is the `capNames` set).
 *
 * `audit` -- audit-log callback. Called for mount, unmount, and every
 *   cap invocation. See module header.
 *
 * `onError` -- optional. If supplied, called with any error thrown by
 *   the message-event listener (typically: structured-clone failures,
 *   bridge internal errors). The mount itself does not call this on
 *   configuration errors -- those throw synchronously from `mountPack`.
 *
 * `origin` -- expected iframe origin. Production callers MUST pass
 *   this; omitting it puts the host in loose mode (development only).
 *
 * @returns {{
 *   iframe: HTMLIFrameElement,
 *   unmount: () => void,
 *   audit: (entry: unknown) => void,
 * }}
 *
 * `iframe` -- the created element. The caller may attach additional
 *   handlers (e.g. `load`) but MUST NOT call removeChild directly;
 *   use `unmount` so the message listener and audit are correctly
 *   torn down.
 *
 * `unmount` -- idempotent. Removes the iframe from the container,
 *   removes the window-level message listener, and audits the
 *   unmount event. Calling twice audits twice; the second call is a
 *   no-op on DOM and listener state.
 *
 * `audit` -- the same audit function passed in, returned for caller
 *   convenience.
 */
export function mountPack(opts) {
  if (!opts || typeof opts !== "object") {
    throw new TypeError("mountPack: opts is required");
  }
  if (!opts.container || typeof opts.container.appendChild !== "function") {
    throw new TypeError("mountPack: opts.container must be a DOM Element");
  }
  if (typeof opts.packBootstrapUrl !== "string" || opts.packBootstrapUrl === "") {
    throw new TypeError("mountPack: opts.packBootstrapUrl must be a non-empty string");
  }
  if (!Array.isArray(opts.capNames)) {
    throw new TypeError("mountPack: opts.capNames must be an array");
  }
  if (!(opts.capImpls instanceof Map)) {
    throw new TypeError("mountPack: opts.capImpls must be a Map");
  }
  if (typeof opts.audit !== "function") {
    throw new TypeError("mountPack: opts.audit must be a function");
  }
  if (opts.onError !== undefined && typeof opts.onError !== "function") {
    throw new TypeError("mountPack: opts.onError must be a function when provided");
  }
  if (opts.origin !== undefined && typeof opts.origin !== "string") {
    throw new TypeError("mountPack: opts.origin must be a string when provided");
  }

  // Validate capNames is a subset of capImpls.keys(). A cap named in
  // capNames without an impl would surface to the realm as a callable
  // shell that always errors `missing` at runtime; we prefer to reject
  // at mount so the misconfiguration is observable up front, not on
  // first invocation.
  /** @type {string[]} */
  const missing = [];
  for (let i = 0; i < opts.capNames.length; i++) {
    const name = opts.capNames[i];
    if (typeof name !== "string") {
      throw new TypeError("mountPack: opts.capNames entries must be strings");
    }
    if (!opts.capImpls.has(name)) missing.push(name);
  }
  if (missing.length > 0) {
    throw new Error(
      "mountPack: capNames contains entries with no capImpls entry: " +
      missing.join(", "),
    );
  }

  const container = opts.container;
  const packBootstrapUrl = opts.packBootstrapUrl;
  const capNames = opts.capNames.slice();
  const expectedOrigin = typeof opts.origin === "string" ? opts.origin : null;
  const targetOrigin = expectedOrigin !== null ? expectedOrigin : "*";
  const audit = opts.audit;
  const onError = typeof opts.onError === "function" ? opts.onError : null;

  // ------------------------------------------------------------------
  // Iframe creation. The owning document is taken from the container;
  // this lets mountPack work in test harnesses that pass a synthetic
  // document (e.g. a node:vm-emulated window) so long as the container
  // exposes `ownerDocument.createElement`.
  // ------------------------------------------------------------------
  const ownerDocument =
    /** @type {{ ownerDocument?: Document }} */ (container).ownerDocument
    || (typeof document !== "undefined" ? document : null);
  if (!ownerDocument || typeof ownerDocument.createElement !== "function") {
    throw new TypeError(
      "mountPack: container.ownerDocument.createElement is unavailable",
    );
  }

  const iframe = /** @type {HTMLIFrameElement} */ (
    ownerDocument.createElement("iframe")
  );
  // sandbox="allow-scripts" ONLY. The realm primitive depends on this
  // exact value -- additional tokens (allow-same-origin in particular)
  // would let the pack reach the host's storage and DOM.
  iframe.setAttribute("sandbox", "allow-scripts");
  iframe.setAttribute("referrerpolicy", "no-referrer");
  iframe.setAttribute("src", packBootstrapUrl);

  // ------------------------------------------------------------------
  // Host bridge wiring. The bridge is constructed before the iframe is
  // appended so the message listener is ready for any synchronous
  // postMessage that might arrive during early iframe load. (Browsers
  // do not synchronously deliver cross-document messages, but we do
  // not want a race.)
  // ------------------------------------------------------------------
  const bridge = createHostBridge({
    grantedCaps: new Set(capNames),
    capImpls: opts.capImpls,
    audit,
    postMessage: (msg) => {
      const win = iframe.contentWindow;
      if (!win) return; // iframe unmounted or not yet contented
      win.postMessage(msg, targetOrigin);
    },
  });

  // The window the listener is installed on is the host-page window,
  // i.e. the document's defaultView. We take it from the iframe's
  // ownerDocument so this works in test contexts that supply a
  // synthetic window.
  const hostWindow =
    /** @type {{ defaultView?: Window }} */ (ownerDocument).defaultView
    || (typeof window !== "undefined" ? window : null);
  if (!hostWindow || typeof hostWindow.addEventListener !== "function") {
    throw new TypeError(
      "mountPack: ownerDocument.defaultView.addEventListener is unavailable",
    );
  }

  const messageListener = (/** @type {MessageEvent} */ event) => {
    try {
      // Source validation FIRST -- unconditional. Even if the origin
      // matches, a message from a different window in the same origin
      // is not ours.
      if (event.source !== iframe.contentWindow) return;
      if (expectedOrigin !== null && event.origin !== expectedOrigin) return;
      bridge.dispatch(event.data);
    } catch (err) {
      if (onError) onError(/** @type {Error} */ (err));
      // Otherwise swallow -- a listener throwing would terminate the
      // listener chain for unrelated handlers on the same window.
    }
  };
  hostWindow.addEventListener("message", messageListener);

  // ------------------------------------------------------------------
  // Mount.
  // ------------------------------------------------------------------
  container.appendChild(iframe);
  audit({ kind: "mount", packBootstrapUrl, capNames });

  let unmounted = false;
  const unmount = () => {
    audit({ kind: "unmount" });
    if (unmounted) return;
    unmounted = true;
    hostWindow.removeEventListener("message", messageListener);
    if (iframe.parentNode === container) {
      container.removeChild(iframe);
    }
  };

  return { iframe, unmount, audit };
}
