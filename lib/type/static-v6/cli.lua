-- lib/type/static-v6/cli.lua
-- v6 typechecker CLI entry point.
--
-- Invoked via `bin/cr check --v6 <file>...`.
-- All I/O is via injected caps; no global io/os references in the library.

if not package.path:find("?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local source_mod = require("lib.type.static-v6.source")

local M = {}

--:: V6CliCaps = { read_file: (path: string) -> (string | nil, string | nil), write_out: (msg: string) -> nil, write_err: (msg: string) -> nil, is_tty: ((unknown) -> boolean) | nil }
--:: V6CliOpts = { files: string[] }
--:: require "lib.type.static-v6.type_defs"

--: (string[]) -> (V6CliOpts | nil, string | nil)
local function parse_argv(argv)
    local opts = { files = {} --[[: string[] ]] }
    local end_of_flags = false
    for i = 1, #argv do
        local a = argv[i]
        if end_of_flags then
            opts.files[#opts.files + 1] = a
        elseif a == "--" then
            end_of_flags = true
        elseif a == "--v6" then
            -- Already-consumed flag; tolerated here too.
        elseif a:sub(1, 2) == "--" then
            return nil, "cr check --v6: unknown flag " .. a
        else
            opts.files[#opts.files + 1] = a
        end
    end
    if #opts.files == 0 then
        return nil, "cr check --v6: at least one file is required"
    end
    return opts, nil
end

--: (unknown) -> Span | nil
local function diagnostic_span(details)
    if type(details) ~= "table" then return nil end
    local span = details.span
    if type(span) == "table" then return span end
    return nil
end

--: (string, CheckDiag) -> string
local function format_diagnostic(path, d)
    local span = diagnostic_span(d.details)
    local file = path
    local line = nil
    local column = nil
    if span ~= nil then
        if span.file ~= nil then file = tostring(span.file) end
        line = span.line
        column = span.column
    end
    local where = file
    if line ~= nil then
        where = where .. ":" .. tostring(line)
        if column ~= nil then where = where .. ":" .. tostring(column) end
    end
    return where .. ": " .. tostring(d.code) .. ": " .. tostring(d.message)
end

--: (string, UnsafeBoundary) -> CheckDiag
local function unsafe_boundary_diagnostic(path, boundary)
    return {
        code = "UNSAFE_BOUNDARY",
        message = "unsafe boundary admitted by " .. tostring(boundary.site or "unknown site"),
        details = { span = boundary.span or { file = path }, boundary = boundary },
    }
end

--: (string, V6CliCaps) -> { diagnostics: CheckDiag[] }
local function check_one(path, caps)
    local src, ferr = caps.read_file(path)
    if src == nil then
        return {
            diagnostics = {
                {
                    code = "IO_ERROR",
                    message = "cannot read file: " .. tostring(ferr or path),
                    details = { span = { file = path } },
                },
            },
        }
    end
    local result = source_mod.check_string(src, path)
    local diagnostics = {} --: { [integer]: CheckDiag }
    for _, d in ipairs(result.diagnostics) do
        diagnostics[#diagnostics + 1] = d
    end
    for _, boundary in ipairs(result.env.unsafe_boundaries) do
        diagnostics[#diagnostics + 1] = unsafe_boundary_diagnostic(path, boundary)
    end
    return { diagnostics = diagnostics }
end

--: (string[], V6CliCaps) -> integer
function M.run(argv, caps)
    local opts, perr = parse_argv(argv)
    if opts == nil then
        caps.write_err(tostring(perr) .. "\n")
        return 2
    end

    local lines = {} --: { [integer]: string | number }
    for _, path in ipairs(opts.files) do
        local result = check_one(path, caps)
        for _, d in ipairs(result.diagnostics) do
            lines[#lines + 1] = format_diagnostic(path, d)
        end
    end

    if #lines > 0 then
        caps.write_out(table.concat(lines, "\n") .. "\n")
        return 1
    end
    return 0
end

return M
