-- lib/fractal/jsonrpc_client_test.lua
-- Tests for lib/fractal/jsonrpc_client.lua (the tree-mirroring client).

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T       = require("lib.test.assert")
local async   = require("lib.async")
local json    = require("lib.format.json")
local fractal = require("lib.fractal")
local server  = require("lib.fractal.jsonrpc_server")
local client  = require("lib.fractal.jsonrpc_client")

--:: require "lib.http.server"

--:: PromiseView = { _state: string, ... }

--: (v: unknown) -> v is PromiseView
local function is_promise(v)
  if type(v) ~= "table" then return false end
  return v._state ~= nil
end

--: (v: unknown) -> v is { [string]: unknown }
local function as_record(v)
  return type(v) == "table"
end

--: (v: unknown) -> { [string]: unknown }
local function record(v)
  if not as_record(v) then error("expected a record, got " .. type(v)) end
  return v
end

--: (v: unknown) -> v is (input: unknown) -> unknown
local function as_callable(v)
  return type(v) == "function"
end

--: (v: unknown) -> (input: unknown) -> unknown
local function callable(v)
  if not as_callable(v) then error("expected a callable, got " .. type(v)) end
  return v
end

-- Drive a leaf call to a value. Every transport in this file is synchronous,
-- so the promise settles before the call returns.
--: (v: unknown, input: unknown) -> (unknown, unknown)
local function call(v, input)
  local p = callable(v)(input)
  if not is_promise(p) then error("a leaf call must return a promise") end
  return async.run(p)
end

--:: CallLog = { [integer]: { method: string, params: { [string]: unknown } } }

-- A `JsonRpcCall` that records what it was asked for and echoes it back.
--: (log: CallLog) -> (method: string, params: { [string]: unknown }) -> unknown
local function recording_call(log)
  --: (method: string, params: { [string]: unknown }) -> unknown
  local function do_call(method, params)
    log[#log + 1] = { method = method, params = params }
    return { method = method, params = params }
  end
  return do_call
end

--: (input: unknown) -> unknown
local function inert(_input)
  return nil
end

-- ── HTTP harness, for the round trip at the bottom ───────────────────────
--
-- The server handler neither streams nor upgrades, so the socket is never
-- touched; the mock carries exactly the members http_client_sock declares.

--: () -> http_client_sock
local function mock_sock()
  return {
    fd = 0,
    _loop = nil,
    on_send = nil,
    on_receive = nil,
    --: (self: http_client_sock, unknown) -> string | nil
    receive = function(_self, _buf) return nil end,
    --: (self: http_client_sock, string) -> unknown
    send = function(_self, d) return #d end,
    --: (self: http_client_sock) -> unknown
    close = function(_self) return true end,
    --: (self: http_client_sock, string, unknown, string | nil) -> (boolean | nil, string | nil)
    set_option = function(_self, _k, _v, _level) return true end,
  }
end

--: (body: string | nil) -> http_server_request
local function http_request(body)
  return {
    method = "POST",
    target = "/rpc",
    version = "HTTP/1.1",
    headers = {},
    body = body,
    scheme = "http",
    host = "localhost",
    port = 8080,
  }
end

--: () -> http_server_response
local function blank_response()
  return { status = 200, reason = "", version = "HTTP/1.1", headers = {}, body = nil, raw = nil, keep_alive = nil }
end

T.describe("lib.fractal.jsonrpc_client", function()

  T.describe("proxy shape", function()

    T.it("mirrors branches as nested tables and leaves as callables", function()
      local tree = fractal.api({
        users = fractal.api({ list = fractal.op(inert) }, nil),
      }, nil)
      local api = client.client_from_tree(tree, recording_call({}))
      local users = record(api.users)
      T.eq(type(users), "table")
      T.eq(type(users.list), "function")
    end)

    T.it("a leaf call returns a promise", function()
      local tree = fractal.api({ ping = fractal.op(inert) }, nil)
      local api = client.client_from_tree(tree, recording_call({}))
      T.eq(is_promise(callable(api.ping)(nil)), true)
    end)
  end)

  T.describe("name derivation", function()

    T.it("dot-joins tree position", function()
      local log = {} --: CallLog
      local tree = fractal.api({ users = fractal.api({ list = fractal.op(inert) }, nil) }, nil)
      local api = client.client_from_tree(tree, recording_call(log))
      call(record(api.users).list, nil)
      T.eq(log[1].method, "users.list")
    end)

    T.it("honours a leaf's meta.jsonrpc.name", function()
      local log = {} --: CallLog
      local tree = fractal.api({
        users = fractal.api({ list = fractal.op(inert, { jsonrpc = { name = "listUsers" } }) }, nil),
      }, nil)
      call(record(client.client_from_tree(tree, recording_call(log)).users).list, nil)
      T.eq(log[1].method, "listUsers")
    end)

    T.it("honours a branch's meta.jsonrpc.segment in the NAME but not the key", function()
      local log = {} --: CallLog
      local tree = fractal.api({
        users = fractal.api({ list = fractal.op(inert) }, { meta = { jsonrpc = { segment = "u" } } }),
      }, nil)
      local api = client.client_from_tree(tree, recording_call(log))
      -- Navigation stays on the tree key; only the derived method name shifts.
      call(record(api.users).list, nil)
      T.eq(log[1].method, "u.list")
    end)

    T.it("agrees with the server's dispatch table", function()
      -- The client and the projector derive names independently; this pins
      -- that they cannot drift.
      local tree = fractal.api({
        books = fractal.api({}, {
          fallback = { name = "bookId", subtree = fractal.api({ get = fractal.op(inert) }, nil) },
        }),
      }, nil)
      local log = {} --: CallLog
      local api = client.client_from_tree(tree, recording_call(log))
      local by_id = callable(record(api.books).bookId)("b-1")
      call(record(by_id).get, nil)

      local handlers = require("lib.fractal.jsonrpc_project").project_methods(tree, nil).handlers
      T.ok(handlers[log[1].method] ~= nil, "the client called a method the server dispatches")
    end)
  end)

  T.describe("fallback slug capture", function()

    T.it("merges the captured value into every call beneath it", function()
      local log = {} --: CallLog
      local tree = fractal.api({
        books = fractal.api({}, {
          fallback = { name = "bookId", subtree = fractal.api({ get = fractal.op(inert) }, nil) },
        }),
      }, nil)
      local api = client.client_from_tree(tree, recording_call(log))
      local by_id = callable(record(api.books).bookId)("b-1")
      call(record(by_id).get, nil)
      T.eq(log[1].method, "books.bookId.get")
      T.eq(log[1].params.bookId, "b-1")
    end)

    T.it("lets an explicit field win over a captured slug", function()
      local log = {} --: CallLog
      local tree = fractal.api({}, {
        fallback = { name = "id", subtree = fractal.api({ get = fractal.op(inert) }, nil) },
      })
      local api = client.client_from_tree(tree, recording_call(log))
      local by_id = callable(api.id)("captured")
      call(record(by_id).get, { id = "explicit" })
      T.eq(log[1].params.id, "explicit")
    end)

    T.it("returns the leaf's own caller when the subtree IS a leaf", function()
      local log = {} --: CallLog
      local tree = fractal.api({
        books = fractal.api({}, { fallback = { name = "bookId", subtree = fractal.op(inert) } }),
      }, nil)
      local api = client.client_from_tree(tree, recording_call(log))
      -- No extra property access beyond the fallback's own name.
      call(callable(record(api.books).bookId)("b-2"), nil)
      T.eq(log[1].method, "books.bookId")
      T.eq(log[1].params.bookId, "b-2")
    end)

    T.it("accumulates nested slugs", function()
      local log = {} --: CallLog
      local inner = fractal.api({}, {
        fallback = { name = "chapterId", subtree = fractal.api({ get = fractal.op(inert) }, nil) },
      })
      local tree = fractal.api({
        books = fractal.api({}, { fallback = { name = "bookId", subtree = inner } }),
      }, nil)
      local api = client.client_from_tree(tree, recording_call(log))
      local book = callable(record(api.books).bookId)("b-1")
      local chapter = callable(record(book).chapterId)("c-9")
      call(record(chapter).get, nil)
      T.eq(log[1].method, "books.bookId.chapterId.get")
      T.eq(log[1].params.bookId, "b-1")
      T.eq(log[1].params.chapterId, "c-9")
    end)
  end)

  T.describe("params", function()

    T.it("passes an empty bag when the caller supplies nothing", function()
      local log = {} --: CallLog
      local tree = fractal.api({ ping = fractal.op(inert) }, nil)
      call(client.client_from_tree(tree, recording_call(log)).ping, nil)
      T.eq(next(log[1].params), nil)
    end)

    T.it("rejects a non-record input — params are by-name only", function()
      local tree = fractal.api({ ping = fractal.op(inert) }, nil)
      local api = client.client_from_tree(tree, recording_call({}))
      local _v, err = call(api.ping, "positional")
      T.ok(err ~= nil, "expected a rejection")
      T.ok(tostring(err):find("by-name", 1, true) ~= nil, "the reason names the contract that was broken")
    end)
  end)

  T.describe("call_from_post", function()

    T.it("frames a Request object with jsonrpc/method/params/id", function()
      local seen = { body = "" } --: { body: string }
      --: (body: string) -> (string | nil, string | nil)
      local function post(body)
        seen["body"] = body
        return '{"jsonrpc":"2.0","result":"ok","id":1}', nil
      end
      local do_call = client.call_from_post(post, nil)
      local tree = fractal.api({ ping = fractal.op(inert) }, nil)
      call(client.client_from_tree(tree, do_call).ping, { x = 1 })

      local sent = record(json.decode(seen.body))
      T.eq(sent.jsonrpc, "2.0")
      T.eq(sent.method, "ping")
      T.eq(record(sent.params).x, 1)
      T.eq(sent.id, 1)
    end)

    T.it("resolves with the response's result", function()
      --: (body: string) -> (string | nil, string | nil)
      local function post(_body) return '{"jsonrpc":"2.0","result":42,"id":1}', nil end
      local tree = fractal.api({ ping = fractal.op(inert) }, nil)
      local v, err = call(client.client_from_tree(tree, client.call_from_post(post, nil)).ping, nil)
      T.eq(err, nil)
      T.eq(v, 42)
    end)

    T.it("increments the default id per call", function()
      local ids = {} --: { [integer]: unknown }
      --: (body: string) -> (string | nil, string | nil)
      local function post(body)
        ids[#ids + 1] = record(json.decode(body)).id
        return '{"jsonrpc":"2.0","result":null,"id":1}', nil
      end
      local tree = fractal.api({ ping = fractal.op(inert) }, nil)
      local api = client.client_from_tree(tree, client.call_from_post(post, nil))
      call(api.ping, nil)
      call(api.ping, nil)
      T.eq(ids[1], 1)
      T.eq(ids[2], 2)
    end)

    T.it("uses an injected id generator", function()
      local ids = {} --: { [integer]: unknown }
      --: (body: string) -> (string | nil, string | nil)
      local function post(body)
        ids[#ids + 1] = record(json.decode(body)).id
        return '{"jsonrpc":"2.0","result":null,"id":1}', nil
      end
      --: () -> unknown
      local function fixed_id() return "always" end
      local tree = fractal.api({ ping = fractal.op(inert) }, nil)
      call(client.client_from_tree(tree, client.call_from_post(post, { id = fixed_id })).ping, nil)
      T.eq(ids[1], "always")
    end)

    T.it("rejects with the error object on a JSON-RPC error response", function()
      --: (body: string) -> (string | nil, string | nil)
      local function post(_body)
        return '{"jsonrpc":"2.0","error":{"code":-32601,"message":"Method not found: ping"},"id":1}', nil
      end
      local tree = fractal.api({ ping = fractal.op(inert) }, nil)
      local v, err = call(client.client_from_tree(tree, client.call_from_post(post, nil)).ping, nil)
      T.eq(v, nil)
      local e = record(err)
      T.eq(e.code, -32601)
      T.eq(e.message, "Method not found: ping")
    end)

    T.it("rejects with the transport's own error, undressed", function()
      --: (body: string) -> (string | nil, string | nil)
      local function post(_body) return nil, "connection refused" end
      local tree = fractal.api({ ping = fractal.op(inert) }, nil)
      local v, err = call(client.client_from_tree(tree, client.call_from_post(post, nil)).ping, nil)
      T.eq(v, nil)
      T.ok(tostring(err):find("connection refused", 1, true) ~= nil,
        "a transport failure is not a JSON-RPC error and is not dressed as one")
    end)

    T.it("rejects when the response is not a Response object", function()
      --: (body: string) -> (string | nil, string | nil)
      local function post(_body) return "not json", nil end
      local tree = fractal.api({ ping = fractal.op(inert) }, nil)
      local v, err = call(client.client_from_tree(tree, client.call_from_post(post, nil)).ping, nil)
      T.eq(v, nil)
      T.ok(err ~= nil, "expected a rejection")
    end)
  end)

  T.describe("round trip against the HTTP server", function()

    T.it("calls a method end to end through both halves", function()
      local tree = fractal.api({
        math = fractal.api({
          add = fractal.op(function(input)
            local i = record(input)
            local a = i.a
            local b = i.b
            if type(a) ~= "number" or type(b) ~= "number" then error("bad params") end
            return a + b
          end),
        }, nil),
      }, nil)

      local handler = server.http_handler_from_tree(tree, nil)

      -- The injected transport: hand the body straight to the server handler
      -- and give back what it wrote. No socket in the loop.
      --: (body: string) -> (string | nil, string | nil)
      local function post(body)
        local res = blank_response()
        handler(http_request(body), res, mock_sock())
        return res.body, nil
      end

      local api = client.client_from_tree(tree, client.call_from_post(post, nil))
      local v, err = call(record(api.math).add, { a = 20, b = 22 })
      T.eq(err, nil)
      T.eq(v, 42)
    end)
  end)
end)
