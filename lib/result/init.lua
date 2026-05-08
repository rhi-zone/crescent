if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

--:: Result = { _tag: string, _val: unknown, ... }

-- Sentinel to distinguish nil-as-value from absence.
-- Ok(nil) is valid and distinct from Err.
local OK = "ok"
local ERR = "err"

-- Metatable for Result objects
local Result = {}
Result.__index = Result

function Result:__tostring()
  if self._tag == OK then
    return "Ok(" .. tostring(self._val) .. ")"
  else
    return "Err(" .. tostring(self._val) .. ")"
  end
end

-- ── Constructors ────────────────────────────────────────────────────────────

--: (val: unknown) -> Result
function M.ok(val)
  return setmetatable({ _tag = OK, _val = val }, Result)
end

--: (err: unknown) -> Result
function M.err(err)
  return setmetatable({ _tag = ERR, _val = err }, Result)
end

--- Wrap a (value, errmsg) return pair into a Result.
--- If errmsg is non-nil, returns Err(errmsg). Otherwise returns Ok(value).
--: (val: unknown, err: unknown) -> Result
function M.from(val, err)
  if err ~= nil then
    return M.err(err)
  end
  return M.ok(val)
end

--- Wrap a pcall into a Result. fn is called with no arguments.
--- On success returns Ok(return_value), on error returns Err(errmsg).
--: (fn: () -> unknown) -> Result
function M.try(fn)
  local success, val = pcall(fn)
  if success then
    return M.ok(val)
  else
    return M.err(val)
  end
end

-- ── Query ───────────────────────────────────────────────────────────────────

--: () -> boolean
function Result:is_ok()
  return self._tag == OK
end

--: () -> boolean
function Result:is_err()
  return self._tag == ERR
end

--: () -> unknown
function Result:unwrap()
  if self._tag == OK then
    return self._val
  end
  error("called unwrap on Err: " .. tostring(self._val), 2)
end

--: (self: Result, default: unknown) -> unknown
function Result:unwrap_or(default)
  if self._tag == OK then
    return self._val
  end
  return default
end

--: () -> unknown
function Result:unwrap_err()
  if self._tag == ERR then
    return self._val
  end
  error("called unwrap_err on Ok: " .. tostring(self._val), 2)
end

--: (self: Result, msg: string) -> unknown
function Result:expect(msg)
  if self._tag == OK then
    return self._val
  end
  error(msg .. ": " .. tostring(self._val), 2)
end

-- ── Transform ───────────────────────────────────────────────────────────────

--- Map the Ok value. Err passes through unchanged.
--: (self: Result, fn: (unknown) -> unknown) -> Result
function Result:map(fn)
  if self._tag == OK then
    return M.ok(fn(self._val))
  end
  return self
end

--- Map the Err value. Ok passes through unchanged.
--: (self: Result, fn: (unknown) -> unknown) -> Result
function Result:map_err(fn)
  if self._tag == ERR then
    return M.err(fn(self._val))
  end
  return self
end

--- Flatmap: fn must return a Result. Short-circuits on Err.
--: (self: Result, fn: (unknown) -> Result) -> Result
function Result:and_then(fn)
  if self._tag == OK then
    return fn(self._val)
  end
  return self
end

--- Called on Err; fn must return a Result. Ok passes through.
--: (self: Result, fn: (unknown) -> Result) -> Result
function Result:or_else(fn)
  if self._tag == ERR then
    return fn(self._val)
  end
  return self
end

--- Call fn(val) for side effects on Ok, pass through the Result unchanged.
--: (self: Result, fn: (unknown) -> nil) -> Result
function Result:inspect(fn)
  if self._tag == OK then
    fn(self._val)
  end
  return self
end

--- Call fn(err) for side effects on Err, pass through the Result unchanged.
--: (self: Result, fn: (unknown) -> nil) -> Result
function Result:inspect_err(fn)
  if self._tag == ERR then
    fn(self._val)
  end
  return self
end

-- ── Combine ─────────────────────────────────────────────────────────────────

--- If all Results are Ok, returns Ok({v1, v2, ...}). Otherwise returns first Err.
--: (results: {Result}) -> Result
function M.all(results)
  local vals = {}
  for i = 1, #results do
    local r = results[i]
    if r._tag == ERR then
      return r
    end
    vals[i] = r._val
  end
  return M.ok(vals)
end

--- Returns the first Ok, or the last Err if all are Err.
--: (results: {Result}) -> Result
function M.any(results)
  local last
  for i = 1, #results do
    local r = results[i]
    if r._tag == OK then
      return r
    end
    last = r
  end
  return last
end

-- ── Convert ─────────────────────────────────────────────────────────────────

--- Convert back to Lua (value, errmsg) convention.
--- Ok(val) -> val, nil
--- Err(e)  -> nil, e
--: () -> (unknown, unknown)
function Result:to_pair()
  if self._tag == OK then
    return self._val, nil
  end
  return nil, self._val
end

return M
