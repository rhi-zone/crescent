#!/usr/bin/env luajit
local arg = arg --[[@type unknown[] ]]
if pcall(debug.getlocal, 4, 1) then
  arg = { ... }
else
  package.path = arg[0]:gsub("lua/.+$", "lua/?.lua", 1) .. ";" .. package.path
end

local lsp = require("lib.lsp.server")

lsp.server(function(request, headers, stop)
  if not request then return end
  if request.method == "initialize" then
    return {
      jsonrpc = "2.0",
      id = request.id,
      --[[@type lsp_initialize_result]]
      result = {
        capabilities = {},
      },
    }
  elseif request.method == "shutdown" then
    stop()
    return {
      jsonrpc = "2.0",
      id = request.id,
      result = nil,
    }
  elseif request.method == "exit" then
    stop()
  else
    if request.id then
      return {
        jsonrpc = "2.0",
        id = request.id,
        result = nil,
      }
    end
  end
end)
