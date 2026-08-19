-- lib/api-tree/http_value.lua — the request/response VALUE model the HTTP
-- projector composes over. Ported from the WHATWG `Request`/`Response` shape
-- that fractal's packages/http-api-projector/src/* passes between layers
-- (layers.ts's `Fetch = (req: Request) => Promise<Response>`, preset.ts's
-- middleware chain, route.ts's `runRoute`).
--
-- WHY THIS MODULE EXISTS. The TypeScript side composes over a RETURNED,
-- REBUILDABLE value. `corsLayer` receives the inner handler's `Response` and
-- builds a new one from it:
--
--     const out = new Response(res.body, { status: res.status, ... })
--     out.headers.set("Access-Control-Allow-Origin", allowedOrigin)
--
-- That `new Response(res.body, …)` never reads, tees, or drains the body — for
-- a streaming response `res.body` is a `ReadableStream` whose production is
-- pull-driven by the eventual consumer, so re-wrapping status and headers
-- around the SAME body reference costs nothing and forces no early
-- materialization. Every layer in the stack (CORS, auto-method, subtree
-- middleware, tracing, idempotency) relies on that property.
--
-- Crescent's HTTP contract is the opposite shape: `HttpHandlerFn` is
-- `(req, res, sock) -> boolean|nil` and a handler MUTATES `res` in place, with
-- `lib/http/server.lua`'s connection core serializing whatever `res` holds when
-- the handler returns. A handler that mutates a shared `res` cannot be composed
-- the way a layer stack needs: there is no "old response" left to rebuild a new
-- one from, and a streaming handler must seize the socket immediately
-- (`mod.response_stream(res, sock)` sets `res.raw`), which happens BEFORE the
-- outer layers have had their chance to wrap it.
--
-- So this module supplies the missing middle: a DEFERRED-PRODUCER response
-- value that is not tied to a socket at all.
--
--   - A non-streaming response is a plain data table — status, headers, body
--     text. Layers rebuild it freely via `M.rebuild`, which allocates a new
--     table and carries the SAME body reference across, exactly as the TS side
--     does. Nothing is written anywhere.
--
--   - A streaming response carries a `lib/api-tree/stream.lua` Stream in place
--     of body text. That Stream is the deferred producer: per stream.lua's
--     documented semantics it runs NOTHING until the first `next()`, emits in
--     lockstep with its consumer, and buffers nothing. It is therefore safe to
--     pass a streaming response value up through the whole layer stack — being
--     wrapped, re-headered, and re-statused any number of times — without a
--     single byte being produced.
--
-- MATERIALIZATION HAPPENS ONCE, AT THE BOUNDARY. Turning one of these values
-- into real bytes on a real socket is `lib/api-tree/http_adapter.lua`'s job and
-- nothing else's: a plain value is copied into `res` and serialized through the
-- server's ordinary managed path; a streaming value switches to
-- `mod.response_stream(res, sock)` and drives its Stream. Both happen strictly
-- AFTER every layer has already transformed the value. That is what preserves
-- fractal's compositional model — CORS, subtree middleware, and everything
-- else apply uniformly to streaming and non-streaming responses alike — while
-- touching the real socket exactly once.
--
-- WHAT A STREAM EMITS HERE. Byte strings, already framed. SSE framing
-- (`event:`/`data:` lines) is the ROUTE layer's concern, the same place the
-- TypeScript keeps it (`streamAsSse` in route.ts), not this module's: a
-- streaming response value is transport-mechanical and says only "these bytes,
-- over time".
--
-- HEADERS ARE MULTI-VALUED. `{ [string]: string[] }`, matching
-- `lib/http/format.lua`'s parse output and `lib/http/server.lua`'s request and
-- response shapes. Repeated fields (`set-cookie`, `vary`, `link`) are carried
-- natively rather than flattened into a comma-joined scalar — the flattening
-- the WHATWG `Headers` object imposes and that this port deliberately does not
-- reproduce. Field names are lowercased on the way in, since HTTP field names
-- are case-insensitive (RFC 9110 §5.1) and the rest of the repo already
-- normalizes them that way.

if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local json   = require("lib.format.json")
local stream = require("lib.api-tree.stream")
local url     = require("lib.url")

local M = {}

-- ── Types ────────────────────────────────────────────────────────────────

-- Multi-valued header bag, keyed by LOWERCASED field name. Same shape as
-- lib/http/format.lua produces and lib/http/server.lua consumes, so no
-- translation is needed at the boundary.
--:: HttpHeaders = { [string]: string[] }

-- The request as the projector sees it. Crescent has no single absolute-URL
-- string the way `new URL(req.url)` gives the TS side, so the pieces the TS
-- side derives from that URL are carried directly instead:
--
--   path   — the request target's path, slug-matched by the router.
--   query  — the parsed query string, MULTI-VALUED (lib/url's
--            `parse_query_multi`), so a repeated param survives round-tripping
--            through a rebuilt link. `lib/url.parse_query` is last-wins and
--            would silently collapse `?tag=a&tag=b`.
--   scheme/host/port — the connection origin, from lib/http/server.lua's
--            `http_server_request` (RFC 9112 §3.3). `host` is nil when the
--            server genuinely has no configured host name; a caller that needs
--            an absolute URL must handle that rather than fabricate one.
--:: HttpRequestValue = { method: string, path: string, query: { [string]: string[] }, headers: HttpHeaders, body: string | nil, scheme: string, host: string | nil, port: integer | nil }

-- The two response body arms. `kind` is a literal type on each, so
-- `body.kind == "stream"` narrows at a read site without a cast — the same
-- reason result.lua's Result arms and stream.lua's StreamStep arms are written
-- this way.
--
-- A plain body's `text` is nil for a genuinely bodyless response (204, 304,
-- 1xx, and a HEAD derived from a GET). That is distinct from `""`, an empty
-- body that still exists.
--:: HttpBodyPlain = { kind: "plain", text: string | nil }

-- The deferred producer. `producer` is a lib/api-tree/stream.lua Stream whose
-- emissions are byte strings. Nothing in it has run when this value is
-- constructed and nothing runs while it is passed through layers.
--:: HttpBodyStream = { kind: "stream", producer: unknown }

--:: HttpBody = HttpBodyPlain | HttpBodyStream

--:: HttpResponseValue = { status: integer, reason: string, headers: HttpHeaders, body: HttpBody }

-- What a constructor or `rebuild` may override. Every field is optional;
-- an omitted field keeps whatever the source value had (or the constructor
-- default, for a fresh response).
--:: HttpResponseInit = { status?: integer, reason?: string, headers?: HttpHeaders }

-- ── Header helpers ───────────────────────────────────────────────────────
--
-- All of these are PURE: none mutates its argument. A layer that "sets a
-- header on the response" is really building a new response, and these return
-- new bags so that stays true by construction rather than by discipline.

--: (name: string) -> string
local function norm(name)
	return name:lower()
end

-- Copy a header bag, deep enough that mutating the copy's value arrays cannot
-- reach the original's. The value arrays are copied, not shared, because the
-- append helpers below build on this.
--: (headers: HttpHeaders) -> HttpHeaders
function M.copy_headers(headers)
	--: HttpHeaders
	local out = {}
	for name, values in pairs(headers) do
		--: { [integer]: string }
		local copied = {}
		for i = 1, #values do copied[i] = values[i] end
		out[name] = copied
	end
	return out
end

-- Build a header bag from a name→value map, where each value is a single
-- string. The ergonomic constructor form, mirroring the TS
-- `{ headers: { Allow: "GET, POST" } }` object-literal idiom. Names are
-- lowercased; a caller needing repeated fields builds the array shape directly
-- or uses `M.append_header`.
--: (pairs_map: { [string]: string }) -> HttpHeaders
function M.headers_from_map(pairs_map)
	--: HttpHeaders
	local out = {}
	for name, value in pairs(pairs_map) do
		out[norm(name)] = { value }
	end
	return out
end

-- First value of a field, or nil when the field is absent. The read a caller
-- wants for a single-valued field (`content-type`, `origin`).
--: (headers: HttpHeaders, name: string) -> string | nil
function M.get_header(headers, name)
	local values = headers[norm(name)]
	if values == nil then return nil end
	return values[1]
end

-- Every value of a field, in wire order. Empty table when absent — a caller
-- iterating repeated fields never needs a nil guard.
--: (headers: HttpHeaders, name: string) -> string[]
function M.get_header_all(headers, name)
	local values = headers[norm(name)]
	if values == nil then return {} end
	--: { [integer]: string }
	local out = {}
	for i = 1, #values do out[i] = values[i] end
	return out
end

--: (headers: HttpHeaders, name: string) -> boolean
function M.has_header(headers, name)
	return headers[norm(name)] ~= nil
end

-- Replace a field outright, dropping every existing value. Returns a NEW bag.
--: (headers: HttpHeaders, name: string, value: string) -> HttpHeaders
function M.set_header(headers, name, value)
	local out = M.copy_headers(headers)
	out[norm(name)] = { value }
	return out
end

-- Add a value to a field, keeping any already there. Returns a NEW bag. This
-- is what `set-cookie` and `vary` need and what a flattened scalar bag cannot
-- express.
--: (headers: HttpHeaders, name: string, value: string) -> HttpHeaders
function M.append_header(headers, name, value)
	local out = M.copy_headers(headers)
	local key = norm(name)
	local values = out[key]
	if values == nil then
		out[key] = { value }
	else
		values[#values + 1] = value
	end
	return out
end

-- Remove a field entirely. Returns a NEW bag.
--
-- Built by copying everything EXCEPT the removed field rather than by copying
-- then assigning nil: a `{ [string]: string[] }` index signature does not admit
-- nil as a value type, so `out[k] = nil` is a type error even though it is the
-- idiomatic Lua way to delete a key. Skipping on the way out says the same
-- thing and stays inside the declared type.
--: (headers: HttpHeaders, name: string) -> HttpHeaders
function M.remove_header(headers, name)
	local key = norm(name)
	--: HttpHeaders
	local out = {}
	for field, values in pairs(headers) do
		if field ~= key then
			--: { [integer]: string }
			local copied = {}
			for i = 1, #values do copied[i] = values[i] end
			out[field] = copied
		end
	end
	return out
end

-- Merge `overrides` over `base`, per field: a field present in `overrides`
-- REPLACES the base's values for that field rather than appending to them.
-- This is the `new Headers(base)` + `.set(...)` sequence the TS layers perform,
-- in one step.
--: (base: HttpHeaders, overrides: HttpHeaders) -> HttpHeaders
function M.merge_headers(base, overrides)
	local out = M.copy_headers(base)
	for name, values in pairs(overrides) do
		--: { [integer]: string }
		local copied = {}
		for i = 1, #values do copied[i] = values[i] end
		out[norm(name)] = copied
	end
	return out
end

-- ── Constructing a response value ────────────────────────────────────────

local status_reasons = require("lib.http.status").status_names

--: (status: integer, reason: string | nil) -> string
local function reason_for(status, reason)
	if reason ~= nil then return reason end
	return status_reasons[status] or ""
end

--: (init: HttpResponseInit | nil) -> HttpHeaders
local function init_headers(init)
	if init == nil then return {} end
	local h = init.headers
	if h == nil then return {} end
	return M.copy_headers(h)
end

-- A plain (non-streaming) response. `text` is the whole body, or nil for a
-- bodyless response. Defaults to 200 with an empty header bag.
--: (text: string | nil, init: HttpResponseInit | nil) -> HttpResponseValue
function M.response(text, init)
	local status = (init and init.status) or 200
	return {
		status  = status,
		reason  = reason_for(status, init and init.reason),
		headers = init_headers(init),
		body    = { kind = "plain", text = text },
	}
end

-- A JSON response — `value` serialized, with `content-type: application/json`
-- supplied only when the caller did not already set one. Ported from
-- project.ts's `jsonResponse`, including that "don't clobber an explicit
-- content-type" rule.
--
-- Returns `(nil, errmsg)` when `value` cannot be serialized, per the repo's
-- error convention: an unserializable handler return is a data error, not a
-- programming error, and callers (route.ts's encode stage) turn it into a 500
-- rather than crashing the connection.
--: (value: unknown, init: HttpResponseInit | nil) -> (HttpResponseValue | nil, string | nil)
function M.json_response(value, init)
	local text, err = json.encode(value)
	if text == nil then
		return nil, "api_tree.http_value: response body is not JSON-serializable: " .. tostring(err)
	end
	local res = M.response(text --[[: string]], init)
	if not M.has_header(res.headers, "content-type") then
		res.headers["content-type"] = { "application/json" }
	end
	return res
end

-- A streaming response. `producer` is a lib/api-tree/stream.lua Stream emitting
-- byte strings. NOTHING in it runs here, or at any point before
-- `http_adapter.materialize` drives it — that laziness is the whole point (see
-- the module doc).
--
-- Errors rather than returning `(nil, err)` on a non-Stream argument: passing
-- something that is not a Stream is a programming error at the construction
-- site, not a data error (conventions.md's split).
--: (producer: unknown, init: HttpResponseInit | nil) -> HttpResponseValue
function M.stream_response(producer, init)
	if not stream.is_stream(producer) then
		error("api_tree.http_value: stream_response requires a lib/api-tree/stream Stream")
	end
	local status = (init and init.status) or 200
	return {
		status  = status,
		reason  = reason_for(status, init and init.reason),
		headers = init_headers(init),
		body    = { kind = "stream", producer = producer },
	}
end

-- ── Rebuilding a response value ──────────────────────────────────────────

-- THE compositional primitive. Build a new response value from an existing
-- one, overriding status/reason/headers and carrying the SAME body reference
-- across — the direct analogue of `new Response(res.body, { status, headers })`
-- on the TypeScript side, and safe for the same reason: a streaming body is a
-- deferred producer, so re-wrapping it neither starts nor consumes it.
--
-- `init.headers`, when given, REPLACES the header bag wholesale (matching
-- `new Response(body, { headers: new Headers(res.headers) })`, where the caller
-- has already decided what the new bag is). A layer that wants to add one
-- header to the existing set composes: `rebuild(res, { headers =
-- set_header(res.headers, "vary", "origin") })`.
--
-- `reason` and `headers` are each resolved by a small helper rather than by an
-- uninitialized `local x --: T` followed by branch assignments: the checker
-- requires an annotated local to have an initializer (nil is not in `string`),
-- so a helper that RETURNS the resolved value is the shape that stays typed.
--: (res: HttpResponseValue, init: HttpResponseInit | nil, status: integer) -> string
local function rebuilt_reason(res, init, status)
	if init == nil then return res.reason end
	local explicit = init.reason
	if explicit ~= nil then return explicit end
	local new_status = init.status
	if new_status ~= nil and new_status ~= res.status then
		-- The status changed but no reason was supplied: the old reason phrase
		-- describes the OLD status and carrying it forward would produce
		-- `404 OK`. Re-derive from the new status instead.
		return reason_for(status, nil)
	end
	return res.reason
end

--: (res: HttpResponseValue, init: HttpResponseInit | nil) -> HttpHeaders
local function rebuilt_headers(res, init)
	if init ~= nil then
		local override = init.headers
		if override ~= nil then return M.copy_headers(override) end
	end
	return M.copy_headers(res.headers)
end

--: (res: HttpResponseValue, init: HttpResponseInit | nil) -> HttpResponseValue
function M.rebuild(res, init)
	local status = (init and init.status) or res.status
	return {
		status  = status,
		reason  = rebuilt_reason(res, init, status),
		headers = rebuilt_headers(res, init),
		body    = res.body,
	}
end

-- Strip the body, keeping status, reason, and headers EXACTLY as they are —
-- `content-length` included.
--
-- That preservation is spec compliance, not a choice: RFC 9110 §9.3.2 requires
-- a HEAD response's header fields to be identical to those the equivalent GET
-- would have sent, and names `Content-Length` specifically as describing the
-- length the GET's body WOULD have had. Recomputing it to 0 here would make a
-- HEAD report a different size than the resource it describes, which is the
-- exact failure the rule exists to prevent. This is `autoMethodLayer`'s
-- HEAD-from-GET step (layers.ts), where `new Response(null, { status,
-- statusText, headers: new Headers(res.headers) })` preserves the same way.
--
-- A streaming body is discarded WITHOUT being driven — the producer is
-- deferred, so dropping the reference is sufficient and no bytes are ever
-- produced.
--: (res: HttpResponseValue) -> HttpResponseValue
function M.without_body(res)
	return {
		status  = res.status,
		reason  = res.reason,
		headers = M.copy_headers(res.headers),
		body    = { kind = "plain", text = nil },
	}
end

-- ── Detection ────────────────────────────────────────────────────────────

-- The opt-in runtime sniff, mirroring `is_result_shape` (result.lua),
-- `is_page_shape` (page.lua), and `is_stream` (stream.lua). Requires the
-- `body` sub-table to carry a recognized `kind`, so a plain data table that
-- happens to have a numeric `status` does not false-positive.
--: (v: unknown) -> boolean
function M.is_response_value(v)
	if type(v) ~= "table" then return false end
	local t = v --[[: { [string]: unknown }]]
	if type(t.status) ~= "number" then return false end
	local body = t.body
	if type(body) ~= "table" then return false end
	local kind = (body --[[: { [string]: unknown }]]).kind
	return kind == "plain" or kind == "stream"
end

-- True when this response will stream. The one check `http_adapter` branches
-- on, and the check a layer uses when it must know (a layer that would have to
-- read the body — content-encoding, say — cannot, and must say so rather than
-- silently draining a deferred producer).
--: (res: HttpResponseValue) -> boolean
function M.is_streaming(res)
	return res.body.kind == "stream"
end

-- ── Request values ───────────────────────────────────────────────────────

-- Build a request value from lib/http/server.lua's `http_server_request`.
--
-- The target is split into path and query here rather than by the caller,
-- because the split is where the multi-valued query parse belongs: a request
-- target is the only place a repeated param arrives, and every downstream
-- consumer (route matching, the `query` store, `pageLinkHeader`'s
-- preserve-the-other-params step) reads the parsed form.
--
-- A target with no `?` yields an empty query table, not nil, so no read site
-- needs a nil guard.
--
-- The parameter carries the `...` structural-subtyping marker: a real
-- `http_server_request` has a `version` field this function has no use for, and
-- a closed record type would reject it as an excess field. `...` states what is
-- actually required — these fields, at least — which is the same thing
-- lib/http/server.lua's own `http_client_sock` declaration says about a real
-- accepted socket.
--: (sreq: { method: string, target: string, headers: HttpHeaders, body: string | nil, scheme: string, host: string | nil, port: integer | nil, ... }) -> HttpRequestValue
function M.request_from_server(sreq)
	local target = sreq.target
	local qpos = target:find("?", 1, true)
	local path = qpos == nil and target or target:sub(1, qpos - 1)
	local query_string = qpos == nil and "" or target:sub(qpos + 1)
	return {
		method  = sreq.method,
		path    = path,
		query   = url.parse_query_multi(query_string),
		headers = sreq.headers,
		body    = sreq.body,
		scheme  = sreq.scheme,
		host    = sreq.host,
		port    = sreq.port,
	}
end

-- Reconstruct the absolute URL of a request — the RFC 9112 §3.3 target URI,
-- and this port's replacement for the TS side's `req.url` string.
--
-- Returns `(nil, errmsg)` when the origin has no host: `http_server_request`
-- documents nil host as a legitimate state (the server has no configured host
-- name and the client sent no `Host` field), and an absolute URL genuinely
-- cannot be formed from it. Fabricating "localhost" would invent an authority
-- the server never claimed. Callers that only need a path (route matching)
-- read `req.path` and never come here; callers that need an absolute URL
-- (`Link: rel="next"`, redirect `Location`) must handle the nil.
--
-- The port is omitted when it is the scheme's default, matching lib/url's own
-- normalization. The query is rebuilt from the PARSED multi-valued form via
-- `build_query_multi`, so repeated params survive and key order is
-- deterministic — the established precedent throughout this port, and required
-- under LuaJIT's randomized hash iteration.
--: (req: HttpRequestValue, override_query: { [string]: string[] } | nil) -> (string | nil, string | nil)
function M.request_url(req, override_query)
	local host = req.host
	if host == nil then
		return nil, "api_tree.http_value: cannot build an absolute URL — the request has no host (no Host field and no configured server host name)"
	end
	local q = override_query or req.query
	local query_string = url.build_query_multi(q)
	-- `host` comes from the Host field verbatim when present, so it may already
	-- carry a ":port". Re-appending the bound port would produce "h:8080:8080";
	-- the field's own authority wins, exactly as RFC 9112 §3.3 orders it.
	--: integer | nil
	local port = nil
	if host:find(":", 1, true) == nil then
		local p = req.port
		if p ~= nil and not ((req.scheme == "http" and p == 80) or (req.scheme == "https" and p == 443)) then
			port = p
		end
	end
	return url.build({
		scheme   = req.scheme,
		userinfo = nil,
		host     = host,
		port     = port,
		path     = req.path,
		query    = query_string ~= "" and query_string or nil,
		fragment = nil,
	})
end

return M
