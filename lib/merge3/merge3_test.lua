if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local m = require("lib.merge3")

-- ── diff tests ────────────────────────────────────────────────────────────────

T.describe("merge3.diff", function()

	T.it("identical strings → single keep entry", function()
		local s = m.diff("a\nb\nc\n", "a\nb\nc\n")
		T.eq(#s, 1)
		T.eq(s[1].op, "keep")
		T.eq(#s[1].lines, 3)
	end)

	T.it("both empty → empty script", function()
		local s = m.diff("", "")
		T.eq(#s, 0)
	end)

	T.it("empty a → single insert", function()
		local s = m.diff("", "x\ny\n")
		T.eq(#s, 1)
		T.eq(s[1].op, "insert")
		T.eq(s[1].lines[1], "x")
		T.eq(s[1].lines[2], "y")
	end)

	T.it("empty b → single delete", function()
		local s = m.diff("x\ny\n", "")
		T.eq(#s, 1)
		T.eq(s[1].op, "delete")
		T.eq(#s[1].lines, 2)
	end)

	T.it("single insertion", function()
		-- "a\nb\n" → "a\nx\nb\n"
		local s = m.diff("a\nb\n", "a\nx\nb\n")
		-- Should be: keep a, insert x, keep b
		local keeps, inserts, deletes = 0, 0, 0
		for _, e in ipairs(s) do
			if e.op == "keep"   then keeps   = keeps   + #e.lines end
			if e.op == "insert" then inserts = inserts + #e.lines end
			if e.op == "delete" then deletes = deletes + #e.lines end
		end
		T.eq(keeps,   2)
		T.eq(inserts, 1)
		T.eq(deletes, 0)
	end)

	T.it("single deletion", function()
		-- "a\nb\nc\n" → "a\nc\n"
		local s = m.diff("a\nb\nc\n", "a\nc\n")
		local keeps, inserts, deletes = 0, 0, 0
		for _, e in ipairs(s) do
			if e.op == "keep"   then keeps   = keeps   + #e.lines end
			if e.op == "insert" then inserts = inserts + #e.lines end
			if e.op == "delete" then deletes = deletes + #e.lines end
		end
		T.eq(keeps,   2)
		T.eq(inserts, 0)
		T.eq(deletes, 1)
	end)

	T.it("single replacement", function()
		-- "a\nb\nc\n" → "a\nX\nc\n"
		local s = m.diff("a\nb\nc\n", "a\nX\nc\n")
		local keeps, inserts, deletes = 0, 0, 0
		for _, e in ipairs(s) do
			if e.op == "keep"   then keeps   = keeps   + #e.lines end
			if e.op == "insert" then inserts = inserts + #e.lines end
			if e.op == "delete" then deletes = deletes + #e.lines end
		end
		T.eq(keeps,   2)
		T.eq(inserts, 1)
		T.eq(deletes, 1)
	end)

	T.it("mixed changes preserve correct lines", function()
		-- Reconstruct b from the edit script and verify it equals the original b.
		local a_str = "one\ntwo\nthree\nfour\nfive\n"
		local b_str = "one\nTWO\nthree\nSIX\nfive\n"
		local script = m.diff(a_str, b_str)

		local a_lines = {}
		for l in (a_str .. "\n"):gmatch("([^\n]*)\n") do a_lines[#a_lines + 1] = l end
		-- Remove trailing empty from split.
		while #a_lines > 0 and a_lines[#a_lines] == "" do a_lines[#a_lines] = nil end

		-- Reconstruct b from the script.
		local reconstructed = {}
		local ai = 1
		for _, e in ipairs(script) do
			if e.op == "keep" then
				for _, l in ipairs(e.lines) do reconstructed[#reconstructed + 1] = l end
			elseif e.op == "insert" then
				for _, l in ipairs(e.lines) do reconstructed[#reconstructed + 1] = l end
			end
			-- delete: skip
		end
		local got = table.concat(reconstructed, "\n") .. "\n"
		T.eq(got, b_str)
	end)

	T.it("single-line inputs", function()
		local s = m.diff("hello\n", "world\n")
		local del, ins = 0, 0
		for _, e in ipairs(s) do
			if e.op == "delete" then del = del + 1 end
			if e.op == "insert" then ins = ins + 1 end
		end
		T.ok(del >= 1)
		T.ok(ins >= 1)
	end)

end)

-- ── merge3 tests ──────────────────────────────────────────────────────────────

T.describe("merge3.merge3", function()

	T.it("no changes → base returned", function()
		local r, c = m.merge3("a\nb\nc\n", "a\nb\nc\n", "a\nb\nc\n")
		T.eq(r, "a\nb\nc\n")
		T.eq(c, 0)
	end)

	T.it("only ours changed → ours returned", function()
		local r, c = m.merge3("a\nb\nc\n", "a\nX\nc\n", "a\nb\nc\n")
		T.eq(r, "a\nX\nc\n")
		T.eq(c, 0)
	end)

	T.it("only theirs changed → theirs returned", function()
		local r, c = m.merge3("a\nb\nc\n", "a\nb\nc\n", "a\nY\nc\n")
		T.eq(r, "a\nY\nc\n")
		T.eq(c, 0)
	end)

	T.it("both changed identically → taken once", function()
		local r, c = m.merge3("a\nb\nc\n", "a\nX\nc\n", "a\nX\nc\n")
		T.eq(r, "a\nX\nc\n")
		T.eq(c, 0)
	end)

	T.it("conflicting change → conflict markers, count=1", function()
		local r, c = m.merge3("a\nb\nc\n", "a\nX\nc\n", "a\nY\nc\n")
		T.eq(c, 1)
		T.ok(r:find("<<<<<<< ours", 1, true) ~= nil)
		T.ok(r:find(">>>>>>> theirs", 1, true) ~= nil)
		T.ok(r:find("||||||| base", 1, true) ~= nil)
		T.ok(r:find("=======", 1, true) ~= nil)
		T.ok(r:find("X", 1, true) ~= nil)
		T.ok(r:find("Y", 1, true) ~= nil)
	end)

	T.it("non-overlapping changes merged cleanly", function()
		local base   = "line1\nline2\nline3\nline4\nline5\n"
		local ours   = "OURS1\nline2\nline3\nline4\nline5\n"
		local theirs = "line1\nline2\nline3\nline4\nTHEIRS5\n"
		local r, c = m.merge3(base, ours, theirs)
		T.eq(c, 0)
		T.eq(r, "OURS1\nline2\nline3\nline4\nTHEIRS5\n")
	end)

	T.it("new lines added by both at same position → conflict", function()
		local base   = "a\nb\n"
		local ours   = "a\nINS_O\nb\n"
		local theirs = "a\nINS_T\nb\n"
		local r, c = m.merge3(base, ours, theirs)
		T.eq(c, 1)
		T.ok(r:find("INS_O", 1, true) ~= nil)
		T.ok(r:find("INS_T", 1, true) ~= nil)
	end)

	T.it("same insertion at same position → taken once", function()
		local base   = "a\nb\n"
		local ours   = "a\nSAME\nb\n"
		local theirs = "a\nSAME\nb\n"
		local r, c = m.merge3(base, ours, theirs)
		T.eq(c, 0)
		T.eq(r, "a\nSAME\nb\n")
	end)

	T.it("deletion on one side, edit on other → conflict", function()
		local base   = "a\nb\nc\n"
		local ours   = "a\nc\n"         -- deleted b
		local theirs = "a\nBMOD\nc\n"   -- edited b
		local r, c = m.merge3(base, ours, theirs)
		T.eq(c, 1)
	end)

	T.it("ours inserts at start, theirs at end → both taken", function()
		local r, c = m.merge3("b\n", "A\nb\n", "b\nZ\n")
		T.eq(c, 0)
		T.eq(r, "A\nb\nZ\n")
	end)

	T.it("multiple non-overlapping conflicts → correct count", function()
		local base   = "a\nb\nc\nd\ne\n"
		local ours   = "A\nb\nC\nd\ne\n"   -- changed a, c
		local theirs = "X\nb\nY\nd\ne\n"   -- changed a, c differently
		local r, c = m.merge3(base, ours, theirs)
		T.eq(c, 2)
	end)

	T.it("round-trip: merge3(base, base, theirs) == theirs always", function()
		local cases = {
			{ "hello\nworld\n",    "hello\nearth\n" },
			{ "a\nb\nc\n",         "x\ny\nz\n" },
			{ "only line\n",       "different\n" },
			{ "",                  "something\n" },
			{ "unchanged\n",       "unchanged\n" },
		}
		for _, pair in ipairs(cases) do
			local base, theirs = pair[1], pair[2]
			local r, c = m.merge3(base, base, theirs)
			T.eq(r, theirs)
			T.eq(c, 0)
		end
	end)

	T.it("round-trip: merge3(base, ours, base) == ours always", function()
		local cases = {
			{ "hello\nworld\n",    "hello\nearth\n" },
			{ "a\nb\nc\n",         "x\ny\nz\n" },
			{ "only line\n",       "different\n" },
			{ "",                  "something\n" },
			{ "unchanged\n",       "unchanged\n" },
		}
		for _, pair in ipairs(cases) do
			local base, ours = pair[1], pair[2]
			local r, c = m.merge3(base, ours, base)
			T.eq(r, ours)
			T.eq(c, 0)
		end
	end)

	T.it("empty base, both sides different → conflict", function()
		local r, c = m.merge3("", "ours\n", "theirs\n")
		T.eq(c, 1)
		T.ok(r:find("ours", 1, true) ~= nil)
		T.ok(r:find("theirs", 1, true) ~= nil)
	end)

	T.it("empty base, both sides same → taken once", function()
		local r, c = m.merge3("", "same\n", "same\n")
		T.eq(r, "same\n")
		T.eq(c, 0)
	end)

	T.it("ours deletes all, theirs unchanged → ours wins", function()
		local r, c = m.merge3("a\nb\nc\n", "", "a\nb\nc\n")
		T.eq(r, "")
		T.eq(c, 0)
	end)

	T.it("theirs deletes all, ours unchanged → theirs wins", function()
		local r, c = m.merge3("a\nb\nc\n", "a\nb\nc\n", "")
		T.eq(r, "")
		T.eq(c, 0)
	end)

	T.it("ten conflict regions → correct count", function()
		local base_lines, ours_lines, theirs_lines = {}, {}, {}
		for i = 1, 100 do
			base_lines[i]   = "base_" .. i
			-- Every 10th line is conflicted.
			if i % 10 == 0 then
				ours_lines[i]   = "ours_" .. i
				theirs_lines[i] = "theirs_" .. i
			else
				ours_lines[i]   = "base_" .. i
				theirs_lines[i] = "base_" .. i
			end
		end
		local base   = table.concat(base_lines,   "\n") .. "\n"
		local ours   = table.concat(ours_lines,   "\n") .. "\n"
		local theirs = table.concat(theirs_lines, "\n") .. "\n"
		local r, c = m.merge3(base, ours, theirs)
		T.eq(c, 10)
	end)

end)
