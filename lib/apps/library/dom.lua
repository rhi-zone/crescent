-- lib/apps/library/dom.lua
-- Library browser UI — searchable grid of items from adapters.
--
-- Entry point for the DOM renderer. Expects a `document` global (browser or mock).
-- Depends on: lib.reactive, lib.web.reactive_dom, lib.widget

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local R      = require("lib.reactive")
local dom    = require("lib.web.reactive_dom")
local widget = require("lib.widget")

local M = {}

-- ── Item widget ──────────────────────────────────────────────────────────────

-- Renders a single library item. Receives a signal whose value is an item
-- table { id, metadata, open }.
local function item_widget(item_signal)
	local el = document.createElement("div")
	el.setAttribute("class", "library-item")

	local name_el = document.createElement("div")
	name_el.setAttribute("class", "item-name")
	el.appendChild(name_el)

	local meta_el = document.createElement("div")
	meta_el.setAttribute("class", "item-meta")
	el.appendChild(meta_el)

	widget.subscribe_now(item_signal, function(item)
		if not item then return end
		name_el.textContent = item.metadata.name or item.id

		local parts = {}
		for k, v in pairs(item.metadata) do
			if k ~= "name" and type(v) == "string" then
				parts[#parts + 1] = k .. ": " .. v
			end
		end
		table.sort(parts)
		meta_el.textContent = table.concat(parts, " | ")
	end)

	return el
end

-- ── Main app widget ──────────────────────────────────────────────────────────

-- create(opts) -> app table
-- opts.items: initial items array (optional, default {})
-- opts.view_mode: initial view mode (optional, default "grid")
--
-- Returns:
--   set_items    — function(items) to load items from adapters
--   widget_fn    — the Widget function for dom.mount
--   search_query — the search query signal (for testing/external control)
--   view_mode    — the view mode signal (for testing/external control)
--   filtered     — the computed filtered items signal (for testing)
function M.create(opts)
	opts = opts or {}

	local search_query = R.signal("")
	local items = R.signal(opts.items or {})
	local view_mode = R.signal(opts.view_mode or "grid")

	-- Derived: filtered items based on search query
	local filtered = R.computed(function()
		local q = search_query.get():lower()
		local all = items.get()
		if q == "" then return all end
		local results = {}
		for _, item in ipairs(all) do
			-- Search id
			if item.id:lower():find(q, 1, true) then
				results[#results + 1] = item
			else
				-- Search metadata string values
				for _, v in pairs(item.metadata) do
					if type(v) == "string" and v:lower():find(q, 1, true) then
						results[#results + 1] = item
						break
					end
				end
			end
		end
		return results
	end, { search_query, items })

	-- Main widget function — builds the entire DOM tree
	local function widget_fn(_signal)
		local root = document.createElement("div")
		root.setAttribute("class", "library")

		-- Update root class when view mode changes
		widget.subscribe_now(view_mode, function(v)
			root.setAttribute("class", "library library-" .. v)
		end)

		-- Search bar
		local search_bar = document.createElement("div")
		search_bar.setAttribute("class", "library-search")
		local input = document.createElement("input")
		input.setAttribute("type", "text")
		input.setAttribute("placeholder", "Search...")
		input.setAttribute("class", "search-input")
		widget.subscribe_now(search_query, function(v)
			input.value = v
		end)
		dom.on(input, "input", function()
			search_query.set(input.value)
		end)
		search_bar.appendChild(input)
		root.appendChild(search_bar)

		-- Controls bar
		local controls = document.createElement("div")
		controls.setAttribute("class", "library-controls")
		local toggle_btn = document.createElement("button")
		toggle_btn.setAttribute("class", "view-toggle")
		widget.subscribe_now(view_mode, function(v)
			toggle_btn.textContent = v == "grid" and "List" or "Grid"
		end)
		dom.on(toggle_btn, "click", function()
			view_mode.update(function(v)
				return v == "grid" and "list" or "grid"
			end)
		end)
		controls.appendChild(toggle_btn)
		root.appendChild(controls)

		-- Item count
		local count_el = document.createElement("div")
		count_el.setAttribute("class", "library-count")
		widget.subscribe_now(filtered, function(list)
			count_el.textContent = tostring(#list) .. " items"
		end)
		root.appendChild(count_el)

		-- Item list — use dom.each with the filtered signal
		local list_widget = dom.each(item_widget)
		local list_node, list_cleanup = widget.with_scope(function()
			return list_widget(filtered)
		end)
		widget.register(list_cleanup)
		root.appendChild(list_node)

		return root
	end

	return {
		set_items = function(new_items) items.set(new_items) end,
		widget_fn = widget_fn,
		search_query = search_query,
		view_mode = view_mode,
		filtered = filtered,
	}
end

-- mount(container, opts) -> cleanup, app
-- Convenience: create the app and mount it into a DOM container.
function M.mount(container, opts)
	local app = M.create(opts)
	-- We pass a dummy signal since widget_fn ignores it
	local dummy = R.signal(nil)
	local cleanup = dom.mount(app.widget_fn, dummy, container)
	return cleanup, app
end

return M
