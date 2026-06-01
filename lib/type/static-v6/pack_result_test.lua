-- lib/type/static-v6/pack_result_test.lua
-- Whole-pack result alternatives for correlated multi-return sites.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")

local pack_result = require("lib.type.static-v6.pack_result")
local packs = require("lib.type.static-v6.packs")
local types = require("lib.type.static-v6.types")

T.describe("v6 pack results", function()
    T.it("preserves whole-pack alternatives before movement adjustment", function()
        local ok_pack = packs.pack({ types.literal("string", "ok"), types.atom("number") })
        local err_pack = packs.pack({ types.literal("string", "err"), types.atom("string") })
        local result = pack_result.union({ ok_pack, err_pack })

        T.eq(result.tag, "union")
        T.eq(#result.alternatives, 2)
        T.eq(pack_result.key(result):find("pack(", 1, true) ~= nil, true)
    end)

    T.it("widens slots only at explicit arity adjustment", function()
        local ok_pack = packs.pack({ types.literal("string", "ok"), types.atom("number") })
        local err_pack = packs.pack({ types.literal("string", "err"), types.atom("string") })
        local adjusted = pack_result.adjust_to_arity(pack_result.union({ ok_pack, err_pack }), 2)

        T.eq(adjusted[1].tag, "union")
        T.eq(adjusted[2].tag, "union")
        T.eq(adjusted[2].members[1].name, "number")
        T.eq(adjusted[2].members[2].name, "string")
    end)

    T.it("prepends scalar expression-list prefixes to each whole-pack alternative", function()
        local ok_pack = packs.pack({ types.literal("string", "ok"), types.atom("number") })
        local err_pack = packs.pack({ types.literal("string", "err"), types.atom("string") })
        local result = pack_result.prepend_items({ types.atom("boolean") }, pack_result.union({ ok_pack, err_pack }))

        T.eq(result.tag, "union")
        T.eq(#result.alternatives, 2)
        T.eq(result.alternatives[1].items[1].name, "boolean")
        T.eq(result.alternatives[2].items[1].name, "boolean")
        T.eq(result.alternatives[1].items[2].value, "ok")
        T.eq(result.alternatives[2].items[2].value, "err")
    end)
end)
