-- lib/type/search/init.lua
-- Hoogle-style type search: query by type signature across modules.
-- Uses the typechecker for structural matching via try_unify.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local check_mod  = require("lib.type.static.check")
local types_mod  = require("lib.type.static.types")
local unify_mod  = require("lib.type.static.unify")
local intern_mod = require("lib.type.static.intern")
local defs       = require("lib.type.static.defs")

local TAG_TABLE    = defs.TAG_TABLE
local TAG_FUNCTION = defs.TAG_FUNCTION

local M = {}

-- ---------------------------------------------------------------------------
-- Index building
-- ---------------------------------------------------------------------------
-- Extract public exports from a typechecker context.
-- Returns array of { name, type_str, type_id, ctx }.
local function extract_exports(ctx)
    local exports = {}
    local rets = ctx.module_return_tids
    local export_tid
    if rets and #rets > 0 and rets[1] and #rets[1] > 0 then
        export_tid = types_mod.find(ctx, rets[1][1])
    end
    if not export_tid then return exports end

    local t = ctx.types:get(export_tid)
    if t.tag ~= TAG_TABLE then
        -- Module returns a non-table (function, primitive, etc.)
        local type_str = types_mod.display(ctx, export_tid)
        exports[#exports + 1] = {
            name     = "(module)",
            type_str = type_str,
        }
        return exports
    end

    -- Enumerate table fields
    for i = t.data[0], t.data[0] + t.data[1] - 1 do
        local fid = ctx.lists:get(i)
        local fe  = ctx.fields:get(fid)
        local name = intern_mod.get(ctx.pool, fe.name_id)
        if name and name:sub(1, 1) ~= "_" then
            local type_str = types_mod.display(ctx, fe.type_id)
            exports[#exports + 1] = {
                name     = name,
                type_str = type_str,
            }
        end
    end

    -- Sort by name for stable output
    table.sort(exports, function(a, b) return a.name < b.name end)
    return exports
end

--- Build a search index from an array of source file paths.
--- Returns an array of { name, file, type } entries.
M.build_index = function(files)
    local index = {}
    for _, filepath in ipairs(files) do
        check_mod.clear_cache()
        local err_ctx, ctx = check_mod.check_file(filepath)
        if ctx then
            local exports = extract_exports(ctx)
            for _, exp in ipairs(exports) do
                index[#index + 1] = {
                    name = exp.name,
                    file = filepath,
                    type = exp.type_str,
                }
            end
        end
    end
    return index
end

--- Build a search index from docgen results (array of doc tables).
--- Each doc table has { file, exports = { { name, type, ... }, ... } }.
M.build_index_from_docs = function(doc_results)
    local index = {}
    -- Accept single result or array
    if doc_results.file then doc_results = { doc_results } end
    for _, result in ipairs(doc_results) do
        for _, exp in ipairs(result.exports) do
            index[#index + 1] = {
                name = exp.name,
                file = result.file,
                type = exp.type,
            }
        end
    end
    return index
end

-- ---------------------------------------------------------------------------
-- Query
-- ---------------------------------------------------------------------------

--- Query the index for exports matching a type signature.
--- query_type_str: a type annotation string, e.g. "(string) -> string"
--- index: array of { name, file, type } as returned by build_index.
--- Returns array of { name, file, type, exact } sorted by relevance.
M.query = function(query_type_str, index)
    local matches = {}
    for _, entry in ipairs(index) do
        -- Create a mini source with the query type and candidate type
        -- as annotated locals. Typecheck it, then try_unify.
        local src = string.format(
            "--: %s\nlocal _q\n--: %s\nlocal _c\n",
            query_type_str, entry.type)
        check_mod.clear_cache()
        local err_ctx, ctx = check_mod.check_string(src, "_search.lua")
        if ctx then
            local q_name = intern_mod.intern(ctx.pool, "_q")
            local c_name = intern_mod.intern(ctx.pool, "_c")
            -- Walk scope chain to find bindings
            local q_tid = ctx.scope and ctx.scope.bindings[q_name]
            local c_tid = ctx.scope and ctx.scope.bindings[c_name]
            -- Also check def_sites for variables that may have been bound
            -- in a child scope (module-level locals end up in root scope)
            if not q_tid and ctx.def_sites and ctx.def_sites[q_name] then
                -- Try parent scopes
                local s = ctx.scope
                while s and not q_tid do
                    q_tid = s.bindings[q_name]
                    s = s.parent
                end
            end
            if not c_tid and ctx.def_sites and ctx.def_sites[c_name] then
                local s = ctx.scope
                while s and not c_tid do
                    c_tid = s.bindings[c_name]
                    s = s.parent
                end
            end
            if q_tid and c_tid then
                q_tid = types_mod.find(ctx, q_tid)
                c_tid = types_mod.find(ctx, c_tid)
                -- Check both directions for flexibility
                local forward  = unify_mod.try_unify(ctx, c_tid, q_tid)
                local backward = unify_mod.try_unify(ctx, q_tid, c_tid)
                if forward or backward then
                    matches[#matches + 1] = {
                        name  = entry.name,
                        file  = entry.file,
                        type  = entry.type,
                        exact = (forward and backward) and true or false,
                    }
                end
            end
        end
    end
    -- Sort: exact matches first, then by name
    table.sort(matches, function(a, b)
        if a.exact ~= b.exact then return a.exact end
        return a.name < b.name
    end)
    return matches
end

return M
