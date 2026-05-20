-- lib/type/static/rules/assert_in_lib.lua
-- Rule: flag assert() calls in non-test library code.
-- assert() should not be used in library code; prefer `if not x then return nil, err end`.
-- Skips test files (_test.lua).

local defs = require("lib.type.static.defs")
local intern_mod = require("lib.type.static.intern")
local rules = require("lib.type.static.rules")

local NODE_CHUNK       = defs.NODE_CHUNK
local NODE_CALL_EXPR   = defs.NODE_CALL_EXPR
local NODE_METHOD_CALL = defs.NODE_METHOD_CALL
local NODE_EXPR_STMT   = defs.NODE_EXPR_STMT
local NODE_IDENTIFIER  = defs.NODE_IDENTIFIER
local NODE_LOCAL_STMT  = defs.NODE_LOCAL_STMT
local NODE_ASSIGN_STMT = defs.NODE_ASSIGN_STMT
local NODE_IF_STMT     = defs.NODE_IF_STMT
local NODE_IF_CLAUSE   = defs.NODE_IF_CLAUSE
local NODE_WHILE_STMT  = defs.NODE_WHILE_STMT
local NODE_REPEAT_STMT = defs.NODE_REPEAT_STMT
local NODE_FOR_NUM     = defs.NODE_FOR_NUM
local NODE_FOR_IN      = defs.NODE_FOR_IN
local NODE_DO_STMT     = defs.NODE_DO_STMT
local NODE_RETURN_STMT = defs.NODE_RETURN_STMT
local NODE_FUNC_DECL   = defs.NODE_FUNC_DECL
local NODE_FUNC_EXPR   = defs.NODE_FUNC_EXPR

local M = {}
M.name        = "assert_in_lib"
M.description = "flag assert() calls in non-test library code"

-- Forward declarations for mutual recursion.
local walk_block, walk_stmt, walk_expr

--: (ctx: Ctx, nid: integer, err_ctx: ErrCtx, filepath: string, severity: string, errors_mod: { error: (ErrCtx, string, integer, integer, string) -> (), warning: (ErrCtx, string, integer, integer, string) -> (), ... }, assert_id: integer) -> ()
walk_expr = function(ctx, nid, err_ctx, filepath, severity, errors_mod, assert_id)
    local nodes     = ctx.nodes
    local ast_lists = ctx.ast_lists
    local n = nodes:get(nid)

    if n.kind == NODE_CALL_EXPR then
        local callee_nid = n.data[0]
        local callee_n   = nodes:get(callee_nid)
        if callee_n.kind == NODE_IDENTIFIER and callee_n.data[0] == assert_id then
            local msg = "`assert()` forbidden in library code"
                .. " \xe2\x80\x94 use `if not x then return nil, err end`"
            if severity == "error" then
                errors_mod.error(err_ctx, filepath, n.line, n.col, msg)
            else
                errors_mod.warning(err_ctx, filepath, n.line, n.col, msg)
            end
        end
        -- Walk arguments.
        for j = n.data[1], n.data[1] + n.data[2] - 1 do
            walk_expr(ctx, ast_lists:get(j), err_ctx, filepath, severity, errors_mod, assert_id)
        end
        -- Also walk the callee in case it is itself a call expression.
        if callee_n.kind == NODE_CALL_EXPR or callee_n.kind == NODE_METHOD_CALL
                or callee_n.kind == NODE_FUNC_EXPR then
            walk_expr(ctx, callee_nid, err_ctx, filepath, severity, errors_mod, assert_id)
        end

    elseif n.kind == NODE_FUNC_EXPR then
        -- body: data[2]=body_start, data[3]=body_len
        walk_block(ctx, n.data[2], n.data[3], err_ctx, filepath, severity, errors_mod, assert_id)

    elseif n.kind == NODE_METHOD_CALL then
        -- data[0]=receiver, data[2]=args_start, data[3]=args_len
        walk_expr(ctx, n.data[0], err_ctx, filepath, severity, errors_mod, assert_id)
        for j = n.data[2], n.data[2] + n.data[3] - 1 do
            walk_expr(ctx, ast_lists:get(j), err_ctx, filepath, severity, errors_mod, assert_id)
        end
    end
    -- Leaf nodes (LITERAL, IDENTIFIER, etc.) have no children to recurse into.
end

--: (ctx: Ctx, sid: integer, err_ctx: ErrCtx, filepath: string, severity: string, errors_mod: { error: (ErrCtx, string, integer, integer, string) -> (), warning: (ErrCtx, string, integer, integer, string) -> (), ... }, assert_id: integer) -> ()
walk_stmt = function(ctx, sid, err_ctx, filepath, severity, errors_mod, assert_id)
    local nodes     = ctx.nodes
    local ast_lists = ctx.ast_lists
    local sn = nodes:get(sid)

    if sn.kind == NODE_EXPR_STMT then
        walk_expr(ctx, sn.data[0], err_ctx, filepath, severity, errors_mod, assert_id)

    elseif sn.kind == NODE_LOCAL_STMT then
        -- data[2]=exprs_start, data[3]=exprs_len
        for j = sn.data[2], sn.data[2] + sn.data[3] - 1 do
            walk_expr(ctx, ast_lists:get(j), err_ctx, filepath, severity, errors_mod, assert_id)
        end

    elseif sn.kind == NODE_ASSIGN_STMT then
        -- RHS: data[2]=rhs_start, data[3]=rhs_len
        for j = sn.data[2], sn.data[2] + sn.data[3] - 1 do
            walk_expr(ctx, ast_lists:get(j), err_ctx, filepath, severity, errors_mod, assert_id)
        end

    elseif sn.kind == NODE_RETURN_STMT then
        -- data[0]=args_start, data[1]=args_len
        for j = sn.data[0], sn.data[0] + sn.data[1] - 1 do
            walk_expr(ctx, ast_lists:get(j), err_ctx, filepath, severity, errors_mod, assert_id)
        end

    elseif sn.kind == NODE_IF_STMT then
        -- data[0]=tests_start, data[1]=tests_len (IF_CLAUSE list, IF + ELSEIF only)
        for j = sn.data[0], sn.data[0] + sn.data[1] - 1 do
            local clause_nid = ast_lists:get(j)
            local clause = nodes:get(clause_nid)
            if clause.kind == NODE_IF_CLAUSE then
                -- data[0]=test_nid, data[1]=body_start, data[2]=body_len
                walk_expr(ctx, clause.data[0], err_ctx, filepath, severity, errors_mod, assert_id)
                walk_block(ctx, clause.data[1], clause.data[2], err_ctx, filepath, severity, errors_mod, assert_id)
            end
        end
        -- Explicit else block (data[2]/data[3]) when FLAG_HAS_ELSE set.
        if (sn.flags % (defs.FLAG_HAS_ELSE * 2)) >= defs.FLAG_HAS_ELSE then
            walk_block(ctx, sn.data[2], sn.data[3], err_ctx, filepath, severity, errors_mod, assert_id)
        end

    elseif sn.kind == NODE_DO_STMT then
        walk_block(ctx, sn.data[0], sn.data[1], err_ctx, filepath, severity, errors_mod, assert_id)

    elseif sn.kind == NODE_WHILE_STMT then
        walk_expr(ctx, sn.data[0], err_ctx, filepath, severity, errors_mod, assert_id)
        walk_block(ctx, sn.data[1], sn.data[2], err_ctx, filepath, severity, errors_mod, assert_id)

    elseif sn.kind == NODE_REPEAT_STMT then
        walk_block(ctx, sn.data[1], sn.data[2], err_ctx, filepath, severity, errors_mod, assert_id)
        walk_expr(ctx, sn.data[0], err_ctx, filepath, severity, errors_mod, assert_id)

    elseif sn.kind == NODE_FOR_NUM then
        -- body: data[4]=body_start, data[5]=body_len
        walk_block(ctx, sn.data[4], sn.data[5], err_ctx, filepath, severity, errors_mod, assert_id)

    elseif sn.kind == NODE_FOR_IN then
        -- exprs: data[2]=exprs_start, data[3]=exprs_len; body: data[4], data[5]
        for j = sn.data[2], sn.data[2] + sn.data[3] - 1 do
            walk_expr(ctx, ast_lists:get(j), err_ctx, filepath, severity, errors_mod, assert_id)
        end
        walk_block(ctx, sn.data[4], sn.data[5], err_ctx, filepath, severity, errors_mod, assert_id)

    elseif sn.kind == NODE_FUNC_DECL then
        -- body: data[3]=body_start, data[4]=body_len
        walk_block(ctx, sn.data[3], sn.data[4], err_ctx, filepath, severity, errors_mod, assert_id)
    end
end

--: (ctx: Ctx, bs: integer, bl: integer, err_ctx: ErrCtx, filepath: string, severity: string, errors_mod: { error: (ErrCtx, string, integer, integer, string) -> (), warning: (ErrCtx, string, integer, integer, string) -> (), ... }, assert_id: integer) -> ()
walk_block = function(ctx, bs, bl, err_ctx, filepath, severity, errors_mod, assert_id)
    local ast_lists = ctx.ast_lists
    for i = bs, bs + bl - 1 do
        local sid = ast_lists:get(i)
        walk_stmt(ctx, sid, err_ctx, filepath, severity, errors_mod, assert_id)
    end
end

--: (ctx: Ctx, err_ctx: ErrCtx, filepath: string, severity: string, errors_mod: { error: (ErrCtx, string, integer, integer, string) -> (), warning: (ErrCtx, string, integer, integer, string) -> (), ... }) -> ()
function M.check(ctx, err_ctx, filepath, severity, errors_mod)
    -- Skip test files.
    if filepath:match("_test%.lua$") then return end

    local pool = ctx.pool
    -- Intern "assert" to get its name ID. If it's never been interned in this
    -- session pool it definitely won't appear in the AST — but intern() is safe
    -- to call regardless (it just adds the string, never returns a stale ID).
    local assert_id = intern_mod.intern(pool, "assert")

    local nodes = ctx.nodes
    -- The chunk is always the last node allocated by the parser.
    local chunk = nodes:get(nodes.len - 1)
    if chunk.kind ~= NODE_CHUNK then return end

    walk_block(ctx, chunk.data[0], chunk.data[1], err_ctx, filepath, severity, errors_mod, assert_id)
end

rules.register(M.name, M)
return M
