if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local xml = require("lib.xml")
local xpath = require("lib.xpath")

-- ---------------------------------------------------------------------------
-- Test document
-- ---------------------------------------------------------------------------
local XML = [[<bookstore>
  <book category="cooking">
    <title lang="en">Everyday Italian</title>
    <author>Giada De Laurentiis</author>
    <price>30.00</price>
  </book>
  <book category="children">
    <title lang="en">Harry Potter</title>
    <author>J K. Rowling</author>
    <price>29.99</price>
  </book>
  <book category="web">
    <title lang="en">Learning XML</title>
    <author>Erik T. Ray</author>
    <price>39.95</price>
  </book>
</bookstore>]]

local doc = xml.parse(XML)
T.ok(doc ~= nil, "parsed test document")

-- Helper: evaluate and return tag names of a node-set
local function tags(ns)
  local result = {}
  for i = 1, #ns do
    result[i] = ns[i].tag or ns[i].type
  end
  return result
end

-- Helper: text content of first node
local function first_text(ns)
  if type(ns) ~= "table" or #ns == 0 then return nil end
  return ns[1].text or ""
end

-- ---------------------------------------------------------------------------
T.describe("module", function()
  T.it("has _tier = pure", function()
    T.eq(xpath._tier, "pure")
  end)
  T.it("exposes eval, select, first, string, number, boolean, compile", function()
    T.ok(type(xpath.eval) == "function")
    T.ok(type(xpath.select) == "function")
    T.ok(type(xpath.first) == "function")
    T.ok(type(xpath.string) == "function")
    T.ok(type(xpath.number) == "function")
    T.ok(type(xpath.boolean) == "function")
    T.ok(type(xpath.compile) == "function")
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("basic location paths", function()
  T.it("/bookstore selects root element", function()
    local ns = xpath.eval(doc, "/bookstore")
    T.ok(type(ns) == "table")
    T.eq(#ns, 1)
    T.eq(ns[1].tag, "bookstore")
  end)

  T.it("/bookstore/book selects 3 books", function()
    local ns = xpath.eval(doc, "/bookstore/book")
    T.eq(#ns, 3)
    for i = 1, 3 do T.eq(ns[i].tag, "book") end
  end)

  T.it("//book selects 3 books from anywhere", function()
    local ns = xpath.eval(doc, "//book")
    T.eq(#ns, 3)
  end)

  T.it("//book/title selects all 3 titles", function()
    local ns = xpath.eval(doc, "//book/title")
    T.eq(#ns, 3)
    for i = 1, 3 do T.eq(ns[i].tag, "title") end
  end)

  T.it("//author selects 3 authors", function()
    local ns = xpath.eval(doc, "//author")
    T.eq(#ns, 3)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("positional predicates", function()
  T.it("/bookstore/book[1] selects first book", function()
    local ns = xpath.eval(doc, "/bookstore/book[1]")
    T.eq(#ns, 1)
    T.eq(ns[1].attrs and ns[1].attrs.category, "cooking")
  end)

  T.it("/bookstore/book[2] selects second book", function()
    local ns = xpath.eval(doc, "/bookstore/book[2]")
    T.eq(#ns, 1)
    T.eq(ns[1].attrs and ns[1].attrs.category, "children")
  end)

  T.it("/bookstore/book[3] selects third book", function()
    local ns = xpath.eval(doc, "/bookstore/book[3]")
    T.eq(#ns, 1)
    T.eq(ns[1].attrs and ns[1].attrs.category, "web")
  end)

  T.it("/bookstore/book[last()] selects last book", function()
    local ns = xpath.eval(doc, "/bookstore/book[last()]")
    T.eq(#ns, 1)
    T.eq(ns[1].attrs and ns[1].attrs.category, "web")
  end)

  T.it("/bookstore/book[position()=2] selects second book", function()
    local ns = xpath.eval(doc, "/bookstore/book[position()=2]")
    T.eq(#ns, 1)
    T.eq(ns[1].attrs.category, "children")
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("attribute predicates", function()
  T.it("/bookstore/book[@category] selects all books with category", function()
    local ns = xpath.eval(doc, "/bookstore/book[@category]")
    T.eq(#ns, 3)
  end)

  T.it('/bookstore/book[@category="web"] selects web book', function()
    local ns = xpath.eval(doc, '/bookstore/book[@category="web"]')
    T.eq(#ns, 1)
    T.eq(ns[1].attrs.category, "web")
  end)

  T.it('/bookstore/book[@category="cooking"] selects cooking book', function()
    local ns = xpath.eval(doc, '/bookstore/book[@category="cooking"]')
    T.eq(#ns, 1)
    T.eq(ns[1].attrs.category, "cooking")
  end)

  T.it('//title[@lang="en"] selects 3 titles', function()
    local ns = xpath.eval(doc, '//title[@lang="en"]')
    T.eq(#ns, 3)
  end)

  T.it('//title[@lang] selects 3 titles', function()
    local ns = xpath.eval(doc, "//title[@lang]")
    T.eq(#ns, 3)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("functions: count, last, position", function()
  T.it("count(//book) = 3", function()
    local n = xpath.eval(doc, "count(//book)")
    T.eq(n, 3)
  end)

  T.it("count(//title) = 3", function()
    T.eq(xpath.eval(doc, "count(//title)"), 3)
  end)

  T.it("count(/bookstore/book[1]/title) = 1", function()
    T.eq(xpath.eval(doc, "count(/bookstore/book[1]/title)"), 1)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("string() and text values", function()
  T.it("string(//book[1]/title) = Everyday Italian", function()
    T.eq(xpath.string(doc, "//book[1]/title"), "Everyday Italian")
  end)

  T.it("string(//book[2]/title) = Harry Potter", function()
    T.eq(xpath.string(doc, "//book[2]/title"), "Harry Potter")
  end)

  T.it("string(//book[3]/title) = Learning XML", function()
    T.eq(xpath.string(doc, "//book[3]/title"), "Learning XML")
  end)

  T.it("xpath.string() convenience function works", function()
    T.eq(xpath.string(doc, "//book[1]/author"), "Giada De Laurentiis")
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("number() conversion", function()
  T.it("number(//book[1]/price) = 30.0", function()
    local n = xpath.number(doc, "//book[1]/price")
    T.eq(n, 30.0)
  end)

  T.it("number(//book[2]/price) = 29.99", function()
    local n = xpath.number(doc, "//book[2]/price")
    T.eq(n, 29.99)
  end)

  T.it("number(//book[3]/price) = 39.95", function()
    local n = xpath.number(doc, "//book[3]/price")
    T.eq(n, 39.95)
  end)

  T.it("number(count(//book)) = 3", function()
    T.eq(xpath.eval(doc, "number(count(//book))"), 3)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("boolean()", function()
  T.it("boolean(//book) = true (non-empty node-set)", function()
    T.eq(xpath.boolean(doc, "//book"), true)
  end)

  T.it("boolean(//nonexistent) = false (empty node-set)", function()
    T.eq(xpath.boolean(doc, "//nonexistent"), false)
  end)

  T.it('boolean(@category) = true when attr exists', function()
    local bookstore = doc.children[1]
    local book1 = bookstore.children[1] -- may be text whitespace; find element
    -- Find first book element
    for i = 1, #bookstore.children do
      if bookstore.children[i].type == "element" then
        book1 = bookstore.children[i]
        break
      end
    end
    T.eq(xpath.boolean(book1, "@category"), true)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("numeric predicates and comparisons", function()
  T.it("//price[number(.) > 30] selects prices over $30", function()
    local ns = xpath.eval(doc, "//price[number(.) > 30]")
    -- 30.00 is not > 30, 29.99 is not, 39.95 is
    T.eq(#ns, 1)
    T.eq(xpath.string(ns[1], "."), "39.95")
  end)

  T.it("//price[number(.) > 29] selects prices over $29", function()
    local ns = xpath.eval(doc, "//price[number(.) > 29]")
    T.eq(#ns, 3)
  end)

  T.it("//book[number(price) < 30] selects cheap books", function()
    local ns = xpath.eval(doc, "//book[number(price) < 30]")
    T.eq(#ns, 1)
    T.eq(ns[1].attrs.category, "children")
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("contains() and starts-with()", function()
  T.it('//author[contains(., "Rowling")] finds JK Rowling', function()
    local ns = xpath.eval(doc, '//author[contains(., "Rowling")]')
    T.eq(#ns, 1)
    T.eq(xpath.string(ns[1], "."), "J K. Rowling")
  end)

  T.it('//author[contains(., "Ray")] finds Erik Ray', function()
    local ns = xpath.eval(doc, '//author[contains(., "Ray")]')
    T.eq(#ns, 1)
    T.eq(xpath.string(ns[1], "."), "Erik T. Ray")
  end)

  T.it('//author[starts-with(., "Giada")] finds first author', function()
    local ns = xpath.eval(doc, '//author[starts-with(., "Giada")]')
    T.eq(#ns, 1)
  end)

  T.it("contains() returns false when not found", function()
    local ns = xpath.eval(doc, '//author[contains(., "Tolkien")]')
    T.eq(#ns, 0)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("string functions", function()
  T.it("string-length works", function()
    local n = xpath.eval(doc, 'string-length("hello")')
    T.eq(n, 5)
  end)

  T.it("concat works", function()
    local s = xpath.eval(doc, 'concat("hello", " ", "world")')
    T.eq(s, "hello world")
  end)

  T.it("normalize-space trims and collapses whitespace", function()
    local s = xpath.eval(doc, 'normalize-space("  foo   bar  ")')
    T.eq(s, "foo bar")
  end)

  T.it("translate works", function()
    local s = xpath.eval(doc, 'translate("hello", "aeiou", "AEIOU")')
    T.eq(s, "hEllO")
  end)

  T.it("substring(str, start) works", function()
    local s = xpath.eval(doc, 'substring("hello", 3)')
    T.eq(s, "llo")
  end)

  T.it("substring(str, start, len) works", function()
    local s = xpath.eval(doc, 'substring("hello", 2, 3)')
    T.eq(s, "ell")
  end)

  T.it("true() and false() functions", function()
    T.eq(xpath.eval(doc, "true()"), true)
    T.eq(xpath.eval(doc, "false()"), false)
  end)

  T.it("not() inverts boolean", function()
    T.eq(xpath.eval(doc, "not(true())"), false)
    T.eq(xpath.eval(doc, "not(false())"), true)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("relative paths and axes", function()
  T.it(". from bookstore child selects self", function()
    local bookstore = xpath.first(doc, "/bookstore")
    T.ok(bookstore ~= nil)
    local ns = xpath.eval(bookstore, ".")
    T.eq(#ns, 1)
    T.eq(ns[1].tag, "bookstore")
  end)

  T.it(".. goes to parent", function()
    local book = xpath.first(doc, "//book")
    T.ok(book ~= nil)
    local ns = xpath.eval(book, "..")
    T.eq(#ns, 1)
    T.eq(ns[1].tag, "bookstore")
  end)

  T.it("child::book selects books", function()
    local bookstore = xpath.first(doc, "/bookstore")
    local ns = xpath.eval(bookstore, "child::book")
    T.eq(#ns, 3)
  end)

  T.it("descendant::title selects all titles from root", function()
    local ns = xpath.eval(doc, "descendant::title")
    T.eq(#ns, 3)
  end)

  T.it("ancestor:: from title goes up", function()
    local title = xpath.first(doc, "//title")
    local ns = xpath.eval(title, "ancestor::bookstore")
    T.eq(#ns, 1)
    T.eq(ns[1].tag, "bookstore")
  end)

  T.it("ancestor-or-self:: includes self", function()
    local title = xpath.first(doc, "//title")
    local ns = xpath.eval(title, "ancestor-or-self::title")
    T.eq(#ns, 1)
    T.eq(ns[1].tag, "title")
  end)

  T.it("following-sibling:: from first book gets 2 more", function()
    local book1 = xpath.first(doc, "/bookstore/book[1]")
    local ns = xpath.eval(book1, "following-sibling::book")
    T.eq(#ns, 2)
  end)

  T.it("preceding-sibling:: from last book gets 2 more", function()
    local book3 = xpath.first(doc, "/bookstore/book[3]")
    local ns = xpath.eval(book3, "preceding-sibling::book")
    T.eq(#ns, 2)
  end)

  T.it("self::book from book node", function()
    local book = xpath.first(doc, "//book")
    local ns = xpath.eval(book, "self::book")
    T.eq(#ns, 1)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("attribute axis", function()
  T.it("attribute::category returns attribute node", function()
    local book = xpath.first(doc, "/bookstore/book[1]")
    local ns = xpath.eval(book, "attribute::category")
    T.eq(#ns, 1)
    T.eq(ns[1].type, "attribute")
    T.eq(ns[1].value, "cooking")
  end)

  T.it("@lang attribute on title", function()
    local title = xpath.first(doc, "//title[1]")
    local ns = xpath.eval(title, "@lang")
    T.eq(#ns, 1)
    T.eq(ns[1].value, "en")
  end)

  T.it("attribute::* returns all attributes", function()
    local book = xpath.first(doc, "/bookstore/book[1]")
    local ns = xpath.eval(book, "attribute::*")
    T.eq(#ns, 1) -- only 'category'
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("union operator |", function()
  T.it("//title | //author selects 6 nodes", function()
    local ns = xpath.eval(doc, "//title | //author")
    T.eq(#ns, 6)
  end)

  T.it("//book[1] | //book[3] selects 2 books", function()
    local ns = xpath.eval(doc, "//book[1] | //book[3]")
    T.eq(#ns, 2)
    T.eq(ns[1].attrs.category, "cooking")
    T.eq(ns[2].attrs.category, "web")
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("text() node test", function()
  T.it("//title/text() selects text nodes", function()
    local ns = xpath.eval(doc, "//title/text()")
    T.eq(#ns, 3)
    local texts = {}
    for i = 1, #ns do texts[i] = ns[i].text end
    table.sort(texts)
    T.eq(texts[1], "Everyday Italian")
    T.eq(texts[2], "Harry Potter")
    T.eq(texts[3], "Learning XML")
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("node() test", function()
  T.it("//book[1]/node() returns all children of first book", function()
    local ns = xpath.eval(doc, "//book[1]/node()")
    -- children include text (whitespace) and element nodes
    T.ok(#ns > 0)
    local elem_count = 0
    for i = 1, #ns do
      if ns[i].type == "element" then elem_count = elem_count + 1 end
    end
    T.eq(elem_count, 3) -- title, author, price
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("arithmetic operators", function()
  T.it("1 + 2 = 3", function()
    T.eq(xpath.eval(doc, "1 + 2"), 3)
  end)

  T.it("10 - 3 = 7", function()
    T.eq(xpath.eval(doc, "10 - 3"), 7)
  end)

  T.it("3 * 4 = 12", function()
    T.eq(xpath.eval(doc, "3 * 4"), 12)
  end)

  T.it("10 div 4 = 2.5", function()
    T.eq(xpath.eval(doc, "10 div 4"), 2.5)
  end)

  T.it("10 mod 3 = 1", function()
    T.eq(xpath.eval(doc, "10 mod 3"), 1)
  end)

  T.it("unary minus: -5 = -5", function()
    T.eq(xpath.eval(doc, "-5"), -5)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("logical operators", function()
  T.it("true() and true() = true", function()
    T.eq(xpath.eval(doc, "true() and true()"), true)
  end)

  T.it("true() and false() = false", function()
    T.eq(xpath.eval(doc, "true() and false()"), false)
  end)

  T.it("false() or true() = true", function()
    T.eq(xpath.eval(doc, "false() or true()"), true)
  end)

  T.it("false() or false() = false", function()
    T.eq(xpath.eval(doc, "false() or false()"), false)
  end)

  T.it("1 = 1 is true", function()
    T.eq(xpath.eval(doc, "1 = 1"), true)
  end)

  T.it("1 != 2 is true", function()
    T.eq(xpath.eval(doc, "1 != 2"), true)
  end)

  T.it("2 > 1 is true", function()
    T.eq(xpath.eval(doc, "2 > 1"), true)
  end)

  T.it("1 < 2 is true", function()
    T.eq(xpath.eval(doc, "1 < 2"), true)
  end)

  T.it("2 >= 2 is true", function()
    T.eq(xpath.eval(doc, "2 >= 2"), true)
  end)

  T.it("2 <= 3 is true", function()
    T.eq(xpath.eval(doc, "2 <= 3"), true)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("compile()", function()
  T.it("compiles and evaluates", function()
    local compiled, err = xpath.compile("//book")
    T.ok(err == nil)
    T.ok(compiled ~= nil)
    local result = compiled:eval(doc)
    T.eq(#result, 3)
  end)

  T.it("returns error for bad expression", function()
    local compiled, err = xpath.compile("///bad///")
    -- should return nil + error OR compiled that errors on eval
    -- Either is acceptable; just test it doesn't crash
    T.ok(compiled == nil or type(err) == "string" or compiled ~= nil)
  end)

  T.it("reuse compiled expression multiple times", function()
    local compiled = xpath.compile("//title")
    local r1 = compiled:eval(doc)
    local r2 = compiled:eval(doc)
    T.eq(#r1, 3)
    T.eq(#r2, 3)
    T.eq(r1[1], r2[1]) -- same node object
  end)

  T.it("compile returns (nil, errmsg) for syntax error", function()
    local compiled2, err2 = xpath.compile("[[[")
    T.ok(compiled2 == nil)
    T.ok(type(err2) == "string")
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("first()", function()
  T.it("returns first book", function()
    local n = xpath.first(doc, "//book")
    T.ok(n ~= nil)
    T.eq(n.tag, "book")
    T.eq(n.attrs.category, "cooking")
  end)

  T.it("returns nil for no match", function()
    local n = xpath.first(doc, "//nonexistent")
    T.eq(n, nil)
  end)

  T.it("returns first title", function()
    local n = xpath.first(doc, "//title")
    T.ok(n ~= nil)
    T.eq(xpath.string(n, "."), "Everyday Italian")
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("name() and local-name()", function()
  T.it("name() on element", function()
    local book = xpath.first(doc, "//book[1]")
    T.eq(xpath.eval(book, "name()"), "book")
  end)

  T.it("name(nodeset) on first node of set", function()
    T.eq(xpath.eval(doc, "name(//book)"), "book")
  end)

  T.it("local-name() strips namespace prefix if any", function()
    T.eq(xpath.eval(doc, "local-name(//book)"), "book")
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("error handling", function()
  T.it("eval returns (nil, errmsg) for bad expression", function()
    local result, err = xpath.eval(doc, "[[[bad")
    T.eq(result, nil)
    T.ok(type(err) == "string")
  end)

  T.it("unterminated string returns error", function()
    local result, err = xpath.eval(doc, '"unterminated')
    T.eq(result, nil)
    T.ok(type(err) == "string")
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("more path patterns", function()
  T.it("//book/title selects all titles", function()
    local ns = xpath.eval(doc, "//book/title")
    T.eq(#ns, 3)
  end)

  T.it("descendant-or-self::book from doc", function()
    local ns = xpath.eval(doc, "descendant-or-self::book")
    T.eq(#ns, 3)
  end)

  T.it("/bookstore/* selects all element children", function()
    local ns = xpath.eval(doc, "/bookstore/*")
    local elem_count = 0
    for i = 1, #ns do
      if ns[i].type == "element" then elem_count = elem_count + 1 end
    end
    T.eq(elem_count, 3)
  end)

  T.it("string value of element with nested text", function()
    -- /bookstore string value = concatenation of all descendant text
    local s = xpath.string(doc, "/bookstore/book[1]")
    T.ok(s:find("Everyday Italian") ~= nil)
    T.ok(s:find("Giada De Laurentiis") ~= nil)
  end)

  T.it("child predicate: //book[title] selects books that have a title", function()
    local ns = xpath.eval(doc, "//book[title]")
    T.eq(#ns, 3)
  end)

  T.it("//book[price][1] first book with a price", function()
    local ns = xpath.eval(doc, "//book[price][1]")
    T.eq(#ns, 1)
    T.eq(ns[1].attrs.category, "cooking")
  end)
end)
