if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- XML 1.0 SAX and DOM parser.
-- Pure Lua implementation — no external dependencies.
-- Supports: elements, attributes, text, CDATA, comments,
-- processing instructions, entity references.

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Entity tables
-- ---------------------------------------------------------------------------

local ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }
local ESCAPE_MAP = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;",
                     ['"'] = "&quot;", ["'"] = "&apos;" }

--- Decode XML entities in a string.
--: (string) -> string
function M.unescape(s)
  return (s
    :gsub("&(%a[%w_]*);", function(e) return ENTITIES[e] or ("&" .. e .. ";") end)
    :gsub("&#(%d+);",     function(n)
      local cp = tonumber(n)
      if cp and cp <= 0x10FFFF then return string.char(cp) end
      return "&#" .. n .. ";"
    end)
    :gsub("&#x(%x+);", function(h)
      local cp = tonumber(h, 16)
      if cp and cp <= 0x10FFFF then return string.char(cp) end
      return "&#x" .. h .. ";"
    end))
end

--- Encode special XML characters in a string.
--: (string) -> string
function M.escape(s)
  return (s:gsub('[&<>"\']', ESCAPE_MAP))
end

-- ---------------------------------------------------------------------------
-- Namespace helper
-- ---------------------------------------------------------------------------

--- Split a prefixed name into (prefix, localname).
--- Returns ("", name) when no prefix is present.
--: (string) -> string, string
function M.ns_split(name)
  local prefix, local_name = name:match("^([^:]+):(.+)$")
  if prefix then return prefix, local_name end
  return "", name
end

-- ---------------------------------------------------------------------------
-- Internal: attribute parser
-- ---------------------------------------------------------------------------

-- Parse attributes starting at pos (inside a tag, after the tag name).
-- Returns: attrs table, self_closing bool, new pos  OR  nil, errmsg
local function parse_attrs(xml, pos)
  local attrs = {}
  local len = #xml
  while pos <= len do
    -- skip whitespace
    pos = xml:match("^%s*()", pos) or pos
    local c = xml:sub(pos, pos)
    if c == ">" then
      return attrs, false, pos + 1
    elseif xml:sub(pos, pos + 1) == "/>" then
      return attrs, true, pos + 2
    elseif c == "" then
      return nil, "unexpected end of input in tag"
    end
    -- attribute name
    local aname, after_name = xml:match("^([%w_:%.%-]+)()", pos)
    if not aname then
      return nil, "expected attribute name at position " .. pos
    end
    pos = after_name
    -- optional whitespace + '='
    pos = xml:match("^%s*()", pos) or pos
    if xml:sub(pos, pos) ~= "=" then
      return nil, "expected '=' after attribute name '" .. aname .. "'"
    end
    pos = pos + 1
    pos = xml:match("^%s*()", pos) or pos
    -- quoted value
    local q = xml:sub(pos, pos)
    if q ~= '"' and q ~= "'" then
      return nil, "expected quote in attribute value for '" .. aname .. "'"
    end
    local pattern = "^" .. q .. "([^" .. q .. "]*)" .. q .. "()"
    local aval, after_val = xml:match(pattern, pos)
    if not aval then
      return nil, "unterminated attribute value for '" .. aname .. "'"
    end
    attrs[aname] = M.unescape(aval)
    pos = after_val
  end
  return nil, "unexpected end of input while parsing attributes"
end

-- ---------------------------------------------------------------------------
-- SAX parser
-- ---------------------------------------------------------------------------

--- Event-driven SAX parser.
--- handlers table may contain any of:
---   start_document()
---   end_document()
---   start_element(name, attrs)
---   end_element(name)
---   text(content)
---   comment(text)
---   cdata(content)
---   processing_instruction(target, data)
---
--- Returns true on success, or (nil, errmsg).
--: (string, table) -> true | nil, string
function M.sax(xml, handlers)
  handlers = handlers or {}
  local function fire(name, ...)
    local fn = handlers[name]
    if fn then fn(...) end
  end

  local pos = 1
  local len = #xml
  local stack = {}  -- open tag names for error reporting

  fire("start_document")

  -- Skip optional BOM
  if xml:sub(1, 3) == "\xEF\xBB\xBF" then pos = 4 end

  while pos <= len do
    -- Find next '<' or end of text
    local lt = xml:find("<", pos, true)
    -- Emit text before '<' (or trailing text)
    local text_end = lt and lt - 1 or len
    if text_end >= pos then
      local raw = xml:sub(pos, text_end)
      -- Only fire text if non-empty after unescaping
      if raw ~= "" then
        fire("text", M.unescape(raw))
      end
    end
    if not lt then break end
    pos = lt + 1  -- pos is now character after '<'

    local c = xml:sub(pos, pos)

    -- XML declaration / processing instruction  <?...?>
    if xml:sub(pos, pos + 1) == "??" or xml:sub(pos, pos) == "?" then
      -- <?...?>
      local target, after_target = xml:match("^%?([%w_:%-%.]+)%s*()", pos)
      if not target then
        return nil, "malformed processing instruction at position " .. pos
      end
      local data_end = xml:find("?>", after_target, true)
      if not data_end then
        return nil, "unterminated processing instruction"
      end
      local data = xml:sub(after_target, data_end - 1)
      -- strip trailing whitespace from data
      data = data:match("^(.-)%s*$")
      if target:lower() ~= "xml" then
        fire("processing_instruction", target, data)
      end
      pos = data_end + 2

    -- Comment  <!--...-->
    elseif xml:sub(pos, pos + 2) == "!--" then
      local comment_end = xml:find("-->", pos + 3, true)
      if not comment_end then
        return nil, "unterminated comment"
      end
      local content = xml:sub(pos + 3, comment_end - 1)
      fire("comment", content)
      pos = comment_end + 3

    -- CDATA  <![CDATA[...]]>
    elseif xml:sub(pos, pos + 7) == "![CDATA[" then
      local cdata_end = xml:find("]]>", pos + 8, true)
      if not cdata_end then
        return nil, "unterminated CDATA section"
      end
      local content = xml:sub(pos + 8, cdata_end - 1)
      fire("cdata", content)
      pos = cdata_end + 3

    -- DOCTYPE — skip entirely
    elseif xml:sub(pos, pos + 7) == "!DOCTYPE" then
      -- skip to '>'
      local gt = xml:find(">", pos + 8, true)
      if not gt then return nil, "unterminated DOCTYPE" end
      pos = gt + 1

    -- End tag  </name>
    elseif c == "/" then
      local name, after_name = xml:match("^/([%w_:%-%.]+)%s*()", pos)
      if not name then
        return nil, "malformed end tag at position " .. pos
      end
      if xml:sub(after_name, after_name) ~= ">" then
        return nil, "expected '>' in end tag '</" .. name .. "'"
      end
      -- validate matching
      local expected = stack[#stack]
      if expected and expected ~= name then
        return nil, "mismatched tags: expected '</" .. expected .. ">' but got '</" .. name .. ">'"
      end
      stack[#stack] = nil
      fire("end_element", name)
      pos = after_name + 1

    -- Start tag  <name attrs> or <name attrs/>
    elseif c:match("[%w_:]") then
      local name, after_name = xml:match("^([%w_:%-%.]+)()", pos)
      if not name then
        return nil, "expected tag name at position " .. pos
      end
      local attrs, self_closing, new_pos = parse_attrs(xml, after_name)
      if not attrs then
        return nil, self_closing  -- self_closing is errmsg here
      end
      fire("start_element", name, attrs)
      if self_closing then
        fire("end_element", name)
      else
        stack[#stack + 1] = name
      end
      pos = new_pos

    else
      -- bare '<' followed by something unexpected — treat as text
      fire("text", "<")
    end
  end

  if #stack > 0 then
    return nil, "unclosed tag: <" .. stack[#stack] .. ">"
  end

  fire("end_document")
  return true
end

-- ---------------------------------------------------------------------------
-- DOM parser
-- ---------------------------------------------------------------------------

--- Parse XML into a DOM tree.
--- Returns root document node, or (nil, errmsg).
--: (string) -> table | nil, string
function M.parse(xml)
  local doc = {
    type = "document",
    children = {},
    parent = nil,
  }
  local current = doc
  local stack = { doc }

  local handlers = {
    start_element = function(name, attrs)
      local node = {
        type = "element",
        tag = name,
        attrs = attrs,
        children = {},
        parent = current,
      }
      current.children[#current.children + 1] = node
      current = node
      stack[#stack + 1] = node
    end,
    end_element = function(_name)
      stack[#stack] = nil
      current = stack[#stack]
    end,
    text = function(content)
      -- merge adjacent text nodes
      local last = current.children[#current.children]
      if last and last.type == "text" then
        last.text = last.text .. content
      else
        current.children[#current.children + 1] = {
          type = "text",
          text = content,
          parent = current,
        }
      end
    end,
    comment = function(content)
      current.children[#current.children + 1] = {
        type = "comment",
        text = content,
        parent = current,
      }
    end,
    cdata = function(content)
      current.children[#current.children + 1] = {
        type = "cdata",
        text = content,
        parent = current,
      }
    end,
    processing_instruction = function(target, data)
      current.children[#current.children + 1] = {
        type = "processing_instruction",
        target = target,
        text = data,
        parent = current,
      }
    end,
  }

  local ok, err = M.sax(xml, handlers)
  if not ok then return nil, err end
  return doc
end

-- ---------------------------------------------------------------------------
-- DOM navigation
-- ---------------------------------------------------------------------------

--- Find the first child element with the given tag name.
--: (table, string) -> table | nil
function M.find(node, tag)
  local children = node.children
  if not children then return nil end
  for i = 1, #children do
    local c = children[i]
    if c.type == "element" and c.tag == tag then return c end
  end
  return nil
end

--- Find all direct child elements with the given tag name.
--: (table, string) -> table
function M.find_all(node, tag)
  local result = {}
  local children = node.children
  if not children then return result end
  for i = 1, #children do
    local c = children[i]
    if c.type == "element" and c.tag == tag then
      result[#result + 1] = c
    end
  end
  return result
end

--- Concatenate all text content (text and CDATA nodes) in the subtree.
--: (table) -> string
function M.text_content(node)
  if node.type == "text" or node.type == "cdata" then
    return node.text or ""
  end
  local parts = {}
  local function walk(n)
    if n.type == "text" or n.type == "cdata" then
      parts[#parts + 1] = n.text or ""
    elseif n.children then
      for i = 1, #n.children do walk(n.children[i]) end
    end
  end
  walk(node)
  return table.concat(parts)
end

--- Get an attribute value from an element node.
--: (table, string) -> string | nil
function M.attr(node, name)
  if node.attrs then return node.attrs[name] end
  return nil
end

--- Simple XPath-style navigation.
--- Supports:
---   "a/b/c"  — descend through direct children
---   "//tag"  — find all descendants with tag
---   "a//b"   — descend to 'a' then find all descendants 'b'
--: (table, string) -> table
function M.xpath_simple(node, path)
  -- Split path on '/'
  -- Handle leading '//' as "all descendants"
  local function descendants(n, tag)
    local result = {}
    local function walk(nd)
      if nd.children then
        for i = 1, #nd.children do
          local c = nd.children[i]
          if c.type == "element" then
            if tag == "*" or c.tag == tag then result[#result + 1] = c end
            walk(c)
          end
        end
      end
    end
    walk(n)
    return result
  end

  -- Parse path segments handling '//'
  -- We iterate segment by segment
  local current_nodes = { node }

  -- Split into segments while preserving '//' markers
  local segments = {}
  local i = 1
  while i <= #path do
    if path:sub(i, i + 1) == "//" then
      segments[#segments + 1] = { deep = true }
      i = i + 2
      -- capture the tag name following '//'
      local tag = path:match("^([^/]+)", i)
      if tag then
        segments[#segments].tag = tag
        i = i + #tag
      end
    elseif path:sub(i, i) == "/" then
      i = i + 1
    else
      local tag = path:match("^([^/]+)", i)
      if tag then
        segments[#segments + 1] = { deep = false, tag = tag }
        i = i + #tag
      else
        break
      end
    end
  end

  for _, seg in ipairs(segments) do
    local next_nodes = {}
    if seg.deep then
      for _, nd in ipairs(current_nodes) do
        local found = descendants(nd, seg.tag or "*")
        for _, f in ipairs(found) do next_nodes[#next_nodes + 1] = f end
      end
    else
      for _, nd in ipairs(current_nodes) do
        local found = M.find_all(nd, seg.tag)
        for _, f in ipairs(found) do next_nodes[#next_nodes + 1] = f end
      end
    end
    current_nodes = next_nodes
  end

  -- if the path started with '//' (first segment was deep), we already handled it above
  -- Remove the starting node if it slipped through
  return current_nodes
end

-- ---------------------------------------------------------------------------
-- Serializer
-- ---------------------------------------------------------------------------

--- Serialize a DOM node to an XML string.
--- opts: { indent=N, declare=true }
--: (table, table | nil) -> string
function M.serialize(node, opts)
  opts = opts or {}
  local indent_size = opts.indent
  local parts = {}

  if opts.declare then
    parts[#parts + 1] = '<?xml version="1.0" encoding="UTF-8"?>\n'
  end

  local function write(n, depth)
    local pad = indent_size and string.rep(" ", depth * indent_size) or ""
    local nl  = indent_size and "\n" or ""

    if n.type == "document" then
      for i = 1, #n.children do write(n.children[i], depth) end

    elseif n.type == "element" then
      parts[#parts + 1] = pad .. "<" .. n.tag
      if n.attrs then
        -- stable attribute order: sort keys
        local keys = {}
        for k in pairs(n.attrs) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do
          parts[#parts + 1] = ' ' .. k .. '="' .. M.escape(n.attrs[k]) .. '"'
        end
      end
      local children = n.children or {}
      if #children == 0 then
        parts[#parts + 1] = "/>" .. nl
      else
        parts[#parts + 1] = ">"
        -- check if all children are text/cdata (inline)
        local all_inline = true
        for i = 1, #children do
          if children[i].type ~= "text" and children[i].type ~= "cdata" then
            all_inline = false; break
          end
        end
        if all_inline and indent_size then
          -- keep on one line
          for i = 1, #children do write(children[i], 0) end
          parts[#parts + 1] = "</" .. n.tag .. ">" .. nl
        else
          parts[#parts + 1] = nl
          for i = 1, #children do write(children[i], depth + 1) end
          parts[#parts + 1] = pad .. "</" .. n.tag .. ">" .. nl
        end
      end

    elseif n.type == "text" then
      if indent_size then
        -- if we're inside an element at depth>0 check if we should pad
        parts[#parts + 1] = M.escape(n.text or "")
      else
        parts[#parts + 1] = M.escape(n.text or "")
      end

    elseif n.type == "cdata" then
      parts[#parts + 1] = "<![CDATA[" .. (n.text or "") .. "]]>"
      if indent_size then parts[#parts + 1] = nl end

    elseif n.type == "comment" then
      parts[#parts + 1] = pad .. "<!--" .. (n.text or "") .. "-->" .. nl

    elseif n.type == "processing_instruction" then
      local data = n.text or ""
      if data ~= "" then
        parts[#parts + 1] = pad .. "<?" .. (n.target or "?") .. " " .. data .. "?>" .. nl
      else
        parts[#parts + 1] = pad .. "<?" .. (n.target or "?") .. "?>" .. nl
      end
    end
  end

  write(node, 0)
  return table.concat(parts)
end

-- ---------------------------------------------------------------------------
-- Builder API
-- ---------------------------------------------------------------------------

--- Create an element node.
--: (string, table | nil, table | nil) -> table
function M.element(tag, attrs, children)
  local node = {
    type = "element",
    tag = tag,
    attrs = attrs or {},
    children = {},
    parent = nil,
  }
  if children then
    for i = 1, #children do
      local c = children[i]
      c.parent = node
      node.children[i] = c
    end
  end
  return node
end

--- Create a text node.
--: (string) -> table
function M.text_node(s)
  return { type = "text", text = s, parent = nil }
end

--- Create a comment node.
--: (string) -> table
function M.comment_node(s)
  return { type = "comment", text = s, parent = nil }
end

return M
