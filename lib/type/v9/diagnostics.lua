-- lib/type/v9/diagnostics.lua
-- Diagnostics seam — errors as DATA, never thrown (crescent convention:
-- `(nil, errmsg)` returns). Outside the proof (the proof has no diagnostics);
-- the contract is just "produce a stable, inspectable Diag from a verdict".

--:: require "lib.type.v9.type_defs"

local M = {}
M.name = "default"

-- A definite subtyping FAILURE ("notsub"): the actual type cannot flow into the
-- expected type.
--: (TypeRep, Ty, Ty, string) -> Diag
function M.mismatch(rep, actual, expected, site)
    return {
        code = "type_mismatch",
        message = site .. ": " .. rep.show(actual) .. " is not a subtype of " .. rep.show(expected),
        actual = rep.show(actual),
        expected = rep.show(expected),
    }
end

-- An UNDECIDED subtyping query ("unknown"): honest deferral surfaced as an
-- error rather than a silent accept (no fail-optimism).
--: (TypeRep, Ty, Ty, string) -> Diag
function M.unprovable(rep, actual, expected, site)
    return {
        code = "subtype_unprovable",
        message = site .. ": cannot prove " .. rep.show(actual) .. " <: " .. rep.show(expected)
            .. " (deferred; no backend decided it)",
        actual = rep.show(actual),
        expected = rep.show(expected),
    }
end

--: (string, string) -> Diag
function M.make(code, message)
    return { code = code, message = message }
end

return M
