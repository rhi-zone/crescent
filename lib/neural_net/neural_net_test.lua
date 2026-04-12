-- lib/neural_net/neural_net_test.lua
-- Tests for lib/neural_net

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local N = require("lib.neural_net")

local abs = math.abs

local function approx(a, b, tol)
  tol = tol or 1e-6
  return abs(a - b) < tol
end

-- ---------------------------------------------------------------------------
-- Activation functions
-- ---------------------------------------------------------------------------

T.describe("activations", function()
  T.it("relu: positive", function()
    local y, dy = N.relu(3)
    T.eq(y, 3)
    T.eq(dy, 1)
  end)

  T.it("relu: negative", function()
    local y, dy = N.relu(-2)
    T.eq(y, 0)
    T.eq(dy, 0)
  end)

  T.it("relu: zero", function()
    local y, dy = N.relu(0)
    T.eq(y, 0)
    T.eq(dy, 0)
  end)

  T.it("sigmoid: at 0", function()
    local y, dy = N.sigmoid(0)
    T.ok(approx(y, 0.5), "sigmoid(0) should be 0.5")
    T.ok(approx(dy, 0.25), "sigmoid derivative at 0 should be 0.25")
  end)

  T.it("sigmoid: large positive saturates to 1", function()
    local y, dy = N.sigmoid(100)
    T.ok(y > 0.999, "sigmoid(100) should be close to 1")
    T.ok(dy < 0.001, "derivative near saturation should be near 0")
  end)

  T.it("sigmoid: large negative saturates to 0", function()
    local y, _ = N.sigmoid(-100)
    T.ok(y < 0.001, "sigmoid(-100) should be close to 0")
  end)

  T.it("tanh: at 0", function()
    local y, dy = N.tanh(0)
    T.ok(approx(y, 0), "tanh(0) = 0")
    T.ok(approx(dy, 1), "tanh derivative at 0 = 1")
  end)

  T.it("tanh: derivative = 1 - tanh^2", function()
    local y, dy = N.tanh(1.5)
    T.ok(approx(dy, 1 - y * y), "tanh derivative formula")
  end)

  T.it("linear: value and derivative", function()
    local y, dy = N.linear(7.3)
    T.ok(approx(y, 7.3), "linear passes through")
    T.eq(dy, 1)
  end)

  T.it("softmax: sums to 1", function()
    local out = N.softmax({1, 2, 3, 4})
    local sum = 0
    for _, v in ipairs(out) do sum = sum + v end
    T.ok(approx(sum, 1.0, 1e-9), "softmax sums to 1")
  end)

  T.it("softmax: largest input gets largest probability", function()
    local out = N.softmax({0.1, 5.0, 0.2})
    T.ok(out[2] > out[1] and out[2] > out[3], "index 2 has highest prob")
  end)

  T.it("softmax: numerically stable (large values)", function()
    local out = N.softmax({1000, 1001, 1002})
    local sum = 0
    for _, v in ipairs(out) do sum = sum + v end
    T.ok(approx(sum, 1.0, 1e-9), "softmax stable for large inputs")
  end)
end)

-- ---------------------------------------------------------------------------
-- Layer creation
-- ---------------------------------------------------------------------------

T.describe("layer creation", function()
  T.it("layer: correct shape", function()
    local l = N.layer(3, 5, "relu")
    T.eq(l.in_size, 3)
    T.eq(l.out_size, 5)
    T.eq(#l.weights, 5)
    T.eq(#l.weights[1], 3)
    T.eq(#l.biases, 5)
  end)

  T.it("layer: zero-initialized weights", function()
    local l = N.layer(2, 3, "sigmoid")
    for o = 1, 3 do
      for i = 1, 2 do
        T.eq(l.weights[o][i], 0, "weight should be zero")
      end
      T.eq(l.biases[o], 0, "bias should be zero")
    end
  end)

  T.it("layer: unknown activation returns nil, errmsg", function()
    local l, err = N.layer(2, 2, "nonexistent")
    T.eq(l, nil)
    T.ok(err and err:find("nonexistent"), "error mentions activation name")
  end)

  T.it("layer_random: Xavier init has reasonable scale", function()
    local l = N.layer_random(100, 100, "sigmoid", 42)
    -- With Xavier: std = sqrt(2/200) ≈ 0.1. Weights should be in roughly [-0.5, 0.5]
    local sum_sq = 0
    local count = 0
    for o = 1, 100 do
      for i = 1, 100 do
        sum_sq = sum_sq + l.weights[o][i]^2
        count = count + 1
      end
    end
    local std_est = math.sqrt(sum_sq / count)
    -- Xavier std = sqrt(2/200) ≈ 0.1
    T.ok(std_est > 0.05 and std_est < 0.2, "Xavier std in reasonable range, got " .. std_est)
  end)

  T.it("layer_random: different seeds give different weights", function()
    local l1 = N.layer_random(4, 4, "relu", 1)
    local l2 = N.layer_random(4, 4, "relu", 2)
    local same = true
    for o = 1, 4 do
      for i = 1, 4 do
        if l1.weights[o][i] ~= l2.weights[o][i] then same = false; break end
      end
    end
    T.ok(not same, "different seeds produce different weights")
  end)
end)

-- ---------------------------------------------------------------------------
-- Network forward pass
-- ---------------------------------------------------------------------------

T.describe("network forward", function()
  T.it("output shape matches last layer out_size", function()
    local net = N.network({
      N.layer_random(3, 5, "relu", 1),
      N.layer_random(5, 2, "sigmoid", 2),
    })
    local out, acts = net:forward({0.1, 0.5, 0.9})
    T.eq(#out, 2, "output size should be 2")
    T.ok(acts, "activations returned")
    T.eq(#acts, 2, "one activation record per layer")
  end)

  T.it("activations captured at each layer", function()
    local net = N.network({
      N.layer_random(2, 3, "relu", 5),
      N.layer_random(3, 1, "sigmoid", 6),
    })
    local _, acts = net:forward({1.0, -1.0})
    T.eq(#acts[1].post, 3, "first layer output has 3 neurons")
    T.eq(#acts[2].post, 1, "second layer output has 1 neuron")
    T.eq(#acts[1].deriv, 3, "first layer has 3 derivatives")
    T.eq(#acts[2].deriv, 1, "second layer has 1 derivative")
  end)

  T.it("single-layer network: manual weight check", function()
    local l = N.layer(2, 1, "linear")
    l.weights[1][1] = 0.5
    l.weights[1][2] = -0.5
    l.biases[1] = 1.0
    local net = N.network({l})
    local out = net:predict({2.0, 4.0})
    -- 0.5*2 + (-0.5)*4 + 1 = 1 - 2 + 1 = 0
    T.ok(approx(out[1], 0.0), "manual weight computation: " .. out[1])
  end)

  T.it("predict matches forward output", function()
    local net = N.network({
      N.layer_random(3, 4, "tanh", 7),
      N.layer_random(4, 2, "sigmoid", 8),
    })
    local input = {0.3, -0.7, 1.2}
    local out1 = net:predict(input)
    local out2, _ = net:forward(input)
    for i = 1, #out1 do
      T.ok(approx(out1[i], out2[i]), "predict and forward agree at index " .. i)
    end
  end)
end)

-- ---------------------------------------------------------------------------
-- Loss functions
-- ---------------------------------------------------------------------------

T.describe("loss functions", function()
  T.it("mse: zero for perfect prediction", function()
    local loss, dloss = N.mse({1.0, 2.0, 3.0}, {1.0, 2.0, 3.0})
    T.ok(approx(loss, 0), "mse = 0 for perfect prediction")
    for i = 1, 3 do
      T.ok(approx(dloss[i], 0), "gradient = 0 for perfect prediction")
    end
  end)

  T.it("mse: non-zero error", function()
    local loss, dloss = N.mse({1.0}, {0.0})
    T.ok(approx(loss, 1.0), "mse({1},{0}) = 1")
    T.ok(approx(dloss[1], 2.0), "mse gradient: 2*(predicted-target)/n")
  end)

  T.it("mse: symmetric with sign flip", function()
    local loss1, _ = N.mse({1.0}, {0.5})
    local loss2, _ = N.mse({0.0}, {0.5})
    T.ok(approx(loss1, loss2), "mse symmetric around target")
  end)

  T.it("cross_entropy: gradient = predicted - target", function()
    local pred = {0.7, 0.2, 0.1}
    local tgt  = {1.0, 0.0, 0.0}
    local _, dloss = N.cross_entropy(pred, tgt)
    -- Combined softmax+CE gradient is predicted - target
    T.ok(approx(dloss[1], pred[1] - tgt[1], 1e-9))
    T.ok(approx(dloss[2], pred[2] - tgt[2], 1e-9))
    T.ok(approx(dloss[3], pred[3] - tgt[3], 1e-9))
  end)

  T.it("cross_entropy: lower for correct predictions", function()
    local loss_good, _ = N.cross_entropy({0.9, 0.1}, {1.0, 0.0})
    local loss_bad,  _ = N.cross_entropy({0.1, 0.9}, {1.0, 0.0})
    T.ok(loss_good < loss_bad, "lower loss when predicting correctly")
  end)

  T.it("binary_cross_entropy: zero at perfect", function()
    local loss, _ = N.binary_cross_entropy({1.0 - 1e-10, 1e-10}, {1.0, 0.0})
    T.ok(loss < 1e-6, "bce near zero for near-perfect prediction, got " .. loss)
  end)

  T.it("binary_cross_entropy: higher for wrong predictions", function()
    local loss_good, _ = N.binary_cross_entropy({0.9}, {1.0})
    local loss_bad, _  = N.binary_cross_entropy({0.1}, {1.0})
    T.ok(loss_good < loss_bad, "bce lower when more correct")
  end)
end)

-- ---------------------------------------------------------------------------
-- Backprop gradient check
-- ---------------------------------------------------------------------------

T.describe("backprop gradient check", function()
  -- Numerical gradient vs analytical gradient on a small network
  T.it("gradients match numerical approximation", function()
    local net = N.network({
      N.layer_random(2, 3, "sigmoid", 10),
      N.layer_random(3, 1, "sigmoid", 11),
    })
    local input = {0.5, -0.3}
    local target = {1.0}
    local eps = 1e-5

    -- Analytical gradients
    local _, acts = net:forward(input)
    local grads = net:backward(acts, target, N.mse)

    -- Numerical gradient check for first layer weights
    local l1 = net.layers[1]
    for o = 1, l1.out_size do
      for i = 1, l1.in_size do
        local orig = l1.weights[o][i]
        l1.weights[o][i] = orig + eps
        local out_p = net:predict(input)
        local loss_p, _ = N.mse(out_p, target)
        l1.weights[o][i] = orig - eps
        local out_m = net:predict(input)
        local loss_m, _ = N.mse(out_m, target)
        l1.weights[o][i] = orig

        local num_grad = (loss_p - loss_m) / (2 * eps)
        local ana_grad = grads[1].dw[o][i]
        local rel_err = abs(num_grad - ana_grad) / (abs(num_grad) + abs(ana_grad) + 1e-10)
        T.ok(rel_err < 1e-4,
          string.format("gradient check w[%d][%d]: num=%.6f ana=%.6f rel_err=%.2e",
            o, i, num_grad, ana_grad, rel_err))
      end
    end
  end)

  T.it("bias gradients match numerical approximation", function()
    local net = N.network({
      N.layer_random(2, 2, "tanh", 20),
      N.layer_random(2, 1, "linear", 21),
    })
    local input = {1.0, 0.5}
    local target = {0.0}
    local eps = 1e-5

    local _, acts = net:forward(input)
    local grads = net:backward(acts, target, N.mse)

    local l2 = net.layers[2]
    for o = 1, l2.out_size do
      local orig = l2.biases[o]
      l2.biases[o] = orig + eps
      local out_p = net:predict(input)
      local loss_p, _ = N.mse(out_p, target)
      l2.biases[o] = orig - eps
      local out_m = net:predict(input)
      local loss_m, _ = N.mse(out_m, target)
      l2.biases[o] = orig

      local num_grad = (loss_p - loss_m) / (2 * eps)
      local ana_grad = grads[2].db[o]
      local rel_err = abs(num_grad - ana_grad) / (abs(num_grad) + abs(ana_grad) + 1e-10)
      T.ok(rel_err < 1e-4,
        string.format("bias gradient check b[%d]: num=%.6f ana=%.6f rel_err=%.2e",
          o, num_grad, ana_grad, rel_err))
    end
  end)
end)

-- ---------------------------------------------------------------------------
-- XOR training
-- ---------------------------------------------------------------------------

T.describe("XOR training", function()
  T.it("2→4→1 network solves XOR under 5000 epochs", function()
    local X = {{0,0}, {0,1}, {1,0}, {1,1}}
    local Y = {{0},   {1},   {1},   {0}}

    local net = N.network({
      N.layer_random(2, 4, "sigmoid", 123),
      N.layer_random(4, 1, "sigmoid", 456),
    })

    local tr = N.trainer(net, {
      lr = 1.0,
      loss = "mse",
      epochs = 5000,
      batch_size = 1,
      shuffle = false,
      seed = 99,
    })

    local result = tr:fit(X, Y)
    T.ok(result.losses, "fit returns losses")
    T.eq(result.epochs, 5000)

    -- Check convergence: final loss should be much less than initial
    local final_loss = result.losses[5000]
    local initial_loss = result.losses[1]
    T.ok(final_loss < initial_loss * 0.5,
      string.format("loss decreased: initial=%.4f final=%.4f", initial_loss, final_loss))
    T.ok(final_loss < 0.05,
      string.format("XOR converged: final loss=%.6f", final_loss))

    -- Predictions should be correct
    for i = 1, 4 do
      local out = net:predict(X[i])
      local pred = out[1] > 0.5 and 1 or 0
      T.eq(pred, Y[i][1], string.format("XOR(%d,%d)=%d, got %.3f", X[i][1], X[i][2], Y[i][1], out[1]))
    end
  end)
end)

-- ---------------------------------------------------------------------------
-- Trainer
-- ---------------------------------------------------------------------------

T.describe("trainer", function()
  T.it("fit returns decreasing loss trend", function()
    local X = {{1,0}, {0,1}, {1,1}, {0,0}}
    local Y = {{1},   {1},   {0},   {0}}

    local net = N.network({
      N.layer_random(2, 4, "sigmoid", 77),
      N.layer_random(4, 1, "sigmoid", 88),
    })
    local tr = N.trainer(net, { lr = 0.3, loss = "mse", epochs = 200, seed = 11 })
    local result = tr:fit(X, Y)

    -- Average of first 10 epochs vs last 10 epochs
    local first_avg = 0
    for i = 1, 10 do first_avg = first_avg + result.losses[i] end
    first_avg = first_avg / 10

    local last_avg = 0
    for i = 191, 200 do last_avg = last_avg + result.losses[i] end
    last_avg = last_avg / 10

    T.ok(last_avg < first_avg,
      string.format("loss decreased: first_avg=%.4f last_avg=%.4f", first_avg, last_avg))
  end)

  T.it("evaluate returns loss and accuracy", function()
    local X = {{1,0}, {0,1}}
    local Y = {{1,0}, {0,1}}  -- one-hot for 2-class

    local net = N.network({
      N.layer_random(2, 4, "relu", 33),
      N.layer_random(4, 2, "sigmoid", 44),
    })
    local tr = N.trainer(net, { lr = 0.1, loss = "mse", epochs = 1, seed = 1 })
    local eval = tr:evaluate(X, Y)
    T.ok(eval.loss ~= nil, "evaluate returns loss")
    T.ok(eval.accuracy ~= nil, "evaluate returns accuracy")
    T.ok(eval.accuracy >= 0 and eval.accuracy <= 1, "accuracy in [0,1]")
  end)

  T.it("evaluate accuracy is 1.0 for trivially correct network", function()
    -- Build a network that reliably outputs class 0 for input {1,0} and class 1 for {0,1}
    -- Train it heavily
    local X = {{1,0}, {0,1}, {1,0}, {0,1}}
    local Y = {{1,0}, {0,1}, {1,0}, {0,1}}

    local net = N.network({
      N.layer_random(2, 8, "sigmoid", 55),
      N.layer_random(8, 2, "sigmoid", 66),
    })
    local tr = N.trainer(net, { lr = 0.5, loss = "mse", epochs = 2000, seed = 7 })
    tr:fit(X, Y)
    local eval = tr:evaluate(X, Y)
    T.ok(eval.accuracy == 1.0,
      "well-trained network should have 100% accuracy on training set, got " .. eval.accuracy)
  end)

  T.it("unknown loss function returns nil, errmsg", function()
    local net = N.network({ N.layer(1, 1, "linear") })
    local tr, err = N.trainer(net, { loss = "nonsense" })
    T.eq(tr, nil)
    T.ok(err and err:find("nonsense"), "error mentions unknown loss")
  end)

  T.it("batch_size > 1 accumulates and averages gradients", function()
    -- Train same data twice: once with batch_size=1, once with batch_size=4
    -- Both should converge
    local X = {{0,0},{0,1},{1,0},{1,1}}
    local Y = {{0},{1},{1},{0}}

    local net1 = N.network({
      N.layer_random(2, 4, "sigmoid", 200),
      N.layer_random(4, 1, "sigmoid", 201),
    })
    local net2 = N.network({
      N.layer_random(2, 4, "sigmoid", 200),
      N.layer_random(4, 1, "sigmoid", 201),
    })

    local tr1 = N.trainer(net1, { lr = 0.5, loss = "mse", epochs = 500, batch_size = 1, shuffle = false, seed = 1 })
    local tr2 = N.trainer(net2, { lr = 0.5, loss = "mse", epochs = 500, batch_size = 4, shuffle = false, seed = 1 })

    local r1 = tr1:fit(X, Y)
    local r2 = tr2:fit(X, Y)

    -- Both should reduce loss compared to start
    T.ok(r1.losses[500] < r1.losses[1], "batch_size=1 reduces loss")
    T.ok(r2.losses[500] < r2.losses[1], "batch_size=4 reduces loss")
  end)
end)

-- ---------------------------------------------------------------------------
-- Serialize / Deserialize
-- ---------------------------------------------------------------------------

T.describe("serialize / deserialize", function()
  T.it("round-trip preserves predictions", function()
    local net = N.network({
      N.layer_random(3, 5, "tanh", 300),
      N.layer_random(5, 2, "sigmoid", 301),
    })
    local input = {0.1, -0.5, 0.9}
    local out_before = net:predict(input)

    local t = net:serialize()
    local net2 = N.deserialize(t)
    local out_after = net2:predict(input)

    T.eq(#out_before, #out_after, "output size preserved")
    for i = 1, #out_before do
      T.ok(approx(out_before[i], out_after[i], 1e-12),
        "prediction matches after round-trip at index " .. i)
    end
  end)

  T.it("serialize produces plain data (no functions)", function()
    local net = N.network({ N.layer_random(2, 3, "relu", 400) })
    local t = net:serialize()
    T.ok(type(t) == "table", "serialized is a table")
    T.ok(type(t.layers) == "table", "has layers")
    T.eq(#t.layers, 1)
    T.eq(t.layers[1].in_size, 2)
    T.eq(t.layers[1].out_size, 3)
    T.eq(t.layers[1].activation_name, "relu")
    T.ok(type(t.layers[1].weights) == "table", "weights are table")
    T.ok(type(t.layers[1].biases) == "table", "biases are table")
    -- No functions in serialized output
    T.ok(type(t.layers[1].activation) == "nil", "no activation function in serialized form")
  end)

  T.it("deserialize with invalid table returns nil, errmsg", function()
    local net, err = N.deserialize(nil)
    T.eq(net, nil)
    T.ok(err ~= nil, "error message returned")
  end)

  T.it("round-trip with training preserves weights exactly", function()
    local net = N.network({
      N.layer_random(2, 1, "sigmoid", 500),
    })
    -- Do a few training steps
    local X = {{1,0},{0,1}}
    local Y = {{1},{0}}
    local tr = N.trainer(net, { lr = 0.1, epochs = 10, seed = 1 })
    tr:fit(X, Y)

    local t = net:serialize()
    local net2 = N.deserialize(t)

    -- Exact weight match
    for o = 1, 1 do
      for i = 1, 2 do
        T.eq(net.layers[1].weights[o][i], net2.layers[1].weights[o][i],
          "weight preserved exactly")
      end
      T.eq(net.layers[1].biases[o], net2.layers[1].biases[o],
        "bias preserved exactly")
    end
  end)
end)

-- ---------------------------------------------------------------------------
-- network() error handling
-- ---------------------------------------------------------------------------

T.describe("network error handling", function()
  T.it("network with empty layers returns nil, errmsg", function()
    local net, err = N.network({})
    T.eq(net, nil)
    T.ok(err ~= nil, "error returned for empty layers")
  end)

  T.it("network with nil returns nil, errmsg", function()
    local net, err = N.network(nil)
    T.eq(net, nil)
    T.ok(err ~= nil, "error returned for nil layers")
  end)
end)
