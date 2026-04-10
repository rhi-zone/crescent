-- lib/rehype_external_links/rehype_external_links_test.lua
if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T              = require("lib.test.assert")
local externalLinks  = require("lib.unified.rehype_external_links")

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Build a minimal hast tree containing a single <a> element.
local function make_link(href, extra_props)
  local props = extra_props or {}
  props.href  = href
  return {
    type     = "root",
    children = {
      { type = "element", tag = "a", props = props, children = {} },
    },
  }
end

-- Run the plugin's transformer directly on a tree and return the first child.
local function run(tree, opts)
  -- Collect the transformer registered by the plugin.
  local transformer
  local fake_processor = {
    use_transformer = function(_self, fn)
      transformer = fn
    end,
  }
  externalLinks.plugin(fake_processor, opts)
  transformer(tree)
  return tree.children[1]
end

-- ── Tests ─────────────────────────────────────────────────────────────────────

T.describe("rehype_external_links", function()

  T.it("adds target and rel to external https link", function()
    local node = run(make_link("https://example.com"))
    T.eq(node.props.target, "_blank")
    T.eq(node.props.rel,    "nofollow noopener noreferrer")
  end)

  T.it("adds target and rel to external http link", function()
    local node = run(make_link("http://example.com/page"))
    T.eq(node.props.target, "_blank")
    T.eq(node.props.rel,    "nofollow noopener noreferrer")
  end)

  T.it("does not modify a relative link", function()
    local node = run(make_link("/about"))
    T.eq(node.props.target, nil)
    T.eq(node.props.rel,    nil)
  end)

  T.it("does not modify an anchor link", function()
    local node = run(make_link("#section"))
    T.eq(node.props.target, nil)
    T.eq(node.props.rel,    nil)
  end)

  T.it("does not modify a mailto link (not in default protocols)", function()
    local node = run(make_link("mailto:user@example.com"))
    T.eq(node.props.target, nil)
    T.eq(node.props.rel,    nil)
  end)

  T.it("opts.target=false omits target attribute", function()
    local node = run(make_link("https://example.com"), { target = false })
    T.eq(node.props.target, nil)
    T.eq(node.props.rel,    "nofollow noopener noreferrer")
  end)

  T.it("opts.rel as string is used verbatim", function()
    local node = run(make_link("https://example.com"), { rel = "noopener" })
    T.eq(node.props.rel, "noopener")
  end)

  T.it("opts.rel as table is joined with spaces", function()
    local node = run(make_link("https://example.com"), { rel = {"noopener", "noreferrer"} })
    T.eq(node.props.rel, "noopener noreferrer")
  end)

  T.it("opts.protocols controls what counts as external", function()
    -- ftp:// is not external by default.
    local node_default = run(make_link("ftp://files.example.com"))
    T.eq(node_default.props.target, nil)

    -- But it is when ftp is added to protocols.
    local node_custom = run(make_link("ftp://files.example.com"), { protocols = {"ftp"} })
    T.eq(node_custom.props.target, "_blank")
  end)

  T.it("merges rel with existing rel attribute", function()
    local node = run(make_link("https://example.com", { rel = "sponsored" }))
    T.eq(node.props.rel, "sponsored nofollow noopener noreferrer")
  end)

  T.it("processes nested links inside other elements", function()
    local tree = {
      type     = "root",
      children = {
        {
          type     = "element",
          tag      = "p",
          props    = {},
          children = {
            { type = "element", tag = "a",
              props = { href = "https://deep.example.com" }, children = {} },
          },
        },
      },
    }
    local transformer
    local fake = { use_transformer = function(_s, fn) transformer = fn end }
    externalLinks.plugin(fake)
    transformer(tree)
    local a = tree.children[1].children[1]
    T.eq(a.props.target, "_blank")
  end)

end)
