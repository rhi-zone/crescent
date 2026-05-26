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
-- Effect propagation (5.C):
--   - Effects are V5Type values whose head is a TConst named "!X"
--     (e.g. !io, !throw<E>, !yield<Y,R>).
--   - Each function scope maintains an effect accumulator (effect_stack).
--   - At each call site we extract effects from the callee's known return type
--     and propagate them into the enclosing function's accumulator.
--   - Annotated functions: per-effect CIntersectionMember(ann_ret, E) constraints
--     are emitted so S-Quiesce-CIntersectionMember surfaces missing effects (F2).
--   - Unannotated functions: collected effects are folded into the inferred
--     return type via TIntersection.
--   - pcall and coroutine.create are recognised syntactically as effect consumers.
--
-- opts.decls: optional { [string]: V5Type } table to pre-seed scope (used by
--   stdlib_types.lua to inject effectful stdlib signatures).
--
-- Residual gaps (to be addressed in 5.D and beyond):
--   - Closures-as-values intricacies (deep closure capture)
--   - Complex narrowing (discriminated unions, type guards)
--   - Method dispatch edge cases beyond simple obj:method(...)
--   - Binary / unary operator constraint emission (emits fresh uvar instead)
--   - for-in / for-num loop variable typing (binds unknown)
--   - Generic function body checking (skolemization)
--   - Type alias / require / module directives (noted but not scope-injected)
--   - Multi-return tuple types (uses union as approximation)
--   - Effect propagation from unknown callees (uvar callee — solved post-gen)

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
--: V5Type
local T_STRING = types_mod.const("string")
--: V5Type
local T_LIT_TRUE = types_mod.const("true")
--: V5Type
local T_LIT_FALSE = types_mod.const("false")
--: V5Type
local T_COROUTINE = types_mod.const("Coroutine")

--:: RawAnn = { kind: integer, content: string, col: integer, ... }

-- Typed directive shapes used when processing --:: declare directives.
-- .type is unknown in ann.lua's V5Directive (cross-file V5Type is unavailable
-- there); we use unknown here too and extract V5Type via a narrowing helper.
--:: DeclVarDir    = { kind: string, name: string, type: unknown, ... }
--:: DeclEffDir    = { kind: string, name: string, arity: number, ... }

-- Narrow an `unknown` value that is a V5Type at runtime (has a .tag field).
-- Returns the value as V5Type if it is a non-nil table with a string .tag.
-- This is the approved narrowing pattern for unknown -> concrete type.
--: (unknown) -> V5Type | nil
local function as_v5type(v)
    if type(v) ~= "table" then return nil end
    --: { tag: unknown, ... }
    local t = v
    local tg = t.tag
    if type(tg) ~= "string" then return nil end
    --: V5Type
    local ty = v
    return ty
end

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
--::   effect_stack: unknown[],
--::   ann_ret_stack: unknown[],
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

--: (V5Ctx, integer, integer) -> Provenance
local function prov_inferred(ctx, line, col)
    return C.prov(ctx.filename, line, col, "inferred")
end

--: (V5Ctx, integer, integer) -> Provenance
local function prov_declared(ctx, line, col)
    return C.prov(ctx.filename, line, col, "declared")
end

-- ── Emit helper ───────────────────────────────────────────────────────────────

--: (V5Ctx, V5Constraint) -> nil
local function emit(ctx, constraint)
    ctx.constraints[#ctx.constraints + 1] = constraint
end

-- ── Effect helpers ────────────────────────────────────────────────────────────

-- extract_effects: given a V5Type (typically a callee's return type), return
-- all effect components — parts of a TIntersection (or the type itself) that
-- are effect-headed (TConst "!X" or TApp chain headed by one).
--: (V5Type) -> V5Type[]
local function extract_effects(ty)
    local out = {} --[[: V5Type[] ]]
    if ty.tag == "intersection" then
        local parts = ty.parts
        for i = 1, #parts do
            local p = parts[i]
            if p ~= nil and types_mod.is_effect(p) then
                out[#out + 1] = p
            end
        end
    elseif types_mod.is_effect(ty) then
        out[1] = ty
    end
    return out
end

-- Return the first return type of an arrow (field "1" of its ret record), or nil.
--: (V5Type) -> V5Type | nil
local function arrow_ret1(ty)
    if ty.tag ~= "arrow" then return nil end
    local ret = ty.ret
    if ret == nil then return nil end
    if ret.tag ~= "record" then return nil end
    return ret.fields["1"]
end

-- ── pcall discriminated-union builder ────────────────────────────────────────
--
-- Gap #2 (5.F2): pcall returns (true, R...) | (false, E) where E is extracted
-- from !throw<E> in the first argument's effect intersection.  This cannot be
-- expressed declaratively in the v5 stdlib (no match types); the gen-pass
-- special-cases it here.
--
-- Given the callee arrow type of pcall's first argument:
--   - Harvest positional return fields "1", "2", ... from arrow.ret
--   - Extract !throw<E> from arrow.ret's effect components; E defaults to string
--   - Build: union([{ "1"=true, "2"=R1, ... }, { "1"=false, "2"=E }])
--
-- When fn_ty is nil (uvar callee — function passed in, not a literal), fall back
-- to union([{ "1"=true }, { "1"=false, "2"=string }]) — loose but safe.
--
-- Returns: (pcall_ret_ty, non_throw_effects) so the caller can propagate non-!throw
-- effects from the inner function (e.g. !io inside pcall still propagates).
--: (V5Type | nil) -> (V5Type, V5Type[])
local function build_pcall_ret(fn_ty)
    --: V5Type
    local T_LIT_T = T_LIT_TRUE
    --: V5Type
    local T_LIT_F = T_LIT_FALSE
    --: V5Type
    local T_STR   = T_STRING

    -- Collect non-throw effects to propagate outward.
    --: V5Type[]
    local non_throw_effs = {}

    -- Harvest positional returns + !throw<E> from the inner arrow.
    --: V5Type[]
    local inner_rets = {}    -- R1, R2, ... from arg arrow
    --: V5Type
    local throw_err_ty = T_STR  -- E in !throw<E>; default = string

    if fn_ty ~= nil and fn_ty.tag == "arrow" then
        -- Walk positional return fields.
        local ret_rec = fn_ty.ret
        if ret_rec ~= nil and ret_rec.tag == "record" then
            local i = 1
            while true do
                local rv = ret_rec.fields[tostring(i)]
                if rv == nil then break end
                -- Extract non-effect return fields as positional returns.
                if not types_mod.is_effect(rv) then
                    inner_rets[#inner_rets + 1] = rv
                else
                    -- Effect in the return intersection — harvest !throw<E>.
                    local head = rv
                    while head.tag == "app" do head = head.f end
                    if head.tag == "const" and head.name == "!throw" then
                        -- E is the first App argument: App(!throw, E).a = E.
                        if rv.tag == "app" then
                            --: V5Type
                            local ev = rv.a
                            throw_err_ty = ev
                        end
                        -- !throw is consumed — do NOT add to non_throw_effs.
                    else
                        -- Non-!throw effect: propagate outward from pcall.
                        non_throw_effs[#non_throw_effs + 1] = rv
                    end
                end
                i = i + 1
            end
            -- Also scan a top-level intersection (arrow ret field "1" = nil & !throw & !io).
            local ret1 = ret_rec.fields["1"]
            if ret1 ~= nil and ret1.tag == "intersection" then
                -- Re-run on intersection parts; clear inner_rets accumulated above.
                inner_rets = {}
                local parts = ret1.parts
                for pi = 1, #parts do
                    local p = parts[pi]
                    if p ~= nil then
                        if not types_mod.is_effect(p) then
                            inner_rets[#inner_rets + 1] = p
                        else
                            local head = p
                            while head.tag == "app" do head = head.f end
                            if head.tag == "const" and head.name == "!throw" then
                                if p.tag == "app" then
                                    --: V5Type
                                    local ev2 = p.a
                                    throw_err_ty = ev2
                                end
                                -- consumed
                            else
                                non_throw_effs[#non_throw_effs + 1] = p
                            end
                        end
                    end
                end
            end
        end
    end

    -- Build true-branch record: { "1"=true, "2"=R1, "3"=R2, ... }
    -- Use tostring(n) rather than literal "1"/"2" to avoid the typechecker
    -- treating string-literal numeric keys as positional record fields.
    local true_fields = {} --[[: { [string]: V5Type } ]]
    true_fields[tostring(1)] = T_LIT_T
    for i = 1, #inner_rets do
        local r = inner_rets[i]
        if r ~= nil then true_fields[tostring(i + 1)] = r end
    end
    --: V5Type
    local true_branch = types_mod.record(true_fields)

    -- Build false-branch record: { "1"=false, "2"=E }
    local false_fields = {} --[[: { [string]: V5Type } ]]
    false_fields[tostring(1)] = T_LIT_F
    false_fields[tostring(2)] = throw_err_ty
    --: V5Type
    local false_branch = types_mod.record(false_fields)

    --: V5Type[]
    local branches = {}
    branches[1] = true_branch
    branches[2] = false_branch
    --: V5Type
    local union_ty = types_mod.union(branches)
    return union_ty, non_throw_effs
end

-- ── coroutine.create Coroutine<Y,S,R> builder ────────────────────────────────
--
-- Gap #3 (5.F3): coroutine.create returns Coroutine<Y, S, R> where Y and R are
-- extracted from !yield<Y, R> in the argument function's effect intersection.
-- S is a fresh uvar because the argument function body cannot determine what
-- coroutine.resume passes back.
--
-- !yield<Y, R> is encoded as App(App(Const("!yield"), Y), R):
--   effect_apply(effect("yield"), {Y, R})
--   = App(App(Const("!yield"), Y), R)
-- Unwrap: eff.f.a = Y (inner App's argument), eff.a = R (outer App's argument).
--
-- When !yield is absent or fn_ty is non-arrow, fall back to
-- App(App(App(Coroutine, unknown), unknown), unknown).
--
-- Returns: (coro_ty, non_yield_effects)
--: (V5Ctx, V5Type | nil) -> (V5Type, V5Type[])
local function build_coroutine_create_ret(ctx, fn_ty)
    --: V5Type
    local fallback_y = T_UNKNOWN
    --: V5Type
    local fallback_r = T_UNKNOWN
    --: V5Type[]
    local non_yield_effs = {}

    --: V5Type
    local yield_y = fallback_y
    --: V5Type
    local yield_r = fallback_r
    local found_yield = false

    if fn_ty ~= nil and fn_ty.tag == "arrow" then
        local ret_rec = fn_ty.ret
        if ret_rec ~= nil and ret_rec.tag == "record" then
            -- Scan all positional return fields for effects.
            local i = 1
            while true do
                local rv = ret_rec.fields[tostring(i)]
                if rv == nil then break end
                if types_mod.is_effect(rv) then
                    -- Walk to the effect head.
                    local head = rv
                    while head.tag == "app" do head = head.f end
                    if head.tag == "const" and head.name == "!yield" then
                        -- !yield<Y,R> = App(App(Const("!yield"), Y), R)
                        -- rv.f = App(Const("!yield"), Y), rv.a = R
                        -- rv.f.a = Y
                        if rv.tag == "app" and rv.f ~= nil and rv.f.tag == "app" then
                            --: V5Type
                            local y_ty = rv.f.a
                            --: V5Type
                            local r_ty = rv.a
                            yield_y = y_ty
                            yield_r = r_ty
                            found_yield = true
                        end
                        -- !yield is consumed — do NOT add to non_yield_effs.
                    else
                        non_yield_effs[#non_yield_effs + 1] = rv
                    end
                end
                i = i + 1
            end
            -- Also check a top-level intersection in field "1".
            if not found_yield then
                local ret1 = ret_rec.fields["1"]
                if ret1 ~= nil and ret1.tag == "intersection" then
                    local parts = ret1.parts
                    non_yield_effs = {}
                    for pi = 1, #parts do
                        local p = parts[pi]
                        if p ~= nil and types_mod.is_effect(p) then
                            local head = p
                            while head.tag == "app" do head = head.f end
                            if head.tag == "const" and head.name == "!yield" then
                                if p.tag == "app" and p.f ~= nil and p.f.tag == "app" then
                                    --: V5Type
                                    local y_ty2 = p.f.a
                                    --: V5Type
                                    local r_ty2 = p.a
                                    yield_y = y_ty2
                                    yield_r = r_ty2
                                    found_yield = true
                                end
                            else
                                non_yield_effs[#non_yield_effs + 1] = p
                            end
                        end
                    end
                end
            end
        end
    end

    -- S is always a fresh uvar: the argument function body cannot determine
    -- what coroutine.resume will pass back.
    --: V5Type
    local s_uvar = fresh_uvar(ctx)

    -- Build App(App(App(Coroutine, Y), S), R) step by step to let the checker
    -- track each intermediate V5Type without seeing nil from complex nesting.
    --: V5Type
    local app1 = types_mod.app(T_COROUTINE, yield_y)
    --: V5Type
    local app2 = types_mod.app(app1, s_uvar)
    --: V5Type
    local coro_ty = types_mod.app(app2, yield_r)
    return coro_ty, non_yield_effs
end

-- ── extract_yield_from_ann_ret ─────────────────────────────────────────────────
--
-- Search the innermost annotated return types for a !yield<Y,R> component.
-- ann_ret_stack entries are V5Type | nil; for an annotated function whose
-- return is "nil & !yield<Y,R>", ann_ret = intersection([nil, App(App(!yield,Y),R)]).
-- Returns (Y, S_fresh, R) if found; (unknown, fresh_uvar, unknown) as fallback.
-- S is always a fresh uvar (not in the annotation; resume binds it).
--: (V5Ctx) -> (V5Type, V5Type, V5Type)
local function extract_yield_from_scope(ctx)
    local ar = ctx.ann_ret_stack
    -- Search from innermost outward.
    for depth = #ar, 1, -1 do
        --: unknown
        local slot = ar[depth]
        --: V5Type | nil
        local ann_ret = as_v5type(slot)
        if ann_ret ~= nil then
            -- ann_ret may be an intersection containing !yield<Y,R>.
            --: V5Type[]
            local parts = {}
            if ann_ret.tag == "intersection" then
                parts = ann_ret.parts
            else
                parts[1] = ann_ret
            end
            for i = 1, #parts do
                local p = parts[i]
                if p ~= nil and types_mod.is_effect(p) then
                    local head = p
                    while head.tag == "app" do head = head.f end
                    if head.tag == "const" and head.name == "!yield" then
                        if p.tag == "app" and p.f ~= nil and p.f.tag == "app" then
                            --: V5Type
                            local y_ty = p.f.a
                            --: V5Type
                            local r_ty = p.a
                            --: V5Type
                            local s_uvar = fresh_uvar(ctx)
                            return y_ty, s_uvar, r_ty
                        end
                    end
                end
            end
        end
    end
    -- Not found: return unknowns + fresh uvar.
    --: V5Type
    local s_uvar = fresh_uvar(ctx)
    return T_UNKNOWN, s_uvar, T_UNKNOWN
end

-- ── Effect scope helpers ──────────────────────────────────────────────────────

-- Push a new (empty) effect accumulator and annotated-return slot.
-- ann_ret is the annotated return type of the function being entered (nil if
-- unannotated).
--: (V5Ctx, V5Type | nil) -> nil
local function push_effect_scope(ctx, ann_ret)
    local es = ctx.effect_stack
    es[#es + 1] = {} --[[: V5Type[] ]]
    local ar = ctx.ann_ret_stack
    ar[#ar + 1] = ann_ret
end

-- Pop the top effect accumulator and annotated-return slot.
-- Returns (effects, ann_ret).
--: (V5Ctx) -> (V5Type[], V5Type | nil)
local function pop_effect_scope(ctx)
    local es = ctx.effect_stack
    local n = #es
    --: V5Type[]
    local effs = es[n] or {}
    es[n] = nil
    local ar = ctx.ann_ret_stack
    --: V5Type | nil
    local ann_ret = ar[n]
    ar[n] = nil
    return effs, ann_ret
end

-- Accumulate an effect into the current (innermost) function's effect scope.
-- If the enclosing function is annotated: emit CIntersectionMember(ann_ret, eff)
-- for F2 enforcement (S-Quiesce-CIntersectionMember surfaces missing effects).
-- If unannotated: record effect in the accumulator for later intersection-folding.
--: (V5Ctx, V5Type, integer, integer) -> nil
local function propagate_effect(ctx, eff, line, col)
    local es = ctx.effect_stack
    local depth = #es
    if depth == 0 then return end
    --: V5Type[]
    local acc = es[depth]
    if acc == nil then return end
    local ar = ctx.ann_ret_stack
    --: V5Type | nil
    local ann_ret = ar[depth]
    if ann_ret ~= nil then
        -- Annotated: emit membership constraint (F2 enforcement).
        emit(ctx, C.intersection_member(ann_ret, eff, prov_declared(ctx, line, col)))
    else
        -- Unannotated: accumulate, deduplicating by structural key.
        local eff_key = C.key_of(eff)
        local found = false
        for i = 1, #acc do
            local e = acc[i]
            if e ~= nil and C.key_of(e) == eff_key then found = true; break end
        end
        if not found then acc[#acc + 1] = eff end
    end
end

-- Propagate all effect components found in a callee's known return type into
-- the current function scope.  If callee_ty is not an arrow (e.g. still a
-- uvar), nothing can be extracted — this is the known residual gap for uvar
-- callees (effects from unknown callees remain untracked until solve time).
--: (V5Ctx, V5Type, integer, integer) -> nil
local function propagate_callee_effects(ctx, callee_ty, line, col)
    local ret1 = arrow_ret1(callee_ty)
    if ret1 == nil then return end
    local effs = extract_effects(ret1)
    for i = 1, #effs do
        local e = effs[i]
        if e ~= nil then propagate_effect(ctx, e, line, col) end
    end
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

--: (V5Ctx, integer) -> V5Directive | nil
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

-- ── Eager dotted-callee resolution ────────────────────────────────────────────
--
-- For a callee expression that is a NODE_FIELD_EXPR chain (e.g. io.write,
-- coroutine.create, a.b.c.fn), walk the chain via record-field lookups through
-- ctx.scope.  If every step resolves to a concrete TRecord field and the final
-- type is an arrow, return it directly so propagate_callee_effects can extract
-- effects at gen time rather than post-solve.
--
-- Returns nil if:
--   - the chain root is not a NODE_IDENTIFIER
--   - the root name is not in scope
--   - any intermediate or final lookup misses a field or hits an open row
--   - the final resolved type is not an arrow
--
-- When a non-nil type is returned, the caller MUST NOT also call gen_expr on
-- the callee node — that would double-emit row_extend constraints.  The caller
-- is responsible for emitting the CSub against the resolved arrow instead.
--
--: (V5Ctx, integer) -> V5Type | nil
local function resolve_callee_eager(ctx, nid)
    -- Collect the field access chain: for io.write we get path = {"write"},
    -- root_nid = <io identifier node>.
    -- Walk the chain bottom-up: each NODE_FIELD_EXPR has data[0]=object, data[1]=field.
    --: { [integer]: string }
    local path = {}
    local cur_nid = nid
    while true do
        local cur_n = ctx.nodes:get(cur_nid)
        if cur_n.kind == NODE_IDENTIFIER then
            -- Reached root.
            break
        elseif cur_n.kind == NODE_FIELD_EXPR then
            -- Prepend field name (we walk inside-out, so reverse at end).
            local field_str = intern_str(ctx, cur_n.data[1])
            path[#path + 1] = field_str
            cur_nid = cur_n.data[0]
        else
            -- Non-identifier, non-field node — can't eager-resolve.
            return nil
        end
    end

    -- cur_nid is now a NODE_IDENTIFIER.
    local root_n = ctx.nodes:get(cur_nid)
    local root_name = intern_str(ctx, root_n.data[0])
    local root_ty = lookup(ctx, root_name)
    if root_ty == nil then return nil end

    -- Reverse path so index 1 is the outermost field (the one applied first).
    -- path was accumulated inner-to-outer: io.write yields path = {"write"} with
    -- root = "io".  Reversing gives {"write"} (single step, already correct for
    -- one-level chains).  For a.b.c: accumulated as {"c","b"}, reversed to {"b","c"}.
    local n = #path
    for i = 1, math.floor(n / 2) do
        local j = n - i + 1
        local tmp = path[i]
        path[i] = path[j]
        path[j] = tmp
    end

    -- Walk the path through record fields.
    --: V5Type
    local ty = root_ty
    for i = 1, n do
        if ty.tag ~= "record" then return nil end
        -- Open records (row ~= nil) have unknown extra fields — bail to be safe.
        if ty.row ~= nil then return nil end
        --: { [string]: V5Type }
        local fields = ty.fields
        local field_name = path[i]
        if field_name == nil then return nil end
        local next_ty = fields[field_name]
        if next_ty == nil then return nil end
        ty = next_ty
    end

    -- Final type must be a concrete arrow for effect extraction to work.
    if ty.tag ~= "arrow" then return nil end
    return ty
end

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
        emit(ctx, C.row_extend(obj_ty, key_str, result, prov_inferred(ctx, n.line, n.col)))
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
        local callee_node = ctx.nodes:get(n.data[0])
        local arg_types = {} --[[: V5Type[] ]]
        local es = n.data[1]
        local el = n.data[2]
        for i = es, es + el - 1 do
            local anid = ctx.lists:get(i)
            arg_types[#arg_types + 1] = gen_expr(ctx, anid)
        end

        -- Detect syntactic special cases for effect handlers.
        -- pcall(fn, ...) — consumes !throw<E> from fn's effects.
        -- coroutine.create(fn) — consumes !yield from fn's effects.
        -- coroutine.resume(co, ...) — discriminated return from Coroutine<Y,S,R>.
        -- coroutine.yield(...) — typechecks against enclosing !yield annotation.
        local is_pcall          = false
        local is_coro_create    = false
        local is_coro_resume    = false
        local is_coro_yield     = false
        if callee_node.kind == NODE_IDENTIFIER then
            local cname = intern_str(ctx, callee_node.data[0])
            if cname == "pcall" then is_pcall = true end
        elseif callee_node.kind == NODE_FIELD_EXPR then
            local obj_node = ctx.nodes:get(callee_node.data[0])
            if obj_node.kind == NODE_IDENTIFIER then
                local oname = intern_str(ctx, obj_node.data[0])
                local fname = intern_str(ctx, callee_node.data[1])
                if oname == "coroutine" then
                    if fname == "create" then
                        is_coro_create = true
                    elseif fname == "resume" then
                        is_coro_resume = true
                    elseif fname == "yield" then
                        is_coro_yield = true
                    end
                end
            end
        end

        -- 5.F2: pcall is special-cased entirely: we skip the normal callee_ty
        -- lookup and CSub so the stdlib pcall arrow's return type does not
        -- conflict with the discriminated union we build directly (gap #2).
        if is_pcall then
            -- Inspect first arg's arrow type to build (true,R...) | (false,E).
            -- Fall back to loose union when the arg is a uvar (function passed in).
            --: V5Type | nil
            local first_arg_ty = arg_types[1]
            --: V5Type | nil
            local inner_arrow = nil
            if first_arg_ty ~= nil and first_arg_ty.tag == "arrow" then
                inner_arrow = first_arg_ty
            end
            local pcall_ret_ty, non_throw_effs = build_pcall_ret(inner_arrow)
            -- Propagate non-!throw effects (e.g. !io inside the pcall callback).
            for i = 1, #non_throw_effs do
                local e = non_throw_effs[i]
                if e ~= nil then propagate_effect(ctx, e, n.line, n.col) end
            end
            return pcall_ret_ty
        end

        -- 5.F3: coroutine.create is special-cased: skip the normal callee_ty
        -- lookup and CSub so the stdlib coroutine.create arrow's return type
        -- (flat thread) does not conflict with the Coroutine<Y,S,R> we build.
        if is_coro_create then
            -- Inspect first arg's arrow type to extract !yield<Y,R>.
            --: V5Type | nil
            local first_arg_ty = arg_types[1]
            --: V5Type | nil
            local inner_arrow = nil
            if first_arg_ty ~= nil and first_arg_ty.tag == "arrow" then
                inner_arrow = first_arg_ty
            end
            local coro_ty, non_yield_effs = build_coroutine_create_ret(ctx, inner_arrow)
            -- Propagate non-!yield effects from the coroutine body outward.
            for i = 1, #non_yield_effs do
                local e = non_yield_effs[i]
                if e ~= nil then propagate_effect(ctx, e, n.line, n.col) end
            end
            return coro_ty
        end

        -- 5.F3: coroutine.resume is special-cased: inspect co's type.
        -- If co is Coroutine<Y,S,R>, return (true,Y) | (true,R) | (false,string).
        -- S is subtyped against the second arg (resume sends it to yield).
        if is_coro_resume then
            --: V5Type | nil
            local co_ty = arg_types[1]
            --: V5Type | nil
            local send_ty = arg_types[2]
            -- Attempt to decompose App(App(App(Coroutine, Y), S), R).
            if co_ty ~= nil and co_ty.tag == "app"
                and co_ty.f ~= nil and co_ty.f.tag == "app"
                and co_ty.f.f ~= nil and co_ty.f.f.tag == "app"
                and co_ty.f.f.f ~= nil and co_ty.f.f.f.tag == "const"
                and co_ty.f.f.f.name == "Coroutine" then
                -- co_ty = App(App(App(Coroutine, Y), S), R)
                -- co_ty.f.f.a = Y, co_ty.f.a = S, co_ty.a = R
                --: V5Type
                local y_ty = co_ty.f.f.a
                --: V5Type
                local s_ty = co_ty.f.a
                --: V5Type
                local r_ty = co_ty.a
                -- Subtype send value against S (resume sends to yield).
                if send_ty ~= nil then
                    emit(ctx, C.sub(send_ty, s_ty, prov_inferred(ctx, n.line, n.col)))
                end
                -- Build (true,Y) | (true,R) | (false,string).
                local tf1 = {} --[[: { [string]: V5Type } ]]
                tf1[tostring(1)] = T_LIT_TRUE
                tf1[tostring(2)] = y_ty
                --: V5Type
                local tb1 = types_mod.record(tf1)
                local tf2 = {} --[[: { [string]: V5Type } ]]
                tf2[tostring(1)] = T_LIT_TRUE
                tf2[tostring(2)] = r_ty
                --: V5Type
                local tb2 = types_mod.record(tf2)
                local ff  = {} --[[: { [string]: V5Type } ]]
                ff[tostring(1)]  = T_LIT_FALSE
                ff[tostring(2)]  = T_STRING
                --: V5Type
                local fb = types_mod.record(ff)
                --: V5Type[]
                local branches = {}
                branches[1] = tb1
                branches[2] = tb2
                branches[3] = fb
                return types_mod.union(branches)
            else
                -- Fallback: co is uvar or bare thread — return (boolean, unknown).
                local tf = {} --[[: { [string]: V5Type } ]]
                tf[tostring(1)] = T_LIT_TRUE
                --: V5Type
                local tbf = types_mod.record(tf)
                local ff = {} --[[: { [string]: V5Type } ]]
                ff[tostring(1)] = T_LIT_FALSE
                ff[tostring(2)] = T_UNKNOWN
                --: V5Type
                local fbf = types_mod.record(ff)
                --: V5Type[]
                local branches = {}
                branches[1] = tbf
                branches[2] = fbf
                return types_mod.union(branches)
            end
        end

        -- 5.F3: coroutine.yield is special-cased: look up the enclosing
        -- function's !yield<Y,R> annotation to typecheck the yielded value
        -- and return S (the type resume sends back).
        if is_coro_yield then
            --: V5Type | nil
            local yield_val_ty = arg_types[1]
            local y_ty, s_ty, _r_ty = extract_yield_from_scope(ctx)
            -- Subtype yielded value against Y.
            if yield_val_ty ~= nil then
                emit(ctx, C.sub(yield_val_ty, y_ty, prov_inferred(ctx, n.line, n.col)))
            else
                -- yield called with no argument — treat as nil yielded.
                emit(ctx, C.sub(T_NIL, y_ty, prov_inferred(ctx, n.line, n.col)))
            end
            -- !yield propagates outward: this function is a yielding function.
            -- Reconstruct !yield<Y,R> to propagate (using _r_ty from scope).
            --: V5Type[]
            local yield_args = {}
            yield_args[1] = y_ty
            yield_args[2] = _r_ty
            --: V5Type
            local yield_head = types_mod.effect("yield")
            --: V5Type
            local yield_eff = types_mod.effect_apply(yield_head, yield_args)
            propagate_effect(ctx, yield_eff, n.line, n.col)
            -- Return type of coroutine.yield is S (what resume passes back).
            return s_ty
        end

        -- Try eager resolution for dotted callees (e.g. io.write, os.exit).
        -- If the chain resolves to a concrete arrow via record-field lookup,
        -- use it directly so propagate_callee_effects can extract effects now
        -- instead of after the solver runs.  When resolution succeeds we skip
        -- gen_expr on the callee node to avoid double-emitting row_extend.
        -- When it fails (nil returned) we fall through to gen_expr as before.
        local eager_ty = resolve_callee_eager(ctx, n.data[0])
        --: V5Type
        local callee_ty = eager_ty ~= nil and eager_ty or gen_expr(ctx, n.data[0])

        local ret = fresh_uvar(ctx)
        local rets_arr = {} --[[: V5Type[] ]]
        rets_arr[1] = ret
        --: V5Type
        local expected_fn = types_mod.arrow(arg_types, rets_arr)
        emit(ctx, C.sub(callee_ty, expected_fn, prov_inferred(ctx, n.line, n.col)))

        -- Effect propagation: normal call path (coroutine special cases have
        -- already returned above; is_coro_create/resume/yield never reach here).
        propagate_callee_effects(ctx, callee_ty, n.line, n.col)

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
        local ret = fresh_uvar(ctx)

        -- Try eager resolution: look up method_str in the recv_ty record.
        -- If recv_ty is a concrete closed TRecord, we can find the method arrow
        -- directly instead of emitting a row_extend + uvar.
        -- eager_method_ty returns non-nil only if recv_ty is a closed record with
        -- a concrete arrow at method_str; nil falls back to row_extend + uvar.
        --: (V5Type, string) -> V5Type | nil
        local function eager_method_ty(rec, mstr)
            if rec.tag ~= "record" then return nil end
            if rec.row ~= nil then return nil end
            --: { [string]: V5Type }
            local rf = rec.fields
            local cm = rf[mstr]
            if cm == nil then return nil end
            if cm.tag ~= "arrow" then return nil end
            return cm
        end
        local concrete_m = eager_method_ty(recv_ty, method_str)
        --: V5Type
        local method_ty = concrete_m ~= nil and concrete_m or fresh_uvar(ctx)
        if concrete_m == nil then
            -- Fallback: emit row_extend so the solver can resolve the method type.
            emit(ctx, C.row_extend(recv_ty, method_str, method_ty, prov_inferred(ctx, n.line, n.col)))
        end

        local rets_arr = {} --[[: V5Type[] ]]
        rets_arr[1]    = ret
        --: V5Type
        local expected_fn = types_mod.arrow(arg_types, rets_arr)
        emit(ctx, C.sub(method_ty, expected_fn, prov_inferred(ctx, n.line, n.col)))
        -- Propagate effects from method's known return type (if concrete).
        -- For eager-resolved methods this now sees the real arrow.
        propagate_callee_effects(ctx, method_ty, n.line, n.col)
        return ret
    end

    -- ── Function expression: function(...) ... end ──────────────────────────
    if kind == NODE_FUNC_EXPR then
        local has_vararg = (n.flags % (FLAG_VARARG * 2)) >= FLAG_VARARG
        local fn_ty = gen_function(ctx, n.data[0], n.data[1], n.data[2], n.data[3],
            has_vararg, nil, n.line, n.col)
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

--: (V5Ctx, integer, integer, integer, integer, boolean, V5Type | nil, integer, integer) -> V5Type
gen_function = function(ctx, ps, pl, bs, bl, has_vararg, ann_ty, line, col)
    local param_tys = {} --[[: V5Type[] ]]

    -- Unpack annotation arrow via helpers (avoids nil-narrowing loss from
    -- conditional local mutation).
    local ann_args = extract_ann_args(ann_ty)
    local ann_ret  = extract_ann_ret(ann_ty)

    push_scope(ctx)
    -- Push an effect accumulator for this function scope.
    -- We pass ann_ret so propagate_effect can decide emit-vs-accumulate.
    push_effect_scope(ctx, ann_ret)

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

    -- Pop the effect accumulator.
    local body_effects, _ = pop_effect_scope(ctx)

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
                emit(ctx, C.sub(rt, ann_ret, prov_declared(ctx, line, col)))
            end
        end
        -- For annotated functions, CIntersectionMember constraints were already
        -- emitted by propagate_effect inside the body walk.
        ret_ty = ann_ret
    elseif #return_types == 0 then
        -- No explicit returns; incorporate any accumulated effects.
        if #body_effects == 0 then
            ret_ty = T_NIL
        else
            -- Build intersection of nil + effects.
            local parts = {} --[[: V5Type[] ]]
            parts[1] = T_NIL
            for i = 1, #body_effects do
                local e = body_effects[i]
                if e ~= nil then parts[#parts + 1] = e end
            end
            --: V5Type
            local ity0 = types_mod.intersection(parts)
            ret_ty = ity0
        end
    elseif #return_types == 1 then
        local rt0 = return_types[1]
        --: V5Type
        local base = rt0 or T_NIL
        if #body_effects == 0 then
            ret_ty = base
        else
            local parts = {} --[[: V5Type[] ]]
            parts[1] = base
            for i = 1, #body_effects do
                local e = body_effects[i]
                if e ~= nil then parts[#parts + 1] = e end
            end
            --: V5Type
            local ity1 = types_mod.intersection(parts)
            ret_ty = ity1
        end
    else
        --: V5Type
        local union_ty = types_mod.union(return_types)
        if #body_effects == 0 then
            ret_ty = union_ty
        else
            local parts = {} --[[: V5Type[] ]]
            parts[1] = union_ty
            for i = 1, #body_effects do
                local e = body_effects[i]
                if e ~= nil then parts[#parts + 1] = e end
            end
            --: V5Type
            local ity2 = types_mod.intersection(parts)
            ret_ty = ity2
        end
    end

    local rets_arr = {} --[[: V5Type[] ]]
    --: V5Type
    local ret_ty_final = ret_ty
    rets_arr[1]    = ret_ty_final
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
                    emit(ctx, C.sub(rhs_ty, ann_ty, prov_declared(ctx, n.line, n.col)))
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
            has_vararg, ann_ty, n.line, n.col)

        if ann_ty ~= nil then
            emit(ctx, C.sub(fn_ty, ann_ty, prov_declared(ctx, n.line, n.col)))
        end

        local name_kind = name_n.kind
        if name_kind == NODE_IDENTIFIER then
            local name_str = intern_str(ctx, name_n.data[0])
            bind(ctx, name_str, fn_ty)
        elseif name_kind == NODE_FIELD_EXPR then
            local obj_ty  = gen_expr(ctx, name_n.data[0])
            local key_str = intern_str(ctx, name_n.data[1])
            emit(ctx, C.row_extend(obj_ty, key_str, fn_ty, prov_inferred(ctx, n.line, n.col)))
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
                    emit(ctx, C.sub(rhs_ty, existing, prov_inferred(ctx, n.line, n.col)))
                else
                    bind(ctx, name_str, rhs_ty)
                end
            elseif tk == NODE_FIELD_EXPR then
                local obj_ty  = gen_expr(ctx, tn.data[0])
                local key_str = intern_str(ctx, tn.data[1])
                emit(ctx, C.row_extend(obj_ty, key_str, rhs_ty, prov_inferred(ctx, n.line, n.col)))
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

-- Export extract_effects so tests can inspect it independently.
M.extract_effects = extract_effects

-- Generate v5 constraints from Lua source.
--
-- Parameters:
--   source   — Lua source string.
--   filename — filename for provenance (defaults to "?").
--   opts     — optional table:
--                pool?  — InternPool (performance hint; currently unused).
--                decls? — { [string]: V5Type } pre-declared scope bindings
--                         (used by stdlib_types.lua to inject effectful stdlib).
--
-- Returns:
--   constraints — flat V5Constraint array.
--   errors      — string array (parse errors, annotation errors).
--
--: (string, string | nil, { pool?: InternPool, decls?: { [string]: V5Type }, ... } | nil) -> (V5Constraint[], string[])
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
        filename      = filename,
        nodes         = pr_nodes,
        lists         = pr_lists,
        pool          = pool,
        constraints   = constraints,
        errors        = errors,
        scope         = {},
        scope_stack   = {},
        return_stack  = {},
        effect_stack  = {},
        ann_ret_stack = {},
        annotations   = raw_anns,
        _next_uvar    = 1,
    }

    -- Seed scope_stack with the top-level scope.
    ctx.scope_stack[1] = ctx.scope

    -- Inject pre-declared types from opts.decls (e.g. stdlib_types).
    if opts ~= nil then
        --: { [string]: V5Type } | nil
        local decls = opts.decls
        if decls ~= nil then
            for dname, dty in pairs(decls) do
                --: V5Type
                local dtyv = dty
                bind(ctx, dname, dtyv)
            end
        end
    end

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
                    -- Access fields common to all V5Directive members directly.
                    -- V5Directive is a union; .kind is string on all members.
                    -- .name, .type, .arity are each only present on specific
                    -- members, but reading them returns the field type or nil.
                    if dir.kind == "declare_var" then
                        -- All V5Directive union members have .name:string; the
                        -- .type field is present only on declare_var members.
                        local dv_name = dir.name
                        local dv_type = as_v5type(dir.type)
                        if dv_name ~= nil and dv_type ~= nil then
                            bind(ctx, dv_name, dv_type)
                        end
                    elseif dir.kind == "declare_effect" then
                        -- .name is string on all members; .arity is number on
                        -- declare_effect only.
                        local de_name  = dir.name
                        local de_arity = dir.arity
                        if de_name ~= nil and de_arity ~= nil then
                            ann_mod.declare_effect(de_name, de_arity)
                        end
                    end
                    -- Other kinds (type_alias, module, etc.) are residual gaps.
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
