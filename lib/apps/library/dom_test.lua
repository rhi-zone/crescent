-- lib/apps/library/dom_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local R = require("lib.reactive")

-- ── Mock DOM ─────────────────────────────────────────────────────────────────
-- Minimal mock of the browser document API, sufficient for reactive_dom/widget.

local function mock_node(tag)
	local node = {
		tagName = tag,
		_attrs = {},
		_children = {},
		_listeners = {},
		parentNode = nil,
		style = {},
	}
	function node.setAttribute(k, v) node._attrs[k] = v end
	function node.getAttribute(k) return node._attrs[k] end
	function node.appendChild(child)
		node._children[#node._children + 1] = child
		child.parentNode = node
		return child
	end
	function node.removeChild(child)
		for i = 1, #node._children do
			if node._children[i] == child then
				table.remove(node._children, i)
				child.parentNode = nil
				return child
			end
		end
	end
	node.firstChild = nil  -- updated lazily via __index below
	function node.addEventListener(event, handler)
		if not node._listeners[event] then node._listeners[event] = {} end
		node._listeners[event][#node._listeners[event] + 1] = handler
	end
	function node.removeEventListener(event, handler)
		local list = node._listeners[event]
		if not list then return end
		for i = 1, #list do
			if list[i] == handler then
				table.remove(list, i)
				return
			end
		end
	end
	-- Simulate firing an event (for testing)
	function node._fire(event)
		local list = node._listeners[event]
		if list then
			for i = 1, #list do list[i]() end
		end
	end
	-- textContent: settable property
	node.textContent = ""
	-- value: settable property (for input elements)
	node.value = ""
	-- data: settable property (for text nodes)
	node.data = ""
	return node
end

-- Install global document mock
document = {
	createElement = function(tag) return mock_node(tag) end,
	createTextNode = function(text)
		local n = mock_node("#text")
		n.data = text
		n.textContent = text
		return n
	end,
	createElementNS = function(_ns, tag) return mock_node(tag) end,
}

-- Now require DOM module (needs document global)
local dom_lib = require("lib.apps.library.dom")

-- ── Helper ───────────────────────────────────────────────────────────────────

local function make_test_items()
	return {
		{
			id = "calc",
			metadata = { name = "Calculator", category = "utility" },
			open = function() end,
		},
		{
			id = "notes",
			metadata = { name = "Notes", category = "productivity" },
			open = function() end,
		},
		{
			id = "player",
			metadata = { name = "Music Player", category = "media" },
			open = function() end,
		},
	}
end

-- ── Tests: module loads ──────────────────────────────────────────────────────

T.describe("dom module", function()
	T.it("loads and exports create and mount", function()
		T.ok(dom_lib.create)
		T.ok(dom_lib.mount)
	end)
end)

-- ── Tests: create / state model ──────────────────────────────────────────────

T.describe("dom.create state model", function()
	T.it("creates app with default state", function()
		local app = dom_lib.create()
		T.eq(app.search_query.get(), "")
		T.eq(app.view_mode.get(), "grid")
		T.eq(#app.filtered.get(), 0)
	end)

	T.it("accepts initial items via opts", function()
		local items = make_test_items()
		local app = dom_lib.create({ items = items })
		T.eq(#app.filtered.get(), 3)
	end)

	T.it("accepts initial view_mode via opts", function()
		local app = dom_lib.create({ view_mode = "list" })
		T.eq(app.view_mode.get(), "list")
	end)

	T.it("set_items updates items signal", function()
		local app = dom_lib.create()
		T.eq(#app.filtered.get(), 0)
		app.set_items(make_test_items())
		T.eq(#app.filtered.get(), 3)
	end)
end)

-- ── Tests: filtering ─────────────────────────────────────────────────────────

T.describe("dom.create filtering", function()
	T.it("filters by search query on metadata name", function()
		local app = dom_lib.create({ items = make_test_items() })
		app.search_query.set("calc")
		local f = app.filtered.get()
		T.eq(#f, 1)
		T.eq(f[1].id, "calc")
	end)

	T.it("filters by search query on metadata category", function()
		local app = dom_lib.create({ items = make_test_items() })
		app.search_query.set("media")
		local f = app.filtered.get()
		T.eq(#f, 1)
		T.eq(f[1].id, "player")
	end)

	T.it("filters by item id", function()
		local app = dom_lib.create({ items = make_test_items() })
		app.search_query.set("notes")
		local f = app.filtered.get()
		T.eq(#f, 1)
		T.eq(f[1].id, "notes")
	end)

	T.it("empty query returns all items", function()
		local app = dom_lib.create({ items = make_test_items() })
		app.search_query.set("x")
		app.search_query.set("")
		T.eq(#app.filtered.get(), 3)
	end)

	T.it("search is case-insensitive", function()
		local app = dom_lib.create({ items = make_test_items() })
		app.search_query.set("CALCULATOR")
		T.eq(#app.filtered.get(), 1)
	end)

	T.it("no matches returns empty", function()
		local app = dom_lib.create({ items = make_test_items() })
		app.search_query.set("zzzzz")
		T.eq(#app.filtered.get(), 0)
	end)
end)

-- ── Tests: view mode ─────────────────────────────────────────────────────────

T.describe("dom.create view mode", function()
	T.it("toggles between grid and list", function()
		local app = dom_lib.create()
		T.eq(app.view_mode.get(), "grid")
		app.view_mode.set("list")
		T.eq(app.view_mode.get(), "list")
		app.view_mode.set("grid")
		T.eq(app.view_mode.get(), "grid")
	end)
end)

-- ── Tests: widget rendering ──────────────────────────────────────────────────

T.describe("dom.create widget_fn", function()
	T.it("produces a DOM node", function()
		local app = dom_lib.create({ items = make_test_items() })
		local widget = require("lib.widget")
		local node, cleanup = widget.with_scope(function()
			return app.widget_fn(R.signal(nil))
		end)
		T.ok(node)
		T.eq(node.tagName, "div")
		T.ok(node._attrs.class:find("library"))
		cleanup()
	end)

	T.it("contains search input", function()
		local app = dom_lib.create({ items = make_test_items() })
		local widget = require("lib.widget")
		local node, cleanup = widget.with_scope(function()
			return app.widget_fn(R.signal(nil))
		end)
		-- First child is search bar div, which contains an input
		local search_bar = node._children[1]
		T.ok(search_bar)
		T.eq(search_bar._attrs.class, "library-search")
		local input = search_bar._children[1]
		T.ok(input)
		T.eq(input._attrs.type, "text")
		cleanup()
	end)

	T.it("contains view toggle button", function()
		local app = dom_lib.create({ items = make_test_items() })
		local widget = require("lib.widget")
		local node, cleanup = widget.with_scope(function()
			return app.widget_fn(R.signal(nil))
		end)
		-- Second child is controls div with toggle button
		local controls = node._children[2]
		T.ok(controls)
		T.eq(controls._attrs.class, "library-controls")
		local btn = controls._children[1]
		T.ok(btn)
		T.eq(btn.textContent, "List")  -- default is grid, so button says "List"
		cleanup()
	end)

	T.it("shows item count", function()
		local app = dom_lib.create({ items = make_test_items() })
		local widget = require("lib.widget")
		local node, cleanup = widget.with_scope(function()
			return app.widget_fn(R.signal(nil))
		end)
		-- Third child is count div
		local count_el = node._children[3]
		T.ok(count_el)
		T.eq(count_el._attrs.class, "library-count")
		T.eq(count_el.textContent, "3 items")
		cleanup()
	end)

	T.it("updates item count on search", function()
		local app = dom_lib.create({ items = make_test_items() })
		local widget = require("lib.widget")
		local node, cleanup = widget.with_scope(function()
			return app.widget_fn(R.signal(nil))
		end)
		local count_el = node._children[3]
		T.eq(count_el.textContent, "3 items")
		app.search_query.set("calc")
		T.eq(count_el.textContent, "1 items")
		cleanup()
	end)

	T.it("updates class on view mode change", function()
		local app = dom_lib.create({ items = make_test_items() })
		local widget = require("lib.widget")
		local node, cleanup = widget.with_scope(function()
			return app.widget_fn(R.signal(nil))
		end)
		T.eq(node._attrs.class, "library library-grid")
		app.view_mode.set("list")
		T.eq(node._attrs.class, "library library-list")
		cleanup()
	end)
end)

-- ── Tests: mount convenience ─────────────────────────────────────────────────

T.describe("dom.mount", function()
	T.it("mounts into container and returns cleanup + app", function()
		local container = mock_node("div")
		local cleanup, app = dom_lib.mount(container, { items = make_test_items() })
		T.ok(cleanup)
		T.ok(app)
		T.eq(#container._children, 1)
		T.eq(container._children[1].tagName, "div")
		cleanup()
	end)
end)

-- ── Tests: adapter integration ───────────────────────────────────────────────

T.describe("dom + adapter integration", function()
	T.it("loads items from adapter into app", function()
		local adapter = require("lib.apps.library.adapter")
		local src = adapter.static(make_test_items())
		local app = dom_lib.create()
		app.set_items(src.list())
		T.eq(#app.filtered.get(), 3)
	end)

	T.it("adapter search and app search produce consistent results", function()
		local adapter = require("lib.apps.library.adapter")
		local items = make_test_items()
		local src = adapter.static(items)
		local app = dom_lib.create({ items = items })

		-- Search via adapter
		local adapter_results = src.search("calc")

		-- Search via app
		app.search_query.set("calc")
		local app_results = app.filtered.get()

		T.eq(#adapter_results, #app_results)
		T.eq(adapter_results[1].id, app_results[1].id)
	end)

	T.it("composite adapter feeds into app", function()
		local adapter = require("lib.apps.library.adapter")
		local src1 = adapter.static({
			{ id = "a", metadata = { name = "Alpha" }, open = function() end },
		})
		local src2 = adapter.static({
			{ id = "b", metadata = { name = "Beta" }, open = function() end },
		})
		local comp = adapter.composite({ src1, src2 })
		local app = dom_lib.create()
		app.set_items(comp.list())
		T.eq(#app.filtered.get(), 2)
	end)
end)
