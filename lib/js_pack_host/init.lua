if not package.path:find("?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- lib/js_pack_host/init.lua
--
-- TYPE-ONLY MODULE. This file is NOT a runtime implementation; it
-- declares the shape of the JS modules at lib/js_pack_host/bootstrap.js
-- (inside-iframe) and lib/js_pack_host/host.js (outside-iframe) so
-- Lua-side typechecking of code that wires the pack-iframe pipeline
-- gets accurate signatures.
--
-- bootstrap.js is the iframe-side bootstrap: the first JS module that
-- runs inside a pack's sandboxed iframe. It builds the realm-side cap
-- bridge from lib/js_cap_bridge/bridge.js, then installs the realm
-- lockdown from lib/js_realm_sandbox/sandbox.js, then returns. Pack
-- source loading is orchestrated by the outer host page.
--
-- host.js is the outside-iframe host-page wiring. It creates a
-- cross-origin sandboxed iframe (sandbox="allow-scripts" only), loads
-- a daemon-served bootstrap URL inside it, and wires the host-side
-- cap bridge (createHostBridge) to the iframe's window via
-- postMessage. Returns { iframe, unmount, audit }.
--
-- Lua callers MUST NOT call M.run_bootstrap or M.mount_pack at
-- runtime -- they error. The functions exist so Lua code that
-- assembles browser-side pipelines (daemon stub-page generation,
-- iframe orchestration) can typecheck against the JS modules'
-- exported signatures.
--
-- See docs/platform_isolation.md §3 "Bootstrap script" / "Bootstrap
-- order" for the spec the JS implementation realises.
--
-- See also:
--   * lib/js_realm_sandbox/  -- the realm lockdown invoked by the
--                                bootstrap; installs the bridge-
--                                produced cap shells onto
--                                globalThis.__cap__.
--   * lib/js_cap_bridge/     -- the postMessage cap bridge whose
--                                realm-side half this bootstrap
--                                instantiates.

local M = {}

--:: RealmBridge = {
--::   caps:     { [string]: (...unknown) -> unknown },
--::   dispatch: (unknown) -> (),
--:: }

--:: RunBootstrapOpts = {
--::   capNames:                string[],
--::   postMessage:             (unknown) -> (),
--::   registerMessageHandler:  ((unknown) -> ()) -> (),
--::   sizeCap:                 integer | nil,
--:: }

--: (RunBootstrapOpts) -> RealmBridge
function M.run_bootstrap(_opts)
  error("lib/js_pack_host is type-only on the Lua side: " ..
    "use lib/js_pack_host/bootstrap.js at runtime in the pack iframe.")
end

--:: MountPackOpts = {
--::   container:        unknown,
--::   packBootstrapUrl: string,
--::   capNames:         string[],
--::   capImpls:         unknown,
--::   audit:            (unknown) -> (),
--::   onError:          ((unknown) -> ()) | nil,
--::   origin:           string | nil,
--:: }

--:: PackHandle = {
--::   iframe:  unknown,
--::   unmount: () -> (),
--::   audit:   (unknown) -> (),
--:: }

--: (MountPackOpts) -> PackHandle
function M.mount_pack(_opts)
  error("lib/js_pack_host is type-only on the Lua side: " ..
    "use lib/js_pack_host/host.js at runtime in the host page.")
end

return M
