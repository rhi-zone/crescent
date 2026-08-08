-- lib/fractal/http_adapter.lua — the boundary between the HTTP projector's
-- response VALUE model (http_value.lua) and a real socket. Ported from
-- fractal's packages/http-api-projector/src/adapter.ts.
--
-- WHAT adapter.ts IS AND WHAT SURVIVES THE PORT. On the TypeScript side an
-- adapter binds a `FetchHandler` — `(req: Request) => Promise<Response>` — to a
-- concrete server runtime, and the file is explicitly "the ONLY runtime touch
-- in this package," so the core stays runtime-agnostic. It carries two shapes:
-- `serveX` (Bun/Node/Deno/Fastly — start a listening loop) and `toX`
-- (Cloudflare Workers/Vercel Edge/AWS Lambda — translate the handler into the
-- export shape a platform's own dispatcher expects).
--
-- Crescent has exactly one server runtime, `lib/http/server.lua`, so the
-- seven-runtime fan-out has no analogue and is NOT reproduced: there is no
-- Bun/Deno/Workers/Lambda to bind to, and inventing stand-ins would be
-- fabricating platforms this repo does not run on. What survives is the FILE'S
-- ROLE — the one runtime touch, the single place a projector value meets a
-- socket — realized against the one runtime that exists:
--
--   `M.materialize`      — a response VALUE onto a `res`/`sock` pair
--   `M.handler_from_fetch` — a projector fetch function as an `HttpHandlerFn`
--   `M.serve`            — bind that handler to `lib/http/server.lua`
--
-- `serve` is the `serveX` shape (starts a loop); `handler_from_fetch` is the
-- `toX` shape (pure translation, starts nothing). The AWS Lambda adapter's
-- genuinely non-passthrough parts — folding `cookies` into headers on the way
-- in, splitting `set-cookie` back out on the way out, base64-ing non-text
-- bodies — are Lambda event-shape concerns with nothing to translate them to
-- here, and are likewise absent rather than approximated.
--
-- ── THE MATERIALIZATION RULE ─────────────────────────────────────────────
--
-- This is the ONLY module that may turn a response value into bytes, and it
-- does so exactly once per request, at the very end of the layer/middleware
-- composition. Everything upstream — CORS, auto-method, subtree middleware,
-- tracing, idempotency — has already had its chance to wrap, re-header, and
-- re-status the value by the time it arrives here. See http_value.lua's module
-- doc for why the value model is built to make that possible.
--
-- Two arms, decided by `http_value.is_streaming`:
--
--   PLAIN — status, reason, and headers are copied into `res` and the body
--     text assigned. Nothing else happens: the connection core in
--     lib/http/server.lua serializes `res` through its ordinary managed path
--     once the handler returns, including its own `connection:` header and
--     keep-alive bookkeeping. The socket is never touched here.
--
--   STREAMING — the head is set on `res`, then `server.response_stream(res,
--     sock)` takes ownership (it sets `res.raw`, which is the connection core's
--     signal to neither serialize nor close). The deferred producer — a
--     lib/fractal/stream.lua Stream that has run NOTHING up to this instant —
--     is driven from there, each emission written as it arrives, and the socket
--     closed when the terminal value lands.
--
-- Driving is asynchronous and the handler returns before it finishes. That is
-- correct rather than a leak: the connection core's `if res.raw then return
-- end` path deliberately leaves the socket open and unclosed precisely so an
-- in-flight incremental response can keep writing on the event loop. The
-- promise is returned so a caller that needs to observe completion (a test, or
-- a shutdown path) can await it.
--
-- BODYLESS RESPONSES. A plain value whose `text` is nil is assigned nil, not
-- `""`. Whether a `content-length: 0` then appears on the wire for a 204/304/
-- 1xx is `lib/http/format.lua`'s call, not this module's — RFC 9112 §6.2
-- forbids it there, and the framing decision belongs to the serializer that
-- owns every other framing decision. This module neither adds nor strips
-- `content-length`; it copies the headers the layer stack produced.

if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local async  = require("lib.async")
local server = require("lib.http.server")
local stream = require("lib.fractal.stream")
local value  = require("lib.fractal.http_value")

local M = {}

-- Structural views of the two lib/http/server.lua shapes this module writes
-- into and reads from. Declared here rather than imported because cross-module
-- named types are not yet supported — the same reason lib/http/server.lua
-- itself declares `AsyncLoop`/`AsyncPromiseLike` structurally, and the reason
-- tags.lua declares its own `NodeView`. The `...` on the socket view is the
-- structural-subtyping marker: a real accepted client carries far more members
-- than the two used here.
-- Each mirrors its lib/http/server.lua counterpart FIELD FOR FIELD
-- (`http_server_response`, `http_client_sock`, `http_server_request`,
-- `http_response_stream`). That exactness is load-bearing: a view that merely
-- covered the members this module happens to touch would not unify with the
-- server's own declarations at the call sites below, and closing the gap with a
-- force cast is precisely what CLAUDE.md forbids. Structurally identical
-- declarations unify without any cast at all.
--:: AdapterResponse = { status: integer, reason: string, version: string, headers: { [string]: string[] }, body: string | nil, raw: boolean | nil, keep_alive: boolean | nil }
--:: AdapterSocket = { receive: (self: AdapterSocket, unknown) -> string | nil, send: (self: AdapterSocket, string) -> unknown, close: (self: AdapterSocket) -> unknown, set_option: (self: AdapterSocket, string, unknown, string | nil) -> (boolean | nil, string | nil), fd: integer, on_send: unknown, on_receive: unknown, _loop: unknown, ... }
--:: AdapterRequest = { method: string, target: string, version: string, headers: { [string]: string[] }, body: string | nil, scheme: string, host: string | nil, port: integer | nil }

-- The incremental-response handle `server.response_stream` returns. Same
-- structural-declaration reasoning as above.
--:: AdapterResponseStream = { send_head: (self: AdapterResponseStream) -> (boolean | nil, string | nil), write: (self: AdapterResponseStream, string) -> (boolean | nil, string | nil), close: (self: AdapterResponseStream) -> nil, is_open: (self: AdapterResponseStream) -> boolean }

-- A projector fetch function: the crescent reading of layers.ts's
-- `Fetch = (req: Request) => Promise<Response>`. Takes a request VALUE and
-- returns either a response value or a promise of one — the async-optional
-- shape direct.lua already established for leaf callables, so a synchronous
-- projector needs no event loop.
--:: FetchFn = (req: unknown) -> unknown

-- ── Narrowing wrappers ───────────────────────────────────────────────────
--
-- `http_value.is_response_value` and `stream.is_stream` both return a plain
-- boolean, which is the right signature there — they are runtime shape sniffs
-- over `unknown`, usable by any consumer. A checked cast cannot narrow an
-- `unknown` (CLAUDE.md: force-casting past `unknown` is wrong), so each is
-- wrapped here in a local predicate carrying a `v is T` signature, where T is
-- spelled structurally because cross-module named types are not yet supported.
-- This is the same idiom stream.lua uses for `is_chunk_effect` over
-- result.lua's `is_stream_chunk`, and direct.lua for `is_plain_table`.

-- The response-value shape this module reads. `body` is flattened to one
-- record carrying both arms' fields rather than the `HttpBodyPlain |
-- HttpBodyStream` union: `kind` is read to choose the arm and only that arm's
-- field is then touched, so the union buys nothing here and a structural union
-- spelled out in a wrapper's signature would not narrow across the module
-- boundary anyway.
--:: AdapterResponseValue = { status: integer, reason: string, headers: { [string]: string[] }, body: { kind: string, text: string | nil, producer: unknown } }

--: (v: unknown) -> v is AdapterResponseValue
local function is_response_value(v)
	return value.is_response_value(v)
end

--:: AdapterStream = { kind: "stream", next: () -> unknown }

--: (v: unknown) -> v is AdapterStream
local function is_stream_producer(v)
	return stream.is_stream(v)
end

-- lib/async's own promise detection, matching `M.await`'s guard: a table
-- carrying the internal `_state` field. Identical to direct.lua's, and declared
-- here for the same reason it is declared there.
--:: AdapterPromiseView = { _state: string, ... }

--: (v: unknown) -> v is AdapterPromiseView
local function is_promise(v)
	if type(v) ~= "table" then return false end
	return v._state ~= nil
end

-- ── Copying a response value onto `res` ──────────────────────────────────

-- Write status, reason, and headers onto the mutable `res` the connection core
-- handed the handler. Header values are copied array-by-array rather than by
-- sharing the value model's tables: `res` outlives this call and the connection
-- core appends its own `connection:` field to it, which must not reach back
-- into a response value a caller may still be holding.
--: (res: AdapterResponse, r: AdapterResponseValue) -> nil
local function write_head(res, r)
	res.status = r.status
	res.reason = r.reason
	--: { [string]: { [integer]: string } }
	local headers = {}
	for name, values in pairs(r.headers) do
		--: { [integer]: string }
		local copied = {}
		for i = 1, #values do copied[i] = values[i] end
		headers[name] = copied
	end
	res.headers = headers
end

-- Drive a deferred producer onto an open response stream.
--
-- Each emission is written as it arrives — `stream.drive`'s `chunk` arm — which
-- is where the lockstep property pays off: the producer is resumed only after
-- the previous chunk has been handed to `sock:send`, so a slow consumer
-- naturally throttles the producer instead of accumulating a buffer. Progress
-- effects are dropped: HTTP has no progress channel distinct from the body, and
-- stream.lua documents omitting the `progress` arm as the correct behavior for
-- exactly such a transport.
--
-- A non-string emission is a producer-side error, not a data error: a streaming
-- response's producer is documented (http_value.lua) to emit already-framed
-- byte strings, and silently `tostring`-ing a table would put malformed bytes on
-- the wire under a content-type that promised otherwise.
--
-- The socket is closed when the terminal value lands. Closing is what delimits
-- a body with no declared length, so this is the normal termination and not
-- only the error path — see `response_stream`'s own note in lib/http/server.lua.
--: (rs: AdapterResponseStream, producer: AdapterStream) -> unknown
local function drive_onto(rs, producer)
	local drain = async.async(function()
		local outcome = async.await(stream.drive(producer, {
			progress = nil,
			--: (chunk: unknown) -> nil
			chunk = function(chunk)
				if type(chunk) ~= "string" then
					error("fractal.http_adapter: a streaming response producer emitted a "
						.. type(chunk) .. "; it must emit already-framed byte strings")
				end
				rs:write(chunk)
			end,
		}))
		rs:close()
		return outcome
	end)
	return drain()
end

-- ── The one materialization point ────────────────────────────────────────

-- Turn a response VALUE into bytes on `res`/`sock`. Returns nil for a plain
-- response (the connection core serializes it) and the driving promise for a
-- streaming one (so completion is observable).
--
-- Errors rather than returning `(nil, err)` when handed something that is not a
-- response value: reaching this function with the wrong type is a programming
-- error at the composition site, not a data error (conventions.md's split).
--: (rv: unknown, res: AdapterResponse, sock: AdapterSocket) -> unknown
function M.materialize(rv, res, sock)
	if not is_response_value(rv) then
		error("fractal.http_adapter: materialize expects an http_value response value")
	end
	write_head(res, rv)
	local body = rv.body
	if body.kind == "plain" then
		res.body = body.text
		return nil
	end
	local producer = body.producer
	if not is_stream_producer(producer) then
		error("fractal.http_adapter: a streaming response value carries no Stream producer")
	end
	-- Streaming: take the socket, then start the producer — in that order, so
	-- the head is on the wire before the first chunk is asked for.
	local handle = server.response_stream(res, sock)
	handle:send_head()
	return drive_onto(handle, producer)
end

-- ── Binding a projector to lib/http/server.lua ───────────────────────────

-- Translate a projector fetch function into an `HttpHandlerFn`. The `toX`
-- shape: pure translation, starts nothing.
--
-- The request is converted to a value up front (`request_from_server`, which is
-- where the multi-valued query parse happens), the fetch function runs, its
-- result is awaited when it is a promise, and the response value is
-- materialized. A fetch function that raises, or that resolves to something
-- that is not a response value, produces a 500 rather than dropping the
-- connection: the connection core has no error path of its own, so a handler
-- that raises would leave the client waiting.
--: (fetch: FetchFn) -> (req: AdapterRequest, res: AdapterResponse, sock: AdapterSocket) -> (boolean | nil)
function M.handler_from_fetch(fetch)
	return function(req, res, sock)
		local rv = value.request_from_server(req)
		local ok, outcome = pcall(fetch, rv)
		if not ok then
			res.status = 500
			res.reason = "Internal Server Error"
			res.headers = {}
			res.body = nil
			return true
		end
		-- A fetch function may be synchronous (its value straight back) or
		-- async (a promise). Awaiting only in the latter case keeps a purely
		-- synchronous projector free of any event-loop requirement, the same
		-- convention direct.lua's leaf callables follow.
		local settled = outcome
		if is_promise(outcome) then
			local await_ok, awaited = pcall(async.await, outcome)
			if not await_ok then
				res.status = 500
				res.reason = "Internal Server Error"
				res.headers = {}
				res.body = nil
				return true
			end
			settled = awaited
		end
		if not value.is_response_value(settled) then
			res.status = 500
			res.reason = "Internal Server Error"
			res.headers = {}
			res.body = nil
			return true
		end
		M.materialize(settled, res, sock)
		return true
	end
end

-- Bind a projector fetch function to `lib/http/server.lua` — the `serveX`
-- shape. `opts` is forwarded verbatim (host, TLS key pair, keep-alive levers);
-- see lib/http/server.lua's `mod.server` for the full set. The epoll poller is
-- a parameter rather than something created here, per conventions.md: the
-- caller owns the event loop.
-- Mirrors lib/http/server.lua's own `mod.server` opts parameter field for
-- field, for the same unify-without-a-cast reason as the views above.
--:: AdapterServeOpts = { host: string | nil, tls_cert: string | nil, tls_key: string | nil, idle_timeout: number | nil, max_requests: integer | nil, loop: unknown | nil }
--: (fetch: FetchFn, port: integer | nil, epoll: unknown | nil, opts: AdapterServeOpts | nil) -> unknown
function M.serve(fetch, port, epoll, opts)
	return server.server(M.handler_from_fetch(fetch), port, epoll, opts)
end

return M
