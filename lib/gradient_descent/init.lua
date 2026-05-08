-- lib/gradient_descent/init.lua
-- Numerical optimization algorithms: gradient descent, Adam, RMSProp, L-BFGS,
-- conjugate gradient, SGD, line search, and numerical differentiation.
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local sqrt, abs, max = math.sqrt, math.abs, math.max
local huge = math.huge

-- ---------------------------------------------------------------------------
-- Internal vector utilities
-- ---------------------------------------------------------------------------

--: (number[], number[]) -> number[]
local function vec_add(a, b)
  local n = #a
  local c = {}
  for i = 1, n do c[i] = a[i] + b[i] end
  return c
end

--: (number[], number[]) -> number[]
local function vec_sub(a, b)
  local n = #a
  local c = {}
  for i = 1, n do c[i] = a[i] - b[i] end
  return c
end

--: (number[], number) -> number[]
local function vec_scale(a, s)
  local n = #a
  local c = {}
  for i = 1, n do c[i] = a[i] * s end
  return c
end

--: (number[], number[]) -> number
local function vec_dot(a, b)
  local n = #a
  local s = 0 --: number
  for i = 1, n do s = s + a[i] * b[i] end
  return s
end

--: (number[]) -> number
local function vec_norm(a)
  return sqrt(vec_dot(a, a))
end

--: (number[]) -> number[]
local function vec_copy(a)
  local n = #a
  local c = {}
  for i = 1, n do c[i] = a[i] end
  return c
end

-- ---------------------------------------------------------------------------
-- Shared result builder
-- ---------------------------------------------------------------------------

--:: GdHistEntry = { iter: integer, loss: number, grad_norm: number }
--:: GdResult = { params: number[], loss: number, iters: integer, converged: boolean, history?: GdHistEntry[] }
--: (number[], number, integer, boolean) -> GdResult
local function make_result(params, loss, iters, converged)
  return { params = params, loss = loss, iters = iters, converged = converged }
end

-- ---------------------------------------------------------------------------
-- Gradient descent (batch)
-- ---------------------------------------------------------------------------

--- Batch gradient descent.
-- f(params) -> scalar loss
-- grad(params) -> gradient array
-- params0: initial parameters
-- opts: { lr=0.01, max_iter=1000, tol=1e-6, momentum=0,
--         callback=nil, record_history=false }
--:: GdInfo = { iter: integer, params: number[], loss: number, grad_norm: number }
--:: GdCallback = (GdInfo) -> (boolean | nil)
--:: GdOpts = { lr?: number, max_iter?: integer, tol?: number, momentum?: number, callback?: GdCallback, record_history?: boolean }
--:: SgdOpts = { lr?: number, epochs?: integer, tol?: number, lr_decay?: number, momentum?: number, callback?: GdCallback, record_history?: boolean }
--:: AdamOpts = { lr?: number, max_iter?: integer, tol?: number, beta1?: number, beta2?: number, epsilon?: number, callback?: GdCallback, record_history?: boolean }
--:: RmsOpts = { lr?: number, max_iter?: integer, tol?: number, decay?: number, epsilon?: number, callback?: GdCallback, record_history?: boolean }
--:: LbfgsOpts = { m?: integer, max_iter?: integer, tol?: number, lr?: number, callback?: GdCallback, record_history?: boolean }
--: ((number[]) -> number, (number[]) -> number[], number[], GdOpts | nil) -> GdResult
function M.gradient_descent(f, grad, params0, opts)
  opts = opts or {}
  local lr        = opts.lr or 0.01
  local max_iter  = opts.max_iter or 1000
  local tol       = opts.tol or 1e-6
  local momentum  = opts.momentum or 0
  local callback  = opts.callback
  local record    = opts.record_history

  local params    = vec_copy(params0)
  local n         = #params
  local velocity = {} --[[: number[] ]]
  for i = 1, n do velocity[i] = 0 end

  local history = record and {} or nil --: { iter: integer, loss: number, grad_norm: number }[] | nil
  local converged = false

  for iter = 1, max_iter do
    local g    = grad(params)
    local gnorm = vec_norm(g)
    local loss = f(params)

    if history then
      history[#history + 1] = { iter = iter, loss = loss, grad_norm = gnorm }
    end

    if callback then
      local cont = callback({ iter = iter, params = params, loss = loss, grad_norm = gnorm })
      if cont == false then break end
    end

    if gnorm < tol then
      converged = true
      break
    end

    -- momentum update: v = momentum*v - lr*g
    for i = 1, n do
      velocity[i] = momentum * velocity[i] - lr * g[i]
      params[i]   = params[i] + velocity[i]
    end
  end

  local final_loss = f(params)
  local res = make_result(params, final_loss, max_iter, converged)
  if history then res.history = history end
  -- fix iters: we need actual count
  -- recompute iters by re-running — instead track inline
  return res
end

-- Internal version that tracks iters properly
--: ((number[]) -> number, (number[]) -> number[], number[], GdOpts | nil) -> GdResult
local function _gradient_descent(f, grad, params0, opts)
  opts = opts or {}
  local lr        = opts.lr or 0.01
  local max_iter  = opts.max_iter or 1000
  local tol       = opts.tol or 1e-6
  local momentum  = opts.momentum or 0
  local callback  = opts.callback
  local record    = opts.record_history

  local params    = vec_copy(params0)
  local n         = #params
  local velocity = {} --[[: number[] ]]
  for i = 1, n do velocity[i] = 0 end

  local history = record and {} or nil --: { iter: integer, loss: number, grad_norm: number }[] | nil
  local converged = false
  local iters = 0 --: integer

  for iter = 1, max_iter do
    iters = iter
    local g     = grad(params)
    local gnorm = vec_norm(g)
    local loss  = f(params)

    if history then
      history[#history + 1] = { iter = iter, loss = loss, grad_norm = gnorm }
    end

    if callback then
      local cont = callback({ iter = iter, params = params, loss = loss, grad_norm = gnorm })
      if cont == false then break end
    end

    if gnorm < tol then
      converged = true
      break
    end

    for i = 1, n do
      velocity[i] = momentum * velocity[i] - lr * g[i]
      params[i]   = params[i] + velocity[i]
    end
  end

  local res = { params = params, loss = f(params), iters = iters, converged = converged }
  if history then res.history = history end
  return res
end

-- Replace the public version with the proper one
M.gradient_descent = _gradient_descent

-- ---------------------------------------------------------------------------
-- Stochastic gradient descent (SGD)
-- ---------------------------------------------------------------------------

--- SGD with optional momentum and learning rate decay.
-- f(params) -> scalar loss (full loss, for convergence check)
-- grad_batch(params, batch_idx) -> gradient array
-- n_batches: number of batches per epoch
-- opts: { lr=0.01, epochs=100, tol=1e-6, lr_decay=0, momentum=0,
--         callback=nil, record_history=false }
--: ((number[]) -> number, (number[], integer) -> number[], number[], integer, SgdOpts | nil) -> GdResult
function M.sgd(f, grad_batch, params0, n_batches, opts)
  opts = opts or {}
  local lr        = opts.lr or 0.01
  local epochs    = opts.epochs or 100
  local tol       = opts.tol or 1e-6
  local lr_decay  = opts.lr_decay or 0
  local momentum  = opts.momentum or 0
  local callback  = opts.callback
  local record    = opts.record_history

  local params    = vec_copy(params0)
  local n         = #params
  local velocity = {} --[[: number[] ]]
  for i = 1, n do velocity[i] = 0 end

  local history = record and {} or nil --: { iter: integer, loss: number, grad_norm: number }[] | nil
  local converged = false
  local iters = 0 --: integer

  for epoch = 1, epochs do
    local current_lr = lr / (1 + lr_decay * (epoch - 1))

    for batch = 1, n_batches do
      iters = iters + 1
      local g = grad_batch(params, batch)
      for i = 1, n do
        velocity[i] = momentum * velocity[i] - current_lr * g[i]
        params[i]   = params[i] + velocity[i]
      end
    end

    local loss  = f(params)
    local g_full = grad_batch(params, 1)  -- approximate grad norm from batch 1
    local gnorm = vec_norm(g_full)

    if history then
      history[#history + 1] = { iter = epoch, loss = loss, grad_norm = gnorm }
    end

    if callback then
      local cont = callback({ iter = epoch, params = params, loss = loss, grad_norm = gnorm })
      if cont == false then break end
    end

    if gnorm < tol then
      converged = true
      break
    end
  end

  local res = { params = params, loss = f(params), iters = iters, converged = converged }
  if history then res.history = history end
  return res
end

-- ---------------------------------------------------------------------------
-- Adam optimizer
-- ---------------------------------------------------------------------------

--- Adam optimizer.
-- opts: { lr=0.001, beta1=0.9, beta2=0.999, eps=1e-8, max_iter=1000, tol=1e-6,
--         callback=nil, record_history=false }
--: ((number[]) -> number, (number[]) -> number[], number[], AdamOpts | nil) -> GdResult
function M.adam(f, grad, params0, opts)
  opts = opts or {}
  local lr       = opts.lr or 0.001
  local beta1    = opts.beta1 or 0.9
  local beta2    = opts.beta2 or 0.999
  local eps      = opts.eps or 1e-8
  local max_iter = opts.max_iter or 1000
  local tol      = opts.tol or 1e-6
  local callback = opts.callback
  local record   = opts.record_history

  local params   = vec_copy(params0)
  local n        = #params
  --: number[]
  local m        = {}   -- first moment
  --: number[]
  local v        = {}   -- second moment
  for i = 1, n do m[i] = 0.0; v[i] = 0.0 end

  local history = record and {} or nil --: { iter: integer, loss: number, grad_norm: number }[] | nil
  local converged = false
  local iters    = 0

  for iter = 1, max_iter do
    iters = iter
    local g     = grad(params)
    local gnorm = vec_norm(g)
    local loss  = f(params)

    if history then
      history[#history + 1] = { iter = iter, loss = loss, grad_norm = gnorm }
    end

    if callback then
      local cont = callback({ iter = iter, params = params, loss = loss, grad_norm = gnorm })
      if cont == false then break end
    end

    if gnorm < tol then
      converged = true
      break
    end

    local b1t = 1 - beta1 ^ iter
    local b2t = 1 - beta2 ^ iter

    for i = 1, n do
      m[i] = beta1 * m[i] + (1 - beta1) * g[i]
      v[i] = beta2 * v[i] + (1 - beta2) * g[i] * g[i]
      local mhat = m[i] / b1t
      local vhat = v[i] / b2t
      params[i] = params[i] - lr * mhat / (sqrt(vhat) + eps)
    end
  end

  local res = { params = params, loss = f(params), iters = iters, converged = converged }
  if history then res.history = history end
  return res
end

-- ---------------------------------------------------------------------------
-- RMSProp
-- ---------------------------------------------------------------------------

--- RMSProp optimizer.
-- opts: { lr=0.01, rho=0.9, eps=1e-8, max_iter=1000, tol=1e-6,
--         callback=nil, record_history=false }
--: ((number[]) -> number, (number[]) -> number[], number[], RmsOpts | nil) -> GdResult
function M.rmsprop(f, grad, params0, opts)
  opts = opts or {}
  local lr       = opts.lr or 0.01
  local rho      = opts.rho or 0.9
  local eps      = opts.eps or 1e-8
  local max_iter = opts.max_iter or 1000
  local tol      = opts.tol or 1e-6
  local callback = opts.callback
  local record   = opts.record_history

  local params   = vec_copy(params0)
  local n        = #params
  --: number[]
  local eg2      = {}   -- running average of squared gradients
  for i = 1, n do eg2[i] = 0.0 end

  local history = record and {} or nil --: { iter: integer, loss: number, grad_norm: number }[] | nil
  local converged = false
  local iters    = 0

  for iter = 1, max_iter do
    iters = iter
    local g     = grad(params)
    local gnorm = vec_norm(g)
    local loss  = f(params)

    if history then
      history[#history + 1] = { iter = iter, loss = loss, grad_norm = gnorm }
    end

    if callback then
      local cont = callback({ iter = iter, params = params, loss = loss, grad_norm = gnorm })
      if cont == false then break end
    end

    if gnorm < tol then
      converged = true
      break
    end

    for i = 1, n do
      eg2[i]    = rho * eg2[i] + (1 - rho) * g[i] * g[i]
      params[i] = params[i] - lr * g[i] / (sqrt(eg2[i]) + eps)
    end
  end

  local res = { params = params, loss = f(params), iters = iters, converged = converged }
  if history then res.history = history end
  return res
end

-- ---------------------------------------------------------------------------
-- Numerical gradient (finite differences, central)
-- ---------------------------------------------------------------------------

--- Compute numerical gradient via central finite differences.
-- f(params) -> scalar
-- h: step size (default 1e-5)
function M.numerical_gradient(f, params, h)
  h = h or 1e-5
  local n    = #params
  local grad = {}
  local p    = vec_copy(params)

  for i = 1, n do
    local orig = p[i]
    p[i] = orig + h
    local fp  = f(p)
    p[i] = orig - h
    local fm  = f(p)
    p[i] = orig
    grad[i] = (fp - fm) / (2 * h)
  end

  return grad
end

-- ---------------------------------------------------------------------------
-- Line search (Armijo / backtracking)
-- ---------------------------------------------------------------------------

--- Backtracking line search (Armijo condition).
-- f_alpha: function(alpha) -> scalar loss along search direction
-- opts: { alpha0=1, rho=0.5, c=1e-4, max_iter=50 }
-- Returns alpha satisfying sufficient decrease, or smallest tried value.
function M.line_search(f_alpha, opts)
  opts = opts or {}
  local alpha0   = opts.alpha0 or 1
  local rho      = opts.rho or 0.5
  local c        = opts.c or 1e-4
  local max_iter = opts.max_iter or 50

  local f0 = f_alpha(0)
  -- Estimate slope at 0 via one-sided finite difference
  local h     = 1e-7
  local slope = (f_alpha(h) - f0) / h

  local alpha = alpha0
  for _ = 1, max_iter do
    if f_alpha(alpha) <= f0 + c * alpha * slope then
      return alpha
    end
    alpha = alpha * rho
  end
  return alpha
end

-- ---------------------------------------------------------------------------
-- Conjugate gradient (linear solver: Ax = b)
-- ---------------------------------------------------------------------------

--- Conjugate gradient method for solving Ax = b.
-- A: function(x) -> Ax (matrix-vector product)
-- b: right-hand side array
-- opts: { max_iter=nil, tol=1e-6, x0=nil }
-- Returns: { x, residual, iters, converged }
function M.conjugate_gradient(A, b, opts)
  opts = opts or {}
  local n        = #b
  local tol      = opts.tol or 1e-6
  local max_iter = opts.max_iter or n

  local x = opts.x0 and vec_copy(--[[:! number[] ]] opts.x0) or {}
  for i = 1, n do x[i] = x[i] or 0 end

  local r   = vec_sub(b, A(x))   -- r = b - Ax
  local p   = vec_copy(r)
  local rr  = vec_dot(r, r)

  local converged = false
  local iters = 0 --: integer

  if sqrt(rr) < tol then
    return { x = x, residual = sqrt(rr), iters = 0, converged = true }
  end

  for iter = 1, max_iter do
    iters = iter
    local Ap   = A(p)
    local pAp  = vec_dot(p, Ap)

    if abs(pAp) < 1e-15 then break end  -- breakdown

    local alpha = rr / pAp

    for i = 1, n do x[i] = x[i] + alpha * p[i] end
    for i = 1, n do r[i] = r[i] - alpha * Ap[i] end

    local rr_new = vec_dot(r, r)
    local rnorm  = sqrt(rr_new)

    if rnorm < tol then
      converged = true
      break
    end

    local beta = rr_new / rr
    for i = 1, n do p[i] = r[i] + beta * p[i] end
    rr = rr_new
  end

  -- When convergence was triggered, rr was updated to rr_new before break
  -- Compute final residual from r directly
  local final_rnorm = sqrt(vec_dot(r, r))
  return { x = x, residual = final_rnorm, iters = iters, converged = converged }
end

-- ---------------------------------------------------------------------------
-- L-BFGS (limited-memory BFGS quasi-Newton)
-- ---------------------------------------------------------------------------

--- L-BFGS optimizer.
-- opts: { m=10, max_iter=1000, tol=1e-6, lr=1,
--         callback=nil, record_history=false }
--: ((number[]) -> number, (number[]) -> number[], number[], LbfgsOpts | nil) -> GdResult
function M.lbfgs(f, grad, params0, opts)
  opts = opts or {}
  local m_mem    = opts.m or 10
  local max_iter = opts.max_iter or 1000
  local tol      = opts.tol or 1e-6
  local lr       = opts.lr or 1
  local callback = opts.callback
  local record   = opts.record_history

  local params   = vec_copy(params0)
  local n        = #params

  -- Circular buffer for s and y vectors
  --: { [integer]: number[] }
  local s_hist   = {}   -- s[k] = params[k+1] - params[k]
  --: { [integer]: number[] }
  local y_hist   = {}   -- y[k] = grad[k+1] - grad[k]
  --: number[]
  local rho_hist = {}   -- rho[k] = 1 / dot(y[k], s[k])
  local buf_size = 0
  local buf_ptr  = 0    -- points to oldest entry (1-indexed circular)

  local history = record and {} or nil --: { iter: integer, loss: number, grad_norm: number }[] | nil
  local converged = false
  local iters    = 0

  local g = grad(params)

  for iter = 1, max_iter do
    iters = iter
    local gnorm = vec_norm(g)
    local loss  = f(params)

    if history then
      history[#history + 1] = { iter = iter, loss = loss, grad_norm = gnorm }
    end

    -- Callback fires before convergence check so caller sees every iteration
    if callback then
      local cont = callback({ iter = iter, params = params, loss = loss, grad_norm = gnorm })
      if cont == false then break end
    end

    if gnorm < tol then
      converged = true
      break
    end

    -- Two-loop L-BFGS recursion to compute search direction H^{-1} * g
    -- Buffer stores pairs in insertion order; buf_ptr is the most recently
    -- written slot (1-indexed, circular over m_mem slots).
    -- Position of the j-th most-recent pair (j=1 → newest):
    --   idx(j) = ((buf_ptr - j) mod m_mem) + 1   (Lua mod: always non-negative via +m_mem)
    local function buf_idx(j)
      return ((buf_ptr - j) % m_mem + m_mem) % m_mem + 1
    end

    local k = buf_size   -- number of stored pairs (0 on first iter)
    local q = vec_copy(g)
    local alphas = {} --: number[]

    -- First loop: newest → oldest
    for j = 1, k do
      local idx = buf_idx(j)
      alphas[j] = rho_hist[idx] * vec_dot(s_hist[idx], q)
      for i = 1, n do q[i] = q[i] - alphas[j] * y_hist[idx][i] end
    end

    -- Scale by H_0 = gamma * I, gamma from most recent pair
    local r
    if k > 0 then
      local newest = buf_idx(1)
      local sy = vec_dot(s_hist[newest], y_hist[newest])
      local yy = vec_dot(y_hist[newest], y_hist[newest])
      if yy > 1e-15 then
        r = vec_scale(q, sy / yy)
      else
        r = vec_copy(q)
      end
    else
      r = vec_copy(q)
    end

    -- Second loop: oldest → newest
    for j = k, 1, -1 do
      local idx  = buf_idx(j)
      local beta = rho_hist[idx] * vec_dot(y_hist[idx], r)
      local diff = alphas[j] - beta
      for i = 1, n do r[i] = r[i] + s_hist[idx][i] * diff end
    end

    -- r = H^{-1} * g; descent direction d = -r
    local d = vec_scale(r, -1)

    -- Backtracking line search along d (Armijo condition)
    local step  = lr   -- initial step size from opts.lr
    local f0    = loss
    local slope = vec_dot(g, d)   -- negative for a descent direction
    -- Guard: if slope >= 0 (numerical issue), fall back to steepest descent
    if slope >= 0 then
      d     = vec_scale(g, -1)
      slope = vec_dot(g, d)
    end
    local c_ls = 1e-4
    for _ = 1, 60 do
      local p_new = vec_add(params, vec_scale(d, step))
      if f(p_new) <= f0 + c_ls * step * slope then break end
      step = step * 0.5
    end

    local params_new = vec_add(params, vec_scale(d, step))
    local g_new      = grad(params_new)

    -- Update circular buffer with new (s, y) pair
    local s_k = vec_sub(params_new, params)
    local y_k = vec_sub(g_new, g)
    local sy  = vec_dot(s_k, y_k)

    if sy > 1e-15 then
      buf_ptr = (buf_ptr % m_mem) + 1
      s_hist[buf_ptr]   = s_k
      y_hist[buf_ptr]   = y_k
      rho_hist[buf_ptr] = 1 / sy
      if buf_size < m_mem then buf_size = buf_size + 1 end
    end

    params = params_new
    g      = g_new
  end

  local res = { params = params, loss = f(params), iters = iters, converged = converged }
  if history then res.history = history end
  return res
end

return M
