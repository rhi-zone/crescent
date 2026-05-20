-- lib/type/static/rules/dead_locals.lua
-- Rule: a local variable that is assigned but never read within the same file.
-- Skips test files (_test.lua), underscore-prefixed names, and parameters.

local defs = require("lib.type.static.defs")
local intern_mod = require("lib.type.static.intern")
local rules = require("lib.type.static.rules")

local NODE_CHUNK       = defs.NODE_CHUNK
local NODE_LOCAL_STMT  = defs.NODE_LOCAL_STMT
local NODE_ASSIGN_STMT = defs.NODE_ASSIGN_STMT
local NODE_RETURN_STMT = defs.NODE_RETURN_STMT
local NODE_EXPR_STMT   = defs.NODE_EXPR_STMT
local NODE_DO_STMT     = defs.NODE_DO_STMT
local NODE_WHILE_STMT  = defs.NODE_WHILE_STMT
local NODE_REPEAT_STMT = defs.NODE_REPEAT_STMT
local NODE_IF_STMT     = defs.NODE_IF_STMT
local NODE_IF_CLAUSE   = defs.NODE_IF_CLAUSE
local NODE_FOR_NUM     = defs.NODE_FOR_NUM
local NODE_FOR_IN      = defs.NODE_FOR_IN
local NODE_FUNC_DECL   = defs.NODE_FUNC_DECL
local NODE_FUNC_EXPR   = defs.NODE_FUNC_EXPR
local NODE_IDENTIFIER  = defs.NODE_IDENTIFIER
local NODE_CALL_EXPR   = defs.NODE_CALL_EXPR
local NODE_METHOD_CALL = defs.NODE_METHOD_CALL
local NODE_FIELD_EXPR  = defs.NODE_FIELD_EXPR
local NODE_INDEX_EXPR  = defs.NODE_INDEX_EXPR
local NODE_UNARY_EXPR  = defs.NODE_UNARY_EXPR
local NODE_BINARY_EXPR = defs.NODE_BINARY_EXPR
local NODE_TABLE_EXPR  = defs.NODE_TABLE_EXPR
local NODE_TABLE_FIELD = defs.NODE_TABLE_FIELD

local M = {}
M.name        = "dead_locals"
M.description = "flag local variables that are assigned but never read"

-- Forward declarations for mutual recursion.
local walk_block, walk_stmt, walk_expr

-- Collect all identifier usages (NODE_IDENTIFIER) into the `uses` set.
-- uses[name_id] = true if there is at least one read of that name.
-- defs_set: name_ids that are local definitions (used to skip the def-site itself
-- when the location matches — but here we just count ALL identifier occurrences,
-- including the definition, and flag when count == 1 and that one is the def site.
-- Simpler: record every (line,col,name_id) in a flat list, then post-filter.
local function collect_id(refs, n)
    -- n is an ASTNode pointer for a NODE_IDENTIFIER
    refs[#refs + 1] = { line = n.line, col = n.col, nid = n.data[0] }
end

walk_expr = function(nodes, ast_lists, refs, nid)
    local n = nodes:get(nid)
    local k = n.kind

    if k == NODE_IDENTIFIER then
        collect_id(refs, n)
        return
    end

    if k == NODE_UNARY_EXPR then
        walk_expr(nodes, ast_lists, refs, n.data[1])
        return
    end

    if k == NODE_BINARY_EXPR then
        walk_expr(nodes, ast_lists, refs, n.data[1])
        walk_expr(nodes, ast_lists, refs, n.data[2])
        return
    end

    if k == NODE_FIELD_EXPR then
        -- data[0] = object node; data[1] = field name_id (not a node, skip)
        walk_expr(nodes, ast_lists, refs, n.data[0])
        return
    end

    if k == NODE_INDEX_EXPR then
        -- data[0] = object, data[1] = index expression
        walk_expr(nodes, ast_lists, refs, n.data[0])
        walk_expr(nodes, ast_lists, refs, n.data[1])
        return
    end

    if k == NODE_CALL_EXPR then
        -- data[0]=callee, data[1]=args_start, data[2]=args_len
        walk_expr(nodes, ast_lists, refs, n.data[0])
        for j = n.data[1], n.data[1] + n.data[2] - 1 do
            walk_expr(nodes, ast_lists, refs, ast_lists:get(j))
        end
        return
    end

    if k == NODE_METHOD_CALL then
        -- data[0]=receiver, data[1]=method_name_id (skip), data[2]=args_start, data[3]=args_len
        walk_expr(nodes, ast_lists, refs, n.data[0])
        for j = n.data[2], n.data[2] + n.data[3] - 1 do
            walk_expr(nodes, ast_lists, refs, ast_lists:get(j))
        end
        return
    end

    if k == NODE_FUNC_EXPR then
        -- params: data[0]=params_start, data[1]=params_len (name_ids, not nodes — skip)
        -- body: data[2]=body_start, data[3]=body_len
        walk_block(nodes, ast_lists, refs, n.data[2], n.data[3])
        return
    end

    if k == NODE_TABLE_EXPR then
        -- data[0]=fields_start, data[1]=fields_len
        for j = n.data[0], n.data[0] + n.data[1] - 1 do
            local fn = nodes:get(ast_lists:get(j))
            if fn.kind == NODE_TABLE_FIELD then
                -- data[2]=field_kind; only TFIELD_COMPUTED stores a key node id
                -- in data[0]. TFIELD_NAMED stores a bare intern id (no node).
                if fn.data[2] == defs.TFIELD_COMPUTED then
                    walk_expr(nodes, ast_lists, refs, fn.data[0])
                end
                walk_expr(nodes, ast_lists, refs, fn.data[1])
            end
        end
        return
    end

    -- Literals, vararg, etc.: no sub-expressions to visit.
end

walk_stmt = function(nodes, ast_lists, refs, sid)
    local sn = nodes:get(sid)
    local k = sn.kind

    if k == NODE_LOCAL_STMT then
        -- data[0]=names_start, data[1]=names_len (name_ids, not nodes — skip the LHS names)
        -- data[2]=exprs_start, data[3]=exprs_len
        for j = sn.data[2], sn.data[2] + sn.data[3] - 1 do
            walk_expr(nodes, ast_lists, refs, ast_lists:get(j))
        end
        return
    end

    if k == NODE_ASSIGN_STMT then
        -- LHS: data[0]=lhs_start, data[1]=lhs_len (these are expressions — walk them for sub-exprs)
        for j = sn.data[0], sn.data[0] + sn.data[1] - 1 do
            local lhs_n = nodes:get(ast_lists:get(j))
            -- For FIELD_EXPR/INDEX_EXPR LHS, walk the object part (not the field name).
            if lhs_n.kind == NODE_FIELD_EXPR then
                walk_expr(nodes, ast_lists, refs, lhs_n.data[0])
            elseif lhs_n.kind == NODE_INDEX_EXPR then
                walk_expr(nodes, ast_lists, refs, lhs_n.data[0])
                walk_expr(nodes, ast_lists, refs, lhs_n.data[1])
            elseif lhs_n.kind == NODE_IDENTIFIER then
                -- Reading in LHS of assignment means the variable is being written, not read.
                -- Do NOT add this as a read. (We still skip to avoid double-counting.)
            end
        end
        -- RHS: data[2]=rhs_start, data[3]=rhs_len
        for j = sn.data[2], sn.data[2] + sn.data[3] - 1 do
            walk_expr(nodes, ast_lists, refs, ast_lists:get(j))
        end
        return
    end

    if k == NODE_RETURN_STMT then
        -- data[0]=args_start, data[1]=args_len
        for j = sn.data[0], sn.data[0] + sn.data[1] - 1 do
            walk_expr(nodes, ast_lists, refs, ast_lists:get(j))
        end
        return
    end

    if k == NODE_EXPR_STMT then
        walk_expr(nodes, ast_lists, refs, sn.data[0])
        return
    end

    if k == NODE_DO_STMT then
        walk_block(nodes, ast_lists, refs, sn.data[0], sn.data[1])
        return
    end

    if k == NODE_WHILE_STMT then
        walk_expr(nodes, ast_lists, refs, sn.data[0])
        walk_block(nodes, ast_lists, refs, sn.data[1], sn.data[2])
        return
    end

    if k == NODE_REPEAT_STMT then
        walk_block(nodes, ast_lists, refs, sn.data[1], sn.data[2])
        walk_expr(nodes, ast_lists, refs, sn.data[0])
        return
    end

    if k == NODE_IF_STMT then
        for j = sn.data[0], sn.data[0] + sn.data[1] - 1 do
            local clause_nid = ast_lists:get(j)
            local clause = nodes:get(clause_nid)
            if clause.kind == NODE_IF_CLAUSE then
                walk_expr(nodes, ast_lists, refs, clause.data[0])
                walk_block(nodes, ast_lists, refs, clause.data[1], clause.data[2])
            end
        end
        -- Explicit else block (data[2]/data[3]) when FLAG_HAS_ELSE set.
        if (sn.flags % (defs.FLAG_HAS_ELSE * 2)) >= defs.FLAG_HAS_ELSE then
            walk_block(nodes, ast_lists, refs, sn.data[2], sn.data[3])
        end
        return
    end

    if k == NODE_FOR_NUM then
        -- start, limit exprs: data[1], data[2]; step: data[3] only when FLAG_HAS_STEP.
        -- body: data[4]=body_start, data[5]=body_len.
        walk_expr(nodes, ast_lists, refs, sn.data[1])
        walk_expr(nodes, ast_lists, refs, sn.data[2])
        if (sn.flags % (defs.FLAG_HAS_STEP * 2)) >= defs.FLAG_HAS_STEP then
            walk_expr(nodes, ast_lists, refs, sn.data[3])
        end
        walk_block(nodes, ast_lists, refs, sn.data[4], sn.data[5])
        return
    end

    if k == NODE_FOR_IN then
        -- exprs: data[2]=exprs_start, data[3]=exprs_len; body: data[4], data[5]
        for j = sn.data[2], sn.data[2] + sn.data[3] - 1 do
            walk_expr(nodes, ast_lists, refs, ast_lists:get(j))
        end
        walk_block(nodes, ast_lists, refs, sn.data[4], sn.data[5])
        return
    end

    if k == NODE_FUNC_DECL then
        -- body: data[3]=body_start, data[4]=body_len
        walk_block(nodes, ast_lists, refs, sn.data[3], sn.data[4])
        return
    end
end

walk_block = function(nodes, ast_lists, refs, bs, bl)
    for i = bs, bs + bl - 1 do
        local sid = ast_lists:get(i)
        walk_stmt(nodes, ast_lists, refs, sid)
    end
end

-- Collect the name_ids of all local variables declared at the top level of the chunk.
-- Returns a table: { name_id → { line, col, name_str } }
--: (ctx: Ctx, chunk: ASTNode) -> { [integer]: { line: integer, col: integer, name_str: string }, ... }
local function collect_locals(ctx, chunk)
    local nodes     = ctx.nodes
    local ast_lists = ctx.ast_lists
    local pool      = ctx.pool
    local bs = chunk.data[0]
    local bl = chunk.data[1]
    local result = {}
    for i = bs, bs + bl - 1 do
        local sid = ast_lists:get(i)
        local sn  = nodes:get(sid)
        if sn.kind == NODE_LOCAL_STMT then
            local names_start = sn.data[0]
            local names_len   = sn.data[1]
            for j = names_start, names_start + names_len - 1 do
                local name_id  = ast_lists:get(j)
                local name_str = intern_mod.get(pool, name_id) or "?"
                -- Skip underscore-prefixed names (conventional ignore marker).
                if name_str:sub(1, 1) ~= "_" then
                    result[name_id] = {
                        line     = sn.line,
                        col      = sn.col,
                        name_str = name_str,
                    }
                end
            end
        end
    end
    return result
end

--: (ctx: Ctx, err_ctx: ErrCtx, filepath: string, severity: string, errors_mod: { error: (ErrCtx, string, integer, integer, string) -> (), warning: (ErrCtx, string, integer, integer, string) -> (), ... }) -> ()
function M.check(ctx, err_ctx, filepath, severity, errors_mod)
    -- Skip test files.
    if filepath:match("_test%.lua$") then return end

    local nodes     = ctx.nodes
    local ast_lists = ctx.ast_lists

    -- The chunk is always the last node allocated by the parser.
    local chunk = nodes:get(nodes.len - 1)
    if chunk.kind ~= NODE_CHUNK then return end

    -- Collect all top-level local declarations.
    local locals = collect_locals(ctx, chunk)
    if next(locals) == nil then return end

    -- Walk the entire AST collecting all identifier references.
    local refs = {}
    walk_block(nodes, ast_lists, refs, chunk.data[0], chunk.data[1])

    -- Build a read-count per name_id.
    -- A "read" is any identifier occurrence that is NOT the definition site of that local.
    -- def_sites maps name_id → {line, col} for locals.
    local def_sites = ctx.def_sites or {}
    local reads = {}
    for _, ref in ipairs(refs) do
        local name_id = ref.nid
        if locals[name_id] then
            local ds = def_sites[name_id]
            -- If there is no def_site recorded, or this occurrence is at a different location,
            -- it counts as a read.
            if not ds or ref.line ~= ds.line or ref.col ~= ds.col then
                reads[name_id] = true
            end
        end
    end

    -- Emit warnings for locals with no reads.
    for name_id, info in pairs(locals) do
        if not reads[name_id] then
            local msg = "local `" .. info.name_str .. "` is assigned but never read"
            if severity == "error" then
                errors_mod.error(err_ctx, filepath, info.line, info.col, msg)
            else
                errors_mod.warning(err_ctx, filepath, info.line, info.col, msg)
            end
        end
    end
end

rules.register(M.name, M)
return M
