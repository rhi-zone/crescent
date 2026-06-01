-- lib/type/static-v6/facts_env_test.lua
-- Expected runtime behavior for v6 obligations, facts, and environments.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")

local ty    = require("lib.type.static-v6.types")
local facts = require("lib.type.static-v6.facts")
local env   = require("lib.type.static-v6.env")

--:: require "lib.type.static-v6.type_defs"
--:: FactsModule = { obligation: (StaticType, StaticType, string, string, Span | nil) -> Obligation, binding: (string, StaticType, Span | nil) -> BindingFact, unsafe_boundary: (StaticType, string, string, Span | nil) -> UnsafeBoundary }
--:: EnvModule = { new: () -> table, bind: (table, string, StaticType, Span | nil) -> BindingFact, bind_checked: (table, string, StaticType, StaticType, string, string, Span | nil) -> (boolean, BindingFact | nil, CheckDiag | nil), lookup: (table, string) -> StaticType | nil, require_subtype: (table, StaticType, StaticType, string, string, Span | nil) -> Obligation, record_unsafe_boundary: (table, StaticType, string, string, Span | nil) -> UnsafeBoundary, discharge_obligation: (Obligation) -> (boolean, CheckDiag | nil), discharge_all: (table) -> (boolean, { [integer]: CheckDiag }) }

--: (unknown, string) -> nil
local function assert_type(v, want)
    T.eq(type(v), want)
end

T.describe("v6 facts + env", function()
    T.it("constructs obligations with provenance", function()
        local span = { file = "facts_env_test.lua", line = 12, column = 9 }
        local obligation = facts.obligation(
            ty.literal("string", "GET"),
            ty.atom("string"),
            "local annotation",
            "annotation claim",
            span
        )

        T.eq(obligation.kind, "obligation")
        T.eq(obligation.producer.tag, "literal")
        T.eq(obligation.consumer.tag, "atom")
        T.eq(obligation.site, "local annotation")
        T.eq(obligation.span, span)
        T.eq(obligation.reason, "annotation claim")
        T.eq(obligation.discharged, false)
    end)

    T.it("discharges obligations through subtype checks", function()
        local good = facts.obligation(
            ty.literal("integer", 42),
            ty.atom("number"),
            "numeric widening",
            "initializer satisfies annotation"
        )
        local ok, err = env.discharge_obligation(good)
        T.eq(ok, true)
        T.eq(err, nil)
        T.eq(good.discharged, true)
        T.eq(good.diagnostic, nil)

        local bad = facts.obligation(
            ty.atom("string"),
            ty.atom("number"),
            "bad assignment",
            "assignment target"
        )
        ok, err = env.discharge_obligation(bad)
        T.eq(ok, false)
        T.eq(err.code, "TYPE_MISMATCH")
        T.eq(err.details.site, "bad assignment")
        T.eq(err.details.obligation_reason, "assignment target")
        T.eq(err.details.obligation_site, "bad assignment")
        T.eq(bad.discharged, false)
        T.eq(bad.diagnostic, err)
    end)

    T.it("checked binding installs consumer claim only after proof", function()
        local root = env.new()
        local span = { file = "facts_env_test.lua", line = 80, column = 9 }

        local ok, fact, err = env.bind_checked(
            root,
            "n",
            ty.literal("integer", 1),
            ty.atom("number"),
            "local n",
            "annotation",
            span
        )
        T.eq(ok, true)
        T.eq(err, nil)
        T.eq(fact.type.name, "number")
        T.eq(env.lookup(root, "n").name, "number")

        ok, fact, err = env.bind_checked(
            root,
            "bad",
            ty.atom("string"),
            ty.atom("number"),
            "local bad",
            "annotation",
            span
        )
        T.eq(ok, false)
        T.eq(fact, nil)
        T.eq(err.code, "TYPE_MISMATCH")
        T.eq(env.lookup(root, "bad"), nil)
    end)

    T.it("uses binding environment operations for definitions", function()
        local root = env.new()
        assert_type(root, "table")

        local span = { file = "facts_env_test.lua", line = 78, column = 15 }
        local fact = env.bind(root, "count", ty.atom("number"), span)
        T.eq(fact.kind, "binding")
        T.eq(fact.symbol, "count")
        T.eq(fact.type.tag, "atom")
        T.eq(fact.type.name, "number")
        T.eq(fact.span, span)

        local count_type = env.lookup(root, "count")
        T.eq(count_type.tag, "atom")
        T.eq(count_type.name, "number")
        T.eq(#root.binding_facts, 1)
        T.eq(root.binding_facts[1], fact)
    end)

    T.it("creates subtype obligations through the environment", function()
        local root = env.new()
        local span = { file = "facts_env_test.lua", line = 96, column = 11 }
        local obligation = env.require_subtype(
            root,
            ty.literal("integer", 1),
            ty.atom("number"),
            "count = 1",
            "assignment",
            span
        )

        T.eq(obligation.kind, "obligation")
        T.eq(obligation.producer.tag, "literal")
        T.eq(obligation.consumer.name, "number")
        T.eq(obligation.site, "count = 1")
        T.eq(obligation.reason, "assignment")
        T.eq(obligation.span, span)
        T.eq(#root.obligations, 1)
        T.eq(root.obligations[1], obligation)

        local ok, errors = env.discharge_all(root)
        T.eq(ok, true)
        T.eq(#errors, 0)
        T.eq(obligation.discharged, true)
    end)

    T.it("records unsafe boundaries as explicit audit facts", function()
        local root = env.new()
        local span = { file = "vendor.lua", line = 1, column = 1 }
        local boundary = env.record_unsafe_boundary(
            root,
            ty.any(),
            "foreign import",
            "ffi import has no static type",
            span
        )

        T.eq(boundary.kind, "unsafe_boundary")
        T.eq(boundary.type.tag, "any")
        T.eq(boundary.site, "foreign import")
        T.eq(boundary.reason, "ffi import has no static type")
        T.eq(boundary.span, span)
        T.eq(#root.unsafe_boundaries, 1)
        T.eq(root.unsafe_boundaries[1], boundary)

        local obligation = env.require_subtype(
            root,
            ty.any(),
            ty.atom("string"),
            "foreign import",
            "unsafe boundary must be audited"
        )
        local ok, err = env.discharge_obligation(obligation)
        T.eq(ok, false)
        T.eq(err.code, "UNSAFE_ANY_BOUNDARY")
    end)
end)
