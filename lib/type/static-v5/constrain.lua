-- lib/type/static-v5/constrain.lua
-- Constraint generation pass (gen-pass) for the v5 typechecker.
--
-- Walks the AST produced by lib/type/static/parse.lua (read-only) and emits
-- v5 constraints into a flat array.
--
-- Entry point:
--   M.generate(source, filename, opts) -> constraints[], errors[]
--
-- Annotation integration:
--   --:  (preceding line)  → parse_annotation  → V5Type bound to declaration
--   --:: (preceding line)  → parse_declaration → type alias / declare_var
--
-- The lexer (from parse.lua's L) stores annotations in L.annotations keyed
-- by line number.  Format: { kind, content, col }.
-- defs.ANN_TYPE (0) = --:   single-colon type annotation
-- defs.ANN_DECL (1) = --::  double-colon declaration
--
-- Residual gaps (to be addressed in 5.C / 5.D):
--   - Effect propagation
--   - pcall / coroutine special handling
--   - Closures-as-values intricacies (deep closure capture)
--   - Complex narrowing (discriminated unions, type guards)
--   - Method dispatch edge cases beyond simple obj:method(...)
--   - Binary / unary operator constraint emission (emits fresh uvar instead)
--   - for-in / for-num loop variable typing (binds unknown)
--   - Generic function body checking (skolemization)
--   - Type alias / require / module directives (noted but not scope-injected)
--   - Multi-return tuple types (uses union as approximation)

local parse_mod   = require("lib.type.static.parse")
local defs        = require("lib.type.static.defs")
local intern_mod  = require("lib.type.static.intern")
local ann_mod     = require("lib.type.static-v5.ann")
local types_mod   = require("lib.type.experiments.v5_perf.types")
local C           = require("lib.type.experiments.v5_perf.constraint")

local M = {}

-- ── Local type declarations (inline, since ctx_types.lua is not loaded here) ──

--:: ASTNode = { kind: integer, flags: integer, col: integer, line: integer, data: { [integer]: integer, ... } }
--:: ASTNodeArena = { get: (ASTNodeArena, integer) -> ASTNode, alloc: (ASTNodeArena) -> integer, len: integer, ... }
--:: ListPool = { get: (ListPool, integer) -> integer, len: integer, cap: integer, items: unknown, mark: (ListPool) -> integer, push: (ListPool, integer) -> (), since: (ListPool, integer) -> (integer, integer), grow: (ListPool) -> (), reset: (ListPool) -> (), ... }
--:: InternPool = { ht_cap: integer, ht_mask: integer, ht_count: integer, next_id: integer, buf_count: integer, entries: { [integer]: unknown, ... }, bufs: { [integer]: unknown, ... }, rev: { [integer]: unknown, ... }, map: { [string]: integer, ... }, _anchors: { [integer]: string, ... }, _type_predicates: { [integer]: { param_idx: integer, type_id: integer }, ... } | nil, _assert_predicates: { [integer]: { param_idx: integer, type_id: integer }, ... } | nil, _pending_predicate: { param_idx: integer, type_id: integer, ... } | nil, _pending_assert_predicate: { param_idx: integer, type_id: integer, ... } | nil, ... }

-- ── AST node kind constants (from defs) ─────────────────────────────────────

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
local NODE_ASSIGN_STMT = defs.NODE_ASSIGN_STMT
local NODE_LOCAL_STMT  = defs.NODE_LOCAL_STMT
local NODE_DO_STMT     = defs.NODE_DO_STMT
local NODE_WHILE_STMT  = defs.NODE_WHILE_STMT
local NODE_REPEAT_STMT = defs.NODE_REPEAT_STMT
local NODE_IF_STMT     = defs.NODE_IF_STMT
local NODE_FOR_NUM     = defs.NODE_FOR_NUM
local NODE_FOR_IN      = defs.NODE_FOR_IN
local NODE_RETURN_STMT = defs.NODE_RETURN_STMT
local NODE_EXPR_STMT   = defs.NODE_EXPR_STMT
local NODE_FUNC_DECL   = defs.NODE_FUNC_DECL

local LIT_STRING  = defs.LIT_STRING
local LIT_NUMBER  = defs.LIT_NUMBER
local LIT_BOOLEAN = defs.LIT_BOOLEAN
local LIT_INTEGER = defs.LIT_INTEGER
local LIT_NIL     = defs.LIT_NIL

local TFIELD_POSITIONAL = defs.TFIELD_POSITIONAL
local TFIELD_NAMED      = defs.TFIELD_NAMED

local ANN_TYPE = defs.ANN_TYPE
local ANN_DECL = defs.ANN_DECL

local FLAG_VARARG    = defs.FLAG_VARARG
local FLAG_HAS_STEP  = defs.FLAG_HAS_STEP

local i32x2_to_double = defs.i32x2_to_double

-- ── Well-known types ──────────────────────────────────────────────────────────
-- Annotated explicitly so the checker knows these are non-nil V5Type values.

--: V5Type
local T_NIL = types_mod.const("nil")
--: V5Type
local T_NUMBER = types_mod.const("number")
--: V5Type
local T_UNKNOWN = types_mod.const("unknown")

--:: RawAnn = { kind: integer, content: string, col: integer, ... }

-- ── State record ─────────────────────────────────────────────────────────────

--:: V5Ctx = {
--::   filename: string,
--::   nodes: ASTNodeArena,
--::   lists: ListPool,
--::   pool: InternPool,
--::   constraints: V5Constraint[],
--::   errors: string[],
--::   scope: { [string]: V5Type },
--::   scope_stack: { [string]: V5Type }[],
--::   return_stack: V5Type[],
--::   annotations: { [integer]: RawAnn } | nil,
--::   _next_uvar: integer,
--:: }

-- ── Fresh unification variables ──────────────────────────────────────────────

--: (V5Ctx) -> V5Type
local function fresh_uvar(ctx)
    local id = ctx._next_uvar
    ctx._next_uvar = id + 1
    return types_mod.uvar(id)
end

-- ── Provenance helpers ────────────────────────────────────────────────────────

--: (V5Ctx, integer) -> Provenance
local function prov_inferred(ctx, line)
    return C.prov(ctx.filename, line, "inferred")
end

--: (V5Ctx, integer) -> Provenance
local function prov_declared(ctx, line)
    return C.prov(ctx.filename, line, "declared")
end

-- ── Emit helper ───────────────────────────────────────────────────────────────

--: (V5Ctx, V5Constraint) -> nil
local function emit(ctx, constraint)
    ctx.constraints[#ctx.constraints + 1] = constraint
end

-- ── Scope helpers ─────────────────────────────────────────────────────────────

--: (V5Ctx, string, V5Type) -> nil
local function bind(ctx, name, ty)
    ctx.scope[name] = ty
end

--: (V5Ctx, string) -> V5Type | nil
local function lookup(ctx, name)
    local stack = ctx.scope_stack
    for i = #stack, 1, -1 do
        local s = stack[i]
        if s ~= nil then
            local v = s[name]
            if v ~= nil then return v end
        end
    end
    return nil
end

--: (V5Ctx) -> nil
local function push_scope(ctx)
    ctx.scope_stack[#ctx.scope_stack + 1] = ctx.scope
    ctx.scope = {}
end

--: (V5Ctx) -> nil
local function pop_scope(ctx)
    local stack = ctx.scope_stack
    ctx.scope = stack[#stack] or {}
    stack[#stack] = nil
end

-- ── Annotation lookup ─────────────────────────────────────────────────────────

--: (V5Ctx, integer) -> RawAnn | nil
local function get_raw_ann(ctx, line)
    local anns = ctx.annotations
    if anns == nil then return nil end
    local r = anns[line]
    if r ~= nil then return r end
    return anns[line - 1]
end

--: (V5Ctx, integer) -> V5Type | nil
local function get_type_ann(ctx, line)
    local r = get_raw_ann(ctx, line)
    if r == nil then return nil end
    if r.kind ~= ANN_TYPE then return nil end
    local ty, err = ann_mod.parse_annotation(r.content)
    if ty == nil then
        ctx.errors[#ctx.errors + 1] = (ctx.filename .. ":" .. line
            .. ": annotation parse error: " .. (err or "?"))
    end
    return ty
end

--: (V5Ctx, integer) -> { [string]: unknown } | nil
local function get_decl_ann(ctx, line)
    local r = get_raw_ann(ctx, line)
    if r == nil then return nil end
    if r.kind ~= ANN_DECL then return nil end
    local dir, err = ann_mod.parse_declaration(r.content)
    if dir == nil then
        ctx.errors[#ctx.errors + 1] = (ctx.filename .. ":" .. line
            .. ": declaration parse error: " .. (err or "?"))
    end
    return dir
end


-- ── Intern pool helpers ───────────────────────────────────────────────────────

--: (V5Ctx, integer) -> string
local function intern_str(ctx, id)
    local s = intern_mod.get(ctx.pool, id)
    if s == nil then return "?id:" .. tostring(id) end
    return s
end

-- ── Forward declarations ──────────────────────────────────────────────────────

local gen_expr --[[: (V5Ctx, integer) -> V5Type ]]
local gen_stmt --[[: (V5Ctx, integer) -> nil ]]
local gen_block --[[: (V5Ctx, integer, integer) -> nil ]]
local gen_function --[[: (V5Ctx, integer, integer, integer, integer, boolean, V5Type | nil, integer) -> V5Type ]]
local gen_table_expr --[[: (V5Ctx, integer) -> V5Type ]]

-- ── Expression constraint generation ─────────────────────────────────────────

--: (V5Ctx, integer) -> V5Type
gen_expr = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local kind = n.kind

    -- ── Literals ────────────────────────────────────────────────────────────
    if kind == NODE_LITERAL then
        local lit_kind = n.data[0]
        if lit_kind == LIT_NIL     then return T_NIL end
        if lit_kind == LIT_BOOLEAN then
            --: V5Type
            local bty = types_mod.const(n.data[1] == 1 and "true" or "false")
            return bty
        end
        if lit_kind == LIT_STRING  then
            local s = intern_str(ctx, n.data[1])
            --: V5Type
            local f = types_mod.const("$Lit")
            --: V5Type
            local a = types_mod.const(s)
            --: V5Type
            local r = types_mod.app(f, a)
            return r
        end
        if lit_kind == LIT_INTEGER then
            --: V5Type
            local f = types_mod.const("$LitInt")
            --: V5Type
            local a = types_mod.const(tostring(n.data[1]))
            --: V5Type
            local r = types_mod.app(f, a)
            return r
        end
        if lit_kind == LIT_NUMBER  then
            local num = i32x2_to_double(n.data[1], n.data[2])
            --: V5Type
            local f = types_mod.const("$LitNum")
            --: V5Type
            local a = types_mod.const(tostring(num))
            --: V5Type
            local r = types_mod.app(f, a)
            return r
        end
        return T_UNKNOWN
    end

    -- ── Identifier ──────────────────────────────────────────────────────────
    if kind == NODE_IDENTIFIER then
        local name = intern_str(ctx, n.data[0])
        local ty = lookup(ctx, name)
        if ty ~= nil then return ty end
        return fresh_uvar(ctx)
    end

    -- ── Vararg ──────────────────────────────────────────────────────────────
    if kind == defs.NODE_VARARG_EXPR then
        local ty = lookup(ctx, "...")
        if ty ~= nil then return ty end
        return T_UNKNOWN
    end

    -- ── Unary expression ────────────────────────────────────────────────────
    if kind == NODE_UNARY_EXPR then
        gen_expr(ctx, n.data[1])
        return fresh_uvar(ctx)
    end

    -- ── Binary expression ───────────────────────────────────────────────────
    if kind == NODE_BINARY_EXPR then
        gen_expr(ctx, n.data[1])
        gen_expr(ctx, n.data[2])
        return fresh_uvar(ctx)
    end

    -- ── Field access: a.b ───────────────────────────────────────────────────
    if kind == NODE_FIELD_EXPR then
        local obj_ty  = gen_expr(ctx, n.data[0])
        local key_str = intern_str(ctx, n.data[1])
        local result  = fresh_uvar(ctx)
        emit(ctx, C.row_extend(obj_ty, key_str, result, prov_inferred(ctx, n.line)))
        return result
    end

    -- ── Index expression: a[k] ──────────────────────────────────────────────
    if kind == NODE_INDEX_EXPR then
        gen_expr(ctx, n.data[0])
        gen_expr(ctx, n.data[1])
        return fresh_uvar(ctx)
    end

    -- ── Function call: f(...) ───────────────────────────────────────────────
    if kind == NODE_CALL_EXPR then
        local callee_ty = gen_expr(ctx, n.data[0])
        local arg_types = {} --[[: V5Type[] ]]
        local es = n.data[1]
        local el = n.data[2]
        for i = es, es + el - 1 do
            local anid = ctx.lists:get(i)
            arg_types[#arg_types + 1] = gen_expr(ctx, anid)
        end
        local ret = fresh_uvar(ctx)
        local rets_arr = {} --[[: V5Type[] ]]
        rets_arr[1] = ret
        --: V5Type
        local expected_fn = types_mod.arrow(arg_types, rets_arr)
        emit(ctx, C.sub(callee_ty, expected_fn, prov_inferred(ctx, n.line)))
        return ret
    end

    -- ── Method call: obj:method(...) ────────────────────────────────────────
    if kind == NODE_METHOD_CALL then
        local recv_ty    = gen_expr(ctx, n.data[0])
        local method_str = intern_str(ctx, n.data[1])
        local arg_types  = {} --[[: V5Type[] ]]
        arg_types[1]     = recv_ty
        local es = n.data[2]
        local el = n.data[3]
        for i = es, es + el - 1 do
            local anid = ctx.lists:get(i)
            arg_types[#arg_types + 1] = gen_expr(ctx, anid)
        end
        local ret       = fresh_uvar(ctx)
        local method_ty = fresh_uvar(ctx)
        emit(ctx, C.row_extend(recv_ty, method_str, method_ty, prov_inferred(ctx, n.line)))
        local rets_arr = {} --[[: V5Type[] ]]
        rets_arr[1]    = ret
        --: V5Type
        local expected_fn = types_mod.arrow(arg_types, rets_arr)
        emit(ctx, C.sub(method_ty, expected_fn, prov_inferred(ctx, n.line)))
        return ret
    end

    -- ── Function expression: function(...) ... end ──────────────────────────
    if kind == NODE_FUNC_EXPR then
        local has_vararg = (n.flags % (FLAG_VARARG * 2)) >= FLAG_VARARG
        local fn_ty = gen_function(ctx, n.data[0], n.data[1], n.data[2], n.data[3],
            has_vararg, nil, n.line)
        return fn_ty
    end

    -- ── Table constructor: { ... } ──────────────────────────────────────────
    if kind == NODE_TABLE_EXPR then
        return gen_table_expr(ctx, nid)
    end

    -- ── Cast expression: --[[: T]] expr ─────────────────────────────────────
    if kind == defs.NODE_CAST_EXPR then
        return gen_expr(ctx, n.data[0])
    end

    return fresh_uvar(ctx)
end

-- ── Table constructor ─────────────────────────────────────────────────────────

--: (V5Ctx, integer) -> V5Type
gen_table_expr = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local fields = {} --[[: { [string]: V5Type } ]]
    local pos_idx = 1
    local fs = n.data[0]
    local fl = n.data[1]
    for i = fs, fs + fl - 1 do
        local fld_nid = ctx.lists:get(i)
        local fn = ctx.nodes:get(fld_nid)
        local val_ty = gen_expr(ctx, fn.data[1])
        local field_kind = fn.data[2]

        if field_kind == TFIELD_POSITIONAL then
            fields[tostring(pos_idx)] = val_ty
            pos_idx = pos_idx + 1
        elseif field_kind == TFIELD_NAMED then
            local key_str = intern_str(ctx, fn.data[0])
            fields[key_str] = val_ty
        else
            -- TFIELD_COMPUTED
            gen_expr(ctx, fn.data[0])
            local key = "$computed_" .. tostring(pos_idx)
            fields[key] = val_ty
            pos_idx = pos_idx + 1
        end
    end
    return types_mod.record(fields)
end

-- ── Function body ─────────────────────────────────────────────────────────────

-- Extract the annotated return type from an arrow type.
-- The result comes from `arrow.ret.fields["1"]` which is `V5Type | nil`.
-- Extracted into a helper so that the nil-narrowing works correctly:
-- assigning a local declared `nil` conditionally causes the checker to lose
-- narrowing context, but a function return of `V5Type | nil` narrows correctly.
--: (V5Type | nil) -> V5Type | nil
local function extract_ann_ret(ann_ty)
    if ann_ty ~= nil and ann_ty.tag == "arrow" then
        local ret_rec = ann_ty.ret
        if ret_rec ~= nil and ret_rec.tag == "record" then
            return ret_rec.fields["1"]
        end
    end
    return nil
end

-- Extract annotated parameter types from an arrow type.
--: (V5Type | nil) -> V5Type[] | nil
local function extract_ann_args(ann_ty)
    if ann_ty ~= nil and ann_ty.tag == "arrow" then
        return ann_ty.args
    end
    return nil
end

--: (V5Ctx, integer, integer, integer, integer, boolean, V5Type | nil, integer) -> V5Type
gen_function = function(ctx, ps, pl, bs, bl, has_vararg, ann_ty, line)
    local param_tys = {} --[[: V5Type[] ]]

    -- Unpack annotation arrow via helpers (avoids nil-narrowing loss from
    -- conditional local mutation).
    local ann_args = extract_ann_args(ann_ty)
    local ann_ret  = extract_ann_ret(ann_ty)

    push_scope(ctx)

    -- Bind parameters.
    for i = 0, pl - 1 do
        local name_id  = ctx.lists:get(ps + i)
        local name_str = intern_str(ctx, name_id)
        local param_ty --[[: V5Type]]
        if ann_args ~= nil then
            local at = ann_args[i + 1]
            if at ~= nil then
                param_ty = at
            else
                param_ty = fresh_uvar(ctx)
            end
        else
            param_ty = fresh_uvar(ctx)
        end
        param_tys[#param_tys + 1] = param_ty
        bind(ctx, name_str, param_ty)
    end

    if has_vararg then
        bind(ctx, "...", T_UNKNOWN)
    end

    -- Process body; collect return types.
    local saved_returns = ctx.return_stack
    ctx.return_stack = {}
    gen_block(ctx, bs, bl)
    local return_types = ctx.return_stack
    ctx.return_stack = saved_returns

    pop_scope(ctx)

    -- Determine return type.
    -- ann_ret is V5Type | nil from extract_ann_ret (function-return narrowing works).
    -- Emit sub-constraints for annotated return; compute inferred return otherwise.
    --: V5Type
    local ret_ty = T_NIL   -- default; overwritten below in every branch
    if ann_ret ~= nil then
        for ri = 1, #return_types do
            local rt = return_types[ri]
            if rt ~= nil then
                emit(ctx, C.sub(rt, ann_ret, prov_declared(ctx, line)))
            end
        end
        ret_ty = ann_ret
    elseif #return_types == 0 then
        ret_ty = T_NIL
    elseif #return_types == 1 then
        local rt0 = return_types[1]
        if rt0 ~= nil then
            ret_ty = rt0
        else
            ret_ty = T_NIL
        end
    else
        --: V5Type
        local union_ty = types_mod.union(return_types)
        ret_ty = union_ty
    end

    local rets_arr = {} --[[: V5Type[] ]]
    rets_arr[1]    = ret_ty
    --: V5Type
    local fn_ty = types_mod.arrow(param_tys, rets_arr)
    return fn_ty
end

-- ── Statement constraint generation ──────────────────────────────────────────

--: (V5Ctx, integer) -> nil
gen_stmt = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local kind = n.kind

    -- ── local x [= expr] ────────────────────────────────────────────────────
    if kind == NODE_LOCAL_STMT then
        local ns = n.data[0]
        local nl = n.data[1]
        local es = n.data[2]
        local el = n.data[3]

        local rhs_tys = {} --[[: V5Type[] ]]
        for i = es, es + el - 1 do
            local enid = ctx.lists:get(i)
            rhs_tys[#rhs_tys + 1] = gen_expr(ctx, enid)
        end

        local ann_ty = get_type_ann(ctx, n.line)

        for i = 0, nl - 1 do
            local name_id  = ctx.lists:get(ns + i)
            local name_str = intern_str(ctx, name_id)
            local rhs_ty   = rhs_tys[i + 1]

            if ann_ty ~= nil and i == 0 then
                if rhs_ty ~= nil then
                    emit(ctx, C.sub(rhs_ty, ann_ty, prov_declared(ctx, n.line)))
                end
                bind(ctx, name_str, ann_ty)
            elseif rhs_ty ~= nil then
                bind(ctx, name_str, rhs_ty)
            else
                bind(ctx, name_str, T_UNKNOWN)
            end
        end
        return
    end

    -- ── local function / function decl ──────────────────────────────────────
    if kind == NODE_FUNC_DECL then
        local name_n     = ctx.nodes:get(n.data[0])
        local has_vararg = (n.flags % (FLAG_VARARG * 2)) >= FLAG_VARARG
        local ann_ty     = get_type_ann(ctx, n.line)
        local fn_ty      = gen_function(ctx, n.data[1], n.data[2], n.data[3], n.data[4],
            has_vararg, ann_ty, n.line)

        if ann_ty ~= nil then
            emit(ctx, C.sub(fn_ty, ann_ty, prov_declared(ctx, n.line)))
        end

        local name_kind = name_n.kind
        if name_kind == NODE_IDENTIFIER then
            local name_str = intern_str(ctx, name_n.data[0])
            bind(ctx, name_str, fn_ty)
        elseif name_kind == NODE_FIELD_EXPR then
            local obj_ty  = gen_expr(ctx, name_n.data[0])
            local key_str = intern_str(ctx, name_n.data[1])
            emit(ctx, C.row_extend(obj_ty, key_str, fn_ty, prov_inferred(ctx, n.line)))
        end
        return
    end

    -- ── assignment: x, a.b, a[k] = expr, ... ───────────────────────────────
    if kind == NODE_ASSIGN_STMT then
        local ts = n.data[0]
        local tl = n.data[1]
        local es = n.data[2]
        local el = n.data[3]

        local rhs_tys = {} --[[: V5Type[] ]]
        for i = es, es + el - 1 do
            local enid = ctx.lists:get(i)
            rhs_tys[#rhs_tys + 1] = gen_expr(ctx, enid)
        end

        for i = 0, tl - 1 do
            local tgt_nid = ctx.lists:get(ts + i)
            local tn      = ctx.nodes:get(tgt_nid)
            local rhs_ty  = rhs_tys[i + 1] or T_NIL
            local tk      = tn.kind

            if tk == NODE_IDENTIFIER then
                local name_str = intern_str(ctx, tn.data[0])
                local existing = lookup(ctx, name_str)
                if existing ~= nil then
                    emit(ctx, C.sub(rhs_ty, existing, prov_inferred(ctx, n.line)))
                else
                    bind(ctx, name_str, rhs_ty)
                end
            elseif tk == NODE_FIELD_EXPR then
                local obj_ty  = gen_expr(ctx, tn.data[0])
                local key_str = intern_str(ctx, tn.data[1])
                emit(ctx, C.row_extend(obj_ty, key_str, rhs_ty, prov_inferred(ctx, n.line)))
            elseif tk == NODE_INDEX_EXPR then
                gen_expr(ctx, tn.data[0])
                gen_expr(ctx, tn.data[1])
            end
        end
        return
    end

    -- ── return [expr, ...] ───────────────────────────────────────────────────
    if kind == NODE_RETURN_STMT then
        local rs = n.data[0]
        local rl = n.data[1]
        if rl == 0 then
            ctx.return_stack[#ctx.return_stack + 1] = T_NIL
        elseif rl == 1 then
            local ret_ty = gen_expr(ctx, ctx.lists:get(rs))
            ctx.return_stack[#ctx.return_stack + 1] = ret_ty
        else
            local parts = {} --[[: V5Type[] ]]
            for i = rs, rs + rl - 1 do
                parts[#parts + 1] = gen_expr(ctx, ctx.lists:get(i))
            end
            ctx.return_stack[#ctx.return_stack + 1] = types_mod.union(parts)
        end
        return
    end

    -- ── expression statement ─────────────────────────────────────────────────
    if kind == NODE_EXPR_STMT then
        gen_expr(ctx, n.data[0])
        return
    end

    -- ── do ... end ──────────────────────────────────────────────────────────
    if kind == NODE_DO_STMT then
        push_scope(ctx)
        gen_block(ctx, n.data[0], n.data[1])
        pop_scope(ctx)
        return
    end

    -- ── while cond do ... end ───────────────────────────────────────────────
    if kind == NODE_WHILE_STMT then
        gen_expr(ctx, n.data[0])
        push_scope(ctx)
        gen_block(ctx, n.data[1], n.data[2])
        pop_scope(ctx)
        return
    end

    -- ── repeat ... until cond ───────────────────────────────────────────────
    if kind == NODE_REPEAT_STMT then
        push_scope(ctx)
        gen_block(ctx, n.data[1], n.data[2])
        gen_expr(ctx, n.data[0])
        pop_scope(ctx)
        return
    end

    -- ── if ... end ──────────────────────────────────────────────────────────
    if kind == NODE_IF_STMT then
        local cs = n.data[0]
        local cl = n.data[1]
        for i = cs, cs + cl - 1 do
            local cnid = ctx.lists:get(i)
            local cn   = ctx.nodes:get(cnid)
            gen_expr(ctx, cn.data[0])
            push_scope(ctx)
            gen_block(ctx, cn.data[1], cn.data[2])
            pop_scope(ctx)
        end
        -- else block: data[2]=start, data[3]=len (present when FLAG_HAS_ELSE)
        if n.data[3] > 0 then
            push_scope(ctx)
            gen_block(ctx, n.data[2], n.data[3])
            pop_scope(ctx)
        end
        return
    end

    -- ── for i = ... ─────────────────────────────────────────────────────────
    if kind == NODE_FOR_NUM then
        gen_expr(ctx, n.data[1])
        gen_expr(ctx, n.data[2])
        if (n.flags % (FLAG_HAS_STEP * 2)) >= FLAG_HAS_STEP then
            gen_expr(ctx, n.data[3])
        end
        push_scope(ctx)
        local name_str = intern_str(ctx, n.data[0])
        bind(ctx, name_str, T_NUMBER)
        gen_block(ctx, n.data[4], n.data[5])
        pop_scope(ctx)
        return
    end

    -- ── for name, ... in exprlist do ... end ─────────────────────────────────
    if kind == NODE_FOR_IN then
        local es = n.data[2]
        local el = n.data[3]
        for i = es, es + el - 1 do
            gen_expr(ctx, ctx.lists:get(i))
        end
        push_scope(ctx)
        local ns = n.data[0]
        local nl = n.data[1]
        for i = 0, nl - 1 do
            local name_str = intern_str(ctx, ctx.lists:get(ns + i))
            bind(ctx, name_str, T_UNKNOWN)
        end
        gen_block(ctx, n.data[4], n.data[5])
        pop_scope(ctx)
        return
    end

    -- break / goto / label: nothing to emit.
end

-- ── Block walk ────────────────────────────────────────────────────────────────

--: (V5Ctx, integer, integer) -> nil
gen_block = function(ctx, bs, bl)
    for i = bs, bs + bl - 1 do
        local snid = ctx.lists:get(i)
        gen_stmt(ctx, snid)
    end
end

-- ── Entry point ───────────────────────────────────────────────────────────────

-- Generate v5 constraints from Lua source.
--
-- Parameters:
--   source   — Lua source string.
--   filename — filename for provenance (defaults to "?").
--   opts     — optional table { pool? }.
--
-- Returns:
--   constraints — flat V5Constraint array.
--   errors      — string array (parse errors, annotation errors).
--
--: (string, string | nil, { pool?: InternPool, ... } | nil) -> (V5Constraint[], string[])
function M.generate(source, filename, opts)
    filename = filename or "?"
    -- opts.pool is an optional performance hint (share an intern pool).
    -- For simplicity and type-safety, always create a fresh pool here.
    -- Sharing can be added in 5.C once opts types are better declared.
    --: InternPool
    local pool = intern_mod.new()
    local _opts_unused = opts  -- suppress unused warning

    local errors      = {} --[[: string[] ]]
    local constraints = {} --[[: V5Constraint[] ]]

    -- Parse the source via v4's parser (read-only contract on the result).
    local ok, pr = pcall(parse_mod.parse, source, filename, pool)
    if not ok then
        errors[#errors + 1] = filename .. ":0: parse error: " .. tostring(pr)
        return constraints, errors
    end

    -- Extract parse result fields.  After `if not ok then return end`, the
    -- checker knows pr's type from parse_mod.parse's actual return type.
    -- We annotate each extracted local so downstream code sees the right type.
    --: ListPool
    local pr_lists = pr.lists
    --: ASTNodeArena
    local pr_nodes = pr.nodes
    --: integer | nil
    local pr_root  = pr.root
    --: { annotations: { [integer]: RawAnn }, ... } | nil
    local pr_lexer = pr.lexer

    --: { [integer]: RawAnn } | nil
    local raw_anns = nil
    if pr_lexer ~= nil then
        --: { [integer]: RawAnn }
        local lexer_anns = pr_lexer.annotations
        raw_anns = lexer_anns
    end

    -- Build the context.
    --: V5Ctx
    local ctx = {
        filename     = filename,
        nodes        = pr_nodes,
        lists        = pr_lists,
        pool         = pool,
        constraints  = constraints,
        errors       = errors,
        scope        = {},
        scope_stack  = {},
        return_stack = {},
        annotations  = raw_anns,
        _next_uvar   = 1,
    }

    -- Seed scope_stack with the top-level scope.
    ctx.scope_stack[1] = ctx.scope

    -- Process top-level --:: declare directives to pre-populate scope.
    if raw_anns ~= nil then
        for line, entry in pairs(raw_anns) do
            --: RawAnn
            local rann = entry
            if rann.kind == ANN_DECL then
                local dir, derr = ann_mod.parse_declaration(rann.content)
                if dir == nil and derr ~= nil then
                    errors[#errors + 1] = filename .. ":" .. tostring(line)
                        .. ": declaration parse error: " .. derr
                elseif dir ~= nil then
                    local dk = dir.kind
                    -- declare_var / type_alias / etc. are residual gaps for 5.C.
                    -- parse_declaration returns { [string]: unknown }; to bind
                    -- declare_var values we would need ann.lua to return a typed
                    -- directive struct (tracked as gap).
                    _ = dk
                end
            end
        end
    end

    -- Walk the AST.
    if pr_root ~= nil then
        local chunk = pr_nodes:get(pr_root)
        gen_block(ctx, chunk.data[0], chunk.data[1])
    end

    return constraints, errors
end

return M
