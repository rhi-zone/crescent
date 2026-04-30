-- lib/metric/init.lua
-- Prometheus-compatible metrics collection: counter, gauge, histogram, summary.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ── Helpers ──────────────────────────────────────────────────────────────────

-- Build a canonical label key from a label table and declared label names.
-- Returns a stable string like 'method="GET",status="200"' (sorted by name).
local function label_key(label_names, labels)
  local parts = {}
  for i = 1, #label_names do
    local k = label_names[i]
    local v = labels[k]
    if v == nil then
      error("missing label '" .. k .. "'", 3)
    end
    parts[i] = k .. '="' .. tostring(v) .. '"'
  end
  -- label_names are the canonical order; sort them for stable output
  table.sort(parts)
  return table.concat(parts, ",")
end

-- Validate that labels contains exactly the declared label names.
local function validate_labels(label_names, labels)
  for i = 1, #label_names do
    local k = label_names[i]
    if labels[k] == nil then
      error("missing label '" .. k .. "'", 3)
    end
  end
  -- check no extra keys
  local count = 0
  for _ in pairs(labels) do count = count + 1 end
  if count ~= #label_names then
    error("wrong number of labels: expected " .. #label_names .. ", got " .. count, 3)
  end
end

-- Format a number for Prometheus output.
local function fmt_num(n)
  if n == math.huge then return "+Inf" end
  if n ~= n then return "NaN" end  -- NaN check
  -- emit integer representation when possible
  if n == math.floor(n) and math.abs(n) < 1e15 then
    return string.format("%d", n)
  end
  return string.format("%g", n)
end

-- Build label string for output: {method="GET",status="200"}
-- Returns "" when there are no labels, else the braces form.
local function label_str(label_names, labels, extra_k, extra_v)
  -- Collect all pairs
  local parts = {}
  for i = 1, #label_names do
    local k = label_names[i]
    parts[#parts + 1] = k .. '="' .. tostring(labels[k]) .. '"'
  end
  if extra_k ~= nil then
    parts[#parts + 1] = extra_k .. '="' .. tostring(extra_v) .. '"'
  end
  -- sort for stable output
  table.sort(parts)
  if #parts == 0 then return "" end
  return "{" .. table.concat(parts, ",") .. "}"
end

-- ── Counter ───────────────────────────────────────────────────────────────────

local Counter = {}
Counter.__index = Counter

local function new_counter(name, help, label_names)
  return setmetatable({
    _name        = name,
    _help        = help,
    _label_names = label_names,
    _values      = {},  -- key → number
  }, Counter)
end

function Counter:inc(labels, n)
  n = n or 1
  if n < 0 then error("counter increment must be non-negative", 2) end
  validate_labels(self._label_names, labels)
  local k = label_key(self._label_names, labels)
  self._values[k] = (self._values[k] or 0) + n
end

function Counter:get(labels)
  validate_labels(self._label_names, labels)
  local k = label_key(self._label_names, labels)
  return self._values[k] or 0
end

function Counter:_render(out)
  out[#out + 1] = "# HELP " .. self._name .. " " .. self._help
  out[#out + 1] = "# TYPE " .. self._name .. " counter"
  -- collect keys for stable ordering
  local keys = {}
  for k in pairs(self._values) do keys[#keys + 1] = k end
  table.sort(--[[:! { [integer]: string }]] keys)
  for _, k in ipairs(keys) do
    -- k is already "label=value,..." form; reconstruct label str with braces
    local ls = k == "" and "" or "{" .. k .. "}"
    out[#out + 1] = self._name .. ls .. " " .. fmt_num(self._values[k])
  end
end

function Counter:_reset()
  self._values = {}
end

-- ── Gauge ─────────────────────────────────────────────────────────────────────

local Gauge = {}
Gauge.__index = Gauge

local function new_gauge(name, help, label_names)
  return setmetatable({
    _name        = name,
    _help        = help,
    _label_names = label_names,
    _values      = {},
  }, Gauge)
end

function Gauge:set(labels, v)
  validate_labels(self._label_names, labels)
  local k = label_key(self._label_names, labels)
  self._values[k] = v
end

function Gauge:inc(labels, n)
  n = n or 1
  validate_labels(self._label_names, labels)
  local k = label_key(self._label_names, labels)
  self._values[k] = (self._values[k] or 0) + n
end

function Gauge:dec(labels, n)
  n = n or 1
  validate_labels(self._label_names, labels)
  local k = label_key(self._label_names, labels)
  self._values[k] = (self._values[k] or 0) - n
end

function Gauge:get(labels)
  validate_labels(self._label_names, labels)
  local k = label_key(self._label_names, labels)
  return self._values[k] or 0
end

function Gauge:_render(out)
  out[#out + 1] = "# HELP " .. self._name .. " " .. self._help
  out[#out + 1] = "# TYPE " .. self._name .. " gauge"
  local keys = {}
  for k in pairs(self._values) do keys[#keys + 1] = k end
  table.sort(--[[:! { [integer]: string }]] keys)
  for _, k in ipairs(keys) do
    local ls = k == "" and "" or "{" .. k .. "}"
    out[#out + 1] = self._name .. ls .. " " .. fmt_num(self._values[k])
  end
end

function Gauge:_reset()
  self._values = {}
end

-- ── Histogram ─────────────────────────────────────────────────────────────────

local DEFAULT_BUCKETS = {0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10}

local Histogram = {}
Histogram.__index = Histogram

local function new_histogram(name, help, label_names, buckets)
  buckets = buckets or DEFAULT_BUCKETS
  -- copy and sort buckets, add +Inf
  local bkts = {}
  for i = 1, #buckets do bkts[i] = buckets[i] end
  table.sort(bkts)
  bkts[#bkts + 1] = math.huge  -- +Inf always added

  return setmetatable({
    _name        = name,
    _help        = help,
    _label_names = label_names,
    _buckets     = bkts,
    -- per-labelset data: key → { sum, count, counts[] parallel to _buckets }
    _data        = {},
  }, Histogram)
end

local function hist_entry(h)
  local counts = {}
  for i = 1, #h._buckets do counts[i] = 0 end
  return { sum = 0, count = 0, counts = counts }
end

function Histogram:observe(labels, v)
  validate_labels(self._label_names, labels)
  local k = label_key(self._label_names, labels)
  if not self._data[k] then self._data[k] = hist_entry(self) end
  local d = self._data[k]
  d.sum   = d.sum + v
  d.count = d.count + 1
  for i = 1, #self._buckets do
    if v <= self._buckets[i] then
      d.counts[i] = d.counts[i] + 1
    end
  end
end

function Histogram:sum(labels)
  validate_labels(self._label_names, labels)
  local k = label_key(self._label_names, labels)
  return self._data[k] and self._data[k].sum or 0
end

function Histogram:count(labels)
  validate_labels(self._label_names, labels)
  local k = label_key(self._label_names, labels)
  return self._data[k] and self._data[k].count or 0
end

-- Returns table {[le_value] = cumulative_count, ...}
function Histogram:buckets(labels)
  validate_labels(self._label_names, labels)
  local k = label_key(self._label_names, labels)
  local result = {}
  if not self._data[k] then
    for i = 1, #self._buckets do
      result[self._buckets[i]] = 0
    end
  else
    local d = self._data[k]
    for i = 1, #self._buckets do
      result[self._buckets[i]] = d.counts[i]
    end
  end
  return result
end

function Histogram:_render(out)
  out[#out + 1] = "# HELP " .. self._name .. " " .. self._help
  out[#out + 1] = "# TYPE " .. self._name .. " histogram"
  local keys = {}
  for k in pairs(self._data) do keys[#keys + 1] = k end
  table.sort(--[[:! { [integer]: string }]] keys)
  for _, k in ipairs(keys) do
    local d = self._data[k]
    -- reconstruct label table for label_str; k is already sorted pairs
    -- easier: just inline manually
    local base_ls = k == "" and "" or "," .. k
    for i = 1, #self._buckets do
      local le = self._buckets[i]
      local le_str = fmt_num(le)
      local ls
      if k == "" then
        ls = '{le="' .. le_str .. '"}'
      else
        -- merge: le first, then user labels — but Prometheus sorts; just put le at end
        -- convention: user labels first, le last (standard practice)
        ls = "{" .. k .. ',le="' .. le_str .. '"}'
      end
      out[#out + 1] = self._name .. "_bucket" .. ls .. " " .. fmt_num(d.counts[i])
    end
    -- sum and count use base labels (no le)
    local ls = k == "" and "" or "{" .. k .. "}"
    out[#out + 1] = self._name .. "_sum" .. ls .. " " .. fmt_num(d.sum)
    out[#out + 1] = self._name .. "_count" .. ls .. " " .. fmt_num(d.count)
  end
end

function Histogram:_reset()
  self._data = {}
end

-- ── Summary ───────────────────────────────────────────────────────────────────

local Summary = {}
Summary.__index = Summary

local function new_summary(name, help, label_names)
  return setmetatable({
    _name        = name,
    _help        = help,
    _label_names = label_names,
    _data        = {},  -- key → { sum, count }
  }, Summary)
end

function Summary:observe(labels, v)
  validate_labels(self._label_names, labels)
  local k = label_key(self._label_names, labels)
  if not self._data[k] then self._data[k] = { sum = 0, count = 0 } end
  local d = self._data[k]
  d.sum   = d.sum + v
  d.count = d.count + 1
end

function Summary:sum(labels)
  validate_labels(self._label_names, labels)
  local k = label_key(self._label_names, labels)
  return self._data[k] and self._data[k].sum or 0
end

function Summary:count(labels)
  validate_labels(self._label_names, labels)
  local k = label_key(self._label_names, labels)
  return self._data[k] and self._data[k].count or 0
end

function Summary:_render(out)
  out[#out + 1] = "# HELP " .. self._name .. " " .. self._help
  out[#out + 1] = "# TYPE " .. self._name .. " summary"
  local keys = {}
  for k in pairs(self._data) do keys[#keys + 1] = k end
  table.sort(--[[:! { [integer]: string }]] keys)
  for _, k in ipairs(keys) do
    local d = self._data[k]
    local ls = k == "" and "" or "{" .. k .. "}"
    out[#out + 1] = self._name .. "_sum" .. ls .. " " .. fmt_num(d.sum)
    out[#out + 1] = self._name .. "_count" .. ls .. " " .. fmt_num(d.count)
  end
end

function Summary:_reset()
  self._data = {}
end

-- ── Registry ──────────────────────────────────────────────────────────────────

local Registry = {}
Registry.__index = Registry

local function new_registry()
  return setmetatable({
    _metrics = {},  -- name → metric object
    _order   = {},  -- insertion order list
  }, Registry)
end

local function reg_register(reg, metric)
  local name = metric._name
  if reg._metrics[name] then
    error("metric already registered: " .. name, 3)
  end
  reg._metrics[name] = metric
  reg._order[#reg._order + 1] = name
  return metric
end

function Registry:counter(name, help, label_names)
  return reg_register(self, new_counter(name, help, label_names or {}))
end

function Registry:gauge(name, help, label_names)
  return reg_register(self, new_gauge(name, help, label_names or {}))
end

function Registry:histogram(name, help, label_names, buckets)
  return reg_register(self, new_histogram(name, help, label_names or {}, buckets))
end

function Registry:summary(name, help, label_names)
  return reg_register(self, new_summary(name, help, label_names or {}))
end

function Registry:render()
  local out = {}
  for _, name in ipairs(self._order) do
    self._metrics[name]:_render(out)
  end
  return table.concat(out, "\n") .. (next(self._metrics) and "\n" or "")
end

function Registry:reset()
  for _, name in ipairs(self._order) do
    self._metrics[name]:_reset()
  end
end

-- ── Module-level API (default registry) ───────────────────────────────────────

M.registry = new_registry

local _default = new_registry()

function M.counter(name, help, label_names)
  return _default:counter(name, help, label_names)
end

function M.gauge(name, help, label_names)
  return _default:gauge(name, help, label_names)
end

function M.histogram(name, help, label_names, buckets)
  return _default:histogram(name, help, label_names, buckets)
end

function M.summary(name, help, label_names)
  return _default:summary(name, help, label_names)
end

function M.render()
  return _default:render()
end

function M._reset_default()
  _default = new_registry()
end

return M
