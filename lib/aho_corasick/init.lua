-- lib/aho_corasick/init.lua
-- Aho-Corasick multi-pattern string matching automaton.
-- Simultaneous search for multiple patterns in a single O(n) pass.
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local byte, sub, concat = string.byte, string.sub, table.concat

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- Build the automaton (trie + failure links + output links).
-- Returns goto_table, fail_table, output_table (all indexed from node 1 = root).
local function build(patterns)
  -- goto_table[node][char_code] = next_node
  -- fail_table[node] = fail_node
  -- output_table[node] = list of {pattern_string, original_index} (may be nil)
  local goto_table = {{}}  -- node 1 = root
  local fail_table = {1}
  local output_table = {}
  local next_id = 2

  -- Phase 1: insert all patterns into the trie
  for idx, pat in ipairs(patterns) do
    local node = 1
    local n = #pat
    for i = 1, n do
      local c = byte(pat, i)
      local g = goto_table[node]
      if not g[c] then
        goto_table[next_id] = {}
        fail_table[next_id] = 1
        g[c] = next_id
        next_id = next_id + 1
      end
      node = (g[c] --[[:! integer]])
    end
    -- Mark this node as a pattern end
    if not output_table[node] then output_table[node] = {} end
    local out = output_table[node]
    out[#out + 1] = {pat, idx}
  end

  -- Phase 2: BFS to compute failure links and propagate outputs
  local queue = {}
  local head, tail = 1, 0
  local root_goto = goto_table[1]
  -- Direct children of root: fail → root
  for c, child in pairs(root_goto) do
    fail_table[child] = 1
    tail = tail + 1
    queue[tail] = child
  end

  while head <= tail do
    local node = queue[head]
    head = head + 1
    local ng = goto_table[node]
    for c, child in pairs(ng) do
      -- Compute fail(child)
      local f = fail_table[node]
      while f ~= 1 and not goto_table[f][c] do
        f = fail_table[f]
      end
      local dest = goto_table[f][c]
      if dest and dest ~= child then
        fail_table[child] = dest
      else
        fail_table[child] = 1
      end
      -- Propagate outputs from fail link
      local fout = output_table[fail_table[child]]
      if fout then
        if not output_table[child] then output_table[child] = {} end
        local cout = output_table[child]
        for _, v in ipairs(fout) do
          cout[#cout + 1] = v
        end
      end
      tail = tail + 1
      queue[tail] = child
    end
  end

  return goto_table, fail_table, output_table
end

-- ---------------------------------------------------------------------------
-- Automaton object
-- ---------------------------------------------------------------------------

local Automaton = {}
Automaton.__index = Automaton

-- Search text, calling cb(start, pattern, index) for each match.
function Automaton:search_cb(text, cb)
  local goto_table = self._goto
  local fail_table = self._fail
  local output_table = self._output
  local node = 1
  local n = #text
  for i = 1, n do
    local c = byte(text, i)
    -- Follow failure links until we find a transition or reach root
    while node ~= 1 and not goto_table[node][c] do
      node = fail_table[node]
    end
    local next_node = goto_table[node][c]
    if next_node then
      node = next_node
    end
    -- Report all matches at this node
    local out = output_table[node]
    if out then
      for _, v in ipairs(out) do
        local pat, idx = v[1], v[2]
        cb(i - #pat + 1, pat, idx)
      end
    end
  end
end

-- Search text, return array of {pos, pattern, pattern_index}.
function Automaton:search(text)
  local results = {}
  self:search_cb(text, function(start, pat, idx)
    results[#results + 1] = {start, pat, idx}
  end)
  -- Sort by start position, then by pattern index for determinism
  table.sort(results, function(a, b)
    if a[1] ~= b[1] then return a[1] < b[1] end
    return a[3] < b[3]
  end)
  return results
end

-- Find first match (lowest start position, lowest pattern index on tie).
-- Returns start, pattern, index or nil.
function Automaton:find(text)
  local best_start, best_pat, best_idx = nil, nil, nil
  self:search_cb(text, function(start, pat, idx)
    if best_start == nil or start < best_start or
       (start == best_start and idx < best_idx) then
      best_start, best_pat, best_idx = start, pat, idx
    end
  end)
  return best_start, best_pat, best_idx
end

-- Return true if any pattern occurs in text.
function Automaton:contains(text)
  local goto_table = self._goto
  local fail_table = self._fail
  local output_table = self._output
  local node = 1
  local n = #text
  for i = 1, n do
    local c = byte(text, i)
    while node ~= 1 and not goto_table[node][c] do
      node = fail_table[node]
    end
    local next_node = goto_table[node][c]
    if next_node then node = next_node end
    if output_table[node] then return true end
  end
  return false
end

-- Replace all occurrences.
-- replacements: table {[pattern]=replacement} or function(pattern, start) -> string
--: (self: { ... }, text: string, replacements: unknown) -> string
function Automaton:replace(text, replacements)
  -- Collect all matches, sorted by start then by length (longest first for overlaps).
  local matches = self:search(text)
  if #matches == 0 then return text end

  -- Build a non-overlapping greedy replacement pass (left to right, longest match wins).
  -- First, bucket matches by start position.
  local by_start = {}
  for _, m in ipairs(matches) do
    local s = m[1]
    if not by_start[s] then by_start[s] = {} end
    local bucket = by_start[s]
    bucket[#bucket + 1] = m
  end

  local parts = {}
  local pos = 1
  local n = #text
  local i = 1
  while i <= n do
    local bucket = by_start[i]
    if bucket then
      -- Pick longest match at this position
      local best = nil
      for _, m in ipairs(bucket) do
        if best == nil or #m[2] > #best[2] then best = m end
      end
      -- Append text before this match
      if i > pos then
        parts[#parts + 1] = sub(text, pos, i - 1)
      end
      -- Compute replacement
      local rep
      local t = type(replacements)
      if t == "function" then
        rep = replacements(best[2], best[1])
      else
        rep = replacements[best[2]]
        if rep == nil then rep = best[2] end
      end
      parts[#parts + 1] = rep
      pos = i + #best[2]
      i = pos
    else
      i = i + 1
    end
  end
  if pos <= n then
    parts[#parts + 1] = sub(text, pos, n)
  end
  return concat(parts)
end

-- Return a copy of the patterns list.
function Automaton:patterns()
  local out = {}
  for i, p in ipairs(self._patterns) do out[i] = p end
  return out
end

-- Return the number of patterns.
function Automaton:count()
  return #self._patterns
end

-- ---------------------------------------------------------------------------
-- Constructor
-- ---------------------------------------------------------------------------

-- Build an automaton from a list of patterns.
-- Returns automaton or (nil, errmsg).
--: (patterns: { [integer]: string }) -> ({ ... } | nil, string | nil)
function M.new(patterns)
  if type(patterns) ~= "table" or #patterns == 0 then
    return nil, "aho_corasick.new: patterns must be a non-empty array"
  end
  for i, p in ipairs(patterns) do
    if type(p) ~= "string" then
      return nil, "aho_corasick.new: pattern " .. tostring(i) .. " is not a string"
    end
    if p == "" then
      return nil, "aho_corasick.new: empty pattern at index " .. tostring(i)
    end
  end

  local gt, ft, ot = build(patterns)
  local auto = setmetatable({
    _goto    = gt,
    _fail    = ft,
    _output  = ot,
    _patterns = patterns,
  }, Automaton)
  return auto
end

return M
