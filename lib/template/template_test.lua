if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local M = require("lib.template")

-- ============================================================
T.describe("interpolation", function()
  T.it("simple variable", function()
    T.eq(M.render("{{name}}", {name="World"}), "World")
  end)

  T.it("HTML escape by default: < >", function()
    T.eq(M.render("{{x}}", {x="<b>"}), "&lt;b&gt;")
  end)

  T.it("HTML escape ampersand", function()
    T.eq(M.render("{{x}}", {x="a&b"}), "a&amp;b")
  end)

  T.it("HTML escape quote", function()
    T.eq(M.render("{{x}}", {x='say "hi"'}), "say &quot;hi&quot;")
  end)

  T.it("triple braces no escape", function()
    T.eq(M.render("{{{x}}}", {x="<b>"}), "<b>")
  end)

  T.it("triple braces ampersand raw", function()
    T.eq(M.render("{{{x}}}", {x="a&b"}), "a&b")
  end)

  T.it("missing variable is empty string", function()
    T.eq(M.render("{{x}}", {}), "")
  end)

  T.it("literal text passthrough", function()
    T.eq(M.render("hello world", {}), "hello world")
  end)

  T.it("multiple variables", function()
    T.eq(M.render("{{a}} {{b}}", {a="foo", b="bar"}), "foo bar")
  end)

  T.it("numeric variable", function()
    T.eq(M.render("{{n}}", {n=42}), "42")
  end)
end)

-- ============================================================
T.describe("comments", function()
  T.it("comment removed from output", function()
    T.eq(M.render("a{{! this is a comment }}b", {}), "ab")
  end)

  T.it("comment with special chars", function()
    T.eq(M.render("x{{! <>&\" }}y", {}), "xy")
  end)
end)

-- ============================================================
T.describe("conditionals", function()
  T.it("if true renders body", function()
    T.eq(M.render("{{#if x}}yes{{/if}}", {x=true}), "yes")
  end)

  T.it("if false renders nothing", function()
    T.eq(M.render("{{#if x}}yes{{/if}}", {x=false}), "")
  end)

  T.it("if nil renders nothing", function()
    T.eq(M.render("{{#if x}}yes{{/if}}", {}), "")
  end)

  T.it("if/else true branch", function()
    T.eq(M.render("{{#if x}}y{{#else}}n{{/if}}", {x=true}), "y")
  end)

  T.it("if/else false branch", function()
    T.eq(M.render("{{#if x}}y{{#else}}n{{/if}}", {x=false}), "n")
  end)

  T.it("if truthy string", function()
    T.eq(M.render("{{#if x}}yes{{/if}}", {x="hello"}), "yes")
  end)

  T.it("if truthy number", function()
    T.eq(M.render("{{#if x}}yes{{/if}}", {x=0}), "yes")
  end)

  T.it("nested if", function()
    T.eq(M.render("{{#if a}}{{#if b}}both{{/if}}{{/if}}", {a=true, b=true}), "both")
  end)

  T.it("nested if inner false", function()
    T.eq(M.render("{{#if a}}{{#if b}}both{{/if}}outer{{/if}}", {a=true, b=false}), "outer")
  end)
end)

-- ============================================================
T.describe("loops", function()
  T.it("each over array", function()
    T.eq(M.render("{{#each items}}{{.}},{{/each}}", {items={"a","b","c"}}), "a,b,c,")
  end)

  T.it("each 1-based index", function()
    local r = M.render("{{#each items}}{{@index}},{{/each}}", {items={"a","b"}})
    T.eq(r, "1,2,")
  end)

  T.it("each index access contains 1", function()
    T.ok(M.render("{{#each items}}{{@index}},{{/each}}", {items={"a","b"}}):find("1,"))
  end)

  T.it("each over empty array produces nothing", function()
    T.eq(M.render("{{#each items}}x{{/each}}", {items={}}), "")
  end)

  T.it("each over array of objects", function()
    T.eq(
      M.render("{{#each items}}{{name}},{{/each}}", {items={{name="Alice"},{name="Bob"}}}),
      "Alice,Bob,"
    )
  end)

  T.it("each over map keys", function()
    local r = M.render("{{#each map}}{{@key}}={{.}};{{/each}}", {map={x="1"}})
    T.eq(r, "x=1;")
  end)

  T.it("each map value via dot", function()
    local r = M.render("{{#each map}}{{.}};{{/each}}", {map={a="v1"}})
    T.eq(r, "v1;")
  end)

  T.it("nested each loops", function()
    local r = M.render(
      "{{#each rows}}{{#each cols}}{{.}}{{/each}};{{/each}}",
      {rows={{cols={"a","b"}},{cols={"c","d"}}}}
    )
    T.eq(r, "ab;cd;")
  end)

  T.it("each with if inside", function()
    local r = M.render(
      "{{#each items}}{{#if .}}y{{#else}}n{{/if}},{{/each}}",
      {items={true, false, true}}
    )
    T.eq(r, "y,n,y,")
  end)
end)

-- ============================================================
T.describe("filters", function()
  T.it("upper filter", function()
    T.eq(M.render("{{name|upper}}", {name="hello"}), "HELLO")
  end)

  T.it("lower filter", function()
    T.eq(M.render("{{name|lower}}", {name="HELLO"}), "hello")
  end)

  T.it("trim filter", function()
    T.eq(M.render("{{x|trim}}", {x="  hi  "}), "hi")
  end)

  T.it("escape filter explicit", function()
    T.eq(M.render("{{x|escape}}", {x="<b>"}), "&lt;b&gt;")
  end)

  T.it("raw filter no escaping", function()
    T.eq(M.render("{{x|raw}}", {x="<b>"}), "<b>")
  end)

  T.it("default filter when nil", function()
    T.eq(M.render("{{x|default:none}}", {}), "none")
  end)

  T.it("default filter when false", function()
    T.eq(M.render("{{x|default:missing}}", {x=false}), "missing")
  end)

  T.it("default filter not applied when value present", function()
    T.eq(M.render("{{x|default:fallback}}", {x="hi"}), "hi")
  end)
end)

-- ============================================================
T.describe("partials", function()
  T.it("module-level partial", function()
    -- Use engine instance to isolate from global state
    local e = M.new()
    e:partial("greet", "Hello, {{name}}!")
    T.eq(e:render("{{>greet}}", {name="World"}), "Hello, World!")
  end)

  T.it("partial with HTML escaping in partial body", function()
    local e = M.new()
    e:partial("item", "<li>{{x}}</li>")
    T.eq(e:render("{{>item}}", {x="<b>"}), "<li>&lt;b&gt;</li>")
  end)

  T.it("multiple partial includes", function()
    local e = M.new()
    e:partial("sep", "|")
    T.eq(e:render("a{{>sep}}b{{>sep}}c", {}), "a|b|c")
  end)

  T.it("missing partial renders nothing", function()
    local e = M.new()
    T.eq(e:render("{{>missing}}", {}), "")
  end)
end)

-- ============================================================
T.describe("custom filters", function()
  T.it("engine custom filter", function()
    local e = M.new()
    e:filter("shout", function(v) return v:upper() .. "!" end)
    T.eq(e:render("{{x|shout}}", {x="hello"}), "HELLO!")
  end)

  T.it("engine filter isolated from module", function()
    local e1 = M.new()
    local e2 = M.new()
    e1:filter("shout", function(v) return v .. "!" end)
    -- e2 should not have "shout" (we registered after e2 was created)
    -- This just checks e2 doesn't error
    T.eq(e2:render("{{x}}", {x="hi"}), "hi")
  end)
end)

-- ============================================================
T.describe("compile API", function()
  T.it("compile returns callable", function()
    local tmpl = M.compile("Hello, {{name}}!")
    T.ok(type(tmpl) == "function")
  end)

  T.it("compiled template callable multiple times", function()
    local tmpl = M.compile("{{x}}")
    T.eq(tmpl({x="a"}), "a")
    T.eq(tmpl({x="b"}), "b")
  end)

  T.it("engine compile returns callable", function()
    local e = M.new()
    local fn = e:compile("{{n}}")
    T.ok(type(fn) == "function")
    T.eq(fn({n="42"}), "42")
  end)

  T.it("render returns string directly", function()
    local r = M.render("{{x}}", {x="test"})
    T.eq(r, "test")
  end)
end)

-- ============================================================
T.describe("engine isolation", function()
  T.it("engine instances share no state with each other", function()
    local e1 = M.new()
    local e2 = M.new()
    e1:partial("foo", "from-e1")
    -- e2 should not see e1's partial
    T.eq(e2:render("{{>foo}}", {}), "")
  end)

  T.it("engine filter does not leak to other engines", function()
    local e1 = M.new()
    local e2 = M.new()
    e1:filter("rev", function(v) return v:reverse() end)
    -- e2 does not have rev, so it pass-throughs
    T.eq(e2:render("{{x|rev}}", {x="abc"}), "abc")
    -- e1 has it
    T.eq(e1:render("{{x|rev}}", {x="abc"}), "cba")
  end)

  T.it("engine render method works", function()
    local e = M.new()
    T.eq(e:render("{{a}}+{{b}}", {a="1", b="2"}), "1+2")
  end)
end)

-- ============================================================
T.describe("error handling", function()
  T.it("compile returns nil, err on bad template", function()
    local fn, err = M.compile("{{#if x}}")
    T.eq(fn, nil)
    T.ok(err ~= nil)
  end)

  T.it("render returns nil, err on bad template", function()
    local r, err = M.render("{{unclosed", {})
    T.eq(r, nil)
    T.ok(err ~= nil)
  end)

  T.it("unknown block open returns error", function()
    local fn, err = M.compile("{{#foo bar}}{{/foo}}")
    T.eq(fn, nil)
    T.ok(err ~= nil)
  end)
end)

-- ============================================================
T.describe("edge cases", function()
  T.it("empty template", function()
    T.eq(M.render("", {}), "")
  end)

  T.it("template with only whitespace", function()
    T.eq(M.render("   ", {}), "   ")
  end)

  T.it("variable in middle of text", function()
    T.eq(M.render("a{{x}}b", {x="-"}), "a-b")
  end)

  T.it("dotted path access", function()
    T.eq(M.render("{{user.name}}", {user={name="Pat"}}), "Pat")
  end)

  T.it("_tier is pure", function()
    T.eq(M._tier, "pure")
  end)
end)
