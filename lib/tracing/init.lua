-- lib/tracing/init.lua
-- OpenTelemetry-inspired distributed tracing: spans, traces, exporters.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ── ID generation ──────────────────────────────────────────────────────────

local bit = require("bit")

-- Xorshift32 PRNG — safe in LuaJIT double precision (operates in 32-bit range).
-- Returns unsigned 32-bit integer.
local function _xorshift32(s)
  s = bit.bxor(s, bit.lshift(s, 13))
  s = bit.bxor(s, bit.rshift(s, 17))
  s = bit.bxor(s, bit.lshift(s, 5))
  s = bit.band(s, 0xFFFFFFFF)
  if s < 0 then s = s + 0x100000000 end
  if s == 0 then s = 1 end  -- avoid zero state
  return s
end

local _hex = "0123456789abcdef"

-- rng is a closure returning a non-negative integer each call.
-- We extract 4 bits at a time to produce hex digits.
local function _rand_hex(n, rng_state_ref)
  local t   = {}
  local s   = rng_state_ref[1]
  local bits = 0
  local val  = 0
  for i = 1, n do
    if bits < 4 then
      s   = _xorshift32(s)
      val  = s
      bits = 32
    end
    local nibble = val % 16
    t[i] = _hex:sub(nibble + 1, nibble + 1)
    val  = math.floor(val / 16)
    bits = bits - 4
  end
  rng_state_ref[1] = s
  return table.concat(t)
end

-- Returns a rng_state_ref table {state} and a _rand_hex-compatible call.
local function _make_rng(seed, time_fn)
  local s = seed or time_fn()
  if s == 0 then s = 1 end
  -- Warm up: avoid poor low-seed initial values
  s = _xorshift32(s)
  s = _xorshift32(s)
  s = _xorshift32(s)
  return { s }
end

-- ── Exporters ──────────────────────────────────────────────────────────────

function M.noop_exporter()
  return {
    export = function(_self, _span) end,
    spans  = function(_self) return {} end,
    reset  = function(_self) end,
  }
end

function M.memory_exporter()
  local store = {}
  return {
    export = function(_self, span)
      store[#store + 1] = span
    end,
    spans = function(_self)
      local copy = {}
      for i = 1, #store do copy[i] = store[i] end
      return copy
    end,
    reset = function(_self)
      store = {}
    end,
  }
end

function M.console_exporter()
  return {
    export = function(_self, span)
      local attrs = {}
      for k, v in pairs(span.attributes) do
        attrs[#attrs + 1] = k .. "=" .. tostring(v)
      end
      io.stderr:write(string.format(
        "[tracing] %s trace=%s span=%s parent=%s status=%s dur=%.3fms attrs={%s}\n",
        span.name,
        span.trace_id,
        span.span_id,
        span.parent_span_id or "-",
        span.status,
        span.duration_ms or 0,
        table.concat(attrs, ", ")
      ))
    end,
    spans = function(_self) return {} end,
    reset = function(_self) end,
  }
end

-- ── Span ───────────────────────────────────────────────────────────────────

local Span = {}
Span.__index = Span

function Span:set_attribute(key, value)
  self.attributes[key] = value
end

function Span:add_event(name, attrs)
  self.events[#self.events + 1] = {
    name       = name,
    time       = os.clock(),
    attributes = attrs or {},
  }
end

function Span:set_status(status, message)
  self.status = status
  self.status_message = message
end

function Span:finish()
  if self.end_time then return end  -- already finished
  self.end_time   = os.clock()
  self.duration_ms = (self.end_time - self.start_time) * 1000
  self._exporter:export(self)
end

function Span:context()
  return { trace_id = self.trace_id, span_id = self.span_id }
end

-- ── Tracer ─────────────────────────────────────────────────────────────────

local Tracer = {}
Tracer.__index = Tracer

function Tracer:start_span(name, opts)
  opts = opts or {}
  local trace_id, parent_span_id

  -- opts.parent: a Span object
  -- opts.context: a {trace_id, span_id} table from span:context() or T.extract()
  if opts.parent then
    trace_id       = opts.parent.trace_id
    parent_span_id = opts.parent.span_id
  elseif opts.context then
    trace_id       = opts.context.trace_id
    parent_span_id = opts.context.span_id
  else
    trace_id = _rand_hex(32, self._rng)
  end

  local span = setmetatable({
    name           = name,
    trace_id       = trace_id,
    span_id        = _rand_hex(16, self._rng),
    parent_span_id = parent_span_id,
    start_time     = os.clock(),
    end_time       = nil,
    duration_ms    = nil,
    attributes     = {},
    events         = {},
    status         = "unset",
    status_message = nil,
    _exporter      = self._exporter,
  }, Span)

  return span
end

function Tracer:with_span(name, opts_or_fn, fn)
  local opts, func
  if type(opts_or_fn) == "function" then
    opts = {}
    func = opts_or_fn
  else
    opts = opts_or_fn or {}
    func = fn
  end

  local span = self:start_span(name, opts)
  local ok, err = pcall(func, span)
  if not ok then
    span:set_status("error", tostring(err))
  end
  span:finish()
  if not ok then
    error(err, 2)
  end
end

-- ── Provider ───────────────────────────────────────────────────────────────

local Provider = {}
Provider.__index = Provider

function Provider:tracer(name)
  return setmetatable({
    _name     = name,
    _exporter = self._exporter,
    _rng      = self._rng,
  }, Tracer)
end

function M.provider(opts)
  assert(opts and opts.time_fn, "provider requires opts.time_fn")
  local exporter = opts.exporter or M.noop_exporter()
  local rng = _make_rng(opts.id_seed, opts.time_fn)
  return setmetatable({
    _exporter = exporter,
    _rng      = rng,
  }, Provider)
end

-- ── W3C TraceContext ────────────────────────────────────────────────────────

-- Inject: produce a W3C traceparent header string from a span.
-- Format: "00-{trace_id}-{span_id}-{flags}"
-- flags: "01" = sampled
function M.inject(span)
  return "00-" .. span.trace_id .. "-" .. span.span_id .. "-01"
end

-- Extract: parse a W3C traceparent header string.
-- Returns {trace_id, span_id, flags} or nil, errmsg on failure.
function M.extract(header)
  if type(header) ~= "string" then
    return nil, "extract: expected string, got " .. type(header)
  end
  -- version(2)-traceid(32)-spanid(16)-flags(2)
  local ver, tid, sid, flags = header:match("^(%x%x)-(%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x)-(%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x)-(%x%x)$")
  if not ver then
    return nil, "extract: invalid traceparent header: " .. header
  end
  return { trace_id = tid, span_id = sid, flags = flags, version = ver }
end

-- ── JSON export ─────────────────────────────────────────────────────────────

local function _json_string(s)
  s = tostring(s)
  s = s:gsub('\\', '\\\\')
  s = s:gsub('"',  '\\"')
  s = s:gsub('\n', '\\n')
  s = s:gsub('\r', '\\r')
  s = s:gsub('\t', '\\t')
  return '"' .. s .. '"'
end

local function _json_value(v)
  local t = type(v)
  if t == "string"  then return _json_string(v) end
  if t == "number"  then return tostring(v) end
  if t == "boolean" then return tostring(v) end
  if t == "nil"     then return "null" end
  return '"[unsupported]"'
end

local function _json_attrs(tbl)
  local parts = {}
  for k, v in pairs(tbl) do
    parts[#parts + 1] = _json_string(k) .. ":" .. _json_value(v)
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function _json_events(evts)
  local parts = {}
  for _, e in ipairs(evts) do
    local ep = {
      '"name":' .. _json_string(e.name),
      '"time":' .. tostring(e.time),
      '"attributes":' .. _json_attrs(e.attributes),
    }
    parts[#parts + 1] = "{" .. table.concat(ep, ",") .. "}"
  end
  return "[" .. table.concat(parts, ",") .. "]"
end

local function _json_span(s)
  local parts = {
    '"name":'            .. _json_string(s.name),
    '"trace_id":'        .. _json_string(--[[:! any]] s.trace_id),
    '"span_id":'         .. _json_string(--[[:! any]] s.span_id),
    '"parent_span_id":'  .. (s.parent_span_id and _json_string(--[[:! any]] s.parent_span_id) or "null"),
    '"start_time":'      .. tostring(s.start_time),
    '"end_time":'        .. (s.end_time and tostring(s.end_time) or "null"),
    '"duration_ms":'     .. (s.duration_ms and tostring(s.duration_ms) or "null"),
    '"status":'          .. _json_string(--[[:! any]] s.status),
    '"status_message":'  .. (s.status_message and _json_string(--[[:! any]] s.status_message) or "null"),
    '"attributes":'      .. _json_attrs(--[[:! any]] s.attributes),
    '"events":'          .. _json_events(s.events),
  }
  return "{" .. table.concat(parts, ",") .. "}"
end

-- Convert an array of finished span tables to an OTLP-like JSON string.
function M.to_json(spans)
  local parts = {}
  for _, s in ipairs(spans) do
    parts[#parts + 1] = _json_span(s)
  end
  return "[" .. table.concat(parts, ",") .. "]"
end

return M
