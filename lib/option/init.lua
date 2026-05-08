-- lib/option/init.lua
-- Option/Maybe monad for nullable values.
--
-- Some(v) — value present (v must not be nil)
-- None    — value absent (singleton)

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

M._tier = "pure"

--:: Some = { _val: unknown, is_some: (self: unknown) -> boolean, is_none: (self: unknown) -> boolean, ... }
--:: None = { _val: nil, is_some: (self: unknown) -> boolean, is_none: (self: unknown) -> boolean, ... }
--:: Option = Some | None

-- ── Metatables ────────────────────────────────────────────────────────────────

local Some_mt = {}
local None_mt = {}

Some_mt.__index = Some_mt
None_mt.__index = None_mt

-- ── Construction ──────────────────────────────────────────────────────────────

--: (v: unknown) -> Some
function M.some(v)
	if v == nil then
		error("Option.some: value must not be nil", 2)
	end
	return setmetatable({ _val = v }, Some_mt)
end

-- None singleton declared below after None_mt methods are defined.

--: (v: unknown) -> Option
function M.of(v)
	if v ~= nil then
		return M.some(v)
	end
	return M.none
end

-- from_result(ok, err): Some(ok) when ok ~= nil, else None.
-- Mirrors Lua's (value, errmsg) convention.
--: (ok: unknown, err: unknown) -> Option
function M.from_result(ok, _err)
	if ok ~= nil then
		return M.some(ok)
	end
	return M.none
end

-- from_fn(fn): wraps a function that may return nil into one that returns Option.
--: (fn: (unknown) -> unknown) -> (unknown) -> Option
function M.from_fn(fn)
	--: (x: unknown) -> Option
	return function(x)
		local v = fn(x)
		if v ~= nil then
			return M.some(v)
		end
		return M.none
	end
end

-- ── Predicates ────────────────────────────────────────────────────────────────

function Some_mt:is_some() return true  end
function Some_mt:is_none() return false end

function None_mt:is_some() return false end
function None_mt:is_none() return true  end

-- ── Unwrap ────────────────────────────────────────────────────────────────────

function Some_mt:unwrap()
	return self._val
end

function None_mt:unwrap()
	error("called unwrap on None", 2)
end

-- Alias: value() is unwrap()
Some_mt.value = Some_mt.unwrap
None_mt.value = None_mt.unwrap

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

-- ── Transformations ───────────────────────────────────────────────────────────

function Some_mt:map(fn)
	return M.some(fn(self._val))
end

function None_mt:map(_fn)
	return M.none
end

-- and_then: fn must return an Option.
function Some_mt:and_then(fn)
	return fn(self._val)
end

function None_mt:and_then(_fn)
	return M.none
end

-- or_: if None, use the provided option; if Some, return self.
function Some_mt:or_(_opt)
	return self
end

function None_mt:or_(opt)
	return opt
end

-- or_else: if None, compute an alternative Option lazily.
function Some_mt:or_else(_fn)
	return self
end

function None_mt:or_else(fn)
	return fn()
end

-- filter: Some → None when predicate is false; None stays None.
function Some_mt:filter(pred)
	if pred(self._val) then
		return self
	end
	return M.none
end

function None_mt:filter(_pred)
	return M.none
end

-- ── Conversion ────────────────────────────────────────────────────────────────

-- to_table: Some(v) → {v}, None → {}
function Some_mt:to_table()
	return { self._val }
end

function None_mt:to_table()
	return {}
end

-- to_result(errmsg): Some(v) → (v, nil), None → (nil, errmsg)
function Some_mt:to_result(_errmsg)
	return self._val, nil
end

function None_mt:to_result(errmsg)
	return nil, errmsg
end

-- to_bool: true for Some, false for None
function Some_mt:to_bool() return true  end
function None_mt:to_bool() return false end

-- ── Combinators ───────────────────────────────────────────────────────────────

-- all(opts): Some({v1,v2,...}) if all are Some, else None.
--: (opts: Arr<Option>) -> Option
function M.all(opts)
	local vals = {}
	for i = 1, #opts do
		local o = opts[i]
		if o:is_none() then
			return M.none
		end
		vals[i] = o._val
	end
	return M.some(vals)
end

-- any(opts): first Some, or None if all are None.
--: (opts: Arr<Option>) -> Option
function M.any(opts)
	for i = 1, #opts do
		local o = opts[i]
		if o:is_some() then
			return o
		end
	end
	return M.none
end

-- ── Metamethods ───────────────────────────────────────────────────────────────

Some_mt.__tostring = function(self)
	return "Some(" .. tostring(self._val) .. ")"
end

None_mt.__tostring = function(_self)
	return "None"
end

-- __eq: two Options are equal when both are None, or both are Some with equal values.
Some_mt.__eq = function(a, b)
	if getmetatable(b) ~= Some_mt then return false end
	return a._val == b._val
end

None_mt.__eq = function(_a, b)
	return getmetatable(b) == None_mt
end

-- __bor: opt1 | opt2  →  opt1:or_(opt2)
Some_mt.__bor = function(a, b) return a:or_(b) end
None_mt.__bor = function(a, b) return a:or_(b) end

-- ── None singleton ────────────────────────────────────────────────────────────

M.none = setmetatable({ _val = nil }, None_mt)

return M
