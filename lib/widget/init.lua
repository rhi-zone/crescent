-- lib/widget/init.lua
-- Platform-agnostic reactive widget layer.
--
-- A Widget is a plain function (signal) -> node where node is whatever
-- the renderer produces. This library manages:
--   1. Cleanup context  — tracking subscriptions and teardown functions
--   2. State combinators — pairing local state with external signals
--   3. Subscription helpers — common patterns on top of lib.reactive
--
-- Does not depend on any DOM or TUI renderer.
-- Depends on: lib.reactive, lib.fp.optics.lens, lib.fp.optics.prism, lib.fp.maybe
--:: require "lib.reactive"

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local R     = require("lib.reactive")
local Maybe = require("lib.fp.maybe")

local M = {}

-- ── Cleanup context ───────────────────────────────────────────────────────────

-- Module-level scope stack. Each entry is an array of cleanup callbacks.
-- with_scope pushes; the returned cleanup fn pops (already popped at fn exit).
--:: CleanupFn = () -> ()
--:: ScopeCallbacks = { [integer]: CleanupFn }
--: { [integer]: ScopeCallbacks }
local _scope_stack = {}

-- with_scope(fn) -> result, cleanup_fn
-- Run fn in a tracked cleanup context. Returns fn's result plus a single
-- cleanup() function that fires all registered teardown callbacks in reverse
-- order. Cleanup is safe to call multiple times (no-ops after first call).
function M.with_scope(fn)
	local callbacks = {} --: ScopeCallbacks
	_scope_stack[#_scope_stack + 1] = callbacks

	local ok, result = pcall(fn)

	-- Pop regardless of success/failure.
	table.remove(_scope_stack)

	if not ok then
		-- Still build a cleanup function for any callbacks registered before error.
		local function cleanup()
			for i = #callbacks, 1, -1 do
				callbacks[i]()
			end
		end
		cleanup()
		error(result, 2)
	end

	local cleaned = false
	local function cleanup()
		if cleaned then return end
		cleaned = true
		for i = #callbacks, 1, -1 do
			callbacks[i]()
		end
	end

	return result, cleanup
end

-- register(fn) -> void
-- Register a cleanup callback in the current active scope.
-- Errors if called outside a scope.
function M.register(fn)
	local top = _scope_stack[#_scope_stack]
	if not top then
		error("register: called outside a with_scope context", 2)
	end
	top[#top + 1] = fn
end

-- ── Subscription helpers ──────────────────────────────────────────────────────

-- subscribe_now(signal, handler) -> ()
-- Call handler immediately with signal's current value, then subscribe for
-- future changes. Registers the unsubscribe function in the current scope.
-- Must be called inside a with_scope context.
function M.subscribe_now(signal_raw, handler_raw)
	local signal = signal_raw --: Signal<unknown>
	local handler = handler_raw --: (unknown) -> ()
	handler(signal.get())
	local unsub = signal.subscribe(handler)
	M.register(unsub)
end

-- ── State combinators ─────────────────────────────────────────────────────────

-- dynamic(init_state, widget) -> Widget
-- Pairs local state S with external signal A.
-- The child widget receives a signal whose value is {state=S, value=A}.
-- Local state changes do not propagate to the parent signal.
-- Returns a Widget (function) that manages the local state signal internally.
--
-- The returned widget, when called with an external signal, creates a local
-- state signal, builds a combined computed signal, and calls the child widget
-- with that combined signal. It runs inside the caller's active scope (if any);
-- the child widget's cleanup is registered into whatever scope is active.
--
--:: Widget = (signal: unknown) -> unknown
function M.dynamic(init_state, widget)
	return function(signal)
		local state_sig = R.signal(init_state)
		local state_sig_ = state_sig --[[: any]]

		-- Combined signal: {state=S, value=A}
		local combined = R.computed(function()
			return { state = state_sig_.get(), value = signal.get() }
		end, { state_sig, signal })

		-- Expose state setter on the combined signal so child can update state.
		-- The child receives a signal with the combined value; they can call
		-- combined.set_state(new_state) to update local state.
		--
		-- We wrap combined to add the set_state convenience.
		local wrapped = {}
		wrapped.get       = combined.get
		wrapped.subscribe = combined.subscribe
		wrapped.focus     = combined.focus
		wrapped.narrow    = combined.narrow
		-- set_state(s): update only the local state portion
		wrapped.set_state = function(s) state_sig_.set(s) end
		-- update_state(f): apply f to current local state
		wrapped.update_state = function(f) state_sig_.update(f) end
		-- dispose the computed when scope exits
		M.register(function() combined.dispose() end)

		return widget(wrapped)
	end
end

-- show(widget, predicate) -> Widget
-- Returns a widget that calls the inner widget once and hides/shows the node
-- based on predicate(value). "Hide" means returning nil vs the node — the
-- renderer decides what to do with nil. The inner widget stays mounted
-- (subscriptions active).
function M.show(widget, predicate)
	return function(signal_raw)
		local signal = signal_raw --: Signal<unknown>
		-- Mount the child widget unconditionally.
		local node = widget(signal)

		-- Subscribe to signal changes to track visibility.
		-- We return a visibility-wrapped node: a table with the node and a
		-- visible signal so the renderer can react to predicate changes.
		--: Signal<unknown>
		local visible = R.signal(predicate(signal.get()))

		local unsub = signal.subscribe(function(v)
			visible.set(predicate(v))
		end)
		M.register(unsub)

		-- Return a show_node: { node, visible }
		-- The renderer queries visible.get() to decide whether to render node.
		-- When visible is false, the renderer returns nil for the subtree.
		return { node = node, visible = visible }
	end
end

-- focus(widget, lens) -> Widget
-- Zoom a widget into a product field via lens. Requires lib.fp.optics.lens.
-- The child widget receives a read/write focused signal.
function M.focus(widget, lens)
	return function(signal)
		local focused = R.focused(signal, lens)
		return widget(focused)
	end
end

-- narrow(widget, prism) -> Widget
-- Conditional widget via prism. Returns a widget that passes the focused
-- signal to the child when the prism matches, nil otherwise.
-- When the prism does not match the current signal value, returns nil.
function M.narrow(widget, prism)
	return function(signal)
		local narrowed = R.narrowed(signal, prism)
		if narrowed.get() == nil then
			return nil
		end
		return widget(narrowed)
	end
end

return M
