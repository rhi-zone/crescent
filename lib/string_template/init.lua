-- lib/string_template/init.lua
-- Simple string interpolation and template formatting.
-- No control flow — substitution only.
--
-- Public API:
--   interpolate(template, vars, opts?)  → string | (nil, errmsg)
--   compile(template, opts?)            → function | (nil, errmsg)
--   format(template, vars, opts?)       → string | (nil, errmsg)  (alias for interpolate)
--   printf(fmt, ...)                    → string  (string.format wrapper)
--   dedent(s)                           → string  (strips common leading whitespace)
--   M._tier = "pure"

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ── Syntax patterns ──────────────────────────────────────────────────────────
-- Each syntax maps to the literal prefix and suffix strings used for matching.
-- The capture pattern is built in parse_template below.

--:: Syntax = { open: string, close: string }
local SYNTAX = { --: { [string]: Syntax }
  dollar  = { open = "${",  close = "}" },  -- default
  curly   = { open = "{",   close = "}" },
  percent = { open = "%{",  close = "}" },
  double  = { open = "{{",  close = "}}" },
}

-- ── Path resolution ───────────────────────────────────────────────────────────
-- Resolves "a.b.c" against a table, returning the value or nil.

local function resolve_path(vars, path)
  local cur = vars
  for seg in path:gmatch("[^.]+") do
    if type(cur) ~= "table" then return nil end
    cur = cur[seg] or cur[tonumber(seg)]
  end
  return cur
end

-- ── Format application ────────────────────────────────────────────────────────
-- Applies a format specifier to a value.
-- Returns the formatted string, or (nil, errmsg) on failure.

--: (unknown, string) -> string | (nil, string)
local function apply_format(val, fmt)
  if fmt == "upper" then
    return string.upper(tostring(val))
  elseif fmt == "lower" then
    return string.lower(tostring(val))
  elseif fmt == "int" then
    return string.format("%d", val)
  elseif fmt == "float" then
    return string.format("%g", val)
  elseif fmt == "hex" then
    return string.format("%x", val)
  elseif fmt == "HEX" then
    return string.format("%X", val)
  elseif fmt == "repr" then
    return string.format("%q", tostring(val))
  else
    -- printf-style specifier: must start with %
    local spec = fmt:sub(1, 1) == "%" and fmt or ("%" .. fmt)
    local sval = tostring(val)
    local ok, result = pcall(function() return string.format(spec, sval) end)
    if not ok then
      return nil, "format error: " .. tostring(result)
    end
    return result --[[:! string]]
  end
end

-- ── Template parser ───────────────────────────────────────────────────────────
-- Parses a template string into a list of segments:
--   { type = "literal", value = "..." }
--   { type = "var", path = "a.b", default = nil|"str", fmt = nil|"str" }
--
-- Returns segments list, or (nil, errmsg) on parse error.

--:: Segment = { type: string, value?: string, path?: string, default?: string, fmt?: string }

--: (string, string | nil) -> Arr<Segment> | (nil, string)
local function parse_template(template, syntax_name)
  local syn = SYNTAX[syntax_name or "dollar"]
  if not syn then
    return nil, "unknown syntax: " .. tostring(syntax_name)
  end
  local open  = syn.open
  local close = syn.close
  local olen  = #open
  local clen  = #close

  local segments = {}
  local pos = 1
  local len = #template

  while pos <= len do
    -- Look for escaped open: backslash immediately before open
    -- e.g. \${ for dollar syntax
    local esc_start = template:find("\\" .. open, pos, true)
    local tok_start = template:find(open, pos, true)

    -- If escaped comes before (or at) token start, emit literal up to escape,
    -- then emit the open literally (skipping the backslash), then advance.
    if esc_start and (not tok_start or esc_start < tok_start) then
      -- literal before the backslash
      if esc_start > pos then
        segments[#segments + 1] = { type = "literal", value = template:sub(pos, esc_start - 1) }
      end
      -- emit the open delimiter literally (skipping the backslash)
      segments[#segments + 1] = { type = "literal", value = open }
      pos = esc_start + 1 + olen  -- skip \ + open
    elseif tok_start then
      -- emit literal before token
      if tok_start > pos then
        segments[#segments + 1] = { type = "literal", value = template:sub(pos, tok_start - 1) }
      end
      -- find closing delimiter
      local tok_end = template:find(close, tok_start + olen, true)
      if not tok_end then
        return nil, "unclosed template expression at position " .. tok_start
      end
      local inner = template:sub(tok_start + olen, tok_end - 1)
      -- parse inner: path[:fmt] or path[|default]
      -- precedence: | before : (default has no colons, fmt has no pipes)
      local default_val, fmt_spec
      local pipe = inner:find("|", 1, true)
      local colon = inner:find(":", 1, true)
      local path_raw
      if pipe and (not colon or pipe < colon) then
        path_raw    = inner:sub(1, pipe - 1)
        default_val = inner:sub(pipe + 1)
        -- still allow :fmt after default? Not specified; skip.
      elseif colon then
        path_raw = inner:sub(1, colon - 1)
        fmt_spec = inner:sub(colon + 1)
      else
        path_raw = inner
      end
      -- trim path whitespace (path_raw is always set by if/elseif/else above)
      local path = (path_raw --[[:! string]]):match("^%s*(.-)%s*$") or (path_raw --[[:! string]])
      segments[#segments + 1] = {
        type    = "var",
        path    = path,
        default = default_val,
        fmt     = fmt_spec,
      }
      pos = tok_end + clen
    else
      -- no more tokens: emit rest as literal
      segments[#segments + 1] = { type = "literal", value = template:sub(pos) }
      pos = len + 1
    end
  end

  return segments
end

-- ── Segment evaluator ─────────────────────────────────────────────────────────
-- Given parsed segments and a vars table, build the output string.
-- opts.on_missing: "empty" (default) | "keep" | "error"
-- Returns string, or (nil, errmsg).

--: (Arr<Segment>, unknown, { on_missing?: string, syntax?: string } | nil, string, string | nil) -> string | (nil, string)
local function eval_segments(segments, vars, opts, raw_template, syntax_name)
  local on_missing = (opts and opts.on_missing) or "empty"
  local syn = SYNTAX[syntax_name or "dollar"]
  local parts = {} --: Arr<string>
  for i = 1, #segments do
    local seg = segments[i]
    if seg.type == "literal" then
      parts[#parts + 1] = seg.value or ""
    else
      -- resolve value (var segment always has path set)
      local vpath = seg.path or ""
      local val = resolve_path(vars, vpath)
      if val == nil then
        val = seg.default
      end
      if val == nil then
        if on_missing == "error" then
          return nil, "missing var: " .. vpath
        elseif on_missing == "keep" then
          parts[#parts + 1] = syn.open .. vpath .. syn.close
        else
          -- "empty": emit nothing
        end
      else
        -- apply format if any
        if seg.fmt then
          local formatted, err = apply_format(val, seg.fmt)
          if formatted == nil then
            return nil, err or "format error"
          end
          parts[#parts + 1] = formatted --[[:! string]]
        else
          parts[#parts + 1] = tostring(val)
        end
      end
    end
  end
  return table.concat(parts)
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Interpolate a template string against a vars table.
-- @param template  string
-- @param vars      table  (string keys for named vars; integer keys for positional)
-- @param opts      table? { syntax="dollar"|"curly"|"percent"|"double", on_missing="empty"|"keep"|"error" }
-- @return string | (nil, errmsg)
function M.interpolate(template, vars, opts)
  local syntax = opts and opts.syntax or "dollar"
  local segments, err = parse_template(template, syntax)
  if segments == nil then return nil, err end
  return eval_segments(segments --[[:! Arr<Segment>]], vars, opts, template, syntax)
end

--- Alias for interpolate (positional args feel more natural as "format").
M.format = M.interpolate

--- Compile a template into a reusable function.
-- @param template  string
-- @param opts      table? { syntax=... }
-- @return function(vars, call_opts?) → string | (nil, errmsg)
--       | (nil, errmsg)  on parse failure
function M.compile(template, opts)
  local syntax = opts and opts.syntax or "dollar"
  local segments, err = parse_template(template, syntax)
  if segments == nil then return nil, err end
  local segs = segments --[[:! Arr<Segment>]]
  return function(vars, call_opts)
    local merged_opts = call_opts or opts
    return eval_segments(segs, vars, merged_opts, template, syntax)
  end
end

--- string.format wrapper — returns the formatted string.
-- @param fmt   string  printf format
-- @param ...   args
-- @return string
function M.printf(fmt, ...)
  return string.format(fmt, ...)
end

--- Strip common leading whitespace from a multi-line string.
-- Also strips a leading newline if the string starts with one (heredoc style).
-- @param s  string
-- @return string
function M.dedent(s)
  -- strip leading newline (heredoc style)
  s = s:gsub("^\n", "")
  -- strip trailing newline (heredoc style)
  s = s:gsub("\n$", "")
  -- find minimum indentation (ignore blank lines)
  local min_indent = math.huge
  for line in s:gmatch("[^\n]+") do
    local indent = line:match("^(%s*)")
    if #indent < min_indent then
      min_indent = #indent
    end
  end
  if min_indent == math.huge or min_indent == 0 then
    return s
  end
  local pattern = "^" .. string.rep(" ", min_indent --[[:! integer]])
  local result = {}
  for line in (s .. "\n"):gmatch("([^\n]*)\n") do
    result[#result + 1] = line:gsub(pattern, "", 1)
  end
  -- remove trailing empty line added by sentinel newline above
  if result[#result] == "" then
    result[#result] = nil
  end
  return table.concat(result, "\n")
end

return M
