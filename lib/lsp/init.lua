-- lib/lsp/init.lua
-- LSP protocol method binding library built on top of lib/jsonrpc.
--
-- Usage:
--   local lsp = require("lib.lsp")
--   local server = lsp.server(opts)
--   server:on_hover(function(params) return {contents = {...}} end)
--   server:listen()

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local jsonrpc = require("lib.jsonrpc")
local json    = require("lib.format.json")
local methods = require("lib.lsp.methods")

-- ---------------------------------------------------------------------------
-- Server (metatable object)
-- ---------------------------------------------------------------------------

local Server = {}
Server.__index = Server

-- Map from on_* registration method name to {method_name, capability_key, capability_value, is_notification}.
-- Used for auto-detection of capabilities and DRY registration.
--: { [string]: { [1]: string, [2]: string | nil, [3]: unknown, [4]: boolean } }
local HANDLERS = {
    on_hover           = { methods.HOVER,           "hoverProvider",              true,  false },
    on_completion      = { methods.COMPLETION,       "completionProvider",         {},    false },
    on_definition      = { methods.DEFINITION,       "definitionProvider",         true,  false },
    on_references      = { methods.REFERENCES,       "referencesProvider",         true,  false },
    on_document_symbol = { methods.DOCUMENT_SYMBOL,  "documentSymbolProvider",     true,  false },
    on_signature_help  = { methods.SIGNATURE_HELP,   "signatureHelpProvider",      {},    false },
    on_formatting      = { methods.FORMATTING,       "documentFormattingProvider", true,  false },
    on_rename          = { methods.RENAME,            "renameProvider",             true,  false },
    on_code_action     = { methods.CODE_ACTION,       "codeActionProvider",         true,  false },
    on_diagnostic      = { methods.DIAGNOSTIC,        "diagnosticProvider",         { interFileDependencies = false, workspaceDiagnostics = false }, false },
    -- Notifications (client -> server)
    on_did_open        = { methods.DID_OPEN,   nil, nil, true },
    on_did_close       = { methods.DID_CLOSE,  nil, nil, true },
    on_did_change      = { methods.DID_CHANGE, nil, nil, true },
    on_did_save        = { methods.DID_SAVE,   nil, nil, true },
    on_initialized     = { methods.INITIALIZED, nil, nil, true },
}

-- Text sync notification names for capability detection.
local TEXT_SYNC_NOTIFS = {
    [methods.DID_OPEN]   = true,
    [methods.DID_CLOSE]  = true,
    [methods.DID_CHANGE] = true,
    [methods.DID_SAVE]   = true,
}

-- Build capabilities from registered handlers.
--: (any) -> { [string]: unknown }
local function build_capabilities(self)
    local caps = {}

    -- Check each handler entry for registered capabilities.
    for _, entry in pairs(HANDLERS) do
        local method_name = entry[1]
        local cap_key     = entry[2]
        local cap_value   = entry[3]
        if cap_key and (self._dispatcher._methods[method_name] or self._dispatcher._notifs[method_name]) then
            caps[cap_key] = cap_value
        end
    end

    -- Text document sync: if any of the text sync notifications are registered.
    local has_text_sync = false
    for name in pairs(TEXT_SYNC_NOTIFS) do
        if self._dispatcher._notifs[name] then
            has_text_sync = true
            break
        end
    end
    if has_text_sync then
        caps.textDocumentSync = { openClose = true, change = 1, save = true }
    end

    return caps
end

-- Generate on_* methods from the HANDLERS table.
for fn_name, entry in pairs(HANDLERS) do
    local method_name    = entry[1]
    local is_notif       = entry[4]
    if is_notif then
        Server[fn_name] = function(self, handler)
            self._dispatcher:notify(method_name, handler)
        end
    else
        Server[fn_name] = function(self, handler)
            self._dispatcher:method(method_name, handler)
        end
    end
end

-- Special: on_initialize wraps the user handler to merge capabilities.
--: (any, ((unknown) -> unknown) | nil) -> nil
function Server:on_initialize(handler)
    self._user_init_handler = handler
end

-- Special: on_exit registers a callback that runs before os.exit.
--: (any, (() -> nil) | nil) -> nil
function Server:on_exit(handler)
    self._dispatcher:notify(methods.EXIT, function(_params)
        if handler then handler() end
        os.exit(0)
    end)
end

-- Server -> client notifications.

-- Publish diagnostics to the client.
--: (any, unknown) -> nil
function Server:publish_diagnostics(params)
    self._dispatcher:send_notify(methods.PUBLISH_DIAGNOSTICS, params)
end

-- Send a log message to the client.
--: (any, integer, string) -> nil
function Server:log_message(msg_type, message)
    self._dispatcher:send_notify(methods.LOG_MESSAGE, { type = msg_type, message = message })
end

-- Send a show-message notification to the client.
--: (any, integer, string) -> nil
function Server:show_message(msg_type, message)
    self._dispatcher:send_notify(methods.SHOW_MESSAGE, { type = msg_type, message = message })
end

-- Start processing messages (delegates to jsonrpc dispatcher loop).
--: (any) -> nil
function Server:listen()
    self._dispatcher:loop()
end

-- ---------------------------------------------------------------------------
-- Constructor
-- ---------------------------------------------------------------------------

local M = {}

-- Create a new LSP server.
-- opts.transport: a transport object (default: jsonrpc.stdio_transport()).
--: (unknown) -> unknown
function M.server(opts)
    opts = opts or {}
    local transport = opts.transport or jsonrpc.stdio_transport()
    local d = jsonrpc.new(transport)

    local self = setmetatable({}, Server)
    self._dispatcher = d
    self._user_init_handler = nil
    self._client_capabilities = nil

    -- Register the initialize request handler.
    d:method(methods.INITIALIZE, function(params)
        self._client_capabilities = params and params.capabilities or {}
        local user_result
        if self._user_init_handler then
            user_result = self._user_init_handler(params)
        end
        -- Merge auto-detected capabilities with any user-provided ones.
        local auto_caps = build_capabilities(self)
        local result = user_result or {}
        if not result.capabilities then
            result.capabilities = auto_caps
        else
            -- User caps take precedence; fill in auto-detected ones they didn't set.
            for k, v in pairs(auto_caps) do
                if result.capabilities[k] == nil then
                    result.capabilities[k] = v
                end
            end
        end
        return result
    end)

    -- Register the shutdown request handler (returns json.null = success).
    d:method(methods.SHUTDOWN, function(_params)
        return json.null
    end)

    -- Register exit notification (default: just exit).
    d:notify(methods.EXIT, function(_params)
        os.exit(0)
    end)

    return self
end

-- Re-export methods constants.
M.methods = methods

return M
