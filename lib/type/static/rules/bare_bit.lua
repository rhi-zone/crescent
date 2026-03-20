-- lib/type/static/rules/bare_bit.lua
-- Rule: bare bit.* global without a local require("bit") binding.
-- If a file uses bit.xxx but doesn't have `local bit = require(...)` at the top,
-- emit a warning — LuaJIT provides bit as a global, but it's better to require()
-- it explicitly so the dependency is declared and the code is portable.
-- Skips vendored files (files containing --[[EmmyLua]], "-- Author:", "-- Copyright").

local rules = require("lib.type.static.rules")

local M = {}
M.name        = "bare_bit"
M.description = "bare bit.* global — add `local bit = require(\"bit\")` at top"

-- Simple heuristic: scan source lines. The ctx.err has source_lines attached;
-- we reconstruct the source from ctx.err.source_lines for the file.
function M.check(ctx, err_ctx, filepath, severity, errors_mod)
    -- Skip test files.
    if filepath:match("_test%.lua$") then return end

    -- Get source lines from the err context.
    local src_lines = err_ctx.source_lines and err_ctx.source_lines[filepath]
    if not src_lines then
        -- Try without leading "./" prefix variations.
        if filepath:sub(1, 2) == "./" then
            src_lines = err_ctx.source_lines and err_ctx.source_lines[filepath:sub(3)]
        end
    end
    if not src_lines then return end

    -- Check for vendored file markers. If found, skip.
    local full_src = table.concat(src_lines, "\n")
    if full_src:find("--[[EmmyLua]]", 1, true) then return end
    if full_src:find("-- Author:", 1, true) then return end
    if full_src:find("-- Copyright", 1, true) then return end

    -- Scan line by line, skipping comment-only lines.
    -- A line is "code" if it is not purely a comment (does not start with optional
    -- whitespace followed by '--').  Inline comments are not stripped here; this
    -- is a heuristic that avoids the most common false-positive case.
    local has_bit_access = false
    local has_local_bit  = false
    local first_bit_line = nil

    for ln, line in ipairs(src_lines) do
        -- Strip leading whitespace to detect comment-only lines.
        local trimmed = line:match("^%s*(.*)") or ""
        local is_comment_line = trimmed:sub(1, 2) == "--"
        if not is_comment_line then
            -- Check for bit.* usage (field access on bare `bit` identifier).
            if line:find("bit%.", 1, false) then
                has_bit_access = true
                if not first_bit_line then first_bit_line = ln end
            end
            -- Check for local bit binding.
            if line:find("local%s+bit%s*[,=%s]", 1, false)
                    or line:find("local%s+[%w_]+%s*,%s*bit%s*[,=]", 1, false) then
                has_local_bit = true
            end
        end
    end

    if has_bit_access and not has_local_bit then
        local msg = "bare `bit.*` global — add `local bit = require(\"bit\")` at top"
        local report_line = first_bit_line or 1
        if severity == "error" then
            errors_mod.error(err_ctx, filepath, report_line, 1, msg)
        else
            errors_mod.warning(err_ctx, filepath, report_line, 1, msg)
        end
    end
end

rules.register(M.name, M)
return M
