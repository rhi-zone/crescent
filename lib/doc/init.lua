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

local TAG_TABLE = defs.TAG_TABLE

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
                -- Sort by name for stable output
                table.sort(fields, function(a, b) return a.name < b.name end)
                for _, f in ipairs(fields) do
                    local type_str = types_mod.display(ctx, f.type_id)
                    -- Try to find the line: first scan AST for M.name,
                    -- then fall back to def_sites
                    local line = find_field_line(ctx, f.name_id)
                              or find_binding_line(ctx, f.name_id)
                    local doc = line and doc_comments[line] or nil
                    exports[#exports + 1] = {
                        name = f.name,
                        type = type_str,
                        doc  = doc,
                        line = line,
                    }
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

return M
