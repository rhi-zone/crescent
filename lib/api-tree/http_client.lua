-- lib/api-tree/http_client.lua — the runtime HTTP client, ported from
-- fractal's packages/http-api-projector/src/client.ts (with
-- client-error.ts folded in, see "THE ERROR VALUE" below).
--
-- WHAT THIS IS. An ENUMERATING projection, not a dispatching one: it walks a
-- whole already-projected route tree ONCE at construction time and builds a
-- nested table of callables whose shape mirrors the tree's own structure.
-- After the route rewriters have run, the tree's structure IS the URL
-- structure — a child key is a path segment, `fallback` is the wildcard
-- segment, and `methods` is already keyed by the resolved HTTP verb — so no
-- segment inference, verb derivation, or dispatch-marker interpretation
-- happens here at all.
--
--   client.books.list()                     -- GET  /books
--   client.books.add({ title = "x" })       -- POST /books
--   client.books.book_id("b-1").read()      -- GET  /books/b-1
--
-- A route position with exactly one method and no children and no fallback
-- collapses to a bare callable; every other position becomes a table. A
-- `fallback` becomes a function keyed by `fallback.name` that takes the slug
-- value and returns the sub-client for the bound subtree, with the slug
-- substituted into the path immediately rather than templated and filled
-- later.
--
-- ── THE TRANSPORT IS AN INJECTED CAP, WITH NO DEFAULT ────────────────────
--
-- The TypeScript client defaults `opts.fetch` to the ambient global `fetch`.
-- This port has no such default and will not acquire one. There is no ambient
-- fetch in crescent, and reaching for one — including lazily requiring an HTTP
-- client module inside the call — is precisely the violation the caps rule
-- names: `opts.transport or <anything>` is itself the bug, not a convenience.
-- A client constructed without `opts.transport` ERRORS at construction.
--
-- That is not merely compliance; it is what makes the client testable. A
-- transport is `(req) -> response | promise-of-response` over
-- `http_value.lua`'s value model, which is the SAME shape the server side's
-- fetch function has — so an in-process round-trip test wires the two together
-- directly, with no socket, no loop, and no network, exactly as fractal's own
-- `createFetch(tree)` preset does.
--
-- ── CANCELLATION: WHAT WAS BUILT AND WHY ─────────────────────────────────
--
-- The TypeScript relies on three WHATWG primitives that have no analogue here:
-- `AbortSignal.timeout(ms)` (a signal that fires itself on a timer),
-- `AbortController` (external cancellation), and `AbortSignal.any([...])` (a
-- signal that fires when any input does). `lib/async`'s `M.race` covers only
-- the narrow "first of these promises wins" case and carries no notion of a
-- cancellation source, so the source side is genuinely new design. What this
-- module defines:
--
--   CancelToken — the `AbortSignal` analogue, tagged `kind = "cancel_token"`
--     like every other DU in this port. It exposes `aborted()`, `reason()`,
--     and `subscribe(listener) -> unsubscribe`. `subscribe` fires the listener
--     IMMEDIATELY when the token is already aborted, so a caller never has to
--     write the check-then-subscribe race by hand.
--
--   M.cancel_source() -> (token, abort) — the `AbortController` analogue,
--     shaped like `lib/async`'s own `M.promise() -> (promise, resolve, reject)`:
--     the capability to abort is a separate value from the token that observes
--     it, so handing a call the token does not hand it the ability to cancel
--     its siblings. `abort(reason)` is idempotent.
--
--   TimerFn — `opts.timer`, a cap `(ms) -> promise-resolving-after-ms`. A
--     timeout needs a clock, a clock is I/O, and I/O is injected here like
--     everywhere else; `lib/async`'s own `sleep` already requires an explicit
--     loop for the same reason. Setting `timeout` WITHOUT `timer` errors — a
--     silently-never-firing timeout is worse than a rejected construction.
--
-- ENFORCEMENT IS THE CLIENT'S, NOT THE TRANSPORT'S. A transport that knows how
-- to abort in-flight I/O is not required to exist. The call's own promise is
-- raced against the timeout and the abort, so it settles the instant either
-- fires no matter what the transport does. The token is ALSO passed to the
-- transport (as `req.cancel`) so a cooperative transport can stop early and
-- release its socket; a transport that ignores the field is still correctly
-- cancelled from the caller's point of view, it merely finishes its work
-- unobserved. This split is stated plainly because it is the one place the
-- port cannot match `AbortSignal`'s guarantee: WHATWG `fetch` genuinely tears
-- down the connection, and only a cooperative transport does that here.
--
-- FRESH PER CALL. The timer is started inside the call, never at construction.
-- A timer armed once at construction would only ever fire on a client's first
-- slow call — the same trap `AbortSignal.timeout` has, and the reason the TS
-- creates its signal per call too. The abort subscription is likewise
-- per-call, and is UNSUBSCRIBED when the call settles: a client-level token
-- outlives every individual call, and a listener list that only grows is a
-- leak proportional to request count.
--
-- PER-CALL OPTIONS REPLACE, THEY DO NOT MERGE. A call's own `timeout`/`cancel`
-- each override the client-level value for that field. Nothing is combined:
-- there is no "client signal AND call signal, whichever fires first" the way
-- `AbortSignal.any` would give. A per-call value is a statement about THIS
-- call, and quietly re-adding the client's default underneath it would make
-- "just this one request, on its own terms" unexpressible.
--
-- TIMEOUT AND ABORT REPORT DIFFERENTLY. Two distinct messages, because they
-- are two distinct facts a caller acts on differently — a timeout is a
-- retryable statement about the server, an abort is a statement about the
-- caller's own intent, and collapsing them into one "cancelled" would destroy
-- exactly the distinction the TS `describeAbort` exists to preserve.
--
-- ── THE ERROR VALUE ──────────────────────────────────────────────────────
--
-- client-error.ts is folded in here rather than given its own file: it is one
-- 16-line class whose only consumers are this module (which raises it) and
-- this module's callers (who inspect it). A separate file would carry a module
-- doc longer than the thing it documents.
--
-- The TS `class ClientError extends Error` becomes a tagged record raised into
-- the call's promise rejection, with `M.is_client_error` as the narrowing
-- predicate. It is NOT a `(nil, errmsg)` return: a leaf callable returns a
-- promise, so its failure channel is that promise's rejection, and the status
-- and decoded body must survive as structured fields rather than be flattened
-- into a message string. Timeout and abort reject with plain strings — they
-- carry no structure beyond what their message already says.
--
-- ── DELIBERATE DIVERGENCES FROM THE TYPESCRIPT ───────────────────────────
--
-- NO TYPE-LEVEL CLIENT SHAPE. Roughly a third of client.ts is the
-- `AnyClient`/`RouteClient`/`IsSingleKey`/`RouteMethodsObject` machinery that
-- computes the client's static shape from the route tree's own type. That is
-- conditional-type computation over literal key unions and has no analogue in
-- this type system, so it is absent rather than approximated. The runtime
-- construction is UNCHANGED — the TS builds dynamically too and casts at the
-- boundary — and the constructed value is typed `unknown`, exactly as
-- `direct.lua`'s `create_direct_api` types its proxy. A typed surface is
-- codegen's job on both sides.
--
-- `create_client(node, opts)` IS NOT HERE YET. The TS has two entry points:
-- the core walks an already-projected route tree, and the convenience wrapper
-- projects a `Node` through the standard rewriter pipeline first. That
-- pipeline lives in the route module, which is being ported separately, so the
-- wrapper cannot be written yet. What the wrapper actually ADDS is available
-- now: pass the original `Node` as `opts.node` and this client walks it once to
-- recover authored member names and codegen names (see the next two notes).
-- Once the pipeline lands, `create_client(node, opts)` is
-- `create_client_from_route(http_projection(node), { node = node, ... })`.
--
-- CO-LOCATED MEMBER NAMES. When the route rewriters move several operations
-- onto one position (read/replace/remove all landing on the same fallback),
-- the route tree remembers only the resolved verbs — the authored child keys
-- are gone. `opts.node` restores them via a handler-IDENTITY map, so unrelated
-- handlers that happen to share a key name elsewhere in the tree never
-- collide. Without `opts.node` those members degrade to the lowercased verb
-- (`.get()`/`.put()`/`.delete()`), which is still correct, just less
-- conventional — the same graceful degradation the TS documents.
--
-- CODEGEN NAMES. A SEPARATE convention from member names: the full
-- underscore-joined path from the root (`books_book_id_read`), which is the key
-- a schema map is indexed by. Also derived from `opts.node`, and handed to
-- extensions through `DecodeContext.codegen_name` so an extension can find its
-- own per-operation entry without re-deriving tree-position naming.
--
-- QUERY PARAMS DO NOT COLLAPSE. The TS puts a GET/HEAD/DELETE input into the
-- URL with `searchParams.set(k, String(v))` — one value per key, and
-- `String([1,2])` silently flattening an array to `"1,2"`. This port builds the
-- multi-valued bag `lib/url`'s `build_query_multi` consumes: an array-valued
-- input field becomes REPEATED params, which is what the whole multi-valued
-- header/query substrate exists for. A nested non-array table is reported as
-- an error rather than stringified — `tostring` would emit a Lua table
-- address, which is worse than useless, and inventing a nesting convention
-- here would be minting wire semantics this port has no mandate for.
--
-- A SLUG IS PERCENT-ENCODED. The TS runtime proxy interpolates a slug value
-- into the path raw, while fractal's own codegen path emits
-- `encodeURIComponent(...)` for the same position. Those disagree, and raw
-- interpolation corrupts any slug containing `/` or `?`; this port follows the
-- codegen path, which is the one that is right.
--
-- BASE URL IS A PREFIX, ALWAYS. The TS is internally inconsistent: the
-- body-carrying branch concatenates (`${baseUrl}${path}`) while the query
-- branch resolves (`new URL(path, baseUrl)`), which DROPS a base URL's path
-- component since `path` is absolute. For a bare origin — the only form the
-- option's own doc comment describes ("base URL prepended to every request
-- path") — the two agree, so the disagreement is latent rather than
-- load-bearing. This port concatenates in both branches.
--
-- CONTEXT IS PASSED, NEVER LOOKED UP. Everything the TS threads as ten
-- positional parameters through `makeCaller`/`buildClientNode` is bundled into
-- one immutable `ClientContext`, closure-captured per call site. There is no
-- ambient request-scoped lookup anywhere in this module.
--
-- See:
--   lib/api-tree/http_value.lua           — the request/response value model
--   lib/api-tree/http_client_extension.lua — the extension protocol
--   lib/api-tree/stream.lua               — what a streaming body carries

if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local async = require("lib.async")
local ext   = require("lib.api-tree.http_client_extension")
local json  = require("lib.format.json")
local url   = require("lib.url")
local value = require("lib.api-tree.http_value")

local M = {}

-- ── Structural views ─────────────────────────────────────────────────────
--
-- Cross-module named types are not yet supported by the checker, so each
-- module declares the shapes it reads — the same reason `http_adapter.lua`
-- declares `AdapterResponse`/`AdapterSocket` and `tags.lua` declares
-- `NodeView`. The route views below carry the `...` structural-subtyping
-- marker rather than mirroring the route module field-for-field: that module
-- is not written yet, and `...` states honestly what this one actually
-- requires — these fields, at least — instead of asserting an exact shape it
-- cannot check.

--:: HandlerFn = (input: unknown) -> unknown

-- One resolved operation at a route position. `meta` is the leaf's own
-- accumulated meta bag, handed to extensions verbatim.
--:: RouteMethodEntry = { handler: HandlerFn, meta: { [string]: unknown }, ... }

-- A projected route position. Every field but `meta` is optional, and the
-- three optional ones are exactly the client's three construction cases: a
-- method entry becomes a callable, a child recurses under its path segment,
-- and a fallback becomes a slug-taking function.
--:: RouteView = { methods?: { [string]: RouteMethodEntry }, children?: { [string]: RouteView }, fallback?: { name: string, subtree: RouteView }, meta: { [string]: unknown }, ... }

-- The raw authored tree, only ever walked to recover names. Identical in shape
-- to `direct.lua`'s `NodeView` and `init.lua`'s `Node`.
--:: NodeView = { handler?: HandlerFn, children?: { [string]: NodeView }, fallback?: { name: string, subtree: NodeView }, meta: { [string]: unknown }, ... }

-- `lib/async`'s promise, structurally — the same declaration `direct.lua`
-- makes, for the same reason: `is_promise` must narrow an `unknown` transport
-- return without a cast.
--
-- The three chaining methods are declared here even though `lib/async` puts
-- them on a metatable rather than in its own `PromiseP` alias (which relies on
-- `...` to admit them). A narrowed value can only be called through members
-- the view actually names, so a view that omitted them would narrow
-- successfully and then reject `p:and_then(...)` on the next line.
--:: PromiseView = { _state: string, value: unknown, reason: unknown, _on_fulfill: { [integer]: (v: unknown) -> unknown }, _on_reject: { [integer]: (v: unknown) -> unknown }, _on_finally: { [integer]: () -> unknown }, and_then: (self: PromiseView, fn: (v: unknown) -> unknown) -> PromiseView, catch: (self: PromiseView, fn: (r: unknown) -> unknown) -> PromiseView, finally: (self: PromiseView, fn: () -> unknown) -> PromiseView, ... }

-- The response value this module reads. Mirrors `http_value.lua`'s
-- `HttpResponseValue`, with the body union flattened into one optional-field
-- record for the same reason `http_adapter.lua` flattens it: a union arm is
-- selected by `kind` at the read site either way.
--:: ResponseView = { status: integer, reason: string, headers: { [string]: string[] }, body: { kind: string, text?: string, producer?: unknown } }

-- ── Cancellation ─────────────────────────────────────────────────────────

--:: CancelListener = (reason: string) -> nil

-- The `AbortSignal` analogue — see the module doc for the whole design.
--:: CancelToken = { kind: "cancel_token", aborted: () -> boolean, reason: () -> (string | nil), subscribe: (listener: CancelListener) -> (() -> nil) }

--:: AbortFn = (reason: string | nil) -> nil

-- Mutable state behind one token. `listeners` is sparse once anything
-- unsubscribes, which is why the notify loop below walks indices rather than
-- using `ipairs`.
--:: CancelState = { aborted: boolean, reason: string | nil, listeners: { [integer]: CancelListener | nil }, next_id: integer }

-- Create a cancellation source: a token to observe and a capability to abort.
-- Two values rather than one object with an `abort` method, so a call handed
-- the token cannot cancel anything — the same separation `async.promise()`
-- makes between a promise and its resolve/reject caps.
--
-- `abort(reason)` is idempotent; the first reason wins and later calls do
-- nothing. Defaults to "cancelled" when no reason is given.
--: () -> (CancelToken, AbortFn)
function M.cancel_source()
	--: CancelState
	local st = { aborted = false, reason = nil, listeners = {}, next_id = 1 }

	--: () -> boolean
	local function aborted()
		return st.aborted
	end

	--: () -> (string | nil)
	local function reason()
		return st.reason
	end

	--: (listener: CancelListener) -> (() -> nil)
	local function subscribe(listener)
		if st.aborted then
			-- Already aborted: fire now and hand back a no-op unsubscribe, so a
			-- caller never has to write the check-then-subscribe race itself.
			listener(st.reason or "cancelled")
			return function() end
		end
		local id = st.next_id
		st.next_id = id + 1
		st.listeners[id] = listener
		return function()
			st.listeners[id] = nil
		end
	end

	--: AbortFn
	local function abort(why)
		if st.aborted then return end
		st.aborted = true
		st.reason  = why or "cancelled"
		local final = st.reason or "cancelled"
		for i = 1, st.next_id - 1 do
			local listener = st.listeners[i]
			if listener ~= nil then
				st.listeners[i] = nil
				listener(final)
			end
		end
	end

	return { kind = "cancel_token", aborted = aborted, reason = reason, subscribe = subscribe }, abort
end

-- The opt-in runtime sniff, mirroring `is_stream`/`is_response_value`. Exact on
-- `kind` and requires the three callables, so neither user data carrying an
-- unrelated `kind` nor a bare `{ kind = "cancel_token" }` false-positives.
--: (v: unknown) -> boolean
function M.is_cancel_token(v)
	if type(v) ~= "table" then return false end
	local t = v --[[: { [string]: unknown }]]
	if t.kind ~= "cancel_token" then return false end
	return type(t.aborted) == "function" and type(t.reason) == "function" and type(t.subscribe) == "function"
end

-- ── The error value ──────────────────────────────────────────────────────

-- What a non-2xx response becomes. `body` is the DECODED body (parsed JSON
-- when the response said so, raw text otherwise) rather than the raw string,
-- matching the TS, which hands `ClientError` whatever its own decode produced.
--:: ClientError = { kind: "client_error", status: integer, body: unknown, message: string }

--: (status: integer, body: unknown) -> ClientError
function M.client_error(status, body)
	return {
		kind    = "client_error",
		status  = status,
		body    = body,
		message = "HTTP " .. tostring(status),
	}
end

--: (v: unknown) -> boolean
function M.is_client_error(v)
	if type(v) ~= "table" then return false end
	local t = v --[[: { [string]: unknown }]]
	return t.kind == "client_error" and type(t.status) == "number"
end

-- Narrowing wrapper over the public predicate above, so this module can read
-- `err.status` off a rejection reason without a cast. Same idiom as
-- `stream.lua`'s `is_chunk_effect` over `result.is_stream_chunk`.
--: (v: unknown) -> v is ClientError
local function as_client_error(v)
	return M.is_client_error(v)
end

--: (v: unknown) -> v is PromiseView
local function is_promise(v)
	if type(v) ~= "table" then return false end
	local t = v --[[: { [string]: unknown }]]
	return type(t._state) == "string"
end

-- ── Name maps from the authored tree ─────────────────────────────────────
--
-- Both maps are keyed by handler IDENTITY, not by name or path, which is what
-- makes them collision-free: two different resources each having a `list`
-- operation record two separate entries under two separate function values.

--:: NameMap = { [unknown]: string }

--: (n: NodeView) -> boolean
local function is_leaf_node(n)
	return n.handler ~= nil
end

-- Sorted key list, so every walk below visits children in a fixed order.
-- Nothing here depends on visit order for correctness — the maps are keyed by
-- identity — but LuaJIT randomizes hash iteration, and a walk whose order is
-- reproducible is the difference between a debuggable trace and a heisenbug.
--: (t: { [string]: unknown }) -> { [integer]: string }
local function sorted_keys(t)
	--: { [integer]: string }
	local out = {}
	for k in pairs(t) do out[#out + 1] = k end
	table.sort(out)
	return out
end

-- The OWN authored child key of each handler — `read`, not `books_book_id_read`.
-- Unlike a codegen name it need not be globally unique, because the client only
-- ever uses it as a member name at the one position the handler sits.
--: (n: NodeView, out: NameMap) -> nil
local function collect_handler_names(n, out)
	local children = n.children
	if children ~= nil then
		local keys = sorted_keys(children)
		for i = 1, #keys do
			local key   = keys[i]
			local child = children[key]
			if is_leaf_node(child) then
				local handler = child.handler
				if handler ~= nil then out[handler] = key end
			else
				collect_handler_names(child, out)
			end
		end
	end
	local fallback = n.fallback
	if fallback ~= nil then
		-- A fallback's subtree may be a BARE LEAF (`op(fn)`), not only a branch.
		-- Recursing unconditionally would find no children and silently drop the
		-- handler's name; key it by the fallback's own name instead, which is the
		-- fix every other projector in this port makes at the same spot.
		if is_leaf_node(fallback.subtree) then
			local handler = fallback.subtree.handler
			if handler ~= nil then out[handler] = fallback.name end
		else
			collect_handler_names(fallback.subtree, out)
		end
	end
end

-- Build the handler → authored-child-key map for a `Node` tree.
--: (n: NodeView) -> NameMap
function M.handler_names_from_node(n)
	--: NameMap
	local out = {}
	collect_handler_names(n, out)
	return out
end

--: (n: NodeView, prefix: string, out: NameMap) -> nil
local function collect_codegen_names(n, prefix, out)
	local children = n.children
	if children ~= nil then
		local keys = sorted_keys(children)
		for i = 1, #keys do
			local key   = keys[i]
			local child = children[key]
			local seg   = #prefix > 0 and (prefix .. "_" .. key) or key
			if is_leaf_node(child) then
				local handler = child.handler
				if handler ~= nil then out[handler] = seg end
			else
				collect_codegen_names(child, seg, out)
			end
		end
	end
	local fallback = n.fallback
	if fallback ~= nil then
		local seg = #prefix > 0 and (prefix .. "_" .. fallback.name) or fallback.name
		-- Same bare-leaf subtree case as above: key it at `seg` directly, adding
		-- no segment beyond the fallback's own name.
		if is_leaf_node(fallback.subtree) then
			local handler = fallback.subtree.handler
			if handler ~= nil then out[handler] = seg end
		else
			collect_codegen_names(fallback.subtree, seg, out)
		end
	end
end

-- Build the handler → full underscore-joined-path map for a `Node` tree. A
-- SEPARATE convention from the member-name map above: this one is the key a
-- schema map is indexed by, so it accumulates from the root and must be
-- globally unique.
--: (n: NodeView) -> NameMap
function M.codegen_names_from_node(n)
	--: NameMap
	local out = {}
	collect_codegen_names(n, "", out)
	return out
end

-- ── Options ──────────────────────────────────────────────────────────────

-- A timer cap: returns a promise that resolves after `ms` milliseconds.
-- `lib/async`'s `loop:sleep(ms)` satisfies this directly.
--:: TimerFn = (ms: number) -> unknown

--:: TransportFn = (req: unknown) -> unknown

--:: ClientExtensionList = { [integer]: unknown }

-- Client-level options. `transport` is the only required field — see the
-- module doc on why it has no default.
--
--   base_url    — prefix for every request path. Absent means a relative
--                 client with no origin at all (see `Origin` below).
--   transport   — the injected capability every call goes through.
--   timer       — required if and only if a timeout is ever used.
--   timeout     — per-request timeout in milliseconds, overridable per call.
--   cancel      — a token cancelling every call this client makes,
--                 overridable per call.
--   extensions  — composed once at construction, outermost first.
--   node        — the original authored tree, when available, to recover
--                 member names and codegen names.
--:: ClientOptions = { base_url?: string, transport: TransportFn, timer?: TimerFn, timeout?: number, cancel?: CancelToken, extensions?: ClientExtensionList, node?: NodeView }

-- Per-call overrides. Each field REPLACES its client-level counterpart for
-- this call; nothing is combined. See the module doc.
--:: CallOptions = { timeout?: number, cancel?: CancelToken }

-- The origin every request value is stamped with, resolved once from
-- `base_url` at construction.
--
-- `host` is nil for a client with no `base_url` — a relative client genuinely
-- has no authority, and `http_value.request_url` correctly refuses to build an
-- absolute URL from it rather than fabricating `localhost` the way the TS does
-- to satisfy the `URL` constructor. `scheme` still has to hold a string
-- because the request value's type requires one; with `host` nil it is inert,
-- read by nothing.
--:: Origin = { scheme: string, host: string | nil, port: integer | nil, prefix: string }

-- Everything a leaf callable needs that does not vary by route position,
-- resolved once and captured. Replaces the ten positional parameters the TS
-- threads through `makeCaller`/`buildClientNode`.
--:: ClientContext = { origin: Origin, transport: TransportFn, timer: TimerFn | nil, timeout: number | nil, cancel: CancelToken | nil, extensions: ClientExtensionList | nil, handler_names: NameMap | nil, codegen_names: NameMap | nil }

-- ── Resolving the origin ─────────────────────────────────────────────────

-- `lib/url`'s parse reports a port as a `number`, since Lua has one numeric
-- type; the request value's type says `integer`. The conversion is total: the
-- parser only ever fills this field from a run of digits, so `floor` is a type
-- conversion here and never a rounding decision.
--: (p: number | nil) -> (integer | nil)
local function port_from_parsed(p)
	if p == nil then return nil end
	return math.floor(p)
end

-- Resolve the origin once, at construction.
--
-- This cannot fail. `lib/url`'s parse is TOTAL — it accepts every string,
-- returning a parts record with whatever it could recognize — so there is no
-- malformed-base-url data error to report, and construction has no error
-- channel at all. A base URL the caller mistyped becomes a host or a path
-- prefix that no server answers, which surfaces at the transport rather than
-- here; inventing a validity check this port has no specification for would be
-- minting URL semantics rather than reading them.
--: (base_url: string | nil) -> Origin
local function origin_from_base_url(base_url)
	if base_url == nil or base_url == "" then
		return { scheme = "http", host = nil, port = nil, prefix = "" }
	end
	local parts = url.parse(base_url)
	if parts == nil then
		-- Unreachable while parse stays total; kept so a future stricter parser
		-- degrades to the origin-less client rather than indexing nil.
		return { scheme = "http", host = nil, port = nil, prefix = base_url }
	end
	local host = parts.host
	if host == nil then
		-- A base URL with no authority is a path prefix and nothing more; keep it
		-- as the prefix and stay origin-less rather than inventing a host.
		return { scheme = "http", host = nil, port = nil, prefix = base_url }
	end
	-- A trailing slash on the origin would produce `//books` once the route
	-- path (which always starts with `/`) is appended.
	local prefix = parts.path or ""
	if prefix == "/" then prefix = "" end
	return { scheme = parts.scheme or "http", host = host, port = port_from_parsed(parts.port), prefix = prefix }
end

-- ── Building the request value ───────────────────────────────────────────

-- Verbs whose input goes into the query string rather than a body. A body is
-- not conventional for any of them, which is the TS's own reasoning.
--: (verb: string) -> boolean
local function is_query_verb(verb)
	return verb == "GET" or verb == "HEAD" or verb == "DELETE"
end

--: (v: unknown) -> v is { [string]: unknown }
local function as_record(v)
	return type(v) == "table"
end

--: (v: unknown) -> v is { [integer]: unknown }
local function as_list(v)
	if type(v) ~= "table" then return false end
	local t = v --[[: { [string]: unknown }]]
	return t[1] ~= nil
end

-- One input field as query values. A scalar becomes one value; an array
-- becomes several, which is the whole point of the multi-valued bag (see the
-- module doc). Anything else has no defined encoding and says so.
--: (key: string, v: unknown) -> ({ [integer]: string } | nil, string | nil)
local function query_values(key, v)
	if as_list(v) then
		--: { [integer]: string }
		local out = {}
		for i = 1, #v do
			local item = v[i]
			if type(item) == "table" then
				return nil, "api_tree.http_client: query param '" .. key .. "' has a table element, which has no query encoding"
			end
			out[i] = tostring(item)
		end
		return out, nil
	end
	if type(v) == "table" then
		return nil, "api_tree.http_client: query param '" .. key .. "' is a table, which has no query encoding"
	end
	return { tostring(v) }, nil
end

-- The query bag for a read-only verb's input: every input field except the
-- ones already substituted into the path as slug values.
--
-- Keys are visited in sorted order. The bag itself is unordered and
-- `build_query_multi` sorts on the way out, so this matters only for WHICH
-- offending key gets reported first — but a nondeterministic error message is
-- still a nondeterministic observable.
--: (input: unknown, slugs: { [string]: boolean }) -> ({ [string]: string[] } | nil, string | nil)
local function query_from_input(input, slugs)
	--: { [string]: string[] }
	local query = {}
	if not as_record(input) then return query, nil end
	local keys = sorted_keys(input)
	for i = 1, #keys do
		local key = keys[i]
		if not slugs[key] then
			local v = input[key]
			if v ~= nil then
				local values, err = query_values(key, v)
				if values == nil then return nil, err end
				query[key] = values
			end
		end
	end
	return query, nil
end

-- Build the request value for one call. This is the whole of the TS's
-- `new Request(...)` construction, over the value model instead of WHATWG.
--: (origin: Origin, verb: string, path: string, slugs: { [string]: boolean }, input: unknown, cancel: CancelToken | nil) -> (unknown, string | nil)
local function build_request(origin, verb, path, slugs, input, cancel)
	local full_path = origin.prefix .. path
	if full_path == "" then full_path = "/" end
	if is_query_verb(verb) then
		local query, err = query_from_input(input, slugs)
		if query == nil then return nil, err end
		return {
			method  = verb,
			path    = full_path,
			query   = query,
			headers = {},
			body    = nil,
			scheme  = origin.scheme,
			host    = origin.host,
			port    = origin.port,
			cancel  = cancel,
		}, nil
	end
	local body_input = input
	if body_input == nil then body_input = {} end
	local text, encode_err = json.encode(body_input)
	if text == nil then
		return nil, "api_tree.http_client: request body is not JSON-serializable: " .. tostring(encode_err)
	end
	return {
		method  = verb,
		path    = full_path,
		query   = {},
		headers = { ["content-type"] = { "application/json" } },
		body    = text,
		scheme  = origin.scheme,
		host    = origin.host,
		port    = origin.port,
		cancel  = cancel,
	}, nil
end

-- ── Racing the call against timeout and abort ────────────────────────────

--: (verb: string, path: string, ms: number) -> string
local function timeout_message(verb, path, ms)
	return "api_tree.http_client: request timed out after " .. tostring(ms) .. "ms: " .. verb .. " " .. path
end

--: (verb: string, path: string, reason: string) -> string
local function abort_message(verb, path, reason)
	return "api_tree.http_client: request aborted (" .. reason .. "): " .. verb .. " " .. path
end

-- A promise that never resolves and rejects with `message` once `token`
-- aborts, plus the unsubscribe to run when the call settles.
--: (token: CancelToken, verb: string, path: string) -> (PromiseView, () -> nil)
local function abort_promise(token, verb, path)
	local p, _, reject = async.promise()
	local unsubscribe = token.subscribe(function(reason)
		reject(abort_message(verb, path, reason))
	end)
	return p, unsubscribe
end

-- A promise that rejects once `ms` elapses. The timer starts HERE, inside the
-- call — see the module doc on why a construction-time timer is a trap.
--: (timer: TimerFn, ms: number, verb: string, path: string) -> (PromiseView | nil, string | nil)
local function timeout_promise(timer, ms, verb, path)
	local sleeping = timer(ms)
	if not is_promise(sleeping) then
		return nil, "api_tree.http_client: opts.timer must return a promise"
	end
	-- The parameter is declared and unused: `and_then` hands its handler the
	-- resolved value, and a zero-parameter closure does not satisfy that shape.
	return sleeping:and_then(function(_elapsed)
		-- Level 0: the message is the whole rejection reason, with no source
		-- position prefixed onto it.
		error(timeout_message(verb, path, ms), 0)
	end), nil
end

-- ── Decoding the response ────────────────────────────────────────────────

--: (v: unknown) -> v is ResponseView
local function as_response(v)
	return value.is_response_value(v)
end

-- The client's own decode, run only when no extension claimed the response.
--
-- A STREAMING body is handed back as the stream itself. This case cannot arise
-- in the TS — a WHATWG body is always a stream and `.json()`/`.text()` simply
-- drain it — but here a deferred producer is the one thing that must not be
-- drained on its behalf: draining is what the whole laziness contract exists
-- to prevent, and whether these bytes are SSE frames, NDJSON, or something
-- else is knowledge this layer does not have. An extension that DOES know
-- (fractal's own `streaming()`) claims the response before this ever runs.
--: (res: ResponseView) -> (unknown, string | nil)
local function default_decode(res)
	local body = res.body
	if body.kind == "stream" then return body.producer, nil end
	local text = body.text
	if text == nil then return nil, nil end
	local content_type = value.get_header(res.headers, "content-type") or ""
	if content_type:find("application/json", 1, true) == nil then
		return text, nil
	end
	local decoded, err = json.decode(text)
	if err ~= nil then
		return nil, "api_tree.http_client: response is not valid JSON: " .. tostring(err)
	end
	return decoded, nil
end

-- ── The leaf caller ──────────────────────────────────────────────────────

-- One route position bound to a verb — everything that varies per callable.
--:: CallSite = { verb: string, path: string, slugs: { [string]: boolean }, ctx: ClientContext, meta: { [string]: unknown }, codegen_name: string | nil }

--: (site: CallSite, call_opts: CallOptions | nil) -> (number | nil)
local function resolved_timeout(site, call_opts)
	if call_opts ~= nil then
		local per_call = call_opts.timeout
		if per_call ~= nil then return per_call end
	end
	return site.ctx.timeout
end

--: (site: CallSite, call_opts: CallOptions | nil) -> (CancelToken | nil)
local function resolved_cancel(site, call_opts)
	if call_opts ~= nil then
		local per_call = call_opts.cancel
		if per_call ~= nil then return per_call end
	end
	return site.ctx.cancel
end

-- Send the request and settle with whichever of {transport, timeout, abort}
-- lands first. The transport is invoked exactly once regardless; racing does
-- not and cannot un-send it (see the module doc on cooperative cancellation).
--: (site: CallSite, req: unknown, timeout_ms: number | nil, token: CancelToken | nil) -> unknown
local function send(site, req, timeout_ms, token)
	local raw = site.ctx.transport(req)
	--: PromiseView
	local base = is_promise(raw) and raw or async.resolved(raw)

	if timeout_ms == nil and token == nil then return base end

	--: { [integer]: PromiseView }
	local racers = { base }
	--: { [integer]: () -> nil }
	local cleanups = {}

	if token ~= nil then
		local aborting, unsubscribe = abort_promise(token, site.verb, site.path)
		racers[#racers + 1]     = aborting
		cleanups[#cleanups + 1] = unsubscribe
	end

	if timeout_ms ~= nil then
		local timer = site.ctx.timer
		if timer == nil then
			-- Reached only when a per-call timeout is set on a client built
			-- without a timer; the client-level pairing is checked at
			-- construction.
			return async.rejected("api_tree.http_client: a timeout was requested but no opts.timer cap was injected")
		end
		local timing_out, err = timeout_promise(timer, timeout_ms, site.verb, site.path)
		if timing_out == nil then return async.rejected(err) end
		racers[#racers + 1] = timing_out
	end

	local raced = async.race(racers)
	if not is_promise(raced) then
		return async.rejected("api_tree.http_client: async.race did not return a promise")
	end
	return raced:finally(function()
		-- Unsubscribing on settle is what keeps a client-level token from
		-- accumulating one dead listener per call for its whole lifetime.
		for i = 1, #cleanups do cleanups[i]() end
	end)
end

--: (site: CallSite, input: unknown, call_opts: CallOptions | nil) -> unknown
local function perform(site, input, call_opts)
	local timeout_ms = resolved_timeout(site, call_opts)
	local token      = resolved_cancel(site, call_opts)

	local req, build_err = build_request(site.ctx.origin, site.verb, site.path, site.slugs, input, token)
	if req == nil then error(build_err, 0) end

	local settled = async.await(send(site, req, timeout_ms, token))
	if not as_response(settled) then
		error("api_tree.http_client: the transport did not return an HTTP response value", 0)
	end

	local decoded = ext.compose_decode_response(settled, {
		request      = req,
		refetch      = site.ctx.transport,
		meta         = site.meta,
		codegen_name = site.codegen_name,
	}, site.ctx.extensions)
	-- An extension that claims the response owns BOTH the body decode and the
	-- status check: a stream is `200 OK` at the HTTP layer and reports failure
	-- through the stream itself.
	if decoded ~= nil then return decoded.value end

	local body, decode_err = default_decode(settled)
	if decode_err ~= nil then error(decode_err, 0) end

	if settled.status < 200 or settled.status >= 300 then
		error(M.client_error(settled.status, body), 0)
	end
	return body
end

-- One call's arguments, bundled into a single record.
--
-- This is not tidiness. `async.async` forwards its arguments through
-- `{ ... }` + `unpack`, and `unpack` stops at the first nil hole under LuaJIT
-- — so `perform_async(site, nil, call_opts)`, which is exactly what a
-- no-input call with per-call options looks like, would silently drop
-- `call_opts` and quietly ignore the caller's timeout or cancellation. One
-- table argument has no holes to trip over.
--:: CallBundle = { site: CallSite, input: unknown, call_opts: CallOptions | nil }

--: (bundle: CallBundle) -> unknown
local function perform_bundle(bundle)
	return perform(bundle.site, bundle.input, bundle.call_opts)
end

local perform_async = async.async(perform_bundle)

--: (site: CallSite) -> ((input: unknown, call_opts: CallOptions | nil) -> unknown)
local function make_caller(site)
	return function(input, call_opts)
		return perform_async({ site = site, input = input, call_opts = call_opts })
	end
end

-- ── Building the client tree ─────────────────────────────────────────────

--: (t: { [string]: unknown } | nil) -> integer
local function count_keys(t)
	if t == nil then return 0 end
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

-- A position with exactly one method and nothing else is a true leaf and
-- becomes a bare callable rather than a table with one member on it.
--: (route: RouteView) -> boolean
local function is_single_leaf_method(route)
	return count_keys(route.methods) == 1 and count_keys(route.children) == 0 and route.fallback == nil
end

--: (slugs: { [string]: boolean }, name: string) -> { [string]: boolean }
local function with_slug(slugs, name)
	--: { [string]: boolean }
	local out = {}
	for k, v in pairs(slugs) do out[k] = v end
	out[name] = true
	return out
end

--: (ctx: ClientContext, entry: RouteMethodEntry) -> (string | nil)
local function codegen_name_for(ctx, entry)
	local names = ctx.codegen_names
	if names == nil then return nil end
	return names[entry.handler]
end

-- The member name for one co-located method entry: the handler's authored
-- child key when the authored tree was supplied, else the lowercased verb.
--: (ctx: ClientContext, entry: RouteMethodEntry, verb: string) -> string
local function member_name_for(ctx, entry, verb)
	local names = ctx.handler_names
	if names ~= nil then
		local authored = names[entry.handler]
		if authored ~= nil then return authored end
	end
	return verb:lower()
end

--: (route: RouteView, path: string, slugs: { [string]: boolean }, ctx: ClientContext) -> unknown
local function build_client_node(route, path, slugs, ctx)
	local methods = route.methods

	if methods ~= nil and is_single_leaf_method(route) then
		local verbs = sorted_keys(methods)
		local verb  = verbs[1]
		local entry = methods[verb]
		return make_caller({
			verb         = verb,
			path         = path,
			slugs        = slugs,
			ctx          = ctx,
			meta         = entry.meta,
			codegen_name = codegen_name_for(ctx, entry),
		})
	end

	--: { [string]: unknown }
	local client = {}

	if methods ~= nil then
		local verbs = sorted_keys(methods)
		for i = 1, #verbs do
			local verb  = verbs[i]
			local entry = methods[verb]
			client[member_name_for(ctx, entry, verb)] = make_caller({
				verb         = verb,
				path         = path,
				slugs        = slugs,
				ctx          = ctx,
				meta         = entry.meta,
				codegen_name = codegen_name_for(ctx, entry),
			})
		end
	end

	local children = route.children
	if children ~= nil then
		local segments = sorted_keys(children)
		for i = 1, #segments do
			local seg = segments[i]
			client[seg] = build_client_node(children[seg], path .. "/" .. seg, slugs, ctx)
		end
	end

	local fallback = route.fallback
	if fallback ~= nil then
		local name    = fallback.name
		local subtree = fallback.subtree
		client[name] = function(slug_value)
			-- Percent-encoded, unlike the TS runtime proxy — see the module doc.
			return build_client_node(subtree, path .. "/" .. url.encode(slug_value), with_slug(slugs, name), ctx)
		end
	end

	return client
end

-- ── Public entry point ───────────────────────────────────────────────────

-- Build a runtime HTTP client from an already-projected route tree. Path and
-- verb come straight from the tree's own structure, so what this client sends
-- matches exactly what the router built from the same tree dispatches.
--
-- Errors — rather than returning `(nil, errmsg)` — when `opts.transport` is
-- missing or when `opts.timeout` is set without `opts.timer`. Both are
-- programming errors at the construction site, not data errors: no input the
-- caller could have validated produces them, and a client that silently never
-- times out is a bug that surfaces arbitrarily far from its cause.
--
-- There is no `(nil, errmsg)` return at all, because nothing else here can
-- fail — see `origin_from_base_url` on why a base URL cannot be rejected.
--
-- The returned value is `unknown` and must be narrowed by its caller — see the
-- module doc on why no static client shape is computed.
--: (route: RouteView, opts: ClientOptions) -> unknown
function M.create_client_from_route(route, opts)
	if opts.transport == nil then
		error("api_tree.http_client: opts.transport is required — there is no default transport (see the module doc on caps)")
	end
	if opts.timeout ~= nil and opts.timer == nil then
		error("api_tree.http_client: opts.timeout requires opts.timer — a timeout with no clock would never fire")
	end

	local origin = origin_from_base_url(opts.base_url)
	local node   = opts.node
	--: ClientContext
	local ctx = {
		origin        = origin,
		transport     = ext.compose_transport(opts.transport, opts.extensions),
		timer         = opts.timer,
		timeout       = opts.timeout,
		cancel        = opts.cancel,
		extensions    = opts.extensions,
		handler_names = node ~= nil and M.handler_names_from_node(node) or nil,
		codegen_names = node ~= nil and M.codegen_names_from_node(node) or nil,
	}

	return build_client_node(route, "", {}, ctx)
end

return M
