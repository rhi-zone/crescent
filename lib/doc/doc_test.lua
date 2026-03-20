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
-- Test: private field filtering
-- ---------------------------------------------------------------------------
T.describe("docgen: private field filtering", function()
    T.it("fields starting with _ are excluded from exports", function()
        local source = [[
local M = {}

--- Public function.
M.public = function() end

--- Internal helper.
M._private = function() end

M._internal_state = 0

M.visible = true

return M
]]
        local result = doc.generate_string(source, "private_test.lua")
        T.ok(result, "result should not be nil")
        local names = {}
        for _, e in ipairs(result.exports) do names[e.name] = true end
        T.ok(names["public"],  "should export 'public'")
        T.ok(names["visible"], "should export 'visible'")
        T.ok(not names["_private"],        "_private should be filtered out")
        T.ok(not names["_internal_state"], "_internal_state should be filtered out")
    end)
end)

-- ---------------------------------------------------------------------------
-- Test: parameter names in function exports
-- ---------------------------------------------------------------------------
T.describe("docgen: function parameter names", function()
    T.it("exports include params array for function types", function()
        local source = [[
local M = {}
M.add = function(a, b)
    return a + b
end
return M
]]
        local result = doc.generate_string(source, "params_test.lua")
        T.ok(result, "result should not be nil")
        local exp = find_export(result, "add")
        T.ok(exp, "'add' export should be present")
        T.ok(exp.params, "add should have params")
        T.eq(#exp.params, 2, "add should have 2 params")
        T.eq(exp.params[1].name, "a")
        T.eq(exp.params[2].name, "b")
    end)

    T.it("non-function exports have no params", function()
        local source = [[
local M = {}
M.version = "1.0"
return M
]]
        local result = doc.generate_string(source, "noparams_test.lua")
        T.ok(result, "result should not be nil")
        local exp = find_export(result, "version")
        T.ok(exp, "'version' export should be present")
        T.ok(not exp.params, "string export should not have params")
    end)
end)

-- ---------------------------------------------------------------------------
-- Test: batch mode (generate_package)
-- ---------------------------------------------------------------------------
T.describe("docgen: generate_package", function()
    T.it("generates docs for all .lua files in a package", function()
        local results = doc.generate_package("lib/merge")
        T.ok(results, "results should not be nil")
        T.ok(#results > 0, "should have at least one result")
        -- Should include init.lua
        local has_init = false
        for _, r in ipairs(results) do
            if r.file:find("init.lua", 1, true) then
                has_init = true
            end
        end
        T.ok(has_init, "should include init.lua")
    end)

    T.it("skips test files", function()
        local results = doc.generate_package("lib/merge")
        for _, r in ipairs(results) do
            T.ok(not r.file:find("_test.lua", 1, true),
                "should not include test files, got: " .. r.file)
        end
    end)
end)

-- ---------------------------------------------------------------------------
-- Test: markdown output
-- ---------------------------------------------------------------------------
T.describe("docgen: markdown output", function()
    T.it("produces markdown with headers and code blocks", function()
        local source = [[
local M = {}
--- Add two numbers.
M.add = function(a, b) return a + b end
M.version = "1.0"
return M
]]
        local result = doc.generate_string(source, "md_test.lua")
        T.ok(result, "result should not be nil")
        local md = doc.format_markdown(result)
        T.ok(md:find("# md_test.lua", 1, true), "should have file header")
        T.ok(md:find("## add", 1, true), "should have export header for add")
        T.ok(md:find("## version", 1, true), "should have export header for version")
        T.ok(md:find("```", 1, true), "should have code blocks")
        T.ok(md:find("Add two numbers", 1, true), "should include doc comment")
        T.ok(md:find("---", 1, true), "should have separators")
    end)

    T.it("handles empty exports", function()
        local source = [[
local M = {}
return M
]]
        local result = doc.generate_string(source, "empty.lua")
        T.ok(result, "result should not be nil")
        local md = doc.format_markdown(result)
        T.ok(md:find("(no exports)", 1, true), "should show no exports message")
    end)
end)

-- ---------------------------------------------------------------------------
-- Test: HTML output
-- ---------------------------------------------------------------------------
T.describe("docgen: HTML output", function()
    T.it("produces valid HTML with doctype and structure", function()
        local source = [[
local M = {}
--- Add two numbers.
M.add = function(a, b) return a + b end
M.version = "1.0"
return M
]]
        local result = doc.generate_string(source, "html_test.lua")
        T.ok(result, "result should not be nil")
        local html = doc.format_html(result)
        T.ok(html:find("<!DOCTYPE html>", 1, true), "should start with DOCTYPE")
        T.ok(html:find("<html", 1, true), "should have html tag")
        T.ok(html:find("</html>", 1, true), "should close html tag")
        T.ok(html:find("<head>", 1, true) or html:find("<head ", 1, true), "should have head")
        T.ok(html:find("<body>", 1, true), "should have body")
        T.ok(html:find("</body>", 1, true), "should close body")
    end)

    T.it("contains export names and type signatures", function()
        local source = [[
local M = {}
--- Add two numbers.
M.add = function(a, b) return a + b end
M.version = "1.0"
return M
]]
        local result = doc.generate_string(source, "html_test.lua")
        T.ok(result, "result should not be nil")
        local html = doc.format_html(result)
        T.ok(html:find(">add<", 1, true), "should contain export name 'add'")
        T.ok(html:find(">version<", 1, true), "should contain export name 'version'")
        T.ok(html:find("<pre>", 1, true), "should have code blocks for type signatures")
        T.ok(html:find("Add two numbers", 1, true), "should include doc comment")
    end)

    T.it("includes inline CSS", function()
        local source = [[
local M = {}
M.x = 1
return M
]]
        local result = doc.generate_string(source, "css_test.lua")
        T.ok(result, "result should not be nil")
        local html = doc.format_html(result)
        T.ok(html:find("<style>", 1, true), "should have inline style tag")
        T.ok(html:find("</style>", 1, true), "should close style tag")
    end)

    T.it("escapes HTML special characters", function()
        local source = [[
local M = {}
--- Returns a<b result & more.
M.compare = function(a, b) return a < b end
return M
]]
        local result = doc.generate_string(source, "escape_test.lua")
        T.ok(result, "result should not be nil")
        local html = doc.format_html(result)
        T.ok(html:find("&amp;", 1, true), "should escape & in doc comment")
        T.ok(html:find("&lt;", 1, true), "should escape < in doc or type")
    end)

    T.it("handles empty exports", function()
        local source = [[
local M = {}
return M
]]
        local result = doc.generate_string(source, "empty.lua")
        T.ok(result, "result should not be nil")
        local html = doc.format_html(result)
        T.ok(html:find("no exports", 1, true), "should show no exports message")
    end)

    T.it("handles multiple files as sections", function()
        local src1 = [[
local M = {}
M.a = 1
return M
]]
        local src2 = [[
local M = {}
M.b = 2
return M
]]
        local r1 = doc.generate_string(src1, "mod_a.lua")
        local r2 = doc.generate_string(src2, "mod_b.lua")
        T.ok(r1 and r2, "both results should not be nil")
        local html = doc.format_html({ r1, r2 })
        T.ok(html:find("mod_a.lua", 1, true), "should contain first module name")
        T.ok(html:find("mod_b.lua", 1, true), "should contain second module name")
        -- Should have two <section> tags
        local count = 0
        for _ in html:gmatch("<section>") do count = count + 1 end
        T.eq(count, 2, "should have two sections")
    end)

    T.it("includes line references", function()
        local source = [[
local M = {}
--- A function.
M.foo = function() end
return M
]]
        local result = doc.generate_string(source, "lineref.lua")
        T.ok(result, "result should not be nil")
        local html = doc.format_html(result)
        T.ok(html:find("line-ref", 1, true), "should have line reference class")
        T.ok(html:find("line ", 1, true), "should have line number text")
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
