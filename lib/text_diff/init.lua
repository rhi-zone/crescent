if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- Character-level text diff inspired by diff-match-patch.
-- Diffs are arrays of {op, text} where op = "equal"|"insert"|"delete".

-- ---------------------------------------------------------------------------
-- Internal: Myers O(ND) diff on character arrays.
-- Returns list of {op,text} operations merged into runs.
-- ---------------------------------------------------------------------------

local function chars_to_array(s)
  local t = {}
  for i = 1, #s do t[i] = s:sub(i, i) end
  return t
end

-- Myers forward pass; returns (v_final, d_final, offset) or (nil, errmsg)
--: ({ [integer]: string }, { [integer]: string }) -> ({ [integer]: { [integer]: integer } } | nil, integer | nil, integer | nil)
local function myers_forward(a, b)
  local n = #a
  local m = #b
  local max_d = n + m
  local offset = max_d + 2
  local v = {} --: { [integer]: integer }
  v[offset] = 0
  local trace = {} --: { [integer]: { [integer]: integer } }

  if max_d == 0 then
    trace[1] = { [offset] = 0 }
    return trace, 0, offset
  end

  for d = 0, max_d do
    for k = -d, d, 2 do
      local x0 = 0 --: integer
      if k == -d or (k ~= d and v[offset + k - 1] < v[offset + k + 1]) then
        x0 = v[offset + k + 1]
      else
        x0 = v[offset + k - 1] + 1
      end
      local x = x0 --[[:! integer]]
      local y = x - k --: integer
      while x < n and y < m and a[x + 1] == b[y + 1] do
        x = x + 1
        y = y + 1
      end
      v[offset + k] = x
      if x >= n and y >= m then
        local snap = {} --: { [integer]: integer }
        for j = -d, d, 2 do snap[offset + j] = v[offset + j] end
        trace[d + 1] = snap
        return trace, d, offset
      end
    end
    local snap = {} --: { [integer]: integer }
    for j = -d, d, 2 do snap[offset + j] = v[offset + j] end
    trace[d + 1] = snap
  end

  return nil, "diff: no solution found"
end

--: ({ [integer]: string }, { [integer]: string }, { [integer]: { [integer]: integer } }, integer, integer) -> { [integer]: { [integer]: unknown } }
local function myers_backtrack(a, b, trace, d_final, offset)
  local n = #a
  local m = #b
  local x = n --: integer
  local y = m --: integer
  local stack = {} --: { [integer]: { [integer]: unknown } }
  local ns = 0

  for d = d_final, 0, -1 do
    local k = x - y --: integer
    local prev_snap = d > 0 and trace[d] or nil --: { [integer]: integer } | nil

    local function prev_v(ki)
      if not prev_snap then return 0 end
      return prev_snap[offset + ki]
    end

    local prev_k0 = 0 --: integer
    if k == -d or (k ~= d and prev_v(k - 1) < prev_v(k + 1)) then
      prev_k0 = k + 1
    else
      prev_k0 = k - 1
    end
    local prev_k = prev_k0 --[[:! integer]]

    local prev_x = 0 --: integer
    if d > 0 and prev_snap then
      prev_x = prev_snap[offset + prev_k]
    end
    local prev_x_ = prev_x --[[:! integer]]
    local prev_y = prev_x_ - prev_k --: integer

    local diag_start_x = 0 --: integer
    local diag_start_y = 0 --: integer
    if d > 0 then
      if prev_k > k then
        diag_start_x = prev_x_
        diag_start_y = prev_y + 1
      else
        diag_start_x = prev_x_ + 1
        diag_start_y = prev_y
      end
    end

    local dsx = diag_start_x --[[:! integer]]
    local dsy = diag_start_y --[[:! integer]]
    if x > dsx then
      ns = ns + 1
      stack[ns] = { "equal", dsx + 1, x, dsy + 1, y }
      x = dsx
      y = dsy
    end

    if d > 0 then
      if prev_k > k then
        ns = ns + 1
        stack[ns] = { "insert", x + 1, x, y, y }
        y = y - 1
      else
        ns = ns + 1
        stack[ns] = { "delete", x, x, y + 1, y }
        x = x - 1
      end
    end
  end

  -- Reverse and convert to {op,text}
  local result = {} --: { [integer]: { [integer]: string } }
  local nr = 0
  for i = ns, 1, -1 do
    local e = stack[i]
    local op = e[1] --[[:! string]]
    local e2 = e[2] --[[:! integer]]
    local e3 = e[3] --[[:! integer]]
    local e4 = e[4] --[[:! integer]]
    local e5 = e[5] --[[:! integer]]
    local text = "" --: string
    if op == "equal" then
      -- a[e2..e3]
      local parts = {}
      for j = e2, e3 do parts[j - e2 + 1] = a[j] end
      text = table.concat(parts)
    elseif op == "delete" then
      local parts = {}
      for j = e2, e3 do parts[j - e2 + 1] = a[j] end
      text = table.concat(parts)
    else -- insert
      local parts = {}
      for j = e4, e5 do parts[j - e4 + 1] = b[j] end
      text = table.concat(parts)
    end
    -- Merge with previous if same op
    if nr > 0 and result[nr][1] == op then
      result[nr][2] = result[nr][2] .. text
    else
      nr = nr + 1
      result[nr] = { op, text }
    end
  end
  return result
end

-- ---------------------------------------------------------------------------
-- Common prefix / suffix optimization
-- ---------------------------------------------------------------------------

local function common_prefix_len(s1, s2)
  local n = math.min(#s1, #s2)
  for i = 1, n do
    if s1:sub(i, i) ~= s2:sub(i, i) then return i - 1 end
  end
  return n
end

local function common_suffix_len(s1, s2)
  local n1, n2 = #s1, #s2
  local n = math.min(n1, n2)
  for i = 0, n - 1 do
    if s1:sub(n1 - i, n1 - i) ~= s2:sub(n2 - i, n2 - i) then return i end
  end
  return n
end

-- ---------------------------------------------------------------------------
-- Public: diff
-- ---------------------------------------------------------------------------

-- Compute character-level diff between text1 and text2.
-- Returns array of {op, text} where op = "equal"|"insert"|"delete".
-- opts: {timeout (seconds, default nil = no timeout), check_lines (ignored)}
M.diff = function(text1, text2, _opts)
  if text1 == text2 then
    if text1 == "" then return {} end
    return { { "equal", text1 } }
  end
  if text1 == "" then return { { "insert", text2 } } end
  if text2 == "" then return { { "delete", text1 } } end

  -- Common prefix
  local prefix_len = common_prefix_len(text1, text2)
  local prefix = text1:sub(1, prefix_len)
  local s1 = text1:sub(prefix_len + 1)
  local s2 = text2:sub(prefix_len + 1)

  -- Common suffix
  local suffix_len = common_suffix_len(s1, s2)
  local suffix = s1:sub(#s1 - suffix_len + 1)
  s1 = s1:sub(1, #s1 - suffix_len)
  s2 = s2:sub(1, #s2 - suffix_len)

  local diffs = {}
  local nd = 0

  if prefix_len > 0 then
    nd = nd + 1
    diffs[nd] = { "equal", prefix }
  end

  if s1 == "" and s2 == "" then
    -- nothing to diff
  elseif s1 == "" then
    nd = nd + 1
    diffs[nd] = { "insert", s2 }
  elseif s2 == "" then
    nd = nd + 1
    diffs[nd] = { "delete", s1 }
  else
    local a = chars_to_array(s1)
    local b = chars_to_array(s2)
    local fwd_trace, fwd_d, fwd_offset = myers_forward(a, b)
    if fwd_trace then
      local trace_ = fwd_trace --[[:! { [integer]: { [integer]: integer } }]]
      local d_final_ = (fwd_d or 0) --[[:! integer]]
      local offset_ = (fwd_offset or 0) --[[:! integer]]
      local inner = myers_backtrack(a, b, trace_, d_final_, offset_)
      for _, op in ipairs(inner) do
        nd = nd + 1
        diffs[nd] = op
      end
    else
      -- fallback: single delete + insert
      nd = nd + 1
      diffs[nd] = { "delete", s1 }
      nd = nd + 1
      diffs[nd] = { "insert", s2 }
    end
  end

  if suffix_len > 0 then
    nd = nd + 1
    diffs[nd] = { "equal", suffix }
  end

  return diffs
end

-- ---------------------------------------------------------------------------
-- Public: apply / patch
-- ---------------------------------------------------------------------------

-- Reconstruct destination text by applying diffs to source.
M.apply = function(source, diffs)
  local parts = {}
  local np = 0
  local pos = 1
  for _, d in ipairs(diffs) do
    local op, text = d[1], d[2]
    if op == "equal" then
      np = np + 1
      parts[np] = text
      pos = pos + #text
    elseif op == "delete" then
      pos = pos + #text
    elseif op == "insert" then
      np = np + 1
      parts[np] = text
    end
  end
  _ = source -- source is consumed implicitly via pos tracking; kept for API clarity
  return table.concat(parts)
end

M.patch = M.apply

-- ---------------------------------------------------------------------------
-- Public: cleanup_semantic
-- ---------------------------------------------------------------------------

-- Returns true if c is a word boundary character (whitespace or punctuation).
local function is_boundary(c)
  return c == " " or c == "\t" or c == "\n" or c == "\r"
    or c == "." or c == "," or c == "!" or c == "?" or c == ";"
    or c == ":" or c == "(" or c == ")" or c == "[" or c == "]"
end

-- Shift edit boundaries to align with word/sentence boundaries.
-- Returns a new diffs array (does not mutate input).
--: ({ [integer]: { [integer]: string } }) -> { [integer]: { [integer]: string } }
M.cleanup_semantic = function(diffs)
  -- Deep copy
  local d = {} --: { [integer]: { [integer]: string } }
  for i, v in ipairs(diffs) do
    local v1 = v[1] --[[:! string]]
    local v2 = v[2] --[[:! string]]
    d[i] = { v1, v2 }
  end

  -- Repeatedly shift non-equal runs right to word boundaries.
  -- For each edit group between two equals, we can shift by moving the
  -- prefix of the following equal onto the end of all edits in the group
  -- and the same prefix off the front of the following equal, provided
  -- the edit texts also start with those same chars.
  local changed = true
  while changed do
    changed = false
    local i = 1
    while i <= #d do
      if d[i][1] ~= "equal" then
        -- collect run of non-equal ops
        local run_s = i
        while i <= #d and d[i][1] ~= "equal" do i = i + 1 end
        local run_e = i - 1

        -- Try shifting right: move chars from start of following equal
        -- to end of each edit in the run (rotation: edit shifts right).
        if i <= #d and d[i][1] == "equal" then
          local eq = d[i][2]
          -- Find max shift: all edit texts must start with eq[1..shift]
          -- after the rotation they become text[shift+1..] + text[1..shift]
          -- which means text[1..shift] == eq[1..shift].
          -- We want to shift until we're at a word boundary.
          local max_ok = 0
          for k = 1, #eq do
            -- Check all edits: their text starts with eq[1..k] after cycling
            -- This means: for each edit text T, T's last k chars == eq[1..k].
            local ok = true
            for j = run_s, run_e do
              local t = d[j][2]
              if #t < k or t:sub(#t - k + 1) ~= eq:sub(1, k) then
                ok = false; break
              end
            end
            if ok then max_ok = k end
          end
          -- Find rightmost word boundary within 0..max_ok
          local best = 0
          for k = 1, max_ok do
            local c = eq:sub(k, k)
            if is_boundary(c) then best = k end
          end
          if best > 0 then
            -- Apply shift of `best` to all edits in run
            for j = run_s, run_e do
              local t = d[j][2]
              -- rotate right by `best`: new_text = t[#t-best+1..] .. t[1..#t-best]
              d[j][2] = t:sub(#t - best + 1) .. t:sub(1, #t - best)
            end
            -- Shift equal: move best chars from front to back
            d[i][2] = eq:sub(best + 1) .. eq:sub(1, best)
            changed = true
          end
        end
      else
        i = i + 1
      end
    end
  end

  -- Merge adjacent ops of same type and remove empties
  local result = {} --: { [integer]: { [integer]: string } }
  local nr = 0
  for _, v in ipairs(d) do
    if v[2] ~= "" then
      if nr > 0 and result[nr][1] == v[1] then
        result[nr][2] = result[nr][2] .. v[2]
      else
        nr = nr + 1
        result[nr] = { v[1], v[2] }
      end
    end
  end
  return result
end

-- ---------------------------------------------------------------------------
-- Public: cleanup_efficiency
-- ---------------------------------------------------------------------------

-- Merge tiny edit islands that cost more edits than they save.
-- edit_cost: number of edit operations to open a new edit region (default 4).
--: ({ [integer]: { [integer]: string } }, (number | nil)) -> { [integer]: { [integer]: string } }
M.cleanup_efficiency = function(diffs, edit_cost)
  edit_cost = edit_cost or 4
  local d = {} --: { [integer]: { [integer]: string } }
  for i, v in ipairs(diffs) do
    local v1 = v[1] --[[:! string]]
    local v2 = v[2] --[[:! string]]
    d[i] = { v1, v2 }
  end

  local changed = true
  while changed do
    changed = false
    local i = 2
    while i <= #d - 1 do
      -- Look for: non-equal, small-equal, non-equal pattern
      if d[i][1] == "equal" and #d[i][2] < edit_cost then
        local prev = d[i - 1]
        local next = d[i + 1]
        if prev and next and prev[1] ~= "equal" and next[1] ~= "equal" then
          -- Absorb the small equal into surrounding edits
          local eq_text = d[i][2]
          -- Append eq to prev ops, prepend to next ops (for same op type)
          if prev[1] == "delete" or prev[1] == "insert" then
            prev[2] = prev[2] .. eq_text
          end
          if next[1] == "delete" or next[1] == "insert" then
            next[2] = eq_text .. next[2]
          end
          -- Remove the equal
          table.remove(d, i)
          -- Merge adjacent same-op
          if i <= #d and d[i - 1][1] == d[i][1] then
            d[i - 1][2] = d[i - 1][2] .. d[i][2]
            table.remove(d, i)
          end
          changed = true
        else
          i = i + 1
        end
      else
        i = i + 1
      end
    end
  end

  -- Remove empty
  local result = {}
  local nr = 0
  for _, v in ipairs(d) do
    if v[2] ~= "" then
      nr = nr + 1
      result[nr] = v
    end
  end
  return result
end

-- ---------------------------------------------------------------------------
-- Public: to_html
-- ---------------------------------------------------------------------------

local function html_escape(s)
  return s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
end

-- Render diffs as HTML. Equal text in <span>, inserts in <ins>, deletes in <del>.
-- opts: {ins_class, del_class, eq_class} — extra CSS classes (optional).
M.to_html = function(diffs, opts)
  opts = opts or {}
  local parts = {}
  local np = 0
  for _, d in ipairs(diffs) do
    local op, text = d[1], d[2]
    local escaped = html_escape(text):gsub("\n", "&para;<br>")
    if op == "equal" then
      np = np + 1
      parts[np] = "<span>" .. escaped .. "</span>"
    elseif op == "insert" then
      np = np + 1
      parts[np] = "<ins>" .. escaped .. "</ins>"
    elseif op == "delete" then
      np = np + 1
      parts[np] = "<del>" .. escaped .. "</del>"
    end
    _ = opts
  end
  return table.concat(parts)
end

-- ---------------------------------------------------------------------------
-- Public: to_unified
-- ---------------------------------------------------------------------------

-- Produce a unified-diff-style string from character-level diffs.
-- from/to: file name labels. opts: {context=3}
M.to_unified = function(diffs, from, to, opts)
  opts = opts or {}
  local ctx_ = opts.context
  local ctx = (ctx_ ~= nil and ctx_ or 3) --[[:! integer]]
  from = from or "a"
  to = to or "b"

  -- Build line-level view from character diffs
  -- Split each diff text by newline, emit +/- lines
  local lines = {} --: { [integer]: { [integer]: string } }
  local nl = 0

  for _, d in ipairs(diffs) do
    local op, text = d[1], d[2]
    -- Split text on newlines, keeping the newline
    local start = 1
    while start <= #text do
      local nl_pos = text:find("\n", start, true)
      local chunk
      if nl_pos then
        chunk = text:sub(start, nl_pos)
        start = nl_pos + 1
      else
        chunk = text:sub(start)
        start = #text + 1
      end
      if chunk ~= "" then
        nl = nl + 1
        lines[nl] = { op, chunk }
      end
    end
  end

  if nl == 0 then return "" end

  -- Identify changed indices
  local changed_idx = {} --: { [integer]: integer }
  local nc = 0
  for i = 1, nl do
    if lines[i][1] ~= "equal" then
      nc = nc + 1
      changed_idx[nc] = i
    end
  end

  if nc == 0 then return "" end

  -- Group into hunks
  local hunks = {} --: { [integer]: { [integer]: integer } }
  local nh = 0
  local hs = math.max(1, changed_idx[1] - ctx) --[[:! integer]]
  local he = math.min(nl, changed_idx[1] + ctx) --[[:! integer]]
  for ci = 2, nc do
    local idx = changed_idx[ci]
    local new_start = math.max(1, idx - ctx) --[[:! integer]]
    if new_start <= he + 1 then
      he = math.min(nl, idx + ctx) --[[:! integer]]
    else
      nh = nh + 1
      hunks[nh] = { hs, he }
      hs = new_start
      he = math.min(nl, idx + ctx) --[[:! integer]]
    end
  end
  nh = nh + 1
  hunks[nh] = { hs, he }

  local out = {}
  local no = 0
  no = no + 1; out[no] = "--- " .. from .. "\n"
  no = no + 1; out[no] = "+++ " .. to .. "\n"

  for hi = 1, nh do
    local hstart = hunks[hi][1] --[[:! integer]]
    local hend = hunks[hi][2] --[[:! integer]]
    -- Count a/b lines
    local a_n, b_n = 0, 0
    local a_line, b_line = 1, 1  -- logical line counters (just use position)
    for i = 1, hstart - 1 do
      if lines[i][1] == "equal" then a_line = a_line + 1; b_line = b_line + 1
      elseif lines[i][1] == "delete" then a_line = a_line + 1
      elseif lines[i][1] == "insert" then b_line = b_line + 1
      end
    end
    for i = hstart, hend do
      local lop = lines[i][1]
      if lop == "equal" then a_n = a_n + 1; b_n = b_n + 1
      elseif lop == "delete" then a_n = a_n + 1
      elseif lop == "insert" then b_n = b_n + 1
      end
    end

    no = no + 1
    out[no] = "@@ -" .. a_line .. "," .. a_n .. " +" .. b_line .. "," .. b_n .. " @@\n"

    for i = hstart, hend do
      local lop, text = lines[i][1], lines[i][2]
      if lop == "equal" then
        no = no + 1; out[no] = " " .. text
        if text:sub(-1) ~= "\n" then no = no + 1; out[no] = "\n" end
      elseif lop == "delete" then
        no = no + 1; out[no] = "-" .. text
        if text:sub(-1) ~= "\n" then no = no + 1; out[no] = "\n" end
      elseif lop == "insert" then
        no = no + 1; out[no] = "+" .. text
        if text:sub(-1) ~= "\n" then no = no + 1; out[no] = "\n" end
      end
    end
  end

  return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- Public: to_patch / from_patch  (simple serialization)
-- ---------------------------------------------------------------------------

-- Serialize diffs to a line-based patch text.
-- Format: one op-line per diff entry:
--   =<base64-len> <text>
--   +<base64-len> <text>
--   -<base64-len> <text>
-- Text is percent-encoded (newlines as %0A, % as %25).
local function pct_encode(s)
  return s:gsub("%%", "%%25"):gsub("\n", "%%0A"):gsub("\r", "%%0D")
end

local function pct_decode(s)
  return s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
end

M.to_patch = function(_source, diffs)
  local lines = {}
  local nl = 0
  for _, d in ipairs(diffs) do
    local op, text = d[1], d[2]
    local prefix
    if op == "equal" then prefix = "="
    elseif op == "insert" then prefix = "+"
    else prefix = "-"
    end
    nl = nl + 1
    lines[nl] = prefix .. pct_encode(text)
  end
  return table.concat(lines, "\n")
end

M.from_patch = function(patch_text)
  local diffs = {}
  local nd = 0
  for line in (patch_text .. "\n"):gmatch("([^\n]*)\n") do
    if line ~= "" then
      local prefix = line:sub(1, 1)
      local text = pct_decode(line:sub(2))
      local op
      if prefix == "=" then op = "equal"
      elseif prefix == "+" then op = "insert"
      elseif prefix == "-" then op = "delete"
      end
      if op then
        nd = nd + 1
        diffs[nd] = { op, text }
      end
    end
  end
  return diffs
end

-- ---------------------------------------------------------------------------
-- Public: stats
-- ---------------------------------------------------------------------------

M.stats = function(diffs)
  local equal, inserted, deleted = 0, 0, 0
  for _, d in ipairs(diffs) do
    local op, text = d[1], d[2]
    local n = #text
    if op == "equal" then equal = equal + n
    elseif op == "insert" then inserted = inserted + n
    elseif op == "delete" then deleted = deleted + n
    end
  end
  local total = equal + inserted + deleted
  local similarity
  if total == 0 then
    similarity = 1.0
  else
    -- similarity = 2 * equal / (2 * equal + inserted + deleted)
    similarity = (2 * equal) / (2 * equal + inserted + deleted)
  end
  return {
    equal = equal,
    inserted = inserted,
    deleted = deleted,
    changes = inserted + deleted,
    similarity = similarity,
  }
end

-- ---------------------------------------------------------------------------
-- Public: levenshtein
-- ---------------------------------------------------------------------------

-- Compute Levenshtein edit distance from a diff (insertions + deletions are 1 each char).
M.levenshtein = function(diffs)
  local dist = 0 --: number
  local ins_buf, del_buf = 0, 0
  for _, d in ipairs(diffs) do
    local op, text = d[1], d[2]
    local n = #text
    if op == "insert" then
      ins_buf = ins_buf + n
    elseif op == "delete" then
      del_buf = del_buf + n
    else
      dist = dist + math.max(ins_buf, del_buf)
      ins_buf = 0
      del_buf = 0
    end
  end
  dist = dist + math.max(ins_buf, del_buf)
  return dist
end

-- ---------------------------------------------------------------------------
-- Public: fuzzy_find
-- ---------------------------------------------------------------------------

-- Find best position of pattern in text using bitap algorithm.
-- Returns (pos, score) where pos is 1-indexed, score is 0..1 (1=exact).
-- opts: {threshold=0.5}
--: (string, string, { threshold: number | nil } | nil) -> (integer | nil, number)
M.fuzzy_find = function(text, pattern, opts)
  local opts_ = opts or {} --[[:! { threshold: number | nil }]]
  local threshold = opts_.threshold or 0.5
  if pattern == "" then return 1, 1.0 end
  if text == "" then return nil, 0.0 end

  local pat_len = #pattern
  local text_len = #text

  -- Exact match first
  local exact = text:find(pattern, 1, true)
  if exact then return exact, 1.0 end

  -- Simple approach: sliding window with normalized edit distance
  local best_pos = nil
  local best_score = 0.0 --: number

  for i = 1, text_len - pat_len + 1 do
    local window = text:sub(i, i + pat_len - 1)
    -- Compute edit distance between window and pattern
    -- Simple DP
    local prev = {} --: { [integer]: integer }
    for j = 0, pat_len do prev[j] = j end
    for ci = 1, pat_len do
      local curr = { [0] = ci } --: { [integer]: integer }
      local c = window:sub(ci, ci)
      for j = 1, pat_len do
        local cost = c == pattern:sub(j, j) and 0 or 1
        curr[j] = math.min(curr[j-1] + 1, prev[j] + 1, prev[j-1] + cost) --[[:! integer]]
      end
      prev = curr
    end
    local dist = prev[pat_len] --[[:! integer]]
    local score = 1.0 - dist / pat_len
    if score > best_score and score >= threshold then
      best_score = score
      best_pos = i
    end
  end

  if best_pos then
    return best_pos, best_score
  end
  return nil, 0.0
end

-- ---------------------------------------------------------------------------
-- Public: word_diff
-- ---------------------------------------------------------------------------

-- Split text into words (sequences of non-whitespace + whitespace runs).
--: (string) -> { [integer]: string }
local function split_words(s)
  local words = {}
  local nw = 0
  local pos = 1
  local len = #s
  while pos <= len do
    -- Word token: non-whitespace
    local ws_end = s:find("%S", pos)
    if ws_end and ws_end > pos then
      -- whitespace run
      nw = nw + 1
      words[nw] = s:sub(pos, ws_end - 1)
      pos = ws_end
    elseif not ws_end then
      -- trailing whitespace
      nw = nw + 1
      words[nw] = s:sub(pos)
      break
    end
    -- non-whitespace run
    local word_end = s:find("%s", pos)
    if word_end then
      nw = nw + 1
      words[nw] = s:sub(pos, word_end - 1)
      pos = word_end
    else
      nw = nw + 1
      words[nw] = s:sub(pos)
      break
    end
  end
  return words
end

-- Word-level diff. Same {op,text} format but operations span whole words.
M.word_diff = function(text1, text2)
  local words1 = split_words(text1)
  local words2 = split_words(text2)

  if #words1 == 0 and #words2 == 0 then return {} end
  if #words1 == 0 then return { { "insert", text2 } } end
  if #words2 == 0 then return { { "delete", text1 } } end

  -- Use lib/diff for array diff on words
  local diff_lib = require("lib.diff")
  local edits = diff_lib.diff(words1, words2)
  if not edits then return { { "delete", text1 }, { "insert", text2 } } end

  local edits_any = edits --[[: any]]
  local edits_ = edits_any --[[:! { [integer]: { op: string, a_start: integer, a_end: integer, b_start: integer, b_end: integer } }]]
  local result = {} --: { [integer]: { [integer]: string } }
  local nr = 0
  for _, e in ipairs(edits_) do
    local op_name
    if e.op == "eq" then op_name = "equal"
    elseif e.op == "del" then op_name = "delete"
    elseif e.op == "ins" then op_name = "insert"
    end

    local text
    if e.op == "eq" or e.op == "del" then
      local parts = {} --: { [integer]: string }
      for i = e.a_start, e.a_end do parts[i - e.a_start + 1] = words1[i] end
      text = table.concat(parts)
    else
      local parts = {} --: { [integer]: string }
      for i = e.b_start, e.b_end do parts[i - e.b_start + 1] = words2[i] end
      text = table.concat(parts)
    end

    -- Merge adjacent same op
    if nr > 0 and result[nr][1] == op_name then
      local prev_text = result[nr][2] --[[:! string]]
      result[nr][2] = prev_text .. text
    else
      nr = nr + 1
      result[nr] = { op_name, text }
    end
  end
  return result
end

return M
