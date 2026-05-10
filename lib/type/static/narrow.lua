-- lib/type/static/narrow.lua
-- Control flow narrowing for the typechecker.
-- Extracts type narrowing information from if/while/repeat test expressions.

local defs = require("lib.type.static.defs")
local types_mod = require("lib.type.static.types")
local intern_mod = require("lib.type.static.intern")

local FLAG_OPTIONAL    = defs.FLAG_OPTIONAL
local band             = bit.band

local NODE_BINARY_EXPR = defs.NODE_BINARY_EXPR
local NODE_UNARY_EXPR  = defs.NODE_UNARY_EXPR
local NODE_CALL_EXPR   = defs.NODE_CALL_EXPR
local NODE_IDENTIFIER  = defs.NODE_IDENTIFIER
local NODE_FIELD_EXPR  = defs.NODE_FIELD_EXPR

local OP_EQ  = defs.OP_EQ
local OP_NE  = defs.OP_NE
local OP_NOT = defs.OP_NOT
local OP_AND = defs.OP_AND
local OP_OR  = defs.OP_OR

local TAG_ANY   = defs.TAG_ANY
local TAG_NIL   = defs.TAG_NIL
local TAG_NEVER = defs.TAG_NEVER
local TAG_VAR    = defs.TAG_VAR
local TAG_ROWVAR = defs.TAG_ROWVAR
local TAG_TABLE  = defs.TAG_TABLE
local TAG_UNION = defs.TAG_UNION
local TAG_LITERAL     = defs.TAG_LITERAL
local TAG_ENUM_MEMBER = defs.TAG_ENUM_MEMBER
local TAG_STRING  = defs.TAG_STRING
local LIT_NIL     = defs.LIT_NIL
local LIT_STRING  = defs.LIT_STRING
local LIT_BOOLEAN = defs.LIT_BOOLEAN
local LIT_INTEGER = defs.LIT_INTEGER
local LIT_NUMBER  = defs.LIT_NUMBER
local i32x2_to_double = defs.i32x2_to_double

local M = {}

--:: NarrowInfoNilCheck     = { kind: "nil_check", name_id: integer, positive: boolean }
--:: NarrowInfoFieldDisc    = { kind: "field_disc", name_id: integer, field_name_id: integer, lit_kind: integer, lit_intern_id: integer, lit_intern_hi?: integer, positive: boolean }
--:: NarrowInfoLitEq        = { kind: "lit_eq", name_id: integer, lit_kind: integer, lit_id: number, positive: boolean }
--:: NarrowInfoEnumEq       = { kind: "enum_eq", name_id: integer, member_tid: integer, positive: boolean }
--:: NarrowInfoFieldPres    = { kind: "field_presence", obj_name_id: integer, field_name_id: integer, positive: boolean }
--:: NarrowInfoTypeCheck    = { kind: "type_check", name_id: integer, type_str: string, positive: boolean }
--:: NarrowInfoGuardCheck   = { kind: "guard_check", name_id: integer, guard_type_id: integer, positive: boolean }
--:: NarrowInfoInner        = NarrowInfoNilCheck | NarrowInfoFieldDisc | NarrowInfoLitEq | NarrowInfoEnumEq | NarrowInfoFieldPres | NarrowInfoTypeCheck | NarrowInfoGuardCheck
--:: NarrowInfoNegation     = { kind: "negation", inner: NarrowInfoInner }
--:: NarrowInfo             = NarrowInfoInner | NarrowInfoNegation

-- Extract narrowing information from a test expression node.
-- Returns a narrowing_info table or nil.
-- Narrowing info types:
--   { kind = "nil_check", name_id = int, positive = bool }
--     — `x ~= nil` (positive=true means: x is not nil in the truthy branch)
--   { kind = "field_disc", name_id = int, field_id = int, lit_intern_id = int }
--     — `x.field == "value"` (discriminated union)
--   { kind = "type_check", name_id = int, type_str = string }
--     — `type(x) == "string"` etc.
--   { kind = "negation", inner = narrowing_info }
--   { kind = "field_presence", obj_name_id = int, field_name_id = int, positive = bool }
--     — `x.field` is truthy (positive=true means: x.field is non-nil in the truthy branch)
--   { kind = "enum_eq", name_id = int, member_tid = int, positive = bool }
--     — `x == Enum.Member`: narrows x to the enum member type (preserves EnumName.Member display)
--: (Ctx, integer) -> NarrowInfo | nil
local function extract_narrowing(ctx, nid)
    local n = ctx.nodes:get(nid)
    if not n then return nil end

    -- Bare identifier: `if x then` / `if not x then`.
    -- Treat truthiness as a nil-check (positive=true means "x is not nil").
    if n.kind == NODE_IDENTIFIER then
        return { kind = "nil_check", name_id = n.data[0], positive = true }
    end

    -- Bare call expression: `if is_str(v) then`.
    -- If the callee is a user-defined type predicate, extract the guard narrowing.
    if n.kind == NODE_CALL_EXPR then
        local callee = ctx.nodes:get(n.data[0])
        if callee and callee.kind == NODE_IDENTIFIER then
            local env_mod = require("lib.type.static.env")
            local callee_tid_raw = env_mod.lookup(ctx.scope, callee.data[0])
            if callee_tid_raw then
                local callee_tid = types_mod.find(ctx, callee_tid_raw)
                local pred = ctx.pool._type_predicates
                    and ctx.pool._type_predicates[callee_tid]
                if pred and n.data[2] > pred.param_idx then
                    local arg_nid = ctx.ast_lists:get(n.data[1] + pred.param_idx)
                    local arg = ctx.nodes:get(arg_nid)
                    if arg and arg.kind == NODE_IDENTIFIER then
                        return {
                            kind          = "guard_check",
                            name_id       = arg.data[0],
                            guard_type_id = pred.type_id,
                            positive      = true,
                        }
                    end
                end
            end
        end
    end

    -- Field access: `if x.field then` / `if not x.field then`.
    -- Treat as a presence check on x's field (positive=true means field is non-nil).
    if n.kind == NODE_FIELD_EXPR then
        local obj = ctx.nodes:get(n.data[0])
        if obj and obj.kind == NODE_IDENTIFIER then
            return { kind = "field_presence", obj_name_id = obj.data[0], field_name_id = n.data[1], positive = true }
        end
    end

    if n.kind == NODE_UNARY_EXPR and n.data[0] == OP_NOT then
        local inner = extract_narrowing(ctx, n.data[1])
        if not inner then return nil end
        return { kind = "negation", inner = inner }
    end

    if n.kind == NODE_BINARY_EXPR then
        local op = n.data[0]
        if op ~= OP_EQ and op ~= OP_NE then return nil end
        local lhs_nid = n.data[1]
        local rhs_nid = n.data[2]
        local lhs = ctx.nodes:get(lhs_nid)
        local rhs = ctx.nodes:get(rhs_nid)

        -- x == nil / x ~= nil
        if rhs and rhs.kind == defs.NODE_LITERAL and rhs.data[0] == defs.LIT_NIL then
            if lhs and lhs.kind == NODE_IDENTIFIER then
                local positive = (op == OP_NE)  -- ~= nil means "is not nil" in truthy branch
                return { kind = "nil_check", name_id = lhs.data[0], positive = positive }
            end
        end
        if lhs and lhs.kind == defs.NODE_LITERAL and lhs.data[0] == defs.LIT_NIL then
            if rhs and rhs.kind == NODE_IDENTIFIER then
                local positive = (op == OP_NE)
                return { kind = "nil_check", name_id = rhs.data[0], positive = positive }
            end
        end

        -- x == "literal", x == true/false, x == 42 (direct identifier equality with a literal)
        -- x == nil is handled above as nil_check
        local function make_lit_eq(ident_node, lit_node, positive)
            local rlit_kind = lit_node.data[0]
            if rlit_kind == LIT_STRING or rlit_kind == LIT_BOOLEAN then
                return { kind = "lit_eq", name_id = ident_node.data[0],
                         lit_kind = rlit_kind, lit_id = lit_node.data[1], positive = positive }
            end
            if rlit_kind == LIT_NUMBER then
                -- LIT_NUMBER stores the double inline as data[1]+data[2] (i32x2).
                local num = i32x2_to_double(lit_node.data[1], lit_node.data[2])
                if num % 1 == 0 and num >= -(2^31) and num <= 2^31 - 1 then
                    -- Integer-valued float: promote to LIT_INTEGER for cross-type comparison.
                    return { kind = "lit_eq", name_id = ident_node.data[0],
                             lit_kind = LIT_INTEGER, lit_id = math.floor(num), positive = positive }
                else
                    -- Non-integer float: narrow as LIT_NUMBER literal.
                    return { kind = "lit_eq", name_id = ident_node.data[0],
                             lit_kind = LIT_NUMBER, lit_id = num, positive = positive }
                end
            end
        end
        if lhs and lhs.kind == NODE_IDENTIFIER and rhs and rhs.kind == defs.NODE_LITERAL then
            local r = make_lit_eq(lhs, rhs, op == OP_EQ)
            if r then return r end
        end
        -- symmetric: "literal" == x
        if rhs and rhs.kind == NODE_IDENTIFIER and lhs and lhs.kind == defs.NODE_LITERAL then
            local r = make_lit_eq(rhs, lhs, op == OP_EQ)
            if r then return r end
        end

        -- x == Enum.Member (e.g. x == Status.OK): enum member narrowing
        local function try_enum_eq(ident_node, field_node, positive)
            if ident_node.kind ~= NODE_IDENTIFIER then return nil end
            if field_node.kind ~= NODE_FIELD_EXPR then return nil end
            local obj_n = ctx.nodes:get(field_node.data[0])
            if not obj_n or obj_n.kind ~= NODE_IDENTIFIER then return nil end
            -- Look up the enum member type from scope
            local obj_tid = types_mod.find(ctx, (require("lib.type.static.env").lookup(ctx.scope, obj_n.data[0])) or -1)
            if obj_tid < 0 then return nil end
            local fe = types_mod.table_field(ctx, obj_tid, field_node.data[1])
            if not fe then return nil end
            local mem_tid = types_mod.find(ctx, fe.type_id)
            if ctx.types:get(mem_tid).tag ~= TAG_ENUM_MEMBER then return nil end
            return { kind = "enum_eq", name_id = ident_node.data[0],
                     member_tid = mem_tid, positive = positive }
        end
        if lhs and rhs then
            local r = try_enum_eq(lhs, rhs, op == OP_EQ)
                   or try_enum_eq(rhs, lhs, op == OP_EQ)
            if r then return r end
        end

        -- x.field == "literal" or x.field == true/false or x.field == 42
        if lhs and lhs.kind == NODE_FIELD_EXPR then
            local obj = ctx.nodes:get(lhs.data[0])
            if obj and obj.kind == NODE_IDENTIFIER then
                if rhs and rhs.kind == defs.NODE_LITERAL then
                    local rlit_kind = rhs.data[0]
                    if rlit_kind == LIT_STRING or rlit_kind == LIT_BOOLEAN
                    or rlit_kind == LIT_INTEGER or rlit_kind == LIT_NUMBER then
                        local positive = (op == OP_EQ)
                        local disc_lit_kind = rlit_kind
                        local disc_lit_intern_id = rhs.data[1]
                        if rlit_kind == LIT_NUMBER then
                            -- LIT_NUMBER stores the double inline as data[1]+data[2] (i32x2).
                            -- Apply the same promotion as make_lit_eq: integer-valued floats
                            -- become LIT_INTEGER so they match `count: 42` variant fields.
                            local num = i32x2_to_double(rhs.data[1], rhs.data[2])
                            if num % 1 == 0 and num >= -(2^31) and num <= 2^31 - 1 then
                                disc_lit_kind = LIT_INTEGER
                                disc_lit_intern_id = math.floor(num)
                            end
                            -- Non-integer LIT_NUMBER: disc_lit_kind stays LIT_NUMBER,
                            -- disc_lit_intern_id stays rhs.data[1] (low half of i32x2).
                            -- narrow_by_field will compare both halves for LIT_NUMBER.
                        end
                        return {
                            kind          = "field_disc",
                            name_id       = obj.data[0],
                            field_name_id = lhs.data[1],
                            lit_kind      = disc_lit_kind,
                            lit_intern_id = disc_lit_intern_id,
                            lit_intern_hi = (rlit_kind == LIT_NUMBER and disc_lit_kind == LIT_NUMBER) and rhs.data[2] or nil,
                            positive      = positive,
                        }
                    end
                end
            end
        end

        -- type(x) == "string" etc.
        if lhs and lhs.kind == NODE_CALL_EXPR then
            local callee = ctx.nodes:get(lhs.data[0])
            if callee and callee.kind == NODE_IDENTIFIER then
                local callee_name = intern_mod.get(ctx.pool, callee.data[0])
                if callee_name == "type" and lhs.data[2] == 1 then
                    -- One argument: type(x)
                    local arg_nid = ctx.ast_lists:get(lhs.data[1])
                    local arg = ctx.nodes:get(arg_nid)
                    if arg and arg.kind == NODE_IDENTIFIER then
                        if rhs and rhs.kind == defs.NODE_LITERAL and rhs.data[0] == LIT_STRING then
                            local type_str = intern_mod.get(ctx.pool, rhs.data[1])
                            if type_str then
                                local positive = (op == OP_EQ)
                                return {
                                    kind = "type_check",
                                    name_id = arg.data[0],
                                    type_str = type_str,
                                    positive = positive,
                                }
                            end
                        end
                    end
                end
            end
        end
    end

    return nil
end

-- Narrow a table type so a specific field has nil subtracted from its type.
-- Used for field-presence narrowing: after `if not x.field then return end`,
-- x.field is guaranteed non-nil in the continuation.
--: (Ctx, integer, integer) -> integer
local function narrow_field_non_nil(ctx, tid, field_name_id)
    tid = types_mod.find(ctx, tid)
    local t = ctx.types:get(tid)

    if t.tag == TAG_TABLE then
        -- Collect field data before any allocs (FFI pointers invalidated on arena grow)
        local fs, fl = t.data[0], t.data[1]
        local is, il = t.data[2], t.data[3]
        local rv     = t.data[4]
        local ms, ml = t.data[5], t.data[6]
        --: { [integer]: { fid: integer, name_id: integer, type_id: integer, flags: integer }, ... }
        local field_data = {}
        for i = fs, fs + fl - 1 do
            local fid = ctx.lists:get(i)
            local fe = ctx.fields:get(fid)
            field_data[#field_data + 1] = { fid = fid, name_id = fe.name_id, type_id = fe.type_id, flags = fe.flags }
        end

        -- Build new field list, replacing target field with non-nil version.
        local new_field_ids = {}
        local changed = false
        local FLAG_OPTIONAL_CLEAR = bit.bnot(defs.FLAG_OPTIONAL)
        for _, fd in ipairs(field_data) do
            if fd.name_id == field_name_id then
                -- Two sources of nil to strip:
                --   1. The type itself contains nil (e.g. { x: T | nil }) — subtract it.
                --   2. FLAG_OPTIONAL causes solve_index to re-add nil dynamically — clear it.
                -- Both must be handled: a field declared `f?: T` has FLAG_OPTIONAL set
                -- and type_id = T (no nil in the stored type), so subtract alone is not enough.
                local non_nil = types_mod.subtract(ctx, fd.type_id, ctx.T_NIL)
                local new_flags = band(fd.flags, FLAG_OPTIONAL_CLEAR)
                if non_nil ~= fd.type_id or new_flags ~= fd.flags then
                    local new_fid = types_mod.make_field(ctx, fd.name_id, non_nil, new_flags)
                    new_field_ids[#new_field_ids + 1] = new_fid
                    changed = true
                else
                    new_field_ids[#new_field_ids + 1] = fd.fid
                end
            else
                new_field_ids[#new_field_ids + 1] = fd.fid
            end
        end

        if not changed then return tid end

        local indexer_pairs = {}
        for i = is, is + il - 1 do indexer_pairs[#indexer_pairs + 1] = ctx.lists:get(i) end
        local meta_field_ids = {}
        for i = ms, ms + ml - 1 do meta_field_ids[#meta_field_ids + 1] = ctx.lists:get(i) end
        return types_mod.make_table(ctx, new_field_ids, indexer_pairs, rv, meta_field_ids)

    elseif t.tag == TAG_UNION then
        -- Collect member IDs before recursing (allocation may reallocate list pool)
        local s, l = t.data[0], t.data[1]
        --: { [integer]: integer, ... }
        local member_ids = {}
        for i = s, s + l - 1 do
            member_ids[#member_ids + 1] = types_mod.find(ctx, ctx.lists:get(i))
        end
        local members = {}
        for _, mid in ipairs(member_ids) do
            members[#members + 1] = narrow_field_non_nil(ctx, mid, field_name_id)
        end
        return types_mod.make_union(ctx, members)
    end

    return tid
end

-- Apply narrowing info to create a narrowed type_id.
-- info: narrowing info from extract_narrowing
-- ty_id: the current type of the variable
-- in_truthy: true if we're in the truthy branch, false for falsy branch
--: (Ctx, NarrowInfo, integer, boolean) -> integer
local function apply_narrowing(ctx, info, ty_id, in_truthy)
    local t = types_mod.find(ctx, ty_id)

    if info.kind == "negation" then
        local inner = info.inner or info  -- non-nil: negation always has inner
        return apply_narrowing(ctx, inner, ty_id, not in_truthy)
    elseif info.kind == "nil_check" then
        -- positive=true: info says "x ~= nil" (not nil is truthy direction)
        -- in truthy branch with ~=nil: remove nil (and literal false for boolean truthiness)
        -- in falsy branch with ~=nil: keep only nil
        local should_remove_nil = (info.positive == in_truthy)
        -- If the input type is still a free TAG_VAR (e.g. for-in loop variable
        -- waiting on deferred C_BIND_GENERICS / C_INDEX), emit a deferred
        -- C_NARROW_NIL constraint so the narrowed type is computed once the
        -- input resolves.  Without this, narrowing would silently no-op.
        local tt_pre = ctx.types:get(t)
        if tt_pre.tag == TAG_VAR or tt_pre.tag == TAG_ROWVAR then
            local constrain_mod = require("lib.type.static.constrain")
            local result_tid = types_mod.make_var(ctx, ctx.scope.level)
            ctx.constraints[#ctx.constraints + 1] = {
                constrain_mod.C_NARROW_NIL, t, result_tid, not should_remove_nil,
                0, 0,
            }
            return result_tid
        end
        if should_remove_nil then
            local result = types_mod.subtract(ctx, t, ctx.T_NIL)
            -- Also subtract literal false: `if x then` means x is not nil AND not false.
            -- This only affects union(literal_true, literal_false) — TAG_BOOLEAN is unchanged.
            local false_lit = types_mod.make_literal(ctx, LIT_BOOLEAN, 0)
            return types_mod.subtract(ctx, result, false_lit)
        else
            -- Keep only nil members.
            -- For TAG_ANY, leave unchanged.
            local tt = ctx.types:get(t)
            if tt.tag == TAG_ANY then return ty_id end
            if tt.tag == TAG_UNION then
                --: { [integer]: integer, ... }
                local nil_members = {}
                for i = tt.data[0], tt.data[0] + tt.data[1] - 1 do
                    local mid = types_mod.find(ctx, ctx.lists:get(i))
                    local mt = ctx.types:get(mid)
                    if mt.tag == TAG_NIL or (mt.tag == TAG_LITERAL and mt.data[0] == LIT_NIL) then
                        nil_members[#nil_members + 1] = mid
                    end
                end
                if #nil_members == 0 then return ctx.T_NEVER end
                if #nil_members == 1 then return nil_members[1] end
                return types_mod.make_union(ctx, nil_members)
            end
            if tt.tag == TAG_NIL then return t end
            if tt.tag == TAG_LITERAL and tt.data[0] == LIT_NIL then return t end
            return ctx.T_NEVER
        end
    elseif info.kind == "field_disc" then
        local lit_intern_hi = info.lit_intern_hi --[[:! integer | nil]]
        if in_truthy == info.positive then
            -- keep members where field matches
            return types_mod.narrow_by_field(ctx, t, info.field_name_id, info.lit_intern_id, true, info.lit_kind, lit_intern_hi)
        else
            -- remove members where field matches
            return types_mod.narrow_by_field(ctx, t, info.field_name_id, info.lit_intern_id, false, info.lit_kind, lit_intern_hi)
        end
    elseif info.kind == "lit_eq" then
        local lit_tid = types_mod.make_literal(ctx, info.lit_kind, info.lit_id)
        local unify_mod = require("lib.type.static.unify")
        if in_truthy == info.positive then
            -- Truthy branch: narrow to this specific literal.
            -- From a union, keep only members that subsume the literal; then return the literal itself.
            -- From a non-union type, narrow to the literal if the type subsumes it.
            local tr = types_mod.find(ctx, ty_id)
            local tt = ctx.types:get(tr)
            if tt.tag == TAG_UNION then
                local has_match = false
                for i = tt.data[0], tt.data[0] + tt.data[1] - 1 do
                    local mid = types_mod.find(ctx, ctx.lists:get(i))
                    if unify_mod.try_unify(ctx, lit_tid, mid) then
                        has_match = true; break
                    end
                end
                if not has_match then return ctx.T_NEVER end
                return lit_tid
            else
                if unify_mod.try_unify(ctx, lit_tid, tr) then return lit_tid end
                return ctx.T_NEVER
            end
        else
            -- Falsy branch: subtract the literal from the type.
            return types_mod.subtract(ctx, ty_id, lit_tid)
        end
    elseif info.kind == "enum_eq" then
        local unify_mod = require("lib.type.static.unify")
        if in_truthy == info.positive then
            -- Truthy: narrow to this specific enum member.
            local tr = types_mod.find(ctx, ty_id)
            local tt = ctx.types:get(tr)
            if tt.tag == TAG_UNION then
                local has_match = false
                for i = tt.data[0], tt.data[0] + tt.data[1] - 1 do
                    local mid = types_mod.find(ctx, ctx.lists:get(i))
                    if unify_mod.try_unify(ctx, info.member_tid, mid) then
                        has_match = true; break
                    end
                end
                if not has_match then return ctx.T_NEVER end
            else
                if not unify_mod.try_unify(ctx, info.member_tid, tr) then
                    return ctx.T_NEVER
                end
            end
            return info.member_tid or ctx.T_NEVER
        else
            -- Falsy: subtract the enum member from the type.
            local mem_tid = info.member_tid or ctx.T_NEVER
            return types_mod.subtract(ctx, ty_id, mem_tid)
        end
    elseif info.kind == "field_presence" then
        -- positive=true: field is truthy (non-nil) when in_truthy matches.
        local field_is_nonnull = (info.positive == in_truthy)
        if field_is_nonnull then
            local fnid = info.field_name_id or 0  -- non-nil: field_presence always has field_name_id
            return narrow_field_non_nil(ctx, ty_id, fnid)
        end
        -- Conservative: don't narrow to nil in the falsy direction.
        return ty_id
    elseif info.kind == "type_check" then
        -- Build the target type
        local target_id = types_mod.typeof_to_id(ctx, info.type_str)
        local tt = ctx.types:get(t)
        if in_truthy == info.positive then
            -- Keep only members matching the type
            if tt.tag == TAG_UNION then
                --: { [integer]: integer, ... }
                local matching = {}
                for i = tt.data[0], tt.data[0] + tt.data[1] - 1 do
                    local mid = types_mod.find(ctx, ctx.lists:get(i))
                    local unify_mod = require("lib.type.static.unify")
                    if unify_mod.try_unify(ctx, mid, target_id) then matching[#matching + 1] = mid end
                end
                if #matching == 0 then return target_id end
                if #matching == 1 then return matching[1] end
                return types_mod.make_union(ctx, matching)
            end
            return target_id
        else
            -- Remove members matching the type
            return types_mod.subtract(ctx, t, target_id)
        end
    elseif info.kind == "guard_check" then
        -- User-defined type predicate: `is_str(x)` where is_str: (x: T) -> x is GuardType.
        -- Same logic as type_check but the target type is a direct type_id (not a string).
        local target_id = types_mod.find(ctx, info.guard_type_id)
        local tt = ctx.types:get(t)
        if in_truthy == info.positive then
            if tt.tag == TAG_UNION then
                --: { [integer]: integer, ... }
                local matching = {}
                local unify_mod = require("lib.type.static.unify")
                for i = tt.data[0], tt.data[0] + tt.data[1] - 1 do
                    local mid = types_mod.find(ctx, ctx.lists:get(i))
                    if unify_mod.try_unify(ctx, mid, target_id) then
                        matching[#matching + 1] = mid
                    end
                end
                if #matching == 0 then return target_id end
                if #matching == 1 then return matching[1] end
                return types_mod.make_union(ctx, matching)
            end
            return target_id
        else
            return types_mod.subtract(ctx, t, target_id)
        end
    else
        -- Unknown kind: no narrowing possible — return the type unchanged.
        return ty_id
    end
end

-- Extract the name_id targeted by a narrowing info struct.
--: (NarrowInfo) -> integer | nil
local function info_name_id(info)
    if info.kind == "nil_check" or info.kind == "type_check" or info.kind == "lit_eq"
        or info.kind == "guard_check" then
        return info.name_id
    elseif info.kind == "field_disc" then
        return info.name_id
    elseif info.kind == "field_presence" then
        return info.obj_name_id
    elseif info.kind == "enum_eq" then
        return info.name_id
    elseif info.kind == "negation" then
        local inner = info.inner
        if inner.kind == "nil_check" or inner.kind == "type_check" or inner.kind == "lit_eq"
            or inner.kind == "enum_eq" then
            return inner.name_id
        elseif inner.kind == "field_disc" then
            return inner.name_id
        elseif inner.kind == "field_presence" then
            return inner.obj_name_id
        elseif inner.kind == "guard_check" then
            return inner.name_id
        else
            -- Nested negation or unknown kind: no target name available.
            return nil
        end
    end
    return nil
end

-- Propagate correlated multi-return narrowing.
-- When a binding from a multi-return call is narrowed, re-derive sibling bindings
-- from the surviving arms of the source union-of-tuples.
-- Return true if a concrete type is considered truthy (not nil, not literal false).
-- Returns nil if uncertain (e.g. TAG_VAR — not yet solved).
--: (Ctx, integer) -> boolean | nil
local function arm_slot_truthy(ctx, tid)
    local t = ctx.types:get(types_mod.find(ctx, tid))
    if t.tag == TAG_NIL   then return false end
    if t.tag == TAG_NEVER then return false end
    if t.tag == TAG_VAR   then return nil   end  -- unresolved — skip filtering
    if t.tag == TAG_LITERAL and t.data[0] == defs.LIT_BOOLEAN and t.data[1] == 0 then
        return false  -- literal false
    end
    return true
end

--: (Ctx, integer, integer, boolean, { [integer]: integer, ... }) -> ()
local function propagate_multi_ret_narrowing(ctx, name_id, narrowed_tid, is_truthy, narrowed)
    local entry = ctx._multi_ret and ctx._multi_ret[name_id]
    if not entry then return end
    local env_mod   = require("lib.type.static.env")
    -- Filter arms based on whether the arm's slot value matches the narrowing direction.
    -- This is evaluated at constraint-gen time (types may not be solved), so we use
    -- arm_slot_truthy (works on concrete literal slots from the intrinsic) rather than
    -- try_unify against the (potentially unresolved) narrowed_tid.
    local surviving = types_mod.filter_tuple_union_arms(ctx, entry.source_tid, entry.slot,
        function(slot_tid)
            local truthy = arm_slot_truthy(ctx, slot_tid)
            if truthy == nil then return true end  -- uncertain: keep arm (conservative)
            return truthy == is_truthy
        end)
    if surviving == nil then return end
    local surviving_arms = surviving --[[: { [integer]: integer, ... }]]
    if #surviving_arms == 0 then return end
    -- Re-derive ALL correlated bindings (including name_id itself) from surviving arms.
    -- This overrides apply_narrowing's result for the primary binding when it cannot
    -- narrow an unbound TAG_VAR (e.g. string.find: slot_var subtract nil = unchanged).
    for other_id, other_entry in pairs(ctx._multi_ret) do
        if (entry.call_uid and other_entry.call_uid == entry.call_uid) or
           (not entry.call_uid and other_entry.source_tid == entry.source_tid) then
            if env_mod.lookup(ctx.scope, other_id) then
                --: { [integer]: integer, ... }
                local parts = {}
                for _, arm in ipairs(surviving_arms) do
                    local arm_t = ctx.types:get(arm)
                    if arm_t.data[1] > other_entry.slot then
                        local elem = types_mod.find(ctx,
                            ctx.lists:get(arm_t.data[0] + other_entry.slot))
                        -- Unwrap TAG_SPREAD: (true, ...R) stores TAG_SPREAD(R) at slot 1.
                        -- After if-guard narrowing, the slot value is R, not the spread.
                        local elem_t = ctx.types:get(elem)
                        if elem_t.tag == defs.TAG_SPREAD then
                            elem = types_mod.find(ctx, elem_t.data[0])
                        end
                        parts[#parts + 1] = elem
                    else
                        parts[#parts + 1] = ctx.T_NIL
                    end
                end
                if #parts == 1 then
                    narrowed[other_id] = parts[1]
                elseif #parts > 1 then
                    narrowed[other_id] = types_mod.make_union(ctx, parts)
                end
            end
        end
    end
end

-- Apply a single narrowing info to the 'narrowed' map.
-- When narrowed[name_id] already has an entry (e.g. from a prior arm of `and`/`or`),
-- apply the new narrowing to the already-narrowed type so both constraints compose.
--: (Ctx, NarrowInfo | nil, { [integer]: integer, ... }, boolean) -> ()
local function record_narrowing(ctx, info, narrowed, is_truthy)
    if not info then return end
    local name_id = info_name_id(info) or 0
    if name_id == 0 then return end
    local env_mod = require("lib.type.static.env")
    local current_ty = narrowed[name_id] or env_mod.lookup(ctx.scope, name_id)
    if not current_ty then return end
    -- Bug fix: when nil-check narrowing a variable whose flow type is nil (e.g. after
    -- `x = nil` on an `x: T | nil` annotated local), the annotation type is wider and
    -- should be used as the base for narrowing.  Otherwise `subtract(nil, nil)` → never,
    -- making the truthy branch unreachable even though the declared type admits non-nil.
    -- Only applies to nil_check narrowing; other narrowing kinds use the flow type.
    if info.kind == "nil_check" then
        local ann_ty = env_mod.lookup_annotation(ctx.scope, name_id)
        if ann_ty then
            local ct = ctx.types:get(types_mod.find(ctx, current_ty))
            local at = ctx.types:get(types_mod.find(ctx, ann_ty))
            -- Use the annotation type when the flow type is narrower:
            -- specifically when flow is nil/never and annotation is a union with non-nil.
            if (ct.tag == TAG_NIL or ct.tag == TAG_NEVER or
                (ct.tag == TAG_LITERAL and ct.data and ct.data[0] == LIT_NIL))
               and at.tag == TAG_UNION then
                current_ty = ann_ty
            end
        end
    end
    narrowed[name_id] = apply_narrowing(ctx, info, current_ty, is_truthy)
    -- Propagate correlated multi-return narrowings when any binding is narrowed.
    -- Pass the narrowing direction (is_truthy_effective) so arm filtering works at gen time.
    -- For negated infos, the effective direction is flipped.
    --: (NarrowInfo, boolean) -> boolean
    local function effective_truthy(inf, it)
        if inf.kind == "negation" then
            local inner = inf.inner or inf  -- non-nil: negation always has inner
            return effective_truthy(inner, not it)
        else
            -- All non-negation kinds: direction is unchanged.
            return it
        end
    end
    propagate_multi_ret_narrowing(ctx, name_id, narrowed[name_id],
        effective_truthy(info, is_truthy), narrowed)
end

-- Narrow a scope based on a test expression.
-- Returns a table { [name_id] -> type_id } of narrowed types.
-- is_truthy: true for truthy branch, false for falsy branch.
function M.narrow_scope(ctx, test_nid, is_truthy)
    local narrowed = {}
    local n = ctx.nodes:get(test_nid)

    -- `a and b`: in truthy branch, both a and b are true — apply both narrowings.
    -- In falsy branch, De Morgan complexity: skip (conservative).
    -- Recurse on either side that is itself an OP_AND so that chains of three
    -- or more conjuncts (`a and b and c`, parsed as `(a and b) and c`) compose
    -- their narrowings rather than dropping the inner ones.
    if n and n.kind == NODE_BINARY_EXPR and n.data[0] == OP_AND then
        if is_truthy then
            local left_nid  = n.data[1]
            local right_nid = n.data[2]
            local left_n  = ctx.nodes:get(left_nid)
            local right_n = ctx.nodes:get(right_nid)
            if left_n and left_n.kind == NODE_BINARY_EXPR and left_n.data[0] == OP_AND then
                local sub = M.narrow_scope(ctx, left_nid, true)
                for nid_, tid_ in pairs(sub) do narrowed[nid_] = tid_ end
            else
                local left_info = extract_narrowing(ctx, left_nid)
                record_narrowing(ctx, left_info, narrowed, true)
            end
            if right_n and right_n.kind == NODE_BINARY_EXPR and right_n.data[0] == OP_AND then
                local sub = M.narrow_scope(ctx, right_nid, true)
                for nid_, tid_ in pairs(sub) do narrowed[nid_] = tid_ end
            else
                local right_info = extract_narrowing(ctx, right_nid)
                record_narrowing(ctx, right_info, narrowed, true)
            end
        end
        return narrowed
    end

    -- `a or b`: in falsy branch, not (A or B) ≡ not A and not B — apply both negated narrowings.
    -- In truthy branch, either arm may be true: skip (conservative).
    -- Recurse on either side that is itself OP_OR for the same chain reason.
    if n and n.kind == NODE_BINARY_EXPR and n.data[0] == OP_OR then
        if not is_truthy then
            local left_nid  = n.data[1]
            local right_nid = n.data[2]
            local left_n  = ctx.nodes:get(left_nid)
            local right_n = ctx.nodes:get(right_nid)
            if left_n and left_n.kind == NODE_BINARY_EXPR and left_n.data[0] == OP_OR then
                local sub = M.narrow_scope(ctx, left_nid, false)
                for nid_, tid_ in pairs(sub) do narrowed[nid_] = tid_ end
            else
                local left_info = extract_narrowing(ctx, left_nid)
                record_narrowing(ctx, left_info, narrowed, false)
            end
            if right_n and right_n.kind == NODE_BINARY_EXPR and right_n.data[0] == OP_OR then
                local sub = M.narrow_scope(ctx, right_nid, false)
                for nid_, tid_ in pairs(sub) do narrowed[nid_] = tid_ end
            else
                local right_info = extract_narrowing(ctx, right_nid)
                record_narrowing(ctx, right_info, narrowed, false)
            end
        end
        return narrowed
    end

    local info = extract_narrowing(ctx, test_nid)
    record_narrowing(ctx, info, narrowed, is_truthy)
    return narrowed
end

-- Apply a single narrowing info against a given type_id, returning the narrowed type_id.
-- Exposed for constrain.lua's guard_narrowings accumulation (elseif chains).
--: (Ctx, NarrowInfo, integer, boolean) -> integer
function M.apply_narrowing_info(ctx, info, ty_id, is_truthy)
    return apply_narrowing(ctx, info, ty_id, is_truthy)
end

-- Extract narrowing info from a test expression node, without looking up types.
-- Exposed for constrain.lua to reuse per-arm narrowing info.
--: (Ctx, integer) -> NarrowInfo | nil
function M.extract_narrowing_info(ctx, nid)
    return extract_narrowing(ctx, nid)
end

-- Apply narrowed types to a scope (for if-branch entry).
--: (Ctx, { [integer]: integer, ... }) -> Scope
function M.apply_narrowed(ctx, narrowed)
    local env_mod = require("lib.type.static.env")
    local new_scope = env_mod.child(ctx.scope)
    -- Track which bindings are narrowing-derived so that lookup_declared can skip them.
    local nn = {}
    for name_id, type_id in pairs(narrowed) do
        env_mod.bind(new_scope, name_id, type_id)
        nn[name_id] = true
    end
    new_scope.narrowed_names = nn
    return new_scope
end

return M
