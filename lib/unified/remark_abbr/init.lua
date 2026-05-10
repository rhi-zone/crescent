-- lib/unified/remark_abbr/init.lua
-- remark plugin: parse abbreviation definitions and wrap occurrences in text.
-- Port of remark-abbr.
--
-- Syntax:
--   *[HTML]: Hypertext Markup Language
--   *[CSS]: Cascading Style Sheets
--
-- Definitions are extracted from paragraph nodes whose sole text content
-- starts with "*[". Those paragraphs are removed from the tree. All remaining
-- text nodes are scanned for occurrences of defined abbreviations (whole-word
-- match, case-sensitive) and split into text + abbr nodes.
--
-- Output node for an abbreviation:
--   { type = "abbr", title = "expansion", children = { { type = "text", value = "HTML" } } }
--
-- Usage:
--   local remark = require("lib.unified.remark")
--   local abbr   = require("lib.unified.remark_abbr")
--   local proc   = remark():use(abbr)
--   local ast    = proc:run(proc:parse(src))

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- ── Abbreviation definition extraction ───────────────────────────────────────

-- Extract the raw text content of a node (concatenation of all text values).
local function raw_text(node)
  if node.type == "text" then return node.value or ""
  elseif not node.children then return ""
  else
    local parts = {}
    for _, c in ipairs(node.children) do
      parts[#parts + 1] = raw_text(c)
    end
    return table.concat(parts)
  end
end

-- Parse a single "*[ABBR]: Expansion" line.
-- Returns abbr, expansion or nil.
local function parse_abbr_line(line)
  -- Must start with "*["
  local abbr, expansion = line:match("^%*%[([^%]]+)%]:%s*(.+)$")
  return abbr, expansion
end

-- Collect the "lines" of a paragraph node.
-- mdast represents soft-wrapped lines as interleaved text + softBreak nodes.
-- We collect each text node value as a separate line, ignoring softBreak nodes.
local function para_lines(node)
  local lines = {}
  for _, child in ipairs(node.children or {}) do
    if child.type == "text" then
      -- A text node may itself contain embedded newlines in some parsers;
      -- split defensively.
      for part in (child.value .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = part
      end
    end
    -- softBreak nodes are ignored (they act as the line separator already).
  end
  -- Remove trailing empty string from the split above.
  while #lines > 0 and lines[#lines] == "" do
    lines[#lines] = nil
  end
  return lines
end

-- Scan root.children for abbreviation-definition paragraphs.
-- Returns abbrs table and the filtered children list.
local function extract_abbrs(root)
  local abbrs    = {}
  local new_kids = {}

  for _, node in ipairs(root.children or {}) do
    if node.type == "paragraph" then
      local lines = para_lines(node)
      -- A definition paragraph: every line must be a valid "*[abbr]: expansion".
      local all_defns = #lines > 0
      local found = {}
      for _, line in ipairs(lines) do
        local ab, exp = parse_abbr_line(line)
        if ab and exp then
          found[#found + 1] = { abbr = ab, exp = exp }
        else
          all_defns = false
          break
        end
      end
      if all_defns then
        for _, f in ipairs(found) do
          abbrs[f.abbr] = f.exp
        end
        -- Omit this paragraph from output.
      else
        new_kids[#new_kids + 1] = node
      end
    else
      new_kids[#new_kids + 1] = node
    end
  end

  return abbrs, new_kids
end

-- ── Text splitting ────────────────────────────────────────────────────────────

-- Build a sorted list of abbreviation keys (longest first) for greedy matching.
local function sorted_abbr_keys(abbrs)
  local keys = {}
  for k in pairs(abbrs) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b)
    if #a ~= #b then return #a > #b end
    return a < b
  end)
  return keys
end

-- Returns true if the character at byte position pos in s is a word character.
local function is_word_char(s, pos)
  if pos < 1 or pos > #s then return false end
  local b = s:byte(pos)
  return (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or
         (b >= 48 and b <= 57) or b == 95
end

-- Find the earliest occurrence of any abbreviation in `s` starting at `start`.
-- Returns: start_pos, end_pos, abbr_key  OR nil.
-- Uses whole-word matching (not preceded or followed by a word char).
local function find_earliest_abbr(s, start, keys, abbrs)  -- luacheck: ignore abbrs
  local best_pos = #s + 1
  local best_end, best_key

  for _, key in ipairs(keys) do
    local pos = start
    while true do
      local found = s:find(key, pos, true)
      if not found then break end
      local after = found + #key
      -- Whole-word check.
      if not is_word_char(s, found - 1) and not is_word_char(s, after) then
        if found < best_pos then
          best_pos = found
          best_end = after - 1
          best_key = key
        end
        break  -- earliest occurrence of this key found; move to next key
      else
        pos = found + 1
      end
    end
  end

  if best_key then
    return best_pos, best_end, best_key
  end
  return nil
end

-- Split a text node value into a list of mdast/abbr nodes.
--: (string, { [string]: string }, { [integer]: string, ... }) -> { [integer]: unknown }
local function split_text(value, abbrs, keys)
  local nodes = {} --: { [integer]: unknown }
  local pos = 1
  local len = #value

  while pos <= len do
    local s, e, key = find_earliest_abbr(value, pos, keys, abbrs)
    if not s then
      nodes[#nodes + 1] = { type = "text", value = value:sub(pos) }
      break
    end
    local s_any = s --[[: any]]
    local s_ = s_any --[[:! integer]]
    local e_any = e --[[: any]]
    local e_ = e_any --[[:! integer]]
    if s_ > pos then
      nodes[#nodes + 1] = { type = "text", value = value:sub(pos, s_ - 1) }
    end
    nodes[#nodes + 1] = {
      type     = "abbr",
      title    = abbrs[key],
      children = { { type = "text", value = key } },
    }
    pos = e_ + 1
  end

  if #nodes == 0 then
    nodes[1] = { type = "text", value = value }
  end

  return nodes
end

-- ── Tree walker ───────────────────────────────────────────────────────────────

local function walk(node, abbrs, keys)
  local children = node.children
  if not children then return end

  local new_children = {}
  local changed = false

  for i = 1, #children do
    local child = children[i]
    if child.type == "text" and child.value and #child.value > 0 then
      local parts = split_text(child.value, abbrs, keys)
      local p1 = parts[1] --[[:! { type: string, value: string | nil, ... }]]
      if #parts == 1 and p1.type == "text" and p1.value == child.value then
        new_children[#new_children + 1] = child
      else
        changed = true
        for _, p in ipairs(parts) do
          new_children[#new_children + 1] = p
        end
      end
    else
      new_children[#new_children + 1] = child
      walk(child, abbrs, keys)
    end
  end

  if changed then
    node.children = new_children
  end
end

-- ── Plugin ────────────────────────────────────────────────────────────────────

local function remark_abbr(processor, _opts)
  processor:use_transformer(function(tree)
    -- Phase 1: extract definitions and remove definition paragraphs.
    local abbrs, new_children = extract_abbrs(tree)
    tree.children = new_children

    -- Phase 2: walk remaining tree and replace abbreviation occurrences.
    local keys = sorted_abbr_keys(abbrs)
    if #keys > 0 then
      walk(tree, abbrs, keys)
    end

    return tree
  end)
end

M.plugin = remark_abbr

setmetatable(M, { __call = function(_, ...) return remark_abbr(...) end })

return M
