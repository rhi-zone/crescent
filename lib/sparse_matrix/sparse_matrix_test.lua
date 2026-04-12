if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local sparse = require("lib.sparse_matrix")
local T = require("lib.test.assert")

-- ── DOK basics ────────────────────────────────────────────────────────────────

T.describe("DOK", function()
  T.it("set/get/nnz", function()
    local A = sparse.dok(4, 4)
    A:set(1, 1, 5)
    A:set(2, 3, 8)
    A:set(3, 2, -3)
    T.eq(A:get(1, 1), 5)
    T.eq(A:get(2, 3), 8)
    T.eq(A:get(3, 2), -3)
    T.eq(A:get(1, 2), 0)
    T.eq(A:nnz(), 3)
  end)

  T.it("zero values auto-removed on set", function()
    local A = sparse.dok(3, 3)
    A:set(1, 1, 7)
    T.eq(A:nnz(), 1)
    A:set(1, 1, 0)
    T.eq(A:nnz(), 0)
    T.eq(A:get(1, 1), 0)
  end)

  T.it("shape", function()
    local A = sparse.dok(5, 7)
    local r, c = A:shape()
    T.eq(r, 5)
    T.eq(c, 7)
  end)

  T.it("to_dense matches manual construction", function()
    local A = sparse.dok(3, 3)
    A:set(1, 1, 1)
    A:set(2, 2, 2)
    A:set(3, 3, 3)
    local d = A:to_dense()
    T.eq(d[1][1], 1) T.eq(d[1][2], 0) T.eq(d[1][3], 0)
    T.eq(d[2][1], 0) T.eq(d[2][2], 2) T.eq(d[2][3], 0)
    T.eq(d[3][1], 0) T.eq(d[3][2], 0) T.eq(d[3][3], 3)
  end)

  T.it("each() iterates all non-zeros", function()
    local A = sparse.dok(3, 3)
    A:set(1, 2, 10)
    A:set(3, 1, 20)
    local found = {}
    for i, j, v in A:each() do
      found[i .. "," .. j] = v
    end
    T.eq(found["1,2"], 10)
    T.eq(found["3,1"], 20)
    local count = 0
    for _ in pairs(found) do count = count + 1 end
    T.eq(count, 2)
  end)
end)

-- ── from_dense ────────────────────────────────────────────────────────────────

T.describe("from_dense", function()
  T.it("correct nnz and values", function()
    local A = sparse.from_dense({{1,0,2},{0,0,3},{4,0,5}})
    T.eq(A:nnz(), 5)
    T.eq(A:get(1,1), 1)
    T.eq(A:get(1,2), 0)
    T.eq(A:get(1,3), 2)
    T.eq(A:get(2,3), 3)
    T.eq(A:get(3,1), 4)
    T.eq(A:get(3,3), 5)
  end)
end)

-- ── arithmetic ────────────────────────────────────────────────────────────────

T.describe("add", function()
  T.it("A + B correct result", function()
    local A = sparse.from_dense({{1,0},{0,2}})
    local B = sparse.from_dense({{0,3},{4,0}})
    local C = A + B
    T.eq(C:get(1,1), 1)
    T.eq(C:get(1,2), 3)
    T.eq(C:get(2,1), 4)
    T.eq(C:get(2,2), 2)
  end)

  T.it("cancellation removes zeros", function()
    local A = sparse.from_dense({{1,2},{3,4}})
    local B = sparse.from_dense({{-1,-2},{-3,-4}})
    local C = A + B
    T.eq(C:nnz(), 0)
  end)
end)

T.describe("mul", function()
  T.it("A * B matrix multiplication 3x3 known result", function()
    -- A = [[1,2,3],[4,5,6],[7,8,9]], B = identity
    local A = sparse.from_dense({{1,2,0},{0,0,3},{4,0,5}})
    local I = sparse.from_dense({{1,0,0},{0,1,0},{0,0,1}})
    local C = A * I
    T.eq(C:get(1,1), 1)
    T.eq(C:get(1,2), 2)
    T.eq(C:get(1,3), 0)
    T.eq(C:get(2,3), 3)
    T.eq(C:get(3,1), 4)
    T.eq(C:get(3,3), 5)
  end)

  T.it("2x2 known result", function()
    -- [[1,2],[3,4]] * [[5,6],[7,8]] = [[19,22],[43,50]]
    local A = sparse.from_dense({{1,2},{3,4}})
    local B = sparse.from_dense({{5,6},{7,8}})
    local C = A * B
    T.eq(C:get(1,1), 19)
    T.eq(C:get(1,2), 22)
    T.eq(C:get(2,1), 43)
    T.eq(C:get(2,2), 50)
  end)

  T.it("identity * A = A", function()
    local A = sparse.from_dense({{1,0,2},{0,0,3},{4,0,5}})
    local I = sparse.from_dense({{1,0,0},{0,1,0},{0,0,1}})
    local C = I * A
    T.eq(C:get(1,1), 1)
    T.eq(C:get(1,3), 2)
    T.eq(C:get(2,3), 3)
    T.eq(C:get(3,1), 4)
    T.eq(C:get(3,3), 5)
  end)
end)

T.describe("scale", function()
  T.it("scalar multiply", function()
    local A = sparse.from_dense({{1,2},{3,4}})
    local B = A * 3
    T.eq(B:get(1,1), 3)
    T.eq(B:get(1,2), 6)
    T.eq(B:get(2,1), 9)
    T.eq(B:get(2,2), 12)
    T.eq(B:nnz(), 4)
  end)

  T.it("scale by zero returns empty", function()
    local A = sparse.from_dense({{1,2},{3,4}})
    local B = A * 0
    T.eq(B:nnz(), 0)
  end)
end)

T.describe("transpose", function()
  T.it("rows/cols swapped, values correct", function()
    local A = sparse.dok(2, 3)
    A:set(1, 2, 7)
    A:set(2, 3, 9)
    local B = A:T()
    local r, c = B:shape()
    T.eq(r, 3)
    T.eq(c, 2)
    T.eq(B:get(2, 1), 7)
    T.eq(B:get(3, 2), 9)
    T.eq(B:nnz(), 2)
  end)
end)

T.describe("mul_vec", function()
  T.it("correct result", function()
    -- [[1,2,3],[0,1,0],[0,0,1]] * [1,0,0] = [1,0,0]
    local A = sparse.from_dense({{1,2,3},{0,1,0},{0,0,1}})
    local v = A:mul_vec({1, 0, 0})
    T.eq(v[1], 1)
    T.eq(v[2], 0)
    T.eq(v[3], 0)
  end)

  T.it("general case", function()
    local A = sparse.from_dense({{1,0},{0,2}})
    local v = A:mul_vec({3, 4})
    T.eq(v[1], 3)
    T.eq(v[2], 8)
  end)
end)

-- ── CSR conversion ────────────────────────────────────────────────────────────

T.describe("CSR", function()
  T.it("to_csr/to_dok round-trip preserves values", function()
    local A = sparse.from_dense({{1,0,2},{0,0,3},{4,0,5}})
    local B = A:to_csr()
    T.eq(B:nnz(), 5)
    local C = B:to_dok()
    T.eq(C:get(1,1), 1)
    T.eq(C:get(1,3), 2)
    T.eq(C:get(2,3), 3)
    T.eq(C:get(3,1), 4)
    T.eq(C:get(3,3), 5)
    T.eq(C:nnz(), 5)
  end)

  T.it("CSR mul_vec correct", function()
    local A = sparse.from_dense({{1,0,2},{0,0,3},{4,0,5}}):to_csr()
    local v = A:mul_vec({1, 1, 1})
    T.eq(v[1], 3)
    T.eq(v[2], 3)
    T.eq(v[3], 9)
  end)

  T.it("CSR each() iterates all non-zeros", function()
    local A = sparse.from_dense({{1,0,2},{0,0,3}}):to_csr()
    local count = 0
    local found = {}
    for i, j, v in A:each() do
      count = count + 1
      found[i .. "," .. j] = v
    end
    T.eq(count, 3)
    T.eq(found["1,1"], 1)
    T.eq(found["1,3"], 2)
    T.eq(found["2,3"], 3)
  end)
end)

-- ── COO ───────────────────────────────────────────────────────────────────────

T.describe("COO", function()
  T.it("construction and to_dok", function()
    local A = sparse.coo(4, 4, {{1,1,5},{2,3,8},{3,2,-3}})
    T.eq(A:nnz(), 3)
    local D = A:to_dok()
    T.eq(D:get(1,1), 5)
    T.eq(D:get(2,3), 8)
    T.eq(D:get(3,2), -3)
    T.eq(D:nnz(), 3)
  end)

  T.it("each() iterates entries", function()
    local A = sparse.coo(3, 3, {{1,2,7},{3,1,9}})
    local found = {}
    for i, j, v in A:each() do
      found[i .. "," .. j] = v
    end
    T.eq(found["1,2"], 7)
    T.eq(found["3,1"], 9)
  end)
end)

-- ── norms ─────────────────────────────────────────────────────────────────────

T.describe("norm", function()
  -- A = [[3,0],[-4,0],[0,5]]
  -- col sums: col1=7, col2=5 → norm1=7
  -- row sums: row1=3, row2=4, row3=5 → normInf=5
  -- fro = sqrt(9+16+25) = sqrt(50)
  T.it("norm(1) column-sum norm", function()
    local A = sparse.from_dense({{3,0},{-4,0},{0,5}})
    T.eq(A:norm(1), 7)
  end)

  T.it("norm(\"inf\") row-sum norm", function()
    local A = sparse.from_dense({{3,0},{-4,0},{0,5}})
    T.eq(A:norm("inf"), 5)
  end)

  T.it("norm(\"fro\") Frobenius norm", function()
    local A = sparse.from_dense({{3,0},{-4,0},{0,5}})
    local f = A:norm("fro")
    -- sqrt(50) ≈ 7.0710...
    T.ok(math.abs(f - math.sqrt(50)) < 1e-10)
  end)
end)

-- ── large sparse ──────────────────────────────────────────────────────────────

T.describe("large sparse", function()
  T.it("100x100 with 10 non-zeros, operations don't crash", function()
    local A = sparse.dok(100, 100)
    A:set(1,  1,  1)
    A:set(10, 10, 2)
    A:set(20, 30, 3)
    A:set(50, 50, 4)
    A:set(99, 99, 5)
    A:set(5,  80, -1)
    A:set(70, 5,  7)
    A:set(33, 33, 8)
    A:set(44, 44, 9)
    A:set(60, 70, 10)
    T.eq(A:nnz(), 10)

    local B = A:to_csr()
    T.eq(B:nnz(), 10)

    local C = A + A
    T.eq(C:get(1,1), 2)
    T.eq(C:get(10,10), 4)

    local vec = {}
    for k = 1, 100 do vec[k] = 1 end
    local result = A:mul_vec(vec)
    T.eq(result[1],   1)
    T.eq(result[10],  2)
    T.eq(result[20],  3)
    T.eq(result[99],  5)

    local t = A:T()
    T.eq(t:get(1, 1), 1)
    T.eq(t:get(10,10), 2)
    T.eq(t:get(30,20), 3)
  end)
end)
