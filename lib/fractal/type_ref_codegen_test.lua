-- lib/fractal/type_ref_codegen_test.lua
-- Tests for lib/fractal/type_ref_codegen.lua: identifier casing, the subtype
-- check, and JSON string quoting.
--
-- The casing expectations below are not hand-derived — every one was produced
-- by running the corresponding function in fractal's
-- packages/type-ir/src/codegen-helpers.ts and recording its output. A
-- projector's job is to emit what fractal emits, so a divergence here is a
-- port bug even when the Lua result looks more "correct" in isolation
-- (`split_words("foo.bar")` really does leave the dot alone — `.` is not one
-- of the separators that variant splits on).

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T        = require("lib.test.assert")
local codegen  = require("lib.fractal.type_ref_codegen")
local type_ref = require("lib.fractal.type_ref")

T.describe("lib.fractal.type_ref_codegen", function()

  T.describe("pascal_case_strip_separators", function()

    -- Strips every non-alphanumeric run, uppercases what follows it, and
    -- leaves internal casing alone (the Rust/Gleam convention).
    local cases = {
      { "userName",       "UserName" },
      { "user_name",      "UserName" },
      { "user-name",      "UserName" },
      { "in-progress",    "InProgress" },
      { "foo.bar",        "FooBar" },
      { "a--b",           "AB" },
      { "_lead_",         "Lead" },
      { "a b  c",         "ABC" },
      { "active",         "Active" },
      -- Internal casing preserved: neither acronym is re-cased.
      { "HTTPHeader",     "HTTPHeader" },
      { "myHTTPValue",    "MyHTTPValue" },
      { "XMLHttpRequest", "XMLHttpRequest" },
      -- A leading digit cannot be uppercased; it passes through, so the
      -- result is not a valid identifier in any target. fractal does not
      -- guard this and neither does the port.
      { "2fast",          "2fast" },
      { "",               "" },
    }

    for i = 1, #cases do
      local input, want = cases[i][1], cases[i][2]
      T.it(string.format("%q -> %q", input, want), function()
        T.eq(codegen.pascal_case_strip_separators(input), want)
      end)
    end

  end)

  T.describe("snake_case_strip_separators", function()

    local cases = {
      { "userName",       "user_name" },
      { "user_name",      "user_name" },
      { "user-name",      "user_name" },
      { "in-progress",    "in_progress" },
      { "foo.bar",        "foo_bar" },
      { "a--b",           "a_b" },
      { "a b  c",         "a_b_c" },
      { "active",         "active" },
      { "f0oBar",         "f0o_bar" },
      -- Leading/trailing separator runs are trimmed, not turned into `_`.
      { "_lead_",         "lead" },
      -- The camel-boundary split only fires on lower/digit followed by
      -- upper, so an all-caps run collapses rather than splitting per letter.
      { "HTTPHeader",     "httpheader" },
      { "myHTTPValue",    "my_httpvalue" },
      { "XMLHttpRequest", "xmlhttp_request" },
      { "2fast",          "2fast" },
      { "",               "" },
    }

    for i = 1, #cases do
      local input, want = cases[i][1], cases[i][2]
      T.it(string.format("%q -> %q", input, want), function()
        T.eq(codegen.snake_case_strip_separators(input), want)
      end)
    end

  end)

  T.describe("pascal_case_from_words", function()

    -- The other PascalCase variant: splits into words, then lowercases the
    -- remainder of each one. Diverges from pascal_case_strip_separators on
    -- exactly two axes — acronyms get flattened, and `.` is not a separator.
    local cases = {
      { "userName",       "UserName" },
      { "user_name",      "UserName" },
      { "in-progress",    "InProgress" },
      { "a b  c",         "ABC" },
      { "_lead_",         "Lead" },
      { "active",         "Active" },
      { "f0oBar",         "F0oBar" },
      -- Acronym flattened (contrast "HTTPHeader" above).
      { "HTTPHeader",     "Httpheader" },
      { "myHTTPValue",    "MyHttpvalue" },
      { "XMLHttpRequest", "XmlhttpRequest" },
      -- `.` is not among this variant's separators, so it survives into the
      -- output (contrast "FooBar" above).
      { "foo.bar",        "Foo.bar" },
      { "2fast",          "2fast" },
      { "",               "" },
    }

    for i = 1, #cases do
      local input, want = cases[i][1], cases[i][2]
      T.it(string.format("%q -> %q", input, want), function()
        T.eq(codegen.pascal_case_from_words(input), want)
      end)
    end

  end)

  T.describe("split_words", function()

    T.it("splits on camelCase boundaries", function()
      local words = codegen.split_words("userNameValue")
      T.eq(#words, 3)
      T.eq(words[1], "user")
      T.eq(words[2], "Name")
      T.eq(words[3], "Value")
    end)

    T.it("splits on runs of underscore, hyphen, and whitespace", function()
      local words = codegen.split_words("a_b-c  d")
      T.eq(#words, 4)
      T.eq(words[1], "a")
      T.eq(words[4], "d")
    end)

    T.it("the empty string yields no words", function()
      T.eq(#codegen.split_words(""), 0)
    end)

    T.it("a string of only separators yields no words", function()
      T.eq(#codegen.split_words("__--  "), 0)
    end)

  end)

  T.describe("capitalize", function()

    T.it("uppercases the first character and leaves the rest alone", function()
      T.eq(codegen.capitalize("nameValue"), "NameValue")
    end)

    T.it("the empty string passes through", function()
      T.eq(codegen.capitalize(""), "")
    end)

  end)

  T.describe("is_a", function()

    -- Own kind prefix, so these registrations don't collide with another
    -- test file's (the lattice is module-level shared state).
    T.it("a kind is always a subtype of itself", function()
      T.eq(codegen.is_a("isa_thing", "isa_thing"), true)
    end)

    T.it("finds a target among the registered ancestors", function()
      type_ref.register_parent("isa_int32", "isa_integer")
      type_ref.register_parent("isa_integer", "isa_number")
      T.eq(codegen.is_a("isa_int32", "isa_integer"), true)
      -- Transitive: the whole chain counts, not just the immediate parent.
      T.eq(codegen.is_a("isa_int32", "isa_number"), true)
    end)

    T.it("is false for an unrelated kind and for the wrong direction", function()
      type_ref.register_parent("isa_uuid", "isa_string")
      T.eq(codegen.is_a("isa_uuid", "isa_number"), false)
      -- A parent is not a subtype of its child.
      T.eq(codegen.is_a("isa_string", "isa_uuid"), false)
    end)

    T.it("a root kind is a subtype of nothing but itself", function()
      T.eq(codegen.is_a("isa_orphan", "isa_string"), false)
      T.eq(codegen.is_a("isa_orphan", "isa_orphan"), true)
    end)

  end)

  T.describe("quote", function()

    T.it("wraps a plain string in double quotes", function()
      T.eq(codegen.quote("hello"), '"hello"')
    end)

    T.it("escapes quotes and backslashes", function()
      T.eq(codegen.quote('a"b'), '"a\\"b"')
      T.eq(codegen.quote("a\\b"), '"a\\\\b"')
    end)

    T.it("escapes the named control characters", function()
      T.eq(codegen.quote("a\nb"), '"a\\nb"')
      T.eq(codegen.quote("a\tb"), '"a\\tb"')
      T.eq(codegen.quote("a\rb"), '"a\\rb"')
    end)

    T.it("escapes an unnamed control character as \\uXXXX", function()
      T.eq(codegen.quote("a\1b"), '"a\\u0001b"')
    end)

    T.it("the empty string quotes to a pair of quotes", function()
      T.eq(codegen.quote(""), '""')
    end)

    T.it("a run of consecutive escapes emits each one", function()
      T.eq(codegen.quote('""'), '"\\"\\""')
    end)

    -- Only bytes below 0x20 (plus `"` and `\`) are escaped; everything above
    -- passes through as-is, so a UTF-8 sequence survives byte for byte.
    T.it("passes bytes above the control range through unescaped", function()
      T.eq(codegen.quote("caf\233"), '"caf\233"')
    end)

  end)

end)
