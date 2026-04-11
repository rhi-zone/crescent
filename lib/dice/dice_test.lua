-- lib/dice/dice_test.lua
-- Tests for lib/dice: parser, evaluator, statistics, simulation.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local M = require("lib.dice")

-- Deterministic RNG: always returns max (n).
local function max_rng(n) return n end
-- Always returns 1.
local function min_rng(n) return 1 end   -- luacheck: ignore
-- Always returns a fixed value (mid).
local function mid_rng(n) return math.ceil(n / 2) end  -- luacheck: ignore

T.describe("M.parse", function()
  T.it("parses d6", function()
    local e = M.parse("d6")
    T.eq(e.type, "roll")
    T.eq(e.count, 1)
    T.eq(e.sides, 6)
    T.eq(e.keep, nil)
    T.eq(e.explode, false)
    T.eq(e.fudge, false)
  end)

  T.it("parses 3d6", function()
    local e = M.parse("3d6")
    T.eq(e.type, "roll")
    T.eq(e.count, 3)
    T.eq(e.sides, 6)
    T.eq(e.keep, nil)
    T.eq(e.keep_low, false)
  end)

  T.it("parses 3d6+2", function()
    local e = M.parse("3d6+2")
    T.eq(e.type, "binop")
    T.eq(e.op, "+")
    T.eq(e.left.type, "roll")
    T.eq(e.left.count, 3)
    T.eq(e.left.sides, 6)
    T.eq(e.right.type, "constant")
    T.eq(e.right.value, 2)
  end)

  T.it("parses 2d8-1", function()
    local e = M.parse("2d8-1")
    T.eq(e.type, "binop")
    T.eq(e.op, "-")
    T.eq(e.left.sides, 8)
    T.eq(e.right.value, 1)
  end)

  T.it("parses 4d6k3 (keep highest)", function()
    local e = M.parse("4d6k3")
    T.eq(e.type, "roll")
    T.eq(e.count, 4)
    T.eq(e.sides, 6)
    T.eq(e.keep, 3)
    T.eq(e.keep_low, false)
  end)

  T.it("parses 4d6kl3 (keep lowest)", function()
    local e = M.parse("4d6kl3")
    T.eq(e.type, "roll")
    T.eq(e.keep, 3)
    T.eq(e.keep_low, true)
  end)

  T.it("parses 4d6KL3 case-insensitive", function()
    local e = M.parse("4d6KL3")
    T.eq(e.type, "roll")
    T.eq(e.keep, 3)
    T.eq(e.keep_low, true)
  end)

  T.it("parses 2d6! (exploding)", function()
    local e = M.parse("2d6!")
    T.eq(e.type, "roll")
    T.eq(e.explode, true)
    T.eq(e.count, 2)
    T.eq(e.sides, 6)
  end)

  T.it("parses d% (percentile)", function()
    local e = M.parse("d%")
    T.eq(e.type, "roll")
    T.eq(e.sides, 100)
    T.eq(e.pct, true)
  end)

  T.it("parses dF (fudge)", function()
    local e = M.parse("dF")
    T.eq(e.type, "roll")
    T.eq(e.fudge, true)
  end)

  T.it("parses dF.2 (fudge alternate notation)", function()
    local e = M.parse("dF.2")
    T.eq(e.type, "roll")
    T.eq(e.fudge, true)
  end)

  T.it("parses DF (uppercase fudge)", function()
    local e = M.parse("DF")
    T.eq(e.type, "roll")
    T.eq(e.fudge, true)
  end)

  T.it("parses compound 3d6+2d4", function()
    local e = M.parse("3d6+2d4")
    T.eq(e.type, "binop")
    T.eq(e.op, "+")
    T.eq(e.left.count, 3)
    T.eq(e.left.sides, 6)
    T.eq(e.right.count, 2)
    T.eq(e.right.sides, 4)
  end)

  T.it("parses (3d6+2)*2", function()
    local e = M.parse("(3d6+2)*2")
    T.eq(e.type, "binop")
    T.eq(e.op, "*")
    T.eq(e.left.type, "binop")
    T.eq(e.right.type, "constant")
    T.eq(e.right.value, 2)
  end)

  T.it("handles leading/trailing whitespace", function()
    local e = M.parse("  3d6  ")
    T.eq(e.type, "roll")
    T.eq(e.count, 3)
  end)

  T.it("handles spaces around operator", function()
    local e = M.parse("3d6 + 2")
    T.eq(e.type, "binop")
    T.eq(e.op, "+")
  end)

  T.it("returns nil,err on empty string", function()
    local e, err = M.parse("")
    T.eq(e, nil)
    T.ok(type(err) == "string")
  end)

  T.it("returns nil,err on invalid notation", function()
    local e, err = M.parse("xyz")
    T.eq(e, nil)
    T.ok(type(err) == "string")
  end)

  T.it("returns nil,err on d0", function()
    local e, err = M.parse("d0")
    T.eq(e, nil)
    T.ok(type(err) == "string")
  end)

  T.it("returns nil,err on keep exceeding count", function()
    local e, err = M.parse("2d6k5")
    T.eq(e, nil)
    T.ok(type(err) == "string")
  end)

  T.it("returns nil,err on bare 'd'", function()
    local e, err = M.parse("d")
    T.eq(e, nil)
    T.ok(type(err) == "string")
  end)

  T.it("returns nil,err on trailing garbage", function()
    local e, err = M.parse("3d6xyz")
    T.eq(e, nil)
    T.ok(type(err) == "string")
  end)
end)

T.describe("M.roll deterministic", function()
  T.it("1d1 -> 1", function()
    T.eq(M.roll("1d1", max_rng), 1)
  end)

  T.it("1d1+5 -> 6", function()
    T.eq(M.roll("1d1+5", max_rng), 6)
  end)

  T.it("2d1 -> 2", function()
    T.eq(M.roll("2d1", max_rng), 2)
  end)

  T.it("d1 -> 1", function()
    T.eq(M.roll("d1", max_rng), 1)
  end)

  T.it("2d1-1 -> 1", function()
    T.eq(M.roll("2d1-1", max_rng), 1)
  end)

  T.it("3d6 with max_rng -> 18", function()
    T.eq(M.roll("3d6", max_rng), 18)
  end)

  T.it("3d6 with min_rng -> 3", function()
    T.eq(M.roll("3d6", min_rng), 3)
  end)

  T.it("d6+d4 with max_rng -> 10", function()
    T.eq(M.roll("d6+d4", max_rng), 10)
  end)

  T.it("4d1k3 (keep 3 of 4 ones) -> 3", function()
    T.eq(M.roll("4d1k3", max_rng), 3)
  end)

  T.it("4d1kl3 (keep lowest 3) -> 3", function()
    T.eq(M.roll("4d1kl3", max_rng), 3)
  end)

  T.it("4d6k3 with max_rng (all 6s, keep 3) -> 18", function()
    T.eq(M.roll("4d6k3", max_rng), 18)
  end)

  T.it("4d6kl3 with min_rng (all 1s, keep 3) -> 3", function()
    T.eq(M.roll("4d6kl3", min_rng), 3)
  end)

  T.it("constant 7 -> 7", function()
    T.eq(M.roll("7", max_rng), 7)
  end)

  T.it("2*3 -> 6", function()
    T.eq(M.roll("2*3", max_rng), 6)
  end)

  T.it("10/3 -> 3 (floor division)", function()
    T.eq(M.roll("10/3", max_rng), 3)
  end)

  T.it("(d1+2)*3 -> 9", function()
    T.eq(M.roll("(d1+2)*3", max_rng), 9)
  end)

  T.it("negative constant: -5 -> -5", function()
    T.eq(M.roll("-5", max_rng), -5)  -- actually parsed as neg(5)
  end)
end)

T.describe("M.roll range checks", function()
  T.it("d% in 1..100", function()
    local v = M.roll("d%")
    T.ok(v >= 1 and v <= 100, "d% out of range: " .. tostring(v))
  end)

  T.it("dF in -1..1", function()
    local v = M.roll("dF")
    T.ok(v >= -1 and v <= 1, "dF out of range: " .. tostring(v))
  end)

  T.it("dF with max_rng -> 1", function()
    -- max_rng(3) = 3; 3-2 = 1
    T.eq(M.roll("dF", max_rng), 1)
  end)

  T.it("dF with min_rng -> -1", function()
    T.eq(M.roll("dF", min_rng), -1)
  end)

  T.it("3dF with max_rng -> 3", function()
    T.eq(M.roll("3dF", max_rng), 3)
  end)

  T.it("3dF with min_rng -> -3", function()
    T.eq(M.roll("3dF", min_rng), -3)
  end)

  T.it("d6 in 1..6", function()
    for _ = 1, 50 do
      local v = M.roll("d6")
      T.ok(v >= 1 and v <= 6)
    end
  end)

  T.it("3d6+2 in 5..20", function()
    for _ = 1, 20 do
      local v = M.roll("3d6+2")
      T.ok(v >= 5 and v <= 20)
    end
  end)
end)

T.describe("M.roll_detailed", function()
  T.it("3d1+2 -> total=5 with rolls", function()
    local d, err = M.roll_detailed("3d1+2", max_rng)
    T.eq(err, nil)
    T.eq(d.total, 5)
    T.ok(type(d.rolls) == "table")
    T.ok(#d.rolls >= 1)
    T.ok(type(d.breakdown) == "string")
  end)

  T.it("3d1+2 rolls entry has label and dice", function()
    local d = M.roll_detailed("3d1+2", max_rng)
    local r = d.rolls[1]
    T.ok(r ~= nil)
    T.eq(r.sum, 3)
    T.eq(#r.dice, 3)
    T.eq(r.dice[1], 1)
  end)

  T.it("4d1k3 detailed kept=3 dropped=1", function()
    local d = M.roll_detailed("4d1k3", max_rng)
    T.eq(d.total, 3)
    local r = d.rolls[1]
    T.eq(#r.kept, 3)
    T.eq(#r.dropped, 1)
  end)

  T.it("breakdown contains dice notation label", function()
    local d = M.roll_detailed("2d6", max_rng)
    T.ok(d.breakdown:find("2d6"), "breakdown should mention '2d6'")
  end)

  T.it("constant only", function()
    local d = M.roll_detailed("5", max_rng)
    T.eq(d.total, 5)
    T.eq(#d.rolls, 0)
  end)
end)

T.describe("M.stats", function()
  T.it("1d6: min=1, max=6, mean=3.5", function()
    local s = M.stats("1d6")
    T.eq(s.min, 1)
    T.eq(s.max, 6)
    T.eq(s.mean, 3.5)
    T.ok(s.variance > 0)
    T.ok(s.stddev > 0)
  end)

  T.it("1d6: stddev = sqrt(variance)", function()
    local s = M.stats("1d6")
    local diff = math.abs(s.stddev - math.sqrt(s.variance))
    T.ok(diff < 1e-9)
  end)

  T.it("2d6: min=2, max=12, mean=7.0", function()
    local s = M.stats("2d6")
    T.eq(s.min, 2)
    T.eq(s.max, 12)
    T.eq(s.mean, 7.0)
  end)

  T.it("1d6+2: min=3, max=8, mean=5.5", function()
    local s = M.stats("1d6+2")
    T.eq(s.min, 3)
    T.eq(s.max, 8)
    T.eq(s.mean, 5.5)
  end)

  T.it("constant 5: min=max=mean=5, variance=0", function()
    local s = M.stats("5")
    T.eq(s.min, 5)
    T.eq(s.max, 5)
    T.eq(s.mean, 5)
    T.eq(s.variance, 0)
    T.eq(s.stddev, 0)
  end)

  T.it("1d4+1d8: mean = sum of means", function()
    local s = M.stats("1d4+1d8")
    -- 1d4 mean=2.5, 1d8 mean=4.5 → 7.0
    T.eq(s.mean, 7.0)
    T.eq(s.min, 2)
    T.eq(s.max, 12)
  end)

  T.it("3d6: mean=10.5", function()
    local s = M.stats("3d6")
    T.eq(s.mean, 10.5)
    T.eq(s.min, 3)
    T.eq(s.max, 18)
  end)

  T.it("1d6-1: min=0, max=5, mean=2.5", function()
    local s = M.stats("1d6-1")
    T.eq(s.min, 0)
    T.eq(s.max, 5)
    T.eq(s.mean, 2.5)
  end)

  T.it("4d6k3: returns stats table (simulation fallback)", function()
    local s = M.stats("4d6k3")
    T.ok(s.min >= 3 and s.min <= 6)
    T.ok(s.max >= 12 and s.max <= 18)
    T.ok(s.mean > 10 and s.mean < 14)  -- approximately 12.24
    T.ok(s.stddev > 0)
  end)

  T.it("dF: min=-1, max=1, mean=0", function()
    local s = M.stats("dF")
    T.eq(s.min, -1)
    T.eq(s.max, 1)
    T.eq(s.mean, 0)
  end)
end)

T.describe("M.simulate", function()
  T.it("returns frequency table", function()
    local freq = M.simulate("1d6", 600)
    T.ok(type(freq) == "table")
    local total = 0
    for _, c in pairs(freq) do total = total + c end
    T.eq(total, 600)
  end)

  T.it("d1 always 1", function()
    local freq = M.simulate("d1", 100, max_rng)
    T.eq(freq[1], 100)
    T.eq(freq[2], nil)
  end)

  T.it("all values in range for d6", function()
    local freq = M.simulate("1d6", 600)
    for v, _ in pairs(freq) do
      T.ok(v >= 1 and v <= 6)
    end
  end)
end)

T.describe("M.roll error cases", function()
  T.it("empty string -> nil, err", function()
    local v, err = M.roll("")
    T.eq(v, nil)
    T.ok(type(err) == "string")
  end)

  T.it("non-string -> nil, err", function()
    local v, err = M.roll(42)
    T.eq(v, nil)
    T.ok(type(err) == "string")
  end)

  T.it("returns nil,err for division by zero", function()
    -- d1/0 isn't directly parseable; craft AST manually
    local ast = { type = "binop", op = "/",
                  left  = { type = "constant", value = 5 },
                  right = { type = "constant", value = 0 } }
    local v, err = M.roll(ast, max_rng)
    T.eq(v, nil)
    T.ok(type(err) == "string")
  end)
end)

T.describe("M.d convenience", function()
  T.it("M.d(6) in 1..6", function()
    local v = M.d(6)
    T.ok(v >= 1 and v <= 6)
  end)
end)

T.describe("M.roll_str convenience", function()
  T.it("M.roll_str('d1') -> 1", function()
    -- Uses math.random; d1 is always 1
    T.eq(M.roll_str("d1"), 1)
  end)
end)

T.describe("exploding dice", function()
  T.it("d6! with max_rng produces value > 6", function()
    -- max_rng(6) = 6 → explode. max_rng(6) = 6 again → boom cap at 100.
    -- Result: 6 * 100 + 6 (very large), all 6s.
    local v = M.roll("d6!", max_rng)
    T.ok(v > 6, "exploding die should exceed max sides")
  end)

  T.it("d6! with min_rng -> 1 (no explosion)", function()
    T.eq(M.roll("d6!", min_rng), 1)
  end)
end)
