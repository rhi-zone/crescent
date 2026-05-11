-- lib/doc/cli.lua
-- CLI entry point for the docgen tool.
-- Usage: luajit lib/doc/cli.lua [--format json|text|markdown|html] [--package <dir>] <file>...

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local doc    = require("lib.doc")
local json   = require("lib.format.json")
--:: DocExport = { name: string, type: string, doc: string | nil, line: integer | nil }
--:: DocResult = { file: string, exports: { [integer]: DocExport } }

local M = {}

function M.main(argv)
    local format  = "json"
    local files   = {}
    local pkg_dir = nil

    local i = 1
    while i <= #argv do
        local a = argv[i]
        if a == "--format" then
            i = i + 1
            format = argv[i] or "json"
        elseif a:sub(1, 9) == "--format=" then
            format = a:sub(10)
        elseif a == "--package" then
            i = i + 1
            pkg_dir = argv[i]
        elseif a:sub(1, 10) == "--package=" then
            pkg_dir = a:sub(11)
        else
            files[#files + 1] = a
        end
        i = i + 1
    end

    if #files == 0 and not pkg_dir then
        io.stderr:write("usage: luajit lib/doc/cli.lua [--format json|text|markdown|html] [--package <dir>] <file>...\n")
        os.exit(1)
    end

    local results = {}
    local had_error = false

    if pkg_dir then
        results = doc.generate_package(pkg_dir)
        if #results == 0 then
            io.stderr:write("warning: no results from package " .. pkg_dir .. "\n")
        end
    end

    for _, filename in ipairs(files) do
        local result, err = doc.generate(filename)
        if err then
            io.stderr:write("error: " .. filename .. ": " .. (err or "") .. "\n")
            had_error = true
        else
            results[#results + 1] = result
        end
    end

    if format == "html" then
        io.write(doc.format_html(results))
    elseif format == "markdown" then
        io.write(doc.format_markdown(results))
    elseif format == "text" then
        for _, result_u in ipairs(results) do
            local result = result_u --[[:! DocResult]]
            io.write("# " .. result.file .. "\n\n")
            if #result.exports == 0 then
                io.write("(no exports)\n\n")
            else
                for _, exp in ipairs(result.exports) do
                    io.write(exp.name .. ": " .. exp.type .. "\n")
                    if exp.doc then
                        io.write("  " .. (exp.doc --[[:! string]]) .. "\n")
                    end
                    if exp.line then
                        io.write("  line " .. (exp.line --[[:! integer]]) .. "\n")
                    end
                    io.write("\n")
                end
            end
        end
    else
        -- JSON output: single object for one file, array for multiple
        local output
        if #results == 1 then
            output = results[1]
        else
            output = results
        end
        local ok, encoded = pcall(json.encode, output)
        if ok then
            io.write(((encoded --[[: unknown]]) --[[:! string]]) .. "\n")
        else
            io.stderr:write("json encode error: " .. tostring(encoded) .. "\n")
            had_error = true
        end
    end

    os.exit(had_error and 1 or 0)
end

if arg then M.main(arg) end

return M
