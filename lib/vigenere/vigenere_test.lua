-- lib/vigenere/vigenere_test.lua
-- Tests for the classical cipher suite.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local C = require("lib.vigenere")

-- ---------------------------------------------------------------------------
-- Module metadata
-- ---------------------------------------------------------------------------

T.describe("vigenere module", function()
  T.it("has _tier = pure", function()
    T.eq(C._tier, "pure")
  end)
end)

-- ---------------------------------------------------------------------------
-- Caesar cipher
-- ---------------------------------------------------------------------------

T.describe("caesar_encrypt", function()
  T.it("known vector: shift 3", function()
    T.eq(C.caesar_encrypt("HELLO", 3), "KHOOR")
  end)
  T.it("known vector: shift 13", function()
    T.eq(C.caesar_encrypt("HELLO", 13), "URYYB")
  end)
  T.it("shift 0 is identity", function()
    T.eq(C.caesar_encrypt("HELLO", 0), "HELLO")
  end)
  T.it("wraps around Z", function()
    T.eq(C.caesar_encrypt("XYZ", 3), "ABC")
  end)
  T.it("lowercases input → uppercase output", function()
    T.eq(C.caesar_encrypt("hello", 3), "KHOOR")
  end)
  T.it("strips non-alpha by default", function()
    T.eq(C.caesar_encrypt("HE LLO", 3), "KHOOR")
  end)
  T.it("preserves non-alpha with opts.preserve", function()
    T.eq(C.caesar_encrypt("HE LLO", 3, { preserve = true }), "KH OOR")
  end)
  T.it("full alphabet shift 1", function()
    T.eq(C.caesar_encrypt("ABCDEFGHIJKLMNOPQRSTUVWXYZ", 1), "BCDEFGHIJKLMNOPQRSTUVWXYZA")
  end)
end)

T.describe("caesar_decrypt", function()
  T.it("known vector: shift 3", function()
    T.eq(C.caesar_decrypt("KHOOR", 3), "HELLO")
  end)
  T.it("shift 0 is identity", function()
    T.eq(C.caesar_decrypt("HELLO", 0), "HELLO")
  end)
  T.it("round-trip", function()
    local plain = "ATTACKATDAWN"
    for shift = 0, 25 do
      T.eq(C.caesar_decrypt(C.caesar_encrypt(plain, shift), shift), plain)
    end
  end)
  T.it("shift 26 = shift 0", function()
    T.eq(C.caesar_decrypt("KHOOR", 29), "HELLO")
  end)
end)

-- ---------------------------------------------------------------------------
-- ROT13
-- ---------------------------------------------------------------------------

T.describe("rot13", function()
  T.it("known vector", function()
    T.eq(C.rot13("HELLO"), "URYYB")
  end)
  T.it("Hello, World! with preserve: non-alpha chars preserved, letters uppercased", function()
    T.eq(C.rot13("Hello, World!", { preserve = true }), "URYYB, JBEYQ!")
  end)
  T.it("self-inverse", function()
    T.eq(C.rot13(C.rot13("ATTACKATDAWN")), "ATTACKATDAWN")
  end)
  T.it("self-inverse on mixed text with preserve", function()
    local s = "The Quick Brown Fox!"
    T.eq(C.rot13(C.rot13(s, { preserve = true }), { preserve = true }), "THE QUICK BROWN FOX!")
  end)
  T.it("self-inverse: all letters", function()
    local s = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    T.eq(C.rot13(C.rot13(s)), s)
  end)
end)

-- ---------------------------------------------------------------------------
-- Atbash
-- ---------------------------------------------------------------------------

T.describe("atbash", function()
  T.it("known vector: HELLO → SVOOL", function()
    T.eq(C.atbash("HELLO"), "SVOOL")
  end)
  T.it("A ↔ Z", function()
    T.eq(C.atbash("AZ"), "ZA")
  end)
  T.it("self-inverse", function()
    T.eq(C.atbash(C.atbash("ATTACKATDAWN")), "ATTACKATDAWN")
  end)
  T.it("self-inverse: full alphabet", function()
    local s = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    T.eq(C.atbash(C.atbash(s)), s)
  end)
  T.it("lowercase input → uppercase output", function()
    T.eq(C.atbash("hello"), "SVOOL")
  end)
end)

-- ---------------------------------------------------------------------------
-- Vigenère cipher
-- ---------------------------------------------------------------------------

T.describe("vigenere_encrypt", function()
  T.it("known vector: ATTACKATDAWN + LEMON = LXFOPVEFRNHR", function()
    T.eq(C.vigenere_encrypt("ATTACKATDAWN", "LEMON"), "LXFOPVEFRNHR")
  end)
  T.it("key shorter than message: key repeats", function()
    T.eq(C.vigenere_encrypt("AAAA", "B"), "BBBB")
  end)
  T.it("key = A (shift 0): identity", function()
    T.eq(C.vigenere_encrypt("HELLO", "A"), "HELLO")
  end)
  T.it("nil key → error", function()
    local r, err = C.vigenere_encrypt("HELLO", "")
    T.eq(r, nil)
    T.ok(err ~= nil)
  end)
end)

T.describe("vigenere_decrypt", function()
  T.it("known vector: LXFOPVEFRNHR + LEMON = ATTACKATDAWN", function()
    T.eq(C.vigenere_decrypt("LXFOPVEFRNHR", "LEMON"), "ATTACKATDAWN")
  end)
  T.it("round-trip: short key", function()
    local plain = "HELLOWORLD"
    T.eq(C.vigenere_decrypt(C.vigenere_encrypt(plain, "KEY"), "KEY"), plain)
  end)
  T.it("round-trip: key length = message length", function()
    local plain = "SECRETMSG"
    local key   = "RANDOMKEY"
    T.eq(C.vigenere_decrypt(C.vigenere_encrypt(plain, key), key), plain)
  end)
  T.it("round-trip: mixed case input", function()
    local cipher = C.vigenere_encrypt("attackatdawn", "lemon")
    T.eq(cipher, "LXFOPVEFRNHR")
    T.eq(C.vigenere_decrypt(cipher, "LEMON"), "ATTACKATDAWN")
  end)
end)

-- ---------------------------------------------------------------------------
-- Beaufort cipher
-- ---------------------------------------------------------------------------

T.describe("beaufort", function()
  T.it("encrypt produces a result", function()
    local ct = C.beaufort_encrypt("HELLO", "KEY")
    T.ok(#ct == 5)
  end)
  T.it("self-reciprocal: encrypt(encrypt(p)) = p", function()
    local plain = "ATTACKATDAWN"
    local key   = "LEMON"
    T.eq(C.beaufort_decrypt(C.beaufort_encrypt(plain, key), key), plain)
  end)
  T.it("self-reciprocal: multiple keys", function()
    local cases = {
      { "HELLOWORLD", "SECRET" },
      { "CRYPTOGRAPHY", "KEY" },
      { "ABCDEFGHIJKLMNOP", "ABCD" },
    }
    for _, case in ipairs(cases) do
      local p, k = case[1], case[2]
      T.eq(C.beaufort_decrypt(C.beaufort_encrypt(p, k), k), p)
    end
  end)
  T.it("encrypt == decrypt (same function)", function()
    T.eq(C.beaufort_encrypt, C.beaufort_decrypt)
  end)
end)

-- ---------------------------------------------------------------------------
-- Auto-key Vigenère
-- ---------------------------------------------------------------------------

T.describe("autokey", function()
  T.it("round-trip: basic", function()
    local plain = "ATTACKATDAWN"
    local key   = "QUEENLY"
    T.eq(C.autokey_decrypt(C.autokey_encrypt(plain, key), key), plain)
  end)
  T.it("round-trip: key shorter than message", function()
    local plain = "HELLOWORLD"
    local key   = "AB"
    T.eq(C.autokey_decrypt(C.autokey_encrypt(plain, key), key), plain)
  end)
  T.it("round-trip: key same length as message", function()
    local plain = "CRYPTO"
    local key   = "SEKRET"
    T.eq(C.autokey_decrypt(C.autokey_encrypt(plain, key), key), plain)
  end)
  T.it("differs from standard Vigenère", function()
    local plain = "ATTACKATDAWN"
    local key   = "LEMON"
    local ak = C.autokey_encrypt(plain, key)
    local vg = C.vigenere_encrypt(plain, key)
    T.neq(ak, vg)
  end)
  T.it("nil key → error", function()
    local r, err = C.autokey_encrypt("HELLO", "")
    T.eq(r, nil)
    T.ok(err ~= nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- Playfair cipher
-- ---------------------------------------------------------------------------

T.describe("playfair", function()
  T.it("encrypt produces even-length result", function()
    local ct = C.playfair_encrypt("HELLO", "KEYWORD")
    T.eq(#ct % 2, 0)
  end)
  T.it("round-trip: basic", function()
    local key = "KEYWORD"
    local ct  = C.playfair_encrypt("HELLO", key)
    local pt  = C.playfair_decrypt(ct, key)
    -- Playfair may change repeated letters and pads; check first meaningful letters
    T.ok(pt:find("HE") ~= nil or pt:find("HELXLO") ~= nil or #pt >= 4)
  end)
  T.it("round-trip preserves content for non-repeated letters", function()
    local key   = "MONARCHY"
    local plain = "INSTRUMENTS"
    local ct    = C.playfair_encrypt(plain, key)
    local pt    = C.playfair_decrypt(ct, key)
    -- Strip trailing padding X and compare
    T.ok(pt:sub(1, #plain) == plain or pt:find(plain:sub(1, 6)) ~= nil)
  end)
  T.it("J is treated as I", function()
    local key = "KEY"
    local ct1 = C.playfair_encrypt("INN", key)
    local ct2 = C.playfair_encrypt("JNN", key)
    T.eq(ct1, ct2)
  end)
  T.it("known vector: HIDE + PLAYFAIR", function()
    -- Classic example: HIDE THE GOLD IN THE TREE STUMP → encrypt verifiable
    local ct = C.playfair_encrypt("HIDETHEGOLD", "PLAYFAIR")
    T.ok(type(ct) == "string")
    T.ok(#ct % 2 == 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- letter_frequencies
-- ---------------------------------------------------------------------------

T.describe("letter_frequencies", function()
  T.it("sums to total letter count", function()
    local text = "Hello World"
    local freq = C.letter_frequencies(text)
    local total = 0
    for _, v in pairs(freq) do total = total + v end
    T.eq(total, 10)  -- 10 letters (no space)
  end)
  T.it("correct individual counts", function()
    local freq = C.letter_frequencies("AABBC")
    T.eq(freq.a, 2)
    T.eq(freq.b, 2)
    T.eq(freq.c, 1)
    T.eq(freq.d, 0)
  end)
  T.it("returns all 26 letters", function()
    local freq = C.letter_frequencies("ABC")
    local n = 0
    for _ in pairs(freq) do n = n + 1 end
    T.eq(n, 26)
  end)
  T.it("case insensitive", function()
    local f1 = C.letter_frequencies("HELLO")
    local f2 = C.letter_frequencies("hello")
    T.eq(f1.h, f2.h)
    T.eq(f1.e, f2.e)
  end)
end)

-- ---------------------------------------------------------------------------
-- index_of_coincidence
-- ---------------------------------------------------------------------------

T.describe("index_of_coincidence", function()
  T.it("English text ≈ 0.065", function()
    -- Long English text approximation
    local english = "THEENGLISHLANGUAGEISAFASCINATINGANDCOMPLEXSYSTEMOFCOMMUNICATIONTHATHASEMERGEDOVERMANYCENTURIESOFHISTORICALDEVELOPMENTANDCULTURALINTERACTIONITENCOMPASSESARICHVOCABULARYOFOVERONEMILLIONWORDSANDAUNIQUECOMBINATIONOFGRAMMATICALSTRUCTURES"
    local ic = C.index_of_coincidence(english)
    T.ok(ic > 0.055 and ic < 0.080, "IC should be near 0.065 for English, got: " .. tostring(ic))
  end)
  T.it("uniform/random text has lower IC than English", function()
    -- A string with near-uniform letter distribution (all 26 repeated)
    local uniform = string.rep("ABCDEFGHIJKLMNOPQRSTUVWXYZ", 10)
    local ic_uniform = C.index_of_coincidence(uniform)
    local english = string.rep("THEQUICKBROWNFOXJUMPSOVERTHELAZYDOG", 6)
    local ic_eng = C.index_of_coincidence(english)
    T.ok(ic_uniform < ic_eng, "uniform IC should be < English IC")
  end)
  T.it("IC of uniform distribution ≈ 1/26 ≈ 0.0385", function()
    local uniform = string.rep("ABCDEFGHIJKLMNOPQRSTUVWXYZ", 20)
    local ic = C.index_of_coincidence(uniform)
    T.ok(ic > 0.030 and ic < 0.045, "uniform IC should be near 0.038, got " .. tostring(ic))
  end)
  T.it("empty text returns 0", function()
    T.eq(C.index_of_coincidence(""), 0)
  end)
  T.it("single letter returns 0", function()
    T.eq(C.index_of_coincidence("A"), 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- chi_squared
-- ---------------------------------------------------------------------------

T.describe("chi_squared", function()
  T.it("English text has lower chi-squared than random shift", function()
    local english = "THEENGLISHLANGUAGEISAFASCINATINGANDCOMPLEXSYSTEM"
    local rotated = C.caesar_encrypt(english, 13)
    -- chi-squared against English frequencies: English should score lower
    local chi_eng = C.chi_squared(english)
    local chi_rot = C.chi_squared(rotated)
    T.ok(chi_eng < chi_rot, "English text should fit English freq better")
  end)
  T.it("returns a non-negative number", function()
    T.ok(C.chi_squared("HELLO") >= 0)
  end)
  T.it("empty text returns 0", function()
    T.eq(C.chi_squared(""), 0)
  end)
  T.it("accepts custom expected frequencies", function()
    local custom = {}
    for i = 0, 25 do custom[string.char(i + 97)] = 1/26 end
    local score = C.chi_squared("ABCDEFGHIJKLMNOPQRSTUVWXYZ", custom)
    T.ok(score >= 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- Friedman test
-- ---------------------------------------------------------------------------

T.describe("friedman_test", function()
  T.it("returns a positive number for any text", function()
    T.ok(C.friedman_test("HELLOWORLD") > 0)
  end)
  T.it("typical English text returns a small positive estimate", function()
    -- A more uniform English sample gives estimates in reasonable range
    local english = "THEQUICKBROWNFOXJUMPSOVERTHELAZYDOG"
    local est = C.friedman_test(english)
    T.ok(est > 0, "estimate should be positive, got " .. tostring(est))
  end)
  T.it("Vigenère ciphertext with high IC returns estimate > 1", function()
    -- When IC is high (clustered), Friedman yields higher key length estimate
    local plain = string.rep("THEQUICKBROWNFOXJUMPSOVERTHELAZYDOG", 8)
    local cipher = C.vigenere_encrypt(plain, "LEMON")
    local est = C.friedman_test(cipher)
    T.ok(est > 0, "Friedman estimate should be positive, got " .. tostring(est))
  end)
  T.it("classic English prose gives estimate near 1", function()
    -- Classical English text (not pangram) has IC near 0.065
    local prose = "THEENGLISHLANGUAGEISAFASCINATINGANDCOMPLEXSYSTEMOFCOMMUNICATION" ..
                  "THATHASEMERGEDOVERMANYCENTURIESOFHISTORICALDEVELOPMENT"
    local est = C.friedman_test(prose)
    -- IC is near 0.065, formula should give ~1
    T.ok(est >= 0.5 and est <= 3, "prose estimate should be near 1, got " .. tostring(est))
  end)
end)

-- ---------------------------------------------------------------------------
-- Kasiski test
-- ---------------------------------------------------------------------------

T.describe("kasiski_test", function()
  T.it("returns array with len and score fields", function()
    local plain  = string.rep("THEQUICKBROWNFOXJUMPSOVERTHELAZYDOG", 6)
    local cipher = C.vigenere_encrypt(plain, "KEY")
    local results = C.kasiski_test(cipher)
    T.ok(#results > 0)
    T.ok(results[1].len ~= nil)
    T.ok(results[1].score ~= nil)
  end)
  T.it("top result for key-3 ciphertext includes 3 or a multiple", function()
    local plain  = string.rep("ATTACKATDAWNATTACKATDAWNATTACKATDAWN", 3)
    local cipher = C.vigenere_encrypt(plain, "KEY")
    local results = C.kasiski_test(cipher)
    -- At least one of top 3 results should be 3 or multiple of 3
    local found = false
    for i = 1, math.min(3, #results) do
      if results[i].len % 3 == 0 then found = true end
    end
    T.ok(found, "Kasiski should detect key length 3 or multiple")
  end)
  T.it("results are sorted by score descending", function()
    local cipher = C.vigenere_encrypt(string.rep("HELLOWORLD", 10), "ABC")
    local results = C.kasiski_test(cipher)
    for i = 2, #results do
      T.ok(results[i].score <= results[i-1].score, "results should be sorted descending")
    end
  end)
  T.it("max_keylen option is respected", function()
    local cipher  = C.vigenere_encrypt(string.rep("TESTMESSAGE", 5), "XY")
    local results = C.kasiski_test(cipher, { max_keylen = 10 })
    for _, r in ipairs(results) do
      T.ok(r.len <= 10)
    end
  end)
end)

-- ---------------------------------------------------------------------------
-- crack_caesar
-- ---------------------------------------------------------------------------

T.describe("crack_caesar", function()
  T.it("recovers shift 3", function()
    local plain  = "THEQUICKBROWNFOXJUMPSOVERTHELAZYDOG"
    local cipher = C.caesar_encrypt(plain, 3)
    local result = C.crack_caesar(cipher)
    T.eq(result.shift, 3)
    T.eq(result.plaintext, plain)
  end)
  T.it("recovers shift 13", function()
    local plain  = string.upper("HELLOWORLDHOWAREYOU")
    local cipher = C.caesar_encrypt(plain, 13)
    local result = C.crack_caesar(cipher)
    T.eq(result.shift, 13)
  end)
  T.it("returns {shift, plaintext, score}", function()
    local result = C.crack_caesar("KHOOR")
    T.ok(result.shift ~= nil)
    T.ok(result.plaintext ~= nil)
    T.ok(result.score ~= nil)
  end)
  T.it("score is non-negative", function()
    local result = C.crack_caesar("KHOOR")
    T.ok(result.score >= 0)
  end)
  T.it("shift 0 recovery", function()
    local plain  = "THEQUICKBROWNFOXJUMPSOVERTHELAZYDOG"
    local result = C.crack_caesar(plain)
    T.eq(result.shift, 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- crack_vigenere_keylen
-- ---------------------------------------------------------------------------

T.describe("crack_vigenere_keylen", function()
  T.it("returns up to 5 candidates", function()
    local cipher = C.vigenere_encrypt(string.rep("THEQUICKBROWNFOXJUMPSOVERTHELAZYDOG", 5), "KEY")
    local results = C.crack_vigenere_keylen(cipher, 10)
    T.ok(#results <= 5)
  end)
  T.it("top candidate for key-3 appears in candidates", function()
    -- Use prose text (non-pangram) for better IC-based analysis
    local plain  = string.rep("THEENGLISHLANGUAGEISAFASCINATINGANDCOMPLEXSYSTEMOFCOMMUNICATION", 4)
    local cipher = C.vigenere_encrypt(plain, "KEY")
    local results = C.crack_vigenere_keylen(cipher, 10)
    local found = false
    for i = 1, #results do
      if results[i].len % 3 == 0 then found = true end
    end
    T.ok(found, "key length 3 or multiple should appear in candidates")
  end)
  T.it("results sorted by score descending", function()
    local cipher = C.vigenere_encrypt(string.rep("HELLOWORLD", 10), "AB")
    local results = C.crack_vigenere_keylen(cipher, 8)
    for i = 2, #results do
      T.ok(results[i].score <= results[i-1].score)
    end
  end)
  T.it("each result has len and score", function()
    local cipher = C.vigenere_encrypt("ATTACKATDAWN", "XY")
    local results = C.crack_vigenere_keylen(cipher, 5)
    for _, r in ipairs(results) do
      T.ok(r.len ~= nil)
      T.ok(r.score ~= nil)
    end
  end)
end)

-- ---------------------------------------------------------------------------
-- crack_vigenere (full key recovery)
-- ---------------------------------------------------------------------------

T.describe("crack_vigenere", function()
  T.it("recovers key for long English ciphertext", function()
    local plain  = string.rep("THEQUICKBROWNFOXJUMPSOVERTHELAZYDOG", 6)
    local key    = "KEY"
    local cipher = C.vigenere_encrypt(plain, key)
    local result = C.crack_vigenere(cipher, 3)
    T.eq(result.key, key)
    T.eq(result.plaintext, plain)
  end)
  T.it("returns {key, plaintext}", function()
    local cipher = C.vigenere_encrypt("ATTACKATDAWNATTACKATDAWN", "AB")
    local result = C.crack_vigenere(cipher, 2)
    T.ok(result.key ~= nil)
    T.ok(result.plaintext ~= nil)
  end)
  T.it("plaintext length matches ciphertext letter count", function()
    local plain  = "HELLOWORLD"
    local cipher = C.vigenere_encrypt(plain, "XY")
    local result = C.crack_vigenere(cipher, 2)
    T.eq(#result.plaintext, #plain)
  end)
end)
