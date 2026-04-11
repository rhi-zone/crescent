if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local pi = math.pi

-- ---------------------------------------------------------------------------
-- Unit tables: each entry maps unit name → factor relative to canonical SI
-- base unit for the category.  Temperature is special (offset conversion).
-- ---------------------------------------------------------------------------

-- category → { canonical_unit, { alias → factor, ... } }
local CATEGORIES = {}

local function def(cat, base, units)
  CATEGORIES[cat] = { base = base, units = units }
end

def("length", "m", {
  m = 1, meter = 1, meters = 1,
  km = 1000, kilometer = 1000, kilometers = 1000,
  cm = 0.01, centimeter = 0.01, centimeters = 0.01,
  mm = 0.001, millimeter = 0.001, millimeters = 0.001,
  um = 1e-6, micrometer = 1e-6, micrometers = 1e-6,
  nm = 1e-9, nanometer = 1e-9, nanometers = 1e-9,
  ["in"] = 0.0254, inch = 0.0254, inches = 0.0254,
  ft = 0.3048, foot = 0.3048, feet = 0.3048,
  yd = 0.9144, yard = 0.9144, yards = 0.9144,
  mi = 1609.344, mile = 1609.344, miles = 1609.344,
  nmi = 1852, nautical_mile = 1852,
  ly = 9.461e15, light_year = 9.461e15,
  au = 1.496e11, astronomical_unit = 1.496e11,
})

def("mass", "kg", {
  kg = 1, kilogram = 1, kilograms = 1,
  g = 0.001, gram = 0.001, grams = 0.001,
  mg = 1e-6, milligram = 1e-6, milligrams = 1e-6,
  t = 1000, tonne = 1000, metric_ton = 1000,
  lb = 0.453592, pound = 0.453592, pounds = 0.453592,
  oz = 0.0283495, ounce = 0.0283495, ounces = 0.0283495,
  st = 6.35029, stone = 6.35029, stones = 6.35029,
  ton = 907.185, short_ton = 907.185,
  long_ton = 1016.05,
})

def("time", "s", {
  s = 1, sec = 1, second = 1, seconds = 1,
  ms = 0.001, millisecond = 0.001, milliseconds = 0.001,
  us = 1e-6, microsecond = 1e-6, microseconds = 1e-6,
  ns = 1e-9, nanosecond = 1e-9, nanoseconds = 1e-9,
  min = 60, minute = 60, minutes = 60,
  h = 3600, hr = 3600, hour = 3600, hours = 3600,
  d = 86400, day = 86400, days = 86400,
  wk = 604800, week = 604800, weeks = 604800,
  mo = 2629800, month = 2629800, months = 2629800,
  yr = 31557600, year = 31557600, years = 31557600,
})

-- Temperature is handled specially; register names but no factors.
def("temperature", "C", {
  C = true, celsius = true, degC = true,
  F = true, fahrenheit = true, degF = true,
  K = true, kelvin = true,
  R = true, rankine = true,
})

def("area", "m2", {
  m2 = 1, sq_m = 1,
  km2 = 1e6, sq_km = 1e6,
  cm2 = 1e-4, sq_cm = 1e-4,
  mm2 = 1e-6, sq_mm = 1e-6,
  in2 = 6.4516e-4, sq_in = 6.4516e-4,
  ft2 = 0.092903, sq_ft = 0.092903,
  yd2 = 0.836127, sq_yd = 0.836127,
  mi2 = 2.59e6, sq_mi = 2.59e6,
  acre = 4046.86,
  ha = 10000, hectare = 10000,
})

def("volume", "L", {
  L = 1, l = 1, liter = 1, liters = 1,
  mL = 0.001, ml = 0.001, milliliter = 0.001, milliliters = 0.001,
  m3 = 1000, cubic_meter = 1000,
  cm3 = 0.001, cubic_cm = 0.001, cc = 0.001,
  ft3 = 28.3168, cubic_ft = 28.3168,
  in3 = 0.0163871, cubic_in = 0.0163871,
  gal = 3.78541, gallon = 3.78541, gallons = 3.78541,
  qt = 0.946353, quart = 0.946353, quarts = 0.946353,
  pt = 0.473176, pint = 0.473176, pints = 0.473176,
  fl_oz = 0.0295735, fluid_ounce = 0.0295735,
  tsp = 0.00492892, teaspoon = 0.00492892,
  tbsp = 0.0147868, tablespoon = 0.0147868,
})

def("speed", "m/s", {
  ["m/s"] = 1, mps = 1,
  ["km/h"] = 1/3.6, kph = 1/3.6,
  mph = 0.44704,
  knot = 0.514444, kt = 0.514444,
  ["ft/s"] = 0.3048, fps = 0.3048,
})

def("pressure", "Pa", {
  Pa = 1, pascal = 1,
  kPa = 1000,
  MPa = 1e6,
  bar = 1e5,
  mbar = 100, millibar = 100,
  atm = 101325, atmosphere = 101325,
  psi = 6894.76,
  mmHg = 133.322, torr = 133.322,
  inHg = 3386.39,
})

def("energy", "J", {
  J = 1, joule = 1, joules = 1,
  kJ = 1000, kilojoule = 1000,
  MJ = 1e6, megajoule = 1e6,
  cal = 4.184, calorie = 4.184, calories = 4.184,
  kcal = 4184, kilocalorie = 4184, Calorie = 4184,
  Wh = 3600, watt_hour = 3600,
  kWh = 3.6e6,
  eV = 1.602e-19, electronvolt = 1.602e-19,
  BTU = 1055.06,
})

def("digital_storage", "B", {
  B = 1, byte = 1, bytes = 1,
  KB = 1024, kilobyte = 1024,
  MB = 1024^2, megabyte = 1024^2,
  GB = 1024^3, gigabyte = 1024^3,
  TB = 1024^4, terabyte = 1024^4,
  PB = 1024^5, petabyte = 1024^5,
  b = 0.125, bit = 0.125, bits = 0.125,
  Kb = 128, kilobit = 128,
  Mb = 131072, megabit = 131072,
  Gb = 134217728, gigabit = 134217728,
})

def("angle", "rad", {
  rad = 1, radian = 1, radians = 1,
  deg = pi/180, degree = pi/180, degrees = pi/180,
  grad = pi/200, gradian = pi/200,
  turn = 2*pi, revolution = 2*pi,
  arcmin = pi/10800, arcminute = pi/10800,
  arcsec = pi/648000, arcsecond = pi/648000,
})

-- ---------------------------------------------------------------------------
-- Lookup helpers
-- ---------------------------------------------------------------------------

-- unit_name → category name
local UNIT_TO_CAT = {}
for cat, info in pairs(CATEGORIES) do
  for unit in pairs(info.units) do
    UNIT_TO_CAT[unit] = cat
  end
end

-- ---------------------------------------------------------------------------
-- Temperature helpers
-- ---------------------------------------------------------------------------

local TEMP_ALIASES = {
  C = "C", celsius = "C", degC = "C",
  F = "F", fahrenheit = "F", degF = "F",
  K = "K", kelvin = "K",
  R = "R", rankine = "R",
}

local function to_celsius(v, unit)
  local u = TEMP_ALIASES[unit]
  if u == "C" then return v
  elseif u == "F" then return (v - 32) * 5/9
  elseif u == "K" then return v - 273.15
  elseif u == "R" then return (v - 491.67) * 5/9
  end
end

local function from_celsius(v, unit)
  local u = TEMP_ALIASES[unit]
  if u == "C" then return v
  elseif u == "F" then return v * 9/5 + 32
  elseif u == "K" then return v + 273.15
  elseif u == "R" then return (v + 273.15) * 9/5
  end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Convert value from one unit to another.
--- Returns converted_number, nil  OR  nil, errmsg
function M.convert(value, from_unit, to_unit)
  if type(value) ~= "number" then
    return nil, "value must be a number"
  end
  local from_cat = UNIT_TO_CAT[from_unit]
  local to_cat   = UNIT_TO_CAT[to_unit]
  if not from_cat then
    return nil, "unknown unit: " .. tostring(from_unit)
  end
  if not to_cat then
    return nil, "unknown unit: " .. tostring(to_unit)
  end
  if from_cat ~= to_cat then
    return nil, "cannot convert " .. from_cat .. " unit '" .. from_unit ..
                "' to " .. to_cat .. " unit '" .. to_unit .. "'"
  end
  if from_cat == "temperature" then
    return from_celsius(to_celsius(value, from_unit), to_unit), nil
  end
  local info = CATEGORIES[from_cat]
  local from_factor = info.units[from_unit]
  local to_factor   = info.units[to_unit]
  return value * from_factor / to_factor, nil
end

--- Parse a string like "5 km" or "72°F" or "72F".
--- Returns {value=number, unit=string}, nil  OR  nil, errmsg
function M.parse(str)
  if type(str) ~= "string" then
    return nil, "expected string"
  end
  -- strip leading/trailing whitespace
  str = str:match("^%s*(.-)%s*$")
  -- strip UTF-8 degree sign (U+00B0 = \xC2\xB0) that may appear between number and unit
  str = str:gsub("\xC2\xB0", " ")
  -- try: number, optional whitespace, unit
  local num_str, unit = str:match("^([+-]?%d*%.?%d+[eE]?[+-]?%d*)%s*(%S+)$")
  if not num_str then
    -- try number only (no unit)
    num_str = str:match("^([+-]?%d*%.?%d+)$")
    if num_str then
      return nil, "no unit found in: " .. str
    end
    return nil, "cannot parse: " .. str
  end
  local value = tonumber(num_str)
  if not value then
    return nil, "cannot parse number: " .. num_str
  end
  if not UNIT_TO_CAT[unit] then
    return nil, "unknown unit: " .. unit
  end
  return { value = value, unit = unit }, nil
end

--- Format a value with unit as a string.
--- opts: {precision=2, space=true}
function M.format(value, unit, opts)
  opts = opts or {}
  local precision = opts.precision
  if precision == nil then precision = 2 end
  local space = opts.space
  if space == nil then space = true end
  local sep = space and " " or ""
  local fmt_str = "%." .. precision .. "f"
  return string.format(fmt_str, value) .. sep .. tostring(unit)
end

--- List all known unit names in a category.
function M.list(category)
  local info = CATEGORIES[category]
  if not info then return nil, "unknown category: " .. tostring(category) end
  local result = {}
  for unit in pairs(info.units) do
    result[#result + 1] = unit
  end
  table.sort(result)
  return result
end

--- List all category names.
function M.categories()
  local result = {}
  for cat in pairs(CATEGORIES) do
    result[#result + 1] = cat
  end
  table.sort(result)
  return result
end

--- Check if a unit string is known.
function M.known(unit)
  return UNIT_TO_CAT[unit] ~= nil
end

return M
