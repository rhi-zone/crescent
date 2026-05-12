if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- Bonus/penalty constants
local BONUS_CONSECUTIVE   = 15
local BONUS_WORD_BOUNDARY = 12
local BONUS_PREFIX        = 10
local BONUS_CAMEL_CASE    = 10
local BONUS_EXACT         = 20
local PENALTY_GAP         = 1
local PENALTY_LEADING_GAP = 1

local function char_lower(c)
  if c >= 65 and c <= 90 then return c + 32 end
  return c
end

local function is_word_boundary(prev, curr)
  -- After space, /, _, -, .
  if prev == 32 or prev == 47 or prev == 95 or prev == 45 or prev == 46 then
    return true
  end
  -- Camel case: prev lowercase, curr uppercase
  if prev >= 97 and prev <= 122 and curr >= 65 and curr <= 90 then
    return true
  end
  return false
end

-- Check if all characters in pattern appear in order in str.
-- case_sensitive default: false
--: (string, string, ({case_sensitive: (boolean | nil)} | nil)) -> boolean
function M.match(str, pattern, opts)
  if #pattern == 0 then return true end
  if #str == 0 then return false end

  local case_sensitive = opts and opts.case_sensitive or false

  local si = 1
  local pi = 1
  local slen = #str
  local plen = #pattern

  while si <= slen and pi <= plen do
    local sc = str:byte(si) or 0
    local pc = pattern:byte(pi) or 0
    if not case_sensitive then
      sc = char_lower(sc)
      pc = char_lower(pc)
    end
    if sc == pc then
      pi = pi + 1
    end
    si = si + 1
  end

  return pi > plen
end

-- Score a match. Returns score (number >= 0) or nil if no match.
-- Higher score = better match.
--: (string, string, ({case_sensitive: (boolean | nil)} | nil)) -> (number | nil)
function M.score(str, pattern, opts)
  local _, sc = M.positions(str, pattern, opts)
  return sc
end

-- Find matching positions and score.
-- Returns positions (array of 1-based indices), score; or nil, nil on no match.
--: (string, string, ({case_sensitive: (boolean | nil)} | nil)) -> (integer[] | nil, number | nil)
function M.positions(str, pattern, opts)
  if #pattern == 0 then
    -- Empty pattern matches with score 0, no positions
    return {}, 0
  end
  if #str == 0 then
    return nil, nil
  end

  local case_sensitive = opts and opts.case_sensitive or false

  local slen = #str
  local plen = #pattern

  -- Normalize strings for matching (single assignment to avoid conditional-reassign nil issue)
  local str_cmp = not case_sensitive and str:lower() or str
  local pat_cmp = not case_sensitive and pattern:lower() or pattern

  -- Quick match check
  if not M.match(str_cmp, pat_cmp, {case_sensitive = true}) then
    return nil, nil
  end

  -- Check for exact substring
  local exact_bonus = 0
  local exact_start = str_cmp:find(pat_cmp, 1, true)
  if exact_start then
    exact_bonus = BONUS_EXACT
  end

  -- Use a greedy forward scan to find best positions.
  -- For better scoring, we try to maximize consecutive runs and word boundaries.
  -- We'll do a simple forward-greedy pass to get positions, then score them.
  local positions = {}
  local si = 1
  local pi = 1

  while si <= slen and pi <= plen do
    if str_cmp:byte(si) == pat_cmp:byte(pi) then
      positions[pi] = si
      pi = pi + 1
    end
    si = si + 1
  end

  if pi <= plen then
    return nil, nil
  end

  -- Now try to find better positions by biasing toward word boundaries and
  -- consecutive runs. We do a second pass: for each matched char, if there's
  -- a later occurrence that starts a longer consecutive run, prefer it.
  -- Simple improvement: for the last matched character, look for a closer
  -- grouping (reduce gap penalties). Use DP for optimal placement.

  -- DP approach: dp[i][j] = best score matching pat[1..j] ending at str[i]
  -- This is O(n*m) which is acceptable for typical fuzzy match inputs.
  -- We store dp as a flat array indexed by (i-1)*plen + j.

  local NEG_INF = -1e9
  -- prev_dp[i] = best score when last pattern char was matched at str[i]
  -- We only need the previous pattern-char layer.

  -- dp_prev[si] = best score matching pat[1..j-1] ending at str[si]
  local dp_prev = {} --: { [integer]: number }
  local dp_curr = {} --: { [integer]: number }
  local from_prev = {} -- track back for each (si, pi): from_si

  -- Initialize: matching pat[1] at each position in str
  -- We'll use a 2-layer approach
  -- dp[j][si] = best score matching pat[1..j] with last match at str[si]

  -- Layer 0 (before matching anything): score 0 at position 0 (virtual)
  -- Leading gap penalty applied when first match is at si > 1
  for i = 0, slen do dp_prev[i] = NEG_INF end
  dp_prev[0] = 0  -- virtual start

  local best_scores = {}  -- best_scores[j][si] for backtracking
  local layers = {}  -- layers[j] = array indexed by si

  for j = 1, plen do
    local pc = pat_cmp:byte(j)
    local layer = {} --: { [integer]: number }
    for i = 1, slen do layer[i] = NEG_INF end

    for si2 = 1, slen do
      if str_cmp:byte(si2) == pc then
        -- Find best previous: any dp_prev[prev_si] where prev_si < si2
        -- Score contribution from transition prev_si -> si2:
        --   if prev_si == 0 (start): leading gap penalty * (si2 - 1)
        --   else: gap penalty * (si2 - prev_si - 1) + consecutive/boundary bonus

        -- Check all valid previous positions
        local best_here = NEG_INF
        local best_from = -1

        for prev_si = 0, si2 - 1 do
          local prev_score = dp_prev[prev_si]
          if prev_score > NEG_INF then
            local add = 0
            if prev_si == 0 then
              -- Leading gap
              add = add - PENALTY_LEADING_GAP * (si2 - 1)
              -- Prefix bonus if match starts at position 1
              if si2 == 1 then add = add + BONUS_PREFIX end
            else
              local gap = si2 - prev_si - 1
              add = add - PENALTY_GAP * gap
              -- Consecutive bonus
              if gap == 0 then
                add = add + BONUS_CONSECUTIVE
              end
              -- Word boundary bonus
              local prev_char = str_cmp:byte(prev_si) or 0  -- not used directly; need original
              local curr_char = str:byte(si2) or 0
              local prev_orig = str:byte(prev_si) or 0
              if is_word_boundary(prev_orig, curr_char) then
                add = add + BONUS_WORD_BOUNDARY
              end
              -- Camel case: prev was matched, check if curr is uppercase after lowercase
              -- Already handled in is_word_boundary
            end

            local candidate = prev_score + add
            if candidate > best_here then
              best_here = candidate
              best_from = prev_si
            end
          end
        end

        if best_here > NEG_INF then
          layer[si2] = best_here
        end
      end
    end

    layers[j] = layer
    -- Update dp_prev for next iteration: need to carry forward
    -- dp_prev[si] = max over all si' <= si of layer[si'] (best score ending at or before si)
    -- Actually for the next layer we need exact positions, not prefix max.
    -- Just set dp_prev = layer for next iteration.
    for i = 1, slen do dp_prev[i] = layer[i] end
    dp_prev[0] = NEG_INF
  end

  -- Find best final position
  local best_end = -1
  local best_final = NEG_INF
  local last_layer = layers[plen]
  for si2 = 1, slen do
    if last_layer[si2] and last_layer[si2] > best_final then
      best_final = last_layer[si2]
      best_end = si2
    end
  end

  if best_end == -1 then return nil, nil end

  -- Backtrack to find positions
  -- Rebuild from layers
  local result_pos = {}
  local cur_si = best_end
  result_pos[plen] = cur_si

  -- We need to store backtrack info. Redo DP storing from pointers.
  -- Re-run DP storing best_from for each (j, si).
  local from = {}  -- from[j] = array indexed by si -> prev_si
  for j2 = 1, plen do from[j2] = {} end

  -- Reset
  for i = 0, slen do dp_prev[i] = NEG_INF end
  dp_prev[0] = 0

  for j = 1, plen do
    local pc = pat_cmp:byte(j)
    local layer = {} --: { [integer]: number }
    local from_layer = {}
    for i = 1, slen do layer[i] = NEG_INF end

    for si2 = 1, slen do
      if str_cmp:byte(si2) == pc then
        local best_here = NEG_INF
        local best_from = -1

        for prev_si = 0, si2 - 1 do
          local prev_score = dp_prev[prev_si]
          if prev_score > NEG_INF then
            local add = 0
            if prev_si == 0 then
              add = add - PENALTY_LEADING_GAP * (si2 - 1)
              if si2 == 1 then add = add + BONUS_PREFIX end
            else
              local gap = si2 - prev_si - 1
              add = add - PENALTY_GAP * gap
              if gap == 0 then add = add + BONUS_CONSECUTIVE end
              local curr_char = str:byte(si2) or 0
              local prev_orig = str:byte(prev_si) or 0
              if is_word_boundary(prev_orig, curr_char) then
                add = add + BONUS_WORD_BOUNDARY
              end
            end
            local candidate = prev_score + add
            if candidate > best_here then
              best_here = candidate
              best_from = prev_si
            end
          end
        end

        if best_here > NEG_INF then
          layer[si2] = best_here
          from_layer[si2] = best_from
        end
      end
    end

    from[j] = from_layer
    for i = 1, slen do dp_prev[i] = layer[i] end
    dp_prev[0] = NEG_INF
    layers[j] = layer
  end

  -- Find best end again
  best_end = -1
  best_final = NEG_INF
  for si2 = 1, slen do
    if layers[plen][si2] and layers[plen][si2] > best_final then
      best_final = layers[plen][si2]
      best_end = si2
    end
  end

  if best_end == -1 then return nil, nil end

  -- Backtrack
  result_pos = {}
  cur_si = best_end
  for j = plen, 1, -1 do
    result_pos[j] = cur_si
    cur_si = from[j][cur_si]
  end

  local total_score = best_final + exact_bonus
  return result_pos, total_score
end

-- Search: filter and rank a list of candidates.
-- Returns array of {item, score, positions} sorted by score descending.
-- opts.key: function(item) -> string  (default: item itself)
-- opts.case_sensitive: boolean (default: false)
--: (string, unknown[], ({key: (((unknown) -> string) | nil), case_sensitive: (boolean | nil)} | nil)) -> {item: unknown, score: number, positions: integer[]}[]
function M.search(pattern, candidates, opts)
  local key_fn = opts and opts.key or nil
  local results = {}

  for i = 1, #candidates do
    local item = candidates[i]
    local str = (key_fn and key_fn(item) or item) --[[:! string]]
    local pos, sc = M.positions(str, pattern, opts)
    if pos and sc then
      results[#results + 1] = { item = item, score = sc, positions = pos }
    end
  end

  -- Sort by score descending
  table.sort(results, function(a, b)
    return a.score > b.score
  end)

  return results
end

return M
