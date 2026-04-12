-- lib/neural/neural_test.lua

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local nn = require("lib.neural")

local function approx(a, b, eps)
  eps = eps or 1e-6
  return math.abs(a - b) <= eps
end

-- ---------------------------------------------------------------------------
T.describe("activations", function()
  T.it("sigmoid values", function()
    local s = nn.activations.sigmoid
    T.ok(approx(s.fn(0), 0.5),                   "sigmoid(0) = 0.5")
    T.ok(approx(s.fn(2), 1 / (1 + math.exp(-2))), "sigmoid(2)")
    T.ok(s.fn(100) > 0.999,                       "sigmoid(100) near 1")
    T.ok(s.fn(-100) < 0.001,                      "sigmoid(-100) near 0")
    local d = s.deriv(0)
    T.ok(approx(d, 0.25),                          "sigmoid deriv at 0 = 0.25")
  end)

  T.it("relu values", function()
    local r = nn.activations.relu
    T.eq(r.fn(3),   3,   "relu(3)=3")
    T.eq(r.fn(-1),  0,   "relu(-1)=0")
    T.eq(r.fn(0),   0,   "relu(0)=0")
    T.eq(r.deriv(5),  1, "relu deriv +")
    T.eq(r.deriv(-1), 0, "relu deriv -")
  end)

  T.it("tanh values", function()
    local t = nn.activations.tanh
    T.ok(approx(t.fn(0), 0),   "tanh(0)=0")
    T.ok(approx(t.fn(0), 0),   "tanh(0)=0 again")
    T.ok(t.fn(10)  > 0.999,    "tanh(10) near 1")
    T.ok(t.fn(-10) < -0.999,   "tanh(-10) near -1")
    T.ok(approx(t.deriv(0), 1),"tanh deriv at 0 = 1")
  end)

  T.it("softmax sums to 1", function()
    local net = nn.network({ layers = {3, 3}, output_activation = "softmax" })
    local out = net:forward({1.0, 2.0, 0.5})
    local sum = 0
    for _, v in ipairs(out) do sum = sum + v end
    T.ok(approx(sum, 1, 1e-6), "softmax sums to 1")
    for _, v in ipairs(out) do
      T.ok(v > 0 and v < 1, "softmax output in (0,1)")
    end
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("loss functions", function()
  T.it("mse zero for perfect prediction", function()
    local pred   = {0.5, 0.3, 0.8}
    local target = {0.5, 0.3, 0.8}
    T.ok(approx(nn.loss.mse(pred, target), 0), "mse = 0 for perfect")
  end)

  T.it("mse computes correctly", function()
    local pred   = {1.0, 0.0}
    local target = {0.0, 1.0}
    -- ((1-0)^2 + (0-1)^2) / 2 = 1.0
    T.ok(approx(nn.loss.mse(pred, target), 1.0), "mse = 1.0")
  end)

  T.it("cross_entropy correct", function()
    local pred   = {0.9, 0.05, 0.05}
    local target = {1.0, 0.0,  0.0}
    local expected = -math.log(0.9)
    T.ok(approx(nn.loss.cross_entropy(pred, target), expected, 1e-9),
         "cross_entropy correct")
  end)

  T.it("cross_entropy near-zero pred clamped", function()
    local pred   = {1.0, 0.0}
    local target = {0.0, 1.0}
    -- Should not produce -inf; loss is a finite large number
    local v = nn.loss.cross_entropy(pred, target)
    T.ok(v > 0 and v < math.huge, "cross_entropy finite for 0 pred")
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("network construction", function()
  T.it("forward pass output shape", function()
    local net = nn.network({ layers = {4, 8, 3}, activation = "relu", seed = 1 })
    local out = net:forward({1.0, 0.5, -0.3, 0.8})
    T.eq(#out, 3, "output has 3 values")
  end)

  T.it("deeper network shape", function()
    local net = nn.network({ layers = {2, 4, 4, 2}, activation = "tanh", seed = 2 })
    local out = net:forward({0.1, 0.9})
    T.eq(#out, 2, "output has 2 values")
  end)

  T.it("deterministic with fixed seed", function()
    local net1 = nn.network({ layers = {3, 5, 2}, seed = 99 })
    local net2 = nn.network({ layers = {3, 5, 2}, seed = 99 })
    local o1   = net1:forward({0.1, 0.2, 0.3})
    local o2   = net2:forward({0.1, 0.2, 0.3})
    for i = 1, #o1 do
      T.ok(approx(o1[i], o2[i]), "same output for same seed i=" .. i)
    end
  end)

  T.it("different seeds give different outputs", function()
    local net1 = nn.network({ layers = {3, 5, 2}, seed = 1 })
    local net2 = nn.network({ layers = {3, 5, 2}, seed = 2 })
    local o1   = net1:forward({0.1, 0.2, 0.3})
    local o2   = net2:forward({0.1, 0.2, 0.3})
    local same = true
    for i = 1, #o1 do
      if not approx(o1[i], o2[i]) then same = false end
    end
    T.ok(not same, "different seeds give different outputs")
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("save/load", function()
  T.it("round-trip preserves weights", function()
    local net      = nn.network({ layers = {3, 5, 2}, activation = "sigmoid", seed = 7 })
    local input    = {0.4, -0.1, 0.7}
    local out_orig = net:forward(input)
    local snap     = net:save()
    local net2     = nn.load(snap)
    local out2     = net2:forward(input)
    for i = 1, #out_orig do
      T.ok(approx(out_orig[i], out2[i]), "weight preserved i=" .. i)
    end
  end)

  T.it("load preserves activation config", function()
    local net  = nn.network({ layers = {2, 4, 2}, activation = "tanh",
                               output_activation = "softmax", seed = 3 })
    local snap = net:save()
    local net2 = nn.load(snap)
    T.eq(net2._act_name,     "tanh",    "act_name preserved")
    T.eq(net2._out_act_name, "softmax", "out_act_name preserved")
  end)

  T.it("modified net does not affect loaded snapshot", function()
    local net  = nn.network({ layers = {2, 3, 1}, seed = 5 })
    local snap = net:save()
    -- Train the original net a bit
    for _ = 1, 10 do
      local out = net:forward({1, 0})
      net:backward(out, {1}, 0.1)
    end
    local net2  = nn.load(snap)
    local out1  = net:forward({0.5, 0.5})
    local out2  = net2:forward({0.5, 0.5})
    -- They should differ since net was trained
    T.ok(not approx(out1[1], out2[1]), "trained net differs from snapshot")
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("training", function()
  T.it("loss decreases over training (XOR)", function()
    -- XOR dataset
    local dataset = {
      { {0, 0}, {0} },
      { {0, 1}, {1} },
      { {1, 0}, {1} },
      { {1, 1}, {0} },
    }
    local net = nn.network({ layers = {2, 8, 1}, activation = "sigmoid",
                              output_activation = "sigmoid", seed = 42 })
    local hist = nn.train(net, dataset, {
      epochs = 2000,
      lr     = 0.5,
      loss   = "mse",
      shuffle = false,
    })
    local first_loss = hist[1].loss
    local last_loss  = hist[2000].loss
    T.ok(last_loss < first_loss, "loss decreased over training")
    -- With enough epochs should get reasonable accuracy
    T.ok(last_loss < 0.05, "XOR converges (loss < 0.05)")
  end)

  T.it("train returns correct history shape", function()
    local dataset = {
      { {1, 0}, {1} },
      { {0, 1}, {1} },
    }
    local net  = nn.network({ layers = {2, 4, 1}, seed = 1 })
    local hist = nn.train(net, dataset, { epochs = 10, lr = 0.01 })
    T.eq(#hist, 10, "history has 10 entries")
    for i = 1, 10 do
      T.eq(hist[i].epoch, i, "epoch field correct")
      T.ok(type(hist[i].loss) == "number", "loss is a number")
    end
  end)

  T.it("classification with softmax + cross_entropy", function()
    -- Simple 2-class classification
    local dataset = {}
    -- class 0: input near (1,0) → target {1,0}
    -- class 1: input near (0,1) → target {0,1}
    for _ = 1, 10 do
      dataset[#dataset + 1] = { {1, 0}, {1, 0} }
      dataset[#dataset + 1] = { {0, 1}, {0, 1} }
    end
    local net = nn.network({ layers = {2, 4, 2}, activation = "relu",
                              output_activation = "softmax", seed = 7 })
    local hist = nn.train(net, dataset, {
      epochs = 200,
      lr     = 0.05,
      loss   = "cross_entropy",
      shuffle = false,
    })
    -- Output should sum to 1 after training
    local out = net:forward({1, 0})
    local sum = out[1] + out[2]
    T.ok(approx(sum, 1, 1e-5), "softmax output sums to 1 after training")
    -- Should classify class 0 with higher probability
    T.ok(out[1] > out[2], "correct class has higher probability")
  end)

  T.it("multiple hidden layers train", function()
    local dataset = {
      { {0, 0}, {0} },
      { {0, 1}, {1} },
      { {1, 0}, {1} },
      { {1, 1}, {0} },
    }
    local net = nn.network({ layers = {2, 6, 4, 1}, activation = "sigmoid",
                              output_activation = "sigmoid", seed = 13 })
    local hist = nn.train(net, dataset, {
      epochs  = 3000,
      lr      = 0.3,
      loss    = "mse",
      shuffle = false,
    })
    T.ok(hist[3000].loss < hist[1].loss, "loss improves with deep net")
  end)

  T.it("predict alias works", function()
    local net = nn.network({ layers = {3, 4, 2}, seed = 9 })
    local inp = {0.1, 0.5, 0.9}
    local fwd = net:forward(inp)
    -- Re-load from snapshot to reset internal state, then predict fresh
    local snap = net:save()
    local net2 = nn.load(snap)
    local pred = net2:predict(inp)
    for i = 1, #fwd do
      T.ok(approx(fwd[i], pred[i]), "predict matches forward i=" .. i)
    end
  end)
end)
