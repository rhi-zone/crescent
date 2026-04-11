-- lib/geo/geo_test.lua
if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local geo = require("lib.geo")

local PARIS    = geo.point(48.8566,  2.3522)
local LONDON   = geo.point(51.5074, -0.1278)
local NEWYORK  = geo.point(40.7128, -74.0060)
local SYDNEY   = geo.point(-33.8688, 151.2093)
local NORTHPOLE = geo.point(90, 0)
local SOUTHPOLE = geo.point(-90, 0)

-- ── Helpers ──────────────────────────────────────────────────────────────────

-- Assert two numbers are within `tol` relative tolerance.
local function approx(a, b, tol, msg)
  tol = tol or 0.01
  local diff = math.abs(a - b)
  local scale = math.max(math.abs(b), 1e-10)
  T.ok(diff / scale <= tol, (msg or "approx") .. ": " .. tostring(a) .. " vs " .. tostring(b) .. " (tol=" .. tostring(tol) .. ")")
end

-- Assert two numbers are within absolute tolerance.
local function approx_abs(a, b, tol, msg)
  T.ok(math.abs(a - b) <= tol, (msg or "approx_abs") .. ": " .. tostring(a) .. " vs " .. tostring(b) .. " (abs_tol=" .. tostring(tol) .. ")")
end

-- ── point ────────────────────────────────────────────────────────────────────

T.describe("point", function()
  T.it("stores lat and lon", function()
    T.eq(PARIS.lat, 48.8566)
    T.eq(PARIS.lon, 2.3522)
    T.eq(LONDON.lat, 51.5074)
    T.eq(LONDON.lon, -0.1278)
  end)
  T.it("handles negative coordinates", function()
    T.eq(SYDNEY.lat, -33.8688)
    T.eq(SYDNEY.lon, 151.2093)
  end)
  T.it("handles poles", function()
    T.eq(NORTHPOLE.lat, 90)
    T.eq(SOUTHPOLE.lat, -90)
  end)
end)

-- ── deg_to_rad / rad_to_deg ──────────────────────────────────────────────────

T.describe("deg_to_rad / rad_to_deg", function()
  T.it("0 degrees = 0 radians", function()
    T.eq(geo.deg_to_rad(0), 0)
    T.eq(geo.rad_to_deg(0), 0)
  end)
  T.it("180 degrees = pi radians", function()
    approx_abs(geo.deg_to_rad(180), math.pi, 1e-12, "180→pi")
    approx_abs(geo.rad_to_deg(math.pi), 180, 1e-10, "pi→180")
  end)
  T.it("45 degrees = pi/4", function()
    approx_abs(geo.deg_to_rad(45), math.pi / 4, 1e-12, "45→pi/4")
  end)
  T.it("round-trip", function()
    approx_abs(geo.rad_to_deg(geo.deg_to_rad(123.456)), 123.456, 1e-9, "round-trip")
  end)
  T.it("negative angles", function()
    approx_abs(geo.deg_to_rad(-90), -math.pi / 2, 1e-12, "-90")
  end)
end)

-- ── distance ─────────────────────────────────────────────────────────────────

T.describe("distance (Haversine)", function()
  -- Haversine with R=6371000 for coords 48.8566N,2.3522E → 51.5074N,0.1278W = ~343,556 m.
  T.it("Paris-London ~343.5 km (within 1%)", function()
    approx(geo.distance(PARIS, LONDON), 343556, 0.01, "Paris-London m")
  end)
  T.it("distance_km matches distance/1000", function()
    approx_abs(geo.distance_km(PARIS, LONDON), geo.distance(PARIS, LONDON) / 1000, 1e-9, "km")
  end)
  T.it("distance_miles matches distance*0.000621371", function()
    approx_abs(geo.distance_miles(PARIS, LONDON), geo.distance(PARIS, LONDON) * 0.000621371, 1e-9, "miles")
  end)
  T.it("distance_km ~343.5", function()
    approx(geo.distance_km(PARIS, LONDON), 343.5, 0.01, "Paris-London km")
  end)
  T.it("distance_miles ~213.4", function()
    approx(geo.distance_miles(PARIS, LONDON), 213.4, 0.02, "Paris-London miles")
  end)
  T.it("Paris-NYC ~5840 km", function()
    approx(geo.distance_km(PARIS, NEWYORK), 5840, 0.02, "Paris-NYC km")
  end)
  T.it("same point = 0", function()
    T.eq(geo.distance(PARIS, PARIS), 0)
  end)
  T.it("symmetric", function()
    approx_abs(geo.distance(PARIS, LONDON), geo.distance(LONDON, PARIS), 1e-6, "symmetric")
  end)
  T.it("pole to pole ~20000 km", function()
    approx(geo.distance_km(NORTHPOLE, SOUTHPOLE), 20015, 0.01, "pole-to-pole")
  end)
end)

-- ── vincenty_distance ─────────────────────────────────────────────────────────

T.describe("vincenty_distance", function()
  T.it("Paris-London within 1% of Haversine", function()
    local v = geo.vincenty_distance(PARIS, LONDON)
    local h = geo.distance(PARIS, LONDON)
    -- Vincenty (ellipsoidal WGS-84) and Haversine (spherical) will differ slightly.
    approx(v, h, 0.005, "vincenty vs haversine within 0.5%")
  end)
  T.it("Paris-London in range 340–345 km", function()
    local v = geo.vincenty_distance(PARIS, LONDON)
    T.ok(v > 340000 and v < 345000, "vincenty Paris-London in range: " .. tostring(v))
  end)
  T.it("same point = 0", function()
    T.eq(geo.vincenty_distance(PARIS, PARIS), 0)
  end)
  T.it("symmetric within 0.01%", function()
    approx(geo.vincenty_distance(PARIS, LONDON), geo.vincenty_distance(LONDON, PARIS), 0.001, "vincenty symmetric")
  end)
  T.it("Paris-Sydney ~16700 km", function()
    approx(geo.vincenty_distance(PARIS, SYDNEY) / 1000, 16700, 0.02, "Paris-Sydney vincenty")
  end)
end)

-- ── bearing ──────────────────────────────────────────────────────────────────

T.describe("bearing", function()
  -- Due north: from (0,0) to (10,0).
  T.it("due north = 0 degrees", function()
    approx_abs(geo.bearing(geo.point(0, 0), geo.point(10, 0)), 0, 0.001, "north")
  end)
  -- Due south: from (10,0) to (0,0).
  T.it("due south = 180 degrees", function()
    approx_abs(geo.bearing(geo.point(10, 0), geo.point(0, 0)), 180, 0.001, "south")
  end)
  -- Due east: from (0,0) to (0,10).
  T.it("due east = 90 degrees", function()
    approx_abs(geo.bearing(geo.point(0, 0), geo.point(0, 10)), 90, 0.001, "east")
  end)
  -- Due west: from (0,0) to (0,-10).
  T.it("due west = 270 degrees", function()
    approx_abs(geo.bearing(geo.point(0, 0), geo.point(0, -10)), 270, 0.001, "west")
  end)
  T.it("Paris to London: roughly north-northwest (~330°)", function()
    local b = geo.bearing(PARIS, LONDON)
    approx_abs(b, 330, 2, "Paris-London bearing")
  end)
  T.it("result in [0, 360)", function()
    local b = geo.bearing(PARIS, LONDON)
    T.ok(b >= 0 and b < 360, "bearing in [0,360)")
  end)
end)

T.describe("final_bearing", function()
  T.it("final bearing is in [0, 360)", function()
    local final = geo.final_bearing(PARIS, LONDON)
    T.ok(final >= 0 and final < 360, "final bearing in range")
  end)
  T.it("final bearing = reverse of bearing(dest → origin) + 180", function()
    -- The direction you're heading when you arrive at London = reverse of London→Paris + 180.
    local rev_plus_180 = (geo.bearing(LONDON, PARIS) + 180) % 360
    approx_abs(geo.final_bearing(PARIS, LONDON), rev_plus_180, 1, "final = rev+180")
  end)
  T.it("final bearing differs from initial bearing on curved route", function()
    -- On a great-circle route, initial and final bearings differ (geodesic curvature).
    local init  = geo.bearing(PARIS, LONDON)
    local final = geo.final_bearing(PARIS, LONDON)
    -- They should not be identical (Paris-London is a curved path).
    T.ok(math.abs(init - final) > 0.1, "initial and final bearings differ")
  end)
  T.it("same point: final bearing well-defined", function()
    -- Not an error; just check it doesn't crash.
    local final = geo.final_bearing(PARIS, PARIS)
    T.ok(final >= 0 and final < 360)
  end)
end)

-- ── destination ──────────────────────────────────────────────────────────────

T.describe("destination", function()
  T.it("move north, arrive north of start", function()
    local dest = geo.destination(PARIS, 100000, 0)  -- 100 km north
    T.ok(dest.lat > PARIS.lat, "lat increased going north")
    approx_abs(dest.lon, PARIS.lon, 0.01, "lon unchanged going north")
  end)
  T.it("move south, arrive south of start", function()
    local dest = geo.destination(PARIS, 100000, 180)
    T.ok(dest.lat < PARIS.lat, "lat decreased going south")
  end)
  T.it("move east, arrive east of start", function()
    local dest = geo.destination(PARIS, 100000, 90)
    T.ok(dest.lon > PARIS.lon, "lon increased going east")
    approx_abs(dest.lat, PARIS.lat, 0.1, "lat near-unchanged going east")
  end)
  T.it("move west, arrive west of start", function()
    local dest = geo.destination(PARIS, 100000, 270)
    T.ok(dest.lon < PARIS.lon, "lon decreased going west")
  end)
  T.it("100 km north moves lat ~0.9 degrees", function()
    local dest = geo.destination(geo.point(0, 0), 100000, 0)
    approx(dest.lat, 0.8993, 0.01, "100km north lat")
  end)
  T.it("zero distance returns same point", function()
    local dest = geo.destination(PARIS, 0, 45)
    approx_abs(dest.lat, PARIS.lat, 1e-6, "zero dist lat")
    approx_abs(dest.lon, PARIS.lon, 1e-6, "zero dist lon")
  end)
  T.it("destination-distance round-trip within 0.1%", function()
    local dist = 500000  -- 500 km
    local dest = geo.destination(PARIS, dist, 45)
    approx(geo.distance(PARIS, dest), dist, 0.001, "round-trip distance")
  end)
end)

-- ── bounding_box ─────────────────────────────────────────────────────────────

T.describe("bounding_box", function()
  local box = geo.bounding_box(PARIS, 50000)  -- 50 km radius
  T.it("min_lat < center lat", function()
    T.ok(box.min_lat < PARIS.lat)
  end)
  T.it("max_lat > center lat", function()
    T.ok(box.max_lat > PARIS.lat)
  end)
  T.it("min_lon < center lon", function()
    T.ok(box.min_lon < PARIS.lon)
  end)
  T.it("max_lon > center lon", function()
    T.ok(box.max_lon > PARIS.lon)
  end)
  T.it("lat span ~100 km (within 1%)", function()
    local span_m = (box.max_lat - box.min_lat) * math.pi / 180 * 6371000
    approx(span_m, 100000, 0.01, "lat span")
  end)
  T.it("center is inside box", function()
    T.ok(PARIS.lat >= box.min_lat and PARIS.lat <= box.max_lat)
    T.ok(PARIS.lon >= box.min_lon and PARIS.lon <= box.max_lon)
  end)
  T.it("point 40km away is inside box", function()
    local nearby = geo.destination(PARIS, 40000, 45)
    T.ok(nearby.lat >= box.min_lat and nearby.lat <= box.max_lat)
    T.ok(nearby.lon >= box.min_lon and nearby.lon <= box.max_lon)
  end)
  T.it("point 60km away is outside box", function()
    local far = geo.destination(PARIS, 60000, 0)
    T.ok(far.lat > box.max_lat)
  end)
end)

-- ── geohash ──────────────────────────────────────────────────────────────────

T.describe("geohash_encode", function()
  T.it("Paris 8-char geohash starts with 'u09t'", function()
    local h = geo.geohash_encode(PARIS.lat, PARIS.lon, 8)
    T.eq(type(h), "string")
    T.eq(#h, 8)
    T.ok(h:sub(1, 4) == "u09t", "Paris geohash prefix: " .. h)
  end)
  T.it("returns correct length for various precisions", function()
    for prec = 1, 9 do
      local h = geo.geohash_encode(PARIS.lat, PARIS.lon, prec)
      T.eq(#h, prec)
    end
  end)
  T.it("default precision is 8", function()
    T.eq(#geo.geohash_encode(PARIS.lat, PARIS.lon), 8)
  end)
  T.it("only uses valid base32 characters", function()
    local valid = "0123456789bcdefghjkmnpqrstuvwxyz"
    local h = geo.geohash_encode(PARIS.lat, PARIS.lon, 9)
    for i = 1, #h do
      local c = h:sub(i, i)
      T.ok(valid:find(c, 1, true) ~= nil, "valid char: " .. c)
    end
  end)
end)

T.describe("geohash_decode", function()
  T.it("round-trips within precision", function()
    local h = geo.geohash_encode(PARIS.lat, PARIS.lon, 8)
    local d = geo.geohash_decode(h)
    T.ok(d ~= nil, "decode returned result")
    approx_abs(d.lat, PARIS.lat, d.lat_err * 1.01, "decode lat roundtrip")
    approx_abs(d.lon, PARIS.lon, d.lon_err * 1.01, "decode lon roundtrip")
  end)
  T.it("lat_err and lon_err are positive", function()
    local d = geo.geohash_decode("u09tvw0k")
    T.ok(d.lat_err > 0)
    T.ok(d.lon_err > 0)
  end)
  T.it("higher precision → smaller error", function()
    local d5 = geo.geohash_decode(geo.geohash_encode(PARIS.lat, PARIS.lon, 5))
    local d8 = geo.geohash_decode(geo.geohash_encode(PARIS.lat, PARIS.lon, 8))
    T.ok(d8.lat_err < d5.lat_err, "prec8 lat_err < prec5")
    T.ok(d8.lon_err < d5.lon_err, "prec8 lon_err < prec5")
  end)
  T.it("returns nil on invalid character", function()
    local d, err = geo.geohash_decode("u09tvwaX")  -- 'X' is not in alphabet
    T.eq(d, nil)
    T.ok(type(err) == "string")
  end)
  T.it("London round-trip", function()
    local h = geo.geohash_encode(LONDON.lat, LONDON.lon, 8)
    local d = geo.geohash_decode(h)
    approx_abs(d.lat, LONDON.lat, d.lat_err * 1.01, "London lat")
    approx_abs(d.lon, LONDON.lon, d.lon_err * 1.01, "London lon")
  end)
end)

T.describe("geohash_neighbors", function()
  local h = geo.geohash_encode(PARIS.lat, PARIS.lon, 6)
  local nb = geo.geohash_neighbors(h)
  T.it("returns 8 directions", function()
    T.ok(nb.n  ~= nil)
    T.ok(nb.ne ~= nil)
    T.ok(nb.e  ~= nil)
    T.ok(nb.se ~= nil)
    T.ok(nb.s  ~= nil)
    T.ok(nb.sw ~= nil)
    T.ok(nb.w  ~= nil)
    T.ok(nb.nw ~= nil)
  end)
  T.it("all neighbors have same precision as original", function()
    for _, dir in ipairs({"n","ne","e","se","s","sw","w","nw"}) do
      T.eq(#nb[dir], #h)
    end
  end)
  T.it("all neighbors are distinct", function()
    local seen = {}
    for _, dir in ipairs({"n","ne","e","se","s","sw","w","nw"}) do
      T.ok(not seen[nb[dir]], "duplicate neighbor " .. dir .. ": " .. nb[dir])
      seen[nb[dir]] = true
    end
  end)
  T.it("all neighbors are distinct from origin", function()
    for _, dir in ipairs({"n","ne","e","se","s","sw","w","nw"}) do
      T.neq(nb[dir], h)
    end
  end)
  T.it("north neighbor decodes to higher latitude", function()
    local center = geo.geohash_decode(h)
    local north  = geo.geohash_decode(nb.n)
    T.ok(north.lat > center.lat, "north is north")
  end)
  T.it("south neighbor decodes to lower latitude", function()
    local center = geo.geohash_decode(h)
    local south  = geo.geohash_decode(nb.s)
    T.ok(south.lat < center.lat, "south is south")
  end)
  T.it("east neighbor decodes to higher longitude", function()
    local center = geo.geohash_decode(h)
    local east   = geo.geohash_decode(nb.e)
    T.ok(east.lon > center.lon, "east is east")
  end)
end)

T.describe("geohash_precision", function()
  T.it("returns table with 4 fields", function()
    local p = geo.geohash_precision(5)
    T.ok(p.lat_err ~= nil)
    T.ok(p.lon_err ~= nil)
    T.ok(p.km_width ~= nil)
    T.ok(p.km_height ~= nil)
  end)
  T.it("precision 1: 5 bits total (3 lon, 2 lat) → lat_err=22.5, lon_err=22.5", function()
    -- prec=1: 5 bits. lon gets ceil(5/2)=3 bits → err=180/2^3=22.5
    --                  lat gets floor(5/2)=2 bits → err=90/2^2=22.5
    local p = geo.geohash_precision(1)
    approx(p.lat_err, 22.5, 0.01, "prec1 lat_err")
    approx(p.lon_err, 22.5, 0.01, "prec1 lon_err")
  end)
  T.it("higher precision → smaller errors", function()
    local p4 = geo.geohash_precision(4)
    local p8 = geo.geohash_precision(8)
    T.ok(p8.lat_err < p4.lat_err)
    T.ok(p8.lon_err < p4.lon_err)
  end)
  T.it("km_width and km_height are positive", function()
    local p = geo.geohash_precision(6)
    T.ok(p.km_width > 0)
    T.ok(p.km_height > 0)
  end)
end)

-- ── GeoJSON ──────────────────────────────────────────────────────────────────

T.describe("to_geojson_point", function()
  T.it("type is 'Point'", function()
    T.eq(geo.to_geojson_point(PARIS).type, "Point")
  end)
  T.it("coordinates are [lon, lat] (GeoJSON order)", function()
    local gj = geo.to_geojson_point(PARIS)
    T.eq(gj.coordinates[1], PARIS.lon)  -- lon first
    T.eq(gj.coordinates[2], PARIS.lat)  -- lat second
  end)
  T.it("negative coordinates preserved", function()
    local gj = geo.to_geojson_point(NEWYORK)
    T.eq(gj.coordinates[1], NEWYORK.lon)  -- -74.0060
    T.eq(gj.coordinates[2], NEWYORK.lat)  -- 40.7128
  end)
end)

T.describe("from_geojson_point", function()
  T.it("round-trips through to_geojson_point", function()
    local gj = geo.to_geojson_point(PARIS)
    local pt = geo.from_geojson_point(gj)
    T.eq(pt.lat, PARIS.lat)
    T.eq(pt.lon, PARIS.lon)
  end)
  T.it("parses {type=Point, coordinates={lon,lat}}", function()
    local pt = geo.from_geojson_point({ type = "Point", coordinates = { 2.3522, 48.8566 } })
    T.eq(pt.lat, 48.8566)
    T.eq(pt.lon, 2.3522)
  end)
  T.it("returns nil on wrong type", function()
    local pt, err = geo.from_geojson_point({ type = "LineString", coordinates = {} })
    T.eq(pt, nil)
    T.ok(type(err) == "string")
  end)
  T.it("returns nil on missing coordinates", function()
    local pt, err = geo.from_geojson_point({ type = "Point", coordinates = {1} })
    T.eq(pt, nil)
    T.ok(type(err) == "string")
  end)
end)

-- ── point_in_polygon ─────────────────────────────────────────────────────────

T.describe("point_in_polygon", function()
  -- 10°×10° square at origin.
  local square = {
    geo.point(0, 0), geo.point(0, 10), geo.point(10, 10), geo.point(10, 0)
  }
  T.it("center point is inside", function()
    T.ok(geo.point_in_polygon(geo.point(5, 5), square))
  end)
  T.it("far point is outside", function()
    T.ok(not geo.point_in_polygon(geo.point(15, 5), square))
  end)
  T.it("point below square is outside", function()
    T.ok(not geo.point_in_polygon(geo.point(-1, 5), square))
  end)
  T.it("point left of square is outside", function()
    T.ok(not geo.point_in_polygon(geo.point(5, -1), square))
  end)
  T.it("corner-adjacent is outside", function()
    T.ok(not geo.point_in_polygon(geo.point(11, 11), square))
  end)
  T.it("near-center still inside", function()
    T.ok(geo.point_in_polygon(geo.point(1, 1), square))
    T.ok(geo.point_in_polygon(geo.point(9, 9), square))
  end)
  -- Triangle: vertices at (lat=0,lon=0), (lat=10,lon=5), (lat=0,lon=10).
  -- This is a triangle with base along lat=0 from lon=0 to lon=10, apex at lat=10,lon=5.
  local triangle = {
    geo.point(0, 0), geo.point(10, 5), geo.point(0, 10)
  }
  T.it("center of triangle is inside", function()
    -- centroid is at (lat=20/3≈3.3, lon=5)
    T.ok(geo.point_in_polygon(geo.point(3, 5), triangle))
  end)
  T.it("point outside triangle (above apex)", function()
    -- lat=12 is above the apex at lat=10, so outside
    T.ok(not geo.point_in_polygon(geo.point(12, 5), triangle))
  end)
  T.it("point inside triangle near apex", function()
    -- (8,5) is inside (close to apex, within the sides)
    T.ok(geo.point_in_polygon(geo.point(8, 5), triangle))
  end)
  T.it("point outside triangle (below base)", function()
    -- lat=-1 is below the base at lat=0
    T.ok(not geo.point_in_polygon(geo.point(-1, 5), triangle))
  end)
end)

-- ── polygon_area ─────────────────────────────────────────────────────────────

T.describe("polygon_area", function()
  -- 1° × 1° square at equator ≈ 111km × 111km ≈ 12,321 km².
  local one_deg_sq = {
    geo.point(0, 0), geo.point(1, 0), geo.point(1, 1), geo.point(0, 1)
  }
  T.it("1°×1° square at equator ~12,300 km²", function()
    local area_m2 = geo.polygon_area(one_deg_sq)
    local area_km2 = area_m2 / 1e6
    approx(area_km2, 12321, 0.02, "1deg sq area km2")
  end)
  T.it("area is positive", function()
    T.ok(geo.polygon_area(one_deg_sq) > 0)
  end)
  T.it("degenerate (< 3 points) returns 0", function()
    T.eq(geo.polygon_area({}), 0)
    T.eq(geo.polygon_area({ geo.point(0,0), geo.point(1,1) }), 0)
  end)
  T.it("larger polygon has larger area", function()
    local big = {
      geo.point(0, 0), geo.point(2, 0), geo.point(2, 2), geo.point(0, 2)
    }
    T.ok(geo.polygon_area(big) > geo.polygon_area(one_deg_sq))
  end)
end)

-- ── meters_to_degrees ────────────────────────────────────────────────────────

T.describe("meters_to_degrees", function()
  T.it("~111 km per degree latitude at equator", function()
    local lat_deg = geo.meters_to_degrees(111000, 0)
    approx(lat_deg, 1.0, 0.01, "111km → ~1 degree lat")
  end)
  T.it("lon degrees compressed at higher latitude", function()
    local _, lon45 = geo.meters_to_degrees(111000, 45)
    local _, lon0  = geo.meters_to_degrees(111000, 0)
    T.ok(lon45 > lon0, "lon degree larger at lat=45 for same distance")
  end)
end)

