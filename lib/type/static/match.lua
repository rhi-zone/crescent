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

-- ── Coinductive field-merging helpers ──────────────────────────────────────────

-- Expand a TAG_NAMED type one level using env.resolve_named_type.
-- Returns the resolved type_id, or nil if it cannot be expanded
-- (undefined alias, arity error, or cycle detected via seen_named).
-- seen_named: { [ty_id] = true } — prevents re-expanding the same named node.
--: (Ctx, integer, { [integer]: boolean, ... }) -> integer | nil
local function expand_named(ctx, ty_id, seen_named)
    if seen_named[ty_id] then return nil end
    local t = ctx.types:get(ty_id)
    if t.tag ~= TAG_NAMED then return nil end
    local name_id  = t.data[0]
    local args_len = t.data[2]
    local arg_ids  = nil
    if args_len > 0 then
        arg_ids = {}
        for i = t.data[1], t.data[1] + args_len - 1 do
            --: integer
            local aid = ctx.lists:get(i)
            arg_ids[#arg_ids + 1] = aid
        end
    end
    local env_mod = require("lib.type.static.env")
    local scope = ctx.scope
    if not scope then return nil end
    seen_named[ty_id] = true
    local resolved = env_mod.resolve_named_type(ctx, scope, name_id, arg_ids)
    -- Note: we do NOT clear seen_named[ty_id] after returning — once expanded,
    -- we assume the result terminates; the coinductive hypothesis prevents re-entry.
    if not resolved then
        return nil
    end
    return types_mod.find(ctx, resolved)
end

-- intersect_field_in_type: look up field `name_id` in type `ty_id` coinductively.
-- Returns:
--   type_id   — the field's type (possibly T_NEVER if a closed member lacks the field)
--   nil       — neutral: open member that doesn't mention this field (skip, don't intersect)
-- The `seen_named` table prevents infinite expansion of recursive named types.
-- The `pat_seen` table is the match_pattern coinductive seen-set (passed through).
--: (Ctx, integer, integer, { [integer]: boolean, ... }, { [string]: boolean, ... }) -> integer | nil
local function intersect_field_in_type(ctx, ty_id, name_id, seen_named, pat_seen)
    ty_id = types_mod.find(ctx, ty_id)
    local t = ctx.types:get(ty_id)

    if t.tag == TAG_TABLE then
        -- Look up the field directly.
        local fe = types_mod.table_field(ctx, ty_id, name_id)
        if fe then
            return fe.type_id
        end
        -- Field absent: open or closed?
        -- data[4] >= 0 means has row variable (open table).
        if t.data[4] >= 0 then
            return nil  -- open: neutral, skip
        else
            return ctx.T_NEVER  -- closed: this member forbids the field
        end
    end

    if t.tag == TAG_INTERSECTION then
        -- Recurse into each intersection member and intersect contributions.
        --: { [integer]: integer, ... }
        local contributions = {}
        for i = 0, t.data[1] - 1 do
            --: integer
            local mid = ctx.lists:get(t.data[0] + i)
            local contrib = intersect_field_in_type(ctx, mid, name_id, seen_named, pat_seen)
            if contrib == ctx.T_NEVER then
                return ctx.T_NEVER  -- fast-fail
            end
            if contrib ~= nil then
                contributions[#contributions + 1] = contrib
            end
        end
        if #contributions == 0 then return nil end
        --: integer
        if #contributions == 1 then return contributions[1] end
        return types_mod.make_intersection(ctx, contributions)
    end

    if t.tag == TAG_UNION then
        -- Contribute the union of each member's field type.
        -- If any member returns nil (open, missing), that member contributes T_UNKNOWN
        -- (since an open member might have the field at runtime).
        --: { [integer]: integer, ... }
        local parts = {}
        for i = 0, t.data[1] - 1 do
            --: integer
            local mid = ctx.lists:get(t.data[0] + i)
            local contrib = intersect_field_in_type(ctx, mid, name_id, seen_named, pat_seen)
            if contrib == ctx.T_NEVER then
                -- This union member cannot have the field — contribute never (it will be filtered)
                parts[#parts + 1] = ctx.T_NEVER
            elseif contrib == nil then
                -- Open member, might have it: contribute unknown
                parts[#parts + 1] = ctx.T_UNKNOWN
            else
                parts[#parts + 1] = contrib
            end
        end
        if #parts == 0 then return nil end
        --: integer
        if #parts == 1 then return parts[1] end
        return types_mod.make_union(ctx, parts)
    end

    if t.tag == TAG_NAMED then
        -- Coinductive hypothesis: if we've seen this node, assume compatible (neutral).
        if seen_named[ty_id] then return nil end
        local expanded = expand_named(ctx, ty_id, seen_named)
        if not expanded then return nil end
        return intersect_field_in_type(ctx, expanded, name_id, seen_named, pat_seen)
    end

    if t.tag == TAG_MATCH_TYPE then
        -- Evaluate the match type, then recurse on the result.
        local result = M.evaluate(ctx, ty_id, pat_seen)
        result = types_mod.find(ctx, result)
        return intersect_field_in_type(ctx, result, name_id, seen_named, pat_seen)
    end

    -- Other tags (primitives, functions, etc.): no fields, treat as closed non-table.
    -- Returning T_NEVER would be too strict — these are not "closed tables that lack x".
    -- Return nil (neutral) so we don't abort the intersection unnecessarily.
    return nil
end

-- Merge two bindings tables, returning merged or nil on conflict.
--: ({ [integer]: integer } | nil, { [integer]: integer } | nil) -> ({ [integer]: integer } | nil)
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
-- seen: { ["ty_id:pat_id"] = true } coinductive cycle-detection set.
--: (Ctx, integer, integer, { [string]: boolean, ... } | nil) -> (boolean, { [integer]: integer, ... } | nil)
function M.match_pattern(ctx, ty_id, pat_id, seen)
    seen = seen or {}

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
    if pt.tag == TAG_TABLE then
        -- If the input is a TAG_TABLE, use direct structural matching.
        if tt.tag == TAG_TABLE then
            --: { [integer]: integer, ... } | nil
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
                local pfe  = ctx.fields:get(pfid)
                if pfe.name_id == -2 then
                    -- Rest-field capture: store the capture name_id for later processing.
                    local prf_t = ctx.types:get(types_mod.find(ctx, pfe.type_id))
                    rest_capture_name_id = prf_t.data[0]
                else
                    -- Find the matching field in the input type
                    local afe = types_mod.table_field(ctx, ty_id, pfe.name_id)
                    if not afe then return false, nil end
                    local ok, sub_bindings = M.match_pattern(ctx, afe.type_id, pfe.type_id, seen)
                    if not ok then return false, nil end
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
                    local tfe  = ctx.fields:get(tfid)
                    if tfe.name_id >= 0 and not matched_name_ids[tfe.name_id] then
                        local copied = types_mod.make_field(ctx, tfe.name_id, tfe.type_id, tfe.flags)
                        rest_field_ids[#rest_field_ids + 1] = copied
                    end
                end
                -- Build the synthetic rest table (closed, no indexers)
                local rest_tid = types_mod.make_table(ctx, rest_field_ids, {}, -1, {})
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
                    local ok, sub = M.match_pattern(ctx, tk_id, pk_id, seen)
                    if not ok then return false, nil end
                    bindings = merge_bindings(bindings, sub)
                    if bindings == nil then return false, nil end
                    ok, sub = M.match_pattern(ctx, tv_id, pv_id, seen)
                    if not ok then return false, nil end
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
                        bindings = merge_bindings(bindings, { [cap_name_id] = syn_tid })
                        if bindings == nil then return false, nil end
                    end
                end
            end
            return true, bindings
        end

        -- Input is TAG_INTERSECTION: coinductive field-merging structural match.
        -- For each named field in the pattern, look it up in every intersection member
        -- and intersect the contributions. If any closed member lacks the field → T_NEVER
        -- → fail. Open members that lack the field contribute nil (neutral, skip).
        if tt.tag == TAG_INTERSECTION then
            local cycle_key = ty_id .. ":" .. pat_id
            if seen[cycle_key] then
                -- Coinductive hypothesis: assume match succeeds, no bindings
                return true, {}
            end
            seen[cycle_key] = true

            --: { [integer]: integer, ... } | nil
            local bindings = {}
            local seen_named = {}  -- per-field-lookup expansion guard

            -- Check pattern fields via coinductive field merging
            local rest_capture_name_id = nil
            for pi = pt.data[0], pt.data[0] + pt.data[1] - 1 do
                --: integer
                local pfid = ctx.lists:get(pi)
                local pfe  = ctx.fields:get(pfid)
                if pfe.name_id == -2 then
                    -- Rest-field capture: deferred (handled below if needed)
                    local prf_t = ctx.types:get(types_mod.find(ctx, pfe.type_id))
                    rest_capture_name_id = prf_t.data[0]
                else
                    -- Collect this field's type from all intersection members.
                    local field_ty = intersect_field_in_type(ctx, ty_id, pfe.name_id, seen_named, seen)
                    if field_ty == nil then
                        -- All members are open and none has the field: pattern fails
                        -- (open intersection doesn't guarantee the field exists).
                        seen[cycle_key] = nil
                        return false, nil
                    end
                    if types_mod.find(ctx, field_ty) == ctx.T_NEVER then
                        -- A closed member forbids the field: pattern fails.
                        seen[cycle_key] = nil
                        return false, nil
                    end
                    -- Now match the field's merged type against the pattern field type.
                    local ok, sub_bindings = M.match_pattern(ctx, field_ty, pfe.type_id, seen)
                    if not ok then
                        seen[cycle_key] = nil
                        return false, nil
                    end
                    bindings = merge_bindings(bindings, sub_bindings)
                    if bindings == nil then
                        seen[cycle_key] = nil
                        return false, nil
                    end
                end
            end

            -- Rest-field capture for intersection: collect fields from each member
            -- that are not explicitly matched by the pattern, then union/intersect.
            -- This is a best-effort: we enumerate fields from the first TAG_TABLE member.
            if rest_capture_name_id then
                local matched_name_ids = {}
                for pi = pt.data[0], pt.data[0] + pt.data[1] - 1 do
                    local pfid = ctx.lists:get(pi)
                    local pfe  = ctx.fields:get(pfid)
                    if pfe.name_id >= 0 then
                        matched_name_ids[pfe.name_id] = true
                    end
                end
                -- Gather unmatched fields from all TABLE members.
                local rest_names = {}  -- name_id → true, deduped
                local rest_field_ids = {}
                for i = 0, tt.data[1] - 1 do
                    local mid = ctx.lists:get(tt.data[0] + i)
                    local mt = ctx.types:get(types_mod.find(ctx, mid))
                    if mt.tag == TAG_TABLE then
                        for fi = mt.data[0], mt.data[0] + mt.data[1] - 1 do
                            local fid = ctx.lists:get(fi)
                            local fe  = ctx.fields:get(fid)
                            if fe.name_id >= 0 and not matched_name_ids[fe.name_id] and not rest_names[fe.name_id] then
                                rest_names[fe.name_id] = true
                                local copied = types_mod.make_field(ctx, fe.name_id, fe.type_id, fe.flags)
                                rest_field_ids[#rest_field_ids + 1] = copied
                            end
                        end
                    end
                end
                local rest_tid = types_mod.make_table(ctx, rest_field_ids, {}, -1, {})
                bindings = merge_bindings(bindings, { [rest_capture_name_id] = rest_tid })
                if bindings == nil then
                    seen[cycle_key] = nil
                    return false, nil
                end
            end

            -- Pattern indexers: for intersection inputs, check that any pattern indexer
            -- is satisfied by the intersection. Use try_unify as a subtype check.
            local pil = pt.data[3]
            if pil >= 2 then
                local unify_mod = require("lib.type.static.unify")
                if not unify_mod.try_unify(ctx, ty_id, pat_id, {}) then
                    seen[cycle_key] = nil
                    return false, nil
                end
            end

            seen[cycle_key] = nil
            return true, bindings
        end

        -- Input is TAG_NAMED: expand one level and recurse.
        if tt.tag == TAG_NAMED then
            local cycle_key = ty_id .. ":" .. pat_id
            if seen[cycle_key] then
                return true, {}  -- coinductive hypothesis
            end
            seen[cycle_key] = true
            local seen_named = {}
            local expanded = expand_named(ctx, ty_id, seen_named)
            seen[cycle_key] = nil
            if not expanded then return false, nil end
            local ok, b = M.match_pattern(ctx, expanded, pat_id, seen)
            return ok, b
        end

        -- Input is TAG_MATCH_TYPE: evaluate then recurse.
        if tt.tag == TAG_MATCH_TYPE then
            local result = M.evaluate(ctx, ty_id, seen)
            local ok, b = M.match_pattern(ctx, result, pat_id, seen)
            return ok, b
        end

        -- For all other input tags (non-table): table pattern fails.
        return false, nil
    end

    -- Function pattern: match param and return types, collecting capture bindings.
    -- e.g. (...%P) -> R or (A, B) -> C
    if pt.tag == TAG_FUNCTION then
        -- The input must also be a function
        if tt.tag ~= TAG_FUNCTION then return false, nil end
        --: { [integer]: integer, ... } | nil
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
                local ok, sub = M.match_pattern(ctx, t_param, p_param, seen)
                if not ok then return false, nil end
                bindings = merge_bindings(bindings, sub)
                if bindings == nil then return false, nil end
            end
            -- Match suffix params (right-to-left)
            for j = 0, suffix_len - 1 do
                --: integer
                local p_param = ctx.lists:get(pt.data[0] + ppl - 1 - j)
                --: integer
                local t_param = ctx.lists:get(tt.data[0] + tpl - 1 - j)
                local ok, sub = M.match_pattern(ctx, t_param, p_param, seen)
                if not ok then return false, nil end
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
                local ok, sub = M.match_pattern(ctx, t_param, p_param, seen)
                if not ok then return false, nil end
                bindings = merge_bindings(bindings, sub)
                if bindings == nil then return false, nil end
            end
        end
        -- Match vararg
        local p_va = pt.data[4]
        if p_va >= 0 then
            local t_va = tt.data[4]
            if t_va < 0 then return false, nil end
            local ok, sub = M.match_pattern(ctx, t_va, p_va, seen)
            if not ok then return false, nil end
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
                    local ok, sub = M.match_pattern(ctx, bound_tid, p_ret0_canon, seen)
                    if not ok then return false, nil end
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
                local ok, sub = M.match_pattern(ctx, t_ret, p_ret, seen)
                if not ok then return false, nil end
                bindings = merge_bindings(bindings, sub)
                if bindings == nil then return false, nil end
            end
        end
        return true, bindings
    end

    -- Union pattern: ty_id matches if it is a subtype of the union.
    -- This occurs when an alias param like `Keys` (bound to `"x" | "y"`) is used
    -- directly as a pattern after substitution replaces it with the union type.
    -- Use try_unify for subtype checking: try_unify(ctx, actual, expected) succeeds
    -- when actual <: expected.
    if pt.tag == TAG_UNION then
        local unify_mod = require("lib.type.static.unify")
        if unify_mod.try_unify(ctx, ty_id, pat_id, {}) then
            return true, {}
        end
        return false, nil
    end

    -- Intersection input against non-table, non-union, non-function patterns:
    -- use intersection elimination — A & B <: A, so if any member matches, the arm fires.
    -- This handles cases like `match (integer & string) { integer => T }` (MA7c) and
    -- `match (integer & (string | boolean)) { integer => T }` (MA7g, where the union
    -- is inside the intersection).
    -- No bindings are produced (the pattern has no captures at this point).
    if tt.tag == TAG_INTERSECTION then
        for i = 0, tt.data[1] - 1 do
            local mid = ctx.lists:get(tt.data[0] + i)
            local ok, sub = M.match_pattern(ctx, mid, pat_id, seen)
            if ok then
                return true, sub or {}
            end
        end
        return false, nil
    end

    -- Named input against non-table patterns: expand one level and retry.
    if tt.tag == TAG_NAMED then
        local cycle_key = ty_id .. ":" .. pat_id
        if seen[cycle_key] then
            return true, {}  -- coinductive hypothesis
        end
        seen[cycle_key] = true
        local seen_named = {}
        local expanded = expand_named(ctx, ty_id, seen_named)
        seen[cycle_key] = nil
        if not expanded then return false, nil end
        local ok, b = M.match_pattern(ctx, expanded, pat_id, seen)
        return ok, b
    end

    -- Match-type input: evaluate then retry.
    if tt.tag == TAG_MATCH_TYPE then
        local result = M.evaluate(ctx, ty_id, seen)
        local ok, b = M.match_pattern(ctx, result, pat_id, seen)
        return ok, b
    end

    return false, nil
end

-- Evaluate a match type.
-- mt_id: type_id of a TAG_MATCH_TYPE slot
-- seen:  { [mt_id] -> true } cycle-detection set (shared across recursive calls)
-- Returns the result type_id of the first matching arm, or T_NEVER.
--: (Ctx, integer, { [integer]: boolean, ... } | nil) -> integer
function M.evaluate(ctx, mt_id, seen)
    seen = seen or {}

    -- Cycle detection: if we are already evaluating this exact match-type node,
    -- return never to break the cycle rather than looping or crashing.
    if seen[mt_id] then return ctx.T_NEVER end
    seen[mt_id] = true

    local mt = ctx.types:get(mt_id)
    if mt.tag ~= TAG_MATCH_TYPE then
        seen[mt_id] = nil
        return ctx.T_NEVER
    end

    local param_id = types_mod.find(ctx, mt.data[0])
    local arms_start = mt.data[1]
    local arms_len   = mt.data[2]

    -- Memoization: cache (mt_id, param_id) → result across evaluations.
    -- The seen-set prevents loops within an evaluation; the cache reuses completed results.
    ctx.match_cache = ctx.match_cache or {}
    local cache_key = mt_id .. ":" .. param_id
    local cached = ctx.match_cache[cache_key]
    if cached ~= nil then
        seen[mt_id] = nil
        return cached
    end

    -- Fast path: distribute over union inputs only.
    -- TAG_UNION: match each member independently, union the results.
    -- TAG_INTERSECTION and TAG_NAMED: pass straight to arm loop; match_pattern handles them.
    local top = ctx.types:get(param_id)
    if top.tag == TAG_UNION then
        --: { [integer]: integer, ... }
        local results = {}
        for idx = 0, top.data[1] - 1 do
            local member_id = ctx.lists:get(top.data[0] + idx)
            -- Build a temporary match-type node with this member as the param.
            -- Reuse the existing arms slice from the list pool (no new allocation).
            local sub_mt = types_mod.alloc_type(ctx, TAG_MATCH_TYPE)
            local sub_mtt = ctx.types:get(sub_mt)
            sub_mtt.data[0] = member_id
            sub_mtt.data[1] = arms_start
            sub_mtt.data[2] = arms_len
            results[#results + 1] = M.evaluate(ctx, sub_mt, seen)
        end
        seen[mt_id] = nil
        local result
        if #results == 0 then
            result = ctx.T_NEVER
        elseif #results == 1 then
            result = results[1]
        else
            result = types_mod.make_union(ctx, results)
        end
        ctx.match_cache[cache_key] = result
        return result
    end

    -- Arm loop: TAG_INTERSECTION and TAG_NAMED inputs go directly here.
    -- match_pattern handles coinductive expansion and field merging.
    local pat_seen = {}  -- per-evaluation coinductive seen-set for match_pattern

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
            local result
            if #results == 0 then
                result = ctx.T_NEVER
            elseif #results == 1 then
                result = results[1]
            else
                result = types_mod.make_union(ctx, results)
            end
            ctx.match_cache[cache_key] = result
            return result
        end

        local ok, bindings = M.match_pattern(ctx, param_id, pat_id, pat_seen)
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
            ctx.match_cache[cache_key] = result
            return result
        end
        i = i + 2
    end

    seen[mt_id] = nil
    ctx.match_cache[cache_key] = ctx.T_NEVER
    return ctx.T_NEVER
end

-- Indexed access: lookup `key_tid` in `subject_tid`, returning a type id or nil.
--
-- - String/integer literal key on a TAG_TABLE: try named-field lookup first; fall back
--   to indexer matching (e.g. `M[string]` where M is `{ [string]: number }`).
-- - Type-valued key on a TAG_TABLE: scan indexers, find one whose key type the
--   query key is a subtype of, return its value.
-- - TAG_UNION subject: distribute, union the per-member results (TS-style).
-- - TAG_INTERSECTION subject: take any member that has the key; intersect successes.
-- - TAG_NAMED subject: expand one level and recurse.
--
-- Returns nil on miss; caller is responsible for emitting INDEX_KEY_NOT_FOUND.
--: (Ctx, integer, integer) -> integer | nil
function M.lookup_index(ctx, subject_tid, key_tid)
    subject_tid = types_mod.find(ctx, subject_tid)
    key_tid = types_mod.find(ctx, key_tid)
    local st = ctx.types:get(subject_tid)

    if st.tag == TAG_UNION then
        local results = {}
        for i = 0, st.data[1] - 1 do
            local mid = ctx.lists:get(st.data[0] + i)
            local r = M.lookup_index(ctx, mid, key_tid)
            if r == nil then return nil end  -- any member missing → fail the whole lookup
            results[#results + 1] = r
        end
        if #results == 0 then return nil end
        if #results == 1 then return results[1] end
        return types_mod.make_union(ctx, results)
    end

    if st.tag == TAG_INTERSECTION then
        -- Mirror match.lua's indexer unification approach: collect contributions
        -- from members that have the key; intersect them.
        local contribs = {}
        for i = 0, st.data[1] - 1 do
            local mid = ctx.lists:get(st.data[0] + i)
            local r = M.lookup_index(ctx, mid, key_tid)
            if r ~= nil then
                contribs[#contribs + 1] = r
            end
        end
        if #contribs == 0 then return nil end
        if #contribs == 1 then return contribs[1] end
        return types_mod.make_intersection(ctx, contribs)
    end

    if st.tag == TAG_NAMED then
        local seen_named = {}
        local expanded = expand_named(ctx, subject_tid, seen_named)
        if not expanded then return nil end
        return M.lookup_index(ctx, expanded, key_tid)
    end

    if st.tag == TAG_MATCH_TYPE then
        local result = M.evaluate(ctx, subject_tid, {})
        return M.lookup_index(ctx, result, key_tid)
    end

    if st.tag ~= TAG_TABLE then
        return nil
    end

    local kt = ctx.types:get(key_tid)

    -- String literal key: try named-field lookup first.
    if kt.tag == TAG_LITERAL and kt.data[0] == LIT_STRING then
        local name_id = kt.data[1]
        local fe = types_mod.table_field(ctx, subject_tid, name_id)
        if fe then return fe.type_id end
        -- Fall through to indexer lookup (string literal can match `[string]: V`).
    end

    -- Indexer lookup: scan indexer pairs, find one whose key type accepts the query key.
    local pis = st.data[2]
    local pil = st.data[3]
    if pil >= 2 then
        local unify_mod = require("lib.type.static.unify")
        local i = pis
        while i < pis + pil - 1 do
            local idx_k = types_mod.find(ctx, ctx.lists:get(i))
            local idx_v = types_mod.find(ctx, ctx.lists:get(i + 1))
            if unify_mod.try_unify(ctx, key_tid, idx_k, {}) then
                return idx_v
            end
            i = i + 2
        end
    end

    return nil
end

return M
