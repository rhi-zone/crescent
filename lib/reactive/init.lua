-- lib/reactive/init.lua
-- Push-based signal primitives.
-- API: signal, computed, effect, batch, focused, narrowed
-- Design: explicit dependency arrays, no implicit tracking scheduler.
-- Reference: rainbow/packages/core/src/ (TypeScript)

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local Maybe = require("lib.fp.maybe")

local M = {}

-- ── Batch ────────────────────────────────────────────────────────────────────

local _batch_depth = 0
-- Pending notifications: subscriber fn → thunk.
-- Using fn as key deduplicates multiple notifications to the same subscriber.
local _pending = {}

-- batch(fn) — defer and dedup all signal notifications until the outermost
-- batch returns, then flush in a loop (to handle cascading updates).
function M.batch(fn)
	_batch_depth = _batch_depth + 1
	local ok, err = pcall(fn)
	_batch_depth = _batch_depth - 1
	if _batch_depth == 0 then
		while next(_pending) do
			local thunks = {}
			for sub, thunk in pairs(_pending) do
				thunks[#thunks + 1] = thunk
				_pending[sub] = nil
			end
			for i = 1, #thunks do thunks[i]() end
		end
	end
	if not ok then error(err, 2) end
end

-- ── Equality ─────────────────────────────────────────────────────────────────

-- is_same(a, b): skip-no-op equality. Treats NaN as equal to itself
-- (mirrors Object.is semantics). For tables/functions: reference equality.
local function is_same(a, b)
	if a ~= a and b ~= b then return true end  -- both NaN
	return a == b
end

-- ── Internal notification ─────────────────────────────────────────────────────

local function fire(subscribers, value)
	if _batch_depth > 0 then
		for sub in pairs(subscribers) do
			_pending[sub] = function() sub(value) end
		end
	else
		local snap = {}
		for sub in pairs(subscribers) do snap[#snap + 1] = sub end
		for i = 1, #snap do snap[i](value) end
	end
end

-- ── signal ────────────────────────────────────────────────────────────────────

-- signal(init) — mutable signal.
-- Returns { get, set, update, subscribe, focus, narrow }
function M.signal(init)
	local value = init
	local subscribers = {}  -- set: fn -> true

	local s = {}

	function s.get()
		return value
	end

	function s.set(a)
		if is_same(value, a) then return end
		value = a
		fire(subscribers, value)
	end

	function s.update(f)
		s.set(f(value))
	end

	-- subscribe(fn) -> unsubscribe: register fn(new_value) on change.
	function s.subscribe(fn)
		subscribers[fn] = true
		return function() subscribers[fn] = nil end
	end

	-- focus(lens) -> Signal b — read/write through a Lens.
	function s.focus(lens)
		return M.focused(s, lens)
	end

	-- narrow(prism) -> Signal (b|nil) — prism-focused signal.
	function s.narrow(prism)
		return M.narrowed(s, prism)
	end

	return s
end

-- ── computed ──────────────────────────────────────────────────────────────────

-- computed(fn, deps) — read-only derived signal.
-- fn: () -> T; deps: array of signals or computed values.
-- Memoized: fn() only runs when a dep has changed since the last get().
-- Notifies subscribers only when the output value changes (via is_same).
-- Call c.dispose() when the computed is no longer needed to release dep subscriptions.
function M.computed(fn, deps)
	local c = {}
	local _cache     -- last computed value
	local _dirty = true  -- start dirty: first get() always computes
	local _subs = {}     -- { handler -> wrapped_fn }: our subscribers

	-- Notify all our subscribers with the current (recomputed) value.
	local function notify()
		local next_val = c.get()
		for _, wrapped in pairs(_subs) do wrapped(next_val) end
	end

	-- Single shared dep handler — shared reference enables batch deduplication:
	-- if multiple deps change in one batch, _pending[on_dep] is overwritten to
	-- the last thunk, so notify() fires once after all dep changes are applied.
	local function on_dep()
		_dirty = true
		notify()
	end

	-- Eagerly subscribe to all deps so _dirty is always up-to-date,
	-- even when nothing has called c.subscribe() yet.
	local _dep_unsubs = {}
	for i = 1, #deps do
		_dep_unsubs[i] = deps[i].subscribe(on_dep)
	end

	function c.get()
		if _dirty then
			_cache = fn()
			_dirty = false
		end
		return _cache
	end

	-- subscribe(handler) -> unsubscribe
	-- handler receives the new computed value whenever it changes.
	function c.subscribe(handler)
		local prev = c.get()
		local function wrapped(next_val)
			if not is_same(prev, next_val) then
				prev = next_val
				handler(next_val)
			end
		end
		_subs[handler] = wrapped
		return function() _subs[handler] = nil end
	end

	-- dispose() — unsubscribe from all deps. Call when the computed is no
	-- longer needed to prevent the dep→computed subscription from keeping
	-- the computed (and its fn closure) alive.
	function c.dispose()
		for i = 1, #_dep_unsubs do _dep_unsubs[i]() end
		_dep_unsubs = {}
	end

	-- focus(lens) -> read-only computed through a lens
	function c.focus(lens)
		return M.computed(function() return lens.get(c.get()) end, {c})
	end

	-- narrow(prism) -> read-only computed through a prism
	function c.narrow(prism)
		return M.computed(function()
			local m = prism.preview(c.get())
			if Maybe.is_nothing(m) then return nil end
			return m.value
		end, {c})
	end

	return c
end

-- ── effect ────────────────────────────────────────────────────────────────────

-- effect(fn, deps) — run fn immediately and re-run when any dep changes.
-- fn: () -> void; deps: array of signals or computed values.
-- Returns unsubscribe function.
function M.effect(fn, deps)
	fn()
	local unsubs = {}
	local function rerun() fn() end
	for i = 1, #deps do
		unsubs[i] = deps[i].subscribe(rerun)
	end
	return function()
		for i = 1, #unsubs do unsubs[i]() end
	end
end

-- ── focused ───────────────────────────────────────────────────────────────────

-- focused(source, lens) — read/write signal through a Lens.
-- source: Signal a; lens: Lens a b -> Signal b
-- Lens API: { get: s->a, set: (s,a)->s }
function M.focused(source, lens)
	local f = {}

	function f.get()
		return lens.get(source.get())
	end

	function f.set(b)
		source.set(lens.set(source.get(), b))
	end

	function f.update(fn)
		f.set(fn(f.get()))
	end

	-- subscribe(handler) -> unsubscribe
	function f.subscribe(handler)
		local prev = f.get()
		return source.subscribe(function()
			local next_val = f.get()
			if not is_same(prev, next_val) then
				prev = next_val
				handler(next_val)
			end
		end)
	end

	function f.focus(lens2)
		return M.focused(f, lens2)
	end

	function f.narrow(prism)
		return M.narrowed(f, prism)
	end

	return f
end

-- ── narrowed ──────────────────────────────────────────────────────────────────

-- narrowed(source, prism) — prism-focused signal for sum types.
-- source: Signal a; prism: Prism a b -> Signal (b|nil)
-- get() returns nil when the prism doesn't match the current value.
-- set(b) is a no-op when b is nil.
-- Prism API: { preview: s->Maybe a, review: a->s }
function M.narrowed(source, prism)
	local function extract()
		local m = prism.preview(source.get())
		if Maybe.is_nothing(m) then return nil end
		return m.value
	end

	local n = {}

	function n.get()
		return extract()
	end

	function n.set(b)
		if b ~= nil then
			source.set(prism.review(b))
		end
	end

	function n.update(fn)
		local cur = n.get()
		if cur ~= nil then n.set(fn(cur)) end
	end

	-- subscribe(handler) -> unsubscribe
	function n.subscribe(handler)
		local prev = n.get()
		return source.subscribe(function()
			local next_val = n.get()
			if not is_same(prev, next_val) then
				prev = next_val
				handler(next_val)
			end
		end)
	end

	function n.focus(lens)
		return M.focused(n, lens)
	end

	function n.narrow(prism2)
		return M.narrowed(n, prism2)
	end

	return n
end

return M
