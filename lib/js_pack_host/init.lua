if not package.path:find("?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- lib/js_pack_host/init.lua
--
-- TYPE-ONLY MODULE. This file is NOT a runtime implementation; it
-- declares the shape of the JS module at lib/js_pack_host/bootstrap.js
-- so Lua-side typechecking of code that wires the pack-iframe
-- bootstrap pipeline gets accurate signatures.
--
-- The real implementation lives in bootstrap.js. It is the iframe-side
-- (inside-iframe) bootstrap: the first JS module that runs inside a
-- pack's sandboxed iframe. It builds the realm-side cap bridge from
-- lib/js_cap_bridge/bridge.js, then installs the realm lockdown from
-- lib/js_realm_sandbox/sandbox.js, then returns. Pack source loading
-- is orchestrated by the outer host page (separate library, separate
-- commit) -- the bootstrap's contract is "lockdown + bridge setup".
--
-- Lua callers MUST NOT call M.run_bootstrap at runtime -- it errors.
-- The function exists so Lua code that assembles browser-side
-- pipelines (daemon stub-page generation, iframe orchestration) can
-- typecheck against the JS module's exported signature.
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

return M
