-- lib/pdf/form.lua
-- AcroForm field extraction and value filling (ISO 32000-1 §12.7).
--
-- Built entirely on the resolved PDF object model lib/pdf/init.lua exposes
-- (`pdf.resolve`, `pdf.document_root`) — this module never parses bytes
-- directly. Filling a field's value never rewrites the source file: it
-- produces new/replacement indirect objects and hands them to
-- lib/pdf/write.lua's incremental-update writer.
--
-- Scope boundary: this module never regenerates a field's on-page
-- *appearance stream* (the glyphs drawn in the widget's rectangle) — that
-- needs font metrics and text layout, which lib/pdf explicitly defers (see
-- lib/pdf/init.lua's header). Instead, filling sets the field's /V (and, for
-- checkbox/radio-button widgets, each widget's /AS to match) and sets
-- /NeedAppearances true on the AcroForm dictionary when that dictionary is
-- itself an indirect object — the spec-sanctioned way (ISO 32000-1 §12.7.2,
-- Table 218) to tell a conforming viewer to regenerate every field's
-- appearance itself when the document is next opened, instead of trusting
-- whatever appearance streams are already there. Reading an existing
-- appearance dictionary's *state names* (`/AP /N`'s dictionary keys, e.g.
-- "Yes"/"Off") is plain object-model navigation, not content-stream
-- parsing, and is in scope; reading the *content* of an appearance stream
-- (the drawing operators inside it) is not.
--
-- A field record represents one *widget* (one on-page appearance of a
-- field), not one field name: the PDF object model has field-level
-- attributes (name, type, value, default value, flags — held on the
-- terminal field dictionary) and separate widget-level attributes (page,
-- rectangle — held on a Widget annotation, ISO 32000-1 §12.5.6.19), and a
-- single field can have more than one widget (radio button groups: one
-- widget per page/position, one shared field for the group's value; a
-- checkbox repeated on multiple pages). This module flattens that into one
-- record per widget, repeating the field-level attributes across each of a
-- field's widgets, rather than inventing a nested "widgets: [...]" shape not
-- asked for by the field's own attributes — a caller that only cares about
-- single-widget fields (the overwhelming common case) never needs to know
-- the distinction exists.
--
-- Errors: `(nil, errmsg)`, per docs/conventions.md.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local pdf = require("lib.pdf")
local pdf_write = require("lib.pdf.write")
local bit = require("bit")
local band = bit.band

local M = {}
M._tier = "pure"

-- ── Narrowing helpers over `unknown` PDF values ──────────────────────────────
-- Mirrors the pattern used throughout lib/pdf/xref.lua and lib/pdf/filter.lua.

--: (unknown) -> { [string]: unknown, [integer]: unknown } | nil
local function as_table(v)
	if type(v) == "table" then return v end
	return nil
end

--: (unknown) -> number | nil
local function as_number(v)
	if type(v) == "number" then return v end
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

--: (unknown) -> { [integer]: unknown } | nil
local function as_array(v)
	-- Arrays and dictionaries are both plain, untagged tables in
	-- lib/pdf/object.lua's representation (see its header comment); every
	-- array this module reads (/Kids, /Fields, /Rect) is spec-mandated to be
	-- an array when present, so there is no separate discriminator to check.
	return as_table(v)
end

--: (unknown) -> boolean
local function is_reference(v)
	local t = as_table(v)
	return t ~= nil and t.kind == "reference"
end

--:: FormDocument = { bytes: string, entries: unknown, trailer: unknown, objstm_cache: unknown }

-- ── Field type mapping (ISO 32000-1 §12.7.4, Table 220 /FT values) ─────────

--:: FieldType = "text" | "checkbox" | "radio" | "choice" | "signature" | "pushbutton" | "unknown"

-- Field flag bits relevant to distinguishing sub-kinds of /FT /Btn and /Ch
-- (ISO 32000-1 §12.7.3.1 Table 221, §12.7.4.2 Table 226, §12.7.4.5 Table 228).
local FF_BTN_RADIO = 0x8000     -- bit 16: Radio
local FF_BTN_PUSHBUTTON = 0x10000 -- bit 17: Pushbutton
local FF_CH_COMBO = 0x20000     -- bit 18: Combo (dropdown vs list box; both reported as "choice")

--: (string | nil, number) -> FieldType
local function field_kind(ft, ff)
	if ft == "Tx" then return "text" end
	if ft == "Ch" then return "choice" end
	if ft == "Sig" then return "signature" end
	if ft == "Btn" then
		local ffi = math.floor(ff)
		if band(ffi, FF_BTN_PUSHBUTTON) ~= 0 then return "pushbutton" end
		if band(ffi, FF_BTN_RADIO) ~= 0 then return "radio" end
		return "checkbox"
	end
	return "unknown"
end
-- FF_CH_COMBO isn't distinguished in FieldType (both combo and list-box
-- choice fields report "choice"); kept named above for the reader who wants
-- to know the bit exists, not dropped silently.
local _ = FF_CH_COMBO

-- name: fully qualified field name. type: FieldType. value/default_value:
-- resolved /V, /DV. flags: /Ff (0 if absent). page: the widget's page
-- reference, or nil if undeterminable. rect: the widget's /Rect array, or
-- nil. field_num/field_gen: the indirect object number/generation of the
-- field dictionary /V should be written to when filling (nil if the field
-- isn't backed by its own indirect object).
--:: FormField = { name: string, type: FieldType, value: unknown, default_value: unknown, flags: number, page: unknown | nil, rect: { [integer]: unknown } | nil, field_num: number | nil, field_gen: number | nil }

-- ── Page lookup for a widget lacking its own /P entry ───────────────────────
-- /P is optional on an annotation dictionary (ISO 32000-1 Table 164); when
-- absent, the only way to find a widget's page is to search the page tree's
-- /Annots arrays for a reference matching the widget's own indirect-object
-- identity. This walk is cached per document (keyed by the /Pages tree
-- reference visited) so filling/extracting many widgets from one document
-- doesn't re-walk the page tree per widget.

-- Keyed "num gen" -> page reference.
--:: PageAnnotIndex = { [string]: unknown }

--: (FormDocument, unknown, PageAnnotIndex) -> nil
local function index_page_annots(doc, node_ref, index)
	local node, err = pdf.resolve(doc, node_ref)
	if node == nil then return end
	local nt = as_table(node)
	if nt == nil then return end
	if as_name(nt.Type) == "Pages" then
		local kids = as_array(nt.Kids)
		if kids == nil then return end
		local i = 1
		while kids[i] ~= nil do
			index_page_annots(doc, kids[i], index)
			i = i + 1
		end
		return
	end
	-- A Page (or a node without /Type — some writers omit it on leaves):
	-- record each of its /Annots entries against this page reference.
	local annots = as_array(nt.Annots)
	if annots == nil then return end
	local i = 1
	while annots[i] ~= nil do
		local aref = annots[i]
		local at = as_table(aref)
		if at ~= nil and at.kind == "reference" then
			local key = tostring(as_number(at.num)) .. " " .. tostring(as_number(at.gen))
			index[key] = node_ref
		end
		i = i + 1
	end
end

--: (FormDocument, unknown | nil, unknown | nil) -> unknown | nil
-- `own_p` is the widget's own /P entry, if any (preferred — no search
-- needed). `widget_ref` is the reference the widget was reached through
-- (nil if it wasn't reached via a reference at all, e.g. an irregular
-- inline dictionary — in which case its page genuinely cannot be
-- determined and this returns nil, a documented limitation rather than a
-- guess).
local function widget_page(doc, own_p, widget_ref, page_index)
	if own_p ~= nil then return own_p end
	if widget_ref == nil then return nil end
	local wt = as_table(widget_ref)
	if wt == nil or wt.kind ~= "reference" then return nil end
	local key = tostring(as_number(wt.num)) .. " " .. tostring(as_number(wt.gen))
	return page_index[key]
end

-- ── Field tree walk (ISO 32000-1 §12.7.3.2 field-attribute inheritance) ─────

--:: Inherited = { ft: string | nil, ff: number, v: unknown, dv: unknown }

--: (FormDocument, unknown, unknown | nil, Inherited, string, PageAnnotIndex, { [integer]: FormField }) -> (nil, string | nil)
local function walk_field(doc, node_ref, node_ref_identity, inherited, name_prefix, page_index, out)
	local node, rerr = pdf.resolve(doc, node_ref)
	if node == nil then return nil, rerr end
	local nt = as_table(node)
	if nt == nil then return nil, "form field is not a dictionary" end

	local own_ft = as_name(nt.FT)
	local ft = own_ft or inherited.ft
	local own_ff = as_number(nt.Ff)
	local ff = own_ff or inherited.ff
	local v = nt.V
	if v == nil then v = inherited.v end
	local dv = nt.DV
	if dv == nil then dv = inherited.dv end

	local part = nt.T
	local part_name = nil --: string | nil
	if type(part) == "string" then
		part_name = part
	end
	local qualified = name_prefix
	if part_name ~= nil then
		if name_prefix == "" then qualified = part_name else qualified = name_prefix .. "." .. part_name end
	end

	local kids = as_array(nt.Kids)

	-- Distinguish widget-kids (annotations merged under a field with a
	-- single name — no /T of their own) from field-kids (child nodes of a
	-- hierarchical field name — each has its own /T). Per ISO 32000-1
	-- §12.7.3.2: a Kids entry with a /T is a field; without one, it's this
	-- field's own Widget annotation.
	local has_named_kid = false
	if kids ~= nil then
		local i = 1
		while kids[i] ~= nil do
			local kid, kerr = pdf.resolve(doc, kids[i])
			if kid == nil then return nil, kerr end
			local kt = as_table(kid)
			if kt ~= nil and type(kt.T) == "string" then has_named_kid = true end
			i = i + 1
		end
	end

	if has_named_kid then
		local child_inherited = { ft = ft, ff = ff, v = v, dv = dv }
		local i = 1
		while kids[i] ~= nil do
			local _, werr = walk_field(doc, kids[i], kids[i], child_inherited, qualified, page_index, out)
			if werr ~= nil then return nil, werr end
			i = i + 1
		end
		return nil, nil
	end

	-- This node is a terminal field. It may also directly be a widget
	-- (merged field+widget, the common single-widget case: /Subtype
	-- /Widget or a /Rect present directly on it) and/or have widget Kids
	-- (multi-widget fields: radio groups, a checkbox repeated across pages).
	local field_num = nil --[[: number | nil]]
	local field_gen = nil --[[: number | nil]]
	local ident = as_table(node_ref_identity)
	if ident ~= nil and ident.kind == "reference" then
		field_num = as_number(ident.num)
		field_gen = as_number(ident.gen)
	end

	local kind = field_kind(ft, ff)
	local self_is_widget = as_name(nt.Subtype) == "Widget" or nt.Rect ~= nil

	local emitted_any = false
	if self_is_widget then
		emitted_any = true
		out[#out + 1] = {
			name = qualified,
			type = kind,
			value = v,
			default_value = dv,
			flags = ff,
			page = widget_page(doc, nt.P, node_ref_identity, page_index),
			rect = as_array(nt.Rect),
			field_num = field_num,
			field_gen = field_gen,
		}
	end

	if kids ~= nil then
		local i = 1
		while kids[i] ~= nil do
			local kid_ref = kids[i]
			local kid, kerr = pdf.resolve(doc, kid_ref)
			if kid == nil then return nil, kerr end
			local kt = as_table(kid)
			if kt ~= nil then
				emitted_any = true
				out[#out + 1] = {
					name = qualified,
					type = kind,
					value = v,
					default_value = dv,
					flags = ff,
					page = widget_page(doc, kt.P, kid_ref, page_index),
					rect = as_array(kt.Rect),
					field_num = field_num,
					field_gen = field_gen,
				}
			end
			i = i + 1
		end
	end

	if not emitted_any then
		-- A terminal field with no widget of its own and no widget Kids:
		-- structurally unusual (nothing to display/click), but not an
		-- error — report it with no page/rect rather than dropping it, so a
		-- caller filling its /V by name still finds it.
		out[#out + 1] = {
			name = qualified,
			type = kind,
			value = v,
			default_value = dv,
			flags = ff,
			page = nil,
			rect = nil,
			field_num = field_num,
			field_gen = field_gen,
		}
	end

	return nil, nil
end

--- Extract every AcroForm field in `doc` (ISO 32000-1 §12.7). Returns one
-- record per widget (see module header for why); a field with multiple
-- widgets appears multiple times under the same `name`.
--: (FormDocument) -> ({ [integer]: FormField } | nil, string | nil)
function M.document_to_fields(doc)
	local root, rerr = pdf.document_root(doc)
	if root == nil then return nil, rerr end
	local rt = as_table(root)
	if rt == nil then return nil, "document catalog is not a dictionary" end
	if rt.AcroForm == nil then return nil, "document has no /AcroForm" end
	local acroform, aerr = pdf.resolve(doc, rt.AcroForm)
	if acroform == nil then return nil, aerr end
	local at = as_table(acroform)
	if at == nil then return nil, "/AcroForm is not a dictionary" end
	local fields = as_array(at.Fields)
	if fields == nil then return nil, "/AcroForm has no /Fields array" end

	local pages, perr = pdf.document_root(doc)
	if pages == nil then return nil, perr end
	local page_index = {} --[[: PageAnnotIndex ]]
	local root_pages = as_table(pages).Pages
	if root_pages ~= nil then index_page_annots(doc, root_pages, page_index) end

	local out = {} --[[: { [integer]: FormField } ]]
	local i = 1
	while fields[i] ~= nil do
		local _, werr = walk_field(doc, fields[i], fields[i], { ft = nil, ff = 0, v = nil, dv = nil }, "", page_index, out)
		if werr ~= nil then return nil, "field " .. i .. ": " .. werr end
		i = i + 1
	end
	return out, nil
end

-- ── Filling ──────────────────────────────────────────────────────────────────

--: ({ [integer]: FormField }, string) -> { [integer]: FormField }
-- All widget records sharing a field name — a caller filling that field's
-- value needs every widget updated (e.g. every radio button in a group
-- needs its /AS reconsidered against the same new /V).
local function fields_by_name(fields, name)
	local matches = {} --[[: { [integer]: FormField } ]]
	local i = 1
	while fields[i] ~= nil do
		if fields[i].name == name then matches[#matches + 1] = fields[i] end
		i = i + 1
	end
	return matches
end

--: (unknown) -> string | nil
-- The appearance-state name a /V or /AS value names, whether stored as a
-- Name object (the common /Btn case) or, more permissively, a bare string.
local function state_name(v)
	local n = as_name(v)
	if n ~= nil then return n end
	if type(v) == "string" then return v end
	return nil
end

-- A widget's /AP /N appearance-state dictionary, keyed by state name (e.g.
-- "Yes", "Off") — reading these *keys* is object-model navigation, not
-- content-stream parsing (see module header); the streams those keys point
-- to are never opened here.
--: (FormDocument, { [string]: unknown }) -> { [string]: unknown } | nil
local function widget_appearance_states(doc, widget_dict)
	local ap = as_table(widget_dict.AP)
	if ap == nil then return nil end
	local n, err = pdf.resolve(doc, ap.N)
	if n == nil then return nil end
	local nt = as_table(n)
	if nt == nil then return nil end
	local _ = err
	return nt
end

--- Fill form fields with new values, producing the complete new file bytes
-- (original bytes plus one incremental update — see lib/pdf/write.lua). Does
-- not modify `doc.bytes` in place.
--
-- `values` maps a field's fully qualified name (dot-joined /T path, same
-- string `document_to_fields` reports as `name`) to a new value in the same
-- Lua representation lib/pdf/object.lua would parse it into: a plain string
-- for a text or choice field's /V, a Name-object table
-- `{ kind = "name", value = "Yes" }` (or, permissively, a bare string) for a
-- checkbox/radio-button state. Signature fields cannot be filled this way
-- (filling a signature means creating a cryptographic signature dictionary
-- and byte-range digest, out of scope here) and produce an error naming the
-- field.
--: (FormDocument, { [string]: unknown }) -> (string | nil, string | nil)
function M.fill_fields(doc, values)
	local fields, ferr = M.document_to_fields(doc)
	if fields == nil then return nil, ferr end

	-- Collect updated indirect objects, keyed by object number so a field
	-- touched by more than one requested value (shouldn't normally happen —
	-- `values` is keyed by name — but a field object also shared as its own
	-- widget must only be written once) and every affected widget dict
	-- collapse into a single write per object.
	local updates = {} --[[: { [integer]: { num: number, gen: number, dict: { [string]: unknown } } } ]]

	--: (number | nil, number | nil) -> ({ [string]: unknown } | nil, string | nil)
	local function fetch_dict(num, gen)
		if num == nil or gen == nil then return nil, "field is not backed by its own indirect object" end
		if updates[num] ~= nil then return updates[num].dict, nil end
		local obj, oerr = pdf.resolve_reference(doc, { kind = "reference", num = num, gen = gen })
		if obj == nil then return nil, oerr end
		local ot = as_table(obj)
		if ot == nil then return nil, "object " .. num .. " is not a dictionary" end
		local copy = {} --[[: { [string]: unknown } ]]
		for k, v in pairs(ot) do copy[k] = v end
		updates[num] = { num = num, gen = gen, dict = copy }
		return copy, nil
	end

	-- TYPECHECKER WORKAROUND: the natural way to change one field of a
	-- fetched dict would be direct mutation — `local d = fetch_dict(...); d.V
	-- = new_value` — reusing the same table across every requested value and
	-- widget update, same as `updates`'s cache already assumes. That direct
	-- mutation confirmed-repros a checker bug: once a table returned through
	-- an index-signature-typed (`{ [string]: unknown }`) return annotation
	-- has a field assigned to it *after* the return statement, the checker
	-- retroactively adds that field, at its literal (unwidened) value type,
	-- as a required field of the table's type at its point of origin — and
	-- this attaches to the underlying table object itself, not the
	-- reference/cast used to reach it, so even a fresh same-shape cast right
	-- before the assignment still fails. Minimal repro (no lib/pdf
	-- involvement): a local `make()` returning `({ [string]: unknown } |
	-- nil, string | nil)`; a separate `use()` calls it, then does `d.V = 42`
	-- — `make`'s own `return t, nil` then fails typecheck against `{ V: 42,
	-- [string]: unknown } | nil`, even though `--: (unknown) -> ...`/copy
	-- annotations never mentioned `V`. Root cause not investigated; matches
	-- the general shape of the "table-DAG-sharing" class already logged in
	-- this file's other typechecker-gap entries (a mutable table's inferred
	-- type is shared across every reference to it rather than scoped to the
	-- assignment's own control-flow point). Worked around by never mutating
	-- a fetched dict in place: `with_field` below always returns a *new*
	-- table (built fully within one function, no assignment surviving past
	-- its own return), and `apply_field` replaces `updates[num]` wholesale
	-- rather than mutating `.dict` on the existing entry. Revert to direct
	-- mutation once a table's row type is scoped to control flow instead of
	-- shared across every alias of the same value. See TODO.md.
	--: ({ [string]: unknown }, string, unknown) -> { [string]: unknown }
	local function with_field(dict, key, value)
		local out = {} --[[: { [string]: unknown } ]]
		for k, v in pairs(dict) do out[k] = v end
		out[key] = value
		return out
	end

	--: (number | nil, number | nil, string, unknown) -> string | nil
	local function apply_field(num, gen, key, value)
		if num == nil or gen == nil then return "field is not backed by its own indirect object" end
		local dict, err = fetch_dict(num, gen)
		if dict == nil then return err end
		updates[num] = { num = num, gen = gen, dict = with_field(dict, key, value) }
		return nil
	end

	for name, new_value in pairs(values) do
		local matches = fields_by_name(fields, name)
		if #matches == 0 then return nil, "no such field: " .. name end

		local first = matches[1]
		if first.type == "signature" then
			return nil, "field " .. name .. " is a signature field and cannot be filled"
		end

		local verr = apply_field(first.field_num, first.field_gen, "V", new_value)
		if verr ~= nil then return nil, "field " .. name .. ": " .. verr end

		if first.type == "checkbox" or first.type == "radio" then
			local wanted_state = state_name(new_value)
			if wanted_state == nil then
				return nil, "field " .. name .. ": checkbox/radio value must be a name or string state, got "
					.. type(new_value)
			end

			-- Re-fetch: now includes the /V just applied above.
			local field_dict, dict_err = fetch_dict(first.field_num, first.field_gen)
			if field_dict == nil then return nil, "field " .. name .. ": " .. tostring(dict_err) end

			-- Sets /AS to `wanted_state` if this widget's own /AP /N offers
			-- that appearance state, else "Off" (ISO 32000-1 §12.7.4.2.3 —
			-- a widget's /AS must name one of its own appearance states).
			--: (number | nil, number | nil, { [string]: unknown }) -> string | nil
			local function set_as(anum, agen, target_dict)
				local states = widget_appearance_states(doc, target_dict)
				local as_value = "Off"
				if states ~= nil and states[wanted_state] ~= nil then as_value = wanted_state end
				return apply_field(anum, agen, "AS", { kind = "name", value = as_value })
			end

			-- Merged field+widget (the common single-widget case): the
			-- field dict is itself the Widget annotation.
			if as_name(field_dict.Subtype) == "Widget" or field_dict.Rect ~= nil then
				local serr = set_as(first.field_num, first.field_gen, field_dict)
				if serr ~= nil then return nil, "field " .. name .. ": " .. serr end
			end

			-- Multi-widget case (radio groups; a checkbox repeated across
			-- pages): the field dict's own /Kids are separate widget
			-- objects, each needing its own /AS.
			local kids = as_array(field_dict.Kids)
			if kids ~= nil then
				local ki = 1
				while kids[ki] ~= nil do
					local kref = as_table(kids[ki])
					if kref ~= nil and kref.kind == "reference" then
						local knum = as_number(kref.num)
						local kgen = as_number(kref.gen)
						local kdict, kderr = fetch_dict(knum, kgen)
						if kdict == nil then return nil, "field " .. name .. ": " .. tostring(kderr) end
						local serr = set_as(knum, kgen, kdict)
						if serr ~= nil then return nil, "field " .. name .. ": " .. serr end
					end
					ki = ki + 1
				end
			end
		end
	end

	-- Best-effort /NeedAppearances: only when the AcroForm dictionary is
	-- itself an indirect object (the overwhelmingly common case) can this
	-- be set without also rewriting whatever object embeds it (the
	-- Catalog, if /AcroForm is inline there) — skip silently rather than
	-- error, since it's a rendering hint, not what makes the fill correct
	-- (the field's /V is already set above regardless).
	local root = as_table(pdf.document_root(doc))
	if root ~= nil and is_reference(root.AcroForm) then
		local aref = as_table(root.AcroForm)
		if aref ~= nil then
			local anum = as_number(aref.num)
			local agen = as_number(aref.gen)
			apply_field(anum, agen, "NeedAppearances", true)
		end
	end

	local n = 0
	for _ in pairs(updates) do n = n + 1 end
	if n == 0 then return nil, "no fields to fill" end

	local objects = {} --[[: { [integer]: { num: number, gen: number, value: unknown } } ]]
	for _, u in pairs(updates) do
		objects[#objects + 1] = { num = u.num, gen = u.gen, value = u.dict }
	end

	return pdf_write.write_incremental_update(doc, objects)
end

return M
