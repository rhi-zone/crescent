-- lib/fractal/jsonrpc_client.lua — the runtime JSON-RPC client, ported from
-- fractal's packages/json-rpc-api-projector/src/client.ts.
--
-- `client_from_tree(tree, call)` walks a Node tree and returns a nested table
-- mirroring its shape — a branch becomes a table, a leaf becomes a callable
-- returning a promise, and a `fallback` becomes a `(slug_value) -> sub_client`
-- function keyed by the fallback's name. Built from the RAW tree, so the
-- client's method-name derivation cannot drift from what
-- `jsonrpc_project.project_methods` — and, transitively, jsonrpc_server.lua's
-- dispatch table — actually exposes. Name derivation mirrors that module
-- exactly: DOT-joined tree position, `meta.jsonrpc.name`/`.segment` read the
-- same way.
--
-- The shape is deliberately direct.lua's, not a second convention:
--
--   branch    -> a nested client table, keyed by its own tree key (never by a
--                `meta.jsonrpc.segment` override — that affects the derived
--                method NAME, never the navigation key)
--   fallback  -> `(value) -> sub_client`, keyed by `fallback.name`, capturing
--                the slug into a params bag every leaf beneath it merges into
--                its own call: `client.books.bookId("b-1").get()` calls
--                `"books.bookId.get"` with `params = { bookId = "b-1" }`
--   leaf      -> `(input) -> promise`, dispatching
--                `call(name, merge(slugs, input))`
--
-- TRANSPORT. `call` is injected, never created here — the convention every
-- protocol library in this repo follows. `call_from_post` builds one over a
-- `post` cap the caller supplies (a function that takes one request body and
-- returns one response body), so this module opens no sockets and knows no
-- URLs; those belong to whatever the caller injects. The TypeScript source's
-- `createJsonRpcHttpCall` reaches for a global `fetch`, which has no analogue
-- here and would be a caps violation if it did.
--
-- FAILURE. A JSON-RPC error Response rejects the returned promise with the
-- error OBJECT (`{ code, message, data? }`) — the TS source throws a
-- `JsonRpcClientError` carrying the same value, and Lua has no exception class
-- to be the difference. A transport failure rejects with whatever the injected
-- `post` reported, unchanged: it is not a JSON-RPC error and is not dressed up
-- as one. A response that is not a JSON-RPC Response object at all rejects
-- with a message saying so.

if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local async   = require("lib.async")
local json    = require("lib.format.json")
local project = require("lib.fractal.jsonrpc_project")

local M = {}

--:: NodeView = { handler?: (input: unknown) -> unknown, children?: { [string]: NodeView }, fallback?: { name: string, subtree: NodeView }, meta: { [string]: unknown } }
--:: PromiseView = { _state: string, ... }

-- One JSON-RPC call, transport-agnostic: params are always by-name (see
-- jsonrpc_server.lua's dispatch, which reads no positional form). Returns the
-- successful `result`, or a promise of it.
--:: JsonRpcCall = (method: string, params: { [string]: unknown }) -> unknown

-- The nested client. Values are sub-clients, leaf callables, or fallback
-- functions — a heterogeneous table, so the caller narrows what it pulled out,
-- exactly as with direct.lua's projection.
--:: ClientTable = { [string]: unknown }

--:: Slugs = { [string]: string }

-- A request body sender: hands one serialized JSON-RPC Request to the peer and
-- returns the serialized Response, or (nil, err). May block or yield; a
-- yield-aware transport works unchanged, since this is called from inside an
-- async coroutine.
--:: PostFn = (body: string) -> (string | nil, string | nil)

--:: ClientOptions = { id: (() -> unknown) | nil }

--: (v: unknown) -> v is PromiseView
local function is_promise(v)
	if type(v) ~= "table" then return false end
	return (v --[[: { [string]: unknown }]])._state ~= nil
end

--: (v: unknown) -> v is string
local function is_string(v)
	return type(v) == "string"
end

--: (node: NodeView) -> boolean
local function is_leaf(node)
	return node.handler ~= nil
end

-- Merge captured slug values into the caller's input, slugs first so an
-- explicit field wins on conflict — the same precedence path params take in
-- `assemble`, and the same direct.lua reproduces.
--
-- A non-nil input that is not a record is rejected rather than merged: params
-- here are by-name only, so there is no reading under which a string or a
-- number is a params bag. (The TS source spreads it, which silently produces
-- an index-keyed object.)
--: (slugs: Slugs, input: unknown) -> { [string]: unknown }
local function merge_slugs(slugs, input)
	local out = {} --: { [string]: unknown }
	for k, v in pairs(slugs) do out[k] = v end
	if input == nil then return out end
	if type(input) ~= "table" then
		error("fractal.jsonrpc_client: params must be a record — JSON-RPC params are by-name only")
	end
	for k, v in pairs(input --[[: { [string]: unknown }]]) do out[k] = v end
	return out
end

-- Wrap one leaf as an async callable. `call` may itself be synchronous (an
-- in-process implementation), so its return is awaited only when it is a
-- promise — the same guard direct.lua's `make_caller` uses.
--: (call: JsonRpcCall, name: string, slugs: Slugs) -> (input: unknown) -> unknown
local function make_caller(call, name, slugs)
	return async.async(function(input)
		local out = call(name, merge_slugs(slugs, input))
		if is_promise(out) then return async.await(out) end
		return out
	end)
end

--: (slugs: Slugs, name: string, value: string) -> Slugs
local function extend_slugs(slugs, name, value)
	local out = {} --: Slugs
	for k, v in pairs(slugs) do out[k] = v end
	out[name] = value
	return out
end

-- The leaf's method name: its `meta.jsonrpc.name` override, else the dot-joined
-- tree position.
--: (node: NodeView, prefix: string, key: string) -> string
local function method_name(node, prefix, key)
	local jr = project.overrides_from_meta(node.meta)
	local override = jr.name
	if is_string(override) then return override end
	if #prefix > 0 then return prefix .. "." .. key end
	return key
end

--: (node: NodeView, prefix: string, call: JsonRpcCall, slugs: Slugs) -> ClientTable
local function build_client(node, prefix, call, slugs)
	local client = {} --: ClientTable

	local children = node.children
	if children ~= nil then
		for key, child in pairs(children) do
			if is_leaf(child) then
				client[key] = make_caller(call, method_name(child, prefix, key), slugs)
			else
				local child_jr = project.overrides_from_meta(child.meta)
				local segment = child_jr.segment
				local raw_seg = key
				if is_string(segment) then raw_seg = segment end
				local seg = raw_seg
				if #prefix > 0 then seg = prefix .. "." .. raw_seg end
				client[key] = build_client(child, seg, call, slugs)
			end
		end
	end

	local fallback = node.fallback
	if fallback ~= nil then
		local fallback_name = fallback.name
		local seg = fallback_name
		if #prefix > 0 then seg = prefix .. "." .. fallback_name end
		local subtree = fallback.subtree

		-- A `fallback.subtree` may be a bare leaf, not only a branch — the same
		-- case jsonrpc_project.lua handles in its walk. Building a client over a
		-- bare leaf would read `subtree.children` (absent) and hand back an empty
		-- table with nothing callable, so when the subtree IS the leaf the
		-- fallback function returns that leaf's OWN caller directly.
		if is_leaf(subtree) then
			client[fallback_name] = function(value)
				local jr = project.overrides_from_meta(subtree.meta)
				local override = jr.name
				local name = seg
				if is_string(override) then name = override end
				return make_caller(call, name, extend_slugs(slugs, fallback_name, value))
			end
		else
			client[fallback_name] = function(value)
				return build_client(subtree, seg, call, extend_slugs(slugs, fallback_name, value))
			end
		end
	end

	return client
end

-- Build a client over `tree`, dispatching every leaf call through `call`.
--: (tree: NodeView, call: JsonRpcCall) -> ClientTable
function M.client_from_tree(tree, call)
	return build_client(tree, "", call, {})
end

-- ── A call over an injected request/response transport ───────────────────

-- Build a `JsonRpcCall` that frames a Request object, hands it to `post`, and
-- reads back one Response — the shape jsonrpc_server.lua's HTTP transport
-- serves (one endpoint, every method, addressing inside the payload).
--
-- `opts.id` generates the request id, called once per call; the default is an
-- incrementing counter starting at 1, which is enough correlation for one
-- client instance over one connection. The id is not otherwise used: a
-- request/response transport correlates by position, and the response's own id
-- is passed through untouched rather than checked, since a peer that answers
-- the wrong id has already broken the correlation this cannot repair.
--: (post: PostFn, opts: ClientOptions | nil) -> JsonRpcCall
function M.call_from_post(post, opts)
	local counter = 0
	local next_id = (opts ~= nil and opts.id) or nil

	return async.async(function(method, params)
		local id = nil --: unknown
		if next_id ~= nil then
			id = next_id()
		else
			counter = counter + 1
			id = counter
		end

		local body = json.encode({ jsonrpc = "2.0", method = method, params = params, id = id })
		if body == nil then
			error("fractal.jsonrpc_client: params are not JSON-encodable")
		end

		local raw, post_err = post(body)
		if raw == nil then
			error(post_err or "fractal.jsonrpc_client: transport returned no response")
		end

		local decoded = json.decode(raw)
		if type(decoded) ~= "table" then
			error("fractal.jsonrpc_client: response is not a JSON-RPC Response object")
		end
		local response = decoded --[[: { [string]: unknown }]]
		local err_obj = response.error
		if err_obj ~= nil then
			error(err_obj)
		end
		return response.result
	end)
end

return M
