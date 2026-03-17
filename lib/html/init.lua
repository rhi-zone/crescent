-- lib/html — type-safe HTML builder
-- Attrs table: string keys are HTML attributes, integer keys are child strings.
-- Void elements (br, hr, img, input, link, meta, source) take attrs only (no children).
--
-- Usage:
--   local h = require("lib.html")
--   h.div({ class="card", h.p("hello"), h.a({ href="/about" }, "About") })

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- HTML character escaping -----------------------------------------------

local ESCAPE_MAP = {
	["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;",
	['"'] = "&quot;", ["'"] = "&#039;",
}

--: fun(s: string): string
local function escape(s) return s:gsub("[&<>\"']", ESCAPE_MAP) end
M.escape = escape

-- Attribute serialization -----------------------------------------------

local function attrs_str(t)
	local out = {}
	for k, v in pairs(t) do
		if type(k) == "string" then
			if v == true then
				out[#out + 1] = " " .. k
			elseif v ~= false then
				out[#out + 1] = string.format(' %s="%s"', k, escape(tostring(v)))
			end
		end
	end
	return table.concat(out)
end

-- Element factories -----------------------------------------------------

-- Normal element: children are integer-indexed strings in the attrs table,
-- or a plain string (auto-escaped).
local function element(tag)
	return function(xs)
		if type(xs) == "string" then
			return string.format("<%s>%s</%s>", tag, escape(xs), tag)
		end
		local parts = { "<", tag, attrs_str(xs), ">" }
		for i = 1, #xs do parts[#parts + 1] = xs[i] end
		parts[#parts + 1] = "</" .. tag .. ">"
		return table.concat(parts)
	end
end

-- Raw element: children not escaped (for <script>, <style>).
local function raw_element(tag)
	return function(xs)
		if type(xs) == "string" then
			return string.format("<%s>%s</%s>", tag, xs, tag)
		end
		local parts = { "<", tag, attrs_str(xs), ">" }
		for i = 1, #xs do parts[#parts + 1] = xs[i] end
		parts[#parts + 1] = "</" .. tag .. ">"
		return table.concat(parts)
	end
end

-- Void element: no children, self-closing.
local function void(tag)
	return function(xs)
		return "<" .. tag .. attrs_str(xs or {}) .. " />"
	end
end

M.element     = element
M.raw_element = raw_element
M.void        = void

-- Type declarations -----------------------------------------------------
--
-- GlobalAttrs: attributes valid on every HTML element.
--:: GlobalAttrs = { id?: string, class?: string, style?: string, title?: string, hidden?: boolean, tabindex?: integer }
--
-- Per-element attribute types (extend GlobalAttrs fields):
--:: AAttrs       = { href?: string, target?: string, rel?: string, download?: string, id?: string, class?: string, style?: string }
--:: ButtonAttrs  = { type?: string, name?: string, value?: string, disabled?: boolean, form?: string, id?: string, class?: string, style?: string }
--:: FormAttrs    = { action?: string, method?: string, enctype?: string, id?: string, class?: string, style?: string }
--:: ImgAttrs     = { src: string, alt: string, width?: string, height?: string, loading?: string, id?: string, class?: string, style?: string }
--:: InputAttrs   = { type?: string, name?: string, value?: string, placeholder?: string, required?: boolean, disabled?: boolean, checked?: boolean, id?: string, class?: string, style?: string }
--:: LabelAttrs   = { for?: string, id?: string, class?: string, style?: string }
--:: LinkAttrs    = { rel: string, href?: string, type?: string, media?: string, id?: string, class?: string }
--:: MetaAttrs    = { name?: string, content?: string, charset?: string, ["http-equiv"]?: string }
--:: OptionAttrs  = { value?: string, selected?: boolean, disabled?: boolean, id?: string, class?: string }
--:: ScriptAttrs  = { src?: string, type?: string, async?: boolean, defer?: boolean, id?: string }
--:: SelectAttrs  = { name?: string, multiple?: boolean, required?: boolean, disabled?: boolean, id?: string, class?: string, style?: string }
--:: TextareaAttrs = { name?: string, rows?: integer, cols?: integer, placeholder?: string, required?: boolean, disabled?: boolean, readonly?: boolean, id?: string, class?: string, style?: string }
--:: VideoAttrs   = { src?: string, controls?: boolean, autoplay?: boolean, loop?: boolean, muted?: boolean, width?: string, height?: string, id?: string, class?: string, style?: string }
--:: AudioAttrs   = { src?: string, controls?: boolean, autoplay?: boolean, loop?: boolean, muted?: boolean, id?: string, class?: string }
--:: SourceAttrs  = { src?: string, type?: string, srcset?: string, media?: string }

-- Document structure ----------------------------------------------------

local _html = element("html")
--: fun(xs: { lang?: string, [integer]: string }): string
M.html = function(xs) return "<!DOCTYPE html>" .. _html(xs) end

--: fun(xs: { [integer]: string }): string
M.head = element("head")

--: fun(xs: { [integer]: string, class?: string, id?: string, style?: string }): string
M.body = element("body")

-- Metadata elements (void) ---------------------------------------------

--: fun(xs: MetaAttrs): string
M.meta = void("meta")

--: fun(xs: LinkAttrs): string
M.link = void("link")

--: fun(xs: ScriptAttrs): string
M.script = raw_element("script")

--: fun(xs: { [integer]: string }): string
M.style = raw_element("style")

--: fun(xs: { [integer]: string, charset?: string }): string
M.title = element("title")

-- Flow content ----------------------------------------------------------

--: fun(xs: { id?: string, class?: string, style?: string, [integer]: string }): string
M.div = element("div")

--: fun(xs: { id?: string, class?: string, style?: string, [integer]: string }): string
M.section = element("section")

--: fun(xs: { id?: string, class?: string, style?: string, [integer]: string }): string
M.article = element("article")

--: fun(xs: { id?: string, class?: string, style?: string, [integer]: string }): string
M.aside = element("aside")

--: fun(xs: { id?: string, class?: string, style?: string, [integer]: string }): string
M.header = element("header")

--: fun(xs: { id?: string, class?: string, style?: string, [integer]: string }): string
M.footer = element("footer")

--: fun(xs: { id?: string, class?: string, style?: string, [integer]: string }): string
M.main = element("main")

--: fun(xs: { id?: string, class?: string, style?: string, [integer]: string }): string
M.nav = element("nav")

-- Headings --------------------------------------------------------------

--: fun(xs: string | { id?: string, class?: string, style?: string, [integer]: string }): string
M.h1 = element("h1")
--: fun(xs: string | { id?: string, class?: string, style?: string, [integer]: string }): string
M.h2 = element("h2")
--: fun(xs: string | { id?: string, class?: string, style?: string, [integer]: string }): string
M.h3 = element("h3")
--: fun(xs: string | { id?: string, class?: string, style?: string, [integer]: string }): string
M.h4 = element("h4")
--: fun(xs: string | { id?: string, class?: string, style?: string, [integer]: string }): string
M.h5 = element("h5")
--: fun(xs: string | { id?: string, class?: string, style?: string, [integer]: string }): string
M.h6 = element("h6")

-- Phrasing content ------------------------------------------------------

--: fun(xs: string | { id?: string, class?: string, style?: string, [integer]: string }): string
M.p = element("p")

--: fun(xs: AAttrs | { [integer]: string }): string
M.a = element("a")

--: fun(xs: string | { id?: string, class?: string, style?: string, [integer]: string }): string
M.span = element("span")

--: fun(xs: string | { id?: string, class?: string, style?: string, [integer]: string }): string
M.em = element("em")

--: fun(xs: string | { id?: string, class?: string, style?: string, [integer]: string }): string
M.strong = element("strong")

--: fun(xs: string | { id?: string, class?: string, style?: string, [integer]: string }): string
M.code = element("code")

--: fun(xs: string | { id?: string, class?: string, style?: string, [integer]: string }): string
M.pre = element("pre")

--: fun(xs: string | { id?: string, class?: string, style?: string, [integer]: string }): string
M.blockquote = element("blockquote")

--: fun(xs: string | { id?: string, class?: string, style?: string, [integer]: string }): string
M.i = element("i")

--: fun(xs: string | { id?: string, class?: string, style?: string, [integer]: string }): string
M.b = element("b")

--: fun(xs: string | { id?: string, class?: string, style?: string, [integer]: string }): string
M.small = element("small")

--: fun(xs: string | { id?: string, class?: string, style?: string, [integer]: string }): string
M.abbr = element("abbr")

-- Void phrasing content ------------------------------------------------

--: string
M.br = "<br />"

--: fun(xs: { class?: string, id?: string }): string
M.br_ = void("br")

--: fun(xs: { class?: string, id?: string }): string
M.hr = void("hr")

--: fun(xs: ImgAttrs): string
M.img = void("img")

-- Lists -----------------------------------------------------------------

--: fun(xs: { id?: string, class?: string, style?: string, [integer]: string }): string
M.ul = element("ul")

--: fun(xs: { id?: string, class?: string, style?: string, start?: integer, [integer]: string }): string
M.ol = element("ol")

--: fun(xs: string | { id?: string, class?: string, style?: string, [integer]: string }): string
M.li = element("li")

--: fun(xs: { id?: string, class?: string, style?: string, [integer]: string }): string
M.dl = element("dl")

--: fun(xs: string | { id?: string, class?: string, style?: string, [integer]: string }): string
M.dt = element("dt")

--: fun(xs: string | { id?: string, class?: string, style?: string, [integer]: string }): string
M.dd = element("dd")

-- Tables ----------------------------------------------------------------

--: fun(xs: { id?: string, class?: string, style?: string, [integer]: string }): string
M.table = element("table")

--: fun(xs: { id?: string, class?: string, style?: string, [integer]: string }): string
M.thead = element("thead")

--: fun(xs: { id?: string, class?: string, style?: string, [integer]: string }): string
M.tbody = element("tbody")

--: fun(xs: { id?: string, class?: string, style?: string, [integer]: string }): string
M.tfoot = element("tfoot")

--: fun(xs: { id?: string, class?: string, style?: string, [integer]: string }): string
M.tr = element("tr")

--: fun(xs: string | { colspan?: integer, rowspan?: integer, scope?: string, id?: string, class?: string, style?: string, [integer]: string }): string
M.th = element("th")

--: fun(xs: string | { colspan?: integer, rowspan?: integer, id?: string, class?: string, style?: string, [integer]: string }): string
M.td = element("td")

-- Forms -----------------------------------------------------------------

--: fun(xs: FormAttrs | { [integer]: string }): string
M.form = element("form")

--: fun(xs: InputAttrs): string
M.input = void("input")

--: fun(xs: LabelAttrs | { [integer]: string }): string
M.label = element("label")

--: fun(xs: { id?: string, class?: string, style?: string, legend?: string, disabled?: boolean, [integer]: string }): string
M.fieldset = element("fieldset")

--: fun(xs: SelectAttrs | { [integer]: string }): string
M.select = element("select")

--: fun(xs: OptionAttrs | { [integer]: string }): string
M.option = element("option")

--: fun(xs: TextareaAttrs): string
M.textarea = element("textarea")

--: fun(xs: ButtonAttrs | { [integer]: string }): string
M.button = element("button")

-- Media -----------------------------------------------------------------

--: fun(xs: { id?: string, class?: string, style?: string, width?: string, height?: string, name?: string, src?: string, [integer]: string }): string
M.iframe = element("iframe")

--: fun(xs: VideoAttrs | { [integer]: string }): string
M.video = element("video")

--: fun(xs: AudioAttrs | { [integer]: string }): string
M.audio = element("audio")

--: fun(xs: SourceAttrs): string
M.source = void("source")

-- Graphics --------------------------------------------------------------

--: fun(xs: { id?: string, class?: string, style?: string, width?: string, height?: string, [integer]: string }): string
M.canvas = element("canvas")

--: fun(xs: { id?: string, class?: string, style?: string, width?: string, height?: string, viewBox?: string, xmlns?: string, [integer]: string }): string
M.svg = element("svg")

-- Utility ---------------------------------------------------------------

--: fun(s: string): string
M.text = escape

return M
