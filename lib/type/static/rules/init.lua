-- lib/type/static/rules/init.lua
-- Rule pass runner infrastructure for the typechecker.
-- Each pass is a module under lib/type/static/rules/ with shape:
--   M.name        = "pass_name"
--   M.description = "one-line description"
--   M.check       = function(ctx, err_ctx, filepath) end

local M = {}

-- Registry: list of { name, pass } in registration order.
local _passes = {}

-- Default policy: all passes emit as "warning".
-- policy is a table { [rule_name] = "error"|"warning"|"off" }.
local DEFAULT_SEVERITY = "warning"

-- Register a named rule pass. Called by each pass module's own require().
--: (string, { name: string, description: string, check: function }) -> ()
function M.register(name, pass)
    _passes[#_passes + 1] = { name = name, pass = pass }
end

-- Run all registered passes against a checked file's ctx.
-- ctx:      type context from check_file (may be nil if check failed)
-- err_ctx:  diagnostic context to receive warnings/errors
-- filepath: source file path (string)
-- policy:   optional table { [rule_name] = "error"|"warning"|"off" }
--: (table?, table, string, table?) -> ()
function M.run(ctx, err_ctx, filepath, policy)
    if not ctx then return end
    policy = policy or {}
    local errors_mod = require("lib.type.static.errors")
    for _, entry in ipairs(_passes) do
        local name = entry.name
        local pass = entry.pass
        local severity = policy[name] or DEFAULT_SEVERITY
        if severity ~= "off" then
            -- Run the pass inside a pcall so a bug in one pass doesn't abort the others.
            local ok, err = pcall(pass.check, ctx, err_ctx, filepath, severity, errors_mod)
            if not ok then
                errors_mod.warning(err_ctx, filepath, 0, 0,
                    "[rule:" .. name .. "] internal error: " .. tostring(err))
            end
        end
    end
end

-- Return the list of registered passes (for introspection / testing).
--: () -> { [integer]: { name: string, pass: table }, ... }
function M.passes()
    return _passes
end

-- Auto-load all passes from this directory. Each pass module calls M.register()
-- in its body. We load them by explicit name rather than directory scanning so
-- that the set is always predictable and does not depend on the OS readdir order.
local _loaded = false
function M.load_all()
    if _loaded then return end
    _loaded = true
    local base = "lib.type.static.rules."
    local pass_names = { "unannotated", "assert_in_lib", "naming", "bare_bit" }
    for _, pname in ipairs(pass_names) do
        local ok, err = pcall(require, base .. pname)
        if not ok then
            -- Non-fatal: a missing or broken pass is skipped.
            io.stderr:write("[rules] failed to load pass '" .. pname .. "': " .. tostring(err) .. "\n")
        end
    end
end

return M
