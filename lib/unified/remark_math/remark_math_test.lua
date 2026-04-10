-- lib/unified/remark_math/remark_math_test.lua
-- Tests for the remark_math plugin.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T           = require("lib.test.assert")
local remark      = require("lib.unified.remark")
local math_plugin = require("lib.unified.remark_math")

-- Parse helper: parse then run transformers.
local function parse(processor, src)
  local ast = processor:parse(src)
  return processor:run(ast)
end

-- ── Block math ────────────────────────────────────────────────────────────────

T.describe("remark_math: block math", function()
  local processor = remark():use(math_plugin)

  T.it("multi-line $$...$$  paragraph becomes a math node", function()
    local ast = parse(processor, "$$\n\\frac{a}{b}\n$$")
    T.eq(#ast.children, 1)
    local node = ast.children[1]
    T.eq(node.type, "math")
    T.eq(node.value, "\\frac{a}{b}")
    T.eq(node.meta, nil)
  end)

  T.it("multi-line block math with multiple inner lines", function()
    local ast = parse(processor, "$$\na + b\n= c\n$$")
    local node = ast.children[1]
    T.eq(node.type, "math")
    T.eq(node.value, "a + b\n= c")
  end)

  T.it("block math surrounded by other content", function()
    local ast = parse(processor, "Before.\n\n$$\nx^2\n$$\n\nAfter.")
    T.eq(#ast.children, 3)
    T.eq(ast.children[1].type, "paragraph")
    T.eq(ast.children[2].type, "math")
    T.eq(ast.children[2].value, "x^2")
    T.eq(ast.children[3].type, "paragraph")
  end)

  T.it("single-line $$content$$ paragraph becomes a math node", function()
    local ast = parse(processor, "$$E=mc^2$$")
    local node = ast.children[1]
    T.eq(node.type, "math")
    T.eq(node.value, "E=mc^2")
  end)

  T.it("paragraph that is not block math is left as paragraph", function()
    local ast = parse(processor, "Just a paragraph.")
    T.eq(ast.children[1].type, "paragraph")
  end)
end)

-- ── Inline math ───────────────────────────────────────────────────────────────

T.describe("remark_math: inline math", function()
  local processor = remark():use(math_plugin)

  T.it("$...$ inside a paragraph becomes an inlineMath node", function()
    local ast = parse(processor, "Inline $E=mc^2$ formula.")
    local p = ast.children[1]
    T.eq(p.type, "paragraph")
    -- children: text "Inline ", inlineMath, text " formula."
    T.eq(#p.children, 3)
    T.eq(p.children[1].type, "text")
    T.eq(p.children[1].value, "Inline ")
    T.eq(p.children[2].type, "inlineMath")
    T.eq(p.children[2].value, "E=mc^2")
    T.eq(p.children[3].type, "text")
    T.eq(p.children[3].value, " formula.")
  end)

  T.it("multiple inline math spans in one paragraph", function()
    local ast = parse(processor, "$a$ and $b$.")
    local p = ast.children[1]
    local math_nodes = {}
    for i = 1, #p.children do
      if p.children[i].type == "inlineMath" then
        math_nodes[#math_nodes + 1] = p.children[i]
      end
    end
    T.eq(#math_nodes, 2)
    T.eq(math_nodes[1].value, "a")
    T.eq(math_nodes[2].value, "b")
  end)

  T.it("text with no $ is unchanged", function()
    local ast = parse(processor, "No math here.")
    local p = ast.children[1]
    T.eq(#p.children, 1)
    T.eq(p.children[1].type, "text")
    T.eq(p.children[1].value, "No math here.")
  end)

  T.it("inline math at start of paragraph", function()
    local ast = parse(processor, "$x$ is a variable.")
    local p = ast.children[1]
    T.eq(p.children[1].type, "inlineMath")
    T.eq(p.children[1].value, "x")
  end)

  T.it("inline math at end of paragraph", function()
    local ast = parse(processor, "The answer is $42$")
    local p = ast.children[1]
    local last = p.children[#p.children]
    T.eq(last.type, "inlineMath")
    T.eq(last.value, "42")
  end)
end)

-- ── single_dollar_tex_math_equation = false ───────────────────────────────────

T.describe("remark_math: single_dollar disabled", function()
  local processor = remark():use(math_plugin, { single_dollar_tex_math_equation = false })

  T.it("$...$ is NOT converted to inlineMath when disabled", function()
    local ast = parse(processor, "Price is $10 and more.")
    local p = ast.children[1]
    for i = 1, #p.children do
      T.ok(p.children[i].type ~= "inlineMath", "no inlineMath when single_dollar disabled")
    end
  end)

  T.it("block $$...$$ still works when single_dollar disabled", function()
    local ast = parse(processor, "$$\nx^2\n$$")
    local node = ast.children[1]
    T.eq(node.type, "math")
    T.eq(node.value, "x^2")
  end)
end)

-- ── Module callable ───────────────────────────────────────────────────────────

T.describe("remark_math: module callable", function()
  T.it("module is callable as a plugin directly", function()
    local p = remark():use(math_plugin)
    local ast = parse(p, "$x$")
    local node = ast.children[1].children[1]
    T.eq(node.type, "inlineMath")
    T.eq(node.value, "x")
  end)

  T.it("M.plugin alias works", function()
    local p = remark():use(math_plugin.plugin)
    local ast = parse(p, "$$\ny\n$$")
    T.eq(ast.children[1].type, "math")
  end)
end)
