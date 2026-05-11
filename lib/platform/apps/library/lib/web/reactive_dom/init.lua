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

--:: require "lib.web.js_types"
--:: declare document = Document

--:: require "lib.reactive"

--:: EventHandler = (ev: AnyEvent) -> ()
--:: AttrMap = { [string]: (unknown) -> string }
--:: CleanupArray = { [integer]: () -> () }
--:: KeyEntry = { node: Node, cleanup: () -> (), sig: Signal<unknown> }
--:: KeyMap = { [string]: KeyEntry }
--:: ListSignal = { get: () -> { [integer]: unknown }, set: (unknown) -> (), update: ((unknown) -> unknown) -> (), subscribe: ((unknown) -> ()) -> (() -> ()), focus: (Lens) -> Focused<unknown>, narrow: (Prism) -> Narrowed<unknown> }

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local widget = require("lib.widget")
local R      = require("lib.reactive")
local Lens   = require("lib.fp.optics.lens")

-- Hoist typed references to R functions to avoid unknown-indexed-module errors.
-- Preceding-line annotations assert the type without requiring RHS to be typed.
--: (unknown) -> Signal<unknown>
local R_signal   = R.signal
--: (Signal<unknown>, Lens) -> Focused<unknown>
local R_focused  = R.focused
--: (() -> unknown, { [integer]: unknown }) -> Computed<unknown>
local R_computed = R.computed

local M = {}

-- ── element ───────────────────────────────────────────────────────────────────

-- element(tag, attrs, children) -> Widget
-- tag:      string — HTML tag name (e.g. "div", "span")
-- attrs:    { [string]: (value) -> string } — reactive attribute bindings.
--           Each value is a function that maps the signal value to an attribute
--           string. Subscribe to signal, call fn, set attribute on change.
-- children: array of Widget or string (static text nodes)
-- Returns a Widget: (signal) -> Element
function M.element(tag, attrs_raw, children_raw)
	local attrs    = (attrs_raw    or {}) --: AttrMap
	local children = (children_raw or {}) --: { [integer]: string | ((unknown) -> Node) }
	return function(signal_raw)
		local signal = signal_raw --: Signal<unknown>
		local el = document.createElement(tag) --: HTMLElement
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
				local child_str = child --: string
				local tn = document.createTextNode(child_str)
				el.appendChild(tn)
			else
				-- child is a Widget: call it with the same signal
				local child_fn = child --: (unknown) -> Node
				local child_node = child_fn(signal)
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
function M.text(f_raw)
	local f = f_raw --: (unknown) -> string
	return function(signal_raw)
		local signal = signal_raw --: Signal<unknown>
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
function M.on(el_raw, event_raw, handler_raw)
	local el = el_raw --: Element
	local event = event_raw --: string
	local handler = handler_raw --: EventHandler
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
function M.bind_input(el_raw, signal_raw)
	local el = el_raw --: HTMLInputElement
	local sig = signal_raw --: Signal<unknown>
	widget.subscribe_now(signal_raw, function(v)
		el.value = tostring(v)
	end)
	local function on_input(_ev)
		_ev = _ev --: AnyEvent
		sig.set(el.value)
	end
	local el_elem = el_raw --: Element
	M.on(el_elem, "input", on_input)
end

-- bind_checkbox(el, signal) -> void
-- Two-way binding between a checkbox's checked state and a boolean signal.
-- Signal → DOM: subscribe_now sets el.checked.
-- DOM → Signal: "change" event sets signal.set(el.checked).
-- Must be called inside a with_scope context.
function M.bind_checkbox(el_raw, signal_raw)
	local sig = signal_raw --: Signal<unknown>
	-- The subscribe_now handler uses el_raw directly (untyped) to avoid
	-- the typechecker inferring handler type from HTMLInputElement.checked: boolean.
	widget.subscribe_now(signal_raw, function(v)
		el_raw.checked = v
	end)
	local el = el_raw --: HTMLInputElement
	local function on_change(_ev)
		_ev = _ev --: AnyEvent
		sig.set(el.checked)
	end
	local el_elem = el_raw --: Element
	M.on(el_elem, "change", on_change)
end

-- ── mount ─────────────────────────────────────────────────────────────────────

-- mount(widget_fn, signal, container) -> cleanup_fn
-- Bootstrap: run widget in a scope, append produced node to container.
-- Returns a cleanup function that removes the node and unsubscribes everything.
function M.mount(widget_fn, signal, container_raw)
	local container = container_raw --: Element
	-- widget_fn and signal are intentionally untyped here: calling a typed
	-- function inside with_scope causes the checker to mistype the cleanup
	-- return. Use raw params inside the closure.
	local node, cleanup = widget.with_scope(function()
		return widget_fn(signal)
	end)
	--: Node
	local mount_node = node
	--: () -> ()
	local mount_cleanup = cleanup
	container.appendChild(mount_node)
	return function()
		-- Remove node from container if possible
		--: Node | nil
		local parent = mount_node.parentNode
		if parent then
			parent.removeChild(mount_node)
		end
		mount_cleanup()
	end
end

-- ── Layout combinators ────────────────────────────────────────────────────────

-- beside(w1, w2) -> Widget
-- Render w1 and w2 side by side inside a div[data-beside].
-- Both widgets receive the same signal value.
-- beside(w1, w2): both widgets are intentionally untyped in closures;
-- typing them causes widget.with_scope to mistype cleanup (checker bug).
function M.beside(w1, w2)
	return function(signal)
		local node = document.createElement("div")
		node.setAttribute("data-beside", "")
		local n1, c1 = widget.with_scope(function() return w1(signal) end)
		local n2, c2 = widget.with_scope(function() return w2(signal) end)
		local nn1 = n1 --: Node
		local nn2 = n2 --: Node
		local cleanup1 = c1 --: () -> ()
		local cleanup2 = c2 --: () -> ()
		node.appendChild(nn1)
		node.appendChild(nn2)
		widget.register(cleanup1)
		widget.register(cleanup2)
		return node
	end
end

-- above(w1, w2) -> Widget
-- Render w1 above w2 inside a div[data-above].
-- Both widgets receive the same signal value.
-- above(w1, w2): both widgets are intentionally untyped in closures;
-- typing them causes widget.with_scope to mistype cleanup (checker bug).
function M.above(w1, w2)
	return function(signal)
		local node = document.createElement("div")
		node.setAttribute("data-above", "")
		local n1, c1 = widget.with_scope(function() return w1(signal) end)
		local n2, c2 = widget.with_scope(function() return w2(signal) end)
		local nn1 = n1 --: Node
		local nn2 = n2 --: Node
		local cleanup1 = c1 --: () -> ()
		local cleanup2 = c2 --: () -> ()
		node.appendChild(nn1)
		node.appendChild(nn2)
		widget.register(cleanup1)
		widget.register(cleanup2)
		return node
	end
end

-- stack(widgets) -> Widget
-- Render N widgets all receiving the same signal, appended to a div[data-stack].
-- stack: widgets intentionally untyped in closure (typed fn in with_scope
-- causes checker to mistype cleanup return).
function M.stack(widgets)
	return function(signal)
		local node = document.createElement("div")
		node.setAttribute("data-stack", "")
		for i = 1, #widgets do
			local n, c = widget.with_scope(function() return widgets[i](signal) end)
			local nn = n --: Node
			local cleanup = c --: () -> ()
			node.appendChild(nn)
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
	item_widget = item_widget --: (Signal<unknown>) -> Node
	get_key = get_key --: ((unknown) -> string) | nil
	return function(list_signal_raw)
		local list_signal = list_signal_raw --: ListSignal
		local node = document.createElement("div")
		node.setAttribute("data-each", "")

		-- item_cleanups: array of cleanup fns, parallel to rendered items.
		local item_cleanups = {} --: CleanupArray

		local function teardown_all()
			for i = 1, #item_cleanups do
				item_cleanups[i]()
			end
			item_cleanups = {} --: CleanupArray
		end

		-- Remove all DOM children from node.
		local function clear_children()
			while node.firstChild do
				node.removeChild(node.firstChild)
			end
		end

		local function render_all(items_raw)
			--: { [integer]: unknown }
			local items = items_raw
			teardown_all()
			clear_children()
			for i = 1, #items do
				local idx = i
				-- Index lens: focus list signal on element at position idx.
				-- type(s_raw)=="table" narrows unknown→table so #s_raw and s_raw[k] work.
				--: Lens
				local item_lens = Lens.new(
					function(s_raw)
						if type(s_raw) == "table" then return s_raw[idx] end
						return nil
					end,
					function(s_raw, v)
						if type(s_raw) == "table" then
							local copy = {}
							for j = 1, #s_raw do copy[j] = s_raw[j] end
							copy[idx] = v
							return copy
						end
						return s_raw
					end
				)
				local item_sig = R_focused(list_signal, item_lens)
				local child_node, cleanup = widget.with_scope(function()
					return item_widget(item_sig)
				end)
				child_node = child_node --: Node
				cleanup = cleanup --: () -> ()
				item_cleanups[#item_cleanups + 1] = cleanup
				node.appendChild(child_node)
			end
		end

		if get_key then
			-- Keyed mode: each item has an independent R.signal so its index
			-- never becomes stale on reorder or removal.
			-- key_map: key -> { node, cleanup, sig } where sig is R.signal(item)
			local _get_key = get_key --: (unknown) -> string
			local key_map = {} --: KeyMap
			local prev_keys = {} --: { [integer]: string }

			local function keyed_teardown()
				for k, entry in pairs(key_map) do
					entry = entry --: KeyEntry
					entry.cleanup()
					rawset(key_map, k, nil)
				end
				prev_keys = {} --: { [integer]: string }
				item_cleanups = {} --: CleanupArray
				clear_children()
			end

			local function render_keyed(items_raw)
				--: { [integer]: unknown }
				local items = items_raw
				local new_keys = {} --: { [integer]: string }
				local new_key_set = {} --: { [string]: boolean }
				for i = 1, #items do
					local k = _get_key(items[i])
					new_keys[i] = k
					new_key_set[k] = true
				end

				-- Tear down removed keys
				for _, k in ipairs(prev_keys) do
					if not new_key_set[k] then
						local entry = key_map[k]
						if entry then
							entry = entry --: KeyEntry
							entry.cleanup()
							rawset(key_map, k, nil)
						end
					end
				end

				-- Rebuild DOM in new order; create or update each item
				clear_children()
				local new_cleanups = {} --: CleanupArray
				local new_prev = {} --: { [integer]: string }
				for i = 1, #items do
					local k = new_keys[i]
					new_prev[#new_prev + 1] = k
					local entry = key_map[k]
					if entry then
						-- Existing key: update its signal value, re-append node
						entry = entry --: KeyEntry
						entry.sig.set(items[i])
						node.appendChild(entry.node)
						new_cleanups[#new_cleanups + 1] = entry.cleanup
					else
						-- New key: create independent signal and render widget
						local item_sig = R_signal(items[i])
						local child_node, cleanup = widget.with_scope(function()
							return item_widget(item_sig)
						end)
						child_node = child_node --: Node
						cleanup = cleanup --: () -> ()
						node.appendChild(child_node)
						new_cleanups[#new_cleanups + 1] = cleanup
						key_map[k] = { node = child_node, cleanup = cleanup, sig = item_sig }
					end
				end
				item_cleanups = new_cleanups
				prev_keys = new_prev
			end

			-- Initial render
			render_keyed(list_signal.get())

			local unsub = list_signal.subscribe(function(_v)
				render_keyed(list_signal.get())
			end)
			widget.register(((unsub --[[: unknown]]) --[[:! () -> ()]])) 
			widget.register(keyed_teardown)
		else
			-- Unkeyed: re-render on length change only
			render_all(list_signal.get())

			--: Computed<unknown>
			local len_computed = R_computed(function()
				return #list_signal.get()
			end, { list_signal })
			local unsub = len_computed.subscribe(function(_v)
				render_all(list_signal.get())
			end)
			widget.register(((unsub --[[: unknown]]) --[[:! () -> ()]])) 
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
function M.show(inner_widget, predicate_raw)
	local predicate = predicate_raw --: (unknown) -> boolean
	return function(signal_raw)
		local signal = signal_raw --: Signal<unknown>
		local wrapper = document.createElement("div")
		wrapper.setAttribute("data-show", "")

		local child_node, cleanup = widget.with_scope(function()
			return inner_widget(signal_raw)
		end)
		local show_node = child_node --: Node
		local show_cleanup = cleanup --: () -> ()
		wrapper.appendChild(show_node)
		widget.register(show_cleanup)

		-- Apply initial visibility
		--: (unknown) -> ()
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
		widget.register(((unsub --[[: unknown]]) --[[:! () -> ()]])) 

		return wrapper
	end
end

-- ── Re-exports from widget layer ──────────────────────────────────────────────

M.focus   = widget.focus
M.narrow  = widget.narrow
M.dynamic = widget.dynamic

return M
