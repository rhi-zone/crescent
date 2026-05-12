-- lib/geo_hash/init.lua
-- Geohash encoding, decoding, neighbors, and spatial queries.
--
-- Public API:
--   M.encode(lat, lng, precision)               → hash string
--   M.decode(hash)                              → {lat={min,max,center}, lng={min,max,center}}
--   M.decode_center(hash)                       → lat, lng
--   M.neighbors(hash)                           → {n,ne,e,se,s,sw,w,nw}
--   M.neighbor(hash, dir)                       → hash string
--   M.bboxes(min_lat, min_lng, max_lat, max_lng, precision) → array of hashes
--   M.distance(hash1, hash2)                    → km (haversine between centers)
--   M.haversine(lat1, lng1, lat2, lng2)         → km
--   M.within_radius(hash, center_lat, center_lng, radius_km) → bool
--   M.precision_info(precision)                 → {width_km, height_km}
--   M.is_valid(hash)                            → bool
--   M.parent(hash)                              → hash string (precision - 1)
--   M.common_prefix(hash1, hash2)               → string
--   M._tier                                     = "pure"

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ── Constants ─────────────────────────────────────────────────────────────────

local EARTH_R     = 6371.0          -- mean radius in km
local PI          = math.pi
local DEG_TO_RAD  = PI / 180

-- Standard geohash base32 alphabet (no a/i/l/o).
local ALPHA = "0123456789bcdefghjkmnpqrstuvwxyz"

-- Decode table: char → 0-based 5-bit value.
local DECODE = {}
for i = 1, #ALPHA do
  DECODE[ALPHA:sub(i, i)] = i - 1
end

-- Valid character set for is_valid.
local VALID_CHARS = {}
for i = 1, #ALPHA do
  VALID_CHARS[ALPHA:sub(i, i)] = true
end

-- ── Precision table ──────────────────────────────────────────────────────────
-- Total bits = 5 * prec.  Even-position bits (0-indexed) = longitude;
-- odd-position bits = latitude.
-- lon_bits = ceil(5*prec/2), lat_bits = floor(5*prec/2).
--:: PrecInfo = { width_km: number, height_km: number, lat_err: number, lon_err: number }
local PRECISION_INFO = {} --: { [integer]: PrecInfo }
for prec = 1, 12 do
  local total     = 5 * prec
  local lon_bits  = math.ceil(total / 2)
  local lat_bits  = math.floor(total / 2)
  local lat_err   = 90  / (2 ^ lat_bits)
  local lon_err   = 180 / (2 ^ lon_bits)
  PRECISION_INFO[prec] = {
    width_km  = lon_err * 2 * EARTH_R * DEG_TO_RAD,
    height_km = lat_err * 2 * EARTH_R * DEG_TO_RAD,
    lat_err   = lat_err,
    lon_err   = lon_err,
  }
end

-- ── Encode / Decode ──────────────────────────────────────────────────────────

-- Returns hash, min_lat, max_lat, min_lng, max_lng.
--: (number, number, integer) -> (string, number, number, number, number)
local function encode_full(lat, lng, precision)
  local min_lat = -90.0  --: number
  local max_lat =  90.0  --: number
  local min_lng = -180.0 --: number
  local max_lng =  180.0 --: number
  local result   = {}
  local hash_val = 0
  local bits     = 0
  local is_lng   = true  -- geohash starts with longitude bit

  while #result < precision do
    if is_lng then
      local mid = (min_lng + max_lng) * 0.5
      if lng >= mid then
        hash_val = hash_val * 2 + 1
        min_lng  = mid
      else
        hash_val = hash_val * 2
        max_lng  = mid
      end
    else
      local mid = (min_lat + max_lat) * 0.5
      if lat >= mid then
        hash_val = hash_val * 2 + 1
        min_lat  = mid
      else
        hash_val = hash_val * 2
        max_lat  = mid
      end
    end
    is_lng = not is_lng
    bits   = bits + 1
    if bits == 5 then
      result[#result + 1] = ALPHA:sub(hash_val + 1, hash_val + 1)
      hash_val = 0
      bits     = 0
    end
  end

  return table.concat(result), min_lat, max_lat, min_lng, max_lng
end

-- Returns min_lat, max_lat, min_lng, max_lng for a given hash.
--: (string) -> (number | nil, number | nil, number | nil, number | nil, string | nil)
local function decode_bounds(hash)
  local min_lat = -90.0  --: number
  local max_lat =  90.0  --: number
  local min_lng = -180.0 --: number
  local max_lng =  180.0 --: number
  local is_lng = true

  for i = 1, #hash do
    local ch = hash:sub(i, i)
    local val = DECODE[ch]
    if not val then
      return nil, nil, nil, nil, "invalid geohash character: " .. ch
    end
    for bit = 4, 0, -1 do
      local b = math.floor(val / (2 ^ bit)) % 2
      if is_lng then
        local mid = (min_lng + max_lng) * 0.5
        if b == 1 then min_lng = mid else max_lng = mid end
      else
        local mid = (min_lat + max_lat) * 0.5
        if b == 1 then min_lat = mid else max_lat = mid end
      end
      is_lng = not is_lng
    end
  end

  return min_lat, max_lat, min_lng, max_lng, nil
end

M.encode = function(lat, lng, precision)
  precision = precision or 9
  if type(lat) ~= "number" or type(lng) ~= "number" then
    return nil, "lat and lng must be numbers"
  end
  if precision < 1 or precision > 12 then
    return nil, "precision must be between 1 and 12"
  end
  local hash = encode_full(lat, lng, precision)
  return hash
end

--: (string) -> ({ lat: { min: number, max: number, center: number }, lng: { min: number, max: number, center: number } } | nil, string | nil)
M.decode = function(hash)
  if type(hash) ~= "string" or #hash == 0 then
    return nil, "hash must be a non-empty string"
  end
  local min_lat, max_lat, min_lng, max_lng, err = decode_bounds(hash)
  if err then return nil, err end
  if not min_lat or not max_lat or not min_lng or not max_lng then return nil, "decode_bounds returned nil" end
  return {
    lat = {
      min    = min_lat,
      max    = max_lat,
      center = (min_lat + max_lat) * 0.5,
    },
    lng = {
      min    = min_lng,
      max    = max_lng,
      center = (min_lng + max_lng) * 0.5,
    },
  }
end

--: (string) -> (number | nil, number | nil, string | nil)
M.decode_center = function(hash)
  local bounds, err = M.decode(hash)
  if not bounds then return nil, nil, err end
  return bounds.lat.center, bounds.lng.center, nil
end

-- ── Neighbors ────────────────────────────────────────────────────────────────

local DIR_DLAT = { n = 1,  s = -1, e = 0,  w = 0,  ne = 1,  nw = 1,  se = -1, sw = -1 }
local DIR_DLNG = { n = 0,  s = 0,  e = 1,  w = -1, ne = 1,  nw = -1, se = 1,  sw = -1 }

M.neighbor = function(hash, dir)
  if type(hash) ~= "string" or #hash == 0 then
    return nil, "hash must be a non-empty string"
  end
  local dlat_dir = DIR_DLAT[dir]
  local dlng_dir = DIR_DLNG[dir]
  if dlat_dir == nil then
    return nil, "invalid direction: " .. tostring(dir)
  end

  local min_lat, max_lat, min_lng, max_lng, err = decode_bounds(hash)
  if err then return nil, err end
  if not min_lat or not max_lat or not min_lng or not max_lng then return nil, "decode_bounds returned nil" end
  local ndlat_dir = dlat_dir --[[:! number]]
  local ndlng_dir = dlng_dir --[[:! number]]

  local prec    = #hash
  local lat_err = (max_lat - min_lat) * 0.5
  local lng_err = (max_lng - min_lng) * 0.5
  local clat    = (min_lat + max_lat) * 0.5
  local clng    = (min_lng + max_lng) * 0.5

  local nlat = clat + ndlat_dir * lat_err * 2
  local nlng = clng + ndlng_dir * lng_err * 2

  -- Clamp latitude; wrap longitude.
  if nlat >  90 then nlat =  90 end
  if nlat < -90 then nlat = -90 end
  nlng = ((nlng + 180) % 360) - 180

  return (encode_full(nlat, nlng, prec))
end

M.neighbors = function(hash)
  local n  = M.neighbor(hash, "n")
  local s  = M.neighbor(hash, "s")
  local e  = M.neighbor(hash, "e")
  local w  = M.neighbor(hash, "w")
  -- Derive diagonals from cardinal neighbors to avoid double-decode.
  local ne = M.neighbor(n, "e")
  local nw = M.neighbor(n, "w")
  local se = M.neighbor(s, "e")
  local sw = M.neighbor(s, "w")
  return { n = n, ne = ne, e = e, se = se, s = s, sw = sw, w = w, nw = nw }
end

-- ── Bounding-box coverage ────────────────────────────────────────────────────

--: (number, number, number, number, integer | nil) -> string[]
M.bboxes = function(min_lat, min_lng, max_lat, max_lng, precision)
  precision = precision or 6
  local info    = PRECISION_INFO[precision]
  if not info then return {} end
  local lat_err = info.lat_err
  local lng_err = info.lon_err

  -- Find SW corner hash and step through the grid.
  local result = {}
  local seen   = {}

  -- Clamp inputs.
  if min_lat < -90  then min_lat = -90  end
  if max_lat >  90  then max_lat =  90  end
  if min_lng < -180 then min_lng = -180 end
  if max_lng >  180 then max_lng =  180 end

  -- Start slightly inside so the first cell hash is unambiguous.
  local lat = min_lat + lat_err * 0.5
  while lat <= max_lat + lat_err do
    if lat > 90 then lat = 90 end
    local lng = min_lng + lng_err * 0.5
    while lng <= max_lng + lng_err do
      if lng > 180 then lng = 180 end
      local h = encode_full(lat, lng, precision)
      if not seen[h] then
        seen[h]           = true
        result[#result + 1] = h
      end
      if lng >= max_lng then break end
      lng = lng + lng_err * 2
    end
    if lat >= max_lat then break end
    lat = lat + lat_err * 2
  end

  return result
end

-- ── Distance / Haversine ─────────────────────────────────────────────────────

M.haversine = function(lat1, lng1, lat2, lng2)
  local dlat     = (lat2 - lat1) * DEG_TO_RAD
  local dlng     = (lng2 - lng1) * DEG_TO_RAD
  local sin_dlat = math.sin(dlat * 0.5)
  local sin_dlng = math.sin(dlng * 0.5)
  local a = sin_dlat * sin_dlat
      + math.cos(lat1 * DEG_TO_RAD) * math.cos(lat2 * DEG_TO_RAD) * sin_dlng * sin_dlng
  return EARTH_R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
end

M.distance = function(hash1, hash2)
  local lat1, lng1, err = M.decode_center(hash1)
  if not lat1 or not lng1 then return nil, err end
  local lat2, lng2
  lat2, lng2, err = M.decode_center(hash2)
  if not lat2 or not lng2 then return nil, err end
  return M.haversine(lat1, lng1, lat2, lng2)
end

-- ── Radius query ─────────────────────────────────────────────────────────────

M.within_radius = function(hash, center_lat, center_lng, radius_km)
  local lat, lng, err = M.decode_center(hash)
  if not lat or not lng then return nil, err end
  return M.haversine(lat, lng, center_lat, center_lng) <= radius_km
end

-- ── Precision info ───────────────────────────────────────────────────────────

M.precision_info = function(precision)
  local info = PRECISION_INFO[precision]
  if not info then return nil, "precision must be between 1 and 12" end
  return { width_km = info.width_km, height_km = info.height_km }
end

-- ── Validation ───────────────────────────────────────────────────────────────

M.is_valid = function(hash)
  if type(hash) ~= "string" or #hash == 0 then return false end
  for i = 1, #hash do
    if not VALID_CHARS[hash:sub(i, i)] then return false end
  end
  return true
end

-- ── Parent / Prefix ──────────────────────────────────────────────────────────

M.parent = function(hash)
  if type(hash) ~= "string" or #hash < 2 then
    return nil, "hash must be a string of length >= 2"
  end
  return hash:sub(1, #hash - 1)
end

M.common_prefix = function(hash1, hash2)
  local len = math.min(#hash1, #hash2)
  local i   = 1
  while i <= len and hash1:sub(i, i) == hash2:sub(i, i) do
    i = i + 1
  end
  return hash1:sub(1, i - 1)
end

return M
