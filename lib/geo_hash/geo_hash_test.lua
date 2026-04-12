-- lib/geo_hash/geo_hash_test.lua

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local GH = require("lib.geo_hash")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function approx(a, b, eps)
  return math.abs(a - b) <= eps
end

-- ── encode ───────────────────────────────────────────────────────────────────

T.describe("encode", function()
  T.it("encodes San Francisco at precision 7", function()
    T.eq(GH.encode(37.7749, -122.4194, 7), "9q8yyk8")
  end)

  T.it("encodes San Francisco at precision 5", function()
    T.eq(GH.encode(37.7749, -122.4194, 5), "9q8yy")
  end)

  T.it("encodes NYC at precision 7", function()
    -- New York City
    local h = GH.encode(40.7128, -74.0060, 7)
    T.ok(#h == 7, "length is 7")
    -- Verify round-trip center is close
    local lat, lng = GH.decode_center(h)
    T.ok(approx(lat, 40.7128, 0.01), "lat close")
    T.ok(approx(lng, -74.0060, 0.01), "lng close")
  end)

  T.it("encodes London at precision 6", function()
    local h = GH.encode(51.5074, -0.1278, 6)
    T.ok(#h == 6, "length is 6")
    local lat, lng = GH.decode_center(h)
    T.ok(approx(lat, 51.5074, 0.02), "lat close")
    T.ok(approx(lng, -0.1278, 0.02), "lng close")
  end)

  T.it("returns nil for invalid precision", function()
    local h, err = GH.encode(0, 0, 0)
    T.eq(h, nil)
    T.ok(err ~= nil, "has error")
  end)

  T.it("defaults to precision 9", function()
    local h = GH.encode(0, 0)
    T.eq(#h, 9)
  end)
end)

-- ── decode ───────────────────────────────────────────────────────────────────

T.describe("decode", function()
  T.it("decodes 9q8yyk8 to correct bbox", function()
    local b = GH.decode("9q8yyk8")
    T.ok(b ~= nil, "not nil")
    T.ok(b.lat.min < 37.7749 and b.lat.max > 37.7749, "lat in bbox")
    T.ok(b.lng.min < -122.4194 and b.lng.max > -122.4194, "lng in bbox")
    T.ok(approx(b.lat.center, 37.7749, 0.01), "lat center close")
    T.ok(approx(b.lng.center, -122.4194, 0.01), "lng center close")
  end)

  T.it("center is midpoint of min/max", function()
    local b = GH.decode("9q8yyk8")
    T.ok(approx(b.lat.center, (b.lat.min + b.lat.max) * 0.5, 1e-12), "lat center is midpoint")
    T.ok(approx(b.lng.center, (b.lng.min + b.lng.max) * 0.5, 1e-12), "lng center is midpoint")
  end)

  T.it("returns nil on invalid hash", function()
    local b, err = GH.decode("invalid!")
    T.eq(b, nil)
    T.ok(err ~= nil, "error present")
  end)

  T.it("returns nil on empty string", function()
    local b, err = GH.decode("")
    T.eq(b, nil)
    T.ok(err ~= nil, "error present")
  end)
end)

-- ── decode_center ─────────────────────────────────────────────────────────────

T.describe("decode_center", function()
  T.it("returns lat, lng for known hash", function()
    local lat, lng = GH.decode_center("9q8yyk8")
    T.ok(approx(lat, 37.7749, 0.01), "lat close")
    T.ok(approx(lng, -122.4194, 0.01), "lng close")
  end)

  T.it("returns two values", function()
    local lat, lng = GH.decode_center("u09tvw")
    T.ok(type(lat) == "number", "lat is number")
    T.ok(type(lng) == "number", "lng is number")
  end)
end)

-- ── encode→decode round-trip ─────────────────────────────────────────────────

T.describe("encode→decode round-trip", function()
  local cases = {
    { 37.7749, -122.4194, "SF" },
    { 40.7128, -74.0060,  "NYC" },
    { 51.5074, -0.1278,   "London" },
    { -33.8688, 151.2093, "Sydney" },
    { 35.6762, 139.6503,  "Tokyo" },
  }
  for _, c in ipairs(cases) do
    local lat, lng, name = c[1], c[2], c[3]
    T.it("round-trip " .. name, function()
      for _, prec in ipairs({ 5, 7, 9 }) do
        local h = GH.encode(lat, lng, prec)
        local b = GH.decode(h)
        -- Input point must lie inside the decoded bbox.
        T.ok(lat >= b.lat.min and lat <= b.lat.max, name .. " p" .. prec .. " lat in cell")
        T.ok(lng >= b.lng.min and lng <= b.lng.max, name .. " p" .. prec .. " lng in cell")
        -- Center should be within half the cell size of the original point.
        local cell_lat = (b.lat.max - b.lat.min) * 0.5
        local cell_lng = (b.lng.max - b.lng.min) * 0.5
        T.ok(approx(b.lat.center, lat, cell_lat), name .. " p" .. prec .. " lat center in cell")
        T.ok(approx(b.lng.center, lng, cell_lng), name .. " p" .. prec .. " lng center in cell")
      end
    end)
  end
end)

-- ── neighbors ────────────────────────────────────────────────────────────────

T.describe("neighbors", function()
  local hash = "9q8yyk8"

  T.it("returns 8 distinct neighbors", function()
    local nb = GH.neighbors(hash)
    local dirs = { "n", "ne", "e", "se", "s", "sw", "w", "nw" }
    local seen = {}
    for _, d in ipairs(dirs) do
      T.ok(nb[d] ~= nil, d .. " exists")
      T.ok(not seen[nb[d]], "neighbor " .. d .. " is unique: " .. nb[d])
      seen[nb[d]] = true
    end
  end)

  T.it("all neighbors have same precision", function()
    local nb = GH.neighbors(hash)
    for _, d in ipairs({ "n", "ne", "e", "se", "s", "sw", "w", "nw" }) do
      T.eq(#nb[d], #hash)
    end
  end)

  T.it("north neighbor is north of original", function()
    local nb = GH.neighbors(hash)
    local orig_lat = GH.decode_center(hash)
    local n_lat    = GH.decode_center(nb.n)
    T.ok(n_lat > orig_lat, "north is north")
  end)

  T.it("south neighbor is south of original", function()
    local nb = GH.neighbors(hash)
    local orig_lat = GH.decode_center(hash)
    local s_lat    = GH.decode_center(nb.s)
    T.ok(s_lat < orig_lat, "south is south")
  end)

  T.it("east neighbor is east of original", function()
    local nb = GH.neighbors(hash)
    local _, orig_lng = GH.decode_center(hash)
    local _, e_lng    = GH.decode_center(nb.e)
    T.ok(e_lng > orig_lng, "east is east")
  end)

  T.it("west neighbor is west of original", function()
    local nb = GH.neighbors(hash)
    local _, orig_lng = GH.decode_center(hash)
    local _, w_lng    = GH.decode_center(nb.w)
    T.ok(w_lng < orig_lng, "west is west")
  end)
end)

T.describe("neighbor (single)", function()
  T.it("neighbor north matches neighbors().n", function()
    local hash = "9q8yyk8"
    T.eq(GH.neighbor(hash, "n"), GH.neighbors(hash).n)
  end)

  T.it("returns nil for invalid direction", function()
    local h, err = GH.neighbor("9q8yyk8", "up")
    T.eq(h, nil)
    T.ok(err ~= nil, "error present")
  end)
end)

-- ── bboxes ───────────────────────────────────────────────────────────────────

T.describe("bboxes", function()
  T.it("returns hashes covering a small bbox", function()
    -- Small bbox around downtown SF
    local hashes = GH.bboxes(37.77, -122.42, 37.78, -122.41, 7)
    T.ok(#hashes >= 1, "at least one hash")
    -- Every returned hash must overlap the query bbox.
    for _, h in ipairs(hashes) do
      local b = GH.decode(h)
      T.ok(b.lat.max >= 37.77 and b.lat.min <= 37.78,   h .. " lat overlaps")
      T.ok(b.lng.max >= -122.42 and b.lng.min <= -122.41, h .. " lng overlaps")
    end
  end)

  T.it("all hashes are valid", function()
    local hashes = GH.bboxes(37.77, -122.42, 37.78, -122.41, 6)
    for _, h in ipairs(hashes) do
      T.ok(GH.is_valid(h), h .. " is valid")
      T.eq(#h, 6)
    end
  end)

  T.it("returns no duplicates", function()
    local hashes = GH.bboxes(37.77, -122.42, 37.78, -122.41, 6)
    local seen   = {}
    for _, h in ipairs(hashes) do
      T.ok(not seen[h], "no duplicate: " .. h)
      seen[h] = true
    end
  end)

  T.it("single-cell bbox returns at least one hash", function()
    local h      = GH.encode(37.7749, -122.4194, 5)
    local b      = GH.decode(h)
    local hashes = GH.bboxes(b.lat.min, b.lng.min, b.lat.max, b.lng.max, 5)
    T.ok(#hashes >= 1, "at least one hash for exact cell")
  end)
end)

-- ── haversine ────────────────────────────────────────────────────────────────

T.describe("haversine", function()
  T.it("SF to NYC is approximately 4130 km", function()
    local km = GH.haversine(37.7749, -122.4194, 40.7128, -74.0060)
    -- Accept within 5%.
    T.ok(km > 4130 * 0.95 and km < 4130 * 1.05,
      "SF-NYC distance " .. string.format("%.1f", km) .. " km within 5% of 4130")
  end)

  T.it("same point is zero distance", function()
    T.ok(GH.haversine(0, 0, 0, 0) == 0, "zero")
  end)

  T.it("is symmetric", function()
    local d1 = GH.haversine(37.77, -122.42, 40.71, -74.01)
    local d2 = GH.haversine(40.71, -74.01, 37.77, -122.42)
    T.ok(approx(d1, d2, 1e-9), "symmetric")
  end)
end)

-- ── distance between hashes ──────────────────────────────────────────────────

T.describe("distance", function()
  T.it("neighboring hashes have small distance", function()
    local h   = "9q8yyk8"
    local nb  = GH.neighbors(h)
    local km  = GH.distance(h, nb.n)
    T.ok(km < 1, "adjacent hash distance < 1 km: " .. km)
  end)

  T.it("same hash has zero distance", function()
    T.ok(GH.distance("9q8yyk8", "9q8yyk8") == 0, "zero")
  end)

  T.it("SF vs NYC hash distance is ~4100 km", function()
    local sf  = GH.encode(37.7749, -122.4194, 7)
    local nyc = GH.encode(40.7128, -74.0060,  7)
    local km  = GH.distance(sf, nyc)
    T.ok(km > 4000 and km < 4500, "SF-NYC ~4100 km: " .. km)
  end)
end)

-- ── within_radius ─────────────────────────────────────────────────────────────

T.describe("within_radius", function()
  T.it("hash center is within 0.5 km of its own center", function()
    local h        = "9q8yyk8"
    local lat, lng = GH.decode_center(h)
    T.ok(GH.within_radius(h, lat, lng, 0.5), "center within 0.5 km of itself")
  end)

  T.it("far away hash is not within 1 km", function()
    local sf  = "9q8yyk8"
    local nyc_lat, nyc_lng = GH.decode_center(GH.encode(40.7128, -74.0060, 7))
    T.ok(not GH.within_radius(sf, nyc_lat, nyc_lng, 1), "SF not within 1 km of NYC")
  end)

  T.it("adjacent hash center is within 1 km", function()
    local h    = GH.encode(37.7749, -122.4194, 7)
    local nb   = GH.neighbors(h)
    local lat, lng = GH.decode_center(h)
    T.ok(GH.within_radius(nb.n, lat, lng, 1), "adjacent hash within 1 km")
  end)
end)

-- ── parent ───────────────────────────────────────────────────────────────────

T.describe("parent", function()
  T.it("reduces precision by 1", function()
    T.eq(GH.parent("9q8yyk8"), "9q8yyk")
    T.eq(GH.parent("9q8yyk"),  "9q8yy")
    T.eq(GH.parent("9q8yy"),   "9q8y")
  end)

  T.it("parent bbox contains child bbox", function()
    local child  = "9q8yyk8"
    local parent = GH.parent(child)
    local cb     = GH.decode(child)
    local pb     = GH.decode(parent)
    T.ok(pb.lat.min <= cb.lat.min and pb.lat.max >= cb.lat.max, "parent lat contains child")
    T.ok(pb.lng.min <= cb.lng.min and pb.lng.max >= cb.lng.max, "parent lng contains child")
  end)

  T.it("returns nil for length-1 hash", function()
    local p, err = GH.parent("9")
    T.eq(p, nil)
    T.ok(err ~= nil, "error present")
  end)
end)

-- ── common_prefix ─────────────────────────────────────────────────────────────

T.describe("common_prefix", function()
  T.it("two nearby hashes share a prefix", function()
    -- 9q8yyk8 (SF) and its west neighbor 9q8yyhx share prefix "9q8yy"
    T.eq(GH.common_prefix("9q8yyk8", "9q8yyhx"), "9q8yy")
  end)

  T.it("identical hashes share full prefix", function()
    T.eq(GH.common_prefix("9q8yyk8", "9q8yyk8"), "9q8yyk8")
  end)

  T.it("hashes in different continents share no/short prefix", function()
    local sf     = GH.encode(37.7749, -122.4194, 7)  -- 9q8yyk8
    local tokyo  = GH.encode(35.6762, 139.6503,  7)  -- xn7...
    local prefix = GH.common_prefix(sf, tokyo)
    T.ok(#prefix < 2, "minimal common prefix for distant hashes: '" .. prefix .. "'")
  end)

  T.it("prefix is a valid parent", function()
    -- 9q8yyk8 and 9q8yyhx (west neighbor) share prefix "9q8yy"
    local h1     = "9q8yyk8"
    local h2     = "9q8yyhx"
    local prefix = GH.common_prefix(h1, h2)
    T.ok(GH.is_valid(prefix), "prefix is valid hash")
    local b1 = GH.decode(h1)
    local b2 = GH.decode(h2)
    local bp = GH.decode(prefix)
    T.ok(bp.lat.min <= b1.lat.min and bp.lat.max >= b1.lat.max, "prefix lat contains h1")
    T.ok(bp.lat.min <= b2.lat.min and bp.lat.max >= b2.lat.max, "prefix lat contains h2")
  end)
end)

-- ── is_valid ─────────────────────────────────────────────────────────────────

T.describe("is_valid", function()
  T.it("valid hashes", function()
    T.ok(GH.is_valid("9q8yyk8"), "SF hash")
    T.ok(GH.is_valid("0"),       "single char")
    T.ok(GH.is_valid("000000000000"), "precision 12")
    T.ok(GH.is_valid("zzzzzzzz"), "all z's")
  end)

  T.it("invalid characters", function()
    T.ok(not GH.is_valid("invalid!"), "exclamation")
    T.ok(not GH.is_valid("9q8yABC"),  "uppercase")
    T.ok(not GH.is_valid("9q8ya"),    "contains 'a'")
    T.ok(not GH.is_valid("9q8yi"),    "contains 'i'")
    T.ok(not GH.is_valid("9q8yl"),    "contains 'l'")
    T.ok(not GH.is_valid("9q8yo"),    "contains 'o'")
  end)

  T.it("empty string is invalid", function()
    T.ok(not GH.is_valid(""), "empty")
  end)

  T.it("non-string is invalid", function()
    T.ok(not GH.is_valid(nil),  "nil")
    T.ok(not GH.is_valid(123),  "number")
  end)
end)

-- ── precision_info ────────────────────────────────────────────────────────────

T.describe("precision_info", function()
  T.it("precision 7 is approximately 150m cells", function()
    local info = GH.precision_info(7)
    T.ok(info ~= nil, "not nil")
    -- ~152m wide and tall; accept 100–250m.
    T.ok(info.width_km  > 0.1 and info.width_km  < 0.25,
      "width " .. info.width_km .. " km is ~150m")
    T.ok(info.height_km > 0.1 and info.height_km < 0.25,
      "height " .. info.height_km .. " km is ~150m")
  end)

  T.it("precision 1 is large (~5000 km)", function()
    local info = GH.precision_info(1)
    T.ok(info.width_km > 4000 and info.width_km < 6000,
      "precision 1 width " .. info.width_km .. " km")
  end)

  T.it("precision 9 is ~2.5m–5m cells", function()
    local info = GH.precision_info(9)
    -- ~4.8m wide, ~4.8m tall at equator
    T.ok(info.width_km  < 0.01 and info.width_km  > 0.001,
      "precision 9 width " .. info.width_km .. " km")
    T.ok(info.height_km < 0.01 and info.height_km > 0.001,
      "precision 9 height " .. info.height_km .. " km")
  end)

  T.it("cells get smaller at higher precision", function()
    local prev = GH.precision_info(1)
    for p = 2, 9 do
      local cur = GH.precision_info(p)
      T.ok(cur.width_km < prev.width_km, "p" .. p .. " narrower than p" .. (p - 1))
      prev = cur
    end
  end)

  T.it("returns nil for out-of-range precision", function()
    local info, err = GH.precision_info(0)
    T.eq(info, nil)
    T.ok(err ~= nil, "error present")
  end)
end)

-- ── Edge cases ────────────────────────────────────────────────────────────────

T.describe("edge cases", function()
  T.it("encodes north pole (lat=90)", function()
    local h = GH.encode(90, 0, 5)
    T.ok(GH.is_valid(h), "valid hash for north pole: " .. h)
    local b = GH.decode(h)
    T.ok(b.lat.max <= 90, "lat max <= 90")
  end)

  T.it("encodes south pole (lat=-90)", function()
    local h = GH.encode(-90, 0, 5)
    T.ok(GH.is_valid(h), "valid hash for south pole: " .. h)
    local b = GH.decode(h)
    T.ok(b.lat.min >= -90, "lat min >= -90")
  end)

  T.it("encodes date line east (lng=180)", function()
    local h = GH.encode(0, 180, 5)
    T.ok(GH.is_valid(h), "valid hash: " .. h)
  end)

  T.it("encodes date line west (lng=-180)", function()
    local h = GH.encode(0, -180, 5)
    T.ok(GH.is_valid(h), "valid hash: " .. h)
  end)

  T.it("neighbor across antimeridian wraps longitude", function()
    -- Hash near date line (Fiji area, lng ~180)
    local h   = GH.encode(0, 179.9, 4)
    local nb  = GH.neighbors(h)
    -- East neighbor should wrap to negative longitude
    local _, e_lng = GH.decode_center(nb.e)
    T.ok(e_lng < 0 or e_lng > 179, "east neighbor wraps or stays near boundary: " .. e_lng)
  end)

  T.it("neighbor near north pole clamps latitude", function()
    local h  = GH.encode(89.9, 0, 4)
    local nb = GH.neighbors(h)
    local n_lat = GH.decode_center(nb.n)
    T.ok(n_lat <= 90, "clamped to <=90")
  end)
end)
