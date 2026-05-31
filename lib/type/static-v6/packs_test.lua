-- lib/type/static-v6/packs_test.lua
-- Conformance tests for v6 structural packs.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")

local ty = require("lib.type.static-v6.types")
local packs = require("lib.type.static-v6.packs")

T.describe("v6 packs", function()
    T.it("constructs fixed packs without applying Lua adjustment semantics", function()
        local p = packs.pack({ ty.atom("number"), ty.atom("string") })
        T.eq(packs.fixed_arity(p), 2)
        T.eq(packs.is_open(p), false)
        T.eq(packs.tostring(p), "(number, string)")
    end)

    T.it("constructs open packs with a homogeneous rest type", function()
        local p = packs.pack({ ty.atom("number") }, ty.atom("string"))
        T.eq(packs.fixed_arity(p), 1)
        T.eq(packs.is_open(p), true)
        T.eq(packs.tostring(p), "(number, ...string)")
    end)

    T.it("rejects sparse packs instead of allowing ipairs truncation", function()
        local ok, err = pcall(function()
            packs.pack({ [1] = ty.atom("number"), [3] = ty.atom("string") })
        end)
        T.eq(ok, false)
        T.ok(tostring(err):find("dense", 1, true) ~= nil, "dense-pack error")
    end)

    T.it("rejects non-type items and rest", function()
        local ok, err = pcall(function()
            packs.pack({ "number" })
        end)
        T.eq(ok, false)
        T.ok(tostring(err):find("not a type", 1, true) ~= nil, "item type error")

        ok, err = pcall(function()
            packs.pack({}, "string")
        end)
        T.eq(ok, false)
        T.ok(tostring(err):find("rest", 1, true) ~= nil, "rest type error")
    end)

    T.it("distinguishes fixed arity and rest in structural keys", function()
        local one = packs.pack({ ty.atom("number") })
        local two = packs.pack({ ty.atom("number"), ty.atom("string") })
        local open = packs.pack({ ty.atom("number") }, ty.atom("string"))

        T.ok(not packs.equal(one, two), "fixed arity differs")
        T.ok(not packs.equal(one, open), "rest differs")
    end)

    T.it("makes arrow keys depend on parameter and return packs", function()
        local number_to_string = ty.arrow(
            packs.pack({ ty.atom("number") }),
            packs.pack({ ty.atom("string") })
        )
        local string_to_number = ty.arrow(
            packs.pack({ ty.atom("string") }),
            packs.pack({ ty.atom("number") })
        )

        T.ok(not ty.equal(number_to_string, string_to_number), "distinct arrows are not equal")
    end)
end)
