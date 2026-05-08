-- lib/jsonrpc/init.lua
-- JSON-RPC 2.0 dispatcher with pluggable transport.
--
-- Usage:
--   local jsonrpc = require("lib.jsonrpc")
--   local d = jsonrpc.new(transport)
--   d:method("foo", function(params) return result end)
--   d:notify("bar", function(params) end)
--   d:loop()
--
-- Transports:
--   jsonrpc.stdio_transport()          -- LSP-style Content-Length framing
--   jsonrpc.table_transport(in, out)   -- in-memory, for testing

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local json = require("lib.format.json")

-- ---------------------------------------------------------------------------
-- Error codes (JSON-RPC 2.0 spec)
-- ---------------------------------------------------------------------------

local ERR_PARSE          = -32700
local ERR_INVALID        = -32600
local ERR_NOT_FOUND      = -32601
local ERR_INVALID_PARAMS = -32602
local ERR_INTERNAL       = -32603

-- ---------------------------------------------------------------------------
-- Dispatcher (metatable object)
-- ---------------------------------------------------------------------------

local Dispatcher = {}
Dispatcher.__index = Dispatcher

-- Internal: encode and send a message via transport.
-- self is `any` — setmetatable result; we own the layout.
--: (any, unknown) -> nil
local function send_msg(self, msg)
    local body, err = json.encode(msg)
    if not body then
        io.stderr:write("lib.jsonrpc: encode error: " .. tostring(err) .. "\n")
        return
    end
    self._transport:write(body)
end

-- Internal: build a success response.
--: (unknown, unknown) -> { [string]: unknown }
local function ok_resp(id, result)
    return { jsonrpc = "2.0", id = id, result = result }
end

-- Internal: build an error response.
--: (unknown, integer, string, unknown) -> { [string]: unknown }
local function err_resp(id, code, message, data)
    local e = { code = code, message = message }
    if data ~= nil then e.data = data end
    return { jsonrpc = "2.0", id = id, error = e }
end

-- Internal: dispatch a single parsed request/notification.
-- Captures two return values from handler (result + optional error descriptor).
-- Returns a response table for requests, nil for notifications.
-- self is `any` — setmetatable result; we own the layout.
--: (any, { [string]: unknown }) -> { [string]: unknown } | nil
local function dispatch_one(self, msg)
    local id     = msg.id
    local method = msg.method

    if type(method) ~= "string" then
        return err_resp(id, ERR_INVALID, "Invalid Request: method must be a string", nil)
    end

    -- Notification: id absent (nil). Ignore unknown methods silently.
    local is_notification = (id == nil)

    if is_notification then
        local handler = self._notifs[method]
        if handler then
            local ok, err2 = pcall(handler, msg.params)
            if not ok then
                io.stderr:write("lib.jsonrpc: notification handler error [" .. method .. "]: " .. tostring(err2) .. "\n")
            end
        end
        return nil
    end

    -- Request: must respond.
    local handler = self._methods[method]
    if not handler then
        return err_resp(id, ERR_NOT_FOUND, "Method not found: " .. tostring(method), nil)
    end

    -- Call handler and capture (result, err_obj) — LuaJIT-compatible (no table.pack).
    local pcall_ok, result, err_obj = pcall(handler, msg.params)
    if not pcall_ok then
        return err_resp(id, ERR_INTERNAL, "Internal error", tostring(result))
    end

    if result == nil and err_obj ~= nil then
        -- Handler signalled an error: nil, {code, message, data?}
        local code    = err_obj.code    or ERR_INTERNAL
        local message = err_obj.message or "Unknown error"
        return err_resp(id, code, message, err_obj.data)
    end

    -- Successful result. Encode nil as JSON null.
    local encoded_result = result
    if encoded_result == nil then encoded_result = json.null end
    return ok_resp(id, encoded_result)
end

-- ---------------------------------------------------------------------------
-- Public Dispatcher methods
-- ---------------------------------------------------------------------------

-- Register a method handler.
-- handler(params) -> result | nil, {code, message, data?}
--: (any, string, (unknown) -> unknown) -> nil
function Dispatcher:method(name, handler)
    self._methods[name] = handler
end

-- Register a notification handler (no response sent).
-- handler(params) -> nil
--: (any, string, (unknown) -> nil) -> nil
function Dispatcher:notify(name, handler)
    self._notifs[name] = handler
end

-- Send a request from this side. Generates an id, writes the request,
-- then synchronously reads responses until the matching one arrives.
-- Returns result, nil on success; nil, err_obj on error.
--: (any, string, unknown) -> (unknown, unknown)
function Dispatcher:request(method, params)
    local id = self._next_id
    self._next_id = id + 1
    self._pending[id] = true

    send_msg(self, { jsonrpc = "2.0", id = id, method = method, params = params })

    -- Read messages until we get our response.
    while true do
        local raw = self._transport:read()
        if raw == nil then
            self._pending[id] = nil
            return nil, { code = ERR_INTERNAL, message = "Transport closed waiting for response" }
        end

        local decoded = json.decode(raw)
        if decoded == nil then
            io.stderr:write("lib.jsonrpc: parse error in response stream\n")
        elseif type(decoded) == "table" and decoded.id == id then
            self._pending[id] = nil
            if decoded.error then
                return nil, decoded.error
            end
            return decoded.result, nil
        else
            -- Some other message arrived first — dispatch it.
            local resp = dispatch_one(self, decoded --[[:! { [string]: unknown }]])
            if resp then send_msg(self, resp) end
        end
    end
end

-- Send a notification from this side (no response expected).
--: (any, string, unknown) -> nil
function Dispatcher:send_notify(method, params)
    send_msg(self, { jsonrpc = "2.0", method = method, params = params })
end

-- Process one message from the transport.
-- Returns true on success, false on EOF.
--: (any) -> boolean
function Dispatcher:step()
    local raw = self._transport:read()
    if raw == nil then return false end

    local decoded, decode_err = json.decode(raw)
    if decoded == nil then
        -- Parse error — no id to respond to.
        send_msg(self, err_resp(json.null, ERR_PARSE, "Parse error: " .. tostring(decode_err), nil))
        return true
    end

    -- Batch: Lua array (has integer key 1 and no "method" field at top level).
    if type(decoded) == "table" and decoded[1] ~= nil and decoded.method == nil then
        local responses = {}
        for _, item in ipairs(decoded) do
            if type(item) == "table" then
                local resp = dispatch_one(self, item)
                if resp then responses[#responses + 1] = resp end
            end
        end
        if #responses > 0 then
            send_msg(self, responses)
        end
        return true
    end

    -- Single message.
    if type(decoded) ~= "table" then
        send_msg(self, err_resp(json.null, ERR_INVALID, "Invalid Request", nil))
        return true
    end

    local resp = dispatch_one(self, decoded)
    if resp then send_msg(self, resp) end
    return true
end

-- Loop: process messages until transport closes.
--: (any) -> nil
function Dispatcher:loop()
    while self:step() do end
end

-- ---------------------------------------------------------------------------
-- Constructor
-- ---------------------------------------------------------------------------

local M = {}

-- Create a new dispatcher backed by the given transport.
-- transport: object with read() -> string|nil and write(string) methods.
--: (unknown) -> unknown
function M.new(transport)
    local d = setmetatable({}, Dispatcher)
    d._methods   = {}
    d._notifs    = {}
    d._transport = transport
    d._next_id   = 1
    d._pending   = {}
    return d
end

-- ---------------------------------------------------------------------------
-- Built-in transports
-- ---------------------------------------------------------------------------

-- stdio_transport: LSP-style Content-Length framing over stdin/stdout.
-- read()  -> reads headers, extracts Content-Length, reads body JSON string.
-- write() -> writes Content-Length header + body to stdout.
--: () -> unknown
function M.stdio_transport()
    local t = {}

    function t:read()
        local content_length
        while true do
            local line = io.stdin:read("*l")
            if line == nil then return nil end
            line = line:gsub("\r$", "")
            if line == "" then break end
            local k, v = line:match("^(.-):%s*(.-)%s*$")
            if k and k:lower() == "content-length" then
                content_length = tonumber(v)
            end
        end
        if not content_length or content_length <= 0 then return nil end
        return io.stdin:read(content_length)
    end

    function t:write(s)
        io.stdout:write("Content-Length: " .. #s .. "\r\n\r\n" .. s)
        io.stdout:flush()
    end

    return t
end

-- table_transport: in-memory transport for testing.
-- messages_in:  array of raw JSON strings served as input (consumed in order).
-- messages_out: array that receives written messages.
-- Parameters are `any` — caller supplies concrete arrays; layout is known.
--: (any, any) -> unknown
function M.table_transport(messages_in, messages_out)
    local t   = {}
    local pos = 1

    function t:read()
        local msg = messages_in[pos]
        if msg == nil then return nil end
        pos = pos + 1
        return msg
    end

    function t:write(s)
        messages_out[#messages_out + 1] = s
    end

    return t
end

-- ---------------------------------------------------------------------------
-- Error code constants (public)
-- ---------------------------------------------------------------------------

M.ERR_PARSE          = ERR_PARSE
M.ERR_INVALID        = ERR_INVALID
M.ERR_NOT_FOUND      = ERR_NOT_FOUND
M.ERR_INVALID_PARAMS = ERR_INVALID_PARAMS
M.ERR_INTERNAL       = ERR_INTERNAL

return M
