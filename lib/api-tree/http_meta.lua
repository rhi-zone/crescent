-- lib/api-tree/http_meta.lua — the `meta.http` flat bag, the accessor that
-- reads it, and HTTP verb derivation from the tag lattice. Ported from
-- fractal's packages/http-api-projector/src/tags.ts (`verbFromTags`) plus the
-- `meta.http` type surface and response helpers of that package's project.ts
-- (`getHttpMeta`, `allowHeader`).
--
-- WHY THESE THREE LIVE TOGETHER. On the TypeScript side they are split across
-- two files for an import-cycle reason that does not exist here: `verbFromTags`
-- was pulled out of project.ts so that packages with their own self-contained
-- tree walks (openapi, client) could derive the same verb a leaf would get
-- without importing project.ts's dispatch internals. In this port there are no
-- dispatch internals in this file at all — routing (`toHttpRoutes`,
-- `makeRouter`) is a separate module — so the accessor and its one derived
-- reading are one module, which is also what a reader looking for "what does
-- meta.http mean" would expect.
--
-- Not folded into lib/api-tree/tags.lua, for tags.ts's own stated reason:
-- `resolve_tags` and the tag constants are projector-agnostic and know nothing
-- about HTTP. `verb_from_tags` reads `meta.http`, an HTTP-specific bag.
-- Keeping it here keeps HTTP shape out of the core tag module.
--
-- WHAT `meta.http` IS. A FLAT, namespaced bag of scalar/map/array keys, where
-- the value's SHAPE determines how two contributions to the same node fold:
--
--   verb/method/moveTo/response/paginated/validate — at-most-one scalars,
--     last-wins.
--   sourceMap/encodingMap — keyed partial contributions; key-merged, a later
--     contribution's keys winning on overlap.
--   middleware/handlerMiddleware — genuinely multiple and ordered; arrays,
--     concatenated.
--
-- The bag is already the RESOLVED shape by the time anything reads it: the
-- node builder's own meta fold produces exactly this, so `get_http_meta` is a
-- typed read with a non-table guard, NOT a resolver. It predates that design
-- (it used to fold an array of directives by `kind` at read time) and is kept
-- as a named function purely because every read site already calls it.
--
-- VERB DISPATCH (tag-set.md § "HTTP verb selection"):
--   readOnly = true                       → GET
--   idempotent = true, destructive = true → DELETE
--   idempotent = true, destructive ≠ true → PUT    (unknown ≠ true)
--   otherwise                             → POST   (conservative)
--
-- An explicit `meta.http.verb` always wins, checked before tags. Tags are
-- three-valued (true / false / unknown), and unknown is NOT false. Tags are
-- read from the node's OWN meta — there is no ancestor inheritance, by
-- design (see tags.lua's note on why inheritance-by-position is rejected).

if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local tags_mod = require("lib.api-tree.tags")

local M = {}

-- ── Types ────────────────────────────────────────────────────────────────

-- A node's meta bag as this module sees it: open, untyped values. Declared
-- structurally rather than imported from the node module, matching tags.lua
-- and cli_projector.lua, which declare their own `NodeView`/`Meta` for the
-- same reason — only runtime functions cross a module boundary here.
--:: Meta = { [string]: unknown }

-- A projector fetch function. Declared as loosely as http_adapter.lua's own
-- `FetchFn` and for the same reason: this module never CALLS one, it only
-- carries them through the meta bag, and pinning the request/response types
-- here would couple `meta.http` to http_value.lua for no gain.
--:: FetchFn = (req: unknown) -> unknown

-- `http.middleware(...)` — a transport-level wrapper around the fetch
-- function. A branch node's contribution scopes its whole subtree; a leaf's
-- scopes only itself. Composition across ancestors happens at route-collection
-- time, not here.
--:: HttpMiddleware = (inner: FetchFn) -> FetchFn

-- The handler-invoking call `http.handlerMiddleware(...)` wraps: it receives
-- the assembled input bag and the per-request store bag.
--:: HandlerCall = (input: { [string]: unknown }, stores: { [string]: { [string]: unknown } }) -> unknown

-- `http.handlerMiddleware(...)` — a wrapper one level in from `middleware`,
-- around the handler call rather than around the transport. Composes like an
-- onion: the first entry is the OUTERMOST wrapper.
--:: HttpHandlerMiddleware = (next: HandlerCall) -> HandlerCall

-- `http.response(...)` — status/header overrides materialized into the
-- handler's response. Last-wins as a WHOLE object, not merged field by field.
--
-- `headers` is single-valued (`{ [string]: string }`) while the response VALUE
-- model's header bag is multi-valued: this is the AUTHORING shape, where one
-- header literal per name is what an author writes, and it is turned into the
-- wire shape by `http_value.headers_from_map`. Matching the TS side's
-- `Record<string, string>` here is deliberate — an author who genuinely needs
-- a repeated field sets it on the response value, which is where repetition is
-- expressible.
--:: HttpResponseOverride = { status?: integer, headers?: { [string]: string } }

-- `http.paginated(...)` — hints for a CLIENT that already knows the endpoint
-- paginates. Whether an endpoint paginates at all is a runtime shape check on
-- the actual response (page.lua's `is_page_shape`); this only overrides the
-- client's parameter-name defaults when they do not apply.
--:: HttpPaginatedHints = { style?: "cursor" | "offset", inputCursorParam?: string, inputOffsetParam?: string, inputLimitParam?: string }

-- Per-param store overrides — the same shape input.lua's `SourceMap` declares.
-- Restated rather than imported so this module's type surface does not force a
-- require of the assembler just to name a meta field.
--:: HttpSourceMap = { [string]: { store: string, key?: string } }

-- Per-field wire-encoding overrides, layered on top of `sourceMap`'s per-field
-- STORE choice. Each entry is either a base-profile NAME or a decoder function
-- run in place of the default decode for that field.
--:: HttpEncodingMap = { [string]: unknown }

-- The `meta.http` bag itself — every key optional, since a node contributes
-- only the keys it names.
--
-- `validate` is `unknown` rather than a declared validator shape ON PURPOSE:
-- nothing in this module interprets it. It is carried opaquely to whichever
-- module runs it, and pinning a shape here would freeze that decision from a
-- module that has no stake in it.
--:: HttpMetaProperties = { verb?: string, method?: string, moveTo?: string, response?: HttpResponseOverride, paginated?: HttpPaginatedHints, validate?: unknown, sourceMap?: HttpSourceMap, encodingMap?: HttpEncodingMap, middleware?: { [integer]: HttpMiddleware }, handlerMiddleware?: { [integer]: HttpHandlerMiddleware } }

-- ── Narrowing predicates ─────────────────────────────────────────────────
--
-- Both mirror the TS side's `typeof x === "object" && x !== null` guard
-- exactly — no more, no less. They are written as `v is T` predicates rather
-- than casts because that is this repo's idiom (stream.lua's `is_chunk_effect`,
-- http_adapter.lua's `is_response_value`), and because a predicate states the
-- trust boundary at the one place the value crosses it.
--
-- Neither inspects individual fields. Doing so would be stricter than the
-- source and would silently drop a bag carrying a key this port has not seen
-- yet — `meta.http` is an OPEN bag by design.

--: (v: unknown) -> v is HttpMetaProperties
local function is_http_meta_properties(v)
	return type(v) == "table"
end

--: (v: unknown) -> v is { [string]: boolean }
local function is_tag_bag(v)
	return type(v) == "table"
end

-- ── Accessor ─────────────────────────────────────────────────────────────

-- Read `meta.http` off a node's meta. Returns an empty bag when the key is
-- absent or is not a table, so every read site can index the result without a
-- nil guard — the one thing this function gives over a bare `meta.http`.
--: (meta: Meta) -> HttpMetaProperties
function M.get_http_meta(meta)
	local h = meta.http
	if not is_http_meta_properties(h) then return {} end
	return h
end

-- ── Verb derivation ──────────────────────────────────────────────────────

-- The explicit `meta.http.verb` override, when one is present and is a string.
--: (meta: Meta) -> string | nil
local function verb_directive(meta)
	local h = M.get_http_meta(meta)
	local verb = h.verb
	if type(verb) ~= "string" then return nil end
	return verb
end

-- Derive the HTTP verb a leaf should be exposed under, from its own meta.
--
-- Uppercases an explicit override (`http.verb("get")` and `http.verb("GET")`
-- name the same method — HTTP method tokens are case-sensitive on the wire,
-- so normalizing at derivation is what makes the lowercase authoring spelling
-- safe rather than silently broken).
--
-- Tag-derived verbs come out of the lattice already resolved by
-- `tags.resolve_tags`, which is why `readOnly` alone suffices for GET: the
-- lattice has already lifted `readOnly ⇒ idempotent`, and `readOnly` and
-- `destructive` cannot both hold.
--: (meta: Meta) -> string
function M.verb_from_tags(meta)
	local override = verb_directive(meta)
	if override ~= nil then return override:upper() end

	local raw = meta.tags
	local bag = is_tag_bag(raw) and raw or {}
	local resolved = tags_mod.resolve_tags(bag)

	-- readOnly = true → GET (lattice: safe ⇒ idempotent, safe ⇒ ¬destructive)
	if resolved.readOnly == true then return "GET" end
	-- idempotent = true and destructive = true → DELETE
	if resolved.idempotent == true and resolved.destructive == true then return "DELETE" end
	-- idempotent = true, destructive unknown or false → PUT
	if resolved.idempotent == true then return "PUT" end
	-- Unknown or false idempotent → POST, the conservative reading
	return "POST"
end

-- ── Response helpers ─────────────────────────────────────────────────────

-- Build an `Allow` header value from a list of method tokens: de-duplicated,
-- SORTED, comma-space joined.
--
-- The sort is load-bearing twice over. It is what the TS source does
-- (`[...new Set(verbs)].sort().join(", ")`), and it is what makes the output
-- deterministic under LuaJIT at all — de-duplication goes through a table
-- keyed by token, and LuaJIT randomizes hash-part iteration order, so an
-- unsorted result would differ run to run for the same input. A response
-- header that changes between identical requests breaks caching and makes
-- fixtures untestable.
--
-- Sorting is byte-wise, matching JavaScript's default (code-unit) `sort` for
-- the ASCII method tokens HTTP admits.
--: (verbs: string[]) -> string
function M.allow_header(verbs)
	--: { [string]: boolean }
	local seen = {}
	--: { [integer]: string }
	local unique = {}
	for i = 1, #verbs do
		local verb = verbs[i]
		if not seen[verb] then
			seen[verb] = true
			unique[#unique + 1] = verb
		end
	end
	table.sort(unique)
	return table.concat(unique, ", ")
end

return M
