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
-- Uses a fresh state unless one is supplied.
--: (string, AnnState | nil) -> V5Type
local function pt(text, state)
    local st = state or ann.new_state()
    local ty, err = ann.parse_annotation(st, text)
    if ty == nil then
        error("parse_annotation failed for `" .. text .. "`: " .. tostring(err), 2)
    end
    return ty
end

-- Assert that a parsed type round-trips to the expected V5Type.
--: (string, V5Type, AnnState | nil) -> nil
local function assert_eq(text, expected, state)
    local got = pt(text, state)
    T.ok(types_mod.equal(got, expected),
        "parse `" .. text .. "`: mismatch (got tag=" .. got.tag .. ")")
end

-- Assert that a parsed type has a given tag.
--: (string, string, AnnState | nil) -> V5Type
local function assert_tag(text, tag, state)
    local got = pt(text, state)
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
    local lit = types_mod.literal
    T.it("string literal double-quote", function()
        assert_eq('"hello"', lit("string", "hello"))
    end)
    T.it("string literal single-quote", function()
        assert_eq("'world'", lit("string", "world"))
    end)
    T.it("integer literal 0", function()
        -- Sanity: scan_number_lit on "0" must yield literal(integer, 0).
        assert_eq("0", lit("integer", 0))
    end)
    T.it("integer literal 42", function()
        assert_eq("42", lit("integer", 42))
    end)
    T.it("float literal 3.14", function()
        assert_eq("3.14", lit("number", 3.14))
    end)
    T.it("true literal", function()
        assert_eq("true", lit("boolean", true))
    end)
    T.it("false literal", function()
        assert_eq("false", lit("boolean", false))
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
            T.eq(#got.args.items, 0, "no params")
        end
    end)
    T.it("single param (string) -> number", function()
        local got = pt("(string) -> number")
        T.ok(got.tag == "arrow", "is arrow")
        if got.tag == "arrow" then
            T.eq(#got.args.items, 1, "one param")
        end
    end)
    T.it("two param (string, number) -> boolean", function()
        local got = pt("(string, number) -> boolean")
        T.ok(got.tag == "arrow", "is arrow")
        if got.tag == "arrow" then
            T.eq(#got.args.items, 2, "two params")
        end
    end)
    T.it("named params (x: number, y: number) -> number", function()
        local got = pt("(x: number, y: number) -> number")
        T.ok(got.tag == "arrow", "is arrow")
        if got.tag == "arrow" then
            T.eq(#got.args.items, 2, "two params")
        end
    end)
    T.it("bare right-associative arrow string -> number", function()
        assert_tag("string -> number", "arrow")
    end)
    T.it("higher-order function ((string) -> number) -> boolean", function()
        local got = pt("((string) -> number) -> boolean")
        T.ok(got.tag == "arrow", "is arrow")
        if got.tag == "arrow" then
            local p = got.args.items[1]
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
            T.ok(ret.tag == "pack", "ret is pack")
            if ret.tag == "pack" then
                local r1 = ret.items[1]
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
                T.ok(types_mod.equal(fx.type, con("number")), "x: number")
                T.ok(not fx.optional and not fx.readonly, "x: not optional/readonly")
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
    T.it("index signature [string]: T stores an indexes[] entry", function()
        local got = pt("{ [string]: number }")
        T.ok(got.tag == "record", "record")
        if got.tag == "record" then
            T.eq(#got.indexes, 1, "one index signature")
            local ix = got.indexes[1]
            if ix ~= nil then
                T.ok(types_mod.equal(ix.key, con("string")), "index key string")
                T.ok(types_mod.equal(ix.value, con("number")), "index value number")
            end
        end
    end)
    T.it("optional field x?: T stores fields.x.optional", function()
        local got = pt("{ x?: number }")
        T.ok(got.tag == "record", "record")
        if got.tag == "record" then
            local fx = got.fields["x"]
            T.ok(fx ~= nil, "has field x")
            if fx ~= nil then T.ok(fx.optional, "x is optional") end
        end
    end)
    T.it("readonly field stores fields.x.readonly", function()
        local got = pt("{ readonly x: number }")
        T.ok(got.tag == "record", "record")
        if got.tag == "record" then
            local fx = got.fields["x"]
            T.ok(fx ~= nil, "has field x")
            if fx ~= nil then T.ok(fx.readonly, "x is readonly") end
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
            T.ok(ret.tag == "pack", "ret is pack")
            if ret.tag == "pack" then
                local r1 = ret.items[1]
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
        local st = ann.new_state()
        local dir, err = ann.parse_declaration(st, "declare effect !Io : 0")
        T.ok(err == nil, "no error: " .. tostring(err))
        T.ok(dir ~= nil, "directive returned")
        if dir ~= nil then
            T.eq(dir.kind, "declare_effect", "kind")
            T.eq(dir.name, "Io", "effect name")
            T.eq(dir.arity, 0, "arity 0")
        end
    end)
    T.it("declare effect !Throw : 1 registers arity", function()
        local st = ann.new_state()
        local dir, err = ann.parse_declaration(st, "declare effect !Throw : 1")
        T.ok(err == nil, "no error: " .. tostring(err))
        T.ok(dir ~= nil, "directive returned")
        if dir ~= nil then
            T.eq(dir.kind, "declare_effect", "kind")
            T.eq(dir.name, "Throw", "effect name")
            T.eq(dir.arity, 1, "arity 1")
        end
    end)
    T.it("declare effect !Yield : 2 then use correctly", function()
        local st = ann.new_state()
        ann.parse_declaration(st, "declare effect !Yield : 2")
        local ty, err = ann.parse_annotation(st, "!Yield<number, string>")
        T.ok(err == nil, "no error: " .. tostring(err))
        T.ok(ty ~= nil, "type returned")
    end)
    T.it("arity mismatch (arity=2, given 1) is an error", function()
        local st = ann.new_state()
        ann.declare_effect(st, "TestArityMismatch", 2)
        local ty, err = ann.parse_annotation(st, "!TestArityMismatch<string>")
        T.ok(ty == nil, "nil type on arity mismatch")
        T.ok(err ~= nil, "error reported")
    end)
    T.it("bare use of arity-0 effect is ok", function()
        local st = ann.new_state()
        ann.declare_effect(st, "IoZero", 0)
        local ty, err = ann.parse_annotation(st, "!IoZero")
        T.ok(err == nil, "no error: " .. tostring(err))
        T.ok(ty ~= nil, "type returned")
    end)
    T.it("bare use of arity-1 effect is an error", function()
        local st = ann.new_state()
        ann.declare_effect(st, "Must1Arg", 1)
        local ty, err = ann.parse_annotation(st, "!Must1Arg")
        T.ok(ty == nil, "nil type on missing args")
        T.ok(err ~= nil, "error reported")
    end)
    T.it("declare_effect API registers arity", function()
        local st = ann.new_state()
        ann.declare_effect(st, "DirectAPI", 2)
        local ty, err = ann.parse_annotation(st, "!DirectAPI<string, number>")
        T.ok(err == nil, "no error: " .. tostring(err))
        T.ok(ty ~= nil, "type returned")
    end)
end)

-- ── Declaration parsing ───────────────────────────────────────────────────────

T.describe("declarations", function()
    T.it("type alias MyType = string", function()
        local st = ann.new_state()
        local dir, err = ann.parse_declaration(st, "MyType = string")
        T.ok(err == nil, "no error: " .. tostring(err))
        T.ok(dir ~= nil, "directive")
        if dir ~= nil then
            T.eq(dir.kind, "type_alias", "kind")
            T.eq(dir.name, "MyType", "name")
        end
    end)
    T.it("type alias with params List<T> = { [integer]: T }", function()
        local st = ann.new_state()
        local dir, err = ann.parse_declaration(st, "List<T> = { [integer]: T }")
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
        local st = ann.new_state()
        local dir, err = ann.parse_declaration(st, "Map<K, V> = { [K]: V }")
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
        local st = ann.new_state()
        local dir, err = ann.parse_declaration(st, "declare x = number")
        T.ok(err == nil, "no error: " .. tostring(err))
        T.ok(dir ~= nil, "directive")
        if dir ~= nil then
            T.eq(dir.kind, "declare_var", "kind")
            T.eq(dir.name, "x", "name")
        end
    end)
    T.it("module directive", function()
        local st = ann.new_state()
        local dir, err = ann.parse_declaration(st, 'module "foo.bar": string')
        T.ok(err == nil, "no error: " .. tostring(err))
        T.ok(dir ~= nil, "directive")
        if dir ~= nil then
            T.eq(dir.kind, "module", "kind")
            T.eq(dir.mod_name, "foo.bar", "mod_name")
        end
    end)
    T.it("require directive", function()
        local st = ann.new_state()
        local dir, err = ann.parse_declaration(st, 'require "foo.bar"')
        T.ok(err == nil, "no error: " .. tostring(err))
        T.ok(dir ~= nil, "directive")
        if dir ~= nil then
            T.eq(dir.kind, "require", "kind")
            T.eq(dir.mod_name, "foo.bar", "mod_name")
        end
    end)
    T.it("template directive", function()
        local st = ann.new_state()
        local dir, err = ann.parse_declaration(st, "template")
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
        local st = ann.new_state()
        local ty, err = ann.parse_annotation(st, "")
        T.ok(ty == nil, "nil on empty")
        T.ok(err ~= nil, "error string")
    end)
    T.it("unclosed paren returns error", function()
        local st = ann.new_state()
        local ty, err = ann.parse_annotation(st, "(string")
        T.ok(ty == nil or err ~= nil, "error or nil")
    end)
    T.it("unknown char @ returns error", function()
        local st = ann.new_state()
        local ty, err = ann.parse_annotation(st, "@")
        T.ok(ty == nil, "nil on '@'")
        T.ok(err ~= nil, "error string")
    end)
    T.it("bare ! with no name returns error", function()
        local st = ann.new_state()
        local ty, err = ann.parse_annotation(st, "!")
        T.ok(ty == nil, "nil on bare '!'")
        T.ok(err ~= nil, "error string")
    end)
    T.it("empty declaration returns error", function()
        local st = ann.new_state()
        local dir, err = ann.parse_declaration(st, "")
        T.ok(dir == nil, "nil directive")
        T.ok(err ~= nil, "error string")
    end)
end)

-- ── Array sugar and postfix ───────────────────────────────────────────────────

T.describe("postfix", function()
    T.it("string[] parses as a record with an integer index signature", function()
        local got = pt("string[]")
        T.eq(got.tag, "record", "record")
        if got.tag == "record" then
            T.eq(#got.indexes, 1, "one index signature")
            local ix = got.indexes[1]
            if ix ~= nil then
                T.ok(types_mod.equal(ix.key, con("integer")), "index key integer")
                T.ok(types_mod.equal(ix.value, con("string")), "index value string")
            end
        end
    end)
    T.it("T? is handled without crash", function()
        local st = ann.new_state()
        local ty, _err = ann.parse_annotation(st, "string?")
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
    T.it("typeof x errors as unsupported in v5", function()
        local st = ann.new_state()
        local ty, err = ann.parse_annotation(st, "typeof x")
        T.ok(ty == nil, "nil on typeof")
        T.ok(err ~= nil, "error reported")
    end)
end)

-- ── State isolation regression test ──────────────────────────────────────────
--
-- Verifies R7: two independent parse sessions with separate AnnState objects
-- must not share row-var IDs.  The first open-record type in state1 gets row-var
-- id=1; the first open-record type in state2 must also get id=1, not id=2.
--
-- Also verifies R8: effect arities registered in state1 must not leak into
-- state2.

T.describe("state isolation (R7 + R8)", function()
    T.it("row-var IDs restart in a fresh state", function()
        local st1 = ann.new_state()
        local st2 = ann.new_state()

        -- Parse an open-record in st1; this consumes row-var id=1 in st1.
        local ty1 = pt("{ x: number, ... }", st1)
        T.ok(ty1.tag == "record", "st1: is record")
        local row1 = ty1.row
        T.ok(row1 ~= nil, "st1: has row variable")

        -- Parse the same annotation in a fresh st2; it must also get id=1.
        local ty2 = pt("{ x: number, ... }", st2)
        T.ok(ty2.tag == "record", "st2: is record")
        local row2 = ty2.row
        T.ok(row2 ~= nil, "st2: has row variable")

        -- Both should have gotten id=1 (fresh counter in each state).
        if row1 ~= nil and row2 ~= nil then
            T.eq(row1.id, 1, "st1 row-var id is 1")
            T.eq(row2.id, 1, "st2 row-var id is 1 (restarted, not continued)")
        end

        -- Consume another row-var in st1; st1's counter is now at 3.
        local ty1b = pt("{ y: string, ... }", st1)
        T.ok(ty1b.row ~= nil, "st1 second open record has row")
        if ty1b.row ~= nil then
            T.eq(ty1b.row.id, 2, "st1 second row-var id is 2")
        end

        -- st2's counter should still be at 2 (only consumed one row-var).
        local ty2b = pt("{ y: string, ... }", st2)
        T.ok(ty2b.row ~= nil, "st2 second open record has row")
        if ty2b.row ~= nil then
            T.eq(ty2b.row.id, 2, "st2 second row-var id is 2 (independent from st1)")
        end
    end)

    T.it("effect arities do not leak across states", function()
        local st1 = ann.new_state()
        local st2 = ann.new_state()

        -- Register !MyFx with arity 1 in st1.
        ann.declare_effect(st1, "MyFx", 1)

        -- In st1, bare !MyFx (arity-1 effect) should be an error.
        local ty1, err1 = ann.parse_annotation(st1, "!MyFx")
        T.ok(ty1 == nil, "st1: bare !MyFx (arity 1) is error")
        T.ok(err1 ~= nil, "st1: error reported for bare !MyFx")

        -- In st2 (fresh, no arities registered), bare !MyFx should succeed
        -- (treated as undeclared, arity 0 allowed).
        local ty2, err2 = ann.parse_annotation(st2, "!MyFx")
        T.ok(ty2 ~= nil, "st2: bare !MyFx succeeds (arity not registered in st2)")
        T.ok(err2 == nil, "st2: no error for undeclared !MyFx")
    end)
end)

-- ── Y10: augment / unseal explicit error (not silent misparse) ────────────────

T.describe("parse_declaration unsupported v4 directives", function()
    T.it("augment produces explicit unsupported error", function()
        local state = ann.new_state()
        local dir, err = ann.parse_declaration(state, "augment Foo { x: integer }")
        T.ok(dir == nil, "augment: directive should be nil")
        T.ok(err ~= nil, "augment: error should be non-nil")
        if err ~= nil then
            local errs = tostring(err)
            T.ok(errs:find("augment") ~= nil,
                "augment error mentions 'augment' (got: " .. errs .. ")")
            T.ok(errs:find("not yet supported") ~= nil,
                "augment error mentions 'not yet supported' (got: " .. errs .. ")")
        end
    end)

    T.it("unseal produces explicit unsupported error", function()
        local state = ann.new_state()
        local dir, err = ann.parse_declaration(state, "unseal Foo")
        T.ok(dir == nil, "unseal: directive should be nil")
        T.ok(err ~= nil, "unseal: error should be non-nil")
        if err ~= nil then
            local errs = tostring(err)
            T.ok(errs:find("unseal") ~= nil,
                "unseal error mentions 'unseal' (got: " .. errs .. ")")
            T.ok(errs:find("not yet supported") ~= nil,
                "unseal error mentions 'not yet supported' (got: " .. errs .. ")")
        end
    end)

    T.it("type_alias still parses fine after augment/unseal guards", function()
        local state = ann.new_state()
        local dir, err = ann.parse_declaration(state, "MyAlias = string")
        T.ok(err == nil, "type_alias: no error (got: " .. tostring(err) .. ")")
        T.ok(dir ~= nil, "type_alias: directive non-nil")
        if dir ~= nil then
            T.eq(dir.kind, "type_alias", "type_alias: kind is type_alias")
            T.eq(dir.name, "MyAlias", "type_alias: name is MyAlias")
        end
    end)

    T.it("declare still parses fine after augment/unseal guards", function()
        local state = ann.new_state()
        local dir, err = ann.parse_declaration(state, "declare myVar = integer")
        T.ok(err == nil, "declare: no error (got: " .. tostring(err) .. ")")
        T.ok(dir ~= nil, "declare: directive non-nil")
        if dir ~= nil then
            T.eq(dir.kind, "declare_var", "declare: kind is declare_var")
            T.eq(dir.name, "myVar", "declare: name is myVar")
        end
    end)
end)

-- ── Match types (Spec B part 2: TMatch + captures + all-fields + rest) ─────────

-- Parse a match annotation and return its arms (the parser guarantees a TMatch).
--: (string) -> { pattern: V5Type, result: V5Type }[]
local function parse_arms(text)
    local ty = pt(text)
    if ty.tag ~= "match" then error("expected a match type for `" .. text .. "`", 2) end
    return ty.arms
end

T.describe("match types", function()
    T.it("parses match with literal and wildcard arms", function()
        local arms = parse_arms('match F { "GET" => integer, _ => string }')
        T.eq(#arms, 2, "two arms")
        local a1 = arms[1]
        local a2 = arms[2]
        if a1 ~= nil then
            T.eq(a1.pattern.tag, "literal", "arm 1 pattern is a literal")
            T.eq(a1.result.tag, "const", "arm 1 result is a const")
        end
        if a2 ~= nil then
            local p2 = a2.pattern
            T.eq(p2.tag, "capture", "arm 2 pattern is a capture (wildcard)")
            if p2.tag == "capture" then T.eq(p2.idx, -1, "wildcard capture idx is -1") end
        end
    end)

    T.it("a %Name capture in a pattern binds, and bare Name in result references it", function()
        local arms = parse_arms("match T { { a: %X } => X }")
        local a1 = arms[1]
        if a1 ~= nil then
            local pat = a1.pattern
            T.eq(pat.tag, "record", "arm 1 pattern is a record")
            local res = a1.result
            T.eq(res.tag, "capture", "result X resolves to the capture")
            if pat.tag == "record" and res.tag == "capture" then
                local fa = pat.fields["a"]
                T.ok(fa ~= nil and fa.type.tag == "capture", "field a is a capture")
                if fa ~= nil and fa.type.tag == "capture" then
                    T.eq(res.idx, fa.type.idx, "result idx matches pattern capture idx")
                end
            end
        end
    end)

    T.it("all-fields distribution { ...[%K]: %V } lowers to patallfields", function()
        local arms = parse_arms("match T { { ...[%K]: %V } => V }")
        local a1 = arms[1]
        if a1 ~= nil then
            local pat = a1.pattern
            local res = a1.result
            T.eq(pat.tag, "patallfields", "pattern is patallfields")
            T.eq(res.tag, "capture", "result references %V")
            if pat.tag == "patallfields" and res.tag == "capture" then
                T.eq(res.idx, pat.v, "result idx is the V binder")
            end
        end
    end)

    T.it("rest-field capture { f: T, ...%Rest } stores the '...' reserved field", function()
        local arms = parse_arms("match T { { a: integer, ...%Rest } => Rest }")
        local a1 = arms[1]
        if a1 ~= nil then
            local pat = a1.pattern
            T.eq(pat.tag, "record", "pattern is a record")
            if pat.tag == "record" then
                local restf = pat.fields["..."]
                T.ok(restf ~= nil and restf.type.tag == "capture", "rest capture stored under '...'")
            end
            T.eq(a1.result.tag, "capture", "result references Rest")
        end
    end)

    T.it("() -> %R arrow pattern", function()
        local arms = parse_arms("match F { () -> %R => R }")
        local a1 = arms[1]
        if a1 ~= nil then
            local pat = a1.pattern
            T.eq(pat.tag, "arrow", "pattern is an arrow")
            if pat.tag == "arrow" then
                local aitems = pat.args.items
                if aitems ~= nil then T.eq(#aitems, 0, "args pack is empty (param wildcard)") end
            end
            T.eq(a1.result.tag, "capture", "result references %R")
        end
    end)

    T.it("each arm has its own capture scope (indices reset per arm)", function()
        local arms = parse_arms("match T { %A => A, %B => B }")
        local a1 = arms[1]
        local a2 = arms[2]
        if a1 ~= nil and a1.pattern.tag == "capture" then T.eq(a1.pattern.idx, 0, "arm 1 capture idx is 0") end
        if a2 ~= nil and a2.pattern.tag == "capture" then T.eq(a2.pattern.idx, 0, "arm 2 capture idx resets to 0") end
    end)
end)
