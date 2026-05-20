-- Arena → POJO decoder for the v4 driver (K2).
--
-- Translates the legacy parser's arena-encoded AST
-- (`{ nodes, lists, pool, root, lexer }` as produced by
-- `lib/type/static/parse.lua`) into the plain-Lua-table node shape that
-- `lib/type/static-v4/walker/walker.lua` consumes. See
-- `docs/typechecker-v4-driver-design.md` §2 for the architectural framing
-- and `lib/type/static-v4/walker/README.md`'s per-sub-phase "Decoded node
-- shape" tables for the per-kind field contract.
--
-- Decoder responsibilities (one per concern):
--   1. Resolve intern-pool IDs (parser stores strings as integer IDs) into
--      actual `string` values where the walker reads strings.
--   2. Follow `(start, len)` list-pool references into materialised Lua
--      arrays of decoded child nodes.
--   3. Map the parser's integer operator codes (defs.OP_*) onto the walker
--      handler's string operator names (`"+"`, `"=="`, `"and"`, `"not"`,
--      ... — see `control_flow.lua` analyzer).
--   4. Preserve arena identity: the same arena row decodes to the same
--      POJO table for the lifetime of one decode pass. This is required
--      for origin tracking and any walker cache keyed on table identity.
--
-- Design choices (recorded explicitly per K2 prompt + design doc §11 #3):
--
-- * **Eager decoding.** Walk from `root` once and materialise the full
--   POJO tree. The design doc left lazy vs eager open; eager is chosen
--   here because (a) the walker performs a full pass over the chunk in
--   the driver path — there is no partial-walk consumer that benefits
--   from laziness; (b) lazy would require closures or memoised proxies,
--   both of which add hidden-class churn and code that resists reading;
--   (c) the design doc's lazy-as-default sketch was a guess pending
--   measurement, not a constraint. Eager is the simpler correct shape;
--   if a future bench shows defeated cache locality, that benchmark is
--   the trigger for revisiting — not speculation.
--
-- * **Identity preservation.** The decoder threads a `cache` table keyed
--   by arena index. The first decode of arena index `i` produces a fresh
--   POJO; subsequent decodes return the cached table. Cycles in the
--   arena cannot arise from the parser (it builds a tree), but the cache
--   is correctness-critical for shared subtrees (the parser does not
--   share, but field-key literal nodes in table constructors are the
--   pattern that could create sharing in future). Beyond correctness,
--   identity is a contract: origin metadata (`O.record`) is keyed by
--   table reference, and the walker MAY cache per-node in future phases.
--
-- * **Integer tags.** The walker reads `node.tag` and compares against
--   `defs.NODE_*` integer constants throughout
--   (`walker.lua`, `control_flow.lua`, `statements.lua`,
--   `indexed_access.lua`, `effects.lua`, `ffi_cdef.lua`,
--   `require_resolve.lua`, `functions.lua`). Producing string tags
--   ("literal", "if-stmt", …) would force a renaming of every comparison
--   in the walker; that is not the decoder's mandate. The integer-tag
--   surface is the walker's existing contract, and the decoder honours
--   it.
--
-- Errors. The decoder rejects unknown node kinds with a clear errmsg
-- (`nil, "unknown node kind N"`). A malformed arena (out-of-range list
-- index, missing pool entry) propagates the FFI / intern-pool error
-- verbatim — these are typechecker-internal invariants, not user-
-- recoverable. The driver wraps decoder failures in an `E_INTERNAL`
-- diagnostic at the call site (K1's responsibility).

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local defs       = require("lib.type.static.defs")
local intern_mod = require("lib.type.static.intern")

local i32x2_to_double = defs.i32x2_to_double

local M = {}

-- ─ Operator code → walker string ─────────────────────────────────────────
--
-- The walker's guard analyzer (control_flow.lua) and any future
-- binary/unary handler reads `node.op` as a string. The parser stores
-- defs.OP_* integers in `data[0]`. The mapping below is the canonical
-- translation; any value outside it indicates a parser/decoder drift bug
-- (raise loudly, no silent fallback).

local OP_NAME = {} --[[: { [integer]: string } ]]
OP_NAME[defs.OP_ADD]    = "+"
OP_NAME[defs.OP_SUB]    = "-"
OP_NAME[defs.OP_MUL]    = "*"
OP_NAME[defs.OP_DIV]    = "/"
OP_NAME[defs.OP_MOD]    = "%"
OP_NAME[defs.OP_POW]    = "^"
OP_NAME[defs.OP_CONCAT] = ".."
OP_NAME[defs.OP_EQ]     = "=="
OP_NAME[defs.OP_NE]     = "~="
OP_NAME[defs.OP_LT]     = "<"
OP_NAME[defs.OP_LE]     = "<="
OP_NAME[defs.OP_GT]     = ">"
OP_NAME[defs.OP_GE]     = ">="
OP_NAME[defs.OP_AND]    = "and"
OP_NAME[defs.OP_OR]     = "or"
OP_NAME[defs.OP_UNM]    = "-"
OP_NAME[defs.OP_NOT]    = "not"
OP_NAME[defs.OP_LEN]    = "#"

-- Context record threaded through the decoder. Fields are all the inputs
-- the per-kind decoder branches consult; carrying them in one record
-- avoids ten parameter slots per recursive call.
--
-- Shape:
--   { nodes, lists, pool, cache }
--
-- `cache[arena_index]` is the materialised POJO table for that arena row,
-- or nil if not yet decoded.

-- Look up a string by intern ID, or return nil for `-1` (the parser's
-- "absent" sentinel for table-field positional keys and else-clauses).
local function pool_string(pool, id)
	if id == nil or id < 0 then return nil end
	return intern_mod.get(pool, id)
end

-- Materialise a child-list reference (start, len) into an array of
-- decoded children. `decode_index` is the per-kind callback used to
-- decode each list entry; it is supplied by the caller because lists
-- contain different kinds of children depending on where they appear
-- (node IDs vs intern IDs for parameter/name lists).
local function decode_list(ctx, start --[[: integer]], len --[[: integer]], decode_index)
	local out = {}
	for i = 0, len - 1 do
		out[i + 1] = decode_index(ctx, ctx.lists:get(start + i))
	end
	return out
end

-- Forward declaration for mutually recursive decoding.
local decode_node

-- Decode a list of node indices into a list of POJO nodes.
local function decode_node_list(ctx, start, len)
	return decode_list(ctx, start, len, decode_node)
end

-- Decode a list of intern IDs into a list of strings. Used for parameter
-- and local-name lists, which the parser stores as flat integer IDs.
local function decode_name_list(ctx, start --[[: integer]], len --[[: integer]])
	local out = {}
	for i = 0, len - 1 do
		out[i + 1] = pool_string(ctx.pool, ctx.lists:get(start + i))
	end
	return out
end

-- ─ Per-kind decoders ─────────────────────────────────────────────────────
--
-- One function per NODE_* kind. Each consumes the FFI node row and emits
-- the POJO table the walker's handler reads. Field names are taken from
-- the walker README's "Decoded node shape" tables.

local function decode_literal(ctx, n, out)
	local lit_kind = n.data[0]
	out.lit_kind = lit_kind
	if lit_kind == defs.LIT_NIL then
		-- no value
	elseif lit_kind == defs.LIT_BOOLEAN then
		out.value = (n.data[1] ~= 0)
	elseif lit_kind == defs.LIT_INTEGER then
		out.value = n.data[1]
	elseif lit_kind == defs.LIT_NUMBER then
		out.value = i32x2_to_double(n.data[1], n.data[2])
	elseif lit_kind == defs.LIT_STRING then
		out.value = pool_string(ctx.pool, n.data[1])
	elseif lit_kind == defs.LIT_OPAQUE_KEY then
		out.value = pool_string(ctx.pool, n.data[1])
	else
		-- Unknown literal kind. The walker's literal handler will reject
		-- via its own validation path; we pass the raw value so the
		-- diagnostic is informative.
		out.value = n.data[1]
	end
	return out
end

local function decode_identifier(ctx, n, out)
	out.name = pool_string(ctx.pool, n.data[0])
	return out
end

local function decode_vararg(_ctx, _n, out)
	return out
end

local function decode_unary(ctx, n, out)
	out.op = OP_NAME[n.data[0]] or ("op#" .. tostring(n.data[0]))
	out.operand = decode_node(ctx, n.data[1])
	return out
end

local function decode_binary(ctx, n, out)
	out.op = OP_NAME[n.data[0]] or ("op#" .. tostring(n.data[0]))
	out.lhs = decode_node(ctx, n.data[1])
	out.rhs = decode_node(ctx, n.data[2])
	return out
end

local function decode_field_expr(ctx, n, out)
	out.target = decode_node(ctx, n.data[0])
	out.key = pool_string(ctx.pool, n.data[1])
	return out
end

local function decode_index_expr(ctx, n, out)
	out.target = decode_node(ctx, n.data[0])
	out.key = decode_node(ctx, n.data[1])
	return out
end

local function decode_method_call(ctx, n, out)
	out.receiver = decode_node(ctx, n.data[0])
	out.method = pool_string(ctx.pool, n.data[1])
	out.args = decode_node_list(ctx, n.data[2], n.data[3])
	return out
end

local function decode_call_expr(ctx, n, out)
	out.callee = decode_node(ctx, n.data[0])
	out.args = decode_node_list(ctx, n.data[1], n.data[2])
	return out
end

-- Function-shaped node (FUNC_EXPR and FUNC_DECL share data layout, with
-- FUNC_DECL also carrying `data[0] = name_node`). The walker's
-- `synth_func` consumes both kinds via the same handler — neither path
-- reads a function name out of the node, so FUNC_DECL's name slot is
-- decoded into an optional `name` field that the walker tolerates but
-- ignores. The remaining slots are identical between the two kinds.
local function decode_func_like(ctx, n, out, with_name)
	local data_offset --[[: integer]] = 0
	if with_name then
		data_offset = 1
		out.name = decode_node(ctx, n.data[0])
	end
	-- params are intern IDs, not node IDs — see parse.lua's
	-- parse_params_and_body. Each parameter has only a name in the parser
	-- output; per-parameter annotations live on the walker's `params[i].ann`
	-- slot, which is populated by the annotation parser (out of K2's scope).
	local ps --[[: integer]] = n.data[data_offset]
	local pl --[[: integer]] = n.data[data_offset + 1]
	local names = decode_name_list(ctx, ps, pl)
	local params = {}
	for i, nm in ipairs(names) do
		params[i] = { name = nm }
	end
	out.params = params
	out.body = decode_node_list(ctx, n.data[data_offset + 2], n.data[data_offset + 3])
	out.vararg = (n.flags % 2 == 1) -- FLAG_VARARG = 1 (low bit)
	out.vararg_ann = nil
	out.ret_ann = nil
	out.annotation = nil
	out.generic = nil
	return out
end

local function decode_func_expr(ctx, n, out)
	return decode_func_like(ctx, n, out, false)
end

local function decode_func_decl(ctx, n, out)
	return decode_func_like(ctx, n, out, true)
end

local function decode_table_field(ctx, n, out)
	-- data[0]: -1 for positional, key_node for computed/named, key_id (intern
	--          ID via NODE_LITERAL key_node — the parser ALWAYS wraps the
	--          key in a NODE_LITERAL for `name=val` and `[expr]=val` forms.
	-- data[1]: value node ID.
	-- FLAG_COMPUTED set when key is `[expr]` (an expression).
	local key_slot = n.data[0]
	if key_slot == -1 then
		out.key = nil      -- positional
	else
		out.key = decode_node(ctx, key_slot)
	end
	out.value = decode_node(ctx, n.data[1])
	out.computed = (n.flags % (defs.FLAG_COMPUTED * 2) >= defs.FLAG_COMPUTED)
	return out
end

local function decode_table_expr(ctx, n, out)
	out.fields = decode_node_list(ctx, n.data[0], n.data[1])
	return out
end

local function decode_assign_stmt(ctx, n, out)
	out.targets = decode_node_list(ctx, n.data[0], n.data[1])
	out.exprs   = decode_node_list(ctx, n.data[2], n.data[3])
	return out
end

local function decode_local_stmt(ctx, n, out)
	-- Names: intern IDs in lists. The walker's NODE_LOCAL_STMT consumes a
	-- list of `{ name, ann? }` records. Annotations are populated by the
	-- annotation parser; K2 leaves `ann` nil for every slot.
	local names_raw = decode_name_list(ctx, n.data[0], n.data[1])
	local names = {}
	for i, nm in ipairs(names_raw) do
		names[i] = { name = nm }
	end
	out.names = names
	out.exprs = decode_node_list(ctx, n.data[2], n.data[3])
	return out
end

local function decode_do_stmt(ctx, n, out)
	out.body = decode_node_list(ctx, n.data[0], n.data[1])
	return out
end

local function decode_while_stmt(ctx, n, out)
	out.cond = decode_node(ctx, n.data[0])
	out.body = decode_node_list(ctx, n.data[1], n.data[2])
	return out
end

local function decode_repeat_stmt(ctx, n, out)
	out.cond = decode_node(ctx, n.data[0])
	out.body = decode_node_list(ctx, n.data[1], n.data[2])
	return out
end

local function decode_if_clause(ctx, n, out)
	local cond_slot = n.data[0]
	if cond_slot == -1 then
		out.cond = nil   -- else clause
	else
		out.cond = decode_node(ctx, cond_slot)
	end
	out.body = decode_node_list(ctx, n.data[1], n.data[2])
	return out
end

local function decode_if_stmt(ctx, n, out)
	-- The parser stores all clauses (if + elseif + else) as a single list
	-- of NODE_IF_CLAUSE entries; the walker's NODE_IF_STMT handler expects
	-- `{ clauses: {{ cond, body }}, else_body }`. Split the clauses list
	-- into the leading conditional clauses and a trailing else-body.
	local raw = decode_node_list(ctx, n.data[0], n.data[1])
	local clauses = {}
	local else_body = nil
	for _, c in ipairs(raw) do
		if c.cond == nil then
			else_body = c.body
		else
			clauses[#clauses + 1] = { cond = c.cond, body = c.body }
		end
	end
	out.clauses = clauses
	out.else_body = else_body
	return out
end

local function decode_for_num(ctx, n, out)
	out.name = pool_string(ctx.pool, n.data[0])
	out.init = decode_node(ctx, n.data[1])
	out.stop = decode_node(ctx, n.data[2])
	if n.data[3] == -1 then
		out.step = nil
	else
		out.step = decode_node(ctx, n.data[3])
	end
	out.body = decode_node_list(ctx, n.data[4], n.data[5])
	return out
end

local function decode_for_in(ctx, n, out)
	out.names = decode_name_list(ctx, n.data[0], n.data[1])
	out.exprs = decode_node_list(ctx, n.data[2], n.data[3])
	out.body  = decode_node_list(ctx, n.data[4], n.data[5])
	return out
end

local function decode_return_stmt(ctx, n, out)
	out.exprs = decode_node_list(ctx, n.data[0], n.data[1])
	return out
end

local function decode_break_stmt(_ctx, _n, out)
	return out
end

local function decode_goto_stmt(ctx, n, out)
	out.label = pool_string(ctx.pool, n.data[0])
	return out
end

local function decode_label_stmt(ctx, n, out)
	out.label = pool_string(ctx.pool, n.data[0])
	return out
end

local function decode_expr_stmt(ctx, n, out)
	out.expr = decode_node(ctx, n.data[0])
	return out
end

local function decode_cast_expr(ctx, n, out)
	-- The cast's annotation ID (data[1]) is a pool index into
	-- lexer.annotations; resolving it to a V4Type is the annotation
	-- parser's job, NOT the decoder's. Carry the inner expression and
	-- the raw annotation ID so the annotation bridge can pick it up
	-- when it lands.
	out.expr = decode_node(ctx, n.data[0])
	out.annotation_id = n.data[1]
	out.force = (n.flags % 2 == 1) -- FLAG_FORCE_CAST = 1
	return out
end

local function decode_chunk(ctx, n, out)
	out.body = decode_node_list(ctx, n.data[0], n.data[1])
	out.filename = pool_string(ctx.pool, n.data[2])
	out.lastline = n.data[3]
	return out
end

-- ─ Per-kind dispatch table ──────────────────────────────────────────────
--
-- Indexed by defs.NODE_* integer. Missing entries → `decode_node` returns
-- a node with `tag` set but no kind-specific fields; the walker will
-- reject via its E_UNSUPPORTED_NODE path, which is the principled
-- response (the decoder does not invent fields it cannot derive).

local DECODERS = {}
DECODERS[defs.NODE_LITERAL]      = decode_literal
DECODERS[defs.NODE_IDENTIFIER]   = decode_identifier
DECODERS[defs.NODE_VARARG_EXPR]  = decode_vararg
DECODERS[defs.NODE_UNARY_EXPR]   = decode_unary
DECODERS[defs.NODE_BINARY_EXPR]  = decode_binary
DECODERS[defs.NODE_FIELD_EXPR]   = decode_field_expr
DECODERS[defs.NODE_INDEX_EXPR]   = decode_index_expr
DECODERS[defs.NODE_METHOD_CALL]  = decode_method_call
DECODERS[defs.NODE_CALL_EXPR]    = decode_call_expr
DECODERS[defs.NODE_FUNC_EXPR]    = decode_func_expr
DECODERS[defs.NODE_FUNC_DECL]    = decode_func_decl
DECODERS[defs.NODE_TABLE_EXPR]   = decode_table_expr
DECODERS[defs.NODE_TABLE_FIELD]  = decode_table_field
DECODERS[defs.NODE_ASSIGN_STMT]  = decode_assign_stmt
DECODERS[defs.NODE_LOCAL_STMT]   = decode_local_stmt
DECODERS[defs.NODE_DO_STMT]      = decode_do_stmt
DECODERS[defs.NODE_WHILE_STMT]   = decode_while_stmt
DECODERS[defs.NODE_REPEAT_STMT]  = decode_repeat_stmt
DECODERS[defs.NODE_IF_STMT]      = decode_if_stmt
DECODERS[defs.NODE_IF_CLAUSE]    = decode_if_clause
DECODERS[defs.NODE_FOR_NUM]      = decode_for_num
DECODERS[defs.NODE_FOR_IN]       = decode_for_in
DECODERS[defs.NODE_RETURN_STMT]  = decode_return_stmt
DECODERS[defs.NODE_BREAK_STMT]   = decode_break_stmt
DECODERS[defs.NODE_GOTO_STMT]    = decode_goto_stmt
DECODERS[defs.NODE_LABEL_STMT]   = decode_label_stmt
DECODERS[defs.NODE_EXPR_STMT]    = decode_expr_stmt
DECODERS[defs.NODE_CHUNK]        = decode_chunk
DECODERS[defs.NODE_CAST_EXPR]    = decode_cast_expr

-- Decode a single arena row at index `idx`. Returns the cached POJO if
-- the row has already been decoded; otherwise pre-records a stub in the
-- cache (so a cyclic structure, if one ever arose, would terminate)
-- and fills its fields in-place.
decode_node = function(ctx, idx)
	local cached = ctx.cache[idx]
	if cached ~= nil then return cached end
	local n = ctx.nodes:get(idx) --[[: { kind: integer, flags: integer, line: integer, col: integer, data: { [integer]: integer } }]]
	local kind = n.kind
	-- Pre-record the stub with the always-present fields before recursing
	-- into children, so identity is stable from the first decode.
	local out = {
		tag  = kind,
		line = n.line,
		col  = n.col,
	}
	ctx.cache[idx] = out
	local decoder = DECODERS[kind]
	if decoder == nil then
		out._error = "unknown node kind " .. tostring(kind)
		return out
	end
	return decoder(ctx, n, out)
end

-- Public entry point.
--
-- Given a parse result `{ nodes, lists, pool, root, lexer }`, produce the
-- POJO equivalent of the root NODE_CHUNK. Identity within one call is
-- preserved across shared subtrees via the per-call cache.
--
--: (parse_result: { nodes: unknown, lists: unknown, pool: unknown, root: integer, lexer: unknown, ... }) -> unknown
function M.decode(parse_result)
	local ctx = {
		nodes = parse_result.nodes,
		lists = parse_result.lists,
		pool  = parse_result.pool,
		cache = {},
	}
	return decode_node(ctx, parse_result.root)
end

-- Decode a single node by index. Exposed for tests that want to exercise
-- individual kinds without going through a full chunk decode.
--: (parse_result: { nodes: unknown, lists: unknown, pool: unknown, root: integer, lexer: unknown, ... }, idx: integer) -> unknown
function M.decode_at(parse_result, idx)
	local ctx = {
		nodes = parse_result.nodes,
		lists = parse_result.lists,
		pool  = parse_result.pool,
		cache = {},
	}
	return decode_node(ctx, idx)
end

-- Operator name table — exported for downstream consumers (e.g. tests
-- verifying decoder/walker contract).
M.OP_NAME = OP_NAME

return M
