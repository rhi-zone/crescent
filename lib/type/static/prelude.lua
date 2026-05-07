-- lib/type/static/prelude.lua
-- Lua 5.1 / LuaJIT stdlib type bindings for the typechecker.
-- Call M.populate(ctx) after creating a checker context to add stdlib types
-- to ctx.scope. Types are allocated into ctx's own arena so IDs are valid.

local intern_mod = require("lib.type.static.intern")
local env_mod    = require("lib.type.static.env")
local defs_mod   = require("lib.type.static.defs")

local M = {}

-- Module-level parse cache: path → { ar, strings }
--
-- INVARIANT: infer.check_string calls populate() BEFORE parsing the user
-- source.  Therefore, at populate time the pool contains only pre-seeded
-- keywords (IDs 0–21) for any fresh pool.  Because keyword seeding is
-- deterministic, every fresh pool assigns the same integer IDs to the same
-- stdlib strings encountered in the same file-parse order.
--
-- The cache stores:
--   ar      – the annotation-arena result from the FIRST parse (pool-specific
--             IDs, but identical for all fresh pools due to the invariant above)
--   strings – ordered list of {id, str} pairs for each new intern ID added
--             during the stdlib parse; used to populate subsequent fresh pools
--             so that later user-source parsing finds stdlib names at the
--             expected IDs.
--
-- On a cache hit the file I/O, parse_mod.parse, and ann_mod.parse_annotations
-- calls are all skipped.  Instead the cached strings are re-interned into the
-- current pool (free if already present; idempotent) and the cached ar is
-- reused directly.
--
-- Invariant violation (e.g. passing a pre-used pool): handled conservatively —
-- if the pool's next_id differs from the expected first stdlib ID (22) at
-- populate time, the cache is bypassed and a full re-parse is done.
--
-- Call M.clear_cache() to force re-parsing (e.g. if stdlib _types.lua files
-- change at runtime, which should not happen in normal usage).
--: { [string]: { ar: AnnResult, strings: { [integer]: { [integer]: unknown, ... }, ... }, first_id: integer }, ... }
local _cache = {}   -- path → { ar, strings, first_id }

function M.clear_cache()
    _cache = {}
end

-- Parse a _types.lua declaration file and populate ctx.scope.
-- Uses the annotation pipeline.
-- Variable declarations (--:: declare name = type) are bound in ctx.scope.
-- Type aliases (--:: Name = type) are registered in ctx.scope.type_bindings.
-- After loading, primitive meta type ctx fields are derived from aliases.
--: (Ctx, string) -> ()
local function load_decls(ctx, path)
    local parse_mod  = require("lib.type.static.parse")
    local ann_mod    = require("lib.type.static.ann")
    local constrain_mod = require("lib.type.static.constrain")

    local cached = _cache[path]
    local ar

    if cached and ctx.pool.next_id == cached.first_id then
        -- Cache hit: pool is in the expected state (same number of pre-existing
        -- IDs as when the cache was built).  Re-intern the stdlib strings to
        -- ensure they are registered in this pool at the same IDs, then reuse ar.
        for _, entry in ipairs(cached.strings) do
            intern_mod.intern(ctx.pool, entry[2])
        end
        ar = cached.ar
    else
        -- Cache miss: full parse + annotate.
        local f = io.open(path, "r")
        if not f then return end
        local source = f:read("*a")
        f:close()

        local first_id = ctx.pool.next_id

        local ok_p, pr = pcall(parse_mod.parse, source, path, ctx.pool)
        if not ok_p then return end

        local ok_a, ar_ = pcall(ann_mod.parse_annotations, pr.lexer.annotations, ctx.pool, path)
        if not ok_a then return end
        ar = ar_

        -- Collect all strings that were freshly interned during this parse so
        -- that we can re-register them in subsequent pools on a cache hit.
        local strings = {}
        for id = first_id, ctx.pool.next_id - 1 do
            strings[#strings + 1] = { id, intern_mod.get(ctx.pool, id) }
        end

        _cache[path] = { ar = ar, strings = strings, first_id = first_id }
    end

    -- Temporarily attach annotation arenas so resolve_annotation_type can read them.
    local saved_ann = ctx.ann
    ctx.ann = ar

    local resolve = constrain_mod.resolve_annotation_type

    -- Collect all ANN_DECL, ANN_MODULE, and ANN_AUGMENT results.
    local decls = {}
    local module_decls = {}
    local augment_decls = {}
    local augment_decl_lines = {}
    for line, r in pairs(ar.results) do
        if r.kind == defs_mod.ANN_DECL then
            decls[#decls + 1] = r
        elseif r.kind == defs_mod.ANN_MODULE then
            module_decls[#module_decls + 1] = r
        elseif r.kind == defs_mod.ANN_AUGMENT then
            augment_decls[#augment_decls + 1] = r
            augment_decl_lines[r] = line
        end
    end

    -- Pass 1: pre-register type aliases with placeholder body so that
    -- forward references within the file resolve correctly.
    for _, r in ipairs(decls) do
        if not r.decl_var then
            local params = nil
            if r.type_params_len and r.type_params_len > 0 then
                params = {}
                for i = r.type_params_start, r.type_params_start + r.type_params_len - 1 do
                    params[#params + 1] = ar.lists:get(i)
                end
            end
            env_mod.bind_type(ctx.scope, r.name_id, { body = ctx.T_ANY, params = params })
        end
    end

    -- Pass 2a: resolve plain type alias bodies (non-decl_var, non-newtype) first
    -- so that variable declarations in Pass 2b can reference fully-resolved aliases.
    -- This mirrors constrain.lua's Pass 2a/2b split and is required when a variable
    -- declaration references a generic alias (e.g. `declare pairs` uses PairsReturn<T>).
    local types_mod = require("lib.type.static.types")
    for _, r in ipairs(decls) do
        if not r.decl_var and not r.newtype then
            local alias = env_mod.lookup_type(ctx.scope, r.name_id)
            -- For generic aliases, push a temporary scope where each type
            -- parameter is bound to a TAG_NAMED placeholder.  This mirrors the
            -- logic in constrain.lua (Pass 2a) and allows the alias body to
            -- reference its own parameters (e.g. `match T { ... }`) without
            -- triggering "undefined type" errors.
            local old_scope = ctx.scope
            if alias and alias.params and #alias.params > 0 then
                local temp = env_mod.new(ctx.scope.level + 1)
                temp.parent = ctx.scope
                for _, param_name_id in ipairs(alias.params) do
                    local ph = types_mod.alloc_type(ctx, defs_mod.TAG_NAMED)
                    ctx.types:get(ph).data[0] = param_name_id
                    env_mod.bind_type(temp, param_name_id, { body = ph, params = nil, nominal = false })
                end
                ctx.scope = temp
            end
            local resolved = resolve(ctx, r.type_id)
            ctx.scope = old_scope
            if alias then alias.body = resolved end
        end
    end

    -- Pass 2b: resolve newtypes and variable declarations (which may reference
    -- aliases resolved in Pass 2a).
    for _, r in ipairs(decls) do
        if r.decl_var then
            env_mod.bind(ctx.scope, r.name_id, resolve(ctx, r.type_id))
        elseif r.newtype then
            -- Newtype: resolve underlying type, assign a stable nominal identity.
            -- Use path (the .d.lua file) + name as the hash key so stdlib newtypes
            -- are consistent across all files that load this prelude.
            local ann_nom = ctx.ann.types:get(r.type_id)
            local underlying = resolve(ctx, ann_nom.data[2])
            local name_str = intern_mod.get(ctx.pool, r.name_id) or ""
            local nominal_id = defs_mod.fnv31(path .. ":newtype:" .. name_str)
            local nom = types_mod.make_nominal(ctx, r.name_id, nominal_id, underlying)
            local alias = env_mod.lookup_type(ctx.scope, r.name_id)
            if alias then alias.body = nom end
        end
    end

    -- Pass 3: resolve module declarations and store in ctx.module_types.
    -- --:: module "name": T  declares the type returned by require("name").
    for _, r in ipairs(module_decls) do
        ctx.module_types[r.mod_name] = resolve(ctx, r.type_id)
    end

    -- Pass 4: apply --:: augment Name { ... } declarations.
    -- Mirrors constrain.lua Pass 2c: merges fields into existing value bindings or type aliases.
    -- Required because stdlib_types.lua uses --:: augment for library table globals.
    if #augment_decls > 1 then
        local al = augment_decl_lines
        table.sort(augment_decls, function(a, b) return (al[a] or 0) < (al[b] or 0) end)
    end
    for _, r in ipairs(augment_decls) do
        local aug_tid = resolve(ctx, r.type_id)
        local aug_t = ctx.types:get(types_mod.find(ctx, aug_tid))
        if aug_t.tag == defs_mod.TAG_TABLE then
            -- Determine prim_tag for prim_index updates.
            local name_str = intern_mod.get(ctx.pool, r.name_id) or ""
            local prim_tag = nil
            if name_str == "string"  then prim_tag = defs_mod.TAG_STRING
            elseif name_str == "number"  then prim_tag = defs_mod.TAG_NUMBER
            elseif name_str == "integer" then prim_tag = defs_mod.TAG_INTEGER
            elseif name_str == "boolean" then prim_tag = defs_mod.TAG_BOOLEAN
            end

            -- Collect new fields and meta fields from the augment table.
            local new_field_ids = {}
            local new_meta_field_ids = {}
            for i = aug_t.data[0], aug_t.data[0] + aug_t.data[1] - 1 do
                new_field_ids[#new_field_ids + 1] = ctx.lists:get(i)
            end
            for i = aug_t.data[5], aug_t.data[5] + aug_t.data[6] - 1 do
                new_meta_field_ids[#new_meta_field_ids + 1] = ctx.lists:get(i)
            end

            -- Merge new fields into an existing TAG_TABLE base.
            local function merge_into_table(base_tid)
                local bt = ctx.types:get(types_mod.find(ctx, base_tid))
                if bt.tag ~= defs_mod.TAG_TABLE then
                    return types_mod.make_table(ctx, new_field_ids, {}, -1, new_meta_field_ids)
                end
                local fs, fl = bt.data[0], bt.data[1]
                local is2, il = bt.data[2], bt.data[3]
                local rv = bt.data[4]
                local ms, ml = bt.data[5], bt.data[6]
                local merged = {}
                local name_pos = {}
                for i = fs, fs + fl - 1 do
                    local fid = ctx.lists:get(i)
                    local fe  = ctx.fields:get(fid)
                    if fe.name_id >= 0 then name_pos[fe.name_id] = #merged + 1 end
                    merged[#merged + 1] = fid
                end
                for _, fid in ipairs(new_field_ids) do
                    local fe = ctx.fields:get(fid)
                    if fe.name_id >= 0 and name_pos[fe.name_id] then
                        merged[name_pos[fe.name_id]] = fid
                    else
                        if fe.name_id >= 0 then name_pos[fe.name_id] = #merged + 1 end
                        merged[#merged + 1] = fid
                    end
                end
                local merged_meta = {}
                local meta_name_pos = {}
                for i = ms, ms + ml - 1 do
                    local fid = ctx.lists:get(i)
                    local fe  = ctx.fields:get(fid)
                    if fe.name_id >= 0 then meta_name_pos[fe.name_id] = #merged_meta + 1 end
                    merged_meta[#merged_meta + 1] = fid
                end
                for _, fid in ipairs(new_meta_field_ids) do
                    local fe = ctx.fields:get(fid)
                    if fe.name_id >= 0 and meta_name_pos[fe.name_id] then
                        merged_meta[meta_name_pos[fe.name_id]] = fid
                    else
                        if fe.name_id >= 0 then meta_name_pos[fe.name_id] = #merged_meta + 1 end
                        merged_meta[#merged_meta + 1] = fid
                    end
                end
                local indexers = {}
                local ix = is2
                while ix < is2 + il - 1 do
                    indexers[#indexers + 1] = ctx.lists:get(ix)
                    indexers[#indexers + 1] = ctx.lists:get(ix + 1)
                    ix = ix + 2
                end
                return types_mod.make_table(ctx, merged, indexers, rv, merged_meta)
            end

            local existing_value_tid = env_mod.lookup(ctx.scope, r.name_id)
            local existing_alias     = env_mod.lookup_type(ctx.scope, r.name_id)

            if existing_value_tid then
                local merged_tid = merge_into_table(existing_value_tid)
                env_mod.bind(ctx.scope, r.name_id, merged_tid)
                if prim_tag then ctx.prim_index[prim_tag] = merged_tid end
            elseif existing_alias then
                local base_body = existing_alias.body or types_mod.make_table(ctx, {}, {}, -1, {})
                local merged_tid = merge_into_table(base_body)
                existing_alias.body = merged_tid
                if prim_tag then
                    ctx.prim_index[prim_tag] = merged_tid
                    if aug_t.data[6] > 0 then ctx.prim_meta[prim_tag] = merged_tid end
                end
            else
                -- No existing binding: create fresh value binding from augment.
                local new_tid = types_mod.make_table(ctx, new_field_ids, {}, -1, new_meta_field_ids)
                env_mod.bind(ctx.scope, r.name_id, new_tid)
                if prim_tag then ctx.prim_index[prim_tag] = new_tid end
            end
        end
    end

    ctx.ann = saved_ann

    -- Derive ctx primitive meta type fields from the loaded type aliases.
    local function get_alias(name)
        local nid = intern_mod.intern(ctx.pool, name)
        local alias = env_mod.lookup_type(ctx.scope, nid)
        return alias and alias.body
    end

    local function get_var(name)
        local nid = intern_mod.intern(ctx.pool, name)
        return env_mod.lookup(ctx.scope, nid)
    end

    ctx.string_meta_tid = get_var("string") or ctx.string_meta_tid

    -- Populate prim_meta: TAG_* → operator metamethods table TID.
    -- Also populate prim_index: TAG_* → __index table TID (method dispatch).
    local num_meta  = get_alias("number_meta")
    local int_meta  = get_alias("integer_meta")
    local str_ops   = get_alias("string_meta_ops")
    if num_meta  then ctx.prim_meta[defs_mod.TAG_NUMBER]  = num_meta  end
    if int_meta  then ctx.prim_meta[defs_mod.TAG_INTEGER] = int_meta  end
    if str_ops   then ctx.prim_meta[defs_mod.TAG_STRING]  = str_ops   end
    if ctx.string_meta_tid then
        ctx.prim_index[defs_mod.TAG_STRING] = ctx.string_meta_tid
    end
end

-- Synthesize the $GlobalScope type: a closed TAG_TABLE whose named fields mirror
-- the current root scope.  No fallback indexer — accessing an undeclared key on
-- _G is the same error as accessing an undeclared global.
--
-- Must be called AFTER load_decls so that all stdlib (and optionally checker)
-- bindings are already in scope.  Pre-register the $GlobalScope alias before
-- load_decls and call this function after; it patches the alias body and
-- re-binds _G so the declaration in stdlib_types.lua resolves correctly.
local function synthesize_G(ctx)
    local types_mod = require("lib.type.static.types")

    -- Walk to root scope frame (holds the stdlib bindings we just loaded).
    local root = ctx.scope
    while root.parent do root = root.parent end

    local field_ids = {}
    for name_id, type_id in pairs(root.bindings) do
        local fid = types_mod.make_field(ctx, name_id, types_mod.find(ctx, type_id), false)
        field_ids[#field_ids + 1] = fid
    end

    -- No fallback indexer: _G is the exact global scope, nothing more.
    local g_tid = types_mod.make_table(ctx, field_ids, {}, -1, {})

    -- Patch the pre-registered $GlobalScope alias so that $GlobalScope resolves
    -- to this type everywhere (including the --:: declare _G = $GlobalScope in
    -- stdlib_types.lua that was already processed with a placeholder body).
    local gs_name_id = intern_mod.intern(ctx.pool, "GlobalScope")
    local alias = env_mod.lookup_type(ctx.scope, gs_name_id)
    if alias then alias.body = g_tid end

    -- Re-bind _G to the synthesized type (overwrites the placeholder T_ANY that
    -- load_decls installed when it processed --:: declare _G = $GlobalScope).
    local g_name_id = intern_mod.intern(ctx.pool, "_G")
    env_mod.bind(ctx.scope, g_name_id, g_tid)
end

-- Pre-register the $GlobalScope type alias with a T_ANY placeholder so that
-- --:: declare _G = $GlobalScope in stdlib_types.lua can resolve without error.
-- synthesize_G() patches this alias body with the real type after load_decls.
local function prereq_G(ctx)
    local gs_name_id = intern_mod.intern(ctx.pool, "GlobalScope")
    env_mod.bind_type(ctx.scope, gs_name_id, { body = ctx.T_ANY, params = nil })
end

-- Expose load_decls for external callers (e.g. populate_from_files).
-- path must be an absolute or relative path to a _types.lua declaration file.
M.load_decls = load_decls

-- Populate ctx.scope from a list of file paths (absolute or relative).
-- Each file is loaded via load_decls. prereq_G and synthesize_G are handled
-- by the caller (populate or populate_checker) if _G synthesis is needed.
function M.populate_from_files(ctx, paths, with_G)
    if with_G then prereq_G(ctx) end
    for _, path in ipairs(paths) do
        load_decls(ctx, path)
    end
    if with_G then synthesize_G(ctx) end
end

-- Populate ctx.scope with Lua 5.1 / LuaJIT stdlib bindings.
-- Only loads stdlib_types.lua — does NOT load ctx_types.lua.
-- ctx_types.lua declares typechecker-internal functions and must not appear in
-- user-file scope; use populate_checker() for self-checking typechecker sources.
function M.populate(ctx)
    local src_path = debug.getinfo(1, "S").source:gsub("^@", "")
    local dir = src_path:match("^(.+/)[^/]+$") or "./"
    prereq_G(ctx)
    load_decls(ctx, dir .. "stdlib_types.lua")
    synthesize_G(ctx)
end

-- Populate ctx.scope with stdlib AND typechecker-internal declarations (ctx_types.lua).
-- Use this only when checking typechecker source files themselves, so that
-- internal functions like `report`, `infer_expr_multi`, etc. are in scope.
-- Re-synthesizes _G after loading ctx_types.lua so that checker-internal names are
-- also reachable via _G when self-checking.
function M.populate_checker(ctx)
    local src_path = debug.getinfo(1, "S").source:gsub("^@", "")
    local dir = src_path:match("^(.+/)[^/]+$") or "./"
    prereq_G(ctx)
    load_decls(ctx, dir .. "stdlib_types.lua")
    load_decls(ctx, dir .. "ctx_types.lua")
    synthesize_G(ctx)
end

return M
