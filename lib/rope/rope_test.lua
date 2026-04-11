if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local rope = require("lib.rope")

T.describe("rope", function()

  T.it("empty rope", function()
    local r = rope.new()
    T.eq(r:length(), 0)
    T.eq(r:to_string(), "")
    T.eq(tostring(r), "")
  end)

  T.it("empty rope from empty string", function()
    local r = rope.new("")
    T.eq(r:length(), 0)
    T.eq(r:to_string(), "")
  end)

  T.it("from string", function()
    local r = rope.new("hello world")
    T.eq(r:length(), 11)
    T.eq(r:to_string(), "hello world")
    T.eq(tostring(r), "hello world")
  end)

  T.it("_tier is pure", function()
    T.eq(rope._tier, "pure")
  end)

  T.describe("char_at", function()
    local r = rope.new("hello world")

    T.it("first char", function()
      T.eq(r:char_at(1), "h")
    end)

    T.it("last char", function()
      T.eq(r:char_at(11), "d")
    end)

    T.it("middle char", function()
      T.eq(r:char_at(6), " ")
    end)

    T.it("out of range returns nil + errmsg", function()
      local c, err = r:char_at(0)
      T.eq(c, nil)
      T.ok(err ~= nil)
      local c2, err2 = r:char_at(12)
      T.eq(c2, nil)
      T.ok(err2 ~= nil)
    end)
  end)

  T.describe("sub", function()
    local r = rope.new("hello world")

    T.it("first word", function()
      T.eq(r:sub(1, 5):to_string(), "hello")
    end)

    T.it("second word", function()
      T.eq(r:sub(7, 11):to_string(), "world")
    end)

    T.it("single char", function()
      T.eq(r:sub(6, 6):to_string(), " ")
    end)

    T.it("full string", function()
      T.eq(r:sub(1, 11):to_string(), "hello world")
    end)

    T.it("empty when i > j", function()
      T.eq(r:sub(5, 3):to_string(), "")
    end)

    T.it("negative index", function()
      T.eq(r:sub(-5, -1):to_string(), "world")
    end)

    T.it("clamp past end", function()
      T.eq(r:sub(7, 100):to_string(), "world")
    end)
  end)

  T.describe("concat", function()
    T.it("two ropes via :concat", function()
      local r1 = rope.new("hello")
      local r2 = rope.new(" world")
      local r3 = r1:concat(r2)
      T.eq(r3:to_string(), "hello world")
      T.eq(r3:length(), 11)
    end)

    T.it(".. operator", function()
      local r = rope.new("foo") .. rope.new("bar")
      T.eq(r:to_string(), "foobar")
      T.eq(r:length(), 6)
    end)

    T.it("concat with empty left", function()
      local r = rope.new("") .. rope.new("abc")
      T.eq(r:to_string(), "abc")
    end)

    T.it("concat with empty right", function()
      local r = rope.new("abc") .. rope.new("")
      T.eq(r:to_string(), "abc")
    end)

    T.it("concat preserves both sides unchanged", function()
      local r1 = rope.new("hello")
      local r2 = rope.new(" world")
      local r3 = r1:concat(r2)
      T.eq(r1:to_string(), "hello")
      T.eq(r2:to_string(), " world")
      T.eq(r3:to_string(), "hello world")
    end)
  end)

  T.describe("split", function()
    local r = rope.new("hello world")

    T.it("split in middle", function()
      local left, right = r:split(5)
      T.eq(left:to_string(), "hello")
      T.eq(right:to_string(), " world")
    end)

    T.it("split at start (pos=0)", function()
      local left, right = r:split(0)
      T.eq(left:to_string(), "")
      T.eq(right:to_string(), "hello world")
    end)

    T.it("split at end", function()
      local left, right = r:split(11)
      T.eq(left:to_string(), "hello world")
      T.eq(right:to_string(), "")
    end)

    T.it("split at position 1", function()
      local left, right = r:split(1)
      T.eq(left:to_string(), "h")
      T.eq(right:to_string(), "ello world")
    end)
  end)

  T.describe("insert", function()
    local r = rope.new("hello world")

    T.it("insert in middle", function()
      local r2 = r:insert(6, ", dear")
      T.eq(r2:to_string(), "hello, dear world")
    end)

    T.it("insert at beginning", function()
      local r2 = r:insert(1, "say: ")
      T.eq(r2:to_string(), "say: hello world")
    end)

    T.it("insert at end", function()
      local r2 = r:insert(r:length() + 1, "!")
      T.eq(r2:to_string(), "hello world!")
    end)

    T.it("original unchanged", function()
      local _ = r:insert(6, "X")
      T.eq(r:to_string(), "hello world")
    end)
  end)

  T.describe("delete", function()
    local r = rope.new("hello, dear world")

    T.it("delete middle chars", function()
      -- delete ", dea" chars 6-10
      local r2 = r:delete(6, 10)
      T.eq(r2:to_string(), "hellor world")
    end)

    T.it("delete from start", function()
      local r2 = r:delete(1, 7)
      T.eq(r2:to_string(), "dear world")
    end)

    T.it("delete to end", function()
      local r2 = r:delete(6, r:length())
      T.eq(r2:to_string(), "hello")
    end)

    T.it("delete single char", function()
      local r2 = r:delete(6, 6)
      T.eq(r2:to_string(), "hello dear world")
    end)

    T.it("original unchanged", function()
      local _ = r:delete(1, 3)
      T.eq(r:to_string(), "hello, dear world")
    end)
  end)

  T.describe("iter", function()
    T.it("single leaf", function()
      local r = rope.new("hello")
      local chunks = {}
      for chunk in r:iter() do
        chunks[#chunks + 1] = chunk
      end
      T.eq(#chunks, 1)
      T.eq(chunks[1], "hello")
    end)

    T.it("multi-chunk concat", function()
      local r = rope.new("foo") .. rope.new("bar") .. rope.new("baz")
      local collected = ""
      for chunk in r:iter() do
        collected = collected .. chunk
      end
      T.eq(collected, "foobarbaz")
    end)

    T.it("empty rope yields no chunks", function()
      local r = rope.new()
      local count = 0
      for _ in r:iter() do
        count = count + 1
      end
      T.eq(count, 0)
    end)

    T.it("iter chunks concatenate to full string", function()
      local r = rope.new("hello") .. rope.new(" ") .. rope.new("world")
      local parts = {}
      for chunk in r:iter() do
        parts[#parts + 1] = chunk
      end
      T.eq(table.concat(parts), "hello world")
    end)
  end)

  T.describe("rebalance", function()
    T.it("rebalance preserves content", function()
      local r = rope.new("hello") .. rope.new(" ") .. rope.new("world")
      local rb = r:rebalance()
      T.eq(rb:to_string(), "hello world")
      T.eq(rb:length(), 11)
    end)

    T.it("rebalance empty", function()
      local r = rope.new()
      local rb = r:rebalance()
      T.eq(rb:to_string(), "")
    end)
  end)

  T.describe("equality metamethod", function()
    T.it("same content equal", function()
      local r1 = rope.new("hello world")
      local r2 = rope.new("hello world")
      T.ok(r1 == r2)
    end)

    T.it("different content not equal", function()
      local r1 = rope.new("hello")
      local r2 = rope.new("world")
      T.ok(r1 ~= r2)
    end)

    T.it("concat result equals flat rope", function()
      local r1 = rope.new("hello") .. rope.new(" world")
      local r2 = rope.new("hello world")
      T.ok(r1 == r2)
    end)

    T.it("empty ropes equal", function()
      T.ok(rope.new() == rope.new(""))
    end)
  end)

  T.describe("large string tests", function()
    T.it("100 repeated concats match naive", function()
      local r = rope.new()
      local naive = ""
      for i = 1, 100 do
        local s = "chunk" .. tostring(i) .. " "
        r = r .. rope.new(s)
        naive = naive .. s
      end
      T.eq(r:to_string(), naive)
      T.eq(r:length(), #naive)
    end)

    T.it("100 repeated concats: iter matches naive", function()
      local r = rope.new()
      local naive = ""
      for i = 1, 100 do
        local s = tostring(i) .. ","
        r = r .. rope.new(s)
        naive = naive .. s
      end
      local collected = {}
      for chunk in r:iter() do
        collected[#collected + 1] = chunk
      end
      T.eq(table.concat(collected), naive)
    end)

    T.it("large rope: char_at works", function()
      local r = rope.new()
      for i = 1, 50 do
        r = r .. rope.new("ab")
      end
      -- 100 chars: all odd positions = 'a', even = 'b'
      T.eq(r:length(), 100)
      T.eq(r:char_at(1), "a")
      T.eq(r:char_at(2), "b")
      T.eq(r:char_at(99), "a")
      T.eq(r:char_at(100), "b")
    end)

    T.it("large rope: sub works", function()
      local r = rope.new()
      for i = 1, 20 do
        r = r .. rope.new("hello")
      end
      T.eq(r:length(), 100)
      T.eq(r:sub(1, 5):to_string(), "hello")
      T.eq(r:sub(96, 100):to_string(), "hello")
    end)

    T.it("large rope: insert/delete roundtrip", function()
      local r = rope.new("hello world")
      for i = 1, 10 do
        r = r:insert(r:length() + 1, " more")
      end
      -- delete all the " more" suffixes
      -- each " more" is 5 chars; original is 11 chars
      for i = 1, 10 do
        local len = r:length()
        r = r:delete(len - 4, len)
      end
      T.eq(r:to_string(), "hello world")
    end)
  end)

  T.describe("split on multi-chunk rope", function()
    T.it("split multi-chunk rope in middle", function()
      local r = rope.new("hello") .. rope.new(" world")
      local left, right = r:split(5)
      T.eq(left:to_string(), "hello")
      T.eq(right:to_string(), " world")
    end)

    T.it("split at chunk boundary", function()
      local r = rope.new("abc") .. rope.new("def")
      local left, right = r:split(3)
      T.eq(left:to_string(), "abc")
      T.eq(right:to_string(), "def")
    end)
  end)

  T.describe("spec aliases", function()
    T.it("rope:len() == rope:length()", function()
      local r = rope.new("hello")
      T.eq(r:len(), 5)
      T.eq(r:len(), r:length())
    end)

    T.it("rope:str() == rope:to_string()", function()
      local r = rope.new("hello world")
      T.eq(r:str(), "hello world")
      T.eq(r:str(), r:to_string())
    end)

    T.it("rope:len() on empty", function()
      T.eq(rope.new():len(), 0)
    end)

    -- Note: LuaJIT does not support __len metamethod on plain tables
    -- (Lua 5.2+ feature). Use :len() or :length() instead.
    T.it("M.concat(a, b) rope+rope", function()
      local r = rope.concat(rope.new("hello"), rope.new(" world"))
      T.eq(r:str(), "hello world")
      T.eq(r:len(), 11)
    end)

    T.it("M.concat(a, b) string+rope", function()
      local r = rope.concat("hello", rope.new(" world"))
      T.eq(r:str(), "hello world")
    end)

    T.it("M.concat(a, b) rope+string", function()
      local r = rope.concat(rope.new("hello"), " world")
      T.eq(r:str(), "hello world")
    end)

    T.it("stress: 100 single-char inserts match naive concat", function()
      local r = rope.new()
      local naive = ""
      for i = 1, 100 do
        local ch = string.char(97 + (i - 1) % 26)
        r = r:insert(r:len() + 1, ch)
        naive = naive .. ch
      end
      T.eq(r:str(), naive)
      T.eq(r:len(), 100)
    end)

    T.it("1000 insert operations produce correct final string", function()
      local r = rope.new("x")
      local naive = "x"
      for i = 1, 1000 do
        r = r:insert(r:len() + 1, "a")
        naive = naive .. "a"
      end
      T.eq(r:len(), 1001)
      T.eq(r:str(), naive)
    end)

    T.it("rebalance does not change content on deep rope", function()
      local r = rope.new()
      for i = 1, 200 do
        r = r .. rope.new(tostring(i))
      end
      local s = r:str()
      local rb = r:rebalance()
      T.eq(rb:str(), s)
      T.eq(rb:len(), #s)
    end)
  end)

end)
