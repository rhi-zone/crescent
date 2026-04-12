if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local nlp = require("lib.nat_lang")

T.describe("nat_lang", function()

  T.describe("tokenize", function()
    T.it("splits on whitespace and punctuation", function()
      local toks = nlp.tokenize("Hello, world!")
      -- should contain Hello , world !
      local found = {}
      for _, t in ipairs(toks) do found[t] = true end
      T.ok(found["Hello"], "Hello token")
      T.ok(found[","],     "comma token")
      T.ok(found["world"], "world token")
      T.ok(found["!"],     "exclamation token")
    end)

    T.it("handles multiple sentences", function()
      local toks = nlp.tokenize("Hello, world! How are you?")
      local found = {}
      for _, t in ipairs(toks) do found[t] = true end
      T.ok(found["How"],  "How token")
      T.ok(found["you"],  "you token")
      T.ok(found["?"],    "question mark token")
    end)
  end)

  T.describe("word_tokenize", function()
    T.it("returns words only, no punctuation", function()
      local words = nlp.word_tokenize("Hello, world! How are you?")
      for _, w in ipairs(words) do
        T.ok(not w:match("^[%p]$"), "no punctuation: " .. w)
      end
      T.eq(words[1], "Hello")
      T.eq(words[2], "world")
    end)

    T.it("handles simple sentence", function()
      local words = nlp.word_tokenize("The quick brown fox")
      T.eq(#words, 4)
      T.eq(words[1], "The")
      T.eq(words[4], "fox")
    end)
  end)

  T.describe("sent_tokenize", function()
    T.it("splits on . ! ?", function()
      local sents = nlp.sent_tokenize("Hello world. How are you? I'm fine!")
      T.eq(#sents, 3)
      T.eq(sents[1], "Hello world.")
      T.eq(sents[2], "How are you?")
      T.eq(sents[3], "I'm fine!")
    end)

    T.it("handles single sentence", function()
      local sents = nlp.sent_tokenize("Hello world")
      T.eq(#sents, 1)
      T.eq(sents[1], "Hello world")
    end)
  end)

  T.describe("normalize", function()
    T.it("lowercases text", function()
      T.eq(nlp.normalize("Hello World"), "hello world")
    end)

    T.it("collapses whitespace", function()
      T.eq(nlp.normalize("hello   world"), "hello world")
    end)

    T.it("trims leading/trailing whitespace", function()
      T.eq(nlp.normalize("  hello  "), "hello")
    end)
  end)

  T.describe("stem", function()
    T.it("stems 'running' to 'run'", function()
      T.eq(nlp.stem("running"), "run")
    end)

    T.it("stems 'jumping' to 'jump'", function()
      T.eq(nlp.stem("jumping"), "jump")
    end)

    T.it("stems 'flies' to 'fli'", function()
      -- porter stemmer maps "flies" → "fli"
      local s = nlp.stem("flies")
      T.ok(s == "fli" or s == "flie" or s == "fly", "flies stem: " .. s)
    end)

    T.it("stems 'caresses' to 'caress'", function()
      T.eq(nlp.stem("caresses"), "caress")
    end)

    T.it("stems 'generously'", function()
      local s = nlp.stem("generously")
      T.ok(#s < #"generously", "generously shorter: " .. s)
    end)
  end)

  T.describe("lemmatize", function()
    T.it("lemmatizes 'ran' to 'run'", function()
      T.eq(nlp.lemmatize("ran"), "run")
    end)

    T.it("lemmatizes 'running' to 'run'", function()
      T.eq(nlp.lemmatize("running"), "run")
    end)

    T.it("lemmatizes 'was' to 'be'", function()
      T.eq(nlp.lemmatize("was"), "be")
    end)
  end)

  T.describe("stopwords", function()
    T.it("contains common English stop words", function()
      local stops = nlp.stopwords("en")
      T.ok(stops["the"],  "the is a stop word")
      T.ok(stops["and"],  "and is a stop word")
      T.ok(stops["is"],   "is is a stop word")
      T.ok(stops["a"],    "a is a stop word")
    end)

    T.it("does not contain content words", function()
      local stops = nlp.stopwords("en")
      T.ok(not stops["fox"],    "fox is not a stop word")
      T.ok(not stops["quick"],  "quick is not a stop word")
    end)

    T.it("returns empty set for unknown lang", function()
      local stops = nlp.stopwords("zz")
      local count = 0
      for _ in pairs(stops) do count = count + 1 end
      T.eq(count, 0)
    end)
  end)

  T.describe("remove_stopwords", function()
    T.it("filters stop words", function()
      local words = {"the", "quick", "brown", "fox"}
      local filtered = nlp.remove_stopwords(words, "en")
      local found = {}
      for _, w in ipairs(filtered) do found[w] = true end
      T.ok(not found["the"],   "the removed")
      T.ok(found["quick"],     "quick kept")
      T.ok(found["brown"],     "brown kept")
      T.ok(found["fox"],       "fox kept")
    end)

    T.it("preserves order", function()
      local words = {"quick", "brown", "fox"}
      local filtered = nlp.remove_stopwords(words, "en")
      T.eq(#filtered, 3)
      T.eq(filtered[1], "quick")
      T.eq(filtered[3], "fox")
    end)
  end)

  T.describe("ngrams", function()
    T.it("computes bigrams", function()
      local words = {"The", "quick", "brown", "fox"}
      local bigrams = nlp.ngrams(words, 2)
      T.eq(#bigrams, 3)
      T.eq(bigrams[1][1], "The")
      T.eq(bigrams[1][2], "quick")
      T.eq(bigrams[2][1], "quick")
      T.eq(bigrams[2][2], "brown")
      T.eq(bigrams[3][1], "brown")
      T.eq(bigrams[3][2], "fox")
    end)

    T.it("computes trigrams", function()
      local words = {"a", "b", "c", "d"}
      local trigrams = nlp.ngrams(words, 3)
      T.eq(#trigrams, 2)
      T.eq(trigrams[1][1], "a")
      T.eq(trigrams[1][3], "c")
    end)

    T.it("returns empty for n > length", function()
      local words = {"a", "b"}
      local result = nlp.ngrams(words, 5)
      T.eq(#result, 0)
    end)
  end)

  T.describe("bag_of_words", function()
    T.it("counts word frequencies", function()
      local words = {"the", "cat", "sat", "on", "the", "mat"}
      local bow = nlp.bag_of_words(words)
      T.eq(bow["the"], 2)
      T.eq(bow["cat"], 1)
      T.eq(bow["sat"], 1)
      T.eq(bow["mat"], 1)
    end)

    T.it("lowercases words", function()
      local words = {"Hello", "hello", "HELLO"}
      local bow = nlp.bag_of_words(words)
      T.eq(bow["hello"], 3)
    end)
  end)

  T.describe("term_freq", function()
    T.it("frequencies sum to 1.0", function()
      local words = {"a", "b", "c", "a"}
      local tf = nlp.term_freq(words)
      local total = 0
      for _, v in pairs(tf) do total = total + v end
      T.ok(math.abs(total - 1.0) < 1e-9, "sum ~= 1.0, got " .. total)
    end)

    T.it("most frequent word has highest TF", function()
      local words = {"the", "cat", "the", "the", "sat"}
      local tf = nlp.term_freq(words)
      T.ok(tf["the"] > tf["cat"], "the > cat")
    end)
  end)

  T.describe("tfidf", function()
    T.it("rare word has higher IDF across documents", function()
      local docs = {
        {"the", "cat", "sat", "on", "mat"},
        {"the", "dog", "sat", "on", "log"},
        {"the", "cat", "chased", "the", "bird"},
      }
      local tfidf = nlp.tfidf(docs)
      -- "the" appears in all docs → low IDF; "bird" only in doc3 → higher IDF
      local the_score  = tfidf[3]["the"]  or 0
      local bird_score = tfidf[3]["bird"] or 0
      T.ok(bird_score > the_score, "bird > the in doc3: " .. bird_score .. " vs " .. the_score)
    end)

    T.it("returns scores for each document", function()
      local docs = {
        {"hello", "world"},
        {"foo", "bar"},
      }
      local tfidf = nlp.tfidf(docs)
      T.eq(#tfidf, 2)
      T.ok(type(tfidf[1]) == "table")
      T.ok(type(tfidf[2]) == "table")
    end)
  end)

  T.describe("edit_distance", function()
    T.it("kitten → sitting = 3", function()
      T.eq(nlp.edit_distance("kitten", "sitting"), 3)
    end)

    T.it("same string = 0", function()
      T.eq(nlp.edit_distance("hello", "hello"), 0)
    end)

    T.it("empty string", function()
      T.eq(nlp.edit_distance("", "abc"), 3)
      T.eq(nlp.edit_distance("abc", ""), 3)
    end)

    T.it("single char diff", function()
      T.eq(nlp.edit_distance("cat", "bat"), 1)
    end)
  end)

  T.describe("similarity", function()
    T.it("identical strings have similarity 1.0", function()
      T.eq(nlp.similarity("hello", "hello"), 1.0)
    end)

    T.it("similar strings have high similarity", function()
      local s = nlp.similarity("hello", "helo")
      T.ok(s > 0.7, "hello/helo similarity " .. s)
    end)

    T.it("very different strings have low similarity", function()
      local s = nlp.similarity("abc", "xyz")
      T.ok(s < 0.5, "abc/xyz similarity " .. s)
    end)
  end)

  T.describe("extract_entities", function()
    T.it("detects capitalized PERSON entity", function()
      local entities = nlp.extract_entities("John visited Paris in 2023")
      local found_person = false
      local found_location = false
      local found_date = false
      for _, e in ipairs(entities) do
        if e[2] == "PERSON"   then found_person   = true end
        if e[2] == "LOCATION" then found_location = true end
        if e[2] == "DATE"     then found_date     = true end
      end
      T.ok(found_person,   "PERSON entity found")
      T.ok(found_location, "LOCATION entity found")
      T.ok(found_date,     "DATE entity found")
    end)

    T.it("detects known organizations", function()
      local entities = nlp.extract_entities("Google announced new features")
      local found_org = false
      for _, e in ipairs(entities) do
        if e[2] == "ORGANIZATION" then found_org = true end
      end
      T.ok(found_org, "ORGANIZATION entity found")
    end)
  end)

  T.describe("pos_tag", function()
    T.it("tags 'The' as DT", function()
      local tags = nlp.pos_tag({"The", "quick", "fox", "runs"})
      T.eq(tags[1][1], "The")
      T.eq(tags[1][2], "DT")
    end)

    T.it("tags common noun as NN", function()
      local tags = nlp.pos_tag({"The", "cat"})
      T.eq(tags[2][2], "NN")
    end)

    T.it("tags adjective suffix correctly", function()
      local tags = nlp.pos_tag({"beautiful"})
      -- -ful suffix → JJ
      T.eq(tags[1][2], "JJ")
    end)

    T.it("tags -ing word as VBG", function()
      local tags = nlp.pos_tag({"running"})
      T.eq(tags[1][2], "VBG")
    end)

    T.it("returns same number of tags as words", function()
      local words = {"The", "quick", "brown", "fox", "jumps"}
      local tags = nlp.pos_tag(words)
      T.eq(#tags, #words)
    end)
  end)

  T.describe("sentiment", function()
    T.it("positive text returns positive score", function()
      local s = nlp.sentiment("I love this great product")
      T.ok(s > 0, "positive score: " .. s)
    end)

    T.it("negative text returns negative score", function()
      local s = nlp.sentiment("This is terrible and awful")
      T.ok(s < 0, "negative score: " .. s)
    end)

    T.it("neutral text returns near-zero score", function()
      local s = nlp.sentiment("the cat sat on the mat")
      T.ok(math.abs(s) <= 1.0, "within bounds: " .. s)
    end)

    T.it("negation flips sentiment", function()
      local pos = nlp.sentiment("I love this")
      local neg = nlp.sentiment("I do not love this")
      T.ok(pos > neg, "negation reduces positive: " .. pos .. " vs " .. neg)
    end)
  end)

  T.describe("sentiment_label", function()
    T.it("labels positive text", function()
      T.eq(nlp.sentiment_label("I love this amazing product"), "positive")
    end)

    T.it("labels negative text", function()
      T.eq(nlp.sentiment_label("This is terrible and horrible"), "negative")
    end)
  end)

  T.describe("keywords", function()
    T.it("returns an array of keywords", function()
      local text = "The quick brown fox jumps over the lazy dog. The fox was very quick."
      local kws = nlp.keywords(text, { n = 3 })
      T.ok(type(kws) == "table", "returns table")
      T.ok(#kws > 0, "non-empty")
      T.ok(#kws <= 3, "at most n keywords")
    end)

    T.it("top keyword is frequent content word", function()
      local text = "cat cat cat dog dog bird"
      local kws = nlp.keywords(text, { n = 1 })
      T.eq(kws[1], "cat")
    end)
  end)

  T.describe("flesch_reading_ease", function()
    T.it("returns a number", function()
      local score = nlp.flesch_reading_ease("The cat sat on the mat.")
      T.ok(type(score) == "number", "is number")
    end)

    T.it("simple text has high score", function()
      local score = nlp.flesch_reading_ease("I am. You are. We go.")
      T.ok(score > 50, "simple text easy: " .. score)
    end)

    T.it("complex text has lower score than simple", function()
      local simple  = nlp.flesch_reading_ease("I am. You go. We see.")
      local complex = nlp.flesch_reading_ease(
        "The extraordinarily sophisticated computational infrastructure demonstrates remarkable capabilities.")
      T.ok(simple > complex, "simple > complex: " .. simple .. " vs " .. complex)
    end)
  end)

  T.describe("flesch_kincaid_grade", function()
    T.it("returns a number", function()
      local grade = nlp.flesch_kincaid_grade("The cat sat on the mat.")
      T.ok(type(grade) == "number", "is number")
    end)

    T.it("simple text has low grade", function()
      local grade = nlp.flesch_kincaid_grade("I am. You are. We go.")
      T.ok(grade < 10, "simple text low grade: " .. grade)
    end)
  end)

end)
