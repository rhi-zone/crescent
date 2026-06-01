-- lib/type/static-v6/facts.lua
-- Constructors for v6 facts and proof obligations.

local M = {}

--:: require "lib.type.static-v6.type_defs"

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

--: (string, StaticType, Span | nil) -> BindingFact
function M.binding(symbol, typ, span)
    return {
        kind = "binding",
        symbol = symbol,
        type = typ,
        span = span,
    }
end

--: (string, StaticType, Span | nil) -> ExprFact
function M.expr(expr, typ, span)
    return {
        kind = "expr",
        expr = expr,
        type = typ,
        span = span,
    }
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
