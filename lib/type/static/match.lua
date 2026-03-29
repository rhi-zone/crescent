-- lib/type/static/match.lua
-- Match type evaluation for the typechecker.
-- Evaluates: match T { pattern => result, ... }

local defs = require("lib.type.static.defs")
local types_mod = require("lib.type.static.types")

local TAG_ANY          = defs.TAG_ANY
local TAG_NIL          = defs.TAG_NIL
local TAG_BOOLEAN      = defs.TAG_BOOLEAN
local TAG_NUMBER       = defs.TAG_NUMBER
local TAG_STRING       = defs.TAG_STRING
local TAG_INTEGER      = defs.TAG_INTEGER
local TAG_LITERAL      = defs.TAG_LITERAL
local TAG_NAMED        = defs.TAG_NAMED
local TAG_MATCH_TYPE   = defs.TAG_MATCH_TYPE
local TAG_TABLE        = defs.TAG_TABLE
local TAG_FUNCTION     = defs.TAG_FUNCTION
local TAG_UNION        = defs.TAG_UNION
local TAG_INTERSECTION = defs.TAG_INTERSECTION
local TAG_TUPLE        = defs.TAG_TUPLE

local LIT_STRING  = defs.LIT_STRING
local LIT_NUMBER  = defs.LIT_NUMBER
local LIT_BOOLEAN = defs.LIT_BOOLEAN

local M = {}

-- Merge two bindings tables, returning merged or nil on conflict.
local function merge_bindings(a, b)
    if not b then return a end
    local out = {}
    for k, v in pairs(a) do out[k] = v end
    for k, v in pairs(b) do
        if out[k] ~= nil and out[k] ~= v then return nil end
        out[k] = v
    end
    return out
end

-- Check if `ty_id` matches `pat_id`.
-- Returns (ok, bindings_table_or_nil).
-- bindings: { [name_id] -> type_id } for named patterns (type variables).
--: (Ctx, integer, integer) -> (boolean, { [integer]: integer, ... }?)
function M.match_pattern(ctx, ty_id, pat_id)
    --: integer
    local ty_id  = types_mod.find(ctx, ty_id)
    --: integer
    local pat_id = types_mod.find(ctx, pat_id)

    local tt = ctx.types:get(ty_id)
    local pt = ctx.types:get(pat_id)

    -- any pattern matches everything
    if pt.tag == TAG_ANY then return true, {} end

    -- Named pattern (type variable in match context): binds
    -- A bare name with no args is a capture variable that matches anything.
    if pt.tag == TAG_NAMED and pt.data[2] == 0 then  -- no args
        return true, { [pt.data[0]] = ty_id }
    end

    -- Exact primitive match
    if tt.tag == pt.tag then
        if tt.tag == TAG_NIL or tt.tag == TAG_BOOLEAN or tt.tag == TAG_NUMBER
          or tt.tag == TAG_INTEGER or tt.tag == TAG_STRING then
            return true, {}
        end
        if tt.tag == TAG_LITERAL then
            if tt.data[0] == pt.data[0] and tt.data[1] == pt.data[1] then
                return true, {}
            end
            return false, nil
        end
    end

    -- Subtype matching
    if tt.tag == TAG_INTEGER and pt.tag == TAG_NUMBER then
        return true, {}
    end
    if tt.tag == TAG_LITERAL then
        local kind = tt.data[0]
        if kind == LIT_STRING  and pt.tag == TAG_STRING  then return true, {} end
        if kind == LIT_NUMBER  and pt.tag == TAG_NUMBER  then return true, {} end
        if kind == LIT_BOOLEAN and pt.tag == TAG_BOOLEAN then return true, {} end
    end

    -- Table pattern: structural match with field-level and indexer capture variables.
    -- { key: K, value: V } matched against an actual table collects bindings
    -- for each field whose pattern type is a bare TAG_NAMED (capture var).
    -- { [K]: V } matched against a table with an indexer binds K → key type, V → value type.
    -- Every named field in the pattern must be present in the input type.
    -- Every indexer pair in the pattern must be matched positionally against the subject's indexers.
    if pt.tag == TAG_TABLE and tt.tag == TAG_TABLE then
        --: any
        local bindings = {}
        -- Each named field in the pattern must exist in the actual type.
        for pi = pt.data[0], pt.data[0] + pt.data[1] - 1 do
            --: integer
            local pfid = ctx.lists:get(pi)
            --: any
            local pfe  = ctx.fields:get(pfid)
            -- Find the matching field in the input type
            local afe = types_mod.table_field(ctx, ty_id, pfe.name_id)
            if not afe then return false, nil end
            local ok, sub_bindings = M.match_pattern(ctx, afe.type_id, pfe.type_id)
            if not ok then return false, nil end
            --: any
            bindings = merge_bindings(bindings, sub_bindings)
            if bindings == nil then return false, nil end
        end
        -- If the pattern has indexer pairs, match them positionally against the subject.
        -- { [K]: V } binds K → subject key type, V → subject value type.
        local pil = pt.data[3]
        if pil >= 2 then
            -- Subject must have at least as many indexer pairs as the pattern requires.
            if tt.data[3] < pil then return false, nil end
            local pis = pt.data[2]
            local tis = tt.data[2]
            for i = 0, pil / 2 - 1 do
                --: integer
                local pk_id = ctx.lists:get(pis + i * 2)
                --: integer
                local pv_id = ctx.lists:get(pis + i * 2 + 1)
                --: integer
                local tk_id = ctx.lists:get(tis + i * 2)
                --: integer
                local tv_id = ctx.lists:get(tis + i * 2 + 1)
                local ok, sub = M.match_pattern(ctx, tk_id, pk_id)
                if not ok then return false, nil end
                --: any
                bindings = merge_bindings(bindings, sub)
                if bindings == nil then return false, nil end
                ok, sub = M.match_pattern(ctx, tv_id, pv_id)
                if not ok then return false, nil end
                --: any
                bindings = merge_bindings(bindings, sub)
                if bindings == nil then return false, nil end
            end
        end
        return true, bindings
    end

    -- Function pattern: match param and return types, collecting capture bindings.
    -- e.g. (...P) -> R or (A, B) -> C
    if pt.tag == TAG_FUNCTION then
        -- The input must also be a function
        if tt.tag ~= TAG_FUNCTION then return false, nil end
        --: any
        local bindings = {}
        -- Match params
        local ppl = pt.data[1]  -- param count in pattern
        local tpl = tt.data[1]  -- param count in input
        -- If pattern has params, match them positionally
        if ppl > 0 then
            if tpl ~= ppl then return false, nil end
            for i = 0, ppl - 1 do
                --: integer
                local p_param = ctx.lists:get(pt.data[0] + i)
                --: integer
                local t_param = ctx.lists:get(tt.data[0] + i)
                local ok, sub = M.match_pattern(ctx, t_param, p_param)
                if not ok then return false, nil end
                --: any
                bindings = merge_bindings(bindings, sub)
                if bindings == nil then return false, nil end
            end
        end
        -- Match vararg
        local p_va = pt.data[4]
        if p_va >= 0 then
            local t_va = tt.data[4]
            if t_va < 0 then return false, nil end
            local ok, sub = M.match_pattern(ctx, t_va, p_va)
            if not ok then return false, nil end
            --: any
            bindings = merge_bindings(bindings, sub)
            if bindings == nil then return false, nil end
        end
        -- Match returns
        local prl = pt.data[3]
        local trl = tt.data[3]
        if prl > 0 then
            -- Special case: single capture variable in return position.
            -- `() -> R` where R is a bare TAG_NAMED (capture var) binds R to:
            --   trl=0: never (void function has no return to bind)
            --   trl=1: the single return type
            --   trl>1: a tuple of all return types
            -- This enables `ReturnType<F> = match F { () -> R => R }` for any F.
            if prl == 1 then
                --: integer
                local p_ret0 = ctx.lists:get(pt.data[2])
                --: integer
                local p_ret0_canon = types_mod.find(ctx, p_ret0)
                local p_ret0_t = ctx.types:get(p_ret0_canon)
                if p_ret0_t.tag == TAG_NAMED and p_ret0_t.data[2] == 0 then
                    if trl == 0 then return false, nil end
                    -- Bind R to first return type (trl=1) or tuple of all returns (trl>1).
                    -- trl>1 tuple-binding enables `PcallReturn<F> = match F { () -> R => (true, R) | ... }`
                    -- where R is a tuple that can be spread with future `(true, ...R)` syntax.
                    local bound_tid
                    if trl == 1 then
                        --: integer
                        bound_tid = ctx.lists:get(tt.data[2])
                    else
                        local rets = {}
                        for ri = 0, trl - 1 do
                            --: integer
                            rets[ri + 1] = ctx.lists:get(tt.data[2] + ri)
                        end
                        bound_tid = types_mod.make_tuple(ctx, rets)
                    end
                    local ok, sub = M.match_pattern(ctx, bound_tid, p_ret0_canon)
                    if not ok then return false, nil end
                    --: any
                    bindings = merge_bindings(bindings, sub)
                    if bindings == nil then return false, nil end
                    return true, bindings
                end
            end
            -- Normal case: strict return count match.
            if trl ~= prl then return false, nil end
            for i = 0, prl - 1 do
                --: integer
                local p_ret = ctx.lists:get(pt.data[2] + i)
                --: integer
                local t_ret = ctx.lists:get(tt.data[2] + i)
                local ok, sub = M.match_pattern(ctx, t_ret, p_ret)
                if not ok then return false, nil end
                --: any
                bindings = merge_bindings(bindings, sub)
                if bindings == nil then return false, nil end
            end
        end
        return true, bindings
    end

    return false, nil
end

-- Evaluate a match type.
-- mt_id: type_id of a TAG_MATCH_TYPE slot
-- seen:  { [mt_id] -> true } cycle-detection set (shared across recursive calls)
-- Returns the result type_id of the first matching arm, or T_NEVER.
--: (Ctx, integer, { [integer]: boolean, ... }?) -> integer
function M.evaluate(ctx, mt_id, seen)
    seen = seen or {}

    -- Cycle detection: if we are already evaluating this exact match-type node,
    -- return never to break the cycle rather than looping or crashing.
    if seen[mt_id] then return ctx.T_NEVER end
    seen[mt_id] = true

    --: any
    local mt = ctx.types:get(mt_id)
    if mt.tag ~= TAG_MATCH_TYPE then
        seen[mt_id] = nil
        return ctx.T_NEVER
    end

    local param_id = types_mod.find(ctx, mt.data[0])
    local arms_start = mt.data[1]
    local arms_len   = mt.data[2]

    -- Distribution over union inputs: match T { ... } where T is a union
    -- evaluates each union member independently and re-unions the results.
    -- This is required by the design: "Distribution still applies. When a match
    -- receives a union, it distributes: each union member is matched independently,
    -- results are re-unioned."
    --: any
    local param_t = ctx.types:get(param_id)
    if param_t.tag == TAG_UNION then
        --: { [integer]: integer, ... }
        local results = {}
        for ui = param_t.data[0], param_t.data[0] + param_t.data[1] - 1 do
            --: integer
            local member_id = types_mod.find(ctx, ctx.lists:get(ui))
            -- Build a temporary match-type node with this member as the param.
            -- Reuse the existing arms slice from the list pool (no new allocation).
            local sub_mt = types_mod.alloc_type(ctx, TAG_MATCH_TYPE)
            --: any
            local sub_mtt = ctx.types:get(sub_mt)
            sub_mtt.data[0] = member_id
            sub_mtt.data[1] = arms_start
            sub_mtt.data[2] = arms_len
            results[#results + 1] = M.evaluate(ctx, sub_mt, seen)
        end
        seen[mt_id] = nil
        if #results == 0 then return ctx.T_NEVER end
        if #results == 1 then return results[1] end
        return types_mod.make_union(ctx, results)
    end

    local i = arms_start
    while i < arms_start + arms_len - 1 do
        --: integer
        local pat_id = ctx.lists:get(i)
        --: integer
        local res_id = ctx.lists:get(i + 1)
        local ok, bindings = M.match_pattern(ctx, param_id, pat_id)
        if ok then
            seen[mt_id] = nil
            if bindings and next(bindings) then
                -- Substitute bindings into result, passing seen so that any
                -- TAG_MATCH_TYPE nodes encountered during substitution share
                -- this cycle-detection set.
                local env_mod = require("lib.type.static.env")
                return env_mod.substitute(ctx, res_id, bindings, seen)
            end
            return res_id
        end
        i = i + 2
    end

    seen[mt_id] = nil
    return ctx.T_NEVER
end

return M
