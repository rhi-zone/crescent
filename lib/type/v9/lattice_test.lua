-- lib/type/v9/lattice_test.lua
-- The v0 type lattice: sound joins, unknown-as-absorbing-top, and the two
-- flow operations (truthy/falsy) that narrowing AND the and/or typing rules
-- derive from. Lattice laws are what make the engine's fixpoint sound.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local L = require("lib.type.v9.lattice")

T.describe("v9 lattice — joins", function()
    T.it("joins atom sets as unions", function()
        local j = L.lattice.join(L.single("number"), L.single("string"))
        T.eq(L.show(j), "number | string", "number ⊔ string")
        T.ok(L.lattice.equal(j, L.of({ "string", "number" })), "order-insensitive")
    end)

    T.it("unknown absorbs (a real top, not any)", function()
        local j = L.lattice.join(L.single("unknown"), L.single("number"))
        T.eq(L.show(j), "unknown", "unknown ⊔ number = unknown")
    end)

    T.it("bottom is the identity", function()
        local j = L.lattice.join(L.lattice.bottom(), L.single("table"))
        T.eq(L.show(j), "table", "⊥ ⊔ table = table")
        T.eq(L.show(L.lattice.bottom()), "never", "⊥ renders as never")
    end)

    T.it("join is idempotent and commutative (spot laws)", function()
        local a = L.of({ "number", "nil" })
        T.ok(L.lattice.equal(L.lattice.join(a, a), a), "idempotent")
        local b = L.of({ "string" })
        T.ok(L.lattice.equal(L.lattice.join(a, b), L.lattice.join(b, a)), "commutative")
    end)
end)

T.describe("v9 lattice — truthy/falsy (the narrowing + and/or substrate)", function()
    T.it("truthy drops nil, keeps everything else", function()
        T.eq(L.show(L.truthy(L.of({ "number", "nil" }))), "number", "number|nil truthy -> number")
        T.eq(L.show(L.truthy(L.single("table"))), "table", "table truthy -> table")
        T.eq(L.show(L.truthy(L.single("boolean"))), "boolean", "boolean stays (no literal split in v0)")
    end)

    T.it("falsy keeps only nil and boolean", function()
        T.eq(L.show(L.falsy(L.of({ "number", "nil" }))), "nil", "number|nil falsy -> nil")
        T.eq(L.show(L.falsy(L.single("table"))), "never", "a table is never falsy")
        T.eq(L.show(L.falsy(L.of({ "boolean", "string" }))), "boolean", "false lives in boolean")
    end)

    T.it("unknown stays unknown through both (must narrow explicitly)", function()
        T.eq(L.show(L.truthy(L.single("unknown"))), "unknown", "truthy(unknown)")
        T.eq(L.show(L.falsy(L.single("unknown"))), "unknown", "falsy(unknown)")
    end)

    T.it("both are monotone (spot check on a chain)", function()
        local small = L.single("nil")
        local big = L.of({ "nil", "number" })
        -- truthy(small) ⊆ truthy(big) and falsy(small) ⊆ falsy(big)
        T.eq(L.excess(L.truthy(small), L.truthy(big)), nil, "truthy monotone")
        T.eq(L.excess(L.falsy(small), L.falsy(big)), nil, "falsy monotone")
    end)
end)

T.describe("v9 lattice — obligation queries", function()
    T.it("excess reports atoms outside the allowed set", function()
        T.eq(L.excess(L.single("number"), L.single("number")), nil, "number ⊆ number")
        T.eq(L.excess(L.of({ "number", "string" }), L.single("number")), "string", "string sticks out")
        T.eq(L.excess(L.of({ "table", "nil" }), L.single("number")), "nil | table", "sorted list")
    end)

    T.it("is_unknown / is_bottom", function()
        T.eq(L.is_unknown(L.single("unknown")), true, "top detected")
        T.eq(L.is_unknown(L.single("number")), false, "number is not unknown")
        T.eq(L.is_bottom(L.lattice.bottom()), true, "bottom detected")
    end)
end)
