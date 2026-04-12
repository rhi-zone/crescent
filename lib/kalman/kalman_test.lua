if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local K = require("lib.kalman")
local mat = K.mat

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function approx(a, b, tol)
  tol = tol or 1e-9
  return math.abs(a - b) <= tol
end

-- Frobenius-norm distance between two matrices
local function mat_close(A, B, tol)
  tol = tol or 1e-9
  for i = 1, #A do
    for j = 1, #A[i] do
      if math.abs(A[i][j] - B[i][j]) > tol then return false end
    end
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Matrix utility tests
-- ---------------------------------------------------------------------------

T.describe("mat.mul", function()
  T.it("multiplies 2x2 matrices", function()
    local A = {{1,2},{3,4}}
    local B = {{5,6},{7,8}}
    local C = mat.mul(A, B)
    -- [1*5+2*7, 1*6+2*8] = [19, 22]
    -- [3*5+4*7, 3*6+4*8] = [43, 50]
    T.eq(C[1][1], 19)
    T.eq(C[1][2], 22)
    T.eq(C[2][1], 43)
    T.eq(C[2][2], 50)
  end)

  T.it("multiplies non-square matrices (2x3) * (3x2)", function()
    local A = {{1,2,3},{4,5,6}}
    local B = {{7,8},{9,10},{11,12}}
    local C = mat.mul(A, B)
    T.eq(C[1][1], 58)   -- 1*7+2*9+3*11
    T.eq(C[1][2], 64)   -- 1*8+2*10+3*12
    T.eq(C[2][1], 139)
    T.eq(C[2][2], 154)
  end)

  T.it("identity times matrix gives same matrix", function()
    local I = mat.eye(3)
    local A = {{1,2,3},{4,5,6},{7,8,9}}
    local IA = mat.mul(I, A)
    T.ok(mat_close(IA, A), "I*A == A")
  end)
end)

T.describe("mat.T (transpose)", function()
  T.it("transposes 2x3 to 3x2", function()
    local A = {{1,2,3},{4,5,6}}
    local At = mat.T(A)
    T.eq(#At, 3)
    T.eq(#At[1], 2)
    T.eq(At[1][1], 1)
    T.eq(At[1][2], 4)
    T.eq(At[2][1], 2)
    T.eq(At[2][2], 5)
    T.eq(At[3][1], 3)
    T.eq(At[3][2], 6)
  end)

  T.it("double transpose returns original", function()
    local A = {{1,2},{3,4},{5,6}}
    T.ok(mat_close(mat.T(mat.T(A)), A), "(Aᵀ)ᵀ == A")
  end)
end)

T.describe("mat.add", function()
  T.it("adds two matrices element-wise", function()
    local A = {{1,2},{3,4}}
    local B = {{5,6},{7,8}}
    local C = mat.add(A, B)
    T.eq(C[1][1], 6)
    T.eq(C[1][2], 8)
    T.eq(C[2][1], 10)
    T.eq(C[2][2], 12)
  end)
end)

T.describe("mat.sub", function()
  T.it("subtracts two matrices element-wise", function()
    local A = {{5,6},{7,8}}
    local B = {{1,2},{3,4}}
    local C = mat.sub(A, B)
    T.eq(C[1][1], 4)
    T.eq(C[1][2], 4)
    T.eq(C[2][1], 4)
    T.eq(C[2][2], 4)
  end)
end)

T.describe("mat.inv", function()
  T.it("inverts 2x2 identity -> identity", function()
    local I = mat.eye(2)
    local inv = mat.inv(I)
    T.ok(mat_close(inv, I, 1e-12), "inv(I) == I")
  end)

  T.it("A * inv(A) ≈ I for 2x2", function()
    local A = {{4,7},{2,6}}
    local Ai = mat.inv(A)
    local prod = mat.mul(A, Ai)
    local I = mat.eye(2)
    T.ok(mat_close(prod, I, 1e-12), "A * A⁻¹ ≈ I")
  end)

  T.it("A * inv(A) ≈ I for 3x3", function()
    local A = {{2,1,3},{1,3,2},{3,2,1}}
    local Ai = mat.inv(A)
    T.ok(Ai ~= nil, "matrix is invertible")
    local prod = mat.mul(A, Ai)
    local I = mat.eye(3)
    T.ok(mat_close(prod, I, 1e-12), "A * A⁻¹ ≈ I (3x3)")
  end)

  T.it("returns nil for singular matrix", function()
    local S = {{1,2},{2,4}}
    local inv, err = mat.inv(S)
    T.eq(inv, nil)
    T.ok(err ~= nil, "error message present")
  end)

  T.it("inv(A) * A ≈ I for 2x2", function()
    local A = {{3,1},{2,5}}
    local Ai = mat.inv(A)
    local prod = mat.mul(Ai, A)
    T.ok(mat_close(prod, mat.eye(2), 1e-12), "A⁻¹ * A ≈ I")
  end)
end)

T.describe("mat.mulv", function()
  T.it("multiplies matrix by vector", function()
    local A = {{1,2},{3,4}}
    local v = {5, 6}
    local r = mat.mulv(A, v)
    T.eq(r[1], 17)  -- 1*5+2*6
    T.eq(r[2], 39)  -- 3*5+4*6
  end)
end)

-- ---------------------------------------------------------------------------
-- Scalar Kalman filter tests
-- ---------------------------------------------------------------------------

T.describe("K.scalar: basic structure", function()
  T.it("returns a filter with initial defaults", function()
    local kf = K.scalar()
    T.eq(kf:value(), 0)
    T.ok(kf:variance() > 0, "initial variance > 0")
  end)

  T.it("respects initial_value and initial_variance", function()
    local kf = K.scalar({ initial_value = 10, initial_variance = 0.5 })
    T.eq(kf:value(), 10)
    T.eq(kf:variance(), 0.5)
  end)
end)

T.describe("K.scalar: convergence to true value", function()
  T.it("converges toward 5.0 after many noisy measurements", function()
    local kf = K.scalar({
      process_noise = 1e-5,
      measurement_noise = 0.1,
      initial_value = 0,
      initial_variance = 1,
    })
    math.randomseed(42)
    for _ = 1, 200 do
      local z = 5.0 + (math.random() - 0.5) * 0.6  -- noise ~ uniform [-0.3, 0.3]
      kf:update(z)
    end
    T.ok(math.abs(kf:value() - 5.0) < 0.1, "estimate converged to ~5.0 (got " .. kf:value() .. ")")
  end)

  T.it("variance decreases with more measurements", function()
    local kf = K.scalar({ process_noise = 1e-5, measurement_noise = 0.1 })
    local v0 = kf:variance()
    kf:update(1.0)
    local v1 = kf:variance()
    kf:update(1.0)
    local v2 = kf:variance()
    T.ok(v1 < v0, "variance decreases after first update")
    T.ok(v2 < v1, "variance decreases after second update")
  end)

  T.it("update returns {value, variance} table", function()
    local kf = K.scalar()
    local result = kf:update(3.0)
    T.ok(type(result) == "table", "update returns table")
    T.ok(type(result[1]) == "number", "result[1] is number (value)")
    T.ok(type(result[2]) == "number", "result[2] is number (variance)")
  end)
end)

T.describe("K.scalar: predict-only mode", function()
  T.it("predict does not change value", function()
    local kf = K.scalar({ initial_value = 7.0, process_noise = 1e-5 })
    local before = kf:value()
    kf:predict()
    T.eq(kf:value(), before)
  end)

  T.it("predict increases variance by Q", function()
    local Q = 1e-4
    local kf = K.scalar({ process_noise = Q, initial_variance = 0.5 })
    local P_before = kf:variance()
    kf:predict()
    T.ok(approx(kf:variance(), P_before + Q, 1e-15), "P increases by Q on predict")
  end)

  T.it("predict returns {value, variance}", function()
    local kf = K.scalar()
    local r = kf:predict()
    T.ok(type(r) == "table", "predict returns table")
    T.ok(type(r[1]) == "number", "r[1] is number")
    T.ok(type(r[2]) == "number", "r[2] is number")
  end)
end)

T.describe("K.scalar: noise sensitivity", function()
  T.it("low measurement noise -> fast convergence", function()
    local kf = K.scalar({ measurement_noise = 1e-6, initial_value = 0, initial_variance = 1 })
    kf:update(10.0)
    T.ok(math.abs(kf:value() - 10.0) < 0.1, "fast convergence with low R")
  end)

  T.it("high measurement noise -> slow convergence", function()
    local kf = K.scalar({ measurement_noise = 1e6, initial_value = 0, initial_variance = 1 })
    kf:update(10.0)
    -- With huge R, estimate barely moves
    T.ok(math.abs(kf:value()) < 1.0, "slow convergence with high R")
  end)
end)

-- ---------------------------------------------------------------------------
-- Multivariate Kalman filter tests
-- ---------------------------------------------------------------------------

T.describe("K.multivariate: 1D position tracking", function()
  -- State: [position], F=[[1]], H=[[1]]
  T.it("converges toward true position 3.0", function()
    local mkf = K.multivariate({
      F  = { {1} },
      H  = { {1} },
      Q  = { {1e-4} },
      R  = { {0.1} },
      x0 = { 0 },
      P0 = { {1} },
    })
    math.randomseed(7)
    for _ = 1, 100 do
      local z = 3.0 + (math.random() - 0.5) * 0.6
      mkf:update({z})
    end
    local s = mkf:state()
    T.ok(math.abs(s[1] - 3.0) < 0.2, "converged to ~3.0 (got " .. s[1] .. ")")
  end)

  T.it("state() returns array of correct length", function()
    local mkf = K.multivariate({
      F  = { {1,0},{0,1} },
      H  = { {1,0} },
      Q  = { {1e-4,0},{0,1e-4} },
      R  = { {0.1} },
      x0 = { 0, 0 },
      P0 = { {1,0},{0,1} },
    })
    local s = mkf:state()
    T.eq(#s, 2)
  end)

  T.it("covariance() returns n×n matrix", function()
    local mkf = K.multivariate({
      F  = { {1,0},{0,1} },
      H  = { {1,0} },
      Q  = { {1e-4,0},{0,1e-4} },
      R  = { {0.1} },
      x0 = { 0, 0 },
      P0 = { {1,0},{0,1} },
    })
    local P = mkf:covariance()
    T.eq(#P, 2)
    T.eq(#P[1], 2)
  end)

  T.it("predict only returns state array", function()
    local mkf = K.multivariate({
      F  = { {1,0},{0,1} },
      H  = { {1,0} },
      Q  = { {1e-4,0},{0,1e-4} },
      R  = { {0.1} },
      x0 = { 2, 0 },
      P0 = { {1,0},{0,1} },
    })
    local s = mkf:predict()
    T.ok(type(s) == "table", "predict returns table")
    T.eq(#s, 2)
  end)

  T.it("returns error on missing required opts", function()
    local mkf, err = K.multivariate({})
    T.eq(mkf, nil)
    T.ok(err ~= nil, "error message present")
  end)
end)

-- ---------------------------------------------------------------------------
-- Tracker1d tests
-- ---------------------------------------------------------------------------

T.describe("K.tracker1d: 2D state (position, velocity)", function()
  T.it("tracks a stationary target", function()
    local tr = K.tracker1d({
      process_noise = 1e-4,
      measurement_noise = 0.5,
      dt = 1,
      initial_position = 0,
    })
    math.randomseed(123)
    for _ = 1, 100 do
      local z = 10.0 + (math.random() - 0.5) * 1.0
      tr:update({z})
    end
    local s = tr:state()
    T.ok(math.abs(s[1] - 10.0) < 0.5, "position converged to ~10 (got " .. s[1] .. ")")
  end)

  T.it("velocity estimate is near zero for stationary target", function()
    local tr = K.tracker1d({
      process_noise = 1e-5,
      measurement_noise = 0.1,
      dt = 1,
    })
    math.randomseed(99)
    for _ = 1, 200 do
      tr:update({ 5.0 + (math.random() - 0.5) * 0.2 })
    end
    local s = tr:state()
    T.ok(math.abs(s[2]) < 0.5, "velocity near 0 for stationary (got " .. s[2] .. ")")
  end)

  T.it("tracks a linearly moving target", function()
    -- True model: pos = 2*k, vel = 2 (dt=1)
    local tr = K.tracker1d({
      process_noise = 1e-3,
      measurement_noise = 0.5,
      dt = 1,
      initial_position = 0,
      initial_velocity = 0,
    })
    math.randomseed(55)
    local true_pos = 0
    for _ = 1, 100 do
      true_pos = true_pos + 2
      tr:update({ true_pos + (math.random() - 0.5) * 1.0 })
    end
    local s = tr:state()
    -- After 100 steps, position should be near 200
    T.ok(math.abs(s[1] - 200) < 5, "position tracks linear motion (got " .. s[1] .. ")")
    T.ok(math.abs(s[2] - 2.0) < 0.5, "velocity converged to ~2 (got " .. s[2] .. ")")
  end)

  T.it("state has 2 elements (position, velocity)", function()
    local tr = K.tracker1d()
    local s = tr:state()
    T.eq(#s, 2)
  end)

  T.it("covariance is 2x2", function()
    local tr = K.tracker1d()
    local P = tr:covariance()
    T.eq(#P, 2)
    T.eq(#P[1], 2)
  end)
end)

-- ---------------------------------------------------------------------------
-- Extended Kalman Filter tests
-- ---------------------------------------------------------------------------

T.describe("K.extended: nonlinear measurement h(x) = x²", function()
  -- State: [x] (scalar), f(x) = x (constant model)
  -- h(x) = x² → Jh = [[2x]]
  -- We measure z = x_true² + noise, true state x_true = 3.0

  local function make_ekf_square(x0)
    return K.extended({
      f  = function(x) return { x[1] } end,
      Jf = function(_x) return { {1} } end,
      h  = function(x) return { x[1] * x[1] } end,
      Jh = function(x) return { {2 * x[1]} } end,
      Q  = { {1e-4} },
      R  = { {0.5} },
      x0 = { x0 },
      P0 = { {1} },
    })
  end

  T.it("state() returns array of length 1", function()
    local ekf = make_ekf_square(1.0)
    local s = ekf:state()
    T.eq(#s, 1)
  end)

  T.it("converges toward true state x=3 when measuring z=x²", function()
    local ekf = make_ekf_square(1.0)
    math.randomseed(77)
    local true_x = 3.0
    for _ = 1, 200 do
      local z = true_x * true_x + (math.random() - 0.5) * 1.0
      ekf:update({z})
    end
    local s = ekf:state()
    T.ok(math.abs(s[1] - true_x) < 0.5, "EKF converged near x=3 (got " .. s[1] .. ")")
  end)

  T.it("predict only does not break state", function()
    local ekf = make_ekf_square(2.0)
    local before = ekf:state()
    ekf:predict()
    local after = ekf:state()
    -- f(x)=x, so state should be unchanged (constant model)
    T.ok(approx(after[1], before[1], 1e-12), "predict with f(x)=x preserves state")
  end)

  T.it("returns error on missing opts", function()
    local ekf, err = K.extended({})
    T.eq(ekf, nil)
    T.ok(err ~= nil, "error message present")
  end)
end)

T.describe("K.extended: linear system matches multivariate", function()
  -- When f and h are linear, EKF should behave like standard KF.
  -- State: [pos, vel], f(x) = F*x, h(x) = H*x
  -- F = [[1,1],[0,1]], H = [[1,0]]
  T.it("linear EKF update is close to multivariate KF", function()
    local F_mat = { {1, 1}, {0, 1} }
    local H_mat = { {1, 0} }
    local Q = { {1e-4, 0}, {0, 1e-4} }
    local R = { {0.1} }
    local x0 = {0, 0}
    local P0 = { {1, 0}, {0, 1} }

    local mkf = K.multivariate({ F=F_mat, H=H_mat, Q=Q, R=R, x0=x0, P0=P0 })
    local ekf = K.extended({
      f  = function(x) return mat.mulv(F_mat, x) end,
      Jf = function(_x) return mat.copy(F_mat) end,
      h  = function(x) return mat.mulv(H_mat, x) end,
      Jh = function(_x) return mat.copy(H_mat) end,
      Q=Q, R=R, x0=x0, P0=P0,
    })

    math.randomseed(31)
    for i = 1, 20 do
      local z = {i * 1.0 + (math.random() - 0.5) * 0.2}
      mkf:update(z)
      ekf:update(z)
    end

    local ms = mkf:state()
    local es = ekf:state()
    T.ok(approx(ms[1], es[1], 1e-9), "position matches (multi=" .. ms[1] .. " ekf=" .. es[1] .. ")")
    T.ok(approx(ms[2], es[2], 1e-9), "velocity matches (multi=" .. ms[2] .. " ekf=" .. es[2] .. ")")
  end)
end)

-- ---------------------------------------------------------------------------
-- Additional edge cases
-- ---------------------------------------------------------------------------

T.describe("edge cases", function()
  T.it("scalar: predict-only does not add measurement noise", function()
    local kf = K.scalar({ process_noise = 1e-3, measurement_noise = 1.0, initial_variance = 0.1 })
    kf:predict()
    -- Variance should only increase by Q, not R
    T.ok(approx(kf:variance(), 0.1 + 1e-3, 1e-14), "variance = P0 + Q after predict")
  end)

  T.it("scalar: value and variance match update return", function()
    local kf = K.scalar()
    local r = kf:update(5.0)
    T.eq(r[1], kf:value())
    T.eq(r[2], kf:variance())
  end)

  T.it("mat.scale multiplies all elements", function()
    local A = {{1,2},{3,4}}
    local B = mat.scale(A, 3)
    T.eq(B[1][1], 3)
    T.eq(B[1][2], 6)
    T.eq(B[2][1], 9)
    T.eq(B[2][2], 12)
  end)

  T.it("mat.eye creates correct identity", function()
    local I = mat.eye(3)
    for i = 1, 3 do
      for j = 1, 3 do
        T.eq(I[i][j], (i == j) and 1 or 0)
      end
    end
  end)

  T.it("mat.zeros creates all-zero matrix", function()
    local Z = mat.zeros(2, 3)
    T.eq(#Z, 2)
    T.eq(#Z[1], 3)
    for i = 1, 2 do
      for j = 1, 3 do
        T.eq(Z[i][j], 0)
      end
    end
  end)

  T.it("M._tier is 'pure'", function()
    T.eq(K._tier, "pure")
  end)

  T.it("multivariate: repeated predict increases uncertainty", function()
    local mkf = K.multivariate({
      F  = { {1} },
      H  = { {1} },
      Q  = { {1e-3} },
      R  = { {0.1} },
      x0 = { 0 },
      P0 = { {0.5} },
    })
    local P0 = mkf:covariance()[1][1]
    mkf:predict()
    local P1 = mkf:covariance()[1][1]
    mkf:predict()
    local P2 = mkf:covariance()[1][1]
    T.ok(P1 > P0, "covariance grows on predict (1)")
    T.ok(P2 > P1, "covariance grows on predict (2)")
  end)
end)
