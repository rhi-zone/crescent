-- lib/rehype_urls/init.lua
-- rehype plugin: transform URLs in hast elements. Port of rehype-urls.
--
-- Visits all elements and calls a user-supplied function for each URL found
-- in known URL-bearing attributes (href, src, action, data). If the function
-- returns a non-nil, non-false value, the attribute is replaced with that
-- string.
--
-- URL attributes checked per element:
--   href   → a, link (and any other element with href)
--   src    → img, script, iframe, audio, video, source
--   action → form
--   data   → object
--
-- Usage:
--   local rehype    = require("lib.unified.rehype")
--   local urls      = require("lib.unified.rehype_urls")
--   local processor = rehype():use(urls, function(url, node)
--     if url:sub(1,1) == "/" then
--       return "https://example.com" .. url
--     end
--   end)

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local M = {}

-- ── URL attribute map ─────────────────────────────────────────────────────────

-- Attributes that carry URLs. We check all of these on every element rather
-- than gating on tag name, so custom elements and future HTML are handled.
local URL_ATTRS = { "href", "src", "action", "data" }

-- ── Tree walker ───────────────────────────────────────────────────────────────

--:: HastNode = { type: string, tag?: string, props?: { [string]: unknown }, children?: { [integer]: HastNode }, ... }
--: (HastNode, (...unknown) -> unknown) -> nil
local function walk(node, fn)
  if node.type == "element" then
    local props = node.props
    if props then
      for _, attr in ipairs(URL_ATTRS) do
        local val = props[attr]
        if val and type(val) == "string" then
          local new_val = fn(val, node)
          if new_val ~= nil and new_val ~= false then
            props[attr] = tostring(new_val)
          end
        end
      end
    end
  end
  if node.children then
    for _, child in ipairs(node.children) do
      walk(child, fn)
    end
  end
end

-- ── Plugin ────────────────────────────────────────────────────────────────────

--: (unknown, unknown) -> nil
function M.plugin(processor, opts)
  -- opts is the URL transform function itself (following the JS convention of
  -- passing the handler directly as the options argument).
  local fn = opts --[[:! (...unknown) -> unknown]]
  if type(fn) ~= "function" then
    error("rehype_urls: opts must be a function(url, node) -> string|nil")
  end
  ;(processor --[[:! { use_transformer: (...unknown) -> unknown, ... }]]):use_transformer(function(tree)
    walk(tree, fn)
    return tree
  end)
end

setmetatable(M, {
  __call = function(_self, processor, opts)
    M.plugin(processor, opts)
  end,
})

return M
