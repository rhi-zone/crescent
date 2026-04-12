-- lib/template_engine/template_engine_test.lua
if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local TE = require("lib.template_engine")

-- Helper: create a simple env (no loader, no autoescape)
local function env(opts) return TE.environment(opts) end
local function render(src, ctx, opts) return env(opts):render(src, ctx or {}) end

-- ---------------------------------------------------------------------------
T.describe("template_engine", function()

  -- -------------------------------------------------------------------------
  T.describe("plain text", function()
    T.it("renders as-is", function()
      T.eq(render("Hello, world!"), "Hello, world!")
    end)

    T.it("empty string", function()
      T.eq(render(""), "")
    end)

    T.it("multiline text", function()
      T.eq(render("line1\nline2\nline3"), "line1\nline2\nline3")
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("variables", function()
    T.it("basic substitution", function()
      T.eq(render("Hello, {{ name }}!", { name = "Alice" }), "Hello, Alice!")
    end)

    T.it("no spaces around variable", function()
      T.eq(render("{{name}}", { name = "Bob" }), "Bob")
    end)

    T.it("missing variable renders empty string", function()
      T.eq(render("{{ missing }}", {}), "")
    end)

    T.it("number value", function()
      T.eq(render("{{ count }}", { count = 42 }), "42")
    end)

    T.it("boolean value", function()
      T.eq(render("{{ flag }}", { flag = true }), "true")
    end)

    T.it("dot notation for nested fields", function()
      T.eq(render("{{ user.name }}", { user = { name = "Carol" } }), "Carol")
    end)

    T.it("deeply nested dot access", function()
      T.eq(render("{{ a.b.c }}", { a = { b = { c = "deep" } } }), "deep")
    end)

    T.it("nil nested field renders empty", function()
      T.eq(render("{{ user.missing }}", { user = { name = "x" } }), "")
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("filters", function()
    T.it("upper filter", function()
      T.eq(render("{{ name | upper }}", { name = "hello" }), "HELLO")
    end)

    T.it("lower filter", function()
      T.eq(render("{{ name | lower }}", { name = "WORLD" }), "world")
    end)

    T.it("length filter on string", function()
      T.eq(render("{{ s | length }}", { s = "hello" }), "5")
    end)

    T.it("length filter on array", function()
      T.eq(render("{{ arr | length }}", { arr = {1,2,3} }), "3")
    end)

    T.it("default filter: value present", function()
      T.eq(render("{{ x | default('fallback') }}", { x = "real" }), "real")
    end)

    T.it("default filter: value missing", function()
      T.eq(render("{{ x | default('fallback') }}", {}), "fallback")
    end)

    T.it("join filter", function()
      T.eq(render("{{ items | join(', ') }}", { items = {"a","b","c"} }), "a, b, c")
    end)

    T.it("join filter default sep", function()
      T.eq(render("{{ items | join }}", { items = {"x","y"} }), "xy")
    end)

    T.it("capitalize filter", function()
      T.eq(render("{{ s | capitalize }}", { s = "hello world" }), "Hello world")
    end)

    T.it("strip filter", function()
      T.eq(render("{{ s | strip }}", { s = "  hi  " }), "hi")
    end)

    T.it("chained filters: upper then strip", function()
      T.eq(render("{{ s | strip | upper }}", { s = "  hello  " }), "HELLO")
    end)

    T.it("chained filters: lower then capitalize", function()
      T.eq(render("{{ s | lower | capitalize }}", { s = "HELLO WORLD" }), "Hello world")
    end)

    T.it("reverse filter on array", function()
      local out = render("{{ items | reverse | join }}", { items = {"a","b","c"} })
      T.eq(out, "cba")
    end)

    T.it("first filter on array", function()
      T.eq(render("{{ items | first }}", { items = {"x","y","z"} }), "x")
    end)

    T.it("last filter on array", function()
      T.eq(render("{{ items | last }}", { items = {"x","y","z"} }), "z")
    end)

    T.it("int filter", function()
      T.eq(render("{{ n | int }}", { n = "42.7" }), "42")
    end)

    T.it("abs filter", function()
      T.eq(render("{{ n | abs }}", { n = -5 }), "5")
    end)

    T.it("truncate filter", function()
      T.eq(render("{{ s | truncate(5) }}", { s = "hello world" }), "hello...")
    end)

    T.it("truncate filter no-op when short", function()
      T.eq(render("{{ s | truncate(20) }}", { s = "hi" }), "hi")
    end)

    T.it("replace filter", function()
      T.eq(render("{{ s | replace('world', 'Lua') }}", { s = "hello world" }), "hello Lua")
    end)

    T.it("custom filter via add_filter", function()
      local e = env()
      e:add_filter("exclaim", function(v) return tostring(v) .. "!" end)
      local tmpl = e:compile("{{ msg | exclaim }}")
      T.eq(tmpl:render({ msg = "hello" }), "hello!")
    end)

    T.it("title filter", function()
      T.eq(render("{{ s | title }}", { s = "hello world" }), "Hello World")
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("comments", function()
    T.it("comment not in output", function()
      T.eq(render("before{# this is a comment #}after"), "beforeafter")
    end)

    T.it("multiline comment not in output", function()
      T.eq(render("a{# line1\nline2 #}b"), "ab")
    end)

    T.it("comment among variables", function()
      T.eq(render("{{ x }}{# skip #}{{ y }}", { x = "1", y = "2" }), "12")
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("if / elif / else", function()
    T.it("true branch taken", function()
      T.eq(render("{% if flag %}yes{% endif %}", { flag = true }), "yes")
    end)

    T.it("false branch skipped", function()
      T.eq(render("{% if flag %}yes{% endif %}", { flag = false }), "")
    end)

    T.it("else branch", function()
      T.eq(render("{% if flag %}yes{% else %}no{% endif %}", { flag = false }), "no")
    end)

    T.it("elif taken", function()
      local tmpl = "{% if x == 1 %}one{% elif x == 2 %}two{% else %}other{% endif %}"
      T.eq(render(tmpl, { x = 2 }), "two")
    end)

    T.it("elif fallthrough to else", function()
      local tmpl = "{% if x == 1 %}one{% elif x == 2 %}two{% else %}other{% endif %}"
      T.eq(render(tmpl, { x = 9 }), "other")
    end)

    T.it("comparison: greater than", function()
      T.eq(render("{% if n > 5 %}big{% else %}small{% endif %}", { n = 10 }), "big")
    end)

    T.it("comparison: less than", function()
      T.eq(render("{% if n < 5 %}small{% else %}big{% endif %}", { n = 2 }), "small")
    end)

    T.it("string equality", function()
      T.eq(render('{% if s == "hi" %}yes{% else %}no{% endif %}', { s = "hi" }), "yes")
    end)

    T.it("and operator", function()
      T.eq(render("{% if a and b %}both{% else %}no{% endif %}", { a = true, b = true }), "both")
    end)

    T.it("or operator", function()
      T.eq(render("{% if a or b %}yes{% else %}no{% endif %}", { a = false, b = true }), "yes")
    end)

    T.it("not operator", function()
      T.eq(render("{% if not flag %}yes{% else %}no{% endif %}", { flag = false }), "yes")
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("for loop", function()
    T.it("iterates array", function()
      T.eq(render("{% for x in items %}{{ x }},{% endfor %}", { items = {1,2,3} }), "1,2,3,")
    end)

    T.it("empty array produces no output", function()
      T.eq(render("{% for x in items %}{{ x }}{% endfor %}", { items = {} }), "")
    end)

    T.it("for-else: else when empty", function()
      T.eq(render("{% for x in items %}{{ x }}{% else %}none{% endfor %}", { items = {} }), "none")
    end)

    T.it("for-else: no else when non-empty", function()
      T.eq(render("{% for x in items %}{{ x }}{% else %}none{% endfor %}", { items = {"a"} }), "a")
    end)

    T.it("loop.index (1-based)", function()
      T.eq(render("{% for x in items %}{{ loop.index }}{% endfor %}", { items = {"a","b"} }), "12")
    end)

    T.it("loop.index0 (0-based)", function()
      T.eq(render("{% for x in items %}{{ loop.index0 }}{% endfor %}", { items = {"a","b"} }), "01")
    end)

    T.it("loop.first", function()
      T.eq(render("{% for x in items %}{% if loop.first %}F{% endif %}{{ x }}{% endfor %}", { items = {"a","b","c"} }), "Fabc")
    end)

    T.it("loop.last", function()
      T.eq(render("{% for x in items %}{{ x }}{% if loop.last %}!{% endif %}{% endfor %}", { items = {"a","b","c"} }), "abc!")
    end)

    T.it("nested for loops", function()
      T.eq(render("{% for i in rows %}{% for j in cols %}({{ i }},{{ j }}){% endfor %}{% endfor %}",
        { rows = {1,2}, cols = {"a","b"} }), "(1,a)(1,b)(2,a)(2,b)")
    end)

    T.it("k,v iteration", function()
      -- Lua table iteration order is not guaranteed; use a single-entry table
      T.eq(render("{% for k, v in data %}{{ k }}={{ v }}{% endfor %}", { data = { x = "1" } }), "x=1")
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("set", function()
    T.it("set creates variable", function()
      T.eq(render("{% set x = 42 %}{{ x }}", {}), "42")
    end)

    T.it("set can use expression", function()
      T.eq(render("{% set n = a + b %}{{ n }}", { a = 3, b = 4 }), "7")
    end)

    T.it("set overrides context variable in scope", function()
      T.eq(render("{% set name = 'Bob' %}{{ name }}", { name = "Alice" }), "Bob")
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("raw", function()
    T.it("raw block outputs literal delimiters", function()
      T.eq(render("{% raw %}{{ not_a_var }}{% endraw %}"), "{{ not_a_var }}")
    end)

    T.it("raw block with tag syntax", function()
      T.eq(render("{% raw %}{% if x %}{% endraw %}"), "{% if x %}")
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("include", function()
    T.it("includes another template", function()
      local templates = {
        header = "== Header ==",
      }
      local e = env({ loader = function(name) return templates[name] end })
      local tmpl = e:compile('{% include "header" %}')
      T.eq(tmpl:render({}), "== Header ==")
    end)

    T.it("included template shares context", function()
      local templates = {
        greeting = "Hello, {{ name }}!",
      }
      local e = env({ loader = function(name) return templates[name] end })
      local tmpl = e:compile('{% include "greeting" %}')
      T.eq(tmpl:render({ name = "Dave" }), "Hello, Dave!")
    end)

    T.it("missing loader: include silently skipped", function()
      T.eq(render('{% include "missing" %}', {}), "")
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("template inheritance (extends + block)", function()
    T.it("child overrides block", function()
      local templates = {
        base = "BEFORE{% block content %}default{% endblock %}AFTER",
      }
      local e = env({ loader = function(name) return templates[name] end })
      local child = '{% extends "base" %}{% block content %}CHILD{% endblock %}'
      local tmpl = e:compile(child)
      T.eq(tmpl:render({}), "BEFORECHILDAFTER")
    end)

    T.it("base block default used when child has no override", function()
      local templates = {
        base = "A{% block x %}DEFAULT{% endblock %}B",
      }
      local e = env({ loader = function(name) return templates[name] end })
      local child = '{% extends "base" %}'
      local tmpl = e:compile(child)
      T.eq(tmpl:render({}), "ADEFAULTB")
    end)

    T.it("multiple blocks overridden", function()
      local templates = {
        base = "{% block title %}T{% endblock %}: {% block body %}B{% endblock %}",
      }
      local e = env({ loader = function(name) return templates[name] end })
      local child = '{% extends "base" %}{% block title %}MyTitle{% endblock %}{% block body %}MyBody{% endblock %}'
      local tmpl = e:compile(child)
      T.eq(tmpl:render({}), "MyTitle: MyBody")
    end)

    T.it("context available in inherited template", function()
      local templates = {
        base = "Hello, {% block name %}World{% endblock %}!",
      }
      local e = env({ loader = function(name) return templates[name] end })
      local child = '{% extends "base" %}{% block name %}{{ user }}{% endblock %}'
      local tmpl = e:compile(child)
      T.eq(tmpl:render({ user = "Alice" }), "Hello, Alice!")
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("macros", function()
    T.it("define and call macro", function()
      local src = "{% macro greet(name) %}Hello, {{ name }}!{% endmacro %}{{ greet('World') }}"
      T.eq(render(src, {}), "Hello, World!")
    end)

    T.it("macro with multiple parameters", function()
      local src = "{% macro add(a, b) %}{{ a + b }}{% endmacro %}{{ add(3, 4) }}"
      T.eq(render(src, {}), "7")
    end)

    T.it("macro with default parameter", function()
      local src = "{% macro hi(name='stranger') %}Hi, {{ name }}{% endmacro %}{{ hi() }}"
      T.eq(render(src, {}), "Hi, stranger")
    end)

    T.it("macro call tag outputs result", function()
      local src = "{% macro shout(msg) %}{{ msg | upper }}!{% endmacro %}{% call shout('hello') %}"
      T.eq(render(src, {}), "HELLO!")
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("autoescape", function()
    T.it("autoescape off: raw HTML passes through", function()
      T.eq(render("{{ html }}", { html = "<b>bold</b>" }), "<b>bold</b>")
    end)

    T.it("autoescape on: < escaped", function()
      local e = env({ autoescape = true })
      local tmpl = e:compile("{{ html }}")
      T.eq(tmpl:render({ html = "<b>bold</b>" }), "&lt;b&gt;bold&lt;/b&gt;")
    end)

    T.it("autoescape on: & escaped", function()
      local e = env({ autoescape = true })
      local tmpl = e:compile("{{ val }}")
      T.eq(tmpl:render({ val = "a&b" }), "a&amp;b")
    end)

    T.it("escape filter: explicit HTML escaping", function()
      T.eq(render("{{ html | escape }}", { html = '<script>alert("x")</script>' }),
           '&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;')
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("whitespace control", function()
    T.it("{%- strips leading whitespace", function()
      T.eq(render("text   {%- if true %}Y{% endif %}", { }), "textY")
    end)

    T.it("whitespace in for loop without trimming", function()
      T.eq(render("[{% for x in items %}{{ x }}{% endfor %}]", { items = {"a","b"} }), "[ab]")
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("while loop", function()
    T.it("while iterates until condition false", function()
      local src = "{% set i = 1 %}{% while i <= 3 %}{{ i }}{% set i = i + 1 %}{% endwhile %}"
      T.eq(render(src, {}), "123")
    end)

    T.it("while with false condition: no output", function()
      T.eq(render("{% while false %}x{% endwhile %}", {}), "")
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("compile / render API", function()
    T.it("env:compile returns template object", function()
      local e = env()
      local tmpl, err = e:compile("Hello {{ name }}")
      T.ok(tmpl ~= nil, "compile returned nil")
      T.ok(err == nil, "compile returned error")
    end)

    T.it("tmpl:render returns string", function()
      local e = env()
      local tmpl = e:compile("{{ x }}")
      T.eq(tmpl:render({ x = "yes" }), "yes")
    end)

    T.it("env:render shortcut works", function()
      local e = env()
      local out, err = e:render("{{ v }}", { v = "ok" })
      T.eq(out, "ok")
      T.ok(err == nil)
    end)

    T.it("M._tier is 'pure'", function()
      T.eq(TE._tier, "pure")
    end)

    T.it("M.render convenience function", function()
      local out = TE.render("{{ x }}", { x = "top" })
      T.eq(out, "top")
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("edge cases", function()
    T.it("multiple variables in one template", function()
      T.eq(render("{{ a }} and {{ b }}", { a = "foo", b = "bar" }), "foo and bar")
    end)

    T.it("variable used multiple times", function()
      T.eq(render("{{ x }}-{{ x }}", { x = "hi" }), "hi-hi")
    end)

    T.it("nested if inside for", function()
      local src = "{% for n in nums %}{% if n > 2 %}{{ n }}{% endif %}{% endfor %}"
      T.eq(render(src, { nums = {1,2,3,4} }), "34")
    end)

    T.it("set inside for accumulates", function()
      local src = "{% set total = 0 %}{% for n in nums %}{% set total = total + n %}{% endfor %}{{ total }}"
      T.eq(render(src, { nums = {1,2,3} }), "6")
    end)

    T.it("filter on missing variable uses empty string", function()
      T.eq(render("{{ x | upper }}", {}), "")
    end)
  end)

end)
