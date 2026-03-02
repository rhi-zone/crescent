-- lib/type/static/v2/infer.lua
-- AST walker for the v2 typechecker.
--
-- Two list pools:
--   ctx.lists     = type list pool  (write: type construction via types_mod)
--   ctx.ast_lists = AST list pool   (read: node IDs, param IDs, stmt IDs from parser)
--
-- All AST traversal uses ctx.ast_lists:get(i).
-- All type construction uses ctx.lists (via types_mod helpers).

local defs     = require("lib.type.static.v2.defs")
local types_mod = require("lib.type.static.v2.types")
local env_mod   = require("lib.type.static.v2.env")
local unify_mod = require("lib.type.static.v2.unify")
local errors_mod = require("lib.type.static.v2.errors")
local intern_mod = require("lib.type.static.v2.intern")
local ann_mod    = require("lib.type.static.v2.ann")

local NODE_LITERAL     = defs.NODE_LITERAL
local NODE_IDENTIFIER  = defs.NODE_IDENTIFIER
local NODE_UNARY_EXPR  = defs.NODE_UNARY_EXPR
local NODE_BINARY_EXPR = defs.NODE_BINARY_EXPR
local NODE_INDEX_EXPR  = defs.NODE_INDEX_EXPR
local NODE_FIELD_EXPR  = defs.NODE_FIELD_EXPR
local NODE_METHOD_CALL = defs.NODE_METHOD_CALL
local NODE_CALL_EXPR   = defs.NODE_CALL_EXPR
local NODE_FUNC_EXPR   = defs.NODE_FUNC_EXPR
local NODE_TABLE_EXPR  = defs.NODE_TABLE_EXPR
local NODE_TABLE_FIELD = defs.NODE_TABLE_FIELD
local NODE_VARARG_EXPR = defs.NODE_VARARG_EXPR
local NODE_ASSIGN_STMT = defs.NODE_ASSIGN_STMT
local NODE_LOCAL_STMT  = defs.NODE_LOCAL_STMT
local NODE_DO_STMT     = defs.NODE_DO_STMT
local NODE_WHILE_STMT  = defs.NODE_WHILE_STMT
local NODE_REPEAT_STMT = defs.NODE_REPEAT_STMT
local NODE_IF_STMT     = defs.NODE_IF_STMT
local NODE_IF_CLAUSE   = defs.NODE_IF_CLAUSE
local NODE_FOR_NUM     = defs.NODE_FOR_NUM
local NODE_FOR_IN      = defs.NODE_FOR_IN
local NODE_RETURN_STMT = defs.NODE_RETURN_STMT
local NODE_BREAK_STMT  = defs.NODE_BREAK_STMT
local NODE_EXPR_STMT   = defs.NODE_EXPR_STMT
local NODE_FUNC_DECL   = defs.NODE_FUNC_DECL
local NODE_CHUNK       = defs.NODE_CHUNK

local LIT_STRING  = defs.LIT_STRING
local LIT_NUMBER  = defs.LIT_NUMBER
local LIT_BOOLEAN = defs.LIT_BOOLEAN
local LIT_NIL     = defs.LIT_NIL

local OP_ADD    = defs.OP_ADD
local OP_SUB    = defs.OP_SUB
local OP_MUL    = defs.OP_MUL
local OP_DIV    = defs.OP_DIV
local OP_MOD    = defs.OP_MOD
local OP_POW    = defs.OP_POW
local OP_CONCAT = defs.OP_CONCAT
local OP_EQ     = defs.OP_EQ
local OP_NE     = defs.OP_NE
local OP_LT     = defs.OP_LT
local OP_LE     = defs.OP_LE
local OP_GT     = defs.OP_GT
local OP_GE     = defs.OP_GE
local OP_AND    = defs.OP_AND
local OP_OR     = defs.OP_OR
local OP_UNM    = defs.OP_UNM
local OP_NOT    = defs.OP_NOT
local OP_LEN    = defs.OP_LEN

local FLAG_LOCAL    = defs.FLAG_LOCAL
local FLAG_VARARG   = defs.FLAG_VARARG
local FLAG_COMPUTED = defs.FLAG_COMPUTED

local ANN_TYPE      = defs.ANN_TYPE
local ANN_DECL      = defs.ANN_DECL

local TAG_ANY      = defs.TAG_ANY
local TAG_NIL      = defs.TAG_NIL
local TAG_NUMBER   = defs.TAG_NUMBER
local TAG_INTEGER  = defs.TAG_INTEGER
local TAG_STRING   = defs.TAG_STRING
local TAG_LITERAL  = defs.TAG_LITERAL
local TAG_FUNCTION = defs.TAG_FUNCTION
local TAG_TABLE    = defs.TAG_TABLE
local TAG_UNION    = defs.TAG_UNION
local TAG_VAR      = defs.TAG_VAR
local TAG_ROWVAR   = defs.TAG_ROWVAR
local TAG_NAMED    = defs.TAG_NAMED
local TAG_NOMINAL  = defs.TAG_NOMINAL
local TAG_MATCH_TYPE = defs.TAG_MATCH_TYPE
local TAG_FORALL   = defs.TAG_FORALL
local TAG_INTRINSIC = defs.TAG_INTRINSIC
local TAG_TYPE_CALL = defs.TAG_TYPE_CALL
local TAG_TUPLE    = defs.TAG_TUPLE
local TAG_SPREAD   = defs.TAG_SPREAD
local TAG_NEVER    = defs.TAG_NEVER

local M = {}

---------------------------------------------------------------------------
-- Context helpers
---------------------------------------------------------------------------

local function report(ctx, line, col, msg)
    errors_mod.error(ctx.err, ctx.filename, line or 0, col or 0, msg)
end

-- stub_ret_vars: optional array of TAG_VAR type IDs from the prescan stub.
-- When provided, add_return eagerly binds them so recursive calls within
-- this function body see the correct return type immediately via find().
local function push_return_collector(ctx, stub_ret_vars)
    ctx.return_types[#ctx.return_types + 1] = {}
    ctx.return_stub_vars[#ctx.return_stub_vars + 1] = stub_ret_vars or false
end

local function pop_return_collector(ctx)
    local c = ctx.return_types[#ctx.return_types]
    ctx.return_types[#ctx.return_types] = nil
    ctx.return_stub_vars[#ctx.return_stub_vars] = nil
    return c
end

local function add_return(ctx, type_ids)
    local c = ctx.return_types[#ctx.return_types]
    if not c then return end
    c[#c + 1] = type_ids
    -- Eagerly bind the prescan stub's return vars so recursive calls within
    -- this function body get the correct return type via find().
    local stub_vars = ctx.return_stub_vars[#ctx.return_stub_vars]
    if stub_vars then
        for j, rv in ipairs(stub_vars) do
            rv = types_mod.find(ctx, rv)
            if ctx.types:get(rv).tag == TAG_VAR then
                unify_mod.unify(ctx, type_ids[j] or ctx.T_NIL, rv)
            end
        end
    end
end

---------------------------------------------------------------------------
-- Annotation helpers
---------------------------------------------------------------------------

local function get_ann(ctx, line)
    if not ctx.ann then return nil end
    return ctx.ann.results[line] or ctx.ann.results[line - 1]
end

-- Forward declarations
local infer_expr, infer_stmt, infer_block, infer_function, resolve_annotation_type, prescan_block

-- Translate annotation type_id (from ann_ctx.types) into a checker type_id.
-- Uses ctx.ann.types/fields/lists for reading, ctx.types/fields/lists for writing.
resolve_annotation_type = function(ctx, ann_tid, seen)
    if not ctx.ann then return ctx.T_ANY end
    seen = seen or {}
    if seen[ann_tid] then return ctx.T_ANY end

    -- Read from annotation arena
    local at = ctx.ann.types:get(ann_tid)
    if not at then return ctx.T_ANY end
    local tag = at.tag

    -- Primitives → singletons
    if tag == defs.TAG_NIL      then return ctx.T_NIL end
    if tag == defs.TAG_BOOLEAN  then return ctx.T_BOOLEAN end
    if tag == defs.TAG_NUMBER   then return ctx.T_NUMBER end
    if tag == defs.TAG_STRING   then return ctx.T_STRING end
    if tag == defs.TAG_ANY      then return ctx.T_ANY end
    if tag == defs.TAG_NEVER    then return ctx.T_NEVER end
    if tag == defs.TAG_INTEGER  then return ctx.T_INTEGER end
    if tag == defs.TAG_CDATA    then
        local id = types_mod.alloc_type(ctx, defs.TAG_CDATA)
        return id
    end

    if tag == TAG_LITERAL then
        return types_mod.make_literal(ctx, at.data[0], at.data[1])
    end

    if tag == TAG_ROWVAR then
        return types_mod.make_rowvar(ctx, ctx.scope.level)
    end

    if tag == TAG_NAMED then
        local name_id = at.data[0]
        local args_len = at.data[2]
        local arg_ids = nil
        if args_len > 0 then
            seen[ann_tid] = true
            arg_ids = {}
            for i = at.data[1], at.data[1] + args_len - 1 do
                arg_ids[#arg_ids + 1] = resolve_annotation_type(ctx, ctx.ann.lists:get(i), seen)
            end
            seen[ann_tid] = nil
        end
        local resolved = env_mod.resolve_named_type(ctx, ctx.scope, name_id, arg_ids)
        if resolved then
            -- resolved is already a checker type_id
            return resolved
        end
        -- Unknown named type — keep as named ref
        local id = types_mod.alloc_type(ctx, TAG_NAMED)
        ctx.types:get(id).data[0] = name_id
        return id
    end

    if tag == TAG_FUNCTION then
        seen[ann_tid] = true
        local params = {}
        for i = at.data[0], at.data[0] + at.data[1] - 1 do
            params[#params + 1] = resolve_annotation_type(ctx, ctx.ann.lists:get(i), seen)
        end
        local returns = {}
        for i = at.data[2], at.data[2] + at.data[3] - 1 do
            returns[#returns + 1] = resolve_annotation_type(ctx, ctx.ann.lists:get(i), seen)
        end
        local vararg_id = -1
        if at.data[4] >= 0 then
            vararg_id = resolve_annotation_type(ctx, at.data[4], seen)
        end
        seen[ann_tid] = nil
        return types_mod.make_func(ctx, params, returns, vararg_id)
    end

    if tag == TAG_TABLE then
        seen[ann_tid] = true
        local field_ids = {}
        for i = at.data[0], at.data[0] + at.data[1] - 1 do
            local fid = ctx.ann.lists:get(i)
            local fe  = ctx.ann.fields:get(fid)
            local ft  = resolve_annotation_type(ctx, fe.type_id, seen)
            field_ids[#field_ids + 1] = types_mod.make_field(ctx, fe.name_id, ft, fe.optional == 1)
        end
        local indexers = {}
        local is, il = at.data[2], at.data[3]
        local i = is
        while i < is + il - 1 do
            indexers[#indexers + 1] = resolve_annotation_type(ctx, ctx.ann.lists:get(i), seen)
            indexers[#indexers + 1] = resolve_annotation_type(ctx, ctx.ann.lists:get(i + 1), seen)
            i = i + 2
        end
        local row_var = -1
        if at.data[4] >= 0 then
            row_var = resolve_annotation_type(ctx, at.data[4], seen)
        end
        local meta_ids = {}
        for j = at.data[5], at.data[5] + at.data[6] - 1 do
            local fid = ctx.ann.lists:get(j)
            local fe  = ctx.ann.fields:get(fid)
            local ft  = resolve_annotation_type(ctx, fe.type_id, seen)
            meta_ids[#meta_ids + 1] = types_mod.make_field(ctx, fe.name_id, ft, fe.optional == 1)
        end
        seen[ann_tid] = nil
        return types_mod.make_table(ctx, field_ids, indexers, row_var, meta_ids)
    end

    if tag == TAG_UNION then
        seen[ann_tid] = true
        local members = {}
        for i = at.data[0], at.data[0] + at.data[1] - 1 do
            members[#members + 1] = resolve_annotation_type(ctx, ctx.ann.lists:get(i), seen)
        end
        seen[ann_tid] = nil
        return types_mod.make_union(ctx, members)
    end

    if tag == defs.TAG_INTERSECTION then
        seen[ann_tid] = true
        local members = {}
        for i = at.data[0], at.data[0] + at.data[1] - 1 do
            members[#members + 1] = resolve_annotation_type(ctx, ctx.ann.lists:get(i), seen)
        end
        seen[ann_tid] = nil
        return types_mod.make_intersection(ctx, members)
    end

    if tag == TAG_TUPLE then
        seen[ann_tid] = true
        local elems = {}
        for i = at.data[0], at.data[0] + at.data[1] - 1 do
            elems[#elems + 1] = resolve_annotation_type(ctx, ctx.ann.lists:get(i), seen)
        end
        seen[ann_tid] = nil
        return types_mod.make_tuple(ctx, elems)
    end

    if tag == TAG_FORALL then
        seen[ann_tid] = true
        local param_scope = env_mod.child(ctx.scope)
        for i = at.data[0], at.data[0] + at.data[1] - 1 do
            local param_name_id = ctx.ann.lists:get(i)
            local tv = types_mod.make_var(ctx, ctx.scope.level + 1)
            ctx.types:get(tv).flags = defs.FLAG_GENERIC
            env_mod.bind_type(param_scope, param_name_id, { body = tv })
        end
        local saved_scope = ctx.scope
        ctx.scope = param_scope
        local body = resolve_annotation_type(ctx, at.data[2], seen)
        ctx.scope = saved_scope
        seen[ann_tid] = nil
        return body
    end

    if tag == TAG_MATCH_TYPE then
        seen[ann_tid] = true
        local param = resolve_annotation_type(ctx, at.data[0], seen)
        local arms = {}
        local as, al = at.data[1], at.data[2]
        local i = as
        while i < as + al - 1 do
            arms[#arms + 1] = resolve_annotation_type(ctx, ctx.ann.lists:get(i), seen)
            arms[#arms + 1] = resolve_annotation_type(ctx, ctx.ann.lists:get(i + 1), seen)
            i = i + 2
        end
        local m = ctx.lists:mark()
        for _, aid in ipairs(arms) do ctx.lists:push(aid) end
        local ms, ml = ctx.lists:since(m)
        local id = types_mod.alloc_type(ctx, TAG_MATCH_TYPE)
        local mtt = ctx.types:get(id)
        mtt.data[0] = param
        mtt.data[1] = ms
        mtt.data[2] = ml
        seen[ann_tid] = nil
        local match_mod = require("lib.type.static.v2.match")
        return match_mod.evaluate(ctx, id)
    end

    if tag == TAG_NOMINAL then
        seen[ann_tid] = true
        local underlying = resolve_annotation_type(ctx, at.data[2], seen)
        seen[ann_tid] = nil
        return types_mod.make_nominal(ctx, at.data[0], at.data[1], underlying)
    end

    if tag == TAG_SPREAD then
        seen[ann_tid] = true
        local inner = resolve_annotation_type(ctx, at.data[0], seen)
        seen[ann_tid] = nil
        local id = types_mod.alloc_type(ctx, TAG_SPREAD)
        ctx.types:get(id).data[0] = inner
        return id
    end

    if tag == TAG_INTRINSIC then
        local id = types_mod.alloc_type(ctx, TAG_INTRINSIC)
        ctx.types:get(id).data[0] = at.data[0]
        return id
    end

    if tag == TAG_TYPE_CALL then
        seen[ann_tid] = true
        local callee = resolve_annotation_type(ctx, at.data[0], seen)
        local arg_ids = {}
        for i = at.data[1], at.data[1] + at.data[2] - 1 do
            arg_ids[#arg_ids + 1] = resolve_annotation_type(ctx, ctx.ann.lists:get(i), seen)
        end
        seen[ann_tid] = nil
        local ct = ctx.types:get(callee)
        if ct.tag == TAG_NAMED then
            local resolved = env_mod.resolve_named_type(ctx, ctx.scope, ct.data[0], arg_ids)
            if resolved then return resolved end
        end
        local m = ctx.lists:mark()
        for _, aid in ipairs(arg_ids) do ctx.lists:push(aid) end
        local as, al = ctx.lists:since(m)
        local id = types_mod.alloc_type(ctx, TAG_TYPE_CALL)
        local tct = ctx.types:get(id)
        tct.data[0] = callee
        tct.data[1] = as
        tct.data[2] = al
        return id
    end

    return ctx.T_ANY
end

---------------------------------------------------------------------------
-- Expression inference
---------------------------------------------------------------------------

local ExprRule = {}
local StmtRule = {}

infer_expr = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local rule = ExprRule[n.kind]
    if rule then return rule(ctx, nid) end
    report(ctx, n.line, n.col, "unhandled expr kind " .. n.kind)
    return ctx.T_ANY
end

-- Infer expression for multi-return contexts (calls).
local function infer_expr_multi(ctx, nid)
    local n = ctx.nodes:get(nid)
    if n.kind == NODE_CALL_EXPR or n.kind == NODE_METHOD_CALL then
        local rule = ExprRule[n.kind]
        if rule then
            local primary = rule(ctx, nid)
            local mr = ctx._last_multi_return
            ctx._last_multi_return = nil
            if mr then return mr end
            return { primary }
        end
    end
    return { infer_expr(ctx, nid) }
end

-- Infer expression list; last expr may multi-return.
local function infer_expr_list(ctx, es, el)
    if el == 0 then return {} end
    local result = {}
    for i = es, es + el - 2 do
        result[#result + 1] = infer_expr(ctx, ctx.ast_lists:get(i))
    end
    local last_nid = ctx.ast_lists:get(es + el - 1)
    local multi = infer_expr_multi(ctx, last_nid)
    for _, tid in ipairs(multi) do result[#result + 1] = tid end
    return result
end

-- Normalize a primitive or literal type tag to its base primitive tag for prim_meta lookup.
-- Returns the resolved base tag, or nil if not a relevant primitive.
local function prim_tag(ctx, tid)
    local t = ctx.types:get(types_mod.find(ctx, tid))
    local tag = t.tag
    if tag == TAG_LITERAL then
        local kind = t.data[0]
        if kind == LIT_NUMBER  then return TAG_NUMBER  end
        if kind == LIT_STRING  then return TAG_STRING  end
        return nil  -- boolean/nil literals have no prim_meta
    end
    if tag == TAG_NUMBER or tag == TAG_INTEGER or tag == TAG_STRING then return tag end
    return nil
end

-- Get return type of metamethod on type, or nil.
-- For TAG_TABLE: looks up the meta field directly.
-- For primitives: looks up ctx.prim_meta[base_tag] (number, integer, string).
-- NOTE: Do NOT call this for binary arithmetic/concat/cmp operands when both sides
-- may be primitives — the hardcoded dispatch in those paths handles mixed-type
-- arithmetic correctly and validates concat operands. Call with tag==TAG_TABLE guard
-- or use the prim_tag() helper inline instead.
local function meta_op_ret(ctx, tid, mm_name)
    tid = types_mod.find(ctx, tid)
    local t = ctx.types:get(tid)
    local meta_tid
    if t.tag == TAG_TABLE then
        meta_tid = tid
    else
        local pt = prim_tag(ctx, tid)
        if not pt then return nil end
        local pmt = ctx.prim_meta[pt]
        if not pmt then return nil end
        meta_tid = types_mod.find(ctx, pmt)
        if ctx.types:get(meta_tid).tag ~= TAG_TABLE then return nil end
    end
    local mm_id = intern_mod.intern(ctx.pool, mm_name)
    local fe = types_mod.table_meta_field(ctx, meta_tid, mm_id)
    if not fe then return nil end
    local fn_tid = types_mod.find(ctx, fe.type_id)
    local ft = ctx.types:get(fn_tid)
    if ft.tag == TAG_FUNCTION and ft.data[3] > 0 then
        return types_mod.find(ctx, ctx.lists:get(ft.data[2]))
    end
    return ctx.T_ANY
end


-- Like meta_op_ret but returns the full metamethod function TID (not just return type).
-- Used to extract parameter types for cross-type operand validation.
local function meta_fn_tid(ctx, tid, mm_name)
    tid = types_mod.find(ctx, tid)
    local t = ctx.types:get(tid)
    local meta_tid
    if t.tag == TAG_TABLE then
        meta_tid = tid
    else
        local pt = prim_tag(ctx, tid)
        if not pt then return nil end
        local pmt = ctx.prim_meta[pt]
        if not pmt then return nil end
        meta_tid = types_mod.find(ctx, pmt)
        if ctx.types:get(meta_tid).tag ~= TAG_TABLE then return nil end
    end
    local mm_id = intern_mod.intern(ctx.pool, mm_name)
    local fe = types_mod.table_meta_field(ctx, meta_tid, mm_id)
    if not fe then return nil end
    return types_mod.find(ctx, fe.type_id)
end

local ARITH_META = {
    [OP_ADD] = "__add", [OP_SUB] = "__sub", [OP_MUL] = "__mul",
    [OP_DIV] = "__div", [OP_MOD] = "__mod", [OP_POW] = "__pow",
}
local CMP_META = {
    [OP_LT] = "__lt", [OP_GT] = "__lt", [OP_LE] = "__le", [OP_GE] = "__le",
}

-- Check whether a type (including unions) has a specific metamethod.
-- Uses meta_op_ret for the leaf check (handles TAG_TABLE fields and prim_meta).
-- TAG_ANY / TAG_VAR / TAG_ROWVAR are assumed to have any metamethod (unconstrained).
-- allow_table: if true, TAG_TABLE always passes (for OP_LEN — built-in # on tables).
local has_metamethod
has_metamethod = function(ctx, tid, mm_name, allow_table)
    tid = types_mod.find(ctx, tid)
    local t = ctx.types:get(tid)
    if t.tag == TAG_ANY or t.tag == TAG_VAR or t.tag == TAG_ROWVAR then return true end
    if allow_table and t.tag == TAG_TABLE then return true end
    if t.tag == TAG_UNION then
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            if not has_metamethod(ctx, ctx.lists:get(i), mm_name, allow_table) then
                return false
            end
        end
        return true
    end
    return meta_op_ret(ctx, tid, mm_name) ~= nil
end

-- A type is numeric iff it has arithmetic metamethods (__add as proxy).
-- number/integer pass via prim_meta; nil, boolean, string correctly fail.
local function is_numeric(ctx, tid)
    return has_metamethod(ctx, tid, "__add", false)
end

local function is_int_compat(ctx, tid)
    local t = ctx.types:get(types_mod.find(ctx, tid))
    return t.tag == TAG_INTEGER
        or (t.tag == TAG_LITERAL and t.data[0] == LIT_NUMBER)
end

ExprRule[NODE_LITERAL] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local kind = n.data[0]
    if kind == LIT_NIL     then return ctx.T_NIL end
    if kind == LIT_BOOLEAN then return types_mod.make_literal(ctx, LIT_BOOLEAN, n.data[1]) end
    if kind == LIT_STRING  then return types_mod.make_literal(ctx, LIT_STRING, n.data[1]) end
    if kind == LIT_NUMBER  then
        -- n.data[1] is the numval index into pr.lexer.numvals (Lua numbers, not pool IDs)
        local num = ctx.numvals[n.data[1]]
        if num and num % 1 == 0 and num >= -2^53 and num <= 2^53 then
            return ctx.T_INTEGER
        end
        return ctx.T_NUMBER
    end
    return ctx.T_ANY
end

ExprRule[NODE_IDENTIFIER] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local name_id = n.data[0]
    local ty = env_mod.lookup(ctx.scope, name_id)
    if ty then return ty end
    local name = intern_mod.get(ctx.pool, name_id) or "?"
    report(ctx, n.line, n.col, "unknown identifier '" .. name .. "'")
    return ctx.T_ANY
end

ExprRule[NODE_VARARG_EXPR] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local vararg_id = intern_mod.intern(ctx.pool, "...")
    local ty = env_mod.lookup(ctx.scope, vararg_id)
    if ty then return ty end
    report(ctx, n.line, n.col, "'...' used outside a vararg function")
    return ctx.T_ANY
end

ExprRule[NODE_UNARY_EXPR] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local op = n.data[0]
    local arg_tid = infer_expr(ctx, n.data[1])
    if op == OP_NOT then return ctx.T_BOOLEAN end
    if op == OP_UNM then
        local mm = meta_op_ret(ctx, arg_tid, "__unm")
        if mm then return mm end
        if not has_metamethod(ctx, arg_tid, "__unm", false) then
            report(ctx, n.line, n.col, "cannot perform arithmetic on '" .. types_mod.display(ctx, arg_tid) .. "'")
        end
        return ctx.T_NUMBER
    end
    if op == OP_LEN then
        local mm = meta_op_ret(ctx, arg_tid, "__len")
        if mm then return mm end
        -- Tables always support # (built-in length); everything else needs __len.
        if not has_metamethod(ctx, arg_tid, "__len", true) then
            report(ctx, n.line, n.col, "cannot get length of '" .. types_mod.display(ctx, arg_tid) .. "'")
        end
        return ctx.T_INTEGER
    end
    return ctx.T_ANY
end

ExprRule[NODE_BINARY_EXPR] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local op = n.data[0]

    -- OP_AND: short-circuit — when evaluating right, left was truthy.
    -- Narrow scope from left before inferring right to avoid false positives
    -- on patterns like `ann and ann.field`.
    if op == defs.OP_AND then
        infer_expr(ctx, n.data[1])
        local narrow_mod = require("lib.type.static.v2.narrow")
        local narrowed = narrow_mod.narrow_scope(ctx, n.data[1], true)
        local saved = ctx.scope
        if next(narrowed) then ctx.scope = narrow_mod.apply_narrowed(ctx, narrowed) end
        local right_r = types_mod.find(ctx, infer_expr(ctx, n.data[2]))
        ctx.scope = saved
        return types_mod.make_union(ctx, { ctx.T_NIL, right_r })
    end

    local left_tid  = infer_expr(ctx, n.data[1])
    local right_tid = infer_expr(ctx, n.data[2])
    local left_r  = types_mod.find(ctx, left_tid)
    local right_r = types_mod.find(ctx, right_tid)

    if ARITH_META[op] then
        local mm_name = ARITH_META[op]
        -- Only dispatch via table metamethods for non-primitive operands.
        -- Primitive arithmetic is handled by the hardcoded path below, which correctly
        -- handles mixed integer+number types and validates non-numeric operands.
        local mm
        if ctx.types:get(left_r).tag == TAG_TABLE then
            mm = meta_op_ret(ctx, left_r, mm_name)
        end
        if not mm and ctx.types:get(right_r).tag == TAG_TABLE then
            mm = meta_op_ret(ctx, right_r, mm_name)
        end
        if mm then return mm end
        local function check_num(r_id)
            local lt = ctx.types:get(r_id)
            if lt.tag == TAG_UNION then
                for i = lt.data[0], lt.data[0] + lt.data[1] - 1 do
                    if not is_numeric(ctx, ctx.lists:get(i)) then
                        report(ctx, n.line, n.col, "cannot perform arithmetic on '" .. types_mod.display(ctx, r_id) .. "'")
                        return
                    end
                end
            elseif not is_numeric(ctx, r_id) then
                report(ctx, n.line, n.col, "cannot perform arithmetic on '" .. types_mod.display(ctx, r_id) .. "'")
            end
        end
        check_num(left_r)
        check_num(right_r)
        if op == OP_DIV or op == OP_POW then return ctx.T_NUMBER end
        if is_int_compat(ctx, left_r) and is_int_compat(ctx, right_r) then return ctx.T_INTEGER end
        return ctx.T_NUMBER
    end

    if op == OP_EQ or op == OP_NE then return ctx.T_BOOLEAN end
    if CMP_META[op] then
        local mm_name = CMP_META[op]
        -- Custom __lt/__le on a table operand overrides return type.
        local mm
        if ctx.types:get(left_r).tag == TAG_TABLE then
            mm = meta_op_ret(ctx, left_r, mm_name)
        end
        if not mm and ctx.types:get(right_r).tag == TAG_TABLE then
            mm = meta_op_ret(ctx, right_r, mm_name)
        end
        if mm then return mm end
        -- Validate each operand supports ordering (nil and boolean do not).
        if not has_metamethod(ctx, left_r, mm_name, false) then
            report(ctx, n.line, n.col, "cannot compare '" .. types_mod.display(ctx, left_r) .. "'")
            return ctx.T_BOOLEAN
        end
        if not has_metamethod(ctx, right_r, mm_name, false) then
            report(ctx, n.line, n.col, "cannot compare '" .. types_mod.display(ctx, right_r) .. "'")
            return ctx.T_BOOLEAN
        end
        -- Cross-type check via Lua metamethod calling rules.
        -- Lua picks __lt/__le from left operand first, then right.
        -- The function's parameter types define valid operand types.
        local fn = meta_fn_tid(ctx, left_r, mm_name)
               or  meta_fn_tid(ctx, right_r, mm_name)
        if fn then
            local ft = ctx.types:get(fn)
            if ft.tag == TAG_FUNCTION and ft.data[1] >= 2 then
                local p0 = ctx.lists:get(ft.data[0])
                local p1 = ctx.lists:get(ft.data[0] + 1)
                local ok0 = unify_mod.try_unify(ctx, left_r,  p0)
                local ok1 = unify_mod.try_unify(ctx, right_r, p1)
                if not ok0 or not ok1 then
                    report(ctx, n.line, n.col,
                        "cannot compare '" .. types_mod.display(ctx, left_r)
                        .. "' with '" .. types_mod.display(ctx, right_r) .. "'")
                end
            end
        end
        return ctx.T_BOOLEAN
    end

    if op == OP_CONCAT then
        -- Custom __concat on a table operand overrides the return type.
        local mm
        if ctx.types:get(left_r).tag == TAG_TABLE then
            mm = meta_op_ret(ctx, left_r, "__concat")
        end
        if not mm and ctx.types:get(right_r).tag == TAG_TABLE then
            mm = meta_op_ret(ctx, right_r, "__concat")
        end
        if mm then return mm end
        -- A type is concat-compatible iff it has a __concat metamethod.
        -- meta_op_ret checks both table meta fields and ctx.prim_meta for primitives.
        -- TAG_ANY / TAG_VAR / TAG_ROWVAR are assumed compatible (unconstrained).
        -- nil and boolean have no __concat in prim_meta, so they correctly fail.
        local is_concat_ok
        is_concat_ok = function(r_id)
            r_id = types_mod.find(ctx, r_id)
            local t = ctx.types:get(r_id)
            if t.tag == TAG_ANY or t.tag == TAG_VAR or t.tag == TAG_ROWVAR then return true end
            if t.tag == TAG_UNION then
                for j = t.data[0], t.data[0] + t.data[1] - 1 do
                    if not is_concat_ok(ctx.lists:get(j)) then return false end
                end
                return true
            end
            return meta_op_ret(ctx, r_id, "__concat") ~= nil
        end
        if not is_concat_ok(left_r) then
            report(ctx, n.line, n.col, "cannot concatenate '" .. types_mod.display(ctx, left_r) .. "'")
        end
        if not is_concat_ok(right_r) then
            report(ctx, n.line, n.col, "cannot concatenate '" .. types_mod.display(ctx, right_r) .. "'")
        end
        return ctx.T_STRING
    end

    if op == OP_OR then
        -- Cat F: `A or B` — when right is used, left was nil/false.
        -- Strip nil from left to avoid spurious nil in the result union.
        local non_nil_left = types_mod.subtract(ctx, left_r, ctx.T_NIL)
        return types_mod.make_union(ctx, { non_nil_left, right_r })
    end

    report(ctx, n.line, n.col, "unknown binary operator " .. op)
    return ctx.T_ANY
end

ExprRule[NODE_FIELD_EXPR] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local obj_tid = types_mod.find(ctx, infer_expr(ctx, n.data[0]))
    local fname_id = n.data[1]
    local obj_t = ctx.types:get(obj_tid)

    if obj_t.tag == TAG_NEVER then return ctx.T_NEVER end
    if obj_t.tag == TAG_ANY   then return ctx.T_ANY end

    if obj_t.tag == TAG_TABLE then
        local fe = types_mod.table_field(ctx, obj_tid, fname_id)
        if fe then return types_mod.find(ctx, fe.type_id) end
        local is, il = obj_t.data[2], obj_t.data[3]
        local i = is
        while i < is + il - 1 do
            local kt = types_mod.find(ctx, ctx.lists:get(i))
            if ctx.types:get(kt).tag == defs.TAG_STRING then
                return types_mod.find(ctx, ctx.lists:get(i + 1))
            end
            i = i + 2
        end
        if obj_t.data[4] >= 0 then return ctx.T_ANY end
        local fname = intern_mod.get(ctx.pool, fname_id) or "?"
        report(ctx, n.line, n.col, "no field '" .. fname .. "' on type '" .. types_mod.display(ctx, obj_tid) .. "'")
        return ctx.T_ANY
    end

    if obj_t.tag == TAG_VAR then
        local field_var = types_mod.make_var(ctx, ctx.scope.level)
        local row_var   = types_mod.make_rowvar(ctx, ctx.scope.level)
        local fid = types_mod.make_field(ctx, fname_id, field_var, false)
        local tbl_ty = types_mod.make_table(ctx, { fid }, {}, row_var, {})
        unify_mod.unify(ctx, obj_tid, tbl_ty)
        return field_var
    end

    if obj_t.tag == TAG_UNION then
        local field_types = {}
        local any_missing = false
        for i = obj_t.data[0], obj_t.data[0] + obj_t.data[1] - 1 do
            local mid = types_mod.find(ctx, ctx.lists:get(i))
            local mt = ctx.types:get(mid)
            if mt.tag == TAG_TABLE then
                local fe = types_mod.table_field(ctx, mid, fname_id)
                if fe then
                    field_types[#field_types + 1] = types_mod.find(ctx, fe.type_id)
                else
                    any_missing = true
                end
            elseif mt.tag == TAG_ANY then
                return ctx.T_ANY
            else
                any_missing = true
            end
        end
        if #field_types > 0 then
            if any_missing then field_types[#field_types + 1] = ctx.T_NIL end
            return types_mod.make_union(ctx, field_types)
        end
    end

    local fname = intern_mod.get(ctx.pool, fname_id) or "?"
    report(ctx, n.line, n.col, "no field '" .. fname .. "' on type '" .. types_mod.display(ctx, obj_tid) .. "'")
    return ctx.T_ANY
end

ExprRule[NODE_INDEX_EXPR] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local obj_tid = types_mod.find(ctx, infer_expr(ctx, n.data[0]))
    local key_tid = infer_expr(ctx, n.data[1])
    local key_r   = types_mod.find(ctx, key_tid)
    local obj_t   = ctx.types:get(obj_tid)

    if obj_t.tag == TAG_ANY then return ctx.T_ANY end

    if obj_t.tag == TAG_TABLE then
        local is, il = obj_t.data[2], obj_t.data[3]
        local i = is
        while i < is + il - 1 do
            local kt = ctx.lists:get(i)
            if unify_mod.try_unify(ctx, key_r, kt) then return types_mod.find(ctx, ctx.lists:get(i + 1)) end
            i = i + 2
        end
        local kt_t = ctx.types:get(key_r)
        if kt_t.tag == TAG_LITERAL and kt_t.data[0] == LIT_STRING then
            local fe = types_mod.table_field(ctx, obj_tid, kt_t.data[1])
            if fe then return types_mod.find(ctx, fe.type_id) end
        end
        if obj_t.data[4] >= 0 then return ctx.T_ANY end
    end

    if obj_t.tag == TAG_VAR then
        local elem_var = types_mod.make_var(ctx, ctx.scope.level)
        local tbl = types_mod.make_table(ctx, {}, { key_r, elem_var }, -1, {})
        unify_mod.unify(ctx, obj_tid, tbl)
        return elem_var
    end

    return ctx.T_ANY
end

local function check_call_args(ctx, fn_tid, arg_tids, line, col)
    local ft = ctx.types:get(fn_tid)
    if ft.tag ~= TAG_FUNCTION then return end
    local pl = ft.data[1]
    for i = 0, pl - 1 do
        local exp_tid = types_mod.find(ctx, ctx.lists:get(ft.data[0] + i))
        local act_tid = arg_tids[i + 1]
        if act_tid then
            local ok, err = unify_mod.unify(ctx, act_tid, exp_tid)
            if not ok then
                report(ctx, line, col,
                    "argument " .. (i + 1) .. ": cannot pass '" .. types_mod.display(ctx, act_tid)
                    .. "' where '" .. types_mod.display(ctx, exp_tid) .. "' expected"
                    .. (err and (": " .. err) or ""))
            end
        else
            local ok = unify_mod.unify(ctx, ctx.T_NIL, exp_tid)
            if not ok then
                report(ctx, line, col, "argument " .. (i + 1) .. ": missing required argument")
            end
        end
    end
end

local function call_returns(ctx, fn_tid, arg_tids, line, col)
    fn_tid = types_mod.find(ctx, fn_tid)
    local ft = ctx.types:get(fn_tid)

    if ft.tag == TAG_ANY then
        ctx._last_multi_return = { ctx.T_ANY }
        return ctx.T_ANY
    end

    if ft.tag == TAG_FUNCTION then
        local inst_fn = env_mod.instantiate(ctx, fn_tid, ctx.scope.level)
        check_call_args(ctx, inst_fn, arg_tids, line, col)
        local ift = ctx.types:get(inst_fn)
        local rl = ift.data[3]
        if rl == 0 then
            ctx._last_multi_return = { ctx.T_NIL }
            return ctx.T_NIL
        end
        local returns = {}
        for i = ift.data[2], ift.data[2] + rl - 1 do
            returns[#returns + 1] = types_mod.find(ctx, ctx.lists:get(i))
        end
        ctx._last_multi_return = returns
        return returns[1]
    end

    if ft.tag == TAG_UNION then
        for i = ft.data[0], ft.data[0] + ft.data[1] - 1 do
            local mid = types_mod.find(ctx, ctx.lists:get(i))
            if ctx.types:get(mid).tag == TAG_FUNCTION then
                local rl = ctx.types:get(mid).data[3]
                if rl > 0 then
                    local r = types_mod.find(ctx, ctx.lists:get(ctx.types:get(mid).data[2]))
                    ctx._last_multi_return = { r }
                    return r
                end
                ctx._last_multi_return = { ctx.T_NIL }
                return ctx.T_NIL
            end
        end
    end

    if ft.tag == TAG_VAR then
        local ret_var = types_mod.make_var(ctx, ctx.scope.level)
        ctx._last_multi_return = { ret_var }
        return ret_var
    end

    if ft.tag ~= TAG_NEVER then
        report(ctx, line, col, "cannot call type '" .. types_mod.display(ctx, fn_tid) .. "'")
    end
    ctx._last_multi_return = { ctx.T_ANY }
    return ctx.T_ANY
end

ExprRule[NODE_CALL_EXPR] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local callee_nid = n.data[0]
    local callee_tid = infer_expr(ctx, callee_nid)
    local arg_tids = infer_expr_list(ctx, n.data[1], n.data[2])

    -- Detect pcall(fn, ...) / xpcall(fn, handler, ...) for enriched return types.
    -- Extract the wrapped function's return types so that `local ok, val = pcall(fn)`
    -- gives val: ret_type|nil rather than any, enabling downstream narrowing.
    ctx._last_pcall_success_types = nil
    local callee_n = ctx.nodes:get(callee_nid)
    if callee_n.kind == NODE_IDENTIFIER and n.data[2] >= 1 then
        local fname = intern_mod.get(ctx.pool, callee_n.data[0]) or ""
        if fname == "pcall" or fname == "xpcall" then
            local wrapped_fn_tid = types_mod.find(ctx, arg_tids[1])
            local wft = ctx.types:get(wrapped_fn_tid)
            if wft.tag == TAG_FUNCTION then
                local inst = env_mod.instantiate(ctx, wrapped_fn_tid, ctx.scope.level)
                local ift = ctx.types:get(inst)
                local success_types = {}
                for i = ift.data[2], ift.data[2] + ift.data[3] - 1 do
                    success_types[#success_types + 1] = types_mod.find(ctx, ctx.lists:get(i))
                end
                ctx._last_pcall_success_types = success_types
                -- Multi-return: boolean + each success type union'd with nil
                local returns = { ctx.T_BOOLEAN }
                for _, st in ipairs(success_types) do
                    returns[#returns + 1] = types_mod.make_union(ctx, {st, ctx.T_NIL})
                end
                if #returns == 1 then
                    -- Wrapped fn returns nothing: pcall still returns boolean
                    returns[2] = ctx.T_ANY
                end
                ctx._last_multi_return = returns
                return ctx.T_BOOLEAN
            end
        elseif fname == "require" and ctx.cri_loader and n.data[2] >= 1 then
            -- If a cri_loader is registered, use it to resolve the module's export type.
            -- The first arg must be a string literal for static resolution.
            local arg0_nid_or_mod = n.data[1]  -- start index into ast_lists
            local arg0_nid = ctx.ast_lists:get(arg0_nid_or_mod)
            local arg0_n = ctx.nodes:get(arg0_nid)
            if arg0_n and arg0_n.kind == NODE_LITERAL and arg0_n.data[2] == LIT_STRING then
                local mod_name = intern_mod.get(ctx.pool, arg0_n.data[1]) or ""
                local exports = ctx.cri_loader(ctx, mod_name)
                if exports then
                    return exports
                end
            end
        end
    end

    return call_returns(ctx, callee_tid, arg_tids, n.line, n.col)
end

ExprRule[NODE_METHOD_CALL] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local recv_tid = infer_expr(ctx, n.data[0])
    local recv_r   = types_mod.find(ctx, recv_tid)
    local method_name_id = n.data[1]

    local method_tid = ctx.T_ANY
    local recv_t = ctx.types:get(recv_r)
    if recv_t.tag == TAG_TABLE then
        local fe = types_mod.table_field(ctx, recv_r, method_name_id)
        if fe then
            method_tid = types_mod.find(ctx, fe.type_id)
        else
            local mname = intern_mod.get(ctx.pool, method_name_id) or "?"
            report(ctx, n.line, n.col, "no method '" .. mname .. "' on type '" .. types_mod.display(ctx, recv_r) .. "'")
        end
    else
        -- For primitive types, look up a registered __index table in ctx.prim_index.
        -- Literal types are mapped to their base primitive tag first.
        local tag = recv_t.tag
        if tag == TAG_LITERAL and recv_t.data[0] == LIT_STRING then
            tag = TAG_STRING
        end
        local prim_tid = ctx.prim_index[tag]
        if prim_tid then
            prim_tid = types_mod.find(ctx, prim_tid)
            if ctx.types:get(prim_tid).tag == TAG_TABLE then
                local fe = types_mod.table_field(ctx, prim_tid, method_name_id)
                if fe then
                    method_tid = types_mod.find(ctx, fe.type_id)
                else
                    local mname = intern_mod.get(ctx.pool, method_name_id) or "?"
                    report(ctx, n.line, n.col, "no method '" .. mname .. "' on type '" .. types_mod.display(ctx, recv_r) .. "'")
                end
            end
        elseif recv_t.tag ~= TAG_ANY and recv_t.tag ~= TAG_VAR then
            local mname = intern_mod.get(ctx.pool, method_name_id) or "?"
            report(ctx, n.line, n.col, "no method '" .. mname .. "' on type '" .. types_mod.display(ctx, recv_r) .. "'")
        end
    end

    local extra = infer_expr_list(ctx, n.data[2], n.data[3])
    local arg_tids = { recv_tid }
    for _, a in ipairs(extra) do arg_tids[#arg_tids + 1] = a end
    return call_returns(ctx, method_tid, arg_tids, n.line, n.col)
end

ExprRule[NODE_TABLE_EXPR] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local field_ids = {}
    local indexers  = {}
    local pos_idx   = 1
    for i = n.data[0], n.data[0] + n.data[1] - 1 do
        local fld_nid = ctx.ast_lists:get(i)
        local fn = ctx.nodes:get(fld_nid)
        local val_tid = infer_expr(ctx, fn.data[1])
        local key_nid = fn.data[0]

        if key_nid == -1 then
            -- Positional
            local pos_key = intern_mod.intern(ctx.pool, tostring(pos_idx))
            field_ids[#field_ids + 1] = types_mod.make_field(ctx, pos_key, val_tid, false)
            pos_idx = pos_idx + 1
        elseif (fn.flags % (FLAG_COMPUTED * 2)) >= FLAG_COMPUTED then
            -- [expr] = val
            local key_tid = infer_expr(ctx, key_nid)
            indexers[#indexers + 1] = key_tid
            indexers[#indexers + 1] = val_tid
        else
            -- name = val (key_nid is a literal string node)
            local kn = ctx.nodes:get(key_nid)
            local name_id = kn.data[1]
            field_ids[#field_ids + 1] = types_mod.make_field(ctx, name_id, val_tid, false)
        end
    end
    return types_mod.make_table(ctx, field_ids, indexers, -1, {})
end

infer_function = function(ctx, ps, pl, bs, bl, has_vararg, ann_fn_tid, stub_ret_vars)
    local fn_scope = env_mod.child(ctx.scope)
    local param_tids = {}

    local has_ann_fn = ann_fn_tid ~= nil
    if has_ann_fn then
        local aft = ctx.types:get(ann_fn_tid)
        if aft and aft.tag == TAG_FUNCTION then
            for i = 0, pl - 1 do
                local name_id = ctx.ast_lists:get(ps + i)
                local pt_id
                if i < aft.data[1] then
                    pt_id = types_mod.find(ctx, ctx.lists:get(aft.data[0] + i))
                else
                    pt_id = types_mod.make_var(ctx, fn_scope.level)
                end
                env_mod.bind(fn_scope, name_id, pt_id)
                param_tids[#param_tids + 1] = pt_id
            end
            if has_vararg then
                local dots_id = intern_mod.intern(ctx.pool, "...")
                local vt = aft.data[4] >= 0 and aft.data[4] or ctx.T_ANY
                env_mod.bind(fn_scope, dots_id, vt)
            end
        else
            has_ann_fn = false
        end
    end

    -- Cat H: scan body start for `param = param or default` to detect optional params.
    -- Build name_id → param index (1-based) mapping for the scan.
    local param_name_to_idx = {}
    if not has_ann_fn then
        for i = 0, pl - 1 do
            local name_id = ctx.ast_lists:get(ps + i)
            local pt_id = types_mod.make_var(ctx, fn_scope.level)
            env_mod.bind(fn_scope, name_id, pt_id)
            param_tids[#param_tids + 1] = pt_id
            param_name_to_idx[name_id] = i + 1
        end
        if has_vararg then
            local dots_id = intern_mod.intern(ctx.pool, "...")
            env_mod.bind(fn_scope, dots_id, ctx.T_ANY)
        end
    end

    local saved = ctx.scope
    ctx.scope = fn_scope
    prescan_block(ctx, bs, bl)
    -- Pass stub_ret_vars only for unannotated functions; annotated functions
    -- use the declared return type as the source of truth.
    push_return_collector(ctx, not has_ann_fn and stub_ret_vars or nil)
    infer_block(ctx, bs, bl)
    local rc = pop_return_collector(ctx)
    ctx.scope = saved

    -- Cat H: after body inference, widen params with `param = param or default` to
    -- include nil, so callers can omit trailing optional arguments.
    -- Scan the first few body statements (the pattern may follow guard returns).
    if not has_ann_fn then
        local scan_limit = bl < 10 and bl or 10
        for i = bs, bs + scan_limit - 1 do
            local sid = ctx.ast_lists:get(i)
            local sn  = ctx.nodes:get(sid)
            if sn.kind ~= NODE_ASSIGN_STMT or sn.data[1] ~= 1 or sn.data[3] ~= 1 then
                -- Skip non-matching statements; stop at end-of-range.
            else
                local lhs_n = ctx.nodes:get(ctx.ast_lists:get(sn.data[0]))
                if lhs_n.kind == NODE_IDENTIFIER then
                    local nm_id = lhs_n.data[0]
                    local pidx  = param_name_to_idx[nm_id]
                    if pidx then
                        local rhs_n = ctx.nodes:get(ctx.ast_lists:get(sn.data[2]))
                        if rhs_n.kind == NODE_BINARY_EXPR and rhs_n.data[0] == OP_OR then
                            local or_left_n = ctx.nodes:get(rhs_n.data[1])
                            if or_left_n.kind == NODE_IDENTIFIER and or_left_n.data[0] == nm_id then
                                -- Pattern matched: widen this param to union(bound_type, T_NIL).
                                param_tids[pidx] = types_mod.make_union(ctx, { param_tids[pidx], ctx.T_NIL })
                            end
                        end
                    end
                end
            end
        end
    end

    local returns
    if has_ann_fn then
        local aft = ctx.types:get(ann_fn_tid)
        if aft and aft.tag == TAG_FUNCTION then
            returns = {}
            for i = aft.data[2], aft.data[2] + aft.data[3] - 1 do
                returns[#returns + 1] = types_mod.find(ctx, ctx.lists:get(i))
            end
        end
    end

    if not returns then
        if #rc == 0 then
            returns = {}
        elseif #rc == 1 then
            returns = rc[1]
        else
            local max_rets = 0
            for _, rtl in ipairs(rc) do if #rtl > max_rets then max_rets = #rtl end end
            returns = {}
            for i = 1, max_rets do
                local cands = {}
                for _, rtl in ipairs(rc) do cands[#cands + 1] = rtl[i] or ctx.T_NIL end
                returns[i] = types_mod.make_union(ctx, cands)
            end
        end
    end

    local vararg_id = has_vararg and ctx.T_ANY or -1
    local fn_tid = types_mod.make_func(ctx, param_tids, returns, vararg_id)
    env_mod.generalize(ctx, fn_tid, saved.level)
    return fn_tid
end

ExprRule[NODE_FUNC_EXPR] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local has_vararg = (n.flags % (FLAG_VARARG * 2)) >= FLAG_VARARG
    local ann = get_ann(ctx, n.line)
    local ann_fn_tid = nil
    if ann and ann.kind == ANN_TYPE then
        local resolved = resolve_annotation_type(ctx, ann.type_id)
        local rt = ctx.types:get(types_mod.find(ctx, resolved))
        if rt.tag == TAG_FUNCTION then ann_fn_tid = resolved end
    end
    return infer_function(ctx, n.data[0], n.data[1], n.data[2], n.data[3], has_vararg, ann_fn_tid)
end

---------------------------------------------------------------------------
-- Block / statement inference
---------------------------------------------------------------------------

infer_block = function(ctx, bs, bl)
    for i = bs, bs + bl - 1 do
        infer_stmt(ctx, ctx.ast_lists:get(i))
    end
end

-- Add a field to a table type in-place (used by prescan and open-table extension).
-- WARNING: reads all ot.data before calling make_table, then re-fetches the pointer
-- after, because arena:grow() may reallocate ctx.types.items, invalidating old ptrs.
local function table_add_field(ctx, obj_tid, field_id, field_type_id)
    -- Snapshot all data before any allocation that may trigger arena grow.
    local ot = ctx.types:get(obj_tid)
    local fs, fl = ot.data[0], ot.data[1]
    local is2, il2 = ot.data[2], ot.data[3]
    local rv = ot.data[4]
    local ms, ml = ot.data[5], ot.data[6]

    local existing_fields = {}
    for i = fs, fs + fl - 1 do
        existing_fields[#existing_fields + 1] = ctx.lists:get(i)
    end
    existing_fields[#existing_fields + 1] = types_mod.make_field(ctx, field_id, field_type_id, false)
    local existing_indexers = {}
    local ix = is2
    while ix < is2 + il2 - 1 do
        existing_indexers[#existing_indexers + 1] = ctx.lists:get(ix)
        existing_indexers[#existing_indexers + 1] = ctx.lists:get(ix + 1)
        ix = ix + 2
    end
    local existing_meta = {}
    for j = ms, ms + ml - 1 do
        existing_meta[#existing_meta + 1] = ctx.lists:get(j)
    end
    local new_tbl = types_mod.make_table(ctx, existing_fields, existing_indexers, rv, existing_meta)
    -- Re-fetch ot: make_table may have triggered ctx.types arena grow, invalidating old ptr.
    ot = ctx.types:get(obj_tid)
    local new_t = ctx.types:get(new_tbl)
    for k = 0, 6 do ot.data[k] = new_t.data[k] end
end

-- Build a prescan stub for a forward-declared function.
-- Uses T_ANY for all params (recursive call arg-checking always passes)
-- and a fresh TAG_VAR for the return (shared across all recursive calls;
-- eagerly bound when the first return statement fires).
local function make_prescan_stub(ctx, pl)
    local param_anys = {}
    for i = 1, pl do param_anys[i] = ctx.T_ANY end
    local ret_var = types_mod.make_var(ctx, ctx.scope.level)
    return types_mod.make_func(ctx, param_anys, {ret_var}, -1)
end

prescan_block = function(ctx, bs, bl)
    for i = bs, bs + bl - 1 do
        local sid = ctx.ast_lists:get(i)
        local sn  = ctx.nodes:get(sid)
        if sn.kind == NODE_FUNC_DECL then
            local nn = ctx.nodes:get(sn.data[0])
            local pl = sn.data[2]  -- param list length
            if nn.kind == NODE_IDENTIFIER then
                local name_id = nn.data[0]
                if not env_mod.lookup(ctx.scope, name_id) then
                    env_mod.bind(ctx.scope, name_id, make_prescan_stub(ctx, pl))
                end
            elseif nn.kind == NODE_FIELD_EXPR then
                -- function M.foo(): pre-add foo as a stub field on M's table type.
                local obj_n = ctx.nodes:get(nn.data[0])
                if obj_n.kind == NODE_IDENTIFIER then
                    local obj_name_id = obj_n.data[0]
                    local obj_tid = env_mod.lookup(ctx.scope, obj_name_id)
                    if obj_tid then
                        obj_tid = types_mod.find(ctx, obj_tid)
                        local ot = ctx.types:get(obj_tid)
                        if ot.tag == TAG_TABLE then
                            local field_id = nn.data[1]
                            if not types_mod.table_field(ctx, obj_tid, field_id) then
                                table_add_field(ctx, obj_tid, field_id,
                                    make_prescan_stub(ctx, pl))
                            end
                        end
                    end
                end
            end
        elseif sn.kind == NODE_LOCAL_STMT then
            -- `local M = {}` prescan
            if sn.data[1] == 1 and sn.data[3] == 1 then
                local val_nid = ctx.ast_lists:get(sn.data[2])
                local vn = ctx.nodes:get(val_nid)
                if vn.kind == NODE_TABLE_EXPR and vn.data[1] == 0 then
                    local name_id = ctx.ast_lists:get(sn.data[0])
                    if not env_mod.lookup(ctx.scope, name_id) then
                        local rv = types_mod.make_rowvar(ctx, ctx.scope.level)
                        env_mod.bind(ctx.scope, name_id, types_mod.make_table(ctx, {}, {}, rv, {}))
                    end
                end
            end
        end
    end
end

infer_stmt = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local rule = StmtRule[n.kind]
    if rule then rule(ctx, nid) end
end

StmtRule[NODE_EXPR_STMT] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    infer_expr(ctx, n.data[0])
end

StmtRule[NODE_LOCAL_STMT] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local ns, nl = n.data[0], n.data[1]
    local es, el = n.data[2], n.data[3]

    local rhs_types = el > 0 and infer_expr_list(ctx, es, el) or {}

    -- Cat B: if the last RHS is a call, missing entries may be extra returns → use T_ANY.
    local last_rhs_is_call = false
    if el > 0 then
        local last_rhs_nid = ctx.ast_lists:get(es + el - 1)
        local last_rhs_n = ctx.nodes:get(last_rhs_nid)
        last_rhs_is_call = (last_rhs_n.kind == NODE_CALL_EXPR or last_rhs_n.kind == NODE_METHOD_CALL)
    end

    for i = 0, nl - 1 do
        local name_id = ctx.ast_lists:get(ns + i)
        local rhs_tid = rhs_types[i + 1]

        local ann = get_ann(ctx, n.line)
        local ann_tid = nil
        if ann and ann.kind == ANN_TYPE then
            ann_tid = resolve_annotation_type(ctx, ann.type_id)
        end

        -- Check for a prescan binding in the CURRENT scope (forward-declared module table).
        -- When `local M = {}` is prescanned, M is bound as a table with all method fields
        -- pre-populated. The inferred RHS (`{}`) must not overwrite that richer type.
        local prescanned = ctx.scope.bindings[name_id]

        if ann_tid then
            if rhs_tid then
                local ok, err = unify_mod.unify(ctx, rhs_tid, ann_tid)
                if not ok then
                    report(ctx, n.line, n.col,
                        "type mismatch: '" .. types_mod.display(ctx, rhs_tid)
                        .. "' is not assignable to '" .. types_mod.display(ctx, ann_tid) .. "'"
                        .. (err and (": " .. err) or ""))
                end
            end
            env_mod.bind(ctx.scope, name_id, ann_tid)
        elseif prescanned then
            -- Prescan bound this name: unify with RHS but keep the richer prescanned type.
            if rhs_tid then unify_mod.unify(ctx, rhs_tid, prescanned) end
        else
            local bind_tid
            if rhs_tid then
                -- Cat D: widen boolean literals so `local x = false` gives x: boolean,
                -- allowing reassignment to any boolean expression.
                -- Cat I: explicit nil init (`local x = nil`) treated as forward declaration.
                local rt = ctx.types:get(types_mod.find(ctx, rhs_tid))
                if rt.tag == TAG_LITERAL and rt.data[0] == LIT_BOOLEAN then
                    bind_tid = ctx.T_BOOLEAN
                elseif rt.tag == defs.TAG_NIL then
                    -- Same as no-RHS: fresh typevar so later assignment succeeds.
                    bind_tid = types_mod.make_var(ctx, ctx.scope.level)
                else
                    bind_tid = rhs_tid
                end
            elseif el == 0 then
                -- Cat A: no RHS at all — forward declaration; use a fresh type var
                -- so later assignment (e.g. `local f; f = function()...end`) succeeds.
                bind_tid = types_mod.make_var(ctx, ctx.scope.level)
            elseif last_rhs_is_call then
                -- Cat B: last RHS was a call with unknown arity; treat missing returns as any.
                bind_tid = ctx.T_ANY
            else
                bind_tid = ctx.T_NIL
            end
            env_mod.bind(ctx.scope, name_id, bind_tid)
        end
    end

    -- Track pcall/xpcall bindings for result-variable narrowing.
    -- When `local ok, v1, v2, ... = pcall(fn, ...)`, record the ok→{v1,v2,...} mapping
    -- so that `if ok then` can narrow v1, v2, ... to fn's actual return types.
    local success_types = ctx._last_pcall_success_types
    ctx._last_pcall_success_types = nil
    if success_types and el == 1 and nl >= 2 then
        local ok_name_id = ctx.ast_lists:get(ns + 0)
        local result_name_ids = {}
        for i = 1, nl - 1 do
            result_name_ids[i] = ctx.ast_lists:get(ns + i)
        end
        ctx._pcall_info[ok_name_id] = {
            result_name_ids = result_name_ids,
            success_types   = success_types,
        }
    end
end

StmtRule[NODE_ASSIGN_STMT] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local rhs_count = n.data[3]
    local rhs_types = infer_expr_list(ctx, n.data[2], rhs_count)

    -- Cat B: if the last RHS is a call, missing return slots → T_ANY not T_NIL.
    local last_rhs_is_call = false
    if rhs_count > 0 then
        local last_rhs_nid = ctx.ast_lists:get(n.data[2] + rhs_count - 1)
        local last_rhs_n = ctx.nodes:get(last_rhs_nid)
        last_rhs_is_call = (last_rhs_n.kind == NODE_CALL_EXPR or last_rhs_n.kind == NODE_METHOD_CALL)
    end

    for i = 0, n.data[1] - 1 do
        local target_nid = ctx.ast_lists:get(n.data[0] + i)
        local rhs_tid = rhs_types[i + 1] or (last_rhs_is_call and ctx.T_ANY or ctx.T_NIL)
        local tn = ctx.nodes:get(target_nid)

        if tn.kind == NODE_IDENTIFIER then
            local name_id = tn.data[0]
            local existing = env_mod.lookup(ctx.scope, name_id)
            if existing then
                -- Use the declared type (skipping narrowing-derived bindings) for the
                -- compatibility check, so that assigning inside a narrowing branch (e.g.
                -- `if x == nil then x = "default" end`) checks against the declared
                -- string|nil rather than the narrowed nil.
                local declared = env_mod.lookup_declared(ctx.scope, name_id)
                -- Cat D: widen literals so `local x = false; x = boolExpr` is fine.
                local check_against = types_mod.widen(ctx, declared or existing)
                local ca_resolved   = types_mod.find(ctx, check_against)
                local ca_tag        = ctx.types:get(ca_resolved).tag
                -- Skip check when existing resolved to never: this happens in narrowed
                -- branches (e.g. inside `if not x then`) where the type was eliminated.
                -- Assignment in such branches is always permissive — the code is
                -- logically unreachable under the narrowed assumptions.
                -- Also skip when check_against is an unbound typevar: unifying against a
                -- free typevar would bind it globally across branches (invalidating the
                -- second branch's check). Instead, rebind branch-locally and let the
                -- branch-join later resolve the final type as a union.
                local skip_check = (ca_resolved == ctx.T_NEVER) or (ca_tag == TAG_VAR)
                local ok = true
                if not skip_check then
                    local err
                    ok, err = unify_mod.unify(ctx, rhs_tid, check_against)
                    if not ok then
                        local nm = intern_mod.get(ctx.pool, name_id) or "?"
                        report(ctx, tn.line, tn.col,
                            "cannot assign '" .. types_mod.display(ctx, rhs_tid)
                            .. "' to '" .. nm .. "'" .. (err and (": " .. err) or ""))
                    end
                end
                if ok then
                    -- Rebind in the current scope so branch-local type changes are
                    -- visible to subsequent code in this branch AND diffable by
                    -- branch-join after the if-statement.
                    -- Clear any stale narrowed_names flag for this binding.
                    if ctx.scope.narrowed_names then
                        ctx.scope.narrowed_names[name_id] = nil
                    end
                    env_mod.bind(ctx.scope, name_id, rhs_tid)
                end
            else
                local s = ctx.scope
                while s.parent do s = s.parent end
                env_mod.bind(s, name_id, rhs_tid)
            end
        elseif tn.kind == NODE_FIELD_EXPR then
            local obj_nid = tn.data[0]
            local field_id = tn.data[1]
            local obj_tid = types_mod.find(ctx, infer_expr(ctx, obj_nid))
            local ot = ctx.types:get(obj_tid)
            if ot.tag == TAG_TABLE then
                local fe = types_mod.table_field(ctx, obj_tid, field_id)
                if not fe then
                    table_add_field(ctx, obj_tid, field_id, rhs_tid)
                end
                -- Re-assignment to an existing field: no type check here.
                -- The field type was inferred from the first assignment; we do
                -- not check subsequent ones since index-assignment tracking is
                -- not yet implemented (returns[n] = v keeps returns typed as {}).
                -- Catching wrong-type re-assignment (e.g. `M.fn = "string"` after
                -- `function M.fn()`) is tracked in TODO.md for a future pass.
            end
        elseif tn.kind == NODE_INDEX_EXPR then
            infer_expr(ctx, tn.data[0])
            infer_expr(ctx, tn.data[1])
        end
    end
end

StmtRule[NODE_FUNC_DECL] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local name_nid   = n.data[0]
    local ps, pl     = n.data[1], n.data[2]
    local bs, bl     = n.data[3], n.data[4]
    local has_vararg = (n.flags % (FLAG_VARARG * 2)) >= FLAG_VARARG

    local ann = get_ann(ctx, n.line)
    local ann_fn_tid = nil
    if ann and ann.kind == ANN_TYPE then
        local resolved = resolve_annotation_type(ctx, ann.type_id)
        local rt = ctx.types:get(types_mod.find(ctx, resolved))
        if rt.tag == TAG_FUNCTION then ann_fn_tid = resolved end
    end

    -- Extract the prescan stub's return vars so infer_function can eagerly
    -- bind them when return statements fire, making recursive calls
    -- resolve to the correct return type via find().
    -- Only for unannotated functions; annotated ones use the declared type.
    local stub_ret_vars = nil
    local nn = ctx.nodes:get(name_nid)
    if not ann_fn_tid then
        local stub_tid
        if nn.kind == NODE_IDENTIFIER then
            local sid = env_mod.lookup(ctx.scope, nn.data[0])
            if sid then stub_tid = types_mod.find(ctx, sid) end
        elseif nn.kind == NODE_FIELD_EXPR then
            local obj_n = ctx.nodes:get(nn.data[0])
            if obj_n.kind == NODE_IDENTIFIER then
                local obj_tid = env_mod.lookup(ctx.scope, obj_n.data[0])
                if obj_tid then
                    obj_tid = types_mod.find(ctx, obj_tid)
                    local fe = types_mod.table_field(ctx, obj_tid, nn.data[1])
                    if fe then stub_tid = types_mod.find(ctx, fe.type_id) end
                end
            end
        end
        if stub_tid then
            local st = ctx.types:get(stub_tid)
            if st.tag == TAG_FUNCTION and st.data[3] > 0 then
                stub_ret_vars = {}
                for i = st.data[2], st.data[2] + st.data[3] - 1 do
                    stub_ret_vars[#stub_ret_vars + 1] = ctx.lists:get(i)
                end
            end
        end
    end

    local fn_tid = infer_function(ctx, ps, pl, bs, bl, has_vararg, ann_fn_tid, stub_ret_vars)

    nn = ctx.nodes:get(name_nid)
    if nn.kind == NODE_IDENTIFIER then
        local name_id = nn.data[0]
        local existing = env_mod.lookup(ctx.scope, name_id)
        if existing then
            unify_mod.unify(ctx, fn_tid, existing)
        end
        env_mod.bind(ctx.scope, name_id, fn_tid)
    elseif nn.kind == NODE_FIELD_EXPR then
        -- function M.foo(...): assign to field
        local obj_nid = nn.data[0]
        local field_id = nn.data[1]
        local obj_tid = types_mod.find(ctx, infer_expr(ctx, obj_nid))
        local ot = ctx.types:get(obj_tid)
        if ot.tag == TAG_TABLE then
            local fe = types_mod.table_field(ctx, obj_tid, field_id)
            if fe then
                unify_mod.unify(ctx, fn_tid, fe.type_id)
                fe.type_id = fn_tid
            else
                table_add_field(ctx, obj_tid, field_id, fn_tid)
            end
        end
    end
end

StmtRule[NODE_RETURN_STMT] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local ret_types = infer_expr_list(ctx, n.data[0], n.data[1])
    add_return(ctx, ret_types)
end

StmtRule[NODE_DO_STMT] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local saved = ctx.scope
    ctx.scope = env_mod.child(ctx.scope)
    infer_block(ctx, n.data[0], n.data[1])
    ctx.scope = saved
end

StmtRule[NODE_WHILE_STMT] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    infer_expr(ctx, n.data[0])
    local narrow_mod = require("lib.type.static.v2.narrow")
    local narrowed = narrow_mod.narrow_scope(ctx, n.data[0], true)
    local saved = ctx.scope
    ctx.scope = narrow_mod.apply_narrowed(ctx, narrowed)
    infer_block(ctx, n.data[1], n.data[2])
    ctx.scope = saved
end

StmtRule[NODE_REPEAT_STMT] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local saved = ctx.scope
    ctx.scope = env_mod.child(ctx.scope)
    infer_block(ctx, n.data[1], n.data[2])
    infer_expr(ctx, n.data[0])
    ctx.scope = saved
end

-- Collect the effective type of each parent-scope variable at the end of a branch.
-- Walks the branch_scope chain up to (not including) base_scope and returns
-- { [name_id] -> type_id } for names that already existed in base_scope.
-- This captures narrowings AND assignment rebindings from within the branch.
local function branch_scope_diff(ctx, branch_scope, base_scope)
    local result = {}
    local s = branch_scope
    while s and s ~= base_scope do
        for name_id, type_id in pairs(s.bindings) do
            if result[name_id] == nil then
                -- Only include names that existed before the branch (not new locals).
                if env_mod.lookup(base_scope, name_id) ~= nil then
                    result[name_id] = type_id
                end
            end
        end
        s = s.parent
    end
    return result
end

StmtRule[NODE_IF_STMT] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local narrow_mod = require("lib.type.static.v2.narrow")
    local saved = ctx.scope  -- stable reference; same for all clauses

    -- Per-clause state collected during the loop.
    local guard_narrowings = {}  -- Cat E: negated narrowings from exiting clauses
    local branch_ends    = {}    -- [i] -> { name_id -> type_id } for non-exiting clauses
    local pass_through_neg = {}  -- negated narrowings for the implicit pass-through path
    local has_else       = false

    for i = n.data[0], n.data[0] + n.data[1] - 1 do
        local cn      = ctx.nodes:get(ctx.ast_lists:get(i))
        local test_nid = cn.data[0]

        if test_nid < 0 then
            has_else = true
        else
            infer_expr(ctx, test_nid)
            local narrowed = narrow_mod.narrow_scope(ctx, test_nid, true)
            ctx.scope = narrow_mod.apply_narrowed(ctx, narrowed)
        end

        infer_block(ctx, cn.data[1], cn.data[2])
        local end_scope = ctx.scope  -- end-of-branch state before restore
        ctx.scope = saved

        -- Determine whether this clause exits unconditionally.
        local exits = false
        if cn.data[2] > 0 then
            local last_nid = ctx.ast_lists:get(cn.data[1] + cn.data[2] - 1)
            local last_n   = ctx.nodes:get(last_nid)
            exits = (last_n.kind == NODE_RETURN_STMT or last_n.kind == NODE_BREAK_STMT)
        end

        if test_nid >= 0 and exits then
            -- Cat E guard: negated narrowing narrows the continuation scope.
            local neg = narrow_mod.narrow_scope(ctx, test_nid, false)
            for name_id, type_id in pairs(neg) do
                guard_narrowings[name_id] = type_id
            end
        end

        if not exits then
            -- Collect end-of-branch effective types for branch-join.
            branch_ends[#branch_ends + 1] = branch_scope_diff(ctx, end_scope, saved)
            -- Accumulate negated narrowings for the implicit pass-through path.
            -- (Only conditional clauses contribute; the else clause sets has_else.)
            if test_nid >= 0 then
                local neg = narrow_mod.narrow_scope(ctx, test_nid, false)
                for name_id, type_id in pairs(neg) do
                    pass_through_neg[name_id] = type_id
                end
            end
        end
    end

    -- Step 1: Apply Cat E guard narrowings to the continuation scope.
    if next(guard_narrowings) then
        ctx.scope = narrow_mod.apply_narrowed(ctx, guard_narrowings)
    end

    -- Step 2: Branch join — union per-branch end-types and bind in the continuation.
    -- Collect all names that changed in at least one non-exiting branch.
    local changed = {}
    for _, et in ipairs(branch_ends) do
        for name_id in pairs(et) do changed[name_id] = true end
    end

    if next(changed) then
        local join = {}
        for name_id in pairs(changed) do
            -- post_guard is the type this variable has in the continuation after guards.
            local post_guard = env_mod.lookup(ctx.scope, name_id)
            local members = {}
            local seen    = {}
            local function add_member(t)
                t = types_mod.find(ctx, t)
                if t ~= nil and not seen[t] then
                    seen[t] = true
                    members[#members + 1] = t
                end
            end

            -- Collect types from each non-exiting branch.
            for _, et in ipairs(branch_ends) do
                add_member(et[name_id] or post_guard)
            end

            -- If there is no else clause, the "no branch taken" path also contributes.
            -- Its type is the negated narrowing of the clause condition applied to
            -- post_guard (e.g. after `if x == nil` the pass-through has x non-nil).
            if not has_else then
                local pt = pass_through_neg[name_id] or post_guard
                add_member(pt)
            end

            if #members == 1 then
                join[name_id] = members[1]
            elseif #members > 1 then
                join[name_id] = types_mod.make_union(ctx, members)
            end
        end

        if next(join) then
            ctx.scope = narrow_mod.apply_narrowed(ctx, join)
        end
    end
end

StmtRule[NODE_FOR_NUM] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    infer_expr(ctx, n.data[1])
    infer_expr(ctx, n.data[2])
    if n.data[3] >= 0 then infer_expr(ctx, n.data[3]) end
    local saved = ctx.scope
    ctx.scope = env_mod.child(ctx.scope)
    env_mod.bind(ctx.scope, n.data[0], ctx.T_INTEGER)
    infer_block(ctx, n.data[4], n.data[5])
    ctx.scope = saved
end

StmtRule[NODE_FOR_IN] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    -- Pre-inspect: detect pairs(t)/ipairs(t) with a single argument to extract
    -- element types from the actual table, giving typed loop variables.
    local typed_iter_returns = nil
    if n.data[3] == 1 then
        local call_nid = ctx.ast_lists:get(n.data[2])
        local call_n = ctx.nodes:get(call_nid)
        if call_n.kind == NODE_CALL_EXPR and call_n.data[2] == 1 then
            local callee_n = ctx.nodes:get(call_n.data[0])
            if callee_n.kind == NODE_IDENTIFIER then
                local fn_name = intern_mod.get(ctx.pool, callee_n.data[0]) or ""
                if fn_name == "pairs" or fn_name == "ipairs" then
                    local arg_nid = ctx.ast_lists:get(call_n.data[1])
                    local arg_tid = types_mod.find(ctx, infer_expr(ctx, arg_nid))
                    local at = ctx.types:get(arg_tid)
                    if at.tag == TAG_TABLE and at.data[3] >= 2 then
                        local is = at.data[2]
                        if fn_name == "ipairs" then
                            -- Find numeric indexer → (integer, V)
                            local j = is
                            while j < is + at.data[3] - 1 do
                                local kt = ctx.types:get(types_mod.find(ctx, ctx.lists:get(j)))
                                if kt.tag == defs.TAG_NUMBER or kt.tag == TAG_INTEGER then
                                    typed_iter_returns = {
                                        ctx.T_INTEGER,
                                        types_mod.find(ctx, ctx.lists:get(j + 1))
                                    }
                                    break
                                end
                                j = j + 2
                            end
                        else  -- pairs: use first indexer → (K, V)
                            local k = types_mod.find(ctx, ctx.lists:get(is))
                            local v = types_mod.find(ctx, ctx.lists:get(is + 1))
                            typed_iter_returns = { k, v }
                        end
                    end
                end
            end
        end
    end
    local iter_types = infer_expr_list(ctx, n.data[2], n.data[3])
    local saved = ctx.scope
    ctx.scope = env_mod.child(ctx.scope)
    local ns, nl = n.data[0], n.data[1]
    -- Extract loop-variable types from iterator function's return types.
    -- iter_types[1] is the iterator function; its returns are the loop vars.
    local iter_func_returns = {}
    if #iter_types > 0 then
        local ft = types_mod.find(ctx, iter_types[1])
        local ftt = ctx.types:get(ft)
        if ftt.tag == TAG_FUNCTION then
            for j = ftt.data[2], ftt.data[2] + ftt.data[3] - 1 do
                iter_func_returns[#iter_func_returns + 1] = types_mod.find(ctx, ctx.lists:get(j))
            end
        end
    end
    for i = 0, nl - 1 do
        local name_id = ctx.ast_lists:get(ns + i)
        -- typed_iter_returns (from pairs/ipairs table inspection) takes priority
        local t = (typed_iter_returns and typed_iter_returns[i + 1])
               or iter_func_returns[i + 1]
               or ctx.T_ANY
        env_mod.bind(ctx.scope, name_id, t)
    end
    infer_block(ctx, n.data[4], n.data[5])
    ctx.scope = saved
end

StmtRule[NODE_BREAK_STMT] = function() end

---------------------------------------------------------------------------
-- Type declaration processing
---------------------------------------------------------------------------

local function process_type_decls(ctx)
    if not ctx.ann then return end
    local decls = {}
    for _, result in pairs(ctx.ann.results) do
        if result.kind == ANN_DECL then
            decls[#decls + 1] = result
        end
    end
    -- Pass 1: register names
    for _, r in ipairs(decls) do
        local params = nil
        if r.type_params_len and r.type_params_len > 0 then
            params = {}
            for i = r.type_params_start, r.type_params_start + r.type_params_len - 1 do
                params[#params + 1] = ctx.ann.lists:get(i)
            end
        end
        env_mod.bind_type(ctx.scope, r.name_id, {
            body   = nil,
            params = params,
            nominal = r.newtype or false,
        })
    end
    -- Pass 2: resolve bodies
    for _, r in ipairs(decls) do
        local alias = env_mod.lookup_type(ctx.scope, r.name_id)
        if alias then
            if r.newtype then
                local underlying = resolve_annotation_type(ctx, r.type_id)
                ctx.nominal_id = ctx.nominal_id + 1
                alias.body = types_mod.make_nominal(ctx, r.name_id, ctx.nominal_id, underlying)
            else
                alias.body = resolve_annotation_type(ctx, r.type_id)
            end
        end
    end
end

---------------------------------------------------------------------------
-- Entry point
---------------------------------------------------------------------------

-- Create a fully initialized checker context.
function M.new_ctx(parse_result, ann_result, pool, err_ctx, filename, scope)
    -- types_mod.new_ctx creates the type arena + field arena + type list pool
    local ctx = types_mod.new_ctx(pool)
    -- ctx.lists is the TYPE list pool — don't touch it
    ctx.ast_lists = parse_result.lists  -- AST list pool (read only)
    ctx.nodes     = parse_result.nodes
    ctx.numvals   = parse_result.lexer and parse_result.lexer.numvals or {}
    ctx.pool      = pool
    ctx.ann       = ann_result
    ctx.err       = err_ctx or errors_mod.new_ctx()
    ctx.filename  = filename or "?"
    ctx.scope     = scope or env_mod.new(0)
    ctx.return_types    = {}
    ctx.return_stub_vars = {}  -- stack parallel to return_types; see push_return_collector
    ctx.module_types = {}
    ctx.module_return_tids = nil  -- set after check_string wraps infer_block
    ctx.cri_loader = nil          -- optional: function(ctx, module_name) -> exports_table | nil
    ctx._last_multi_return = nil
    ctx._last_pcall_success_types = nil
    ctx._pcall_info = {}
    ctx.nominal_id = 0
    return ctx
end

-- Check a Lua source string. Returns err_ctx, ctx.
-- Optional cri_loader: function(ctx, module_name) -> type_id | nil
-- Installed on ctx before inference so require() calls resolve at check time.
function M.check_string(source, filename, parent_scope, pool, cri_loader)
    local parse_mod  = require("lib.type.static.v2.parse")
    local intern_new = require("lib.type.static.v2.intern").new
    pool = pool or intern_new()

    local ok_parse, pr = pcall(parse_mod.parse, source, filename, pool)
    if not ok_parse then
        local err_ctx = errors_mod.new_ctx()
        errors_mod.error(err_ctx, filename or "?", 0, 0, tostring(pr))
        return err_ctx
    end

    local ann_result = nil
    local lex_annotations = pr.lexer and pr.lexer.annotations
    if lex_annotations and next(lex_annotations) then
        local ok_ann, ar = pcall(ann_mod.parse_annotations, lex_annotations, pool, filename)
        if ok_ann then ann_result = ar end
    end

    local err_ctx = errors_mod.new_ctx()
    local scope   = parent_scope or env_mod.new(0)
    local ctx     = M.new_ctx(pr, ann_result, pool, err_ctx, filename, scope)

    -- Install cri_loader before inference so require() calls resolve at check time.
    if cri_loader then ctx.cri_loader = cri_loader end

    -- Populate stdlib prelude when no parent scope is provided.
    if not parent_scope then
        require("lib.type.static.v2.prelude").populate(ctx)
    end

    -- Register type declarations first, then prescan, then infer
    process_type_decls(ctx)

    local chunk = pr.root and ctx.nodes:get(pr.root)
    if chunk then
        local bs, bl = chunk.data[0], chunk.data[1]
        prescan_block(ctx, bs, bl)
        push_return_collector(ctx, nil)
        infer_block(ctx, bs, bl)
        ctx.module_return_tids = pop_return_collector(ctx)
    end

    return err_ctx, ctx
end

-- Expose resolve_annotation_type for external use (e.g. check.lua)
M.resolve_annotation_type = resolve_annotation_type

return M
