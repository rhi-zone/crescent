if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Phonetic algorithm library.
-- Implements Soundex, Metaphone, Double Metaphone, and NYSIIS.
-- All algorithms work on ASCII strings; input is uppercased internally.
-- Empty input returns (nil, "empty input").

local M = {}

M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--: (string) -> string
local function upper(s)
  return s:upper()
end

-- Return the byte value of the first character of a string.
local function byte1(s, i)
  return s:byte(i or 1)
end

-- ---------------------------------------------------------------------------
-- Soundex (US National Archives standard)
-- ---------------------------------------------------------------------------

-- Soundex digit table: A=0,E=0,I=0,O=0,U=0,H=0,W=0,Y=0 (ignored)
-- B,F,P,V=1  C,G,J,K,Q,S,X,Z=2  D,T=3  L=4  M,N=5  R=6
local SOUNDEX_TABLE = {
  A=0, E=0, I=0, O=0, U=0, H=0, W=0, Y=0,
  B=1, F=1, P=1, V=1,
  C=2, G=2, J=2, K=2, Q=2, S=2, X=2, Z=2,
  D=3, T=3,
  L=4,
  M=5, N=5,
  R=6,
}

--: (string) -> (string | nil, string | nil)
M.soundex = function(word)
  if not word or word == "" then
    return nil, "empty input"
  end
  local s = upper(word)
  -- Remove non-alpha characters
  s = s:gsub("[^A-Z]", "")
  if s == "" then
    return nil, "empty input"
  end

  local first = s:sub(1, 1)
  local result = { first }
  local prev_code = SOUNDEX_TABLE[first] or 0

  for i = 2, #s do
    local ch = s:sub(i, i)
    local code = SOUNDEX_TABLE[ch]
    if code and code ~= 0 then
      -- Only add if different from previous code (handles adjacent same sounds,
      -- including vowels between same-coded consonants — we track prev_code
      -- ignoring vowels/H/W/Y)
      if code ~= prev_code then
        result[#result + 1] = tostring(code)
        if #result == 4 then break end
      end
      prev_code = code
    elseif code == 0 then
      -- Vowel/H/W/Y: reset separator so next consonant with same code is kept
      -- Standard Soundex: adjacent same codes separated ONLY by H or W are coded once;
      -- separated by a vowel are coded twice. Here we implement the strict standard:
      -- H and W are ignored (don't reset prev_code), vowels (A,E,I,O,U) reset it.
      if ch == "A" or ch == "E" or ch == "I" or ch == "O" or ch == "U" then
        prev_code = -1 -- reset: next consonant always codes
      end
      -- H and W: keep prev_code unchanged (acts as transparent)
    end
  end

  -- Pad with zeros to length 4
  while #result < 4 do
    result[#result + 1] = "0"
  end

  return table.concat(result, ""):sub(1, 4)
end

-- ---------------------------------------------------------------------------
-- Refined Soundex (slightly improved variant)
-- ---------------------------------------------------------------------------

-- Uses a finer-grained digit mapping
local REFINED_TABLE = {
  A=0, E=0, I=0, O=0, U=0,
  B=1, P=1,
  C=3, G=7, J=6, K=3, Q=3, S=4, X=4, Z=5,
  D=2, T=2,
  F=8, V=8,
  H=0, W=0, Y=0,
  L=5,
  M=6, N=6,
  R=7,
}

M.soundex_refined = function(word)
  if not word or word == "" then
    return nil, "empty input"
  end
  local s = upper(word)
  s = s:gsub("[^A-Z]", "")
  if s == "" then
    return nil, "empty input"
  end

  local first = s:sub(1, 1)
  local result = { first }
  local prev_code = REFINED_TABLE[first]
  if prev_code == nil then prev_code = -1 end

  for i = 2, #s do
    local ch = s:sub(i, i)
    local code = REFINED_TABLE[ch]
    if code ~= nil and code ~= 0 then
      if code ~= prev_code then
        result[#result + 1] = tostring(code)
      end
      prev_code = code
    elseif code == 0 then
      prev_code = -1
    end
  end

  -- Pad to 6 characters (refined soundex is longer)
  while #result < 6 do
    result[#result + 1] = "0"
  end

  return table.concat(result, ""):sub(1, 6)
end

-- ---------------------------------------------------------------------------
-- Metaphone (Lawrence Philips, 1990)
-- ---------------------------------------------------------------------------

M.metaphone = function(word)
  if not word or word == "" then
    return nil, "empty input"
  end

  local s = upper(word)
  s = s:gsub("[^A-Z]", "")
  if s == "" then
    return nil, "empty input"
  end

  local len = #s
  local result = {}
  local i = 1 --: integer

  -- Helper: character at position (or "" if out of bounds)
  local function at(pos)
    if pos < 1 or pos > len then return "" end
    return s:sub(pos, pos)
  end

  -- Helper: substring starting at pos
  local function sub(pos, n)
    if pos < 1 or pos > len then return "" end
    return s:sub(pos, pos + (n or 1) - 1)
  end

  -- Drop initial silent letter combinations
  local start2 = sub(1, 2)
  if start2 == "AE" or start2 == "GN" or start2 == "KN" or start2 == "PN" or start2 == "WR" then
    i = 2
  end

  -- Initial vowel maps to "A"
  if i == 1 then
    local first = at(1)
    if first == "A" or first == "E" or first == "I" or first == "O" or first == "U" then
      result[#result + 1] = "A"
      i = 2
    end
  end

  while i <= len do
    local c = at(i)
    local prev = at(i - 1)
    local next1 = at(i + 1)
    local next2 = at(i + 2)
    local next3 = at(i + 3)

    -- Skip duplicate adjacent letters (except C)
    if c ~= "C" and c == prev then
      i = i + 1
      goto continue
    end

    -- Vowels after start are dropped
    if c == "A" or c == "E" or c == "I" or c == "O" or c == "U" then
      i = i + 1
      goto continue
    end

    if c == "B" then
      -- Drop B after M at end
      if prev ~= "M" or i ~= len then
        result[#result + 1] = "B"
      end
      i = i + 1

    elseif c == "C" then
      if next1 == "I" or next1 == "E" or next1 == "Y" then
        if next1 == "I" and next2 == "A" then
          result[#result + 1] = "X" -- CIA → X
        else
          result[#result + 1] = "S"
        end
      elseif sub(i, 2) == "CH" then
        result[#result + 1] = "X"
        i = i + 1
      elseif sub(i, 3) == "CIA" then
        result[#result + 1] = "X"
        i = i + 2
      else
        -- CK → K (skip C)
        if next1 ~= "K" then
          result[#result + 1] = "K"
        end
      end
      i = i + 1

    elseif c == "D" then
      if sub(i, 2) == "DG" and (next2 == "I" or next2 == "E" or next2 == "Y") then
        result[#result + 1] = "J"
        i = i + 2
      else
        result[#result + 1] = "T"
        i = i + 1
      end

    elseif c == "F" then
      result[#result + 1] = "F"
      i = i + 1

    elseif c == "G" then
      if next1 == "H" then
        -- GH: silent at end or before a consonant, or → K
        local after_gh = at(i + 2)
        if i + 1 == len then
          -- GH at end: silent
          i = i + 2
        elseif after_gh ~= "" and after_gh ~= "A" and after_gh ~= "E" and after_gh ~= "I" and after_gh ~= "O" and after_gh ~= "U" then
          -- GH before consonant: silent
          i = i + 2
        else
          result[#result + 1] = "K"
          i = i + 2
        end
      elseif next1 == "N" then
        if i + 1 == len then
          -- GN at end: silent
          i = i + 2
        elseif next2 == "E" and i + 2 == len then
          -- GNED at end: silent
          i = i + 2
        else
          result[#result + 1] = "K"
          i = i + 1
        end
      elseif sub(i, 2) == "GE" or sub(i, 2) == "GI" or sub(i, 2) == "GY" then
        result[#result + 1] = "J"
        i = i + 1
      else
        if prev ~= "G" then
          result[#result + 1] = "K"
        end
        i = i + 1
      end

    elseif c == "H" then
      -- Drop H if after vowel and not before vowel
      if (prev == "A" or prev == "E" or prev == "I" or prev == "O" or prev == "U") and
         next1 ~= "A" and next1 ~= "E" and next1 ~= "I" and next1 ~= "O" and next1 ~= "U" then
        -- silent
      else
        result[#result + 1] = "H"
      end
      i = i + 1

    elseif c == "J" then
      result[#result + 1] = "J"
      i = i + 1

    elseif c == "K" then
      if prev ~= "C" then
        result[#result + 1] = "K"
      end
      i = i + 1

    elseif c == "L" then
      result[#result + 1] = "L"
      i = i + 1

    elseif c == "M" then
      result[#result + 1] = "M"
      i = i + 1

    elseif c == "N" then
      result[#result + 1] = "N"
      i = i + 1

    elseif c == "P" then
      if next1 == "H" then
        result[#result + 1] = "F"
        i = i + 2
      else
        result[#result + 1] = "P"
        i = i + 1
      end

    elseif c == "Q" then
      result[#result + 1] = "K"
      i = i + 1

    elseif c == "R" then
      result[#result + 1] = "R"
      i = i + 1

    elseif c == "S" then
      if sub(i, 2) == "SH" or (sub(i, 3) == "SIO" or sub(i, 3) == "SIA") then
        result[#result + 1] = "X"
        if sub(i, 2) == "SH" then
          i = i + 2
        else
          i = i + 3
        end
      elseif sub(i, 3) == "SCH" then
        result[#result + 1] = "SK"
        i = i + 3
      else
        result[#result + 1] = "S"
        i = i + 1
      end

    elseif c == "T" then
      if sub(i, 2) == "TH" then
        result[#result + 1] = "0"
        i = i + 2
      elseif sub(i, 3) == "TIA" or sub(i, 3) == "TIO" then
        result[#result + 1] = "X"
        i = i + 3
      elseif sub(i, 3) == "TCH" then
        -- drop T in TCH
        i = i + 1
      else
        result[#result + 1] = "T"
        i = i + 1
      end

    elseif c == "V" then
      result[#result + 1] = "F"
      i = i + 1

    elseif c == "W" then
      -- W only codes before a vowel
      if next1 == "A" or next1 == "E" or next1 == "I" or next1 == "O" or next1 == "U" then
        result[#result + 1] = "W"
      end
      i = i + 1

    elseif c == "X" then
      result[#result + 1] = "KS"
      i = i + 1

    elseif c == "Y" then
      -- Y only codes before a vowel
      if next1 == "A" or next1 == "E" or next1 == "I" or next1 == "O" or next1 == "U" then
        result[#result + 1] = "Y"
      end
      i = i + 1

    elseif c == "Z" then
      result[#result + 1] = "S"
      i = i + 1

    else
      i = i + 1
    end

    ::continue::
  end

  -- Collapse adjacent identical output phonemes
  local raw = table.concat(result, "")
  local deduped = {}
  local prev_out = ""
  for k = 1, #raw do
    local ch = raw:sub(k, k)
    if ch ~= prev_out then
      deduped[#deduped + 1] = ch
      prev_out = ch
    end
  end
  return table.concat(deduped, "")
end

-- ---------------------------------------------------------------------------
-- Double Metaphone (Lawrence Philips, 2000)
-- ---------------------------------------------------------------------------

-- Returns primary, secondary phonetic keys.
M.double_metaphone = function(word)
  if not word or word == "" then
    return nil, "empty input"
  end

  local s = upper(word)
  -- Add sentinel spaces for look-behind/look-ahead convenience
  s = s:gsub("[^A-Z]", "")
  if s == "" then
    return nil, "empty input"
  end

  local len = #s
  local pri = {}  -- primary key
  local sec = {}  -- secondary key
  local i = 1 --: integer

  local function at(pos)
    if pos < 1 or pos > len then return "" end
    return s:sub(pos, pos)
  end

  --: (integer, integer | nil) -> string
  local function sub(pos, n)
    if pos < 1 then return "" end
    local nn = (n or 1)
    if pos > len then return "" end
    return s:sub(pos, math.min(pos + nn - 1, len))
  end

  --: (string, string | nil) -> ()
  local function add(p, q)
    pri[#pri + 1] = p
    sec[#sec + 1] = (q ~= nil) and q or p
  end

  -- Check if pos is at start of vowel cluster
  local function is_vowel(pos)
    local c = at(pos)
    return c == "A" or c == "E" or c == "I" or c == "O" or c == "U" or c == "Y"
  end

  -- Helper: check if string s contains substr at pos (1-indexed)
  local function starts_with_at(pos, substr)
    return sub(pos, #substr) == substr
  end

  -- Handle initial special cases
  if starts_with_at(1, "GN") or starts_with_at(1, "KN") or
     starts_with_at(1, "PN") or starts_with_at(1, "AE") or
     starts_with_at(1, "WR") then
    i = 2
  end

  -- Initial vowel → A
  if is_vowel(1) then
    add("A")
    i = 2
  end

  while i <= len do
    local c = at(i)
    local prev = at(i - 1)

    if c == "B" then
      -- Drop B after M at end
      if not (prev == "M" and i == len) then
        add("P")
      end
      i = i + 1

    elseif c == "Ç" then
      add("S")
      i = i + 1

    elseif c == "C" then
      if i > 1 and not is_vowel(i - 1) and starts_with_at(i - 1, "ACH") and
         at(i + 2) ~= "I" and (at(i + 2) ~= "E" or starts_with_at(i - 2, "BACHER") or starts_with_at(i - 2, "MACHER")) then
        add("K")
        i = i + 2
      elseif i == 1 and starts_with_at(i, "CAESAR") then
        add("S")
        i = i + 2
      elseif starts_with_at(i, "CHIA") then
        add("K")
        i = i + 2
      elseif starts_with_at(i, "CH") then
        -- CH: check for various contexts
        if i == 1 and (starts_with_at(i + 2, "AE") or starts_with_at(i + 2, "OE")) then
          -- Greek: K
          add("K")
        else
          -- Germanic or Slavic: K/X
          local is_germanic = starts_with_at(1, "VAN ") or starts_with_at(1, "VON ") or
                              starts_with_at(1, "SCH") or
                              starts_with_at(i - 2, "ORCHES") or
                              starts_with_at(i - 2, "ARCHIT") or
                              starts_with_at(i - 2, "ORCHID") or
                              at(i + 2) == "T" or at(i + 2) == "S" or
                              ((i == 1) and (at(i + 2) == "A" or at(i + 2) == "I" or at(i + 2) == "O" or at(i + 2) == "U"))
          if is_germanic then
            add("K")
          else
            add("X", "K")
          end
        end
        i = i + 2
      elseif starts_with_at(i, "CZ") and not starts_with_at(i - 2, "WICZ") then
        add("S", "X")
        i = i + 2
      elseif starts_with_at(i + 1, "CIA") then
        add("X")
        i = i + 3
      elseif starts_with_at(i, "CC") and not (i == 2 and at(1) == "M") then
        -- CCI/CCE/CCH
        if at(i + 2) == "I" or at(i + 2) == "E" or at(i + 2) == "H" then
          add("X")
          i = i + 3
        else
          add("K")
          i = i + 2
        end
      elseif starts_with_at(i, "CK") or starts_with_at(i, "CG") or starts_with_at(i, "CQ") then
        add("K")
        i = i + 2
      elseif starts_with_at(i, "CI") or starts_with_at(i, "CE") or starts_with_at(i, "CY") then
        -- Italian/French: S vs K
        if starts_with_at(i, "CIO") or starts_with_at(i, "CIE") or starts_with_at(i, "CIA") then
          add("S", "X")
        else
          add("S")
        end
        i = i + 2
      else
        add("K")
        -- Double C (not before I/E)
        if starts_with_at(i + 1, "C") or starts_with_at(i + 1, "Q") or starts_with_at(i + 1, "G") then
          i = i + 2
        else
          i = i + 1
        end
      end

    elseif c == "D" then
      if starts_with_at(i, "DG") then
        if at(i + 2) == "I" or at(i + 2) == "E" or at(i + 2) == "Y" then
          add("J")
          i = i + 3
        else
          add("TK")
          i = i + 2
        end
      elseif starts_with_at(i, "DT") or starts_with_at(i, "DD") then
        add("T")
        i = i + 2
      else
        add("T")
        i = i + 1
      end

    elseif c == "F" then
      if at(i + 1) == "F" then
        i = i + 2
      else
        i = i + 1
      end
      add("F")

    elseif c == "G" then
      if at(i + 1) == "H" then
        if i > 1 and not is_vowel(i - 1) then
          add("K")
          i = i + 2
        elseif i == 1 then
          if at(i + 2) == "I" then
            add("J")
          else
            add("K")
          end
          i = i + 2
        elseif (i > 2 and (at(i - 2) == "B" or at(i - 2) == "H" or at(i - 2) == "D")) or
               (i > 3 and (at(i - 3) == "B" or at(i - 3) == "H" or at(i - 3) == "D")) or
               (i > 4 and (at(i - 4) == "B" or at(i - 4) == "H")) then
          i = i + 2
        else
          if i > 3 and at(i - 1) == "U" and
             (at(i - 3) == "C" or at(i - 3) == "G" or at(i - 3) == "L" or at(i - 3) == "R" or at(i - 3) == "T") then
            add("F")
          elseif i > 1 and at(i - 1) ~= "I" then
            add("K")
          end
          i = i + 2
        end
      elseif at(i + 1) == "N" then
        if i == 2 and is_vowel(1) and not false then -- not slavo-germanic
          add("KN", "N")
        else
          if not starts_with_at(i + 2, "EY") and at(i + 1) ~= "Y" and not false then
            add("N", "KN")
          else
            add("KN")
          end
        end
        i = i + 2
      elseif starts_with_at(i + 1, "LI") and not false then
        add("KL", "L")
        i = i + 2
      elseif i == 1 and (at(i + 1) == "Y" or
          starts_with_at(i + 1, "ES") or starts_with_at(i + 1, "EP") or
          starts_with_at(i + 1, "EB") or starts_with_at(i + 1, "EL") or
          starts_with_at(i + 1, "EY") or starts_with_at(i + 1, "IB") or
          starts_with_at(i + 1, "IL") or starts_with_at(i + 1, "IN") or
          starts_with_at(i + 1, "IE") or starts_with_at(i + 1, "EI") or
          starts_with_at(i + 1, "ER")) then
        add("K", "J")
        i = i + 2
      elseif (starts_with_at(i + 1, "ER") or at(i + 1) == "Y") and
             not (starts_with_at(1, "DANGER") or starts_with_at(1, "RANGER") or starts_with_at(1, "MANGER")) and
             not (at(i - 1) == "E" or at(i - 1) == "I") and
             not (starts_with_at(i - 1, "RGY") or starts_with_at(i - 1, "OGY")) then
        add("K", "J")
        i = i + 2
      elseif at(i + 1) == "E" or at(i + 1) == "I" or at(i + 1) == "Y" or
             starts_with_at(i - 1, "AGGI") or starts_with_at(i - 1, "OGGI") then
        if starts_with_at(1, "VAN ") or starts_with_at(1, "VON ") or starts_with_at(1, "SCH") or
           starts_with_at(i + 1, "ET") then
          add("K")
        else
          if starts_with_at(i + 1, "IER") then
            add("J")
          else
            add("J", "K")
          end
        end
        i = i + 2
      elseif at(i + 1) == "G" then
        add("K")
        i = i + 2
      else
        add("K")
        i = i + 1
      end

    elseif c == "H" then
      if (i == 1 or is_vowel(i - 1)) and is_vowel(i + 1) then
        add("H")
        i = i + 2
      else
        i = i + 1
      end

    elseif c == "J" then
      if starts_with_at(i, "JOSE") or starts_with_at(1, "SAN ") then
        if (i == 1 and at(i + 4) == " ") or starts_with_at(1, "SAN ") then
          add("H")
        else
          add("J", "H")
        end
        i = i + 1
      else
        if i == 1 and not starts_with_at(i, "JOSE") then
          add("J", "A")
        else
          if is_vowel(i - 1) and not false and (at(i + 1) == "A" or at(i + 1) == "O") then
            add("J", "H")
          else
            if i == len then
              add("J", "")
            else
              if at(i + 1) ~= "L" and at(i + 1) ~= "T" and at(i + 1) ~= "K" and
                 at(i + 1) ~= "S" and at(i + 1) ~= "N" and at(i + 1) ~= "M" and
                 at(i + 1) ~= "B" and at(i + 1) ~= "Z" and
                 at(i - 1) ~= "S" and at(i - 1) ~= "K" and at(i - 1) ~= "L" then
                add("J")
              end
            end
          end
        end
        if at(i + 1) == "J" then
          i = i + 2
        else
          i = i + 1
        end
      end

    elseif c == "K" then
      if at(i + 1) == "K" then
        i = i + 2
      else
        i = i + 1
      end
      add("K")

    elseif c == "L" then
      if at(i + 1) == "L" then
        -- Spanish LL
        if (i == len - 1 and
           (starts_with_at(i - 1, "ILLO") or starts_with_at(i - 1, "ILLA") or starts_with_at(i - 1, "ALLE"))) or
           ((starts_with_at(len - 1, "AS") or starts_with_at(len - 1, "OS")) and starts_with_at(i - 1, "ALLE")) then
          add("L", "")
          i = i + 2
        else
          add("L")
          i = i + 2
        end
      else
        add("L")
        i = i + 1
      end

    elseif c == "M" then
      if (starts_with_at(i - 1, "UMB") and (i + 1 == len or starts_with_at(i + 2, "ER"))) or
         at(i + 1) == "M" then
        i = i + 2
      else
        i = i + 1
      end
      add("M")

    elseif c == "N" then
      if at(i + 1) == "N" then
        i = i + 2
      else
        i = i + 1
      end
      add("N")

    elseif c == "Ñ" then
      add("N")
      i = i + 1

    elseif c == "P" then
      if at(i + 1) == "H" then
        add("F")
        i = i + 2
      else
        add("P")
        if at(i + 1) == "P" then
          i = i + 2
        else
          i = i + 1
        end
      end

    elseif c == "Q" then
      if at(i + 1) == "Q" then
        i = i + 2
      else
        i = i + 1
      end
      add("K")

    elseif c == "R" then
      if i == len and not false and starts_with_at(i - 2, "IE") and
         not (starts_with_at(i - 4, "ME") or starts_with_at(i - 3, "MA")) then
        add("", "R")
      else
        add("R")
      end
      if at(i + 1) == "R" then
        i = i + 2
      else
        i = i + 1
      end

    elseif c == "S" then
      -- Special cases: island, isle
      if starts_with_at(i - 1, "ISL") or starts_with_at(i - 1, "YSL") then
        i = i + 1
      elseif i == 1 and starts_with_at(i, "SUGAR") then
        add("X", "S")
        i = i + 1
      elseif starts_with_at(i, "SH") then
        add("X")
        i = i + 2
      elseif starts_with_at(i, "SIO") or starts_with_at(i, "SIA") then
        if false then -- slavo-germanic
          add("S")
        else
          add("S", "X")
        end
        i = i + 3
      elseif (i == 1 and (at(i + 1) == "M" or at(i + 1) == "N" or at(i + 1) == "L" or at(i + 1) == "W")) or
             starts_with_at(i + 1, "Z") then
        add("S", "X")
        if at(i + 1) == "Z" then
          i = i + 2
        else
          i = i + 1
        end
      elseif starts_with_at(i, "SC") then
        if at(i + 2) == "H" then
          -- Slavic or Germanic: SK
          if at(i + 3) == "W" or at(i + 3) == "A" or at(i + 3) == "O" then
            add("X", "SK")
          else
            if i == 1 and not is_vowel(3) and at(3) ~= "W" then
              add("X", "S")
            else
              add("X")
            end
          end
          i = i + 3
        elseif at(i + 2) == "I" or at(i + 2) == "E" or at(i + 2) == "Y" then
          add("S")
          i = i + 3
        else
          add("SK")
          i = i + 3
        end
      else
        if i == len and (starts_with_at(i - 2, "AI") or starts_with_at(i - 2, "OI")) then
          add("", "S")
        else
          add("S")
        end
        if at(i + 1) == "S" or at(i + 1) == "Z" then
          i = i + 2
        else
          i = i + 1
        end
      end

    elseif c == "T" then
      if starts_with_at(i, "TION") or starts_with_at(i, "TIA") or starts_with_at(i, "TCH") then
        add("X")
        i = i + 3
      elseif starts_with_at(i, "TH") or starts_with_at(i, "TTH") then
        if starts_with_at(i + 2, "OM") or starts_with_at(i + 2, "AM") or
           starts_with_at(1, "VAN ") or starts_with_at(1, "VON ") or starts_with_at(1, "SCH") then
          add("T")
        else
          add("0", "T")
        end
        if starts_with_at(i, "TTH") then
          i = i + 3
        else
          i = i + 2
        end
      else
        add("T")
        if at(i + 1) == "T" or at(i + 1) == "D" then
          i = i + 2
        else
          i = i + 1
        end
      end

    elseif c == "V" then
      if at(i + 1) == "V" then
        i = i + 2
      else
        i = i + 1
      end
      add("F")

    elseif c == "W" then
      if starts_with_at(i, "WR") then
        add("R")
        i = i + 2
      else
        if i == 1 and (is_vowel(i + 1) or starts_with_at(i, "WH")) then
          if is_vowel(i + 1) then
            add("A", "F")
          else
            add("A")
          end
        end
        if (i == len and is_vowel(i - 1)) or
           starts_with_at(i - 1, "EWSKI") or starts_with_at(i - 1, "EWSKY") or
           starts_with_at(i - 1, "OWSKI") or starts_with_at(i - 1, "OWSKY") or
           starts_with_at(1, "SCH") then
          add("", "F")
          i = i + 1
        elseif starts_with_at(i, "WICZ") or starts_with_at(i, "WITZ") then
          add("TS", "FX")
          i = i + 4
        else
          i = i + 1
        end
      end

    elseif c == "X" then
      if not (i == len and (starts_with_at(i - 3, "IAU") or starts_with_at(i - 3, "EAU") or
              starts_with_at(i - 2, "AU") or starts_with_at(i - 2, "OU"))) then
        add("KS")
      end
      if at(i + 1) == "C" or at(i + 1) == "X" then
        i = i + 2
      else
        i = i + 1
      end

    elseif c == "Z" then
      if at(i + 1) == "H" then
        add("J")
        i = i + 2
      else
        if starts_with_at(i + 1, "ZA") or starts_with_at(i + 1, "ZI") or starts_with_at(i + 1, "ZO") or
           (i > 1 and at(i - 1) ~= "T") then
          add("S", "TS")
        else
          add("S")
        end
        if at(i + 1) == "Z" then
          i = i + 2
        else
          i = i + 1
        end
      end

    else
      i = i + 1
    end
  end

  local primary = table.concat(pri, "")
  local secondary = table.concat(sec, "")
  if secondary == primary then
    secondary = primary
  end
  return primary, secondary
end

-- ---------------------------------------------------------------------------
-- NYSIIS (New York State Identification and Intelligence System)
-- ---------------------------------------------------------------------------

M.nysiis = function(word)
  if not word or word == "" then
    return nil, "empty input"
  end

  local s = upper(word)
  s = s:gsub("[^A-Z]", "")
  if s == "" then
    return nil, "empty input"
  end

  -- Step 1: Transliterate prefix
  local prefixes = {
    { "MAC", "MCC" },
    { "KN",  "NN"  },
    { "K",   "C"   },
    { "PH",  "FF"  },
    { "PF",  "FF"  },
    { "SCH", "SSS" },
  }
  for _, pair in ipairs(prefixes) do
    local from, to = pair[1], pair[2]
    if s:sub(1, #from) == from then
      s = to .. s:sub(#from + 1)
      break
    end
  end

  -- Step 2: Transliterate suffix
  local suffixes = {
    { "EE",  "Y" },
    { "IE",  "Y" },
    { "DT",  "D" },
    { "RT",  "D" },
    { "RD",  "D" },
    { "NT",  "D" },
    { "ND",  "D" },
  }
  for _, pair in ipairs(suffixes) do
    local from, to = pair[1], pair[2]
    local tail = #s - #from + 1
    if tail > 0 and s:sub(tail) == from then
      s = s:sub(1, tail - 1) .. to
      break
    end
  end

  -- Keep first character
  local first = s:sub(1, 1)
  local body = s:sub(2)

  -- Step 3: Encode body
  -- Apply substitution rules (left to right, longest match first)
  --: (string) -> string
  local function encode_body(str)
    local result = {} --[[: { [integer]: string }]]
    local j = 1
    local blen = #str
    while j <= blen do
      local ch = str:sub(j, j)
      -- Multi-char substitutions first
      if str:sub(j, j+1) == "EV" then
        result[#result + 1] = "AF"
        j = j + 2
      elseif ch == "E" or ch == "I" or ch == "O" or ch == "U" then
        result[#result + 1] = "A"
        j = j + 1
      elseif ch == "Q" then
        result[#result + 1] = "G"
        j = j + 1
      elseif ch == "Z" then
        result[#result + 1] = "S"
        j = j + 1
      elseif ch == "M" then
        result[#result + 1] = "N"
        j = j + 1
      elseif ch == "K" then
        if str:sub(j, j+1) == "KN" then
          result[#result + 1] = "N"
          j = j + 2
        else
          result[#result + 1] = "C"
          j = j + 1
        end
      elseif ch == "S" then
        if str:sub(j, j+2) == "SCH" then
          result[#result + 1] = "SSS"
          j = j + 3
        else
          result[#result + 1] = "S"
          j = j + 1
        end
      elseif ch == "P" then
        if str:sub(j, j+1) == "PH" then
          result[#result + 1] = "FF"
          j = j + 2
        else
          result[#result + 1] = "P"
          j = j + 1
        end
      elseif ch == "H" then
        -- If H is between two vowels or not before a vowel, replace with previous char
        local prev_ch = j > 1 and str:sub(j-1, j-1) or ""
        local next_ch = str:sub(j+1, j+1)
        local prev_is_vowel = prev_ch == "A" or prev_ch == "E" or prev_ch == "I" or prev_ch == "O" or prev_ch == "U"
        local next_is_vowel = next_ch == "A" or next_ch == "E" or next_ch == "I" or next_ch == "O" or next_ch == "U"
        if not next_is_vowel or prev_is_vowel then
          if #result > 0 then
            result[#result + 1] = result[#result]:sub(-1)
          end
        end
        j = j + 1
      elseif ch == "W" then
        -- W is only kept if preceded by a vowel
        local prev_ch = j > 1 and str:sub(j-1, j-1) or ""
        local prev_is_vowel = prev_ch == "A" or prev_ch == "E" or prev_ch == "I" or prev_ch == "O" or prev_ch == "U"
        if prev_is_vowel then
          result[#result + 1] = "A"
        end
        j = j + 1
      else
        result[#result + 1] = ch
        j = j + 1
      end
    end
    return table.concat(result, "")
  end

  local encoded = encode_body(body)

  -- Step 4: Collapse adjacent duplicate characters
  local collapsed = {}
  local prev_ch = ""
  for k = 1, #encoded do
    local ch = encoded:sub(k, k)
    if ch ~= prev_ch then
      collapsed[#collapsed + 1] = ch
      prev_ch = ch
    end
  end

  -- Step 5: Remove trailing S if present
  if #collapsed > 0 and collapsed[#collapsed] == "S" and #collapsed > 1 then
    collapsed[#collapsed] = nil
  end

  -- Remove trailing A if present
  if #collapsed > 0 and collapsed[#collapsed] == "A" then
    collapsed[#collapsed] = nil
  end

  local result = first .. table.concat(collapsed, "")

  -- Uppercase (already uppercase, but ensure)
  return result:upper()
end

-- ---------------------------------------------------------------------------
-- Utility: sounds_like and similarity
-- ---------------------------------------------------------------------------

M.sounds_like = function(a, b)
  local sa = M.soundex(a)
  local sb = M.soundex(b)
  if sa == nil or sb == nil then return false end
  return sa == sb
end

-- Longest Common Subsequence length of two strings
--: (string, string) -> integer
local function lcs_length(a, b)
  local la, lb = #a, #b
  if la == 0 or lb == 0 then return 0 end
  -- Use two-row DP
  local prev = {} --[[: { [integer]: integer }]]
  local curr = {} --[[: { [integer]: integer }]]
  for j = 0, lb do prev[j] = 0 end
  for i_idx = 1, la do
    curr[0] = 0
    for j_idx = 1, lb do
      if a:sub(i_idx, i_idx) == b:sub(j_idx, j_idx) then
        curr[j_idx] = prev[j_idx - 1] + 1
      else
        curr[j_idx] = math.max(prev[j_idx], curr[j_idx - 1])
      end
    end
    -- Swap
    for j_idx = 0, lb do
      prev[j_idx] = curr[j_idx]
    end
  end
  return prev[lb]
end

M.similarity = function(a, b)
  local pa = M.soundex(a)
  local pb = M.soundex(b)
  if pa == nil or pb == nil then return 0.0 end
  local lcs = lcs_length(pa, pb)
  local maxlen = math.max(#pa, #pb)
  if maxlen == 0 then return 1.0 end
  return lcs / maxlen
end

return M
