-- lib/type/static/rules/naming.lua
-- Rule: naming convention violations.
-- Checks:
--   1. Module variable must be `M` (file must have `local M = {}`).
--   2. M.create / M.destroy / M.free / M.release / M.delete are banned
--      in favour of M.new / M:close().

local defs = require("lib.type.static.defs")
local intern_mod = require("lib.type.static.intern")
local rules = require("lib.type.static.rules")

local NODE_CHUNK       = defs.NODE_CHUNK
local NODE_LOCAL_STMT  = defs.NODE_LOCAL_STMT
local NODE_TABLE_EXPR  = defs.NODE_TABLE_EXPR
local NODE_ASSIGN_STMT = defs.NODE_ASSIGN_STMT
local NODE_FIELD_EXPR  = defs.NODE_FIELD_EXPR
local NODE_IDENTIFIER  = defs.NODE_IDENTIFIER
local NODE_FUNC_DECL   = defs.NODE_FUNC_DECL

-- Banned export names → suggested replacement.
local BANNED = {
    create  = "M.new",
    destroy = "M:close()",
    free    = "M:close()",
    release = "M:close()",
    delete  = "M:close()",
}

local M = {}
M.name        = "naming"
M.description = "naming convention violations: module must be M; M.create/destroy/free/release/delete banned"

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

    local M_id = intern_mod.intern(pool, "M")

    -- Pass 1: check that `local M = {}` exists at the top level.
    -- Also collect the name_id of the actual module variable to use in pass 2
    -- (could be anything, but the rule only checks for the string "M").
    local has_M = false
    for i = bs, bs + bl - 1 do
        local sid = ast_lists:get(i)
        local sn  = nodes:get(sid)
        -- `local M = {}` → NODE_LOCAL_STMT, names_len=1, exprs_len=1, rhs is TABLE_EXPR
        if sn.kind == NODE_LOCAL_STMT and sn.data[1] == 1 then
            local name_id = ast_lists:get(sn.data[0])
            if name_id == M_id then
                has_M = true
            end
        end
    end

    if not has_M then
        local msg = "module variable not named `M` — add `local M = {}` at top level"
        if severity == "error" then
            errors_mod.error(err_ctx, filepath, 1, 1, msg)
        else
            errors_mod.warning(err_ctx, filepath, 1, 1, msg)
        end
        -- Still continue to check banned names even without M declaration.
    end

    -- Pass 2: check for banned M.* names in ASSIGN_STMT and FUNC_DECL.
    for i = bs, bs + bl - 1 do
        local sid = ast_lists:get(i)
        local sn  = nodes:get(sid)

        -- ASSIGN_STMT: M.name = value
        if sn.kind == NODE_ASSIGN_STMT then
            local lhs_start = sn.data[0]
            local lhs_len   = sn.data[1]
            for j = lhs_start, lhs_start + lhs_len - 1 do
                local lhs_nid = ast_lists:get(j)
                local lhs_n   = nodes:get(lhs_nid)
                if lhs_n.kind == NODE_FIELD_EXPR then
                    local obj_n = nodes:get(lhs_n.data[0])
                    if obj_n.kind == NODE_IDENTIFIER and obj_n.data[0] == M_id then
                        local fname = intern_mod.get(pool, lhs_n.data[1]) or ""
                        local alt = BANNED[fname]
                        if alt then
                            local msg = "`M." .. fname .. "` — use `" .. alt .. "` instead"
                            if severity == "error" then
                                errors_mod.error(err_ctx, filepath, sn.line, sn.col, msg)
                            else
                                errors_mod.warning(err_ctx, filepath, sn.line, sn.col, msg)
                            end
                        end
                    end
                end
            end

        -- FUNC_DECL: function M.name(...) or function M:name(...)
        elseif sn.kind == NODE_FUNC_DECL then
            local name_nid = sn.data[0]
            local name_n   = nodes:get(name_nid)
            if name_n.kind == NODE_FIELD_EXPR then
                local obj_n = nodes:get(name_n.data[0])
                if obj_n.kind == NODE_IDENTIFIER and obj_n.data[0] == M_id then
                    local fname = intern_mod.get(pool, name_n.data[1]) or ""
                    local alt = BANNED[fname]
                    if alt then
                        local msg = "`M." .. fname .. "` — use `" .. alt .. "` instead"
                        if severity == "error" then
                            errors_mod.error(err_ctx, filepath, sn.line, sn.col, msg)
                        else
                            errors_mod.warning(err_ctx, filepath, sn.line, sn.col, msg)
                        end
                    end
                end
            end
        end
    end
end

rules.register(M.name, M)
return M
