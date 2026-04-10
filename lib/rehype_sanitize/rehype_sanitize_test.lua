-- lib/rehype_sanitize/rehype_sanitize_test.lua
if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T        = require("lib.test.assert")
local sanitize = require("lib.rehype_sanitize")

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Run the sanitize transformer on a tree and return the result root.
local function run(tree, opts)
  local transformer
  local fake = { use_transformer = function(_s, fn) transformer = fn end }
  sanitize.plugin(fake, opts)
  return transformer(tree)
end

-- Build a root containing a single element.
local function root_with(elem)
  return { type = "root", children = { elem } }
end

local function el(tag, props, children)
  return { type = "element", tag = tag, props = props or {}, children = children or {} }
end

local function text(v)
  return { type = "text", value = v }
end

-- ── Tests ─────────────────────────────────────────────────────────────────────

T.describe("rehype_sanitize", function()

  -- 1. Allowed element passes through.
  T.it("allowed element passes through unchanged", function()
    local tree = run(root_with(el("p", {}, { text("hello") })))
    T.eq(#tree.children, 1)
    T.eq(tree.children[1].tag, "p")
    T.eq(tree.children[1].children[1].value, "hello")
  end)

  -- 2. script element is dropped entirely with its children.
  T.it("script element is removed with children", function()
    local tree = run(root_with(
      el("script", {}, { text("alert(1)") })
    ))
    T.eq(#tree.children, 0)
  end)

  -- 3. style element is dropped entirely with its children.
  T.it("style element is removed with children", function()
    local tree = run(root_with(
      el("style", {}, { text("body{color:red}") })
    ))
    T.eq(#tree.children, 0)
  end)

  -- 4. Disallowed element (span) is unwrapped — children are preserved.
  T.it("disallowed element span is unwrapped, children preserved", function()
    local tree = run(root_with(
      el("span", {}, { text("inside span") })
    ))
    -- span is removed; text child is hoisted.
    T.eq(#tree.children, 1)
    T.eq(tree.children[1].type, "text")
    T.eq(tree.children[1].value, "inside span")
  end)

  -- 5. Disallowed attribute is stripped from an allowed element.
  T.it("disallowed attribute is stripped", function()
    local tree = run(root_with(
      el("p", { ["onclick"] = "evil()", class = "ok" }, {})
    ))
    local p = tree.children[1]
    T.eq(p.props["onclick"], nil)
    T.eq(p.props["class"],   "ok")
  end)

  -- 6. href with javascript: protocol is stripped.
  T.it("href with javascript: protocol is removed", function()
    local tree = run(root_with(
      el("a", { href = "javascript:alert(1)", title = "bad" }, {})
    ))
    local a = tree.children[1]
    T.eq(a.props.href,  nil)
    -- title is in the allowlist for <a>, so it stays.
    T.eq(a.props.title, "bad")
  end)

  -- 7. href with https: is allowed.
  T.it("href with https: is allowed", function()
    local tree = run(root_with(
      el("a", { href = "https://example.com" }, {})
    ))
    T.eq(tree.children[1].props.href, "https://example.com")
  end)

  -- 8. Relative href ("/path") is allowed (no protocol).
  T.it("relative href is allowed", function()
    local tree = run(root_with(
      el("a", { href = "/about" }, {})
    ))
    T.eq(tree.children[1].props.href, "/about")
  end)

  -- 9. Anchor href ("#section") is allowed.
  T.it("anchor href is allowed", function()
    local tree = run(root_with(
      el("a", { href = "#section" }, {})
    ))
    T.eq(tree.children[1].props.href, "#section")
  end)

  -- 10. class is allowed on any element via ["*"].
  T.it("class attribute allowed on any allowed element via wildcard", function()
    local tree = run(root_with(
      el("blockquote", { class = "highlight", onclick = "bad()" }, {})
    ))
    local bq = tree.children[1]
    T.eq(bq.props["class"],   "highlight")
    T.eq(bq.props["onclick"], nil)
  end)

  -- 11. img src with data: protocol is stripped (not in default allowlist).
  T.it("img src with data: protocol is removed", function()
    local tree = run(root_with(
      el("img", { src = "data:image/png;base64,abc", alt = "pic" }, {})
    ))
    local img = tree.children[1]
    T.eq(img.props.src, nil)
    T.eq(img.props.alt, "pic")
  end)

  -- 12. Custom schema works.
  T.it("custom schema is respected", function()
    local schema = {
      elements   = { "b" },
      attributes = { ["*"] = {} },
      protocols  = {},
    }
    -- b is allowed, span is not.
    local tree = run({
      type     = "root",
      children = {
        el("b",    { class = "x" }, { text("bold") }),
        el("span", { class = "y" }, { text("raw")  }),
      },
    }, { schema = schema })

    -- b stays (class stripped, not in any allowlist for "b")
    T.eq(#tree.children, 2)
    T.eq(tree.children[1].tag,   "b")
    T.eq(tree.children[1].props["class"], nil)
    -- span unwrapped → text node
    T.eq(tree.children[2].type,  "text")
    T.eq(tree.children[2].value, "raw")
  end)

  -- 13. Deeply nested disallowed element is unwrapped recursively.
  T.it("deeply nested disallowed element is unwrapped", function()
    local tree = run(root_with(
      el("p", {}, {
        el("span", {}, { text("a") }),
        text("b"),
      })
    ))
    local p = tree.children[1]
    -- span is unwrapped: children are [text("a"), text("b")]
    T.eq(#p.children, 2)
    T.eq(p.children[1].value, "a")
    T.eq(p.children[2].value, "b")
  end)

  -- 14. Text nodes pass through unmodified.
  T.it("text nodes are passed through unchanged", function()
    local tree = run({ type = "root", children = { text("hello world") } })
    T.eq(#tree.children, 1)
    T.eq(tree.children[1].value, "hello world")
  end)

end)
