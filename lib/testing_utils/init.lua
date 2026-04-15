-- lib/testing_utils: extended testing utilities for crescent
-- Mocking/spying, parameterized tests, benchmarking, deep equality,
-- table matchers, fake clock, and HTTP request recorder.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Spy / Mock / Stub
-- ---------------------------------------------------------------------------

-- Create a standalone spy wrapping fn (or a no-op if fn is nil).
-- Returns a callable table with .calls, .call_count, and :restore() (no-op).
function M.spy(fn)
  local s = {
    calls      = {},
    call_count = 0,
  }
  local mt = {}
  mt.__call = function(self, ...)
    self.call_count = self.call_count + 1
    local args = { ... }
    local ret  = { (fn and fn(...)) }
    self.calls[#self.calls + 1] = { args = args, return_values = ret }
    return unpack(ret)
  end
  s.restore = function() end
  setmetatable(s, mt)
  return s
end

-- Create a spy that always returns return_value (ignoring all arguments).
function M.stub(return_value)
  return M.spy(function() return return_value end)
end

-- Replace obj[method_name] with a spy wrapping replacement_fn (or the
-- existing method if replacement_fn is nil).  Returns the spy; call
-- spy:restore() to put the original back.
function M.mock(obj, method_name, replacement_fn)
  local original = obj[method_name]
  local wrapped  = replacement_fn or original
  local s = M.spy(wrapped)
  obj[method_name] = s
  s.restore = function()
    obj[method_name] = original
  end
  return s
end

-- ---------------------------------------------------------------------------
-- Parameterized tests
-- ---------------------------------------------------------------------------

-- M.each(cases, fn) returns a function that, when called (as the body of
-- T.it), iterates over cases and calls fn(unpack(case)) for each one.
-- Failures from individual cases propagate immediately.
function M.each(cases, fn)
  return function()
    for i = 1, #cases do
      fn(unpack(cases[i]))
    end
  end
end

-- ---------------------------------------------------------------------------
-- Benchmark harness
-- ---------------------------------------------------------------------------

-- Run fn repeatedly and return timing statistics.
-- opts: { iterations=1000, warmup=100, min_ms=100 }
-- Returns: { iterations, total_ms, per_iter_ms, ops_per_sec }
function M.bench(fn, opts)
  opts = opts or {}
  local warmup     = opts.warmup     or 100
  local iterations = opts.iterations or 1000
  local min_ms     = opts.min_ms     or 100
  local clock      = opts.clock_fn or error("testing_utils.bench: opts.clock_fn is required")

  for _ = 1, warmup do fn() end

  local t0    = clock()
  local count = 0
  repeat
    for _ = 1, iterations do fn() end
    count = count + iterations
  until (clock() - t0) * 1000 >= min_ms

  local elapsed_s  = clock() - t0
  local total_ms   = elapsed_s * 1000
  local per_iter   = total_ms / count
  local ops        = count / elapsed_s

  return {
    iterations   = count,
    total_ms     = total_ms,
    per_iter_ms  = per_iter,
    ops_per_sec  = ops,
  }
end

-- Run multiple named functions and compare them.
-- fns: { name = fn }
-- Returns: { [name] = result, fastest = name, slowest = name,
--            relative = { [name] = ratio_vs_fastest } }
function M.bench_compare(fns, opts)
  local results = {}
  for name, fn in pairs(fns) do
    results[name] = M.bench(fn, opts)
  end

  local fastest_name, fastest_ops = nil, -1
  local slowest_name, slowest_ops = nil, math.huge
  for name, r in pairs(results) do
    if r.ops_per_sec > fastest_ops then
      fastest_ops  = r.ops_per_sec
      fastest_name = name
    end
    if r.ops_per_sec < slowest_ops then
      slowest_ops  = r.ops_per_sec
      slowest_name = name
    end
  end

  local relative = {}
  for name, r in pairs(results) do
    relative[name] = r.ops_per_sec / fastest_ops
  end

  results.fastest  = fastest_name
  results.slowest  = slowest_name
  results.relative = relative
  return results
end

-- ---------------------------------------------------------------------------
-- Deep equality with diff output
-- ---------------------------------------------------------------------------

-- Returns (bool, diff_string).
-- diff_string is "" on equality, otherwise describes the first difference
-- with a path like ".users[2].name: expected 'alice' got 'bob'"
function M.deep_eq(a, b, _path)
  local path = _path or ""

  if type(a) ~= type(b) then
    return false, (path == "" and "." or path) ..
      ": type mismatch: expected " .. type(b) .. " got " .. type(a)
  end

  if type(a) ~= "table" then
    if a ~= b then
      local function fmt(v)
        if type(v) == "string" then return ("'%s'"):format(v) end
        return tostring(v)
      end
      return false, (path == "" and "." or path) ..
        ": expected " .. fmt(b) .. " got " .. fmt(a)
    end
    return true, ""
  end

  -- Check keys in b exist in a with correct values.
  for k, vb in pairs(b) do
    local va = a[k]
    local seg
    if type(k) == "number" then
      seg = "[" .. k .. "]"
    else
      seg = "." .. tostring(k)
    end
    local ok, diff = M.deep_eq(va, vb, path .. seg)
    if not ok then return false, diff end
  end

  -- Check a has no extra keys not in b.
  for k in pairs(a) do
    if b[k] == nil then
      local seg
      if type(k) == "number" then
        seg = "[" .. k .. "]"
      else
        seg = "." .. tostring(k)
      end
      return false, (path .. seg) .. ": unexpected key"
    end
  end

  return true, ""
end

-- ---------------------------------------------------------------------------
-- Table matchers
-- ---------------------------------------------------------------------------

local Matcher = {}
Matcher.__index = Matcher

local function new_matcher(test_fn, desc)
  return setmetatable({ _test = test_fn, _desc = desc }, Matcher)
end

function Matcher:test(value)
  return self._test(value)
end

-- True if actual contains all keys present in subset (extra keys are fine).
function M.contains(subset)
  return new_matcher(function(actual)
    if type(actual) ~= "table" then
      return false, "expected table, got " .. type(actual)
    end
    for k, v in pairs(subset) do
      local av = actual[k]
      if av == nil then
        return false, "missing key: " .. tostring(k)
      end
      if av ~= v then
        return false,
          "key " .. tostring(k) .. ": expected " .. tostring(v) ..
          " got " .. tostring(av)
      end
    end
    return true, ""
  end, "contains")
end

-- Each value in pattern_table can be a plain value (strict equality) or a
-- predicate function (called with the actual value, must return true).
function M.matches(pattern_table)
  return new_matcher(function(actual)
    if type(actual) ~= "table" then
      return false, "expected table, got " .. type(actual)
    end
    for k, pat in pairs(pattern_table) do
      local av = actual[k]
      if type(pat) == "function" then
        local ok, reason = pat(av)
        if not ok then
          return false,
            "key " .. tostring(k) .. " predicate failed: " .. tostring(reason)
        end
      else
        if av ~= pat then
          return false,
            "key " .. tostring(k) .. ": expected " .. tostring(pat) ..
            " got " .. tostring(av)
        end
      end
    end
    return true, ""
  end, "matches")
end

-- True if the value matches any of the supplied matchers or plain values.
function M.any_of(...)
  local candidates = { ... }
  return new_matcher(function(actual)
    for _, c in ipairs(candidates) do
      if type(c) == "table" and getmetatable(c) == Matcher then
        local ok = c:test(actual)
        if ok then return true, "" end
      else
        if actual == c then return true, "" end
      end
    end
    return false,
      "value did not match any of " .. #candidates .. " candidates"
  end, "any_of")
end

-- True if the value's metatable is mt.
function M.instance_of(mt)
  return new_matcher(function(actual)
    if getmetatable(actual) == mt then return true, "" end
    return false, "expected instance of given metatable"
  end, "instance_of")
end

-- ---------------------------------------------------------------------------
-- Fake clock
-- ---------------------------------------------------------------------------

-- Create a controllable clock.
-- clock.time          current fake time
-- clock:advance(d)    add d to time, return clock
-- clock:tick(d)       alias for advance
-- clock:freeze()      no-op (already controlled); return clock
-- clock:as_fn()       return function() return clock.time end
function M.fake_clock(start_time)
  local clock = { time = start_time or 0 }
  function clock:advance(delta)
    self.time = self.time + delta
    return self
  end
  clock.tick = clock.advance
  function clock:freeze()
    return self
  end
  function clock:as_fn()
    return function() return self.time end
  end
  return clock
end

-- ---------------------------------------------------------------------------
-- HTTP request recorder
-- ---------------------------------------------------------------------------

-- recorder:expect(method, path) -> expectation
--   expectation:respond(status, headers, body) -> expectation
--   expectation:times(n)                        -> expectation
-- recorder:as_client() -> fn(method, url, opts) -> status, headers, body
-- recorder:assert_all_called()
-- recorder:reset()

function M.http_recorder()
  local recorder = { _expectations = {} }

  function recorder:expect(method, path)
    local exp = {
      method   = method:upper(),
      path     = path,
      _times   = 1,
      _called  = 0,
      _status  = 200,
      _headers = {},
      _body    = "",
    }
    function exp:respond(status, headers, body)
      self._status  = status
      self._headers = headers or {}
      self._body    = body    or ""
      return self
    end
    function exp:times(n)
      self._times = n
      return self
    end
    self._expectations[#self._expectations + 1] = exp
    return exp
  end

  function recorder:as_client()
    local r = self
    return function(method, url, _opts)
      method = method:upper()
      -- Extract path from url (strip scheme+host if present).
      local path = url:match("^https?://[^/]+(/.*)$") or url
      for _, exp in ipairs(r._expectations) do
        if exp.method == method and exp.path == path then
          if exp._called < exp._times then
            exp._called = exp._called + 1
            return exp._status, exp._headers, exp._body
          end
        end
      end
      return nil, "no matching expectation for " .. method .. " " .. path
    end
  end

  function recorder:assert_all_called()
    for _, exp in ipairs(self._expectations) do
      if exp._called < exp._times then
        error(
          "expectation not satisfied: " .. exp.method .. " " .. exp.path ..
          " expected " .. exp._times .. " call(s), got " .. exp._called,
          2
        )
      end
    end
  end

  function recorder:reset()
    self._expectations = {}
  end

  return recorder
end

return M
