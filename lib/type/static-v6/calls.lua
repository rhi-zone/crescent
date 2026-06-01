-- lib/type/static-v6/calls.lua
-- Pure v6 arrow and overload call checking over already-built argument packs.

local pack_result = require("lib.type.static-v6.pack_result")
local subtype = require("lib.type.static-v6.subtype")
local types = require("lib.type.static-v6.types")

local M = {}

--:: require "lib.type.static-v6.type_defs"
--:: ArgsForArity = (arity: integer) -> { [integer]: StaticType }
--:: CallCheck = { ok: boolean, result: PackResult | nil, code: string | nil, message: string | nil, diagnostic: CheckDiag | nil }
--:: ArrowPackCheck = { ok: boolean, pack: Pack | nil, code: string | nil, message: string | nil, diagnostic: CheckDiag | nil }

--: (StaticType, { [integer]: ArrowType }) -> boolean
function M.collect_arrow_branches(typ, out)
    if typ.tag == "arrow" then
        out[#out + 1] = typ
        return true
    end
    if typ.tag == "intersection" then
        for _, member in ipairs(typ.members) do
            if not M.collect_arrow_branches(member, out) then return false end
        end
        return true
    end
    return false
end

--: (string, string) -> CallCheck
local function code_failure(code, message)
    return { ok = false, result = nil, code = code, message = message, diagnostic = nil }
end

--: (CheckDiag | nil) -> CallCheck
local function diagnostic_failure(diagnostic)
    return { ok = false, result = nil, code = nil, message = nil, diagnostic = diagnostic }
end

--: (PackResult) -> CallCheck
local function success(result)
    return { ok = true, result = result, code = nil, message = nil, diagnostic = nil }
end

--: (string, string) -> ArrowPackCheck
local function arrow_code_failure(code, message)
    return { ok = false, pack = nil, code = code, message = message, diagnostic = nil }
end

--: (CheckDiag | nil) -> ArrowPackCheck
local function arrow_diagnostic_failure(diagnostic)
    return { ok = false, pack = nil, code = nil, message = nil, diagnostic = diagnostic }
end

--: (Pack) -> ArrowPackCheck
local function arrow_success(pack)
    return { ok = true, pack = pack, code = nil, message = nil, diagnostic = nil }
end

--: (ArrowPackCheck) -> CallCheck
local function pack_failure_to_call(checked)
    if checked.diagnostic then return diagnostic_failure(checked.diagnostic) end
    return code_failure(checked.code or "INTERNAL_TYPECHECKER_ERROR", checked.message or "call checking failed")
end

--: (ArrowType, { [integer]: StaticType }) -> ArrowPackCheck
local function check_arrow_pack(callee, args)
    local params = callee.params
    local returns = callee.returns
    if params == nil or returns == nil then
        return arrow_code_failure("INTERNAL_TYPECHECKER_ERROR", "arrow type missing pack")
    end
    if params.rest ~= nil or returns.rest ~= nil then
        return arrow_code_failure("FEATURE_NOT_ADMITTED", "v6 M2 calls do not admit open packs yet")
    end
    if #args ~= #params.items then
        return arrow_code_failure("FUNCTION_ARITY_MISMATCH",
            "call arity " .. tostring(#args) .. " does not match parameter arity " .. tostring(#params.items))
    end
    for i = 1, #args do
        local ok, err = subtype.is_subtype(args[i], params.items[i], {
            site = "call argument",
            term_budget = 256,
        })
        if not ok then
            return arrow_diagnostic_failure(err)
        end
    end
    return arrow_success(returns)
end

--: (StaticType, ArgsForArity) -> CallCheck
function M.check(callee, args_for_arity)
    if callee.tag == "unknown" then
        return success(pack_result.from_items({ types.unknown() }))
    end
    if callee.tag == "arrow" then
        local params = callee.params
        if params == nil then
            return code_failure("INTERNAL_TYPECHECKER_ERROR", "arrow type missing parameter pack")
        end
        local checked = check_arrow_pack(callee, args_for_arity(#params.items)) --: ArrowPackCheck
        if not checked.ok then return pack_failure_to_call(checked) end
        local pack = checked.pack
        if pack == nil then return code_failure("INTERNAL_TYPECHECKER_ERROR", "arrow check produced no pack") end
        return success(pack_result.single(pack))
    end

    local branches = {} --: { [integer]: ArrowType }
    if not M.collect_arrow_branches(callee, branches) then
        return code_failure("CANNOT_CALL", "cannot call non-function type " .. types.tostring(callee))
    end

    local matches = {} --: { [integer]: Pack }
    for _, branch in ipairs(branches) do
        local params = branch.params
        if params ~= nil then
            local checked = check_arrow_pack(branch, args_for_arity(#params.items)) --: ArrowPackCheck
            if checked.ok then
                local pack = checked.pack
                if pack ~= nil then matches[#matches + 1] = pack end
            end
        end
    end
    if #matches == 0 then
        return code_failure("NO_MATCHING_OVERLOAD", "no overload branch accepts argument pack")
    end
    return success(pack_result.union(matches))
end

return M
