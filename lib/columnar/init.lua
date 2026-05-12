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

--:: ValidatorFn = (value: unknown) -> boolean
--: ValidatorFn
local function _val_number(v) return type(v) == "number" end
--: ValidatorFn
local function _val_string(v) return type(v) == "string" end
--: ValidatorFn
local function _val_boolean(v) return type(v) == "boolean" end
local type_validators = { --: { [string]: ValidatorFn }
  integer = _val_number,
  number  = _val_number,
  string  = _val_string,
  boolean = _val_boolean,
}

-- Table object

--:: ColDef = { name: string, type: string, default: unknown }
--:: ColTable = { _schema: { [integer]: ColDef }, _columns: { [string]: { [integer]: unknown } }, _col_index: { [string]: integer }, _count: integer, _validate: (ColTable, ColDef, unknown) -> (boolean | nil, string | nil), _row_at: (ColTable, integer) -> { [string]: unknown }, insert: (ColTable, { [string]: unknown }) -> (boolean | nil, string | nil), ... }

local Table = {}
Table.__index = Table

--: (ColTable, ColDef, unknown) -> (boolean | nil, string | nil)
function Table:_validate(col_def, value)
  local col_def_ = col_def --[[:! ColDef]]
  if value == nil then return true end  -- nil is allowed (null)
  local validator = type_validators[col_def_.type]
  if not validator then
    return nil, "unknown type: " .. tostring(col_def_.type)
  end
  if not validator(value) then
    return nil, "column '" .. col_def_.name .. "' expects " .. col_def_.type ..
      ", got " .. type(value)
  end
  return true
end

--: (ColTable, { [string]: unknown }) -> (boolean | nil, string | nil)
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

--: (ColTable, { [integer]: { [string]: unknown } }) -> (boolean | nil, string | nil)
function Table:insert_many(rows)
  for _, row in ipairs(rows) do
    local ok, err = self:insert(row)
    if not ok then return nil, err end
  end
  return true
end

--: (ColTable) -> integer
function Table:count()
  return self._count
end

--: (ColTable, string) -> ({ [integer]: unknown } | nil, string | nil)
function Table:column(name)
  local col = self._columns[name]
  if not col then return nil, "no such column: " .. tostring(name) end
  local result = {}
  for i = 1, self._count do
    result[i] = col[i]
  end
  return result
end

--: (ColTable, integer) -> ({ [string]: unknown } | nil, string | nil)
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
--: (ColTable, integer) -> { [string]: unknown }
function Table:_row_at(i)
  local result = {}
  for j = 1, #self._schema do
    local name = self._schema[j].name
    result[name] = self._columns[name][i]
  end
  return result
end

--: (ColTable, { where: (({ [string]: unknown }) -> boolean) | nil, columns: { [integer]: string } | nil, order_by: string | nil, desc: boolean | nil, limit: integer | nil, ... } | nil) -> { [integer]: { [string]: unknown } }
function Table:select(opts)
  local where = opts and opts.where
  local proj = opts and opts.columns
  local order_by = opts and opts.order_by
  local desc = opts and opts.desc
  local limit = opts and opts.limit

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
    local include = not where
    if not include then
      local where_ = where --[[:! (({ [string]: unknown }) -> boolean)]]
      include = where_(row)
    end
    if include then
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
  if limit and #rows > (limit --[[:! integer]]) then
    local limited = {}
    for i = 1, limit do
      limited[i] = rows[i]
    end
    rows = limited
  end

  return rows
end

--: (ColTable, { group_by: string | nil, aggregations: { [string]: { op: string, col: string | nil } } | nil, ... } | nil) -> { [string]: { [string]: unknown } }
function Table:aggregate(opts)
  local group_by = opts and opts.group_by
  local aggregations = opts and opts.aggregations or {}

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

    for agg_name, agg_def in pairs(aggregations --[[:! { [string]: { op: string, col: string } }]]) do
      local agg_def_ = agg_def
      local op = agg_def_.op
      if op == "count" then
        result[agg_name] = #g.indices
      elseif op == "sum" then
        local s = 0 --: number
        for _, idx in ipairs(g.indices) do
          local v = self._columns[agg_def_.col][idx]
          if v ~= nil then s = s + (v --[[:! number]]) end
        end
        result[agg_name] = s
      elseif op == "avg" then
        local s = 0 --: number
        local c = 0
        for _, idx in ipairs(g.indices) do
          local v = self._columns[agg_def_.col][idx]
          if v ~= nil then s = s + (v --[[:! number]]); c = c + 1 end
        end
        result[agg_name] = c > 0 and (s / c) or nil
      elseif op == "min" then
        local mn = nil --: number | nil
        for _, idx in ipairs(g.indices) do
          local v = self._columns[agg_def_.col][idx]
          if v ~= nil then
            local v_ = v --[[:! number]]
            if mn == nil or v_ < (mn --[[:! number]]) then mn = v_ end
          end
        end
        result[agg_name] = mn
      elseif op == "max" then
        local mx = nil --: number | nil
        for _, idx in ipairs(g.indices) do
          local v = self._columns[agg_def_.col][idx]
          if v ~= nil then
            local v_ = v --[[:! number]]
            if mx == nil or v_ > (mx --[[:! number]]) then mx = v_ end
          end
        end
        result[agg_name] = mx
      end
    end

    results[#results + 1] = result
  end

  return results
end

--: (ColTable, string) -> ({ [string]: number | nil } | nil, string | nil)
function Table:stats(col_name)
  local col = self._columns[col_name]
  if not col then return nil, "no such column: " .. tostring(col_name) end

  local mn = nil --: number | nil
  local mx = nil --: number | nil
  local s = 0 --: number
  local s2 = 0 --: number
  local c = 0
  local nulls = 0
  for i = 1, self._count do
    local v = col[i]
    if v == nil then
      nulls = nulls + 1
    else
      local v_ = v --[[:! number]]
      c = c + 1
      s = s + v_
      s2 = s2 + v_ * v_
      if mn == nil or v_ < (mn --[[:! number]]) then mn = v_ end
      if mx == nil or v_ > (mx --[[:! number]]) then mx = v_ end
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

--: (ColTable, ColDef) -> (boolean | nil, string | nil)
function Table:add_column(col_def)
  local col_def_ = col_def --[[:! ColDef]]
  if not col_def or not col_def_.name then
    return nil, "column definition requires a name"
  end
  if self._col_index[col_def_.name] then
    return nil, "column already exists: " .. col_def_.name
  end
  local default = col_def_.default
  local arr = {} --: { [integer]: unknown }
  for i = 1, self._count do
    arr[i] = default
  end
  self._columns[col_def_.name] = arr
  self._schema[#self._schema + 1] = { name = col_def_.name, type = col_def_.type or "string" }
  self._col_index[col_def_.name] = #self._schema
  return true
end

--: (ColTable, string) -> (boolean | nil, string | nil)
function Table:drop_column(name)
  if not self._col_index[name] then
    return nil, "no such column: " .. tostring(name)
  end
  self._columns[name] = nil --[[: unknown]]
  self._col_index[name] = nil --[[: unknown]]
  local new_schema = {} --: { [integer]: ColDef }
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

--: (ColTable, ({ [string]: unknown }) -> boolean) -> boolean
function Table:delete(predicate)
  local kept = {} --: { [string]: { [integer]: unknown } }
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

--: (ColTable) -> { [integer]: { name: string, type: string } }
function Table:schema()
  local result = {} --: { [integer]: { name: string, type: string } }
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

  local t = setmetatable({ _schema = {}, _columns = {}, _col_index = {}, _count = 0 }, Table)

  for i, col_def in ipairs(opts.columns) do
    local col_def_ = col_def --[[:! ColDef]]
    if not col_def_.name then
      return nil, "column " .. i .. " missing name"
    end
    if not type_validators[col_def_.type or "string"] then
      return nil, "unknown type: " .. tostring(col_def_.type)
    end
    t._schema[i] = { name = col_def_.name, type = col_def_.type or "string" }
    t._columns[col_def_.name] = {}
    t._col_index[col_def_.name] = i
  end

  return t
end

return M
