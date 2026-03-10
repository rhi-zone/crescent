-- lib/type/static/env.lua
-- Scope management for the typechecker.
-- Scopes are linked Lua tables. Identifiers are intern IDs (integers).
-- Type aliases are stored separately from value bindings.

local defs = require("lib.type.static.defs")
local types_mod = require("lib.type.static.types")

local TAG_VAR          = defs.TAG_VAR
local TAG_ROWVAR       = defs.TAG_ROWVAR
local TAG_FUNCTION     = defs.TAG_FUNCTION
local TAG_TABLE        = defs.TAG_TABLE
local TAG_UNION        = defs.TAG_UNION
local TAG_INTERSECTION = defs.TAG_INTERSECTION
local TAG_TUPLE        = defs.TAG_TUPLE
local TAG_SPREAD       = defs.TAG_SPREAD
local FLAG_GENERIC     = defs.FLAG_GENERIC

local M = {}

-- Create a root scope at the given level.
function M.new(level)
    return {
        bindings      = {},  -- [name_id] -> type_id
        type_bindings = {},  -- [name_id] -> { body=type_id, params={name_id,...} | nil, nominal=bool }
        parent        = nil,
        level         = level or 0,
    }
end

-- Create a child scope inheriting from parent.
function M.child(parent)
    return {
        bindings      = {},
        type_bindings = {},
        parent        = parent,
        level         = parent.level + 1,
    }
end

-- Bind a name (intern ID) to a type_id in the given scope.
function M.bind(scope, name_id, type_id)
    scope.bindings[name_id] = type_id
end

-- Bind a type alias in the given scope.
-- alias: { body=type_id, params={name_id,...}|nil, nominal=bool }
function M.bind_type(scope, name_id, alias)
    scope.type_bindings[name_id] = alias
end

-- Look up a name (intern ID) up the scope chain.
-- Returns type_id or nil.
function M.lookup(scope, name_id)
    local s = scope
    while s do
        local ty = s.bindings[name_id]
        if ty ~= nil then return ty end
        s = s.parent
    end
    return nil
end

-- Look up the declared type of a name, skipping narrowing-derived bindings.
-- Narrowing scopes (created by apply_narrowed) record which names are narrowed
-- in the `narrowed_names` table. This function skips those entries to find
-- the type as declared/assigned before narrowing.
-- Returns type_id or nil.
function M.lookup_declared(scope, name_id)
    local s = scope
    while s do
        local ty = s.bindings[name_id]
        if ty ~= nil then
            -- If this binding is narrowing-derived, skip it
            if not (s.narrowed_names and s.narrowed_names[name_id]) then
                return ty
            end
        end
        s = s.parent
    end
    return nil
end

-- Look up a type alias up the scope chain.
-- Returns alias entry or nil.
function M.lookup_type(scope, name_id)
    local s = scope
    while s do
        local alias = s.type_bindings[name_id]
        if alias ~= nil then return alias end
        s = s.parent
    end
    return nil
end

---------------------------------------------------------------------------
-- Generalize / Instantiate
---------------------------------------------------------------------------

-- Walk a type graph and mark free vars at level > `level` as generic.
-- This is done in-place (mutates the TypeSlot flags).
-- seen: set of type_ids to prevent cycles
local function generalize_inner(ctx, tid, level, seen)
    tid = types_mod.find(ctx, tid)
    if seen[tid] then return end
    seen[tid] = true

    local t = ctx.types:get(tid)
    local tag = t.tag

    if tag == TAG_VAR or tag == TAG_ROWVAR then
        if t.data[1] > level then
            t.flags = FLAG_GENERIC
        end
        return
    end

    if tag == TAG_FUNCTION then
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            generalize_inner(ctx, ctx.lists:get(i), level, seen)
        end
        for i = t.data[2], t.data[2] + t.data[3] - 1 do
            generalize_inner(ctx, ctx.lists:get(i), level, seen)
        end
        if t.data[4] >= 0 then
            generalize_inner(ctx, t.data[4], level, seen)
        end
        return
    end

    if tag == TAG_TABLE then
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            local fe = ctx.fields:get(ctx.lists:get(i))
            generalize_inner(ctx, fe.type_id, level, seen)
        end
        local is, il = t.data[2], t.data[3]
        for i = is, is + il - 1 do
            generalize_inner(ctx, ctx.lists:get(i), level, seen)
        end
        for i = t.data[5], t.data[5] + t.data[6] - 1 do
            local fe = ctx.fields:get(ctx.lists:get(i))
            generalize_inner(ctx, fe.type_id, level, seen)
        end
        return
    end

    if tag == TAG_UNION or tag == TAG_INTERSECTION or tag == TAG_TUPLE then
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            generalize_inner(ctx, ctx.lists:get(i), level, seen)
        end
        return
    end

    if tag == TAG_SPREAD then
        generalize_inner(ctx, t.data[0], level, seen)
        return
    end
end

-- Generalize: mark free vars above level as generic (for let-polymorphism).
function M.generalize(ctx, tid, level)
    generalize_inner(ctx, tid, level, {})
end

-- Instantiate: deep-copy a type, replacing generic vars with fresh vars.
-- mapping: { var_type_id -> fresh_var_type_id } (shared across recursion)
-- seen: { type_id -> copied_type_id } (cycle detection for circular tables)
local function instantiate_inner(ctx, tid, level, mapping, seen)
    tid = types_mod.find(ctx, tid)

    local t = ctx.types:get(tid)
    local tag = t.tag

    if tag == TAG_VAR or tag == TAG_ROWVAR then
        if t.flags == FLAG_GENERIC then
            if not mapping[tid] then
                if tag == TAG_VAR then
                    mapping[tid] = types_mod.make_var(ctx, level)
                else
                    mapping[tid] = types_mod.make_rowvar(ctx, level)
                end
            end
            return mapping[tid]
        end
        return tid
    end

    if tag == TAG_FUNCTION then
        local params = {}
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            params[#params + 1] = instantiate_inner(ctx, ctx.lists:get(i), level, mapping, seen)
        end
        local returns = {}
        for i = t.data[2], t.data[2] + t.data[3] - 1 do
            returns[#returns + 1] = instantiate_inner(ctx, ctx.lists:get(i), level, mapping, seen)
        end
        local vararg_id = t.data[4]
        if vararg_id >= 0 then
            vararg_id = instantiate_inner(ctx, vararg_id, level, mapping, seen)
        end
        local param_name_ids = nil
        if t.data[6] > 0 then
            param_name_ids = {}
            for i = t.data[5], t.data[5] + t.data[6] - 1 do
                param_name_ids[#param_name_ids + 1] = ctx.lists:get(i)
            end
        end
        return types_mod.make_func(ctx, params, returns, vararg_id, param_name_ids)
    end

    if tag == TAG_TABLE then
        if seen[tid] then return seen[tid] end
        -- Pre-register to handle cycles
        local result_id = types_mod.make_table(ctx, {}, {}, -1, {})
        seen[tid] = result_id

        -- Now build the actual fields
        local new_field_ids = {}
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            local fid = ctx.lists:get(i)
            local fe = ctx.fields:get(fid)
            local new_type = instantiate_inner(ctx, fe.type_id, level, mapping, seen)
            new_field_ids[#new_field_ids + 1] = types_mod.make_field(ctx, fe.name_id, new_type, fe.optional == 1)
        end

        local new_indexers = {}
        local is, il = t.data[2], t.data[3]
        local i = is
        while i < is + il - 1 do
            new_indexers[#new_indexers + 1] = instantiate_inner(ctx, ctx.lists:get(i), level, mapping, seen)
            new_indexers[#new_indexers + 1] = instantiate_inner(ctx, ctx.lists:get(i + 1), level, mapping, seen)
            i = i + 2
        end

        local new_meta = {}
        for j = t.data[5], t.data[5] + t.data[6] - 1 do
            local fid = ctx.lists:get(j)
            local fe = ctx.fields:get(fid)
            local new_type = instantiate_inner(ctx, fe.type_id, level, mapping, seen)
            new_meta[#new_meta + 1] = types_mod.make_field(ctx, fe.name_id, new_type, fe.optional == 1)
        end

        local row_var = t.data[4]
        if row_var >= 0 then
            row_var = instantiate_inner(ctx, row_var, level, mapping, seen)
        end

        -- Rebuild the result table with actual data
        -- (can't modify in-place after make_table since lists are immutable)
        -- Just overwrite the result_id's data
        local rt = ctx.types:get(result_id)
        -- We need to re-allocate: make_table appended to the list pool.
        -- It's simpler to just re-create, but the cycle dict already points to result_id.
        -- Solution: write fields into the result TypeSlot directly after creating them.
        local new_result = types_mod.make_table(ctx, new_field_ids, new_indexers, row_var, new_meta)
        -- Copy new_result data into result_id
        local nrt = ctx.types:get(new_result)
        local rrt = ctx.types:get(result_id)
        for k = 0, 6 do rrt.data[k] = nrt.data[k] end
        -- result_id now has correct data; new_result is orphaned (harmless)
        seen[tid] = nil  -- clean up
        return result_id
    end

    if tag == TAG_UNION then
        local members = {}
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            members[#members + 1] = instantiate_inner(ctx, ctx.lists:get(i), level, mapping, seen)
        end
        return types_mod.make_union(ctx, members)
    end

    if tag == TAG_INTERSECTION then
        local members = {}
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            members[#members + 1] = instantiate_inner(ctx, ctx.lists:get(i), level, mapping, seen)
        end
        return types_mod.make_intersection(ctx, members)
    end

    if tag == TAG_TUPLE then
        local elems = {}
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            elems[#elems + 1] = instantiate_inner(ctx, ctx.lists:get(i), level, mapping, seen)
        end
        return types_mod.make_tuple(ctx, elems)
    end

    if tag == TAG_SPREAD then
        local inner = instantiate_inner(ctx, t.data[0], level, mapping, seen)
        local id = types_mod.alloc_type(ctx, defs.TAG_SPREAD)
        ctx.types:get(id).data[0] = inner
        return id
    end

    return tid
end

-- Instantiate: replace generic vars with fresh vars at current level.
function M.instantiate(ctx, tid, level)
    return instantiate_inner(ctx, tid, level, {}, {})
end

-- Substitute: replace TAG_NAMED references matching mapping keys.
-- mapping: { [name_id] -> type_id }
local function substitute_inner(ctx, tid, mapping, seen)
    tid = types_mod.find(ctx, tid)
    if seen[tid] then return tid end
    seen[tid] = true

    local t = ctx.types:get(tid)
    local tag = t.tag

    if tag == TAG_VAR or tag == TAG_ROWVAR then
        seen[tid] = nil
        return tid
    end

    -- TAG_NAMED: check if name matches a substitution
    if tag == defs.TAG_NAMED then
        local name_id = t.data[0]
        local repl = mapping[name_id]
        if repl ~= nil and t.data[2] == 0 then  -- no args
            seen[tid] = nil
            return repl
        end
        seen[tid] = nil
        return tid
    end

    if tag == TAG_FUNCTION then
        local params = {}
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            params[#params + 1] = substitute_inner(ctx, ctx.lists:get(i), mapping, seen)
        end
        local returns = {}
        for i = t.data[2], t.data[2] + t.data[3] - 1 do
            returns[#returns + 1] = substitute_inner(ctx, ctx.lists:get(i), mapping, seen)
        end
        local vararg_id = t.data[4]
        if vararg_id >= 0 then
            vararg_id = substitute_inner(ctx, vararg_id, mapping, seen)
        end
        local param_name_ids = nil
        if t.data[6] > 0 then
            param_name_ids = {}
            for i = t.data[5], t.data[5] + t.data[6] - 1 do
                param_name_ids[#param_name_ids + 1] = ctx.lists:get(i)
            end
        end
        seen[tid] = nil
        return types_mod.make_func(ctx, params, returns, vararg_id, param_name_ids)
    end

    if tag == TAG_TABLE then
        local new_field_ids = {}
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            local fid = ctx.lists:get(i)
            local fe = ctx.fields:get(fid)
            local new_type = substitute_inner(ctx, fe.type_id, mapping, seen)
            new_field_ids[#new_field_ids + 1] = types_mod.make_field(ctx, fe.name_id, new_type, fe.optional == 1)
        end
        local new_indexers = {}
        local is, il = t.data[2], t.data[3]
        local i = is
        while i < is + il - 1 do
            new_indexers[#new_indexers + 1] = substitute_inner(ctx, ctx.lists:get(i), mapping, seen)
            new_indexers[#new_indexers + 1] = substitute_inner(ctx, ctx.lists:get(i + 1), mapping, seen)
            i = i + 2
        end
        local new_meta = {}
        for j = t.data[5], t.data[5] + t.data[6] - 1 do
            local fid = ctx.lists:get(j)
            local fe = ctx.fields:get(fid)
            local new_type = substitute_inner(ctx, fe.type_id, mapping, seen)
            new_meta[#new_meta + 1] = types_mod.make_field(ctx, fe.name_id, new_type, fe.optional == 1)
        end
        seen[tid] = nil
        return types_mod.make_table(ctx, new_field_ids, new_indexers, t.data[4], new_meta)
    end

    if tag == TAG_UNION then
        local members = {}
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            members[#members + 1] = substitute_inner(ctx, ctx.lists:get(i), mapping, seen)
        end
        seen[tid] = nil
        return types_mod.make_union(ctx, members)
    end

    if tag == TAG_INTERSECTION then
        local members = {}
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            members[#members + 1] = substitute_inner(ctx, ctx.lists:get(i), mapping, seen)
        end
        seen[tid] = nil
        return types_mod.make_intersection(ctx, members)
    end

    if tag == TAG_TUPLE then
        local elems = {}
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            elems[#elems + 1] = substitute_inner(ctx, ctx.lists:get(i), mapping, seen)
        end
        seen[tid] = nil
        return types_mod.make_tuple(ctx, elems)
    end

    if tag == TAG_SPREAD then
        local inner = substitute_inner(ctx, t.data[0], mapping, seen)
        seen[tid] = nil
        local id = types_mod.alloc_type(ctx, defs.TAG_SPREAD)
        ctx.types:get(id).data[0] = inner
        return id
    end

    seen[tid] = nil
    return tid
end

-- Substitute named type refs in a type.
-- mapping: { [name_id] -> type_id }
function M.substitute(ctx, tid, mapping)
    return substitute_inner(ctx, tid, mapping, {})
end

-- Resolve a named type alias: look up in scope, apply type args.
-- Returns (resolved_type_id, nil) or (nil, error_message).
function M.resolve_named_type(ctx, scope, name_id, arg_ids)
    local alias = M.lookup_type(scope, name_id)
    if not alias then
        local name = require("lib.type.static.intern").get(ctx.pool, name_id) or "?"
        return nil, "undefined type '" .. name .. "'"
    end

    -- Simple alias (no params)
    if not alias.params or #alias.params == 0 then
        if arg_ids and #arg_ids > 0 then
            local name = require("lib.type.static.intern").get(ctx.pool, name_id) or "?"
            return nil, "type '" .. name .. "' does not take type arguments"
        end
        return alias.body
    end

    -- Generic alias: check arity
    if not arg_ids or #arg_ids ~= #alias.params then
        local name = require("lib.type.static.intern").get(ctx.pool, name_id) or "?"
        local expected = #alias.params
        local got = arg_ids and #arg_ids or 0
        return nil, "type '" .. name .. "' expects " .. expected .. " argument(s), got " .. got
    end

    -- Build substitution mapping
    local mapping = {}
    for i = 1, #alias.params do
        mapping[alias.params[i]] = arg_ids[i]
    end
    return M.substitute(ctx, alias.body, mapping)
end

return M
