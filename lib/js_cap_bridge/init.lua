if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- lib/js_cap_bridge/init.lua
--
-- TYPE-ONLY MODULE. This file is NOT a runtime implementation; it
-- declares the shape of the JS module at lib/js_cap_bridge/bridge.js so
-- Lua-side typechecking of code that wires realm <-> host pipelines
-- gets accurate signatures.
--
-- The real implementation lives in bridge.js. It is a pure protocol
-- implementation -- postMessage and message-handler registration are
-- injected, so the same code paths run in node:vm test contexts and in
-- real iframes wired to window.postMessage / message events.
--
-- Lua callers MUST NOT call M.create_realm_bridge or M.create_host_bridge
-- at runtime -- they error. The functions exist so Lua code that
-- assembles browser-side pipelines (daemon stub-page generation,
-- pack-load orchestration) can typecheck against the JS module's
-- exported signatures.
--
-- See docs/platform_isolation.md §4 "Capability bridge protocol" for
-- the spec the JS module realises.
--
-- See also:
--   * lib/js_realm_sandbox/  -- the realm lockdown that installs the
--                                bridge-produced cap shells onto
--                                globalThis.__cap__.
--   * lib/js_pack_validator/ -- author-side hygiene tool (parallel
--                                concern, not used at runtime).

local M = {}

--:: CallEnvelope = {
--::   id:   integer,
--::   kind: "call",
--::   cap:  string,
--::   args: unknown[],
--:: }

--:: ResultEnvelope = {
--::   id:    integer,
--::   kind:  "result",
--::   value: unknown,
--:: }

--:: ErrorEnvelope = {
--::   id:    integer,
--::   kind:  "error",
--::   error: { type: string, message: string },
--:: }

--:: ResponseEnvelope = ResultEnvelope | ErrorEnvelope

--:: AuditEntry = {
--::   cap:    string,
--::   args:   unknown[],
--::   ok:     boolean | nil,
--::   error:  unknown | nil,
--::   denied: string | nil,
--:: }

--:: RealmBridgeOpts = {
--::   capNames:                string[],
--::   postMessage:             (unknown) -> (),
--::   registerMessageHandler:  ((unknown) -> ()) -> () | nil,
--:: }

--:: RealmBridge = {
--::   caps:     { [string]: (...unknown) -> unknown },
--::   dispatch: (unknown) -> (),
--:: }

--:: HostBridgeOpts = {
--::   grantedCaps: { [string]: true },
--::   capImpls:    { [string]: (...unknown) -> unknown },
--::   audit:       (AuditEntry) -> (),
--::   postMessage: (unknown) -> (),
--:: }

--:: HostBridge = {
--::   dispatch: (unknown) -> (),
--:: }

--: (RealmBridgeOpts) -> RealmBridge
function M.create_realm_bridge(_opts)
  error("lib/js_cap_bridge is type-only on the Lua side: " ..
    "use lib/js_cap_bridge/bridge.js at runtime in the browser realm " ..
    "or in node:vm test contexts.")
end

--: (HostBridgeOpts) -> HostBridge
function M.create_host_bridge(_opts)
  error("lib/js_cap_bridge is type-only on the Lua side: " ..
    "use lib/js_cap_bridge/bridge.js at runtime in the host stub page.")
end

return M
