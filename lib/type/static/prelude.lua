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
-- Call M.clear_cache() to force re-parsing (e.g. if stdlib .d.lua files
-- change at runtime, which should not happen in normal usage).
local _cache = {}   -- path → { ar, strings, first_id }

function M.clear_cache()
    _cache = {}
end

-- Parse a .d.lua declaration file and populate ctx.scope.
-- Uses the annotation pipeline.
-- Variable declarations (--:: declare name = type) are bound in ctx.scope.
-- Type aliases (--:: Name = type) are registered in ctx.scope.type_bindings.
-- After loading, primitive meta type ctx fields are derived from aliases.
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

    -- Collect all ANN_DECL results.
    local decls = {}
    for _, r in pairs(ar.results) do
        if r.kind == defs_mod.ANN_DECL then
            decls[#decls + 1] = r
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

    -- Pass 2: resolve all type bodies and bind.
    local types_mod = require("lib.type.static.types")
    for _, r in ipairs(decls) do
        if r.decl_var then
            env_mod.bind(ctx.scope, r.name_id, resolve(ctx, r.type_id))
        elseif r.newtype then
            -- Newtype: resolve underlying type, assign a unique nominal identity.
            -- ann.lua stores data[1]=0 for all newtypes; without a unique identity
            -- all newtypes would unify with each other (identity-based equality).
            local ann_nom = ctx.ann.types:get(r.type_id)
            local underlying = resolve(ctx, ann_nom.data[2])
            ctx.nominal_id = ctx.nominal_id + 1
            local nom = types_mod.make_nominal(ctx, r.name_id, ctx.nominal_id, underlying)
            local alias = env_mod.lookup_type(ctx.scope, r.name_id)
            if alias then alias.body = nom end
        else
            local resolved = resolve(ctx, r.type_id)
            local alias = env_mod.lookup_type(ctx.scope, r.name_id)
            if alias then alias.body = resolved end
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

-- Populate ctx.scope with Lua 5.1 / LuaJIT stdlib bindings.
function M.populate(ctx)
    -- Load all stdlib declarations from the companion .d.lua files.
    local src_path = debug.getinfo(1, "S").source:gsub("^@", "")
    local dir = src_path:match("^(.+/)[^/]+$") or "./"
    load_decls(ctx, dir .. "stdlib.d.lua")
    load_decls(ctx, dir .. "ctx.d.lua")
end

return M
