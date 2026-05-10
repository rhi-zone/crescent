-- lib/markdown_it/init.lua
-- High-level markdown processing library.
-- Combines lib/unified/mdast (parser) + lib/unified/hast (HTML backend)
-- into a simple pipeline with extension/plugin support.
--
-- API:
--   mdit.new(opts)              -> MarkdownIt instance
--   md:render(src)              -> html string
--   md:parse(src)               -> mdast root node
--   md:use(plugin, plugin_opts) -> md (chainable)
--   mdit.render(src[, opts])    -> html string (one-shot)
--
--   Built-in plugins:
--   mdit.plugin.tasklist  -- [ ] / [x] task list items
--   mdit.plugin.table     -- GFM tables (already in mdast; plugin is a no-op wire)
--   mdit.plugin.abbr      -- abbreviations: *[HTML]: Hyper Text Markup Language
--   mdit.plugin.deflist   -- definition lists (custom block)
--   mdit.plugin.footnote  -- [^1] footnotes
--
-- Options (on new/render):
--   html       boolean  allow raw HTML in source to pass through (default false)
--   breaks     boolean  soft line breaks → <br> (default false)
--   linkify    boolean  auto-linkify bare URLs (default false)
--   typographer boolean smart quotes / em-dashes (default false)
--
-- M._tier = "pure"

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

M._tier = "pure"

--:: MdNode = { type: string, ... }

-- ── Lazy-load dependencies ────────────────────────────────────────────────────

local _mdast, _hast

local function get_mdast()
  if not _mdast then _mdast = require("lib.unified.mdast") end
  return _mdast
end

local function get_hast()
  if not _hast then _hast = require("lib.unified.hast") end
  return _hast
end

-- ── HTML escaping (used by option transforms) ─────────────────────────────────

--: (string) -> string
local function escape_html(s)
  s = s:gsub("&", "&amp;")
  s = s:gsub("<", "&lt;")
  s = s:gsub(">", "&gt;")
  return s
end

-- ── AST transforms applied after parsing ─────────────────────────────────────

-- Walk an mdast tree depth-first, calling fn(node, parent, index).
-- fn may return a replacement node, nil to remove, or nothing to keep.
--: (MdNode | nil, (MdNode, ...unknown) -> unknown) -> MdNode | nil
local function walk(node, fn)
  if not node then return node end
  local children = node.children
  if children then
    local new_children = {}
    for i, child in ipairs(children --[[:! { [integer]: MdNode }]]) do
      local replaced = fn(child, node, i)
      if replaced == nil then
        -- fn returned nothing (no explicit return) — keep original then recurse
        walk(child, fn)
        new_children[#new_children + 1] = child
      elseif replaced == false then
        -- explicit false means remove this node
      else
        walk(replaced --[[:! MdNode]], fn)
        new_children[#new_children + 1] = replaced --[[:! MdNode]]
      end
    end
    node.children = new_children --[[:! { [integer]: MdNode } | nil]]
  end
  return node
end

-- ── Option transforms ─────────────────────────────────────────────────────────

-- html=false: strip raw HTML nodes (replace with escaped text).
--: (MdNode) -> MdNode
local function transform_strip_html(tree)
  walk(tree, function(node)
    if node.type == "html" then
      -- Replace with a paragraph containing escaped text.
      return { type = "paragraph", children = { { type = "text", value = escape_html(node.value or "") } } }
    else return nil
    end
  end)
  return tree
end

-- breaks=true: replace softBreak nodes with hardBreak (renders as <br>).
--: (MdNode) -> MdNode
local function transform_breaks(tree)
  walk(tree, function(node)
    if node.type == "softBreak" then
      return { type = "hardBreak" }
    else return nil
    end
  end)
  return tree
end

-- linkify=true: scan text nodes for bare URLs and wrap them in link nodes.
-- Simple heuristic: http(s):// or www. prefix, up to first whitespace.
--: (MdNode) -> MdNode
local function transform_linkify(tree)
  local url_pat = "(https?://[^%s<>\"']+)"
  walk(tree, function(node, parent)
    if node.type == "text" and parent and parent.type ~= "link" and parent.type ~= "image" then
      local value = node.value or ""
      -- Check if there's a URL in this text node.
      if value:find("https?://", 1, false) then
        -- Split text around URLs.
        local parts = {}
        local last = 1
        for s, e, url in value:gmatch("()(" .. url_pat .. ")()") do
          -- gmatch positions: s=start of match, e=actual url, url captures
          -- Re-do with find for proper positions.
          _ = s; _ = e; _ = url  -- suppress unused warning
        end
        -- Use string.find in a loop for proper indexing.
        local pos = 1
        local len = #value
        while pos <= len do
          local s, e, url = value:find("(https?://[^%s<>\"']+)", pos)
          if not s then
            -- No more URLs; append remaining text.
            if pos <= len then
              parts[#parts + 1] = { type = "text", value = value:sub(pos) }
            end
            break
          end
          -- Text before URL.
          if s > pos then
            parts[#parts + 1] = { type = "text", value = value:sub(pos, s - 1) }
          end
          -- Link node.
          parts[#parts + 1] = {
            type = "link",
            url = url,
            title = nil,
            children = { { type = "text", value = url } },
          }
          pos = e + 1
        end
        if #parts > 0 then
          -- We must splice `parts` in place of `node` in parent.children.
          -- Signal to walk() by returning a synthetic "fragment" — we can't
          -- return multiple nodes from the walker. Instead, mutate the node
          -- into a fragment container that hast will unwrap.
          node.type = "_fragment"
          node.children = parts
          node.value = nil
          return node
        end
      end
    end
  end)
  return tree
end

-- typographer=true: replace common punctuation patterns with typographic equivalents.
-- Applied on text nodes only.
--: (MdNode) -> MdNode
local function transform_typographer(tree)
  walk(tree, function(node)
    if node.type == "text" then
      local v = node.value or ""
      -- Em-dashes: --- → —
      v = v:gsub("%-%-%-", "\xe2\x80\x94")
      -- En-dashes: -- → –
      v = v:gsub("%-%-", "\xe2\x80\x93")
      -- Ellipsis: ... → …
      v = v:gsub("%.%.%.", "\xe2\x80\xa6")
      -- Double quotes: "word" → "word" (simple heuristic)
      v = v:gsub('"([^"]*)"', "\xe2\x80\x9c%1\xe2\x80\x9d")
      -- Single quotes: 'word' → 'word'
      v = v:gsub("'([^']*)'", "\xe2\x80\x98%1\xe2\x80\x99")
      node.value = v
    end
  end)
  return tree
end

-- ── hast extension: handle _fragment nodes from linkify ──────────────────────
-- Patch hast.from_mdast to handle our synthetic _fragment type by inlining children.
-- We do this by post-processing the hast tree.

--: (unknown) -> MdNode | nil
local function flatten_fragments(node)
  if not node then return nil end
  local n = node --[[:! MdNode]]
  local children = n.children
  if children then
    local new_children = {}
    for _, child in ipairs(children --[[:! { [integer]: MdNode }]]) do
      local fc = flatten_fragments(child)
      if fc and fc.type == "_fragment" then
        local fcc = fc.children
        for _, gc in ipairs((fcc or {}) --[[:! { [integer]: MdNode }]]) do
          new_children[#new_children + 1] = gc
        end
      elseif fc ~= nil then
        new_children[#new_children + 1] = fc
      end
    end
    n.children = new_children --[[:! { [integer]: MdNode } | nil]]
  end
  return n
end

-- ── MarkdownIt instance ───────────────────────────────────────────────────────

--:: MditOpts = { html: boolean, breaks: boolean, linkify: boolean, typographer: boolean }
--:: MditInstance = { _opts: MditOpts, _plugins: { [integer]: unknown, ... }, _transforms: { [integer]: (unknown) -> unknown, ... }, parse: (MditInstance, string) -> unknown, render: (MditInstance, string) -> string, use: (MditInstance, unknown, unknown | nil) -> unknown, _add_transform: (MditInstance, (unknown) -> unknown) -> nil, ... }

local MarkdownIt = {}
MarkdownIt.__index = MarkdownIt

--: ((unknown | nil)) -> unknown
function M.new(opts)
  local opts_ = (opts or {}) --[[:! { html: boolean | nil, breaks: boolean | nil, linkify: boolean | nil, typographer: boolean | nil, ... }]]
  local self = setmetatable({}, MarkdownIt)
  self._opts = {
    html        = opts_.html        or false,
    breaks      = opts_.breaks      or false,
    linkify     = opts_.linkify     or false,
    typographer = opts_.typographer or false,
  }
  -- Plugins: list of {fn, plugin_opts} pairs applied after parsing, before rendering.
  -- Each plugin is a function(md_instance, plugin_opts) → transform fn(tree) → tree
  -- OR a function that registers transforms on the instance.
  self._plugins = {}
  -- Post-parse transforms: list of fn(tree, opts) → tree
  self._transforms = {}
  return self
end

-- Use a plugin.  plugin(md_instance, plugin_opts) is called immediately.
-- Returns self for chaining.
--: (self: MditInstance, unknown, (unknown | nil)) -> unknown
function MarkdownIt:use(plugin, plugin_opts)
  local plugin_fn = plugin --[[:! (unknown, unknown | nil) -> nil]]
  plugin_fn(self, plugin_opts)
  return self
end

-- Register a post-parse transform.  fn(tree) -> tree.
--: (self: MditInstance, (unknown) -> unknown) -> ()
function MarkdownIt:_add_transform(fn)
  self._transforms[#self._transforms + 1] = fn
end

-- Parse markdown string → mdast tree (with option transforms applied).
--: (self: MditInstance, string) -> MdNode
function MarkdownIt:parse(src)
  local mdast = get_mdast()
  local tree = mdast.parse(src)

  -- Apply built-in option transforms.
  if not self._opts.html then
    tree = transform_strip_html(tree)
  end
  if self._opts.breaks then
    tree = transform_breaks(tree)
  end
  if self._opts.linkify then
    tree = transform_linkify(tree)
  end
  if self._opts.typographer then
    tree = transform_typographer(tree)
  end

  -- Apply plugin transforms.
  for _, fn in ipairs(self._transforms) do
    tree = fn(tree) or tree
  end

  return tree
end

-- Render markdown string → HTML string.
--: (self: MditInstance, string) -> string
function MarkdownIt:render(src)
  local hast = get_hast()
  local tree = self:parse(src)
  local hast_tree = hast.from_mdast(tree)
  -- Flatten _fragment nodes introduced by linkify.
  hast_tree = flatten_fragments(hast_tree)
  return hast.to_html(hast_tree)
end

-- ── One-shot convenience ──────────────────────────────────────────────────────

-- mdit.render(src) / mdit.render(src, opts) → html string
--: (string, (unknown | nil)) -> string
function M.render(src, opts)
  local inst = M.new(opts) --[[:! MditInstance]]
  return inst:render(src)
end

-- ── Built-in plugins ──────────────────────────────────────────────────────────

M.plugin = {}

-- tasklist: converts `[ ]` / `[x]` list item markers into checkbox inputs.
-- Operates on listItem nodes whose first child is a paragraph starting with
-- [ ] or [x].
M.plugin.tasklist = function(md, _opts)
  md:_add_transform(function(tree)
    walk(tree, function(node)
      if node.type == "listItem" then
        local para = node.children and node.children[1]
        if para and para.type == "paragraph" then
          local first = para.children and para.children[1]
          if first and first.type == "text" then
            local v = first.value or ""
            local checked, rest = v:match("^%[([xX ])%] ?(.*)")
            if checked then
              local is_checked = (checked == "x" or checked == "X")
              -- Replace leading text with a checkbox input node.
              first.value = rest
              -- Insert checkbox as first child of the paragraph.
              local checkbox = {
                type  = "html",
                value = is_checked
                  and '<input type="checkbox" checked disabled> '
                  or  '<input type="checkbox" disabled> ',
              }
              table.insert(para.children, 1, checkbox)
              node.checked = is_checked
            end
          end
        end
      end
    end)
    return tree
  end)
end

-- table: GFM tables are in the roadmap for lib/unified/mdast (Phase 2 known gap).
-- This plugin is a no-op wire for forward compatibility; when mdast gains GFM
-- table support the tables will render automatically without changing call sites.
M.plugin.table = function(_md, _opts)
  -- No-op: tables will be handled by the mdast parser when Phase 2 is implemented.
end

-- abbr: abbreviations expansion.
-- Syntax (anywhere in document, typically at end):
--   *[HTML]: Hyper Text Markup Language
-- After collecting definitions, wraps occurrences in text nodes with <abbr>.
M.plugin.abbr = function(md, _opts)
  md:_add_transform(function(tree)
    -- First pass: collect abbreviation definitions from paragraphs.
    local abbrs = {}  -- { term = string, title = string }
    local to_remove = {}
    walk(tree, function(node, parent, idx)
      if node.type == "paragraph" then
        local first = node.children and node.children[1]
        if first and first.type == "text" then
          local term, title = (first.value or ""):match("^%*%[([^%]]+)%]%:%s*(.*)")
          if term then
            abbrs[#abbrs + 1] = { term = term, title = title }
            to_remove[node] = { parent = parent, idx = idx }
          end
        end
      end
    end)

    -- Remove definition paragraphs (mark for deletion).
    -- We need a second walk since to_remove is keyed by node identity.
    walk(tree, function(node)
      if to_remove[node] then
        return false  -- remove
      end
    end)

    if #abbrs == 0 then return tree end

    -- Second pass: replace occurrences in text nodes.
    walk(tree, function(node, parent)
      if node.type == "text" and parent and parent.type ~= "html" then
        local v = node.value or ""
        local changed = false
        for _, ab in ipairs(abbrs) do
          -- Escape term for pattern use.
          local pat = ab.term:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
          if v:find(pat) then
            -- Split text around the term and introduce _abbr nodes.
            changed = true
            local parts = {}
            local pos = 1
            local len = #v
            while pos <= len do
              local s, e = v:find(pat, pos)
              if not s then
                parts[#parts + 1] = { type = "text", value = v:sub(pos) }
                break
              end
              if s > pos then
                parts[#parts + 1] = { type = "text", value = v:sub(pos, s - 1) }
              end
              parts[#parts + 1] = {
                type  = "html",
                value = '<abbr title="' .. (ab.title or "") .. '">' .. ab.term .. "</abbr>",
              }
              pos = e + 1
            end
            -- Mutate node into _fragment.
            node.type = "_fragment"
            node.children = parts
            node.value = nil
            v = ""  -- prevent further patterns from re-processing
          end
        end
        if changed then return node end
      end
    end)

    return tree
  end)
end

-- deflist: definition lists.
-- Syntax:
--   Term
--   :   Definition
--
-- A paragraph immediately followed by lines starting with `:` is converted
-- to a <dl>/<dt>/<dd> structure.  We implement this as a post-parse transform
-- that detects paragraphs whose text ends just before a `:` paragraph.
-- NOTE: deflist depends on the source having been re-parsed with special
-- awareness, which is hard post-hoc. We implement a best-effort approach:
-- look for consecutive paragraphs where the second starts with ": ".
M.plugin.deflist = function(md, _opts)
  md:_add_transform(function(tree)
    if not tree.children then return tree end
    local tc = tree.children --[[:! { [integer]: MdNode }]]
    local new_children = {}
    local i = 1
    while i <= #tc do
      local node = tc[i]
      -- Check if next node is a definition (paragraph starting with ": ").
      if node.type == "paragraph" and tc[i + 1] then
        local next_node = tc[i + 1]
        if next_node.type == "paragraph" then
          local nn_children = next_node.children --[[:! { [integer]: MdNode } | nil]]
          local first = nn_children and nn_children[1]
          if first and first.type == "text" and (first.value or ""):sub(1, 2) == ": " then
            -- Build a <dl> node.
            local _dl = { type = "html", value = "<dl>" }
            local dt_children = (node.children or {}) --[[:! { [integer]: MdNode }]]
            local dt_html = "<dt>"
            for _, c in ipairs(dt_children) do
              if c.type == "text" then dt_html = dt_html .. (c.value or "") end
            end
            dt_html = dt_html .. "</dt>"
            -- Collect all consecutive definition paragraphs.
            local dds = {}
            local j = i + 1
            while j <= #tc do
              local dn = tc[j]
              if dn.type == "paragraph" then
                local dn_children = dn.children --[[:! { [integer]: MdNode } | nil]]
                local df = dn_children and dn_children[1]
                if df and df.type == "text" and (df.value or ""):sub(1, 2) == ": " then
                  local def_text = (df.value or ""):sub(3)
                  dds[#dds + 1] = "<dd>" .. def_text .. "</dd>"
                  j = j + 1
                else
                  break
                end
              else
                break
              end
            end
            local dl_html = "<dl>" .. dt_html .. table.concat(dds) .. "</dl>"
            new_children[#new_children + 1] = { type = "html", value = dl_html }
            i = j
            goto continue
          end
        end
      end
      new_children[#new_children + 1] = node
      i = i + 1
      ::continue::
    end
    tree.children = new_children
    return tree
  end)
end

-- footnote: [^id] footnote references and definitions.
-- Syntax:
--   Text with a footnote[^1].
--   [^1]: The footnote content.
--
-- The mdast parser treats [^id] as a link (with label ^id as url-text) and
-- [^id]: content as a link definition node (label=^id, url=first-word-of-content).
-- This plugin detects those patterns and converts them to footnote markup.
M.plugin.footnote = function(md, _opts)
  md:_add_transform(function(tree)
    -- Collect footnote definitions from mdast `definition` nodes whose label
    -- starts with "^".  The mdast parser stores [^id]: content as:
    --   { type="definition", label="^id", url="first-word", title=... }
    -- which is a limitation of the parser (footnotes aren't in CommonMark).
    -- We reconstruct content from label (strip "^"), url, and title fields.
    local defs = {}      -- normalized_id → content string
    local def_nodes = {} -- set of nodes to remove
    walk(tree, function(node)
      if node.type == "definition" then
        local label = node.label or ""
        if label:sub(1, 1) == "^" then
          local id = label:sub(2)
          -- Reconstruct content: url is the first "word" (space-delimited) of
          -- the original content; title may contain further words if quoted.
          local content = node.url or ""
          if node.title and node.title ~= "" then
            content = content .. " " .. node.title --[[:! string]]
          end
          defs[id] = content
          def_nodes[node] = true
        end
      end
    end)

    -- Remove definition nodes.
    walk(tree, function(node)
      if def_nodes[node] then return false end
    end)

    if not next(defs) then return tree end

    -- Replace footnote link nodes: link nodes where the single child text
    -- starts with "^" are footnote references produced by the mdast parser.
    local ref_order = {}
    local ref_seen  = {}
    walk(tree, function(node)
      if node.type == "link" then
        local first_child = node.children and node.children[1]
        if first_child and first_child.type == "text" then
          local label = first_child.value or ""
          if label:sub(1, 1) == "^" then
            local id = label:sub(2)
            if not ref_seen[id] then
              ref_seen[id] = true
              ref_order[#ref_order + 1] = id
            end
            local n = 0
            for k, rid in ipairs(ref_order) do
              if rid == id then n = k; break end
            end
            -- Replace with html footnote reference.
            node.type  = "html"
            node.value = '<sup><a href="#fn-' .. id ..
              '" id="fnref-' .. id .. '">[' .. n .. ']</a></sup>'
            node.children = nil
            node.url      = nil
            return node
          end
        end
      end
    end)

    -- Append footnotes section.
    if #ref_order > 0 then
      local items = {}
      for k, id in ipairs(ref_order) do
        local content = defs[id] or ""
        items[#items + 1] = '<li id="fn-' .. id .. '">' .. content ..
          ' <a href="#fnref-' .. id .. '">&#8617;</a></li>'
      end
      local section = '<section class="footnotes"><ol>' ..
        table.concat(items) .. '</ol></section>'
      local tc_fn = tree.children --[[:! { [integer]: MdNode }]]
      tc_fn[#tc_fn + 1] = { type = "html", value = section } --[[:! MdNode]]
    end

    return tree
  end)
end

-- ── Return ────────────────────────────────────────────────────────────────────

return M
