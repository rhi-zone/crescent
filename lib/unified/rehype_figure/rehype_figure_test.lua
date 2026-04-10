-- lib/unified/rehype_figure/rehype_figure_test.lua
if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T      = require("lib.test.assert")
local hast   = require("lib.unified.hast")
local figure = require("lib.unified.rehype_figure")
local rehype = require("lib.unified.rehype")

-- Helper: build an element node inline.
local function el(tag, props, children)
  return { type = "element", tag = tag, props = props or {}, children = children or {} }
end
local function txt(v)
  return { type = "text", value = v }
end

-- Helper: run the figure plugin on a root and return HTML.
local function run(root, opts)
  local p = rehype():use(figure, opts)
  return p:stringify(p:run(root))
end

T.describe("rehype_figure: standalone img in <p>", function()
  T.it("wraps img in figure with figcaption when alt present", function()
    local root = {
      type = "root",
      children = {
        el("p", {}, { el("img", { src = "cat.png", alt = "A cat" }, {}) }),
      },
    }
    local html = run(root)
    T.ok(html:find("<figure>", 1, true), "has <figure>")
    T.ok(html:find("<figcaption>A cat</figcaption>", 1, true), "has figcaption")
    T.ok(html:find('<img', 1, true), "has img")
    T.ok(not html:find("<p>", 1, true), "<p> replaced")
  end)

  T.it("omits figcaption when alt is empty", function()
    local root = {
      type = "root",
      children = {
        el("p", {}, { el("img", { src = "x.png", alt = "" }, {}) }),
      },
    }
    local html = run(root)
    T.ok(html:find("<figure>", 1, true), "has figure")
    T.ok(not html:find("figcaption", 1, true), "no figcaption")
  end)

  T.it("omits figcaption when alt is absent", function()
    local root = {
      type = "root",
      children = {
        el("p", {}, { el("img", { src = "x.png" }, {}) }),
      },
    }
    local html = run(root)
    T.ok(not html:find("figcaption", 1, true), "no figcaption")
  end)

  T.it("adds class to figure when opts.class is set", function()
    local root = {
      type = "root",
      children = {
        el("p", {}, { el("img", { src = "x.png", alt = "hi" }, {}) }),
      },
    }
    local html = run(root, { class = "media" })
    T.ok(html:find('class="media"', 1, true), "figure has class")
  end)

  T.it("does not wrap <p> with multiple children", function()
    local root = {
      type = "root",
      children = {
        el("p", {}, {
          el("img", { src = "x.png", alt = "hi" }, {}),
          txt(" more text"),
        }),
      },
    }
    local html = run(root)
    T.ok(html:find("<p>", 1, true), "<p> preserved")
    T.ok(not html:find("<figure>", 1, true), "no figure")
  end)

  T.it("does not wrap <p> when child is not an img", function()
    local root = {
      type = "root",
      children = {
        el("p", {}, { el("span", {}, { txt("text") }) }),
      },
    }
    local html = run(root)
    T.ok(html:find("<p>", 1, true), "<p> preserved")
    T.ok(not html:find("<figure>", 1, true), "no figure")
  end)

  T.it("leaves non-p elements untouched", function()
    local root = {
      type = "root",
      children = {
        el("h1", {}, { txt("Title") }),
        el("p", {}, { el("img", { src = "a.png", alt = "img" }, {}) }),
      },
    }
    local html = run(root)
    T.ok(html:find("<h1>", 1, true), "h1 preserved")
    T.ok(html:find("<figure>", 1, true), "figure added")
  end)
end)
