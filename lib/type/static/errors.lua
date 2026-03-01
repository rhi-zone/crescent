-- lib/type/static/errors.lua
-- Error collection and formatting for the static typechecker.

local M = {}

-- ANSI color support. Disabled when NO_COLOR is set or TERM=dumb.
-- Returns a table of escape strings (empty strings when color is off).
function M.get_colors()
  if os.getenv("NO_COLOR") or os.getenv("TERM") == "dumb" then
    return { err = "", path = "", dim = "", reset = "" }
  end
  return {
    err   = "\27[31m",   -- red   — mismatch annotation
    path  = "\27[33m",   -- yellow — .field.path line
    dim   = "\27[2m",    -- dim    — secondary context
    reset = "\27[0m",
  }
end

function M.new()
  return { errors = {} }
end

function M.add(ctx, severity, file, line, message)
  ctx.errors[#ctx.errors + 1] = {
    severity = severity,
    file = file,
    line = line,
    message = message,
  }
end

function M.error(ctx, file, line, message)
  M.add(ctx, "error", file, line, message)
end

function M.warning(ctx, file, line, message)
  M.add(ctx, "warning", file, line, message)
end

function M.has_errors(ctx)
  for i = 1, #ctx.errors do
    if ctx.errors[i].severity == "error" then
      return true
    end
  end
  return false
end

function M.count(ctx, severity)
  local n = 0
  for i = 1, #ctx.errors do
    if not severity or ctx.errors[i].severity == severity then
      n = n + 1
    end
  end
  return n
end

function M.sort(ctx)
  table.sort(ctx.errors, function(a, b)
    if a.file ~= b.file then return (a.file or "") < (b.file or "") end
    local al, bl = a.line or 0, b.line or 0
    if al ~= bl then return al < bl end
    return (a.severity or "") < (b.severity or "")
  end)
end

function M.format(ctx, source_lines)
  M.sort(ctx)
  local out = {}
  for i = 1, #ctx.errors do
    local e = ctx.errors[i]
    local prefix = e.file .. ":" .. (e.line or 0) .. ": " .. e.severity .. ": "
    out[#out + 1] = prefix .. e.message
    -- Show source line if available
    if source_lines and e.line and source_lines[e.line] then
      local src_line = source_lines[e.line]
      local line_str = string.format("  %d | %s", e.line, src_line)
      out[#out + 1] = line_str
    end
  end
  return table.concat(out, "\n")
end

-- Escape a string for JSON output (no dependency on a JSON library)
local function json_escape(s)
  s = s:gsub('\\', '\\\\')
  s = s:gsub('"', '\\"')
  s = s:gsub('\n', '\\n')
  s = s:gsub('\r', '\\r')
  s = s:gsub('\t', '\\t')
  return s
end

function M.format_json(ctx)
  M.sort(ctx)
  local parts = {}
  for i = 1, #ctx.errors do
    local e = ctx.errors[i]
    parts[#parts + 1] = '{"file":"' .. json_escape(e.file or "") ..
      '","line":' .. (e.line or 0) ..
      ',"severity":"' .. json_escape(e.severity or "error") ..
      '","message":"' .. json_escape(e.message or "") .. '"}'
  end
  return "[" .. table.concat(parts, ",") .. "]"
end

function M.format_sarif(ctx)
  M.sort(ctx)
  local results = {}
  for i = 1, #ctx.errors do
    local e = ctx.errors[i]
    local level = e.severity == "warning" and "warning" or "error"
    results[#results + 1] = '{"ruleId":"' .. json_escape(e.severity or "error") ..
      '","level":"' .. level ..
      '","message":{"text":"' .. json_escape(e.message or "") ..
      '"},"locations":[{"physicalLocation":{"artifactLocation":{"uri":"' ..
      json_escape(e.file or "") ..
      '"},"region":{"startLine":' .. (e.line or 0) .. '}}}]}'
  end
  return '{"$schema":"https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json",' ..
    '"version":"2.1.0",' ..
    '"runs":[{"tool":{"driver":{"name":"crescent-typecheck","version":"0.1.0"}},' ..
    '"results":[' .. table.concat(results, ",") .. ']}]}'
end

return M
