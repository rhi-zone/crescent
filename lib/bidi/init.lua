-- Unicode Bidirectional Algorithm (UAX #9) — pure Lua implementation.
--
-- Classification data scope (bounded subset, NOT the full 1.1M-codepoint
-- DerivedBidiClass.txt):
--
--   Covered ranges (per-codepoint classification from Unicode 17.0
--   DerivedBidiClass.txt, cross-checked against @missing block defaults):
--     - ASCII + Latin-1 Supplement (U+0000-U+00FF)
--     - Hebrew block (U+0590-U+05FF): R default, NSM for combining marks
--     - Arabic block (U+0600-U+06FF): AL default, with AN/EN/ET/CS/ON/NSM
--     - Arabic Supplement (U+0750-U+077F): AL
--     - General Punctuation (U+2000-U+206F): WS/ON/ET/CS/B/BN + explicit
--       format characters (LRE U+202A, RLE U+202B, PDF U+202C, LRO U+202D,
--       RLO U+202E, LRI U+2066, RLI U+2067, FSI U+2068, PDI U+2069)
--     - Currency Symbols (U+20A0-U+20CF): ET
--     - Mathematical Operators (U+2200-U+22FF): ON, with U+2212 ES, U+2213 ET
--     - Hebrew Presentation Forms (U+FB1D-U+FB4F): R, FB1E NSM, FB29 ES
--     - Arabic Presentation Forms-A (U+FB50-U+FDFF): AL, with ON/BN exceptions
--     - Arabic Presentation Forms-B (U+FE70-U+FEFF): AL, FEFF BN
--   Digit ranges:
--     - Arabic-Indic digits (U+0660-U+0669): AN (per UCD)
--     - Extended Arabic-Indic digits (U+06F0-U+06F9): EN (per UCD; NOT AN)
--   Default for uncovered codepoints: L (UCD @missing: 0000..10FFFF; Left_To_Right)
--
-- N0 (paired bracket resolution) is NOT implemented. Brackets in
-- mixed-direction text are resolved by N1-N2 (surrounding strong type or
-- embedding direction), which is correct for most cases but may produce
-- visually awkward bracket directionality in edge cases. N0 requires
-- BidiBrackets.txt data and a stack-based pairing algorithm — meaningful
-- additional scope.
--
-- The algorithm itself is fully general UAX #9 (P2-P3, X1-X8, X9,
-- BD13/X10 isolating run sequences, W1-W7, N1-N2, I1-I2, L1-L2).
-- L3 (combining mark reordering) and L4 (mirrored-glyph substitution)
-- are not implemented: this module reorders codepoints, not display glyphs.

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

-- Explicit bidi control characters plus zero-width/format characters.
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

-- Range table: { lo, hi, type }, sorted ascending by lo, binary-searched.
--:: bidi_range = { integer, integer, bidi_type }
local RANGES = {} --: { [integer]: bidi_range }
--: (integer, integer, bidi_type) -> nil
local function add_range(lo, hi, t) RANGES[#RANGES + 1] = { lo, hi, t } end

-- Latin-1 Supplement (U+0080-U+00FF)
add_range(0x0080, 0x0084, "BN")
add_range(0x0085, 0x0085, "B")   -- NEL (Next Line)
add_range(0x0086, 0x009F, "BN")
add_range(0x00A0, 0x00A0, "CS")  -- NBSP
add_range(0x00A1, 0x00A1, "ON")
add_range(0x00A2, 0x00A5, "ET")
add_range(0x00A6, 0x00A9, "ON")
add_range(0x00AB, 0x00AC, "ON")
add_range(0x00AD, 0x00AD, "BN")  -- soft hyphen
add_range(0x00AE, 0x00AF, "ON")
add_range(0x00B0, 0x00B1, "ET")
add_range(0x00B2, 0x00B3, "EN")
add_range(0x00B4, 0x00B4, "ON")
add_range(0x00B6, 0x00B8, "ON")
add_range(0x00B9, 0x00B9, "EN")
add_range(0x00BB, 0x00BF, "ON")
add_range(0x00D7, 0x00D7, "ON")  -- multiplication sign
add_range(0x00F7, 0x00F7, "ON")  -- division sign

-- Hebrew (U+0590-U+05FF): block default R per @missing
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
add_range(0x05C8, 0x05FF, "R")   -- unassigned default to R per block @missing

-- Arabic (U+0600-U+06FF): block default AL per @missing
add_range(0x0600, 0x0605, "AN")  -- Arabic number sign, etc.
add_range(0x0606, 0x0607, "ON")
add_range(0x0608, 0x0608, "AL")
add_range(0x0609, 0x060A, "ET")
add_range(0x060B, 0x060B, "AL")  -- Afghani sign
add_range(0x060C, 0x060C, "CS")  -- Arabic comma
add_range(0x060D, 0x060D, "AL")  -- Arabic date separator
add_range(0x060E, 0x060F, "ON")
add_range(0x0610, 0x061A, "NSM")
add_range(0x061B, 0x061B, "AL")  -- Arabic semicolon
-- 0x061C in CONTROLS table (AL)
add_range(0x061D, 0x061F, "AL")  -- Arabic end of text mark, question/triple dot
add_range(0x0620, 0x063F, "AL")
add_range(0x0640, 0x064A, "AL")  -- tatweel + letters
add_range(0x064B, 0x065F, "NSM")
add_range(0x0660, 0x0669, "AN")  -- Arabic-Indic digits
add_range(0x066A, 0x066A, "ET")  -- Arabic percent sign
add_range(0x066B, 0x066C, "AN")  -- Arabic decimal/thousands separator
add_range(0x066D, 0x066D, "AL")  -- Arabic five pointed star
add_range(0x066E, 0x066F, "AL")
add_range(0x0670, 0x0670, "NSM")
add_range(0x0671, 0x06D5, "AL")
add_range(0x06D6, 0x06DC, "NSM")
add_range(0x06DD, 0x06DD, "AN")  -- Arabic end of ayah
add_range(0x06DE, 0x06DE, "ON")
add_range(0x06DF, 0x06E4, "NSM")
add_range(0x06E5, 0x06E6, "AL")
add_range(0x06E7, 0x06E8, "NSM")
add_range(0x06E9, 0x06E9, "ON")
add_range(0x06EA, 0x06ED, "NSM")
add_range(0x06EE, 0x06EF, "AL")
add_range(0x06F0, 0x06F9, "EN")  -- Extended Arabic-Indic digits (EN per UCD, not AN)
add_range(0x06FA, 0x06FF, "AL")

-- Arabic Supplement (U+0750-U+077F): block default AL per @missing
add_range(0x0750, 0x077F, "AL")

-- General Punctuation (U+2000-U+206F): handled partly by CONTROLS table
add_range(0x2000, 0x200A, "WS")  -- spaces
-- 200B-200D, 200E, 200F in CONTROLS
add_range(0x2010, 0x2027, "ON")  -- dashes, quotes, daggers, etc.
-- 2028, 2029, 202A-202E in CONTROLS
add_range(0x202F, 0x202F, "CS")  -- narrow no-break space
add_range(0x2030, 0x2034, "ET")  -- per mille, prime marks
add_range(0x2035, 0x2043, "ON")  -- reversed prime, misc
add_range(0x2044, 0x2044, "CS")  -- fraction slash
add_range(0x2045, 0x205E, "ON")  -- brackets, misc punctuation
add_range(0x205F, 0x205F, "WS")  -- medium mathematical space
add_range(0x2060, 0x2065, "BN")  -- word joiner, invisible operators
-- 2066-2069 in CONTROLS
add_range(0x206A, 0x206F, "BN")  -- deprecated formatting chars

-- Currency Symbols (U+20A0-U+20CF): all ET per @missing
add_range(0x20A0, 0x20CF, "ET")

-- Mathematical Operators (U+2200-U+22FF)
add_range(0x2200, 0x2211, "ON")
add_range(0x2212, 0x2212, "ES")  -- minus sign
add_range(0x2213, 0x2213, "ET")  -- minus-or-plus sign
add_range(0x2214, 0x22FF, "ON")

-- Hebrew Presentation Forms (U+FB1D-U+FB4F): block default R per @missing
add_range(0xFB1D, 0xFB1D, "R")
add_range(0xFB1E, 0xFB1E, "NSM") -- Hebrew point judeo-spanish varika
add_range(0xFB1F, 0xFB28, "R")
add_range(0xFB29, 0xFB29, "ES")  -- Hebrew letter alternative plus sign
add_range(0xFB2A, 0xFB4F, "R")

-- Arabic Presentation Forms-A (U+FB50-U+FDFF): block default AL per @missing
add_range(0xFB50, 0xFBC2, "AL")
add_range(0xFBC3, 0xFBD2, "ON")  -- unassigned
add_range(0xFBD3, 0xFD3D, "AL")
add_range(0xFD3E, 0xFD4F, "ON")  -- ornate parens + unassigned
add_range(0xFD50, 0xFD8F, "AL")
add_range(0xFD90, 0xFD91, "ON")  -- unassigned
add_range(0xFD92, 0xFDC7, "AL")
add_range(0xFDC8, 0xFDCF, "ON")  -- unassigned
add_range(0xFDD0, 0xFDEF, "BN")  -- noncharacters
add_range(0xFDF0, 0xFDFC, "AL")
add_range(0xFDFD, 0xFDFF, "ON")

-- Arabic Presentation Forms-B (U+FE70-U+FEFF): block default AL per @missing
add_range(0xFE70, 0xFEFE, "AL")
-- 0xFEFF in CONTROLS (BN)

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

--- Return the bidi character class for a single Unicode codepoint.
-- Covers the bounded subset documented in the file header; returns "L"
-- for any codepoint outside the covered ranges.
--: (number) -> (bidi_type | nil, string | nil)
M.classify_codepoint = function(cp)
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

--: (bidi_type[], integer, string) -> integer
local function paragraph_level(types, n, base_direction)
  if base_direction == "ltr" then return 0 end
  if base_direction == "rtl" then return 1 end
  -- "auto" (default): P2-P3
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
-- level_run: start/stop are positions into the filtered array.
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
  -- initiator/PDI; sos if at the start of the sequence.
  for k = 1, m do
    if get(k) == "NSM" then
      if k == 1 then
        set(k, seq.sos)
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
-- L2: REORDER
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

-- ============================================================
-- INTERNAL: full resolve pipeline
-- ============================================================

--:: bidi_result = {
--::   codepoints: { [integer]: integer },
--::   types: { [integer]: bidi_type },
--::   levels: { [integer]: integer },
--::   paragraph_level: integer,
--:: }

--: (string | { [integer]: integer }, { base_direction?: string } | nil) -> (bidi_result | nil, string | nil)
local function resolve_impl(input, opts)
  local cps, err = codepoints_from_input(input)
  if not cps then return nil, err end
  local n = #cps

  local orig_types = {} --: { [integer]: bidi_type }
  for i = 1, n do
    local t, terr = M.classify_codepoint(cps[i])
    if not t then return nil, terr end
    orig_types[i] = t
  end

  local base_direction = opts and opts.base_direction or "auto"
  local para_lvl = paragraph_level(orig_types, n, base_direction)

  -- types[] is mutated in place by override resolution and by W/N rules;
  -- orig_types[] is kept untouched for L1.
  local types = {} --: { [integer]: bidi_type }
  for i = 1, n do types[i] = orig_types[i] end

  local expl = resolve_explicit(types, n, para_lvl)

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
    local sequences = isolating_run_sequences(filtered, n_filtered, runs, expl, types, para_lvl)
    for _, seq in ipairs(sequences) do
      resolve_sequence(seq, filtered, types)
    end
  end

  -- Reassemble full-length levels array: retained chars get their
  -- resolved level; removed chars get the level of the nearest
  -- preceding retained character (X9 reconstruction), or para_level if
  -- none precedes.
  local levels = {} --: { [integer]: integer }
  local last_level = para_lvl
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
    if orig_types[i] == "B" or orig_types[i] == "S" then levels[i] = para_lvl end
  end
  local in_ws_run = true
  for i = n, 1, -1 do
    local ot = orig_types[i]
    if ot == "B" or ot == "S" then
      in_ws_run = true
    elseif RESETTABLE[ot] or expl.removed[i] then
      if in_ws_run then levels[i] = para_lvl end
    else
      in_ws_run = false
    end
  end

  return { codepoints = cps, types = orig_types, levels = levels, paragraph_level = para_lvl }
end

-- ============================================================
-- PUBLIC API
-- ============================================================

--- Resolve per-codepoint embedding levels for a UTF-8 paragraph.
-- The entire input is treated as one paragraph; callers should split at
-- paragraph boundaries (bidi class B) if processing multi-paragraph text.
--
-- opts.base_direction: "auto" (default, P2-P3 first-strong detection) |
--                      "ltr" (force paragraph level 0) |
--                      "rtl" (force paragraph level 1)
--
-- Returns a table with:
--   codepoints:      integer array of decoded codepoints
--   types:           original bidi type per codepoint (before algorithm mutations)
--   levels:          integer array of resolved embedding levels (1-indexed)
--   paragraph_level: the paragraph embedding level (0 or 1)
-- On invalid UTF-8 or input: (nil, errmsg)
--: (string | { [integer]: integer }, { base_direction?: string } | nil) -> (bidi_result | nil, string | nil)
M.resolve_levels = function(input, opts)
  return resolve_impl(input, opts)
end

--- Reorder a string or codepoint array according to resolved levels (L2).
-- Takes the input in logical order and the levels from resolve_levels.
-- Returns the visually reordered form (string if input was string,
-- codepoint array if input was array).
-- On error: (nil, errmsg)
--: (string | { [integer]: integer }, { [integer]: integer }) -> (string | { [integer]: integer } | nil, string | nil)
M.reorder = function(input, levels)
  if type(input) == "string" then
    local cps, err = codepoints_from_input(input)
    if not cps then return nil, err end
    if #cps ~= #levels then return nil, "levels length must match codepoint count" end
    local out = reorder_codepoints(cps, levels)
    local parts = {} --: { [integer]: string }
    for i = 1, #out do parts[i] = utf8.char(out[i]) end
    return table.concat(parts), nil
  elseif type(input) == "table" then
    if #input ~= #levels then return nil, "levels length must match codepoint count" end
    return reorder_codepoints(input, levels), nil
  end
  return nil, "input must be a string or codepoint array"
end

--- Reorder a UTF-8 string into visual (display) order.
-- Combines resolve_levels + reorder (L2) in one call.
-- Returns the visually reordered UTF-8 string.
-- On invalid input: (nil, errmsg)
--: (string, { base_direction?: string } | nil) -> (string | nil, string | nil)
M.reorder_to_visual = function(text, opts)
  local result, err = resolve_impl(text, opts)
  if not result then return nil, err end
  local reordered, rerr = M.reorder(text, result.levels)
  if not reordered then return nil, rerr end
  if type(reordered) ~= "string" then return nil, "unexpected reorder result type" end
  return reordered, nil
end

--- Return visual-order runs with original codepoint index ranges.
-- Each run is {start=int, stop=int, level=int} where start/stop are
-- 1-based codepoint indices in the original string's codepoint sequence.
-- Runs are listed in visual (display) order. Within each run, characters
-- appear in logical order if level is even (LTR) or reversed if odd (RTL).
-- On invalid input: (nil, errmsg)
--: (string, { base_direction?: string } | nil) -> ({ [integer]: { start: integer, stop: integer, level: integer } } | nil, string | nil)
M.visual_runs = function(text, opts)
  local result, err = resolve_impl(text, opts)
  if not result then return nil, err end

  local levels = result.levels
  local n = #result.codepoints
  if n == 0 then return {} end

  -- Copy levels and build index map for L2
  local lvl = {} --: { [integer]: integer }
  local idx = {} --: { [integer]: integer }
  for i = 1, n do lvl[i] = levels[i]; idx[i] = i end

  -- L2 reversal on idx + lvl
  local max_lev = 0
  local min_odd_lev = nil --: integer | nil
  for i = 1, n do
    local l = lvl[i]
    if l > max_lev then max_lev = l end
    if l % 2 == 1 then min_odd_lev = min_of_optional(min_odd_lev, l) end
  end

  if min_odd_lev then
    for level = max_lev, min_odd_lev, -1 do
      local i = 1
      while i <= n do
        if lvl[i] >= level then
          local j = i
          while j + 1 <= n and lvl[j + 1] >= level do j = j + 1 end
          local lo, hi = i, j
          while lo < hi do
            idx[lo], idx[hi] = idx[hi], idx[lo]
            lvl[lo], lvl[hi] = lvl[hi], lvl[lo]
            lo = lo + 1; hi = hi - 1
          end
          i = j + 1
        else
          i = i + 1
        end
      end
    end
  end

  -- Extract runs of same level in visual order
  local runs_out = {} --: { [integer]: { start: integer, stop: integer, level: integer } }
  local run_start = 1
  for i = 2, n + 1 do
    if i > n or lvl[i] ~= lvl[run_start] then
      local lo_idx = idx[run_start]
      local hi_idx = idx[run_start]
      for j = run_start + 1, i - 1 do
        if idx[j] < lo_idx then lo_idx = idx[j] end
        if idx[j] > hi_idx then hi_idx = idx[j] end
      end
      runs_out[#runs_out + 1] = { start = lo_idx, stop = hi_idx, level = lvl[run_start] }
      run_start = i
    end
  end

  return runs_out
end

return M
