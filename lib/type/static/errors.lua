-- lib/type/static/errors.lua
-- Error collection and formatting for the static typechecker.

local M = {}

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

return M
