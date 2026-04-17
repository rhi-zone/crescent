-- lib/web/html/init.lua
-- Type-safe DOM element builder library.
--
-- Each factory creates a DOM element and returns a nominal wrapper
--   { _tag: string, node: HTMLElement }
-- so the typechecker can enforce HTML content model constraints.
--
-- Plain closures only (lua2ts compatibility — no metatables).
-- Runtime requirement: `document` global (browser or mock DOM in tests).
--
-- Usage:
--   local h = require("lib.web.html")
--   local card = h.div({ class = "card" }, h.p({}, "hello"), h.a({ href = "/about" }, "About"))

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- ── Type declarations ─────────────────────────────────────────────────────────
--:: require "lib.web.js_types"
--:: declare document = Document

-- Base El type: nominal wrapper pairing a tag name with a DOM node.
--:: El = { _tag: string, node: HTMLElement }

-- Individual element types (nominal aliases over El)
--:: HtmlEl       = { _tag: string, node: HTMLElement }
--:: HeadEl       = { _tag: string, node: HTMLElement }
--:: BodyEl       = { _tag: string, node: HTMLElement }
--:: DivEl        = { _tag: string, node: HTMLElement }
--:: SectionEl    = { _tag: string, node: HTMLElement }
--:: ArticleEl    = { _tag: string, node: HTMLElement }
--:: AsideEl      = { _tag: string, node: HTMLElement }
--:: HeaderEl     = { _tag: string, node: HTMLElement }
--:: FooterEl     = { _tag: string, node: HTMLElement }
--:: MainEl       = { _tag: string, node: HTMLElement }
--:: NavEl        = { _tag: string, node: HTMLElement }
--:: H1El         = { _tag: string, node: HTMLElement }
--:: H2El         = { _tag: string, node: HTMLElement }
--:: H3El         = { _tag: string, node: HTMLElement }
--:: H4El         = { _tag: string, node: HTMLElement }
--:: H5El         = { _tag: string, node: HTMLElement }
--:: H6El         = { _tag: string, node: HTMLElement }
--:: PEl          = { _tag: string, node: HTMLElement }
--:: SpanEl       = { _tag: string, node: HTMLElement }
--:: AEl          = { _tag: string, node: HTMLElement }
--:: EmEl         = { _tag: string, node: HTMLElement }
--:: StrongEl     = { _tag: string, node: HTMLElement }
--:: CodeEl       = { _tag: string, node: HTMLElement }
--:: PreEl        = { _tag: string, node: HTMLElement }
--:: BlockquoteEl = { _tag: string, node: HTMLElement }
--:: IEl          = { _tag: string, node: HTMLElement }
--:: BEl          = { _tag: string, node: HTMLElement }
--:: SmallEl      = { _tag: string, node: HTMLElement }
--:: AbbrEl       = { _tag: string, node: HTMLElement }
--:: BrEl         = { _tag: string, node: HTMLElement }
--:: HrEl         = { _tag: string, node: HTMLElement }
--:: ImgEl        = { _tag: string, node: HTMLElement }
--:: UlEl         = { _tag: string, node: HTMLElement }
--:: OlEl         = { _tag: string, node: HTMLElement }
--:: LiEl         = { _tag: string, node: HTMLElement }
--:: DlEl         = { _tag: string, node: HTMLElement }
--:: DtEl         = { _tag: string, node: HTMLElement }
--:: DdEl         = { _tag: string, node: HTMLElement }
--:: TableEl      = { _tag: string, node: HTMLElement }
--:: TheadEl      = { _tag: string, node: HTMLElement }
--:: TbodyEl      = { _tag: string, node: HTMLElement }
--:: TfootEl      = { _tag: string, node: HTMLElement }
--:: TrEl         = { _tag: string, node: HTMLElement }
--:: ThEl         = { _tag: string, node: HTMLElement }
--:: TdEl         = { _tag: string, node: HTMLElement }
--:: FormEl       = { _tag: string, node: HTMLFormElement }
--:: InputEl      = { _tag: string, node: HTMLInputElement }
--:: LabelEl      = { _tag: string, node: HTMLElement }
--:: FieldsetEl   = { _tag: string, node: HTMLElement }
--:: LegendEl     = { _tag: string, node: HTMLElement }
--:: SelectEl     = { _tag: string, node: HTMLSelectElement }
--:: OptionEl     = { _tag: string, node: HTMLElement }
--:: TextareaEl   = { _tag: string, node: HTMLTextAreaElement }
--:: ButtonEl     = { _tag: string, node: HTMLElement }
--:: IframeEl     = { _tag: string, node: HTMLElement }
--:: VideoEl      = { _tag: string, node: HTMLVideoElement }
--:: AudioEl      = { _tag: string, node: HTMLAudioElement }
--:: SourceEl     = { _tag: string, node: HTMLElement }
--:: CanvasEl     = { _tag: string, node: HTMLCanvasElement }
--:: SvgEl        = { _tag: string, node: HTMLElement }
--:: StyleEl      = { _tag: string, node: HTMLElement }
--:: ScriptEl     = { _tag: string, node: HTMLElement }
--:: MetaEl       = { _tag: string, node: HTMLElement }
--:: LinkEl       = { _tag: string, node: HTMLElement }
--:: TitleEl      = { _tag: string, node: HTMLElement }
--:: TextNodeEl   = { _tag: string, node: HTMLElement }

-- SVG child element types
--:: CircleEl         = { _tag: string, node: HTMLElement }
--:: EllipseEl        = { _tag: string, node: HTMLElement }
--:: RectEl           = { _tag: string, node: HTMLElement }
--:: LineEl           = { _tag: string, node: HTMLElement }
--:: PolylineEl       = { _tag: string, node: HTMLElement }
--:: PolygonEl        = { _tag: string, node: HTMLElement }
--:: PathEl           = { _tag: string, node: HTMLElement }
--:: SvgTextEl        = { _tag: string, node: HTMLElement }
--:: TspanEl          = { _tag: string, node: HTMLElement }
--:: GEl              = { _tag: string, node: HTMLElement }
--:: DefsEl           = { _tag: string, node: HTMLElement }
--:: SymbolEl         = { _tag: string, node: HTMLElement }
--:: UseEl            = { _tag: string, node: HTMLElement }
--:: ClipPathEl       = { _tag: string, node: HTMLElement }
--:: MaskEl           = { _tag: string, node: any }
--:: LinearGradientEl = { _tag: string, node: any }
--:: RadialGradientEl = { _tag: string, node: any }
--:: StopEl           = { _tag: string, node: any }
--:: PatternEl        = { _tag: string, node: any }
--:: SvgImageEl       = { _tag: string, node: any }
--:: ForeignObjectEl  = { _tag: string, node: any }

-- Content category unions
--:: HeadContent       = MetaEl | LinkEl | ScriptEl | StyleEl | TitleEl
--:: PhrasingContent   = SpanEl | AEl | EmEl | StrongEl | CodeEl | IEl | BEl | SmallEl | AbbrEl | ImgEl | BrEl | InputEl | ButtonEl | LabelEl | SelectEl | TextareaEl
--:: HeadingContent    = H1El | H2El | H2El | H3El | H4El | H5El | H6El
--:: SectioningContent = SectionEl | ArticleEl | AsideEl | NavEl
--:: EmbeddedContent   = ImgEl | VideoEl | AudioEl | IframeEl | CanvasEl | SvgEl
--:: FlowContent       = DivEl | PEl | PreEl | BlockquoteEl | UlEl | OlEl | DlEl | TableEl | FormEl | FieldsetEl | HeaderEl | FooterEl | MainEl | HrEl | HeadingContent | SectioningContent | PhrasingContent | EmbeddedContent
--:: TableSectionContent = TheadEl | TbodyEl | TfootEl
--:: RowContent        = TrEl
--:: CellContent       = TdEl | ThEl
--:: ListItemContent   = LiEl
--:: SelectContent     = OptionEl
--:: LegendContent     = LegendEl
--:: DefinitionListContent = DtEl | DdEl
--:: SvgContent        = CircleEl | EllipseEl | RectEl | LineEl | PolylineEl | PolygonEl | PathEl | SvgTextEl | TspanEl | GEl | DefsEl | SymbolEl | UseEl | ClipPathEl | MaskEl | LinearGradientEl | RadialGradientEl | StopEl | PatternEl | SvgImageEl | ForeignObjectEl
--:: AnyEl             = FlowContent | HeadContent | RowContent | CellContent | ListItemContent | SelectContent | LegendContent | SourceEl | TableSectionContent | DefinitionListContent | HtmlEl | HeadEl | BodyEl | SvgContent

-- Attribute table type (open — all HTML attributes are strings, numbers, or booleans)
--:: Attrs = { [string]: string | number | boolean | nil, ... }

-- ── SVG namespace ─────────────────────────────────────────────────────────────

local SVG_NS = "http://www.w3.org/2000/svg"

-- ── Internal helpers ──────────────────────────────────────────────────────────

-- Apply attributes table to a DOM node.
-- Skips nil/false values; true becomes empty string (boolean attribute).
--: (HTMLElement, { [string]: unknown }) -> nil
local function apply_attrs(node, attrs)
	for k, v in pairs(attrs) do
		if v ~= nil and v ~= false then
			if v == true then
				node.setAttribute(k, "")
			else
				node.setAttribute(k, tostring(v))
			end
		end
	end
end

-- Append children to a DOM node.
-- Each child is either an El wrapper (append .node) or a string (text node).
local function append_children(node, children)
	for i = 1, #children do
		local child = children[i]
		if type(child) == "string" then
			node.appendChild(document.createTextNode(child))
		else
			node.appendChild(child.node)
		end
	end
end

-- Build a standard HTML element factory.
-- Returns a function: (attrs, ...children) -> El
local function make_el(tag)
	return function(attrs, ...)
		local node = document.createElement(tag)
		apply_attrs(node, attrs)
		append_children(node, {...})
		return { _tag = tag, node = node }
	end
end

-- Build a void element factory (no children).
-- Returns a function: (attrs) -> El
local function make_void(tag)
	return function(attrs)
		local node = document.createElement(tag)
		apply_attrs(node, attrs)
		return { _tag = tag, node = node }
	end
end

-- Build an SVG namespace element factory (with children).
local function make_svg_el(tag)
	return function(attrs, ...)
		local node = document.createElementNS(SVG_NS, tag)
		apply_attrs(node, attrs)
		append_children(node, {...})
		return { _tag = tag, node = node }
	end
end

-- Build a void SVG element factory (no children).
local function make_svg_void(tag)
	return function(attrs)
		local node = document.createElementNS(SVG_NS, tag)
		apply_attrs(node, attrs)
		return { _tag = tag, node = node }
	end
end

-- ── Document structure ────────────────────────────────────────────────────────

M.html    = make_el("html")
M.head    = make_el("head")
M.body    = make_el("body")

-- ── Metadata ──────────────────────────────────────────────────────────────────

M.meta   = make_void("meta")
M.link   = make_void("link")

-- script: optional inline content string after attrs
function M.script(attrs, content)
	local node = document.createElement("script")
	apply_attrs(node, attrs)
	if content ~= nil then
		node.textContent = content
	end
	return { _tag = "script", node = node }
end

-- style: inline content required
function M.style(attrs, content)
	local node = document.createElement("style")
	apply_attrs(node, attrs)
	node.textContent = content
	return { _tag = "style", node = node }
end

-- title_ (trailing underscore avoids collision with Lua global `title` if any)
function M.title_(attrs, content)
	local node = document.createElement("title")
	apply_attrs(node, attrs)
	node.textContent = content
	return { _tag = "title", node = node }
end

-- ── Sectioning / flow ─────────────────────────────────────────────────────────

M.div     = make_el("div")
M.section = make_el("section")
M.article = make_el("article")
M.aside   = make_el("aside")
M.header  = make_el("header")
M.footer  = make_el("footer")
M.main    = make_el("main")
M.nav     = make_el("nav")

-- ── Headings ──────────────────────────────────────────────────────────────────

M.h1 = make_el("h1")
M.h2 = make_el("h2")
M.h3 = make_el("h3")
M.h4 = make_el("h4")
M.h5 = make_el("h5")
M.h6 = make_el("h6")

-- ── Phrasing content ──────────────────────────────────────────────────────────

M.p          = make_el("p")
M.span       = make_el("span")
M.a          = make_el("a")
M.em         = make_el("em")
M.strong     = make_el("strong")
M.code       = make_el("code")
M.pre        = make_el("pre")
M.blockquote = make_el("blockquote")
M.i          = make_el("i")
M.b          = make_el("b")
M.small      = make_el("small")
M.abbr       = make_el("abbr")

-- ── Void phrasing ─────────────────────────────────────────────────────────────

-- br: no attrs, new node each call (avoid insertion-move semantics)
function M.br()
	return { _tag = "br", node = document.createElement("br") }
end

M.hr  = make_void("hr")
M.img = make_void("img")

-- ── Lists ─────────────────────────────────────────────────────────────────────

M.ul = make_el("ul")
M.ol = make_el("ol")
M.li = make_el("li")
M.dl = make_el("dl")
M.dt = make_el("dt")
M.dd = make_el("dd")

-- ── Tables ────────────────────────────────────────────────────────────────────

M.table = make_el("table")
M.thead = make_el("thead")
M.tbody = make_el("tbody")
M.tfoot = make_el("tfoot")
M.tr    = make_el("tr")
M.th    = make_el("th")
M.td    = make_el("td")

-- ── Forms ─────────────────────────────────────────────────────────────────────

M.form     = make_el("form")
M.input    = make_void("input")
M.label    = make_el("label")
M.fieldset = make_el("fieldset")
M.legend   = make_el("legend")
M.select   = make_el("select")
M.button   = make_el("button")

-- option: optional inline text content
function M.option(attrs, content)
	local node = document.createElement("option")
	apply_attrs(node, attrs)
	if content ~= nil then
		node.textContent = content
	end
	return { _tag = "option", node = node }
end

-- textarea: optional inline text content
function M.textarea(attrs, content)
	local node = document.createElement("textarea")
	apply_attrs(node, attrs)
	if content ~= nil then
		node.textContent = content
	end
	return { _tag = "textarea", node = node }
end

-- ── Media / embedded ──────────────────────────────────────────────────────────

M.iframe = make_void("iframe")
M.video  = make_el("video")
M.audio  = make_el("audio")
M.source = make_void("source")
M.canvas = make_void("canvas")

-- svg: uses createElementNS
function M.svg(attrs, ...)
	local node = document.createElementNS(SVG_NS, "svg")
	apply_attrs(node, attrs)
	append_children(node, {...})
	return { _tag = "svg", node = node }
end

-- ── SVG child elements ────────────────────────────────────────────────────────

M.circle         = make_svg_void("circle")
M.ellipse        = make_svg_void("ellipse")
M.rect           = make_svg_void("rect")
M.line           = make_svg_void("line")
M.polyline       = make_svg_void("polyline")
M.polygon        = make_svg_void("polygon")
M.path           = make_svg_void("path")
M.svg_text       = make_svg_el("text")
M.tspan          = make_svg_el("tspan")
M.g              = make_svg_el("g")
M.defs           = make_svg_el("defs")
M.symbol         = make_svg_el("symbol")
M.use            = make_svg_void("use")
M.clip_path      = make_svg_el("clipPath")
M.mask           = make_svg_el("mask")
M.linear_gradient = make_svg_el("linearGradient")
M.radial_gradient = make_svg_el("radialGradient")
M.stop           = make_svg_void("stop")
M.pattern        = make_svg_el("pattern")
M.svg_image      = make_svg_void("image")
M.foreign_object = make_svg_el("foreignObject")

-- ── Text / utilities ──────────────────────────────────────────────────────────

-- text(str) — create a Text node wrapped as El
function M.text(str)
	return { _tag = "#text", node = document.createTextNode(str) }
end

-- mount(el, container) — append el.node into a container DOM node
function M.mount(el, container)
	container.appendChild(el.node)
end

return M
