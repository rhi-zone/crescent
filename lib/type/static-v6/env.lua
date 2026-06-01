-- lib/type/static-v6/env.lua
-- Controlled environment updates for v6 facts and obligations.

local subtype = require("lib.type.static-v6.subtype")
local facts   = require("lib.type.static-v6.facts")

local M = {}

--:: require "lib.type.static-v6.type_defs"

--: (CheckDiag, Obligation) -> CheckDiag
local function attach_obligation_context(err, obligation)
    local details = err.details
    if type(details) ~= "table" then details = {} end
    details.obligation_reason = obligation.reason
    details.obligation_span = obligation.span
    details.obligation_site = obligation.site
    details.span = details.span or obligation.span
    details.producer = details.producer or obligation.producer
    details.consumer = details.consumer or obligation.consumer
    err.details = details
    return err
end

--: () -> Env
function M.new()
    return {
        bindings = {},
        binding_claims = {},
        binding_facts = {},
        obligations = {},
        unsafe_boundaries = {},
        identities = {},
        next_identity_id = 0,
    }
end

--: (Env, string, ValueClaim, Span | nil) -> BindingFact
function M.bind_claim(env, symbol, claim, span)
    env.bindings[symbol] = claim.type
    env.binding_claims[symbol] = claim
    local fact = facts.binding_claim(symbol, claim, span)
    env.binding_facts[#env.binding_facts + 1] = fact
    return fact
end

--: (Env, string, StaticType, Span | nil) -> BindingFact
function M.bind(env, symbol, typ, span)
    local claim = facts.value_claim(typ) --: ValueClaim
    return M.bind_claim(env, symbol, claim, span)
end

--: (Env, string) -> StaticType | nil
function M.lookup(env, symbol)
    return env.bindings[symbol]
end

--: (Env, string) -> ValueClaim | nil
function M.lookup_claim(env, symbol)
    return env.binding_claims[symbol]
end

--: (Env, Obligation) -> Obligation
function M.add_obligation(env, obligation)
    env.obligations[#env.obligations + 1] = obligation
    return obligation
end

--: (Env, StaticType, StaticType, string, string, Span | nil) -> Obligation
function M.require_subtype(env, producer, consumer, site, reason, span)
    return M.add_obligation(env, facts.obligation(producer, consumer, site, reason, span))
end

--: (Env, string, StaticType, StaticType, string, string, Span | nil) -> (boolean, BindingFact | nil, CheckDiag | nil)
function M.bind_checked(env, symbol, producer, consumer, site, reason, span)
    local obligation = M.require_subtype(env, producer, consumer, site, reason, span)
    local ok, err = M.discharge_obligation(obligation)
    if not ok then return false, nil, err end
    local claim = facts.value_claim(consumer) --: ValueClaim
    return true, M.bind_claim(env, symbol, claim, span), nil
end

--: (Env, StaticType, string, string, Span | nil) -> UnsafeBoundary
function M.record_unsafe_boundary(env, typ, site, reason, span)
    local boundary = facts.unsafe_boundary(typ, site, reason, span)
    env.unsafe_boundaries[#env.unsafe_boundaries + 1] = boundary
    return boundary
end

--: (Obligation) -> (boolean, CheckDiag | nil)
function M.discharge_obligation(obligation)
    if obligation.discharged then return true, nil end
    if obligation.diagnostic then return false, obligation.diagnostic end
    local ok, err = subtype.is_subtype(obligation.producer, obligation.consumer, {
        site = obligation.site,
        term_budget = 256,
    })
    obligation.discharged = ok
    if err then err = attach_obligation_context(err, obligation) end
    obligation.diagnostic = err
    return ok, err
end

--: (Env) -> (boolean, { [integer]: CheckDiag })
function M.discharge_all(env)
    local errors = {} --: { [integer]: CheckDiag }
    for _, obligation in ipairs(env.obligations) do
        local ok, err = M.discharge_obligation(obligation)
        if not ok and err then
            errors[#errors + 1] = err
        end
    end
    return #errors == 0, errors
end

return M
