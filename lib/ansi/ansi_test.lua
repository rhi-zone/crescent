if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T    = require("lib.test.assert")
local ansi = require("lib.ansi")

-- Ensure enabled for all tests (override env detection).
local orig_enabled = ansi.enabled
ansi.enabled = true

T.describe("ansi", function()

  T.describe("styles", function()
    T.it("bold wraps string with bold escape and reset", function()
      local s = ansi.bold("x")
      T.ok(s:find("\27%[1m", 1, false), "contains bold open")
      T.ok(s:find("x", 1, true), "contains the string")
      T.ok(s:find("\27%[0m", 1, false), "contains reset")
    end)

    T.it("bold with no arg returns just the escape sequence", function()
      local s = ansi.bold()
      T.eq(s, "\27[1m")
    end)

    T.it("dim wraps string", function()
      local s = ansi.dim("d")
      T.ok(s:find("\27%[2m", 1, false))
      T.ok(s:find("d", 1, true))
    end)

    T.it("italic wraps string", function()
      local s = ansi.italic("i")
      T.ok(s:find("\27%[3m", 1, false))
    end)

    T.it("underline wraps string", function()
      local s = ansi.underline("u")
      T.ok(s:find("\27%[4m", 1, false))
    end)

    T.it("blink wraps string", function()
      local s = ansi.blink("b")
      T.ok(s:find("\27%[5m", 1, false))
    end)

    T.it("reverse wraps string", function()
      local s = ansi.reverse("r")
      T.ok(s:find("\27%[7m", 1, false))
    end)

    T.it("strikethrough wraps string", function()
      local s = ansi.strikethrough("s")
      T.ok(s:find("\27%[9m", 1, false))
    end)
  end)

  T.describe("4-bit foreground colors", function()
    T.it("red wraps string with red escape and reset", function()
      local s = ansi.red("hello")
      T.ok(s:find("\27%[31m", 1, false), "contains red open")
      T.ok(s:find("hello", 1, true), "contains text")
      T.ok(s:find("\27%[0m", 1, false), "contains reset")
    end)

    T.it("red with no arg returns just the escape sequence", function()
      local s = ansi.red()
      T.eq(s, "\27[31m")
    end)

    T.it("green works", function()
      T.ok(ansi.green("g"):find("\27%[32m", 1, false))
    end)

    T.it("yellow works", function()
      T.ok(ansi.yellow("y"):find("\27%[33m", 1, false))
    end)

    T.it("blue works", function()
      T.ok(ansi.blue("b"):find("\27%[34m", 1, false))
    end)

    T.it("magenta works", function()
      T.ok(ansi.magenta("m"):find("\27%[35m", 1, false))
    end)

    T.it("cyan works", function()
      T.ok(ansi.cyan("c"):find("\27%[36m", 1, false))
    end)

    T.it("white works", function()
      T.ok(ansi.white("w"):find("\27%[37m", 1, false))
    end)

    T.it("black works", function()
      T.ok(ansi.black("k"):find("\27%[30m", 1, false))
    end)

    T.it("bright_red works", function()
      T.ok(ansi.bright_red("br"):find("\27%[91m", 1, false))
    end)
  end)

  T.describe("4-bit background colors", function()
    T.it("bg_red wraps string", function()
      local s = ansi.bg_red("hello")
      T.ok(s:find("\27%[41m", 1, false))
      T.ok(s:find("hello", 1, true))
    end)

    T.it("bg_bright_blue works", function()
      T.ok(ansi.bg_bright_blue("x"):find("\27%[104m", 1, false))
    end)
  end)

  T.describe("8-bit colors", function()
    T.it("fg256 wraps string", function()
      local s = ansi.fg256(200, "hi")
      T.ok(s:find("38;5;200", 1, true), "contains 256-color fg code")
      T.ok(s:find("hi", 1, true))
    end)

    T.it("fg256 with no string returns sequence", function()
      local s = ansi.fg256(100)
      T.ok(s:find("38;5;100", 1, true))
      T.ok(not s:find("\27%[0m", 1, false), "no reset when no string")
    end)

    T.it("bg256 wraps string", function()
      local s = ansi.bg256(50, "bg")
      T.ok(s:find("48;5;50", 1, true))
      T.ok(s:find("bg", 1, true))
    end)
  end)

  T.describe("24-bit true color", function()
    T.it("fg RGB wraps string", function()
      local s = ansi.fg(255, 0, 0, "red")
      T.ok(s:find("38;2;255;0;0", 1, true), "contains truecolor fg code")
      T.ok(s:find("red", 1, true))
      T.ok(s:find("\27%[0m", 1, false), "ends with reset")
    end)

    T.it("fg RGB with no string returns sequence", function()
      local s = ansi.fg(0, 128, 255)
      T.ok(s:find("38;2;0;128;255", 1, true))
    end)

    T.it("bg RGB wraps string", function()
      local s = ansi.bg(0, 255, 0, "green")
      T.ok(s:find("48;2;0;255;0", 1, true), "contains truecolor bg code")
      T.ok(s:find("green", 1, true))
    end)
  end)

  T.describe("cursor movement", function()
    T.it("up produces correct sequence", function()
      T.eq(ansi.up(3), "\27[3A")
    end)

    T.it("down produces correct sequence", function()
      T.eq(ansi.down(2), "\27[2B")
    end)

    T.it("right produces correct sequence", function()
      T.eq(ansi.right(5), "\27[5C")
    end)

    T.it("left produces correct sequence", function()
      T.eq(ansi.left(1), "\27[1D")
    end)

    T.it("move_to produces correct sequence (1-indexed)", function()
      T.eq(ansi.move_to(1, 1), "\27[1;1H")
      T.eq(ansi.move_to(10, 20), "\27[10;20H")
    end)

    T.it("ansi['goto'] is an alias for move_to", function()
      T.eq(ansi["goto"](5, 10), "\27[5;10H")
    end)

    T.it("home produces correct sequence", function()
      T.eq(ansi.home(), "\27[H")
    end)

    T.it("save_pos produces correct sequence", function()
      T.eq(ansi.save_pos(), "\27[s")
    end)

    T.it("restore_pos produces correct sequence", function()
      T.eq(ansi.restore_pos(), "\27[u")
    end)
  end)

  T.describe("terminal control", function()
    T.it("clear", function()
      T.eq(ansi.clear(), "\27[2J")
    end)

    T.it("clear_line", function()
      T.eq(ansi.clear_line(), "\27[2K")
    end)

    T.it("clear_to_eol", function()
      T.eq(ansi.clear_to_eol(), "\27[0K")
    end)

    T.it("hide_cursor", function()
      T.eq(ansi.hide_cursor(), "\27[?25l")
    end)

    T.it("show_cursor", function()
      T.eq(ansi.show_cursor(), "\27[?25h")
    end)

    T.it("enter_alt_screen", function()
      T.eq(ansi.enter_alt_screen(), "\27[?1049h")
    end)

    T.it("exit_alt_screen", function()
      T.eq(ansi.exit_alt_screen(), "\27[?1049l")
    end)
  end)

  T.describe("strip", function()
    T.it("removes bold+color escape sequences", function()
      T.eq(ansi.strip("\27[1;31mhello\27[0m"), "hello")
    end)

    T.it("removes truecolor sequences", function()
      T.eq(ansi.strip("\27[38;2;255;0;0mred\27[0m"), "red")
    end)

    T.it("passes plain strings through unchanged", function()
      T.eq(ansi.strip("plain text"), "plain text")
    end)

    T.it("handles multiple sequences in one string", function()
      T.eq(ansi.strip("\27[1mhello\27[0m \27[32mworld\27[0m"), "hello world")
    end)

    T.it("round-trips with colored output", function()
      local colored = ansi.red("hello")
      T.eq(ansi.strip(colored), "hello")
    end)
  end)

  T.describe("len", function()
    T.it("returns printable length excluding escapes", function()
      T.eq(ansi.len("\27[1mhi\27[0m"), 2)
    end)

    T.it("returns full length for plain strings", function()
      T.eq(ansi.len("hello"), 5)
    end)

    T.it("returns 0 for empty string", function()
      T.eq(ansi.len(""), 0)
    end)

    T.it("works on red-wrapped string", function()
      T.eq(ansi.len(ansi.red("hello")), 5)
    end)
  end)

  T.describe("reset constant", function()
    T.it("is the correct escape sequence", function()
      T.eq(ansi.reset, "\27[0m")
    end)
  end)

  T.describe("NO_COLOR / enabled=false", function()
    T.it("red returns string unchanged when disabled", function()
      ansi.enabled = false
      T.eq(ansi.red("x"), "x")
      ansi.enabled = true
    end)

    T.it("bold returns string unchanged when disabled", function()
      ansi.enabled = false
      T.eq(ansi.bold("x"), "x")
      ansi.enabled = true
    end)

    T.it("fg256 returns string unchanged when disabled", function()
      ansi.enabled = false
      T.eq(ansi.fg256(100, "x"), "x")
      ansi.enabled = true
    end)

    T.it("fg returns string unchanged when disabled", function()
      ansi.enabled = false
      T.eq(ansi.fg(255, 0, 0, "red"), "red")
      ansi.enabled = true
    end)

    T.it("color functions return empty string when disabled and no string given", function()
      ansi.enabled = false
      T.eq(ansi.red(), "")
      T.eq(ansi.fg256(100), "")
      T.eq(ansi.fg(255, 0, 0), "")
      ansi.enabled = true
    end)

    T.it("strip still works when disabled", function()
      ansi.enabled = false
      T.eq(ansi.strip("\27[31mhello\27[0m"), "hello")
      ansi.enabled = true
    end)
  end)

end)

-- Restore original enabled state.
ansi.enabled = orig_enabled
