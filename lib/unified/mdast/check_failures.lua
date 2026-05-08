-- Diagnostic script: print failing fixtures for emphasis, links, lists
if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local mdast = require("lib.unified.mdast")
local json  = require("lib.format.json")

--: (string) -> string
local function esc_html(s)
  s = (s:gsub("&",  "&amp;"))
  s = (s:gsub("<",  "&lt;"))
  s = (s:gsub(">",  "&gt;"))
  s = (s:gsub('"',  "&quot;"))
  return s
end

--: (string) -> string
local function esc_attr(s)
  s = (s:gsub("&", "&amp;"))
  s = (s:gsub('"', "&quot;"))
  return s
end

--: (string) -> string
local function encode_url(s)
  local result = {}
  local i = 1
  local len = #s
  while i <= len do
    local b = s:byte(i) --[[:! integer]]
    if b == 37 then
      local h1, h2 = s:byte(i+1), s:byte(i+2)
      local hex = "0123456789ABCDEFabcdef"
      local is_hex1 = h1 and hex:find(string.char(h1), 1, true)
      local is_hex2 = h2 and hex:find(string.char(h2), 1, true)
      if is_hex1 and is_hex2 then
        result[#result + 1] = s:sub(i, i+2)
        i = i + 3
      else
        result[#result + 1] = "%25"
        i = i + 1
      end
    elseif b == 32 then result[#result+1] = "%20"; i = i+1
    elseif b == 34 then result[#result+1] = "%22"; i = i+1
    elseif b == 92 then result[#result+1] = "%5C"; i = i+1
    elseif b == 60 then result[#result+1] = "%3C"; i = i+1
    elseif b == 62 then result[#result+1] = "%3E"; i = i+1
    elseif b == 91 then result[#result+1] = "%5B"; i = i+1
    elseif b == 93 then result[#result+1] = "%5D"; i = i+1
    elseif b == 94 then result[#result+1] = "%5E"; i = i+1
    elseif b == 96 then result[#result+1] = "%60"; i = i+1
    elseif b == 123 then result[#result+1] = "%7B"; i = i+1
    elseif b == 124 then result[#result+1] = "%7C"; i = i+1
    elseif b == 125 then result[#result+1] = "%7D"; i = i+1
    elseif b >= 128 then  -- non-ASCII: percent-encode each byte
      result[#result + 1] = string.format("%%%02X", b)
      i = i + 1
    else result[#result+1] = s:sub(i,i); i = i+1
    end
  end
  return table.concat(result)
end

local render_node
local render_inline

render_inline = function(node)
  local t = node.type
  if t == "text" then
    return esc_html(node.value or "")
  elseif t == "inlineCode" then
    return "<code>" .. esc_html(node.value or "") .. "</code>"
  elseif t == "emphasis" then
    local inner = ""
    for _, c in ipairs(node.children or {}) do inner = inner .. render_inline(c) end
    return "<em>" .. inner .. "</em>"
  elseif t == "strong" then
    local inner = ""
    for _, c in ipairs(node.children or {}) do inner = inner .. render_inline(c) end
    return "<strong>" .. inner .. "</strong>"
  elseif t == "link" then
    local href = esc_attr(encode_url(node.url or ""))
    local title_attr = node.title and (' title="' .. esc_attr(node.title --[[:! string]]) .. '"') or ""
    local inner = ""
    for _, c in ipairs(node.children or {}) do inner = inner .. render_inline(c) end
    return '<a href="' .. href .. '"' .. title_attr .. ">" .. inner .. "</a>"
  elseif t == "image" then
    local extract_text
    extract_text = function(nodes)
      local parts = {}
      for _, c in ipairs(nodes or {}) do
        if c.type == "text" or c.type == "inlineCode" then
          parts[#parts + 1] = esc_html(c.value or "")
        elseif c.children then parts[#parts + 1] = extract_text(c.children) end
      end
      return table.concat(parts)
    end
    local alt = extract_text(node.children)
    local src = esc_attr(encode_url(node.url or ""))
    local title_attr = node.title and (' title="' .. esc_attr(node.title --[[:! string]]) .. '"') or ""
    return '<img src="' .. src .. '" alt="' .. alt .. '"' .. title_attr .. " />"
  elseif t == "break" then return "<br />\n"
  elseif t == "softBreak" then return "\n"
  elseif t == "html" then
    local v = node.value or ""
    -- Detect autolinks: <scheme:content> where content has no spaces or '<'.
    -- CommonMark §6.9: autolink = <absolute-URI> or <email-address>.
    local url = v:match("^<([a-zA-Z][a-zA-Z0-9+%-.]+:[^%s<>]*)>$")
    if url then
      local href = esc_attr(encode_url(url))
      return '<a href="' .. href .. '">' .. esc_html(url) .. '</a>'
    end
    return v
  else return "" end
end

local function render_inlines(children)
  if not children then return "" end
  local parts = {}
  for _, c in ipairs(children) do parts[#parts + 1] = render_inline(c) end
  return table.concat(parts)
end

local function is_loose_list(node)
  if node._loose then return true end
  for _, item in ipairs(node.children or {}) do
    if item._loose then return true end
  end
  return false
end

render_node = function(node)
  local t = node.type
  if t == "root" then
    local parts = {}
    for _, c in ipairs(node.children or {}) do parts[#parts + 1] = render_node(c) end
    return table.concat(parts)
  elseif t == "heading" then
    local tag = "h" .. tostring(node.depth)
    return "<" .. tag .. ">" .. render_inlines(node.children) .. "</" .. tag .. ">\n"
  elseif t == "paragraph" then
    return "<p>" .. render_inlines(node.children) .. "</p>\n"
  elseif t == "code" then
    local lang_attr = ""
    if node.lang and node.lang ~= "" then
      lang_attr = ' class="language-' .. esc_attr(node.lang --[[:! string]]) .. '"'
    end
    local value = esc_html(node.value or "")
    if value ~= "" then value = value .. "\n" end
    return "<pre><code" .. lang_attr .. ">" .. value .. "</code></pre>\n"
  elseif t == "thematicBreak" then return "<hr />\n"
  elseif t == "blockquote" then
    local inner = ""
    for _, c in ipairs(node.children or {}) do inner = inner .. render_node(c) end
    return "<blockquote>\n" .. inner .. "</blockquote>\n"
  elseif t == "list" then
    local tag = node.ordered and "ol" or "ul"
    local start_attr = ""
    if node.ordered and node.start and node.start ~= 1 then
      start_attr = ' start="' .. tostring(node.start) .. '"'
    end
    local loose = is_loose_list(node)
    local parts = {}
    for _, item in ipairs(node.children or {}) do
      local ch = item.children or {}
      if loose then
        if #ch == 0 then parts[#parts + 1] = "<li></li>\n"
        else
          local inner = ""
          for _, c in ipairs(ch) do inner = inner .. render_node(c) end
          parts[#parts + 1] = "<li>\n" .. inner .. "</li>\n"
        end
      else
        if #ch == 1 and ch[1].type == "paragraph" then
          local content = render_inlines(ch[1].children)
          parts[#parts + 1] = "<li>" .. content .. "</li>\n"
        elseif #ch == 0 then parts[#parts + 1] = "<li></li>\n"
        elseif ch[1].type == "paragraph" then
          local inner = render_inlines(ch[1].children) .. "\n"
          for ci = 2, #ch do inner = inner .. render_node(ch[ci]) end
          parts[#parts + 1] = "<li>" .. inner .. "</li>\n"
        else
          local inner = ""
          for ci, c in ipairs(ch --[[:! { [integer]: { type: string, children: unknown } }]]) do
            if c.type == "paragraph" then
              local nl = (ci < #(ch --[[:! { [integer]: unknown }]])) and "\n" or ""
              inner = inner .. render_inlines(c.children) .. nl
            else inner = inner .. render_node(c) end
          end
          parts[#parts + 1] = "<li>\n" .. inner .. "</li>\n"
        end
      end
    end
    return "<" .. tag .. start_attr .. ">\n" .. table.concat(parts) .. "</" .. tag .. ">\n"
  elseif t == "html" then
    local v = node.value or ""
    if v ~= "" and v:sub(-1) ~= "\n" then v = v .. "\n" end
    return v
  elseif t == "definition" then return ""
  else return "" end
end

local f0 = io.open("/tmp/commonmark_spec.json", "r")
if not f0 then error("could not open commonmark spec") end
local f = f0 --[[:! { close: (any) -> (boolean | nil, string | nil), flush: (any) -> (boolean | nil, string | nil), lines: (any) -> () -> string | nil, read: (any, ...string | number) -> string | nil, seek: (any, string | nil, integer | nil) -> (integer | nil, string | nil), setvbuf: (any, string, integer | nil) -> (boolean | nil, string | nil), write: (any, ...string | number) -> (any, string | nil) }]]
local src = f:read("*a") --[[:! string]]
f:close()
local data_raw = json.decode(src)
local data = data_raw --[[:! { [integer]: { section: string, markdown: string, html: string, example: integer } }]]

local target_sections = {
  ["Emphasis and strong emphasis"] = true,
  ["Links"] = true,
  ["Lists"] = true,
}

for _, e in ipairs(data) do
  if target_sections[e.section] then
    local parsed_tree = mdast.parse(e.markdown)
    local tree = parsed_tree --[[:! { type: string }]]
    local got = render_node(tree)
    local html = e.html
    local markdown = e.markdown
    if got ~= html then
      print(string.format("=== FAIL ex%d [%s] ===", e.example, e.section))
      local md_str = (markdown:gsub("\n", "\\n"))
      local want_str = (html:gsub("\n", "\\n"))
      local got_str = ((got --[[:! string]]):gsub("\n", "\\n"))
      print("MARKDOWN: " .. md_str)
      print("WANT:     " .. want_str)
      print("GOT:      " .. got_str)
      print()
    end
  end
end
