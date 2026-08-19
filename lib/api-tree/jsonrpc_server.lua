-- lib/api-tree/jsonrpc_server.lua — the two transport adapters and the dispatch
-- core they share, ported from fractal's
-- packages/json-rpc-api-projector/src/server.ts.
--
-- `http_handler_from_tree` serves JSON-RPC over HTTP POST as a lib/http/server
-- handler; `ws_handler_from_tree` serves it over a WebSocket connection as a
-- lib/http/server_ws `ws` handler. Both are built from
-- `jsonrpc_project.project_methods`, and both share the dispatch core below —
-- method lookup, input assembly, the handler call, and result/error shaping —
-- so the adapters differ only in how a raw payload becomes a parsed body and
-- how a response or notification gets sent back, never in dispatch semantics.
--
-- WHY THIS DOES NOT USE lib/jsonrpc. `lib/jsonrpc` is crescent's general
-- JSON-RPC 2.0 dispatcher, and its handler contract is `handler(params)` —
-- one argument, no request identity. This projector's WebSocket transport
-- needs the originating request's `id` INSIDE the call, to stamp it as the
-- `subscription` field of every notification a streaming handler produces (see
-- "Streaming" below). Passing the id as a second argument to
-- `lib/jsonrpc`-registered handlers was rejected: Lua silently accepts extra
-- arguments, so every existing single-argument handler across lib/mcp, lib/lsp
-- and lib/jsonrpc's own tests would keep typechecking and keep running while
-- the contract underneath them changed — and lib/lsp passes handlers straight
-- through to ITS consumers, propagating the change past this repo with nothing
-- to catch it. So this module owns its dispatch instead, and with it the parts
-- of the JSON-RPC 2.0 specification lib/jsonrpc otherwise owns: batching (§6),
-- the notification/request distinction (§4.1), and error framing with the
-- standard codes (§5.1). The reimplementation is what jsonrpc_server_test.lua
-- tests against the specification's own worked examples, not against
-- lib/jsonrpc's test shapes — divergence from the spec is the risk this
-- structure trades for correct id correlation, so it is the risk under test.
--
-- BATCHING (§6). A parsed body is either one Request object or an array of
-- them. An empty array is itself an Invalid Request ("If the batch rpc call
-- itself fails to be recognized ... the Server MUST return a single Response
-- object"). A non-empty array dispatches each element independently and
-- concurrently — one element's slow or failing handler does not block the
-- others — and collects the responses of the non-Notification elements. If
-- every element was a Notification the response array would be empty; §6
-- forbids returning one ("the Server MUST NOT return an empty Array"), so
-- dispatch returns nil and each adapter renders that as "send nothing" (HTTP:
-- 204 No Content; WebSocket: nothing written).
--
-- EMPTY ARRAY vs EMPTY OBJECT. Lua cannot tell `[]` from `{}` after decoding
-- (both are an empty table; the same conflation every codec in this repo
-- documents). It costs nothing here: §6's empty-batch response and §4.2's
-- response to a non-Request object are byte-identical — Invalid Request,
-- id null — so the two paths that would need telling apart produce the same
-- message. The empty table simply falls through to the single-request path.
--
-- STREAMING. A handler returning a `lib/api-tree/stream` Stream is drained
-- differently per transport, since only one of them has a push channel:
--   - WebSocket: each emission becomes a Notification whose params carry
--     `subscription = <the originating call's id>`, the same
--     subscription-keyed convention production JSON-RPC pub/sub extensions
--     use. When the stream ends, the original request's id still receives an
--     ordinary Response carrying the stream's TERMINAL value as `result` —
--     symmetric with a non-streaming call, so a client that only awaits the
--     call still resolves normally whether or not it also listens for the
--     notifications.
--   - HTTP POST: no push channel exists mid-request, so the stream is drained
--     to completion and its collected chunk values become the single
--     Response's `result` array, with the terminal value appended last.
--     Progress effects are dropped — they have no synchronous consumer over a
--     request/response transport. A lossy but honest degrade.
--
-- ERROR MAPPING. Framework-level failures (malformed JSON, malformed Request
-- shape, unknown method) use the standard codes from jsonrpc_wire.lua. A
-- handler's own `result.err` value is transport-agnostic, so an
-- `error_encoder` maps it to a `{ code, message, data }` envelope;
-- app-specific codes are conventionally drawn from the -32000..-32099
-- server-error range (§5.1) so they never collide with a spec-reserved code.
-- `error_encoder_from_codes` builds one from a `{ [kind] = code }` mapping. An
-- encoder returning nil — including when no encoder was supplied — falls back
-- to INVALID_PARAMS carrying the raw error value as `data`. A handler that
-- RAISES is never surfaced verbatim: it collapses to a generic Internal error,
-- matching the TypeScript projectors' shared default. Returning `err(...)` is
-- the way to convey a client-facing failure, and that one IS conveyed
-- verbatim.
--
-- CAPS. Neither adapter creates a transport. `http_handler_from_tree` returns
-- a handler for a server the caller already has; `ws_handler_from_tree`
-- returns a message pump for a connection the caller already accepted. Both
-- are handed their socket by lib/http/server, which is the injected transport
-- in this arrangement.

if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local async   = require("lib.async")
local json    = require("lib.format.json")
local api_tree = require("lib.api-tree")
local input   = require("lib.api-tree.input")
local result  = require("lib.api-tree.result")
local stream  = require("lib.api-tree.stream")
local wire    = require("lib.api-tree.jsonrpc_wire")
local project = require("lib.api-tree.jsonrpc_project")

--:: require "lib.http.server"
--:: require "lib.http.server_ws"

local M = {}

-- ── Local structural views ───────────────────────────────────────────────
--
-- Cross-module named types are not yet supported for lib/api-tree's own
-- modules, so the shapes this file reads out of its siblings are declared
-- here, the way tags.lua/direct.lua/stream_test.lua each declare theirs. The
-- lib/http types above come in through the `--:: require` form, which is
-- supported.

--:: NodeView = { handler?: (input: unknown) -> unknown, children?: { [string]: NodeView }, fallback?: { name: string, subtree: NodeView }, meta: { [string]: unknown } }
--:: ParamSource = { store: string, key?: string }
--:: SourceMap = { [string]: ParamSource }
--:: Dispatch = { handler: (input: unknown) -> unknown, source_map: SourceMap, meta: { [string]: unknown } }
--:: DispatchTable = { [string]: Dispatch }
--:: JsonSchema = { [string]: unknown }
--:: MethodSchema = { paramsSchema?: JsonSchema, resultSchema?: JsonSchema, description?: string }
--:: SchemaMap = { [string]: MethodSchema }

-- A Request that has already passed `wire.is_request_shape`, so `method` is
-- known to be a string. `id` absent means Notification.
--:: RequestView = { jsonrpc: string, method: string, params?: unknown, id?: unknown }

--:: StreamView = { kind: "stream", next: () -> unknown }
--:: PromiseView = { _state: string, ... }

-- The error envelope an encoder produces. `data` is what the encoder chose to
-- carry, not necessarily the raw error.
--:: JsonRpcErrorObject = { code: number, message: string, data?: unknown }
--:: JsonRpcErrorEncoder = (error_value: unknown) -> (JsonRpcErrorObject | nil)

-- Opt-in return-value detection, mirroring the `detection` option every other
-- fractal projector takes. Both default true.
--:: DetectionOptions = { result?: boolean, streaming?: boolean }

--:: ServerOptions = { schemas?: SchemaMap, detection?: DetectionOptions, error_encoder?: JsonRpcErrorEncoder }

-- The resolved per-dispatch options. `send_notification` is present only for
-- the WebSocket transport — its presence is what selects the
-- notification-streaming path over HTTP's drain-to-array degrade, exactly as
-- in the TS source.
--:: RunOptions = { detect_result: boolean, detect_streaming: boolean, error_encoder: JsonRpcErrorEncoder | nil, send_notification: ((n: { [string]: unknown }) -> nil) | nil }

-- ── Error encoding ───────────────────────────────────────────────────────

-- The `message` an encoded error carries: the error value's own `message`
-- field when that is a string, else the error JSON-encoded. An error the JSON
-- encoder cannot serialize (a function, a cycle) still has to produce SOME
-- message, so it degrades to `tostring` rather than failing the call — the
-- value itself still travels intact as the envelope's `data`.
--: (error_value: unknown) -> string
local function message_of_error(error_value)
	if type(error_value) == "table" then
		local field = (error_value --[[: { [string]: unknown }]]).message
		if type(field) == "string" then return field end
	end
	local encoded = json.encode(error_value)
	if encoded ~= nil then return encoded end
	return tostring(error_value)
end

-- Build an encoder mapping error `kind` values to JSON-RPC error codes, e.g.
-- `error_encoder_from_codes({ notFound = -32001 })`. The `message` is the
-- error value's own `message` field when that is a string, else the error
-- JSON-encoded; the FULL error value is always carried as `data`, so nothing
-- is lost even when `message` degrades to the JSON dump. Internally a
-- `compose_error_encoders` over one `match_kind` per entry — first match wins.
--
-- Iteration order over `mapping` is Lua's, not authored order, so "first match
-- wins" is only observable when two entries could match the same error; they
-- cannot, since `match_kind` compares one `kind` field for equality.
--: (mapping: { [string]: number }) -> JsonRpcErrorEncoder
function M.error_encoder_from_codes(mapping)
	local encoders = {} --: { [integer]: (error_value: unknown) -> unknown }
	local n = 0
	for kind, code in pairs(mapping) do
		n = n + 1
		encoders[n] = result.match_kind(kind, code)
	end
	local composed = result.compose_error_encoders(unpack(encoders, 1, n))

	--: (error_value: unknown) -> (JsonRpcErrorObject | nil)
	return function(error_value)
		local code = composed(error_value)
		if type(code) ~= "number" then return nil end
		return { code = code, message = message_of_error(error_value), data = error_value }
	end
end

-- ── Dispatch core ────────────────────────────────────────────────────────

--: (v: unknown) -> v is PromiseView
local function is_promise(v)
	if type(v) ~= "table" then return false end
	return (v --[[: { [string]: unknown }]])._state ~= nil
end

--: (v: unknown) -> v is RequestView
local function as_request(v)
	return wire.is_request_shape(v)
end

--: (v: unknown) -> v is StreamView
local function as_stream(v)
	return stream.is_stream(v)
end

--: (v: unknown) -> v is { kind: string, value: unknown, error: unknown }
local function as_result(v)
	return result.is_result_shape(v)
end

--: (v: unknown) -> v is { [string]: unknown }
local function as_record(v)
	return type(v) == "table"
end

-- A decoded JSON array — a batch (§6). Uses `lib/api-tree`'s `is_array`, under
-- which an empty table is NOT an array; see the module doc's EMPTY ARRAY vs
-- EMPTY OBJECT note for why that costs nothing here.
--: (v: unknown) -> v is { [integer]: unknown }
local function as_list(v)
	if type(v) ~= "table" then return false end
	return api_tree.is_array(v)
end

-- The `id` to answer a malformed request with: the value the sender put in
-- `id` when the payload was an object carrying one, else null (§5: an error
-- that cannot be correlated to a request id reports id null).
--: (raw: unknown) -> unknown
local function id_of_malformed(raw)
	if not as_record(raw) then return wire.NULL end
	if api_tree.is_array(raw) then return wire.NULL end
	local id = raw.id
	if id == nil then return wire.NULL end
	return id
end

-- Drain a stream over the WebSocket push channel: one Notification per
-- emission, each stamped with `subscription = id`, and resolve with the
-- stream's terminal value (which becomes the originating call's `result`).
--: (s: StreamView, method: string, id: unknown, send: (n: { [string]: unknown }) -> nil) -> unknown
local function drive_to_notifications(s, method, id, send)
	--: (effect: unknown) -> nil
	local function on_progress(effect)
		if not as_record(effect) then return end
		-- `total ?? 1` on the TS side: a progress effect with no declared total
		-- is reported against a unit total rather than omitting the field, so a
		-- client always has a denominator.
		local total = effect.total
		if total == nil then total = 1 end
		local params = {
			type = "progress",
			subscription = id,
			progress = effect.progress,
			total = total,
			message = effect.message,
		}
		send({ jsonrpc = "2.0", method = method, params = params })
	end

	--: (value: unknown) -> nil
	local function on_chunk(value)
		send({ jsonrpc = "2.0", method = method, params = { type = "chunk", subscription = id, value = value } })
	end

	return stream.drive(s, { progress = on_progress, chunk = on_chunk })
end

-- The HTTP degrade: drain a stream to completion, collecting chunk payloads
-- into an array, and append the terminal value last when there is one.
-- Progress effects are dropped by supplying no progress arm — `stream.drive`
-- documents that omission as the correct behavior for a transport with no
-- progress channel.
--
-- A chunk carrying nil is dropped rather than becoming a hole in the array;
-- the TS `out.push(value)` would leave `undefined`, which `JSON.stringify`
-- renders as `null`. Emitting nil is degenerate either way — a stream that
-- means "null" emits the null sentinel.
local drain_to_array = async.async(function(s)
	local out = {} --: { [integer]: unknown }

	--: (value: unknown) -> nil
	local function on_chunk(value)
		if value == nil then return end
		out[#out + 1] = value
	end

	local terminal = async.await(stream.drive(s, { progress = nil, chunk = on_chunk }))
	if terminal ~= nil then out[#out + 1] = terminal end
	return out
end)

-- Call one resolved handler and shape its return value into a Response (or
-- nil for a Notification). Everything that can fail on behalf of the caller
-- lives in here, so `dispatch_one`'s single pcall around it reproduces the TS
-- source's single try/catch — LuaJIT permits yielding across pcall, so the
-- awaits below are unaffected by being protected.
--: (dispatch: Dispatch, req: RequestView, id: unknown, is_notification: boolean, opts: RunOptions) -> unknown
local function run_dispatch(dispatch, req, id, is_notification, opts)
	-- By-name params only. A positional (array) `params` degrades to an empty
	-- object rather than attempting positional-to-name mapping, which would
	-- need the method's own params schema threaded down here just to recover
	-- argument order. §4 permits either structure; this projector documents
	-- by-name as its contract, the same call type-ir's json-rpc projection
	-- makes when it always emits an object params schema.
	local params_obj = {} --: { [string]: unknown }
	local raw_params = req.params
	if as_record(raw_params) and not api_tree.is_array(raw_params) then
		params_obj = raw_params
	end

	local stores = { params = params_obj, caller = {} } --: { [string]: { [string]: unknown } }

	-- Every param the request supplied, plus every param the leaf redirects
	-- through a source override — deduplicated, since a name may be in both.
	local param_names = {} --: { [integer]: string }
	local seen = {} --: { [string]: boolean }
	for name in pairs(params_obj) do
		if not seen[name] then
			seen[name] = true
			param_names[#param_names + 1] = name
		end
	end
	for name in pairs(dispatch.source_map) do
		if not seen[name] then
			seen[name] = true
			param_names[#param_names + 1] = name
		end
	end

	local input_bag = input.assemble(stores, param_names, dispatch.source_map, "params", nil)

	local value = dispatch.handler(input_bag)
	if is_promise(value) then value = async.await(value) end

	if opts.detect_streaming and as_stream(value) then
		local send = opts.send_notification
		if send ~= nil then
			value = async.await(drive_to_notifications(value, req.method, id, send))
		else
			value = async.await(drain_to_array(value))
		end
	end

	-- Result detection runs AFTER streaming, on whatever streaming produced:
	-- a stream's terminal `err(...)` becomes this call's error response. Over
	-- HTTP the terminal value has by then been folded into the collected
	-- array, so it is not unwrapped — the drain is the degrade, and this is
	-- the shape of it.
	if opts.detect_result and as_result(value) then
		if value.kind == "err" then
			if is_notification then return nil end
			local encoder = opts.error_encoder
			if encoder ~= nil then
				local encoded = encoder(value.error)
				if encoded ~= nil then
					return wire.error_response(id, encoded.code, encoded.message, encoded.data)
				end
			end
			return wire.error_response(id, wire.INVALID_PARAMS, "Invalid params", value.error)
		end
		value = value.value
	end

	if is_notification then return nil end
	return wire.success_response(id, value)
end

-- Dispatch ONE Request or Notification object. Resolves with a Response, or
-- with nil when nothing is to be sent back (a Notification, per §4.1).
local dispatch_one = async.async(function(handlers, raw, opts)
	if not as_request(raw) then
		return wire.error_response(id_of_malformed(raw), wire.INVALID_REQUEST, "Invalid Request", nil)
	end

	-- `id` absent is a Notification (§4.1). An `id` present and null is an
	-- ordinary Request answered with `"id": null` — see jsonrpc_wire.lua's
	-- NULL vs ABSENT note for why those two are distinguishable here.
	local is_notification = raw.id == nil
	local id = raw.id
	if id == nil then id = wire.NULL end

	local dispatch = (handlers --[[: DispatchTable]])[raw.method]
	if dispatch == nil then
		if is_notification then return nil end
		return wire.error_response(id, wire.METHOD_NOT_FOUND, "Method not found: " .. raw.method, nil)
	end

	local ok, response = pcall(run_dispatch, dispatch, raw, id, is_notification, opts)
	if not ok then
		-- A raised error is never surfaced verbatim; see the module doc's
		-- ERROR MAPPING note.
		if is_notification then return nil end
		return wire.error_response(id, wire.INTERNAL_ERROR, "Internal error", nil)
	end
	return response
end)

-- Dispatch a parsed body: one Request object or a batch array (§6). Resolves
-- with a Response, an array of Responses, or nil when nothing is to be sent.
local dispatch_body = async.async(function(handlers, body, opts)
	if as_list(body) then
		local list = body
		local pending = {} --: { [integer]: unknown }
		for i = 1, #list do
			pending[i] = dispatch_one(handlers, list[i], opts)
		end
		local settled = async.await(async.all(pending)) --[[: { [integer]: unknown }]]
		local responses = {} --: { [integer]: unknown }
		for i = 1, #list do
			local r = settled[i]
			if r ~= nil then responses[#responses + 1] = r end
		end
		if #responses > 0 then return responses end
		return nil
	end
	return async.await(dispatch_one(handlers, body, opts))
end)

--: (opts: ServerOptions, send_notification: ((n: { [string]: unknown }) -> nil) | nil) -> RunOptions
local function resolve_run_options(opts, send_notification)
	-- Both default true, so only an explicit `false` changes anything — which
	-- is also what lets the read sidestep the `boolean | nil` a `?:` field
	-- yields.
	local detection = opts.detection
	local detect_result = true
	local detect_streaming = true
	if detection ~= nil then
		if detection.result == false then detect_result = false end
		if detection.streaming == false then detect_streaming = false end
	end
	return {
		detect_result = detect_result,
		detect_streaming = detect_streaming,
		error_encoder = opts.error_encoder,
		send_notification = send_notification,
	}
end

--: (tree: NodeView, opts: ServerOptions) -> DispatchTable
local function handlers_of(tree, opts)
	return project.project_methods(tree, { schemas = opts.schemas }).handlers
end

-- ── HTTP POST transport ──────────────────────────────────────────────────

-- Serialize `value` as the response body. An encoding failure (a handler
-- returned something with a cycle, or a function) has no JSON-RPC message to
-- carry it, so it collapses to an uncorrelated Internal error rather than
-- raising out of the handler — raising would kill the connection coroutine,
-- which is a worse answer to "this one call produced an unserializable
-- result".
--: (res: http_server_response, value: unknown) -> nil
local function write_json(res, value)
	local body = json.encode(value)
	if body == nil then
		body = json.encode(wire.error_response(wire.NULL, wire.INTERNAL_ERROR, "Internal error", nil))
	end
	res.status = 200
	res.reason = "OK"
	res.headers["content-type"] = { "application/json" }
	res.body = body
end

-- Build an HTTP POST handler for `tree`, suitable for lib/http/server (or
-- lib/http/server_ws's `http` slot). Every request carries a JSON-RPC Request
-- object or batch array as its body; the method is NOT read from the URL —
-- JSON-RPC addressing lives entirely inside the payload, so every call goes to
-- the same endpoint.
--
-- A malformed (or absent) body is a Parse error (§4.2, -32700). A body that is
-- neither a Request-shaped object nor a batch array is an Invalid Request
-- (§4.2, -32600). Both are ordinary 200 responses carrying a JSON-RPC error
-- object: the HTTP status describes the HTTP exchange, which succeeded.
--
-- A lone Notification, or a batch made entirely of Notifications, answers 204
-- No Content — the conventional HTTP rendering of §6's "no Response objects".
-- NOTE: lib/http/format's `serialize_response` synthesizes `content-length: 0`
-- for a bodyless response, which RFC 9112 §6.2 forbids on a 204. Suppressing
-- it is that serializer's call to make, not this handler's — see TODO.md.
--: (tree: NodeView, opts: ServerOptions | nil) -> HttpHandlerFn
function M.http_handler_from_tree(tree, opts)
	local o = opts or {} --: ServerOptions
	local handlers = handlers_of(tree, o)
	local run_opts = resolve_run_options(o, nil)

	--: (req: http_server_request, res: http_server_response, sock: http_client_sock) -> (boolean | nil)
	return function(req, res, _sock)
		local body = req.body
		local decoded = nil --: unknown
		if body ~= nil and #body > 0 then
			decoded = json.decode(body)
		end
		if decoded == nil then
			write_json(res, wire.error_response(wire.NULL, wire.PARSE_ERROR, "Parse error", nil))
			return nil
		end

		local out = async.await(dispatch_body(handlers, decoded, run_opts))
		if out == nil then
			res.status = 204
			res.reason = "No Content"
			return nil
		end
		write_json(res, out)
		return nil
	end
end

-- ── WebSocket transport ──────────────────────────────────────────────────

-- Handle one received frame payload. Runs as its own async task so several
-- calls can be in flight on one connection at once: the message pump below
-- does not await this, which is what makes a streaming call's notifications
-- interleave with other calls' traffic instead of stalling the pump until the
-- stream ends. That interleaving is the whole reason the WebSocket transport
-- exists.
local handle_ws_message = async.async(function(handlers, opts, ws_conn, payload)
	local conn = ws_conn --[[: WsConn]]
	local decoded = json.decode(payload)
	if decoded == nil then
		local parse_error = json.encode(wire.error_response(wire.NULL, wire.PARSE_ERROR, "Parse error", nil))
		if parse_error ~= nil then conn:send(parse_error, nil) end
		return nil
	end

	--: (n: { [string]: unknown }) -> nil
	local function send_notification(n)
		local encoded = json.encode(n)
		if encoded ~= nil then conn:send(encoded, nil) end
	end

	local run_opts = resolve_run_options(opts --[[: ServerOptions]], send_notification)
	local out = async.await(dispatch_body(handlers, decoded, run_opts))
	if out ~= nil then
		local encoded = json.encode(out)
		if encoded ~= nil then conn:send(encoded, nil) end
	end
	return nil
end)

-- Build a WebSocket message pump for `tree`, suitable for lib/http/server_ws's
-- `ws` slot. One connection dispatches every message it receives against the
-- SAME tree; there is no per-connection state beyond what the tree's own
-- handlers close over. A consumer needing per-connection identity (auth,
-- session) bakes it into those handlers, not into this pump.
--
-- The pump returns when the peer closes or the connection errors, at which
-- point lib/http/server_ws closes the socket.
--: (tree: NodeView, opts: ServerOptions | nil) -> WsHandlerFn
function M.ws_handler_from_tree(tree, opts)
	local o = opts or {} --: ServerOptions
	local handlers = handlers_of(tree, o)

	--: (ws_conn: WsConn, req: http_server_request) -> nil
	return function(ws_conn, _req)
		while true do
			local msg = ws_conn:recv()
			if msg == nil then return end
			-- Control frames never reach here — lib/http/server_ws answers
			-- ping and close itself — so anything delivered is a data frame,
			-- text or binary, and both carry a JSON payload.
			handle_ws_message(handlers, o, ws_conn, msg.payload)
		end
	end
end

return M
