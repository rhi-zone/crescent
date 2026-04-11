if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- Split a string into an array of lines (preserving line endings).
--: (string) -> { [number]: string }
M.split_lines = function(s)
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

-- Forward pass of Myers diff. Returns (trace, d_final, offset) or (nil, errmsg).
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

  return nil, "diff failed: no solution found"
end

-- Backtrack through trace to produce edit script.
local function myers_backtrack(trace, a, b, d_final, offset)
  local n = #a
  local m = #b
  local x, y = n, m
  local stack = {}
  local ns = 0

  for d = d_final, 0, -1 do
    local k = x - y

    -- The decision at step d used v from step d-1 (trace[d], 1-indexed).
    -- For d=0, the "previous" state is v[k]=0 for all k (initial).
    local prev_snap = d > 0 and trace[d] or nil

    local function prev_v(ki)
      if not prev_snap then return 0 end -- d=0: all zeros except we only check k=0
      return prev_snap[offset + ki] or -1
    end

    -- Determine which diagonal we came from
    local prev_k
    if k == -d or (k ~= d and prev_v(k - 1) < prev_v(k + 1)) then
      prev_k = k + 1 -- came from above: insert
    else
      prev_k = k - 1 -- came from left: delete
    end

    -- x on prev_k diagonal at end of step d-1
    local prev_x = d > 0 and (prev_snap[offset + prev_k] or 0) or 0
    local prev_y = prev_x - prev_k

    -- After the edit, we start the diagonal walk.
    -- The edit moves from (prev_x, prev_y) to the start of the diagonal:
    --   delete: (prev_x+1, prev_y) then diagonal to (x, y)
    --   insert: (prev_x, prev_y+1) then diagonal to (x, y)
    -- So the diagonal start is:
    local diag_start_x, diag_start_y
    if d > 0 then
      if prev_k > k then
        -- insert: x stays, y increments
        diag_start_x = prev_x
        diag_start_y = prev_y + 1
      else
        -- delete: x increments, y stays
        diag_start_x = prev_x + 1
        diag_start_y = prev_y
      end
    else
      diag_start_x = 0
      diag_start_y = 0
    end

    -- Emit diagonal equals (backwards from (x,y) to (diag_start_x, diag_start_y))
    while x > diag_start_x and y > diag_start_y do
      ns = ns + 1
      stack[ns] = { op = "equal", val = a[x], a_idx = x, b_idx = y }
      x = x - 1
      y = y - 1
    end

    -- Emit the edit
    if d > 0 then
      if prev_k > k then
        ns = ns + 1
        stack[ns] = { op = "insert", val = b[y], b_idx = y }
        y = y - 1
      else
        ns = ns + 1
        stack[ns] = { op = "delete", val = a[x], a_idx = x }
        x = x - 1
      end
    end
  end

  -- Reverse to forward order
  local result = {}
  for i = ns, 1, -1 do
    result[ns - i + 1] = stack[i]
  end
  return result
end

-- Myers diff algorithm (greedy, O(ND)).
-- Returns an edit script: array of {op, val, a_idx?, b_idx?}.
--: ({ [number]: unknown }, { [number]: unknown }) -> { [number]: { op: string, val: unknown, a_idx: number?, b_idx: number? } } | (nil, string)
M.diff = function(a, b)
  local n = #a
  local m = #b

  if n == 0 and m == 0 then return {} end
  if n == 0 then
    local edits = {}
    for j = 1, m do
      edits[j] = { op = "insert", val = b[j], b_idx = j }
    end
    return edits
  end
  if m == 0 then
    local edits = {}
    for i = 1, n do
      edits[i] = { op = "delete", val = a[i], a_idx = i }
    end
    return edits
  end

  local trace, d_final, offset = myers_forward(a, b)
  if not trace then return nil, d_final end
  return myers_backtrack(trace, a, b, d_final, offset)
end

-- Diff two strings by lines.
--: (string, string) -> { [number]: { op: string, val: unknown, a_idx: number?, b_idx: number? } } | (nil, string)
M.diff_strings = function(s1, s2)
  local a = M.split_lines(s1)
  local b = M.split_lines(s2)
  return M.diff(a, b)
end

-- Produce unified diff output.
--: ({ [number]: unknown }, { [number]: unknown }, { context: number?, a_name: string?, b_name: string? }?) -> string
M.unified = function(a, b, opts)
  opts = opts or {}
  local ctx_lines = opts.context or 3
  local a_name = opts.a_name or "a"
  local b_name = opts.b_name or "b"

  local edits = M.diff(a, b)
  if not edits then return "" end

  local changes = {}
  local nc = 0
  for i = 1, #edits do
    if edits[i].op ~= "equal" then
      nc = nc + 1
      changes[nc] = i
    end
  end

  if nc == 0 then return "" end

  -- Group changes into hunks
  local hunks = {}
  local nh = 0
  local hunk_start = changes[1]
  local hunk_end = changes[1]

  for ci = 2, nc do
    local ci_idx = changes[ci]
    if ci_idx - hunk_end <= 2 * ctx_lines then
      hunk_end = ci_idx
    else
      nh = nh + 1
      hunks[nh] = { hunk_start, hunk_end }
      hunk_start = ci_idx
      hunk_end = ci_idx
    end
  end
  nh = nh + 1
  hunks[nh] = { hunk_start, hunk_end }

  local out = {}
  local no = 0

  no = no + 1; out[no] = "--- " .. a_name .. "\n"
  no = no + 1; out[no] = "+++ " .. b_name .. "\n"

  for hi = 1, nh do
    local hs, he = hunks[hi][1], hunks[hi][2]
    local start_idx = hs - ctx_lines
    if start_idx < 1 then start_idx = 1 end
    local end_idx = he + ctx_lines
    if end_idx > #edits then end_idx = #edits end

    local a_start, a_count = nil, 0
    local b_start, b_count = nil, 0

    for i = start_idx, end_idx do
      local e = edits[i]
      if e.op == "equal" then
        if not a_start then a_start = e.a_idx end
        if not b_start then b_start = e.b_idx end
        a_count = a_count + 1
        b_count = b_count + 1
      elseif e.op == "delete" then
        if not a_start then a_start = e.a_idx end
        a_count = a_count + 1
      elseif e.op == "insert" then
        if not b_start then b_start = e.b_idx end
        b_count = b_count + 1
      end
    end

    a_start = a_start or 0
    b_start = b_start or 0

    no = no + 1
    out[no] = "@@ -" .. a_start .. "," .. a_count .. " +" .. b_start .. "," .. b_count .. " @@\n"

    for i = start_idx, end_idx do
      local e = edits[i]
      local val = tostring(e.val)
      if e.op == "equal" then
        no = no + 1; out[no] = " " .. val .. "\n"
      elseif e.op == "delete" then
        no = no + 1; out[no] = "-" .. val .. "\n"
      elseif e.op == "insert" then
        no = no + 1; out[no] = "+" .. val .. "\n"
      end
    end
  end

  return table.concat(out)
end

-- Apply an edit script to sequence a, producing sequence b.
--: ({ [number]: unknown }, { [number]: { op: string, val: unknown } }) -> { [number]: unknown }
M.patch = function(a, edits)
  local result = {}
  local nr = 0
  for i = 1, #edits do
    local e = edits[i]
    if e.op == "equal" or e.op == "insert" then
      nr = nr + 1
      result[nr] = e.val
    end
  end
  return result
end

-- Longest common subsequence (derived from the diff).
--: ({ [number]: unknown }, { [number]: unknown }) -> { [number]: unknown }
M.lcs = function(a, b)
  local edits = M.diff(a, b)
  if not edits then return {} end
  local result = {}
  local nr = 0
  for i = 1, #edits do
    if edits[i].op == "equal" then
      nr = nr + 1
      result[nr] = edits[i].val
    end
  end
  return result
end

return M
