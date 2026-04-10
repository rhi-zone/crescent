-- lib/remark_frontmatter/init.lua
-- remark plugin that extracts YAML or TOML frontmatter from Markdown source.
--
-- When registered, the plugin wraps the processor's parser so that:
--   1. If the source begins with a recognised frontmatter fence (`---` for YAML,
--      `+++` for TOML), the block is extracted before mdast sees the rest.
--   2. A frontmatter AST node (`{type="yaml"|"toml", value=<content>}`) is
--      prepended to the root's children list.
--   3. The remainder of the document is parsed normally.
--
-- If no frontmatter is found the source is forwarded unchanged.
--
-- Usage:
--   local remark      = require("lib.remark")
--   local frontmatter = require("lib.remark_frontmatter")
--
--   local processor = remark():use(frontmatter)
--   local ast = processor:parse("---\ntitle: Hello\n---\n\n# Hello")
--   -- ast.children[1] == { type = "yaml", value = "title: Hello" }
--   -- ast.children[2] == { type = "heading", depth = 1, ... }
--
-- Options:
--   opts.types  — array of frontmatter types to enable.
--                 Each entry is "yaml" (fence "---") or "toml" (fence "+++").
--                 Default: {"yaml"}.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- ── Fence table ──────────────────────────────────────────────────────────────

-- Maps frontmatter type name → fence string (3 chars, no newline).
local FENCES = {
  yaml = "---",
  toml = "+++",
}

-- ── Frontmatter extraction ────────────────────────────────────────────────────

-- Try to extract frontmatter of the given type from source.
-- Returns (node, rest_source) on success, or nil if no match.
--
-- Matching rules:
--   • Source must begin with the fence immediately (no leading whitespace).
--   • The opening fence line must be exactly the 3-char fence followed by \n
--     or \r\n (no trailing content, e.g. "--- extra" is not a fence).
--   • The closing fence must appear on its own line (same rule).
--   • Content between the fences is the raw frontmatter value (trailing
--     newline of the last content line is not included in `value`).
local function try_extract(source, node_type, fence)
  local fence_len = #fence  -- always 3

  -- Opening fence must be the first characters.
  if source:sub(1, fence_len) ~= fence then return nil end

  -- The character immediately after the fence must be \n or \r\n (or end of
  -- string, which would be an unterminated block — reject that).
  local open_end  -- byte index of the first character after the opening line
  local ch4 = source:sub(fence_len + 1, fence_len + 1)
  if ch4 == "\n" then
    open_end = fence_len + 2
  elseif ch4 == "\r" and source:sub(fence_len + 2, fence_len + 2) == "\n" then
    open_end = fence_len + 3
  else
    -- Trailing content on the opening line (e.g. "--- extra") — not a fence.
    return nil
  end

  -- Scan for the closing fence.  It must appear at the start of a line.
  local pos = open_end
  local src_len = #source
  while pos <= src_len do
    local nl = source:find("\n", pos, true)
    local line_end = nl or (src_len + 1)
    local line = source:sub(pos, line_end - 1)
    -- Strip trailing \r.
    if line:sub(-1) == "\r" then line = line:sub(1, -2) end

    if line == fence then
      -- Found the closing fence.
      local content = source:sub(open_end, pos - 1)
      -- Remove the trailing newline from the content (the \n before the fence).
      if content:sub(-2) == "\r\n" then
        content = content:sub(1, -3)
      elseif content:sub(-1) == "\n" then
        content = content:sub(1, -2)
      end

      -- Rest of the document starts after the closing fence line.
      local rest_start = (nl and nl + 1) or (src_len + 1)
      local rest = source:sub(rest_start)

      local node = { type = node_type, value = content }
      return node, rest
    end

    pos = line_end + 1
  end

  -- No closing fence found.
  return nil
end

-- ── Plugin ────────────────────────────────────────────────────────────────────

local function remark_frontmatter(processor, opts)
  -- Resolve which types are active.
  local types = (opts and opts.types) or { "yaml" }

  -- Capture the existing parser so we can delegate to it.
  local inner_parser = processor._parser

  processor:parser(function(source)
    -- Try each active type in order.
    for i = 1, #types do
      local name  = types[i]
      local fence = FENCES[name]
      if fence then
        local fm_node, rest = try_extract(source, name, fence)
        if fm_node then
          -- Parse the rest of the document (may be empty string).
          local ast, err
          if inner_parser then
            ast, err = inner_parser(rest)
          else
            return nil, "remark_frontmatter: no base parser registered"
          end
          if not ast then return nil, err end
          -- Prepend the frontmatter node to the root's children.
          local children = ast.children or {}
          table.insert(children, 1, fm_node)
          ast.children = children
          return ast
        end
      end
    end

    -- No frontmatter found: delegate as-is.
    if inner_parser then
      return inner_parser(source)
    end
    return nil, "remark_frontmatter: no base parser registered"
  end)
end

-- Make the module callable as a plugin:
--   processor:use(frontmatter)
setmetatable(M, { __call = function(_, ...) return remark_frontmatter(...) end })

M.plugin = remark_frontmatter

return M
