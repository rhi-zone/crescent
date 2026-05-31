-- lib/type/static-v6/facts.lua
-- Constructors for v6 facts and proof obligations.

local M = {}

--:: AtomType = { tag: "atom", name: string }
--:: LiteralType = { tag: "literal", base: string, value: unknown }
--:: UnknownType = { tag: "unknown" }
--:: NeverType = { tag: "never" }
--:: AnyType = { tag: "any" }
--:: UnionType = { tag: "union", members: { [integer]: StaticType } }
--:: IntersectionType = { tag: "intersection", members: { [integer]: StaticType } }
--:: ComplementType = { tag: "complement", of: StaticType }
--:: Pack = { items: { [integer]: StaticType }, rest: StaticType | nil }
--:: ArrowType = { tag: "arrow", params: Pack, returns: Pack, effects: unknown }
--:: RecordType = { tag: "record" }
--:: NominalType = { tag: "nominal", name: string }
--:: VarType = { tag: "var", id: integer }
--:: StaticType = AtomType | LiteralType | UnknownType | NeverType | AnyType | UnionType | IntersectionType | ComplementType | ArrowType | RecordType | NominalType | VarType
--:: Span = { file: string | nil, line: integer | nil, column: integer | nil, ... }
--:: Obligation = { kind: "obligation", producer: StaticType, consumer: StaticType, site: string, reason: string, span: Span | nil, discharged: boolean, ... }
--:: BindingFact = { kind: "binding", symbol: string, type: StaticType, span: Span | nil, ... }
--:: ExprFact = { kind: "expr", expr: string, type: StaticType, span: Span | nil, ... }
--:: UnsafeBoundary = { kind: "unsafe_boundary", type: StaticType, site: string, reason: string, span: Span | nil, ... }

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
