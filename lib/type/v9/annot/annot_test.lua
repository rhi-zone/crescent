-- lib/type/v9/annot/annot_test.lua
-- The annotation grammar seam: what v0 PARSES (atoms, unions, records,
-- functions, aliases) vs what it routes to NAMED buckets (generics,
-- intrinsics, index signatures, intersections, ...). Honesty is the
-- contract: nothing silently guessed, every unsupported feature named.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local annot = require("lib.type.v9.annot")

--: (string) -> (string | nil, string | nil)
local function no_alias(name) return nil, nil end

--: (x: unknown) -> x is { k: string, ... }
local function is_at(x) return type(x) == "table" end

-- narrow a node's child list for assertions (At children are open).
--: (x: unknown) -> x is { [integer]: { [string]: unknown } }
local function is_items(x) return type(x) == "table" end

--: (at: unknown, field: string) -> integer
local function count_of(at, field)
    if not is_at(at) then return -1 end
    local items = at[field]
    if not is_items(items) then return -1 end
    return #items
end

--: (content: string) -> (unknown, { [integer]: string })
local function parse(content)
    local at, buckets = annot.parse(content, no_alias)
    return at, buckets
end

--: ({ [integer]: string }, string) -> boolean
local function has_bucket(buckets, name)
    for i = 1, #buckets do
        if buckets[i] == name then return true end
    end
    return false
end

T.describe("v9 annot — the supported v0 grammar", function()
    T.it("atoms (integer maps to the number atom)", function()
        local cases = {
            { "nil", "nil" }, { "boolean", "boolean" }, { "number", "number" },
            { "integer", "number" }, { "string", "string" }, { "table", "table" },
            { "function", "function" },
        } --: { [integer]: { [integer]: string } }
        for i = 1, #cases do
            local src = cases[i][1]
            local want = cases[i][2]
            local at, buckets = parse(src)
            T.ok(is_at(at) and at.k == "atom" and at.name == want,
                src .. " -> atom " .. want)
            T.eq(#buckets, 0, src .. ": no buckets")
        end
    end)

    T.it("unknown / never are their own nodes", function()
        local u = parse("unknown")
        T.ok(is_at(u) and u.k == "unknown", "unknown")
        local n = parse("never")
        T.ok(is_at(n) and n.k == "never", "never")
    end)

    T.it("unions, incl. the T | nil idiom", function()
        local at, buckets = parse("string | nil")
        T.ok(is_at(at) and at.k == "union", "union node")
        T.eq(#buckets, 0, "clean")
        if is_at(at) then
            local parts = at.parts
            T.ok(is_items(parts) and #parts == 2, "two parts")
        end
    end)

    T.it("literal types UP-approximate to their base atom", function()
        local s = parse("\"heading\"")
        T.ok(is_at(s) and s.k == "atom" and s.name == "string", "string literal -> string")
        local u = parse("\"a\" | \"b\" | nil")
        T.ok(is_at(u) and u.k == "union", "literal unions parse")
        local n = parse("42")
        T.ok(is_at(n) and n.k == "atom" and n.name == "number", "42 -> number")
    end)

    T.it("records: fields, optional, readonly, the open marker", function()
        local at, buckets = parse("{ name: string, age?: integer, readonly id: number, ... }")
        T.eq(#buckets, 0, "all v0-expressible")
        T.ok(is_at(at) and at.k == "record", "record node")
        if is_at(at) and at.k == "record" then
            local fields = at.fields
            if is_items(fields) then
                T.eq(#fields, 3, "three fields (the open marker is a no-op)")
                T.eq(fields[2].optional, true, "age is optional")
                T.eq(fields[3].readonly, true, "id is readonly")
            else
                T.ok(false, "record has a field list")
            end
        end
    end)

    T.it("function types: params, named params, multi-return", function()
        local f1 = parse("(string, integer) -> boolean")
        T.ok(is_at(f1) and f1.k == "fn", "positional params")
        local f2 = parse("(name: string, age: integer) -> boolean")
        T.ok(is_at(f2) and f2.k == "fn" and count_of(f2, "params") == 2, "named params")
        local f3 = parse("() -> (string | nil, string | nil)")
        T.ok(is_at(f3) and f3.k == "fn" and count_of(f3, "results") == 2, "the (nil, errmsg) idiom")
        local f4 = parse("() -> nil")
        T.ok(is_at(f4) and f4.k == "fn" and count_of(f4, "results") == 1, "unit-ish")
    end)

    T.it("vararg rest params `...T`", function()
        local at = parse("(string, ...integer) -> nil")
        T.ok(is_at(at) and at.k == "fn", "fn")
        if is_at(at) and at.k == "fn" then
            T.eq(at.vararg, true, "vararg marked")
            T.ok(is_at(at.rest), "rest type captured")
        end
    end)

    T.it("a trailing `...` in a result tuple marks the arrow result-open", function()
        local at, buckets = parse("(f: function) -> (boolean, ...)")
        T.eq(#buckets, 0, "in-grammar, not a bucket")
        T.ok(is_at(at) and at.k == "fn", "fn")
        if is_at(at) and at.k == "fn" then
            T.eq(at.open, true, "result-open")
            T.eq(count_of(at, "results"), 1, "one fixed result")
        end
        local bare = parse("() -> (...)")
        T.ok(is_at(bare) and bare.k == "fn" and bare.open == true, "all-open results")
        local closed = parse("() -> (string, integer)")
        T.ok(is_at(closed) and closed.k == "fn" and closed.open ~= true, "no `...`, closed")
    end)

    T.it("`x is T` predicates read as boolean results (narrowing later, stated)", function()
        local at, buckets = parse("(x: unknown) -> x is string")
        T.ok(is_at(at) and at.k == "fn", "fn")
        T.eq(#buckets, 0, "predicates are readable, not bucketed")
        if is_at(at) and at.k == "fn" then
            local r1 = at.results[1]
            T.ok(is_at(r1) and r1.k == "atom" and r1.name == "boolean", "result is boolean")
        end
    end)

    T.it("higher-order and right-associative arrows", function()
        local at = parse("(cb: (number) -> nil) -> nil")
        T.ok(is_at(at) and at.k == "fn", "fn param inside fn")
        local bare = parse("string -> integer")
        T.ok(is_at(bare) and bare.k == "fn", "bare curried sugar")
    end)

    T.it("nested parens group", function()
        local at = parse("((string | nil))")
        T.ok(is_at(at) and at.k == "union", "parens are transparent")
    end)
end)

T.describe("v9 annot — named buckets (the honest boundary)", function()
    T.it("routes each non-v0 feature to its named bucket", function()
        local cases = {
            { "<T>(T) -> T", "generic" },
            { "Arr<string>", "generic" },
            { "$Require<T>", "intrinsic" },
            { "{ [string]: integer }", "index-signature" },
            { "string[]", "array" },
            { "A & B", "intersection" },
            { "~string", "complement" },
            { "typeof foo", "typeof" },
            { "any", "any" },
            { "cdata", "cdata" },
            { "SomeUnknownName", "unknown-name" },
            { "{ #__add: (unknown, unknown) -> unknown }", "meta-slot" },
            { "() -> ...(T)", "return-spread" },
        } --: { [integer]: { [integer]: string } }
        for i = 1, #cases do
            local src = cases[i][1]
            local want = cases[i][2]
            local at, buckets = parse(src)
            T.ok(has_bucket(buckets, want),
                src .. " -> bucket " .. want .. " (got: " .. table.concat(buckets, ",") .. ")")
            T.ok(at ~= nil, src .. " still yields a usable (approximate) node")
        end
    end)

    T.it("index signatures / arrays keep table-ness in the approximation", function()
        local at = parse("{ [integer]: string }")
        T.ok(is_at(at) and at.k == "opaque" and at.approx == "table", "approximates to the table atom")
    end)

    T.it("a bucketed SUBTREE does not poison the rest", function()
        local at, buckets = parse("{ ok: string, weird: $Magic<T> }")
        T.ok(is_at(at) and at.k == "record", "the record still parses")
        T.ok(has_bucket(buckets, "intrinsic"), "the intrinsic is named")
        T.eq(count_of(at, "fields"), 2, "both fields present; the weird one reads unknown")
    end)

    T.it("hard parse failures are (nil, buckets, errmsg) — data, never a throw", function()
        local at, _, err = annot.parse("} broken {", no_alias)
        T.eq(at, nil, "no node")
        T.ok(err ~= nil, "errmsg present: " .. tostring(err))
        local at2, _, err2 = annot.parse("", no_alias)
        T.eq(at2, nil, "empty annotation is not a type")
        T.ok(err2 ~= nil, "errmsg present")
    end)
end)

T.describe("v9 annot — aliases", function()
    --: (string) -> (string | nil, string | nil)
    local function resolver(name)
        if name == "Res" then return "{ status: number, body: string | nil }", nil end
        if name == "Loop" then return "Loop | nil", nil end
        if name == "Gen" then return nil, "generic" end
        return nil, nil
    end

    T.it("resolves through the injected cap", function()
        local at, buckets = annot.parse("Res | nil", resolver)
        T.ok(is_at(at) and at.k == "union", "alias body inlined into the union")
        T.eq(#buckets, 0, "clean")
    end)

    T.it("recursive aliases unroll once and cut to unknown at the knot (no hang, no bucket)", function()
        local at, buckets = annot.parse("Loop", resolver)
        T.ok(is_at(at) and at.k == "union", "the alias body IS read (one unroll)")
        T.eq(#buckets, 0,
            "a bounded-depth approximation, like clip — supported, not a boundary")
    end)

    T.it("names mapped to features bucket as that feature", function()
        local _, buckets = annot.parse("Gen", resolver)
        T.ok(has_bucket(buckets, "generic"), "a generic alias reference is the generic bucket")
    end)

    T.it("mutually-recursive alias GRAPHS expand memoized (linear, not path-exponential)", function()
        -- a dense mutual graph: naive path-wise unrolling is ~k^depth; the
        -- per-parse memo makes it one expansion per alias. 8 aliases, each
        -- referencing four neighbours (chains stay under the depth cap) —
        -- completes instantly or not at all.
        local n = 8
        --: (string) -> (string | nil, string | nil)
        local function graph(name)
            local i = tonumber(name:match("^G(%d+)$"))
            if i == nil then return nil, nil end
            local parts = {} --: { [integer]: string }
            for d = 1, 4 do
                parts[#parts + 1] = ("a%d: G%d"):format(d, (i + d) % n)
            end
            return "{ " .. table.concat(parts, ", ") .. " }", nil
        end
        local at, buckets = annot.parse("G0", graph)
        T.ok(is_at(at) and at.k == "record", "the graph root parses")
        T.eq(#buckets, 0, "within budget: no bucket")
    end)

    T.it("a path-explosive graph hits the honest alias-budget bucket, never a hang", function()
        -- every reference mints a FRESH name (memo never hits): the budget
        -- is the backstop.
        --: (string) -> (string | nil, string | nil)
        local function explosive(name)
            return "{ l: " .. name .. "l, r: " .. name .. "r }", nil
        end
        local at, buckets = annot.parse("X", explosive)
        T.ok(at ~= nil, "still yields a usable approximate node")
        T.ok(has_bucket(buckets, "alias-budget"), "the budget boundary is named")
    end)
end)

T.describe("v9 annot — `--::` declaration classification", function()
    T.it("aliases split into name + body", function()
        local kind, name, body = annot.classify_decl("Diag = { code: string }")
        T.eq(kind, "alias", "alias")
        T.eq(name, "Diag", "name")
        T.eq(body, "{ code: string }", "body")
    end)

    T.it("generic aliases are named as such", function()
        local kind, name = annot.classify_decl("Arr<T> = { [integer]: T }")
        T.eq(kind, "generic-alias", "generic alias")
        T.eq(name, "Arr", "name")
    end)

    T.it("`require` is the cross-module boundary; other forms are annotation-<kw>", function()
        local kind, feat = annot.classify_decl("require \"lib.foo\"")
        T.eq(kind, "feature", "feature")
        T.eq(feat, "cross-module", "cross-module")
        local _, f3 = annot.classify_decl("augment string { upper: () -> string }")
        T.eq(f3, "annotation-augment", "augment")
    end)

    T.it("`declare name = T` is a global declaration (name + body split)", function()
        local kind, name, body = annot.classify_decl("declare print = (string) -> nil")
        T.eq(kind, "declare", "declare kind")
        T.eq(name, "print", "name")
        T.eq(body, "(string) -> nil", "body")
        -- a malformed declare (no `= T` body) stays the named bucket.
        local k2, f2 = annot.classify_decl("declare print")
        T.eq(k2, "feature", "feature")
        T.eq(f2, "annotation-declare", "annotation-declare")
    end)

    T.it("garbage classifies as garbage", function()
        local kind = annot.classify_decl("!!! not a decl")
        T.eq(kind, "garbage", "named, not guessed")
    end)
end)
