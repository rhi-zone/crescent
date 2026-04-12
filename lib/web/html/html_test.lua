-- lib/web/html/html_test.lua
-- Tests for the type-safe DOM element builder library.
-- Uses a minimal mock DOM (same pattern as reactive_dom_test.lua).

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")

-- ── Mock DOM ──────────────────────────────────────────────────────────────────

local function make_node(node_type, tag_or_data)
	local n = {}
	n.nodeType   = node_type
	n.tagName    = (node_type == 1) and tag_or_data or nil
	n.data       = (node_type == 3) and (tag_or_data or "") or nil
	n.children   = {}
	n.attributes = {}
	n.parentNode = nil
	n.textContent = nil

	function n.appendChild(child)
		n.children[#n.children + 1] = child
		child.parentNode = n
		return child
	end

	function n.setAttribute(name, value)
		n.attributes[name] = value
	end

	function n.getAttribute(name)
		return n.attributes[name]
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
function mock_document.createElementNS(ns, tag)
	local n = make_node(1, tag)
	n.namespaceURI = ns
	return n
end

-- Install as global so h can find it at load time.
document = mock_document --: any

-- Load the library after document global is set.
local h = require("lib.web.html")

-- ── Tests ─────────────────────────────────────────────────────────────────────

T.describe("html.div", function()
	T.it("creates element with correct _tag", function()
		local el = h.div({})
		T.eq(el._tag, "div")
	end)

	T.it("creates element with correct DOM tagName", function()
		local el = h.div({})
		T.eq(el.node.tagName, "div")
	end)

	T.it("sets string attribute", function()
		local el = h.div({ class = "card" })
		T.eq(el.node.attributes["class"], "card")
	end)

	T.it("sets numeric attribute as string", function()
		local el = h.div({ tabindex = 0 })
		T.eq(el.node.attributes["tabindex"], "0")
	end)

	T.it("sets boolean true as empty string", function()
		local el = h.div({ hidden = true })
		T.eq(el.node.attributes["hidden"], "")
	end)

	T.it("skips false attribute", function()
		local el = h.div({ hidden = false })
		T.eq(el.node.attributes["hidden"], nil)
	end)

	T.it("skips nil attribute", function()
		local el = h.div({ id = nil })
		T.eq(el.node.attributes["id"], nil)
	end)

	T.it("appends El child", function()
		local child = h.span({})
		local el = h.div({}, child)
		T.eq(#el.node.children, 1)
		T.eq(el.node.children[1], child.node)
	end)

	T.it("appends string child as text node", function()
		local el = h.div({}, "hello")
		T.eq(#el.node.children, 1)
		T.eq(el.node.children[1].nodeType, 3)
		T.eq(el.node.children[1].data, "hello")
	end)

	T.it("appends multiple children in order", function()
		local c1 = h.span({})
		local c2 = h.em({})
		local el = h.div({}, c1, c2)
		T.eq(#el.node.children, 2)
		T.eq(el.node.children[1], c1.node)
		T.eq(el.node.children[2], c2.node)
	end)

	T.it("mixes El and string children", function()
		local span_el = h.span({})
		local el = h.div({}, "before", span_el, "after")
		T.eq(#el.node.children, 3)
		T.eq(el.node.children[1].nodeType, 3)
		T.eq(el.node.children[2], span_el.node)
		T.eq(el.node.children[3].nodeType, 3)
	end)
end)

T.describe("html element factories", function()
	T.it("span", function()
		local el = h.span({ id = "x" })
		T.eq(el._tag, "span")
		T.eq(el.node.tagName, "span")
		T.eq(el.node.attributes["id"], "x")
	end)

	T.it("p", function()
		local el = h.p({}, "text")
		T.eq(el._tag, "p")
		T.eq(#el.node.children, 1)
	end)

	T.it("a", function()
		local el = h.a({ href = "/about" }, "About")
		T.eq(el._tag, "a")
		T.eq(el.node.attributes["href"], "/about")
	end)

	T.it("h1 through h6", function()
		for _, tag in ipairs({"h1", "h2", "h3", "h4", "h5", "h6"}) do
			local el = h[tag]({}, tag .. " text")
			T.eq(el._tag, tag)
			T.eq(el.node.tagName, tag)
		end
	end)

	T.it("ul + li nesting", function()
		local list = h.ul({}, h.li({}, "item 1"), h.li({}, "item 2"))
		T.eq(list._tag, "ul")
		T.eq(#list.node.children, 2)
		T.eq(list.node.children[1].tagName, "li")
	end)

	T.it("table nesting: table > tbody > tr > td", function()
		local cell = h.td({}, "cell")
		local row  = h.tr({}, cell)
		local body = h.tbody({}, row)
		local tbl  = h.table({}, body)
		T.eq(tbl._tag, "table")
		T.eq(tbl.node.children[1], body.node)
		T.eq(body.node.children[1], row.node)
		T.eq(row.node.children[1], cell.node)
	end)

	T.it("form + input", function()
		local inp  = h.input({ type = "text", name = "q" })
		local form = h.form({ action = "/search" }, inp)
		T.eq(inp._tag, "input")
		T.eq(inp.node.attributes["type"], "text")
		T.eq(#form.node.children, 1)
	end)

	T.it("button", function()
		local el = h.button({ type = "submit" }, "Submit")
		T.eq(el._tag, "button")
		T.eq(el.node.attributes["type"], "submit")
	end)

	T.it("select + option", function()
		local opt = h.option({ value = "1" }, "One")
		T.eq(opt._tag, "option")
		T.eq(opt.node.textContent, "One")
		local sel = h.select({}, opt)
		T.eq(#sel.node.children, 1)
	end)

	T.it("textarea with content", function()
		local el = h.textarea({ name = "body" }, "initial text")
		T.eq(el._tag, "textarea")
		T.eq(el.node.textContent, "initial text")
	end)

	T.it("textarea without content", function()
		local el = h.textarea({ name = "body" })
		T.eq(el._tag, "textarea")
		T.eq(el.node.textContent, nil)
	end)
end)

T.describe("html void elements", function()
	T.it("br creates new node each call", function()
		local b1 = h.br()
		local b2 = h.br()
		T.eq(b1._tag, "br")
		T.ok(b1.node ~= b2.node)
	end)

	T.it("hr with attrs", function()
		local el = h.hr({ class = "divider" })
		T.eq(el._tag, "hr")
		T.eq(el.node.attributes["class"], "divider")
	end)

	T.it("img with src and alt", function()
		local el = h.img({ src = "/logo.png", alt = "Logo" })
		T.eq(el._tag, "img")
		T.eq(el.node.attributes["src"], "/logo.png")
		T.eq(el.node.attributes["alt"], "Logo")
	end)

	T.it("input is void (no children)", function()
		local el = h.input({ type = "checkbox", checked = true })
		T.eq(el._tag, "input")
		T.eq(el.node.attributes["checked"], "")
	end)
end)

T.describe("html metadata elements", function()
	T.it("meta", function()
		local el = h.meta({ name = "viewport", content = "width=device-width" })
		T.eq(el._tag, "meta")
		T.eq(el.node.attributes["name"], "viewport")
	end)

	T.it("link", function()
		local el = h.link({ rel = "stylesheet", href = "/style.css" })
		T.eq(el._tag, "link")
		T.eq(el.node.attributes["rel"], "stylesheet")
	end)

	T.it("script without content", function()
		local el = h.script({ src = "/app.js", defer = true })
		T.eq(el._tag, "script")
		T.eq(el.node.attributes["src"], "/app.js")
		T.eq(el.node.attributes["defer"], "")
	end)

	T.it("script with inline content", function()
		local el = h.script({}, "console.log('hello')")
		T.eq(el._tag, "script")
		T.eq(el.node.textContent, "console.log('hello')")
	end)

	T.it("style", function()
		local el = h.style({}, "body { margin: 0 }")
		T.eq(el._tag, "style")
		T.eq(el.node.textContent, "body { margin: 0 }")
	end)

	T.it("title_", function()
		local el = h.title_({}, "My Page")
		T.eq(el._tag, "title")
		T.eq(el.node.textContent, "My Page")
	end)
end)

T.describe("html.text", function()
	T.it("creates text node wrapper", function()
		local el = h.text("hello world")
		T.eq(el._tag, "#text")
		T.eq(el.node.nodeType, 3)
		T.eq(el.node.data, "hello world")
	end)
end)

T.describe("html.mount", function()
	T.it("appends el.node into container", function()
		local container = mock_document.createElement("div")
		local el = h.div({ class = "app" })
		h.mount(el, container)
		T.eq(#container.children, 1)
		T.eq(container.children[1], el.node)
	end)

	T.it("sets parentNode on mounted element", function()
		local container = mock_document.createElement("body")
		local el = h.p({}, "content")
		h.mount(el, container)
		T.eq(el.node.parentNode, container)
	end)
end)

T.describe("html SVG elements", function()
	T.it("svg uses createElementNS", function()
		local el = h.svg({ width = "100", height = "100" })
		T.eq(el._tag, "svg")
		T.eq(el.node.namespaceURI, "http://www.w3.org/2000/svg")
	end)

	T.it("svg children appended", function()
		local c = h.circle({ cx = "50", cy = "50", r = "40" })
		local el = h.svg({ viewBox = "0 0 100 100" }, c)
		T.eq(#el.node.children, 1)
		T.eq(el.node.children[1], c.node)
	end)

	T.it("circle is void SVG", function()
		local el = h.circle({ cx = "10", cy = "10", r = "5", fill = "red" })
		T.eq(el._tag, "circle")
		T.eq(el.node.namespaceURI, "http://www.w3.org/2000/svg")
		T.eq(el.node.attributes["fill"], "red")
	end)

	T.it("rect", function()
		local el = h.rect({ x = "0", y = "0", width = "100", height = "50" })
		T.eq(el._tag, "rect")
	end)

	T.it("path", function()
		local el = h.path({ d = "M0 0 L10 10" })
		T.eq(el._tag, "path")
		T.eq(el.node.attributes["d"], "M0 0 L10 10")
	end)

	T.it("g with children", function()
		local r = h.rect({ width = "10", height = "10" })
		local el = h.g({}, r)
		T.eq(el._tag, "g")
		T.eq(#el.node.children, 1)
	end)

	T.it("linear_gradient with stops", function()
		local s1 = h.stop({ offset = "0%", ["stop-color"] = "#fff" })
		local s2 = h.stop({ offset = "100%", ["stop-color"] = "#000" })
		local el = h.linear_gradient({ id = "grad1" }, s1, s2)
		T.eq(el._tag, "linearGradient")
		T.eq(#el.node.children, 2)
	end)

	T.it("use", function()
		local el = h.use({ href = "#icon" })
		T.eq(el._tag, "use")
		T.eq(el.node.attributes["href"], "#icon")
	end)
end)

T.describe("html.dl / dt / dd", function()
	T.it("dl with dt and dd", function()
		local term = h.dt({}, "Term")
		local def  = h.dd({}, "Definition")
		local list = h.dl({}, term, def)
		T.eq(list._tag, "dl")
		T.eq(#list.node.children, 2)
		T.eq(list.node.children[1].tagName, "dt")
		T.eq(list.node.children[2].tagName, "dd")
	end)
end)

T.describe("html sectioning and media", function()
	T.it("section, article, aside, nav", function()
		for _, tag in ipairs({"section", "article", "aside", "nav"}) do
			local el = h[tag]({})
			T.eq(el._tag, tag)
		end
	end)

	T.it("header and footer", function()
		local hdr = h.header({}, h.h1({}, "Title"))
		T.eq(hdr._tag, "header")
		T.eq(#hdr.node.children, 1)
		local ftr = h.footer({}, "Copyright")
		T.eq(ftr._tag, "footer")
	end)

	T.it("video with source", function()
		local src = h.source({ src = "/vid.mp4", type = "video/mp4" })
		local vid = h.video({ controls = true }, src)
		T.eq(vid._tag, "video")
		T.eq(#vid.node.children, 1)
	end)

	T.it("canvas", function()
		local el = h.canvas({ width = "800", height = "600" })
		T.eq(el._tag, "canvas")
		T.eq(el.node.attributes["width"], "800")
	end)

	T.it("iframe", function()
		local el = h.iframe({ src = "https://example.com" })
		T.eq(el._tag, "iframe")
		T.eq(el.node.attributes["src"], "https://example.com")
	end)
end)

T.describe("html fieldset / legend", function()
	T.it("fieldset with legend", function()
		local leg = h.legend({}, "Options")
		local fs  = h.fieldset({}, leg)
		T.eq(fs._tag, "fieldset")
		T.eq(#fs.node.children, 1)
		T.eq(fs.node.children[1].tagName, "legend")
	end)
end)
