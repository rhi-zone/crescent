-- lib/rehype_sanitize/init.lua
-- rehype plugin: allowlist-based HTML sanitization.
-- Port of rehype-sanitize.
--
-- Walks the hast tree and:
--   1. Removes disallowed elements. script/style and their children are dropped
--      entirely. Other disallowed elements are unwrapped (children preserved).
--   2. Strips disallowed properties from allowed elements.
--   3. For href/src (and any attribute listed in schema.protocols), removes the
--      attribute if its protocol is not in the allowlist. Relative URLs
--      ("#anchor", "/path", "./path", bare words) are always allowed.
--
-- Options:
--   opts.schema   table   sanitization schema (see DEFAULT_SCHEMA below).
--                         When omitted, the GitHub-flavored default is used.
--
-- Plugin signature (unified):
--   function(processor, opts)
--
-- Usage:
--   local rehype   = require("lib.rehype")
--   local sanitize = require("lib.rehype_sanitize")
--   local processor = rehype():use(sanitize)

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local M = {}

-- ── Default schema (GitHub-flavored) ─────────────────────────────────────────

M.DEFAULT_SCHEMA = {
  elements = {
    "a", "b", "blockquote", "br", "code", "dd", "del", "details",
    "div", "dl", "dt", "em", "h1", "h2", "h3", "h4", "h5", "h6",
    "hr", "i", "img", "input", "kbd", "li", "ol", "p", "pre",
    "section", "strong", "sub", "sup", "summary", "table", "tbody",
    "td", "th", "thead", "tr", "ul",
  },
  attributes = {
    a     = { "href", "title" },
    img   = { "src", "alt", "title", "width", "height" },
    input = { "type", "checked", "disabled" },
    td    = { "align" },
    th    = { "align" },
    ["*"] = { "class" },
  },
  protocols = {
    href = { "http", "https", "mailto", "#" },
    src  = { "http", "https" },
  },
}

-- ── Schema compilation ────────────────────────────────────────────────────────

-- Convert the schema's list-based tables into sets for O(1) lookup.
--: (any) -> any
local function compile_schema(schema)
  -- elements set
  local elem_set = {}
  for _, e in ipairs(schema.elements) do elem_set[e] = true end

  -- per-tag attribute sets (merged with "*" attributes)
  local global_attrs = {}
  if schema.attributes["*"] then
    for _, a in ipairs(schema.attributes["*"]) do global_attrs[a] = true end
  end

  local attr_sets = {}  -- tag -> set of allowed attr names
  for tag, attrs in pairs(schema.attributes) do
    if tag ~= "*" then
      local s = {}
      for k in pairs(global_attrs) do s[k] = true end
      for _, a in ipairs(attrs) do s[a] = true end
      attr_sets[tag] = s
    end
  end

  -- protocol sets per attribute name
  local proto_sets = {}
  if schema.protocols then
    for attr, protos in pairs(schema.protocols) do
      local s = {}
      for _, p in ipairs(protos) do s[p] = true end
      proto_sets[attr] = s
    end
  end

  return {
    elem_set    = elem_set,
    attr_sets   = attr_sets,
    global_attrs = global_attrs,
    proto_sets  = proto_sets,
  }
end

-- ── Protocol checking ─────────────────────────────────────────────────────────

-- Elements whose entire subtree is dropped when disallowed.
local DROP_WITH_CHILDREN = { script = true, style = true }

-- Return the protocol portion of a URL string, or nil for relative URLs.
-- "https://example.com" -> "https"
-- "#anchor"             -> "#"
-- "/path"               -> nil (relative, always allowed)
-- "mailto:foo"          -> "mailto"
--: (string) -> string | nil
local function url_protocol(url)
  -- Anchor shorthand.
  if url:sub(1, 1) == "#" then return "#" end
  -- Protocol with "://".
  local colon = url:find(":", 1, true)
  if colon then
    -- Distinguish "mailto:foo" (colon, no slash) from "https://foo".
    -- In both cases the protocol is everything before the colon.
    -- But "/path" starts with "/" so colon won't be at pos 1.
    local before = url:sub(1, colon - 1)
    -- Must be all alpha chars to count as a protocol scheme.
    if before:match("^[%a][%a%d%+%-%.]*$") then
      return before
    end
  end
  -- Relative URL — no protocol to check.
  return nil
end

-- Return true if the URL value is allowed given the protocol set for this attr.
--: (string, any) -> boolean
local function proto_allowed(value, proto_set)
  local proto = url_protocol(value)
  if proto == nil then
    -- Relative URL: always allowed.
    return true
  end
  return proto_set[proto] == true
end

-- ── Sanitize a single element's props ────────────────────────────────────────

--: (any, string, any) -> any
local function sanitize_props(props, tag, compiled)
  if not props then return {} end
  local allowed = compiled.attr_sets[tag] or compiled.global_attrs
  local proto_sets = compiled.proto_sets
  local out = {}
  for k, v in pairs(props) do
    local ks = tostring(k)
    if allowed[ks] then
      -- Check protocol constraint if applicable.
      local ps = proto_sets[ks]
      if ps and type(v) == "string" then
        if proto_allowed(v, ps) then
          out[ks] = v
        end
        -- else: drop attr (bad protocol)
      else
        out[ks] = v
      end
    end
  end
  return out
end

-- ── Tree sanitizer ────────────────────────────────────────────────────────────

-- Returns a list of hast nodes to replace `node` with (may be empty, one, or
-- multiple nodes when an element is unwrapped).
local sanitize_node  -- forward declaration

--: (any) -> any
local function sanitize_children(children, compiled)
  if not children then return {} end
  local out = {}
  for _, child in ipairs(children) do
    local replacements = sanitize_node(child, compiled)
    for _, r in ipairs(replacements) do
      out[#out + 1] = r
    end
  end
  return out
end

--: (any, any) -> any
sanitize_node = function(node, compiled)
  local t = node.type

  if t == "text" or t == "raw" then
    return { node }
  end

  if t == "root" then
    node.children = sanitize_children(node.children, compiled)
    return { node }
  end

  if t == "element" then
    local tag = node.tag

    if not compiled.elem_set[tag] then
      -- Disallowed element.
      if DROP_WITH_CHILDREN[tag] then
        -- Drop entirely (script, style, …).
        return {}
      else
        -- Unwrap: replace element with its sanitized children.
        return sanitize_children(node.children, compiled)
      end
    end

    -- Allowed element: sanitize props and recurse into children.
    node.props    = sanitize_props(node.props, tag, compiled)
    node.children = sanitize_children(node.children, compiled)
    return { node }
  end

  -- Unknown node type: pass through unchanged.
  return { node }
end

-- ── Plugin ────────────────────────────────────────────────────────────────────

--: (any, any) -> nil
function M.plugin(processor, opts)
  opts = opts or {}
  local schema   = opts.schema or M.DEFAULT_SCHEMA
  local compiled = compile_schema(schema)

  processor:use_transformer(function(tree)
    local result = sanitize_node(tree, compiled)
    -- The root node is always returned as a single-element list.
    return result[1] or tree
  end)
end

setmetatable(M, {
  __call = function(_self, processor, opts)
    M.plugin(processor, opts)
  end,
})

return M
