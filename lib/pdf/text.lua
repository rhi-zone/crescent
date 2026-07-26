-- lib/pdf/text.lua
-- PDF text extraction: ties lib/pdf/content.lua (content-stream operator
-- parsing) and lib/pdf/font.lua (character-code -> Unicode mapping)
-- together with a page's /Resources to produce positioned text.
--
-- TEXT-POSITIONING MATH (ISO 32000-1 §9.4) — matrices are represented as
-- { a, b, c, d, e, f } (the six PDF matrix operands; the implicit third
-- column is always [0, 0, 1]). `multiply(m1, m2)` composes them in PDF's
-- row-vector convention: transforming a point by the result is the same
-- as transforming by m1 first, then by m2 — this is the same order the
-- spec uses for both "CTM_new = M_cm × CTM_old" (cm's own matrix first)
-- and "Trm = scale × Tm × CTM" (scale first, then Tm, then CTM).
--
-- The current transformation matrix (CTM) is tracked through q/Q/cm.
-- SCOPE DECISION (see lib/pdf/content.lua's header for the flip side of
-- this): content.lua deliberately does NOT interpret q/Q/cm — it was a
-- clear call there since parsing them needs no special shape. Here, it's
-- the opposite call: computing a text span's on-page position is
-- genuinely wrong without the CTM, since real-world content streams
-- routinely wrap text in a non-identity `cm` (rotated/scaled form
-- XObjects, page-level transforms). Per spec Table 52, the CTM AND the
-- text state parameters (Tc, Tw, Tz, TL, current font/size, Ts, Tr) are
-- all part of the general graphics state, saved/restored by q/Q — Tm and
-- Tlm are NOT (they're "text object state", reset fresh at every BT and
-- never touched by q/Q). Both halves of that split are implemented below.
--
-- PER-GLYPH WIDTH-BASED ADVANCE — the text matrix's advance between glyphs
-- uses each glyph's width (`w0` in the spec's advance formula, §9.4.3) when
-- the current font's /Widths data is available (lib/pdf/font.lua's
-- `Font.code_to_width`, built from /Widths + /FirstChar + /FontDescriptor
-- /MissingWidth — see that file). `decode_shown_string` sums each shown
-- code's width; `show_text` folds `(width_sum / 1000) * Tfs * Th` into the
-- same advance accumulation TJ adjustments and Tc/Tw already used. When a
-- font has no /Widths array at all (`code_to_width == nil` — legitimate,
-- e.g. a non-embedded standard-14 font relying on built-in metrics, or a
-- Type0/CID font whose /Encoding isn't Identity-H/V, where /DW+/W lookup
-- would need a code->CID CMap this codebase doesn't resolve — see
-- lib/pdf/font.lua's `build_code_to_cid_width` comment; Identity-H/V CID
-- fonts DO get real /DW+/W-driven widths here, code==CID needing no CMap),
-- `width_sum` is 0 and the advance
-- degrades exactly to the previous w0-treated-as-0 approximation: a span's
-- recorded position is always exact (computed from the real Tm/CTM at the
-- start of the operation); only the advance to the NEXT untracked-width
-- operation can undercount. Most real content streams reposition via
-- Td/Tm per line/run anyway, which this module tracks exactly regardless.
--
-- READING-ORDER RECONSTRUCTION — M.spans_to_reading_order groups spans
-- into lines using a Y-tolerance scaled to each span's font size
-- (`Y_LINE_TOLERANCE_RATIO` below), not a fixed constant — a span now
-- carries its `font_size` (see `Span` below) since Tf's size argument is
-- already threaded through `show_text`. A ratio-of-font-size tolerance
-- scales correctly across documents mixing e.g. 8pt footnotes and 24pt
-- headings, where a single fixed tolerance tuned for one would be too
-- tight or too loose for the other.
--
-- SCOPE GAP — a page's coordinate system here is exactly its content
-- stream's default user space (CTM starts at identity at the top of each
-- content stream). A /MediaBox with a non-(0,0) origin would need an
-- additional translation this module doesn't apply (that's a page-level
-- concern the spec would layer on top of the content stream's own CTM,
-- not something content-stream interpretation itself establishes). Real
-- PDFs overwhelmingly use a (0,0)-origin MediaBox; a nonstandard one is a
-- documented, rare gap, not a silent one.
--
-- Errors: `(nil, errmsg)`, per docs/conventions.md. Pure Lua only.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local pdf = require("lib.pdf")
local pdf_content = require("lib.pdf.content")
local pdf_font = require("lib.pdf.font")

local M = {}
M._tier = "pure"

local byte = string.byte

-- ── Narrowing helpers over `unknown` PDF values ──────────────────────────
-- Mirrors the pattern used throughout lib/pdf/{object,xref,filter,content,font}.lua.

--: (unknown) -> { [string]: unknown, [integer]: unknown } | nil
local function as_table(v)
	if type(v) == "table" then return v end
	return nil
end

--: (unknown) -> string | nil
local function as_name(v)
	local t = as_table(v)
	if t == nil then return nil end
	if t.kind ~= "name" then return nil end
	local val = t.value
	if type(val) == "string" then return val end
	return nil
end

--: (unknown) -> number | nil
local function as_number(v)
	if type(v) == "number" then return v end
	return nil
end

--: (unknown) -> string | nil
local function as_string(v)
	if type(v) == "string" then return v end
	return nil
end

--: (unknown) -> { [integer]: unknown } | nil
local function as_array(v)
	return as_table(v)
end

--: (unknown) -> unknown
local function as_stream(v)
	local t = as_table(v)
	if t == nil or t.kind ~= "stream" then return nil end
	return t
end

-- Mirrors lib/pdf/init.lua's Document shape (same-shape local
-- redeclaration — type declarations don't cross `require` boundaries in
-- this typechecker; see lib/pdf/font.lua's identical note).
--:: Document = { bytes: string, entries: unknown, trailer: unknown }

-- ── 2D affine matrices (ISO 32000-1 §8.3.4, §9.4.2, §9.4.4) ──────────────

--:: Matrix = { a: number, b: number, c: number, d: number, e: number, f: number }

--: () -> Matrix
local function identity_matrix()
	return { a = 1, b = 0, c = 0, d = 1, e = 0, f = 0 }
end

--: (number, number) -> Matrix
local function translation_matrix(tx, ty)
	return { a = 1, b = 0, c = 0, d = 1, e = tx, f = ty }
end

--- Composes m1 and m2 such that transforming a point by the result equals
-- transforming by m1 first, then by m2 (PDF's row-vector convention).
--: (Matrix, Matrix) -> Matrix
local function multiply(m1, m2)
	return {
		a = m1.a * m2.a + m1.b * m2.c,
		b = m1.a * m2.b + m1.b * m2.d,
		c = m1.c * m2.a + m1.d * m2.c,
		d = m1.c * m2.b + m1.d * m2.d,
		e = m1.e * m2.a + m1.f * m2.c + m2.e,
		f = m1.e * m2.b + m1.f * m2.d + m2.f,
	}
end

-- ── Graphics-state text parameters (ISO 32000-1 Table 52) ────────────────
-- Saved/restored by q/Q, distinct from Tm/Tlm (which are NOT — see file
-- header). `font_name` is the /Resources /Font key (e.g. "F1"), not a
-- resolved Font; resolution is cached separately (see get_font below).

--:: TextGraphicsState = {
--::   ctm: Matrix,
--::   font_name: string | nil, font_size: number,
--::   char_spacing: number, word_spacing: number,
--::   h_scale: number, leading: number, rise: number, render_mode: number,
--:: }

--: () -> TextGraphicsState
local function initial_graphics_state()
	return {
		ctm = identity_matrix(),
		font_name = nil, font_size = 0,
		char_spacing = 0, word_spacing = 0,
		h_scale = 100, leading = 0, rise = 0, render_mode = 0,
	}
end

--: (TextGraphicsState) -> TextGraphicsState
local function copy_graphics_state(gs)
	return {
		ctm = { a = gs.ctm.a, b = gs.ctm.b, c = gs.ctm.c, d = gs.ctm.d, e = gs.ctm.e, f = gs.ctm.f },
		font_name = gs.font_name, font_size = gs.font_size,
		char_spacing = gs.char_spacing, word_spacing = gs.word_spacing,
		h_scale = gs.h_scale, leading = gs.leading, rise = gs.rise, render_mode = gs.render_mode,
	}
end

-- Mirrors lib/pdf/font.lua's Font shape (same-shape local redeclaration —
-- see this file's Document note above for why).
--:: Font = {
--::   code_width: integer,
--::   code_to_unicode: (integer) -> (string | nil),
--::   code_to_width: ((integer) -> number) | nil,
--:: }

--: (unknown) -> Font | nil
-- Narrows an `unknown` value (as returned by requiring lib.pdf.font, whose
-- own Font type doesn't cross the require boundary — see Document note
-- above) into this file's local Font alias. Narrows via a direct
-- `type(v) == "table"` check (NOT via as_table's declared index-signature
-- return type, which is a specific structural type of its own that a
-- concrete record like Font doesn't checked-cast-assign from — the
-- generic table type this direct check narrows to is what a checked,
-- non-forced, cast to a concrete record is accepted from). Same two-step
-- pattern lib/pdf/font_test.lua's `as_font` uses.
local function as_font(v)
	if type(v) ~= "table" then return nil end
	local f = v --[[: Font]]
	return f
end

-- ── Decoding a shown string through the current font ─────────────────────

--: (Font, string) -> (string, integer, integer, number)
-- Returns (decoded unicode text, number of character codes shown, number
-- of those codes eligible for word spacing — single-byte code 32 only, per
-- spec's word-spacing exception for multi-byte codes — and the sum of each
-- shown code's glyph width in glyph space / thousandths, ISO 32000-1
-- §9.4.3's w0 term, summed rather than per-glyph since the caller applies
-- one Tfs/Th scale to the whole run). The width sum is 0 when the font has
-- no /Widths data (font_obj.code_to_width == nil) — same as before /Widths
-- parsing existed, since the caller's advance formula then degrades
-- exactly to the old w0-treated-as-0 approximation.
local function decode_shown_string(font_obj, bytes)
	local width = font_obj.code_width
	local code_to_unicode = font_obj.code_to_unicode
	local code_to_width = font_obj.code_to_width
	local parts = {}
	local n = #bytes
	local n_units = 0
	local n_space_units = 0
	local width_sum = 0 --: number
	if width == 2 then
		local i = 1
		while i + 1 <= n do
			local b1 = byte(bytes, i) or 0
			local b2 = byte(bytes, i + 1) or 0
			local code = b1 * 256 + b2
			local decoded = code_to_unicode(code)
			if decoded ~= nil then parts[#parts + 1] = decoded end
			if code_to_width ~= nil then width_sum = width_sum + code_to_width(code) end
			n_units = n_units + 1
			i = i + 2
		end
	else
		for i = 1, n do
			local code = byte(bytes, i) or 0
			local decoded = code_to_unicode(code)
			if decoded ~= nil then parts[#parts + 1] = decoded end
			if code_to_width ~= nil then width_sum = width_sum + code_to_width(code) end
			n_units = n_units + 1
			if code == 32 then n_space_units = n_space_units + 1 end
		end
	end
	return table.concat(parts), n_units, n_space_units, width_sum
end

-- ── Page-level content-stream interpretation ─────────────────────────────

--:: Span = { text: string, x: number, y: number, font_name: string | nil, font_size: number }

-- ── Reading-order reconstruction ─────────────────────────────────────────
-- Placed before page_to_text (which calls M.spans_to_reading_order) so its
-- concrete signature is visible at that call site rather than inferred
-- from a forward reference.

-- Font-size-adaptive Y-proximity tolerance for "same line" grouping — see
-- file header. Ratio is heuristic (not a spec value: nothing in ISO
-- 32000-1 defines "same line" — it's a reading-order reconstruction this
-- module performs on top of positioned spans, same as pdf.js/pdfplumber
-- unofficial-heuristic prior art for the same problem). 0.3x font size
-- comfortably covers normal baseline jitter (subscript/superscript Ts,
-- rounding) without merging adjacent same-size text lines, whose baselines
-- are normally a full line-height (~1.0-1.5x font size) apart.
-- MIN_Y_LINE_TOLERANCE floors it for degenerate/zero-font-size spans
-- (e.g. a font never set via Tf) at the old fixed constant's value, so
-- that pre-existing case doesn't regress to zero-tolerance (every span on
-- its own line).
local Y_LINE_TOLERANCE_RATIO = 0.3
local MIN_Y_LINE_TOLERANCE = 3

-- table.sort's declared signature takes a comparator of `(unknown, unknown)
-- -> boolean | nil` (it must accept any array's element type); a
-- comparator typed to take `Span` directly isn't assignable there
-- (contravariance). Narrowed the same way as_font narrows `unknown` into
-- `Font` above: a direct `type(v) == "table"` check, then a checked (not
-- forced) cast — never a force cast past unnarrowed `unknown`, since every
-- value actually passed to these comparators is one this same function
-- constructed as a Span a few lines above the sort call.
--: (unknown, unknown) -> boolean
local function span_x_less(a, b)
	if type(a) ~= "table" or type(b) ~= "table" then return false end
	local a_ = a --[[: Span]]
	local b_ = b --[[: Span]]
	return a_.x < b_.x
end

--: (unknown, unknown) -> boolean
local function span_y_greater(a, b)
	if type(a) ~= "table" or type(b) ~= "table" then return false end
	local a_ = a --[[: Span]]
	local b_ = b --[[: Span]]
	return a_.y > b_.y
end

--:: Line = { y: number, font_size: number, spans: { [integer]: Span } }

--- Groups spans into lines by Y-proximity (PDF y increases upward, so
-- lines come out top-of-page first) and sorts each line's spans by X
-- ascending (left to right). Returns an array of `Line` records, `y`
-- being the first (topmost) span's y in that line — a representative
-- value for the line, not every span's exact y. The Y-tolerance used to
-- decide "same line" is `max(line's representative font_size, this span's
-- font_size) * Y_LINE_TOLERANCE_RATIO`, floored at MIN_Y_LINE_TOLERANCE —
-- see those constants' comments above.
--: ({ [integer]: Span }) -> { [integer]: Line }
function M.spans_to_reading_order(spans)
	local sorted = {} --[[: { [integer]: Span } ]]
	local i = 1
	while spans[i] ~= nil do
		sorted[i] = spans[i]
		i = i + 1
	end
	table.sort(sorted, span_y_greater)

	local lines = {} --[[: { [integer]: Line } ]]
	local current = nil --: Line | nil
	local j = 1
	while sorted[j] ~= nil do
		local span = sorted[j]
		local same_line = false
		if current ~= nil then
			local tolerance = math.max(current.font_size, span.font_size) * Y_LINE_TOLERANCE_RATIO
			if tolerance < MIN_Y_LINE_TOLERANCE then tolerance = MIN_Y_LINE_TOLERANCE end
			if math.abs(span.y - current.y) <= tolerance then same_line = true end
		end
		if not same_line then
			current = { y = span.y, font_size = span.font_size, spans = {} }
			lines[#lines + 1] = current
		end
		local line = current
		if line ~= nil then
			line.spans[#line.spans + 1] = span
		end
		j = j + 1
	end

	local k = 1
	while lines[k] ~= nil do
		table.sort(lines[k].spans, span_x_less)
		k = k + 1
	end

	return lines
end

--: (Document, unknown) -> ({ [string]: unknown, [integer]: unknown } | nil)
-- Walks /Parent to find the nearest ancestor's /Resources (inheritable
-- attribute, ISO 32000-1 §7.6.4 / Table 30). Guards against a malformed
-- (cyclic) ancestor chain with a fixed iteration cap — real page trees
-- are never deep.
local function find_resources(doc, page_dict)
	local node = as_table(page_dict)
	local guard = 0
	while node ~= nil and guard < 64 do
		guard = guard + 1
		local res = as_table(pdf.resolve(doc, node.Resources))
		if res ~= nil then return res end
		node = as_table(pdf.resolve(doc, node.Parent))
	end
	return nil
end

--: (Document, unknown) -> (string | nil, string | nil)
-- /Contents is either a single stream or an array of streams to be
-- concatenated (ISO 32000-1 Table 30). A page legitimately may have no
-- /Contents at all (a blank page) — that is not an error, just empty text.
local function page_contents_bytes(doc, page_dict)
	local page = as_table(page_dict)
	if page == nil then return nil, "page_dict is not a dictionary" end
	local contents = pdf.resolve(doc, page.Contents)
	if contents == nil then return "", nil end

	local single = as_stream(contents)
	if single ~= nil then return pdf.stream_to_bytes(single) end

	local arr = as_array(contents)
	if arr == nil then return nil, "/Contents is neither a stream nor an array of streams" end

	local parts = {}
	local i = 1
	while arr[i] ~= nil do
		local st = as_stream(pdf.resolve(doc, arr[i]))
		if st == nil then return nil, "/Contents array element " .. i .. " is not a stream" end
		local bytes, err = pdf.stream_to_bytes(st)
		if bytes == nil then return nil, "failed to decode /Contents stream " .. i .. ": " .. tostring(err) end
		parts[#parts + 1] = bytes
		i = i + 1
	end
	-- Streams are joined with a newline (PDF whitespace) so a token
	-- straddling the boundary between two concatenated streams (e.g. the
	-- end of one operator and the start of the next) can never fuse into
	-- one token — the spec requires producers to avoid this, but content
	-- streams are untrusted input, not spec-guaranteed-conformant data.
	return table.concat(parts, "\n"), nil
end

--- Extracts positioned text from a single (already-resolved) page
-- dictionary. `page_dict` should have /Type /Page; /Resources is looked
-- up via inheritance if absent on the page itself.
--: (Document, unknown) -> ({ text: string, spans: { [integer]: Span } } | nil, string | nil)
function M.page_to_text(doc, page_dict)
	local page = as_table(pdf.resolve(doc, page_dict))
	if page == nil then return nil, "page_dict is not a dictionary" end

	local resources = find_resources(doc, page)
	local font_dict = nil --: { [string]: unknown, [integer]: unknown } | nil
	if resources ~= nil then font_dict = as_table(pdf.resolve(doc, resources.Font)) end

	local content_bytes, cerr = page_contents_bytes(doc, page)
	if content_bytes == nil then return nil, cerr end

	local ops, operr = pdf_content.string_to_content_stream(content_bytes)
	if ops == nil then return nil, "failed to parse content stream: " .. tostring(operr) end

	-- Lazily-resolved, cached per resource name. `false` is a negative-
	-- cache sentinel (font resource present but failed to resolve/build —
	-- avoids re-attempting and re-erroring on every subsequent Tf/Tj).
	local font_cache = {} --[[: { [string]: (Font | boolean) } ]]
	--: (string | nil) -> Font | nil
	local function get_font(name)
		if name == nil then return nil end
		local cached = font_cache[name]
		if cached ~= nil then
			if cached == false then return nil end
			return as_font(cached)
		end
		if font_dict == nil then
			font_cache[name] = false
			return nil
		end
		local dict = as_table(pdf.resolve(doc, font_dict[name]))
		if dict == nil then
			font_cache[name] = false
			return nil
		end
		local f, ferr = pdf_font.font_from_dict(doc, dict)
		local font_obj = as_font(f)
		if font_obj == nil then
			font_cache[name] = false
			return nil
		end
		font_cache[name] = font_obj
		return font_obj
	end

	local gs = initial_graphics_state()
	local gs_stack = {} --[[: { [integer]: TextGraphicsState } ]]
	local tm = nil --: Matrix | nil
	local tlm = nil --: Matrix | nil
	local spans = {} --[[: { [integer]: Span } ]]

	--: ({ [integer]: unknown }) -> nil
	-- Handles Tj (single-string array) and TJ (mixed string/number array)
	-- uniformly: one span per call, at the position computed BEFORE any of
	-- this call's own advances (see file header's w0-less advance model).
	local function show_text(elements)
		if tm == nil then return end -- Tj/TJ outside BT: malformed, ignore
		local font_obj = get_font(gs.font_name)
		if font_obj == nil then return end -- unresolvable font: can't decode, skip

		local th = gs.h_scale / 100
		local scale = { a = gs.font_size * th, b = 0, c = 0, d = gs.font_size, e = 0, f = gs.rise }
		local trm = multiply(multiply(scale, tm), gs.ctm)
		local span_x, span_y = trm.e, trm.f

		local text_parts = {}
		local total_tx = 0 --[[: number]]
		local i = 1
		while elements[i] ~= nil do
			local el = elements[i]
			local s = as_string(el)
			if s ~= nil then
				local decoded, n_units, n_space, width_sum = decode_shown_string(font_obj, s)
				text_parts[#text_parts + 1] = decoded
				total_tx = total_tx
					+ (n_units * gs.char_spacing + n_space * gs.word_spacing) * th
					+ (width_sum / 1000) * gs.font_size * th
			else
				local adj = as_number(el)
				if adj ~= nil then
					total_tx = total_tx + (-adj / 1000) * gs.font_size * th
				end
			end
			i = i + 1
		end

		local combined = table.concat(text_parts)
		if combined ~= "" then
			spans[#spans + 1] =
				{ text = combined, x = span_x, y = span_y, font_name = gs.font_name, font_size = gs.font_size }
		end
		tm = multiply(translation_matrix(total_tx, 0), tm)
	end

	--: () -> nil
	-- T* / next-line component shared by T*, ', ".
	local function next_line()
		if tlm == nil then return end
		tlm = multiply(translation_matrix(0, -gs.leading), tlm)
		tm = tlm
	end

	local i = 1
	while ops[i] ~= nil do
		local raw_op = as_table(ops[i])
		i = i + 1
		if raw_op ~= nil then
			local op = raw_op.op
			local args = as_array(raw_op.args) or {}

			if op == "q" then
				gs_stack[#gs_stack + 1] = copy_graphics_state(gs)
			elseif op == "Q" then
				local popped = table.remove(gs_stack)
				if popped ~= nil then gs = popped end
			elseif op == "cm" then
				local a, b, c, d, e, f =
					as_number(args[1]), as_number(args[2]), as_number(args[3]),
					as_number(args[4]), as_number(args[5]), as_number(args[6])
				if a ~= nil and b ~= nil and c ~= nil and d ~= nil and e ~= nil and f ~= nil then
					gs.ctm = multiply({ a = a, b = b, c = c, d = d, e = e, f = f }, gs.ctm)
				end
			elseif op == "BT" then
				tm = identity_matrix()
				tlm = identity_matrix()
			elseif op == "ET" then
				tm = nil
				tlm = nil
			elseif op == "Tf" then
				gs.font_name = as_name(args[1])
				gs.font_size = as_number(args[2]) or gs.font_size
			elseif op == "Tc" then
				gs.char_spacing = as_number(args[1]) or gs.char_spacing
			elseif op == "Tw" then
				gs.word_spacing = as_number(args[1]) or gs.word_spacing
			elseif op == "Tz" then
				gs.h_scale = as_number(args[1]) or gs.h_scale
			elseif op == "TL" then
				gs.leading = as_number(args[1]) or gs.leading
			elseif op == "Ts" then
				gs.rise = as_number(args[1]) or gs.rise
			elseif op == "Tr" then
				gs.render_mode = as_number(args[1]) or gs.render_mode
			elseif op == "Td" or op == "TD" then
				local tx = as_number(args[1]) or 0
				local ty = as_number(args[2]) or 0
				if op == "TD" then gs.leading = -ty end
				if tlm ~= nil then
					tlm = multiply(translation_matrix(tx, ty), tlm)
					tm = tlm
				end
			elseif op == "Tm" then
				local a, b, c, d, e, f =
					as_number(args[1]), as_number(args[2]), as_number(args[3]),
					as_number(args[4]), as_number(args[5]), as_number(args[6])
				if a ~= nil and b ~= nil and c ~= nil and d ~= nil and e ~= nil and f ~= nil then
					local m = { a = a, b = b, c = c, d = d, e = e, f = f }
					tm = m
					tlm = { a = m.a, b = m.b, c = m.c, d = m.d, e = m.e, f = m.f }
				end
			elseif op == "T*" then
				next_line()
			elseif op == "Tj" then
				show_text({ args[1] })
			elseif op == "TJ" then
				show_text(as_array(args[1]) or {})
			elseif op == "'" then
				next_line()
				show_text({ args[1] })
			elseif op == "\"" then
				gs.word_spacing = as_number(args[1]) or gs.word_spacing
				gs.char_spacing = as_number(args[2]) or gs.char_spacing
				next_line()
				show_text({ args[3] })
			end
			-- Every other operator (path construction, painting, color,
			-- clipping, marked content, inline images, ...) doesn't affect
			-- text position or content and is intentionally ignored.
		end
	end

	local lines = M.spans_to_reading_order(spans)
	local line_texts = {}
	local li = 1
	while lines[li] ~= nil do
		local line = lines[li]
		local span_texts = {}
		local si = 1
		while line.spans[si] ~= nil do
			span_texts[#span_texts + 1] = line.spans[si].text
			si = si + 1
		end
		line_texts[#line_texts + 1] = table.concat(span_texts, " ")
		li = li + 1
	end

	return { text = table.concat(line_texts, "\n"), spans = spans }, nil
end

-- ── Document-level page-tree walk ─────────────────────────────────────────

--: (Document, unknown, { [integer]: unknown }, { [integer]: boolean }) -> string | nil
-- Recursively collects leaf /Type /Page nodes in document order. Cycle
-- guard keys on the object number of each Kids entry that is itself an
-- indirect reference (the normal case — Page/Pages nodes are always
-- indirect objects per spec) since resolved objects are freshly-parsed
-- tables each call and can't be identity-deduplicated.
local function collect_pages(doc, node_ref, out, seen)
	local node_ref_t = as_table(node_ref)
	if node_ref_t ~= nil and node_ref_t.kind == "reference" then
		local num = as_number(node_ref_t.num)
		if num ~= nil then
			if seen[num] then return nil end
			seen[num] = true
		end
	end

	local node = as_table(pdf.resolve(doc, node_ref))
	if node == nil then return "page tree node is not a dictionary" end

	local node_type = as_name(node.Type)
	local kids = as_array(pdf.resolve(doc, node.Kids))
	if kids ~= nil and node_type ~= "Page" then
		local i = 1
		while kids[i] ~= nil do
			local err = collect_pages(doc, kids[i], out, seen)
			if err ~= nil then return err end
			i = i + 1
		end
		return nil
	end

	out[#out + 1] = node
	return nil
end

--- Extracts positioned text from every page in the document, in document
-- order (walking Catalog -> Pages -> Kids, recursively, per ISO 32000-1
-- §7.7.3). Returns an array (1-based, in page order) of the same shape
-- `M.page_to_text` returns per page.
--: (Document) -> ({ [integer]: unknown } | nil, string | nil)
function M.document_to_text(doc)
	local root, rerr = pdf.document_root(doc)
	if root == nil then return nil, rerr end
	local root_t = as_table(root)
	if root_t == nil then return nil, "document catalog is not a dictionary" end
	if root_t.Pages == nil then return nil, "document catalog has no /Pages entry" end

	local pages = {} --[[: { [integer]: unknown } ]]
	local err = collect_pages(doc, root_t.Pages, pages, {})
	if err ~= nil then return nil, err end

	local results = {} --[[: { [integer]: unknown } ]]
	local i = 1
	while pages[i] ~= nil do
		local page_result, perr = M.page_to_text(doc, pages[i])
		if page_result == nil then return nil, "page " .. i .. ": " .. tostring(perr) end
		results[i] = page_result
		i = i + 1
	end
	return results, nil
end

return M
