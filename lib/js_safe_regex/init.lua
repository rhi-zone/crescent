if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- lib/js_safe_regex/init.lua
--
-- TYPE-ONLY MODULE. This file is NOT a runtime implementation; it
-- declares the shape of the JS module at lib/js_safe_regex/safe_regex.js
-- so Lua-side typechecking of code targeting the browser realm (which
-- conceptually requires the JS module via the cap-bridge / pipeline
-- mapping) gets accurate signatures.
--
-- Lua callers MUST NOT use this module at runtime — use the real Lua
-- implementation in lib/safe_regex/ instead. The JS implementation runs
-- only in the browser realm bootstrap, where it wraps RegExp /
-- String.prototype.match / matchAll / search to refuse pathological
-- patterns. The two implementations are parity-tested against each
-- other; see lib/js_safe_regex/parity_test.lua.
--
-- Convention precedent: this is the first dual-implementation js_*
-- library in crescent. The shape (init.lua declaring the JS exports
-- but erroring at runtime) is chosen so that:
--   1. Code that requires "lib.js_safe_regex" for its type signatures
--      gets a checked surface from the typechecker.
--   2. Accidental runtime use is caught immediately by a loud error
--      rather than silently doing nothing.

local M = {}

--:: ValidateResult = { ok: true } | { ok: false, error: string }

--: (string) -> ValidateResult
function M.validate_pattern(_pattern)
  error("lib/js_safe_regex is type-only on the Lua side: " ..
    "use lib/js_safe_regex/safe_regex.js at runtime in the browser " ..
    "realm, or require 'lib.safe_regex' for Lua-side validation.")
end

return M
