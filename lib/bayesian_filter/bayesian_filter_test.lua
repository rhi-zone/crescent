if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local BF = require("lib.bayesian_filter")

T.describe("bayesian_filter", function()

  T.describe("empty classifier", function()
    T.it("classify on empty classifier returns nil label and empty scores", function()
      local clf = BF.new()
      local label, scores = clf:classify("some text")
      T.eq(label, nil)
      T.eq(type(scores), "table")
    end)

    T.it("scores on empty classifier returns empty table", function()
      local clf = BF.new()
      local scores = clf:scores("some text")
      T.eq(type(scores), "table")
      T.eq(next(scores), nil)
    end)
  end)

  T.describe("single category", function()
    T.it("always classifies as the only category", function()
      local clf = BF.new()
      clf:train("cat", "hello world test")
      clf:train("cat", "more training data")
      local label, scores = clf:classify("anything at all")
      T.eq(label, "cat")
      T.eq(type(scores), "table")
      T.ok(scores["cat"] ~= nil)
    end)
  end)

  T.describe("spam/ham classifier", function()
    local function make_clf()
      local clf = BF.new()
      clf:train("spam", "buy now cheap pills free offer")
      clf:train("spam", "click here for free money")
      clf:train("spam", "limited time offer buy cheap discount")
      clf:train("ham", "meeting at 3pm tomorrow")
      clf:train("ham", "project status update for the team")
      clf:train("ham", "let us schedule a call to discuss the plan")
      return clf
    end

    T.it("classifies obvious spam as spam", function()
      local clf = make_clf()
      local label = clf:classify("buy cheap pills free money offer")
      T.eq(label, "spam")
    end)

    T.it("classifies obvious ham as ham", function()
      local clf = make_clf()
      local label = clf:classify("meeting tomorrow to discuss the project status")
      T.eq(label, "ham")
    end)

    T.it("classify returns string label and table scores", function()
      local clf = make_clf()
      local label, scores = clf:classify("free money offer")
      T.eq(type(label), "string")
      T.eq(type(scores), "table")
    end)

    T.it("scores sum to approximately 1.0", function()
      local clf = make_clf()
      local _, scores = clf:classify("free money offer")
      local total = 0
      for _, v in pairs(scores) do
        total = total + v
      end
      T.ok(math.abs(total - 1.0) < 1e-9)
    end)

    T.it("scores are between 0 and 1", function()
      local clf = make_clf()
      local _, scores = clf:classify("free money offer")
      for _, v in pairs(scores) do
        T.ok(v >= 0 and v <= 1)
      end
    end)
  end)

  T.describe("training accumulation", function()
    T.it("training same category multiple times accumulates stats", function()
      local clf = BF.new()
      clf:train("a", "hello world")
      clf:train("a", "hello again")
      clf:train("b", "goodbye world")
      local stats = clf:stats()
      T.eq(stats.total_docs, 3)
      T.eq(stats.category_stats["a"].doc_count, 2)
      T.eq(stats.category_stats["b"].doc_count, 1)
    end)
  end)

  T.describe("unknown words", function()
    T.it("handles words not in training data gracefully via Laplace smoothing", function()
      local clf = BF.new()
      clf:train("pos", "good great excellent")
      clf:train("neg", "bad terrible awful")
      -- Words completely unseen
      local label, scores = clf:classify("zzzzunknownword xyzzy")
      T.eq(type(label), "string")
      T.eq(type(scores), "table")
      -- Scores still sum to 1
      local total = 0
      for _, v in pairs(scores) do total = total + v end
      T.ok(math.abs(total - 1.0) < 1e-9)
    end)
  end)

  T.describe("serialize/deserialize", function()
    T.it("round-trip produces same classification result", function()
      local clf = BF.new()
      clf:train("spam", "buy now cheap pills free offer")
      clf:train("spam", "click here for free money")
      clf:train("ham", "meeting at 3pm tomorrow")
      clf:train("ham", "project status update for the team")

      local t = clf:serialize()
      local clf2 = BF.deserialize(t)

      local label1, scores1 = clf:classify("free money offer")
      local label2, scores2 = clf2:classify("free money offer")

      T.eq(label1, label2)
      -- Scores should be numerically identical
      for k, v in pairs(scores1) do
        T.ok(math.abs(v - scores2[k]) < 1e-12)
      end
    end)

    T.it("serialize returns a table", function()
      local clf = BF.new()
      clf:train("x", "hello world")
      local t = clf:serialize()
      T.eq(type(t), "table")
    end)
  end)

  T.describe("stats", function()
    T.it("returns correct doc counts", function()
      local clf = BF.new()
      clf:train("a", "one two three")
      clf:train("b", "four five")
      clf:train("a", "six seven")
      local stats = clf:stats()
      T.eq(stats.total_docs, 3)
      T.eq(stats.category_stats["a"].doc_count, 2)
      T.eq(stats.category_stats["b"].doc_count, 1)
    end)

    T.it("categories list has correct length", function()
      local clf = BF.new()
      clf:train("x", "hello")
      clf:train("y", "world")
      clf:train("z", "foo")
      local stats = clf:stats()
      T.eq(#stats.categories, 3)
    end)

    T.it("vocab_size is correct", function()
      local clf = BF.new()
      clf:train("a", "hello world")
      clf:train("b", "hello lua")  -- "hello" already counted
      local stats = clf:stats()
      -- unique words: hello, world, lua = 3
      T.eq(stats.vocab_size, 3)
    end)
  end)

  T.describe("classify_all", function()
    T.it("returns same-length array", function()
      local clf = BF.new()
      clf:train("pos", "good great")
      clf:train("neg", "bad awful")
      local texts = {"good text", "bad text", "neutral text"}
      local results = clf:classify_all(texts)
      T.eq(#results, 3)
    end)

    T.it("each result is a string label", function()
      local clf = BF.new()
      clf:train("pos", "good great")
      clf:train("neg", "bad awful")
      local results = clf:classify_all({"good", "bad"})
      T.eq(type(results[1]), "string")
      T.eq(type(results[2]), "string")
    end)
  end)

  T.describe("reset", function()
    T.it("clears all state", function()
      local clf = BF.new()
      clf:train("spam", "buy now")
      clf:train("ham", "hello there")
      clf:reset()
      local stats = clf:stats()
      T.eq(stats.total_docs, 0)
      T.eq(#stats.categories, 0)
      T.eq(stats.vocab_size, 0)
    end)

    T.it("after reset, classify returns nil", function()
      local clf = BF.new()
      clf:train("a", "hello")
      clf:reset()
      local label, scores = clf:classify("hello")
      T.eq(label, nil)
    end)
  end)

  T.describe("multi-category (topics)", function()
    T.it("classifies sports text as sports", function()
      local clf = BF.new()
      clf:train("sports", "football goal scored match player team")
      clf:train("sports", "basketball court score points game")
      clf:train("tech", "python programming code function variable")
      clf:train("tech", "software algorithm data structure computer")
      clf:train("cooking", "recipe ingredients flour butter bake oven")
      clf:train("cooking", "cook boil simmer sauce pan heat")

      local label = clf:classify("football goal scored player")
      T.eq(label, "sports")
    end)

    T.it("classifies tech text as tech", function()
      local clf = BF.new()
      clf:train("sports", "football goal scored match player team")
      clf:train("sports", "basketball court score points game")
      clf:train("tech", "python programming code function variable")
      clf:train("tech", "software algorithm data structure computer")
      clf:train("cooking", "recipe ingredients flour butter bake oven")
      clf:train("cooking", "cook boil simmer sauce pan heat")

      local label = clf:classify("python programming code")
      T.eq(label, "tech")
    end)

    T.it("classifies cooking text as cooking", function()
      local clf = BF.new()
      clf:train("sports", "football goal scored match player team")
      clf:train("sports", "basketball court score points game")
      clf:train("tech", "python programming code function variable")
      clf:train("tech", "software algorithm data structure computer")
      clf:train("cooking", "recipe ingredients flour butter bake oven")
      clf:train("cooking", "cook boil simmer sauce pan heat")

      local label = clf:classify("recipe bake oven flour butter")
      T.eq(label, "cooking")
    end)

    T.it("scores sum to 1.0 with 3 categories", function()
      local clf = BF.new()
      clf:train("a", "apple orange banana")
      clf:train("b", "car truck bus")
      clf:train("c", "dog cat fish")
      local _, scores = clf:classify("apple car dog")
      local total = 0
      for _, v in pairs(scores) do total = total + v end
      T.ok(math.abs(total - 1.0) < 1e-9)
    end)
  end)

end)
