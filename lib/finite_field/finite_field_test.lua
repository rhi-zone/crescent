if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local FF = require("lib.finite_field")

-- ─── GF(17) prime field ──────────────────────────────────────────────────────

T.describe("GF(17) prime field", function()
  local F = FF.prime(17)

  T.it("new reduces values into [0, p-1]", function()
    T.eq(F.new(0):val(),  0)
    T.eq(F.new(17):val(), 0)   -- 17 mod 17 = 0
    T.eq(F.new(18):val(), 1)   -- 18 mod 17 = 1
    T.eq(F.new(-1):val(), 16)  -- -1 mod 17 = 16
    T.eq(F.new(-17):val(), 0)
    T.eq(F.new(34):val(), 0)
    T.eq(F.new(5):val(), 5)
  end)

  T.it("add is correct mod 17", function()
    T.eq(F.new(10):add(F.new(9)):val(), 2)   -- 19 mod 17 = 2
    T.eq(F.new(0):add(F.new(7)):val(), 7)
    T.eq(F.new(16):add(F.new(1)):val(), 0)
    T.eq(F.new(8):add(F.new(8)):val(), 16)
  end)

  T.it("sub is correct mod 17", function()
    T.eq(F.new(5):sub(F.new(3)):val(), 2)
    T.eq(F.new(0):sub(F.new(1)):val(), 16)   -- 0-1 = -1 mod 17 = 16
    T.eq(F.new(3):sub(F.new(5)):val(), 15)   -- -2 mod 17 = 15
  end)

  T.it("mul is correct mod 17", function()
    T.eq(F.new(3):mul(F.new(6)):val(), 1)    -- 18 mod 17 = 1
    T.eq(F.new(4):mul(F.new(5)):val(), 3)    -- 20 mod 17 = 3
    T.eq(F.new(0):mul(F.new(9)):val(), 0)
    T.eq(F.new(8):mul(F.new(2)):val(), 16)   -- 16 mod 17 = 16
  end)

  T.it("neg is correct", function()
    T.eq(F.new(5):neg():val(), 12)   -- -5 mod 17 = 12
    T.eq(F.new(0):neg():val(), 0)
    T.eq(F.new(1):neg():val(), 16)
  end)

  T.it("inv: 3^{-1} mod 17 = 6", function()
    local inv3 = F.new(3):inv()
    T.ok(inv3 ~= nil, "inv(3) not nil")
    T.eq(inv3:val(), 6)
    -- verify: 3 * 6 = 18 = 1 mod 17
    T.eq(F.new(3):mul(inv3):val(), 1)
  end)

  T.it("inv(0) returns nil", function()
    T.eq(F.new(0):inv(), nil)
  end)

  T.it("inv is correct for several values", function()
    for _, v in ipairs({1, 2, 3, 4, 5, 7, 8, 16}) do
      local inv = F.new(v):inv()
      T.ok(inv ~= nil, "inv(" .. v .. ") not nil")
      T.eq(F.new(v):mul(inv):val(), 1, "v * inv(v) = 1 for v=" .. v)
    end
  end)

  T.it("div: a/b = a * b^{-1}", function()
    local a = F.new(10)
    local b = F.new(3)
    local q = a:div(b)
    T.ok(q ~= nil, "div result not nil")
    -- q * b = a
    T.eq(q:mul(b):val(), a:val())
  end)

  T.it("div by zero returns nil + errmsg", function()
    local r, err = F.new(5):div(F.new(0))
    T.eq(r, nil)
    T.ok(type(err) == "string", "error message is string")
  end)

  T.it("pow with positive exponent", function()
    T.eq(F.new(2):pow(4):val(), 16)   -- 2^4 = 16 mod 17 = 16
    T.eq(F.new(3):pow(2):val(), 9)
    T.eq(F.new(3):pow(0):val(), 1)
    T.eq(F.new(0):pow(3):val(), 0)
  end)

  T.it("pow(1) = identity", function()
    T.eq(F.new(7):pow(1):val(), 7)
  end)

  T.it("pow(0) = 1", function()
    T.eq(F.new(9):pow(0):val(), 1)
    T.eq(F.new(1):pow(0):val(), 1)
  end)

  T.it("pow with negative exponent (Fermat)", function()
    -- a^{-1} = a^{p-2} mod p (Fermat's little theorem)
    -- 3^{-1} mod 17 = 6
    T.eq(F.new(3):pow(-1):val(), 6)
    -- verify: a^{-2} = (a^{-1})^2
    local a = F.new(5)
    local inv_a = a:inv()
    T.eq(a:pow(-2):val(), inv_a:mul(inv_a):val())
  end)

  T.it("Fermat's little theorem: a^(p-1) = 1", function()
    for _, v in ipairs({1, 2, 3, 7, 16}) do
      T.eq(F.new(v):pow(16):val(), 1, "Fermat for v=" .. v)
    end
  end)

  T.it("eq", function()
    T.ok(F.new(5):eq(F.new(5)))
    T.ok(F.new(5):eq(F.new(22)))   -- 22 mod 17 = 5
    T.ok(not F.new(5):eq(F.new(6)))
  end)

  T.it("operator metamethods: + - * / - ==", function()
    local a = F.new(10)
    local b = F.new(9)
    T.eq((a + b):val(), 2)          -- 19 mod 17
    T.eq((a - b):val(), 1)
    T.eq((a * b):val(), 5)          -- 90 mod 17 = 5
    local c = F.new(3)
    local d = F.new(6)
    T.eq((c * d):val(), 1)          -- inverse pair
    -- unary minus
    T.eq((-a):val(), 7)             -- -10 mod 17 = 7
    -- ==
    T.ok(F.new(5) == F.new(22))
    T.ok(not (F.new(5) == F.new(6)))
  end)

  T.it("div operator", function()
    local a = F.new(10)
    local b = F.new(3)
    local q = a / b
    T.ok(q ~= nil)
    T.eq((q * b):val(), a:val())
  end)

  T.it("tostring includes field info and value", function()
    local s = tostring(F.new(5))
    T.ok(s:find("17") ~= nil, "tostring mentions p")
    T.ok(s:find("5") ~= nil,  "tostring mentions value")
  end)
end)

-- ─── GF(256) AES field ──────────────────────────────────────────────────────

T.describe("GF(2^8) AES field", function()
  local GF = FF.GF256

  T.it("new stores value correctly", function()
    T.eq(GF.new(0x53):val(), 0x53)
    T.eq(GF.new(0):val(), 0)
    T.eq(GF.new(0xFF):val(), 0xFF)
  end)

  T.it("add = XOR: 0x53 + 0xCA = 0x99", function()
    local a = GF.new(0x53)
    local b = GF.new(0xCA)
    T.eq(a:add(b):val(), 0x99)
    -- commutative
    T.eq(b:add(a):val(), 0x99)
  end)

  T.it("add with zero is identity", function()
    local a = GF.new(0x53)
    T.eq(a:add(GF.new(0)):val(), 0x53)
    T.eq(GF.new(0):add(a):val(), 0x53)
  end)

  T.it("sub = add in GF(2^n)", function()
    local a = GF.new(0x53)
    local b = GF.new(0xCA)
    T.eq(a:sub(b):val(), a:add(b):val())
  end)

  T.it("a + a = 0 (characteristic 2)", function()
    for _, v in ipairs({1, 0x53, 0xFF, 0x80}) do
      T.eq(GF.new(v):add(GF.new(v)):val(), 0, "a+a=0 for v=" .. v)
    end
  end)

  T.it("mul: 0x53 * 0xCA = 0x01 (AES test vector)", function()
    local a = GF.new(0x53)
    local b = GF.new(0xCA)
    T.eq(a:mul(b):val(), 0x01)
  end)

  T.it("mul by 1 is identity", function()
    local a = GF.new(0x53)
    T.eq(a:mul(GF.new(1)):val(), 0x53)
    T.eq(GF.new(1):mul(a):val(), 0x53)
  end)

  T.it("mul by 0 is 0", function()
    T.eq(GF.new(0x53):mul(GF.new(0)):val(), 0)
    T.eq(GF.new(0):mul(GF.new(0x53)):val(), 0)
  end)

  T.it("mul is commutative", function()
    local a = GF.new(0x57)
    local b = GF.new(0x83)
    T.eq(a:mul(b):val(), b:mul(a):val())
  end)

  T.it("inv: 0x53^{-1} = 0xCA", function()
    local a = GF.new(0x53)
    local inv = a:inv()
    T.ok(inv ~= nil, "inv(0x53) not nil")
    T.eq(inv:val(), 0xCA)
    -- verify: a * a^{-1} = 1
    T.eq(a:mul(inv):val(), 1)
  end)

  T.it("inv(0) = nil", function()
    T.eq(GF.new(0):inv(), nil)
  end)

  T.it("inv is consistent with mul", function()
    for _, v in ipairs({1, 2, 0x53, 0x83, 0xFF}) do
      local a = GF.new(v)
      local inv = a:inv()
      T.ok(inv ~= nil, "inv(" .. v .. ") exists")
      T.eq(a:mul(inv):val(), 1, "a * inv(a) = 1 for a=" .. v)
    end
  end)

  T.it("div: a / b = a * b^{-1}", function()
    local a = GF.new(0x53)
    local b = GF.new(0x83)
    local q = a:div(b)
    T.ok(q ~= nil)
    T.eq(q:mul(b):val(), a:val())
  end)

  T.it("div by zero returns nil + errmsg", function()
    local r, err = GF.new(0x53):div(GF.new(0))
    T.eq(r, nil)
    T.ok(type(err) == "string")
  end)

  T.it("pow: a^255 = 1 for all nonzero a (order of GF(256)*)", function()
    for _, v in ipairs({1, 2, 0x53, 0xCA, 0xFF}) do
      T.eq(GF.new(v):pow(255):val(), 1, "a^255=1 for a=" .. v)
    end
  end)

  T.it("pow(0) = 1", function()
    T.eq(GF.new(0x53):pow(0):val(), 1)
  end)

  T.it("pow(1) = identity", function()
    T.eq(GF.new(0x53):pow(1):val(), 0x53)
  end)

  T.it("pow negative: a^{-1} via pow(-1)", function()
    local a = GF.new(0x53)
    T.eq(a:pow(-1):val(), 0xCA)
  end)

  T.it("exp table: exp[0] = 1", function()
    local exp = GF._exp()
    T.eq(exp[0], 1)
  end)

  T.it("log table: log[1] = 0", function()
    local log = GF._log()
    T.eq(log[1], 0)
  end)

  T.it("exp/log are inverses for nonzero elements", function()
    local exp = GF._exp()
    local log = GF._log()
    for _, v in ipairs({1, 2, 0x53, 0xCA, 0xFF, 0x80}) do
      T.eq(exp[log[v]], v, "exp(log(v))=v for v=" .. v)
    end
  end)

  T.it("eq", function()
    T.ok(GF.new(0x53):eq(GF.new(0x53)))
    T.ok(not GF.new(0x53):eq(GF.new(0x54)))
  end)

  T.it("tostring", function()
    local s = tostring(GF.new(0x53))
    T.ok(s:find("8") ~= nil or s:find("2") ~= nil, "tostring mentions field")
  end)
end)

-- ─── GF(16) field ───────────────────────────────────────────────────────────

T.describe("GF(2^4) field", function()
  local GF = FF.GF16

  T.it("elements are in [0, 15]", function()
    T.eq(GF.new(0):val(), 0)
    T.eq(GF.new(15):val(), 15)
    T.eq(GF.new(16):val(), 0)  -- wraps
  end)

  T.it("a + a = 0", function()
    for v = 1, 15 do
      T.eq(GF.new(v):add(GF.new(v)):val(), 0)
    end
  end)

  T.it("a^15 = 1 for nonzero a (order of GF(16)*)", function()
    for v = 1, 15 do
      T.eq(GF.new(v):pow(15):val(), 1, "a^15=1 for a=" .. v)
    end
  end)

  T.it("inv * a = 1", function()
    for v = 1, 15 do
      local a = GF.new(v)
      local inv = a:inv()
      T.ok(inv ~= nil)
      T.eq(a:mul(inv):val(), 1, "a*inv(a)=1 for a=" .. v)
    end
  end)
end)

-- ─── gf2n custom field construction ─────────────────────────────────────────

T.describe("FF.gf2n custom construction", function()
  T.it("can construct GF(2^8) with AES poly manually", function()
    local GF = FF.gf2n(8, 0x11B, 3)
    -- Should match prebuilt GF256 for the same test vector
    T.eq(GF.new(0x53):mul(GF.new(0xCA)):val(), 0x01)
  end)
end)

-- ─── Polynomial arithmetic over GF(17) ──────────────────────────────────────

T.describe("Polynomial arithmetic over GF(17)", function()
  local F = FF.prime(17)

  T.it("poly creation and degree", function()
    local p = FF.poly(F, {1, 0, 1})  -- 1 + 0*x + 1*x^2
    T.eq(p:degree(), 2)
  end)

  T.it("coeffs() returns field elements", function()
    local p = FF.poly(F, {1, 0, 1})
    local cs = p:coeffs()
    T.eq(#cs, 3)
    T.eq(cs[1]:val(), 1)
    T.eq(cs[2]:val(), 0)
    T.eq(cs[3]:val(), 1)
  end)

  T.it("eval: (1 + x^2) at x=3 -> 1 + 9 = 10 mod 17", function()
    local p = FF.poly(F, {1, 0, 1})
    local result = p:eval(F.new(3))
    T.eq(result:val(), 10)
  end)

  T.it("eval at x=0 returns constant term", function()
    local p = FF.poly(F, {5, 3, 2})
    T.eq(p:eval(F.new(0)):val(), 5)
  end)

  T.it("eval of constant poly", function()
    local p = FF.poly(F, {7})
    T.eq(p:eval(F.new(3)):val(), 7)
    T.eq(p:degree(), 0)
  end)

  T.it("poly add: coefficient-wise addition", function()
    local p = FF.poly(F, {1, 2, 3})   -- 1 + 2x + 3x^2
    local q = FF.poly(F, {4, 5})      -- 4 + 5x
    local r = p:add(q)
    local cs = r:coeffs()
    T.eq(cs[1]:val(), 5)   -- 1+4
    T.eq(cs[2]:val(), 7)   -- 2+5
    T.eq(cs[3]:val(), 3)   -- 3+0
    T.eq(r:degree(), 2)
  end)

  T.it("poly add with same degree (cancellation)", function()
    local p = FF.poly(F, {1, 2, 3})
    local q = FF.poly(F, {16, 15, 14})  -- -1, -2, -3 mod 17
    local r = p:add(q)
    -- all coefficients cancel; poly trims to degree 0 (constant 0)
    T.eq(r:degree(), 0)
    T.eq(r:eval(F.new(0)):val(), 0)
    T.eq(r:eval(F.new(5)):val(), 0)
  end)

  T.it("poly mul: (1 + x)(1 - x) = 1 - x^2", function()
    local p = FF.poly(F, {1, 1})        -- 1 + x
    local q = FF.poly(F, {1, 16})       -- 1 - x = 1 + 16x (mod 17)
    local r = p:mul(q)
    local cs = r:coeffs()
    T.eq(cs[1]:val(), 1)    -- constant = 1
    T.eq(cs[2]:val(), 0)    -- x term = 0
    T.eq(cs[3]:val(), 16)   -- x^2 term = -1 mod 17 = 16
    T.eq(r:degree(), 2)
  end)

  T.it("poly mul: degree additivity", function()
    local p = FF.poly(F, {1, 1, 1})  -- degree 2
    local q = FF.poly(F, {1, 1})     -- degree 1
    local r = p:mul(q)
    T.eq(r:degree(), 3)
  end)

  T.it("poly mul by zero poly gives zero", function()
    local p = FF.poly(F, {1, 2, 3})
    local zero = FF.poly(F, {0})
    local r = p:mul(zero)
    T.eq(r:eval(F.new(5)):val(), 0)
  end)

  T.it("Horner eval matches naive sum", function()
    -- p(x) = 3 + 2x + x^2, eval at x=4
    -- naive: 3 + 2*4 + 16 = 3 + 8 + 16 = 27 mod 17 = 10
    local p = FF.poly(F, {3, 2, 1})
    T.eq(p:eval(F.new(4)):val(), 10)
  end)
end)

-- ─── FF._tier ───────────────────────────────────────────────────────────────

T.describe("module metadata", function()
  T.it("_tier is 'pure'", function()
    T.eq(FF._tier, "pure")
  end)
end)
