-- lib/csv_query/init.lua
-- SQL-like query engine for in-memory tabular data.
-- Pure Lua — no dependencies beyond optional lib/csv for CSV I/O.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local concat, insert, sort = table.concat, table.insert, table.sort
local floor, sqrt = math.floor, math.sqrt

-- ---------------------------------------------------------------------------
-- Optional lib/csv integration
-- ---------------------------------------------------------------------------

local csv_ok, csv = pcall(require, "lib.csv")
if not csv_ok then csv = nil end

-- ---------------------------------------------------------------------------
-- DataFrame metatable
-- ---------------------------------------------------------------------------

local DataFrame = {}
DataFrame.__index = DataFrame

local function new_df(rows, cols)
  -- cols: ordered array of column names (may be nil — will be derived)
  if not cols then
    -- Derive columns from first row
    cols = {}
    local seen = {}
    for _, row in ipairs(rows) do
      for k in pairs(row) do
        if not seen[k] then
          seen[k] = true
          insert(cols, k)
        end
      end
    end
    sort(cols)
  end
  return setmetatable({ _rows = rows, _cols = cols }, DataFrame)
end

-- ---------------------------------------------------------------------------
-- Constructors
-- ---------------------------------------------------------------------------

--- Load from CSV string. Returns df, err.
function M.from_csv(csv_string)
  if type(csv_string) ~= "string" then
    return nil, "from_csv: expected string"
  end
  local rows, err
  if csv then
    rows, err = csv.decode(csv_string, { headers = true, coerce = true })
    if not rows then return nil, err end
  else
    -- Built-in minimal CSV parser (no quoting support)
    rows = {}
    local headers = nil
    for line in (csv_string .. "\n"):gmatch("([^\r\n]*)\r?\n") do
      if #line > 0 then
        local fields = {}
        for field in (line .. ","):gmatch("([^,]*),") do
          local n = tonumber(field)
          insert(fields, n ~= nil and n or field)
        end
        if not headers then
          headers = fields
        else
          local row = {}
          for i, h in ipairs(headers) do
            row[h] = fields[i]
          end
          insert(rows, row)
        end
      end
    end
  end
  -- Derive columns from header order (use first row's keys if no headers array)
  local cols
  if csv and rows and rows[1] then
    -- We need to get header order — re-parse first line
    local first_line = csv_string:match("^([^\r\n]+)")
    if first_line then
      cols = {}
      for field in (first_line .. ","):gmatch("([^,]*),") do
        local f = field:match("^%s*(.-)%s*$")
        insert(cols, f)
      end
    end
  end
  return new_df(rows, cols)
end

--- Load from array of row tables: [{col=val, ...}, ...]
function M.from_rows(rows)
  local copy = {}
  for i, row in ipairs(rows) do
    local r = {}
    for k, v in pairs(row) do r[k] = v end
    copy[i] = r
  end
  return new_df(copy)
end

--- Load from array of arrays + column names.
--- arrays: [[v1, v2, ...], [v1, v2, ...], ...]
--- columns: ["col1", "col2", ...]
function M.from_arrays(arrays, columns)
  local rows = {}
  for i, arr in ipairs(arrays) do
    local row = {}
    for j, col in ipairs(columns) do
      row[col] = arr[j]
    end
    rows[i] = row
  end
  return new_df(rows, { unpack(columns) })
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function copy_cols(cols)
  local c = {}
  for i, v in ipairs(cols) do c[i] = v end
  return c
end

local function copy_row(row)
  local r = {}
  for k, v in pairs(row) do r[k] = v end
  return r
end

-- ---------------------------------------------------------------------------
-- SELECT
-- ---------------------------------------------------------------------------

function DataFrame:select(...)
  local wanted = { ... }
  -- Build set for fast lookup
  local want_set = {}
  for _, c in ipairs(wanted) do want_set[c] = true end
  local rows = {}
  for i, row in ipairs(self._rows) do
    local r = {}
    for _, c in ipairs(wanted) do
      r[c] = row[c]
    end
    rows[i] = r
  end
  return new_df(rows, copy_cols(wanted))
end

-- ---------------------------------------------------------------------------
-- WHERE
-- ---------------------------------------------------------------------------

function DataFrame:where(predicate)
  local rows = {}
  for _, row in ipairs(self._rows) do
    if predicate(row) then
      insert(rows, copy_row(row))
    end
  end
  return new_df(rows, copy_cols(self._cols))
end

-- ---------------------------------------------------------------------------
-- ORDER BY
-- ---------------------------------------------------------------------------

function DataFrame:order_by(key, dir)
  dir = dir or "asc"
  local rows = {}
  for i, row in ipairs(self._rows) do
    rows[i] = copy_row(row)
  end
  local get_key
  if type(key) == "function" then
    get_key = key
  else
    get_key = function(row) return row[key] end
  end
  sort(rows, function(a, b)
    local ka, kb = get_key(a), get_key(b)
    if ka == nil and kb == nil then return false end
    if ka == nil then return dir == "asc" end
    if kb == nil then return dir == "desc" end
    if dir == "asc" then return ka < kb else return ka > kb end
  end)
  return new_df(rows, copy_cols(self._cols))
end

-- ---------------------------------------------------------------------------
-- LIMIT / OFFSET
-- ---------------------------------------------------------------------------

function DataFrame:limit(n)
  local rows = {}
  local src = self._rows
  for i = 1, math.min(n, #src) do
    rows[i] = copy_row(src[i])
  end
  return new_df(rows, copy_cols(self._cols))
end

function DataFrame:offset(n)
  local rows = {}
  local src = self._rows
  for i = n + 1, #src do
    insert(rows, copy_row(src[i]))
  end
  return new_df(rows, copy_cols(self._cols))
end

-- ---------------------------------------------------------------------------
-- GROUP BY + aggregation
-- ---------------------------------------------------------------------------

local function apply_agg(group_rows, fn_name, source_col)
  if fn_name == "count" then
    return #group_rows
  end
  local vals = {}
  for _, row in ipairs(group_rows) do
    local v = source_col and row[source_col] or nil
    if v ~= nil then insert(vals, v) end
  end
  if fn_name == "sum" then
    local s = 0
    for _, v in ipairs(vals) do s = s + v end
    return s
  elseif fn_name == "min" then
    if #vals == 0 then return nil end
    local m = vals[1]
    for i = 2, #vals do if vals[i] < m then m = vals[i] end end
    return m
  elseif fn_name == "max" then
    if #vals == 0 then return nil end
    local m = vals[1]
    for i = 2, #vals do if vals[i] > m then m = vals[i] end end
    return m
  elseif fn_name == "avg" then
    if #vals == 0 then return nil end
    local s = 0
    for _, v in ipairs(vals) do s = s + v end
    return s / #vals
  elseif fn_name == "first" then
    return vals[1]
  elseif fn_name == "last" then
    return vals[#vals]
  end
  return nil
end

function DataFrame:group_by(groups, aggregates)
  -- Normalize groups to array
  local group_cols
  if type(groups) == "string" then
    group_cols = { groups }
  else
    group_cols = groups
  end

  -- Build group key → rows mapping (preserve insertion order)
  local group_map = {}   -- key_str → {rows, key_vals}
  local group_order = {} -- ordered list of key_strs

  for _, row in ipairs(self._rows) do
    local parts = {}
    for _, col in ipairs(group_cols) do
      insert(parts, tostring(row[col] ~= nil and row[col] or ""))
    end
    local key_str = concat(parts, "\0")
    if not group_map[key_str] then
      group_map[key_str] = { rows = {}, key_vals = {} }
      for _, col in ipairs(group_cols) do
        group_map[key_str].key_vals[col] = row[col]
      end
      insert(group_order, key_str)
    end
    insert(group_map[key_str].rows, row)
  end

  -- Build result rows and determine output columns
  local result = {}
  local out_cols = copy_cols(group_cols)
  -- Collect aggregate output col names in deterministic order
  local agg_col_names = {}
  if aggregates then
    local sorted = {}
    for out_col in pairs(aggregates) do insert(sorted, out_col) end
    sort(sorted)
    agg_col_names = sorted
    for _, oc in ipairs(agg_col_names) do insert(out_cols, oc) end
  end

  for _, key_str in ipairs(group_order) do
    local info = group_map[key_str]
    local new_row = {}
    -- Copy group-by column values
    for _, col in ipairs(group_cols) do
      new_row[col] = info.key_vals[col]
    end
    -- Apply aggregates
    if aggregates then
      for _, out_col in ipairs(agg_col_names) do
        local spec = aggregates[out_col]
        new_row[out_col] = apply_agg(info.rows, spec[1], spec[2])
      end
    end
    insert(result, new_row)
  end

  return new_df(result, out_cols)
end

-- ---------------------------------------------------------------------------
-- JOIN
-- ---------------------------------------------------------------------------

local function resolve_on(on)
  -- on: string or {left_col, right_col}
  if type(on) == "string" then
    return on, on
  else
    return on[1], on[2]
  end
end

function DataFrame:join(other, on)
  local lcol, rcol = resolve_on(on)
  -- Build hash on right side
  local hash = {}
  for _, rrow in ipairs(other._rows) do
    local k = rrow[rcol]
    if k ~= nil then
      hash[k] = hash[k] or {}
      insert(hash[k], rrow)
    end
  end

  -- Determine output columns: all left cols + right cols not in left
  local out_cols = copy_cols(self._cols)
  local left_col_set = {}
  for _, c in ipairs(self._cols) do left_col_set[c] = true end
  for _, c in ipairs(other._cols) do
    if not left_col_set[c] then insert(out_cols, c) end
  end

  local result = {}
  for _, lrow in ipairs(self._rows) do
    local k = lrow[lcol]
    local matches = k ~= nil and hash[k]
    if matches then
      for _, rrow in ipairs(matches) do
        local new_row = copy_row(lrow)
        for _, c in ipairs(other._cols) do
          if not left_col_set[c] then
            new_row[c] = rrow[c]
          end
        end
        insert(result, new_row)
      end
    end
  end

  return new_df(result, out_cols)
end

function DataFrame:left_join(other, on)
  local lcol, rcol = resolve_on(on)
  local hash = {}
  for _, rrow in ipairs(other._rows) do
    local k = rrow[rcol]
    if k ~= nil then
      hash[k] = hash[k] or {}
      insert(hash[k], rrow)
    end
  end

  local out_cols = copy_cols(self._cols)
  local left_col_set = {}
  for _, c in ipairs(self._cols) do left_col_set[c] = true end
  for _, c in ipairs(other._cols) do
    if not left_col_set[c] then insert(out_cols, c) end
  end

  local result = {}
  for _, lrow in ipairs(self._rows) do
    local k = lrow[lcol]
    local matches = k ~= nil and hash[k]
    if matches then
      for _, rrow in ipairs(matches) do
        local new_row = copy_row(lrow)
        for _, c in ipairs(other._cols) do
          if not left_col_set[c] then
            new_row[c] = rrow[c]
          end
        end
        insert(result, new_row)
      end
    else
      -- No match: keep left row with nils for right columns
      local new_row = copy_row(lrow)
      for _, c in ipairs(other._cols) do
        if not left_col_set[c] then
          new_row[c] = nil
        end
      end
      insert(result, new_row)
    end
  end

  return new_df(result, out_cols)
end

-- ---------------------------------------------------------------------------
-- DISTINCT
-- ---------------------------------------------------------------------------

function DataFrame:distinct(col)
  local seen = {}
  local result = {}
  for _, row in ipairs(self._rows) do
    local key
    if col then
      key = tostring(row[col] ~= nil and row[col] or "")
    else
      -- Serialize all columns
      local parts = {}
      for _, c in ipairs(self._cols) do
        insert(parts, tostring(row[c] ~= nil and row[c] or ""))
      end
      key = concat(parts, "\0")
    end
    if not seen[key] then
      seen[key] = true
      insert(result, copy_row(row))
    end
  end
  return new_df(result, copy_cols(self._cols))
end

-- ---------------------------------------------------------------------------
-- ADD COLUMN
-- ---------------------------------------------------------------------------

function DataFrame:add_column(name, fn)
  local rows = {}
  for i, row in ipairs(self._rows) do
    local r = copy_row(row)
    r[name] = fn(row)
    rows[i] = r
  end
  local cols = copy_cols(self._cols)
  -- Add name if not already present
  local found = false
  for _, c in ipairs(cols) do if c == name then found = true; break end end
  if not found then insert(cols, name) end
  return new_df(rows, cols)
end

-- ---------------------------------------------------------------------------
-- DROP
-- ---------------------------------------------------------------------------

function DataFrame:drop(...)
  local drop_set = {}
  for _, c in ipairs({ ... }) do drop_set[c] = true end
  local cols = {}
  for _, c in ipairs(self._cols) do
    if not drop_set[c] then insert(cols, c) end
  end
  local rows = {}
  for i, row in ipairs(self._rows) do
    local r = {}
    for _, c in ipairs(cols) do r[c] = row[c] end
    rows[i] = r
  end
  return new_df(rows, cols)
end

-- ---------------------------------------------------------------------------
-- RENAME
-- ---------------------------------------------------------------------------

function DataFrame:rename(mapping)
  local cols = {}
  for _, c in ipairs(self._cols) do
    insert(cols, mapping[c] or c)
  end
  local rows = {}
  for i, row in ipairs(self._rows) do
    local r = {}
    for old, v in pairs(row) do
      r[mapping[old] or old] = v
    end
    rows[i] = r
  end
  return new_df(rows, cols)
end

-- ---------------------------------------------------------------------------
-- AGGREGATE (without grouping)
-- ---------------------------------------------------------------------------

function DataFrame:agg(spec)
  local result = {}
  -- Collect agg col names in deterministic order
  local out_cols = {}
  for out_col in pairs(spec) do insert(out_cols, out_col) end
  sort(out_cols)
  for _, out_col in ipairs(out_cols) do
    local s = spec[out_col]
    result[out_col] = apply_agg(self._rows, s[1], s[2])
  end
  return result
end

-- ---------------------------------------------------------------------------
-- Conversion
-- ---------------------------------------------------------------------------

function DataFrame:rows()
  local result = {}
  for i, row in ipairs(self._rows) do
    result[i] = copy_row(row)
  end
  return result
end

function DataFrame:columns()
  return copy_cols(self._cols)
end

function DataFrame:count()
  return #self._rows
end

function DataFrame:row(i)
  local r = self._rows[i]
  if not r then return nil end
  return copy_row(r)
end

function DataFrame:col_values(name)
  local result = {}
  for i, row in ipairs(self._rows) do
    result[i] = row[name]
  end
  return result
end

function DataFrame:to_csv()
  if csv then
    return csv.encode_records(self._rows, self._cols)
  end
  -- Built-in minimal formatter
  local lines = {}
  -- Header
  local header_parts = {}
  for _, c in ipairs(self._cols) do
    local s = tostring(c)
    if s:find(",") or s:find('"') or s:find("\n") then
      s = '"' .. s:gsub('"', '""') .. '"'
    end
    insert(header_parts, s)
  end
  insert(lines, concat(header_parts, ","))
  -- Rows
  for _, row in ipairs(self._rows) do
    local parts = {}
    for _, c in ipairs(self._cols) do
      local v = row[c]
      local s = v ~= nil and tostring(v) or ""
      if s:find(",") or s:find('"') or s:find("\n") then
        s = '"' .. s:gsub('"', '""') .. '"'
      end
      insert(parts, s)
    end
    insert(lines, concat(parts, ","))
  end
  return concat(lines, "\n") .. "\n"
end

-- ---------------------------------------------------------------------------
-- DESCRIBE
-- ---------------------------------------------------------------------------

function DataFrame:describe()
  local result = {}
  for _, col in ipairs(self._cols) do
    local vals = {}
    for _, row in ipairs(self._rows) do
      local v = row[col]
      if type(v) == "number" then insert(vals, v) end
    end
    if #vals > 0 then
      local n = #vals
      local sum = 0
      local mn, mx = vals[1], vals[1]
      for _, v in ipairs(vals) do
        sum = sum + v
        if v < mn then mn = v end
        if v > mx then mx = v end
      end
      local mean = sum / n
      local sq_sum = 0
      for _, v in ipairs(vals) do
        local d = v - mean
        sq_sum = sq_sum + d * d
      end
      local stddev = n > 1 and sqrt(sq_sum / (n - 1)) or 0
      result[col] = {
        count  = n,
        min    = mn,
        max    = mx,
        mean   = mean,
        stddev = stddev,
      }
    end
  end
  return result
end

return M
