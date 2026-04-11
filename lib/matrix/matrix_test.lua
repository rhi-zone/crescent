if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local matrix = require("lib.matrix")

T.describe("matrix", function()

  T.describe("construction", function()
    T.it("new creates zero matrix", function()
      local m = matrix.new(2, 3)
      T.eq(m:rows(), 2)
      T.eq(m:cols(), 3)
      T.eq(m:get(1, 1), 0)
      T.eq(m:get(2, 3), 0)
    end)

    T.it("new with data", function()
      local m = matrix.new(2, 2, {1, 2, 3, 4})
      T.eq(m:get(1, 1), 1)
      T.eq(m:get(1, 2), 2)
      T.eq(m:get(2, 1), 3)
      T.eq(m:get(2, 2), 4)
    end)

    T.it("new rejects bad dimensions", function()
      local m, err = matrix.new(0, 3)
      T.eq(m, nil)
      T.ok(err)
    end)

    T.it("new rejects mismatched data length", function()
      local m, err = matrix.new(2, 2, {1, 2, 3})
      T.eq(m, nil)
      T.ok(err)
    end)

    T.it("from_rows", function()
      local m = matrix.from_rows({{1, 2, 3}, {4, 5, 6}})
      T.eq(m:rows(), 2)
      T.eq(m:cols(), 3)
      T.eq(m:get(1, 1), 1)
      T.eq(m:get(2, 3), 6)
    end)

    T.it("from_rows rejects jagged", function()
      local m, err = matrix.from_rows({{1, 2}, {3}})
      T.eq(m, nil)
      T.ok(err)
    end)

    T.it("from_rows rejects empty", function()
      local m, err = matrix.from_rows({})
      T.eq(m, nil)
      T.ok(err)
    end)

    T.it("identity", function()
      local m = matrix.identity(3)
      T.eq(m:get(1, 1), 1)
      T.eq(m:get(2, 2), 1)
      T.eq(m:get(3, 3), 1)
      T.eq(m:get(1, 2), 0)
      T.eq(m:get(2, 3), 0)
    end)

    T.it("zeros", function()
      local m = matrix.zeros(2, 3)
      T.eq(m:get(1, 1), 0)
      T.eq(m:get(2, 3), 0)
    end)

    T.it("ones", function()
      local m = matrix.ones(2, 2)
      T.eq(m:get(1, 1), 1)
      T.eq(m:get(1, 2), 1)
      T.eq(m:get(2, 1), 1)
      T.eq(m:get(2, 2), 1)
    end)

    T.it("diag", function()
      local m = matrix.diag({2, 3, 5})
      T.eq(m:rows(), 3)
      T.eq(m:cols(), 3)
      T.eq(m:get(1, 1), 2)
      T.eq(m:get(2, 2), 3)
      T.eq(m:get(3, 3), 5)
      T.eq(m:get(1, 2), 0)
    end)

    T.it("random produces values in range", function()
      local m = matrix.random(3, 3, 10, 20)
      for i = 1, 3 do
        for j = 1, 3 do
          local v = m:get(i, j)
          T.ok(v >= 10, "value >= lo")
          T.ok(v < 20, "value < hi")
        end
      end
    end)
  end)

  T.describe("accessors", function()
    T.it("size returns rows and cols", function()
      local m = matrix.new(3, 4)
      local r, c = m:size()
      T.eq(r, 3)
      T.eq(c, 4)
    end)

    T.it("set and get", function()
      local m = matrix.new(2, 2)
      m:set(1, 2, 42)
      T.eq(m:get(1, 2), 42)
      T.eq(m:get(1, 1), 0)
    end)

    T.it("row returns array", function()
      local m = matrix.from_rows({{1, 2, 3}, {4, 5, 6}})
      local r = m:row(2)
      T.eq(r[1], 4)
      T.eq(r[2], 5)
      T.eq(r[3], 6)
    end)

    T.it("col returns array", function()
      local m = matrix.from_rows({{1, 2}, {3, 4}, {5, 6}})
      local c = m:col(2)
      T.eq(c[1], 2)
      T.eq(c[2], 4)
      T.eq(c[3], 6)
    end)
  end)

  T.describe("arithmetic", function()
    T.it("add", function()
      local a = matrix.from_rows({{1, 2}, {3, 4}})
      local b = matrix.from_rows({{5, 6}, {7, 8}})
      local c = a:add(b)
      T.eq(c:get(1, 1), 6)
      T.eq(c:get(1, 2), 8)
      T.eq(c:get(2, 1), 10)
      T.eq(c:get(2, 2), 12)
    end)

    T.it("add rejects dimension mismatch", function()
      local a = matrix.new(2, 2)
      local b = matrix.new(2, 3)
      local c, err = a:add(b)
      T.eq(c, nil)
      T.ok(err)
    end)

    T.it("sub", function()
      local a = matrix.from_rows({{5, 6}, {7, 8}})
      local b = matrix.from_rows({{1, 2}, {3, 4}})
      local c = a:sub(b)
      T.eq(c:get(1, 1), 4)
      T.eq(c:get(2, 2), 4)
    end)

    T.it("mul 2x3 * 3x2", function()
      local a = matrix.from_rows({{1, 2, 3}, {4, 5, 6}})
      local b = matrix.from_rows({{7, 8}, {9, 10}, {11, 12}})
      local c = a:mul(b)
      T.eq(c:rows(), 2)
      T.eq(c:cols(), 2)
      T.eq(c:get(1, 1), 58)   -- 1*7+2*9+3*11
      T.eq(c:get(1, 2), 64)   -- 1*8+2*10+3*12
      T.eq(c:get(2, 1), 139)  -- 4*7+5*9+6*11
      T.eq(c:get(2, 2), 154)  -- 4*8+5*10+6*12
    end)

    T.it("mul rejects inner dim mismatch", function()
      local a = matrix.new(2, 3)
      local b = matrix.new(2, 2)
      local c, err = a:mul(b)
      T.eq(c, nil)
      T.ok(err)
    end)

    T.it("scale", function()
      local m = matrix.from_rows({{1, 2}, {3, 4}})
      local s = m:scale(3)
      T.eq(s:get(1, 1), 3)
      T.eq(s:get(2, 2), 12)
    end)

    T.it("neg", function()
      local m = matrix.from_rows({{1, -2}, {3, 0}})
      local n = m:neg()
      T.eq(n:get(1, 1), -1)
      T.eq(n:get(1, 2), 2)
      T.eq(n:get(2, 1), -3)
      T.eq(n:get(2, 2), 0)
    end)
  end)

  T.describe("transpose", function()
    T.it("transposes non-square", function()
      local m = matrix.from_rows({{1, 2, 3}, {4, 5, 6}})
      local t = m:transpose()
      T.eq(t:rows(), 3)
      T.eq(t:cols(), 2)
      T.eq(t:get(1, 1), 1)
      T.eq(t:get(1, 2), 4)
      T.eq(t:get(2, 1), 2)
      T.eq(t:get(3, 2), 6)
    end)

    T.it("double transpose is identity", function()
      local m = matrix.from_rows({{1, 2}, {3, 4}})
      T.ok(m:transpose():transpose():eq(m))
    end)
  end)

  T.describe("trace", function()
    T.it("trace of identity", function()
      T.eq(matrix.identity(4):trace(), 4)
    end)

    T.it("trace of custom", function()
      local m = matrix.from_rows({{1, 0}, {0, 5}})
      T.eq(m:trace(), 6)
    end)

    T.it("trace rejects non-square", function()
      local m = matrix.new(2, 3)
      local t, err = m:trace()
      T.eq(t, nil)
      T.ok(err)
    end)
  end)

  T.describe("determinant", function()
    T.it("1x1", function()
      local m = matrix.new(1, 1, {7})
      T.eq(m:det(), 7)
    end)

    T.it("2x2", function()
      local m = matrix.from_rows({{1, 2}, {3, 4}})
      T.eq(m:det(), -2)
    end)

    T.it("3x3", function()
      local m = matrix.from_rows({{6, 1, 1}, {4, -2, 5}, {2, 8, 7}})
      -- det = 6(-2*7-5*8) - 1(4*7-5*2) + 1(4*8-(-2)*2) = 6(-54) - 1(18) + 1(36) = -324 - 18 + 36 = -306
      local d = m:det()
      T.ok(math.abs(d - (-306)) < 1e-9, "3x3 det")
    end)

    T.it("identity det is 1", function()
      T.eq(matrix.identity(4):det(), 1)
    end)

    T.it("singular det is 0", function()
      local m = matrix.from_rows({{1, 2}, {2, 4}})
      T.eq(m:det(), 0)
    end)

    T.it("det rejects non-square", function()
      local m = matrix.new(2, 3)
      local d, err = m:det()
      T.eq(d, nil)
      T.ok(err)
    end)
  end)

  T.describe("inverse", function()
    T.it("2x2 inverse", function()
      local m = matrix.from_rows({{4, 7}, {2, 6}})
      local inv = m:inverse()
      T.ok(inv, "inverse should exist")
      local prod = m:mul(inv)
      T.ok(prod:eq(matrix.identity(2), 1e-9), "M * M^-1 = I")
    end)

    T.it("3x3 inverse", function()
      local m = matrix.from_rows({{1, 2, 3}, {0, 1, 4}, {5, 6, 0}})
      local inv = m:inverse()
      T.ok(inv, "inverse should exist")
      local prod = m:mul(inv)
      T.ok(prod:eq(matrix.identity(3), 1e-9), "M * M^-1 = I")
    end)

    T.it("singular returns nil", function()
      local m = matrix.from_rows({{1, 2}, {2, 4}})
      local inv, err = m:inverse()
      T.eq(inv, nil)
      T.ok(err)
    end)

    T.it("inverse rejects non-square", function()
      local m = matrix.new(2, 3)
      local inv, err = m:inverse()
      T.eq(inv, nil)
      T.ok(err)
    end)

    T.it("identity inverse is identity", function()
      local I = matrix.identity(3)
      local inv = I:inverse()
      T.ok(inv:eq(I, 1e-9))
    end)
  end)

  T.describe("solve", function()
    T.it("2x2 system", function()
      -- x + 2y = 5, 3x + 4y = 11 => x=1, y=2
      local A = matrix.from_rows({{1, 2}, {3, 4}})
      local b = matrix.new(2, 1, {5, 11})
      local x = matrix.solve(A, b)
      T.ok(x, "solution should exist")
      T.ok(math.abs(x:get(1, 1) - 1) < 1e-9, "x=1")
      T.ok(math.abs(x:get(2, 1) - 2) < 1e-9, "y=2")
    end)

    T.it("3x3 system", function()
      local A = matrix.from_rows({{2, 1, -1}, {-3, -1, 2}, {-2, 1, 2}})
      local b = matrix.new(3, 1, {8, -11, -3})
      local x = matrix.solve(A, b)
      T.ok(x, "solution should exist")
      T.ok(math.abs(x:get(1, 1) - 2) < 1e-9, "x1=2")
      T.ok(math.abs(x:get(2, 1) - 3) < 1e-9, "x2=3")
      T.ok(math.abs(x:get(3, 1) - (-1)) < 1e-9, "x3=-1")
    end)

    T.it("singular system returns nil", function()
      local A = matrix.from_rows({{1, 2}, {2, 4}})
      local b = matrix.new(2, 1, {3, 6})
      local x, err = matrix.solve(A, b)
      T.eq(x, nil)
      T.ok(err)
    end)

    T.it("verify Ax=b", function()
      local A = matrix.from_rows({{1, 2}, {3, 4}})
      local b = matrix.new(2, 1, {5, 11})
      local x = matrix.solve(A, b)
      local Ax = A:mul(x)
      T.ok(Ax:eq(b, 1e-9), "Ax should equal b")
    end)
  end)

  T.describe("map", function()
    T.it("doubles all elements", function()
      local m = matrix.from_rows({{1, 2}, {3, 4}})
      local doubled = m:map(function(v) return v * 2 end)
      T.eq(doubled:get(1, 1), 2)
      T.eq(doubled:get(2, 2), 8)
    end)

    T.it("absolute value", function()
      local m = matrix.from_rows({{-1, 2}, {-3, 4}})
      local a = m:map(math.abs)
      T.eq(a:get(1, 1), 1)
      T.eq(a:get(2, 1), 3)
    end)
  end)

  T.describe("reshape", function()
    T.it("2x3 to 3x2", function()
      local m = matrix.from_rows({{1, 2, 3}, {4, 5, 6}})
      local r = m:reshape(3, 2)
      T.eq(r:rows(), 3)
      T.eq(r:cols(), 2)
      T.eq(r:get(1, 1), 1)
      T.eq(r:get(1, 2), 2)
      T.eq(r:get(2, 1), 3)
      T.eq(r:get(3, 2), 6)
    end)

    T.it("rejects incompatible reshape", function()
      local m = matrix.new(2, 3)
      local r, err = m:reshape(2, 2)
      T.eq(r, nil)
      T.ok(err)
    end)

    T.it("reshape to 1xN", function()
      local m = matrix.from_rows({{1, 2}, {3, 4}})
      local r = m:reshape(1, 4)
      T.eq(r:rows(), 1)
      T.eq(r:cols(), 4)
      T.eq(r:get(1, 3), 3)
    end)
  end)

  T.describe("to_array and to_rows", function()
    T.it("to_array returns flat copy", function()
      local m = matrix.from_rows({{1, 2}, {3, 4}})
      local a = m:to_array()
      T.eq(#a, 4)
      T.eq(a[1], 1)
      T.eq(a[4], 4)
      -- mutating copy doesn't affect matrix
      a[1] = 99
      T.eq(m:get(1, 1), 1)
    end)

    T.it("to_rows returns nested arrays", function()
      local m = matrix.from_rows({{1, 2, 3}, {4, 5, 6}})
      local rows = m:to_rows()
      T.eq(#rows, 2)
      T.eq(#rows[1], 3)
      T.eq(rows[1][1], 1)
      T.eq(rows[2][3], 6)
    end)
  end)

  T.describe("norm and dot", function()
    T.it("frobenius norm", function()
      local m = matrix.from_rows({{3, 4}})
      T.eq(m:norm(), 5) -- sqrt(9+16)
    end)

    T.it("frobenius norm of identity", function()
      local n = matrix.identity(3):norm()
      T.ok(math.abs(n - math.sqrt(3)) < 1e-9)
    end)

    T.it("dot product", function()
      local a = matrix.from_rows({{1, 2}, {3, 4}})
      local b = matrix.from_rows({{5, 6}, {7, 8}})
      -- 1*5 + 2*6 + 3*7 + 4*8 = 5+12+21+32 = 70
      T.eq(a:dot(b), 70)
    end)

    T.it("dot rejects mismatch", function()
      local a = matrix.new(2, 2)
      local b = matrix.new(2, 3)
      local d, err = a:dot(b)
      T.eq(d, nil)
      T.ok(err)
    end)
  end)

  T.describe("eq", function()
    T.it("equal matrices", function()
      local a = matrix.from_rows({{1, 2}, {3, 4}})
      local b = matrix.from_rows({{1, 2}, {3, 4}})
      T.ok(a:eq(b))
    end)

    T.it("unequal matrices", function()
      local a = matrix.from_rows({{1, 2}, {3, 4}})
      local b = matrix.from_rows({{1, 2}, {3, 5}})
      T.ok(not a:eq(b))
    end)

    T.it("different dimensions", function()
      local a = matrix.new(2, 2)
      local b = matrix.new(2, 3)
      T.ok(not a:eq(b))
    end)

    T.it("epsilon tolerance", function()
      local a = matrix.from_rows({{1.0, 2.0}})
      local b = matrix.from_rows({{1.0000001, 2.0000001}})
      T.ok(not a:eq(b))
      T.ok(a:eq(b, 1e-6))
    end)
  end)

  T.describe("edge cases", function()
    T.it("1x1 matrix operations", function()
      local m = matrix.new(1, 1, {5})
      T.eq(m:det(), 5)
      T.eq(m:trace(), 5)
      local inv = m:inverse()
      T.ok(math.abs(inv:get(1, 1) - 0.2) < 1e-9)
      T.eq(m:norm(), 5)
    end)

    T.it("non-square transpose round-trip", function()
      local m = matrix.from_rows({{1, 2, 3}})
      local t = m:transpose()
      T.eq(t:rows(), 3)
      T.eq(t:cols(), 1)
      T.ok(t:transpose():eq(m))
    end)

    T.it("mul by identity is identity", function()
      local m = matrix.from_rows({{1, 2}, {3, 4}})
      local I = matrix.identity(2)
      T.ok(m:mul(I):eq(m))
      T.ok(I:mul(m):eq(m))
    end)

    T.it("tostring works", function()
      local m = matrix.from_rows({{1, 2}, {3, 4}})
      local s = tostring(m)
      T.ok(type(s) == "string")
      T.ok(#s > 0)
    end)

    T.it("data is copied, not shared", function()
      local data = {1, 2, 3, 4}
      local m = matrix.new(2, 2, data)
      data[1] = 99
      T.eq(m:get(1, 1), 1, "matrix data should be independent copy")
    end)
  end)

  -- -------------------------------------------------------------------------
  -- from_array (flat row-major, spec alias)
  -- -------------------------------------------------------------------------
  T.describe("from_array", function()
    T.it("creates matrix from flat row-major array", function()
      local B = matrix.from_array(3, 3, {
        1, 2, 3,
        4, 5, 6,
        7, 8, 9,
      })
      T.eq(B:rows(), 3)
      T.eq(B:cols(), 3)
      T.eq(B:get(1, 2), 2)
      T.eq(B:get(2, 1), 4)
      T.eq(B:get(3, 3), 9)
    end)

    T.it("from_array 3x2 non-square", function()
      local m = matrix.from_array(3, 2, {1, 2, 3, 4, 5, 6})
      T.eq(m:rows(), 3)
      T.eq(m:cols(), 2)
      T.eq(m:get(2, 2), 4)
      T.eq(m:get(3, 1), 5)
    end)
  end)

  -- -------------------------------------------------------------------------
  -- shape / size returning table
  -- -------------------------------------------------------------------------
  T.describe("shape", function()
    T.it("returns {rows, cols} table", function()
      local m = matrix.new(4, 5)
      local s = m:shape()
      T.eq(s[1], 4)
      T.eq(s[2], 5)
    end)

    T.it("1x1 shape", function()
      local m = matrix.new(1, 1)
      local s = m:shape()
      T.eq(s[1], 1)
      T.eq(s[2], 1)
    end)
  end)

  -- -------------------------------------------------------------------------
  -- diagonal
  -- -------------------------------------------------------------------------
  T.describe("diagonal", function()
    T.it("square matrix diagonal", function()
      local B = matrix.from_array(3, 3, {1,2,3,4,5,6,7,8,9})
      local d = B:diagonal()
      T.eq(d[1], 1)
      T.eq(d[2], 5)
      T.eq(d[3], 9)
      T.eq(#d, 3)
    end)

    T.it("non-square 2x3 diagonal (min dimension)", function()
      local m = matrix.from_array(2, 3, {1,2,3,4,5,6})
      local d = m:diagonal()
      T.eq(#d, 2)
      T.eq(d[1], 1)
      T.eq(d[2], 5)
    end)

    T.it("identity diagonal is all ones", function()
      local d = matrix.identity(4):diagonal()
      for i = 1, 4 do T.eq(d[i], 1) end
    end)
  end)

  -- -------------------------------------------------------------------------
  -- Operator overloads: +, -, *, unary -
  -- -------------------------------------------------------------------------
  T.describe("operator overloads", function()
    local A = matrix.from_array(2, 2, {1,2,3,4})
    local B = matrix.from_array(2, 2, {5,6,7,8})

    T.it("__add element-wise", function()
      local C = A + B
      T.eq(C:get(1,1), 6)
      T.eq(C:get(1,2), 8)
      T.eq(C:get(2,1), 10)
      T.eq(C:get(2,2), 12)
    end)

    T.it("__sub element-wise", function()
      local C = B - A
      T.eq(C:get(1,1), 4)
      T.eq(C:get(2,2), 4)
    end)

    T.it("__mul matrix multiply", function()
      local C = A * B
      -- [1 2]*[5 6] = [1*5+2*7, 1*6+2*8] = [19, 22]
      -- [3 4] [7 8]   [3*5+4*7, 3*6+4*8]   [43, 50]
      T.eq(C:get(1,1), 19)
      T.eq(C:get(1,2), 22)
      T.eq(C:get(2,1), 43)
      T.eq(C:get(2,2), 50)
    end)

    T.it("__mul scalar right", function()
      local C = A * 3
      T.eq(C:get(1,1), 3)
      T.eq(C:get(2,2), 12)
    end)

    T.it("__mul scalar left", function()
      local C = 2 * A
      T.eq(C:get(1,1), 2)
      T.eq(C:get(2,2), 8)
    end)

    T.it("__unm negation", function()
      local C = -A
      T.eq(C:get(1,1), -1)
      T.eq(C:get(1,2), -2)
      T.eq(C:get(2,1), -3)
      T.eq(C:get(2,2), -4)
    end)
  end)

  -- -------------------------------------------------------------------------
  -- sum / min / max
  -- -------------------------------------------------------------------------
  T.describe("aggregation", function()
    T.it("sum of elements", function()
      local m = matrix.from_array(2, 3, {1,2,3,4,5,6})
      T.eq(m:sum(), 21)
    end)

    T.it("sum of identity(3) is 3", function()
      T.eq(matrix.identity(3):sum(), 3)
    end)

    T.it("min element", function()
      local m = matrix.from_array(2, 2, {3,-1,7,2})
      T.eq(m:min(), -1)
    end)

    T.it("max element", function()
      local m = matrix.from_array(2, 2, {3,-1,7,2})
      T.eq(m:max(), 7)
    end)

    T.it("min and max on 1x1", function()
      local m = matrix.new(1, 1, {42})
      T.eq(m:min(), 42)
      T.eq(m:max(), 42)
    end)
  end)

  -- -------------------------------------------------------------------------
  -- zip
  -- -------------------------------------------------------------------------
  T.describe("zip", function()
    T.it("element-wise add via zip", function()
      local a = matrix.from_array(2, 2, {1,2,3,4})
      local b = matrix.from_array(2, 2, {10,20,30,40})
      local c = a:zip(b, function(x, y) return x + y end)
      T.eq(c:get(1,1), 11)
      T.eq(c:get(2,2), 44)
    end)

    T.it("element-wise product via zip", function()
      local a = matrix.from_array(1, 3, {2,3,4})
      local b = matrix.from_array(1, 3, {5,6,7})
      local c = a:zip(b, function(x, y) return x * y end)
      T.eq(c:get(1,1), 10)
      T.eq(c:get(1,2), 18)
      T.eq(c:get(1,3), 28)
    end)

    T.it("zip rejects dimension mismatch", function()
      local a = matrix.new(2,2)
      local b = matrix.new(2,3)
      local c, err = a:zip(b, function(x,y) return x+y end)
      T.eq(c, nil)
      T.ok(err)
    end)
  end)

  -- -------------------------------------------------------------------------
  -- inv (alias for inverse)
  -- -------------------------------------------------------------------------
  T.describe("inv", function()
    T.it("inv is alias for inverse", function()
      local m = matrix.from_array(2, 2, {4,7,2,6})
      local inv = m:inv()
      T.ok(inv, "inv should succeed")
      local prod = m:mul(inv)
      T.ok(prod:eq(matrix.identity(2), 1e-9), "M*M^-1=I")
    end)

    T.it("inv of singular returns nil", function()
      local m = matrix.from_array(2, 2, {1,2,2,4})
      local inv, err = m:inv()
      T.eq(inv, nil)
      T.ok(err)
    end)
  end)

  -- -------------------------------------------------------------------------
  -- LU decomposition
  -- -------------------------------------------------------------------------
  T.describe("lu", function()
    T.it("L is lower triangular with unit diagonal", function()
      local A = matrix.from_array(3, 3, {2,1,1, 4,3,3, 8,7,9})
      local L, U = A:lu()
      T.ok(L, "L exists")
      T.ok(U, "U exists")
      -- Unit diagonal
      T.ok(math.abs(L:get(1,1) - 1) < 1e-9)
      T.ok(math.abs(L:get(2,2) - 1) < 1e-9)
      T.ok(math.abs(L:get(3,3) - 1) < 1e-9)
      -- Upper triangle of L is zero
      T.ok(math.abs(L:get(1,2)) < 1e-9)
      T.ok(math.abs(L:get(1,3)) < 1e-9)
      T.ok(math.abs(L:get(2,3)) < 1e-9)
      -- Lower triangle of U is zero
      T.ok(math.abs(U:get(2,1)) < 1e-9)
      T.ok(math.abs(U:get(3,1)) < 1e-9)
      T.ok(math.abs(U:get(3,2)) < 1e-9)
    end)

    T.it("LU rejects non-square", function()
      local m = matrix.new(2, 3)
      local L, err = m:lu()
      T.eq(L, nil)
      T.ok(err)
    end)

    T.it("2x2 LU product equals original when no pivoting", function()
      -- Row 1 has larger pivot (4 > 1), so no swap occurs: L*U = A exactly.
      local A = matrix.from_array(2, 2, {4,3,2,1})
      local L, U = A:lu()
      local LU = L:mul(U)
      T.ok(LU:eq(A, 1e-9), "L*U = A when no pivot swap")
    end)

    T.it("3x3 L*U reconstructs A when leading element is largest", function()
      -- Diagonal-dominant: pivots are already the largest, no row swaps.
      local A = matrix.from_array(3, 3, {10,2,1, 1,8,2, 2,1,9})
      local L, U = A:lu()
      local LU = L:mul(U)
      T.ok(LU:eq(A, 1e-9), "L*U = A")
    end)

    T.it("identity lu gives L=I, U=I", function()
      local I = matrix.identity(3)
      local L, U = I:lu()
      T.ok(L:eq(matrix.identity(3), 1e-9), "L=I")
      T.ok(U:eq(matrix.identity(3), 1e-9), "U=I")
    end)
  end)

  -- -------------------------------------------------------------------------
  -- slice
  -- -------------------------------------------------------------------------
  T.describe("slice", function()
    T.it("extract 2x2 submatrix from 3x3", function()
      local B = matrix.from_array(3, 3, {1,2,3,4,5,6,7,8,9})
      local S = B:slice(1, 1, 2, 2)
      T.eq(S:rows(), 2)
      T.eq(S:cols(), 2)
      T.eq(S:get(1,1), 1)
      T.eq(S:get(1,2), 2)
      T.eq(S:get(2,1), 4)
      T.eq(S:get(2,2), 5)
    end)

    T.it("slice full matrix returns equal copy", function()
      local B = matrix.from_array(2, 3, {1,2,3,4,5,6})
      local S = B:slice(1, 1, 2, 3)
      T.ok(S:eq(B))
    end)

    T.it("slice single element", function()
      local B = matrix.from_array(3, 3, {1,2,3,4,5,6,7,8,9})
      local S = B:slice(2, 2, 2, 2)
      T.eq(S:rows(), 1)
      T.eq(S:cols(), 1)
      T.eq(S:get(1,1), 5)
    end)

    T.it("slice bottom-right 2x2", function()
      local B = matrix.from_array(3, 3, {1,2,3,4,5,6,7,8,9})
      local S = B:slice(2, 2, 3, 3)
      T.eq(S:get(1,1), 5)
      T.eq(S:get(1,2), 6)
      T.eq(S:get(2,1), 8)
      T.eq(S:get(2,2), 9)
    end)

    T.it("slice out-of-range returns nil", function()
      local B = matrix.from_array(2, 2, {1,2,3,4})
      local S, err = B:slice(1, 1, 3, 2)
      T.eq(S, nil)
      T.ok(err)
    end)
  end)

  -- -------------------------------------------------------------------------
  -- approx_eq
  -- -------------------------------------------------------------------------
  T.describe("approx_eq", function()
    T.it("exact equal matrices", function()
      local a = matrix.from_array(2, 2, {1,2,3,4})
      local b = matrix.from_array(2, 2, {1,2,3,4})
      T.ok(a:approx_eq(b))
    end)

    T.it("within default tolerance", function()
      local a = matrix.from_array(1, 2, {1.0, 2.0})
      local b = matrix.from_array(1, 2, {1.0 + 1e-10, 2.0 - 1e-10})
      T.ok(a:approx_eq(b))
    end)

    T.it("outside default tolerance", function()
      local a = matrix.from_array(1, 2, {1.0, 2.0})
      local b = matrix.from_array(1, 2, {1.1, 2.0})
      T.ok(not a:approx_eq(b))
    end)

    T.it("custom tolerance", function()
      local a = matrix.from_array(1, 1, {1.0})
      local b = matrix.from_array(1, 1, {1.05})
      T.ok(not a:approx_eq(b, 0.01))
      T.ok(a:approx_eq(b, 0.1))
    end)

    T.it("different shapes are not approx equal", function()
      local a = matrix.new(2, 2)
      local b = matrix.new(2, 3)
      T.ok(not a:approx_eq(b))
    end)
  end)

  -- -------------------------------------------------------------------------
  -- to_string (formatted [[...]] output)
  -- -------------------------------------------------------------------------
  T.describe("to_string", function()
    T.it("1x1 formatted output", function()
      local m = matrix.new(1, 1, {7})
      T.eq(m:to_string(), "[[7]]")
    end)

    T.it("1x3 single row", function()
      local m = matrix.from_array(1, 3, {1, 2, 3})
      T.eq(m:to_string(), "[[1 2 3]]")
    end)

    T.it("2x3 multi-row format", function()
      local m = matrix.from_array(2, 3, {1,2,3,4,5,6})
      local s = m:to_string()
      T.ok(s:find("%[%[1 2 3%]"), "first row starts with [[")
      T.ok(s:find("%[4 5 6%]%]"), "last row ends with ]]")
      T.ok(s:find("\n"), "multi-row has newline")
    end)

    T.it("3x3 from spec example", function()
      local m = matrix.from_array(3, 3, {1,2,3,4,5,6,7,8,9})
      local s = m:to_string()
      T.eq(s, "[[1 2 3]\n [4 5 6]\n [7 8 9]]")
    end)
  end)

  -- -------------------------------------------------------------------------
  -- solve: verify Ax=b for 3x3 and edge cases
  -- -------------------------------------------------------------------------
  T.describe("solve extended", function()
    T.it("solve returns n×1 matrix", function()
      local A = matrix.from_array(2, 2, {1,0,0,1})
      local b = matrix.new(2, 1, {3, 7})
      local x = matrix.solve(A, b)
      T.ok(x, "solution exists")
      T.eq(x:rows(), 2)
      T.eq(x:cols(), 1)
      T.eq(x:get(1,1), 3)
      T.eq(x:get(2,1), 7)
    end)

    T.it("solve b must be column vector", function()
      local A = matrix.from_array(2, 2, {1,0,0,1})
      local b = matrix.from_array(1, 2, {3, 7})  -- wrong: 1x2 not 2x1
      local x, err = matrix.solve(A, b)
      T.eq(x, nil)
      T.ok(err)
    end)
  end)

  -- -------------------------------------------------------------------------
  -- M._tier
  -- -------------------------------------------------------------------------
  T.describe("module metadata", function()
    T.it("_tier is pure", function()
      T.eq(matrix._tier, "pure")
    end)
  end)

end)
