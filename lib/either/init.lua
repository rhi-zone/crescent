-- lib/either/init.lua
-- Either<L, R> and Maybe<T> — algebraic data types with functor/monad interface.
--
-- Either:
--   Right(r) — success/value side  (right-biased: map/and_then act on Right)
--   Left(l)  — failure/error side
--
-- Maybe:
--   Some(v)  — value present
--   None     — value absent (singleton; call M.None() or use M.None directly)

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

M._tier = "pure"

-- ── Either ────────────────────────────────────────────────────────────────────

local Right_mt = {}
local Left_mt  = {}

Right_mt.__index = Right_mt
Left_mt.__index  = Left_mt

-- ── Right constructors / predicates ──────────────────────────────────────────

function M.Right(r)
	return setmetatable({ _tag = "right", _val = r }, Right_mt)
end

function Right_mt:is_right() return true  end
function Right_mt:is_left()  return false end

function Right_mt:right() return self._val end
function Right_mt:left()  return nil       end
function Right_mt:value() return self._val end

-- ── Left constructors / predicates ───────────────────────────────────────────

function M.Left(l)
	return setmetatable({ _tag = "left", _val = l }, Left_mt)
end

function Left_mt:is_right() return false end
function Left_mt:is_left()  return true  end

function Left_mt:right() return nil       end
function Left_mt:left()  return self._val end
function Left_mt:value() return self._val end

-- ── map ───────────────────────────────────────────────────────────────────────

function Right_mt:map(fn)
	return M.Right(fn(self._val))
end

function Left_mt:map(_fn)
	return self
end

-- ── map_left ──────────────────────────────────────────────────────────────────

function Right_mt:map_left(_fn)
	return self
end

function Left_mt:map_left(fn)
	return M.Left(fn(self._val))
end

-- ── and_then (flat_map / bind) ────────────────────────────────────────────────

function Right_mt:and_then(fn)
	return fn(self._val)
end

function Left_mt:and_then(_fn)
	return self
end

-- ── or_else ───────────────────────────────────────────────────────────────────

function Right_mt:or_else(_fn)
	return self
end

function Left_mt:or_else(fn)
	return fn(self._val)
end

-- ── fold ──────────────────────────────────────────────────────────────────────

-- fold(left_fn, right_fn) — apply the matching branch, return its result.
function Right_mt:fold(_left_fn, right_fn)
	return right_fn(self._val)
end

function Left_mt:fold(left_fn, _right_fn)
	return left_fn(self._val)
end

-- ── unwrap ────────────────────────────────────────────────────────────────────

function Right_mt:unwrap()
	return self._val
end

function Left_mt:unwrap()
	error(tostring(self._val), 2)
end

function Right_mt:unwrap_or(_default)
	return self._val
end

function Left_mt:unwrap_or(default)
	return default
end

function Right_mt:unwrap_or_else(_fn)
	return self._val
end

function Left_mt:unwrap_or_else(fn)
	return fn(self._val)
end

-- ── to_pair / from_pair ───────────────────────────────────────────────────────

-- Returns (value, nil) for Right, (nil, err) for Left — Lua error convention.
function Right_mt:to_pair()
	return self._val, nil
end

function Left_mt:to_pair()
	return nil, self._val
end

-- from_pair(value, err) — wraps a (value, err) Lua pair into Either.
-- If err is non-nil → Left(err), otherwise → Right(value).
function M.from_pair(value, err)
	if err ~= nil then
		return M.Left(err)
	end
	return M.Right(value)
end

-- ── to_maybe ──────────────────────────────────────────────────────────────────

function Right_mt:to_maybe()
	return M.Some(self._val)
end

function Left_mt:to_maybe()
	return M.None
end

-- ── __tostring ────────────────────────────────────────────────────────────────

Right_mt.__tostring = function(self)
	return "Right(" .. tostring(self._val) .. ")"
end

Left_mt.__tostring = function(self)
	return "Left(" .. tostring(self._val) .. ")"
end

-- ── Maybe ─────────────────────────────────────────────────────────────────────

local Some_mt = {}
local None_mt = {}

Some_mt.__index = Some_mt
None_mt.__index = None_mt

-- ── Some ──────────────────────────────────────────────────────────────────────

function M.Some(v)
	return setmetatable({ _tag = "some", _val = v }, Some_mt)
end

function Some_mt:is_some() return true  end
function Some_mt:is_none() return false end
function Some_mt:value()   return self._val end

-- ── None singleton ────────────────────────────────────────────────────────────
-- M.None is the singleton. M.None() also works (returns the same singleton).

local none_singleton

None_mt.__index = None_mt
None_mt.__call  = function(self) return self end   -- None() == None

None_mt.__tostring = function(_self) return "None" end

none_singleton = setmetatable({ _tag = "none" }, None_mt)

function None_mt:is_some() return false end
function None_mt:is_none() return true  end
function None_mt:value()   return nil   end

M.None = none_singleton

-- ── Maybe.map ─────────────────────────────────────────────────────────────────

function Some_mt:map(fn)
	return M.Some(fn(self._val))
end

function None_mt:map(_fn)
	return M.None
end

-- ── Maybe.and_then ────────────────────────────────────────────────────────────

function Some_mt:and_then(fn)
	return fn(self._val)
end

function None_mt:and_then(_fn)
	return M.None
end

-- ── Maybe.or_else ─────────────────────────────────────────────────────────────

function Some_mt:or_else(_fn)
	return self
end

function None_mt:or_else(fn)
	return fn()
end

-- ── Maybe.filter ──────────────────────────────────────────────────────────────

function Some_mt:filter(fn)
	if fn(self._val) then
		return self
	end
	return M.None
end

function None_mt:filter(_fn)
	return M.None
end

-- ── Maybe.unwrap ──────────────────────────────────────────────────────────────

function Some_mt:unwrap()
	return self._val
end

function None_mt:unwrap()
	error("called unwrap on None", 2)
end

function Some_mt:unwrap_or(_default)
	return self._val
end

function None_mt:unwrap_or(default)
	return default
end

function Some_mt:unwrap_or_else(_fn)
	return self._val
end

function None_mt:unwrap_or_else(fn)
	return fn()
end

-- ── Maybe.to_pair ─────────────────────────────────────────────────────────────

-- Returns (value, nil) for Some, (nil, nil) for None.
function Some_mt:to_pair()
	return self._val, nil
end

function None_mt:to_pair()
	return nil, nil
end

-- ── maybe_from ────────────────────────────────────────────────────────────────

-- maybe_from(v) → Some(v) if v ~= nil, else None.
function M.maybe_from(v)
	if v ~= nil then
		return M.Some(v)
	end
	return M.None
end

-- ── Maybe.to_right / to_either ────────────────────────────────────────────────

-- to_right(err_fn): Some(v) → Right(v), None → Left(err_fn()).
function Some_mt:to_right(_err_fn)
	return M.Right(self._val)
end

function None_mt:to_right(err_fn)
	return M.Left(err_fn())
end

-- Alias: to_either is the same as to_right.
Some_mt.to_either = Some_mt.to_right
None_mt.to_either = None_mt.to_right

-- ── Some.__tostring ───────────────────────────────────────────────────────────

Some_mt.__tostring = function(self)
	return "Some(" .. tostring(self._val) .. ")"
end

return M
