if not package.path:find("?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local vt = require("lib.vt")

local describe, it = T.describe, T.it

--:: Color = { space: "16" | "256" | "rgb", n: integer } | { space: "rgb", r: integer, g: integer, b: integer } | nil
--:: Cell = { char: string, fg: Color, bg: Color, bold: boolean, dim: boolean, underline: boolean, reverse: boolean, wide: boolean, _cont: boolean }

-- Helpers -------------------------------------------------------------------

local ESC = "\27["

-- Compare two terminals cell-by-cell. Returns true if every cell matches.
local function grids_equal(a, b)
  a = a --[[: { size: (self: unknown) -> (integer, integer), cell: (self: unknown, integer, integer) -> Cell }]]
  b = b --[[: { size: (self: unknown) -> (integer, integer), cell: (self: unknown, integer, integer) -> Cell }]]
  local ar, ac = a:size()
  local br, bc = b:size()
  if ar ~= br or ac ~= bc then return false, "size mismatch" end
  for r = 1, ar do
    for c = 1, ac do
      local ca = a:cell(r, c)
      local cb = b:cell(r, c)
      if ca.char ~= cb.char then
        return false, "char mismatch at " .. r .. "," .. c
          .. ": " .. ("%q"):format(ca.char) .. " vs " .. ("%q"):format(cb.char)
      end
      if ca.bold ~= cb.bold then
        return false, "bold mismatch at " .. r .. "," .. c
      end
      if ca.dim ~= cb.dim then
        return false, "dim mismatch at " .. r .. "," .. c
      end
      if ca.underline ~= cb.underline then
        return false, "underline mismatch at " .. r .. "," .. c
      end
      if ca.reverse ~= cb.reverse then
        return false, "reverse mismatch at " .. r .. "," .. c
      end
      -- Compare colors.
      local function ceq(x, y, label)
        if x == nil and y == nil then return true end
        if x == nil or y == nil then
          return false, label .. " nil mismatch at " .. r .. "," .. c
        end
        if x.space ~= y.space then
          return false, label .. " space mismatch at " .. r .. "," .. c
        end
        if x.space == "rgb" then
          if x.r ~= y.r or x.g ~= y.g or x.b ~= y.b then
            return false, label .. " rgb mismatch at " .. r .. "," .. c
          end
        else
          if x.n ~= y.n then
            return false, label .. " n mismatch at " .. r .. "," .. c
          end
        end
        return true
      end
      local ok, err = ceq(ca.fg, cb.fg, "fg")
      if not ok then return false, err end
      ok, err = ceq(ca.bg, cb.bg, "bg")
      if not ok then return false, err end
    end
  end
  return true
end

-- ── Basic text output ──────────────────────────────────────────────────────

describe("basic text output", function()
  it("fills cells left to right", function()
    local term = vt.new(10, 3)
    term:feed("ABC")
    T.eq(term:cell(1, 1).char, "A")
    T.eq(term:cell(1, 2).char, "B")
    T.eq(term:cell(1, 3).char, "C")
    T.eq(term:cell(1, 4).char, "")
    local cr, cc = term:cursor()
    T.eq(cr, 1); T.eq(cc, 4)
  end)

  it("wraps at right margin", function()
    local term = vt.new(5, 3)
    term:feed("ABCDE")
    -- After writing at col 5, cursor is at col 5 with wrap pending.
    local cr, cc = term:cursor()
    T.eq(cr, 1); T.eq(cc, 5)
    -- Next character triggers the wrap.
    term:feed("F")
    T.eq(term:cell(1, 5).char, "E")
    T.eq(term:cell(2, 1).char, "F")
    cr, cc = term:cursor()
    T.eq(cr, 2); T.eq(cc, 2)
  end)

  it("handles blank cells as empty string", function()
    local term = vt.new(5, 3)
    T.eq(term:cell(1, 1).char, "")
    T.eq(term:cell(3, 5).char, "")
  end)
end)

-- ── CR, LF, BS, HT ────────────────────────────────────────────────────────

describe("control characters", function()
  it("CR returns cursor to column 1", function()
    local term = vt.new(10, 3)
    term:feed("ABC\r")
    local cr, cc = term:cursor()
    T.eq(cr, 1); T.eq(cc, 1)
    -- Overwrite.
    term:feed("X")
    T.eq(term:cell(1, 1).char, "X")
    T.eq(term:cell(1, 2).char, "B")
  end)

  it("LF moves cursor down", function()
    local term = vt.new(10, 3)
    term:feed("A\nB")
    T.eq(term:cell(1, 1).char, "A")
    T.eq(term:cell(2, 2).char, "B") -- LF does not reset column
  end)

  it("LF at bottom scrolls", function()
    local term = vt.new(5, 3)
    term:feed("AAA\r\n")
    term:feed("BBB\r\n")
    term:feed("CCC\r\n") -- cursor on row 3, LF should scroll
    -- Row 1 should now be "BBB", row 2 "CCC", row 3 blank.
    T.eq(term:cell(1, 1).char, "B")
    T.eq(term:cell(2, 1).char, "C")
    T.eq(term:cell(3, 1).char, "")
  end)

  it("BS moves cursor left", function()
    local term = vt.new(10, 3)
    term:feed("AB\bC")
    T.eq(term:cell(1, 1).char, "A")
    T.eq(term:cell(1, 2).char, "C") -- overwrote B
  end)

  it("BS at column 1 does nothing", function()
    local term = vt.new(10, 3)
    term:feed("\b")
    local cr, cc = term:cursor()
    T.eq(cr, 1); T.eq(cc, 1)
  end)

  it("HT moves to next tab stop", function()
    local term = vt.new(40, 3)
    term:feed("\t")
    local cr, cc = term:cursor()
    T.eq(cr, 1); T.eq(cc, 9)
    term:feed("\t")
    cr, cc = term:cursor()
    T.eq(cr, 1); T.eq(cc, 17)
  end)

  it("HT from column 1 goes to 9", function()
    local term = vt.new(40, 3)
    term:feed("A\t")
    local _, cc = term:cursor()
    T.eq(cc, 9)
  end)
end)

-- ── Cursor movement (CSI) ──────────────────────────────────────────────────

describe("cursor movement", function()
  it("CUP positions cursor", function()
    local term = vt.new(10, 5)
    term:feed(ESC .. "3;7H")
    local cr, cc = term:cursor()
    T.eq(cr, 3); T.eq(cc, 7)
  end)

  it("CUP defaults to 1;1", function()
    local term = vt.new(10, 5)
    term:feed("ABCDE")
    term:feed(ESC .. "H")
    local cr, cc = term:cursor()
    T.eq(cr, 1); T.eq(cc, 1)
  end)

  it("CUP clamps to bounds", function()
    local term = vt.new(10, 5)
    term:feed(ESC .. "99;99H")
    local cr, cc = term:cursor()
    T.eq(cr, 5); T.eq(cc, 10)
  end)

  it("CUU moves cursor up", function()
    local term = vt.new(10, 5)
    term:feed(ESC .. "3;5H" .. ESC .. "1A")
    local cr, cc = term:cursor()
    T.eq(cr, 2); T.eq(cc, 5)
  end)

  it("CUD moves cursor down", function()
    local term = vt.new(10, 5)
    term:feed(ESC .. "1;1H" .. ESC .. "2B")
    local cr, cc = term:cursor()
    T.eq(cr, 3); T.eq(cc, 1)
  end)

  it("CUF moves cursor right", function()
    local term = vt.new(10, 5)
    term:feed(ESC .. "1;1H" .. ESC .. "3C")
    local cr, cc = term:cursor()
    T.eq(cr, 1); T.eq(cc, 4)
  end)

  it("CUB moves cursor left", function()
    local term = vt.new(10, 5)
    term:feed(ESC .. "1;5H" .. ESC .. "2D")
    local cr, cc = term:cursor()
    T.eq(cr, 1); T.eq(cc, 3)
  end)
end)

-- ── Erase (ED / EL) ───────────────────────────────────────────────────────

describe("erase", function()
  it("ED mode 0: cursor to end of screen", function()
    local term = vt.new(5, 3)
    term:feed("AAAAABBBBBCCCCC")
    term:feed(ESC .. "2;3H" .. ESC .. "0J")
    -- Row 1 intact.
    T.eq(term:cell(1, 1).char, "A")
    -- Row 2: cols 1-2 intact, cols 3-5 erased.
    T.eq(term:cell(2, 2).char, "B")
    T.eq(term:cell(2, 3).char, "")
    -- Row 3 erased.
    T.eq(term:cell(3, 1).char, "")
  end)

  it("ED mode 1: start of screen to cursor", function()
    local term = vt.new(5, 3)
    term:feed("AAAAABBBBBCCCCC")
    term:feed(ESC .. "2;3H" .. ESC .. "1J")
    -- Row 1 erased.
    T.eq(term:cell(1, 1).char, "")
    -- Row 2: cols 1-3 erased, cols 4-5 intact.
    T.eq(term:cell(2, 3).char, "")
    T.eq(term:cell(2, 4).char, "B")
    -- Row 3 intact.
    T.eq(term:cell(3, 1).char, "C")
  end)

  it("ED mode 2: entire screen", function()
    local term = vt.new(5, 3)
    term:feed("AAAAABBBBBCCCCC")
    term:feed(ESC .. "2J")
    for r = 1, 3 do
      for c = 1, 5 do T.eq(term:cell(r, c).char, "") end
    end
  end)

  it("EL mode 0: cursor to end of line", function()
    local term = vt.new(5, 3)
    term:feed("ABCDE")
    term:feed(ESC .. "1;3H" .. ESC .. "0K")
    T.eq(term:cell(1, 1).char, "A")
    T.eq(term:cell(1, 2).char, "B")
    T.eq(term:cell(1, 3).char, "")
    T.eq(term:cell(1, 4).char, "")
  end)

  it("EL mode 1: start of line to cursor", function()
    local term = vt.new(5, 3)
    term:feed("ABCDE")
    term:feed(ESC .. "1;3H" .. ESC .. "1K")
    T.eq(term:cell(1, 1).char, "")
    T.eq(term:cell(1, 2).char, "")
    T.eq(term:cell(1, 3).char, "")
    T.eq(term:cell(1, 4).char, "D")
  end)

  it("EL mode 2: entire line", function()
    local term = vt.new(5, 3)
    term:feed("ABCDE")
    term:feed(ESC .. "1;3H" .. ESC .. "2K")
    for c = 1, 5 do T.eq(term:cell(1, c).char, "") end
  end)
end)

-- ── SGR (attributes and colors) ────────────────────────────────────────────

describe("SGR", function()
  it("bold attribute", function()
    local term = vt.new(10, 3)
    term:feed(ESC .. "1m" .. "A" .. ESC .. "0m" .. "B")
    T.eq(term:cell(1, 1).bold, true)
    T.eq(term:cell(1, 2).bold, false)
  end)

  it("underline attribute", function()
    local term = vt.new(10, 3)
    term:feed(ESC .. "4m" .. "A" .. ESC .. "24m" .. "B")
    T.eq(term:cell(1, 1).underline, true)
    T.eq(term:cell(1, 2).underline, false)
  end)

  it("dim attribute", function()
    local term = vt.new(10, 3)
    term:feed(ESC .. "2m" .. "A" .. ESC .. "22m" .. "B")
    T.eq(term:cell(1, 1).dim, true)
    T.eq(term:cell(1, 2).dim, false)
  end)

  it("reverse attribute", function()
    local term = vt.new(10, 3)
    term:feed(ESC .. "7m" .. "A" .. ESC .. "27m" .. "B")
    T.eq(term:cell(1, 1).reverse, true)
    T.eq(term:cell(1, 2).reverse, false)
  end)

  it("SGR 0 resets all", function()
    local term = vt.new(10, 3)
    term:feed(ESC .. "1;4;7m" .. "A" .. ESC .. "0m" .. "B")
    local a = term:cell(1, 1)
    T.ok(a.bold); T.ok(a.underline); T.ok(a.reverse)
    local b = term:cell(1, 2)
    T.fail(b.bold); T.fail(b.underline); T.fail(b.reverse)
  end)

  it("16-color foreground", function()
    local term = vt.new(10, 3)
    term:feed(ESC .. "31m" .. "A")
    local cell = term:cell(1, 1)
    T.ok(cell.fg)
    T.eq(cell.fg.space, "16")
    T.eq(cell.fg.n, 1) -- red
  end)

  it("bright 16-color foreground", function()
    local term = vt.new(10, 3)
    term:feed(ESC .. "91m" .. "A")
    local cell = term:cell(1, 1)
    T.ok(cell.fg)
    T.eq(cell.fg.space, "16")
    T.eq(cell.fg.n, 9) -- bright red
  end)

  it("256-color foreground", function()
    local term = vt.new(10, 3)
    term:feed(ESC .. "38;5;196m" .. "A")
    local cell = term:cell(1, 1)
    T.ok(cell.fg)
    T.eq(cell.fg.space, "256")
    T.eq(cell.fg.n, 196)
  end)

  it("RGB foreground", function()
    local term = vt.new(10, 3)
    term:feed(ESC .. "38;2;100;150;200m" .. "A")
    local cell = term:cell(1, 1)
    T.ok(cell.fg)
    T.eq(cell.fg.space, "rgb")
    T.eq(cell.fg.r, 100)
    T.eq(cell.fg.g, 150)
    T.eq(cell.fg.b, 200)
  end)

  it("16-color background", function()
    local term = vt.new(10, 3)
    term:feed(ESC .. "42m" .. "A")
    local cell = term:cell(1, 1)
    T.ok(cell.bg)
    T.eq(cell.bg.space, "16")
    T.eq(cell.bg.n, 2) -- green
  end)

  it("256-color background", function()
    local term = vt.new(10, 3)
    term:feed(ESC .. "48;5;123m" .. "A")
    local cell = term:cell(1, 1)
    T.ok(cell.bg)
    T.eq(cell.bg.space, "256")
    T.eq(cell.bg.n, 123)
  end)

  it("RGB background", function()
    local term = vt.new(10, 3)
    term:feed(ESC .. "48;2;10;20;30m" .. "A")
    local cell = term:cell(1, 1)
    T.ok(cell.bg)
    T.eq(cell.bg.space, "rgb")
    T.eq(cell.bg.r, 10)
    T.eq(cell.bg.g, 20)
    T.eq(cell.bg.b, 30)
  end)

  it("default fg/bg via SGR 39/49", function()
    local term = vt.new(10, 3)
    term:feed(ESC .. "31;42m" .. "A" .. ESC .. "39;49m" .. "B")
    T.ok(term:cell(1, 1).fg)
    T.ok(term:cell(1, 1).bg)
    T.eq(term:cell(1, 2).fg, nil)
    T.eq(term:cell(1, 2).bg, nil)
  end)
end)

-- ── Alternate screen buffer ────────────────────────────────────────────────

describe("alternate screen buffer", function()
  it("DECSET 1049 switches to alt, DECRST 1049 restores main", function()
    local term = vt.new(5, 3)
    term:feed("MAIN!")
    term:feed(ESC .. "?1049h") -- switch to alt
    T.eq(term:cell(1, 1).char, "") -- alt screen is cleared
    term:feed("ALT!!")
    T.eq(term:cell(1, 1).char, "A")
    term:feed(ESC .. "?1049l") -- back to main
    T.eq(term:cell(1, 1).char, "M")
    T.eq(term:cell(1, 2).char, "A")
  end)

  it("DECSET 1049 saves and restores cursor", function()
    local term = vt.new(10, 5)
    term:feed(ESC .. "3;7H")
    term:feed(ESC .. "?1049h")
    local cr, cc = term:cursor()
    T.eq(cr, 1); T.eq(cc, 1) -- alt screen starts at 1,1
    term:feed(ESC .. "5;10H")
    term:feed(ESC .. "?1049l")
    cr, cc = term:cursor()
    T.eq(cr, 3); T.eq(cc, 7) -- restored to pre-switch position
  end)
end)

-- ── Scroll region (DECSTBM) ───────────────────────────────────────────────

describe("scroll region", function()
  it("LF at bottom of scroll region scrolls only the region", function()
    local term = vt.new(5, 5)
    -- Fill rows.
    term:feed("AAAAA\r\nBBBBB\r\nCCCCC\r\nDDDDD\r\nEEEEE")
    -- Set scroll region to rows 2-4.
    term:feed(ESC .. "2;4r")
    -- Cursor moves to 1,1 after DECSTBM.
    local cr, cc = term:cursor()
    T.eq(cr, 1); T.eq(cc, 1)
    -- Move cursor to row 4 (bottom of scroll region), then LF.
    term:feed(ESC .. "4;1H" .. "\n")
    -- Row 1 untouched.
    T.eq(term:cell(1, 1).char, "A")
    -- Row 5 untouched.
    T.eq(term:cell(5, 1).char, "E")
    -- Region scrolled: old row 3 -> row 2, old row 4 -> row 3, row 4 is blank.
    T.eq(term:cell(2, 1).char, "C")
    T.eq(term:cell(3, 1).char, "D")
    T.eq(term:cell(4, 1).char, "")
  end)

  it("reverse index at top of scroll region scrolls down", function()
    local term = vt.new(5, 5)
    term:feed("AAAAA\r\nBBBBB\r\nCCCCC\r\nDDDDD\r\nEEEEE")
    term:feed(ESC .. "2;4r")
    -- Move to top of scroll region.
    term:feed(ESC .. "2;1H")
    -- Reverse index (ESC M).
    term:feed("\27M")
    -- Row 1 untouched.
    T.eq(term:cell(1, 1).char, "A")
    -- Row 5 untouched.
    T.eq(term:cell(5, 1).char, "E")
    -- Region scrolled down: row 2 blank, old row 2 -> row 3, old row 3 -> row 4.
    T.eq(term:cell(2, 1).char, "")
    T.eq(term:cell(3, 1).char, "B")
    T.eq(term:cell(4, 1).char, "C")
  end)
end)

-- ── Resize ─────────────────────────────────────────────────────────────────

describe("resize", function()
  it("grow preserves content", function()
    local term = vt.new(5, 3)
    term:feed("ABCDE")
    term:resize(5, 8) -- 5 rows, 8 cols
    T.eq(term:cell(1, 1).char, "A")
    T.eq(term:cell(1, 5).char, "E")
    T.eq(term:cell(1, 6).char, "") -- new column
    T.eq(term:cell(4, 1).char, "") -- new row
    local rows, cols = term:size()
    T.eq(rows, 5); T.eq(cols, 8)
  end)

  it("shrink truncates and clamps cursor", function()
    local term = vt.new(10, 5)
    term:feed(ESC .. "5;10H")
    term:resize(3, 4) -- 3 rows, 4 cols
    local cr, cc = term:cursor()
    T.eq(cr, 3); T.eq(cc, 4) -- clamped
    local rows, cols = term:size()
    T.eq(rows, 3); T.eq(cols, 4)
  end)

  it("resets scroll region when it no longer fits", function()
    local term = vt.new(10, 10)
    term:feed(ESC .. "3;8r") -- scroll region rows 3-8
    term:resize(5, 10) -- 5 rows, 10 cols — region 3-8 doesn't fit
    -- After resize, region should be reset to full screen (1-5).
    -- Verify by checking that LF at row 5 scrolls the whole screen.
    term:feed(ESC .. "5;1H")
    term:feed("XXXXX\n")
    -- If scroll region were still 3-8 (invalid), behavior would be wrong.
    -- With region 1-5, row 1 scrolls out and row 5 is blank.
    T.eq(term:cell(4, 1).char, "X")
    T.eq(term:cell(5, 1).char, "")
  end)
end)

-- ── Wide characters ────────────────────────────────────────────────────────

describe("wide characters", function()
  it("CJK character occupies two cells", function()
    -- U+4E16 (CJK Unified Ideograph)
    local term = vt.new(10, 3)
    term:feed("\xe4\xb8\x96") -- U+4E16
    T.eq(term:cell(1, 1).char, "\xe4\xb8\x96")
    T.eq(term:cell(1, 1).wide, true)
    T.eq(term:cell(1, 2)._cont, true)
    T.eq(term:cell(1, 2).char, "")
    local _, cc = term:cursor()
    T.eq(cc, 3)
  end)

  it("overwriting first half of wide char clears continuation", function()
    local term = vt.new(10, 3)
    term:feed("\xe4\xb8\x96") -- wide at 1,2
    term:feed(ESC .. "1;1H" .. "X")
    T.eq(term:cell(1, 1).char, "X")
    T.eq(term:cell(1, 1).wide, false)
    T.eq(term:cell(1, 2)._cont, false)
    T.eq(term:cell(1, 2).char, "")
  end)

  it("overwriting second half of wide char clears first half", function()
    local term = vt.new(10, 3)
    term:feed("\xe4\xb8\x96") -- wide at col 1-2
    term:feed(ESC .. "1;2H" .. "X")
    T.eq(term:cell(1, 1).char, "")
    T.eq(term:cell(1, 1).wide, false)
    T.eq(term:cell(1, 2).char, "X")
    T.eq(term:cell(1, 2)._cont, false)
  end)

  it("wide char at last column wraps", function()
    local term = vt.new(5, 3)
    term:feed("ABCD") -- cursor at col 5
    term:feed("\xe4\xb8\x96") -- can't fit at col 5
    -- Col 5 should be blank (cleared), wide char wraps to row 2.
    T.eq(term:cell(1, 5).char, "")
    T.eq(term:cell(2, 1).char, "\xe4\xb8\x96")
    T.eq(term:cell(2, 1).wide, true)
    T.eq(term:cell(2, 2)._cont, true)
  end)
end)

-- ── Snapshot round-trip ────────────────────────────────────────────────────

describe("snapshot", function()
  it("round-trips basic content", function()
    local term = vt.new(10, 3)
    term:feed("Hello!")
    term:feed(ESC .. "2;1H" .. "World")
    local snap = term:snapshot()
    local term2 = vt.new(10, 3)
    term2:feed(snap)
    local ok, err = grids_equal(term, term2)
    T.ok(ok, err)
  end)

  it("round-trips colored content", function()
    local term = vt.new(10, 3)
    term:feed(ESC .. "1;31m" .. "Red" .. ESC .. "0m" .. " plain")
    local snap = term:snapshot()
    local term2 = vt.new(10, 3)
    term2:feed(snap)
    local ok, err = grids_equal(term, term2)
    T.ok(ok, err)
  end)

  it("round-trips cursor position", function()
    local term = vt.new(10, 5)
    term:feed("Hello")
    term:feed(ESC .. "3;7H")
    local snap = term:snapshot()
    local term2 = vt.new(10, 5)
    term2:feed(snap)
    local cr, cc = term2:cursor()
    T.eq(cr, 3); T.eq(cc, 7)
  end)

  it("round-trips 256-color", function()
    local term = vt.new(10, 3)
    term:feed(ESC .. "38;5;196m" .. "A" .. ESC .. "48;5;21m" .. "B")
    local snap = term:snapshot()
    local term2 = vt.new(10, 3)
    term2:feed(snap)
    local ok, err = grids_equal(term, term2)
    T.ok(ok, err)
  end)

  it("round-trips RGB color", function()
    local term = vt.new(10, 3)
    term:feed(ESC .. "38;2;100;150;200m" .. "A")
    local snap = term:snapshot()
    local term2 = vt.new(10, 3)
    term2:feed(snap)
    local ok, err = grids_equal(term, term2)
    T.ok(ok, err)
  end)

  it("round-trips alternate screen", function()
    local term = vt.new(5, 3)
    term:feed("MAIN!")
    term:feed(ESC .. "?1049h")
    term:feed("ALT!!")
    local snap = term:snapshot()
    local term2 = vt.new(5, 3)
    term2:feed(snap)
    -- Should be on alt screen with "ALT!!" visible.
    T.eq(term2:cell(1, 1).char, "A")
    T.eq(term2:cell(1, 2).char, "L")
    -- Switch back to main — should have "MAIN!".
    term2:feed(ESC .. "?1049l")
    T.eq(term2:cell(1, 1).char, "M")
    T.eq(term2:cell(1, 2).char, "A")
  end)

  it("round-trips cursor visibility", function()
    local term = vt.new(10, 3)
    term:feed(ESC .. "?25l") -- hide cursor
    T.eq(term:cursor_visible(), false)
    local snap = term:snapshot()
    local term2 = vt.new(10, 3)
    term2:feed(snap)
    T.eq(term2:cursor_visible(), false)
  end)

  it("round-trips scroll region", function()
    local term = vt.new(10, 5)
    -- Write content, set scroll region 2-4, position cursor.
    term:feed("AAAAAAAAAA\r\nBBBBBBBBBB\r\nCCCCCCCCCC\r\nDDDDDDDDDD\r\nEEEEEEEEEE")
    term:feed(ESC .. "2;4r")
    term:feed(ESC .. "3;5H")
    local snap = term:snapshot()
    local term2 = vt.new(10, 5)
    term2:feed(snap)
    -- Verify content.
    local ok, err = grids_equal(term, term2)
    T.ok(ok, err)
    -- Verify cursor.
    local cr, cc = term2:cursor()
    T.eq(cr, 3); T.eq(cc, 5)
  end)

  it("round-trips multiple attributes", function()
    local term = vt.new(10, 3)
    term:feed(ESC .. "1;2;4;7;31;42m" .. "X" .. ESC .. "0m" .. "Y")
    local snap = term:snapshot()
    local term2 = vt.new(10, 3)
    term2:feed(snap)
    local ok, err = grids_equal(term, term2)
    T.ok(ok, err)
    local c = term2:cell(1, 1)
    T.ok(c.bold); T.ok(c.dim); T.ok(c.underline); T.ok(c.reverse)
    T.eq(c.fg.space, "16"); T.eq(c.fg.n, 1)
    T.eq(c.bg.space, "16"); T.eq(c.bg.n, 2)
  end)
end)

-- ── Edge cases ─────────────────────────────────────────────────────────────

describe("edge cases", function()
  it("ESC c resets terminal", function()
    local term = vt.new(10, 3)
    term:feed(ESC .. "1;31m" .. "Hello")
    term:feed("\27c")
    -- Screen should be cleared and attributes reset.
    T.eq(term:cell(1, 1).char, "")
    local cr, cc = term:cursor()
    T.eq(cr, 1); T.eq(cc, 1)
  end)

  it("ignores OSC sequences", function()
    local term = vt.new(10, 3)
    -- OSC 0 (set title) terminated by BEL.
    term:feed("\27]0;my title\7" .. "A")
    T.eq(term:cell(1, 1).char, "A")
  end)

  it("ignores DCS sequences", function()
    local term = vt.new(10, 3)
    -- DCS terminated by ST (ESC \).
    term:feed("\27Psomething\27\\" .. "B")
    T.eq(term:cell(1, 1).char, "B")
  end)

  it("cell out of bounds returns nil + error", function()
    local term = vt.new(5, 3)
    local c, err = term:cell(0, 1)
    T.eq(c, nil)
    T.ok(err)
    c, err = term:cell(4, 1)
    T.eq(c, nil)
    T.ok(err)
  end)

  it("partial UTF-8 across feed calls", function()
    local term = vt.new(10, 3)
    local s = "\xe4\xb8\x96" -- U+4E16, 3-byte UTF-8
    -- Split across two feeds.
    term:feed(s:sub(1, 1))
    term:feed(s:sub(2))
    T.eq(term:cell(1, 1).char, s)
    T.eq(term:cell(1, 1).wide, true)
  end)

  it("DECSC / DECRC (ESC 7 / ESC 8) save and restore cursor", function()
    local term = vt.new(10, 5)
    term:feed(ESC .. "3;7H")
    term:feed("\0277") -- ESC 7
    term:feed(ESC .. "1;1H")
    term:feed("\0278") -- ESC 8
    local cr, cc = term:cursor()
    T.eq(cr, 3); T.eq(cc, 7)
  end)
end)
