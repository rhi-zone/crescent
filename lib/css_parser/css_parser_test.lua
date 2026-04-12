-- lib/css_parser/css_parser_test.lua

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local CSS = require("lib.css_parser")

-- ── Tokenizer ────────────────────────────────────────────────────────────────

T.describe("tokenize: idents and keywords", function()
  T.it("single ident", function()
    local toks = CSS.tokenize("div")
    T.eq(toks[1].type, "ident")
    T.eq(toks[1].value, "div")
    T.eq(toks[2].type, "eof")
  end)

  T.it("hyphenated ident", function()
    local toks = CSS.tokenize("font-size")
    T.eq(toks[1].type, "ident")
    T.eq(toks[1].value, "font-size")
  end)

  T.it("underscore ident", function()
    local toks = CSS.tokenize("_custom")
    T.eq(toks[1].type, "ident")
    T.eq(toks[1].value, "_custom")
  end)

  T.it("at-keyword @media", function()
    local toks = CSS.tokenize("@media")
    T.eq(toks[1].type, "at_keyword")
    T.eq(toks[1].value, "media")
  end)

  T.it("at-keyword @import", function()
    local toks = CSS.tokenize("@import")
    T.eq(toks[1].type, "at_keyword")
    T.eq(toks[1].value, "import")
  end)

  T.it("at-keyword @keyframes", function()
    local toks = CSS.tokenize("@keyframes")
    T.eq(toks[1].type, "at_keyword")
    T.eq(toks[1].value, "keyframes")
  end)
end)

T.describe("tokenize: strings", function()
  T.it("double-quoted string", function()
    local toks = CSS.tokenize('"hello"')
    T.eq(toks[1].type, "string")
    T.eq(toks[1].value, "hello")
  end)

  T.it("single-quoted string", function()
    local toks = CSS.tokenize("'world'")
    T.eq(toks[1].type, "string")
    T.eq(toks[1].value, "world")
  end)

  T.it("escaped quote in string", function()
    local toks = CSS.tokenize('"say \\"hi\\""')
    T.eq(toks[1].type, "string")
    T.eq(toks[1].value, 'say "hi"')
  end)

  T.it("backslash-n in string becomes newline", function()
    local toks = CSS.tokenize('"line\\nbreak"')
    T.eq(toks[1].type, "string")
    T.eq(toks[1].value, "line\nbreak")
  end)
end)

T.describe("tokenize: numbers, dimensions, percentages", function()
  T.it("integer", function()
    local toks = CSS.tokenize("42")
    T.eq(toks[1].type, "number")
    T.eq(toks[1].value, "42")
  end)

  T.it("float", function()
    local toks = CSS.tokenize("3.14")
    T.eq(toks[1].type, "number")
    T.eq(toks[1].value, "3.14")
  end)

  T.it("negative number", function()
    local toks = CSS.tokenize("-5")
    T.eq(toks[1].type, "number")
    T.eq(toks[1].value, "-5")
  end)

  T.it("dimension px", function()
    local toks = CSS.tokenize("14px")
    T.eq(toks[1].type, "dimension")
    T.eq(toks[1].value, "14")
    T.eq(toks[1].unit, "px")
  end)

  T.it("dimension em", function()
    local toks = CSS.tokenize("2.5em")
    T.eq(toks[1].type, "dimension")
    T.eq(toks[1].value, "2.5")
    T.eq(toks[1].unit, "em")
  end)

  T.it("dimension vw", function()
    local toks = CSS.tokenize("100vw")
    T.eq(toks[1].type, "dimension")
    T.eq(toks[1].value, "100")
    T.eq(toks[1].unit, "vw")
  end)

  T.it("percentage", function()
    local toks = CSS.tokenize("50%")
    T.eq(toks[1].type, "percentage")
    T.eq(toks[1].value, "50")
  end)

  T.it("percentage float", function()
    local toks = CSS.tokenize("12.5%")
    T.eq(toks[1].type, "percentage")
    T.eq(toks[1].value, "12.5")
  end)
end)

T.describe("tokenize: hash", function()
  T.it("hex color", function()
    local toks = CSS.tokenize("#ff0000")
    T.eq(toks[1].type, "hash")
    T.eq(toks[1].value, "ff0000")
  end)

  T.it("named hash", function()
    local toks = CSS.tokenize("#foo")
    T.eq(toks[1].type, "hash")
    T.eq(toks[1].value, "foo")
  end)
end)

T.describe("tokenize: delimiters and brackets", function()
  T.it("colon", function()
    local toks = CSS.tokenize(":")
    T.eq(toks[1].type, "colon")
  end)

  T.it("semicolon", function()
    local toks = CSS.tokenize(";")
    T.eq(toks[1].type, "semicolon")
  end)

  T.it("comma", function()
    local toks = CSS.tokenize(",")
    T.eq(toks[1].type, "comma")
  end)

  T.it("open brace", function()
    local toks = CSS.tokenize("{")
    T.eq(toks[1].type, "open_brace")
  end)

  T.it("close brace", function()
    local toks = CSS.tokenize("}")
    T.eq(toks[1].type, "close_brace")
  end)

  T.it("open bracket", function()
    local toks = CSS.tokenize("[")
    T.eq(toks[1].type, "open_bracket")
  end)

  T.it("close bracket", function()
    local toks = CSS.tokenize("]")
    T.eq(toks[1].type, "close_bracket")
  end)

  T.it("open paren", function()
    local toks = CSS.tokenize("(")
    T.eq(toks[1].type, "open_paren")
  end)

  T.it("close paren", function()
    local toks = CSS.tokenize(")")
    T.eq(toks[1].type, "close_paren")
  end)
end)

T.describe("tokenize: comments stripped", function()
  T.it("comment between tokens", function()
    local toks = CSS.tokenize("div /* comment */ span")
    -- should have: ident, ws, ident, ws, ident, eof (no comment token)
    local types = {}
    for _, t in ipairs(toks) do types[#types+1] = t.type end
    -- verify no "comment" type
    local found_comment = false
    for _, tp in ipairs(types) do
      if tp == "comment" then found_comment = true end
    end
    T.fail(found_comment, "comment token should not appear")
  end)

  T.it("comment at start", function()
    local toks = CSS.tokenize("/* hi */ color")
    T.eq(toks[1].type, "whitespace")
    T.eq(toks[2].type, "ident")
    T.eq(toks[2].value, "color")
  end)

  T.it("multiple comments", function()
    local toks = CSS.tokenize("a /* x */ /* y */ b")
    -- ident a, ws, ws (between comments absorbed), ident b
    local idents = {}
    for _, t in ipairs(toks) do
      if t.type == "ident" then idents[#idents+1] = t.value end
    end
    T.eq(idents[1], "a")
    T.eq(idents[2], "b")
  end)
end)

T.describe("tokenize: function and url", function()
  T.it("function token", function()
    local toks = CSS.tokenize("rgb(")
    T.eq(toks[1].type, "function")
    T.eq(toks[1].value, "rgb")
  end)

  T.it("url with quotes", function()
    local toks = CSS.tokenize('url("image.png")')
    T.eq(toks[1].type, "url")
    T.eq(toks[1].value, "image.png")
  end)

  T.it("url without quotes", function()
    local toks = CSS.tokenize("url(image.png)")
    T.eq(toks[1].type, "url")
    T.eq(toks[1].value, "image.png")
  end)
end)

-- ── Declaration Parser ────────────────────────────────────────────────────────

T.describe("parse_declarations: basic", function()
  T.it("single property", function()
    local decls = CSS.parse_declarations("color: red")
    T.eq(#decls, 1)
    T.eq(decls[1].property, "color")
    T.eq(decls[1].value, "red")
    T.eq(decls[1].important, false)
  end)

  T.it("multiple properties", function()
    local decls = CSS.parse_declarations("color: red; font-size: 14px")
    T.eq(#decls, 2)
    T.eq(decls[1].property, "color")
    T.eq(decls[1].value, "red")
    T.eq(decls[2].property, "font-size")
    T.eq(decls[2].value, "14px")
  end)

  T.it("trailing semicolon", function()
    local decls = CSS.parse_declarations("color: red;")
    T.eq(#decls, 1)
    T.eq(decls[1].property, "color")
  end)

  T.it("whitespace trimmed", function()
    local decls = CSS.parse_declarations("  color :  blue  ")
    T.eq(decls[1].property, "color")
    T.eq(decls[1].value, "blue")
  end)
end)

T.describe("parse_declarations: !important", function()
  T.it("important flag set", function()
    local decls = CSS.parse_declarations("color: red !important")
    T.eq(#decls, 1)
    T.eq(decls[1].property, "color")
    T.eq(decls[1].value, "red")
    T.eq(decls[1].important, true)
  end)

  T.it("important with trailing whitespace", function()
    local decls = CSS.parse_declarations("color: red !important  ")
    T.eq(decls[1].important, true)
    T.eq(decls[1].value, "red")
  end)

  T.it("important in list", function()
    local decls = CSS.parse_declarations("font-size: 12px; color: blue !important")
    T.eq(decls[1].important, false)
    T.eq(decls[2].important, true)
  end)
end)

T.describe("parse_declarations: shorthand values", function()
  T.it("margin shorthand", function()
    local decls = CSS.parse_declarations("margin: 0 auto")
    T.eq(decls[1].property, "margin")
    T.eq(decls[1].value, "0 auto")
  end)

  T.it("border shorthand", function()
    local decls = CSS.parse_declarations("border: 1px solid black")
    T.eq(decls[1].property, "border")
    T.eq(decls[1].value, "1px solid black")
  end)

  T.it("background shorthand", function()
    local decls = CSS.parse_declarations("background: url(img.png) no-repeat center")
    T.eq(decls[1].property, "background")
    T.ok(decls[1].value:find("no-repeat", 1, true) ~= nil)
  end)
end)

-- ── Selector Parser ───────────────────────────────────────────────────────────

T.describe("parse_selector: type selector", function()
  T.it("single element", function()
    local sel = CSS.parse_selector("div")
    T.eq(#sel, 1)
    T.eq(#sel[1], 1)
    T.eq(sel[1][1].type_selector, "div")
  end)

  T.it("universal selector", function()
    local sel = CSS.parse_selector("*")
    T.eq(sel[1][1].type_selector, "*")
  end)
end)

T.describe("parse_selector: class and id", function()
  T.it("class selector", function()
    local sel = CSS.parse_selector(".foo")
    T.eq(#sel[1][1].classes, 1)
    T.eq(sel[1][1].classes[1], "foo")
  end)

  T.it("id selector", function()
    local sel = CSS.parse_selector("#bar")
    T.eq(sel[1][1].id, "bar")
  end)

  T.it("element with class", function()
    local sel = CSS.parse_selector("div.foo")
    T.eq(sel[1][1].type_selector, "div")
    T.eq(sel[1][1].classes[1], "foo")
  end)

  T.it("multiple classes", function()
    local sel = CSS.parse_selector(".a.b.c")
    T.eq(#sel[1][1].classes, 3)
    T.eq(sel[1][1].classes[1], "a")
    T.eq(sel[1][1].classes[2], "b")
    T.eq(sel[1][1].classes[3], "c")
  end)
end)

T.describe("parse_selector: attribute selectors", function()
  T.it("presence attribute", function()
    local sel = CSS.parse_selector("[href]")
    T.eq(#sel[1][1].attributes, 1)
    T.eq(sel[1][1].attributes[1].name, "href")
    T.eq(sel[1][1].attributes[1].op, nil)
  end)

  T.it("exact match attribute", function()
    local sel = CSS.parse_selector('[type="text"]')
    T.eq(sel[1][1].attributes[1].name, "type")
    T.eq(sel[1][1].attributes[1].op, "=")
    T.eq(sel[1][1].attributes[1].value, "text")
  end)

  T.it("prefix match attribute ^=", function()
    local sel = CSS.parse_selector('[href^="https"]')
    T.eq(sel[1][1].attributes[1].op, "^=")
    T.eq(sel[1][1].attributes[1].value, "https")
  end)

  T.it("contains match attribute *=", function()
    local sel = CSS.parse_selector('[class*="btn"]')
    T.eq(sel[1][1].attributes[1].op, "*=")
    T.eq(sel[1][1].attributes[1].value, "btn")
  end)
end)

T.describe("parse_selector: combinators", function()
  T.it("descendant combinator (space)", function()
    local sel = CSS.parse_selector("div span")
    T.eq(#sel[1], 2)
    T.eq(sel[1][1].type_selector, "div")
    T.eq(sel[1][2].type_selector, "span")
    T.eq(sel[1][2].combinator, " ")
  end)

  T.it("child combinator >", function()
    local sel = CSS.parse_selector("ul > li")
    T.eq(#sel[1], 2)
    T.eq(sel[1][2].combinator, ">")
    T.eq(sel[1][2].type_selector, "li")
  end)

  T.it("adjacent sibling +", function()
    local sel = CSS.parse_selector("h1 + p")
    T.eq(sel[1][2].combinator, "+")
    T.eq(sel[1][2].type_selector, "p")
  end)

  T.it("general sibling ~", function()
    local sel = CSS.parse_selector("h1 ~ p")
    T.eq(sel[1][2].combinator, "~")
    T.eq(sel[1][2].type_selector, "p")
  end)

  T.it("chained combinators", function()
    local sel = CSS.parse_selector("div > ul > li")
    T.eq(#sel[1], 3)
    T.eq(sel[1][2].combinator, ">")
    T.eq(sel[1][3].combinator, ">")
  end)
end)

T.describe("parse_selector: multiple selectors (comma)", function()
  T.it("two selectors", function()
    local sel = CSS.parse_selector("h1, h2")
    T.eq(#sel, 2)
    T.eq(sel[1][1].type_selector, "h1")
    T.eq(sel[2][1].type_selector, "h2")
  end)

  T.it("three selectors", function()
    local sel = CSS.parse_selector("h1, h2, h3")
    T.eq(#sel, 3)
  end)

  T.it("complex selectors comma-separated", function()
    local sel = CSS.parse_selector("div.foo > span:hover, a[href]")
    T.eq(#sel, 2)
    -- first: div.foo > span:hover
    T.eq(sel[1][1].type_selector, "div")
    T.eq(sel[1][1].classes[1], "foo")
    T.eq(sel[1][2].type_selector, "span")
    -- second: a[href]
    T.eq(sel[2][1].type_selector, "a")
    T.eq(sel[2][1].attributes[1].name, "href")
  end)
end)

T.describe("parse_selector: pseudo-classes", function()
  T.it(":hover", function()
    local sel = CSS.parse_selector("a:hover")
    T.eq(#sel[1][1].pseudos, 1)
    T.eq(sel[1][1].pseudos[1].name, "hover")
    T.eq(sel[1][1].pseudos[1].element, false)
  end)

  T.it(":first-child", function()
    local sel = CSS.parse_selector("li:first-child")
    T.eq(sel[1][1].pseudos[1].name, "first-child")
  end)

  T.it(":nth-child(2n+1)", function()
    local sel = CSS.parse_selector("li:nth-child(2n+1)")
    T.eq(sel[1][1].pseudos[1].name, "nth-child")
    T.eq(sel[1][1].pseudos[1].functional, true)
    T.eq(sel[1][1].pseudos[1].arg, "2n+1")
  end)

  T.it("::before pseudo-element", function()
    local sel = CSS.parse_selector("p::before")
    T.eq(sel[1][1].pseudos[1].name, "before")
    T.eq(sel[1][1].pseudos[1].element, true)
  end)

  T.it(":not() functional pseudo", function()
    local sel = CSS.parse_selector("li:not(.active)")
    T.eq(sel[1][1].pseudos[1].name, "not")
    T.eq(sel[1][1].pseudos[1].arg, ".active")
  end)
end)

-- ── matches() ────────────────────────────────────────────────────────────────

T.describe("matches: type selector", function()
  T.it("matches by tag", function()
    T.ok(CSS.matches("div", { tag = "div" }))
  end)

  T.it("no match wrong tag", function()
    T.fail(CSS.matches("span", { tag = "div" }))
  end)

  T.it("universal matches any", function()
    T.ok(CSS.matches("*", { tag = "div" }))
    T.ok(CSS.matches("*", { tag = "span" }))
  end)
end)

T.describe("matches: class selector", function()
  T.it("single class match", function()
    T.ok(CSS.matches(".foo", { tag = "div", class = "foo" }))
  end)

  T.it("multi-class element matches one class", function()
    T.ok(CSS.matches(".bar", { tag = "div", class = "foo bar baz" }))
  end)

  T.it("all classes must match", function()
    T.ok(CSS.matches(".foo.bar", { tag = "div", class = "foo bar" }))
    T.fail(CSS.matches(".foo.bar", { tag = "div", class = "foo" }))
  end)

  T.it("no match wrong class", function()
    T.fail(CSS.matches(".active", { tag = "div", class = "foo bar" }))
  end)
end)

T.describe("matches: id selector", function()
  T.it("id match", function()
    T.ok(CSS.matches("#main", { tag = "div", id = "main" }))
  end)

  T.it("no match wrong id", function()
    T.fail(CSS.matches("#main", { tag = "div", id = "other" }))
  end)

  T.it("element + id", function()
    T.ok(CSS.matches("div#main", { tag = "div", id = "main" }))
    T.fail(CSS.matches("span#main", { tag = "div", id = "main" }))
  end)
end)

T.describe("matches: attribute selectors", function()
  T.it("presence", function()
    T.ok(CSS.matches("[href]", { tag = "a", attrs = { href = "http://example.com" } }))
    T.fail(CSS.matches("[href]", { tag = "a", attrs = {} }))
  end)

  T.it("exact match", function()
    T.ok(CSS.matches('[type="text"]', { tag = "input", attrs = { type = "text" } }))
    T.fail(CSS.matches('[type="text"]', { tag = "input", attrs = { type = "email" } }))
  end)

  T.it("prefix match ^=", function()
    T.ok(CSS.matches('[href^="https"]', { tag = "a", attrs = { href = "https://example.com" } }))
    T.fail(CSS.matches('[href^="https"]', { tag = "a", attrs = { href = "http://example.com" } }))
  end)

  T.it("suffix match $=", function()
    T.ok(CSS.matches('[href$=".pdf"]', { tag = "a", attrs = { href = "doc.pdf" } }))
    T.fail(CSS.matches('[href$=".pdf"]', { tag = "a", attrs = { href = "doc.html" } }))
  end)

  T.it("contains match *=", function()
    T.ok(CSS.matches('[class*="btn"]', { tag = "div", attrs = { class = "btn-primary" } }))
    T.fail(CSS.matches('[class*="btn"]', { tag = "div", attrs = { class = "alert" } }))
  end)
end)

T.describe("matches: combinators with parent", function()
  local parent = { tag = "ul", id = nil, class = nil, attrs = {} }
  local child = { tag = "li", class = "item", attrs = {}, parent = parent }

  T.it("child combinator", function()
    T.ok(CSS.matches("ul > li", child))
  end)

  T.it("descendant combinator", function()
    local grandparent = { tag = "nav" }
    local p2 = { tag = "ul", parent = grandparent }
    local c2 = { tag = "li", parent = p2 }
    T.ok(CSS.matches("nav li", c2))
  end)

  T.it("no child match wrong parent", function()
    T.fail(CSS.matches("div > li", child))
  end)
end)

-- ── Specificity ───────────────────────────────────────────────────────────────

T.describe("specificity", function()
  T.it("element selector", function()
    local s = CSS.specificity("div")
    T.eq(s.a, 0); T.eq(s.b, 0); T.eq(s.c, 1)
  end)

  T.it("class selector", function()
    local s = CSS.specificity(".foo")
    T.eq(s.a, 0); T.eq(s.b, 1); T.eq(s.c, 0)
  end)

  T.it("id selector", function()
    local s = CSS.specificity("#bar")
    T.eq(s.a, 1); T.eq(s.b, 0); T.eq(s.c, 0)
  end)

  T.it("element + class", function()
    local s = CSS.specificity("div.foo")
    T.eq(s.a, 0); T.eq(s.b, 1); T.eq(s.c, 1)
  end)

  T.it("element + class + pseudo-class", function()
    local s = CSS.specificity("div.foo > span:hover")
    T.eq(s.a, 0); T.eq(s.b, 2); T.eq(s.c, 2)
  end)

  T.it("id + class + element", function()
    local s = CSS.specificity("#a .b div")
    T.eq(s.a, 1); T.eq(s.b, 1); T.eq(s.c, 1)
  end)

  T.it("attribute selector counts as b", function()
    local s = CSS.specificity("a[href]")
    T.eq(s.a, 0); T.eq(s.b, 1); T.eq(s.c, 1)
  end)

  T.it("pseudo-element counts as c", function()
    local s = CSS.specificity("p::before")
    T.eq(s.a, 0); T.eq(s.b, 0); T.eq(s.c, 2)
  end)

  T.it("specificity_gt higher id wins", function()
    local s1 = CSS.specificity("#id")
    local s2 = CSS.specificity(".cls.cls.cls")
    T.ok(CSS.specificity_gt(s1, s2))
  end)

  T.it("specificity_gt same a, compare b", function()
    local s1 = CSS.specificity(".foo.bar")
    local s2 = CSS.specificity(".baz")
    T.ok(CSS.specificity_gt(s1, s2))
    T.fail(CSS.specificity_gt(s2, s1))
  end)

  T.it("specificity_gt equal specs", function()
    local s1 = CSS.specificity("div")
    local s2 = CSS.specificity("p")
    T.fail(CSS.specificity_gt(s1, s2))
  end)
end)

-- ── Stylesheet Parser ─────────────────────────────────────────────────────────

T.describe("CSS.parse: full stylesheet", function()
  T.it("single style rule", function()
    local ss = CSS.parse("div { color: red; }")
    T.eq(#ss, 1)
    T.eq(ss[1].type, "style_rule")
    T.eq(ss[1].declarations[1].property, "color")
    T.eq(ss[1].declarations[1].value, "red")
  end)

  T.it("multiple style rules", function()
    local ss = CSS.parse("h1 { color: blue; } p { margin: 0; }")
    T.eq(#ss, 2)
    T.eq(ss[1].type, "style_rule")
    T.eq(ss[2].type, "style_rule")
    T.eq(ss[2].declarations[1].property, "margin")
  end)

  T.it("selector parsed correctly", function()
    local ss = CSS.parse("div.foo > span { color: green; }")
    T.eq(ss[1].type, "style_rule")
    local sel = ss[1].selector
    T.eq(#sel, 1)
    T.eq(sel[1][1].type_selector, "div")
    T.eq(sel[1][1].classes[1], "foo")
    T.eq(sel[1][2].type_selector, "span")
  end)

  T.it("@import at-rule", function()
    local ss = CSS.parse('@import "style.css";')
    T.eq(#ss, 1)
    T.eq(ss[1].type, "at_rule")
    T.eq(ss[1].name, "import")
    T.ok(ss[1].prelude:find("style.css") ~= nil)
  end)

  T.it("@media at-rule with nested rules", function()
    local ss = CSS.parse('@media screen { div { color: red; } }')
    T.eq(#ss, 1)
    T.eq(ss[1].type, "at_rule")
    T.eq(ss[1].name, "media")
    T.ok(ss[1].rules ~= nil)
    T.eq(#ss[1].rules, 1)
    T.eq(ss[1].rules[1].type, "style_rule")
    T.eq(ss[1].rules[1].declarations[1].property, "color")
  end)

  T.it("multiple rules with comments", function()
    local css = [[
      /* Header styles */
      h1 { font-size: 2em; }
      /* Paragraph */
      p { line-height: 1.5; }
    ]]
    local ss = CSS.parse(css)
    T.eq(#ss, 2)
    T.eq(ss[1].declarations[1].property, "font-size")
    T.eq(ss[2].declarations[1].property, "line-height")
  end)

  T.it("important in stylesheet", function()
    local ss = CSS.parse("div { color: red !important; }")
    T.eq(ss[1].declarations[1].important, true)
    T.eq(ss[1].declarations[1].value, "red")
  end)
end)

T.describe("CSS._tier", function()
  T.it("is pure", function()
    T.eq(CSS._tier, "pure")
  end)
end)
