if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

--:: CsvAgg = { init: () -> unknown, step: (unknown, { [string]: unknown, ... }) -> nil, final: (unknown) -> unknown, ... }

-- ── CSV Parsing ────────────────────────────────────────────────────────────────

--- Parse a CSV string into an array of row tables keyed by header.
-- Handles quoted fields, embedded commas, embedded newlines, and escaped quotes ("").
-- @param str string  CSV content
-- @return table[]    array of {header=value} tables, or (nil, errmsg)
function M.parse(str)
	if type(str) ~= "string" then
		return nil, "csv_transform.parse: expected string, got " .. type(str)
	end

	-- Tokenise into rows of fields
	local rows = {} --: { [integer]: { [integer]: string } }
	local cur_row = {} --: { [integer]: string }
	local field_buf = {}
	local i = 1
	local n = #str
	local in_quote = false

	local function flush_field()
		cur_row[#cur_row + 1] = table.concat(field_buf)
		field_buf = {}
	end

	local function flush_row()
		flush_field()
		rows[#rows + 1] = cur_row
		cur_row = {} --: { [integer]: string }
	end

	while i <= n do
		local c = str:sub(i, i)
		if in_quote then
			if c == '"' then
				local next_c = str:sub(i + 1, i + 1)
				if next_c == '"' then
					-- escaped quote
					field_buf[#field_buf + 1] = '"'
					i = i + 2
				else
					-- closing quote
					in_quote = false
					i = i + 1
				end
			else
				field_buf[#field_buf + 1] = c
				i = i + 1
			end
		else
			if c == '"' then
				in_quote = true
				i = i + 1
			elseif c == ',' then
				flush_field()
				i = i + 1
			elseif c == '\r' then
				-- handle \r\n or lone \r
				flush_row()
				if str:sub(i + 1, i + 1) == '\n' then
					i = i + 2
				else
					i = i + 1
				end
			elseif c == '\n' then
				flush_row()
				i = i + 1
			else
				field_buf[#field_buf + 1] = c
				i = i + 1
			end
		end
	end

	-- flush last field/row if there's remaining content
	if #field_buf > 0 or #cur_row > 0 then
		flush_row()
	end

	if #rows == 0 then
		return {}
	end

	local headers = rows[1]
	local result = {}
	for r = 2, #rows do
		local raw = rows[r]
		-- skip completely empty trailing rows
		if #raw == 1 and raw[1] == "" then
			-- skip
		else
			local record = {}
			for h = 1, #headers do
				record[headers[h]] = raw[h] or ""
			end
			result[#result + 1] = record
		end
	end
	return result
end

-- ── CSV Serialization ──────────────────────────────────────────────────────────

--- Escape a field value for CSV output.
local function escape_field(v)
	v = tostring(v)
	if v:find('[",\r\n]') then
		local escaped = v:gsub('"', '""') --: string
		return '"' .. escaped .. '"'
	end
	return v
end

--- Serialize an array of row tables to a CSV string.
-- @param rows   table[]    array of row tables
-- @param headers string[]  column order (required)
-- @return string
function M.serialize(rows, headers)
	if type(rows) ~= "table" then
		return nil, "csv_transform.serialize: expected table for rows"
	end
	if type(headers) ~= "table" then
		return nil, "csv_transform.serialize: expected table for headers"
	end
	local lines = {}
	-- header line
	local hparts = {}
	for _, h in ipairs(headers) do
		hparts[#hparts + 1] = escape_field(h)
	end
	lines[#lines + 1] = table.concat(hparts, ",")
	-- data lines
	for _, row in ipairs(rows) do
		local parts = {}
		for _, h in ipairs(headers) do
			parts[#parts + 1] = escape_field(row[h] ~= nil and row[h] or "")
		end
		lines[#lines + 1] = table.concat(parts, ",")
	end
	return table.concat(lines, "\n") .. "\n"
end

-- ── Aggregator factories ───────────────────────────────────────────────────────

--- Aggregator: count rows in group.
function M.count()
	return {
		_type = "agg",
		init = function() return { n = 0 } end,
		step = function(acc, _row) acc.n = acc.n + 1 end,
		final = function(acc) return acc.n end,
	}
end

--- Aggregator: sum of numeric column.
function M.sum(col)
	return {
		_type = "agg",
		init = function() return { s = 0 } end,
		step = function(acc, row) acc.s = acc.s + (tonumber(row[col]) or 0) end,
		final = function(acc) return acc.s end,
	}
end

--- Aggregator: average of numeric column.
function M.avg(col)
	return {
		_type = "agg",
		init = function() return { s = 0, n = 0 } end,
		--: ({ s: number, n: number, ... }, { [string]: unknown, ... }) -> nil
		step = function(acc, row)
			acc.s = acc.s + (tonumber(row[col]) or 0)
			acc.n = acc.n + 1
		end,
		--: ({ s: number, n: number, ... }) -> number | nil
		final = function(acc)
			if acc.n == 0 then return nil end
			return acc.s / acc.n
		end,
	}
end

--- Aggregator: minimum numeric value.
function M.min(col)
	return {
		_type = "agg",
		init = function() return { v = nil } end,
		step = function(acc, row)
			local v = tonumber(row[col])
			if v ~= nil and (acc.v == nil or v < acc.v) then acc.v = v end
		end,
		final = function(acc) return acc.v end,
	}
end

--- Aggregator: maximum numeric value.
function M.max(col)
	return {
		_type = "agg",
		init = function() return { v = nil } end,
		step = function(acc, row)
			local v = tonumber(row[col])
			if v ~= nil and (acc.v == nil or v > acc.v) then acc.v = v end
		end,
		final = function(acc) return acc.v end,
	}
end

--- Aggregator: first value in group.
function M.first(col)
	return {
		_type = "agg",
		init = function() return { v = nil, seen = false } end,
		step = function(acc, row)
			if not acc.seen then
				acc.v = row[col]
				acc.seen = true
			end
		end,
		final = function(acc) return acc.v end,
	}
end

--- Aggregator: last value in group.
function M.last(col)
	return {
		_type = "agg",
		init = function() return { v = nil } end,
		step = function(acc, row) acc.v = row[col] end,
		final = function(acc) return acc.v end,
	}
end

--- Aggregator: collect all values in group into an array.
function M.collect(col)
	return {
		_type = "agg",
		init = function() return { vs = {} } end,
		step = function(acc, row)
			acc.vs[#acc.vs + 1] = row[col]
		end,
		final = function(acc) return acc.vs end,
	}
end

-- ── Pipeline ───────────────────────────────────────────────────────────────────

--- Deep-copy a row (shallow copy of key-value pairs).
local function copy_row(row)
	local r = {}
	for k, v in pairs(row) do r[k] = v end
	return r
end

local Pipeline = {}
Pipeline.__index = Pipeline

--- Create a new pipeline from an array of rows (copied).
function M.from(rows)
	local data = {}
	for i = 1, #rows do
		data[i] = copy_row(rows[i])
	end
	local self = setmetatable({}, Pipeline)
	self._data = data
	self._group_key = nil  -- set by group_by
	self._groups = nil     -- set by group_by
	return self
end

--- Keep only specified columns.
function Pipeline:select(cols)
	local data = self._data
	local out = {}
	for i = 1, #data do
		local row = data[i]
		local r = {}
		for _, c in ipairs(cols) do
			r[c] = row[c]
		end
		out[i] = r
	end
	self._data = out
	return self
end

--- Rename columns. mapping is {old_name = new_name}.
function Pipeline:rename(mapping)
	local data = self._data
	for i = 1, #data do
		local row = data[i]
		for old, new in pairs(mapping) do
			if row[old] ~= nil then
				row[new] = row[old]
				row[old] = nil
			end
		end
	end
	return self
end

--- Cast column values using provided functions. casts is {col = fn}.
function Pipeline:cast(casts)
	local data = self._data
	for i = 1, #data do
		local row = data[i]
		for col, fn in pairs(casts) do
			if row[col] ~= nil then
				row[col] = fn(row[col])
			end
		end
	end
	return self
end

--- Keep rows matching predicate.
function Pipeline:filter(pred)
	local data = self._data
	local out = {}
	for i = 1, #data do
		if pred(data[i]) then
			out[#out + 1] = data[i]
		end
	end
	self._data = out
	return self
end

--- Transform each row with fn. fn receives a copy and must return the row.
function Pipeline:map(fn)
	local data = self._data
	for i = 1, #data do
		data[i] = fn(data[i])
	end
	return self
end

--- Sort by a column. direction is "asc" (default) or "desc".
function Pipeline:sort(col, direction)
	local desc = direction == "desc"
	table.sort(self._data, function(a, b)
		local av = tonumber(a[col]) or a[col]
		local bv = tonumber(b[col]) or b[col]
		if desc then
			return av > bv
		else
			return av < bv
		end
	end)
	return self
end

--- Keep at most n rows.
function Pipeline:limit(n)
	local data = self._data
	if #data > n then
		local out = {}
		for i = 1, n do out[i] = data[i] end
		self._data = out
	end
	return self
end

--- Add a computed column. fn receives the row, returns the value.
function Pipeline:add_column(name, fn)
	local data = self._data
	for i = 1, #data do
		data[i][name] = fn(data[i])
	end
	return self
end

--- Keep only rows with distinct values for the given column.
function Pipeline:distinct(col)
	local seen = {}
	local out = {}
	local data = self._data
	for i = 1, #data do
		local v = data[i][col]
		if not seen[v] then
			seen[v] = true
			out[#out + 1] = data[i]
		end
	end
	self._data = out
	return self
end

--- Expand rows where a column contains sep-separated multi-values into multiple rows.
function Pipeline:explode(col, sep)
	local sep = (sep or ",") --: string
	local out = {}
	local data = self._data
	for i = 1, #data do
		local row = data[i]
		local val = row[col] --[[:! string | nil]]
		if val ~= nil and val ~= "" then
			-- split by sep
			local parts = {}
			local sep_esc = sep:gsub("[%(%)%.%%%+%-%*%?%[%^%$]", "%%%1") --: string
			local pat = "([^" .. sep_esc .. "]*)"
			for part in (val .. sep):gmatch(pat .. sep_esc) do
				parts[#parts + 1] = part
			end
			if #parts == 0 then
				out[#out + 1] = row
			else
				for _, part in ipairs(parts) do
					local r = copy_row(row)
					r[col] = part
					out[#out + 1] = r
				end
			end
		else
			out[#out + 1] = row
		end
	end
	self._data = out
	return self
end

--- Group rows by a column. Returns self (with group state set for :agg()).
function Pipeline:group_by(col)
	self._group_key = col
	local order = {}
	local groups = {}
	local data = self._data
	for i = 1, #data do
		local row = data[i]
		local k = row[col]
		if not groups[k] then
			groups[k] = {}
			order[#order + 1] = k
		end
		groups[k][#groups[k] + 1] = row
	end
	self._groups = groups
	self._group_order = order
	return self
end

--- Aggregate grouped data. spec is {output_col = aggregator}.
-- Must be called after group_by().
function Pipeline:agg(spec)
	if not self._groups then
		error("csv_transform: agg() called without group_by()")
	end
	local out = {}
	for _, key in ipairs(self._group_order) do
		local grp = self._groups[key]
		-- initialise accumulators
		local accs = {}
		for out_col, agg in pairs(spec) do
			accs[out_col] = agg.init()
		end
		-- step each row
		for _, row in ipairs(grp) do
			for out_col, agg in pairs(spec) do
				agg.step(accs[out_col], row)
			end
		end
		-- finalise
		local record = { [self._group_key] = key }
		for out_col, agg in pairs(spec) do
			record[out_col] = agg.final(accs[out_col])
		end
		out[#out + 1] = record
	end
	self._data = out
	self._groups = nil
	self._group_key = nil
	self._group_order = nil
	return self
end

--- Inner join with another array of rows on matching columns.
-- @param other      table[]   right-hand rows
-- @param left_col   string    column name in current pipeline rows
-- @param right_col  string    column name in other rows
function Pipeline:join(other, left_col, right_col)
	-- build hash index on right side
	local index = {}
	for i = 1, #other do
		local k = other[i][right_col]
		if k ~= nil then
			if not index[k] then index[k] = {} end
			index[k][#index[k] + 1] = other[i]
		end
	end
	local out = {}
	local data = self._data
	for i = 1, #data do
		local row = data[i]
		local k = row[left_col]
		local matches = index[k]
		if matches then
			for _, right_row in ipairs(matches) do
				local r = copy_row(row)
				for rk, rv in pairs(right_row) do
					if r[rk] == nil then
						r[rk] = rv
					end
				end
				out[#out + 1] = r
			end
		end
	end
	self._data = out
	return self
end

--- Pivot table: rows become column values for pivot_col, values are aggregated.
-- @param pivot_col  string    column whose distinct values become new columns
-- @param value_col  string    column to aggregate
-- @param agg        aggregator  how to aggregate value_col per cell
-- Other non-pivot, non-value columns are used as the row identity.
function Pipeline:pivot(pivot_col, value_col, agg)
	local agg = agg
	-- collect distinct pivot values and row keys
	local pivot_vals = {}
	local pivot_seen = {}
	local data = self._data
	for i = 1, #data do
		local pv = data[i][pivot_col]
		if not pivot_seen[pv] then
			pivot_seen[pv] = true
			pivot_vals[#pivot_vals + 1] = pv
		end
	end
	table.sort(pivot_vals, function(a, b) return tostring(a) < tostring(b) end)

	-- determine identity columns (everything except pivot_col and value_col)
	local id_cols = {} --: { [integer]: string }
	if #data > 0 then
		for k in pairs(data[1]) do
			local col_name = k --[[:! string]]
			if col_name ~= pivot_col and col_name ~= value_col then
				id_cols[#id_cols + 1] = col_name
			end
		end
		table.sort(id_cols)
	end

	-- build row key
	local function row_key(row)
		local parts = {}
		for _, c in ipairs(id_cols) do
			parts[#parts + 1] = tostring(row[c] or "")
		end
		return table.concat(parts, "\0")
	end

	local order = {}
	local cells = {}  -- key -> {pv -> acc}
	local key_rows = {}  -- key -> identity fields

	for i = 1, #data do
		local row = data[i]
		local k = row_key(row)
		local pv = row[pivot_col]
		if not cells[k] then
			cells[k] = {}
			order[#order + 1] = k
			local r = {}
			for _, c in ipairs(id_cols) do r[c] = row[c] end
			key_rows[k] = r
		end
		if not cells[k][pv] then
			cells[k][pv] = agg.init()
		end
		agg.step(cells[k][pv], row)
	end

	local out = {}
	for _, k in ipairs(order) do
		local record = key_rows[k]
		for _, pv in ipairs(pivot_vals) do
			local acc = cells[k][pv]
			record[pv] = acc and agg.final(acc) or nil
		end
		out[#out + 1] = record
	end
	self._data = out
	return self
end

--- Compute descriptive statistics for a numeric column.
-- Returns {count, mean, std, min, p25, p50, p75, max}.
function Pipeline:describe(col)
	local data = self._data
	local vals = {}
	for i = 1, #data do
		local v = tonumber(data[i][col])
		if v ~= nil then
			vals[#vals + 1] = v
		end
	end
	local n = #vals
	if n == 0 then
		return { count = 0, mean = nil, std = nil, min = nil, p25 = nil, p50 = nil, p75 = nil, max = nil }
	end
	table.sort(vals)
	local sum = 0 --: number
	for _, v in ipairs(vals) do sum = sum + v end
	local mean = sum / n
	local sq_sum = 0 --: number
	for _, v in ipairs(vals) do sq_sum = sq_sum + (v - mean) ^ 2 end
	local std = n > 1 and math.sqrt(sq_sum / (n - 1)) or 0

	local function percentile(p)
		local idx = p * (n - 1) + 1
		local lo = math.floor(idx)
		local hi = math.ceil(idx)
		if lo == hi then return vals[lo] end
		local frac = idx - lo
		return vals[lo] * (1 - frac) + vals[hi] * frac
	end

	return {
		count = n,
		mean  = mean,
		std   = std,
		min   = vals[1],
		p25   = percentile(0.25),
		p50   = percentile(0.50),
		p75   = percentile(0.75),
		max   = vals[n],
	}
end

--- Materialize the pipeline into an array.
function Pipeline:to_array()
	return self._data
end

return M
