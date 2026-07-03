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
    T.it("truthy drops nil and false, keeps everything else", function()
        T.eq(L.show(L.truthy(L.of({ "number", "nil" }))), "number", "number|nil truthy -> number")
        T.eq(L.show(L.truthy(L.single("table"))), "table", "table truthy -> table")
        T.eq(L.show(L.truthy(L.single("boolean"))), "true", "the literal split: only true survives")
        T.eq(L.show(L.truthy(L.single("true"))), "true", "true is truthy")
        T.eq(L.show(L.truthy(L.single("false"))), "never", "false is never truthy")
    end)

    T.it("falsy keeps only nil and false", function()
        T.eq(L.show(L.falsy(L.of({ "number", "nil" }))), "nil", "number|nil falsy -> nil")
        T.eq(L.show(L.falsy(L.single("table"))), "never", "a table is never falsy")
        T.eq(L.show(L.falsy(L.of({ "boolean", "string" }))), "false", "only the false literal is falsy")
        T.eq(L.show(L.falsy(L.single("true"))), "never", "true is never falsy")
    end)

    T.it("boolean IS the true/false pair (normalized construction, collapsed display)", function()
        local b = L.single("boolean")
        T.ok(L.lattice.equal(b, L.of({ "true", "false" })), "boolean = true | false")
        T.eq(L.show(b), "boolean", "the pair renders collapsed")
        T.eq(L.show(L.single("true")), "true", "a lone literal renders as itself")
        T.eq(L.leq(L.single("true"), b), true, "true ⊑ boolean")
        T.eq(L.leq(b, L.single("false")), false, "boolean ⊄ false")
        T.eq(L.excess(b, L.single("number")), "boolean", "excess collapses the pair too")
        T.eq(L.show(L.tag_keep(L.single("unknown"), "boolean")), "boolean",
            "type(x)=='boolean' keeps the whole pair from unknown")
        T.eq(L.show(L.tag_drop(L.of({ "true", "nil" }), "boolean")), "nil",
            "dropping the boolean tag removes both literals")
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

    T.it("boolean literals WIDEN at mutable-ref creation (the flag idiom)", function()
        local r = L.record_of({ enabled = L.single("false") })
        T.eq(L.show(r), "{ enabled: boolean }", "the ref holds the base pair, not the literal")
        local w = L.field_write_bound(r, "enabled")
        T.ok(w ~= nil and L.leq(L.single("true"), w) == true,
            "t.enabled = true is admitted (no false-positive machine)")
        local ext = L.set_field(L.record_of({}), "neon", L.single("true"))
        local wb = L.field_write_bound(ext, "neon")
        T.ok(wb ~= nil and L.leq(L.single("false"), wb) == true,
            "a new field written `true` still accepts false later")
        -- flow values keep literal precision; only fresh refs widen.
        T.eq(L.show(L.single("false")), "false", "non-ref positions stay literal")
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

T.describe("v9 lattice — function types (contravariant params, covariant results)", function()
    local mkfn_seq = 0
    --: (pins: { [integer]: unknown }, results: { [integer]: unknown }) -> unknown
    local function mkfn(pins, results)
        local params = {} --: { [integer]: { cell: string, pin: unknown } }
        for i = 1, #pins do
            mkfn_seq = mkfn_seq + 1
            params[i] = { cell = "p#" .. tostring(mkfn_seq), pin = pins[i] }
        end
        return L.fn_val(params, results, false, nil, false)
    end

    T.it("renders and joins with itself", function()
        local f = mkfn({ L.single("number") }, { L.single("string") })
        T.eq(L.show(f), "(number) -> string", "arrow rendering")
        T.ok(L.lattice.equal(L.lattice.join(f, f), f), "join idempotent on the same fn")
    end)

    T.it("join of the SAME function joins results pointwise (covariant)", function()
        local params = { { cell = "p1", pin = nil } } --: { [integer]: { cell: string, pin: nil } }
        local f1 = L.fn_val(params, { L.single("number") }, false, nil, false)
        local f2 = L.fn_val(params, { L.single("string") }, false, nil, false)
        local j = L.lattice.join(f1, f2)
        T.eq(L.show(j), "(?) -> number | string", "results union up")
    end)

    T.it("join of DIFFERENT functions collapses to the function top", function()
        local f = mkfn({ L.single("number") }, { L.single("string") })
        local g = mkfn({ L.single("string") }, { L.single("string") })
        local j = L.lattice.join(f, g)
        T.eq(L.show(j), "function", "cond and f or g : some function, unchecked")
        T.eq(L.leq(f, j), true, "each arrow ⊑ the function top")
    end)

    T.it("leq: results are COVARIANT", function()
        local narrow = mkfn({}, { L.single("number") })
        local wide = mkfn({}, { L.of({ "number", "string" }) })
        T.eq(L.leq(narrow, wide), true, "() -> number ⊑ () -> number|string")
        T.eq(L.leq(wide, narrow), false, "and NOT the reverse")
    end)

    T.it("leq: params are CONTRAVARIANT (the soundness direction)", function()
        local takes_num = mkfn({ L.single("number") }, { L.single("nil") })
        local takes_numstr = mkfn({ L.of({ "number", "string" }) }, { L.single("nil") })
        T.eq(L.leq(takes_numstr, takes_num), true,
            "(number|string) -> nil ⊑ (number) -> nil : accepts MORE, usable where less is passed")
        T.eq(L.leq(takes_num, takes_numstr), false,
            "(number) -> nil ⊄ (number|string) -> nil : would receive strings it cannot take")
    end)

    T.it("leq: arity extension per Lua call semantics", function()
        local one_res = mkfn({}, { L.single("number") })
        local two_res = mkfn({}, { L.single("number"), L.of({ "nil", "string" }) })
        -- a function returning fewer results pads with nil at the caller.
        T.eq(L.leq(one_res, two_res), true, "missing result position reads as nil ⊑ nil|string")
        local two_strict = mkfn({}, { L.single("number"), L.single("string") })
        T.eq(L.leq(one_res, two_strict), false, "nil pad ⊄ string")
        -- a function with MORE pinned params than the expectation passes
        -- receives nil at the extra position.
        local needs_two = mkfn({ L.single("number"), L.of({ "number", "nil" }) }, {})
        local wants_one = mkfn({ L.single("number") }, {})
        T.eq(L.leq(needs_two, wants_one), true, "extra param admits nil -> ok")
        local needs_two_strict = mkfn({ L.single("number"), L.single("number") }, {})
        T.eq(L.leq(needs_two_strict, wants_one), false, "extra param demands number, gets nil")
    end)

    T.it("truthy keeps functions; falsy drops them", function()
        local f = mkfn({}, {})
        local opt = L.lattice.join(f, L.single("nil"))
        T.eq(L.show(L.truthy(opt)), "() -> ()", "functions are truthy")
        T.eq(L.show(L.falsy(opt)), "nil", "and never falsy")
    end)

    T.it("clip bounds depth with an UPPER approximation", function()
        local inner = mkfn({}, { L.single("number") })
        local outer = mkfn({}, { inner })
        local clipped = L.clip(outer, 1)
        T.eq(L.show(clipped), "() -> unknown", "structure below the cut becomes unknown")
        T.eq(L.leq(outer, clipped), true, "clip(v) ⊒ v (monotone proposals survive)")
        T.ok(L.lattice.equal(L.clip(L.single("number"), 0), L.single("number")),
            "atoms are never clipped")
    end)

    T.it("excess flags an arrow outside a non-function bound", function()
        local f = mkfn({}, {})
        T.eq(L.excess(f, L.single("number")), "() -> ()", "arrow reported")
        T.eq(L.excess(f, L.single("function")), nil, "admitted by the function atom")
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

T.describe("v9 lattice — index signatures (the idx component)", function()
    --: (Val) -> Field
    local function ref(v) return { r = v, w = v } end

    --: () -> Val
    local function str_num_map()
        return L.record_rw({}, L.idx_of(ref(L.single("number")), nil))
    end

    T.it("record_of with an element type is an index-bounded array", function()
        local arr = L.record_of({}, L.single("string"))
        T.eq(L.show(arr), "{ [number]: string }", "the array constructor's shape")
        T.eq(L.has_index(arr), true, "index-bounded")
        T.eq(L.has_str_index(arr), false, "string keys claimed absent (never part)")
    end)

    T.it("project_index is T | nil, joins named fields for string keys", function()
        local m = L.record_rw({ n = ref(L.single("string")) },
            L.idx_of(ref(L.single("number")), nil))
        local v = L.project_index(m, L.single("string"))
        T.eq(L.show(v), "nil | number | string", "part + named field + nil")
        local u = L.project_index(m, L.single("unknown"))
        T.eq(L.show(u), "unknown", "an unknown key projects the top (monotone)")
        local plain = L.record_of({}, nil)
        T.eq(L.show(L.project_index(plain, L.single("string"))), "unknown",
            "a plain open record's dynamic keys are untracked")
    end)

    T.it("join keeps idx only when BOTH sides are bounded; dropped fields FOLD", function()
        local a = L.record_rw({ x = ref(L.single("number")) },
            L.idx_of(ref(L.single("number")), nil))
        local b = str_num_map()
        local j = L.lattice.join(a, b)
        T.ok(L.as_val(j), "joined")
        if L.as_val(j) then
            T.eq(L.has_index(j), true, "both bounded -> still bounded")
            local read = L.project_index(j, L.single("string"))
            T.eq(L.show(read), "nil | number", "x's number FOLDED into the str part (sound reads)")
        end
        local plain = L.record_of({}, nil)
        local j2 = L.lattice.join(a, plain)
        T.ok(L.as_val(j2), "joined")
        if L.as_val(j2) then
            T.eq(L.has_index(j2), false, "an unbounded side unbounds the join")
        end
    end)

    T.it("leq: a plain open record does NOT flow into an index-signature type", function()
        local plain = L.record_of({ x = L.single("number") }, nil)
        T.eq(L.leq(plain, str_num_map()), false,
            "its unnamed keys are unbounded — the sound rejection")
        T.eq(L.leq_init(plain, str_num_map()), true,
            "a FRESH constructor does (init re-types; fields fit the part)")
        local bad = L.record_of({ x = L.single("string") }, nil)
        T.eq(L.leq_init(bad, str_num_map()), false,
            "width-into-index still checks the fields against T")
    end)

    T.it("leq between bounded records: r covariant, w contravariant per part", function()
        local narrow = str_num_map()
        local wide = L.record_rw({}, L.idx_of(ref(L.of({ "number", "string" })), nil))
        T.eq(L.leq(narrow, wide), false, "w-contravariance rejects (writes through wide)")
        local ro_wide = L.record_rw({}, L.idx_of({ r = L.of({ "number", "string" }), w = L.of({}) }, nil))
        T.eq(L.leq(narrow, ro_wide), true, "a read-only wide view admits the narrow map")
    end)

    T.it("iteration projections: elem nil-drops, values joins all, keys | nil", function()
        local arr = L.record_rw({},
            L.idx_of(nil, ref(L.of({ "number", "nil" }))))
        T.eq(L.show(L.elem_iter(arr)), "number",
            "$Elem drops nil — ipairs stops at the first nil (Lua semantics)")
        local m = L.record_rw({ n = ref(L.single("string")) },
            L.idx_of(ref(L.single("number")), ref(L.single("table"))))
        T.eq(L.show(L.values_iter(m)), "number | string | table", "$Values joins fields + both parts")
        T.eq(L.show(L.keys_iter(m)), "nil | number | string", "$Keys includes the end-marker nil")
        T.eq(L.show(L.values_iter(L.record_of({}, nil))), "unknown",
            "a plain open record's values are unbounded")
    end)

    T.it("set_index grows never/missing parts; existing parts are invariant refs", function()
        local plain = L.record_of({}, nil)
        local grown = L.set_index(plain, L.single("number"), L.single("string"))
        T.ok(L.as_val(grown), "grew")
        if L.as_val(grown) then
            T.eq(L.show(grown), "{ [number]: string }", "the num part grew from the write")
            local wb = L.index_write_bound(grown, "num")
            T.ok(wb ~= nil and L.show(wb) == "string", "and its w bound is the written ref")
        end
        local m = str_num_map()
        local after = L.set_index(m, L.single("string"), L.single("table"))
        T.ok(L.as_val(after), "wrote")
        if L.as_val(after) then
            local wb = L.index_write_bound(after, "str")
            T.ok(wb ~= nil and L.show(wb) == "number",
                "an existing part never widens from a write (checked post-solve instead)")
        end
    end)

    T.it("key_kinds classifies the discipline boundary", function()
        local kk = L.key_kinds(L.of({ "string", "number" }))
        T.eq(kk.str and kk.num, true, "both kinds")
        T.eq(kk.other, false, "in-discipline")
        T.eq(L.key_kinds(L.single("true")).other, true, "boolean keys are outside")
        T.eq(L.key_kinds(L.single("unknown")).unknown, true, "unknown keys must narrow")
    end)
end)
