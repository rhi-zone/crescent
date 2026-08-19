-- lib/api-tree/http_value_test.lua
-- Tests for lib/api-tree/http_value.lua (the HTTP request/response value model).
--
-- The load-bearing property under test throughout is LAZINESS: a streaming
-- response value must survive being rebuilt, re-headered, and re-statused any
-- number of times without its producer running. Several tests below assert on
-- a run counter that stays at zero for exactly that reason — see the module
-- doc in http_value.lua for why the whole layer stack depends on it.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T      = require("lib.test.assert")
local stream = require("lib.api-tree.stream")
local value  = require("lib.api-tree.http_value")

--: (v: unknown) -> v is { [string]: unknown }
local function as_record(v)
  return type(v) == "table"
end

-- Copy a multi-valued query bag, replacing one key with a single value —
-- exactly what `pageLinkHeader` does when it swaps the cursor and preserves
-- every other param. Written as a function rather than inline so the copy's
-- type comes from this annotation instead of being inferred from the literal
-- at its declaration site (an inferred literal type would then reject the
-- later key assignment).
--: (q: { [string]: string[] }, key: string, replacement: string) -> { [string]: string[] }
local function with_replaced(q, key, replacement)
  --: { [string]: { [integer]: string } }
  local out = {}
  for k, vs in pairs(q) do
    --: { [integer]: string }
    local copied = {}
    for i = 1, #vs do copied[i] = vs[i] end
    out[k] = copied
  end
  out[key] = { replacement }
  return out
end

-- A stream whose producer bumps `counter.n` the instant it starts. Every
-- laziness assertion in this file is "counter.n is still 0".
--: (counter: { n: integer }) -> unknown
local function counting_stream(counter)
  return stream.from(function(emit)
    counter.n = counter.n + 1
    return nil
  end)
end

T.describe("lib.api-tree.http_value", function()

  T.describe("headers", function()

    T.it("headers_from_map lowercases field names", function()
      local h = value.headers_from_map({ ["Content-Type"] = "text/plain" })
      T.eq(h["content-type"][1], "text/plain")
      T.eq(h["Content-Type"], nil)
    end)

    T.it("get_header reads the first value, case-insensitively", function()
      local h = value.headers_from_map({ Allow = "GET, POST" })
      T.eq(value.get_header(h, "allow"), "GET, POST")
      T.eq(value.get_header(h, "ALLOW"), "GET, POST")
      T.eq(value.get_header(h, "missing"), nil)
    end)

    T.it("get_header_all returns an empty table for an absent field", function()
      T.eq(#value.get_header_all({}, "vary"), 0)
    end)

    T.it("append_header keeps every value — no flattening", function()
      local h = value.append_header({}, "set-cookie", "a=1")
      h = value.append_header(h, "set-cookie", "b=2")
      local all = value.get_header_all(h, "set-cookie")
      T.eq(#all, 2)
      T.eq(all[1], "a=1")
      T.eq(all[2], "b=2")
      -- The single-value read still answers with the first, not a join.
      T.eq(value.get_header(h, "set-cookie"), "a=1")
    end)

    T.it("set_header replaces every existing value of the field", function()
      local h = value.append_header({}, "vary", "origin")
      h = value.append_header(h, "vary", "accept")
      h = value.set_header(h, "vary", "cookie")
      local all = value.get_header_all(h, "vary")
      T.eq(#all, 1)
      T.eq(all[1], "cookie")
    end)

    T.it("the header helpers never mutate their argument", function()
      local base = value.headers_from_map({ a = "1" })
      value.set_header(base, "a", "2")
      value.append_header(base, "a", "3")
      value.remove_header(base, "a")
      value.merge_headers(base, value.headers_from_map({ a = "4" }))
      local all = value.get_header_all(base, "a")
      T.eq(#all, 1)
      T.eq(all[1], "1")
    end)

    T.it("copy_headers copies the value arrays, not just the bag", function()
      local base = value.headers_from_map({ a = "1" })
      local copy = value.copy_headers(base)
      copy["a"][1] = "mutated"
      T.eq(value.get_header(base, "a"), "1")
    end)

    T.it("remove_header drops the field entirely", function()
      local h = value.headers_from_map({ a = "1", b = "2" })
      local out = value.remove_header(h, "A")
      T.eq(value.has_header(out, "a"), false)
      T.eq(value.has_header(out, "b"), true)
    end)

    T.it("merge_headers replaces per field rather than appending", function()
      local base = value.append_header({}, "vary", "origin")
      base = value.append_header(base, "x", "keep")
      local out = value.merge_headers(base, value.headers_from_map({ vary = "cookie" }))
      T.eq(#value.get_header_all(out, "vary"), 1)
      T.eq(value.get_header(out, "vary"), "cookie")
      T.eq(value.get_header(out, "x"), "keep")
    end)

  end)

  T.describe("constructing", function()

    T.it("response defaults to 200 with the standard reason phrase", function()
      local res = value.response("hi")
      T.eq(res.status, 200)
      T.eq(res.reason, "OK")
      T.eq(res.body.kind, "plain")
      T.eq(res.body.text, "hi")
    end)

    T.it("response derives the reason phrase from an explicit status", function()
      T.eq(value.response(nil, { status = 404 }).reason, "Not Found")
      T.eq(value.response(nil, { status = 204 }).reason, "No Content")
    end)

    T.it("an explicit reason wins over the derived phrase", function()
      T.eq(value.response(nil, { status = 404, reason = "Gone Fishing" }).reason, "Gone Fishing")
    end)

    T.it("a nil body is distinct from an empty one", function()
      T.eq(value.response(nil).body.text, nil)
      T.eq(value.response("").body.text, "")
    end)

    T.it("json_response serializes and supplies a content-type", function()
      local res = value.json_response({ a = 1 })
      if res == nil then error("json_response returned nil") end
      T.eq(value.get_header(res.headers, "content-type"), "application/json")
      T.eq(res.body.text, '{"a":1}')
    end)

    T.it("json_response does not clobber an explicit content-type", function()
      local res = value.json_response({ a = 1 }, {
        headers = value.headers_from_map({ ["content-type"] = "application/problem+json" }),
      })
      if res == nil then error("json_response returned nil") end
      T.eq(value.get_header(res.headers, "content-type"), "application/problem+json")
    end)

    T.it("stream_response rejects a non-Stream producer", function()
      local ok = pcall(value.stream_response, { kind = "stream" })
      T.eq(ok, false)
    end)

    T.it("stream_response does not start the producer", function()
      local counter = { n = 0 } --: { n: integer }
      local res = value.stream_response(counting_stream(counter))
      T.eq(res.body.kind, "stream")
      T.eq(counter.n, 0)
    end)

  end)

  T.describe("rebuild", function()

    T.it("carries the SAME body reference across", function()
      local res = value.response("body")
      local out = value.rebuild(res, { status = 201 })
      T.eq(out.body, res.body)
    end)

    T.it("re-derives the reason phrase when the status changes", function()
      local res = value.response(nil, { status = 200 })
      T.eq(value.rebuild(res, { status = 404 }).reason, "Not Found")
    end)

    T.it("keeps the reason phrase when the status does not change", function()
      local res = value.response(nil, { status = 200, reason = "Custom" })
      T.eq(value.rebuild(res, {}).reason, "Custom")
      T.eq(value.rebuild(res, { status = 200 }).reason, "Custom")
    end)

    T.it("an explicit reason wins even when the status changes", function()
      local res = value.response(nil, { status = 200 })
      T.eq(value.rebuild(res, { status = 500, reason = "Boom" }).reason, "Boom")
    end)

    T.it("headers in init replace the bag wholesale", function()
      local res = value.response(nil, { headers = value.headers_from_map({ a = "1", b = "2" }) })
      local out = value.rebuild(res, { headers = value.headers_from_map({ c = "3" }) })
      T.eq(value.has_header(out.headers, "a"), false)
      T.eq(value.get_header(out.headers, "c"), "3")
    end)

    T.it("omitting headers copies the source's, without aliasing them", function()
      local res = value.response(nil, { headers = value.headers_from_map({ a = "1" }) })
      local out = value.rebuild(res, { status = 201 })
      out.headers["a"][1] = "mutated"
      T.eq(value.get_header(res.headers, "a"), "1")
    end)

    T.it("rebuilding a streaming response never starts the producer", function()
      local counter = { n = 0 } --: { n: integer }
      local res = value.stream_response(counting_stream(counter))
      -- The CORS-layer shape: re-wrap status and headers around the same body.
      local out = res
      for _ = 1, 5 do
        out = value.rebuild(out, {
          status  = 200,
          headers = value.set_header(out.headers, "access-control-allow-origin", "*"),
        })
      end
      T.eq(counter.n, 0)
      T.eq(out.body, res.body)
      T.eq(value.get_header(out.headers, "access-control-allow-origin"), "*")
    end)

  end)

  T.describe("without_body", function()

    T.it("preserves content-length verbatim (RFC 9110 §9.3.2)", function()
      local res = value.response("0123456789", {
        headers = value.headers_from_map({ ["content-length"] = "10" }),
      })
      local head = value.without_body(res)
      T.eq(head.body.text, nil)
      T.eq(value.get_header(head.headers, "content-length"), "10")
    end)

    T.it("preserves status and reason", function()
      local res = value.response("x", { status = 201 })
      local head = value.without_body(res)
      T.eq(head.status, 201)
      T.eq(head.reason, "Created")
    end)

    T.it("discards a streaming producer without driving it", function()
      local counter = { n = 0 } --: { n: integer }
      local res = value.stream_response(counting_stream(counter))
      local head = value.without_body(res)
      T.eq(head.body.kind, "plain")
      T.eq(head.body.text, nil)
      T.eq(counter.n, 0)
    end)

  end)

  T.describe("detection", function()

    T.it("is_response_value is exact on the body tag", function()
      T.eq(value.is_response_value(value.response("x")), true)
      T.eq(value.is_response_value(value.stream_response(stream.from(function(_) return nil end))), true)
      T.eq(value.is_response_value({ status = 200 }), false)
      T.eq(value.is_response_value({ status = 200, body = { kind = "other" } }), false)
      T.eq(value.is_response_value({ body = { kind = "plain" } }), false)
      T.eq(value.is_response_value(nil), false)
      T.eq(value.is_response_value("200"), false)
    end)

    T.it("is_streaming distinguishes the two arms", function()
      T.eq(value.is_streaming(value.response("x")), false)
      T.eq(value.is_streaming(value.stream_response(stream.from(function(_) return nil end))), true)
    end)

  end)

  T.describe("request values", function()

    --: (target: string, host: string | nil) -> unknown
    local function req_from(target, host)
      return value.request_from_server({
        method = "GET", target = target, version = "HTTP/1.1",
        headers = {}, body = nil,
        scheme = "http", host = host, port = 80,
      })
    end

    T.it("splits the target into path and query", function()
      local req = req_from("/a/b?x=1", "h")
      if not as_record(req) then error("not a record") end
      T.eq(req.path, "/a/b")
    end)

    T.it("a target with no query yields an empty query table, not nil", function()
      local req = value.request_from_server({
        method = "GET", target = "/a", version = "HTTP/1.1",
        headers = {}, body = nil, scheme = "http", host = "h", port = 80,
      })
      T.eq(next(req.query), nil)
    end)

    T.it("preserves repeated query params rather than collapsing them", function()
      local req = value.request_from_server({
        method = "GET", target = "/s?tag=a&tag=b&q=z", version = "HTTP/1.1",
        headers = {}, body = nil, scheme = "http", host = "h", port = 80,
      })
      T.eq(#req.query["tag"], 2)
      T.eq(req.query["tag"][1], "a")
      T.eq(req.query["tag"][2], "b")
      T.eq(req.query["q"][1], "z")
    end)

  end)

  T.describe("request_url", function()

    --: (host: string | nil, port: integer | nil, scheme: string, target: string) -> (string | nil, string | nil)
    local function url_of(host, port, scheme, target)
      local req = value.request_from_server({
        method = "GET", target = target, version = "HTTP/1.1",
        headers = {}, body = nil, scheme = scheme, host = host, port = port,
      })
      return value.request_url(req, nil)
    end

    T.it("errors rather than fabricating an authority when host is nil", function()
      local u, err = url_of(nil, 80, "http", "/a")
      T.eq(u, nil)
      T.eq(type(err), "string")
    end)

    T.it("omits the scheme's default port", function()
      T.eq(url_of("example.com", 80, "http", "/a"), "http://example.com/a")
      T.eq(url_of("example.com", 443, "https", "/a"), "https://example.com/a")
    end)

    T.it("includes a non-default port", function()
      T.eq(url_of("example.com", 8080, "http", "/a"), "http://example.com:8080/a")
    end)

    T.it("does not re-append a port the Host field already carries", function()
      T.eq(url_of("example.com:9000", 8080, "http", "/a"), "http://example.com:9000/a")
    end)

    T.it("rebuilds a repeated query param and sorts keys deterministically", function()
      T.eq(url_of("h", 80, "http", "/s?b=2&a=1&a=0"), "http://h/s?a=1&a=0&b=2")
    end)

    T.it("accepts an override query — the pageLinkHeader shape", function()
      local req = value.request_from_server({
        method = "GET", target = "/s?tag=a&tag=b&cursor=old", version = "HTTP/1.1",
        headers = {}, body = nil, scheme = "https", host = "api.example.com", port = 443,
      })
      -- Preserve the "other" params, replace only the cursor — the repeated
      -- `tag` must survive, which a last-wins parse would have destroyed.
      local q = with_replaced(req.query, "cursor", "next-token")
      T.eq(value.request_url(req, q), "https://api.example.com/s?cursor=next-token&tag=a&tag=b")
    end)

  end)

end)
