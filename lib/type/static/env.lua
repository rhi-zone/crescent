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
local FLAG_OPTIONAL    = defs.FLAG_OPTIONAL
local band             = bit.band

local M = {}

-- Create a root scope at the given level.
--: (integer | nil) -> Scope
function M.new(level)
    return {
        bindings         = {},  -- [name_id] -> type_id
        type_bindings    = {},  -- [name_id] -> { body=type_id, params={name_id,...} | nil, nominal=bool }
        annotation_types = {},  -- [name_id] -> type_id (declared annotation, permanent type for variable)
        parent           = nil,
        level            = level or 0,
        narrowed_names   = nil,
    }
end

-- Create a child scope inheriting from parent.
--: (Scope) -> Scope
function M.child(parent)
    return {
        bindings         = {},
        type_bindings    = {},
        annotation_types = {},
        parent           = parent,
        level            = parent.level + 1,
        narrowed_names   = nil,
    }
end

-- Bind a name (intern ID) to a type_id in the given scope.
function M.bind(scope, name_id, type_id)
    scope.bindings[name_id] = type_id
    -- If this scope is a narrowed scope and we're overwriting a narrowed binding with a
    -- real assignment, clear the narrowing flag so branch_scope_diff picks it up correctly.
    if scope.narrowed_names and scope.narrowed_names[name_id] then
        scope.narrowed_names[name_id] = nil
    end
end

-- Bind a type alias in the given scope.
-- alias: { body=type_id, params={name_id,...}|nil, nominal=bool }
function M.bind_type(scope, name_id, alias)
    scope.type_bindings[name_id] = alias
end

-- Record the explicit annotation type for a variable (permanent declared type).
-- Assignments to this variable check rhs <: annotation_type rather than rebinding.
function M.bind_annotation(scope, name_id, type_id)
    scope.annotation_types[name_id] = type_id
end

-- Look up the annotation type for a variable up the scope chain.
-- Returns type_id or nil if the variable has no explicit annotation.
function M.lookup_annotation(scope, name_id)
    local s = scope
    while s do
        if s.annotation_types then
            local ty = s.annotation_types[name_id]
            if ty ~= nil then return ty end
        end
        s = s.parent
    end
    return nil
end

-- Look up a name (intern ID) up the scope chain.
-- Returns type_id or nil.
--: (Scope, integer) -> integer | nil
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
--: (Ctx, integer, integer, { [integer]: boolean, ... }) -> ()
local function generalize_inner(ctx, tid, level, seen)
    tid = types_mod.find(ctx, tid)
    if seen[tid] then return end
    seen[tid] = true

    local t = ctx.types:get(tid)
    local tag = t.tag

    if tag == TAG_VAR or tag == TAG_ROWVAR then
        if types_mod.var_level(t) > level then
            t.flags = FLAG_GENERIC
        end
        return
    end

    if tag == TAG_FUNCTION then
        local ps, pl = types_mod.fn_params_start(t), types_mod.fn_params_len(t)
        for i = ps, ps + pl - 1 do
            generalize_inner(ctx, ctx.lists:get(i), level, seen)
        end
        local rs, rl = types_mod.fn_returns_start(t), types_mod.fn_returns_len(t)
        for i = rs, rs + rl - 1 do
            generalize_inner(ctx, ctx.lists:get(i), level, seen)
        end
        local va = types_mod.fn_vararg(t)
        if va >= 0 then
            generalize_inner(ctx, va, level, seen)
        end
        return
    end

    if tag == TAG_TABLE then
        local fs, fl = types_mod.tbl_fields_start(t), types_mod.tbl_fields_len(t)
        for i = fs, fs + fl - 1 do
            local fe = ctx.fields:get(ctx.lists:get(i))
            generalize_inner(ctx, fe.type_id, level, seen)
        end
        local is, il = types_mod.tbl_indexers_start(t), types_mod.tbl_indexers_len(t)
        for i = is, is + il - 1 do
            generalize_inner(ctx, ctx.lists:get(i), level, seen)
        end
        local ms, ml = types_mod.tbl_meta_start(t), types_mod.tbl_meta_len(t)
        for i = ms, ms + ml - 1 do
            local fe = ctx.fields:get(ctx.lists:get(i))
            generalize_inner(ctx, fe.type_id, level, seen)
        end
        return
    end

    if tag == TAG_UNION or tag == TAG_INTERSECTION or tag == TAG_TUPLE then
        local ms, ml = types_mod.agg_members_start(t), types_mod.agg_members_len(t)
        for i = ms, ms + ml - 1 do
            generalize_inner(ctx, ctx.lists:get(i), level, seen)
        end
        return
    end

    if tag == TAG_SPREAD then
        generalize_inner(ctx, types_mod.spread_inner(t), level, seen)
        return
    end

    if tag == defs.TAG_TYPE_CALL then
        generalize_inner(ctx, types_mod.tycall_callee(t), level, seen)
        local as, al = types_mod.tycall_args_start(t), types_mod.tycall_args_len(t)
        for i = as, as + al - 1 do
            generalize_inner(ctx, ctx.lists:get(i), level, seen)
        end
        return
    end
end

-- Generalize: mark free vars above level as generic (for let-polymorphism).
--: (Ctx, integer, integer) -> ()
function M.generalize(ctx, tid, level)
    generalize_inner(ctx, tid, level, {})
end

-- Check whether a type contains any generic type variable (TAG_VAR / TAG_ROWVAR
-- with FLAG_GENERIC).  Returns false immediately when a concrete leaf is reached.
-- Uses a `seen` table to break cycles (TAG_TABLE and TAG_FUNCTION can be cyclic
-- when types reference themselves through field/return-type chains).
--: (Ctx, integer, { [integer]: boolean, ... } | nil) -> boolean
local function has_generic_var(ctx, tid, seen)
    tid = types_mod.find(ctx, tid)
    local t   = ctx.types:get(tid)
    local tag = t.tag
    if tag == TAG_VAR or tag == TAG_ROWVAR then
        return t.flags == FLAG_GENERIC
    end
    seen = seen or {}
    if seen[tid] then return false end
    seen[tid] = true
    if tag == TAG_FUNCTION then
        local ps, pl = types_mod.fn_params_start(t), types_mod.fn_params_len(t)
        for i = ps, ps + pl - 1 do
            if has_generic_var(ctx, ctx.lists:get(i), seen) then return true end
        end
        local rs, rl = types_mod.fn_returns_start(t), types_mod.fn_returns_len(t)
        for i = rs, rs + rl - 1 do
            if has_generic_var(ctx, ctx.lists:get(i), seen) then return true end
        end
        local va = types_mod.fn_vararg(t)
        if va >= 0 and has_generic_var(ctx, va, seen) then return true end
        return false
    end
    if tag == TAG_TABLE then
        local fs, fl = types_mod.tbl_fields_start(t), types_mod.tbl_fields_len(t)
        for i = fs, fs + fl - 1 do
            local fe = ctx.fields:get(ctx.lists:get(i))
            if has_generic_var(ctx, fe.type_id, seen) then return true end
        end
        local rv = types_mod.tbl_row_var(t)
        if rv >= 0 and has_generic_var(ctx, rv, seen) then return true end
        local ms, ml = types_mod.tbl_meta_start(t), types_mod.tbl_meta_len(t)
        for j = ms, ms + ml - 1 do
            local fe = ctx.fields:get(ctx.lists:get(j))
            if has_generic_var(ctx, fe.type_id, seen) then return true end
        end
        return false
    end
    if tag == TAG_UNION or tag == TAG_INTERSECTION or tag == TAG_TUPLE then
        local ms, ml = types_mod.agg_members_start(t), types_mod.agg_members_len(t)
        for i = ms, ms + ml - 1 do
            if has_generic_var(ctx, ctx.lists:get(i), seen) then return true end
        end
        return false
    end
    if tag == defs.TAG_SPREAD then
        return has_generic_var(ctx, types_mod.spread_inner(t), seen)
    end
    -- TAG_TYPE_CALL: callee + args list (e.g. $Require<T>, PairsReturn<T>)
    if tag == defs.TAG_TYPE_CALL then
        if has_generic_var(ctx, types_mod.tycall_callee(t), seen) then return true end
        local as, al = types_mod.tycall_args_start(t), types_mod.tycall_args_len(t)
        for i = as, as + al - 1 do
            if has_generic_var(ctx, ctx.lists:get(i), seen) then return true end
        end
        return false
    end
    -- TAG_MATCH_TYPE: subject + arms pairs
    if tag == defs.TAG_MATCH_TYPE then
        if has_generic_var(ctx, types_mod.match_param(t), seen) then return true end
        local as, al = types_mod.match_arms_start(t), types_mod.match_arms_len(t)
        for i = as, as + al - 1 do
            if has_generic_var(ctx, ctx.lists:get(i), seen) then return true end
        end
        return false
    end
    -- TAG_INDEX_TYPE: subject + key
    if tag == defs.TAG_INDEX_TYPE then
        if has_generic_var(ctx, types_mod.index_subject(t), seen) then return true end
        if has_generic_var(ctx, types_mod.index_key(t), seen) then return true end
        return false
    end
    return false
end

-- Instantiate: deep-copy a type, replacing generic vars with fresh vars.
-- mapping: { var_type_id -> fresh_var_type_id } (shared across recursion)
-- seen: { type_id -> copied_type_id } (cycle detection for circular tables)
--: (Ctx, integer, integer, { [integer]: integer, ... }, { [integer]: integer | nil, ... }) -> integer
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

    -- Fast path: if the type contains no generic vars, return it unchanged.
    -- This avoids deep-copying large concrete types (e.g. HTMLElement) and
    -- prevents arena-invalidation crashes when copied types trigger arena growth.
    if not has_generic_var(ctx, tid, nil) then
        return tid
    end

    if tag == TAG_FUNCTION then
        local ps, pl = types_mod.fn_params_start(t), types_mod.fn_params_len(t)
        local params = {}
        for i = ps, ps + pl - 1 do
            params[#params + 1] = instantiate_inner(ctx, ctx.lists:get(i), level, mapping, seen)
        end
        local rs, rl = types_mod.fn_returns_start(t), types_mod.fn_returns_len(t)
        local returns = {}
        for i = rs, rs + rl - 1 do
            returns[#returns + 1] = instantiate_inner(ctx, ctx.lists:get(i), level, mapping, seen)
        end
        local vararg_id = types_mod.fn_vararg(t)
        if vararg_id >= 0 then
            vararg_id = instantiate_inner(ctx, vararg_id, level, mapping, seen)
        end
        local param_name_ids = nil
        local pns, pnl = types_mod.fn_param_names_start(t), types_mod.fn_param_names_len(t)
        if pnl > 0 then
            param_name_ids = {}
            for i = pns, pns + pnl - 1 do
                param_name_ids[#param_name_ids + 1] = ctx.lists:get(i)
            end
        end
        return types_mod.make_func(ctx, params, returns, vararg_id, param_name_ids)
    end

    if tag == TAG_TABLE then
        if seen[tid] then return seen[tid] or tid end
        -- Snapshot all needed type data BEFORE any arena-modifying operations.
        -- make_table / make_field / instantiate_inner can all grow ctx.types or
        -- ctx.fields, invalidating any FFI pointer previously obtained via :get().
        local fields_start   = types_mod.tbl_fields_start(t)
        local fields_len     = types_mod.tbl_fields_len(t)
        local indexers_start = types_mod.tbl_indexers_start(t)
        local indexers_len   = types_mod.tbl_indexers_len(t)
        local row_var_orig   = types_mod.tbl_row_var(t)
        local meta_start     = types_mod.tbl_meta_start(t)
        local meta_len       = types_mod.tbl_meta_len(t)

        -- Pre-register to handle cycles (make_table can grow ctx.types, invalidating t)
        local result_id = types_mod.make_table(ctx, {}, {}, -1, {})
        seen[tid] = result_id

        -- Build fields: snapshot each fe before calling instantiate_inner
        local new_field_ids = {}
        for i = fields_start, fields_start + fields_len - 1 do
            local fid = ctx.lists:get(i)
            local fe = ctx.fields:get(fid)
            -- Snapshot fe data before instantiate_inner, which can grow ctx.fields
            local fe_type_id = fe.type_id
            local fe_name_id = fe.name_id
            local fe_flags   = fe.flags
            local new_type = instantiate_inner(ctx, fe_type_id, level, mapping, seen)
            new_field_ids[#new_field_ids + 1] = types_mod.make_field(ctx, fe_name_id, new_type, band(fe_flags, defs.FLAG_OPTIONAL) ~= 0)
        end

        local new_indexers = {}
        local i = indexers_start
        while i < indexers_start + indexers_len - 1 do
            new_indexers[#new_indexers + 1] = instantiate_inner(ctx, ctx.lists:get(i), level, mapping, seen)
            new_indexers[#new_indexers + 1] = instantiate_inner(ctx, ctx.lists:get(i + 1), level, mapping, seen)
            i = i + 2
        end

        local new_meta = {}
        for j = meta_start, meta_start + meta_len - 1 do
            local fid = ctx.lists:get(j)
            local fe = ctx.fields:get(fid)
            -- Snapshot fe data before instantiate_inner, which can grow ctx.fields
            local fe_type_id = fe.type_id
            local fe_name_id = fe.name_id
            local fe_flags   = fe.flags
            if fe_name_id == -1 then
                -- Meta-spread placeholder: instantiate inner, then expand if now concrete.
                local new_sp_inner = instantiate_inner(ctx, fe_type_id, level, mapping, seen)
                local sp_t   = ctx.types:get(types_mod.find(ctx, new_sp_inner))
                local exp_id = types_mod.find(ctx, types_mod.spread_inner(sp_t))
                local exp_t  = ctx.types:get(exp_id)
                if exp_t.tag == TAG_TABLE then
                    -- Copy meta slots from the resolved type.
                    -- Snapshot exp_t bounds before the loop (make_field can grow ctx.types).
                    local exp_ms = types_mod.tbl_meta_start(exp_t)
                    local exp_ml = types_mod.tbl_meta_len(exp_t)
                    for k = exp_ms, exp_ms + exp_ml - 1 do
                        local inner_fid = ctx.lists:get(k)
                        local inner_fe  = ctx.fields:get(inner_fid)
                        -- Snapshot before make_field grows ctx.fields
                        local inner_name = inner_fe.name_id
                        local inner_type = inner_fe.type_id
                        local inner_flg  = inner_fe.flags
                        if inner_name >= 0 then
                            new_meta[#new_meta + 1] = types_mod.make_field(ctx, inner_name, inner_type, inner_flg)
                        end
                    end
                else
                    -- Still unresolved — keep placeholder
                    new_meta[#new_meta + 1] = types_mod.make_field(ctx, -1, new_sp_inner, 0)
                end
            else
                local new_type = instantiate_inner(ctx, fe_type_id, level, mapping, seen)
                new_meta[#new_meta + 1] = types_mod.make_field(ctx, fe_name_id, new_type, band(fe_flags, defs.FLAG_OPTIONAL) ~= 0)
            end
        end

        local row_var = row_var_orig
        if row_var >= 0 then
            row_var = instantiate_inner(ctx, row_var, level, mapping, seen)
        end

        -- Rebuild the result table with actual data.
        -- (can't modify in-place after make_table since lists are immutable)
        -- Just overwrite the result_id's data.
        -- We need to re-allocate: make_table appended to the list pool.
        -- It's simpler to just re-create, but the cycle dict already points to result_id.
        -- Solution: write fields into the result TypeSlot directly after creating them.
        local new_result = types_mod.make_table(ctx, new_field_ids, new_indexers, row_var, new_meta)
        -- Re-fetch both pointers after make_table (arena may have grown)
        local nrt = ctx.types:get(new_result)
        local rrt = ctx.types:get(result_id)
        -- Polymorphic clone across all 7 data slots (raw copy regardless of tag).
        -- Per migration plan §6 risk #1: not a per-tag access, no accessor applies.
        for k = 0, 6 do rrt.data[k] = nrt.data[k] end
        -- result_id now has correct data; new_result is orphaned (harmless)
        seen[tid] = nil  -- clean up
        return result_id
    end

    if tag == TAG_UNION then
        local ms, ml = types_mod.agg_members_start(t), types_mod.agg_members_len(t)
        local members = {}
        for i = ms, ms + ml - 1 do
            members[#members + 1] = instantiate_inner(ctx, ctx.lists:get(i), level, mapping, seen)
        end
        return types_mod.make_union(ctx, members)
    end

    if tag == TAG_INTERSECTION then
        local ms, ml = types_mod.agg_members_start(t), types_mod.agg_members_len(t)
        local members = {}
        for i = ms, ms + ml - 1 do
            members[#members + 1] = instantiate_inner(ctx, ctx.lists:get(i), level, mapping, seen)
        end
        return types_mod.make_intersection(ctx, members)
    end

    if tag == TAG_TUPLE then
        local ms, ml = types_mod.agg_members_start(t), types_mod.agg_members_len(t)
        local elems = {}
        for i = ms, ms + ml - 1 do
            elems[#elems + 1] = instantiate_inner(ctx, ctx.lists:get(i), level, mapping, seen)
        end
        return types_mod.make_tuple(ctx, elems)
    end

    if tag == TAG_SPREAD then
        local inner = instantiate_inner(ctx, types_mod.spread_inner(t), level, mapping, seen)
        local id = types_mod.alloc_type(ctx, defs.TAG_SPREAD)
        ctx.types:get(id).data[0] = inner
        return id
    end

    if tag == defs.TAG_TYPE_CALL then
        local callee = instantiate_inner(ctx, types_mod.tycall_callee(t), level, mapping, seen)
        local cas, cal = types_mod.tycall_args_start(t), types_mod.tycall_args_len(t)
        local new_args = {}
        for i = cas, cas + cal - 1 do
            new_args[#new_args + 1] = instantiate_inner(ctx, ctx.lists:get(i), level, mapping, seen)
        end
        local mk = ctx.lists:mark()
        for _, aid in ipairs(new_args) do ctx.lists:push(aid) end
        local as, al = ctx.lists:since(mk)
        local id = types_mod.alloc_type(ctx, defs.TAG_TYPE_CALL)
        ctx.types:get(id).data[0] = callee
        ctx.types:get(id).data[1] = as
        ctx.types:get(id).data[2] = al
        return id
    end

    -- TAG_MATCH_TYPE: instantiate the subject (param) so that generic TVs inside
    -- bound match types are replaced by their fresh TVs.  Arms are also instantiated
    -- to propagate any generic TVs that appear in result types.
    if tag == defs.TAG_MATCH_TYPE then
        local new_param = instantiate_inner(ctx, types_mod.match_param(t), level, mapping, seen)
        local new_arms = {}
        local as, al = types_mod.match_arms_start(t), types_mod.match_arms_len(t)
        local i = as
        while i < as + al - 1 do
            new_arms[#new_arms + 1] = instantiate_inner(ctx, ctx.lists:get(i),     level, mapping, seen)
            new_arms[#new_arms + 1] = instantiate_inner(ctx, ctx.lists:get(i + 1), level, mapping, seen)
            i = i + 2
        end
        local mk = ctx.lists:mark()
        for _, aid in ipairs(new_arms) do ctx.lists:push(aid) end
        local ms, ml = ctx.lists:since(mk)
        local id = types_mod.alloc_type(ctx, defs.TAG_MATCH_TYPE)
        ctx.types:get(id).data[0] = new_param
        ctx.types:get(id).data[1] = ms
        ctx.types:get(id).data[2] = ml
        return id
    end

    -- TAG_INDEX_TYPE: instantiate subject and key. Eager evaluation happens in
    -- substitute_inner once concrete types are bound.
    if tag == defs.TAG_INDEX_TYPE then
        local new_subj = instantiate_inner(ctx, types_mod.index_subject(t), level, mapping, seen)
        local new_key  = instantiate_inner(ctx, types_mod.index_key(t), level, mapping, seen)
        local id = types_mod.alloc_type(ctx, defs.TAG_INDEX_TYPE)
        local it = ctx.types:get(id)
        it.data[0] = new_subj
        it.data[1] = new_key
        return id
    end

    return tid
end

-- Instantiate: replace generic vars with fresh vars at current level.
-- Returns (result_tid, mapping) where mapping is { [orig_generic_tv_id] = fresh_tv_id }.
-- If out_mapping is provided it is used (and populated) instead of a fresh table.
--: (Ctx, integer, integer, { [integer]: integer, ... } | nil) -> (integer, { [integer]: integer, ... })
function M.instantiate(ctx, tid, level, out_mapping)
    local mapping = out_mapping or {}
    local result = instantiate_inner(ctx, tid, level, mapping, {})
    return result, mapping
end

-- Rank-N: collect FLAG_GENERIC TVs that are STRICTLY nested inside a
-- function-typed parameter/return slot of `callee_tid` and are NOT also
-- reachable from a top-level non-function slot. Returns a set
-- { [tv_id] = true, ... } of TVs that should be skolemized at the call
-- site (instead of getting fresh let-poly unification vars).
--
-- Strategy: reuse env.instantiate (which already walks the entire type
-- structure with full coverage and is accepted at baseline) to enumerate
-- every FLAG_GENERIC TV via the mapping it produces. Compute "top-level"
-- TVs by instantiating each top-level slot individually with a SEPARATE
-- mapping when that slot is not itself a TAG_FUNCTION — any TV in such a
-- mapping belongs to the callee's own quantifier. Rank-N set is the
-- difference. This piggybacks on existing walker code and adds no new
-- arena-typing baseline errors.
--
-- Only annotation-introduced FLAG_GENERIC TVs (those with a name_id in
-- data[3], set by resolve_annotation_type) qualify. HM-generalized TVs
-- (without a name) are let-poly artifacts and must be instantiated normally.
--: (Ctx, integer) -> { [integer]: boolean, ... }
function M.collect_rank_n_generics(ctx, callee_tid)
    local result = {} --: { [integer]: boolean, ... }
    callee_tid = types_mod.find(ctx, callee_tid)
    local t = ctx.types:get(callee_tid)
    if t.tag == defs.TAG_NOMINAL then
        callee_tid = types_mod.find(ctx, types_mod.nom_underlying(t))
        t = ctx.types:get(callee_tid)
    end
    if t.tag ~= TAG_FUNCTION then return result end

    -- All FLAG_GENERIC TVs reachable from the callee: instantiate to a
    -- throwaway, the mapping's keys are exactly the FLAG_GENERIC TVs we want.
    local all_map = {} --: { [integer]: integer, ... }
    M.instantiate(ctx, callee_tid, ctx.scope.level, all_map)

    -- Top-level FLAG_GENERIC TVs: walk each top slot via instantiate, but
    -- only when the slot is NOT itself a TAG_FUNCTION (nested function
    -- contributes only rank-N TVs by definition).
    local top_map = {} --: { [integer]: integer, ... }
    --: (integer) -> ()
    local function consider_top_slot(slot_tid)
        slot_tid = types_mod.find(ctx, slot_tid)
        local st = ctx.types:get(slot_tid)
        if st.tag == defs.TAG_NOMINAL then
            slot_tid = types_mod.find(ctx, types_mod.nom_underlying(st))
            st = ctx.types:get(slot_tid)
        end
        if st.tag == TAG_FUNCTION then return end
        M.instantiate(ctx, slot_tid, ctx.scope.level, top_map)
    end
    local ps, pl = types_mod.fn_params_start(t), types_mod.fn_params_len(t)
    for i = ps, ps + pl - 1 do consider_top_slot(ctx.lists:get(i)) end
    local rs, rl = types_mod.fn_returns_start(t), types_mod.fn_returns_len(t)
    for i = rs, rs + rl - 1 do consider_top_slot(ctx.lists:get(i)) end
    local va = types_mod.fn_vararg(t)
    if va >= 0 then consider_top_slot(va) end

    for orig_tv in pairs(all_map) do
        if not top_map[orig_tv] then
            local ot = ctx.types:get(orig_tv)
            if (ot.tag == TAG_VAR or ot.tag == TAG_ROWVAR)
                and ot.flags == FLAG_GENERIC
                -- Annotation-introduced FLAG_GENERIC TVs have name_id > 0;
                -- HM-generalized TVs have 0.
                and types_mod.var_skolem_name_id(ot) > 0 then
                result[orig_tv] = true
            end
        end
    end
    return result
end

-- Rank-N: skolemize annotation-introduced FLAG_GENERIC TVs reachable from
-- `ret_tid`. Used by gen_function when pushing the annotated return type
-- onto the body's return slot — rank-N in return position must be
-- skolemized so the body cannot produce a monomorphic value that silently
-- specializes the polymorphic return. Returns a fresh tid (when
-- skolemization fires) or the input tid unchanged.
--: (Ctx, integer) -> integer
function M.skolemize_return_for_rank_n(ctx, ret_tid)
    -- Probe for annotation-introduced FLAG_GENERIC TVs anywhere reachable
    -- by piggybacking on instantiate's mapping (no new walker required).
    local probe = {} --: { [integer]: integer, ... }
    M.instantiate(ctx, ret_tid, ctx.scope.level, probe)
    local has_ann_gen = false
    for tv_id in pairs(probe) do
        local nt = ctx.types:get(tv_id)
        if (nt.tag == TAG_VAR or nt.tag == TAG_ROWVAR)
            and nt.flags == FLAG_GENERIC
            and types_mod.var_skolem_name_id(nt) > 0 then
            has_ann_gen = true; break
        end
    end
    if not has_ann_gen then return ret_tid end

    local skolem_tid, mapping = M.instantiate(ctx, ret_tid, ctx.scope.level)
    for orig_tv, fresh_tv in pairs(mapping) do
        local ot = ctx.types:get(orig_tv)
        local ot_name_id = types_mod.var_skolem_name_id(ot)
        if ot_name_id > 0 then
            local ft = ctx.types:get(fresh_tv)
            ft.flags = defs.FLAG_SKOLEM
            ft.data[3] = ot_name_id
        end
    end
    return skolem_tid
end

-- Substitute: replace TAG_NAMED references matching mapping keys.
-- mapping:           { [name_id] -> type_id }
-- eval_seen:         cycle-detection set shared with match.evaluate (optional)
-- in_match_arm_subst: true while recursing into a TAG_MATCH_TYPE arm result;
--                    defers $Throw evaluation so it only fires when the arm
--                    is actually selected by match.evaluate (replaces former
--                    ctx._in_match_arm_subst channel field, item 4d).
--: (Ctx, integer, { [integer]: integer, ... }, { [integer]: boolean | nil, ... }, { [integer]: boolean, ... } | nil, boolean | nil) -> integer
local function substitute_inner(ctx, tid, mapping, seen, eval_seen, in_match_arm_subst)
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
        local name_id = types_mod.named_name_id(t)
        local repl = mapping[name_id]
        if repl ~= nil and types_mod.named_args_len(t) == 0 then  -- no args
            seen[tid] = nil
            return repl
        end
        seen[tid] = nil
        return tid
    end

    if tag == TAG_FUNCTION then
        local ps, pl = types_mod.fn_params_start(t), types_mod.fn_params_len(t)
        local params = {}
        for i = ps, ps + pl - 1 do
            params[#params + 1] = substitute_inner(ctx, ctx.lists:get(i), mapping, seen, eval_seen, in_match_arm_subst)
        end
        local rs, rl = types_mod.fn_returns_start(t), types_mod.fn_returns_len(t)
        local returns = {}
        for i = rs, rs + rl - 1 do
            returns[#returns + 1] = substitute_inner(ctx, ctx.lists:get(i), mapping, seen, eval_seen, in_match_arm_subst)
        end
        local vararg_id = types_mod.fn_vararg(t)
        if vararg_id >= 0 then
            vararg_id = substitute_inner(ctx, vararg_id, mapping, seen, eval_seen, in_match_arm_subst)
        end
        local param_name_ids = nil
        local pns, pnl = types_mod.fn_param_names_start(t), types_mod.fn_param_names_len(t)
        if pnl > 0 then
            param_name_ids = {}
            for i = pns, pns + pnl - 1 do
                param_name_ids[#param_name_ids + 1] = ctx.lists:get(i)
            end
        end
        seen[tid] = nil
        return types_mod.make_func(ctx, params, returns, vararg_id, param_name_ids)
    end

    if tag == TAG_TABLE then
        local new_field_ids = {}
        local field_pos = {}  -- name_id -> index in new_field_ids; later entries win
        local function add_subst_field(new_fid, name_id)
            if field_pos[name_id] then
                new_field_ids[field_pos[name_id]] = new_fid
            else
                new_field_ids[#new_field_ids + 1] = new_fid
                field_pos[name_id] = #new_field_ids
            end
        end
        local tfs, tfl = types_mod.tbl_fields_start(t), types_mod.tbl_fields_len(t)
        for i = tfs, tfs + tfl - 1 do
            local fid = ctx.lists:get(i)
            local fe = ctx.fields:get(fid)
            if fe.name_id == -1 then
                -- Spread placeholder: substitute inner, then expand if now concrete.
                local new_sp = substitute_inner(ctx, fe.type_id, mapping, seen, eval_seen, in_match_arm_subst)
                local sp_t   = ctx.types:get(types_mod.find(ctx, new_sp))
                local exp_id = types_mod.find(ctx, types_mod.spread_inner(sp_t))
                local exp_t  = ctx.types:get(exp_id)
                if exp_t.tag == TAG_TABLE then
                    local efs, efl = types_mod.tbl_fields_start(exp_t), types_mod.tbl_fields_len(exp_t)
                    for j = efs, efs + efl - 1 do
                        local inner_fid = ctx.lists:get(j)
                        local inner_fe  = ctx.fields:get(inner_fid)
                        local copied = types_mod.make_field(ctx, inner_fe.name_id, inner_fe.type_id, inner_fe.flags)
                        add_subst_field(copied, inner_fe.name_id)
                    end
                elseif exp_t.tag == TAG_UNION then
                    -- Distribute spread over union members:
                    --   { ...(A | B), k: V } → { ...A, k: V } | { ...B, k: V }
                    -- This is true union distribution: each arm gets its own table,
                    -- not a single table with unioned field types.
                    local arms_start = types_mod.agg_members_start(exp_t)
                    local arms_len   = types_mod.agg_members_len(exp_t)
                    local all_tables = true
                    for k = arms_start, arms_start + arms_len - 1 do
                        local arm_t = ctx.types:get(types_mod.find(ctx, ctx.lists:get(k)))
                        if arm_t.tag ~= TAG_TABLE then all_tables = false; break end
                    end
                    if all_tables then
                        -- Build indexers and meta once — they are shared across all union arms.
                        local dist_indexers = {}
                        do
                            local is2, il2 = types_mod.tbl_indexers_start(t), types_mod.tbl_indexers_len(t)
                            local j = is2
                            while j < is2 + il2 - 1 do
                                dist_indexers[#dist_indexers + 1] = substitute_inner(ctx, ctx.lists:get(j),     mapping, seen, eval_seen, in_match_arm_subst)
                                dist_indexers[#dist_indexers + 1] = substitute_inner(ctx, ctx.lists:get(j + 1), mapping, seen, eval_seen, in_match_arm_subst)
                                j = j + 2
                            end
                        end
                        local dist_meta = {}
                        do
                            local tms, tml = types_mod.tbl_meta_start(t), types_mod.tbl_meta_len(t)
                            for j = tms, tms + tml - 1 do
                                local mfid = ctx.lists:get(j)
                                local mfe  = ctx.fields:get(mfid)
                                if mfe.name_id == -1 then
                                    local new_msp  = substitute_inner(ctx, mfe.type_id, mapping, seen, eval_seen, in_match_arm_subst)
                                    local msp_t    = ctx.types:get(types_mod.find(ctx, new_msp))
                                    local mexp_id  = types_mod.find(ctx, types_mod.spread_inner(msp_t))
                                    local mexp_t   = ctx.types:get(mexp_id)
                                    if mexp_t.tag == TAG_TABLE then
                                        local mems, meml = types_mod.tbl_meta_start(mexp_t), types_mod.tbl_meta_len(mexp_t)
                                        for mk = mems, mems + meml - 1 do
                                            local mife = ctx.fields:get(ctx.lists:get(mk))
                                            if mife.name_id >= 0 then
                                                dist_meta[#dist_meta + 1] = types_mod.make_field(ctx, mife.name_id, mife.type_id, mife.flags)
                                            end
                                        end
                                    else
                                        dist_meta[#dist_meta + 1] = types_mod.make_field(ctx, -1, new_msp, 0)
                                    end
                                else
                                    local new_mtype = substitute_inner(ctx, mfe.type_id, mapping, seen, eval_seen, in_match_arm_subst)
                                    dist_meta[#dist_meta + 1] = types_mod.make_field(ctx, mfe.name_id, new_mtype, band(mfe.flags, defs.FLAG_OPTIONAL) ~= 0)
                                end
                            end
                        end
                        -- For each union arm, build the full field list:
                        --   fields before this spread (already in new_field_ids)
                        --   + this arm's spread fields
                        --   + fields after this spread (remaining in the original field list)
                        seen[tid] = nil
                        local union_members = {}
                        for k = arms_start, arms_start + arms_len - 1 do
                            local arm_tid = types_mod.find(ctx, ctx.lists:get(k))
                            local arm_t2  = ctx.types:get(arm_tid)
                            local arm_fids = {}
                            local arm_fpos = {}
                            local function add_af(new_fid, name_id)
                                if arm_fpos[name_id] then
                                    arm_fids[arm_fpos[name_id]] = new_fid
                                else
                                    arm_fids[#arm_fids + 1] = new_fid
                                    arm_fpos[name_id] = #arm_fids
                                end
                            end
                            -- Copy fields accumulated before this spread
                            for _, prev_fid in ipairs(new_field_ids) do
                                local prev_fe = ctx.fields:get(prev_fid)
                                if prev_fe.name_id ~= -1 then
                                    add_af(prev_fid, prev_fe.name_id)
                                end
                            end
                            -- Expand this arm's spread fields
                            local afs, afl = types_mod.tbl_fields_start(arm_t2), types_mod.tbl_fields_len(arm_t2)
                            for j = afs, afs + afl - 1 do
                                local inner_fe = ctx.fields:get(ctx.lists:get(j))
                                if inner_fe.name_id ~= -1 then
                                    add_af(types_mod.make_field(ctx, inner_fe.name_id, inner_fe.type_id, inner_fe.flags), inner_fe.name_id)
                                end
                            end
                            -- Process remaining fields after this spread position
                            for fi = i + 1, tfs + tfl - 1 do
                                local rfe = ctx.fields:get(ctx.lists:get(fi))
                                if rfe.name_id == -1 then
                                    local r_new_sp = substitute_inner(ctx, rfe.type_id, mapping, seen, eval_seen, in_match_arm_subst)
                                    local r_sp_t   = ctx.types:get(types_mod.find(ctx, r_new_sp))
                                    local r_exp_id = types_mod.find(ctx, types_mod.spread_inner(r_sp_t))
                                    local r_exp_t  = ctx.types:get(r_exp_id)
                                    if r_exp_t.tag == TAG_TABLE then
                                        local refs, refl = types_mod.tbl_fields_start(r_exp_t), types_mod.tbl_fields_len(r_exp_t)
                                        for j2 = refs, refs + refl - 1 do
                                            local rife = ctx.fields:get(ctx.lists:get(j2))
                                            if rife.name_id ~= -1 then
                                                add_af(types_mod.make_field(ctx, rife.name_id, rife.type_id, rife.flags), rife.name_id)
                                            end
                                        end
                                    else
                                        arm_fids[#arm_fids + 1] = types_mod.make_field(ctx, -1, r_new_sp, 0)
                                    end
                                else
                                    local r_new_type = substitute_inner(ctx, rfe.type_id, mapping, seen, eval_seen, in_match_arm_subst)
                                    add_af(types_mod.make_field(ctx, rfe.name_id, r_new_type, band(rfe.flags, defs.FLAG_OPTIONAL) ~= 0), rfe.name_id)
                                end
                            end
                            union_members[#union_members + 1] = types_mod.make_table(ctx, arm_fids, dist_indexers, types_mod.tbl_row_var(t), dist_meta)
                        end
                        return types_mod.make_union(ctx, union_members)
                    else
                        -- Not all union arms are tables — keep placeholder
                        new_field_ids[#new_field_ids + 1] = types_mod.make_field(ctx, -1, new_sp, 0)
                    end
                else
                    -- Still unresolved — keep placeholder
                    new_field_ids[#new_field_ids + 1] = types_mod.make_field(ctx, -1, new_sp, 0)
                end
            else
                local new_type = substitute_inner(ctx, fe.type_id, mapping, seen, eval_seen, in_match_arm_subst)
                add_subst_field(types_mod.make_field(ctx, fe.name_id, new_type, band(fe.flags, defs.FLAG_OPTIONAL) ~= 0), fe.name_id)
            end
        end
        local new_indexers = {}
        local is, il = types_mod.tbl_indexers_start(t), types_mod.tbl_indexers_len(t)
        local i = is
        while i < is + il - 1 do
            new_indexers[#new_indexers + 1] = substitute_inner(ctx, ctx.lists:get(i), mapping, seen, eval_seen, in_match_arm_subst)
            new_indexers[#new_indexers + 1] = substitute_inner(ctx, ctx.lists:get(i + 1), mapping, seen, eval_seen, in_match_arm_subst)
            i = i + 2
        end
        local new_meta = {}
        local tms, tml = types_mod.tbl_meta_start(t), types_mod.tbl_meta_len(t)
        for j = tms, tms + tml - 1 do
            local fid = ctx.lists:get(j)
            local fe = ctx.fields:get(fid)
            if fe.name_id == -1 then
                -- Meta-spread placeholder: substitute inner, then expand if now concrete.
                local new_sp = substitute_inner(ctx, fe.type_id, mapping, seen, eval_seen, in_match_arm_subst)
                local sp_t   = ctx.types:get(types_mod.find(ctx, new_sp))
                local exp_id = types_mod.find(ctx, types_mod.spread_inner(sp_t))
                local exp_t  = ctx.types:get(exp_id)
                if exp_t.tag == TAG_TABLE then
                    -- Copy meta slots from the resolved type
                    local ems, eml = types_mod.tbl_meta_start(exp_t), types_mod.tbl_meta_len(exp_t)
                    for k = ems, ems + eml - 1 do
                        local inner_fid = ctx.lists:get(k)
                        local inner_fe  = ctx.fields:get(inner_fid)
                        if inner_fe.name_id >= 0 then
                            new_meta[#new_meta + 1] = types_mod.make_field(ctx, inner_fe.name_id, inner_fe.type_id, inner_fe.flags)
                        end
                    end
                else
                    -- Still unresolved — keep placeholder
                    new_meta[#new_meta + 1] = types_mod.make_field(ctx, -1, new_sp, 0)
                end
            else
                local new_type = substitute_inner(ctx, fe.type_id, mapping, seen, eval_seen, in_match_arm_subst)
                new_meta[#new_meta + 1] = types_mod.make_field(ctx, fe.name_id, new_type, band(fe.flags, defs.FLAG_OPTIONAL) ~= 0)
            end
        end
        seen[tid] = nil
        return types_mod.make_table(ctx, new_field_ids, new_indexers, types_mod.tbl_row_var(t), new_meta)
    end

    if tag == TAG_UNION then
        local ms, ml = types_mod.agg_members_start(t), types_mod.agg_members_len(t)
        local members = {}
        for i = ms, ms + ml - 1 do
            members[#members + 1] = substitute_inner(ctx, ctx.lists:get(i), mapping, seen, eval_seen, in_match_arm_subst)
        end
        seen[tid] = nil
        return types_mod.make_union(ctx, members)
    end

    if tag == TAG_INTERSECTION then
        local ms, ml = types_mod.agg_members_start(t), types_mod.agg_members_len(t)
        local members = {}
        for i = ms, ms + ml - 1 do
            members[#members + 1] = substitute_inner(ctx, ctx.lists:get(i), mapping, seen, eval_seen, in_match_arm_subst)
        end
        seen[tid] = nil
        return types_mod.make_intersection(ctx, members)
    end

    if tag == TAG_TUPLE then
        local ms, ml = types_mod.agg_members_start(t), types_mod.agg_members_len(t)
        local new_elems = {}
        for i = ms, ms + ml - 1 do
            local elem_tid = substitute_inner(ctx, ctx.lists:get(i), mapping, seen, eval_seen, in_match_arm_subst)
            local elem_t   = ctx.types:get(types_mod.find(ctx, elem_tid))
            if elem_t.tag == TAG_SPREAD then
                -- Splice spread-in-tuple-position: (A, ...R) with R=integer → (A, integer)
                -- (A, ...R) with R=tuple(X,Y) → (A, X, Y); (A, ...never) → (A)
                -- If the inner type is still unresolved (TAG_NAMED or TAG_VAR), keep the
                -- TAG_SPREAD in the element list so a later substitution pass can splice it.
                local inner_tid = types_mod.find(ctx, types_mod.spread_inner(elem_t))
                local inner_t   = ctx.types:get(inner_tid)
                if inner_t.tag == TAG_TUPLE then
                    -- Multi-return tuple: splice all elements in-place
                    local ims, iml = types_mod.agg_members_start(inner_t), types_mod.agg_members_len(inner_t)
                    for j = ims, ims + iml - 1 do
                        new_elems[#new_elems + 1] = ctx.lists:get(j)
                    end
                elseif inner_t.tag == TAG_VAR or inner_t.tag == TAG_ROWVAR
                    or inner_t.tag == defs.TAG_NAMED then
                    -- Still unresolved: preserve the (substituted) TAG_SPREAD for later
                    new_elems[#new_elems + 1] = elem_tid
                elseif inner_t.tag ~= defs.TAG_NEVER then
                    -- Single concrete type: treat as 1-element spread
                    new_elems[#new_elems + 1] = inner_tid
                end
                -- TAG_NEVER: contribute zero elements
            else
                new_elems[#new_elems + 1] = elem_tid
            end
        end
        seen[tid] = nil
        return types_mod.make_tuple(ctx, new_elems)
    end

    if tag == TAG_SPREAD then
        local inner = substitute_inner(ctx, types_mod.spread_inner(t), mapping, seen, eval_seen, in_match_arm_subst)
        seen[tid] = nil
        local id = types_mod.alloc_type(ctx, defs.TAG_SPREAD)
        ctx.types:get(id).data[0] = inner
        return id
    end

    -- TAG_MATCH_TYPE: deferred match evaluation.
    -- When stored as an alias body with a TAG_NAMED param placeholder, substitution
    -- replaces the placeholder with the concrete type and then evaluates the match.
    if tag == defs.TAG_MATCH_TYPE then
        -- Substitute into the param
        local new_param = substitute_inner(ctx, types_mod.match_param(t), mapping, seen, eval_seen, in_match_arm_subst)
        -- Substitute into each arm.
        -- Patterns: apply the full mapping so that alias params used as concrete matchers
        -- (e.g. `Keys` in `match K { Keys => ... }`) get replaced with their concrete types.
        -- TAG_NAMED nodes NOT in the mapping are left unchanged (concrete type lookups like
        -- `integer`, `string`, or legacy catch-all names). TAG_CAPTURE nodes (`%Name`) are
        -- never in the mapping and always pass through as-is.
        -- Results: apply the full mapping so that references to alias params (e.g. T
        -- in `$Values<T>`) are correctly replaced with concrete types.
        local new_arms = {}
        local as, al = types_mod.match_arms_start(t), types_mod.match_arms_len(t)
        local i = as
        -- Pass in_match_arm_subst=true so $Throw in result expressions is
        -- deferred (not evaluated eagerly). The throw should only fire when
        -- match.evaluate actually picks that arm.
        while i < as + al - 1 do
            new_arms[#new_arms + 1] = substitute_inner(ctx, ctx.lists:get(i),     mapping, seen, eval_seen, true)
            new_arms[#new_arms + 1] = substitute_inner(ctx, ctx.lists:get(i + 1), mapping, seen, eval_seen, true)
            i = i + 2
        end
        seen[tid] = nil
        local mk = ctx.lists:mark()
        for _, aid in ipairs(new_arms) do ctx.lists:push(aid) end
        local ms, ml = ctx.lists:since(mk)
        local new_mt = types_mod.alloc_type(ctx, defs.TAG_MATCH_TYPE)
        local mtt = ctx.types:get(new_mt)
        mtt.data[0] = new_param
        mtt.data[1] = ms
        mtt.data[2] = ml
        -- Only evaluate the match if the subject is concrete (not a free variable
        -- or unresolved placeholder).
        -- TAG_VAR / TAG_ROWVAR: forall param TV not yet bound — defer.
        -- TAG_NAMED: unresolved generic-alias placeholder (e.g. the T in an outer
        -- match body like `match T { string => Box<T> }` being evaluated during
        -- alias body resolution before T is concrete) — must also defer, otherwise
        -- match.evaluate sees an abstract subject and returns never for every arm.
        local resolved_param = types_mod.find(ctx, new_param)
        local rpt = ctx.types:get(resolved_param)
        if rpt.tag == TAG_VAR or rpt.tag == TAG_ROWVAR or rpt.tag == defs.TAG_NAMED then
            return new_mt
        end
        -- Param is concrete: evaluate the match now.
        -- Pass eval_seen to share the cycle-detection set with the caller.
        local match_mod = require("lib.type.static.match")
        return match_mod.evaluate(ctx, new_mt, eval_seen)
    end

    -- TAG_INDEX_TYPE: deferred indexed access. Substitute subject and key, then
    -- if both are concrete, evaluate via match.lookup_index. Otherwise rebuild a
    -- TAG_INDEX_TYPE node so a future substitution can finish the job.
    -- Mirrors the deferred TAG_MATCH_TYPE pattern above.
    if tag == defs.TAG_INDEX_TYPE then
        local new_subj = substitute_inner(ctx, types_mod.index_subject(t), mapping, seen, eval_seen, in_match_arm_subst)
        local new_key  = substitute_inner(ctx, types_mod.index_key(t), mapping, seen, eval_seen, in_match_arm_subst)
        seen[tid] = nil
        local rs = types_mod.find(ctx, new_subj)
        local rk = types_mod.find(ctx, new_key)
        local rst = ctx.types:get(rs)
        local rkt = ctx.types:get(rk)
        local function deferred(ttag) return ttag == TAG_VAR or ttag == TAG_ROWVAR or ttag == defs.TAG_NAMED end
        if deferred(rst.tag) or deferred(rkt.tag) then
            local id = types_mod.alloc_type(ctx, defs.TAG_INDEX_TYPE)
            local it = ctx.types:get(id)
            it.data[0] = new_subj
            it.data[1] = new_key
            return id
        end
        local match_mod = require("lib.type.static.match")
        local result = match_mod.lookup_index(ctx, new_subj, new_key)
        if result then return result or 0 end
        -- Miss after substitution: report and return never. Suppress when the
        -- subject is still a free var to avoid spurious errors during inference.
        local errors_mod = require("lib.type.static.errors")
        local defs_mod = defs
        local msg = errors_mod.format_diag(defs_mod.E.INDEX_KEY_NOT_FOUND, {
            t = types_mod.display_short(ctx, new_subj),
            k = types_mod.display_short(ctx, new_key),
        })
        errors_mod.error(ctx.err, ctx.filename, 0, 0, msg)
        return ctx.T_NEVER
    end

    -- TAG_TYPE_CALL: deferred HKT application F<A>.
    -- Substitute through callee and args so that when F is replaced by a concrete
    -- type constructor (e.g. Maybe), the application can be evaluated later.
    if tag == defs.TAG_TYPE_CALL then
        local callee_id = substitute_inner(ctx, types_mod.tycall_callee(t), mapping, seen, eval_seen, in_match_arm_subst)
        local cas, cal = types_mod.tycall_args_start(t), types_mod.tycall_args_len(t)
        local new_args = {}
        for i = cas, cas + cal - 1 do
            new_args[#new_args + 1] = substitute_inner(ctx, ctx.lists:get(i), mapping, seen, eval_seen, in_match_arm_subst)
        end
        seen[tid] = nil
        -- Arity check: if the callee is now a concrete non-generic type (not a
        -- type variable, named alias, intrinsic, match, or nested type call) and
        -- there are arguments, it cannot accept type args — emit an error.
        if #new_args > 0 then
            local callee_tid2 = types_mod.find(ctx, callee_id)
            local ct2 = ctx.types:get(callee_tid2)
            if ct2.tag ~= TAG_VAR and ct2.tag ~= TAG_ROWVAR
                and ct2.tag ~= defs.TAG_NAMED
                and ct2.tag ~= defs.TAG_INTRINSIC
                and ct2.tag ~= defs.TAG_MATCH_TYPE
                and ct2.tag ~= defs.TAG_TYPE_CALL then
                local err_mod = require("lib.type.static.errors")
                err_mod.error(ctx.err, ctx.filename, 0, 0,
                    "type '" .. types_mod.display_short(ctx, callee_tid2)
                    .. "' does not take type arguments")
                return ctx.T_NEVER
            end
        end
        -- When callee is TAG_INTRINSIC and all substitution-target args are now
        -- resolved, evaluate the intrinsic immediately.
        -- A TAG_NAMED arg is a remaining placeholder only when its name_id is still
        -- present in the mapping (i.e. substitution didn't replace it).  A TAG_NAMED
        -- that is NOT in the mapping is a reference to a concrete named alias (e.g.
        -- MakeOptional) and is handled correctly by apply_type_fn inside the intrinsic.
        -- A free TAG_VAR arg means the intrinsic arg is not yet concrete; defer by
        -- leaving the TAG_TYPE_CALL node intact for later evaluation (e.g. via
        -- resolve_deferred_intrinsic in solve.lua once the TV is bound to a concrete type).
        local ct = ctx.types:get(callee_id)
        if ct.tag == defs.TAG_INTRINSIC then
            -- $Throw must not be evaluated eagerly during match arm result substitution.
            -- It should only fire when its arm is actually taken by match.evaluate.
            -- When in_match_arm_subst is true, leave $Throw as a deferred TAG_TYPE_CALL
            -- so match.evaluate can fire it after confirming the arm is selected.
            local intr_name = require("lib.type.static.intern").get(ctx.pool, types_mod.intrinsic_name_id(ct)) or ""
            local defer_throw = intr_name == "Throw" and in_match_arm_subst
            if not defer_throw then
                local has_unresolved = false
                for _, aid in ipairs(new_args) do
                    local at2 = ctx.types:get(types_mod.find(ctx, aid))
                    if at2.tag == defs.TAG_NAMED and mapping[types_mod.named_name_id(at2)] ~= nil then
                        has_unresolved = true
                        break
                    end
                    if at2.tag == defs.TAG_VAR or at2.tag == TAG_ROWVAR then
                        has_unresolved = true
                        break
                    end
                end
                if not has_unresolved then
                    local intrinsic_mod = require("lib.type.static.intrinsic")
                    return intrinsic_mod.expand(ctx, types_mod.intrinsic_name_id(ct), new_args, types_mod.tycall_stable_id(t))
                end
            end
        end
        -- When callee is a TAG_NAMED alias (e.g. PickKey in PickKey<Keys> after
        -- Keys is substituted) and all args are concrete, try to resolve the alias.
        -- This handles partial application: PickKey<"x"> → TAG_PARTIAL_APP.
        if ct.tag == defs.TAG_NAMED then
            local has_unresolved = false
            for _, aid in ipairs(new_args) do
                local at2 = ctx.types:get(types_mod.find(ctx, aid))
                if at2.tag == defs.TAG_NAMED and mapping[types_mod.named_name_id(at2)] ~= nil then
                    has_unresolved = true
                    break
                end
                if at2.tag == defs.TAG_VAR or at2.tag == TAG_ROWVAR then
                    has_unresolved = true
                    break
                end
            end
            if not has_unresolved then
                local resolved = M.resolve_named_type(ctx, ctx.scope, types_mod.named_name_id(ct), new_args)
                if resolved then return resolved or 0 end
            end
        end
        local mk = ctx.lists:mark()
        for _, aid in ipairs(new_args) do ctx.lists:push(aid) end
        local as, al = ctx.lists:since(mk)
        local id = types_mod.alloc_type(ctx, defs.TAG_TYPE_CALL)
        ctx.types:get(id).data[0] = callee_id
        ctx.types:get(id).data[1] = as
        ctx.types:get(id).data[2] = al
        return id
    end

    -- TAG_PARTIAL_APP: partially-applied generic alias.
    -- Substitute through partial args so that alias params (e.g. Keys) get replaced
    -- with their concrete types when the enclosing alias body is instantiated.
    -- If all resulting args are still concrete (no TAG_VAR/unresolved TAG_NAMED),
    -- attempt to re-evaluate via resolve_named_type (which may produce a fully-resolved
    -- type, another TAG_PARTIAL_APP, or a concrete result).
    if tag == defs.TAG_PARTIAL_APP then
        local pname_id = types_mod.partial_name_id(t)
        local pas, pal = types_mod.partial_args_start(t), types_mod.partial_args_len(t)
        local new_partial_args = {}
        for i = pas, pas + pal - 1 do
            new_partial_args[#new_partial_args + 1] = substitute_inner(ctx, ctx.lists:get(i), mapping, seen, eval_seen, in_match_arm_subst)
        end
        seen[tid] = nil
        -- Check if any arg is still unresolved
        local has_unresolved = false
        for _, aid in ipairs(new_partial_args) do
            local at2 = ctx.types:get(types_mod.find(ctx, aid))
            if at2.tag == defs.TAG_NAMED and mapping[types_mod.named_name_id(at2)] ~= nil then
                has_unresolved = true; break
            end
            if at2.tag == TAG_VAR or at2.tag == TAG_ROWVAR then
                has_unresolved = true; break
            end
        end
        if not has_unresolved then
            -- Try to re-evaluate with the now-concrete args
            local resolved = M.resolve_named_type(ctx, ctx.scope, pname_id, new_partial_args)
            if resolved then return resolved or 0 end
        end
        -- Still unresolved: rebuild the TAG_PARTIAL_APP with substituted args
        local mk = ctx.lists:mark()
        for _, aid in ipairs(new_partial_args) do ctx.lists:push(aid) end
        local ls, ll = ctx.lists:since(mk)
        local id = types_mod.alloc_type(ctx, defs.TAG_PARTIAL_APP)
        local pt = ctx.types:get(id)
        pt.data[0] = pname_id  -- name_id unchanged
        pt.data[1] = ls
        pt.data[2] = ll
        return id
    end

    seen[tid] = nil
    return tid
end

-- Substitute named type refs in a type.
-- mapping:    { [name_id] -> type_id }
-- eval_seen:  optional cycle-detection set from an enclosing match.evaluate call
--: (Ctx, integer, { [integer]: integer, ... }, { [integer]: boolean, ... } | nil) -> integer
function M.substitute(ctx, tid, mapping, eval_seen)
    return substitute_inner(ctx, tid, mapping, {}, eval_seen, false)
end

-- Resolve a named type alias: look up in scope, apply type args.
-- Returns (resolved_type_id, nil) or (nil, error_message).
--: (Ctx, Scope, integer, { [integer]: integer, ... } | nil) -> (integer | nil, string | nil)
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

    -- Generic alias: check arity, applying defaults for missing trailing args.
    local arg_ids_len = arg_ids and #arg_ids or 0
    local param_count = #alias.params
    -- Count required params (those without a default).
    local required_count = param_count
    if alias.resolved_defaults then
        for i = param_count, 1, -1 do
            if alias.resolved_defaults[i] ~= nil then
                required_count = i - 1
            else
                break
            end
        end
    end
    if arg_ids_len > param_count then
        local name = require("lib.type.static.intern").get(ctx.pool, name_id) or "?"
        if required_count == param_count then
            return nil, "type '" .. name .. "' expects " .. param_count .. " argument(s), got " .. arg_ids_len
        else
            return nil, "type '" .. name .. "' expects " .. required_count .. " to " .. param_count .. " argument(s), got " .. arg_ids_len
        end
    end

    -- Partial application: at least one arg supplied but not enough to fully apply.
    -- Return TAG_PARTIAL_APP so the caller can later supply the remaining arg(s)
    -- via apply_type_fn (e.g. $EachField<T, PickKey<"x">>).
    -- Zero-arg partial application (arg_ids_len == 0) is not supported — that is
    -- just an unapplied alias (handled above as TAG_NAMED); emit an arity error.
    if arg_ids_len >= 1 and arg_ids_len < required_count then
        local mk = ctx.lists:mark()
        for _, aid in ipairs(arg_ids) do ctx.lists:push(aid) end
        local ls, ll = ctx.lists:since(mk)
        local id = types_mod.alloc_type(ctx, defs.TAG_PARTIAL_APP)
        local pt = ctx.types:get(id)
        pt.data[0] = name_id
        pt.data[1] = ls
        pt.data[2] = ll
        return id
    end

    -- Zero-arg under-arity: arity error (alias has params but caller supplied none).
    if arg_ids_len < required_count then
        local name = require("lib.type.static.intern").get(ctx.pool, name_id) or "?"
        if required_count == param_count then
            return nil, "type '" .. name .. "' expects " .. param_count .. " argument(s), got " .. arg_ids_len
        else
            return nil, "type '" .. name .. "' expects " .. required_count .. " to " .. param_count .. " argument(s), got " .. arg_ids_len
        end
    end

    -- Build substitution mapping, filling in defaults for missing args.
    local mapping = {}
    for i = 1, param_count do
        if arg_ids and i <= arg_ids_len then
            mapping[alias.params[i]] = arg_ids[i]
        else
            -- Use the resolved default for this parameter.
            mapping[alias.params[i]] = alias.resolved_defaults[i]
        end
    end

    -- Cycle guard: alias.body == nil means we are currently constructing this
    -- generic alias body (self-referential during Pass 2a of process_type_decls).
    -- Return nil,nil so the caller (resolve_annotation_type) can emit a TAG_NAMED
    -- forward-reference placeholder instead of crashing on substitute(nil).
    if alias.body == nil then return nil, nil end

    -- Check each argument against its resolved bound, if any.
    if alias.resolved_bounds then
        local intern_mod = require("lib.type.static.intern")
        local unify_mod  = require("lib.type.static.unify")
        for i = 1, #alias.params do
            local bound = alias.resolved_bounds[i]
            if bound ~= nil then
                -- Use mapping so default-filled args are also checked (arg_ids may be nil).
                local arg = mapping[alias.params[i]]
                -- Use try_unify to check structural assignability (read-only, no side effects).
                -- Widen literal arg types first so `{ x: 1 }` satisfies `{ x: number }`.
                local widened_arg = types_mod.widen(ctx, arg)
                if not unify_mod.try_unify(ctx, widened_arg, bound) then
                    local param_name = intern_mod.get(ctx.pool, alias.params[i]) or "?"
                    local arg_str  = types_mod.display_short(ctx, arg)
                    local bnd_str  = types_mod.display_short(ctx, bound)
                    return nil, "type argument '" .. arg_str
                        .. "' does not satisfy constraint '" .. bnd_str
                        .. "' for parameter '" .. param_name .. "'"
                end
            end
        end
    end

    return M.substitute(ctx, alias.body, mapping)
end

return M
