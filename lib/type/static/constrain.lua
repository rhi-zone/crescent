-- lib/type/static/constrain.lua
-- Constraint generation pass for the v3 typechecker.
-- Walks the AST like infer.lua but emits constraints instead of unifying immediately.

local defs      = require("lib.type.static.defs")
local types_mod = require("lib.type.static.types")
local env_mod   = require("lib.type.static.env")
local errors_mod = require("lib.type.static.errors")
local intern_mod = require("lib.type.static.intern")
local ann_mod    = require("lib.type.static.ann")

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
local LIT_INTEGER = defs.LIT_INTEGER
local LIT_NIL     = defs.LIT_NIL
local i32x2_to_double = defs.i32x2_to_double

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

local ANN_TYPE = defs.ANN_TYPE
local ANN_DECL = defs.ANN_DECL

local TAG_ANY      = defs.TAG_ANY
local TAG_UNKNOWN  = defs.TAG_UNKNOWN
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
local TAG_FORALL   = defs.TAG_FORALL
local TAG_TUPLE    = defs.TAG_TUPLE
local TAG_NEVER    = defs.TAG_NEVER

local E = defs.E

-- ---------------------------------------------------------------------------
-- Constraint kinds
-- ---------------------------------------------------------------------------

local C_UNIFY     = 1   -- {C_UNIFY,     t1, t2, line, col}
local C_SUB       = 2   -- {C_SUB,       actual, expected, line, col}
local C_HAS_FIELD = 3   -- {C_HAS_FIELD, obj_tid, name_id, result_tid, line, col}
local C_CALLABLE  = 4   -- {C_CALLABLE,  callee_tid, arg_tids_list, ret_tid, line, col}
local C_ARITH     = 5   -- {C_ARITH,     op_str, lhs_tid, rhs_tid, result_tid, line, col}
local C_RETURN    = 6   -- {C_RETURN,    val_tid, expected_tid, line, col}

local M = {}

M.C_UNIFY     = C_UNIFY
M.C_SUB       = C_SUB
M.C_HAS_FIELD = C_HAS_FIELD
M.C_CALLABLE  = C_CALLABLE
M.C_ARITH     = C_ARITH
M.C_RETURN    = C_RETURN

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function report(ctx, line, col, code, args)
    local msg = errors_mod.format_diag(code, args)
    return errors_mod.error(ctx.err, ctx.filename, line or 0, col or 0, msg)
end

local function warn(ctx, line, col, code, args)
    local msg = errors_mod.format_diag(code, args)
    errors_mod.warning(ctx.err, ctx.filename, line or 0, col or 0, msg)
end

local function emit(ctx, constraint)
    ctx.constraints[#ctx.constraints + 1] = constraint
end

local function fresh_var(ctx)
    return types_mod.make_var(ctx, ctx.scope.level)
end

-- ---------------------------------------------------------------------------
-- Annotation resolution (copied from infer.lua — identical semantics needed)
-- ---------------------------------------------------------------------------

local resolve_annotation_type

resolve_annotation_type = function(ctx, ann_tid, seen)
    if not ctx.ann then return ctx.T_ANY end
    seen = seen or {}
    if seen[ann_tid] then return ctx.T_ANY end

    local at = ctx.ann.types:get(ann_tid)
    if not at then return ctx.T_ANY end
    local tag = at.tag

    if tag == defs.TAG_NIL      then return ctx.T_NIL end
    if tag == defs.TAG_BOOLEAN  then return ctx.T_BOOLEAN end
    if tag == defs.TAG_NUMBER   then return ctx.T_NUMBER end
    if tag == defs.TAG_STRING   then return ctx.T_STRING end
    if tag == defs.TAG_ANY      then
        if ctx._ann_warn_line then
            warn(ctx, ctx._ann_warn_line, 0, E.EXPLICIT_ANY, {})
            ctx._ann_warn_line = nil
        end
        return ctx.T_ANY
    end
    if tag == defs.TAG_NEVER    then return ctx.T_NEVER end
    if tag == defs.TAG_INTEGER  then return ctx.T_INTEGER end
    if tag == defs.TAG_UNKNOWN  then return ctx.T_UNKNOWN end
    if tag == defs.TAG_CDATA    then
        local id = types_mod.alloc_type(ctx, defs.TAG_CDATA)
        return id
    end

    if tag == TAG_LITERAL then
        if at.data[0] == LIT_NUMBER then
            return types_mod.make_literal(ctx, LIT_NUMBER, i32x2_to_double(at.data[1], at.data[2]))
        end
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
        if resolved then return resolved end
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
        local param_name_ids = nil
        if at.data[6] > 0 then
            param_name_ids = {}
            for i = at.data[5], at.data[5] + at.data[6] - 1 do
                param_name_ids[#param_name_ids + 1] = ctx.ann.lists:get(i)
            end
        end
        seen[ann_tid] = nil
        return types_mod.make_func(ctx, params, returns, vararg_id, param_name_ids)
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

    if tag == defs.TAG_NOMINAL then
        seen[ann_tid] = true
        local underlying = resolve_annotation_type(ctx, at.data[2], seen)
        seen[ann_tid] = nil
        return types_mod.make_nominal(ctx, at.data[0], at.data[1], underlying)
    end

    if tag == defs.TAG_SPREAD then
        seen[ann_tid] = true
        local inner = resolve_annotation_type(ctx, at.data[0], seen)
        seen[ann_tid] = nil
        local id = types_mod.alloc_type(ctx, defs.TAG_SPREAD)
        ctx.types:get(id).data[0] = inner
        return id
    end

    if tag == defs.TAG_INTRINSIC then
        local id = types_mod.alloc_type(ctx, defs.TAG_INTRINSIC)
        ctx.types:get(id).data[0] = at.data[0]
        return id
    end

    if tag == defs.TAG_MATCH_TYPE then
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
        local mk = ctx.lists:mark()
        for _, aid in ipairs(arms) do ctx.lists:push(aid) end
        local ms, ml = ctx.lists:since(mk)
        local id = types_mod.alloc_type(ctx, defs.TAG_MATCH_TYPE)
        local mtt = ctx.types:get(id)
        mtt.data[0] = param
        mtt.data[1] = ms
        mtt.data[2] = ml
        seen[ann_tid] = nil
        local match_mod = require("lib.type.static.match")
        return match_mod.evaluate(ctx, id)
    end

    if tag == defs.TAG_TYPE_CALL then
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
        local mk = ctx.lists:mark()
        for _, aid in ipairs(arg_ids) do ctx.lists:push(aid) end
        local as, al = ctx.lists:since(mk)
        local id = types_mod.alloc_type(ctx, defs.TAG_TYPE_CALL)
        local tct = ctx.types:get(id)
        tct.data[0] = callee
        tct.data[1] = as
        tct.data[2] = al
        return id
    end

    return ctx.T_ANY
end

-- ---------------------------------------------------------------------------
-- Annotation helpers
-- ---------------------------------------------------------------------------

local function get_ann(ctx, line)
    if not ctx.ann then return nil end
    return ctx.ann.results[line] or ctx.ann.results[line - 1]
end

-- ---------------------------------------------------------------------------
-- Forward declarations
-- ---------------------------------------------------------------------------

local gen_expr, gen_stmt, gen_block, gen_function, gen_prescan_block

-- ---------------------------------------------------------------------------
-- Expression constraint generation
-- ---------------------------------------------------------------------------

local ExprRule = {}

gen_expr = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local rule = ExprRule[n.kind]
    if rule then return rule(ctx, nid) end
    report(ctx, n.line, n.col, E.UNHANDLED_EXPR, { kind = n.kind })
    return ctx.T_ANY
end

local function gen_expr_multi(ctx, nid)
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
    return { gen_expr(ctx, nid) }
end

local function gen_expr_list(ctx, es, el)
    if el == 0 then return {} end
    local result = {}
    for i = es, es + el - 2 do
        result[#result + 1] = gen_expr(ctx, ctx.ast_lists:get(i))
    end
    local last_nid = ctx.ast_lists:get(es + el - 1)
    local multi = gen_expr_multi(ctx, last_nid)
    for _, tid in ipairs(multi) do result[#result + 1] = tid end
    return result
end

ExprRule[NODE_LITERAL] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local kind = n.data[0]
    if kind == LIT_NIL     then return ctx.T_NIL end
    if kind == LIT_BOOLEAN then return types_mod.make_literal(ctx, LIT_BOOLEAN, n.data[1]) end
    if kind == LIT_STRING  then return types_mod.make_literal(ctx, LIT_STRING, n.data[1]) end
    if kind == LIT_NUMBER  then
        local num = i32x2_to_double(n.data[1], n.data[2])
        if num % 1 == 0 and num >= -(2^31) and num <= 2^31 - 1 then
            return types_mod.make_literal(ctx, LIT_INTEGER, math.floor(num))
        end
        return types_mod.make_literal(ctx, LIT_NUMBER, num)
    end
    return ctx.T_ANY
end

ExprRule[NODE_IDENTIFIER] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local name_id = n.data[0]
    local ty = env_mod.lookup(ctx.scope, name_id)
    if ty then return ty end
    local name = intern_mod.get(ctx.pool, name_id) or "?"
    report(ctx, n.line, n.col, E.UNKNOWN_IDENTIFIER, { name = name })
    return ctx.T_ANY
end

ExprRule[NODE_VARARG_EXPR] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local vararg_id = intern_mod.intern(ctx.pool, "...")
    local ty = env_mod.lookup(ctx.scope, vararg_id)
    if ty then return ty end
    report(ctx, n.line, n.col, E.VARARG_OUTSIDE_FN, {})
    return ctx.T_ANY
end

ExprRule[NODE_UNARY_EXPR] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local op = n.data[0]
    local arg_tid = gen_expr(ctx, n.data[1])
    if op == OP_NOT then return ctx.T_BOOLEAN end
    if op == OP_UNM then
        local res = fresh_var(ctx)
        emit(ctx, { C_ARITH, "__unm", arg_tid, arg_tid, res, n.line, n.col })
        return res
    end
    if op == OP_LEN then
        return ctx.T_INTEGER
    end
    return ctx.T_ANY
end

ExprRule[NODE_BINARY_EXPR] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local op = n.data[0]

    if op == OP_AND then
        gen_expr(ctx, n.data[1])
        local right_r = types_mod.find(ctx, gen_expr(ctx, n.data[2]))
        return types_mod.make_union(ctx, { ctx.T_NIL, right_r })
    end

    local left_tid  = gen_expr(ctx, n.data[1])
    local right_tid = gen_expr(ctx, n.data[2])

    local ARITH_OPS = {
        [OP_ADD] = "__add", [OP_SUB] = "__sub", [OP_MUL] = "__mul",
        [OP_DIV] = "__div", [OP_MOD] = "__mod", [OP_POW] = "__pow",
    }

    if ARITH_OPS[op] then
        local res = fresh_var(ctx)
        emit(ctx, { C_ARITH, ARITH_OPS[op], left_tid, right_tid, res, n.line, n.col })
        return res
    end

    if op == OP_EQ or op == OP_NE then return ctx.T_BOOLEAN end

    if op == OP_LT or op == OP_GT or op == OP_LE or op == OP_GE then
        return ctx.T_BOOLEAN
    end

    if op == OP_CONCAT then
        return ctx.T_STRING
    end

    if op == OP_OR then
        local non_nil_left = types_mod.subtract(ctx, types_mod.find(ctx, left_tid), ctx.T_NIL)
        return types_mod.make_union(ctx, { non_nil_left, types_mod.find(ctx, right_tid) })
    end

    report(ctx, n.line, n.col, E.BINARY_OP_UNKNOWN, { op = op })
    return ctx.T_ANY
end

ExprRule[NODE_FIELD_EXPR] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local obj_tid = gen_expr(ctx, n.data[0])
    local fname_id = n.data[1]
    local res = fresh_var(ctx)
    emit(ctx, { C_HAS_FIELD, obj_tid, fname_id, res, n.line, n.col })
    return res
end

ExprRule[NODE_INDEX_EXPR] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local obj_tid = types_mod.find(ctx, gen_expr(ctx, n.data[0]))
    local key_tid = gen_expr(ctx, n.data[1])
    local obj_t   = ctx.types:get(obj_tid)

    if obj_t.tag == TAG_NEVER   then return ctx.T_NEVER end
    if obj_t.tag == TAG_UNKNOWN then return ctx.T_UNKNOWN end
    if obj_t.tag == TAG_ANY     then return ctx.T_ANY end

    -- String literal key → treat as named field
    local key_r = types_mod.find(ctx, key_tid)
    local kt_t = ctx.types:get(key_r)
    if kt_t.tag == TAG_LITERAL and kt_t.data[0] == LIT_STRING then
        local res = fresh_var(ctx)
        emit(ctx, { C_HAS_FIELD, obj_tid, kt_t.data[1], res, n.line, n.col })
        return res
    end

    -- Generic index
    if obj_t.tag == TAG_TABLE then
        local is, il = obj_t.data[2], obj_t.data[3]
        local i = is
        while i < is + il - 1 do
            return types_mod.find(ctx, ctx.lists:get(i + 1))
        end
        if obj_t.data[4] >= 0 then return ctx.T_UNKNOWN end
    end

    return ctx.T_ANY
end

ExprRule[NODE_TABLE_EXPR] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local field_ids = {}
    local indexers  = {}
    local pos_idx   = 1
    for i = n.data[0], n.data[0] + n.data[1] - 1 do
        local fld_nid = ctx.ast_lists:get(i)
        local fn = ctx.nodes:get(fld_nid)
        local val_tid = gen_expr(ctx, fn.data[1])
        local key_nid = fn.data[0]

        if key_nid == -1 then
            local pos_key = intern_mod.intern(ctx.pool, tostring(pos_idx))
            field_ids[#field_ids + 1] = types_mod.make_field(ctx, pos_key, val_tid, false)
            pos_idx = pos_idx + 1
        elseif (fn.flags % (FLAG_COMPUTED * 2)) >= FLAG_COMPUTED then
            local key_tid = gen_expr(ctx, key_nid)
            indexers[#indexers + 1] = key_tid
            indexers[#indexers + 1] = val_tid
        else
            local kn = ctx.nodes:get(key_nid)
            local name_id = kn.data[1]
            field_ids[#field_ids + 1] = types_mod.make_field(ctx, name_id, val_tid, false)
        end
    end
    return types_mod.make_table(ctx, field_ids, indexers, -1, {})
end

-- Generate constraints for a function body.
-- Returns the function type_id.
gen_function = function(ctx, ps, pl, bs, bl, has_vararg, ann_fn_tid)
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

    if not has_ann_fn then
        for i = 0, pl - 1 do
            local name_id = ctx.ast_lists:get(ps + i)
            local pt_id = types_mod.make_var(ctx, fn_scope.level)
            env_mod.bind(fn_scope, name_id, pt_id)
            param_tids[#param_tids + 1] = pt_id
        end
        if has_vararg then
            local dots_id = intern_mod.intern(ctx.pool, "...")
            env_mod.bind(fn_scope, dots_id, ctx.T_ANY)
        end
    end

    local saved = ctx.scope
    ctx.scope = fn_scope

    -- Fresh return variable for this function
    local ret_var = types_mod.make_var(ctx, fn_scope.level)
    ctx.return_vars[#ctx.return_vars + 1] = ret_var

    gen_prescan_block(ctx, bs, bl)
    gen_block(ctx, bs, bl)

    ctx.return_vars[#ctx.return_vars] = nil
    ctx.scope = saved

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
        returns = { ret_var }
    end

    local vararg_id = has_vararg and ctx.T_ANY or -1
    local param_name_ids = {}
    for i = 0, pl - 1 do param_name_ids[i + 1] = ctx.ast_lists:get(ps + i) end
    local fn_tid = types_mod.make_func(ctx, param_tids, returns, vararg_id, param_name_ids)

    -- Generalize: replace free vars in fn_tid with ForAll-bound vars.
    -- This gives let-polymorphism for unannotated local functions.
    if not has_ann_fn then
        env_mod.generalize(ctx, fn_tid, saved.level)
    end

    return fn_tid
end

ExprRule[NODE_FUNC_EXPR] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local has_vararg = (n.flags % (FLAG_VARARG * 2)) >= FLAG_VARARG
    local ann = get_ann(ctx, n.line)
    local ann_fn_tid = nil
    if ann and ann.kind == ANN_TYPE then
        ctx._ann_warn_line = n.line
        local resolved = resolve_annotation_type(ctx, ann.type_id)
        ctx._ann_warn_line = nil
        local rt = ctx.types:get(types_mod.find(ctx, resolved))
        if rt.tag == TAG_FUNCTION then ann_fn_tid = resolved end
    end
    return gen_function(ctx, n.data[0], n.data[1], n.data[2], n.data[3], has_vararg, ann_fn_tid)
end

ExprRule[NODE_CALL_EXPR] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local callee_nid = n.data[0]
    local callee_tid = gen_expr(ctx, callee_nid)
    local arg_tids = gen_expr_list(ctx, n.data[1], n.data[2])

    -- require() passthrough
    local callee_n = ctx.nodes:get(callee_nid)
    if callee_n.kind == NODE_IDENTIFIER and n.data[2] >= 1 then
        local fname = intern_mod.get(ctx.pool, callee_n.data[0]) or ""
        if fname == "require" then
            local arg0_nid = ctx.ast_lists:get(n.data[1])
            local arg0_n = ctx.nodes:get(arg0_nid)
            if arg0_n and arg0_n.kind == NODE_LITERAL and arg0_n.data[2] == LIT_STRING then
                local mod_name = intern_mod.get(ctx.pool, arg0_n.data[1]) or ""
                ctx._last_require_mod = mod_name
                if ctx.cri_loader then
                    local exports = ctx.cri_loader(ctx, mod_name)
                    if exports then
                        ctx._last_multi_return = { exports }
                        return exports
                    end
                end
            end
        end
    end

    -- Instantiate callee at this call site (let-polymorphism)
    local inst_callee = env_mod.instantiate(ctx, callee_tid, ctx.scope.level)

    local ret = fresh_var(ctx)
    emit(ctx, { C_CALLABLE, inst_callee, arg_tids, ret, n.line, n.col })
    ctx._last_multi_return = { ret }
    return ret
end

ExprRule[NODE_METHOD_CALL] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local recv_tid = gen_expr(ctx, n.data[0])
    local method_name_id = n.data[1]

    -- Get method field
    local method_var = fresh_var(ctx)
    emit(ctx, { C_HAS_FIELD, recv_tid, method_name_id, method_var, n.line, n.col })

    local extra = gen_expr_list(ctx, n.data[2], n.data[3])
    local arg_tids = { recv_tid }
    for _, a in ipairs(extra) do arg_tids[#arg_tids + 1] = a end

    local inst_method = env_mod.instantiate(ctx, method_var, ctx.scope.level)

    local ret = fresh_var(ctx)
    emit(ctx, { C_CALLABLE, inst_method, arg_tids, ret, n.line, n.col })
    ctx._last_multi_return = { ret }
    return ret
end

-- ---------------------------------------------------------------------------
-- Block / statement generation
-- ---------------------------------------------------------------------------

gen_block = function(ctx, bs, bl)
    for i = bs, bs + bl - 1 do
        gen_stmt(ctx, ctx.ast_lists:get(i))
    end
end

local StmtRule = {}

gen_stmt = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local rule = StmtRule[n.kind]
    if rule then rule(ctx, nid) end
end

StmtRule[NODE_EXPR_STMT] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    gen_expr(ctx, n.data[0])
end

StmtRule[NODE_LOCAL_STMT] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local ns, nl = n.data[0], n.data[1]
    local es, el = n.data[2], n.data[3]

    ctx._last_require_mod = nil
    local rhs_types = el > 0 and gen_expr_list(ctx, es, el) or {}
    local stmt_require_mod = ctx._last_require_mod
    ctx._last_require_mod = nil

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
            ctx._ann_warn_line = n.line
            ann_tid = resolve_annotation_type(ctx, ann.type_id)
            ctx._ann_warn_line = nil
        end

        local prescanned = ctx.scope.bindings[name_id]

        if ann_tid then
            if rhs_tid then
                emit(ctx, { C_SUB, rhs_tid, ann_tid, n.line, n.col })
            end
            env_mod.bind(ctx.scope, name_id, ann_tid)
            ctx.def_sites[name_id] = { line = n.line, col = n.col }
            if stmt_require_mod and i == 0 and el == 1 then
                ctx.require_sources[name_id] = stmt_require_mod
            end
        elseif prescanned then
            if rhs_tid then
                emit(ctx, { C_UNIFY, rhs_tid, prescanned, n.line, n.col })
            end
        else
            local bind_tid
            if rhs_tid then
                local rt = ctx.types:get(types_mod.find(ctx, rhs_tid))
                if rt.tag == TAG_LITERAL and rt.data[0] == LIT_BOOLEAN then
                    bind_tid = ctx.T_BOOLEAN
                elseif rt.tag == defs.TAG_NIL then
                    bind_tid = types_mod.make_var(ctx, ctx.scope.level)
                else
                    bind_tid = rhs_tid
                end
            elseif el == 0 then
                bind_tid = types_mod.make_var(ctx, ctx.scope.level)
            elseif last_rhs_is_call then
                bind_tid = ctx.T_ANY
            else
                bind_tid = ctx.T_NIL
            end
            env_mod.bind(ctx.scope, name_id, bind_tid)
            ctx.def_sites[name_id] = { line = n.line, col = n.col }
            if stmt_require_mod and i == 0 and el == 1 then
                ctx.require_sources[name_id] = stmt_require_mod
            end
        end
    end
end

StmtRule[NODE_ASSIGN_STMT] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local rhs_count = n.data[3]
    local rhs_types = gen_expr_list(ctx, n.data[2], rhs_count)

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
                local declared = env_mod.lookup_declared(ctx.scope, name_id)
                local check_against = types_mod.widen(ctx, declared or existing)
                local ca_resolved = types_mod.find(ctx, check_against)
                local ca_tag = ctx.types:get(ca_resolved).tag
                if ca_tag ~= TAG_VAR and ca_resolved ~= ctx.T_NEVER then
                    emit(ctx, { C_SUB, rhs_tid, check_against, tn.line, tn.col })
                end
                env_mod.bind(ctx.scope, name_id, rhs_tid)
            else
                local s = ctx.scope
                while s.parent do s = s.parent end
                env_mod.bind(s, name_id, rhs_tid)
            end
        elseif tn.kind == NODE_FIELD_EXPR then
            local obj_nid = tn.data[0]
            local field_id = tn.data[1]
            local obj_tid = types_mod.find(ctx, gen_expr(ctx, obj_nid))
            local ot = ctx.types:get(obj_tid)
            if ot.tag == TAG_TABLE then
                local fe = types_mod.table_field(ctx, obj_tid, field_id)
                if not fe then
                    -- Add field (same as infer.lua table_add_field)
                    local fields, indexers, rv, meta = {}, {}, ot.data[4], {}
                    local fs, fl = ot.data[0], ot.data[1]
                    for j = fs, fs + fl - 1 do fields[#fields + 1] = ctx.lists:get(j) end
                    local is2, il2 = ot.data[2], ot.data[3]
                    local ix = is2
                    while ix < is2 + il2 - 1 do
                        indexers[#indexers + 1] = ctx.lists:get(ix)
                        indexers[#indexers + 1] = ctx.lists:get(ix + 1)
                        ix = ix + 2
                    end
                    for j = ot.data[5], ot.data[5] + ot.data[6] - 1 do meta[#meta + 1] = ctx.lists:get(j) end
                    fields[#fields + 1] = types_mod.make_field(ctx, field_id, rhs_tid, false)
                    local new_tbl = types_mod.make_table(ctx, fields, indexers, rv, meta)
                    local ot2 = ctx.types:get(obj_tid)
                    local new_t = ctx.types:get(new_tbl)
                    for k = 0, 6 do ot2.data[k] = new_t.data[k] end
                end
            end
        end
    end
end

StmtRule[NODE_DO_STMT] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local saved = ctx.scope
    ctx.scope = env_mod.child(ctx.scope)
    gen_block(ctx, n.data[0], n.data[1])
    ctx.scope = saved
end

StmtRule[NODE_WHILE_STMT] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    gen_expr(ctx, n.data[0])
    local saved = ctx.scope
    ctx.scope = env_mod.child(ctx.scope)
    gen_block(ctx, n.data[1], n.data[2])
    ctx.scope = saved
end

StmtRule[NODE_REPEAT_STMT] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local saved = ctx.scope
    ctx.scope = env_mod.child(ctx.scope)
    gen_block(ctx, n.data[0], n.data[1])
    gen_expr(ctx, n.data[2])
    ctx.scope = saved
end

StmtRule[NODE_IF_STMT] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local saved = ctx.scope
    for i = n.data[0], n.data[0] + n.data[1] - 1 do
        local cn = ctx.nodes:get(ctx.ast_lists:get(i))
        local test_nid = cn.data[0]
        ctx.scope = env_mod.child(saved)
        if test_nid >= 0 then gen_expr(ctx, test_nid) end
        gen_block(ctx, cn.data[1], cn.data[2])
        ctx.scope = saved
    end
end

StmtRule[NODE_FOR_NUM] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    gen_expr(ctx, n.data[1])
    gen_expr(ctx, n.data[2])
    if n.data[3] >= 0 then gen_expr(ctx, n.data[3]) end
    local saved = ctx.scope
    ctx.scope = env_mod.child(ctx.scope)
    env_mod.bind(ctx.scope, n.data[0], ctx.T_INTEGER)
    gen_block(ctx, n.data[4], n.data[5])
    ctx.scope = saved
end

StmtRule[NODE_FOR_IN] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local iter_types = gen_expr_list(ctx, n.data[2], n.data[3])
    local saved = ctx.scope
    ctx.scope = env_mod.child(ctx.scope)
    local ns, nl = n.data[0], n.data[1]
    for i = 0, nl - 1 do
        local name_id = ctx.ast_lists:get(ns + i)
        env_mod.bind(ctx.scope, name_id, ctx.T_ANY)
    end
    gen_block(ctx, n.data[4], n.data[5])
    ctx.scope = saved
end

StmtRule[NODE_RETURN_STMT] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local ret_tids = gen_expr_list(ctx, n.data[0], n.data[1])
    local ret_var = ctx.return_vars[#ctx.return_vars]
    if ret_var then
        local ret_tid = ret_tids[1] or ctx.T_NIL
        emit(ctx, { C_RETURN, ret_tid, ret_var, n.line, n.col })
    end
end

StmtRule[NODE_BREAK_STMT] = function() end

StmtRule[NODE_FUNC_DECL] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local name_n = ctx.nodes:get(n.data[0])
    local has_vararg = (n.flags % (FLAG_VARARG * 2)) >= FLAG_VARARG

    local ann = get_ann(ctx, n.line)
    local ann_fn_tid = nil
    if ann and ann.kind == ANN_TYPE then
        ctx._ann_warn_line = n.line
        local resolved = resolve_annotation_type(ctx, ann.type_id)
        ctx._ann_warn_line = nil
        local rt = ctx.types:get(types_mod.find(ctx, resolved))
        if rt.tag == TAG_FUNCTION then ann_fn_tid = resolved end
    end

    local fn_tid = gen_function(ctx, n.data[1], n.data[2], n.data[3], n.data[4], has_vararg, ann_fn_tid)

    if name_n.kind == NODE_IDENTIFIER then
        local name_id = name_n.data[0]
        local existing = env_mod.lookup(ctx.scope, name_id)
        if existing then
            emit(ctx, { C_UNIFY, fn_tid, existing, n.line, n.col })
        end
        env_mod.bind(ctx.scope, name_id, fn_tid)
        ctx.def_sites[name_id] = { line = n.line, col = n.col }
    elseif name_n.kind == NODE_FIELD_EXPR then
        local obj_nid = name_n.data[0]
        local field_id = name_n.data[1]
        local obj_tid = types_mod.find(ctx, gen_expr(ctx, obj_nid))
        local ot = ctx.types:get(obj_tid)
        if ot.tag == TAG_TABLE then
            local fe = types_mod.table_field(ctx, obj_tid, field_id)
            if not fe then
                local fields, indexers, rv, meta = {}, {}, ot.data[4], {}
                local fs, fl = ot.data[0], ot.data[1]
                for j = fs, fs + fl - 1 do fields[#fields + 1] = ctx.lists:get(j) end
                local is2, il2 = ot.data[2], ot.data[3]
                local ix = is2
                while ix < is2 + il2 - 1 do
                    indexers[#indexers + 1] = ctx.lists:get(ix)
                    indexers[#indexers + 1] = ctx.lists:get(ix + 1)
                    ix = ix + 2
                end
                for j = ot.data[5], ot.data[5] + ot.data[6] - 1 do meta[#meta + 1] = ctx.lists:get(j) end
                fields[#fields + 1] = types_mod.make_field(ctx, field_id, fn_tid, false)
                local new_tbl = types_mod.make_table(ctx, fields, indexers, rv, meta)
                local ot2 = ctx.types:get(obj_tid)
                local new_t = ctx.types:get(new_tbl)
                for k = 0, 6 do ot2.data[k] = new_t.data[k] end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Prescan (forward declarations, mirrors infer.lua prescan_block)
-- ---------------------------------------------------------------------------

local function make_prescan_stub(ctx, pl)
    local param_anys = {}
    for i = 1, pl do param_anys[i] = ctx.T_ANY end
    local ret_var = types_mod.make_var(ctx, ctx.scope.level)
    return types_mod.make_func(ctx, param_anys, { ret_var }, -1)
end

gen_prescan_block = function(ctx, bs, bl)
    for i = bs, bs + bl - 1 do
        local sid = ctx.ast_lists:get(i)
        local sn  = ctx.nodes:get(sid)
        if sn.kind == NODE_FUNC_DECL then
            local nn = ctx.nodes:get(sn.data[0])
            local pl = sn.data[2]
            if nn.kind == NODE_IDENTIFIER then
                local name_id = nn.data[0]
                if not env_mod.lookup(ctx.scope, name_id) then
                    env_mod.bind(ctx.scope, name_id, make_prescan_stub(ctx, pl))
                end
            elseif nn.kind == NODE_FIELD_EXPR then
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
                                local fields, indexers, rv, meta = {}, {}, ot.data[4], {}
                                local fs, fl = ot.data[0], ot.data[1]
                                for j = fs, fs + fl - 1 do fields[#fields + 1] = ctx.lists:get(j) end
                                local is2, il2 = ot.data[2], ot.data[3]
                                local ix = is2
                                while ix < is2 + il2 - 1 do
                                    indexers[#indexers + 1] = ctx.lists:get(ix)
                                    indexers[#indexers + 1] = ctx.lists:get(ix + 1)
                                    ix = ix + 2
                                end
                                for j = ot.data[5], ot.data[5] + ot.data[6] - 1 do meta[#meta + 1] = ctx.lists:get(j) end
                                fields[#fields + 1] = types_mod.make_field(ctx, field_id, make_prescan_stub(ctx, pl), false)
                                local new_tbl = types_mod.make_table(ctx, fields, indexers, rv, meta)
                                local ot2 = ctx.types:get(obj_tid)
                                local new_t = ctx.types:get(new_tbl)
                                for k = 0, 6 do ot2.data[k] = new_t.data[k] end
                            end
                        end
                    end
                end
            end
        elseif sn.kind == NODE_LOCAL_STMT then
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

-- ---------------------------------------------------------------------------
-- Type declaration processing
-- ---------------------------------------------------------------------------

local function process_type_decls(ctx)
    if not ctx.ann then return end
    if ctx.ann.warnings then
        for _, w in ipairs(ctx.ann.warnings) do
            errors_mod.warning(ctx.err, ctx.filename, w.line or 0, w.col or 0, w.msg)
        end
    end
    local decls = {}
    local decl_lines = {}
    for line, result in pairs(ctx.ann.results) do
        if result.kind == ANN_DECL then
            decls[#decls + 1] = result
            decl_lines[result] = line
        end
    end
    for _, r in ipairs(decls) do
        if not r.decl_var then
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
    end
    for _, r in ipairs(decls) do
        if r.decl_var then
            env_mod.bind(ctx.scope, r.name_id, resolve_annotation_type(ctx, r.type_id))
        else
            local alias = env_mod.lookup_type(ctx.scope, r.name_id)
            if alias then
                if r.newtype then
                    local ann_nom = ctx.ann.types:get(r.type_id)
                    local underlying = resolve_annotation_type(ctx, ann_nom.data[2])
                    ctx.nominal_id = ctx.nominal_id + 1
                    alias.body = types_mod.make_nominal(ctx, r.name_id, ctx.nominal_id, underlying)
                else
                    alias.body = resolve_annotation_type(ctx, r.type_id)
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

-- Run constraint generation on a parsed source.
-- Returns {ctx, constraints} where ctx is the fully-initialized checker context
-- and constraints is the flat constraint array.
function M.generate(source, filename, parent_scope, pool, cri_loader)
    local parse_mod  = require("lib.type.static.parse")
    local intern_new = require("lib.type.static.intern").new
    pool = pool or intern_new()

    local scope = parent_scope or env_mod.new(0)
    local ctx = types_mod.new_ctx(pool)
    ctx.scope              = scope
    ctx.ann                = nil
    ctx.err                = errors_mod.new_ctx()
    ctx.filename           = filename or "?"
    ctx.return_types       = {}
    ctx.return_stub_vars   = {}
    ctx.return_vars        = {}   -- v3: stack of return type variables
    ctx.module_types       = {}
    ctx.module_return_tids = nil
    ctx.cri_loader         = nil
    ctx.ffi_hooks          = nil
    ctx._last_multi_return = nil
    ctx._last_require_mod  = nil
    ctx._pcall_info        = {}
    ctx.nominal_id         = 0
    ctx.inferred_anns      = {}
    ctx.type_at            = {}
    ctx.name_at            = {}
    ctx.field_at           = {}
    ctx.def_sites          = {}
    ctx.require_sources    = {}
    ctx.constraints        = {}   -- v3: emitted constraints

    if not parent_scope then
        require("lib.type.static.prelude").populate(ctx)
    end

    local ok_parse, pr = pcall(parse_mod.parse, source, filename, pool)
    if not ok_parse then
        errors_mod.error(ctx.err, filename or "?", 0, 0, tostring(pr))
        return ctx, {}
    end

    ctx.ast_lists = pr.lists
    ctx.nodes     = pr.nodes

    errors_mod.set_source(ctx.err, filename or "?", source)

    local lex_annotations = pr.lexer and pr.lexer.annotations
    if lex_annotations and next(lex_annotations) then
        local ok_ann, ar = pcall(ann_mod.parse_annotations, lex_annotations, pool, filename)
        if ok_ann then ctx.ann = ar end
    end

    if cri_loader then ctx.cri_loader = cri_loader end

    if ctx.ffi_hooks and ctx.ffi_hooks.init then
        ctx.ffi_hooks.init(ctx)
    end

    process_type_decls(ctx)

    local chunk = pr.root and ctx.nodes:get(pr.root)
    if chunk then
        local bs, bl = chunk.data[0], chunk.data[1]
        gen_prescan_block(ctx, bs, bl)

        local module_ret_var = types_mod.make_var(ctx, ctx.scope.level)
        ctx.return_vars[1] = module_ret_var
        gen_block(ctx, bs, bl)
        ctx.return_vars[1] = nil
        ctx.module_return_tids = { { module_ret_var } }
    end

    return ctx, ctx.constraints
end

return M
