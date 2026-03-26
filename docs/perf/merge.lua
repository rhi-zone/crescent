-- docs/perf/merge.lua
-- Benchmark: lib/merge3 diff and three-way merge throughput.
-- Usage: luajit docs/perf/merge.lua [N]
--   N = number of iterations per measurement (default 200)

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local m   = require("lib.merge3")
local fmt = string.format

local N = tonumber(arg and arg[1]) or 200

-- ── helpers ───────────────────────────────────────────────────────────────────

local function gen_lines(n, prefix)
	local t = {}
	for i = 1, n do t[i] = (prefix or "") .. "line" .. i end
	return t
end

-- Build a string with `n` lines. Every `conflict_every` lines, the line differs
-- between base/ours/theirs (to create conflict density). `mod_every` controls
-- non-conflicting edits on one side.
local function gen_triplet(n, conflict_every, mod_every)
	local base_t, ours_t, theirs_t = {}, {}, {}
	conflict_every = conflict_every or 0
	mod_every = mod_every or 0
	for i = 1, n do
		local base_line = "line" .. i
		base_t[i] = base_line
		if conflict_every > 0 and i % conflict_every == 0 then
			ours_t[i]   = "OURS_" .. i
			theirs_t[i] = "THEIRS_" .. i
		elseif mod_every > 0 and i % mod_every == 0 then
			ours_t[i]   = "MOD_" .. i
			theirs_t[i] = base_line
		else
			ours_t[i]   = base_line
			theirs_t[i] = base_line
		end
	end
	local base   = table.concat(base_t,   "\n") .. "\n"
	local ours   = table.concat(ours_t,   "\n") .. "\n"
	local theirs = table.concat(theirs_t, "\n") .. "\n"
	return base, ours, theirs
end

local function bench(label, n_iters, fn)
	-- Warmup.
	for _ = 1, math.max(5, math.floor(n_iters / 20)) do fn() end

	-- 3 rounds; report best.
	local best_us = math.huge
	for _ = 1, 3 do
		collectgarbage("collect")
		collectgarbage("stop")
		local t0 = os.clock()
		for _ = 1, n_iters do fn() end
		local t1 = os.clock()
		collectgarbage("restart")
		local us = (t1 - t0) / n_iters * 1e6
		if us < best_us then best_us = us end
	end
	return best_us
end

-- ── section 1: diff throughput vs file size ───────────────────────────────────

print("=== diff throughput by file size ===")
print(fmt("%-40s  %6s  %9s  %10s  %10s",
	"scenario", "lines", "µs/call", "Klines/s", "KB/s"))
print(string.rep("-", 82))

for _, nlines in ipairs({100, 500, 1000, 5000}) do
	-- ~5% of lines changed (non-conflicting edit on b side).
	local a_lines = gen_lines(nlines)
	local b_lines = {}
	for i = 1, nlines do
		b_lines[i] = (i % 20 == 0) and ("CHANGED_" .. i) or a_lines[i]
	end
	local a_str = table.concat(a_lines, "\n") .. "\n"
	local b_str = table.concat(b_lines, "\n") .. "\n"
	local kb = #a_str / 1024

	local iters = math.max(10, math.floor(N * 1000 / nlines))
	local us = bench("diff " .. nlines, iters, function() m.diff(a_str, b_str) end)

	local klines_s = nlines / us * 1e3
	local kb_s     = kb     / us * 1e6
	print(fmt("diff %-35s  %6d  %9.1f  %10.1f  %10.1f",
		string.format("(%d lines, 5%% changed)", nlines),
		nlines, us, klines_s, kb_s))
end
print()

-- ── section 2: merge3 throughput vs conflict density ─────────────────────────

print("=== merge3 throughput by conflict density ===")
print(fmt("%-48s  %6s  %9s  %10s  %10s  %8s",
	"scenario", "lines", "µs/call", "Klines/s", "KB/s", "conflicts"))
print(string.rep("-", 98))

local densities = {
	{ lines = 1000, conflict_pct = 0,  mod_pct = 5,  label = "0% conflict, 5% ours-only edit" },
	{ lines = 1000, conflict_pct = 5,  mod_pct = 0,  label = "5% conflict" },
	{ lines = 1000, conflict_pct = 20, mod_pct = 0,  label = "20% conflict" },
	{ lines = 500,  conflict_pct = 10, mod_pct = 5,  label = "500 lines, 10% conflict, 5% mod" },
	{ lines = 5000, conflict_pct = 2,  mod_pct = 3,  label = "5000 lines, 2% conflict" },
}

for _, d in ipairs(densities) do
	local n = d.lines
	local ce = d.conflict_pct > 0 and math.floor(100 / d.conflict_pct) or 0
	local me = d.mod_pct     > 0 and math.floor(100 / d.mod_pct)     or 0
	local base, ours, theirs = gen_triplet(n, ce, me)
	local kb = #base / 1024

	-- Count conflicts.
	local _, nc = m.merge3(base, ours, theirs)

	local iters = math.max(5, math.floor(N * 1000 / n))
	local us = bench(d.label, iters, function() m.merge3(base, ours, theirs) end)

	local klines_s = n  / us * 1e3
	local kb_s     = kb / us * 1e6
	print(fmt("merge3 %-41s  %6d  %9.1f  %10.1f  %10.1f  %8d",
		d.label, n, us, klines_s, kb_s, nc))
end
print()

-- ── section 3: diff correctness spot-check ───────────────────────────────────

print("=== correctness spot-check ===")
local function reconstruct(script, a_lines)
	local out = {}
	for _, e in ipairs(script) do
		if e.op == "keep" or e.op == "insert" then
			for _, l in ipairs(e.lines) do out[#out + 1] = l end
		end
	end
	return table.concat(out, "\n") .. "\n"
end

local spot_ok = true
for _, nlines in ipairs({10, 100, 500}) do
	local a_lines = gen_lines(nlines, "A")
	local b_lines = {}
	for i = 1, nlines do
		if i % 7 == 0 then b_lines[i] = "B" .. i
		elseif i % 13 == 0 then b_lines[i] = nil  -- delete
		else b_lines[i] = a_lines[i]
		end
	end
	-- Remove nils (simulate deletions by skipping).
	local b_compact = {}
	for i = 1, nlines do
		if b_lines[i] then b_compact[#b_compact + 1] = b_lines[i] end
	end
	local a_str = table.concat(a_lines,   "\n") .. "\n"
	local b_str = table.concat(b_compact, "\n") .. "\n"
	local script = m.diff(a_str, b_str)
	local got = reconstruct(script, a_lines)
	if got ~= b_str then
		print(fmt("  FAIL: diff reconstruction wrong for %d-line file", nlines))
		spot_ok = false
	else
		print(fmt("  ok: diff(%d lines) reconstructs correctly", nlines))
	end
end

local rt_ok = true
local rt_cases = {
	{ "hello\nworld\n", "hello\nearth\n" },
	{ "a\nb\nc\n",       "x\ny\nz\n" },
	{ "",                "something\n" },
}
for _, pair in ipairs(rt_cases) do
	local base, theirs = pair[1], pair[2]
	local r, c = m.merge3(base, base, theirs)
	if r ~= theirs or c ~= 0 then
		print("  FAIL: round-trip merge3(base, base, theirs) != theirs")
		rt_ok = false
	end
	local r2, c2 = m.merge3(base, theirs, base)
	if r2 ~= theirs or c2 ~= 0 then
		print("  FAIL: round-trip merge3(base, theirs, base) != theirs")
		rt_ok = false
	end
end
if rt_ok then print("  ok: all round-trip invariants hold") end
print()

print("Done.")
