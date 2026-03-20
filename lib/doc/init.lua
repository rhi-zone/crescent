-- lib/doc/init.lua
-- Docgen library: extract typed API documentation from Lua source files.
-- Uses the typechecker to get inferred types and extracts --- doc comments.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local check_mod  = require("lib.type.static.check")
local types_mod  = require("lib.type.static.types")
local intern_mod = require("lib.type.static.intern")
local defs       = require("lib.type.static.defs")

local TAG_TABLE    = defs.TAG_TABLE
local TAG_FUNCTION = defs.TAG_FUNCTION

local M = {}

-- ---------------------------------------------------------------------------
-- Doc comment extraction
-- ---------------------------------------------------------------------------
-- Parse source line by line and build a map from line_number → comment text.
-- Lines are 1-indexed, matching the typechecker's convention.
-- Only `---` (triple-dash) comments immediately preceding a declaration count.
-- "Immediately preceding" means no blank lines between the last `---` line
-- and the declaration line.
local function extract_doc_comments(source)
    local comments = {}   -- line_number → string (the declaration line number)
    local pending  = {}   -- accumulated comment lines for the current block
    local prev_was_doc = false

    local lnum = 0
    for line in (source .. "\n"):gmatch("([^\n]*)\n") do
        lnum = lnum + 1
        local stripped = line:match("^%s*%-%-%-(.*)$")
        if stripped then
            -- Strip exactly one leading space if present
            local text = stripped:match("^ (.*)$") or stripped
            pending[#pending + 1] = text
            prev_was_doc = true
        else
            if prev_was_doc and #pending > 0 then
                -- This line is the declaration that follows the doc block.
                comments[lnum] = table.concat(pending, " ")
            end
            pending = {}
            prev_was_doc = false
        end
    end
    return comments
end

-- ---------------------------------------------------------------------------
-- Field extraction from a TAG_TABLE type
-- ---------------------------------------------------------------------------
-- Returns an array of { name_id, name, type_id } for all non-meta fields.
local function table_fields(ctx, tid)
    tid = types_mod.find(ctx, tid)
    local t = ctx.types:get(tid)
    if t.tag ~= TAG_TABLE then return nil end
    local fields = {}
    for i = t.data[0], t.data[0] + t.data[1] - 1 do
        local fid = ctx.lists:get(i)
        local fe  = ctx.fields:get(fid)
        local name = intern_mod.get(ctx.pool, fe.name_id)
        if name then
            fields[#fields + 1] = {
                name_id = fe.name_id,
                name    = name,
                type_id = fe.type_id,
            }
        end
    end
    return fields
end

-- ---------------------------------------------------------------------------
-- Line lookup: given a name/field, find the line where it was defined.
-- For module fields, scan AST for the assignment site.
-- Falls back to def_sites (for locals/upvalues).
-- ---------------------------------------------------------------------------
local NODE_ASSIGN_STMT = defs.NODE_ASSIGN_STMT
local NODE_FUNC_DECL   = defs.NODE_FUNC_DECL
local NODE_FIELD_EXPR  = defs.NODE_FIELD_EXPR
local NODE_IDENTIFIER  = defs.NODE_IDENTIFIER

local function find_field_line(ctx, name_id)
    -- Scan AST for M.name = ... or function M.name(...)
    if not ctx.nodes then return nil end
    for i = 0, ctx.nodes.len - 1 do
        local nd = ctx.nodes:get(i)
        if nd.kind == NODE_ASSIGN_STMT then
            local ls, lc = nd.data[0], nd.data[1]
            for j = ls, ls + lc - 1 do
                local lhs_n = ctx.nodes:get(ctx.ast_lists:get(j))
                if lhs_n.kind == NODE_FIELD_EXPR and lhs_n.data[1] == name_id then
                    return lhs_n.line
                end
            end
        elseif nd.kind == NODE_FUNC_DECL then
            local name_n = ctx.nodes:get(nd.data[0])
            if name_n.kind == NODE_FIELD_EXPR and name_n.data[1] == name_id then
                return name_n.line
            end
        end
    end
    return nil
end

local function find_binding_line(ctx, name_id)
    -- def_sites stores line for local bindings
    local ds = ctx.def_sites and ctx.def_sites[name_id]
    if ds then return ds.line end
    return nil
end

-- ---------------------------------------------------------------------------
-- Parameter name extraction for function types
-- ---------------------------------------------------------------------------
-- Given a function type_id, extract parameter names and types as an array of
-- { name = "param_name", type = "param_type" }.
local function extract_func_params(ctx, tid)
    tid = types_mod.find(ctx, tid)
    local t = ctx.types:get(tid)
    if t.tag ~= TAG_FUNCTION then return nil end
    local params = {}
    local param_count = t.data[1]
    local has_names = t.data[6] and t.data[6] > 0
    for i = 0, param_count - 1 do
        local ptid = ctx.lists:get(t.data[0] + i)
        local ptype = types_mod.display(ctx, ptid)
        local pname = "_"
        if has_names and i < t.data[6] then
            local name_id = ctx.lists:get(t.data[5] + i)
            local n = intern_mod.get(ctx.pool, name_id)
            if n then pname = n end
        end
        params[#params + 1] = { name = pname, type = ptype }
    end
    return params
end

-- ---------------------------------------------------------------------------
-- Core generation logic (shared between generate and generate_string)
-- ---------------------------------------------------------------------------
local function build_doc(source, filename, err_ctx, ctx)
    if not ctx then
        -- Typechecker failed to produce a context
        local errs = {}
        if err_ctx and err_ctx.errors then
            for _, e in ipairs(err_ctx.errors) do
                errs[#errs + 1] = tostring(e.msg or e)
            end
        end
        return nil, "typecheck failed: " .. (#errs > 0 and errs[1] or "unknown error")
    end

    -- Extract doc comments from source
    local doc_comments = extract_doc_comments(source)

    -- Get the module export type
    local export_tid
    local rets = ctx.module_return_tids
    if rets and #rets > 0 and rets[1] and #rets[1] > 0 then
        export_tid = types_mod.find(ctx, rets[1][1])
    end

    local exports = {}

    if export_tid then
        local et = ctx.types:get(export_tid)
        if et.tag == TAG_TABLE then
            -- Module returns a table — enumerate its fields as exports
            local fields = table_fields(ctx, export_tid)
            if fields then
                -- Filter out private fields (names starting with _)
                local public = {}
                for _, f in ipairs(fields) do
                    if f.name:sub(1, 1) ~= "_" then
                        public[#public + 1] = f
                    end
                end
                -- Sort by name for stable output
                table.sort(public, function(a, b) return a.name < b.name end)
                for _, f in ipairs(public) do
                    local type_str = types_mod.display(ctx, f.type_id)
                    -- Try to find the line: first scan AST for M.name,
                    -- then fall back to def_sites
                    local line = find_field_line(ctx, f.name_id)
                              or find_binding_line(ctx, f.name_id)
                    local doc = line and doc_comments[line] or nil
                    local entry = {
                        name = f.name,
                        type = type_str,
                        doc  = doc,
                        line = line,
                    }
                    local fp = extract_func_params(ctx, f.type_id)
                    if fp then entry.params = fp end
                    exports[#exports + 1] = entry
                end
            end
        else
            -- Module returns a non-table (function, primitive, etc.)
            -- Emit a single unnamed export for the return value itself.
            local type_str = types_mod.display(ctx, export_tid)
            exports[#exports + 1] = {
                name = "(module)",
                type = type_str,
                doc  = nil,
                line = nil,
            }
        end
    else
        -- No return statement: expose top-level non-private bindings
        -- from def_sites (these are the locals the module declared)
        if ctx.def_sites and ctx.scope then
            local bindings = ctx.scope.bindings or {}
            -- Collect all name_ids from def_sites that have a binding
            local names = {}
            for name_id, site in pairs(ctx.def_sites) do
                local name = intern_mod.get(ctx.pool, name_id)
                if name and name:sub(1, 1) ~= "_" then
                    -- look up the type from scope
                    local tid = bindings[name_id]
                    if tid then
                        names[#names + 1] = {
                            name    = name,
                            name_id = name_id,
                            type_id = tid,
                            line    = site.line,
                        }
                    end
                end
            end
            table.sort(names, function(a, b) return a.name < b.name end)
            for _, n in ipairs(names) do
                local type_str = types_mod.display(ctx, n.type_id)
                local doc = n.line and doc_comments[n.line] or nil
                exports[#exports + 1] = {
                    name = n.name,
                    type = type_str,
                    doc  = doc,
                    line = n.line,
                }
            end
        end
    end

    return {
        file    = filename,
        exports = exports,
    }
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Generate documentation for a Lua source file on disk.
--- Returns doc_table, err_string|nil.
M.generate = function(filename)
    -- Read source for doc comment extraction (check_file reads it again
    -- internally, but we need the raw text for comment parsing).
    local f, ioerr = io.open(filename, "r")
    if not f then
        return nil, "cannot open file: " .. (ioerr or filename)
    end
    local source = f:read("*a")
    f:close()

    check_mod.clear_cache()
    local err_ctx, ctx = check_mod.check_file(filename)
    return build_doc(source, filename, err_ctx, ctx)
end

--- Generate documentation from a source string (for LSP/editor integration).
--- filename is used for display purposes and require() resolution.
--- Returns doc_table, err_string|nil.
M.generate_string = function(source, filename)
    filename = filename or "<string>"
    check_mod.clear_cache()
    local err_ctx, ctx = check_mod.check_string(source, filename)
    return build_doc(source, filename, err_ctx, ctx)
end

--- Generate documentation for all .lua files in a package directory.
--- Returns an array of doc tables.
M.generate_package = function(dir)
    -- Normalize trailing slash
    if dir:sub(-1) ~= "/" then dir = dir .. "/" end
    -- List .lua files
    local h = io.popen('ls -1 "' .. dir .. '"')
    if not h then return {} end
    local entries = {}
    for line in h:lines() do
        if line:match("%.lua$") and not line:match("_test%.lua$") then
            entries[#entries + 1] = line
        end
    end
    h:close()
    -- Sort: init.lua first, then alphabetical
    table.sort(entries, function(a, b)
        if a == "init.lua" then return true end
        if b == "init.lua" then return false end
        return a < b
    end)
    local results = {}
    for _, name in ipairs(entries) do
        local path = dir .. name
        local result, err = M.generate(path)
        if result then
            results[#results + 1] = result
        elseif err then
            io.stderr:write("warning: " .. path .. ": " .. err .. "\n")
        end
    end
    return results
end

--- Escape HTML special characters.
local function html_escape(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

--- Format a doc result (or array of results) as a self-contained HTML page.
M.format_html = function(results)
    -- Accept single result or array
    if results.file then results = { results } end
    local out = {}
    out[#out + 1] = '<!DOCTYPE html>\n<html lang="en"><head><meta charset="utf-8">'
    out[#out + 1] = '<meta name="viewport" content="width=device-width,initial-scale=1">'
    -- Title: first file or generic
    local title = #results == 1 and html_escape(results[1].file) or "API Documentation"
    out[#out + 1] = '<title>' .. title .. '</title>'
    out[#out + 1] = '<style>'
    out[#out + 1] = [[*{box-sizing:border-box;margin:0;padding:0}
body{font-family:system-ui,-apple-system,sans-serif;line-height:1.6;max-width:52rem;margin:0 auto;padding:1rem 1.5rem;color:#1a1a1a;background:#fff}
h1{font-size:1.8rem;margin:1.5rem 0 1rem;border-bottom:2px solid #e0e0e0;padding-bottom:0.3rem}
h2{font-size:1.3rem;margin:1.2rem 0 0.4rem}
pre{background:#1e1e2e;color:#cdd6f4;padding:0.8rem 1rem;border-radius:6px;overflow-x:auto;font-size:0.9rem;line-height:1.4;margin:0.4rem 0}
code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
p{margin:0.3rem 0 0.6rem}
.doc{color:#444}
.line-ref{font-size:0.8rem;color:#888;margin-top:0.2rem}
.export{margin-bottom:1.2rem;padding-bottom:0.8rem;border-bottom:1px solid #eee}
.no-exports{color:#888;font-style:italic}
section{margin-bottom:2rem}]]
    out[#out + 1] = '</style></head><body>'
    for _, result in ipairs(results) do
        out[#out + 1] = '<section>'
        out[#out + 1] = '<h1>' .. html_escape(result.file) .. '</h1>'
        if #result.exports == 0 then
            out[#out + 1] = '<p class="no-exports">(no exports)</p>'
        else
            for _, exp in ipairs(result.exports) do
                out[#out + 1] = '<div class="export">'
                out[#out + 1] = '<h2>' .. html_escape(exp.name) .. '</h2>'
                out[#out + 1] = '<pre><code>' .. html_escape(exp.type) .. '</code></pre>'
                if exp.doc then
                    out[#out + 1] = '<p class="doc">' .. html_escape(exp.doc) .. '</p>'
                end
                if exp.line then
                    out[#out + 1] = '<p class="line-ref">line ' .. exp.line .. '</p>'
                end
                out[#out + 1] = '</div>'
            end
        end
        out[#out + 1] = '</section>'
    end
    out[#out + 1] = '</body></html>'
    return table.concat(out, "\n")
end

--- Format a doc result (or array of results) as Markdown.
M.format_markdown = function(results)
    -- Accept single result or array
    if results.file then results = { results } end
    local out = {}
    for _, result in ipairs(results) do
        out[#out + 1] = "# " .. result.file
        out[#out + 1] = ""
        if #result.exports == 0 then
            out[#out + 1] = "(no exports)"
            out[#out + 1] = ""
        else
            for _, exp in ipairs(result.exports) do
                out[#out + 1] = "## " .. exp.name
                out[#out + 1] = ""
                out[#out + 1] = "```"
                out[#out + 1] = exp.type
                out[#out + 1] = "```"
                out[#out + 1] = ""
                if exp.doc then
                    out[#out + 1] = exp.doc
                    out[#out + 1] = ""
                end
                out[#out + 1] = "---"
                out[#out + 1] = ""
            end
        end
    end
    return table.concat(out, "\n")
end

return M
