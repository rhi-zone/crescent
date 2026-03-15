-- lib/type/static/prelude.lua
-- Lua 5.1 / LuaJIT stdlib type bindings for the typechecker.
-- Call M.populate(ctx) after creating a checker context to add stdlib types
-- to ctx.scope. Types are allocated into ctx's own arena so IDs are valid.

local intern_mod = require("lib.type.static.intern")
local env_mod    = require("lib.type.static.env")
local defs_mod   = require("lib.type.static.defs")

local M = {}

-- Module-level source cache: path → source string.
--
-- Caches the raw file contents so that subsequent populate() calls skip
-- file I/O.  parse_mod.parse and ann_mod.parse_annotations are still called
-- on every populate() so that intern IDs are always assigned into the current
-- pool — intern is idempotent, so calling it multiple times with the same
-- strings on the same pool is free.
--
-- INVARIANT: infer.check_string calls populate() BEFORE parsing the user
-- source, so the pool contains only pre-seeded keywords (IDs 0–21) at the
-- start of the first populate() call on a fresh pool.  Because intern is
-- idempotent, re-parsing the stdlib files on a reused pool simply confirms
-- the same IDs that were already assigned.
--
-- Call M.clear_cache() if the stdlib .d.lua files change at runtime.
local _source_cache = {}   -- path → source string

function M.clear_cache()
    _source_cache = {}
end

-- Parse a .d.lua declaration file and populate ctx.scope.
-- Uses the + annotation pipeline.
-- Variable declarations (--:: declare name = type) are bound in ctx.scope.
-- Type aliases (--:: Name = type) are registered in ctx.scope.type_bindings.
-- After loading, primitive meta type ctx fields are derived from aliases.
local function load_decls(ctx, path)
    local parse_mod  = require("lib.type.static.parse")
    local ann_mod    = require("lib.type.static.ann")
    local infer_mod  = require("lib.type.static.infer")

    -- Cache the source string to skip file I/O on subsequent calls.
    local source = _source_cache[path]
    if not source then
        local f = io.open(path, "r")
        if not f then return end
        source = f:read("*a")
        f:close()
        _source_cache[path] = source
    end

    local ok_p, pr = pcall(parse_mod.parse, source, path, ctx.pool)
    if not ok_p then return end

    local ok_a, ar = pcall(ann_mod.parse_annotations, pr.lexer.annotations, ctx.pool, path)
    if not ok_a then return end

    -- Temporarily attach annotation arenas so resolve_annotation_type can read them.
    local saved_ann = ctx.ann
    ctx.ann = ar

    local resolve = infer_mod.resolve_annotation_type

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
