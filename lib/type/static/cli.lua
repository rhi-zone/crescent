-- lib/type/static/cli.lua
-- CLI entry point for the typechecker.
-- Usage: luajit lib/type/static/cli.lua [--format plain|ansi|json|sarif] [--dump] [<file> ...]
-- If no files given, globs lib/ for *.lua (excluding *_test.lua and dep/).

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local function glob_lua_files(dir)
    local files = {}
    local p = io.popen('find "' .. dir .. '" -name "*.lua" -not -name "*_test.lua" -not -path "*/dep/*" 2>/dev/null')
    if not p then return files end
    for line in p:lines() do
        files[#files + 1] = line
    end
    p:close()
    table.sort(files)
    return files
end

local function main()
    local check_mod  = require("lib.type.static.check")
    local errors_mod = require("lib.type.static.errors")
    local intern_mod = require("lib.type.static.intern")
    local types_mod  = require("lib.type.static.types")
    local defs       = require("lib.type.static.defs")

    local format   = "ansi"  -- ansi | plain | json | sarif
    local dump     = false
    local annotate = false
    local files    = {}

    local i = 1
    while i <= #arg do
        if arg[i] == "--format" and arg[i + 1] then
            format = arg[i + 1]
            i = i + 2
        elseif arg[i] == "--dump" then
            dump = true
            i = i + 1
        elseif arg[i] == "--annotate" then
            annotate = true
            i = i + 1
        else
            files[#files + 1] = arg[i]
            i = i + 1
        end
    end

    -- Auto-discover lib/ when no files given (mirrors v1 behaviour).
    if #files == 0 then
        files = glob_lua_files("lib")
        if #files == 0 then
            io.stderr:write("usage: luajit lib/type/static/cli.lua [--format plain|ansi|json|sarif] [--dump] [--annotate] <file> ...\n")
            os.exit(1)
        end
    end

    -- --annotate mode: emit source with inferred type annotations inserted.
    if annotate then
        for _, filename in ipairs(files) do
            local _, ctx = check_mod.check_file(filename)
            if not ctx then
                io.stderr:write(filename .. ": failed to check\n")
            else
                -- Read source lines.
                local src_lines = {}
                local f = io.open(filename, "r")
                if f then
                    for line in f:lines() do src_lines[#src_lines + 1] = line end
                    f:close()
                end

                -- Build line → list of annotation strings to insert before that line.
                local insertions = {}
                for _, ann in ipairs(ctx.inferred_anns) do
                    local line = ann.line
                    if line and line > 0 then
                        local resolved = types_mod.find(ctx, ann.type_id)
                        local rt = ctx.types:get(resolved)
                        -- Skip trivial: vars, any, nil, functions with all-any sigs.
                        if rt.tag ~= defs.TAG_VAR and rt.tag ~= defs.TAG_ANY
                                and rt.tag ~= defs.TAG_NIL then
                            local type_str = types_mod.display(ctx, resolved)
                            local ann_text = "--: " .. type_str
                            if not insertions[line] then insertions[line] = {} end
                            insertions[line][#insertions[line] + 1] = ann_text
                        end
                    end
                end

                -- Emit source with annotations inserted before each annotated line.
                for ln, src_line in ipairs(src_lines) do
                    if insertions[ln] then
                        local indent = src_line:match("^(%s*)") or ""
                        for _, ann_text in ipairs(insertions[ln]) do
                            io.write(indent .. ann_text .. "\n")
                        end
                    end
                    io.write(src_line .. "\n")
                end
            end
        end
        return
    end

    -- --dump mode: print inferred top-level bindings for each file.
    if dump then
        for _, filename in ipairs(files) do
            local _, ctx = check_mod.check_file(filename)
            if ctx then
                -- Collect (name_string, type_id) pairs from top-level scope.
                local pairs_list = {}
                for name_id, type_id in pairs(ctx.scope.bindings) do
                    local name = intern_mod.get(ctx.pool, name_id) or tostring(name_id)
                    pairs_list[#pairs_list + 1] = { name, types_mod.find(ctx, type_id) }
                end
                table.sort(pairs_list, function(a, b) return a[1] < b[1] end)
                io.write("-- " .. filename .. "\n")
                for _, p in ipairs(pairs_list) do
                    io.write(p[1] .. ": " .. types_mod.display(ctx, p[2]) .. "\n")
                end
                -- Show module return type.
                local rets = ctx.module_return_tids
                if rets and #rets > 0 and rets[1] and #rets[1] > 0 then
                    local ret_tid = types_mod.find(ctx, rets[1][1])
                    io.write("(return): " .. types_mod.display(ctx, ret_tid) .. "\n")
                end
            end
        end
        return
    end

    local total_errors   = 0
    local total_warnings = 0
    local structured_parts = {}

    for _, filename in ipairs(files) do
        local err_ctx = check_mod.check_file(filename)
        local ne = #err_ctx.errors
        local nw = #err_ctx.warnings
        total_errors   = total_errors   + ne
        total_warnings = total_warnings + nw

        if format == "json" then
            structured_parts[#structured_parts + 1] = errors_mod.format_json(err_ctx)
        elseif format == "sarif" then
            structured_parts[#structured_parts + 1] = err_ctx
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
        -- Merge all JSON arrays into one.
        io.write("[")
        local first = true
        for _, part in ipairs(structured_parts) do
            local inner = part:match("^%[(.*)%]$") or ""
            if inner ~= "" then
                if not first then io.write(",") end
                io.write(inner)
                first = false
            end
        end
        io.write("]\n")
    elseif format == "sarif" then
        -- Merge all err_ctx into one SARIF document.
        local combined = errors_mod.new_ctx()
        for _, ec in ipairs(structured_parts) do
            for _, e in ipairs(ec.errors)   do combined.errors[#combined.errors+1]     = e end
            for _, w in ipairs(ec.warnings) do combined.warnings[#combined.warnings+1] = w end
        end
        io.write(errors_mod.format_sarif(combined))
        io.write("\n")
    end

    io.stderr:write(string.format("\nChecked %d file(s): %d error(s), %d warning(s)\n",
        #files, total_errors, total_warnings))

    os.exit(total_errors > 0 and 1 or 0)
end

main()
