-- lib/promise/init.lua
-- Promise/Future for asynchronous programming.
-- Promises/A+ inspired, adapted for Lua. Operates synchronously --
-- all handlers execute immediately on resolve/reject. Can integrate
-- with an event loop later by deferring handler dispatch.
--
-- Public API:
--   M.new(executor)        -> promise  (executor receives resolve, reject)
--   M.resolve(value)       -> promise  (already fulfilled)
--   M.reject(reason)       -> promise  (already rejected)
--   p:and_then(on_fulfilled) -> promise
--   p:catch(on_rejected)     -> promise
--   p:finally(on_settled)    -> promise
--   p:state()  -> "pending" | "fulfilled" | "rejected"
--   p:value()  -> resolved value or nil
--   p:reason() -> rejection reason or nil
--   p:await()  -> value, err
--   M.all(promises)          -> promise
--   M.race(promises)         -> promise
--   M.all_settled(promises)  -> promise
--   M.any(promises)          -> promise

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

local STATE_PENDING   = "pending"
local STATE_FULFILLED = "fulfilled"
local STATE_REJECTED  = "rejected"

-- Promise metatable
local Promise = {}
Promise.__index = Promise

--: (self: Promise) -> "pending" | "fulfilled" | "rejected"
function Promise:state()
	return self._state
end

--: (self: Promise) -> unknown | nil
function Promise:value()
	if self._state == STATE_FULFILLED then
		return self._value
	end
	return nil
end

--: (self: Promise) -> unknown | nil
function Promise:reason()
	if self._state == STATE_REJECTED then
		return self._reason
	end
	return nil
end

-- Internal: create a raw promise object (no executor).
local function make_promise()
	local p = setmetatable({
		_state = STATE_PENDING,
		_value = nil,
		_reason = nil,
		_handlers = {},  -- list of {on_fulfilled, on_rejected, child_resolve, child_reject}
	}, Promise)
	return p
end

-- Internal: resolve a promise. If value is itself a promise, adopt its state.
local function resolve_promise(p, value)
	if p._state ~= STATE_PENDING then return end
	-- If value is a promise, adopt its state
	if type(value) == "table" and getmetatable(value) == Promise then
		if value._state == STATE_FULFILLED then
			resolve_promise(p, value._value)
		elseif value._state == STATE_REJECTED then
			reject_promise(p, value._reason)
		else
			-- value is still pending -- attach handlers
			value:and_then(
				function(v) resolve_promise(p, v) end
			):catch(
				function(r) reject_promise(p, r) end
			)
		end
		return
	end
	p._state = STATE_FULFILLED
	p._value = value
	-- Flush handlers
	for i = 1, #p._handlers do
		local h = p._handlers[i]
		local on_fulfilled = h[1]
		local child_resolve = h[3]
		local child_reject = h[4]
		if on_fulfilled then
			local ok, result = pcall(on_fulfilled, value)
			if ok then
				child_resolve(result)
			else
				child_reject(result)
			end
		else
			child_resolve(value)
		end
	end
	p._handlers = nil
end

-- Internal: reject a promise.
-- Forward declaration used by resolve_promise.
function reject_promise(p, reason) -- luacheck: ignore 111
	if p._state ~= STATE_PENDING then return end
	p._state = STATE_REJECTED
	p._reason = reason
	-- Flush handlers
	for i = 1, #p._handlers do
		local h = p._handlers[i]
		local on_rejected = h[2]
		local child_resolve = h[3]
		local child_reject = h[4]
		if on_rejected then
			local ok, result = pcall(on_rejected, reason)
			if ok then
				child_resolve(result)
			else
				child_reject(result)
			end
		else
			child_reject(reason)
		end
	end
	p._handlers = nil
end

--- Chain a fulfillment handler. Returns a new promise.
--: (self: Promise, on_fulfilled: (value: unknown) -> unknown) -> Promise
function Promise:and_then(on_fulfilled)
	local child = make_promise()
	local function child_resolve(v) resolve_promise(child, v) end
	local function child_reject(r) reject_promise(child, r) end

	if self._state == STATE_FULFILLED then
		if on_fulfilled then
			local ok, result = pcall(on_fulfilled, self._value)
			if ok then
				resolve_promise(child, --[[: any]] result)
			else
				reject_promise(child, result)
			end
		else
			resolve_promise(child, self._value)
		end
	elseif self._state == STATE_REJECTED then
		reject_promise(child, self._reason)
	else
		self._handlers[#self._handlers + 1] = {on_fulfilled, nil, child_resolve, child_reject}
	end
	return child
end

--- Chain a rejection handler. Returns a new promise.
--: (self: Promise, on_rejected: (reason: unknown) -> unknown) -> Promise
function Promise:catch(on_rejected)
	local child = make_promise()
	local function child_resolve(v) resolve_promise(child, v) end
	local function child_reject(r) reject_promise(child, r) end

	if self._state == STATE_REJECTED then
		if on_rejected then
			local ok, result = pcall(on_rejected, self._reason)
			if ok then
				resolve_promise(child, --[[: any]] result)
			else
				reject_promise(child, result)
			end
		else
			reject_promise(child, self._reason)
		end
	elseif self._state == STATE_FULFILLED then
		resolve_promise(child, self._value)
	else
		self._handlers[#self._handlers + 1] = {nil, on_rejected, child_resolve, child_reject}
	end
	return child
end

--- Attach a handler that runs regardless of outcome. The original value/reason
--- passes through unless the handler throws.
--: (self: Promise, on_settled: () -> ()) -> Promise
function Promise:finally(on_settled)
	return self:and_then(function(value)
		if on_settled then on_settled() end
		return value
	end):catch(function(reason)
		if on_settled then on_settled() end
		return M.reject(reason)
	end)
end

--- Synchronous await. Returns (value, nil) on fulfillment or (nil, reason) on rejection.
--- In synchronous mode all promises settle immediately so this never actually blocks.
--: (self: Promise) -> (unknown, string | nil)
function Promise:await()
	if self._state == STATE_FULFILLED then
		return self._value, nil
	elseif self._state == STATE_REJECTED then
		return nil, self._reason
	end
	return nil, "promise is pending"
end

---------------------------------------------------------------------------
-- Constructors
---------------------------------------------------------------------------

--- Create a new promise with an executor function.
--: (executor: (resolve: (value: unknown) -> (), reject: (reason: unknown) -> ()) -> ()) -> Promise
function M.new(executor)
	local p = make_promise()
	local function res(v) resolve_promise(p, --[[: any]] v) end
	local function rej(r) reject_promise(p, --[[: any]] r) end
	local ok, err = pcall(executor, res, rej)
	if not ok then
		reject_promise(p, err)
	end
	return p
end

--- Create an already-fulfilled promise.
--: (value: unknown) -> Promise
function M.resolve(value)
	local p = make_promise()
	resolve_promise(p, --[[: any]] value)
	return p
end

--- Create an already-rejected promise.
--: (reason: unknown) -> Promise
function M.reject(reason)
	local p = make_promise()
	reject_promise(p, --[[: any]] reason)
	return p
end

---------------------------------------------------------------------------
-- Combinators
---------------------------------------------------------------------------

--- Resolves when all promises resolve; rejects on first rejection.
--: (promises: {Promise}) -> Promise
function M.all(promises)
	if #promises == 0 then return M.resolve({}) end
	return M.new(function(resolve, reject)
		local results = {}
		local remaining = #promises
		local rejected = false
		for i = 1, #promises do
			promises[i]:and_then(function(value)
				if rejected then return end
				results[i] = value
				remaining = remaining - 1
				if remaining == 0 then
					resolve(results)
				end
			end):catch(function(reason)
				if rejected then return end
				rejected = true
				reject(reason)
			end)
		end
	end)
end

--- Resolves or rejects with the first settled promise.
--: (promises: {Promise}) -> Promise
function M.race(promises)
	if #promises == 0 then return M.new(function() end) end
	return M.new(function(resolve, reject)
		local settled = false
		for i = 1, #promises do
			promises[i]:and_then(function(value)
				if settled then return end
				settled = true
				resolve(value)
			end):catch(function(reason)
				if settled then return end
				settled = true
				reject(reason)
			end)
		end
	end)
end

--- Always resolves with an array of {status, value/reason} for each promise.
--: (promises: {Promise}) -> Promise
function M.all_settled(promises)
	if #promises == 0 then return M.resolve({}) end
	return M.new(function(resolve)
		local results = {}
		local remaining = #promises
		for i = 1, #promises do
			promises[i]:and_then(function(value)
				results[i] = { status = STATE_FULFILLED, value = value }
				remaining = remaining - 1
				if remaining == 0 then resolve(results) end
			end):catch(function(reason)
				results[i] = { status = STATE_REJECTED, reason = reason }
				remaining = remaining - 1
				if remaining == 0 then resolve(results) end
			end)
		end
	end)
end

--- Resolves with the first fulfilled value; rejects if all reject.
--: (promises: {Promise}) -> Promise
function M.any(promises)
	if #promises == 0 then return M.reject("All promises were rejected") end
	return M.new(function(resolve, reject)
		local errors = {}
		local remaining = #promises
		local fulfilled = false
		for i = 1, #promises do
			promises[i]:and_then(function(value)
				if fulfilled then return end
				fulfilled = true
				resolve(value)
			end):catch(function(reason)
				if fulfilled then return end
				errors[i] = reason
				remaining = remaining - 1
				if remaining == 0 then
					reject(errors)
				end
			end)
		end
	end)
end

return M
