if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local S = require("lib.string_template")

T.describe("interpolate", function()
  T.it("simple variable", function()
    T.eq(S.interpolate("Hello, ${name}!", {name = "World"}), "Hello, World!")
  end)

  T.it("multiple variables", function()
    T.eq(
      S.interpolate("${first} ${last} is ${age} years old", {first="Alice", last="Smith", age=30}),
      "Alice Smith is 30 years old"
    )
  end)

  T.it("missing variable defaults to empty string", function()
    T.eq(S.interpolate("Hello, ${name}!", {}), "Hello, !")
  end)

  T.it("empty template", function()
    T.eq(S.interpolate("", {}), "")
  end)

  T.it("template with no vars", function()
    T.eq(S.interpolate("no substitutions here", {}), "no substitutions here")
  end)

  T.it("variable at start", function()
    T.eq(S.interpolate("${x} world", {x="hello"}), "hello world")
  end)

  T.it("variable at end", function()
    T.eq(S.interpolate("hello ${x}", {x="world"}), "hello world")
  end)

  T.it("adjacent variables", function()
    T.eq(S.interpolate("${a}${b}", {a="foo", b="bar"}), "foobar")
  end)
end)

T.describe("dot-path access", function()
  T.it("one level", function()
    T.eq(S.interpolate("${user.name}", {user={name="Bob"}}), "Bob")
  end)

  T.it("two levels", function()
    T.eq(
      S.interpolate("${a.b.c}", {a={b={c="deep"}}}),
      "deep"
    )
  end)

  T.it("missing intermediate returns empty", function()
    T.eq(S.interpolate("${user.name}", {}), "")
  end)

  T.it("dot-path in full sentence", function()
    T.eq(
      S.interpolate("${user.name} from ${user.city}", {user={name="Bob", city="NYC"}}),
      "Bob from NYC"
    )
  end)
end)

T.describe("default values", function()
  T.it("uses default when var is missing", function()
    T.eq(S.interpolate("Hello, ${name|Guest}!", {}), "Hello, Guest!")
  end)

  T.it("uses var value when present, ignores default", function()
    T.eq(S.interpolate("Hello, ${name|Guest}!", {name="Alice"}), "Hello, Alice!")
  end)

  T.it("empty default string", function()
    T.eq(S.interpolate("${x|}", {}), "")
  end)
end)

T.describe("format specs", function()
  T.it("%.2f rounds float", function()
    T.eq(S.interpolate("Pi is ${pi:.2f}", {pi=3.14159}), "Pi is 3.14")
  end)

  T.it("%05d zero-pads integer", function()
    T.eq(S.interpolate("Count: ${n:%05d}", {n=42}), "Count: 00042")
  end)

  T.it("%10s right-pads string", function()
    T.eq(S.interpolate("Name: ${name:%10s}", {name="Alice"}), "Name:      Alice")
  end)

  T.it("named shortcut: upper", function()
    T.eq(S.interpolate("${s:upper}", {s="hello"}), "HELLO")
  end)

  T.it("named shortcut: lower", function()
    T.eq(S.interpolate("${s:lower}", {s="WORLD"}), "world")
  end)

  T.it("named shortcut: hex", function()
    T.eq(S.interpolate("${n:hex}", {n=255}), "ff")
  end)

  T.it("named shortcut: HEX", function()
    T.eq(S.interpolate("${n:HEX}", {n=255}), "FF")
  end)

  T.it("named shortcut: int", function()
    T.eq(S.interpolate("${n:int}", {n=42.9}), "42")
  end)

  T.it("named shortcut: float", function()
    T.eq(S.interpolate("${n:float}", {n=3.14}), "3.14")
  end)

  T.it("named shortcut: repr", function()
    T.eq(S.interpolate("${s:repr}", {s='he said "hi"'}), string.format("%q", 'he said "hi"'))
  end)
end)

T.describe("compile", function()
  T.it("returns a function", function()
    local tpl = S.compile("Hello, ${name}!")
    T.ok(type(tpl) == "function")
  end)

  T.it("produces correct output", function()
    local tpl = S.compile("Hello, ${name}!")
    T.eq(tpl({name="Alice"}), "Hello, Alice!")
  end)

  T.it("reusable with different vars", function()
    local tpl = S.compile("Hello, ${name}!")
    T.eq(tpl({name="Alice"}), "Hello, Alice!")
    T.eq(tpl({name="Bob"}),   "Hello, Bob!")
  end)

  T.it("returns nil+errmsg on parse error", function()
    local tpl, err = S.compile("Hello ${unclosed")
    T.ok(tpl == nil)
    T.ok(type(err) == "string")
  end)
end)

T.describe("syntax variants", function()
  T.it("curly: {name}", function()
    local tpl = S.compile("Hello, {name}!", {syntax="curly"})
    T.eq(tpl({name="Alice"}), "Hello, Alice!")
  end)

  T.it("percent: %{name}", function()
    local tpl = S.compile("Hello, %{name}!", {syntax="percent"})
    T.eq(tpl({name="Alice"}), "Hello, Alice!")
  end)

  T.it("double: {{name}}", function()
    local tpl = S.compile("Hello, {{name}}!", {syntax="double"})
    T.eq(tpl({name="Alice"}), "Hello, Alice!")
  end)

  T.it("curly syntax with dot-path", function()
    local tpl = S.compile("{user.name}", {syntax="curly"})
    T.eq(tpl({user={name="Bob"}}), "Bob")
  end)
end)

T.describe("positional args", function()
  T.it("integer keys via ${1}, ${2}", function()
    T.eq(S.interpolate("${1} + ${2} = ${3}", {10, 20, 30}), "10 + 20 = 30")
  end)

  T.it("single positional", function()
    T.eq(S.interpolate("value: ${1}", {"hello"}), "value: hello")
  end)
end)

T.describe("printf", function()
  T.it("formats and returns string", function()
    T.eq(S.printf("%s is %d years old", "Alice", 30), "Alice is 30 years old")
  end)

  T.it("float format", function()
    T.eq(S.printf("%.3f", 3.14159), "3.142")
  end)

  T.it("zero padding", function()
    T.eq(S.printf("%05d", 42), "00042")
  end)
end)

T.describe("on_missing option", function()
  T.it("error: returns nil + errmsg", function()
    local result, err = S.interpolate("${missing}", {}, {on_missing="error"})
    T.ok(result == nil)
    T.ok(err ~= nil)
    T.ok(err:find("missing") ~= nil)
  end)

  T.it("keep: leaves placeholder unchanged", function()
    T.eq(S.interpolate("${missing}", {}, {on_missing="keep"}), "${missing}")
  end)

  T.it("empty: replaces with empty string (default)", function()
    T.eq(S.interpolate("${missing}", {}, {on_missing="empty"}), "")
  end)

  T.it("default behavior (no option) is empty", function()
    T.eq(S.interpolate("${missing}", {}), "")
  end)
end)

T.describe("escape sequences", function()
  T.it("\\${ produces literal ${", function()
    T.eq(S.interpolate("price: \\${amount}", {amount=5}), "price: ${amount}")
  end)

  T.it("escape at start", function()
    T.eq(S.interpolate("\\${x} world", {x="hi"}), "${x} world")
  end)

  T.it("escape at end", function()
    T.eq(S.interpolate("hello \\${x}", {x="hi"}), "hello ${x}")
  end)

  T.it("mix of escaped and real vars", function()
    T.eq(
      S.interpolate("${greeting}, \\${name}!", {greeting="Hello"}),
      "Hello, ${name}!"
    )
  end)
end)

T.describe("dedent", function()
  T.it("strips common leading spaces", function()
    local result = S.dedent("  hello\n  world\n")
    T.eq(result, "hello\nworld")
  end)

  T.it("strips leading newline (heredoc style)", function()
    local s = "\n  hello\n  world\n"
    local result = S.dedent(s)
    T.eq(result, "hello\nworld")
  end)

  T.it("no-op when no indentation", function()
    T.eq(S.dedent("hello\nworld\n"), "hello\nworld")
  end)
end)
