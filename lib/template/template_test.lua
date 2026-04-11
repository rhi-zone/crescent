if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local template = require("lib.template")

T.describe("template.compile", function()
	T.it("returns a function on success", function()
		local fn, err = template.compile("hello")
		T.ok(fn, "should return a function")
		T.eq(err, nil, "should not return an error")
		T.eq(type(fn), "function")
	end)

	T.it("returns nil and error on unclosed {{", function()
		local fn, err = template.compile("{{ x")
		T.eq(fn, nil)
		T.ok(err, "should return an error message")
		T.ok(err:find("unclosed", 1, true), "error should mention unclosed")
	end)

	T.it("returns nil and error on unclosed {{{", function()
		local fn, err = template.compile("{{{ x")
		T.eq(fn, nil)
		T.ok(err)
	end)

	T.it("returns nil and error on unclosed {%", function()
		local fn, err = template.compile("{% if true then")
		T.eq(fn, nil)
		T.ok(err)
	end)

	T.it("returns nil and error on unclosed {#", function()
		local fn, err = template.compile("{# comment")
		T.eq(fn, nil)
		T.ok(err)
	end)

	T.it("compiled function is reusable", function()
		local fn = template.compile("Hello, {{ name }}!")
		T.eq(fn({name = "Alice"}), "Hello, Alice!")
		T.eq(fn({name = "Bob"}), "Hello, Bob!")
		T.eq(fn({name = "Charlie"}), "Hello, Charlie!")
	end)

	T.it("returns compile error for invalid Lua in expression", function()
		local fn, err = template.compile("{{ end }}")
		T.eq(fn, nil)
		T.ok(err)
		T.ok(err:find("compile error", 1, true))
	end)

	T.it("returns compile error for invalid Lua in code block", function()
		local fn, err = template.compile("{% local 123 = %}")
		T.eq(fn, nil)
		T.ok(err)
	end)
end)

T.describe("template.render — simple interpolation", function()
	T.it("interpolates a single variable", function()
		T.eq(template.render("Hello, {{ name }}!", {name = "World"}), "Hello, World!")
	end)

	T.it("interpolates multiple variables", function()
		T.eq(template.render("{{ a }} and {{ b }}", {a = "X", b = "Y"}), "X and Y")
	end)

	T.it("interpolates numbers", function()
		T.eq(template.render("Count: {{ n }}", {n = 42}), "Count: 42")
	end)

	T.it("interpolates boolean", function()
		T.eq(template.render("{{ v }}", {v = true}), "true")
	end)

	T.it("interpolates expressions", function()
		T.eq(template.render("{{ a + b }}", {a = 3, b = 4}), "7")
	end)

	T.it("interpolates string concatenation", function()
		T.eq(template.render("{{ a .. b }}", {a = "foo", b = "bar"}), "foobar")
	end)

	T.it("interpolates method calls", function()
		T.eq(template.render("{{ s:upper() }}", {s = "hello"}), "HELLO")
	end)

	T.it("interpolates table access", function()
		T.eq(template.render("{{ t.x }}", {t = {x = "val"}}), "val")
	end)

	T.it("interpolates nested table access", function()
		T.eq(template.render("{{ t.a.b }}", {t = {a = {b = "deep"}}}), "deep")
	end)

	T.it("interpolates bracket access", function()
		T.eq(template.render("{{ t[1] }}", {t = {"first"}}), "first")
	end)
end)

T.describe("template.render — HTML escaping", function()
	T.it("escapes < and >", function()
		T.eq(template.render("{{ x }}", {x = "<div>"}), "&lt;div&gt;")
	end)

	T.it("escapes &", function()
		T.eq(template.render("{{ x }}", {x = "a&b"}), "a&amp;b")
	end)

	T.it("escapes double quotes", function()
		T.eq(template.render("{{ x }}", {x = 'a"b'}), "a&quot;b")
	end)

	T.it("escapes single quotes", function()
		T.eq(template.render("{{ x }}", {x = "a'b"}), "a&#039;b")
	end)

	T.it("escapes all special characters together", function()
		T.eq(template.render("{{ x }}", {x = [[<>&"']]}), "&lt;&gt;&amp;&quot;&#039;")
	end)

	T.it("does not double-escape", function()
		T.eq(template.render("{{ x }}", {x = "&amp;"}), "&amp;amp;")
	end)
end)

T.describe("template.render — raw output", function()
	T.it("raw output does not escape HTML", function()
		T.eq(template.render("{{{ x }}}", {x = "<b>bold</b>"}), "<b>bold</b>")
	end)

	T.it("raw output preserves all special chars", function()
		T.eq(template.render("{{{ x }}}", {x = [[<>&"']]}), [[<>&"']])
	end)

	T.it("raw output with expression", function()
		T.eq(template.render("{{{ a .. b }}}", {a = "<", b = ">"}), "<>")
	end)
end)

T.describe("template.render — code blocks", function()
	T.it("executes code block", function()
		T.eq(template.render("{% local x = 42 %}{{ x }}", {}), "42")
	end)

	T.it("if/then block", function()
		T.eq(template.render("{% if show then %}visible{% end %}", {show = true}), "visible")
	end)

	T.it("if/then block when false", function()
		T.eq(template.render("{% if show then %}visible{% end %}", {show = false}), "")
	end)

	T.it("if/else block — true branch", function()
		local tmpl = "{% if x then %}yes{% else %}no{% end %}"
		T.eq(template.render(tmpl, {x = true}), "yes")
	end)

	T.it("if/else block — false branch", function()
		local tmpl = "{% if x then %}yes{% else %}no{% end %}"
		T.eq(template.render(tmpl, {x = false}), "no")
	end)

	T.it("if/elseif/else block", function()
		local tmpl = "{% if x == 1 then %}one{% elseif x == 2 then %}two{% else %}other{% end %}"
		T.eq(template.render(tmpl, {x = 1}), "one")
		T.eq(template.render(tmpl, {x = 2}), "two")
		T.eq(template.render(tmpl, {x = 3}), "other")
	end)
end)

T.describe("template.render — for loops", function()
	T.it("ipairs loop", function()
		local tmpl = "{% for i, v in ipairs(items) do %}{{ v }}{% end %}"
		T.eq(template.render(tmpl, {items = {"a", "b", "c"}}), "abc")
	end)

	T.it("ipairs loop with separator", function()
		local tmpl = "{% for i, v in ipairs(items) do %}{% if i > 1 then %}, {% end %}{{ v }}{% end %}"
		T.eq(template.render(tmpl, {items = {"a", "b", "c"}}), "a, b, c")
	end)

	T.it("numeric for loop", function()
		local tmpl = "{% for i = 1, 3 do %}{{ i }}{% end %}"
		T.eq(template.render(tmpl, {}), "123")
	end)

	T.it("nested for loops", function()
		local tmpl = "{% for i = 1, 2 do %}{% for j = 1, 2 do %}{{ i }}{{ j }}{% end %}{% end %}"
		T.eq(template.render(tmpl, {}), "11122122")
	end)

	T.it("for loop with HTML list", function()
		local tmpl = "<ul>{% for _, item in ipairs(items) do %}<li>{{ item }}</li>{% end %}</ul>"
		T.eq(template.render(tmpl, {items = {"a", "b"}}), "<ul><li>a</li><li>b</li></ul>")
	end)

	T.it("pairs loop", function()
		-- pairs order is undefined, so just check length
		local tmpl = "{% for k, v in pairs(t) do %}{{ k }}={{ v }} {% end %}"
		local r = template.render(tmpl, {t = {x = 1}})
		T.eq(r, "x=1 ")
	end)
end)

T.describe("template.render — comments", function()
	T.it("strips comments", function()
		T.eq(template.render("hello{# this is a comment #} world", {}), "hello world")
	end)

	T.it("strips comment at start", function()
		T.eq(template.render("{# comment #}hello", {}), "hello")
	end)

	T.it("strips comment at end", function()
		T.eq(template.render("hello{# comment #}", {}), "hello")
	end)

	T.it("strips multiple comments", function()
		T.eq(template.render("{# a #}x{# b #}y{# c #}", {}), "xy")
	end)

	T.it("comment with template-like content inside", function()
		T.eq(template.render("{# {{ x }} #}done", {}), "done")
	end)
end)

T.describe("template.render — filters", function()
	T.it("upper filter", function()
		T.eq(template.render("{{ name | upper }}", {name = "world"}), "WORLD")
	end)

	T.it("lower filter", function()
		T.eq(template.render("{{ name | lower }}", {name = "WORLD"}), "world")
	end)

	T.it("trim filter", function()
		T.eq(template.render("{{ name | trim }}", {name = "  hello  "}), "hello")
	end)

	T.it("length filter on string", function()
		T.eq(template.render("{{ name | length }}", {name = "hello"}), "5")
	end)

	T.it("length filter on table", function()
		T.eq(template.render("{{ items | length }}", {items = {1, 2, 3}}), "3")
	end)

	T.it("default filter with nil value", function()
		T.eq(template.render([[{{ missing | default("N/A") }}]], {}), "N/A")
	end)

	T.it("default filter with existing value", function()
		T.eq(template.render([[{{ name | default("N/A") }}]], {name = "Alice"}), "Alice")
	end)

	T.it("chained filters", function()
		T.eq(template.render("{{ name | trim | upper }}", {name = "  hello  "}), "HELLO")
	end)

	T.it("filter on raw output", function()
		T.eq(template.render("{{{ name | upper }}}", {name = "world"}), "WORLD")
	end)

	T.it("filter with HTML escaping", function()
		T.eq(template.render("{{ x | upper }}", {x = "<b>"}), "&lt;B&gt;")
	end)
end)

T.describe("template.add_filter — custom filters", function()
	T.it("adds a custom filter", function()
		template.add_filter("reverse", function(s) return tostring(s):reverse() end)
		T.eq(template.render("{{ name | reverse }}", {name = "hello"}), "olleh")
	end)

	T.it("custom filter with raw output", function()
		template.add_filter("exclaim", function(s) return tostring(s) .. "!" end)
		T.eq(template.render("{{{ name | exclaim }}}", {name = "wow"}), "wow!")
	end)

	T.it("custom filter chains with built-in", function()
		template.add_filter("wrap", function(s) return "[" .. tostring(s) .. "]" end)
		T.eq(template.render("{{ name | upper | wrap }}", {name = "hi"}), "[HI]")
	end)
end)

T.describe("template.render — edge cases", function()
	T.it("empty template", function()
		T.eq(template.render("", {}), "")
	end)

	T.it("no variables — plain text", function()
		T.eq(template.render("just text", {}), "just text")
	end)

	T.it("nil context", function()
		T.eq(template.render("hello", nil), "hello")
	end)

	T.it("consecutive tags with no text between", function()
		T.eq(template.render("{{ a }}{{ b }}", {a = "X", b = "Y"}), "XY")
	end)

	T.it("consecutive tags with space", function()
		T.eq(template.render("{{ a }} {{ b }}", {a = "X", b = "Y"}), "X Y")
	end)

	T.it("template with only a tag", function()
		T.eq(template.render("{{ x }}", {x = "val"}), "val")
	end)

	T.it("multiline template", function()
		local tmpl = "line1\nline2\n{{ x }}"
		T.eq(template.render(tmpl, {x = "val"}), "line1\nline2\nval")
	end)

	T.it("literal braces — single {", function()
		T.eq(template.render("a { b", {}), "a { b")
	end)

	T.it("expression with spaces", function()
		T.eq(template.render("{{  name  }}", {name = "X"}), "X")
	end)

	T.it("code block with local variable", function()
		T.eq(template.render("{% local x = 1 + 2 %}{{ x }}", {}), "3")
	end)

	T.it("whitespace in code blocks", function()
		T.eq(template.render("{%   if true then   %}ok{%   end   %}", {}), "ok")
	end)

	T.it("mixed tags", function()
		local tmpl = "{{ a }}{# comment #}{% if true then %}{{ b }}{% end %}{{{ c }}}"
		T.eq(template.render(tmpl, {a = "<", b = "&", c = ">"}), "&lt;&amp;>")
	end)

	T.it("template with only whitespace", function()
		T.eq(template.render("   ", {}), "   ")
	end)

	T.it("empty expression renders as nil", function()
		-- {{  }} compiles to __esc() which tostrings nil
		T.eq(template.render("{{  }}", {}), "nil")
	end)

	T.it("while loop in code block", function()
		local tmpl = "{% local i = 0 %}{% while i < 3 do %}{{ i }}{% i = i + 1 %}{% end %}"
		T.eq(template.render(tmpl, {}), "012")
	end)

	T.it("repeat/until in code block", function()
		local tmpl = "{% local i = 0 %}{% repeat %}{{ i }}{% i = i + 1 %}{% until i == 3 %}"
		T.eq(template.render(tmpl, {}), "012")
	end)
end)

T.describe("template.render — complex templates", function()
	T.it("HTML page with loop and conditional", function()
		local tmpl = [[<ul>
{% for i, item in ipairs(items) do %}
<li class="{% if i == 1 then %}first{% end %}">{{ item }}</li>
{% end %}
</ul>]]
		local r = template.render(tmpl, {items = {"<a>", "b", "c"}})
		T.ok(r:find("&lt;a&gt;", 1, true), "should escape item")
		T.ok(r:find('class="first"', 1, true), "should have first class")
	end)

	T.it("nested conditionals", function()
		local tmpl = "{% if a then %}{% if b then %}both{% else %}a only{% end %}{% end %}"
		T.eq(template.render(tmpl, {a = true, b = true}), "both")
		T.eq(template.render(tmpl, {a = true, b = false}), "a only")
		T.eq(template.render(tmpl, {a = false, b = true}), "")
	end)

	T.it("variable assignment in code block used later", function()
		local tmpl = "{% local total = 0 %}{% for _, v in ipairs(nums) do %}{% total = total + v %}{% end %}Total: {{ total }}"
		T.eq(template.render(tmpl, {nums = {1, 2, 3}}), "Total: 6")
	end)

	T.it("string literal in expression", function()
		T.eq(template.render([[ {{ "hello" }} ]], {}), " hello ")
	end)

	T.it("ternary-style expression", function()
		T.eq(template.render("{{ x and 'yes' or 'no' }}", {x = true}), "yes")
		T.eq(template.render("{{ x and 'yes' or 'no' }}", {x = false}), "no")
	end)

	T.it("table constructor in expression", function()
		T.eq(template.render("{{ #({1,2,3}) }}", {}), "3")
	end)
end)

T.describe("template.escape", function()
	T.it("escapes all HTML special characters", function()
		T.eq(template.escape('<script>alert("x")</script>'),
			'&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;')
	end)

	T.it("returns unchanged string without special chars", function()
		T.eq(template.escape("hello world"), "hello world")
	end)

	T.it("converts non-string to string first", function()
		T.eq(template.escape(42), "42")
	end)
end)
