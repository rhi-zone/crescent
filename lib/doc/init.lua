-- lib/doc/init.lua
-- Docgen library: extract typed API documentation from Lua source files.
-- Uses the typechecker to get inferred types and extracts --- doc comments.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

--:: DocExport = { name: string, type: string, doc: string | nil, line: integer | nil, params: { [integer]: { name: string, type: string } } | nil }
--:: DocResult = { file: string, exports: { [integer]: DocExport } }
--:: DocCtxPool = { rev: { [integer]: string }, ht_cap: integer, ht_mask: integer, ht_count: integer, next_id: integer, buf_count: integer, entries: { [integer]: unknown, ... }, bufs: { [integer]: unknown, ... }, map: { [string]: integer, ... }, _anchors: { [integer]: string, ... }, ... }
--:: DocCtxNode = { kind: integer, data: { [integer]: integer }, line: integer }
--:: DocCtxNodeArena = { len: integer, get: (DocCtxNodeArena, integer) -> DocCtxNode }
--:: DocCtxListArena = { get: (DocCtxListArena, integer) -> integer }
--:: DocCtxTypeArena = { get: (DocCtxTypeArena, integer) -> { tag: integer, data: { [integer]: integer } } }
--:: DocCtxFieldArena = { get: (DocCtxFieldArena, integer) -> { name_id: integer, type_id: integer } }
--:: DocCtxScope = { bindings: { [integer]: integer } | nil }
--:: DocCtx = { nodes: DocCtxNodeArena | nil, ast_lists: DocCtxListArena, lists: DocCtxListArena, types: DocCtxTypeArena, fields: DocCtxFieldArena, pool: DocCtxPool, def_sites: { [integer]: { line: integer } } | nil, scope: DocCtxScope, module_return_tids: { [integer]: { [integer]: integer } } | nil }
--:: DocErrCtx = { errors: { [integer]: { msg: string | nil } } | nil }
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
    local ctx_ = ctx --[[:! DocCtx]]
    local ctx_c = (ctx_ --[[: unknown]]) --[[:! Ctx]]
    tid = types_mod.find(ctx_c, tid)
    local t = ctx_.types:get(tid)
    if t.tag ~= TAG_TABLE then return nil end
    local fields = {}
    for i = t.data[0], t.data[0] + t.data[1] - 1 do
        local fid = ctx_.lists:get(i)
        local fe  = ctx_.fields:get(fid)
        local name = intern_mod.get(ctx_.pool, fe.name_id)
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
    local ctx_ = ctx --[[:! DocCtx]]
    -- Scan AST for M.name = ... or function M.name(...)
    if not ctx_.nodes then return nil end
    local nodes_ = ctx_.nodes --[[:! DocCtxNodeArena]]
    for i = 0, nodes_.len - 1 do
        local nd = nodes_:get(i)
        if nd.kind == NODE_ASSIGN_STMT then
            local ls, lc = nd.data[0], nd.data[1]
            for j = ls, ls + lc - 1 do
                local lhs_n = nodes_:get(ctx_.ast_lists:get(j))
                if lhs_n.kind == NODE_FIELD_EXPR and lhs_n.data[1] == name_id then
                    return lhs_n.line
                end
            end
        elseif nd.kind == NODE_FUNC_DECL then
            local name_n = nodes_:get(nd.data[0])
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
    local ctx_ = ctx --[[:! DocCtx]]
    local ctx_any = (ctx_ --[[: unknown]]) --[[:! Ctx]]
    tid = types_mod.find(ctx_any, tid)
    local t = ctx_.types:get(tid)
    local ta = t --[[:! { tag: integer, data: { [integer]: integer } }]]
    if ta.tag ~= TAG_FUNCTION then return nil end
    local params = {}
    local param_count = ta.data[1]
    local has_names = ta.data[6] and ta.data[6] > 0
    for i = 0, param_count - 1 do
        local ptid = ctx_.lists:get(ta.data[0] + i)
        local ptype = types_mod.display(ctx_any, ptid)
        local pname = "_"
        if has_names and i < ta.data[6] then
            local name_id = ctx_.lists:get(ta.data[5] + i)
            local n = intern_mod.get(ctx_.pool, name_id)
            if n then pname = tostring(n) end
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
        local errs = {} --: { [integer]: string }
        local err_ctx_ = err_ctx --[[:! DocErrCtx]]
        if err_ctx_ and err_ctx_.errors then
            for _, e in ipairs(err_ctx_.errors) do
                local msg_ = tostring(e.msg or e)
                errs[#errs + 1] = msg_
            end
        end
        local first_err = errs[1] or "unknown error"
        return nil, "typecheck failed: " .. first_err
    end
    local ctx_ = ctx --[[:! DocCtx]]
    local ctx_any = (ctx_ --[[: unknown]]) --[[:! Ctx]]

    -- Extract doc comments from source
    local doc_comments = extract_doc_comments(source)

    -- Get the module export type
    local export_tid
    local rets = ctx_.module_return_tids
    if rets then
        local rets_ = rets --[[:! { [integer]: { [integer]: integer } }]]
        if #rets_ > 0 and rets_[1] and #rets_[1] > 0 then
            export_tid = types_mod.find(ctx_any, rets_[1][1])
        end
    end

    local exports = {}

    if export_tid then
        local et = ctx_.types:get(export_tid)
        local et_ = et --[[:! { tag: integer }]]
        if et_.tag == TAG_TABLE then
            -- Module returns a table — enumerate its fields as exports
            local fields = table_fields(ctx_, export_tid)
            if fields then
                -- Filter out private fields (names starting with _)
                --: { [integer]: { name_id: integer, name: string, type_id: integer } }
                local public = {}
                for _, f in ipairs(fields) do
                    if f.name:sub(1, 1) ~= "_" then
                        public[#public + 1] = f
                    end
                end
                -- Sort by name for stable output
                local public_cmp = function(a, b)
                    local a_ = a --[[:! { name: string, ... }]]
                    local b_ = b --[[:! { name: string, ... }]]
                    return a_.name < b_.name
                end
                table.sort(public, public_cmp)
                for _, f in ipairs(public) do
                    local type_str = types_mod.display(ctx_any, f.type_id)
                    -- Try to find the line: first scan AST for M.name,
                    -- then fall back to def_sites
                    local line = find_field_line(ctx_, f.name_id)
                              or find_binding_line(ctx_, f.name_id)
                    local doc = line and doc_comments[line] or nil
                    local entry = {
                        name = f.name,
                        type = type_str,
                        doc  = doc,
                        line = line,
                    }
                    local fp = extract_func_params(ctx_, f.type_id)
                    if fp then entry.params = fp end
                    exports[#exports + 1] = entry
                end
            end
        else
            -- Module returns a non-table (function, primitive, etc.)
            -- Emit a single unnamed export for the return value itself.
            local type_str = types_mod.display(ctx_any, export_tid)
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
        if ctx_.def_sites and ctx_.scope then
            local def_sites_ = ctx_.def_sites --[[:! { [integer]: { line: integer } }]]
            local scope_ = ctx_.scope --[[:! DocCtxScope]]
            local bindings = scope_.bindings or {}
            -- Collect all name_ids from def_sites that have a binding
            local names = {}
            for name_id, site in pairs(def_sites_) do
                local name = intern_mod.get(ctx_.pool, name_id)
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
            local names_cmp = function(a, b)
                local a_ = a --[[:! { name: string, ... }]]
                local b_ = b --[[:! { name: string, ... }]]
                return a_.name < b_.name
            end
            table.sort(names, names_cmp)
            for _, n in ipairs(names) do
                local type_str = types_mod.display(ctx_any, n.type_id)
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
    local source = f:read("*a") or ""
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
--: (string) -> { [integer]: unknown }
M.generate_package = function(dir)
    -- Normalize trailing slash
    local dir_base = dir --: string
    local dir_ = (dir_base --[[:! string]])
    -- List .lua files
    local h = io.popen('ls -1 "' .. dir_ .. '"')
    if not h then return {} end
    local entries = {} --: { [integer]: string }
    local line_iter = h:lines()
    while true do
        local line = line_iter() --[[:! string | nil]]
        if line == nil then break end
        if line:match("%.lua$") and not line:match("_test%.lua$") then
            entries[#entries + 1] = line
        end
    end
    h:close()
    -- Sort: init.lua first, then alphabetical
    -- Sort: init.lua first, then alphabetical.
    -- Manual insertion sort to avoid table.sort generic V conflict.
    do
        local n = #entries
        for i = 2, n do
            local v = entries[i]
            local j = i - 1
            while j >= 1 and (entries[j] ~= "init.lua") and
                  (v == "init.lua" or (entries[j] --[[:! string]]) > (v --[[:! string]])) do
                entries[j + 1] = entries[j]
                j = j - 1
            end
            entries[j + 1] = v
        end
    end
    local results = {}
    for _, name in ipairs(entries) do
        local path = dir_ .. name
        local result, err = M.generate(path)
        if result then
            results[#results + 1] = result
        elseif err then
            io.stderr:write("warning: " .. path .. ": " .. tostring(err) .. "\n")
        end
    end
    return results
end

--- Escape HTML special characters.
--: (string) -> string
local function html_escape(s)
    local r, _ = s:gsub("&", "&amp;")
    r, _ = r:gsub("<", "&lt;")
    r, _ = r:gsub(">", "&gt;")
    r, _ = r:gsub('"', "&quot;")
    return r
end

--- Format a doc result (or array of results) as a self-contained HTML page.
M.format_html = function(results)
    -- Accept single result or array
    local results_r = (results --[[: unknown]]) --[[:! { file?: string, ... }]]
    local results_any
    if results_r.file then results_any = { results_r } else results_any = results end
    local results_ = (results_any --[[: unknown]]) --[[:! { [integer]: DocResult }]]
    local out = {}
    out[#out + 1] = '<!DOCTYPE html>\n<html lang="en"><head><meta charset="utf-8">'
    out[#out + 1] = '<meta name="viewport" content="width=device-width,initial-scale=1">'
    -- Title: first file or generic
    local title = #results_ == 1 and html_escape(results_[1].file) or "API Documentation"
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
    for _, result in ipairs(results_) do
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
                    local doc_ = exp.doc --[[:! string]]
                    out[#out + 1] = '<p class="doc">' .. html_escape(doc_) .. '</p>'
                end
                if exp.line then
                    local line_ = exp.line --[[:! integer]]
                    out[#out + 1] = '<p class="line-ref">line ' .. line_ .. '</p>'
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
    local results_r2 = (results --[[: unknown]]) --[[:! { file?: string, ... }]]
    local results_any2
    if results_r2.file then results_any2 = { results_r2 } else results_any2 = results end
    local results2_ = (results_any2 --[[: unknown]]) --[[:! { [integer]: DocResult }]]
    local out = {}
    for _, result in ipairs(results2_) do
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
