-- lib/type/static-v5/ann_test.lua
-- Tests for the v5 annotation parser (lib/type/static-v5/ann.lua).
-- Covers every surface form plus the new effect-type syntax.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T         = require("lib.test.assert")
local types_mod = require("lib.type.experiments.v5_perf.types")
local ann       = require("lib.type.static-v5.ann")

-- ── helpers ─────────────────────────────────────────────────────────────────

-- Parse a type annotation string; fail test on error.
--: (string) -> V5Type
local function pt(text)
    local ty, err = ann.parse_annotation(text)
    if ty == nil then
        error("parse_annotation failed for `" .. text .. "`: " .. tostring(err), 2)
    end
    return ty
end

-- Assert that a parsed type round-trips to the expected V5Type.
--: (string, V5Type) -> nil
local function assert_eq(text, expected)
    local got = pt(text)
    T.ok(types_mod.equal(got, expected),
        "parse `" .. text .. "`: mismatch (got tag=" .. got.tag .. ")")
end

-- Assert that a parsed type has a given tag.
--: (string, string) -> V5Type
local function assert_tag(text, tag)
    local got = pt(text)
    T.eq(got.tag, tag, "parse `" .. text .. "`: expected tag " .. tag)
    return got
end

local con  = types_mod.const
local app  = types_mod.app
local un   = types_mod.union
local isec = types_mod.intersection
local arr  = types_mod.arrow
local rec  = types_mod.record
local reco = types_mod.record_open
local eff  = types_mod.effect
local eapp = types_mod.effect_apply

-- ── Primitive types ──────────────────────────────────────────────────────────

T.describe("primitives", function()
    T.it("nil",     function() assert_eq("nil",     con("nil")) end)
    T.it("boolean", function() assert_eq("boolean", con("boolean")) end)
    T.it("number",  function() assert_eq("number",  con("number")) end)
    T.it("string",  function() assert_eq("string",  con("string")) end)
    T.it("integer", function() assert_eq("integer", con("integer")) end)
    T.it("never",   function() assert_eq("never",   con("never")) end)
    T.it("unknown", function() assert_eq("unknown", con("unknown")) end)
    T.it("cdata",   function() assert_eq("cdata",   con("cdata")) end)
end)

-- ── Literal types ────────────────────────────────────────────────────────────

T.describe("literals", function()
    T.it("string literal double-quote", function()
        assert_eq('"hello"', app(con("$LitStr"), con("hello")))
    end)
    T.it("string literal single-quote", function()
        assert_eq("'world'", app(con("$LitStr"), con("world")))
    end)
    T.it("integer literal 42", function()
        assert_eq("42", app(con("$LitInt"), con("42")))
    end)
    T.it("float literal 3.14", function()
        assert_eq("3.14", app(con("$LitNum"), con("3.14")))
    end)
    T.it("true literal", function()
        assert_eq("true", app(con("$LitBool"), con("true")))
    end)
    T.it("false literal", function()
        assert_eq("false", app(con("$LitBool"), con("false")))
    end)
end)

-- ── Named types and generics ─────────────────────────────────────────────────

T.describe("named types", function()
    T.it("plain name", function()
        assert_eq("Foo", con("Foo"))
    end)
    T.it("single generic List<string>", function()
        assert_eq("List<string>", app(con("List"), con("string")))
    end)
    T.it("two-arg generic Map<string, number>", function()
        assert_eq("Map<string, number>",
            app(app(con("Map"), con("string")), con("number")))
    end)
    T.it("three-arg generic F<A, B, C>", function()
        assert_eq("F<A, B, C>",
            app(app(app(con("F"), con("A")), con("B")), con("C")))
    end)
    T.it("nested generic List<Map<string, number>>", function()
        assert_eq("List<Map<string, number>>",
            app(con("List"), app(app(con("Map"), con("string")), con("number"))))
    end)
end)

-- ── Intrinsic types ($) ──────────────────────────────────────────────────────

T.describe("intrinsics", function()
    T.it("bare intrinsic $Require", function()
        assert_eq("$Require", con("$Require"))
    end)
    T.it("intrinsic with arg $Require<string>", function()
        assert_eq("$Require<string>", app(con("$Require"), con("string")))
    end)
    T.it("intrinsic two args $Opaque<T, U>", function()
        assert_eq("$Opaque<T, U>", app(app(con("$Opaque"), con("T")), con("U")))
    end)
end)

-- ── Union types ──────────────────────────────────────────────────────────────

T.describe("union", function()
    T.it("A | B", function()
        assert_eq("string | nil", un({ con("string"), con("nil") }))
    end)
    T.it("A | B | C", function()
        assert_eq("string | number | nil",
            un({ con("string"), con("number"), con("nil") }))
    end)
    T.it("union with generic", function()
        assert_eq("List<string> | nil",
            un({ app(con("List"), con("string")), con("nil") }))
    end)
    T.it("A | B has tag union", function()
        assert_tag("A | B", "union")
    end)
end)

-- ── Intersection types ───────────────────────────────────────────────────────

T.describe("intersection", function()
    T.it("A & B", function()
        assert_eq("Foo & Bar", isec({ con("Foo"), con("Bar") }))
    end)
    T.it("A & B & C", function()
        assert_eq("A & B & C", isec({ con("A"), con("B"), con("C") }))
    end)
    T.it("intersection has tag intersection", function()
        assert_tag("Foo & Bar", "intersection")
    end)
    T.it("intersection binds tighter than union (outer is union)", function()
        assert_tag("A | B & C", "union")
    end)
end)

-- ── Function types ───────────────────────────────────────────────────────────

T.describe("function types", function()
    T.it("zero-param function () -> string", function()
        assert_tag("() -> string", "arrow")
    end)
    T.it("zero-param has no args", function()
        local got = pt("() -> string")
        T.ok(got.tag == "arrow", "is arrow")
        if got.tag == "arrow" then
            T.eq(#got.args, 0, "no params")
        end
    end)
    T.it("single param (string) -> number", function()
        local got = pt("(string) -> number")
        T.ok(got.tag == "arrow", "is arrow")
        if got.tag == "arrow" then
            T.eq(#got.args, 1, "one param")
        end
    end)
    T.it("two param (string, number) -> boolean", function()
        local got = pt("(string, number) -> boolean")
        T.ok(got.tag == "arrow", "is arrow")
        if got.tag == "arrow" then
            T.eq(#got.args, 2, "two params")
        end
    end)
    T.it("named params (x: number, y: number) -> number", function()
        local got = pt("(x: number, y: number) -> number")
        T.ok(got.tag == "arrow", "is arrow")
        if got.tag == "arrow" then
            T.eq(#got.args, 2, "two params")
        end
    end)
    T.it("bare right-associative arrow string -> number", function()
        assert_tag("string -> number", "arrow")
    end)
    T.it("higher-order function ((string) -> number) -> boolean", function()
        local got = pt("((string) -> number) -> boolean")
        T.ok(got.tag == "arrow", "is arrow")
        if got.tag == "arrow" then
            local p = got.args[1]
            T.ok(p ~= nil, "has first param")
            if p ~= nil then
                T.eq(p.tag, "arrow", "param is arrow")
            end
        end
    end)
    T.it("spread return () -> ...(string)", function()
        local got = pt("() -> ...(string)")
        T.ok(got.tag == "arrow", "is arrow")
        if got.tag == "arrow" then
            local ret = got.ret
            T.ok(ret.tag == "record", "ret is record")
            if ret.tag == "record" then
                local r1 = ret.fields["1"]
                T.ok(r1 ~= nil, "has return slot")
                if r1 ~= nil then
                    T.eq(r1.tag, "app", "spread is app")
                end
            end
        end
    end)
    T.it("function keyword alias", function()
        assert_tag("function(string) -> number", "arrow")
    end)
end)

-- ── Record types ─────────────────────────────────────────────────────────────

T.describe("record types", function()
    T.it("empty record {}", function()
        assert_tag("{}", "record")
    end)
    T.it("empty record has no fields", function()
        local got = pt("{}")
        T.ok(got.tag == "record", "record")
        if got.tag == "record" then
            local count = 0
            for _ in pairs(got.fields) do count = count + 1 end
            T.eq(count, 0, "no fields")
        end
    end)
    T.it("single field { x: number }", function()
        local got = pt("{ x: number }")
        T.ok(got.tag == "record", "record")
        if got.tag == "record" then
            local fx = got.fields["x"]
            T.ok(fx ~= nil, "has field x")
            if fx ~= nil then
                T.ok(types_mod.equal(fx, con("number")), "x: number")
            end
        end
    end)
    T.it("two fields { x: number, y: string }", function()
        local got = pt("{ x: number, y: string }")
        T.ok(got.tag == "record", "record")
        if got.tag == "record" then
            T.ok(got.fields["x"] ~= nil, "has x")
            T.ok(got.fields["y"] ~= nil, "has y")
        end
    end)
    T.it("open record has row variable", function()
        local got = pt("{ x: number, ... }")
        T.ok(got.tag == "record", "record")
        if got.tag == "record" then
            T.ok(got.row ~= nil, "has row variable")
            T.ok(got.fields["x"] ~= nil, "has field x")
        end
    end)
    T.it("index signature [string]: T stores indexer", function()
        local got = pt("{ [string]: number }")
        T.ok(got.tag == "record", "record")
        if got.tag == "record" then
            T.ok(got.fields["$idx_1"] ~= nil, "has $idx_1 field")
        end
    end)
    T.it("optional field x?: T stores as $opt_x", function()
        local got = pt("{ x?: number }")
        T.ok(got.tag == "record", "record")
        if got.tag == "record" then
            T.ok(got.fields["$opt_x"] ~= nil, "has $opt_x field")
        end
    end)
    T.it("semicolon-separated fields", function()
        local got = pt("{ x: number; y: string }")
        T.ok(got.tag == "record", "record")
        if got.tag == "record" then
            T.ok(got.fields["x"] ~= nil, "has x")
            T.ok(got.fields["y"] ~= nil, "has y")
        end
    end)
end)

-- ── Effect types (NEW) ────────────────────────────────────────────────────────

T.describe("effect types", function()
    T.it("bare effect head !Io", function()
        assert_eq("!Io", eff("Io"))
    end)
    T.it("bare effect head !io (lowercase)", function()
        assert_eq("!io", eff("io"))
    end)
    T.it("effect with one arg !Throw<string>", function()
        assert_eq("!Throw<string>", eapp(eff("Throw"), { con("string") }))
    end)
    T.it("effect with two args !Yield<number, string>", function()
        assert_eq("!Yield<number, string>",
            eapp(eff("Yield"), { con("number"), con("string") }))
    end)
    T.it("effect in union string | !Io", function()
        local got = pt("string | !Io")
        T.ok(got.tag == "union", "outer is union")
        if got.tag == "union" then
            local x2 = got.xs[2]
            T.ok(x2 ~= nil, "has second member")
            if x2 ~= nil then
                T.ok(types_mod.is_effect_head(x2), "second member is effect")
            end
        end
    end)
    T.it("effect in function return () -> !Io", function()
        local got = pt("() -> !Io")
        T.ok(got.tag == "arrow", "arrow")
        if got.tag == "arrow" then
            local ret = got.ret
            T.ok(ret.tag == "record", "ret is record")
            if ret.tag == "record" then
                local r1 = ret.fields["1"]
                T.ok(r1 ~= nil, "has return slot")
                if r1 ~= nil then
                    T.ok(types_mod.is_effect_head(r1), "return is effect head")
                end
            end
        end
    end)
    T.it("is_effect_head recognizes !Io", function()
        local ty = pt("!Io")
        T.ok(types_mod.is_effect_head(ty), "is_effect_head")
    end)
    T.it("is_effect recognizes !Throw<string> app chain", function()
        local ty = pt("!Throw<string>")
        T.ok(types_mod.is_effect(ty), "is_effect on app chain")
    end)
    T.it("effect is a const tagged value", function()
        local ty = pt("!Net")
        T.eq(ty.tag, "const", "effect is const")
        if ty.tag == "const" then
            T.eq(ty.name, "!Net", "effect const name")
        end
    end)
end)

-- ── declare effect directive ──────────────────────────────────────────────────

T.describe("declare effect directive", function()
    T.it("declare effect !Io : 0 returns directive", function()
        local dir, err = ann.parse_declaration("declare effect !Io : 0")
        T.ok(err == nil, "no error: " .. tostring(err))
        T.ok(dir ~= nil, "directive returned")
        if dir ~= nil then
            T.eq(dir.kind, "declare_effect", "kind")
            T.eq(dir.name, "Io", "effect name")
            T.eq(dir.arity, 0, "arity 0")
        end
    end)
    T.it("declare effect !Throw : 1 registers arity", function()
        local dir, err = ann.parse_declaration("declare effect !Throw : 1")
        T.ok(err == nil, "no error: " .. tostring(err))
        T.ok(dir ~= nil, "directive returned")
        if dir ~= nil then
            T.eq(dir.kind, "declare_effect", "kind")
            T.eq(dir.name, "Throw", "effect name")
            T.eq(dir.arity, 1, "arity 1")
        end
    end)
    T.it("declare effect !Yield : 2 then use correctly", function()
        ann.parse_declaration("declare effect !Yield : 2")
        local ty, err = ann.parse_annotation("!Yield<number, string>")
        T.ok(err == nil, "no error: " .. tostring(err))
        T.ok(ty ~= nil, "type returned")
    end)
    T.it("arity mismatch (arity=2, given 1) is an error", function()
        ann.declare_effect("TestArityMismatch", 2)
        local ty, err = ann.parse_annotation("!TestArityMismatch<string>")
        T.ok(ty == nil, "nil type on arity mismatch")
        T.ok(err ~= nil, "error reported")
    end)
    T.it("bare use of arity-0 effect is ok", function()
        ann.declare_effect("IoZero", 0)
        local ty, err = ann.parse_annotation("!IoZero")
        T.ok(err == nil, "no error: " .. tostring(err))
        T.ok(ty ~= nil, "type returned")
    end)
    T.it("bare use of arity-1 effect is an error", function()
        ann.declare_effect("Must1Arg", 1)
        local ty, err = ann.parse_annotation("!Must1Arg")
        T.ok(ty == nil, "nil type on missing args")
        T.ok(err ~= nil, "error reported")
    end)
    T.it("declare_effect API registers arity", function()
        ann.declare_effect("DirectAPI", 2)
        local ty, err = ann.parse_annotation("!DirectAPI<string, number>")
        T.ok(err == nil, "no error: " .. tostring(err))
        T.ok(ty ~= nil, "type returned")
    end)
end)

-- ── Declaration parsing ───────────────────────────────────────────────────────

T.describe("declarations", function()
    T.it("type alias MyType = string", function()
        local dir, err = ann.parse_declaration("MyType = string")
        T.ok(err == nil, "no error: " .. tostring(err))
        T.ok(dir ~= nil, "directive")
        if dir ~= nil then
            T.eq(dir.kind, "type_alias", "kind")
            T.eq(dir.name, "MyType", "name")
        end
    end)
    T.it("type alias with params List<T> = { [integer]: T }", function()
        local dir, err = ann.parse_declaration("List<T> = { [integer]: T }")
        T.ok(err == nil, "no error: " .. tostring(err))
        T.ok(dir ~= nil, "directive")
        if dir ~= nil then
            T.eq(dir.kind, "type_alias", "kind")
            T.eq(dir.name, "List", "name")
            local ps = dir.params
            T.ok(ps ~= nil, "has params")
            if type(ps) == "table" then
                T.eq(#ps, 1, "one param")
                T.eq(ps[1], "T", "param is T")
            end
        end
    end)
    T.it("type alias two params Map<K, V>", function()
        local dir, err = ann.parse_declaration("Map<K, V> = { [K]: V }")
        T.ok(err == nil, "no error: " .. tostring(err))
        T.ok(dir ~= nil, "directive")
        if dir ~= nil then
            local ps = dir.params
            if type(ps) == "table" then
                T.eq(#ps, 2, "two params")
            end
        end
    end)
    T.it("declare var x = number", function()
        local dir, err = ann.parse_declaration("declare x = number")
        T.ok(err == nil, "no error: " .. tostring(err))
        T.ok(dir ~= nil, "directive")
        if dir ~= nil then
            T.eq(dir.kind, "declare_var", "kind")
            T.eq(dir.name, "x", "name")
        end
    end)
    T.it("module directive", function()
        local dir, err = ann.parse_declaration('module "foo.bar": string')
        T.ok(err == nil, "no error: " .. tostring(err))
        T.ok(dir ~= nil, "directive")
        if dir ~= nil then
            T.eq(dir.kind, "module", "kind")
            T.eq(dir.mod_name, "foo.bar", "mod_name")
        end
    end)
    T.it("require directive", function()
        local dir, err = ann.parse_declaration('require "foo.bar"')
        T.ok(err == nil, "no error: " .. tostring(err))
        T.ok(dir ~= nil, "directive")
        if dir ~= nil then
            T.eq(dir.kind, "require", "kind")
            T.eq(dir.mod_name, "foo.bar", "mod_name")
        end
    end)
    T.it("template directive", function()
        local dir, err = ann.parse_declaration("template")
        T.ok(err == nil, "no error: " .. tostring(err))
        T.ok(dir ~= nil, "directive")
        if dir ~= nil then
            T.eq(dir.kind, "template", "kind")
        end
    end)
end)

-- ── Error cases ───────────────────────────────────────────────────────────────

T.describe("error handling", function()
    T.it("empty annotation returns error", function()
        local ty, err = ann.parse_annotation("")
        T.ok(ty == nil, "nil on empty")
        T.ok(err ~= nil, "error string")
    end)
    T.it("unclosed paren returns error", function()
        local ty, err = ann.parse_annotation("(string")
        T.ok(ty == nil or err ~= nil, "error or nil")
    end)
    T.it("unknown char @ returns error", function()
        local ty, err = ann.parse_annotation("@")
        T.ok(ty == nil, "nil on '@'")
        T.ok(err ~= nil, "error string")
    end)
    T.it("bare ! with no name returns error", function()
        local ty, err = ann.parse_annotation("!")
        T.ok(ty == nil, "nil on bare '!'")
        T.ok(err ~= nil, "error string")
    end)
    T.it("empty declaration returns error", function()
        local dir, err = ann.parse_declaration("")
        T.ok(dir == nil, "nil directive")
        T.ok(err ~= nil, "error string")
    end)
end)

-- ── Array sugar and postfix ───────────────────────────────────────────────────

T.describe("postfix", function()
    T.it("string[] parses as $Idx app", function()
        local got = pt("string[]")
        T.eq(got.tag, "app", "app")
    end)
    T.it("T? is handled without crash", function()
        local ty, _err = ann.parse_annotation("string?")
        T.ok(ty ~= nil or _err ~= nil, "does not crash")
    end)
end)

-- ── Spread ────────────────────────────────────────────────────────────────────

T.describe("spread", function()
    T.it("...string standalone is $Spread app", function()
        local got = pt("...string")
        T.eq(got.tag, "app", "app")
        if got.tag == "app" then
            local h = got.f
            T.ok(h ~= nil, "has head")
            if h ~= nil then
                T.eq(h.tag, "const", "head is const")
                if h.tag == "const" then
                    T.eq(h.name, "$Spread", "$Spread head")
                end
            end
        end
    end)
end)

-- ── Intersection with effects ─────────────────────────────────────────────────

T.describe("intersection with effects", function()
    T.it("string & !Io is intersection", function()
        assert_tag("string & !Io", "intersection")
    end)
    T.it("string & !Io parts are string and effect", function()
        local got = pt("string & !Io")
        T.ok(got.tag == "intersection", "intersection")
        if got.tag == "intersection" then
            T.eq(#got.parts, 2, "two parts")
            local p1 = got.parts[1]
            local p2 = got.parts[2]
            T.ok(p1 ~= nil, "has part 1")
            T.ok(p2 ~= nil, "has part 2")
            if p1 ~= nil then
                T.ok(types_mod.equal(p1, con("string")), "part 1 is string")
            end
            if p2 ~= nil then
                T.ok(types_mod.is_effect_head(p2), "part 2 is effect")
            end
        end
    end)
end)

-- ── typeof ────────────────────────────────────────────────────────────────────

T.describe("typeof", function()
    T.it("typeof x parses as $Typeof app", function()
        local got = pt("typeof x")
        T.eq(got.tag, "app", "app")
        if got.tag == "app" then
            local h = got.f
            T.ok(h ~= nil, "has head")
            if h ~= nil then
                T.ok(types_mod.equal(h, con("$Typeof")), "$Typeof head")
            end
        end
    end)
end)
