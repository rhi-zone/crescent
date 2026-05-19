-- Walker — AST → v4 type-system bridge.
--
-- Sub-phase A scaffolding (see docs/typechecker-ast-walker-design.md §13
-- "Phase A"). This module supplies:
--
--   - The two-mode dispatch shell (SYNTHESIZE and CHECK).
--   - A registry keyed by `node.tag` (the integer constants defined in
--     `lib/type/static/defs.lua`) — one handler slot per (tag, mode).
--   - A clean extension mechanism (`M.register_synth`, `M.register_check`)
--     so later sub-phases (B–J) plug in per-node handlers without editing
--     this file.
--
-- Sub-phase A does NOT register any real handlers. Every node tag dispatches
-- to a stub that returns a clean error indicating sub-phase A's limit. The
-- dispatch shell itself is the load-bearing piece.
--
-- Mode dispatch
-- ─────────────
-- SYNTHESIZE — returns `(V4Type | nil, E, errmsg | nil)`. The type is the
-- node's inferred type (or nil for statements). The env is the post-walk
-- env (statements modify scope). Errmsg is a clean error string on failure.
--
-- CHECK — like SYNTHESIZE, but the caller provides an expected type. The
-- default rule (sub-phase A) is: synthesize, then constrain via the solver.
-- Direct CHECK rules will be registered by later sub-phases where
-- bidirectional checking yields meaningfully better types (table literals,
-- function literals, generic calls — see §2.1).
--
-- The walker accepts a `solver` argument on every entry point so handlers
-- can emit `V.constrain(solver, A, B)`. Sub-phase A does not actually emit
-- constraints (no per-node handlers yet), but the parameter is plumbed
-- through the shell so downstream phases plug in without churn.

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local V = require("lib.type.static-v4")
local E = require("lib.type.static-v4.walker.env")

local M = {}

-- Registry — populated by `M.register_synth` and `M.register_check`. A
-- missing entry indicates sub-phase A's stub limit, NOT an unknown tag;
-- truly unknown tags are caught separately.
--
-- Type aliases used below come in from the require graph:
--   - `V4Type` — `lib/type/static-v4/types.lua`.
--   - `V4Solver` — `lib/type/static-v4/subtype.lua`.
--   - `{ bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }` — `lib/type/static-v4/walker/env.lua` (env.lua owns the
--     definitive shape; the walker only consumes it).

--:: Node = { tag: integer, line: integer | nil, col: integer | nil, ... }
-- SynthHandler / CheckHandler signatures are inlined at each registration
-- callsite rather than aliased here, because top-level `--::` aliases that
-- reference cross-module aliases (V4Type, V4Solver, { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }) don't resolve
-- in the walker's annotation scope. The same shapes appear inline on
-- M.walk_synth / M.walk_check below.

local synth_handlers = {} --[[: { [integer]: (node: Node, env: { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }, solver: V4Solver) -> (V4Type | nil, { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }, string | nil) } ]]
local check_handlers = {} --[[: { [integer]: (node: Node, env: { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }, solver: V4Solver, expected: V4Type) -> ({ bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }, string | nil) } ]]

-- Tag-name table (for diagnostics). Populated from defs.lua at load time so
-- error messages can name the unsupported node rather than printing a bare
-- integer.
local defs = require("lib.type.static.defs")
local tag_names = {} --[[: { [integer]: string } ]]
for k, v in pairs(defs --[[: { [string]: integer } ]]) do
	if k:sub(1, 5) == "NODE_" then
		tag_names[v] = k
	end
end

--: (integer) -> string
local function tag_name(tag)
	return tag_names[tag] or ("tag#" .. tostring(tag))
end

-- Register a SYNTHESIZE handler for `tag`. Re-registering overrides. This is
-- the extension point for sub-phases B–J: each adds the handlers it owns.
--: (tag: integer, handler: (node: Node, env: { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }, solver: V4Solver) -> (V4Type | nil, { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }, string | nil)) -> nil
function M.register_synth(tag, handler)
	synth_handlers[tag] = handler
end

--: (tag: integer, handler: (node: Node, env: { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }, solver: V4Solver, expected: V4Type) -> ({ bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }, string | nil)) -> nil
function M.register_check(tag, handler)
	check_handlers[tag] = handler
end

-- Whether a handler is currently registered. Used by tests to verify that A
-- registers nothing.
--: (integer) -> boolean
function M.has_synth(tag) return synth_handlers[tag] ~= nil end
--: (integer) -> boolean
function M.has_check(tag) return check_handlers[tag] ~= nil end

-- Clear all registered handlers. Test-only; production callers should
-- register-then-walk in a single setup. Sub-phase B (and beyond) install
-- their built-in handlers at module load; after `_reset_handlers` a test
-- that wants the built-ins back must call `_register_builtins`.
--: () -> nil
function M._reset_handlers()
	synth_handlers = {} --[[: { [integer]: (node: Node, env: { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }, solver: V4Solver) -> (V4Type | nil, { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }, string | nil) } ]]
	check_handlers = {} --[[: { [integer]: (node: Node, env: { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }, solver: V4Solver, expected: V4Type) -> ({ bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }, string | nil) } ]]
end

-- Update the env's source position from a node if it carries one. Many
-- nodes do; the walker tolerates missing line/col fields (sub-phase A
-- doesn't enforce them).
--: (node: Node, env: { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }) -> { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }
local function position(node, env)
	local line, col = node.line, node.col
	if line ~= nil and col ~= nil then
		return E.with_position(env, line, col)
	end
	return env
end

-- ── SYNTHESIZE ────────────────────────────────────────────────────────────

--: (node: Node, env: { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }, solver: V4Solver) -> (V4Type | nil, { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }, string | nil)
function M.walk_synth(node, env, solver)
	env = position(node, env)
	local tag = node.tag
	local h = synth_handlers[tag]
	if h == nil then
		return nil, env,
			"walker: " .. tag_name(tag) .. " not yet implemented"
	end
	return h(node, env, solver)
end

-- ── CHECK ─────────────────────────────────────────────────────────────────
--
-- Default rule (§2.1 "if in doubt, synthesize and subtype"): synthesize the
-- node's type, then constrain it against `expected`. Direct CHECK rules
-- (registered via `register_check`) override this for nodes where
-- bidirectional checking pays off (table literals, function literals,
-- generic calls — sub-phases D and G).
--
-- The default is wired in sub-phase B now that synth handlers produce
-- real types. On constrain failure, `solver.error` carries the diagnostic
-- and we surface it as the err return.

local subtype_mod = require("lib.type.static-v4.subtype")

--: (node: Node, env: { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }, solver: V4Solver, expected: V4Type) -> ({ bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }, string | nil)
function M.walk_check(node, env, solver, expected)
	env = position(node, env)
	local tag = node.tag
	local h = check_handlers[tag]
	if h ~= nil then
		return h(node, env, solver, expected)
	end
	-- Default: synthesize, then constrain.
	local env2 = E.with_expected(env, expected)
	local ty, env3, err = M.walk_synth(node, env2, solver)
	if err ~= nil then return env3, err end
	if ty == nil then
		-- Statement nodes synthesize to nil. CHECK against a non-statement
		-- node is the caller's contract; receiving nil here means the caller
		-- asked CHECK on a statement, which is a bug.
		return env3, "walker: CHECK invoked on a statement node (" ..
			tag_name(tag) .. ")"
	end
	subtype_mod.constrain(solver, ty, expected)
	if solver.error ~= nil then
		return env3, solver.error
	end
	return env3, nil
end

-- Convenience: unified entry. If `env.expected` is set, walks in CHECK mode
-- against that expected type; otherwise SYNTHESIZE. Returns the same shape
-- as walk_synth for uniformity; in CHECK mode the type slot is `expected`.
--: (node: Node, env: { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }, solver: V4Solver) -> (V4Type | nil, { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }, string | nil)
function M.walk(node, env, solver)
	local expected = env.expected
	if expected ~= nil then
		local env_no_expect = E.with_expected(env, nil)
		local env2, err = M.walk_check(node, env_no_expect, solver, expected)
		if err ~= nil then return nil, env2, err end
		return expected, env2, nil
	end
	return M.walk_synth(node, env, solver)
end

-- ── Built-in handler registration ─────────────────────────────────────────
--
-- Each sub-phase contributes a module that exports `register(W)`. The walker
-- composes them at load time. After `M._reset_handlers()` a test can call
-- `M._register_builtins()` to restore the standard set.

local literals  = require("lib.type.static-v4.walker.literals")
local functions = require("lib.type.static-v4.walker.functions")

--: () -> nil
function M._register_builtins()
	literals.register(M)
	functions.register(M)
end

M._register_builtins()

return M
