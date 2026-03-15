-- lib/type/static/errors.lua
-- Error collection and formatting for the typechecker.

local M = {}

-- Create a new error context.
-- source_lines: filename -> array of source lines (populated by set_source).
function M.new_ctx()
    return { errors = {}, warnings = {}, source_lines = {} }
end

-- Store source text for a file so formatters can display context lines.
-- Call this once after creating an err_ctx, before reporting errors.
function M.set_source(err_ctx, filename, source)
    if not source or source == "" then return end
    local lines = {}
    local i = 1
    local len = #source
    while i <= len do
        local nl = source:find("\n", i, true)
        if nl then
            lines[#lines + 1] = source:sub(i, nl - 1)
            i = nl + 1
        else
            lines[#lines + 1] = source:sub(i)
            break
        end
    end
    err_ctx.source_lines[filename] = lines
end

-- Add an error. Returns the error entry so callers can attach notes.
function M.error(err_ctx, filename, line, col, msg)
    local e = {
        kind     = "error",
        filename = filename,
        line     = line,
        col      = col,
        msg      = msg,
        notes    = {},
    }
    err_ctx.errors[#err_ctx.errors + 1] = e
    return e
end

-- Attach a secondary note to an error entry returned by M.error.
-- note: { filename, line, col, msg }
function M.add_note(entry, filename, line, col, msg)
    if not entry then return end
    entry.notes[#entry.notes + 1] = {
        filename = filename,
        line     = line,
        col      = col,
        msg      = msg,
    }
end

-- Add a warning. Returns the warning entry.
function M.warning(err_ctx, filename, line, col, msg)
    local w = {
        kind     = "warning",
        filename = filename,
        line     = line,
        col      = col,
        msg      = msg,
        notes    = {},
    }
    err_ctx.warnings[#err_ctx.warnings + 1] = w
    return w
end

-- Check if there are any errors.
function M.has_errors(err_ctx)
    return #err_ctx.errors > 0
end

-- Append source context (line + caret) to an output lines table.
-- col is 0-indexed. line_num is 1-indexed.
local function append_context(out, source_lines, filename, line_num, col)
    if not source_lines then return end
    local file_lines = source_lines[filename]
    if not file_lines or not file_lines[line_num] then return end
    local src = file_lines[line_num]
    local prefix = string.format("  %d | ", line_num)
    out[#out + 1] = prefix .. src
    if col and col >= 0 then
        out[#out + 1] = string.rep(" ", #prefix + col) .. "^"
    end
end

-- Append notes to an output lines table (plain text).
local function append_notes_plain(out, notes, source_lines)
    if not notes then return end
    for _, note in ipairs(notes) do
        out[#out + 1] = string.format("  note: %s", note.msg)
        append_context(out, source_lines, note.filename, note.line, note.col)
    end
end

-- Format errors as plain text.
function M.format_plain(err_ctx)
    local lines = {}
    for _, e in ipairs(err_ctx.errors) do
        lines[#lines + 1] = string.format("%s:%d:%d: error: %s",
            e.filename, e.line, e.col, e.msg)
        append_context(lines, err_ctx.source_lines, e.filename, e.line, e.col)
        append_notes_plain(lines, e.notes, err_ctx.source_lines)
    end
    for _, w in ipairs(err_ctx.warnings) do
        lines[#lines + 1] = string.format("%s:%d:%d: warning: %s",
            w.filename, w.line, w.col, w.msg)
        append_context(lines, err_ctx.source_lines, w.filename, w.line, w.col)
    end
    return table.concat(lines, "\n")
end

-- ANSI color codes
local ANSI = {
    reset  = "\27[0m",
    red    = "\27[31m",
    yellow = "\27[33m",
    bold   = "\27[1m",
    dim    = "\27[2m",
}

-- Append ANSI-colored source context to an output lines table.
local function append_context_ansi(out, source_lines, filename, line_num, col, caret_color)
    if not source_lines then return end
    local file_lines = source_lines[filename]
    if not file_lines or not file_lines[line_num] then return end
    local src = file_lines[line_num]
    local prefix = string.format("  %d | ", line_num)
    out[#out + 1] = ANSI.dim .. prefix .. src .. ANSI.reset
    if col and col >= 0 then
        out[#out + 1] = string.rep(" ", #prefix + col) ..
            (caret_color or ANSI.red) .. "^" .. ANSI.reset
    end
end

-- Append notes to an output lines table (ANSI).
local function append_notes_ansi(out, notes, source_lines)
    if not notes then return end
    for _, note in ipairs(notes) do
        out[#out + 1] = string.format("  %snote:%s %s", ANSI.bold, ANSI.reset, note.msg)
        append_context_ansi(out, source_lines, note.filename, note.line, note.col, ANSI.dim)
    end
end

-- Format errors with ANSI colors.
function M.format_ansi(err_ctx)
    local lines = {}
    for _, e in ipairs(err_ctx.errors) do
        lines[#lines + 1] = string.format("%s%s:%d:%d:%s %serror:%s %s",
            ANSI.bold, e.filename, e.line, e.col, ANSI.reset,
            ANSI.red, ANSI.reset, e.msg)
        append_context_ansi(lines, err_ctx.source_lines, e.filename, e.line, e.col, ANSI.red)
        append_notes_ansi(lines, e.notes, err_ctx.source_lines)
    end
    for _, w in ipairs(err_ctx.warnings) do
        lines[#lines + 1] = string.format("%s%s:%d:%d:%s %swarning:%s %s",
            ANSI.bold, w.filename, w.line, w.col, ANSI.reset,
            ANSI.yellow, ANSI.reset, w.msg)
        append_context_ansi(lines, err_ctx.source_lines, w.filename, w.line, w.col, ANSI.yellow)
    end
    return table.concat(lines, "\n")
end

-- Serialize a notes array to JSON fragment.
local function notes_to_json(notes)
    if not notes or #notes == 0 then return "[]" end
    local parts = {}
    for _, note in ipairs(notes) do
        parts[#parts + 1] = string.format(
            '{"file":%s,"line":%d,"col":%d,"message":%s}',
            M._json_str(note.filename), note.line, note.col, M._json_str(note.msg))
    end
    return "[" .. table.concat(parts, ",") .. "]"
end

-- Format errors as JSON array.
function M.format_json(err_ctx)
    local items = {}
    for _, e in ipairs(err_ctx.errors) do
        items[#items + 1] = string.format(
            '{"kind":"error","file":%s,"line":%d,"col":%d,"message":%s,"notes":%s}',
            M._json_str(e.filename), e.line, e.col, M._json_str(e.msg),
            notes_to_json(e.notes))
    end
    for _, w in ipairs(err_ctx.warnings) do
        items[#items + 1] = string.format(
            '{"kind":"warning","file":%s,"line":%d,"col":%d,"message":%s,"notes":%s}',
            M._json_str(w.filename), w.line, w.col, M._json_str(w.msg),
            notes_to_json(w.notes))
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
