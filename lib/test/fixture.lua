-- lib/test/fixture.lua
-- Snapshot / fixture testing for crescent.
--
-- Usage:
--   local fixture = require("lib.test.fixture")
--
--   -- Discover *.input / *.expected pairs in a directory.
--   fixture.run_dir("lib/mylib/testdata", function(input)
--       return transform(input)
--   end)
--
--   -- With options:
--   fixture.run_dir("testdata", runner, {
--       update    = false,           -- or set UPDATE_SNAPSHOTS=1 env var
--       normalize = fixture.normalize.strip_ws,
--       input_ext    = ".in",        -- default ".input"
--       expected_ext = ".out",       -- default ".expected"
--       recursive    = false,        -- default: top-level only
--   })
--
--   -- Named group (wraps in a describe block):
--   fixture.group("parser roundtrip", "testdata/parser", runner)
--
-- Update mode: UPDATE_SNAPSHOTS=1 env var or opts.update = true.
-- On first run when no .expected file exists, the test fails with a hint
-- to run with UPDATE_SNAPSHOTS=1 to create the snapshot.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- ── File I/O ──────────────────────────────────────────────────────────────────

local function read_file(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local content = f:read("*all")
	f:close()
	return content
end

local function write_file(path, content)
	local f, err = io.open(path, "wb")
	if not f then error("fixture: cannot write " .. path .. ": " .. tostring(err)) end
	f:write(content)
	f:close()
end

-- ── Binary detection ──────────────────────────────────────────────────────────

-- Returns true if the string looks like binary (has non-printable, non-whitespace bytes).
local function is_binary(s)
	for i = 1, math.min(#s, 8192) do
		local b = s:byte(i)
		if b < 9 or (b >= 14 and b <= 31) or b == 127 then
			return true
		end
	end
	return false
end

-- ── Hex dump ──────────────────────────────────────────────────────────────────

local function hex_dump(s, max_bytes)
	max_bytes = max_bytes or 256
	local out = {}
	for i = 1, math.min(#s, max_bytes), 16 do
		local hex, asc = {}, {}
		for j = i, math.min(i + 15, #s) do
			local b = s:byte(j)
			hex[#hex + 1] = string.format("%02x", b)
			asc[#asc + 1] = (b >= 32 and b < 127) and string.char(b) or "."
		end
		out[#out + 1] = string.format("%08x  %-48s  %s",
			i - 1, table.concat(hex, " "), table.concat(asc))
	end
	if #s > max_bytes then
		out[#out + 1] = string.format("... (%d bytes total)", #s)
	end
	return table.concat(out, "\n")
end

-- ── Line splitting ────────────────────────────────────────────────────────────

local function split_lines(s)
	local lines = {}
	local i = 1
	while i <= #s do
		local j = s:find("\n", i, true)
		if j then
			lines[#lines + 1] = s:sub(i, j - 1)
			i = j + 1
		else
			lines[#lines + 1] = s:sub(i)
			break
		end
	end
	return lines
end

-- ── Unified diff ──────────────────────────────────────────────────────────────

-- LCS table (O(n*m) — only used when n+m <= MAX_DIFF_LINES).
local MAX_DIFF_LINES = 600
local CONTEXT = 3

-- Returns a list of display lines representing a unified-style diff.
function M.diff(expected, actual)
	local exp_lines = split_lines(expected)
	local act_lines = split_lines(actual)
	local ne, na = #exp_lines, #act_lines

	if ne == 0 and na == 0 then return {} end

	if ne + na > MAX_DIFF_LINES then
		return { string.format("(diff omitted: expected %d lines, got %d lines)", ne, na) }
	end

	-- Build LCS table.
	local lcs = {}
	for i = 0, ne do
		lcs[i] = {}
		for j = 0, na do lcs[i][j] = 0 end
	end
	for i = 1, ne do
		for j = 1, na do
			if exp_lines[i] == act_lines[j] then
				lcs[i][j] = lcs[i - 1][j - 1] + 1
			else
				lcs[i][j] = math.max(lcs[i - 1][j], lcs[i][j - 1])
			end
		end
	end

	-- Backtrack to build edit list.
	local edits = {}
	local i, j = ne, na
	while i > 0 or j > 0 do
		if i > 0 and j > 0 and exp_lines[i] == act_lines[j] then
			table.insert(edits, 1, { op = "eq", line = exp_lines[i] })
			i, j = i - 1, j - 1
		elseif j > 0 and (i == 0 or lcs[i][j - 1] >= lcs[i - 1][j]) then
			table.insert(edits, 1, { op = "ins", line = act_lines[j] })
			j = j - 1
		else
			table.insert(edits, 1, { op = "del", line = exp_lines[i] })
			i = i - 1
		end
	end

	-- Mark which positions to show (changed lines + CONTEXT around them).
	local n = #edits
	local show = {}
	for k = 1, n do
		if edits[k].op ~= "eq" then
			for c = math.max(1, k - CONTEXT), math.min(n, k + CONTEXT) do
				show[c] = true
			end
		end
	end

	-- Render with "..." separators between hunks.
	local out = {}
	local prev_shown = false
	for k = 1, n do
		if show[k] then
			if not prev_shown and k > 1 then
				out[#out + 1] = "  ..."
			end
			local e = edits[k]
			if     e.op == "eq"  then out[#out + 1] = "   " .. e.line
			elseif e.op == "del" then out[#out + 1] = " - " .. e.line
			else                      out[#out + 1] = " + " .. e.line
			end
			prev_shown = true
		else
			prev_shown = false
		end
	end
	return out
end

-- ── Normalizers ───────────────────────────────────────────────────────────────

M.normalize = {}

-- Strip trailing whitespace from every line and trailing whitespace at end.
M.normalize.strip_ws = function(s)
	s = s:gsub("[ \t]+\n", "\n")  -- trailing spaces/tabs before newline
	s = s:gsub("[ \t\n]+$", "")   -- trailing whitespace at end of string
	return s
end

-- Normalize line endings to LF.
M.normalize.crlf = function(s)
	return (s:gsub("\r\n", "\n"):gsub("\r", "\n"))
end

-- Sort lines alphabetically.
M.normalize.sort_lines = function(s)
	local lines = split_lines(s)
	table.sort(lines)
	return table.concat(lines, "\n")
end

-- Compose multiple normalizers left-to-right.
M.normalize.compose = function(fns)
	return function(s)
		for _, fn in ipairs(fns) do s = fn(s) end
		return s
	end
end

-- ── Single-fixture runner ─────────────────────────────────────────────────────

-- Run a single fixture.
-- Returns: ok (bool), status ("pass"|"updated"|"created"|"fail"), message
--
-- Public so callers can test or drive individual fixtures without it() integration.
function M.check(input_path, expected_path, runner, opts)
	local update = opts.update or (os.getenv("UPDATE_SNAPSHOTS") == "1")
	local normalize = opts.normalize

	local input = read_file(input_path)
	if not input then
		return false, "fail", "cannot read input file: " .. input_path
	end

	local ok, actual = pcall(runner, input)
	if not ok then
		return false, "fail", "runner raised error:\n  " .. tostring(actual)
	end

	if type(actual) ~= "string" then
		return false, "fail", "runner must return a string, got " .. type(actual)
	end

	if normalize then
		actual = normalize(actual)
	end

	local expected = read_file(expected_path)

	if update then
		write_file(expected_path, actual)
		local status = (expected == nil) and "created" or "updated"
		return true, status, nil
	end

	if expected == nil then
		return false, "fail",
			"no expected file: " .. expected_path
				.. "\n  run with UPDATE_SNAPSHOTS=1 to create it"
	end

	if normalize then
		expected = normalize(expected)
	end

	if actual == expected then
		return true, "pass", nil
	end

	-- Build failure message with diff.
	local lines = { "snapshot mismatch: " .. input_path }

	if is_binary(actual) or is_binary(expected) then
		lines[#lines + 1] = "expected (" .. #expected .. " bytes):"
		lines[#lines + 1] = hex_dump(expected, 128)
		lines[#lines + 1] = "actual (" .. #actual .. " bytes):"
		lines[#lines + 1] = hex_dump(actual, 128)
	else
		local diff = M.diff(expected, actual)
		if #diff > 0 then
			for _, dl in ipairs(diff) do lines[#lines + 1] = dl end
		else
			-- Should not happen (we checked actual ~= expected), but be safe.
			lines[#lines + 1] = "(outputs differ but diff is empty — check normalizers)"
		end
	end

	return false, "fail", table.concat(lines, "\n")
end

-- ── fixture.run_dir ───────────────────────────────────────────────────────────

-- Discover all *.input files in dir and run them as fixtures.
-- Each is registered as a named assert.it() block.
--
-- opts:
--   update       bool     -- overwrite .expected files with actual output
--   normalize    function -- normalize(str) -> str, applied to both sides
--   input_ext    string   -- default ".input"
--   expected_ext string   -- default ".expected"
--   recursive    bool     -- search subdirectories (default false)
function M.run_dir(dir, runner, opts)
	opts = opts or {}
	local input_ext    = opts.input_ext    or ".input"
	local expected_ext = opts.expected_ext or ".expected"
	local assert_mod   = require("lib.test.assert")
	local maxdepth     = opts.recursive and "" or " -maxdepth 1"

	local cmd = "find " .. dir .. maxdepth
		.. " -name '*" .. input_ext .. "' -type f | sort"
	local h = io.popen(cmd)
	if not h then
		assert_mod.it(dir .. ": (popen failed)", function()
			error("fixture.run_dir: could not list directory: " .. dir)
		end)
		return
	end

	local inputs = {}
	for line in h:lines() do inputs[#inputs + 1] = line end
	h:close()

	if #inputs == 0 then
		return  -- empty dir is not an error; just nothing to run
	end

	for _, input_path in ipairs(inputs) do
		local base          = input_path:sub(1, #input_path - #input_ext)
		local expected_path = base .. expected_ext
		local name          = base:match("[^/]+$") or base

		assert_mod.it(name, function()
			local ok, _status, msg = M.check(input_path, expected_path, runner, opts)
			if not ok then
				error(msg, 2)
			end
		end)
	end
end

-- ── fixture.group ─────────────────────────────────────────────────────────────

-- Like run_dir but wraps everything in a describe block.
function M.group(group_name, dir, runner, opts)
	local assert_mod = require("lib.test.assert")
	assert_mod.describe(group_name, function()
		M.run_dir(dir, runner, opts)
	end)
end

return M
