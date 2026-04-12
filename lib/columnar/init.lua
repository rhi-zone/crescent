if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- Aggregation descriptor builders

function M.count()
  return { op = "count" }
end

function M.avg(col_name)
  return { op = "avg", col = col_name }
end

function M.sum(col_name)
  return { op = "sum", col = col_name }
end

function M.min(col_name)
  return { op = "min", col = col_name }
end

function M.max(col_name)
  return { op = "max", col = col_name }
end

-- Type validators

local type_validators = {
  integer = function(v) return type(v) == "number" end,
  number  = function(v) return type(v) == "number" end,
  string  = function(v) return type(v) == "string" end,
  boolean = function(v) return type(v) == "boolean" end,
}

-- Table object

local Table = {}
Table.__index = Table

function Table:_validate(col_def, value)
  if value == nil then return true end  -- nil is allowed (null)
  local validator = type_validators[col_def.type]
  if not validator then
    return nil, "unknown type: " .. tostring(col_def.type)
  end
  if not validator(value) then
    return nil, "column '" .. col_def.name .. "' expects " .. col_def.type ..
      ", got " .. type(value)
  end
  return true
end

function Table:insert(row)
  for i = 1, #self._schema do
    local col_def = self._schema[i]
    local value = row[col_def.name]
    local ok, err = self:_validate(col_def, value)
    if not ok then return nil, err end
  end
  self._count = self._count + 1
  for i = 1, #self._schema do
    local name = self._schema[i].name
    self._columns[name][self._count] = row[name]
  end
  return true
end

function Table:insert_many(rows)
  for _, row in ipairs(rows) do
    local ok, err = self:insert(row)
    if not ok then return nil, err end
  end
  return true
end

function Table:count()
  return self._count
end

function Table:column(name)
  local col = self._columns[name]
  if not col then return nil, "no such column: " .. tostring(name) end
  local result = {}
  for i = 1, self._count do
    result[i] = col[i]
  end
  return result
end

function Table:row(i)
  if i < 1 or i > self._count then
    return nil, "row index out of range: " .. tostring(i)
  end
  local result = {}
  for j = 1, #self._schema do
    local name = self._schema[j].name
    result[name] = self._columns[name][i]
  end
  return result
end

-- Reconstruct a row table from column arrays for a given index
function Table:_row_at(i)
  local result = {}
  for j = 1, #self._schema do
    local name = self._schema[j].name
    result[name] = self._columns[name][i]
  end
  return result
end

function Table:select(opts)
  opts = opts or {}
  local where = opts.where
  local proj = opts.columns
  local order_by = opts.order_by
  local desc = opts.desc
  local limit = opts.limit

  -- Build column projection set
  local proj_set
  if proj then
    proj_set = {}
    for _, name in ipairs(proj) do
      proj_set[name] = true
    end
  end

  -- Filter rows
  local rows = {}
  for i = 1, self._count do
    local row = self:_row_at(i)
    if not where or where(row) then
      if proj_set then
        local projected = {}
        for _, name in ipairs(proj) do
          projected[name] = row[name]
        end
        rows[#rows + 1] = projected
      else
        rows[#rows + 1] = row
      end
    end
  end

  -- Sort
  if order_by then
    if type(order_by) == "function" then
      if desc then
        table.sort(rows, function(a, b) return order_by(a, b) end)
        -- reverse
        local n = #rows
        for i = 1, math.floor(n / 2) do
          rows[i], rows[n - i + 1] = rows[n - i + 1], rows[i]
        end
      else
        table.sort(rows, order_by)
      end
    else
      local col_name = order_by
      if desc then
        table.sort(rows, function(a, b)
          local av, bv = a[col_name], b[col_name]
          if av == nil then return false end
          if bv == nil then return true end
          return av > bv
        end)
      else
        table.sort(rows, function(a, b)
          local av, bv = a[col_name], b[col_name]
          if av == nil then return false end
          if bv == nil then return true end
          return av < bv
        end)
      end
    end
  end

  -- Limit
  if limit and #rows > limit then
    local limited = {}
    for i = 1, limit do
      limited[i] = rows[i]
    end
    rows = limited
  end

  return rows
end

function Table:aggregate(opts)
  opts = opts or {}
  local group_by = opts.group_by
  local aggregations = opts.aggregations or {}

  -- Group rows
  local groups = {}   -- key -> {rows...}
  local group_keys = {} -- ordered list of unique keys

  for i = 1, self._count do
    local key
    if group_by then
      key = self._columns[group_by][i]
    else
      key = "__all__"
    end
    local sk = tostring(key) .. "\0" .. type(key)  -- safe string key
    if not groups[sk] then
      groups[sk] = { key = key, indices = {} }
      group_keys[#group_keys + 1] = sk
    end
    local g = groups[sk]
    g.indices[#g.indices + 1] = i
  end

  -- Compute aggregations per group
  local results = {}
  for _, sk in ipairs(group_keys) do
    local g = groups[sk]
    local result = {}
    if group_by then
      result[group_by] = g.key
    end

    for agg_name, agg_def in pairs(aggregations) do
      local op = agg_def.op
      if op == "count" then
        result[agg_name] = #g.indices
      elseif op == "sum" then
        local s = 0
        for _, idx in ipairs(g.indices) do
          local v = self._columns[agg_def.col][idx]
          if v ~= nil then s = s + v end
        end
        result[agg_name] = s
      elseif op == "avg" then
        local s = 0
        local c = 0
        for _, idx in ipairs(g.indices) do
          local v = self._columns[agg_def.col][idx]
          if v ~= nil then s = s + v; c = c + 1 end
        end
        result[agg_name] = c > 0 and (s / c) or nil
      elseif op == "min" then
        local mn = nil
        for _, idx in ipairs(g.indices) do
          local v = self._columns[agg_def.col][idx]
          if v ~= nil and (mn == nil or v < mn) then mn = v end
        end
        result[agg_name] = mn
      elseif op == "max" then
        local mx = nil
        for _, idx in ipairs(g.indices) do
          local v = self._columns[agg_def.col][idx]
          if v ~= nil and (mx == nil or v > mx) then mx = v end
        end
        result[agg_name] = mx
      end
    end

    results[#results + 1] = result
  end

  return results
end

function Table:stats(col_name)
  local col = self._columns[col_name]
  if not col then return nil, "no such column: " .. tostring(col_name) end

  local mn, mx, s, s2, c, nulls = nil, nil, 0, 0, 0, 0
  for i = 1, self._count do
    local v = col[i]
    if v == nil then
      nulls = nulls + 1
    else
      c = c + 1
      s = s + v
      s2 = s2 + v * v
      if mn == nil or v < mn then mn = v end
      if mx == nil or v > mx then mx = v end
    end
  end

  local mean = c > 0 and (s / c) or nil
  local stddev = nil
  if c > 1 then
    local variance = (s2 - s * s / c) / (c - 1)
    stddev = math.sqrt(variance < 0 and 0 or variance)
  elseif c == 1 then
    stddev = 0
  end

  return {
    min    = mn,
    max    = mx,
    mean   = mean,
    sum    = s,
    count  = c,
    stddev = stddev,
    nulls  = nulls,
  }
end

function Table:add_column(col_def)
  if not col_def or not col_def.name then
    return nil, "column definition requires a name"
  end
  if self._col_index[col_def.name] then
    return nil, "column already exists: " .. col_def.name
  end
  local default = col_def.default
  local arr = {}
  for i = 1, self._count do
    arr[i] = default
  end
  self._columns[col_def.name] = arr
  self._schema[#self._schema + 1] = { name = col_def.name, type = col_def.type or "string" }
  self._col_index[col_def.name] = #self._schema
  return true
end

function Table:drop_column(name)
  if not self._col_index[name] then
    return nil, "no such column: " .. tostring(name)
  end
  self._columns[name] = nil
  self._col_index[name] = nil
  local new_schema = {}
  for _, col_def in ipairs(self._schema) do
    if col_def.name ~= name then
      new_schema[#new_schema + 1] = col_def
    end
  end
  self._schema = new_schema
  -- Rebuild index
  for i, col_def in ipairs(self._schema) do
    self._col_index[col_def.name] = i
  end
  return true
end

function Table:delete(predicate)
  local kept = {}  -- per column: array of kept values
  for _, col_def in ipairs(self._schema) do
    kept[col_def.name] = {}
  end
  local new_count = 0
  for i = 1, self._count do
    local row = self:_row_at(i)
    if not predicate(row) then
      new_count = new_count + 1
      for _, col_def in ipairs(self._schema) do
        local name = col_def.name
        kept[name][new_count] = self._columns[name][i]
      end
    end
  end
  self._count = new_count
  for _, col_def in ipairs(self._schema) do
    self._columns[col_def.name] = kept[col_def.name]
  end
  return true
end

function Table:schema()
  local result = {}
  for i, col_def in ipairs(self._schema) do
    result[i] = { name = col_def.name, type = col_def.type }
  end
  return result
end

-- Constructor

function M.table(opts)
  if not opts or not opts.columns then
    return nil, "table() requires a columns definition"
  end

  local t = setmetatable({}, Table)
  t._schema = {}
  t._columns = {}
  t._col_index = {}
  t._count = 0

  for i, col_def in ipairs(opts.columns) do
    if not col_def.name then
      return nil, "column " .. i .. " missing name"
    end
    if not type_validators[col_def.type or "string"] then
      return nil, "unknown type: " .. tostring(col_def.type)
    end
    t._schema[i] = { name = col_def.name, type = col_def.type or "string" }
    t._columns[col_def.name] = {}
    t._col_index[col_def.name] = i
  end

  return t
end

return M
