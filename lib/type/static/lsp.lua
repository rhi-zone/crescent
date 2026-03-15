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
-- Returns name_id, matched_col (both nil if no match).
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
    return best_name_id, best_col
end

-- field_at is a flat array: {line, col, field_name_id, obj_name_id, ...} stride=4.
-- Returns field_id, obj_name_id, matched_col (all nil if no match).
local function field_at_lookup(ctx, hover_line, hover_col)
    local fa = ctx.field_at
    if not fa then return nil end
    local tc_line = hover_line + 1
    local tc_col  = hover_col + 1
    local best_fid, best_oid, best_col
    local i = 1
    local n = #fa
    while i <= n do
        local eline = fa[i]
        local ecol  = fa[i + 1]
        local efid  = fa[i + 2]
        local eoid  = fa[i + 3]
        if eline == tc_line and ecol <= tc_col then
            if best_col == nil or ecol >= best_col then
                best_col = ecol
                best_fid = efid
                best_oid = eoid
            end
        end
        i = i + 4
    end
    return best_fid, best_oid, best_col
end

-- Scan ctx_scan.nodes for the definition of a field with intern id `field_id`.
-- obj_name_id_opt: if non-nil, only match that object variable; nil matches any.
-- Returns {line, col} (1-indexed typechecker coords) or nil.
local function find_field_in_ctx(ctx_scan, obj_name_id_opt, field_id)
    local NODE_ASSIGN_STMT = defs.NODE_ASSIGN_STMT
    local NODE_FUNC_DECL   = defs.NODE_FUNC_DECL
    local NODE_FIELD_EXPR  = defs.NODE_FIELD_EXPR
    local NODE_IDENTIFIER  = defs.NODE_IDENTIFIER
    for i = 0, ctx_scan.nodes.len - 1 do
        local nd = ctx_scan.nodes:get(i)
        if nd.kind == NODE_ASSIGN_STMT then
            local ls, lc = nd.data[0], nd.data[1]
            for j = ls, ls + lc - 1 do
                local lhs_n = ctx_scan.nodes:get(ctx_scan.ast_lists:get(j))
                if lhs_n.kind == NODE_FIELD_EXPR and lhs_n.data[1] == field_id then
                    local obj_n = ctx_scan.nodes:get(lhs_n.data[0])
                    if obj_n.kind == NODE_IDENTIFIER
                        and (obj_name_id_opt == nil or obj_n.data[0] == obj_name_id_opt) then
                        return { line = lhs_n.line, col = lhs_n.col }
                    end
                end
            end
        elseif nd.kind == NODE_FUNC_DECL then
            local name_n = ctx_scan.nodes:get(nd.data[0])
            if name_n.kind == NODE_FIELD_EXPR and name_n.data[1] == field_id then
                local obj_n = ctx_scan.nodes:get(name_n.data[0])
                if obj_n.kind == NODE_IDENTIFIER
                    and (obj_name_id_opt == nil or obj_n.data[0] == obj_name_id_opt) then
                    return { line = name_n.line, col = name_n.col }
                end
            end
        end
    end
    return nil
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

    -- Invalidate only this file's session entry; dependencies on disk remain cached.
    check.invalidate_file(path)

    local err_ctx, ctx = check.check_string_with_deps(text, path)

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
-- Field completion helpers
-- ---------------------------------------------------------------------------

-- Return the text of line lsp_line (0-indexed) from a full document string.
local function get_line(text, lsp_line)
    local n = 0
    local pos = 1
    while pos <= #text do
        local nl = text:find("\n", pos, true)
        if n == lsp_line then
            return text:sub(pos, nl and nl - 1 or #text)
        end
        if nl then pos = nl + 1 else break end
        n = n + 1
    end
    return nil
end

-- Build completion items for all regular fields of a table type.
-- Handles TAG_TABLE directly; for TAG_UNION, merges fields from all members.
-- Returns an array (possibly empty) or nil if tid has no table fields.
local function table_field_items(ctx, tid)
    local TAG_FUNCTION    = defs.TAG_FUNCTION
    local TAG_TABLE       = defs.TAG_TABLE
    local TAG_UNION       = defs.TAG_UNION
    local TAG_INTERSECTION = defs.TAG_INTERSECTION

    local function collect_fields(resolved, out, seen_names)
        local t = ctx.types:get(resolved)
        if t.tag == TAG_TABLE then
            for i = t.data[0], t.data[0] + t.data[1] - 1 do
                local fid  = ctx.lists:get(i)
                local fe   = ctx.fields:get(fid)
                local name = intern.get(ctx.pool, fe.name_id)
                if name and name:sub(1, 2) ~= "__" and not seen_names[name] then
                    seen_names[name] = true
                    local fres = types.find(ctx, fe.type_id)
                    local ft   = ctx.types:get(fres)
                    local kind = ft.tag == TAG_FUNCTION and 3 or 6
                    out[#out + 1] = {
                        label  = name,
                        kind   = kind,
                        detail = types.display_short(ctx, fres),
                    }
                end
            end
        elseif t.tag == TAG_UNION or t.tag == TAG_INTERSECTION then
            for i = t.data[0], t.data[0] + t.data[1] - 1 do
                collect_fields(types.find(ctx, ctx.lists:get(i)), out, seen_names)
            end
        end
    end

    local resolved = types.find(ctx, tid)
    local t = ctx.types:get(resolved)
    if t.tag ~= TAG_TABLE and t.tag ~= TAG_UNION and t.tag ~= TAG_INTERSECTION then
        return nil
    end
    local items = {}
    collect_fields(resolved, items, {})
    return #items > 0 and items or nil
end

-- ---------------------------------------------------------------------------
-- Signature help helpers
-- ---------------------------------------------------------------------------

-- Build a SignatureInformation from a TAG_FUNCTION type.
-- Returns {label, parameters=[{label},...]} or nil.
local function fn_signature(ctx, fn_tid)
    local TAG_FUNCTION = defs.TAG_FUNCTION
    local resolved = types.find(ctx, fn_tid)
    local t = ctx.types:get(resolved)
    if t.tag ~= TAG_FUNCTION then return nil end

    local param_labels = {}
    for i = t.data[0], t.data[0] + t.data[1] - 1 do
        local ptid = types.find(ctx, ctx.lists:get(i))
        local label = types.display_short(ctx, ptid)
        -- If the slot has a name (data[5]/data[6] in the list), prefer it.
        -- Param names are stored in the TypeSlot's data fields; display_short
        -- already shows the type, which is sufficient.
        param_labels[#param_labels + 1] = { label = label }
    end

    local full_label = types.display_short(ctx, resolved)
    return { label = full_label, parameters = param_labels }
end

-- Resolve the function type at a call site by scanning the line prefix
-- for a function name before the opening paren or last comma.
-- Returns a SignatureInformation table or nil.
local function signature_at(ctx, text, lsp_line, lsp_char)
    local line = get_line(text, lsp_line)
    if not line then return nil end

    -- Extract prefix up to the cursor.
    local prefix = line:sub(1, lsp_char)

    -- Count open parens to find active arg index and the call start.
    -- Strategy: find the innermost unclosed '('.
    local depth = 0
    local call_start = nil
    for i = #prefix, 1, -1 do
        local ch = prefix:sub(i, i)
        if ch == ")" then
            depth = depth + 1
        elseif ch == "(" then
            if depth == 0 then
                call_start = i
                break
            end
            depth = depth - 1
        end
    end
    if not call_start then return nil end

    -- Count top-level commas between call_start+1 and cursor to find active param index.
    local active_param = 0
    local inner_depth = 0
    for i = call_start + 1, #prefix do
        local ch = prefix:sub(i, i)
        if ch == "(" or ch == "[" or ch == "{" then
            inner_depth = inner_depth + 1
        elseif ch == ")" or ch == "]" or ch == "}" then
            inner_depth = inner_depth - 1
        elseif ch == "," and inner_depth == 0 then
            active_param = active_param + 1
        end
    end

    -- Extract the callee expression: text before '('.
    local callee_str = prefix:sub(1, call_start - 1):match("([%a_][%w_%.%:]*)%s*$")
    if not callee_str then return nil end

    -- For method calls (x:method), strip the colon part and look up on the object.
    -- For field calls (x.method), strip the dot part.
    -- For simple calls (foo), look up directly.
    local obj_str, fn_str = callee_str:match("^(.+)[%.%:]([%a_][%w_]*)$")

    local function lookup_in_scope(name_str)
        local name_id = ctx.pool.map[name_str]
        if not name_id then return nil end
        local scope = ctx.scope
        while scope do
            if scope.bindings[name_id] then
                return scope.bindings[name_id]
            end
            scope = scope.parent
        end
        return nil
    end

    local fn_tid
    if obj_str and fn_str then
        -- x.method or x:method — look up x then get the field.
        local obj_name = obj_str:match("[%a_][%w_]*$") -- last simple name in chain
        local obj_tid = lookup_in_scope(obj_name)
        if not obj_tid then return nil end
        local obj_res = types.find(ctx, obj_tid)
        local ot = ctx.types:get(obj_res)
        if ot.tag == defs.TAG_TABLE then
            local fn_name_id = ctx.pool.map[fn_str]
            if not fn_name_id then return nil end
            for i = ot.data[0], ot.data[0] + ot.data[1] - 1 do
                local fe = ctx.fields:get(ctx.lists:get(i))
                if fe.name_id == fn_name_id then
                    fn_tid = types.find(ctx, fe.type_id)
                    break
                end
            end
        end
    else
        -- Simple identifier.
        fn_tid = lookup_in_scope(callee_str)
    end

    if not fn_tid then return nil end
    return fn_signature(ctx, fn_tid), active_param
end

-- Given a trigger character ("." or ":") and cursor position, try to
-- extract the identifier before the trigger and look up its fields.
-- Returns an items array on success, nil on failure.
local function field_completions(ctx, text, lsp_line, lsp_char, trigger)
    local line = get_line(text, lsp_line)
    if not line then return nil end
    -- Extract text up to and including the trigger position.
    -- lsp_char is 0-indexed; Lua sub is 1-indexed.
    local prefix = line:sub(1, lsp_char)
    -- Strip trailing trigger character if present.
    if prefix:sub(-1) == trigger then prefix = prefix:sub(1, -2) end
    -- Match trailing simple identifier.
    local name_str = prefix:match("([%a_][%w_]*)$")
    if not name_str then return nil end
    -- Look up name in intern pool (read-only via pool.map).
    local name_id = ctx.pool.map[name_str]
    if not name_id then return nil end
    -- Search scope chain for type binding.
    local scope = ctx.scope
    local type_id
    while scope do
        if scope.bindings[name_id] then
            type_id = scope.bindings[name_id]
            break
        end
        scope = scope.parent
    end
    if not type_id then return nil end
    return table_field_items(ctx, type_id)
end

-- ---------------------------------------------------------------------------
-- Cross-file navigation helpers
-- ---------------------------------------------------------------------------

-- Resolve a Lua module name to a file:// URI.
-- Tries <root>/<mod/path>.lua then <root>/<mod/path>/init.lua.
-- Returns a URI string or nil if no file is found.
local function resolve_module_uri(root, mod_name)
    local rel = mod_name:gsub("%.", "/")
    local candidates = { rel .. ".lua", rel .. "/init.lua" }
    for _, p in ipairs(candidates) do
        local abs = root .. "/" .. p
        local f = io.open(abs, "r")
        if f then
            f:close()
            -- Percent-encode spaces; other chars left as-is for simplicity.
            local encoded = abs:gsub(" ", "%%20")
            return "file://" .. encoded
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Message handlers
-- ---------------------------------------------------------------------------

local HANDLERS = {}

HANDLERS["initialize"] = function(state, msg)
    state.initialized = true
    -- Capture workspace root for cross-file navigation.
    local p = msg.params or {}
    if p.rootUri then
        state.root_path = uri_to_path(p.rootUri)
    elseif p.rootPath then
        state.root_path = p.rootPath
    else
        state.root_path = "."
    end
    send(ok_resp(msg.id, {
        capabilities = {
            textDocumentSync = {
                openClose = true,
                change    = 1,    -- Full document sync
                save      = true,
            },
            hoverProvider      = true,
            definitionProvider = true,
            completionProvider  = { triggerCharacters = { ".", ":" } },
            signatureHelpProvider = { triggerCharacters = { "(", "," } },
        },
        serverInfo = { name = "crescent", version = "0.3.0" },
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

    -- Field completion: triggered by "." or ":" — enumerate the object's fields.
    local trigger = p.context and p.context.triggerCharacter
    local pos     = p.position
    if pos and (trigger == "." or trigger == ":") then
        local text = state.open_files[uri]
        if text then
            local items = field_completions(ctx, text, pos.line, pos.character, trigger)
            if items then
                send(ok_resp(msg.id, #items > 0 and items or EMPTY_ARRAY))
                return
            end
        end
    end

    -- Fallback: enumerate all names visible in the module-level scope chain.
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

HANDLERS["textDocument/signatureHelp"] = function(state, msg)
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
    local text = state.open_files[uri]
    if not text then
        send(ok_resp(msg.id, NULL))
        return
    end
    local sig, active_param = signature_at(ctx, text, ln, col)
    if not sig then
        send(ok_resp(msg.id, NULL))
        return
    end
    send(ok_resp(msg.id, {
        signatures      = { sig },
        activeSignature = 0,
        activeParameter = active_param or 0,
    }))
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

    local name_id, name_col   = name_at_lookup(ctx, ln, col)
    local field_id, obj_id, field_col = field_at_lookup(ctx, ln, col)

    -- Prefer field go-to-def when the field_at match has a higher (or equal) col than name_at.
    -- This handles `x.bar`: cursor on `bar` → field wins; cursor on `x` → name wins.
    if field_id and (not name_col or field_col >= name_col) then
        local field_str = intern.get(ctx.pool, field_id)
        local field_len = field_str and #field_str or 1

        -- Cross-file: obj is a required module — navigate into that module.
        if ctx.require_sources and ctx.require_sources[obj_id] then
            local mod_name = ctx.require_sources[obj_id]
            local root = state.root_path or "."
            local rel  = mod_name:gsub("%.", "/")
            for _, rel_path in ipairs({ rel .. ".lua", rel .. "/init.lua" }) do
                local abs_path = root .. "/" .. rel_path
                local f = io.open(abs_path, "r")
                if f then
                    f:close()
                    local _ec, mod_ctx = check.check_file(abs_path)
                    if mod_ctx then
                        local mod_fid = intern.intern(mod_ctx.pool, field_str)
                        local def = find_field_in_ctx(mod_ctx, nil, mod_fid)
                        if def then
                            local dl = math.max(0, def.line - 1)
                            local dc = math.max(0, def.col - 1)
                            local encoded = abs_path:gsub(" ", "%%20")
                            send(ok_resp(msg.id, {
                                uri   = "file://" .. encoded,
                                range = {
                                    start   = { line = dl, character = dc },
                                    ["end"] = { line = dl, character = dc + field_len },
                                },
                            }))
                            return
                        end
                    end
                    -- Module found but field not located — navigate to top of file.
                    local encoded = abs_path:gsub(" ", "%%20")
                    send(ok_resp(msg.id, {
                        uri   = "file://" .. encoded,
                        range = { start = { line = 0, character = 0 },
                                  ["end"] = { line = 0, character = 1 } },
                    }))
                    return
                end
            end
            send(ok_resp(msg.id, NULL))
            return
        end

        -- Same-file: scan AST for where obj.field was first defined.
        local def = find_field_in_ctx(ctx, obj_id, field_id)
        if def then
            local dl = math.max(0, def.line - 1)
            local dc = math.max(0, def.col - 1)
            send(ok_resp(msg.id, {
                uri   = uri,
                range = {
                    start   = { line = dl, character = dc },
                    ["end"] = { line = dl, character = dc + field_len },
                },
            }))
            return
        end
        send(ok_resp(msg.id, NULL))
        return
    end

    -- Name go-to-def path (variables, require() bindings).
    if not name_id then
        send(ok_resp(msg.id, NULL))
        return
    end
    -- Cross-file: if this name was bound from a require(), navigate to the module file.
    if ctx.require_sources and ctx.require_sources[name_id] then
        local mod_name = ctx.require_sources[name_id]
        local root = state.root_path or "."
        local mod_uri = resolve_module_uri(root, mod_name)
        if mod_uri then
            send(ok_resp(msg.id, {
                uri   = mod_uri,
                range = {
                    start   = { line = 0, character = 0 },
                    ["end"] = { line = 0, character = 1 },
                },
            }))
            return
        end
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
