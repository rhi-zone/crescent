if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local bit = require("bit")
local band, bor, rshift, lshift = bit.band, bit.bor, bit.rshift, bit.lshift

local M = {}
M._tier = "pure"

-- Base32 alphabet used by geohash
local BASE32 = "0123456789bcdefghjkmnpqrstuvwxyz"

-- Lookup table: char -> 5-bit value
local DECODE_MAP = {}
for i = 1, #BASE32 do
  DECODE_MAP[BASE32:sub(i, i)] = i - 1
end

-- Encode lat/lon to geohash string of given precision (default 9)
function M.encode(lat, lon, precision)
  precision = precision or 9
  if type(lat) ~= "number" or type(lon) ~= "number" then
    return nil, "lat and lon must be numbers"
  end
  if lat < -90 or lat > 90 then
    return nil, "lat must be in [-90, 90]"
  end
  if lon < -180 or lon > 180 then
    return nil, "lon must be in [-180, 180]"
  end
  if precision < 1 or precision > 12 then
    return nil, "precision must be in [1, 12]"
  end

  local min_lat, max_lat = -90.0, 90.0
  local min_lon, max_lon = -180.0, 180.0

  local chars = {}
  local bits = 0
  local bitsTotal = 0
  local hashValue = 0
  local even = true -- odd positions = lon, even = lat; but we start with lon (even=true means lon)

  while #chars < precision do
    if even then
      -- bisect longitude
      local mid = (min_lon + max_lon) / 2
      if lon >= mid then
        hashValue = bor(lshift(hashValue, 1), 1)
        min_lon = mid
      else
        hashValue = lshift(hashValue, 1)
        max_lon = mid
      end
    else
      -- bisect latitude
      local mid = (min_lat + max_lat) / 2
      if lat >= mid then
        hashValue = bor(lshift(hashValue, 1), 1)
        min_lat = mid
      else
        hashValue = lshift(hashValue, 1)
        max_lat = mid
      end
    end
    even = not even
    bits = bits + 1
    bitsTotal = bitsTotal + 1

    if bits == 5 then
      chars[#chars + 1] = BASE32:sub(hashValue + 1, hashValue + 1)
      bits = 0
      hashValue = 0
    end
  end

  return table.concat(chars)
end

-- Decode geohash to {lat, lon, lat_err, lon_err}
function M.decode(hash)
  if type(hash) ~= "string" or #hash == 0 then
    return nil, "hash must be a non-empty string"
  end

  local min_lat, max_lat = -90.0, 90.0
  local min_lon, max_lon = -180.0, 180.0
  local even = true

  for i = 1, #hash do
    local c = hash:sub(i, i)
    local val = DECODE_MAP[c]
    if val == nil then
      return nil, "invalid geohash character: " .. c
    end
    -- Process 5 bits from MSB to LSB
    for j = 4, 0, -1 do
      local bit_val = band(rshift(val, j), 1)
      if even then
        -- longitude
        local mid = (min_lon + max_lon) / 2
        if bit_val == 1 then
          min_lon = mid
        else
          max_lon = mid
        end
      else
        -- latitude
        local mid = (min_lat + max_lat) / 2
        if bit_val == 1 then
          min_lat = mid
        else
          max_lat = mid
        end
      end
      even = not even
    end
  end

  local lat = (min_lat + max_lat) / 2
  local lon = (min_lon + max_lon) / 2
  local lat_err = (max_lat - min_lat) / 2
  local lon_err = (max_lon - min_lon) / 2

  return { lat = lat, lon = lon, lat_err = lat_err, lon_err = lon_err }
end

-- Decode geohash to bounding box {min_lat, min_lon, max_lat, max_lon}
function M.decode_bbox(hash)
  if type(hash) ~= "string" or #hash == 0 then
    return nil, "hash must be a non-empty string"
  end

  local min_lat, max_lat = -90.0, 90.0
  local min_lon, max_lon = -180.0, 180.0
  local even = true

  for i = 1, #hash do
    local c = hash:sub(i, i)
    local val = DECODE_MAP[c]
    if val == nil then
      return nil, "invalid geohash character: " .. c
    end
    for j = 4, 0, -1 do
      local bit_val = band(rshift(val, j), 1)
      if even then
        local mid = (min_lon + max_lon) / 2
        if bit_val == 1 then min_lon = mid else max_lon = mid end
      else
        local mid = (min_lat + max_lat) / 2
        if bit_val == 1 then min_lat = mid else max_lat = mid end
      end
      even = not even
    end
  end

  return { min_lat = min_lat, min_lon = min_lon, max_lat = max_lat, max_lon = max_lon }
end

-- Neighbor lookup tables (standard geohash neighbor algorithm)
-- These tables encode the neighbor character given current char and direction
-- Source: standard geohash neighbor algorithm by David Troy

local NEIGHBOR = {
  right  = { even = "bc01fg45telegramhij23mn6789", odd  = "p0r21436x8zb9dcf5h7kjnmqesgutwvy" },
  left   = { even = "238967debc01telegramfghi45jkmnopqrstuvwx", odd  = "14365h7k9dcfesgujnmqp0r2twvyx8zb" },
  top    = { even = "p0r21436x8zb9dcf5h7kjnmqesgutwvy", odd  = "bc01fg45telegramhij23mn6789" },
  bottom = { even = "14365h7k9dcfesgujnmqp0r2twvyx8zb", odd  = "238967debc01telegramfghi45jkmnopqrstuvwx" },
}

local BORDER = {
  right  = { even = "bcfguvyz", odd  = "prxz" },
  left   = { even = "0145hjnp", odd  = "028b" },
  top    = { even = "prxz",     odd  = "bcfguvyz" },
  bottom = { even = "028b",     odd  = "0145hjnp" },
}

-- The standard neighbor lookup tables (using the well-known approach)
-- We implement neighbor via decode+encode for simplicity and correctness
-- but offset by the appropriate delta in lat/lon space.

local function get_bbox_size(hash)
  local len = #hash
  -- Total bits = len * 5
  -- lat bits = ceil(len*5 / 2), lon bits = floor(len*5 / 2) + (len*5 % 2 == 1 and 1 or 0)
  -- Actually: for each char, bits alternate lon/lat starting with lon
  -- lon bits = ceil(len*5 / 2), lat bits = floor(len*5 / 2)
  local total_bits = len * 5
  local lon_bits = math.ceil(total_bits / 2)
  local lat_bits = math.floor(total_bits / 2)
  local lat_err = 180.0 / (2 ^ lat_bits)
  local lon_err = 360.0 / (2 ^ lon_bits)
  return lat_err * 2, lon_err * 2  -- full height, full width
end

-- Get neighbor in a cardinal or diagonal direction
-- direction: "n", "s", "e", "w", "ne", "nw", "se", "sw"
function M.neighbor(hash, direction)
  if type(hash) ~= "string" or #hash == 0 then
    return nil, "hash must be a non-empty string"
  end
  if type(direction) ~= "string" then
    return nil, "direction must be a string"
  end

  local result, err = M.decode(hash)
  if not result then return nil, err end

  local lat_h, lon_w = get_bbox_size(hash)

  local dlat, dlon = 0, 0
  local d = direction
  if d == "n" or d == "ne" or d == "nw" then dlat = lat_h end
  if d == "s" or d == "se" or d == "sw" then dlat = -lat_h end
  if d == "e" or d == "ne" or d == "se" then dlon = lon_w end
  if d == "w" or d == "nw" or d == "sw" then dlon = -lon_w end

  if dlat == 0 and dlon == 0 then
    return nil, "invalid direction: " .. direction
  end

  -- Clamp to valid ranges
  local new_lat = result.lat + dlat
  local new_lon = result.lon + dlon

  -- Handle longitude wrap-around
  if new_lon > 180 then new_lon = new_lon - 360 end
  if new_lon < -180 then new_lon = new_lon + 360 end

  -- Clamp latitude (poles don't wrap)
  if new_lat > 90 then new_lat = 90 - result.lat_err / 2 end
  if new_lat < -90 then new_lat = -90 + result.lat_err / 2 end

  return M.encode(new_lat, new_lon, #hash)
end

-- Get all 8 neighbors
function M.neighbors(hash)
  if type(hash) ~= "string" or #hash == 0 then
    return nil, "hash must be a non-empty string"
  end
  local dirs = { "n", "s", "e", "w", "ne", "nw", "se", "sw" }
  local result = {}
  for _, d in ipairs(dirs) do
    local nb, err = M.neighbor(hash, d)
    if not nb then return nil, err end
    result[d] = nb
  end
  return result
end

-- Check if two geohashes are neighbors (adjacent, including diagonals)
function M.are_neighbors(hash1, hash2)
  if type(hash1) ~= "string" or type(hash2) ~= "string" then
    return nil, "both arguments must be strings"
  end
  if #hash1 ~= #hash2 then
    return false
  end
  local nbs, err = M.neighbors(hash1)
  if not nbs then return nil, err end
  for _, v in pairs(nbs) do
    if v == hash2 then return true end
  end
  return false
end

-- Get geohashes within radius (bounding-box approximation)
-- Returns array of hashes covering the area within radius_km of (lat, lon)
function M.within(lat, lon, radius_km, precision)
  precision = precision or 9
  if type(lat) ~= "number" or type(lon) ~= "number" then
    return nil, "lat and lon must be numbers"
  end
  if type(radius_km) ~= "number" or radius_km <= 0 then
    return nil, "radius_km must be a positive number"
  end

  -- Convert radius to degrees (approximate)
  local lat_deg = radius_km / 111.0  -- ~111 km per degree latitude
  local lon_deg = radius_km / (111.0 * math.cos(math.rad(lat)))

  local min_lat = math.max(-90,  lat - lat_deg)
  local max_lat = math.min(90,   lat + lat_deg)
  local min_lon = math.max(-180, lon - lon_deg)
  local max_lon = math.min(180,  lon + lon_deg)

  -- Get cell size for the given precision
  local total_bits = precision * 5
  local lon_bits = math.ceil(total_bits / 2)
  local lat_bits = math.floor(total_bits / 2)
  local cell_lat = 180.0 / (2 ^ lat_bits)
  local cell_lon = 360.0 / (2 ^ lon_bits)

  -- Enumerate all cells covering the bounding box
  local seen = {}
  local result = {}

  local clat = min_lat
  while clat <= max_lat + cell_lat / 2 do
    local clon = min_lon
    while clon <= max_lon + cell_lon / 2 do
      local clat_c = math.max(-90, math.min(90, clat))
      local clon_c = math.max(-180, math.min(180, clon))
      local h = M.encode(clat_c, clon_c, precision)
      if h and not seen[h] then
        seen[h] = true
        result[#result + 1] = h
      end
      clon = clon + cell_lon
    end
    clat = clat + cell_lat
  end

  return result
end

return M
