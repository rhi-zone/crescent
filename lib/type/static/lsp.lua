-- lib/type/static/lsp.lua
-- LSP daemon for the crescent typechecker.
-- JSON-RPC 2.0 over stdio; full text sync; publishDiagnostics on open/change/save.
--
-- Usage:
--   luajit lib/type/static/lsp.lua
-- Then point your editor to this script as the language server.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local json   = require("lib.lunajson")
local check  = require("lib.type.static.check")

-- ---------------------------------------------------------------------------
-- JSON null sentinel
-- ---------------------------------------------------------------------------
-- lunajson.encode(v, nullv): any value == nullv is written as JSON null.
local NULL = {}  -- unique sentinel for JSON null

-- ---------------------------------------------------------------------------
-- Wire protocol
-- ---------------------------------------------------------------------------

local function send(msg)
    local body = json.encode(msg, NULL)
    io.stdout:write("Content-Length: " .. #body .. "\r\n\r\n" .. body)
    io.stdout:flush()
end

local function recv()
    local content_length
    while true do
        local line = io.stdin:read("*l")
        if line == nil then return nil end
        line = line:gsub("\r$", "")      -- strip CR from CRLF
        if line == "" then break end     -- blank line ends headers
        local k, v = line:match("^(.-):%s*(.-)%s*$")
        if k and k:lower() == "content-length" then
            content_length = tonumber(v)
        end
    end
    if not content_length or content_length <= 0 then return nil end
    local body = io.stdin:read(content_length)
    if not body then return nil end
    local ok, msg = pcall(json.decode, body)
    if not ok then
        io.stderr:write("crescent-lsp: JSON decode error: " .. tostring(msg) .. "\n")
        return nil
    end
    return msg
end

-- ---------------------------------------------------------------------------
-- Response helpers
-- ---------------------------------------------------------------------------

local function ok_resp(id, result)
    return { jsonrpc = "2.0", id = id, result = result }
end

local function err_resp(id, code, message)
    return { jsonrpc = "2.0", id = id, error = { code = code, message = message } }
end

local function notify(method, params)
    send({ jsonrpc = "2.0", method = method, params = params })
end

-- ---------------------------------------------------------------------------
-- File URI conversion
-- ---------------------------------------------------------------------------

local function uri_to_path(uri)
    -- file:///path or file://host/path  →  /path
    local path = uri:match("^file://[^/]*(/.+)$")
    if not path then return uri end
    path = path:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    return path
end

-- ---------------------------------------------------------------------------
-- Diagnostics
-- ---------------------------------------------------------------------------
-- Typechecker: line is 1-indexed, col is 0-indexed.
-- LSP Position: both 0-indexed.

local function to_lsp_diag(entry)
    local ln  = math.max(0, (entry.line or 1) - 1)
    local col = math.max(0, entry.col or 0)
    return {
        range = {
            start   = { line = ln, character = col },
            ["end"] = { line = ln, character = col + 1 },
        },
        severity = entry.kind == "error" and 1 or 2,  -- 1=Error, 2=Warning
        source   = "crescent",
        message  = entry.msg,
    }
end

local function run_check(state, uri, text)
    -- Skip if text is unchanged and diagnostics are cached.
    if state.text_cache[uri] == text and state.diag_cache[uri] then
        notify("textDocument/publishDiagnostics", {
            uri = uri, diagnostics = state.diag_cache[uri],
        })
        return
    end

    local path = uri_to_path(uri)
    state.text_cache[uri] = text

    -- Clear per-session cache so this file is re-checked fresh.
    check.clear_cache()

    local err_ctx = check.check_string(text, path)

    local diags = {}
    for _, e in ipairs(err_ctx.errors) do
        if e.filename == path then
            diags[#diags + 1] = to_lsp_diag(e)
        end
    end
    for _, w in ipairs(err_ctx.warnings) do
        if w.filename == path then
            diags[#diags + 1] = to_lsp_diag(w)
        end
    end

    state.diag_cache[uri] = diags
    notify("textDocument/publishDiagnostics", {
        uri = uri, diagnostics = diags,
    })
end

-- ---------------------------------------------------------------------------
-- Message handlers
-- ---------------------------------------------------------------------------

local HANDLERS = {}

HANDLERS["initialize"] = function(state, msg)
    state.initialized = true
    send(ok_resp(msg.id, {
        capabilities = {
            textDocumentSync = {
                openClose = true,
                change    = 1,    -- Full document sync
                save      = true,
            },
        },
        serverInfo = { name = "crescent", version = "0.2.0" },
    }))
end

HANDLERS["initialized"] = function(_state, _msg)
    -- Notification: no response.
end

HANDLERS["shutdown"] = function(state, msg)
    state.shutdown = true
    send(ok_resp(msg.id, NULL))  -- LSP spec: result must be null
end

HANDLERS["exit"] = function(state, _msg)
    os.exit(state.shutdown and 0 or 1)
end

HANDLERS["textDocument/didOpen"] = function(state, msg)
    local p = msg.params
    if not p or not p.textDocument then return end
    local uri  = p.textDocument.uri
    local text = p.textDocument.text
    if not text then return end
    state.open_files[uri] = text
    run_check(state, uri, text)
end

HANDLERS["textDocument/didChange"] = function(state, msg)
    local p = msg.params
    if not p or not p.textDocument then return end
    local uri = p.textDocument.uri
    -- Full sync: last content change holds the full document text.
    local text
    if p.contentChanges and #p.contentChanges > 0 then
        text = p.contentChanges[#p.contentChanges].text
    end
    if not text then return end
    state.open_files[uri] = text
    run_check(state, uri, text)
end

HANDLERS["textDocument/didSave"] = function(state, msg)
    local p = msg.params
    if not p or not p.textDocument then return end
    local uri  = p.textDocument.uri
    -- If the client sends the text in didSave, use it; otherwise re-check
    -- from the last known content.
    local text = (p.text ~= nil and p.text) or state.open_files[uri]
    if not text then return end
    -- Force re-check on save even if text is unchanged.
    state.text_cache[uri] = nil
    run_check(state, uri, text)
end

HANDLERS["textDocument/didClose"] = function(state, msg)
    local p = msg.params
    if not p or not p.textDocument then return end
    local uri = p.textDocument.uri
    state.open_files[uri] = nil
    state.text_cache[uri] = nil
    state.diag_cache[uri] = nil
    -- Clear diagnostics for the closed file.
    notify("textDocument/publishDiagnostics", { uri = uri, diagnostics = {} })
end

HANDLERS["$/cancelRequest"]     = function(_s, _m) end
HANDLERS["$/setTrace"]          = function(_s, _m) end
HANDLERS["$/setTraceNotification"] = function(_s, _m) end

-- ---------------------------------------------------------------------------
-- Main loop
-- ---------------------------------------------------------------------------

local function main()
    local state = {
        initialized = false,
        shutdown    = false,
        open_files  = {},   -- uri → text
        text_cache  = {},   -- uri → last-checked text
        diag_cache  = {},   -- uri → last diags array
    }

    while true do
        local msg = recv()
        if msg == nil then break end

        local method = msg.method
        if method then
            local handler = HANDLERS[method]
            if handler then
                local ok, err = pcall(handler, state, msg)
                if not ok then
                    io.stderr:write("crescent-lsp: error in " .. method
                        .. ": " .. tostring(err) .. "\n")
                    if msg.id ~= nil then
                        send(err_resp(msg.id, -32603, tostring(err)))
                    end
                end
            elseif msg.id ~= nil then
                -- Unknown request (not notification): respond with MethodNotFound.
                send(err_resp(msg.id, -32601, "method not found: " .. tostring(method)))
            end
            -- Unknown notifications are silently ignored.
        end
    end
end

main()
