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
local TAG_TYPE_CALL    = defs.TAG_TYPE_CALL

-- Resolve a TAG_TYPE_CALL whose callee is a concrete TAG_NAMED alias and
-- whose args are all concrete (no free TVs). Returns the resolved tid or
-- the original tid if resolution isn't applicable / fails. Used at unify
-- entry to allow `Maybe<integer>` (resolved structural) to unify against
-- `TAG_TYPE_CALL(F_bound_to_Maybe, A_bound_to_integer)` once HKT
-- decomposition has bound F and A.
--: (Ctx, integer) -> integer
local function normalize_type_call(ctx, tid)
    local t = ctx.types:get(tid)
    if t.tag ~= TAG_TYPE_CALL then return tid end
    local callee_tid = types_mod.find(ctx, types_mod.tycall_callee(t))
    local ct = ctx.types:get(callee_tid)
    if ct.tag ~= TAG_NAMED then return tid end
    -- Collect args; bail if any is still a free TV.
    local args = {}
    local as, al = types_mod.tycall_args_start(t), types_mod.tycall_args_len(t)
    for i = as, as + al - 1 do
        local a_tid = types_mod.find(ctx, ctx.lists:get(i))
        local at = ctx.types:get(a_tid)
        if at.tag == TAG_VAR or at.tag == TAG_ROWVAR then return tid end
        args[#args + 1] = a_tid
    end
    local env_mod = require("lib.type.static.env")
    local resolved = env_mod.resolve_named_type(ctx, ctx.scope, types_mod.named_name_id(ct), args)
    if resolved then return resolved end
    return tid
end

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
        local ps, pl = types_mod.fn_params_start(t), types_mod.fn_params_len(t)
        for i = ps, ps + pl - 1 do
            if occurs(ctx, var_tid, ctx.lists:get(i), seen) then return true end
        end
        local rs, rl = types_mod.fn_returns_start(t), types_mod.fn_returns_len(t)
        for i = rs, rs + rl - 1 do
            if occurs(ctx, var_tid, ctx.lists:get(i), seen) then return true end
        end
        local va = types_mod.fn_vararg(t)
        if va >= 0 then
            if occurs(ctx, var_tid, va, seen) then return true end
        end
        return false
    end

    if tag == TAG_TABLE then
        seen = seen or {}; seen[tid] = true
        local fs, fl = types_mod.tbl_fields_start(t), types_mod.tbl_fields_len(t)
        for i = fs, fs + fl - 1 do
            local fe = ctx.fields:get(ctx.lists:get(i))
            if occurs(ctx, var_tid, fe.type_id, seen) then return true end
        end
        local is, il = types_mod.tbl_indexers_start(t), types_mod.tbl_indexers_len(t)
        for i = is, is + il - 1 do
            if occurs(ctx, var_tid, ctx.lists:get(i), seen) then return true end
        end
        local ms, ml = types_mod.tbl_meta_start(t), types_mod.tbl_meta_len(t)
        for i = ms, ms + ml - 1 do
            local fe = ctx.fields:get(ctx.lists:get(i))
            if occurs(ctx, var_tid, fe.type_id, seen) then return true end
        end
        return false
    end

    if tag == TAG_UNION or tag == TAG_INTERSECTION or tag == TAG_TUPLE then
        seen = seen or {}; seen[tid] = true
        local ms, ml = types_mod.agg_members_start(t), types_mod.agg_members_len(t)
        for i = ms, ms + ml - 1 do
            if occurs(ctx, var_tid, ctx.lists:get(i), seen) then return true end
        end
        return false
    end

    if tag == TAG_SPREAD then
        return occurs(ctx, var_tid, types_mod.spread_inner(t), seen or {})
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
        -- Write to data[1] (var_level); no setter exists, write direct.
        if t.data[1] > max_level then t.data[1] = max_level end
        return
    end

    seen = seen or {}
    seen[tid] = true

    if tag == TAG_FUNCTION then
        local ps, pl = types_mod.fn_params_start(t), types_mod.fn_params_len(t)
        for i = ps, ps + pl - 1 do
            adjust_levels(ctx, ctx.lists:get(i), max_level, seen)
        end
        local rs, rl = types_mod.fn_returns_start(t), types_mod.fn_returns_len(t)
        for i = rs, rs + rl - 1 do
            adjust_levels(ctx, ctx.lists:get(i), max_level, seen)
        end
        local va = types_mod.fn_vararg(t)
        if va >= 0 then
            adjust_levels(ctx, va, max_level, seen)
        end
        return
    end

    if tag == TAG_TABLE then
        local fs, fl = types_mod.tbl_fields_start(t), types_mod.tbl_fields_len(t)
        for i = fs, fs + fl - 1 do
            local fe = ctx.fields:get(ctx.lists:get(i))
            adjust_levels(ctx, fe.type_id, max_level, seen)
        end
        local is, il = types_mod.tbl_indexers_start(t), types_mod.tbl_indexers_len(t)
        for i = is, is + il - 1 do
            adjust_levels(ctx, ctx.lists:get(i), max_level, seen)
        end
        local ms, ml = types_mod.tbl_meta_start(t), types_mod.tbl_meta_len(t)
        for i = ms, ms + ml - 1 do
            local fe = ctx.fields:get(ctx.lists:get(i))
            adjust_levels(ctx, fe.type_id, max_level, seen)
        end
        return
    end

    if tag == TAG_UNION or tag == TAG_INTERSECTION or tag == TAG_TUPLE then
        local ms, ml = types_mod.agg_members_start(t), types_mod.agg_members_len(t)
        for i = ms, ms + ml - 1 do
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
        local var_name = intern_mod2.get(ctx.pool, types_mod.var_skolem_name_id(vt_check)) or ("$sk" .. tostring(types_mod.var_id(vt_check)))
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
            local ms, ml = types_mod.agg_members_start(tt), types_mod.agg_members_len(tt)
            for i = ms, ms + ml - 1 do
                local mid = find(ctx, ctx.lists:get(i))
                if mid ~= var_tid then
                    filtered[#filtered + 1] = mid
                end
            end
            if #filtered < ml then
                local new_ty = 0 --: integer
                if #filtered == 0 then
                    new_ty = ctx.T_NEVER
                elseif #filtered == 1 then
                    new_ty = filtered[1]
                else
                    new_ty = types_mod.make_union(ctx, filtered)
                end
                if not occurs(ctx, var_tid, new_ty) then
                    adjust_levels(ctx, new_ty, types_mod.var_level(ctx.types:get(var_tid)))
                    -- Write to data[2] (var parent): union-find bind, no setter.
                    ctx.types:get(var_tid).data[2] = new_ty
                    return true
                end
            end
        end
        return false, "recursive type"
    end
    local vt = ctx.types:get(var_tid)
    adjust_levels(ctx, target_tid, types_mod.var_level(vt))
    -- Write to data[2] (var parent): union-find bind, no setter.
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
-- Public access to the local bind_var. Required by solve_hkt_decompose to
-- directly bind a fresh TV to a TAG_NAMED bound alias — M.unify short-circuits
-- TAG_NAMED to true without binding.
--: (Ctx, integer, integer) -> (boolean, string | nil, { kind: string, path: { [integer]: unknown } | nil, expected?: unknown, got?: unknown, field?: string } | nil)
function M.bind_var_to_type(ctx, var_tid, target_tid)
    local ok, msg, info = bind_var(ctx, find(ctx, var_tid), target_tid)
    return ok, msg, info
end

-- Returns true, or false + error_message [+ detail_table]
-- seen: coinductive cycle guard — pair already being unified returns true immediately.
--: (ctx: Ctx, a: integer, b: integer, seen: { [integer]: { [integer]: boolean } | nil } | nil) -> (boolean, string | nil, UnifyDetail | nil)
function M.unify(ctx, a, b, seen)
    a = find(ctx, a)
    b = find(ctx, b)

    -- Resolve TAG_TYPE_CALL nodes whose callee + args are now concrete (HKT
    -- decomposition has bound them). Without this, post-decomposition slots
    -- like TAG_TYPE_CALL(F=Maybe, A=integer) remain as opaque nodes and
    -- unify treats them as a tag mismatch against the actual `Maybe<integer>`
    -- structural expansion.
    a = normalize_type_call(ctx, a)
    b = normalize_type_call(ctx, b)

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

    -- unknown <: any is rejected (Gap 11). `any` is an opt-out the user must declare on
    -- the binding, not a back-channel for laundering an `unknown` source. Use `--[[:! T]]`
    -- (force cast) to escape `unknown` without narrowing. Must precede the bilateral TAG_ANY
    -- rules below, which would otherwise accept this case.
    if ta.tag == TAG_UNKNOWN and tb.tag == TAG_ANY then
        return false, "value of type `unknown` must be narrowed before use (got unknown, expected `any`); use `--[[:! T]]` to force-cast without narrowing", nil
    end

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
        return false, "value of type `unknown` must be narrowed before use (got unknown, expected `" .. types_mod.display(ctx, b) .. "`)", nil
    end

    -- never is bottom
    if ta.tag == TAG_NEVER then return true end

    -- Type variable binding (TAG_ROWVAR is treated the same as TAG_VAR for binding).
    -- When both sides are TVs but one is a skolem and the other is a free
    -- unification var, prefer to bind the free var TO the skolem (skolems can
    -- never be bound themselves, but a free var binding to a skolem is fine —
    -- it just means "this var stands for the abstract type"). This is the
    -- rank-N positive case: a polymorphic argument's fresh TV must accept the
    -- param slot's skolem as its value.
    if ta.tag == TAG_VAR or ta.tag == TAG_ROWVAR then
        if (tb.tag == TAG_VAR or tb.tag == TAG_ROWVAR)
            and band(ta.flags, FLAG_SKOLEM) ~= 0
            and band(tb.flags, FLAG_SKOLEM) == 0 then
            local ok, msg = bind_var(ctx, b, a)
            return ok, msg, nil
        end
        local ok, msg = bind_var(ctx, a, b)
        return ok, msg, nil
    end
    if tb.tag == TAG_VAR or tb.tag == TAG_ROWVAR then
        local ok, msg = bind_var(ctx, b, a)
        return ok, msg, nil
    end

    -- Nominal types: identity-based
    if ta.tag == TAG_NOMINAL and tb.tag == TAG_NOMINAL then
        if types_mod.nom_identity(ta) == types_mod.nom_identity(tb) then return true end
        local na = intern_mod.get(ctx.pool, types_mod.nom_name_id(ta)) or "?"
        local nb = intern_mod.get(ctx.pool, types_mod.nom_name_id(tb)) or "?"
        return false, "nominal type `" .. na .. "` is not `" .. nb .. "`", nil
    end
    if ta.tag == TAG_NOMINAL then
        local na = intern_mod.get(ctx.pool, types_mod.nom_name_id(ta)) or "?"
        return false, "nominal type `" .. na .. "` is not assignable to `" .. types_mod.display(ctx, b) .. "`", nil
    end
    if tb.tag == TAG_NOMINAL then
        local nb = intern_mod.get(ctx.pool, types_mod.nom_name_id(tb)) or "?"
        return false, "`" .. types_mod.display(ctx, a) .. "` is not assignable to nominal type `" .. nb .. "`", nil
    end

    -- integer <: number (every integer is a number; not the reverse)
    if ta.tag == TAG_INTEGER and tb.tag == TAG_NUMBER then return true end

    -- Enum member identity and subtyping
    if ta.tag == TAG_ENUM_MEMBER then
        -- same enum + same member = equal
        if tb.tag == TAG_ENUM_MEMBER then
            if types_mod.enum_name_id(ta) == types_mod.enum_name_id(tb)
                and types_mod.enum_member_id(ta) == types_mod.enum_member_id(tb) then return true end
            return false, types_mod.display(ctx, a) .. " is not " .. types_mod.display(ctx, b), nil
        end
        -- enum member <: its base primitive type
        local kind = types_mod.enum_lit_kind(ta)
        if kind == LIT_INTEGER then
            if tb.tag == TAG_INTEGER then return true end
            if tb.tag == TAG_NUMBER  then return true end
        end
        if kind == LIT_STRING and tb.tag == TAG_STRING then return true end
        -- enum member <: matching literal (same kind and value)
        if tb.tag == TAG_LITERAL and types_mod.lit_kind(tb) == kind
            and tb.data[1] == types_mod.enum_value(ta) then
            -- tb.data[1]: for LIT_STRING this is lit_str_id, for LIT_INTEGER it's lit_num_lo.
            -- The cross-kind raw-slot compare is intentional (kinds already matched above).
            return true
        end
    end

    -- Literal <: base type
    if ta.tag == TAG_LITERAL then
        if tb.tag == TAG_LITERAL then
            if types_mod.lit_kind(ta) == types_mod.lit_kind(tb) and ta.data[1] == tb.data[1]
              and (types_mod.lit_kind(ta) ~= LIT_NUMBER or types_mod.lit_num_hi(ta) == types_mod.lit_num_hi(tb)) then return true end
            -- ta.data[1] / tb.data[1] is kind-polymorphic (lit_str_id | lit_bool | lit_num_lo);
            -- the kind equality guard above makes the raw-slot compare well-defined.
            return false, "`" .. types_mod.display(ctx, a) .. "` is not `" .. types_mod.display(ctx, b) .. "`", nil
        end
        local kind = types_mod.lit_kind(ta)
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
        local ams, aml = types_mod.agg_members_start(ta), types_mod.agg_members_len(ta)
        for i = ams, ams + aml - 1 do
            local mid = find(ctx, ctx.lists:get(i))
            local ok, err = M.unify(ctx, mid, b, seen)
            if not ok then
                return false, "`" .. types_mod.display(ctx, mid) .. "` in union is not assignable to `" .. types_mod.display(ctx, b) .. "`", nil
            end
        end
        return true
    end

    -- Intersection on LHS: at least one member satisfies RHS.
    -- This block handles all composite RHS cases too, so the standalone union/intersection-on-RHS
    -- checks below only fire when ta is NOT an intersection.
    -- Use copy_seen for each alternative.
    if ta.tag == TAG_INTERSECTION then
        local ams, aml = types_mod.agg_members_start(ta), types_mod.agg_members_len(ta)
        -- Step 1: any single member of the intersection satisfies b?
        -- This correctly handles (A & (B|C)) <: (B|C) by checking (B|C) member against union b.
        for i = ams, ams + aml - 1 do
            local ok = M.unify(ctx, ctx.lists:get(i), b, copy_seen(seen))
            if ok then return true end
        end
        -- Step 2: dispatch on b's structure for cases no single member covers.
        if tb.tag == TAG_UNION then
            -- Try the full intersection against each union member (e.g. merged-fields vs TABLE member).
            local best_detail, best_depth = nil, -1
            local bms, bml = types_mod.agg_members_start(tb), types_mod.agg_members_len(tb)
            for i = bms, bms + bml - 1 do
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
            local bms, bml = types_mod.agg_members_start(tb), types_mod.agg_members_len(tb)
            for i = bms, bms + bml - 1 do
                local ok2, err = M.unify(ctx, a, ctx.lists:get(i), seen)
                if not ok2 then return false, err, nil end
            end
            return true
        end
        -- Merged-fields fallback: {f:T} & {g:U} <: {f:T, g:U}
        -- For each required field in b, at least one intersection member must cover it.
        if tb.tag == TAG_TABLE then
            local all_covered = true
            local bfs, bfl = types_mod.tbl_fields_start(tb), types_mod.tbl_fields_len(tb)
            for i = bfs, bfs + bfl - 1 do
                local bfe = ctx.fields:get(ctx.lists:get(i))
                if band(bfe.flags, FLAG_OPTIONAL) == 0 then
                    local found = false
                    for j = ams, ams + aml - 1 do
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
        return false, "`" .. types_mod.display(ctx, a) .. "` is not assignable to `" .. types_mod.display(ctx, b) .. "`", nil
    end

    -- Union on RHS: LHS must be assignable to at least one member.
    -- (Only reached when ta is NOT an intersection.)
    -- Use copy_seen for each alternative: failed branches must not contaminate siblings.
    if tb.tag == TAG_UNION then
        local best_detail, best_depth = nil, -1
        local bms, bml = types_mod.agg_members_start(tb), types_mod.agg_members_len(tb)
        for i = bms, bms + bml - 1 do
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
        local bms, bml = types_mod.agg_members_start(tb), types_mod.agg_members_len(tb)
        for i = bms, bms + bml - 1 do
            local ok, err = M.unify(ctx, a, ctx.lists:get(i), seen)
            if not ok then return false, err, nil end
        end
        return true
    end

    -- Function types: contravariant params, covariant returns
    if ta.tag == TAG_FUNCTION and tb.tag == TAG_FUNCTION then
        local aps = types_mod.fn_params_start(ta)
        local apl = types_mod.fn_params_len(ta)
        local bps = types_mod.fn_params_start(tb)
        local bpl = types_mod.fn_params_len(tb)
        -- fn_vararg >= 0: function has a variadic param (...T); value is the type of T.
        local a_va_id = types_mod.fn_vararg(ta)
        local b_va_id = types_mod.fn_vararg(tb)
        local a_vararg = a_va_id >= 0 and find(ctx, a_va_id) or nil
        local b_vararg = b_va_id >= 0 and find(ctx, b_va_id) or nil
        local max_params = apl > bpl and apl or bpl --: integer
        for i = 0, max_params - 1 do
            local ap_id = i < apl and find(ctx, ctx.lists:get(aps + i))
                       or (a_vararg or ctx.T_NIL)
            local bp_id = i < bpl and find(ctx, ctx.lists:get(bps + i))
                       or (b_vararg or ctx.T_NIL)
            -- Contravariant: b's param assignable to a's param
            local ok, err = M.unify(ctx, bp_id, ap_id, seen)
            if not ok then
                return false, "parameter " .. (i + 1) .. ": " .. (err or "type mismatch"), nil
            end
        end
        local ars, arl = types_mod.fn_returns_start(ta), types_mod.fn_returns_len(ta)
        local brs, brl = types_mod.fn_returns_start(tb), types_mod.fn_returns_len(tb)
        -- For returns: actual returning MORE values than expected is fine in Lua
        -- (callers ignore extra returns). Only check up to expected's declared count.
        -- When actual returns FEWER than expected, the missing slots are nil.
        for i = 0, brl - 1 do
            local ar_id = i < arl and find(ctx, ctx.lists:get(ars + i)) or ctx.T_NIL
            local br_id = find(ctx, ctx.lists:get(brs + i))
            local ok, err = M.unify(ctx, ar_id, br_id, seen)
            if not ok then
                return false, "return " .. (i + 1) .. ": " .. (err or "type mismatch"), nil
            end
        end
        return true
    end

    -- Primitives satisfy meta-only table constraints (e.g. number satisfies { #__add: fn }).
    -- Look up the primitive's declared meta type from ctx.prim_meta (keyed by base TAG_*).
    if tb.tag == TAG_TABLE and types_mod.tbl_fields_len(tb) == 0
        and types_mod.tbl_indexers_len(tb) == 0 and types_mod.tbl_meta_len(tb) > 0 then
        local ptag = ta.tag
        if ptag == TAG_LITERAL then
            local lk = types_mod.lit_kind(ta)
            if lk == LIT_NUMBER   then ptag = TAG_NUMBER
            elseif lk == LIT_INTEGER then ptag = TAG_INTEGER
            elseif lk == LIT_STRING  then ptag = TAG_STRING
            else ptag = nil
            end
        elseif ptag ~= TAG_NUMBER and ptag ~= TAG_INTEGER and ptag ~= TAG_STRING then
            ptag = nil
        end
        local prim_meta_tid = ptag and ctx.prim_meta[ptag]
        if prim_meta_tid then
            local ms, ml = types_mod.tbl_meta_start(tb), types_mod.tbl_meta_len(tb)
            for i = ms, ms + ml - 1 do
                local fe  = ctx.fields:get(ctx.lists:get(i))
                local amf = types_mod.table_meta_field(ctx, prim_meta_tid, fe.name_id)
                if not amf then
                    local mname = intern_mod.get(ctx.pool, fe.name_id) or "?"
                    return false, types_mod.display(ctx, a) .. " does not support #" .. mname, nil
                end
            end
            return true
        end
    end

    -- Primitives satisfy named-field table constraints via their declared __index (ctx.prim_index).
    -- E.g. string <: { sub: _ } works because ctx.prim_index[TAG_STRING] is the user-declared
    -- `string` table in stdlib_types.lua, which has a `sub` field. User-configurable: changing
    -- the `string` declaration in stdlib_types.lua changes what fields `string` structurally exposes.
    if ta.tag ~= TAG_TABLE and tb.tag == TAG_TABLE and types_mod.tbl_fields_len(tb) > 0 then
        local ptag = ta.tag
        if ptag == TAG_LITERAL then
            local lk = types_mod.lit_kind(ta)
            if lk == LIT_NUMBER   then ptag = TAG_NUMBER
            elseif lk == LIT_INTEGER then ptag = TAG_INTEGER
            elseif lk == LIT_STRING  then ptag = TAG_STRING
            else ptag = nil
            end
        elseif ptag ~= TAG_NUMBER and ptag ~= TAG_INTEGER and ptag ~= TAG_STRING then
            ptag = nil
        end
        local idx_tid = ptag and ctx.prim_index and ctx.prim_index[ptag]
        if idx_tid then
            local bfs, bfl = types_mod.tbl_fields_start(tb), types_mod.tbl_fields_len(tb)
            for i = bfs, bfs + bfl - 1 do
                local bfid = ctx.lists:get(i)
                local bfe  = ctx.fields:get(bfid)
                if band(bfe.flags, FLAG_OPTIONAL) ~= 0 then goto prim_named_next end
                local afe = types_mod.table_field(ctx, idx_tid, bfe.name_id)
                if not afe then
                    local fname = intern_mod.get(ctx.pool, bfe.name_id) or "?"
                    return false, types_mod.display(ctx, a) .. " has no field `" .. fname .. "`", nil
                end
                local ok, err = M.unify(ctx, find(ctx, afe.type_id), find(ctx, bfe.type_id), seen)
                if not ok then
                    local fname = intern_mod.get(ctx.pool, bfe.name_id) or "?"
                    return false, "field `" .. fname .. "`: " .. (err or "type mismatch"), nil
                end
                ::prim_named_next::
            end
            return true
        end
    end

    -- Table types: structural subtyping
    if ta.tag == TAG_TABLE and tb.tag == TAG_TABLE then
        local bfs0, bfl0 = types_mod.tbl_fields_start(tb), types_mod.tbl_fields_len(tb)
        -- Every required field in b must exist in a
        for i = bfs0, bfs0 + bfl0 - 1 do
            local bfid = ctx.lists:get(i)
            local bfe = ctx.fields:get(bfid)
            local bft = find(ctx, bfe.type_id)
            -- Handle spread fields { ...T, ... }: expand the inner table's
            -- fields and check each one against a, as if they were direct fields.
            if bfe.name_id == -1 then
                local spread_t = ctx.types:get(bft)
                if spread_t.tag == TAG_SPREAD then
                    local inner_tid = find(ctx, types_mod.spread_inner(spread_t))
                    local inner_t = ctx.types:get(inner_tid)
                    if inner_t.tag == TAG_TABLE then
                        local ifs, ifl = types_mod.tbl_fields_start(inner_t), types_mod.tbl_fields_len(inner_t)
                        for j = ifs, ifs + ifl - 1 do
                            local jfid = ctx.lists:get(j)
                            local jfe  = ctx.fields:get(jfid)
                            if jfe.name_id == -1 then goto spread_next end
                            local jft  = find(ctx, jfe.type_id)
                            local afe2 = types_mod.table_field(ctx, a, jfe.name_id)
                            if not afe2 then
                                if band(jfe.flags, FLAG_OPTIONAL) == 0 then
                                    local ais, ail = types_mod.tbl_indexers_start(ta), types_mod.tbl_indexers_len(ta)
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
                                    if not found and types_mod.tbl_row_var(ta) >= 0 then found = true end
                                    if not found then
                                        local fname = intern_mod.get(ctx.pool, jfe.name_id) or "?"
                                        return false,
                                            "missing field `" .. fname .. "` (from spread)",
                                            { kind = "missing_field", field = fname, path = nil }
                                    end
                                end
                            else
                                local aft = find(ctx, afe2.type_id)
                                local ok2, err2 = M.unify(ctx, aft, jft, seen)
                                if not ok2 then
                                    local fname = intern_mod.get(ctx.pool, jfe.name_id) or "?"
                                    return false,
                                        "field `" .. fname .. "` (from spread): " .. (err2 or "type mismatch"), nil
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
                    local ais, ail = types_mod.tbl_indexers_start(ta), types_mod.tbl_indexers_len(ta)
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
                    if not found and types_mod.tbl_row_var(ta) >= 0 then found = true end
                    if not found then
                        local fname = intern_mod.get(ctx.pool, bfe.name_id) or "?"
                        return false, "missing field '" .. fname .. "'",
                            { kind = "missing_field", field = fname, path = nil }
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
        local bis0, bil0 = types_mod.tbl_indexers_start(tb), types_mod.tbl_indexers_len(tb)
        for i = bis0, bis0 + bil0 - 1, 2 do
            local bk = find(ctx, ctx.lists:get(i))
            local bv = find(ctx, ctx.lists:get(i + 1))
            local matched = false
            local ais, ail = types_mod.tbl_indexers_start(ta), types_mod.tbl_indexers_len(ta)
            local j = ais
            while j < ais + ail - 1 do
                local ak = find(ctx, ctx.lists:get(j))
                if M.unify(ctx, ak, bk, seen) then
                    local av = find(ctx, ctx.lists:get(j + 1))
                    local ok, err = M.unify(ctx, av, bv, seen)
                    if not ok then
                        return false, "indexer value: " .. (err or "type mismatch"), nil
                    end
                    matched = true
                    break
                end
                j = j + 2
            end
            if not matched then
                if types_mod.tbl_fields_len(ta) == 0 and types_mod.tbl_indexers_len(ta) == 0 then
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
                        local afs, afl = types_mod.tbl_fields_start(ta), types_mod.tbl_fields_len(ta)
                        for fi = afs, afs + afl - 1 do
                            local afe = ctx.fields:get(ctx.lists:get(fi))
                            local fname = intern_mod.get(ctx.pool, afe.name_id)
                            if fname and fname:match("^%d+$") then
                                local av = find(ctx, afe.type_id)
                                local ok, err = M.unify(ctx, av, bv, seen)
                                if not ok then
                                    return false, "positional element " .. tostring(fname) .. ": " .. (err or "type mismatch"), nil
                                end
                                matched = true
                            end
                        end
                    end
                    if not matched and bkt.tag ~= TAG_STRING then
                        if types_mod.tbl_row_var(ta) < 0 then  -- no row var
                            return false, "missing indexer for " .. types_mod.display(ctx, bk), nil
                        end
                    end
                end
            end
        end

        -- Check meta fields
        local bms0, bml0 = types_mod.tbl_meta_start(tb), types_mod.tbl_meta_len(tb)
        for i = bms0, bms0 + bml0 - 1 do
            local bfid = ctx.lists:get(i)
            local bfe = ctx.fields:get(bfid)
            local amf = types_mod.table_meta_field(ctx, a, bfe.name_id)
            if not amf then
                if band(bfe.flags, FLAG_OPTIONAL) == 0 then
                    local mname = intern_mod.get(ctx.pool, bfe.name_id) or "?"
                    return false, "missing metatable slot '#" .. mname .. "'", nil
                end
            else
                local ok, err = M.unify(ctx, find(ctx, amf.type_id), find(ctx, bfe.type_id), seen)
                if not ok then
                    local mname = intern_mod.get(ctx.pool, bfe.name_id) or "?"
                    return false, "#" .. mname .. ": " .. (err or "type mismatch"), nil
                end
            end
        end

        -- Excess-indexer check: every indexer entry in `a` (source) must be
        -- covered by some indexer entry in `b` (target). A target indexer
        -- `[BK] -> BV` covers a source indexer `[AK] -> AV` when AK <: BK and
        -- AV <: BV. Without this, source indexers carrying values that violate
        -- the target value type slip through (e.g. `{ "a", 2 }` typed as
        -- `{ [number]: string }` — both positional entries become indexers
        -- with LIT_INTEGER keys, and the b-driven loop above only finds the
        -- first matching a-entry per target indexer).
        if types_mod.tbl_row_var(tb) < 0 and types_mod.tbl_row_var(ta) < 0 then
            local ais, ail = types_mod.tbl_indexers_start(ta), types_mod.tbl_indexers_len(ta)
            local j = ais
            while j < ais + ail - 1 do
                local ak = find(ctx, ctx.lists:get(j))
                local av = find(ctx, ctx.lists:get(j + 1))
                local akt = ctx.types:get(ak)
                local covered = false
                local last_err = nil --: string | nil
                -- Skip TAG_VAR / TAG_ROWVAR source keys: the b-driven loop
                -- above already bound them where compatible, and an unbound
                -- key cannot be meaningfully checked for excess.
                if akt.tag == TAG_VAR or akt.tag == defs.TAG_ROWVAR then
                    covered = true
                end
                local bis, bil = types_mod.tbl_indexers_start(tb), types_mod.tbl_indexers_len(tb)
                local k = bis
                while not covered and k < bis + bil - 1 do
                    local bk = find(ctx, ctx.lists:get(k))
                    local bv = find(ctx, ctx.lists:get(k + 1))
                    if M.try_unify(ctx, ak, bk, seen) then
                        local ok_v, err_v = M.unify(ctx, av, bv, seen)
                        if ok_v then covered = true; break
                        else last_err = err_v end
                    end
                    k = k + 2
                end
                if not covered then
                    if last_err then
                        return false, "indexer value for " .. types_mod.display(ctx, ak) .. ": " .. last_err, nil
                    end
                    -- No target indexer key subsumed `ak` — only an error when
                    -- target has at least one indexer; otherwise the field
                    -- excess check below (or open-table absorption) handles it.
                    if bil > 0 then
                        return false, "excess indexer for key " .. types_mod.display(ctx, ak) .. " not in target type", nil
                    end
                end
                j = j + 2
            end
        end

        -- Excess-field check: if the target is closed (no row var) and the source
        -- is also closed, every field in the source must exist in the target.
        -- Width subtyping ({x,y} <: {x}) only holds when the target is open ({x,...}).
        if types_mod.tbl_row_var(tb) < 0 and types_mod.tbl_row_var(ta) < 0 then
            local afs1, afl1 = types_mod.tbl_fields_start(ta), types_mod.tbl_fields_len(ta)
            for i = afs1, afs1 + afl1 - 1 do
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
                        local bis, bil = types_mod.tbl_indexers_start(tb), types_mod.tbl_indexers_len(tb)
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
                                    return false, "field '" .. fname .. "': " .. (err2 or "type mismatch"), nil
                                end
                            end
                            j = j + 2
                        end
                        if not covered then
                            return false, "excess field '" .. fname .. "' not in target type", nil
                        end
                    end
                end
            end
        end

        return true
    end

    -- Tuple types
    if ta.tag == TAG_TUPLE and tb.tag == TAG_TUPLE then
        local aml = types_mod.agg_members_len(ta)
        local bml = types_mod.agg_members_len(tb)
        if aml ~= bml then
            return false, "tuple length mismatch: " .. aml .. " vs " .. bml, nil
        end
        local ams, bms = types_mod.agg_members_start(ta), types_mod.agg_members_start(tb)
        for i = 0, aml - 1 do
            local ae = find(ctx, ctx.lists:get(ams + i))
            local be = find(ctx, ctx.lists:get(bms + i))
            local ok, err = M.unify(ctx, ae, be, seen)
            if not ok then
                return false, "tuple element " .. (i + 1) .. ": " .. (err or "type mismatch"), nil
            end
        end
        return true
    end

    if ta.tag == TAG_TUPLE and tb.tag == TAG_TABLE then
        return false, "tuple is not assignable to table/array", nil
    end
    if ta.tag == TAG_TABLE and tb.tag == TAG_TUPLE then
        return false, "table/array is not assignable to tuple", nil
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

    -- Gap 11: unknown <: any is rejected (mirrors M.unify). Other any-on-either-side
    -- combinations remain bilateral.
    if ta.tag == TAG_UNKNOWN and tb.tag == TAG_ANY then return false end
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
        local a_name = types_mod.named_name_id(ta)
        local b_name = types_mod.named_name_id(tb)
        -- Same alias: trivially subtype.
        if a_name == b_name then return true end
        -- Oracle lookup: is (a_name, b_name) a declared subtype pair?
        local ds = ctx.declared_subtypes
        if ds and ds[a_name] == b_name then
            -- Args check: if actual and expected both have args, each must unify.
            local a_al = types_mod.named_args_len(ta)  -- args len (0 for non-generic checker-arena nodes)
            local b_al = types_mod.named_args_len(tb)
            if a_al == 0 and b_al == 0 then
                return true  -- non-generic oracle hit
            end
            if a_al == b_al then
                local a_as = types_mod.named_args_start(ta)
                local b_as = types_mod.named_args_start(tb)
                for i = 0, a_al - 1 do
                    local aa = ctx.lists:get(a_as + i)
                    local ba = ctx.lists:get(b_as + i)
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
        local ams, aml = types_mod.agg_members_start(ta), types_mod.agg_members_len(ta)
        for i = ams, ams + aml - 1 do
            if not M.try_unify(ctx, ctx.lists:get(i), b, seen) then return false end
        end
        return true
    end

    if ta.tag == tb.tag and is_primitive_tag(ta.tag) then return true end

    if ta.tag == TAG_INTEGER and tb.tag == TAG_NUMBER then return true end

    if ta.tag == TAG_ENUM_MEMBER then
        if tb.tag == TAG_ENUM_MEMBER then
            if types_mod.enum_name_id(ta) == types_mod.enum_name_id(tb)
                and types_mod.enum_member_id(ta) == types_mod.enum_member_id(tb) then return true end
            return false
        end
        local kind = types_mod.enum_lit_kind(ta)
        if kind == LIT_INTEGER then
            if tb.tag == TAG_INTEGER then return true end
            if tb.tag == TAG_NUMBER  then return true end
        end
        if kind == LIT_STRING and tb.tag == TAG_STRING then return true end
        if tb.tag == TAG_LITERAL and types_mod.lit_kind(tb) == kind
            and tb.data[1] == types_mod.enum_value(ta) then
            -- See M.unify enum branch: cross-kind raw-slot compare is guarded by kind equality.
            return true
        end
        return false
    end

    if ta.tag == TAG_LITERAL then
        if tb.tag == TAG_LITERAL and types_mod.lit_kind(ta) == types_mod.lit_kind(tb)
          and ta.data[1] == tb.data[1]
          and (types_mod.lit_kind(ta) ~= LIT_NUMBER or types_mod.lit_num_hi(ta) == types_mod.lit_num_hi(tb)) then
            -- data[1] raw compare is kind-polymorphic; well-defined under the kind equality guard.
            return true
        end
        local kind = types_mod.lit_kind(ta)
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
        local ams, aml = types_mod.agg_members_start(ta), types_mod.agg_members_len(ta)
        -- Step 1: any single member of the intersection satisfies b?
        -- This correctly handles (A & (B|C)) <: (B|C) by checking (B|C) member against union b.
        for i = ams, ams + aml - 1 do
            if M.try_unify(ctx, ctx.lists:get(i), b, copy_seen(seen)) then return true end
        end
        -- Step 2: dispatch on b's structure for cases no single member covers.
        if tb.tag == TAG_UNION then
            -- Try the full intersection against each union member (e.g. merged-fields vs TABLE member).
            local bms, bml = types_mod.agg_members_start(tb), types_mod.agg_members_len(tb)
            for i = bms, bms + bml - 1 do
                if M.try_unify(ctx, a, ctx.lists:get(i), copy_seen(seen)) then return true end
            end
            return false
        end
        if tb.tag == TAG_INTERSECTION then
            -- LHS must satisfy ALL RHS members (conjunction).
            local bms, bml = types_mod.agg_members_start(tb), types_mod.agg_members_len(tb)
            for i = bms, bms + bml - 1 do
                if not M.try_unify(ctx, a, ctx.lists:get(i), seen) then return false end
            end
            return true
        end
        -- Merged-fields fallback: {f:T} & {g:U} <: {f:T, g:U}
        if tb.tag == TAG_TABLE then
            local all_covered = true
            local bfs, bfl = types_mod.tbl_fields_start(tb), types_mod.tbl_fields_len(tb)
            for i = bfs, bfs + bfl - 1 do
                local bfe = ctx.fields:get(ctx.lists:get(i))
                if band(bfe.flags, FLAG_OPTIONAL) == 0 then
                    local found = false
                    for j = ams, ams + aml - 1 do
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
        local bms, bml = types_mod.agg_members_start(tb), types_mod.agg_members_len(tb)
        for i = bms, bms + bml - 1 do
            if M.try_unify(ctx, a, ctx.lists:get(i), copy_seen(seen)) then return true end
        end
        return false
    end

    -- Intersection on RHS: a must satisfy ALL members (conjunctive — shared seen is fine).
    -- (Only reached when ta is NOT an intersection.)
    if tb.tag == TAG_INTERSECTION then
        local bms, bml = types_mod.agg_members_start(tb), types_mod.agg_members_len(tb)
        for i = bms, bms + bml - 1 do
            if not M.try_unify(ctx, a, ctx.lists:get(i), seen) then return false end
        end
        return true
    end

    if ta.tag == TAG_FUNCTION and tb.tag == TAG_FUNCTION then
        local aps = types_mod.fn_params_start(ta)
        local apl = types_mod.fn_params_len(ta)
        local bps = types_mod.fn_params_start(tb)
        local bpl = types_mod.fn_params_len(tb)
        local a_va_id = types_mod.fn_vararg(ta)
        local b_va_id = types_mod.fn_vararg(tb)
        local a_va = a_va_id >= 0 and find(ctx, a_va_id) or nil
        local b_va = b_va_id >= 0 and find(ctx, b_va_id) or nil
        local max_p = apl > bpl and apl or bpl --: integer
        for i = 0, max_p - 1 do
            local ap = i < apl and find(ctx, ctx.lists:get(aps + i)) or (a_va or ctx.T_NIL)
            local bp = i < bpl and find(ctx, ctx.lists:get(bps + i)) or (b_va or ctx.T_NIL)
            if not M.try_unify(ctx, bp, ap, seen) then return false end
        end
        return true
    end

    -- Same prim_index check for try_unify (non-destructive — no TV binding involved for primitives).
    if ta.tag ~= TAG_TABLE and tb.tag == TAG_TABLE and types_mod.tbl_fields_len(tb) > 0 then
        local ptag = ta.tag
        if ptag == TAG_LITERAL then
            local lk = types_mod.lit_kind(ta)
            if lk == LIT_NUMBER   then ptag = TAG_NUMBER
            elseif lk == LIT_INTEGER then ptag = TAG_INTEGER
            elseif lk == LIT_STRING  then ptag = TAG_STRING
            else ptag = nil
            end
        elseif ptag ~= TAG_NUMBER and ptag ~= TAG_INTEGER and ptag ~= TAG_STRING then
            ptag = nil
        end
        local idx_tid = ptag and ctx.prim_index and ctx.prim_index[ptag]
        if idx_tid then
            local bfs, bfl = types_mod.tbl_fields_start(tb), types_mod.tbl_fields_len(tb)
            for i = bfs, bfs + bfl - 1 do
                local bfe = ctx.fields:get(ctx.lists:get(i))
                if band(bfe.flags, FLAG_OPTIONAL) ~= 0 then goto try_prim_named_next end
                local afe = types_mod.table_field(ctx, idx_tid, bfe.name_id)
                if not afe then return false end
                if not M.try_unify(ctx, find(ctx, afe.type_id), find(ctx, bfe.type_id), seen) then
                    return false
                end
                ::try_prim_named_next::
            end
            return true
        end
    end

    if ta.tag == TAG_TABLE and tb.tag == TAG_TABLE then
        local bfs, bfl = types_mod.tbl_fields_start(tb), types_mod.tbl_fields_len(tb)
        for i = bfs, bfs + bfl - 1 do
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
        local bms, bml = types_mod.tbl_meta_start(tb), types_mod.tbl_meta_len(tb)
        for i = bms, bms + bml - 1 do
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
        return types_mod.nom_identity(ta) == types_mod.nom_identity(tb)
    end

    if ta.tag == TAG_CDATA or tb.tag == TAG_CDATA then return true end

    return false
end

-- Expose the private is_primitive_tag for external use.
function M.is_primitive_tag(tag)
    return tag == TAG_NIL or tag == TAG_BOOLEAN or tag == TAG_NUMBER
        or tag == TAG_INTEGER or tag == TAG_STRING
end

-- Strict subtype check: `actual` is assignable to `expected` (actual <: expected)
-- under the same lattice that `unify` enforces — including the closed-table
-- excess-field check that `try_unify` deliberately omits.
--
-- `try_unify` is "shape overlap": shared fields must agree, but extra fields
-- on `actual` are tolerated even when `expected` is closed. That is the right
-- semantics for force-cast overlap (`--[[:! T]]`) and for narrowing oracles,
-- but it is NOT the right semantics for the REDUNDANT_CAST classifier — a cast
-- that strips fields is doing real work even though `try_unify` says "they
-- overlap". For redundancy classification we need the assignability lattice.
--
-- Implementation: try_unify (which checks shape recursively), then for the
-- top-level closed-table case, additionally enforce the excess-field rule.
-- Side-effect free.
--: (Ctx, integer, integer) -> boolean
function M.is_subtype(ctx, actual, expected)
    if not M.try_unify(ctx, actual, expected) then return false end
    local a = find(ctx, actual)
    local b = find(ctx, expected)
    local ta = ctx.types:get(a)
    local tb = ctx.types:get(b)
    -- Closed-target excess check: when both sides are closed tables, every
    -- named field of `actual` must exist in `expected` (or be covered by an
    -- indexer on `expected`). Otherwise the cast is removing a field — not
    -- redundant.
    if ta.tag == TAG_TABLE and tb.tag == TAG_TABLE
        and types_mod.tbl_row_var(tb) < 0 and types_mod.tbl_row_var(ta) < 0 then
        local afs, afl = types_mod.tbl_fields_start(ta), types_mod.tbl_fields_len(ta)
        for i = afs, afs + afl - 1 do
            local afid = ctx.lists:get(i)
            local afe  = ctx.fields:get(afid)
            if band(afe.flags, FLAG_OPAQUE_KEY) == 0 then
                local bfe_match = types_mod.table_field(ctx, b, afe.name_id)
                if not bfe_match then
                    -- Indexer cover check (mirrors unify's logic at line 776+).
                    local fname = intern_mod.get(ctx.pool, afe.name_id) or "?"
                    local covered = false
                    local bis, bil = types_mod.tbl_indexers_start(tb), types_mod.tbl_indexers_len(tb)
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
                            if M.try_unify(ctx, av, bv) then
                                covered = true; break
                            end
                        end
                        j = j + 2
                    end
                    if not covered then return false end
                end
            end
        end
    end
    return true
end

-- Overlap (read-only): does there exist any value v with v : a AND v : b?
-- Used by C_OVERLAP (--[[:! T]] force casts). Returns boolean.
--
-- Definition:
--   - any/unknown overlap with everything (top types).
--   - never overlaps with nothing (bottom).
--   - If try_unify(a, b) or try_unify(b, a), overlap is true (either set
--     contains the other's witness).
--   - If a is a union, overlap iff some member of a overlaps with b
--     (and symmetrically for b).
--   - If a is an intersection, overlap iff no member has a field that conflicts
--     with b's required fields (structural no-conflict check). This handles
--     setmetatable result types and other intersection patterns.
--   - If both are tables, same structural no-conflict check (handles casting
--     a table with MORE fields to a table with FEWER fields).
--   - Otherwise no overlap (atomic mismatch like string vs integer).
--
-- The structural no-conflict check is intentionally weaker than subtyping: two
-- table types overlap when their shared fields are type-compatible, even if
-- one has extra fields the other doesn't. This allows `{x,y} --[[:! {x}]]`
-- (structural subtype) and intersection narrowing with setmetatable results.
--: (Ctx, integer, integer) -> boolean
function M.types_overlap(ctx, a, b)
    a = find(ctx, a)
    b = find(ctx, b)
    if a == b then return true end
    local ta = ctx.types:get(a)
    local tb = ctx.types:get(b)
    if ta.tag == TAG_NEVER or tb.tag == TAG_NEVER then return false end
    if ta.tag == TAG_ANY or tb.tag == TAG_ANY then return true end
    if ta.tag == TAG_UNKNOWN or tb.tag == TAG_UNKNOWN then return true end
    -- Subtyping in either direction implies overlap.
    if M.try_unify(ctx, a, b) then return true end
    if M.try_unify(ctx, b, a) then return true end
    -- Union: any member overlapping suffices.
    if ta.tag == TAG_UNION then
        local ams, aml = types_mod.agg_members_start(ta), types_mod.agg_members_len(ta)
        for i = ams, ams + aml - 1 do
            if M.types_overlap(ctx, ctx.lists:get(i), b) then return true end
        end
        return false
    end
    if tb.tag == TAG_UNION then
        local bms, bml = types_mod.agg_members_start(tb), types_mod.agg_members_len(tb)
        for i = bms, bms + bml - 1 do
            if M.types_overlap(ctx, a, ctx.lists:get(i)) then return true end
        end
        return false
    end
    -- Structural field compatibility: check that shared fields don't conflict.
    -- Two table types conflict on a field when both declare the field required
    -- and the field types are incompatible in both directions (neither is a
    -- subtype of the other). Extra fields on one side never prevent overlap.
    --
    -- When ta is an intersection, gather named fields from each TABLE member
    -- and check them against b's required fields.  This handles the common
    -- setmetatable pattern: `{x: 1} & {#?: ...{__index: {get: fn}}}` overlaps
    -- with `{get: fn, x: integer}` because `x: 1` and `x: integer` are
    -- compatible (1 <: integer), and the `get` field is absent from the
    -- intersection's named fields so there is no conflict.
    --
    -- The symmetric case (tb is an intersection) is handled by swapping roles.
    local function fields_compatible(tbl_tid, other_tid)
        -- For each required named field in `other_tid` (a TAG_TABLE), check
        -- if `tbl_tid` (also a TAG_TABLE) has a conflicting declaration.
        local other_t = ctx.types:get(other_tid)
        local ofs, ofl = types_mod.tbl_fields_start(other_t), types_mod.tbl_fields_len(other_t)
        for i = ofs, ofs + ofl - 1 do
            local bfe = ctx.fields:get(ctx.lists:get(i))
            if band(bfe.flags, FLAG_OPTIONAL) ~= 0 then goto compat_next end
            local afe = types_mod.table_field(ctx, tbl_tid, bfe.name_id)
            if afe then
                -- Same field in both: types must overlap (no conflict).
                local at = find(ctx, afe.type_id)
                local bt = find(ctx, bfe.type_id)
                if not M.try_unify(ctx, at, bt) and not M.try_unify(ctx, bt, at) then
                    return false  -- field type conflict: cannot have common witness
                end
            end
            -- Field absent in tbl_tid but required in other: no conflict
            -- (tbl_tid may have extra fields or the combined type is fine).
            ::compat_next::
        end
        return true
    end

    if ta.tag == TAG_INTERSECTION then
        -- Check each TABLE member against b for field conflicts.
        -- If NO member conflicts, the intersection overlaps with b.
        local any_conflict = false
        local ams, aml = types_mod.agg_members_start(ta), types_mod.agg_members_len(ta)
        for i = ams, ams + aml - 1 do
            local mid = find(ctx, ctx.lists:get(i))
            local mt = ctx.types:get(mid)
            if mt.tag == TAG_TABLE then
                if tb.tag == TAG_TABLE and not fields_compatible(mid, b) then
                    any_conflict = true; break
                end
            end
        end
        if not any_conflict then return true end
    end
    if tb.tag == TAG_INTERSECTION then
        -- Symmetric: check each TABLE member of tb against a.
        local any_conflict = false
        local bms, bml = types_mod.agg_members_start(tb), types_mod.agg_members_len(tb)
        for i = bms, bms + bml - 1 do
            local mid = find(ctx, ctx.lists:get(i))
            local mt = ctx.types:get(mid)
            if mt.tag == TAG_TABLE then
                if ta.tag == TAG_TABLE and not fields_compatible(mid, a) then
                    any_conflict = true; break
                end
            end
        end
        if not any_conflict then return true end
    end
    -- Direct table-to-table: check shared fields are type-compatible in either
    -- direction.  This allows `{x: integer, y: string} --[[:! {x: integer}]]`
    -- where the actual has more fields than the expected type (structural width
    -- subtyping for force casts).
    if ta.tag == TAG_TABLE and tb.tag == TAG_TABLE then
        if fields_compatible(a, b) and fields_compatible(b, a) then
            return true
        end
    end
    return false
end

return M
