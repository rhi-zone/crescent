-- lib/fractal/jsonrpc_wire.lua — JSON-RPC 2.0 wire-format shapes, the standard
-- error envelope, and the request-shape sniff. Ported from fractal's
-- packages/json-rpc-api-projector/src/wire.ts.
--
-- Shared by jsonrpc_server.lua (which builds these) and jsonrpc_client.lua
-- (which parses them) — its own module rather than duplicated or defined
-- one-sided, since both sides need the exact same shape.
--
-- NULL vs ABSENT. This is the one place the port has to say something the
-- TypeScript source never had to. JavaScript distinguishes `undefined` (key
-- absent) from `null` (key present, holding null); Lua does not — assigning
-- `nil` removes the key. JSON-RPC leans on exactly that distinction in two
-- places, so both use `lib/null`'s shared sentinel rather than `nil`:
--
--   - `id` ABSENT means Notification (§4.1, never answered). `id` present and
--     null is an ordinary Request whose response carries `"id": null`. The
--     decoder maps JSON `null` to the sentinel, so `msg.id == nil` is
--     "absent" and `msg.id == null.null` is "present, null" — the same two
--     states JS reads as `undefined` and `null`.
--   - a Response's `id` and `result` must SERIALIZE as `null`, never be
--     omitted (§5: `result` is required on success; §5.1's error responses
--     carry `"id": null` when the request could not be correlated). A Lua
--     table cannot hold `nil` there, so the sentinel is what goes in the
--     field and the JSON encoder renders it as `null`.
--
-- Spec: https://www.jsonrpc.org/specification

if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local null    = require("lib.null")
local codes   = require("lib.fractal.type_ref_json_rpc")
local fractal = require("lib.fractal")

local M = {}

-- ── Standard error codes (§5.1) ──────────────────────────────────────────
--
-- Re-exported from type_ref_json_rpc.lua — the one place they are defined,
-- mirroring wire.ts's re-export from type-ir's json-rpc.ts. A consumer of this
-- module never has to reach past it for a code.

M.PARSE_ERROR      = codes.PARSE_ERROR
M.INVALID_REQUEST  = codes.INVALID_REQUEST
M.METHOD_NOT_FOUND = codes.METHOD_NOT_FOUND
M.INVALID_PARAMS   = codes.INVALID_PARAMS
M.INTERNAL_ERROR   = codes.INTERNAL_ERROR
M.SERVER_ERROR_MIN = codes.SERVER_ERROR_MIN
M.SERVER_ERROR_MAX = codes.SERVER_ERROR_MAX

-- The value that serializes to JSON `null`, re-exported so a caller building
-- an id or reading one back never has to know which module minted it — and,
-- more importantly, never mints its own (`lib/null`'s doc: a private `{}`
-- sentinel compares unequal to everyone else's).
M.NULL = null.null

-- ── Wire shapes ──────────────────────────────────────────────────────────

-- A request `id` (§4): a string, a number, or null — the last carried as
-- `M.NULL`. Typed `unknown` rather than `string | number | <sentinel table>`
-- deliberately: every id this port handles arrives out of a JSON decode, whose
-- result is `unknown`, and a tighter alias would buy a cast at every read
-- without excluding anything — the sentinel is a table, so the union would
-- have to admit tables anyway. Callers compare against `M.NULL` and otherwise
-- pass the value through untouched, which is all the spec asks (§4: the server
-- MUST reply with the same id it was sent).
--:: JsonRpcId = unknown

-- A Request object (§4). `id` absent = a Notification (§4.1).
--:: JsonRpcRequest = { jsonrpc: string, method: string, params?: unknown, id?: JsonRpcId }

-- A Notification (§4.1) — a Request with no `id`. Sent server -> client for
-- streaming results (see jsonrpc_server.lua's "Streaming" section) or
-- client -> server for a fire-and-forget call.
--:: JsonRpcNotification = { jsonrpc: string, method: string, params?: unknown }

-- An error object (§5.1).
--:: JsonRpcErrorObject = { code: number, message: string, data?: unknown }

--:: JsonRpcSuccessResponse = { jsonrpc: string, result: unknown, id: JsonRpcId }
--:: JsonRpcErrorResponse = { jsonrpc: string, error: JsonRpcErrorObject, id: JsonRpcId }

-- Either flavor of Response object. Not a discriminated union on a `kind`
-- field the way the rest of this port's DUs are — JSON-RPC discriminates by
-- which of `result`/`error` is PRESENT (§5), so the arms are told apart by
-- `is_error_response` below rather than by a tag read.
--:: JsonRpcResponse = JsonRpcSuccessResponse | JsonRpcErrorResponse

-- ── Constructors ─────────────────────────────────────────────────────────

-- Build an error Response object (§5.1). `data` is omitted entirely when nil,
-- matching the TS spread — an absent `data` key and a `data: null` are
-- different messages on the wire, and only the former is what "no extra
-- information" means here.
--: (id: JsonRpcId, code: number, message: string, data: unknown) -> JsonRpcErrorResponse
function M.error_response(id, code, message, data)
	local e = { code = code, message = message } --[[: JsonRpcErrorObject]]
	if data ~= nil then e.data = data end
	return { jsonrpc = "2.0", error = e, id = id }
end

-- Build a success Response object (§5). `result` nil becomes `M.NULL`, never
-- an absent key: §5 requires `result` on every successful response, so a
-- handler returning nothing still carries `"result": null`.
--: (id: JsonRpcId, result: unknown) -> JsonRpcSuccessResponse
function M.success_response(id, result)
	local r = result
	if r == nil then r = M.NULL end
	return { jsonrpc = "2.0", result = r, id = id }
end

-- ── Predicates ───────────────────────────────────────────────────────────

-- True when `res` is specifically an error Response — i.e. carries an `error`
-- key. The `"error" in res` test of the TS source; Lua's key-absence and
-- nil-value being the same state costs nothing here, because a well-formed
-- response never holds a nil `error`.
--: (res: JsonRpcResponse) -> boolean
function M.is_error_response(res)
	local r = res --[[: { [string]: unknown }]]
	return r.error ~= nil
end

-- True when `v` has the minimal shape of a Request object — `jsonrpc = "2.0"`
-- and a string `method`. Anything else (wrong version, missing or non-string
-- method) is an Invalid Request (§4), INCLUDING a batch element that is not an
-- object at all, which the batch walk reports per-element rather than failing
-- the whole batch.
--
-- The array test is `lib/fractal`'s `is_array`, under which an empty table is
-- NOT an array; that is the right answer here for the same reason it is there
-- — an empty table reaching this predicate fails it anyway, for want of
-- `jsonrpc`/`method`.
--: (v: unknown) -> boolean
function M.is_request_shape(v)
	if type(v) ~= "table" then return false end
	local t = v --[[: { [string]: unknown }]]
	if fractal.is_array(t) then return false end
	if t.jsonrpc ~= "2.0" then return false end
	return type(t.method) == "string"
end

return M
