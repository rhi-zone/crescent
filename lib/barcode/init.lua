if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

--- 1D barcode encoder: Code128, EAN-13, EAN-8, UPC-A, Code39.
-- Returns bars arrays (1=black, 0=white) and SVG output.
local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Code128 bar patterns
-- Each entry is a table of 6 widths (3 bars + 3 spaces), sum = 11 modules.
-- Index 0..102 = data symbols; 103=StartA, 104=StartB, 105=StartC, 106=Stop
-- ---------------------------------------------------------------------------
-- The stop symbol is 7 widths summing to 13 (special case).
local CODE128_PATTERNS = {
  [0]  = {2,1,2,2,2,2}, [1]  = {2,2,2,1,2,2}, [2]  = {2,2,2,2,2,1},
  [3]  = {1,2,1,2,2,3}, [4]  = {1,2,1,3,2,2}, [5]  = {1,3,1,2,2,2},
  [6]  = {1,2,2,2,1,3}, [7]  = {1,2,2,3,1,2}, [8]  = {1,3,2,2,1,2},
  [9]  = {2,2,1,2,1,3}, [10] = {2,2,1,3,1,2}, [11] = {2,3,1,2,1,2},
  [12] = {1,1,2,2,3,2}, [13] = {1,2,2,1,3,2}, [14] = {1,2,2,2,3,1},
  [15] = {1,1,3,2,2,2}, [16] = {1,2,3,1,2,2}, [17] = {1,2,3,2,2,1},
  [18] = {2,2,3,2,1,1}, [19] = {2,2,1,1,3,2}, [20] = {2,2,1,2,3,1},
  [21] = {2,1,3,2,1,2}, [22] = {2,2,3,1,1,2}, [23] = {3,1,2,1,3,1},
  [24] = {3,1,1,2,2,2}, [25] = {3,2,1,1,2,2}, [26] = {3,2,1,2,2,1},
  [27] = {3,1,2,2,1,2}, [28] = {3,2,2,1,1,2}, [29] = {3,2,2,2,1,1},
  [30] = {2,1,2,1,2,3}, [31] = {2,1,2,3,2,1}, [32] = {2,3,2,1,2,1},
  [33] = {1,1,1,3,2,3}, [34] = {1,3,1,1,2,3}, [35] = {1,3,1,3,2,1},
  [36] = {1,1,2,3,1,3}, [37] = {1,3,2,1,1,3}, [38] = {1,3,2,3,1,1},
  [39] = {2,1,1,3,1,3}, [40] = {2,3,1,1,1,3}, [41] = {2,3,1,3,1,1},
  [42] = {1,1,2,1,3,3}, [43] = {1,1,2,3,3,1}, [44] = {1,3,2,1,3,1},
  [45] = {1,1,3,1,2,3}, [46] = {1,1,3,3,2,1}, [47] = {1,3,3,1,2,1},
  [48] = {3,1,3,1,2,1}, [49] = {2,1,1,3,3,1}, [50] = {2,3,1,1,3,1},
  [51] = {2,1,3,1,1,3}, [52] = {2,1,3,3,1,1}, [53] = {2,1,3,1,3,1},
  [54] = {3,1,1,1,2,3}, [55] = {3,1,1,3,2,1}, [56] = {3,3,1,1,2,1},
  [57] = {3,1,2,1,1,3}, [58] = {3,1,2,3,1,1}, [59] = {3,3,2,1,1,1},
  [60] = {3,1,4,1,1,1}, [61] = {2,2,1,4,1,1}, [62] = {4,3,1,1,1,1},
  [63] = {1,1,1,2,2,4}, [64] = {1,1,1,4,2,2}, [65] = {1,2,1,1,2,4},
  [66] = {1,2,1,4,2,1}, [67] = {1,4,1,1,2,2}, [68] = {1,4,1,2,2,1},
  [69] = {1,1,2,2,1,4}, [70] = {1,1,2,4,1,2}, [71] = {1,2,2,1,1,4},
  [72] = {1,2,2,4,1,1}, [73] = {1,4,2,1,1,2}, [74] = {1,4,2,2,1,1},
  [75] = {2,4,1,2,1,1}, [76] = {2,2,1,1,1,4}, [77] = {4,1,3,1,1,1},
  [78] = {2,4,1,1,1,2}, [79] = {1,3,4,1,1,1}, [80] = {1,1,1,2,4,2},
  [81] = {1,2,1,1,4,2}, [82] = {1,2,1,2,4,1}, [83] = {1,1,4,2,1,2},
  [84] = {1,2,4,1,1,2}, [85] = {1,2,4,2,1,1}, [86] = {4,1,1,2,1,2},
  [87] = {4,2,1,1,1,2}, [88] = {4,2,1,2,1,1}, [89] = {2,1,2,1,4,1},
  [90] = {2,1,4,1,2,1}, [91] = {4,1,2,1,2,1}, [92] = {1,1,1,1,4,3},
  [93] = {1,1,1,3,4,1}, [94] = {1,3,1,1,4,1}, [95] = {1,1,4,1,1,3},
  [96] = {1,1,4,3,1,1}, [97] = {4,1,1,1,1,3}, [98] = {4,1,1,3,1,1},
  [99] = {1,1,3,1,4,1}, [100] = {1,1,4,1,3,1}, [101] = {3,1,1,1,4,1},
  [102] = {4,1,1,1,3,1},
  -- Start symbols
  [103] = {2,1,1,4,1,2}, -- StartA
  [104] = {2,1,1,2,1,4}, -- StartB
  [105] = {2,1,1,2,3,2}, -- StartC
  -- Stop (7 widths, 13 modules: bar-space-bar-space-bar-space-bar)
  [106] = {2,3,3,1,1,1,2},
}

-- Code128 Code B: symbol value for ASCII code point
-- Symbol 0..94 map to ASCII 32..126
-- Symbol 95..102 map to special function codes (FNC3, FNC2, SHIFT, CodeC, CodeB, FNC4, CodeA, FNC1)
-- For Code B auto-select we only use values 0..94 (space..~)
local function code128b_value(byte)
  -- ASCII 32 = symbol 0, ASCII 126 = symbol 94
  if byte >= 32 and byte <= 126 then
    return byte - 32
  end
  return nil
end

local function code128_append_pattern(bars, pat)
  local color = 1 -- start with bar (black)
  for i = 1, #pat do
    local w = pat[i]
    for _ = 1, w do
      bars[#bars + 1] = color
    end
    color = 1 - color
  end
end

--- Encode a string as Code128 (Code B subset).
-- Returns bars array, nil on success; nil, errmsg on failure.
function M.code128(s)
  if type(s) ~= "string" then
    return nil, "code128: expected string"
  end
  -- Check all chars are encodable in Code B (ASCII 32-126)
  for i = 1, #s do
    local b = s:byte(i)
    if b < 32 or b > 126 then
      return nil, "code128: character at position " .. i .. " (byte " .. b .. ") not encodable in Code B (ASCII 32-126)"
    end
  end

  local bars = {}
  -- Quiet zone: 10 white modules
  for _ = 1, 10 do bars[#bars + 1] = 0 end

  -- Start B symbol (value 104)
  code128_append_pattern(bars, CODE128_PATTERNS[104])

  -- Checksum: start value * 1
  local checksum = 104

  -- Data symbols
  for i = 1, #s do
    local sym = code128b_value(s:byte(i))
    code128_append_pattern(bars, CODE128_PATTERNS[sym])
    checksum = checksum + i * sym
  end

  checksum = checksum % 103
  code128_append_pattern(bars, CODE128_PATTERNS[checksum])

  -- Stop symbol (106)
  code128_append_pattern(bars, CODE128_PATTERNS[106])

  -- Quiet zone: 10 white modules
  for _ = 1, 10 do bars[#bars + 1] = 0 end

  return bars, nil
end

-- ---------------------------------------------------------------------------
-- EAN / UPC
-- ---------------------------------------------------------------------------

-- L-code patterns (left half, odd parity) for digits 0-9
-- Each is 7 modules.
local EAN_L = {
  [0] = {3,2,1,1}, [1] = {2,2,2,1}, [2] = {2,1,2,2}, [3] = {1,4,1,1},
  [4] = {1,1,3,2}, [5] = {1,2,3,1}, [6] = {1,1,1,4}, [7] = {1,3,1,2},
  [8] = {1,2,1,3}, [9] = {3,1,1,2},
}

-- G-code = reverse of R-code = reverse of complement of L-code
-- R-code: complement of L-code (bar<->space)
-- We store L-codes and compute R and G as needed.

-- Parity table for EAN-13 first digit: 6-bit pattern (0=L, 1=G)
-- First digit 0: LLLLLL, 1: LLGLGG, 2: LLGGLG, etc.
local EAN13_PARITY = {
  [0] = {0,0,0,0,0,0}, [1] = {0,0,1,0,1,1}, [2] = {0,0,1,1,0,1},
  [3] = {0,0,1,1,1,0}, [4] = {0,1,0,0,1,1}, [5] = {0,1,1,0,0,1},
  [6] = {0,1,1,1,0,0}, [7] = {0,1,0,1,0,1}, [8] = {0,1,0,1,1,0},
  [9] = {0,1,1,0,1,0},
}

-- Append an EAN digit (7 modules) given pattern type: "L", "G", or "R"
local function ean_append_digit(bars, digit, ptype)
  local lp = EAN_L[digit]
  local widths
  if ptype == "L" then
    widths = lp
  elseif ptype == "R" then
    -- R = complement of L: swap bar and space (invert colors)
    -- L starts with space (white), R starts with bar (black) relative to background
    -- Actually in EAN encoding:
    --   L-code: starts with space-bar-space-bar (WBWB)
    --   R-code: starts with bar-space-bar-space (BWBW) = complement
    -- widths are the same, just first module color is inverted
    widths = lp
  elseif ptype == "G" then
    -- G-code = reverse of R-code, same widths reversed
    widths = {}
    for i = #lp, 1, -1 do widths[#widths + 1] = lp[i] end
  end

  -- Determine starting color based on type
  -- In EAN-13, all digits are encoded on alternating bars, but the left half
  -- starts at a specific color context. We track color externally by examining
  -- current bars state.
  -- Simpler: append widths with correct starting color.
  -- L-code: starts with WHITE (space)
  -- G-code: starts with WHITE (space)  (same as L in terms of starting color)
  -- R-code: starts with BLACK (bar)
  local start_color = (ptype == "R") and 1 or 0
  local color = start_color
  for i = 1, #widths do
    local w = widths[i]
    for _ = 1, w do
      bars[#bars + 1] = color
    end
    color = 1 - color
  end
end

--- Calculate EAN-13 check digit from 12-digit string.
-- Returns check digit (0-9), nil on error.
function M.ean13_check_digit(s)
  if type(s) ~= "string" or #s ~= 12 then
    return nil, "ean13_check_digit: expected 12-digit string"
  end
  local sum = 0
  for i = 1, 12 do
    local d = s:byte(i) - 48
    if d < 0 or d > 9 then return nil, "ean13_check_digit: non-digit in input" end
    -- Odd positions (1,3,5,...) weight 1; even positions (2,4,6,...) weight 3
    sum = sum + d * ((i % 2 == 0) and 3 or 1)
  end
  return (10 - (sum % 10)) % 10
end

--- Calculate UPC-A check digit from 11-digit string.
function M.upca_check_digit(s)
  if type(s) ~= "string" or #s ~= 11 then
    return nil, "upca_check_digit: expected 11-digit string"
  end
  return M.ean13_check_digit("0" .. s)
end

--- Encode EAN-13.
-- Accepts 12-digit string (check digit computed) or 13-digit (check digit verified).
-- Returns bars array; nil, errmsg on failure.
function M.ean13(s)
  if type(s) ~= "string" then return nil, "ean13: expected string" end
  if #s ~= 12 and #s ~= 13 then
    return nil, "ean13: expected 12 or 13 digits, got " .. #s
  end
  for i = 1, #s do
    local b = s:byte(i)
    if b < 48 or b > 57 then
      return nil, "ean13: non-digit at position " .. i
    end
  end

  local digits = {}
  for i = 1, #s do digits[i] = s:byte(i) - 48 end

  local check, err
  if #s == 12 then
    check, err = M.ean13_check_digit(s)
    if not check then return nil, err end
    digits[13] = check
  else
    check, err = M.ean13_check_digit(s:sub(1, 12))
    if not check then return nil, err end
    if digits[13] ~= check then
      return nil, "ean13: invalid check digit (expected " .. check .. ", got " .. digits[13] .. ")"
    end
  end

  local first = digits[1]
  local parity = EAN13_PARITY[first]

  local bars = {}

  -- Quiet zone: 9 modules white
  for _ = 1, 9 do bars[#bars + 1] = 0 end

  -- Left guard: bar-space-bar (3 modules)
  bars[#bars + 1] = 1
  bars[#bars + 1] = 0
  bars[#bars + 1] = 1

  -- Left 6 digits (digits 2-7, indices 2..7)
  for i = 2, 7 do
    local pt = (parity[i - 1] == 0) and "L" or "G"
    ean_append_digit(bars, digits[i], pt)
  end

  -- Center guard: space-bar-space-bar-space (5 modules)
  bars[#bars + 1] = 0
  bars[#bars + 1] = 1
  bars[#bars + 1] = 0
  bars[#bars + 1] = 1
  bars[#bars + 1] = 0

  -- Right 6 digits (digits 8-13, indices 8..13) — always R-code
  for i = 8, 13 do
    ean_append_digit(bars, digits[i], "R")
  end

  -- Right guard: bar-space-bar (3 modules)
  bars[#bars + 1] = 1
  bars[#bars + 1] = 0
  bars[#bars + 1] = 1

  -- Quiet zone: 9 modules white
  for _ = 1, 9 do bars[#bars + 1] = 0 end

  return bars, nil
end

--- Encode EAN-8.
-- Accepts 7-digit string (check digit computed) or 8-digit (verified).
function M.ean8(s)
  if type(s) ~= "string" then return nil, "ean8: expected string" end
  if #s ~= 7 and #s ~= 8 then
    return nil, "ean8: expected 7 or 8 digits, got " .. #s
  end
  for i = 1, #s do
    local b = s:byte(i)
    if b < 48 or b > 57 then
      return nil, "ean8: non-digit at position " .. i
    end
  end

  local digits = {}
  for i = 1, #s do digits[i] = s:byte(i) - 48 end

  -- EAN-8 check digit: same algorithm as EAN-13 but on 7 digits
  -- Weights: odd=3, even=1 (reversed from EAN-13)
  local function ean8_check(d7)
    local sum = 0
    for i = 1, 7 do
      sum = sum + d7[i] * ((i % 2 == 1) and 3 or 1)
    end
    return (10 - (sum % 10)) % 10
  end

  if #s == 7 then
    digits[8] = ean8_check(digits)
  else
    local expected = ean8_check(digits)
    if digits[8] ~= expected then
      return nil, "ean8: invalid check digit (expected " .. expected .. ", got " .. digits[8] .. ")"
    end
  end

  local bars = {}

  -- Quiet zone: 9 modules
  for _ = 1, 9 do bars[#bars + 1] = 0 end

  -- Left guard
  bars[#bars + 1] = 1; bars[#bars + 1] = 0; bars[#bars + 1] = 1

  -- Left 4 digits (L-code)
  for i = 1, 4 do ean_append_digit(bars, digits[i], "L") end

  -- Center guard
  bars[#bars + 1] = 0; bars[#bars + 1] = 1; bars[#bars + 1] = 0
  bars[#bars + 1] = 1; bars[#bars + 1] = 0

  -- Right 4 digits (R-code)
  for i = 5, 8 do ean_append_digit(bars, digits[i], "R") end

  -- Right guard
  bars[#bars + 1] = 1; bars[#bars + 1] = 0; bars[#bars + 1] = 1

  -- Quiet zone: 9 modules
  for _ = 1, 9 do bars[#bars + 1] = 0 end

  return bars, nil
end

--- Encode UPC-A (12-digit EAN-13 with leading 0).
function M.upca(s)
  if type(s) ~= "string" then return nil, "upca: expected string" end
  if #s ~= 11 and #s ~= 12 then
    return nil, "upca: expected 11 or 12 digits, got " .. #s
  end
  for i = 1, #s do
    local b = s:byte(i)
    if b < 48 or b > 57 then
      return nil, "upca: non-digit at position " .. i
    end
  end
  -- UPC-A is EAN-13 with a leading 0
  return M.ean13("0" .. s)
end

-- ---------------------------------------------------------------------------
-- Code39
-- ---------------------------------------------------------------------------

-- Code39 character set: A-Z, 0-9, - . $ / + % SPACE
-- Each symbol: 9 modules (5 bars + 4 spaces), 3 wide elements.
-- Pattern encoded as 9 bits: 1=wide, 0=narrow; alternating bar/space starting with bar.
-- Narrow=1 module, wide=3 modules (standard ratio 3:1).
local CODE39_PATTERNS = {
  ["0"] = {false,false,false,true,true,false,true,false,false},
  ["1"] = {true,false,false,true,false,false,false,false,true},
  ["2"] = {false,false,true,true,false,false,false,false,true},
  ["3"] = {true,false,true,true,false,false,false,false,false},
  ["4"] = {false,false,false,true,true,false,false,false,true},  -- was wrong
  ["5"] = {true,false,false,true,true,false,false,false,false},
  ["6"] = {false,false,true,true,true,false,false,false,false},
  ["7"] = {false,false,false,true,false,false,true,false,true},
  ["8"] = {true,false,false,true,false,false,true,false,false},
  ["9"] = {false,false,true,true,false,false,true,false,false},
  ["A"] = {true,false,false,false,false,true,false,false,true},
  ["B"] = {false,false,true,false,false,true,false,false,true},
  ["C"] = {true,false,true,false,false,true,false,false,false},
  ["D"] = {false,false,false,false,true,true,false,false,true},
  ["E"] = {true,false,false,false,true,true,false,false,false},
  ["F"] = {false,false,true,false,true,true,false,false,false},
  ["G"] = {false,false,false,false,false,true,true,false,true},
  ["H"] = {true,false,false,false,false,true,true,false,false},
  ["I"] = {false,false,true,false,false,true,true,false,false},
  ["J"] = {false,false,false,false,true,true,true,false,false},
  ["K"] = {true,false,false,false,false,false,false,true,true},
  ["L"] = {false,false,true,false,false,false,false,true,true},
  ["M"] = {true,false,true,false,false,false,false,true,false},
  ["N"] = {false,false,false,false,true,false,false,true,true},
  ["O"] = {true,false,false,false,true,false,false,true,false},
  ["P"] = {false,false,true,false,true,false,false,true,false},
  ["Q"] = {false,false,false,false,false,false,true,true,true},
  ["R"] = {true,false,false,false,false,false,true,true,false},
  ["S"] = {false,false,true,false,false,false,true,true,false},
  ["T"] = {false,false,false,false,true,false,true,true,false},
  ["U"] = {true,true,false,false,false,false,false,false,true},
  ["V"] = {false,true,true,false,false,false,false,false,true},
  ["W"] = {true,true,true,false,false,false,false,false,false},
  ["X"] = {false,true,false,false,true,false,false,false,true},
  ["Y"] = {true,true,false,false,true,false,false,false,false},
  ["Z"] = {false,true,true,false,true,false,false,false,false},
  ["-"] = {false,true,false,false,false,false,true,false,true},
  ["."] = {true,true,false,false,false,false,true,false,false},
  [" "] = {false,true,true,false,false,false,true,false,false},
  ["$"] = {false,true,false,true,false,true,false,false,false},
  ["/"] = {false,true,false,true,false,false,false,true,false},
  ["+"] = {false,true,false,false,false,true,false,true,false},
  ["%"] = {false,false,false,true,false,true,false,true,false},
  ["*"] = {false,true,false,false,true,false,true,false,false}, -- start/stop
}

local function code39_append_symbol(bars, pat, narrow, wide)
  narrow = narrow or 1
  wide = wide or 3
  local color = 1 -- start with bar
  for i = 1, 9 do
    local w = pat[i] and wide or narrow
    for _ = 1, w do bars[#bars + 1] = color end
    color = 1 - color
  end
end

--- Encode Code39.
-- Valid chars: A-Z, 0-9, - . $ / + % SPACE
-- Returns bars array; nil, errmsg on failure.
function M.code39(s)
  if type(s) ~= "string" then return nil, "code39: expected string" end
  -- Validate
  for i = 1, #s do
    local c = s:sub(i, i)
    if not CODE39_PATTERNS[c] then
      return nil, "code39: invalid character '" .. c .. "' at position " .. i
    end
  end

  local bars = {}
  -- Quiet zone: 10 white modules
  for _ = 1, 10 do bars[#bars + 1] = 0 end

  -- Start symbol (*)
  code39_append_symbol(bars, CODE39_PATTERNS["*"])
  -- Inter-character gap: 1 narrow white
  bars[#bars + 1] = 0

  for i = 1, #s do
    local c = s:sub(i, i)
    code39_append_symbol(bars, CODE39_PATTERNS[c])
    -- Inter-character gap
    bars[#bars + 1] = 0
  end

  -- Stop symbol (*)
  code39_append_symbol(bars, CODE39_PATTERNS["*"])

  -- Quiet zone: 10 white modules
  for _ = 1, 10 do bars[#bars + 1] = 0 end

  return bars, nil
end

-- ---------------------------------------------------------------------------
-- Utility functions
-- ---------------------------------------------------------------------------

--- Decode bars array into run-length array of {color, width} entries.
function M.bar_widths(bars)
  if not bars or #bars == 0 then return {} end
  local runs = {}
  local cur_color = bars[1]
  local cur_width = 1
  for i = 2, #bars do
    if bars[i] == cur_color then
      cur_width = cur_width + 1
    else
      runs[#runs + 1] = {color = cur_color, width = cur_width}
      cur_color = bars[i]
      cur_width = 1
    end
  end
  runs[#runs + 1] = {color = cur_color, width = cur_width}
  return runs
end

--- Render bars array as an SVG string.
-- opts: { height=100, bar_width=2, quiet_zone=10, show_text=true, text="" }
function M.to_svg(bars, opts)
  opts = opts or {}
  local height     = opts.height     or 100
  local bar_width  = opts.bar_width  or 2
  local quiet_zone = opts.quiet_zone or 0
  local show_text  = opts.show_text
  if show_text == nil then show_text = true end
  local label      = opts.text or ""

  local total_width = (#bars + 2 * quiet_zone) * bar_width
  local text_height = (show_text and label ~= "") and 20 or 0
  local svg_height  = height + text_height

  local parts = {}
  parts[#parts + 1] = string.format(
    '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d">',
    total_width, svg_height
  )
  -- Background
  parts[#parts + 1] = string.format(
    '<rect width="%d" height="%d" fill="white"/>',
    total_width, svg_height
  )

  local x_offset = quiet_zone * bar_width
  for i = 1, #bars do
    if bars[i] == 1 then
      parts[#parts + 1] = string.format(
        '<rect x="%d" y="0" width="%d" height="%d" fill="black"/>',
        x_offset + (i - 1) * bar_width, bar_width, height
      )
    end
  end

  if show_text and label ~= "" then
    parts[#parts + 1] = string.format(
      '<text x="%d" y="%d" font-family="monospace" font-size="12" text-anchor="middle" fill="black">%s</text>',
      total_width / 2, height + 15, label
    )
  end

  parts[#parts + 1] = '</svg>'
  return table.concat(parts, "\n")
end

return M
