-- lib/neural/init.lua
-- Feedforward neural network with backpropagation (SGD).
-- Pure Lua, no external dependencies.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Simple LCG RNG for reproducible weight init
-- ---------------------------------------------------------------------------
local function make_rng(seed)
  local s = seed or 12345
  return {
    next = function(self)
      -- LCG: m=2^32, a=1664525, c=1013904223 (Numerical Recipes)
      s = (s * 1664525 + 1013904223) % 4294967296
      return s
    end,
    float = function(self)
      return self:next() / 4294967296
    end,
    -- Gaussian via Box-Muller
    gauss = function(self)
      local u1, u2
      repeat u1 = self:float() until u1 > 1e-10
      u2 = self:float()
      local mag = math.sqrt(-2 * math.log(u1))
      return mag * math.cos(2 * math.pi * u2)
    end,
  }
end

-- ---------------------------------------------------------------------------
-- Activations: each entry has fn(x) and deriv(x) (deriv w.r.t. pre-activation)
-- Note: for softmax, deriv is not used element-wise; handled specially.
-- ---------------------------------------------------------------------------
M.activations = {
  sigmoid = {
    fn = function(x)
      if x >= 0 then
        local e = math.exp(-x)
        return 1 / (1 + e)
      else
        local e = math.exp(x)
        return e / (1 + e)
      end
    end,
    deriv = function(x)
      local s
      if x >= 0 then
        local e = math.exp(-x)
        s = 1 / (1 + e)
      else
        local e = math.exp(x)
        s = e / (1 + e)
      end
      return s * (1 - s)
    end,
  },
  relu = {
    fn    = function(x) return x > 0 and x or 0 end,
    deriv = function(x) return x > 0 and 1 or 0 end,
  },
  tanh = {
    fn    = function(x) return math.tanh(x) end,
    deriv = function(x)
      local t = math.tanh(x)
      return 1 - t * t
    end,
  },
  linear = {
    fn    = function(x) return x end,
    deriv = function(_) return 1 end,
  },
  softmax = {
    -- Applied to a whole layer (vector), not element-wise.
    -- fn/deriv are stubs; the vector form is used inside network logic.
    fn    = function(x) return x end, -- identity placeholder
    deriv = function(_) return 1 end,
  },
}

-- Vector softmax
local function softmax_vec(z)
  local max = z[1]
  for i = 2, #z do if z[i] > max then max = z[i] end end
  local sum = 0
  local out = {}
  for i = 1, #z do
    out[i] = math.exp(z[i] - max)
    sum = sum + out[i]
  end
  for i = 1, #z do out[i] = out[i] / sum end
  return out
end

-- ---------------------------------------------------------------------------
-- Loss functions
-- ---------------------------------------------------------------------------
M.loss = {}

function M.loss.mse(pred, target)
  local s = 0
  for i = 1, #pred do
    local d = pred[i] - target[i]
    s = s + d * d
  end
  return s / #pred
end

function M.loss.mse_deriv(pred, target)
  local g = {}
  local n = #pred
  for i = 1, n do
    g[i] = 2 * (pred[i] - target[i]) / n
  end
  return g
end

function M.loss.cross_entropy(pred, target)
  local s = 0
  for i = 1, #pred do
    local p = pred[i]
    if p < 1e-15 then p = 1e-15 end
    s = s - target[i] * math.log(p)
  end
  return s
end

-- Derivative of cross-entropy + softmax combined (common pairing).
-- If output_activation is softmax, we use this combined gradient.
function M.loss.cross_entropy_softmax_deriv(pred, target)
  local g = {}
  for i = 1, #pred do
    g[i] = pred[i] - target[i]
  end
  return g
end

-- Generic cross-entropy derivative (without softmax baked in).
function M.loss.cross_entropy_deriv(pred, target)
  local g = {}
  for i = 1, #pred do
    local p = pred[i]
    if p < 1e-15 then p = 1e-15 end
    g[i] = -target[i] / p
  end
  return g
end

-- ---------------------------------------------------------------------------
-- Network constructor
-- ---------------------------------------------------------------------------
-- opts:
--   layers            : array of sizes, e.g. {4, 8, 3}
--   activation        : string key into M.activations (default "relu")
--   output_activation : string key (default "linear")
--   seed              : integer seed for weight init
function M.network(opts)
  local layers           = opts.layers
  local act_name         = opts.activation or "relu"
  local out_act_name     = opts.output_activation or "linear"
  local seed             = opts.seed or 42

  if not layers or #layers < 2 then
    return nil, "layers must have at least 2 entries"
  end
  if not M.activations[act_name] then
    return nil, "unknown activation: " .. tostring(act_name)
  end
  if not M.activations[out_act_name] then
    return nil, "unknown output_activation: " .. tostring(out_act_name)
  end

  local rng = make_rng(seed)
  local n_layers = #layers

  -- weights[l][j][i] = weight from neuron i in layer l to neuron j in layer l+1
  -- biases[l][j]     = bias for neuron j in layer l+1
  -- (l indexes from 1 to n_layers-1)
  local weights = {}
  local biases  = {}

  for l = 1, n_layers - 1 do
    local fan_in  = layers[l]
    local fan_out = layers[l + 1]

    -- He init for relu, Xavier for others
    local std
    if act_name == "relu" and l < n_layers - 1 then
      std = math.sqrt(2 / fan_in)
    else
      std = math.sqrt(2 / (fan_in + fan_out))
    end

    weights[l] = {}
    biases[l]  = {}
    for j = 1, fan_out do
      weights[l][j] = {}
      biases[l][j]  = 0
      for i = 1, fan_in do
        weights[l][j][i] = rng:gauss() * std
      end
    end
  end

  local net = {
    _layers      = layers,
    _act_name    = act_name,
    _out_act_name = out_act_name,
    _weights     = weights,
    _biases      = biases,
    _n_layers    = n_layers,
  }

  -- -------------------------------------------------------------------------
  -- forward(input) → output array
  -- Also stores intermediate values for backward pass.
  -- -------------------------------------------------------------------------
  function net:forward(input)
    local act_fn  = M.activations[self._act_name]
    local out_act = M.activations[self._out_act_name]

    -- _zs[l] = pre-activation values at layer l+1 (l = 1..n-1)
    -- _as[l] = post-activation values at layer l (l = 0..n-1)
    --   _as[0] = input
    self._zs = {}
    self._as = {}
    self._as[0] = input

    local a = input
    for l = 1, self._n_layers - 1 do
      local fan_out = self._layers[l + 1]
      local z = {}
      for j = 1, fan_out do
        local s = self._biases[l][j]
        for i = 1, #a do
          s = s + self._weights[l][j][i] * a[i]
        end
        z[j] = s
      end
      self._zs[l] = z

      local new_a
      if l == self._n_layers - 1 and self._out_act_name == "softmax" then
        new_a = softmax_vec(z)
      elseif l == self._n_layers - 1 then
        new_a = {}
        for j = 1, fan_out do
          new_a[j] = out_act.fn(z[j])
        end
      else
        new_a = {}
        for j = 1, fan_out do
          new_a[j] = act_fn.fn(z[j])
        end
      end
      self._as[l] = new_a
      a = new_a
    end
    return a
  end

  -- -------------------------------------------------------------------------
  -- backward(output, target, lr) — SGD update
  -- Must be called after forward().
  -- -------------------------------------------------------------------------
  function net:backward(output, target, lr)
    local act_fn  = M.activations[self._act_name]
    local L       = self._n_layers - 1   -- index of last weight layer

    -- Compute output gradient (delta at last layer)
    local deltas = {}

    -- For softmax + cross_entropy, use combined gradient (pred - target).
    -- For other combos, use chain rule manually.
    local out_delta = {}
    if self._out_act_name == "softmax" then
      -- Assume cross_entropy loss; combined gradient is pred - target.
      out_delta = M.loss.cross_entropy_softmax_deriv(output, target)
    else
      -- Use MSE-like gradient times activation derivative.
      local out_act = M.activations[self._out_act_name]
      local fan_out = self._layers[self._n_layers]
      for j = 1, fan_out do
        out_delta[j] = (output[j] - target[j]) * out_act.deriv(self._zs[L][j])
      end
    end
    deltas[L] = out_delta

    -- Backpropagate through hidden layers
    for l = L - 1, 1, -1 do
      local fan_out = self._layers[l + 1]
      local delta   = {}
      for i = 1, fan_out do
        local s = 0
        for j = 1, self._layers[l + 2] do
          s = s + self._weights[l + 1][j][i] * deltas[l + 1][j]
        end
        delta[i] = s * act_fn.deriv(self._zs[l][i])
      end
      deltas[l] = delta
    end

    -- Update weights and biases
    for l = 1, L do
      local a_prev  = self._as[l - 1]
      local fan_out = self._layers[l + 1]
      local fan_in  = self._layers[l]
      for j = 1, fan_out do
        self._biases[l][j] = self._biases[l][j] - lr * deltas[l][j]
        for i = 1, fan_in do
          self._weights[l][j][i] = self._weights[l][j][i] - lr * deltas[l][j] * a_prev[i]
        end
      end
    end
  end

  -- -------------------------------------------------------------------------
  -- predict(input) — alias for forward (single sample)
  -- -------------------------------------------------------------------------
  function net:predict(input)
    return self:forward(input)
  end

  -- -------------------------------------------------------------------------
  -- save() → snapshot table (deep copy of weights/biases + config)
  -- -------------------------------------------------------------------------
  function net:save()
    local w_copy = {}
    local b_copy = {}
    for l = 1, self._n_layers - 1 do
      w_copy[l] = {}
      b_copy[l] = {}
      for j = 1, self._layers[l + 1] do
        w_copy[l][j] = {}
        b_copy[l][j] = self._biases[l][j]
        for i = 1, self._layers[l] do
          w_copy[l][j][i] = self._weights[l][j][i]
        end
      end
    end
    return {
      layers           = { unpack(self._layers) },
      act_name         = self._act_name,
      out_act_name     = self._out_act_name,
      weights          = w_copy,
      biases           = b_copy,
    }
  end

  return net
end

-- ---------------------------------------------------------------------------
-- M.load(snapshot) → net
-- ---------------------------------------------------------------------------
function M.load(snapshot)
  local net, err = M.network({
    layers           = snapshot.layers,
    activation       = snapshot.act_name,
    output_activation = snapshot.out_act_name,
  })
  if not net then return nil, err end

  -- Overwrite weights/biases with snapshot values (deep copy)
  for l = 1, #snapshot.layers - 1 do
    for j = 1, snapshot.layers[l + 1] do
      net._biases[l][j] = snapshot.biases[l][j]
      for i = 1, snapshot.layers[l] do
        net._weights[l][j][i] = snapshot.weights[l][j][i]
      end
    end
  end

  return net
end

-- ---------------------------------------------------------------------------
-- M.train(net, dataset, opts) → history array of {epoch, loss}
-- dataset: array of {input, target}
-- opts: { epochs, lr, loss, batch_size, shuffle, seed }
-- ---------------------------------------------------------------------------
function M.train(net, dataset, opts)
  opts = opts or {}
  local epochs     = opts.epochs     or 100
  local lr         = opts.lr         or 0.01
  local loss_name  = opts.loss       or "mse"
  local batch_size = opts.batch_size or #dataset
  local shuffle    = opts.shuffle ~= false
  local seed       = opts.seed       or 0

  local loss_fn
  if loss_name == "mse" then
    loss_fn = M.loss.mse
  elseif loss_name == "cross_entropy" then
    loss_fn = M.loss.cross_entropy
  else
    return nil, "unknown loss: " .. tostring(loss_name)
  end

  local rng = make_rng(seed)
  local n   = #dataset

  -- Build index array for shuffling
  local idx = {}
  for i = 1, n do idx[i] = i end

  local history = {}

  for epoch = 1, epochs do
    -- Shuffle indices
    if shuffle then
      for i = n, 2, -1 do
        local j = math.floor(rng:float() * i) + 1
        idx[i], idx[j] = idx[j], idx[i]
      end
    end

    local total_loss = 0
    local batches    = 0

    local pos = 1
    while pos <= n do
      local batch_end = math.min(pos + batch_size - 1, n)

      -- Process batch: accumulate gradients (simple SGD per sample for now)
      local batch_loss = 0
      for k = pos, batch_end do
        local sample = dataset[idx[k]]
        local input, target = sample[1], sample[2]
        local output = net:forward(input)
        batch_loss = batch_loss + loss_fn(output, target)
        net:backward(output, target, lr)
      end

      total_loss = total_loss + batch_loss
      batches    = batches + 1
      pos        = batch_end + 1
    end

    history[epoch] = { epoch = epoch, loss = total_loss / n }
  end

  return history
end

return M
