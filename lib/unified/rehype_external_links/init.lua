-- lib/rehype_external_links/init.lua
-- rehype plugin: add target and rel attributes to external links.
-- Port of rehype-external-links.
--
-- A link is "external" if its href starts with one of the configured protocol
-- schemes followed by "://". Internal links (relative URLs, anchors, mailto,
-- etc.) are left untouched.
--
-- Options:
--   opts.target    string | false   default "_blank". false = do not add target.
--   opts.rel       string | table   default {"nofollow","noopener","noreferrer"}.
--   opts.protocols table            default {"http","https"}.
--
-- Plugin signature (unified):
--   function(processor, opts)
--
-- Usage:
--   local rehype        = require("lib.unified.rehype")
--   local externalLinks = require("lib.unified.rehype_external_links")
--   local processor     = rehype():use(externalLinks)
--   local html          = processor:stringify(processor:run(my_hast_tree))

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local M = {}

-- ── Defaults ──────────────────────────────────────────────────────────────────

local DEFAULT_TARGET    = "_blank"
local DEFAULT_REL       = { "nofollow", "noopener", "noreferrer" }
local DEFAULT_PROTOCOLS = { "http", "https" }

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Build a set of protocol prefixes ("http://", "https://", …) for O(1) checks.
--: (any) -> any
local function build_prefix_set(protocols)
  local set = {}
  for _, p in ipairs(protocols) do
    set[tostring(p) .. "://"] = true
  end
  return set
end

-- Return true when href starts with one of the external protocol prefixes.
--: (string, any) -> boolean
local function is_external(href, prefix_set)
  -- Fast path: must contain "://" somewhere.
  local colon = href:find("://", 1, true)
  if not colon then return false end
  local prefix = href:sub(1, colon + 2)  -- e.g. "https://"
  return prefix_set[prefix] == true
end

-- Convert rel option to a space-separated string.
--: (any) -> string
local function rel_to_string(rel)
  if type(rel) == "string" then return rel end
  if type(rel) == "table" then return table.concat(rel, " ") end
  return ""
end

-- ── Tree walker ───────────────────────────────────────────────────────────────

--: (any, any, any, any) -> nil
local function walk(node, prefix_set, target, rel_str)
  if node.type == "element" and node.tag == "a" then
    local props = node.props or {}
    local href  = props.href
    if type(href) == "string" and is_external(href, prefix_set) then
      if target ~= false then
        props.target = target
      end
      if rel_str ~= "" then
        -- Merge with existing rel if present.
        if props.rel and props.rel ~= "" then
          props.rel = props.rel .. " " .. rel_str
        else
          props.rel = rel_str
        end
      end
      node.props = props
    end
  end
  if node.children then
    for _, child in ipairs(node.children) do
      walk(child, prefix_set, target, rel_str)
    end
  end
end

-- ── Plugin ────────────────────────────────────────────────────────────────────

--: (any, any) -> nil
function M.plugin(processor, opts)
  opts = opts or {}
  local target    = opts.target    == nil  and DEFAULT_TARGET    or opts.target
  local rel_opt   = opts.rel       ~= nil  and opts.rel          or DEFAULT_REL
  local protocols = opts.protocols ~= nil  and opts.protocols    or DEFAULT_PROTOCOLS

  local prefix_set = build_prefix_set(protocols)
  local rel_str    = rel_to_string(rel_opt)

  processor:use_transformer(function(tree)
    walk(tree, prefix_set, target, rel_str)
    return tree
  end)
end

setmetatable(M, {
  __call = function(_self, processor, opts)
    M.plugin(processor, opts)
  end,
})

return M
