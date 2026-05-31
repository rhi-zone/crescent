-- lib/type/static-v6/ann_test.lua
-- Tests for the v6 M1 annotation parser.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")

local ann = require("lib.type.static-v6.ann")
local ty = require("lib.type.static-v6.types")

--: (string) -> unknown
local function parse(text)
    local got, err = ann.parse_annotation(ann.new_state(), text)
    if err then error(err, 2) end
    return got
end

T.describe("v6 annotations", function()
    T.it("parses primitive and literal types", function()
        T.eq(ty.key(parse("string")), "atom:string")
        T.eq(ty.key(parse("nil")), "atom:nil")
        T.eq(ty.key(parse('"GET"')), "literal:string:GET")
        T.eq(ty.key(parse("42")), "literal:integer:42")
        T.eq(ty.key(parse("true")), "literal:boolean:true")
    end)

    T.it("parses union intersection and complement", function()
        T.eq(ty.key(parse("string | nil")), "union(atom:nil,atom:string)")
        T.eq(ty.key(parse("string & ~nil")), "intersection(atom:string,complement(atom:nil))")
    end)

    T.it("parses arrow packs structurally", function()
        local got = parse("(string, number) -> boolean")
        T.eq(got.tag, "arrow")
        T.eq(#got.params.items, 2)
        T.eq(got.returns.items[1].name, "boolean")
    end)

    T.it("parses multi-return arrow packs", function()
        local got = parse("() -> (number, string)")
        T.eq(got.tag, "arrow")
        T.eq(#got.params.items, 0)
        T.eq(#got.returns.items, 2)
        T.eq(got.returns.items[1].name, "number")
        T.eq(got.returns.items[2].name, "string")

        got = parse("() -> ()")
        T.eq(#got.returns.items, 0)
    end)

    T.it("rejects unsupported named types and tuple types", function()
        local got, err = ann.parse_annotation(ann.new_state(), "Point")
        T.eq(got, nil)
        T.ok(tostring(err):find("named types", 1, true) ~= nil, "named type error")

        got, err = ann.parse_annotation(ann.new_state(), "(string, number)")
        T.eq(got, nil)
        T.ok(tostring(err):find("tuple", 1, true) ~= nil, "tuple error")
    end)
end)
