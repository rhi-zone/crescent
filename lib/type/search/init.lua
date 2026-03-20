-- lib/type/search/init.lua
-- Hoogle-style type search: query by type signature across modules.
-- Uses the typechecker for structural matching via try_unify.
--
-- TODO: immediate improvements
-- 1. Accept type_id + ctx as query (not just strings) — programmatic queries
-- 2. Unseal mode: search.query("(string) -> string", index, { unseal = true })
--    ignores $Opaque wrappers, unifies against underlying types
-- 3. Opaque pattern queries: searching for $Opaque<string> means "any opaque
--    wrapping string" (match the type constructor shape, not a specific site)
-- 4. Subtype ranking: exact match > subtype > supertype (currently binary)
-- 5. Arity pre-filtering: reject candidates with wrong param count before
--    check_string (avoids typechecker overhead for obvious non-matches)
-- 6. Acceleration structures for large indexes: bloom filter on type tags,
--    inverted index from tag → exports, pre-cluster by arity
-- 7. Persistent index: serialize index to disk (JSON/binary), reload without
--    re-typechecking all files — needed for registry-scale search

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
-- Arity extraction (for pre-filtering)
-- ---------------------------------------------------------------------------
-- Extract param count from a type string like "(a, b, c) -> d".
-- Returns nil if the type is not a function.
local function extract_arity(type_str)
    local params = type_str:match("^%((.-)%)%s*%->")
    if not params then return nil end
    if params:match("^%s*$") then return 0 end
    local count = 1
    -- Count commas not inside nested parens/braces/angles
    local depth = 0
    for i = 1, #params do
        local c = params:byte(i)
        if c == 40 or c == 123 or c == 60 then depth = depth + 1     -- ( { <
        elseif c == 41 or c == 125 or c == 62 then depth = depth - 1  -- ) } >
        elseif c == 44 and depth == 0 then count = count + 1          -- ,
        end
    end
    return count
end

-- ---------------------------------------------------------------------------
-- Scope lookup helper
-- ---------------------------------------------------------------------------
local function lookup_binding(ctx, name_id)
    local s = ctx.scope
    while s do
        local tid = s.bindings[name_id]
        if tid then return tid end
        s = s.parent
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Query
-- ---------------------------------------------------------------------------
local BATCH_SIZE = 50

--- Query the index for exports matching a type signature.
--- query_type_str: a type annotation string, e.g. "(string) -> string"
--- index: array of { name, file, type } as returned by build_index.
--- opts: optional table { limit = N } (default: no limit)
--- Returns array of { name, file, type, score } sorted by relevance.
--- Score: 3 = exact (both directions), 2 = candidate assignable to query,
---        1 = query assignable to candidate (supertype match).
M.query = function(query_type_str, index, opts)
    opts = opts or {}
    local limit = opts.limit

    -- Pre-filter by arity if query is a function type
    local query_arity = extract_arity(query_type_str)
    local candidates = {}
    for _, entry in ipairs(index) do
        if query_arity then
            local cand_arity = extract_arity(entry.type)
            -- Skip non-functions or wrong arity
            if cand_arity and cand_arity ~= query_arity then
                goto skip
            end
        end
        candidates[#candidates + 1] = entry
        ::skip::
    end

    -- Process in batches to reduce check_string overhead
    local matches = {}
    for batch_start = 1, #candidates, BATCH_SIZE do
        local batch_end = math.min(batch_start + BATCH_SIZE - 1, #candidates)
        local batch_count = batch_end - batch_start + 1

        -- Build a single source with query + all candidates in this batch
        local lines = { "--: " .. query_type_str, "local _q" }
        for i = 0, batch_count - 1 do
            local entry = candidates[batch_start + i]
            lines[#lines + 1] = "--: " .. entry.type
            lines[#lines + 1] = "local _c" .. i
        end
        local src = table.concat(lines, "\n") .. "\n"

        check_mod.clear_cache()
        local _, ctx = check_mod.check_string(src, "_search.lua")
        if ctx then
            local q_nid = intern_mod.intern(ctx.pool, "_q")
            local q_tid = lookup_binding(ctx, q_nid)
            if q_tid then
                q_tid = types_mod.find(ctx, q_tid)
                for i = 0, batch_count - 1 do
                    local c_nid = intern_mod.intern(ctx.pool, "_c" .. i)
                    local c_tid = lookup_binding(ctx, c_nid)
                    if c_tid then
                        c_tid = types_mod.find(ctx, c_tid)
                        local forward  = unify_mod.try_unify(ctx, c_tid, q_tid)
                        local backward = unify_mod.try_unify(ctx, q_tid, c_tid)
                        if forward or backward then
                            local score = (forward and backward) and 3
                                       or forward and 2
                                       or 1
                            local entry = candidates[batch_start + i]
                            matches[#matches + 1] = {
                                name  = entry.name,
                                file  = entry.file,
                                type  = entry.type,
                                score = score,
                                exact = score == 3,
                            }
                        end
                    end
                end
            end
        end
    end

    -- Sort: highest score first, then by name
    table.sort(matches, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.name < b.name
    end)

    -- Apply limit
    if limit and #matches > limit then
        local trimmed = {}
        for i = 1, limit do trimmed[i] = matches[i] end
        matches = trimmed
    end

    return matches
end

return M
