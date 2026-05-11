-- lib/vigenere/init.lua
-- Classical cipher suite: Vigenère, Caesar, Atbash, ROT13, Playfair, Beaufort,
-- Auto-key Vigenère, and key analysis tools (Kasiski, Friedman, chi-squared).
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local byte, char, sub, upper, lower, format = string.byte, string.char, string.sub, string.upper, string.lower, string.format
local floor, abs, sqrt = math.floor, math.abs, math.sqrt
local concat, insert, sort = table.concat, table.insert, table.sort

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Returns only alphabetic characters, uppercased, as an array of 0-based indices (A=0..Z=25).
local function to_alpha_indices(text)
  local out = {}
  for i = 1, #text do
    local b = byte(text, i)
    if b >= 65 and b <= 90 then       -- A-Z
      out[#out + 1] = b - 65
    elseif b >= 97 and b <= 122 then  -- a-z
      out[#out + 1] = b - 97
    end
  end
  return out
end

-- Reconstruct a string from indices, preserving non-alpha characters from original
-- if opts.preserve is true.
local function from_indices(indices, original, preserve)
  if not preserve then
    local t = {}
    for i = 1, #indices do t[i] = char(indices[i] + 65) end
    return concat(t)
  end
  -- Weave alpha results back into original with non-alpha chars preserved.
  local t = {}
  local ai = 1
  for i = 1, #original do
    local b = byte(original, i)
    if (b >= 65 and b <= 90) or (b >= 97 and b <= 122) then
      t[#t + 1] = char(indices[ai] + 65)
      ai = ai + 1
    else
      t[#t + 1] = char(b)
    end
  end
  return concat(t)
end

-- ---------------------------------------------------------------------------
-- Caesar cipher
-- ---------------------------------------------------------------------------

function M.caesar_encrypt(text, shift, opts)
  shift = shift % 26
  local indices = to_alpha_indices(text)
  for i = 1, #indices do
    indices[i] = (indices[i] + shift) % 26
  end
  return from_indices(indices, text, opts and opts.preserve)
end

function M.caesar_decrypt(text, shift, opts)
  return M.caesar_encrypt(text, -shift, opts)
end

-- ---------------------------------------------------------------------------
-- ROT13
-- ---------------------------------------------------------------------------

function M.rot13(text, opts)
  return M.caesar_encrypt(text, 13, opts)
end

-- ---------------------------------------------------------------------------
-- Atbash (A↔Z, B↔Y, ...)
-- ---------------------------------------------------------------------------

function M.atbash(text, opts)
  local indices = to_alpha_indices(text)
  for i = 1, #indices do
    indices[i] = 25 - indices[i]
  end
  return from_indices(indices, text, opts and opts.preserve)
end

-- ---------------------------------------------------------------------------
-- Vigenère cipher
-- ---------------------------------------------------------------------------

function M.vigenere_encrypt(text, key, opts)
  local pi = to_alpha_indices(text)
  local ki = to_alpha_indices(key)
  if #ki == 0 then return nil, "key must contain at least one letter" end
  local klen = #ki
  for i = 1, #pi do
    pi[i] = (pi[i] + ki[((i - 1) % klen) + 1]) % 26
  end
  return from_indices(pi, text, opts and opts.preserve)
end

function M.vigenere_decrypt(text, key, opts)
  local ci = to_alpha_indices(text)
  local ki = to_alpha_indices(key)
  if #ki == 0 then return nil, "key must contain at least one letter" end
  local klen = #ki
  for i = 1, #ci do
    ci[i] = (ci[i] - ki[((i - 1) % klen) + 1] + 26) % 26
  end
  return from_indices(ci, text, opts and opts.preserve)
end

-- ---------------------------------------------------------------------------
-- Beaufort cipher  C = (K - P) mod 26  (self-reciprocal)
-- ---------------------------------------------------------------------------

function M.beaufort_encrypt(text, key, opts)
  local pi = to_alpha_indices(text)
  local ki = to_alpha_indices(key)
  if #ki == 0 then return nil, "key must contain at least one letter" end
  local klen = #ki
  for i = 1, #pi do
    pi[i] = (ki[((i - 1) % klen) + 1] - pi[i] + 26) % 26
  end
  return from_indices(pi, text, opts and opts.preserve)
end

-- Beaufort is self-reciprocal: decrypt == encrypt
M.beaufort_decrypt = M.beaufort_encrypt

-- ---------------------------------------------------------------------------
-- Auto-key Vigenère (key extended with plaintext)
-- ---------------------------------------------------------------------------

function M.autokey_encrypt(text, key, opts)
  local pi = to_alpha_indices(text)
  local ki = to_alpha_indices(key)
  if #ki == 0 then return nil, "key must contain at least one letter" end
  -- Build full running key: ki then pi (but only as many pi as needed)
  local ci = {}
  for i = 1, #pi do
    local k
    if i <= #ki then
      k = ki[i]
    else
      k = pi[i - #ki]
    end
    ci[i] = (pi[i] + k) % 26
  end
  return from_indices(ci, text, opts and opts.preserve)
end

function M.autokey_decrypt(text, key, opts)
  local ci = to_alpha_indices(text)
  local ki = to_alpha_indices(key)
  if #ki == 0 then return nil, "key must contain at least one letter" end
  local pi = {}
  for i = 1, #ci do
    local k
    if i <= #ki then
      k = ki[i]
    else
      k = pi[i - #ki]
    end
    pi[i] = (ci[i] - k + 26) % 26
  end
  return from_indices(pi, text, opts and opts.preserve)
end

-- ---------------------------------------------------------------------------
-- Playfair cipher
-- ---------------------------------------------------------------------------

-- Build 5x5 key square. J is merged with I.
local function playfair_square(key)
  local seen = {}
  local sq = {}
  -- Add key letters first, then remaining alphabet
  local combined = upper(key) .. "ABCDEFGHIKLMNOPQRSTUVWXYZ"  -- no J
  for i = 1, #combined do
    local b0 = byte(combined, i)
    if b0 ~= nil then
      local b = b0 == 74 and 73 or b0
      if b >= 65 and b <= 90 and not seen[b] then
        seen[b] = true
        sq[#sq + 1] = b - 65  -- store as 0-based index
      end
    end
  end
  -- Build lookup: letter → {row, col}
  local pos = {}
  for i = 1, 25 do
    local r = floor((i - 1) / 5)
    local c = (i - 1) % 5
    pos[sq[i]] = { r, c }
  end
  return sq, pos
end

-- Prepare plaintext: uppercase, no J, digraphs with X padding
--: (text: string) -> unknown
local function playfair_prepare(text)
  local letters = {}
  for i = 1, #text do
    local b0 = byte(text, i) or 0
    if b0 >= 65 and b0 <= 90 then
      local b = b0 == 74 and 73 or b0
      letters[#letters + 1] = b - 65
    elseif b0 >= 97 and b0 <= 122 then
      local b1 = b0 - 32
      local b = b1 == 74 and 73 or b1
      letters[#letters + 1] = b - 65
    end
  end
  -- Insert X between repeated letters in a pair
  --: Arr<{ [integer]: integer }>
  local digraphs = {}
  local i = 1
  while i <= #letters do
    local a = letters[i]
    local b2 = letters[i + 1]
    if b2 == nil then
      -- Pad last single letter with X
      digraphs[#digraphs + 1] = { a, 23 }  -- X = 23
      i = i + 1
    elseif a == b2 then
      -- Same pair: insert X as second of this digraph
      digraphs[#digraphs + 1] = { a, 23 }
      i = i + 1
    else
      digraphs[#digraphs + 1] = { a, b2 }
      i = i + 2
    end
  end
  return digraphs
end

function M.playfair_encrypt(text, key)
  local sq, pos = playfair_square(key)
  local digraphs = playfair_prepare(text)
  local result = {}
  for _, pair in ipairs(digraphs) do
    local a, b2 = pair[1], pair[2]
    local pa, pb = pos[a], pos[b2]
    local ra, ca = pa[1], pa[2]
    local rb, cb = pb[1], pb[2]
    local ea, eb
    if ra == rb then
      -- Same row: shift right
      ea = sq[ra * 5 + (ca + 1) % 5 + 1]
      eb = sq[rb * 5 + (cb + 1) % 5 + 1]
    elseif ca == cb then
      -- Same col: shift down
      ea = sq[((ra + 1) % 5) * 5 + ca + 1]
      eb = sq[((rb + 1) % 5) * 5 + cb + 1]
    else
      -- Rectangle: swap columns
      ea = sq[ra * 5 + cb + 1]
      eb = sq[rb * 5 + ca + 1]
    end
    result[#result + 1] = char(ea + 65)
    result[#result + 1] = char(eb + 65)
  end
  return concat(result)
end

--: (text: string, key: string) -> string
function M.playfair_decrypt(text, key)
  local sq, pos = playfair_square(key)
  -- Build digraphs from ciphertext directly (no X insertion needed for decrypt)
  local ci = {}
  for i = 1, #text do
    local b = byte(text, i) or 0
    if b >= 65 and b <= 90 then
      ci[#ci + 1] = b - 65
    elseif b >= 97 and b <= 122 then
      ci[#ci + 1] = b - 97
    end
  end
  local result = {}
  local i = 1
  while i <= #ci - 1 do
    local a, b2 = ci[i], ci[i + 1]
    local pa, pb = pos[a], pos[b2]
    local ra, ca = pa[1], pa[2]
    local rb, cb = pb[1], pb[2]
    local da, db
    if ra == rb then
      -- Same row: shift left
      da = sq[ra * 5 + (ca + 4) % 5 + 1]
      db = sq[rb * 5 + (cb + 4) % 5 + 1]
    elseif ca == cb then
      -- Same col: shift up
      da = sq[((ra + 4) % 5) * 5 + ca + 1]
      db = sq[((rb + 4) % 5) * 5 + cb + 1]
    else
      -- Rectangle: swap columns
      da = sq[ra * 5 + cb + 1]
      db = sq[rb * 5 + ca + 1]
    end
    result[#result + 1] = char(da + 65)
    result[#result + 1] = char(db + 65)
    i = i + 2
  end
  return concat(result)
end

-- ---------------------------------------------------------------------------
-- Frequency analysis
-- ---------------------------------------------------------------------------

-- English letter frequencies (A-Z), from standard tables.
local ENGLISH_FREQ = {
  0.08167, 0.01492, 0.02782, 0.04253, 0.12702, 0.02228, 0.02015,
  0.06094, 0.06966, 0.00153, 0.00772, 0.04025, 0.02406, 0.06749,
  0.07507, 0.01929, 0.00095, 0.05987, 0.06327, 0.09056, 0.02758,
  0.00978, 0.02360, 0.00150, 0.01974, 0.00074,
}

-- Returns {a=count, b=count, ...} for all 26 letters (lowercase keys).
--: (text: string) -> { [string]: integer }
function M.letter_frequencies(text)
  --: { [string]: integer }
  local counts = {}
  for i = 0, 25 do counts[char(i + 97)] = 0 end
  for i = 1, #text do
    local b = byte(text, i) or 0
    if b >= 65 and b <= 90 then
      local k = char(b + 32)
      counts[k] = counts[k] + 1
    elseif b >= 97 and b <= 122 then
      local k = char(b)
      counts[k] = counts[k] + 1
    end
  end
  return counts
end

-- Chi-squared statistic: lower = better fit to expected distribution.
-- expected: optional table {a=freq, b=freq, ...} (relative frequencies summing to 1).
-- Defaults to English letter frequencies.
--: (text: string, expected: { [string]: number } | nil) -> number
function M.chi_squared(text, expected)
  local counts = M.letter_frequencies(text)
  --: integer
  local total = 0
  for i = 0, 25 do total = total + (counts[char(i + 97)] or 0) end
  if total == 0 then return 0 end
  --: number
  local chi = 0
  for i = 0, 25 do
    local lc = char(i + 97)
    local observed = counts[lc]
    local from_user = expected and expected[lc] or nil
    local exp_freq = from_user or ENGLISH_FREQ[i + 1] or 0
    local expected_count = (exp_freq or 0) * total
    if expected_count > 0 then
      chi = chi + ((observed or 0) - expected_count) ^ 2 / expected_count
    end
  end
  return chi
end

-- ---------------------------------------------------------------------------
-- Index of Coincidence
-- ---------------------------------------------------------------------------

-- IC ≈ 0.065 for English, ≈ 0.038 for random uniform text.
function M.index_of_coincidence(text)
  local counts = M.letter_frequencies(text)
  local n = 0
  for i = 0, 25 do n = n + counts[char(i + 97)] end
  if n <= 1 then return 0 end
  local sum = 0
  for i = 0, 25 do
    local f = counts[char(i + 97)]
    sum = sum + f * (f - 1)
  end
  return sum / (n * (n - 1))
end

-- ---------------------------------------------------------------------------
-- Friedman test: estimate key length from IC
-- ---------------------------------------------------------------------------

function M.friedman_test(ciphertext)
  local ic = M.index_of_coincidence(ciphertext)
  local indices = to_alpha_indices(ciphertext)
  local n = #indices
  if n <= 1 or ic <= 0.038 then return 1 end
  -- Formula: key_len ≈ (0.0265*N) / ((N-1)*IC - 0.038*N + 0.065)
  local denom = (n - 1) * ic - 0.038 * n + 0.065
  if denom <= 0 then return 1 end
  return (0.0265 * n) / denom
end

-- ---------------------------------------------------------------------------
-- Kasiski test: find repeated trigrams/tetragrams, rank key length candidates
-- ---------------------------------------------------------------------------

-- Returns array of {len=k, score=s} sorted by score descending.
function M.kasiski_test(ciphertext, opts)
  local max_keylen = (opts and opts.max_keylen) or 20
  local indices = to_alpha_indices(ciphertext)
  local text_upper = ""
  for i = 1, #indices do text_upper = text_upper .. char(indices[i] + 65) end

  local n = #text_upper
  -- Find all repeated n-grams of length 3 and 4, record distances
  local distances = {}
  for nglen = 3, 4 do
    --: { [string]: Arr<integer> }
    local positions = {}
    for i = 1, n - nglen + 1 do
      local s = sub(text_upper, i, i + nglen - 1)
      if not positions[s] then
        positions[s] = {}
      end
      insert(positions[s], i)
    end
    for _, pos_list in pairs(positions) do
      if #pos_list >= 2 then
        for i = 1, #pos_list - 1 do
          for j = i + 1, #pos_list do
            distances[#distances + 1] = pos_list[j] - pos_list[i]
          end
        end
      end
    end
  end

  -- Count factor occurrences for each candidate key length 2..max_keylen
  --: { [integer]: integer }
  local factor_count = {}
  for k = 2, max_keylen do factor_count[k] = 0 end
  for _, d in ipairs(distances) do
    for k = 2, max_keylen do
      if d % k == 0 then
        factor_count[k] = factor_count[k] + 1
      end
    end
  end

  -- Build result sorted by score
  local result = {}
  for k = 2, max_keylen do
    result[#result + 1] = { len = k, score = factor_count[k] }
  end
  sort(result, function(a, b) return a.score > b.score end)
  return result
end

-- ---------------------------------------------------------------------------
-- Crack Caesar via chi-squared
-- ---------------------------------------------------------------------------

-- Returns best {shift, plaintext, score} (lowest chi-squared).
function M.crack_caesar(ciphertext)
  local best_shift, best_plain, best_score = 0, "", math.huge
  for shift = 0, 25 do
    local plain = M.caesar_decrypt(ciphertext, shift)
    local score = M.chi_squared(plain)
    if score < best_score then
      best_score = score
      best_shift = shift
      best_plain = plain
    end
  end
  return { shift = best_shift, plaintext = best_plain, score = best_score }
end

-- ---------------------------------------------------------------------------
-- Crack Vigenère key length candidates
-- ---------------------------------------------------------------------------

-- Top 5 candidate key lengths via average IC of cosets.
-- Returns array of {len=k, score=ic} sorted by score descending (higher IC = more likely).
function M.crack_vigenere_keylen(ciphertext, max_len)
  max_len = max_len or 20
  local indices = to_alpha_indices(ciphertext)
  local n = #indices
  --: Arr<{ len: integer, score: number }>
  local results = {}
  for k = 1, max_len do
    -- Split into k cosets
    --: { [integer]: Arr<integer> }
    local cosets = {}
    for j = 1, k do cosets[j] = {} end
    for i = 1, n do
      local j = ((i - 1) % k) + 1
      insert(cosets[j], indices[i])
    end
    -- Average IC across cosets
    --: number
    local total_ic = 0
    for j = 1, k do
      local coset = cosets[j]
      local m = #coset
      if m <= 1 then
        total_ic = total_ic + 0
      else
        --: { [integer]: integer }
        local freq = {}
        for fi = 0, 25 do freq[fi] = 0 end
        for _, v in ipairs(coset) do freq[v] = freq[v] + 1 end
        local ic_sum = 0.0
        for fi = 0, 25 do ic_sum = ic_sum + freq[fi] * (freq[fi] - 1) end
        total_ic = total_ic + ic_sum / (m * (m - 1))
      end
    end
    results[#results + 1] = { len = k, score = total_ic / k }
  end
  sort(results --[[: unknown]], function(a, b) return a.score > b.score end)
  -- Return top 5
  local top = {}
  for i = 1, math.min(5, #results) do top[i] = results[i] end
  return top
end

-- ---------------------------------------------------------------------------
-- Crack Vigenère key given key length
-- ---------------------------------------------------------------------------

-- For each coset, find best Caesar shift via chi-squared.
-- Returns {key=string, plaintext=string}.
function M.crack_vigenere(ciphertext, key_length)
  local indices = to_alpha_indices(ciphertext)
  local n = #indices
  local key_indices = {}
  for k = 1, key_length do
    -- Build coset k
    local coset_chars = {}
    for i = k, n, key_length do
      coset_chars[#coset_chars + 1] = char(indices[i] + 65)
    end
    local coset_str = concat(coset_chars)
    -- Find best shift
    local best_shift, best_score = 0, math.huge
    for shift = 0, 25 do
      local plain = M.caesar_decrypt(coset_str, shift)
      local score = M.chi_squared(plain)
      if score < best_score then
        best_score = score
        best_shift = shift
      end
    end
    key_indices[k] = best_shift
  end
  -- Build key string
  local key_chars = {}
  for k = 1, key_length do key_chars[k] = char(key_indices[k] + 65) end
  local key = concat(key_chars)
  local plaintext = M.vigenere_decrypt(ciphertext, key)
  return { key = key, plaintext = plaintext }
end

return M
