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
local types  = require("lib.type.static.types")
local intern = require("lib.type.static.intern")
local defs   = require("lib.type.static.defs")

-- ---------------------------------------------------------------------------
-- JSON null sentinel
-- ---------------------------------------------------------------------------
-- lunajson.encode(v, nullv): any value == nullv is written as JSON null.
local NULL = {}  -- unique sentinel for JSON null

-- lunajson encodes empty tables as "{}" (object). To force "[]" (array),
-- set t[0] = 0 (explicit array-length marker recognized by lunajson).
local EMPTY_ARRAY = {[0] = 0}

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
    -- Typechecker col is 1-indexed; LSP character is 0-indexed.
    local col = math.max(0, (entry.col or 1) - 1)
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

-- ---------------------------------------------------------------------------
-- Hover helpers
-- ---------------------------------------------------------------------------
-- name_at is a flat array: {line1, col1, name_id1, ...}; same coord system as type_at.
local function name_at_lookup(ctx, hover_line, hover_col)
    local na = ctx.name_at
    if not na then return nil end
    local tc_line = hover_line + 1
    local tc_col  = hover_col + 1
    local best_name_id, best_col
    local i = 1
    local n = #na
    while i <= n do
        local eline = na[i]
        local ecol  = na[i + 1]
        local eid   = na[i + 2]
        if eline == tc_line and ecol <= tc_col then
            if best_col == nil or ecol >= best_col then
                best_col = ecol
                best_name_id = eid
            end
        end
        i = i + 3
    end
    return best_name_id
end

-- type_at is a flat array: {line1, col1, tid1, line2, col2, tid2, ...}
-- typechecker line is 1-indexed; col is 0-indexed.
-- LSP position: both 0-indexed.
local function type_at_lookup(ctx, hover_line, hover_col)
    local ta = ctx.type_at
    if not ta then return nil end
    -- Convert LSP position to typechecker coords.
    -- LSP: 0-indexed line, 0-indexed char.
    -- Typechecker: 1-indexed line, 1-indexed col.
    local tc_line = hover_line + 1
    local tc_col  = hover_col + 1
    -- Find the entry on the correct line whose col is closest to (≤) hover col.
    local best_tid, best_col
    local i = 1
    local n = #ta
    while i <= n do
        local eline = ta[i]
        local ecol  = ta[i + 1]
        local etid  = ta[i + 2]
        if eline == tc_line and ecol <= tc_col then
            if best_col == nil or ecol >= best_col then
                best_col = ecol
                best_tid = etid
            end
        end
        i = i + 3
    end
    return best_tid
end

-- ---------------------------------------------------------------------------
-- Check + publish
-- ---------------------------------------------------------------------------

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

    local err_ctx, ctx = check.check_string(text, path)

    -- Store ctx for hover queries (ctx.type_at is always populated by infer_expr).
    state.ctx_cache[uri] = ctx

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

    state.diag_cache[uri] = #diags > 0 and diags or EMPTY_ARRAY
    notify("textDocument/publishDiagnostics", {
        uri = uri, diagnostics = state.diag_cache[uri],
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
            hoverProvider      = true,
            definitionProvider = true,
            completionProvider = { triggerCharacters = { ".", ":" } },
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
    state.ctx_cache[uri]  = nil
    -- Clear diagnostics for the closed file.
    notify("textDocument/publishDiagnostics", { uri = uri, diagnostics = EMPTY_ARRAY })
end

HANDLERS["textDocument/hover"] = function(state, msg)
    local p = msg.params
    if not p or not p.textDocument or not p.position then
        send(ok_resp(msg.id, NULL))
        return
    end
    local uri  = p.textDocument.uri
    local ln   = p.position.line      -- 0-indexed
    local col  = p.position.character -- 0-indexed
    local ctx  = state.ctx_cache[uri]
    if not ctx then
        send(ok_resp(msg.id, NULL))
        return
    end
    local tid = type_at_lookup(ctx, ln, col)
    if not tid then
        send(ok_resp(msg.id, NULL))
        return
    end
    local resolved = types.find(ctx, tid)
    local type_str = types.display(ctx, resolved)
    send(ok_resp(msg.id, {
        contents = { kind = "markdown", value = "```\n" .. type_str .. "\n```" },
    }))
end

HANDLERS["textDocument/completion"] = function(state, msg)
    local p = msg.params
    if not p or not p.textDocument then
        send(ok_resp(msg.id, EMPTY_ARRAY))
        return
    end
    local uri = p.textDocument.uri
    local ctx = state.ctx_cache[uri]
    if not ctx then
        send(ok_resp(msg.id, EMPTY_ARRAY))
        return
    end
    -- Enumerate all names visible in the module-level scope chain.
    -- This is a best-effort approximation; cursor-local scopes are not tracked.
    local TAG_FUNCTION = defs.TAG_FUNCTION
    local TAG_TABLE    = defs.TAG_TABLE
    local items = {}
    local seen = {}
    local scope = ctx.scope
    while scope do
        for name_id, type_id in pairs(scope.bindings) do
            if not seen[name_id] then
                seen[name_id] = true
                local name = intern.get(ctx.pool, name_id)
                if name and name:sub(1, 2) ~= "__" then  -- skip metamethod names
                    local resolved = types.find(ctx, type_id)
                    local rt = ctx.types:get(resolved)
                    -- LSP CompletionItemKind: 3=Function, 6=Variable, 7=Class(table), 9=Module
                    local kind = 6
                    if rt.tag == TAG_FUNCTION then kind = 3
                    elseif rt.tag == TAG_TABLE then kind = 7
                    end
                    items[#items + 1] = {
                        label  = name,
                        kind   = kind,
                        detail = types.display_short(ctx, resolved),
                    }
                end
            end
        end
        scope = scope.parent
    end
    send(ok_resp(msg.id, items))
end

HANDLERS["textDocument/definition"] = function(state, msg)
    local p = msg.params
    if not p or not p.textDocument or not p.position then
        send(ok_resp(msg.id, NULL))
        return
    end
    local uri = p.textDocument.uri
    local ln  = p.position.line
    local col = p.position.character
    local ctx = state.ctx_cache[uri]
    if not ctx then
        send(ok_resp(msg.id, NULL))
        return
    end
    local name_id = name_at_lookup(ctx, ln, col)
    if not name_id then
        send(ok_resp(msg.id, NULL))
        return
    end
    local def = ctx.def_sites[name_id]
    if not def then
        send(ok_resp(msg.id, NULL))
        return
    end
    -- Convert typechecker 1-indexed line/col to LSP 0-indexed.
    local def_ln  = math.max(0, def.line - 1)
    local def_col = math.max(0, def.col - 1)
    send(ok_resp(msg.id, {
        uri   = uri,
        range = {
            start   = { line = def_ln, character = def_col },
            ["end"] = { line = def_ln, character = def_col + 1 },
        },
    }))
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
        ctx_cache   = {},   -- uri → infer ctx (for hover type_at lookup)
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
