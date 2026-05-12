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
local function escape(s)
	local map = ESCAPE_MAP --[[:! { [string]: string }]]
	local r, _ = s:gsub("[&<>\"']", map)
	return r
end
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
-- These factories return functions typed as `unknown` (the actual return type is
-- a newtype of string; the cast to the newtype is done at each assignment site
-- via `--[[:! Element<T, A>]]`).
--: (string) -> unknown
local function element(tag)
	local function f(xs)
		if type(xs) == "string" then
			return string.format("<%s>%s</%s>", tag, escape(xs), tag)
		end
		local xs_ = xs --[[:! { [string]: unknown, [integer]: unknown }]]
		local parts = { "<", tag, attrs_str(xs_), ">" }
		for i = 1, #xs_ do parts[#parts + 1] = xs_[i] --[[:! string]] end
		parts[#parts + 1] = "</" .. tag .. ">"
		return table.concat(parts) --[[: unknown]]
	end
	return f --[[: unknown]]
end

-- Raw element: children not escaped (for <script>, <style>).
--: (string) -> unknown
local function raw_element(tag)
	local function f(xs)
		if type(xs) == "string" then
			return string.format("<%s>%s</%s>", tag, xs, tag)
		end
		local xs_ = xs --[[:! { [string]: unknown, [integer]: unknown }]]
		local parts = { "<", tag, attrs_str(xs_), ">" }
		for i = 1, #xs_ do parts[#parts + 1] = xs_[i] --[[:! string]] end
		parts[#parts + 1] = "</" .. tag .. ">"
		return table.concat(parts) --[[: unknown]]
	end
	return f --[[: unknown]]
end

-- Void element: no children, self-closing.
--: (string) -> unknown
local function void(tag)
	local function f(xs)
		local xs_ = xs --[[:! { [string]: unknown, [integer]: unknown }]]
		return ("<" .. tag .. attrs_str(xs_ or {}) .. " />") --[[: unknown]]
	end
	return f --[[: unknown]]
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
--:: newtype HtmlElement   = string
--:: newtype HeadElement   = string
--:: newtype BodyElement   = string
--:: newtype DivElement    = string
--:: newtype SectionElement = string
--:: newtype ArticleElement = string
--:: newtype AsideElement  = string
--:: newtype HeaderElement = string
--:: newtype FooterElement = string
--:: newtype MainElement   = string
--:: newtype NavElement    = string
--:: newtype PElement      = string
--:: newtype H1Element     = string
--:: newtype H2Element     = string
--:: newtype H3Element     = string
--:: newtype H4Element     = string
--:: newtype H5Element     = string
--:: newtype H6Element     = string
--:: newtype SpanElement   = string
--:: newtype AElement      = string
--:: newtype EmElement     = string
--:: newtype StrongElement = string
--:: newtype CodeElement   = string
--:: newtype PreElement    = string
--:: newtype BlockquoteElement = string
--:: newtype IElement      = string
--:: newtype BElement      = string
--:: newtype SmallElement  = string
--:: newtype AbbrElement   = string
--:: newtype UlElement     = string
--:: newtype OlElement     = string
--:: newtype LiElement     = string
--:: newtype DlElement     = string
--:: newtype DtElement     = string
--:: newtype DdElement     = string
--:: newtype TableElement  = string
--:: newtype TheadElement  = string
--:: newtype TbodyElement  = string
--:: newtype TfootElement  = string
--:: newtype TrElement     = string
--:: newtype ThElement     = string
--:: newtype TdElement     = string
--:: newtype FormElement   = string
--:: newtype InputElement  = string
--:: newtype LabelElement  = string
--:: newtype FieldsetElement = string
--:: newtype SelectElement = string
--:: newtype OptionElement = string
--:: newtype TextareaElement = string
--:: newtype ButtonElement = string
--:: newtype ImgElement    = string
--:: newtype IframeElement = string
--:: newtype VideoElement  = string
--:: newtype AudioElement  = string
--:: newtype SourceElement = string
--:: newtype CanvasElement = string
--:: newtype SvgElement    = string
--:: newtype StyleElement  = string
--:: newtype ScriptElement = string
--:: newtype MetaElement   = string
--:: newtype LinkElement   = string
--:: newtype TitleElement  = string
--:: newtype BrElement     = string
--:: newtype HrElement     = string
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
--:: GlobalAttrs = { id: (string | nil), class: (string | nil), style: (string | nil), title: (string | nil), hidden: (boolean | nil), tabindex: (integer  | nil)}
--:: AAttrs      = { href: (string | nil), target: (string | nil), rel: (string | nil), download: (string | nil), id: (string | nil), class: (string | nil), style: (string  | nil)}
--:: ButtonAttrs = { type: (string | nil), name: (string | nil), value: (string | nil), disabled: (boolean | nil), form: (string | nil), id: (string | nil), class: (string | nil), style: (string  | nil)}
--:: FormAttrs   = { action: (string | nil), method: (string | nil), enctype: (string | nil), id: (string | nil), class: (string | nil), style: (string  | nil)}
--:: ImgAttrs    = { src: string, alt: string, width: (string | nil), height: (string | nil), loading: (string | nil), id: (string | nil), class: (string | nil), style: (string  | nil)}
--:: InputAttrs  = { type: (string | nil), name: (string | nil), value: (string | nil), placeholder: (string | nil), required: (boolean | nil), disabled: (boolean | nil), checked: (boolean | nil), id: (string | nil), class: (string | nil), style: (string  | nil)}
--:: LabelAttrs  = { for: (string | nil), id: (string | nil), class: (string | nil), style: (string  | nil)}
--:: LinkAttrs   = { rel: string, href: (string | nil), type: (string | nil), media: (string | nil), id: (string | nil), class: (string  | nil)}
--:: MetaAttrs   = { name: (string | nil), content: (string | nil), charset: (string | nil), ["http-equiv"]: (string | nil) }
--:: OptionAttrs = { value: (string | nil), selected: (boolean | nil), disabled: (boolean | nil), id: (string | nil), class: (string  | nil)}
--:: ScriptAttrs = { src: (string | nil), type: (string | nil), async: (boolean | nil), defer: (boolean | nil), id: (string  | nil)}
--:: SelectAttrs = { name: (string | nil), multiple: (boolean | nil), required: (boolean | nil), disabled: (boolean | nil), id: (string | nil), class: (string | nil), style: (string  | nil)}
--:: TextareaAttrs = { name: (string | nil), rows: (integer | nil), cols: (integer | nil), placeholder: (string | nil), required: (boolean | nil), disabled: (boolean | nil), readonly: (boolean | nil), id: (string | nil), class: (string | nil), style: (string  | nil)}
--:: VideoAttrs  = { src: (string | nil), controls: (boolean | nil), autoplay: (boolean | nil), loop: (boolean | nil), muted: (boolean | nil), width: (string | nil), height: (string | nil), id: (string | nil), class: (string | nil), style: (string  | nil)}
--:: AudioAttrs  = { src: (string | nil), controls: (boolean | nil), autoplay: (boolean | nil), loop: (boolean | nil), muted: (boolean | nil), id: (string | nil), class: (string  | nil)}
--:: SourceAttrs = { src: (string | nil), type: (string | nil), srcset: (string | nil), media: (string  | nil)}
--:: ContainerAttrs = { id: (string | nil), class: (string | nil), style: (string  | nil)}
--:: ThAttrs     = { colspan: (integer | nil), rowspan: (integer | nil), scope: (string | nil), id: (string | nil), class: (string | nil), style: (string  | nil)}
--:: TdAttrs     = { colspan: (integer | nil), rowspan: (integer | nil), id: (string | nil), class: (string | nil), style: (string  | nil)}
--:: TrAttrs     = { id: (string | nil), class: (string | nil), style: (string  | nil)}
--:: TableAttrs  = { id: (string | nil), class: (string | nil), style: (string  | nil)}
--:: OlAttrs     = { id: (string | nil), class: (string | nil), style: (string | nil), start: (integer  | nil)}

-- Document structure ----------------------------------------------------

M.html = (function(xs) --[[:! { lang: (string | nil), [integer]: HeadElement | BodyElement, [string]: unknown }]]
  local inner_fn = element("html") --[[:! ({ [integer]: unknown, [string]: unknown }) -> string]]
  return ("<!DOCTYPE html>" .. inner_fn(xs)) --[[: unknown]]
end) --[[:! Element<HtmlElement, { lang: (string | nil), [integer]: HeadElement | BodyElement }>]]

M.head = element("head") --[[:! Element<HeadElement, { [integer]: HeadContent }>]]

M.body = element("body") --[[:! Element<BodyElement, { [integer]: FlowContent, class: (string | nil), id: (string | nil), style: (string  | nil)}>]]

-- Metadata elements (void) ---------------------------------------------

M.meta = void("meta") --[[:! Element<MetaElement, MetaAttrs>]]

M.link = void("link") --[[:! Element<LinkElement, LinkAttrs>]]

M.script = raw_element("script") --[[:! Element<ScriptElement, ScriptAttrs | { [integer]: string }>]]

M.style = raw_element("style") --[[:! Element<StyleElement, { [integer]: string }>]]

M.title = element("title") --[[:! Element<TitleElement, { [integer]: string }>]]

-- Flow content ----------------------------------------------------------

M.div = element("div") --[[:! Element<DivElement, ContainerAttrs | { [integer]: FlowContent }>]]

M.section = element("section") --[[:! Element<SectionElement, ContainerAttrs | { [integer]: FlowContent }>]]

M.article = element("article") --[[:! Element<ArticleElement, ContainerAttrs | { [integer]: FlowContent }>]]

M.aside = element("aside") --[[:! Element<AsideElement, ContainerAttrs | { [integer]: FlowContent }>]]

M.header = element("header") --[[:! Element<HeaderElement, ContainerAttrs | { [integer]: FlowContent }>]]

M.footer = element("footer") --[[:! Element<FooterElement, ContainerAttrs | { [integer]: FlowContent }>]]

M.main = element("main") --[[:! Element<MainElement, ContainerAttrs | { [integer]: FlowContent }>]]

M.nav = element("nav") --[[:! Element<NavElement, ContainerAttrs | { [integer]: FlowContent }>]]

-- Headings --------------------------------------------------------------

M.h1 = element("h1") --[[:! Element<H1Element, ContainerAttrs | { [integer]: PhrasingContent }>]]
M.h2 = element("h2") --[[:! Element<H2Element, ContainerAttrs | { [integer]: PhrasingContent }>]]
M.h3 = element("h3") --[[:! Element<H3Element, ContainerAttrs | { [integer]: PhrasingContent }>]]
M.h4 = element("h4") --[[:! Element<H4Element, ContainerAttrs | { [integer]: PhrasingContent }>]]
M.h5 = element("h5") --[[:! Element<H5Element, ContainerAttrs | { [integer]: PhrasingContent }>]]
M.h6 = element("h6") --[[:! Element<H6Element, ContainerAttrs | { [integer]: PhrasingContent }>]]

-- Phrasing content ------------------------------------------------------

M.p = element("p") --[[:! Element<PElement, ContainerAttrs | { [integer]: PhrasingContent }>]]

M.a = element("a") --[[:! Element<AElement, AAttrs | { [integer]: PhrasingContent }>]]

M.span = element("span") --[[:! Element<SpanElement, ContainerAttrs | { [integer]: PhrasingContent }>]]

M.em = element("em") --[[:! Element<EmElement, ContainerAttrs | { [integer]: PhrasingContent }>]]

M.strong = element("strong") --[[:! Element<StrongElement, ContainerAttrs | { [integer]: PhrasingContent }>]]

M.code = element("code") --[[:! Element<CodeElement, ContainerAttrs | { [integer]: PhrasingContent }>]]

M.pre = element("pre") --[[:! Element<PreElement, ContainerAttrs | { [integer]: PhrasingContent }>]]

M.blockquote = element("blockquote") --[[:! Element<BlockquoteElement, ContainerAttrs | { [integer]: FlowContent }>]]

M.i = element("i") --[[:! Element<IElement, ContainerAttrs | { [integer]: PhrasingContent }>]]

M.b = element("b") --[[:! Element<BElement, ContainerAttrs | { [integer]: PhrasingContent }>]]

M.small = element("small") --[[:! Element<SmallElement, ContainerAttrs | { [integer]: PhrasingContent }>]]

M.abbr = element("abbr") --[[:! Element<AbbrElement, ContainerAttrs | { [integer]: PhrasingContent }>]]

-- Void phrasing content ------------------------------------------------

M.br = ((void("br") --[[:! ({ [string]: unknown }) -> string]])({}) --[[: unknown]]) --[[:! BrElement]]

M.br_ = void("br") --[[:! Element<BrElement, ContainerAttrs>]]

M.hr = void("hr") --[[:! Element<HrElement, ContainerAttrs>]]

M.img = void("img") --[[:! Element<ImgElement, ImgAttrs>]]

-- Lists -----------------------------------------------------------------

M.ul = element("ul") --[[:! Element<UlElement, ContainerAttrs | { [integer]: ListItemContent }>]]

M.ol = element("ol") --[[:! Element<OlElement, OlAttrs | { [integer]: ListItemContent }>]]

M.li = element("li") --[[:! Element<LiElement, ContainerAttrs | { [integer]: FlowContent }>]]

M.dl = element("dl") --[[:! Element<DlElement, ContainerAttrs | { [integer]: DtElement | DdElement }>]]

M.dt = element("dt") --[[:! Element<DtElement, ContainerAttrs | { [integer]: PhrasingContent }>]]

M.dd = element("dd") --[[:! Element<DdElement, ContainerAttrs | { [integer]: FlowContent }>]]

-- Tables ----------------------------------------------------------------

M.table = element("table") --[[:! Element<TableElement, TableAttrs | { [integer]: TableSectionContent }>]]

M.thead = element("thead") --[[:! Element<TheadElement, ContainerAttrs | { [integer]: RowContent }>]]

M.tbody = element("tbody") --[[:! Element<TbodyElement, ContainerAttrs | { [integer]: RowContent }>]]

M.tfoot = element("tfoot") --[[:! Element<TfootElement, ContainerAttrs | { [integer]: RowContent }>]]

M.tr = element("tr") --[[:! Element<TrElement, TrAttrs | { [integer]: CellContent }>]]

M.th = element("th") --[[:! Element<ThElement, ThAttrs | { [integer]: PhrasingContent }>]]

M.td = element("td") --[[:! Element<TdElement, TdAttrs | { [integer]: FlowContent }>]]

-- Forms -----------------------------------------------------------------

M.form = element("form") --[[:! Element<FormElement, FormAttrs | { [integer]: FlowContent }>]]

M.input = void("input") --[[:! Element<InputElement, InputAttrs>]]

M.label = element("label") --[[:! Element<LabelElement, LabelAttrs | { [integer]: PhrasingContent }>]]

M.fieldset = element("fieldset") --[[:! Element<FieldsetElement, ContainerAttrs | { [integer]: FlowContent }>]]

M.select = element("select") --[[:! Element<SelectElement, SelectAttrs | { [integer]: SelectContent }>]]

M.option = element("option") --[[:! Element<OptionElement, OptionAttrs | { [integer]: string }>]]

M.textarea = element("textarea") --[[:! Element<TextareaElement, TextareaAttrs>]]

M.button = element("button") --[[:! Element<ButtonElement, ButtonAttrs | { [integer]: PhrasingContent }>]]

-- Media -----------------------------------------------------------------

M.iframe = element("iframe") --[[:! Element<IframeElement, { id: (string | nil), class: (string | nil), style: (string | nil), width: (string | nil), height: (string | nil), name: (string | nil), src: (string | nil), [integer]: string }>]]

M.video = element("video") --[[:! Element<VideoElement, VideoAttrs | { [integer]: SourceElement | string }>]]

M.audio = element("audio") --[[:! Element<AudioElement, AudioAttrs | { [integer]: SourceElement | string }>]]

M.source = void("source") --[[:! Element<SourceElement, SourceAttrs>]]

-- Graphics --------------------------------------------------------------

M.canvas = element("canvas") --[[:! Element<CanvasElement, { id: (string | nil), class: (string | nil), style: (string | nil), width: (string | nil), height: (string  | nil)}>]]

M.svg = element("svg") --[[:! Element<SvgElement, { id: (string | nil), class: (string | nil), style: (string | nil), width: (string | nil), height: (string | nil), viewBox: (string | nil), xmlns: (string | nil), [integer]: string }>]]

-- Utility ---------------------------------------------------------------

M.text = escape --[[:! (s: string) -> string]]

return M

