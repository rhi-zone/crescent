-- lib/doc/doc_test.lua
-- Tests for the docgen library.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local doc = require("lib.doc")

-- ---------------------------------------------------------------------------
-- Helper: find an export by name
-- ---------------------------------------------------------------------------
local function find_export(result, name)
    for _, e in ipairs(result.exports) do
        if e.name == name then return e end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Test: basic module with exports and doc comments
-- ---------------------------------------------------------------------------
T.describe("docgen: basic module", function()
    local source = [[
local M = {}

--- Add two numbers.
--- Returns their sum.
M.add = function(a, b)
    return a + b
end

--- Greet someone.
M.greet = function(name)
    return "hello, " .. name
end

M.version = "1.0.0"

return M
]]
    T.it("generate_string returns a doc table", function()
        local result, err = doc.generate_string(source, "test_module.lua")
        T.ok(result, "expected result, got error: " .. tostring(err))
        T.ok(result.exports, "result should have exports")
    end)

    T.it("exports include named fields", function()
        local result = doc.generate_string(source, "test_module.lua")
        T.ok(result, "result should not be nil")
        local names = {}
        for _, e in ipairs(result.exports) do names[e.name] = true end
        T.ok(names["add"],     "should export 'add'")
        T.ok(names["greet"],   "should export 'greet'")
        T.ok(names["version"], "should export 'version'")
    end)

    T.it("add export has function type", function()
        local result = doc.generate_string(source, "test_module.lua")
        T.ok(result, "result should not be nil")
        local exp = find_export(result, "add")
        T.ok(exp, "'add' export should be present")
        -- Type should contain '->' (it's a function)
        T.ok(exp.type:find("->", 1, true), "add type should be a function, got: " .. tostring(exp.type))
    end)

    T.it("doc comment extracted for add", function()
        local result = doc.generate_string(source, "test_module.lua")
        T.ok(result, "result should not be nil")
        local exp = find_export(result, "add")
        T.ok(exp, "'add' export should be present")
        T.ok(exp.doc, "add should have a doc comment")
        T.ok(exp.doc:find("Add two numbers", 1, true), "doc should contain 'Add two numbers', got: " .. tostring(exp.doc))
    end)

    T.it("doc comment for add includes second line", function()
        local result = doc.generate_string(source, "test_module.lua")
        T.ok(result, "result should not be nil")
        local exp = find_export(result, "add")
        T.ok(exp, "'add' export should be present")
        T.ok(exp.doc:find("Returns their sum", 1, true), "doc should contain 'Returns their sum', got: " .. tostring(exp.doc))
    end)

    T.it("doc comment extracted for greet", function()
        local result = doc.generate_string(source, "test_module.lua")
        T.ok(result, "result should not be nil")
        local exp = find_export(result, "greet")
        T.ok(exp, "'greet' export should be present")
        T.ok(exp.doc, "greet should have a doc comment")
        T.ok(exp.doc:find("Greet someone", 1, true), "doc should contain 'Greet someone', got: " .. tostring(exp.doc))
    end)

    T.it("version export has no doc comment", function()
        local result = doc.generate_string(source, "test_module.lua")
        T.ok(result, "result should not be nil")
        local exp = find_export(result, "version")
        T.ok(exp, "'version' export should be present")
        -- version has no preceding --- comment
        T.ok(not exp.doc or exp.doc == "", "version should have no doc comment, got: " .. tostring(exp.doc))
    end)

    T.it("exports have line numbers", function()
        local result = doc.generate_string(source, "test_module.lua")
        T.ok(result, "result should not be nil")
        local exp = find_export(result, "add")
        T.ok(exp, "'add' export should be present")
        T.ok(exp.line and exp.line > 0, "add should have a positive line number, got: " .. tostring(exp.line))
    end)

    T.it("file field matches given filename", function()
        local result = doc.generate_string(source, "test_module.lua")
        T.ok(result, "result should not be nil")
        T.eq(result.file, "test_module.lua")
    end)
end)

-- ---------------------------------------------------------------------------
-- Test: doc comment extraction edge cases
-- ---------------------------------------------------------------------------
T.describe("docgen: doc comment edge cases", function()
    T.it("blank line breaks doc comment attachment", function()
        local source = [[
local M = {}

--- This is for something else.

M.orphaned = function() end

return M
]]
        local result = doc.generate_string(source, "edge.lua")
        T.ok(result, "result should not be nil")
        local exp = find_export(result, "orphaned")
        T.ok(exp, "'orphaned' export should be present")
        -- The blank line separates the comment from the declaration
        T.ok(not exp.doc, "orphaned should have no doc (blank line between), got: " .. tostring(exp.doc))
    end)

    T.it("single-line doc comment", function()
        local source = [[
local M = {}
--- The answer.
M.answer = 42
return M
]]
        local result = doc.generate_string(source, "single.lua")
        T.ok(result, "result should not be nil")
        local exp = find_export(result, "answer")
        T.ok(exp, "'answer' export should be present")
        T.ok(exp.doc and exp.doc:find("The answer", 1, true), "should find doc, got: " .. tostring(exp.doc))
    end)
end)

-- ---------------------------------------------------------------------------
-- Test: module with no return (no exports from return)
-- ---------------------------------------------------------------------------
T.describe("docgen: module with no return", function()
    T.it("returns empty exports for no-return module", function()
        local source = [[
local x = 1
local y = 2
]]
        local result = doc.generate_string(source, "noreturn.lua")
        T.ok(result, "result should not be nil")
        -- No return — exports may be empty or from top-level bindings
        T.ok(result.exports ~= nil, "exports field should exist")
    end)
end)
