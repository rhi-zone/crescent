-- lib/type/static/rules/predicate_return.lua
-- Rule: a function named `is_*` or `has_*` on M should return boolean.
-- Skips test files (_test.lua).

local defs = require("lib.type.static.defs")
local intern_mod = require("lib.type.static.intern")
local types_mod = require("lib.type.static.types")
local rules = require("lib.type.static.rules")

local NODE_CHUNK       = defs.NODE_CHUNK
local NODE_ASSIGN_STMT = defs.NODE_ASSIGN_STMT
local NODE_FIELD_EXPR  = defs.NODE_FIELD_EXPR
local NODE_IDENTIFIER  = defs.NODE_IDENTIFIER

local TAG_FUNCTION = defs.TAG_FUNCTION
local TAG_BOOLEAN  = defs.TAG_BOOLEAN
local TAG_ANY      = defs.TAG_ANY
local TAG_VAR      = defs.TAG_VAR
local TAG_LITERAL  = defs.TAG_LITERAL
local LIT_BOOLEAN  = defs.LIT_BOOLEAN

local M = {}
M.name        = "predicate_return"
M.description = "functions named is_*/has_* on M should return boolean"

-- Look up the type_id for a node by its line/col in ctx.type_at.
-- Returns tid or nil if not found.
--: (ctx: Ctx, node_line: integer, node_col: integer) -> integer | nil
local function type_for_node(ctx, node_line, node_col)
    local ta = ctx.type_at
    if not ta then return nil end
    local best_tid, best_col
    local i = 1
    local n = #ta
    while i <= n do
        local eline = ta[i]
        local ecol  = ta[i + 1]
        local etid  = ta[i + 2]
        if eline == node_line then
            -- Pick the entry whose col is closest to (and <=) node_col.
            if ecol <= node_col then
                if best_col == nil or ecol >= best_col then
                    best_col = ecol
                    best_tid = etid
                end
            end
        end
        i = i + 3
    end
    return best_tid
end

-- Return true if tid represents boolean (TAG_BOOLEAN or a boolean literal).
--: (ctx: Ctx, tid: integer) -> boolean
local function is_boolean_type(ctx, tid)
    tid = types_mod.find(ctx, tid)
    local t = ctx.types:get(tid)
    if t.tag == TAG_BOOLEAN then return true end
    if t.tag == TAG_LITERAL and t.data[0] == LIT_BOOLEAN then return true end
    return false
end

--: (ctx: Ctx, err_ctx: ErrCtx, filepath: string, severity: string, errors_mod: { error: (ErrCtx, string, integer, integer, string) -> (), warning: (ErrCtx, string, integer, integer, string) -> (), ... }) -> ()
function M.check(ctx, err_ctx, filepath, severity, errors_mod)
    -- Skip test files.
    if filepath:match("_test%.lua$") then return end

    local nodes     = ctx.nodes
    local ast_lists = ctx.ast_lists
    local pool      = ctx.pool

    -- The chunk is always the last node allocated by the parser.
    local chunk = nodes:get(nodes.len - 1)
    if chunk.kind ~= NODE_CHUNK then return end

    local bs = chunk.data[0]
    local bl = chunk.data[1]

    for i = bs, bs + bl - 1 do
        local sid  = ast_lists:get(i)
        local sn   = nodes:get(sid)
        if sn.kind == NODE_ASSIGN_STMT then
            -- LHS list: data[0]=lhs_start, data[1]=lhs_len
            -- RHS list: data[2]=rhs_start, data[3]=rhs_len
            local lhs_start = sn.data[0]
            local lhs_len   = sn.data[1]
            local rhs_start = sn.data[2]
            local rhs_len   = sn.data[3]

            -- Only handle single-assignment (one LHS, one RHS) for simplicity.
            if lhs_len ~= 1 or rhs_len ~= 1 then goto continue end

            local lhs_nid = ast_lists:get(lhs_start)
            local lhs_n   = nodes:get(lhs_nid)

            -- Is this M.something?
            if lhs_n.kind ~= NODE_FIELD_EXPR then goto continue end
            local obj_nid = lhs_n.data[0]
            local obj_n   = nodes:get(obj_nid)
            if obj_n.kind ~= NODE_IDENTIFIER then goto continue end
            local obj_name = intern_mod.get(pool, obj_n.data[0]) or ""
            if obj_name ~= "M" then goto continue end

            local field_name = intern_mod.get(pool, lhs_n.data[1]) or "?"

            -- Check if field name starts with is_ or has_
            if not (field_name:sub(1, 3) == "is_" or field_name:sub(1, 4) == "has_") then
                goto continue
            end

            -- Get the RHS node and its inferred type from type_at.
            local rhs_nid = ast_lists:get(rhs_start)
            local rhs_n   = nodes:get(rhs_nid)
            local rhs_tid = type_for_node(ctx, rhs_n.line, rhs_n.col)
            if not rhs_tid then goto continue end

            rhs_tid = types_mod.find(ctx, rhs_tid)
            local rt = ctx.types:get(rhs_tid)

            -- Must be a function type.
            if rt.tag ~= TAG_FUNCTION then goto continue end

            local returns_len = rt.data[3]
            -- No return → returns () → not boolean.
            if returns_len == 0 then
                local msg = "`M." .. field_name .. "` returns `()` — predicates named `is_*`/`has_*` should return boolean"
                if severity == "error" then
                    errors_mod.error(err_ctx, filepath, sn.line, sn.col, msg)
                else
                    errors_mod.warning(err_ctx, filepath, sn.line, sn.col, msg)
                end
                goto continue
            end

            -- Check first return type.
            -- Returns are stored in the type list pool (ctx.lists), not in ast_lists.
            local ret_tid = types_mod.find(ctx, ctx.lists:get(rt.data[2]))
            local ret_t   = ctx.types:get(ret_tid)

            -- Skip unresolved (TAG_VAR) and any (TAG_ANY) — can't know.
            if ret_t.tag == TAG_VAR or ret_t.tag == TAG_ANY then goto continue end

            -- Skip if it is boolean.
            if is_boolean_type(ctx, ret_tid) then goto continue end

            -- Warn: non-boolean return from predicate.
            local ret_str = types_mod.display(ctx, ret_tid)
            local msg = "`M." .. field_name .. "` returns `" .. ret_str
                .. "` — predicates named `is_*`/`has_*` should return boolean"
            if severity == "error" then
                errors_mod.error(err_ctx, filepath, sn.line, sn.col, msg)
            else
                errors_mod.warning(err_ctx, filepath, sn.line, sn.col, msg)
            end
        end
        ::continue::
    end
end

rules.register(M.name, M)
return M
