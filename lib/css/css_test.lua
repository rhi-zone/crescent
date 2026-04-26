if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local css = require("lib.css")

T.describe("css constructors", function()
  T.it("class returns the name string", function()
    T.eq(css.class("btn"), "btn")
  end)
  T.it("id returns the name string", function()
    T.eq(css.id("root"), "root")
  end)
  T.it("var returns the var name", function()
    T.eq(css.var("--brand"), "--brand")
  end)
  T.it("var errors on non-double-dash", function()
    T.throws(function() css.var("brand") end)
  end)
  T.it("anim returns the name string", function()
    T.eq(css.anim("slide-in"), "slide-in")
  end)
  T.it("varref renders var() syntax", function()
    T.eq(css.varref("--brand"), "var(--brand)")
  end)
end)

T.describe("css.declare", function()
  T.it("returns structured record", function()
    local S = css.declare {
      classes = { btn = "btn", card = "card" },
      ids = { root = "root" },
      vars = { brand = "--brand" },
      anims = { slide_in = "slide-in" },
    }
    T.eq(S.classes.btn, "btn")
    T.eq(S.classes.card, "card")
    T.eq(S.ids.root, "root")
    T.eq(S.vars.brand, "--brand")
    T.eq(S.anims.slide_in, "slide-in")
  end)
end)

T.describe("selector DSL", function()
  local sel = css.sel
  T.it("class selector", function()
    T.eq(sel.class("btn")._str, ".btn")
  end)
  T.it("id selector", function()
    T.eq(sel.id("root")._str, "#root")
  end)
  T.it("tag selector", function()
    T.eq(sel.tag("div")._str, "div")
  end)
  T.it("universal selector", function()
    T.eq(sel.universal()._str, "*")
  end)
  T.it("descendant combinator", function()
    T.eq(sel.class("btn"):desc(sel.tag("span"))._str, ".btn span")
  end)
  T.it("child combinator", function()
    T.eq(sel.class("btn"):child(sel.id("root"))._str, ".btn > #root")
  end)
  T.it("adjacent sibling", function()
    T.eq(sel.tag("h1"):adjacent(sel.tag("p"))._str, "h1 + p")
  end)
  T.it("general sibling", function()
    T.eq(sel.tag("h1"):sibling(sel.tag("p"))._str, "h1 ~ p")
  end)
  T.it("compound selector", function()
    T.eq(sel.class("btn"):and_(sel.class("primary"))._str, ".btn.primary")
  end)
  T.it("pseudo-class", function()
    T.eq(sel.class("btn"):pseudo("hover")._str, ".btn:hover")
  end)
  T.it("attribute presence", function()
    T.eq(sel.tag("input"):attr("disabled")._str, "input[disabled]")
  end)
  T.it("attribute equality", function()
    T.eq(sel.tag("input"):attr_eq("type", "text")._str, 'input[type="text"]')
  end)
  T.it("selector list", function()
    T.eq(sel.list(sel.tag("h1"), sel.tag("h2"), sel.tag("h3"))._str, "h1, h2, h3")
  end)
end)

T.describe("render", function()
  T.it("renders a rule with kebab-case properties", function()
    local rule = css.rule(css.sel.class("btn"), {
      color = "white",
      background_color = "blue",
    })
    local rendered = css.render_rule(rule)
    -- check selector and both properties appear
    T.ok(rendered:find("%.btn {"), "has selector")
    T.ok(rendered:find("background%-color: blue;"), "has background-color")
    T.ok(rendered:find("color: white;"), "has color")
  end)
  T.it("varref renders correctly in a rule", function()
    local rule = css.rule(css.sel.class("btn"), {
      color = css.varref("--brand"),
    })
    local rendered = css.render_rule(rule)
    T.ok(rendered:find("color: var%(%-%-brand%);"), "has var() reference")
  end)
  T.it("render_selector on selector object", function()
    T.eq(css.render_selector(css.sel.tag("div")), "div")
  end)
  T.it("full stylesheet render", function()
    local sheet = css.stylesheet({
      css.rule(css.sel.class("a"), { color = "red" }),
      css.rule(css.sel.class("b"), { color = "blue" }),
    })
    local out = css.render(sheet)
    T.ok(out:find("%.a {"), "has .a")
    T.ok(out:find("%.b {"), "has .b")
  end)
  T.it("snapshot: representative stylesheet", function()
    local S = css.declare {
      classes = { btn = "btn" },
      ids = { root = "root" },
      vars = { brand = "--brand", radius = "--radius" },
      anims = {},
    }
    local sheet = css.stylesheet({
      css.rule(css.sel.tag(":root"), {
        [S.vars.brand] = "#3366ff",
        [S.vars.radius] = "8px",
      }),
      css.rule(css.sel.class(S.classes.btn), {
        color = "white",
        background_color = css.varref(S.vars.brand),
        border_radius = css.varref(S.vars.radius),
      }),
    })
    local out = css.render(sheet)
    T.ok(out:find(":root {"), ":root rule")
    T.ok(out:find("%-%-brand: #3366ff;"), "var declaration")
    T.ok(out:find("background%-color: var%(%-%-brand%);"), "var reference")
    T.ok(out:find("border%-radius: var%(%-%-radius%);"), "border-radius kebab")
  end)
end)

T.describe("keyframes", function()
  T.it("constructs keyframe rule with _type", function()
    local kf = css.keyframes(css.anim("slide-in"), {
      from = { transform = "translateX(-100%)" },
      to   = { transform = "translateX(0)" },
    })
    T.eq(kf._type, "keyframes")
    T.eq(kf.name, "slide-in")
  end)
  T.it("render_keyframes produces correct output", function()
    local kf = css.keyframes("slide-in", {
      from = { transform = "translateX(-100%)" },
      to   = { transform = "translateX(0)" },
    })
    local out = css.render_keyframes(kf)
    T.ok(out:find("@keyframes slide%-in {"), "has @keyframes header")
    T.ok(out:find("from {"), "has from stop")
    T.ok(out:find("to {"), "has to stop")
    T.ok(out:find("transform: translateX(-100%);", 1, true), "has from transform")
    T.ok(out:find("transform: translateX(0);", 1, true), "has to transform")
  end)
  T.it("keyframes in stylesheet renders via css.render", function()
    local sheet = css.stylesheet({
      css.keyframes("fade", {
        ["0%"]   = { opacity = "0" },
        ["100%"] = { opacity = "1" },
      }),
    })
    local out = css.render(sheet)
    T.ok(out:find("@keyframes fade"), "has keyframes block")
    T.ok(out:find("0%% {"), "has 0%% stop")
    T.ok(out:find("100%% {"), "has 100%% stop")
  end)
  T.it("stops sorted from/to/percentages deterministically", function()
    local kf = css.keyframes("bounce", {
      to   = { transform = "scale(1)" },
      ["50%"] = { transform = "scale(1.1)" },
      from = { transform = "scale(0.9)" },
    })
    local out = css.render_keyframes(kf)
    local from_pos = out:find("from {")
    local mid_pos  = out:find("50%% {")
    local to_pos   = out:find("to {")
    T.ok(from_pos < mid_pos, "from before 50%")
    T.ok(mid_pos  < to_pos,  "50% before to")
  end)
end)

T.describe("media queries", function()
  T.it("min_width query string", function()
    T.eq(css.mq.min_width("768px")._q, "(min-width: 768px)")
  end)
  T.it("max_width query string", function()
    T.eq(css.mq.max_width("1024px")._q, "(max-width: 1024px)")
  end)
  T.it("prefers-color-scheme query", function()
    T.eq(css.mq.prefers_color_scheme("dark")._q, "(prefers-color-scheme: dark)")
  end)
  T.it("orientation query", function()
    T.eq(css.mq.orientation("landscape")._q, "(orientation: landscape)")
  end)
  T.it("and_ combinator", function()
    local q = css.mq.min_width("768px"):and_(css.mq.max_width("1024px"))
    T.eq(q._q, "(min-width: 768px) and (max-width: 1024px)")
  end)
  T.it("or_ combinator (comma-separated)", function()
    local q = css.mq.screen:or_(css.mq.print)
    T.eq(q._q, "screen, print")
  end)
  T.it("not_ negation", function()
    local q = css.mq.prefers_color_scheme("dark"):not_()
    T.eq(q._q, "not (prefers-color-scheme: dark)")
  end)
  T.it("raw string query accepted", function()
    local block = css.media("(min-width: 600px)", {})
    T.eq(block.query, "(min-width: 600px)")
  end)
  T.it("media block renders @media header", function()
    local block = css.media(css.mq.min_width("768px"), {
      css.rule(css.sel.class("btn"), { padding = "12px 24px" }),
    })
    local out = css.render_media(block)
    T.ok(out:find("@media %(min%-width: 768px%) {"), "has @media header")
    T.ok(out:find("%.btn {"), "has nested rule selector")
    T.ok(out:find("padding: 12px 24px;"), "has nested declaration")
  end)
  T.it("media in stylesheet renders via css.render", function()
    local sheet = css.stylesheet({
      css.media("screen", {
        css.rule(css.sel.tag("body"), { margin = "0" }),
      }),
    })
    local out = css.render(sheet)
    T.ok(out:find("@media screen {"), "has @media block")
    T.ok(out:find("body {"), "has nested body rule")
  end)
  T.it("nested media queries", function()
    local inner = css.media(css.mq.orientation("landscape"), {
      css.rule(css.sel.tag("aside"), { display = "none" }),
    })
    local outer = css.media(css.mq.min_width("768px"), { inner })
    local out = css.render_media(outer)
    T.ok(out:find("@media %(min%-width: 768px%) {"), "outer media")
    T.ok(out:find("@media %(orientation: landscape%) {"), "inner media")
  end)
end)

T.describe("@property rules", function()
  T.it("constructs @property rule", function()
    local p = css.property_rule("--brand", {
      syntax = "<color>",
      inherits = false,
      initial_value = "#000",
    })
    T.eq(p._type, "property")
    T.eq(p.name, "--brand")
    T.eq(p.syntax, "<color>")
    T.eq(p.inherits, false)
    T.eq(p.initial_value, "#000")
  end)
  T.it("errors on non-double-dash name", function()
    T.throws(function()
      css.property_rule("brand", { syntax = "<color>", inherits = false })
    end)
  end)
  T.it("errors when syntax missing", function()
    T.throws(function()
      css.property_rule("--brand", { inherits = false })
    end)
  end)
  T.it("render_property output", function()
    local p = css.property_rule("--radius", {
      syntax = "<length>",
      inherits = false,
      initial_value = "0px",
    })
    local out = css.render_property(p)
    T.ok(out:find("@property %-%-radius {"), "has @property header")
    T.ok(out:find('syntax: "<length>";'), "has syntax")
    T.ok(out:find("inherits: false;"), "has inherits")
    T.ok(out:find("initial%-value: 0px;"), "has initial-value")
  end)
  T.it("render_property without initial_value", function()
    local p = css.property_rule("--color", {
      syntax = "<color>",
      inherits = true,
    })
    local out = css.render_property(p)
    T.ok(not out:find("initial%-value"), "no initial-value line")
    T.ok(out:find("inherits: true;"), "has inherits true")
  end)
  T.it("@property in stylesheet renders via css.render", function()
    local sheet = css.stylesheet({
      css.property_rule("--brand", { syntax = "<color>", inherits = false, initial_value = "#fff" }),
      css.rule(css.sel.tag("body"), { color = css.varref("--brand") }),
    })
    local out = css.render(sheet)
    T.ok(out:find("@property %-%-brand"), "has @property")
    T.ok(out:find("body {"), "has body rule")
  end)
end)

T.describe("embed stylesheet", function()
  T.it("returns a style block string", function()
    local sheet = css.stylesheet({
      css.rule(css.sel.class("btn"), { color = "white", background_color = "blue" }),
    })
    local style_block, _ = css.embed(sheet)
    T.ok(style_block:find("<style>"), "has <style> open")
    T.ok(style_block:find("</style>"), "has </style> close")
    T.ok(style_block:find("%.btn {"), "has .btn rule")
  end)
  T.it("returns class name for simple class selectors", function()
    local sheet = css.stylesheet({
      css.rule(css.sel.class("btn"), { color = "white" }),
      css.rule(css.sel.class("card"), { padding = "1rem" }),
    })
    local _, classes = css.embed(sheet)
    T.eq(classes.btn,  "btn",  "btn class value")
    T.eq(classes.card, "card", "card class value")
  end)
  T.it("does not expose complex selectors as class names", function()
    local sheet = css.stylesheet({
      css.rule(css.sel.class("btn"):pseudo("hover"), { opacity = "0.9" }),
      css.rule(css.sel.class("btn"):child(css.sel.tag("span")), { color = "red" }),
    })
    local _, classes = css.embed(sheet)
    T.eq(classes.btn, nil, "complex selectors not exposed")
  end)
  T.it("media-nested rules appear in style block but not classes", function()
    local sheet = css.stylesheet({
      css.rule(css.sel.class("hero"), { font_size = "2rem" }),
      css.media("screen", {
        css.rule(css.sel.class("hero"), { font_size = "3rem" }),
      }),
    })
    local style_block, classes = css.embed(sheet)
    T.ok(style_block:find("@media screen"), "media appears in style block")
    T.eq(classes.hero, "hero", "top-level class still exposed")
  end)
  T.it("classes can be used directly as html class attribute values", function()
    local sheet = css.stylesheet({
      css.rule(css.sel.class("container"), { max_width = "1200px" }),
    })
    local _, classes = css.embed(sheet)
    -- At runtime, ClassName is just a string — usable directly as class=""
    T.eq(type(classes.container), "string")
    T.eq(classes.container, "container")
  end)
end)

T.describe("scope analysis", function()
  T.it("detects declared vars", function()
    local sheet = css.stylesheet({
      css.rule(css.sel.tag(":root"), {
        ["--brand"] = "#3366ff",
        ["--radius"] = "8px",
      }),
    })
    local report = css.analyze(sheet, { "--brand", "--radius" })
    T.eq(#report["--brand"].declared, 1)
    T.eq(report["--brand"].declared[1], ":root")
    T.eq(#report["--radius"].declared, 1)
  end)
  T.it("detects referenced vars", function()
    local sheet = css.stylesheet({
      css.rule(css.sel.class("btn"), {
        color = css.varref("--brand"),
        border_radius = css.varref("--radius"),
      }),
    })
    local report = css.analyze(sheet, { "--brand", "--radius" })
    T.eq(#report["--brand"].referenced, 1)
    T.eq(report["--brand"].referenced[1], ".btn")
    T.eq(#report["--radius"].referenced, 1)
  end)
  T.it("detects @property registrations", function()
    local sheet = css.stylesheet({
      css.property_rule("--brand", { syntax = "<color>", inherits = false }),
    })
    local report = css.analyze(sheet, { "--brand" })
    T.eq(report["--brand"].registered, true)
  end)
  T.it("unmentioned var has empty declared/referenced", function()
    local sheet = css.stylesheet({
      css.rule(css.sel.tag("body"), { color = "red" }),
    })
    local report = css.analyze(sheet, { "--brand" })
    T.eq(#report["--brand"].declared, 0)
    T.eq(#report["--brand"].referenced, 0)
    T.eq(report["--brand"].registered, false)
  end)
  T.it("vars inside @media are detected", function()
    local sheet = css.stylesheet({
      css.media("screen", {
        css.rule(css.sel.tag(":root"), { ["--brand"] = "blue" }),
      }),
    })
    local report = css.analyze(sheet, { "--brand" })
    T.eq(#report["--brand"].declared, 1)
  end)
end)
