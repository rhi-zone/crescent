if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local mdast = require("lib.unified.mdast")
local json  = require("lib.format.json")

--: (string) -> string
local function esc_html(s)
  s = (s:gsub("&",  "&amp;")); s = (s:gsub("<",  "&lt;")); s = (s:gsub(">",  "&gt;")); s = (s:gsub('"',  "&quot;"))
  return s
end
--: (string) -> string
local function esc_attr(s)
  s = (s:gsub("&", "&amp;")); s = (s:gsub('"', "&quot;")); return s
end
--: (string) -> string
local function encode_url(s)
  s = (s:gsub(" ", "%%20")); return s
end

local render_node, render_inline
render_inline = function(node)
  local t = node.type
  if t == "text" then return esc_html(node.value or "")
  elseif t == "inlineCode" then return "<code>" .. esc_html(node.value or "") .. "</code>"
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
        if c.type == "text" or c.type == "inlineCode" then parts[#parts+1] = esc_html(c.value or "")
        elseif c.children then parts[#parts+1] = extract_text(c.children) end
      end
      return table.concat(parts)
    end
    local alt = extract_text(node.children)
    local src = esc_attr(encode_url(node.url or ""))
    local title_attr = node.title and (' title="' .. esc_attr(node.title --[[:! string]]) .. '"') or ""
    return '<img src="' .. src .. '" alt="' .. alt .. '"' .. title_attr .. " />"
  elseif t == "break" then return "<br />\n"
  elseif t == "softBreak" then return "\n"
  elseif t == "html" then return node.value or ""
  else return "" end
end

local function render_inlines(children)
  if not children then return "" end
  local parts = {}
  for _, c in ipairs(children) do parts[#parts+1] = render_inline(c) end
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
    for _, c in ipairs(node.children or {}) do parts[#parts+1] = render_node(c) end
    return table.concat(parts)
  elseif t == "heading" then
    local tag = "h" .. tostring(node.depth)
    return "<" .. tag .. ">" .. render_inlines(node.children) .. "</" .. tag .. ">\n"
  elseif t == "paragraph" then
    return "<p>" .. render_inlines(node.children) .. "</p>\n"
  elseif t == "code" then
    local lang_attr = ""
    if node.lang and node.lang ~= "" then lang_attr = ' class="language-' .. esc_attr(node.lang --[[:! string]]) .. '"' end
    local value = esc_html(node.value or "")
    if value ~= "" and value:sub(-1) ~= "\n" then value = value .. "\n" end
    return "<pre><code" .. lang_attr .. ">" .. value .. "</code></pre>\n"
  elseif t == "thematicBreak" then return "<hr />\n"
  elseif t == "blockquote" then
    local inner = ""
    for _, c in ipairs(node.children or {}) do inner = inner .. render_node(c) end
    return "<blockquote>\n" .. inner .. "</blockquote>\n"
  elseif t == "list" then
    local tag = node.ordered and "ol" or "ul"
    local start_attr = ""
    if node.ordered and node.start and node.start ~= 1 then start_attr = ' start="' .. tostring(node.start) .. '"' end
    local loose = is_loose_list(node)
    local parts = {}
    for _, item in ipairs(node.children or {}) do
      local ch = item.children or {}
      if loose then
        if #ch == 0 then parts[#parts+1] = "<li></li>\n"
        else
          local inner = ""
          for _, c in ipairs(ch) do inner = inner .. render_node(c) end
          parts[#parts+1] = "<li>\n" .. inner .. "</li>\n"
        end
      else
        if #ch == 1 and ch[1].type == "paragraph" then
          parts[#parts+1] = "<li>" .. render_inlines(ch[1].children) .. "</li>\n"
        elseif #ch == 0 then parts[#parts+1] = "<li></li>\n"
        elseif ch[1].type == "paragraph" then
          local inner = render_inlines(ch[1].children) .. "\n"
          for ci = 2, #ch do inner = inner .. render_node(ch[ci]) end
          parts[#parts+1] = "<li>" .. inner .. "</li>\n"
        else
          local inner = ""
          for ci, c in ipairs(ch) do
            if c.type == "paragraph" then inner = inner .. render_inlines(c.children) .. "\n"
            else inner = inner .. render_node(c) end
          end
          parts[#parts+1] = "<li>\n" .. inner .. "</li>\n"
        end
      end
    end
    return "<" .. tag .. start_attr .. ">\n" .. table.concat(parts) .. "</" .. tag .. ">\n"
  elseif t == "html" then
    local v = node.value or "" --: string
    if v ~= "" and v:sub(-1) ~= "\n" then v = v .. "\n" end
    return v
  elseif t == "definition" then return ""
  else return "" end
end

local f1 = io.open("/tmp/commonmark_spec.json", "r")
if not f1 then
  os.execute("curl -sf https://spec.commonmark.org/0.31.2/spec.json -o /tmp/commonmark_spec.json")
end
local f2 = f1 or io.open("/tmp/commonmark_spec.json", "r")
if not f2 then error("could not open commonmark spec") end
local f = f2 --[[:! { close: (unknown) -> (boolean | nil, string | nil), flush: (unknown) -> (boolean | nil, string | nil), lines: (unknown) -> () -> string | nil, read: (unknown, ...string | number) -> string | nil, seek: (unknown, string | nil, integer | nil) -> (integer | nil, string | nil), setvbuf: (unknown, string, integer | nil) -> (boolean | nil, string | nil), write: (unknown, ...string | number) -> (unknown, string | nil) }]]
local src = f:read("*a") --[[:! string]]
f:close()
local data_raw = json.decode(src)
local data = data_raw --[[:! { [integer]: { section: string, markdown: string, html: string, example: integer } }]]

--: { [string]: { [integer]: { section: string, markdown: string, html: string, example: integer } } }
local sections = {}
local section_order = {}
for _, e in ipairs(data) do
  if not sections[e.section] then sections[e.section] = {}; section_order[#section_order+1] = e.section end
  sections[e.section][#sections[e.section]+1] = e
end

local skip = { ["HTML blocks"]=true, ["Raw HTML"]=true, ["Autolinks"]=true,
  ["Entity and numeric character references"]=true, ["Backslash escapes"]=true,
  ["Link reference definitions"]=true, ["Inlines"]=true }

for _, sec in ipairs(section_order) do
  if skip[sec] then goto cont end
  local pass, fail = 0, 0
  for _, e in ipairs(sections[sec]) do
    local parsed_tree = mdast.parse(e.markdown)
    local got = render_node(parsed_tree --[[:! { type: string }]])
    if got == e.html then pass = pass + 1 else fail = fail + 1 end
  end
  local total = pass + fail
  print(string.format("%-45s %3d/%3d  (%.0f%%)", sec, pass, total, pass/total*100))
  ::cont::
end
