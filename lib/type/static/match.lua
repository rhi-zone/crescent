-- lib/type/static/match.lua
-- Match type evaluation for the typechecker.
-- Evaluates: match T { pattern => result, ... }

local defs = require("lib.type.static.defs")
local types_mod = require("lib.type.static.types")

local TAG_ANY            = defs.TAG_ANY
local TAG_NIL            = defs.TAG_NIL
local TAG_BOOLEAN        = defs.TAG_BOOLEAN
local TAG_NUMBER         = defs.TAG_NUMBER
local TAG_STRING         = defs.TAG_STRING
local TAG_INTEGER        = defs.TAG_INTEGER
local TAG_LITERAL        = defs.TAG_LITERAL
local TAG_NAMED          = defs.TAG_NAMED
local TAG_MATCH_TYPE     = defs.TAG_MATCH_TYPE
local TAG_TABLE          = defs.TAG_TABLE
local TAG_FUNCTION       = defs.TAG_FUNCTION
local TAG_UNION          = defs.TAG_UNION
local TAG_INTERSECTION   = defs.TAG_INTERSECTION
local TAG_TUPLE          = defs.TAG_TUPLE
local TAG_UNKNOWN        = defs.TAG_UNKNOWN
local TAG_NEVER          = defs.TAG_NEVER
local TAG_CAPTURE          = defs.TAG_CAPTURE
local TAG_PAT_ALL_FIELDS   = defs.TAG_PAT_ALL_FIELDS
local TAG_PAT_REST_FIELDS  = defs.TAG_PAT_REST_FIELDS
local TAG_PAT_META_SPREAD  = defs.TAG_PAT_META_SPREAD
local TAG_SPREAD           = defs.TAG_SPREAD

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

    -- Explicit capture: %Name → always matches, binds name_id → input type
    if pt.tag == TAG_CAPTURE then
        return true, { [pt.data[0]] = ty_id }
    end

    -- Named pattern (bare name, no type args) in pattern position → concrete type lookup.
    -- Exception: `_` is a wildcard that always succeeds without binding.
    -- For all other bare names: look up in scope; fail the arm if not found.
    -- (Previously this was an implicit capture; now TAG_CAPTURE handles that.)
    if pt.tag == TAG_NAMED and pt.data[2] == 0 then  -- no args
        -- `_` wildcard: always succeeds, no binding
        local intern_mod = require("lib.type.static.intern")
        local name = intern_mod.get(ctx.pool, pt.data[0]) or ""
        if name == "_" then
            return true, {}
        end
        local env_mod = require("lib.type.static.env")
        local scope = ctx.scope
        if scope then
            local resolved = env_mod.resolve_named_type(ctx, scope, pt.data[0], {})
            if resolved then
                -- Resolved: check subtype compatibility (ty_id <: resolved)
                local unify_mod = require("lib.type.static.unify")
                if unify_mod.try_unify(ctx, ty_id, resolved, {}) then
                    return true, {}
                end
                return false, nil
            end
        end
        -- Name not in scope: arm fails (no implicit capture fallback)
        return false, nil
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
        if kind == LIT_STRING   and pt.tag == TAG_STRING  then return true, {} end
        if kind == LIT_NUMBER   and pt.tag == TAG_NUMBER  then return true, {} end
        if kind == LIT_BOOLEAN  and pt.tag == TAG_BOOLEAN then return true, {} end
        -- LIT_INTEGER: subtype of both integer and number
        if kind == defs.LIT_INTEGER and pt.tag == TAG_INTEGER then return true, {} end
        if kind == defs.LIT_INTEGER and pt.tag == TAG_NUMBER  then return true, {} end
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
        -- Track which field name_ids are explicitly matched by the pattern.
        --: { [integer]: boolean, ... }
        local matched_name_ids = {}
        -- Rest-field capture node (TAG_PAT_REST_FIELDS), if present in the pattern.
        local rest_capture_name_id = nil
        -- Each named field in the pattern must exist in the actual type.
        -- Also detect the rest-capture field (name_id == -2).
        for pi = pt.data[0], pt.data[0] + pt.data[1] - 1 do
            --: integer
            local pfid = ctx.lists:get(pi)
            --: any
            local pfe  = ctx.fields:get(pfid)
            if pfe.name_id == -2 then
                -- Rest-field capture: store the capture name_id for later processing.
                local prf_t = ctx.types:get(types_mod.find(ctx, pfe.type_id))
                rest_capture_name_id = prf_t.data[0]
            else
                -- Find the matching field in the input type
                local afe = types_mod.table_field(ctx, ty_id, pfe.name_id)
                if not afe then return false, nil end
                local ok, sub_bindings = M.match_pattern(ctx, afe.type_id, pfe.type_id)
                if not ok then return false, nil end
                --: any
                bindings = merge_bindings(bindings, sub_bindings)
                if bindings == nil then return false, nil end
                matched_name_ids[pfe.name_id] = true
            end
        end
        -- If the pattern has a rest-field capture (...%Rest), collect all fields from the
        -- actual type that were NOT explicitly matched and bind them to a synthetic table.
        if rest_capture_name_id then
            local rest_field_ids = {}
            for ti = tt.data[0], tt.data[0] + tt.data[1] - 1 do
                --: integer
                local tfid = ctx.lists:get(ti)
                --: any
                local tfe  = ctx.fields:get(tfid)
                if tfe.name_id >= 0 and not matched_name_ids[tfe.name_id] then
                    local copied = types_mod.make_field(ctx, tfe.name_id, tfe.type_id, tfe.flags)
                    rest_field_ids[#rest_field_ids + 1] = copied
                end
            end
            -- Build the synthetic rest table (closed, no indexers)
            local rest_tid = types_mod.make_table(ctx, rest_field_ids, {}, -1, {})
            --: any
            bindings = merge_bindings(bindings, { [rest_capture_name_id] = rest_tid })
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
        -- If the pattern has a meta-spread capture (#...%M in the meta slot list),
        -- collect all meta slots from the input and bind M to a synthetic table.
        -- Succeeds only if the input has at least one meta slot; fails otherwise.
        local pml = pt.data[6]
        if pml > 0 then
            for mi = pt.data[5], pt.data[5] + pml - 1 do
                local mfid = ctx.lists:get(mi)
                local mfe  = ctx.fields:get(mfid)
                if mfe.name_id == -3 then
                    -- Meta-spread capture: #...%M
                    local pms_t = ctx.types:get(types_mod.find(ctx, mfe.type_id))
                    local cap_name_id = pms_t.data[0]
                    -- Fail if input has no meta slots
                    if tt.data[6] == 0 then return false, nil end
                    -- Build synthetic table from input's meta slots
                    local syn_meta_ids = {}
                    for ti2 = tt.data[5], tt.data[5] + tt.data[6] - 1 do
                        local inner_fid = ctx.lists:get(ti2)
                        local inner_fe  = ctx.fields:get(inner_fid)
                        if inner_fe.name_id >= 0 then  -- skip spread markers
                            syn_meta_ids[#syn_meta_ids + 1] = types_mod.make_field(ctx, inner_fe.name_id, inner_fe.type_id, inner_fe.flags)
                        end
                    end
                    if #syn_meta_ids == 0 then return false, nil end
                    local syn_tid = types_mod.make_table(ctx, {}, {}, -1, syn_meta_ids)
                    --: any
                    bindings = merge_bindings(bindings, { [cap_name_id] = syn_tid })
                    if bindings == nil then return false, nil end
                end
            end
        end
        return true, bindings
    end

    -- Function pattern: match param and return types, collecting capture bindings.
    -- e.g. (...%P) -> R or (A, B) -> C
    if pt.tag == TAG_FUNCTION then
        -- The input must also be a function
        if tt.tag ~= TAG_FUNCTION then return false, nil end
        --: any
        local bindings = {}
        -- Match params
        local ppl = pt.data[1]  -- param count in pattern
        local tpl = tt.data[1]  -- param count in input

        -- Detect rest-capture param: TAG_SPREAD(TAG_CAPTURE) anywhere in the param list.
        -- Evaluator matches concrete prefix params left-to-right and concrete suffix params
        -- right-to-left; the middle is bound as a tuple to the capture variable.
        local rest_pos = nil     -- 0-based index of TAG_SPREAD(TAG_CAPTURE) in pattern params
        local rest_name_id = nil
        if ppl > 0 then
            for i = 0, ppl - 1 do
                --: integer
                local p_param = ctx.lists:get(pt.data[0] + i)
                local p_param_t = ctx.types:get(types_mod.find(ctx, p_param))
                if p_param_t.tag == TAG_SPREAD then
                    local inner_t = ctx.types:get(types_mod.find(ctx, p_param_t.data[0]))
                    if inner_t.tag == TAG_CAPTURE then
                        rest_pos = i
                        rest_name_id = inner_t.data[0]
                        break
                    end
                end
            end
        end

        if rest_pos ~= nil then
            -- Rest-capture mode: prefix = rest_pos params, suffix = ppl - rest_pos - 1 params.
            local prefix_len = rest_pos
            local suffix_len = ppl - rest_pos - 1
            -- Actual function must have at least prefix_len + suffix_len params.
            if tpl < prefix_len + suffix_len then return false, nil end
            -- Match prefix params
            for i = 0, prefix_len - 1 do
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
            -- Match suffix params (right-to-left)
            for j = 0, suffix_len - 1 do
                --: integer
                local p_param = ctx.lists:get(pt.data[0] + ppl - 1 - j)
                --: integer
                local t_param = ctx.lists:get(tt.data[0] + tpl - 1 - j)
                local ok, sub = M.match_pattern(ctx, t_param, p_param)
                if not ok then return false, nil end
                --: any
                bindings = merge_bindings(bindings, sub)
                if bindings == nil then return false, nil end
            end
            -- Collect middle params as a tuple for the rest capture.
            -- Always a tuple even for 0 or 1 params (the caller can spread ...P in result position).
            local middle_count = tpl - prefix_len - suffix_len
            local middle_ids = {}
            for i = 0, middle_count - 1 do
                middle_ids[i + 1] = ctx.lists:get(tt.data[0] + prefix_len + i)
            end
            local rest_tid = types_mod.make_tuple(ctx, middle_ids)
            --: any
            bindings = merge_bindings(bindings, { [rest_name_id] = rest_tid })
            if bindings == nil then return false, nil end
        elseif ppl > 0 then
            -- Normal mode: match params positionally (exact count)
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
            -- `() -> %R` where %R is a TAG_CAPTURE binds R to:
            --   trl=0: never (void function has no return to bind)
            --   trl=1: the single return type
            --   trl>1: a tuple of all return types
            -- This enables `ReturnType<F> = match F { () -> %R => R }` for any F.
            if prl == 1 then
                --: integer
                local p_ret0 = ctx.lists:get(pt.data[2])
                --: integer
                local p_ret0_canon = types_mod.find(ctx, p_ret0)
                local p_ret0_t = ctx.types:get(p_ret0_canon)
                if p_ret0_t.tag == TAG_CAPTURE or
                   (p_ret0_t.tag == TAG_NAMED and p_ret0_t.data[2] == 0) then
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

        -- TAG_PAT_ALL_FIELDS: { ...[%K]: %V } distributes over every field of the input.
        -- For each named field: K = lit_string(name), V = field_type.
        -- For each indexer: K = key_type, V = value_type.
        -- TAG_ANY/TAG_UNKNOWN: one iteration K=unknown, V=unknown.
        -- TAG_NEVER: zero iterations → contribute nothing.
        -- Always matches (total).
        local pat_t = ctx.types:get(types_mod.find(ctx, pat_id))
        if pat_t.tag == TAG_PAT_ALL_FIELDS then
            local k_name_id = pat_t.data[0]
            local v_name_id = pat_t.data[1]
            --: { [integer]: integer, ... }
            local results = {}
            local env_mod = require("lib.type.static.env")

            -- Helper: evaluate result expression with K → k_tid, V → v_tid bound
            local function eval_with_kv(k_tid, v_tid)
                local bindings = { [k_name_id] = k_tid, [v_name_id] = v_tid }
                return env_mod.substitute(ctx, res_id, bindings, seen)
            end

            local pt = ctx.types:get(param_id)
            if pt.tag == TAG_NEVER then
                -- Zero iterations: contribute nothing
            elseif pt.tag == TAG_ANY or pt.tag == TAG_UNKNOWN then
                -- One synthetic iteration: K=unknown, V=unknown
                results[#results + 1] = eval_with_kv(ctx.T_UNKNOWN, ctx.T_UNKNOWN)
            elseif pt.tag == TAG_TABLE then
                -- Named fields: K = lit_integer(name) if name is an integer, else lit_string(name)
                local intern_mod_af = require("lib.type.static.intern")
                for fi_idx = pt.data[0], pt.data[0] + pt.data[1] - 1 do
                    local fid = ctx.lists:get(fi_idx)
                    local fe  = ctx.fields:get(fid)
                    if fe.name_id >= 0 then  -- skip spread markers (name_id == -1)
                        local field_name = intern_mod_af.get(ctx.pool, fe.name_id) or ""
                        local int_val = tonumber(field_name)
                        local k_tid
                        if int_val and math.floor(int_val) == int_val then
                            -- Integer-named field (e.g. positional array element { 1, 2, 3 })
                            k_tid = types_mod.make_literal(ctx, defs.LIT_INTEGER, int_val)
                        else
                            k_tid = types_mod.make_literal(ctx, defs.LIT_STRING, fe.name_id)
                        end
                        -- Widen value types: literal integer → integer, literal string → string, etc.
                        -- This ensures that iterating over `{ 1, 2, 3 }` gives V = integer,
                        -- not the narrow literal types `1 | 2 | 3`.
                        local v_tid = types_mod.widen(ctx, fe.type_id)
                        results[#results + 1] = eval_with_kv(k_tid, v_tid)
                    end
                end
                -- Indexers: K = key_type, V = value_type
                local j = pt.data[2]
                while j < pt.data[2] + pt.data[3] - 1 do
                    local k_tid = types_mod.find(ctx, ctx.lists:get(j))
                    local v_tid = types_mod.find(ctx, ctx.lists:get(j + 1))
                    results[#results + 1] = eval_with_kv(k_tid, v_tid)
                    j = j + 2
                end
                -- If no fields and no indexers: zero iterations → never (empty/closed table).
                -- For open tables (with a row variable), the TAG_UNKNOWN/TAG_ANY branch above
                -- handles the case. An empty closed table has no keys to iterate over.
            else
                -- Non-table, non-union: one unknown iteration
                results[#results + 1] = eval_with_kv(ctx.T_UNKNOWN, ctx.T_UNKNOWN)
            end

            seen[mt_id] = nil
            if #results == 0 then return ctx.T_NEVER end
            if #results == 1 then return results[1] end
            return types_mod.make_union(ctx, results)
        end

        local ok, bindings = M.match_pattern(ctx, param_id, pat_id)
        if ok then
            seen[mt_id] = nil
            local result
            if bindings and next(bindings) then
                -- Substitute bindings into result, passing seen so that any
                -- TAG_MATCH_TYPE nodes encountered during substitution share
                -- this cycle-detection set.
                local env_mod = require("lib.type.static.env")
                result = env_mod.substitute(ctx, res_id, bindings, seen)
            else
                result = res_id
            end
            -- Evaluate any deferred $Throw that was left as a TAG_TYPE_CALL
            -- during arm substitution (to prevent spurious throws from arms
            -- that are not taken). Now that this arm IS taken, fire it.
            result = types_mod.find(ctx, result)
            local rt = ctx.types:get(result)
            if rt.tag == defs.TAG_TYPE_CALL then
                local callee_t = ctx.types:get(types_mod.find(ctx, rt.data[0]))
                if callee_t.tag == defs.TAG_INTRINSIC then
                    local intr_name = require("lib.type.static.intern").get(ctx.pool, callee_t.data[0]) or ""
                    if intr_name == "Throw" then
                        local arg_ids = {}
                        for j = rt.data[1], rt.data[1] + rt.data[2] - 1 do
                            arg_ids[#arg_ids + 1] = ctx.lists:get(j)
                        end
                        local intrinsic_mod = require("lib.type.static.intrinsic")
                        result = intrinsic_mod.expand(ctx, callee_t.data[0], arg_ids, rt.data[3])
                    end
                end
            end
            return result
        end
        i = i + 2
    end

    seen[mt_id] = nil
    return ctx.T_NEVER
end

return M
