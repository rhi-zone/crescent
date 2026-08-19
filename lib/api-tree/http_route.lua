-- lib/api-tree/http_route.lua — the HTTP ROUTE TREE: its type, its constructor,
-- the mechanical `Node -> HttpRoute` baseline, and the rewriters that reshape
-- it. Ported from the tree half of fractal's
-- packages/http-api-projector/src/route.ts (its lines ~81–690 plus the
-- wire-time source-coverage section).
--
-- The route tree is a SEPARATE type from the API tree (`Node`, lib/api-tree/
-- init.lua). The API tree is organized by DOMAIN — children are operations.
-- The route tree is organized by PROTOCOL — children are path segments, and
-- each node carries a `methods` map keyed by HTTP method. A transform pipeline
-- produces the second from the first:
--
--   Node --naive_transform--> HttpRoute --rewriters--> HttpRoute --> dispatch
--
-- Four pieces live here:
--   1. `HttpRoute` — the route tree type plus `M.http_route()`, the branded
--      constructor.
--   2. `M.naive_transform` — the mechanical baseline: every child becomes a
--      path-segment child, every handler becomes a single POST entry, meta is
--      copied through unchanged. No inference, no convention.
--   3. The rewriters — `HttpRoute -> HttpRoute` functions, each reading ONE
--      flat `meta.http.*` key and reshaping the tree: `apply_methods`,
--      `apply_move_to`, `apply_response`. `compose_transforms` chains them.
--   4. `check_route_source_coverage` — the wire-time check that a leaf's
--      declared param sources can actually be filled at its projected position.
--
-- DISPATCH IS NOT HERE. Matching a URL against this tree, decoding a request
-- into a handler input, encoding the result, and the SSE/error/pagination
-- encoders are route.ts's OTHER half and live in lib/api-tree/http_run.lua.
-- This module is pure tree algebra: it never reads a request and never
-- produces a response.
--
-- ── WHY THIS MODULE REPEATS THE meta.http READS ──────────────────────────
--
-- route.ts deliberately keeps its own `meta.http.*` accessors rather than
-- importing project.ts's, because project.ts VALUE-imports `naiveTransform`
-- and friends from route.ts and the reverse import would cycle. That
-- independence is preserved here on purpose: this module does NOT require
-- lib/api-tree/http_meta.lua. `read_http_meta` below is this module's own,
-- and the duplication is the point, not an oversight.
--
-- ── DELIBERATE DIVERGENCES FROM THE TYPESCRIPT ───────────────────────────
--
-- THE BRANDS ARE WEAK-KEYED TABLES. TS uses a module-private `WeakSet<object>`
-- for the `HttpRoute` brand and a module-private `Symbol` key for the
-- `ResponseOverride` brand. Both exist for the same reason — an UNFORGEABLE
-- mark that no plain data value can accidentally carry, and that no consumer
-- outside this module can mint. Lua has neither a WeakSet nor a Symbol, but it
-- has the mechanism underneath both: a table with `__mode = "k"`, whose keys
-- are the branded values themselves and which therefore neither keeps them
-- alive nor is reachable from them. Both brands are that, and both are
-- module-private, so `M.is_http_route`/`M.is_response_override` are the only
-- ways to ask. `ResponseOverride` is branded this way rather than by an
-- in-band `kind` field (result.lua's and http_value.lua's idiom) specifically
-- because it wraps an ARBITRARY handler return value: a `kind` field would be
-- forgeable by a handler that happens to return `{ kind = "..." }`, which is
-- exactly the collision the TS `Symbol` exists to rule out.
--
-- KEY ITERATION IS SORTED WHEREVER ORDER IS OBSERVABLE. JavaScript's
-- `Object.entries` yields string keys in insertion order; LuaJIT's `pairs`
-- yields them in hash order, which varies between runs. Every place an
-- iteration order can reach the output — the order `apply_move_to` detaches
-- and re-inserts subtrees (which decides which merge conflict is reported
-- first, and, for two subtrees landing on one position, which one's
-- `fallback` survives), the order `apply_methods` renames entries (which
-- decides last-wins when two entries rename onto one key), and the order
-- `find_route_source_coverage_problems` emits problems — iterates a SORTED
-- key list instead. Where order cannot be observed (building a map whose
-- keys are disjoint by construction) plain `pairs` is used and says so.
--
-- HEADERS. A `meta.http.response` directive's `headers` is authored as the
-- flat `{ name = value }` map the TS object literal uses; it is converted to
-- the repo's multi-valued `{ [string]: string[] }` header bag via
-- `http_value.headers_from_map` at the moment the override is built. Nothing
-- downstream ever sees a flattened bag — see http_value.lua's module doc for
-- why the multi-valued shape is load-bearing.
--
-- NOTHING IS AWAITED. `wrapResponse` in the TS is `async (input) => { const
-- body = await handler(input); ... }` because every handler there is async.
-- A crescent `Node` handler is `(input: unknown) -> unknown` — synchronous by
-- type — so there is nothing here to await, and adding an await point would
-- change the handler type this whole tree is generic over. A handler that
-- returns a promise therefore lands a PENDING promise in
-- `ResponseOverride.body`, and resolving it is the dispatch layer's job, in
-- the same place cli_projector.lua already resolves a promise-returning
-- handler's result. This is a real seam with http_run.lua, not a settled
-- contract — see the report accompanying this port.

if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local http_value = require("lib.api-tree.http_value")

local M = {}

-- ── Types ────────────────────────────────────────────────────────────────

-- The open metadata bag, same shape as lib/api-tree/init.lua's `Meta`. Declared
-- locally rather than imported for the same reason tags.lua declares its own
-- `NodeView`: nothing here constructs a `Node`, and a local declaration keeps
-- the module's type surface self-contained.
--:: Meta = { [string]: unknown }

-- The minimal `Node` view `naive_transform` walks. Mirrors tags.lua's
-- `NodeView` exactly.
--:: NodeView = { handler?: (input: unknown) -> unknown, children?: { [string]: NodeView }, fallback?: { name: string, subtree: NodeView }, meta: Meta }

-- Where a specific param is read from, overriding the primary-store
-- convention. Same shape as lib/api-tree/input.lua's `ParamSource`; declared
-- locally for the same self-containment reason as `Meta`.
--:: ParamSource = { store: string, key?: string }

--:: SourceMap = { [string]: ParamSource }

-- The `meta.http` sub-bag as this module reads it. A structural VIEW, not a
-- closed record: `read_http_meta` casts into it after a `type(...) == "table"`
-- check, exactly as cli_projector.lua's `read_cli_meta` does for `meta.cli`.
-- Only the keys this module actually reads are listed; a bag carrying more
-- (`verb`, `middleware`, …) reads fine through it.
--
-- `validate` is `unknown` rather than a Standard Schema type: nothing here
-- runs it, this module only carries it from meta onto `sources`, and inventing
-- a `StandardSchemaV1` shape that no crescent module implements yet would be
-- fabricating a contract.
--:: ResponseDirective = { status?: integer, headers?: { [string]: string } }
--:: PaginatedDirective = { style?: string, inputCursorParam?: string, inputOffsetParam?: string, inputLimitParam?: string }
--:: HttpMetaView = { method?: string, moveTo?: string, response?: ResponseDirective, paginated?: PaginatedDirective, sourceMap?: SourceMap, validate?: unknown, ... }

-- Declarative per-route decode configuration. Real, protocol-specific work
-- (which store a param comes from), carried on the route so the dispatch layer
-- has it without re-reading meta.
--
-- `authored_path_params` is the leaf's own PRE-moveTo ancestor fallback-name
-- chain, stamped by `naive_transform` at the earliest point in the pipeline —
-- before any rewriter (including `apply_move_to`, and any caller-supplied
-- transform) can relocate the leaf. It exists so a leaf's field-to-store
-- binding is a pure function of its AUTHORED declarations (local path-slug
-- ancestry plus explicit `source_map` entries) and never of where `moveTo`
-- happens to move it. moveTo is an address transform; it must not silently
-- rebind inputs.
--
-- Absent (rather than empty) specifically means "this `Sources` did not come
-- from `naive_transform` at all" — a hand-built `HttpRoute`, which many tests
-- construct directly, has no authored-position history to consult, so the
-- coverage check below falls back to the plain live-slug behavior for it. A
-- leaf that DID go through `naive_transform` but was never nested under a
-- fallback gets an EMPTY list, not an absent one: an empty authored set,
-- correctly excluding it from any implicit path binding.
--:: Sources = { sourceMap?: SourceMap, paramNames?: { [integer]: string }, authoredPathParams?: { [integer]: string }, transform?: (bag: { [string]: unknown }) -> { [string]: unknown }, validate?: unknown }

-- The response-init shape http_value.lua accepts, mirrored here because type
-- aliases are per-file. `headers` is the repo's multi-valued header bag; the
-- flat `{ name = value }` map a `meta.http.response` directive authors is
-- converted into it by `http_value.headers_from_map`, never carried flat.
--:: HttpHeaders = { [string]: { [integer]: string } }
--:: HttpResponseInit = { status?: integer, reason?: string, headers?: HttpHeaders }

--:: MethodEntry = { handler: (input: unknown) -> unknown, meta: Meta, sources?: Sources | nil }

-- Every optional field is written `?: T | nil` rather than plain `?: T`. In
-- Lua an absent field and a field holding nil are the SAME observable state,
-- and the constructor below builds a route by assigning all four fields
-- unconditionally — the direct equivalent of the TS constructor's conditional
-- spreads, since assigning nil simply does not create the key. Declaring the
-- fields as `T | nil` is what makes that construction expressible without a
-- cast: `?: T` alone would reject an expression whose own type is `T | nil`.
--:: HttpRoute = { methods?: { [string]: MethodEntry } | nil, children?: { [string]: HttpRoute } | nil, fallback?: { name: string, subtree: HttpRoute } | nil, meta: Meta }

-- What `M.http_route` accepts — the same four fields, with `meta` optional too
-- (it defaults to an empty bag).
--:: HttpRouteDef = { methods?: { [string]: MethodEntry } | nil, children?: { [string]: HttpRoute } | nil, fallback?: { name: string, subtree: HttpRoute } | nil, meta?: Meta | nil }

-- ── Sorted iteration ─────────────────────────────────────────────────────

-- Sorted key list of a string-keyed map. THE determinism primitive for this
-- module — see the module doc's note on why every order-observable iteration
-- goes through it.
--: (t: { [string]: unknown }) -> { [integer]: string }
local function sorted_keys(t)
	--: { [integer]: string }
	local out = {}
	local n = 0
	for k in pairs(t) do
		n = n + 1
		out[n] = k
	end
	table.sort(out)
	return out
end

-- Array append, returning a NEW array. Used for path accumulation, where the
-- TS spreads (`[...path, key]`); mutating a shared array would leak a sibling
-- branch's segment into another branch.
--: (xs: { [integer]: string }, x: string) -> { [integer]: string }
local function appended(xs, x)
	--: { [integer]: string }
	local out = {}
	for i = 1, #xs do out[i] = xs[i] end
	out[#xs + 1] = x
	return out
end

--: (xs: { [integer]: string }, x: string) -> boolean
local function includes(xs, x)
	for i = 1, #xs do
		if xs[i] == x then return true end
	end
	return false
end

-- ── HttpRoute constructor + brand ────────────────────────────────────────

-- The runtime brand. Weak-keyed so branding a route never keeps it alive —
-- the direct analogue of the TS `WeakSet<object>`, and private for the same
-- reason: `M.is_http_route` must be the only way to answer the question, or
-- the brand is forgeable and stops being a discriminator.
local route_brand = setmetatable({}, { __mode = "k" }) --[[: { [unknown]: boolean } ]]

-- Construct an `HttpRoute`, registering it for `M.is_http_route`. Every route
-- in the pipeline goes through here — `naive_transform` and all three
-- rewriters build only via this function — so the brand is universal.
--
-- `meta` defaults to an empty bag, matching the TS `def.meta ?? {}`.
--: (def: HttpRouteDef) -> HttpRoute
function M.http_route(def)
	--: HttpRoute
	local route = {
		methods  = def.methods,
		children = def.children,
		fallback = def.fallback,
		meta     = def.meta or {},
	}
	route_brand[route] = true
	return route
end

-- True when `v` is an `HttpRoute` built by `M.http_route`. The discriminator a
-- consumer handed either a `Node` or an `HttpRoute` needs: both shapes carry
-- `children` and `meta`, so structure alone cannot tell them apart.
--: (v: unknown) -> v is HttpRoute
function M.is_http_route(v)
	if type(v) ~= "table" then return false end
	-- Narrowed to a table before the brand lookup rather than indexing a
	-- still-`unknown` value directly. Reading through an `{ [unknown]: T }`
	-- index signature warns "inference fell back to `any`" either way — the
	-- checker has no rule for a non-string, non-integer index key — which is
	-- the same warning every other weak-keyed table in this repo carries
	-- (lib/type/analysis/crescent_slice.lua, lib/platform/daemon/init.lua).
	-- The comparison to `true` below is what keeps the result a `boolean`
	-- regardless.
	local t = v --[[: { [string]: unknown }]]
	return route_brand[t] == true
end

-- ── Flat-key readers ─────────────────────────────────────────────────────
--
-- This module's OWN reads of `meta.http.*`, not calls into http_meta.lua —
-- see the module doc for why that independence is deliberate. Since the flat
-- meta design resolves each key at `op()`/`merge_meta` time (last-wins for
-- scalars, key-merged for `sourceMap`), these are plain field reads rather
-- than a directive-array walk.

-- Read the `meta.http` bag. An absent or non-table `meta.http` reads as an
-- empty bag, so every call site can index the result directly without a nil
-- guard. Same contract and same shape as cli_projector.lua's `read_cli_meta`.
--: (meta: Meta) -> HttpMetaView
function M.read_http_meta(meta)
	local h = meta.http
	if type(h) ~= "table" then return {} end
	return h --[[: HttpMetaView]]
end

--: (meta: Meta) -> SourceMap | nil
function M.source_map_of(meta)
	return M.read_http_meta(meta).sourceMap
end

--: (meta: Meta) -> unknown
function M.validate_of(meta)
	return M.read_http_meta(meta).validate
end

-- Exported although this module never reads it: `paginated` is consumed by the
-- dispatch half (the `Link` header builder) and by client extensions, and this
-- is where route.ts keeps the reader. Exporting it is what lets http_run.lua
-- reuse it instead of growing a second copy of the same meta read.
--: (meta: Meta) -> PaginatedDirective | nil
function M.paginated_directive_of(meta)
	return M.read_http_meta(meta).paginated
end

-- Assemble a leaf's `sources`. Factored out of `naive_transform_node` for the
-- same reason the TS factors it out: the `sourceMap`/`validate` reads happen
-- exactly once each, at a point where the presence check and the value are the
-- same expression.
--: (meta: Meta, authored_path_params: { [integer]: string }) -> Sources
local function build_sources(meta, authored_path_params)
	local http = M.read_http_meta(meta)
	--: Sources
	local sources = { authoredPathParams = authored_path_params }
	local source_map = http.sourceMap
	if source_map ~= nil then sources.sourceMap = source_map end
	local validate = http.validate
	if validate ~= nil then sources.validate = validate end
	return sources
end

-- ── 1. naive_transform: Node -> HttpRoute ────────────────────────────────
--
-- Every child becomes a path-segment child. Every handler becomes a single
-- POST entry. meta is copied through unchanged. Recursive.
--
-- The TS carries a `NaiveRoute<N>` mapped type that threads each leaf's exact
-- handler signature through the transform, so `route.children.getBook.methods
-- .POST.handler` keeps its real `(input: {id: string}) => Book` type. That is a
-- TypeScript conditional-type computation over the input tree's literal shape;
-- it has no runtime component whatsoever, and crescent's `NodeView` handlers
-- are already the erased `(input: unknown) -> unknown`. Nothing is lost at
-- runtime and nothing is approximated — the precision simply never existed on
-- this side of the port.

-- `authored_ancestors` is the list of fallback names on the path from the
-- root to `node` IN THE AUTHORED TREE, threaded down so every leaf gets its
-- `sources.authoredPathParams` stamped at construction — the earliest point in
-- the pipeline, before any rewriter can relocate anything.
--: (node: NodeView, authored_ancestors: { [integer]: string }) -> HttpRoute
local function naive_transform_node(node, authored_ancestors)
	--: { [string]: MethodEntry } | nil
	local methods = nil
	local handler = node.handler
	if handler ~= nil then
		methods = {
			POST = {
				handler = handler,
				meta    = node.meta,
				sources = build_sources(node.meta, authored_ancestors),
			},
		}
	end

	--: { [string]: HttpRoute } | nil
	local children = nil
	local node_children = node.children
	if node_children ~= nil then
		--: { [string]: HttpRoute }
		local built = {}
		-- Plain `pairs`: this builds a MAP whose keys are the input's keys.
		-- Iteration order cannot reach the result.
		for key, child in pairs(node_children) do
			built[key] = naive_transform_node(child, authored_ancestors)
		end
		children = built
	end

	--: { name: string, subtree: HttpRoute } | nil
	local fallback = nil
	local node_fallback = node.fallback
	if node_fallback ~= nil then
		fallback = {
			name    = node_fallback.name,
			subtree = naive_transform_node(node_fallback.subtree, appended(authored_ancestors, node_fallback.name)),
		}
	end

	return M.http_route({ methods = methods, children = children, fallback = fallback, meta = node.meta })
end

--: (node: NodeView) -> HttpRoute
function M.naive_transform(node)
	return naive_transform_node(node, {})
end

-- ── Shared visitor ───────────────────────────────────────────────────────

-- Pre-order visitor over a route tree: `fn` transforms a single node — its own
-- `methods`/`meta` — and `map_route` owns the recursion into `children` and
-- `fallback`, applying `fn` to `route` FIRST and then recursing into the
-- fields of the RESULT.
--
-- Pre-order rather than post-order because it lets `fn` return an entirely
-- different node before that node's children are visited. For the rewriters
-- here the two orders are behaviorally identical anyway — none of them reads a
-- node's children to decide how to transform that node — so the choice is made
-- on which one matches how a rewriter reads: transform self, then thread
-- through children.
--: (route: HttpRoute, fn: (node: HttpRoute) -> HttpRoute) -> HttpRoute
function M.map_route(route, fn)
	local mapped = fn(route)

	--: { [string]: HttpRoute } | nil
	local children = nil
	local mapped_children = mapped.children
	if mapped_children ~= nil then
		--: { [string]: HttpRoute }
		local built = {}
		for key, child in pairs(mapped_children) do
			built[key] = M.map_route(child, fn)
		end
		children = built
	end

	--: { name: string, subtree: HttpRoute } | nil
	local fallback = nil
	local mapped_fallback = mapped.fallback
	if mapped_fallback ~= nil then
		fallback = { name = mapped_fallback.name, subtree = M.map_route(mapped_fallback.subtree, fn) }
	end

	return M.http_route({ methods = mapped.methods, children = children, fallback = fallback, meta = mapped.meta })
end

-- ── 2a. apply_methods ────────────────────────────────────────────────────
--
-- Reads the flat `meta.http.method` key off a method entry's OWN meta and
-- renames the method key accordingly — POST, the `naive_transform` default,
-- becomes GET/PUT/DELETE/….

-- The per-node rename, factored out of the visitor closure so its result has a
-- DECLARED type. Inlined, the rebuilt map's type flowed back into the
-- `node.methods` local through the `sorted_keys` call and widened it to the
-- parameter's `{ [string]: unknown }`; a named helper pins both ends.
--
-- Returns the input map unchanged when nothing renamed, matching the TS
-- `methods = changed ? rebuilt : methods` — an untouched node keeps its
-- original method table identity.
--: (methods: { [string]: MethodEntry }) -> { [string]: MethodEntry }
local function renamed_methods(methods)
	--: { [string]: MethodEntry }
	local rebuilt = {}
	local changed = false
	-- SORTED: two entries whose `meta.http.method` names the same method
	-- collapse onto one key, and which one survives is decided by iteration
	-- order. Hash order would make that a coin flip between runs.
	local keys = sorted_keys(methods)
	for i = 1, #keys do
		local key = keys[i]
		local entry = methods[key]
		local method = M.read_http_meta(entry.meta).method
		local new_key = method ~= nil and method:upper() or key
		if new_key ~= key then changed = true end
		-- No stripping: `meta.http.method` STAYS on the entry's meta after the
		-- rename. The flat design's rule is "resolved shape = authored shape"
		-- — the key is informational, not a directive to consume — so a bare
		-- leaf's route-position meta and its sole method entry's meta remain
		-- the same table through this rewriter.
		rebuilt[new_key] = entry
	end
	if not changed then return methods end
	return rebuilt
end

--: (route: HttpRoute) -> HttpRoute
function M.apply_methods(route)
	return M.map_route(route, function(node)
		local methods = node.methods
		if methods ~= nil then methods = renamed_methods(methods) end
		return M.http_route({ methods = methods, children = node.children, fallback = node.fallback, meta = node.meta })
	end)
end

-- ── 2b. apply_move_to ────────────────────────────────────────────────────
--
-- Reads the flat `meta.http.moveTo` key and moves whole route subtrees within
-- the tree, per a relative-path algebra with filesystem semantics:
--
--   "." (the whole directive) — identity; the node stays where it is.
--   Any other path resolves relative to the node's OWN position:
--     ".."          — up to the parent
--     "../newname"  — rename (a sibling under a different name)
--     "*"           — push a wildcard (fallback) segment below self
--     "."           (as one component) — no-op
--     any other token — push that literal segment below self
--
-- Two phases: (1) walk the tree, DETACHING every subtree that carries a
-- `moveTo` on its own top-level meta and recording its resolved absolute
-- target; (2) RE-INSERT each detached subtree at its target, creating
-- intermediate branch/fallback nodes as needed and merging when several
-- subtrees converge on one position — the motivating REST case, where
-- get/update/delete all land on the same `*`.
--
-- ORDER IS LOAD-BEARING HERE, which is why both phases iterate sorted keys.
-- The detach order fixes the insertion order, and the insertion order decides
-- (a) which of two colliding placements is reported in the conflict error and
-- (b) for two subtrees converging on one position, whose `fallback` survives
-- `merge_routes`'s `incoming or target` precedence. Under LuaJIT's randomized
-- hash iteration, leaving that to `pairs` would make a tree with two moves
-- into one position build differently between runs.
--
-- [convention] When a move creates a NEW wildcard segment — no `fallback`
-- already at that position — the parameter name defaults to "param". The
-- design this is ported from leaves the wildcard's parameter name as coming
-- "from the node's own metadata," which is not wired up on either side. An
-- already-present `fallback.name` at the target always wins over the default.

--:: PendingMove = { targetPath: { [integer]: string }, subtree: HttpRoute }

--: (item_path: { [integer]: string }, path: string) -> { [integer]: string }
local function resolve_move_to(item_path, path)
	--: { [integer]: string }
	local stack = {}
	local n = 0
	for i = 1, #item_path do
		n = n + 1
		stack[n] = item_path[i]
	end
	if path == "." then return stack end
	for tok in path:gmatch("[^/]+") do
		if tok == "." then
			-- A "." component is a no-op: it names the current position.
			n = n
		elseif tok == ".." then
			-- Popping past the root is a no-op, matching `Array.prototype.pop`
			-- on an empty array.
			if n > 0 then n = n - 1 end
		else
			n = n + 1
			stack[n] = tok
		end
	end
	-- `n` is decremented rather than the popped slot being cleared, because a
	-- `{ [integer]: string }` array does not admit nil as an element type. The
	-- live prefix is copied out at the end instead.
	--: { [integer]: string }
	local out = {}
	for i = 1, n do out[i] = stack[i] end
	return out
end

--: (route: HttpRoute, path: { [integer]: string }, moves: { [integer]: PendingMove }) -> HttpRoute
local function detach(route, path, moves)
	local children = route.children
	if children ~= nil then
		--: { [string]: HttpRoute }
		local rebuilt = {}
		local keys = sorted_keys(children)
		for i = 1, #keys do
			local key = keys[i]
			local child = children[key]
			local child_path = appended(path, key)
			local move_to = M.read_http_meta(child.meta).moveTo
			if move_to ~= nil then
				local target = resolve_move_to(child_path, move_to)
				-- The child's own descendants' moves are recorded BEFORE the
				-- child's, because detaching the subtree is what produces the
				-- value pushed here. Same evaluation order as the TS.
				local subtree = detach(child, child_path, moves)
				-- No stripping: `meta.http.moveTo` stays on the moved
				-- subtree's meta — informational, not consumed, same rule as
				-- `apply_methods`.
				moves[#moves + 1] = { targetPath = target, subtree = subtree }
			else
				rebuilt[key] = detach(child, child_path, moves)
			end
		end
		children = rebuilt
	end

	local fallback = route.fallback
	if fallback ~= nil then
		local child_path = appended(path, "*")
		local move_to = M.read_http_meta(fallback.subtree.meta).moveTo
		if move_to ~= nil then
			local target = resolve_move_to(child_path, move_to)
			local subtree = detach(fallback.subtree, child_path, moves)
			moves[#moves + 1] = { targetPath = target, subtree = subtree }
			fallback = nil
		else
			fallback = { name = fallback.name, subtree = detach(fallback.subtree, child_path, moves) }
		end
	end

	return M.http_route({ methods = route.methods, children = children, fallback = fallback, meta = route.meta })
end

--: (path: { [integer]: string }) -> string
local function display_path(path)
	if #path == 0 then return "/" end
	return "/" .. table.concat(path, "/")
end

-- Merge an incoming subtree into whatever already occupies a target position —
-- what makes converging placements group naturally.
--
-- ERRORS (rather than returning `(nil, errmsg)`) when both sides define the
-- same HTTP method. Two operations at one path+method is an authoring mistake
-- discovered while WIRING the tree, not a data error in a request: there is no
-- answer to "which handler serves this request?" for a merge to pick, and the
-- caller is a build step with nothing sensible to do but stop. Same call
-- http_value.lua's `stream_response` makes for a non-Stream argument.
--: (target: HttpRoute, incoming: HttpRoute, path: { [integer]: string }) -> HttpRoute
local function merge_routes(target, incoming, path)
	local target_methods = target.methods or {}
	local incoming_methods = incoming.methods or {}
	-- SORTED: with two conflicting methods, this decides which one the error
	-- names. A nondeterministic error message is a nondeterministic build.
	local incoming_keys = sorted_keys(incoming_methods)
	for i = 1, #incoming_keys do
		local method = incoming_keys[i]
		if target_methods[method] ~= nil then
			error("api_tree.http_route: apply_move_to: conflicting route — " .. method .. " "
				.. display_path(path) .. " is defined by more than one node")
		end
	end

	--: { [string]: MethodEntry }
	local methods = {}
	for k, v in pairs(target_methods) do methods[k] = v end
	for k, v in pairs(incoming_methods) do methods[k] = v end

	--: { [string]: HttpRoute }
	local children = {}
	local target_children = target.children
	if target_children ~= nil then
		for k, v in pairs(target_children) do children[k] = v end
	end
	local incoming_children = incoming.children
	if incoming_children ~= nil then
		for k, v in pairs(incoming_children) do children[k] = v end
	end

	return M.http_route({
		methods  = methods,
		children = children,
		fallback = incoming.fallback or target.fallback,
		meta     = target.meta,
	})
end

-- Insert `subtree` at `target_path` within `root`, creating intermediate
-- branch/fallback nodes along the way (mkdir -p): a resolved target such as
-- `../api/v2/users` names several segments, and every one not already present
-- is created as a plain, empty route so the walk can continue.
--
-- `full_path` is carried unchanged for error reporting — `merge_routes` names
-- the WHOLE target position, not the remaining suffix.
--: (root: HttpRoute, target_path: { [integer]: string }, subtree: HttpRoute, full_path: { [integer]: string }) -> HttpRoute
local function insert_at(root, target_path, subtree, full_path)
	if #target_path == 0 then return merge_routes(root, subtree, full_path) end

	local head = target_path[1]
	--: { [integer]: string }
	local rest = {}
	for i = 2, #target_path do rest[i - 1] = target_path[i] end

	if head == "*" then
		local existing = root.fallback
		local name = existing ~= nil and existing.name or "param"
		local base = existing ~= nil and existing.subtree or M.http_route({})
		return M.http_route({
			methods  = root.methods,
			children = root.children,
			fallback = { name = name, subtree = insert_at(base, rest, subtree, full_path) },
			meta     = root.meta,
		})
	end

	--: { [string]: HttpRoute }
	local children = {}
	local root_children = root.children
	if root_children ~= nil then
		for k, v in pairs(root_children) do children[k] = v end
	end
	local base = children[head] or M.http_route({})
	children[head] = insert_at(base, rest, subtree, full_path)

	return M.http_route({
		methods  = root.methods,
		children = children,
		fallback = root.fallback,
		meta     = root.meta,
	})
end

-- Apply every `moveTo` in the tree. Detached subtrees are re-inserted
-- SEQUENTIALLY, so a conflict between two DIFFERENT placed subtrees converging
-- on one path+method is caught exactly like a conflict between a placed
-- subtree and a node already sitting at the target — both funnel through
-- `merge_routes`'s check.
--: (route: HttpRoute) -> HttpRoute
function M.apply_move_to(route)
	--: { [integer]: PendingMove }
	local moves = {}
	local acc = detach(route, {}, moves)
	for i = 1, #moves do
		local m = moves[i]
		acc = insert_at(acc, m.targetPath, m.subtree, m.targetPath)
	end
	return acc
end

-- ── 2c. apply_response ───────────────────────────────────────────────────
--
-- Reads the flat `meta.http.response` key and wraps the handler — FUNCTION
-- COMPOSITION, not metadata on the route — so it produces a value carrying the
-- response override. The override is materialized into the handler's RETURN
-- VALUE via a branded wrapper any `HttpRoute` consumer can recognize;
-- everything else about the handler is untouched.

--:: ResponseOverride = { body: unknown, init: HttpResponseInit }

-- See the module doc for why this is a weak-keyed brand rather than an in-band
-- `kind` field: the override wraps an arbitrary handler return value, and a
-- structural marker would be forgeable by a handler that happens to return a
-- table with the same field.
local override_brand = setmetatable({}, { __mode = "k" }) --[[: { [unknown]: boolean } ]]

-- Build a response override. `init` is an http_value `HttpResponseInit`, so
-- its `headers` is already the multi-valued `{ [string]: string[] }` bag.
--: (body: unknown, init: HttpResponseInit) -> ResponseOverride
function M.response_override(body, init)
	--: ResponseOverride
	local override = { body = body, init = init }
	override_brand[override] = true
	return override
end

--: (v: unknown) -> v is ResponseOverride
function M.is_response_override(v)
	if type(v) ~= "table" then return false end
	-- Same narrow-before-index as `M.is_http_route`.
	local t = v --[[: { [string]: unknown }]]
	return override_brand[t] == true
end

--: (handler: (input: unknown) -> unknown, status: integer | nil, headers: { [string]: string } | nil) -> (input: unknown) -> unknown
local function wrap_response(handler, status, headers)
	return function(input)
		local body = handler(input)
		--: HttpResponseInit
		local init = {}
		if status ~= nil then init.status = status end
		if headers ~= nil then init.headers = http_value.headers_from_map(headers) end
		return M.response_override(body, init)
	end
end

-- Factored out of the visitor closure for the same typing reason as
-- `renamed_methods` above.
--: (methods: { [string]: MethodEntry }) -> { [string]: MethodEntry }
local function wrapped_methods(methods)
	--: { [string]: MethodEntry }
	local rebuilt = {}
	local changed = false
	-- Sorted for consistency with `renamed_methods`; this rewriter never
	-- renames a key, so no entry can collide with another here.
	local keys = sorted_keys(methods)
	for i = 1, #keys do
		local key = keys[i]
		local entry = methods[key]
		local response = M.read_http_meta(entry.meta).response
		if response == nil then
			rebuilt[key] = entry
		else
			changed = true
			--: MethodEntry
			local wrapped = {
				handler = wrap_response(entry.handler, response.status, response.headers),
				-- No stripping: `meta.http.response` stays on the entry's meta
				-- after wrapping — informational, same rule as
				-- `renamed_methods`.
				meta    = entry.meta,
				sources = entry.sources,
			}
			rebuilt[key] = wrapped
		end
	end
	if not changed then return methods end
	return rebuilt
end

--: (route: HttpRoute) -> HttpRoute
function M.apply_response(route)
	return M.map_route(route, function(node)
		local methods = node.methods
		if methods ~= nil then methods = wrapped_methods(methods) end
		return M.http_route({ methods = methods, children = node.children, fallback = node.fallback, meta = node.meta })
	end)
end

-- ── 3. compose_transforms ────────────────────────────────────────────────

-- Chain rewriters into a single `HttpRoute -> HttpRoute`, applied left to
-- right.
--: (...((r: HttpRoute) -> HttpRoute)) -> ((r: HttpRoute) -> HttpRoute)
function M.compose_transforms(...)
	local count = select("#", ...)
	--: { [integer]: (r: HttpRoute) -> HttpRoute }
	local fns = { ... }
	return function(r)
		local acc = r
		for i = 1, count do
			acc = fns[i](acc)
		end
		return acc
	end
end

-- ── split_path ───────────────────────────────────────────────────────────

-- Split a URL path into its non-empty segments, in one pass and one
-- allocation — the TS avoids `split("/")` followed by `filter(s => s.length >
-- 0)` because that builds two arrays; this scans bytes and appends only the
-- segments it keeps.
--
-- Lives here rather than in the dispatch module because it defines what a
-- "segment" IS, which is the same thing `children` keys and `fallback`
-- positions mean in this tree.
--: (pathname: string) -> { [integer]: string }
function M.split_path(pathname)
	--: { [integer]: string }
	local segs = {}
	local count = 0
	local start = 1
	local len = #pathname
	for i = 1, len + 1 do
		if i == len + 1 or pathname:byte(i) == 47 then
			if i > start then
				count = count + 1
				segs[count] = pathname:sub(start, i - 1)
			end
			start = i + 1
		end
	end
	return segs
end

-- ── Wire-time source coverage ────────────────────────────────────────────
--
-- `op()` can statically check only the one resolution step visible at its own
-- call site — a `source()` override naming a param the handler does not
-- declare. The other two steps are not visible there, structurally rather than
-- for want of engineering: a path-param match depends on where the leaf is
-- MOUNTED (a property of the tree handed to `api()`, not of the leaf's own
-- `op()` arguments), and the no-`paramNames` convention fallback resolves
-- against the live request's own keys.
--
-- Both DO exist once the route tree is built, which is where this check runs:
-- once, at wire time, over every leaf method. It reports EVERY problem it
-- finds in one pass rather than stopping at the first, so one boot surfaces
-- the whole list.
--
-- A leaf without `sources.paramNames` is skipped entirely: with no
-- codegen-derived param list there is no fixed set to check coverage against.
--
-- moveTo is purely an ADDRESS transform and must not affect input binding, so
-- each param is resolved by mirroring `input.assemble`'s own resolution order
-- exactly — path match, then explicit override, then primary-store convention
-- — using the authored-restricted path-param set, and flagging whichever step
-- it actually lands on when that step does not hold up.

--:: SourceCoverageProblem = { path: string, method: string, param: string, kind: string, detail: string }

--:: SourceCoverageOptions = { known_stores?: { [integer]: string } }

-- The store names this repo's HTTP projector itself builds.
--
-- SUBSTRATE NOTE: on the TypeScript side this constant and
-- `primary_store_for_method` below both live in decode.ts and are IMPORTED by
-- route.ts. decode.ts has no crescent port yet, so both are duplicated here —
-- deliberately module-PRIVATE, so nothing downstream can come to depend on
-- this file as their home and the eventual decode port is free to own them
-- outright. See TODO.md.
--: { [integer]: string }
local BUILTIN_HTTP_STORE_NAMES = { "path", "query", "header", "body", "caller" }

-- The default store for a non-path param, by method: GET/HEAD/DELETE read from
-- the query, everything else from the body.
--: (method: string) -> string
local function primary_store_for_method(method)
	if method == "GET" or method == "HEAD" or method == "DELETE" then return "query" end
	return "body"
end

-- Walk `root` and collect every leaf method whose declared param sources do
-- not hold up. The NON-throwing form, for a caller that wants to report the
-- problems itself; `M.check_route_source_coverage` is the throwing form.
--
-- Resolution, per param, mirroring `input.assemble`:
--
--   1. Resolves via "path" when it is a LIVE final path-param name AND — when
--      this leaf came through `naive_transform`, i.e. `authoredPathParams` is
--      present — it is also in the leaf's AUTHORED set. When
--      `authoredPathParams` is absent (a hand-built route that bypassed
--      `naive_transform`), being a live path-param name is enough. Always
--      fine when it applies: "path" is always a known store, and any
--      `sourceMap` override for the param is dead code at that point.
--   2. Otherwise, an explicit `sourceMap[param]`. Store "path" requires its
--      resolved key to actually be present in the leaf's final path params —
--      otherwise `unfillable-path`, the field is declared path-sourced but
--      nothing at the leaf's projected position supplies it. Any other store
--      must be one something builds, or `unknown-store`.
--   3. Otherwise, if the param IS in the leaf's authored set but did not
--      resolve via path in step 1 — reachable only when the live path params
--      at the leaf's FINAL position lack it — `unfillable-path`: moveTo
--      relocated the leaf away from its matching ancestor.
--   4. Otherwise it falls through to the primary-store convention like any
--      other non-path field, checked against the known set. This is the case
--      that used to bind implicitly by name collision; it no longer does, and
--      is correctly NOT an error — it is an ordinary query/body field.
--
-- Also flags a `sourceMap` entry for a param that is not in `paramNames`:
-- `assemble` only ever reads `paramNames`, so such an override never applies.
--: (root: HttpRoute, opts: SourceCoverageOptions | nil) -> { [integer]: SourceCoverageProblem }
function M.find_route_source_coverage_problems(root, opts)
	--: { [string]: boolean }
	local known = {}
	for i = 1, #BUILTIN_HTTP_STORE_NAMES do known[BUILTIN_HTTP_STORE_NAMES[i]] = true end
	local extra = opts ~= nil and opts.known_stores or nil
	if extra ~= nil then
		for i = 1, #extra do known[extra[i]] = true end
	end
	local known_list = table.concat(sorted_keys(known), ", ")

	--: { [integer]: SourceCoverageProblem }
	local problems = {}

	--: (route: HttpRoute, segments: { [integer]: string }, path_params: { [integer]: string }) -> nil
	local function visit(route, segments, path_params)
		local path = display_path(segments)
		local methods = route.methods
		if methods ~= nil then
			-- SORTED: `problems` is an ordered list a caller prints, so the
			-- iteration order is directly observable output.
			local method_keys = sorted_keys(methods)
			for mi = 1, #method_keys do
				local method = method_keys[mi]
				local entry = methods[method]
				local sources = entry.sources
				local param_names = sources ~= nil and sources.paramNames or nil
				local source_map = (sources ~= nil and sources.sourceMap) or {}
				local authored = sources ~= nil and sources.authoredPathParams or nil
				if param_names ~= nil then
					local primary = primary_store_for_method(method)
					for pi = 1, #param_names do
						local param = param_names[pi]
						local authored_wants_it = authored ~= nil and includes(authored, param)
						-- A live path-param name is necessary either way; when
						-- the leaf came through `naive_transform` it must ALSO
						-- be in the authored set.
						local resolves_via_path = includes(path_params, param)
						if authored ~= nil then
							resolves_via_path = resolves_via_path and authored_wants_it
						end

						if not resolves_via_path then
							local override = source_map[param]
							if override ~= nil then
								if override.store == "path" then
									local key = override.key or param
									if not includes(path_params, key) then
										problems[#problems + 1] = {
											path   = path,
											method = method,
											param  = param,
											kind   = "unfillable-path",
											detail = 'declared as path-sourced (key "' .. key .. '") via an explicit source override,'
												.. " but nothing at this leaf's projected position (" .. path .. ") supplies it",
										}
									end
								elseif not known[override.store] then
									problems[#problems + 1] = {
										path   = path,
										method = method,
										param  = param,
										kind   = "unknown-store",
										detail = 'reads from store "' .. override.store .. '", which no projector builds'
											.. " (known: " .. known_list .. ")",
									}
								end
							elseif authored_wants_it then
								-- Authored as a local slug but `resolves_via_path`
								-- was false — reachable only when the live path
								-- params at this leaf's FINAL position lack it,
								-- i.e. moveTo moved the leaf away from its
								-- matching ancestor.
								problems[#problems + 1] = {
									path   = path,
									method = method,
									param  = param,
									kind   = "unfillable-path",
									detail = "authored as a local path slug, but moveTo relocated this leaf away from"
										.. ' a matching ancestor — its projected position (' .. path .. ') has no "'
										.. param .. '" segment',
								}
							elseif not known[primary] then
								-- Not authored, not explicit-path-sourced: an
								-- ordinary primary-store field, even if its name
								-- happens to coincide with a live path param
								-- post-move.
								problems[#problems + 1] = {
									path   = path,
									method = method,
									param  = param,
									kind   = "unknown-store",
									detail = 'reads from store "' .. primary .. '", which no projector builds'
										.. " (known: " .. known_list .. ")",
								}
							end
						end
					end

					local declared = table.concat(param_names, ", ")
					if declared == "" then declared = "none" end
					local override_keys = sorted_keys(source_map)
					for oi = 1, #override_keys do
						local param = override_keys[oi]
						if not includes(param_names, param) then
							problems[#problems + 1] = {
								path   = path,
								method = method,
								param  = param,
								kind   = "unused-override",
								detail = "has a source override but is not one of this route's params"
									.. " (" .. declared .. ") — the override is never applied",
							}
						end
					end
				end
			end
		end

		local children = route.children
		if children ~= nil then
			local child_keys = sorted_keys(children)
			for ci = 1, #child_keys do
				local name = child_keys[ci]
				visit(children[name], appended(segments, name), path_params)
			end
		end

		local fallback = route.fallback
		if fallback ~= nil then
			-- A fallback segment IS a path param: the dispatcher binds the raw
			-- segment to `fallback.name` as a slug, so every leaf below here
			-- can source that name from "path".
			visit(fallback.subtree, appended(segments, "{" .. fallback.name .. "}"), appended(path_params, fallback.name))
		end
	end

	visit(root, {}, {})
	return problems
end

-- The message a coverage failure reports — every problem, not just the first.
-- Exported because the TypeScript carries this text on a `SourceCoverageError`
-- class whose only other member is `problems`, and
-- `find_route_source_coverage_problems` already hands `problems` back
-- directly. A caller that wants the structured list calls that; a caller that
-- wants the rendered message calls this. Lua has no exception classes to
-- inherit from, so the class reduces to exactly these two pieces.
--: (problems: { [integer]: SourceCoverageProblem }) -> string
function M.source_coverage_message(problems)
	--: { [integer]: string }
	local lines = {}
	lines[1] = "api_tree.http_route: HTTP route source coverage: " .. tostring(#problems) .. " problem(s)"
	for i = 1, #problems do
		local p = problems[i]
		lines[i + 1] = "  " .. p.method .. " " .. p.path .. ' — param "' .. p.param .. '": ' .. p.detail
	end
	return table.concat(lines, "\n")
end

-- `find_route_source_coverage_problems`, but ERRORS with every problem listed
-- when there is at least one. Run once at wire time, while building a
-- dispatcher — the point at which mount position and the codegen'd
-- `paramNames` list both exist, which is exactly why the check lives here
-- instead of at `op()`.
--
-- Errors rather than returning `(nil, errmsg)` for the same reason
-- `merge_routes` does: a route tree whose params cannot be filled is a wiring
-- mistake found while building the server, not a data error in a request.
--: (root: HttpRoute, opts: SourceCoverageOptions | nil) -> nil
function M.check_route_source_coverage(root, opts)
	local problems = M.find_route_source_coverage_problems(root, opts)
	if #problems > 0 then
		error(M.source_coverage_message(problems))
	end
	return nil
end

return M
