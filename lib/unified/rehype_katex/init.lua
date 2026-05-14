-- lib/rehype_katex/init.lua
-- rehype plugin: render math nodes as HTML containers for KaTeX/MathJax.
-- Port of rehype-katex (without a server-side KaTeX renderer).
--
-- Since we have no KaTeX renderer in Lua, we wrap raw LaTeX in semantic HTML
-- that a browser-side KaTeX or MathJax script can pick up. The output is
-- valid HTML that degrades gracefully (the LaTeX is still readable).
--
-- Input node types (produced by remark-math / lib/unified/remark_math):
--   { type = "inlineMath", value = "E=mc^2" }
--     → <span class="math math-inline"><code>E=mc^2</code></span>
--
--   { type = "math", value = "\\frac{1}{2}" }
--     → <div class="math math-display"><code>\\frac{1}{2}</code></div>
--
-- Options:
--   opts.class_names.inline   — class for inline math (default "math math-inline")
--   opts.class_names.display  — class for display math (default "math math-display")
--   opts.output               — "html" (default) or "mathml" (same as html for now)
--
-- Usage:
--   local rehype  = require("lib.unified.rehype")
--   local katex   = require("lib.unified.rehype_katex")
--   local p = rehype():use(katex)
--   local p = rehype():use(katex, { class_names = { inline = "math-inline" } })

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local M = {}

-- ── Tree transformer ──────────────────────────────────────────────────────────

--:: MathNode = { type: string, value?: string, children?: { [integer]: MathNode }, ... }
--:: processor = { parser: (processor, (string) -> unknown) -> processor, compiler: (processor, (unknown) -> string) -> processor, use_transformer: (processor, (unknown) -> unknown) -> processor, ... }
--: (MathNode, string, string, string) -> MathNode
local function make_math_node(math_node, inline_class, display_class, _output)
  local t = math_node.type
  local value = tostring(math_node.value or "")
  local code_child = { type = "element", tag = "code", props = {}, children = {
    { type = "text", value = value }
  }}
  if t == "inlineMath" then
    return {
      type = "element",
      tag = "span",
      props = { class = inline_class },
      children = { code_child },
    }
  elseif t == "math" then
    return {
      type = "element",
      tag = "div",
      props = { class = display_class },
      children = { code_child },
    }
  end
  return math_node
end

--: (MathNode, string, string, string) -> MathNode
local function transform(node, inline_class, display_class, output)
  local t = node.type
  if t == "inlineMath" or t == "math" then
    return make_math_node(node, inline_class, display_class, output)
  end
  if node.children then
    local new_children = {}
    for _, child in ipairs(node.children) do
      new_children[#new_children + 1] = transform(child, inline_class, display_class, output)
    end
    node.children = new_children
  end
  return node
end

-- ── Plugin ────────────────────────────────────────────────────────────────────

--: (processor, { class_names: { inline: string | nil, display: string | nil } | nil, output: string | nil, ... } | nil) -> nil
function M.plugin(processor, opts)
  opts = (opts or {}) --[[:! { class_names: { inline: string | nil, display: string | nil } | nil, output: string | nil }]]
  local class_names   = opts.class_names or ({} --[[:! { inline: string | nil, display: string | nil }]])
  local inline_class  = class_names.inline  or "math math-inline"
  local display_class = class_names.display or "math math-display"
  local output        = opts.output or "html"

  processor:use_transformer(function(tree)
    return transform(tree --[[:! MathNode]], inline_class, display_class, output)
  end)
end

setmetatable(M, {
  __call = function(_self, processor, opts)
    M.plugin(processor, opts)
  end,
})

return M
