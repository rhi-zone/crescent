-- lib/mcp/mcp_test.lua
-- Tests for lib/mcp MCP server library.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T       = require("lib.test.assert")
local mcp     = require("lib.mcp")
local jsonrpc = require("lib.jsonrpc")
local json    = require("lib.format.json")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function make_test_server(opts)
    local msgs_in = {}
    local msgs_out = {}
    local transport = jsonrpc.table_transport(msgs_in, msgs_out)
    opts = opts or {}
    opts.transport = transport
    opts.name = opts.name or "test-server"
    opts.version = opts.version or "0.1.0"
    local server = mcp.server(opts)
    return server, msgs_in, msgs_out
end

local function push(msgs_in, obj)
    msgs_in[#msgs_in + 1] = json.encode(obj)
end

local function out(msgs_out, n)
    local raw = msgs_out[n]
    if not raw then return nil end
    return json.decode(raw)
end

-- ---------------------------------------------------------------------------
T.describe("initialize", function()
    T.it("returns protocolVersion, capabilities, and serverInfo", function()
        local server, msgs_in, msgs_out = make_test_server()
        push(msgs_in, { jsonrpc = "2.0", id = 1, method = "initialize", params = {} })
        server._dispatcher:step()
        local resp = out(msgs_out, 1)
        T.eq(resp.result.protocolVersion, "2025-11-25")
        T.eq(resp.result.serverInfo.name, "test-server")
        T.eq(resp.result.serverInfo.version, "0.1.0")
        T.ok(resp.result.capabilities.logging)
    end)

    T.it("capabilities reflect registrations — no tools means no tools key", function()
        local server, msgs_in, msgs_out = make_test_server()
        push(msgs_in, { jsonrpc = "2.0", id = 1, method = "initialize", params = {} })
        server._dispatcher:step()
        local resp = out(msgs_out, 1)
        T.eq(resp.result.capabilities.tools, nil)
        T.eq(resp.result.capabilities.resources, nil)
        T.eq(resp.result.capabilities.prompts, nil)
    end)

    T.it("capabilities include tools when tools are registered", function()
        local server, msgs_in, msgs_out = make_test_server()
        server:tool("dummy", {
            description = "dummy",
            input_schema = { type = "object" },
            handler = function() return {} end,
        })
        push(msgs_in, { jsonrpc = "2.0", id = 1, method = "initialize", params = {} })
        server._dispatcher:step()
        local resp = out(msgs_out, 1)
        T.ok(resp.result.capabilities.tools)
    end)
end)

-- ---------------------------------------------------------------------------
T.describe("ping", function()
    T.it("returns empty object", function()
        local server, msgs_in, msgs_out = make_test_server()
        push(msgs_in, { jsonrpc = "2.0", id = 1, method = "ping", params = {} })
        server._dispatcher:step()
        local resp = out(msgs_out, 1)
        T.ok(resp.result)
        T.eq(resp.error, nil)
    end)
end)

-- ---------------------------------------------------------------------------
T.describe("tools", function()
    T.it("lists registered tools", function()
        local server, msgs_in, msgs_out = make_test_server()
        server:tool("search", {
            description = "Search things",
            input_schema = { type = "object", properties = { query = { type = "string" } } },
            handler = function() return {} end,
        })
        push(msgs_in, { jsonrpc = "2.0", id = 1, method = "tools/list", params = {} })
        server._dispatcher:step()
        local resp = out(msgs_out, 1)
        T.eq(#resp.result.tools, 1)
        T.eq(resp.result.tools[1].name, "search")
        T.eq(resp.result.tools[1].description, "Search things")
        -- handler should not be in the response
        T.eq(resp.result.tools[1].handler, nil)
    end)

    T.it("calls a tool handler and returns result", function()
        local server, msgs_in, msgs_out = make_test_server()
        server:tool("echo", {
            description = "Echo input",
            input_schema = { type = "object" },
            handler = function(params)
                return { content = { { type = "text", text = params.message } } }
            end,
        })
        push(msgs_in, {
            jsonrpc = "2.0", id = 1, method = "tools/call",
            params = { name = "echo", arguments = { message = "hello" } },
        })
        server._dispatcher:step()
        local resp = out(msgs_out, 1)
        T.eq(resp.result.content[1].text, "hello")
    end)

    T.it("returns error for unknown tool", function()
        local server, msgs_in, msgs_out = make_test_server()
        push(msgs_in, {
            jsonrpc = "2.0", id = 1, method = "tools/call",
            params = { name = "nonexistent", arguments = {} },
        })
        server._dispatcher:step()
        local resp = out(msgs_out, 1)
        T.ok(resp.error)
        T.eq(resp.error.code, -32602)
    end)

    T.it("lists multiple tools", function()
        local server, msgs_in, msgs_out = make_test_server()
        server:tool("a", { description = "A", input_schema = {}, handler = function() return {} end })
        server:tool("b", { description = "B", input_schema = {}, handler = function() return {} end })
        server:tool("c", { description = "C", input_schema = {}, handler = function() return {} end })
        push(msgs_in, { jsonrpc = "2.0", id = 1, method = "tools/list", params = {} })
        server._dispatcher:step()
        local resp = out(msgs_out, 1)
        T.eq(#resp.result.tools, 3)
    end)

    T.it("returns empty array when no tools registered", function()
        local server, msgs_in, msgs_out = make_test_server()
        push(msgs_in, { jsonrpc = "2.0", id = 1, method = "tools/list", params = {} })
        server._dispatcher:step()
        local resp = out(msgs_out, 1)
        -- empty array decodes to empty table
        T.eq(#resp.result.tools, 0)
    end)
end)

-- ---------------------------------------------------------------------------
T.describe("resources", function()
    T.it("lists registered resources", function()
        local server, msgs_in, msgs_out = make_test_server()
        server:resource("file:///readme", {
            description = "The readme",
            handler = function() return {} end,
        })
        push(msgs_in, { jsonrpc = "2.0", id = 1, method = "resources/list", params = {} })
        server._dispatcher:step()
        local resp = out(msgs_out, 1)
        T.eq(#resp.result.resources, 1)
        T.eq(resp.result.resources[1].uri, "file:///readme")
        T.eq(resp.result.resources[1].handler, nil)
    end)

    T.it("reads a resource by URI", function()
        local server, msgs_in, msgs_out = make_test_server()
        server:resource("file:///hello", {
            description = "Hello file",
            handler = function(uri, _params)
                return { contents = { { uri = uri, text = "hello world" } } }
            end,
        })
        push(msgs_in, {
            jsonrpc = "2.0", id = 1, method = "resources/read",
            params = { uri = "file:///hello" },
        })
        server._dispatcher:step()
        local resp = out(msgs_out, 1)
        T.eq(resp.result.contents[1].text, "hello world")
        T.eq(resp.result.contents[1].uri, "file:///hello")
    end)

    T.it("returns error for unknown resource", function()
        local server, msgs_in, msgs_out = make_test_server()
        push(msgs_in, {
            jsonrpc = "2.0", id = 1, method = "resources/read",
            params = { uri = "file:///nope" },
        })
        server._dispatcher:step()
        local resp = out(msgs_out, 1)
        T.ok(resp.error)
        T.eq(resp.error.code, -32602)
    end)
end)

-- ---------------------------------------------------------------------------
T.describe("resource templates", function()
    T.it("lists registered templates", function()
        local server, msgs_in, msgs_out = make_test_server()
        server:resource_template("file:///{path}", {
            description = "Read any file",
            handler = function() return {} end,
        })
        push(msgs_in, { jsonrpc = "2.0", id = 1, method = "resources/templates/list", params = {} })
        server._dispatcher:step()
        local resp = out(msgs_out, 1)
        T.eq(#resp.result.resourceTemplates, 1)
        T.eq(resp.result.resourceTemplates[1].uriTemplate, "file:///{path}")
        T.eq(resp.result.resourceTemplates[1].handler, nil)
    end)
end)

-- ---------------------------------------------------------------------------
T.describe("prompts", function()
    T.it("lists registered prompts", function()
        local server, msgs_in, msgs_out = make_test_server()
        server:prompt("summarize", {
            description = "Summarize content",
            arguments = { { name = "text", required = true } },
            handler = function() return {} end,
        })
        push(msgs_in, { jsonrpc = "2.0", id = 1, method = "prompts/list", params = {} })
        server._dispatcher:step()
        local resp = out(msgs_out, 1)
        T.eq(#resp.result.prompts, 1)
        T.eq(resp.result.prompts[1].name, "summarize")
        T.eq(resp.result.prompts[1].description, "Summarize content")
        T.eq(resp.result.prompts[1].handler, nil)
    end)

    T.it("gets a prompt by name", function()
        local server, msgs_in, msgs_out = make_test_server()
        server:prompt("greet", {
            description = "Greet someone",
            arguments = { { name = "name", required = true } },
            handler = function(params)
                return {
                    messages = {
                        { role = "user", content = { type = "text", text = "Hello " .. params.name } },
                    },
                }
            end,
        })
        push(msgs_in, {
            jsonrpc = "2.0", id = 1, method = "prompts/get",
            params = { name = "greet", arguments = { name = "World" } },
        })
        server._dispatcher:step()
        local resp = out(msgs_out, 1)
        T.eq(resp.result.messages[1].content.text, "Hello World")
    end)

    T.it("returns error for unknown prompt", function()
        local server, msgs_in, msgs_out = make_test_server()
        push(msgs_in, {
            jsonrpc = "2.0", id = 1, method = "prompts/get",
            params = { name = "nonexistent", arguments = {} },
        })
        server._dispatcher:step()
        local resp = out(msgs_out, 1)
        T.ok(resp.error)
        T.eq(resp.error.code, -32602)
    end)
end)

-- ---------------------------------------------------------------------------
T.describe("logging", function()
    T.it("sends log notification to client", function()
        local server, msgs_in, msgs_out = make_test_server()
        server:log("info", "something happened")
        local resp = out(msgs_out, 1)
        T.eq(resp.method, "notifications/message")
        T.eq(resp.params.level, "info")
        T.eq(resp.params.logger, "test-server")
    end)

    T.it("respects minimum log level from setLevel", function()
        local server, msgs_in, msgs_out = make_test_server()
        -- Set level to warning — info should be suppressed
        push(msgs_in, {
            jsonrpc = "2.0", method = "logging/setLevel",
            params = { level = "warning" },
        })
        server._dispatcher:step()
        -- info is below warning threshold
        server:log("info", "should be suppressed")
        T.eq(#msgs_out, 0)
        -- warning should go through
        server:log("warning", "this should appear")
        T.eq(#msgs_out, 1)
    end)
end)

-- ---------------------------------------------------------------------------
T.describe("completions", function()
    T.it("returns completion values for registered argument", function()
        local server, msgs_in, msgs_out = make_test_server()
        server:completion("color", function(_params)
            return { completion = { values = { "red", "green", "blue" } } }
        end)
        push(msgs_in, {
            jsonrpc = "2.0", id = 1, method = "completion/complete",
            params = { argument = { name = "color" } },
        })
        server._dispatcher:step()
        local resp = out(msgs_out, 1)
        T.eq(#resp.result.completion.values, 3)
    end)

    T.it("returns empty values for unknown argument", function()
        local server, msgs_in, msgs_out = make_test_server()
        push(msgs_in, {
            jsonrpc = "2.0", id = 1, method = "completion/complete",
            params = { argument = { name = "unknown_arg" } },
        })
        server._dispatcher:step()
        local resp = out(msgs_out, 1)
        T.eq(#resp.result.completion.values, 0)
    end)
end)

-- ---------------------------------------------------------------------------
T.describe("initialized notification", function()
    T.it("accepts initialized notification without error", function()
        local server, msgs_in, msgs_out = make_test_server()
        push(msgs_in, { jsonrpc = "2.0", method = "notifications/initialized" })
        -- Should not crash or produce output (notifications have no response)
        server._dispatcher:step()
        T.eq(#msgs_out, 0)
    end)
end)
