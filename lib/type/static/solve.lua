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
local TAG_INTRINSIC    = defs.TAG_INTRINSIC
local TAG_FFIC         = defs.TAG_FFIC
local TAG_SPREAD       = defs.TAG_SPREAD

local LIT_INTEGER   = defs.LIT_INTEGER
local LIT_NUMBER    = defs.LIT_NUMBER
local LIT_STRING    = defs.LIT_STRING
local LIT_OPAQUE_KEY = defs.LIT_OPAQUE_KEY

local FLAG_OPTIONAL   = defs.FLAG_OPTIONAL
local FLAG_PRIVATE    = defs.FLAG_PRIVATE
local FLAG_OPAQUE_KEY = defs.FLAG_OPAQUE_KEY
local FLAG_SKOLEM     = defs.FLAG_SKOLEM
local band            = require("bit").band

local C_UNIFY         = constrain.C_UNIFY
local C_SUB           = constrain.C_SUB
local C_INDEX         = constrain.C_INDEX
local C_CALLABLE      = constrain.C_CALLABLE
local C_ARITH         = constrain.C_ARITH
local C_RETURN        = constrain.C_RETURN
local C_COMPARE       = constrain.C_COMPARE
local C_BOUND         = constrain.C_BOUND
local C_OR            = constrain.C_OR
local C_BIND_GENERICS = constrain.C_BIND_GENERICS
local C_CHECK_ARGS    = constrain.C_CHECK_ARGS
local C_OVERLAP       = constrain.C_OVERLAP

local find = types_mod.find

local M = {}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--: (Ctx, integer | nil, integer | nil, string) -> ()
local function add_error(ctx, line, col, msg)
    errors_mod.error(ctx.err, ctx.filename, line or 0, col or 0, msg)
end

--: (Ctx, integer | nil, integer | nil, string) -> ()
local function add_warning(ctx, line, col, msg)
    errors_mod.warning(ctx.err, ctx.filename, line or 0, col or 0, msg)
end

-- Widen literal to base type for Sub constraints.
--: (Ctx, integer) -> integer
local function widen_for_sub(ctx, tid)
    return types_mod.widen(ctx, tid)
end

-- Return true if type variable `tv_id` appears directly in the args of any
-- deferred TAG_TYPE_CALL(TAG_INTRINSIC, ...) in the return list of `callee_t`.
-- Used to decide whether to skip argument literal widening: when the return type
-- is a parameterized intrinsic (e.g. $Require<T>) and T is one of its args, the
-- caller must preserve the literal type so the intrinsic can resolve the module.
--: (Ctx, { tag: integer, data: { [integer]: integer, ... }, ... }, integer) -> boolean
local function ret_uses_tv_in_intrinsic(ctx, callee_t, tv_id)
    local rl = callee_t.data[3]
    for ri = 0, rl - 1 do
        local ret_tid = ctx.lists:get(callee_t.data[2] + ri)
        local rt = ctx.types:get(ret_tid)
        if rt.tag == TAG_TYPE_CALL then
            local callee_id = ctx.types:get(rt.data[0])
            if callee_id and callee_id.tag == TAG_INTRINSIC then
                for ai = rt.data[1], rt.data[1] + rt.data[2] - 1 do
                    if ctx.lists:get(ai) == tv_id then return true end
                end
            end
        end
    end
    return false
end

-- Evaluate a deferred TAG_TYPE_CALL(TAG_INTRINSIC, ...) after all type variables
-- in the args have been bound by the solver.  Used when a generic function's return
-- type is a parameterized intrinsic application (e.g. $Require<T>): after argument
-- unification, T is bound, so we can call the intrinsic immediately.
-- Returns the evaluated type id, or the original tid if not applicable.
--: (Ctx, integer) -> integer
local function resolve_deferred_intrinsic(ctx, tid)
    local t = ctx.types:get(tid)
    -- TAG_SPREAD wrapping a TAG_TYPE_CALL intrinsic: unwrap and evaluate.
    -- Handles `-> ...($IpairsReturn<T>)` / `-> ...($PairsReturn<T>)` return types,
    -- which are stored as TAG_SPREAD(TAG_TYPE_CALL(TAG_INTRINSIC, ...)).
    -- The result (a TAG_TUPLE iterator triple) is returned directly so the caller
    -- can unify ret_tid with the tuple, enabling C_INDEX projection in for-in.
    --
    -- Also handles TAG_SPREAD wrapping a TAG_MATCH_TYPE whose param is now concrete
    -- (param was a generic TV bound during solve_callable argument unification).
    -- PairsReturn<T>/IpairsReturn<T> match aliases use this path.
    if t.tag == TAG_SPREAD then
        local inner_tid = find(ctx, t.data[0])
        local inner_t = ctx.types:get(inner_tid)
        -- TAG_MATCH_TYPE with a now-concrete param: evaluate the match.
        -- PairsReturn<T>/IpairsReturn<T> match aliases return a 2-tuple (K, V);
        -- wrap the result in a full iterator triple so the for-in handler can
        -- extract iter_fn at slot 0.  The match param (data[0]) is the table
        -- type T used as iterator state.
        if inner_t.tag == TAG_MATCH_TYPE then
            local param_resolved = find(ctx, inner_t.data[0])
            local param_t = ctx.types:get(param_resolved)
            -- Defer only when param is an unresolved generic-alias placeholder (TAG_NAMED).
            -- TAG_VAR / TAG_ROWVAR are free type variables: evaluate the match anyway —
            -- PairsReturn/IpairsReturn catch-all arms handle non-table subjects by
            -- returning (string, unknown) or (integer, unknown).
            if param_t.tag == TAG_NAMED then
                return tid  -- alias param placeholder — still deferred
            end
            local match_mod = require("lib.type.static.match")
            local result_tid = match_mod.evaluate(ctx, inner_tid)
            -- If the result is a 2-tuple (K, V) or a union of 2-tuples,
            -- build a full iterator triple so the for-in handler's
            -- C_INDEX(triple, 0) gets an iter_fn, not a bare key type.
            -- Union-of-2-tuples arises from { ...[%K]: %V } distribution:
            -- e.g. PairsReturn<{ x: integer, y: string }> = ("x",integer)|("y",string)
            -- → collapse to K = "x"|"y", V = integer|string → iter_fn: (T, K?) -> (K,V).
            local intrinsic_mod = require("lib.type.static.intrinsic")
            local result_canon = find(ctx, result_tid)
            local result_t = ctx.types:get(result_canon)
            if result_t.tag == TAG_TUPLE and result_t.data[1] == 2 then
                local K_tid = find(ctx, ctx.lists:get(result_t.data[0]))
                local V_tid = find(ctx, ctx.lists:get(result_t.data[0] + 1))
                return intrinsic_mod.build_iter_triple(ctx, param_resolved, K_tid, V_tid)
            end
            if result_t.tag == TAG_UNION then
                -- Check if all union members are 2-tuples; if so, collapse K and V.
                local ks, vs = {}, {}
                local all_pairs = true
                for ui = result_t.data[0], result_t.data[0] + result_t.data[1] - 1 do
                    local member = ctx.types:get(find(ctx, ctx.lists:get(ui)))
                    if member.tag == TAG_TUPLE and member.data[1] == 2 then
                        ks[#ks + 1] = find(ctx, ctx.lists:get(member.data[0]))
                        vs[#vs + 1] = find(ctx, ctx.lists:get(member.data[0] + 1))
                    elseif member.tag == TAG_NEVER then
                        -- skip never members (e.g. from filtered-out ipairs arms)
                    else
                        all_pairs = false
                        break
                    end
                end
                if all_pairs and #ks > 0 then
                    local K_tid = #ks == 1 and ks[1] or types_mod.make_union(ctx, ks)
                    local V_tid = #vs == 1 and vs[1] or types_mod.make_union(ctx, vs)
                    return intrinsic_mod.build_iter_triple(ctx, param_resolved, K_tid, V_tid)
                end
                if all_pairs and #ks == 0 then
                    -- All members were never: result is never (no valid iteration)
                    return ctx.T_NEVER
                end
            end
            return result_tid
        end
        if inner_t.tag ~= TAG_TYPE_CALL then
            return tid  -- spread wrapping a non-intrinsic: leave unchanged
        end
        t = inner_t
        tid = inner_tid
    end
    if t.tag ~= TAG_TYPE_CALL then return tid end
    local callee_id = find(ctx, t.data[0])
    local ct = ctx.types:get(callee_id)
    if ct.tag ~= TAG_INTRINSIC then return tid end
    -- Collect resolved arg type ids.
    local arg_ids = {}
    for i = t.data[1], t.data[1] + t.data[2] - 1 do
        arg_ids[#arg_ids + 1] = find(ctx, ctx.lists:get(i))
    end
    local intrinsic_mod = require("lib.type.static.intrinsic")
    -- stable_id is stored in data[3]; 0 means not set.
    local stable = t.data[3]
    return intrinsic_mod.expand(ctx, ct.data[0], arg_ids, stable)
end

-- Widen a literal type to its base type at argument position.
-- Applies when binding a fresh typevar (TAG_VAR) to an argument's inferred type.
-- Rule: argument position is not a narrowing position — a literal `0` passed to a
-- generic <T>(x: T) binds T to `integer`, not to `0`.  This lets subsequent calls
-- with different integer literals (e.g. id(0); id(1)) all succeed.
-- Does NOT recurse into table fields (unlike widen_deep).
-- Does NOT apply to concrete annotated parameter types (e.g. (x: 0) -> nil).
--   LIT_INTEGER(n) -> integer
--   LIT_NUMBER(f)  -> number
--   LIT_STRING(s)  -> string
--   LIT_BOOLEAN(b) -> boolean
--   LIT_OPAQUE_KEY -> unchanged (not a user literal)
--: (Ctx, integer) -> integer
local function widen_literal(ctx, tid)
    return types_mod.widen(ctx, tid)
end

-- Resolve TAG_FFIC to ctx.T_FFI_C.
-- If tid is TAG_FFIC, returns ctx.T_FFI_C (or T_ANY as fallback).
-- Otherwise returns tid unchanged.
--: (Ctx, integer) -> integer
local function resolve_ffic(ctx, tid)
    if ctx.types:get(tid).tag == TAG_FFIC then
        -- ctx.T_FFI_C is integer? — use T_ANY when unset (no ffi initialized).
        return ctx.T_FFI_C or ctx.T_ANY
    end
    return tid
end

-- Deeply widen a type: widens top-level literals AND literal-typed table fields.
-- Used when comparing inferred (non-annotated) types in bound checks, so that
-- a table inferred as {x: 1} is treated as {x: number} for structural comparison.
--: (Ctx, integer, { [integer]: boolean | nil, ... } | nil) -> integer
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
--: (Ctx, integer, { [integer]: boolean, ... } | nil) -> boolean
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
        -- Also check vararg_id (data[4]): TAG_SPREAD(P) or a free TV for ...P.
        if t.data[4] >= 0 and contains_free_var(ctx, t.data[4], seen) then return true end
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
-- Defensive: refuse to bind a var to itself (self-loop in the union-find chain).
-- This can happen when a field-access result var feeds back into the union of field
-- types computed for an intersection/union field access (e.g. `instance._ctx` where
-- `instance` is an intersection containing an open table whose `_ctx` row-var got
-- unified with the result var). A self-loop here makes `find` non-terminating.
--: (Ctx, integer, integer) -> ()
local function bind_to(ctx, tid, target)
    local root = find(ctx, tid)
    local t = ctx.types:get(root)
    if t.tag == TAG_VAR or t.tag == TAG_ROWVAR then
        local target_root = find(ctx, target)
        if target_root == root then return end  -- would create a self-loop
        t.data[2] = target
    end
end

-- Resolve arithmetic result type from primitive operands.
-- Returns result_tid or nil if operands are not numeric.
local ARITH_OPS_SET = {
    __add = true, __sub = true, __mul = true,
    __div = true, __mod = true, __pow = true, __unm = true,
}

-- Check metamethod on a TABLE type (not primitives — prim_meta lookup not needed here).
--: (Ctx, integer, string) -> integer | nil
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

-- Resolve the result type of an operator via metamethod dispatch.
-- Checks table metamethods first, then prim_meta for primitive types.
-- TAG_UNION: all arms must support the op; result is union of arm results.
-- Returns result TID, ctx.T_ANY (any/unknown operand), or nil (not supported).
--: (Ctx, string, integer) -> integer | nil
local function meta_op_ret_impl(ctx, op_name, tid)
    tid = find(ctx, tid)
    local t = ctx.types:get(tid)
    if t.tag == TAG_ANY then return ctx.T_ANY end
    if t.tag == TAG_UNKNOWN then return nil end  -- unknown must be narrowed first
    if t.tag == TAG_TABLE then
        local r = table_meta_op_ret(ctx, tid, op_name)
        if r then return r end
        -- Tables have implicit length support (#t returns integer without needing __len)
        if op_name == "__len" then return ctx.T_INTEGER end
        return nil
    end
    if t.tag == TAG_INTERSECTION then
        -- Intersection: if any member supports the op, use its result
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            local r = meta_op_ret_impl(ctx, op_name, ctx.lists:get(i))
            if r then return r end
        end
        return nil
    end
    if t.tag == TAG_UNION then
        local parts = {}
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            local r = meta_op_ret_impl(ctx, op_name, ctx.lists:get(i))
            if r == nil then return nil end  -- any arm unsupported → whole union fails
            parts[#parts + 1] = r
        end
        return #parts == 0 and nil or types_mod.make_union(ctx, parts)
    end
    -- Primitive: map tag (or literal kind) to prim_meta entry
    local ptag = t.tag
    if ptag == TAG_LITERAL then
        local k = t.data[0]
        if k == LIT_NUMBER  then ptag = TAG_NUMBER
        elseif k == LIT_INTEGER then ptag = TAG_INTEGER
        elseif k == LIT_STRING  then ptag = TAG_STRING
        else return nil end
    elseif ptag ~= TAG_NUMBER and ptag ~= TAG_INTEGER and ptag ~= TAG_STRING then
        return nil  -- nil, boolean, etc.: no prim_meta
    end
    local pm = ctx.prim_meta[ptag]
    return pm and table_meta_op_ret(ctx, pm, op_name)
end

-- ---------------------------------------------------------------------------
-- Constraint handlers
-- ---------------------------------------------------------------------------

-- any: constraint arrays are heterogeneous (integer kind tag, then mixed integer/string
-- fields per constraint type) — no tuple/heterogeneous-array type available.
--: (Ctx, { [integer]: any, ... }) -> boolean
local function solve_unify(ctx, c)
    local t1 = find(ctx, c[2])
    local t2 = find(ctx, c[3])
    local ok, err = unify_mod.unify(ctx, t1, t2)
    if not ok then
        add_error(ctx, c[4], c[5],
            "type mismatch: cannot unify `" .. types_mod.display_short(ctx, t1)
            .. "` with `" .. types_mod.display_short(ctx, t2) .. "`"
            .. (err and (": " .. err) or ""))
    end
    return ok
end

-- any: constraint arrays are heterogeneous — see solve_unify comment.
--: (Ctx, { [integer]: any, ... }) -> boolean
local function solve_sub(ctx, c)
    local actual   = find(ctx, c[2])
    local expected = find(ctx, c[3])
    local line, col = c[4], c[5]

    -- Multi-return tuple assigned to scalar: project the first element.
    -- In Lua `local x = f()` where f() returns (T, U, ...) → x gets T.
    -- When C_SUB receives a tuple on the left but a non-tuple on the right,
    -- check the first element instead of the whole tuple.
    do
        local at = ctx.types:get(actual)
        local et = ctx.types:get(expected)
        if at.tag == TAG_TUPLE and et.tag ~= TAG_TUPLE then
            actual = at.data[1] > 0
                and find(ctx, ctx.lists:get(at.data[0]))
                or ctx.T_NIL
        end
    end

    -- Redundant cast warning: if this C_SUB was emitted by a cast expression (c[6]=true),
    -- and the inferred type is structurally identical to the asserted type, warn.
    -- Excludes any on either side: any unifies with everything so it's not "redundant",
    -- it's an explicit opt-out.
    if c[6] then
        local et = ctx.types:get(expected)
        local widened = widen_for_sub(ctx, actual)
        local wt = ctx.types:get(widened)
        if wt.tag ~= TAG_ANY and et.tag ~= TAG_ANY
            and types_mod.types_equal(ctx, widened, expected) then
            add_warning(ctx, line, col,
                "redundant type assertion: expression already has type `"
                .. types_mod.display_short(ctx, widened) .. "`")
        end
    end

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
                    "expects `" .. types_mod.display_short(ctx, expected)
                    .. "`, but argument might also be `"
                    .. types_mod.display_short(ctx, fail_tid) .. "`")
                return false
            end
        end
        add_error(ctx, line, col,
            "cannot assign `" .. types_mod.display_short(ctx, actual)
            .. "` to `" .. types_mod.display_short(ctx, expected) .. "`"
            .. (err and (": " .. err) or ""))
    end
    return ok
end

-- Solve a deferred `or` expression: C_OR = { C_OR, left_tid, right_tid, result_tid, line, col }
-- Defers while left_tid is still a free TAG_VAR (not yet resolved).
-- Once concrete: result = subtract(left, nil) | right.
-- any: constraint arrays are heterogeneous — see solve_unify comment.
--: (Ctx, { [integer]: any, ... }) -> boolean
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

-- Propagate type information from a concrete function type into a function-type bound
-- that contains free type variables.  This is the back-inference step for generic bounds
-- of the form <F: (...P) -> R>: once F is bound to a concrete function type, P and R must
-- be resolved from F's param/return structure so that subsequent constraints on P and R
-- (e.g. checking call args against ...P) can be solved.
--
-- Specifically:
--   - Return slots: unify actual's return slots with bound's return slots (binding R_fresh).
--   - Vararg TV: if bound has no regular params and its vararg slot is a free TV (P_fresh),
--     collect actual's params as a TAG_TUPLE and bind P_fresh to it.  This covers
--     <F: (...P) -> R> where P_fresh must absorb the concrete param list.
--   - Named-param form: if bound has concrete regular params (e.g. <F: (A,B)->R>), unify
--     each pair contravariantly to bind A_fresh, B_fresh from actual's params.
--: (Ctx, integer, integer) -> ()
local function propagate_function_bound(ctx, actual, resolved_bound)
    local at = ctx.types:get(find(ctx, actual))
    local bt = ctx.types:get(find(ctx, resolved_bound))
    if at.tag ~= TAG_FUNCTION or bt.tag ~= TAG_FUNCTION then return end

    -- Return slots: bind bound's free return TVs from actual's returns.
    local arl, brl = at.data[3], bt.data[3]
    local min_ret = arl < brl and arl or brl
    for i = 0, min_ret - 1 do
        local ar_id = find(ctx, ctx.lists:get(at.data[2] + i))
        local br_id = ctx.lists:get(bt.data[2] + i)
        local br = ctx.types:get(find(ctx, br_id))
        if br.tag == TAG_VAR or br.tag == TAG_ROWVAR then
            unify_mod.unify(ctx, ar_id, br_id)
        end
    end

    -- Vararg TV: if the bound's vararg slot is a free TV, collect actual's params
    -- as a tuple and bind the TV.  This handles <F: (...P) -> R> where P absorbs
    -- all of F's params as a tuple type (consistent with how (...%P) -> %R in match
    -- binds P to the full param tuple).
    local bva_id = bt.data[4]
    if bva_id >= 0 then
        local bva_root = find(ctx, bva_id)
        local bvt = ctx.types:get(bva_root)
        if bvt.tag == TAG_VAR or bvt.tag == TAG_ROWVAR then
            -- Collect actual's regular params as a tuple.
            local param_types = {}
            for i = 0, at.data[1] - 1 do
                param_types[#param_types + 1] = find(ctx, ctx.lists:get(at.data[0] + i))
            end
            local tuple_id = types_mod.make_tuple(ctx, param_types)
            unify_mod.unify(ctx, tuple_id, bva_root)
        end
    end

    -- Named-param form: if the bound has regular params that are free TVs,
    -- bind them contravariantly from actual's params (e.g. <F: (A, B) -> R>).
    local apl, bpl = at.data[1], bt.data[1]
    local min_param = apl < bpl and apl or bpl
    for i = 0, min_param - 1 do
        local ap_id = find(ctx, ctx.lists:get(at.data[0] + i))
        local bp_id = ctx.lists:get(bt.data[0] + i)
        local bp = ctx.types:get(find(ctx, bp_id))
        -- Contravariant: bind bound's free param TV from actual's param.
        if bp.tag == TAG_VAR or bp.tag == TAG_ROWVAR then
            unify_mod.unify(ctx, ap_id, bp_id)
        end
    end
end

-- Solve a forall bound check: C_BOUND = { C_BOUND, fresh_tv_id, bound_type_id, line, col }
-- Defers while fresh_tv is still a free TAG_VAR (not yet bound at call site).
-- Once bound:
--   - For TAG_MATCH_TYPE bounds: evaluate the match with the actual type as subject.
--     If the result is TAG_NEVER, the constraint is violated.
--   - For other bounds: check try_unify(widen(actual), bound).
-- Skips enforcement when the bound is TAG_NAMED (unapplied kind constraint).
-- any: constraint arrays are heterogeneous — see solve_unify comment.
--: (Ctx, { [integer]: any, ... }) -> boolean
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
                    "type `" .. types_mod.display_short(ctx, actual)
                    .. "` has kind *, expected kind " .. kind_arrows
                    .. " (bound `" .. bound_name .. "` requires arity "
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
                "type argument `" .. types_mod.display_short(ctx, actual)
                .. "` does not satisfy constraint `"
                .. types_mod.display_short(ctx, find(ctx, bound_id)) .. "`")
            return false
        end
        return true
    end

    -- `function` bound (<F: function> or <F: (...P) -> R>).
    -- Two sub-cases:
    --   a) Bound has no free TVs (<F: function>): kind-check only.
    --      The annotation `function` keyword resolves to `(...any) -> ()` which would
    --      reject any specific function type under structural unification, so we only
    --      verify that the actual type is callable.  TAG_ANY is accepted.
    --   b) Bound contains free TVs (<F: (...P) -> R>): kind-check PLUS back-propagation.
    --      After confirming the actual is a function, decompose the concrete function type
    --      into the bound's free slots (P, R) so subsequent constraints on those TVs can
    --      be solved.  This is the step that enables <F: (...P) -> R, P, R>(f: F, ...P) -> R
    --      to properly bind P and R at each call site.
    if bt.tag == TAG_FUNCTION then
        local wa_tid = find(ctx, widen_deep(ctx, actual))
        local wa_tag = ctx.types:get(wa_tid).tag
        if wa_tag ~= TAG_FUNCTION and wa_tag ~= TAG_ANY and wa_tag ~= TAG_UNKNOWN then
            add_error(ctx, line, col,
                "type argument `" .. types_mod.display_short(ctx, actual)
                .. "` does not satisfy constraint `"
                .. (contains_free_var(ctx, resolved_bound) and
                    types_mod.display_short(ctx, find(ctx, bound_id)) or "function") .. "`")
            return false
        end
        -- Sub-case (b): back-propagate concrete param/return types into bound's free TVs.
        if wa_tag == TAG_FUNCTION and contains_free_var(ctx, resolved_bound) then
            propagate_function_bound(ctx, wa_tid, resolved_bound)
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
            "type argument `" .. types_mod.display_short(ctx, actual)
            .. "` does not satisfy constraint `"
            .. types_mod.display_short(ctx, resolved_bound) .. "`")
        return false
    end
    return true
end

-- Solve a slot/field index: C_INDEX = { C_INDEX, obj_tid, key_tid, res_tid, line, col }
-- key_tid: TAG_LITERAL(LIT_STRING, name_id) for named field; TAG_LITERAL(LIT_INTEGER, slot) for tuple slot.
-- any: constraint arrays are heterogeneous — see solve_unify comment.
--: (Ctx, { [integer]: any, ... }) -> boolean
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

        if obj_t.tag == TAG_ANY then
            bind_to(ctx, res_tid, ctx.T_ANY)
            return true
        end
        if obj_t.tag == TAG_UNKNOWN then
            add_error(ctx, line, col, "value of type `unknown` must be narrowed before indexing")
            bind_to(ctx, res_tid, ctx.T_ANY)
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
        if obj_t.tag == TAG_ANY then
            bind_to(ctx, res_tid, ctx.T_ANY)
            return true
        end
        if obj_t.tag == TAG_UNKNOWN then
            bind_to(ctx, res_tid, ctx.T_UNKNOWN)
            return true
        end
        if obj_t.tag == TAG_NEVER then
            bind_to(ctx, res_tid, ctx.T_NEVER)
            return true
        end
        -- Vararg spread (e.g. ...(string|nil) from string.match): each slot is
        -- the inner element type. This covers method calls like str:match(pat)
        -- where the return type resolves to TAG_SPREAD before C_INDEX fires.
        if obj_t.tag == TAG_SPREAD then
            bind_to(ctx, res_tid, find(ctx, obj_t.data[0]))
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
    local obj_tid  = resolve_ffic(ctx, find(ctx, obj_tid_raw))
    local obj_t = ctx.types:get(obj_tid)

    if obj_t.tag == TAG_ANY then
        bind_to(ctx, res_tid, ctx.T_ANY)
        return true
    end
    if obj_t.tag == TAG_UNKNOWN then
        add_error(ctx, line, col, "value of type `unknown` must be narrowed before indexing")
        bind_to(ctx, res_tid, ctx.T_ANY)
        return true
    end

    if obj_t.tag == TAG_NEVER then
        bind_to(ctx, res_tid, ctx.T_NEVER)
        return true
    end

    -- Nominal: check opaque view, then unwrap.
    -- TAG_NOMINAL types are produced either by $Opaque or by --:: newtype.
    -- $Opaque nominals are tracked in ctx._opaque_nominals.
    --   Two-arg: ctx._opaque_view[identity] = U; field access resolves through U.
    --   One-arg: no view entry; field access is always an error.
    -- newtype nominals: fall through to unwrap as usual.
    if obj_t.tag == TAG_NOMINAL then
        local nom_identity = obj_t.data[1]
        if ctx._opaque_nominals and ctx._opaque_nominals[nom_identity] then
            local fname = intern_mod.get(ctx.pool, name_id) or "?"
            if ctx._opaque_view and ctx._opaque_view[nom_identity] ~= nil then
                -- Two-arg $Opaque<T, U>: resolve field through U.
                local view_tid = ctx._opaque_view[nom_identity]
                local vfe = types_mod.table_field(ctx, view_tid, name_id)
                if vfe then
                    local ft = find(ctx, vfe.type_id)
                    if band(vfe.flags, FLAG_OPTIONAL) ~= 0 then
                        ft = types_mod.make_union(ctx, { ft, ctx.T_NIL })
                    end
                    unify_mod.unify(ctx, res_tid, ft)
                    return true
                else
                    add_error(ctx, line, col,
                        "field `" .. fname .. "` is not exposed by opaque type — use unseal")
                    bind_to(ctx, res_tid, ctx.T_ANY)
                    return false
                end
            else
                -- One-arg $Opaque<T>: no field access.
                add_error(ctx, line, col,
                    "cannot access fields of opaque type — use unseal to recover inner type")
                bind_to(ctx, res_tid, ctx.T_ANY)
                return false
            end
        end
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
            add_error(ctx, line, col, "no method `" .. fname .. "` on this type")
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
                        "field `" .. fname .. "` is private to `" .. origin .. "`")
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
        -- Spread field fallback: check { ...T } placeholders when named field not found.
        -- Handles { ...(A | B) } where the union wasn't distributed at substitution time.
        for si = obj_t.data[0], obj_t.data[0] + obj_t.data[1] - 1 do
            local sfe = ctx.fields:get(ctx.lists:get(si))
            if sfe.name_id == -1 then
                local sp_t = ctx.types:get(find(ctx, sfe.type_id))
                if sp_t.tag == TAG_SPREAD then
                    local inner_tid = find(ctx, sp_t.data[0])
                    local inner_t   = ctx.types:get(inner_tid)
                    if inner_t.tag == TAG_TABLE then
                        local sfe2 = types_mod.table_field(ctx, inner_tid, name_id)
                        if sfe2 then
                            local ft = find(ctx, sfe2.type_id)
                            if band(sfe2.flags, defs.FLAG_OPTIONAL) ~= 0 then
                                ft = types_mod.make_union(ctx, { ft, ctx.T_NIL })
                            end
                            unify_mod.unify(ctx, res_tid, ft)
                            return true
                        end
                    elseif inner_t.tag == TAG_UNION then
                        -- Collect field types from all union arms that have it.
                        local field_types = {}
                        local all_have   = true
                        for ai = inner_t.data[0], inner_t.data[0] + inner_t.data[1] - 1 do
                            local arm_tid = find(ctx, ctx.lists:get(ai))
                            local arm_t   = ctx.types:get(arm_tid)
                            if arm_t.tag == TAG_TABLE then
                                local afe = types_mod.table_field(ctx, arm_tid, name_id)
                                if afe then
                                    field_types[#field_types + 1] = find(ctx, afe.type_id)
                                else
                                    all_have = false
                                end
                            else
                                all_have = false
                            end
                        end
                        if #field_types > 0 then
                            local ft = types_mod.make_union(ctx, field_types)
                            if not all_have then
                                ft = types_mod.make_union(ctx, { ft, ctx.T_NIL })
                            end
                            unify_mod.unify(ctx, res_tid, ft)
                            return true
                        end
                    end
                end
            end
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
        add_error(ctx, line, col, "field `" .. fname .. "` doesn't exist")
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

    -- ---------------------------------------------------------------------------
    -- Recursive field lookup: distributivity over union and intersection.
    --
    -- field_access_on(ctx, mid, name_id) -> (field_types, open_miss, closed_miss, any_escape)
    --
    -- Distributes field access over compound types:
    --   (A & B).x  = A.x & B.x  (collect from all members)
    --   (A | B).x  = A.x | B.x  (collect from each arm; closed_miss if any arm misses)
    --   (A & B) | C  -> recurse into (A & B) then C
    --   (A | B) & C  -> recurse into (A | B) then C
    --
    -- Returns:
    --   field_types  - list of resolved type IDs found so far (may be appended to)
    --   open_miss    - true if any arm was open and might have the field
    --   closed_miss  - true if any arm was closed and definitely lacks the field
    --   any_escape   - true if any arm was TAG_ANY (caller should return T_ANY immediately)
    --
    -- Implemented as a local forward-declared function so union/intersection handlers
    -- can call each other recursively without hoisting all code.

    -- forward declaration so union and intersection lambdas can cross-call
    local field_access_on
    field_access_on = function(ctx2, mid, nid)
        mid = find(ctx2, mid)
        local mt = ctx2.types:get(mid)
        -- TAG_FFIC: resolve to actual C table first
        if mt.tag == TAG_FFIC then
            local resolved_mid = resolve_ffic(ctx2, mid)
            local resolved_mt  = ctx2.types:get(resolved_mid)
            if resolved_mt.tag == TAG_TABLE then
                local fe = types_mod.table_field(ctx2, resolved_mid, nid)
                if fe then
                    return { find(ctx2, fe.type_id) }, false, false, false
                else
                    return {}, false, true, false
                end
            else
                -- $FfiC not yet initialised: T_ANY fallback
                return {}, false, false, true
            end
        end
        if mt.tag == TAG_ANY then
            return {}, false, false, true
        end
        if mt.tag == TAG_UNKNOWN then
            return { ctx2.T_UNKNOWN }, false, false, false
        end
        if mt.tag == TAG_VAR or mt.tag == TAG_ROWVAR then
            return {}, true, false, false
        end
        if mt.tag == TAG_TABLE then
            local fe = types_mod.table_field(ctx2, mid, nid)
            if fe then
                return { find(ctx2, fe.type_id) }, false, false, false
            elseif mt.data[4] >= 0 then
                return {}, true, false, false
            else
                return {}, false, true, false
            end
        end
        if mt.tag == TAG_INTERSECTION then
            -- Distribute: field must be reachable from each member that is a closed type.
            -- Collect types from all members; any_open means result may contain unknown.
            local ftypes, any_open2, all_miss2 = {}, false, true
            for i = mt.data[0], mt.data[0] + mt.data[1] - 1 do
                local arm_mid = ctx2.lists:get(i)
                local arm_ft, arm_open, arm_closed, arm_any = field_access_on(ctx2, arm_mid, nid)
                if arm_any then return {}, false, false, true end
                for _, t in ipairs(arm_ft) do ftypes[#ftypes + 1] = t end
                if arm_open   then any_open2 = true; all_miss2 = false end
                if #arm_ft > 0 then all_miss2 = false end
                -- arm_closed means this member definitively lacks the field; for an
                -- intersection that is a miss (the intersection still contributes closed_miss
                -- only when ALL members miss — but since we are inside a union arm, we just
                -- treat a closed-table member that lacks the field as contributing nothing,
                -- and if all intersection members miss we treat the intersection as missing).
                if arm_closed and #arm_ft == 0 and not arm_open then
                    -- this member definitively lacks the field; keep all_miss as-is
                else
                    -- arm has something (field or open) — already updated above
                end
            end
            if all_miss2 and not any_open2 then
                return {}, false, true, false
            end
            if any_open2 then ftypes[#ftypes + 1] = ctx2.T_UNKNOWN end
            return ftypes, false, false, false
        end
        if mt.tag == TAG_UNION then
            -- Distribute: collect from each arm.
            local ftypes, any_open2, any_closed2 = {}, false, false
            for i = mt.data[0], mt.data[0] + mt.data[1] - 1 do
                local arm_mid = ctx2.lists:get(i)
                local arm_ft, arm_open, arm_closed, arm_any = field_access_on(ctx2, arm_mid, nid)
                if arm_any then return {}, false, false, true end
                for _, t in ipairs(arm_ft) do ftypes[#ftypes + 1] = t end
                if arm_open   then any_open2   = true end
                if arm_closed then any_closed2 = true end
            end
            return ftypes, any_open2, any_closed2, false
        end
        -- All other types (function, tuple, nominal, etc.) lack the field
        return {}, false, true, false
    end

    if obj_t.tag == TAG_UNION then
        local field_types = {}
        local closed_miss = false
        local open_miss   = false
        for i = obj_t.data[0], obj_t.data[0] + obj_t.data[1] - 1 do
            local mid = ctx.lists:get(i)
            local arm_ft, arm_open, arm_closed, arm_any = field_access_on(ctx, mid, name_id)
            if arm_any then
                bind_to(ctx, res_tid, ctx.T_ANY)
                return true
            end
            for _, t in ipairs(arm_ft) do field_types[#field_types + 1] = t end
            if arm_open   then open_miss   = true end
            if arm_closed then closed_miss = true end
        end
        if #field_types > 0 or open_miss or closed_miss then
            if open_miss   then field_types[#field_types + 1] = ctx.T_UNKNOWN end
            if closed_miss then field_types[#field_types + 1] = ctx.T_NIL end
            local result = types_mod.make_union(ctx, field_types)
            bind_to(ctx, res_tid, result)
            return true
        end
        local fname = intern_mod.get(ctx.pool, name_id) or "?"
        add_error(ctx, line, col, "field `" .. fname .. "` doesn't exist in union")
        bind_to(ctx, res_tid, ctx.T_ANY)
        return false
    end

    if obj_t.tag == TAG_INTERSECTION then
        -- Field must exist in at least one member; if any open member, result may exist.
        -- Closed members that lack the field are simply not a source of it (the value
        -- satisfies all members, so it may still carry the field from another member).
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
            elseif mt.tag == TAG_UNKNOWN then
                -- unknown in an intersection: result is unknown (requires narrowing at use site)
                field_types[#field_types + 1] = ctx.T_UNKNOWN
                all_miss = false
            elseif mt.tag == TAG_VAR or mt.tag == TAG_ROWVAR then
                any_open = true
                all_miss = false
            end
        end
        if all_miss and not any_open then
            local fname = intern_mod.get(ctx.pool, name_id) or "?"
            add_error(ctx, line, col, "field `" .. fname .. "` doesn't exist")
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

-- any: constraint arrays are heterogeneous — see solve_unify comment.
--: (Ctx, { [integer]: any, ... }) -> boolean
local function solve_callable(ctx, c)
    local callee_raw = c[2]   -- raw stored id (may be TAG_VAR for method calls)
    local callee_tid = find(ctx, callee_raw)
    local arg_tids   = c[3]
    local ret_tid    = c[4]
    local line, col  = c[5], c[6]
    local callee_t   = ctx.types:get(callee_tid)

    if callee_t.tag == TAG_ANY then
        bind_to(ctx, ret_tid, ctx.T_ANY)
        return true
    end
    if callee_t.tag == TAG_UNKNOWN then
        add_error(ctx, line, col, "value of type `unknown` must be narrowed before calling")
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
        -- Named-param generic bound deferral (<F: (A,B)->R, A, B, R>).
        -- When first called, F is a free TV that gets bound by processing param 0 (f: F).
        -- Params A and B are ALSO free TVs at this point — C_BOUND hasn't fired yet to
        -- back-propagate their concrete values from F's bound.  If we process A/B now,
        -- they absorb any arg type with no error.
        -- Strategy: if param 0 is a free TV AND some param at i>0 is also a free TV, AND
        -- arg 0 is a function type, then:
        --   (a) process only param 0 (to bind F so C_BOUND can decompose it), then
        --   (b) return false to defer.  The deferred-constraint system re-enables this
        --       constraint when progress is made (C_BOUND fires → tag change → changed=true
        --       → deferred constraints retry with concrete A/B so wrong-typed args are
        --       detected).
        -- Guard: only defer when param 0 binds to a TAG_FUNCTION (a bound like (A,B)->R).
        -- Monomorphic functions (e.g. add(a,b)) have non-function-typed args at param 0
        -- and must NOT be deferred — body constraints (C_ARITH etc.) are emitted before
        -- C_CALLABLE in constraint order; if C_CALLABLE defers without binding all params,
        -- those body constraints see unbound TVs on the final error pass and silently skip.
        do
            local exp0_t = ctx.types:get(find(ctx, ctx.lists:get(callee_t.data[0])))
            -- Param 0 must itself be a free TV (F_fresh) for the deferral to apply.
            if pl > 1 and (exp0_t.tag == TAG_VAR or exp0_t.tag == TAG_ROWVAR) then
                local has_unbound_named_param = false
                for si = 1, pl - 1 do
                    local st = ctx.types:get(find(ctx, ctx.lists:get(callee_t.data[0] + si)))
                    if st.tag == TAG_VAR or st.tag == TAG_ROWVAR then
                        has_unbound_named_param = true
                        break
                    end
                end
                if has_unbound_named_param then
                    -- Defer if param 0's TV has a pending C_BOUND constraint.
                    -- C_BOUND will back-propagate concrete types from the bound once param 0
                    -- is bound. This generalises the old TAG_FUNCTION check: any compound bound
                    -- (function, table, etc.) will have a C_BOUND; checking the tag directly
                    -- would miss non-function bounds like <T: { x: A, y: B }, A, B>.
                    local param0_tv = find(ctx, ctx.lists:get(callee_t.data[0]))
                    local has_pending_bound = false
                    if ctx._constraints then
                        for _, bc in ipairs(ctx._constraints) do
                            if bc[1] == C_BOUND and find(ctx, bc[2]) == param0_tv then
                                has_pending_bound = true
                                break
                            end
                        end
                    end
                    if has_pending_bound then
                        local act0 = arg_tids[1]
                        if act0 then
                            -- Bind param 0 from arg 0, then defer A/B checking until C_BOUND fires.
                            unify_mod.unify(ctx, widen_literal(ctx, act0), find(ctx, ctx.lists:get(callee_t.data[0])))
                        end
                        return false
                    end
                end
            end
        end
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
                -- Argument-literal widening (argument position is not a narrowing position).
                -- When exp_tid is a fresh TAG_VAR (generic instantiation), widen the actual
                -- to its base type before binding so that e.g. id(0); id(1) both pass with
                -- T = integer rather than T = LIT_INTEGER(0) on the first call.
                -- For concrete annotated params (e.g. (x: 0) -> nil), the fast path already
                -- handles direct assignability; we reach here only when fast path is skipped
                -- (TAG_VAR, closed table, or contains free vars), so widening is correct in
                -- all three cases.
                -- Exemption: when this TAG_VAR appears as an arg to a parameterized intrinsic
                -- in the return type (e.g. $Require<T>), the literal must be preserved so the
                -- intrinsic can resolve the concrete type.  Skip widening in that case.
                local skip_widen = (et.tag == TAG_VAR)
                    and ret_uses_tv_in_intrinsic(ctx, callee_t, exp_tid)
                local widened = skip_widen and find(ctx, act_tid)
                    or (et.tag == TAG_VAR or et.tag == TAG_ROWVAR)
                    and widen_literal(ctx, act_tid)
                    or  widen_for_sub(ctx, act_tid)
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
                            local pn = param_name or ""
                            local arg_label = param_name
                                and ("`" .. pn .. "`")
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
                            "argument " .. (i + 1) .. ": cannot pass `"
                            .. types_mod.display_short(ctx, act_tid)
                            .. "` where `"
                            .. types_mod.display_short(ctx, exp_tid) .. "` expected"
                            .. (err and (": " .. err) or ""))
                    end
                end
                end  -- close fast-path else
            else
                -- Missing argument
                local ok = unify_mod.unify(ctx, ctx.T_NIL, exp_tid)
                if not ok then
                    add_error(ctx, line, col,
                        "missing argument " .. (i + 1) .. " (expected `"
                        .. types_mod.display_short(ctx, exp_tid) .. "`)")
                end
            end
        end
        -- Handle extra args against the function's vararg slot (data[4]).
        -- This covers calls like wrap(f, 5) where wrap is <F: (...P)->R, P, R>(f: F, ...P)->R:
        -- after C_BOUND back-propagates P from F's concrete params, P_fresh is a TAG_TUPLE
        -- and each extra arg must satisfy the corresponding tuple slot.
        local va_id = callee_t.data[4]
        if va_id >= 0 and #arg_tids > pl then
            local va_resolved = find(ctx, va_id)
            local vat = ctx.types:get(va_resolved)
            -- Defer if the vararg TV is still unbound (P not yet back-propagated).
            if vat.tag == TAG_VAR or vat.tag == TAG_ROWVAR then
                return false  -- retry later
            end
            if vat.tag == TAG_TUPLE then
                -- Extra args must match tuple slots in order.
                for ei = pl, #arg_tids - 1 do
                    local slot_idx = ei - pl  -- 0-based index into the tuple
                    local exp_slot
                    if slot_idx < vat.data[1] then
                        exp_slot = find(ctx, ctx.lists:get(vat.data[0] + slot_idx))
                    else
                        exp_slot = ctx.T_NIL  -- more args than tuple slots
                    end
                    local act_tid = arg_tids[ei + 1]
                    local ok, err = unify_mod.unify(ctx, widen_literal(ctx, act_tid), exp_slot)
                    if not ok then
                        add_error(ctx, line, col,
                            "argument " .. (ei + 1) .. ": cannot pass `"
                            .. types_mod.display_short(ctx, act_tid)
                            .. "` where `"
                            .. types_mod.display_short(ctx, exp_slot) .. "` expected"
                            .. (err and (": " .. err) or ""))
                    end
                end
            end
            -- If vararg is TAG_ANY or other non-tuple type, extra args are accepted silently.
        end
        -- Unify return
        local rl = callee_t.data[3]
        if rl == 0 then
            unify_mod.unify(ctx, ret_tid, ctx.T_NIL)
        elseif rl == 1 then
            local first_ret = find(ctx, ctx.lists:get(callee_t.data[2]))
            -- Parameterized intrinsic return: evaluate deferred TAG_TYPE_CALL(TAG_INTRINSIC,...)
            -- now that all type variables from argument unification are bound.
            -- E.g. $Require<T> where T was bound to LIT_STRING("mod") during param unification.
            first_ret = resolve_deferred_intrinsic(ctx, first_ret)
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
                "cannot call value of type `" .. types_mod.display_short(ctx, callee_tid) .. "`")
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
                        reasons[#reasons + 1] = "cannot pass `"
                            .. types_mod.display_short(ctx, a)
                            .. "` where `"
                            .. types_mod.display_short(ctx, exp_tid) .. "` expected"
                    end
                end
            end
            cands[#cands + 1] = "candidate " .. ci .. ": "
                .. types_mod.display_short(ctx, m.tid)
                .. (#reasons > 0 and (" — " .. reasons[1]) or "")
        end
        add_error(ctx, line, col,
            "no matching overload for `"
            .. types_mod.display_short(ctx, callee_tid) .. "`:\n  "
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
                fail_msgs[#fail_msgs + 1] = "union member `"
                    .. types_mod.display_short(ctx, mid) .. "` is not callable"
            else
                local member_ok = true
                for j = 0, mt.data[1] - 1 do
                    local exp_tid = find(ctx, ctx.lists:get(mt.data[0] + j))
                    local act_tid = arg_tids[j + 1]
                    if act_tid and not unify_mod.try_unify(ctx, find(ctx, act_tid), exp_tid) then
                        member_ok = false
                        fail_msgs[#fail_msgs + 1] = "argument rejected by union members: `"
                            .. types_mod.display_short(ctx, mid)
                            .. "` does not accept argument " .. (j + 1)
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
        "cannot call value of type `" .. types_mod.display_short(ctx, callee_tid) .. "`")
    bind_to(ctx, ret_tid, ctx.T_ANY)
    return false
end

-- any: constraint arrays are heterogeneous — see solve_unify comment.
-- c[2] is a string (op_name like "__add"), remaining fields are integers.
--: (Ctx, { [integer]: any, ... }) -> boolean | nil
local function solve_arith(ctx, c)
    local op_name  = c[2]
    local lhs_tid  = find(ctx, c[3])
    local rhs_tid  = find(ctx, c[4])
    local res_tid  = c[5]
    local line, col = c[6], c[7]

    -- Defer if either operand is not yet resolved (callsite hasn't bound params yet).
    local lhs_t = ctx.types:get(lhs_tid)
    local rhs_t = ctx.types:get(rhs_tid)
    if lhs_t.tag == TAG_VAR or lhs_t.tag == TAG_ROWVAR then return end
    if rhs_t.tag == TAG_VAR or rhs_t.tag == TAG_ROWVAR then return end

    -- Auto-unwrap TAG_NOMINAL (newtype) for metamethod dispatch — mirrors the
    -- field-access unwrap. Newtypes inherit their underlying type's operators;
    -- the result type is the underlying type's metamethod result, which means
    -- arithmetic "promotes" newtypes back to their underlying type. Walk down
    -- recursively in case of nested newtypes.
    while lhs_t.tag == TAG_NOMINAL do
        lhs_tid = find(ctx, lhs_t.data[2])
        lhs_t   = ctx.types:get(lhs_tid)
    end
    while rhs_t.tag == TAG_NOMINAL do
        rhs_tid = find(ctx, rhs_t.data[2])
        rhs_t   = ctx.types:get(rhs_tid)
    end

    -- Dispatch via metamethod lookup: prim_meta for primitives, table meta for tables.
    -- Both operands must support the operation; result is the union of their declared
    -- return types (integer|integer→integer, integer|number→number via make_union subsumption).
    local lr = meta_op_ret_impl(ctx, op_name, lhs_tid)
    local rr = meta_op_ret_impl(ctx, op_name, rhs_tid)

    if lr == nil or rr == nil then
        local bad_tid = (lr == nil) and lhs_tid or rhs_tid
        if op_name == "__concat" then
            add_error(ctx, line, col,
                "cannot concatenate type `" .. types_mod.display_short(ctx, bad_tid) .. "`")
            unify_mod.unify(ctx, res_tid, ctx.T_STRING)
        elseif op_name == "__len" then
            add_error(ctx, line, col,
                "cannot take length of type `" .. types_mod.display_short(ctx, bad_tid) .. "`")
            unify_mod.unify(ctx, res_tid, ctx.T_INTEGER)
        elseif op_name == "__unm" then
            add_error(ctx, line, col,
                "cannot negate value of type `" .. types_mod.display_short(ctx, bad_tid) .. "`")
            unify_mod.unify(ctx, res_tid, ctx.T_NUMBER)
        else
            add_error(ctx, line, col,
                "cannot perform arithmetic on `" .. types_mod.display_short(ctx, bad_tid) .. "`")
            unify_mod.unify(ctx, res_tid, ctx.T_NUMBER)
        end
        return false
    end

    -- Both sides support the op. Union results: T_ANY wins, else make_union for widening.
    if lr == ctx.T_ANY or rr == ctx.T_ANY then
        unify_mod.unify(ctx, res_tid, ctx.T_ANY)
    else
        unify_mod.unify(ctx, res_tid, types_mod.make_union(ctx, {lr, rr}))
    end
    return true
end

-- any: constraint arrays are heterogeneous — see solve_unify comment.
--: (Ctx, { [integer]: any, ... }) -> boolean
local function solve_compare(ctx, c)
    local lhs_tid = find(ctx, c[2])
    local rhs_tid = find(ctx, c[3])
    local line, col = c[4], c[5]

    local function is_orderable(ctx, tid)
        tid = find(ctx, tid)
        local t = ctx.types:get(tid)
        -- Unwrap TAG_NOMINAL (newtype) — comparisons act on the underlying type.
        while t.tag == TAG_NOMINAL do
            tid = find(ctx, t.data[2])
            t   = ctx.types:get(tid)
        end
        if t.tag == TAG_ANY or t.tag == TAG_UNKNOWN or t.tag == TAG_VAR or t.tag == TAG_ROWVAR then return true end
        if t.tag == TAG_NUMBER or t.tag == TAG_INTEGER then return "number" end
        if t.tag == TAG_STRING then return "string" end
        if t.tag == TAG_LITERAL then
            local k = t.data[0]
            if k == LIT_NUMBER or k == LIT_INTEGER then return "number" end
            if k == LIT_STRING then return "string" end
        end
        -- TAG_UNION: orderable iff every arm is orderable and they agree on the
        -- kind ("number" vs "string").  A phi-join of two integer branches can
        -- produce an `integer | integer` union (different unresolved TAG_VAR IDs
        -- that both resolve to T_INTEGER after solving); without this branch,
        -- such unions would always produce a false "cannot compare" error.
        if t.tag == TAG_UNION then
            local kind = nil  -- "number" or "string" once determined
            for i = t.data[0], t.data[0] + t.data[1] - 1 do
                -- lists:get returns unknown in non-self-check mode; cast to integer
                -- so the recursive call doesn't widen is_orderable's tid parameter type.
                local mk = is_orderable(ctx, ctx.lists:get(i) --[[:! integer]])
                if mk == false then return false end  -- non-orderable arm
                if mk == true then return true end    -- any/unknown/var arm → defer to caller
                -- mk is "number" or "string"
                if kind == nil then kind = mk
                elseif kind ~= mk then return false end  -- mixed number/string
            end
            return kind or false  -- empty union → false
        end
        return false
    end

    local lk = is_orderable(ctx, lhs_tid)
    local rk = is_orderable(ctx, rhs_tid)

    if lk == false then
        add_error(ctx, line, col,
            "cannot compare `" .. types_mod.display_short(ctx, lhs_tid) .. "` with `<`")
        return false
    end
    if rk == false then
        add_error(ctx, line, col,
            "cannot compare `" .. types_mod.display_short(ctx, rhs_tid) .. "` with `<`")
        return false
    end
    -- Cross-type comparison (string vs number): error
    if lk and rk and lk ~= rk and lk ~= true and rk ~= true then
        add_error(ctx, line, col,
            "cannot compare `" .. types_mod.display_short(ctx, lhs_tid)
            .. "` with `" .. types_mod.display_short(ctx, rhs_tid) .. "`")
        return false
    end
    return true
end

-- any: constraint arrays are heterogeneous — see solve_unify comment.
--: (Ctx, { [integer]: any, ... }) -> boolean
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

    -- A FLAG_SKOLEM TAG_VAR is a skolemized generic return type (from a generic
    -- function body check).  Treat it as an annotated type for assignability checking:
    -- the body must produce a value assignable to the abstract type parameter.
    -- Skolem vars cannot be bound (bind_var rejects them), so no self-loop is possible.
    local is_skolem_ret = ret_var_t.tag == TAG_VAR and band(ret_var_t.flags, FLAG_SKOLEM) ~= 0
    if ret_var_t.tag ~= TAG_VAR or is_skolem_ret then
        -- Annotated return type (or skolem): check assignability.
        -- TAG_SPREAD in return position means multi-return; unwrap to the inner type
        -- so that `return 1` is checked against `integer`, not `...integer`.
        local expected_tid = find(ctx, ret_var_id)
        local et = ctx.types:get(expected_tid)
        if et.tag == TAG_SPREAD then
            expected_tid = find(ctx, et.data[0])
            et = ctx.types:get(expected_tid)
        end
        -- When the annotated return is a TAG_TUPLE (multi-return packed as tuple)
        -- and the actual value is also a TAG_TUPLE, unify them directly — this
        -- handles `return p` where p: Parameters<typeof f> = (integer, string).
        -- When the actual value is NOT a tuple (normal `return a, b` path where
        -- only the first expression is emitted via C_RETURN), use slot 0 of the
        -- expected tuple for the per-slot check.
        if et.tag == TAG_TUPLE and ctx.types:get(widened).tag ~= TAG_TUPLE then
            -- Normal multi-return: `return a, b` — ret_tids[1] = a, check against slot 0.
            if et.data[1] > 0 then
                expected_tid = find(ctx, ctx.lists:get(et.data[0]))
            end
        end
        local ok, err = unify_mod.unify(ctx, widened, expected_tid)
        if not ok then
            add_error(ctx, line, col,
                "return type mismatch: cannot return `"
                .. types_mod.display_short(ctx, val_tid)
                .. "`: " .. (err or "type mismatch"))
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

-- any: constraint arrays are heterogeneous — see solve_unify comment.
-- Binds free type variables in the callee's param slots from call arguments.
-- Runs before C_CHECK_ARGS so that C_BOUND can fire and back-propagate named-param
-- TVs (A, B, R) before C_CHECK_ARGS checks argument types against them.
-- For non-function callees (TAG_ANY/UNKNOWN/NEVER/VAR/INTERSECTION/UNION): no-op.
--
-- Deferral rule: after binding, if param 0 was a free TV that got bound to a
-- function type AND some later param is still a free TV, return false.  This lets
-- C_BOUND back-propagate the concrete param/return types from that function before
-- C_CHECK_ARGS verifies argument compatibility.  Without this step, C_BIND_GENERICS
-- would eagerly bind A/B from the raw args (possibly wrong types), blocking the
-- back-propagation and silently hiding mismatches.
--: (Ctx, { [integer]: any, ... }) -> boolean
local function solve_bind_generics(ctx, c)
    local callee_raw = c[2]
    local callee_tid = find(ctx, callee_raw)
    local arg_tids   = c[3]
    local callee_t   = ctx.types:get(callee_tid)

    -- Unwrap nominal to inner type.
    if callee_t.tag == TAG_NOMINAL then
        callee_tid = find(ctx, callee_t.data[2])
        callee_t   = ctx.types:get(callee_tid)
    end

    -- Only act on TAG_FUNCTION. All other callee forms are handled by C_CHECK_ARGS.
    if callee_t.tag ~= TAG_FUNCTION then return true end

    -- Instantiate if callee was a free var at gen time (method calls).
    local raw_t = ctx.types:get(callee_raw)
    if raw_t.tag == TAG_VAR or raw_t.tag == TAG_ROWVAR then
        callee_tid = env_mod.instantiate(ctx, callee_tid, 0)
        callee_t   = ctx.types:get(callee_tid)
    end

    local pl = callee_t.data[1]

    -- Named-param generic deferral: when param 0 is a free TV (F) and some later param
    -- is also a free TV (A, B, R), and the first argument is a function type:
    -- bind ONLY param 0 from arg 0, then defer.  C_BOUND will back-propagate the
    -- concrete A/B/R types from F's function type into those free TVs.
    -- Without this, C_BIND_GENERICS would eagerly bind A/B from the raw args
    -- (potentially wrong types), blocking C_BOUND and silently hiding mismatches.
    do
        local exp0_t = ctx.types:get(find(ctx, ctx.lists:get(callee_t.data[0])))
        if pl > 1 and (exp0_t.tag == TAG_VAR or exp0_t.tag == TAG_ROWVAR) then
            local has_free_later_param = false
            for si = 1, pl - 1 do
                local st = ctx.types:get(find(ctx, ctx.lists:get(callee_t.data[0] + si)))
                if st.tag == TAG_VAR or st.tag == TAG_ROWVAR then
                    has_free_later_param = true
                    break
                end
            end
            if has_free_later_param then
                -- Defer if param 0's TV has a pending C_BOUND constraint.
                -- C_BOUND will back-propagate concrete types (A, B, R, ...) from the bound
                -- into the free later params once param 0 is bound to a concrete type.
                -- This generalises the old TAG_FUNCTION check: any compound bound
                -- (function, table, etc.) will have a C_BOUND; checking the tag directly
                -- would miss non-function bounds like <T: { x: A, y: B }, A, B>.
                local param0_tv = find(ctx, ctx.lists:get(callee_t.data[0]))
                local has_pending_bound = false
                if ctx._constraints then
                    for _, bc in ipairs(ctx._constraints) do
                        if bc[1] == C_BOUND and find(ctx, bc[2]) == param0_tv then
                            has_pending_bound = true
                            break
                        end
                    end
                end
                if has_pending_bound then
                    local act0 = arg_tids[1]
                    if act0 then
                        -- Bind param 0 (F_fresh / T_fresh) from arg 0, then defer.
                        -- C_BOUND fires next pass to back-propagate A, B, R from the bound type.
                        unify_mod.unify(ctx, widen_literal(ctx, act0),
                            find(ctx, ctx.lists:get(callee_t.data[0])))
                    end
                    return false
                end
            end
        end
    end

    for i = 0, pl - 1 do
        local exp_tid = find(ctx, ctx.lists:get(callee_t.data[0] + i))
        local et      = ctx.types:get(exp_tid)
        -- Bind when the param slot is a free TV (top-level) OR contains nested free TVs
        -- (e.g. Maybe<T> where T is a free TV in a union-of-tables param).
        -- We need unify() to propagate into the structure and bind nested TVs.
        if et.tag == TAG_VAR or et.tag == TAG_ROWVAR or contains_free_var(ctx, exp_tid) then
            local act_tid = arg_tids[i + 1]
            if act_tid then
                -- Preserve literal when this TV feeds a parameterized intrinsic return
                -- (e.g. $Require<T>: the literal module name must survive to solve time).
                local skip_widen = (et.tag == TAG_VAR)
                    and ret_uses_tv_in_intrinsic(ctx, callee_t, exp_tid)
                local widened = skip_widen and find(ctx, act_tid)
                    or (et.tag == TAG_VAR or et.tag == TAG_ROWVAR)
                    and widen_literal(ctx, act_tid)
                    or  widen_for_sub(ctx, act_tid)
                unify_mod.unify(ctx, widened, exp_tid)
            end
        end
    end

    return true
end

-- any: constraint arrays are heterogeneous — see solve_unify comment.
-- Checks that call arguments match the (now-concrete) param types and unifies the return type.
-- Defers (returns false) if any param is still a free TV — C_BIND_GENERICS and C_BOUND
-- have already had a chance to run, so deferral is always safe here.
--: (Ctx, { [integer]: any, ... }) -> boolean
local function solve_check_args(ctx, c)
    local callee_raw = c[2]
    local callee_tid = find(ctx, callee_raw)
    local arg_tids   = c[3]
    local ret_tid    = c[4]
    local line, col  = c[5], c[6]
    local callee_t   = ctx.types:get(callee_tid)

    if callee_t.tag == TAG_ANY then
        bind_to(ctx, ret_tid, ctx.T_ANY)
        return true
    end
    if callee_t.tag == TAG_UNKNOWN then
        add_error(ctx, line, col, "value of type `unknown` must be narrowed before calling")
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
        bind_to(ctx, ret_tid, ctx.T_ANY)
        return true
    end

    if callee_t.tag == TAG_FUNCTION then
        -- Instantiate if callee was a free var at gen time (method calls).
        local raw_t = ctx.types:get(callee_raw)
        if raw_t.tag == TAG_VAR or raw_t.tag == TAG_ROWVAR then
            callee_tid = env_mod.instantiate(ctx, callee_tid, 0)
            callee_t   = ctx.types:get(callee_tid)
        end
        local pl = callee_t.data[1]
        local has_names = callee_t.data[6] > 0
        -- Simple deferral: if any param is still a free TV, wait.
        -- C_BIND_GENERICS and C_BOUND have already had a chance to run; if a param
        -- is still free, more solver progress is needed before we can check args.
        for i = 0, pl - 1 do
            local et = ctx.types:get(find(ctx, ctx.lists:get(callee_t.data[0] + i)))
            if et.tag == TAG_VAR or et.tag == TAG_ROWVAR then
                return false  -- defer
            end
        end
        for i = 0, pl - 1 do
            local exp_tid = find(ctx, ctx.lists:get(callee_t.data[0] + i))
            local act_tid = arg_tids[i + 1]
            if act_tid then
                -- Fast path: try direct assignability (preserves literal-to-literal/union).
                local act_r = find(ctx, act_tid)
                local et = ctx.types:get(exp_tid)
                local param_is_closed_table = et.tag == TAG_TABLE and et.data[4] < 0
                if not param_is_closed_table
                  and et.tag ~= TAG_VAR and et.tag ~= TAG_ROWVAR
                  and not contains_free_var(ctx, exp_tid)
                  and unify_mod.try_unify(ctx, act_r, exp_tid) then
                    -- ok
                else
                local skip_widen = (et.tag == TAG_VAR)
                    and ret_uses_tv_in_intrinsic(ctx, callee_t, exp_tid)
                local widened = skip_widen and find(ctx, act_tid)
                    or (et.tag == TAG_VAR or et.tag == TAG_ROWVAR)
                    and widen_literal(ctx, act_tid)
                    or  widen_for_sub(ctx, act_tid)
                local ok, err = unify_mod.unify(ctx, widened, exp_tid)
                if not ok then
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
                            local pn = param_name or ""
                            local arg_label = param_name
                                and ("`" .. pn .. "`")
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
                            "argument " .. (i + 1) .. ": cannot pass `"
                            .. types_mod.display_short(ctx, act_tid)
                            .. "` where `"
                            .. types_mod.display_short(ctx, exp_tid) .. "` expected"
                            .. (err and (": " .. err) or ""))
                    end
                end
                end  -- close fast-path else
            else
                -- Missing argument
                local ok = unify_mod.unify(ctx, ctx.T_NIL, exp_tid)
                if not ok then
                    add_error(ctx, line, col,
                        "missing argument " .. (i + 1) .. " (expected `"
                        .. types_mod.display_short(ctx, exp_tid) .. "`)")
                end
            end
        end
        -- Handle extra args against the function's vararg slot (data[4]).
        local va_id = callee_t.data[4]
        if va_id >= 0 and #arg_tids > pl then
            local va_resolved = find(ctx, va_id)
            local vat = ctx.types:get(va_resolved)
            if vat.tag == TAG_VAR or vat.tag == TAG_ROWVAR then
                return false  -- retry later
            end
            if vat.tag == TAG_TUPLE then
                for ei = pl, #arg_tids - 1 do
                    local slot_idx = ei - pl
                    local exp_slot
                    if slot_idx < vat.data[1] then
                        exp_slot = find(ctx, ctx.lists:get(vat.data[0] + slot_idx))
                    else
                        exp_slot = ctx.T_NIL
                    end
                    local act_tid = arg_tids[ei + 1]
                    local ok, err = unify_mod.unify(ctx, widen_literal(ctx, act_tid), exp_slot)
                    if not ok then
                        add_error(ctx, line, col,
                            "argument " .. (ei + 1) .. ": cannot pass `"
                            .. types_mod.display_short(ctx, act_tid)
                            .. "` where `"
                            .. types_mod.display_short(ctx, exp_slot) .. "` expected"
                            .. (err and (": " .. err) or ""))
                    end
                end
            end
        end
        -- Unify return
        local rl = callee_t.data[3]
        if rl == 0 then
            unify_mod.unify(ctx, ret_tid, ctx.T_NIL)
        elseif rl == 1 then
            local first_ret = find(ctx, ctx.lists:get(callee_t.data[2]))
            first_ret = resolve_deferred_intrinsic(ctx, first_ret)
            unify_mod.unify(ctx, ret_tid, first_ret)
        else
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
                "cannot call value of type `" .. types_mod.display_short(ctx, callee_tid) .. "`")
            bind_to(ctx, ret_tid, ctx.T_ANY)
            return false
        end
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
                        reasons[#reasons + 1] = "cannot pass `"
                            .. types_mod.display_short(ctx, a)
                            .. "` where `"
                            .. types_mod.display_short(ctx, exp_tid) .. "` expected"
                    end
                end
            end
            cands[#cands + 1] = "candidate " .. ci .. ": "
                .. types_mod.display_short(ctx, m.tid)
                .. (#reasons > 0 and (" — " .. reasons[1]) or "")
        end
        add_error(ctx, line, col,
            "no matching overload for `"
            .. types_mod.display_short(ctx, callee_tid) .. "`:\n  "
            .. table.concat(cands, "\n  "))
        bind_to(ctx, ret_tid, ctx.T_ANY)
        return false
    end

    -- Union: ALL members must accept the argument.
    if callee_t.tag == TAG_UNION then
        local ret_types = {}
        local fail_msgs = {}
        for i = callee_t.data[0], callee_t.data[0] + callee_t.data[1] - 1 do
            local mid = find(ctx, ctx.lists:get(i))
            local mt  = ctx.types:get(mid)
            if mt.tag ~= TAG_FUNCTION then
                fail_msgs[#fail_msgs + 1] = "union member `"
                    .. types_mod.display_short(ctx, mid) .. "` is not callable"
            else
                local member_ok = true
                for j = 0, mt.data[1] - 1 do
                    local exp_tid = find(ctx, ctx.lists:get(mt.data[0] + j))
                    local act_tid = arg_tids[j + 1]
                    if act_tid and not unify_mod.try_unify(ctx, find(ctx, act_tid), exp_tid) then
                        member_ok = false
                        fail_msgs[#fail_msgs + 1] = "argument rejected by union members: `"
                            .. types_mod.display_short(ctx, mid)
                            .. "` does not accept argument " .. (j + 1)
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
        "cannot call value of type `" .. types_mod.display_short(ctx, callee_tid) .. "`")
    bind_to(ctx, ret_tid, ctx.T_ANY)
    return false
end

-- Overlap-checked force cast: `--[[:! T]] expr`. Succeeds iff actual and
-- expected have any value in common. Defers while either side is still a free
-- TAG_VAR so we don't make a soundness call against an unbound type.
--: (Ctx, { [integer]: any, ... }) -> boolean
local function solve_overlap(ctx, c)
    local actual   = find(ctx, c[2])
    local expected = find(ctx, c[3])
    local line, col = c[4], c[5]
    -- Defer if either side is still a free type variable: the answer would be
    -- determined by whatever the var binds to next, not by the user's program.
    do
        local at = ctx.types:get(actual)
        local bt = ctx.types:get(expected)
        if at.tag == TAG_VAR or at.tag == TAG_ROWVAR then return false end
        if bt.tag == TAG_VAR or bt.tag == TAG_ROWVAR then return false end
    end
    if unify_mod.types_overlap(ctx, actual, expected) then return true end
    add_error(ctx, line, col,
        "force cast has no overlap: `"
        .. types_mod.display_short(ctx, actual)
        .. "` and `" .. types_mod.display_short(ctx, expected)
        .. "` are disjoint")
    return true  -- error reported; don't defer further
end

-- ---------------------------------------------------------------------------
-- Solver
-- ---------------------------------------------------------------------------

-- any: constraints is a list of heterogeneous arrays — see solve_unify comment.
--: (Ctx, { [integer]: { [integer]: any, ... }, ... }) -> ()
function M.solve(ctx, constraints)
    -- Dispatch table by constraint kind
    local handlers = {
        [C_UNIFY]         = solve_unify,
        [C_SUB]           = solve_sub,
        [C_INDEX]         = solve_index,
        [C_CALLABLE]      = solve_callable,
        [C_ARITH]         = solve_arith,
        [C_RETURN]        = solve_return,
        [C_COMPARE]       = solve_compare,
        [C_BOUND]         = solve_bound,
        [C_OR]            = solve_or,
        [C_BIND_GENERICS] = solve_bind_generics,
        [C_CHECK_ARGS]    = solve_check_args,
        [C_OVERLAP]       = solve_overlap,
    }

    -- Dependency-aware fixpoint solver.
    -- Handlers return false to mean "I'm waiting on unbound type variables — defer me."
    -- Deferred constraints are skipped each pass; they are re-enabled when any progress
    -- is made (any TV gets bound → tag change → changed=true → all deferred become ready).
    -- This prevents deferred handlers from being called every pass regardless of readiness,
    -- and eliminates the need for complex multi-condition guards inside handlers.
    --
    -- Suppress error emission on all but the final pass to avoid duplicates.
    local real_err = ctx.err
    --: ErrCtx
    local silent_err = { errors = {}, warnings = {}, source_lines = {} }

    -- Expose the constraint list on ctx so handlers can scan for pending C_BOUND constraints.
    ctx._constraints = constraints

    -- Initialize deferred flags on all constraints.
    for _, c in ipairs(constraints) do
        c._deferred = false
    end

    for pass = 1, 4 do
        local changed = false
        local n_deferred = 0
        -- Use silent error context on non-final passes
        ctx.err = (pass < 4) and silent_err or real_err
        silent_err.errors = {}
        silent_err.warnings = {}

        for _, c in ipairs(constraints) do
            local kind = c[1]
            local handler = handlers[kind]
            if handler then
                if c._deferred then
                    n_deferred = n_deferred + 1
                else
                    -- Track var state before for progress detection.
                    -- C_ARITH has op_name (string) at c[2]; use lhs_tid at c[3] instead.
                    local probe = kind ~= constrain.C_ARITH and c[2] or c[3]
                    local t_before = ctx.types:get(find(ctx, probe))
                    local tag_before = t_before.tag
                    local result = handler(ctx, c)
                    if result == false then
                        -- Handler is waiting on unbound TVs — skip until progress is made.
                        c._deferred = true
                        n_deferred = n_deferred + 1
                    end
                    local t_after = ctx.types:get(find(ctx, probe))
                    if t_after.tag ~= tag_before then changed = true end
                end
            end
        end

        -- If any progress was made this pass, re-enable all deferred constraints
        -- so they get another chance to run (their blocking TVs may now be bound).
        if changed then
            for _, c in ipairs(constraints) do
                c._deferred = false
            end
        end

        if not changed then
            -- No progress: converged (or stuck on deferred that can never progress).
            -- Run one final pass with real_err to emit errors, including any stuck deferred.
            if pass < 4 then
                ctx.err = real_err
                for _, c in ipairs(constraints) do
                    c._deferred = false  -- run everything on final error pass
                end
                for _, c in ipairs(constraints) do
                    local handler = handlers[c[1]]
                    if handler then handler(ctx, c) end
                end
            end
            break
        end
    end
    ctx.err = real_err
    ctx._constraints = nil
end

return M
