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

local LIT_INTEGER = defs.LIT_INTEGER
local LIT_NUMBER  = defs.LIT_NUMBER
local LIT_STRING  = defs.LIT_STRING

local C_UNIFY     = constrain.C_UNIFY
local C_SUB       = constrain.C_SUB
local C_HAS_FIELD = constrain.C_HAS_FIELD
local C_CALLABLE  = constrain.C_CALLABLE
local C_ARITH     = constrain.C_ARITH
local C_RETURN    = constrain.C_RETURN
local C_COMPARE   = constrain.C_COMPARE

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
    do
        local et = ctx.types:get(expected)
        if et.tag ~= TAG_VAR and et.tag ~= TAG_ROWVAR then
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

local function solve_has_field(ctx, c)
    local obj_tid  = find(ctx, c[2])
    local name_id  = c[3]
    local res_tid  = c[4]
    local line, col = c[5], c[6]
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
            unify_mod.unify(ctx, res_tid, find(ctx, fe.type_id))
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
    local callee_tid = find(ctx, c[2])
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
        -- This is needed for method calls where the callee was a free var at gen time:
        -- FLAG_GENERIC params (including 'self') get fresh vars so occurs check doesn't fail.
        callee_tid = env_mod.instantiate(ctx, callee_tid, 0)
        callee_t   = ctx.types:get(callee_tid)
        -- Unify arguments with parameters
        local pl = callee_t.data[1]
        local has_names = callee_t.data[6] > 0
        for i = 0, pl - 1 do
            local exp_tid = find(ctx, ctx.lists:get(callee_t.data[0] + i))
            local act_tid = arg_tids[i + 1]
            if act_tid then
                -- Fast path: try direct assignability (preserves literal-to-literal/union).
                local act_r = find(ctx, act_tid)
                local et = ctx.types:get(exp_tid)
                if et.tag ~= TAG_VAR and et.tag ~= TAG_ROWVAR
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
        else
            local first_ret = find(ctx, ctx.lists:get(callee_t.data[2]))
            unify_mod.unify(ctx, ret_tid, first_ret)
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
        [C_HAS_FIELD] = solve_has_field,
        [C_CALLABLE]  = solve_callable,
        [C_ARITH]     = solve_arith,
        [C_RETURN]    = solve_return,
        [C_COMPARE]   = solve_compare,
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
