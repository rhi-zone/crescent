-- Walker sub-phase B — literals and primitive expressions.
--
-- Per docs/typechecker-ast-walker-design.md §3.1, §3.2, §3.3 and §13 Phase B.
-- This module registers SYNTHESIZE handlers for the three node kinds whose
-- semantics map one-to-one to a v4 constructor and require no subtyping,
-- call, narrowing or scope manipulation:
--
--   - NODE_LITERAL      — nil / boolean / number / integer / string literals
--   - NODE_IDENTIFIER   — a bare name lookup (§3.2)
--   - NODE_VARARG_EXPR  — the `...` expression (§3.3)
--
-- Decoded node shape (what handlers consume)
-- ──────────────────────────────────────────
-- The parser emits FFI ASTNode records (8-byte header + int32 data slots).
-- The walker operates on a decoded Lua-table view; sub-phase J wires the
-- FFI→walker bridge. The decoded shape is:
--
--   NODE_LITERAL
--     { tag, line, col, lit_kind: integer, value: unknown }
--       lit_kind is one of defs.LIT_NIL / LIT_BOOLEAN / LIT_INTEGER /
--       LIT_NUMBER / LIT_STRING. `value` carries the Lua-typed payload
--       (boolean for LIT_BOOLEAN, number for LIT_INTEGER/LIT_NUMBER,
--       string for LIT_STRING; absent for LIT_NIL).
--
--   NODE_IDENTIFIER
--     { tag, line, col, name: string }
--
--   NODE_VARARG_EXPR
--     { tag, line, col }
--
-- This decoded shape is intentionally divorced from the FFI struct: the
-- walker's contract is over Lua tables so handlers stay portable to
-- non-parser callers (tests, REPL eval, future cdef integration).
--
-- CHECK mode
-- ──────────
-- Each of these nodes follows §2.1 "if in doubt, synthesize and subtype" —
-- the default CHECK rule in walker.lua (synthesize, then constrain against
-- expected) is sufficient. No direct CHECK handlers are registered.

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local V    = require("lib.type.static-v4")
local E    = require("lib.type.static-v4.walker.env")
local D    = require("lib.type.static-v4.walker.diag")
local defs = require("lib.type.static.defs")

-- Pull V4Type into alias scope.
local _types = require("lib.type.static-v4.types")
local _ = _types

local M = {}

-- ── NODE_LITERAL ──────────────────────────────────────────────────────────
--
-- §3.1 mapping:
--   nil          → V.prim("nil")            -- design doc admits either prim
--                                              or V.literal("nil", nil); we
--                                              pick prim — a `nil` literal
--                                              has no useful precise value,
--                                              and prim("nil") is the
--                                              canonical singleton (interned
--                                              once by V.prim).
--   boolean      → V.literal("boolean", v)  -- preserves true/false precision
--   integer      → V.literal("integer", v)
--   number       → V.literal("number", v)
--   string       → V.literal("string", v)
--
-- The parser emits LIT_INTEGER vs LIT_NUMBER on the lexer side; the walker
-- trusts that distinction rather than re-deriving it from `value`.

--: (node: { tag: integer, line: integer | nil, col: integer | nil, lit_kind: integer, value: unknown }, env: { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer }, aliases: { [string]: V4Type }, io_caps: { read_file: (path: string) -> (string | nil, string | nil), write_file: (path: string, bytes: string) -> (boolean, string | nil), mkdir: (path: string) -> (boolean, string | nil), file_exists: (path: string) -> boolean } | nil, cache_dir: string | nil, require_chain: { [string]: V4Type | boolean }, prim_index: { [string]: V4Type } }, solver: V4Solver) -> (V4Type | nil, { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer }, aliases: { [string]: V4Type }, io_caps: { read_file: (path: string) -> (string | nil, string | nil), write_file: (path: string, bytes: string) -> (boolean, string | nil), mkdir: (path: string) -> (boolean, string | nil), file_exists: (path: string) -> boolean } | nil, cache_dir: string | nil, require_chain: { [string]: V4Type | boolean }, prim_index: { [string]: V4Type } }, string | nil)
local function synth_literal(node, env, _solver)
	local k = node.lit_kind
	if k == defs.LIT_NIL then
		return V.prim("nil"), env, nil
	elseif k == defs.LIT_BOOLEAN then
		return V.literal("boolean", node.value), env, nil
	elseif k == defs.LIT_INTEGER then
		return V.literal("integer", node.value), env, nil
	elseif k == defs.LIT_NUMBER then
		return V.literal("number", node.value), env, nil
	elseif k == defs.LIT_STRING then
		return V.literal("string", node.value), env, nil
	end
	return nil, env, D.emit(env, D.E_INTERNAL,
		"walker: NODE_LITERAL with unknown lit_kind " .. tostring(k))
end

-- ── NODE_IDENTIFIER ───────────────────────────────────────────────────────
--
-- §3.2: look up the binding's current view (narrowed type if inside a
-- narrowing scope, else its declared/inferred type). Narrowing precedence
-- is enforced by E.lookup itself (overlay > binding).
--
-- Crescent disallows ambient globals (CLAUDE.md "no-ambient-globals"). An
-- unbound name MUST error rather than widen to `unknown`: the latter
-- silently legitimizes a missing declaration. The error is named so the
-- callsite produces a useful diagnostic; the position is already threaded
-- into env.source by the walker shell.

--: (node: { tag: integer, line: integer | nil, col: integer | nil, name: string }, env: { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer }, aliases: { [string]: V4Type }, io_caps: { read_file: (path: string) -> (string | nil, string | nil), write_file: (path: string, bytes: string) -> (boolean, string | nil), mkdir: (path: string) -> (boolean, string | nil), file_exists: (path: string) -> boolean } | nil, cache_dir: string | nil, require_chain: { [string]: V4Type | boolean }, prim_index: { [string]: V4Type } }, solver: V4Solver) -> (V4Type | nil, { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer }, aliases: { [string]: V4Type }, io_caps: { read_file: (path: string) -> (string | nil, string | nil), write_file: (path: string, bytes: string) -> (boolean, string | nil), mkdir: (path: string) -> (boolean, string | nil), file_exists: (path: string) -> boolean } | nil, cache_dir: string | nil, require_chain: { [string]: V4Type | boolean }, prim_index: { [string]: V4Type } }, string | nil)
local function synth_identifier(node, env, _solver)
	local name = node.name
	local ty = E.lookup(env, name)
	if ty == nil then
		return nil, env, D.emit(env, D.E_UNDEFINED_NAME,
			"undefined name " .. tostring(name))
	end
	return ty, env, nil
end

-- ── NODE_VARARG_EXPR ──────────────────────────────────────────────────────
--
-- §3.3: the enclosing function's vararg type lives in env.vararg. A vararg
-- expression outside any vararg-bearing function is a static error.
--
-- The "tuple-return position" spread semantics from §3.3 (last expression
-- of a call argument list / return / table constructor) is a property of
-- the *enclosing* node, not of the vararg node itself — sub-phase D
-- handles that on the call/return/table-literal side. Here we return the
-- vararg's declared type and let callers decide how to consume it.

--: (node: { tag: integer, line: integer | nil, col: integer | nil }, env: { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer }, aliases: { [string]: V4Type }, io_caps: { read_file: (path: string) -> (string | nil, string | nil), write_file: (path: string, bytes: string) -> (boolean, string | nil), mkdir: (path: string) -> (boolean, string | nil), file_exists: (path: string) -> boolean } | nil, cache_dir: string | nil, require_chain: { [string]: V4Type | boolean }, prim_index: { [string]: V4Type } }, solver: V4Solver) -> (V4Type | nil, { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer }, aliases: { [string]: V4Type }, io_caps: { read_file: (path: string) -> (string | nil, string | nil), write_file: (path: string, bytes: string) -> (boolean, string | nil), mkdir: (path: string) -> (boolean, string | nil), file_exists: (path: string) -> boolean } | nil, cache_dir: string | nil, require_chain: { [string]: V4Type | boolean }, prim_index: { [string]: V4Type } }, string | nil)
local function synth_vararg(_node, env, _solver)
	local vararg = env.vararg
	if vararg == nil then
		return nil, env, D.emit(env, D.E_VARARG_OUT_OF_SCOPE,
			"varargs not in scope")
	end
	return vararg, env, nil
end

-- Register all sub-phase B handlers into a walker module `W`. Called by
-- walker.lua at load time and by tests that want to restore the built-in
-- handler set after `W._reset_handlers()`.
--: (W: { register_synth: (tag: integer, handler: (node: { tag: integer, line: integer | nil, col: integer | nil, ... }, env: { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer }, aliases: { [string]: V4Type }, io_caps: { read_file: (path: string) -> (string | nil, string | nil), write_file: (path: string, bytes: string) -> (boolean, string | nil), mkdir: (path: string) -> (boolean, string | nil), file_exists: (path: string) -> boolean } | nil, cache_dir: string | nil, require_chain: { [string]: V4Type | boolean }, prim_index: { [string]: V4Type } }, solver: V4Solver) -> (V4Type | nil, { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer }, aliases: { [string]: V4Type }, io_caps: { read_file: (path: string) -> (string | nil, string | nil), write_file: (path: string, bytes: string) -> (boolean, string | nil), mkdir: (path: string) -> (boolean, string | nil), file_exists: (path: string) -> boolean } | nil, cache_dir: string | nil, require_chain: { [string]: V4Type | boolean }, prim_index: { [string]: V4Type } }, string | nil)) -> nil, ... }) -> nil
function M.register(W)
	W.register_synth(defs.NODE_LITERAL,     synth_literal)
	W.register_synth(defs.NODE_IDENTIFIER,  synth_identifier)
	W.register_synth(defs.NODE_VARARG_EXPR, synth_vararg)
end

return M
