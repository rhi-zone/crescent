-- lib/rehype_highlight/rehype_highlight_test.lua
-- Tests for the rehype_highlight plugin.

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T    = require("lib.test.assert")
local hast = require("lib.hast")
local rh   = require("lib.rehype_highlight")

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Build a minimal hast tree: root > pre > code[class=language-X] > text
local function make_code_tree(lang, src)
  local code_props = {}
  if lang then
    code_props.class = "language-" .. lang
  end
  local code_node = {
    type = "element", tag = "code",
    props = code_props,
    children = { { type = "text", value = src } },
  }
  local pre_node = {
    type = "element", tag = "pre",
    props = {},
    children = { code_node },
  }
  return { type = "root", children = { pre_node } }, pre_node, code_node
end

-- Serialize to HTML using hast.to_html for inspection.
local function to_html(tree)
  return hast.to_html(tree)
end

-- Check whether the highlighted children include a span of the given kind.
local function has_span(code_node, kind, text)
  for _, child in ipairs(code_node.children) do
    if child.type == "element" and child.tag == "span" then
      local cls = (child.props or {}).class or ""
      if cls == kind then
        if text == nil then return true end
        local first = child.children and child.children[1]
        if first and first.value == text then return true end
      end
    end
  end
  return false
end

-- ── Lua highlighting ──────────────────────────────────────────────────────────

T.describe("lua highlighting", function()
  T.it("wraps keywords in hljs-keyword spans", function()
    local tree, pre, code = make_code_tree("lua", "local x = 1\nreturn x")
    rh.plugin(
      { use_transformer = function(self, fn)
          self._fn = fn
        end,
        _fn = nil,
      },
      nil
    )
    -- Use the transformer directly via a fake processor
    local proc = {
      _fns = {},
      use_transformer = function(self, fn) self._fns[#self._fns + 1] = fn end,
    }
    rh.plugin(proc, nil)
    for _, fn in ipairs(proc._fns) do fn(tree) end

    T.ok(has_span(code, "hljs-keyword", "local"), "local keyword")
    T.ok(has_span(code, "hljs-keyword", "return"), "return keyword")
  end)

  T.it("wraps strings in hljs-string spans", function()
    local tree, pre, code = make_code_tree("lua", 'local s = "hello"')
    local proc = { _fns = {}, use_transformer = function(self, fn) self._fns[#self._fns + 1] = fn end }
    rh.plugin(proc, nil)
    for _, fn in ipairs(proc._fns) do fn(tree) end

    T.ok(has_span(code, "hljs-string", '"hello"'), "double-quoted string")
  end)

  T.it("wraps single-quoted strings", function()
    local tree, pre, code = make_code_tree("lua", "local s = 'world'")
    local proc = { _fns = {}, use_transformer = function(self, fn) self._fns[#self._fns + 1] = fn end }
    rh.plugin(proc, nil)
    for _, fn in ipairs(proc._fns) do fn(tree) end

    T.ok(has_span(code, "hljs-string", "'world'"), "single-quoted string")
  end)

  T.it("wraps line comments in hljs-comment spans", function()
    local tree, pre, code = make_code_tree("lua", "-- this is a comment\nlocal x = 1")
    local proc = { _fns = {}, use_transformer = function(self, fn) self._fns[#self._fns + 1] = fn end }
    rh.plugin(proc, nil)
    for _, fn in ipairs(proc._fns) do fn(tree) end

    T.ok(has_span(code, "hljs-comment", "-- this is a comment"), "line comment")
  end)

  T.it("wraps literals (true/false/nil) in hljs-literal spans", function()
    local tree, pre, code = make_code_tree("lua", "local a = true\nlocal b = false\nlocal c = nil")
    local proc = { _fns = {}, use_transformer = function(self, fn) self._fns[#self._fns + 1] = fn end }
    rh.plugin(proc, nil)
    for _, fn in ipairs(proc._fns) do fn(tree) end

    T.ok(has_span(code, "hljs-literal", "true"), "true literal")
    T.ok(has_span(code, "hljs-literal", "false"), "false literal")
    T.ok(has_span(code, "hljs-literal", "nil"), "nil literal")
  end)

  T.it("wraps numbers in hljs-number spans", function()
    local tree, pre, code = make_code_tree("lua", "local n = 42")
    local proc = { _fns = {}, use_transformer = function(self, fn) self._fns[#self._fns + 1] = fn end }
    rh.plugin(proc, nil)
    for _, fn in ipairs(proc._fns) do fn(tree) end

    T.ok(has_span(code, "hljs-number", "42"), "number")
  end)

  T.it("adds hljs class to pre element", function()
    local tree, pre, code = make_code_tree("lua", "return 1")
    local proc = { _fns = {}, use_transformer = function(self, fn) self._fns[#self._fns + 1] = fn end }
    rh.plugin(proc, nil)
    for _, fn in ipairs(proc._fns) do fn(tree) end

    T.eq((pre.props or {}).class, "hljs", "pre gets hljs class")
  end)

  T.it("block comments", function()
    local tree, pre, code = make_code_tree("lua", "--[[ block\ncomment ]]")
    local proc = { _fns = {}, use_transformer = function(self, fn) self._fns[#self._fns + 1] = fn end }
    rh.plugin(proc, nil)
    for _, fn in ipairs(proc._fns) do fn(tree) end

    T.ok(has_span(code, "hljs-comment", "--[[ block\ncomment ]]"), "block comment")
  end)
end)

-- ── JavaScript highlighting ───────────────────────────────────────────────────

T.describe("javascript highlighting", function()
  T.it("wraps const/function keywords", function()
    local tree, pre, code = make_code_tree("javascript", "const f = function() {}")
    local proc = { _fns = {}, use_transformer = function(self, fn) self._fns[#self._fns + 1] = fn end }
    rh.plugin(proc, nil)
    for _, fn in ipairs(proc._fns) do fn(tree) end

    T.ok(has_span(code, "hljs-keyword", "const"), "const keyword")
    T.ok(has_span(code, "hljs-keyword", "function"), "function keyword")
  end)

  T.it("wraps string literals", function()
    local tree, pre, code = make_code_tree("js", 'const s = "hello"')
    local proc = { _fns = {}, use_transformer = function(self, fn) self._fns[#self._fns + 1] = fn end }
    rh.plugin(proc, nil)
    for _, fn in ipairs(proc._fns) do fn(tree) end

    T.ok(has_span(code, "hljs-string", '"hello"'), "double-quoted string")
  end)

  T.it("wraps null literal", function()
    local tree, pre, code = make_code_tree("js", "const x = null")
    local proc = { _fns = {}, use_transformer = function(self, fn) self._fns[#self._fns + 1] = fn end }
    rh.plugin(proc, nil)
    for _, fn in ipairs(proc._fns) do fn(tree) end

    T.ok(has_span(code, "hljs-literal", "null"), "null literal")
  end)

  T.it("wraps template literals", function()
    local tree, pre, code = make_code_tree("js", "const s = `hi ${name}`")
    local proc = { _fns = {}, use_transformer = function(self, fn) self._fns[#self._fns + 1] = fn end }
    rh.plugin(proc, nil)
    for _, fn in ipairs(proc._fns) do fn(tree) end

    T.ok(has_span(code, "hljs-string", "`hi ${name}`"), "template literal")
  end)

  T.it("wraps line comments", function()
    local tree, pre, code = make_code_tree("js", "// a comment\nconst x = 1")
    local proc = { _fns = {}, use_transformer = function(self, fn) self._fns[#self._fns + 1] = fn end }
    rh.plugin(proc, nil)
    for _, fn in ipairs(proc._fns) do fn(tree) end

    T.ok(has_span(code, "hljs-comment", "// a comment"), "line comment")
  end)
end)

-- ── JSON highlighting ─────────────────────────────────────────────────────────

T.describe("json highlighting", function()
  T.it("wraps object keys in hljs-attr", function()
    local tree, pre, code = make_code_tree("json", '{"name": "Alice"}')
    local proc = { _fns = {}, use_transformer = function(self, fn) self._fns[#self._fns + 1] = fn end }
    rh.plugin(proc, nil)
    for _, fn in ipairs(proc._fns) do fn(tree) end

    T.ok(has_span(code, "hljs-attr", '"name"'), "key wrapped in attr")
  end)

  T.it("wraps string values in hljs-string", function()
    local tree, pre, code = make_code_tree("json", '{"name": "Alice"}')
    local proc = { _fns = {}, use_transformer = function(self, fn) self._fns[#self._fns + 1] = fn end }
    rh.plugin(proc, nil)
    for _, fn in ipairs(proc._fns) do fn(tree) end

    T.ok(has_span(code, "hljs-string", '"Alice"'), "value wrapped in string")
  end)

  T.it("wraps numbers in hljs-number", function()
    local tree, pre, code = make_code_tree("json", '{"age": 30}')
    local proc = { _fns = {}, use_transformer = function(self, fn) self._fns[#self._fns + 1] = fn end }
    rh.plugin(proc, nil)
    for _, fn in ipairs(proc._fns) do fn(tree) end

    T.ok(has_span(code, "hljs-number", "30"), "number value")
  end)

  T.it("wraps true/false/null in hljs-literal", function()
    local tree, pre, code = make_code_tree("json", '{"a": true, "b": false, "c": null}')
    local proc = { _fns = {}, use_transformer = function(self, fn) self._fns[#self._fns + 1] = fn end }
    rh.plugin(proc, nil)
    for _, fn in ipairs(proc._fns) do fn(tree) end

    T.ok(has_span(code, "hljs-literal", "true"), "true literal")
    T.ok(has_span(code, "hljs-literal", "false"), "false literal")
    T.ok(has_span(code, "hljs-literal", "null"), "null literal")
  end)
end)

-- ── Unknown / missing language ────────────────────────────────────────────────

T.describe("unknown language", function()
  T.it("leaves code unchanged when language is unsupported", function()
    local tree, pre, code = make_code_tree("brainfuck", "+++++")
    local original_children = code.children

    local proc = { _fns = {}, use_transformer = function(self, fn) self._fns[#self._fns + 1] = fn end }
    rh.plugin(proc, nil)
    for _, fn in ipairs(proc._fns) do fn(tree) end

    -- children unchanged (still single text node)
    T.eq(#code.children, 1, "still one child")
    T.eq(code.children[1].type, "text", "still a text node")
    -- pre does NOT get hljs class
    T.fail((pre.props or {}).class == "hljs", "pre does not get hljs class")
  end)

  T.it("leaves code unchanged when no language class", function()
    local tree, pre, code = make_code_tree(nil, "some code")

    local proc = { _fns = {}, use_transformer = function(self, fn) self._fns[#self._fns + 1] = fn end }
    rh.plugin(proc, nil)
    for _, fn in ipairs(proc._fns) do fn(tree) end

    T.eq(#code.children, 1, "still one child")
    T.eq(code.children[1].type, "text", "still a text node")
    T.fail((pre.props or {}).class == "hljs", "no hljs on pre")
  end)
end)

-- ── Pre gets hljs class ───────────────────────────────────────────────────────

T.describe("pre class handling", function()
  T.it("adds hljs to pre with no existing class", function()
    local tree, pre, code = make_code_tree("lua", "x = 1")
    local proc = { _fns = {}, use_transformer = function(self, fn) self._fns[#self._fns + 1] = fn end }
    rh.plugin(proc, nil)
    for _, fn in ipairs(proc._fns) do fn(tree) end

    T.eq(pre.props.class, "hljs", "class is hljs")
  end)

  T.it("appends hljs to pre with existing class", function()
    local tree, pre, code = make_code_tree("lua", "x = 1")
    pre.props.class = "myblock"
    local proc = { _fns = {}, use_transformer = function(self, fn) self._fns[#self._fns + 1] = fn end }
    rh.plugin(proc, nil)
    for _, fn in ipairs(proc._fns) do fn(tree) end

    T.ok(pre.props.class:find("hljs"), "hljs appended to existing class")
    T.ok(pre.props.class:find("myblock"), "original class preserved")
  end)
end)

-- ── Custom prefix ─────────────────────────────────────────────────────────────

T.describe("custom prefix", function()
  T.it("uses custom prefix for span classes", function()
    local tree, pre, code = make_code_tree("lua", "local x = 1")
    local proc = { _fns = {}, use_transformer = function(self, fn) self._fns[#self._fns + 1] = fn end }
    rh.plugin(proc, { prefix = "hl-" })
    for _, fn in ipairs(proc._fns) do fn(tree) end

    T.ok(has_span(code, "hl-keyword", "local"), "custom prefix on keyword")
  end)
end)

-- ── Aliases ───────────────────────────────────────────────────────────────────

T.describe("aliases", function()
  T.it("resolves alias to canonical language", function()
    local tree, pre, code = make_code_tree("luascript", "local x = 1")
    local proc = { _fns = {}, use_transformer = function(self, fn) self._fns[#self._fns + 1] = fn end }
    rh.plugin(proc, { aliases = { luascript = "lua" } })
    for _, fn in ipairs(proc._fns) do fn(tree) end

    T.ok(has_span(code, "hljs-keyword", "local"), "alias resolved to lua")
  end)
end)

-- ── HTML output integration ───────────────────────────────────────────────────

T.describe("HTML output", function()
  T.it("produces correct HTML for lua code block", function()
    local tree, pre, code = make_code_tree("lua", "return true")
    local proc = { _fns = {}, use_transformer = function(self, fn) self._fns[#self._fns + 1] = fn end }
    rh.plugin(proc, nil)
    for _, fn in ipairs(proc._fns) do fn(tree) end

    local html = to_html(tree)
    T.ok(html:find('class="hljs"'), "pre has hljs class in HTML")
    T.ok(html:find('class="hljs%-keyword"'), "keyword span in HTML")
    T.ok(html:find('class="hljs%-literal"'), "literal span in HTML")
  end)

  T.it("produces correct HTML for json code block", function()
    local tree, pre, code = make_code_tree("json", '{"x": 1}')
    local proc = { _fns = {}, use_transformer = function(self, fn) self._fns[#self._fns + 1] = fn end }
    rh.plugin(proc, nil)
    for _, fn in ipairs(proc._fns) do fn(tree) end

    local html = to_html(tree)
    T.ok(html:find('class="hljs%-attr"'), "attr span in HTML")
    T.ok(html:find('class="hljs%-number"'), "number span in HTML")
  end)
end)

-- ── Tokenizer edge cases ──────────────────────────────────────────────────────

T.describe("tokenizer edge cases", function()
  T.it("lua: hex numbers", function()
    local toks = rh.tokenizers.lua("local n = 0xFF")
    local found = false
    for _, tok in ipairs(toks) do
      if tok[1] == "number" and tok[2] == "0xFF" then found = true end
    end
    T.ok(found, "hex number tokenized")
  end)

  T.it("lua: built-in functions", function()
    local toks = rh.tokenizers.lua("print(require('x'))")
    local found_print, found_require = false, false
    for _, tok in ipairs(toks) do
      if tok[1] == "built_in" and tok[2] == "print" then found_print = true end
      if tok[1] == "built_in" and tok[2] == "require" then found_require = true end
    end
    T.ok(found_print, "print built-in")
    T.ok(found_require, "require built-in")
  end)

  T.it("python: triple-quoted strings", function()
    local toks = rh.tokenizers.python('x = """hello\nworld"""')
    local found = false
    for _, tok in ipairs(toks) do
      if tok[1] == "string" and tok[2]:find('"""') then found = true end
    end
    T.ok(found, "triple-quoted string tokenized")
  end)

  T.it("python: True/False/None are literals", function()
    local toks = rh.tokenizers.python("x = True\ny = False\nz = None")
    local found_true, found_false, found_none = false, false, false
    for _, tok in ipairs(toks) do
      if tok[1] == "literal" and tok[2] == "True" then found_true = true end
      if tok[1] == "literal" and tok[2] == "False" then found_false = true end
      if tok[1] == "literal" and tok[2] == "None" then found_none = true end
    end
    T.ok(found_true, "True literal")
    T.ok(found_false, "False literal")
    T.ok(found_none, "None literal")
  end)

  T.it("bash: comments", function()
    local toks = rh.tokenizers.bash("# a comment\necho hello")
    local found_comment, found_builtin = false, false
    for _, tok in ipairs(toks) do
      if tok[1] == "comment" then found_comment = true end
      if tok[1] == "built_in" and tok[2] == "echo" then found_builtin = true end
    end
    T.ok(found_comment, "bash comment")
    T.ok(found_builtin, "echo built-in")
  end)

  T.it("js: block comment", function()
    local toks = rh.tokenizers.javascript("/* block */\nconst x = 1")
    local found = false
    for _, tok in ipairs(toks) do
      if tok[1] == "comment" and tok[2]:find("block") then found = true end
    end
    T.ok(found, "block comment tokenized")
  end)
end)
