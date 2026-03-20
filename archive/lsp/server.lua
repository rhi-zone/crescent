local lsp_format = require("lib.lsp.format")

local mod = {}

--[[@param handler fun(msg: lsp_request_message, headers: table<string, string>, stop: fun(): nil): lsp_response_message?]]
--[[@param epoll? table]]
mod.server = function(handler, epoll)
  local running = true
  local function stop() running = false end
  local function handle_message(msg)
    local lsp_msg, headers = lsp_format.string_to_lsp_message(msg)
    if not lsp_msg or type(headers) == "string" then
      io.stderr:write("error parsing LSP message: ", headers, "\n")
      return
    end
    ---@diagnostic disable-next-line: param-type-mismatch
    local response = handler(lsp_msg, headers, stop)
    if response then
      io.stdout:write(lsp_format.lsp_message_to_string(response))
      io.stdout:flush()
    else
      io.stderr:write("error handling LSP message: no response returned\n")
    end
  end
  if epoll then
    epoll:add(io.stdin, function()
      local line = io.stdin:read("*l")
      if not line then
        running = false; return
      end
      local msg = line
      while not msg:find("\r\n\r\n") do
        local next_line = io.stdin:read("*l")
        if not next_line then
          running = false; return
        end
        msg = msg .. "\n" .. next_line
      end
      local headers = msg:match("(.-)\r\n\r\n")
      local content_length = headers and headers:match("Content%-Length:%s*(%d+)")
      if content_length then
        local len = tonumber(content_length)
        if len then
          local body = io.stdin:read(math.floor(len))
          msg = msg .. body
        end
      end
      handle_message(msg)
    end)
    while running do
      epoll:wait()
    end
  else
    while running do
      local line = io.stdin:read("*l")
      if not line then break end
      local msg = line
      while not msg:find("\r\n\r\n") do
        local next_line = io.stdin:read("*l")
        if not next_line then break end
        msg = msg .. "\n" .. next_line
      end
      local headers = msg:match("(.-)\r\n\r\n")
      local content_length = headers and headers:match("Content%-Length:%s*(%d+)")
      if content_length then
        local len = tonumber(content_length)
        if len then
          local body = io.stdin:read(math.floor(len))
          msg = msg .. body
        end
      end
      handle_message(msg)
    end
  end
end

return mod
