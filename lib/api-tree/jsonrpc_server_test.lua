-- lib/api-tree/jsonrpc_server_test.lua
-- Tests for lib/api-tree/jsonrpc_server.lua — the dispatch core and both
-- transports.
--
-- The dispatch core here is a REIMPLEMENTATION of what lib/jsonrpc otherwise
-- owns (batching, the notification/request distinction, standard-code error
-- framing) — see that module's doc for why it could not be routed through
-- lib/jsonrpc. So these tests are written against the JSON-RPC 2.0
-- specification itself, including the worked examples in §7, rather than
-- against lib/jsonrpc's test shapes: spec divergence is the risk this
-- structure accepts, so spec conformance is what is pinned here.
--
-- Every handler in this file is synchronous, so each dispatch promise settles
-- before the call that made it returns and no event loop is needed — the same
-- property direct_test.lua and stream_test.lua rely on.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T       = require("lib.test.assert")
local async   = require("lib.async")
local json    = require("lib.format.json")
local api_tree = require("lib.api-tree")
local result  = require("lib.api-tree.result")
local stream  = require("lib.api-tree.stream")
local wire    = require("lib.api-tree.jsonrpc_wire")
local server  = require("lib.api-tree.jsonrpc_server")

--:: require "lib.http.server"
--:: require "lib.http.server_ws"

--: (v: unknown) -> v is { [string]: unknown }
local function as_record(v)
  return type(v) == "table"
end

--: (v: unknown) -> v is { [integer]: unknown }
local function as_list(v)
  return type(v) == "table"
end

--: (v: unknown) -> { [string]: unknown }
local function record(v)
  if not as_record(v) then error("expected a record, got " .. type(v)) end
  return v
end

--: (v: unknown) -> { [integer]: unknown }
local function list(v)
  if not as_list(v) then error("expected a list, got " .. type(v)) end
  return v
end

-- ── HTTP harness ─────────────────────────────────────────────────────────

-- The socket is never touched by this handler (it neither streams nor
-- upgrades), but the contract passes one, so the mock carries exactly the
-- members http_client_sock declares.
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

-- POST one raw body at a handler and hand back the response it filled in.
--: (handler: HttpHandlerFn, body: string | nil) -> http_server_response
local function post(handler, body)
  local res = blank_response()
  handler(http_request(body), res, mock_sock())
  return res
end

-- The decoded JSON body of a response.
--: (res: http_server_response) -> unknown
local function body_of(res)
  local body = res.body
  if body == nil then error("response carries no body") end
  return json.decode(body)
end

-- ── WebSocket harness ────────────────────────────────────────────────────

--:: SentLog = { [integer]: string }

-- A connection that replays `messages` and records everything written. Once
-- the script is exhausted `recv` reports a closed peer, which is what ends the
-- message pump.
--: (messages: { [integer]: string }) -> (WsConn, SentLog)
local function fake_ws(messages)
  local i = 0
  local sent = {} --: SentLog
  local conn = {
    --: (self: WsConn) -> (WsMessage | nil, string | nil)
    recv = function(_self)
      i = i + 1
      local m = messages[i]
      if m == nil then return nil, "closed" end
      return { type = "text", payload = m }, nil
    end,
    --: (self: WsConn, string, string | nil) -> (boolean | nil, string | nil)
    send = function(_self, data, _msg_type)
      sent[#sent + 1] = data
      return true
    end,
    --: (self: WsConn, integer | nil, string | nil) -> nil
    close = function(_self, _code, _reason) return nil end,
  }
  return conn, sent
end

-- Run the pump over a scripted conversation and return everything it wrote,
-- decoded.
--: (handler: WsHandlerFn, messages: { [integer]: string }) -> { [integer]: unknown }
local function ws_exchange(handler, messages)
  local conn, sent = fake_ws(messages)
  handler(conn, http_request(nil))
  local out = {} --: { [integer]: unknown }
  for i = 1, #sent do out[i] = json.decode(sent[i]) end
  return out
end

-- ── The tree under test ──────────────────────────────────────────────────

--: () -> unknown
local function build_tree()
  return api_tree.api({
    -- Echoes its whole input bag, so tests can see exactly what `assemble`
    -- produced from `params`.
    echo = api_tree.op(function(input) return input end),
    add = api_tree.op(function(input)
      local i = record(input)
      local a = i.a
      local b = i.b
      if type(a) ~= "number" or type(b) ~= "number" then return result.err({ kind = "badParams" }) end
      return a + b
    end),
    boom = api_tree.op(function(_input) error("handler exploded") end),
    nothing = api_tree.op(function(_input) return nil end),
    failing = api_tree.op(function(_input) return result.err({ kind = "notFound", message = "no such book" }) end),
    wrapped = api_tree.op(function(_input) return result.ok("unwrapped") end),
    counted = api_tree.op(function(_input)
      return stream.from(function(emit)
        async.await(emit({ kind = "chunk", data = "a" }))
        async.await(emit({ kind = "progress", progress = 1, total = 2, message = "half" }))
        async.await(emit({ kind = "chunk", data = "b" }))
        return "finished"
      end)
    end),
    streamed_error = api_tree.op(function(_input)
      return stream.from(function(emit)
        async.await(emit({ kind = "chunk", data = "partial" }))
        return result.err({ kind = "notFound" })
      end)
    end),
  }, nil)
end

T.describe("lib.api-tree.jsonrpc_server", function()

  T.describe("error_encoder_from_codes", function()

    T.it("maps a matching error kind to its code", function()
      local encode = server.error_encoder_from_codes({ notFound = -32001 })
      local encoded = encode({ kind = "notFound", message = "gone" })
      if encoded == nil then error("expected an encoded error") end
      T.eq(encoded.code, -32001)
      T.eq(encoded.message, "gone")
    end)

    T.it("carries the full error value as data", function()
      local encode = server.error_encoder_from_codes({ notFound = -32001 })
      local encoded = encode({ kind = "notFound", detail = "book 7" })
      if encoded == nil then error("expected an encoded error") end
      local data = record(encoded.data)
      T.eq(data.detail, "book 7")
    end)

    T.it("degrades the message to the JSON dump when there is no message field", function()
      local encode = server.error_encoder_from_codes({ notFound = -32001 })
      local encoded = encode({ kind = "notFound" })
      if encoded == nil then error("expected an encoded error") end
      T.ok(encoded.message:find("notFound", 1, true) ~= nil, "message must still identify the error")
    end)

    T.it("returns nil for an unrecognized error", function()
      local encode = server.error_encoder_from_codes({ notFound = -32001 })
      T.eq(encode({ kind = "somethingElse" }), nil)
      T.eq(encode("not even a record"), nil)
    end)
  end)

  T.describe("HTTP transport — single calls", function()

    T.it("answers a by-name call with a success Response (§5)", function()
      local handler = server.http_handler_from_tree(build_tree(), nil)
      local res = post(handler, '{"jsonrpc":"2.0","method":"add","params":{"a":19,"b":23},"id":1}')
      T.eq(res.status, 200)
      local out = record(body_of(res))
      T.eq(out.jsonrpc, "2.0")
      T.eq(out.result, 42)
      T.eq(out.id, 1)
    end)

    T.it("echoes the id verbatim, including a string id (§4)", function()
      local handler = server.http_handler_from_tree(build_tree(), nil)
      local out = record(body_of(post(handler, '{"jsonrpc":"2.0","method":"nothing","id":"abc-1"}')))
      T.eq(out.id, "abc-1")
    end)

    T.it("carries a null result rather than omitting the member (§5)", function()
      local handler = server.http_handler_from_tree(build_tree(), nil)
      local res = post(handler, '{"jsonrpc":"2.0","method":"nothing","id":1}')
      local body = res.body
      if body == nil then error("expected a body") end
      T.ok(body:find('"result":null', 1, true) ~= nil, "a void method still carries a result member")
    end)

    T.it("answers an id that was explicitly null as an ordinary request", function()
      -- `"id": null` is a Request (§4 discourages it but does not forbid it),
      -- NOT a Notification; only an ABSENT id is a Notification.
      local handler = server.http_handler_from_tree(build_tree(), nil)
      local res = post(handler, '{"jsonrpc":"2.0","method":"nothing","id":null}')
      T.eq(res.status, 200)
      local out = record(body_of(res))
      T.eq(out.id, wire.NULL)
    end)

    T.it("sets a JSON content type", function()
      local handler = server.http_handler_from_tree(build_tree(), nil)
      local res = post(handler, '{"jsonrpc":"2.0","method":"nothing","id":1}')
      local ct = res.headers["content-type"]
      if ct == nil then error("no content-type") end
      T.eq(ct[1], "application/json")
    end)
  end)

  T.describe("HTTP transport — params", function()

    T.it("assembles by-name params into the handler's input", function()
      local handler = server.http_handler_from_tree(build_tree(), nil)
      local out = record(body_of(post(handler, '{"jsonrpc":"2.0","method":"echo","params":{"x":1,"y":"z"},"id":1}')))
      local input = record(out.result)
      T.eq(input.x, 1)
      T.eq(input.y, "z")
    end)

    T.it("degrades positional params to an empty bag", function()
      -- §4 permits by-position params; this projector documents by-name as its
      -- contract, so a positional call reaches the handler with nothing rather
      -- than being guessed into names.
      local handler = server.http_handler_from_tree(build_tree(), nil)
      local out = record(body_of(post(handler, '{"jsonrpc":"2.0","method":"echo","params":[42,23],"id":1}')))
      T.eq(next(record(out.result)), nil)
    end)

    T.it("accepts a call with no params at all", function()
      local handler = server.http_handler_from_tree(build_tree(), nil)
      local out = record(body_of(post(handler, '{"jsonrpc":"2.0","method":"echo","id":1}')))
      T.eq(next(record(out.result)), nil)
    end)

    T.it("honours a leaf's sourceMap override", function()
      local tree = api_tree.api({
        whoami = api_tree.op(function(input) return record(input).who end,
          { jsonrpc = { sourceMap = { who = { store = "caller", key = "id" } } } }),
      }, nil)
      local handler = server.http_handler_from_tree(tree, nil)
      -- The `caller` store this projector builds is empty, so an override onto
      -- it resolves to nothing — what is pinned here is that the override is
      -- CONSULTED (the param does not fall through to `params`).
      local out = record(body_of(post(handler, '{"jsonrpc":"2.0","method":"whoami","params":{"who":"impostor"},"id":1}')))
      T.eq(out.result, wire.NULL)
    end)
  end)

  T.describe("HTTP transport — notifications (§4.1)", function()

    T.it("answers 204 with no body", function()
      local handler = server.http_handler_from_tree(build_tree(), nil)
      local res = post(handler, '{"jsonrpc":"2.0","method":"nothing"}')
      T.eq(res.status, 204)
      T.eq(res.body, nil)
    end)

    T.it("stays silent for an unknown method", function()
      local handler = server.http_handler_from_tree(build_tree(), nil)
      T.eq(post(handler, '{"jsonrpc":"2.0","method":"noSuchMethod"}').status, 204)
    end)

    T.it("stays silent when the handler raises", function()
      local handler = server.http_handler_from_tree(build_tree(), nil)
      T.eq(post(handler, '{"jsonrpc":"2.0","method":"boom"}').status, 204)
    end)

    T.it("stays silent when the handler returns an err Result", function()
      local handler = server.http_handler_from_tree(build_tree(), nil)
      T.eq(post(handler, '{"jsonrpc":"2.0","method":"failing"}').status, 204)
    end)

    T.it("still runs the handler", function()
      local seen = { count = 0 } --: { count: integer }
      local tree = api_tree.api({
        touch = api_tree.op(function(_input) seen["count"] = seen.count + 1; return nil end),
      }, nil)
      local handler = server.http_handler_from_tree(tree, nil)
      post(handler, '{"jsonrpc":"2.0","method":"touch"}')
      T.eq(seen.count, 1)
    end)
  end)

  T.describe("HTTP transport — framework errors", function()

    T.it("reports malformed JSON as Parse error (§4.2)", function()
      local handler = server.http_handler_from_tree(build_tree(), nil)
      local out = record(body_of(post(handler, '{"jsonrpc":"2.0","method":')))
      local err = record(out.error)
      T.eq(err.code, -32700)
      T.eq(err.message, "Parse error")
      T.eq(out.id, wire.NULL)
    end)

    T.it("reports an absent body as Parse error", function()
      local handler = server.http_handler_from_tree(build_tree(), nil)
      T.eq(record(record(body_of(post(handler, nil))).error).code, -32700)
    end)

    T.it("reports a non-Request object as Invalid Request (§4.2)", function()
      local handler = server.http_handler_from_tree(build_tree(), nil)
      local out = record(body_of(post(handler, '{"jsonrpc":"2.0","method":1,"params":"bar"}')))
      local err = record(out.error)
      T.eq(err.code, -32600)
      T.eq(err.message, "Invalid Request")
      T.eq(out.id, wire.NULL)
    end)

    T.it("reports a wrong protocol version as Invalid Request", function()
      local handler = server.http_handler_from_tree(build_tree(), nil)
      T.eq(record(record(body_of(post(handler, '{"jsonrpc":"1.0","method":"echo","id":1}'))).error).code, -32600)
    end)

    T.it("correlates an Invalid Request to the id the sender did send", function()
      local handler = server.http_handler_from_tree(build_tree(), nil)
      local out = record(body_of(post(handler, '{"jsonrpc":"2.0","id":9}')))
      T.eq(record(out.error).code, -32600)
      T.eq(out.id, 9)
    end)

    T.it("reports an unknown method as Method not found (§5.1)", function()
      local handler = server.http_handler_from_tree(build_tree(), nil)
      local out = record(body_of(post(handler, '{"jsonrpc":"2.0","method":"noSuchMethod","id":1}')))
      local err = record(out.error)
      T.eq(err.code, -32601)
      T.ok(tostring(err.message):find("noSuchMethod", 1, true) ~= nil, "names the method that was missing")
      T.eq(out.id, 1)
    end)

    T.it("collapses a raised handler error to Internal error, verbatim to nobody", function()
      local handler = server.http_handler_from_tree(build_tree(), nil)
      local out = record(body_of(post(handler, '{"jsonrpc":"2.0","method":"boom","id":1}')))
      local err = record(out.error)
      T.eq(err.code, -32603)
      T.eq(err.message, "Internal error")
      T.eq(err.data, nil, "a raised error must not leak its text to the client")
      T.eq(out.id, 1)
    end)
  end)

  T.describe("HTTP transport — handler err Results", function()

    T.it("falls back to Invalid params carrying the raw error", function()
      local handler = server.http_handler_from_tree(build_tree(), nil)
      local out = record(body_of(post(handler, '{"jsonrpc":"2.0","method":"failing","id":1}')))
      local err = record(out.error)
      T.eq(err.code, -32602)
      T.eq(err.message, "Invalid params")
      T.eq(record(err.data).kind, "notFound")
    end)

    T.it("uses the supplied encoder's code and message", function()
      local handler = server.http_handler_from_tree(build_tree(), {
        error_encoder = server.error_encoder_from_codes({ notFound = -32001 }),
      })
      local out = record(body_of(post(handler, '{"jsonrpc":"2.0","method":"failing","id":1}')))
      local err = record(out.error)
      T.eq(err.code, -32001)
      T.eq(err.message, "no such book")
      T.eq(record(err.data).kind, "notFound")
    end)

    T.it("falls back when the encoder does not recognize the error", function()
      local handler = server.http_handler_from_tree(build_tree(), {
        error_encoder = server.error_encoder_from_codes({ somethingElse = -32001 }),
      })
      T.eq(record(record(body_of(post(handler, '{"jsonrpc":"2.0","method":"failing","id":1}'))).error).code, -32602)
    end)

    T.it("unwraps an ok Result into the result member", function()
      local handler = server.http_handler_from_tree(build_tree(), nil)
      T.eq(record(body_of(post(handler, '{"jsonrpc":"2.0","method":"wrapped","id":1}'))).result, "unwrapped")
    end)

    T.it("leaves the Result wrapper alone when detection is off", function()
      local handler = server.http_handler_from_tree(build_tree(), { detection = { result = false, streaming = nil } })
      local out = record(body_of(post(handler, '{"jsonrpc":"2.0","method":"wrapped","id":1}')))
      local wrapped = record(out.result)
      T.eq(wrapped.kind, "ok")
      T.eq(wrapped.value, "unwrapped")
    end)
  end)

  T.describe("HTTP transport — batches (§6)", function()

    T.it("answers each request in the batch", function()
      local handler = server.http_handler_from_tree(build_tree(), nil)
      local out = list(body_of(post(handler,
        '[{"jsonrpc":"2.0","method":"add","params":{"a":1,"b":2},"id":1},'
        .. '{"jsonrpc":"2.0","method":"add","params":{"a":10,"b":20},"id":2}]')))
      T.eq(#out, 2)
      T.eq(record(out[1]).result, 3)
      T.eq(record(out[1]).id, 1)
      T.eq(record(out[2]).result, 30)
      T.eq(record(out[2]).id, 2)
    end)

    T.it("omits responses for the batch's Notifications (§4.1)", function()
      local handler = server.http_handler_from_tree(build_tree(), nil)
      local out = list(body_of(post(handler,
        '[{"jsonrpc":"2.0","method":"nothing"},'
        .. '{"jsonrpc":"2.0","method":"add","params":{"a":1,"b":1},"id":7},'
        .. '{"jsonrpc":"2.0","method":"nothing"}]')))
      T.eq(#out, 1)
      T.eq(record(out[1]).id, 7)
    end)

    T.it("sends nothing at all when every element was a Notification", function()
      local handler = server.http_handler_from_tree(build_tree(), nil)
      local res = post(handler, '[{"jsonrpc":"2.0","method":"nothing"},{"jsonrpc":"2.0","method":"nothing"}]')
      T.eq(res.status, 204, "§6 forbids returning an empty Array")
      T.eq(res.body, nil)
    end)

    T.it("answers an empty batch with ONE Invalid Request object", function()
      local handler = server.http_handler_from_tree(build_tree(), nil)
      local out = record(body_of(post(handler, "[]")))
      T.eq(record(out.error).code, -32600)
      T.eq(out.id, wire.NULL)
    end)

    T.it("reports a non-object batch element per element, not per batch", function()
      local handler = server.http_handler_from_tree(build_tree(), nil)
      local out = list(body_of(post(handler, "[1]")))
      T.eq(#out, 1)
      T.eq(record(out[1]).error ~= nil, true)
      T.eq(record(record(out[1]).error).code, -32600)
      T.eq(record(out[1]).id, wire.NULL)
    end)

    T.it("answers §7's [1,2,3] with three Invalid Request objects", function()
      local handler = server.http_handler_from_tree(build_tree(), nil)
      local out = list(body_of(post(handler, "[1,2,3]")))
      T.eq(#out, 3)
      for i = 1, 3 do
        T.eq(record(record(out[i]).error).code, -32600)
      end
    end)

    T.it("keeps going past a failing element", function()
      local handler = server.http_handler_from_tree(build_tree(), nil)
      local out = list(body_of(post(handler,
        '[{"jsonrpc":"2.0","method":"boom","id":1},'
        .. '{"jsonrpc":"2.0","method":"noSuchMethod","id":2},'
        .. '{"jsonrpc":"2.0","method":"add","params":{"a":2,"b":2},"id":3}]')))
      T.eq(#out, 3)
      T.eq(record(record(out[1]).error).code, -32603)
      T.eq(record(record(out[2]).error).code, -32601)
      T.eq(record(out[3]).result, 4)
    end)

    T.it("reports malformed batch JSON as a single Parse error (§4.2)", function()
      local handler = server.http_handler_from_tree(build_tree(), nil)
      local out = record(body_of(post(handler, '[{"jsonrpc":"2.0","method":"nothing"},{"jsonrpc":')))
      T.eq(record(out.error).code, -32700)
    end)
  end)

  T.describe("HTTP transport — streaming degrade", function()

    T.it("collects chunk payloads into the result array", function()
      local handler = server.http_handler_from_tree(build_tree(), nil)
      local out = record(body_of(post(handler, '{"jsonrpc":"2.0","method":"counted","id":1}')))
      local items = list(out.result)
      -- Chunks in order, then the stream's terminal value last. The progress
      -- effect is dropped: HTTP has no channel to deliver it on.
      T.eq(#items, 3)
      T.eq(items[1], "a")
      T.eq(items[2], "b")
      T.eq(items[3], "finished")
    end)

    T.it("does not unwrap a terminal err once it is inside the array", function()
      -- The drain IS the degrade: the terminal value is folded in as data, so
      -- there is no Result left at the top to detect.
      local handler = server.http_handler_from_tree(build_tree(), nil)
      local out = record(body_of(post(handler, '{"jsonrpc":"2.0","method":"streamed_error","id":1}')))
      T.eq(out.error, nil)
      local items = list(out.result)
      T.eq(items[1], "partial")
      T.eq(record(items[2]).kind, "err")
    end)
  end)

  T.describe("WebSocket transport", function()

    T.it("answers a request on the same connection", function()
      local handler = server.ws_handler_from_tree(build_tree(), nil)
      local out = ws_exchange(handler, { '{"jsonrpc":"2.0","method":"add","params":{"a":2,"b":3},"id":1}' })
      T.eq(#out, 1)
      T.eq(record(out[1]).result, 5)
      T.eq(record(out[1]).id, 1)
    end)

    T.it("writes nothing for a Notification", function()
      local handler = server.ws_handler_from_tree(build_tree(), nil)
      T.eq(#ws_exchange(handler, { '{"jsonrpc":"2.0","method":"nothing"}' }), 0)
    end)

    T.it("writes nothing for an all-Notification batch", function()
      local handler = server.ws_handler_from_tree(build_tree(), nil)
      T.eq(#ws_exchange(handler, { '[{"jsonrpc":"2.0","method":"nothing"}]' }), 0)
    end)

    T.it("reports malformed JSON as Parse error", function()
      local handler = server.ws_handler_from_tree(build_tree(), nil)
      local out = ws_exchange(handler, { "not json at all" })
      T.eq(#out, 1)
      T.eq(record(record(out[1]).error).code, -32700)
    end)

    T.it("serves several messages over one connection", function()
      local handler = server.ws_handler_from_tree(build_tree(), nil)
      local out = ws_exchange(handler, {
        '{"jsonrpc":"2.0","method":"add","params":{"a":1,"b":1},"id":1}',
        '{"jsonrpc":"2.0","method":"add","params":{"a":2,"b":2},"id":2}',
      })
      T.eq(#out, 2)
      T.eq(record(out[1]).id, 1)
      T.eq(record(out[2]).id, 2)
    end)
  end)

  T.describe("WebSocket transport — streaming", function()

    T.it("delivers emissions as Notifications correlated by subscription", function()
      local handler = server.ws_handler_from_tree(build_tree(), nil)
      local out = ws_exchange(handler, { '{"jsonrpc":"2.0","method":"counted","id":"sub-1"}' })
      -- chunk, progress, chunk, then the originating call's own Response.
      T.eq(#out, 4)

      local first = record(out[1])
      T.eq(first.jsonrpc, "2.0")
      T.eq(first.method, "counted", "the notification names the method that streamed")
      T.eq(first.id, nil, "a Notification carries no id (§4.1)")
      local first_params = record(first.params)
      T.eq(first_params.type, "chunk")
      T.eq(first_params.subscription, "sub-1", "correlates back to the originating call")
      T.eq(first_params.value, "a")

      local progress = record(record(out[2]).params)
      T.eq(progress.type, "progress")
      T.eq(progress.subscription, "sub-1")
      T.eq(progress.progress, 1)
      T.eq(progress.total, 2)
      T.eq(progress.message, "half")

      T.eq(record(record(out[3]).params).value, "b")
    end)

    T.it("still answers the original call with the stream's terminal value", function()
      local handler = server.ws_handler_from_tree(build_tree(), nil)
      local out = ws_exchange(handler, { '{"jsonrpc":"2.0","method":"counted","id":"sub-1"}' })
      local final = record(out[4])
      T.eq(final.id, "sub-1", "symmetric with a non-streaming call")
      T.eq(final.result, "finished")
    end)

    T.it("turns a terminal err into the call's error response", function()
      local handler = server.ws_handler_from_tree(build_tree(), nil)
      local out = ws_exchange(handler, { '{"jsonrpc":"2.0","method":"streamed_error","id":1}' })
      T.eq(#out, 2)
      T.eq(record(record(out[1]).params).value, "partial")
      T.eq(record(record(out[2]).error).code, -32602)
    end)

    T.it("defaults a progress effect with no total to a unit total", function()
      local tree = api_tree.api({
        vague = api_tree.op(function(_input)
          return stream.from(function(emit)
            async.await(emit({ kind = "progress", progress = 1 }))
            return nil
          end)
        end),
      }, nil)
      local out = ws_exchange(server.ws_handler_from_tree(tree, nil), { '{"jsonrpc":"2.0","method":"vague","id":1}' })
      T.eq(record(record(out[1]).params).total, 1)
    end)

    T.it("treats an untagged emission as a chunk", function()
      local tree = api_tree.api({
        bare = api_tree.op(function(_input)
          return stream.from(function(emit)
            async.await(emit("plain"))
            return nil
          end)
        end),
      }, nil)
      local out = ws_exchange(server.ws_handler_from_tree(tree, nil), { '{"jsonrpc":"2.0","method":"bare","id":1}' })
      local params = record(record(out[1]).params)
      T.eq(params.type, "chunk")
      T.eq(params.value, "plain")
    end)

    T.it("stamps a streaming Notification's subscription as null", function()
      -- A Notification has no id to correlate against, so the subscription is
      -- null and no final Response follows.
      local handler = server.ws_handler_from_tree(build_tree(), nil)
      local out = ws_exchange(handler, { '{"jsonrpc":"2.0","method":"counted"}' })
      T.eq(#out, 3, "the emissions still go out; the call itself is never answered")
      T.eq(record(record(out[1]).params).subscription, wire.NULL)
    end)
  end)
end)
