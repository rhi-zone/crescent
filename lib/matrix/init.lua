if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

--- 2D matrix math library.
-- Pure Lua, flat row-major array storage for LuaJIT performance.
-- Errors return (nil, errmsg), never throw.

local M = {}
local Mt = { __index = M }

local sqrt = math.sqrt
local abs = math.abs
local floor = math.floor

--- Create a new matrix.
--: (rows: number, cols: number, data: { [number]: number }?) -> table
function M.new(rows, cols, data)
  if rows < 1 or cols < 1 then
    return nil, "matrix dimensions must be positive"
  end
  local n = rows * cols
  local d
  if data then
    if #data ~= n then
      return nil, "data length " .. #data .. " does not match " .. rows .. "x" .. cols
    end
    d = {}
    for i = 1, n do d[i] = data[i] end
  else
    d = {}
    for i = 1, n do d[i] = 0 end
  end
  return setmetatable({ _rows = rows, _cols = cols, _data = d }, Mt)
end

--- Create a matrix from an array of row arrays.
--: (rows: { [number]: { [number]: number } }) -> table
function M.from_rows(rows)
  local r = #rows
  if r == 0 then return nil, "empty row array" end
  local c = #rows[1]
  if c == 0 then return nil, "empty columns" end
  local d = {}
  local k = 0
  for i = 1, r do
    local row = rows[i]
    if #row ~= c then
      return nil, "row " .. i .. " has " .. #row .. " cols, expected " .. c
    end
    for j = 1, c do
      k = k + 1
      d[k] = row[j]
    end
  end
  return setmetatable({ _rows = r, _cols = c, _data = d }, Mt)
end

--- Create an identity matrix.
--: (n: number) -> table
function M.identity(n)
  local d = {}
  local sz = n * n
  for i = 1, sz do d[i] = 0 end
  for i = 1, n do
    d[(i - 1) * n + i] = 1
  end
  return setmetatable({ _rows = n, _cols = n, _data = d }, Mt)
end

--- Create a zero matrix.
--: (r: number, c: number) -> table
function M.zeros(r, c)
  return M.new(r, c)
end

--- Create a matrix of ones.
--: (r: number, c: number) -> table
function M.ones(r, c)
  local d = {}
  local n = r * c
  for i = 1, n do d[i] = 1 end
  return setmetatable({ _rows = r, _cols = c, _data = d }, Mt)
end

--- Create a matrix with random values in [lo, hi).
--: (r: number, c: number, lo: number, hi: number) -> table
function M.random(r, c, lo, hi)
  lo = lo or 0
  hi = hi or 1
  local d = {}
  local span = hi - lo
  local n = r * c
  for i = 1, n do
    d[i] = lo + math.random() * span
  end
  return setmetatable({ _rows = r, _cols = c, _data = d }, Mt)
end

--- Create a diagonal matrix from a vector.
--: (v: { [number]: number }) -> table
function M.diag(v)
  local n = #v
  local d = {}
  local sz = n * n
  for i = 1, sz do d[i] = 0 end
  for i = 1, n do
    d[(i - 1) * n + i] = v[i]
  end
  return setmetatable({ _rows = n, _cols = n, _data = d }, Mt)
end

--- Solve Ax = b via Gaussian elimination with partial pivoting.
-- Returns (nil, errmsg) if system is singular.
--: (A: table, b: table) -> table | (nil, string)
function M.solve(A, b)
  local n = A._rows
  if n ~= A._cols then
    return nil, "matrix must be square"
  end
  -- Build augmented matrix as array of rows for pivoting
  local aug = {}
  local ad = A._data
  local bd = b._data
  if not bd or #bd ~= n then
    return nil, "b must be a column vector with " .. n .. " rows"
  end
  for i = 1, n do
    local row = {}
    local base = (i - 1) * n
    for j = 1, n do
      row[j] = ad[base + j]
    end
    row[n + 1] = bd[i]
    aug[i] = row
  end
  -- Forward elimination with partial pivoting
  for k = 1, n do
    -- Find pivot
    local max_val = abs(aug[k][k])
    local max_row = k
    for i = k + 1, n do
      local v = abs(aug[i][k])
      if v > max_val then
        max_val = v
        max_row = i
      end
    end
    if max_val < 1e-12 then
      return nil, "singular matrix"
    end
    -- Swap rows
    if max_row ~= k then
      aug[k], aug[max_row] = aug[max_row], aug[k]
    end
    -- Eliminate below
    local pivot_row = aug[k]
    local pivot = pivot_row[k]
    for i = k + 1, n do
      local row = aug[i]
      local factor = row[k] / pivot
      for j = k + 1, n + 1 do
        row[j] = row[j] - factor * pivot_row[j]
      end
      row[k] = 0
    end
  end
  -- Back substitution
  local x = {}
  for i = n, 1, -1 do
    local row = aug[i]
    local s = row[n + 1]
    for j = i + 1, n do
      s = s - row[j] * x[j]
    end
    x[i] = s / row[i]
  end
  return setmetatable({ _rows = n, _cols = 1, _data = x }, Mt)
end

-- Instance methods

--: () -> number
function M:rows() return self._rows end

--: () -> number
function M:cols() return self._cols end

--: () -> number, number
function M:size() return self._rows, self._cols end

--: (r: number, c: number) -> number
function M:get(r, c)
  return self._data[(r - 1) * self._cols + c]
end

--: (r: number, c: number, v: number) -> nil
function M:set(r, c, v)
  self._data[(r - 1) * self._cols + c] = v
end

--- Return row i as a flat array.
--: (i: number) -> { [number]: number }
function M:row(i)
  local c = self._cols
  local d = self._data
  local base = (i - 1) * c
  local out = {}
  for j = 1, c do out[j] = d[base + j] end
  return out
end

--- Return column j as a flat array.
--: (j: number) -> { [number]: number }
function M:col(j)
  local r = self._rows
  local c = self._cols
  local d = self._data
  local out = {}
  for i = 1, r do out[i] = d[(i - 1) * c + j] end
  return out
end

--- Element-wise addition.
--: (other: table) -> table | (nil, string)
function M:add(other)
  local r, c = self._rows, self._cols
  if r ~= other._rows or c ~= other._cols then
    return nil, "dimension mismatch: " .. r .. "x" .. c .. " vs " .. other._rows .. "x" .. other._cols
  end
  local n = r * c
  local a, b = self._data, other._data
  local d = {}
  for i = 1, n do d[i] = a[i] + b[i] end
  return setmetatable({ _rows = r, _cols = c, _data = d }, Mt)
end

--- Element-wise subtraction.
--: (other: table) -> table | (nil, string)
function M:sub(other)
  local r, c = self._rows, self._cols
  if r ~= other._rows or c ~= other._cols then
    return nil, "dimension mismatch: " .. r .. "x" .. c .. " vs " .. other._rows .. "x" .. other._cols
  end
  local n = r * c
  local a, b = self._data, other._data
  local d = {}
  for i = 1, n do d[i] = a[i] - b[i] end
  return setmetatable({ _rows = r, _cols = c, _data = d }, Mt)
end

--- Matrix multiplication.
--: (other: table) -> table | (nil, string)
function M:mul(other)
  local ar, ac = self._rows, self._cols
  local br, bc = other._rows, other._cols
  if ac ~= br then
    return nil, "inner dimensions mismatch: " .. ac .. " vs " .. br
  end
  local a, b = self._data, other._data
  local d = {}
  local k = 0
  for i = 1, ar do
    local a_base = (i - 1) * ac
    for j = 1, bc do
      local s = 0
      for p = 1, ac do
        s = s + a[a_base + p] * b[(p - 1) * bc + j]
      end
      k = k + 1
      d[k] = s
    end
  end
  return setmetatable({ _rows = ar, _cols = bc, _data = d }, Mt)
end

--- Scalar multiplication.
--: (n: number) -> table
function M:scale(n)
  local sz = self._rows * self._cols
  local a = self._data
  local d = {}
  for i = 1, sz do d[i] = a[i] * n end
  return setmetatable({ _rows = self._rows, _cols = self._cols, _data = d }, Mt)
end

--- Negate all elements.
--: () -> table
function M:neg()
  return self:scale(-1)
end

--- Transpose.
--: () -> table
function M:transpose()
  local r, c = self._rows, self._cols
  local a = self._data
  local d = {}
  for i = 1, r do
    local base = (i - 1) * c
    for j = 1, c do
      d[(j - 1) * r + i] = a[base + j]
    end
  end
  return setmetatable({ _rows = c, _cols = r, _data = d }, Mt)
end

--- Trace (sum of diagonal elements).
--: () -> number | (nil, string)
function M:trace()
  if self._rows ~= self._cols then
    return nil, "trace requires square matrix"
  end
  local n = self._rows
  local c = self._cols
  local d = self._data
  local s = 0
  for i = 1, n do
    s = s + d[(i - 1) * c + i]
  end
  return s
end

--- Determinant via LU decomposition with partial pivoting.
--: () -> number | (nil, string)
function M:det()
  if self._rows ~= self._cols then
    return nil, "determinant requires square matrix"
  end
  local n = self._rows
  if n == 1 then return self._data[1] end
  if n == 2 then
    local d = self._data
    return d[1] * d[4] - d[2] * d[3]
  end
  -- Copy to working matrix (array of rows)
  local d = self._data
  local rows = {}
  for i = 1, n do
    local row = {}
    local base = (i - 1) * n
    for j = 1, n do row[j] = d[base + j] end
    rows[i] = row
  end
  local sign = 1
  for k = 1, n do
    -- Partial pivoting
    local max_val = abs(rows[k][k])
    local max_row = k
    for i = k + 1, n do
      local v = abs(rows[i][k])
      if v > max_val then
        max_val = v
        max_row = i
      end
    end
    if max_val < 1e-12 then return 0 end
    if max_row ~= k then
      rows[k], rows[max_row] = rows[max_row], rows[k]
      sign = -sign
    end
    local pivot_row = rows[k]
    local pivot = pivot_row[k]
    for i = k + 1, n do
      local row = rows[i]
      local factor = row[k] / pivot
      for j = k + 1, n do
        row[j] = row[j] - factor * pivot_row[j]
      end
      row[k] = 0
    end
  end
  local det = sign
  for i = 1, n do det = det * rows[i][i] end
  return det
end

--- Inverse via Gauss-Jordan elimination.
-- Returns (nil, errmsg) if singular.
--: () -> table | (nil, string)
function M:inverse()
  if self._rows ~= self._cols then
    return nil, "inverse requires square matrix"
  end
  local n = self._rows
  local d = self._data
  -- Build [A | I] augmented matrix
  local aug = {}
  for i = 1, n do
    local row = {}
    local base = (i - 1) * n
    for j = 1, n do row[j] = d[base + j] end
    for j = 1, n do row[n + j] = (i == j) and 1 or 0 end
    aug[i] = row
  end
  local n2 = n * 2
  -- Forward elimination
  for k = 1, n do
    local max_val = abs(aug[k][k])
    local max_row = k
    for i = k + 1, n do
      local v = abs(aug[i][k])
      if v > max_val then
        max_val = v
        max_row = i
      end
    end
    if max_val < 1e-12 then
      return nil, "singular matrix"
    end
    if max_row ~= k then
      aug[k], aug[max_row] = aug[max_row], aug[k]
    end
    local pivot_row = aug[k]
    local pivot = pivot_row[k]
    -- Scale pivot row
    for j = k, n2 do
      pivot_row[j] = pivot_row[j] / pivot
    end
    -- Eliminate column in all other rows
    for i = 1, n do
      if i ~= k then
        local row = aug[i]
        local factor = row[k]
        for j = k, n2 do
          row[j] = row[j] - factor * pivot_row[j]
        end
      end
    end
  end
  -- Extract right half
  local rd = {}
  local idx = 0
  for i = 1, n do
    local row = aug[i]
    for j = 1, n do
      idx = idx + 1
      rd[idx] = row[n + j]
    end
  end
  return setmetatable({ _rows = n, _cols = n, _data = rd }, Mt)
end

--- Element-wise equality with optional epsilon.
--: (other: table, eps: number?) -> boolean
function M:eq(other, eps)
  if self._rows ~= other._rows or self._cols ~= other._cols then
    return false
  end
  eps = eps or 0
  local n = self._rows * self._cols
  local a, b = self._data, other._data
  if eps == 0 then
    for i = 1, n do
      if a[i] ~= b[i] then return false end
    end
  else
    for i = 1, n do
      if abs(a[i] - b[i]) > eps then return false end
    end
  end
  return true
end

--- Element-wise transform.
--: (fn: (number) -> number) -> table
function M:map(fn)
  local n = self._rows * self._cols
  local a = self._data
  local d = {}
  for i = 1, n do d[i] = fn(a[i]) end
  return setmetatable({ _rows = self._rows, _cols = self._cols, _data = d }, Mt)
end

--- Reshape to new dimensions (must preserve element count).
--: (r: number, c: number) -> table | (nil, string)
function M:reshape(r, c)
  if r * c ~= self._rows * self._cols then
    return nil, "cannot reshape " .. self._rows .. "x" .. self._cols .. " to " .. r .. "x" .. c
  end
  local d = {}
  local a = self._data
  local n = r * c
  for i = 1, n do d[i] = a[i] end
  return setmetatable({ _rows = r, _cols = c, _data = d }, Mt)
end

--- Return flat array copy of data.
--: () -> { [number]: number }
function M:to_array()
  local n = self._rows * self._cols
  local a = self._data
  local d = {}
  for i = 1, n do d[i] = a[i] end
  return d
end

--- Return array of row arrays.
--: () -> { [number]: { [number]: number } }
function M:to_rows()
  local r, c = self._rows, self._cols
  local a = self._data
  local out = {}
  for i = 1, r do
    local row = {}
    local base = (i - 1) * c
    for j = 1, c do row[j] = a[base + j] end
    out[i] = row
  end
  return out
end

--- Frobenius norm.
--: () -> number
function M:norm()
  local n = self._rows * self._cols
  local a = self._data
  local s = 0
  for i = 1, n do s = s + a[i] * a[i] end
  return sqrt(s)
end

--- Frobenius inner product (element-wise multiply then sum).
--: (other: table) -> number | (nil, string)
function M:dot(other)
  if self._rows ~= other._rows or self._cols ~= other._cols then
    return nil, "dimension mismatch"
  end
  local n = self._rows * self._cols
  local a, b = self._data, other._data
  local s = 0
  for i = 1, n do s = s + a[i] * b[i] end
  return s
end

--- String representation.
Mt.__tostring = function(self)
  local r, c = self._rows, self._cols
  local d = self._data
  local lines = {}
  for i = 1, r do
    local vals = {}
    local base = (i - 1) * c
    for j = 1, c do
      vals[j] = tostring(d[base + j])
    end
    lines[i] = "| " .. table.concat(vals, "\t") .. " |"
  end
  return table.concat(lines, "\n")
end

return M
