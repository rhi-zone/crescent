if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Matrix utilities (inline, self-contained)
-- All matrices represented as arrays of row-arrays.
-- ---------------------------------------------------------------------------

--:: Matrix = number[][]
--:: Vector = number[]

local mat = {}

-- Create n×m zero matrix
--: (integer, integer) -> Matrix
function mat.zeros(n, m)
  local r = {}
  for i = 1, n do
    r[i] = {}
    for j = 1, m do r[i][j] = 0 end
  end
  return r
end

-- Identity matrix n×n
--: (integer) -> Matrix
function mat.eye(n)
  local r = mat.zeros(n, n)
  for i = 1, n do r[i][i] = 1 end
  return r
end

-- Deep copy a matrix
--: (Matrix) -> Matrix
function mat.copy(A)
  local r = {}
  for i = 1, #A do
    r[i] = {}
    for j = 1, #A[i] do r[i][j] = A[i][j] end
  end
  return r
end

-- Matrix multiply: A (n×k) * B (k×m) -> n×m
--: (Matrix, Matrix) -> Matrix
function mat.mul(A, B)
  local n, k, m = #A, #B, #B[1]
  local r = mat.zeros(n, m)
  for i = 1, n do
    for l = 1, k do
      local a = A[i][l]
      if a ~= 0 then
        for j = 1, m do
          r[i][j] = r[i][j] + a * B[l][j]
        end
      end
    end
  end
  return r
end

-- Matrix add: A + B (same dims)
--: (Matrix, Matrix) -> Matrix
function mat.add(A, B)
  local n, m = #A, #A[1]
  local r = mat.zeros(n, m)
  for i = 1, n do
    for j = 1, m do r[i][j] = A[i][j] + B[i][j] end
  end
  return r
end

-- Matrix subtract: A - B (same dims)
--: (Matrix, Matrix) -> Matrix
function mat.sub(A, B)
  local n, m = #A, #A[1]
  local r = mat.zeros(n, m)
  for i = 1, n do
    for j = 1, m do r[i][j] = A[i][j] - B[i][j] end
  end
  return r
end

-- Transpose: A (n×m) -> m×n
--: (Matrix) -> Matrix
function mat.T(A)
  local n, m = #A, #A[1]
  local r = mat.zeros(m, n)
  for i = 1, n do
    for j = 1, m do r[j][i] = A[i][j] end
  end
  return r
end

-- Scalar multiply
--: (Matrix, number) -> Matrix
function mat.scale(A, s)
  local n, m = #A, #A[1]
  local r = mat.zeros(n, m)
  for i = 1, n do
    for j = 1, m do r[i][j] = A[i][j] * s end
  end
  return r
end

-- Invert square matrix using Gaussian elimination with partial pivoting.
-- Returns inverted matrix, or (nil, errmsg) if singular.
--: (Matrix) -> (Matrix | nil, string | nil)
function mat.inv(A)
  local n = #A
  -- Augment [A | I]
  local aug --[[: Matrix]] = {}
  for i = 1, n do
    aug[i] = {}
    for j = 1, n do aug[i][j] = A[i][j] end
    for j = 1, n do aug[i][n + j] = (i == j) and 1 or 0 end
  end
  for col = 1, n do
    -- Find pivot
    local pivot_row --: integer | nil
    local pivot_val = 0.0 --: number
    for row = col, n do
      local v = aug[row][col]
      if v < 0 then v = -v end
      if v > pivot_val then
        pivot_val = v
        pivot_row = row
      end
    end
    if pivot_row == nil or pivot_val < 1e-15 then
      return nil, "singular matrix"
    end
    -- Swap rows
    if pivot_row ~= col then
      aug[col], aug[pivot_row] = aug[pivot_row], aug[col]
    end
    -- Scale pivot row
    local inv_pivot = 1 / aug[col][col]
    for j = 1, 2 * n do aug[col][j] = aug[col][j] * inv_pivot end
    -- Eliminate column
    for row = 1, n do
      if row ~= col then
        local factor = aug[row][col]
        if factor ~= 0 then
          for j = 1, 2 * n do
            aug[row][j] = aug[row][j] - factor * aug[col][j]
          end
        end
      end
    end
  end
  -- Extract right half
  local inv = mat.zeros(n, n)
  for i = 1, n do
    for j = 1, n do inv[i][j] = aug[i][n + j] end
  end
  return inv
end

-- Matrix-vector multiply: A (n×m) * v (m-element array) -> n-element array
--: (Matrix, Vector) -> Vector
function mat.mulv(A, v)
  local n, m = #A, #v
  local r = {}
  for i = 1, n do
    local s = 0.0 --: number
    for j = 1, m do s = s + A[i][j] * v[j] end
    r[i] = s
  end
  return r
end

-- Outer product: u (n) * vT (m) -> n×m
--: (Vector, Vector) -> Matrix
function mat.outer(u, v)
  local n, m = #u, #v
  local r = mat.zeros(n, m)
  for i = 1, n do
    for j = 1, m do r[i][j] = u[i] * v[j] end
  end
  return r
end

-- Vector subtract: a - b
--: (Vector, Vector) -> Vector
local function vec_sub(a, b)
  local r = {}
  for i = 1, #a do r[i] = a[i] - b[i] end
  return r
end

-- Vector add: a + b
--: (Vector, Vector) -> Vector
local function vec_add(a, b)
  local r = {}
  for i = 1, #a do r[i] = a[i] + b[i] end
  return r
end

M.mat = mat

-- ---------------------------------------------------------------------------
-- Scalar (1D) Kalman filter
-- ---------------------------------------------------------------------------
-- Models a constant signal with additive Gaussian noise.
--
-- State: scalar x̂ (estimate), P (variance)
-- Predict: x̂⁻ = x̂,  P⁻ = P + Q
-- Update:  K = P⁻ / (P⁻ + R);  x̂ = x̂⁻ + K*(z - x̂⁻);  P = (1-K)*P⁻

local Scalar = {}
Scalar.__index = Scalar

function M.scalar(opts)
  opts = opts or {}
  local self = setmetatable({}, Scalar)
  self._Q  = opts.process_noise      or 1e-5
  self._R  = opts.measurement_noise  or 1e-2
  self._x  = opts.initial_value      or 0
  self._P  = opts.initial_variance   or 1
  return self
end

-- Predict step only (no measurement). Returns {value, variance}.
function Scalar:predict()
  self._P = self._P + self._Q
  return { self._x, self._P }
end

-- Predict + update with measurement z. Returns {value, variance}.
function Scalar:update(z)
  -- Predict
  local P_minus = self._P + self._Q
  -- Update
  local K = P_minus / (P_minus + self._R)
  self._x = self._x + K * (z - self._x)
  self._P = (1 - K) * P_minus
  return { self._x, self._P }
end

function Scalar:value()    return self._x end
function Scalar:variance() return self._P end

-- ---------------------------------------------------------------------------
-- Multivariate Kalman filter
-- ---------------------------------------------------------------------------
-- Standard linear Kalman filter equations:
--
-- Predict:
--   x̂⁻ = F * x̂
--   P⁻  = F * P * Fᵀ + Q
--
-- Update:
--   S  = H * P⁻ * Hᵀ + R
--   K  = P⁻ * Hᵀ * S⁻¹
--   x̂  = x̂⁻ + K * (z - H * x̂⁻)
--   P  = (I - K * H) * P⁻

--:: MultiSelf = { _F: Matrix, _H: Matrix, _Q: Matrix, _R: Matrix, _x: Vector, _P: Matrix, _n: integer, _I: Matrix, ... }
local Multi = {}
Multi.__index = Multi

--: ({ F: Matrix, H: Matrix, Q: Matrix, R: Matrix, x0: Vector, P0: Matrix } | nil) -> (MultiSelf | nil, string | nil)
function M.multivariate(opts)
  if not opts or not opts.F then
    return nil, "opts.F (state transition matrix) required"
  end
  if not opts.H then return nil, "opts.H (observation matrix) required" end
  if not opts.Q then return nil, "opts.Q (process noise covariance) required" end
  if not opts.R then return nil, "opts.R (observation noise covariance) required" end
  if not opts.x0 then return nil, "opts.x0 (initial state vector) required" end
  if not opts.P0 then return nil, "opts.P0 (initial covariance) required" end

  local n = #opts.x0
  local x = {}
  for i = 1, n do x[i] = opts.x0[i] end
  local self --[[: MultiSelf]] = setmetatable({
    _F = opts.F,
    _H = opts.H,
    _Q = opts.Q,
    _R = opts.R,
    _x = x,
    _P = mat.copy(opts.P0),
    _n = n,
    _I = mat.eye(n),
  }, Multi)
  return self
end

-- Predict step. Returns predicted state array (copy).
--: (self: MultiSelf) -> Vector
function Multi:predict()
  self._x = mat.mulv(self._F, self._x)
  -- P⁻ = F P Fᵀ + Q
  self._P = mat.add(mat.mul(mat.mul(self._F, self._P), mat.T(self._F)), self._Q)
  local r = {}
  for i = 1, self._n do r[i] = self._x[i] end
  return r
end

-- Predict + update with measurement vector z (m-element array).
-- Returns current state array (copy).
--: (self: MultiSelf, z: Vector) -> (Vector | nil, string | nil)
function Multi:update(z)
  -- Predict
  self._x = mat.mulv(self._F, self._x)
  local FT = mat.T(self._F)
  self._P = mat.add(mat.mul(mat.mul(self._F, self._P), FT), self._Q)
  -- Innovation: y = z - H*x̂⁻
  local Hx = mat.mulv(self._H, self._x)
  local y = vec_sub(z, Hx)
  -- Innovation covariance: S = H*P⁻*Hᵀ + R
  local HT = mat.T(self._H)
  local S = mat.add(mat.mul(mat.mul(self._H, self._P), HT), self._R)
  -- Kalman gain: K = P⁻ * Hᵀ * S⁻¹
  local S_inv, err = mat.inv(S)
  if not S_inv then return nil, "singular innovation covariance: " .. tostring(err) end
  local K = mat.mul(mat.mul(self._P, HT), S_inv)
  -- State update: x̂ = x̂⁻ + K * y
  local Ky = mat.mulv(K, y)
  self._x = vec_add(self._x, Ky)
  -- Covariance update: P = (I - K*H) * P⁻
  self._P = mat.mul(mat.sub(self._I, mat.mul(K, self._H)), self._P)
  local r = {}
  for i = 1, self._n do r[i] = self._x[i] end
  return r
end

--: (self: MultiSelf) -> Vector
function Multi:state()
  local r = {}
  for i = 1, self._n do r[i] = self._x[i] end
  return r
end

--: (self: MultiSelf) -> Matrix
function Multi:covariance()
  return mat.copy(self._P)
end

-- ---------------------------------------------------------------------------
-- Extended Kalman Filter (EKF)
-- ---------------------------------------------------------------------------
-- For nonlinear systems:
--   x_{k+1} = f(x_k) + process noise
--   z_k     = h(x_k) + measurement noise
--
-- Predict:
--   x̂⁻ = f(x̂)
--   P⁻  = Jf(x̂) * P * Jf(x̂)ᵀ + Q
--
-- Update:
--   S  = Jh(x̂⁻) * P⁻ * Jh(x̂⁻)ᵀ + R
--   K  = P⁻ * Jh(x̂⁻)ᵀ * S⁻¹
--   x̂  = x̂⁻ + K * (z - h(x̂⁻))
--   P  = (I - K * Jh(x̂⁻)) * P⁻

--:: ExtendedSelf = { _f: (Vector) -> Vector, _Jf: (Vector) -> Matrix, _h: (Vector) -> Vector, _Jh: (Vector) -> Matrix, _Q: Matrix, _R: Matrix, _x: Vector, _P: Matrix, _n: integer, _I: Matrix, ... }
local Extended = {}
Extended.__index = Extended

--: ({ f: (Vector) -> Vector, Jf: (Vector) -> Matrix, h: (Vector) -> Vector, Jh: (Vector) -> Matrix, Q: Matrix, R: Matrix, x0: Vector, P0: Matrix } | nil) -> (ExtendedSelf | nil, string | nil)
function M.extended(opts)
  if not opts or not opts.f  then return nil, "opts.f required" end
  if not opts.Jf then return nil, "opts.Jf required" end
  if not opts.h  then return nil, "opts.h required" end
  if not opts.Jh then return nil, "opts.Jh required" end
  if not opts.Q  then return nil, "opts.Q required" end
  if not opts.R  then return nil, "opts.R required" end
  if not opts.x0 then return nil, "opts.x0 required" end
  if not opts.P0 then return nil, "opts.P0 required" end

  local n = #opts.x0
  local x = {}
  for i = 1, n do x[i] = opts.x0[i] end
  local self --[[: ExtendedSelf]] = setmetatable({
    _f = opts.f,
    _Jf = opts.Jf,
    _h = opts.h,
    _Jh = opts.Jh,
    _Q = opts.Q,
    _R = opts.R,
    _x = x,
    _P = mat.copy(opts.P0),
    _n = n,
    _I = mat.eye(n),
  }, Extended)
  return self
end

-- Predict step. Returns predicted state array.
--: (self: ExtendedSelf) -> Vector
function Extended:predict()
  local Jf = self._Jf(self._x)
  self._x = self._f(self._x)
  self._P = mat.add(mat.mul(mat.mul(Jf, self._P), mat.T(Jf)), self._Q)
  local r = {}
  for i = 1, self._n do r[i] = self._x[i] end
  return r
end

-- Predict + update. Returns state array.
--: (self: ExtendedSelf, z: Vector) -> (Vector | nil, string | nil)
function Extended:update(z)
  -- Predict
  local Jf = self._Jf(self._x)
  self._x = self._f(self._x)
  self._P = mat.add(mat.mul(mat.mul(Jf, self._P), mat.T(Jf)), self._Q)
  -- Update
  local Jh = self._Jh(self._x)
  local JhT = mat.T(Jh)
  local S = mat.add(mat.mul(mat.mul(Jh, self._P), JhT), self._R)
  local S_inv, err = mat.inv(S)
  if not S_inv then return nil, "singular S: " .. tostring(err) end
  local K = mat.mul(mat.mul(self._P, JhT), S_inv)
  -- Innovation: z - h(x̂⁻)
  local hx = self._h(self._x)
  -- z and hx are arrays
  local y = vec_sub(z, hx)
  local Ky = mat.mulv(K, y)
  self._x = vec_add(self._x, Ky)
  self._P = mat.mul(mat.sub(self._I, mat.mul(K, Jh)), self._P)
  local r = {}
  for i = 1, self._n do r[i] = self._x[i] end
  return r
end

--: (self: ExtendedSelf) -> Vector
function Extended:state()
  local r = {}
  for i = 1, self._n do r[i] = self._x[i] end
  return r
end

-- ---------------------------------------------------------------------------
-- Tracker1d convenience constructor
-- ---------------------------------------------------------------------------
-- 2D state: [position, velocity]
-- F = [[1, dt], [0, 1]]   (constant velocity)
-- H = [[1, 0]]            (observe position only)
-- Q = [[q*dt³/3, q*dt²/2], [q*dt²/2, q*dt]]
-- R = [[r]]

function M.tracker1d(opts)
  opts = opts or {}
  local q  = opts.process_noise     or 1e-5
  local r  = opts.measurement_noise or 1e-2
  local dt = opts.dt                or 1
  local x0 = opts.initial_position  or 0
  local v0 = opts.initial_velocity  or 0

  local dt2 = dt * dt
  local dt3 = dt2 * dt

  return M.multivariate({
    F  = { {1, dt}, {0, 1} },
    H  = { {1, 0} },
    Q  = { {q * dt3 / 3, q * dt2 / 2}, {q * dt2 / 2, q * dt} },
    R  = { {r} },
    x0 = { x0, v0 },
    P0 = { {1, 0}, {0, 1} },
  })
end

return M
