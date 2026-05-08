-- lib/sparse_matrix/init.lua
-- Sparse matrix library supporting DOK, CSR, and COO formats.
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local floor = math.floor
local sqrt  = math.sqrt
local abs   = math.abs

-- ── helpers ───────────────────────────────────────────────────────────────────

-- Encode (i,j) into a single integer key for DOK storage.
-- Rows/cols are 1-based; max dim is 2^20 (~1M), enough for practical sparse work.
local SHIFT = 20
local MASK  = (1 * 2^SHIFT) - 1  -- lower 20 bits

--:: DOKData = { [number]: number }
--:: DOKMatrix = { rows: integer, cols: integer, data: DOKData, T: (self: unknown) -> DOKMatrix, to_coo: (self: unknown) -> unknown, to_csr: (self: unknown) -> unknown, to_dense: (self: unknown) -> unknown, mul_vec: (self: unknown, vec: unknown) -> unknown, norm: (self: unknown, p: unknown) -> (number | nil, string | nil) }
--:: CSRMatrix = { rows: integer, cols: integer, rp: { [integer]: integer }, ci: { [integer]: integer }, cv: { [integer]: number }, to_dok: (self: unknown) -> DOKMatrix }
--:: COOMatrix = { rows: integer, cols: integer, rows_list: { [integer]: integer }, cols_list: { [integer]: integer }, vals: { [integer]: number }, to_dok: (self: unknown) -> DOKMatrix }

--: (number, number) -> number
local function key(i, j) return i * 2^SHIFT + j end
--: (number) -> (number, number)
local function unkey(k)
  local j = k % 2^SHIFT
  local i = (k - j) / 2^SHIFT
  return i, j
end

-- ── DOK ───────────────────────────────────────────────────────────────────────
-- Dictionary Of Keys: data[key(i,j)] = v

local DOK = {}
DOK.__index = DOK

--: (DOKMatrix, number, number, number) -> nil
function DOK:set(i, j, v)
  local k = key(i, j)
  if v == 0 then
    self.data[k] = nil
  else
    self.data[k] = v
  end
end

--: (DOKMatrix, number, number) -> number
function DOK:get(i, j)
  return self.data[key(i, j)] or 0
end

--: (DOKMatrix, number, number) -> nil
function DOK:del(i, j)
  self.data[key(i, j)] = nil
end

--: (DOKMatrix) -> integer
function DOK:nnz()
  local n = 0
  for _ in pairs(self.data) do n = n + 1 end
  return n
end

--: (DOKMatrix) -> (integer, integer)
function DOK:shape()
  return self.rows, self.cols
end

function DOK:each()
  local t = self.data
  local keys = {} --[[:! { [integer]: number }]]
  local vals = {} --[[:! { [integer]: number }]]
  local n = 0
  for k, v in pairs(t) do
    n = n + 1
    keys[n] = k
    vals[n] = v
  end
  local idx = 0
  return function()
    idx = idx + 1
    if idx <= n then
      local i, j = unkey(keys[idx])
      return i, j, vals[idx]
    end
  end
end

--: (DOKMatrix) -> { [integer]: { [integer]: number } }
function DOK:to_dense()
  local rows, cols = self.rows, self.cols
  local out = {}
  for r = 1, rows do
    out[r] = {}
    for c = 1, cols do
      out[r][c] = self.data[key(r, c)] or 0
    end
  end
  return out
end

--: (DOKMatrix) -> CSRMatrix
function DOK:to_csr()
  local rows, cols = self.rows, self.cols
  -- collect and sort entries row-major
  local entries = {}
  for k, v in pairs(self.data) do
    local i, j = unkey(k)
    entries[#entries + 1] = { i, j, v }
  end
  table.sort(entries, function(a, b)
    if a[1] ~= b[1] then return a[1] < b[1] end
    return a[2] < b[2]
  end)

  local rp = {} --[[:! { [integer]: integer }]]  -- row pointers (length rows+1)
  local ci = {} --[[:! { [integer]: integer }]]  -- column indices
  local cv = {} --[[:! { [integer]: number }]]   -- values

  for r = 1, rows + 1 do rp[r] = 1 end

  for _, e in ipairs(entries) do
    local r, c, v = e[1], e[2], e[3]
    ci[#ci + 1] = c
    cv[#cv + 1] = v
    rp[r + 1] = #ci + 1
  end
  -- fill forward
  for r = 2, rows + 1 do
    if rp[r] < rp[r - 1] then rp[r] = rp[r - 1] end
  end

  return M._make_csr(rows, cols, rp, ci, cv)
end

--: (DOKMatrix) -> COOMatrix
function DOK:to_coo()
  local rows_list = {} --[[:! { [integer]: integer }]]
  local cols_list = {} --[[:! { [integer]: integer }]]
  local vals = {} --[[:! { [integer]: number }]]
  for k, v in pairs(self.data) do
    local i, j = unkey(k)
    rows_list[#rows_list + 1] = i --[[:! integer]]
    cols_list[#cols_list + 1] = j --[[:! integer]]
    vals[#vals + 1] = v
  end
  return M._make_coo(self.rows, self.cols, rows_list, cols_list, vals)
end

--: (DOKMatrix, { [integer]: number }) -> { [integer]: number }
function DOK:mul_vec(vec)
  local rows, cols = self.rows, self.cols
  local out = {} --[[:! { [integer]: number }]]
  for r = 1, rows do out[r] = 0 end
  for k, v in pairs(self.data) do
    local i, j = unkey(k)
    out[i --[[:! integer]]] = out[i --[[:! integer]]] + v * (vec[j --[[:! integer]]] or 0)
  end
  return out
end

--: (DOKMatrix, integer | "inf" | "fro") -> (number | nil, string | nil)
function DOK:norm(p)
  if p == 1 then
    -- max column sum of absolute values
    local col_sum = {} --[[:! { [number]: number }]]
    for k, v in pairs(self.data) do
      local _, j = unkey(k)
      col_sum[j] = (col_sum[j] or 0) + abs(v)
    end
    local mx = 0 --: number
    for _, s in pairs(col_sum) do if s > mx then mx = s end end
    return mx
  elseif p == "inf" then
    -- max row sum of absolute values
    local row_sum = {} --[[:! { [number]: number }]]
    for k, v in pairs(self.data) do
      local i = floor(k / 2^SHIFT)
      row_sum[i] = (row_sum[i] or 0) + abs(v)
    end
    local mx = 0 --: number
    for _, s in pairs(row_sum) do if s > mx then mx = s end end
    return mx
  elseif p == "fro" then
    local s = 0 --: number
    for _, v in pairs(self.data) do s = s + v * v end
    return sqrt(s)
  end
  return nil, "unsupported norm: " .. tostring(p)
end

--: (DOKMatrix) -> DOKMatrix
function DOK:T()
  local out = M.dok(self.cols, self.rows)
  for k, v in pairs(self.data) do
    local i, j = unkey(k)
    out.data[key(j, i)] = v
  end
  return out
end

-- ── CSR ───────────────────────────────────────────────────────────────────────
-- Compressed Sparse Row: rp[i]..rp[i+1]-1 are the col/val indices for row i.

local CSR = {}
CSR.__index = CSR

function CSR:get(i, j)
  local rp, ci, cv = self.rp, self.ci, self.cv
  for idx = rp[i], rp[i + 1] - 1 do
    if ci[idx] == j then return cv[idx] end
  end
  return 0
end

--: (CSRMatrix) -> integer
function CSR:nnz()
  return #self.cv
end

--: (CSRMatrix) -> (integer, integer)
function CSR:shape()
  return self.rows, self.cols
end

function CSR:each()
  local rows = self.rows
  local rp, ci, cv = self.rp, self.ci, self.cv
  local r = 1
  local idx = rp[1]
  return function()
    while r <= rows do
      if idx < rp[r + 1] then
        local i, j, v = r, ci[idx], cv[idx]
        idx = idx + 1
        return i, j, v
      end
      r = r + 1
      if r <= rows then idx = rp[r] end
    end
  end
end

--: (CSRMatrix) -> { [integer]: { [integer]: number } }
function CSR:to_dense()
  local rows, cols = self.rows, self.cols
  local rp, ci, cv = self.rp, self.ci, self.cv
  local out = {}
  for r = 1, rows do
    out[r] = {}
    for c = 1, cols do out[r][c] = 0 end
    for idx = rp[r], rp[r + 1] - 1 do
      out[r][ci[idx]] = cv[idx]
    end
  end
  return out
end

--: (CSRMatrix) -> DOKMatrix
function CSR:to_dok()
  local d = M.dok(self.rows, self.cols)
  local rp, ci, cv = self.rp, self.ci, self.cv
  for r = 1, self.rows do
    for idx = rp[r], rp[r + 1] - 1 do
      d.data[key(r, ci[idx])] = cv[idx]
    end
  end
  return d
end

--: (CSRMatrix) -> CSRMatrix
function CSR:to_csr() return self end

--: (CSRMatrix) -> COOMatrix
function CSR:to_coo()
  return (self:to_dok():to_coo() --[[:! COOMatrix]])
end

--: (CSRMatrix, { [integer]: number }) -> { [integer]: number }
function CSR:mul_vec(vec)
  local rows = self.rows
  local rp, ci, cv = self.rp, self.ci, self.cv
  local out = {}
  for r = 1, rows do
    local s = 0
    for idx = rp[r], rp[r + 1] - 1 do
      s = s + cv[idx] * (vec[ci[idx]] or 0)
    end
    out[r] = s
  end
  return out
end

--: (CSRMatrix, integer | "inf" | "fro") -> (number | nil, string | nil)
function CSR:norm(p)
  return self:to_dok():norm(p)
end

--: (CSRMatrix) -> DOKMatrix
function CSR:T()
  return self:to_dok():T()
end

-- ── COO ───────────────────────────────────────────────────────────────────────
-- Coordinate list: parallel arrays rows_list, cols_list, vals.

local COO = {}
COO.__index = COO

--: (COOMatrix) -> integer
function COO:nnz()
  return #self.vals
end

--: (COOMatrix) -> (integer, integer)
function COO:shape()
  return self.rows, self.cols
end

--: (COOMatrix) -> () -> unknown
function COO:each()
  local rs, cs, vs = self.rows_list, self.cols_list, self.vals
  local i = 0
  local n = #vs
  return function()
    i = i + 1
    if i <= n then return rs[i], cs[i], vs[i] end
  end
end

--: (COOMatrix) -> DOKMatrix
function COO:to_dok()
  local d = M.dok(self.rows, self.cols)
  local rs, cs, vs = self.rows_list, self.cols_list, self.vals
  for idx = 1, #vs do
    d.data[key(rs[idx], cs[idx])] = vs[idx]
  end
  return d
end

--: (COOMatrix) -> CSRMatrix
function COO:to_csr()
  return (self:to_dok():to_csr() --[[:! CSRMatrix]])
end

--: (COOMatrix) -> COOMatrix
function COO:to_coo() return self end

--: (COOMatrix) -> { [integer]: { [integer]: number } }
function COO:to_dense()
  return (self:to_dok():to_dense() --[[:! { [integer]: { [integer]: number } }]])
end

--: (COOMatrix, { [integer]: number }) -> { [integer]: number }
function COO:mul_vec(vec)
  return (self:to_dok():mul_vec(vec) --[[:! { [integer]: number }]])
end

--: (COOMatrix, integer | "inf" | "fro") -> (number | nil, string | nil)
function COO:norm(p)
  return self:to_dok():norm(p)
end

--: (COOMatrix) -> DOKMatrix
function COO:T()
  return self:to_dok():T()
end

-- ── arithmetic helpers (format-agnostic) ──────────────────────────────────────

-- Convert anything to DOK for element-wise access.
--: ({ to_dok: () -> DOKMatrix, ... }) -> DOKMatrix
local function as_dok(A)
  if getmetatable(A) == DOK then return A --[[:! DOKMatrix]] end
  return A:to_dok()
end

local function check_shape(A, B)
  local ar, ac = A:shape()
  local br, bc = B:shape()
  if ar ~= br or ac ~= bc then
    return nil, "shape mismatch: " .. ar .. "x" .. ac .. " vs " .. br .. "x" .. bc
  end
  return ar, ac
end

-- ── metamethods shared across formats ─────────────────────────────────────────

local function mt_add(A, B)
  if type(B) == "number" then
    -- adding a scalar to a sparse matrix is dense — not sensible, error gracefully
    error("sparse matrix + scalar is undefined; use scale for scalar multiply", 2)
  end
  return M.add(A, B)
end

local function mt_mul(A, B)
  if type(B) == "number" then return M.scale(A, B) end
  if type(A) == "number" then return M.scale(B, A) end
  return M.mul(A, B)
end

DOK.__add = mt_add
DOK.__mul = mt_mul
CSR.__add = mt_add
CSR.__mul = mt_mul
COO.__add = mt_add
COO.__mul = mt_mul

-- ── public constructors ───────────────────────────────────────────────────────

--: (integer, integer) -> DOKMatrix
function M.dok(rows, cols)
  return (setmetatable({ rows = rows, cols = cols, data = {} --[[:! DOKData]] }, DOK) --[[:! DOKMatrix]])
end

--: (integer, integer, { [integer]: integer }, { [integer]: integer }, { [integer]: number }) -> CSRMatrix
function M._make_csr(rows, cols, rp, ci, cv)
  return (setmetatable({ rows = rows, cols = cols, rp = rp, ci = ci, cv = cv }, CSR) --[[:! CSRMatrix]])
end

--: (integer, integer, { [integer]: integer }, { [integer]: integer }, { [integer]: number }) -> COOMatrix
function M._make_coo(rows, cols, rows_list, cols_list, vals)
  return (setmetatable({ rows = rows, cols = cols, --[[:! COOMatrix]]
                        rows_list = rows_list, cols_list = cols_list, vals = vals }, COO) --[[:! COOMatrix]])
end

-- M.coo(rows, cols, triples) where triples = {{i,j,v},...}
function M.coo(rows, cols, triples)
  local rs, cs, vs = {}, {}, {}
  if triples then
    for _, t in ipairs(triples) do
      rs[#rs + 1] = t[1]
      cs[#cs + 1] = t[2]
      vs[#vs + 1] = t[3]
    end
  end
  return M._make_coo(rows, cols, rs, cs, vs)
end

-- M.from_dense(t) where t is a 2D array (1-based).
function M.from_dense(t)
  local rows = #t
  local cols = rows > 0 and #t[1] or 0
  local d = M.dok(rows, cols)
  for r = 1, rows do
    for c = 1, cols do
      local v = t[r][c]
      if v and v ~= 0 then
        d.data[key(r, c)] = v
      end
    end
  end
  return d
end

-- ── operations ────────────────────────────────────────────────────────────────

function M.add(A, B)
  local rows, err = check_shape(A, B)
  if not rows then return nil, err end
  local _, cols = A:shape()

  local da = as_dok(A)
  local db = as_dok(B)
  local out = M.dok(rows, cols)

  for k, v in pairs(da.data) do
    out.data[k] = v
  end
  for k, v in pairs(db.data) do
    local cur = out.data[k] or 0
    local s = cur + v
    if s == 0 then
      out.data[k] = nil
    else
      out.data[k] = s
    end
  end
  return out
end

function M.mul(A, B)
  local ar, ac = A:shape()
  local br, bc = B:shape()
  if ac ~= br then
    return nil, "mul shape mismatch: " .. ar .. "x" .. ac .. " * " .. br .. "x" .. bc
  end

  local da = as_dok(A)
  local db = as_dok(B)
  local out = M.dok(ar, bc)

  -- For each non-zero in A, multiply with matching non-zeros in B (same row index).
  -- Build column index for B: col_index[j] = list of (k, v) pairs where db[j,k] != 0
  local b_by_row = {}
  for kk, v in pairs(db.data) do
    local i, j = unkey(kk)
    if not b_by_row[i] then b_by_row[i] = {} end
    b_by_row[i][#b_by_row[i] + 1] = { j, v }
  end

  for ka, va in pairs(da.data) do
    local ai, aj = unkey(ka)
    local brow = b_by_row[aj]
    if brow then
      for _, pair in ipairs(brow) do
        local bj, bv = pair[1], pair[2]
        local ok = key(ai, bj)
        out.data[ok] = (out.data[ok] or 0) + va * bv
      end
    end
  end

  -- Remove accidental zeros
  for k, v in pairs(out.data) do
    if v == 0 then out.data[k] = nil end
  end

  return out
end

function M.scale(A, k)
  local rows, cols = A:shape()
  local out = M.dok(rows, cols)
  local da = as_dok(A)
  if k == 0 then return out end
  for idx, v in pairs(da.data) do
    out.data[idx] = v * k
  end
  return out
end

function M.transpose(A)
  return as_dok(A):T()
end

function M.mul_vec(A, vec)
  return A:mul_vec(vec)
end

function M.norm(A, p)
  return A:norm(p)
end

function M.each(A)
  return A:each()
end

function M.to_dense(A)
  return A:to_dense()
end

return M
