if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local W = require("lib.wavelet")

local SQRT2 = math.sqrt(2)
local INV_SQRT2 = 1 / SQRT2
local EPS = 1e-9
local EPS_DB = 1e-8  -- looser for db2/db4/coif1 multi-tap filters (floating point accumulation)

local function near(a, b)
  return math.abs(a - b) < EPS
end

local function near_tol(a, b, tol)
  return math.abs(a - b) < tol
end

local function near_arr(a, b, tol)
  tol = tol or EPS
  if #a ~= #b then return false end
  for i = 1, #a do
    if not near_tol(a[i], b[i], tol) then return false end
  end
  return true
end

local function energy(arr)
  local s = 0
  for i = 1, #arr do s = s + arr[i] * arr[i] end
  return s
end

-- ---------------------------------------------------------------------------
T.describe("wavelet module", function()

  T.describe("wavelet_info", function()
    T.it("returns info for haar", function()
      local info = W.wavelet_info("haar")
      T.ok(info ~= nil, "info not nil")
      T.eq(info.name, "haar")
      T.eq(info.vanishing_moments, 1)
      T.eq(#info.dec_lo, 2)
      T.eq(#info.dec_hi, 2)
      T.eq(#info.rec_lo, 2)
      T.eq(#info.rec_hi, 2)
    end)

    T.it("returns info for db2", function()
      local info = W.wavelet_info("db2")
      T.ok(info ~= nil, "info not nil")
      T.eq(info.vanishing_moments, 2)
      T.eq(#info.dec_lo, 4)
      T.eq(#info.dec_hi, 4)
    end)

    T.it("returns info for db4", function()
      local info = W.wavelet_info("db4")
      T.ok(info ~= nil, "info not nil")
      T.eq(info.vanishing_moments, 4)
      T.eq(#info.dec_lo, 8)
      T.eq(#info.dec_hi, 8)
    end)

    T.it("returns nil for unknown wavelet", function()
      local info, err = W.wavelet_info("unknown_xyz")
      T.eq(info, nil)
      T.ok(err ~= nil, "error message present")
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("Haar DWT", function()
    T.it("known output for constant signal {1,1,1,1}", function()
      local approx, detail = W.dwt({1, 1, 1, 1}, "haar")
      T.ok(near(approx[1], SQRT2), "approx[1] = sqrt2")
      T.ok(near(approx[2], SQRT2), "approx[2] = sqrt2")
      T.ok(near(detail[1], 0), "detail[1] = 0")
      T.ok(near(detail[2], 0), "detail[2] = 0")
    end)

    T.it("known output for {1,0,1,0}", function()
      local approx, detail = W.dwt({1, 0, 1, 0}, "haar")
      T.ok(near(approx[1], INV_SQRT2), "approx[1]")
      T.ok(near(approx[2], INV_SQRT2), "approx[2]")
      T.ok(near(detail[1], INV_SQRT2), "detail[1]")
      T.ok(near(detail[2], INV_SQRT2), "detail[2]")
    end)

    T.it("output lengths are half the input", function()
      local sig = {1, 2, 3, 4, 5, 6, 7, 8}
      local approx, detail = W.dwt(sig, "haar")
      T.eq(#approx, 4)
      T.eq(#detail, 4)
    end)

    T.it("round-trip: idwt(dwt(x)) ≈ x", function()
      local sig = {3, 1, 4, 1, 5, 9, 2, 6}
      local approx, detail = W.dwt(sig, "haar")
      local rec = W.idwt(approx, detail, "haar")
      T.ok(near_arr(rec, sig), "round-trip haar")
    end)

    T.it("energy preservation", function()
      local sig = {3, 1, 4, 1, 5, 9, 2, 6}
      local approx, detail = W.dwt(sig, "haar")
      local e_in = energy(sig)
      local e_out = energy(approx) + energy(detail)
      T.ok(near(e_in, e_out), "energy preserved")
    end)

    T.it("round-trip for length-2 signal", function()
      local sig = {3, 7}
      local approx, detail = W.dwt(sig, "haar")
      local rec = W.idwt(approx, detail, "haar")
      T.ok(near_arr(rec, sig), "round-trip length 2")
    end)

    T.it("round-trip for all-zeros signal", function()
      local sig = {0, 0, 0, 0}
      local approx, detail = W.dwt(sig, "haar")
      local rec = W.idwt(approx, detail, "haar")
      T.ok(near_arr(rec, sig), "round-trip zeros")
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("db2 DWT", function()
    T.it("output lengths are half the input", function()
      local sig = {1, 2, 3, 4, 5, 6, 7, 8}
      local approx, detail = W.dwt(sig, "db2")
      T.eq(#approx, 4)
      T.eq(#detail, 4)
    end)

    T.it("round-trip: idwt(dwt(x)) ≈ x", function()
      local sig = {3, 1, 4, 1, 5, 9, 2, 6}
      local approx, detail = W.dwt(sig, "db2")
      local rec = W.idwt(approx, detail, "db2")
      T.ok(near_arr(rec, sig, EPS_DB), "round-trip db2")
    end)

    T.it("round-trip for length-4 signal", function()
      local sig = {1, -2, 3, -4}
      local approx, detail = W.dwt(sig, "db2")
      local rec = W.idwt(approx, detail, "db2")
      T.ok(near_arr(rec, sig, EPS_DB), "round-trip db2 length 4")
    end)

    T.it("round-trip for constant signal", function()
      local sig = {5, 5, 5, 5, 5, 5, 5, 5}
      local approx, detail = W.dwt(sig, "db2")
      local rec = W.idwt(approx, detail, "db2")
      T.ok(near_arr(rec, sig, EPS_DB), "round-trip db2 constant")
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("db4 DWT", function()
    T.it("round-trip: idwt(dwt(x)) ≈ x", function()
      local sig = {3, 1, 4, 1, 5, 9, 2, 6}
      local approx, detail = W.dwt(sig, "db4")
      local rec = W.idwt(approx, detail, "db4")
      T.ok(near_arr(rec, sig, EPS_DB), "round-trip db4")
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("coif1 DWT", function()
    T.it("round-trip: idwt(dwt(x)) ≈ x", function()
      local sig = {2, 4, 6, 8, 6, 4, 2, 0}
      local approx, detail = W.dwt(sig, "coif1")
      local rec = W.idwt(approx, detail, "coif1")
      T.ok(near_arr(rec, sig, EPS_DB), "round-trip coif1")
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("wavedec / waverec", function()
    T.it("level-1 matches single dwt", function()
      local sig = {1, 2, 3, 4, 5, 6, 7, 8}
      local coeffs = W.wavedec(sig, 1, "haar")
      local approx, detail = W.dwt(sig, "haar")
      T.ok(near_arr(coeffs[1], approx), "approx matches")
      T.ok(near_arr(coeffs[2], detail), "detail matches")
    end)

    T.it("level-1 round-trip haar", function()
      local sig = {3, 1, 4, 1, 5, 9, 2, 6}
      local coeffs = W.wavedec(sig, 1, "haar")
      local rec = W.waverec(coeffs, "haar")
      T.ok(near_arr(rec, sig), "level-1 round-trip")
    end)

    T.it("level-2 round-trip haar", function()
      local sig = {3, 1, 4, 1, 5, 9, 2, 6}
      local coeffs = W.wavedec(sig, 2, "haar")
      T.eq(#coeffs, 3)  -- approx + 2 detail levels
      local rec = W.waverec(coeffs, "haar")
      T.ok(near_arr(rec, sig), "level-2 round-trip")
    end)

    T.it("level-3 round-trip haar", function()
      local sig = {3, 1, 4, 1, 5, 9, 2, 6}
      local coeffs = W.wavedec(sig, 3, "haar")
      T.eq(#coeffs, 4)  -- approx + 3 detail levels
      local rec = W.waverec(coeffs, "haar")
      T.ok(near_arr(rec, sig), "level-3 round-trip")
    end)

    T.it("level-2 round-trip db2", function()
      local sig = {1, 2, 3, 4, 5, 6, 7, 8}
      local coeffs = W.wavedec(sig, 2, "db2")
      local rec = W.waverec(coeffs, "db2")
      T.ok(near_arr(rec, sig, EPS_DB), "level-2 round-trip db2")
    end)

    T.it("returns error for level < 1", function()
      local result, err = W.wavedec({1,2,3,4}, 0, "haar")
      T.eq(result, nil)
      T.ok(err ~= nil, "error for level 0")
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("2D DWT (Haar)", function()
    T.it("LL subband concentrates energy, detail bands zero for constant matrix", function()
      -- 2x2 constant matrix
      local mat = {{4, 4}, {4, 4}}
      local LL, LH, HL, HH = W.dwt2(mat, "haar")
      -- Two passes of Haar: each pass multiplies by sqrt(2), so LL = 4 * 2 = 8
      T.ok(LL ~= nil, "LL not nil")
      T.ok(near(LL[1][1], 8), "LL[1][1] = 8 (two sqrt(2) passes on constant 4)")
      T.ok(near(LH[1][1], 0), "LH = 0 for constant")
      T.ok(near(HL[1][1], 0), "HL = 0 for constant")
      T.ok(near(HH[1][1], 0), "HH = 0 for constant")
    end)

    T.it("round-trip: idwt2(dwt2(m)) ≈ m for 2x2", function()
      local mat = {{1, 2}, {3, 4}}
      local LL, LH, HL, HH = W.dwt2(mat, "haar")
      local rec = W.idwt2(LL, LH, HL, HH, "haar")
      T.ok(near(rec[1][1], mat[1][1]), "[1][1]")
      T.ok(near(rec[1][2], mat[1][2]), "[1][2]")
      T.ok(near(rec[2][1], mat[2][1]), "[2][1]")
      T.ok(near(rec[2][2], mat[2][2]), "[2][2]")
    end)

    T.it("round-trip: idwt2(dwt2(m)) ≈ m for 4x4", function()
      local mat = {
        {1, 2, 3, 4},
        {5, 6, 7, 8},
        {9, 10, 11, 12},
        {13, 14, 15, 16},
      }
      local LL, LH, HL, HH = W.dwt2(mat, "haar")
      local rec = W.idwt2(LL, LH, HL, HH, "haar")
      local ok = true
      for r = 1, 4 do
        for c = 1, 4 do
          if not near(rec[r][c], mat[r][c]) then
            ok = false
            break
          end
        end
      end
      T.ok(ok, "4x4 round-trip")
    end)

    T.it("round-trip with db2 for 4x4", function()
      local mat = {
        {3, 1, 4, 1},
        {5, 9, 2, 6},
        {5, 3, 5, 8},
        {9, 7, 9, 3},
      }
      local LL, LH, HL, HH = W.dwt2(mat, "db2")
      local rec = W.idwt2(LL, LH, HL, HH, "db2")
      local ok = true
      for r = 1, 4 do
        for c = 1, 4 do
          if not near_tol(rec[r][c], mat[r][c], EPS_DB) then ok = false end
        end
      end
      T.ok(ok, "4x4 db2 round-trip")
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("threshold", function()
    T.it("hard threshold zeros small values", function()
      local arr = {-3, -1, 0, 1, 3}
      W.threshold(arr, 1.5, "hard")
      T.eq(arr[1], -3)
      T.eq(arr[2], 0)   -- |−1| < 1.5 → 0
      T.eq(arr[3], 0)
      T.eq(arr[4], 0)   -- |1| < 1.5 → 0
      T.eq(arr[5], 3)
    end)

    T.it("hard threshold returns same table", function()
      local arr = {1, 2, 3}
      local ret = W.threshold(arr, 0.5, "hard")
      T.ok(ret == arr, "returns same table")
    end)

    T.it("soft threshold shrinks values toward zero", function()
      local arr = {-3, -1, 0, 1, 3}
      W.threshold(arr, 1.5, "soft")
      T.ok(near(arr[1], -1.5), "−3 → −1.5")
      T.eq(arr[2], 0)          -- |−1| <= 1.5 → 0
      T.eq(arr[3], 0)
      T.eq(arr[4], 0)          -- |1| <= 1.5 → 0
      T.ok(near(arr[5], 1.5), "3 → 1.5")
    end)

    T.it("soft threshold at boundary becomes zero", function()
      local arr = {1.5, -1.5}
      W.threshold(arr, 1.5, "soft")
      T.eq(arr[1], 0)
      T.eq(arr[2], 0)
    end)

    T.it("threshold returns nil for unknown mode", function()
      local arr = {1, 2, 3}
      local ret, err = W.threshold(arr, 1, "bogus")
      T.eq(ret, nil)
      T.ok(err ~= nil, "error for unknown mode")
    end)

    T.it("hard threshold with zero thresh leaves all unchanged", function()
      local arr = {1, -2, 3}
      W.threshold(arr, 0, "hard")
      T.eq(arr[1], 1)
      T.eq(arr[2], -2)
      T.eq(arr[3], 3)
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("pad_to_power_of_2", function()
    T.it("pads length 3 to 4", function()
      local out = W.pad_to_power_of_2({1, 2, 3})
      T.eq(#out, 4)
      T.eq(out[1], 1)
      T.eq(out[2], 2)
      T.eq(out[3], 3)
      T.eq(out[4], 0)
    end)

    T.it("pads length 5 to 8", function()
      local out = W.pad_to_power_of_2({1, 2, 3, 4, 5})
      T.eq(#out, 8)
      T.eq(out[5], 5)
      T.eq(out[6], 0)
      T.eq(out[7], 0)
      T.eq(out[8], 0)
    end)

    T.it("leaves power-of-2 length unchanged", function()
      local sig = {1, 2, 3, 4}
      local out = W.pad_to_power_of_2(sig)
      T.eq(#out, 4)
      T.ok(near_arr(out, sig), "same values")
    end)

    T.it("handles length 1", function()
      local out = W.pad_to_power_of_2({7})
      T.eq(#out, 1)
      T.eq(out[1], 7)
    end)

    T.it("pads length 6 to 8", function()
      local out = W.pad_to_power_of_2({1, 2, 3, 4, 5, 6})
      T.eq(#out, 8)
      T.eq(out[7], 0)
      T.eq(out[8], 0)
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("M._tier", function()
    T.it("is 'pure'", function()
      T.eq(W._tier, "pure")
    end)
  end)

end)
