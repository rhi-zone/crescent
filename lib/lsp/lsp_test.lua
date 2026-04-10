-- lib/lsp/lsp_test.lua
-- Tests for lib/lsp LSP protocol method binding library.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T       = require("lib.test.assert")
local json    = require("lib.format.json")
local jsonrpc = require("lib.jsonrpc")
local lsp     = require("lib.lsp")

-- Helper: create a test server with table transport.
-- Returns server, msgs_in, msgs_out.
local function make_test_server()
    local msgs_in  = {}
    local msgs_out = {}
    local transport = jsonrpc.table_transport(msgs_in, msgs_out)
    local server = lsp.server({ transport = transport })
    return server, msgs_in, msgs_out
end

-- Helper: push a raw JSON-RPC message object into the input queue.
local function push(msgs_in, obj)
    msgs_in[#msgs_in + 1] = json.encode(obj)
end

-- Helper: decode the nth output message (1-indexed).
local function out(msgs_out, n)
    local raw = msgs_out[n]
    if not raw then return nil end
    return json.decode(raw)
end

-- ---------------------------------------------------------------------------
T.describe("initialize handshake", function()
    T.it("returns capabilities on initialize", function()
        local server, msgs_in, msgs_out = make_test_server()

        push(msgs_in, {
            jsonrpc = "2.0", id = 1, method = "initialize",
            params = { capabilities = {} },
        })
        server._dispatcher:step()

        local resp = out(msgs_out, 1)
        T.ok(resp ~= nil, "got response")
        T.eq(resp.id, 1)
        T.ok(resp.result ~= nil, "result present")
        T.ok(resp.result.capabilities ~= nil, "capabilities present")
    end)

    T.it("calls user on_initialize handler", function()
        local server, msgs_in, msgs_out = make_test_server()
        local called = false

        server:on_initialize(function(params)
            called = true
            return { capabilities = { hoverProvider = true }, serverInfo = { name = "test" } }
        end)

        push(msgs_in, {
            jsonrpc = "2.0", id = 1, method = "initialize",
            params = { capabilities = {} },
        })
        server._dispatcher:step()

        T.ok(called, "user handler was called")
        local resp = out(msgs_out, 1)
        T.eq(resp.result.serverInfo.name, "test")
        T.eq(resp.result.capabilities.hoverProvider, true)
    end)
end)

-- ---------------------------------------------------------------------------
T.describe("auto-capabilities", function()
    T.it("registers hoverProvider when on_hover is set", function()
        local server, msgs_in, msgs_out = make_test_server()
        server:on_hover(function(_params) return { contents = { kind = "plaintext", value = "hi" } } end)

        push(msgs_in, {
            jsonrpc = "2.0", id = 1, method = "initialize",
            params = { capabilities = {} },
        })
        server._dispatcher:step()

        local resp = out(msgs_out, 1)
        T.eq(resp.result.capabilities.hoverProvider, true)
    end)

    T.it("registers textDocumentSync when on_did_open is set", function()
        local server, msgs_in, msgs_out = make_test_server()
        server:on_did_open(function(_params) end)

        push(msgs_in, {
            jsonrpc = "2.0", id = 1, method = "initialize",
            params = { capabilities = {} },
        })
        server._dispatcher:step()

        local resp = out(msgs_out, 1)
        local sync = resp.result.capabilities.textDocumentSync
        T.ok(sync ~= nil, "textDocumentSync present")
        T.eq(sync.openClose, true)
        T.eq(sync.change, 1)
        T.eq(sync.save, true)
    end)

    T.it("registers multiple capabilities", function()
        local server, msgs_in, msgs_out = make_test_server()
        server:on_hover(function(_params) return {} end)
        server:on_completion(function(_params) return { items = {} } end)
        server:on_definition(function(_params) return {} end)
        server:on_did_open(function(_params) end)

        push(msgs_in, {
            jsonrpc = "2.0", id = 1, method = "initialize",
            params = { capabilities = {} },
        })
        server._dispatcher:step()

        local caps = out(msgs_out, 1).result.capabilities
        T.eq(caps.hoverProvider, true)
        T.ok(caps.completionProvider ~= nil, "completionProvider present")
        T.eq(caps.definitionProvider, true)
        T.ok(caps.textDocumentSync ~= nil, "textDocumentSync present")
    end)
end)

-- ---------------------------------------------------------------------------
T.describe("hover", function()
    T.it("dispatches hover request to handler", function()
        local server, msgs_in, msgs_out = make_test_server()
        server:on_hover(function(params)
            return { contents = { kind = "plaintext", value = "type: number" } }
        end)

        push(msgs_in, {
            jsonrpc = "2.0", id = 2, method = "textDocument/hover",
            params = { textDocument = { uri = "file:///test.lua" }, position = { line = 0, character = 5 } },
        })
        server._dispatcher:step()

        local resp = out(msgs_out, 1)
        T.eq(resp.id, 2)
        T.eq(resp.result.contents.value, "type: number")
    end)
end)

-- ---------------------------------------------------------------------------
T.describe("completion", function()
    T.it("dispatches completion request to handler", function()
        local server, msgs_in, msgs_out = make_test_server()
        server:on_completion(function(params)
            return { items = { { label = "foo" }, { label = "bar" } } }
        end)

        push(msgs_in, {
            jsonrpc = "2.0", id = 3, method = "textDocument/completion",
            params = { textDocument = { uri = "file:///test.lua" }, position = { line = 1, character = 3 } },
        })
        server._dispatcher:step()

        local resp = out(msgs_out, 1)
        T.eq(resp.id, 3)
        T.eq(#resp.result.items, 2)
        T.eq(resp.result.items[1].label, "foo")
    end)
end)

-- ---------------------------------------------------------------------------
T.describe("definition", function()
    T.it("dispatches definition request to handler", function()
        local server, msgs_in, msgs_out = make_test_server()
        server:on_definition(function(params)
            return { uri = "file:///test.lua", range = { start = { line = 10, character = 0 }, ["end"] = { line = 10, character = 5 } } }
        end)

        push(msgs_in, {
            jsonrpc = "2.0", id = 4, method = "textDocument/definition",
            params = { textDocument = { uri = "file:///test.lua" }, position = { line = 5, character = 3 } },
        })
        server._dispatcher:step()

        local resp = out(msgs_out, 1)
        T.eq(resp.id, 4)
        T.eq(resp.result.uri, "file:///test.lua")
    end)
end)

-- ---------------------------------------------------------------------------
T.describe("did-open notification", function()
    T.it("calls handler on textDocument/didOpen", function()
        local server, msgs_in, msgs_out = make_test_server()
        local received_uri = nil
        server:on_did_open(function(params)
            received_uri = params.textDocument.uri
        end)

        push(msgs_in, {
            jsonrpc = "2.0", method = "textDocument/didOpen",
            params = { textDocument = { uri = "file:///hello.lua", languageId = "lua", version = 1, text = "print('hi')" } },
        })
        server._dispatcher:step()

        T.eq(received_uri, "file:///hello.lua")
        T.eq(#msgs_out, 0, "no response for notification")
    end)
end)

-- ---------------------------------------------------------------------------
T.describe("did-change notification", function()
    T.it("calls handler on textDocument/didChange", function()
        local server, msgs_in, msgs_out = make_test_server()
        local called = false
        server:on_did_change(function(params)
            called = true
        end)

        push(msgs_in, {
            jsonrpc = "2.0", method = "textDocument/didChange",
            params = { textDocument = { uri = "file:///hello.lua", version = 2 }, contentChanges = { { text = "print('bye')" } } },
        })
        server._dispatcher:step()

        T.ok(called, "handler was called")
        T.eq(#msgs_out, 0, "no response for notification")
    end)
end)

-- ---------------------------------------------------------------------------
T.describe("shutdown", function()
    T.it("returns json.null on shutdown", function()
        local server, msgs_in, msgs_out = make_test_server()

        push(msgs_in, { jsonrpc = "2.0", id = 10, method = "shutdown" })
        server._dispatcher:step()

        local resp = out(msgs_out, 1)
        T.eq(resp.id, 10)
        -- json.null decodes back as json.null; the raw JSON should contain "null".
        local raw = msgs_out[1]
        T.ok(raw:find('"result":null', 1, true) ~= nil, "result is null")
    end)
end)

-- ---------------------------------------------------------------------------
T.describe("publish_diagnostics", function()
    T.it("sends textDocument/publishDiagnostics notification", function()
        local server, msgs_in, msgs_out = make_test_server()

        server:publish_diagnostics({
            uri = "file:///test.lua",
            diagnostics = { { range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 5 } }, message = "err", severity = 1 } },
        })

        T.eq(#msgs_out, 1, "one message sent")
        local msg = out(msgs_out, 1)
        T.eq(msg.method, "textDocument/publishDiagnostics")
        T.eq(msg.params.uri, "file:///test.lua")
        T.eq(#msg.params.diagnostics, 1)
        T.eq(msg.params.diagnostics[1].message, "err")
    end)
end)

-- ---------------------------------------------------------------------------
T.describe("log_message and show_message", function()
    T.it("log_message sends window/logMessage", function()
        local server, msgs_in, msgs_out = make_test_server()
        server:log_message(3, "info message")

        local msg = out(msgs_out, 1)
        T.eq(msg.method, "window/logMessage")
        T.eq(msg.params.type, 3)
        T.eq(msg.params.message, "info message")
    end)

    T.it("show_message sends window/showMessage", function()
        local server, msgs_in, msgs_out = make_test_server()
        server:show_message(1, "error!")

        local msg = out(msgs_out, 1)
        T.eq(msg.method, "window/showMessage")
        T.eq(msg.params.type, 1)
        T.eq(msg.params.message, "error!")
    end)
end)

-- ---------------------------------------------------------------------------
T.describe("unregistered method", function()
    T.it("returns method-not-found for unregistered request", function()
        local server, msgs_in, msgs_out = make_test_server()

        push(msgs_in, {
            jsonrpc = "2.0", id = 99, method = "textDocument/references",
            params = {},
        })
        server._dispatcher:step()

        local resp = out(msgs_out, 1)
        T.eq(resp.id, 99)
        T.ok(resp.error ~= nil, "error present")
        T.eq(resp.error.code, jsonrpc.ERR_NOT_FOUND)
    end)
end)

-- ---------------------------------------------------------------------------
T.describe("did-save notification", function()
    T.it("calls handler on textDocument/didSave", function()
        local server, msgs_in, msgs_out = make_test_server()
        local saved_uri = nil
        server:on_did_save(function(params)
            saved_uri = params.textDocument.uri
        end)

        push(msgs_in, {
            jsonrpc = "2.0", method = "textDocument/didSave",
            params = { textDocument = { uri = "file:///saved.lua" } },
        })
        server._dispatcher:step()

        T.eq(saved_uri, "file:///saved.lua")
    end)
end)

-- ---------------------------------------------------------------------------
T.describe("additional feature handlers", function()
    T.it("on_references dispatches correctly", function()
        local server, msgs_in, msgs_out = make_test_server()
        server:on_references(function(params)
            return { { uri = "file:///a.lua", range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 3 } } } }
        end)

        push(msgs_in, { jsonrpc = "2.0", id = 20, method = "textDocument/references", params = {} })
        server._dispatcher:step()

        local resp = out(msgs_out, 1)
        T.eq(resp.id, 20)
        T.eq(#resp.result, 1)
        T.eq(resp.result[1].uri, "file:///a.lua")
    end)

    T.it("on_document_symbol dispatches correctly", function()
        local server, msgs_in, msgs_out = make_test_server()
        server:on_document_symbol(function(params)
            return { { name = "foo", kind = 12, range = { start = { line = 0, character = 0 }, ["end"] = { line = 5, character = 0 } } } }
        end)

        push(msgs_in, { jsonrpc = "2.0", id = 21, method = "textDocument/documentSymbol", params = {} })
        server._dispatcher:step()

        local resp = out(msgs_out, 1)
        T.eq(resp.id, 21)
        T.eq(resp.result[1].name, "foo")
    end)

    T.it("on_rename dispatches correctly", function()
        local server, msgs_in, msgs_out = make_test_server()
        server:on_rename(function(params)
            return { changes = { ["file:///a.lua"] = { { range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 3 } }, newText = "bar" } } } }
        end)

        push(msgs_in, { jsonrpc = "2.0", id = 22, method = "textDocument/rename", params = { newName = "bar" } })
        server._dispatcher:step()

        local resp = out(msgs_out, 1)
        T.eq(resp.id, 22)
        T.ok(resp.result.changes ~= nil, "changes present")
    end)

    T.it("on_formatting dispatches correctly", function()
        local server, msgs_in, msgs_out = make_test_server()
        server:on_formatting(function(params)
            return { { range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 5 } }, newText = "fixed" } }
        end)

        push(msgs_in, { jsonrpc = "2.0", id = 23, method = "textDocument/formatting", params = {} })
        server._dispatcher:step()

        local resp = out(msgs_out, 1)
        T.eq(resp.id, 23)
        T.eq(#resp.result, 1)
        T.eq(resp.result[1].newText, "fixed")
    end)

    T.it("on_code_action dispatches correctly", function()
        local server, msgs_in, msgs_out = make_test_server()
        server:on_code_action(function(params)
            return { { title = "Fix it", kind = "quickfix" } }
        end)

        push(msgs_in, { jsonrpc = "2.0", id = 24, method = "textDocument/codeAction", params = {} })
        server._dispatcher:step()

        local resp = out(msgs_out, 1)
        T.eq(resp.id, 24)
        T.eq(resp.result[1].title, "Fix it")
    end)

    T.it("on_signature_help dispatches correctly", function()
        local server, msgs_in, msgs_out = make_test_server()
        server:on_signature_help(function(params)
            return { signatures = { { label = "foo(x: number)" } } }
        end)

        push(msgs_in, { jsonrpc = "2.0", id = 25, method = "textDocument/signatureHelp", params = {} })
        server._dispatcher:step()

        local resp = out(msgs_out, 1)
        T.eq(resp.id, 25)
        T.eq(resp.result.signatures[1].label, "foo(x: number)")
    end)

    T.it("on_diagnostic dispatches correctly", function()
        local server, msgs_in, msgs_out = make_test_server()
        server:on_diagnostic(function(params)
            return { kind = "full", items = {} }
        end)

        push(msgs_in, { jsonrpc = "2.0", id = 26, method = "textDocument/diagnostic", params = {} })
        server._dispatcher:step()

        local resp = out(msgs_out, 1)
        T.eq(resp.id, 26)
        T.eq(resp.result.kind, "full")
    end)
end)
