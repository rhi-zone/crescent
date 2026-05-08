if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

-- lib/merge3/init.lua — pure Lua three-way merge library
--
-- Standalone, vendorable. No dependencies outside LuaJIT stdlib.
--
-- API:
--   merge3.diff(a_str, b_str)              → edit_script
--   merge3.merge3(base, ours, theirs)      → merged_string, conflict_count
--
-- diff() implements Myers O(ND) greedy algorithm with trace-based backtracking.
-- merge3() walks both edit scripts simultaneously aligned on base positions.
--
-- Conflict markers (diff3 -m style):
--   <<<<<<< ours
--   ...ours lines...
--   ||||||| base
--   ...base lines...
--   =======
--   ...theirs lines...
--   >>>>>>> theirs

local M = {}

-- ── line splitting ────────────────────────────────────────────────────────────

-- Split a string into lines (without \n). "" → {}.
--: (string) -> { [integer]: string }
local function split_lines(s)
	if s == "" then return {} end
	local lines = {} --: { [integer]: string }
	local pos, len = 1, #s
	while pos <= len do
		local nl = s:find("\n", pos, true)
		if nl then
			lines[#lines + 1] = s:sub(pos, nl - 1)
			pos = nl + 1
		else
			lines[#lines + 1] = s:sub(pos)
			pos = len + 1
		end
	end
	return lines
end

-- ── Myers diff ────────────────────────────────────────────────────────────────

-- Standard Myers O(ND) diff with trace-based backtracking.
-- Returns an edit script: array of {op="keep"|"delete"|"insert", lines={...}}
-- Adjacent same-op entries are merged into one record.
function M.diff(a_str, b_str)
	local a = split_lines(a_str)
	local b = split_lines(b_str)
	local n, m = #a, #b

	if n == 0 and m == 0 then return {} end
	if n == 0 then return {{ op = "insert", lines = b }} end
	if m == 0 then return {{ op = "delete", lines = a }} end

	-- v[k] = furthest x on diagonal k = x - y.
	-- We index v with an offset so k can be negative: v[k + off].
	local off = m + 1

	-- Keep a snapshot of v after each d step for backtracking.
	-- trace[d + 1] = table mapping (k + off) → x at that step.
	local trace = {} --: { [integer]: { [integer]: number } }

	local v = {} --: { [integer]: number }
	-- Bootstrap: diagonal 0, extend from (0,0).
	do
		local x = 0
		while x < n and x < m and a[x + 1] == b[x + 1] do x = x + 1 end
		v[0 + off] = x
		if x >= n and x >= m then
			-- All keeps.
			trace[1] = { [0 + off] = x }
			local script = {}
			if n > 0 then script[1] = { op = "keep", lines = a } end
			return script
		end
		-- Sentinel for k=1 (used when k = -d+1 references k+1 = k+1).
		v[1 + off] = 0
		trace[1] = { [0 + off] = x, [1 + off] = 0 }
	end

	local final_d = -1

	for d = 1, n + m do
		local sv = {} --: { [integer]: number }
		for k = -d, d, 2 do
			local x
			local vkm1 = v[k - 1 + off] or 0 --: number
			local vkp1 = v[k + 1 + off] or 0 --: number
			if k == -d or (k ~= d and vkm1 < vkp1) then
				x = vkp1   -- move down
			else
				x = vkm1 + 1  -- move right (delete)
			end
			local y = x - k
			while x < n and y < m and a[x + 1] == b[y + 1] do
				x = x + 1; y = y + 1
			end
			v[k + off] = x
			sv[k + off] = x
			if x >= n and y >= m then
				trace[d + 1] = sv
				final_d = d
				goto done
			end
		end
		trace[d + 1] = sv
	end
	::done::

	if final_d < 0 then
		return {{ op = "delete", lines = a }, { op = "insert", lines = b }}
	end

	-- Backtrack through the trace to reconstruct the edit.
	-- We collect (kind, ...) steps in reverse order, then reverse.
	local steps = {} --: { [integer]: any }
	local x, y = n, m

	for d = final_d, 1, -1 do
		local prev = trace[d]
		local k = x - y

		-- Determine move direction at step d for diagonal k.
		local prev_vkm1 = (prev and prev[k - 1 + off] or 0) --: number
		local prev_vkp1 = (prev and prev[k + 1 + off] or 0) --: number

		local came_down
		if k == -d or (k ~= d and prev_vkm1 < prev_vkp1) then
			came_down = true   -- moved down from k+1 (insert from b)
		else
			came_down = false  -- moved right from k-1 (delete from a)
		end

		local px, py  -- position before the snake at this step
		if came_down then
			px = prev_vkp1
			py = px - (k + 1)
			-- After move down: y increases by 1, x stays.
			-- Snake: (px, py+1) → (x, y).
			if x > px or y > py + 1 then
				steps[#steps + 1] = { kind = "snake", x0 = px, y0 = py + 1, x1 = x, y1 = y }
			end
			steps[#steps + 1] = { kind = "insert", bi = py + 1 }
			x = px
			y = py
		else
			px = prev_vkm1
			py = px - (k - 1)
			-- After move right: x increases by 1, y stays.
			-- Snake: (px+1, py) → (x, y).
			if x > px + 1 or y > py then
				steps[#steps + 1] = { kind = "snake", x0 = px + 1, y0 = py, x1 = x, y1 = y }
			end
			steps[#steps + 1] = { kind = "delete", ai = px + 1 }
			x = px
			y = py
		end
	end

	-- Leading snake from (0,0) to (x,y).
	if x > 0 or y > 0 then
		steps[#steps + 1] = { kind = "snake", x0 = 0, y0 = 0, x1 = x, y1 = y }
	end

	-- Reverse steps.
	local lo, hi = 1, #steps
	while lo < hi do steps[lo], steps[hi] = steps[hi], steps[lo]; lo = lo + 1; hi = hi - 1 end

	-- Build edit script.
	--:: ScriptEntry = { op: string, lines: { [integer]: string } }
	local script = {} --: { [integer]: ScriptEntry }
	local function push(op, line)
		local last = script[#script] --[[:! ScriptEntry | nil]]
		if last and last.op == op then
			last.lines[#last.lines + 1] = line
		else
			script[#script + 1] = { op = op, lines = { line } }
		end
	end

	for _, st in ipairs(steps) do
		if st.kind == "snake" then
			for i = st.x0 + 1, st.x1 do push("keep", a[i]) end
		elseif st.kind == "delete" then
			push("delete", a[st.ai])
		else
			push("insert", b[st.bi])
		end
	end

	return script
end

-- ── three-way merge ───────────────────────────────────────────────────────────

-- Convert an edit script to a list of hunks.
-- Each hunk: {kind="keep"|"change", base_lines={...}, other_lines={...}}
-- "keep": base_lines == other_lines (unchanged lines from base).
-- "change": base_lines = deleted a-lines; other_lines = inserted b-lines.
--   Pure inserts have empty base_lines; pure deletes have empty other_lines.
--:: Hunk = { kind: string, base_lines: { [integer]: string }, other_lines: { [integer]: string } }
local function to_hunks(script)
	local hunks = {} --: { [integer]: Hunk }
	local i = 1
	while i <= #script do
		local e = script[i] --[[:! ScriptEntry]]
		if e.op == "keep" then
			hunks[#hunks + 1] = { kind = "keep", base_lines = e.lines, other_lines = e.lines }
			i = i + 1
		else
			local del = {} --: { [integer]: string }
			local ins = {} --: { [integer]: string }
			while i <= #script and (script[i] --[[:! ScriptEntry]]).op ~= "keep" do
				local se = script[i] --[[:! ScriptEntry]]
				if se.op == "delete" then
					for _, l in ipairs(se.lines) do del[#del + 1] = l end
				else
					for _, l in ipairs(se.lines) do ins[#ins + 1] = l end
				end
				i = i + 1
			end
			hunks[#hunks + 1] = { kind = "change", base_lines = del, other_lines = ins }
		end
	end
	return hunks
end

--: ({ [integer]: string }, { [integer]: string }) -> boolean
local function lines_eq(a, b)
	if #a ~= #b then return false end
	for i = 1, #a do if a[i] ~= b[i] then return false end end
	return true
end

-- Three-way merge. Returns: merged_string, conflict_count.
function M.merge3(base_str, ours_str, theirs_str)
	if ours_str == theirs_str then return ours_str, 0 end
	if base_str == ours_str   then return theirs_str, 0 end
	if base_str == theirs_str then return ours_str, 0 end

	local ho = to_hunks(M.diff(base_str, ours_str))
	local ht = to_hunks(M.diff(base_str, theirs_str))

	local out = {}
	local conflicts = 0

	-- We maintain two "cursors": (oi, oh_off) for ours and (ti, th_off) for theirs.
	-- oh_off = number of lines already consumed from the front of ho[oi].
	-- This avoids mutating the hunk tables.
	local oi, oi_off = 1, 0
	local ti, ti_off = 1, 0

	-- Get the current hunk for each side (adjusted for offset).
	-- Returns nil when exhausted.
	--: () -> Hunk | nil
	local function cur_o()
		if oi > #ho then return nil end
		local h = ho[oi] --[[:! Hunk]]
		local off_ = oi_off --: number
		if off_ == 0 then return h end
		-- Return a virtual trimmed hunk.
		local bl = {} --: { [integer]: string }
		local ol = {} --: { [integer]: string }
		for j = off_ + 1, #h.base_lines  do bl[#bl + 1] = h.base_lines[j] end
		for j = off_ + 1, #h.other_lines do ol[#ol + 1] = h.other_lines[j] end
		return { kind = h.kind, base_lines = bl, other_lines = ol }
	end

	--: () -> Hunk | nil
	local function cur_t()
		if ti > #ht then return nil end
		local h = ht[ti] --[[:! Hunk]]
		local off_ = ti_off --: number
		if off_ == 0 then return h end
		local bl = {} --: { [integer]: string }
		local ol = {} --: { [integer]: string }
		for j = off_ + 1, #h.base_lines  do bl[#bl + 1] = h.base_lines[j] end
		for j = off_ + 1, #h.other_lines do ol[#ol + 1] = h.other_lines[j] end
		return { kind = h.kind, base_lines = bl, other_lines = ol }
	end

	-- Advance ours cursor by `n` base lines (keep hunks only).
	-- Must only be called when we know the next n base lines of ours are "keep".
	local function adv_o_base(n)
		while n > 0 do
			local h = ho[oi]
			if not h then break end
			local have = #h.base_lines - oi_off
			if n >= have then
				n = n - have
				oi = oi + 1
				oi_off = 0
			else
				oi_off = oi_off + n
				n = 0
			end
		end
	end

	local function adv_t_base(n)
		while n > 0 do
			local h = ht[ti]
			if not h then break end
			local have = #h.base_lines - ti_off
			if n >= have then
				n = n - have
				ti = ti + 1
				ti_off = 0
			else
				ti_off = ti_off + n
				n = 0
			end
		end
	end

	-- Advance ours by one full hunk.
	local function adv_o()
		oi = oi + 1
		oi_off = 0
	end

	local function adv_t()
		ti = ti + 1
		ti_off = 0
	end

	--: ({ [integer]: string }) -> nil
	local function emit(lines)
		for _, l in ipairs(lines) do out[#out + 1] = l end
	end

	--: ({ [integer]: string }, { [integer]: string }, { [integer]: string }) -> nil
	local function conflict(ol, bl, tl)
		conflicts = conflicts + 1
		out[#out + 1] = "<<<<<<< ours"
		for _, l in ipairs(ol) do out[#out + 1] = l end
		out[#out + 1] = "||||||| base"
		for _, l in ipairs(bl) do out[#out + 1] = l end
		out[#out + 1] = "======="
		for _, l in ipairs(tl) do out[#out + 1] = l end
		out[#out + 1] = ">>>>>>> theirs"
	end

	-- Slice first `n` elements of a table into a new table.
	local function first(t, n)
		local r = {}
		for j = 1, n do r[j] = t[j] end
		return r
	end

	while true do
		local oh = cur_o()
		local th = cur_t()
		if not oh and not th then break end

		-- Pure inserts (zero base lines consumed).
		local oi_pure = oh and oh.kind == "change" and #oh.base_lines == 0
		local ti_pure = th and th.kind == "change" and #th.base_lines == 0

		if oi_pure and ti_pure then
			local oh_ = oh --[[:! Hunk]]
			local th_ = th --[[:! Hunk]]
			if lines_eq(oh_.other_lines, th_.other_lines) then
				emit(oh_.other_lines)
			else
				conflict(oh_.other_lines, {}, th_.other_lines)
			end
			adv_o(); adv_t()
		elseif oi_pure then
			emit((oh --[[:! Hunk]]).other_lines); adv_o()
		elseif ti_pure then
			emit((th --[[:! Hunk]]).other_lines); adv_t()
		elseif not oh then
			emit((th --[[:! Hunk]]).other_lines); adv_t()
		elseif not th then
			emit((oh --[[:! Hunk]]).other_lines); adv_o()
		elseif oh.kind == "keep" and th.kind == "keep" then
			-- Both keeping. Take the shorter span, then advance both.
			local on, tn = #oh.base_lines, #th.base_lines
			local take = math.min(on, tn)
			for j = 1, take do out[#out + 1] = oh.base_lines[j] end
			-- Advance both by take base lines.
			adv_o_base(take)
			adv_t_base(take)
		elseif oh.kind == "change" and th.kind == "keep" then
			-- Ours changed, theirs kept: take ours change, advance theirs by cn base lines.
			local cn = #oh.base_lines
			emit(oh.other_lines); adv_o()
			adv_t_base(cn)
		elseif oh.kind == "keep" and th.kind == "change" then
			-- Theirs changed, ours kept: take theirs change, advance ours by cn base lines.
			local cn = #th.base_lines
			emit(th.other_lines); adv_t()
			adv_o_base(cn)
		else
			-- Both changed.
			local on, tn = #oh.base_lines, #th.base_lines

			if lines_eq(oh.other_lines, th.other_lines) and on == tn then
				-- Identical change to identical base region.
				emit(oh.other_lines); adv_o(); adv_t()
			else
				-- Conflict: use the shorter base region as the conflict base.
				local take = math.min(on, tn)
				local bl = first(oh.base_lines, take)
				conflict(oh.other_lines, bl, th.other_lines)

				if on <= tn then
					adv_o()
					adv_t_base(on)
				else
					adv_t()
					adv_o_base(tn)
				end
			end
		end
	end

	if #out == 0 then return "", conflicts end
	return table.concat(out, "\n") .. "\n", conflicts
end

return M
