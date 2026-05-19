-- Walker sub-phase J — origin map for V4Type values.
--
-- v4 itself does NOT store source positions or producing-site references on
-- type values (type-system.md Principle 13: "source locations do not belong
-- in the type system"). The walker maintains origins in a parallel map
-- keyed by V4Type identity.
--
-- Origin record shape:
--
--   {
--     kind:    string,   -- one of diag.O_FROM_REQUIRE / O_FROM_CAST / ...
--     pos:     { file, line, col, end_line?, end_col? } | nil,
--     module:  string | nil,         -- module name for from-require
--     msg:     string | nil,         -- short producer description
--     parent:  Origin | nil,         -- chain (origin of an origin)
--   }
--
-- Identity-keyed: two structurally-equal but distinct V4Type tables get
-- distinct entries. This matches v4's no-hash-consing discipline (subtype.lua
-- key_of uses table identity for the constraint cache).
--
-- Memory: this map is per-walk, not a process-wide singleton. Each walker
-- invocation creates a fresh map and threads it via the env (or, for the
-- single-walk case, a module-level table that the walker resets). For phase
-- J we use a module-level map plus an explicit `reset()` — the walker is
-- not yet re-entrant and tests can call `reset()` between runs.
--
-- The parallel-map approach is lower-risk than retrofitting origins onto
-- types.lua: it keeps v4 core untouched and centralises origin policy in
-- the walker (where the import-surface, cast, narrowing concepts exist).

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- The origin map. Keys are V4Type table identities; values are origin
-- records. Reset via `M.reset()` between walks.
local origins = {} --[[: { [unknown]: unknown } ]]

-- Record an origin for a V4Type. Returns the same V4Type for chaining at
-- callsites: `local ty = O.record(V.var(), { kind = O_FROM_REQUIRE, ... })`.
-- A duplicate record for the same V4Type overrides — the latest producer
-- wins, which matches the "narrowing replaces" semantics. (In practice
-- origin recording happens once per type at construction; this fall-through
-- is for the rare case of post-construction re-typing.)
function M.record(ty, origin)
	if type(ty) ~= "table" then return ty end
	origins[ty] = origin
	return ty
end

-- Look up an origin record by V4Type. Returns nil if no origin is recorded
-- (most types don't have one — only types produced at well-defined sites
-- like `require`, `--[[: T]]` casts, and `--: T` annotations).
function M.get(ty)
	if type(ty) ~= "table" then return nil end
	return origins[ty]
end

-- Build an origin record from an env's source position. Most call sites
-- pass `env` rather than constructing a position table by hand.
function M.from_env(env, kind, opts)
	opts = opts or {}
	local pos
	if env ~= nil and env.source ~= nil then
		pos = {
			file     = env.source.file,
			line     = env.source.line,
			col      = env.source.col,
			end_line = env.source.end_line,
			end_col  = env.source.end_col,
		}
	end
	return {
		kind   = kind,
		pos    = pos,
		module = opts.module,
		msg    = opts.msg,
		parent = opts.parent,
	}
end

-- Clear the origin map. Test-only and between-walks; production code with a
-- single walk per process does not need to call this. Tests call it to keep
-- assertions deterministic.
--: () -> nil
function M.reset()
	origins = {} --[[: { [unknown]: unknown } ]]
end

-- Test-only: number of recorded origins. Allows tests to assert the walker
-- isn't leaking origins on types that shouldn't have them.
--: () -> integer
function M._count()
	local n = 0
	for _ in pairs(origins) do n = n + 1 end
	return n
end

return M
