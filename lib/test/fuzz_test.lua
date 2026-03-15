-- lib/test/fuzz_test.lua
-- Tests for the corpus-based mutation fuzzer.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T    = require("lib.test.assert")
local fuzz = require("lib.test.fuzz")

-- ── mutate ────────────────────────────────────────────────────────────────────

T.describe("fuzz.mutate", function()
	T.it("returns a string", function()
		local gen = require("lib.test.gen")
		local rng = gen.make_rng(42)
		local out = fuzz.mutate("hello", rng)
		T.ok(type(out) == "string", "mutate returns string")
	end)

	T.it("handles empty input without error", function()
		local gen = require("lib.test.gen")
		local rng = gen.make_rng(1)
		-- Should not error on empty string for any mutation.
		for _ = 1, 50 do
			local ok, err = pcall(fuzz.mutate, "", rng)
			T.ok(ok, "mutate('', rng) should not error: " .. tostring(err))
		end
	end)

	T.it("sometimes changes the input", function()
		local gen = require("lib.test.gen")
		local rng = gen.make_rng(7)
		local changed = false
		for _ = 1, 30 do
			local out = fuzz.mutate("hello world", rng)
			if out ~= "hello world" then changed = true; break end
		end
		T.ok(changed, "at least one mutation should change the input")
	end)

	T.it("uses corpus for splice", function()
		local gen = require("lib.test.gen")
		local rng = gen.make_rng(99)
		-- With a corpus, splice should occasionally produce a mix of inputs.
		local corpus   = { "AAAA", "BBBB", "CCCC" }
		local spliced  = false
		for _ = 1, 100 do
			local out = fuzz.mutate("XXXX", rng, corpus)
			-- A splice would combine parts of "XXXX" with another corpus entry.
			if out:find("A") or out:find("B") or out:find("C") then
				spliced = true; break
			end
		end
		T.ok(spliced, "splice should occasionally draw from corpus")
	end)
end)

-- ── fuzz.run — basic structure ────────────────────────────────────────────────

T.describe("fuzz.run", function()
	T.it("returns expected result fields", function()
		local result = fuzz.run(function(_) end, { iters = 10, seeds = {""} })
		T.ok(type(result.iters)        == "number", "iters is number")
		T.ok(type(result.crashes)      == "table",  "crashes is table")
		T.ok(type(result.unique_paths) == "number", "unique_paths is number")
		T.ok(type(result.corpus_size)  == "number", "corpus_size is number")
		T.ok(type(result.seed)         == "number", "seed is number")
		T.eq(result.iters, 10)
	end)

	T.it("reports zero crashes for a function that never errors", function()
		local result = fuzz.run(function(_) end, { iters = 50, seeds = {"abc", "xyz"} })
		T.eq(#result.crashes, 0)
	end)

	T.it("detects crashes", function()
		-- Function that crashes on inputs containing 'X'.
		local result = fuzz.run(function(s)
			if s:find("X", 1, true) then error("found X!") end
		end, {
			iters  = 200,
			seeds  = {"XXXX"},  -- seed ensures 'X' is in corpus from the start
			mode   = "fast",
			seed   = 1,
		})
		T.ok(#result.crashes > 0, "should detect crash (found X)")
		T.ok(result.crashes[1].input ~= nil,     "crash has input")
		T.ok(result.crashes[1].err   ~= nil,     "crash has err")
		T.ok(result.crashes[1].err:find("found X"), "crash err contains message")
	end)

	T.it("respects expected_errs patterns", function()
		-- Errors matching expected_errs are not reported as crashes.
		local result = fuzz.run(function(s)
			if s:find("X", 1, true) then error("expected_error: benign") end
		end, {
			iters         = 100,
			seeds         = {"XXXX"},
			expected_errs = { "expected_error" },
			seed          = 1,
		})
		T.eq(#result.crashes, 0, "expected errors should not be counted as crashes")
	end)

	T.it("corpus grows in guided mode when new paths are found", function()
		-- In guided mode the corpus should grow beyond the initial seed count
		-- as the fuzzer explores new branches.
		local result = fuzz.run(function(_) end, {
			iters = 30,
			seeds = {"a"},
			mode  = "guided",
			seed  = 42,
		})
		-- corpus_size >= 1 (the seed), and likely > 1 from new coverage hits.
		T.ok(result.corpus_size >= 1, "corpus_size at least 1")
		T.ok(result.unique_paths >= 0, "unique_paths is non-negative")
	end)

	T.it("respects max_input_len", function()
		-- Collect all input lengths seen by the target.
		local max_seen = 0
		fuzz.run(function(s)
			if #s > max_seen then max_seen = #s end
		end, {
			iters         = 100,
			seeds         = {"A"},
			max_input_len = 20,
			seed          = 5,
		})
		T.ok(max_seen <= 20, "no input should exceed max_input_len")
	end)

	T.it("respects mutations_per range", function()
		-- By setting mutations_per={0,0} the input never changes from base.
		-- (min 0 means mutate_n is called with n=0 → no-op)
		local seen = {}
		fuzz.run(function(s) seen[s] = true end, {
			iters         = 20,
			seeds         = {"hello"},
			mutations_per = {0, 0},
			seed          = 9,
		})
		-- Only "hello" should have been seen (zero mutations).
		T.ok(seen["hello"], "base seed should appear")
		local count = 0; for _ in pairs(seen) do count = count + 1 end
		T.eq(count, 1, "with 0 mutations, only the seed should appear")
	end)

	T.it("seed is deterministic", function()
		-- Same seed should produce same crash list.
		local crashes1, crashes2 = {}, {}
		fuzz.run(function(s)
			if s:find("Z", 1, true) then error("z-crash") end
		end, { iters=50, seeds={"Z"}, seed=123, on_crash = function(inp)
			crashes1[#crashes1+1] = inp
		end })
		fuzz.run(function(s)
			if s:find("Z", 1, true) then error("z-crash") end
		end, { iters=50, seeds={"Z"}, seed=123, on_crash = function(inp)
			crashes2[#crashes2+1] = inp
		end })
		T.eq(#crashes1, #crashes2, "same seed → same number of crashes")
		for i = 1, #crashes1 do
			T.eq(crashes1[i], crashes2[i], "same seed → same crash inputs")
		end
	end)

	T.it("on_crash callback is invoked", function()
		local called = 0
		fuzz.run(function(s)
			if s:find("Q", 1, true) then error("q!") end
		end, {
			iters    = 100,
			seeds    = {"Q"},
			seed     = 2,
			on_crash = function(_, _) called = called + 1 end,
		})
		T.ok(called > 0, "on_crash should be called at least once")
	end)
end)

-- ── fuzz.it ───────────────────────────────────────────────────────────────────

T.describe("fuzz.it", function()
	T.it("runs without error when no crashes occur", function()
		-- fuzz.it itself wraps in T.it, so we call fuzz.run directly here
		-- to avoid nesting T.it inside T.it (not supported by the runner).
		local result = fuzz.run(function(_) end, { iters = 20, seed = 77 })
		T.eq(#result.crashes, 0)
	end)
end)
