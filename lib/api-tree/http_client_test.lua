-- lib/api-tree/http_client_test.lua
-- Tests for lib/api-tree/http_client.lua (the runtime HTTP client).
--
-- Every test here runs a real round trip through a real client; the only thing
-- faked is the transport, which is the injected cap the whole module is built
-- around. That is the point of the caps rule rather than a testing
-- convenience: no socket, no event loop, and no network appear anywhere below,
-- and a test asserts on the request VALUE the client produced rather than on
-- bytes it would have written.
--
-- Promises are inspected directly (`_state`/`value`/`reason`) rather than
-- driven with `async.run`. Everything in these tests settles synchronously —
-- `lib/async` propagates settlement through its continuation lists with no
-- scheduler in between — and reading the settled promise is both exact about
-- WHICH failure occurred and able to assert that a pending call is still
-- pending, which is what the cancellation cases need.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T      = require("lib.test.assert")
local async  = require("lib.async")
local client = require("lib.api-tree.http_client")
local json   = require("lib.format.json")
local value  = require("lib.api-tree.http_value")

-- ── Local views of the module's own types ────────────────────────────────
--
-- Cross-module named types are not yet supported, so a test that hands the
-- client a route tree, an authored node tree, or an options record has to
-- spell those shapes itself. They are structurally identical to
-- `http_client.lua`'s `RouteView`/`NodeView`/`ClientOptions` and unify with
-- them without a cast; the module's own `...` markers are omitted because
-- these fixtures carry nothing extra.

--:: HandlerFn = (input: unknown) -> unknown
--:: TestMethodEntry = { handler: HandlerFn, meta: { [string]: unknown } }
--:: TestRoute = { methods?: { [string]: TestMethodEntry }, children?: { [string]: TestRoute }, fallback?: { name: string, subtree: TestRoute }, meta: { [string]: unknown } }
--:: TestNode = { handler?: HandlerFn, children?: { [string]: TestNode }, fallback?: { name: string, subtree: TestNode }, meta: { [string]: unknown } }
--:: TestCancelToken = { kind: "cancel_token", aborted: () -> boolean, reason: () -> (string | nil), subscribe: (listener: (reason: string) -> nil) -> (() -> nil) }
--:: TestTransport = (req: unknown) -> unknown
--:: TestOptions = { base_url?: string, transport: TestTransport, timer?: (ms: number) -> unknown, timeout?: number, cancel?: TestCancelToken, extensions?: { [integer]: unknown }, node?: TestNode }

-- ── Narrowing helpers ────────────────────────────────────────────────────

--: (v: unknown) -> v is { [string]: unknown }
local function as_record(v)
  return type(v) == "table"
end

--: (v: unknown) -> v is { _state: string, value: unknown, reason: unknown }
local function as_promise(v)
  return type(v) == "table"
end

--: (v: unknown) -> v is (input: unknown, call_opts: unknown) -> unknown
local function as_callable(v)
  return type(v) == "function"
end

--: (v: unknown) -> v is (slug: string) -> unknown
local function as_slug_fn(v)
  return type(v) == "function"
end

--: (v: unknown) -> v is { status: integer, body: unknown, message: string }
local function as_client_error(v)
  return client.is_client_error(v)
end

-- ── Fixtures ─────────────────────────────────────────────────────────────
--
-- Handlers are distinct empty functions used purely as IDENTITIES: the name
-- maps are keyed by the handler value, so what matters is that no two of these
-- are the same function, not what any of them does.

--: (input: unknown) -> unknown
local function h_list(input) return input end
--: (input: unknown) -> unknown
local function h_add(input) return input end
--: (input: unknown) -> unknown
local function h_read(input) return input end
--: (input: unknown) -> unknown
local function h_replace(input) return input end

-- A route tree shaped exactly as the route rewriters leave one: children keys
-- are path segments, `methods` is keyed by resolved verb, and the co-located
-- read/replace operations have collapsed onto the fallback position with only
-- their verbs remembered.
--: () -> TestRoute
local function books_route()
  return {
    meta = {},
    children = {
      books = {
        meta = {},
        methods = {
          GET  = { handler = h_list, meta = { op = "list" } },
          POST = { handler = h_add,  meta = { op = "add" } },
        },
        fallback = {
          name = "book_id",
          subtree = {
            meta = {},
            methods = {
              GET = { handler = h_read,    meta = { op = "read" } },
              PUT = { handler = h_replace, meta = { op = "replace" } },
            },
          },
        },
      },
    },
  }
end

-- The AUTHORED tree the route above was projected from — the thing that still
-- remembers `read`/`replace` as member names.
--: () -> TestNode
local function books_node()
  return {
    meta = {},
    children = {
      books = {
        meta = {},
        children = {
          list = { handler = h_list, meta = {} },
          add  = { handler = h_add,  meta = {} },
        },
        fallback = {
          name = "book_id",
          subtree = {
            meta = {},
            children = {
              read    = { handler = h_read,    meta = {} },
              replace = { handler = h_replace, meta = {} },
            },
          },
        },
      },
    },
  }
end

-- A transport that records every request it is handed and replies with a
-- fixed JSON body.
--: (log: { [integer]: unknown }, status: integer, payload: unknown) -> TestTransport
local function recording_transport(log, status, payload)
  return function(req)
    log[#log + 1] = req
    local text = json.encode(payload)
    return value.response(text, { status = status, headers = { ["content-type"] = { "application/json" } } })
  end
end

-- A transport that never replies, plus the handle to reply later. Used by the
-- cancellation cases, where the whole question is what happens while a request
-- is still in flight.
--: () -> (TestTransport, { resolve: (v: unknown) -> nil })
local function pending_transport()
  local handle = { resolve = function(v) end }
  --: (req: unknown) -> unknown
  local function transport(req)
    local p, resolve, _ = async.promise()
    handle.resolve = resolve
    return p
  end
  return transport, handle
end

--: (route: TestRoute, opts: TestOptions) -> unknown
local function build(route, opts)
  local c = client.create_client_from_route(route, opts)
  T.neq(c, nil)
  return c
end

--: (c: unknown, path: { [integer]: string }) -> unknown
local function member(c, path)
  local cur = c
  for i = 1, #path do
    T.ok(as_record(cur), "expected a client table at segment " .. path[i])
    if as_record(cur) then cur = cur[path[i]] end
  end
  return cur
end

--: (c: unknown, path: { [integer]: string }, input: unknown, call_opts: unknown) -> unknown
local function call(c, path, input, call_opts)
  local fn = member(c, path)
  T.ok(as_callable(fn), "expected a callable at " .. table.concat(path, "."))
  if not as_callable(fn) then return nil end
  return fn(input, call_opts)
end

T.describe("lib.api-tree.http_client", function()

  T.describe("construction", function()

    -- Both construction guards below are unreachable from typed code:
    -- `transport` is a required field, and an options record with `timeout`
    -- but no `timer` is rejected by the annotation before it runs. They exist
    -- for callers the checker never sees, so they are exercised the way such a
    -- caller reaches them — through a reference widened to `unknown` and
    -- narrowed back to a looser signature, which is a real narrowing and not a
    -- force cast past the declared type.
    --: (v: unknown) -> v is (route: unknown, opts: { [string]: unknown }) -> unknown
    local function as_untyped_ctor(v)
      return type(v) == "function"
    end

    T.it("errors without an injected transport — there is no default", function()
      local ctor = client.create_client_from_route --[[: unknown]]
      T.ok(as_untyped_ctor(ctor))
      T.throws(function()
        if as_untyped_ctor(ctor) then return ctor(books_route(), {}) end
        return nil
      end)
    end)

    T.it("errors when a timeout is set with no timer cap to drive it", function()
      local ctor = client.create_client_from_route --[[: unknown]]
      T.throws(function()
        if as_untyped_ctor(ctor) then
          --: (req: unknown) -> unknown
          local function transport(req) return req end
          return ctor(books_route(), { transport = transport, timeout = 100 })
        end
        return nil
      end)
    end)

    T.it("treats an authority-less base_url as a bare path prefix", function()
      -- `lib/url`'s parse is total, so there is no malformed-base-url error to
      -- report — a base URL with nothing that reads as a host becomes a path
      -- prefix and the client stays origin-less. See the module doc.
      --: { [integer]: unknown }
      local log = {}
      local c = build(books_route(), {
        transport = recording_transport(log, 200, {}),
        base_url  = "/api",
      })
      call(c, { "books", "get" }, nil, nil)
      local req = log[1]
      T.ok(as_record(req))
      if as_record(req) then
        T.eq(req.path, "/api/books")
        T.eq(req.host, nil)
      end
    end)

  end)

  T.describe("request construction", function()

    T.it("puts a GET input into the query string, never a body", function()
      --: { [integer]: unknown }
      local log = {}
      local c = build(books_route(), { transport = recording_transport(log, 200, {}) })
      call(c, { "books", "get" }, { limit = 10 }, nil)

      T.eq(#log, 1)
      local req = log[1]
      T.ok(as_record(req))
      if not as_record(req) then return end
      T.eq(req.method, "GET")
      T.eq(req.path, "/books")
      T.eq(req.body, nil)
      local query = req.query
      T.ok(as_record(query))
      if as_record(query) then
        local limit = query.limit
        T.ok(as_record(limit))
        if as_record(limit) then T.eq(limit[1], "10") end
      end
    end)

    T.it("keeps a repeated query param repeated instead of collapsing it", function()
      --: { [integer]: unknown }
      local log = {}
      local c = build(books_route(), { transport = recording_transport(log, 200, {}) })
      call(c, { "books", "get" }, { tag = { "a", "b" } }, nil)

      local req = log[1]
      T.ok(as_record(req))
      if not as_record(req) then return end
      local query = req.query
      T.ok(as_record(query))
      if not as_record(query) then return end
      local tags = query.tag
      T.ok(as_record(tags))
      if as_record(tags) then
        T.eq(#tags, 2)
        T.eq(tags[1], "a")
        T.eq(tags[2], "b")
      end
    end)

    T.it("rejects a nested table param rather than stringifying an address", function()
      --: { [integer]: unknown }
      local log = {}
      local c = build(books_route(), { transport = recording_transport(log, 200, {}) })
      local p = call(c, { "books", "get" }, { filter = { author = "x" } }, nil)
      T.ok(as_promise(p))
      if as_promise(p) then
        T.eq(p._state, "rejected")
        T.eq(type(p.reason), "string")
      end
      T.eq(#log, 0, "the transport is never reached")
    end)

    T.it("sends a POST input as a JSON body with a content-type", function()
      --: { [integer]: unknown }
      local log = {}
      local c = build(books_route(), { transport = recording_transport(log, 200, {}) })
      call(c, { "books", "post" }, { title = "x" }, nil)

      local req = log[1]
      T.ok(as_record(req))
      if not as_record(req) then return end
      T.eq(req.method, "POST")
      T.eq(req.body, '{"title":"x"}')
      local headers = req.headers
      T.ok(as_record(headers))
      if as_record(headers) then
        local ct = headers["content-type"]
        T.ok(as_record(ct))
        if as_record(ct) then T.eq(ct[1], "application/json") end
      end
    end)

    T.it("sends an empty JSON object when a body verb gets no input", function()
      --: { [integer]: unknown }
      local log = {}
      local c = build(books_route(), { transport = recording_transport(log, 200, {}) })
      call(c, { "books", "post" }, nil, nil)
      local req = log[1]
      T.ok(as_record(req))
      if as_record(req) then T.eq(req.body, "{}") end
    end)

    T.it("prepends base_url as a prefix and stamps the origin onto the request", function()
      --: { [integer]: unknown }
      local log = {}
      local c = build(books_route(), {
        transport = recording_transport(log, 200, {}),
        base_url  = "https://api.example.com:8443/v1",
      })
      call(c, { "books", "get" }, nil, nil)

      local req = log[1]
      T.ok(as_record(req))
      if not as_record(req) then return end
      T.eq(req.path, "/v1/books")
      T.eq(req.scheme, "https")
      T.eq(req.host, "api.example.com")
      T.eq(req.port, 8443)
    end)

    T.it("stays origin-less with no base_url rather than fabricating a host", function()
      --: { [integer]: unknown }
      local log = {}
      local c = build(books_route(), { transport = recording_transport(log, 200, {}) })
      call(c, { "books", "get" }, nil, nil)
      local req = log[1]
      T.ok(as_record(req))
      if as_record(req) then T.eq(req.host, nil) end
    end)

  end)

  T.describe("tree shape", function()

    T.it("substitutes a fallback slug into the path, percent-encoded", function()
      --: { [integer]: unknown }
      local log = {}
      local c = build(books_route(), { transport = recording_transport(log, 200, {}) })
      local sub_fn = member(c, { "books", "book_id" })
      T.ok(as_slug_fn(sub_fn))
      if not as_slug_fn(sub_fn) then return end
      local sub = sub_fn("a/b?c")
      call(sub, { "get" }, nil, nil)

      local req = log[1]
      T.ok(as_record(req))
      if as_record(req) then T.eq(req.path, "/books/a%2Fb%3Fc") end
    end)

    T.it("omits a path slug from the query params it is already embedded in", function()
      --: { [integer]: unknown }
      local log = {}
      local c = build(books_route(), { transport = recording_transport(log, 200, {}) })
      local sub_fn = member(c, { "books", "book_id" })
      if not as_slug_fn(sub_fn) then return end
      call(sub_fn("b-1"), { "get" }, { book_id = "b-1", fields = "title" }, nil)

      local req = log[1]
      T.ok(as_record(req))
      if not as_record(req) then return end
      local query = req.query
      T.ok(as_record(query))
      if as_record(query) then
        T.eq(query.book_id, nil)
        T.neq(query.fields, nil)
      end
    end)

    T.it("collapses a lone-method position into a bare callable", function()
      --: { [integer]: unknown }
      local log = {}
      local route = {
        meta = {},
        children = {
          health = { meta = {}, methods = { GET = { handler = h_list, meta = {} } } },
        },
      }
      local c = build(route, { transport = recording_transport(log, 200, {}) })
      T.ok(as_callable(member(c, { "health" })), "a single-method position is the callable itself")
    end)

    T.it("names co-located methods by verb when the authored tree is absent", function()
      --: { [integer]: unknown }
      local log = {}
      local c = build(books_route(), { transport = recording_transport(log, 200, {}) })
      local sub_fn = member(c, { "books", "book_id" })
      if not as_slug_fn(sub_fn) then return end
      local sub = sub_fn("b-1")
      T.ok(as_callable(member(sub, { "get" })))
      T.ok(as_callable(member(sub, { "put" })))
      T.eq(member(sub, { "read" }), nil)
    end)

    T.it("recovers authored member names when opts.node is supplied", function()
      --: { [integer]: unknown }
      local log = {}
      local c = build(books_route(), {
        transport = recording_transport(log, 200, {}),
        node      = books_node(),
      })
      T.ok(as_callable(member(c, { "books", "list" })))
      T.ok(as_callable(member(c, { "books", "add" })))
      local sub_fn = member(c, { "books", "book_id" })
      if not as_slug_fn(sub_fn) then return end
      local sub = sub_fn("b-1")
      T.ok(as_callable(member(sub, { "read" })))
      T.ok(as_callable(member(sub, { "replace" })))
      T.eq(member(sub, { "get" }), nil, "the verb name is replaced, not added alongside")
    end)

  end)

  T.describe("name maps", function()

    T.it("keys authored names by handler identity, so duplicate keys never collide", function()
      local names = client.handler_names_from_node(books_node())
      T.eq(names[h_list], "list")
      T.eq(names[h_read], "read")
      T.eq(names[h_replace], "replace")
    end)

    T.it("accumulates codegen names from the root, fallback name included", function()
      local names = client.codegen_names_from_node(books_node())
      T.eq(names[h_list], "books_list")
      T.eq(names[h_read], "books_book_id_read")
    end)

    T.it("names a bare-leaf fallback subtree by the fallback's own name", function()
      -- The Node model allows `fallback.subtree` to be a leaf rather than a
      -- branch; recursing into its nonexistent children would silently drop it.
      local node = {
        meta = {},
        children = {
          files = {
            meta = {},
            fallback = { name = "path", subtree = { handler = h_read, meta = {} } },
          },
        },
      }
      T.eq(client.handler_names_from_node(node)[h_read], "path")
      T.eq(client.codegen_names_from_node(node)[h_read], "files_path")
    end)

  end)

  T.describe("response decoding", function()

    T.it("parses a JSON body and resolves with it", function()
      --: { [integer]: unknown }
      local log = {}
      local c = build(books_route(), { transport = recording_transport(log, 200, { ok = true }) })
      local p = call(c, { "books", "get" }, nil, nil)
      T.ok(as_promise(p))
      if not as_promise(p) then return end
      T.eq(p._state, "fulfilled")
      local body = p.value
      T.ok(as_record(body))
      if as_record(body) then T.eq(body.ok, true) end
    end)

    T.it("returns the raw text when the response is not JSON", function()
      --: (req: unknown) -> unknown
      local function transport(req)
        return value.response("plain words", { headers = { ["content-type"] = { "text/plain" } } })
      end
      local c = build(books_route(), { transport = transport })
      local p = call(c, { "books", "get" }, nil, nil)
      if as_promise(p) then T.eq(p.value, "plain words") end
    end)

    T.it("rejects a non-2xx response with a structured client error", function()
      --: { [integer]: unknown }
      local log = {}
      local c = build(books_route(), { transport = recording_transport(log, 404, { message = "no such book" }) })
      local p = call(c, { "books", "get" }, nil, nil)
      T.ok(as_promise(p))
      if not as_promise(p) then return end
      T.eq(p._state, "rejected")
      local err = p.reason
      T.ok(as_client_error(err), "a non-2xx rejection is a client error value")
      if as_client_error(err) then
        T.eq(err.status, 404)
        T.eq(err.message, "HTTP 404")
        local body = err.body
        T.ok(as_record(body))
        if as_record(body) then T.eq(body.message, "no such book") end
      end
    end)

    T.it("hands back a streaming body undrained rather than buffering it", function()
      local stream = require("lib.api-tree.stream")
      --: { n: number }
      local counter = { n = 0 }
      --: (req: unknown) -> unknown
      local function transport(req)
        return value.stream_response(stream.from(function(emit)
          counter.n = counter.n + 1
          return nil
        end))
      end
      local c = build(books_route(), { transport = transport })
      local p = call(c, { "books", "get" }, nil, nil)
      T.ok(as_promise(p))
      if as_promise(p) then
        T.eq(p._state, "fulfilled")
        T.ok(stream.is_stream(p.value), "the value is the stream itself")
      end
      T.eq(counter.n, 0, "nothing in the producer has run")
    end)

    T.it("rejects when the transport returns something that is not a response", function()
      --: (req: unknown) -> unknown
      local function transport(req) return { not_a = "response" } end
      local c = build(books_route(), { transport = transport })
      local p = call(c, { "books", "get" }, nil, nil)
      if as_promise(p) then
        T.eq(p._state, "rejected")
        T.eq(type(p.reason), "string")
      end
    end)

  end)

  T.describe("extensions", function()

    T.it("wraps every call's transport, once, at construction", function()
      --: { [integer]: unknown }
      local log = {}
      --: { n: number }
      local counter = { n = 0 }
      local c = build(books_route(), {
        transport  = recording_transport(log, 200, {}),
        extensions = { {
          name = "counting",
          --: (inner: (req: unknown) -> unknown) -> ((req: unknown) -> unknown)
          wrap_transport = function(inner)
            return function(req)
              counter.n = counter.n + 1
              return inner(req)
            end
          end,
        } },
      })
      call(c, { "books", "get" }, nil, nil)
      call(c, { "books", "post" }, nil, nil)
      T.eq(counter.n, 2)
    end)

    T.it("lets a decoder claim the response, skipping both the decode and the status check", function()
      --: { [integer]: unknown }
      local log = {}
      local c = build(books_route(), {
        transport  = recording_transport(log, 500, { message = "boom" }),
        extensions = { {
          name = "claiming",
          --: (res: unknown, ctx: unknown) -> unknown
          decode_response = function(res, ctx) return { value = "claimed" } end,
        } },
      })
      local p = call(c, { "books", "get" }, nil, nil)
      T.ok(as_promise(p))
      if as_promise(p) then
        T.eq(p._state, "fulfilled", "a claimed 500 is not turned into a client error")
        T.eq(p.value, "claimed")
      end
    end)

    T.it("threads the leaf's meta and codegen name into the decode context", function()
      --: { [integer]: unknown }
      local log = {}
      local seen = { codegen_name = "", op = "" }
      local c = build(books_route(), {
        transport  = recording_transport(log, 200, {}),
        node       = books_node(),
        extensions = { {
          name = "observer",
          --: (res: unknown, ctx: unknown) -> unknown
          decode_response = function(res, ctx)
            local record = ctx
            if as_record(record) then
              seen.codegen_name = tostring(record.codegen_name)
              local meta = record.meta
              if as_record(meta) then seen.op = tostring(meta.op) end
            end
            return { value = nil }
          end,
        } },
      })
      call(c, { "books", "list" }, nil, nil)
      T.eq(seen.codegen_name, "books_list")
      T.eq(seen.op, "list")
    end)

    T.it("leaves codegen_name nil when no authored tree was supplied", function()
      --: { [integer]: unknown }
      local log = {}
      local seen = { codegen_name = "unset" }
      local c = build(books_route(), {
        transport  = recording_transport(log, 200, {}),
        extensions = { {
          name = "observer",
          --: (res: unknown, ctx: unknown) -> unknown
          decode_response = function(res, ctx)
            if as_record(ctx) then seen.codegen_name = tostring(ctx.codegen_name) end
            return { value = nil }
          end,
        } },
      })
      call(c, { "books", "get" }, nil, nil)
      T.eq(seen.codegen_name, "nil")
    end)

  end)

  T.describe("cancellation", function()

    T.it("cancel_source hands out a token and a separate abort capability", function()
      local token, abort = client.cancel_source()
      T.ok(client.is_cancel_token(token))
      T.eq(token.aborted(), false)
      abort("because")
      T.eq(token.aborted(), true)
      T.eq(token.reason(), "because")
    end)

    T.it("abort is idempotent — the first reason wins", function()
      local token, abort = client.cancel_source()
      abort("first")
      abort("second")
      T.eq(token.reason(), "first")
    end)

    T.it("subscribe fires immediately on an already-aborted token", function()
      local token, abort = client.cancel_source()
      abort("done")
      local seen = { reason = "" }
      token.subscribe(function(reason) seen.reason = reason end)
      T.eq(seen.reason, "done")
    end)

    T.it("unsubscribing stops a listener from firing", function()
      local token, abort = client.cancel_source()
      --: { n: number }
      local seen = { n = 0 }
      local unsubscribe = token.subscribe(function(reason) seen.n = seen.n + 1 end)
      unsubscribe()
      abort(nil)
      T.eq(seen.n, 0)
    end)

    T.it("settles an in-flight call the moment its token aborts", function()
      local transport, handle = pending_transport()
      local token, abort = client.cancel_source()
      local c = build(books_route(), { transport = transport, cancel = token })

      local p = call(c, { "books", "get" }, nil, nil)
      T.ok(as_promise(p))
      if not as_promise(p) then return end
      T.eq(p._state, "pending")

      abort("navigated away")
      T.eq(p._state, "rejected")
      T.eq(type(p.reason), "string")
      if type(p.reason) == "string" then
        local reason = tostring(p.reason)
        T.neq(reason:find("aborted", 1, true), nil, "the message says aborted")
        T.neq(reason:find("navigated away", 1, true), nil, "the caller's reason survives")
        T.eq(reason:find("timed out", 1, true), nil, "abort and timeout are distinct messages")
      end
    end)

    T.it("does not resurrect a settled call when its token aborts afterwards", function()
      --: { [integer]: unknown }
      local log = {}
      local token, abort = client.cancel_source()
      local c = build(books_route(), { transport = recording_transport(log, 200, { ok = true }), cancel = token })
      local p = call(c, { "books", "get" }, nil, nil)
      T.ok(as_promise(p))
      if not as_promise(p) then return end
      T.eq(p._state, "fulfilled")
      abort("too late")
      T.eq(p._state, "fulfilled")
    end)

    T.it("a per-call token replaces the client-level one rather than joining it", function()
      local transport, handle = pending_transport()
      local client_token, abort_client = client.cancel_source()
      local call_token, abort_call = client.cancel_source()
      local c = build(books_route(), { transport = transport, cancel = client_token })

      local p = call(c, { "books", "get" }, nil, { cancel = call_token })
      T.ok(as_promise(p))
      if not as_promise(p) then return end

      abort_client("client-level")
      T.eq(p._state, "pending", "the replaced client token no longer reaches this call")

      abort_call("per-call")
      T.eq(p._state, "rejected")
    end)

  end)

  T.describe("timeout", function()

    -- A timer cap whose promises are fired by hand, so a test controls time
    -- exactly instead of sleeping. Records every arming, which is how the
    -- fresh-per-call property is asserted.
    --: () -> (((ms: number) -> unknown), { [integer]: { ms: number, fire: () -> nil } })
    local function manual_timer()
      --: { [integer]: { ms: number, fire: () -> nil } }
      local armed = {}
      --: (ms: number) -> unknown
      local function timer(ms)
        local p, resolve, _ = async.promise()
        armed[#armed + 1] = { ms = ms, fire = function() resolve(nil) end }
        return p
      end
      return timer, armed
    end

    T.it("rejects with a timeout message distinct from an abort", function()
      local transport, handle = pending_transport()
      local timer, armed = manual_timer()
      local c = build(books_route(), { transport = transport, timer = timer, timeout = 250 })

      local p = call(c, { "books", "get" }, nil, nil)
      T.ok(as_promise(p))
      if not as_promise(p) then return end
      T.eq(p._state, "pending")
      T.eq(#armed, 1)
      T.eq(armed[1].ms, 250)

      armed[1].fire()
      T.eq(p._state, "rejected")
      local reason = tostring(p.reason)
      T.neq(reason:find("timed out after 250ms", 1, true), nil)
      T.eq(reason:find("aborted", 1, true), nil, "timeout and abort are distinct messages")
    end)

    T.it("arms a fresh timer for every call", function()
      local transport, handle = pending_transport()
      local timer, armed = manual_timer()
      local c = build(books_route(), { transport = transport, timer = timer, timeout = 100 })
      call(c, { "books", "get" }, nil, nil)
      call(c, { "books", "get" }, nil, nil)
      T.eq(#armed, 2, "a timer armed once at construction would only fire for the first call")
    end)

    T.it("a per-call timeout replaces the client-level one", function()
      local transport, handle = pending_transport()
      local timer, armed = manual_timer()
      local c = build(books_route(), { transport = transport, timer = timer, timeout = 100 })
      call(c, { "books", "get" }, nil, { timeout = 5000 })
      T.eq(#armed, 1)
      T.eq(armed[1].ms, 5000)
    end)

    T.it("does not arm a timer when neither level sets a timeout", function()
      --: { [integer]: unknown }
      local log = {}
      local timer, armed = manual_timer()
      local c = build(books_route(), { transport = recording_transport(log, 200, {}), timer = timer })
      call(c, { "books", "get" }, nil, nil)
      T.eq(#armed, 0)
    end)

    T.it("rejects a per-call timeout on a client built without a timer cap", function()
      --: { [integer]: unknown }
      local log = {}
      local c = build(books_route(), { transport = recording_transport(log, 200, {}) })
      local p = call(c, { "books", "get" }, nil, { timeout = 10 })
      T.ok(as_promise(p))
      if as_promise(p) then T.eq(p._state, "rejected") end
    end)

    T.it("a transport that wins the race leaves the timeout inert", function()
      --: { [integer]: unknown }
      local log = {}
      local timer, armed = manual_timer()
      local c = build(books_route(), {
        transport = recording_transport(log, 200, { ok = true }),
        timer     = timer,
        timeout   = 100,
      })
      local p = call(c, { "books", "get" }, nil, nil)
      T.ok(as_promise(p))
      if not as_promise(p) then return end
      T.eq(p._state, "fulfilled")
      armed[1].fire()
      T.eq(p._state, "fulfilled", "a late timer cannot re-settle a finished call")
    end)

  end)

end)
