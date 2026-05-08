-- lib/suffix_array/init.lua
-- Suffix array with LCP array for O(m log n) pattern search.
-- Construction: O(n log n) prefix-doubling (Manber-Myers).
-- LCP: O(n) Kasai's algorithm.
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Internal: build suffix array via O(n log n) prefix doubling
-- ---------------------------------------------------------------------------

--: (string) -> integer[]
local function build_sa(s)
  local n = #s
  if n == 0 then return {} end

  local sa = {}
  local rank = {}
  local tmp = {}

  for i = 1, n do
    sa[i] = i
    rank[i] = string.byte(s, i)
  end

  local k = 1
  while k < n do
    -- Sort by (rank[i], rank[i+k]) pairs
    table.sort(sa, function(a, b)
      if rank[a] ~= rank[b] then return rank[a] < rank[b] end
      local ra = a + k <= n and rank[a + k] or -1
      local rb = b + k <= n and rank[b + k] or -1
      return ra < rb
    end)
    -- Update ranks
    tmp[sa[1]] = 1
    for i = 2, n do
      local same = rank[sa[i]] == rank[sa[i - 1]]
      if same then
        local ra = sa[i] + k <= n and rank[sa[i] + k] or -1
        local rb = sa[i - 1] + k <= n and rank[sa[i - 1] + k] or -1
        same = (ra == rb)
      end
      tmp[sa[i]] = tmp[sa[i - 1]] + (same and 0 or 1)
    end
    -- Check if all ranks are unique
    if tmp[sa[n]] == n then
      for i = 1, n do rank[i] = tmp[i] end
      break
    end
    for i = 1, n do rank[i] = tmp[i] end
    k = k * 2
  end

  return sa
end

-- ---------------------------------------------------------------------------
-- Internal: build LCP array via Kasai's O(n) algorithm
-- ---------------------------------------------------------------------------

--: (string, integer[]) -> integer[]
local function build_lcp(s, sa)
  local n = #s
  if n == 0 then return {} end

  -- Inverse SA: rank[pos] = index in sa
  local rank = {}
  for i = 1, n do rank[sa[i]] = i end

  local lcp = {}
  local h = 0
  for i = 1, n do
    if rank[i] > 1 then
      local j = sa[rank[i] - 1]
      while i + h <= n and j + h <= n and
            string.byte(s, i + h) == string.byte(s, j + h) do
        h = h + 1
      end
      lcp[rank[i]] = h
      if h > 0 then h = h - 1 end
    else
      lcp[rank[i]] = 0
    end
  end
  lcp[1] = 0  -- convention
  return lcp
end

-- ---------------------------------------------------------------------------
-- Internal: binary-search helpers
-- ---------------------------------------------------------------------------

-- Compare s[sa_i .. sa_i+#p-1] with pattern p.
-- Returns -1 if suffix-prefix < p, 1 if > p, 0 if equal.
--: (string, integer, string, integer) -> integer
local function cmp_suffix_prefix(s, sa_i, p, plen)
  local slen = #s
  for k = 0, plen - 1 do
    local pos = sa_i + k
    if pos > slen then
      -- Suffix is shorter than pattern: suffix < pattern
      return -1
    end
    local sc = string.byte(s, pos)
    local pc = string.byte(p, k + 1)
    if sc ~= pc then
      return sc < pc and -1 or 1
    end
  end
  return 0
end

-- Lower bound: smallest index in [1,n] where cmp >= 0 (suffix >= p as prefix)
--: (string, integer[], integer, string, integer) -> integer
local function lower_bound(s, sa, n, p, plen)
  local lo, hi = 1, n + 1
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if cmp_suffix_prefix(s, sa[mid], p, plen) < 0 then
      lo = mid + 1
    else
      hi = mid
    end
  end
  return lo
end

-- Upper bound: smallest index in [1,n] where cmp > 0 (suffix > p as prefix)
--: (string, integer[], integer, string, integer) -> integer
local function upper_bound(s, sa, n, p, plen)
  local lo, hi = 1, n + 1
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if cmp_suffix_prefix(s, sa[mid], p, plen) <= 0 then
      lo = mid + 1
    else
      hi = mid
    end
  end
  return lo
end

-- ---------------------------------------------------------------------------
-- Suffix array object
-- ---------------------------------------------------------------------------

--:: SuffixArray = {
--::   _s: string, _n: integer, _sa: integer[], _lcp: integer[] | nil,
--::   array: (self: SuffixArray) -> integer[],
--::   lcp: (self: SuffixArray) -> integer[],
--::   str: (self: SuffixArray) -> string,
--::   len: (self: SuffixArray) -> integer,
--::   search: (self: SuffixArray, p: string) -> integer[],
--::   count: (self: SuffixArray, p: string) -> integer,
--::   find: (self: SuffixArray, p: string) -> integer | nil,
--::   contains: (self: SuffixArray, p: string) -> boolean,
--::   longest_repeated: (self: SuffixArray) -> string,
--:: }
local SA = {}
SA.__index = SA

--- Return the raw suffix array (1-indexed positions).
--: (self: SuffixArray) -> integer[]
function SA:array()
  return self._sa
end

--- Return the LCP array (1-indexed, lcp[1] = 0 by convention).
--: (self: SuffixArray) -> integer[]
function SA:lcp()
  if not self._lcp then
    self._lcp = build_lcp(self._s, self._sa)
  end
  return self._lcp
end

--- Return the original string.
--: (self: SuffixArray) -> string
function SA:str()
  return self._s
end

--- Return the number of suffixes (= #s).
--: (self: SuffixArray) -> integer
function SA:len()
  return self._n
end

--- Search for all occurrences of pattern p. Returns sorted 1-indexed positions.
--: (self: SuffixArray, p: string) -> integer[]
function SA:search(p)
  local plen = #p
  local s, sa, n = self._s, self._sa, self._n
  if plen == 0 then
    -- Empty pattern matches every position
    local result = {}
    for i = 1, n do result[i] = i end
    table.sort(result)
    return result
  end
  if plen > n then return {} end

  local lo = lower_bound(s, sa, n, p, plen)
  local hi = upper_bound(s, sa, n, p, plen)

  local result = {}
  for i = lo, hi - 1 do
    result[#result + 1] = sa[i]
  end
  table.sort(result)
  return result
end

--- Count occurrences of pattern p.
--: (self: SuffixArray, p: string) -> integer
function SA:count(p)
  local plen = #p
  local s, sa, n = self._s, self._sa, self._n
  if plen == 0 then return n end
  if plen > n then return 0 end

  local lo = lower_bound(s, sa, n, p, plen)
  local hi = upper_bound(s, sa, n, p, plen)
  return hi - lo
end

--- Find the first occurrence of pattern p (leftmost in string), or nil.
--: (self: SuffixArray, p: string) -> integer | nil
function SA:find(p)
  local matches = self:search(p)
  return matches[1]
end

--- Check if pattern p occurs at least once.
--: (self: SuffixArray, p: string) -> boolean
function SA:contains(p)
  local plen = #p
  local s, sa, n = self._s, self._sa, self._n
  if plen == 0 then return n > 0 end
  if plen > n then return false end

  local lo = lower_bound(s, sa, n, p, plen)
  if lo > n then return false end
  return cmp_suffix_prefix(s, sa[lo], p, plen) == 0
end

--- Return the longest repeated substring.
--: (self: SuffixArray) -> string
function SA:longest_repeated()
  local lcp = self:lcp()
  local s = self._s
  local best_len, best_pos = 0, 1
  for i = 2, self._n do
    if lcp[i] > best_len then
      best_len = lcp[i]
      best_pos = self._sa[i]
    end
  end
  if best_len == 0 then return "" end
  return s:sub(best_pos, best_pos + best_len - 1)
end

-- ---------------------------------------------------------------------------
-- Public constructor
-- ---------------------------------------------------------------------------

--- Build a suffix array for string s.
--: (string) -> SuffixArray
function M.new(s)
  local sa = build_sa(s)
  local obj = setmetatable({
    _s  = s,
    _n  = #s,
    _sa = sa,
    _lcp = nil,  -- lazy
  }, SA)
  return obj
end

-- ---------------------------------------------------------------------------
-- Static: longest common substring of two strings
-- ---------------------------------------------------------------------------

--- Return the longest common substring of s1 and s2.
--- Uses the concatenation trick: build SA on s1 + '\0' + s2.
--: (string, string) -> string
function M.lcs_str(s1, s2)
  if #s1 == 0 or #s2 == 0 then return "" end
  local sep = "\0"
  local combined = s1 .. sep .. s2
  local n1 = #s1
  -- Build SA + LCP on combined string
  local sa_obj = M.new(combined)
  local sa   = sa_obj:array()
  local lcp  = sa_obj:lcp()
  local n    = sa_obj:len()

  -- A suffix is "from s1" if its start position <= n1,
  -- "from s2" if its start position > n1 + 1 (skip the separator).
  -- Also, a valid substring must not contain the separator ('\0'),
  -- which means the LCP must not extend past the separator boundary.
  -- The LCP from Kasai naturally handles this because '\0' < any real char,
  -- so two suffixes from different parts will stop at the separator.

  local best_len, best_pos = 0, 1
  for i = 2, n do
    local l = lcp[i]
    if l > 0 then
      local a = sa[i]
      local b = sa[i - 1]
      -- Must come from different halves and the LCP must not cross separator
      local a_in_s1 = a <= n1
      local b_in_s1 = b <= n1
      if a_in_s1 ~= b_in_s1 then
        -- The LCP cannot exceed the distance from either start to the separator
        local max_a = a_in_s1 and (n1 - a + 1) or (#s2 - (a - n1 - 2))
        local max_b = b_in_s1 and (n1 - b + 1) or (#s2 - (b - n1 - 2))
        local valid_len = math.min(l, max_a, max_b)
        if valid_len > best_len then
          best_len = valid_len
          best_pos = a_in_s1 and a or b
        end
      end
    end
  end

  if best_len == 0 then return "" end
  return s1:sub(best_pos, best_pos + best_len - 1)
end

return M
