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
local FLAG_READONLY = defs.FLAG_READONLY
local FLAG_OPTIONAL = defs.FLAG_OPTIONAL
local FLAG_PRIVATE  = defs.FLAG_PRIVATE
local band          = require("bit").band
local bor           = require("bit").bor

-- Compute field flags, auto-setting FLAG_PRIVATE for `_`-prefixed names.
local function field_flags(ctx, name_id, base_flags)
    base_flags = base_flags or 0
    if type(base_flags) == "boolean" then
        base_flags = base_flags and FLAG_OPTIONAL or 0
    end
    local name = require("lib.type.static.intern").get(ctx.pool, name_id) or ""
    if name:sub(1, 1) == "_" then
        base_flags = bor(base_flags, FLAG_PRIVATE)
    end
    return base_flags
end

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
local TAG_NEVER       = defs.TAG_NEVER
local TAG_ENUM_MEMBER = defs.TAG_ENUM_MEMBER

local E = defs.E

-- ---------------------------------------------------------------------------
-- Constraint kinds
-- ---------------------------------------------------------------------------

local C_UNIFY     = 1   -- {C_UNIFY,    t1, t2, line, col}
local C_SUB       = 2   -- {C_SUB,      actual, expected, line, col}
local C_CALLABLE  = 4   -- {C_CALLABLE, callee_tid, arg_tids_list, ret_tid, line, col}
local C_ARITH     = 5   -- {C_ARITH,    op_str, lhs_tid, rhs_tid, result_tid, line, col}
local C_RETURN    = 6   -- {C_RETURN,   val_tid, expected_tid, line, col}
local C_COMPARE   = 7   -- {C_COMPARE,  lhs_tid, rhs_tid, line, col}
local C_INDEX     = 8   -- {C_INDEX,    obj_tid, key_tid, result_tid, line, col}
-- key_tid: TAG_LITERAL(LIT_STRING, name_id) for field; TAG_LITERAL(LIT_INTEGER, slot) for tuple slot

local M = {}

M.C_UNIFY     = C_UNIFY
M.C_SUB       = C_SUB
M.C_INDEX     = C_INDEX
M.C_CALLABLE  = C_CALLABLE
M.C_ARITH     = C_ARITH
M.C_RETURN    = C_RETURN
M.C_COMPARE   = C_COMPARE

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
            -- Allow unapplied type constructors as HKT arguments (e.g. Maybe in map<Maybe, A, B>).
            local prev_allow = ctx._allow_unapplied_constructors
            ctx._allow_unapplied_constructors = true
            for i = at.data[1], at.data[1] + args_len - 1 do
                arg_ids[#arg_ids + 1] = resolve_annotation_type(ctx, ctx.ann.lists:get(i), seen)
            end
            ctx._allow_unapplied_constructors = prev_allow
            seen[ann_tid] = nil
        end
        -- Literal boolean types: `true` / `false` are valid type-level names.
        local intern_local = require("lib.type.static.intern")
        local name_str = intern_local.get(ctx.pool, name_id) or ""
        if name_str == "true"  then return types_mod.make_literal(ctx, LIT_BOOLEAN, 1) end
        if name_str == "false" then return types_mod.make_literal(ctx, LIT_BOOLEAN, 0) end

        -- Check if the alias exists at all; only emit an error for truly undefined names.
        local alias = env_mod.lookup_type(ctx.scope, name_id)
        if not alias then
            local err_line = ctx._ann_warn_line or 0
            errors_mod.error(ctx.err, ctx.filename, err_line, 0, "undefined type '" .. name_str .. "'")
            return ctx.T_ANY
        end

        -- If no type args were provided and the alias is generic (has params),
        -- allow unapplied constructor only when explicitly requested by the caller
        -- (e.g. when resolving args for a TAG_INTRINSIC type-call like $EachUnion).
        -- In all other contexts (value types, alias bodies) emit the arity error.
        if not arg_ids and alias.params and #alias.params > 0
          and ctx._allow_unapplied_constructors then
            local id = types_mod.alloc_type(ctx, TAG_NAMED)
            ctx.types:get(id).data[0] = name_id
            return id
        end

        local resolved, resolve_err = env_mod.resolve_named_type(ctx, ctx.scope, name_id, arg_ids)
        if resolved then return resolved end
        -- Arity mismatch or similar resolution error.
        if resolve_err then
            -- HKT deferred application: F<A> where F is a type variable (forall param or
            -- generic alias placeholder). Only applies when the alias has NO type params of
            -- its own (the error is arity mismatch: "does not take type arguments") AND the
            -- alias body is an abstract type (TAG_VAR = forall param; TAG_NAMED = placeholder).
            -- Constraint violations (alias HAS params, arg fails bound check) are NOT deferred.
            if arg_ids and #arg_ids > 0 and alias.body
                and (not alias.params or #alias.params == 0) then
                local body_id = types_mod.find(ctx, alias.body)
                local bt = ctx.types:get(body_id)
                if bt.tag == TAG_VAR or bt.tag == TAG_NAMED then
                    -- Produce TAG_TYPE_CALL(body, args): resolved at instantiation time.
                    local mk = ctx.lists:mark()
                    for _, aid in ipairs(arg_ids) do ctx.lists:push(aid) end
                    local as, al = ctx.lists:since(mk)
                    local id = types_mod.alloc_type(ctx, defs.TAG_TYPE_CALL)
                    ctx.types:get(id).data[0] = body_id
                    ctx.types:get(id).data[1] = as
                    ctx.types:get(id).data[2] = al
                    return id
                end
            end
            errors_mod.error(ctx.err, ctx.filename, ctx._ann_warn_line or 0, 0, resolve_err)
            return ctx.T_ANY
        end
        -- alias.body == nil: self-referential or forward-ref during construction.
        -- Fall back to an opaque TAG_NAMED placeholder (will be substituted on use).
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
            field_ids[#field_ids + 1] = types_mod.make_field(ctx, fe.name_id, ft, fe.flags)
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
            meta_ids[#meta_ids + 1] = types_mod.make_field(ctx, fe.name_id, ft, fe.flags)
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
        local ct = ctx.types:get(callee)
        -- When the callee is a TAG_INTRINSIC, allow unapplied generic aliases
        -- as type constructor arguments (e.g. $EachUnion<T, ToString>).
        local prev_allow = ctx._allow_unapplied_constructors
        if ct.tag == defs.TAG_INTRINSIC then
            ctx._allow_unapplied_constructors = true
        end
        local arg_ids = {}
        for i = at.data[1], at.data[1] + at.data[2] - 1 do
            arg_ids[#arg_ids + 1] = resolve_annotation_type(ctx, ctx.ann.lists:get(i), seen)
        end
        ctx._allow_unapplied_constructors = prev_allow
        seen[ann_tid] = nil
        if ct.tag == TAG_NAMED then
            local resolved = env_mod.resolve_named_type(ctx, ctx.scope, ct.data[0], arg_ids)
            if resolved then return resolved end
        end
        if ct.tag == defs.TAG_INTRINSIC then
            local intrinsic_mod = require("lib.type.static.intrinsic")
            return intrinsic_mod.expand(ctx, ct.data[0], arg_ids)
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
    local consumed = ctx._ann_consumed
    local r = ctx.ann.results[line]
    if r and not (consumed and consumed[line]) then return r end
    local r1 = ctx.ann.results[line - 1]
    if r1 and not (consumed and consumed[line - 1]) then return r1 end
    return nil
end

local function consume_ann(ctx, line)
    local r  = ctx.ann and ctx.ann.results[line]
    local r1 = ctx.ann and ctx.ann.results[line - 1]
    -- Only consume ANN_TYPE entries (not ANN_DECL, which are type-alias declarations).
    if (r  and r.kind  == ANN_TYPE) or
       (r1 and r1.kind == ANN_TYPE) then
        ctx._ann_consumed = ctx._ann_consumed or {}
        if r  and r.kind  == ANN_TYPE then ctx._ann_consumed[line]     = true end
        if r1 and r1.kind == ANN_TYPE then ctx._ann_consumed[line - 1] = true end
    end
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
        local res = fresh_var(ctx)
        emit(ctx, { C_ARITH, "__len", arg_tid, arg_tid, res, n.line, n.col })
        return res
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
        emit(ctx, { C_COMPARE, left_tid, right_tid, n.line, n.col })
        return ctx.T_BOOLEAN
    end

    if op == OP_CONCAT then
        local res = fresh_var(ctx)
        emit(ctx, { C_ARITH, "__concat", left_tid, right_tid, res, n.line, n.col })
        return res
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
    local obj_nid = n.data[0]
    local obj_tid = gen_expr(ctx, obj_nid)
    local fname_id = n.data[1]
    local res = fresh_var(ctx)
    emit(ctx, { C_INDEX, obj_tid, types_mod.make_literal(ctx, LIT_STRING, fname_id), res, n.line, n.col })
    -- Track field access for LSP go-to-def (only for simple identifier objects)
    local obj_n = ctx.nodes:get(obj_nid)
    if obj_n.kind == NODE_IDENTIFIER then
        local fa = ctx.field_at
        fa[#fa+1] = n.line
        fa[#fa+1] = n.col
        fa[#fa+1] = fname_id
        fa[#fa+1] = obj_n.data[0]  -- name_id of the object
    end
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
        emit(ctx, { C_INDEX, obj_tid, types_mod.make_literal(ctx, LIT_STRING, kt_t.data[1]), res, n.line, n.col })
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
            field_ids[#field_ids + 1] = types_mod.make_field(ctx, pos_key, val_tid, field_flags(ctx, pos_key))
            pos_idx = pos_idx + 1
        elseif (fn.flags % (FLAG_COMPUTED * 2)) >= FLAG_COMPUTED then
            local key_tid = gen_expr(ctx, key_nid)
            indexers[#indexers + 1] = key_tid
            indexers[#indexers + 1] = val_tid
        else
            local kn = ctx.nodes:get(key_nid)
            local name_id = kn.data[1]
            field_ids[#field_ids + 1] = types_mod.make_field(ctx, name_id, val_tid, field_flags(ctx, name_id))
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

    -- Fresh return variable for this function.
    -- Use saved.level so generalize does NOT mark it generic; the solve pass will
    -- bind it to the actual union of return types from the body.
    local ret_var = types_mod.make_var(ctx, saved.level)
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

-- Peek at the declared return type of a callee without going through constraint
-- variables. Returns the concrete ret-slot type id, or nil if not resolvable.
-- Used to detect union-of-tuples return types (e.g. string.find, io.open) so
-- that LOCAL_STMT can correlate bindings at narrowing time.
local function peek_callee_ret_union(ctx, callee_n)
    local fn_tid = nil
    if callee_n.kind == NODE_IDENTIFIER then
        local tid = env_mod.lookup(ctx.scope, callee_n.data[0])
        if tid then fn_tid = types_mod.find(ctx, tid) end
    elseif callee_n.kind == NODE_FIELD_EXPR then
        local obj_n = ctx.nodes:get(callee_n.data[0])
        if obj_n.kind == NODE_IDENTIFIER then
            local obj_tid = env_mod.lookup(ctx.scope, obj_n.data[0])
            if obj_tid then
                obj_tid = types_mod.find(ctx, obj_tid)
                local fe = types_mod.table_field(ctx, obj_tid, callee_n.data[1])
                if fe then fn_tid = types_mod.find(ctx, fe.type_id) end
            end
        end
    end
    if not fn_tid then return nil end
    local fn_t = ctx.types:get(fn_tid)
    if fn_t.tag ~= TAG_FUNCTION or fn_t.data[3] ~= 1 then return nil end
    local ret_slot = types_mod.find(ctx, ctx.lists:get(fn_t.data[2]))
    local ret_t = ctx.types:get(ret_slot)
    if ret_t.tag ~= TAG_UNION then return nil end
    for i = ret_t.data[0], ret_t.data[0] + ret_t.data[1] - 1 do
        local arm = types_mod.find(ctx, ctx.lists:get(i))
        if ctx.types:get(arm).tag ~= TAG_TUPLE then return nil end
    end
    return ret_slot
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

    -- ffi.cdef() passthrough: register C type declarations into annotation namespace.
    if callee_n.kind == NODE_FIELD_EXPR and ctx.ffi_hooks and n.data[2] >= 1 then
        local obj_n = ctx.nodes:get(callee_n.data[0])
        if obj_n.kind == NODE_IDENTIFIER then
            local obj_name   = intern_mod.get(ctx.pool, obj_n.data[0]) or ""
            local field_name = intern_mod.get(ctx.pool, callee_n.data[1]) or ""
            if obj_name == "ffi" and field_name == "cdef" then
                local arg0_nid = ctx.ast_lists:get(n.data[1])
                local arg0_n   = ctx.nodes:get(arg0_nid)
                if arg0_n and arg0_n.kind == NODE_LITERAL and arg0_n.data[2] == LIT_STRING then
                    local c_str = intern_mod.get(ctx.pool, arg0_n.data[1]) or ""
                    if ctx.ffi_hooks.process then
                        ctx.ffi_hooks.process(ctx, c_str)
                    end
                end
                return ctx.T_NIL
            end
        end
    end

    -- Instantiate callee at this call site (let-polymorphism)
    local inst_callee = env_mod.instantiate(ctx, callee_tid, ctx.scope.level)

    local ret = fresh_var(ctx)
    emit(ctx, { C_CALLABLE, inst_callee, arg_tids, ret, n.line, n.col })
    ctx._last_multi_return = { ret }

    -- pcall/xpcall intrinsic: synthesise (true, fn_ret) | (false, string) union.
    -- Stored in _last_multi_return_override for LOCAL_STMT to use as call_ret_tid.
    if callee_n.kind == NODE_IDENTIFIER then
        local fname = intern_mod.get(ctx.pool, callee_n.data[0]) or ""
        if (fname == "pcall" or fname == "xpcall") and #arg_tids >= 1 then
            local fn_arg_tid = types_mod.find(ctx, arg_tids[1])
            local fn_t = ctx.types:get(fn_arg_tid)
            -- Collect fn return types (first slot only for simplicity)
            local fn_rets = {}
            if fn_t.tag == TAG_FUNCTION and fn_t.data[3] > 0 then
                fn_rets[1] = types_mod.find(ctx, ctx.lists:get(fn_t.data[2]))
            elseif fn_t.tag == TAG_FUNCTION then
                fn_rets[1] = ctx.T_NIL
            else
                fn_rets[1] = ctx.T_ANY
            end
            local true_lit  = types_mod.make_literal(ctx, LIT_BOOLEAN, 1)
            local false_lit = types_mod.make_literal(ctx, LIT_BOOLEAN, 0)
            local success_arm = types_mod.make_tuple(ctx, { true_lit, fn_rets[1] })
            local failure_arm = types_mod.make_tuple(ctx, { false_lit, ctx.T_STRING })
            ctx._last_multi_return_override = types_mod.make_union(ctx, { success_arm, failure_arm })
        end
    end

    -- General union-of-tuples override: any callee declared to return a
    -- union-of-tuples (e.g. string.find, io.open) gets the concrete union as
    -- call_ret_tid so LOCAL_STMT can correlate bindings at narrowing time.
    if not ctx._last_multi_return_override then
        local ret_union = peek_callee_ret_union(ctx, callee_n)
        if ret_union then
            ctx._last_multi_return_override = ret_union
        end
    end

    return ret
end

ExprRule[NODE_METHOD_CALL] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local recv_tid = gen_expr(ctx, n.data[0])
    local method_name_id = n.data[1]

    -- Get method field
    local method_var = fresh_var(ctx)
    emit(ctx, { C_INDEX, recv_tid, types_mod.make_literal(ctx, LIT_STRING, method_name_id), method_var, n.line, n.col })

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

-- If all fields of a table literal are same-kind literals (all LIT_INTEGER or all LIT_STRING),
-- rewrite each field's type_id to a TAG_ENUM_MEMBER so `Status.OK` displays as `Status.OK`.
-- enum_name_id is the intern ID of the variable name (e.g. "Status").
-- No-op when fields are mixed kinds, empty, or contain non-literals.
local function try_promote_enum(ctx, tbl_tid, enum_name_id)
    local ot = ctx.types:get(types_mod.find(ctx, tbl_tid))
    if ot.tag ~= TAG_TABLE then return end
    local fs, fl = ot.data[0], ot.data[1]
    if fl == 0 then return end
    local lit_kind = nil
    local entries = {}  -- {feid, member_name_id, lit_kind, value}
    for i = fs, fs + fl - 1 do
        local fe = ctx.fields:get(ctx.lists:get(i))
        local vt = ctx.types:get(types_mod.find(ctx, fe.type_id))
        if vt.tag ~= TAG_LITERAL then return end
        local k = vt.data[0]
        if k ~= LIT_INTEGER and k ~= LIT_STRING then return end  -- booleans/nil: skip
        if lit_kind == nil then lit_kind = k
        elseif lit_kind ~= k then return end  -- mixed kinds: not an enum
        entries[#entries + 1] = { feid = ctx.lists:get(i), member_name_id = fe.name_id,
                                  lit_kind = k, value = vt.data[1] }
    end
    for _, info in ipairs(entries) do
        local mem_tid = types_mod.make_enum_member(ctx, enum_name_id,
            info.member_name_id, info.lit_kind, info.value)
        -- Re-fetch FieldEntry after make_enum_member (arena may have grown)
        local fe = ctx.fields:get(info.feid)
        fe.type_id = mem_tid
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
    ctx._last_multi_return_override = nil  -- clear before gen so stale values don't persist
    local rhs_types = el > 0 and gen_expr_list(ctx, es, el) or {}
    local stmt_require_mod = ctx._last_require_mod
    ctx._last_require_mod = nil

    local last_rhs_is_call = false
    if el > 0 then
        local last_rhs_nid = ctx.ast_lists:get(es + el - 1)
        local last_rhs_n = ctx.nodes:get(last_rhs_nid)
        last_rhs_is_call = (last_rhs_n.kind == NODE_CALL_EXPR or last_rhs_n.kind == NODE_METHOD_CALL)
    end

    -- For call-derived bindings, use C_INDEX to project individual slots.
    -- call_ret_tid: the multi-return source (pcall intrinsic union, or last RHS ret var).
    local call_ret_tid = nil
    if last_rhs_is_call then
        if ctx._last_multi_return_override then
            call_ret_tid = ctx._last_multi_return_override
            ctx._last_multi_return_override = nil
        else
            call_ret_tid = rhs_types[el]  -- the call's ret var
        end
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
            -- For tuple annotations, check each element against corresponding RHS expr.
            local at_resolved = types_mod.find(ctx, ann_tid)
            local at_t = ctx.types:get(at_resolved)
            if at_t.tag == TAG_TUPLE then
                for ti = 0, at_t.data[1] - 1 do
                    local elem_tid = types_mod.find(ctx, ctx.lists:get(at_t.data[0] + ti))
                    local rhs_elem = rhs_types[ti + 1]
                    if rhs_elem then
                        emit(ctx, { C_SUB, rhs_elem, elem_tid, n.line, n.col })
                    end
                end
            elseif rhs_tid then
                emit(ctx, { C_SUB, rhs_tid, ann_tid, n.line, n.col })
            end
            env_mod.bind(ctx.scope, name_id, ann_tid)
            ctx.def_sites[name_id] = { line = n.line, col = n.col }
            if stmt_require_mod and i == 0 and el == 1 then
                ctx.require_sources[name_id] = stmt_require_mod
            end
        elseif prescanned then
            -- Prescan already bound this name to a rich type (e.g. M with all method fields).
            -- The inferred RHS (e.g. `{}`) is a closed empty table — unifying would fail.
            -- Keep the prescan binding as-is, mirroring v2 infer.lua's behavior.
            -- (v2 calls unify but ignores the result; the prescan type wins.)
        else
            local bind_tid
            -- call_slot: which slot of the call's return this binding maps to (-1 if not from call).
            -- Bindings at index i >= (el-1) come from the last (call) expression.
            local call_slot = (last_rhs_is_call and el > 0) and (i - (el - 1)) or -1
            if call_slot >= 0 and call_ret_tid then
                -- Project slot from the call's multi-return tuple/union via C_INDEX.
                local slot_var = fresh_var(ctx)
                emit(ctx, { C_INDEX, call_ret_tid,
                    types_mod.make_literal(ctx, LIT_INTEGER, call_slot),
                    slot_var, n.line, n.col })
                bind_tid = slot_var
                if not ctx._multi_ret then ctx._multi_ret = {} end
                ctx._multi_ret[name_id] = { source_tid = call_ret_tid, slot = call_slot }
            elseif rhs_tid then
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
            else
                bind_tid = ctx.T_NIL
            end
            env_mod.bind(ctx.scope, name_id, bind_tid)
            ctx.def_sites[name_id] = { line = n.line, col = n.col }
            if stmt_require_mod and i == 0 and el == 1 then
                ctx.require_sources[name_id] = stmt_require_mod
            end
            -- After binding a single-name table literal with no annotation, try to promote
            -- it to an enum (e.g. `local Status = { OK = 1, ERR = 2 }`).
            if nl == 1 and el == 1 and bind_tid then
                local rhs_nid = ctx.ast_lists:get(es)
                if ctx.nodes:get(rhs_nid).kind == NODE_TABLE_EXPR then
                    try_promote_enum(ctx, types_mod.find(ctx, bind_tid), name_id)
                end
            end
        end
    end
    -- Consume the annotation for this line so it doesn't spill to the next statement
    -- via the line-1 fallback in get_ann (e.g. `local t --: T \n local v = t.x`).
    consume_ann(ctx, n.line)
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
                if fe then
                    -- Readonly check: assignment to a readonly field is a type error
                    if band(fe.flags, FLAG_READONLY) ~= 0 then
                        local fname = intern_mod.get(ctx.pool, field_id) or "?"
                        report(ctx, tn.line, tn.col, E.FIELD_READONLY,
                            { field = fname })
                    end
                    -- Re-assignment: check type compatibility (widen to base type first)
                    local expected = types_mod.widen(ctx, fe.type_id)
                    local et = ctx.types:get(types_mod.find(ctx, expected))
                    if et.tag ~= TAG_VAR then
                        emit(ctx, { C_SUB, rhs_tid, expected, tn.line, tn.col })
                    end
                else
                    -- Add field
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
                    fields[#fields + 1] = types_mod.make_field(ctx, field_id, rhs_tid, field_flags(ctx, field_id))
                    local new_tbl = types_mod.make_table(ctx, fields, indexers, rv, meta)
                    local ot2 = ctx.types:get(obj_tid)
                    local new_t = ctx.types:get(new_tbl)
                    for k = 0, 6 do ot2.data[k] = new_t.data[k] end
                end
            end
        elseif tn.kind == NODE_INDEX_EXPR then
            local obj_nid = tn.data[0]
            local key_nid = tn.data[1]
            local obj_tid = types_mod.find(ctx, gen_expr(ctx, obj_nid))
            local key_tid = gen_expr(ctx, key_nid)
            local ot = ctx.types:get(obj_tid)
            if ot.tag == TAG_TABLE then
                local key_r = types_mod.find(ctx, key_tid)
                local kt_t = ctx.types:get(key_r)
                -- String literal key: treat as named field (same as t.field syntax)
                if kt_t.tag == TAG_LITERAL and kt_t.data[0] == LIT_STRING then
                    local field_id = kt_t.data[1]
                    local fe = types_mod.table_field(ctx, obj_tid, field_id)
                    if fe then
                        -- Re-assignment: check type compatibility (widen to base type first)
                        local expected = types_mod.widen(ctx, fe.type_id)
                        local et = ctx.types:get(types_mod.find(ctx, expected))
                        if et.tag ~= TAG_VAR then
                            emit(ctx, { C_SUB, rhs_tid, expected, tn.line, tn.col })
                        end
                    else
                        -- New field: add it
                        local fields, indexers, rv, meta = {}, {}, ot.data[4], {}
                        local fs2, fl2 = ot.data[0], ot.data[1]
                        for j = fs2, fs2 + fl2 - 1 do fields[#fields+1] = ctx.lists:get(j) end
                        local is3, il3 = ot.data[2], ot.data[3]
                        local ix2 = is3
                        while ix2 < is3 + il3 - 1 do
                            indexers[#indexers+1] = ctx.lists:get(ix2)
                            indexers[#indexers+1] = ctx.lists:get(ix2+1)
                            ix2 = ix2 + 2
                        end
                        for j = ot.data[5], ot.data[5] + ot.data[6] - 1 do meta[#meta+1] = ctx.lists:get(j) end
                        fields[#fields+1] = types_mod.make_field(ctx, field_id, rhs_tid, field_flags(ctx, field_id))
                        local new_tbl = types_mod.make_table(ctx, fields, indexers, rv, meta)
                        local ot2 = ctx.types:get(obj_tid)
                        local new_t = ctx.types:get(new_tbl)
                        for k = 0, 6 do ot2.data[k] = new_t.data[k] end
                    end
                else
                    -- Non-literal key: check rhs against indexer value type if known
                    local is2, il2 = ot.data[2], ot.data[3]
                    if il2 > 0 then
                        -- Check first indexer pair's value type
                        local idx_val = types_mod.find(ctx, ctx.lists:get(is2 + 1))
                        local ivt = ctx.types:get(idx_val)
                        if ivt.tag ~= TAG_VAR then
                            emit(ctx, { C_SUB, rhs_tid, idx_val, tn.line, tn.col })
                        end
                    end
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
    local narrow_mod = require("lib.type.static.narrow")
    local narrowed = narrow_mod.narrow_scope(ctx, n.data[0], true)
    local saved = ctx.scope
    ctx.scope = narrow_mod.apply_narrowed(ctx, narrowed)
    gen_block(ctx, n.data[1], n.data[2])
    ctx.scope = saved
end

StmtRule[NODE_REPEAT_STMT] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local saved = ctx.scope
    ctx.scope = env_mod.child(ctx.scope)
    gen_block(ctx, n.data[1], n.data[2])  -- data[1]=bs, data[2]=bl
    gen_expr(ctx, n.data[0])              -- data[0]=test condition
    ctx.scope = saved
end

-- Collect end-of-branch types for variables that already existed in base_scope.
local function branch_scope_diff(ctx, branch_scope, base_scope)
    local result = {}
    local s = branch_scope
    while s and s ~= base_scope do
        for name_id, type_id in pairs(s.bindings) do
            if result[name_id] == nil and env_mod.lookup(base_scope, name_id) ~= nil then
                result[name_id] = type_id
            end
        end
        s = s.parent
    end
    return result
end

StmtRule[NODE_IF_STMT] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local narrow_mod = require("lib.type.static.narrow")
    local saved = ctx.scope

    local guard_narrowings = {}  -- Cat E: negated narrowings from exiting clauses
    local branch_ends      = {}  -- { name_id -> type_id } per non-exiting clause
    local pass_through_neg = {}  -- negated narrowings for the implicit pass-through path
    local has_else         = false

    for i = n.data[0], n.data[0] + n.data[1] - 1 do
        local cn          = ctx.nodes:get(ctx.ast_lists:get(i))
        local test_nid    = cn.data[0]
        local block_start = cn.data[1]
        local block_len   = cn.data[2]

        if test_nid >= 0 then
            gen_expr(ctx, test_nid)
            local narrowed = narrow_mod.narrow_scope(ctx, test_nid, true)
            ctx.scope = narrow_mod.apply_narrowed(ctx, narrowed)
        else
            has_else = true
            ctx.scope = env_mod.child(saved)
        end

        gen_block(ctx, block_start, block_len)
        local end_scope = ctx.scope

        -- Detect unconditional exit (return/break as last statement).
        local exits = false
        if block_len > 0 then
            local last_n = ctx.nodes:get(ctx.ast_lists:get(block_start + block_len - 1))
            exits = (last_n.kind == NODE_RETURN_STMT or last_n.kind == NODE_BREAK_STMT)
        end

        if not exits then
            branch_ends[#branch_ends + 1] = branch_scope_diff(ctx, end_scope, saved)
        end

        -- Restore scope to saved BEFORE computing negated narrowing so that the
        -- lookup of variable types uses the pre-branch types (not truthy-narrowed ones).
        -- (e.g. `if n == 0 then return end` — negated narrowing of n should be
        -- based on n's type before the branch, not LIT_INTEGER(0) from inside it.)
        ctx.scope = saved

        if test_nid >= 0 then
            local neg = narrow_mod.narrow_scope(ctx, test_nid, false)
            if exits then
                -- Cat E: negate to narrow the continuation scope.
                for name_id, type_id in pairs(neg) do
                    guard_narrowings[name_id] = type_id
                end
            else
                -- Accumulate for pass-through path.
                for name_id, type_id in pairs(neg) do
                    if pass_through_neg[name_id] == nil then
                        pass_through_neg[name_id] = type_id
                    end
                end
            end
        end
    end

    -- Step 1: Apply Cat E guard narrowings to the continuation scope.
    if next(guard_narrowings) then
        ctx.scope = narrow_mod.apply_narrowed(ctx, guard_narrowings)
    end

    -- Step 2: Branch-join — union per-branch end-types and bind in continuation.
    local changed = {}
    for _, et in ipairs(branch_ends) do
        for name_id in pairs(et) do changed[name_id] = true end
    end

    if next(changed) then
        local join = {}
        for name_id in pairs(changed) do
            local post_guard = env_mod.lookup(ctx.scope, name_id)
            local members, seen_m = {}, {}
            local function add_member(t)
                t = types_mod.find(ctx, t)
                if t and not seen_m[t] then seen_m[t] = true; members[#members + 1] = t end
            end
            for _, et in ipairs(branch_ends) do
                add_member(et[name_id] or post_guard)
            end
            if not has_else then
                add_member(pass_through_neg[name_id] or post_guard)
            end
            if #members == 1 then
                join[name_id] = members[1]
            elseif #members > 1 then
                join[name_id] = types_mod.make_union(ctx, members)
            end
        end
        if next(join) then
            -- Use a plain child scope (no narrowed_names) so joined types become
            -- the new declared type for subsequent lookup_declared calls.
            local join_scope = env_mod.child(ctx.scope)
            for name_id, type_id in pairs(join) do
                env_mod.bind(join_scope, name_id, type_id)
            end
            ctx.scope = join_scope
        end
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

    -- Pre-inspect: detect pairs(t)/ipairs(t) to extract typed loop vars from the table.
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
                    local arg_n = ctx.nodes:get(arg_nid)
                    -- Only inspect identifiers to avoid double constraint emission.
                    local arg_tid = nil
                    if arg_n.kind == NODE_IDENTIFIER then
                        arg_tid = env_mod.lookup(ctx.scope, arg_n.data[0])
                        if arg_tid then arg_tid = types_mod.find(ctx, arg_tid) end
                    end
                    local at = arg_tid and ctx.types:get(arg_tid)
                    if at and at.tag == TAG_TABLE and at.data[3] >= 2 then
                        local is = at.data[2]
                        if fn_name == "ipairs" then
                            local j = is
                            while j < is + at.data[3] - 1 do
                                local kt = ctx.types:get(types_mod.find(ctx, ctx.lists:get(j)))
                                if kt.tag == TAG_NUMBER or kt.tag == TAG_INTEGER then
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

    local iter_types = gen_expr_list(ctx, n.data[2], n.data[3])
    local saved = ctx.scope
    ctx.scope = env_mod.child(ctx.scope)
    local ns, nl = n.data[0], n.data[1]
    -- Extract loop-var types from iterator function's return types.
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
        local t = (typed_iter_returns and typed_iter_returns[i + 1])
               or iter_func_returns[i + 1]
               or ctx.T_ANY
        env_mod.bind(ctx.scope, name_id, t)
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
                fields[#fields + 1] = types_mod.make_field(ctx, field_id, fn_tid, field_flags(ctx, field_id))
                local new_tbl = types_mod.make_table(ctx, fields, indexers, rv, meta)
                local ot2 = ctx.types:get(obj_tid)
                local new_t = ctx.types:get(new_tbl)
                for k = 0, 6 do ot2.data[k] = new_t.data[k] end
            else
                -- Prescan stub exists: update the field to point to the inferred
                -- function type (mirrors v2 infer.lua: fe.type_id = fn_tid).
                -- This ensures callers see the solved return type, not the stub var.
                fe.type_id = fn_tid
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
                                fields[#fields + 1] = types_mod.make_field(ctx, field_id, make_prescan_stub(ctx, pl), field_flags(ctx, field_id))
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
    -- Sort by source line so forward references resolve in file order.
    table.sort(decls, function(a, b) return (decl_lines[a] or 0) < (decl_lines[b] or 0) end)

    -- Pass 1: register all type alias names (body=nil) so forward refs are visible.
    for _, r in ipairs(decls) do
        if not r.decl_var then
            local params = nil
            if r.type_params_len and r.type_params_len > 0 then
                params = {}
                for i = r.type_params_start, r.type_params_start + r.type_params_len - 1 do
                    params[#params + 1] = ctx.ann.lists:get(i)
                end
            end
            -- Extract raw (annotation-arena) bound type IDs, if any.
            -- -1 entries are "no bound" sentinels. resolved_bounds is filled in Pass 2a.
            local raw_bounds = nil
            if r.type_bounds_len and r.type_bounds_len > 0 then
                raw_bounds = {}
                for i = r.type_bounds_start, r.type_bounds_start + r.type_bounds_len - 1 do
                    raw_bounds[#raw_bounds + 1] = ctx.ann.lists:get(i)
                end
            end
            env_mod.bind_type(ctx.scope, r.name_id, {
                body        = nil,
                params      = params,
                nominal     = r.newtype or false,
                raw_bounds  = raw_bounds,   -- annotation-arena IDs; resolved in Pass 2a
            })
        end
    end

    -- Pass 2a: resolve type alias bodies (non-decl_var) before variable declarations
    -- reference them, so that `--:: declare x = SomeAlias` sees the fully-resolved body.
    for _, r in ipairs(decls) do
        if not r.decl_var then
            -- Warn on function type declarations with unnamed parameters.
            local at = ctx.ann.types:get(r.type_id)
            local fn_at
            if at.tag == defs.TAG_FUNCTION then
                fn_at = at
            elseif at.tag == defs.TAG_FORALL then
                local body = ctx.ann.types:get(at.data[2])
                if body.tag == defs.TAG_FUNCTION then fn_at = body end
            end
            if fn_at and fn_at.data[1] > 0 and fn_at.data[6] == 0 then
                warn(ctx, decl_lines[r], 1, E.UNNAMED_PARAMS, {})
            end

            local alias = env_mod.lookup_type(ctx.scope, r.name_id)
            if alias then
                -- For generic aliases, push a temporary scope where each type parameter
                -- is bound to a TAG_NAMED placeholder. This lets resolve_annotation_type
                -- produce the correct placeholder types (substitutable by env_mod.substitute)
                -- instead of erroring on unresolved parameter names.
                local old_scope = ctx.scope
                if alias.params and #alias.params > 0 then
                    local temp = env_mod.new(ctx.scope.level + 1)
                    temp.parent = ctx.scope
                    for _, param_name_id in ipairs(alias.params) do
                        local ph = types_mod.alloc_type(ctx, defs.TAG_NAMED)
                        ctx.types:get(ph).data[0] = param_name_id
                        env_mod.bind_type(temp, param_name_id, { body = ph, params = nil, nominal = false })
                    end
                    ctx.scope = temp
                end

                if r.newtype then
                    local ann_nom = ctx.ann.types:get(r.type_id)
                    local underlying = resolve_annotation_type(ctx, ann_nom.data[2])
                    ctx.nominal_id = ctx.nominal_id + 1
                    alias.body = types_mod.make_nominal(ctx, r.name_id, ctx.nominal_id, underlying)
                else
                    alias.body = resolve_annotation_type(ctx, r.type_id)
                end

                -- Resolve raw_bounds (annotation-arena IDs) into checker-context type IDs.
                -- These are resolved in the same temporary param scope so that bound types
                -- that reference other params (e.g. <T: { x: U }, U>) resolve correctly.
                if alias.raw_bounds then
                    alias.resolved_bounds = {}
                    for _, raw_id in ipairs(alias.raw_bounds) do
                        if raw_id == -1 then
                            alias.resolved_bounds[#alias.resolved_bounds + 1] = nil
                        else
                            alias.resolved_bounds[#alias.resolved_bounds + 1] =
                                resolve_annotation_type(ctx, raw_id)
                        end
                    end
                end

                ctx.scope = old_scope
            end
        end
    end

    -- Pass 2b: bind declared variables (decl_var), which may reference aliases set above.
    for _, r in ipairs(decls) do
        if r.decl_var then
            -- Warn on function type declarations with unnamed parameters.
            local at = ctx.ann.types:get(r.type_id)
            local fn_at
            if at.tag == defs.TAG_FUNCTION then
                fn_at = at
            elseif at.tag == defs.TAG_FORALL then
                local body = ctx.ann.types:get(at.data[2])
                if body.tag == defs.TAG_FUNCTION then fn_at = body end
            end
            if fn_at and fn_at.data[1] > 0 and fn_at.data[6] == 0 then
                warn(ctx, decl_lines[r], 1, E.UNNAMED_PARAMS, {})
            end
            env_mod.bind(ctx.scope, r.name_id, resolve_annotation_type(ctx, r.type_id))
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
    ctx._last_multi_return          = nil
    ctx._last_multi_return_override = nil
    ctx._last_require_mod           = nil
    ctx._multi_ret                  = {}
    ctx.nominal_id         = 0
    ctx.inferred_anns      = {}
    ctx.type_at            = {}
    ctx.name_at            = {}
    ctx.field_at           = {}
    ctx.def_sites          = {}
    ctx.require_sources    = {}
    ctx.type_origins       = {}   -- [type_id] -> filename; populated for cross-file types
    ctx.constraints        = {}   -- v3: emitted constraints
    ctx.lit_cache          = {}   -- literal type interning: (kind<<32|val) → type_id

    if not parent_scope then
        require("lib.type.static.prelude").populate(ctx)
        require("lib.type.static.prelude_luajit").populate(ctx)
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

M.resolve_annotation_type = resolve_annotation_type

return M
