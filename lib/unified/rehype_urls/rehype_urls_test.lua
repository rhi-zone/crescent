-- lib/rehype_urls/rehype_urls_test.lua
-- Tests for lib/unified/rehype_urls.

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T       = require("lib.test.assert")
local unified = require("lib.unified")
local urls    = require("lib.unified.rehype_urls")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function el(tag, props, children)
  return { type = "element", tag = tag, props = props or {}, children = children or {} }
end

local function text(value)
  return { type = "text", value = value }
end

local function root(children)
  return { type = "root", children = children }
end

local function make_processor(fn)
  local p = unified.new()
  p:use(urls, fn)
  return p
end

local function run(tree, fn)
  local result, err = make_processor(fn):run(tree)
  if not result then error(err) end
  return result
end

-- ── Tests ─────────────────────────────────────────────────────────────────────

T.describe("rehype_urls", function()

  T.it("transforms href on <a> elements", function()
    local tree = root({
      el("a", { href = "/about" }, { text("About") })
    })
    local out = run(tree, function(url, _node)
      if url:sub(1,1) == "/" then
        return "https://example.com" .. url
      end
    end)
    T.eq(out.children[1].props.href, "https://example.com/about")
  end)

  T.it("transforms src on <img> elements", function()
    local tree = root({
      el("img", { src = "/images/logo.png" }, {})
    })
    local out = run(tree, function(url, _node)
      return "https://cdn.example.com" .. url
    end)
    T.eq(out.children[1].props.src, "https://cdn.example.com/images/logo.png")
  end)

  T.it("transforms src on <script> elements", function()
    local tree = root({
      el("script", { src = "/js/app.js" }, {})
    })
    local out = run(tree, function(url, _node)
      return "https://cdn.example.com" .. url
    end)
    T.eq(out.children[1].props.src, "https://cdn.example.com/js/app.js")
  end)

  T.it("transforms action on <form> elements", function()
    local tree = root({
      el("form", { action = "/submit" }, {})
    })
    local out = run(tree, function(url, _node)
      return "https://api.example.com" .. url
    end)
    T.eq(out.children[1].props.action, "https://api.example.com/submit")
  end)

  T.it("transforms data on <object> elements", function()
    local tree = root({
      el("object", { data = "/file.swf" }, {})
    })
    local out = run(tree, function(url, _node)
      return "https://cdn.example.com" .. url
    end)
    T.eq(out.children[1].props.data, "https://cdn.example.com/file.swf")
  end)

  T.it("leaves URL unchanged when function returns nil", function()
    local tree = root({
      el("a", { href = "https://example.com" }, { text("link") })
    })
    local out = run(tree, function(_url, _node)
      return nil  -- no change
    end)
    T.eq(out.children[1].props.href, "https://example.com")
  end)

  T.it("leaves URL unchanged when function returns false", function()
    local tree = root({
      el("a", { href = "https://example.com" }, { text("link") })
    })
    local out = run(tree, function(_url, _node)
      return false
    end)
    T.eq(out.children[1].props.href, "https://example.com")
  end)

  T.it("passes the node to the transform function", function()
    local seen_nodes = {}
    local tree = root({
      el("a", { href = "/x" }, { text("X") })
    })
    run(tree, function(_url, node)
      seen_nodes[#seen_nodes + 1] = node
    end)
    T.eq(#seen_nodes, 1)
    T.eq(seen_nodes[1].tag, "a")
  end)

  T.it("walks into nested children", function()
    local tree = root({
      el("div", {}, {
        el("a", { href = "/deep" }, { text("Deep link") })
      })
    })
    local out = run(tree, function(url, _node)
      return "https://example.com" .. url
    end)
    local inner = out.children[1].children[1]
    T.eq(inner.props.href, "https://example.com/deep")
  end)

  T.it("skips elements without URL attributes", function()
    local tree = root({
      el("p", { class = "foo" }, { text("Hello") })
    })
    local calls = 0
    run(tree, function(_url, _node) calls = calls + 1 end)
    T.eq(calls, 0)
  end)

  T.it("transforms multiple URL attributes in the same tree", function()
    local tree = root({
      el("a", { href = "/a" }, {}),
      el("img", { src = "/img.png" }, {}),
      el("form", { action = "/post" }, {}),
    })
    local out = run(tree, function(url, _node)
      return "https://h.example.com" .. url
    end)
    T.eq(out.children[1].props.href,   "https://h.example.com/a")
    T.eq(out.children[2].props.src,    "https://h.example.com/img.png")
    T.eq(out.children[3].props.action, "https://h.example.com/post")
  end)

  T.it("errors when opts is not a function", function()
    local ok, err = pcall(function()
      local p = unified.new()
      p:use(urls, "not a function")
    end)
    T.eq(ok, false)
    T.ok(err:find("function"), "error mentions 'function'")
  end)

end)
