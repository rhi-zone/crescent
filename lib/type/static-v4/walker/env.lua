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
-- The shape is captured as a `--:: WalkerEnv` alias and reused across
-- function signatures. (Cross-module `--::` alias resolution now works:
-- top-level `require()` calls populate the alias scope before this file's
-- `--::` bodies are resolved.)

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

-- Bring V4Type into alias scope (visible to the WalkerEnv alias below).
local _types = require("lib.type.static-v4.types")
local _ = _types

--:: WalkerEnv = {
--::   bindings:  { [string]: V4Type },
--::   narrowed:  { [string]: V4Type },
--::   return_ty: V4Type | nil,
--::   vararg:    V4Type | nil,
--::   effects:   { [string]: boolean },
--::   module:    V4Type | nil,
--::   expected:  V4Type | nil,
--::   source:    { file: string, line: integer, col: integer },
--:: }
--
-- Sub-phase I added four runtime slots that are intentionally NOT in the
-- alias body above. Each `V4Type` reference in the body triggers the
-- cross-module alias-resolution limitation (the README notes this is a
-- pre-existing issue with WalkerEnv's V4Type refs), so we keep the
-- alias body at the size that works for the current import topology and
-- treat the new fields as runtime-only extensions documented here:
--
--   `aliases:   { [string]: V4Type }` — file-scope type-alias scope.
--     `--::` declarations populate this in their own file; when
--     `require("foo")` succeeds, foo's exported aliases are merged in.
--   `io_caps:   V4IoCaps | nil` — capability injection for file I/O
--     (required for `require`). Per CLAUDE.md "Caps-first, everywhere":
--     absent caps + an attempted `require` errors loudly; no fallback to
--     globals.
--   `cache_dir: string | nil` — base directory for the .cri cache.
--     Required alongside io_caps for `require` resolution.
--   `require_chain: { [string]: V4Type | boolean }` — cycle-detection
--     map. While `require("A")` is being resolved, an entry maps "A" → a
--     placeholder V4Type (or `true` if no placeholder is needed yet). A
--     recursive `require("A")` returns the placeholder, breaking the
--     cycle per Lua's runtime semantics.
--   `prim_index: { [string]: V4Type }` — per-primitive-tag method-dispatch
--     registry. Keyed by primitive base tag (`"string"`, ...), maps to the
--     V4Type used as that primitive's `__index` table for method lookups.
--     Populated by `inject_stdlib` from `stdlib.prim_index`. Lookups go
--     through this map, NOT through `env.bindings[<name>]` — user
--     shadowing the `string` global must not break `("x"):upper()`.
--
-- Helpers (`bind_alias`, `with_io_caps`, `with_cache_dir`, `push_require`,
-- `lookup_require`, etc.) annotate these fields inline at each function
-- signature, mirroring the existing inlined-shape convention for the rest
-- of the env. `clone()` carries them through.

local M = {}

local EMPTY_SOURCE = { file = "?", line = 0, col = 0 }

-- Shallow-copy primitive (one helper, not duplicated per field).
--: (e: WalkerEnv) -> WalkerEnv
local function clone(e)
	return {
		bindings      = e.bindings,
		narrowed      = e.narrowed,
		return_ty     = e.return_ty,
		vararg        = e.vararg,
		effects       = e.effects,
		module        = e.module,
		expected      = e.expected,
		source        = e.source,
		aliases       = e.aliases,
		io_caps       = e.io_caps,
		cache_dir     = e.cache_dir,
		require_chain = e.require_chain,
		prim_index    = e.prim_index,
	}
end

--: () -> WalkerEnv
function M.new()
	return {
		bindings      = {} --[[: { [string]: V4Type } ]],
		narrowed      = {} --[[: { [string]: V4Type } ]],
		return_ty     = nil,
		vararg        = nil,
		effects       = {} --[[: { [string]: boolean } ]],
		module        = nil,
		expected      = nil,
		source        = EMPTY_SOURCE,
		aliases       = {} --[[: { [string]: V4Type } ]],
		io_caps       = nil,
		cache_dir     = nil,
		require_chain = {} --[[: { [string]: V4Type | boolean } ]],
		prim_index    = {} --[[: { [string]: V4Type } ]],
	}
end

-- Bind a name to a type. Returns a new env; the original is untouched.
-- A fresh `bindings` table is allocated on edit (shared otherwise).
--: (env: WalkerEnv, name: string, ty: V4Type) -> WalkerEnv
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
--: (env: WalkerEnv, name: string) -> V4Type | nil
function M.lookup(env, name)
	local n = env.narrowed[name]
	if n ~= nil then return n end
	return env.bindings[name]
end

-- Whether a name has an underlying binding (ignoring narrowing).
--: (env: WalkerEnv, name: string) -> boolean
function M.has(env, name)
	return env.bindings[name] ~= nil
end

-- Add a narrowing overlay for `name`. The underlying binding is unchanged;
-- only the narrowed view is updated. Returns a new env.
--: (env: WalkerEnv, name: string, ty: V4Type) -> WalkerEnv
function M.narrow(env, name, ty)
	local new_narrowed = {}
	for k, v in pairs(env.narrowed) do new_narrowed[k] = v end
	new_narrowed[name] = ty
	local e = clone(env)
	e.narrowed = new_narrowed
	return e
end

-- Drop any narrowing on `name`, reverting lookup to the underlying binding.
--: (env: WalkerEnv, name: string) -> WalkerEnv
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
--: (env: WalkerEnv) -> WalkerEnv
function M.clear_narrowed(env)
	if next(env.narrowed) == nil then return env end
	local e = clone(env)
	e.narrowed = {}
	return e
end

-- Set the CHECK target. Returns a new env; the original is untouched. Passing
-- `nil` clears the expectation (the caller is returning to SYNTHESIZE mode).
--: (env: WalkerEnv, ty: V4Type | nil) -> WalkerEnv
function M.with_expected(env, ty)
	local e = clone(env)
	e.expected = ty
	return e
end

-- Update the current source position. Used by the walker to thread parser
-- positions through to diagnostics. The position is the active AST node's
-- (line, col); `file` is the chunk-level file path.
--: (env: WalkerEnv, line: integer, col: integer) -> WalkerEnv
function M.with_position(env, line, col)
	local e = clone(env)
	e.source = { file = env.source.file, line = line, col = col }
	return e
end

-- Replace the entire source position (used on chunk entry).
--: (env: WalkerEnv, src: { file: string, line: integer, col: integer }) -> WalkerEnv
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
--: (env: WalkerEnv, return_ty: V4Type | nil, vararg: V4Type | nil) -> WalkerEnv
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
--: (env: WalkerEnv, eff: string) -> WalkerEnv
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
--: (env: WalkerEnv, ty: V4Type | nil) -> WalkerEnv
function M.with_module(env, ty)
	local e = clone(env)
	e.module = ty
	return e
end

-- ── Sub-phase I helpers: aliases, I/O caps, cache dir, require chain ─────

-- Bind a file-scope type alias (the `--::` form). Returns a new env; the
-- original is untouched. Used by both in-file `--::` declarations and by
-- the cross-file `require()` machinery (when foo's aliases are merged into
-- the requiring file's scope).
--: (env: WalkerEnv, name: string, ty: V4Type) -> WalkerEnv
function M.bind_alias(env, name, ty)
	local new_aliases = {}
	for k, v in pairs(env.aliases) do new_aliases[k] = v end
	new_aliases[name] = ty
	local e = clone(env)
	e.aliases = new_aliases
	return e
end

-- Resolve a type alias. Returns nil if the alias name is not in scope.
--: (env: WalkerEnv, name: string) -> V4Type | nil
function M.lookup_alias(env, name)
	return env.aliases[name]
end

-- Install the I/O capability table. Required for `require()` resolution.
-- Passing nil clears the caps (used by tests).
--: (env: WalkerEnv, caps: { read_file: (path: string) -> (string | nil, string | nil), write_file: (path: string, bytes: string) -> (boolean, string | nil), mkdir: (path: string) -> (boolean, string | nil), file_exists: (path: string) -> boolean } | nil) -> WalkerEnv
function M.with_io_caps(env, caps)
	local e = clone(env)
	e.io_caps = caps
	return e
end

-- Install the cache directory used by the `.cri` cache. Required alongside
-- io_caps for `require()` resolution.
--: (env: WalkerEnv, dir: string | nil) -> WalkerEnv
function M.with_cache_dir(env, dir)
	local e = clone(env)
	e.cache_dir = dir
	return e
end

-- Install the per-primitive method-dispatch registry. Keyed by primitive
-- base tag, maps to the V4Type used as that primitive's `__index` for
-- `recv:method(...)` lookups. The driver wires this from `stdlib.prim_index`
-- at env construction; tests may also set it directly for isolated cases.
--: (env: WalkerEnv, registry: { [string]: V4Type }) -> WalkerEnv
function M.with_prim_index(env, registry)
	local e = clone(env)
	e.prim_index = registry
	return e
end

-- Push a require-in-progress entry. Used for cycle detection: while
-- resolving `require("A")`, the entry `A → placeholder` is set; a recursive
-- `require("A")` inside A's body looks the entry up and returns the
-- placeholder rather than re-walking. Pass `true` for the value if no
-- placeholder type is known yet.
--: (env: WalkerEnv, mod_name: string, placeholder: V4Type | boolean) -> WalkerEnv
function M.push_require(env, mod_name, placeholder)
	local new_chain = {}
	for k, v in pairs(env.require_chain) do new_chain[k] = v end
	new_chain[mod_name] = placeholder
	local e = clone(env)
	e.require_chain = new_chain
	return e
end

-- Pop a require-in-progress entry. The chain is unwound as resolution
-- completes.
--: (env: WalkerEnv, mod_name: string) -> WalkerEnv
function M.pop_require(env, mod_name)
	if env.require_chain[mod_name] == nil then return env end
	local new_chain = {}
	for k, v in pairs(env.require_chain) do
		if k ~= mod_name then new_chain[k] = v end
	end
	local e = clone(env)
	e.require_chain = new_chain
	return e
end

-- Look up a require-in-progress entry. Returns the placeholder (V4Type or
-- the sentinel boolean `true`) when the module is currently being resolved,
-- nil otherwise.
--: (env: WalkerEnv, mod_name: string) -> V4Type | boolean | nil
function M.lookup_require(env, mod_name)
	return env.require_chain[mod_name]
end

return M
