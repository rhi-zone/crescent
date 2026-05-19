-- Walker sub-phase J — structured diagnostics.
--
-- Per docs/typechecker-ast-walker-design.md §12 and the "Root-cause error
-- grouping" audit (in the same doc). Every walker-emitted diagnostic is a
-- structured record, NOT a bare string:
--
--   {
--     code:        string,                    -- one of D.CODES
--     pos:         { file, line, col, end_line?, end_col? },
--     msg:         string,                    -- rendered human message
--     origin:      Diagnostic | V4Type | nil, -- producing site, if unknown
--     origin_kind: string | nil,              -- "from-require", ...
--     module:      string | nil,              -- module name (E_REQUIRE_UNRESOLVED)
--     severity:    string,                    -- "error" | "warning"
--   }
--
-- The audit's mandate: the `--summary` grouping must be a data-level
-- group_by over `code` / `origin_kind` / `origin`, not a regex over
-- rendered text. This module provides the data shape; the rendering layer
-- consumes `tostring(d)` for the textual format (a `__tostring` metamethod
-- preserves the existing concatenation patterns at error-propagation sites).
--
-- Origins on V4Type values live in `walker.origin` (a parallel map keyed by
-- V4Type identity), not on the type values themselves — type-system.md
-- Principle 13 forbids storing positions in the type system. `D.emit` accepts
-- an optional `origin_type` opt whose V4Type identity is looked up against
-- the origin map; when an origin record is found, it populates the
-- diagnostic's `origin` / `origin_kind` / `module` fields.

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local O = require("lib.type.static-v4.walker.origin")

local M = {}

-- ── Diagnostic codes ──────────────────────────────────────────────────────
--
-- Each code is a stable machine identifier for an error class. The taxonomy
-- is data (per the audit) — bucket-mapping for `--summary` is a direct
-- lookup, not a substring match over `msg`. A new error site picks the code
-- from this set or adds one here.

M.E_UNDEFINED_NAME       = "undefined-name"
M.E_TYPE_MISMATCH        = "type-mismatch"
M.E_FIELD_MISSING        = "field-missing"
M.E_CALL_ARITY           = "call-arity"
M.E_CALL_NON_FN          = "call-non-function"
M.E_OP_TYPE              = "operator-type"
M.E_ARG_MISSING          = "arg-missing"
M.E_REQUIRE_UNRESOLVED   = "require-unresolved"
M.E_REQUIRE_IO           = "require-io"
M.E_VARARG_OUT_OF_SCOPE  = "vararg-out-of-scope"
M.E_RETURN_OUTSIDE_FN    = "return-outside-fn"
M.E_EFFECT_UNDECLARED    = "effect-undeclared"
M.E_FFI_CDEF             = "ffi-cdef"
M.E_NOT_NARROWED         = "not-narrowed"
M.E_UNSUPPORTED_NODE     = "unsupported-node"
M.E_INTERNAL             = "internal"
M.E_MATCH                = "match"
M.E_CAST                 = "cast"

-- Set membership for code validity checks. Test affordance — emitting an
-- unrecognised code is a bug, not a runtime fallback.
M.CODES = {
	[M.E_UNDEFINED_NAME]      = true,
	[M.E_TYPE_MISMATCH]       = true,
	[M.E_FIELD_MISSING]       = true,
	[M.E_CALL_ARITY]          = true,
	[M.E_CALL_NON_FN]         = true,
	[M.E_OP_TYPE]             = true,
	[M.E_ARG_MISSING]         = true,
	[M.E_REQUIRE_UNRESOLVED]  = true,
	[M.E_REQUIRE_IO]          = true,
	[M.E_VARARG_OUT_OF_SCOPE] = true,
	[M.E_RETURN_OUTSIDE_FN]   = true,
	[M.E_EFFECT_UNDECLARED]   = true,
	[M.E_FFI_CDEF]            = true,
	[M.E_NOT_NARROWED]        = true,
	[M.E_UNSUPPORTED_NODE]    = true,
	[M.E_INTERNAL]            = true,
	[M.E_MATCH]               = true,
	[M.E_CAST]                = true,
}

-- ── Origin kinds ──────────────────────────────────────────────────────────
--
-- The discriminant `origin_kind` enables the `--summary` group_by. The set
-- is closed; adding a new kind is a deliberate design move.

M.O_FROM_REQUIRE     = "from-require"
M.O_FROM_CAST        = "from-cast"
M.O_FROM_ANNOTATION  = "from-annotation"
M.O_FROM_NARROW      = "from-narrow"
M.O_PROPAGATED       = "propagated"

-- ── Diagnostic metatable ──────────────────────────────────────────────────

local DiagMt = {}
DiagMt.__index = DiagMt

-- Render a diagnostic to the textual format. The format mirrors the
-- legacy CLI: `file:line:col: severity: msg`. Origin chains are NOT folded
-- into the rendered text by default — the printer chooses how to present
-- chains (e.g. `--summary` groups by `origin`; default printer just shows
-- the leaf).
function DiagMt.__tostring(d)
	local pos = d.pos
	local file = pos and pos.file or "?"
	local line = pos and pos.line or 0
	local col  = pos and pos.col or 0
	return file .. ":" .. tostring(line) .. ":" .. tostring(col)
		.. ": " .. d.severity .. ": " .. d.msg
end

-- Concatenation: unknown walker site that does `"prefix: " .. err` continues to
-- work because tostring(diag) returns the rendered form. Lua's concat
-- operator calls __concat when either operand is a non-string with the
-- metamethod, but for string-on-the-left we need __tostring fallback. Lua
-- 5.1 does NOT auto-tostring on concat — we explicitly install __concat.
function DiagMt.__concat(a, b)
	local sa = type(a) == "string" and a or tostring(a)
	local sb = type(b) == "string" and b or tostring(b)
	return sa .. sb
end

-- ── Predicates ────────────────────────────────────────────────────────────

function M.is_diagnostic(d)
	if type(d) ~= "table" then return false end
	return getmetatable(d) == DiagMt
end

-- ── Position helpers ──────────────────────────────────────────────────────
--
-- The walker threads `env.source` ({file, line, col}) through every visit
-- via env.lua. A diagnostic's `pos` is derived from env.source unless
-- explicitly overridden via opts.pos (a node-specific position is preferred
-- when the diagnostic blames a sub-expression of the current node).

local function position_from(env, opts)
	if opts ~= nil and opts.pos ~= nil then return opts.pos end
	local s = env and env.source
	if s == nil then return { file = "?", line = 0, col = 0 } end
	return {
		file     = s.file,
		line     = s.line,
		col      = s.col,
		end_line = s.end_line,
		end_col  = s.end_col,
	}
end

M.position_from = position_from

-- ── Diagnostic builder ────────────────────────────────────────────────────
--
-- `D.emit(env, code, msg, opts?)`. Returns a Diagnostic table. Opts:
--   - `pos`         — override env.source position.
--   - `origin`      — explicit origin (another Diagnostic OR an origin record).
--   - `origin_type` — a V4Type whose origin map entry (if unknown) becomes
--                     the diagnostic's origin. Used for subtype failures:
--                     pass the LHS/RHS V4Type and the origin map populates
--                     the chain automatically.
--   - `origin_kind` — explicit override.
--   - `module`      — module name (E_REQUIRE_UNRESOLVED).
--   - `severity`    — defaults to "error".
--
-- An unrecognised `code` is rejected immediately — a typo in a walker
-- handler that mints a new code is a bug, not a runtime fallback (the
-- audit's "taxonomy as data" only works if the set is closed).

function M.emit(env, code, msg, opts)
	if M.CODES[code] == nil then
		error("diag.emit: unrecognised code '" .. tostring(code) ..
			"' — add it to diag.lua's CODES set if intentional")
	end
	opts = opts or {}
	local d = {
		code        = code,
		pos         = position_from(env, opts),
		msg         = msg,
		origin      = opts.origin,
		origin_kind = opts.origin_kind,
		module      = opts.module,
		severity    = opts.severity or "error",
	}
	-- Resolve origin from a V4Type's origin map entry when no explicit
	-- origin was supplied. This is the load-bearing piece: subtype failures
	-- automatically carry origin metadata from the participating types.
	if d.origin == nil and opts.origin_type ~= nil then
		local rec = O.get(opts.origin_type)
		if rec ~= nil then
			d.origin = rec
			if d.origin_kind == nil then d.origin_kind = rec.kind end
			if d.module == nil and rec.module ~= nil then d.module = rec.module end
		end
	end
	return setmetatable(d, DiagMt)
end

-- Wrap an inner Diagnostic (or string) with an outer one — used at error-
-- propagation sites where a handler adds context to a downstream error.
-- The inner becomes the outer's origin with `origin_kind = O_PROPAGATED`.
function M.chain(env, code, msg, inner)
	local opts = {
		origin      = inner,
		origin_kind = M.O_PROPAGATED,
	}
	-- If the inner is already a Diagnostic, inherit its module field (the
	-- root require name) so a downstream consumer doesn't have to walk
	-- the chain to recover it.
	if M.is_diagnostic(inner) and inner.module ~= nil then
		opts.module = inner.module
	end
	return M.emit(env, code, msg, opts)
end

-- Lift a raw error value into a Diagnostic when needed. Existing handlers
-- that return arbitrary strings (e.g. from solver.error) can pass through
-- this lifter to normalise the return shape. Already-diagnostic values are
-- returned untouched.
function M.lift(env, code, err)
	if M.is_diagnostic(err) then return err end
	return M.emit(env, code, tostring(err))
end

-- ── Subtype-failure helper ────────────────────────────────────────────────
--
-- The common pattern at solver-driven constraint sites:
--   subtype_mod.constrain(solver, A, B)
--   if solver.error ~= nil then ... emit diagnostic ... end
--
-- This helper consolidates the pattern: it consumes `solver.error`,
-- resets it, and emits a Diagnostic that names BOTH origin types (LHS and
-- RHS) — the LHS origin populates the primary origin field (the producing
-- site is what root-cause grouping wants); the RHS origin lands in
-- `origin_rhs` for future renderers that show both ends of the chain.

function M.from_solver(env, code, msg, solver, lhs, rhs)
	local raw = solver.error
	solver.error = nil
	local full = msg
	if raw ~= nil then full = msg .. ": " .. tostring(raw) end
	local opts = { origin_type = lhs }
	local d = M.emit(env, code, full, opts)
	-- Annotate the RHS origin alongside the primary. Renderers can elect
	-- to surface both ends of the chain; the default renderer prints only
	-- the leaf message.
	if rhs ~= nil then
		local rec = O.get(rhs)
		if rec ~= nil then d.origin_rhs = rec end
	end
	return d
end

return M
