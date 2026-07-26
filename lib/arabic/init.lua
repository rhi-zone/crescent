-- Arabic joining/shaping — pure Lua implementation of Unicode Joining_Type
-- classification (UAX #44 / The Unicode Standard §9.2) and positional
-- shaping into Arabic Presentation Forms-B (U+FE70-U+FEFF).
--
-- Classification data scope (bounded subset, NOT the full 1.1M-codepoint
-- DerivedJoiningType.txt), sourced from Unicode 17.0
-- extracted/DerivedJoiningType.txt:
--
--   Covered ranges (per-codepoint Joining_Type):
--     - Arabic block (U+0600-U+06FF)
--     - Arabic Supplement (U+0750-U+077F)
--   Default for uncovered codepoints (including the rest of the Arabic
--   block not listed above): "U" (Non_Joining), per UCD
--   @missing: 0000..10FFFF; Non_Joining.
--
-- Positional shaping (presentation-form lookup) scope, sourced from
-- Unicode 17.0 UnicodeData.txt Decomposition_Mapping field for
-- U+FE70-U+FEFC:
--   Covered: the 33 base Arabic letters U+0621-U+064A that have an
--   <isolated>/<initial>/<medial>/<final> decomposition into
--   Presentation Forms-B. Right_Joining letters have only
--   isolated/final forms (they never accept a join from the following
--   character); Dual_Joining letters have all four.
--   NOT covered: extended letters outside U+0621-U+064A (e.g. Arabic
--   Supplement letters such as U+066E DOTLESS BEH) are classified with a
--   correct Joining_Type but have NO presentation-form codepoints
--   allocated by Unicode in FE70-FEFF, so shape_codepoints leaves them
--   as their original codepoint at every position. This is a real gap
--   in the Unicode block (Arabic Presentation Forms-B was frozen after
--   the original 1991 Arabic repertoire), not an omission here.
--   Also NOT covered: the tatweel/space + combining-mark "contextual
--   diacritic" forms at U+FE70-U+FE7F (e.g. U+FE71 TATWEEL WITH
--   FATHATAN MEDIAL FORM) — these render a diacritic mark itself, not a
--   base letter, and are a distinct concern from letter joining.
--
-- Mandatory ligature (Lam-Alef) is implemented as a separate, explicit
-- post-process (M.apply_lam_alef_ligatures) — see that function's docs.
-- It is standalone and NOT composable with shape_codepoints in either
-- order (see the limitation documented on that function); producing text
-- that is both fully positionally shaped and ligature-correct would
-- require joining-aware ligature detection integrated into a single
-- pass, which is not implemented.
-- This is NOT full OpenType shaping: no other ligatures, no mark
-- positioning, no contextual alternates beyond Lam-Alef.

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local utf8 = require("lib.encode.utf8")

local M = {}
M._tier = "pure"

--:: joining_type = "R" | "L" | "D" | "C" | "U" | "T"
-- R = Right_Joining, L = Left_Joining, D = Dual_Joining, C = Join_Causing,
-- U = Non_Joining, T = Transparent.

--:: shape_form = "isolated" | "initial" | "medial" | "final"

-- ============================================================
-- JOINING TYPE CLASSIFICATION (bounded table)
-- ============================================================

--:: join_range = { integer, integer, joining_type }
local JOIN_RANGES = {} --: { [integer]: join_range }
--: (integer, integer, joining_type) -> nil
local function add_join_range(lo, hi, t) JOIN_RANGES[#JOIN_RANGES + 1] = { lo, hi, t } end

-- Arabic block (U+0600-U+06FF) + Arabic Supplement (U+0750-U+077F).
-- Sourced verbatim from Unicode 17.0 extracted/DerivedJoiningType.txt.
add_join_range(0x0610, 0x061A, "T")
add_join_range(0x061C, 0x061C, "T")
add_join_range(0x0620, 0x0620, "D")
add_join_range(0x0622, 0x0625, "R")
add_join_range(0x0626, 0x0626, "D")
add_join_range(0x0627, 0x0627, "R")
add_join_range(0x0628, 0x0628, "D")
add_join_range(0x0629, 0x0629, "R")
add_join_range(0x062A, 0x062E, "D")
add_join_range(0x062F, 0x0632, "R")
add_join_range(0x0633, 0x063F, "D")
add_join_range(0x0640, 0x0640, "C")
add_join_range(0x0641, 0x0647, "D")
add_join_range(0x0648, 0x0648, "R")
add_join_range(0x0649, 0x064A, "D")
add_join_range(0x064B, 0x065F, "T")
add_join_range(0x066E, 0x066F, "D")
add_join_range(0x0670, 0x0670, "T")
add_join_range(0x0671, 0x0673, "R")
add_join_range(0x0675, 0x0677, "R")
add_join_range(0x0678, 0x0687, "D")
add_join_range(0x0688, 0x0699, "R")
add_join_range(0x069A, 0x06BF, "D")
add_join_range(0x06C0, 0x06C0, "R")
add_join_range(0x06C1, 0x06C2, "D")
add_join_range(0x06C3, 0x06CB, "R")
add_join_range(0x06CC, 0x06CC, "D")
add_join_range(0x06CD, 0x06CD, "R")
add_join_range(0x06CE, 0x06CE, "D")
add_join_range(0x06CF, 0x06CF, "R")
add_join_range(0x06D0, 0x06D1, "D")
add_join_range(0x06D2, 0x06D3, "R")
add_join_range(0x06D5, 0x06D5, "R")
add_join_range(0x06D6, 0x06DC, "T")
add_join_range(0x06DF, 0x06E4, "T")
add_join_range(0x06E7, 0x06E8, "T")
add_join_range(0x06EA, 0x06ED, "T")
add_join_range(0x06EE, 0x06EF, "R")
add_join_range(0x06FA, 0x06FC, "D")
add_join_range(0x06FF, 0x06FF, "D")
add_join_range(0x0759, 0x075B, "R")
add_join_range(0x075C, 0x076A, "D")
add_join_range(0x076B, 0x076C, "R")
add_join_range(0x076D, 0x0770, "D")
add_join_range(0x0771, 0x0771, "R")
add_join_range(0x0772, 0x0772, "D")
add_join_range(0x0773, 0x0774, "R")
add_join_range(0x0775, 0x0777, "D")
add_join_range(0x0778, 0x0779, "R")
add_join_range(0x077A, 0x077F, "D")

table.sort(JOIN_RANGES, function(a, b) return a[1] < b[1] end)

--: (integer) -> joining_type | nil
local function join_range_lookup(cp)
  local lo, hi = 1, #JOIN_RANGES
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local r = JOIN_RANGES[mid]
    if cp < r[1] then hi = mid - 1
    elseif cp > r[2] then lo = mid + 1
    else return r[3] end
  end
  return nil
end

--- Return the Unicode Joining_Type for a single codepoint.
-- Covers the bounded subset documented in the file header (Arabic block +
-- Arabic Supplement); returns "U" (Non_Joining) for any codepoint outside
-- the covered ranges, matching the UCD global default.
--: (number) -> (joining_type | nil, string | nil)
M.classify_codepoint = function(cp)
  local n = math.floor(cp)
  if cp < 0 or cp ~= n then return nil, "invalid codepoint" end
  return join_range_lookup(n) or "U"
end

-- ============================================================
-- PRESENTATION FORM TABLE (U+0621-U+064A -> Presentation Forms-B)
-- ============================================================

--:: base_forms = { isolated: integer, initial: integer | nil, medial: integer | nil, final: integer | nil }
-- Sourced verbatim from Unicode 17.0 UnicodeData.txt Decomposition_Mapping
-- field for U+FE70-U+FEFC.
local BASE_FORMS = { --: { [integer]: base_forms }
  [0x0621] = { isolated = 0xFE80, final = nil, initial = nil, medial = nil },
  [0x0622] = { isolated = 0xFE81, final = 0xFE82, initial = nil, medial = nil },
  [0x0623] = { isolated = 0xFE83, final = 0xFE84, initial = nil, medial = nil },
  [0x0624] = { isolated = 0xFE85, final = 0xFE86, initial = nil, medial = nil },
  [0x0625] = { isolated = 0xFE87, final = 0xFE88, initial = nil, medial = nil },
  [0x0626] = { isolated = 0xFE89, final = 0xFE8A, initial = 0xFE8B, medial = 0xFE8C },
  [0x0627] = { isolated = 0xFE8D, final = 0xFE8E, initial = nil, medial = nil },
  [0x0628] = { isolated = 0xFE8F, final = 0xFE90, initial = 0xFE91, medial = 0xFE92 },
  [0x0629] = { isolated = 0xFE93, final = 0xFE94, initial = nil, medial = nil },
  [0x062A] = { isolated = 0xFE95, final = 0xFE96, initial = 0xFE97, medial = 0xFE98 },
  [0x062B] = { isolated = 0xFE99, final = 0xFE9A, initial = 0xFE9B, medial = 0xFE9C },
  [0x062C] = { isolated = 0xFE9D, final = 0xFE9E, initial = 0xFE9F, medial = 0xFEA0 },
  [0x062D] = { isolated = 0xFEA1, final = 0xFEA2, initial = 0xFEA3, medial = 0xFEA4 },
  [0x062E] = { isolated = 0xFEA5, final = 0xFEA6, initial = 0xFEA7, medial = 0xFEA8 },
  [0x062F] = { isolated = 0xFEA9, final = 0xFEAA, initial = nil, medial = nil },
  [0x0630] = { isolated = 0xFEAB, final = 0xFEAC, initial = nil, medial = nil },
  [0x0631] = { isolated = 0xFEAD, final = 0xFEAE, initial = nil, medial = nil },
  [0x0632] = { isolated = 0xFEAF, final = 0xFEB0, initial = nil, medial = nil },
  [0x0633] = { isolated = 0xFEB1, final = 0xFEB2, initial = 0xFEB3, medial = 0xFEB4 },
  [0x0634] = { isolated = 0xFEB5, final = 0xFEB6, initial = 0xFEB7, medial = 0xFEB8 },
  [0x0635] = { isolated = 0xFEB9, final = 0xFEBA, initial = 0xFEBB, medial = 0xFEBC },
  [0x0636] = { isolated = 0xFEBD, final = 0xFEBE, initial = 0xFEBF, medial = 0xFEC0 },
  [0x0637] = { isolated = 0xFEC1, final = 0xFEC2, initial = 0xFEC3, medial = 0xFEC4 },
  [0x0638] = { isolated = 0xFEC5, final = 0xFEC6, initial = 0xFEC7, medial = 0xFEC8 },
  [0x0639] = { isolated = 0xFEC9, final = 0xFECA, initial = 0xFECB, medial = 0xFECC },
  [0x063A] = { isolated = 0xFECD, final = 0xFECE, initial = 0xFECF, medial = 0xFED0 },
  [0x0641] = { isolated = 0xFED1, final = 0xFED2, initial = 0xFED3, medial = 0xFED4 },
  [0x0642] = { isolated = 0xFED5, final = 0xFED6, initial = 0xFED7, medial = 0xFED8 },
  [0x0643] = { isolated = 0xFED9, final = 0xFEDA, initial = 0xFEDB, medial = 0xFEDC },
  [0x0644] = { isolated = 0xFEDD, final = 0xFEDE, initial = 0xFEDF, medial = 0xFEE0 },
  [0x0645] = { isolated = 0xFEE1, final = 0xFEE2, initial = 0xFEE3, medial = 0xFEE4 },
  [0x0646] = { isolated = 0xFEE5, final = 0xFEE6, initial = 0xFEE7, medial = 0xFEE8 },
  [0x0647] = { isolated = 0xFEE9, final = 0xFEEA, initial = 0xFEEB, medial = 0xFEEC },
  [0x0648] = { isolated = 0xFEED, final = 0xFEEE, initial = nil, medial = nil },
  [0x0649] = { isolated = 0xFEEF, final = 0xFEF0, initial = nil, medial = nil },
  [0x064A] = { isolated = 0xFEF1, final = 0xFEF2, initial = 0xFEF3, medial = 0xFEF4 },
}

-- ============================================================
-- LAM-ALEF MANDATORY LIGATURE (U+0644 + alef variant -> ligature)
-- ============================================================

--:: lam_alef_forms = { isolated: integer, final: integer }
-- Sourced verbatim from Unicode 17.0 UnicodeData.txt Decomposition_Mapping
-- field for U+FEF5-U+FEFC. Only isolated/final exist: the ligature is
-- always the last two characters of a joining run (alef is Right_Joining
-- and never sends a join forward).
local LAM_ALEF_FORMS = { --: { [integer]: lam_alef_forms }
  [0x0622] = { isolated = 0xFEF5, final = 0xFEF6 },
  [0x0623] = { isolated = 0xFEF7, final = 0xFEF8 },
  [0x0625] = { isolated = 0xFEF9, final = 0xFEFA },
  [0x0627] = { isolated = 0xFEFB, final = 0xFEFC },
}
local LAM = 0x0644

-- ============================================================
-- CODEPOINT INPUT NORMALIZATION
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
-- POSITIONAL SHAPING
-- ============================================================

local SEND = { D = true, C = true, L = true } --: { [string]: boolean }
local RECV = { D = true, C = true, R = true } --: { [string]: boolean }

--:: shaped_char = { codepoint: integer, form: shape_form | nil, joining_type: joining_type }

--- Determine the joining form of every codepoint in a sequence and map it
-- to its Presentation Forms-B codepoint where one exists.
--
-- Returns one shaped_char per input codepoint (strict 1:1 correspondence
-- with the input — see apply_lam_alef_ligatures for the separate,
-- length-changing ligature pass).
--
-- shaped_char.codepoint is the presentation-form codepoint when
-- BASE_FORMS covers the character at the computed form; otherwise it is
-- the original input codepoint unchanged (Non_Joining/Transparent/
-- Join_Causing characters, or Dual_Joining/Right_Joining characters
-- outside the covered U+0621-U+064A range).
-- shaped_char.form is nil for characters that are never shaped (C, U, T).
--
-- Transparent (combining mark) characters do not participate in joining:
-- they are skipped when locating each character's nearest neighbor, but
-- are still emitted unchanged in the output at their own position.
--
-- On invalid input: (nil, errmsg)
--: (string | { [integer]: integer }) -> (shaped_char[] | nil, string | nil)
M.shape_codepoints = function(input)
  local cps, err = codepoints_from_input(input)
  if not cps then return nil, err end
  local n = #cps

  local jtype = {} --: { [integer]: joining_type }
  for i = 1, n do
    local t, terr = M.classify_codepoint(cps[i])
    if not t then return nil, terr end
    jtype[i] = t
  end

  -- nearest non-Transparent index before i
  --: (integer) -> integer | nil
  local function prev_participant(i)
    local k = i - 1
    while k >= 1 and jtype[k] == "T" do k = k - 1 end
    if k >= 1 then return k end
    return nil
  end
  -- nearest non-Transparent index after i
  --: (integer) -> integer | nil
  local function next_participant(i)
    local k = i + 1
    while k <= n and jtype[k] == "T" do k = k + 1 end
    if k <= n then return k end
    return nil
  end

  local result = {} --: { [integer]: shaped_char }
  for i = 1, n do
    local t = jtype[i]
    if t == "T" then
      result[i] = { codepoint = cps[i], form = nil, joining_type = t }
    elseif t == "D" or t == "R" or t == "L" then
      local pi = prev_participant(i)
      local ni = next_participant(i)
      local from_prev = pi ~= nil and SEND[jtype[pi]] and RECV[t] or false
      local to_next = ni ~= nil and SEND[t] and RECV[jtype[ni]] or false

      local form --: shape_form | nil
      if from_prev and to_next then form = "medial"
      elseif from_prev then form = "final"
      elseif to_next then form = "initial"
      else form = "isolated" end

      local forms = BASE_FORMS[cps[i]]
      local shaped_cp = (forms and forms[form]) or cps[i]
      result[i] = { codepoint = shaped_cp, form = form, joining_type = t }
    else
      -- C (Join_Causing, e.g. Tatweel) and U (Non_Joining): no shape.
      result[i] = { codepoint = cps[i], form = nil, joining_type = t }
    end
  end

  return result
end

--- Shape a UTF-8 string into its positional presentation forms.
-- Convenience wrapper over shape_codepoints + re-encode; length in
-- codepoints is preserved (see apply_lam_alef_ligatures for ligatures).
-- On invalid input: (nil, errmsg)
--: (string) -> (string | nil, string | nil)
M.shape = function(text)
  local shaped, err = M.shape_codepoints(text)
  if not shaped then return nil, err end
  local parts = {} --: { [integer]: string }
  for i = 1, #shaped do parts[i] = utf8.char(shaped[i].codepoint) end
  return table.concat(parts), nil
end

--- Apply the mandatory Lam-Alef ligature substitution to RAW (unshaped)
-- input — a UTF-8 string or a codepoint array of original text
-- codepoints, NOT the output of shape_codepoints.
--
-- Whenever a LAM (U+0644) is immediately followed (skipping Transparent
-- characters) by one of the four alef variants (U+0622, U+0623, U+0625,
-- U+0627), the pair collapses into a single ligature codepoint from
-- U+FEF5-U+FEFC — isolated if the LAM itself had no incoming join,
-- final otherwise. This changes the output length: it is NOT 1:1 with
-- the input, unlike shape_codepoints. Callers needing an index mapping
-- back to source positions should not use this pass.
--
-- LIMITATION (not composable with shape_codepoints, in either order):
-- running this after shape_codepoints will not detect LAM, because by
-- then it has already been replaced by its own presentation-form
-- codepoint. Running shape_codepoints after this will misjudge the
-- character preceding the ligature, because the ligature codepoint
-- falls outside classify_codepoint's covered ranges and defaults to
-- Non_Joining, hiding the fact that it still accepts a join from its
-- predecessor. Producing text that is both fully positionally shaped
-- AND ligature-correct requires joining awareness to be integrated
-- into a single pass (treating the LAM+alef pair as one unit during
-- neighbor resolution) — not implemented here. This function is only
-- correct standalone, for callers who want Lam-Alef collapsed and are
-- not also running shape_codepoints over the same text.
--
-- On invalid input: (nil, errmsg)
--: (string | { [integer]: integer }) -> ({ [integer]: integer } | nil, string | nil)
M.apply_lam_alef_ligatures = function(input)
  local cps, err = codepoints_from_input(input)
  if not cps then return nil, err end
  local n = #cps

  local jtype = {} --: { [integer]: joining_type }
  for i = 1, n do
    local t, terr = M.classify_codepoint(cps[i])
    if not t then return nil, terr end
    jtype[i] = t
  end

  local out = {} --: { [integer]: integer }
  local i = 1
  while i <= n do
    if cps[i] == LAM then
      -- Find next non-Transparent codepoint (may be adjacent).
      local k = i + 1
      while k <= n and jtype[k] == "T" do k = k + 1 end
      local lig = k <= n and LAM_ALEF_FORMS[cps[k]] or nil
      if lig then
        -- Any transparent marks between LAM and the alef are emitted
        -- unchanged before the ligature (they still combine visually
        -- with what precedes them; not reordered).
        for m = i + 1, k - 1 do out[#out + 1] = cps[m] end
        local pi = i - 1
        while pi >= 1 and jtype[pi] == "T" do pi = pi - 1 end
        local from_prev = pi >= 1 and SEND[jtype[pi]] and true or false
        out[#out + 1] = from_prev and lig.final or lig.isolated
        i = k + 1
      else
        out[#out + 1] = cps[i]
        i = i + 1
      end
    else
      out[#out + 1] = cps[i]
      i = i + 1
    end
  end

  return out
end

return M
