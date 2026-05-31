-- lib/type/static-v6/source.lua
-- M1 direct-arena source checker for literals, bindings, assignment, and casts.

local parse_mod  = require("lib.type.static.parse")
local defs       = require("lib.type.static.defs")
local intern_mod = require("lib.type.static.intern")

local ann_mod = require("lib.type.static-v6.ann")
local diag    = require("lib.type.static-v6.diagnostics")
local env_mod = require("lib.type.static-v6.env")
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
--:: Result = { ok: boolean, env: Env, diagnostics: { [integer]: CheckDiag } }

local NODE_LITERAL = defs.NODE_LITERAL
local NODE_IDENTIFIER = defs.NODE_IDENTIFIER
local NODE_ASSIGN_STMT = defs.NODE_ASSIGN_STMT
local NODE_LOCAL_STMT = defs.NODE_LOCAL_STMT
local NODE_CHUNK = defs.NODE_CHUNK
local NODE_CAST_EXPR = defs.NODE_CAST_EXPR

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

    add_error(ctx, "FEATURE_NOT_ADMITTED", "expression node not admitted in v6 M1: " .. tostring(kind), n)
    return types.unknown()
end

--: (Ctx, ASTNode) -> nil
local function check_local(ctx, n)
    local ns = n.data[0]
    local nl = n.data[1]
    local es = n.data[2]
    local el = n.data[3]
    if nl ~= 1 or el > 1 then
        add_error(ctx, "FEATURE_NOT_ADMITTED", "v6 M1 admits only 1:1 local bindings", n)
        return
    end
    local name = intern_str(ctx, ctx.lists:get(ns))
    local producer = types.atom("nil") --: StaticType
    if el == 1 then producer = check_expr(ctx, ctx.lists:get(es)) end
    local ann_ty = parse_type_ann(ctx, n.line, n)
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

--: (Ctx, integer) -> nil
check_stmt = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local kind = n.kind
    consume_decl_ann(ctx, n.line)
    if kind == NODE_LOCAL_STMT then check_local(ctx, n); return end
    if kind == NODE_ASSIGN_STMT then check_assign(ctx, n); return end
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
    return { ok = #diagnostics == 0, env = env, diagnostics = diagnostics }
end

return M
