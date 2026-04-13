-- lib/web/reactive_dom/init.lua
-- Reactive DOM widget library for browser execution (lua2ts target).
--
-- A Widget is a plain function (signal) -> node.
-- No metatables — plain closures only (lua2ts compatibility).
--
-- DOM updates happen reactively: subscribe_now effects keep attributes,
-- text content, and child lists in sync with signal values.
--
-- Depends on: lib.widget, lib.reactive, lib.fp.optics.lens
-- Runtime requirement: `document` global (browser / mock DOM in tests)

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local widget = require("lib.widget")
local R      = require("lib.reactive")
local Lens   = require("lib.fp.optics.lens")

local M = {}

-- ── element ───────────────────────────────────────────────────────────────────

-- element(tag, attrs, children) -> Widget
-- tag:      string — HTML tag name (e.g. "div", "span")
-- attrs:    { [string]: (value) -> string } — reactive attribute bindings.
--           Each value is a function that maps the signal value to an attribute
--           string. Subscribe to signal, call fn, set attribute on change.
-- children: array of Widget or string (static text nodes)
-- Returns a Widget: (signal) -> Element
function M.element(tag, attrs, children)
	attrs    = attrs    or {}
	children = children or {}
	return function(signal)
		local el = document.createElement(tag) --: Element
		-- Reactive attribute bindings
		for attr, fn in pairs(attrs) do
			widget.subscribe_now(signal, function(v)
				el.setAttribute(attr, fn(v))
			end)
		end
		-- Children
		for i = 1, #children do
			local child = children[i]
			if type(child) == "string" then
				local tn = document.createTextNode(child)
				el.appendChild(tn)
			else
				-- child is a Widget: call it with the same signal
				local child_node = child(signal)
				el.appendChild(child_node)
			end
		end
		return el
	end
end

-- ── text ──────────────────────────────────────────────────────────────────────

-- text(f) -> Widget
-- f: (value) -> string — reactive text content.
-- Creates a Text node; subscribes to signal to keep .data current.
-- Returns a Widget: (signal) -> Text
function M.text(f)
	return function(signal)
		local tn = document.createTextNode("")
		widget.subscribe_now(signal, function(v)
			tn.data = f(v)
		end)
		return tn
	end
end

-- ── on ────────────────────────────────────────────────────────────────────────

-- on(el, event, handler) -> void
-- Attach an event listener to el; registers removeEventListener in the current
-- widget scope so it is torn down on cleanup.
-- Must be called inside a with_scope context (i.e. during widget construction).
function M.on(el, event, handler)
	el.addEventListener(event, handler)
	widget.register(function()
		el.removeEventListener(event, handler)
	end)
end

-- ── bind_input ────────────────────────────────────────────────────────────────

-- bind_input(el, signal) -> void
-- Two-way binding between an <input> element's value and a signal.
-- Signal → DOM: subscribe_now sets el.value.
-- DOM → Signal: "input" event sets signal.set(el.value).
-- Must be called inside a with_scope context.
function M.bind_input(el, signal)
	widget.subscribe_now(signal, function(v)
		el.value = v
	end)
	local function on_input()
		signal.set(el.value)
	end
	M.on(el, "input", on_input)
end

-- bind_checkbox(el, signal) -> void
-- Two-way binding between a checkbox's checked state and a boolean signal.
-- Signal → DOM: subscribe_now sets el.checked.
-- DOM → Signal: "change" event sets signal.set(el.checked).
-- Must be called inside a with_scope context.
function M.bind_checkbox(el, signal)
	widget.subscribe_now(signal, function(v)
		el.checked = v
	end)
	local function on_change()
		signal.set(el.checked)
	end
	M.on(el, "change", on_change)
end

-- ── mount ─────────────────────────────────────────────────────────────────────

-- mount(widget_fn, signal, container) -> cleanup_fn
-- Bootstrap: run widget in a scope, append produced node to container.
-- Returns a cleanup function that removes the node and unsubscribes everything.
function M.mount(widget_fn, signal, container)
	local node, cleanup = widget.with_scope(function()
		return widget_fn(signal)
	end)
	container.appendChild(node)
	return function()
		-- Remove node from container if possible
		local parent = node.parentNode
		if parent then
			parent.removeChild(node)
		end
		cleanup()
	end
end

-- ── Layout combinators ────────────────────────────────────────────────────────

-- beside(w1, w2) -> Widget
-- Render w1 and w2 side by side inside a div[data-beside].
-- Both widgets receive the same signal value.
function M.beside(w1, w2)
	return function(signal)
		local node = document.createElement("div")
		node.setAttribute("data-beside", "")
		local n1, cleanup1 = widget.with_scope(function() return w1(signal) end)
		local n2, cleanup2 = widget.with_scope(function() return w2(signal) end)
		node.appendChild(n1)
		node.appendChild(n2)
		widget.register(cleanup1)
		widget.register(cleanup2)
		return node
	end
end

-- above(w1, w2) -> Widget
-- Render w1 above w2 inside a div[data-above].
-- Both widgets receive the same signal value.
function M.above(w1, w2)
	return function(signal)
		local node = document.createElement("div")
		node.setAttribute("data-above", "")
		local n1, cleanup1 = widget.with_scope(function() return w1(signal) end)
		local n2, cleanup2 = widget.with_scope(function() return w2(signal) end)
		node.appendChild(n1)
		node.appendChild(n2)
		widget.register(cleanup1)
		widget.register(cleanup2)
		return node
	end
end

-- stack(widgets) -> Widget
-- Render N widgets all receiving the same signal, appended to a div[data-stack].
function M.stack(widgets)
	return function(signal)
		local node = document.createElement("div")
		node.setAttribute("data-stack", "")
		for i = 1, #widgets do
			local n, cleanup = widget.with_scope(function() return widgets[i](signal) end)
			node.appendChild(n)
			widget.register(cleanup)
		end
		return node
	end
end

-- ── each ─────────────────────────────────────────────────────────────────────

-- each(item_widget, get_key?) -> Widget
-- List rendering. The signal value must be an array.
-- get_key: optional (item) -> string  — keyed diffing for stable updates.
--
-- Unkeyed: full re-render on length change; per-item value updates are handled
-- by focused index-lens signals (no teardown for same-length updates).
--
-- Keyed: each item gets its own independent signal (not an index lens).
-- On list change, items whose key disappears are torn down; new keys are
-- rendered fresh; existing keys have their signal updated in-place. This
-- preserves DOM nodes for stable keys across reorders and partial updates.
function M.each(item_widget, get_key)
	return function(list_signal)
		local node = document.createElement("div")
		node.setAttribute("data-each", "")

		-- item_cleanups: array of cleanup fns, parallel to rendered items.
		local item_cleanups = {}

		local function teardown_all()
			for i = 1, #item_cleanups do
				item_cleanups[i]()
			end
			item_cleanups = {}
		end

		-- Remove all DOM children from node.
		local function clear_children()
			while node.firstChild do
				node.removeChild(node.firstChild)
			end
		end

		local function render_all(items)
			teardown_all()
			clear_children()
			for i = 1, #items do
				local idx = i
				-- Index lens: focus list signal on element at position idx.
				local item_lens = Lens.new(
					function(arr) return arr[idx] end,
					function(arr, v)
						local copy = {}
						for j = 1, #arr do copy[j] = arr[j] end
						copy[idx] = v
						return copy
					end
				)
				local item_sig = R.focused(list_signal, item_lens)
				local child_node, cleanup = widget.with_scope(function()
					return item_widget(item_sig)
				end)
				item_cleanups[#item_cleanups + 1] = cleanup
				node.appendChild(child_node)
			end
		end

		if get_key then
			-- Keyed mode: each item has an independent R.signal so its index
			-- never becomes stale on reorder or removal.
			-- key_map: key -> { node, cleanup, sig } where sig is R.signal(item)
			local key_map = {}
			local prev_keys = {}

			local function keyed_teardown()
				for k, entry in pairs(key_map) do
					entry.cleanup()
					key_map[k] = nil
				end
				prev_keys = {}
				item_cleanups = {}
				clear_children()
			end

			local function render_keyed(items)
				local new_keys = {}
				local new_key_set = {}
				for i = 1, #items do
					local k = get_key(items[i])
					new_keys[i] = k
					new_key_set[k] = true
				end

				-- Tear down removed keys
				for _, k in ipairs(prev_keys) do
					if not new_key_set[k] then
						local entry = key_map[k]
						if entry then
							entry.cleanup()
							key_map[k] = nil
						end
					end
				end

				-- Rebuild DOM in new order; create or update each item
				clear_children()
				local new_cleanups = {}
				local new_prev = {}
				for i = 1, #items do
					local k = new_keys[i]
					new_prev[#new_prev + 1] = k
					local entry = key_map[k]
					if entry then
						-- Existing key: update its signal value, re-append node
						entry.sig.set(items[i])
						node.appendChild(entry.node)
						new_cleanups[#new_cleanups + 1] = entry.cleanup
					else
						-- New key: create independent signal and render widget
						local item_sig = R.signal(items[i])
						local child_node, cleanup = widget.with_scope(function()
							return item_widget(item_sig)
						end)
						node.appendChild(child_node)
						new_cleanups[#new_cleanups + 1] = cleanup
						key_map[k] = { node = child_node, cleanup = cleanup, sig = item_sig }
					end
				end
				item_cleanups = new_cleanups
				prev_keys = new_prev
			end

			-- Initial render
			local init = list_signal.get()
			render_keyed(init)

			local unsub = list_signal.subscribe(render_keyed)
			widget.register(unsub)
			widget.register(keyed_teardown)
		else
			-- Unkeyed: re-render on length change only
			render_all(list_signal.get())

			local len_computed = R.computed(function()
				return #list_signal.get()
			end, { list_signal })
			local unsub = len_computed.subscribe(function()
				render_all(list_signal.get())
			end)
			widget.register(unsub)
			widget.register(function() len_computed.dispose() end)
			widget.register(teardown_all)
		end

		return node
	end
end

-- ── show (DOM override) ───────────────────────────────────────────────────────

-- show(inner_widget, predicate) -> Widget
-- DOM-specific override of widget.show:
-- Calls inner_widget once; subscribes to predicate; toggles node.style.display.
-- The inner widget stays mounted; subscriptions remain active while hidden.
-- Returns a Widget that produces the wrapper div.
function M.show(inner_widget, predicate)
	return function(signal)
		local wrapper = document.createElement("div")
		wrapper.setAttribute("data-show", "")

		local child_node, cleanup = widget.with_scope(function()
			return inner_widget(signal)
		end)
		wrapper.appendChild(child_node)
		widget.register(cleanup)

		-- Apply initial visibility
		local function apply(v)
			if predicate(v) then
				wrapper.style.display = ""
			else
				wrapper.style.display = "none"
			end
		end
		apply(signal.get())

		-- Subscribe for future changes
		local unsub = signal.subscribe(apply)
		widget.register(unsub)

		return wrapper
	end
end

-- ── Re-exports from widget layer ──────────────────────────────────────────────

M.focus   = widget.focus
M.narrow  = widget.narrow
M.dynamic = widget.dynamic

return M
