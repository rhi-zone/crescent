-- lib/type/static-v6/diagnostics.lua
-- v6 diagnostic constructors.

local M = {}

--:: require "lib.type.static-v6.type_defs"

--: (string, string, unknown | nil) -> CheckDiag
function M.new(code, message, details)
    return {
        code = code,
        message = message,
        details = details or {},
    }
end

--: (string, unknown, unknown, string | nil) -> CheckDiag
function M.type_mismatch(message, producer, consumer, site)
    return M.new("TYPE_MISMATCH", message, {
        producer = producer,
        consumer = consumer,
        site = site,
    })
end

--: (string) -> CheckDiag
function M.complexity_limit(operation)
    return M.new("TYPE_COMPLEXITY_LIMIT",
        "type proof exceeded v6 complexity budget during " .. operation,
        { operation = operation })
end

--: (string) -> CheckDiag
function M.unsafe_any(site)
    return M.new("UNSAFE_ANY_BOUNDARY",
        "any is an explicit unsafe boundary at " .. site,
        { site = site })
end

return M
