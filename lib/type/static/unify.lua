-- lib/type/static/unify.lua
-- HM unification extended for structural types.
-- Ports v1 unify.lua to work with flat TypeSlot arenas.

local defs = require("lib.type.static.defs")
local types_mod = require("lib.type.static.types")
local intern_mod = require("lib.type.static.intern")

local TAG_NIL          = defs.TAG_NIL
local TAG_BOOLEAN      = defs.TAG_BOOLEAN
local TAG_NUMBER       = defs.TAG_NUMBER
local TAG_STRING       = defs.TAG_STRING
local TAG_ANY          = defs.TAG_ANY
local TAG_NEVER        = defs.TAG_NEVER
local TAG_INTEGER      = defs.TAG_INTEGER
local TAG_UNKNOWN      = defs.TAG_UNKNOWN
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
local TAG_ENUM_MEMBER  = defs.TAG_ENUM_MEMBER

local LIT_STRING  = defs.LIT_STRING
local LIT_NUMBER  = defs.LIT_NUMBER
local LIT_BOOLEAN = defs.LIT_BOOLEAN
local LIT_INTEGER = defs.LIT_INTEGER

local FLAG_OPTIONAL  = defs.FLAG_OPTIONAL
local FLAG_READONLY  = defs.FLAG_READONLY
local FLAG_OPAQUE_KEY = defs.FLAG_OPAQUE_KEY
local FLAG_SKOLEM    = defs.FLAG_SKOLEM
local band = require("bit").band

-- Meta ops supported natively by primitive types
local M = {}
local find = types_mod.find

-- Occurs check: does the var at `var_tid` (after find) appear in type `tid`?
-- var_tid must be the root of a TAG_VAR or TAG_ROWVAR.
-- seen: set of already-visited type IDs to break cycles (recursive/self-referential types).
--: (ctx: Ctx, var_tid: integer, tid: integer, seen: { [integer]: boolean, ... } | nil) -> boolean
local function occurs(ctx, var_tid, tid, seen)
    tid = find(ctx, tid)
    if tid == var_tid then return true end
    if seen and seen[tid] then return false end

    local t = ctx.types:get(tid)
    local tag = t.tag

    if tag == TAG_FUNCTION then
        seen = seen or {}; seen[tid] = true
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            if occurs(ctx, var_tid, ctx.lists:get(i), seen) then return true end
        end
        for i = t.data[2], t.data[2] + t.data[3] - 1 do
            if occurs(ctx, var_tid, ctx.lists:get(i), seen) then return true end
        end
        if t.data[4] >= 0 then
            if occurs(ctx, var_tid, t.data[4], seen) then return true end
        end
        return false
    end

    if tag == TAG_TABLE then
        seen = seen or {}; seen[tid] = true
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            local fe = ctx.fields:get(ctx.lists:get(i))
            if occurs(ctx, var_tid, fe.type_id, seen) then return true end
        end
        local is, il = t.data[2], t.data[3]
        for i = is, is + il - 1 do
            if occurs(ctx, var_tid, ctx.lists:get(i), seen) then return true end
        end
        for i = t.data[5], t.data[5] + t.data[6] - 1 do
            local fe = ctx.fields:get(ctx.lists:get(i))
            if occurs(ctx, var_tid, fe.type_id, seen) then return true end
        end
        return false
    end

    if tag == TAG_UNION or tag == TAG_INTERSECTION or tag == TAG_TUPLE then
        seen = seen or {}; seen[tid] = true
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            if occurs(ctx, var_tid, ctx.lists:get(i), seen) then return true end
        end
        return false
    end

    if tag == TAG_SPREAD then
        return occurs(ctx, var_tid, t.data[0], seen or {})
    end

    return false
end

-- Adjust levels: lower the level of free vars in `tid` to max_level.
--: (ctx: Ctx, tid: integer, max_level: integer, seen: { [integer]: boolean, ... } | nil) -> ()
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
--: (ctx: Ctx, var_tid: integer, target_tid: integer) -> (boolean, string | nil)
local function bind_var(ctx, var_tid, target_tid)
    -- Skolem variables must never be bound: they represent abstract generic type
    -- parameters at definition time.  If binding would occur, it means the body
    -- produced a concrete type that cannot unify with the abstract parameter.
    local vt_check = ctx.types:get(var_tid)
    if band(vt_check.flags, FLAG_SKOLEM) ~= 0 then
        local intern_mod2 = require("lib.type.static.intern")
        local var_name = intern_mod2.get(ctx.pool, vt_check.data[3]) or ("$sk" .. tostring(vt_check.data[0]))
        local target_str = types_mod.display(ctx, target_tid)
        return false, "type parameter `" .. var_name .. "` is abstract (skolem) — body produces `" .. target_str .. "` which cannot unify with an abstract type parameter"
    end
    -- var_tid is already find()'d to root
    if occurs(ctx, var_tid, target_tid) then
        -- Special case: `x = x or default` → union containing var itself.
        -- Strip var out of the union.
        local target_root = find(ctx, target_tid)
        local tt = ctx.types:get(target_root)
        if tt.tag == TAG_UNION then
            --: { [integer]: integer, ... }
            local filtered = {}
            for i = tt.data[0], tt.data[0] + tt.data[1] - 1 do
                local mid = find(ctx, ctx.lists:get(i))
                if mid ~= var_tid then
                    filtered[#filtered + 1] = mid
                end
            end
            if #filtered < tt.data[1] then
                --: integer
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
--: (ctx: Ctx, name: string) -> integer
local function meta_intern_id(ctx, name)
    return intern_mod.intern(ctx.pool, name)
end

-- Shallow copy of a 2D seen table.
-- Used before disjunctive iterations (union RHS, intersection LHS) so that
-- entries set by a failed alternative don't contaminate subsequent alternatives.
-- Each branch inherits the parent's cycle-guard entries (the current proof path)
-- but sibling branches cannot see each other's entries.
local function copy_seen(s)
    local c = {}
    for k, v in pairs(s) do
        local iv = {}
        if v then for k2 in pairs(v) do iv[k2] = true end end
        c[k] = iv
    end
    return c
end

-- unify(ctx, a, b): check if a is assignable to b, binding vars as needed.
-- Returns true, or false + error_message [+ detail_table]
-- seen: coinductive cycle guard — pair already being unified returns true immediately.
--: (ctx: Ctx, a: integer, b: integer, seen: { [integer]: { [integer]: boolean } | nil } | nil) -> (boolean, string | nil, UnifyDetail | nil)
function M.unify(ctx, a, b, seen)
    a = find(ctx, a)
    b = find(ctx, b)

    -- Coinductive cycle detection: if we're already unifying (a,b) in this chain,
    -- assume compatible. Handles recursive/mutually-referential table types (typeclasses, etc).
    seen = seen or {}
    if seen[a] and seen[a][b] then return true end
    seen[a] = seen[a] or {}
    seen[a][b] = true

    -- Named types (unresolved): treat as any
    if ctx.types:get(a).tag == TAG_NAMED then return true end
    if ctx.types:get(b).tag == TAG_NAMED then return true end

    -- Same type_id
    if a == b then return true end

    local ta = ctx.types:get(a)
    local tb = ctx.types:get(b)

    -- any is bilateral.
    -- When one side is TAG_ANY and the other is a free type variable (TAG_VAR/TAG_ROWVAR),
    -- bind the var to TAG_ANY so all future unifications with that var also see TAG_ANY.
    -- Without this, the var stays unbound and the next concrete assignment binds it to a
    -- specific type, causing later assignments of different types to fail (Box<any> bug).
    if ta.tag == TAG_ANY then
        if tb.tag == TAG_VAR or tb.tag == TAG_ROWVAR then bind_var(ctx, b, a) end
        return true
    end
    if tb.tag == TAG_ANY then
        if ta.tag == TAG_VAR or ta.tag == TAG_ROWVAR then bind_var(ctx, a, b) end
        return true
    end

    -- unknown: top type — everything is assignable to unknown (T <: unknown),
    -- but unknown is not assignable to a specific type (unknown <: T fails, must narrow).
    -- When the target is unknown and the actual is a free type var, bind the var to unknown:
    -- this prevents subsequent constraints (e.g. C_SUB from an annotated assignment) from
    -- narrowing the var to a more specific type, which would silently lose the unknown signal.
    if tb.tag == TAG_UNKNOWN then
        if ta.tag == TAG_VAR or ta.tag == TAG_ROWVAR then bind_var(ctx, a, b) end
        return true
    end
    if ta.tag == TAG_UNKNOWN then
        -- When the expected type is a free type variable, bind it to unknown (e.g. function
        -- parameter with no annotation used as a callback argument of type unknown). This
        -- arises in contravariant param checks: unify(actual_param=unknown, expected_param=VAR).
        -- The free param should accept unknown values — bind it so future uses see unknown.
        if tb.tag == TAG_VAR or tb.tag == TAG_ROWVAR then bind_var(ctx, b, a) return true end
        return false, "value of type `unknown` must be narrowed before use (got unknown, expected `" .. types_mod.display(ctx, b) .. "`)"
    end

    -- never is bottom
    if ta.tag == TAG_NEVER then return true end

    -- Type variable binding (TAG_ROWVAR is treated the same as TAG_VAR for binding)
    if ta.tag == TAG_VAR or ta.tag == TAG_ROWVAR then
        local ok, msg = bind_var(ctx, a, b)
        return ok, msg
    end
    if tb.tag == TAG_VAR or tb.tag == TAG_ROWVAR then
        local ok, msg = bind_var(ctx, b, a)
        return ok, msg
    end

    -- Nominal types: identity-based
    if ta.tag == TAG_NOMINAL and tb.tag == TAG_NOMINAL then
        if ta.data[1] == tb.data[1] then return true end
        local na = intern_mod.get(ctx.pool, ta.data[0]) or "?"
        local nb = intern_mod.get(ctx.pool, tb.data[0]) or "?"
        return false, "nominal type `" .. na .. "` is not `" .. nb .. "`"
    end
    if ta.tag == TAG_NOMINAL then
        local na = intern_mod.get(ctx.pool, ta.data[0]) or "?"
        return false, "nominal type `" .. na .. "` is not assignable to `" .. types_mod.display(ctx, b) .. "`"
    end
    if tb.tag == TAG_NOMINAL then
        local nb = intern_mod.get(ctx.pool, tb.data[0]) or "?"
        return false, "`" .. types_mod.display(ctx, a) .. "` is not assignable to nominal type `" .. nb .. "`"
    end

    -- integer <: number (every integer is a number; not the reverse)
    if ta.tag == TAG_INTEGER and tb.tag == TAG_NUMBER then return true end

    -- Enum member identity and subtyping
    if ta.tag == TAG_ENUM_MEMBER then
        -- same enum + same member = equal
        if tb.tag == TAG_ENUM_MEMBER then
            if ta.data[0] == tb.data[0] and ta.data[1] == tb.data[1] then return true end
            return false, types_mod.display(ctx, a) .. " is not " .. types_mod.display(ctx, b)
        end
        -- enum member <: its base primitive type
        local kind = ta.data[2]
        if kind == LIT_INTEGER then
            if tb.tag == TAG_INTEGER then return true end
            if tb.tag == TAG_NUMBER  then return true end
        end
        if kind == LIT_STRING and tb.tag == TAG_STRING then return true end
        -- enum member <: matching literal (same kind and value)
        if tb.tag == TAG_LITERAL and tb.data[0] == kind and tb.data[1] == ta.data[3] then
            return true
        end
    end

    -- Literal <: base type
    if ta.tag == TAG_LITERAL then
        if tb.tag == TAG_LITERAL then
            if ta.data[0] == tb.data[0] and ta.data[1] == tb.data[1]
              and (ta.data[0] ~= LIT_NUMBER or ta.data[2] == tb.data[2]) then return true end
            return false, "`" .. types_mod.display(ctx, a) .. "` is not `" .. types_mod.display(ctx, b) .. "`"
        end
        local kind = ta.data[0]
        if (kind == LIT_STRING  and tb.tag == TAG_STRING)  then return true end
        if (kind == LIT_NUMBER  and tb.tag == TAG_NUMBER)  then return true end
        if (kind == LIT_BOOLEAN and tb.tag == TAG_BOOLEAN) then return true end
        if  kind == LIT_INTEGER then
            if tb.tag == TAG_INTEGER then return true end
            if tb.tag == TAG_NUMBER  then return true end  -- integer <: number
        end
    end

    -- Same primitive tags
    if ta.tag == tb.tag and is_primitive_tag(ta.tag) then return true end

    -- Union on LHS: each member must be assignable to RHS
    if ta.tag == TAG_UNION then
        for i = ta.data[0], ta.data[0] + ta.data[1] - 1 do
            local mid = find(ctx, ctx.lists:get(i))
            local ok, err = M.unify(ctx, mid, b, seen)
            if not ok then
                return false, "`" .. types_mod.display(ctx, mid) .. "` in union is not assignable to `" .. types_mod.display(ctx, b) .. "`"
            end
        end
        return true
    end

    -- Intersection on LHS: at least one member satisfies RHS.
    -- This block handles all composite RHS cases too, so the standalone union/intersection-on-RHS
    -- checks below only fire when ta is NOT an intersection.
    -- Use copy_seen for each alternative.
    if ta.tag == TAG_INTERSECTION then
        -- Step 1: any single member of the intersection satisfies b?
        -- This correctly handles (A & (B|C)) <: (B|C) by checking (B|C) member against union b.
        for i = ta.data[0], ta.data[0] + ta.data[1] - 1 do
            local ok = M.unify(ctx, ctx.lists:get(i), b, copy_seen(seen))
            if ok then return true end
        end
        -- Step 2: dispatch on b's structure for cases no single member covers.
        if tb.tag == TAG_UNION then
            -- Try the full intersection against each union member (e.g. merged-fields vs TABLE member).
            local best_detail, best_depth = nil, -1
            for i = tb.data[0], tb.data[0] + tb.data[1] - 1 do
                local mid = find(ctx, ctx.lists:get(i))
                local ok2, _, detail = M.unify(ctx, a, mid, copy_seen(seen))
                if ok2 then return true end
                --: UnifyDetail | nil
                local det = detail
                if det and det.kind == "mismatch" then
                    local depth = det.path and #det.path or 0
                    if depth > best_depth then
                        best_detail = detail
                        best_depth = depth
                    end
                end
            end
            return false, "`" .. types_mod.display(ctx, a) .. "` is not assignable to `" .. types_mod.display(ctx, b) .. "`",
                best_detail
        end
        if tb.tag == TAG_INTERSECTION then
            -- LHS must satisfy ALL RHS members (conjunction).
            for i = tb.data[0], tb.data[0] + tb.data[1] - 1 do
                local ok2, err = M.unify(ctx, a, ctx.lists:get(i), seen)
                if not ok2 then return false, err end
            end
            return true
        end
        -- Merged-fields fallback: {f:T} & {g:U} <: {f:T, g:U}
        -- For each required field in b, at least one intersection member must cover it.
        if tb.tag == TAG_TABLE then
            local all_covered = true
            for i = tb.data[0], tb.data[0] + tb.data[1] - 1 do
                local bfe = ctx.fields:get(ctx.lists:get(i))
                if band(bfe.flags, FLAG_OPTIONAL) == 0 then
                    local found = false
                    for j = ta.data[0], ta.data[0] + ta.data[1] - 1 do
                        local mid = find(ctx, ctx.lists:get(j))
                        local mfe = types_mod.table_field(ctx, mid, bfe.name_id)
                        if mfe then
                            local ok2 = M.unify(ctx, find(ctx, mfe.type_id), find(ctx, bfe.type_id), seen)
                            if ok2 then found = true; break end
                        end
                    end
                    if not found then all_covered = false; break end
                end
            end
            if all_covered then return true end
        end
        return false, "`" .. types_mod.display(ctx, a) .. "` is not assignable to `" .. types_mod.display(ctx, b) .. "`"
    end

    -- Union on RHS: LHS must be assignable to at least one member.
    -- (Only reached when ta is NOT an intersection.)
    -- Use copy_seen for each alternative: failed branches must not contaminate siblings.
    if tb.tag == TAG_UNION then
        local best_detail, best_depth = nil, -1
        for i = tb.data[0], tb.data[0] + tb.data[1] - 1 do
            local mid = find(ctx, ctx.lists:get(i))
            local ok, _, detail = M.unify(ctx, a, mid, copy_seen(seen))
            if ok then return true end
            --: UnifyDetail | nil
            local det = detail
            if det and det.kind == "mismatch" then
                local depth = det.path and #det.path or 0
                if depth > best_depth then
                    best_detail = detail
                    best_depth = depth
                end
            end
        end
        return false, "`" .. types_mod.display(ctx, a) .. "` is not assignable to `" .. types_mod.display(ctx, b) .. "`",
            best_detail
    end

    -- Intersection on RHS: LHS must satisfy all members.
    -- (Only reached when ta is NOT an intersection.)
    if tb.tag == TAG_INTERSECTION then
        for i = tb.data[0], tb.data[0] + tb.data[1] - 1 do
            local ok, err = M.unify(ctx, a, ctx.lists:get(i), seen)
            if not ok then return false, err end
        end
        return true
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
            local ok, err = M.unify(ctx, bp_id, ap_id, seen)
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
            local ok, err = M.unify(ctx, ar_id, br_id, seen)
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
            if ta.data[0] == LIT_NUMBER   then ptag = TAG_NUMBER
            elseif ta.data[0] == LIT_INTEGER then ptag = TAG_INTEGER
            elseif ta.data[0] == LIT_STRING  then ptag = TAG_STRING
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
            -- Handle spread fields { ...T, ... }: expand the inner table's
            -- fields and check each one against a, as if they were direct fields.
            if bfe.name_id == -1 then
                local spread_t = ctx.types:get(bft)
                if spread_t.tag == TAG_SPREAD then
                    local inner_tid = find(ctx, spread_t.data[0])
                    local inner_t = ctx.types:get(inner_tid)
                    if inner_t.tag == TAG_TABLE then
                        for j = inner_t.data[0], inner_t.data[0] + inner_t.data[1] - 1 do
                            local jfid = ctx.lists:get(j)
                            local jfe  = ctx.fields:get(jfid)
                            if jfe.name_id == -1 then goto spread_next end
                            local jft  = find(ctx, jfe.type_id)
                            local afe2 = types_mod.table_field(ctx, a, jfe.name_id)
                            if not afe2 then
                                if band(jfe.flags, FLAG_OPTIONAL) == 0 then
                                    local ais, ail = ta.data[2], ta.data[3]
                                    local found = false
                                    local k = ais
                                    while k < ais + ail - 1 do
                                        local kt = find(ctx, ctx.lists:get(k))
                                        if ctx.types:get(kt).tag == TAG_STRING then
                                            local vt = find(ctx, ctx.lists:get(k + 1))
                                            if M.unify(ctx, vt, jft, seen) then
                                                found = true; break
                                            end
                                        end
                                        k = k + 2
                                    end
                                    if not found and ta.data[4] >= 0 then found = true end
                                    if not found then
                                        local fname = intern_mod.get(ctx.pool, jfe.name_id) or "?"
                                        return false,
                                            "missing field `" .. fname .. "` (from spread)",
                                            { kind = "missing_field", field = fname }
                                    end
                                end
                            else
                                local aft = find(ctx, afe2.type_id)
                                local ok2, err2 = M.unify(ctx, aft, jft, seen)
                                if not ok2 then
                                    local fname = intern_mod.get(ctx.pool, jfe.name_id) or "?"
                                    return false,
                                        "field `" .. fname .. "` (from spread): " .. (err2 or "type mismatch")
                                end
                            end
                            ::spread_next::
                        end
                    end
                    -- inner type not a concrete table: conservatively pass
                end
                goto continue
            end
            local afe, afid = types_mod.table_field(ctx, a, bfe.name_id)
            if not afe then
                if band(bfe.flags, FLAG_OPTIONAL) == 0 then
                    -- Check a's indexers with string key
                    local found = false
                    local ais, ail = ta.data[2], ta.data[3]
                    local j = ais
                    while j < ais + ail - 1 do
                        local kt = find(ctx, ctx.lists:get(j))
                        if ctx.types:get(kt).tag == TAG_STRING then
                            local vt = find(ctx, ctx.lists:get(j + 1))
                            local ok = M.unify(ctx, vt, bft, seen)
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
                -- If target field is required but source field is optional, reject:
                -- { x?: T } is not a subtype of { x: T }
                if band(bfe.flags, FLAG_OPTIONAL) == 0 and band(afe.flags, FLAG_OPTIONAL) ~= 0 then
                    local fname = intern_mod.get(ctx.pool, bfe.name_id) or "?"
                    return false, "field '" .. fname .. "': optional field cannot satisfy required field",
                        { kind = "mismatch", path = { fname },
                          got = "optional field", expected = "required field" }
                end
                local aft = find(ctx, afe.type_id)
                local ok, err, detail = M.unify(ctx, aft, bft, seen)
                if not ok then
                    local fname = intern_mod.get(ctx.pool, bfe.name_id) or "?"
                    --: UnifyDetail | nil
                    local d = detail
                    if d and d.kind == "mismatch" then
                        local new_path = { fname }
                        if d.path then
                            for _, p in ipairs(d.path) do new_path[#new_path + 1] = p end
                        end
                        d = { kind = "mismatch", path = new_path, got = d.got, expected = d.expected }
                    end
                    return false, "field '" .. fname .. "': " .. (err or "type mismatch"), d
                end
            end
            ::continue::
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
                if M.unify(ctx, ak, bk, seen) then
                    local av = find(ctx, ctx.lists:get(j + 1))
                    local ok, err = M.unify(ctx, av, bv, seen)
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
                                local ok, err = M.unify(ctx, av, bv, seen)
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
                if band(bfe.flags, FLAG_OPTIONAL) == 0 then
                    local mname = intern_mod.get(ctx.pool, bfe.name_id) or "?"
                    return false, "missing metatable slot '#" .. mname .. "'"
                end
            else
                local ok, err = M.unify(ctx, find(ctx, amf.type_id), find(ctx, bfe.type_id), seen)
                if not ok then
                    local mname = intern_mod.get(ctx.pool, bfe.name_id) or "?"
                    return false, "#" .. mname .. ": " .. (err or "type mismatch")
                end
            end
        end

        -- Excess-field check: if the target is closed (no row var) and the source
        -- is also closed, every field in the source must exist in the target.
        -- Width subtyping ({x,y} <: {x}) only holds when the target is open ({x,...}).
        if tb.data[4] < 0 and ta.data[4] < 0 then
            for i = ta.data[0], ta.data[0] + ta.data[1] - 1 do
                local afid = ctx.lists:get(i)
                local afe  = ctx.fields:get(afid)
                if band(afe.flags, FLAG_OPAQUE_KEY) == 0 then
                    local bfe_match = types_mod.table_field(ctx, b, afe.name_id)
                    if not bfe_match then
                        -- Before rejecting as excess, check if tb has an indexer that
                        -- covers this field's key type. A numeric-named field ("1","2"...)
                        -- is covered by a number/integer indexer; any named field is covered
                        -- by a string indexer. Also verify the value type is assignable.
                        local fname = intern_mod.get(ctx.pool, afe.name_id) or "?"
                        local covered = false
                        local bis, bil = tb.data[2], tb.data[3]
                        local j = bis
                        while j < bis + bil - 1 do
                            local bkt = ctx.types:get(find(ctx, ctx.lists:get(j)))
                            local is_numeric_key = fname:match("^%d+$")
                            local key_ok = false
                            if is_numeric_key and (bkt.tag == TAG_NUMBER or bkt.tag == TAG_INTEGER) then
                                key_ok = true
                            elseif not is_numeric_key and bkt.tag == TAG_STRING then
                                key_ok = true
                            end
                            if key_ok then
                                local bv = find(ctx, ctx.lists:get(j + 1))
                                local av = find(ctx, afe.type_id)
                                local ok2, err2 = M.unify(ctx, av, bv, seen)
                                if ok2 then
                                    covered = true; break
                                else
                                    return false, "field '" .. fname .. "': " .. (err2 or "type mismatch")
                                end
                            end
                            j = j + 2
                        end
                        if not covered then
                            return false, "excess field '" .. fname .. "' not in target type"
                        end
                    end
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
            local ok, err = M.unify(ctx, ae, be, seen)
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
        "cannot assign `" .. types_mod.display(ctx, a) .. "` to `" .. types_mod.display(ctx, b) .. "`",
        { kind = "mismatch", path = {}, got = a, expected = b }
end

-- Read-only unification: checks assignability without mutating type variables.
-- Returns ok (boolean). Does not bind type variables.
-- seen: coinductive cycle guard (same semantics as M.unify).
--: (ctx: Ctx, a: integer, b: integer, seen: { [integer]: { [integer]: boolean } | nil } | nil) -> boolean
function M.try_unify(ctx, a, b, seen)
    a = find(ctx, a)
    b = find(ctx, b)

    -- Coinductive cycle detection
    seen = seen or {}
    if seen[a] and seen[a][b] then return true end
    seen[a] = seen[a] or {}
    seen[a][b] = true

    local ta = ctx.types:get(a)
    local tb = ctx.types:get(b)

    -- Same type ID: trivially reflexive.
    if a == b then return true end

    if ta.tag == TAG_ANY or tb.tag == TAG_ANY then return true end
    if tb.tag == TAG_UNKNOWN then return true end
    if ta.tag == TAG_UNKNOWN then return false end
    if ta.tag == TAG_NEVER then return true end
    -- TAG_VAR/TAG_ROWVAR on RHS (expected type is a free var): accept any actual — this covers
    -- generic-param instantiation, where exp_tid is a freshly-created unbound var.
    -- TAG_ROWVAR on LHS (actual is a row extension): accept for structural/open-table matching.
    -- TAG_VAR on LHS (actual is a free unbound var): return false — we cannot confirm that an
    -- unknown type is compatible with the expected type (soundness-audit.md Gap 1).
    if tb.tag == TAG_VAR or tb.tag == TAG_ROWVAR then return true end
    if ta.tag == TAG_ROWVAR then return true end
    -- TAG_NAMED oracle: when both sides are named aliases, check declared_subtypes
    -- before falling back to structural comparison (which would just return true).
    if ta.tag == TAG_NAMED and tb.tag == TAG_NAMED then
        local a_name = ta.data[0]
        local b_name = tb.data[0]
        -- Same alias: trivially subtype.
        if a_name == b_name then return true end
        -- Oracle lookup: is (a_name, b_name) a declared subtype pair?
        local ds = ctx.declared_subtypes
        if ds and ds[a_name] == b_name then
            -- Args check: if actual and expected both have args, each must unify.
            local a_al = ta.data[2]  -- args len (0 for non-generic checker-arena nodes)
            local b_al = tb.data[2]
            if a_al == 0 and b_al == 0 then
                return true  -- non-generic oracle hit
            end
            if a_al == b_al then
                for i = 0, a_al - 1 do
                    local aa = ctx.lists:get(ta.data[1] + i)
                    local ba = ctx.lists:get(tb.data[1] + i)
                    if not M.try_unify(ctx, aa, ba, seen) then return false end
                end
                return true
            end
            -- Arg count mismatch: fall through (structural will return true anyway)
        end
        -- No oracle hit: keep original blanket-pass for unresolved named placeholders.
        return true
    end
    if ta.tag == TAG_NAMED or tb.tag == TAG_NAMED then return true end

    -- Union LHS: all members must be assignable to b.
    if ta.tag == TAG_UNION then
        for i = ta.data[0], ta.data[0] + ta.data[1] - 1 do
            if not M.try_unify(ctx, ctx.lists:get(i), b, seen) then return false end
        end
        return true
    end

    if ta.tag == tb.tag and is_primitive_tag(ta.tag) then return true end

    if ta.tag == TAG_INTEGER and tb.tag == TAG_NUMBER then return true end

    if ta.tag == TAG_ENUM_MEMBER then
        if tb.tag == TAG_ENUM_MEMBER then
            if ta.data[0] == tb.data[0] and ta.data[1] == tb.data[1] then return true end
            return false
        end
        local kind = ta.data[2]
        if kind == LIT_INTEGER then
            if tb.tag == TAG_INTEGER then return true end
            if tb.tag == TAG_NUMBER  then return true end
        end
        if kind == LIT_STRING and tb.tag == TAG_STRING then return true end
        if tb.tag == TAG_LITERAL and tb.data[0] == kind and tb.data[1] == ta.data[3] then
            return true
        end
        return false
    end

    if ta.tag == TAG_LITERAL then
        if tb.tag == TAG_LITERAL and ta.data[0] == tb.data[0] and ta.data[1] == tb.data[1]
          and (ta.data[0] ~= LIT_NUMBER or ta.data[2] == tb.data[2]) then
            return true
        end
        local kind = ta.data[0]
        if kind == LIT_STRING  and tb.tag == TAG_STRING  then return true end
        if kind == LIT_NUMBER  and tb.tag == TAG_NUMBER  then return true end
        if kind == LIT_BOOLEAN and tb.tag == TAG_BOOLEAN then return true end
        if kind == LIT_INTEGER then
            if tb.tag == TAG_INTEGER then return true end
            if tb.tag == TAG_NUMBER  then return true end
        end
    end

    -- Intersection on LHS: satisfies b if ANY member satisfies b (disjunctive — copy seen).
    -- This block handles all composite RHS cases too, so the standalone union/intersection-on-RHS
    -- checks below only fire when ta is NOT an intersection.
    if ta.tag == TAG_INTERSECTION then
        -- Step 1: any single member of the intersection satisfies b?
        -- This correctly handles (A & (B|C)) <: (B|C) by checking (B|C) member against union b.
        for i = ta.data[0], ta.data[0] + ta.data[1] - 1 do
            if M.try_unify(ctx, ctx.lists:get(i), b, copy_seen(seen)) then return true end
        end
        -- Step 2: dispatch on b's structure for cases no single member covers.
        if tb.tag == TAG_UNION then
            -- Try the full intersection against each union member (e.g. merged-fields vs TABLE member).
            for i = tb.data[0], tb.data[0] + tb.data[1] - 1 do
                if M.try_unify(ctx, a, ctx.lists:get(i), copy_seen(seen)) then return true end
            end
            return false
        end
        if tb.tag == TAG_INTERSECTION then
            -- LHS must satisfy ALL RHS members (conjunction).
            for i = tb.data[0], tb.data[0] + tb.data[1] - 1 do
                if not M.try_unify(ctx, a, ctx.lists:get(i), seen) then return false end
            end
            return true
        end
        -- Merged-fields fallback: {f:T} & {g:U} <: {f:T, g:U}
        if tb.tag == TAG_TABLE then
            local all_covered = true
            for i = tb.data[0], tb.data[0] + tb.data[1] - 1 do
                local bfe = ctx.fields:get(ctx.lists:get(i))
                if band(bfe.flags, FLAG_OPTIONAL) == 0 then
                    local found = false
                    for j = ta.data[0], ta.data[0] + ta.data[1] - 1 do
                        local mid = find(ctx, ctx.lists:get(j))
                        local mfe = types_mod.table_field(ctx, mid, bfe.name_id)
                        if mfe then
                            if M.try_unify(ctx, find(ctx, mfe.type_id), find(ctx, bfe.type_id), seen) then
                                found = true; break
                            end
                        end
                    end
                    if not found then all_covered = false; break end
                end
            end
            if all_covered then return true end
        end
        return false
    end

    -- Disjunctive: use copy_seen so failed alternatives don't contaminate siblings.
    -- (Only reached when ta is NOT an intersection.)
    if tb.tag == TAG_UNION then
        for i = tb.data[0], tb.data[0] + tb.data[1] - 1 do
            if M.try_unify(ctx, a, ctx.lists:get(i), copy_seen(seen)) then return true end
        end
        return false
    end

    -- Intersection on RHS: a must satisfy ALL members (conjunctive — shared seen is fine).
    -- (Only reached when ta is NOT an intersection.)
    if tb.tag == TAG_INTERSECTION then
        for i = tb.data[0], tb.data[0] + tb.data[1] - 1 do
            if not M.try_unify(ctx, a, ctx.lists:get(i), seen) then return false end
        end
        return true
    end

    if ta.tag == TAG_FUNCTION and tb.tag == TAG_FUNCTION then
        local apl, bpl = ta.data[1], tb.data[1]
        local max_p = apl > bpl and apl or bpl
        for i = 0, max_p - 1 do
            local ap = i < apl and find(ctx, ctx.lists:get(ta.data[0] + i)) or ctx.T_NIL
            local bp = i < bpl and find(ctx, ctx.lists:get(tb.data[0] + i)) or ctx.T_NIL
            if not M.try_unify(ctx, bp, ap, seen) then return false end
        end
        return true
    end

    if ta.tag == TAG_TABLE and tb.tag == TAG_TABLE then
        for i = tb.data[0], tb.data[0] + tb.data[1] - 1 do
            local bfe = ctx.fields:get(ctx.lists:get(i))
            local afe = types_mod.table_field(ctx, a, bfe.name_id)
            if not afe and band(bfe.flags, FLAG_OPTIONAL) == 0 then return false end
            if afe then
                -- Optional field cannot satisfy a required field
                if band(bfe.flags, FLAG_OPTIONAL) == 0 and band(afe.flags, FLAG_OPTIONAL) ~= 0 then
                    return false
                end
                if not M.try_unify(ctx, find(ctx, afe.type_id), find(ctx, bfe.type_id), seen) then
                    return false
                end
            end
        end
        -- Check meta fields: each required meta field in tb must exist in ta with compatible type
        for i = tb.data[5], tb.data[5] + tb.data[6] - 1 do
            local bfe = ctx.fields:get(ctx.lists:get(i))
            local amf = types_mod.table_meta_field(ctx, a, bfe.name_id)
            if not amf and band(bfe.flags, FLAG_OPTIONAL) == 0 then return false end
            if amf then
                if band(bfe.flags, FLAG_OPTIONAL) == 0 and band(amf.flags, FLAG_OPTIONAL) ~= 0 then
                    return false
                end
                if not M.try_unify(ctx, find(ctx, amf.type_id), find(ctx, bfe.type_id), seen) then
                    return false
                end
            end
        end
        return true
    end

    if ta.tag == TAG_NOMINAL and tb.tag == TAG_NOMINAL then
        return ta.data[1] == tb.data[1]
    end

    if ta.tag == TAG_CDATA or tb.tag == TAG_CDATA then return true end

    return false
end

-- Expose the private is_primitive_tag for external use.
function M.is_primitive_tag(tag)
    return tag == TAG_NIL or tag == TAG_BOOLEAN or tag == TAG_NUMBER
        or tag == TAG_INTEGER or tag == TAG_STRING
end

return M
