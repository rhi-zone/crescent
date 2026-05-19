-- E — walker environment record.
--
-- Sub-phase A of the AST walker (see docs/typechecker-ast-walker-design.md §4).
-- This module supplies the functional environment threaded through every
-- walker visit. Per-node constraint generation lives in later sub-phases; A
-- contributes only the data structure and its primitive operations.
--
-- Shape and rationale
-- ───────────────────
-- An environment frame is a flat record. Functional-with-overlays semantics
-- is realized by shallow-copy-on-update: every mutating operation
-- (`E.bind`, `E.narrow`, ...) returns a NEW table with the relevant field
-- replaced, leaving the caller's reference untouched. This is the simpler of
-- the two designs the doc admits (the other being parent-chain delegation)
-- and is preferred here because:
--
--   1. Lookups are O(1) on a flat map; a parent chain makes them O(depth).
--   2. The JIT sees one hidden class per env shape — all fields present at
--      construction (CLAUDE.md "Table construction").
--   3. Branch-join (the §5.2 union of narrowed views from two branches) is
--      simpler when each frame fully owns its bindings rather than relying
--      on which level of a chain a name happens to live at.
--
-- The cost is per-edit allocation; in practice scope edits are rare relative
-- to lookups, and the bindings map itself is shared (we copy the env record
-- but not the bindings table) when no binding changes.
--
-- The `narrowed` overlay is consulted before `bindings` on lookup. On a
-- function boundary the overlay is cleared (narrowings do not survive into
-- a nested function body).
--
-- The env shape (a "WalkerEnv") is:
--
--   {
--     bindings:  { [string]: V4Type },         -- in-scope names → types
--     narrowed:  { [string]: V4Type },         -- path-sensitive overlay
--     return_ty: V4Type | nil,                 -- enclosing fn return slot
--     vararg:    V4Type | nil,                 -- enclosing fn vararg type
--     effects:   { [string]: boolean },        -- effects accumulated in body
--     module:    V4Type | nil,                 -- module-pattern accumulator
--     expected:  V4Type | nil,                 -- CHECK target (else nil)
--     source:    { file: string, line: integer, col: integer },
--   }
--
-- The shape is inlined at each function signature rather than abstracted
-- as a top-level `--::` alias because the crescent typechecker does NOT
-- resolve cross-module aliases (`V4Type`) inside top-level `--::` alias
-- bodies — only `--:` function annotations and `--[[: T]]` casts honor the
-- require graph. Repeating the shape 13× is uglier than one alias would
-- be, but no `unknown` widening is needed to make it work. See the
-- walker/README.md for the design choice.

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

-- Bring V4Type into alias scope (visible to function annotations below).
local _types = require("lib.type.static-v4.types")
local _ = _types

local M = {}

local EMPTY_SOURCE = { file = "?", line = 0, col = 0 }

-- Shallow-copy primitive (one helper, not duplicated per field).
--: (e: { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }) -> { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }
local function clone(e)
	return {
		bindings  = e.bindings,
		narrowed  = e.narrowed,
		return_ty = e.return_ty,
		vararg    = e.vararg,
		effects   = e.effects,
		module    = e.module,
		expected  = e.expected,
		source    = e.source,
	}
end

--: () -> { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }
function M.new()
	return {
		bindings  = {},
		narrowed  = {},
		return_ty = nil,
		vararg    = nil,
		effects   = {},
		module    = nil,
		expected  = nil,
		source    = EMPTY_SOURCE,
	}
end

-- Bind a name to a type. Returns a new env; the original is untouched.
-- A fresh `bindings` table is allocated on edit (shared otherwise).
--: (env: { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }, name: string, ty: V4Type) -> { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }
function M.bind(env, name, ty)
	local new_bindings = {}
	for k, v in pairs(env.bindings) do new_bindings[k] = v end
	new_bindings[name] = ty
	local e = clone(env)
	e.bindings = new_bindings
	-- A re-binding clears any prior narrowing of the same name: narrowing is
	-- relative to a binding, and the binding just changed.
	if env.narrowed[name] ~= nil then
		local new_narrowed = {}
		for k, v in pairs(env.narrowed) do
			if k ~= name then new_narrowed[k] = v end
		end
		e.narrowed = new_narrowed
	end
	return e
end

-- Resolve a name. Narrowing overlay takes precedence over the underlying
-- binding. Returns nil if the name is unbound.
--: (env: { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }, name: string) -> V4Type | nil
function M.lookup(env, name)
	local n = env.narrowed[name]
	if n ~= nil then return n end
	return env.bindings[name]
end

-- Whether a name has an underlying binding (ignoring narrowing).
--: (env: { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }, name: string) -> boolean
function M.has(env, name)
	return env.bindings[name] ~= nil
end

-- Add a narrowing overlay for `name`. The underlying binding is unchanged;
-- only the narrowed view is updated. Returns a new env.
--: (env: { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }, name: string, ty: V4Type) -> { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }
function M.narrow(env, name, ty)
	local new_narrowed = {}
	for k, v in pairs(env.narrowed) do new_narrowed[k] = v end
	new_narrowed[name] = ty
	local e = clone(env)
	e.narrowed = new_narrowed
	return e
end

-- Drop any narrowing on `name`, reverting lookup to the underlying binding.
--: (env: { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }, name: string) -> { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }
function M.unnarrow(env, name)
	if env.narrowed[name] == nil then return env end
	local new_narrowed = {}
	for k, v in pairs(env.narrowed) do
		if k ~= name then new_narrowed[k] = v end
	end
	local e = clone(env)
	e.narrowed = new_narrowed
	return e
end

-- Drop all narrowing overlays. Used on function-boundary frames: a narrowing
-- in the enclosing scope does not survive into a nested function body.
--: (env: { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }) -> { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }
function M.clear_narrowed(env)
	if next(env.narrowed) == nil then return env end
	local e = clone(env)
	e.narrowed = {}
	return e
end

-- Set the CHECK target. Returns a new env; the original is untouched. Passing
-- `nil` clears the expectation (the caller is returning to SYNTHESIZE mode).
--: (env: { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }, ty: V4Type | nil) -> { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }
function M.with_expected(env, ty)
	local e = clone(env)
	e.expected = ty
	return e
end

-- Update the current source position. Used by the walker to thread parser
-- positions through to diagnostics. The position is the active AST node's
-- (line, col); `file` is the chunk-level file path.
--: (env: { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }, line: integer, col: integer) -> { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }
function M.with_position(env, line, col)
	local e = clone(env)
	e.source = { file = env.source.file, line = line, col = col }
	return e
end

-- Replace the entire source position (used on chunk entry).
--: (env: { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }, src: { file: string, line: integer, col: integer }) -> { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }
function M.with_source(env, src)
	local e = clone(env)
	e.source = src
	return e
end

-- Function-boundary primitive. Replaces return_ty / vararg / effects / module
-- with a fresh frame (per §4 "function entry pushes a fresh
-- return_ty/vararg/effects/module"). Narrowing is also cleared (it does not
-- cross function boundaries). Bindings are inherited (closures see the outer
-- scope). Caller is responsible for binding parameter names afterward via
-- `E.bind`.
--: (env: { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }, return_ty: V4Type | nil, vararg: V4Type | nil) -> { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }
function M.enter_function(env, return_ty, vararg)
	local e = clone(env)
	e.narrowed  = {}
	e.return_ty = return_ty
	e.vararg    = vararg
	e.effects   = {}
	e.module    = nil
	e.expected  = nil
	return e
end

-- Record an effect on the current function-body's effect set.
--: (env: { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }, eff: string) -> { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }
function M.add_effect(env, eff)
	if env.effects[eff] then return env end
	local new_effects = {}
	for k, v in pairs(env.effects) do new_effects[k] = v end
	new_effects[eff] = true
	local e = clone(env)
	e.effects = new_effects
	return e
end

-- Install (or replace) the module-pattern accumulator. The slot is plumbed
-- here for downstream phases; sub-phase A does not interpret it.
--: (env: { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }, ty: V4Type | nil) -> { bindings: { [string]: V4Type }, narrowed: { [string]: V4Type }, return_ty: V4Type | nil, vararg: V4Type | nil, effects: { [string]: boolean }, module: V4Type | nil, expected: V4Type | nil, source: { file: string, line: integer, col: integer } }
function M.with_module(env, ty)
	local e = clone(env)
	e.module = ty
	return e
end

return M
