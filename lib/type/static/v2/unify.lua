-- lib/type/static/v2/unify.lua
-- HM unification extended for structural types.
-- Ports v1 unify.lua to work with flat TypeSlot arenas.

local defs = require("lib.type.static.v2.defs")
local types_mod = require("lib.type.static.v2.types")
local intern_mod = require("lib.type.static.v2.intern")

local TAG_NIL          = defs.TAG_NIL
local TAG_BOOLEAN      = defs.TAG_BOOLEAN
local TAG_NUMBER       = defs.TAG_NUMBER
local TAG_STRING       = defs.TAG_STRING
local TAG_ANY          = defs.TAG_ANY
local TAG_NEVER        = defs.TAG_NEVER
local TAG_INTEGER      = defs.TAG_INTEGER
local TAG_LITERAL      = defs.TAG_LITERAL
local TAG_FUNCTION     = defs.TAG_FUNCTION
local TAG_TABLE        = defs.TAG_TABLE
local TAG_UNION        = defs.TAG_UNION
local TAG_INTERSECTION = defs.TAG_INTERSECTION
local TAG_VAR          = defs.TAG_VAR
local TAG_ROWVAR       = defs.TAG_ROWVAR
local TAG_TUPLE        = defs.TAG_TUPLE
local TAG_NOMINAL      = defs.TAG_NOMINAL
local TAG_MATCH_TYPE   = defs.TAG_MATCH_TYPE
local TAG_CDATA        = defs.TAG_CDATA
local TAG_NAMED        = defs.TAG_NAMED
local TAG_SPREAD       = defs.TAG_SPREAD

local LIT_STRING  = defs.LIT_STRING
local LIT_NUMBER  = defs.LIT_NUMBER
local LIT_BOOLEAN = defs.LIT_BOOLEAN

-- Meta ops supported natively by primitive types
local M = {}
local find = types_mod.find

-- Occurs check: does the var at `var_tid` (after find) appear in type `tid`?
-- var_tid must be the root of a TAG_VAR or TAG_ROWVAR.
local function occurs(ctx, var_tid, tid)
    tid = find(ctx, tid)
    if tid == var_tid then return true end
    local t = ctx.types:get(tid)
    local tag = t.tag

    if tag == TAG_FUNCTION then
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            if occurs(ctx, var_tid, ctx.lists:get(i)) then return true end
        end
        for i = t.data[2], t.data[2] + t.data[3] - 1 do
            if occurs(ctx, var_tid, ctx.lists:get(i)) then return true end
        end
        if t.data[4] >= 0 then
            if occurs(ctx, var_tid, t.data[4]) then return true end
        end
        return false
    end

    if tag == TAG_TABLE then
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            local fe = ctx.fields:get(ctx.lists:get(i))
            if occurs(ctx, var_tid, fe.type_id) then return true end
        end
        local is, il = t.data[2], t.data[3]
        for i = is, is + il - 1 do
            if occurs(ctx, var_tid, ctx.lists:get(i)) then return true end
        end
        for i = t.data[5], t.data[5] + t.data[6] - 1 do
            local fe = ctx.fields:get(ctx.lists:get(i))
            if occurs(ctx, var_tid, fe.type_id) then return true end
        end
        return false
    end

    if tag == TAG_UNION or tag == TAG_INTERSECTION or tag == TAG_TUPLE then
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            if occurs(ctx, var_tid, ctx.lists:get(i)) then return true end
        end
        return false
    end

    if tag == TAG_SPREAD then
        return occurs(ctx, var_tid, t.data[0])
    end

    return false
end

-- Adjust levels: lower the level of free vars in `tid` to max_level.
local function adjust_levels(ctx, tid, max_level, seen)
    tid = find(ctx, tid)
    if seen and seen[tid] then return end
    local t = ctx.types:get(tid)
    local tag = t.tag

    if tag == TAG_VAR or tag == TAG_ROWVAR then
        if t.data[1] > max_level then t.data[1] = max_level end
        return
    end

    seen = seen or {}
    seen[tid] = true

    if tag == TAG_FUNCTION then
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            adjust_levels(ctx, ctx.lists:get(i), max_level, seen)
        end
        for i = t.data[2], t.data[2] + t.data[3] - 1 do
            adjust_levels(ctx, ctx.lists:get(i), max_level, seen)
        end
        if t.data[4] >= 0 then
            adjust_levels(ctx, t.data[4], max_level, seen)
        end
        return
    end

    if tag == TAG_TABLE then
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            local fe = ctx.fields:get(ctx.lists:get(i))
            adjust_levels(ctx, fe.type_id, max_level, seen)
        end
        local is, il = t.data[2], t.data[3]
        for i = is, is + il - 1 do
            adjust_levels(ctx, ctx.lists:get(i), max_level, seen)
        end
        for i = t.data[5], t.data[5] + t.data[6] - 1 do
            local fe = ctx.fields:get(ctx.lists:get(i))
            adjust_levels(ctx, fe.type_id, max_level, seen)
        end
        return
    end

    if tag == TAG_UNION or tag == TAG_INTERSECTION or tag == TAG_TUPLE then
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            adjust_levels(ctx, ctx.lists:get(i), max_level, seen)
        end
        return
    end
end

-- Bind a type variable to a type.
-- Returns true, or false + error message.
local function bind_var(ctx, var_tid, target_tid)
    -- var_tid is already find()'d to root
    if occurs(ctx, var_tid, target_tid) then
        -- Special case: `x = x or default` → union containing var itself.
        -- Strip var out of the union.
        local target_root = find(ctx, target_tid)
        local tt = ctx.types:get(target_root)
        if tt.tag == TAG_UNION then
            local filtered = {}
            for i = tt.data[0], tt.data[0] + tt.data[1] - 1 do
                local mid = find(ctx, ctx.lists:get(i))
                if mid ~= var_tid then
                    filtered[#filtered + 1] = mid
                end
            end
            if #filtered < tt.data[1] then
                local new_ty
                if #filtered == 0 then
                    new_ty = ctx.T_NEVER
                elseif #filtered == 1 then
                    new_ty = filtered[1]
                else
                    new_ty = types_mod.make_union(ctx, filtered)
                end
                if not occurs(ctx, var_tid, new_ty) then
                    adjust_levels(ctx, new_ty, ctx.types:get(var_tid).data[1])
                    ctx.types:get(var_tid).data[2] = new_ty
                    return true
                end
            end
        end
        return false, "recursive type"
    end
    local vt = ctx.types:get(var_tid)
    adjust_levels(ctx, target_tid, vt.data[1])
    vt.data[2] = target_tid
    return true
end

-- Check if tag is a primitive (same-tag implies equality)
local function is_primitive_tag(tag)
    return tag == TAG_NIL or tag == TAG_BOOLEAN or tag == TAG_NUMBER
        or tag == TAG_INTEGER or tag == TAG_STRING
end

-- Helper: get intern_id for meta slot name
local function meta_intern_id(ctx, name)
    return intern_mod.intern(ctx.pool, name)
end

-- unify(ctx, a, b): check if a is assignable to b, binding vars as needed.
-- Returns true, or false + error_message [+ detail_table]
function M.unify(ctx, a, b)
    a = find(ctx, a)
    b = find(ctx, b)

    -- Named types (unresolved): treat as any
    if ctx.types:get(a).tag == TAG_NAMED then return true end
    if ctx.types:get(b).tag == TAG_NAMED then return true end

    -- Same type_id
    if a == b then return true end

    local ta = ctx.types:get(a)
    local tb = ctx.types:get(b)

    -- any is bilateral
    if ta.tag == TAG_ANY or tb.tag == TAG_ANY then return true end

    -- never is bottom
    if ta.tag == TAG_NEVER then return true end

    -- Type variable binding
    if ta.tag == TAG_VAR then
        return bind_var(ctx, a, b)
    end
    if tb.tag == TAG_VAR then
        return bind_var(ctx, b, a)
    end

    -- Nominal types: identity-based
    if ta.tag == TAG_NOMINAL and tb.tag == TAG_NOMINAL then
        if ta.data[1] == tb.data[1] then return true end
        local na = intern_mod.get(ctx.pool, ta.data[0]) or "?"
        local nb = intern_mod.get(ctx.pool, tb.data[0]) or "?"
        return false, "nominal type '" .. na .. "' is not '" .. nb .. "'"
    end
    if ta.tag == TAG_NOMINAL then
        local na = intern_mod.get(ctx.pool, ta.data[0]) or "?"
        return false, "nominal type '" .. na .. "' is not assignable to '" .. types_mod.display(ctx, b) .. "'"
    end
    if tb.tag == TAG_NOMINAL then
        local nb = intern_mod.get(ctx.pool, tb.data[0]) or "?"
        return false, "'" .. types_mod.display(ctx, a) .. "' is not assignable to nominal type '" .. nb .. "'"
    end

    -- integer <: number (every integer is a number; not the reverse)
    if ta.tag == TAG_INTEGER and tb.tag == TAG_NUMBER then return true end

    -- Literal <: base type
    if ta.tag == TAG_LITERAL then
        if tb.tag == TAG_LITERAL then
            if ta.data[0] == tb.data[0] and ta.data[1] == tb.data[1] then return true end
            return false, "'" .. types_mod.display(ctx, a) .. "' is not '" .. types_mod.display(ctx, b) .. "'"
        end
        local kind = ta.data[0]
        if (kind == LIT_STRING  and tb.tag == TAG_STRING)  then return true end
        if (kind == LIT_NUMBER  and tb.tag == TAG_NUMBER)  then return true end
        if (kind == LIT_BOOLEAN and tb.tag == TAG_BOOLEAN) then return true end
    end

    -- Same primitive tags
    if ta.tag == tb.tag and is_primitive_tag(ta.tag) then return true end

    -- Union on LHS: each member must be assignable to RHS
    if ta.tag == TAG_UNION then
        for i = ta.data[0], ta.data[0] + ta.data[1] - 1 do
            local mid = find(ctx, ctx.lists:get(i))
            local ok, err = M.unify(ctx, mid, b)
            if not ok then
                return false, types_mod.display(ctx, mid) .. " in union is not assignable to " .. types_mod.display(ctx, b)
            end
        end
        return true
    end

    -- Union on RHS: LHS must be assignable to at least one member
    if tb.tag == TAG_UNION then
        local best_detail, best_depth = nil, -1
        for i = tb.data[0], tb.data[0] + tb.data[1] - 1 do
            local mid = find(ctx, ctx.lists:get(i))
            local ok, _, detail = M.unify(ctx, a, mid)
            if ok then return true end
            if detail and detail.kind == "mismatch" then
                local depth = detail.path and #detail.path or 0
                if depth > best_depth then
                    best_detail = detail
                    best_depth = depth
                end
            end
        end
        return false, "'" .. types_mod.display(ctx, a) .. "' is not assignable to '" .. types_mod.display(ctx, b) .. "'",
            best_detail
    end

    -- Intersection on RHS: LHS must satisfy all members
    if tb.tag == TAG_INTERSECTION then
        for i = tb.data[0], tb.data[0] + tb.data[1] - 1 do
            local ok, err = M.unify(ctx, a, ctx.lists:get(i))
            if not ok then return false, err end
        end
        return true
    end

    -- Intersection on LHS: at least one member satisfies RHS
    if ta.tag == TAG_INTERSECTION then
        for i = ta.data[0], ta.data[0] + ta.data[1] - 1 do
            local ok = M.unify(ctx, ctx.lists:get(i), b)
            if ok then return true end
        end
        return false, "'" .. types_mod.display(ctx, a) .. "' is not assignable to '" .. types_mod.display(ctx, b) .. "'"
    end

    -- Function types: contravariant params, covariant returns
    if ta.tag == TAG_FUNCTION and tb.tag == TAG_FUNCTION then
        local apl, bpl = ta.data[1], tb.data[1]
        local max_params = apl > bpl and apl or bpl
        for i = 0, max_params - 1 do
            local ap_id, bp_id
            if i < apl then
                ap_id = find(ctx, ctx.lists:get(ta.data[0] + i))
            else
                ap_id = ctx.T_NIL
            end
            if i < bpl then
                bp_id = find(ctx, ctx.lists:get(tb.data[0] + i))
            else
                bp_id = ctx.T_NIL
            end
            -- Contravariant: b's param assignable to a's param
            local ok, err = M.unify(ctx, bp_id, ap_id)
            if not ok then
                return false, "parameter " .. (i + 1) .. ": " .. (err or "type mismatch")
            end
        end
        local arl, brl = ta.data[3], tb.data[3]
        local max_rets = arl > brl and arl or brl
        for i = 0, max_rets - 1 do
            local ar_id, br_id
            if i < arl then
                ar_id = find(ctx, ctx.lists:get(ta.data[2] + i))
            else
                ar_id = ctx.T_NIL
            end
            if i < brl then
                br_id = find(ctx, ctx.lists:get(tb.data[2] + i))
            else
                br_id = ctx.T_NIL
            end
            local ok, err = M.unify(ctx, ar_id, br_id)
            if not ok then
                return false, "return " .. (i + 1) .. ": " .. (err or "type mismatch")
            end
        end
        return true
    end

    -- Primitives satisfy meta-only table constraints (e.g. number satisfies { #__add: fn }).
    -- Look up the primitive's declared meta type from ctx.prim_meta (keyed by base TAG_*).
    if tb.tag == TAG_TABLE and tb.data[1] == 0 and tb.data[3] == 0 and tb.data[6] > 0 then
        local ptag = ta.tag
        if ptag == TAG_LITERAL then
            if ta.data[0] == LIT_NUMBER  then ptag = TAG_NUMBER
            elseif ta.data[0] == LIT_STRING then ptag = TAG_STRING
            else ptag = nil
            end
        elseif ptag ~= TAG_NUMBER and ptag ~= TAG_INTEGER and ptag ~= TAG_STRING then
            ptag = nil
        end
        local prim_meta_tid = ptag and ctx.prim_meta[ptag]
        if prim_meta_tid then
            for i = tb.data[5], tb.data[5] + tb.data[6] - 1 do
                local fe  = ctx.fields:get(ctx.lists:get(i))
                local amf = types_mod.table_meta_field(ctx, prim_meta_tid, fe.name_id)
                if not amf then
                    local mname = intern_mod.get(ctx.pool, fe.name_id) or "?"
                    return false, types_mod.display(ctx, a) .. " does not support #" .. mname
                end
            end
            return true
        end
    end

    -- Table types: structural subtyping
    if ta.tag == TAG_TABLE and tb.tag == TAG_TABLE then
        -- Every required field in b must exist in a
        for i = tb.data[0], tb.data[0] + tb.data[1] - 1 do
            local bfid = ctx.lists:get(i)
            local bfe = ctx.fields:get(bfid)
            local bft = find(ctx, bfe.type_id)
            local afe, afid = types_mod.table_field(ctx, a, bfe.name_id)
            if not afe then
                if bfe.optional == 0 then
                    -- Check a's indexers with string key
                    local found = false
                    local ais, ail = ta.data[2], ta.data[3]
                    local j = ais
                    while j < ais + ail - 1 do
                        local kt = find(ctx, ctx.lists:get(j))
                        if ctx.types:get(kt).tag == TAG_STRING then
                            local vt = find(ctx, ctx.lists:get(j + 1))
                            local ok = M.unify(ctx, vt, bft)
                            if ok then found = true; break end
                        end
                        j = j + 2
                    end
                    -- Open table (row var) may absorb extra fields
                    if not found and ta.data[4] >= 0 then found = true end
                    if not found then
                        local fname = intern_mod.get(ctx.pool, bfe.name_id) or "?"
                        return false, "missing field '" .. fname .. "'",
                            { kind = "missing_field", field = fname }
                    end
                end
            else
                local aft = find(ctx, afe.type_id)
                local ok, err, detail = M.unify(ctx, aft, bft)
                if not ok then
                    local fname = intern_mod.get(ctx.pool, bfe.name_id) or "?"
                    local d = detail or { kind = "mismatch", path = {}, got = aft, expected = bft }
                    if d.kind == "mismatch" then
                        local new_path = { fname }
                        if d.path then
                            for _, p in ipairs(d.path) do new_path[#new_path + 1] = p end
                        end
                        d = { kind = "mismatch", path = new_path, got = d.got, expected = d.expected }
                    end
                    return false, "field '" .. fname .. "': " .. (err or "type mismatch"), d
                end
            end
        end

        -- Unify indexers
        for i = tb.data[2], tb.data[2] + tb.data[3] - 1, 2 do
            local bk = find(ctx, ctx.lists:get(i))
            local bv = find(ctx, ctx.lists:get(i + 1))
            local matched = false
            local ais, ail = ta.data[2], ta.data[3]
            local j = ais
            while j < ais + ail - 1 do
                local ak = find(ctx, ctx.lists:get(j))
                if M.unify(ctx, ak, bk) then
                    local av = find(ctx, ctx.lists:get(j + 1))
                    local ok, err = M.unify(ctx, av, bv)
                    if not ok then
                        return false, "indexer value: " .. (err or "type mismatch")
                    end
                    matched = true
                    break
                end
                j = j + 2
            end
            if not matched then
                if ta.data[1] == 0 and ta.data[3] == 0 then
                    -- Empty table absorbs indexers
                    -- Can't add to immutable arena; treat as ok for empty tables
                    matched = true
                else
                    -- Cat C: positional table `{T, U}` vs `{[number]: T}`.
                    -- When b expects a numeric indexer and a has sequential integer-named
                    -- fields ("1", "2", ...), unify each positional value with the indexer
                    -- value type instead of reporting "missing indexer".
                    local bkt = ctx.types:get(bk)
                    if bkt.tag == TAG_NUMBER or bkt.tag == TAG_INTEGER then
                        for fi = ta.data[0], ta.data[0] + ta.data[1] - 1 do
                            local afe = ctx.fields:get(ctx.lists:get(fi))
                            local fname = intern_mod.get(ctx.pool, afe.name_id)
                            if fname and fname:match("^%d+$") then
                                local av = find(ctx, afe.type_id)
                                local ok, err = M.unify(ctx, av, bv)
                                if not ok then
                                    return false, "positional element " .. fname .. ": " .. (err or "type mismatch")
                                end
                                matched = true
                            end
                        end
                    end
                    if not matched and bkt.tag ~= TAG_STRING then
                        if ta.data[4] < 0 then  -- no row var
                            return false, "missing indexer for " .. types_mod.display(ctx, bk)
                        end
                    end
                end
            end
        end

        -- Check meta fields
        for i = tb.data[5], tb.data[5] + tb.data[6] - 1 do
            local bfid = ctx.lists:get(i)
            local bfe = ctx.fields:get(bfid)
            local amf = types_mod.table_meta_field(ctx, a, bfe.name_id)
            if not amf then
                if bfe.optional == 0 then
                    local mname = intern_mod.get(ctx.pool, bfe.name_id) or "?"
                    return false, "missing metatable slot '#" .. mname .. "'"
                end
            else
                local ok, err = M.unify(ctx, find(ctx, amf.type_id), find(ctx, bfe.type_id))
                if not ok then
                    local mname = intern_mod.get(ctx.pool, bfe.name_id) or "?"
                    return false, "#" .. mname .. ": " .. (err or "type mismatch")
                end
            end
        end
        return true
    end

    -- Tuple types
    if ta.tag == TAG_TUPLE and tb.tag == TAG_TUPLE then
        if ta.data[1] ~= tb.data[1] then
            return false, "tuple length mismatch: " .. ta.data[1] .. " vs " .. tb.data[1]
        end
        for i = 0, ta.data[1] - 1 do
            local ae = find(ctx, ctx.lists:get(ta.data[0] + i))
            local be = find(ctx, ctx.lists:get(tb.data[0] + i))
            local ok, err = M.unify(ctx, ae, be)
            if not ok then
                return false, "tuple element " .. (i + 1) .. ": " .. (err or "type mismatch")
            end
        end
        return true
    end

    if ta.tag == TAG_TUPLE and tb.tag == TAG_TABLE then
        return false, "tuple is not assignable to table/array"
    end
    if ta.tag == TAG_TABLE and tb.tag == TAG_TUPLE then
        return false, "table/array is not assignable to tuple"
    end

    -- cdata
    if ta.tag == TAG_CDATA or tb.tag == TAG_CDATA then return true end

    return false,
        "cannot assign '" .. types_mod.display(ctx, a) .. "' to '" .. types_mod.display(ctx, b) .. "'",
        { kind = "mismatch", path = {}, got = a, expected = b }
end

-- Read-only unification: checks assignability without mutating type variables.
-- Returns ok (boolean). Does not bind type variables.
function M.try_unify(ctx, a, b)
    a = find(ctx, a)
    b = find(ctx, b)

    local ta = ctx.types:get(a)
    local tb = ctx.types:get(b)

    if ta.tag == TAG_ANY or tb.tag == TAG_ANY then return true end
    if ta.tag == TAG_NEVER then return true end
    if ta.tag == TAG_VAR or tb.tag == TAG_VAR then return true end
    if ta.tag == TAG_NAMED or tb.tag == TAG_NAMED then return true end

    -- Union LHS: all members must be assignable to b.
    if ta.tag == TAG_UNION then
        for i = ta.data[0], ta.data[0] + ta.data[1] - 1 do
            if not M.try_unify(ctx, ctx.lists:get(i), b) then return false end
        end
        return true
    end

    if ta.tag == tb.tag and is_primitive_tag(ta.tag) then return true end

    if ta.tag == TAG_INTEGER and tb.tag == TAG_NUMBER then return true end

    if ta.tag == TAG_LITERAL then
        if tb.tag == TAG_LITERAL and ta.data[0] == tb.data[0] and ta.data[1] == tb.data[1] then
            return true
        end
        local kind = ta.data[0]
        if kind == LIT_STRING  and tb.tag == TAG_STRING  then return true end
        if kind == LIT_NUMBER  and tb.tag == TAG_NUMBER  then return true end
        if kind == LIT_BOOLEAN and tb.tag == TAG_BOOLEAN then return true end
    end

    if tb.tag == TAG_UNION then
        for i = tb.data[0], tb.data[0] + tb.data[1] - 1 do
            if M.try_unify(ctx, a, ctx.lists:get(i)) then return true end
        end
        return false
    end

    if ta.tag == TAG_FUNCTION and tb.tag == TAG_FUNCTION then
        local apl, bpl = ta.data[1], tb.data[1]
        local max_p = apl > bpl and apl or bpl
        for i = 0, max_p - 1 do
            local ap = i < apl and find(ctx, ctx.lists:get(ta.data[0] + i)) or ctx.T_NIL
            local bp = i < bpl and find(ctx, ctx.lists:get(tb.data[0] + i)) or ctx.T_NIL
            if not M.try_unify(ctx, bp, ap) then return false end
        end
        return true
    end

    if ta.tag == TAG_TABLE and tb.tag == TAG_TABLE then
        for i = tb.data[0], tb.data[0] + tb.data[1] - 1 do
            local bfe = ctx.fields:get(ctx.lists:get(i))
            local afe = types_mod.table_field(ctx, a, bfe.name_id)
            if not afe and bfe.optional == 0 then return false end
            if afe then
                if not M.try_unify(ctx, find(ctx, afe.type_id), find(ctx, bfe.type_id)) then
                    return false
                end
            end
        end
        return true
    end

    if ta.tag == TAG_NOMINAL and tb.tag == TAG_NOMINAL then
        return ta.data[1] == tb.data[1]
    end

    return false
end

-- Expose the private is_primitive_tag for use in infer.lua
function M.is_primitive_tag(tag)
    return tag == TAG_NIL or tag == TAG_BOOLEAN or tag == TAG_NUMBER
        or tag == TAG_INTEGER or tag == TAG_STRING
end

return M
