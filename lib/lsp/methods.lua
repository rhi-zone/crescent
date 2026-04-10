-- lib/lsp/methods.lua
-- LSP method name constants.

local M = {}

-- Lifecycle
M.INITIALIZE           = "initialize"
M.INITIALIZED          = "initialized"
M.SHUTDOWN             = "shutdown"
M.EXIT                 = "exit"

-- Text synchronization
M.DID_OPEN             = "textDocument/didOpen"
M.DID_CLOSE            = "textDocument/didClose"
M.DID_CHANGE           = "textDocument/didChange"
M.DID_SAVE             = "textDocument/didSave"

-- Language features
M.HOVER                = "textDocument/hover"
M.COMPLETION           = "textDocument/completion"
M.DEFINITION           = "textDocument/definition"
M.REFERENCES           = "textDocument/references"
M.DOCUMENT_SYMBOL      = "textDocument/documentSymbol"
M.SIGNATURE_HELP       = "textDocument/signatureHelp"
M.FORMATTING           = "textDocument/formatting"
M.RENAME               = "textDocument/rename"
M.CODE_ACTION          = "textDocument/codeAction"
M.DIAGNOSTIC           = "textDocument/diagnostic"
M.PUBLISH_DIAGNOSTICS  = "textDocument/publishDiagnostics"

-- Window
M.LOG_MESSAGE          = "window/logMessage"
M.SHOW_MESSAGE         = "window/showMessage"

return M
