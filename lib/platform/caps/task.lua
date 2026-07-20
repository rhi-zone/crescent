-- lib/platform/caps/task.lua
-- Task capability: spawn background coroutines on the daemon's event loop.
--
-- Factory:
--   M.task_cap(daemon_ctx) -> cap, revoke_fn
--
-- Cap API:
--   cap.spawn(fn) -> TaskHandle | nil, err
--
-- TaskHandle API:
--   handle.cancel()  -> true | nil, err   (cooperative cancellation)
--   handle.done()    -> boolean           (true if task finished or cancelled)
--
-- Spawned coroutines are driven by the shared event loop. Any async operation
-- (pty reads, ws recv, loop:sleep, etc.) called inside fn will yield properly.
-- Errors inside fn are caught and don't propagate to the event loop.
-- Revocation cancels all active tasks.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local async = require("lib.async")

local M = {}

--:: require "lib.platform.caps.cap_types"

-- task_cap(daemon_ctx) -> (TaskCap, () -> nil) | (nil, string)
--: (DaemonCtx) -> (TaskCap | nil, (() -> nil) | string | nil)
function M.task_cap(daemon_ctx)
	if not daemon_ctx then
		return nil, "task cap requires daemon_ctx"
	end

	local revoked = false
	local active_tasks = {} --: { [integer]: { cancel: () -> nil, promise: { _state: string, ... } } | nil }
	local task_count = 0

	--: (fn: () -> nil) -> (TaskHandle | nil, string | nil)
	local function spawn(fn)
		if revoked then return nil, "task: capability revoked" end
		if type(fn) ~= "function" then return nil, "task: fn must be a function" end

		local task_id = task_count + 1
		task_count = task_id

		local run = async.cancellable(fn)
		local promise_raw, cancel_fn_raw = run()
		local promise = promise_raw --[[: { _state: string, _on_fulfill: { [integer]: (unknown) -> unknown }, _on_reject: { [integer]: (unknown) -> unknown }, ... }]]
		local cancel_fn = cancel_fn_raw --[[: () -> nil]]

		active_tasks[task_id] = { cancel = cancel_fn, promise = promise }

		-- Clean up from active_tasks when the task settles (success, error,
		-- or cancellation).
		--: (unknown) -> nil
		local function cleanup() active_tasks[task_id] = nil end
		promise._on_fulfill[#promise._on_fulfill + 1] = cleanup
		promise._on_reject[#promise._on_reject + 1] = cleanup

		--: () -> (true | nil, string | nil)
		local function handle_cancel()
			cancel_fn()
			return true
		end

		--: () -> boolean
		local function handle_done()
			return promise._state ~= "pending"
		end

		--: TaskHandle
		local handle = {
			cancel = handle_cancel,
			done = handle_done,
		}

		return handle
	end

	--: TaskCap
	local cap = {
		_type = "task",
		spawn = spawn,
	}

	--: () -> nil
	local function revoke()
		revoked = true
		-- Cancel all active tasks. Iterate over a snapshot since cancel
		-- triggers cleanup which mutates active_tasks.
		local snapshot = {} --: { [integer]: { cancel: () -> nil, promise: { _state: string, ... } } }
		for k, v in pairs(active_tasks) do
			if v then snapshot[k] = v end
		end
		for _, entry in pairs(snapshot) do
			entry.cancel()
		end
	end

	return cap, revoke
end

return M
