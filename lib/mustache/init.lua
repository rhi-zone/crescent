if not package.path:find("./?/init.lua", 1, true) then package.path = "./?/init.lua;" .. package.path end

--:: mustache_ctx = { [string]: unknown }
--:: mustache_partials = { [string]: string }
--:: mustache_token = { type: string, value?: string, key?: string, escape?: boolean, inverted?: boolean, tokens?: mustache_template, raw_text?: string, indent?: string, ... }
--:: mustache_template = { [integer]: mustache_token, ... }
--:: mustache_compiled = { _tokens: mustache_template, render: (mustache_compiled, mustache_ctx, (mustache_partials | nil)) -> ((string | nil), (string | nil)) }
local M = {} --: { render?: (string, mustache_ctx, (mustache_partials | nil)) -> ((string | nil), (string | nil)), compile?: (string) -> ((mustache_compiled | nil), (string | nil)), [string]: unknown }

--: <V>(t: { [integer]: V, ... }, pos: integer | nil) -> V | nil
local pop = table.remove

-- HTML escape map
local escape_map = {
  ["&"] = "&amp;",
  ["<"] = "&lt;",
  [">"] = "&gt;",
  ['"'] = "&quot;",
  ["'"] = "&#39;",
}

--: (string) -> string
local function html_escape(s)
  local r = s:gsub('[&<>"\']', escape_map)
  return r
end

--: (mustache_ctx, string) -> unknown
local function lookup_dotted(ctx, key)
  if key == "." then return ctx end
  local val = ctx
  for part in key:gmatch("[^.]+") do
    if type(val) ~= "table" then return nil end
    val = (val --[[:! { [string]: unknown }]])[part] --[[:! mustache_ctx]]
    if val == nil then return nil end
  end
  return val
end

--: (Arr<mustache_ctx>, string) -> unknown
local function resolve(stack, key)
  if key == "." then
    return stack[#stack]
  end
  -- For dotted keys, split into first segment and rest
  local first, rest = key:match("^([^.]+)%.(.+)$")
  if not first then
    -- Simple key: walk up the stack
    for i = #stack, 1, -1 do
      local ctx = stack[i]
      if type(ctx) == "table" then
        local v = ctx[key]
        if v ~= nil then return v end
      end
    end
    return nil
  end
  -- Dotted key: find first segment by walking up, then resolve rest within that context
  for i = #stack, 1, -1 do
    local ctx = stack[i]
    if type(ctx) == "table" then
      local v = ctx[first]
      if v ~= nil then
        return lookup_dotted(v --[[:! mustache_ctx]], rest)
      end
    end
  end
  return nil
end

--: (unknown) -> boolean
local function is_list(t)
  if type(t) ~= "table" then return false end
  local n = #t
  return n > 0
end

-- In Mustache: nil, false, and empty lists are falsy. Everything else is truthy.
-- Empty string is truthy. Non-list tables are truthy. Non-empty lists are truthy.
--: (unknown) -> boolean
local function is_falsy(val)
  if val == nil or val == false then return true end
  if type(val) == "table" and #val == 0 then return true end
  return false
end

-- Check whether the tag spanning [tag_start, tag_end_exclusive) is standalone on its line.
-- A tag is standalone if the only non-whitespace on its line is the tag itself.
-- This means: the immediately preceding text token (if any) must end with only whitespace
-- after its last newline (or be entirely whitespace if no newline), AND there must be no
-- non-text tokens between that text and the current tag on the same line.
-- Returns: is_standalone, pre_text_idx (index of preceding text token to trim, or 0 for start),
-- and the newline string to skip after the tag (or "" at end of template).
--: (string, integer, integer, mustache_template, integer) -> (boolean, integer | nil, string | nil)
local function check_standalone(template, tag_start, tag_end, tokens, len)
  -- Check preceding: either start of template or only whitespace since last newline
  local pre_text_idx = nil --: integer | nil
  local n = #tokens
  if n > 0 then
    -- The last token must be text (if there are non-text tokens after the last newline,
    -- this tag is not standalone)
    if tokens[n].type ~= "text" then
      return false
    end
    local txt = tokens[n].value or ""
    local nl_pos = txt:find("\n[^\n]*$")
    if nl_pos then
      local after_nl = txt:sub(nl_pos + 1)
      if after_nl:match("^%s*$") then
        pre_text_idx = n
      end
    elseif txt:match("^%s*$") then
      -- All whitespace, but we need to check there are no non-text tokens before this
      -- on the same line (i.e., since the last newline in any earlier text token)
      local only_ws = true
      for j = n - 1, 1, -1 do
        if tokens[j].type == "text" then
          local jv = tokens[j].value or ""
          if jv:find("\n") then
            break -- found a newline boundary, we're good
          elseif not jv:match("^%s*$") then
            only_ws = false
            break
          end
        else
          -- Non-text token on same line: not standalone
          only_ws = false
          break
        end
      end
      if only_ws then
        pre_text_idx = n
      end
    end
  elseif n == 0 then
    pre_text_idx = 0
  end

  if pre_text_idx == nil then return false end

  -- Check following: newline or end of template
  local post_nl = nil
  if tag_end > len then
    post_nl = ""
  else
    local nl = template:match("^\r?\n", tag_end)
    if nl then post_nl = nl end
  end

  if post_nl == nil then return false end

  return true, pre_text_idx, post_nl
end

-- Trim the preceding whitespace text for a standalone tag, and advance past the trailing newline.
--: (mustache_template, integer) -> mustache_template
local function trim_standalone_pre(tokens, pre_text_idx)
  if pre_text_idx > 0 then
    local txt = tokens[pre_text_idx].value or ""
    local nl_pos = txt:find("\n[^\n]*$")
    if nl_pos then
      tokens[pre_text_idx].value = txt:sub(1, nl_pos)
    elseif txt:match("^%s*$") then
      local new = {} --: mustache_template
      for j, t in ipairs(tokens) do
        if j ~= pre_text_idx then new[#new + 1] = t end
      end
      tokens = new
    end
  end
  return tokens
end

-- Forward declaration
local render_tokens

--: (string, string, string) -> (mustache_template | nil, string | nil)
local function compile_tokens(template, otag, ctag)
  local tokens = {} --: mustache_template
  local i = 1
  local len = #template
  local section_stack = {} --: Arr<{ otag: string, ctag: string, key: string, inverted: boolean, start_pos: integer, raw_start: integer, tokens: mustache_template }>

  while i <= len do
    -- Find next open tag
    local tag_start = template:find(otag, i, true)
    if not tag_start then
      -- Rest is plain text
      local text = template:sub(i)
      if #text > 0 then
        tokens[#tokens + 1] = { type = "text", value = text }
      end
      break
    end

    -- Text before tag
    if tag_start > i then
      local text = template:sub(i, tag_start - 1)
      tokens[#tokens + 1] = { type = "text", value = text }
    end

    local after_otag = tag_start + #otag

    -- Check for triple mustache {{{...}}}
    if otag == "{{" and template:sub(after_otag, after_otag) == "{" then
      local close = template:find("}}}", after_otag + 1, true)
      if not close then
        return nil, "unclosed triple mustache at position " .. tag_start
      end
      local key = template:sub(after_otag + 1, close - 1):match("^%s*(.-)%s*$")
      tokens[#tokens + 1] = { type = "var", key = key, escape = false }
      i = close + 3
    else
      local tag_end = template:find(ctag, after_otag, true)
      if not tag_end then
        return nil, "unclosed tag at position " .. tag_start
      end
      local content = template:sub(after_otag, tag_end - 1)
      i = tag_end + #ctag

      local sigil = content:sub(1, 1)

      if sigil == "!" then
        -- Comment: standalone handling
        local is_standalone, pre_idx, post_nl = check_standalone(template, tag_start, i, tokens, len)
        if is_standalone then
          tokens = trim_standalone_pre(tokens, pre_idx or 0)
          if post_nl and #post_nl > 0 then
            i = i + #post_nl
          end
        end
        tokens[#tokens + 1] = { type = "comment" }

      elseif sigil == "#" or sigil == "^" then
        local key = content:sub(2):match("^%s*(.-)%s*$")
        local is_standalone, pre_idx, post_nl = check_standalone(template, tag_start, i, tokens, len)
        if is_standalone then
          tokens = trim_standalone_pre(tokens, pre_idx or 0)
          if post_nl and #post_nl > 0 then
            i = i + #post_nl
          end
        end

        section_stack[#section_stack + 1] = {
          key = key,
          inverted = (sigil == "^"),
          tokens = tokens,
          otag = otag,
          ctag = ctag,
          start_pos = tag_start,
          raw_start = i,
        }
        tokens = {}

      elseif sigil == "/" then
        local key = content:sub(2):match("^%s*(.-)%s*$")
        if #section_stack == 0 then
          return nil, "unexpected closing tag {{/" .. key .. "}}"
        end
        local section = section_stack[#section_stack]
        table.remove(section_stack)
        if section.key ~= key then
          return nil, "mismatched section close: expected {{/" .. section.key .. "}} but got {{/" .. key .. "}}"
        end

        -- Standalone handling for closing tag
        local inner_tokens = tokens
        local is_standalone, pre_idx, post_nl = check_standalone(template, tag_start, i, inner_tokens, len)
        if is_standalone then
          inner_tokens = trim_standalone_pre(inner_tokens, pre_idx or 0)
          if post_nl and #post_nl > 0 then
            i = i + #post_nl
          end
        end

        -- Extract raw section text for lambdas
        local raw_text = template:sub(section.raw_start, tag_start - 1)

        local section_token = {
          type = "section",
          key = section.key,
          inverted = section.inverted,
          tokens = inner_tokens,
          raw_text = raw_text,
        }
        tokens = section.tokens
        tokens[#tokens + 1] = section_token

        -- Restore delimiters
        otag = section.otag
        ctag = section.ctag

      elseif sigil == ">" then
        local key = content:sub(2):match("^%s*(.-)%s*$")
        -- Determine indentation for partial
        local indent = ""
        if #tokens > 0 and tokens[#tokens].type == "text" then
          local txt = tokens[#tokens].value or ""
          local last_nl = txt:find("\n[^\n]*$")
          local line_start = nil --: string | nil
          if last_nl then
            line_start = txt:sub(last_nl + 1)
          elseif not txt:find("\n") then
            line_start = txt
          end
          if line_start ~= nil then
            local ls = line_start --[[:! string]]
            if ls:match("^%s+$") then
              indent = ls
            end
          end
        elseif #tokens == 0 then
          local pre = template:sub(1, tag_start - 1)
          if pre:match("^%s*$") and #pre > 0 then
            indent = pre
          end
        end

        -- Standalone check for partials
        local is_standalone, pre_idx, post_nl = check_standalone(template, tag_start, i, tokens, len)
        if is_standalone then
          tokens = trim_standalone_pre(tokens, pre_idx or 0)
          if post_nl and #post_nl > 0 then
            i = i + #post_nl
          end
        end

        tokens[#tokens + 1] = { type = "partial", key = key, indent = indent }

      elseif sigil == "&" then
        local key = content:sub(2):match("^%s*(.-)%s*$")
        tokens[#tokens + 1] = { type = "var", key = key, escape = false }

      elseif sigil == "=" then
        -- Set delimiter: {{=<% %>=}}
        local inner = content:sub(2) -- remove leading =
        if inner:sub(-1) == "=" then
          inner = inner:sub(1, -2)
        end
        local new_otag, new_ctag = (inner --[[:! string]]):match("^%s*(%S+)%s+(%S+)%s*$")
        if not new_otag then
          return nil, "invalid set delimiter tag"
        end

        local is_standalone, pre_idx, post_nl = check_standalone(template, tag_start, i, tokens, len)
        if is_standalone then
          tokens = trim_standalone_pre(tokens, pre_idx or 0)
          if post_nl and #post_nl > 0 then
            i = i + #post_nl
          end
        end

        otag = new_otag
        ctag = new_ctag

      else
        -- Variable (escaped)
        local key = content:match("^%s*(.-)%s*$")
        tokens[#tokens + 1] = { type = "var", key = key, escape = true }
      end
    end
  end

  if #section_stack > 0 then
    return nil, "unclosed section: {{#" .. section_stack[#section_stack].key .. "}}"
  end

  return tokens, nil
end

--: (mustache_template, Arr<mustache_ctx>, (mustache_partials | nil), string, string) -> string
render_tokens = function(tokens, stack, partials, otag, ctag)
  local buf = {} --: { [integer]: string }
  for _, tok in ipairs(tokens) do
    if tok.type == "text" then
      buf[#buf + 1] = tok.value or ""

    elseif tok.type == "var" then
      local val = resolve(stack, tok.key or "")
      if val ~= nil and val ~= false then
        local s = tostring(val)
        if tok.escape then
          s = html_escape(s)
        end
        buf[#buf + 1] = s
      end

    elseif tok.type == "section" then
      local val = resolve(stack, tok.key or "")
      if tok.inverted then
        if is_falsy(val) then
          buf[#buf + 1] = render_tokens(tok.tokens or {}, stack, partials, otag, ctag)
        end
      else
        if type(val) == "function" then
          -- Lambda: call with raw text, render result
          local raw = val(tok.raw_text)
          if raw then
            local lambda_tokens = compile_tokens(tostring(raw), otag, ctag)
            if lambda_tokens then
              buf[#buf + 1] = render_tokens(lambda_tokens, stack, partials, otag, ctag)
            end
          end
        elseif is_list(--[[:! mustache_ctx]] val) then
          local val_arr = val --[[:! Arr<mustache_ctx>]]
          for _, item in ipairs(val_arr) do
            stack[#stack + 1] = item --[[:! mustache_ctx]]
            buf[#buf + 1] = render_tokens(tok.tokens or {}, stack, partials, otag, ctag)
            pop(stack)
          end
        elseif val and val ~= false then
          if type(val) == "table" then
            stack[#stack + 1] = val --[[:! mustache_ctx]]
          else
            stack[#stack + 1] = --[[:! mustache_ctx]] val
          end
          buf[#buf + 1] = render_tokens(tok.tokens or {}, stack, partials, otag, ctag)
          pop(stack)
        end
        -- falsy: skip
      end

    elseif tok.type == "partial" then
      if partials then
        local partial_template = partials[tok.key or ""]
        if partial_template then
          -- Apply indentation to partial
          local indented = partial_template
          local tok_indent = tok.indent or ""
          if #tok_indent > 0 then
            -- Indent every line of the partial (including the first)
            local replaced = partial_template:gsub("\n", "\n" .. tok_indent)
            indented = tok_indent .. replaced
            -- Remove trailing indent if partial ends with newline
            if partial_template:sub(-1) == "\n" then
              indented = indented:sub(1, -(#tok_indent + 1))
            end
          end
          local partial_tokens = compile_tokens(indented, "{{", "}}")
          if partial_tokens then
            buf[#buf + 1] = render_tokens(partial_tokens, stack, partials, otag, ctag)
          end
        end
      end

    -- type == "comment": skip
    end
  end
  return table.concat(buf)
end

--: (string) -> ((mustache_compiled | nil), (string | nil))
local function compile(template)
  local tokens, err = compile_tokens(template, "{{", "}}")
  if not tokens then return nil, err end
  local compiled = {
    _tokens = tokens,
  }
  --: ({ _tokens: mustache_template, ... }, mustache_ctx, (mustache_partials | nil)) -> ((string | nil), (string | nil))
  function compiled:render(data, partials)
    local stack = { data } --: Arr<mustache_ctx>
    local ok2, result = pcall(render_tokens, self._tokens, stack, partials, "{{", "}}")
    if not ok2 then return nil, result end
    return result, nil
  end
  return compiled, nil
end
M.compile = compile

--: (string, mustache_ctx, (mustache_partials | nil)) -> ((string | nil), (string | nil))
function M.render(template, data, partials)
  local compiled, err = compile(template)
  if not compiled then return nil, err end
  return compiled:render(data, partials)
end

return M
