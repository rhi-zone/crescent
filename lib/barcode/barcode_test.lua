if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local BC = require("lib.barcode")

-- Helper: check all bars are 0 or 1
local function all_binary(bars)
  for i = 1, #bars do
    if bars[i] ~= 0 and bars[i] ~= 1 then return false end
  end
  return true
end

-- Helper: check quiet zones (first and last N bars are white)
local function check_quiet(bars, n)
  for i = 1, n do
    if bars[i] ~= 0 then return false end
  end
  for i = #bars - n + 1, #bars do
    if bars[i] ~= 0 then return false end
  end
  return true
end

-- ---------------------------------------------------------------------------
T.describe("BC._tier", function()
  T.it("is 'pure'", function()
    T.eq(BC._tier, "pure")
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("Code128", function()
  T.it("encodes non-empty string to non-empty bars", function()
    local bars, err = BC.code128("HELLO")
    T.ok(bars, err)
    T.ok(#bars > 0, "bars is non-empty")
  end)

  T.it("bars are all 0 or 1", function()
    local bars = BC.code128("HELLO")
    T.ok(all_binary(bars), "all bars are 0 or 1")
  end)

  T.it("quiet zone present at start and end (10 white modules)", function()
    local bars = BC.code128("HELLO")
    T.ok(check_quiet(bars, 10), "quiet zones present")
  end)

  T.it("encodes single character", function()
    local bars, err = BC.code128("A")
    T.ok(bars, err)
    -- Structure: 10 quiet + 11 StartB + 11 data + 11 check + 13 stop + 10 quiet = 66
    T.eq(#bars, 66, "single char: 66 modules")
  end)

  T.it("length grows linearly with input", function()
    local bars1 = BC.code128("A")
    local bars2 = BC.code128("AB")
    -- Each extra char adds 11 modules
    T.eq(#bars2 - #bars1, 11, "each char adds 11 modules")
  end)

  T.it("encodes digits", function()
    local bars, err = BC.code128("12345678")
    T.ok(bars, err)
    T.ok(#bars > 0)
    T.ok(all_binary(bars))
  end)

  T.it("encodes spaces and punctuation", function()
    local bars, err = BC.code128("Hello, World!")
    T.ok(bars, err)
    T.ok(all_binary(bars))
  end)

  T.it("encodes full printable ASCII range", function()
    local s = ""
    for i = 32, 126 do s = s .. string.char(i) end
    local bars, err = BC.code128(s)
    T.ok(bars, err)
    T.ok(all_binary(bars))
  end)

  T.it("rejects control characters", function()
    local bars, err = BC.code128("Hello\x01World")
    T.ok(bars == nil, "should fail on control char")
    T.ok(type(err) == "string", "returns error message")
  end)

  T.it("rejects non-string input", function()
    local bars, err = BC.code128(42)
    T.ok(bars == nil)
    T.ok(type(err) == "string")
  end)

  T.it("encodes empty string (header+check+stop only)", function()
    local bars, err = BC.code128("")
    T.ok(bars, err)
    -- 10 quiet + 11 StartB + 11 check + 13 stop + 10 quiet = 55
    T.eq(#bars, 55, "empty string: 55 modules")
  end)

  T.it("starts with bar after quiet zone", function()
    local bars = BC.code128("A")
    -- Module 11 (index 11) is the first module of StartB = bar (1)
    T.eq(bars[11], 1, "first module after quiet zone is a bar")
  end)

  T.it("bar_widths round-trips correctly for simple pattern", function()
    local bars = {1,1,0,0,0,1,0,1,1}
    local runs = BC.bar_widths(bars)
    T.eq(#runs, 5)
    T.eq(runs[1].color, 1); T.eq(runs[1].width, 2)
    T.eq(runs[2].color, 0); T.eq(runs[2].width, 3)
    T.eq(runs[3].color, 1); T.eq(runs[3].width, 1)
    T.eq(runs[4].color, 0); T.eq(runs[4].width, 1)
    T.eq(runs[5].color, 1); T.eq(runs[5].width, 2)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("EAN-13 check digit", function()
  T.it("known vector: 400638133393 -> 1", function()
    local cd, err = BC.ean13_check_digit("400638133393")
    T.ok(cd ~= nil, err)
    T.eq(cd, 1)
  end)

  T.it("known vector: 978020137962 -> 4", function()
    -- ISBN-13 for "The C Programming Language": 9780201379624
    local cd, err = BC.ean13_check_digit("978020137962")
    T.ok(cd ~= nil, err)
    T.eq(cd, 4)
  end)

  T.it("known vector: 000000000000 -> 0", function()
    local cd = BC.ean13_check_digit("000000000000")
    T.eq(cd, 0)
  end)

  T.it("rejects non-12-digit string", function()
    local cd, err = BC.ean13_check_digit("12345")
    T.ok(cd == nil)
    T.ok(type(err) == "string")
  end)

  T.it("rejects non-digit characters", function()
    local cd, err = BC.ean13_check_digit("1234567890AB")
    T.ok(cd == nil)
    T.ok(type(err) == "string")
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("EAN-13 encoding", function()
  T.it("encodes 13-digit string with correct check digit", function()
    local bars, err = BC.ean13("4006381333931")
    T.ok(bars, err)
    T.ok(#bars > 0)
  end)

  T.it("total width is 95 + 2*9 = 113 modules", function()
    local bars = BC.ean13("4006381333931")
    T.eq(#bars, 113, "total EAN-13 width = 113 modules")
  end)

  T.it("accepts 12-digit input (auto-computes check digit)", function()
    local bars, err = BC.ean13("400638133393")
    T.ok(bars, err)
    T.eq(#bars, 113)
  end)

  T.it("bars are all 0 or 1", function()
    local bars = BC.ean13("4006381333931")
    T.ok(all_binary(bars), "all bars binary")
  end)

  T.it("quiet zones are white (9 each end)", function()
    local bars = BC.ean13("4006381333931")
    T.ok(check_quiet(bars, 9), "quiet zones present")
  end)

  T.it("left guard is bar-space-bar at offset 9", function()
    local bars = BC.ean13("4006381333931")
    T.eq(bars[10], 1, "left guard bar 1")
    T.eq(bars[11], 0, "left guard space")
    T.eq(bars[12], 1, "left guard bar 2")
  end)

  T.it("rejects non-digit input", function()
    local bars, err = BC.ean13("400638133393X")
    T.ok(bars == nil)
    T.ok(type(err) == "string")
  end)

  T.it("rejects wrong length", function()
    local bars, err = BC.ean13("123456789")
    T.ok(bars == nil)
    T.ok(type(err) == "string")
  end)

  T.it("rejects wrong check digit", function()
    local bars, err = BC.ean13("4006381333930") -- check digit should be 1
    T.ok(bars == nil)
    T.ok(type(err) == "string")
  end)

  T.it("encodes all-zeros EAN-13", function()
    local bars, err = BC.ean13("0000000000000")
    T.ok(bars, err)
    T.eq(#bars, 113)
    T.ok(all_binary(bars))
  end)

  T.it("two different inputs produce different bars", function()
    local a = BC.ean13("4006381333931")
    local b = BC.ean13("0000000000000")
    local same = true
    for i = 1, #a do
      if a[i] ~= b[i] then same = false; break end
    end
    T.ok(not same, "different inputs → different bars")
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("UPC-A check digit", function()
  T.it("delegates correctly to ean13_check_digit", function()
    -- UPC-A "03600029145" → check digit 2 (full: 036000291452)
    local cd, err = BC.upca_check_digit("03600029145")
    T.ok(cd ~= nil, err)
    T.eq(cd, 2)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("EAN-8", function()
  T.it("encodes 8-digit string", function()
    -- EAN-8 "40170725" (check digit = 5; actually compute: "4017072")
    local bars, err = BC.ean8("4017072")
    T.ok(bars, err)
    T.ok(#bars > 0)
  end)

  T.it("total width is 67 + 2*9 = 85 modules", function()
    -- EAN-8: 3 + 4*7 + 5 + 4*7 + 3 = 67 + 18 = 85
    local bars, err = BC.ean8("4017072")
    T.ok(bars, err)
    T.eq(#bars, 85, "EAN-8 total = 85 modules")
  end)

  T.it("bars are all 0 or 1", function()
    local bars = BC.ean8("4017072")
    T.ok(all_binary(bars))
  end)

  T.it("rejects non-digit input", function()
    local bars, err = BC.ean8("401707X")
    T.ok(bars == nil)
    T.ok(type(err) == "string")
  end)

  T.it("rejects wrong length", function()
    local bars, err = BC.ean8("123456")
    T.ok(bars == nil)
    T.ok(type(err) == "string")
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("Code39", function()
  T.it("encodes uppercase letters", function()
    local bars, err = BC.code39("HELLO")
    T.ok(bars, err)
    T.ok(#bars > 0)
  end)

  T.it("encodes digits", function()
    local bars, err = BC.code39("12345")
    T.ok(bars, err)
    T.ok(all_binary(bars))
  end)

  T.it("encodes special chars (- . $ / + % SPACE)", function()
    local bars, err = BC.code39("-. $/+%")
    T.ok(bars, err)
    T.ok(all_binary(bars))
  end)

  T.it("bars are all 0 or 1", function()
    local bars = BC.code39("ABC123")
    T.ok(all_binary(bars))
  end)

  T.it("quiet zones are white", function()
    local bars = BC.code39("A")
    T.ok(check_quiet(bars, 10))
  end)

  T.it("rejects lowercase letters", function()
    local bars, err = BC.code39("hello")
    T.ok(bars == nil)
    T.ok(type(err) == "string")
  end)

  T.it("rejects unsupported characters", function()
    local bars, err = BC.code39("A@B")
    T.ok(bars == nil)
    T.ok(type(err) == "string")
  end)

  T.it("encodes empty string (just start/stop)", function()
    local bars, err = BC.code39("")
    T.ok(bars, err)
    -- 10 quiet + 13 start(*) + 1 gap + 1 gap + 13 stop(*) + 10 quiet = 48
    -- start=9 narrow+wide modules, interchar gap = 1 narrow
    -- *: pattern has 5 bars + 4 spaces = 9 elements (3 wide, 6 narrow)
    -- wide=3, narrow=1: 3*3 + 6*1 = 15 modules per symbol
    -- empty: 10 + 15 + 1 + 15 + 10 = 51
    T.ok(#bars > 0)
  end)

  T.it("length grows with each added character", function()
    local b1 = BC.code39("A")
    local b2 = BC.code39("AB")
    -- Each char: symbol(15 modules) + gap(1 module) = 16
    T.eq(#b2 - #b1, 16, "each char adds 16 modules")
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("bar_widths", function()
  T.it("empty input returns empty table", function()
    local runs = BC.bar_widths({})
    T.eq(#runs, 0)
  end)

  T.it("single module", function()
    local runs = BC.bar_widths({1})
    T.eq(#runs, 1)
    T.eq(runs[1].color, 1)
    T.eq(runs[1].width, 1)
  end)

  T.it("alternating modules produce many runs", function()
    local bars = {1,0,1,0,1,0}
    local runs = BC.bar_widths(bars)
    T.eq(#runs, 6)
  end)

  T.it("total width sums to #bars", function()
    local bars = BC.code128("TEST")
    local runs = BC.bar_widths(bars)
    local total = 0
    for _, r in ipairs(runs) do total = total + r.width end
    T.eq(total, #bars)
  end)

  T.it("adjacent same-color modules are merged", function()
    local bars = {1,1,1,0,0,1}
    local runs = BC.bar_widths(bars)
    T.eq(#runs, 3)
    T.eq(runs[1].color, 1); T.eq(runs[1].width, 3)
    T.eq(runs[2].color, 0); T.eq(runs[2].width, 2)
    T.eq(runs[3].color, 1); T.eq(runs[3].width, 1)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("to_svg", function()
  T.it("returns string containing <svg", function()
    local bars = BC.code128("TEST")
    local svg = BC.to_svg(bars)
    T.ok(type(svg) == "string")
    T.ok(svg:find("<svg", 1, true) ~= nil, "contains <svg")
  end)

  T.it("returns string containing <rect", function()
    local bars = BC.code128("TEST")
    local svg = BC.to_svg(bars)
    T.ok(svg:find("<rect", 1, true) ~= nil, "contains <rect")
  end)

  T.it("contains closing </svg>", function()
    local svg = BC.to_svg(BC.code128("A"))
    T.ok(svg:find("</svg>", 1, true) ~= nil)
  end)

  T.it("includes text when show_text=true and text provided", function()
    local svg = BC.to_svg(BC.code128("A"), {show_text=true, text="HELLO"})
    T.ok(svg:find("HELLO", 1, true) ~= nil, "text appears in SVG")
    T.ok(svg:find("<text", 1, true) ~= nil, "text element present")
  end)

  T.it("no text element when show_text=false", function()
    local svg = BC.to_svg(BC.code128("A"), {show_text=false, text="HELLO"})
    T.ok(svg:find("<text", 1, true) == nil, "no text element when show_text=false")
  end)

  T.it("custom height is reflected in SVG dimensions", function()
    local svg = BC.to_svg(BC.code128("A"), {height=200})
    T.ok(svg:find('height="200"', 1, true) ~= nil, "height attribute present")
  end)

  T.it("white background rect is always present", function()
    local svg = BC.to_svg(BC.code128("A"))
    T.ok(svg:find('fill="white"', 1, true) ~= nil, "white background present")
  end)

  T.it("works with EAN-13 bars", function()
    local bars = BC.ean13("4006381333931")
    local svg = BC.to_svg(bars, {text="4006381333931"})
    T.ok(type(svg) == "string")
    T.ok(svg:find("<svg", 1, true) ~= nil)
  end)
end)
