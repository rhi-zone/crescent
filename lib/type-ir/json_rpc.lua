-- lib/type-ir/json_rpc.lua — the JSON-RPC 2.0 standard error codes
-- and the fixed error-object schema, ported from fractal's
-- packages/type-ir/src/json-rpc.ts.
--
-- PARTIAL PORT, DELIBERATELY FENCED. json-rpc.ts has two halves: the wire-level
-- constants plus `jsonRpcErrorSchema` (ported here), and the TypeRef lowering
-- `toJsonRpcMethod`/`toJsonRpcMethods` that turns an `interface` TypeRef into
-- per-method params/result/error schemas (NOT ported). The lowering is the
-- type-ir sibling of `json_schema.lua`'s projection and belongs with
-- the rest of that family; nothing in the framework-layer projector
-- (`jsonrpc_project.lua`, `jsonrpc_server.lua`) consumes it — those read a
-- derived `SchemaMap` handed in by a caller, exactly as the TypeScript
-- framework layer does. This file exists so the codes and the envelope have
-- ONE definition, as the TS source insists ("the ONE place they're defined;
-- this package never redeclares them"), rather than being spelled a second
-- time inside the projector. See TODO.md for the remaining half.
--
-- The codes are the spec's own (§5.1). They are NOT a re-export of
-- `lib/jsonrpc`'s identically-valued constants: that library is an independent
-- dispatcher with its own handler contract, and this port's server does not
-- route through it (see jsonrpc_server.lua's module doc). Two libraries
-- agreeing on numbers the specification fixes is not duplication of a
-- decision — neither module is free to choose a different value.
--
-- Spec: https://www.jsonrpc.org/specification

if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local M = {}

-- ── Standard JSON-RPC 2.0 error codes (§5.1) ─────────────────────────────

-- Invalid JSON was received by the server.
M.PARSE_ERROR = -32700
-- The JSON sent is not a valid Request object.
M.INVALID_REQUEST = -32600
-- The method does not exist / is not available.
M.METHOD_NOT_FOUND = -32601
-- Invalid method parameter(s).
M.INVALID_PARAMS = -32602
-- Internal JSON-RPC error.
M.INTERNAL_ERROR = -32603
-- Lower bound (inclusive) of the range reserved for implementation-defined
-- server errors (-32000 to -32099).
M.SERVER_ERROR_MIN = -32099
-- Upper bound (inclusive) of the same range.
M.SERVER_ERROR_MAX = -32000

-- ── Error envelope (§5.1) ────────────────────────────────────────────────

-- Same open-bag reading of a JSON Schema `json_schema.lua` uses.
--:: JsonSchema = { [string]: unknown }

-- The standard JSON-RPC 2.0 error object schema: `{ code, message, data? }`.
-- `data_schema`, when supplied, constrains `data`'s shape; nil leaves `data`
-- unconstrained (any value, or none at all, validates) — the empty schema,
-- which in Lua is the same value as an empty array, the ambiguity
-- `json_schema.lua`'s module doc already documents for `unknown`.
--: (data_schema: JsonSchema | nil) -> JsonSchema
function M.error_schema_from_data_schema(data_schema)
	return {
		type = "object",
		properties = {
			code = { type = "integer" },
			message = { type = "string" },
			data = data_schema or {},
		},
		required = { "code", "message" },
	}
end

return M
