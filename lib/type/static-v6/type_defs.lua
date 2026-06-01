-- lib/type/static-v6/type_defs.lua
-- Shared v6 annotation-only type definitions.

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

--:: PackResultSingle = { tag: "single", pack: Pack }
--:: PackResultUnion = { tag: "union", alternatives: { [integer]: Pack } }
--:: PackResult = PackResultSingle | PackResultUnion

--:: Span = { file: string | nil, line: integer | nil, column: integer | nil, ... }
--:: CheckDiag = { code: string, message: string, details: unknown, ... }
--:: Obligation = { kind: "obligation", producer: StaticType, consumer: StaticType, site: string, reason: string, span: Span | nil, discharged: boolean, diagnostic: CheckDiag | nil, ... }
--:: BindingFact = { kind: "binding", symbol: string, type: StaticType, span: Span | nil, ... }
--:: ExprFact = { kind: "expr", expr: string, type: StaticType, span: Span | nil, ... }
--:: UnsafeBoundary = { kind: "unsafe_boundary", type: StaticType, site: string, reason: string, span: Span | nil, ... }
--:: Env = { bindings: { [string]: StaticType }, binding_facts: { [integer]: BindingFact }, obligations: { [integer]: Obligation }, unsafe_boundaries: { [integer]: UnsafeBoundary } }

--:: CheckOpts = { term_budget: integer, site: string, ... }

return {}
