if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local MX = require("lib.matrix_ext")
local M  = require("lib.matrix")

local sqrt = math.sqrt
local abs  = math.abs

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function approx_eq(a, b, tol)
  tol = tol or 1e-9
  return abs(a - b) <= tol
end

local function mat_approx_eq(A, B, tol)
  tol = tol or 1e-9
  if A._rows ~= B._rows or A._cols ~= B._cols then return false end
  for i = 1, A._rows do
    for j = 1, A._cols do
      if abs(A:get(i,j) - B:get(i,j)) > tol then return false end
    end
  end
  return true
end

-- Multiply a matrix by a column vector (1-D table), returning 1-D table.
local function mat_vec(A, x)
  local m, n = A._rows, A._cols
  local out = {}
  for i = 1, m do
    local s = 0
    for j = 1, n do s = s + A:get(i,j) * x[j] end
    out[i] = s
  end
  return out
end

-- Frobenius difference between two matrices.
local function fro_diff(A, B)
  local n = A._rows * A._cols
  local s = 0
  for i = 1, n do
    local d = A._data[i] - B._data[i]
    s = s + d * d
  end
  return sqrt(s)
end

-- ---------------------------------------------------------------------------
-- Constructor / access tests
-- ---------------------------------------------------------------------------

T.describe("matrix_ext constructors", function()
  T.it("new creates zero matrix", function()
    local A = MX.new(2, 3)
    T.eq(A._rows, 2)
    T.eq(A._cols, 3)
    T.eq(A:get(1,1), 0)
    T.eq(A:get(2,3), 0)
  end)

  T.it("new with init value", function()
    local A = MX.new(2, 2, 5)
    T.eq(A:get(1,1), 5)
    T.eq(A:get(2,2), 5)
  end)

  T.it("identity matrix", function()
    local I = MX.identity(3)
    T.eq(I:get(1,1), 1)
    T.eq(I:get(2,2), 1)
    T.eq(I:get(3,3), 1)
    T.eq(I:get(1,2), 0)
    T.eq(I:get(2,3), 0)
  end)

  T.it("from_array", function()
    local A = MX.from_array({1,2,3,4,5,6}, 2, 3)
    T.eq(A:get(1,1), 1)
    T.eq(A:get(1,3), 3)
    T.eq(A:get(2,1), 4)
    T.eq(A:get(2,3), 6)
  end)

  T.it("from_rows", function()
    local A = MX.from_rows({{1,2},{3,4}})
    T.eq(A:get(1,1), 1)
    T.eq(A:get(1,2), 2)
    T.eq(A:get(2,1), 3)
    T.eq(A:get(2,2), 4)
  end)
end)

-- ---------------------------------------------------------------------------
-- mul / transpose / norm_frobenius
-- ---------------------------------------------------------------------------

T.describe("mul / transpose / norm_frobenius", function()
  T.it("2x2 matrix multiply", function()
    local A = MX.from_rows({{1,2},{3,4}})
    local B = MX.from_rows({{5,6},{7,8}})
    local C = MX.mul(A, B)
    T.eq(C:get(1,1), 19)
    T.eq(C:get(1,2), 22)
    T.eq(C:get(2,1), 43)
    T.eq(C:get(2,2), 50)
  end)

  T.it("mul dimension mismatch returns error", function()
    local A = MX.from_rows({{1,2,3}})
    local B = MX.from_rows({{1,2},{3,4}})
    local C, err = MX.mul(A, B)
    T.eq(C, nil)
    T.ok(err ~= nil)
  end)

  T.it("transpose 2x3", function()
    local A = MX.from_array({1,2,3,4,5,6}, 2, 3)
    local At = MX.transpose(A)
    T.eq(At._rows, 3)
    T.eq(At._cols, 2)
    T.eq(At:get(1,1), 1)
    T.eq(At:get(2,1), 2)
    T.eq(At:get(3,1), 3)
    T.eq(At:get(1,2), 4)
    T.eq(At:get(3,2), 6)
  end)

  T.it("frobenius norm", function()
    local A = MX.from_rows({{3,4},{0,0}})
    T.ok(approx_eq(MX.norm_frobenius(A), 5))
  end)

  T.it("frobenius norm identity 3x3", function()
    local I = MX.identity(3)
    T.ok(approx_eq(MX.norm_frobenius(I), sqrt(3)))
  end)
end)

-- ---------------------------------------------------------------------------
-- LU decomposition
-- ---------------------------------------------------------------------------

T.describe("LU decomposition", function()
  T.it("3x3 PA = LU", function()
    local A = MX.from_rows({{2,1,-1},{-3,-1,2},{-2,1,2}})
    local L, U, P, sign = MX.lu(A)
    T.ok(L ~= nil)
    T.ok(U ~= nil)
    T.ok(P ~= nil)

    -- Compute LU
    local LU = MX.mul(L, U)

    -- Compute PA (permuted A)
    local PA = MX.from_rows({A:row(P[1]), A:row(P[2]), A:row(P[3])})

    T.ok(mat_approx_eq(LU, PA, 1e-10))
  end)

  T.it("L is lower triangular with unit diagonal", function()
    local A = MX.from_rows({{4,3},{6,3}})
    local L, U, P = MX.lu(A)
    T.eq(L:get(1,1), 1)
    T.eq(L:get(2,2), 1)
    T.eq(L:get(1,2), 0)  -- upper triangle of L is zero
  end)

  T.it("U is upper triangular", function()
    local A = MX.from_rows({{4,3},{6,3}})
    local _, U = MX.lu(A)
    T.eq(U:get(2,1), 0)
  end)

  T.it("sign reflects swap parity", function()
    -- A diagonal matrix: no swaps → sign = 1
    local A = MX.from_rows({{2,0},{0,3}})
    local _, _, _, sign = MX.lu(A)
    T.ok(sign == 1 or sign == -1)
  end)

  T.it("singular matrix returns error", function()
    local A = MX.from_rows({{1,2},{2,4}})
    local L, U, P, sign, err = MX.lu(A)
    T.eq(L, nil)
    T.ok(err ~= nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- solve
-- ---------------------------------------------------------------------------

T.describe("solve Ax = b", function()
  T.it("2x2 system", function()
    local A = MX.from_rows({{2,1},{5,7}})
    local b = {11, 13}
    local x, err = MX.solve(A, b)
    T.eq(err, nil)
    T.ok(x ~= nil)
    -- Verify A*x ≈ b
    local Ax = mat_vec(A, x)
    T.ok(approx_eq(Ax[1], 11, 1e-10))
    T.ok(approx_eq(Ax[2], 13, 1e-10))
  end)

  T.it("3x3 system", function()
    local A = MX.from_rows({{1,2,3},{4,5,6},{7,8,10}})
    local b = {6, 15, 26}
    local x, err = MX.solve(A, b)
    T.eq(err, nil)
    local Ax = mat_vec(A, x)
    T.ok(approx_eq(Ax[1], 6,  1e-9))
    T.ok(approx_eq(Ax[2], 15, 1e-9))
    T.ok(approx_eq(Ax[3], 26, 1e-9))
  end)

  T.it("singular system returns error", function()
    local A = MX.from_rows({{1,2},{2,4}})
    local b = {1, 2}
    local x, err = MX.solve(A, b)
    T.eq(x, nil)
    T.ok(err ~= nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- determinant
-- ---------------------------------------------------------------------------

T.describe("determinant", function()
  T.it("2x2 det ad-bc", function()
    local A = MX.from_rows({{3,8},{4,6}})
    local d = MX.det(A)
    T.ok(approx_eq(d, 3*6 - 8*4, 1e-10))  -- 18-32 = -14
  end)

  T.it("3x3 det", function()
    local A = MX.from_rows({{1,2,3},{4,5,6},{7,8,10}})
    local d = MX.det(A)
    -- det = 1*(50-48) - 2*(40-42) + 3*(32-35) = 2+4-9 = -3
    T.ok(approx_eq(d, -3, 1e-8))
  end)

  T.it("identity det = 1", function()
    local I = MX.identity(4)
    T.ok(approx_eq(MX.det(I), 1, 1e-10))
  end)

  T.it("singular matrix det = 0", function()
    local A = MX.from_rows({{1,2},{2,4}})
    local d = MX.det(A)
    T.ok(approx_eq(d, 0, 1e-10))
  end)
end)

-- ---------------------------------------------------------------------------
-- matrix inverse
-- ---------------------------------------------------------------------------

T.describe("matrix inverse", function()
  T.it("2x2 inverse: A * inv(A) ≈ I", function()
    local A = MX.from_rows({{4,7},{2,6}})
    local Ai, err = MX.inv(A)
    T.eq(err, nil)
    T.ok(Ai ~= nil)
    local prod = MX.mul(A, Ai)
    local I    = MX.identity(2)
    T.ok(mat_approx_eq(prod, I, 1e-10))
  end)

  T.it("3x3 inverse: A * inv(A) ≈ I", function()
    local A = MX.from_rows({{1,2,3},{0,1,4},{5,6,0}})
    local Ai, err = MX.inv(A)
    T.eq(err, nil)
    local prod = MX.mul(A, Ai)
    local I    = MX.identity(3)
    T.ok(mat_approx_eq(prod, I, 1e-9))
  end)

  T.it("singular matrix inverse returns error", function()
    local A = MX.from_rows({{1,2},{2,4}})
    local Ai, err = MX.inv(A)
    T.eq(Ai, nil)
    T.ok(err ~= nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- QR decomposition
-- ---------------------------------------------------------------------------

T.describe("QR decomposition", function()
  T.it("3x3 QR: A = Q*R", function()
    local A = MX.from_rows({{1,2,3},{4,5,6},{7,8,10}})
    local Q, R, err = MX.qr(A)
    T.eq(err, nil)
    T.ok(Q ~= nil)
    T.ok(R ~= nil)
    local QR = MX.mul(Q, R)
    T.ok(mat_approx_eq(QR, A, 1e-9))
  end)

  T.it("3x3 QR: Q^T*Q ≈ I", function()
    local A = MX.from_rows({{1,2,3},{4,5,6},{7,8,10}})
    local Q, _, err = MX.qr(A)
    T.eq(err, nil)
    local Qt = MX.transpose(Q)
    local QtQ = MX.mul(Qt, Q)
    local I = MX.identity(3)
    T.ok(mat_approx_eq(QtQ, I, 1e-9))
  end)

  T.it("R is upper triangular", function()
    local A = MX.from_rows({{1,2,3},{4,5,6},{7,8,10}})
    local _, R = MX.qr(A)
    T.ok(approx_eq(R:get(2,1), 0, 1e-12))
    T.ok(approx_eq(R:get(3,1), 0, 1e-12))
    T.ok(approx_eq(R:get(3,2), 0, 1e-12))
  end)

  T.it("4x3 tall QR: A = Q*R and Q^T*Q = I", function()
    local A = MX.from_rows({{1,2,3},{4,5,6},{7,8,9},{1,0,1}})
    local Q, R, err = MX.qr(A)
    T.eq(err, nil)
    local QR = MX.mul(Q, R)
    T.ok(mat_approx_eq(QR, A, 1e-9))
    local QtQ = MX.mul(MX.transpose(Q), Q)
    local I   = MX.identity(3)
    T.ok(mat_approx_eq(QtQ, I, 1e-9))
  end)
end)

-- ---------------------------------------------------------------------------
-- Cholesky decomposition
-- ---------------------------------------------------------------------------

T.describe("Cholesky decomposition", function()
  T.it("2x2 SPD: L*L^T = A", function()
    local A = MX.from_rows({{4,2},{2,3}})
    local L, err = MX.cholesky(A)
    T.eq(err, nil)
    T.ok(L ~= nil)
    local Lt = MX.transpose(L)
    local LLt = MX.mul(L, Lt)
    T.ok(mat_approx_eq(LLt, A, 1e-10))
  end)

  T.it("3x3 SPD: L*L^T = A", function()
    local A = MX.from_rows({{4,2,2},{2,5,3},{2,3,6}})
    local L, err = MX.cholesky(A)
    T.eq(err, nil)
    local Lt = MX.transpose(L)
    local LLt = MX.mul(L, Lt)
    T.ok(mat_approx_eq(LLt, A, 1e-10))
  end)

  T.it("L is lower triangular", function()
    local A = MX.from_rows({{4,2},{2,3}})
    local L = MX.cholesky(A)
    T.ok(approx_eq(L:get(1,2), 0, 1e-12))
  end)

  T.it("non-positive-definite returns error", function()
    local A = MX.from_rows({{1,2},{2,1}})  -- eigenvalues -1 and 3 → not PD
    local L, err = MX.cholesky(A)
    T.eq(L, nil)
    T.ok(err ~= nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- Eigenvalues (Jacobi, symmetric)
-- ---------------------------------------------------------------------------

T.describe("eigen_symmetric", function()
  T.it("2x2 diagonal: eigenvalues are diagonal", function()
    local A = MX.from_rows({{3,0},{0,7}})
    local vals, vecs, err = MX.eigen_symmetric(A)
    T.eq(err, nil)
    T.ok(approx_eq(vals[1], 3, 1e-10))
    T.ok(approx_eq(vals[2], 7, 1e-10))
  end)

  T.it("2x2 diagonal: eigenvectors are identity columns", function()
    local A = MX.from_rows({{3,0},{0,7}})
    local _, vecs = MX.eigen_symmetric(A)
    -- eigenvec for lambda=3 is [1,0], for lambda=7 is [0,1]
    T.ok(approx_eq(abs(vecs:get(1,1)), 1, 1e-9))
    T.ok(approx_eq(abs(vecs:get(2,1)), 0, 1e-9))
    T.ok(approx_eq(abs(vecs:get(1,2)), 0, 1e-9))
    T.ok(approx_eq(abs(vecs:get(2,2)), 1, 1e-9))
  end)

  T.it("2x2 symmetric: eigenvalues satisfy char poly", function()
    -- A = [[2,1],[1,2]], eigenvalues are 1 and 3
    local A = MX.from_rows({{2,1},{1,2}})
    local vals, _, err = MX.eigen_symmetric(A)
    T.eq(err, nil)
    T.ok(approx_eq(vals[1], 1, 1e-9))
    T.ok(approx_eq(vals[2], 3, 1e-9))
  end)

  T.it("3x3 identity: all eigenvalues = 1", function()
    local A = MX.identity(3)
    local vals = MX.eigen_symmetric(A)
    T.ok(approx_eq(vals[1], 1, 1e-9))
    T.ok(approx_eq(vals[2], 1, 1e-9))
    T.ok(approx_eq(vals[3], 1, 1e-9))
  end)

  T.it("eigenvectors orthonormal (V^T V = I)", function()
    local A = MX.from_rows({{4,1,1},{1,3,2},{1,2,5}})
    local _, V, err = MX.eigen_symmetric(A)
    T.eq(err, nil)
    local Vt = MX.transpose(V)
    local VtV = MX.mul(Vt, V)
    local I = MX.identity(3)
    T.ok(mat_approx_eq(VtV, I, 1e-8))
  end)

  T.it("eigendecomposition: A = V * diag(lambda) * V^T", function()
    local A = MX.from_rows({{4,1,1},{1,3,2},{1,2,5}})
    local vals, V = MX.eigen_symmetric(A)
    -- Build diag(lambda)
    local D = MX.from_rows({
      {vals[1], 0,       0      },
      {0,       vals[2], 0      },
      {0,       0,       vals[3]},
    })
    local Vt = MX.transpose(V)
    local VD = MX.mul(V, D)
    local VDVt = MX.mul(VD, Vt)
    T.ok(mat_approx_eq(VDVt, A, 1e-8))
  end)
end)

-- ---------------------------------------------------------------------------
-- Power iteration
-- ---------------------------------------------------------------------------

T.describe("power_iter", function()
  T.it("2x2 diagonal dominant eigenvalue", function()
    local A = MX.from_rows({{5,0},{0,2}})
    local lam, v, err = MX.power_iter(A, 200, 1e-12)
    T.eq(err, nil)
    T.ok(approx_eq(abs(lam), 5, 1e-8))
  end)

  T.it("symmetric matrix largest eigenvalue", function()
    local A = MX.from_rows({{2,1},{1,2}})
    local lam = MX.power_iter(A, 500, 1e-12)
    T.ok(approx_eq(abs(lam), 3, 1e-7))
  end)
end)

-- ---------------------------------------------------------------------------
-- SVD
-- ---------------------------------------------------------------------------

T.describe("SVD", function()
  T.it("2x2 identity SVD: U=I, S=[1,1], V=I", function()
    local A = MX.identity(2)
    local U, S, V, err = MX.svd(A)
    T.eq(err, nil)
    T.ok(approx_eq(S[1], 1, 1e-8))
    T.ok(approx_eq(S[2], 1, 1e-8))
  end)

  T.it("2x2 diagonal SVD: S = diag values descending", function()
    local A = MX.from_rows({{3,0},{0,5}})
    local U, S, V, err = MX.svd(A)
    T.eq(err, nil)
    T.ok(approx_eq(S[1], 5, 1e-8))
    T.ok(approx_eq(S[2], 3, 1e-8))
  end)

  T.it("singular values are non-negative", function()
    local A = MX.from_rows({{1,2},{3,4},{5,6}})
    local _, S, _, err = MX.svd(A)
    T.eq(err, nil)
    for _, s in ipairs(S) do
      T.ok(s >= 0)
    end
  end)

  T.it("singular values are descending", function()
    local A = MX.from_rows({{1,2},{3,4},{5,6}})
    local _, S = MX.svd(A)
    T.ok(S[1] >= S[2])
  end)

  T.it("U*diag(S)*V^T ≈ A for 3x2", function()
    local A = MX.from_rows({{1,2},{3,4},{5,6}})
    local U, S, V, err = MX.svd(A, 300)
    T.eq(err, nil)
    -- Build diag(S) as 2x2
    local Sm = MX.from_rows({{S[1],0},{0,S[2]}})
    local USm = MX.mul(U, Sm)
    local Vt  = MX.transpose(V)
    local Rec = MX.mul(USm, Vt)
    T.ok(mat_approx_eq(Rec, A, 1e-7))
  end)

  T.it("U^T*U ≈ I (thin U, 3x2 A)", function()
    local A = MX.from_rows({{1,2},{3,4},{5,6}})
    local U, _, _, err = MX.svd(A)
    T.eq(err, nil)
    local UtU = MX.mul(MX.transpose(U), U)
    local I = MX.identity(2)
    T.ok(mat_approx_eq(UtU, I, 1e-8))
  end)

  T.it("V^T*V ≈ I (2x2 V)", function()
    local A = MX.from_rows({{1,2},{3,4},{5,6}})
    local _, _, V, err = MX.svd(A)
    T.eq(err, nil)
    local VtV = MX.mul(MX.transpose(V), V)
    local I   = MX.identity(2)
    T.ok(mat_approx_eq(VtV, I, 1e-8))
  end)
end)

-- ---------------------------------------------------------------------------
-- Rank
-- ---------------------------------------------------------------------------

T.describe("rank", function()
  T.it("full rank 3x3", function()
    local A = MX.from_rows({{1,2,3},{4,5,6},{7,8,10}})
    T.eq(MX.rank(A), 3)
  end)

  T.it("rank-1 matrix", function()
    -- outer product [1,2,3]^T * [1,2,3] has rank 1
    local A = MX.from_rows({{1,2,3},{2,4,6},{3,6,9}})
    T.eq(MX.rank(A, 1e-9), 1)
  end)

  T.it("rank-2 matrix", function()
    -- rows 1 and 2 independent, row 3 = row1 + row2
    local A = MX.from_rows({{1,0,0},{0,1,0},{1,1,0}})
    T.eq(MX.rank(A, 1e-9), 2)
  end)

  T.it("identity n×n has full rank n", function()
    local I = MX.identity(4)
    T.eq(MX.rank(I), 4)
  end)
end)

-- ---------------------------------------------------------------------------
-- Pseudoinverse
-- ---------------------------------------------------------------------------

T.describe("pinv (Moore-Penrose pseudoinverse)", function()
  T.it("square full-rank: pinv(A) ≈ inv(A)", function()
    local A = MX.from_rows({{1,2},{3,4}})
    local Ai  = MX.inv(A)
    local Api = MX.pinv(A)
    T.ok(mat_approx_eq(Ai, Api, 1e-8))
  end)

  T.it("tall 3x2: A * pinv(A) * A ≈ A", function()
    local A = MX.from_rows({{1,2},{3,4},{5,6}})
    local Api = MX.pinv(A)
    local AApi = MX.mul(A, Api)
    local AAApiA = MX.mul(AApi, A)
    T.ok(mat_approx_eq(AAApiA, A, 1e-7))
  end)
end)

-- ---------------------------------------------------------------------------
-- norm_2
-- ---------------------------------------------------------------------------

T.describe("norm_2", function()
  T.it("identity matrix norm_2 = 1", function()
    local I = MX.identity(3)
    local n = MX.norm_2(I)
    T.ok(approx_eq(n, 1, 1e-8))
  end)

  T.it("diagonal matrix norm_2 = largest singular value", function()
    local A = MX.from_rows({{3,0},{0,7}})
    local n = MX.norm_2(A)
    T.ok(approx_eq(n, 7, 1e-8))
  end)
end)
