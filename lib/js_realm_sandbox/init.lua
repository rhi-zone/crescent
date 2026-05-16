if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- lib/js_realm_sandbox/init.lua
--
-- TYPE-ONLY MODULE. This file is NOT a runtime implementation; it
-- declares the shape of the JS module at lib/js_realm_sandbox/sandbox.js
-- so Lua-side typechecking of code that targets the browser realm gets
-- accurate signatures.
--
-- The real implementation lives in sandbox.js. It is loaded as ESM
-- inside the pack realm (sandboxed iframe today, ShadowRealm later)
-- and is the first JS to run -- before any pack-author code. It
-- structurally removes everything from the realm's globalThis except
-- the allow-list of language intrinsics and installs the host-bridged
-- caps under globalThis.__cap__.
--
-- Lua callers MUST NOT call M.install_lockdown at runtime -- it errors.
-- The function exists so Lua code that constructs realm bootstrap
-- pipelines (daemon-side: pack-load, stub-page generation, iframe
-- setup) can typecheck against the JS module's exported signature.
--
-- See docs/platform_isolation.md, especially §3 "Allow-list
-- specification (draft)" and §3 "Bootstrap order", for the spec the
-- JS implementation realises.
--
-- See also:
--   * lib/js_safe_regex/   -- the regex validator consumed by the
--                              bootstrap's RegExp / String.match /
--                              matchAll / search wrappers.
--   * lib/js_types/        -- type declarations for browser intrinsics
--                              and the cap-bridge protocol.

local M = {}

--:: InstallLockdownOpts = {
--::   caps:    { [string]: (...unknown) -> unknown } | nil,
--::   sizeCap: integer | nil,
--:: }

--: (InstallLockdownOpts | nil) -> ()
function M.install_lockdown(_opts)
  error("lib/js_realm_sandbox is type-only on the Lua side: " ..
    "use lib/js_realm_sandbox/sandbox.js at runtime in the browser " ..
    "realm bootstrap.")
end

return M
