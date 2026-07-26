-- Unicode Bidirectional Algorithm (UAX #9).
--
-- Scope: a BOUNDED character classification table (not the full
-- DerivedBidiClass.txt) covering ASCII, Latin-1 Supplement, Hebrew,
-- Arabic, common General Punctuation, and the explicit bidi control
-- characters. Unknown codepoints default to L (safe fallback for
-- scripts outside this table's coverage — Latin-script text using them
-- still reorders correctly since L is the common case).
--
-- Implements: P2-P3 (paragraph level), X1-X8 (explicit levels, via the
-- "removal" strategy documented in UAX#9 5.2 rather than the "retaining"
-- strategy — explicit formatting characters and BN are dropped before
-- W/N/I and their levels are reconstructed afterward from the nearest
-- preceding retained character, which UAX#9 explicitly sanctions as
-- conformant), BD13/X10 (isolating run sequences), W1-W7 (weak types),
-- N1-N2 (neutral types; N0 bracket-pair resolution is NOT implemented —
-- out of scope for v1 per design brief, neutrals inside bracket pairs
-- fall through to N1/N2 like any other neutral run), I1-I2 (implicit
-- levels), L1-L2 (reordering). L3 (combining mark reordering) and L4
-- (mirrored-glyph substitution) are NOT implemented: this module
-- reorders codepoints, it does not select display glyphs.

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local utf8 = require("lib.encode.utf8")

local M = {}
M._tier = "pure"

--:: bidi_type = "L" | "R" | "AL" | "EN" | "ES" | "ET" | "AN" | "CS" | "NSM" | "BN" | "B" | "S" | "WS" | "ON" | "LRE" | "LRO" | "RLE" | "RLO" | "PDF" | "LRI" | "RLI" | "FSI" | "PDI"

-- ============================================================
-- CHARACTER CLASSIFICATION (bounded table)
-- ============================================================

-- ASCII (U+0000-U+007F): direct array lookup, index 0..127.
local ASCII = {} --: { [integer]: bidi_type }
for cp = 0x00, 0x08 do ASCII[cp] = "BN" end
ASCII[0x09] = "S"
ASCII[0x0A] = "B"
ASCII[0x0B] = "S"
ASCII[0x0C] = "WS"
ASCII[0x0D] = "B"
for cp = 0x0E, 0x1B do ASCII[cp] = "BN" end
for cp = 0x1C, 0x1E do ASCII[cp] = "B" end
ASCII[0x1F] = "S"
ASCII[0x20] = "WS"
ASCII[0x21] = "ON"; ASCII[0x22] = "ON"
ASCII[0x23] = "ET"; ASCII[0x24] = "ET"; ASCII[0x25] = "ET"
for cp = 0x26, 0x2A do ASCII[cp] = "ON" end
ASCII[0x2B] = "ES"
ASCII[0x2C] = "CS"
ASCII[0x2D] = "ES"
ASCII[0x2E] = "CS"
ASCII[0x2F] = "CS"
for cp = 0x30, 0x39 do ASCII[cp] = "EN" end
ASCII[0x3A] = "CS"
for cp = 0x3B, 0x40 do ASCII[cp] = "ON" end
for cp = 0x41, 0x5A do ASCII[cp] = "L" end
for cp = 0x5B, 0x60 do ASCII[cp] = "ON" end
for cp = 0x61, 0x7A do ASCII[cp] = "L" end
for cp = 0x7B, 0x7E do ASCII[cp] = "ON" end
ASCII[0x7F] = "BN"

-- Explicit bidi control characters (scattered codepoints, not a single
-- contiguous block) plus a handful of zero-width/format characters
-- commonly seen alongside them.
local CONTROLS = { --: { [integer]: bidi_type }
  [0x061C] = "AL",  -- ALM: Arabic Letter Mark
  [0x200B] = "BN",  -- ZWSP
  [0x200C] = "BN",  -- ZWNJ
  [0x200D] = "BN",  -- ZWJ
  [0x200E] = "L",   -- LRM
  [0x200F] = "R",   -- RLM
  [0x202A] = "LRE",
  [0x202B] = "RLE",
  [0x202C] = "PDF",
  [0x202D] = "LRO",
  [0x202E] = "RLO",
  [0x2028] = "WS",  -- LINE SEPARATOR
  [0x2029] = "B",   -- PARAGRAPH SEPARATOR
  [0x2066] = "LRI",
  [0x2067] = "RLI",
  [0x2068] = "FSI",
  [0x2069] = "PDI",
  [0xFEFF] = "BN",  -- ZERO WIDTH NO-BREAK SPACE / BOM
}

-- Range table for everything else, sorted ascending by lo, checked via
-- binary search. Each entry is { lo, hi, type }.
--:: bidi_range = { integer, integer, bidi_type }
local RANGES = {} --: { [integer]: bidi_range }
--: (integer, integer, bidi_type) -> nil
local function add_range(lo, hi, t) RANGES[#RANGES + 1] = { lo, hi, t } end

-- Latin-1 Supplement (U+0080-U+00FF): mostly L, per the design brief.
add_range(0x0080, 0x009F, "BN") -- C1 controls
add_range(0x00A0, 0x00A0, "CS") -- NBSP
add_range(0x00A1, 0x00A1, "ON")
add_range(0x00A2, 0x00A5, "ET")
add_range(0x00A6, 0x00A9, "ON")
add_range(0x00AB, 0x00AC, "ON")
add_range(0x00AD, 0x00AD, "BN") -- soft hyphen
add_range(0x00AE, 0x00AF, "ON")
add_range(0x00B0, 0x00B1, "ET")
add_range(0x00B2, 0x00B3, "EN")
add_range(0x00B4, 0x00B4, "ON")
add_range(0x00B6, 0x00B8, "ON")
add_range(0x00B9, 0x00B9, "EN")
add_range(0x00BB, 0x00BF, "ON")
add_range(0x00D7, 0x00D7, "ON") -- multiplication sign
add_range(0x00F7, 0x00F7, "ON") -- division sign

-- General Punctuation (common subset: spaces, dashes, quotes).
add_range(0x2000, 0x200A, "WS")
add_range(0x2010, 0x2015, "ON") -- hyphens/dashes
add_range(0x2016, 0x2017, "ON")
add_range(0x2018, 0x201F, "ON") -- quotation marks
add_range(0x2020, 0x2027, "ON")
add_range(0x2030, 0x2034, "ET") -- per mille etc
add_range(0x2039, 0x203A, "ON")
add_range(0x2032, 0x2034, "ET")

-- Hebrew (U+0590-U+05FF): R, with a subrange of NSM combining points.
add_range(0x0590, 0x0590, "R")
add_range(0x0591, 0x05BD, "NSM")
add_range(0x05BE, 0x05BE, "R")
add_range(0x05BF, 0x05BF, "NSM")
add_range(0x05C0, 0x05C0, "R")
add_range(0x05C1, 0x05C2, "NSM")
add_range(0x05C3, 0x05C3, "R")
add_range(0x05C4, 0x05C5, "NSM")
add_range(0x05C6, 0x05C6, "R")
add_range(0x05C7, 0x05C7, "NSM")
add_range(0x05C8, 0x05FF, "R")

-- Arabic (U+0600-U+06FF): AL for letters, AN for Arabic-Indic digits,
-- EN for Extended Arabic-Indic digits, NSM for diacritics.
add_range(0x0600, 0x0605, "AN")
add_range(0x0606, 0x0607, "ON")
add_range(0x0608, 0x0608, "AL")
add_range(0x0609, 0x060A, "ET")
add_range(0x060B, 0x060B, "AL")
add_range(0x060C, 0x060D, "CS")
add_range(0x060E, 0x060F, "ON")
add_range(0x0610, 0x061A, "NSM")
add_range(0x061B, 0x061B, "ON")
-- 0x061C handled in CONTROLS
add_range(0x061D, 0x061F, "ON")
add_range(0x0620, 0x063A, "AL")
add_range(0x0640, 0x064A, "AL")
add_range(0x064B, 0x065F, "NSM")
add_range(0x0660, 0x0669, "AN")
add_range(0x066A, 0x066A, "ET")
add_range(0x066B, 0x066C, "AN")
add_range(0x066D, 0x066D, "ON")
add_range(0x066E, 0x066F, "AL")
add_range(0x0670, 0x0670, "NSM")
add_range(0x0671, 0x06D3, "AL")
add_range(0x06D4, 0x06D5, "AL")
add_range(0x06D6, 0x06DC, "NSM")
add_range(0x06DD, 0x06DD, "AN")
add_range(0x06DE, 0x06DE, "ON")
add_range(0x06DF, 0x06E4, "NSM")
add_range(0x06E5, 0x06E6, "AL")
add_range(0x06E7, 0x06E8, "NSM")
add_range(0x06E9, 0x06E9, "ON")
add_range(0x06EA, 0x06ED, "NSM")
add_range(0x06EE, 0x06EF, "AL")
add_range(0x06F0, 0x06F9, "EN") -- Extended Arabic-Indic digits
add_range(0x06FA, 0x06FF, "AL")

table.sort(RANGES, function(a, b) return a[1] < b[1] end)

--: (integer) -> bidi_type | nil
local function range_lookup(cp)
  local lo, hi = 1, #RANGES
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local r = RANGES[mid]
    if cp < r[1] then hi = mid - 1
    elseif cp > r[2] then lo = mid + 1
    else return r[3] end
  end
  return nil
end

--: (number) -> (bidi_type | nil, string | nil)
M.char_type = function(cp)
  local n = math.floor(cp)
  if cp < 0 or cp ~= n then return nil, "invalid codepoint" end
  if n <= 0x7F then return ASCII[n] or "L" end
  local ctrl = CONTROLS[n]
  if ctrl then return ctrl end
  return range_lookup(n) or "L"
end

-- ============================================================
-- INPUT NORMALIZATION
-- ============================================================

--: (string | { [integer]: integer }) -> ({ [integer]: integer } | nil, string | nil)
local function codepoints_from_input(input)
  if type(input) == "table" then return input end
  if type(input) ~= "string" then return nil, "input must be a string or codepoint array" end
  if not utf8.is_valid(input) then return nil, "invalid UTF-8 input" end
  local cps = {} --: { [integer]: integer }
  for _, cp in utf8.codes(input) do
    if cp then cps[#cps + 1] = cp end
  end
  return cps
end

-- ============================================================
-- P2-P3: PARAGRAPH EMBEDDING LEVEL
-- ============================================================

local ISOLATE_INIT = { LRI = true, RLI = true, FSI = true } --: { [string]: boolean }

--: (bidi_type[], integer, integer) -> integer | nil
local function find_matching_pdi(types, i, n)
  local depth = 1
  for j = i + 1, n do
    local t = types[j]
    if ISOLATE_INIT[t] then depth = depth + 1
    elseif t == "PDI" then
      depth = depth - 1
      if depth == 0 then return j end
    end
  end
  return nil
end

-- Scan [from, to] for the first strong type (L, AL, R), skipping
-- isolate content per P2. Returns "L" or "R"; defaults to "L" (P3) if
-- no strong character is found.
--: (bidi_type[], integer, integer) -> "L" | "R"
local function first_strong_direction(types, from, to)
  local i = from
  while i <= to do
    local t = types[i]
    if t == "L" then return "L"
    elseif t == "AL" or t == "R" then return "R"
    elseif ISOLATE_INIT[t] then
      local j = find_matching_pdi(types, i, to)
      if j then i = j + 1 else return "L" end
    else
      i = i + 1
    end
  end
  return "L"
end

--: (bidi_type[], integer) -> integer
local function paragraph_level(types, n)
  local dir = first_strong_direction(types, 1, n)
  return dir == "R" and 1 or 0
end

-- ============================================================
-- X1-X8: EXPLICIT LEVELS (removal strategy, UAX#9 5.2)
-- ============================================================

local MAX_DEPTH = 125

--: (integer) -> integer
local function next_odd(level) return (level % 2 == 0) and (level + 1) or (level + 2) end
--: (integer) -> integer
local function next_even(level) return (level % 2 == 0) and (level + 2) or (level + 1) end

--:: explicit_result = {
--::   levels: { [integer]: integer },
--::   removed: { [integer]: boolean },
--::   match_pdi: { [integer]: integer },
--::   match_init: { [integer]: integer },
--:: }

--: (bidi_type[], integer, integer) -> explicit_result
local function resolve_explicit(types, n, para_level)
  local levels = {} --: { [integer]: integer }
  local removed = {} --: { [integer]: boolean }
  local match_pdi = {} --: { [integer]: integer }
  local match_init = {} --: { [integer]: integer }

  --:: stack_entry = { level: integer, override: bidi_type | nil, isolate: boolean, char_index: integer }
  local stack = {} --: { [integer]: stack_entry }
  stack[1] = { level = para_level, override = nil, isolate = false, char_index = 0 }
  local overflow_isolate = 0
  local overflow_embedding = 0
  local valid_isolate = 0

  for i = 1, n do
    local t = types[i]
    local top = stack[#stack]

    if t == "RLE" or t == "LRE" or t == "RLO" or t == "LRO" then
      levels[i] = top.level
      removed[i] = true
      local new_level = (t == "RLE" or t == "RLO") and next_odd(top.level) or next_even(top.level)
      if new_level <= MAX_DEPTH and overflow_isolate == 0 and overflow_embedding == 0 then
        local ov = nil --: bidi_type | nil
        if t == "RLO" then ov = "R" elseif t == "LRO" then ov = "L" end
        stack[#stack + 1] = { level = new_level, override = ov, isolate = false, char_index = i }
      elseif overflow_isolate == 0 then
        overflow_embedding = overflow_embedding + 1
      end
    elseif t == "RLI" or t == "LRI" or t == "FSI" then
      levels[i] = top.level
      if top.override then types[i] = top.override end
      local dir = t == "RLI" and "R" or (t == "LRI" and "L" or nil)
      if dir == nil then
        local j = find_matching_pdi(types, i, n)
        dir = first_strong_direction(types, i + 1, j and (j - 1) or n)
      end
      local new_level = (dir == "R") and next_odd(top.level) or next_even(top.level)
      if new_level <= MAX_DEPTH and overflow_isolate == 0 and overflow_embedding == 0 then
        valid_isolate = valid_isolate + 1
        stack[#stack + 1] = { level = new_level, override = nil, isolate = true, char_index = i }
      else
        overflow_isolate = overflow_isolate + 1
      end
    elseif t == "PDF" then
      levels[i] = top.level
      removed[i] = true
      if overflow_isolate > 0 then
        -- matches an overflow isolate initiator: no-op
      elseif overflow_embedding > 0 then
        overflow_embedding = overflow_embedding - 1
      elseif (not top.isolate) and #stack > 1 then
        table.remove(stack)
      end
    elseif t == "PDI" then
      if overflow_isolate > 0 then
        overflow_isolate = overflow_isolate - 1
      elseif valid_isolate > 0 then
        overflow_embedding = 0
        while stack[#stack].isolate == false do table.remove(stack) end
        local closed = stack[#stack]
        match_init[closed.char_index] = i
        match_pdi[i] = closed.char_index
        table.remove(stack)
        valid_isolate = valid_isolate - 1
      end
      top = stack[#stack]
      levels[i] = top.level
      if top.override then types[i] = top.override end
    elseif t == "B" then
      levels[i] = para_level
      stack = {}
      stack[1] = { level = para_level, override = nil, isolate = false, char_index = 0 }
      overflow_isolate = 0
      overflow_embedding = 0
      valid_isolate = 0
    else
      levels[i] = top.level
      if top.override then types[i] = top.override end
      if t == "BN" then removed[i] = true end
    end
  end

  return { levels = levels, removed = removed, match_pdi = match_pdi, match_init = match_init }
end

-- ============================================================
-- BD13/X10: ISOLATING RUN SEQUENCES
-- ============================================================

--:: filtered_item = { orig: integer, level: integer }
-- level_run: start/stop are positions into the filtered array (not original codepoint indices).
--:: level_run = { start: integer, stop: integer, level: integer }
--:: run_sequence = { runs: level_run[], level: integer, sos: "L" | "R", eos: "L" | "R" }

--: (filtered_item[], integer) -> level_run[]
local function level_runs(filtered, n_filtered)
  local runs = {} --: level_run[]
  local i = 1
  while i <= n_filtered do
    local lvl = filtered[i].level
    local j = i
    while j + 1 <= n_filtered and filtered[j + 1].level == lvl do j = j + 1 end
    runs[#runs + 1] = { start = i, stop = j, level = lvl }
    i = j + 1
  end
  return runs
end

--: (filtered_item[], integer, level_run[], explicit_result, bidi_type[], integer) -> run_sequence[]
local function isolating_run_sequences(filtered, n_filtered, runs, expl, types, para_level)
  -- Maps: orig index of a run's first char -> run index.
  local run_for_start_orig = {} --: { [integer]: integer }
  for ri, r in ipairs(runs) do
    run_for_start_orig[filtered[r.start].orig] = ri
  end

  local consumed = {} --: { [integer]: boolean }
  local sequences = {} --: run_sequence[]

  for ri, r in ipairs(runs) do
    local first_orig = filtered[r.start].orig
    local starts_with_matched_pdi = types[first_orig] == "PDI" and expl.match_init[first_orig] ~= nil
    if not consumed[ri] and not starts_with_matched_pdi then
      local seq_runs = { r } --[[: level_run[] ]]
      consumed[ri] = true
      local cur = r
      while true do
        local last_orig = filtered[cur.stop].orig
        if ISOLATE_INIT[types[last_orig]] and expl.match_pdi[last_orig] then
          local next_ri = run_for_start_orig[expl.match_pdi[last_orig]]
          if next_ri and not consumed[next_ri] then
            local nr = runs[next_ri]
            seq_runs[#seq_runs + 1] = nr
            consumed[next_ri] = true
            cur = nr
          else
            break
          end
        else
          break
        end
      end

      local seq_level = r.level
      local first_run = seq_runs[1]
      local last_run = seq_runs[#seq_runs]

      local before_level = para_level
      if first_run.start > 1 then before_level = filtered[first_run.start - 1].level end
      local sos = (math.max(seq_level, before_level) % 2 == 1) and "R" or "L"

      local last_orig2 = filtered[last_run.stop].orig
      local ends_unmatched_isolate = ISOLATE_INIT[types[last_orig2]] and not expl.match_pdi[last_orig2]
      local after_level
      if ends_unmatched_isolate then
        after_level = para_level
      elseif last_run.stop < n_filtered then
        after_level = filtered[last_run.stop + 1].level
      else
        after_level = para_level
      end
      local eos = (math.max(seq_level, after_level) % 2 == 1) and "R" or "L"

      sequences[#sequences + 1] = { runs = seq_runs, level = seq_level, sos = sos, eos = eos }
    end
  end

  return sequences
end

-- ============================================================
-- W1-W7, N1-N2, I1-I2 (applied per isolating run sequence)
-- ============================================================

local NI = { B = true, S = true, WS = true, ON = true, FSI = true, LRI = true, RLI = true, PDI = true } --: { [string]: boolean }

--: (run_sequence, filtered_item[], bidi_type[]) -> nil
local function resolve_sequence(seq, filtered, types)
  -- Materialize the sequence as a flat list of filtered-array positions.
  local positions = {} --: { [integer]: integer }
  for _, r in ipairs(seq.runs) do
    for p = r.start, r.stop do positions[#positions + 1] = p end
  end
  local m = #positions

  --: (integer) -> bidi_type
  local function get(k)
    if k < 1 then return seq.sos end
    if k > m then return seq.eos end
    return types[filtered[positions[k]].orig]
  end
  --: (integer, bidi_type) -> nil
  local function set(k, t) types[filtered[positions[k]].orig] = t end

  -- W1: NSM -> type of previous char; ON if previous is isolate
  -- initiator/PDI, or if at the start of the sequence.
  for k = 1, m do
    if get(k) == "NSM" then
      if k == 1 then
        set(k, "ON")
      else
        local prev = get(k - 1)
        if prev == "LRI" or prev == "RLI" or prev == "FSI" or prev == "PDI" then
          set(k, "ON")
        else
          set(k, prev)
        end
      end
    end
  end

  -- W2: EN -> AN if the nearest preceding strong type is AL.
  do
    local strong = seq.sos
    for k = 1, m do
      local t = get(k)
      if t == "L" or t == "R" or t == "AL" then
        strong = t
      elseif t == "EN" and strong == "AL" then
        set(k, "AN")
      end
    end
  end

  -- W3: AL -> R.
  for k = 1, m do
    if get(k) == "AL" then set(k, "R") end
  end

  -- W4: single ES between two EN -> EN; single CS between two same-type
  -- (EN..EN or AN..AN) -> that type.
  for k = 2, m - 1 do
    local t = get(k)
    if t == "ES" then
      if get(k - 1) == "EN" and get(k + 1) == "EN" then set(k, "EN") end
    elseif t == "CS" then
      local p, nx = get(k - 1), get(k + 1)
      if p == "EN" and nx == "EN" then set(k, "EN")
      elseif p == "AN" and nx == "AN" then set(k, "AN") end
    end
  end

  -- W5: a run of ET adjacent to EN (on either side) becomes EN.
  do
    local k = 1
    while k <= m do
      if get(k) == "ET" then
        local j = k
        while j <= m and get(j) == "ET" do j = j + 1 end
        -- run is [k, j-1]
        if get(k - 1) == "EN" or get(j) == "EN" then
          for p = k, j - 1 do set(p, "EN") end
        end
        k = j
      else
        k = k + 1
      end
    end
  end

  -- W6: remaining ES, ET, CS -> ON.
  for k = 1, m do
    local t = get(k)
    if t == "ES" or t == "ET" or t == "CS" then set(k, "ON") end
  end

  -- W7: EN -> L if the nearest preceding strong type is L.
  do
    local strong = seq.sos
    for k = 1, m do
      local t = get(k)
      if t == "L" or t == "R" then
        strong = t
      elseif t == "EN" and strong == "L" then
        set(k, "L")
      end
    end
  end

  -- N1: a run of NI between two strong types that match (EN/AN count as
  -- R for this purpose) resolves to that type.
  do
    --: (bidi_type) -> "L" | "R"
    local function strong_of(t)
      if t == "L" then return "L" end
      return "R" -- R, EN, AN, and sos/eos (already "L"|"R")
    end
    local k = 1
    while k <= m do
      if NI[get(k)] then
        local j = k
        while j <= m and NI[get(j)] do j = j + 1 end
        -- run is [k, j-1]
        local before = (k == 1) and seq.sos or strong_of(get(k - 1))
        local after = (j > m) and seq.eos or strong_of(get(j))
        if before == after then
          for p = k, j - 1 do set(p, before) end
        end
        k = j
      else
        k = k + 1
      end
    end
  end

  -- N2: any remaining NI -> embedding direction.
  do
    local e = (seq.level % 2 == 1) and "R" or "L"
    for k = 1, m do
      if NI[get(k)] then set(k, e) end
    end
  end

  -- I1/I2: implicit levels.
  for k = 1, m do
    local t = get(k)
    local pos = positions[k]
    local item = filtered[pos]
    if seq.level % 2 == 0 then
      if t == "R" then item.level = item.level + 1
      elseif t == "AN" or t == "EN" then item.level = item.level + 2 end
    else
      if t == "L" or t == "EN" or t == "AN" then item.level = item.level + 1 end
    end
  end
end

-- ============================================================
-- L1: RESET LEVELS ON SEPARATORS AND TRAILING WHITESPACE
-- ============================================================

local RESETTABLE = { WS = true, FSI = true, LRI = true, RLI = true, PDI = true } --: { [string]: boolean }

-- ============================================================
-- PUBLIC API: resolve
-- ============================================================

-- `types` reports each character's ORIGINAL bidi_type from char_type — it
-- is not mutated by directional overrides (X6) or by weak/neutral
-- resolution (W1-W7, N1-N2). Those steps only affect `levels`. Use
-- char_type directly (or re-derive) if the post-override type is needed.
--:: bidi_result = {
--::   codepoints: { [integer]: integer },
--::   types: { [integer]: bidi_type },
--::   levels: { [integer]: integer },
--::   paragraph_level: integer,
--:: }

--: (string | { [integer]: integer }, { base_level?: integer } | nil) -> (bidi_result | nil, string | nil)
M.resolve = function(input, opts)
  local cps, err = codepoints_from_input(input)
  if not cps then return nil, err end
  local n = #cps

  local orig_types = {} --: { [integer]: bidi_type }
  for i = 1, n do
    local t, terr = M.char_type(cps[i])
    if not t then return nil, terr end
    orig_types[i] = t
  end

  local base_level = opts and opts.base_level
  local para_level = base_level or paragraph_level(orig_types, n)

  -- types[] is mutated in place by override resolution and by W/N rules;
  -- orig_types[] is kept untouched for L1.
  local types = {} --: { [integer]: bidi_type }
  for i = 1, n do types[i] = orig_types[i] end

  local expl = resolve_explicit(types, n, para_level)

  -- Build the filtered (non-removed) sequence.
  local filtered = {} --[[: filtered_item[] ]]
  for i = 1, n do
    if not expl.removed[i] then
      filtered[#filtered + 1] = { orig = i, level = expl.levels[i] }
    end
  end
  local n_filtered = #filtered

  if n_filtered > 0 then
    local runs = level_runs(filtered, n_filtered)
    local sequences = isolating_run_sequences(filtered, n_filtered, runs, expl, types, para_level)
    for _, seq in ipairs(sequences) do
      resolve_sequence(seq, filtered, types)
    end
  end

  -- Reassemble full-length levels array: retained chars get their
  -- resolved level; removed chars get the level of the nearest
  -- preceding retained character (X9 reconstruction), or para_level if
  -- none precedes.
  local levels = {} --: { [integer]: integer }
  local last_level = para_level
  local fi = 1
  for i = 1, n do
    if fi <= n_filtered and filtered[fi].orig == i then
      levels[i] = filtered[fi].level
      last_level = filtered[fi].level
      fi = fi + 1
    else
      levels[i] = last_level
    end
  end

  -- L1.
  for i = 1, n do
    if orig_types[i] == "B" or orig_types[i] == "S" then levels[i] = para_level end
  end
  local in_ws_run = true
  for i = n, 1, -1 do
    local ot = orig_types[i]
    if ot == "B" or ot == "S" then
      in_ws_run = true
    elseif RESETTABLE[ot] or expl.removed[i] then
      if in_ws_run then levels[i] = para_level end
    else
      in_ws_run = false
    end
  end

  return { codepoints = cps, types = orig_types, levels = levels, paragraph_level = para_level }
end

-- ============================================================
-- PUBLIC API: reorder (L2)
-- ============================================================

--: (integer | nil, integer) -> integer
local function min_of_optional(current, lvl)
  if current == nil then return lvl end
  if lvl < current then return lvl end
  return current
end

--: ({ [integer]: integer }, { [integer]: integer }) -> { [integer]: integer }
local function reorder_codepoints(cps, levels)
  local n = #cps
  local out = {} --: { [integer]: integer }
  for i = 1, n do out[i] = cps[i] end

  local max_level = 0
  local min_odd = nil --: integer | nil
  for i = 1, n do
    local lvl = levels[i]
    if lvl > max_level then max_level = lvl end
    if lvl % 2 == 1 then min_odd = min_of_optional(min_odd, lvl) end
  end
  if min_odd == nil then return out end

  for level = max_level, min_odd, -1 do
    local i = 1
    while i <= n do
      if levels[i] >= level then
        local j = i
        while j + 1 <= n and levels[j + 1] >= level do j = j + 1 end
        -- reverse out[i..j]
        local lo, hi = i, j
        while lo < hi do
          out[lo], out[hi] = out[hi], out[lo]
          lo = lo + 1
          hi = hi - 1
        end
        i = j + 1
      else
        i = i + 1
      end
    end
  end

  return out
end

--: (string | { [integer]: integer }, { [integer]: integer }) -> (string | { [integer]: integer } | nil, string | nil)
M.reorder = function(input, levels)
  if type(input) == "string" then
    local cps, err = codepoints_from_input(input)
    if not cps then return nil, err end
    if #cps ~= #levels then return nil, "levels length must match codepoint count" end
    local out = reorder_codepoints(cps, levels)
    return utf8.char(unpack(out)), nil
  elseif type(input) == "table" then
    if #input ~= #levels then return nil, "levels length must match codepoint count" end
    return reorder_codepoints(input, levels), nil
  end
  return nil, "input must be a string or codepoint array"
end

-- ============================================================
-- PUBLIC API: convenience combinator
-- ============================================================

-- M.reorder's return type also covers the codepoint-array input case;
-- called here with a string, it always takes the string branch.
--: (string, { base_level?: integer } | nil) -> (string | { [integer]: integer } | nil, string | nil)
M.text_to_visual_order = function(text, opts)
  local result, err = M.resolve(text, opts)
  if not result then return nil, err end
  return M.reorder(text, result.levels)
end

return M
