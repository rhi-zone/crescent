-- lib/type/static-v6/env.lua
-- Controlled environment updates for v6 facts and obligations.

local subtype = require("lib.type.static-v6.subtype")
local facts   = require("lib.type.static-v6.facts")

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
--:: Field = { type: StaticType, optional: boolean, readonly: boolean }
--:: Index = { key: StaticType, value: StaticType, readonly: boolean }
--:: RecordType = { tag: "record", fields: { [string]: Field }, indexes: { [integer]: Index }, row: string }
--:: NominalType = { tag: "nominal", name: string }
--:: VarType = { tag: "var", id: integer }
--:: StaticType = AtomType | LiteralType | UnknownType | NeverType | AnyType | UnionType | IntersectionType | ComplementType | ArrowType | RecordType | NominalType | VarType
--:: Span = { file: string | nil, line: integer | nil, column: integer | nil, ... }
--:: CheckDiag = { code: string, message: string, details: unknown, ... }
--:: Obligation = { kind: "obligation", producer: StaticType, consumer: StaticType, site: string, reason: string, span: Span | nil, discharged: boolean, diagnostic: CheckDiag | nil, ... }
--:: BindingFact = { kind: "binding", symbol: string, type: StaticType, span: Span | nil, ... }
--:: UnsafeBoundary = { kind: "unsafe_boundary", type: StaticType, site: string, reason: string, span: Span | nil, ... }
--:: Env = { bindings: { [string]: StaticType }, binding_facts: { [integer]: BindingFact }, obligations: { [integer]: Obligation }, unsafe_boundaries: { [integer]: UnsafeBoundary } }

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
        binding_facts = {},
        obligations = {},
        unsafe_boundaries = {},
    }
end

--: (Env, string, StaticType, Span | nil) -> BindingFact
function M.bind(env, symbol, typ, span)
    env.bindings[symbol] = typ
    local fact = facts.binding(symbol, typ, span)
    env.binding_facts[#env.binding_facts + 1] = fact
    return fact
end

--: (Env, string) -> StaticType | nil
function M.lookup(env, symbol)
    return env.bindings[symbol]
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
    return true, M.bind(env, symbol, consumer, span), nil
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
