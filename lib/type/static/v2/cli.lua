-- lib/type/static/v2/cli.lua
-- CLI entry point for the v2 typechecker.
-- Usage: luajit lib/type/static/v2/cli.lua [--format plain|ansi|json] <file> [<file> ...]

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local function main()
    local check_mod  = require("lib.type.static.v2.check")
    local errors_mod = require("lib.type.static.v2.errors")

    local format = "ansi"  -- ansi | plain | json
    local files  = {}

    local i = 1
    while i <= #arg do
        if arg[i] == "--format" and arg[i + 1] then
            format = arg[i + 1]
            i = i + 2
        else
            files[#files + 1] = arg[i]
            i = i + 1
        end
    end

    if #files == 0 then
        io.stderr:write("usage: luajit lib/type/static/v2/cli.lua [--format plain|ansi|json] <file> ...\n")
        os.exit(1)
    end

    local total_errors   = 0
    local total_warnings = 0
    local json_parts     = {}

    for _, filename in ipairs(files) do
        local err_ctx = check_mod.check_file(filename)
        local ne = #err_ctx.errors
        local nw = #err_ctx.warnings
        total_errors   = total_errors   + ne
        total_warnings = total_warnings + nw

        if format == "json" then
            json_parts[#json_parts + 1] = errors_mod.format_json(err_ctx)
        elseif ne > 0 or nw > 0 then
            if format == "plain" then
                io.stderr:write(errors_mod.format_plain(err_ctx))
            else
                io.stderr:write(errors_mod.format_ansi(err_ctx))
            end
            io.stderr:write("\n")
        end
    end

    if format == "json" then
        -- Merge all JSON arrays into one
        io.write("[")
        local first = true
        for _, part in ipairs(json_parts) do
            -- Strip outer brackets and concat
            local inner = part:match("^%[(.*)%]$") or ""
            if inner ~= "" then
                if not first then io.write(",") end
                io.write(inner)
                first = false
            end
        end
        io.write("]\n")
    end

    io.stderr:write(string.format("\nChecked %d file(s): %d error(s), %d warning(s)\n",
        #files, total_errors, total_warnings))

    os.exit(total_errors > 0 and 1 or 0)
end

main()
