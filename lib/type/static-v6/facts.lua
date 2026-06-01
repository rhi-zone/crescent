-- lib/type/static-v6/facts.lua
-- Constructors for v6 facts and proof obligations.

local M = {}

--:: require "lib.type.static-v6.type_defs"

--: (StaticType) -> ValueClaim
function M.value_claim(typ)
    return {
        type = typ,
    }
end

--: (StaticType, IdentityId) -> ValueClaim
function M.identity_claim(typ, identity)
    return {
        type = typ,
        identity = identity,
    }
end

--: (StaticType, StaticType, string, string, Span | nil) -> Obligation
function M.obligation(producer, consumer, site, reason, span)
    return {
        kind = "obligation",
        producer = producer,
        consumer = consumer,
        site = site,
        reason = reason,
        span = span,
        discharged = false,
        diagnostic = nil,
    }
end

--: (string, ValueClaim, Span | nil) -> BindingFact
function M.binding_claim(symbol, claim, span)
    return {
        kind = "binding",
        symbol = symbol,
        type = claim.type,
        claim = claim,
        span = span,
    }
end

--: (string, StaticType, Span | nil) -> BindingFact
function M.binding(symbol, typ, span)
    return M.binding_claim(symbol, M.value_claim(typ), span)
end

--: (string, ValueClaim, Span | nil) -> ExprFact
function M.expr_claim(expr, claim, span)
    return {
        kind = "expr",
        expr = expr,
        type = claim.type,
        claim = claim,
        span = span,
    }
end

--: (string, StaticType, Span | nil) -> ExprFact
function M.expr(expr, typ, span)
    return M.expr_claim(expr, M.value_claim(typ), span)
end

--: (StaticType, string, string, Span | nil) -> UnsafeBoundary
function M.unsafe_boundary(typ, site, reason, span)
    return {
        kind = "unsafe_boundary",
        type = typ,
        site = site,
        reason = reason,
        span = span,
    }
end

return M
