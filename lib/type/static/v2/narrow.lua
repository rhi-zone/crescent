-- lib/type/static/v2/narrow.lua
-- Control flow narrowing for the v2 typechecker.
-- Extracts type narrowing information from if/while/repeat test expressions.

local defs = require("lib.type.static.v2.defs")
local types_mod = require("lib.type.static.v2.types")
local intern_mod = require("lib.type.static.v2.intern")

local NODE_BINARY_EXPR = defs.NODE_BINARY_EXPR
local NODE_UNARY_EXPR  = defs.NODE_UNARY_EXPR
local NODE_CALL_EXPR   = defs.NODE_CALL_EXPR
local NODE_IDENTIFIER  = defs.NODE_IDENTIFIER
local NODE_FIELD_EXPR  = defs.NODE_FIELD_EXPR

local OP_EQ = defs.OP_EQ
local OP_NE = defs.OP_NE
local OP_NOT = defs.OP_NOT

local TAG_ANY  = defs.TAG_ANY
local TAG_NIL  = defs.TAG_NIL
local TAG_UNION = defs.TAG_UNION
local TAG_LITERAL = defs.TAG_LITERAL
local TAG_STRING  = defs.TAG_STRING
local LIT_NIL     = defs.LIT_NIL
local LIT_STRING  = defs.LIT_STRING

local M = {}

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
local function extract_narrowing(ctx, nid)
    local n = ctx.nodes:get(nid)
    if not n then return nil end

    if n.kind == NODE_UNARY_EXPR and n.data[0] == OP_NOT then
        local inner = extract_narrowing(ctx, n.data[1])
        if inner then
            return { kind = "negation", inner = inner }
        end
        return nil
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

        -- x.field == "literal"
        if lhs and lhs.kind == NODE_FIELD_EXPR then
            local obj = ctx.nodes:get(lhs.data[0])
            if obj and obj.kind == NODE_IDENTIFIER then
                if rhs and rhs.kind == defs.NODE_LITERAL and rhs.data[0] == LIT_STRING then
                    local positive = (op == OP_EQ)
                    return {
                        kind = "field_disc",
                        name_id = obj.data[0],
                        field_name_id = lhs.data[1],
                        lit_intern_id = rhs.data[1],
                        positive = positive,
                    }
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
                    local arg_nid = ctx.lists:get(lhs.data[1])
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

-- Apply narrowing info to create a narrowed type_id.
-- info: narrowing info from extract_narrowing
-- ty_id: the current type of the variable
-- in_truthy: true if we're in the truthy branch, false for falsy branch
local function apply_narrowing(ctx, info, ty_id, in_truthy)
    local t = types_mod.find(ctx, ty_id)

    if info.kind == "negation" then
        return apply_narrowing(ctx, info.inner, ty_id, not in_truthy)
    end

    if info.kind == "nil_check" then
        -- positive=true: info says "x ~= nil" (not nil is truthy direction)
        -- in truthy branch with ~=nil: remove nil
        -- in falsy branch with ~=nil: keep only nil
        local should_remove_nil = (info.positive == in_truthy)
        if should_remove_nil then
            return types_mod.subtract(ctx, t, ctx.T_NIL)
        else
            -- Keep only nil members
            local tt = ctx.types:get(t)
            if tt.tag == TAG_UNION then
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
    end

    if info.kind == "field_disc" then
        if in_truthy == info.positive then
            -- keep members where field matches
            return types_mod.narrow_by_field(ctx, t, info.field_name_id, info.lit_intern_id, true)
        else
            -- remove members where field matches
            return types_mod.narrow_by_field(ctx, t, info.field_name_id, info.lit_intern_id, false)
        end
    end

    if info.kind == "type_check" then
        -- Build the target type
        local target_id = types_mod.typeof_to_id(ctx, info.type_str)
        local tt = ctx.types:get(t)
        if in_truthy == info.positive then
            -- Keep only members matching the type
            if tt.tag == TAG_UNION then
                local matching = {}
                for i = tt.data[0], tt.data[0] + tt.data[1] - 1 do
                    local mid = types_mod.find(ctx, ctx.lists:get(i))
                    local unify_mod = require("lib.type.static.v2.unify")
                    local _, ok = unify_mod.try_unify(ctx, mid, target_id)
                    if ok then matching[#matching + 1] = mid end
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
    end

    return ty_id
end

-- Narrow a scope based on a test expression.
-- Returns a table { [name_id] -> type_id } of narrowed types.
-- is_truthy: true for truthy branch, false for falsy branch.
function M.narrow_scope(ctx, test_nid, is_truthy)
    local narrowed = {}
    local info = extract_narrowing(ctx, test_nid)
    if not info then return narrowed end

    local name_id
    if info.kind == "nil_check" or info.kind == "type_check" then
        name_id = info.name_id
    elseif info.kind == "field_disc" then
        name_id = info.name_id
    elseif info.kind == "negation" then
        -- Let apply_narrowing handle the inversion
        local inner = info.inner
        if inner.kind == "nil_check" or inner.kind == "type_check" then
            name_id = inner.name_id
        elseif inner.kind == "field_disc" then
            name_id = inner.name_id
        end
    end

    if not name_id then return narrowed end

    local env_mod = require("lib.type.static.v2.env")
    local current_ty = env_mod.lookup(ctx.scope, name_id)
    if not current_ty then return narrowed end

    local narrowed_ty = apply_narrowing(ctx, info, current_ty, is_truthy)
    narrowed[name_id] = narrowed_ty
    return narrowed
end

-- Apply narrowed types to a scope (for if-branch entry).
function M.apply_narrowed(ctx, narrowed)
    local env_mod = require("lib.type.static.v2.env")
    local new_scope = env_mod.child(ctx.scope)
    for name_id, type_id in pairs(narrowed) do
        env_mod.bind(new_scope, name_id, type_id)
    end
    return new_scope
end

return M
