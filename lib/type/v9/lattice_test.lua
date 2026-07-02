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

T.describe("v9 lattice — structural open records", function()
    T.it("constructs and projects fields", function()
        local r = L.record_of({ x = L.single("number"), y = L.single("string") })
        T.eq(L.show(r), "{ x: number, y: string }", "renders sorted fields")
        T.eq(L.show(L.project(r, "x")), "number", "project x")
        T.eq(L.show(L.project(r, "y")), "string", "project y")
        T.eq(L.show(L.project(r, "z")), "unknown", "absent field on an OPEN record projects to unknown")
    end)

    T.it("join is pointwise on COMMON fields (width at merges)", function()
        local a = L.record_of({ x = L.single("number"), y = L.single("string") })
        local b = L.record_of({ x = L.single("string") })
        local j = L.lattice.join(a, b)
        T.eq(L.show(j), "{ x: number | string }", "x joins; y (not common) drops")
    end)

    T.it("join with non-record atoms keeps the record (optional-table idiom)", function()
        local r = L.record_of({ x = L.single("number") })
        local j = L.lattice.join(L.single("nil"), r)
        T.eq(L.show(j), "nil | { x: number }", "nil | record stays precise")
        T.eq(L.show(L.truthy(j)), "{ x: number }", "truthy drops nil, keeps the record")
        T.eq(L.show(L.falsy(j)), "nil", "falsy drops the record (tables are never falsy)")
    end)

    T.it("the `table` top absorbs the record component", function()
        local r = L.record_of({ x = L.single("number") })
        local j = L.lattice.join(L.single("table"), r)
        T.eq(L.show(j), "table", "record ⊑ table-top; join collapses")
        T.eq(L.show(L.project(j, "x")), "unknown", "fields unknown through the top")
    end)

    T.it("unknown absorbs records too", function()
        local r = L.record_of({ x = L.single("number") })
        T.eq(L.show(L.lattice.join(L.single("unknown"), r)), "unknown", "top is top")
    end)

    T.it("leq: width subtyping accepts records with MORE fields", function()
        local wide = L.record_of({ x = L.single("number"), y = L.single("string") })
        local narrow = L.record_of({ x = L.single("number") })
        T.eq(L.leq(wide, narrow), true, "{x,y} ⊑ {x}")
        T.eq(L.leq(narrow, wide), false, "{x} ⊄ {x,y} (missing field)")
        T.eq(L.leq(wide, L.single("table")), true, "record ⊑ table-top")
        T.eq(L.leq(L.single("table"), narrow), false, "table-top ⊄ record")
    end)

    T.it("leq: field types are INVARIANT (r covariant AND w contravariant)", function()
        local num = L.record_of({ x = L.single("number") })
        local numstr = L.record_of({ x = L.of({ "number", "string" }) })
        -- r-part alone would accept num ⊑ numstr; the w-part rejects it:
        -- a {x: number|string} view would admit writing "s" into a number ref.
        T.eq(L.leq(num, numstr), false, "covariant-field flow is rejected (mutable refs)")
        T.eq(L.leq(numstr, num), false, "and the reverse too")
        T.eq(L.leq(num, num), true, "equal fields flow")
    end)

    T.it("join meets the write bounds: writes through a merged view need both", function()
        local a = L.record_of({ x = L.single("number") })
        local b = L.record_of({ x = L.single("string") })
        local j = L.lattice.join(a, b)
        local w = L.field_write_bound(j, "x")
        T.ok(w ~= nil, "common field keeps a write bound")
        if w ~= nil then
            T.eq(L.show(w), "never", "w = meet(number, string) = never: no write is safe for both")
            T.eq(L.leq(L.single("number"), w), false, "even a number write is rejected through the merge")
        end
        T.eq(L.show(L.project(j, "x")), "number | string", "reads stay covariant (union)")
    end)

    T.it("set_field: existing fields are invariant refs; new fields extend", function()
        local r = L.record_of({ x = L.single("number") })
        local after = L.set_field(r, "x", L.single("string"))
        T.eq(L.show(after), "{ x: number }", "existing field type NEVER relaxed by a write")
        local ext = L.set_field(r, "y", L.single("string"))
        T.eq(L.show(ext), "{ x: number, y: string }", "new field extends the open record")
        local wb = L.field_write_bound(ext, "y")
        T.ok(wb ~= nil and L.show(wb) == "string", "new field's write bound = its first written type")
    end)

    T.it("string-only detection (the s:sub(...) stdlib boundary)", function()
        T.eq(L.is_string_only(L.single("string")), true, "string alone")
        T.eq(L.is_string_only(L.of({ "string", "nil" })), false, "string|nil is not string-only")
        T.eq(L.is_string_only(L.record_of({})), false, "records are not strings")
    end)

    T.it("excess admits records under a `table` bound (# operand etc.)", function()
        local r = L.record_of({ x = L.single("number") })
        T.eq(L.excess(r, L.of({ "string", "table" })), nil, "record ⊑ table for atom bounds")
        T.eq(L.excess(r, L.single("number")), "{ x: number }", "and is reported otherwise")
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
