-- lib/type/static/rules/unannotated.lua
-- Rule: flag public exports (M.name = ...) without a preceding --: annotation.
-- Skips test files (_test.lua).

local defs = require("lib.type.static.defs")
local intern_mod = require("lib.type.static.intern")
local rules = require("lib.type.static.rules")

local NODE_CHUNK       = defs.NODE_CHUNK
local NODE_ASSIGN_STMT = defs.NODE_ASSIGN_STMT
local NODE_FIELD_EXPR  = defs.NODE_FIELD_EXPR
local NODE_IDENTIFIER  = defs.NODE_IDENTIFIER
local ANN_TYPE         = defs.ANN_TYPE

local M = {}
M.name        = "unannotated"
M.description = "flag public exports (M.name = ...) without a --: annotation"

--: (ctx: Ctx, err_ctx: ErrCtx, filepath: string, severity: string, errors_mod: { error: (ErrCtx, string, integer, integer, string) -> (), warning: (ErrCtx, string, integer, integer, string) -> (), ... }) -> ()
function M.check(ctx, err_ctx, filepath, severity, errors_mod)
    -- Skip test files.
    if filepath:match("_test%.lua$") then return end

    local nodes     = ctx.nodes
    local ast_lists = ctx.ast_lists
    local pool      = ctx.pool
    local ann       = ctx.ann

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
            local lhs_start = sn.data[0]
            local lhs_len   = sn.data[1]
            for j = lhs_start, lhs_start + lhs_len - 1 do
                local lhs_nid = ast_lists:get(j)
                local lhs_n   = nodes:get(lhs_nid)
                -- Is this M.something?
                if lhs_n.kind == NODE_FIELD_EXPR then
                    local obj_nid  = lhs_n.data[0]
                    local obj_n    = nodes:get(obj_nid)
                    if obj_n.kind == NODE_IDENTIFIER then
                        local obj_name = intern_mod.get(pool, obj_n.data[0]) or ""
                        if obj_name == "M" then
                            local field_name = intern_mod.get(pool, lhs_n.data[1]) or "?"
                            -- Check for annotation on this line or the preceding line.
                            local line = sn.line
                            local has_ann = false
                            if ann and ann.results then
                                local r  = ann.results[line]
                                local r1 = ann.results[line - 1]
                                if (r  and r.kind  == ANN_TYPE) or
                                   (r1 and r1.kind == ANN_TYPE) then
                                    has_ann = true
                                end
                            end
                            if not has_ann then
                                local msg = "public export `" .. field_name
                                    .. "` has no type annotation"
                                if severity == "error" then
                                    errors_mod.error(err_ctx, filepath,
                                        line, sn.col, msg)
                                else
                                    errors_mod.warning(err_ctx, filepath,
                                        line, sn.col, msg)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

rules.register(M.name, M)
return M
