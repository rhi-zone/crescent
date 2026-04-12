-- lib/web/reactive_dom/reactive_dom_test.lua
-- Tests for reactive DOM widget library using a minimal mock DOM.
--
-- Mock DOM: plain Lua tables with the same interface as the browser DOM:
--   createElement, createTextNode, Node.appendChild, Node.removeChild,
--   Node.setAttribute, Node.addEventListener, Node.removeEventListener,
--   Node.style, Node.parentNode linkage.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local R  = require("lib.reactive")

-- ── Mock DOM ──────────────────────────────────────────────────────────────────

-- Build a minimal mock document global.
-- We assign it to the global `document` so reactive_dom can find it at load
-- time without requiring it.

local function make_style()
	local style = {}
	style.display = ""
	return style
end

local function make_node(node_type, tag_or_data)
	local n = {}
	n.nodeType    = node_type  -- 1=Element, 3=Text
	n.tagName     = (node_type == 1) and tag_or_data or nil
	n.data        = (node_type == 3) and (tag_or_data or "") or nil
	n.children    = {}         -- ordered child array
	n.attributes  = {}         -- { [name] = value }
	n.listeners   = {}         -- { [event] = { [handler] = true } }
	n.style       = make_style()
	n.parentNode  = nil
	n.firstChild  = nil        -- updated by appendChild/removeChild

	local function _refresh_first()
		n.firstChild = n.children[1] or nil
	end

	function n.appendChild(child)
		n.children[#n.children + 1] = child
		child.parentNode = n
		_refresh_first()
		return child
	end

	function n.removeChild(child)
		for i = 1, #n.children do
			if n.children[i] == child then
				table.remove(n.children, i)
				child.parentNode = nil
				_refresh_first()
				return child
			end
		end
		error("removeChild: node not found")
	end

	function n.setAttribute(name, value)
		n.attributes[name] = value
	end

	function n.getAttribute(name)
		return n.attributes[name]
	end

	function n.addEventListener(event, handler)
		if not n.listeners[event] then n.listeners[event] = {} end
		n.listeners[event][handler] = true
	end

	function n.removeEventListener(event, handler)
		if n.listeners[event] then
			n.listeners[event][handler] = nil
		end
	end

	-- Helper: dispatch a synthetic event (used in tests)
	function n._dispatch(event)
		if n.listeners[event] then
			for h in pairs(n.listeners[event]) do h() end
		end
	end

	return n
end

local mock_document = {}
function mock_document.createElement(tag)
	return make_node(1, tag)
end
function mock_document.createTextNode(data)
	return make_node(3, data or "")
end

-- Install as global so reactive_dom can use it.
document = mock_document --: any

-- Now load the library (after document is set up).
local dom = require("lib.web.reactive_dom")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local widget = require("lib.widget")

-- Run a widget in a scope, return node + cleanup.
local function run(w, sig)
	return widget.with_scope(function()
		return w(sig)
	end)
end

-- ── Tests ─────────────────────────────────────────────────────────────────────

T.describe("reactive_dom.element", function()
	T.it("creates element with correct tag", function()
		local sig = R.signal("hello")
		local w = dom.element("span", {}, {})
		local node, cleanup = run(w, sig)
		T.eq(node.tagName, "span")
		cleanup()
	end)

	T.it("sets reactive attributes on mount", function()
		local sig = R.signal("world")
		local w = dom.element("div", {
			title = function(v) return "tip:" .. v end,
		}, {})
		local node, cleanup = run(w, sig)
		T.eq(node.attributes["title"], "tip:world")
		cleanup()
	end)

	T.it("updates attributes on signal change", function()
		local sig = R.signal("a")
		local w = dom.element("div", {
			["data-val"] = function(v) return v end,
		}, {})
		local node, cleanup = run(w, sig)
		T.eq(node.attributes["data-val"], "a")
		sig.set("b")
		T.eq(node.attributes["data-val"], "b")
		cleanup()
	end)

	T.it("appends static text child", function()
		local sig = R.signal(0)
		local w = dom.element("p", {}, { "hello" })
		local node, cleanup = run(w, sig)
		T.eq(#node.children, 1)
		T.eq(node.children[1].data, "hello")
		cleanup()
	end)

	T.it("appends widget children", function()
		local sig = R.signal("x")
		local inner = dom.element("em", {}, {})
		local w = dom.element("div", {}, { inner })
		local node, cleanup = run(w, sig)
		T.eq(#node.children, 1)
		T.eq(node.children[1].tagName, "em")
		cleanup()
	end)

	T.it("unsubscribes attributes on cleanup", function()
		local sig = R.signal("before")
		local w = dom.element("div", {
			id = function(v) return v end,
		}, {})
		local node, cleanup = run(w, sig)
		cleanup()
		sig.set("after")
		-- Attribute must NOT have been updated after cleanup
		T.eq(node.attributes["id"], "before")
	end)
end)

T.describe("reactive_dom.text", function()
	T.it("creates text node with initial value", function()
		local sig = R.signal(42)
		local w = dom.text(function(v) return tostring(v) end)
		local node, cleanup = run(w, sig)
		T.eq(node.data, "42")
		cleanup()
	end)

	T.it("updates text node on signal change", function()
		local sig = R.signal("foo")
		local w = dom.text(function(v) return v end)
		local node, cleanup = run(w, sig)
		T.eq(node.data, "foo")
		sig.set("bar")
		T.eq(node.data, "bar")
		cleanup()
	end)

	T.it("stops updating after cleanup", function()
		local sig = R.signal("initial")
		local w = dom.text(function(v) return v end)
		local node, cleanup = run(w, sig)
		cleanup()
		sig.set("changed")
		T.eq(node.data, "initial")
	end)
end)

T.describe("reactive_dom.on", function()
	T.it("attaches event listener", function()
		local sig = R.signal(0)
		local fired = 0
		local node, cleanup = widget.with_scope(function()
			local el = document.createElement("button")
			dom.on(el, "click", function() fired = fired + 1 end)
			return el
		end)
		node._dispatch("click")
		T.eq(fired, 1)
		cleanup()
	end)

	T.it("removes event listener on cleanup", function()
		local sig = R.signal(0)
		local fired = 0
		local node, cleanup = widget.with_scope(function()
			local el = document.createElement("button")
			dom.on(el, "click", function() fired = fired + 1 end)
			return el
		end)
		cleanup()
		node._dispatch("click")
		T.eq(fired, 0)
	end)
end)

T.describe("reactive_dom.bind_input", function()
	T.it("sets initial value from signal", function()
		local sig = R.signal("hello")
		local node, cleanup = widget.with_scope(function()
			local el = document.createElement("input")
			dom.bind_input(el, sig)
			return el
		end)
		T.eq(node.value, "hello")
		cleanup()
	end)

	T.it("updates el.value when signal changes", function()
		local sig = R.signal("a")
		local node, cleanup = widget.with_scope(function()
			local el = document.createElement("input")
			dom.bind_input(el, sig)
			return el
		end)
		sig.set("b")
		T.eq(node.value, "b")
		cleanup()
	end)

	T.it("updates signal when input event fires", function()
		local sig = R.signal("")
		local node, cleanup = widget.with_scope(function()
			local el = document.createElement("input")
			-- Simulate browser: el.value gets set by user; event fires
			dom.bind_input(el, sig)
			return el
		end)
		node.value = "typed"
		node._dispatch("input")
		T.eq(sig.get(), "typed")
		cleanup()
	end)
end)

T.describe("reactive_dom.bind_checkbox", function()
	T.it("sets initial checked from signal", function()
		local sig = R.signal(true)
		local node, cleanup = widget.with_scope(function()
			local el = document.createElement("input")
			dom.bind_checkbox(el, sig)
			return el
		end)
		T.eq(node.checked, true)
		cleanup()
	end)

	T.it("updates signal on change event", function()
		local sig = R.signal(false)
		local node, cleanup = widget.with_scope(function()
			local el = document.createElement("input")
			dom.bind_checkbox(el, sig)
			return el
		end)
		node.checked = true
		node._dispatch("change")
		T.eq(sig.get(), true)
		cleanup()
	end)
end)

T.describe("reactive_dom.mount", function()
	T.it("appends node to container", function()
		local container = document.createElement("div")
		local sig = R.signal("x")
		local w = dom.element("span", {}, {})
		local cleanup = dom.mount(w, sig, container)
		T.eq(#container.children, 1)
		T.eq(container.children[1].tagName, "span")
		cleanup()
	end)

	T.it("removes node from container on cleanup", function()
		local container = document.createElement("div")
		local sig = R.signal("x")
		local w = dom.element("span", {}, {})
		local cleanup = dom.mount(w, sig, container)
		T.eq(#container.children, 1)
		cleanup()
		T.eq(#container.children, 0)
	end)

	T.it("unsubscribes on cleanup", function()
		local container = document.createElement("div")
		local sig = R.signal("a")
		local w = dom.element("div", { id = function(v) return v end }, {})
		local cleanup = dom.mount(w, sig, container)
		local mounted_node = container.children[1]
		cleanup()
		sig.set("b")
		T.eq(mounted_node.attributes["id"], "a")  -- not updated after unmount
	end)
end)

T.describe("reactive_dom.beside", function()
	T.it("creates div with data-beside attribute", function()
		local sig = R.signal("v")
		local w1 = dom.element("span", {}, {})
		local w2 = dom.element("em", {}, {})
		local w = dom.beside(w1, w2)
		local node, cleanup = run(w, sig)
		T.eq(node.tagName, "div")
		T.eq(node.attributes["data-beside"], "")
		T.eq(#node.children, 2)
		cleanup()
	end)

	T.it("both children receive same signal", function()
		local sig = R.signal("hello")
		local vals = {}
		local function capture(n)
			return function(s) return dom.text(function(v) vals[n] = v; return v end)(s) end
		end
		local w = dom.beside(capture(1), capture(2))
		local node, cleanup = run(w, sig)
		T.eq(vals[1], "hello")
		T.eq(vals[2], "hello")
		cleanup()
	end)
end)

T.describe("reactive_dom.above", function()
	T.it("creates div with data-above attribute", function()
		local sig = R.signal(0)
		local w = dom.above(
			dom.element("h1", {}, {}),
			dom.element("p", {}, {})
		)
		local node, cleanup = run(w, sig)
		T.eq(node.attributes["data-above"], "")
		T.eq(node.children[1].tagName, "h1")
		T.eq(node.children[2].tagName, "p")
		cleanup()
	end)
end)

T.describe("reactive_dom.stack", function()
	T.it("renders N children inside div[data-stack]", function()
		local sig = R.signal(0)
		local ws = {
			dom.element("a", {}, {}),
			dom.element("b", {}, {}),
			dom.element("c", {}, {}),
		}
		local w = dom.stack(ws)
		local node, cleanup = run(w, sig)
		T.eq(node.attributes["data-stack"], "")
		T.eq(#node.children, 3)
		T.eq(node.children[1].tagName, "a")
		T.eq(node.children[3].tagName, "c")
		cleanup()
	end)
end)

T.describe("reactive_dom.each (unkeyed)", function()
	T.it("renders one child per item initially", function()
		local sig = R.signal({"a", "b", "c"})
		local w = dom.each(dom.text(function(v) return v end))
		local node, cleanup = run(w, sig)
		T.eq(#node.children, 3)
		cleanup()
	end)

	T.it("adds children when list grows", function()
		local sig = R.signal({"x"})
		local w = dom.each(dom.text(function(v) return v end))
		local node, cleanup = run(w, sig)
		T.eq(#node.children, 1)
		sig.set({"x", "y"})
		T.eq(#node.children, 2)
		cleanup()
	end)

	T.it("removes children when list shrinks", function()
		local sig = R.signal({"a", "b", "c"})
		local w = dom.each(dom.text(function(v) return v end))
		local node, cleanup = run(w, sig)
		T.eq(#node.children, 3)
		sig.set({"a"})
		T.eq(#node.children, 1)
		cleanup()
	end)

	T.it("updates item text reactively via focused signal", function()
		local sig = R.signal({"alpha", "beta"})
		local w = dom.each(dom.text(function(v) return v end))
		local node, cleanup = run(w, sig)
		-- Per-item update: change first element in-place (same length)
		sig.set({"ALPHA", "beta"})
		T.eq(node.children[1].data, "ALPHA")
		T.eq(node.children[2].data, "beta")
		cleanup()
	end)

	T.it("cleans up all item subscriptions on cleanup", function()
		local sig = R.signal({"a", "b"})
		local w = dom.each(dom.text(function(v) return v end))
		local node, cleanup = run(w, sig)
		local c1 = node.children[1]
		cleanup()
		sig.set({"changed", "b"})
		-- Node should NOT have been updated
		T.eq(c1.data, "a")
	end)
end)

T.describe("reactive_dom.each (keyed)", function()
	local function get_key(item) return item.id end

	T.it("renders items with keys", function()
		local sig = R.signal({
			{ id = "x", label = "X" },
			{ id = "y", label = "Y" },
		})
		local w = dom.each(
			dom.text(function(v) return v.label end),
			get_key
		)
		local node, cleanup = run(w, sig)
		T.eq(#node.children, 2)
		T.eq(node.children[1].data, "X")
		T.eq(node.children[2].data, "Y")
		cleanup()
	end)

	T.it("preserves node identity for stable keys on reorder", function()
		local sig = R.signal({
			{ id = "a", label = "A" },
			{ id = "b", label = "B" },
		})
		local w = dom.each(
			dom.text(function(v) return v.label end),
			get_key
		)
		local node, cleanup = run(w, sig)
		local node_a = node.children[1]
		-- Reverse order
		sig.set({
			{ id = "b", label = "B" },
			{ id = "a", label = "A" },
		})
		-- node_a (key "a") should still exist in children
		local found = false
		for i = 1, #node.children do
			if node.children[i] == node_a then found = true end
		end
		T.ok(found, "original node_a should be preserved")
		cleanup()
	end)

	T.it("removes nodes for deleted keys", function()
		local sig = R.signal({
			{ id = "1", label = "one" },
			{ id = "2", label = "two" },
			{ id = "3", label = "three" },
		})
		local w = dom.each(
			dom.text(function(v) return v.label end),
			get_key
		)
		local node, cleanup = run(w, sig)
		T.eq(#node.children, 3)
		sig.set({
			{ id = "1", label = "one" },
			{ id = "3", label = "three" },
		})
		T.eq(#node.children, 2)
		cleanup()
	end)

	T.it("adds nodes for new keys", function()
		local sig = R.signal({ { id = "a", label = "A" } })
		local w = dom.each(
			dom.text(function(v) return v.label end),
			get_key
		)
		local node, cleanup = run(w, sig)
		T.eq(#node.children, 1)
		sig.set({
			{ id = "a", label = "A" },
			{ id = "b", label = "B" },
		})
		T.eq(#node.children, 2)
		cleanup()
	end)
end)

T.describe("reactive_dom.show", function()
	T.it("shows element when predicate is true", function()
		local sig = R.signal(true)
		local w = dom.show(dom.element("div", {}, {}), function(v) return v end)
		local node, cleanup = run(w, sig)
		T.eq(node.style.display, "")
		cleanup()
	end)

	T.it("hides element when predicate is false", function()
		local sig = R.signal(false)
		local w = dom.show(dom.element("div", {}, {}), function(v) return v end)
		local node, cleanup = run(w, sig)
		T.eq(node.style.display, "none")
		cleanup()
	end)

	T.it("toggles visibility on signal change", function()
		local sig = R.signal(true)
		local w = dom.show(dom.element("div", {}, {}), function(v) return v end)
		local node, cleanup = run(w, sig)
		T.eq(node.style.display, "")
		sig.set(false)
		T.eq(node.style.display, "none")
		sig.set(true)
		T.eq(node.style.display, "")
		cleanup()
	end)

	T.it("inner widget stays subscribed while hidden", function()
		local sig = R.signal({ visible = true, text = "hello" })
		local captured = {}
		local inner = dom.text(function(v) captured[#captured+1] = v.text; return v.text end)
		local pred = function(v) return v.visible end
		local w = dom.show(inner, pred)
		local node, cleanup = run(w, sig)
		-- hide it
		sig.set({ visible = false, text = "world" })
		-- inner still updated despite being hidden
		T.eq(captured[#captured], "world")
		cleanup()
	end)

	T.it("stops toggling after cleanup", function()
		local sig = R.signal(true)
		local w = dom.show(dom.element("div", {}, {}), function(v) return v end)
		local node, cleanup = run(w, sig)
		cleanup()
		sig.set(false)
		-- Should still be "" because cleanup was called
		T.eq(node.style.display, "")
	end)
end)

T.describe("reactive_dom re-exports", function()
	T.it("exposes focus from widget layer", function()
		T.ok(type(dom.focus) == "function")
	end)
	T.it("exposes narrow from widget layer", function()
		T.ok(type(dom.narrow) == "function")
	end)
	T.it("exposes dynamic from widget layer", function()
		T.ok(type(dom.dynamic) == "function")
	end)
end)
