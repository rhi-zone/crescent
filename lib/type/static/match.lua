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

local LIT_STRING  = defs.LIT_STRING
local LIT_NUMBER  = defs.LIT_NUMBER
local LIT_BOOLEAN = defs.LIT_BOOLEAN

local M = {}

-- Check if `ty_id` matches `pat_id`.
-- Returns (ok, bindings_table_or_nil).
-- bindings: { [name_id] -> type_id } for named patterns (type variables).
function M.match_pattern(ctx, ty_id, pat_id)
    ty_id  = types_mod.find(ctx, ty_id)
    pat_id = types_mod.find(ctx, pat_id)

    local tt = ctx.types:get(ty_id)
    local pt = ctx.types:get(pat_id)

    -- any pattern matches everything
    if pt.tag == TAG_ANY then return true, {} end

    -- Named pattern (type variable in match context): binds
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

    return false, nil
end

-- Evaluate a match type.
-- mt_id: type_id of a TAG_MATCH_TYPE slot
-- Returns the result type_id of the first matching arm, or T_NEVER.
function M.evaluate(ctx, mt_id, seen)
    seen = seen or {}

    -- Cycle detection
    if seen[mt_id] then return ctx.T_NEVER end
    seen[mt_id] = true

    local mt = ctx.types:get(mt_id)
    if mt.tag ~= TAG_MATCH_TYPE then return ctx.T_NEVER end

    local param_id = types_mod.find(ctx, mt.data[0])
    local arms_start = mt.data[1]
    local arms_len   = mt.data[2]

    local i = arms_start
    while i < arms_start + arms_len - 1 do
        local pat_id = ctx.lists:get(i)
        local res_id = ctx.lists:get(i + 1)
        local ok, bindings = M.match_pattern(ctx, param_id, pat_id)
        if ok then
            if bindings and next(bindings) then
                -- Substitute bindings into result
                local env_mod = require("lib.type.static.env")
                return env_mod.substitute(ctx, res_id, bindings)
            end
            return res_id
        end
        i = i + 2
    end

    seen[mt_id] = nil
    return ctx.T_NEVER
end

return M
