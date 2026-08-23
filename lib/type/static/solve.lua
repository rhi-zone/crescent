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
-- Outside-In/X solver core (P1 of the rewrite, docs/typechecker-solver-rewrite.md).
-- Coexists with this file; M.solve still dispatches the legacy path in P1.
-- Required here so solve2 can lazy-require solve back without a cycle on
-- first use of legacy_handlers.
local solve2 = require("lib.type.static.solve2")

local TAG_ANY          = defs.TAG_ANY
local TAG_UNKNOWN      = defs.TAG_UNKNOWN
local TAG_NIL          = defs.TAG_NIL
local TAG_BOOLEAN      = defs.TAG_BOOLEAN
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
local TAG_INDEX_TYPE   = defs.TAG_INDEX_TYPE

local LIT_INTEGER   = defs.LIT_INTEGER
local LIT_NUMBER    = defs.LIT_NUMBER
local LIT_STRING    = defs.LIT_STRING
local LIT_OPAQUE_KEY = defs.LIT_OPAQUE_KEY

local FLAG_OPTIONAL      = defs.FLAG_OPTIONAL
local FLAG_PRIVATE       = defs.FLAG_PRIVATE
local FLAG_OPAQUE_KEY    = defs.FLAG_OPAQUE_KEY
local FLAG_SKOLEM        = defs.FLAG_SKOLEM
local FLAG_ROWVAR_INFER  = defs.FLAG_ROWVAR_INFER
local FLAG_GENERIC       = defs.FLAG_GENERIC
local FLAG_SUB_SOLVE_PARAM = defs.FLAG_SUB_SOLVE_PARAM
local band               = require("bit").band
local bor                = require("bit").bor

local C_UNIFY         = constrain.C_UNIFY
local C_SUB           = constrain.C_SUB
local C_INDEX         = constrain.C_INDEX
local C_CALLABLE      = constrain.C_CALLABLE
local C_ARITH         = constrain.C_ARITH
local C_RETURN        = constrain.C_RETURN
local C_COMPARE       = constrain.C_COMPARE
local C_BOUND         = constrain.C_BOUND
local C_OR            = constrain.C_OR
local C_AND           = constrain.C_AND
local C_BIND_GENERICS = constrain.C_BIND_GENERICS
local C_CHECK_ARGS    = constrain.C_CHECK_ARGS
local C_OVERLAP       = constrain.C_OVERLAP
local C_NARROW_NIL    = constrain.C_NARROW_NIL
local C_ESCAPE_CHECK  = constrain.C_ESCAPE_CHECK
local C_HKT_DECOMPOSE = constrain.C_HKT_DECOMPOSE
local C_INSTANTIATE_AT_CALL = constrain.C_INSTANTIATE_AT_CALL

local find = types_mod.find

local M = {}

-- ---------------------------------------------------------------------------
-- Solver-architecture-v2 (β): await primitive
-- ---------------------------------------------------------------------------
-- Register `c` as a waiter on the union-find root of `tv_id`. The handler
-- should return the value produced here; solve_range sees `result.solved ==
-- false` and marks the constraint deferred. When unify.bind_var_to_type
-- (centralized chokepoint) binds the root, wake_waiters drains the list and
-- clears _deferred on each subscriber so the next solver pass re-runs them.
--
-- Symmetric to P1.5's emit channel. The await field on the return is
-- informational — registration is done here, not by solve_range — but kept
-- in the protocol so handler intent is grep-able and the solver can later
-- adopt a worklist that consumes the channel directly.
--: (Ctx, { [integer]: unknown, ... }, integer) -> { solved: boolean, await: integer }
local function await(ctx, c, tv_id)
    local root = find(ctx, tv_id)
    local list = ctx.tv_waiters[root]
    if not list then
        list = {}
        ctx.tv_waiters[root] = list
    end
    list[#list + 1] = c
    return { solved = false, await = root }
end
M.await = await

-- ---------------------------------------------------------------------------
-- TV ownership (cross-constraint dependency tracking)
-- ---------------------------------------------------------------------------
-- Complement to `await` and to solve2's `blocked_on`. Where `await` makes a
-- reader sleep on a TV that some past constraint already advertised, and
-- `blocked_on` records intra-implication dependencies, `tv_owners` records
-- a *future* writer commitment that crosses constraint boundaries.
--
-- A producer that has committed to binding TV X — but cannot do so yet
-- (e.g. solve_callable is waiting for one of its arg unifications to
-- settle; the to-be-ported solve_instantiate_at_call will emit children
-- that bind X) — calls `claim(ctx, X, self)`. From that point on every
-- reader that would otherwise fall through to an eager `unify` on free X
-- consults `is_owned(ctx, X)` first and, when owned, parks itself via
-- `await(c, X)` instead. The producer's eventual bind goes through the
-- union-find chokepoints (`bind_var_to_type` in unify.lua, `bind_to` in
-- this file) which call `release` and wake everyone parked on X — the
-- parked readers re-run with X bound to the producer's chosen type and
-- compare against it rather than racing to a different binding.
--
-- This is the Phase F-blocker fix
-- (docs/typechecker-phase-f-blocker.md): the cross-statement bug where
-- a next statement's `C_SUB(call_ret_TV, ann_T)` eagerly unified the
-- ret_TV before the call's own constraints had committed it.
--
-- claim/release symmetry: every terminal-success path of every producer
-- goes through `bind_var_to_type` or `bind_to` on the claimed TV, so the
-- release is automatic at the chokepoint. Claim is idempotent — the same
-- producer re-running across deferral simply overwrites the slot with
-- itself.
--: (Ctx, integer, { [integer]: unknown, ... }) -> ()
local function claim(ctx, tv_id, owner)
    ctx.tv_owners[find(ctx, tv_id)] = owner
end
M.claim = claim

--: (Ctx, integer) -> ()
local function release(ctx, tv_id)
    ctx.tv_owners[tv_id] = nil
end
M.release = release

--: (Ctx, integer) -> boolean
local function is_owned(ctx, tv_id)
    return ctx.tv_owners[find(ctx, tv_id)] ~= nil
end
M.is_owned = is_owned

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

-- Rule-aware warning: looks up effective severity from rules_config on ctx.
-- Falls back to add_warning when the code has no rule default (non-configurable).
-- Returns the resulting DiagEntry (so callers can attach a fix) or nil if suppressed.
--: (Ctx, integer | nil, integer | nil, integer) -> DiagEntry | nil
local function add_warning_code(ctx, line, col, code)
    --: { [integer]: { name: string, severity: string }, ... }
    local rd = defs.rule_defaults --[[:! { [integer]: { name: string, severity: string }, ... }]]
    if rd[code] then
        local rc_mod = require("lib.type.static.rules_config")
        --: { [string]: { severity?: string, enabled?: boolean, allow?: { [integer]: string, ... }, ... }, ... } | nil
        local rc = ctx.rules_config --[[:! { [string]: { severity?: string, enabled?: boolean, allow?: { [integer]: string, ... }, ... }, ... } | nil]]
        local sev = rc_mod.effective_severity(code, rc, rd)
        if sev == "off" then return nil end
        local allow = rc_mod.allow_patterns(code, rc, rd)
        if rc_mod.is_allowed(ctx.filename, allow) then return nil end
        local msg = errors_mod.format_diag(code, {})
        if sev == "error" then
            return errors_mod.error(ctx.err, ctx.filename, line or 0, col or 0, msg)
        else
            return errors_mod.warning(ctx.err, ctx.filename, line or 0, col or 0, msg)
        end
    end
    return errors_mod.warning(ctx.err, ctx.filename, line or 0, col or 0, errors_mod.format_diag(code, {}))
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
    local rl = types_mod.fn_returns_len(callee_t)
    local rs = types_mod.fn_returns_start(callee_t)
    for ri = 0, rl - 1 do
        local ret_tid = ctx.lists:get(rs + ri)
        local rt = ctx.types:get(ret_tid)
        if rt.tag == TAG_TYPE_CALL then
            -- TAG_TYPE_CALL direct: tycall accessors trigger spurious cascading
            -- errors elsewhere (typechecker flow-sensitivity quirk noted in C14).
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
        local inner_tid = find(ctx, types_mod.spread_inner(t))
        local inner_t = ctx.types:get(inner_tid)
        -- TAG_MATCH_TYPE with a now-concrete param: evaluate the match.
        -- PairsReturn<T>/IpairsReturn<T> match aliases return a 2-tuple (K, V);
        -- wrap the result in a full iterator triple so the for-in handler can
        -- extract iter_fn at slot 0.  The match param (data[0]) is the table
        -- type T used as iterator state.
        if inner_t.tag == TAG_MATCH_TYPE then
            local param_resolved = find(ctx, types_mod.match_param(inner_t))
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
            if result_t.tag == TAG_TUPLE and types_mod.agg_members_len(result_t) == 2 then
                local rs = types_mod.agg_members_start(result_t)
                local K_tid = find(ctx, ctx.lists:get(rs))
                local V_tid = find(ctx, ctx.lists:get(rs + 1))
                return intrinsic_mod.build_iter_triple(ctx, param_resolved, K_tid, V_tid)
            end
            if result_t.tag == TAG_UNION then
                -- Check if all union members are 2-tuples; if so, collapse K and V.
                local ks, vs = {}, {}
                local all_pairs = true
                local us, ul = types_mod.agg_members_start(result_t), types_mod.agg_members_len(result_t)
                for ui = us, us + ul - 1 do
                    local member = ctx.types:get(find(ctx, ctx.lists:get(ui)))
                    if member.tag == TAG_TUPLE and types_mod.agg_members_len(member) == 2 then
                        local ms = types_mod.agg_members_start(member)
                        ks[#ks + 1] = find(ctx, ctx.lists:get(ms))
                        vs[#vs + 1] = find(ctx, ctx.lists:get(ms + 1))
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
    -- TAG_INDEX_TYPE: evaluate T[K] when both subject and key are now concrete.
    -- Arises when a generic return type like CTypeMap[S] has S bound after arg unification.
    if t.tag == TAG_INDEX_TYPE then
        local subj_tid = find(ctx, types_mod.index_subject(t))
        local key_tid  = find(ctx, types_mod.index_key(t))
        local st = ctx.types:get(subj_tid)
        local kt = ctx.types:get(key_tid)
        if st.tag ~= TAG_VAR and st.tag ~= TAG_ROWVAR and st.tag ~= TAG_NAMED
            and kt.tag ~= TAG_VAR and kt.tag ~= TAG_ROWVAR and kt.tag ~= TAG_NAMED then
            local match_mod = require("lib.type.static.match")
            local result --: integer | nil
            result = match_mod.lookup_index(ctx, subj_tid, key_tid) --[[:! integer | nil]]
            if result ~= nil then
                return result
            end
        end
        return tid
    end

    if t.tag ~= TAG_TYPE_CALL then return tid end
    -- TAG_TYPE_CALL callee/args kept direct: tycall_callee/_args_* accessors
    -- trigger spurious cascading errors here (typechecker flow-sensitivity
    -- quirk noted in C14).
    local callee_id = find(ctx, t.data[0])
    local ct = ctx.types:get(callee_id)
    if ct.tag ~= TAG_INTRINSIC then return tid end
    -- Collect resolved arg type ids.
    local arg_ids = {}
    for i = t.data[1], t.data[1] + t.data[2] - 1 do
        arg_ids[#arg_ids + 1] = find(ctx, ctx.lists:get(i))
    end
    local intrinsic_mod = require("lib.type.static.intrinsic")
    local stable = types_mod.tycall_stable_id(t)
    return intrinsic_mod.expand(ctx, types_mod.intrinsic_name_id(ct), arg_ids, stable)
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
        local fs, fl = types_mod.tbl_fields_start(t), types_mod.tbl_fields_len(t)
        for i = fs, fs + fl - 1 do
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
        local is, il = types_mod.tbl_indexers_start(t), types_mod.tbl_indexers_len(t)
        local i = is
        while i < is + il - 1 do
            new_indexers[#new_indexers + 1] = ctx.lists:get(i)
            new_indexers[#new_indexers + 1] = ctx.lists:get(i + 1)
            i = i + 2
        end
        seen[tid] = nil
        return types_mod.make_table(ctx, new_fields, new_indexers, types_mod.tbl_row_var(t), {})
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
        local fs, fl = types_mod.tbl_fields_start(t), types_mod.tbl_fields_len(t)
        for i = fs, fs + fl - 1 do
            local fe = ctx.fields:get(ctx.lists:get(i))
            if contains_free_var(ctx, fe.type_id, seen) then return true end
        end
        local rv = types_mod.tbl_row_var(t)
        if rv >= 0 and contains_free_var(ctx, rv, seen) then return true end
        return false
    end
    if tag == TAG_FUNCTION then
        seen = seen or {}; seen[tid] = true
        local ps, pl = types_mod.fn_params_start(t), types_mod.fn_params_len(t)
        for i = ps, ps + pl - 1 do
            if contains_free_var(ctx, ctx.lists:get(i), seen) then return true end
        end
        local rs, rl = types_mod.fn_returns_start(t), types_mod.fn_returns_len(t)
        for i = rs, rs + rl - 1 do
            if contains_free_var(ctx, ctx.lists:get(i), seen) then return true end
        end
        -- Also check vararg_id: TAG_SPREAD(P) or a free TV for ...P.
        local va = types_mod.fn_vararg(t)
        if va >= 0 and contains_free_var(ctx, va, seen) then return true end
        return false
    end
    if tag == TAG_UNION or tag == TAG_INTERSECTION or tag == TAG_TUPLE then
        seen = seen or {}; seen[tid] = true
        local ms, ml = types_mod.agg_members_start(t), types_mod.agg_members_len(t)
        for i = ms, ms + ml - 1 do
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
        -- Release TV ownership at the union-find chokepoint. Paired with
        -- the same call inside unify.bind_var_to_type; both bind paths
        -- must clear ownership so claim/release symmetry holds regardless
        -- of which chokepoint the producer's terminal bind goes through.
        release(ctx, root)
    end
end

-- Resolve arithmetic result type from primitive operands.
-- Returns result_tid or nil if operands are not numeric.
local ARITH_OPS_SET = {
    __add = true, __sub = true, __mul = true,
    __div = true, __mod = true, __pow = true, __unm = true,
}

-- Follow the __index prototype chain to find a field.
-- Checks both #__index meta-slots (declared with the # syntax) and __index as a
-- regular named field (the common runtime pattern: Proto.__index = Proto).
-- Returns (type_id, flags) if found, (nil, nil) if not.
-- depth-limited to prevent cycles in pathological type definitions.
--: (Ctx, integer, integer, integer) -> (integer | nil, integer | nil)
local function field_via_index_chain(ctx, tbl_tid, name_id, depth)
    if depth > 8 then return nil, nil end
    local fe = types_mod.table_field(ctx, tbl_tid, name_id)
    if fe then return find(ctx, fe.type_id), fe.flags end
    local idx_name_id = intern_mod.intern(ctx.pool, "__index")
    -- Check #__index meta-slot first (explicit annotation), then __index named field
    -- (common runtime pattern: Proto.__index = Proto).
    local idx_fe = types_mod.table_meta_field(ctx, tbl_tid, idx_name_id)
    if not idx_fe then idx_fe = types_mod.table_field(ctx, tbl_tid, idx_name_id) end
    if not idx_fe then return nil, nil end
    local idx_tid = find(ctx, idx_fe.type_id)
    local idx_t = ctx.types:get(idx_tid)
    if idx_t.tag == TAG_TABLE then
        return field_via_index_chain(ctx, idx_tid, name_id, depth + 1)
    end
    return nil, nil
end

-- Check metamethod on a TABLE type (not primitives — prim_meta lookup not needed here).
--: (Ctx, integer, string) -> integer | nil
local function table_meta_op_ret(ctx, tbl_tid, mm_name)
    local mm_id = intern_mod.intern(ctx.pool, mm_name)
    local fe = types_mod.table_meta_field(ctx, tbl_tid, mm_id)
    if not fe then return nil end
    local fn_tid = find(ctx, fe.type_id)
    local ft = ctx.types:get(fn_tid)
    if ft.tag == TAG_FUNCTION and types_mod.fn_returns_len(ft) > 0 then
        return find(ctx, ctx.lists:get(types_mod.fn_returns_start(ft)))
    end
    return ctx.T_ANY
end

-- Resolve the result type of an operator via metamethod dispatch.
-- Checks table metamethods first, then prim_meta for primitive types.
-- TAG_UNION: all arms must support the op; result is union of arm results.
-- Returns result TID, ctx.T_ANY (any/unknown operand), or nil (not supported).
-- `seen` guards against recursive types (a union/intersection containing
-- itself transitively, which can arise from inferred recursive structures).
--: (Ctx, string, integer, { [integer]: boolean } | nil) -> integer | nil
local function meta_op_ret_impl(ctx, op_name, tid, seen)
    tid = find(ctx, tid)
    if seen and seen[tid] then return nil end
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
        seen = seen or {}
        seen[tid] = true
        -- Intersection: if any member supports the op, use its result
        local ms, ml = types_mod.agg_members_start(t), types_mod.agg_members_len(t)
        for i = ms, ms + ml - 1 do
            local r = meta_op_ret_impl(ctx, op_name, ctx.lists:get(i), seen)
            if r then return r end
        end
        return nil
    end
    if t.tag == TAG_UNION then
        seen = seen or {}
        seen[tid] = true
        local parts = {}
        local ms, ml = types_mod.agg_members_start(t), types_mod.agg_members_len(t)
        for i = ms, ms + ml - 1 do
            local r = meta_op_ret_impl(ctx, op_name, ctx.lists:get(i), seen)
            if r == nil then return nil end  -- any arm unsupported → whole union fails
            parts[#parts + 1] = r
        end
        return #parts == 0 and nil or types_mod.make_union(ctx, parts)
    end
    -- Primitive: map tag (or literal kind) to prim_meta entry
    local ptag = t.tag
    if ptag == TAG_LITERAL then
        local k = types_mod.lit_kind(t)
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
--: (Ctx, { [integer]: unknown, ... }) -> boolean
local function solve_unify(ctx, c)
    local t1 = find(ctx, constrain.unify_lhs(c))
    local t2 = find(ctx, constrain.unify_rhs(c))
    local ok, err = unify_mod.unify(ctx, t1, t2)
    if not ok then
        add_error(ctx, constrain.unify_line(c), constrain.unify_col(c),
            "type mismatch: cannot unify `" .. types_mod.display_short(ctx, t1)
            .. "` with `" .. types_mod.display_short(ctx, t2) .. "`"
            .. (err and (": " .. err) or ""))
    end
    -- Terminal either way: success solves; failure emitted the error.
    -- Retrying after a TV bind would re-emit the same error.
    return true
end

-- any: constraint arrays are heterogeneous — see solve_unify comment.
--: (Ctx, { [integer]: unknown, ... }) -> boolean | { solved: boolean, await: integer }
local function solve_sub(ctx, c)
    local actual   = find(ctx, constrain.sub_actual(c))
    local expected = find(ctx, constrain.sub_expected(c))
    local line, col = constrain.sub_line(c), constrain.sub_col(c)

    -- Multi-return tuple assigned to scalar: project the first element.
    -- In Lua `local x = f()` where f() returns (T, U, ...) → x gets T.
    -- When C_SUB receives a tuple on the left but a non-tuple on the right,
    -- check the first element instead of the whole tuple.
    -- Track whether the original was a free var or a multi-return tuple so the
    -- redundant-cast check below can suppress false positives (see below).
    -- Check c[2] directly (the raw stored type ID) not via find(), because the
    -- type var may have been bound by earlier constraints in this solver pass.
    local original_was_free_var   = false
    local original_was_tuple      = false
    do
        -- Check the raw type node stored in the constraint (before find/union-find traversal).
        -- This reflects what the expression type was at constraint-generation time.
        local raw_t = ctx.types:get(constrain.sub_actual(c))
        if raw_t.tag == TAG_VAR or raw_t.tag == TAG_ROWVAR then
            original_was_free_var = true
        end
        local at = ctx.types:get(actual)
        local et = ctx.types:get(expected)
        if at.tag == TAG_TUPLE and et.tag ~= TAG_TUPLE then
            original_was_tuple = true
            actual = types_mod.agg_members_len(at) > 0
                and find(ctx, ctx.lists:get(types_mod.agg_members_start(at)))
                or ctx.T_NIL
        end
    end

    -- Redundant cast warning: if this C_SUB was emitted by a cast expression (c[6]=true),
    -- and the inferred type is structurally identical to the asserted type, warn.
    -- Excludes any on either side: any unifies with everything so it's not "redundant",
    -- it's an explicit opt-out.
    --
    -- Two cases where the cast is NOT redundant even if widened == expected:
    --   1. original_was_free_var: the type var was bound via this very C_SUB constraint
    --      (back-propagation in the fixpoint solver). In a later fixpoint pass, the var
    --      appears to already have the cast type — but the cast is what gave it that type.
    --   2. original_was_tuple: `(f()) --[[: T]]` where f() returns multi-return.
    --      The cast truncates the tuple to a scalar. In return position the cast is
    --      necessary, even though locally the first element already matches T.
    if constrain.sub_is_cast(c) and not original_was_free_var and not original_was_tuple then
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
        local is_closed_table = et.tag == TAG_TABLE and types_mod.tbl_row_var(et) < 0
        if not is_closed_table and et.tag ~= TAG_VAR and et.tag ~= TAG_ROWVAR then
            -- TV ownership check (cross-constraint dependency tracking).
            -- If `actual` is a free TV that some producer has committed to
            -- writing in the future, the slow path's `unify` below would
            -- otherwise bind the TV to `expected` itself — eating the
            -- error that the producer's eventual bind would have surfaced.
            -- Park on the producer's TV; wake when its bind fires, then
            -- re-run this C_SUB against the actually-produced type.
            -- This is the Phase F-blocker fix
            -- (docs/typechecker-phase-f-blocker.md): the cross-statement
            -- C_SUB(call_ret_TV, ann_T) bug.
            local at = ctx.types:get(actual)
            if (at.tag == TAG_VAR or at.tag == TAG_ROWVAR)
                and is_owned(ctx, actual) then
                return await(ctx, c, actual)
            end
            -- Use the strict variant so a free TV at the top level falls
            -- through to the unify slow path (which binds eagerly today;
            -- Phase E will route it through `await`). See
            -- docs/typechecker-solver-architecture-v2.md Phase A.
            local r = unify_mod.try_unify_strict(ctx, actual, expected)
            if r == true then return true end
            -- r == false  → fall through to slow path for the proper error.
            -- r == "needs" → fall through; slow path binds the TV.
        end
    end

    -- Widen actual literals before constraining
    local widened = widen_for_sub(ctx, actual)

    -- Checked-cast sites (`--[[: T]] expr`) must CHECK assignability without
    -- binding free inference variables. The destructive `unify` below is the
    -- solver's binding mechanism (regular assignment / back-propagation needs
    -- it), and it is bidirectional: when the cast actual (`widened`) is an
    -- unannotated param's free `TAG_VAR`, unify binds that var to the asserted
    -- type — turning the cast into an inference source, which is unsound (a
    -- checked or force cast must never inject inference facts; see TODO
    -- "solve.lua:579 — destructive unify on checked-cast sites"). The
    -- unsoundness arises only when the *actual* is a free var: with a concrete
    -- actual, `unify` only ever binds vars inside `expected`, which for a cast
    -- is the user-written asserted type (carrying no free inference vars). So
    -- intercept exactly the free-var-actual case and defer it — park on the var
    -- and re-check once a producer (e.g. caller arg inference for the param)
    -- resolves it — rather than binding (the bug) or eagerly erroring (a false
    -- positive when a caller would resolve the param compatibly). Every other
    -- cast case keeps the original `unify` path verbatim, so its diagnostics
    -- (including the "must be narrowed" guidance for `unknown`→`any`) are
    -- preserved.
    if constrain.sub_is_cast(c) then
        local wt = ctx.types:get(find(ctx, widened))
        if wt.tag == TAG_VAR or wt.tag == TAG_ROWVAR then
            return await(ctx, c, find(ctx, widened))
        end
    end

    local ok, err = unify_mod.unify(ctx, widened, expected)
    if not ok then
        -- "might also be" message for unions
        local act_t = ctx.types:get(find(ctx, actual))
        if act_t.tag == TAG_UNION then
            local failing = {}
            local ams, aml = types_mod.agg_members_start(act_t), types_mod.agg_members_len(act_t)
            for i = ams, ams + aml - 1 do
                local mid = find(ctx, ctx.lists:get(i))
                if not unify_mod.try_unify(ctx, mid, expected) then
                    failing[#failing + 1] = mid
                end
            end
            local total = aml
            if #failing > 0 and #failing < total then
                local fail_tid = #failing == 1 and failing[1]
                    or types_mod.make_union(ctx, failing)
                add_error(ctx, line, col,
                    "expects `" .. types_mod.display_short(ctx, expected)
                    .. "`, but argument might also be `"
                    .. types_mod.display_short(ctx, fail_tid) .. "`")
                return true  -- terminal: error emitted, retry would duplicate.
            end
        end
        add_error(ctx, line, col,
            "cannot assign `" .. types_mod.display_short(ctx, actual)
            .. "` to `" .. types_mod.display_short(ctx, expected) .. "`"
            .. (err and (": " .. err) or ""))
    end
    -- Terminal either way: success solves; failure emitted the error above.
    return true
end

-- Solve a deferred nil-narrowing: C_NARROW_NIL = { _, input_tid, result_tid, keep_nil, line, col }
-- Defers while input is a free TAG_VAR. Once input is concrete, computes either the
-- non-nil/non-false subset (keep_nil=false) or the nil-only subset (keep_nil=true)
-- and unifies with result_tid. Used by narrow.lua when narrowing operates on a TAG_VAR
-- that hasn't been resolved yet (e.g. for-in loop variables).
-- any: constraint arrays are heterogeneous — see solve_unify comment.
--: (Ctx, { [integer]: unknown, ... }) -> boolean | { solved: boolean, await: integer }
local function solve_narrow_nil(ctx, c)
    local input_tid  = constrain.narrowNil_input(c)
    local result_tid = constrain.narrowNil_result(c)
    local keep_nil   = constrain.narrowNil_keep(c)

    local input = find(ctx, input_tid)
    local it = ctx.types:get(input)
    if it.tag == TAG_VAR or it.tag == TAG_ROWVAR then
        return await(ctx, c, input)
    end

    local resolved = ctx.T_NEVER
    if keep_nil then
        -- Keep only nil members.
        if it.tag == TAG_ANY then
            resolved = input
        elseif it.tag == TAG_UNION then
            --: { [integer]: integer, ... }
            local nil_members = {}
            local ims, iml = types_mod.agg_members_start(it), types_mod.agg_members_len(it)
            for i = ims, ims + iml - 1 do
                local mid = find(ctx, ctx.lists:get(i))
                local mt = ctx.types:get(mid)
                if mt.tag == TAG_NIL or (mt.tag == TAG_LITERAL and types_mod.lit_kind(mt) == defs.LIT_NIL) then
                    nil_members[#nil_members + 1] = mid
                end
            end
            if #nil_members == 1 then
                resolved = nil_members[1]
            elseif #nil_members > 1 then
                resolved = types_mod.make_union(ctx, nil_members)
            end
        elseif it.tag == TAG_NIL or (it.tag == TAG_LITERAL and types_mod.lit_kind(it) == defs.LIT_NIL) then
            resolved = input
        end
    else
        -- Remove nil and literal false.
        local r = types_mod.subtract(ctx, input, ctx.T_NIL)
        local false_lit = types_mod.make_literal(ctx, defs.LIT_BOOLEAN, 0)
        resolved = types_mod.subtract(ctx, r, false_lit)
    end
    unify_mod.unify(ctx, result_tid, resolved)
    return true
end

-- Rank-N escape check: after a call site introduces per-call skolems for nested
-- forall quantifiers, verify that no skolem with the matching call_id is
-- reachable from the inferred return type. If one is, the polymorphic value
-- escaped its quantifier (unsoundness) and we emit a diagnostic.
-- Defers while ret_tid is still a free TAG_VAR (waiting for C_CHECK_ARGS).
--: (Ctx, { [integer]: unknown, ... }) -> boolean
local function solve_escape_check(ctx, c)
    local ret_tid = constrain.escape_ret(c)
    local call_id = constrain.escape_call_id(c)
    local line, col = constrain.escape_line(c), constrain.escape_col(c)

    local resolved = find(ctx, ret_tid)
    local rt = ctx.types:get(resolved)
    -- Defer while the return is still a free (non-skolem) TV — C_CHECK_ARGS
    -- hasn't run yet. A skolem TV at the top is itself an immediate escape.
    if (rt.tag == TAG_VAR or rt.tag == TAG_ROWVAR)
        and band(rt.flags, FLAG_SKOLEM) == 0 then
        return false
    end

    -- Collect every TV reachable from the resolved return type. A rank-N
    -- skolem with matching call_id appearing in this set means it leaked.
    local reachable = {} --: { [integer]: boolean, ... }
    constrain.collect_bound_tvs(ctx, resolved, reachable, {})
    local found_name --: integer | nil
    for tv_id in pairs(reachable) do
        local t = ctx.types:get(tv_id)
        if (t.tag == TAG_VAR or t.tag == TAG_ROWVAR)
            and band(t.flags, FLAG_SKOLEM) ~= 0
            and types_mod.var_skolem_call_id(t) == call_id then
            found_name = types_mod.var_skolem_name_id(t)
            break
        end
    end

    if found_name then
        local skolem_name = intern_mod.get(ctx.pool, found_name) or "?"
        add_error(ctx, line, col,
            "polymorphic value escapes its quantifier: type parameter `"
            .. skolem_name .. "` would leak into the call's return type")
    end
    return true
end

-- The truthy part of a single (non-union) concrete type: it with {false, nil}
-- removed. Returns a tid, or nil if the type contributes nothing truthy.
--   nil / lit nil / lit false -> nil (no contribution: always falsy)
--   boolean                   -> true   (boolean splits into true|false; only true is truthy)
--   lit true                  -> true
--   any other concrete type   -> itself (always truthy)
--   any                       -> any
--   unknown                   -> unknown
--: (Ctx, integer) -> integer | nil
local function truthy_part_single(ctx, tid)
    local t = ctx.types:get(tid)
    local tag = t.tag
    if tag == TAG_NIL then return nil end
    if tag == TAG_LITERAL then
        local k = types_mod.lit_kind(t)
        if k == defs.LIT_NIL then return nil end
        if k == defs.LIT_BOOLEAN then
            -- lit true is truthy; lit false contributes nothing.
            if types_mod.lit_bool(t) == 1 then return tid end
            return nil
        end
        return tid
    end
    if tag == TAG_BOOLEAN then
        return types_mod.make_literal(ctx, defs.LIT_BOOLEAN, 1)
    end
    -- any / unknown / every other concrete type is (possibly) truthy as-is.
    return tid
end

-- The truthy part of a (possibly union) type: it with {false, nil} removed.
-- Returns T_NEVER when the type is always falsy.
--: (Ctx, integer) -> integer
local function truthy_part(ctx, tid)
    tid = find(ctx, tid)
    local t = ctx.types:get(tid)
    if t.tag == TAG_UNION then
        --: { [integer]: integer, ... }
        local parts = {}
        local us, ul = types_mod.agg_members_start(t), types_mod.agg_members_len(t)
        for i = us, us + ul - 1 do
            local mid = find(ctx, ctx.lists:get(i))
            local tp = truthy_part_single(ctx, mid)
            if tp ~= nil then parts[#parts + 1] = tp end
        end
        if #parts == 0 then return ctx.T_NEVER end
        if #parts == 1 then return parts[1] end
        return types_mod.make_union(ctx, parts)
    end
    local tp = truthy_part_single(ctx, tid)
    if tp == nil then return ctx.T_NEVER end
    return tp
end

-- Solve a deferred `or` expression: C_OR = { C_OR, left_tid, right_tid, result_tid, line, col }
-- Defers while left_tid is still a free TAG_VAR (not yet resolved).
-- Once concrete: result = truthy_part(left) | right. `a or b` yields `a` only
-- when `a` is truthy, so the left contributes its non-falsy part (nil AND false
-- removed); when `a` is falsy the result is `b`.
-- Special case: when left is T_UNKNOWN and right is a non-falsy typed default,
-- result is right. `unknown or 0` means the programmer is asserting the result
-- type via the fallback — the or-default IS the narrowing. Not applied when right
-- is falsy (nil, false literal) because those don't carry type information.
-- any: constraint arrays are heterogeneous — see solve_unify comment.
--: (Ctx, { [integer]: unknown, ... }) -> boolean
local function solve_or(ctx, c)
    local left_tid   = constrain.or_left(c)
    local right_tid  = constrain.or_right(c)
    local result_tid = constrain.or_result(c)

    local left = find(ctx, left_tid)
    local lt = ctx.types:get(left)
    if lt.tag == TAG_VAR or lt.tag == TAG_ROWVAR then
        return false  -- defer
    end

    local right = find(ctx, right_tid)
    local resolved
    if left == ctx.T_UNKNOWN then
        -- Only narrow when the default is a non-falsy typed value: not nil, not false.
        -- `unknown or false` / `unknown or nil` don't assert the result type.
        local rt = ctx.types:get(right)
        local is_falsy = right == ctx.T_NIL or rt.tag == TAG_NIL
            or (rt.tag == TAG_LITERAL and types_mod.lit_kind(rt) == defs.LIT_BOOLEAN and types_mod.lit_bool(rt) == 0)
        if not is_falsy then
            resolved = right
        else
            resolved = types_mod.make_union(ctx, { ctx.T_UNKNOWN, right })
        end
    else
        local truthy_left = truthy_part(ctx, left)
        if truthy_left == ctx.T_NEVER then
            resolved = right
        else
            resolved = types_mod.make_union(ctx, { truthy_left, right })
        end
    end
    unify_mod.unify(ctx, result_tid, resolved)
    return true
end

-- The falsy part of a single (non-union) concrete type: its intersection with
-- {false, nil}. Returns a tid, or nil if the type contributes nothing falsy.
--   nil / lit nil      -> nil
--   boolean            -> false   (boolean splits into true|false; only false is falsy)
--   lit false          -> false
--   lit true / any other always-truthy type -> nil (no contribution)
--   any                -> any      (a falsy value is possible and unconstrained)
--   unknown            -> nil|false (conservative: could be either falsy value)
--: (Ctx, integer) -> integer | nil
local function falsy_part_single(ctx, tid)
    local t = ctx.types:get(tid)
    local tag = t.tag
    if tag == TAG_NIL then return ctx.T_NIL end
    if tag == TAG_LITERAL then
        local k = types_mod.lit_kind(t)
        if k == defs.LIT_NIL then return ctx.T_NIL end
        if k == defs.LIT_BOOLEAN then
            -- lit false is falsy; lit true contributes nothing.
            if types_mod.lit_bool(t) == 0 then return tid end
            return nil
        end
        return nil
    end
    if tag == TAG_BOOLEAN then
        return types_mod.make_literal(ctx, defs.LIT_BOOLEAN, 0)
    end
    if tag == TAG_ANY then return ctx.T_ANY end
    if tag == TAG_UNKNOWN then
        local false_lit = types_mod.make_literal(ctx, defs.LIT_BOOLEAN, 0)
        return types_mod.make_union(ctx, { ctx.T_NIL, false_lit })
    end
    -- All other concrete types are always truthy: no falsy contribution.
    return nil
end

-- The falsy part of a (possibly union) type: its intersection with {false, nil}.
-- Returns T_NEVER when the type is always truthy.
--: (Ctx, integer) -> integer
local function falsy_part(ctx, tid)
    tid = find(ctx, tid)
    local t = ctx.types:get(tid)
    if t.tag == TAG_UNION then
        --: { [integer]: integer, ... }
        local parts = {}
        local us, ul = types_mod.agg_members_start(t), types_mod.agg_members_len(t)
        for i = us, us + ul - 1 do
            local mid = find(ctx, ctx.lists:get(i))
            local fp = falsy_part_single(ctx, mid)
            if fp ~= nil then parts[#parts + 1] = fp end
        end
        if #parts == 0 then return ctx.T_NEVER end
        if #parts == 1 then return parts[1] end
        return types_mod.make_union(ctx, parts)
    end
    local fp = falsy_part_single(ctx, tid)
    if fp == nil then return ctx.T_NEVER end
    return fp
end

-- Solve a deferred `and` expression: C_AND = { C_AND, left_tid, right_tid, result_tid, line, col }
-- Defers while left_tid is still a free TAG_VAR (not yet resolved).
-- Once concrete: `a and b` is `a` when `a` is falsy, else `b`, so
-- result = falsy_part(left) | right. Symmetric with solve_or.
-- any: constraint arrays are heterogeneous — see solve_unify comment.
--: (Ctx, { [integer]: unknown, ... }) -> boolean
local function solve_and(ctx, c)
    local left_tid   = constrain.and_left(c)
    local right_tid  = constrain.and_right(c)
    local result_tid = constrain.and_result(c)

    local left = find(ctx, left_tid)
    local lt = ctx.types:get(left)
    if lt.tag == TAG_VAR or lt.tag == TAG_ROWVAR then
        return false  -- defer
    end

    local right = find(ctx, right_tid)
    local fp = falsy_part(ctx, left)
    local resolved
    if fp == ctx.T_NEVER then
        resolved = right
    else
        resolved = types_mod.make_union(ctx, { fp, right })
    end
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
-- Look up a metamethod's full signature on a type, dispatching prim_meta
-- for primitives and structural meta-slots for tables. Returns the
-- TAG_FUNCTION tid of the metamethod, or nil if the type doesn't have it.
-- Mirrors meta_op_ret_impl's dispatch but returns the whole signature
-- rather than just the return type. Used by propagate_meta_bound to
-- back-propagate metamethod params/returns into bound-side free TVs.
--: (Ctx, integer, string) -> integer | nil
local function find_metamethod_sig(ctx, tid, mm_name)
    tid = find(ctx, tid)
    local t = ctx.types:get(tid)
    if t.tag == TAG_NOMINAL then
        return find_metamethod_sig(ctx, types_mod.nom_underlying(t), mm_name)
    end
    local mm_id = intern_mod.intern(ctx.pool, mm_name)
    if t.tag == TAG_TABLE then
        local fe = types_mod.table_meta_field(ctx, tid, mm_id)
        if not fe then return nil end
        local sig_tid = find(ctx, fe.type_id)
        local st = ctx.types:get(sig_tid)
        if st.tag == TAG_FUNCTION then return sig_tid end
        return nil
    end
    -- Primitive: map via prim_meta.
    local ptag = t.tag
    if ptag == TAG_LITERAL then
        local k = types_mod.lit_kind(t)
        if     k == LIT_NUMBER  then ptag = TAG_NUMBER
        elseif k == LIT_INTEGER then ptag = TAG_INTEGER
        elseif k == LIT_STRING  then ptag = TAG_STRING
        else return nil end
    elseif ptag ~= TAG_NUMBER and ptag ~= TAG_INTEGER and ptag ~= TAG_STRING then
        return nil
    end
    local pm = ctx.prim_meta[ptag]
    if not pm then return nil end
    local fe = types_mod.table_meta_field(ctx, pm, mm_id)
    if not fe then return nil end
    local sig_tid = find(ctx, fe.type_id)
    local st = ctx.types:get(sig_tid)
    if st.tag == TAG_FUNCTION then return sig_tid end
    return nil
end

-- Back-propagate a structural-meta-slot bound (HM Phase 1a). Bound is a
-- TAG_TABLE with one or more meta-slots and an open row var:
-- `{ #__add: (Self, Other) -> R, ... }`. For each meta-slot in the bound,
-- find the corresponding metamethod on the actual via find_metamethod_sig
-- (handles both prim_meta and structural meta-slots), then unify the
-- bound's signature TVs with the actual's signature (contravariant for
-- params, covariant for returns). Same shape as propagate_function_bound,
-- but per-meta-slot instead of for the whole function.
--
-- Also handles named fields in the bound (e.g. `{ x: U, ... }`) by
-- looking the field up on the actual via prim_index for primitives
-- (string:upper(), etc.) or table_field for tables.
--
-- Returns "ok" on success, "missing"/<msg> string on failure.
--: (Ctx, integer, integer) -> string
local function propagate_meta_bound(ctx, actual_tid, bound_tid)
    actual_tid = find(ctx, actual_tid)
    bound_tid  = find(ctx, bound_tid)
    local bt = ctx.types:get(bound_tid)
    if bt.tag ~= TAG_TABLE then return "not_meta_bound" end
    -- Must be open (row var) to be a bound; closed tables are exact-shape requirements.
    if types_mod.tbl_row_var(bt) < 0 then return "not_meta_bound" end

    -- Meta-slots: iterate and back-propagate.
    local meta_start, meta_len = types_mod.tbl_meta_start(bt), types_mod.tbl_meta_len(bt)
    for i = meta_start, meta_start + meta_len - 1 do
        local fid = ctx.lists:get(i)
        local fe  = ctx.fields:get(fid)
        local mm_name = intern_mod.get(ctx.pool, fe.name_id) or "?"
        local bound_sig_tid = find(ctx, fe.type_id)
        local bound_sig     = ctx.types:get(bound_sig_tid)
        if bound_sig.tag ~= TAG_FUNCTION then
            return "metamethod `" .. mm_name .. "` bound is not a function signature"
        end
        local actual_sig_tid = find_metamethod_sig(ctx, actual_tid, mm_name)
        if not actual_sig_tid then
            return "missing metamethod `" .. mm_name .. "`"
        end
        local actual_sig = ctx.types:get(actual_sig_tid)
        -- Back-propagate params (contravariant: bound's free param TV gets actual's param type).
        local apl, bpl = types_mod.fn_params_len(actual_sig), types_mod.fn_params_len(bound_sig)
        local aps, bps = types_mod.fn_params_start(actual_sig), types_mod.fn_params_start(bound_sig)
        local min_p = apl < bpl and apl or bpl
        for j = 0, min_p - 1 do
            local bp_id = ctx.lists:get(bps + j)
            local bp = ctx.types:get(find(ctx, bp_id))
            if bp.tag == TAG_VAR or bp.tag == TAG_ROWVAR then
                local ap_id = find(ctx, ctx.lists:get(aps + j))
                unify_mod.unify(ctx, ap_id, bp_id)
            end
        end
        -- Back-propagate returns (covariant).
        local arl, brl = types_mod.fn_returns_len(actual_sig), types_mod.fn_returns_len(bound_sig)
        local ars, brs = types_mod.fn_returns_start(actual_sig), types_mod.fn_returns_start(bound_sig)
        local min_r = arl < brl and arl or brl
        for j = 0, min_r - 1 do
            local br_id = ctx.lists:get(brs + j)
            local br = ctx.types:get(find(ctx, br_id))
            if br.tag == TAG_VAR or br.tag == TAG_ROWVAR then
                local ar_id = find(ctx, ctx.lists:get(ars + j))
                unify_mod.unify(ctx, ar_id, br_id)
            end
        end
    end

    -- Indexer pairs: iterate (data[2..3]) and back-propagate via indexer lookup.
    -- Bound `{ [K]: V, ... }` requires the actual to have an indexer matching
    -- key K with value type V. For TAG_TABLE actuals, walk the indexer list.
    -- For primitives, the prim_index table is consulted (rare — strings have
    -- prim_index for method names, not for integer indexing).
    do
        local idx_start, idx_len = types_mod.tbl_indexers_start(bt), types_mod.tbl_indexers_len(bt)
        if idx_len > 0 then
            local at_now = ctx.types:get(actual_tid)
            local ix = idx_start
            while ix < idx_start + idx_len - 1 do
                local bk_tid = find(ctx, ctx.lists:get(ix))
                local bv_tid = find(ctx, ctx.lists:get(ix + 1))
                ix = ix + 2
                local actual_value_tid
                if at_now.tag == TAG_TABLE then
                    -- Walk actual's indexers for a matching key (structurally).
                    local ais, ail = types_mod.tbl_indexers_start(at_now), types_mod.tbl_indexers_len(at_now)
                    local aix = ais
                    while aix < ais + ail - 1 do
                        local ak = find(ctx, ctx.lists:get(aix))
                        if unify_mod.try_unify(ctx, bk_tid, ak) then
                            actual_value_tid = find(ctx, ctx.lists:get(aix + 1))
                            break
                        end
                        aix = aix + 2
                    end
                    -- Fallback: integer-literal-keyed fields satisfy `[integer]`
                    -- (Lua table literals `{a, b, c}` type as `{1: a, 2: b, 3: c}`
                    -- — literal-keyed fields, not an explicit indexer). The key
                    -- check is by literal subtyping: bk = integer accepts
                    -- 1: a, 2: b, etc. Returns the union of matching field types.
                    if not actual_value_tid then
                        local matched_value_tids = {} --: { [integer]: integer, ... }
                        local afs, afl = types_mod.tbl_fields_start(at_now), types_mod.tbl_fields_len(at_now)
                        for fi = afs, afs + afl - 1 do
                            local afid = ctx.lists:get(fi)
                            local afe = ctx.fields:get(afid)
                            local fname = intern_mod.get(ctx.pool, afe.name_id)
                            if fname and tonumber(fname) then
                                -- Integer-literal field; its key type is the literal
                                -- integer, which is a subtype of `integer`. Match if
                                -- bk_tid accepts integer (i.e. is integer or wider).
                                if unify_mod.try_unify(ctx, bk_tid, ctx.T_INTEGER) then
                                    matched_value_tids[#matched_value_tids + 1] = find(ctx, afe.type_id)
                                end
                            end
                        end
                        if #matched_value_tids == 1 then
                            actual_value_tid = matched_value_tids[1]
                        elseif #matched_value_tids > 1 then
                            actual_value_tid = types_mod.make_union(ctx, matched_value_tids)
                        end
                    end
                end
                if not actual_value_tid then
                    return "missing indexer `[" .. types_mod.display_short(ctx, bk_tid) .. "]`"
                end
                local bvt = ctx.types:get(bv_tid)
                if bvt.tag == TAG_VAR or bvt.tag == TAG_ROWVAR then
                    unify_mod.unify(ctx, actual_value_tid, bv_tid)
                else
                    if not unify_mod.try_unify(ctx, actual_value_tid, bv_tid) then
                        return "indexer `[" .. types_mod.display_short(ctx, bk_tid) .. "]` value type mismatch"
                    end
                end
            end
        end
    end

    -- Named fields: iterate and back-propagate via field lookup.
    -- For primitives, consult prim_index; for tables, table_field.
    local field_start, field_len = types_mod.tbl_fields_start(bt), types_mod.tbl_fields_len(bt)
    if field_len > 0 then
        local at = ctx.types:get(actual_tid)
        for i = field_start, field_start + field_len - 1 do
            local bfid = ctx.lists:get(i)
            local bfe  = ctx.fields:get(bfid)
            local fname = intern_mod.get(ctx.pool, bfe.name_id) or "?"
            local bf_tid = find(ctx, bfe.type_id)
            -- Resolve the actual's field type.
            local actual_field_tid
            if at.tag == TAG_TABLE then
                local afe = types_mod.table_field(ctx, actual_tid, bfe.name_id)
                if afe then actual_field_tid = find(ctx, afe.type_id) end
            else
                -- Primitive: prim_index lookup.
                local ptag = at.tag
                if ptag == TAG_LITERAL then
                    local k = types_mod.lit_kind(at)
                    if     k == LIT_NUMBER  then ptag = TAG_NUMBER
                    elseif k == LIT_INTEGER then ptag = TAG_INTEGER
                    elseif k == LIT_STRING  then ptag = TAG_STRING
                    else ptag = nil end
                end
                if ptag and ctx.prim_index and ctx.prim_index[ptag] then
                    local pi = ctx.prim_index[ptag]
                    local pfe = types_mod.table_field(ctx, pi, bfe.name_id)
                    if pfe then actual_field_tid = find(ctx, pfe.type_id) end
                end
            end
            if not actual_field_tid then
                return "missing field `" .. fname .. "`"
            end
            -- Bind the bound's field TV (if free) from the actual's field type.
            local bft = ctx.types:get(bf_tid)
            if bft.tag == TAG_VAR or bft.tag == TAG_ROWVAR then
                unify_mod.unify(ctx, actual_field_tid, bf_tid)
            else
                -- Concrete field requirement: try_unify must succeed.
                if not unify_mod.try_unify(ctx, actual_field_tid, bf_tid) then
                    return "field `" .. fname .. "` type mismatch"
                end
            end
        end
    end
    return "ok"
end

local function propagate_function_bound(ctx, actual, resolved_bound)
    local at = ctx.types:get(find(ctx, actual))
    local bt = ctx.types:get(find(ctx, resolved_bound))
    if at.tag ~= TAG_FUNCTION or bt.tag ~= TAG_FUNCTION then return end

    -- Return slots: bind bound's free return TVs from actual's returns.
    local arl, brl = types_mod.fn_returns_len(at), types_mod.fn_returns_len(bt)
    local ars, brs = types_mod.fn_returns_start(at), types_mod.fn_returns_start(bt)
    local min_ret = arl < brl and arl or brl
    for i = 0, min_ret - 1 do
        local ar_id = find(ctx, ctx.lists:get(ars + i))
        local br_id = ctx.lists:get(brs + i)
        local br = ctx.types:get(find(ctx, br_id))
        if br.tag == TAG_VAR or br.tag == TAG_ROWVAR then
            unify_mod.unify(ctx, ar_id, br_id)
        end
    end

    -- Vararg TV: if the bound's vararg slot is a free TV, collect actual's params
    -- as a tuple and bind the TV.  This handles <F: (...P) -> R> where P absorbs
    -- all of F's params as a tuple type (consistent with how (...%P) -> %R in match
    -- binds P to the full param tuple).
    local bva_id = types_mod.fn_vararg(bt)
    if bva_id >= 0 then
        local bva_root = find(ctx, bva_id)
        local bvt = ctx.types:get(bva_root)
        if bvt.tag == TAG_VAR or bvt.tag == TAG_ROWVAR then
            -- Collect actual's regular params as a tuple.
            local param_types = {}
            local aps_va = types_mod.fn_params_start(at)
            for i = 0, types_mod.fn_params_len(at) - 1 do
                param_types[#param_types + 1] = find(ctx, ctx.lists:get(aps_va + i))
            end
            local tuple_id = types_mod.make_tuple(ctx, param_types)
            unify_mod.unify(ctx, tuple_id, bva_root)
        end
    end

    -- Named-param form: if the bound has regular params that are free TVs,
    -- bind them contravariantly from actual's params (e.g. <F: (A, B) -> R>).
    local apl, bpl = types_mod.fn_params_len(at), types_mod.fn_params_len(bt)
    local aps, bps = types_mod.fn_params_start(at), types_mod.fn_params_start(bt)
    local min_param = apl < bpl and apl or bpl
    for i = 0, min_param - 1 do
        local ap_id = find(ctx, ctx.lists:get(aps + i))
        local bp_id = ctx.lists:get(bps + i)
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
--: (Ctx, { [integer]: unknown, ... }) -> boolean | { solved: boolean, await: integer }
local function solve_bound(ctx, c)
    local tv_id    = constrain.bound_tv(c)
    local bound_id = constrain.bound_type(c)
    local line, col = constrain.bound_line(c), constrain.bound_col(c)

    local actual = find(ctx, tv_id)
    local at = ctx.types:get(actual)
    -- Defer: TV not yet bound to a concrete type at the call site.
    if at.tag == TAG_VAR or at.tag == TAG_ROWVAR then
        return await(ctx, c, actual)
    end

    local resolved_bound = find(ctx, bound_id)
    local bt = ctx.types:get(resolved_bound)

    -- Defer if the bound TV itself is still free — e.g. "T: F" where F's fresh
    -- TV has not yet been unified with a concrete type by the C_CALLABLE solver.
    -- Once F is resolved, the next solver pass re-evaluates this constraint.
    if bt.tag == TAG_VAR or bt.tag == TAG_ROWVAR then
        return await(ctx, c, resolved_bound)
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
    if bt.tag == TAG_NAMED and types_mod.named_args_len(bt) == 0 then
        local bound_alias = env_mod.lookup_type(ctx.scope, types_mod.named_name_id(bt))
        local bound_arity = (bound_alias and bound_alias.params) and #bound_alias.params or 0
        if bound_arity > 0 then
            -- Actual type must also be a TAG_NAMED alias with matching arity.
            local actual_arity = 0
            if at.tag == TAG_NAMED and types_mod.named_args_len(at) == 0 then
                local actual_alias = env_mod.lookup_type(ctx.scope, types_mod.named_name_id(at))
                actual_arity = (actual_alias and actual_alias.params) and #actual_alias.params or 0
            end
            -- Primitives and non-generic types have arity 0; they fail the kind check.
            if actual_arity ~= bound_arity then
                local bound_name = intern_mod.get(ctx.pool, types_mod.named_name_id(bt)) or "?"
                local kind_arrows = string.rep("* -> ", bound_arity) .. "*"
                add_error(ctx, line, col,
                    "type `" .. types_mod.display_short(ctx, actual)
                    .. "` has kind *, expected kind " .. kind_arrows
                    .. " (bound `" .. bound_name .. "` requires arity "
                    .. bound_arity .. ")")
                return true  -- terminal: kind mismatch will not flip on retry.
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
        -- Writes are direct (accessors are read-only per types.lua).
        mtt.data[0] = actual
        mtt.data[1] = types_mod.match_arms_start(bt)
        mtt.data[2] = types_mod.match_arms_len(bt)
        local result = match_mod.evaluate(ctx, new_mt)
        if find(ctx, result) == ctx.T_NEVER then
            add_error(ctx, line, col,
                "type argument `" .. types_mod.display_short(ctx, actual)
                .. "` does not satisfy constraint `"
                .. types_mod.display_short(ctx, find(ctx, bound_id)) .. "`")
            return true  -- terminal: match-bound failure won't recover on retry.
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
            return true  -- terminal: non-function actual won't become a function.
        end
        -- Sub-case (b): back-propagate concrete param/return types into bound's free TVs.
        if wa_tag == TAG_FUNCTION and contains_free_var(ctx, resolved_bound) then
            propagate_function_bound(ctx, wa_tid, resolved_bound)
        end
        -- Signature validity: after back-propagation, any concrete slots on both
        -- sides must satisfy function variance (params contravariant, returns
        -- covariant). Free TVs on either side were either bound by the
        -- back-propagation step above or are genuinely unconstrained — try_unify
        -- handles both. Without this check, a bound like `(string) -> R` (with R
        -- free) silently accepts an actual `(integer) -> integer` because
        -- propagate_function_bound only writes into free TVs and never validates
        -- concrete-vs-concrete slots. See HM Phase 1c step 2: callers of
        -- inferred-shape parameters narrow the bound's param TVs from real call
        -- arguments, after which the bound becomes concrete and must agree with
        -- the actual function's signature.
        -- Skip the validity check when the bound uses the vararg-as-tuple
        -- encoding `(...P) -> R`. propagate_function_bound binds the bound's
        -- vararg TV to a tuple of actual's params (Parameters<F>-style); a
        -- direct unify would then compare actual's named-param shape against
        -- a tuple-typed vararg and spuriously reject. The vararg-only form
        -- is recognized by: zero regular params + a vararg slot.
        -- Skip the validity check when the bound has zero named params:
        -- the vararg-as-tuple encoding `(...P) -> R` (Parameters<F>-style)
        -- causes propagate_function_bound to bind the vararg slot to a tuple
        -- of actual's params, which a direct unify against actual's named
        -- params would spuriously reject.
        local bound_named_param_count = types_mod.fn_params_len(bt) or 0
        if wa_tag == TAG_FUNCTION and bound_named_param_count > 0 then
            local widened_actual = find(ctx, widen_deep(ctx, wa_tid))
            local widened_bound  = find(ctx, widen_deep(ctx, resolved_bound))
            local ok, err = unify_mod.unify(ctx, widened_actual, widened_bound)
            if not ok then
                local msg = "type argument `" .. types_mod.display_short(ctx, actual)
                    .. "` does not satisfy constraint `"
                    .. types_mod.display_short(ctx, find(ctx, bound_id)) .. "`"
                if type(err) == "string" and #err > 0 then msg = msg .. ": " .. err end
                add_error(ctx, line, col, msg)
                return true  -- terminal: signature mismatch is definite.
            end
        end
        return true
    end

    -- HM Phase 1a: open-table bounds with meta-slots or named fields are
    -- metamethod-shape constraints (e.g. `<T: { #__add: (T,T) -> T, ... }>`).
    -- The fallthrough try_unify below would reject primitives like `integer`
    -- because they carry metamethods via prim_meta, not as structural meta-
    -- slots. propagate_meta_bound dispatches the same way meta_op_ret_impl
    -- does (prim_meta + table) and back-propagates the bound's free TVs.
    --
    -- TAG_INTERSECTION bounds (composed via make_intersection during body
    -- usage merging) recurse into each member.
    -- Returns nil (not a meta bound → fall through), true (meta-bound
    -- satisfied), or "error" (meta-bound rejected, error already emitted).
    -- "error" is terminal for solve_bound: the failure is definite and a
    -- retry would just re-emit the same diagnostic.
    local function check_meta(actual_check_tid, bound_check_tid)
        local result = propagate_meta_bound(ctx, actual_check_tid, bound_check_tid)
        if result == "not_meta_bound" then return nil end  -- defer to fallback
        if result == "ok" then return true end
        add_error(ctx, line, col,
            "type argument `" .. types_mod.display_short(ctx, actual_check_tid)
            .. "` does not satisfy constraint `"
            .. types_mod.display_short(ctx, bound_check_tid) .. "`: " .. result)
        return "error"
    end
    if bt.tag == TAG_TABLE and types_mod.tbl_row_var(bt) >= 0 then
        local r = check_meta(actual, resolved_bound)
        -- nil → fall through; true → solved; "error" → terminal-after-error.
        if r ~= nil then return true end
    end
    if bt.tag == TAG_INTERSECTION then
        local all_meta = true
        local bms, bml = types_mod.agg_members_start(bt), types_mod.agg_members_len(bt)
        for i = bms, bms + bml - 1 do
            local mid = find(ctx, ctx.lists:get(i))
            local mt  = ctx.types:get(mid)
            if not (mt.tag == TAG_TABLE and types_mod.tbl_row_var(mt) >= 0) then
                all_meta = false
                break
            end
        end
        if all_meta then
            for i = bms, bms + bml - 1 do
                local mid = find(ctx, ctx.lists:get(i))
                check_meta(actual, mid)
                -- Errors (if any) emitted inside check_meta; we still consider
                -- all members so the user sees every failing bound. Terminal.
            end
            return true
        end
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
        return true  -- terminal: bound check failed.
    end
    return true
end

-- HM Phase 1c helpers (declared before solve_index so the body solvers can
-- reference them; bodies execute at runtime but the names need to be in
-- lexical scope at the call sites).

-- Merge a structural bound into ctx.tv_bounds[var_tid]. Multi-usage
-- bodies (e.g. `a + b` and `a.x`) compose via make_intersection.
--: (Ctx, integer, integer) -> ()
local function merge_inferred_bound(ctx, var_tid, bound_tid)
    local existing = ctx.tv_bounds[var_tid]
    if existing then
        ctx.tv_bounds[var_tid] = types_mod.make_intersection(ctx, { existing, bound_tid })
    else
        ctx.tv_bounds[var_tid] = bound_tid
    end
end

-- Build a metamethod-shape bound `{ #op: (Self, Other) -> R, ... }` and merge
-- it. Self is the param tid itself (equi-recursive — verified working).
--: (Ctx, integer, string, integer, integer) -> ()
local function emit_meta_bound(ctx, var_tid, op_name, other_tid, res_tid)
    local var_t = ctx.types:get(var_tid)
    local var_level = types_mod.var_level(var_t)
    local sig_tid = types_mod.make_func(ctx, { var_tid, other_tid }, { res_tid }, -1, nil)
    local op_name_id = intern_mod.intern(ctx.pool, op_name)
    local mm_field = types_mod.make_field(ctx, op_name_id, sig_tid, 0)
    local rowvar = types_mod.make_rowvar(ctx, var_level)
    local bound = types_mod.make_table(ctx, {}, {}, rowvar, { mm_field })
    merge_inferred_bound(ctx, var_tid, bound)
end

-- Build a named-field bound `{ field_name: res_tid, ... }` and merge.
-- Used by solve_index for `t.x` access on a free param var.
--: (Ctx, integer, integer, integer) -> ()
local function emit_field_bound(ctx, var_tid, field_name_id, res_tid)
    local var_t = ctx.types:get(var_tid)
    local var_level = types_mod.var_level(var_t)
    local field = types_mod.make_field(ctx, field_name_id, res_tid, 0)
    local rowvar = types_mod.make_rowvar(ctx, var_level)
    local bound = types_mod.make_table(ctx, { field }, {}, rowvar, {})
    merge_inferred_bound(ctx, var_tid, bound)
end

-- Build an indexer bound `{ [key_tid]: res_tid, ... }` and merge.
-- Used by solve_index for `t[k]` access on a free param var, where k is
-- a typed (non-name) key. propagate_meta_bound's indexer-shape support
-- isn't yet implemented; for now this emits the bound but the call-site
-- check falls through to try_unify, which works for table actuals
-- carrying matching indexers but rejects primitives. (Phase 1c step 7.5
-- TODO: extend propagate_meta_bound to consult prim_index for indexers.)
--: (Ctx, integer, integer, integer) -> ()
local function emit_indexer_bound(ctx, var_tid, key_tid, res_tid)
    local var_t = ctx.types:get(var_tid)
    local var_level = types_mod.var_level(var_t)
    local rowvar = types_mod.make_rowvar(ctx, var_level)
    local bound = types_mod.make_table(ctx, {}, { key_tid, res_tid }, rowvar, {})
    merge_inferred_bound(ctx, var_tid, bound)
end

-- Solve a slot/field index: C_INDEX = { C_INDEX, obj_tid, key_tid, res_tid, line, col }
-- key_tid: TAG_LITERAL(LIT_STRING, name_id) for named field; TAG_LITERAL(LIT_INTEGER, slot) for tuple slot.
-- any: constraint arrays are heterogeneous — see solve_unify comment.
--: (Ctx, { [integer]: unknown, ... }) -> boolean | { solved: boolean, await: integer }
local function solve_index(ctx, c)
    local obj_tid_raw = find(ctx, constrain.index_obj(c))
    local key_tid  = find(ctx, constrain.index_key(c))
    local res_tid  = constrain.index_result(c)
    local line, col = constrain.index_line(c), constrain.index_col(c)

    -- If a producer (solve_check_args, solve_instantiate_at_call, ...) has
    -- claimed res_tid for a future write, defer: every eager fast-path below
    -- binds res_tid unconditionally, which would race the producer. Same
    -- shape as solve_sub's reader-side guard (commit 63c55f18).
    if is_owned(ctx, res_tid) then
        return await(ctx, c, res_tid)
    end

    local key_t = ctx.types:get(key_tid)
    if key_t.tag ~= TAG_LITERAL then
        add_warning_code(ctx, line, col, defs.E.IMPLICIT_ANY)
        bind_to(ctx, res_tid, ctx.T_ANY)
        return true
    end

    -- Opaque table-valued key: t[TC] — look for a FLAG_OPAQUE_KEY field by variable name.
    if types_mod.lit_kind(key_t) == LIT_OPAQUE_KEY then
        local key_name_id = types_mod.lit_str_id(key_t)
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
            return await(ctx, c, obj_tid)
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
            -- No matching opaque field: open table returns unknown, closed returns any.
            -- Closed-table fallback to any is implicit — emit IMPLICIT_ANY so the user
            -- sees that inference gave up.
            if types_mod.tbl_row_var(obj_t) >= 0 then
                bind_to(ctx, res_tid, ctx.T_UNKNOWN)
            else
                add_warning_code(ctx, line, col, defs.E.IMPLICIT_ANY)
                bind_to(ctx, res_tid, ctx.T_ANY)
            end
            return true
        end
        -- Not a table (and not any/unknown/never/var, which are handled above):
        -- inference cannot determine a result type — emit IMPLICIT_ANY.
        add_warning_code(ctx, line, col, defs.E.IMPLICIT_ANY)
        bind_to(ctx, res_tid, ctx.T_ANY)
        return true
    end

    if types_mod.lit_kind(key_t) == LIT_INTEGER then
        -- Tuple slot projection
        local slot = types_mod.lit_str_id(key_t)
        local obj_tid = find(ctx, obj_tid_raw)
        local obj_t = ctx.types:get(obj_tid)
        -- Splice semantics: unwrap TAG_SPREAD up front so every slot-typing
        -- branch below (TAG_TUPLE, TAG_UNION, the scalar fallback, ...)
        -- handles the spread's actual inner type directly — same as
        -- `(true, ...R)` splicing R's elements (docs/semantics.md §7.1;
        -- lib/type/static/CLAUDE.md). No separate spread-specific branch.
        if obj_t.tag == defs.TAG_SPREAD then
            obj_tid = find(ctx, types_mod.spread_inner(obj_t))
            obj_t = ctx.types:get(obj_tid)
        end
        -- HM Phase 1c step 7: free param + integer-key access → emit
        -- `{ [integer]: V, ... }` bound. The bound captures "this param
        -- has integer-keyed indexer access"; specific tuple-slot semantics
        -- (slot < tuple length) are deferred until the actual is resolved
        -- at the call site. For now use ctx.T_INTEGER as the bound's key.
        if obj_t.tag == TAG_VAR and band(obj_t.flags, FLAG_SUB_SOLVE_PARAM) ~= 0 then
            emit_indexer_bound(ctx, obj_tid, ctx.T_INTEGER, res_tid)
            return true
        end
        if obj_t.tag == TAG_VAR or obj_t.tag == TAG_ROWVAR then
            return await(ctx, c, obj_tid)
        end
        if obj_t.tag == TAG_TUPLE then
            if slot < types_mod.agg_members_len(obj_t) then
                unify_mod.unify(ctx, res_tid, find(ctx, ctx.lists:get(types_mod.agg_members_start(obj_t) + slot)))
            else
                bind_to(ctx, res_tid, ctx.T_NIL)
            end
            return true
        end
        if obj_t.tag == TAG_TABLE then
            -- 1) Positional/integer-named field: `{1, 2, 3}` uses fields named "1", "2", "3".
            local slot_name_id = intern_mod.intern(ctx.pool, tostring(slot))
            local fe = types_mod.table_field(ctx, obj_tid, slot_name_id)
            if fe then
                local ft = find(ctx, fe.type_id)
                if band(fe.flags, FLAG_OPTIONAL) ~= 0 then
                    ft = types_mod.make_union(ctx, { ft, ctx.T_NIL })
                end
                unify_mod.unify(ctx, res_tid, ft)
                return true
            end
            -- 2) Integer/number indexer: `{ [integer]: T }` (FFI fixed-size arrays land
            --    here when cdef declares `int32_t[N]`) or `{ [number]: T }`.
            --    Literal-integer key matches base integer/number indexer or matching literal key.
            local is, il = types_mod.tbl_indexers_start(obj_t), types_mod.tbl_indexers_len(obj_t)
            local i = is
            while i < is + il - 1 do
                local kt   = find(ctx, ctx.lists:get(i))
                local kt_t = ctx.types:get(kt)
                if kt_t.tag == TAG_INTEGER or kt_t.tag == TAG_NUMBER then
                    unify_mod.unify(ctx, res_tid, find(ctx, ctx.lists:get(i + 1)))
                    return true
                end
                if kt_t.tag == TAG_LITERAL
                    and (types_mod.lit_kind(kt_t) == LIT_INTEGER or types_mod.lit_kind(kt_t) == LIT_NUMBER)
                    and types_mod.lit_str_id(kt_t) == slot then
                    unify_mod.unify(ctx, res_tid, find(ctx, ctx.lists:get(i + 1)))
                    return true
                end
                i = i + 2
            end
            -- Fallback: preserve the "slot 0 is the value itself" semantics so multi-return
            -- slot extraction (LOCAL_STMT / ASSIGN_STMT emit C_INDEX(call_ret, 0) to project
            -- the first return slot) works when the function returns a plain non-tuple table
            -- (e.g. `local m = require("mod")` where mod's return type is a TAG_TABLE).
            -- For other slots, no value exists.
            if slot == 0 then
                unify_mod.unify(ctx, res_tid, obj_tid)
            else
                bind_to(ctx, res_tid, ctx.T_NIL)
            end
            return true
        end
        if obj_t.tag == TAG_UNION then
            local parts = {}
            local oms, oml = types_mod.agg_members_start(obj_t), types_mod.agg_members_len(obj_t)
            for i = oms, oms + oml - 1 do
                local arm = find(ctx, ctx.lists:get(i))
                local arm_t = ctx.types:get(arm)
                if arm_t.tag == TAG_TUPLE and slot < types_mod.agg_members_len(arm_t) then
                    parts[#parts + 1] = find(ctx, ctx.lists:get(types_mod.agg_members_start(arm_t) + slot))
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
        -- Non-tuple: slot 0 = the value itself, others = nil
        if slot == 0 then
            unify_mod.unify(ctx, res_tid, obj_tid)
        else
            bind_to(ctx, res_tid, ctx.T_NIL)
        end
        return true
    end

    -- LIT_STRING key: named field access (was solve_has_field)
    local name_id  = types_mod.lit_str_id(key_t)
    local obj_tid  = resolve_ffic(ctx, find(ctx, obj_tid_raw))
    local obj_t = ctx.types:get(obj_tid)

    -- HM Phase 1c: free param + field access → emit `{ field: res, ... }` bound.
    -- Body usage `t.x` constrains `t` to be a record with field `x`. The bound
    -- is merged into tv_bounds; at call site, propagate_meta_bound checks
    -- the actual has the field via prim_index for primitives or table_field
    -- for tables. res_tid is the bound's field type — at call site it gets
    -- unified with the actual's field type, propagating downstream.
    if obj_t.tag == TAG_VAR and band(obj_t.flags, FLAG_SUB_SOLVE_PARAM) ~= 0 then
        emit_field_bound(ctx, obj_tid, name_id, res_tid)
        return true
    end

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
        local nom_identity = types_mod.nom_identity(obj_t)
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
                    return true  -- terminal: result bound to any.
                end
            else
                -- One-arg $Opaque<T>: no field access.
                add_error(ctx, line, col,
                    "cannot access fields of opaque type — use unseal to recover inner type")
                bind_to(ctx, res_tid, ctx.T_ANY)
                return true  -- terminal: result bound to any.
            end
        end
        obj_tid = find(ctx, types_mod.nom_underlying(obj_t))
        obj_t   = ctx.types:get(obj_tid)
    end

    -- Primitive field lookup via prim_index (string/number/integer methods).
    -- Normalize TAG_LITERAL to its base primitive tag first.
    do
        local base_tag = obj_t.tag
        if base_tag == TAG_LITERAL then
            local kind = types_mod.lit_kind(obj_t)
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
            return true  -- terminal: result bound to any.
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
                    return true  -- terminal: result bound to any.
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
        local ofs, ofl = types_mod.tbl_fields_start(obj_t), types_mod.tbl_fields_len(obj_t)
        for si = ofs, ofs + ofl - 1 do
            local sfe = ctx.fields:get(ctx.lists:get(si))
            if sfe.name_id == -1 then
                local sp_t = ctx.types:get(find(ctx, sfe.type_id))
                if sp_t.tag == TAG_SPREAD then
                    local inner_tid = find(ctx, types_mod.spread_inner(sp_t))
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
                        local ims, iml = types_mod.agg_members_start(inner_t), types_mod.agg_members_len(inner_t)
                        for ai = ims, ims + iml - 1 do
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
        local is, il = types_mod.tbl_indexers_start(obj_t), types_mod.tbl_indexers_len(obj_t)
        local i = is
        while i < is + il - 1 do
            local kt = find(ctx, ctx.lists:get(i))
            if ctx.types:get(kt).tag == TAG_STRING then
                unify_mod.unify(ctx, res_tid, find(ctx, ctx.lists:get(i + 1)))
                return true
            end
            i = i + 2
        end
        -- __index prototype chain: Lua metatable lookup.
        -- Handles setmetatable({}, Proto) where Proto has the field.
        do
            local proto_ft, proto_flags = field_via_index_chain(ctx, obj_tid, name_id, 0)
            if proto_ft then
                if proto_flags and band(proto_flags, defs.FLAG_OPTIONAL) ~= 0 then
                    proto_ft = types_mod.make_union(ctx, { proto_ft, ctx.T_NIL })
                end
                unify_mod.unify(ctx, res_tid, proto_ft)
                return true
            end
        end
        -- Open table with a row variable: follow the row variable chain to find
        -- the field, or extend the deepest free row variable with a new field.
        --
        -- This only applies to INFERENCE row variables (FLAG_ROWVAR_INFER).
        -- Declared open records { name: string, ... } use a plain row variable
        -- and accessing an unlisted field on them returns unknown.  Inference
        -- row variables are marked FLAG_ROWVAR_INFER and are created by the
        -- TAG_VAR/TAG_ROWVAR branch below when an unannotated parameter is first
        -- accessed.  They MUST be extended so that multiple field accesses on the
        -- same unannotated parameter each get their own fresh type variable.
        if types_mod.tbl_row_var(obj_t) >= 0 then
            -- Walk the row variable chain to find the deepest free var.
            -- Along the way, check fields in intermediate tables.
            local row_tid = find(ctx, types_mod.tbl_row_var(obj_t))
            for _ = 1, 64 do  -- cycle-safe depth limit
                local row_t = ctx.types:get(row_tid)
                if row_t.tag == TAG_VAR or row_t.tag == TAG_ROWVAR then
                    -- Reached a free row variable.
                    -- Only extend if it was created for inference (FLAG_ROWVAR_INFER).
                    if band(row_t.flags, FLAG_ROWVAR_INFER) ~= 0 then
                        local field_var = types_mod.make_var(ctx, 0)
                        local new_row   = types_mod.make_rowvar(ctx, 0)
                        -- Propagate the inference flag so the chain stays extensible.
                        ctx.types:get(new_row).flags = bor(
                            ctx.types:get(new_row).flags, FLAG_ROWVAR_INFER)
                        local fid2    = types_mod.make_field(ctx, name_id, field_var, false)
                        local ext_tbl = types_mod.make_table(ctx, { fid2 }, {}, new_row, {})
                        unify_mod.unify(ctx, row_tid, ext_tbl)
                        unify_mod.unify(ctx, res_tid, field_var)
                        return true
                    end
                    -- Non-inference row var: declared open record; fall through to unknown.
                    break
                elseif row_t.tag == TAG_TABLE then
                    -- Row was already extended by a previous field access.
                    -- Check if the field we want is in this intermediate table.
                    local row_fe = types_mod.table_field(ctx, row_tid, name_id)
                    if row_fe then
                        local ft = find(ctx, row_fe.type_id)
                        if band(row_fe.flags, FLAG_OPTIONAL) ~= 0 then
                            ft = types_mod.make_union(ctx, { ft, ctx.T_NIL })
                        end
                        unify_mod.unify(ctx, res_tid, ft)
                        return true
                    end
                    -- Field not here; follow this table's own row variable deeper.
                    if types_mod.tbl_row_var(row_t) >= 0 then
                        row_tid = find(ctx, types_mod.tbl_row_var(row_t))
                    else
                        break  -- closed intermediate table; fall through to unknown
                    end
                else
                    break  -- unexpected type in chain; fall through to unknown
                end
            end
            bind_to(ctx, res_tid, ctx.T_UNKNOWN)
            return true
        end
        local fname = intern_mod.get(ctx.pool, name_id) or "?"
        add_error(ctx, line, col, "field `" .. fname .. "` doesn't exist")
        bind_to(ctx, res_tid, ctx.T_ANY)
        return true  -- terminal: result bound to any.
    end

    if obj_t.tag == TAG_VAR or obj_t.tag == TAG_ROWVAR then
        -- Open table: add the field constraint by binding var to a table with this field.
        -- Mark the row variable with FLAG_ROWVAR_INFER so that subsequent field accesses
        -- on the same object (after it resolves to the created table) can extend the chain
        -- rather than returning unknown.
        local field_var = types_mod.make_var(ctx, 0)
        local row_var   = types_mod.make_rowvar(ctx, 0)
        ctx.types:get(row_var).flags = bor(ctx.types:get(row_var).flags, FLAG_ROWVAR_INFER)
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
            elseif types_mod.tbl_row_var(mt) >= 0 then
                return {}, true, false, false
            else
                return {}, false, true, false
            end
        end
        if mt.tag == TAG_INTERSECTION then
            -- Distribute: field must be reachable from each member that is a closed type.
            -- Collect types from all members; any_open means result may contain unknown.
            local ftypes, any_open2, all_miss2 = {}, false, true
            local mms, mml = types_mod.agg_members_start(mt), types_mod.agg_members_len(mt)
            for i = mms, mms + mml - 1 do
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
            local ums, uml = types_mod.agg_members_start(mt), types_mod.agg_members_len(mt)
            for i = ums, ums + uml - 1 do
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
        local ums, uml = types_mod.agg_members_start(obj_t), types_mod.agg_members_len(obj_t)
        for i = ums, ums + uml - 1 do
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
        -- Field exists in no union arm: the access is dead code. Result is `never`
        -- (the type of expressions that cannot produce a value). Returning `any` here
        -- would let downstream constraints succeed silently on the stripped type.
        bind_to(ctx, res_tid, ctx.T_NEVER)
        return true  -- terminal: result bound to never.
    end

    if obj_t.tag == TAG_INTERSECTION then
        -- Field must exist in at least one member; if any open member, result may exist.
        -- Closed members that lack the field are simply not a source of it (the value
        -- satisfies all members, so it may still carry the field from another member).
        local field_types = {}
        local any_open = false
        local all_miss = true
        local ims, iml = types_mod.agg_members_start(obj_t), types_mod.agg_members_len(obj_t)
        for i = ims, ims + iml - 1 do
            local mid = find(ctx, ctx.lists:get(i))
            local mt  = ctx.types:get(mid)
            if mt.tag == TAG_TABLE then
                local fe = types_mod.table_field(ctx, mid, name_id)
                if fe then
                    field_types[#field_types + 1] = find(ctx, fe.type_id)
                    all_miss = false
                else
                    -- Also follow __index prototype chain for this member.
                    local proto_ft = field_via_index_chain(ctx, mid, name_id, 0)
                    if proto_ft then
                        field_types[#field_types + 1] = proto_ft
                        all_miss = false
                    elseif types_mod.tbl_row_var(mt) >= 0 then
                        any_open = true
                        all_miss = false
                    end
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
            -- Field exists in no intersection member: dead code; result is never.
            bind_to(ctx, res_tid, ctx.T_NEVER)
            return true  -- terminal: result bound to never.
        end
        if any_open then field_types[#field_types + 1] = ctx.T_UNKNOWN end
        local result = #field_types == 0 and ctx.T_UNKNOWN
            or #field_types == 1 and field_types[1]
            or types_mod.make_union(ctx, field_types)
        bind_to(ctx, res_tid, result)
        return true
    end

    -- For any other type, inference cannot determine a result type — emit IMPLICIT_ANY.
    add_warning_code(ctx, line, col, defs.E.IMPLICIT_ANY)
    bind_to(ctx, res_tid, ctx.T_ANY)
    return true
end

-- any: constraint arrays are heterogeneous — see solve_unify comment.
--: (Ctx, { [integer]: unknown, ... }) -> boolean
local function solve_callable(ctx, c)
    local callee_raw = constrain.callable_callee(c)   -- raw stored id (may be TAG_VAR for method calls)
    local callee_tid = find(ctx, callee_raw)
    local arg_tids   = constrain.callable_args_list(c)
    local ret_tid    = constrain.callable_ret(c)
    local line, col  = constrain.callable_line(c), constrain.callable_col(c)
    local callee_t   = ctx.types:get(callee_tid)
    -- Claim ret_tid: this handler commits to binding it before returning
    -- (every terminal-success path below ends with bind_to/unify on
    -- ret_tid). Until that bind fires, any cross-statement C_SUB whose
    -- actual side is this ret_TV must defer instead of racing ahead with
    -- an eager unify. See docs/typechecker-phase-f-blocker.md.
    claim(ctx, ret_tid, c)

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
        callee_tid = find(ctx, types_mod.nom_underlying(callee_t))
        callee_t   = ctx.types:get(callee_tid)
    end

    if callee_t.tag == TAG_VAR or callee_t.tag == TAG_ROWVAR then
        -- HM Phase 1c step 2: free callee that is a sub-solve param emits a
        -- function-shape bound `(arg_types...) -> R`, registered into
        -- ctx.tv_bounds. At call site, propagate_function_bound (in
        -- solve_bound) decomposes the actual function's signature into the
        -- bound's free TVs.
        if callee_t.tag == TAG_VAR and band(callee_t.flags, FLAG_SUB_SOLVE_PARAM) ~= 0 then
            local var_t = ctx.types:get(callee_tid)
            local var_level = types_mod.var_level(var_t)
            local r_var = types_mod.make_var(ctx, var_level)
            local sig_tid = types_mod.make_func(ctx, arg_tids, { r_var }, -1, nil)
            merge_inferred_bound(ctx, callee_tid, sig_tid)
            unify_mod.unify(ctx, ret_tid, r_var)
            return true
        end
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
        local pl = types_mod.fn_params_len(callee_t)
        local has_names = types_mod.fn_param_names_len(callee_t) > 0
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
        -- Givens-before-wanteds (item 2): the per-param bind loop below runs
        -- unify on each (arg, param) pair; when one of those binds wakes a
        -- GIVEN waiter (typically a C_BOUND on the param TV carrying the
        -- rank-N kind signature `<F: (A,B)->R>`), unify.bind_var_to_type sets
        -- ctx._bind_woke_given. We then defer the rest of the loop so the
        -- woken GIVEN gets to back-propagate A/B/R into still-free params
        -- before we attempt to unify them with raw arg types — without that
        -- ordering, the wanted bind would absorb the wrong A/B values and
        -- silently mask call-site mismatches. Replaces the prior ad-hoc
        -- C_BOUND peek scan: the discipline is now uniform across every
        -- WANTED bind, dispatched at the union-find chokepoint.
        local ps_main = types_mod.fn_params_start(callee_t)
        for i = 0, pl - 1 do
            local raw_param_tid = ctx.lists:get(ps_main + i)
            local exp_tid = find(ctx, raw_param_tid)
            local act_tid = arg_tids[i + 1]
            if act_tid then
                -- Fast path: try direct assignability (preserves literal-to-literal/union).
                -- Skip when exp_tid contains free vars: try_unify is read-only and won't bind them.
                -- Skip for closed table params: the full unify path enforces the excess-field check.
                local act_r = find(ctx, act_tid)
                local et = ctx.types:get(exp_tid)
                local param_is_closed_table = et.tag == TAG_TABLE and types_mod.tbl_row_var(et) < 0
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
                        local atms, atml = types_mod.agg_members_start(act_t), types_mod.agg_members_len(act_t)
                        for mi = atms, atms + atml - 1 do
                            local mid = find(ctx, ctx.lists:get(mi))
                            if not unify_mod.try_unify(ctx, mid, exp_tid) then
                                failing[#failing + 1] = mid
                            end
                        end
                        local total = atml
                        if #failing > 0 and #failing < total then
                            local fail_tid = #failing == 1 and failing[1]
                                or types_mod.make_union(ctx, failing)
                            local param_name = nil
                            if has_names then
                                local name_id = ctx.lists:get(types_mod.fn_param_names_start(callee_t) + i)
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
            -- Givens-before-wanteds: if the bind that just fired woke a
            -- GIVEN waiter (e.g. C_BOUND back-propagating from a rank-N
            -- kind signature), defer the rest of the param loop. The GIVEN
            -- will re-fire on this round, rewrite still-free params with
            -- their declared types, and re-wake this constraint to retry.
            if ctx._bind_woke_given then
                return false
            end
        end
        -- Handle extra args against the function's vararg slot.
        -- This covers calls like wrap(f, 5) where wrap is <F: (...P)->R, P, R>(f: F, ...P)->R:
        -- after C_BOUND back-propagates P from F's concrete params, P_fresh is a TAG_TUPLE
        -- and each extra arg must satisfy the corresponding tuple slot.
        local va_id = types_mod.fn_vararg(callee_t)
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
                    if slot_idx < types_mod.agg_members_len(vat) then
                        exp_slot = find(ctx, ctx.lists:get(types_mod.agg_members_start(vat) + slot_idx))
                    else
                        exp_slot = ctx.T_NIL  -- more args than tuple slots
                    end
                    local act_tid = arg_tids[ei + 1]
                    local ok, err = unify_mod.unify(ctx, widen_literal(ctx, act_tid), exp_slot)
                    if not ok then
                        local err_s = err
                        add_error(ctx, line, col,
                            "argument " .. (ei + 1) .. ": cannot pass `"
                            .. types_mod.display_short(ctx, act_tid)
                            .. "` where `"
                            .. types_mod.display_short(ctx, exp_slot) .. "` expected"
                            .. (err_s ~= nil and (": " .. err_s) or ""))
                    end
                end
            end
            -- If vararg is TAG_ANY or other non-tuple type, extra args are accepted silently.
        end
        -- Unify return
        local rl = types_mod.fn_returns_len(callee_t)
        local rs_main = types_mod.fn_returns_start(callee_t)
        if rl == 0 then
            unify_mod.unify(ctx, ret_tid, ctx.T_NIL)
        elseif rl == 1 then
            local first_ret = find(ctx, ctx.lists:get(rs_main))
            -- Parameterized intrinsic return: evaluate deferred TAG_TYPE_CALL(TAG_INTRINSIC,...)
            -- now that all type variables from argument unification are bound.
            -- E.g. $Require<T> where T was bound to LIT_STRING("mod") during param unification.
            first_ret = resolve_deferred_intrinsic(ctx, first_ret)
            unify_mod.unify(ctx, ret_tid, first_ret)
        else
            -- Multiple return values: assemble TAG_TUPLE so C_INDEX can project slots.
            local slots = {}
            for ri = 0, rl - 1 do
                slots[ri + 1] = find(ctx, ctx.lists:get(rs_main + ri))
            end
            unify_mod.unify(ctx, ret_tid, types_mod.make_tuple(ctx, slots))
        end
        return true
    end

    -- Intersection: overload dispatch — first matching overload wins.
    if callee_t.tag == TAG_INTERSECTION then
        local members = {}
        local cms, cml = types_mod.agg_members_start(callee_t), types_mod.agg_members_len(callee_t)
        for i = cms, cms + cml - 1 do
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
            return true  -- terminal: result bound to any after error.
        end
        -- Try each overload; first whose params all accept returns immediately.
        for _, m in ipairs(members) do
            local ft = m.t
            local ok = true
            local fps = types_mod.fn_params_start(ft)
            local fpl = types_mod.fn_params_len(ft)
            for j = 0, fpl - 1 do
                local exp_tid = find(ctx, ctx.lists:get(fps + j))
                local act_tid = arg_tids[j + 1]
                if act_tid and not unify_mod.try_unify(ctx, find(ctx, act_tid), exp_tid) then
                    ok = false; break
                end
            end
            if ok then
                local rl = types_mod.fn_returns_len(ft)
                if rl == 0 then
                    bind_to(ctx, ret_tid, ctx.T_NIL)
                else
                    local first_ret = find(ctx, ctx.lists:get(types_mod.fn_returns_start(ft)))
                    first_ret = resolve_deferred_intrinsic(ctx, first_ret)
                    bind_to(ctx, ret_tid, first_ret)
                end
                return true
            end
        end
        -- No overload matched: report with candidates
        local cands = {}
        for ci, m in ipairs(members) do
            local ft = m.t
            --: { [integer]: string, ... }
            local reasons = {}
            local fps = types_mod.fn_params_start(ft)
            local fpl = types_mod.fn_params_len(ft)
            for j = 0, fpl - 1 do
                local exp_tid = find(ctx, ctx.lists:get(fps + j))
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
        return true  -- terminal: result bound to any after error.
    end

    -- Union: ALL members must accept the argument (sound — we don't know which branch is live).
    if callee_t.tag == TAG_UNION then
        local ret_types = {}
        --: { [integer]: string, ... }
        local fail_msgs = {}
        local ums, uml = types_mod.agg_members_start(callee_t), types_mod.agg_members_len(callee_t)
        for i = ums, ums + uml - 1 do
            local mid = find(ctx, ctx.lists:get(i))
            local mt  = ctx.types:get(mid)
            if mt.tag ~= TAG_FUNCTION then
                fail_msgs[#fail_msgs + 1] = "union member `"
                    .. types_mod.display_short(ctx, mid) .. "` is not callable"
            else
                local member_ok = true
                local mps = types_mod.fn_params_start(mt)
                local mpl = types_mod.fn_params_len(mt)
                for j = 0, mpl - 1 do
                    local exp_tid = find(ctx, ctx.lists:get(mps + j))
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
                    local rl = types_mod.fn_returns_len(mt)
                    ret_types[#ret_types + 1] = rl > 0
                        and find(ctx, ctx.lists:get(types_mod.fn_returns_start(mt)))
                        or  ctx.T_NIL
                end
            end
        end
        if #fail_msgs > 0 then
            add_error(ctx, line, col, fail_msgs[1])
            bind_to(ctx, ret_tid, ctx.T_ANY)
            return true  -- terminal: result bound to any after error.
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
    return true  -- terminal: result bound to any after error.
end

-- any: constraint arrays are heterogeneous — see solve_unify comment.
-- c[2] is a string (op_name like "__add"), remaining fields are integers.
--: (Ctx, { [integer]: unknown, ... }) -> boolean | nil
local function solve_arith(ctx, c)
    local op_name  = constrain.arith_op(c)
    local lhs_raw  = constrain.arith_lhs(c)
    local rhs_raw  = constrain.arith_rhs(c)
    local lhs_tid  = find(ctx, lhs_raw)
    local rhs_tid  = find(ctx, rhs_raw)
    local res_tid  = constrain.arith_result(c)
    local line, col = constrain.arith_line(c), constrain.arith_col(c)

    -- HM Phase 1c: if an operand is a free param of the function currently
    -- being sub-solved, register a metamethod-shape bound on it instead of
    -- deferring. The bound captures the body's structural requirement (e.g.
    -- `a + b` requires `a` to have `__add: (a, b) -> R`); at call sites the
    -- bound is checked via solve_bound's propagate_meta_bound (Phase 1a).
    local lhs_t = ctx.types:get(lhs_tid)
    local rhs_t = ctx.types:get(rhs_tid)
    do
        local lhs_is_param = lhs_t.tag == TAG_VAR and band(lhs_t.flags, FLAG_SUB_SOLVE_PARAM) ~= 0
        local rhs_is_param = rhs_t.tag == TAG_VAR and band(rhs_t.flags, FLAG_SUB_SOLVE_PARAM) ~= 0
        if lhs_is_param then
            emit_meta_bound(ctx, lhs_tid, op_name, rhs_tid, res_tid)
        end
        if rhs_is_param and lhs_tid ~= rhs_tid then
            -- Symmetric bound on rhs (skip if same tid as lhs to avoid duplicate).
            emit_meta_bound(ctx, rhs_tid, op_name, lhs_tid, res_tid)
        end
        if lhs_is_param or rhs_is_param then
            -- Bound(s) registered; the bound's signature has the result tid
            -- as the return slot, so res_tid is connected to the bound's R.
            -- The actual __op result type resolves at call sites when
            -- propagate_meta_bound back-propagates the metamethod's signature.
            return true
        end
    end

    -- Defer if either operand is not yet resolved (callsite hasn't bound params yet).
    if lhs_t.tag == TAG_VAR or lhs_t.tag == TAG_ROWVAR then return false end
    if rhs_t.tag == TAG_VAR or rhs_t.tag == TAG_ROWVAR then return false end

    -- Auto-unwrap TAG_NOMINAL (newtype) for metamethod dispatch — mirrors the
    -- field-access unwrap. Newtypes inherit their underlying type's operators;
    -- the result type is the underlying type's metamethod result, which means
    -- arithmetic "promotes" newtypes back to their underlying type. Walk down
    -- recursively in case of nested newtypes.
    while lhs_t.tag == TAG_NOMINAL do
        lhs_tid = find(ctx, types_mod.nom_underlying(lhs_t))
        lhs_t   = ctx.types:get(lhs_tid)
    end
    while rhs_t.tag == TAG_NOMINAL do
        rhs_tid = find(ctx, types_mod.nom_underlying(rhs_t))
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
        return true  -- terminal: result bound to a primitive after error.
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
--: (Ctx, { [integer]: unknown, ... }) -> boolean
local function solve_compare(ctx, c)
    local lhs_raw = constrain.compare_lhs(c)
    local rhs_raw = constrain.compare_rhs(c)
    local lhs_tid = find(ctx, lhs_raw)
    local rhs_tid = find(ctx, rhs_raw)
    local line, col = constrain.compare_line(c), constrain.compare_col(c)

    -- HM Phase 1c step 4: bound emission for free param operands. Same
    -- pattern as solve_arith. The result is hardwired to boolean (set at
    -- constraint emit time in constrain.lua), so we use a fresh discard
    -- var as the bound's R slot — comparison's signature is morally
    -- `(Self, Other) -> boolean`, but the propagate_meta_bound check just
    -- needs to find `__lt` on the actual.
    local lhs_t = ctx.types:get(lhs_tid)
    local rhs_t = ctx.types:get(rhs_tid)
    do
        local lhs_is_param = lhs_t.tag == TAG_VAR and band(lhs_t.flags, FLAG_SUB_SOLVE_PARAM) ~= 0
        local rhs_is_param = rhs_t.tag == TAG_VAR and band(rhs_t.flags, FLAG_SUB_SOLVE_PARAM) ~= 0
        if lhs_is_param then
            local r_discard = types_mod.make_var(ctx, types_mod.var_level(lhs_t))
            emit_meta_bound(ctx, lhs_tid, "__lt", rhs_tid, r_discard)
        end
        if rhs_is_param and lhs_tid ~= rhs_tid then
            local r_discard = types_mod.make_var(ctx, types_mod.var_level(rhs_t))
            emit_meta_bound(ctx, rhs_tid, "__lt", lhs_tid, r_discard)
        end
        if lhs_is_param or rhs_is_param then
            return true
        end
    end

    -- Defer if either operand is not yet resolved (callsite hasn't bound params yet).
    if lhs_t.tag == TAG_VAR or lhs_t.tag == TAG_ROWVAR then return false end
    if rhs_t.tag == TAG_VAR or rhs_t.tag == TAG_ROWVAR then return false end

    -- Auto-unwrap TAG_NOMINAL (newtype) for metamethod dispatch — mirrors
    -- solve_arith. Newtypes inherit their underlying type's operators.
    while lhs_t.tag == TAG_NOMINAL do
        lhs_tid = find(ctx, types_mod.nom_underlying(lhs_t))
        lhs_t   = ctx.types:get(lhs_tid)
    end
    while rhs_t.tag == TAG_NOMINAL do
        rhs_tid = find(ctx, types_mod.nom_underlying(rhs_t))
        rhs_t   = ctx.types:get(rhs_tid)
    end

    -- Dispatch via metamethod lookup: __lt is the canonical comparison metamethod
    -- (Lua semantics: `<`, `>`, `<=`, `>=` all reduce to `__lt` / `__le`; `__le`
    -- falls back to `__lt` when missing). Both operands must support `__lt`.
    -- Mirrors solve_arith: prim_meta for primitives, table meta for user types.
    local lr = meta_op_ret_impl(ctx, "__lt", lhs_tid)
    local rr = meta_op_ret_impl(ctx, "__lt", rhs_tid)

    if lr == nil then
        add_error(ctx, line, col,
            "cannot compare `" .. types_mod.display_short(ctx, lhs_tid) .. "` with `<`")
        return true  -- terminal: no comparison metamethod on lhs.
    end
    if rr == nil then
        add_error(ctx, line, col,
            "cannot compare `" .. types_mod.display_short(ctx, rhs_tid) .. "` with `<`")
        return true  -- terminal: no comparison metamethod on rhs.
    end

    -- Cross-type check: verify the rhs is assignable to the second parameter of
    -- the lhs's __lt metamethod (and vice versa). This faithfully simulates the
    -- metamethod call: `__lt: (number, number) -> boolean` for `number` rejects
    -- a string rhs, because rhs is not assignable to the second param. This is
    -- not a special-case predicate — it's the metamethod's declared signature
    -- being honored, the same way C_CALLABLE would honor it.
    local function meta_op_fn(ctx, tid)
        tid = find(ctx, tid)
        local t = ctx.types:get(tid)
        while t.tag == TAG_NOMINAL do
            tid = find(ctx, types_mod.nom_underlying(t))
            t   = ctx.types:get(tid)
        end
        local mm_id = intern_mod.intern(ctx.pool, "__lt")
        if t.tag == TAG_TABLE then
            local fe = types_mod.table_meta_field(ctx, tid, mm_id)
            if fe then return find(ctx, fe.type_id) end
            return nil
        end
        local ptag = t.tag
        if ptag == TAG_LITERAL then
            local k = types_mod.lit_kind(t)
            if k == LIT_NUMBER  then ptag = TAG_NUMBER
            elseif k == LIT_INTEGER then ptag = TAG_INTEGER
            elseif k == LIT_STRING  then ptag = TAG_STRING
            else return nil end
        elseif ptag ~= TAG_NUMBER and ptag ~= TAG_INTEGER and ptag ~= TAG_STRING then
            return nil
        end
        local pm = ctx.prim_meta[ptag]
        if not pm then return nil end
        local fe = types_mod.table_meta_field(ctx, pm, mm_id)
        if fe then return find(ctx, fe.type_id) end
        return nil
    end

    local function check_against(fn_tid, a_tid, b_tid)
        if fn_tid == nil then return true end
        local ft = ctx.types:get(fn_tid)
        if ft.tag ~= TAG_FUNCTION or types_mod.fn_params_len(ft) < 2 then return true end
        local fps = types_mod.fn_params_start(ft)
        local p1 = find(ctx, ctx.lists:get(fps))
        local p2 = find(ctx, ctx.lists:get(fps + 1))
        return unify_mod.try_unify(ctx, a_tid, p1) and unify_mod.try_unify(ctx, b_tid, p2)
    end

    local lhs_fn = meta_op_fn(ctx, lhs_tid)
    local rhs_fn = meta_op_fn(ctx, rhs_tid)
    -- Skip cross-type check when either operand resolved to any/unknown via prim_meta
    -- (meta_op_fn returns nil for those; we already gated lr/rr above).
    if not check_against(lhs_fn, lhs_tid, rhs_tid) and not check_against(rhs_fn, lhs_tid, rhs_tid) then
        add_error(ctx, line, col,
            "cannot compare `" .. types_mod.display_short(ctx, lhs_tid)
            .. "` with `" .. types_mod.display_short(ctx, rhs_tid) .. "`")
        return true  -- terminal: cross-type comparison check failed.
    end
    return true
end

-- any: constraint arrays are heterogeneous — see solve_unify comment.
--: (Ctx, { [integer]: unknown, ... }) -> boolean
local function solve_return(ctx, c)
    local val_tid   = find(ctx, constrain.return_val(c))
    local line, col = constrain.return_line(c), constrain.return_col(c)
    local widened   = widen_for_sub(ctx, val_tid)

    -- return_expected is the ret_var created by gen_function for this function body.
    -- If it's still a free VAR, bind directly (first return path).
    -- If it's already bound (subsequent return path), widen to union.
    -- This mirrors v2 infer_function's return-type accumulation.
    local ret_var_id = constrain.return_expected(c)
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
            local inner_tid = find(ctx, types_mod.spread_inner(et))
            -- Variadic return `() -> ...(T)` accepts zero or more T-typed values.
            -- Actual cases:
            --   `return` (empty)         → widened = nil → accepted (zero values)
            --   `return a`               → widened = scalar → check scalar <: T
            --   `return a, b, c`         → widened = TAG_TUPLE → each slot <: T
            local wt = ctx.types:get(widened)
            if wt.tag == TAG_NIL then
                return true
            end
            if wt.tag == TAG_TUPLE then
                local ws = types_mod.agg_members_start(wt)
                local wl = types_mod.agg_members_len(wt)
                for i = 0, wl - 1 do
                    local slot_tid = find(ctx, ctx.lists:get(ws + i))
                    local ok, err = unify_mod.unify(ctx, slot_tid, inner_tid)
                    if not ok then
                        add_error(ctx, line, col,
                            "return type mismatch: cannot return `"
                            .. types_mod.display_short(ctx, val_tid)
                            .. "` against variadic `..."
                            .. types_mod.display_short(ctx, inner_tid)
                            .. "` (slot " .. (i + 1) .. "): "
                            .. (err or "type mismatch"))
                        return true
                    end
                end
                return true
            end
            -- Scalar actual: check against inner.
            local ok, err = unify_mod.unify(ctx, widened, inner_tid)
            if not ok then
                add_error(ctx, line, col,
                    "return type mismatch: cannot return `"
                    .. types_mod.display_short(ctx, val_tid)
                    .. "` against variadic `..."
                    .. types_mod.display_short(ctx, inner_tid)
                    .. "`: " .. (err or "type mismatch"))
            end
            return true
        end
        -- When the annotated return is a TAG_TUPLE (multi-return packed as tuple)
        -- and the actual value is also a TAG_TUPLE, unify them directly — this
        -- handles `return p` where p: Parameters<typeof f> = (integer, string).
        -- When the actual value is NOT a tuple (normal `return a, b` path where
        -- only the first expression is emitted via C_RETURN), use slot 0 of the
        -- expected tuple for the per-slot check.
        if et.tag == TAG_TUPLE and ctx.types:get(widened).tag ~= TAG_TUPLE then
            -- Scalar actual vs multi-slot expected: `return a` against `(A, B, ...)`.
            -- Per Lua semantics, missing return values are `nil` at the call site
            -- (`local x, y = f()` yields y = nil). So treat the actual as
            -- (actual, nil, nil, ...) padded to expected's arity and check each slot.
            -- This is sound: it rejects iff a missing slot's `nil` is not a subtype
            -- of the corresponding expected slot (e.g. `return 1` against
            -- `(integer, string)` fails because nil </: string), but accepts when
            -- the trailing slots are nilable (e.g. `(integer, string?)`).
            local e_len = types_mod.agg_members_len(et)
            local e_start = types_mod.agg_members_start(et)
            if e_len > 0 then
                expected_tid = find(ctx, ctx.lists:get(e_start))
            end
            -- Fast path (mirrors argument position): when the expected slot is
            -- concrete, check the UNWIDENED actual for direct assignability first.
            -- Widening loses literal precision — `return "a"` against a `"a" | "b"`
            -- return slot widens to `string`, which is not assignable to the literal
            -- union and would spuriously fail. A literal is assignable to a literal
            -- union without widening.
            -- Fast path: when the expected slot is concrete, prefer the UNWIDENED
            -- actual so literal precision is kept (`return "a"` against a `"a" | "b"`
            -- slot widens to `string` otherwise, which is not assignable). Fall back
            -- to the widened actual when the unwidened one is not directly assignable.
            local et_slot = ctx.types:get(find(ctx, expected_tid))
            local actual_tid = widened
            if et_slot.tag ~= TAG_VAR and et_slot.tag ~= TAG_ROWVAR
                and not contains_free_var(ctx, expected_tid)
                and unify_mod.try_unify(ctx, val_tid, expected_tid) then
                actual_tid = val_tid
            end
            local ok, err = unify_mod.unify(ctx, actual_tid, expected_tid)
            if not ok then
                add_error(ctx, line, col,
                    "return type mismatch: cannot return `"
                    .. types_mod.display_short(ctx, val_tid)
                    .. "`: " .. (err or "type mismatch"))
                return true
            end
            -- Check the remaining slots against `nil`.
            for i = 1, e_len - 1 do
                local slot_tid = find(ctx, ctx.lists:get(e_start + i))
                local ok2, err2 = unify_mod.unify(ctx, ctx.T_NIL, slot_tid)
                if not ok2 then
                    add_error(ctx, line, col,
                        "return type mismatch: function declared to return "
                        .. e_len .. " values but only 1 returned (slot "
                        .. (i + 1) .. " `"
                        .. types_mod.display_short(ctx, slot_tid)
                        .. "` does not accept nil): " .. (err2 or "type mismatch"))
                    return true
                end
            end
            return true
        end
        -- Mixed multi-return with trailing variadic: `(A, B, ...(C))`.
        -- Expected TAG_TUPLE whose last slot is TAG_SPREAD(C). Concrete prefix
        -- slots check pairwise; remaining actual slots must each be <: C; the
        -- actual tuple may also be shorter than the concrete prefix (trailing
        -- nils per Lua semantics) when the missing slots accept nil.
        if et.tag == TAG_TUPLE and ctx.types:get(widened).tag == TAG_TUPLE then
            local e_start = types_mod.agg_members_start(et)
            local e_len = types_mod.agg_members_len(et)
            local last_slot_tid = e_len > 0
                and find(ctx, ctx.lists:get(e_start + e_len - 1))
                or 0
            local last_slot_t = e_len > 0 and ctx.types:get(last_slot_tid) or nil
            if last_slot_t and last_slot_t.tag == TAG_SPREAD then
                local prefix_len = e_len - 1
                local spread_inner = find(ctx, types_mod.spread_inner(last_slot_t))
                local wt = ctx.types:get(widened)
                local w_start = types_mod.agg_members_start(wt)
                local w_len = types_mod.agg_members_len(wt)
                -- Pairwise check the concrete prefix.
                for i = 0, prefix_len - 1 do
                    local exp_i = find(ctx, ctx.lists:get(e_start + i))
                    local act_i = i < w_len
                        and find(ctx, ctx.lists:get(w_start + i))
                        or ctx.T_NIL
                    local ok, err = unify_mod.unify(ctx, act_i, exp_i)
                    if not ok then
                        add_error(ctx, line, col,
                            "return type mismatch: cannot return `"
                            .. types_mod.display_short(ctx, val_tid)
                            .. "` (slot " .. (i + 1) .. "): "
                            .. (err or "type mismatch"))
                        return true
                    end
                end
                -- Remaining actual slots match against the spread inner.
                for i = prefix_len, w_len - 1 do
                    local act_i = find(ctx, ctx.lists:get(w_start + i))
                    local ok, err = unify_mod.unify(ctx, act_i, spread_inner)
                    if not ok then
                        add_error(ctx, line, col,
                            "return type mismatch: cannot return `"
                            .. types_mod.display_short(ctx, val_tid)
                            .. "` against variadic `..."
                            .. types_mod.display_short(ctx, spread_inner)
                            .. "` (slot " .. (i + 1) .. "): "
                            .. (err or "type mismatch"))
                        return true
                    end
                end
                return true
            end
        end
        -- Fast path (mirrors argument position, line ~2256): when the expected
        -- return type is concrete (no free vars, not a bare TAG_VAR), check the
        -- UNWIDENED actual for direct assignability first. Widening loses literal
        -- precision — e.g. `return "a"` against `"a" | "b"` widens to `string`,
        -- which is not assignable to the literal union and would spuriously fail.
        -- A literal is assignable to a literal union (or a literal field/param)
        -- without widening; widening is only correct when the expected side is a
        -- free var to be inferred (handled by the non-annotated branch below).
        local et2 = ctx.types:get(find(ctx, expected_tid))
        if et2.tag ~= TAG_VAR and et2.tag ~= TAG_ROWVAR
          and not contains_free_var(ctx, expected_tid)
          and unify_mod.try_unify(ctx, val_tid, expected_tid) then
            return true
        end
        local ok, err = unify_mod.unify(ctx, widened, expected_tid)
        if not ok then
            add_error(ctx, line, col,
                "return type mismatch: cannot return `"
                .. types_mod.display_short(ctx, val_tid)
                .. "`: " .. (err or "type mismatch"))
        end
        -- Terminal: success solves; failure emitted the error.
        return true
    end

    -- Operate on ret_var_id.data[2] directly — never on find(ret_var_id).
    -- Following the chain can reach a different unbound var (e.g. prescan_ret_var
    -- after C_UNIFY extended the chain). Binding that var to `widened` where
    -- widened == find(ret_var_id) creates a self-loop and hangs find().
    if types_mod.var_parent(ret_var_t) == -1 then
        -- First return path: bind ret_var_id directly.
        -- Write stays direct (no typed setter exists; accessors are read-only per types.lua).
        ret_var_t.data[2] = widened
    else
        -- Subsequent return path (multiple `return` stmts, or fixpoint re-pass).
        -- Use ret_var_t's parent slot to find the current concrete binding without
        -- following the full chain past what this constraint owns.
        local prev_root = find(ctx, types_mod.var_parent(ret_var_t))
        if prev_root ~= widened then
            -- Widen: new union of what we had and the new return value.
            local new_union = types_mod.make_union(ctx, { prev_root, widened })
            ret_var_t.data[2] = new_union
        end
        -- If prev_root == widened: idempotent, no change needed.
    end
    return true
end

-- C_INSTANTIATE_AT_CALL stub (Phase 1).
--
-- High-level deferred per-call instantiation. Today this is a no-op: the
-- gen-time machinery in constrain.lua's NODE_CALL_EXPR handler still does
-- instantiation, rank-N skolemization, HKT decomposition, eager-bind, and
-- emits C_BIND_GENERICS / C_CHECK_ARGS directly.
--
-- The constraint is emitted as a code-motion landing zone. Subsequent phases
-- move the gen-time work into this handler piece by piece, eventually
-- deleting the gen-time machinery entirely. See
-- docs/typechecker-h2-correct-design-v2.md (option X) for the full design.
--: (Ctx, { [integer]: unknown, ... }) -> boolean
local function solve_instantiate_at_call(ctx, c)
    -- P4 will turn this into the unified `instantiate_at_use` entry that
    -- emits C_BIND_GENERICS / C_CHECK_ARGS children at solve-time. Until
    -- then it is a no-op — the eager gen-time emission in constrain.lua
    -- already covers the actual work. We still claim ret_tid: when the
    -- P4 port lands, the claim is what keeps cross-statement C_SUB from
    -- racing the deferred children to bind the ret_TV (the exact failure
    -- mode docs/typechecker-phase-f-blocker.md describes).
    claim(ctx, constrain.instcall_ret(c), c)
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
--: (Ctx, { [integer]: unknown, ... }) -> boolean
local function solve_bind_generics(ctx, c)
    local callee_raw = constrain.bindgen_callee(c)
    local callee_tid = find(ctx, callee_raw)
    local arg_tids   = constrain.bindgen_args(c)
    local callee_t   = ctx.types:get(callee_tid)

    -- Unwrap nominal to inner type.
    if callee_t.tag == TAG_NOMINAL then
        callee_tid = find(ctx, types_mod.nom_underlying(callee_t))
        callee_t   = ctx.types:get(callee_tid)
    end

    -- Only act on TAG_FUNCTION. All other callee forms are handled by C_CHECK_ARGS.
    if callee_t.tag ~= TAG_FUNCTION then return true end

    -- Instantiate if callee was a free var at gen time (method calls).
    --
    -- Per-constraint instantiation cache (livelock fix). This handler may be
    -- re-seeded every solve_range round (the constraint stays on ctx.constraints
    -- and re-enters the worklist). The VAR/ROWVAR `raw_t` tag persists across
    -- rounds even after the callee var resolves to a concrete function (union-find
    -- records the bind in the parent pointer, not the node tag), so without a cache
    -- this path re-instantiates a FRESH copy of the callee every round: +N arena
    -- slots and a fresh set of generic-param TVs each time. The bind loop below
    -- then unifies those fresh TVs, advancing ctx._bind_generation every round,
    -- which defeats the solve_range quiescence test (`not solved and gen unchanged`)
    -- and livelocks until the arena exhausts (observed >430k rounds on lib/bloom).
    --
    -- The instantiation only depends on the resolved callee type, so caching it on
    -- the constraint and reusing it across re-seeds is sound: the second round's
    -- bind loop operates on the SAME (already-bound) TVs, so unify is a no-op, gen
    -- stays put, and quiescence can fire. Keyed by the resolved source tid so that
    -- if the callee ever resolves to a different function mid-solve the stale copy
    -- is discarded and re-instantiated. The instantiated tid is local to this
    -- handler (solve_check_args instantiates its own independent copy), so the
    -- cache cannot affect any other constraint.
    local raw_t = ctx.types:get(callee_raw)
    if raw_t.tag == TAG_VAR or raw_t.tag == TAG_ROWVAR then
        if c._bg_inst_src == callee_tid and c._bg_inst_tid then
            callee_tid = c._bg_inst_tid --[[: integer]]
        else
            c._bg_inst_src = callee_tid
            callee_tid = env_mod.instantiate(ctx, callee_tid, 0)
            c._bg_inst_tid = callee_tid
        end
        callee_t = ctx.types:get(callee_tid)
    end

    local pl = types_mod.fn_params_len(callee_t)
    local ps = types_mod.fn_params_start(callee_t)

    -- Givens-before-wanteds (item 2): the per-param bind loop below issues
    -- WANTED-tier unify calls (this handler is wanted: it reads call-site
    -- argument types and writes them into generic param TVs). When such a
    -- bind wakes a GIVEN waiter — typically C_BOUND on the F-fresh TV in
    -- `<F: (A,B)->R, A, B, R>(f: F, a: A, b: B) -> R` waiting to
    -- back-propagate the kind signature into A/B/R — we defer the rest of
    -- the loop. The GIVEN re-fires in the same drain, rewrites the
    -- still-free A/B/R with their declared types, and re-wakes this
    -- C_BIND_GENERICS; the second run binds A/B/R to the (now-declared)
    -- types and any later-arg mismatch surfaces as the call-site error
    -- rather than being absorbed into A/B by the wanted bind.
    --
    -- Replaces the prior ad-hoc C_BOUND peek scan: discipline is uniform
    -- across every WANTED bind, dispatched at unify.bind_var_to_type.
    for i = 0, pl - 1 do
        local exp_tid = find(ctx, ctx.lists:get(ps + i))
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
                if ctx._bind_woke_given then
                    return false
                end
            end
        end
    end

    return true
end

-- any: constraint arrays are heterogeneous — see solve_unify comment.
-- Checks that call arguments match the (now-concrete) param types and unifies the return type.
-- Defers (returns false) if any param is still a free TV — C_BIND_GENERICS and C_BOUND
-- have already had a chance to run, so deferral is always safe here.
--: (Ctx, { [integer]: unknown, ... }) -> boolean
local function solve_check_args(ctx, c)
    local callee_raw = constrain.checkargs_callee(c)
    local callee_tid = find(ctx, callee_raw)
    local arg_tids   = constrain.checkargs_args(c)
    local ret_tid    = constrain.checkargs_ret(c)
    local line, col  = constrain.checkargs_line(c), constrain.checkargs_col(c)
    local callee_t   = ctx.types:get(callee_tid)
    -- Claim ret_tid: same discipline as solve_callable. The constraint
    -- commits to binding it via bind_to / unify on every terminal-success
    -- path; readers (cross-statement C_SUB) must defer until that fires.
    claim(ctx, ret_tid, c)

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
        callee_tid = find(ctx, types_mod.nom_underlying(callee_t))
        callee_t   = ctx.types:get(callee_tid)
    end

    if callee_t.tag == TAG_VAR or callee_t.tag == TAG_ROWVAR then
        -- HM Phase 1c step 2 (extension): same as solve_callable's free-callee
        -- bound emission. Ordinary `f(x)` calls in user code go through
        -- C_CHECK_ARGS, not C_CALLABLE — so the bound emission must live here
        -- too, or HM's higher-order inference is silently broken (callee
        -- silently binds to T_ANY, no contravariance check fires).
        if callee_t.tag == TAG_VAR and band(callee_t.flags, FLAG_SUB_SOLVE_PARAM) ~= 0 then
            local var_t = ctx.types:get(callee_tid)
            local var_level = types_mod.var_level(var_t)
            local r_var = types_mod.make_var(ctx, var_level)
            local sig_tid = types_mod.make_func(ctx, arg_tids, { r_var }, -1, nil)
            merge_inferred_bound(ctx, callee_tid, sig_tid)
            unify_mod.unify(ctx, ret_tid, r_var)
            return true
        end
        -- Defer: callee is a free TV. Phase 2 _forall_ops re-emits C_CHECK_ARGS
        -- on TVs that will be bound by C_BOUND propagation from the actual call's
        -- argument unification; we must wait for that to settle before checking.
        return false
    end

    if callee_t.tag == TAG_FUNCTION then
        -- Instantiate if callee was a free var at gen time (method calls).
        local raw_t = ctx.types:get(callee_raw)
        if raw_t.tag == TAG_VAR or raw_t.tag == TAG_ROWVAR then
            callee_tid = env_mod.instantiate(ctx, callee_tid, 0)
            callee_t   = ctx.types:get(callee_tid)
        end
        local pl = types_mod.fn_params_len(callee_t)
        local ps = types_mod.fn_params_start(callee_t)
        local has_names = types_mod.fn_param_names_len(callee_t) > 0
        -- Simple deferral: if any param is still a free TV, wait.
        -- C_BIND_GENERICS and C_BOUND have already had a chance to run; if a param
        -- is still free, more solver progress is needed before we can check args.
        for i = 0, pl - 1 do
            local et = ctx.types:get(find(ctx, ctx.lists:get(ps + i)))
            if et.tag == TAG_VAR or et.tag == TAG_ROWVAR then
                return false  -- defer
            end
        end
        for i = 0, pl - 1 do
            local raw_param_tid = ctx.lists:get(ps + i)
            local exp_tid = find(ctx, raw_param_tid)
            local act_tid = arg_tids[i + 1]
            if act_tid then
                -- Fast path: try direct assignability (preserves literal-to-literal/union).
                local act_r = find(ctx, act_tid)
                local et = ctx.types:get(exp_tid)
                local param_is_closed_table = et.tag == TAG_TABLE and types_mod.tbl_row_var(et) < 0
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
                        local atms, atml = types_mod.agg_members_start(act_t), types_mod.agg_members_len(act_t)
                        for mi = atms, atms + atml - 1 do
                            local mid = find(ctx, ctx.lists:get(mi))
                            if not unify_mod.try_unify(ctx, mid, exp_tid) then
                                failing[#failing + 1] = mid
                            end
                        end
                        local total = atml
                        if #failing > 0 and #failing < total then
                            local fail_tid = #failing == 1 and failing[1]
                                or types_mod.make_union(ctx, failing)
                            local param_name = nil
                            if has_names then
                                local name_id = ctx.lists:get(types_mod.fn_param_names_start(callee_t) + i)
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
        -- Handle extra args against the function's vararg slot.
        local va_id = types_mod.fn_vararg(callee_t)
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
                    if slot_idx < types_mod.agg_members_len(vat) then
                        exp_slot = find(ctx, ctx.lists:get(types_mod.agg_members_start(vat) + slot_idx))
                    else
                        exp_slot = ctx.T_NIL
                    end
                    local act_tid = arg_tids[ei + 1]
                    local ok, err = unify_mod.unify(ctx, widen_literal(ctx, act_tid), exp_slot)
                    if not ok then
                        local err_s = err
                        add_error(ctx, line, col,
                            "argument " .. (ei + 1) .. ": cannot pass `"
                            .. types_mod.display_short(ctx, act_tid)
                            .. "` where `"
                            .. types_mod.display_short(ctx, exp_slot) .. "` expected"
                            .. (err_s ~= nil and (": " .. err_s) or ""))
                    end
                end
            end
        end
        -- Unify return
        local rl = types_mod.fn_returns_len(callee_t)
        local rs = types_mod.fn_returns_start(callee_t)
        if rl == 0 then
            unify_mod.unify(ctx, ret_tid, ctx.T_NIL)
        elseif rl == 1 then
            local first_ret = find(ctx, ctx.lists:get(rs))
            first_ret = resolve_deferred_intrinsic(ctx, first_ret)
            unify_mod.unify(ctx, ret_tid, first_ret)
        else
            local slots = {}
            for ri = 0, rl - 1 do
                slots[ri + 1] = find(ctx, ctx.lists:get(rs + ri))
            end
            unify_mod.unify(ctx, ret_tid, types_mod.make_tuple(ctx, slots))
        end
        return true
    end

    -- Intersection: overload dispatch — first matching overload wins.
    if callee_t.tag == TAG_INTERSECTION then
        local members = {}
        local cms, cml = types_mod.agg_members_start(callee_t), types_mod.agg_members_len(callee_t)
        for i = cms, cms + cml - 1 do
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
            return true  -- terminal: result bound to any after error.
        end
        for _, m in ipairs(members) do
            local ft = m.t
            local ok = true
            local fps = types_mod.fn_params_start(ft)
            local fpl = types_mod.fn_params_len(ft)
            for j = 0, fpl - 1 do
                local exp_tid = find(ctx, ctx.lists:get(fps + j))
                local act_tid = arg_tids[j + 1]
                if act_tid and not unify_mod.try_unify(ctx, find(ctx, act_tid), exp_tid) then
                    ok = false; break
                end
            end
            if ok then
                -- Bind params of the winning overload so that generic TVs in the
                -- return type get resolved (e.g. CTypeMap[S_fresh]).
                for j = 0, fpl - 1 do
                    local pexp = ctx.lists:get(fps + j)
                    local exp_p = find(ctx, pexp)
                    local pact = arg_tids[j + 1]
                    if pact then
                        local ept = ctx.types:get(exp_p)
                        if ept.tag == TAG_VAR or ept.tag == TAG_ROWVAR
                          or contains_free_var(ctx, exp_p) then
                            unify_mod.unify(ctx, find(ctx, pact), exp_p)
                        end
                    end
                end
                local rl = types_mod.fn_returns_len(ft)
                if rl == 0 then
                    bind_to(ctx, ret_tid, ctx.T_NIL)
                else
                    local first_ret = find(ctx, ctx.lists:get(types_mod.fn_returns_start(ft)))
                    first_ret = resolve_deferred_intrinsic(ctx, first_ret)
                    bind_to(ctx, ret_tid, first_ret)
                end
                return true
            end
        end
        local cands = {}
        for ci, m in ipairs(members) do
            local ft = m.t
            --: { [integer]: string, ... }
            local reasons = {}
            local fps = types_mod.fn_params_start(ft)
            local fpl = types_mod.fn_params_len(ft)
            for j = 0, fpl - 1 do
                local exp_tid = find(ctx, ctx.lists:get(fps + j))
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
        return true  -- terminal: result bound to any after error.
    end

    -- Union: ALL members must accept the argument.
    if callee_t.tag == TAG_UNION then
        local ret_types = {}
        --: { [integer]: string, ... }
        local fail_msgs = {}
        local ums, uml = types_mod.agg_members_start(callee_t), types_mod.agg_members_len(callee_t)
        for i = ums, ums + uml - 1 do
            local mid = find(ctx, ctx.lists:get(i))
            local mt  = ctx.types:get(mid)
            if mt.tag ~= TAG_FUNCTION then
                fail_msgs[#fail_msgs + 1] = "union member `"
                    .. types_mod.display_short(ctx, mid) .. "` is not callable"
            else
                local member_ok = true
                local mps = types_mod.fn_params_start(mt)
                local mpl = types_mod.fn_params_len(mt)
                for j = 0, mpl - 1 do
                    local exp_tid = find(ctx, ctx.lists:get(mps + j))
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
                    local rl = types_mod.fn_returns_len(mt)
                    ret_types[#ret_types + 1] = rl > 0
                        and find(ctx, ctx.lists:get(types_mod.fn_returns_start(mt)))
                        or  ctx.T_NIL
                end
            end
        end
        if #fail_msgs > 0 then
            add_error(ctx, line, col, fail_msgs[1])
            bind_to(ctx, ret_tid, ctx.T_ANY)
            return true  -- terminal: result bound to any after error.
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
    return true  -- terminal: result bound to any after error.
end

-- Overlap-checked force cast: `--[[:! T]] expr`.
-- Succeeds iff `actual` and `expected` have any value in common (structural overlap).
-- Disjoint types (e.g. string and integer, or function and table) are rejected.
-- Common patterns that succeed:
--   - unknown --[[:! T]]          (unknown overlaps everything)
--   - T | nil --[[:! T]]          (nil-stripping: T overlaps with T|nil member)
--   - A | B --[[:! A]]            (union projection: A overlaps with A)
--   - {x,y} --[[:! {x}]          (struct width subtyping: shared fields compatible)
--   - partial_literal --[[:! Full] (partial literal to full type: absent fields ok)
-- Defers while either side is still a free TAG_VAR.
--: (Ctx, { [integer]: unknown, ... }) -> boolean
local function solve_overlap(ctx, c)
    local actual   = find(ctx, constrain.overlap_actual(c))
    local expected = find(ctx, constrain.overlap_expected(c))
    local line, col = constrain.overlap_line(c), constrain.overlap_col(c)
    -- Look up byte range of the `--[[:! T]]` comment for autofix (set by
    -- constrain.lua at the NODE_CAST_EXPR emit site). Keyed by (line, col)
    -- so the lookup survives constraint deferral/retry.
    local byte_start, byte_end
    if line and col and ctx._overlap_byte_range then
        local range = ctx._overlap_byte_range[(line or 0) * 100000 + (col or 0)]
        if range then byte_start, byte_end = range[1], range[2] end
    end
    -- Defer if either side is still a free type variable: the answer would be
    -- determined by whatever the var binds to next, not by the user's program.
    -- Do NOT emit the warning yet — the actual type may resolve to exactly the
    -- cast target (making the cast genuinely redundant), and we should only
    -- warn once the actual type is concrete.
    do
        local at = ctx.types:get(actual)
        local bt = ctx.types:get(expected)
        if at.tag == TAG_VAR or at.tag == TAG_ROWVAR then return false end
        if bt.tag == TAG_VAR or bt.tag == TAG_ROWVAR then return false end
    end
    -- Emit a diagnostic exactly once per source site.  Use a (line, col) key
    -- so re-tries after type-variable resolution do not produce duplicates.
    do
        local key = (line or 0) * 100000 + (col or 0)
        if not ctx._overlap_warned then ctx._overlap_warned = {} end
        if not ctx._overlap_warned[key] then
            ctx._overlap_warned[key] = true
            -- If the actual type is already assignable to the expected type, the
            -- force cast is redundant — emit REDUNDANT_CAST (error) so it gets stripped.
            -- Otherwise, emit FORCE_CAST (warning) for a genuine narrowing cast.
            -- Use is_subtype, not try_unify: try_unify is overlap (allows extra
            -- fields on actual when expected is closed), which would falsely
            -- classify field-stripping casts as redundant.
            if unify_mod.is_subtype(ctx, actual, expected) then
                local entry = add_warning_code(ctx, line, col, defs.E.REDUNDANT_CAST)
                if entry and byte_start and byte_end then
                    -- Compute fix: delete the `--[[:! T]]` span. Optionally include
                    -- a single preceding whitespace char that would otherwise become
                    -- trailing whitespace on its line.
                    local source = ctx.source
                    local edit_start = byte_start
                    if source and source ~= "" and byte_start > 0 then
                        local prev = source:sub(byte_start, byte_start)  -- 1-indexed
                        if prev == " " or prev == "\t" then
                            -- After deletion, the char at (byte_end..) follows the prev char.
                            -- If the char before (byte_start - 1) is also non-newline content
                            -- (so the prev space is between code and the cast), and the next
                            -- char after the cast is a newline or end-of-line, the prev space
                            -- becomes trailing whitespace. Drop it.
                            local before = byte_start >= 2 and source:sub(byte_start - 1, byte_start - 1) or ""
                            local after = byte_end < #source and source:sub(byte_end + 1, byte_end + 1) or ""
                            if before ~= "" and before ~= "\n" and (after == "" or after == "\n" or after == "\r") then
                                edit_start = byte_start - 1
                            end
                        end
                    end
                    entry.fix = {
                        kind = "safe",
                        rule = "redundant_cast",
                        edits = { {
                            byte_start  = edit_start,
                            byte_end    = byte_end,
                            replacement = "",
                        } },
                    }
                end
                return true
            end
            add_warning_code(ctx, line, col, defs.E.FORCE_CAST)
        else
            -- Already diagnosed this site; still need to check assignability for return value.
            if unify_mod.try_unify(ctx, actual, expected) then return true end
        end
    end
    if unify_mod.types_overlap(ctx, actual, expected) then return true end
    add_error(ctx, line, col,
        "force cast has no overlap: `"
        .. types_mod.display_short(ctx, actual)
        .. "` and `" .. types_mod.display_short(ctx, expected)
        .. "` are disjoint; use `--[[: any]]` to escape the type system entirely if intentional")
    return true  -- error reported; don't defer further
end

-- ---------------------------------------------------------------------------
-- Solver
-- ---------------------------------------------------------------------------

-- _constraints is a scratch field set/cleared during solve; augment Ctx to allow nil assignment.
--:: augment Ctx { _constraints?: { [integer]: { [integer]: unknown } } }
-- _overlap_warned tracks force-cast sites that have already emitted the FORCE_CAST warning,
-- so the warning fires exactly once per site even when the constraint is deferred and retried.
--:: augment Ctx { _overlap_warned?: { [integer]: boolean } }
-- _overlap_byte_range maps (line, col) → {byte_start, byte_end} of the cast comment,
-- set by constrain.lua at NODE_CAST_EXPR emit so solve_overlap can attach an autofix.
--:: augment Ctx { _overlap_byte_range?: { [integer]: { [integer]: integer } } }
-- Return the 0-indexed byte offset of the start of `line_num` (1-indexed) in `source`.
-- Returns nil if line_num is out of range.
--: (string, integer) -> integer | nil
local function line_start_byte(source, line_num)
    if line_num <= 0 then return nil end
    if line_num == 1 then return 0 end
    local i = 1
    local n = 1
    local len = #source
    while i <= len do
        local nl = source:find("\n", i, true) --[[: integer | nil]]
        if not nl then return nil end
        n = n + 1
        -- nl is 1-indexed pos of "\n"; the byte offset (0-indexed) of the
        -- start of the NEXT line is `nl` (since the char after "\n" is at
        -- 1-indexed pos nl+1, which is 0-indexed offset nl).
        if n == line_num then return nl end
        i = nl + 1
    end
    return nil
end

-- Return the substring of `source` corresponding to line `line_num`
-- (1-indexed; excluding trailing newline). Returns "" if out of range.
--: (string, integer) -> string
local function get_line(source, line_num)
    local start_b = line_start_byte(source, line_num)
    if not start_b then return "" end
    -- start_b is 0-indexed byte offset; Lua sub is 1-indexed.
    local s = start_b + 1
    local e = source:find("\n", s, true)
    if not e then return source:sub(s) end
    return source:sub(s, e - 1)
end


-- HM-aware annotation renderer (Phase 1 follow-up). Walks a function tid
-- collecting FLAG_GENERIC vars, assigns names (T, U, V, W, X, Y, Z, T1+),
-- and renders the function as `<T[: bound], U[: bound], ...>(params) -> ret`
-- with var occurrences substituted. Bounds come from ctx.tv_bounds.
--
-- The standard display() renders FLAG_GENERIC vars as `_` — indistinguishable
-- from each other and unparseable as annotation source. This renderer needs
-- to produce parseable `--:` annotation text for the autofix to write back.
--
-- Returns the signature string (without the `--: ` prefix) on success, or
-- nil if any tid can't be cleanly rendered (free non-generic vars, leaky
-- shapes, etc.).
--: (Ctx, integer) -> string | nil
local function render_hm_signature(ctx, fn_tid)
    fn_tid = find(ctx, fn_tid)
    local fn_t = ctx.types:get(fn_tid)
    if fn_t.tag ~= TAG_FUNCTION then return nil end

    -- var_names: tid -> name; var_order: ordered list of generic tids
    local var_names = {} --: { [integer]: string, ... }
    local var_order = {} --: { [integer]: integer, ... }
    local NAMES = { "T", "U", "V", "W", "X", "Y", "Z" }

    -- Assign a name to a generic var if not already named. Returns name or nil.
    local function name_for(tid)
        tid = find(ctx, tid)
        if var_names[tid] then return var_names[tid] end
        local t = ctx.types:get(tid)
        if t.tag ~= TAG_VAR then return nil end
        if band(t.flags, FLAG_GENERIC) == 0 then return nil end
        local idx = #var_order + 1
        local name = NAMES[idx] or ("T" .. idx)
        var_names[tid] = name
        var_order[#var_order + 1] = tid
        return name
    end

    -- Render a tid with var-name substitution. seen guards cycles. Returns
    -- nil if the tid can't be rendered (non-generic free var, etc.).
    local render
    render = function(tid, seen)
        tid = find(ctx, tid)
        if seen[tid] then return var_names[tid] end  -- cycle: use name if available
        seen[tid] = true
        local t = ctx.types:get(tid)
        local tag = t.tag
        if tag == TAG_VAR then
            local n = name_for(tid)
            if n then return n end
            -- Non-generic free var (e.g. body usage produced a var that didn't
            -- get generalized because it's at the outer scope level). Render
            -- as `unknown` — sound (unknown is the top type, must be narrowed
            -- before use) and parseable. Loses precision but doesn't break
            -- the autofix output.
            return "unknown"
        end
        if tag == TAG_ROWVAR then
            -- Free row var inside a structural type — render as `...` (open
            -- record marker) for parseability.
            return "..."
        end
        if tag == TAG_NIL      then return "nil" end
        if tag == TAG_BOOLEAN  then return "boolean" end
        if tag == TAG_NUMBER   then return "number" end
        if tag == TAG_STRING   then return "string" end
        if tag == TAG_INTEGER  then return "integer" end
        if tag == TAG_ANY      then return "any" end
        if tag == TAG_NEVER    then return "never" end
        if tag == TAG_UNKNOWN  then return "unknown" end
        if tag == TAG_FUNCTION then
            local pparts = {} --: { [integer]: string, ... }
            local ps, pl = types_mod.fn_params_start(t), types_mod.fn_params_len(t)
            for i = ps, ps + pl - 1 do
                local p = render(ctx.lists:get(i), seen)
                if not p then return nil end
                pparts[#pparts + 1] = p
            end
            local rparts = {} --: { [integer]: string, ... }
            local rs, rl = types_mod.fn_returns_start(t), types_mod.fn_returns_len(t)
            for i = rs, rs + rl - 1 do
                local r = render(ctx.lists:get(i), seen)
                if not r then return nil end
                rparts[#rparts + 1] = r
            end
            local rs = #rparts == 0 and "()"
                or #rparts == 1 and rparts[1]
                or "(" .. table.concat(rparts, ", ") .. ")"
            return "(" .. table.concat(pparts, ", ") .. ") -> " .. rs
        end
        if tag == TAG_TABLE then
            local parts = {} --: { [integer]: string, ... }
            -- Named fields
            local fs, fl = types_mod.tbl_fields_start(t), types_mod.tbl_fields_len(t)
            for i = fs, fs + fl - 1 do
                local fid = ctx.lists:get(i)
                local fe = ctx.fields:get(fid)
                local fname = intern_mod.get(ctx.pool, fe.name_id)
                if not fname then return nil end
                local ft = render(fe.type_id, seen)
                if not ft then return nil end
                parts[#parts + 1] = fname .. ": " .. ft
            end
            -- Indexers (key, value pairs)
            local is, il = types_mod.tbl_indexers_start(t), types_mod.tbl_indexers_len(t)
            local ix = is
            while ix < is + il - 1 do
                local kt = render(ctx.lists:get(ix), seen)
                local vt = render(ctx.lists:get(ix + 1), seen)
                if not kt or not vt then return nil end
                parts[#parts + 1] = "[" .. kt .. "]: " .. vt
                ix = ix + 2
            end
            -- Meta slots
            local ms, ml = types_mod.tbl_meta_start(t), types_mod.tbl_meta_len(t)
            for i = ms, ms + ml - 1 do
                local fid = ctx.lists:get(i)
                local fe = ctx.fields:get(fid)
                local mname = intern_mod.get(ctx.pool, fe.name_id)
                if not mname then return nil end
                local ft = render(fe.type_id, seen)
                if not ft then return nil end
                parts[#parts + 1] = "#" .. mname .. ": " .. ft
            end
            -- Open/closed
            if types_mod.tbl_row_var(t) >= 0 then
                parts[#parts + 1] = "..."
            end
            return "{ " .. table.concat(parts, ", ") .. " }"
        end
        if tag == TAG_LITERAL then
            local kind = types_mod.lit_kind(t)
            if kind == LIT_STRING then
                local s = intern_mod.get(ctx.pool, types_mod.lit_str_id(t)) or "?"
                return '"' .. s .. '"'
            end
            if kind == LIT_INTEGER then return tostring(types_mod.lit_str_id(t)) end
            if kind == LIT_BOOLEAN then return types_mod.lit_bool(t) == 1 and "true" or "false" end
            if kind == LIT_NIL     then return "nil" end
            return nil  -- LIT_NUMBER (float) — unsupported in this renderer
        end
        if tag == TAG_UNION then
            local parts = {} --: { [integer]: string, ... }
            local uums, uuml = types_mod.agg_members_start(t), types_mod.agg_members_len(t)
            for i = uums, uums + uuml - 1 do
                local p = render(ctx.lists:get(i), seen)
                if not p then return nil end
                parts[#parts + 1] = p
            end
            return table.concat(parts, " | ")
        end
        if tag == TAG_INTERSECTION then
            local parts = {} --: { [integer]: string, ... }
            local iims, iiml = types_mod.agg_members_start(t), types_mod.agg_members_len(t)
            for i = iims, iims + iiml - 1 do
                local p = render(ctx.lists:get(i), seen)
                if not p then return nil end
                parts[#parts + 1] = p
            end
            return table.concat(parts, " & ")
        end
        if tag == TAG_NAMED then
            -- Use the alias name. If args, render them too.
            local name = intern_mod.get(ctx.pool, types_mod.named_name_id(t)) or "?"
            local arg_l = types_mod.named_args_len(t)
            if arg_l == 0 then return name end
            local args = {} --: { [integer]: string, ... }
            local nas = types_mod.named_args_start(t)
            for i = nas, nas + arg_l - 1 do
                local a = render(ctx.lists:get(i), seen)
                if not a then return nil end
                args[#args + 1] = a
            end
            return name .. "<" .. table.concat(args, ", ") .. ">"
        end
        -- Unsupported tag (TAG_LITERAL float, TAG_TUPLE, TAG_NOMINAL, etc.):
        -- render as `unknown` — sound fallback. Specific tags can be added
        -- as their use cases surface.
        return "unknown"
    end

    -- Walk the function type to discover generic vars in encounter order.
    -- (The actual rendering of param/return parts happens in a second pass.)
    local function collect(tid, seen)
        tid = find(ctx, tid)
        if seen[tid] then return end
        seen[tid] = true
        local t = ctx.types:get(tid)
        if t.tag == TAG_VAR then name_for(tid); return end
        if t.tag == TAG_FUNCTION then
            local cps, cpl = types_mod.fn_params_start(t), types_mod.fn_params_len(t)
            for i = cps, cps + cpl - 1 do collect(ctx.lists:get(i), seen) end
            local crs, crl = types_mod.fn_returns_start(t), types_mod.fn_returns_len(t)
            for i = crs, crs + crl - 1 do collect(ctx.lists:get(i), seen) end
            return
        end
        if t.tag == TAG_TABLE then
            local cfs, cfl = types_mod.tbl_fields_start(t), types_mod.tbl_fields_len(t)
            for i = cfs, cfs + cfl - 1 do
                local fid = ctx.lists:get(i)
                local fe = ctx.fields:get(fid)
                collect(fe.type_id, seen)
            end
            local is, il = types_mod.tbl_indexers_start(t), types_mod.tbl_indexers_len(t)
            for i = is, is + il - 1 do collect(ctx.lists:get(i), seen) end
            local cms, cml = types_mod.tbl_meta_start(t), types_mod.tbl_meta_len(t)
            for i = cms, cms + cml - 1 do
                local fid = ctx.lists:get(i)
                local fe = ctx.fields:get(fid)
                collect(fe.type_id, seen)
            end
            return
        end
        if t.tag == TAG_UNION or t.tag == TAG_INTERSECTION then
            local ams, aml = types_mod.agg_members_start(t), types_mod.agg_members_len(t)
            for i = ams, ams + aml - 1 do collect(ctx.lists:get(i), seen) end
            return
        end
    end
    collect(fn_tid, {})

    -- Render params.
    local pparts = {} --: { [integer]: string, ... }
    local fnps, fnpl = types_mod.fn_params_start(fn_t), types_mod.fn_params_len(fn_t)
    for i = fnps, fnps + fnpl - 1 do
        local p = render(ctx.lists:get(i), {})
        if not p then return nil end
        pparts[#pparts + 1] = p
    end
    -- Render returns.
    local rl = types_mod.fn_returns_len(fn_t)
    local fnrs = types_mod.fn_returns_start(fn_t)
    local ret_s
    if rl == 0 then
        ret_s = "nil"
    elseif rl == 1 then
        local rid = find(ctx, ctx.lists:get(fnrs))
        local rt  = ctx.types:get(rid)
        if rt.tag == TAG_VAR and band(rt.flags, FLAG_GENERIC) == 0 then
            -- Free non-generic return — typically an unbound ret_var (no
            -- return statement). Emit `nil` to match the runtime behavior
            -- of a function that doesn't return.
            ret_s = "nil"
        else
            ret_s = render(rid, {})
        end
    else
        local rparts = {} --: { [integer]: string, ... }
        for i = fnrs, fnrs + rl - 1 do
            local r = render(ctx.lists:get(i), {})
            if not r then return nil end
            rparts[#rparts + 1] = r
        end
        ret_s = "(" .. table.concat(rparts, ", ") .. ")"
    end
    if not ret_s then return nil end

    -- Build generic-prefix `<T1[: bound1], T2[: bound2], ...>` if any vars.
    local generic_prefix = ""
    if #var_order > 0 then
        local gparts = {} --: { [integer]: string, ... }
        for _, vtid in ipairs(var_order) do
            local name = var_names[vtid]
            local bound = ctx.tv_bounds and ctx.tv_bounds[vtid]
            if bound then
                local bs = render(bound, {})
                if bs then
                    gparts[#gparts + 1] = name .. ": " .. bs
                else
                    gparts[#gparts + 1] = name  -- bound un-renderable; skip it
                end
            else
                gparts[#gparts + 1] = name
            end
        end
        generic_prefix = "<" .. table.concat(gparts, ", ") .. ">"
    end
    return generic_prefix .. "(" .. table.concat(pparts, ", ") .. ") -> " .. ret_s
end


-- Emit MISSING_FUNCTION_SIGNATURE errors for function definitions that lack
-- a `--:` annotation. Statement-form definitions always fire; expression-
-- form definitions fire only when the source line is at statement position
-- (`local f = function(...)`, `M.f = function(...)`, etc.). Inline
-- anonymous functions like `s:gsub(p, function(c) end)` are typed by their
-- call context and do not need a separate signature.
--
-- Where the existing per-param inference data is available (recorded by
-- gen_function), an autofix is attached: the rendered signature is
-- inserted on the line above the function definition.
--: (Ctx, ErrCtx, string) -> ()
local function emit_missing_function_signature(ctx, real_err, sev)
    if not ctx._missing_signatures then return end

    local seen = {}
    for _, sig in ipairs(ctx._missing_signatures) do
        local dkey = sig.line * 100000 + sig.col
        local skip = seen[dkey]
        if not skip then
            seen[dkey] = true
            local target_line = ctx.source and get_line(ctx.source, sig.line) or ""
            local trimmed = target_line:match("^[ \t]*(.*)$") or target_line
            local is_statement_form =
                trimmed:find("^function%s+[%w_][%w_.:]*%s*%(")
                or trimmed:find("^function%s*%(")
                or trimmed:find("^local%s+function%s+[%w_]+%s*%(")
                or trimmed:find("^local%s+[%w_]+%s*=%s*function%s*%(")
                or trimmed:find("^[%w_][%w_.]*%s*=%s*function%s*%(")
            -- Expression-form (inline anon) functions get their type from
            -- their enclosing call context — no signature required.
            if sig.source_kind ~= "expr" or is_statement_form then
                local name --: string | nil
                if sig.name_id and sig.name_id ~= -1 then
                    name = intern_mod.get(ctx.pool, sig.name_id)
                end
                if not name then
                    name = trimmed:match("^function%s+([%w_][%w_.:]*)")
                        or trimmed:match("^local%s+function%s+([%w_]+)")
                        or trimmed:match("^local%s+([%w_]+)%s*=")
                        or trimmed:match("^([%w_][%w_.]*)%s*=")
                end
                local msg = errors_mod.format_diag(
                    defs.E.MISSING_FUNCTION_SIGNATURE,
                    { name = name or "" })
                local entry
                if sev == "error" then
                    entry = errors_mod.error(real_err, ctx.filename,
                        sig.line, sig.col, msg)
                else
                    entry = errors_mod.warning(real_err, ctx.filename,
                        sig.line, sig.col, msg)
                end
                -- Try to attach autofix when the def is at a statement-form
                -- line and we have rendered-signature data.
                if entry and ctx.source and is_statement_form then
                    -- Belt-and-suspenders: skip if preceding non-blank line
                    -- already starts with `--:` (annotation parse may have
                    -- missed it, or it parsed to a non-function type).
                    local already_annotated = false
                    local probe = sig.line - 1
                    while probe >= 1 do
                        local ls = get_line(ctx.source, probe)
                        if ls:find("%S") then
                            if ls:find("%-%-:") or ls:find("%-%-::") then
                                already_annotated = true
                            end
                            break
                        end
                        probe = probe - 1
                    end
                    if not already_annotated then
                        -- Prefer the HM-aware renderer (handles FLAG_GENERIC
                        -- vars + bounds via tv_bounds). Falls back to the
                        -- callsite-aggregating renderer for cases without HM
                        -- generalization (e.g. annotated functions that
                        -- somehow trigger the warning).
                        local sig_str = sig.fn_tid and render_hm_signature(ctx, sig.fn_tid)
                        if sig_str then
                            local insert_at = line_start_byte(ctx.source, sig.line)
                            if insert_at then
                                local indent = target_line:match("^[ \t]*") or ""
                                local replacement = indent .. "--: " .. sig_str .. "\n"
                                entry.fix = {
                                    kind = "safe",
                                    rule = "missing_function_signature",
                                    edits = { {
                                        byte_start  = insert_at,
                                        byte_end    = insert_at,
                                        replacement = replacement,
                                    } },
                                }
                            end
                        end
                    end
                end
            end
        end
    end
end


-- Strongly-typed inner solver. Payload is carried directly on the constraint
-- record (item 3a of the first-principles solver rework).
--: (Ctx, integer, { [integer]: integer, ... }, integer, integer, integer | nil, integer | nil) -> boolean
local function solve_hkt_decompose_impl(ctx, f_fresh, args_fresh, bound_alias_id, actual_id, line, col)
    -- Defer while the actual argument is still a free TV — we can't pattern
    -- match against an unresolved structural witness.
    local actual = find(ctx, actual_id)
    local at = ctx.types:get(actual)
    if at.tag == TAG_VAR or at.tag == TAG_ROWVAR then
        return false
    end

    -- Resolve the bound alias to its TAG_NAMED form and look up the alias entry.
    local bound_tid = find(ctx, bound_alias_id)
    local bt = ctx.types:get(bound_tid)
    if bt.tag ~= TAG_NAMED then
        -- Bound is not a generic-alias reference any more (shouldn't happen
        -- given the emission guard, but be defensive). Defer-consume.
        return true
    end
    local alias = env_mod.lookup_type(ctx.scope, types_mod.named_name_id(bt))
    if not alias or not alias.params or #alias.params == 0 or alias.body == nil then
        return true
    end

    -- H6: match-typed alias bodies cannot be inverted. Emit the documented
    -- explicit error rather than miscompiling.
    local body_t = ctx.types:get(find(ctx, alias.body))
    if body_t.tag == TAG_MATCH_TYPE then
        local alias_name = intern_mod.get(ctx.pool, types_mod.named_name_id(bt)) or "?"
        add_error(ctx, line, col,
            "higher-kinded type `" .. alias_name
            .. "` has a non-invertible alias body (match type); "
            .. "cannot decompose `" .. types_mod.display_short(ctx, actual)
            .. "` against `" .. alias_name .. "<...>`. "
            .. "Approach 2 HKT requires plain structural alias bodies "
            .. "(union, table, tuple).")
        return true  -- terminal: non-invertible alias body.
    end

    -- Build mapping: alias.params[i] (name_id) -> args_fresh[i] (tid). This
    -- substitutes the alias body to produce a "template" that has the
    -- call-site fresh TVs in the positions where the alias's params were.
    -- Unifying the actual against this template back-solves the fresh TVs.
    if #args_fresh ~= #alias.params then
        -- Arity mismatch (caller's F<A> has a different arity than the
        -- bound alias). Surface as an error so it doesn't silently pass.
        add_error(ctx, line, col,
            "higher-kinded application has arity " .. #args_fresh
            .. " but bound alias `"
            .. (intern_mod.get(ctx.pool, types_mod.named_name_id(bt)) or "?")
            .. "` has arity " .. #alias.params)
        return true  -- terminal: arity mismatch is definite.
    end
    local mapping = {}
    for i = 1, #alias.params do
        mapping[alias.params[i]] = args_fresh[i]
    end
    local template = env_mod.substitute(ctx, alias.body, mapping)

    -- Unify actual against the template. This binds args_fresh from the
    -- structural witness (e.g. `{tag:"some",value:integer}|{tag:"none"}`
    -- vs `{tag:"some",value:A_fresh}|{tag:"none"}` solves A_fresh := integer).
    unify_mod.unify(ctx, actual, template)

    -- Bind F_fresh := bound_alias so return-side slots (e.g. F<B>) can
    -- substitute back to the named alias for re-resolution. M.unify
    -- short-circuits TAG_NAMED to true without binding, so use the direct
    -- bind helper.
    local ff_root = find(ctx, f_fresh)
    local ff_t = ctx.types:get(ff_root)
    if ff_t.tag == TAG_VAR or ff_t.tag == TAG_ROWVAR then
        unify_mod.bind_var_to_type(ctx, ff_root, bound_tid)
    end

    return true
end

-- Solve C_HKT_DECOMPOSE = { C_HKT_DECOMPOSE, f_fresh, args_fresh_list,
--                            bound_alias, actual_arg, line, col }
-- Payload travels on the constraint record (item 3a of the first-principles
-- rework). No ctx side-channel.
-- any: constraint arrays are heterogeneous — see solve_unify comment.
--: (Ctx, { [integer]: unknown, ... }) -> boolean
local function solve_hkt_decompose(ctx, c)
    return solve_hkt_decompose_impl(ctx,
        constrain.hkt_f_fresh(c), constrain.hkt_args_fresh(c),
        constrain.hkt_bound_alias(c), constrain.hkt_actual_arg(c),
        constrain.hkt_line(c), constrain.hkt_col(c))
end


-- Dispatch table by constraint kind. Module-level so both M.solve and the
-- per-function sub-solve (Phase 2 of HM-for-unannotated-params) share it.
-- Handler return shape: boolean for simple solved/parked, or a structured
-- table { solved, await?, emit? }. Typed verbatim so solve2.lua's dispatcher
-- can narrow `type(result) == "table"` to the structured shape without a
-- force cast (the structured-table fields are the contract from solve.await
-- and the few handlers that emit children).
--: { [integer]: ((Ctx, { [integer]: unknown, ... }) -> boolean | { solved: boolean, await: integer | nil, emit: { [integer]: { [integer]: unknown, ... }, ... } | nil } | nil) | nil }
local _handlers
local function get_handlers()
    if _handlers then return _handlers end
    _handlers = {
        [C_UNIFY]         = solve_unify,
        [C_SUB]           = solve_sub,
        [C_INDEX]         = solve_index,
        [C_CALLABLE]      = solve_callable,
        [C_ARITH]         = solve_arith,
        [C_RETURN]        = solve_return,
        [C_COMPARE]       = solve_compare,
        [C_BOUND]         = solve_bound,
        [C_OR]            = solve_or,
        [C_AND]           = solve_and,
        [C_BIND_GENERICS] = solve_bind_generics,
        [C_CHECK_ARGS]    = solve_check_args,
        [C_OVERLAP]       = solve_overlap,
        [C_NARROW_NIL]    = solve_narrow_nil,
        [C_ESCAPE_CHECK]  = solve_escape_check,
        [C_HKT_DECOMPOSE] = solve_hkt_decompose,
        [C_INSTANTIATE_AT_CALL] = solve_instantiate_at_call,
    }
    return _handlers
end

-- Exposed for solve2.lua (P1 of docs/typechecker-solver-rewrite.md) so the
-- new Outside-In/X core can route ported kinds through the existing handler
-- dispatch table. Will be inlined when the old solver is deleted in P6.
M.get_handlers = get_handlers

-- Worklist-to-quiescence solver (item 1 of the first-principles rework, see
-- docs/typechecker-architecture-from-first-principles.md §4). Replaces the
-- prior 4-pass fixpoint over the slice [lo, hi].
--
-- Mechanism. A worklist of ready constraint refs is drained in rounds:
--   * Round = drain the worklist to empty. Each dequeue runs the handler.
--     Successful solve marks _solved. Emitted children are appended to
--     ctx.constraints AND pushed onto the worklist. A handler that parks
--     (returns false, or { solved = false }) marks the constraint _deferred;
--     parking is normally paired with solve.await(ctx, c, tv) which puts c
--     on ctx.tv_waiters[tv]. When unify.bind_var_to_type binds that root,
--     wake_waiters clears _deferred AND pushes the waiter onto ctx._worklist,
--     so wakes that arrive mid-drain are picked up in the same round.
--   * Quiescence = the round retired no constraints AND no TV was bound
--     during it. Otherwise re-seed the worklist from the in-range
--     not-_solved constraints (newly emitted entries past the original hi
--     included) and run another round. This is the structural replacement
--     for the 4-pass cap: termination is observed, not budgeted.
--
-- Sub-solve composition. gen_function calls solve_range on a body slice with
-- the function's param TVs still free. Constraints awaiting one of those TVs
-- park in tv_waiters and stay _deferred when sub-solve exits — they remain
-- in ctx.constraints, and the outer solve_range will re-seed them. If the
-- outer solver later binds the TV, wake_waiters re-enqueues them on the
-- (then-active) outer worklist. No explicit transfer is needed.
--
-- Errors are terminal (item 1.5a). Every handler that emits a diagnostic
-- returns true on the same turn — the constraint is retired, never retried,
-- so each error reaches ctx.err at most once. No dedup buffer is needed.
--: (Ctx, { [integer]: { [integer]: unknown, ... }, ... }, integer, integer) -> ()
local function solve_range(ctx, constraints, lo, hi)
    local handlers = get_handlers()
    if hi < lo then return end

    -- Save and install the active worklist. Nested solve_range (sub-solve
    -- inside the outer solve) restores the parent worklist on exit, so
    -- wake_waiters writes to the innermost active drain.
    local saved_worklist = ctx._worklist
    --: { [integer]: { [integer]: unknown, ... }, ... }
    local worklist = {}
    ctx._worklist = worklist

    --: () -> ()
    local function seed()
        local n = #constraints
        if hi > n then hi = n end
        for i = lo, n do
            local c = constraints[i]
            if not c._solved then
                c._deferred = false
                worklist[#worklist + 1] = c
            end
        end
        -- The slice may have grown via emit; bump hi so the next seed round
        -- considers freshly-emitted constraints too.
        hi = n
    end

    --: ({ [integer]: unknown, ... }) -> ()
    local function run_one(c)
        local kind = c[1]
        -- Per-kind dispatch (P2 of docs/typechecker-solver-rewrite.md):
        -- kinds listed in solve2.PORTED run through the Outside-In/X
        -- simplify loop instead of the legacy handler directly. The
        -- handler implementations are reused — what changes is the
        -- scheduling context. Currently: C_UNIFY, C_SUB. Uniform
        -- predicate, no per-kind carve-outs (CLAUDE.md ad-hoc ban).
        local handler = handlers[kind]
        if not handler then c._solved = true; return end
        -- Givens-before-wanteds (item 2): publish the current constraint's
        -- tier so unify.bind_var_to_type → wake_waiters can see whether the
        -- in-flight bind was issued by a WANTED, and reset _bind_woke_given
        -- so the handler can detect a wake-up that happened during its run.
        -- Saved/restored so nested handler invocations (e.g. unify recursing
        -- through normalize_type_call) inherit the outer tier without
        -- leaking it on exit.
        local saved_tier = ctx._current_tier
        local saved_wake = ctx._bind_woke_given
        ctx._current_tier = c._tier or 1  -- TIER_WANTED default
        ctx._bind_woke_given = false
        local result
        if solve2.PORTED[kind] then
            result = solve2.dispatch_one(ctx, c)
        else
            result = handler(ctx, c)
        end
        ctx._current_tier = saved_tier
        ctx._bind_woke_given = saved_wake
        if type(result) == "boolean" then
            if result == false then
                c._deferred = true
            else
                c._solved = true
            end
            return
        end
        -- Structured form: { solved: boolean, emit?, await? }. The await
        -- field is informational; registration is performed inside
        -- solve.await at call time. emit appends children to the constraint
        -- list AND pushes them onto the active worklist. Emitted children
        -- inherit the parent's tier if untagged (per P1.5 + bind-ordering
        -- doc §4 #5 — default-inherit is safer than re-declaring per site).
        if result.solved == false then
            c._deferred = true
        else
            c._solved = true
        end
        if result.emit then
            local parent_tier = c._tier or 1
            for _, nc in ipairs(result.emit) do
                if nc._tier == nil then nc._tier = parent_tier end
                constraints[#constraints + 1] = nc
                nc._deferred = false
                worklist[#worklist + 1] = nc
            end
        end
        local _ = result.await
    end

    seed()
    while true do
        local gen_before = ctx._bind_generation or 0
        local solved_this_round = false
        -- FIFO drain by head index: handlers were authored against in-order
        -- [lo..hi] traversal, and dependency chains (e.g. C_BIND_GENERICS
        -- feeding C_CHECK_ARGS) need that emission order preserved. A LIFO
        -- stack inverts these chains and silently mis-orders them.
        local head = 1
        while head <= #worklist do
            local c = worklist[head]
            head = head + 1
            -- Skip already-retired constraints and ones parked in this
            -- round. _deferred is cleared by (a) wake_waiters on a TV bind
            -- the constraint was awaiting, which also re-enqueues it for
            -- this same drain, and (b) the round-boundary re-seed below
            -- when any progress (solve or bind) was observed.
            if not c._solved and not c._deferred then
                run_one(c)
                if c._solved then
                    solved_this_round = true
                end
            end
        end
        -- Truncate the consumed entries so the next round starts from a
        -- length-0 worklist (and wake_waiters pushes into a clean queue).
        -- rawset to bypass the index-signature type which forbids nil.
        for i = 1, #worklist do rawset(worklist, i, nil) end
        local gen_after = ctx._bind_generation or 0
        if not solved_this_round and gen_after == gen_before then
            -- Quiescent: no constraint retired and no TV bound during the
            -- round. Either every remaining constraint is solved, or the
            -- remaining ones are deadlocked awaiting TVs that nothing in
            -- this range will bind. In the sub-solve case the latter is
            -- expected — the outer solver picks them up via re-seed when it
            -- runs over [1, #constraints].
            break
        end
        -- Progress happened; re-seed. Constraints emitted via wake/emit are
        -- already on the worklist (or were drained), but a TV bound during
        -- the round may also have unblocked constraints that deferred without
        -- registering an await. Re-seed catches them uniformly without
        -- per-kind carve-outs.
        seed()
    end

    if saved_worklist then
        ctx._worklist = saved_worklist
    else
        rawset(ctx, "_worklist", nil)
    end
end

-- any: constraints is a list of heterogeneous arrays — see solve_unify comment.
--: (Ctx, { [integer]: { [integer]: unknown, ... }, ... }) -> ()
-- Public for HM Phase 1b: per-function sub-solve called from constrain.lua's
-- gen_function. Resolves the body's constraints against still-free param
-- vars before the function type is generalized and exposed to call sites.
M.solve_range = solve_range

function M.solve(ctx, constraints)
    solve_range(ctx, constraints, 1, #constraints)

    -- Post-pass: MISSING_FUNCTION_SIGNATURE (error). Every function-def site
    -- without a `--:` annotation gets reported at the function-def line.
    -- Statement-form definitions always fire; expression-form (inline anon)
    -- functions only fire when the source line is itself at statement
    -- position (`local f = function(...)`, `M.f = function(...)`, etc.) —
    -- truly inline functions are typed by their call context.
    --
    -- An autofix is attached when the per-param inference data (recorded by
    -- gen_function and call sites) is sufficient to render a full signature.
    -- See render_signature for the modal-or-union rules.
    local rd2 = defs.rule_defaults --[[:! { [integer]: { name: string, severity: string }, ... }]]
    local rd_entry = rd2[defs.E.MISSING_FUNCTION_SIGNATURE]
    if ctx._missing_signatures and rd_entry then
        local rc_mod = require("lib.type.static.rules_config")
        local rc = ctx.rules_config --[[:! { [string]: { severity?: string, enabled?: boolean, allow?: { [integer]: string, ... }, ... }, ... } | nil]]
        local sev = rc_mod.effective_severity(defs.E.MISSING_FUNCTION_SIGNATURE, rc, rd2)
        local allow = rc_mod.allow_patterns(defs.E.MISSING_FUNCTION_SIGNATURE, rc, rd2)
        local suppressed = sev == "off" or rc_mod.is_allowed(ctx.filename, allow)
        if not suppressed then
            -- Normalize unions before rendering: phi-join artifacts can leave
            -- `string | string | nil` shapes where two TAG_VARs both resolved
            -- to T_STRING via different paths. The post-solve normalization
            -- in check.lua runs AFTER us, so invoke it here too.
            types_mod.normalize_unions(ctx)
            -- ctx.err is the real error sink; solve_range writes directly.
            emit_missing_function_signature(ctx, ctx.err, sev)
        end
    end
end

return M
