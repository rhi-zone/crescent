-- lib/pdf/content.lua
-- PDF content stream operator parser (ISO 32000-1 §7.8.2, §8, §9).
--
-- A content stream's syntax is: zero or more PDF objects (its operands —
-- numbers, strings, names, arrays, dictionaries; reusing
-- lib/pdf/object.lua's object parser, since operand syntax is identical to
-- top-level PDF object syntax) followed by a bare keyword (the operator).
-- Operators never nest and never carry an object-syntax "value" of their
-- own — they're just keywords, so this module tokenizes them itself (they
-- are not one of the 8 object types object.lua parses).
--
-- Representation: every operator (recognized or not) parses to a uniform
--   { op = string, args = { [integer]: unknown } }
-- record — see M.string_to_content_stream. `args` holds the operands in
-- the exact native Lua types object.lua already produces for each operand's
-- syntax (a number for a numeric operand, a Lua string for a string
-- operand, a PdfName table for a name operand, a Lua array for an array
-- operand, etc.). This module does NOT special-shape or rename fields per
-- operator ("recognized arg shapes" from the task brief is satisfied by
-- this: object.lua's parser already gives each operand its correct native
-- type; a consumer that knows an operator's spec-defined operand order —
-- e.g. Tf's args are (font-resource-name, size) — reads `args[1]`/`args[2]`
-- directly with its own narrowing helpers, the same pattern every lib/pdf
-- file already uses for `unknown` PDF values). Duplicating per-operator
-- record shapes here would mean two places encode the same spec knowledge
-- (this file and whatever interprets the ops); positional `args` avoids
-- that duplication. No operator is filtered out or dropped — every
-- operator this module doesn't have special handling for still produces an
-- {op, args} record; "unknown ops are opaque" means exactly this uniform
-- shape, not omission.
--
-- SCOPE DECISION — q/Q/cm are parsed like any other operator (uniform
-- {op, args}), not specially. They needed no special *parsing* shape (their
-- operands are plain numbers, already handled generically); the only
-- reason the task brief flagged them is that computing a text span's
-- correct on-page position needs the current transformation matrix (CTM),
-- which q/Q/cm mutate. That interpretation (matrix stack, composing CTM
-- with Tm) is behavioral state tracked by whatever *interprets* this
-- module's output (lib/pdf/text.lua), not something the operator-record
-- parser itself needs to know about. Keeping cm/q/Q uniform here, and
-- doing the matrix math in text.lua, is the same content/interpretation
-- split as the rest of this file.
--
-- INLINE IMAGES (BI...ID...EI, ISO 32000-1 §8.9.7) — the one place this
-- module's syntax genuinely diverges from generic object parsing: the
-- bytes between `ID` and the matching `EI` are raw (possibly binary) image
-- data, not PDF-object syntax, and must be skipped without being
-- object-parsed or the rest of the stream would desync. Handled as a
-- distinct record shape, discriminated by `op`:
--   { op = "INLINE_IMAGE", dict = unknown, data = string }
-- `dict` is the image parameter dictionary (BI's key/value pairs, using
-- object.lua's normal name/value object parsing — abbreviated keys like
-- /W /H /CS /F are not expanded, since this module doesn't interpret
-- images, only preserves them opaquely per the task's "not corrupt parsing
-- of the rest of the stream" bar). `data` is the raw undecoded bytes
-- between `ID` and `EI`.
--
-- Locating the matching `EI` is a documented heuristic, not a spec-exact
-- parse: this module has no reliable way to know the image data's byte
-- length (no mandatory /Length-equivalent key exists for inline images
-- in the base spec), so — like other lightweight PDF parsers — it scans
-- for the first occurrence of the literal bytes "EI" that is preceded by
-- whitespace and followed by whitespace, a delimiter, or end of input.
-- This can misfire if the raw image data itself happens to contain that
-- exact whitespace-bounded "EI" byte sequence; that is a known, accepted
-- gap (image *content* is out of scope for this library — see the task's
-- "what NOT to build" — so a misparse here affects only how much of the
-- image's bytes end up in `data`, never the parse of subsequent operators,
-- since scanning resumes from the (possibly wrong) EI it found — a
-- currently-unavoidable trade-off given no image codec is implemented to
-- compute the true data length from /W, /H, /BPC, /CS).
--
-- Errors: `(nil, errmsg)`, per docs/conventions.md. Pure Lua only.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local pdf_object = require("lib.pdf.object")

local M = {}
M._tier = "pure"

local byte, sub, find = string.byte, string.sub, string.find

--:: ContentOp = { op: string, args: { [integer]: unknown } }
--:: InlineImageOp = { op: "INLINE_IMAGE", dict: unknown, data: string }

-- ── Narrowing helper over `unknown` PDF values ──────────────────────────
-- Mirrors the pattern used throughout lib/pdf/{object,xref,filter}.lua.

--: (unknown) -> string | nil
local function as_name(v)
	if type(v) ~= "table" then return nil end
	local t = v --[[: { [string]: unknown } ]]
	if t.kind ~= "name" then return nil end
	local val = t.value
	if type(val) == "string" then return val end
	return nil
end

-- ── Byte classification ──────────────────────────────────────────────────
-- Mirrored from lib/pdf/object.lua's private WS/DELIM tables (kept local:
-- xref.lua already establishes this precedent — "no framework coupling
-- between the two parsers beyond object.lua's public API" — for the exact
-- same reason: these are simple, stable byte-classification tables, and
-- object.lua does not export them).

local WS = { [0] = true, [9] = true, [10] = true, [12] = true, [13] = true, [32] = true }
local DELIM = {
	[40] = true, [41] = true, [60] = true, [62] = true,
	[91] = true, [93] = true, [123] = true, [125] = true,
	[47] = true, [37] = true,
}

--: (integer | nil) -> boolean
local function is_ws(b) return b ~= nil and WS[b] == true end
--: (integer | nil) -> boolean
local function is_regular(b) return b ~= nil and not WS[b] and not DELIM[b] end

--: (Reader) -> integer | nil
local function peek_byte(r)
	if r.pos > r.len then return nil end
	return byte(r.src, r.pos)
end

--: (Reader, integer) -> integer | nil
local function peek_byte_at(r, offset)
	local p = r.pos + offset
	if p > r.len or p < 1 then return nil end
	return byte(r.src, p)
end

--: (Reader) -> nil
local function skip_ws_and_comments(r)
	while true do
		local b = peek_byte(r)
		if b == nil then return end
		if WS[b] then
			r.pos = r.pos + 1
		elseif b == 37 then -- '%'
			r.pos = r.pos + 1
			while true do
				local c = peek_byte(r)
				if c == nil or c == 10 or c == 13 then break end
				r.pos = r.pos + 1
			end
		else
			return
		end
	end
end

--: (Reader, string) -> boolean
-- Matches a literal bare keyword (e.g. "ID") at the current position
-- without consuming on failure. Mirrors object.lua's match_keyword.
local function match_keyword(r, kw)
	local n = #kw
	if r.pos + n - 1 > r.len then return false end
	if sub(r.src, r.pos, r.pos + n - 1) ~= kw then return false end
	local after = peek_byte_at(r, n)
	if is_regular(after) then return false end
	r.pos = r.pos + n
	return true
end

-- ── Bare operator/keyword token scanning ─────────────────────────────────

--: (Reader) -> string | nil
-- Reads a maximal run of "regular" (non-whitespace, non-delimiter) bytes
-- starting at the current position, e.g. "BT", "Tf", "T*", "'", "\"".
local function read_token(r)
	local start = r.pos
	while is_regular(peek_byte(r)) do r.pos = r.pos + 1 end
	if r.pos == start then return nil end
	return sub(r.src, start, r.pos - 1)
end

-- ── Inline images: BI <dict pairs> ID <raw data> EI ─────────────────────

--: (Reader) -> (InlineImageOp | nil, string | nil)
local function parse_inline_image(r)
	local dict = {}
	while true do
		skip_ws_and_comments(r)
		if match_keyword(r, "ID") then break end
		if peek_byte(r) == nil then return nil, "unterminated inline image dictionary (no 'ID' found)" end
		local key, kerr = pdf_object.parse_object(r)
		if key == nil then return nil, "inline image dictionary key: " .. tostring(kerr) end
		local key_name = as_name(key)
		if key_name == nil then return nil, "inline image dictionary key is not a name" end
		skip_ws_and_comments(r)
		local val, verr = pdf_object.parse_object(r)
		if val == nil then return nil, "inline image dictionary value: " .. tostring(verr) end
		dict[key_name] = val
	end

	-- Exactly one whitespace byte separates 'ID' from the raw data
	-- (ISO 32000-1 §8.9.7).
	if is_ws(peek_byte(r)) then r.pos = r.pos + 1 end
	local data_start = r.pos

	-- Scan for the first "EI" bounded by whitespace on both sides (see file
	-- header for why this is a heuristic, not an exact parse).
	local search_from = data_start
	local ei_pos = nil --: integer | nil
	while true do
		local found = find(r.src, "EI", search_from, true)
		if found == nil then break end
		-- TYPECHECKER WORKAROUND: `found`, narrowed from string.find's
		-- $FindReturn<P>-derived (integer|nil) return, doesn't reliably keep
		-- its narrowed `integer` type across call shapes — same substrate gap
		-- recorded in TODO.md for lib/pdf/object.lua and lib/pdf/xref.lua.
		-- Natural code would use `found` directly with no cast.
		local found_pos = found --[[: integer]]
		local before = found_pos > data_start and byte(r.src, found_pos - 1) or nil
		local after = peek_byte_at(r, found_pos - r.pos + 2)
		local before_ok = found_pos == data_start or is_ws(before)
		local after_ok = after == nil or is_ws(after) or DELIM[after] == true
		if before_ok and after_ok then
			ei_pos = found_pos
			break
		end
		search_from = found_pos + 1
	end
	if ei_pos == nil then return nil, "unterminated inline image: 'EI' not found" end

	-- Strip the single mandatory whitespace byte immediately before 'EI'
	-- from the data (mirrors object.lua's stream/endstream EOL stripping).
	local raw_end = ei_pos
	if raw_end > data_start and is_ws(byte(r.src, raw_end - 1)) then raw_end = raw_end - 1 end
	local data = sub(r.src, data_start, raw_end - 1)

	r.pos = ei_pos
	if not match_keyword(r, "EI") then return nil, "expected 'EI' keyword at offset " .. r.pos end

	return { op = "INLINE_IMAGE", dict = dict, data = data }, nil
end

-- ── Top-level: parse a whole content stream into a sequence of ops ──────

--: (string) -> ({ [integer]: unknown } | nil, string | nil)
function M.string_to_content_stream(bytes)
	local r = pdf_object.new_reader(bytes)
	local ops = {} --[[: { [integer]: unknown } ]]
	local operands = {} --[[: { [integer]: unknown } ]]

	while true do
		skip_ws_and_comments(r)
		if peek_byte(r) == nil then break end

		local before_pos = r.pos
		local operand, oerr = pdf_object.parse_object(r)
		if operand ~= nil then
			operands[#operands + 1] = operand
		else
			-- Not object syntax at this position: either a bare operator
			-- keyword, or a genuine parse error if parse_object consumed
			-- input before failing.
			if r.pos ~= before_pos then
				return nil, "malformed operand in content stream: " .. tostring(oerr)
			end
			local token = read_token(r)
			if token == nil then
				return nil, "unexpected byte in content stream at offset " .. r.pos
			end
			if token == "BI" then
				local img, ierr = parse_inline_image(r)
				if img == nil then return nil, ierr end
				ops[#ops + 1] = img
				operands = {}
			else
				ops[#ops + 1] = { op = token, args = operands }
				operands = {}
			end
		end
	end

	return ops, nil
end

return M
