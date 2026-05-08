if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local mdast = require("lib.unified.mdast")
local json  = require("lib.format.json")

--: (string) -> string
local function esc_html(s)
  s = (s:gsub("&","&amp;")); s = (s:gsub("<","&lt;")); s = (s:gsub(">","&gt;")); s = (s:gsub('"',"&quot;"))
  return s
end
--: (string) -> string
local function esc_attr(s) s = (s:gsub("&","&amp;")); s = (s:gsub('"',"&quot;")); return s end
--: (string) -> string
local function encode_url(s)
  local result = {}; local i = 1; local len = #s
  while i <= len do
    local b = s:byte(i)
    if b == 37 then
      local h1, h2 = s:byte(i+1), s:byte(i+2)
      local hex = "0123456789ABCDEFabcdef"
      if h1 and h2 and hex:find(string.char(h1),1,true) and hex:find(string.char(h2),1,true) then
        result[#result+1] = s:sub(i,i+2); i = i+3
      else result[#result+1] = "%25"; i = i+1 end
    elseif b==32 then result[#result+1]="%20";i=i+1
    elseif b==34 then result[#result+1]="%22";i=i+1
    elseif b==92 then result[#result+1]="%5C";i=i+1
    elseif b==60 then result[#result+1]="%3C";i=i+1
    elseif b==62 then result[#result+1]="%3E";i=i+1
    elseif b==91 then result[#result+1]="%5B";i=i+1
    elseif b==93 then result[#result+1]="%5D";i=i+1
    elseif b==94 then result[#result+1]="%5E";i=i+1
    elseif b==96 then result[#result+1]="%60";i=i+1
    elseif b==123 then result[#result+1]="%7B";i=i+1
    elseif b==124 then result[#result+1]="%7C";i=i+1
    elseif b==125 then result[#result+1]="%7D";i=i+1
    else result[#result+1]=s:sub(i,i);i=i+1 end
  end
  return table.concat(result)
end

local render_node, render_inline
render_inline = function(node)
  local t = node.type
  if t == "text" then return esc_html(node.value or "")
  elseif t == "inlineCode" then return "<code>" .. esc_html(node.value or "") .. "</code>"
  elseif t == "emphasis" then
    local i = ""; for _, c in ipairs(node.children or {}) do i = i .. render_inline(c) end
    return "<em>" .. i .. "</em>"
  elseif t == "strong" then
    local i = ""; for _, c in ipairs(node.children or {}) do i = i .. render_inline(c) end
    return "<strong>" .. i .. "</strong>"
  elseif t == "link" then
    local href = esc_attr(encode_url(node.url or ""))
    local title_attr = node.title and (' title="' .. esc_attr(node.title --[[:! string]]) .. '"') or ""
    local inner = ""; for _, c in ipairs(node.children or {}) do inner = inner .. render_inline(c) end
    return '<a href="' .. href .. '"' .. title_attr .. ">" .. inner .. "</a>"
  elseif t == "image" then
    local extract_text
    extract_text = function(nodes)
      local p = {}
      for _, c in ipairs(nodes or {}) do
        if c.type == "text" or c.type == "inlineCode" then p[#p+1] = esc_html(c.value or "")
        elseif c.children then p[#p+1] = extract_text(c.children) end
      end
      return table.concat(p)
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
  local p = {}; for _, c in ipairs(children) do p[#p+1] = render_inline(c) end
  return table.concat(p)
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
    local p = {}; for _, c in ipairs(node.children or {}) do p[#p+1] = render_node(c) end
    return table.concat(p)
  elseif t == "heading" then
    local tag = "h" .. tostring(node.depth)
    return "<"..tag..">"..render_inlines(node.children).."</"..tag..">\n"
  elseif t == "paragraph" then return "<p>"..render_inlines(node.children).."</p>\n"
  elseif t == "code" then
    local lang_attr = ""
    if node.lang and node.lang ~= "" then lang_attr = ' class="language-'..esc_attr(node.lang --[[:! string]])..'"' end
    local value = esc_html(node.value or "")
    -- CommonMark: each source line ends with \n, so the final value always ends with \n.
    -- Always append \n so trailing blank lines are preserved correctly.
    if value ~= "" then value = value .. "\n" end
    return "<pre><code"..lang_attr..">"..value.."</code></pre>\n"
  elseif t == "thematicBreak" then return "<hr />\n"
  elseif t == "blockquote" then
    local inner = ""; for _, c in ipairs(node.children or {}) do inner = inner .. render_node(c) end
    return "<blockquote>\n"..inner.."</blockquote>\n"
  elseif t == "list" then
    local tag = node.ordered and "ol" or "ul"
    local start_attr = ""
    if node.ordered and node.start and node.start ~= 1 then start_attr = ' start="'..tostring(node.start)..'"' end
    local loose = is_loose_list(node)
    local parts = {}
    for _, item in ipairs(node.children or {}) do
      local ch = item.children or {}
      if loose then
        if #ch == 0 then parts[#parts+1] = "<li></li>\n"
        else
          local inner = ""; for _, c in ipairs(ch) do inner = inner .. render_node(c) end
          parts[#parts+1] = "<li>\n"..inner.."</li>\n"
        end
      else
        if #ch == 1 and ch[1].type == "paragraph" then
          parts[#parts+1] = "<li>"..render_inlines(ch[1].children).."</li>\n"
        elseif #ch == 0 then parts[#parts+1] = "<li></li>\n"
        elseif ch[1].type == "paragraph" then
          local inner = render_inlines(ch[1].children).."\n"
          for ci = 2, #ch do inner = inner .. render_node(ch[ci]) end
          parts[#parts+1] = "<li>"..inner.."</li>\n"
        else
          local inner = ""
          for ci, c in ipairs(ch --[[:! { [integer]: { type: string, children: unknown } }]]) do
            if c.type == "paragraph" then
              local nl = (ci < #(ch --[[:! { [integer]: unknown }]])) and "\n" or ""
              inner = inner .. render_inlines(c.children) .. nl
            else inner = inner .. render_node(c) end
          end
          parts[#parts+1] = "<li>\n"..inner.."</li>\n"
        end
      end
    end
    return "<"..tag..start_attr..">\n"..table.concat(parts).."</"..tag..">\n"
  elseif t == "html" then
    local v = node.value or ""
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
local f = f2 --[[:! { close: (any) -> (boolean | nil, string | nil), flush: (any) -> (boolean | nil, string | nil), lines: (any) -> () -> string | nil, read: (any, ...string | number) -> string | nil, seek: (any, string | nil, integer | nil) -> (integer | nil, string | nil), setvbuf: (any, string, integer | nil) -> (boolean | nil, string | nil), write: (any, ...string | number) -> (any, string | nil) }]]
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

local show_fails = arg and arg[1]

for _, sec in ipairs(section_order) do
  if skip[sec] then goto cont end
  local pass, fail = 0, 0
  local fails = {}
  for _, e in ipairs(sections[sec]) do
    local parsed_tree = mdast.parse(e.markdown)
    local got = render_node(parsed_tree --[[:! { type: string }]])
    if got == e.html then pass = pass + 1
    else
      fail = fail + 1
      fails[#fails+1] = e
    end
  end
  local total = pass + fail
  print(string.format("%-45s %3d/%3d  (%.0f%%)", sec, pass, total, pass/total*100))
  if show_fails and fail > 0 then
    for _, e in ipairs(fails) do
      local parsed_tree2 = mdast.parse(e.markdown)
      print(string.format("  ex%d: want=%s got=%s", e.example,
        e.html:gsub("\n","\\n"), render_node(parsed_tree2 --[[:! { type: string }]]):gsub("\n","\\n")))
    end
  end
  ::cont::
end
