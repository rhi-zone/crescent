-- lib/type/static/v2/prelude.lua
-- Lua 5.1 / LuaJIT stdlib type bindings for the v2 typechecker.
-- Call M.populate(ctx) after creating a checker context to add stdlib types
-- to ctx.scope. Types are allocated into ctx's own arena so IDs are valid.

local intern_mod = require("lib.type.static.v2.intern")
local types_mod  = require("lib.type.static.v2.types")
local env_mod    = require("lib.type.static.v2.env")
local defs_mod   = require("lib.type.static.v2.defs")

local M = {}

-- Parse a .d.lua declaration file and populate ctx.scope.
-- Uses the v2 parse + annotation pipeline.
-- Variable declarations (--:: declare name = type) are bound in ctx.scope.
-- Type aliases (--:: Name = type) are registered in ctx.scope.type_bindings.
-- After loading, primitive meta type ctx fields are derived from aliases.
local function load_decls(ctx, path)
    local f = io.open(path, "r")
    if not f then return end
    local source = f:read("*a")
    f:close()

    local parse_mod  = require("lib.type.static.v2.parse")
    local ann_mod    = require("lib.type.static.v2.ann")
    local infer_mod  = require("lib.type.static.v2.infer")

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
    for _, r in ipairs(decls) do
        local resolved = resolve(ctx, r.type_id)
        if r.decl_var then
            env_mod.bind(ctx.scope, r.name_id, resolved)
        else
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

    ctx.number_meta_tid     = get_alias("number_meta")     or ctx.number_meta_tid
    ctx.integer_meta_tid    = get_alias("integer_meta")    or ctx.integer_meta_tid
    ctx.string_meta_ops_tid = get_alias("string_meta_ops") or ctx.string_meta_ops_tid
    ctx.string_meta_tid     = get_var("string")            or ctx.string_meta_tid
end

-- Populate ctx.scope with Lua 5.1 / LuaJIT stdlib bindings.
function M.populate(ctx)
    -- Load all stdlib declarations from the companion .d.lua file.
    local src_path = debug.getinfo(1, "S").source:gsub("^@", "")
    local dir = src_path:match("^(.+/)[^/]+$") or "./"
    load_decls(ctx, dir .. "stdlib.d.lua")

    -- _G: open table — requires a row variable, not expressible in annotation syntax.
    local rv = types_mod.make_rowvar(ctx, 0)
    local g_name_id = intern_mod.intern(ctx.pool, "_G")
    env_mod.bind(ctx.scope, g_name_id, types_mod.make_table(ctx, {}, {}, rv, {}))
end

return M
