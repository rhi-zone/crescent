-- lib/type/static/solve.lua
-- Constraint solver for the v3 typechecker.
-- Processes constraints emitted by constrain.lua and binds type variables.

local defs      = require("lib.type.static.defs")
local types_mod = require("lib.type.static.types")
local unify_mod = require("lib.type.static.unify")
local errors_mod = require("lib.type.static.errors")
local intern_mod = require("lib.type.static.intern")
local env_mod    = require("lib.type.static.env")
local constrain  = require("lib.type.static.constrain")

local TAG_ANY          = defs.TAG_ANY
local TAG_UNKNOWN      = defs.TAG_UNKNOWN
local TAG_NIL          = defs.TAG_NIL
local TAG_NUMBER       = defs.TAG_NUMBER
local TAG_INTEGER      = defs.TAG_INTEGER
local TAG_STRING       = defs.TAG_STRING
local TAG_LITERAL      = defs.TAG_LITERAL
local TAG_FUNCTION     = defs.TAG_FUNCTION
local TAG_TABLE        = defs.TAG_TABLE
local TAG_UNION        = defs.TAG_UNION
local TAG_INTERSECTION = defs.TAG_INTERSECTION
local TAG_VAR          = defs.TAG_VAR
local TAG_ROWVAR       = defs.TAG_ROWVAR
local TAG_NEVER        = defs.TAG_NEVER
local TAG_NOMINAL      = defs.TAG_NOMINAL
local TAG_TUPLE        = defs.TAG_TUPLE
local TAG_NAMED        = defs.TAG_NAMED
local TAG_MATCH_TYPE   = defs.TAG_MATCH_TYPE
local TAG_TYPE_CALL    = defs.TAG_TYPE_CALL

local LIT_INTEGER   = defs.LIT_INTEGER
local LIT_NUMBER    = defs.LIT_NUMBER
local LIT_STRING    = defs.LIT_STRING
local LIT_OPAQUE_KEY = defs.LIT_OPAQUE_KEY

local FLAG_OPTIONAL   = defs.FLAG_OPTIONAL
local FLAG_PRIVATE    = defs.FLAG_PRIVATE
local FLAG_OPAQUE_KEY = defs.FLAG_OPAQUE_KEY
local band            = require("bit").band

local C_UNIFY     = constrain.C_UNIFY
local C_SUB       = constrain.C_SUB
local C_INDEX     = constrain.C_INDEX
local C_CALLABLE  = constrain.C_CALLABLE
local C_ARITH     = constrain.C_ARITH
local C_RETURN    = constrain.C_RETURN
local C_COMPARE   = constrain.C_COMPARE
local C_BOUND     = constrain.C_BOUND
local C_OR        = constrain.C_OR

local find = types_mod.find

local M = {}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function add_error(ctx, line, col, msg)
    errors_mod.error(ctx.err, ctx.filename, line or 0, col or 0, msg)
end

-- Widen literal to base type for Sub constraints.
local function widen_for_sub(ctx, tid)
    return types_mod.widen(ctx, tid)
end

-- Deeply widen a type: widens top-level literals AND literal-typed table fields.
-- Used when comparing inferred (non-annotated) types in bound checks, so that
-- a table inferred as {x: 1} is treated as {x: number} for structural comparison.
local function widen_deep(ctx, tid, seen)
    tid = types_mod.find(ctx, tid)
    local t = ctx.types:get(tid)
    local top = types_mod.widen(ctx, tid)
    if top ~= tid then return top end  -- was a top-level literal; already widened
    if t.tag == TAG_TABLE then
        seen = seen or {}
        if seen[tid] then return tid end
        seen[tid] = true
        local changed = false
        local new_fields = {}
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            local fid = ctx.lists:get(i)
            local fe  = ctx.fields:get(fid)
            local wt  = widen_deep(ctx, fe.type_id, seen)
            if wt ~= types_mod.find(ctx, fe.type_id) then changed = true end
            new_fields[#new_fields + 1] = types_mod.make_field(ctx, fe.name_id, wt,
                require("bit").band(fe.flags, defs.FLAG_OPTIONAL) ~= 0)
        end
        if not changed then seen[tid] = nil; return tid end
        -- Rebuild indexers (unchanged)
        local new_indexers = {}
        local is, il = t.data[2], t.data[3]
        local i = is
        while i < is + il - 1 do
            new_indexers[#new_indexers + 1] = ctx.lists:get(i)
            new_indexers[#new_indexers + 1] = ctx.lists:get(i + 1)
            i = i + 2
        end
        seen[tid] = nil
        return types_mod.make_table(ctx, new_fields, new_indexers, t.data[4], {})
    end
    return tid
end

-- Check if a type contains any unbound free TAG_VAR (depth-first, with cycle guard).
-- Used to decide whether the fast path in solve_callable can safely skip unify().
local function contains_free_var(ctx, tid, seen)
    tid = types_mod.find(ctx, tid)
    local t = ctx.types:get(tid)
    local tag = t.tag
    if tag == TAG_VAR or tag == TAG_ROWVAR then return true end
    if seen and seen[tid] then return false end
    if tag == TAG_TABLE then
        seen = seen or {}; seen[tid] = true
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            local fe = ctx.fields:get(ctx.lists:get(i))
            if contains_free_var(ctx, fe.type_id, seen) then return true end
        end
        if t.data[4] >= 0 and contains_free_var(ctx, t.data[4], seen) then return true end
        return false
    end
    if tag == TAG_FUNCTION then
        seen = seen or {}; seen[tid] = true
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            if contains_free_var(ctx, ctx.lists:get(i), seen) then return true end
        end
        for i = t.data[2], t.data[2] + t.data[3] - 1 do
            if contains_free_var(ctx, ctx.lists:get(i), seen) then return true end
        end
        return false
    end
    if tag == TAG_UNION or tag == TAG_INTERSECTION or tag == TAG_TUPLE then
        seen = seen or {}; seen[tid] = true
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            if contains_free_var(ctx, ctx.lists:get(i), seen) then return true end
        end
        return false
    end
    return false
end

-- Bind a free type var to a target type directly (bypasses unify's bilateral-any short-circuit).
-- Use this when we want to resolve a result VAR to a concrete type (T_ANY, T_UNKNOWN, etc.).
local function bind_to(ctx, tid, target)
    local root = find(ctx, tid)
    local t = ctx.types:get(root)
    if t.tag == TAG_VAR or t.tag == TAG_ROWVAR then
        t.data[2] = target
    end
end

-- Resolve arithmetic result type from primitive operands.
-- Returns result_tid or nil if operands are not numeric.
local ARITH_OPS_SET = {
    __add = true, __sub = true, __mul = true,
    __div = true, __mod = true, __pow = true, __unm = true,
}

local function is_numeric_tid(ctx, tid)
    tid = find(ctx, tid)
    local t = ctx.types:get(tid)
    if t.tag == TAG_ANY or t.tag == TAG_VAR or t.tag == TAG_ROWVAR then return true end
    if t.tag == TAG_NUMBER  or t.tag == TAG_INTEGER  then return true end
    if t.tag == TAG_LITERAL then
        local k = t.data[0]
        return k == LIT_INTEGER or k == LIT_NUMBER
    end
    if t.tag == TAG_UNION then
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            if not is_numeric_tid(ctx, ctx.lists:get(i)) then return false end
        end
        return true
    end
    return false
end

local function is_int_compat_tid(ctx, tid)
    tid = find(ctx, tid)
    local t = ctx.types:get(tid)
    return t.tag == TAG_INTEGER
        or (t.tag == TAG_LITERAL and t.data[0] == LIT_INTEGER)
end

-- Check metamethod on a TABLE type (not primitives — prim_meta lookup not needed here).
local function table_meta_op_ret(ctx, tbl_tid, mm_name)
    local mm_id = intern_mod.intern(ctx.pool, mm_name)
    local fe = types_mod.table_meta_field(ctx, tbl_tid, mm_id)
    if not fe then return nil end
    local fn_tid = find(ctx, fe.type_id)
    local ft = ctx.types:get(fn_tid)
    if ft.tag == TAG_FUNCTION and ft.data[3] > 0 then
        return find(ctx, ctx.lists:get(ft.data[2]))
    end
    return ctx.T_ANY
end

-- ---------------------------------------------------------------------------
-- Constraint handlers
-- ---------------------------------------------------------------------------

local function solve_unify(ctx, c)
    local t1 = find(ctx, c[2])
    local t2 = find(ctx, c[3])
    local ok, err = unify_mod.unify(ctx, t1, t2)
    if not ok then
        add_error(ctx, c[4], c[5],
            "type mismatch: cannot unify '" .. types_mod.display_short(ctx, t1)
            .. "' with '" .. types_mod.display_short(ctx, t2) .. "'"
            .. (err and (": " .. err) or ""))
    end
    return ok
end

local function solve_sub(ctx, c)
    local actual   = find(ctx, c[2])
    local expected = find(ctx, c[3])
    local line, col = c[4], c[5]

    -- Fast path: check direct assignability without widening.
    -- Allows literal types to satisfy union/literal expectations, e.g. "ok" → "ok"|"error",
    -- or 3.14 → 3.14 (float literal narrowing round-trip).
    -- Skip if expected is a free type var (needs unify to bind it, not just a check).
    -- Skip if expected is a closed table: the full unify path enforces the excess-field check
    -- (width subtyping only holds when the target is open with a row variable).
    do
        local et = ctx.types:get(expected)
        local is_closed_table = et.tag == TAG_TABLE and et.data[4] < 0
        if not is_closed_table and et.tag ~= TAG_VAR and et.tag ~= TAG_ROWVAR then
            if unify_mod.try_unify(ctx, actual, expected) then
                return true
            end
        end
    end

    -- Widen actual literals before constraining
    local widened = widen_for_sub(ctx, actual)

    local ok, err = unify_mod.unify(ctx, widened, expected)
    if not ok then
        -- "might also be" message for unions
        local act_t = ctx.types:get(find(ctx, actual))
        if act_t.tag == TAG_UNION then
            local failing = {}
            for i = act_t.data[0], act_t.data[0] + act_t.data[1] - 1 do
                local mid = find(ctx, ctx.lists:get(i))
                if not unify_mod.try_unify(ctx, mid, expected) then
                    failing[#failing + 1] = mid
                end
            end
            local total = act_t.data[1]
            if #failing > 0 and #failing < total then
                local fail_tid = #failing == 1 and failing[1]
                    or types_mod.make_union(ctx, failing)
                add_error(ctx, line, col,
                    "expects '" .. types_mod.display_short(ctx, expected)
                    .. "', but argument might also be '"
                    .. types_mod.display_short(ctx, fail_tid) .. "'")
                return false
            end
        end
        add_error(ctx, line, col,
            "cannot assign '" .. types_mod.display_short(ctx, actual)
            .. "' to '" .. types_mod.display_short(ctx, expected) .. "'"
            .. (err and (": " .. err) or ""))
    end
    return ok
end

-- Solve a deferred `or` expression: C_OR = { C_OR, left_tid, right_tid, result_tid, line, col }
-- Defers while left_tid is still a free TAG_VAR (not yet resolved).
-- Once concrete: result = subtract(left, nil) | right.
local function solve_or(ctx, c)
    local left_tid   = c[2]
    local right_tid  = c[3]
    local result_tid = c[4]

    local left = find(ctx, left_tid)
    local lt = ctx.types:get(left)
    if lt.tag == TAG_VAR or lt.tag == TAG_ROWVAR then
        return false  -- defer
    end

    local non_nil_left = types_mod.subtract(ctx, left, ctx.T_NIL)
    local right = find(ctx, right_tid)
    local resolved = types_mod.make_union(ctx, { non_nil_left, right })
    unify_mod.unify(ctx, result_tid, resolved)
    return true
end

-- Solve a forall bound check: C_BOUND = { C_BOUND, fresh_tv_id, bound_type_id, line, col }
-- Defers while fresh_tv is still a free TAG_VAR (not yet bound at call site).
-- Once bound:
--   - For TAG_MATCH_TYPE bounds: evaluate the match with the actual type as subject.
--     If the result is TAG_NEVER, the constraint is violated.
--   - For other bounds: check try_unify(widen(actual), bound).
-- Skips enforcement when the bound is TAG_NAMED (unapplied kind constraint).
local function solve_bound(ctx, c)
    local tv_id    = c[2]
    local bound_id = c[3]
    local line, col = c[4], c[5]

    local actual = find(ctx, tv_id)
    local at = ctx.types:get(actual)

    -- Defer: TV not yet bound to a concrete type at the call site.
    if at.tag == TAG_VAR or at.tag == TAG_ROWVAR then
        return false
    end

    local resolved_bound = find(ctx, bound_id)
    local bt = ctx.types:get(resolved_bound)

    -- Defer if the bound TV itself is still free — e.g. "T: F" where F's fresh
    -- TV has not yet been unified with a concrete type by the C_CALLABLE solver.
    -- Once F is resolved, the next solver pass re-evaluates this constraint.
    if bt.tag == TAG_VAR or bt.tag == TAG_ROWVAR then
        return false
    end

    -- Skip unenforced bound forms:
    --   TAG_TYPE_CALL  — unapplied HKT application (not yet supported)
    --   TAG_NEVER      — indeterminate bound (match type evaluation failed on free TV)
    if bt.tag == TAG_TYPE_CALL or bt.tag == TAG_NEVER then
        return true  -- not yet enforced
    end

    -- Kind arity enforcement: TAG_NAMED with no args is a kind constraint.
    -- <F: T1> where T1<X>=any means F must be a * -> * type constructor (arity 1).
    -- Check that the actual type has the same arity as the alias.
    if bt.tag == TAG_NAMED and bt.data[2] == 0 then
        local bound_alias = env_mod.lookup_type(ctx.scope, bt.data[0])
        local bound_arity = (bound_alias and bound_alias.params) and #bound_alias.params or 0
        if bound_arity > 0 then
            -- Actual type must also be a TAG_NAMED alias with matching arity.
            local actual_arity = 0
            if at.tag == TAG_NAMED and at.data[2] == 0 then
                local actual_alias = env_mod.lookup_type(ctx.scope, at.data[0])
                actual_arity = (actual_alias and actual_alias.params) and #actual_alias.params or 0
            end
            -- Primitives and non-generic types have arity 0; they fail the kind check.
            if actual_arity ~= bound_arity then
                local bound_name = intern_mod.get(ctx.pool, bt.data[0]) or "?"
                local kind_arrows = string.rep("* -> ", bound_arity) .. "*"
                add_error(ctx, line, col,
                    "type '" .. types_mod.display_short(ctx, actual)
                    .. "' has kind *, expected kind " .. kind_arrows
                    .. " (bound '" .. bound_name .. "' requires arity "
                    .. bound_arity .. ")")
                return false
            end
        end
        return true
    end

    -- TAG_MATCH_TYPE bound: evaluate the match with the actual type as subject.
    -- The bound is TAG_MATCH_TYPE(subject=orig_param_tv, arms=...) where orig_param_tv
    -- is the same generic TV that was instantiated to produce fresh_tv (= tv_id here).
    -- Since actual = find(ctx, tv_id) is the concrete type for that param,
    -- evaluate the match by substituting actual in as the subject directly.
    if bt.tag == TAG_MATCH_TYPE then
        local match_mod = require("lib.type.static.match")
        -- Build a temporary match-type node with the concrete actual type as subject.
        local new_mt = types_mod.alloc_type(ctx, TAG_MATCH_TYPE)
        local mtt = ctx.types:get(new_mt)
        mtt.data[0] = actual
        mtt.data[1] = bt.data[1]
        mtt.data[2] = bt.data[2]
        local result = match_mod.evaluate(ctx, new_mt)
        if find(ctx, result) == ctx.T_NEVER then
            add_error(ctx, line, col,
                "type argument '" .. types_mod.display_short(ctx, actual)
                .. "' does not satisfy constraint '"
                .. types_mod.display_short(ctx, find(ctx, bound_id)) .. "'")
            return false
        end
        return true
    end

    -- TV is bound — check the bound via structural assignability.
    -- Widen both sides deeply: inferred bounds (e.g. "T: F" where F was inferred
    -- from a literal argument like {x=1}) carry literal field types that should be
    -- compared as their base types ({x: number}), not as exact literals.
    local widened       = widen_deep(ctx, actual)
    local widened_bound = widen_deep(ctx, resolved_bound)
    if not unify_mod.try_unify(ctx, widened, widened_bound) then
        add_error(ctx, line, col,
            "type argument '" .. types_mod.display_short(ctx, actual)
            .. "' does not satisfy constraint '"
            .. types_mod.display_short(ctx, resolved_bound) .. "'")
        return false
    end
    return true
end

-- Solve a slot/field index: C_INDEX = { C_INDEX, obj_tid, key_tid, res_tid, line, col }
-- key_tid: TAG_LITERAL(LIT_STRING, name_id) for named field; TAG_LITERAL(LIT_INTEGER, slot) for tuple slot.
local function solve_index(ctx, c)
    local obj_tid_raw = find(ctx, c[2])
    local key_tid  = find(ctx, c[3])
    local res_tid  = c[4]
    local line, col = c[5], c[6]

    local key_t = ctx.types:get(key_tid)
    if key_t.tag ~= TAG_LITERAL then
        bind_to(ctx, res_tid, ctx.T_ANY)
        return true
    end

    -- Opaque table-valued key: t[TC] — look for a FLAG_OPAQUE_KEY field by variable name.
    if key_t.data[0] == LIT_OPAQUE_KEY then
        local key_name_id = key_t.data[1]
        local obj_tid = find(ctx, obj_tid_raw)
        local obj_t   = ctx.types:get(obj_tid)

        if obj_t.tag == TAG_ANY or obj_t.tag == TAG_UNKNOWN then
            bind_to(ctx, res_tid, obj_t.tag == TAG_ANY and ctx.T_ANY or ctx.T_UNKNOWN)
            return true
        end
        if obj_t.tag == TAG_NEVER then
            bind_to(ctx, res_tid, ctx.T_NEVER)
            return true
        end
        if obj_t.tag == TAG_VAR or obj_t.tag == TAG_ROWVAR then
            return false  -- defer
        end
        if obj_t.tag == TAG_TABLE then
            local fe = types_mod.table_opaque_field(ctx, obj_tid, key_name_id)
            if fe then
                local ft = find(ctx, fe.type_id)
                if band(fe.flags, FLAG_OPTIONAL) ~= 0 then
                    ft = types_mod.make_union(ctx, { ft, ctx.T_NIL })
                end
                unify_mod.unify(ctx, res_tid, ft)
                return true
            end
            -- No matching opaque field: open table returns unknown, closed returns any (silently)
            if obj_t.data[4] >= 0 then
                bind_to(ctx, res_tid, ctx.T_UNKNOWN)
            else
                bind_to(ctx, res_tid, ctx.T_ANY)
            end
            return true
        end
        -- Not a table: return any silently
        bind_to(ctx, res_tid, ctx.T_ANY)
        return true
    end

    if key_t.data[0] == LIT_INTEGER then
        -- Tuple slot projection
        local slot = key_t.data[1]
        local obj_tid = find(ctx, obj_tid_raw)
        local obj_t = ctx.types:get(obj_tid)
        if obj_t.tag == TAG_VAR or obj_t.tag == TAG_ROWVAR then
            return false  -- defer until obj is resolved
        end
        if obj_t.tag == TAG_TUPLE then
            if slot < obj_t.data[1] then
                unify_mod.unify(ctx, res_tid, find(ctx, ctx.lists:get(obj_t.data[0] + slot)))
            else
                bind_to(ctx, res_tid, ctx.T_NIL)
            end
            return true
        end
        if obj_t.tag == TAG_UNION then
            local parts = {}
            for i = obj_t.data[0], obj_t.data[0] + obj_t.data[1] - 1 do
                local arm = find(ctx, ctx.lists:get(i))
                local arm_t = ctx.types:get(arm)
                if arm_t.tag == TAG_TUPLE and slot < arm_t.data[1] then
                    parts[#parts + 1] = find(ctx, ctx.lists:get(arm_t.data[0] + slot))
                else
                    parts[#parts + 1] = ctx.T_NIL
                end
            end
            local result = #parts == 0 and ctx.T_NIL
                or #parts == 1 and parts[1]
                or types_mod.make_union(ctx, parts)
            bind_to(ctx, res_tid, result)
            return true
        end
        if obj_t.tag == TAG_ANY or obj_t.tag == TAG_UNKNOWN then
            bind_to(ctx, res_tid, ctx.T_ANY)
            return true
        end
        if obj_t.tag == TAG_NEVER then
            bind_to(ctx, res_tid, ctx.T_NEVER)
            return true
        end
        -- Non-tuple: slot 0 = the value itself, others = nil
        if slot == 0 then
            unify_mod.unify(ctx, res_tid, obj_tid)
        else
            bind_to(ctx, res_tid, ctx.T_NIL)
        end
        return true
    end

    -- LIT_STRING key: named field access (was solve_has_field)
    local name_id  = key_t.data[1]
    local obj_tid  = find(ctx, obj_tid_raw)
    local obj_t = ctx.types:get(obj_tid)

    if obj_t.tag == TAG_ANY or obj_t.tag == TAG_UNKNOWN then
        -- Resolve result to T_ANY/T_UNKNOWN silently
        bind_to(ctx, res_tid, obj_t.tag == TAG_ANY and ctx.T_ANY or ctx.T_UNKNOWN)
        return true
    end

    if obj_t.tag == TAG_NEVER then
        bind_to(ctx, res_tid, ctx.T_NEVER)
        return true
    end

    -- Nominal: unwrap
    if obj_t.tag == TAG_NOMINAL then
        obj_tid = find(ctx, obj_t.data[2])
        obj_t   = ctx.types:get(obj_tid)
    end

    -- Primitive field lookup via prim_index (string/number/integer methods).
    -- Normalize TAG_LITERAL to its base primitive tag first.
    do
        local base_tag = obj_t.tag
        if base_tag == TAG_LITERAL then
            local kind = obj_t.data[0]
            if     kind == LIT_STRING  then base_tag = TAG_STRING
            elseif kind == LIT_NUMBER  then base_tag = TAG_NUMBER
            elseif kind == LIT_INTEGER then base_tag = TAG_INTEGER
            else                            base_tag = nil
            end
        elseif base_tag ~= TAG_STRING and base_tag ~= TAG_NUMBER and base_tag ~= TAG_INTEGER then
            base_tag = nil
        end
        if base_tag then
            local idx_tid = ctx.prim_index and ctx.prim_index[base_tag]
            if idx_tid then
                idx_tid = find(ctx, idx_tid)
                if ctx.types:get(idx_tid).tag == TAG_TABLE then
                    local fe = types_mod.table_field(ctx, idx_tid, name_id)
                    if fe then
                        unify_mod.unify(ctx, res_tid, find(ctx, fe.type_id))
                        return true
                    end
                end
            end
            -- Primitive with no matching method: error
            local fname = intern_mod.get(ctx.pool, name_id) or "?"
            add_error(ctx, line, col, "no method '" .. fname .. "' on this type")
            bind_to(ctx, res_tid, ctx.T_ANY)
            return false
        end
    end

    if obj_t.tag == TAG_TABLE then
        local fe = types_mod.table_field(ctx, obj_tid, name_id)
        if fe then
            -- Private field: only accessible from the file that defines this type.
            if band(fe.flags, FLAG_PRIVATE) ~= 0 then
                local origin = ctx.type_origins and ctx.type_origins[obj_tid]
                if origin and origin ~= ctx.filename then
                    local fname = intern_mod.get(ctx.pool, name_id) or "?"
                    add_error(ctx, line, col,
                        "field '" .. fname .. "' is private to '" .. origin .. "'")
                    bind_to(ctx, res_tid, ctx.T_ANY)
                    return false
                end
            end
            local ft = find(ctx, fe.type_id)
            if band(fe.flags, FLAG_OPTIONAL) ~= 0 then
                -- Optional field: access returns T | nil
                ft = types_mod.make_union(ctx, { ft, ctx.T_NIL })
            end
            unify_mod.unify(ctx, res_tid, ft)
            return true
        end
        -- String indexer fallback
        local is, il = obj_t.data[2], obj_t.data[3]
        local i = is
        while i < is + il - 1 do
            local kt = find(ctx, ctx.lists:get(i))
            if ctx.types:get(kt).tag == TAG_STRING then
                unify_mod.unify(ctx, res_tid, find(ctx, ctx.lists:get(i + 1)))
                return true
            end
            i = i + 2
        end
        -- Open table: field may exist
        if obj_t.data[4] >= 0 then
            bind_to(ctx, res_tid, ctx.T_UNKNOWN)
            return true
        end
        local fname = intern_mod.get(ctx.pool, name_id) or "?"
        add_error(ctx, line, col, "field '" .. fname .. "' doesn't exist")
        bind_to(ctx, res_tid, ctx.T_ANY)
        return false
    end

    if obj_t.tag == TAG_VAR or obj_t.tag == TAG_ROWVAR then
        -- Open table: add the field constraint by binding var to a table with this field
        local field_var = types_mod.make_var(ctx, 0)
        local row_var   = types_mod.make_rowvar(ctx, 0)
        local fid = types_mod.make_field(ctx, name_id, field_var, false)
        local tbl_ty = types_mod.make_table(ctx, { fid }, {}, row_var, {})
        unify_mod.unify(ctx, obj_tid, tbl_ty)
        unify_mod.unify(ctx, res_tid, field_var)
        return true
    end

    if obj_t.tag == TAG_UNION then
        local field_types = {}
        local closed_miss = false
        local open_miss   = false
        for i = obj_t.data[0], obj_t.data[0] + obj_t.data[1] - 1 do
            local mid = find(ctx, ctx.lists:get(i))
            local mt = ctx.types:get(mid)
            if mt.tag == TAG_TABLE then
                local fe = types_mod.table_field(ctx, mid, name_id)
                if fe then
                    field_types[#field_types + 1] = find(ctx, fe.type_id)
                elseif mt.data[4] >= 0 then
                    open_miss = true
                else
                    closed_miss = true
                end
            elseif mt.tag == TAG_ANY then
                bind_to(ctx, res_tid, ctx.T_ANY)
                return true
            elseif mt.tag == TAG_UNKNOWN or mt.tag == TAG_VAR or mt.tag == TAG_ROWVAR then
                -- Unknown/unresolved types are open — field may exist
                open_miss = true
            else
                closed_miss = true
            end
        end
        if #field_types > 0 or open_miss or closed_miss then
            if open_miss   then field_types[#field_types + 1] = ctx.T_UNKNOWN end
            if closed_miss then field_types[#field_types + 1] = ctx.T_NIL end
            local result = types_mod.make_union(ctx, field_types)
            bind_to(ctx, res_tid, result)
            return true
        end
        local fname = intern_mod.get(ctx.pool, name_id) or "?"
        add_error(ctx, line, col, "field '" .. fname .. "' doesn't exist in union")
        bind_to(ctx, res_tid, ctx.T_ANY)
        return false
    end

    if obj_t.tag == TAG_INTERSECTION then
        -- Field must exist in ALL closed members; if any open member, result may exist.
        local field_types = {}
        local any_open = false
        local all_miss = true
        for i = obj_t.data[0], obj_t.data[0] + obj_t.data[1] - 1 do
            local mid = find(ctx, ctx.lists:get(i))
            local mt  = ctx.types:get(mid)
            if mt.tag == TAG_TABLE then
                local fe = types_mod.table_field(ctx, mid, name_id)
                if fe then
                    field_types[#field_types + 1] = find(ctx, fe.type_id)
                    all_miss = false
                elseif mt.data[4] >= 0 then
                    any_open = true
                    all_miss = false
                end
            elseif mt.tag == TAG_ANY then
                bind_to(ctx, res_tid, ctx.T_ANY)
                return true
            elseif mt.tag == TAG_UNKNOWN or mt.tag == TAG_VAR or mt.tag == TAG_ROWVAR then
                any_open = true
                all_miss = false
            end
        end
        if all_miss and not any_open then
            local fname = intern_mod.get(ctx.pool, name_id) or "?"
            add_error(ctx, line, col, "field '" .. fname .. "' doesn't exist")
            bind_to(ctx, res_tid, ctx.T_ANY)
            return false
        end
        if any_open then field_types[#field_types + 1] = ctx.T_UNKNOWN end
        local result = #field_types == 0 and ctx.T_UNKNOWN
            or #field_types == 1 and field_types[1]
            or types_mod.make_union(ctx, field_types)
        bind_to(ctx, res_tid, result)
        return true
    end

    -- For any other type, resolve result to T_ANY
    bind_to(ctx, res_tid, ctx.T_ANY)
    return true
end

local function solve_callable(ctx, c)
    local callee_raw = c[2]   -- raw stored id (may be TAG_VAR for method calls)
    local callee_tid = find(ctx, callee_raw)
    local arg_tids   = c[3]
    local ret_tid    = c[4]
    local line, col  = c[5], c[6]
    local callee_t   = ctx.types:get(callee_tid)

    if callee_t.tag == TAG_ANY or callee_t.tag == TAG_UNKNOWN then
        bind_to(ctx, ret_tid, ctx.T_ANY)
        return true
    end

    if callee_t.tag == TAG_NEVER then
        bind_to(ctx, ret_tid, ctx.T_NEVER)
        return true
    end

    if callee_t.tag == TAG_NOMINAL then
        callee_tid = find(ctx, callee_t.data[2])
        callee_t   = ctx.types:get(callee_tid)
    end

    if callee_t.tag == TAG_VAR or callee_t.tag == TAG_ROWVAR then
        -- Unknown callee: resolve ret to T_ANY
        bind_to(ctx, ret_tid, ctx.T_ANY)
        return true
    end

    if callee_t.tag == TAG_FUNCTION then
        -- Instantiate generic function (let-polymorphism).
        -- Only needed when callee was a free var at gen time (method calls): the actual method
        -- may have FLAG_GENERIC params that need fresh vars per call site.
        -- For regular calls, gen-time instantiate in constrain.lua already created fresh vars;
        -- re-instantiating here would deep-copy already-bound types and cause recursive unification.
        local raw_t = ctx.types:get(callee_raw)
        if raw_t.tag == TAG_VAR or raw_t.tag == TAG_ROWVAR then
            callee_tid = env_mod.instantiate(ctx, callee_tid, 0)
            callee_t   = ctx.types:get(callee_tid)
        end
        -- Unify arguments with parameters
        local pl = callee_t.data[1]
        local has_names = callee_t.data[6] > 0
        for i = 0, pl - 1 do
            local exp_tid = find(ctx, ctx.lists:get(callee_t.data[0] + i))
            local act_tid = arg_tids[i + 1]
            if act_tid then
                -- Fast path: try direct assignability (preserves literal-to-literal/union).
                -- Skip when exp_tid contains free vars: try_unify is read-only and won't bind them.
                -- Skip for closed table params: the full unify path enforces the excess-field check.
                local act_r = find(ctx, act_tid)
                local et = ctx.types:get(exp_tid)
                local param_is_closed_table = et.tag == TAG_TABLE and et.data[4] < 0
                if not param_is_closed_table
                  and et.tag ~= TAG_VAR and et.tag ~= TAG_ROWVAR
                  and not contains_free_var(ctx, exp_tid)
                  and unify_mod.try_unify(ctx, act_r, exp_tid) then
                    -- ok
                else
                local widened = widen_for_sub(ctx, act_tid)
                local ok, err = unify_mod.unify(ctx, widened, exp_tid)
                if not ok then
                    -- "might also be" union message
                    local act_t = ctx.types:get(find(ctx, act_tid))
                    local union_msg = nil
                    if act_t.tag == TAG_UNION then
                        local failing = {}
                        for mi = act_t.data[0], act_t.data[0] + act_t.data[1] - 1 do
                            local mid = find(ctx, ctx.lists:get(mi))
                            if not unify_mod.try_unify(ctx, mid, exp_tid) then
                                failing[#failing + 1] = mid
                            end
                        end
                        local total = act_t.data[1]
                        if #failing > 0 and #failing < total then
                            local fail_tid = #failing == 1 and failing[1]
                                or types_mod.make_union(ctx, failing)
                            local param_name = nil
                            if has_names then
                                local name_id = ctx.lists:get(callee_t.data[5] + i)
                                param_name = intern_mod.get(ctx.pool, name_id)
                            end
                            local arg_label = param_name
                                and ("`" .. param_name .. "`")
                                or  ("argument " .. (i + 1))
                            union_msg = "function expects `" .. types_mod.display_short(ctx, exp_tid)
                                .. "`, but " .. arg_label .. " might also be `"
                                .. types_mod.display_short(ctx, fail_tid) .. "`"
                        end
                    end
                    if union_msg then
                        add_error(ctx, line, col, union_msg)
                    else
                        add_error(ctx, line, col,
                            "argument " .. (i + 1) .. ": cannot pass '"
                            .. types_mod.display_short(ctx, act_tid)
                            .. "' where '"
                            .. types_mod.display_short(ctx, exp_tid) .. "' expected"
                            .. (err and (": " .. err) or ""))
                    end
                end
                end  -- close fast-path else
            else
                -- Missing argument
                local ok = unify_mod.unify(ctx, ctx.T_NIL, exp_tid)
                if not ok then
                    add_error(ctx, line, col,
                        "missing argument " .. (i + 1) .. " (expected '"
                        .. types_mod.display_short(ctx, exp_tid) .. "')")
                end
            end
        end
        -- Unify return
        local rl = callee_t.data[3]
        if rl == 0 then
            unify_mod.unify(ctx, ret_tid, ctx.T_NIL)
        elseif rl == 1 then
            local first_ret = find(ctx, ctx.lists:get(callee_t.data[2]))
            unify_mod.unify(ctx, ret_tid, first_ret)
        else
            -- Multiple return values: assemble TAG_TUPLE so C_INDEX can project slots.
            local slots = {}
            for ri = 0, rl - 1 do
                slots[ri + 1] = find(ctx, ctx.lists:get(callee_t.data[2] + ri))
            end
            unify_mod.unify(ctx, ret_tid, types_mod.make_tuple(ctx, slots))
        end
        return true
    end

    -- Intersection: overload dispatch — first matching overload wins.
    if callee_t.tag == TAG_INTERSECTION then
        local members = {}
        for i = callee_t.data[0], callee_t.data[0] + callee_t.data[1] - 1 do
            local mid = find(ctx, ctx.lists:get(i))
            local mt  = ctx.types:get(mid)
            if mt.tag == TAG_FUNCTION then
                members[#members + 1] = { tid = mid, t = mt }
            end
        end
        if #members == 0 then
            add_error(ctx, line, col,
                "cannot call value of type '" .. types_mod.display_short(ctx, callee_tid) .. "'")
            bind_to(ctx, ret_tid, ctx.T_ANY)
            return false
        end
        -- Try each overload; first whose params all accept returns immediately.
        for _, m in ipairs(members) do
            local ft = m.t
            local ok = true
            for j = 0, ft.data[1] - 1 do
                local exp_tid = find(ctx, ctx.lists:get(ft.data[0] + j))
                local act_tid = arg_tids[j + 1]
                if act_tid and not unify_mod.try_unify(ctx, find(ctx, act_tid), exp_tid) then
                    ok = false; break
                end
            end
            if ok then
                local rl = ft.data[3]
                if rl == 0 then
                    bind_to(ctx, ret_tid, ctx.T_NIL)
                else
                    bind_to(ctx, ret_tid, find(ctx, ctx.lists:get(ft.data[2])))
                end
                return true
            end
        end
        -- No overload matched: report with candidates
        local cands = {}
        for ci, m in ipairs(members) do
            local ft = m.t
            local reasons = {}
            for j = 0, ft.data[1] - 1 do
                local exp_tid = find(ctx, ctx.lists:get(ft.data[0] + j))
                local act_tid = arg_tids[j + 1]
                if act_tid then
                    local a = find(ctx, act_tid)
                    if not unify_mod.try_unify(ctx, a, exp_tid) then
                        reasons[#reasons + 1] = "cannot pass '"
                            .. types_mod.display_short(ctx, a)
                            .. "' where '"
                            .. types_mod.display_short(ctx, exp_tid) .. "' expected"
                    end
                end
            end
            cands[#cands + 1] = "candidate " .. ci .. ": "
                .. types_mod.display_short(ctx, m.tid)
                .. (#reasons > 0 and (" — " .. reasons[1]) or "")
        end
        add_error(ctx, line, col,
            "no matching overload for '"
            .. types_mod.display_short(ctx, callee_tid) .. "':\n  "
            .. table.concat(cands, "\n  "))
        bind_to(ctx, ret_tid, ctx.T_ANY)
        return false
    end

    -- Union: ALL members must accept the argument (sound — we don't know which branch is live).
    if callee_t.tag == TAG_UNION then
        local ret_types = {}
        local fail_msgs = {}
        for i = callee_t.data[0], callee_t.data[0] + callee_t.data[1] - 1 do
            local mid = find(ctx, ctx.lists:get(i))
            local mt  = ctx.types:get(mid)
            if mt.tag ~= TAG_FUNCTION then
                fail_msgs[#fail_msgs + 1] = "union member '"
                    .. types_mod.display_short(ctx, mid) .. "' is not callable"
            else
                local member_ok = true
                for j = 0, mt.data[1] - 1 do
                    local exp_tid = find(ctx, ctx.lists:get(mt.data[0] + j))
                    local act_tid = arg_tids[j + 1]
                    if act_tid and not unify_mod.try_unify(ctx, find(ctx, act_tid), exp_tid) then
                        member_ok = false
                        fail_msgs[#fail_msgs + 1] = "argument rejected by union members: '"
                            .. types_mod.display_short(ctx, mid)
                            .. "' does not accept argument " .. (j + 1)
                        break
                    end
                end
                if member_ok then
                    local rl = mt.data[3]
                    ret_types[#ret_types + 1] = rl > 0
                        and find(ctx, ctx.lists:get(mt.data[2]))
                        or  ctx.T_NIL
                end
            end
        end
        if #fail_msgs > 0 then
            add_error(ctx, line, col, fail_msgs[1])
            bind_to(ctx, ret_tid, ctx.T_ANY)
            return false
        end
        local ret = #ret_types == 1 and ret_types[1]
            or types_mod.make_union(ctx, ret_types)
        bind_to(ctx, ret_tid, ret)
        return true
    end

    -- Non-function: error
    add_error(ctx, line, col,
        "cannot call value of type '" .. types_mod.display_short(ctx, callee_tid) .. "'")
    bind_to(ctx, ret_tid, ctx.T_ANY)
    return false
end

local function solve_arith(ctx, c)
    local op_name  = c[2]
    local lhs_tid  = find(ctx, c[3])
    local rhs_tid  = find(ctx, c[4])
    local res_tid  = c[5]
    local line, col = c[6], c[7]

    -- Check table metamethods first
    local lhs_t = ctx.types:get(lhs_tid)
    local rhs_t = ctx.types:get(rhs_tid)

    if lhs_t.tag == TAG_TABLE then
        local mm = table_meta_op_ret(ctx, lhs_tid, op_name)
        if mm then unify_mod.unify(ctx, res_tid, mm); return true end
    end
    if rhs_t.tag == TAG_TABLE then
        local mm = table_meta_op_ret(ctx, rhs_tid, op_name)
        if mm then unify_mod.unify(ctx, res_tid, mm); return true end
    end

    -- Concat: both operands must be string or number
    if op_name == "__concat" then
        local function is_concat_compat(ctx, tid)
            tid = find(ctx, tid)
            local t = ctx.types:get(tid)
            if t.tag == TAG_ANY or t.tag == TAG_UNKNOWN or t.tag == TAG_VAR or t.tag == TAG_ROWVAR then return true end
            if t.tag == TAG_STRING or t.tag == TAG_NUMBER or t.tag == TAG_INTEGER then return true end
            if t.tag == TAG_LITERAL then
                local k = t.data[0]
                return k == LIT_STRING or k == LIT_NUMBER or k == LIT_INTEGER
            end
            if t.tag == TAG_UNION then
                for i = t.data[0], t.data[0] + t.data[1] - 1 do
                    if not is_concat_compat(ctx, ctx.lists:get(i)) then return false end
                end
                return true
            end
            return false
        end
        if not is_concat_compat(ctx, lhs_tid) then
            add_error(ctx, line, col,
                "cannot concatenate type '" .. types_mod.display_short(ctx, lhs_tid) .. "'")
            unify_mod.unify(ctx, res_tid, ctx.T_STRING)
            return false
        end
        if not is_concat_compat(ctx, rhs_tid) then
            add_error(ctx, line, col,
                "cannot concatenate type '" .. types_mod.display_short(ctx, rhs_tid) .. "'")
            unify_mod.unify(ctx, res_tid, ctx.T_STRING)
            return false
        end
        unify_mod.unify(ctx, res_tid, ctx.T_STRING)
        return true
    end

    -- Length: operand must be string or table
    if op_name == "__len" then
        local function is_len_compat(ctx, tid)
            tid = find(ctx, tid)
            local t = ctx.types:get(tid)
            if t.tag == TAG_ANY or t.tag == TAG_UNKNOWN or t.tag == TAG_VAR or t.tag == TAG_ROWVAR then return true end
            if t.tag == TAG_STRING or t.tag == TAG_TABLE then return true end
            if t.tag == TAG_LITERAL then return t.data[0] == LIT_STRING end
            return false
        end
        if not is_len_compat(ctx, lhs_tid) then
            add_error(ctx, line, col,
                "cannot take length of type '" .. types_mod.display_short(ctx, lhs_tid) .. "'")
            unify_mod.unify(ctx, res_tid, ctx.T_INTEGER)
            return false
        end
        unify_mod.unify(ctx, res_tid, ctx.T_INTEGER)
        return true
    end

    -- Unary negation: same numeric result
    if op_name == "__unm" then
        if not is_numeric_tid(ctx, lhs_tid) then
            add_error(ctx, line, col,
                "cannot negate value of type '" .. types_mod.display_short(ctx, lhs_tid) .. "'")
            unify_mod.unify(ctx, res_tid, ctx.T_NUMBER)
            return false
        end
        if is_int_compat_tid(ctx, lhs_tid) then
            unify_mod.unify(ctx, res_tid, ctx.T_INTEGER)
        else
            unify_mod.unify(ctx, res_tid, ctx.T_NUMBER)
        end
        return true
    end

    -- Division/power always produces number
    if op_name == "__div" or op_name == "__pow" then
        if not is_numeric_tid(ctx, lhs_tid) or not is_numeric_tid(ctx, rhs_tid) then
            local bad = not is_numeric_tid(ctx, lhs_tid) and lhs_tid or rhs_tid
            add_error(ctx, line, col,
                "cannot perform arithmetic on '"
                .. types_mod.display_short(ctx, bad) .. "'")
        end
        unify_mod.unify(ctx, res_tid, ctx.T_NUMBER)
        return true
    end

    -- Defer if either operand is still a free type variable: callsite constraints haven't
    -- bound the params yet. The solver's convergence re-run will retry with concrete types.
    if lhs_t.tag == TAG_VAR or lhs_t.tag == TAG_ROWVAR then return end
    if rhs_t.tag == TAG_VAR or rhs_t.tag == TAG_ROWVAR then return end

    -- Integer arithmetic when both operands are int-compatible
    if not is_numeric_tid(ctx, lhs_tid) then
        add_error(ctx, line, col,
            "cannot perform arithmetic on '"
            .. types_mod.display_short(ctx, lhs_tid) .. "'")
        unify_mod.unify(ctx, res_tid, ctx.T_NUMBER)
        return false
    end
    if not is_numeric_tid(ctx, rhs_tid) then
        add_error(ctx, line, col,
            "cannot perform arithmetic on '"
            .. types_mod.display_short(ctx, rhs_tid) .. "'")
        unify_mod.unify(ctx, res_tid, ctx.T_NUMBER)
        return false
    end

    if is_int_compat_tid(ctx, lhs_tid) and is_int_compat_tid(ctx, rhs_tid) then
        unify_mod.unify(ctx, res_tid, ctx.T_INTEGER)
    else
        unify_mod.unify(ctx, res_tid, ctx.T_NUMBER)
    end
    return true
end

local function solve_compare(ctx, c)
    local lhs_tid = find(ctx, c[2])
    local rhs_tid = find(ctx, c[3])
    local line, col = c[4], c[5]

    local function is_orderable(ctx, tid)
        tid = find(ctx, tid)
        local t = ctx.types:get(tid)
        if t.tag == TAG_ANY or t.tag == TAG_UNKNOWN or t.tag == TAG_VAR or t.tag == TAG_ROWVAR then return true end
        if t.tag == TAG_NUMBER or t.tag == TAG_INTEGER then return "number" end
        if t.tag == TAG_STRING then return "string" end
        if t.tag == TAG_LITERAL then
            local k = t.data[0]
            if k == LIT_NUMBER or k == LIT_INTEGER then return "number" end
            if k == LIT_STRING then return "string" end
        end
        return false
    end

    local lk = is_orderable(ctx, lhs_tid)
    local rk = is_orderable(ctx, rhs_tid)

    if lk == false then
        add_error(ctx, line, col,
            "cannot compare '" .. types_mod.display_short(ctx, lhs_tid) .. "' with '<'")
        return false
    end
    if rk == false then
        add_error(ctx, line, col,
            "cannot compare '" .. types_mod.display_short(ctx, rhs_tid) .. "' with '<'")
        return false
    end
    -- Cross-type comparison (string vs number): error
    if lk and rk and lk ~= rk and lk ~= true and rk ~= true then
        add_error(ctx, line, col,
            "cannot compare '" .. types_mod.display_short(ctx, lhs_tid)
            .. "' with '" .. types_mod.display_short(ctx, rhs_tid) .. "'")
        return false
    end
    return true
end

local function solve_return(ctx, c)
    local val_tid   = find(ctx, c[2])
    local line, col = c[4], c[5]
    local widened   = widen_for_sub(ctx, val_tid)

    -- c[3] is the ret_var created by gen_function for this function body.
    -- If it's still a free VAR, bind directly (first return path).
    -- If it's already bound (subsequent return path), widen to union.
    -- This mirrors v2 infer_function's return-type accumulation.
    local ret_var_id = c[3]
    local ret_var_t  = ctx.types:get(ret_var_id)

    if ret_var_t.tag ~= TAG_VAR then
        -- Annotated return type: check assignability
        local expected_tid = find(ctx, ret_var_id)
        local ok, err = unify_mod.unify(ctx, widened, expected_tid)
        if not ok then
            add_error(ctx, line, col,
                "return type mismatch: cannot return '"
                .. types_mod.display_short(ctx, val_tid)
                .. "': " .. (err or "type mismatch"))
        end
        return ok
    end

    -- Operate on ret_var_id.data[2] directly — never on find(ret_var_id).
    -- Following the chain can reach a different unbound var (e.g. prescan_ret_var
    -- after C_UNIFY extended the chain). Binding that var to `widened` where
    -- widened == find(ret_var_id) creates a self-loop and hangs find().
    if ret_var_t.data[2] == -1 then
        -- First return path: bind ret_var_id directly.
        ret_var_t.data[2] = widened
    else
        -- Subsequent return path (multiple `return` stmts, or fixpoint re-pass).
        -- Use ret_var_t.data[2] to find the current concrete binding without
        -- following the full chain past what this constraint owns.
        local prev_root = find(ctx, ret_var_t.data[2])
        if prev_root ~= widened then
            -- Widen: new union of what we had and the new return value.
            local new_union = types_mod.make_union(ctx, { prev_root, widened })
            ret_var_t.data[2] = new_union
        end
        -- If prev_root == widened: idempotent, no change needed.
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Solver
-- ---------------------------------------------------------------------------

function M.solve(ctx, constraints)
    -- Dispatch table by constraint kind
    local handlers = {
        [C_UNIFY]     = solve_unify,
        [C_SUB]       = solve_sub,
        [C_INDEX]     = solve_index,
        [C_CALLABLE]  = solve_callable,
        [C_ARITH]     = solve_arith,
        [C_RETURN]    = solve_return,
        [C_COMPARE]   = solve_compare,
        [C_BOUND]     = solve_bound,
        [C_OR]        = solve_or,
    }

    -- Iterate to fixpoint (max 3 passes for recursive types).
    -- Suppress error emission on all but the final pass to avoid duplicates.
    local real_err = ctx.err
    local silent_err = { errors = {}, warnings = {} }

    for pass = 1, 3 do
        local changed = false
        -- Use silent error context on non-final passes
        ctx.err = (pass < 3) and silent_err or real_err
        silent_err.errors = {}
        silent_err.warnings = {}

        for _, c in ipairs(constraints) do
            local kind = c[1]
            local handler = handlers[kind]
            if handler then
                -- Track var state before (c[2] is a tid for all kinds except C_ARITH)
                local probe = kind ~= constrain.C_ARITH and c[2] or c[3]
                local t_before = ctx.types:get(find(ctx, probe))
                local tag_before = t_before.tag
                handler(ctx, c)
                local t_after = ctx.types:get(find(ctx, probe))
                if t_after.tag ~= tag_before then changed = true end
            end
        end
        if not changed then
            -- Converged before pass 3 — re-run once more with real_err to emit errors
            if pass < 3 then
                ctx.err = real_err
                for _, c in ipairs(constraints) do
                    local handler = handlers[c[1]]
                    if handler then handler(ctx, c) end
                end
            end
            break
        end
    end
    ctx.err = real_err
end

return M
