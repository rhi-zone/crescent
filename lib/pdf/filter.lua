-- lib/pdf/filter.lua
-- PDF stream filter decoding (ISO 32000-1 §7.4).
--
-- Shared by lib/pdf/xref.lua (cross-reference streams are PDF streams like
-- any other) and lib/pdf's top-level document resolver (any stream object —
-- content streams, image data, embedded files, ...). Given a stream's
-- dictionary and raw (still-encoded) bytes, applies /Filter and any
-- /DecodeParms /Predictor to recover the underlying data.
--
-- Only FlateDecode is supported (the overwhelmingly common filter in
-- practice); other filters return a clear error rather than silently
-- passing through undecoded bytes. Only the PNG predictor family
-- (/Predictor 10-15) is implemented; the TIFF predictor (/Predictor 2,
-- rare in practice) returns a clear "not yet implemented" error. Both are
-- documented gaps, not silent mishandling — see TODO.md.
--
-- Errors: `(nil, errmsg)`, per docs/conventions.md.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local ok_compress, compress_mod = pcall(require, "lib.compress")

local M = {}
M._tier = "pure"

local floor = math.floor

-- TYPECHECKER WORKAROUND: calling string.byte's overloaded (intersection)
-- signature directly and using the result in a comparison inside a loop with
-- `break` spuriously narrows the result to `never` instead of `integer | nil`
-- — see TODO.md ("found while implementing lib/pdf/xref.lua"). Wrapping it in
-- a local single-signature function avoids the overload resolver entirely.
--: (string, integer) -> integer | nil
local function byte(s, pos)
	return string.byte(s, pos)
end

-- ── Narrowing helpers over `unknown` PDF values ──────────────────────────────
-- Mirrors the pattern lib/pdf/object_test.lua and lib/pdf/xref.lua use.

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

--: (unknown) -> integer | nil
local function as_integer(v)
	local n = as_number(v)
	if n == nil then return nil end
	return floor(n)
end

--: (unknown) -> { [integer]: unknown } | nil
local function as_array(v)
	-- Arrays and dictionaries are both plain, untagged tables in
	-- lib/pdf/object.lua's representation; /Filter and /DecodeParms are
	-- spec-mandated to be arrays (when in array form), so there's no
	-- separate discriminator to check here.
	return as_table(v)
end

-- ── PNG predictor un-filtering (used by /DecodeParms /Predictor 10-15) ──────
-- Same algorithm PNG scanline filtering uses (lib/png does not implement
-- this — it passes IDAT through opaquely — so this is not a duplicate of
-- existing code). Needed because FlateDecode+Predictor is the overwhelmingly
-- common encoding real-world PDF producers use; without it, affected streams
-- would decode to structured garbage instead of correct data or a clear error.

--: (integer | nil) -> integer
local function or_zero(v)
	if v == nil then return 0 end
	return v
end

--: (integer, integer, integer) -> integer
local function paeth_predictor(a, b, c)
	local p = a + b - c
	local pa, pb, pc = math.abs(p - a), math.abs(p - b), math.abs(p - c)
	if pa <= pb and pa <= pc then return a end
	if pb <= pc then return b end
	return c
end

--: (string, integer, integer) -> (string | nil, string | nil)
local function png_unfilter(data, row_bytes, bpp)
	local out = {}
	local prior = string.rep("\0", row_bytes)
	local stride = row_bytes + 1
	local n = #data
	local pos = 1
	while pos + stride - 1 <= n do
		local filter_type = byte(data, pos)
		local row = {} --[[: { [integer]: integer } ]]
		for x = 1, row_bytes do
			local raw = byte(data, pos + x)
			if raw == nil then return nil, "truncated PNG-filtered row" end

			local a = 0
			if x > bpp then a = or_zero(row[x - bpp]) end
			local b = or_zero(byte(prior, x))
			local c = 0
			if x > bpp then c = or_zero(byte(prior, x - bpp)) end

			local recon
			if filter_type == 0 then
				recon = raw
			elseif filter_type == 1 then
				recon = raw + a
			elseif filter_type == 2 then
				recon = raw + b
			elseif filter_type == 3 then
				recon = raw + floor((a + b) / 2)
			elseif filter_type == 4 then
				recon = raw + paeth_predictor(a, b, c)
			else
				return nil, "unsupported PNG filter type byte: " .. tostring(filter_type)
			end
			row[x] = recon % 256
		end
		local row_str = string.char(unpack(row, 1, row_bytes))
		out[#out + 1] = row_str
		prior = row_str
		pos = pos + stride
	end
	return table.concat(out), nil
end

-- ── Predictor dispatch ───────────────────────────────────────────────────────

--: (unknown) -> integer
-- Reads /Predictor from a /DecodeParms dictionary (default 1, meaning "no
-- predictor" per ISO 32000-1 Table 8).
local function read_predictor(decode_parms)
	local dp = as_table(decode_parms)
	if dp == nil then return 1 end
	local predictor = as_integer(dp.Predictor)
	if predictor == nil then return 1 end
	return predictor
end

--: (unknown, string, integer) -> (string | nil, string | nil)
-- `default_columns` is the un-predicted row width to fall back on when
-- /DecodeParms /Columns is absent (xref streams: their row width; other
-- streams should always specify /Columns, but this keeps the function total).
local function apply_predictor(decode_parms, data, default_columns)
	local predictor = read_predictor(decode_parms)
	if predictor == 1 then return data, nil end
	if predictor == 2 then
		return nil, "TIFF predictor (/Predictor 2) is not yet implemented"
	end
	if predictor < 10 or predictor > 15 then
		return nil, "unsupported /Predictor value: " .. tostring(predictor)
	end

	local dp = as_table(decode_parms)
	local columns = default_columns
	local colors = 1
	local bpc = 8
	if dp ~= nil then
		local cols = as_integer(dp.Columns)
		if cols ~= nil then columns = cols end
		local c = as_integer(dp.Colors)
		if c ~= nil then colors = c end
		local b = as_integer(dp.BitsPerComponent)
		if b ~= nil then bpc = b end
	end
	local bpp = math.max(1, math.ceil(colors * bpc / 8))
	return png_unfilter(data, columns, bpp)
end

-- ── Public API ───────────────────────────────────────────────────────────────

--- Decode a stream's raw bytes per its dictionary's /Filter and /DecodeParms.
-- `default_columns` (optional) sets the predictor row width to use when
-- /DecodeParms /Columns is absent — callers that know the natural row width
-- of their data (e.g. lib/pdf/xref.lua, whose rows are /W-width fixed
-- records) should pass it; general callers can omit it (defaults to the
-- full data length, i.e. one row) since general streams should carry /Columns.
--: (unknown, string, integer | nil) -> (string | nil, string | nil)
function M.decode_stream(dict, raw_data, default_columns)
	local d = as_table(dict)
	if d == nil then return nil, "stream dictionary is not a dictionary" end

	local filter_name = as_name(d.Filter)
	if filter_name == nil and d.Filter ~= nil then
		local filter_arr = as_array(d.Filter)
		if filter_arr ~= nil and filter_arr[1] ~= nil and filter_arr[2] == nil then
			filter_name = as_name(filter_arr[1])
		end
		if filter_name == nil then
			-- /Filter is present but isn't a name or a single-name array —
			-- e.g. an unresolved indirect reference (rare but spec-legal;
			-- resolving it needs xref access this module doesn't have) or a
			-- multi-filter chain (not implemented). Either way, silently
			-- treating the data as unfiltered would be a correctness bug,
			-- not graceful degradation.
			return nil, "unsupported /Filter value (not a name, not a single-name array — "
				.. "possibly an unresolved indirect reference or an unsupported multi-filter chain)"
		end
	end

	local data = raw_data
	if filter_name == "FlateDecode" then
		if not ok_compress then
			return nil, "stream uses FlateDecode but lib/compress is unavailable"
		end
		local inflated, ierr = compress_mod.inflate(raw_data)
		if inflated == nil then return nil, "failed to inflate stream: " .. tostring(ierr) end
		data = inflated
	elseif filter_name ~= nil then
		return nil, "unsupported stream filter: " .. filter_name
	end

	local decode_parms = d.DecodeParms
	if decode_parms == nil then decode_parms = d.DP end
	return apply_predictor(decode_parms, data, default_columns or #data)
end

return M
