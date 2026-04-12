if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local H = require("lib.hex_dump")

T.describe("hex_dump", function()

  -- dump: basic cases
  T.describe("dump", function()
    T.it("empty string produces single line with address", function()
      local s = H.dump("")
      -- Single line, no newline
      T.ok(not s:find("\n"), "no newline")
      T.ok(s:find("00000000"), "has address")
      -- ASCII column is all spaces
      T.ok(s:find("|" .. string.rep(" ", 16) .. "|"), "ascii column is spaces")
    end)

    T.it("single byte", function()
      local s = H.dump("\x41")  -- 'A'
      T.ok(s:find("00000000"), "has address")
      T.ok(s:find("41"), "has hex byte")
      T.ok(s:find("|A"), "has ASCII column")
    end)

    T.it("exactly 16 bytes (one full line)", function()
      local data = "0123456789abcdef"
      local s = H.dump(data)
      -- Should be a single line
      T.ok(not s:find("\n"), "no newline for single line")
      T.ok(s:find("00000000"), "has address")
      -- Check all bytes appear
      T.ok(s:find("30 31 32 33"), "has sequential hex bytes")
    end)

    T.it("multi-line dump", function()
      local data = string.rep("A", 20)
      local s = H.dump(data)
      local lines = {}
      for l in (s .. "\n"):gmatch("([^\n]*)\n") do
        if #l > 0 then lines[#lines + 1] = l end
      end
      T.eq(#lines, 2, "20 bytes = 2 lines")
      T.ok(lines[1]:find("00000000"), "first line address")
      T.ok(lines[2]:find("00000010"), "second line address = 16")
    end)

    T.it("non-printable chars shown as dot in ASCII column", function()
      local s = H.dump("\x00\x01\x1f\x7f\xff")
      T.ok(s:find("|%.%.%.%.%.|") or s:find("|....."), "non-printable → dot")
    end)

    T.it("Hello, World! matches expected format", function()
      local s = H.dump("Hello, World!\n")
      T.ok(s:find("48 65 6c 6c 6f"), "hex bytes present")
      T.ok(s:find("|Hello, World"), "ASCII column present")
    end)
  end)

  -- dump options
  T.describe("dump options", function()
    T.it("show_ascii=false omits ASCII column", function()
      local s = H.dump("Hello", {show_ascii = false})
      T.ok(not s:find("|"), "no pipe character")
    end)

    T.it("show_addr=false omits address", function()
      local s = H.dump("Hello", {show_addr = false})
      T.ok(not s:find("00000000"), "no address column")
      T.ok(s:find("48 65 6c"), "hex bytes still present")
    end)

    T.it("uppercase=true produces uppercase hex", function()
      local s = H.dump("\xab\xcd\xef", {uppercase = true})
      T.ok(s:find("AB CD EF"), "uppercase hex")
    end)

    T.it("custom width=8", function()
      local data = string.rep("X", 10)
      local s = H.dump(data, {width = 8})
      local lines = {}
      for l in (s .. "\n"):gmatch("([^\n]*)\n") do
        if #l > 0 then lines[#lines + 1] = l end
      end
      T.eq(#lines, 2, "10 bytes at width=8 = 2 lines")
      T.ok(lines[2]:find("00000008"), "second line at offset 8")
    end)

    T.it("custom offset shifts address", function()
      local s = H.dump("AB", {offset = 0x100})
      T.ok(s:find("00000100"), "address starts at offset")
    end)

    T.it("custom ascii_char", function()
      local s = H.dump("\x01\x02", {ascii_char = "?"})
      T.ok(s:find("|%?%?"), "custom replacement char used")
    end)
  end)

  -- to_hex / from_hex
  T.describe("to_hex", function()
    T.it("empty string", function()
      T.eq(H.to_hex(""), "")
    end)

    T.it("Hello", function()
      T.eq(H.to_hex("Hello"), "48656c6c6f")
    end)

    T.it("all byte values round-trip", function()
      local all = {}
      for i = 0, 255 do all[i + 1] = string.char(i) end
      local data = table.concat(all)
      local hex = H.to_hex(data)
      T.eq(#hex, 512, "hex is twice the length")
      local back = H.from_hex(hex)
      T.eq(back, data, "round-trip preserves data")
    end)
  end)

  T.describe("from_hex", function()
    T.it("valid lowercase", function()
      T.eq(H.from_hex("48656c6c6f"), "Hello")
    end)

    T.it("valid uppercase", function()
      T.eq(H.from_hex("48656C6C6F"), "Hello")
    end)

    T.it("strips spaces", function()
      T.eq(H.from_hex("48 65 6c 6c 6f"), "Hello")
    end)

    T.it("strips colons", function()
      T.eq(H.from_hex("48:65:6c:6c:6f"), "Hello")
    end)

    T.it("odd length returns error", function()
      local v, err = H.from_hex("abc")
      T.eq(v, nil)
      T.ok(err:find("odd"), "error mentions odd")
    end)

    T.it("invalid character returns error", function()
      local v, err = H.from_hex("zz")
      T.eq(v, nil)
      T.ok(err ~= nil, "error returned")
    end)
  end)

  -- parse round-trip
  T.describe("parse", function()
    T.it("parse(dump(s)) == s for short string", function()
      local s = "Hello, World!\n"
      T.eq(H.parse(H.dump(s)), s)
    end)

    T.it("parse(dump(s)) == s for multi-line", function()
      local s = string.rep("\x00\xff\xab\xcd", 10)
      T.eq(H.parse(H.dump(s)), s)
    end)

    T.it("parse(dump(s)) == s for all bytes", function()
      local all = {}
      for i = 0, 255 do all[i + 1] = string.char(i) end
      local s = table.concat(all)
      T.eq(H.parse(H.dump(s)), s)
    end)

    T.it("parse dump with no ascii", function()
      local s = "TestData"
      T.eq(H.parse(H.dump(s, {show_ascii = false})), s)
    end)

    T.it("parse dump with no addr", function()
      local s = "TestData"
      T.eq(H.parse(H.dump(s, {show_addr = false})), s)
    end)
  end)

  -- diff
  T.describe("diff", function()
    T.it("identical inputs produce no markers", function()
      local s = H.diff("Hello", "Hello")
      -- No lines should start with >
      T.ok(not s:find("^>", 1) and not s:find("\n>"), "no > markers")
    end)

    T.it("single byte difference produces markers", function()
      local a = "Hello"
      local b = "Hxllo"
      local s = H.diff(a, b)
      T.ok(s:find(">"), "> marker present")
      T.ok(s:find("<"), "< marker present")
    end)

    T.it("different length strings", function()
      local a = "Hello"
      local b = "Hello World"
      local s = H.diff(a, b)
      T.ok(#s > 0, "non-empty diff output")
    end)

    T.it("both empty produces empty string", function()
      T.eq(H.diff("", ""), "")
    end)

    T.it("completely different single lines", function()
      local a = string.rep("\x00", 8)
      local b = string.rep("\xff", 8)
      local s = H.diff(a, b)
      T.ok(s:find(">"), "has > marker")
      T.ok(s:find("<"), "has < marker")
    end)
  end)

  -- inspect
  T.describe("inspect", function()
    T.it("nil", function()
      T.eq(H.inspect(nil), "nil")
    end)

    T.it("boolean true", function()
      T.eq(H.inspect(true), "true")
    end)

    T.it("boolean false", function()
      T.eq(H.inspect(false), "false")
    end)

    T.it("integer number", function()
      T.eq(H.inspect(42), "42")
    end)

    T.it("float number", function()
      local s = H.inspect(3.14)
      T.ok(s:find("3.14"), "float representation")
    end)

    T.it("plain string", function()
      T.eq(H.inspect("hello"), '"hello"')
    end)

    T.it("string with escape sequences", function()
      local s = H.inspect("a\nb\tc")
      T.ok(s:find("\\n"), "newline escaped")
      T.ok(s:find("\\t"), "tab escaped")
    end)

    T.it("string with backslash", function()
      local s = H.inspect("a\\b")
      T.ok(s:find("\\\\"), "backslash doubled")
    end)

    T.it("empty table", function()
      T.eq(H.inspect({}), "{}")
    end)

    T.it("array table", function()
      local s = H.inspect({1, 2, 3}, {compact = true})
      T.ok(s:find("1") and s:find("2") and s:find("3"), "array elements")
    end)

    T.it("hash table", function()
      local s = H.inspect({x = 1, y = 2}, {compact = true})
      T.ok(s:find("x = 1"), "key=value present")
      T.ok(s:find("y = 2"), "second key=value present")
    end)

    T.it("nested table", function()
      local s = H.inspect({a = {b = 1}})
      T.ok(s:find("b = 1"), "nested value present")
    end)

    T.it("cycle detection", function()
      local t = {}
      t.self = t
      local s = H.inspect(t)
      T.ok(s:find("<cycle>"), "cycle detected")
    end)

    T.it("max_depth respected", function()
      local deep = {a = {b = {c = {d = {e = 1}}}}}
      local s = H.inspect(deep, {max_depth = 2})
      T.ok(s:find("{%.%.%.}") or s:find("{...}"), "depth limit shown")
    end)

    T.it("function value", function()
      local s = H.inspect(function() end)
      T.ok(s:find("function:"), "function with address")
    end)
  end)

  -- bytes / from_bytes
  T.describe("bytes", function()
    T.it("empty string", function()
      local b = H.bytes("")
      T.eq(#b, 0)
    end)

    T.it("Hello", function()
      local b = H.bytes("Hello")
      T.eq(b[1], 72)  -- H
      T.eq(b[2], 101) -- e
      T.eq(b[3], 108) -- l
      T.eq(b[4], 108) -- l
      T.eq(b[5], 111) -- o
    end)

    T.it("round-trip", function()
      local data = "Hello, World!\n"
      T.eq(H.from_bytes(H.bytes(data)), data)
    end)

    T.it("all byte values round-trip", function()
      local all = {}
      for i = 0, 255 do all[i + 1] = i end
      local s = H.from_bytes(all)
      T.eq(#s, 256)
      local back = H.bytes(s)
      T.eq(#back, 256)
      local ok = true
      for i = 1, 256 do
        if back[i] ~= all[i] then ok = false; break end
      end
      T.ok(ok, "all byte values match after round-trip")
    end)
  end)

  T.describe("from_bytes", function()
    T.it("empty array", function()
      T.eq(H.from_bytes({}), "")
    end)

    T.it("known bytes", function()
      T.eq(H.from_bytes({65, 66, 67}), "ABC")
    end)
  end)

  -- to_bin
  T.describe("to_bin", function()
    T.it("0 = 00000000", function()
      T.eq(H.to_bin(0), "00000000")
    end)

    T.it("255 = 11111111", function()
      T.eq(H.to_bin(255), "11111111")
    end)

    T.it("42 = 00101010", function()
      T.eq(H.to_bin(42), "00101010")
    end)

    T.it("128 = 10000000", function()
      T.eq(H.to_bin(128), "10000000")
    end)

    T.it("1 = 00000001", function()
      T.eq(H.to_bin(1), "00000001")
    end)
  end)

  -- to_oct
  T.describe("to_oct", function()
    T.it("0 = 0", function()
      T.eq(H.to_oct(0), "0")
    end)

    T.it("8 = 10", function()
      T.eq(H.to_oct(8), "10")
    end)

    T.it("255 = 377", function()
      T.eq(H.to_oct(255), "377")
    end)

    T.it("64 = 100", function()
      T.eq(H.to_oct(64), "100")
    end)
  end)

  -- float_bits / double_bits
  T.describe("float_bits", function()
    T.it("0.0 = 00000000", function()
      T.eq(H.float_bits(0.0), "00000000")
    end)

    T.it("1.0 = 3f800000", function()
      T.eq(H.float_bits(1.0), "3f800000")
    end)

    T.it("-1.0 = bf800000", function()
      T.eq(H.float_bits(-1.0), "bf800000")
    end)

    T.it("2.0 = 40000000", function()
      T.eq(H.float_bits(2.0), "40000000")
    end)

    T.it("0.5 = 3f000000", function()
      T.eq(H.float_bits(0.5), "3f000000")
    end)
  end)

  T.describe("double_bits", function()
    T.it("0.0 = 16 zeros", function()
      T.eq(H.double_bits(0.0), "0000000000000000")
    end)

    T.it("1.0 = 3ff0000000000000", function()
      T.eq(H.double_bits(1.0), "3ff0000000000000")
    end)

    T.it("-1.0 = bff0000000000000", function()
      T.eq(H.double_bits(-1.0), "bff0000000000000")
    end)

    T.it("2.0 = 4000000000000000", function()
      T.eq(H.double_bits(2.0), "4000000000000000")
    end)

    T.it("0.5 = 3fe0000000000000", function()
      T.eq(H.double_bits(0.5), "3fe0000000000000")
    end)
  end)

end)
