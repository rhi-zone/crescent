-- lib/api-tree/http_adapter_test.lua
-- Tests for lib/api-tree/http_adapter.lua (the one materialization boundary).
--
-- The property under test is that materialization happens ONCE, at the end,
-- and that everything before it is free of socket contact: a streaming
-- response's producer must still be un-started at the instant `materialize` is
-- called, and must then drive straight onto the socket.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T       = require("lib.test.assert")
local async   = require("lib.async")
local adapter = require("lib.api-tree.http_adapter")
local stream  = require("lib.api-tree.stream")
local value   = require("lib.api-tree.http_value")

-- A stand-in for an accepted client socket. Records every byte written and
-- whether it was closed, so a test can assert on the exact wire output. The
-- member set mirrors lib/http/server.lua's `http_client_sock` because
-- `response_stream` is typed against that; the members this file does not
-- exercise are present to satisfy the shape, not because they do anything.
--:: FakeSock = { sent: { [integer]: string }, closed: boolean, receive: (self: FakeSock, unknown) -> string | nil, send: (self: FakeSock, string) -> unknown, close: (self: FakeSock) -> unknown, set_option: (self: FakeSock, string, unknown, string | nil) -> (boolean | nil, string | nil), fd: integer, on_send: unknown, on_receive: unknown, _loop: unknown }

--: () -> FakeSock
local function fake_sock()
  --: FakeSock
  local sock = {
    sent = {}, closed = false, fd = 0,
    on_send = nil, on_receive = nil, _loop = nil,
    --: (self: FakeSock, unknown) -> string | nil
    receive = function(self, _) return nil end,
    --: (self: FakeSock, string) -> unknown
    send = function(self, data)
      self.sent[#self.sent + 1] = data
      return #data
    end,
    --: (self: FakeSock) -> unknown
    close = function(self)
      self.closed = true
      return true
    end,
    --: (self: FakeSock, string, unknown, string | nil) -> (boolean | nil, string | nil)
    set_option = function(self, _, _, _) return true end,
  }
  return sock
end

-- A fresh mutable `res`, exactly as lib/http/server.lua's connection core
-- hands one to a handler.
--:: FakeRes = { status: integer, reason: string, version: string, headers: { [string]: string[] }, body: string | nil, raw: boolean | nil, keep_alive: boolean | nil }

--: () -> FakeRes
local function fake_res()
  return {
    status = 200, reason = "", version = "HTTP/1.1",
    headers = {}, body = nil, raw = nil, keep_alive = nil,
  }
end

--: (sock: FakeSock) -> string
local function wire(sock)
  return table.concat(sock.sent)
end

T.describe("lib.api-tree.http_adapter", function()

  T.describe("materialize — plain", function()

    T.it("copies status, reason, headers, and body onto res", function()
      local res = fake_res()
      local rv = value.response("hello", {
        status = 201,
        headers = value.headers_from_map({ ["content-type"] = "text/plain" }),
      })
      adapter.materialize(rv, res, fake_sock())
      T.eq(res.status, 201)
      T.eq(res.reason, "Created")
      T.eq(res.body, "hello")
      T.eq(res.headers["content-type"][1], "text/plain")
    end)

    T.it("never touches the socket", function()
      local sock = fake_sock()
      adapter.materialize(value.response("x"), fake_res(), sock)
      T.eq(#sock.sent, 0)
      T.eq(sock.closed, false)
    end)

    T.it("leaves res unmarked as raw, so the core serializes it", function()
      local res = fake_res()
      adapter.materialize(value.response("x"), res, fake_sock())
      T.eq(res.raw, nil)
    end)

    T.it("carries a nil body through as nil, not an empty string", function()
      local res = fake_res()
      adapter.materialize(value.response(nil, { status = 204 }), res, fake_sock())
      T.eq(res.body, nil)
      T.eq(res.status, 204)
    end)

    T.it("carries repeated header fields without flattening", function()
      local res = fake_res()
      local h = value.append_header({}, "set-cookie", "a=1")
      h = value.append_header(h, "set-cookie", "b=2")
      adapter.materialize(value.response("x", { headers = h }), res, fake_sock())
      T.eq(#res.headers["set-cookie"], 2)
      T.eq(res.headers["set-cookie"][2], "b=2")
    end)

    T.it("does not alias the value's header arrays into res", function()
      local rv = value.response("x", { headers = value.headers_from_map({ a = "1" }) })
      local res = fake_res()
      adapter.materialize(rv, res, fake_sock())
      res.headers["a"][1] = "mutated-by-the-core"
      T.eq(value.get_header(rv.headers, "a"), "1")
    end)

    T.it("rejects a value that is not a response value", function()
      T.eq(pcall(adapter.materialize, { status = 200 }, fake_res(), fake_sock()), false)
    end)

  end)

  T.describe("materialize — streaming", function()

    T.it("does not start the producer until materialize is called", function()
      local counter = { n = 0 } --: { n: integer }
      local rv = value.stream_response(stream.from(function(emit)
        counter.n = counter.n + 1
        return nil
      end))
      -- Wrapped repeatedly, as a layer stack would: still nothing running.
      local wrapped = value.rebuild(rv, { headers = value.set_header(rv.headers, "x", "1") })
      T.eq(counter.n, 0)
      async.run(adapter.materialize(wrapped, fake_res(), fake_sock()))
      T.eq(counter.n, 1)
    end)

    T.it("sends the head, then each chunk, then closes", function()
      local sock = fake_sock()
      local res = fake_res()
      local rv = value.stream_response(stream.from(function(emit)
        async.await(emit("one"))
        async.await(emit("two"))
        return nil
      end), {
        status = 200,
        headers = value.headers_from_map({ ["content-type"] = "text/event-stream" }),
      })
      async.run(adapter.materialize(rv, res, sock))
      local out = wire(sock)
      T.eq(out:find("HTTP/1.1 200 OK", 1, true), 1)
      T.eq(out:find("content-type: text/event-stream", 1, true) ~= nil, true)
      -- The head goes out before the body, and the chunks in emission order.
      local head_end = out:find("\r\n\r\n", 1, true)
      T.eq(out:sub(head_end + 4), "onetwo")
      T.eq(sock.closed, true)
    end)

    T.it("marks res raw so the connection core neither serializes nor closes", function()
      local res = fake_res()
      async.run(adapter.materialize(
        value.stream_response(stream.from(function(_) return nil end)),
        res, fake_sock()))
      T.eq(res.raw, true)
    end)

    T.it("synthesizes no content-length for a streamed body", function()
      local sock = fake_sock()
      async.run(adapter.materialize(
        value.stream_response(stream.from(function(emit)
          async.await(emit("abc"))
          return nil
        end)),
        fake_res(), sock))
      T.eq(wire(sock):lower():find("content-length", 1, true), nil)
    end)

    T.it("carries a status set by an outer layer onto the streamed head", function()
      local sock = fake_sock()
      local rv = value.stream_response(stream.from(function(_) return nil end))
      -- An outer layer re-statuses the streaming response — the whole point of
      -- the deferred model. Materialization must honour the LATEST value.
      local out = value.rebuild(rv, { status = 503 })
      async.run(adapter.materialize(out, fake_res(), sock))
      T.eq(wire(sock):find("HTTP/1.1 503", 1, true), 1)
    end)

    T.it("closes the socket even when the producer emits nothing", function()
      local sock = fake_sock()
      async.run(adapter.materialize(
        value.stream_response(stream.from(function(_) return nil end)),
        fake_res(), sock))
      T.eq(sock.closed, true)
    end)

    T.it("rejects a non-string emission rather than putting it on the wire", function()
      local sock = fake_sock()
      local rv = value.stream_response(stream.from(function(emit)
        async.await(emit({ not_a = "string" }))
        return nil
      end))
      local _, err = async.run(adapter.materialize(rv, fake_res(), sock))
      T.eq(type(err) == "string" and err:find("already-framed", 1, true) ~= nil, true)
    end)

  end)

  T.describe("handler_from_fetch", function()

    T.it("converts the request and materializes the response", function()
      local seen = { path = "", tags = 0 } --: { path: string, tags: integer }
      local handler = adapter.handler_from_fetch(function(req)
        local r = req --[[: { path: string, query: { [string]: string[] } }]]
        seen.path = r.path
        local tags = r.query["tag"]
        seen.tags = tags ~= nil and #tags or 0
        return value.response("ok")
      end)
      local res = fake_res()
      handler({
        method = "GET", target = "/a/b?tag=x&tag=y", version = "HTTP/1.1",
        headers = {}, body = nil, scheme = "http", host = "h", port = 80,
      }, res, fake_sock())
      T.eq(seen.path, "/a/b")
      T.eq(seen.tags, 2)
      T.eq(res.body, "ok")
    end)

    T.it("turns a raising fetch function into a 500 rather than dropping the connection", function()
      local handler = adapter.handler_from_fetch(function(_) error("boom") end)
      local res = fake_res()
      handler({
        method = "GET", target = "/", version = "HTTP/1.1",
        headers = {}, body = nil, scheme = "http", host = "h", port = 80,
      }, res, fake_sock())
      T.eq(res.status, 500)
      T.eq(res.body, nil)
    end)

    T.it("turns a non-response return into a 500", function()
      local handler = adapter.handler_from_fetch(function(_) return { not_a = "response" } end)
      local res = fake_res()
      handler({
        method = "GET", target = "/", version = "HTTP/1.1",
        headers = {}, body = nil, scheme = "http", host = "h", port = 80,
      }, res, fake_sock())
      T.eq(res.status, 500)
    end)

    T.it("awaits a fetch function that returns a promise", function()
      local fetch = async.async(function(_)
        return value.response("async-body")
      end)
      local handler = adapter.handler_from_fetch(fetch)
      local res = fake_res()
      handler({
        method = "GET", target = "/", version = "HTTP/1.1",
        headers = {}, body = nil, scheme = "http", host = "h", port = 80,
      }, res, fake_sock())
      T.eq(res.body, "async-body")
    end)

  end)

end)
