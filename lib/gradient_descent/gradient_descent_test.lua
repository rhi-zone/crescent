-- lib/gradient_descent/gradient_descent_test.lua
-- Tests for lib/gradient_descent

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local GD = require("lib.gradient_descent")

local sqrt = math.sqrt
local abs  = math.abs

-- ---------------------------------------------------------------------------
-- Test functions
-- ---------------------------------------------------------------------------

-- Quadratic: f(x,y) = (x-3)^2 + (y-5)^2, minimum at (3, 5)
local function quad_f(p)
  return (p[1] - 3)^2 + (p[2] - 5)^2
end

local function quad_grad(p)
  return { 2*(p[1] - 3), 2*(p[2] - 5) }
end

-- 1D quadratic: f(x) = x^2, minimum at 0
local function f1d(p)
  return p[1] * p[1]
end

local function grad1d(p)
  return { 2 * p[1] }
end

-- Rosenbrock: f(x,y) = (1-x)^2 + 100*(y-x^2)^2, minimum at (1,1)
local function rosenbrock_f(p)
  local x, y = p[1], p[2]
  return (1 - x)^2 + 100 * (y - x*x)^2
end

local function rosenbrock_grad(p)
  local x, y = p[1], p[2]
  return {
    -2*(1 - x) - 400*x*(y - x*x),
    200*(y - x*x),
  }
end

-- Linear regression: minimize ||Ax - b||^2
-- A = [[1,0],[0,1],[1,1]], b = [1,2,3]  => solution x=[1,2]
local A_mat = {{1,0},{0,1},{1,1}}
local b_vec = {1, 2, 3}

local function linreg_f(params)
  local loss = 0
  for i = 1, #A_mat do
    local row = A_mat[i]
    local r = (row[1]*params[1] + row[2]*params[2]) - b_vec[i]
    loss = loss + r*r
  end
  return loss
end

local function linreg_grad(params)
  local g = {0, 0}
  for i = 1, #A_mat do
    local row = A_mat[i]
    local r = (row[1]*params[1] + row[2]*params[2]) - b_vec[i]
    g[1] = g[1] + 2 * r * row[1]
    g[2] = g[2] + 2 * r * row[2]
  end
  return g
end

-- ---------------------------------------------------------------------------
-- gradient_descent
-- ---------------------------------------------------------------------------

T.describe("gradient_descent", function()
  T.it("converges on quadratic", function()
    local result = GD.gradient_descent(quad_f, quad_grad, {0, 0}, {
      lr = 0.1, max_iter = 2000, tol = 1e-6,
    })
    T.ok(result.converged, "converged flag")
    T.ok(result.loss < 1e-4, "final loss < 1e-4, got " .. result.loss)
    T.ok(abs(result.params[1] - 3) < 0.01, "x near 3")
    T.ok(abs(result.params[2] - 5) < 0.01, "y near 5")
    T.ok(result.iters > 0, "ran at least one iter")
  end)

  T.it("momentum=0.9 converges on quadratic", function()
    local result = GD.gradient_descent(quad_f, quad_grad, {0, 0}, {
      lr = 0.05, max_iter = 2000, tol = 1e-6, momentum = 0.9,
    })
    T.ok(result.converged, "converged with momentum")
    T.ok(result.loss < 1e-4, "final loss < 1e-4, got " .. result.loss)
    T.ok(abs(result.params[1] - 3) < 0.01, "x near 3")
    T.ok(abs(result.params[2] - 5) < 0.01, "y near 5")
  end)

  T.it("converges on 1D quadratic from negative start", function()
    local result = GD.gradient_descent(f1d, grad1d, {-5}, {
      lr = 0.1, max_iter = 1000, tol = 1e-6,
    })
    T.ok(result.converged, "converged")
    T.ok(abs(result.params[1]) < 0.01, "near 0")
    T.ok(result.loss < 1e-4, "small loss")
  end)

  T.it("params already at minimum converges immediately", function()
    local result = GD.gradient_descent(quad_f, quad_grad, {3, 5}, {
      lr = 0.1, max_iter = 1000, tol = 1e-4,
    })
    T.ok(result.converged, "already at minimum, should converge immediately")
    T.ok(result.iters <= 1, "at most 1 iteration, got " .. result.iters)
    T.ok(result.loss < 1e-8, "essentially zero loss")
  end)
end)

-- ---------------------------------------------------------------------------
-- record_history
-- ---------------------------------------------------------------------------

T.describe("record_history", function()
  T.it("history array is populated", function()
    local result = GD.gradient_descent(quad_f, quad_grad, {0, 0}, {
      lr = 0.1, max_iter = 50, tol = 1e-10, record_history = true,
    })
    T.ok(result.history ~= nil, "history not nil")
    T.ok(#result.history >= 1, "at least one history entry")
    local e = result.history[1]
    T.ok(e.iter ~= nil, "entry has iter")
    T.ok(e.loss ~= nil, "entry has loss")
    T.ok(e.grad_norm ~= nil, "entry has grad_norm")
    T.ok(result.history[1].iter == 1, "first entry is iter 1")
    T.ok(#result.history == result.iters, "history length matches iters")
  end)

  T.it("no history when record_history not set", function()
    local result = GD.gradient_descent(quad_f, quad_grad, {0, 0}, {
      lr = 0.1, max_iter = 10,
    })
    T.ok(result.history == nil, "no history by default")
  end)
end)

-- ---------------------------------------------------------------------------
-- callback
-- ---------------------------------------------------------------------------

T.describe("callback", function()
  T.it("is called each iteration", function()
    local call_count = 0
    GD.gradient_descent(quad_f, quad_grad, {0, 0}, {
      lr = 0.1, max_iter = 10, tol = 1e-12,
      callback = function(info)
        call_count = call_count + 1
        T.ok(info.iter ~= nil, "info has iter")
        T.ok(info.loss ~= nil, "info has loss")
        T.ok(info.grad_norm ~= nil, "info has grad_norm")
        T.ok(info.params ~= nil, "info has params")
      end,
    })
    T.ok(call_count == 10, "callback called 10 times, got " .. call_count)
  end)

  T.it("returning false stops early", function()
    local call_count = 0
    local result = GD.gradient_descent(quad_f, quad_grad, {0, 0}, {
      lr = 0.1, max_iter = 1000, tol = 1e-12,
      callback = function(info)
        call_count = call_count + 1
        if info.iter >= 5 then return false end
      end,
    })
    T.ok(call_count == 5, "stopped after 5 calls, got " .. call_count)
    T.ok(result.iters <= 5, "iters <= 5, got " .. result.iters)
    T.ok(not result.converged, "not converged (stopped by callback)")
  end)
end)

-- ---------------------------------------------------------------------------
-- SGD
-- ---------------------------------------------------------------------------

T.describe("sgd", function()
  T.it("n_batches=1 converges on quadratic", function()
    -- grad_batch ignores batch_idx, returns full gradient
    local result = GD.sgd(quad_f, function(p, _) return quad_grad(p) end, {0, 0}, 1, {
      lr = 0.1, epochs = 500, tol = 1e-6,
    })
    T.ok(result.converged, "sgd converged")
    T.ok(result.loss < 1e-4, "final loss < 1e-4, got " .. result.loss)
    T.ok(abs(result.params[1] - 3) < 0.05, "x near 3")
    T.ok(abs(result.params[2] - 5) < 0.05, "y near 5")
  end)

  T.it("momentum=0.5 converges on quadratic", function()
    local result = GD.sgd(quad_f, function(p, _) return quad_grad(p) end, {0, 0}, 1, {
      lr = 0.05, epochs = 500, tol = 1e-6, momentum = 0.5,
    })
    T.ok(result.converged, "sgd with momentum converged")
    T.ok(result.loss < 1e-4, "loss < 1e-4")
  end)

  T.it("lr_decay reduces learning rate", function()
    -- Should still converge (slower), but not diverge
    local result = GD.sgd(quad_f, function(p, _) return quad_grad(p) end, {0, 0}, 1, {
      lr = 0.2, epochs = 1000, tol = 1e-5, lr_decay = 0.01,
    })
    T.ok(result.loss < 0.1, "reasonable final loss with lr_decay")
  end)
end)

-- ---------------------------------------------------------------------------
-- Adam
-- ---------------------------------------------------------------------------

T.describe("adam", function()
  T.it("converges on quadratic", function()
    local result = GD.adam(quad_f, quad_grad, {0, 0}, {
      lr = 0.1, max_iter = 2000, tol = 1e-6,
    })
    T.ok(result.converged, "adam converged")
    T.ok(result.loss < 1e-4, "loss < 1e-4, got " .. result.loss)
    T.ok(abs(result.params[1] - 3) < 0.01, "x near 3")
    T.ok(abs(result.params[2] - 5) < 0.01, "y near 5")
  end)

  T.it("converges on linear regression", function()
    local result = GD.adam(linreg_f, linreg_grad, {0, 0}, {
      lr = 0.05, max_iter = 5000, tol = 1e-5,
    })
    T.ok(result.loss < 0.01, "linreg loss small, got " .. result.loss)
    T.ok(abs(result.params[1] - 1) < 0.05, "x near 1")
    T.ok(abs(result.params[2] - 2) < 0.05, "y near 2")
  end)

  T.it("respects max_iter limit", function()
    local result = GD.adam(quad_f, quad_grad, {0, 0}, {
      lr = 1e-10, max_iter = 7, tol = 1e-20,
    })
    T.ok(result.iters == 7, "exactly 7 iterations, got " .. result.iters)
    T.ok(not result.converged, "did not converge")
  end)
end)

-- ---------------------------------------------------------------------------
-- RMSProp
-- ---------------------------------------------------------------------------

T.describe("rmsprop", function()
  T.it("converges on quadratic", function()
    local result = GD.rmsprop(quad_f, quad_grad, {0, 0}, {
      lr = 0.05, max_iter = 2000, tol = 1e-6,
    })
    T.ok(result.converged, "rmsprop converged")
    T.ok(result.loss < 1e-4, "loss < 1e-4, got " .. result.loss)
    T.ok(abs(result.params[1] - 3) < 0.01, "x near 3")
    T.ok(abs(result.params[2] - 5) < 0.01, "y near 5")
  end)

  T.it("converges on 1D quadratic", function()
    local result = GD.rmsprop(f1d, grad1d, {10}, {
      lr = 0.01, max_iter = 5000, tol = 1e-6,
    })
    T.ok(result.converged, "converged on 1D")
    T.ok(abs(result.params[1]) < 0.01, "near 0")
  end)
end)

-- ---------------------------------------------------------------------------
-- numerical_gradient
-- ---------------------------------------------------------------------------

T.describe("numerical_gradient", function()
  T.it("matches analytical gradient on quadratic", function()
    local p = {1.5, 2.7}
    local ng = GD.numerical_gradient(quad_f, p)
    local ag = quad_grad(p)
    T.ok(#ng == 2, "gradient has 2 elements")
    T.ok(math.abs(ng[1] - ag[1]) < 1e-4, "x component matches, diff=" .. math.abs(ng[1] - ag[1]))
    T.ok(math.abs(ng[2] - ag[2]) < 1e-4, "y component matches, diff=" .. math.abs(ng[2] - ag[2]))
  end)

  T.it("matches analytical gradient on rosenbrock", function()
    local p = {0.5, 0.5}
    local ng = GD.numerical_gradient(rosenbrock_f, p)
    local ag = rosenbrock_grad(p)
    T.ok(math.abs(ng[1] - ag[1]) < 1e-4, "x rosenbrock grad matches")
    T.ok(math.abs(ng[2] - ag[2]) < 1e-4, "y rosenbrock grad matches")
  end)

  T.it("matches analytical gradient on 1D quadratic", function()
    local p = {3.0}
    local ng = GD.numerical_gradient(f1d, p)
    T.ok(math.abs(ng[1] - 6.0) < 1e-4, "gradient of x^2 at x=3 is 6")
  end)

  T.it("custom h parameter works", function()
    local p = {1.5, 2.7}
    local ng = GD.numerical_gradient(quad_f, p, 1e-4)
    local ag = quad_grad(p)
    T.ok(math.abs(ng[1] - ag[1]) < 1e-3, "x with h=1e-4")
    T.ok(math.abs(ng[2] - ag[2]) < 1e-3, "y with h=1e-4")
  end)
end)

-- ---------------------------------------------------------------------------
-- line_search
-- ---------------------------------------------------------------------------

T.describe("line_search", function()
  T.it("returns alpha in (0, 1] for convex function", function()
    -- f_alpha(a) = (1 - a*2)^2 along direction of full step to minimum
    local function f_alpha(a)
      return (2 - a * 2)^2  -- starts at 4, minimum along direction
    end
    local alpha = GD.line_search(f_alpha)
    T.ok(alpha > 0, "alpha > 0, got " .. alpha)
    T.ok(alpha <= 1, "alpha <= 1, got " .. alpha)
  end)

  T.it("decreases function value", function()
    -- Simple: f(x) = (x-1)^2, start at x=0, direction = +1
    -- f_alpha(a) = (0 + a - 1)^2 = (a-1)^2
    local function f_alpha(a)
      return (a - 1)^2
    end
    local f0 = f_alpha(0)  -- = 1
    local alpha = GD.line_search(f_alpha, { alpha0 = 1, rho = 0.5 })
    T.ok(alpha > 0, "alpha > 0")
    T.ok(f_alpha(alpha) <= f0, "function decreased")
  end)

  T.it("fallback: small alpha returned when no progress", function()
    -- Pathological: always returns a value (even if no decrease possible)
    local function f_alpha(_) return 1e10 end  -- constant
    local alpha = GD.line_search(f_alpha, { alpha0 = 1, rho = 0.5, max_iter = 5 })
    T.ok(type(alpha) == "number", "returns a number")
    T.ok(alpha > 0, "positive alpha")
  end)
end)

-- ---------------------------------------------------------------------------
-- conjugate_gradient
-- ---------------------------------------------------------------------------

T.describe("conjugate_gradient", function()
  T.it("solves 2x2 SPD system exactly", function()
    -- A = [[4, 1], [1, 3]], b = [1, 2]
    -- Solution: x = [1/11, 7/11]
    local function A(x)
      return { 4*x[1] + x[2], x[1] + 3*x[2] }
    end
    local b = {1, 2}
    local result = GD.conjugate_gradient(A, b, { tol = 1e-10 })
    T.ok(result.converged, "converged")
    T.ok(math.abs(result.x[1] - 1/11) < 1e-6, "x[1] = 1/11")
    T.ok(math.abs(result.x[2] - 7/11) < 1e-6, "x[2] = 7/11")
    T.ok(result.residual < 1e-8, "small residual")
  end)

  T.it("solves 3x3 SPD system", function()
    -- A = [[4,1,0],[1,4,1],[0,1,4]], b = [1,1,1]
    local function A(x)
      return {
        4*x[1] + x[2],
        x[1] + 4*x[2] + x[3],
        x[2] + 4*x[3],
      }
    end
    local b = {1, 1, 1}
    local result = GD.conjugate_gradient(A, b, { tol = 1e-10 })
    T.ok(result.converged, "3x3 converged")
    -- Verify Ax = b
    local Ax = A(result.x)
    T.ok(math.abs(Ax[1] - b[1]) < 1e-6, "residual row 1")
    T.ok(math.abs(Ax[2] - b[2]) < 1e-6, "residual row 2")
    T.ok(math.abs(Ax[3] - b[3]) < 1e-6, "residual row 3")
  end)

  T.it("converges when x0 already solution", function()
    local function A(x) return { 2*x[1], 2*x[2] } end
    local b = {4, 6}
    local result = GD.conjugate_gradient(A, b, { x0 = {2, 3}, tol = 1e-8 })
    T.ok(result.converged, "immediately converged at solution")
    T.ok(result.residual < 1e-8, "zero residual")
  end)

  T.it("returns iters field", function()
    local function A(x) return { 4*x[1] + x[2], x[1] + 3*x[2] } end
    local b = {1, 2}
    local result = GD.conjugate_gradient(A, b)
    T.ok(type(result.iters) == "number", "iters is a number")
    T.ok(result.iters >= 0, "iters >= 0")
  end)
end)

-- ---------------------------------------------------------------------------
-- L-BFGS
-- ---------------------------------------------------------------------------

T.describe("lbfgs", function()
  T.it("converges on quadratic", function()
    local result = GD.lbfgs(quad_f, quad_grad, {0, 0}, {
      max_iter = 200, tol = 1e-8,
    })
    T.ok(result.converged, "lbfgs converged")
    T.ok(result.loss < 1e-8, "loss < 1e-8, got " .. result.loss)
    T.ok(math.abs(result.params[1] - 3) < 1e-3, "x near 3")
    T.ok(math.abs(result.params[2] - 5) < 1e-3, "y near 5")
  end)

  T.it("converges faster than gradient_descent on quadratic", function()
    -- Both start at same point with same tolerance
    local gd_result = GD.gradient_descent(quad_f, quad_grad, {0, 0}, {
      lr = 0.1, max_iter = 2000, tol = 1e-6,
    })
    local lbfgs_result = GD.lbfgs(quad_f, quad_grad, {0, 0}, {
      max_iter = 2000, tol = 1e-6,
    })
    T.ok(lbfgs_result.converged, "lbfgs converged")
    T.ok(gd_result.converged, "gd also converged")
    T.ok(lbfgs_result.iters < gd_result.iters,
      "lbfgs faster: " .. lbfgs_result.iters .. " vs " .. gd_result.iters)
  end)

  T.it("converges on linear regression", function()
    local result = GD.lbfgs(linreg_f, linreg_grad, {0, 0}, {
      max_iter = 500, tol = 1e-8,
    })
    T.ok(result.converged, "lbfgs linreg converged")
    T.ok(math.abs(result.params[1] - 1) < 0.01, "x near 1, got " .. result.params[1])
    T.ok(math.abs(result.params[2] - 2) < 0.01, "y near 2, got " .. result.params[2])
  end)

  T.it("m parameter controls memory", function()
    local result = GD.lbfgs(quad_f, quad_grad, {0, 0}, {
      m = 3, max_iter = 200, tol = 1e-6,
    })
    T.ok(result.converged, "lbfgs m=3 converged")
    T.ok(result.loss < 1e-6, "loss ok")
  end)

  T.it("callback and early stopping work", function()
    -- Use a harder start and tol=0 so convergence never triggers naturally
    local call_count = 0
    local result = GD.lbfgs(rosenbrock_f, rosenbrock_grad, {-1, -1}, {
      max_iter = 1000, tol = 0,
      callback = function(info)
        call_count = call_count + 1
        if info.iter >= 5 then return false end
      end,
    })
    T.ok(call_count == 5, "callback called 5 times, got " .. call_count)
    T.ok(result.iters <= 5, "stopped at 5 iters, got " .. result.iters)
    T.ok(not result.converged, "not converged (stopped by callback)")
  end)
end)

-- ---------------------------------------------------------------------------
-- Integration: gradient_descent on rosenbrock (harder problem)
-- ---------------------------------------------------------------------------

T.describe("rosenbrock", function()
  T.it("adam converges to (1,1)", function()
    local result = GD.adam(rosenbrock_f, rosenbrock_grad, {0, 0}, {
      lr = 0.001, max_iter = 20000, tol = 1e-4,
    })
    -- Rosenbrock is hard; just check we're close
    T.ok(result.loss < 0.01, "loss < 0.01 on rosenbrock, got " .. result.loss)
    T.ok(math.abs(result.params[1] - 1) < 0.1, "x near 1, got " .. result.params[1])
    T.ok(math.abs(result.params[2] - 1) < 0.1, "y near 1, got " .. result.params[2])
  end)

  T.it("lbfgs converges to (1,1)", function()
    local result = GD.lbfgs(rosenbrock_f, rosenbrock_grad, {0, 0}, {
      max_iter = 1000, tol = 1e-6,
    })
    T.ok(result.loss < 0.001, "lbfgs loss < 0.001 on rosenbrock, got " .. result.loss)
    T.ok(math.abs(result.params[1] - 1) < 0.01, "x near 1")
    T.ok(math.abs(result.params[2] - 1) < 0.01, "y near 1")
  end)
end)
