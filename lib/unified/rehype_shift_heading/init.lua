-- lib/unified/rehype_shift_heading/init.lua
-- rehype plugin: shift heading levels by a fixed amount.
-- Port of rehype-shift-heading.
--
-- h1 → h3 with shift=2. Clamped: never below h1, never above h6.
--
-- Options:
--   opts.shift  integer  Amount to shift (positive = down, negative = up).
--                        Default: 1.

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local M = {}

-- ── Heading tags ──────────────────────────────────────────────────────────────

local HEADING_LEVEL = { h1=1, h2=2, h3=3, h4=4, h5=5, h6=6 } --: { [string]: integer }

-- ── Tree walker ───────────────────────────────────────────────────────────────

--: (any, number) -> nil
local function walk(node, shift)
  if node.type == "element" then
    local level = HEADING_LEVEL[(node.tag --[[:! string]])]
    if level then
      local new_level = level + shift --[[:! number]]
      if new_level < 1 then new_level = 1 end
      local new_level_ = new_level --[[:! number]]
      if new_level_ > 6 then new_level_ = 6 end
      node.tag = "h" .. new_level_
    end
  end
  if node.children then
    for _, child in ipairs(node.children) do
      walk(child, shift)
    end
  end
end

-- ── Plugin ────────────────────────────────────────────────────────────────────

--: (any, any) -> nil
function M.plugin(processor, opts)
  opts = opts or {}
  local shift = (opts.shift or 1) --[[:! number]]
  processor:use_transformer(function(tree)
    walk(tree, shift)
    return tree
  end)
end

setmetatable(M, {
  __call = function(_self, processor, opts)
    M.plugin(processor, opts)
  end,
})

return M
