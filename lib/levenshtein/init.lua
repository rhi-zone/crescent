-- lib/levenshtein/init.lua
-- String edit distance algorithms: Levenshtein, Damerau-Levenshtein, OSA,
-- LCS, Jaro, Jaro-Winkler, fuzzy matching, and similarity utilities.
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local byte = string.byte
local sub = string.sub
local floor = math.floor
local min = math.min
local max = math.max

-- LuaJIT bit operations (bit library; also works on PUC-Rio via bit32 shim)
local bit = bit or rawget(_G, "bit32") or require("bit") --[[: { bor: (...integer) -> integer, band: (...integer) -> integer, bnot: (integer) -> integer, lshift: (integer, integer) -> integer, ... }]]
local bor, band, bnot, lshift = bit.bor, bit.band, bit.bnot, bit.lshift

-- ---------------------------------------------------------------------------
-- Levenshtein distance (Wagner-Fischer, two-row)
-- ---------------------------------------------------------------------------

function M.distance(s, t)
  local m, n = #s, #t
  if m == 0 then return n end
  if n == 0 then return m end
  local prev = {} --: integer[]
  local curr = {} --: integer[]
  for j = 0, n do prev[j] = j end
  for i = 1, m do
    curr[0] = i
    local si = sub(s, i, i)
    for j = 1, n do
      if si == sub(t, j, j) then
        curr[j] = prev[j - 1]
      else
        curr[j] = 1 + min(prev[j], curr[j - 1], prev[j - 1])
      end
    end
    prev, curr = curr, prev
  end
  return prev[n]
end

-- ---------------------------------------------------------------------------
-- Levenshtein with custom costs
-- ---------------------------------------------------------------------------

-- opts.insert / opts.delete / opts.substitute may be numbers or functions(char)->number
local function cost(opt, c)
  if type(opt) == "function" then return opt(c) end
  return opt or 1
end

function M.distance_weighted(s, t, opts)
  opts = opts or {}
  local m, n = #s, #t
  if m == 0 then
    local sum = 0
    for j = 1, n do sum = sum + cost(opts.insert, sub(t, j, j)) end
    return sum
  end
  if n == 0 then
    local sum = 0
    for i = 1, m do sum = sum + cost(opts.delete, sub(s, i, i)) end
    return sum
  end
  -- prev[j] = edit cost for s[1..i-1] -> t[1..j]
  local prev = {} --: number[]
  local curr = {} --: number[]
  prev[0] = 0
  for j = 1, n do prev[j] = prev[j - 1] + cost(opts.insert, sub(t, j, j)) end
  for i = 1, m do
    local si = sub(s, i, i)
    curr[0] = prev[0] + cost(opts.delete, si)
    for j = 1, n do
      local tj = sub(t, j, j)
      if si == tj then
        curr[j] = prev[j - 1]
      else
        local ins = curr[j - 1] + cost(opts.insert, tj)
        local del = prev[j]   + cost(opts.delete, si)
        local sub_ = prev[j - 1] + cost(opts.substitute, si)
        curr[j] = min(ins, del, sub_)
      end
    end
    prev, curr = curr, prev
  end
  return prev[n]
end

-- ---------------------------------------------------------------------------
-- Optimal String Alignment (restricted Damerau)
-- ---------------------------------------------------------------------------

function M.osa(s, t)
  local m, n = #s, #t
  if m == 0 then return n end
  if n == 0 then return m end
  -- Three rows: pp (i-2), p (i-1), c (i)
  local pp = {} --: integer[]
  local p = {} --: integer[]
  local c = {} --: integer[]
  for j = 0, n do p[j] = j end
  -- We need a "zeroth" prev-prev row; initialise as large sentinel
  for j = 0, n do pp[j] = j + m + 1 end
  for i = 1, m do
    c[0] = i
    local si = sub(s, i, i)
    for j = 1, n do
      local tj = sub(t, j, j)
      if si == tj then
        c[j] = p[j - 1]
      else
        c[j] = 1 + min(p[j], c[j - 1], p[j - 1])
      end
      -- transposition: s[i-1]==t[j] and s[i]==t[j-1]
      if i > 1 and j > 1 and si == sub(t, j - 1, j - 1) and sub(s, i - 1, i - 1) == tj then
        c[j] = min(c[j], pp[j - 2] + 1)
      end
    end
    pp, p, c = p, c, pp
  end
  return p[n]
end

-- ---------------------------------------------------------------------------
-- Damerau-Levenshtein (unrestricted / full, O(mn) space)
-- ---------------------------------------------------------------------------

function M.damerau(s, t)
  local m, n = #s, #t
  if m == 0 then return n end
  if n == 0 then return m end

  -- Full Damerau-Levenshtein (unrestricted transpositions).
  -- Implementation follows the standard algorithm with a sentinel
  -- row/column (-1 in 0-based terms).  We store using 1-based keys so
  -- d[i+1][j+1] corresponds to s[1..i] vs t[1..j], and d[0][*] / d[*][0]
  -- are the sentinel row/column set to a large value.
  -- da[c] = last 1-based row in s where character c was seen.

  local INF = m + n + 2
  local da = {} --: { [string]: integer }

  -- Flat array, (m+2) x (n+2), 1-based: index(i,j) = i*(n+2)+j
  local W = n + 2
  local d = {} --: { [integer]: integer }
  -- sentinel row 0 and col 0: d[0][j] = INF for all j
  for i = 0, m + 1 do
    for j = 0, n + 1 do
      d[i * W + j] = INF
    end
  end
  -- d[1..m+1][1] = 0..m (cost to reach s[1..i] from empty t)
  for i = 0, m do d[(i + 1) * W + 1] = i end
  -- d[1][1..n+1] = 0..n
  for j = 0, n do d[1 * W + (j + 1)] = j end

  for i = 1, m do
    local si = sub(s, i, i)
    local db = 0   -- last 1-based t column matching si
    for j = 1, n do
      local tj = sub(t, j, j)
      local i1 = da[tj] or 0   -- last s row matching tj
      local j1 = db
      local sub_cost
      if si == tj then
        sub_cost = 0
        db = j
      else
        sub_cost = 1
      end
      -- Indices shifted by +1 for the sentinel border
      d[(i + 1) * W + (j + 1)] = min(
        d[i * W + j] + sub_cost,                      -- match / substitution
        d[(i + 1) * W + j] + 1,                       -- insertion
        d[i * W + (j + 1)] + 1,                       -- deletion
        d[i1 * W + j1] + (i - i1 - 1) + 1 + (j - j1 - 1)  -- transposition
      )
    end
    da[si] = i
  end
  return d[(m + 1) * W + (n + 1)]
end

-- ---------------------------------------------------------------------------
-- Longest Common Subsequence length
-- ---------------------------------------------------------------------------

function M.lcs(s, t)
  local m, n = #s, #t
  if m == 0 or n == 0 then return 0 end
  local prev = {} --: integer[]
  local curr = {} --: integer[]
  for j = 0, n do prev[j] = 0 end
  for i = 1, m do
    curr[0] = 0
    local si = sub(s, i, i)
    for j = 1, n do
      if si == sub(t, j, j) then
        curr[j] = prev[j - 1] + 1
      else
        curr[j] = max(prev[j], curr[j - 1])
      end
    end
    prev, curr = curr, prev
  end
  return prev[n]
end

-- ---------------------------------------------------------------------------
-- Jaro similarity
-- ---------------------------------------------------------------------------

function M.jaro(s, t)
  local m_len, n_len = #s, #t
  if m_len == 0 and n_len == 0 then return 1.0 end
  if m_len == 0 or n_len == 0 then return 0.0 end
  if s == t then return 1.0 end

  local win = floor(max(m_len, n_len) / 2) - 1
  if win < 0 then win = 0 end

  local s_match = {} --: { [integer]: boolean }
  local t_match = {} --: { [integer]: boolean }
  local matches = 0 --: integer

  for i = 1, m_len do
    local lo = max(1, i - win)
    local hi = min(n_len, i + win)
    for j = lo, hi do
      if not t_match[j] and sub(s, i, i) == sub(t, j, j) then
        s_match[i] = true
        t_match[j] = true
        matches = matches + 1
        break
      end
    end
  end

  if matches == 0 then return 0.0 end

  -- Count transpositions
  local k = 0
  local transpositions = 0
  for i = 1, m_len do
    if s_match[i] then
      k = k + 1
      -- find k-th matched char in t
      local count = 0
      for j = 1, n_len do
        if t_match[j] then
          count = count + 1
          if count == k then
            if sub(s, i, i) ~= sub(t, j, j) then
              transpositions = transpositions + 1
            end
            break
          end
        end
      end
    end
  end

  local jaro = (matches / m_len + matches / n_len + (matches - transpositions / 2) / matches) / 3
  return jaro
end

-- ---------------------------------------------------------------------------
-- Jaro-Winkler similarity
-- ---------------------------------------------------------------------------

function M.jaro_winkler(s, t, p)
  p = p or 0.1
  local jaro_score = M.jaro(s, t)
  -- Common prefix length (up to 4)
  local prefix = 0
  local limit = min(4, min(#s, #t))
  for i = 1, limit do
    if sub(s, i, i) == sub(t, i, i) then
      prefix = prefix + 1
    else
      break
    end
  end
  return jaro_score + prefix * p * (1 - jaro_score)
end

-- ---------------------------------------------------------------------------
-- Normalized similarity (Levenshtein-based, 0..1)
-- ---------------------------------------------------------------------------

function M.similarity(s, t)
  local m, n = #s, #t
  if m == 0 and n == 0 then return 1.0 end
  local longest = max(m, n)
  return 1.0 - M.distance(s, t) / longest
end

-- ---------------------------------------------------------------------------
-- Fuzzy find (Bitap / shift-or, approximate string matching)
-- Returns start, finish, errors (1-indexed) or nil
-- ---------------------------------------------------------------------------

-- Build bitmask table for pattern characters
local function bitap_masks(pattern)
  local pm = {}
  local plen = #pattern
  for i = 1, plen do
    local c = sub(pattern, i, i)
    pm[c] = bor(pm[c] or 0, lshift(1, i - 1))
  end
  return pm
end

-- Bitap approximate string matching (Baeza-Yates / Wu-Manber).
-- Each state[e] is a bitmask where bit i means "pattern[1..i+1] matched
-- ending here with exactly e errors."  We use the standard recurrence:
--   R'[e] = ((R[e] << 1) | 1) & pm[text[j]]          -- match / substitution
--         | (R[e-1] << 1) | 1                          -- insertion into text
--         | R[e-1]                                      -- deletion from text
--         | (R[e-1] << 1)                              -- substitution (alt)
-- Accept when bit plen-1 is set in any state[e] with e <= max_errors.

function M.fuzzy_find(text, pattern, max_errors)
  max_errors = max_errors or 0
  local tlen, plen = #text, #pattern
  if plen == 0 then return 1, 0, 0 end
  if tlen == 0 then return nil end

  local pm = bitap_masks(pattern)
  local accept = lshift(1, plen - 1)

  local states = {} --: integer[]
  for e = 0, max_errors do states[e] = 0 end

  for j = 1, tlen do
    local c = sub(text, j, j)
    local cmask = pm[c] or 0
    -- Update from high error count to low to avoid cascade reads of new values
    for e = max_errors, 1, -1 do
      local prev = states[e - 1]
      local match_sub  = band(bor(lshift(states[e], 1), 1), cmask)
      local ins        = bor(lshift(prev, 1), 1)
      local del        = prev
      local replace    = lshift(prev, 1)
      states[e] = bor(match_sub, bor(ins, bor(del, replace)))
    end
    states[0] = band(bor(lshift(states[0], 1), 1), cmask)

    -- Check each error level (prefer fewest errors)
    for e = 0, max_errors do
      if band(states[e], accept) ~= 0 then
        local start = max(1, j - plen - e + 1)
        return start, j, e
      end
    end
  end
  return nil
end

function M.fuzzy_find_all(text, pattern, max_errors)
  max_errors = max_errors or 0
  local tlen, plen = #text, #pattern
  local results = {}
  if plen == 0 then return results end

  local pm = bitap_masks(pattern)
  local accept = lshift(1, plen - 1)

  local states = {} --: integer[]
  for e = 0, max_errors do states[e] = 0 end

  for j = 1, tlen do
    local c = sub(text, j, j)
    local cmask = pm[c] or 0
    for e = max_errors, 1, -1 do
      local prev = states[e - 1]
      local match_sub = band(bor(lshift(states[e], 1), 1), cmask)
      local ins       = bor(lshift(prev, 1), 1)
      local del       = prev
      local replace   = lshift(prev, 1)
      states[e] = bor(match_sub, bor(ins, bor(del, replace)))
    end
    states[0] = band(bor(lshift(states[0], 1), 1), cmask)

    for e = 0, max_errors do
      if band(states[e], accept) ~= 0 then
        local start = max(1, j - plen - e + 1)
        results[#results + 1] = { start, j, e }
        -- Reset states to avoid re-reporting overlapping matches
        for k = 0, max_errors do states[k] = 0 end
        break
      end
    end
  end
  return results
end

-- ---------------------------------------------------------------------------
-- Closest: sort candidates by Levenshtein distance to query
-- ---------------------------------------------------------------------------

function M.closest(query, candidates, n)
  local scored = {}
  for i = 1, #candidates do
    scored[i] = { candidates[i], M.distance(query, candidates[i]) }
  end
  table.sort(scored, function(a, b) return a[2] < b[2] end)
  local result = {}
  local limit = n and min(n, #scored) or #scored
  for i = 1, limit do
    result[i] = scored[i][1]
  end
  return result
end

-- ---------------------------------------------------------------------------
-- Is subsequence
-- ---------------------------------------------------------------------------

function M.is_subsequence(pattern, text)
  local pi, tlen = 1, #text
  local plen = #pattern
  if plen == 0 then return true end
  for i = 1, tlen do
    if sub(text, i, i) == sub(pattern, pi, pi) then
      pi = pi + 1
      if pi > plen then return true end
    end
  end
  return false
end

return M
