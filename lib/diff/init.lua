if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- Myers O(ND) forward pass.
-- Returns (trace, d_final, offset) or (nil, errmsg).
local function myers_forward(a, b)
  local n = #a
  local m = #b
  local max_d = n + m
  local offset = max_d + 2
  local v = { [offset] = 0 }
  local trace = {}

  for d = 0, max_d do
    for k = -d, d, 2 do
      local x
      if k == -d or (k ~= d and (v[offset + k - 1] or -1) < (v[offset + k + 1] or -1)) then
        x = v[offset + k + 1] or 0
      else
        x = (v[offset + k - 1] or 0) + 1
      end
      local y = x - k
      while x < n and y < m and a[x + 1] == b[y + 1] do
        x = x + 1
        y = y + 1
      end
      v[offset + k] = x
      if x >= n and y >= m then
        local snap = {}
        for j = -d, d, 2 do snap[offset + j] = v[offset + j] end
        trace[d + 1] = snap
        return trace, d, offset
      end
    end
    local snap = {}
    for j = -d, d, 2 do snap[offset + j] = v[offset + j] end
    trace[d + 1] = snap
  end

  return nil, "diff: no solution found"
end

-- Backtrack through trace to produce a flat list of regions.
-- Each region: { op, ax, ay, bx, by } (all 1-indexed, inclusive).
local function myers_backtrack(trace, n, m, d_final, offset)
  local x, y = n, m
  local stack = {}
  local ns = 0

  for d = d_final, 0, -1 do
    local k = x - y
    local prev_snap = d > 0 and trace[d] or nil
    local function prev_v(ki)
      if not prev_snap then return 0 end
      return prev_snap[offset + ki] or -1
    end

    local prev_k
    if k == -d or (k ~= d and prev_v(k - 1) < prev_v(k + 1)) then
      prev_k = k + 1
    else
      prev_k = k - 1
    end

    local prev_x = d > 0 and (prev_snap[offset + prev_k] or 0) or 0
    local prev_y = prev_x - prev_k

    local diag_start_x, diag_start_y
    if d > 0 then
      if prev_k > k then
        diag_start_x = prev_x
        diag_start_y = prev_y + 1
      else
        diag_start_x = prev_x + 1
        diag_start_y = prev_y
      end
    else
      diag_start_x = 0
      diag_start_y = 0
    end

    -- Emit equal diagonal (backwards)
    if x > diag_start_x then
      ns = ns + 1
      stack[ns] = { "eq", diag_start_x + 1, x, diag_start_y + 1, y }
      x = diag_start_x
      y = diag_start_y
    end

    -- Emit the edit
    if d > 0 then
      if prev_k > k then
        -- insert from b[y]
        ns = ns + 1
        stack[ns] = { "ins", x + 1, x, y, y }
        y = y - 1
      else
        -- delete a[x]
        ns = ns + 1
        stack[ns] = { "del", x, x, y + 1, y }
        x = x - 1
      end
    end
  end

  -- Reverse to forward order and convert to table form
  local result = {}
  for i = ns, 1, -1 do
    local e = stack[i]
    result[ns - i + 1] = { op = e[1], a_start = e[2], a_end = e[3], b_start = e[4], b_end = e[5] }
  end
  return result
end

-- Core diff: returns edit script as list of operations.
-- a, b: arrays (tables with integer keys 1..n).
-- Returns { {op="eq"|"ins"|"del", a_start, a_end, b_start, b_end}, ... }
-- For "ins": a_start > a_end (no a elements consumed); b_start..b_end are inserted.
-- For "del": b_start > b_end (no b elements consumed); a_start..a_end are deleted.
-- For "eq":  a_start..a_end == b_start..b_end.
--: ({ [number]: unknown }, { [number]: unknown }) -> { [number]: { op: string, a_start: number, a_end: number, b_start: number, b_end: number } }
M.diff = function(a, b)
  local n = #a
  local m = #b

  if n == 0 and m == 0 then return {} end
  if n == 0 then
    return { { op = "ins", a_start = 1, a_end = 0, b_start = 1, b_end = m } }
  end
  if m == 0 then
    return { { op = "del", a_start = 1, a_end = n, b_start = 1, b_end = 0 } }
  end

  local trace, d_final, offset = myers_forward(a, b)
  if not trace then return nil, d_final end

  -- d_final == 0 means identical sequences: one big eq op
  if d_final == 0 then
    return { { op = "eq", a_start = 1, a_end = n, b_start = 1, b_end = m } }
  end

  return myers_backtrack(trace, n, m, d_final, offset)
end

-- Edit distance only (no script). O(ND) via Myers.
--: ({ [number]: unknown }, { [number]: unknown }) -> number
M.distance = function(a, b)
  local n = #a
  local m = #b
  if n == 0 then return m end
  if m == 0 then return n end

  local max_d = n + m
  local offset = max_d + 2
  local v = { [offset] = 0 }

  for d = 0, max_d do
    for k = -d, d, 2 do
      local x
      if k == -d or (k ~= d and (v[offset + k - 1] or -1) < (v[offset + k + 1] or -1)) then
        x = v[offset + k + 1] or 0
      else
        x = (v[offset + k - 1] or 0) + 1
      end
      local y = x - k
      while x < n and y < m and a[x + 1] == b[y + 1] do
        x = x + 1
        y = y + 1
      end
      v[offset + k] = x
      if x >= n and y >= m then return d end
    end
  end

  return n + m -- unreachable, but safe fallback
end

-- Split a string into lines. Each line includes its trailing newline.
-- A trailing newline does NOT produce an extra empty entry.
--: (string) -> { [number]: string }
local function split_lines(s)
  local lines = {}
  local n = 0
  local pos = 1
  local len = #s
  while pos <= len do
    local nl = s:find("\n", pos, true)
    if nl then
      n = n + 1
      lines[n] = s:sub(pos, nl)
      pos = nl + 1
    else
      n = n + 1
      lines[n] = s:sub(pos)
      pos = len + 1
    end
  end
  return lines
end

-- Convenience: diff two strings line-by-line.
-- Returns array of { op, line } where op = "=", "+", "-".
--: (string, string) -> { [number]: { op: string, line: string } }
M.lines = function(str_a, str_b)
  local a = split_lines(str_a)
  local b = split_lines(str_b)
  local edits = M.diff(a, b)
  if not edits then return nil, "diff failed" end

  local result = {}
  local nr = 0
  for _, e in ipairs(edits) do
    if e.op == "eq" then
      for i = e.a_start, e.a_end do
        nr = nr + 1
        result[nr] = { op = "=", line = a[i] }
      end
    elseif e.op == "del" then
      for i = e.a_start, e.a_end do
        nr = nr + 1
        result[nr] = { op = "-", line = a[i] }
      end
    elseif e.op == "ins" then
      for i = e.b_start, e.b_end do
        nr = nr + 1
        result[nr] = { op = "+", line = b[i] }
      end
    end
  end
  return result
end

-- Convenience: diff two strings character-by-character.
-- Returns array of { op, line } where line is a single character and op = "=", "+", "-".
--: (string, string) -> { [number]: { op: string, line: string } }
M.chars = function(str_a, str_b)
  local a = {}
  for i = 1, #str_a do a[i] = str_a:sub(i, i) end
  local b = {}
  for i = 1, #str_b do b[i] = str_b:sub(i, i) end

  local edits = M.diff(a, b)
  if not edits then return nil, "diff failed" end

  local result = {}
  local nr = 0
  for _, e in ipairs(edits) do
    if e.op == "eq" then
      for i = e.a_start, e.a_end do
        nr = nr + 1
        result[nr] = { op = "=", line = a[i] }
      end
    elseif e.op == "del" then
      for i = e.a_start, e.a_end do
        nr = nr + 1
        result[nr] = { op = "-", line = a[i] }
      end
    elseif e.op == "ins" then
      for i = e.b_start, e.b_end do
        nr = nr + 1
        result[nr] = { op = "+", line = b[i] }
      end
    end
  end
  return result
end

-- Unified diff output (patch format).
-- str_a, str_b: strings to diff (line-by-line).
-- opts: { context=3, a_name="a", b_name="b" }
-- Returns a unified diff string.
--: (string, string, { context: number?, a_name: string?, b_name: string? }?) -> string
M.unified = function(str_a, str_b, opts)
  opts = opts or {}
  local ctx = opts.context
  if ctx == nil then ctx = 3 end
  local a_name = opts.a_name or "a"
  local b_name = opts.b_name or "b"

  local a = split_lines(str_a)
  local b = split_lines(str_b)
  local edits = M.diff(a, b)
  if not edits then return "" end

  -- Flatten into per-line ops with source indices for context tracking
  -- flat[i] = { op="="|"+"|"-", text=string, ai=number?, bi=number? }
  local flat = {}
  local nf = 0
  for _, e in ipairs(edits) do
    if e.op == "eq" then
      local bi = e.b_start
      for ai = e.a_start, e.a_end do
        nf = nf + 1
        flat[nf] = { op = "=", text = a[ai], ai = ai, bi = bi }
        bi = bi + 1
      end
    elseif e.op == "del" then
      for ai = e.a_start, e.a_end do
        nf = nf + 1
        flat[nf] = { op = "-", text = a[ai], ai = ai }
      end
    elseif e.op == "ins" then
      for bi = e.b_start, e.b_end do
        nf = nf + 1
        flat[nf] = { op = "+", text = b[bi], bi = bi }
      end
    end
  end

  -- Identify changed indices in flat
  local changed = {}
  local nc = 0
  for i = 1, nf do
    if flat[i].op ~= "=" then
      nc = nc + 1
      changed[nc] = i
    end
  end

  if nc == 0 then return "" end

  -- Group changed lines into hunks with context
  local hunk_ranges = {}
  local nh = 0
  local hs = math.max(1, changed[1] - ctx)
  local he = math.min(nf, changed[1] + ctx)

  for ci = 2, nc do
    local idx = changed[ci]
    local new_start = math.max(1, idx - ctx)
    if new_start <= he + 1 then
      -- Extend current hunk
      he = math.min(nf, idx + ctx)
    else
      nh = nh + 1
      hunk_ranges[nh] = { hs, he }
      hs = new_start
      he = math.min(nf, idx + ctx)
    end
  end
  nh = nh + 1
  hunk_ranges[nh] = { hs, he }

  local out = {}
  local no = 0
  no = no + 1; out[no] = "--- " .. a_name .. "\n"
  no = no + 1; out[no] = "+++ " .. b_name .. "\n"

  for hi = 1, nh do
    local hstart, hend = hunk_ranges[hi][1], hunk_ranges[hi][2]

    -- Compute hunk header counts
    local a_start_line, b_start_line
    local a_count, b_count = 0, 0
    for i = hstart, hend do
      local f = flat[i]
      if f.op == "=" then
        if not a_start_line then a_start_line = f.ai end
        if not b_start_line then b_start_line = f.bi end
        a_count = a_count + 1
        b_count = b_count + 1
      elseif f.op == "-" then
        if not a_start_line then a_start_line = f.ai end
        a_count = a_count + 1
      elseif f.op == "+" then
        if not b_start_line then b_start_line = f.bi end
        b_count = b_count + 1
      end
    end
    a_start_line = a_start_line or 0
    b_start_line = b_start_line or 0

    no = no + 1
    out[no] = "@@ -" .. a_start_line .. "," .. a_count
           .. " +" .. b_start_line .. "," .. b_count .. " @@\n"

    for i = hstart, hend do
      local f = flat[i]
      -- Strip trailing newline for output (unified diff format has no bare \n)
      local text = f.text
      -- lines already include newlines; emit them directly
      if f.op == "=" then
        no = no + 1; out[no] = " " .. text
        -- ensure newline
        if text:sub(-1) ~= "\n" then no = no + 1; out[no] = "\n" end
      elseif f.op == "-" then
        no = no + 1; out[no] = "-" .. text
        if text:sub(-1) ~= "\n" then no = no + 1; out[no] = "\n" end
      elseif f.op == "+" then
        no = no + 1; out[no] = "+" .. text
        if text:sub(-1) ~= "\n" then no = no + 1; out[no] = "\n" end
      end
    end
  end

  return table.concat(out)
end

-- Parse a unified diff and apply it to original string.
-- Returns patched string, or (nil, errmsg) on failure.
--: (string, string) -> string | (nil, string)
M.apply = function(original, patch)
  if patch == "" then return original end

  local orig_lines = split_lines(original)
  local patch_lines = split_lines(patch)

  -- Skip header lines (--- and +++)
  local pi = 1
  local np = #patch_lines

  -- Skip past file header
  while pi <= np do
    local line = patch_lines[pi]
    if line:sub(1, 4) == "--- " or line:sub(1, 4) == "+++ " then
      pi = pi + 1
    else
      break
    end
  end

  local result = {}
  local nr = 0
  local orig_pos = 1 -- 1-indexed, next line to consume from orig_lines

  while pi <= np do
    local line = patch_lines[pi]
    local stripped = line:gsub("\n$", "")

    -- Parse hunk header: @@ -a_start,a_count +b_start,b_count @@
    local a_start_s, a_count_s, b_start_s, b_count_s =
      stripped:match("^@@ %-(%d+),(%d+) %+(%d+),(%d+) @@")
    if not a_start_s then
      -- Try without counts (single-line hunks sometimes omit count)
      a_start_s, b_start_s =
        stripped:match("^@@ %-(%d+) %+(%d+) @@")
      if a_start_s then
        a_count_s = "1"
        b_count_s = "1"
      end
    end

    if a_start_s then
      local a_start = tonumber(a_start_s)
      -- Emit context lines from orig up to hunk start
      while orig_pos < a_start do
        nr = nr + 1
        result[nr] = orig_lines[orig_pos] or ""
        orig_pos = orig_pos + 1
      end
      pi = pi + 1

      -- Process hunk lines
      while pi <= np do
        local hline = patch_lines[pi]
        local hstripped = hline:gsub("\n$", "")
        local prefix = hstripped:sub(1, 1)

        if prefix == " " then
          -- Context line: keep from original
          if not orig_lines[orig_pos] then
            return nil, "apply: context line mismatch at orig line " .. orig_pos
          end
          nr = nr + 1
          result[nr] = orig_lines[orig_pos]
          orig_pos = orig_pos + 1
          pi = pi + 1
        elseif prefix == "-" then
          -- Delete: skip original line
          if not orig_lines[orig_pos] then
            return nil, "apply: delete line mismatch at orig line " .. orig_pos
          end
          orig_pos = orig_pos + 1
          pi = pi + 1
        elseif prefix == "+" then
          -- Insert: add new line
          local new_line = hstripped:sub(2)
          -- Restore newline: the patch line had a newline stripped
          -- Check if next patch line is a "\ No newline at end of file" marker
          -- For simplicity, restore newline always unless it's the last line indicator
          nr = nr + 1
          result[nr] = new_line .. "\n"
          pi = pi + 1
        elseif prefix == "@" or prefix == "-" and hstripped:sub(1, 3) == "---" then
          break
        else
          -- End of hunk (blank line or next hunk header)
          break
        end
      end
    else
      pi = pi + 1
    end
  end

  -- Append remaining original lines
  while orig_pos <= #orig_lines do
    nr = nr + 1
    result[nr] = orig_lines[orig_pos]
    orig_pos = orig_pos + 1
  end

  return table.concat(result)
end

return M
