if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T = require("lib.test.assert")
local rand = require("lib.rand")

T.describe("rand.bytes", function()
  T.it("returns correct length", function()
    local b = rand.bytes(16)
    T.eq(#b, 16)
    T.eq(#rand.bytes(0), 0)
    T.eq(#rand.bytes(1), 1)
    T.eq(#rand.bytes(1024), 1024)
  end)
  T.it("returns different values on successive calls", function()
    local a = rand.bytes(32)
    local b = rand.bytes(32)
    T.neq(a, b, "two 32-byte random strings should differ")
  end)
end)

T.describe("rand.u32", function()
  T.it("returns a number", function()
    local v = rand.u32()
    T.eq(type(v), "number")
  end)
  T.it("is in uint32 range", function()
    for _ = 1, 100 do
      local v = rand.u32()
      T.ok(v >= 0, "u32 >= 0")
      T.ok(v <= 0xFFFFFFFF, "u32 <= 2^32-1")
    end
  end)
end)

T.describe("rand.u64", function()
  T.it("returns a number", function()
    local v = rand.u64()
    T.eq(type(v), "number")
  end)
  T.it("is non-negative", function()
    for _ = 1, 100 do
      local v = rand.u64()
      T.ok(v >= 0, "u64 >= 0")
    end
  end)
end)

T.describe("rand.int", function()
  T.it("stays within bounds", function()
    for _ = 1, 200 do
      local v = rand.int(5, 10)
      T.ok(v >= 5, "int >= min")
      T.ok(v <= 10, "int <= max")
    end
  end)
  T.it("returns min when min == max", function()
    T.eq(rand.int(7, 7), 7)
  end)
  T.it("returns error when min > max", function()
    local v, err = rand.int(10, 5)
    T.eq(v, nil)
    T.eq(err, "min > max")
  end)
  T.it("handles range of 1", function()
    for _ = 1, 50 do
      local v = rand.int(0, 1)
      T.ok(v == 0 or v == 1, "int(0,1) is 0 or 1")
    end
  end)
  T.it("handles negative ranges", function()
    for _ = 1, 100 do
      local v = rand.int(-10, -5)
      T.ok(v >= -10, "int >= -10")
      T.ok(v <= -5, "int <= -5")
    end
  end)
end)

T.describe("rand.float", function()
  T.it("is in [0, 1)", function()
    for _ = 1, 200 do
      local v = rand.float()
      T.ok(v >= 0, "float >= 0")
      T.ok(v < 1, "float < 1")
    end
  end)
  T.it("returns a number", function()
    T.eq(type(rand.float()), "number")
  end)
end)

T.describe("rand.choice", function()
  T.it("returns element from array", function()
    local arr = {"a", "b", "c", "d"}
    local seen = {}
    for _ = 1, 100 do
      local v = rand.choice(arr)
      seen[v] = true
    end
    -- Should have seen at least 2 different elements in 100 draws from 4
    local count = 0
    for _ in pairs(seen) do count = count + 1 end
    T.ok(count >= 2, "choice returns varied elements")
  end)
  T.it("returns nil for empty array", function()
    local v, err = rand.choice({})
    T.eq(v, nil)
    T.eq(err, "empty array")
  end)
  T.it("returns only element for single-element array", function()
    T.eq(rand.choice({42}), 42)
  end)
end)

T.describe("rand.shuffle", function()
  T.it("preserves all elements", function()
    local arr = {1, 2, 3, 4, 5, 6, 7, 8}
    local copy = {1, 2, 3, 4, 5, 6, 7, 8}
    rand.shuffle(arr)
    table.sort(arr)
    for i = 1, #copy do
      T.eq(arr[i], copy[i])
    end
  end)
  T.it("returns the array", function()
    local arr = {1, 2, 3}
    T.eq(rand.shuffle(arr), arr)
  end)
  T.it("actually shuffles (statistical)", function()
    -- Shuffle 10 times, check that at least one differs from original order
    local orig = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10}
    local any_different = false
    for _ = 1, 10 do
      local arr = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10}
      rand.shuffle(arr)
      for i = 1, #arr do
        if arr[i] ~= orig[i] then any_different = true; break end
      end
      if any_different then break end
    end
    T.ok(any_different, "shuffle should change order")
  end)
end)

T.describe("rand.hex", function()
  T.it("returns correct length", function()
    T.eq(#rand.hex(0), 0)
    T.eq(#rand.hex(1), 2)
    T.eq(#rand.hex(16), 32)
  end)
  T.it("contains only hex characters", function()
    local h = rand.hex(32)
    T.ok(not h:find("[^0-9a-f]"), "hex string should only contain 0-9a-f")
  end)
  T.it("returns different values", function()
    T.neq(rand.hex(16), rand.hex(16), "hex strings should differ")
  end)
end)

T.describe("rand.uuid", function()
  T.it("has correct format", function()
    local u = rand.uuid()
    T.eq(#u, 36, "uuid length")
    T.ok(u:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil,
      "uuid format: " .. u)
  end)
  T.it("version 4 and variant bits", function()
    for _ = 1, 20 do
      local u = rand.uuid()
      T.eq(u:sub(15, 15), "4", "version nibble")
      local variant = u:sub(20, 20)
      T.ok(variant == "8" or variant == "9" or variant == "a" or variant == "b",
        "variant nibble: " .. variant)
    end
  end)
  T.it("returns different values", function()
    T.neq(rand.uuid(), rand.uuid(), "uuids should differ")
  end)
end)
