-- lib/type/static/cli.lua
-- CLI entry point for the typechecker.
-- Usage: luajit lib/type/static/cli.lua [--format plain|ansi|json|sarif] [--dump] [--rules] [<file> ...]
-- If no files given, globs lib/ for *.lua (excluding *_test.lua and dep/).

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local M = {}

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

-- ── dump helpers ──────────────────────────────────────────────────────────────

-- Escape a string for JSON output.
local function json_str(s)
    return '"' .. s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t') .. '"'
end

--- Return { file, bindings, ["return"] } for filename, or nil if check fails.
-- bindings is an array of { name, type } sorted by name.
function M.dump_one(filename, parent_scope, opts)
    local check_mod  = require("lib.type.static.check")
    local intern_mod = require("lib.type.static.intern")
    local types_mod  = require("lib.type.static.types")
    local _, ctx = check_mod.check_file(filename, parent_scope, nil, opts)
    if not ctx then return nil end
    local list = {}
    for name_id, type_id in pairs(ctx.scope.bindings) do
        local name = intern_mod.get(ctx.pool, name_id) or tostring(name_id)
        list[#list + 1] = { name = name, type = types_mod.display(ctx, types_mod.find(ctx, type_id)) }
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    local result = { file = filename, bindings = list }
    local rets = ctx.module_return_tids
    if rets and #rets > 0 and rets[1] and #rets[1] > 0 then
        result["return"] = types_mod.display(ctx, types_mod.find(ctx, rets[1][1]))
    end
    return result
end

--- Dump a list of files as a JSON array string.
-- Each element: { "file", "bindings": [{name, type},...], "return"? }
function M.dump_json(filenames)
    local parts = { "[\n" }
    local first = true
    for _, filename in ipairs(filenames) do
        local r = M.dump_one(filename)
        if r then
            if not first then parts[#parts + 1] = ",\n" end
            first = false
            parts[#parts + 1] = '  {"file":' .. json_str(r.file) .. ',"bindings":['
            for j, b in ipairs(r.bindings) do
                if j > 1 then parts[#parts + 1] = ',' end
                parts[#parts + 1] = '{"name":' .. json_str(b.name) .. ',"type":' .. json_str(b.type) .. '}'
            end
            parts[#parts + 1] = ']'
            if r["return"] then
                parts[#parts + 1] = ',"return":' .. json_str(r["return"])
            end
            parts[#parts + 1] = '}'
        end
    end
    parts[#parts + 1] = "\n]\n"
    return table.concat(parts)
end

--- Main entry point. argv is a 1-indexed list of arguments.
function M.main(argv)
    local check_mod  = require("lib.type.static.check")
    local errors_mod = require("lib.type.static.errors")
    local intern_mod = require("lib.type.static.intern")
    local types_mod  = require("lib.type.static.types")
    local defs       = require("lib.type.static.defs")

    local format   = "ansi"  -- ansi | plain | json | sarif
    local dump     = false
    local annotate = false
    local run_rules = false  -- --rules flag: run lint passes after check
    local files    = {}

    local i = 1
    while i <= #argv do
        if argv[i] == "--format" and argv[i + 1] then
            format = argv[i + 1]
            i = i + 2
        elseif argv[i] == "--dump" then
            dump = true
            i = i + 1
        elseif argv[i] == "--annotate" then
            annotate = true
            i = i + 1
        elseif argv[i] == "--rules" then
            run_rules = true
            i = i + 1
        else
            files[#files + 1] = argv[i]
            i = i + 1
        end
    end

    -- Load rule passes once when --rules is active.
    local rules_mod
    if run_rules then
        rules_mod = require("lib.type.static.rules")
        rules_mod.load_all()
    end

    -- Auto-discover lib/ when no files given (mirrors v1 behaviour).
    if #files == 0 then
        files = glob_lua_files("lib")
        if #files == 0 then
            io.stderr:write("usage: luajit lib/type/static/cli.lua [--format plain|ansi|json|sarif] [--dump] [--annotate] <file> ...\n")
            os.exit(1)
        end
    end

    -- Look for pkg.lua (walk up from the first file's directory or cwd).
    -- If found and it has typecheck.globals, resolve the listed module names to
    -- file paths and pass them as opts.globals_files to each check call.
    -- Each file is loaded into its own ctx's scope (correct: types allocated in
    -- the checking ctx's arenas, not a shared parent arena).
    local project_opts = nil
    do
        -- Walk up from cwd looking for pkg.lua.
        local function find_pkg_lua()
            -- Try cwd first.
            local f = io.open("pkg.lua", "r")
            if f then f:close(); return "pkg.lua" end
            -- Walk up from first file's directory.
            if #files > 0 then
                local dir = files[1]:match("^(.+)/[^/]+$") or "."
                while dir and dir ~= "" and dir ~= "." do
                    local path = dir .. "/pkg.lua"
                    f = io.open(path, "r")
                    if f then f:close(); return path end
                    dir = dir:match("^(.+)/[^/]+$")
                end
            end
            return nil
        end

        local pkg_path = find_pkg_lua()
        if pkg_path then
            local ok_load, pkg_fn = pcall(loadfile, pkg_path)
            if ok_load and pkg_fn then
                local ok_run, manifest = pcall(pkg_fn)
                if ok_run and type(manifest) == "table" then
                    local tc = manifest.typecheck
                    if tc and type(tc) == "table" and type(tc.globals) == "table" then
                        -- Resolve module names to file paths.
                        -- "lib/type/static/stdlib_types" → "lib/type/static/stdlib_types.lua"
                        local globals_files = {}
                        for _, mod_name in ipairs(tc.globals) do
                            -- Accept both slash-path and dot-path conventions.
                            local rel = mod_name:gsub("%.", "/")
                            globals_files[#globals_files + 1] = rel .. ".lua"
                        end
                        if #globals_files > 0 then
                            project_opts = { globals_files = globals_files }
                        end
                    end
                end
            end
        end
    end

    -- --annotate mode: emit source with inferred type annotations inserted.
    if annotate then
        for _, filename in ipairs(files) do
            local _, ctx = check_mod.check_file(filename, nil, nil, project_opts)
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

                -- Build line → annotation string to insert before that line.
                -- type_at is a flat array {line, col, tid, ...} stride 3.
                -- Emit at most one annotation per source line: pick the first
                -- non-trivial type seen on that line (constraint-generation order).
                local insertions = {}  -- line → ann_text string (one per line)
                local ta = ctx.type_at
                local i = 1
                while i <= #ta do
                    local line = ta[i]
                    local tid  = ta[i + 2]
                    i = i + 3
                    if line and line > 0 and not insertions[line] then
                        local resolved = types_mod.find(ctx, tid)
                        local rt = ctx.types:get(resolved)
                        -- Skip trivial: vars, any, nil.
                        if rt.tag ~= defs.TAG_VAR and rt.tag ~= defs.TAG_ANY
                                and rt.tag ~= defs.TAG_NIL then
                            insertions[line] = "--: " .. types_mod.display(ctx, resolved)
                        end
                    end
                end

                -- Emit source with annotations inserted before each annotated line.
                for ln, src_line in ipairs(src_lines) do
                    if insertions[ln] then
                        local indent = src_line:match("^(%s*)") or ""
                        io.write(indent .. insertions[ln] .. "\n")
                    end
                    io.write(src_line .. "\n")
                end
            end
        end
        return
    end

    -- --dump mode: print inferred top-level bindings for each file.
    if dump then
        if format == "json" then
            io.write(M.dump_json(files))
        else
            for _, filename in ipairs(files) do
                local r = M.dump_one(filename, nil, project_opts)
                if r then
                    io.write("-- " .. r.file .. "\n")
                    for _, b in ipairs(r.bindings) do
                        io.write(b.name .. ": " .. b.type .. "\n")
                    end
                    if r["return"] then
                        io.write("(return): " .. r["return"] .. "\n")
                    end
                end
            end
        end
        return
    end

    local total_errors   = 0
    local total_warnings = 0
    local structured_parts = {}

    for _, filename in ipairs(files) do
        local err_ctx, ctx = check_mod.check_file(filename, nil, nil, project_opts)

        -- Run lint rule passes when --rules is active and the check succeeded.
        if run_rules and ctx then
            rules_mod.run(ctx, err_ctx, filename, nil)
        end

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

-- ── standalone entry point ────────────────────────────────────────────────────

if arg and arg[0] and arg[0]:match("static/cli%.lua$") then
    M.main(arg)
end

return M
