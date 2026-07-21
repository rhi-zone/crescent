-- lib/pdf/init.lua
-- PDF document loading: entry point tying lib/pdf/object.lua (object-model
-- parser), lib/pdf/xref.lua (cross-reference table), and lib/pdf/filter.lua
-- (stream decompression) together into "load a file, resolve its objects."
--
-- This is the shared foundation both a forms-extraction path and a
-- text-extraction path need — it stops at object/xref/stream resolution.
-- Content stream parsing (text operators, graphics), font handling, and
-- form field extraction are explicitly out of scope here; they're built on
-- top of this, not in it.
--
-- Errors: `(nil, errmsg)`, per docs/conventions.md.

if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local pdf_object = require("lib.pdf.object")
local pdf_xref = require("lib.pdf.xref")
local pdf_filter = require("lib.pdf.filter")

local M = {}
M._tier = "pure"

-- Re-export the pieces this module composes, so a caller only needs
-- `require("lib.pdf")` for the common case.
M.object = pdf_object
M.xref = pdf_xref
M.filter = pdf_filter
M.null = pdf_object.null

--:: Document = { bytes: string, entries: unknown, trailer: unknown }

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

--- Load a PDF file's bytes: locate and parse its cross-reference table
-- (following /Prev and /XRefStm chains), returning a Document that
-- M.resolve/M.stream_to_bytes/M.document_root operate on.
--: (string) -> (Document | nil, string | nil)
function M.string_to_document(bytes)
	local xt, err = pdf_xref.build(bytes)
	if xt == nil then return nil, err end
	local xtt = as_table(xt)
	if xtt == nil then return nil, "malformed xref table" end
	return { bytes = bytes, entries = xtt.entries, trailer = xtt.trailer }, nil
end

--- Resolve an indirect reference `{ kind = "reference", num, gen }` to its
-- underlying object. Errors clearly (rather than resolving incorrectly) for
-- an object marked free in the xref table, an object whose xref entry
-- points past the end of the file, or an object stored inside an Object
-- Stream (xref entry type 2 — resolving those needs a not-yet-built ObjStm
-- parser; see TODO.md).
--: (Document, unknown) -> (unknown, string | nil)
function M.resolve_reference(doc, ref)
	local r = as_table(ref)
	if r == nil then return nil, "not a reference" end
	local num = as_number(r.num)
	if num == nil then return nil, "reference has no object number" end

	local entries = as_table(doc.entries)
	if entries == nil then return nil, "document has no xref entries" end
	local entry = as_table(entries[num])
	if entry == nil then
		return nil, "object " .. num .. " is not present in the xref table"
	end

	if entry.kind == "free" then
		return nil, "object " .. num .. " is marked free (does not exist)"
	elseif entry.kind == "compressed" then
		return nil, "object " .. num .. " is stored in an Object Stream (ObjStm); "
			.. "resolving compressed objects is not yet implemented"
	elseif entry.kind ~= "in_use" then
		return nil, "object " .. num .. " has an unrecognized xref entry kind"
	end

	local offset = as_number(entry.offset)
	if offset == nil then return nil, "object " .. num .. "'s xref entry has no offset" end

	local bytes = doc.bytes
	if type(bytes) ~= "string" then return nil, "document has no source bytes" end

	--: (unknown) -> (number | nil)
	-- Bridges lib/pdf/object.lua's stream parser to this document's xref
	-- table when a stream's /Length is itself an indirect reference.
	local function resolve_length(length_ref)
		local v = M.resolve_reference(doc, length_ref)
		if type(v) == "number" then return v end
		return nil
	end

	local indirect, ierr =
		pdf_object.string_to_indirect_object(bytes, math.floor(offset) + 1, { resolve_length = resolve_length })
	if indirect == nil then return nil, "failed to parse object " .. num .. ": " .. tostring(ierr) end
	local iv = as_table(indirect)
	if iv == nil then return nil, "malformed indirect object" end
	local found_num = as_number(iv.num)
	if found_num ~= num then
		return nil, "xref offset for object " .. num .. " points at object " .. tostring(found_num) .. " instead"
	end
	return iv.value, nil
end

--- Resolve `v` if it's an indirect reference; otherwise return it unchanged.
-- The ergonomic function most callers want: "give me this dictionary
-- entry's real value, whether it was stored directly or by reference."
--: (Document, unknown) -> (unknown, string | nil)
function M.resolve(doc, v)
	local t = as_table(v)
	if t ~= nil and t.kind == "reference" then
		return M.resolve_reference(doc, v)
	end
	return v, nil
end

--- Resolve the document's trailer /Root entry (the document catalog).
--: (Document) -> (unknown, string | nil)
function M.document_root(doc)
	local trailer = as_table(doc.trailer)
	if trailer == nil then return nil, "document has no trailer" end
	if trailer.Root == nil then return nil, "trailer has no /Root entry" end
	return M.resolve(doc, trailer.Root)
end

--- Decode a stream object's data per its dictionary's /Filter and
-- /DecodeParms. A thin pass-through to lib/pdf/filter.lua — kept here too
-- since "decode this stream I just resolved" is the natural call from a
-- document, and callers of lib/pdf shouldn't need to know filter.lua exists.
--: (unknown) -> (string | nil, string | nil)
function M.stream_to_bytes(stream)
	local st = as_table(stream)
	if st == nil or st.kind ~= "stream" then return nil, "not a stream object" end
	local data = st.data
	if type(data) ~= "string" then return nil, "stream has no data" end
	return pdf_filter.decode_stream(st.dict, data)
end

return M
