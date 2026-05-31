-- lib/type/static-v6/source.lua
-- M1 direct-arena source checker for literals, bindings, assignment, and casts.

local parse_mod  = require("lib.type.static.parse")
local defs       = require("lib.type.static.defs")
local intern_mod = require("lib.type.static.intern")

local ann_mod = require("lib.type.static-v6.ann")
local diag    = require("lib.type.static-v6.diagnostics")
local env_mod = require("lib.type.static-v6.env")
local subtype = require("lib.type.static-v6.subtype")
local types   = require("lib.type.static-v6.types")

local M = {}

--:: AtomType = { tag: "atom", name: string }
--:: LiteralType = { tag: "literal", base: string, value: unknown }
--:: UnknownType = { tag: "unknown" }
--:: NeverType = { tag: "never" }
--:: AnyType = { tag: "any" }
--:: UnionType = { tag: "union", members: { [integer]: StaticType } }
--:: IntersectionType = { tag: "intersection", members: { [integer]: StaticType } }
--:: ComplementType = { tag: "complement", of: StaticType }
--:: Pack = { items: { [integer]: StaticType }, rest: StaticType | nil }
--:: ArrowType = { tag: "arrow", params: Pack, returns: Pack, effects: unknown }
--:: RecordType = { tag: "record" }
--:: NominalType = { tag: "nominal", name: string }
--:: VarType = { tag: "var", id: integer }
--:: StaticType = AtomType | LiteralType | UnknownType | NeverType | AnyType | UnionType | IntersectionType | ComplementType | ArrowType | RecordType | NominalType | VarType
--:: CheckDiag = { code: string, message: string, details: unknown, ... }
--:: Span = { file: string | nil, line: integer | nil, column: integer | nil, ... }
--:: Obligation = { kind: "obligation", producer: StaticType, consumer: StaticType, site: string, reason: string, span: Span | nil, discharged: boolean, diagnostic: CheckDiag | nil, ... }
--:: BindingFact = { kind: "binding", symbol: string, type: StaticType, span: Span | nil, ... }
--:: UnsafeBoundary = { kind: "unsafe_boundary", type: StaticType, site: string, reason: string, span: Span | nil, ... }
--:: RawAnn = { kind: integer, content: string, line: integer | nil, col: integer | nil, force_cast: boolean | nil, ... }
--:: ListPool = { get: (ListPool, integer) -> integer, ... }
--:: ASTNode = { kind: integer, flags: integer, line: integer, col: integer, data: { [integer]: integer, ... } }
--:: ASTNodeArena = { get: (ASTNodeArena, integer) -> ASTNode, ... }
--:: InternPool = { ... }
--:: AnnState = {}
--:: Env = { bindings: { [string]: StaticType }, binding_facts: { [integer]: BindingFact }, obligations: { [integer]: Obligation }, unsafe_boundaries: { [integer]: UnsafeBoundary } }
--:: Ctx = { filename: string, nodes: ASTNodeArena, lists: ListPool, pool: InternPool, annotations: { [integer]: RawAnn } | nil, used_annotations: { [integer]: boolean }, ann_state: AnnState, env: Env, diagnostics: { [integer]: CheckDiag } }
--:: Result = { ok: boolean, sound: boolean, facts_valid: boolean, env: Env, diagnostics: { [integer]: CheckDiag } }

local NODE_LITERAL = defs.NODE_LITERAL
local NODE_IDENTIFIER = defs.NODE_IDENTIFIER
local NODE_ASSIGN_STMT = defs.NODE_ASSIGN_STMT
local NODE_LOCAL_STMT = defs.NODE_LOCAL_STMT
local NODE_CHUNK = defs.NODE_CHUNK
local NODE_CAST_EXPR = defs.NODE_CAST_EXPR
local NODE_FUNC_EXPR = defs.NODE_FUNC_EXPR
local NODE_RETURN_STMT = defs.NODE_RETURN_STMT
local NODE_CALL_EXPR = defs.NODE_CALL_EXPR
local NODE_EXPR_STMT = defs.NODE_EXPR_STMT
local NODE_FUNC_DECL = defs.NODE_FUNC_DECL

--: (Ctx, string, string, ASTNode | nil) -> CheckDiag
local function add_error(ctx, code, message, node)
    local span = nil
    if node then
        span = { file = ctx.filename, line = node.line, column = node.col }
    end
    local d = diag.new(code, message, { span = span })
    ctx.diagnostics[#ctx.diagnostics + 1] = d
    return d
end

--: (Ctx, string, string, Span | nil) -> CheckDiag
local function add_error_span(ctx, code, message, span)
    local d = diag.new(code, message, { span = span })
    ctx.diagnostics[#ctx.diagnostics + 1] = d
    return d
end

--: (Ctx, integer) -> string
local function intern_str(ctx, id)
    local s = intern_mod.get(ctx.pool, id)
    if s == nil then return "?id:" .. tostring(id) end
    return s
end

--: (Ctx, integer) -> RawAnn | nil
local function raw_type_ann(ctx, line)
    local anns = ctx.annotations
    if not anns then return nil end
    if not ctx.used_annotations[line] then
        local r = anns[line]
        if r and r.kind == defs.ANN_TYPE then ctx.used_annotations[line] = true; return r end
    end
    local prev = line - 1
    if ctx.used_annotations[prev] then return nil end
    local r = anns[prev]
    if r and r.kind == defs.ANN_TYPE then ctx.used_annotations[prev] = true; return r end
    return nil
end

--: (Ctx, integer) -> boolean
local function consume_decl_ann(ctx, line)
    local anns = ctx.annotations
    if not anns or ctx.used_annotations[line] then return false end
    local r = anns[line]
    if r and r.kind == defs.ANN_DECL then
        ctx.used_annotations[line] = true
        add_error_span(ctx, "FEATURE_NOT_ADMITTED", "v6 M1 declarations are not admitted yet", {
            file = ctx.filename,
            line = r.line or line,
            column = r.col,
        })
        return true
    end
    return false
end

--: (Ctx, integer, ASTNode) -> StaticType | nil
local function parse_type_ann(ctx, line, node)
    local r = raw_type_ann(ctx, line)
    if not r then return nil end
    local typ, err = ann_mod.parse_annotation(ctx.ann_state, r.content)
    if err then
        add_error_span(ctx, "ANNOTATION_PARSE_ERROR", err, {
            file = ctx.filename,
            line = r.line or line,
            column = r.col,
        })
        return nil
    end
    return typ
end

--: (Ctx, integer, ASTNode) -> StaticType | nil
local function parse_cast_ann(ctx, id, node)
    local anns = ctx.annotations
    local r = anns and anns[id]
    if not r or r.kind ~= defs.ANN_TYPE then
        add_error(ctx, "ANNOTATION_PARSE_ERROR", "missing cast annotation", node)
        return nil
    end
    local typ, err = ann_mod.parse_annotation(ctx.ann_state, r.content)
    if err then
        add_error_span(ctx, "ANNOTATION_PARSE_ERROR", err, {
            file = ctx.filename,
            line = r.line or node.line,
            column = r.col or node.col,
        })
        return nil
    end
    return typ
end

--: (integer) -> boolean
local function has_force_cast_flag(flags)
    return (flags % (defs.FLAG_FORCE_CAST * 2)) >= defs.FLAG_FORCE_CAST
end

local check_expr
local check_stmt

--: ({ [integer]: StaticType }, StaticType) -> nil
local function push_type(out, typ)
    out[#out + 1] = typ
end

--: (StaticType, { [integer]: ArrowType }) -> boolean
local function collect_arrow_branches(typ, out)
    if typ.tag == "arrow" then
        out[#out + 1] = typ
        return true
    end
    if typ.tag == "intersection" then
        for _, member in ipairs(typ.members) do
            if not collect_arrow_branches(member, out) then return false end
        end
        return true
    end
    return false
end

--: (Ctx, ASTNode, ArrowType, { [integer]: StaticType }, boolean) -> { [integer]: StaticType } | nil
local function check_arrow_call_pack(ctx, n, callee, args, emit_errors)
    local params = callee.params
    local returns = callee.returns
    if params == nil or returns == nil then
        if emit_errors then add_error(ctx, "INTERNAL_TYPECHECKER_ERROR", "arrow type missing pack", n) end
        return nil
    end
    if params.rest ~= nil or returns.rest ~= nil then
        if emit_errors then add_error(ctx, "FEATURE_NOT_ADMITTED", "v6 M2 calls do not admit open packs yet", n) end
        return nil
    end
    if #args ~= #params.items then
        if emit_errors then
            add_error(ctx, "FUNCTION_ARITY_MISMATCH",
                "call arity " .. tostring(#args) .. " does not match parameter arity " .. tostring(#params.items), n)
        end
        return nil
    end
    for i = 1, #args do
        local producer = args[i]
        local consumer = params.items[i]
        local ok, err = subtype.is_subtype(producer, consumer, { site = "call argument", term_budget = 256 })
        if not ok then
            if emit_errors and err then
                local details = err.details
                if type(details) ~= "table" then details = {} end
                details.span = details.span or { file = ctx.filename, line = n.line, column = n.col }
                details.obligation_reason = "call argument"
                details.obligation_site = "call argument"
                err.details = details
                ctx.diagnostics[#ctx.diagnostics + 1] = err
            end
            return nil
        end
    end
    return returns.items
end

--: (Ctx, ASTNode, StaticType, integer, integer) -> StaticType
local function check_call_against_arrow(ctx, n, callee, arg_start, arg_len)
    if callee.tag == "unknown" then return types.unknown() end
    local args = {} --: { [integer]: StaticType }
    for i = 1, arg_len do
        args[#args + 1] = check_expr(ctx, ctx.lists:get(arg_start + i - 1))
    end
    if callee.tag == "arrow" then
        local returns = check_arrow_call_pack(ctx, n, callee, args, true)
        if returns == nil then return types.unknown() end
        if #returns ~= 1 then
            add_error(ctx, "FEATURE_NOT_ADMITTED", "v6 M2 expression calls require exactly one return for now", n)
            return types.unknown()
        end
        return returns[1]
    end
    local branches = {} --: { [integer]: ArrowType }
    if not collect_arrow_branches(callee, branches) then
        add_error(ctx, "CANNOT_CALL", "cannot call non-function type " .. types.tostring(callee), n)
        return types.unknown()
    end
    local returns = {} --: { [integer]: StaticType }
    for _, branch in ipairs(branches) do
        local branch_returns = check_arrow_call_pack(ctx, n, branch, args, false)
        if branch_returns ~= nil then
            if #branch_returns ~= 1 then
                add_error(ctx, "FEATURE_NOT_ADMITTED", "v6 M2 overloaded expression calls require one return per matching branch", n)
                return types.unknown()
            end
            returns[#returns + 1] = branch_returns[1]
        end
    end
    if #returns == 0 then
        add_error(ctx, "NO_MATCHING_OVERLOAD", "no overload branch accepts argument pack", n)
        return types.unknown()
    end
    if #returns == 1 then return returns[1] end
    return types.union(returns)
end

--: (Ctx, ASTNode) -> { [integer]: StaticType } | nil
local function check_final_call_pack(ctx, n)
    if n.kind ~= NODE_CALL_EXPR then return nil end
    local callee = check_expr(ctx, n.data[0])
    if callee.tag == "arrow" then
        local args = {} --: { [integer]: StaticType }
        for i = 1, n.data[2] do
            push_type(args, check_expr(ctx, ctx.lists:get(n.data[1] + i - 1)))
        end
        return check_arrow_call_pack(ctx, n, callee, args, true) or { types.unknown() }
    else
        add_error(ctx, "CANNOT_CALL", "cannot call non-function type " .. types.tostring(callee), n)
        return { types.unknown() }
    end
end

--: (Ctx, integer, integer, integer) -> { [integer]: StaticType }
local function adjust_local_rhs(ctx, expr_start, expr_len, target_len)
    local values = {} --: { [integer]: StaticType }
    if expr_len == 0 then
        while #values < target_len do push_type(values, types.atom("nil")) end
        return values
    end
    for i = 1, expr_len do
        local expr_id = ctx.lists:get(expr_start + i - 1)
        local expr = ctx.nodes:get(expr_id)
        if i == expr_len then
            local pack = check_final_call_pack(ctx, expr)
            if pack ~= nil then
                for _, item in ipairs(pack) do push_type(values, item) end
            else
                local value = check_expr(ctx, expr_id)
                push_type(values, value)
            end
        else
            local pack = check_final_call_pack(ctx, expr)
            if pack ~= nil then
                push_type(values, pack[1] or types.atom("nil"))
            else
                local value = check_expr(ctx, expr_id)
                push_type(values, value)
            end
        end
    end
    local adjusted = {} --: { [integer]: StaticType }
    for i = 1, target_len do
        push_type(adjusted, values[i] or types.atom("nil"))
    end
    return adjusted
end

--: (Env) -> Env
local function child_env(parent)
    local child = env_mod.new()
    for name, typ in pairs(parent.bindings) do
        child.bindings[name] = typ
    end
    return child
end

--: (Env, Env) -> nil
local function merge_child_effects(parent, child)
    for _, boundary in ipairs(child.unsafe_boundaries) do
        parent.unsafe_boundaries[#parent.unsafe_boundaries + 1] = boundary
    end
end

--: (Ctx, ASTNode, Pack) -> nil
local function check_return_stmt(ctx, n, returns)
    local rs = n.data[0]
    local rl = n.data[1]
    local want = returns.items
    if returns.rest ~= nil then
        add_error(ctx, "FEATURE_NOT_ADMITTED", "v6 M2 function returns do not admit open return packs yet", n)
        return
    end
    if rl ~= #want then
        add_error(ctx, "FUNCTION_ARITY_MISMATCH",
            "return arity " .. tostring(rl) .. " does not match annotation arity " .. tostring(#want), n)
        return
    end
    for i = 1, rl do
        local producer = check_expr(ctx, ctx.lists:get(rs + i - 1))
        local consumer = want[i]
        local obligation = env_mod.require_subtype(ctx.env, producer, consumer, "return", "function return", {
            file = ctx.filename,
            line = n.line,
            column = n.col,
        })
        local ok, err = env_mod.discharge_obligation(obligation)
        if not ok and err then ctx.diagnostics[#ctx.diagnostics + 1] = err end
    end
end

--: (Ctx, integer, integer, integer, integer, integer, ArrowType, ASTNode, string | nil, StaticType | nil) -> boolean
local function check_func_body_against(ctx, ps, pl, bs, bl, flags, arrow, owner, self_name, self_type)
    if flags % (defs.FLAG_VARARG * 2) >= defs.FLAG_VARARG then
        add_error(ctx, "FEATURE_NOT_ADMITTED", "v6 M2 function literals do not admit varargs yet", owner)
        return true
    end
    local params = arrow.params
    if params.rest ~= nil then
        add_error(ctx, "FEATURE_NOT_ADMITTED", "v6 M2 function literals do not admit open parameter packs yet", owner)
        return true
    end
    if pl ~= #params.items then
        add_error(ctx, "FUNCTION_ARITY_MISMATCH",
            "function parameter arity " .. tostring(pl) .. " does not match annotation arity " .. tostring(#params.items), owner)
        return true
    end
    if bl < 1 then
        add_error(ctx, "FEATURE_NOT_ADMITTED", "v6 M2 function body must end with an explicit return for now", owner)
        return true
    end
    local ret_id = ctx.lists:get(bs + bl - 1)
    local ret = ctx.nodes:get(ret_id)
    if ret.kind ~= NODE_RETURN_STMT then
        add_error(ctx, "FEATURE_NOT_ADMITTED", "v6 M2 function body must end with a return statement for now", ret)
        return true
    end

    local nested = {
        filename = ctx.filename,
        nodes = ctx.nodes,
        lists = ctx.lists,
        pool = ctx.pool,
        annotations = ctx.annotations,
        used_annotations = ctx.used_annotations,
        ann_state = ctx.ann_state,
        env = child_env(ctx.env),
        diagnostics = ctx.diagnostics,
    }
    if self_name ~= nil then
        env_mod.bind(nested.env, self_name, self_type or arrow, {
            file = ctx.filename,
            line = owner.line,
            column = owner.col,
        })
    end
    for i = 1, pl do
        local name = intern_str(ctx, ctx.lists:get(ps + i - 1))
        env_mod.bind(nested.env, name, params.items[i], {
            file = ctx.filename,
            line = owner.line,
            column = owner.col,
        })
    end
    for i = 0, bl - 2 do
        check_stmt(nested, ctx.lists:get(bs + i))
    end
    check_return_stmt(nested, ret, arrow.returns)
    merge_child_effects(ctx.env, nested.env)
    return true
end

--: (Ctx, integer, integer, integer, integer, integer, StaticType, ASTNode, string | nil) -> boolean
local function check_func_type_against(ctx, ps, pl, bs, bl, flags, typ, owner, self_name)
    local branches = {} --: { [integer]: ArrowType }
    if not collect_arrow_branches(typ, branches) then
        add_error(ctx, "TYPE_MISMATCH", "function annotation must be an arrow or intersection of arrows", owner)
        return true
    end
    for _, branch in ipairs(branches) do
        check_func_body_against(ctx, ps, pl, bs, bl, flags, branch, owner, self_name, typ)
    end
    return true
end

--: (Ctx, integer, StaticType, ASTNode) -> boolean
local function check_func_expr_against(ctx, nid, arrow, owner)
    local n = ctx.nodes:get(nid)
    if n.kind ~= NODE_FUNC_EXPR then return false end
    return check_func_type_against(ctx, n.data[0], n.data[1], n.data[2], n.data[3], n.flags, arrow, n, nil)
end

--: (Ctx, integer) -> StaticType
check_expr = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local kind = n.kind

    if kind == NODE_LITERAL then
        local lit = n.data[0]
        if lit == defs.LIT_NIL then return types.atom("nil") end
        if lit == defs.LIT_BOOLEAN then return types.literal("boolean", n.data[1] ~= 0) end
        if lit == defs.LIT_INTEGER then return types.literal("integer", n.data[1]) end
        if lit == defs.LIT_NUMBER then
            return types.literal("number", defs.i32x2_to_double(n.data[1], n.data[2]))
        end
        if lit == defs.LIT_STRING then return types.literal("string", intern_str(ctx, n.data[1])) end
        add_error(ctx, "FEATURE_NOT_ADMITTED", "literal kind not admitted in v6 M1", n)
        return types.unknown()
    end

    if kind == NODE_IDENTIFIER then
        local name = intern_str(ctx, n.data[0])
        local typ = env_mod.lookup(ctx.env, name)
        if typ then return typ end
        add_error(ctx, "UNDECLARED_BINDING", "undeclared binding '" .. name .. "'", n)
        return types.unknown()
    end

    if kind == NODE_CAST_EXPR then
        local inner = check_expr(ctx, n.data[0])
        local target = parse_cast_ann(ctx, n.data[1], n)
        if not target then return inner end
        if has_force_cast_flag(n.flags) then
            env_mod.record_unsafe_boundary(ctx.env, target, "force cast", "source force cast", {
                file = ctx.filename,
                line = n.line,
                column = n.col,
            })
            return target
        end
        local obligation = env_mod.require_subtype(ctx.env, inner, target, "checked cast", "source checked cast", {
            file = ctx.filename,
            line = n.line,
            column = n.col,
        })
        local ok, err = env_mod.discharge_obligation(obligation)
        if not ok and err then ctx.diagnostics[#ctx.diagnostics + 1] = err; return inner end
        return target
    end

    if kind == NODE_CALL_EXPR then
        local callee = check_expr(ctx, n.data[0])
        return check_call_against_arrow(ctx, n, callee, n.data[1], n.data[2])
    end

    add_error(ctx, "FEATURE_NOT_ADMITTED", "expression node not admitted in v6 M1: " .. tostring(kind), n)
    return types.unknown()
end

--: (Ctx, ASTNode) -> nil
local function check_local(ctx, n)
    local ns = n.data[0]
    local nl = n.data[1]
    local es = n.data[2]
    local el = n.data[3]
    if nl < 1 then
        add_error(ctx, "FEATURE_NOT_ADMITTED", "v6 M1 local binding has no names", n)
        return
    end
    if nl > 1 then
        local values = adjust_local_rhs(ctx, es, el, nl)
        for i = 1, nl do
            local name = intern_str(ctx, ctx.lists:get(ns + i - 1))
            env_mod.bind(ctx.env, name, values[i], { file = ctx.filename, line = n.line, column = n.col })
        end
        return
    end
    if el > 1 then
        add_error(ctx, "FEATURE_NOT_ADMITTED", "v6 M1 admits only 1:1 annotated or single-name local bindings", n)
        return
    end
    local ann_ty = parse_type_ann(ctx, n.line, n)
    local name = intern_str(ctx, ctx.lists:get(ns))
    if ann_ty and (ann_ty.tag == "arrow" or ann_ty.tag == "intersection") and el == 1 then
        local expr_id = ctx.lists:get(es)
        local diag_start = #ctx.diagnostics
        if check_func_expr_against(ctx, expr_id, ann_ty, n) then
            if #ctx.diagnostics == diag_start then
                env_mod.bind(ctx.env, name, ann_ty, { file = ctx.filename, line = n.line, column = n.col })
            end
            return
        end
    end
    local producer = types.atom("nil") --: StaticType
    if el == 1 then producer = check_expr(ctx, ctx.lists:get(es)) end
    if ann_ty then
        local consumer = ann_ty
        local ok, _fact, err = env_mod.bind_checked(ctx.env, name, producer, consumer,
            "local annotation", "local annotation", {
                file = ctx.filename,
                line = n.line,
                column = n.col,
            })
        if not ok and err then ctx.diagnostics[#ctx.diagnostics + 1] = err end
        return
    end
    env_mod.bind(ctx.env, name, producer, { file = ctx.filename, line = n.line, column = n.col })
end

--: (Ctx, ASTNode) -> nil
local function check_assign(ctx, n)
    local ts = n.data[0]
    local tl = n.data[1]
    local es = n.data[2]
    local el = n.data[3]
    if tl ~= 1 or el ~= 1 then
        add_error(ctx, "FEATURE_NOT_ADMITTED", "v6 M1 admits only 1:1 assignments", n)
        return
    end
    local target_id = ctx.lists:get(ts)
    local target = ctx.nodes:get(target_id)
    if target.kind ~= NODE_IDENTIFIER then
        add_error(ctx, "FEATURE_NOT_ADMITTED", "v6 M1 assignment target must be an identifier", target)
        return
    end
    local name = intern_str(ctx, target.data[0])
    local consumer = env_mod.lookup(ctx.env, name)
    if not consumer then
        add_error(ctx, "UNDECLARED_BINDING", "assignment to undeclared binding '" .. name .. "'", target)
        return
    end
    local producer = check_expr(ctx, ctx.lists:get(es))
    local ann_ty = parse_type_ann(ctx, n.line, n)
    if ann_ty then
        local ann_obligation = env_mod.require_subtype(ctx.env, producer, ann_ty,
            "assignment annotation", "assignment annotation", {
                file = ctx.filename,
                line = n.line,
                column = n.col,
            })
        local ann_ok, ann_err = env_mod.discharge_obligation(ann_obligation)
        if not ann_ok and ann_err then ctx.diagnostics[#ctx.diagnostics + 1] = ann_err end
    end
    local obligation = env_mod.require_subtype(ctx.env, producer, consumer, "assignment", "assignment", {
        file = ctx.filename,
        line = n.line,
        column = n.col,
    })
    local ok, err = env_mod.discharge_obligation(obligation)
    if not ok and err then ctx.diagnostics[#ctx.diagnostics + 1] = err end
end

--: (Ctx, ASTNode) -> nil
local function check_func_decl(ctx, n)
    if n.flags % (defs.FLAG_LOCAL * 2) < defs.FLAG_LOCAL then
        add_error(ctx, "FEATURE_NOT_ADMITTED", "v6 M2 admits only local function declarations for now", n)
        return
    end
    local name_node = ctx.nodes:get(n.data[0])
    if name_node.kind ~= NODE_IDENTIFIER then
        add_error(ctx, "FEATURE_NOT_ADMITTED", "v6 M2 local function name must be an identifier", name_node)
        return
    end
    local name = intern_str(ctx, name_node.data[0])
    local ann_ty = parse_type_ann(ctx, n.line, n)
    if not ann_ty then
        add_error(ctx, "FEATURE_NOT_ADMITTED", "v6 M2 local function declarations require an arrow annotation", n)
        return
    end
    if ann_ty.tag ~= "arrow" and ann_ty.tag ~= "intersection" then
        add_error(ctx, "TYPE_MISMATCH", "local function annotation must be an arrow or intersection of arrows", n)
        return
    end
    local diag_start = #ctx.diagnostics
    check_func_type_against(ctx, n.data[1], n.data[2], n.data[3], n.data[4], n.flags, ann_ty, n, name)
    if #ctx.diagnostics == diag_start then
        env_mod.bind(ctx.env, name, ann_ty, { file = ctx.filename, line = n.line, column = n.col })
    end
end

--: (Ctx, integer) -> nil
check_stmt = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local kind = n.kind
    consume_decl_ann(ctx, n.line)
    if kind == NODE_LOCAL_STMT then check_local(ctx, n); return end
    if kind == NODE_ASSIGN_STMT then check_assign(ctx, n); return end
    if kind == NODE_FUNC_DECL then check_func_decl(ctx, n); return end
    if kind == NODE_EXPR_STMT then check_expr(ctx, n.data[0]); return end
    add_error(ctx, "FEATURE_NOT_ADMITTED", "statement node not admitted in v6 M1: " .. tostring(kind), n)
end

--: (Ctx, integer, integer) -> nil
local function check_block(ctx, start, len)
    for i = 0, len - 1 do
        check_stmt(ctx, ctx.lists:get(start + i))
    end
end

--: (Ctx) -> nil
local function check_unused_annotations(ctx)
    local anns = ctx.annotations
    if not anns then return end
    local keys = {} --: { [integer]: integer | number }
    for key, _r in pairs(anns) do
        if key >= 0 and not ctx.used_annotations[key] then
            keys[#keys + 1] = key
        end
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local r = anns[key]
        if key >= 0 and not ctx.used_annotations[key] then
            if r.kind == defs.ANN_DECL then
                ctx.used_annotations[key] = true
                add_error_span(ctx, "FEATURE_NOT_ADMITTED", "v6 M1 declarations are not admitted yet", {
                    file = ctx.filename,
                    line = r.line or key,
                    column = r.col,
                })
            elseif r.kind == defs.ANN_TYPE then
                local _typ, err = ann_mod.parse_annotation(ctx.ann_state, r.content)
                ctx.used_annotations[key] = true
                if err then
                    add_error_span(ctx, "ANNOTATION_PARSE_ERROR", err, {
                        file = ctx.filename,
                        line = r.line or key,
                        column = r.col,
                    })
                else
                    add_error_span(ctx, "ANNOTATION_NOT_ATTACHED", "type annotation is not attached to an admitted source form", {
                        file = ctx.filename,
                        line = r.line or key,
                        column = r.col,
                    })
                end
            end
        end
    end
end

--: (string, string | nil) -> Result
function M.check_string(source, filename)
    filename = filename or "<string>"
    local parsed_ok, pr_or_err = pcall(function()
        return parse_mod.parse(source, filename)
    end)
    if not parsed_ok then
        return {
            ok = false,
            sound = false,
            facts_valid = false,
            env = env_mod.new(),
            diagnostics = {
                diag.new("PARSE_ERROR", tostring(pr_or_err), { span = { file = filename } }),
            },
        }
    end
    local pr = pr_or_err
    local root = pr.root
    local root_node = pr.nodes:get(root)
    local root_kind = root_node.kind
    local env = env_mod.new()
    local diagnostics = {} --: { [integer]: CheckDiag }
    local annotations = nil
    if pr.lexer then annotations = pr.lexer.annotations end
    local ctx = {
        filename = filename,
        nodes = pr.nodes,
        lists = pr.lists,
        pool = pr.pool,
        annotations = annotations,
        used_annotations = {},
        ann_state = ann_mod.new_state(),
        env = env,
        diagnostics = diagnostics,
    }
    if root_kind ~= NODE_CHUNK then
        add_error(ctx, "INTERNAL_TYPECHECKER_ERROR", "parser root is not a chunk", root_node)
    else
        check_block(ctx, root_node.data[0], root_node.data[1])
    end
    check_unused_annotations(ctx)
    local ok_ = #diagnostics == 0
    local sound = false
    if ok_ and #env.unsafe_boundaries == 0 then sound = true end
    return { ok = ok_, sound = sound, facts_valid = sound, env = env, diagnostics = diagnostics }
end

return M
