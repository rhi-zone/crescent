-- lib/test/fixture_test.lua
-- Tests for lib/test/fixture.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T       = require("lib.test.assert")
local fixture = require("lib.test.fixture")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local TMP = "/tmp/crescent_fixture_test_" .. tostring(os.time() % 100000)

local function mkdir(path)
	os.execute("mkdir -p " .. path)
end

local function rm_rf(path)
	if not path:find("^/tmp/") then
		error("rm_rf: refusing to remove non-tmp path: " .. path)
	end
	os.execute("rm -rf " .. path)
end

local function write(path, content)
	local f = io.open(path, "wb")
	assert(f, "cannot open " .. path)
	f:write(content)
	f:close()
end

local function read(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local s = f:read("*all")
	f:close()
	return s
end

mkdir(TMP)

-- ── fixture.diff ──────────────────────────────────────────────────────────────

T.describe("fixture.diff", function()
	T.it("identical strings produce empty diff", function()
		local d = fixture.diff("hello\nworld\n", "hello\nworld\n")
		T.eq(#d, 0)
	end)

	T.it("single line change shows - and +", function()
		local d = fixture.diff("hello\n", "goodbye\n")
		local joined = table.concat(d, "\n")
		T.ok(joined:find(" - hello"),   "expected deletion line")
		T.ok(joined:find("%+ goodbye"), "expected insertion line")
	end)

	T.it("added line shows +", function()
		local d = fixture.diff("a\n", "a\nb\n")
		local joined = table.concat(d, "\n")
		T.ok(joined:find("%+ b"), "expected addition of b")
	end)

	T.it("deleted line shows -", function()
		local d = fixture.diff("a\nb\n", "a\n")
		local joined = table.concat(d, "\n")
		T.ok(joined:find(" - b"), "expected deletion of b")
	end)

	T.it("context lines are shown around changes", function()
		local exp = "1\n2\n3\nX\n5\n6\n7\n"
		local act = "1\n2\n3\nY\n5\n6\n7\n"
		local d = fixture.diff(exp, act)
		local joined = table.concat(d, "\n")
		T.ok(joined:find("3"),   "context line 3 shown")
		T.ok(joined:find("5"),   "context line 5 shown")
		T.ok(joined:find(" - X"), "deletion of X")
		T.ok(joined:find("%+ Y"), "insertion of Y")
	end)

	T.it("empty inputs produce empty diff", function()
		T.eq(#fixture.diff("", ""), 0)
	end)

	T.it("empty expected vs non-empty actual shows additions", function()
		local d = fixture.diff("", "hello\n")
		local joined = table.concat(d, "\n")
		T.ok(joined:find("%+ hello"), "should show added line")
	end)

	T.it("non-empty expected vs empty actual shows deletions", function()
		local d = fixture.diff("hello\n", "")
		local joined = table.concat(d, "\n")
		T.ok(joined:find(" - hello"), "should show deleted line")
	end)
end)

-- ── fixture.normalize ─────────────────────────────────────────────────────────

T.describe("fixture.normalize", function()
	T.it("strip_ws removes trailing spaces", function()
		T.eq(fixture.normalize.strip_ws("hello   \nworld\n"), "hello\nworld")
	end)

	T.it("strip_ws removes trailing tabs", function()
		T.eq(fixture.normalize.strip_ws("a\t\t\nb\n"), "a\nb")
	end)

	T.it("strip_ws trims trailing newlines", function()
		T.eq(fixture.normalize.strip_ws("x\n\n\n"), "x")
	end)

	T.it("crlf converts \\r\\n to \\n", function()
		T.eq(fixture.normalize.crlf("a\r\nb\r\n"), "a\nb\n")
	end)

	T.it("crlf converts bare \\r to \\n", function()
		T.eq(fixture.normalize.crlf("a\rb"), "a\nb")
	end)

	T.it("sort_lines sorts alphabetically", function()
		T.eq(fixture.normalize.sort_lines("c\na\nb"), "a\nb\nc")
	end)

	T.it("compose applies normalizers left-to-right", function()
		local norm = fixture.normalize.compose({
			fixture.normalize.crlf,
			fixture.normalize.strip_ws,
		})
		T.eq(norm("hello   \r\nworld  \r\n"), "hello\nworld")
	end)
end)

-- ── fixture.check (single-fixture API) ───────────────────────────────────────

T.describe("fixture.check", function()
	local dir = TMP .. "/check"
	mkdir(dir)

	T.it("passes when actual matches expected", function()
		write(dir .. "/a.input",    "hello\n")
		write(dir .. "/a.expected", "HELLO\n")
		local ok, status, msg = fixture.check(
			dir .. "/a.input", dir .. "/a.expected",
			function(s) return s:upper() end, {})
		T.ok(ok, msg)
		T.eq(status, "pass")
	end)

	T.it("fails when actual differs from expected", function()
		write(dir .. "/b.input",    "hello\n")
		write(dir .. "/b.expected", "GOODBYE\n")
		local ok, status, msg = fixture.check(
			dir .. "/b.input", dir .. "/b.expected",
			function(s) return s:upper() end, {})
		T.ok(not ok)
		T.eq(status, "fail")
		T.ok(msg:find("mismatch"), "message should say mismatch")
		T.ok(msg:find("GOODBYE"),  "message should show expected")
		T.ok(msg:find("HELLO"),    "message should show actual")
	end)

	T.it("fails with hint when no expected file exists", function()
		write(dir .. "/c.input", "data\n")
		-- no c.expected
		local ok, status, msg = fixture.check(
			dir .. "/c.input", dir .. "/c.expected",
			function(s) return s end, {})
		T.ok(not ok)
		T.eq(status, "fail")
		T.ok(msg ~= nil)
	end)

	T.it("update mode creates expected file", function()
		write(dir .. "/d.input", "hello\n")
		-- no d.expected yet
		local ok, status, _msg = fixture.check(
			dir .. "/d.input", dir .. "/d.expected",
			function(s) return s:upper() end,
			{ update = true })
		T.ok(ok)
		T.eq(status, "created")
		T.eq(read(dir .. "/d.expected"), "HELLO\n")
	end)

	T.it("update mode overwrites existing expected file", function()
		write(dir .. "/e.input",    "hello\n")
		write(dir .. "/e.expected", "OLD\n")
		local ok, status, _msg = fixture.check(
			dir .. "/e.input", dir .. "/e.expected",
			function(s) return s:upper() end,
			{ update = true })
		T.ok(ok)
		T.eq(status, "updated")
		T.eq(read(dir .. "/e.expected"), "HELLO\n")
	end)

	T.it("normalizer applied to both sides before compare", function()
		write(dir .. "/f.input",    "hello   \n")
		write(dir .. "/f.expected", "hello")  -- no trailing space, no newline
		local ok, _status, msg = fixture.check(
			dir .. "/f.input", dir .. "/f.expected",
			function(s) return s end,
			{ normalize = fixture.normalize.strip_ws })
		T.ok(ok, msg)
	end)

	T.it("runner error becomes failure message", function()
		write(dir .. "/g.input",    "input\n")
		write(dir .. "/g.expected", "anything\n")
		local ok, status, msg = fixture.check(
			dir .. "/g.input", dir .. "/g.expected",
			function(_s) error("boom") end, {})
		T.ok(not ok)
		T.eq(status, "fail")
		T.ok(msg:find("boom"), "error message should contain 'boom'")
	end)
end)

-- ── fixture.run_dir ───────────────────────────────────────────────────────────

T.describe("fixture.run_dir: passing fixtures register as it() tests", function()
	local dir = TMP .. "/run_dir"
	mkdir(dir)

	write(dir .. "/alpha.input",    "hello\n")
	write(dir .. "/alpha.expected", "HELLO\n")
	write(dir .. "/beta.input",     "world\n")
	write(dir .. "/beta.expected",  "WORLD\n")

	-- run_dir registers tests with the global assert module.
	-- These become part of this file's test output.
	fixture.run_dir(dir, function(s) return s:upper() end)
	-- (alpha and beta will appear as passing it() tests in the suite)
end)

T.describe("fixture.run_dir: custom extensions", function()
	local dir = TMP .. "/run_dir_ext"
	mkdir(dir)
	write(dir .. "/case.src", "test\n")
	write(dir .. "/case.out", "TEST\n")

	fixture.run_dir(dir, function(s) return s:upper() end,
		{ input_ext = ".src", expected_ext = ".out" })
end)

-- ── fixture.group ─────────────────────────────────────────────────────────────

do
	local dir = TMP .. "/group"
	mkdir(dir)
	fixture.group("fixture.group: basic", dir, function(s) return s:upper() end, {})
	-- No files in dir — empty dir produces no test blocks (silently skipped).
end

T.describe("fixture.group: with fixtures", function()
	local dir = TMP .. "/group2"
	mkdir(dir)
	write(dir .. "/x.input",    "abc\n")
	write(dir .. "/x.expected", "ABC\n")

	-- group() wraps in describe; fixture tests get "fixture.group: with fixtures > x" name.
	fixture.group("grp", dir, function(s) return s:upper() end)
end)

-- ── Cleanup ───────────────────────────────────────────────────────────────────

rm_rf(TMP)
