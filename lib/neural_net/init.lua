-- lib/neural_net/init.lua
-- Feedforward neural network with backpropagation.
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local exp, log, sqrt, tanh = math.exp, math.log, math.sqrt, math.tanh
local abs, floor = math.abs, math.floor

-- ---------------------------------------------------------------------------
-- Activation functions
-- Each returns (value, derivative_at_value).
-- ---------------------------------------------------------------------------

function M.relu(x)
  if x > 0 then return x, 1 end
  return 0, 0
end

function M.sigmoid(x)
  local s = 1 / (1 + exp(-x))
  return s, s * (1 - s)
end

function M.tanh(x)
  local t = tanh(x)
  return t, 1 - t * t
end

function M.linear(x)
  return x, 1
end

-- Softmax: takes array, returns array of probabilities.
-- No derivative returned (used as output layer; cross-entropy combines with it).
function M.softmax(xs)
  local n = #xs
  local max = xs[1]
  for i = 2, n do if xs[i] > max then max = xs[i] end end
  local sum = 0
  local out = {}
  for i = 1, n do
    out[i] = exp(xs[i] - max)
    sum = sum + out[i]
  end
  for i = 1, n do out[i] = out[i] / sum end
  return out
end

-- ---------------------------------------------------------------------------
-- Activation registry
-- ---------------------------------------------------------------------------

local ACTIVATIONS = {
  relu    = M.relu,
  sigmoid = M.sigmoid,
  tanh    = M.tanh,
  linear  = M.linear,
}

-- ---------------------------------------------------------------------------
-- LCG random number generator (seeded, portable)
-- ---------------------------------------------------------------------------

local function make_rng(seed)
  local s = seed or 12345
  return {
    next = function(self)
      -- LCG with Knuth constants
      s = (s * 6364136223846793005 + 1442695040888963407) % (2^53)
      return s / (2^53)
    end,
    randn = function(self)
      -- Box-Muller transform for normal distribution
      local u1 = self:next()
      local u2 = self:next()
      if u1 < 1e-15 then u1 = 1e-15 end
      return sqrt(-2 * log(u1)) * math.cos(2 * math.pi * u2)
    end,
  }
end

-- ---------------------------------------------------------------------------
-- Layer construction
-- ---------------------------------------------------------------------------

-- M.layer(in_size, out_size, activation_name) -> layer
-- Weights initialized to zero, biases to zero.
function M.layer(in_size, out_size, activation_name)
  activation_name = activation_name or "linear"
  local act = ACTIVATIONS[activation_name]
  if not act then
    return nil, "unknown activation: " .. tostring(activation_name)
  end
  local weights = {}
  local biases = {}
  for o = 1, out_size do
    weights[o] = {}
    for i = 1, in_size do
      weights[o][i] = 0
    end
    biases[o] = 0
  end
  return {
    weights = weights,
    biases = biases,
    activation = act,
    activation_name = activation_name,
    in_size = in_size,
    out_size = out_size,
  }
end

-- M.layer_random(in_size, out_size, activation_name, seed) -> layer
-- Xavier initialization: std = sqrt(2 / (fan_in + fan_out))
function M.layer_random(in_size, out_size, activation_name, seed)
  local l, err = M.layer(in_size, out_size, activation_name)
  if not l then return nil, err end
  local rng = make_rng(seed)
  local std = sqrt(2 / (in_size + out_size))
  for o = 1, out_size do
    for i = 1, in_size do
      l.weights[o][i] = rng:randn() * std
    end
    l.biases[o] = 0
  end
  return l
end

-- ---------------------------------------------------------------------------
-- Network
-- ---------------------------------------------------------------------------

-- M.network(layers) -> net
function M.network(layers)
  if not layers or #layers == 0 then
    return nil, "network requires at least one layer"
  end
  local net = { layers = layers }

  -- net:forward(input) -> output, activations
  -- activations[i] = { pre: pre-activation values, post: post-activation values, deriv: derivatives }
  -- activations[0] = input (as .post for convenience in backprop)
  function net:forward(input)
    local acts = {}
    acts[0] = { post = input }
    local current = input
    for li = 1, #self.layers do
      local layer = self.layers[li]
      local pre = {}
      local post = {}
      local deriv = {}
      for o = 1, layer.out_size do
        local sum = layer.biases[o]
        local w = layer.weights[o]
        for i = 1, layer.in_size do
          sum = sum + w[i] * current[i]
        end
        pre[o] = sum
        local y, dy = layer.activation(sum)
        post[o] = y
        deriv[o] = dy
      end
      acts[li] = { pre = pre, post = post, deriv = deriv }
      current = post
    end
    return current, acts
  end

  -- net:predict(input) -> output
  function net:predict(input)
    local out = self:forward(input)
    return out
  end

  -- net:backward(activations, target, loss_fn) -> gradients
  -- gradients[i] = { dw: 2D array, db: array } matching layers[i]
  function net:backward(activations, target, loss_fn)
    local n_layers = #self.layers
    -- Compute output loss gradient
    local output = activations[n_layers].post
    local _, dloss = loss_fn(output, target)

    -- delta[o] = error signal for neuron o in current layer
    local delta = {}
    for o = 1, #output do
      delta[o] = dloss[o] * activations[n_layers].deriv[o]
    end

    local grads = {}
    for li = n_layers, 1, -1 do
      local layer = self.layers[li]
      local prev_post = activations[li - 1].post
      local dw = {}
      local db = {}
      for o = 1, layer.out_size do
        dw[o] = {}
        for i = 1, layer.in_size do
          dw[o][i] = delta[o] * prev_post[i]
        end
        db[o] = delta[o]
      end
      grads[li] = { dw = dw, db = db }

      -- Propagate delta to previous layer
      if li > 1 then
        local prev_layer = self.layers[li - 1]
        local new_delta = {}
        for i = 1, prev_layer.out_size do
          local s = 0
          for o = 1, layer.out_size do
            s = s + layer.weights[o][i] * delta[o]
          end
          new_delta[i] = s * activations[li - 1].deriv[i]
        end
        delta = new_delta
      end
    end
    return grads
  end

  -- net:update(gradients, lr) — SGD step
  function net:update(gradients, lr)
    for li = 1, #self.layers do
      local layer = self.layers[li]
      local g = gradients[li]
      for o = 1, layer.out_size do
        for i = 1, layer.in_size do
          layer.weights[o][i] = layer.weights[o][i] - lr * g.dw[o][i]
        end
        layer.biases[o] = layer.biases[o] - lr * g.db[o]
      end
    end
  end

  -- net:serialize() -> plain table
  function net:serialize()
  local t = { layers = {} }
  for li = 1, #self.layers do
    local layer = self.layers[li]
    local ldata = {
      in_size = layer.in_size,
      out_size = layer.out_size,
      activation_name = layer.activation_name,
      weights = {},
      biases = {},
    }
    for o = 1, layer.out_size do
      ldata.weights[o] = {}
      for i = 1, layer.in_size do
        ldata.weights[o][i] = layer.weights[o][i]
      end
      ldata.biases[o] = layer.biases[o]
    end
    t.layers[li] = ldata
  end
  return t
end

  return net
end

-- M.deserialize(t) -> net
function M.deserialize(t)
  if not t or not t.layers then
    return nil, "invalid serialized network: missing layers"
  end
  local layers = {}
  for li = 1, #t.layers do
    local ldata = t.layers[li]
    local l, err = M.layer(ldata.in_size, ldata.out_size, ldata.activation_name)
    if not l then return nil, err end
    for o = 1, ldata.out_size do
      for i = 1, ldata.in_size do
        l.weights[o][i] = ldata.weights[o][i]
      end
      l.biases[o] = ldata.biases[o]
    end
    layers[li] = l
  end
  return M.network(layers)
end

-- ---------------------------------------------------------------------------
-- Loss functions
-- Each returns (loss_scalar, dloss_array).
-- ---------------------------------------------------------------------------

-- Mean squared error
function M.mse(predicted, target)
  local n = #predicted
  local loss = 0
  local dloss = {}
  for i = 1, n do
    local diff = predicted[i] - target[i]
    loss = loss + diff * diff
    dloss[i] = 2 * diff / n
  end
  return loss / n, dloss
end

-- Cross-entropy (for softmax output, target is one-hot or distribution)
function M.cross_entropy(predicted, target)
  local n = #predicted
  local loss = 0
  local dloss = {}
  for i = 1, n do
    local p = predicted[i]
    if p < 1e-15 then p = 1e-15 end
    loss = loss - target[i] * log(p)
    -- Gradient of cross-entropy w.r.t. softmax output = predicted - target
    -- (when combined with softmax layer in the output)
    dloss[i] = predicted[i] - target[i]
  end
  return loss, dloss
end

-- Binary cross-entropy (for sigmoid output, scalar target in [0,1])
function M.binary_cross_entropy(predicted, target)
  local n = #predicted
  local loss = 0
  local dloss = {}
  for i = 1, n do
    local p = predicted[i]
    local y = target[i]
    if p < 1e-15 then p = 1e-15 end
    if p > 1 - 1e-15 then p = 1 - 1e-15 end
    loss = loss - (y * log(p) + (1 - y) * log(1 - p))
    dloss[i] = (p - y) / (p * (1 - p))
  end
  return loss / n, dloss
end

-- ---------------------------------------------------------------------------
-- Loss registry
-- ---------------------------------------------------------------------------

local LOSSES = {
  mse                 = M.mse,
  cross_entropy       = M.cross_entropy,
  binary_cross_entropy = M.binary_cross_entropy,
}

-- ---------------------------------------------------------------------------
-- Trainer
-- ---------------------------------------------------------------------------

-- M.trainer(net, opts) -> trainer
function M.trainer(net, opts)
  opts = opts or {}
  local lr         = opts.lr or 0.01
  local loss_name  = opts.loss or "mse"
  local epochs     = opts.epochs or 100
  local batch_size = opts.batch_size or 1
  local shuffle    = opts.shuffle ~= false  -- default true
  local seed       = opts.seed or 42

  local loss_fn = LOSSES[loss_name]
  if not loss_fn then
    return nil, "unknown loss: " .. tostring(loss_name)
  end

  local trainer = {}

  -- trainer:fit(X, Y) -> { losses, epochs }
  function trainer:fit(X, Y)
    local n = #X
    local rng = make_rng(seed)
    local indices = {}
    for i = 1, n do indices[i] = i end
    local epoch_losses = {}

    for ep = 1, epochs do
      -- Shuffle
      if shuffle then
        for i = n, 2, -1 do
          local j = floor(rng:next() * i) + 1
          indices[i], indices[j] = indices[j], indices[i]
        end
      end

      local total_loss = 0
      local b = 1
      while b <= n do
        local bend = math.min(b + batch_size - 1, n)
        local batch_count = bend - b + 1

        -- Accumulate gradients
        local accum_grads = nil
        for bi = b, bend do
          local idx = indices[bi]
          local output, acts = net:forward(X[idx])
          local loss, _ = loss_fn(output, Y[idx])
          total_loss = total_loss + loss
          local grads = net:backward(acts, Y[idx], loss_fn)
          if not accum_grads then
            accum_grads = grads
          else
            -- Accumulate
            for li = 1, #net.layers do
              local layer = net.layers[li]
              for o = 1, layer.out_size do
                for i = 1, layer.in_size do
                  accum_grads[li].dw[o][i] = accum_grads[li].dw[o][i] + grads[li].dw[o][i]
                end
                accum_grads[li].db[o] = accum_grads[li].db[o] + grads[li].db[o]
              end
            end
          end
        end

        -- Average gradients
        if batch_count > 1 then
          for li = 1, #net.layers do
            local layer = net.layers[li]
            for o = 1, layer.out_size do
              for i = 1, layer.in_size do
                accum_grads[li].dw[o][i] = accum_grads[li].dw[o][i] / batch_count
              end
              accum_grads[li].db[o] = accum_grads[li].db[o] / batch_count
            end
          end
        end

        net:update(accum_grads, lr)
        b = bend + 1
      end

      epoch_losses[ep] = total_loss / n
    end

    return { losses = epoch_losses, epochs = epochs }
  end

  -- trainer:evaluate(X, Y) -> { loss, accuracy }
  function trainer:evaluate(X, Y)
    local n = #X
    local total_loss = 0
    local correct = 0
    for i = 1, n do
      local output, _ = net:forward(X[i])
      local loss, _ = loss_fn(output, Y[i])
      total_loss = total_loss + loss
      -- Accuracy: argmax match
      local pred_max_i = 1
      for j = 2, #output do
        if output[j] > output[pred_max_i] then pred_max_i = j end
      end
      local tgt_max_i = 1
      for j = 2, #Y[i] do
        if Y[i][j] > Y[i][tgt_max_i] then tgt_max_i = j end
      end
      if pred_max_i == tgt_max_i then correct = correct + 1 end
    end
    return { loss = total_loss / n, accuracy = correct / n }
  end

  return trainer
end

return M
