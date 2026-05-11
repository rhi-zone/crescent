-- lib/type/static/errors.lua
-- Error collection and formatting for the typechecker.

local M = {}

--:: DiagEntry = { kind: string, filename: string, line: integer, col: integer, msg: string, notes: { [integer]: { filename: string, line: integer, col: integer, msg: string }, ... } }
--:: ErrCtx = { errors: { [integer]: DiagEntry, ... }, warnings: { [integer]: DiagEntry, ... }, source_lines: { [string]: { [integer]: string, ... }, ... } }
-- Heterogeneous arg table for diagnostic templates. Each template knows the
-- specific fields it expects (e.g. FIELD_NOT_FOUND uses obj/name; CALL_ARG_MISMATCH
-- uses param_name/act/fn/exp/idx/detail). `any` is used because the union of all
-- per-code shapes would be unwieldy; templates effectively know their inputs.
--:: TemplateArgs = { [string]: string | integer }

-- Create a new error context.
-- source_lines: filename -> array of source lines (populated by set_source).
--: () -> ErrCtx
function M.new_ctx()
    return { errors = {}, warnings = {}, source_lines = {} }
end

-- Store source text for a file so formatters can display context lines.
-- Call this once after creating an err_ctx, before reporting errors.
--: (ErrCtx, string, string | nil) -> ()
function M.set_source(err_ctx, filename, source)
    local src = source or ""
    if src == "" then return end
    local lines = {}
    local i = 1
    local len = #src
    while i <= len do
        local nl = src:find("\n", i, true)
        if nl then
            local p = nl or 0  -- non-nil: guarded by if nl then
            lines[#lines + 1] = src:sub(i, p - 1)
            i = p + 1
        else
            lines[#lines + 1] = src:sub(i)
            break
        end
    end
    err_ctx.source_lines[filename] = lines
end

-- Add an error. Returns the error entry so callers can attach notes.
--: (ErrCtx, string, integer, integer, string) -> DiagEntry
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
--: (DiagEntry | nil, string, integer, integer, string) -> ()
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
--: (ErrCtx, string, integer, integer, string) -> DiagEntry
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
--: (ErrCtx) -> boolean
function M.has_errors(err_ctx)
    return #err_ctx.errors > 0
end

local TAB_SIZE = 4

-- Expand tab characters in a string using TAB_SIZE-column tab stops.
--: (string) -> string
local function expand_tabs(s)
    if not s:find("\t", 1, true) then return s end
    local out = {}
    local vcol = 0
    for i = 1, #s do
        local ch = s:sub(i, i)
        if ch == "\t" then
            local n = TAB_SIZE - (vcol % TAB_SIZE)
            out[#out + 1] = string.rep(" ", n)
            vcol = vcol + n
        else
            out[#out + 1] = ch
            vcol = vcol + 1
        end
    end
    return table.concat(out)
end

-- Visual column (0-indexed) of byte offset `boff` (0-indexed) in s, after tab expansion.
--: (string, integer) -> integer
local function visual_col(s, boff)
    local vcol = 0
    for i = 1, boff do
        if s:sub(i, i) == "\t" then
            vcol = vcol + (TAB_SIZE - (vcol % TAB_SIZE))
        else
            vcol = vcol + 1
        end
    end
    return vcol
end

-- Width of the token starting at byte offset `boff` (0-indexed) in s.
--: (string, integer) -> integer
local function token_width(s, boff)
    local n = 0
    local i = boff + 1
    while i + n <= #s and s:sub(i + n, i + n):match("[%w_]") do n = n + 1 end
    return n > 0 and n or 1
end

-- Append source context (line + caret) to an output lines table.
-- col is 1-indexed (lexer convention). line_num is 1-indexed.
--: ({ [integer]: string, ... }, { [string]: { [integer]: string, ... }, ... } | nil, string, integer, integer | nil) -> ()
local function append_context(out, source_lines, filename, line_num, col)
    if not source_lines then return end
    local file_lines = source_lines[filename]
    if not file_lines or not file_lines[line_num] then return end
    local src = file_lines[line_num]
    local prefix = string.format("  %d | ", line_num)
    out[#out + 1] = prefix .. expand_tabs(src)
    local c = col or 0
    if c > 0 then
        local boff = c - 1
        local vcol = visual_col(src, boff)
        local width = token_width(src, boff)
        out[#out + 1] = string.rep(" ", #prefix + vcol) .. string.rep("^", width)
    end
end

-- Append notes to an output lines table (plain text).
--: ({ [integer]: string, ... }, { [integer]: { filename: string, line: integer, col: integer, msg: string }, ... } | nil, { [string]: { [integer]: string, ... }, ... } | nil) -> ()
local function append_notes_plain(out, notes, source_lines)
    if not notes then return end
    for _, note in ipairs(notes) do
        local line = string.format("  note: %s", note.msg)
        out[#out + 1] = line
        append_context(out, source_lines, note.filename, note.line, note.col)
    end
end

-- Format errors as plain text.
--: (ErrCtx) -> string
function M.format_plain(err_ctx)
    local lines = {} --: { [integer]: string, ... }
    for _, e in ipairs(err_ctx.errors) do
        local s = string.format("%s:%d:%d: error: %s",
            e.filename, e.line, e.col, e.msg)
        lines[#lines + 1] = s
        append_context(lines, err_ctx.source_lines, e.filename, e.line, e.col)
        append_notes_plain(lines, e.notes, err_ctx.source_lines)
    end
    for _, w in ipairs(err_ctx.warnings) do
        local s = string.format("%s:%d:%d: warning: %s",
            w.filename, w.line, w.col, w.msg)
        lines[#lines + 1] = s
        append_context(lines, err_ctx.source_lines, w.filename, w.line, w.col)
    end
    return table.concat(lines, "\n")
end

-- ANSI color codes
--:: ANSICodes = { reset: string, red: string, yellow: string, bold: string, dim: string }
--: ANSICodes
local ANSI = {
    reset  = "\27[0m",
    red    = "\27[31m",
    yellow = "\27[33m",
    bold   = "\27[1m",
    dim    = "\27[2m",
}

-- Append ANSI-colored source context to an output lines table.
--: ({ [integer]: string, ... }, { [string]: { [integer]: string, ... }, ... } | nil, string, integer, integer | nil, string | nil) -> ()
local function append_context_ansi(out, source_lines, filename, line_num, col, caret_color)
    if not source_lines then return end
    local file_lines = source_lines[filename]
    if not file_lines or not file_lines[line_num] then return end
    local src = file_lines[line_num]
    local prefix = string.format("  %d | ", line_num)
    out[#out + 1] = ANSI.dim .. prefix .. expand_tabs(src) .. ANSI.reset
    local c = col or 0
    if c > 0 then
        local cc = caret_color or ANSI.red
        local boff = c - 1
        local vcol = visual_col(src, boff)
        local width = token_width(src, boff)
        out[#out + 1] = string.rep(" ", #prefix + vcol) .. cc .. string.rep("^", width) .. ANSI.reset
    end
end

-- Append notes to an output lines table (ANSI).
--: ({ [integer]: string, ... }, { [integer]: { filename: string, line: integer, col: integer, msg: string }, ... } | nil, { [string]: { [integer]: string, ... }, ... } | nil) -> ()
local function append_notes_ansi(out, notes, source_lines)
    if not notes then return end
    for _, note in ipairs(notes) do
        local line = string.format("  %snote:%s %s", ANSI.bold, ANSI.reset, note.msg)
        out[#out + 1] = line
        append_context_ansi(out, source_lines, note.filename, note.line, note.col, ANSI.dim)
    end
end

-- Format errors with ANSI colors.
--: (ErrCtx) -> string
function M.format_ansi(err_ctx)
    local lines = {} --: { [integer]: string, ... }
    for _, e in ipairs(err_ctx.errors) do
        local s = string.format("%s%s:%d:%d:%s %serror:%s %s",
            ANSI.bold, e.filename, e.line, e.col, ANSI.reset,
            ANSI.red, ANSI.reset, e.msg)
        lines[#lines + 1] = s
        append_context_ansi(lines, err_ctx.source_lines, e.filename, e.line, e.col, ANSI.red)
        append_notes_ansi(lines, e.notes, err_ctx.source_lines)
    end
    for _, w in ipairs(err_ctx.warnings) do
        local s = string.format("%s%s:%d:%d:%s %swarning:%s %s",
            ANSI.bold, w.filename, w.line, w.col, ANSI.reset,
            ANSI.yellow, ANSI.reset, w.msg)
        lines[#lines + 1] = s
        append_context_ansi(lines, err_ctx.source_lines, w.filename, w.line, w.col, ANSI.yellow)
    end
    return table.concat(lines, "\n")
end

-- Serialize a notes array to JSON fragment.
--: ({ [integer]: { filename: string, line: integer, col: integer, msg: string }, ... } | nil) -> string
local function notes_to_json(notes)
    if not notes then return "[]" end
    if #notes == 0 then return "[]" end
    local parts = {}
    for _, note in ipairs(notes) do
        parts[#parts + 1] = string.format(
            '{"file":%s,"line":%d,"col":%d,"message":%s}',
            M._json_str(note.filename), note.line, note.col, M._json_str(note.msg))
    end
    return "[" .. table.concat(parts, ",") .. "]"
end

-- Format errors as JSON array.
--: (ErrCtx) -> string
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

-- Template table: maps error code → function(args) → string.
-- Populated lazily so defs can be required without a circular dependency.
local _templates --: { [integer]: (TemplateArgs) -> string } | nil

local function build_templates()
    local defs = require("lib.type.static.defs")
    local E = defs.E
    _templates = {
        --: (TemplateArgs) -> string
        [E.FIELD_NOT_FOUND]       = function(a)
            if a.obj then
                return "`" .. a.obj .. "." .. a.name .. "` doesn't exist"
            end
            return "`" .. a.name .. "` doesn't exist"
        end,
        --: (TemplateArgs) -> string
        [E.CALL_ARG_MISMATCH]     = function(a)
            local label = a.param_name
                and ("`" .. a.param_name .. "` is `" .. a.act .. "`, but " .. a.fn .. " expects `" .. a.exp .. "`")
                or  ("argument " .. a.idx .. " is `" .. a.act .. "`, but " .. a.fn .. " expects `" .. a.exp .. "`")
            if a.detail then label = label .. ": " .. a.detail end
            return label
        end,
        --: (TemplateArgs) -> string
        [E.CALL_ARG_MISSING]      = function(a)
            local label = a.param_name and ("`" .. a.param_name .. "`") or ("argument " .. a.idx)
            return label .. ": missing required argument (expected `" .. a.exp .. "`, got nil)"
        end,
        --: (TemplateArgs) -> string
        [E.ARITH_TYPE]            = function(a)
            return "cannot perform arithmetic on `" .. a.t .. "`"
        end,
        --: (TemplateArgs) -> string
        [E.LENGTH_TYPE]           = function(a)
            return "cannot get length of `" .. a.t .. "`"
        end,
        --: (TemplateArgs) -> string
        [E.COMPARE_TYPE]          = function(a)
            return "cannot compare `" .. a.t .. "`"
        end,
        --: (TemplateArgs) -> string
        [E.COMPARE_CROSS]         = function(a)
            return "cannot compare `" .. a.left .. "` with `" .. a.right .. "`"
        end,
        --: (TemplateArgs) -> string
        [E.CONCAT_TYPE]           = function(a)
            return "cannot concatenate `" .. a.t .. "`"
        end,
        --: (TemplateArgs) -> string
        [E.UNHANDLED_EXPR]        = function(a)
            return "unhandled expr kind " .. a.kind
        end,
        --: (TemplateArgs) -> string
        [E.UNKNOWN_IDENTIFIER]    = function(a)
            return "unknown identifier `" .. a.name .. "`"
        end,
        --: (TemplateArgs) -> string
        [E.VARARG_OUTSIDE_FN]     = function(_a)
            return "`...` used outside a vararg function"
        end,
        --: (TemplateArgs) -> string
        [E.BINARY_OP_UNKNOWN]     = function(a)
            return "unknown binary operator " .. a.op
        end,
        --: (TemplateArgs) -> string
        [E.TYPE_MISMATCH]         = function(a)
            local msg = "type mismatch: `" .. a.got .. "` is not assignable to `" .. a.exp .. "`"
            if a.detail then msg = msg .. ": " .. a.detail end
            return msg
        end,
        --: (TemplateArgs) -> string
        [E.ASSIGN_MISMATCH]       = function(a)
            local msg = "cannot assign `" .. a.got .. "` to `" .. a.name .. "`"
            if a.detail then msg = msg .. ": " .. a.detail end
            return msg
        end,
        --: (TemplateArgs) -> string
        [E.FIELD_REASSIGN]        = function(a)
            return "`" .. a.name .. "` is `" .. a.existing
                .. "`, but this location expects `" .. a.got .. "`"
        end,
        --: (TemplateArgs) -> string
        [E.INDEX_ASSIGN_MISMATCH] = function(a)
            return "cannot assign `" .. a.got
                .. "` \xe2\x80\x94 doesn't match indexer type `" .. a.indexer .. "`"
        end,
        --: (TemplateArgs) -> string
        [E.NO_MATCHING_OVERLOAD]  = function(a)
            return (a.msg --[[:! string]])  -- pre-formatted multi-line string
        end,
        --: (TemplateArgs) -> string
        [E.UNION_CALL_MISMATCH]   = function(a)
            return (a.msg --[[:! string]])  -- pre-formatted multi-line string
        end,
        --: (TemplateArgs) -> string
        [E.CANNOT_CALL]           = function(a)
            return "cannot call type `" .. a.t .. "`"
        end,
        --: (TemplateArgs) -> string
        [E.METHOD_NOT_FOUND]      = function(a)
            return "no method `" .. a.method .. "` on type `" .. a.t .. "`"
        end,
        --: (TemplateArgs) -> string
        [E.UNNAMED_PARAMS]        = function(_a)
            return "declared function type has unnamed parameters"
                .. " \xe2\x80\x94 add `name: type` to show names in error messages"
        end,
        --: (TemplateArgs) -> string
        [E.EXPLICIT_ANY]          = function(_a)
            return "explicit `any` in annotation \xe2\x80\x94"
                .. " use `unknown` for an unconstrained value, or a specific type"
        end,
        --: (TemplateArgs) -> string
        [E.FIELD_READONLY]        = function(a)
            return "cannot assign to readonly field `" .. a.field .. "`"
        end,
        --: (TemplateArgs) -> string
        [E.NON_EXHAUSTIVE]        = function(a)
            return "non-exhaustive match on `" .. a.name .. "`: unhandled " .. a.remaining
        end,
        --: (TemplateArgs) -> string
        [E.FIELD_ON_PRIMITIVE]    = function(a)
            return "field access on `" .. a.t .. "`: `" .. a.t .. "` cannot have fields"
        end,
        --: (TemplateArgs) -> string
        [E.CONSTRAINT_MISMATCH]   = function(a)
            local msg = "'" .. a.name .. "' does not satisfy constraint '" .. a.constraint .. "'"
            if a.detail then msg = msg .. ": " .. a.detail end
            return msg
        end,
        --: (TemplateArgs) -> string
        [E.INDEX_KEY_NOT_FOUND]   = function(a)
            return "type '" .. a.t .. "' has no member '" .. a.k .. "'"
        end,
        --: (TemplateArgs) -> string
        [E.FORCE_CAST_TO_ANY]     = function(_a)
            return "`--[[:! any]]` is not allowed. Use `--[[: unknown]]` (regular cast) instead."
                .. " The force-cast `:!` is for narrowing `unknown` to a concrete type,"
                .. " not for casting to `any`."
        end,
        --: (TemplateArgs) -> string
        [E.LOCAL_NEEDS_INIT]      = function(a)
            return "annotated `local " .. a.name .. "` requires an initializer because `nil`"
                .. " is not in type `" .. a.t .. "` (use `" .. a.t .. " | nil` to allow nil,"
                .. " or provide an initializer)"
        end,
        --: (TemplateArgs) -> string
        [E.MATCH_CONTAINS_ANY]    = function(_a)
            return "match type contains `any` \xe2\x80\x94 exhaustiveness cannot be verified;"
                .. " replace `any` with `unknown` or a specific type"
        end,
        --: (TemplateArgs) -> string
        [E.ANY_IN_TYPE]           = function(_a)
            return "type contains 'any' \xe2\x80\x94 use 'unknown' for unconstrained values,"
                .. " or a specific type"
        end,
        --: (TemplateArgs) -> string
        [E.FORCE_CAST]            = function(_a)
            return "force cast \xe2\x80\x94 fix the upstream type annotation instead; see CLAUDE.md"
        end,
        --: (TemplateArgs) -> string
        [E.MODULE_DECL]           = function(_a)
            return "--:: module declaration should not be used"
                .. " \xe2\x80\x94 require() return types are inferred from return M"
        end,
    }
end

-- Convert an integer error code + args table to a human-readable string.
-- Returns "error <code>" when the code is unknown (should not happen in practice).
--: (integer, TemplateArgs) -> string
function M.format_diag(code, args)
    if not _templates then build_templates() end
    local fn = _templates[code]
    if fn then return fn(args) end
    return "error " .. tostring(code)
end

-- Minimal JSON string escaping.
--: (unknown) -> string
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
--: (ErrCtx) -> string
function M.format_sarif(err_ctx)
    local results = {}
    for _, e in ipairs(err_ctx.errors) do
        results[#results + 1] = string.format(
            '{"ruleId":"checker","level":"error","message":{"text":%s},"locations":[{"physicalLocation":{"artifactLocation":{"uri":%s},"region":{"startLine":%d,"startColumn":%d}}}]}',
            M._json_str(e.msg), M._json_str(e.filename), e.line, e.col)
    end
    for _, w in ipairs(err_ctx.warnings) do
        results[#results + 1] = string.format(
            '{"ruleId":"checker","level":"warning","message":{"text":%s},"locations":[{"physicalLocation":{"artifactLocation":{"uri":%s},"region":{"startLine":%d,"startColumn":%d}}}]}',
            M._json_str(w.msg), M._json_str(w.filename), w.line, w.col)
    end
    return string.format(
        '{"version":"2.1.0","$schema":"https://json.schemastore.org/sarif-2.1.0.json","runs":[{"tool":{"driver":{"name":"crescent","version":"0.2.0"}},"results":[%s]}]}',
        table.concat(results, ","))
end

return M
