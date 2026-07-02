-- lib/type/v9/frontend/frontend_test.lua
-- The frontend seam: real Lua source -> plain-table AST with line/col; syntax
-- errors as data; the node-kind roster is total (all 30 kinds named).

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local frontend = require("lib.type.v9.frontend")
local defs = require("lib.type.static.defs")

T.describe("v9 frontend — parse seam", function()
    T.it("parses real Lua to a chunk with line/col on nodes", function()
        local ast, err = frontend.parse("local x = 1\nlocal y = x + 2\n", "t.lua")
        T.ok(ast ~= nil, "parse succeeded: " .. (err or ""))
        if ast ~= nil then
            T.eq(ast.tag, defs.NODE_CHUNK, "root is a chunk")
            local body = ast.body
            if frontend.is_list(body) then
                T.eq(#body, 2, "two statements")
                T.eq(body[1].tag, defs.NODE_LOCAL_STMT, "first is a local")
                T.eq(body[1].line, 1, "first stmt line")
                T.eq(body[2].line, 2, "second stmt line")
                T.ok(body[2].col >= 1, "col present")
            else
                T.ok(false, "chunk body is a list")
            end
        end
    end)

    T.it("returns syntax errors as data with position, never throws", function()
        local ast, err = frontend.parse("local = = nonsense((", "bad.lua")
        T.eq(ast, nil, "no ast on syntax error")
        T.ok(err ~= nil and err:find("bad.lua", 1, true) ~= nil, "errmsg carries the filename: " .. tostring(err))
    end)

    T.it("names all 30 node kinds (the totality roster)", function()
        local count = 0
        for tag = 0, frontend.NODE_KIND_COUNT - 1 do
            T.ok(frontend.NODE_NAME[tag] ~= nil, "kind " .. tag .. " is named")
            count = count + 1
        end
        T.eq(count, 30, "roster covers exactly 30 kinds")
        T.eq(frontend.node_name(defs.NODE_WHILE_STMT), "while-stmt", "kebab bucket name")
    end)
end)
