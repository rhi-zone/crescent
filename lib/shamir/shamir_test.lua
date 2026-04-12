if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local shamir = require("lib.shamir")

-- Seed for reproducibility in tests
math.randomseed(42)

T.describe("shamir._tier", function()
  T.it("is pure", function()
    T.eq(shamir._tier, "pure")
  end)
end)

T.describe("shamir.split", function()
  T.it("returns n shares", function()
    local shares = shamir.split("hello", 5, 3)
    T.eq(#shares, 5)
  end)

  T.it("each share has correct y length", function()
    local secret = "hello world"
    local shares = shamir.split(secret, 4, 2)
    for i = 1, 4 do
      T.eq(#shares[i].y, #secret)
    end
  end)

  T.it("share x values are 1..n", function()
    local shares = shamir.split("abc", 6, 3)
    for i = 1, 6 do
      T.eq(shares[i].x, i)
    end
  end)

  T.it("returns nil for invalid n", function()
    local s, err = shamir.split("x", 1, 1)
    T.eq(s, nil)
    T.ok(err ~= nil)
  end)

  T.it("returns nil for k > n", function()
    local s, err = shamir.split("x", 3, 5)
    T.eq(s, nil)
    T.ok(err ~= nil)
  end)

  T.it("returns nil for non-string secret", function()
    local s, err = shamir.split(42, 3, 2)
    T.eq(s, nil)
    T.ok(err ~= nil)
  end)
end)

T.describe("shamir round-trip", function()
  local function round_trip(label, secret, n, k)
    T.it(label .. " full set", function()
      local shares = shamir.split(secret, n, k)
      T.ok(shares ~= nil)
      local recovered = shamir.join(shares)
      T.eq(recovered, secret)
    end)

    T.it(label .. " exactly k shares (first k)", function()
      local shares = shamir.split(secret, n, k)
      local subset = {}
      for i = 1, k do subset[i] = shares[i] end
      local recovered = shamir.join(subset)
      T.eq(recovered, secret)
    end)

    if n > k then
      T.it(label .. " exactly k shares (last k)", function()
        local shares = shamir.split(secret, n, k)
        local subset = {}
        for i = n - k + 1, n do subset[#subset + 1] = shares[i] end
        local recovered = shamir.join(subset)
        T.eq(recovered, secret)
      end)

      T.it(label .. " different subsets agree", function()
        local shares = shamir.split(secret, n, k)
        -- subset A: first k shares
        local subA = {}
        for i = 1, k do subA[i] = shares[i] end
        -- subset B: last k shares
        local subB = {}
        for i = n - k + 1, n do subB[#subB + 1] = shares[i] end
        local recA = shamir.join(subA)
        local recB = shamir.join(subB)
        T.eq(recA, secret)
        T.eq(recB, secret)
        T.eq(recA, recB)
      end)
    end
  end

  round_trip("(2,2) 1byte", "X", 2, 2)
  round_trip("(3,2) short", "hi", 3, 2)
  round_trip("(5,3) medium", "secret message", 5, 3)
  round_trip("(10,5) long", string.rep("abcdef", 17), 10, 5)
end)

T.describe("shamir secret lengths", function()
  T.it("empty string", function()
    local shares = shamir.split("", 3, 2)
    T.eq(#shares, 3)
    local recovered = shamir.join(shares)
    T.eq(recovered, "")
  end)

  T.it("1 byte", function()
    local shares = shamir.split("\xff", 3, 2)
    local recovered = shamir.join(shares)
    T.eq(recovered, "\xff")
  end)

  T.it("16 bytes", function()
    local secret = string.rep("\x00\xff", 8)  -- 16 bytes
    local shares = shamir.split(secret, 5, 3)
    local recovered = shamir.join(shares)
    T.eq(recovered, secret)
  end)

  T.it("100 bytes", function()
    local secret = string.rep("A", 100)
    local shares = shamir.split(secret, 7, 4)
    local subset = {}
    for i = 1, 4 do subset[i] = shares[i] end
    local recovered = shamir.join(subset)
    T.eq(recovered, secret)
  end)

  T.it("binary data with all byte values", function()
    local bytes = {}
    for i = 0, 255 do bytes[i+1] = string.char(i) end
    local secret = table.concat(bytes)
    T.eq(#secret, 256)
    local shares = shamir.split(secret, 4, 3)
    local recovered = shamir.join(shares)
    T.eq(recovered, secret)
  end)
end)

T.describe("shamir.join errors", function()
  T.it("too few shares (1)", function()
    local shares = shamir.split("secret", 5, 3)
    local sub = { shares[1] }
    local result, err = shamir.join(sub)
    T.eq(result, nil)
    T.ok(err ~= nil)
  end)

  T.it("duplicate x values", function()
    local shares = shamir.split("secret", 5, 3)
    local dup = { shares[1], shares[1], shares[2] }
    local result, err = shamir.join(dup)
    T.eq(result, nil)
    T.ok(err ~= nil)
  end)

  T.it("non-table input", function()
    local result, err = shamir.join("oops")
    T.eq(result, nil)
    T.ok(err ~= nil)
  end)

  T.it("inconsistent share lengths", function()
    local shares = shamir.split("hello", 3, 2)
    -- Corrupt one share's y length
    local bad = { shares[1], { x = shares[2].x, y = shares[2].y .. "\x00" } }
    local result, err = shamir.join(bad)
    T.eq(result, nil)
    T.ok(err ~= nil)
  end)
end)

T.describe("shamir information-theoretic property", function()
  T.it("k-1 shares + wrong k-th share gives wrong result", function()
    local secret = "mysecret"
    local shares = shamir.split(secret, 5, 3)
    -- Use shares 1,2 plus a corrupted version of share 3
    local fake_share3 = { x = shares[3].x, y = shares[3].y:gsub(".", "\xAB") }
    local bad_set = { shares[1], shares[2], fake_share3 }
    local wrong = shamir.join(bad_set)
    -- wrong reconstruction is not nil (join succeeds) but != secret
    T.neq(wrong, secret)
  end)

  T.it("exactly k-1 correct shares gives wrong result (with random k-th)", function()
    local secret = "topsecret"
    -- Use k=3 so k-1=2 correct shares
    local shares = shamir.split(secret, 5, 3)
    -- Replace share 3 with garbage bytes of same length
    local garbage_y = string.rep("\x55", #shares[3].y)
    local bad = { shares[1], shares[2], { x = shares[3].x, y = garbage_y } }
    local wrong = shamir.join(bad)
    T.neq(wrong, secret)
  end)
end)

T.describe("shamir.encode_shares / decode_shares", function()
  T.it("encode produces hex strings", function()
    local shares = shamir.split("hi", 3, 2)
    local hex = shamir.encode_shares(shares)
    T.eq(#hex, 3)
    for i = 1, 3 do
      T.ok(type(hex[i]) == "string")
      -- format: XX:yyhex (2 + 1 + 2*len_y hex chars)
      T.ok(hex[i]:match("^%x%x:%x*$") ~= nil)
    end
  end)

  T.it("decode round-trips", function()
    local shares = shamir.split("round trip test", 4, 2)
    local hex = shamir.encode_shares(shares)
    local decoded = shamir.decode_shares(hex)
    T.eq(#decoded, #shares)
    for i = 1, #shares do
      T.eq(decoded[i].x, shares[i].x)
      T.eq(decoded[i].y, shares[i].y)
    end
  end)

  T.it("decode invalid format returns error", function()
    local result, err = shamir.decode_shares({ "invalid" })
    T.eq(result, nil)
    T.ok(err ~= nil)
  end)

  T.it("x preserved correctly (various values)", function()
    local shares = shamir.split("abc", 10, 5)
    local hex = shamir.encode_shares(shares)
    local decoded = shamir.decode_shares(hex)
    for i = 1, 10 do
      T.eq(decoded[i].x, i)
    end
  end)
end)

T.describe("shamir.split_hex / join_hex", function()
  T.it("split_hex returns array of strings", function()
    local hex = shamir.split_hex("hello", 3, 2)
    T.eq(#hex, 3)
    for i = 1, 3 do
      T.ok(type(hex[i]) == "string")
    end
  end)

  T.it("join_hex recovers secret", function()
    local secret = "convenience api test"
    local hex = shamir.split_hex(secret, 5, 3)
    local recovered = shamir.join_hex(hex)
    T.eq(recovered, secret)
  end)

  T.it("join_hex with subset works", function()
    local secret = "subset hex"
    local hex = shamir.split_hex(secret, 5, 3)
    -- use only first 3
    local sub = { hex[1], hex[2], hex[3] }
    local recovered = shamir.join_hex(sub)
    T.eq(recovered, secret)
  end)

  T.it("join_hex returns error for bad input", function()
    local result, err = shamir.join_hex({ "zz:notvalid" })
    T.eq(result, nil)
    T.ok(err ~= nil)
  end)

  T.it("split_hex returns nil for invalid args", function()
    local result, err = shamir.split_hex("x", 1, 1)
    T.eq(result, nil)
    T.ok(err ~= nil)
  end)
end)

T.describe("shamir large threshold", function()
  T.it("n=255 k=128 split and join subset", function()
    local secret = "large threshold"
    local shares = shamir.split(secret, 255, 128)
    T.eq(#shares, 255)
    -- join first 128
    local subset = {}
    for i = 1, 128 do subset[i] = shares[i] end
    local recovered = shamir.join(subset)
    T.eq(recovered, secret)
  end)
end)
