-- lib/type/static-v6/algebra_test.lua
-- Conformance tests for v6 vertical 1: value algebra + subtyping.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local v6 = require("lib.type.static-v6")

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
--:: CheckDiag = { code: string, message: string, details: unknown, ... }
--:: TypesModule = { atom: (string) -> StaticType, literal: (string, unknown) -> StaticType, unknown: () -> StaticType, never: () -> StaticType, any: () -> StaticType, union: ({ [integer]: StaticType }) -> StaticType, intersection: ({ [integer]: StaticType }) -> StaticType, complement: (StaticType) -> StaticType, tostring: (StaticType) -> string }
--:: SubtypeModule = { is_subtype: (StaticType, StaticType, { term_budget: integer, site: string }) -> (boolean, CheckDiag | nil) }
--:: NormalizeModule = { normalize: (StaticType, { term_budget: integer, site: string } | nil) -> (StaticType | nil, CheckDiag | nil) }

local ty = v6.types --: TypesModule
local sub = v6.subtype --: SubtypeModule
local norm = v6.normalize --: NormalizeModule

--: (StaticType, StaticType, string | nil) -> nil
local function assert_sub(a, b, msg)
    local ok_, err = sub.is_subtype(a, b, { site = "test", term_budget = 256 })
    local suffix = ""
    if err then suffix = err.message end
    T.ok(ok_, msg or (ty.tostring(a) .. " <: " .. ty.tostring(b) .. " failed: " .. suffix))
end

--: (StaticType, StaticType, string | nil) -> nil
local function assert_not_sub(a, b, code)
    local ok_, err = sub.is_subtype(a, b, { site = "test", term_budget = 256 })
    T.ok(not ok_, ty.tostring(a) .. " should not subtype " .. ty.tostring(b))
    if code then T.eq(err.code, code, "reason code") end
end

T.describe("v6 algebra + subtyping", function()
    T.it("literal widening", function()
        assert_sub(ty.literal("string", "GET"), ty.atom("string"))
        assert_sub(ty.literal("integer", 42), ty.atom("integer"))
        assert_sub(ty.literal("integer", 42), ty.atom("number"))
        assert_not_sub(ty.literal("string", "GET"), ty.atom("number"))
    end)

    T.it("nil is an ordinary union member", function()
        local nil_or_string = ty.union({ ty.atom("nil"), ty.atom("string") })
        assert_sub(ty.atom("nil"), nil_or_string)
        assert_sub(ty.atom("string"), nil_or_string)
        assert_not_sub(nil_or_string, ty.atom("string"))
    end)

    T.it("union left requires every member to satisfy consumer", function()
        local nums = ty.union({ ty.atom("integer"), ty.literal("integer", 1) })
        assert_sub(nums, ty.atom("number"))

        local mixed = ty.union({ ty.atom("integer"), ty.atom("string") })
        assert_not_sub(mixed, ty.atom("number"))
    end)

    T.it("intersection right requires all consumer parts", function()
        local both = ty.intersection({ ty.atom("number"), ty.unknown() })
        assert_sub(ty.atom("integer"), both)
        assert_not_sub(ty.atom("string"), both)
    end)

    T.it("intersection left can provide a usable part", function()
        local both = ty.intersection({ ty.atom("string"), ty.atom("number") })
        assert_sub(both, ty.atom("string"))
        assert_sub(both, ty.atom("number"))
        assert_not_sub(both, ty.atom("boolean"))
    end)

    T.it("complement basics", function()
        assert_sub(ty.atom("string"), ty.complement(ty.atom("number")))
        assert_not_sub(ty.atom("string"), ty.complement(ty.atom("string")))
        assert_sub(ty.literal("string", "x"), ty.complement(ty.literal("string", "y")))
    end)

    T.it("unknown is top consumer but not concrete producer", function()
        assert_sub(ty.atom("string"), ty.unknown())
        assert_not_sub(ty.unknown(), ty.atom("string"), "UNKNOWN_REQUIRES_NARROWING")
    end)

    T.it("any is routed as unsafe boundary", function()
        assert_not_sub(ty.any(), ty.atom("string"), "UNSAFE_ANY_BOUNDARY")
        assert_not_sub(ty.atom("string"), ty.any(), "UNSAFE_ANY_BOUNDARY")
    end)

    T.it("normalization deduplicates and flattens unions", function()
        local u = ty.union({
            ty.atom("string"),
            ty.union({ ty.atom("string"), ty.atom("number") }),
            ty.never(),
        })
        local got, err = norm.normalize(u)
        T.eq(err, nil, "no normalization error")
        T.eq(got.tag, "union", "still union")
        T.eq(#got.members, 2, "deduplicated members")
    end)

    T.it("complexity limit rejects instead of widening", function()
        local members = {}
        for i = 1, 5 do members[i] = ty.literal("integer", i) end
        local got, err = norm.normalize(ty.union(members), { site = "test", term_budget = 3 })
        T.eq(got, nil, "no type when over budget")
        T.eq(err.code, "TYPE_COMPLEXITY_LIMIT", "complexity diagnostic")
    end)
end)
