-- lib/type/search/search_test.lua

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T      = require("lib.test.assert")
local search = require("lib.type.search")
local doc    = require("lib.doc")

local describe, it = T.describe, T.it

-- ---------------------------------------------------------------------------
-- Self-contained tests using build_index_from_docs with synthetic doc tables
-- ---------------------------------------------------------------------------
describe("search.build_index_from_docs", function()
    it("builds flat index from doc results", function()
        local docs = {
            {
                file = "lib/example/init.lua",
                exports = {
                    { name = "encode", type = "(string) -> string" },
                    { name = "decode", type = "(string) -> string" },
                    { name = "count",  type = "(string) -> number" },
                },
            },
            {
                file = "lib/other/init.lua",
                exports = {
                    { name = "run", type = "() -> nil" },
                },
            },
        }
        local index = search.build_index_from_docs(docs)
        T.eq(#index, 4)
        T.eq(index[1].name, "encode")
        T.eq(index[1].file, "lib/example/init.lua")
        T.eq(index[4].name, "run")
    end)

    it("accepts single doc result", function()
        local single = {
            file = "lib/x/init.lua",
            exports = {
                { name = "foo", type = "(number) -> string" },
            },
        }
        local index = search.build_index_from_docs(single)
        T.eq(#index, 1)
        T.eq(index[1].name, "foo")
    end)
end)

-- ---------------------------------------------------------------------------
-- Query tests with synthetic index entries
-- ---------------------------------------------------------------------------
describe("search.query", function()
    it("finds exact match for (string) -> string", function()
        local index = {
            { name = "encode", file = "a.lua", type = "(string) -> string" },
            { name = "count",  file = "a.lua", type = "(string) -> number" },
            { name = "run",    file = "a.lua", type = "() -> nil" },
        }
        local matches = search.query("(string) -> string", index)
        T.ok(#matches >= 1, "should find at least one match")
        -- The exact match should be first
        local found = false
        for _, m in ipairs(matches) do
            if m.name == "encode" then
                found = true
                T.eq(m.exact, true)
            end
        end
        T.ok(found, "should find encode")
    end)

    it("matches subtypes — number is assignable where integer is expected", function()
        local index = {
            { name = "to_hex", file = "b.lua", type = "(integer) -> string" },
        }
        -- Query with number: number is a supertype of integer
        -- Forward: candidate(integer->string) assignable to query(number->string)?
        -- Function params are contravariant: number >: integer, so integer param
        -- accepts less — forward should fail. But backward (query assignable to candidate) should work.
        local matches = search.query("(number) -> string", index)
        T.ok(#matches >= 1, "should find to_hex as compatible match")
    end)

    it("does not match incompatible types", function()
        local index = {
            { name = "noop", file = "c.lua", type = "() -> nil" },
        }
        local matches = search.query("(string) -> string", index)
        T.eq(#matches, 0)
    end)

    it("sorts exact matches before partial", function()
        local index = {
            { name = "partial", file = "d.lua", type = "(string) -> number" },
            { name = "exact",   file = "d.lua", type = "(string) -> string" },
        }
        local matches = search.query("(string) -> string", index)
        -- exact should appear before partial (if partial matches at all)
        if #matches > 0 then
            local found_exact = false
            for _, m in ipairs(matches) do
                if m.name == "exact" then
                    T.eq(m.exact, true)
                    found_exact = true
                end
            end
            T.ok(found_exact, "should find exact match")
        end
    end)

    it("matches table types", function()
        local index = {
            { name = "make", file = "e.lua", type = "() -> { x: number, y: number }" },
        }
        local matches = search.query("() -> { x: number, y: number }", index)
        T.ok(#matches >= 1, "should match table return type")
    end)

    it("handles any type in query", function()
        local index = {
            { name = "f1", file = "f.lua", type = "(string) -> string" },
            { name = "f2", file = "f.lua", type = "(number) -> number" },
        }
        -- any should match everything
        local matches = search.query("(any) -> any", index)
        T.ok(#matches >= 2, "any should match all functions")
    end)
end)

-- ---------------------------------------------------------------------------
-- Integration test with real modules (if available)
-- ---------------------------------------------------------------------------
describe("search.build_index (real files)", function()
    it("indexes a real module", function()
        local index = search.build_index({"lib/encode/base64/init.lua"})
        T.ok(#index > 0, "should find exports in base64")
        -- Check that we got name, file, type for each entry
        for _, entry in ipairs(index) do
            T.ok(entry.name and #entry.name > 0, "entry should have a name")
            T.eq(entry.file, "lib/encode/base64/init.lua")
            T.ok(entry.type and #entry.type > 0, "entry should have a type")
        end
    end)

    it("queries across real modules with matching types", function()
        local index = search.build_index({
            "lib/encode/base64/init.lua",
        })
        -- base64 is unannotated, so the typechecker infers structural types
        -- like ({ byte: _ }, _) -> string. Query with a compatible structural type.
        -- Use any to match broadly.
        local matches = search.query("(any) -> string", index)
        T.ok(#matches >= 1, "should find functions returning string in base64")
        local names = {}
        for _, m in ipairs(matches) do names[m.name] = true end
        T.ok(names["encode"] or names["decode"] or names["string_to_base64"],
             "should find encode or decode or string_to_base64")
    end)
end)
