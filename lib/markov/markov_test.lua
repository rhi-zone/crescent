if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local M = require("lib.markov")

-- Helper: create a chain with a fixed seed so tests are deterministic.
local function seeded_chain(order, seed)
  return M.chain(order or 1, seed or 42)
end

-- ---------------------------------------------------------------------------
T.describe("markov.chain basics", function()

  T.it("returns a chain object with expected fields", function()
    local c = M.chain(1, 42)
    T.ok(c ~= nil, "chain is not nil")
    T.ok(type(c.train)       == "function", "has train()")
    T.ok(type(c.generate)    == "function", "has generate()")
    T.ok(type(c.next)        == "function", "has next()")
    T.ok(type(c.transitions) == "function", "has transitions()")
    T.ok(type(c.save)        == "function", "has save()")
    T.eq(M._tier, "pure")
  end)

  T.it("trains on a string and populates transition table", function()
    local c = M.chain(1, 42)
    c:train("a b c")
    -- <START> -> a
    local t = c:transitions(M.START)
    T.eq(t["a"], 1)
    -- a -> b
    local ta = c:transitions("a")
    T.eq(ta["b"], 1)
  end)

  T.it("trains on a token array", function()
    local c = M.chain(1, 42)
    c:train({ "x", "y", "z" })
    local t = c:transitions(M.START)
    T.eq(t["x"], 1)
  end)

  T.it("accumulates counts across multiple train calls", function()
    local c = M.chain(1, 42)
    c:train("a b")
    c:train("a c")
    local t = c:transitions("a")
    T.eq(t["b"], 1)
    T.eq(t["c"], 1)
  end)

end)

-- ---------------------------------------------------------------------------
T.describe("markov.transitions", function()

  T.it("returns empty table for unknown context", function()
    local c = M.chain(1, 42)
    c:train("hello world")
    local t = c:transitions("unknown")
    T.eq(next(t), nil, "empty for unknown context")
  end)

  T.it("returns correct counts for order-1 chain", function()
    local c = M.chain(1, 42)
    c:train("a b a b a c")
    local t = c:transitions("a")
    T.eq(t["b"], 2)
    T.eq(t["c"], 1)
  end)

  T.it("returns correct counts for order-2 chain", function()
    local c = M.chain(2, 42)
    c:train("a b c b c d")
    -- context "b\0c" should have both "b" and "d" as successors
    local t = c:transitions({ "b", "c" })
    T.eq(t["b"], 1)
    T.eq(t["d"], 1)
  end)

  T.it("transitions returns a copy, not internal state", function()
    local c = M.chain(1, 42)
    c:train("a b")
    local t = c:transitions("a")
    t["b"] = 999
    local t2 = c:transitions("a")
    T.eq(t2["b"], 1, "internal state not modified")
  end)

end)

-- ---------------------------------------------------------------------------
T.describe("markov.next", function()

  T.it("returns a token and probability from known context", function()
    local c = seeded_chain(1, 1)
    c:train("a b c b c b")
    local tok, prob = c:next("b")
    -- after "b" the valid successors are "c" and <END>
    local valid = { c = true, [M.END] = true }
    T.ok(valid[tok], "token is a valid successor of b")
    T.ok(prob > 0 and prob <= 1, "probability in (0,1]")
  end)

  T.it("returns nil, 0 for unknown context", function()
    local c = M.chain(1, 42)
    c:train("a b")
    local tok, prob = c:next("z")
    T.eq(tok, nil)
    T.eq(prob, 0)
  end)

  T.it("deterministic with fixed seed", function()
    -- Train same data twice with same seed → same first prediction.
    local function make()
      local c = seeded_chain(1, 7)
      c:train("cat sat on the mat the cat sat")
      return c
    end
    local c1, c2 = make(), make()
    local tok1 = c1:next("cat")
    local tok2 = c2:next("cat")
    T.eq(tok1, tok2, "same token with same seed")
  end)

end)

-- ---------------------------------------------------------------------------
T.describe("markov.generate", function()

  T.it("generates a non-empty string from trained chain", function()
    local c = seeded_chain(1, 99)
    c:train("the quick brown fox jumps over the lazy dog")
    local out = c:generate()
    T.ok(type(out) == "string", "output is string")
    T.ok(#out > 0, "output is non-empty")
  end)

  T.it("respects max_tokens limit", function()
    local c = seeded_chain(1, 5)
    -- Create a cycle: a -> b -> a -> b ...
    for _ = 1, 20 do c:train("a b") end
    local out = c:generate({ max_tokens = 3, seed_token = "a" })
    local tokens = {}
    for tok in out:gmatch("%S+") do tokens[#tokens + 1] = tok end
    T.ok(#tokens <= 3, "at most 3 tokens")
  end)

  T.it("uses seed_token as first token", function()
    local c = seeded_chain(1, 11)
    c:train("hello world foo bar")
    local out = c:generate({ seed_token = "hello", max_tokens = 1 })
    -- First token must be "hello"
    T.eq(out:match("^%S+"), "hello")
  end)

  T.it("uses custom separator", function()
    local c = seeded_chain(1, 3)
    c:train("a b c d e")
    local out = c:generate({ max_tokens = 3, separator = "-" })
    T.ok(not out:find(" "), "no spaces in output")
  end)

  T.it("returns empty string for empty chain", function()
    local c = M.chain(1, 42)
    local out = c:generate()
    T.eq(out, "")
  end)

  T.it("order-2 chain generates coherent text", function()
    local c = seeded_chain(2, 21)
    c:train("I am Sam Sam I am I do not like green eggs and ham")
    local out = c:generate({ max_tokens = 10 })
    T.ok(type(out) == "string", "generates a string")
  end)

  T.it("deterministic output with same seed", function()
    local function run()
      local c = seeded_chain(1, 42)
      c:train("one two three four five one two three")
      return c:generate({ max_tokens = 5 })
    end
    T.eq(run(), run(), "identical output with same seed")
  end)

end)

-- ---------------------------------------------------------------------------
T.describe("markov.save / load", function()

  T.it("round-trips a chain through save/load", function()
    local c = seeded_chain(1, 77)
    c:train("alpha beta gamma alpha beta delta")
    local snap = c:save()
    local c2 = M.load(snap, 77)
    -- Transitions should be identical.
    local t1 = c:transitions("alpha")
    local t2 = c2:transitions("alpha")
    T.eq(t1["beta"],  t2["beta"])
    T.eq(t1["delta"], t2["delta"])
  end)

  T.it("loaded chain can generate text", function()
    local c = seeded_chain(1, 33)
    c:train("foo bar baz foo bar qux")
    local snap = c:save()
    local c2 = M.load(snap, 33)
    local out = c2:generate({ max_tokens = 5 })
    T.ok(type(out) == "string", "loaded chain generates a string")
  end)

  T.it("snapshot contains order and table keys", function()
    local c = M.chain(2, 42)
    c:train("a b c")
    local snap = c:save()
    T.eq(snap.order, 2)
    T.ok(type(snap.table) == "table", "snapshot has table")
  end)

end)

-- ---------------------------------------------------------------------------
T.describe("markov.from_text", function()

  T.it("builds and trains a chain in one call", function()
    local c = M.from_text("red green blue red green", 42)
    local t = c:transitions("red")
    T.eq(t["green"], 2)
  end)

  T.it("accepts custom order", function()
    local c = M.from_text("a b c d e", 42, 2)
    -- context a\0b -> c
    local t = c:transitions({ "a", "b" })
    T.eq(t["c"], 1)
  end)

end)

-- ---------------------------------------------------------------------------
T.describe("markov edge cases", function()

  T.it("empty string training produces no usable transitions", function()
    local c = M.chain(1, 42)
    c:train("")
    -- Only <START> -> <END> transition exists.
    local t = c:transitions(M.START)
    T.eq(t[M.END], 1)
  end)

  T.it("single token training", function()
    local c = M.chain(1, 42)
    c:train("hello")
    local t = c:transitions(M.START)
    T.eq(t["hello"], 1)
    local t2 = c:transitions("hello")
    T.eq(t2[M.END], 1)
  end)

  T.it("generate from single-token chain returns that token", function()
    local c = seeded_chain(1, 9)
    c:train("hello")
    local out = c:generate({ max_tokens = 10 })
    T.eq(out, "hello")
  end)

  T.it("training multiple sentences accumulates START transitions", function()
    local c = M.chain(1, 42)
    c:train("a b")
    c:train("c d")
    local t = c:transitions(M.START)
    T.eq(t["a"], 1)
    T.eq(t["c"], 1)
  end)

end)
