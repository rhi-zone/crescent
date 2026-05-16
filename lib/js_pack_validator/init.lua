if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- lib/js_pack_validator/init.lua
--
-- TYPE-ONLY MODULE. This file is NOT a runtime implementation; it
-- declares the shape of the JS module at
-- lib/js_pack_validator/validator.js so Lua-side typechecking of
-- author-tool pipelines gets accurate signatures.
--
-- AUTHOR-SIDE HYGIENE TOOL. The validator runs in a pack author's
-- dev/CI environment via bun. It is NOT a daemon-side dependency:
-- docs/platform_isolation.md §3 "Pack-source validation (author-side
-- hygiene)" rejects bundling a JS parser in the daemon. The runtime
-- security boundary is lib/js_realm_sandbox/, not this validator.
--
-- Lua callers MUST NOT call M.validate at runtime -- it errors. The
-- function exists so Lua code that constructs author tooling (e.g. a
-- crescent pkg-publish hook that shells out to bun) can typecheck
-- against the JS module's exported signature.
--
-- See also:
--   * docs/platform_isolation.md §3 "Pack JS subset (draft)" -- the
--     spec the validator enforces.
--   * lib/js_safe_regex/         -- consumed by the validator for
--                                    regex literal checks.
--   * lib/js_realm_sandbox/      -- the runtime boundary (separate
--                                    concern).

local M = {}

--:: ValidationError = {
--::   message:  string,
--::   line:     integer,
--::   column:   integer,
--::   nodeType: string,
--:: }

--:: ValidationResult = { ok: true } | { ok: false, errors: ValidationError[] }

--:: ValidateOpts = {
--::   filename:             string | nil,
--::   allowedConstructors:  string[] | nil,
--:: }

--: (string, ValidateOpts | nil) -> ValidationResult
function M.validate(_source, _opts)
  error("lib/js_pack_validator is type-only on the Lua side: " ..
    "use lib/js_pack_validator/validator.js at author time via bun.")
end

return M
