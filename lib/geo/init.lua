-- lib/geo/init.lua
-- Geospatial calculations on Earth's surface.
--
-- Public API:
--   M.point(lat, lon)                       → {lat, lon}
--   M.distance(a, b)                        → meters (Haversine)
--   M.distance_km(a, b)                     → km
--   M.distance_miles(a, b)                  → miles
--   M.vincenty_distance(a, b)               → meters (higher precision)
--   M.bearing(a, b)                         → degrees (initial bearing, 0=N)
--   M.final_bearing(a, b)                   → degrees (bearing at destination)
--   M.destination(origin, dist_m, bearing)  → point
--   M.bounding_box(center, radius_m)        → {min_lat, max_lat, min_lon, max_lon}
--   M.geohash_encode(lat, lon, precision)   → string
--   M.geohash_decode(hash)                  → {lat, lon, lat_err, lon_err}
--   M.geohash_neighbors(hash)               → {n, ne, e, se, s, sw, w, nw}
--   M.geohash_precision(prec)               → {lat_err, lon_err, km_width, km_height}
--   M.to_geojson_point(pt)                  → {type, coordinates}
--   M.from_geojson_point(obj)               → point
--   M.point_in_polygon(pt, poly)            → bool
--   M.polygon_area(poly)                    → approximate m²
--   M.deg_to_rad(deg)                       → radians
--   M.rad_to_deg(rad)                       → degrees
--   M.meters_to_degrees(meters, lat)        → approximate degrees
--   M._tier                                 = "pure"

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

--:: Point = { lat: number, lon: number }

-- ── Constants ─────────────────────────────────────────────────────────────────

local EARTH_R     = 6371000       -- mean radius in meters
local PI          = math.pi
local TWO_PI      = 2 * PI
local DEG_TO_RAD  = PI / 180
local RAD_TO_DEG  = 180 / PI
local MILES_PER_M = 0.000621371

-- ── Conversion helpers ────────────────────────────────────────────────────────

M.deg_to_rad = function(deg)
  return deg * DEG_TO_RAD
end

M.rad_to_deg = function(rad)
  return rad * RAD_TO_DEG
end

-- Approximate degrees from meters at a given latitude.
-- Longitude degrees account for the cosine compression at the given latitude.
M.meters_to_degrees = function(meters, lat)
  local lat_deg = meters / EARTH_R * RAD_TO_DEG
  local lon_deg = meters / (EARTH_R * math.cos(lat * DEG_TO_RAD)) * RAD_TO_DEG
  return lat_deg, lon_deg
end

-- ── Point ─────────────────────────────────────────────────────────────────────

M.point = function(lat, lon)
  return { lat = lat, lon = lon }
end

-- ── Distance ─────────────────────────────────────────────────────────────────

-- Haversine formula — great-circle distance.
--: (Point, Point) -> number
M.distance = function(a, b)
  local lat1 = a.lat * DEG_TO_RAD
  local lat2 = b.lat * DEG_TO_RAD
  local dlat = (b.lat - a.lat) * DEG_TO_RAD
  local dlon = (b.lon - a.lon) * DEG_TO_RAD
  local sin_dlat = math.sin(dlat * 0.5)
  local sin_dlon = math.sin(dlon * 0.5)
  local hav = sin_dlat * sin_dlat + math.cos(lat1) * math.cos(lat2) * sin_dlon * sin_dlon
  return EARTH_R * 2 * math.atan2(math.sqrt(hav), math.sqrt(1 - hav))
end

M.distance_km = function(a, b)
  return M.distance(a, b) / 1000
end

M.distance_miles = function(a, b)
  return M.distance(a, b) * MILES_PER_M
end

-- Vincenty formula (oblate spheroid).
-- WGS-84 ellipsoid parameters.
local VINCENTY_A = 6378137.0          -- semi-major axis (m)
local VINCENTY_B = 6356752.314245     -- semi-minor axis (m)
local VINCENTY_F = 1 / 298.257223563 -- flattening

--: (Point, Point) -> number
M.vincenty_distance = function(a, b)
  local lat1 = a.lat * DEG_TO_RAD
  local lat2 = b.lat * DEG_TO_RAD
  local lon1 = a.lon * DEG_TO_RAD
  local lon2 = b.lon * DEG_TO_RAD

  -- Check for coincident points.
  if lat1 == lat2 and lon1 == lon2 then return 0 end

  local U1 = math.atan2((1 - VINCENTY_F) * math.tan(lat1), 1)
  local U2 = math.atan2((1 - VINCENTY_F) * math.tan(lat2), 1)
  local L  = lon2 - lon1

  local sinU1 = math.sin(U1); local cosU1 = math.cos(U1)
  local sinU2 = math.sin(U2); local cosU2 = math.cos(U2)

  local lam = L
  local sin_lam, cos_lam
  local sin_sig, cos_sig, sigma, sin_alph, cos2_alph, cos_2sigm
  local C

  for _ = 1, 200 do
    sin_lam = math.sin(lam)
    cos_lam = math.cos(lam)
    local t1 = cosU2 * sin_lam
    local t2 = cosU1 * sinU2 - sinU1 * cosU2 * cos_lam
    sin_sig = math.sqrt(t1 * t1 + t2 * t2)
    if sin_sig == 0 then return 0 end  -- coincident
    cos_sig  = sinU1 * sinU2 + cosU1 * cosU2 * cos_lam
    sigma    = math.atan2(sin_sig, cos_sig)
    sin_alph = cosU1 * cosU2 * sin_lam / sin_sig
    cos2_alph = 1 - sin_alph * sin_alph
    if cos2_alph == 0 then
      cos_2sigm = 0
    else
      cos_2sigm = cos_sig - 2 * sinU1 * sinU2 / cos2_alph
    end
    C = VINCENTY_F / 16 * cos2_alph * (4 + VINCENTY_F * (4 - 3 * cos2_alph))
    local lam_prev = lam
    lam = L + (1 - C) * VINCENTY_F * sin_alph * (sigma + C * sin_sig * (cos_2sigm + C * cos_sig * (-1 + 2 * cos_2sigm * cos_2sigm)))
    if math.abs(lam - lam_prev) < 1e-12 then break end
  end

  local u2   = cos2_alph * (VINCENTY_A * VINCENTY_A - VINCENTY_B * VINCENTY_B) / (VINCENTY_B * VINCENTY_B)
  local A_v  = 1 + u2 / 16384 * (4096 + u2 * (-768 + u2 * (320 - 175 * u2)))
  local B_v  = u2 / 1024 * (256 + u2 * (-128 + u2 * (74 - 47 * u2)))
  local d_sig = B_v * sin_sig * (cos_2sigm + B_v / 4 * (cos_sig * (-1 + 2 * cos_2sigm * cos_2sigm)
    - B_v / 6 * cos_2sigm * (-3 + 4 * sin_sig * sin_sig) * (-3 + 4 * cos_2sigm * cos_2sigm)))

  return VINCENTY_B * A_v * (sigma - d_sig)
end

-- ── Bearing ──────────────────────────────────────────────────────────────────

local function normalize_bearing(b)
  return (b * RAD_TO_DEG + 360) % 360
end

--: (Point, Point) -> number
M.bearing = function(a, b)
  local lat1 = a.lat * DEG_TO_RAD
  local lat2 = b.lat * DEG_TO_RAD
  local dlon = (b.lon - a.lon) * DEG_TO_RAD
  local y = math.sin(dlon) * math.cos(lat2)
  local x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dlon)
  return normalize_bearing(math.atan2(y, x))
end

M.final_bearing = function(a, b)
  -- Final bearing: direction of travel when arriving at b (reverse of b→a, rotated 180°).
  return (M.bearing(b, a) + 180) % 360
end

-- ── Destination ──────────────────────────────────────────────────────────────

--: (Point, number, number) -> Point
M.destination = function(origin, dist_m, bearing_deg)
  local lat1  = origin.lat * DEG_TO_RAD
  local lon1  = origin.lon * DEG_TO_RAD
  local bear  = bearing_deg * DEG_TO_RAD
  local ang   = dist_m / EARTH_R
  local lat2  = math.asin(math.sin(lat1) * math.cos(ang) + math.cos(lat1) * math.sin(ang) * math.cos(bear))
  local lon2  = lon1 + math.atan2(math.sin(bear) * math.sin(ang) * math.cos(lat1), math.cos(ang) - math.sin(lat1) * math.sin(lat2))
  -- Normalize longitude to [-180, 180].
  lon2 = (lon2 + 3 * PI) % TWO_PI - PI
  return M.point(lat2 * RAD_TO_DEG, lon2 * RAD_TO_DEG)
end

-- ── Bounding box ─────────────────────────────────────────────────────────────

M.bounding_box = function(center, radius_m)
  local dlat = radius_m / EARTH_R * RAD_TO_DEG
  local dlon = radius_m / (EARTH_R * math.cos(center.lat * DEG_TO_RAD)) * RAD_TO_DEG
  return {
    min_lat = center.lat - dlat,
    max_lat = center.lat + dlat,
    min_lon = center.lon - dlon,
    max_lon = center.lon + dlon,
  }
end

-- ── Geohash ──────────────────────────────────────────────────────────────────

-- Standard geohash base32 alphabet (0-9, b-z minus a/i/l/o).
local GEOHASH_ALPHA = "0123456789bcdefghjkmnpqrstuvwxyz"

-- Encode: table for fast char lookup by index (1-based for Lua).
local function geohash_encode_inner(lat, lon, precision)
  local min_lat = -90.0 --: number
  local max_lat = 90.0 --: number
  local min_lon = -180.0 --: number
  local max_lon = 180.0 --: number
  local result = {}
  local bits   = 0
  local bits_total = 0
  local hash_val  = 0
  local is_lon = true  -- geohash starts with longitude bit

  while #result < precision do
    if is_lon then
      local mid = (min_lon + max_lon) * 0.5
      if lon >= mid then
        hash_val = hash_val * 2 + 1
        min_lon = mid
      else
        hash_val = hash_val * 2
        max_lon = mid
      end
    else
      local mid = (min_lat + max_lat) * 0.5
      if lat >= mid then
        hash_val = hash_val * 2 + 1
        min_lat = mid
      else
        hash_val = hash_val * 2
        max_lat = mid
      end
    end
    is_lon = not is_lon
    bits_total = bits_total + 1
    bits = bits + 1
    if bits == 5 then
      result[#result + 1] = GEOHASH_ALPHA:sub(hash_val + 1, hash_val + 1)
      hash_val = 0
      bits = 0
    end
  end

  return table.concat(result), min_lat, max_lat, min_lon, max_lon
end

M.geohash_encode = function(lat, lon, precision)
  precision = precision or 8
  local hash = geohash_encode_inner(lat, lon, precision)
  return hash
end

-- Build decode table: char → 0-based 5-bit value.
local GEOHASH_DECODE = {}
for i = 1, #GEOHASH_ALPHA do
  GEOHASH_DECODE[GEOHASH_ALPHA:sub(i, i)] = i - 1
end

--: (string) -> ({ lat: number, lon: number, lat_err: number, lon_err: number } | nil, string | nil)
M.geohash_decode = function(hash)
  local min_lat = -90.0 --: number
  local max_lat = 90.0 --: number
  local min_lon = -180.0 --: number
  local max_lon = 180.0 --: number
  local is_lon = true

  for i = 1, #hash do
    local c = hash:sub(i, i)
    local val = GEOHASH_DECODE[c]
    if not val then
      return nil, "invalid geohash character: " .. c
    end
    -- Process 5 bits from MSB to LSB.
    for bit = 4, 0, -1 do
      local b = math.floor(val / (2 ^ bit)) % 2
      if is_lon then
        local mid = (min_lon + max_lon) * 0.5
        if b == 1 then min_lon = mid else max_lon = mid end
      else
        local mid = (min_lat + max_lat) * 0.5
        if b == 1 then min_lat = mid else max_lat = mid end
      end
      is_lon = not is_lon
    end
  end

  return {
    lat     = (min_lat + max_lat) * 0.5,
    lon     = (min_lon + max_lon) * 0.5,
    lat_err = (max_lat - min_lat) * 0.5,
    lon_err = (max_lon - min_lon) * 0.5,
  }
end

-- Geohash neighbor computation by decode-offset-reencode.
-- This approach avoids error-prone lookup tables: decode the hash to its bounding box,
-- shift the center by one cell in the given direction, then re-encode at the same precision.
-- Handles wraparound (antimeridian, poles) naturally.

--: { [string]: integer }
local DIR_LAT = { n = 1, s = -1, e = 0, w = 0,  ne = 1, nw = 1,  se = -1, sw = -1 }
--: { [string]: integer }
local DIR_LON = { n = 0, s = 0,  e = 1, w = -1, ne = 1, nw = -1, se = 1,  sw = -1 }

--: (string, string) -> string | nil
local function geohash_adjacent(hash, dir)
  local d = M.geohash_decode(hash)
  if not d then return nil end
  local prec  = #hash
  local dlat  = d.lat_err * 2 * DIR_LAT[dir]
  local dlon  = d.lon_err * 2 * DIR_LON[dir]
  local nlat  = d.lat + dlat
  local nlon  = d.lon + dlon
  -- Clamp latitude to [-90, 90]; wrap longitude.
  if nlat > 90  then nlat = 90  end
  if nlat < -90 then nlat = -90 end
  nlon = ((nlon + 180) % 360) - 180
  return M.geohash_encode(nlat, nlon, prec)
end

M.geohash_neighbors = function(hash)
  local n  = geohash_adjacent(hash, "n")
  local s  = geohash_adjacent(hash, "s")
  local e  = geohash_adjacent(hash, "e")
  local w  = geohash_adjacent(hash, "w")
  local ne = n and geohash_adjacent(n, "e") or nil
  local nw = n and geohash_adjacent(n, "w") or nil
  local se = s and geohash_adjacent(s, "e") or nil
  local sw = s and geohash_adjacent(s, "w") or nil
  return { n = n, ne = ne, e = e, se = se, s = s, sw = sw, w = w, nw = nw }
end

-- Error (half-width) per precision level in lat/lon degrees.
-- 5 bits per char, alternating lon/lat; even chars give lon, odd give lat.
M.geohash_precision = function(prec)
  -- Total bits: 5*prec. lon bits = ceil(5*prec/2), lat bits = floor(5*prec/2).
  local total   = 5 * prec
  local lon_bits = math.ceil(total / 2)
  local lat_bits = math.floor(total / 2)
  local lat_err  = 90  / (2 ^ lat_bits)
  local lon_err  = 180 / (2 ^ lon_bits)
  -- km dimensions at equator (approximate).
  local km_width  = lon_err * 2 * EARTH_R * DEG_TO_RAD / 1000
  local km_height = lat_err * 2 * EARTH_R * DEG_TO_RAD / 1000
  return {
    lat_err   = lat_err,
    lon_err   = lon_err,
    km_width  = km_width,
    km_height = km_height,
  }
end

-- ── GeoJSON helpers ──────────────────────────────────────────────────────────

-- GeoJSON uses [lon, lat] order (opposite of our point convention).
M.to_geojson_point = function(pt)
  return { type = "Point", coordinates = { pt.lon, pt.lat } }
end

--: (obj: { type: string, coordinates: number[] }) -> (Point | nil, string | nil)
M.from_geojson_point = function(obj)
  if obj.type ~= "Point" then
    return nil, "expected type 'Point', got '" .. tostring(obj.type) .. "'"
  end
  local coords = obj.coordinates
  if not coords or #coords < 2 then
    return nil, "coordinates must have at least 2 elements"
  end
  -- GeoJSON: [lon, lat]
  return M.point(coords[2], coords[1])
end

-- ── Polygon ──────────────────────────────────────────────────────────────────

-- Ray-casting point-in-polygon test.
-- poly is an array of {lat, lon} points (no need to close the polygon).
--: (Point, Point[]) -> boolean
M.point_in_polygon = function(pt, poly)
  local n = #poly
  local inside = false
  local px, py = pt.lon, pt.lat
  local j = n
  for i = 1, n do
    local xi, yi = poly[i].lon, poly[i].lat
    local xj, yj = poly[j].lon, poly[j].lat
    if ((yi > py) ~= (yj > py)) and (px < (xj - xi) * (py - yi) / (yj - yi) + xi) then
      inside = not inside
    end
    j = i
  end
  return inside
end

-- Shoelace formula for polygon area in m² (flat-earth approximation).
-- Suitable for small polygons (< a few hundred km).
M.polygon_area = function(poly)
  local n = #poly
  if n < 3 then return 0 end
  -- Convert to approximate meters using equirectangular projection.
  local clat = 0
  for i = 1, n do clat = clat + poly[i].lat end
  clat = clat / n  -- centroid latitude for cosine correction

  local cos_lat = math.cos(clat * DEG_TO_RAD)
  local area = 0
  local j = n
  for i = 1, n do
    -- x = lon in meters, y = lat in meters
    local xi = poly[i].lon * DEG_TO_RAD * EARTH_R * cos_lat
    local yi = poly[i].lat * DEG_TO_RAD * EARTH_R
    local xj = poly[j].lon * DEG_TO_RAD * EARTH_R * cos_lat
    local yj = poly[j].lat * DEG_TO_RAD * EARTH_R
    area = area + (xj + xi) * (yj - yi)
    j = i
  end
  return math.abs(area) * 0.5
end

return M
