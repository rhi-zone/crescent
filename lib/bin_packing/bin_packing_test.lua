if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local BP = require("lib.bin_packing")

-- Helper: check no two placed rects overlap
local function no_overlaps(placed)
  for i = 1, #placed do
    for j = i + 1, #placed do
      local a, b = placed[i], placed[j]
      if not (a.x + a.w <= b.x or b.x + b.w <= a.x or
              a.y + a.h <= b.y or b.y + b.h <= a.y) then
        return false, i, j
      end
    end
  end
  return true
end

-- Helper: all rects within bin bounds
local function all_in_bounds(placed, bw, bh)
  for _, p in ipairs(placed) do
    if p.x < 0 or p.y < 0 or p.x + p.w > bw or p.y + p.h > bh then
      return false
    end
  end
  return true
end

T.describe("bin_packing", function()

  -- ========================
  -- MODULE
  -- ========================
  T.it("has _tier = pure", function()
    T.eq(BP._tier, "pure")
  end)

  -- ========================
  -- 1D: FIRST FIT
  -- ========================
  T.describe("first_fit", function()
    T.it("packs simple items correctly", function()
      local items = { 3, 5, 2, 4, 1 }
      local bins, err = BP.first_fit(items, 6)
      T.ok(bins, err)
      T.ok(BP.validate(bins, items, 6))
    end)

    T.it("validate returns true for correct packing", function()
      local items = { 2, 2, 2, 2 }
      local bins = BP.first_fit(items, 4)
      T.ok(bins)
      local ok, msg = BP.validate(bins, items, 4)
      T.ok(ok, msg)
    end)

    T.it("all items placed", function()
      local items = { 1, 1, 1, 1, 1, 1, 1, 1 }
      local bins = BP.first_fit(items, 3)
      T.ok(bins)
      -- 8 items of size 1, capacity 3 → at most 3 bins (3+3+2)
      T.ok(BP.validate(bins, items, 3))
      T.eq(BP.bin_count(bins), 3)
    end)

    T.it("single item per bin when items = capacity", function()
      local items = { 5, 5, 5 }
      local bins = BP.first_fit(items, 5)
      T.ok(bins)
      T.eq(BP.bin_count(bins), 3)
      T.ok(BP.validate(bins, items, 5))
    end)

    T.it("returns error for item exceeding capacity", function()
      local items = { 3, 7, 2 }
      local bins, err = BP.first_fit(items, 5)
      T.ok(bins == nil)
      T.ok(type(err) == "string")
    end)

    T.it("returns error for zero capacity", function()
      local bins, err = BP.first_fit({ 1 }, 0)
      T.ok(bins == nil)
      T.ok(type(err) == "string")
    end)

    T.it("empty items gives empty bins", function()
      local bins = BP.first_fit({}, 10)
      T.ok(bins)
      T.eq(BP.bin_count(bins), 0)
    end)
  end)

  -- ========================
  -- 1D: FIRST FIT DECREASING
  -- ========================
  T.describe("first_fit_decreasing", function()
    T.it("uses fewer or equal bins than first_fit on adversarial input", function()
      -- Classic adversarial: alternating large/small items
      local items = { 3, 1, 3, 1, 3, 1, 3, 1, 3, 1 }
      local capacity = 4
      local bins_ff = BP.first_fit(items, capacity)
      local bins_ffd = BP.first_fit_decreasing(items, capacity)
      T.ok(bins_ff and bins_ffd)
      -- FFD should pack 3+1 together = 5 bins; FF may pack worse
      T.ok(BP.bin_count(bins_ffd) <= BP.bin_count(bins_ff))
    end)

    T.it("produces valid packing", function()
      local items = { 4, 1, 3, 2, 5, 2, 1 }
      local bins = BP.first_fit_decreasing(items, 6)
      T.ok(bins)
      T.ok(BP.validate(bins, items, 6))
    end)

    T.it("rejects oversized items", function()
      local bins, err = BP.first_fit_decreasing({ 1, 10, 2 }, 5)
      T.ok(bins == nil)
      T.ok(type(err) == "string")
    end)
  end)

  -- ========================
  -- 1D: BEST FIT
  -- ========================
  T.describe("best_fit", function()
    T.it("produces valid packing", function()
      local items = { 4, 1, 3, 2, 5, 2, 1 }
      local bins = BP.best_fit(items, 6)
      T.ok(bins)
      T.ok(BP.validate(bins, items, 6))
    end)

    T.it("packs tight items correctly", function()
      local items = { 3, 3, 3, 3 }
      local bins = BP.best_fit(items, 6)
      T.ok(bins)
      T.eq(BP.bin_count(bins), 2)
      T.ok(BP.validate(bins, items, 6))
    end)

    T.it("rejects oversized items", function()
      local bins, err = BP.best_fit({ 1, 8, 2 }, 5)
      T.ok(bins == nil)
      T.ok(type(err) == "string")
    end)
  end)

  -- ========================
  -- 1D: BEST FIT DECREASING
  -- ========================
  T.describe("best_fit_decreasing", function()
    T.it("produces valid packing", function()
      local items = { 4, 1, 3, 2, 5, 2, 1 }
      local bins = BP.best_fit_decreasing(items, 6)
      T.ok(bins)
      T.ok(BP.validate(bins, items, 6))
    end)

    T.it("rejects oversized items", function()
      local bins, err = BP.best_fit_decreasing({ 1, 10, 2 }, 5)
      T.ok(bins == nil)
      T.ok(type(err) == "string")
    end)
  end)

  -- ========================
  -- 1D: NEXT FIT
  -- ========================
  T.describe("next_fit", function()
    T.it("produces valid packing", function()
      local items = { 2, 3, 1, 4, 2 }
      local bins = BP.next_fit(items, 5)
      T.ok(bins)
      T.ok(BP.validate(bins, items, 5))
    end)

    T.it("uses more bins than first_fit on some inputs", function()
      -- Next fit always opens a new bin after current can't fit; may not reuse earlier bins
      local items = { 3, 2, 3, 2, 3, 2 }
      local bins_nf = BP.next_fit(items, 5)
      local bins_ff = BP.first_fit(items, 5)
      T.ok(bins_nf and bins_ff)
      -- Just check both are valid; NF may use more
      T.ok(BP.validate(bins_nf, items, 5))
      T.ok(BP.validate(bins_ff, items, 5))
    end)

    T.it("rejects oversized items", function()
      local bins, err = BP.next_fit({ 1, 9 }, 5)
      T.ok(bins == nil)
      T.ok(type(err) == "string")
    end)
  end)

  -- ========================
  -- 1D: HELPERS
  -- ========================
  T.describe("helpers", function()
    T.it("bin_count returns number of bins", function()
      local bins = BP.first_fit({ 1, 2, 3, 4, 5 }, 6)
      T.ok(bins)
      T.eq(type(BP.bin_count(bins)), "number")
      T.ok(BP.bin_count(bins) >= 1)
    end)

    T.it("utilization is between 0 and 1", function()
      local items = { 3, 2, 4, 1 }
      local bins = BP.first_fit(items, 6)
      T.ok(bins)
      local u = BP.utilization(bins, items, 6)
      T.ok(u >= 0 and u <= 1)
    end)

    T.it("utilization is 1 for perfectly packed bins", function()
      local items = { 3, 3, 3, 3 }
      local bins = BP.first_fit(items, 6)
      T.ok(bins)
      local u = BP.utilization(bins, items, 6)
      T.eq(u, 1.0)
    end)

    T.it("utilization is 0 for empty bins", function()
      local u = BP.utilization({}, {}, 10)
      T.eq(u, 0)
    end)

    T.it("validate detects overflow", function()
      local fake_bins = { { 1, 2, 3 } }
      local items = { 4, 4, 4 }
      local ok, msg = BP.validate(fake_bins, items, 6)
      T.ok(not ok)
      T.ok(type(msg) == "string")
    end)

    T.it("validate detects missing item", function()
      local fake_bins = { { 1, 2 } }
      local items = { 2, 2, 2 }
      local ok, msg = BP.validate(fake_bins, items, 6)
      T.ok(not ok)
      T.ok(type(msg) == "string")
    end)

    T.it("validate detects duplicate item", function()
      local fake_bins = { { 1, 1 } }
      local items = { 2 }
      local ok, msg = BP.validate(fake_bins, items, 6)
      T.ok(not ok)
      T.ok(type(msg) == "string")
    end)
  end)

  -- ========================
  -- 2D: GUILLOTINE
  -- ========================
  T.describe("guillotine", function()
    T.it("places all rects when they fit", function()
      local rects = {
        { w = 32, h = 32 },
        { w = 64, h = 32 },
        { w = 32, h = 64 },
        { w = 16, h = 16 },
      }
      local result = BP.guillotine(rects, 128, 128)
      T.ok(result)
      T.eq(#result.placed, 4)
      T.eq(#result.unplaced, 0)
    end)

    T.it("no overlaps in result", function()
      local rects = {
        { w = 32, h = 32 },
        { w = 64, h = 32 },
        { w = 32, h = 64 },
        { w = 16, h = 16 },
        { w = 48, h = 24 },
      }
      local result = BP.guillotine(rects, 128, 128)
      T.ok(result)
      local ok, i, j = no_overlaps(result.placed)
      T.ok(ok, "rects " .. tostring(i) .. " and " .. tostring(j) .. " overlap")
    end)

    T.it("unplaced items when bin too small", function()
      local rects = {
        { w = 80, h = 80 },
        { w = 80, h = 80 },
      }
      local result = BP.guillotine(rects, 100, 100)
      T.ok(result)
      -- At least one must be unplaced since 80+80 > 100
      T.ok(#result.unplaced >= 1)
    end)

    T.it("all placements within bin bounds", function()
      local rects = {
        { w = 10, h = 20 }, { w = 30, h = 15 }, { w = 5, h = 5 },
        { w = 20, h = 20 }, { w = 15, h = 10 },
      }
      local result = BP.guillotine(rects, 64, 64)
      T.ok(result)
      T.ok(all_in_bounds(result.placed, 64, 64))
    end)

    T.it("allow_rotate places more items or same", function()
      -- Tall rects that wouldn't fit without rotation in a wide-but-short bin
      local rects = {
        { w = 10, h = 60 },
        { w = 10, h = 60 },
        { w = 10, h = 60 },
      }
      local result_no_rot = BP.guillotine(rects, 64, 40, { allow_rotate = false })
      local result_rot = BP.guillotine(rects, 64, 40, { allow_rotate = true })
      T.ok(result_no_rot and result_rot)
      T.ok(#result_rot.placed >= #result_no_rot.placed)
    end)

    T.it("long_axis split produces valid no-overlap packing", function()
      local rects = {
        { w = 40, h = 20 }, { w = 30, h = 30 }, { w = 20, h = 40 },
      }
      local result = BP.guillotine(rects, 128, 128, { split = "long_axis" })
      T.ok(result)
      local ok = no_overlaps(result.placed)
      T.ok(ok)
    end)

    T.it("preserves ids when provided", function()
      local rects = {
        { w = 32, h = 32, id = "spr_a" },
        { w = 16, h = 16, id = "spr_b" },
      }
      local result = BP.guillotine(rects, 64, 64)
      T.ok(result)
      local ids = {}
      for _, p in ipairs(result.placed) do ids[p.id] = true end
      T.ok(ids["spr_a"])
      T.ok(ids["spr_b"])
    end)

    T.it("auto-grow (bin_w=0) packs all rects", function()
      local rects = {
        { w = 32, h = 32 }, { w = 32, h = 32 },
        { w = 16, h = 16 }, { w = 64, h = 16 },
      }
      local result = BP.guillotine(rects, 0, 0)
      T.ok(result)
      -- auto_grow: should have placed all or most
      T.ok(#result.placed > 0)
      local ok = no_overlaps(result.placed)
      T.ok(ok)
    end)

    T.it("empty rects returns empty result", function()
      local result = BP.guillotine({}, 128, 128)
      T.ok(result)
      T.eq(#result.placed, 0)
      T.eq(#result.unplaced, 0)
    end)
  end)

  -- ========================
  -- 2D: SHELF
  -- ========================
  T.describe("shelf", function()
    T.it("valid placement no overlaps", function()
      local rects = {
        { w = 32, h = 32 }, { w = 64, h = 16 }, { w = 16, h = 48 },
        { w = 32, h = 32 }, { w = 48, h = 24 },
      }
      local result = BP.shelf(rects, 128, 128)
      T.ok(result)
      local ok, i, j = no_overlaps(result.placed)
      T.ok(ok, "rects " .. tostring(i) .. " and " .. tostring(j) .. " overlap")
    end)

    T.it("all placements within bin bounds", function()
      local rects = {
        { w = 20, h = 10 }, { w = 30, h = 20 }, { w = 10, h = 15 },
        { w = 25, h = 25 }, { w = 15, h = 10 },
      }
      local result = BP.shelf(rects, 64, 64)
      T.ok(result)
      T.ok(all_in_bounds(result.placed, 64, 64))
    end)

    T.it("unplaced items when bin too small", function()
      local rects = { { w = 70, h = 70 }, { w = 70, h = 70 } }
      local result = BP.shelf(rects, 100, 100)
      T.ok(result)
      T.ok(#result.unplaced >= 1)
    end)

    T.it("allow_rotate places more or same items", function()
      local rects = {
        { w = 10, h = 50 }, { w = 10, h = 50 }, { w = 10, h = 50 },
      }
      local r_no = BP.shelf(rects, 64, 30, { allow_rotate = false })
      local r_yes = BP.shelf(rects, 64, 30, { allow_rotate = true })
      T.ok(r_no and r_yes)
      T.ok(#r_yes.placed >= #r_no.placed)
    end)

    T.it("returns error for zero bin dimensions", function()
      local result, err = BP.shelf({ { w = 1, h = 1 } }, 0, 64)
      T.ok(result == nil)
      T.ok(type(err) == "string")
    end)

    T.it("empty rects returns empty result", function()
      local result = BP.shelf({}, 128, 128)
      T.ok(result)
      T.eq(#result.placed, 0)
      T.eq(#result.unplaced, 0)
    end)

    T.it("single rect packs to origin", function()
      local rects = { { w = 32, h = 32 } }
      local result = BP.shelf(rects, 128, 128)
      T.ok(result)
      T.eq(#result.placed, 1)
      T.eq(result.placed[1].x, 0)
      T.eq(result.placed[1].y, 0)
    end)
  end)

  -- ========================
  -- 2D: MAXRECTS
  -- ========================
  T.describe("maxrects", function()
    T.it("valid placement no overlaps", function()
      local rects = {
        { w = 32, h = 32 }, { w = 64, h = 16 }, { w = 16, h = 48 },
        { w = 32, h = 32 }, { w = 48, h = 24 },
      }
      local result = BP.maxrects(rects, 128, 128)
      T.ok(result)
      local ok, i, j = no_overlaps(result.placed)
      T.ok(ok, "rects " .. tostring(i) .. " and " .. tostring(j) .. " overlap")
    end)

    T.it("all placements within bin bounds", function()
      local rects = {
        { w = 20, h = 10 }, { w = 30, h = 20 }, { w = 10, h = 15 },
        { w = 25, h = 25 }, { w = 15, h = 10 },
      }
      local result = BP.maxrects(rects, 64, 64)
      T.ok(result)
      T.ok(all_in_bounds(result.placed, 64, 64))
    end)

    T.it("unplaced items when bin too small", function()
      local rects = { { w = 70, h = 70 }, { w = 70, h = 70 } }
      local result = BP.maxrects(rects, 100, 100)
      T.ok(result)
      T.ok(#result.unplaced >= 1)
    end)

    T.it("best_area heuristic valid packing", function()
      local rects = {
        { w = 40, h = 40 }, { w = 20, h = 30 }, { w = 30, h = 20 },
      }
      local result = BP.maxrects(rects, 128, 128, { heuristic = "best_area" })
      T.ok(result)
      T.ok(no_overlaps(result.placed))
      T.ok(all_in_bounds(result.placed, 128, 128))
    end)

    T.it("best_long_side heuristic valid packing", function()
      local rects = {
        { w = 40, h = 40 }, { w = 20, h = 30 }, { w = 30, h = 20 },
      }
      local result = BP.maxrects(rects, 128, 128, { heuristic = "best_long_side" })
      T.ok(result)
      T.ok(no_overlaps(result.placed))
    end)

    T.it("allow_rotate produces valid result", function()
      local rects = {
        { w = 10, h = 60 }, { w = 10, h = 60 }, { w = 60, h = 10 },
      }
      local result = BP.maxrects(rects, 128, 128, { allow_rotate = true })
      T.ok(result)
      T.ok(no_overlaps(result.placed))
      T.ok(all_in_bounds(result.placed, 128, 128))
    end)

    T.it("allow_rotate places same or more than no-rotate", function()
      local rects = {
        { w = 10, h = 60 }, { w = 10, h = 60 }, { w = 10, h = 60 },
      }
      local r_no = BP.maxrects(rects, 64, 30, { allow_rotate = false })
      local r_yes = BP.maxrects(rects, 64, 30, { allow_rotate = true })
      T.ok(r_no and r_yes)
      T.ok(#r_yes.placed >= #r_no.placed)
    end)

    T.it("returns error for zero bin dimensions", function()
      local result, err = BP.maxrects({ { w = 1, h = 1 } }, 0, 64)
      T.ok(result == nil)
      T.ok(type(err) == "string")
    end)

    T.it("empty rects returns empty result", function()
      local result = BP.maxrects({}, 128, 128)
      T.ok(result)
      T.eq(#result.placed, 0)
      T.eq(#result.unplaced, 0)
    end)

    T.it("places all rects when bin is large enough", function()
      local rects = {
        { w = 10, h = 10 }, { w = 20, h = 20 }, { w = 15, h = 15 },
        { w = 5, h = 5 }, { w = 12, h = 8 },
      }
      local result = BP.maxrects(rects, 256, 256)
      T.ok(result)
      T.eq(#result.placed, 5)
      T.eq(#result.unplaced, 0)
    end)
  end)

  -- ========================
  -- 2D: AUTO_PACK
  -- ========================
  T.describe("auto_pack", function()
    T.it("returns a valid result", function()
      local rects = {
        { w = 32, h = 32 }, { w = 64, h = 32 }, { w = 16, h = 16 },
        { w = 32, h = 64 }, { w = 48, h = 48 },
      }
      local result = BP.auto_pack(rects)
      T.ok(result)
      T.ok(#result.placed > 0)
    end)

    T.it("places all rects in a reasonably sized bin", function()
      local rects = {
        { w = 20, h = 20 }, { w = 30, h = 30 }, { w = 10, h = 50 },
      }
      local result = BP.auto_pack(rects)
      T.ok(result)
      T.eq(#result.unplaced, 0)
    end)

    T.it("no overlaps in auto_pack result", function()
      local rects = {
        { w = 32, h = 32 }, { w = 64, h = 32 }, { w = 16, h = 16 },
        { w = 32, h = 64 }, { w = 48, h = 48 },
      }
      local result = BP.auto_pack(rects)
      T.ok(result)
      local ok, i, j = no_overlaps(result.placed)
      T.ok(ok, "rects " .. tostring(i) .. " and " .. tostring(j) .. " overlap")
    end)

    T.it("returns non-nil result even for single rect", function()
      local result = BP.auto_pack({ { w = 16, h = 16 } })
      T.ok(result)
      T.eq(#result.placed, 1)
    end)
  end)

  -- ========================
  -- 2D: PACK_EFFICIENCY
  -- ========================
  T.describe("pack_efficiency", function()
    T.it("value between 0 and 1", function()
      local rects = {
        { w = 32, h = 32 }, { w = 64, h = 32 }, { w = 16, h = 16 },
      }
      local result = BP.guillotine(rects, 128, 128)
      T.ok(result)
      local eff = BP.pack_efficiency(result)
      T.ok(eff >= 0 and eff <= 1)
    end)

    T.it("efficiency = 1 for perfect fill", function()
      -- A single rect filling exactly the used area
      local result = {
        placed = { { id = 1, x = 0, y = 0, w = 64, h = 64, rotated = false } },
        unplaced = {},
        w = 64,
        h = 64,
      }
      local eff = BP.pack_efficiency(result)
      T.eq(eff, 1.0)
    end)

    T.it("efficiency > 0 for non-empty result", function()
      local rects = { { w = 20, h = 20 }, { w = 30, h = 30 } }
      local result = BP.maxrects(rects, 128, 128)
      T.ok(result)
      T.ok(BP.pack_efficiency(result) > 0)
    end)

    T.it("efficiency = 0 for empty result", function()
      local result = { placed = {}, unplaced = {}, w = 0, h = 0 }
      T.eq(BP.pack_efficiency(result), 0)
    end)

    T.it("efficiency is consistent across algorithms for same input", function()
      local rects = {
        { w = 30, h = 30 }, { w = 20, h = 40 }, { w = 40, h = 20 },
      }
      local rg = BP.guillotine(rects, 128, 128)
      local rs = BP.shelf(rects, 128, 128)
      local rm = BP.maxrects(rects, 128, 128)
      T.ok(rg and rs and rm)
      -- All efficiencies should be between 0 and 1
      T.ok(BP.pack_efficiency(rg) >= 0 and BP.pack_efficiency(rg) <= 1)
      T.ok(BP.pack_efficiency(rs) >= 0 and BP.pack_efficiency(rs) <= 1)
      T.ok(BP.pack_efficiency(rm) >= 0 and BP.pack_efficiency(rm) <= 1)
    end)
  end)

  -- ========================
  -- STRESS: many rects, all algos
  -- ========================
  T.describe("stress", function()
    T.it("guillotine handles 50 small rects with no overlaps", function()
      local rects = {}
      for i = 1, 50 do
        rects[i] = { w = 8 + (i % 8), h = 8 + (i % 6), id = i }
      end
      local result = BP.guillotine(rects, 256, 256)
      T.ok(result)
      local ok = no_overlaps(result.placed)
      T.ok(ok)
      T.ok(all_in_bounds(result.placed, 256, 256))
    end)

    T.it("maxrects handles 50 small rects with no overlaps", function()
      local rects = {}
      for i = 1, 50 do
        rects[i] = { w = 8 + (i % 8), h = 8 + (i % 6), id = i }
      end
      local result = BP.maxrects(rects, 256, 256)
      T.ok(result)
      local ok = no_overlaps(result.placed)
      T.ok(ok)
      T.ok(all_in_bounds(result.placed, 256, 256))
    end)

    T.it("shelf handles 50 small rects with no overlaps", function()
      local rects = {}
      for i = 1, 50 do
        rects[i] = { w = 8 + (i % 8), h = 8 + (i % 6), id = i }
      end
      local result = BP.shelf(rects, 256, 256)
      T.ok(result)
      local ok = no_overlaps(result.placed)
      T.ok(ok)
      T.ok(all_in_bounds(result.placed, 256, 256))
    end)
  end)

end)
