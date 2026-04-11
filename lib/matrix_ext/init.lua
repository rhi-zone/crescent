if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

--- Advanced linear algebra: LU/QR/Cholesky/SVD decompositions, eigenvalues,
--- linear system solvers, pseudoinverse, rank, and matrix norms.
--- Builds on lib/matrix for the matrix type; all operations return (nil, errmsg)
--- on failure, never throw.

local Matrix = require("lib.matrix")

local M = {}
M._tier = "pure"

local sqrt = math.sqrt
local abs  = math.abs
local huge = math.huge

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Clone a matrix using the lib/matrix API.
local function clone(A)
  return Matrix.new(A._rows, A._cols, A._data)
end

--- Get element (1-indexed).
local function get(A, i, j)
  return A._data[(i - 1) * A._cols + j]
end

--- Set element (1-indexed).
local function set(A, i, j, v)
  A._data[(i - 1) * A._cols + j] = v
end

--- Dot product of two 1-D Lua tables (length n).
local function dot_vec(a, b, n)
  local s = 0
  for k = 1, n do s = s + a[k] * b[k] end
  return s
end

--- 2-norm of a 1-D Lua table (length n).
local function norm_vec(v, n)
  local s = 0
  for k = 1, n do s = s + v[k] * v[k] end
  return sqrt(s)
end

-- ---------------------------------------------------------------------------
-- Public constructors (thin wrappers forwarding to lib/matrix)
-- ---------------------------------------------------------------------------

--- Create a new rows×cols matrix filled with init (default 0).
--: (rows: number, cols: number, init: number?) -> table
function M.new(rows, cols, init)
  if init and init ~= 0 then
    local d = {}
    local n = rows * cols
    for i = 1, n do d[i] = init end
    return Matrix.new(rows, cols, d)
  end
  return Matrix.new(rows, cols)
end

--- n×n identity matrix.
--: (n: number) -> table
function M.identity(n)
  return Matrix.identity(n)
end

--- Matrix from flat row-major array.
--: (data: { [number]: number }, rows: number, cols: number) -> table | (nil, string)
function M.from_array(data, rows, cols)
  return Matrix.new(rows, cols, data)
end

--- Matrix from array of row arrays.
--: (rows_table: { [number]: { [number]: number } }) -> table | (nil, string)
function M.from_rows(rows_table)
  return Matrix.from_rows(rows_table)
end

-- ---------------------------------------------------------------------------
-- Matrix multiply / transpose / norms (module-level, not method-level)
-- ---------------------------------------------------------------------------

--- Matrix multiplication: A (m×k) * B (k×n) -> m×n.
--: (A: table, B: table) -> table | (nil, string)
function M.mul(A, B)
  if A._cols ~= B._rows then
    return nil, "inner dimensions mismatch: " .. A._cols .. " vs " .. B._rows
  end
  return A:mul(B)
end

--- Transpose of A.
--: (A: table) -> table
function M.transpose(A)
  return A:transpose()
end

--- Frobenius norm of A.
--: (A: table) -> number
function M.norm_frobenius(A)
  return A:norm()
end

--- 2-norm (largest singular value) of A.
--- Computed via power iteration on A^T A.
--: (A: table) -> number
function M.norm_2(A)
  local _, S = M.svd(A, 100)
  if not S then
    -- fallback: Frobenius
    return A:norm()
  end
  return S[1] or 0
end

-- ---------------------------------------------------------------------------
-- LU decomposition with partial pivoting
-- ---------------------------------------------------------------------------

--- LU decomposition of square matrix A with partial pivoting.
--- Returns L, U, P, sign  where P is a permutation vector (P[i] = original row),
--- sign is +1 or -1 (number of swaps parity), and PA = LU.
--- Returns (nil, nil, nil, nil, errmsg) if A is singular.
--: (A: table) -> table, table, { [number]: number }, number | (nil, nil, nil, nil, string)
function M.lu(A)
  local n = A._rows
  if n ~= A._cols then
    return nil, nil, nil, nil, "LU requires square matrix"
  end

  -- Working copy as 2-D Lua table for easy row swaps
  local U = {}
  local d = A._data
  for i = 1, n do
    U[i] = {}
    local base = (i - 1) * n
    for j = 1, n do U[i][j] = d[base + j] end
  end

  -- L starts as identity (we fill below-diagonal entries in place)
  local L_data = {}
  for i = 1, n * n do L_data[i] = 0 end
  for i = 1, n do L_data[(i - 1) * n + i] = 1 end

  local P = {}
  for i = 1, n do P[i] = i end
  local sign = 1

  for k = 1, n do
    -- Find pivot
    local max_val = abs(U[k][k])
    local max_row = k
    for i = k + 1, n do
      local v = abs(U[i][k])
      if v > max_val then max_val = v; max_row = i end
    end
    if max_val < 1e-15 then
      return nil, nil, nil, nil, "singular matrix"
    end

    -- Swap rows in U
    if max_row ~= k then
      U[k], U[max_row] = U[max_row], U[k]
      P[k], P[max_row] = P[max_row], P[k]
      -- Swap already-computed L entries (columns 1..k-1)
      for j = 1, k - 1 do
        local pk = (k - 1) * n + j
        local pm = (max_row - 1) * n + j
        L_data[pk], L_data[pm] = L_data[pm], L_data[pk]
      end
      sign = -sign
    end

    -- Eliminate
    for i = k + 1, n do
      local factor = U[i][k] / U[k][k]
      L_data[(i - 1) * n + k] = factor
      for j = k, n do
        U[i][j] = U[i][j] - factor * U[k][j]
      end
    end
  end

  -- Flatten U into a matrix
  local U_data = {}
  for i = 1, n do
    local base = (i - 1) * n
    for j = 1, n do U_data[base + j] = U[i][j] end
  end

  local Lm = Matrix.new(n, n, L_data)
  local Um = Matrix.new(n, n, U_data)
  return Lm, Um, P, sign
end

-- ---------------------------------------------------------------------------
-- Forward / back substitution helpers (for square lower/upper triangular)
-- ---------------------------------------------------------------------------

--- Solve L x = b where L is lower triangular (unit diagonal if unit=true).
local function fwd_sub(L, b, n, unit)
  local x = {}
  for i = 1, n do
    local s = b[i]
    for j = 1, i - 1 do
      s = s - get(L, i, j) * x[j]
    end
    if unit then
      x[i] = s
    else
      local diag = get(L, i, i)
      if abs(diag) < 1e-15 then return nil end
      x[i] = s / diag
    end
  end
  return x
end

--- Solve U x = b where U is upper triangular.
local function back_sub(U, b, n)
  local x = {}
  for i = n, 1, -1 do
    local s = b[i]
    for j = i + 1, n do
      s = s - get(U, i, j) * x[j]
    end
    local diag = get(U, i, i)
    if abs(diag) < 1e-15 then return nil end
    x[i] = s / diag
  end
  return x
end

-- ---------------------------------------------------------------------------
-- Linear system solver: Ax = b
-- ---------------------------------------------------------------------------

--- Solve Ax = b using LU decomposition with partial pivoting.
--- b is a 1-D Lua table (length n).
--- Returns x as a 1-D Lua table, or (nil, errmsg).
--: (A: table, b: { [number]: number }) -> { [number]: number } | (nil, string)
function M.solve(A, b)
  local n = A._rows
  if n ~= A._cols then return nil, "A must be square" end
  if #b ~= n then return nil, "b length must equal A rows" end

  local L, U, P, _, err = M.lu(A)
  if err then return nil, err end

  -- Apply permutation to b
  local pb = {}
  for i = 1, n do pb[i] = b[P[i]] end

  -- Solve Ly = pb (L has unit diagonal)
  local y = fwd_sub(L, pb, n, true)
  if not y then return nil, "singular matrix (forward substitution)" end

  -- Solve Ux = y
  local x = back_sub(U, y, n)
  if not x then return nil, "singular matrix (back substitution)" end

  return x
end

-- ---------------------------------------------------------------------------
-- Determinant
-- ---------------------------------------------------------------------------

--- Determinant of square matrix A via LU.
--: (A: table) -> number | (nil, string)
function M.det(A)
  local n = A._rows
  if n ~= A._cols then return nil, "det requires square matrix" end

  local _, U, _, sign, err = M.lu(A)
  if err then
    -- singular → det = 0
    return 0
  end

  local d = sign
  for i = 1, n do d = d * get(U, i, i) end
  return d
end

-- ---------------------------------------------------------------------------
-- Matrix inverse
-- ---------------------------------------------------------------------------

--- Inverse of square matrix A via LU.
--: (A: table) -> table | (nil, string)
function M.inv(A)
  local n = A._rows
  if n ~= A._cols then return nil, "inv requires square matrix" end

  local L, U, P, _, err = M.lu(A)
  if err then return nil, err end

  -- Solve for each column of the identity
  local cols = {}
  for j = 1, n do
    local ej = {}
    for i = 1, n do ej[i] = 0 end
    ej[P[j]] = 1  -- permuted RHS; we need e_j in the original ordering

    -- Actually we need to map through permutation: pb[i] = ej[P[i]]
    local pb = {}
    for i = 1, n do pb[i] = (P[i] == j) and 1 or 0 end

    local y = fwd_sub(L, pb, n, true)
    if not y then return nil, "singular matrix" end
    local x = back_sub(U, y, n)
    if not x then return nil, "singular matrix" end
    cols[j] = x
  end

  -- Assemble column-major result into row-major matrix
  local data = {}
  for i = 1, n do
    local base = (i - 1) * n
    for j = 1, n do
      data[base + j] = cols[j][i]
    end
  end
  return Matrix.new(n, n, data)
end

-- ---------------------------------------------------------------------------
-- QR decomposition (Modified Gram-Schmidt)
-- ---------------------------------------------------------------------------

--- QR decomposition of A (m×n, m >= n) via modified Gram-Schmidt.
--- Returns Q (m×n orthonormal columns), R (n×n upper triangular).
--- Returns (nil, nil, errmsg) on failure.
--: (A: table) -> table, table | (nil, nil, string)
function M.qr(A)
  local m, n = A._rows, A._cols
  if m < n then
    return nil, nil, "QR requires m >= n"
  end

  -- Work with columns as Lua arrays
  local Q_cols = {}
  for j = 1, n do
    Q_cols[j] = A:col(j)
  end

  local R_data = {}
  for i = 1, n * n do R_data[i] = 0 end

  for j = 1, n do
    -- Modified Gram-Schmidt: orthogonalize against previous columns in-place
    for k = 1, j - 1 do
      local r_kj = dot_vec(Q_cols[k], Q_cols[j], m)
      R_data[(k - 1) * n + j] = r_kj
      for i = 1, m do
        Q_cols[j][i] = Q_cols[j][i] - r_kj * Q_cols[k][i]
      end
    end
    local r_jj = norm_vec(Q_cols[j], m)
    R_data[(j - 1) * n + j] = r_jj
    if abs(r_jj) < 1e-15 then
      return nil, nil, "matrix is rank deficient (column " .. j .. " became zero)"
    end
    for i = 1, m do Q_cols[j][i] = Q_cols[j][i] / r_jj end
  end

  -- Assemble Q (m×n)
  local Q_data = {}
  for i = 1, m do
    local base = (i - 1) * n
    for j = 1, n do
      Q_data[base + j] = Q_cols[j][i]
    end
  end

  local Qm = Matrix.new(m, n, Q_data)
  local Rm = Matrix.new(n, n, R_data)
  return Qm, Rm
end

-- ---------------------------------------------------------------------------
-- Cholesky decomposition
-- ---------------------------------------------------------------------------

--- Cholesky decomposition of symmetric positive-definite matrix A.
--- Returns L (lower triangular) such that A = L * L^T.
--- Returns (nil, errmsg) if A is not positive definite.
--: (A: table) -> table | (nil, string)
function M.cholesky(A)
  local n = A._rows
  if n ~= A._cols then return nil, "Cholesky requires square matrix" end

  local L_data = {}
  for i = 1, n * n do L_data[i] = 0 end

  for i = 1, n do
    for j = 1, i do
      local s = get(A, i, j)
      for k = 1, j - 1 do
        s = s - L_data[(i - 1) * n + k] * L_data[(j - 1) * n + k]
      end
      if i == j then
        if s < 0 then
          return nil, "matrix is not positive definite (negative pivot at " .. i .. ")"
        end
        L_data[(i - 1) * n + j] = sqrt(s)
      else
        local ljj = L_data[(j - 1) * n + j]
        if abs(ljj) < 1e-15 then
          return nil, "matrix is not positive definite (zero diagonal)"
        end
        L_data[(i - 1) * n + j] = s / ljj
      end
    end
  end

  return Matrix.new(n, n, L_data)
end

-- ---------------------------------------------------------------------------
-- Jacobi eigenvalue algorithm (real symmetric matrices)
-- ---------------------------------------------------------------------------

--- Eigenvalues and eigenvectors of real symmetric matrix A via Jacobi iteration.
--- Returns eigenvalues (sorted ascending) and eigenvectors (columns of V).
--- max_iter defaults to 1000.
--: (A: table, max_iter: number?) -> { [number]: number }, table | (nil, nil, string)
function M.eigen_symmetric(A, max_iter)
  local n = A._rows
  if n ~= A._cols then
    return nil, nil, "eigen_symmetric requires square matrix"
  end
  max_iter = max_iter or 1000

  -- Working copy as 2-D Lua table
  local a = {}
  for i = 1, n do
    a[i] = {}
    for j = 1, n do a[i][j] = get(A, i, j) end
  end

  -- V starts as identity (accumulates rotations)
  local V = {}
  for i = 1, n do
    V[i] = {}
    for j = 1, n do V[i][j] = (i == j) and 1 or 0 end
  end

  for _ = 1, max_iter do
    -- Find largest off-diagonal element
    local max_val = 0
    local p, q = 1, 2
    for i = 1, n do
      for j = i + 1, n do
        local v = abs(a[i][j])
        if v > max_val then max_val = v; p = i; q = j end
      end
    end
    if max_val < 1e-12 then break end

    -- Compute rotation angle
    local theta
    local diff = a[q][q] - a[p][p]
    if abs(a[p][q]) < 1e-30 then
      theta = 0
    else
      local tau = diff / (2 * a[p][q])
      local t
      if tau >= 0 then
        t = 1 / (tau + sqrt(1 + tau * tau))
      else
        t = 1 / (tau - sqrt(1 + tau * tau))
      end
      theta = t  -- tan(theta)
    end

    local c = 1 / sqrt(1 + theta * theta)
    local s = theta * c

    -- Apply Jacobi rotation: a = G^T * a * G
    -- Update rows p and q
    local app = a[p][p]
    local aqq = a[q][q]
    local apq = a[p][q]

    a[p][p] = app - theta * apq
    a[q][q] = aqq + theta * apq
    a[p][q] = 0
    a[q][p] = 0

    for r = 1, n do
      if r ~= p and r ~= q then
        local arp = a[r][p]
        local arq = a[r][q]
        a[r][p] = c * arp - s * arq
        a[p][r] = a[r][p]
        a[r][q] = s * arp + c * arq
        a[q][r] = a[r][q]
      end
    end

    -- Accumulate V = V * G
    for r = 1, n do
      local vrp = V[r][p]
      local vrq = V[r][q]
      V[r][p] = c * vrp - s * vrq
      V[r][q] = s * vrp + c * vrq
    end
  end

  -- Extract eigenvalues
  local evals = {}
  for i = 1, n do evals[i] = a[i][i] end

  -- Sort eigenvalues and corresponding eigenvectors (ascending)
  local idx = {}
  for i = 1, n do idx[i] = i end
  table.sort(idx, function(x, y) return evals[x] < evals[y] end)

  local sorted_evals = {}
  for k = 1, n do sorted_evals[k] = evals[idx[k]] end

  -- Build eigenvector matrix (columns in sorted order)
  local V_data = {}
  for i = 1, n do
    local base = (i - 1) * n
    for k = 1, n do
      V_data[base + k] = V[i][idx[k]]
    end
  end
  local Vm = Matrix.new(n, n, V_data)
  return sorted_evals, Vm
end

-- ---------------------------------------------------------------------------
-- Power iteration (dominant eigenvalue)
-- ---------------------------------------------------------------------------

--- Power iteration to find the dominant (largest absolute) eigenvalue and
--- corresponding eigenvector of A.
--- Returns eigenvalue, eigenvector (1-D table), or (nil, nil, errmsg).
--: (A: table, max_iter: number?, tol: number?) -> number, { [number]: number } | (nil, nil, string)
function M.power_iter(A, max_iter, tol)
  local n = A._rows
  if n ~= A._cols then return nil, nil, "power_iter requires square matrix" end
  max_iter = max_iter or 1000
  tol = tol or 1e-10

  -- Start with a random-ish vector
  local v = {}
  for i = 1, n do v[i] = 1 / sqrt(n) end

  local eigenvalue = 0
  for _ = 1, max_iter do
    -- Multiply A * v
    local Av = {}
    for i = 1, n do
      local s = 0
      local base = (i - 1) * n
      local d = A._data
      for j = 1, n do s = s + d[base + j] * v[j] end
      Av[i] = s
    end

    -- Rayleigh quotient: lambda = v^T A v / v^T v = v^T Av (since ||v||=1)
    local new_eval = dot_vec(v, Av, n)
    local nrm = norm_vec(Av, n)
    if nrm < 1e-15 then
      return nil, nil, "zero vector in power iteration"
    end

    for i = 1, n do v[i] = Av[i] / nrm end

    if abs(new_eval - eigenvalue) < tol then
      eigenvalue = new_eval
      break
    end
    eigenvalue = new_eval
  end

  return eigenvalue, v
end

-- ---------------------------------------------------------------------------
-- One-sided Jacobi SVD
-- ---------------------------------------------------------------------------
-- Algorithm: apply Jacobi rotations to A from the right, accumulating V,
-- until A's columns are orthogonal. Column norms are the singular values;
-- normalised columns are the U vectors.
-- For m >= n this gives thin SVD: U (m×n), S (n), V (n×n).
-- Reference: Demmel & Veselic (1992), Drmac & Veselic (2008).

--- Thin SVD of A (m×n) via one-sided Jacobi.
--- Returns U (m×n), S (1-D array of n singular values descending), V (n×n).
--: (A: table, max_iter: number?) -> table, { [number]: number }, table | (nil, nil, nil, string)
function M.svd(A, max_iter)
  local m, n = A._rows, A._cols
  -- Handle wide matrices by transposing
  if m < n then
    local U2, S2, V2, err = M.svd(A:transpose(), max_iter)
    if err then return nil, nil, nil, err end
    return V2, S2, U2
  end

  max_iter = max_iter or 100

  -- Working copy of A as 2-D table (columns will be orthogonalized)
  local B = {}
  for i = 1, m do
    B[i] = {}
    for j = 1, n do B[i][j] = get(A, i, j) end
  end

  -- V starts as n×n identity
  local V = {}
  for i = 1, n do
    V[i] = {}
    for j = 1, n do V[i][j] = (i == j) and 1 or 0 end
  end

  -- Jacobi sweep: for each off-diagonal pair (p,q), zero the inner product
  -- of columns p and q by a right rotation.
  local tol = 1e-14

  for _ = 1, max_iter do
    local converged = true
    for p = 1, n - 1 do
      for q = p + 1, n do
        -- Compute inner products: alpha = <Bp, Bp>, beta = <Bq, Bq>, gamma = <Bp, Bq>
        local alpha, beta, gamma = 0, 0, 0
        for i = 1, m do
          alpha = alpha + B[i][p] * B[i][p]
          beta  = beta  + B[i][q] * B[i][q]
          gamma = gamma + B[i][p] * B[i][q]
        end
        -- Convergence check
        if abs(gamma) > tol * sqrt(alpha * beta) then
          converged = false
          -- Rotation angle: tan(2θ) = 2γ/(α−β),  t² + 2·cot(2θ)·t − 1 = 0
          -- where cot(2θ) = (α−β)/(2γ) = tau
          -- smaller-magnitude root: t = -tau +/- sqrt(tau^2+1)
          local tau = (alpha - beta) / (2 * gamma)
          local t
          if tau >= 0 then
            t = -tau + sqrt(tau * tau + 1)
          else
            t = -tau - sqrt(tau * tau + 1)
          end
          local c = 1 / sqrt(1 + t * t)
          local s = t * c
          -- Apply rotation to B columns p, q from right: B = B * G(p,q,c,s)
          for i = 1, m do
            local bp = B[i][p]
            local bq = B[i][q]
            B[i][p] =  c * bp + s * bq
            B[i][q] = -s * bp + c * bq
          end
          -- Accumulate in V: V = V * G(p,q,c,s)
          for i = 1, n do
            local vp = V[i][p]
            local vq = V[i][q]
            V[i][p] =  c * vp + s * vq
            V[i][q] = -s * vp + c * vq
          end
        end
      end
    end
    if converged then break end
  end

  -- Extract singular values (column norms of B) and normalise to get U
  local S = {}
  for j = 1, n do
    local nrm = 0
    for i = 1, m do nrm = nrm + B[i][j] * B[i][j] end
    S[j] = sqrt(nrm)
  end

  -- Sort descending by singular value
  local idx = {}
  for i = 1, n do idx[i] = i end
  table.sort(idx, function(x, y) return S[x] > S[y] end)

  local S_sorted = {}
  for k = 1, n do S_sorted[k] = S[idx[k]] end

  -- Build U (m×n thin): normalised columns of B in sorted order
  local U_data = {}
  for i = 1, m do
    local base = (i - 1) * n
    for k = 1, n do
      local j = idx[k]
      local sv = S[j]
      U_data[base + k] = (sv > 1e-15) and (B[i][j] / sv) or 0
    end
  end

  -- Build V (n×n) in sorted order
  local V_data = {}
  for i = 1, n do
    local base = (i - 1) * n
    for k = 1, n do
      V_data[base + k] = V[i][idx[k]]
    end
  end

  local Um = Matrix.new(m, n, U_data)
  local Vm = Matrix.new(n, n, V_data)
  return Um, S_sorted, Vm
end

-- ---------------------------------------------------------------------------
-- Rank
-- ---------------------------------------------------------------------------

--- Matrix rank via SVD (threshold-based).
--: (A: table, tol: number?) -> number
function M.rank(A, tol)
  local _, S, _, err = M.svd(A)
  if err or not S then return 0 end
  local n = #S
  if tol == nil then
    -- Default: machine epsilon * max(m,n) * max singular value
    local max_sv = S[1] or 0
    tol = 1e-12 * (A._rows > A._cols and A._rows or A._cols) * max_sv
  end
  local r = 0
  for i = 1, n do
    if S[i] > tol then r = r + 1 end
  end
  return r
end

-- ---------------------------------------------------------------------------
-- Moore-Penrose pseudoinverse
-- ---------------------------------------------------------------------------

--- Moore-Penrose pseudoinverse of A via SVD.
--: (A: table) -> table
function M.pinv(A)
  local m, n = A._rows, A._cols
  local U, S, V = M.svd(A)
  if not U then
    -- fallback: zero matrix
    return Matrix.new(n, m)
  end

  local k = #S
  -- Build S^+ (n×m): diagonal with 1/s_i if s_i > tol, else 0
  local max_sv = S[1] or 0
  local tol = 1e-12 * (m > n and m or n) * max_sv

  -- pinv = V * S^+ * U^T
  -- We compute this as: for each singular value, add v_i * (1/s_i) * u_i^T
  local data = {}
  for i = 1, n * m do data[i] = 0 end

  for i = 1, k do
    if S[i] > tol then
      local inv_s = 1 / S[i]
      for r = 1, n do
        local vr = get(V, r, i)
        local base = (r - 1) * m
        for c2 = 1, m do
          data[base + c2] = data[base + c2] + vr * inv_s * get(U, c2, i)
        end
      end
    end
  end

  return Matrix.new(n, m, data)
end

return M
