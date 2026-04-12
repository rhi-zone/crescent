if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local geohash = require("lib.geohash")

T.describe("geohash.encode", function()
  T.it("known vector: u4pruydqqvj", function()
    T.eq(geohash.encode(57.64911, 10.40744, 11), "u4pruydqqvj")
  end)

  T.it("encode(0, 0, 1) => 's'", function()
    T.eq(geohash.encode(0, 0, 1), "s")
  end)

  T.it("precision 1 returns 1-char string", function()
    local h = geohash.encode(48.8566, 2.3522, 1)
    T.ok(type(h) == "string" and #h == 1)
  end)

  T.it("precision 5 returns 5-char string", function()
    local h = geohash.encode(48.8566, 2.3522, 5)
    T.ok(type(h) == "string" and #h == 5)
  end)

  T.it("precision 9 returns 9-char string (default)", function()
    local h = geohash.encode(48.8566, 2.3522)
    T.ok(type(h) == "string" and #h == 9)
  end)

  T.it("precision 12 returns 12-char string", function()
    local h = geohash.encode(40.7128, -74.0060, 12)
    T.ok(type(h) == "string" and #h == 12)
  end)

  T.it("north pole", function()
    local h = geohash.encode(90, 0, 5)
    T.ok(type(h) == "string" and #h == 5)
  end)

  T.it("south pole", function()
    local h = geohash.encode(-90, 0, 5)
    T.ok(type(h) == "string" and #h == 5)
  end)

  T.it("antimeridian east", function()
    local h = geohash.encode(0, 180, 5)
    T.ok(type(h) == "string" and #h == 5)
  end)

  T.it("antimeridian west", function()
    local h = geohash.encode(0, -180, 5)
    T.ok(type(h) == "string" and #h == 5)
  end)

  T.it("returns nil on invalid lat", function()
    local h, err = geohash.encode(91, 0, 5)
    T.eq(h, nil)
    T.ok(err ~= nil)
  end)

  T.it("returns nil on invalid lon", function()
    local h, err = geohash.encode(0, 181, 5)
    T.eq(h, nil)
    T.ok(err ~= nil)
  end)
end)

T.describe("geohash.decode", function()
  T.it("decode u4pruydqqvj -> approx 57.64911, 10.40744", function()
    local r = geohash.decode("u4pruydqqvj")
    T.ok(r ~= nil)
    T.ok(math.abs(r.lat - 57.64911) <= r.lat_err * 2 + 0.0001)
    T.ok(math.abs(r.lon - 10.40744) <= r.lon_err * 2 + 0.0001)
  end)

  T.it("decode returns lat_err and lon_err", function()
    local r = geohash.decode("u4pruydqqvj")
    T.ok(r.lat_err > 0)
    T.ok(r.lon_err > 0)
  end)

  T.it("returns nil on invalid char", function()
    local r, err = geohash.decode("u4pruydqqva!")
    T.eq(r, nil)
    T.ok(err ~= nil)
  end)

  T.it("returns nil on empty string", function()
    local r, err = geohash.decode("")
    T.eq(r, nil)
    T.ok(err ~= nil)
  end)

  T.it("invalid base32 char 'a' is not in alphabet", function()
    -- 'a' is not in geohash base32
    local r, err = geohash.decode("a")
    T.eq(r, nil)
    T.ok(err ~= nil)
  end)
end)

T.describe("geohash.decode_bbox", function()
  T.it("min_lat < max_lat and min_lon < max_lon", function()
    local b = geohash.decode_bbox("u4pruydqqvj")
    T.ok(b ~= nil)
    T.ok(b.min_lat < b.max_lat)
    T.ok(b.min_lon < b.max_lon)
  end)

  T.it("bounding box contains the decoded center", function()
    local r = geohash.decode("u4pruydqqvj")
    local b = geohash.decode_bbox("u4pruydqqvj")
    T.ok(r.lat >= b.min_lat and r.lat <= b.max_lat)
    T.ok(r.lon >= b.min_lon and r.lon <= b.max_lon)
  end)

  T.it("returns nil on invalid char", function()
    local b, err = geohash.decode_bbox("!")
    T.eq(b, nil)
    T.ok(err ~= nil)
  end)
end)

T.describe("round-trip encode/decode", function()
  local function check_roundtrip(lat, lon, precision)
    local h = geohash.encode(lat, lon, precision)
    T.ok(h ~= nil, "encode succeeded")
    local r = geohash.decode(h)
    T.ok(r ~= nil, "decode succeeded")
    T.ok(math.abs(r.lat - lat) <= r.lat_err + 1e-9, "lat within error for prec=" .. precision)
    T.ok(math.abs(r.lon - lon) <= r.lon_err + 1e-9, "lon within error for prec=" .. precision)
  end

  T.it("Paris, precision 1", function() check_roundtrip(48.8566, 2.3522, 1) end)
  T.it("Paris, precision 3", function() check_roundtrip(48.8566, 2.3522, 3) end)
  T.it("Paris, precision 5", function() check_roundtrip(48.8566, 2.3522, 5) end)
  T.it("Paris, precision 7", function() check_roundtrip(48.8566, 2.3522, 7) end)
  T.it("Paris, precision 9", function() check_roundtrip(48.8566, 2.3522, 9) end)
  T.it("NYC, precision 6", function() check_roundtrip(40.7128, -74.0060, 6) end)
  T.it("Sydney, precision 6", function() check_roundtrip(-33.8688, 151.2093, 6) end)
  T.it("origin (0,0), precision 5", function() check_roundtrip(0, 0, 5) end)
end)

T.describe("geohash.neighbor", function()
  T.it("neighbor north returns same-length string", function()
    local nb = geohash.neighbor("u4pruydqqvj", "n")
    T.ok(type(nb) == "string" and #nb == 11)
  end)

  T.it("neighbor south returns same-length string", function()
    local nb = geohash.neighbor("u4pruydqqvj", "s")
    T.ok(type(nb) == "string" and #nb == 11)
  end)

  T.it("neighbor east returns same-length string", function()
    local nb = geohash.neighbor("u4pruydqqvj", "e")
    T.ok(type(nb) == "string" and #nb == 11)
  end)

  T.it("neighbor west returns same-length string", function()
    local nb = geohash.neighbor("u4pruydqqvj", "w")
    T.ok(type(nb) == "string" and #nb == 11)
  end)

  T.it("neighbor ne returns same-length string", function()
    local nb = geohash.neighbor("u4pruydqqvj", "ne")
    T.ok(type(nb) == "string" and #nb == 11)
  end)

  T.it("neighbor nw returns same-length string", function()
    local nb = geohash.neighbor("u4pruydqqvj", "nw")
    T.ok(type(nb) == "string" and #nb == 11)
  end)

  T.it("neighbor se returns same-length string", function()
    local nb = geohash.neighbor("u4pruydqqvj", "se")
    T.ok(type(nb) == "string" and #nb == 11)
  end)

  T.it("neighbor sw returns same-length string", function()
    local nb = geohash.neighbor("u4pruydqqvj", "sw")
    T.ok(type(nb) == "string" and #nb == 11)
  end)

  T.it("north neighbor is different from original", function()
    local nb = geohash.neighbor("u4pruydqqvj", "n")
    T.ok(nb ~= "u4pruydqqvj")
  end)

  T.it("north neighbor is adjacent to original", function()
    local nb = geohash.neighbor("u4pruydqqvj", "n")
    T.ok(nb ~= nil)
    -- The north neighbor's center should be north of our center
    local orig = geohash.decode("u4pruydqqvj")
    local north = geohash.decode(nb)
    T.ok(north.lat > orig.lat)
  end)

  T.it("invalid direction returns nil", function()
    local nb, err = geohash.neighbor("u4pruydqqvj", "x")
    T.eq(nb, nil)
    T.ok(err ~= nil)
  end)

  T.it("precision-5 hash neighbor", function()
    local h = geohash.encode(48.8566, 2.3522, 5)
    local nb = geohash.neighbor(h, "n")
    T.ok(type(nb) == "string" and #nb == 5)
  end)
end)

T.describe("geohash.neighbors", function()
  T.it("returns table with 8 keys", function()
    local nbs = geohash.neighbors("u4pruydqqvj")
    T.ok(nbs ~= nil)
    local count = 0
    for _ in pairs(nbs) do count = count + 1 end
    T.eq(count, 8)
  end)

  T.it("has all 8 direction keys", function()
    local nbs = geohash.neighbors("u4pruydqqvj")
    T.ok(nbs.n ~= nil)
    T.ok(nbs.s ~= nil)
    T.ok(nbs.e ~= nil)
    T.ok(nbs.w ~= nil)
    T.ok(nbs.ne ~= nil)
    T.ok(nbs.nw ~= nil)
    T.ok(nbs.se ~= nil)
    T.ok(nbs.sw ~= nil)
  end)

  T.it("all neighbors have same length", function()
    local nbs = geohash.neighbors("u4pruydqqvj")
    for _, v in pairs(nbs) do
      T.ok(#v == 11)
    end
  end)

  T.it("all neighbors are different from original", function()
    local nbs = geohash.neighbors("u4pruydqqvj")
    for _, v in pairs(nbs) do
      T.ok(v ~= "u4pruydqqvj")
    end
  end)
end)

T.describe("geohash.are_neighbors", function()
  T.it("original and north neighbor are neighbors", function()
    local nb = geohash.neighbor("u4pruydqqvj", "n")
    T.ok(geohash.are_neighbors("u4pruydqqvj", nb) == true)
  end)

  T.it("original and south neighbor are neighbors", function()
    local nb = geohash.neighbor("u4pruydqqvj", "s")
    T.ok(geohash.are_neighbors("u4pruydqqvj", nb) == true)
  end)

  T.it("original and ne neighbor are neighbors", function()
    local nb = geohash.neighbor("u4pruydqqvj", "ne")
    T.ok(geohash.are_neighbors("u4pruydqqvj", nb) == true)
  end)

  T.it("distant hashes are not neighbors", function()
    -- Paris and New York at precision 5
    local paris = geohash.encode(48.8566, 2.3522, 5)
    local nyc   = geohash.encode(40.7128, -74.0060, 5)
    T.ok(geohash.are_neighbors(paris, nyc) == false)
  end)

  T.it("different lengths are not neighbors", function()
    T.ok(geohash.are_neighbors("u4pru", "u4pruydqqvj") == false)
  end)
end)

T.describe("geohash.within", function()
  T.it("returns non-empty array", function()
    local hashes = geohash.within(48.8566, 2.3522, 1, 5)
    T.ok(type(hashes) == "table" and #hashes > 0)
  end)

  T.it("includes the center hash", function()
    local center = geohash.encode(48.8566, 2.3522, 5)
    local hashes = geohash.within(48.8566, 2.3522, 1, 5)
    local found = false
    for _, h in ipairs(hashes) do
      if h == center then found = true; break end
    end
    T.ok(found)
  end)

  T.it("all hashes have correct precision", function()
    local hashes = geohash.within(48.8566, 2.3522, 5, 4)
    for _, h in ipairs(hashes) do
      T.ok(#h == 4)
    end
  end)

  T.it("larger radius returns more hashes", function()
    local small = geohash.within(48.8566, 2.3522, 1, 5)
    local large = geohash.within(48.8566, 2.3522, 50, 5)
    T.ok(#large >= #small)
  end)

  T.it("returns nil on invalid radius", function()
    local r, err = geohash.within(0, 0, -1, 5)
    T.eq(r, nil)
    T.ok(err ~= nil)
  end)
end)
