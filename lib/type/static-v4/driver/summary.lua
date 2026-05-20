-- K4 — diagnostic rendering for the v4 driver.
--
-- The v4 walker emits structured diagnostics (see walker/diag.lua). This
-- module turns a collected list into one of two text outputs:
--
--   M.render_default(diagnostics)  ->  per-line  "file:line:col: severity: code: msg"
--   M.render_summary(diagnostics)  ->  root-cause-grouped summary
--   M.group(diagnostics)           ->  the data-level grouping primitive
--
-- Discipline
-- ──────────
-- Grouping is a data-level group_by over the structured fields the walker
-- already populates (`code`, `origin_kind`, `module`). It is NOT a regex /
-- substring match over rendered text — that was the legacy implementation's
-- failure mode (see docs/typechecker-ast-walker-design.md "Root-cause error
-- grouping" audit). The taxonomy lives here, in `CATEGORY_FOR_CODE` and
-- `CATEGORY_FOR_ORIGIN_KIND`; a new error code or origin kind is a one-line
-- addition to one of those tables.
--
-- Category vocabulary
-- ───────────────────
-- A fixed, closed set chosen to match the audit's recommendation: one
-- category per root-cause class the user actually wants to investigate. The
-- ordering of categories in the rendered summary is deterministic and
-- chosen so that root causes (unresolved requires, cascading errors) come
-- first.

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local D = require("lib.type.static-v4.walker.diag")

-- Local diagnostic shape — mirrors walker/diag.lua's record. The walker
-- module does not export an alias for this (intentionally — the metatable
-- carries identity), so the renderer declares its own structural alias
-- against which inputs are checked.
--:: Pos = { file: string, line: integer, col: integer, end_line: integer | nil, end_col: integer | nil }
--:: Diag = { code: string, pos: Pos | nil, msg: string, severity: string, origin_kind: string | nil, module: string | nil, ... }

local M = {}

-- ── Category vocabulary ─────────────────────────────────────────────────
--
-- Order is the rendering order in `render_summary`. Root causes (the
-- problems the user should investigate first) precede their downstream
-- effects. The headings are human-facing strings; the keys are stable
-- machine identifiers test code asserts against.

M.CAT_UNRESOLVED_REQUIRES   = "unresolved-requires"
M.CAT_FROM_REQUIRE_CASCADE  = "from-require-cascade"
M.CAT_FROM_CAST             = "from-cast"
M.CAT_FROM_ANNOTATION       = "from-annotation"
M.CAT_FROM_NARROW           = "from-narrow"
M.CAT_UNDEFINED_NAMES       = "undefined-names"
M.CAT_TYPE_MISMATCHES       = "type-mismatches"
M.CAT_MISSING_FIELDS        = "missing-fields"
M.CAT_CALL_ERRORS           = "call-errors"
M.CAT_OPERATOR_ERRORS       = "operator-errors"
M.CAT_NARROWING_ERRORS      = "narrowing-errors"
M.CAT_MATCH_ERRORS          = "match-errors"
M.CAT_CAST_ERRORS           = "cast-errors"
M.CAT_EFFECT_ERRORS         = "effect-errors"
M.CAT_SCOPE_ERRORS          = "scope-errors"
M.CAT_FFI_ERRORS            = "ffi-errors"
M.CAT_REQUIRE_IO            = "require-io-errors"
M.CAT_UNSUPPORTED_NODE      = "unsupported-node"
M.CAT_INTERNAL              = "internal-errors"

-- Deterministic render order. Root causes first.
M.CATEGORY_ORDER = {
	M.CAT_UNRESOLVED_REQUIRES,
	M.CAT_REQUIRE_IO,
	M.CAT_FROM_REQUIRE_CASCADE,
	M.CAT_FROM_CAST,
	M.CAT_FROM_ANNOTATION,
	M.CAT_FROM_NARROW,
	M.CAT_UNDEFINED_NAMES,
	M.CAT_TYPE_MISMATCHES,
	M.CAT_MISSING_FIELDS,
	M.CAT_CALL_ERRORS,
	M.CAT_OPERATOR_ERRORS,
	M.CAT_NARROWING_ERRORS,
	M.CAT_MATCH_ERRORS,
	M.CAT_CAST_ERRORS,
	M.CAT_EFFECT_ERRORS,
	M.CAT_SCOPE_ERRORS,
	M.CAT_FFI_ERRORS,
	M.CAT_UNSUPPORTED_NODE,
	M.CAT_INTERNAL,
}

-- Human-facing heading per category. Pluralised; renderer prepends count.
M.CATEGORY_HEADING = {
	[M.CAT_UNRESOLVED_REQUIRES]   = "unresolved requires",
	[M.CAT_REQUIRE_IO]            = "require I/O errors",
	[M.CAT_FROM_REQUIRE_CASCADE]  = "errors cascading from unresolved requires",
	[M.CAT_FROM_CAST]             = "errors cascading from casts",
	[M.CAT_FROM_ANNOTATION]       = "errors cascading from annotations",
	[M.CAT_FROM_NARROW]           = "errors cascading from narrowing sites",
	[M.CAT_UNDEFINED_NAMES]       = "undefined names",
	[M.CAT_TYPE_MISMATCHES]       = "type mismatches",
	[M.CAT_MISSING_FIELDS]        = "missing fields",
	[M.CAT_CALL_ERRORS]           = "call errors",
	[M.CAT_OPERATOR_ERRORS]       = "operator type errors",
	[M.CAT_NARROWING_ERRORS]      = "narrowing errors",
	[M.CAT_MATCH_ERRORS]          = "match errors",
	[M.CAT_CAST_ERRORS]           = "cast errors",
	[M.CAT_EFFECT_ERRORS]         = "undeclared effects",
	[M.CAT_SCOPE_ERRORS]          = "scope errors",
	[M.CAT_FFI_ERRORS]            = "FFI cdef errors",
	[M.CAT_UNSUPPORTED_NODE]      = "unsupported syntax",
	[M.CAT_INTERNAL]              = "internal errors",
}

-- Code → default category (when no overriding origin_kind applies).
M.CATEGORY_FOR_CODE = {
	[D.E_UNDEFINED_NAME]       = M.CAT_UNDEFINED_NAMES,
	[D.E_TYPE_MISMATCH]        = M.CAT_TYPE_MISMATCHES,
	[D.E_FIELD_MISSING]        = M.CAT_MISSING_FIELDS,
	[D.E_CALL_ARITY]           = M.CAT_CALL_ERRORS,
	[D.E_CALL_NON_FN]          = M.CAT_CALL_ERRORS,
	[D.E_ARG_MISSING]          = M.CAT_CALL_ERRORS,
	[D.E_OP_TYPE]              = M.CAT_OPERATOR_ERRORS,
	[D.E_REQUIRE_UNRESOLVED]   = M.CAT_UNRESOLVED_REQUIRES,
	[D.E_REQUIRE_IO]           = M.CAT_REQUIRE_IO,
	[D.E_VARARG_OUT_OF_SCOPE]  = M.CAT_SCOPE_ERRORS,
	[D.E_RETURN_OUTSIDE_FN]    = M.CAT_SCOPE_ERRORS,
	[D.E_EFFECT_UNDECLARED]    = M.CAT_EFFECT_ERRORS,
	[D.E_FFI_CDEF]             = M.CAT_FFI_ERRORS,
	[D.E_NOT_NARROWED]         = M.CAT_NARROWING_ERRORS,
	[D.E_UNSUPPORTED_NODE]     = M.CAT_UNSUPPORTED_NODE,
	[D.E_INTERNAL]             = M.CAT_INTERNAL,
	[D.E_MATCH]                = M.CAT_MATCH_ERRORS,
	[D.E_CAST]                 = M.CAT_CAST_ERRORS,
}

-- origin_kind → category override. A diagnostic whose origin traces to one
-- of these takes the override category, regardless of its own code.
-- Exception: a diagnostic that IS itself the root (code == E_REQUIRE_UNRESOLVED
-- with origin_kind == O_FROM_REQUIRE on its OWN module type) is a root
-- cause, not a cascade — categorise by code, not by origin_kind.
M.CATEGORY_FOR_ORIGIN_KIND = {
	[D.O_FROM_REQUIRE]    = M.CAT_FROM_REQUIRE_CASCADE,
	[D.O_FROM_CAST]       = M.CAT_FROM_CAST,
	[D.O_FROM_ANNOTATION] = M.CAT_FROM_ANNOTATION,
	[D.O_FROM_NARROW]     = M.CAT_FROM_NARROW,
	-- O_PROPAGATED is NOT an override: a propagated diagnostic categorises
	-- by its own code (the chain wrapper added context but the bucket is
	-- still about what failed).
}

-- ── Category resolution ─────────────────────────────────────────────────
--
-- Priority:
--   1. If the diagnostic IS itself a root-cause (E_REQUIRE_UNRESOLVED,
--      E_REQUIRE_IO), category is by code. Otherwise:
--   2. If `origin_kind` has a category override, use it.
--   3. Otherwise, category by `code`.
--   4. Fallback: CAT_INTERNAL (unmappable code → bug, but render gracefully).

local ROOT_CAUSE_CODES = {
	[D.E_REQUIRE_UNRESOLVED] = true,
	[D.E_REQUIRE_IO]         = true,
}

--: (Diag) -> string
local function category_of(d)
	if ROOT_CAUSE_CODES[d.code] then
		return M.CATEGORY_FOR_CODE[d.code] or M.CAT_INTERNAL
	end
	if d.origin_kind ~= nil then
		local override = M.CATEGORY_FOR_ORIGIN_KIND[d.origin_kind]
		if override ~= nil then return override end
	end
	return M.CATEGORY_FOR_CODE[d.code] or M.CAT_INTERNAL
end

M.category_of = category_of

-- ── Sort key ────────────────────────────────────────────────────────────
--
-- Stable (file, line, col) ordering. Missing pos fields sort low.

--: (Diag) -> (string, integer, integer)
local function pos_key(d)
	local pos = d.pos
	if pos == nil then return "", 0, 0 end
	return pos.file, pos.line, pos.col
end

--: (Diag, Diag) -> boolean
local function cmp_pos(a, b)
	local af, al, ac = pos_key(a)
	local bf, bl, bc = pos_key(b)
	if af ~= bf then return af < bf end
	if al ~= bl then return al < bl end
	return ac < bc
end

-- Hand-rolled insertion sort for string arrays. We avoid `table.sort` for
-- string arrays in this module because `table.sort` is generic and the
-- typechecker binds its `V` parameter at the first call site; mixing
-- string-array calls with Diag-array calls (cmp_pos) produces a re-binding
-- error. cache.lua documents the same limitation. Lists here are at most a
-- handful of codes, so insertion sort is sized appropriately.
--: ({ [integer]: string }) -> nil
local function sort_strings(xs)
	for i = 2, #xs do
		local v = xs[i]
		local j = i - 1
		while j >= 1 and xs[j] > v do
			xs[j + 1] = xs[j]
			j = j - 1
		end
		xs[j + 1] = v
	end
end

-- ── group(diagnostics) -> { [category] = { [code] = [diagnostic, ...] } }
--
-- The data-level group_by primitive. Tested in isolation.

--: ({ [integer]: Diag }) -> { [string]: { [string]: { [integer]: Diag } } }
function M.group(diagnostics)
	local out = {} --[[: { [string]: { [string]: { [integer]: Diag } } } ]]
	for _, d in ipairs(diagnostics) do
		local cat = category_of(d)
		local by_code = out[cat]
		if by_code == nil then
			by_code = {}
			out[cat] = by_code
		end
		local bucket = by_code[d.code]
		if bucket == nil then
			bucket = {} --[[: { [integer]: Diag } ]]
			by_code[d.code] = bucket
		end
		bucket[#bucket + 1] = d
	end
	-- Sort each bucket by (file, line, col) for deterministic output.
	for _, by_code in pairs(out) do
		for _, bucket in pairs(by_code) do
			table.sort(bucket, cmp_pos)
		end
	end
	return out
end

-- ── render_default(diagnostics) -> string ───────────────────────────────
--
-- Per-diagnostic line of  "file:line:col: severity: code: msg"  sorted by
-- (file, line, col). Empty stream renders to the empty string.

--: ({ [integer]: Diag }) -> string
function M.render_default(diagnostics)
	if #diagnostics == 0 then return "" end
	local sorted = {} --[[: { [integer]: Diag } ]]
	for i, d in ipairs(diagnostics) do sorted[i] = d end
	table.sort(sorted, cmp_pos)
	local parts = {} --[[: { [integer]: string } ]]
	for i, d in ipairs(sorted) do
		local pos = d.pos
		local file = pos ~= nil and pos.file or "?"
		local line = pos ~= nil and pos.line or 0
		local col  = pos ~= nil and pos.col or 0
		parts[i] = file .. ":" .. tostring(line) .. ":" .. tostring(col)
			.. ": " .. d.severity
			.. ": " .. d.code
			.. ": " .. d.msg
	end
	return table.concat(parts, "\n") .. "\n"
end

-- ── render_summary(diagnostics) -> string ───────────────────────────────
--
-- Total count at the top, then per-category section in CATEGORY_ORDER.
-- Within each category, codes are listed in alphabetical order (the codes
-- are themselves stable identifiers — no human re-wording risk).

--: ({ [integer]: Diag }) -> string
function M.render_summary(diagnostics)
	if #diagnostics == 0 then return "0 errors.\n" end

	local groups = M.group(diagnostics)

	-- Count populated categories.
	local n_categories = 0
	for _ in pairs(groups) do n_categories = n_categories + 1 end

	local parts = {} --[[: { [integer]: string } ]]
	parts[#parts + 1] = tostring(#diagnostics) .. " error"
		.. (#diagnostics == 1 and "" or "s")
		.. " in " .. tostring(n_categories) .. " categor"
		.. (n_categories == 1 and "y" or "ies") .. "."

	for _, cat in ipairs(M.CATEGORY_ORDER) do
		local by_code = groups[cat]
		if by_code ~= nil then
			-- Count diagnostics in this category.
			local cat_count = 0
			for _, bucket in pairs(by_code) do cat_count = cat_count + #bucket end
			parts[#parts + 1] = ""
			parts[#parts + 1] = "[" .. M.CATEGORY_HEADING[cat] .. "] "
				.. tostring(cat_count) .. " error"
				.. (cat_count == 1 and "" or "s")

			-- Stable code order.
			local codes = {} --[[: { [integer]: string } ]]
			for code in pairs(by_code) do codes[#codes + 1] = code end
			sort_strings(codes)
			for _, code in ipairs(codes) do
				local bucket = by_code[code]
				parts[#parts + 1] = "  " .. code .. ": " .. tostring(#bucket)
				for _, d in ipairs(bucket) do
					local pos = d.pos
					local file = pos ~= nil and pos.file or "?"
					local line = pos ~= nil and pos.line or 0
					local col  = pos ~= nil and pos.col or 0
					local suffix = ""
					local mod = d.module
					if mod ~= nil then
						suffix = "  [module=" .. mod .. "]"
					end
					parts[#parts + 1] = "    " .. file .. ":"
						.. tostring(line) .. ":" .. tostring(col)
						.. ": " .. d.msg .. suffix
				end
			end
		end
	end

	return table.concat(parts, "\n") .. "\n"
end

return M
