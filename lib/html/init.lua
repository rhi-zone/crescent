-- lib/html — type-safe HTML builder
--
-- Every element function returns a distinct nominal type (e.g. DivElement,
-- TrElement), so the typechecker can enforce content models: passing h.div(...)
-- where h.tr expects only TdElement | ThElement children is a type error.
--
-- The Element<Content, Attrs> generic alias is the canonical way to annotate
-- per-element builders. Content categories (FlowContent, PhrasingContent, ...)
-- are union aliases over the individual element types.
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

--: (s: string) -> string
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

-- Normal element: attrs table with string keys as HTML attributes and
-- integer keys as pre-rendered child strings.
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
-- Generic element alias. Each element is annotated as Element<T, A> where
-- T is the element's own newtype and A is its attrs record.
--
--:: Element<Content, Attrs> = (attrs: Attrs) -> Content
--
-- Per-element content newtypes — each is a distinct nominal type wrapping
-- string. The typechecker enforces that e.g. TrElement cannot appear where
-- only CellElement is expected.
--
--:: newtype HtmlElement   = string   -- <html>
--:: newtype HeadElement   = string   -- <head>
--:: newtype BodyElement   = string   -- <body>
--:: newtype DivElement    = string   -- <div>
--:: newtype SectionElement = string  -- <section>
--:: newtype ArticleElement = string  -- <article>
--:: newtype AsideElement  = string   -- <aside>
--:: newtype HeaderElement = string   -- <header>
--:: newtype FooterElement = string   -- <footer>
--:: newtype MainElement   = string   -- <main>
--:: newtype NavElement    = string   -- <nav>
--:: newtype PElement      = string   -- <p>
--:: newtype H1Element     = string   -- <h1>
--:: newtype H2Element     = string   -- <h2>
--:: newtype H3Element     = string   -- <h3>
--:: newtype H4Element     = string   -- <h4>
--:: newtype H5Element     = string   -- <h5>
--:: newtype H6Element     = string   -- <h6>
--:: newtype SpanElement   = string   -- <span>
--:: newtype AElement      = string   -- <a>
--:: newtype EmElement     = string   -- <em>
--:: newtype StrongElement = string   -- <strong>
--:: newtype CodeElement   = string   -- <code>
--:: newtype PreElement    = string   -- <pre>
--:: newtype BlockquoteElement = string -- <blockquote>
--:: newtype IElement      = string   -- <i>
--:: newtype BElement      = string   -- <b>
--:: newtype SmallElement  = string   -- <small>
--:: newtype AbbrElement   = string   -- <abbr>
--:: newtype UlElement     = string   -- <ul>
--:: newtype OlElement     = string   -- <ol>
--:: newtype LiElement     = string   -- <li>
--:: newtype DlElement     = string   -- <dl>
--:: newtype DtElement     = string   -- <dt>
--:: newtype DdElement     = string   -- <dd>
--:: newtype TableElement  = string   -- <table>
--:: newtype TheadElement  = string   -- <thead>
--:: newtype TbodyElement  = string   -- <tbody>
--:: newtype TfootElement  = string   -- <tfoot>
--:: newtype TrElement     = string   -- <tr>
--:: newtype ThElement     = string   -- <th>
--:: newtype TdElement     = string   -- <td>
--:: newtype FormElement   = string   -- <form>
--:: newtype InputElement  = string   -- <input> (void)
--:: newtype LabelElement  = string   -- <label>
--:: newtype FieldsetElement = string -- <fieldset>
--:: newtype SelectElement = string   -- <select>
--:: newtype OptionElement = string   -- <option>
--:: newtype TextareaElement = string -- <textarea>
--:: newtype ButtonElement = string   -- <button>
--:: newtype ImgElement    = string   -- <img> (void)
--:: newtype IframeElement = string   -- <iframe>
--:: newtype VideoElement  = string   -- <video>
--:: newtype AudioElement  = string   -- <audio>
--:: newtype SourceElement = string   -- <source> (void)
--:: newtype CanvasElement = string   -- <canvas>
--:: newtype SvgElement    = string   -- <svg>
--:: newtype StyleElement  = string   -- <style>
--:: newtype ScriptElement = string   -- <script>
--:: newtype MetaElement   = string   -- <meta> (void)
--:: newtype LinkElement   = string   -- <link> (void)
--:: newtype TitleElement  = string   -- <title>
--:: newtype BrElement     = string   -- <br> (void)
--:: newtype HrElement     = string   -- <hr> (void)
--
-- Content category unions — used as child types in parent element attrs.
--
--:: HeadContent = MetaElement | LinkElement | ScriptElement | StyleElement | TitleElement
--
--:: PhrasingContent = SpanElement | AElement | EmElement | StrongElement | CodeElement
--                   | IElement | BElement | SmallElement | AbbrElement | ImgElement
--                   | BrElement | InputElement | ButtonElement | LabelElement
--                   | SelectElement | TextareaElement
--
--:: HeadingContent = H1Element | H2Element | H3Element | H4Element | H5Element | H6Element
--
--:: SectioningContent = SectionElement | ArticleElement | AsideElement | NavElement
--
--:: EmbeddedContent = ImgElement | VideoElement | AudioElement | IframeElement | CanvasElement | SvgElement
--
--:: FlowContent = DivElement | PElement | PreElement | BlockquoteElement
--               | UlElement | OlElement | DlElement
--               | TableElement | FormElement | FieldsetElement
--               | HeaderElement | FooterElement | MainElement
--               | HrElement | HeadingContent | SectioningContent
--               | PhrasingContent | EmbeddedContent
--
-- Table content model:
--:: TableSectionContent = TheadElement | TbodyElement | TfootElement
--:: RowContent          = TrElement
--:: CellContent         = TdElement | ThElement
--:: ListItemContent     = LiElement
--:: SelectContent       = OptionElement
--
-- Per-element attribute types:
--
--:: GlobalAttrs = { id?: string, class?: string, style?: string, title?: string, hidden?: boolean, tabindex?: integer }
--:: AAttrs      = { href?: string, target?: string, rel?: string, download?: string, id?: string, class?: string, style?: string }
--:: ButtonAttrs = { type?: string, name?: string, value?: string, disabled?: boolean, form?: string, id?: string, class?: string, style?: string }
--:: FormAttrs   = { action?: string, method?: string, enctype?: string, id?: string, class?: string, style?: string }
--:: ImgAttrs    = { src: string, alt: string, width?: string, height?: string, loading?: string, id?: string, class?: string, style?: string }
--:: InputAttrs  = { type?: string, name?: string, value?: string, placeholder?: string, required?: boolean, disabled?: boolean, checked?: boolean, id?: string, class?: string, style?: string }
--:: LabelAttrs  = { for?: string, id?: string, class?: string, style?: string }
--:: LinkAttrs   = { rel: string, href?: string, type?: string, media?: string, id?: string, class?: string }
--:: MetaAttrs   = { name?: string, content?: string, charset?: string, ["http-equiv"]?: string }
--:: OptionAttrs = { value?: string, selected?: boolean, disabled?: boolean, id?: string, class?: string }
--:: ScriptAttrs = { src?: string, type?: string, async?: boolean, defer?: boolean, id?: string }
--:: SelectAttrs = { name?: string, multiple?: boolean, required?: boolean, disabled?: boolean, id?: string, class?: string, style?: string }
--:: TextareaAttrs = { name?: string, rows?: integer, cols?: integer, placeholder?: string, required?: boolean, disabled?: boolean, readonly?: boolean, id?: string, class?: string, style?: string }
--:: VideoAttrs  = { src?: string, controls?: boolean, autoplay?: boolean, loop?: boolean, muted?: boolean, width?: string, height?: string, id?: string, class?: string, style?: string }
--:: AudioAttrs  = { src?: string, controls?: boolean, autoplay?: boolean, loop?: boolean, muted?: boolean, id?: string, class?: string }
--:: SourceAttrs = { src?: string, type?: string, srcset?: string, media?: string }
--:: ContainerAttrs = { id?: string, class?: string, style?: string }
--:: ThAttrs     = { colspan?: integer, rowspan?: integer, scope?: string, id?: string, class?: string, style?: string }
--:: TdAttrs     = { colspan?: integer, rowspan?: integer, id?: string, class?: string, style?: string }
--:: TrAttrs     = { id?: string, class?: string, style?: string }
--:: TableAttrs  = { id?: string, class?: string, style?: string }
--:: OlAttrs     = { id?: string, class?: string, style?: string, start?: integer }

-- Document structure ----------------------------------------------------

local _html = element("html")
--: Element<HtmlElement, { lang?: string, [integer]: HeadElement | BodyElement }>
M.html = function(xs) return "<!DOCTYPE html>" .. _html(xs) end

--: Element<HeadElement, { [integer]: HeadContent }>
M.head = element("head")

--: Element<BodyElement, { [integer]: FlowContent, class?: string, id?: string, style?: string }>
M.body = element("body")

-- Metadata elements (void) ---------------------------------------------

--: Element<MetaElement, MetaAttrs>
M.meta = void("meta")

--: Element<LinkElement, LinkAttrs>
M.link = void("link")

--: Element<ScriptElement, ScriptAttrs | { [integer]: string }>
M.script = raw_element("script")

--: Element<StyleElement, { [integer]: string }>
M.style = raw_element("style")

--: Element<TitleElement, { [integer]: string }>
M.title = element("title")

-- Flow content ----------------------------------------------------------

--: Element<DivElement, ContainerAttrs | { [integer]: FlowContent }>
M.div = element("div")

--: Element<SectionElement, ContainerAttrs | { [integer]: FlowContent }>
M.section = element("section")

--: Element<ArticleElement, ContainerAttrs | { [integer]: FlowContent }>
M.article = element("article")

--: Element<AsideElement, ContainerAttrs | { [integer]: FlowContent }>
M.aside = element("aside")

--: Element<HeaderElement, ContainerAttrs | { [integer]: FlowContent }>
M.header = element("header")

--: Element<FooterElement, ContainerAttrs | { [integer]: FlowContent }>
M.footer = element("footer")

--: Element<MainElement, ContainerAttrs | { [integer]: FlowContent }>
M.main = element("main")

--: Element<NavElement, ContainerAttrs | { [integer]: FlowContent }>
M.nav = element("nav")

-- Headings --------------------------------------------------------------

--: Element<H1Element, ContainerAttrs | { [integer]: PhrasingContent }>
M.h1 = element("h1")
--: Element<H2Element, ContainerAttrs | { [integer]: PhrasingContent }>
M.h2 = element("h2")
--: Element<H3Element, ContainerAttrs | { [integer]: PhrasingContent }>
M.h3 = element("h3")
--: Element<H4Element, ContainerAttrs | { [integer]: PhrasingContent }>
M.h4 = element("h4")
--: Element<H5Element, ContainerAttrs | { [integer]: PhrasingContent }>
M.h5 = element("h5")
--: Element<H6Element, ContainerAttrs | { [integer]: PhrasingContent }>
M.h6 = element("h6")

-- Phrasing content ------------------------------------------------------

--: Element<PElement, ContainerAttrs | { [integer]: PhrasingContent }>
M.p = element("p")

--: Element<AElement, AAttrs | { [integer]: PhrasingContent }>
M.a = element("a")

--: Element<SpanElement, ContainerAttrs | { [integer]: PhrasingContent }>
M.span = element("span")

--: Element<EmElement, ContainerAttrs | { [integer]: PhrasingContent }>
M.em = element("em")

--: Element<StrongElement, ContainerAttrs | { [integer]: PhrasingContent }>
M.strong = element("strong")

--: Element<CodeElement, ContainerAttrs | { [integer]: PhrasingContent }>
M.code = element("code")

--: Element<PreElement, ContainerAttrs | { [integer]: PhrasingContent }>
M.pre = element("pre")

--: Element<BlockquoteElement, ContainerAttrs | { [integer]: FlowContent }>
M.blockquote = element("blockquote")

--: Element<IElement, ContainerAttrs | { [integer]: PhrasingContent }>
M.i = element("i")

--: Element<BElement, ContainerAttrs | { [integer]: PhrasingContent }>
M.b = element("b")

--: Element<SmallElement, ContainerAttrs | { [integer]: PhrasingContent }>
M.small = element("small")

--: Element<AbbrElement, ContainerAttrs | { [integer]: PhrasingContent }>
M.abbr = element("abbr")

-- Void phrasing content ------------------------------------------------

--: BrElement
M.br = void("br")({})

--: Element<BrElement, ContainerAttrs>
M.br_ = void("br")

--: Element<HrElement, ContainerAttrs>
M.hr = void("hr")

--: Element<ImgElement, ImgAttrs>
M.img = void("img")

-- Lists -----------------------------------------------------------------

--: Element<UlElement, ContainerAttrs | { [integer]: ListItemContent }>
M.ul = element("ul")

--: Element<OlElement, OlAttrs | { [integer]: ListItemContent }>
M.ol = element("ol")

--: Element<LiElement, ContainerAttrs | { [integer]: FlowContent }>
M.li = element("li")

--: Element<DlElement, ContainerAttrs | { [integer]: DtElement | DdElement }>
M.dl = element("dl")

--: Element<DtElement, ContainerAttrs | { [integer]: PhrasingContent }>
M.dt = element("dt")

--: Element<DdElement, ContainerAttrs | { [integer]: FlowContent }>
M.dd = element("dd")

-- Tables ----------------------------------------------------------------

--: Element<TableElement, TableAttrs | { [integer]: TableSectionContent }>
M.table = element("table")

--: Element<TheadElement, ContainerAttrs | { [integer]: RowContent }>
M.thead = element("thead")

--: Element<TbodyElement, ContainerAttrs | { [integer]: RowContent }>
M.tbody = element("tbody")

--: Element<TfootElement, ContainerAttrs | { [integer]: RowContent }>
M.tfoot = element("tfoot")

--: Element<TrElement, TrAttrs | { [integer]: CellContent }>
M.tr = element("tr")

--: Element<ThElement, ThAttrs | { [integer]: PhrasingContent }>
M.th = element("th")

--: Element<TdElement, TdAttrs | { [integer]: FlowContent }>
M.td = element("td")

-- Forms -----------------------------------------------------------------

--: Element<FormElement, FormAttrs | { [integer]: FlowContent }>
M.form = element("form")

--: Element<InputElement, InputAttrs>
M.input = void("input")

--: Element<LabelElement, LabelAttrs | { [integer]: PhrasingContent }>
M.label = element("label")

--: Element<FieldsetElement, ContainerAttrs | { [integer]: FlowContent }>
M.fieldset = element("fieldset")

--: Element<SelectElement, SelectAttrs | { [integer]: SelectContent }>
M.select = element("select")

--: Element<OptionElement, OptionAttrs | { [integer]: string }>
M.option = element("option")

--: Element<TextareaElement, TextareaAttrs>
M.textarea = element("textarea")

--: Element<ButtonElement, ButtonAttrs | { [integer]: PhrasingContent }>
M.button = element("button")

-- Media -----------------------------------------------------------------

--: Element<IframeElement, { id?: string, class?: string, style?: string, width?: string, height?: string, name?: string, src?: string, [integer]: string }>
M.iframe = element("iframe")

--: Element<VideoElement, VideoAttrs | { [integer]: SourceElement | string }>
M.video = element("video")

--: Element<AudioElement, AudioAttrs | { [integer]: SourceElement | string }>
M.audio = element("audio")

--: Element<SourceElement, SourceAttrs>
M.source = void("source")

-- Graphics --------------------------------------------------------------

--: Element<CanvasElement, { id?: string, class?: string, style?: string, width?: string, height?: string }>
M.canvas = element("canvas")

--: Element<SvgElement, { id?: string, class?: string, style?: string, width?: string, height?: string, viewBox?: string, xmlns?: string, [integer]: string }>
M.svg = element("svg")

-- Utility ---------------------------------------------------------------

--: (s: string) -> string
M.text = escape

return M
