-- lib/type/static/v2/errors.lua
-- Error collection and formatting for the v2 typechecker.

local M = {}

-- Create a new error context.
function M.new_ctx()
    return { errors = {}, warnings = {} }
end

-- Add an error.
function M.error(err_ctx, filename, line, col, msg)
    err_ctx.errors[#err_ctx.errors + 1] = {
        kind     = "error",
        filename = filename,
        line     = line,
        col      = col,
        msg      = msg,
    }
end

-- Add a warning.
function M.warning(err_ctx, filename, line, col, msg)
    err_ctx.warnings[#err_ctx.warnings + 1] = {
        kind     = "warning",
        filename = filename,
        line     = line,
        col      = col,
        msg      = msg,
    }
end

-- Check if there are any errors.
function M.has_errors(err_ctx)
    return #err_ctx.errors > 0
end

-- Format errors as plain text.
function M.format_plain(err_ctx)
    local lines = {}
    for _, e in ipairs(err_ctx.errors) do
        lines[#lines + 1] = string.format("%s:%d:%d: error: %s",
            e.filename, e.line, e.col, e.msg)
    end
    for _, w in ipairs(err_ctx.warnings) do
        lines[#lines + 1] = string.format("%s:%d:%d: warning: %s",
            w.filename, w.line, w.col, w.msg)
    end
    return table.concat(lines, "\n")
end

-- ANSI color codes
local ANSI = {
    reset = "\27[0m",
    red   = "\27[31m",
    yellow = "\27[33m",
    bold  = "\27[1m",
}

-- Format errors with ANSI colors.
function M.format_ansi(err_ctx)
    local lines = {}
    for _, e in ipairs(err_ctx.errors) do
        lines[#lines + 1] = string.format("%s%s:%d:%d:%s %serror:%s %s",
            ANSI.bold, e.filename, e.line, e.col, ANSI.reset,
            ANSI.red, ANSI.reset, e.msg)
    end
    for _, w in ipairs(err_ctx.warnings) do
        lines[#lines + 1] = string.format("%s%s:%d:%d:%s %swarning:%s %s",
            ANSI.bold, w.filename, w.line, w.col, ANSI.reset,
            ANSI.yellow, ANSI.reset, w.msg)
    end
    return table.concat(lines, "\n")
end

-- Format errors as JSON array.
function M.format_json(err_ctx)
    local items = {}
    for _, e in ipairs(err_ctx.errors) do
        items[#items + 1] = string.format(
            '{"kind":"error","file":%s,"line":%d,"col":%d,"message":%s}',
            M._json_str(e.filename), e.line, e.col, M._json_str(e.msg))
    end
    for _, w in ipairs(err_ctx.warnings) do
        items[#items + 1] = string.format(
            '{"kind":"warning","file":%s,"line":%d,"col":%d,"message":%s}',
            M._json_str(w.filename), w.line, w.col, M._json_str(w.msg))
    end
    return "[" .. table.concat(items, ",") .. "]"
end

-- Minimal JSON string escaping.
function M._json_str(s)
    s = tostring(s or "")
    s = s:gsub('\\', '\\\\')
    s = s:gsub('"', '\\"')
    s = s:gsub('\n', '\\n')
    s = s:gsub('\r', '\\r')
    s = s:gsub('\t', '\\t')
    return '"' .. s .. '"'
end

-- Format errors as SARIF 2.1.0 JSON.
function M.format_sarif(err_ctx)
    local results = {}
    for _, e in ipairs(err_ctx.errors) do
        results[#results + 1] = string.format(
            '{"ruleId":"checker","level":"error","message":{"text":%s},"locations":[{"physicalLocation":{"artifactLocation":{"uri":%s},"region":{"startLine":%d,"startColumn":%d}}}]}',
            M._json_str(e.msg), M._json_str(e.filename), e.line, e.col + 1)
    end
    for _, w in ipairs(err_ctx.warnings) do
        results[#results + 1] = string.format(
            '{"ruleId":"checker","level":"warning","message":{"text":%s},"locations":[{"physicalLocation":{"artifactLocation":{"uri":%s},"region":{"startLine":%d,"startColumn":%d}}}]}',
            M._json_str(w.msg), M._json_str(w.filename), w.line, w.col + 1)
    end
    return string.format(
        '{"version":"2.1.0","$schema":"https://json.schemastore.org/sarif-2.1.0.json","runs":[{"tool":{"driver":{"name":"crescent","version":"0.2.0"}},"results":[%s]}]}',
        table.concat(results, ","))
end

return M
