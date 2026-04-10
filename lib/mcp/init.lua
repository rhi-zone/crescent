-- lib/mcp/init.lua
-- Model Context Protocol server library built on lib/jsonrpc.
--
-- Usage:
--   local mcp = require("lib.mcp")
--   local server = mcp.server({ name = "my-server", version = "1.0.0" })
--   server:tool("search", { description = "...", input_schema = {...}, handler = function(params) ... end })
--   server:listen()

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local jsonrpc = require("lib.jsonrpc")

-- ---------------------------------------------------------------------------
-- Log levels (MCP spec order, lower index = more severe)
-- ---------------------------------------------------------------------------

local LOG_LEVELS = {
    emergency = 1, alert = 2, critical = 3, error = 4,
    warning = 5, notice = 6, info = 7, debug = 8,
}

-- ---------------------------------------------------------------------------
-- Server (metatable object)
-- ---------------------------------------------------------------------------

local Server = {}
Server.__index = Server

-- Register a tool.
--: (any, string, { description: string, input_schema: unknown, handler: (unknown) -> unknown }) -> nil
function Server:tool(name, opts)
    self._tools[name] = {
        name = name,
        description = opts.description,
        inputSchema = opts.input_schema,
        handler = opts.handler,
    }
end

-- Register a static resource (exact URI match).
--: (any, string, { description: string, handler: (string, unknown) -> unknown }) -> nil
function Server:resource(uri, opts)
    self._resources[uri] = {
        uri = uri,
        name = opts.name or uri,
        description = opts.description,
        handler = opts.handler,
    }
end

-- Register a resource template (URI template pattern).
--: (any, string, { description: string, handler: (string, unknown) -> unknown }) -> nil
function Server:resource_template(uri_template, opts)
    self._resource_templates[uri_template] = {
        uriTemplate = uri_template,
        name = opts.name or uri_template,
        description = opts.description,
        handler = opts.handler,
    }
end

-- Register a prompt.
--: (any, string, { description: string, arguments: unknown, handler: (unknown) -> unknown }) -> nil
function Server:prompt(name, opts)
    self._prompts[name] = {
        name = name,
        description = opts.description,
        arguments = opts.arguments,
        handler = opts.handler,
    }
end

-- Register a completion handler for an argument name.
--: (any, string, (unknown) -> unknown) -> nil
function Server:completion(key, handler)
    self._completions[key] = handler
end

-- Send a log notification to the client.
-- Respects the minimum log level set by the client via logging/setLevel.
--: (any, string, string, unknown) -> nil
function Server:log(level, message, data)
    local level_n = LOG_LEVELS[level] or 7
    local min_n = LOG_LEVELS[self._log_level] or 7
    if level_n > min_n then return end
    local params = { level = level, logger = self._name, data = message }
    if data ~= nil then params.data = data end
    self._dispatcher:send_notify("notifications/message", params)
end

-- Start the server loop (delegates to jsonrpc dispatcher).
--: (any) -> nil
function Server:listen()
    self._dispatcher:loop()
end

-- ---------------------------------------------------------------------------
-- Internal: collect array values from a name-keyed table
-- ---------------------------------------------------------------------------

--: ({ [string]: unknown }) -> unknown[]
local function values_array(tbl)
    local arr = {}
    for _, v in pairs(tbl) do
        arr[#arr + 1] = v
    end
    if #arr == 0 then return {} end
    return arr
end

-- ---------------------------------------------------------------------------
-- Internal: strip handler from a definition for list responses
-- ---------------------------------------------------------------------------

--: (unknown) -> unknown
local function strip_handler(def)
    local out = {}
    for k, v in pairs(def) do
        if k ~= "handler" then out[k] = v end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Constructor
-- ---------------------------------------------------------------------------

local M = {}

-- Create an MCP server.
--: ({ name: string, version: string, transport: unknown }) -> any
function M.server(opts)
    local transport = opts.transport or jsonrpc.stdio_transport()
    local d = jsonrpc.new(transport)

    local s = setmetatable({}, Server)
    s._dispatcher = d
    s._name = opts.name
    s._version = opts.version
    s._tools = {}
    s._resources = {}
    s._resource_templates = {}
    s._prompts = {}
    s._completions = {}
    s._log_level = "debug"

    -- ── initialize ──────────────────────────────────────────────────────
    d:method("initialize", function(_params)
        local capabilities = { logging = {} }
        if next(s._tools) then capabilities.tools = {} end
        if next(s._resources) or next(s._resource_templates) then capabilities.resources = {} end
        if next(s._prompts) then capabilities.prompts = {} end
        return {
            protocolVersion = "2024-11-05",
            capabilities = capabilities,
            serverInfo = { name = s._name, version = s._version },
        }
    end)

    d:notify("notifications/initialized", function(_params) end)

    -- ── ping ────────────────────────────────────────────────────────────
    d:method("ping", function(_params) return {} end)

    -- ── tools ───────────────────────────────────────────────────────────
    d:method("tools/list", function(_params)
        local list = {}
        for _, tool in pairs(s._tools) do
            list[#list + 1] = strip_handler(tool)
        end
        return { tools = #list > 0 and list or {} }
    end)

    d:method("tools/call", function(params)
        local tool = s._tools[params.name]
        if not tool then
            return nil, { code = -32602, message = "Tool not found: " .. tostring(params.name) }
        end
        return tool.handler(params.arguments)
    end)

    -- ── resources ───────────────────────────────────────────────────────
    d:method("resources/list", function(_params)
        local list = {}
        for _, res in pairs(s._resources) do
            list[#list + 1] = strip_handler(res)
        end
        return { resources = #list > 0 and list or {} }
    end)

    d:method("resources/read", function(params)
        local uri = params.uri
        -- Try exact match first.
        local res = s._resources[uri]
        if res then return res.handler(uri, params) end
        -- Try templates (simple prefix/pattern matching left to handler).
        for _, tmpl in pairs(s._resource_templates) do
            local result = tmpl.handler(uri, params)
            if result then return result end
        end
        return nil, { code = -32602, message = "Resource not found: " .. tostring(uri) }
    end)

    d:method("resources/templates/list", function(_params)
        local list = {}
        for _, tmpl in pairs(s._resource_templates) do
            list[#list + 1] = strip_handler(tmpl)
        end
        return { resourceTemplates = #list > 0 and list or {} }
    end)

    -- ── prompts ─────────────────────────────────────────────────────────
    d:method("prompts/list", function(_params)
        local list = {}
        for _, p in pairs(s._prompts) do
            list[#list + 1] = strip_handler(p)
        end
        return { prompts = #list > 0 and list or {} }
    end)

    d:method("prompts/get", function(params)
        local p = s._prompts[params.name]
        if not p then
            return nil, { code = -32602, message = "Prompt not found: " .. tostring(params.name) }
        end
        return p.handler(params.arguments or {})
    end)

    -- ── logging ─────────────────────────────────────────────────────────
    d:notify("logging/setLevel", function(params)
        if params and params.level then
            s._log_level = params.level
        end
    end)

    -- ── completions ─────────────────────────────────────────────────────
    d:method("completion/complete", function(params)
        local arg_name = params and params.argument and params.argument.name
        local handler = s._completions[arg_name]
        if not handler then
            return { completion = { values = {} } }
        end
        return handler(params)
    end)

    return s
end

return M
