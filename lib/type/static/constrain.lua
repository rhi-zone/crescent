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
local NODE_GOTO_STMT   = defs.NODE_GOTO_STMT
local NODE_EXPR_STMT   = defs.NODE_EXPR_STMT
local NODE_FUNC_DECL   = defs.NODE_FUNC_DECL
local NODE_CHUNK       = defs.NODE_CHUNK
local NODE_CAST_EXPR   = defs.NODE_CAST_EXPR

local LIT_STRING    = defs.LIT_STRING
local LIT_NUMBER    = defs.LIT_NUMBER
local LIT_BOOLEAN   = defs.LIT_BOOLEAN
local LIT_INTEGER   = defs.LIT_INTEGER
local LIT_NIL       = defs.LIT_NIL
local LIT_OPAQUE_KEY = defs.LIT_OPAQUE_KEY
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

local FLAG_LOCAL      = defs.FLAG_LOCAL
local FLAG_VARARG     = defs.FLAG_VARARG
local FLAG_COMPUTED   = defs.FLAG_COMPUTED
local FLAG_READONLY   = defs.FLAG_READONLY
local FLAG_OPTIONAL   = defs.FLAG_OPTIONAL
local FLAG_PRIVATE    = defs.FLAG_PRIVATE
local FLAG_OPAQUE_KEY = defs.FLAG_OPAQUE_KEY
local band            = require("bit").band
local bor             = require("bit").bor

-- Compute field flags from base_flags (boolean shorthand for FLAG_OPTIONAL is accepted).
--: (Ctx, integer, integer | nil) -> integer
local function field_flags(ctx, name_id, base_flags)
    base_flags = base_flags or 0
    if type(base_flags) == "boolean" then
        base_flags = base_flags and FLAG_OPTIONAL or 0
    end
    return base_flags
end

local ANN_TYPE   = defs.ANN_TYPE
local ANN_DECL   = defs.ANN_DECL
local ANN_MODULE = defs.ANN_MODULE
local ANN_UNSEAL  = defs.ANN_UNSEAL
local ANN_REQUIRE = defs.ANN_REQUIRE
local ANN_AUGMENT = defs.ANN_AUGMENT
local ANN_TEMPLATE = defs.ANN_TEMPLATE

local TAG_ANY      = defs.TAG_ANY
local TAG_UNKNOWN  = defs.TAG_UNKNOWN
local TAG_NIL      = defs.TAG_NIL
local TAG_BOOLEAN  = defs.TAG_BOOLEAN
local TAG_NUMBER   = defs.TAG_NUMBER
local TAG_INTEGER  = defs.TAG_INTEGER
local TAG_STRING   = defs.TAG_STRING
local TAG_LITERAL  = defs.TAG_LITERAL
local TAG_FUNCTION = defs.TAG_FUNCTION
local TAG_TABLE        = defs.TAG_TABLE
local TAG_UNION        = defs.TAG_UNION
local TAG_INTERSECTION = defs.TAG_INTERSECTION
local TAG_VAR          = defs.TAG_VAR
local TAG_ROWVAR   = defs.TAG_ROWVAR
local TAG_NAMED    = defs.TAG_NAMED
local TAG_NOMINAL  = defs.TAG_NOMINAL
local TAG_FORALL   = defs.TAG_FORALL
local TAG_TUPLE    = defs.TAG_TUPLE
local TAG_NEVER       = defs.TAG_NEVER
local TAG_ENUM_MEMBER = defs.TAG_ENUM_MEMBER
local TAG_TYPEOF      = defs.TAG_TYPEOF
local fnv31           = defs.fnv31

local E = defs.E

-- ---------------------------------------------------------------------------
-- Constraint kinds
-- ---------------------------------------------------------------------------

local C_UNIFY         = 1   -- {C_UNIFY,         t1, t2, line, col}
local C_SUB           = 2   -- {C_SUB,           actual, expected, line, col}
local C_CALLABLE      = 4   -- {C_CALLABLE,      callee_tid, arg_tids_list, ret_tid, line, col}
local C_ARITH         = 5   -- {C_ARITH,         op_str, lhs_tid, rhs_tid, result_tid, line, col}
local C_RETURN        = 6   -- {C_RETURN,        val_tid, expected_tid, line, col}
local C_COMPARE       = 7   -- {C_COMPARE,       lhs_tid, rhs_tid, line, col}
local C_INDEX         = 8   -- {C_INDEX,         obj_tid, key_tid, result_tid, line, col}
-- key_tid: TAG_LITERAL(LIT_STRING, name_id) for field; TAG_LITERAL(LIT_INTEGER, slot) for tuple slot
local C_BOUND         = 9   -- {C_BOUND,         fresh_tv_id, bound_type_id, line, col}
-- Deferred forall bound check: defers while fresh_tv is still a free TAG_VAR,
-- then checks try_unify(widen(fresh_tv), bound_type). Emitted at call sites.
local C_OR            = 10  -- {C_OR,            left_tid, right_tid, result_tid, line, col}
-- Deferred `or` expression: defers while left_tid is a free TAG_VAR,
-- then computes subtract(left, nil) | right and unifies with result_tid.
local C_BIND_GENERICS = 11  -- {C_BIND_GENERICS, callee_tid, arg_tids_list, ret_tid, line, col}
-- Binds free type variables in the callee's param slots from call arguments.
-- Runs before C_CHECK_ARGS. For <T>(x: T) -> T called with "hello", binds T=string.
-- For non-function callees (TAG_ANY/UNKNOWN/NEVER/VAR/INTERSECTION/UNION), does nothing.
local C_CHECK_ARGS    = 12  -- {C_CHECK_ARGS,    callee_tid, arg_tids_list, ret_tid, line, col}
-- Checks that call arguments match the (now-concrete) param types and unifies the return type.
-- Defers (returns false) if any param is still a free TV. No special-casing needed.
local C_OVERLAP       = 13  -- {C_OVERLAP,       actual, expected, line, col}
-- Bidirectional subtype check for force cast (`--[[:! T]] expr`). Succeeds iff
-- `actual <: expected` (widening) or `expected <: actual` (narrowing). Matches
-- TypeScript `as` semantics: the two types must share a supertype/subtype
-- relationship; disjoint types (e.g. string and integer) are rejected.
local C_NARROW_NIL    = 14  -- {C_NARROW_NIL,    input_tid, result_tid, keep_nil, line, col}
-- Deferred narrowing for nil_check.  Defers while input_tid is a free TAG_VAR;
-- once concrete, computes either subtract(input, nil|false) (keep_nil=false) or
-- the nil-only subset (keep_nil=true) and unifies with result_tid.  Emitted by
-- narrow.apply_narrowing when the input type isn't yet resolved (e.g. for-in
-- loop variables that depend on deferred C_BIND_GENERICS / C_INDEX).  Without
-- this, narrowing on an unresolved TAG_VAR is a silent no-op.

local C_HKT_DECOMPOSE = 16  -- {C_HKT_DECOMPOSE, f_fresh_tid, args_fresh_list, bound_alias_tid, actual_arg_tid, line, col}
-- Higher-kinded type decomposition at a call site. Emitted when a call-site
-- parameter slot is TAG_TYPE_CALL(F_fresh, A_fresh) and F_fresh is a fresh TV
-- with a generic-alias bound (e.g. <F: Maybe>). Bidirectional propagation:
-- when the actual argument is the structural expansion of bound_alias<A>, we
-- pattern-match the actual against the alias's body template to recover the
-- inner type arguments (binding A_fresh), and bind F_fresh := bound_alias.
-- See docs/typechecker-hkt-broader.md (Approach 2).

local C_ESCAPE_CHECK  = 15  -- {C_ESCAPE_CHECK,  ret_tid, call_id, line, col}
-- Rank-N skolem escape check. After a call site introduces per-call skolems
-- for nested forall quantifiers in the callee's parameter slots, verify that
-- no such skolem leaks into the call's return type. If a skolem with the
-- matching call_id is reachable from ret_tid, the polymorphic value escaped
-- its quantifier (unsoundness). Defers while ret_tid is a free TAG_VAR.

local M = {}

M.C_UNIFY         = C_UNIFY
M.C_SUB           = C_SUB
M.C_INDEX         = C_INDEX
M.C_CALLABLE      = C_CALLABLE
M.C_ARITH         = C_ARITH
M.C_RETURN        = C_RETURN
M.C_COMPARE       = C_COMPARE
M.C_BOUND         = C_BOUND
M.C_OR            = C_OR
M.C_BIND_GENERICS = C_BIND_GENERICS
M.C_CHECK_ARGS    = C_CHECK_ARGS
M.C_OVERLAP       = C_OVERLAP
M.C_NARROW_NIL    = C_NARROW_NIL
M.C_ESCAPE_CHECK  = C_ESCAPE_CHECK
M.C_HKT_DECOMPOSE = C_HKT_DECOMPOSE

-- Typed per-C_TAG payload aliases. Constructors and accessors land in C4-C5.
-- Each tuple's first slot is the C_TAG discriminant (an integer literal);
-- remaining slots match the constructor call sites in this file. Slot types
-- reflect what the constructors actually pass, not the comment-form summaries
-- on the C_TAG constants above (which the plan transcribed slightly off for
-- C_SUB, C_NARROW_NIL, and the *_GENERICS / CHECK_ARGS / CALLABLE arg-list
-- slot — see commit body).
--:: ConstraintUnify        = { integer, integer, integer, integer, integer }
--:: ConstraintSub          = { integer, integer, integer, integer, integer, boolean }
--:: ConstraintCallable     = { integer, integer, { [integer]: integer, ... }, integer, integer, integer }
--:: ConstraintArith        = { integer, string,  integer, integer, integer, integer, integer }
--:: ConstraintReturn       = { integer, integer, integer, integer, integer }
--:: ConstraintCompare      = { integer, integer, integer, integer, integer }
--:: ConstraintIndex        = { integer, integer, integer, integer, integer, integer }
--:: ConstraintBound        = { integer, integer, integer, integer, integer }
--:: ConstraintOr           = { integer, integer, integer, integer, integer, integer }
--:: ConstraintBindGenerics = { integer, integer, { [integer]: integer, ... }, integer, integer, integer }
--:: ConstraintCheckArgs    = { integer, integer, { [integer]: integer, ... }, integer, integer, integer }
--:: ConstraintOverlap      = { integer, integer, integer, integer, integer }
--:: ConstraintNarrowNil    = { integer, integer, integer, boolean, integer, integer }
--:: ConstraintEscapeCheck  = { integer, integer, integer, integer, integer }

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--: (Ctx, integer | nil, integer | nil, integer, { [string]: unknown, ... }) -> DiagEntry
local function report(ctx, line, col, code, args)
    local msg = errors_mod.format_diag(code, args --[[:! { [string]: string | integer }]])
    return errors_mod.error(ctx.err, ctx.filename, line or 0, col or 0, msg)
end

--: (Ctx, integer | nil, integer | nil, integer, { [string]: unknown, ... }) -> ()
local function warn(ctx, line, col, code, args)
    --: { [string]: { severity?: string, enabled?: boolean, allow?: { [integer]: string, ... }, ... }, ... } | nil
    local rc = ctx.rules_config --[[:! { [string]: { severity?: string, enabled?: boolean, allow?: { [integer]: string, ... }, ... }, ... } | nil]]
    --: { [integer]: { name: string, severity: string }, ... }
    local rd = defs.rule_defaults --[[:! { [integer]: { name: string, severity: string }, ... }]]
    if rd[code] then
        local rc_mod = require("lib.type.static.rules_config")
        local sev = rc_mod.effective_severity(code, rc, rd)
        if sev == "off" then return end
        local allow = rc_mod.allow_patterns(code, rc, rd)
        if rc_mod.is_allowed(ctx.filename, allow) then return end
        local msg = errors_mod.format_diag(code, args --[[:! { [string]: string | integer }]])
        if sev == "error" then
            errors_mod.error(ctx.err, ctx.filename, line or 0, col or 0, msg)
        else
            errors_mod.warning(ctx.err, ctx.filename, line or 0, col or 0, msg)
        end
        return
    end
    local msg = errors_mod.format_diag(code, args --[[:! { [string]: string | integer }]])
    errors_mod.warning(ctx.err, ctx.filename, line or 0, col or 0, msg)
end

--: (Ctx, { [integer]: unknown, ... }) -> ()
local function emit(ctx, constraint)
    ctx.constraints[#ctx.constraints + 1] = constraint
end

-- HM Phase 2: record polymorphic-rooted body ops keyed by template TV.
-- Inline record at op-emit time is a no-op for HM-inferred params: at body
-- emission time `_forall_bounds` is empty (bounds populated by sub_solve via
-- emit_field_bound / emit_meta_bound). The real recording runs in
-- record_polymorphic_ops_post (called after sub_solve), which scans the body
-- constraint range and walks each operand TV back to its root template TV via
-- the bound's structure. See `collect_bound_tvs` below.
--: (Ctx, { [integer]: unknown, ... }) -> ()
local function record_polymorphic_op(ctx, c)
    -- Kept for potential explicit-forall fast path; the post-pass is the
    -- source of truth for HM-inferred bounds. No-op for now.
    local _, _ = ctx, c
end

-- Walk a type's structure collecting every TAG_VAR / TAG_ROWVAR id reachable
-- inside it. Used to (1) generalize TVs hiding inside _forall_bounds[T] so
-- env.instantiate mints fresh copies for them at call sites, and (2) build
-- the operand→root_T reverse index for record_polymorphic_ops_post.
--
-- SELF-CHECK BASELINE NOTE (HM Phase 2, +11 errors here):
-- Every `t.data[N]` access below (lines ~244-275) reports as `unknown` /
-- wide-union arithmetic from the typechecker. This is the same pre-existing
-- baseline limitation as in env.lua (~120 instances) and types.lua: the
-- `t.data` slot is a fixed-shape integer-keyed sub-record but the
-- typechecker models it as a homogeneous indexer. Annotating these as
-- integers would require a typechecker-level feature (per-tag struct-field
-- typing for arena entries) — not a force-cast fix. Do NOT paper over
-- with `--[[:! integer]]`: that hides the same defect everywhere it is
-- already known to exist. Resolved when the typechecker gains positional /
-- per-tag typing for arena `data` slots.
--
-- The single force cast at the bottom of `record_polymorphic_ops_post`
-- (`val --[[:! integer]]`) is also baseline: `c` is typed
-- `{ [integer]: unknown, ... }` (constraint arrays are intentionally
-- heterogeneous; see ctx_types.lua line 187). After `type(val) == "number"`
-- narrowing, `unknown` becomes `number`; casting `number → integer` would
-- be unsound in general (the cast is sound here because constraint TIDs
-- are always integers). Removing it would require typing constraint
-- arrays as a discriminated union per code, a significant ctx_types.lua
-- refactor.
--: (Ctx, integer, { [integer]: boolean, ... }, { [integer]: boolean, ... }) -> ()
local function collect_bound_tvs(ctx, tid, out, seen)
    tid = types_mod.find(ctx, tid)
    if seen[tid] then return end
    seen[tid] = true
    local t = ctx.types:get(tid)
    local tag = t.tag
    if tag == TAG_VAR or tag == TAG_ROWVAR then
        out[tid] = true
        return
    end
    if tag == TAG_FUNCTION then
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            collect_bound_tvs(ctx, ctx.lists:get(i), out, seen)
        end
        for i = t.data[2], t.data[2] + t.data[3] - 1 do
            collect_bound_tvs(ctx, ctx.lists:get(i), out, seen)
        end
        if t.data[4] >= 0 then collect_bound_tvs(ctx, t.data[4], out, seen) end
        return
    end
    if tag == TAG_TABLE then
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            local fe = ctx.fields:get(ctx.lists:get(i))
            collect_bound_tvs(ctx, fe.type_id, out, seen)
        end
        for i = t.data[2], t.data[2] + t.data[3] - 1 do
            collect_bound_tvs(ctx, ctx.lists:get(i), out, seen)
        end
        if t.data[4] >= 0 then collect_bound_tvs(ctx, t.data[4], out, seen) end
        for j = t.data[5], t.data[5] + t.data[6] - 1 do
            local fe = ctx.fields:get(ctx.lists:get(j))
            collect_bound_tvs(ctx, fe.type_id, out, seen)
        end
        return
    end
    if tag == TAG_UNION or tag == TAG_INTERSECTION or tag == TAG_TUPLE then
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            collect_bound_tvs(ctx, ctx.lists:get(i), out, seen)
        end
        return
    end
    if tag == defs.TAG_SPREAD then
        collect_bound_tvs(ctx, t.data[0], out, seen)
        return
    end
end

-- HM Phase 2 post-pass: after sub_solve has populated `_forall_bounds` for
-- the function's generalized params, walk body constraints in [body_start+1,
-- body_end] and record each polymorphic-rooted op into `_forall_ops[T]` for
-- the root template TV T whose bound contains the operand. Also generalizes
-- TVs hiding inside each bound so call-site instantiation refreshes them.
--: (Ctx, { [integer]: integer, ... }, integer, integer) -> ()
local function record_polymorphic_ops_post(ctx, param_tids, body_start, body_end)
    local fb = ctx._forall_bounds
    if not fb then return end
    -- Collect TVs of each generalized param's bound and reverse-index
    -- bound_tv → root_template_tv. Also generalize collected TVs so
    -- env.instantiate populates inst_mapping for them at call sites.
    local tv_to_root = {}  --: { [integer]: integer, ... }
    for _, ptid in ipairs(param_tids) do
        local root = types_mod.find(ctx, ptid)
        local pt = ctx.types:get(root)
        if pt.tag == TAG_VAR and pt.flags == defs.FLAG_GENERIC then
            local bound = fb[root]
            if bound then
                local tvs = {}
                collect_bound_tvs(ctx, bound, tvs, {})
                for tv in pairs(tvs) do
                    if tv ~= root then
                        local tvt = ctx.types:get(tv)
                        if (tvt.tag == TAG_VAR or tvt.tag == TAG_ROWVAR)
                            and tvt.flags ~= defs.FLAG_GENERIC then
                            tvt.flags = defs.FLAG_GENERIC
                        end
                    end
                    -- index every TV (including root) so operand=root case is recorded too
                    if not tv_to_root[tv] then tv_to_root[tv] = root end
                end
            end
        end
    end
    if not next(tv_to_root) then return end
    -- Walk body constraints; record arith/compare/index/callable ops keyed
    -- by root template TV. Each constraint kind has a different operand-TID
    -- layout; describe per-kind index lists. C_CALLABLE's arg_tids slot is
    -- a Lua array, not an inline TID — handled as a special case.
    local cs = ctx.constraints
    --: { [integer]: { [integer]: integer, ... }, ... }
    local OPERAND_INDICES = {
        [C_ARITH]         = { 3, 4, 5 },  -- {_, op, lhs, rhs, res, line, col}
        [C_COMPARE]       = { 2, 3 },     -- {_, lhs, rhs, line, col}
        -- C_BIND_GENERICS / C_CHECK_ARGS: {_, callee_tid, arg_tids_list, ret_tid, line, col}
        -- The arg_tids slot at index 3 is a Lua array of TIDs, not a TID;
        -- handled as a special case below (treated as additional operands).
        [C_BIND_GENERICS] = { 2, 4 },
        [C_CHECK_ARGS]    = { 2, 4 },
        -- C_INDEX intentionally omitted: emit_field_bound/emit_indexer_bound
        -- in solve.lua already merge open-record/indexer bounds into
        -- _forall_bounds, and call-site C_BOUND propagates field types into
        -- the inst-mapped nested TVs. Re-emitting body C_INDEX at call sites
        -- creates duplicate field bounds and breaks the merged-bound shape.
        --
        -- C_CALLABLE intentionally omitted: body-level call expressions
        -- emit C_BIND_GENERICS / C_CHECK_ARGS (handled above), not C_CALLABLE
        -- itself — C_CALLABLE only fires for for-loop iterator triples.
    }
    for i = body_start + 1, body_end do
        local c = cs[i]
        if c then
            local code = c[1]
            local indices = OPERAND_INDICES[code]
            if indices then
                local roots_seen = {}
                --: (integer | nil) -> ()
                local function check_tid(tid)
                    if tid then
                        local resolved = types_mod.find(ctx, tid)
                        local root = tv_to_root[resolved] or tv_to_root[tid]
                        if root and not roots_seen[root] then
                            roots_seen[root] = true
                            local bucket = ctx._forall_ops[root]
                            if not bucket then
                                bucket = {}
                                ctx._forall_ops[root] = bucket
                            end
                            local clone = {}
                            for k, v in ipairs(c) do
                                if type(v) == "table" then
                                    -- shallow-copy operand list (e.g. arg_tids)
                                    local list = {}
                                    for kk, vv in ipairs(v --[[: { [integer]: integer, ... }]]) do list[kk] = vv end
                                    clone[k] = list
                                else
                                    clone[k] = v
                                end
                            end
                            bucket[#bucket + 1] = clone
                        end
                    end
                end
                for _, idx in ipairs(indices) do
                    local val = c[idx]
                    if type(val) == "number" then
                        check_tid(val --[[:! integer]])
                    elseif type(val) == "table" then
                        for _, tid in ipairs(val --[[: { [integer]: integer, ... }]]) do
                            check_tid(tid)
                        end
                    end
                end
            end
        end
    end
end

--: (Ctx) -> integer
local function fresh_var(ctx)
    return types_mod.make_var(ctx, ctx.scope.level)
end

-- ---------------------------------------------------------------------------
-- Annotation resolution (copied from infer.lua — identical semantics needed)
-- ---------------------------------------------------------------------------

local resolve_annotation_type

--: (Ctx, integer, { [integer]: boolean, ... } | nil) -> integer
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
        if ctx._ann_warn_line ~= 0 then
            warn(ctx, ctx._ann_warn_line, 0, E.EXPLICIT_ANY, {})
            ctx._ann_warn_line = 0
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
    if tag == defs.TAG_FFIC then
        -- $FfiC is a magic type: the live ffi.C table for this compilation unit.
        -- It is kept as TAG_FFIC in the checker's type arena so that solve.lua
        -- can substitute ctx.T_FFI_C dynamically at the time of field access.
        -- This avoids capturing a stale (or nil) T_FFI_C during stdlib_types.lua loading.
        return types_mod.alloc_type(ctx, defs.TAG_FFIC)
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

    if tag == TAG_TYPEOF then
        local name_id = at.data[0]
        local tid = env_mod.lookup(ctx.scope, name_id)
        if not tid then
            local intern_local = require("lib.type.static.intern")
            local name_str = intern_local.get(ctx.pool, name_id) or "?"
            local err_line = ctx._ann_warn_line
            errors_mod.error(ctx.err, ctx.filename, err_line, 0,
                "typeof: unknown identifier `" .. name_str .. "`")
            return ctx.T_UNKNOWN
        end
        local resolved = types_mod.find(ctx, tid)
        local rt = ctx.types:get(resolved)
        if rt.tag == TAG_VAR then
            -- When resolving function signature annotations, param names are pre-bound
            -- to fresh TAG_VAR placeholders so that `typeof <param>` can reference
            -- them.  In that context we return the placeholder TAG_VAR directly —
            -- it will be bound to the concrete annotation type by the caller.
            -- Outside that context (unannotated param at a call site), return T_UNKNOWN
            -- to avoid capturing an unstable free variable.
            if ctx._resolving_func_ann_scope then
                return resolved
            end
            return ctx.T_UNKNOWN
        end
        return resolved
    end

    if tag == TAG_NAMED then
        local name_id = at.data[0]
        local args_len = at.data[2]
        --: { [integer]: integer } | nil
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
            -- Inside a match arm pattern/body, bare names that are not in scope
            -- are pattern capture variables (e.g. `A` in `{ value: A } => A`).
            -- Return a TAG_NAMED placeholder; match.evaluate will bind and substitute.
            if ctx._in_match_arm then
                local id = types_mod.alloc_type(ctx, TAG_NAMED)
                ctx.types:get(id).data[0] = name_id
                return id
            end
            local err_line = ctx._ann_warn_line
            errors_mod.error(ctx.err, ctx.filename, err_line, 0, "undefined type `" .. name_str .. "`")
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
        if resolved then
            -- If the result is a TAG_PARTIAL_APP and we are NOT in an HKT
            -- context (e.g. as an arg to an intrinsic like $EachField),
            -- emit an arity error. TAG_PARTIAL_APP in a concrete-type position
            -- is a usage error: the alias needs more type arguments.
            local rt = ctx.types:get(resolved)
            if rt.tag == defs.TAG_PARTIAL_APP and not ctx._allow_unapplied_constructors then
                local param_count = alias.params and #alias.params or 0
                local required_count = param_count
                if alias.resolved_defaults then
                    for i = param_count, 1, -1 do
                        if alias.resolved_defaults[i] ~= nil then
                            required_count = i - 1
                        else
                            break
                        end
                    end
                end
                errors_mod.error(ctx.err, ctx.filename, ctx._ann_warn_line, 0,
                    "type '" .. name_str .. "' expects " .. required_count
                    .. " argument(s), got " .. (arg_ids and #arg_ids or 0))
                return ctx.T_NEVER
            end
            return resolved
        end
        -- Arity mismatch or similar resolution error.
        if resolve_err then
            -- HKT deferred application: F<A> where F is a type variable (forall param or
            -- generic alias placeholder). Only applies when the alias has NO type params of
            -- its own (the error is arity mismatch: "does not take type arguments") AND the
            -- alias body is an abstract type (TAG_VAR = forall param; TAG_NAMED = placeholder).
            -- Constraint violations (alias HAS params, arg fails bound check) are NOT deferred.
            local ai = arg_ids or {} --: { [integer]: integer, ... }
            if #ai > 0 and alias.body
                and (not alias.params or #alias.params == 0) then
                local body_id = types_mod.find(ctx, alias.body)
                local bt = ctx.types:get(body_id)
                if bt.tag == TAG_VAR or bt.tag == TAG_NAMED then
                    -- Produce TAG_TYPE_CALL(body, args): resolved at instantiation time.
                    local mk = ctx.lists:mark()
                    for _, aid in ipairs(ai) do ctx.lists:push(aid) end
                    local as, al = ctx.lists:since(mk)
                    local id = types_mod.alloc_type(ctx, defs.TAG_TYPE_CALL)
                    ctx.types:get(id).data[0] = body_id
                    ctx.types:get(id).data[1] = as
                    ctx.types:get(id).data[2] = al
                    return id
                end
            end
            errors_mod.error(ctx.err, ctx.filename, ctx._ann_warn_line, 0, resolve_err)
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
        local func_ann_line = ctx._ann_warn_line
        -- Pre-collect param name IDs so we can bind them in a child scope before
        -- resolving any param/return type annotations.  This makes `typeof x` work
        -- in both param types and return types of the same signature.
        local param_name_ids = nil
        if at.data[6] > 0 then
            param_name_ids = {}
            for i = at.data[5], at.data[5] + at.data[6] - 1 do
                param_name_ids[#param_name_ids + 1] = ctx.ann.lists:get(i)
            end
        end
        -- Build a child scope that pre-binds each named param as a fresh TAG_VAR
        -- placeholder.  Resolving param/return annotations with this scope active
        -- lets `typeof <param>` resolve to the placeholder regardless of declaration
        -- order.  After all param annotations are resolved we bind each placeholder
        -- to its concrete annotation type so subsequent `typeof` lookups find the
        -- bound type via union-find.
        local ann_scope = nil
        local ann_vars  = nil   -- parallel to param_name_ids: the fresh TAG_VAR ids
        local saved_scope = ctx.scope
        local saved_flag  = ctx._resolving_func_ann_scope
        if param_name_ids then
            ann_scope = env_mod.child(ctx.scope)
            ann_vars  = {}
            for _, nid in ipairs(param_name_ids) do
                local tv = types_mod.make_var(ctx, ctx.scope.level + 1)
                env_mod.bind(ann_scope, nid, tv)
                ann_vars[#ann_vars + 1] = tv
            end
            ctx.scope = ann_scope
            ctx._resolving_func_ann_scope = true
        end
        local params = {} --: { [integer]: integer }
        for i = at.data[0], at.data[0] + at.data[1] - 1 do
            local pt = resolve_annotation_type(ctx, ctx.ann.lists:get(i), seen)
            if pt == ctx.T_ANY and func_ann_line ~= 0 then
                warn(ctx, func_ann_line, 0, E.ANY_IN_TYPE, {})
            end
            params[#params + 1] = pt
        end
        -- Bind each placeholder to its resolved param type so that `typeof <param>`
        -- in return types (and later param types) resolves through union-find.
        if ann_vars then
            for pi, nid in ipairs(param_name_ids) do
                local tv_id  = ann_vars[pi]
                local ann_id = params[pi]
                if ann_id and ann_id ~= tv_id then
                    -- Only bind if the annotation is a concrete type (not another free
                    -- TAG_VAR placeholder — that would be a mutual `typeof` cycle like
                    -- `(a: typeof b, b: typeof a)`; leave both free and let the caller
                    -- unify them at call sites).
                    local ann_t = ctx.types:get(types_mod.find(ctx, ann_id))
                    if ann_t.tag ~= TAG_VAR then
                        ctx.types:get(tv_id).data[2] = ann_id
                    end
                end
            end
        end
        local returns = {}
        for i = at.data[2], at.data[2] + at.data[3] - 1 do
            local rt = resolve_annotation_type(ctx, ctx.ann.lists:get(i), seen)
            if rt == ctx.T_ANY and func_ann_line ~= 0 then
                warn(ctx, func_ann_line, 0, E.ANY_IN_TYPE, {})
            end
            returns[#returns + 1] = rt
        end
        local vararg_id = -1
        if at.data[4] >= 0 then
            vararg_id = resolve_annotation_type(ctx, at.data[4], seen)
            if vararg_id == ctx.T_ANY and func_ann_line ~= 0 then
                warn(ctx, func_ann_line, 0, E.ANY_IN_TYPE, {})
            end
        end
        if ann_scope then
            ctx.scope = saved_scope
            ctx._resolving_func_ann_scope = saved_flag
        end
        seen[ann_tid] = nil
        local resolved_fn = types_mod.make_func(ctx, params, returns, vararg_id, param_name_ids)
        -- Propagate type predicate / assertion predicate from annotation arena ID to
        -- the resolved ctx.types ID so that narrow.lua / constrain.lua can look it up
        -- by the runtime type ID (which is in ctx.types, not the annotation arena).
        -- The predicate's type_id is also in the annotation arena and must be resolved.
        if ctx.pool._type_predicates and ctx.pool._type_predicates[ann_tid] then
            local raw = ctx.pool._type_predicates[ann_tid]
            ctx.pool._type_predicates[resolved_fn] = {
                param_idx = raw.param_idx,
                type_id   = resolve_annotation_type(ctx, raw.type_id, seen),
            }
        end
        if ctx.pool._assert_predicates and ctx.pool._assert_predicates[ann_tid] then
            local raw = ctx.pool._assert_predicates[ann_tid]
            ctx.pool._assert_predicates[resolved_fn] = {
                param_idx = raw.param_idx,
                type_id   = resolve_annotation_type(ctx, raw.type_id, seen),
            }
        end
        return resolved_fn
    end

    if tag == TAG_TABLE then
        seen[ann_tid] = true
        local tbl_ann_line = ctx._ann_warn_line
        local field_ids = {}
        local field_pos = {}  -- name_id -> index in field_ids; later entries win (override semantics)
        local function add_field(new_fid, name_id)
            if field_pos[name_id] then
                field_ids[field_pos[name_id]] = new_fid
            else
                field_ids[#field_ids + 1] = new_fid
                field_pos[name_id] = #field_ids
            end
        end
        for i = at.data[0], at.data[0] + at.data[1] - 1 do
            local fid = ctx.ann.lists:get(i)
            local fe  = ctx.ann.fields:get(fid)
            if fe.name_id == -2 then
                -- Rest-field capture: { ...[%Rest] } in a match pattern.
                -- fe.type_id is a TAG_PAT_REST_FIELDS annotation node.
                -- Resolve and preserve it in the checker arena as name_id=-2 field.
                local prf_at = ctx.ann.types:get(fe.type_id)
                local prf_id = types_mod.alloc_type(ctx, defs.TAG_PAT_REST_FIELDS)
                ctx.types:get(prf_id).data[0] = prf_at.data[0]  -- name_id
                field_ids[#field_ids + 1] = types_mod.make_field(ctx, -2, prf_id, 0)
            elseif fe.name_id == -1 then
                -- Spread entry: { ...T, ... }
                -- fe.type_id is a TAG_SPREAD annotation node; .data[0] is the inner ann type.
                local spread_at = ctx.ann.types:get(fe.type_id)
                local inner_tid = resolve_annotation_type(ctx, spread_at.data[0], seen)
                inner_tid = types_mod.find(ctx, inner_tid)
                local inner_t = ctx.types:get(inner_tid)
                if inner_t.tag == TAG_TABLE then
                    for j = inner_t.data[0], inner_t.data[0] + inner_t.data[1] - 1 do
                        local inner_fid = ctx.lists:get(j)
                        local inner_fe  = ctx.fields:get(inner_fid)
                        local new_fid = types_mod.make_field(ctx, inner_fe.name_id, inner_fe.type_id, inner_fe.flags)
                        add_field(new_fid, inner_fe.name_id)
                    end
                end
                -- Inner type is not yet concrete (TAG_NAMED generic param, TAG_VAR, etc.).
                -- Keep as a runtime TAG_SPREAD placeholder field so substitute_inner
                -- in env.lua can expand it once the type variable is instantiated.
                local sp = types_mod.alloc_type(ctx, defs.TAG_SPREAD)
                ctx.types:get(sp).data[0] = inner_tid
                field_ids[#field_ids + 1] = types_mod.make_field(ctx, -1, sp, 0)
            else
                local ft = resolve_annotation_type(ctx, fe.type_id, seen)
                if ft == ctx.T_ANY and tbl_ann_line ~= 0 then
                    warn(ctx, tbl_ann_line, 0, E.ANY_IN_TYPE, {})
                end
                add_field(types_mod.make_field(ctx, fe.name_id, ft, fe.flags), fe.name_id)
            end
        end
        local indexers = {}
        local is, il = at.data[2], at.data[3]
        local i = is
        while i < is + il - 1 do
            local kt = resolve_annotation_type(ctx, ctx.ann.lists:get(i), seen)
            local vt = resolve_annotation_type(ctx, ctx.ann.lists:get(i + 1), seen)
            if (kt == ctx.T_ANY or vt == ctx.T_ANY) and tbl_ann_line ~= 0 then
                warn(ctx, tbl_ann_line, 0, E.ANY_IN_TYPE, {})
            end
            indexers[#indexers + 1] = kt
            indexers[#indexers + 1] = vt
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
            if fe.name_id == -3 then
                -- Meta-spread capture pattern: #...%M in a match pattern.
                -- fe.type_id is a TAG_PAT_META_SPREAD annotation node.
                -- Preserve it in the checker arena as name_id=-3 meta field.
                local pms_at = ctx.ann.types:get(fe.type_id)
                local pms_id = types_mod.alloc_type(ctx, defs.TAG_PAT_META_SPREAD)
                ctx.types:get(pms_id).data[0] = pms_at.data[0]  -- name_id
                meta_ids[#meta_ids + 1] = types_mod.make_field(ctx, -3, pms_id, 0)
            elseif fe.name_id == -1 then
                -- Meta-spread entry: #...T — spreads all meta slots from T into this table.
                -- fe.type_id is a TAG_SPREAD annotation node; .data[0] is the inner ann type.
                local spread_at = ctx.ann.types:get(fe.type_id)
                local inner_tid = resolve_annotation_type(ctx, spread_at.data[0], seen)
                inner_tid = types_mod.find(ctx, inner_tid)
                local inner_t = ctx.types:get(inner_tid)
                if inner_t.tag == TAG_TABLE then
                    -- Copy all meta slots from the inner type into this table's meta list.
                    for k = inner_t.data[5], inner_t.data[5] + inner_t.data[6] - 1 do
                        local inner_fid = ctx.lists:get(k)
                        local inner_fe  = ctx.fields:get(inner_fid)
                        meta_ids[#meta_ids + 1] = types_mod.make_field(ctx, inner_fe.name_id, inner_fe.type_id, inner_fe.flags)
                    end
                end
                -- Keep a TAG_SPREAD placeholder so env.lua substitute_inner can expand it
                -- once any type variable is instantiated.
                local sp = types_mod.alloc_type(ctx, defs.TAG_SPREAD)
                ctx.types:get(sp).data[0] = inner_tid
                meta_ids[#meta_ids + 1] = types_mod.make_field(ctx, -1, sp, 0)
            else
                local ft  = resolve_annotation_type(ctx, fe.type_id, seen)
                meta_ids[#meta_ids + 1] = types_mod.make_field(ctx, fe.name_id, ft, fe.flags)
            end
        end
        seen[ann_tid] = nil
        return types_mod.make_table(ctx, field_ids, indexers, row_var, meta_ids)
    end

    if tag == TAG_UNION then
        seen[ann_tid] = true
        local union_ann_line = ctx._ann_warn_line
        local members = {} --: { [integer]: integer }
        for i = at.data[0], at.data[0] + at.data[1] - 1 do
            local mt = resolve_annotation_type(ctx, ctx.ann.lists:get(i), seen)
            if mt == ctx.T_ANY and union_ann_line ~= 0 then
                warn(ctx, union_ann_line, 0, E.ANY_IN_TYPE, {})
            end
            members[#members + 1] = mt
        end
        seen[ann_tid] = nil
        return types_mod.make_union(ctx, members)
    end

    if tag == defs.TAG_INTERSECTION then
        seen[ann_tid] = true
        local isect_ann_line = ctx._ann_warn_line
        local members = {} --: { [integer]: integer }
        for i = at.data[0], at.data[0] + at.data[1] - 1 do
            local mt = resolve_annotation_type(ctx, ctx.ann.lists:get(i), seen)
            if mt == ctx.T_ANY and isect_ann_line ~= 0 then
                warn(ctx, isect_ann_line, 0, E.ANY_IN_TYPE, {})
            end
            members[#members + 1] = mt
        end
        seen[ann_tid] = nil
        -- Detect field conflicts: when two table members share a field name but
        -- their types are mutually incompatible, the intersection is unsatisfiable.
        local unify_mod = require("lib.type.static.unify")
        for i = 1, #members do
            local ai = types_mod.find(ctx, members[i])
            local ta = ctx.types:get(ai)
            if ta.tag == TAG_TABLE then
                for j = i + 1, #members do
                    local aj = types_mod.find(ctx, members[j])
                    local tb = ctx.types:get(aj)
                    if tb.tag == TAG_TABLE then
                        for fi = ta.data[0], ta.data[0] + ta.data[1] - 1 do
                            local afe = ctx.fields:get(ctx.lists:get(fi))
                            local bfe = types_mod.table_field(ctx, aj, afe.name_id)
                            if bfe then
                                local at_field = types_mod.find(ctx, afe.type_id)
                                local bt_field = types_mod.find(ctx, bfe.type_id)
                                if not unify_mod.try_unify(ctx, at_field, bt_field)
                                  and not unify_mod.try_unify(ctx, bt_field, at_field) then
                                    local fname = intern_mod.get(ctx.pool, afe.name_id) or "?"
                                    local at_str = types_mod.display(ctx, at_field)
                                    local bt_str = types_mod.display(ctx, bt_field)
                                    local line = ctx._ann_warn_line
                                    errors_mod.error(ctx.err, ctx.filename, line, 0,
                                        "intersection field conflict: field `" .. fname
                                        .. "` has incompatible types `"
                                        .. at_str .. "` and `" .. bt_str .. "`")
                                    return ctx.T_NEVER
                                end
                            end
                        end
                    end
                end
            end
        end
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
        local has_bounds = at.data[3] >= 0 and at.data[4] > 0
        local param_tvs = {}  -- tv ids, parallel to params (used for bound storage)
        for i = at.data[0], at.data[0] + at.data[1] - 1 do
            local param_name_id = ctx.ann.lists:get(i)
            local tv = types_mod.make_var(ctx, ctx.scope.level + 1)
            local tv_t = ctx.types:get(tv)
            tv_t.flags = defs.FLAG_GENERIC
            tv_t.data[3] = param_name_id  -- store name for skolem error messages
            env_mod.bind_type(param_scope, param_name_id, { body = tv })
            param_tvs[#param_tvs + 1] = tv
        end
        -- Resolve bounds (in param_scope so the bound can reference other type params)
        -- and record them in ctx._forall_bounds keyed by generic tv_id.
        -- Use _allow_unapplied_constructors so that unapplied kind-bounds like
        -- <F: T1> (where T1<X> = ...) are accepted as TAG_NAMED rather than erroring.
        -- solve_bound will skip TAG_NAMED bounds (kind constraints not yet enforced).
        if has_bounds then
            local saved_for_bounds = ctx.scope
            ctx.scope = param_scope
            local prev_allow = ctx._allow_unapplied_constructors
            ctx._allow_unapplied_constructors = true
            for idx = 1, #param_tvs do
                local bound_ann_id = ctx.ann.lists:get(at.data[3] + idx - 1)
                if bound_ann_id ~= -1 then
                    local resolved_bound = resolve_annotation_type(ctx, bound_ann_id, seen)
                    ctx._forall_bounds[param_tvs[idx]] = resolved_bound
                end
            end
            ctx._allow_unapplied_constructors = prev_allow
            ctx.scope = saved_for_bounds
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

    if tag == defs.TAG_CAPTURE then
        -- Preserve capture node in the checker arena with the same name_id.
        -- TAG_CAPTURE is used only in match arm pattern position; match.lua
        -- binds name_id -> resolved input type when the arm is evaluated.
        local id = types_mod.alloc_type(ctx, defs.TAG_CAPTURE)
        ctx.types:get(id).data[0] = at.data[0]  -- name_id
        return id
    end

    if tag == defs.TAG_PAT_ALL_FIELDS then
        -- Preserve all-fields pattern node in the checker arena.
        -- TAG_PAT_ALL_FIELDS is used only in match arm pattern position;
        -- match.lua distributes over all fields and indexers of the input type.
        local id = types_mod.alloc_type(ctx, defs.TAG_PAT_ALL_FIELDS)
        local nt = ctx.types:get(id)
        nt.data[0] = at.data[0]  -- k_name_id
        nt.data[1] = at.data[1]  -- v_name_id
        return id
    end

    if tag == defs.TAG_PAT_REST_FIELDS then
        -- Preserve rest-fields capture node in the checker arena.
        -- TAG_PAT_REST_FIELDS is used in table match arm pattern position;
        -- match.lua collects remaining unmatched fields and binds them to name_id.
        local id = types_mod.alloc_type(ctx, defs.TAG_PAT_REST_FIELDS)
        ctx.types:get(id).data[0] = at.data[0]  -- name_id
        return id
    end

    if tag == defs.TAG_PAT_META_SPREAD then
        -- Preserve meta-spread capture node in the checker arena.
        -- TAG_PAT_META_SPREAD is used in table match arm pattern position;
        -- match.lua collects all meta slots from the input and binds them to name_id.
        local id = types_mod.alloc_type(ctx, defs.TAG_PAT_META_SPREAD)
        ctx.types:get(id).data[0] = at.data[0]  -- name_id
        return id
    end

    if tag == defs.TAG_PARTIAL_APP then
        -- Partial application node: copy to checker arena preserving name_id and list data.
        -- The annotation arena stores partial args in its own lists; copy them into
        -- the checker's list pool so the checker-arena node is self-contained.
        local mk = ctx.lists:mark()
        for i = at.data[1], at.data[1] + at.data[2] - 1 do
            -- Each list entry is an annotation type_id; resolve it first.
            ctx.lists:push(resolve_annotation_type(ctx, ctx.ann.lists:get(i), seen))
        end
        local ls, ll = ctx.lists:since(mk)
        local id = types_mod.alloc_type(ctx, defs.TAG_PARTIAL_APP)
        local pt = ctx.types:get(id)
        pt.data[0] = at.data[0]  -- name_id
        pt.data[1] = ls
        pt.data[2] = ll
        return id
    end

    if tag == defs.TAG_INTRINSIC then
        -- If this intrinsic name is a registered type alias (e.g. $GlobalScope),
        -- resolve it like TAG_NAMED. Otherwise keep it as an opaque intrinsic node
        -- (for $Keys<T>, $EachUnion<T>, etc. that are expanded at call sites).
        local name_id = at.data[0]
        if env_mod.lookup_type(ctx.scope, name_id) then
            local resolved, err = env_mod.resolve_named_type(ctx, ctx.scope, name_id, nil)
            if resolved then return resolved end
        end
        local id = types_mod.alloc_type(ctx, defs.TAG_INTRINSIC)
        ctx.types:get(id).data[0] = name_id
        return id
    end

    if tag == defs.TAG_MATCH_TYPE then
        seen[ann_tid] = true
        local param = resolve_annotation_type(ctx, at.data[0], seen)
        local arms = {} --: { [integer]: integer, ... }
        local as, al = at.data[1], at.data[2]
        -- Arm patterns and bodies may contain free names (e.g. `A` in `{ value: A } => A`).
        -- These are pattern-capture variables, not errors. Set _in_match_arm so that
        -- unresolved TAG_NAMED references are kept as placeholders instead of erroring.
        local prev_in_match_arm = ctx._in_match_arm
        ctx._in_match_arm = true
        local i = as
        while i < as + al - 1 do
            arms[#arms + 1] = resolve_annotation_type(ctx, ctx.ann.lists:get(i), seen)
            arms[#arms + 1] = resolve_annotation_type(ctx, ctx.ann.lists:get(i + 1), seen)
            i = i + 2
        end
        ctx._in_match_arm = prev_in_match_arm
        local mk = ctx.lists:mark()
        for _, aid in ipairs(arms) do ctx.lists:push(aid) end
        local ms, ml = ctx.lists:since(mk)
        local id = types_mod.alloc_type(ctx, defs.TAG_MATCH_TYPE)
        local mtt = ctx.types:get(id)
        mtt.data[0] = param
        mtt.data[1] = ms
        mtt.data[2] = ml
        seen[ann_tid] = nil
        -- Evaluate immediately only when the param is already concrete.
        -- When param is a TAG_NAMED placeholder (generic alias body resolution),
        -- defer evaluation: env_mod.substitute will substitute param and call
        -- match.evaluate with the concrete type at instantiation time.
        local pt = ctx.types:get(types_mod.find(ctx, param))
        if pt.tag == defs.TAG_NAMED then
            return id  -- deferred; evaluated after substitution in env_mod.substitute
        end
        local match_mod = require("lib.type.static.match")
        return match_mod.evaluate(ctx, id)
    end

    if tag == defs.TAG_INDEX_TYPE then
        seen[ann_tid] = true
        local subject = resolve_annotation_type(ctx, at.data[0], seen)
        local key     = resolve_annotation_type(ctx, at.data[1], seen)
        seen[ann_tid] = nil
        local pt = ctx.types:get(types_mod.find(ctx, subject))
        local kt = ctx.types:get(types_mod.find(ctx, key))
        -- Defer when subject is an unresolved generic placeholder (TAG_NAMED with
        -- no args) or a free type variable; or when key is similarly unresolved.
        -- env.substitute_inner re-evaluates once both are concrete.
        local function deferred(ttag) return ttag == defs.TAG_NAMED or ttag == defs.TAG_VAR end
        if deferred(pt.tag) or deferred(kt.tag) then
            local id = types_mod.alloc_type(ctx, defs.TAG_INDEX_TYPE)
            local it = ctx.types:get(id)
            it.data[0] = subject
            it.data[1] = key
            return id
        end
        local match_mod = require("lib.type.static.match")
        local result = match_mod.lookup_index(ctx, subject, key)
        if result then return result end
        local line = ctx._ann_warn_line or 0
        report(ctx, line, 0, defs.E.INDEX_KEY_NOT_FOUND, {
            t = types_mod.display_short(ctx, subject),
            k = types_mod.display_short(ctx, key),
        })
        return ctx.T_NEVER
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
        local arg_ids = {} --: { [integer]: integer, ... }
        -- $Catch<T, Default?> must intercept $Throw inside T.
        -- Set catch_mode before resolving the first arg only.
        local is_catch_intrinsic = ct.tag == defs.TAG_INTRINSIC
            and intern_mod.get(ctx.pool, ct.data[0]) == "Catch"
        local ann_arg_start = at.data[1]
        local ann_arg_count = at.data[2]
        if is_catch_intrinsic then
            ctx.catch_mode = true
            ctx.catch_threw = false
        end
        for i = ann_arg_start, ann_arg_start + ann_arg_count - 1 do
            -- After the first arg of $Catch, disable catch_mode so Default
            -- is resolved normally (its throws are not intercepted).
            if is_catch_intrinsic and i == ann_arg_start + 1 then
                ctx.catch_mode = false
            end
            arg_ids[#arg_ids + 1] = resolve_annotation_type(ctx, ctx.ann.lists:get(i), seen)
        end
        if is_catch_intrinsic then
            ctx.catch_mode = false
        end
        local in_hkt_context = ctx._allow_unapplied_constructors
        ctx._allow_unapplied_constructors = prev_allow
        seen[ann_tid] = nil
        if ct.tag == TAG_NAMED then
            local resolved = env_mod.resolve_named_type(ctx, ctx.scope, ct.data[0], arg_ids)
            if resolved then
                -- If the result is a TAG_PARTIAL_APP and we are NOT in an HKT
                -- context (e.g. as an arg to an intrinsic like $EachField),
                -- emit an arity error. TAG_PARTIAL_APP in a concrete-type position
                -- is a usage error.
                local rt = ctx.types:get(resolved)
                if rt.tag == defs.TAG_PARTIAL_APP and not in_hkt_context then
                    local alias = env_mod.lookup_type(ctx.scope, ct.data[0])
                    local name = intern_mod.get(ctx.pool, ct.data[0]) or "?"
                    local param_count = alias and alias.params and #alias.params or 0
                    local required_count = param_count
                    if alias and alias.resolved_defaults then
                        for i = param_count, 1, -1 do
                            if alias.resolved_defaults[i] ~= nil then
                                required_count = i - 1
                            else
                                break
                            end
                        end
                    end
                    local err_mod = require("lib.type.static.errors")
                    err_mod.error(ctx.err, ctx.filename, 0, 0,
                        "type '" .. name .. "' expects " .. required_count
                        .. " argument(s), got " .. #arg_ids)
                    return ctx.T_NEVER
                end
                return resolved
            end
        end
        if ct.tag == defs.TAG_INTRINSIC then
            -- Defer when any arg is a placeholder TAG_NAMED (an unresolved type
            -- param from the enclosing generic alias body, e.g. T in
            -- $EachField<T, F>).  A placeholder is identified by its alias
            -- in scope having body == the TAG_NAMED node itself (set by
            -- process_type_decls for generic alias params).
            -- Also defer when any arg is a FLAG_GENERIC TAG_VAR (a type parameter
            -- from a FORALL context, e.g. T in <T: string>(m: T) -> $Require<T>).
            -- In both cases the intrinsic cannot be evaluated until the arg is
            -- concretely bound at a call site; the solver calls it via
            -- resolve_deferred_intrinsic after argument unification.
            local has_unresolved = false
            for _, aid in ipairs(arg_ids) do
                local at2 = ctx.types:get(types_mod.find(ctx, aid))
                if at2.tag == defs.TAG_NAMED then
                    local alias2 = env_mod.lookup_type(ctx.scope, at2.data[0])
                    if alias2 and alias2.body == types_mod.find(ctx, aid) then
                        has_unresolved = true
                        break
                    end
                end
                if at2.tag == defs.TAG_VAR and at2.flags == defs.FLAG_GENERIC then
                    has_unresolved = true
                    break
                end
            end
            if not has_unresolved then
                local intrinsic_mod = require("lib.type.static.intrinsic")
                local stable = fnv31(ctx.filename .. ":" .. tostring(ann_tid)) --[[:! integer]]
                return intrinsic_mod.expand(ctx --[[:! Ctx]], ct.data[0], arg_ids, stable) --[[:! integer]]
            end
            -- Fall through to store a deferred TAG_TYPE_CALL.
        end
        local mk = ctx.lists:mark()
        for _, aid in ipairs(arg_ids) do ctx.lists:push(aid) end
        local as, al = ctx.lists:since(mk)
        local id = types_mod.alloc_type(ctx, defs.TAG_TYPE_CALL)
        local tct = ctx.types:get(id)
        tct.data[0] = callee
        tct.data[1] = as
        tct.data[2] = al
        -- data[3]: stable call-site hash for $Opaque memoization. Stable across
        -- check runs for the same source content (annotation parser is deterministic).
        -- Propagated through cri so cross-file uses of this alias resolve consistently.
        tct.data[3] = fnv31(ctx.filename .. ":" .. tostring(ann_tid))
        return id
    end

    return ctx.T_ANY
end

-- ---------------------------------------------------------------------------
-- Annotation helpers
-- ---------------------------------------------------------------------------

-- Collect a run of consecutive preceding-line ANN_TYPE annotations ending at
-- decl_line - 1 and walking backward. Returns a synthetic merged ANN_TYPE entry
-- (intersection in the annotation arena) when there are multiple, the single entry
-- as-is when there is exactly one, or nil when there are none.
-- "Preceding-line" means lines strictly before the declaration line (not inline).
--: (Ctx, integer) -> { kind: integer, type_id: integer, ... } | nil
local function collect_preceding_run(ctx, decl_line)
    if not ctx.ann then return nil end
    local results = ctx.ann.results
    local consumed = ctx._ann_consumed
    local source_lines = ctx.err and ctx.err.source_lines[ctx.filename]
    -- Scan backward from decl_line - 1 collecting consecutive ANN_TYPE entries.
    -- Blank lines and comment-only lines are transparent: the scan skips past them
    -- so that a --: annotation separated from a function by whitespace/comments
    -- still associates with the function.
    local ann_lines = {}  -- lines found, nearest-to-decl first
    local scan = decl_line - 1
    while scan >= 1 do
        local r = results[scan]
        if r and r.kind == ANN_TYPE and not (consumed and consumed[scan]) then
            ann_lines[#ann_lines + 1] = scan
            scan = scan - 1
        elseif not r and source_lines then
            local line_text = source_lines[scan] or ""
            if line_text:match("^%s*$") or line_text:match("^%s*%-%-") then
                scan = scan - 1  -- blank or comment-only: skip
            else
                break
            end
        else
            break
        end
    end
    if #ann_lines == 0 then return nil end
    if #ann_lines == 1 then
        return results[ann_lines[1]]
    end
    -- Multiple consecutive preceding-line ANN_TYPE entries — merge into intersection.
    -- Reverse ann_lines so we go top-to-bottom (natural declaration order).
    local type_ids = {}
    for i = #ann_lines, 1, -1 do
        type_ids[#type_ids + 1] = results[ann_lines[i]].type_id
    end
    local inter_id = ctx.ann.make_intersection(type_ids)
    return { kind = ANN_TYPE, type_id = inter_id }
end

--: (Ctx, integer) -> { kind: integer, type_id: integer, ... } | nil
local function get_ann(ctx, line)
    if not ctx.ann then return nil end
    local consumed = ctx._ann_consumed
    -- Inline (end-of-line) annotation on the same line takes priority.
    local r = ctx.ann.results[line]
    if r and not (consumed and consumed[line]) then return r end
    -- Preceding-line annotation(s): collect the run starting at line-1.
    return collect_preceding_run(ctx, line)
end

--: (Ctx, integer) -> ()
local function consume_ann(ctx, line)
    if not ctx.ann then return end
    local r = ctx.ann.results[line]
    -- Only consume ANN_TYPE entries (not ANN_DECL, which are type-alias declarations).
    if r and r.kind == ANN_TYPE then
        ctx._ann_consumed = ctx._ann_consumed or {}
        ctx._ann_consumed[line] = true
        return
    end
    -- Consume any preceding-line run (walk backward from line-1).
    local results = ctx.ann.results
    local scan = line - 1
    while scan >= 1 do
        local r1 = results[scan]
        if r1 and r1.kind == ANN_TYPE then
            ctx._ann_consumed = ctx._ann_consumed or {}
            ctx._ann_consumed[scan] = true
            scan = scan - 1
        else
            break
        end
    end
end

-- ---------------------------------------------------------------------------
-- Forward declarations
-- ---------------------------------------------------------------------------

local gen_expr, gen_stmt, gen_block, gen_function, gen_prescan_block, gen_function_for_template
local block_has_return_stmt

-- ---------------------------------------------------------------------------
-- Expression constraint generation
-- ---------------------------------------------------------------------------

--: { [integer]: (Ctx, integer) -> integer, ... }
local ExprRule = {}

--: (Ctx, integer) -> integer
gen_expr = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local rule = ExprRule[n.kind]
    local tid
    if rule then
        tid = rule(ctx, nid)
    else
        report(ctx, n.line, n.col, E.UNHANDLED_EXPR, { kind = n.kind })
        tid = ctx.T_ANY
    end
    -- Record location → type for --annotate mode and LSP hover.
    if n.line and n.line > 0 then
        local ta = ctx.type_at
        ta[#ta+1] = n.line
        ta[#ta+1] = n.col
        ta[#ta+1] = tid
    end
    return tid
end

--: (Ctx, integer) -> { [integer]: integer, ... }
local function gen_expr_multi(ctx, nid)
    local n = ctx.nodes:get(nid)
    if n.kind == NODE_CALL_EXPR or n.kind == NODE_METHOD_CALL then
        local rule = ExprRule[n.kind]
        if rule then
            local primary = rule(ctx, nid)
            local mr = ctx._last_multi_return
            ctx._last_multi_return = nil
            --: { [integer]: integer, ... }
            local fallback = { primary }
            return mr or fallback
        end
    end
    return { gen_expr(ctx, nid) }
end

--: (Ctx, integer, integer) -> { [integer]: integer, ... }
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

--: (Ctx, integer) -> integer
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

--: (Ctx, integer) -> integer
ExprRule[NODE_IDENTIFIER] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local name_id = n.data[0]
    local ty = env_mod.lookup(ctx.scope, name_id)
    if ty then return ty end
    local name = intern_mod.get(ctx.pool, name_id) or "?"
    report(ctx, n.line, n.col, E.UNKNOWN_IDENTIFIER, { name = name })
    return ctx.T_ANY
end

--: (Ctx, integer) -> integer
ExprRule[NODE_VARARG_EXPR] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local vararg_id = intern_mod.intern(ctx.pool, "...")
    local ty = env_mod.lookup(ctx.scope, vararg_id)
    if ty then return ty end
    report(ctx, n.line, n.col, E.VARARG_OUTSIDE_FN, {})
    return ctx.T_ANY
end

--: (Ctx, integer) -> integer
ExprRule[NODE_UNARY_EXPR] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local op = n.data[0]
    local arg_tid = gen_expr(ctx, n.data[1])
    if op == OP_NOT then return ctx.T_BOOLEAN end
    if op == OP_UNM then
        local res = fresh_var(ctx)
        local _c = { C_ARITH, "__unm", arg_tid, arg_tid, res, n.line, n.col }
        emit(ctx, _c); record_polymorphic_op(ctx, _c)
        return res
    end
    if op == OP_LEN then
        local res = fresh_var(ctx)
        local _c = { C_ARITH, "__len", arg_tid, arg_tid, res, n.line, n.col }
        emit(ctx, _c); record_polymorphic_op(ctx, _c)
        return res
    end
    return ctx.T_ANY
end

--: (Ctx, integer) -> integer
ExprRule[NODE_BINARY_EXPR] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local op = n.data[0]

    if op == OP_AND then
        gen_expr(ctx, n.data[1])
        -- Narrow the scope for the RHS: if LHS is truthy, any nil/false has been filtered.
        -- e.g. `x and x .. "!"` where x: string|nil — x is string when evaluating RHS.
        local narrow_mod = require("lib.type.static.narrow")
        local narrowed = narrow_mod.narrow_scope(ctx, n.data[1], true)
        local saved_scope = ctx.scope
        if next(narrowed) then
            ctx.scope = narrow_mod.apply_narrowed(ctx, narrowed)
        end
        local right_r = types_mod.find(ctx, gen_expr(ctx, n.data[2]))
        ctx.scope = saved_scope
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
        local _c = { C_ARITH, ARITH_OPS[op], left_tid, right_tid, res, n.line, n.col }
        emit(ctx, _c); record_polymorphic_op(ctx, _c)
        return res
    end

    if op == OP_EQ or op == OP_NE then return ctx.T_BOOLEAN end

    if op == OP_LT or op == OP_GT or op == OP_LE or op == OP_GE then
        emit(ctx, { C_COMPARE, left_tid, right_tid, n.line, n.col })
        return ctx.T_BOOLEAN
    end

    if op == OP_CONCAT then
        local res = fresh_var(ctx)
        local _c = { C_ARITH, "__concat", left_tid, right_tid, res, n.line, n.col }
        emit(ctx, _c); record_polymorphic_op(ctx, _c)
        return res
    end

    if op == OP_OR then
        local res = fresh_var(ctx)
        emit(ctx, { C_OR, left_tid, right_tid, res, n.line, n.col })
        return res
    end

    report(ctx, n.line, n.col, E.BINARY_OP_UNKNOWN, { op = op })
    return ctx.T_ANY
end

--: (Ctx, integer) -> integer
ExprRule[NODE_FIELD_EXPR] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local obj_nid = n.data[0]
    local obj_tid = gen_expr(ctx, obj_nid)
    local fname_id = n.data[1]
    -- Check that the object type can have fields before emitting C_INDEX.
    -- TAG_VAR (unresolved), TAG_ANY, TAG_UNKNOWN, TAG_UNION are all fine — let C_INDEX handle them.
    do
        local resolved = types_mod.find(ctx, obj_tid)
        local ot = ctx.types:get(resolved)
        local no_fields = false
        if ot.tag == TAG_NIL then
            no_fields = true
        elseif ot.tag == TAG_BOOLEAN then
            no_fields = true
        elseif ot.tag == TAG_LITERAL then
            local lk = ot.data[0]
            -- LIT_BOOLEAN and number literals (LIT_NUMBER, LIT_INTEGER) cannot have fields.
            -- LIT_STRING is OK — strings have a metatable with methods in Lua.
            if lk == LIT_BOOLEAN or lk == LIT_NUMBER or lk == LIT_INTEGER then
                no_fields = true
            end
        end
        if no_fields then
            local t_str = types_mod.display(ctx, resolved)
            report(ctx, n.line, n.col, E.FIELD_ON_PRIMITIVE, { t = t_str })
            return fresh_var(ctx)
        end
    end
    local res = fresh_var(ctx)
    emit(ctx, { C_INDEX, obj_tid, types_mod.make_literal(ctx, LIT_STRING, fname_id), res, n.line, n.col })
    -- Record the field-access origin so peek_callee_ret_union can trace local aliases
    -- like `local find = string.find` back to the concrete function type.
    ctx._var_origin[res] = { obj_tid, fname_id }
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

--: (Ctx, integer) -> integer
ExprRule[NODE_INDEX_EXPR] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local key_nid = n.data[1]
    local key_n   = ctx.nodes:get(key_nid)

    -- Opaque key: `t[SomeVar]` where the key is a bare identifier resolving to a
    -- table-typed value (typeclass dispatch pattern). Emit C_INDEX with LIT_OPAQUE_KEY
    -- so solve_index can look up FLAG_OPAQUE_KEY fields by variable name.
    if key_n.kind == NODE_IDENTIFIER then
        local var_name_id = key_n.data[0]
        local var_tid     = env_mod.lookup(ctx.scope, var_name_id)
        if var_tid then
            local vt = ctx.types:get(types_mod.find(ctx, var_tid))
            if vt.tag == TAG_TABLE then
                local obj_tid = types_mod.find(ctx, gen_expr(ctx, n.data[0]))
                -- Consume the key expr so side-effects are still generated
                gen_expr(ctx, key_nid)
                local obj_t = ctx.types:get(obj_tid)
                if obj_t.tag == TAG_NEVER   then return ctx.T_NEVER end
                if obj_t.tag == TAG_UNKNOWN then return ctx.T_UNKNOWN end
                if obj_t.tag == TAG_ANY     then return ctx.T_ANY end
                local res = fresh_var(ctx)
                local opaque_key = types_mod.make_literal(ctx, LIT_OPAQUE_KEY, var_name_id)
                emit(ctx, { C_INDEX, obj_tid, opaque_key, res, n.line, n.col })
                return res
            end
        end
    end

    local obj_tid = types_mod.find(ctx, gen_expr(ctx, n.data[0]))
    local key_tid = gen_expr(ctx, key_nid)
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

    -- Integer literal key on a still-free param var → defer via C_INDEX so
    -- solve_index's integer-key HM branch can register `{ [integer]: U, ... }`
    -- bound on the param (Phase 1c step 7). Without this emission, `t[n]`
    -- on an unannotated function param would silently return T_ANY and the
    -- inferred return type would render as `any` instead of the polymorphic
    -- indexer-value type. For concrete obj types (tuple/table/etc.) the
    -- existing "Generic index" branch below handles the lookup directly,
    -- preserving the long-standing C_INDEX-free fast path for those cases.
    if kt_t.tag == TAG_LITERAL and kt_t.data[0] == LIT_INTEGER
        and (obj_t.tag == TAG_VAR or obj_t.tag == TAG_TABLE) then
        -- TAG_VAR: defer to solve_index's HM branch for indexer-bound inference.
        -- TAG_TABLE: defer so solve_index narrows positional brace-tuple slots
        -- (`{ A, B, C }[N]` → slot N's type) instead of the legacy
        -- "first indexer value wins" shortcut below.
        local res = fresh_var(ctx)
        emit(ctx, { C_INDEX, obj_tid, types_mod.make_literal(ctx, LIT_INTEGER, kt_t.data[1]), res, n.line, n.col })
        return res
    end

    -- Generic index
    if obj_t.tag == TAG_TABLE then
        local is, il = obj_t.data[2], obj_t.data[3]
        local i = is
        while i < is + il - 1 do
            return types_mod.find(ctx, ctx.lists:get(i + 1))
        end
        -- Open table: unknown index (caller must narrow); closed table: also unknown
        -- (no matching indexer means the access is unsound, but T_UNKNOWN is safer than T_ANY)
        return ctx.T_UNKNOWN
    end

    return ctx.T_ANY
end

--: (Ctx, integer) -> integer
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
            --: integer
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

-- Build a skolemized version of ann_fn_tid for generic body checking.
-- Returns (skolem_fn_tid, is_generic) where is_generic is true if any param
-- was FLAG_GENERIC (i.e. the function is a generic forall function).
-- Skolem vars have FLAG_SKOLEM set and can never be bound by the solver;
-- this prevents the self-loop problem that would arise from pushing a generic
-- TAG_VAR return type onto return_vars and then binding it in solve_return.
-- Only called when ann_fn_tid is a TAG_FUNCTION.
--: (Ctx, integer) -> (integer, boolean)
local function skolemize_fn(ctx, ann_fn_tid)
    local aft = ctx.types:get(ann_fn_tid)
    -- Detect whether any param (or the return) is a FLAG_GENERIC TAG_VAR.
    -- We deliberately do NOT walk nested function types: those FLAG_GENERIC
    -- TVs belong to a rank-N quantifier carried by a parameter/return whose
    -- own callers must skolemize them at their own use sites (call site for
    -- parameter-position rank-N, return-statement check for return-position
    -- rank-N). Conflating them with the outer function's quantifier breaks
    -- the body check (the body must be able to instantiate a rank-N param's
    -- `<T>` per call to use the function polymorphically).
    local has_generic = false
    for i = aft.data[0], aft.data[0] + aft.data[1] - 1 do
        local pt = ctx.types:get(types_mod.find(ctx, ctx.lists:get(i)))
        if pt.tag == TAG_VAR and pt.flags == defs.FLAG_GENERIC then
            has_generic = true
            break
        end
    end
    if not has_generic then
        for i = aft.data[2], aft.data[2] + aft.data[3] - 1 do
            local rt = ctx.types:get(types_mod.find(ctx, ctx.lists:get(i)))
            if rt.tag == TAG_VAR and rt.flags == defs.FLAG_GENERIC then
                has_generic = true
                break
            end
        end
    end
    if not has_generic then return ann_fn_tid, false end
    -- Instantiate: replaces FLAG_GENERIC vars with fresh vars.
    -- The mapping maps old_generic_tid -> fresh_tid.
    local skolem_fn_tid, mapping = env_mod.instantiate(ctx, ann_fn_tid, ctx.scope.level)
    -- Convert every fresh var in the mapping to a skolem, copying the name_id
    -- from the original generic var (stored in data[3] by resolve_annotation_type).
    for generic_tid, fresh_tid in pairs(mapping) do
        local fresh_t = ctx.types:get(fresh_tid)
        local orig_t  = ctx.types:get(generic_tid)
        fresh_t.flags = defs.FLAG_SKOLEM
        fresh_t.data[3] = orig_t.data[3]  -- copy name_id for error messages
    end
    return skolem_fn_tid, true
end

-- Rank-N helpers live in env.lua. Call site dispatch uses
-- env_mod.collect_rank_n_generics and env_mod.skolemize_return_for_rank_n.

-- Per-call identifier counter for rank-N skolem grouping. Each call site that
-- introduces nested-forall skolems gets a unique id, stored in the skolem TV's
-- data[4] slot, and matched by C_ESCAPE_CHECK when verifying that no skolem
-- leaked into the call's return type.
--: (Ctx) -> integer
local function next_rank_n_call_id(ctx)
    ctx._rank_n_call_counter = (ctx._rank_n_call_counter or 0) + 1
    return ctx._rank_n_call_counter
end

-- Build a function type for a template at definition time, without checking the body.
-- Returns a function type_id with fresh TAG_VAR params and a fresh TAG_VAR return.
-- The return type is left as a free variable; it will be unified with the actual
-- return at each call site after the body is re-checked with concrete arg types.
--: (Ctx, integer, integer, boolean) -> integer
local function gen_function_skip_body(ctx, ps, pl, has_vararg)
    local param_tids = {}
    for i = 0, pl - 1 do
        param_tids[#param_tids + 1] = types_mod.make_var(ctx, ctx.scope.level)
    end
    local ret_var = types_mod.make_var(ctx, ctx.scope.level)
    local vararg_id = has_vararg and ctx.T_UNKNOWN or -1
    local param_name_ids = {}
    for i = 0, pl - 1 do param_name_ids[i + 1] = ctx.ast_lists:get(ps + i) end
    return types_mod.make_func(ctx, param_tids, { ret_var }, vararg_id, param_name_ids)
end

-- Generate constraints for a function body.
-- Returns the function type_id.
--: (Ctx, integer, integer, integer, integer, boolean, integer | nil, integer | nil, integer | nil) -> integer
gen_function = function(ctx, ps, pl, bs, bl, has_vararg, ann_fn_tid, fn_def_line, fn_def_col)
    local fn_scope = env_mod.child(ctx.scope)
    local param_tids = {} --: { [integer]: integer, ... }

    local has_ann_fn = ann_fn_tid ~= nil
    -- body_ann_fn_tid: the annotation function type used for body checking.
    -- May differ from ann_fn_tid for generic functions (skolemized copy).
    -- Declared here so it is in scope for the return-type annotation block below.
    local body_ann_fn_tid = ann_fn_tid

    -- For generic (forall) functions: create a skolemized version of the annotation
    -- for body checking.  Skolem vars have FLAG_SKOLEM and are never bound by the
    -- solver, so the body check cannot create a self-loop by trying to bind the
    -- return's generic TAG_VAR.  The original ann_fn_tid (with FLAG_GENERIC vars) is
    -- used for the returned fn_tid so call sites still get proper generic instantiation.
    if ann_fn_tid then
        local aft_pre = ctx.types:get(ann_fn_tid)
        if aft_pre and aft_pre.tag == TAG_FUNCTION then
            local skolem_tid, is_generic = skolemize_fn(ctx, ann_fn_tid)
            if is_generic then body_ann_fn_tid = skolem_tid end
        end
    end

    if body_ann_fn_tid then
        local aft_body = ctx.types:get(body_ann_fn_tid)
        if aft_body and aft_body.tag == TAG_FUNCTION then
            -- Use the original ann_fn_tid for param_tids (what goes into fn_tid,
            -- must have FLAG_GENERIC vars so call-site instantiation works).
            -- Use body_ann_fn_tid (skolemized) for fn_scope bindings (what the
            -- body sees — skolem vars that cannot be bound by the solver).
            local aft_orig = ann_fn_tid and ctx.types:get(ann_fn_tid)
            for i = 0, pl - 1 do
                local name_id = ctx.ast_lists:get(ps + i)
                -- Body binding uses skolemized param (or fresh var if no annotation slot)
                local body_pt_id
                if i < aft_body.data[1] then
                    body_pt_id = types_mod.find(ctx, ctx.lists:get(aft_body.data[0] + i))
                else
                    body_pt_id = types_mod.make_var(ctx, fn_scope.level)
                end
                env_mod.bind(fn_scope, name_id, body_pt_id)
                -- fn_tid param uses original annotation (FLAG_GENERIC for generic fns)
                local fn_pt_id
                if aft_orig and aft_orig.tag == TAG_FUNCTION and i < aft_orig.data[1] then
                    fn_pt_id = types_mod.find(ctx, ctx.lists:get(aft_orig.data[0] + i))
                else
                    fn_pt_id = body_pt_id
                end
                param_tids[#param_tids + 1] = fn_pt_id
            end
            if has_vararg then
                local dots_id = intern_mod.intern(ctx.pool, "...")
                local vt = aft_body.data[4] >= 0 and aft_body.data[4] or ctx.T_UNKNOWN
                env_mod.bind(fn_scope, dots_id, vt)
            end
        else
            has_ann_fn = false
            body_ann_fn_tid = nil
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
            env_mod.bind(fn_scope, dots_id, ctx.T_UNKNOWN)
        end
    end

    local saved = ctx.scope
    ctx.scope = fn_scope

    -- Fresh return variable for this function.
    -- Use saved.level so generalize does NOT mark it generic; the solve pass will
    -- bind it to the actual union of return types from the body.
    local ret_var = types_mod.make_var(ctx, saved.level)

    -- If there is an annotated return type, push the concrete annotated type id
    -- onto return_vars instead of the fresh TAG_VAR.  solve_return checks whether
    -- the top of the stack is a TAG_VAR: if it is not, it enters the "check
    -- assignability" branch, which is what we want — actual <: annotated.
    -- If no annotation (or annotation has no return slots), push ret_var as
    -- before and let solve_return accumulate the body's actual return types.
    --
    -- IMPORTANT: only push the annotated type when it is concrete (not a free
    -- TAG_VAR or TAG_ROWVAR).  If the annotation is a type variable — e.g. the
    -- return of a generic function `<T>(x: T) -> T` is the same TAG_VAR as the
    -- param — pushing it onto return_vars and then binding it in solve_return's
    -- accumulation branch would create a self-loop in the union-find structure
    -- (the var's parent pointer points to itself), causing find() to loop forever.
    -- Generic / polymorphic return types are checked indirectly at call sites
    -- via C_CALLABLE, so they do not need body-level checking here.
    local push_ret_id = ret_var
    if has_ann_fn and body_ann_fn_tid then
        local aft = ctx.types:get(body_ann_fn_tid)
        if aft and aft.tag == TAG_FUNCTION and aft.data[3] > 0 then
            local ann_ret = types_mod.find(ctx, ctx.lists:get(aft.data[2]))
            local ann_ret_t = ctx.types:get(ann_ret)
            -- Use the annotated return type for body checking if it is either:
            --   (a) a concrete (non-var) type, or
            --   (b) a FLAG_SKOLEM TAG_VAR (from a skolemized generic function).
            -- Skolem vars are safe to push onto return_vars because they can never
            -- be bound by the solver, so no self-loop can occur.
            -- Plain free TAG_VAR / TAG_ROWVAR (unresolved generic placeholders) are
            -- still skipped — they would cause self-loops if bound in solve_return.
            local is_concrete_or_skolem = ann_ret_t.tag ~= TAG_VAR and ann_ret_t.tag ~= TAG_ROWVAR
            if ann_ret_t.tag == TAG_VAR and
               require("bit").band(ann_ret_t.flags, defs.FLAG_SKOLEM) ~= 0 then
                is_concrete_or_skolem = true
            end
            if is_concrete_or_skolem then
                if aft.data[3] == 1 then
                    -- Single return slot: use it directly.
                    push_ret_id = ann_ret
                    -- Rank-N in return position: if the return slot carries a
                    -- `<T>...` quantifier (annotation-introduced FLAG_GENERIC
                    -- TVs nested anywhere inside), the body's return value
                    -- must conform to the polymorphic shape. Skolemize those
                    -- TVs for the body's C_RETURN check so a monomorphic
                    -- value can't masquerade as the polymorphic slot.
                    push_ret_id = env_mod.skolemize_return_for_rank_n(ctx, push_ret_id)
                else
                    -- Multiple return slots: pack as a TAG_TUPLE so that a single
                    -- tuple-typed expression (e.g. Parameters<typeof f>) can be
                    -- returned and checked against all slots at once.  solve_return
                    -- handles both cases: TAG_TUPLE actual spread across TAG_TUPLE
                    -- expected, and scalar actual against TAG_TUPLE expected (where
                    -- only slot 0 is used — the normal `return a, b` path).
                    local slot_ids = {}
                    local all_usable = true
                    for si = aft.data[2], aft.data[2] + aft.data[3] - 1 do
                        local slot_tid = types_mod.find(ctx, ctx.lists:get(si))
                        local slot_t = ctx.types:get(slot_tid)
                        local slot_ok = slot_t.tag ~= TAG_VAR and slot_t.tag ~= TAG_ROWVAR
                        if slot_t.tag == TAG_VAR and
                           require("bit").band(slot_t.flags, defs.FLAG_SKOLEM) ~= 0 then
                            slot_ok = true
                        end
                        if not slot_ok then
                            all_usable = false
                            break
                        end
                        slot_ids[#slot_ids + 1] = slot_tid
                    end
                    if all_usable then
                        push_ret_id = types_mod.make_tuple(ctx, slot_ids)
                    end
                end
            end
        end
    end
    ctx.return_vars[#ctx.return_vars + 1] = push_ret_id

    -- HM Phase 1b: snapshot constraint-list start so we can sub-solve the
    -- body's constraints against still-free param vars BEFORE the function
    -- type is generalized and exposed to call sites. Without this, gen_call's
    -- env_mod.instantiate (called at constraint-emit time) captures the
    -- still-unresolved ret_var, which then never binds.
    local body_start = #ctx.constraints

    gen_prescan_block(ctx, bs, bl)
    local definitely_returning = gen_block(ctx, bs, bl)

    -- If the function has an annotation and the body does not definitely return on
    -- all paths, emit an implicit C_RETURN(nil, ret_var) for the fall-through path.
    -- This makes the solver see nil as a possible return value, which will conflict
    -- with a non-nil annotated return type and report a missing-return error.
    -- Unannotated functions are skipped: they infer their return type from actual
    -- returns, so adding nil would be overly noisy.
    if has_ann_fn and not definitely_returning then
        emit(ctx, { C_RETURN, ctx.T_NIL, push_ret_id, 0, 0 })
    end

    ctx.return_vars[#ctx.return_vars] = nil
    ctx.scope = saved

    -- HM Phase 1b: per-function sub-solve. Resolve body constraints against
    -- still-free param vars before generalization, so body usages refine the
    -- param shapes (Phase 1c body-solver hooks will emit metamethod-shape
    -- bounds via _forall_bounds; for now this just runs body constraints
    -- early so ret_var binding settles before call-site instantiation).
    -- Skipped for annotated functions (params are already concrete).
    --
    -- ctx._sub_solve_params marks this function's param tids so future
    -- Phase 1c body-solver hooks know which free vars to emit bounds on
    -- instead of deferring. Empty for now (Phase 1b is plumbing only).
    if not has_ann_fn then
        local body_end = #ctx.constraints
        if body_end > body_start then
            local solve_mod = require("lib.type.static.solve")
            local saved_sub_params = ctx._sub_solve_params
            ctx._sub_solve_params = {}
            for _, ptid in ipairs(param_tids) do
                ctx._sub_solve_params[ptid] = true
            end
            solve_mod.solve_range(ctx, ctx.constraints, body_start + 1, body_end)
            ctx._sub_solve_params = saved_sub_params
        end
    end
    local hm_body_end = #ctx.constraints

    local returns
    if ann_fn_tid then
        local aft = ctx.types:get(ann_fn_tid)
        if aft and aft.tag == TAG_FUNCTION then
            returns = {}
            for i = aft.data[2], aft.data[2] + aft.data[3] - 1 do
                returns[#returns + 1] = types_mod.find(ctx, ctx.lists:get(i))
            end
        end
    end
    if not returns then
        if not has_ann_fn and definitely_returning
            and not block_has_return_stmt(ctx, bs, bl) then
            returns = { ctx.T_NEVER }
        else
            returns = { ret_var }
        end
    end

    local vararg_id = has_vararg and ctx.T_UNKNOWN or -1
    local param_name_ids = {}
    for i = 0, pl - 1 do param_name_ids[i + 1] = ctx.ast_lists:get(ps + i) end
    local fn_tid = types_mod.make_func(ctx, param_tids, returns, vararg_id, param_name_ids)

    -- HM Phase 1b generalize: with body sub-solved above, the param vars
    -- carry whatever shape body usage imposed (Phase 1c will add the
    -- bound-emission hooks). Mark remaining free vars at level > saved.level
    -- as FLAG_GENERIC so each call site instantiates fresh copies.
    -- Skipped for annotated functions: param vars are concrete from the
    -- annotation and have no free vars at the function's level.
    if not has_ann_fn then
        env_mod.generalize(ctx, fn_tid, saved.level)
        -- HM Phase 2: with bounds populated by sub_solve and params marked
        -- FLAG_GENERIC, record body ops keyed by root template TV. Also
        -- generalizes nested bound TVs so call-site env.instantiate mints
        -- fresh per-call copies (driving inst_mapping[U_x] = U_x').
        record_polymorphic_ops_post(ctx, param_tids, body_start, hm_body_end)
    end

    -- Propagate type/assertion predicate from the annotation type ID to the runtime
    -- fn_tid so that narrow.lua / constrain.lua can look it up by the bound type ID.
    if ann_fn_tid then
        if ctx.pool._type_predicates and ctx.pool._type_predicates[ann_fn_tid] then
            ctx.pool._type_predicates[fn_tid] = ctx.pool._type_predicates[ann_fn_tid]
        end
        if ctx.pool._assert_predicates and ctx.pool._assert_predicates[ann_fn_tid] then
            ctx.pool._assert_predicates[fn_tid] = ctx.pool._assert_predicates[ann_fn_tid]
        end
    end

    -- Monomorphic inference: params stay as free TAG_VARs so that call-site C_CALLABLE
    -- constraints bind them directly.  Body constraints (C_ARITH, C_COMPARE, etc.) defer
    -- until params are concrete, then resolve with the actual call-site types.
    -- This means add("hello", 2) correctly errors because the body has C_ARITH(string, int).
    -- Functions with no call sites keep free params (effectively polymorphic/unknown).
    -- Explicitly generic functions use ann_fn_tid with <T> annotations instead.
    --
    -- Exception: the implicit `self` param of methods is marked FLAG_GENERIC so each
    -- call site gets a fresh instance.  Without this, binding p_self to the method's
    -- owner table creates a recursive type cycle (occurs check fires).
    if not has_ann_fn and pl > 0 then
        local self_name_id = ctx.ast_lists:get(ps)
        if intern_mod.get(ctx.pool, self_name_id) == "self" then
            ctx.types:get(param_tids[1]).flags = defs.FLAG_GENERIC
        end
    end

    return fn_tid
end

-- Check a function body against each member of an intersection-of-functions type.
-- For each TAG_FUNCTION member in intersection_tid, runs gen_function + solve in
-- isolation, collecting errors. If any overload produces errors, re-emits them
-- tagged with "overload N: <type> — <message>".
-- Returns the intersection_tid so the caller can bind the variable to it.
--: (Ctx, integer, integer, integer, integer, boolean, integer, integer | nil, integer | nil) -> integer
local function check_body_against_intersection(ctx, ps, pl, bs, bl, has_vararg,
                                                intersection_tid, node_line, node_col)
    local solve_mod = require("lib.type.static.solve")
    local it = ctx.types:get(intersection_tid)
    -- Collect TAG_FUNCTION members
    local members = {}
    for i = it.data[0], it.data[0] + it.data[1] - 1 do
        local mid = types_mod.find(ctx, ctx.lists:get(i))
        local mt = ctx.types:get(mid)
        if mt.tag == TAG_FUNCTION then
            members[#members + 1] = mid
        end
    end
    -- If not all members are functions, fall back to no body check
    if #members ~= it.data[1] then
        return intersection_tid
    end

    local saved_err = ctx.err
    for oi, member_tid in ipairs(members) do
        -- Capture constraint list before this overload's gen_function
        local cstart = #ctx.constraints

        -- Use a fresh error context for this overload pass.
        -- Share source_lines from the real err_ctx (read-only; no set_source needed).
        local pass_err = errors_mod.new_ctx()
        pass_err.source_lines = saved_err.source_lines
        ctx.err = pass_err

        gen_function(ctx, ps, pl, bs, bl, has_vararg, member_tid)

        -- Extract only the constraints emitted by this gen_function call
        local overload_constraints = {}
        for ci = cstart + 1, #ctx.constraints do
            overload_constraints[#overload_constraints + 1] = ctx.constraints[ci]
        end
        -- Truncate: these constraints belong to the overload check, not the main solve
        for ci = #ctx.constraints, cstart + 1, -1 do
            ctx.constraints[ci] = nil
        end

        -- Run solve on just the overload constraints (with pass_err active)
        solve_mod.solve(ctx, overload_constraints)

        ctx.err = saved_err

        -- Re-emit any errors from this overload, tagged with which overload
        if #pass_err.errors > 0 then
            local type_str = types_mod.display(ctx, member_tid)
            for _, e in ipairs(pass_err.errors) do
                local tagged_msg = "overload " .. oi .. ": " .. type_str .. " — " .. e.msg
                errors_mod.error(saved_err, ctx.filename, e.line, e.col, tagged_msg)
            end
        end
    end

    return intersection_tid
end

--: (Ctx, integer) -> integer
ExprRule[NODE_FUNC_EXPR] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local has_vararg = (n.flags % (FLAG_VARARG * 2)) >= FLAG_VARARG
    -- Check for --:: template on the preceding line.
    if ctx._template_lines and ctx._template_lines[n.line - 1] then
        -- Template function: skip body check at definition time.
        -- Body will be re-checked at each call site with concrete argument types.
        -- Store ps/pl/bs/bl from NODE_FUNC_EXPR layout: data[0]=ps, [1]=pl, [2]=bs, [3]=bl.
        local fn_tid = gen_function_skip_body(ctx, n.data[0], n.data[1], has_vararg)
        if not ctx._template_fns then ctx._template_fns = {} end
        ctx._template_fns[fn_tid] = {
            ps = n.data[0], pl = n.data[1], bs = n.data[2], bl = n.data[3],
            has_vararg = has_vararg,
        }
        return fn_tid
    end
    local ann = get_ann(ctx, n.line)
    local ann_fn_tid = nil
    if ann and ann.kind == ANN_TYPE then
        ctx._ann_warn_line = n.line
        local resolved = resolve_annotation_type(ctx, ann.type_id)
        ctx._ann_warn_line = 0
        local rt = ctx.types:get(types_mod.find(ctx, resolved))
        if rt.tag == TAG_FUNCTION then
            ann_fn_tid = resolved
        elseif rt.tag == defs.TAG_INTERSECTION then
            -- Intersection of functions: check body against each overload independently,
            -- then return the intersection type itself as the expression result.
            -- LOCAL_STMT will see rhs_tid = intersection_tid, ann_tid = intersection_tid,
            -- emit a trivial C_SUB, and bind the variable to the intersection type.
            local isect_tid = types_mod.find(ctx, resolved)
            check_body_against_intersection(ctx, n.data[0], n.data[1], n.data[2], n.data[3],
                has_vararg, isect_tid, n.line, n.col)
            return isect_tid
        end
    end
    -- Function expressions: record for the post-pass missing-signature check.
    -- Whether to actually fire depends on whether the source line is at
    -- statement position (`local f = function(...)`, `M.f = function(...)`,
    -- etc.) — inline anonymous functions like `s:gsub(p, function(c) end)`
    -- are typed by their call context, not by a separate `--:` line.
    local fn_tid = gen_function(ctx, n.data[0], n.data[1], n.data[2], n.data[3], has_vararg, ann_fn_tid, n.line, n.col)
    if not ann_fn_tid then
        ctx._missing_signatures = ctx._missing_signatures or {}
        ctx._missing_signatures[#ctx._missing_signatures + 1] = {
            line = n.line, col = n.col,
            source_kind = "expr",
            name_id = -1,
            fn_tid = fn_tid,
        }
    end
    return fn_tid
end

-- Recover a concrete type for an argument AST node when its constraint-gen
-- type is still an unresolved TAG_VAR.  Mirrors `peek_callee_ret_union`'s
-- callee-shape inspection: identifiers via scope lookup (with _var_origin
-- fallback through field-access bindings), and field expressions via direct
-- table_field lookup on the receiver.  Returns nil if not statically resolvable.
--: (Ctx, ASTNode) -> integer | nil
local function peek_arg_type(ctx, arg_n)
    if arg_n.kind == NODE_IDENTIFIER then
        local tid = env_mod.lookup(ctx.scope, arg_n.data[0])
        if tid then
            local rtid = types_mod.find(ctx, tid)
            local t = ctx.types:get(rtid)
            if t.tag == TAG_VAR then
                local origin = ctx._var_origin[rtid]
                if origin then
                    local src_obj = types_mod.find(ctx, origin[1])
                    local fe = types_mod.table_field(ctx, src_obj, origin[2])
                    if fe then return types_mod.find(ctx, fe.type_id) end
                end
                return nil
            end
            return rtid
        end
    elseif arg_n.kind == NODE_FIELD_EXPR then
        local obj_n = ctx.nodes:get(arg_n.data[0])
        if obj_n.kind == NODE_IDENTIFIER then
            local obj_tid = env_mod.lookup(ctx.scope, obj_n.data[0])
            if obj_tid then
                local resolved = types_mod.find(ctx, obj_tid)
                local fe = types_mod.table_field(ctx, resolved, arg_n.data[1])
                if fe then return types_mod.find(ctx, fe.type_id) end
            end
            -- Fallback: obj is a require()'d local whose type has not yet been
            -- resolved by the solver (still TAG_VAR awaiting $Require<T>).  Look up
            -- the cached exports tid recorded at gen time.
            if ctx._require_exports then
                local exp_tid = ctx._require_exports[obj_n.data[0]]
                if exp_tid then
                    local exp_resolved = types_mod.find(ctx, exp_tid)
                    local exp_fe = types_mod.table_field(ctx, exp_resolved, arg_n.data[1])
                    if exp_fe then return types_mod.find(ctx, exp_fe.type_id) end
                end
            end
        end
    end
    return nil
end

-- Try to eagerly evaluate a deferred intrinsic return at constraint-gen time.
-- When an instantiated callee has `-> ...$SomeIntrinsic<F>` as its return type,
-- the intrinsic args (which are fresh TVs from let-polymorphism instantiation)
-- can often be resolved immediately from the actual call-site arg types.  This
-- lets _last_multi_return_override be set eagerly so that if-guard narrowing
-- (e.g. `if ok then`) can filter union arms at constraint-gen time rather than
-- waiting until the solver runs.
--
-- Returns the evaluated type id (a concrete union-of-tuples), or nil if not
-- applicable (non-spread return, non-intrinsic inner, or args still unresolved).
--: (Ctx, integer, { [integer]: integer, ... }, integer, integer) -> integer | nil
local function try_eager_intrinsic_return(ctx, inst_callee_tid, arg_tids, args_es, args_el)
    local callee_t = ctx.types:get(types_mod.find(ctx, inst_callee_tid))
    if callee_t.tag ~= TAG_FUNCTION or callee_t.data[3] ~= 1 then return nil end
    local ret_slot = types_mod.find(ctx, ctx.lists:get(callee_t.data[2]))
    local ret_t = ctx.types:get(ret_slot)
    -- Must be TAG_SPREAD wrapping a TAG_TYPE_CALL(TAG_INTRINSIC, ...) or TAG_MATCH_TYPE
    if ret_t.tag ~= defs.TAG_SPREAD then return nil end
    local inner = types_mod.find(ctx, ret_t.data[0])
    local inner_t = ctx.types:get(inner)

    -- TAG_MATCH_TYPE in return spread: evaluate eagerly if match param is concrete.
    -- This handles match-alias equivalents of $PcallReturn (e.g. PcallReturn<F>).
    if inner_t.tag == defs.TAG_MATCH_TYPE then
        local match_param = types_mod.find(ctx, inner_t.data[0])
        local mpt = ctx.types:get(match_param)
        if mpt.tag == TAG_VAR then
            -- Find the function parameter this generic TV corresponds to and resolve
            -- it to the actual argument type.
            local params_len = callee_t.data[1]
            local concrete_arg = nil
            for pi = 0, params_len - 1 do
                local param = types_mod.find(ctx, ctx.lists:get(callee_t.data[0] + pi))
                if param == match_param then
                    if arg_tids[pi + 1] then
                        concrete_arg = types_mod.find(ctx, arg_tids[pi + 1])
                    end
                    -- If arg_tid is still an unresolved TAG_VAR (e.g. arg is a
                    -- field-access whose result is a fresh var awaiting C_INDEX),
                    -- try to recover its declared type by inspecting the AST node.
                    -- This is the path that fires for `pcall(ffi.load, ...)`.
                    if concrete_arg and ctx.types:get(concrete_arg).tag == TAG_VAR
                        and args_es and pi < args_el then
                        local arg_nid = ctx.ast_lists:get(args_es + pi)
                        local peeked = peek_arg_type(ctx, ctx.nodes:get(arg_nid))
                        if peeked then concrete_arg = peeked end
                    end
                    break
                end
            end
            if concrete_arg and ctx.types:get(concrete_arg).tag ~= TAG_VAR then
                -- Create a new match type with the concrete param and same arms.
                local new_mt = types_mod.alloc_type(ctx, defs.TAG_MATCH_TYPE)
                local mtt = ctx.types:get(new_mt)
                mtt.data[0] = concrete_arg
                mtt.data[1] = inner_t.data[1]
                mtt.data[2] = inner_t.data[2]
                local match_mod = require("lib.type.static.match")
                return match_mod.evaluate(ctx, new_mt, {})
            end
        end
        return nil
    end

    return nil
end

-- Peek at the declared return type of a callee without going through constraint
-- variables. Returns the concrete ret-slot type id, or nil if not resolvable.
-- Used to detect union-of-tuples return types (e.g. string.find, io.open) so
-- that LOCAL_STMT can correlate bindings at narrowing time.
--: (Ctx, ASTNode) -> integer | nil
local function peek_callee_ret_union(ctx, callee_n)
    local fn_tid = nil
    if callee_n.kind == NODE_IDENTIFIER then
        local tid = env_mod.lookup(ctx.scope, callee_n.data[0])
        if tid then
            fn_tid = types_mod.find(ctx, tid)
            -- If fn_tid is still an unresolved TAG_VAR (e.g. `local find = string.find`
            -- where the field access result is a fresh var), trace through _var_origin
            -- to find the concrete function type one level up.
            local ft = ctx.types:get(fn_tid)
            if ft.tag == TAG_VAR then
                local origin = ctx._var_origin[fn_tid]
                if origin then
                    local src_obj = types_mod.find(ctx, origin[1])
                    local fe = types_mod.table_field(ctx, src_obj, origin[2])
                    if fe then fn_tid = types_mod.find(ctx, fe.type_id) end
                end
            end
        end
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
    elseif callee_n.kind == defs.NODE_METHOD_CALL then
        -- Method call recv:method(...): look up method in receiver's type eagerly.
        -- This enables peek_callee_ret_union to work for e.g. str:match(pat)
        -- so that multi-return bindings are eager (not deferred via C_INDEX).
        local recv_n = ctx.nodes:get(callee_n.data[0])
        if recv_n then
            local recv_tid = env_mod.lookup(ctx.scope,
                recv_n.kind == defs.NODE_IDENTIFIER and recv_n.data[0] or 0)
            if not recv_tid and recv_n.kind == defs.NODE_IDENTIFIER then
                recv_tid = env_mod.lookup(ctx.scope, recv_n.data[0])
            end
            if recv_tid then
                local rtid = types_mod.find(ctx, recv_tid or 0)
                local method_id = callee_n.data[1]
                local fe = types_mod.table_field(ctx, rtid, method_id)
                if fe then fn_tid = types_mod.find(ctx, fe.type_id) end
            end
        end
    end
    if not fn_tid then return nil end
    local fn_t = ctx.types:get(fn_tid)
    if fn_t.tag ~= TAG_FUNCTION then return nil end
    -- Skip generic functions: their return type contains FLAG_GENERIC vars that won't be
    -- bound in the solver (only the instantiated fresh vars get bound at call sites).
    -- Peeking at the generic template would bind the local to the wrong (generic) type.
    for pi = fn_t.data[0], fn_t.data[0] + fn_t.data[1] - 1 do
        local ptid = types_mod.find(ctx, ctx.lists:get(pi))
        if ctx.types:get(ptid).flags == defs.FLAG_GENERIC then return nil end
    end
    local returns_len = fn_t.data[3]
    if returns_len == 1 then
        local ret_slot = types_mod.find(ctx, ctx.lists:get(fn_t.data[2]))
        local ret_t = ctx.types:get(ret_slot)
        -- Reject unresolved types; accept anything concrete.
        -- Callers use eager_slot for TAG_TUPLE/union-of-tuples (multi-return)
        -- and fall back to direct binding for scalars/plain unions (single return).
        if ret_t.tag == TAG_VAR or ret_t.tag == TAG_ROWVAR then return nil end
        -- Deferred parameterized intrinsic: TAG_TYPE_CALL(TAG_INTRINSIC,...) in return position.
        -- The return type is not concrete yet — the solver resolves it after argument binding
        -- (via resolve_deferred_intrinsic).  Do not peek; let the C_INDEX/slot path handle it.
        if ret_t.tag == defs.TAG_TYPE_CALL then return nil end
        -- Explicit multi-return: TAG_SPREAD in return position wraps the tuple/union-of-tuples.
        -- Unwrap and return the inner type directly — eager_slot handles it.
        if ret_t.tag == defs.TAG_SPREAD then
            return types_mod.find(ctx, ret_t.data[0])
        end
        -- Single-value return (no spread): always wrap in a 1-tuple.
        return types_mod.make_tuple(ctx, { ret_slot })
    elseif returns_len > 1 then
        -- Multi-return function: collect all return slots and wrap into a TAG_TUPLE.
        local slots = {}
        for i = 0, returns_len - 1 do
            local slot = types_mod.find(ctx, ctx.lists:get(fn_t.data[2] + i))
            local st = ctx.types:get(slot)
            -- Bail if any slot is unresolved or deferred.
            if st.tag == TAG_VAR or st.tag == TAG_ROWVAR then return nil end
            if st.tag == defs.TAG_TYPE_CALL then return nil end
            slots[#slots + 1] = slot
        end
        return types_mod.make_tuple(ctx, slots)
    else
        return nil
    end
end

-- Extract the type at slot N from a TAG_TUPLE or union-of-TAG_TUPLEs at constraint-gen time.
-- Returns nil when tid is TAG_VAR, nil, or not a tuple/union-of-tuples.
--: (Ctx, integer | nil, integer) -> integer | nil
local function eager_slot(ctx, tid, slot)
    if not tid then return nil end
    local t = ctx.types:get(tid)
    if t.tag == TAG_VAR or t.tag == TAG_ROWVAR then return nil end
    -- Unwrap TAG_SPREAD when extracting a slot: TAG_SPREAD(T) in position N
    -- means T was spread here.  The slot value is T (or T's inner type if T is
    -- a tuple), not the spread itself.  This covers the case where `(true, ...R)`
    -- was stored with an unresolved R (TAG_VAR) — the caller gets R directly
    -- and the type variable will be resolved by the solver later.
    local function unwrap_spread(elem_id)
        local et = ctx.types:get(elem_id)
        if et.tag == defs.TAG_SPREAD then
            return types_mod.find(ctx, et.data[0])
        end
        return elem_id
    end
    -- A raw vararg spread (e.g. string.match returns ...(string | nil)):
    -- each slot extracts the inner element type.
    if t.tag == defs.TAG_SPREAD then
        return types_mod.find(ctx, t.data[0])
    end
    if t.tag == defs.TAG_TUPLE then
        if slot < t.data[1] then
            return unwrap_spread(types_mod.find(ctx, ctx.lists:get(t.data[0] + slot)))
        end
        return ctx.T_NIL
    end
    if t.tag == TAG_UNION then
        local parts = {} --: { [integer]: integer, ... }
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            local arm = types_mod.find(ctx, ctx.lists:get(i))
            local arm_t = ctx.types:get(arm)
            if arm_t.tag ~= defs.TAG_TUPLE then return nil end
            if slot < arm_t.data[1] then
                parts[#parts + 1] = unwrap_spread(types_mod.find(ctx, ctx.lists:get(arm_t.data[0] + slot)))
            else
                parts[#parts + 1] = ctx.T_NIL
            end
        end
        if #parts == 0 then return ctx.T_NIL end
        if #parts == 1 then return parts[1] end
        return types_mod.make_union(ctx, parts)
    end
    return nil
end

--: (Ctx, integer) -> integer
ExprRule[NODE_CALL_EXPR] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local callee_nid = n.data[0]
    local callee_tid = gen_expr(ctx, callee_nid)
    local arg_tids = gen_expr_list(ctx, n.data[1], n.data[2])

    -- require() side-effect tracking: record module name for require_sources and
    -- invoke cri_loader for type alias injection.  Type resolution is handled by
    -- $Require<T> via the solver; this block extracts the literal module name and
    -- loads aliases at constraint-gen time so NODE_LOCAL_STMT can inject them into
    -- scope before the rest of the source file is processed.
    local callee_n = ctx.nodes:get(callee_nid)
    if callee_n.kind == NODE_IDENTIFIER and n.data[2] >= 1 then
        local fname = intern_mod.get(ctx.pool, callee_n.data[0]) or ""
        if fname == "require" then
            local arg0_nid = ctx.ast_lists:get(n.data[1])
            local arg0_n = ctx.nodes:get(arg0_nid)
            if arg0_n and arg0_n.kind == NODE_LITERAL and arg0_n.data[2] == LIT_STRING then
                local mod_name = intern_mod.get(ctx.pool, arg0_n.data[1]) or ""
                ctx._last_require_mod = mod_name
                -- Invoke cri_loader at gen time to get type aliases for injection.
                -- The returned exports type is ignored here (resolved later by $Require<T>
                -- via the solver); we only care about aliases for scope injection.
                if ctx.cri_loader then
                    local exports_tid, aliases = ctx.cri_loader(ctx, mod_name)
                    if aliases then
                        ctx._last_require_aliases = aliases
                    end
                    if exports_tid then
                        ctx._last_require_exports = exports_tid
                    end
                end
                -- Fallback to declared module type (--:: module "name": T) so
                -- field-access on the require'd local can be resolved eagerly at
                -- gen time (used by try_eager_intrinsic_return for pcall).
                if not ctx._last_require_exports and ctx.module_types
                    and ctx.module_types[mod_name] then
                    ctx._last_require_exports = ctx.module_types[mod_name]
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
                    if ctx.ffi_hooks then
                        ctx.ffi_hooks.process(ctx, c_str)
                    end
                end
                return ctx.T_NIL
            end
        end
    end

    -- Template call-site re-check: if callee is a --:: template function,
    -- re-run the body with the concrete argument types to check it and infer
    -- the return type for this specific call site.
    local resolved_callee = types_mod.find(ctx, callee_tid)
    if ctx._template_fns and ctx._template_fns[resolved_callee] then
        local tinfo = ctx._template_fns[resolved_callee]
        local call_fn_tid = gen_function_for_template(ctx, tinfo.ps, tinfo.pl, tinfo.bs, tinfo.bl,
            tinfo.has_vararg, arg_tids)
        -- Extract the return type from the template instantiation and bind the call's ret.
        local call_fn_t = ctx.types:get(call_fn_tid)
        local ret = fresh_var(ctx)
        if call_fn_t.tag == TAG_FUNCTION then
            local rl = call_fn_t.data[3]
            if rl == 0 then
                emit(ctx, { C_UNIFY, ret, ctx.T_NIL, n.line, n.col })
            elseif rl == 1 then
                local first_ret = types_mod.find(ctx, ctx.lists:get(call_fn_t.data[2]))
                emit(ctx, { C_UNIFY, ret, first_ret, n.line, n.col })
            else
                local slots = {}
                for ri = 0, rl - 1 do
                    slots[ri + 1] = types_mod.find(ctx, ctx.lists:get(call_fn_t.data[2] + ri))
                end
                emit(ctx, { C_UNIFY, ret, types_mod.make_tuple(ctx, slots), n.line, n.col })
            end
        else
            emit(ctx, { C_UNIFY, ret, ctx.T_ANY, n.line, n.col })
        end
        ctx._last_multi_return = { ret }
        return ret
    end

    -- Identify rank-N skolem candidates BEFORE instantiation: any FLAG_GENERIC
    -- TV that lives strictly inside a function-typed parameter or return slot
    -- of the callee. These belong to the nested forall's quantifier, not the
    -- callee's own — they must be skolemized at the call site so the argument
    -- subsumption check enforces the polymorphic shape (rank-N subsumption).
    -- See docs/typechecker-rank-n.md.
    local rank_n_set = env_mod.collect_rank_n_generics(ctx, callee_tid)
    local has_rank_n = next(rank_n_set) ~= nil

    -- Instantiate callee at this call site (let-polymorphism)
    local inst_mapping = {}
    local inst_callee = env_mod.instantiate(ctx, callee_tid, ctx.scope.level, inst_mapping)

    -- For each FLAG_GENERIC TV in `rank_n_set`, convert its fresh image to a
    -- per-call skolem. The skolem can't be bound by unify (unify.bind_var
    -- rejects FLAG_SKOLEM), so a monomorphic argument trying to specialize
    -- the polymorphic slot fails — exactly the rank-N rejection we need.
    local rank_n_call_id = 0 --: integer
    if has_rank_n then
        rank_n_call_id = next_rank_n_call_id(ctx)
        for orig_tv in pairs(rank_n_set) do
            local fresh_tv = inst_mapping[orig_tv]
            if fresh_tv then
                local ft = ctx.types:get(fresh_tv)
                local ot = ctx.types:get(orig_tv)
                ft.flags = defs.FLAG_SKOLEM
                ft.data[3] = ot.data[3]   -- carry name_id for error messages
                ft.data[4] = rank_n_call_id  -- per-call grouping for escape check
            end
        end
    end

    -- Emit deferred bound checks for each instantiated generic TV that has a bound.
    -- Instantiate the bound with inst_mapping so that generic TVs inside it (e.g. the
    -- subject of a TAG_MATCH_TYPE or a TV used as a <T: F> bound) are replaced by the
    -- corresponding fresh TVs.  This lets solve_bound evaluate the bound once the fresh TV
    -- is bound to a concrete type, without needing to retain the original inst_mapping.
    if next(ctx._forall_bounds) and next(inst_mapping) then
        -- Build a map: fresh_tv -> bound_alias_tid for HKT decomposition. A
        -- fresh TV is eligible if its origin had a generic-alias bound
        -- (TAG_NAMED whose name resolves to an alias with >=1 type param).
        -- These are the F in `<F: Maybe>` patterns.
        local hkt_fresh_to_bound = nil
        for orig_tv, fresh_tv in pairs(inst_mapping) do
            local bound = ctx._forall_bounds[orig_tv]
            if bound then
                local inst_bound = env_mod.instantiate(ctx, bound, ctx.scope.level, inst_mapping)
                emit(ctx, { C_BOUND, fresh_tv, inst_bound, n.line, n.col })
                local resolved_bound = types_mod.find(ctx, inst_bound)
                local bt = ctx.types:get(resolved_bound)
                if bt.tag == defs.TAG_NAMED and bt.data[2] == 0 then
                    local alias = env_mod.lookup_type(ctx.scope, bt.data[0])
                    if alias and alias.params and #alias.params >= 1 then
                        hkt_fresh_to_bound = hkt_fresh_to_bound or {}
                        hkt_fresh_to_bound[fresh_tv] = resolved_bound
                    end
                end
            end
        end

        -- HKT decomposition: walk the instantiated callee's parameter slots
        -- and emit C_HKT_DECOMPOSE for each top-level TAG_TYPE_CALL whose
        -- callee is one of the HKT-bounded fresh TVs.
        --
        -- Eager-bind decision: for fresh TVs that appear ONLY in the return
        -- slot as a TAG_TYPE_CALL callee (e.g. `pure: <M: Maybe>(a) -> M<A>`),
        -- pin F := bound_alias so the return slot can normalize once A is
        -- bound. Do NOT eager-bind when F also appears as a bare param-slot
        -- type (e.g. `id_hkt: <F: T1>(fa: F) -> F`) — that case relies on
        -- C_BOUND's kind-arity check to reject mismatched actuals.
        if hkt_fresh_to_bound and arg_tids then
            local decomposed = {}
            local appears_bare_in_param = {}
            local appears_in_return_as_callee = {}
            local ic = ctx.types:get(inst_callee)
            if ic.tag == TAG_FUNCTION then
                local p_start, p_len = ic.data[0], ic.data[1]
                for i = 0, p_len - 1 do
                    local slot_tid = ctx.lists:get(p_start + i)
                    local slot_root = types_mod.find(ctx, slot_tid)
                    local slot = ctx.types:get(slot_root)
                    if slot.tag == defs.TAG_TYPE_CALL then
                        local callee2 = types_mod.find(ctx, slot.data[0])
                        local bound_alias = hkt_fresh_to_bound[callee2]
                        if bound_alias then
                            decomposed[callee2] = true
                            local args_list = {}
                            for j = slot.data[1], slot.data[1] + slot.data[2] - 1 do
                                args_list[#args_list + 1] = ctx.lists:get(j)
                            end
                            local actual_arg = arg_tids[i + 1]
                            if actual_arg then
                                local payloads = ctx._hkt_payloads or {}
                                local pid = #payloads + 1
                                payloads[pid] = {
                                    f_fresh = callee2,
                                    args_fresh = args_list,
                                    bound_alias = bound_alias,
                                    actual_arg = actual_arg,
                                    line = n.line,
                                    col = n.col,
                                }
                                ctx._hkt_payloads = payloads
                                emit(ctx, { C_HKT_DECOMPOSE, pid, n.line, n.col })
                            end
                        end
                    elseif hkt_fresh_to_bound[slot_root] then
                        appears_bare_in_param[slot_root] = true
                    end
                end
                local r_start, r_len = ic.data[2], ic.data[3]
                for i = 0, r_len - 1 do
                    local rslot = ctx.types:get(types_mod.find(ctx, ctx.lists:get(r_start + i)))
                    if rslot.tag == defs.TAG_TYPE_CALL then
                        local rcallee = types_mod.find(ctx, rslot.data[0])
                        if hkt_fresh_to_bound[rcallee] then
                            appears_in_return_as_callee[rcallee] = true
                        end
                    end
                end
            end

            -- Eager bind: F appears as TAG_TYPE_CALL callee in return AND
            -- not as a bare param type AND not already decomposed from a
            -- param. (If decomposed, the structural path will bind it.)
            local unify_mod2 = require("lib.type.static.unify")
            for fresh_tv, bound_alias in pairs(hkt_fresh_to_bound) do
                if appears_in_return_as_callee[fresh_tv]
                    and not decomposed[fresh_tv]
                    and not appears_bare_in_param[fresh_tv] then
                    local ff_root = types_mod.find(ctx, fresh_tv)
                    local ff_t = ctx.types:get(ff_root)
                    if ff_t.tag == TAG_VAR or ff_t.tag == defs.TAG_ROWVAR then
                        unify_mod2.bind_var_to_type(ctx, ff_root, bound_alias)
                    end
                end
            end
        end
        -- HM Phase 2: re-emit recorded body ops with operand TVs mapped to
        -- their per-call fresh instances. The bound walk above populated
        -- inst_mapping for every TV nested inside each generalized bound
        -- (because record_polymorphic_ops_post marked them FLAG_GENERIC).
        -- A single op may be reachable from multiple template TVs (e.g. an
        -- arith op uses operands from two distinct param bounds): use a
        -- per-call seen set to avoid double-emit.
        if ctx._forall_ops then
            local seen_ops = {}
            for orig_tv in pairs(inst_mapping) do
                local bucket = ctx._forall_ops[orig_tv]
                if bucket then
                    for _, op in ipairs(bucket) do
                        if not seen_ops[op] then
                            seen_ops[op] = true
                            local code = op[1]
                            if code == C_ARITH then
                                local lhs = inst_mapping[op[3]] or op[3]
                                local rhs = inst_mapping[op[4]] or op[4]
                                local res = inst_mapping[op[5]] or op[5]
                                emit(ctx, { C_ARITH, op[2], lhs, rhs, res, n.line, n.col })
                            elseif code == C_COMPARE then
                                local lhs = inst_mapping[op[2]] or op[2]
                                local rhs = inst_mapping[op[3]] or op[3]
                                emit(ctx, { C_COMPARE, lhs, rhs, n.line, n.col })
                            elseif code == C_BIND_GENERICS or code == C_CHECK_ARGS then
                                local callee = inst_mapping[op[2]] or op[2]
                                local orig_args = op[3] --[[: { [integer]: integer, ... }]]
                                local mapped_args = {}
                                for k, a in ipairs(orig_args) do
                                    mapped_args[k] = inst_mapping[a] or a
                                end
                                local ret = inst_mapping[op[4]] or op[4]
                                emit(ctx, { code, callee, mapped_args, ret, n.line, n.col })
                            end
                            -- C_INDEX and C_CALLABLE intentionally not
                            -- re-emitted; see record_polymorphic_ops_post.
                        end
                    end
                end
            end
        end
    end

    local ret = fresh_var(ctx)
    emit(ctx, { C_BIND_GENERICS, inst_callee, arg_tids, ret, n.line, n.col })
    emit(ctx, { C_CHECK_ARGS,    inst_callee, arg_tids, ret, n.line, n.col })
    if has_rank_n then
        -- Per-call escape check: ensure no skolem with this call_id reaches
        -- the inferred return type. See docs/typechecker-rank-n.md.
        emit(ctx, { M.C_ESCAPE_CHECK, ret, rank_n_call_id, n.line, n.col })
    end
    ctx._last_multi_return = { ret }

    -- Eagerly evaluate $PcallReturn<F> at constraint-gen time so that
    -- _last_multi_return_override is available for if-guard narrowing.
    -- This replaces the former name-based pcall/xpcall special case.
    -- Only applies to $PcallReturn (union-of-tuples needing correlated narrowing);
    -- other intrinsics ($IpairsReturn, $PairsReturn, $Require, ...) are resolved
    -- by resolve_deferred_intrinsic in the solver after parameter unification.
    local eager = try_eager_intrinsic_return(ctx, inst_callee, arg_tids, n.data[1], n.data[2])
    if eager then
        ctx._last_multi_return_override = eager
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

--: (Ctx, integer) -> integer
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

    local meth_mapping = {}
    local inst_method = env_mod.instantiate(ctx, method_var, ctx.scope.level, meth_mapping)

    -- Emit deferred bound checks for each instantiated generic TV that has a bound.
    -- Instantiate the bound using meth_mapping so generic TVs inside it are replaced.
    if next(ctx._forall_bounds) and next(meth_mapping) then
        for orig_tv, fresh_tv in pairs(meth_mapping) do
            local bound = ctx._forall_bounds[orig_tv]
            if bound then
                local inst_bound = env_mod.instantiate(ctx, bound, ctx.scope.level, meth_mapping)
                emit(ctx, { C_BOUND, fresh_tv, inst_bound, n.line, n.col })
            end
        end
    end

    local ret = fresh_var(ctx)
    emit(ctx, { C_BIND_GENERICS, inst_method, arg_tids, ret, n.line, n.col })
    emit(ctx, { C_CHECK_ARGS,    inst_method, arg_tids, ret, n.line, n.col })
    ctx._last_multi_return = { ret }

    -- Eagerly peek the method's return type so LOCAL_STMT can extract slots at
    -- constraint-gen time (enabling narrowing of e.g. `local a, b = str:match(...)`).
    -- Look up the method directly in the receiver's concrete type (if known).
    local recv_resolved = types_mod.find(ctx, recv_tid)
    local fe = types_mod.table_field(ctx, recv_resolved, method_name_id)
    if fe then
        local mth_fn_tid = types_mod.find(ctx, fe.type_id)
        local mth_fn_t = ctx.types:get(mth_fn_tid)
        if mth_fn_t.tag == TAG_FUNCTION and mth_fn_t.data[3] == 1 then
            -- Check it's not generic
            local is_generic = false
            for pi = mth_fn_t.data[0], mth_fn_t.data[0] + mth_fn_t.data[1] - 1 do
                local ptid = types_mod.find(ctx, ctx.lists:get(pi))
                if ctx.types:get(ptid).flags == defs.FLAG_GENERIC then
                    is_generic = true; break
                end
            end
            if not is_generic then
                local ret_slot = types_mod.find(ctx, ctx.lists:get(mth_fn_t.data[2]))
                local ret_t = ctx.types:get(ret_slot)
                if ret_t.tag ~= TAG_VAR and ret_t.tag ~= TAG_ROWVAR
                    and ret_t.tag ~= defs.TAG_TYPE_CALL then
                    local override
                    if ret_t.tag == defs.TAG_SPREAD then
                        override = types_mod.find(ctx, ret_t.data[0])
                    else
                        override = types_mod.make_tuple(ctx, { ret_slot })
                    end
                    ctx._last_multi_return_override = override
                end
            end
        end
    end

    return ret
end

--: (Ctx, integer) -> integer
ExprRule[NODE_CAST_EXPR] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local inner_tid = gen_expr(ctx, n.data[0])
    if not ctx.ann then return inner_tid end
    local ann = ctx.ann.results[n.data[1]]  -- n.data[1] is the negative cast_id
    if not ann or ann.kind ~= ANN_TYPE then return inner_tid end
    -- Reject `--[[:! any]]`: the force-cast is for narrowing `unknown` to a
    -- concrete type, not for casting to `any`. Use `--[[: unknown]]` instead.
    if band(n.flags, defs.FLAG_FORCE_CAST) ~= 0 then
        local at = ctx.ann and ctx.ann.types:get(ann.type_id)
        if at and at.tag == defs.TAG_ANY then
            local entry = report(ctx, n.line, n.col, E.FORCE_CAST_TO_ANY, {})
            -- Attach autofix: replace `--[[:! any]]` with `--[[: any]]`.
            if entry and ann.byte_start and ann.byte_end then
                entry.fix = {
                    kind = "safe",
                    rule = "force_cast_to_any",
                    edits = { {
                        byte_start  = ann.byte_start,
                        byte_end    = ann.byte_end,
                        replacement = "--[[: any]]",
                    } },
                }
            end
            return inner_tid
        end
    end
    ctx._ann_warn_line = n.line
    local cast_tid = resolve_annotation_type(ctx, ann.type_id)
    ctx._ann_warn_line = 0
    if band(n.flags, defs.FLAG_FORCE_CAST) ~= 0 then
        -- --[[:! T]] expr: bidirectional subtype force cast. Succeeds when actual
        -- is a subtype of expected (widening) or expected is a subtype of actual
        -- (narrowing). Permits unknown→T and (A|B)→A, but rejects unrelated
        -- pairs (e.g. string→integer).
        if ann.byte_start and ann.byte_end then
            ctx._overlap_byte_range = ctx._overlap_byte_range or {}
            ctx._overlap_byte_range[(n.line or 0) * 100000 + (n.col or 0)] =
                { ann.byte_start, ann.byte_end }
        end
        emit(ctx, { C_OVERLAP, inner_tid, cast_tid, n.line, n.col })
    else
        emit(ctx, { C_SUB, inner_tid, cast_tid, n.line, n.col, true })  -- true = is_cast
    end
    return cast_tid
end

-- ---------------------------------------------------------------------------
-- Block / statement generation
-- ---------------------------------------------------------------------------

-- Returns true if stmt nid is an expression-statement that calls a never-returning
-- function (i.e. a function whose return type is T_NEVER, such as error()).
-- Uses the current ctx.scope to look up the callee's type.
--: (Ctx, integer) -> boolean
local function fn_returns_never(ctx, fn_tid)
    if not fn_tid then return false end
    fn_tid = types_mod.find(ctx, fn_tid)
    local ft = ctx.types:get(fn_tid)
    if not ft or ft.tag ~= TAG_FUNCTION then return false end
    -- Check first return type is T_NEVER (data[3] = ret count, data[2] = ret list start).
    if ft.data[3] < 1 then return false end
    local ret0 = types_mod.find(ctx, ctx.lists:get(ft.data[2]))
    return ret0 == ctx.T_NEVER
end

--: (Ctx, integer) -> boolean
local function is_never_call_stmt(ctx, nid)
    local sn = ctx.nodes:get(nid)
    if sn.kind ~= NODE_EXPR_STMT then return false end
    local expr_nid = sn.data[0]
    local en = ctx.nodes:get(expr_nid)
    -- Method call: obj:method(...) — look up method on receiver type.
    if en.kind == NODE_METHOD_CALL then
        local recv_nid = en.data[0]
        local rn = ctx.nodes:get(recv_nid)
        if rn.kind ~= NODE_IDENTIFIER then return false end
        local recv_tid = env_mod.lookup(ctx.scope, rn.data[0])
        if not recv_tid then return false end
        local recv_resolved = types_mod.find(ctx, recv_tid)
        local fe = types_mod.table_field(ctx, recv_resolved, en.data[1])
        if not fe then return false end
        return fn_returns_never(ctx, fe.type_id)
    end
    if en.kind ~= NODE_CALL_EXPR then return false end
    local callee_nid = en.data[0]
    local cn = ctx.nodes:get(callee_nid)
    if cn.kind == NODE_IDENTIFIER then
        local fn_tid = env_mod.lookup(ctx.scope, cn.data[0])
        if fn_tid == nil then return false end
        return fn_returns_never(ctx, fn_tid)
    end
    -- Field-access call: mod.fail(...) — look up field on obj type.
    if cn.kind == NODE_FIELD_EXPR then
        local obj_nid = cn.data[0]
        local on = ctx.nodes:get(obj_nid)
        if on.kind ~= NODE_IDENTIFIER then return false end
        local obj_tid = env_mod.lookup(ctx.scope, on.data[0])
        if not obj_tid then return false end
        local obj_resolved = types_mod.find(ctx, obj_tid)
        local fe = types_mod.table_field(ctx, obj_resolved, cn.data[1])
        if not fe then return false end
        return fn_returns_never(ctx, fe.type_id)
    end
    return false
end

-- Returns true if the block (or a nested non-function-defining sub-block) contains
-- a NODE_RETURN_STMT. Used in conjunction with is_definitely_returning to detect
-- functions whose body unconditionally diverges (every exit is via a never-returning
-- call) — those can be inferred as returning T_NEVER.
-- Does NOT descend into nested function definitions (an inner function's `return`
-- belongs to the inner function, not the outer).
--: (Ctx, integer, integer) -> boolean
function block_has_return_stmt(ctx, bs, bl)
    if bl == 0 then return false end
    for i = bs, bs + bl - 1 do
        local nid = ctx.ast_lists:get(i)
        local sn  = ctx.nodes:get(nid)
        if sn.kind == NODE_RETURN_STMT then
            return true
        elseif sn.kind == NODE_IF_STMT then
            local clause_start = sn.data[0]
            local clause_count = sn.data[1]
            for j = clause_start, clause_start + clause_count - 1 do
                local cn          = ctx.nodes:get(ctx.ast_lists:get(j))
                local block_start = cn.data[1]
                local block_len   = cn.data[2]
                if block_has_return_stmt(ctx, block_start, block_len) then
                    return true
                end
            end
        elseif sn.kind == NODE_WHILE_STMT or sn.kind == NODE_REPEAT_STMT then
            if block_has_return_stmt(ctx, sn.data[1], sn.data[2]) then return true end
        elseif sn.kind == NODE_FOR_NUM or sn.kind == NODE_FOR_IN then
            if block_has_return_stmt(ctx, sn.data[4], sn.data[5]) then return true end
        elseif sn.kind == NODE_DO_STMT then
            if block_has_return_stmt(ctx, sn.data[0], sn.data[1]) then return true end
        end
    end
    return false
end

-- Returns true if the block is definitely returning (every path exits via return or
-- a call to a never-returning function such as error()).
-- A block is definitely returning if:
--   1. It contains a return statement, OR
--   2. It contains a call to a never-returning function (e.g. error()), OR
--   3. Its last statement is an if-statement where there is an else branch and
--      ALL branches are definitely returning (recursive).
-- This is conservative: only return/never-call/if-all-branches are tracked.
--: (Ctx, integer, integer) -> boolean
local function is_definitely_returning(ctx, bs, bl)
    if bl == 0 then return false end
    for i = bs, bs + bl - 1 do
        local nid = ctx.ast_lists:get(i)
        local sn  = ctx.nodes:get(nid)
        if sn.kind == NODE_RETURN_STMT then
            return true
        end
        if is_never_call_stmt(ctx, nid) then
            return true
        end
        if sn.kind == NODE_IF_STMT and i == bs + bl - 1 then
            -- Last statement is an if: check all branches recursively.
            local clause_start = sn.data[0]
            local clause_count = sn.data[1]
            local has_else     = false
            local all_exit     = true
            for j = clause_start, clause_start + clause_count - 1 do
                local cn          = ctx.nodes:get(ctx.ast_lists:get(j))
                local test_nid    = cn.data[0]
                local block_start = cn.data[1]
                local block_len   = cn.data[2]
                if test_nid < 0 then has_else = true end
                if not is_definitely_returning(ctx, block_start, block_len) then
                    all_exit = false
                end
            end
            if has_else and all_exit then return true end
        end
    end
    return false
end

-- Apply any --:: unseal annotations at lines strictly before `before_line`
-- that have not yet been applied in this run.
-- Unseals rebind the named variable in ctx.scope to its opaque inner type T.
--: (Ctx, integer) -> ()
local function apply_unseals_before(ctx, before_line)
    if not ctx.ann then return end
    local results = ctx.ann.results
    if not results then return end
    local applied = ctx._unseal_applied
    for line, r in pairs(results) do
        --: { kind: integer, name_id: integer, type_id: integer, decl_var: boolean, newtype: boolean, ... }
        local r = r
        if r.kind == ANN_UNSEAL and line < before_line then
            if not (applied and applied[line]) then
                if not applied then
                    ctx._unseal_applied = {}
                    applied = ctx._unseal_applied
                end
                applied[line] = true
                --: integer
                local name_id = r.name_id
                local var_tid = env_mod.lookup(ctx.scope, name_id)
                local vname = intern_mod.get(ctx.pool, name_id) or "?"
                if not var_tid then
                    errors_mod.error(ctx.err, ctx.filename, line, 1,
                        "unseal: `" .. vname .. "` is not in scope")
                else
                    --: integer
                    local resolved = types_mod.find(ctx, var_tid)
                    local nt = ctx.types:get(resolved)
                    if nt.tag ~= TAG_NOMINAL then
                        errors_mod.error(ctx.err, ctx.filename, line, 1,
                            "unseal: `" .. vname .. "` is not an opaque type")
                    elseif not (ctx._opaque_nominals and ctx._opaque_nominals[nt.data[1]]) then
                        errors_mod.error(ctx.err, ctx.filename, line, 1,
                            "unseal: `" .. vname .. "` is a newtype, not an opaque type — unseal only works with $Opaque<T>")
                    else
                        local inner_tid = types_mod.find(ctx, nt.data[2])
                        env_mod.bind(ctx.scope, name_id, inner_tid)
                    end
                end
            end
        end
    end
end

--: (Ctx, integer, integer) -> boolean
gen_block = function(ctx, bs, bl)
    for i = bs, bs + bl - 1 do
        local sid = ctx.ast_lists:get(i)
        local sn  = ctx.nodes:get(sid)
        if ctx.ann and sn.line and sn.line > 0 then
            apply_unseals_before(ctx, sn.line)
        end
        gen_stmt(ctx, sid)
    end
    return is_definitely_returning(ctx, bs, bl)
end

-- If all fields of a table literal are same-kind literals (all LIT_INTEGER or all LIT_STRING),
-- rewrite each field's type_id to a TAG_ENUM_MEMBER so `Status.OK` displays as `Status.OK`.
-- enum_name_id is the intern ID of the variable name (e.g. "Status").
-- No-op when fields are mixed kinds, empty, or contain non-literals.
--: (Ctx, integer, integer) -> ()
local function try_promote_enum(ctx, tbl_tid, enum_name_id)
    local ot = ctx.types:get(types_mod.find(ctx, tbl_tid))
    if ot.tag ~= TAG_TABLE then return end
    local fs, fl = ot.data[0], ot.data[1]
    if fl == 0 then return end
    local lit_kind = nil
    local entries = {} --: { [integer]: { feid: integer, member_name_id: integer, lit_kind: integer, value: integer, ... }, ... }
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

-- Inject type aliases from a required module into the current scope.
-- aliases: { [name_string] = { body, params, nominal, resolved_bounds } } | nil
--: (Ctx, { [string]: TypeAlias, ... } | nil) -> ()
local function inject_imported_aliases(ctx, aliases)
    if not aliases then return end
    for name, alias in pairs(aliases) do
        local name_id = intern_mod.intern(ctx.pool, name)
        -- Only inject if not already bound (local declarations take precedence).
        if not env_mod.lookup_type(ctx.scope, name_id) then
            -- params from cri_read are already session name_ids (or nil).
            -- Convert params from name_id array to name_id array (already correct format).
            local params = nil
            if alias.params then
                params = {}
                for j, pid in ipairs(alias.params) do
                    params[j] = pid
                end
            end
            env_mod.bind_type(ctx.scope, name_id, {
                body            = alias.body,
                params          = params,
                nominal         = alias.nominal or false,
                resolved_bounds = alias.resolved_bounds,
            } --[[:! TypeAlias]])
        end
    end
end

--: { [integer]: (Ctx, integer) -> (), ... }
local StmtRule = {}

--: (Ctx, integer) -> ()
gen_stmt = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local rule = StmtRule[n.kind]
    if rule then rule(ctx, nid) end
end

--: (Ctx, integer) -> ()
StmtRule[NODE_EXPR_STMT] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local expr_nid = n.data[0]
    gen_expr(ctx, expr_nid)
    -- After the call, check if the callee is an assertion predicate.
    -- If so, narrow the argument in the current scope (continuation narrowing).
    local en = ctx.nodes:get(expr_nid)
    if en and en.kind == NODE_CALL_EXPR then
        local callee_n = ctx.nodes:get(en.data[0])
        if callee_n and callee_n.kind == NODE_IDENTIFIER then
            local callee_tid = env_mod.lookup(ctx.scope, callee_n.data[0])
            if callee_tid then
                callee_tid = types_mod.find(ctx, callee_tid)
                local pred = ctx.pool._assert_predicates
                    and ctx.pool._assert_predicates[callee_tid]
                if pred and en.data[2] > pred.param_idx then
                    local arg_nid = ctx.ast_lists:get(en.data[1] + pred.param_idx)
                    local arg_n = ctx.nodes:get(arg_nid)
                    if arg_n and arg_n.kind == NODE_IDENTIFIER then
                        local name_id = arg_n.data[0]
                        -- Bind the narrowed type directly in the current scope.
                        env_mod.bind(ctx.scope, name_id, pred.type_id)
                    end
                end
            end
        end
    end
end

--: (Ctx, integer) -> ()
StmtRule[NODE_LOCAL_STMT] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local ns, nl = n.data[0], n.data[1]
    local es, el = n.data[2], n.data[3]

    ctx._last_require_mod = nil
    ctx._last_require_aliases = nil
    ctx._last_multi_return_override = nil  -- clear before gen so stale values don't persist
    local rhs_types = el > 0 and gen_expr_list(ctx, es, el) or {}
    local stmt_require_mod = ctx._last_require_mod
    local stmt_require_aliases = ctx._last_require_aliases
    local stmt_require_exports = ctx._last_require_exports
    ctx._last_require_mod = nil
    ctx._last_require_aliases = nil
    ctx._last_require_exports = nil

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
        local override = ctx._last_multi_return_override
        ctx._last_multi_return_override = nil
        if override then
            call_ret_tid = override
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
            ctx._ann_warn_line = 0
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
            elseif el == 0 then
                -- Gap 9: `local x --: T` with no initializer is sound only if nil ∈ T
                -- (the runtime value is nil). Reject otherwise; user can write `T | nil`
                -- or provide an initializer.
                local unify_mod = require("lib.type.static.unify")
                if not unify_mod.try_unify(ctx, ctx.T_NIL, ann_tid) then
                    local name_str = intern_mod.get(ctx.pool, name_id) or "?"
                    report(ctx, n.line, n.col, E.LOCAL_NEEDS_INIT, {
                        name = name_str,
                        t    = types_mod.display(ctx, ann_tid),
                    })
                end
            end
            env_mod.bind(ctx.scope, name_id, ann_tid)
            -- Record annotation so assignments keep this as the permanent type.
            env_mod.bind_annotation(ctx.scope, name_id, ann_tid)
            ctx.def_sites[name_id] = { line = n.line, col = n.col }
            if stmt_require_mod and i == 0 and el == 1 then
                ctx.require_sources[name_id] = stmt_require_mod
                if stmt_require_exports then
                    if not ctx._require_exports then ctx._require_exports = {} end
                    ctx._require_exports[name_id] = stmt_require_exports
                end
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
                -- Eagerly compute the slot type when call_ret_tid is concrete.
                -- Concrete bindings allow if-not guards to narrow at constraint-gen time.
                local concrete = eager_slot(ctx, call_ret_tid, call_slot)
                if concrete then
                    -- Annotated callee: call_ret_tid is TAG_TUPLE or union-of-tuples.
                    bind_tid = concrete
                else
                    -- Unannotated callee: defer via C_INDEX until solve binds the tuple.
                    local slot_var = fresh_var(ctx)
                    emit(ctx, { C_INDEX, call_ret_tid,
                        types_mod.make_literal(ctx, LIT_INTEGER, call_slot),
                        slot_var, n.line, n.col })
                    bind_tid = slot_var
                end
                if not ctx._multi_ret then ctx._multi_ret = {} end
                ctx._multi_ret[name_id] = { source_tid = call_ret_tid, slot = call_slot, call_uid = nid }
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
                if stmt_require_exports then
                    if not ctx._require_exports then ctx._require_exports = {} end
                    ctx._require_exports[name_id] = stmt_require_exports
                end
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
    -- Inject type aliases from the required module into the current scope.
    if stmt_require_aliases then
        inject_imported_aliases(ctx, stmt_require_aliases)
    end
    -- Consume the annotation for this line so it doesn't spill to the next statement
    -- via the line-1 fallback in get_ann (e.g. `local t --: T \n local v = t.x`).
    consume_ann(ctx, n.line)
end

--: (Ctx, integer) -> ()
StmtRule[NODE_ASSIGN_STMT] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local rhs_count = n.data[3]
    ctx._last_multi_return_override = nil  -- clear before gen so stale values don't persist
    local rhs_types = gen_expr_list(ctx, n.data[2], rhs_count)
    -- Consume any preceding --: annotation so it doesn't spill to the next statement.
    -- We read it first so we can use it for NODE_FIELD_EXPR targets below.
    local stmt_ann = get_ann(ctx, n.line)

    local last_rhs_is_call = false
    if rhs_count > 0 then
        local last_rhs_nid = ctx.ast_lists:get(n.data[2] + rhs_count - 1)
        local last_rhs_n = ctx.nodes:get(last_rhs_nid)
        last_rhs_is_call = (last_rhs_n.kind == NODE_CALL_EXPR or last_rhs_n.kind == NODE_METHOD_CALL)
    end

    -- For call-derived bindings with correlated multi-return (like string.find),
    -- use _last_multi_return_override to slot-extract each target, mirroring LOCAL_STMT.
    local assign_call_ret_tid = nil
    if last_rhs_is_call then
        local override = ctx._last_multi_return_override
        ctx._last_multi_return_override = nil
        if override then
            assign_call_ret_tid = override
        else
            assign_call_ret_tid = rhs_types[rhs_count]
        end
    end

    for i = 0, n.data[1] - 1 do
        local target_nid = ctx.ast_lists:get(n.data[0] + i)
        local call_slot = (last_rhs_is_call and rhs_count > 0) and (i - (rhs_count - 1)) or -1
        local rhs_tid
        if call_slot >= 0 and assign_call_ret_tid then
            local concrete = eager_slot(ctx, assign_call_ret_tid, call_slot)
            if concrete then
                rhs_tid = concrete
            else
                local slot_var = fresh_var(ctx)
                emit(ctx, { C_INDEX, assign_call_ret_tid,
                    types_mod.make_literal(ctx, LIT_INTEGER, call_slot),
                    slot_var, n.line, n.col })
                rhs_tid = slot_var
            end
        else
            rhs_tid = rhs_types[i + 1] or (last_rhs_is_call and ctx.T_ANY or ctx.T_NIL)
        end
        local tn = ctx.nodes:get(target_nid)

        if tn.kind == NODE_IDENTIFIER then
            local name_id = tn.data[0]
            local existing = env_mod.lookup(ctx.scope, name_id)
            if existing then
                -- If the variable has an explicit annotation, that type is authoritative:
                -- always check rhs <: annotation_type regardless of any intermediate binding.
                -- Still rebind for flow-sensitivity (branch-join narrowing via reassignment).
                local ann_type = env_mod.lookup_annotation(ctx.scope, name_id)
                local check_against
                if ann_type then
                    check_against = ann_type
                else
                    local declared = env_mod.lookup_declared(ctx.scope, name_id)
                    check_against = types_mod.widen(ctx, declared or existing)
                end
                local ca_resolved = types_mod.find(ctx, check_against)
                local ca_tag = ctx.types:get(ca_resolved).tag
                if ca_tag ~= TAG_VAR then
                    emit(ctx, { C_SUB, rhs_tid, check_against, tn.line, tn.col })
                end
                env_mod.bind(ctx.scope, name_id, rhs_tid)
                -- Track correlated multi-return for narrowing propagation (e.g. x, y = f())
                if call_slot >= 0 and assign_call_ret_tid then
                    if not ctx._multi_ret then ctx._multi_ret = {} end
                    ctx._multi_ret[name_id] = { source_tid = assign_call_ret_tid, slot = call_slot, call_uid = nid }
                end
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
                -- If a --: annotation precedes this statement, it declares the expected
                -- type for the RHS.  Check rhs_tid <: ann_tid and use the annotation type
                -- as the canonical field type so subsequent uses see the declared type.
                -- The raw ann.type_id is an annotation-pool ID; resolve it to a checker
                -- type ID via resolve_annotation_type (same as LOCAL_STMT does).
                local ann_field_tid
                if stmt_ann and stmt_ann.kind == ANN_TYPE then
                    ctx._ann_warn_line = tn.line
                    ann_field_tid = resolve_annotation_type(ctx, stmt_ann.type_id)
                    ctx._ann_warn_line = 0
                    local ann_resolved = types_mod.find(ctx, ann_field_tid)
                    local ann_t = ctx.types:get(ann_resolved)
                    if ann_t.tag ~= TAG_VAR and ann_t.tag ~= TAG_ROWVAR then
                        emit(ctx, { C_SUB, rhs_tid, ann_field_tid, tn.line, tn.col })
                    end
                end
                local fe = types_mod.table_field(ctx, obj_tid, field_id)
                if fe then
                    -- Readonly check: assignment to a readonly field is a type error
                    if band(fe.flags, FLAG_READONLY) ~= 0 then
                        local fname = intern_mod.get(ctx.pool, field_id) or "?"
                        report(ctx, tn.line, tn.col, E.FIELD_READONLY,
                            { field = fname })
                    end
                    -- Re-assignment: check type compatibility (widen to base type first).
                    -- When an annotation is present it was already checked above; skip the
                    -- inferred-type check to avoid a duplicate (or conflicting) constraint.
                    if not ann_field_tid then
                        local expected = types_mod.widen(ctx, fe.type_id)
                        local et = ctx.types:get(types_mod.find(ctx, expected))
                        if et.tag ~= TAG_VAR then
                            emit(ctx, { C_SUB, rhs_tid, expected, tn.line, tn.col })
                        end
                    end
                else
                    -- Add field.  Use the annotation type as the field's stored type when
                    -- one is present; this makes the declared type visible to later reads.
                    local field_tid = ann_field_tid or rhs_tid
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
                    fields[#fields + 1] = types_mod.make_field(ctx, field_id, field_tid, field_flags(ctx, field_id))
                    local new_tbl = types_mod.make_table(ctx, fields, indexers, rv, meta)
                    local ot2 = ctx.types:get(obj_tid)
                    local new_t = ctx.types:get(new_tbl)
                    for k = 0, 6 do ot2.data[k] = new_t.data[k] end
                end
            elseif ot.tag == TAG_INTERSECTION then
                -- Readonly check for fields accessed through an intersection type.
                -- Search each member for the field; if any member declares it readonly,
                -- the write is an error (readonly is preserved across intersection).
                for j = ot.data[0], ot.data[0] + ot.data[1] - 1 do
                    local mid = types_mod.find(ctx, ctx.lists:get(j))
                    local mt = ctx.types:get(mid)
                    if mt.tag == TAG_TABLE then
                        local mfe = types_mod.table_field(ctx, mid, field_id)
                        if mfe and band(mfe.flags, FLAG_READONLY) ~= 0 then
                            local fname = intern_mod.get(ctx.pool, field_id) or "?"
                            report(ctx, tn.line, tn.col, E.FIELD_READONLY,
                                { field = fname })
                            break
                        end
                    end
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
                    -- Non-literal key: check rhs against indexer value type if known,
                    -- or add an indexer to open tables (loop-populated: t[i] = v).
                    local is2, il2 = ot.data[2], ot.data[3]
                    if il2 > 0 then
                        -- Check first indexer pair's value type
                        local idx_val = types_mod.find(ctx, ctx.lists:get(is2 + 1))
                        local ivt = ctx.types:get(idx_val)
                        if ivt.tag ~= TAG_VAR then
                            emit(ctx, { C_SUB, rhs_tid, idx_val, tn.line, tn.col })
                        end
                    else
                        -- No existing indexer: add one for this key/value type pair.
                        -- Only for open tables (row_var_id != -1); closed tables reject
                        -- writes to undeclared index patterns.
                        local rv = ot.data[4]
                        if rv ~= -1 then
                            local key_wid = types_mod.widen(ctx, key_tid)
                            local fields, indexers, meta = {}, { key_wid, rhs_tid }, {}
                            local fs, fl = ot.data[0], ot.data[1]
                            for j = fs, fs + fl - 1 do fields[#fields + 1] = ctx.lists:get(j) end
                            for j = ot.data[5], ot.data[5] + ot.data[6] - 1 do meta[#meta + 1] = ctx.lists:get(j) end
                            local new_tbl = types_mod.make_table(ctx, fields, indexers, rv, meta)
                            -- Re-fetch ot after make_table (arena:grow() may have moved it)
                            local ot2 = ctx.types:get(obj_tid)
                            local new_t = ctx.types:get(new_tbl)
                            for k = 0, 6 do ot2.data[k] = new_t.data[k] end
                        end
                    end
                end
            end
        end
    end
    -- Consume the annotation so it doesn't spill to the next statement via the
    -- line-1 fallback in get_ann.
    consume_ann(ctx, n.line)
end

--: (Ctx, integer) -> ()
StmtRule[NODE_DO_STMT] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local saved = ctx.scope
    ctx.scope = env_mod.child(ctx.scope)
    gen_block(ctx, n.data[0], n.data[1])
    ctx.scope = saved
end

--: (Ctx, integer) -> ()
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

--: (Ctx, integer) -> ()
StmtRule[NODE_REPEAT_STMT] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local saved = ctx.scope
    ctx.scope = env_mod.child(ctx.scope)
    gen_block(ctx, n.data[1], n.data[2])  -- data[1]=bs, data[2]=bl
    gen_expr(ctx, n.data[0])              -- data[0]=test condition
    ctx.scope = saved
end

-- Collect end-of-branch types for variables that already existed in base_scope.
--: (Ctx, Scope, Scope) -> { [integer]: integer, ... }
local function branch_scope_diff(ctx, branch_scope, base_scope)
    local result = {}
    local s = branch_scope
    while s and s ~= base_scope do
        for name_id, type_id in pairs(s.bindings) do
            -- Skip narrowing-derived bindings: these are scope-scoped (temporary) type
            -- refinements set by apply_narrowed. They should not be treated as real
            -- assignments made inside the branch, and must not be propagated to the
            -- join point or continuation scope via branch_scope_diff.
            if result[name_id] == nil and env_mod.lookup(base_scope, name_id) ~= nil
               and not (s.narrowed_names and s.narrowed_names[name_id]) then
                result[name_id] = type_id
            end
        end
        s = s.parent
    end
    return result
end

--: (Ctx, integer) -> ()
StmtRule[NODE_IF_STMT] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local narrow_mod = require("lib.type.static.narrow")
    local saved = ctx.scope

    --: { [integer]: integer }
    local guard_narrowings = {}  -- Cat E: negated narrowings from exiting clauses
    --: { [integer]: { [integer]: integer } }
    local branch_ends      = {}  -- { name_id -> type_id } per non-exiting clause
    -- Per non-exiting branch, the narrowing types applied at branch ENTRY (parallel
    -- to branch_ends). Captured at branch entry so the join needn't hold scope
    -- references and walk parent chains later. { name_id -> type_id } per branch.
    --: { [integer]: { [integer]: integer } }
    local branch_entry_narrowings = {}
    --: { [integer]: boolean }
    local branch_narrowed  = {}  -- { name_id -> true } names narrowed at non-exiting branch entry
    --: { [integer]: integer }
    local pass_through_neg = {}  -- negated narrowings for the implicit pass-through path
    local has_else         = false
    local disc_names       = {}  -- name_ids narrowed via field_disc in an exiting arm

    for i = n.data[0], n.data[0] + n.data[1] - 1 do
        local cn          = ctx.nodes:get(ctx.ast_lists:get(i))
        local test_nid    = cn.data[0]
        local block_start = cn.data[1]
        local block_len   = cn.data[2]

        local entry_narrowings  --: { [integer]: integer, ... } | nil
        if test_nid >= 0 then
            gen_expr(ctx, test_nid)
            local narrowed = narrow_mod.narrow_scope(ctx, test_nid, true)
            ctx.scope = narrow_mod.apply_narrowed(ctx, narrowed)
            entry_narrowings = narrowed
        else
            has_else = true
            -- Apply all accumulated negated narrowings from preceding if/elseif
            -- conditions: the else branch is reachable only when all prior
            -- conditions were false (both exiting Cat-E and non-exiting ones).
            local else_neg = {}
            for name_id, type_id in pairs(guard_narrowings) do
                else_neg[name_id] = type_id
            end
            for name_id, type_id in pairs(pass_through_neg) do
                if else_neg[name_id] == nil then
                    else_neg[name_id] = type_id
                end
            end
            if next(else_neg) then
                -- Direct assignment triggers a typechecker bug when else_neg is
                -- built by pairs() loops ($PairsReturn leaks into call result type).
                -- Intermediate variable breaks the constraint chain.
                local else_scope = narrow_mod.apply_narrowed(ctx, else_neg)
                ctx.scope = else_scope
                entry_narrowings = else_neg
            else
                ctx.scope = env_mod.child(saved)
            end
        end

        gen_block(ctx, block_start, block_len)
        local end_scope = ctx.scope

        -- Detect unconditional exit (return/break/never-call as last statement,
        -- or nested if where all branches exit).
        local exits = is_definitely_returning(ctx, block_start, block_len)
        if not exits and block_len > 0 then
            local last_n = ctx.nodes:get(ctx.ast_lists:get(block_start + block_len - 1))
            exits = (last_n.kind == NODE_BREAK_STMT or last_n.kind == NODE_GOTO_STMT)
        end

        if not exits then
            local diff = branch_scope_diff(ctx, end_scope, saved)
            branch_ends[#branch_ends + 1] = diff
            -- Capture entry narrowings for names not reassigned in this branch.
            -- These contribute their narrowed type to the post-if join even though
            -- they don't appear in the diff (no reassignment happened).
            local en = {}
            if entry_narrowings then
                for name_id, type_id in pairs(entry_narrowings) do
                    if diff[name_id] == nil then
                        en[name_id] = type_id
                        branch_narrowed[name_id] = true
                    end
                end
            end
            branch_entry_narrowings[#branch_entry_narrowings + 1] = en
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
                -- Intersect with any previously-accumulated guard narrowings: apply this
                -- arm's negation on top of the accumulated type so that each successive
                -- exiting arm subtracts its matched variant from the running result.
                -- Example: Circle|Rect|Tri → arm1 exits (circle) → Rect|Tri in guard;
                --          arm2 exits (rect)  → apply neg(rect) to Rect|Tri → Tri.
                local arm_info = narrow_mod.extract_narrowing_info(ctx, test_nid)
                -- Track name_ids discriminated via field_disc for exhaustiveness checking.
                if arm_info and arm_info.kind == "field_disc" then
                    disc_names[arm_info.name_id] = true
                end
                for name_id, type_id in pairs(neg) do
                    if guard_narrowings[name_id] == nil then
                        -- First exiting arm for this binding: use the negation as-is.
                        guard_narrowings[name_id] = type_id
                    else
                        -- Subsequent exiting arm: apply the negation info against the
                        -- already-accumulated guard type (intersection of exclusions).
                        if arm_info then
                            guard_narrowings[name_id] = narrow_mod.apply_narrowing_info(
                                ctx, arm_info, guard_narrowings[name_id], false)
                        else
                            -- No arm_info (compound condition, e.g. OR): intersect the
                            -- accumulated guard with the negation from this arm.
                            -- Keep only those guard members that also appear in neg[name_id].
                            guard_narrowings[name_id] = types_mod.filter_union(
                                ctx, guard_narrowings[name_id], type_id)
                        end
                    end
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

    -- Exhaustiveness check: warn when a discriminated union if-chain has no else
    -- and all branches exit (Cat E only) but the continuation type is not never.
    -- Only fires for field_disc narrowing (tagged union dispatch), not nil-checks.
    if not has_else and #branch_ends == 0 and next(disc_names) then
        for name_id in pairs(disc_names) do
            local cont_tid = guard_narrowings[name_id]
            if cont_tid then
                cont_tid = types_mod.find(ctx, cont_tid)
                if cont_tid ~= ctx.T_NEVER then
                    local var_name = intern_mod.get(ctx.pool, name_id) or "?"
                    -- Check whether the remaining type contains `any`. If so, emit a
                    -- specific warning instead of the generic non-exhaustive one for
                    -- the `any` member: `any` makes exhaustiveness unverifiable, so
                    -- suggesting "add a _ branch" is misleading — the real fix is to
                    -- eliminate `any` from the type.
                    local cont_t = ctx.types:get(cont_tid)
                    local has_any = (cont_t.tag == TAG_ANY)
                    local non_any_members = {}  -- type_ids of remaining non-any members
                    if not has_any and cont_t.tag == TAG_UNION then
                        for i = cont_t.data[0], cont_t.data[0] + cont_t.data[1] - 1 do
                            local m_tid = types_mod.find(ctx, ctx.lists:get(i))
                            local m_t = ctx.types:get(m_tid)
                            if m_t.tag == TAG_ANY then
                                has_any = true
                            else
                                non_any_members[#non_any_members + 1] = m_tid
                            end
                        end
                    end
                    if has_any then
                        warn(ctx, n.line, n.col, E.MATCH_CONTAINS_ANY, {})
                        -- If there are also non-any unhandled members, still emit
                        -- the generic non-exhaustive warning for those.
                        if #non_any_members > 0 then
                            local remaining_parts = {}
                            for _, m_tid in ipairs(non_any_members) do
                                remaining_parts[#remaining_parts + 1] =
                                    types_mod.display(ctx, m_tid)
                            end
                            local remaining = table.concat(remaining_parts, " | ")
                            warn(ctx, n.line, n.col, E.NON_EXHAUSTIVE,
                                { name = var_name, remaining = "case(s): " .. remaining })
                        end
                    else
                        local remaining = types_mod.display(ctx, cont_tid)
                        warn(ctx, n.line, n.col, E.NON_EXHAUSTIVE,
                            { name = var_name, remaining = "case(s): " .. remaining })
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
    -- Also consider names narrowed at entry of a non-exiting branch (without
    -- reassignment) — but only when the same name was reassigned in some OTHER
    -- branch. Without a reassignment somewhere, the post-if type is just the
    -- pre-if union and rebinding it would (a) be redundant and (b) accumulate
    -- redundant TAG_UNION nodes across many sequential if-stmts on the same
    -- variable, blowing up downstream constraint solving.
    for name_id in pairs(branch_narrowed) do
        if changed[name_id] then  -- already marked by some branch's reassignment
            -- no-op; it's already in changed
        else
            -- Check if any branch_ends has this name (some other branch reassigned)
            local reassigned_elsewhere = false
            for i = 1, #branch_ends do
                if branch_ends[i][name_id] ~= nil then
                    reassigned_elsewhere = true
                    break
                end
            end
            if reassigned_elsewhere then changed[name_id] = true end
        end
    end

    if next(changed) then
        local join = {}
        for name_id in pairs(changed) do
            local post_guard = env_mod.lookup(ctx.scope, name_id)
            --: { [integer]: integer }
            local members = {}
            --: { [integer]: boolean }
            local seen_m = {}
            --: (integer) -> ()
            local function add_member(t)
                t = types_mod.find(ctx, t)
                if t and not seen_m[t] then seen_m[t] = true; members[#members + 1] = t end
            end
            for i = 1, #branch_ends do
                local et = branch_ends[i]
                local en = branch_entry_narrowings[i]
                -- Order: reassigned (et) > entry-narrowed (en) > post_guard.
                -- Pre-computing entry narrowings into `en` avoids holding scope
                -- references for later lookup (which can recurse pathologically).
                local t = et[name_id] or en[name_id] or post_guard
                if t ~= nil then add_member(t) end
            end
            if not has_else then
                local pt = pass_through_neg[name_id] or post_guard
                if pt ~= nil then add_member(pt) end
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

--: (Ctx, integer) -> ()
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

--: (Ctx, integer) -> ()
StmtRule[NODE_FOR_IN] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local iter_types = gen_expr_list(ctx, n.data[2], n.data[3])
    local saved = ctx.scope
    ctx.scope = env_mod.child(ctx.scope)
    local ns, nl = n.data[0], n.data[1]

    -- Determine the iterator function type and call-args (state, initial_key).
    -- For a single-expr explist (e.g. pairs(t)/ipairs(t)), the expression returns
    -- an iterator triple (iter_fn, state, initial_key) as a TAG_TUPLE.  We extract
    -- iter_fn via C_INDEX so the solver can project it once the triple is resolved.
    -- For multi-expr explists (e.g. `for k,v in next, t, nil`), iter_types already
    -- contains the three components directly.
    local iter_fn_tid, state_tid, key0_tid
    if n.data[3] == 1 and #iter_types >= 1 then
        -- Single-expr: explist returns a triple (may be TAG_VAR pointing at a tuple).
        local triple_var = iter_types[1]
        iter_fn_tid = fresh_var(ctx)
        emit(ctx, { C_INDEX, triple_var,
            types_mod.make_literal(ctx, LIT_INTEGER, 0),
            iter_fn_tid, n.line, n.col })
        state_tid = fresh_var(ctx)
        emit(ctx, { C_INDEX, triple_var,
            types_mod.make_literal(ctx, LIT_INTEGER, 1),
            state_tid, n.line, n.col })
        key0_tid = fresh_var(ctx)
        emit(ctx, { C_INDEX, triple_var,
            types_mod.make_literal(ctx, LIT_INTEGER, 2),
            key0_tid, n.line, n.col })
    else
        -- Multi-expr: iter_types[1] = iter_fn, [2] = state, [3] = initial_key.
        iter_fn_tid = iter_types[1] or ctx.T_ANY
        state_tid   = iter_types[2] or ctx.T_NIL
        key0_tid    = iter_types[3] or ctx.T_NIL
    end

    -- Emit C_CALLABLE for the iterator function call: iter_fn(state, initial_key).
    -- The return type (a tuple of loop-var types) is projected slot-by-slot into
    -- individual loop variables via C_INDEX.
    local loop_ret_var = fresh_var(ctx)
    emit(ctx, { C_BIND_GENERICS, iter_fn_tid, { state_tid, key0_tid },
        loop_ret_var, n.line, n.col })
    emit(ctx, { C_CHECK_ARGS,    iter_fn_tid, { state_tid, key0_tid },
        loop_ret_var, n.line, n.col })

    for i = 0, nl - 1 do
        local name_id = ctx.ast_lists:get(ns + i)
        local slot_var = fresh_var(ctx)
        emit(ctx, { C_INDEX, loop_ret_var,
            types_mod.make_literal(ctx, LIT_INTEGER, i),
            slot_var, n.line, n.col })
        env_mod.bind(ctx.scope, name_id, slot_var)
    end

    gen_block(ctx, n.data[4], n.data[5])
    ctx.scope = saved
end

--: (Ctx, integer) -> ()
StmtRule[NODE_RETURN_STMT] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local ret_tids = gen_expr_list(ctx, n.data[0], n.data[1])
    local ret_var = ctx.return_vars[#ctx.return_vars]
    if ret_var then
        local ret_tid
        if #ret_tids > 1 then
            -- Pack multiple return values into a TAG_TUPLE so per-slot
            -- inference works at call sites (`local a, b = f()` projects via
            -- C_INDEX). Single returns stay scalar so existing code paths
            -- (annotated returns, single-value flows) are unchanged.
            ret_tid = types_mod.make_tuple(ctx, ret_tids)
        else
            ret_tid = ret_tids[1] or ctx.T_NIL
        end
        emit(ctx, { C_RETURN, ret_tid, ret_var, n.line, n.col })
    end
end

--: (Ctx, integer) -> ()
StmtRule[NODE_BREAK_STMT] = function(_ctx, _nid) end

--: (Ctx, integer) -> ()
StmtRule[NODE_FUNC_DECL] = function(ctx, nid)
    local n = ctx.nodes:get(nid)
    local name_n = ctx.nodes:get(n.data[0])
    local has_vararg = (n.flags % (FLAG_VARARG * 2)) >= FLAG_VARARG

    -- Check for --:: template on the preceding line.
    if ctx._template_lines and ctx._template_lines[n.line - 1] then
        -- NODE_FUNC_DECL layout: data[1]=ps, data[2]=pl, data[3]=bs, data[4]=bl.
        local fn_tid = gen_function_skip_body(ctx, n.data[1], n.data[2], has_vararg)
        if not ctx._template_fns then ctx._template_fns = {} end
        local tinfo = {
            ps = n.data[1], pl = n.data[2], bs = n.data[3], bl = n.data[4],
            has_vararg = has_vararg,
        }
        -- Stable fn_tid: if a prescan stub exists, mutate it in-place so call sites
        -- that already hold the stub type ID pick up the template marker.
        local stable_tid = fn_tid
        if name_n.kind == NODE_IDENTIFIER then
            local name_id = name_n.data[0]
            local existing = env_mod.lookup(ctx.scope, name_id) or 0
            if existing ~= 0 then
                local eid = types_mod.find(ctx, existing)
                local stub_t = ctx.types:get(eid)
                local real_t = ctx.types:get(fn_tid)
                if stub_t.tag == TAG_FUNCTION and real_t.tag == TAG_FUNCTION then
                    for k = 0, 6 do stub_t.data[k] = real_t.data[k] end
                    stable_tid = eid
                end
            end
            env_mod.bind(ctx.scope, name_id, fn_tid)
            ctx.def_sites[name_id] = { line = n.line, col = n.col }
        end
        ctx._template_fns[stable_tid] = tinfo
        if stable_tid ~= fn_tid then
            ctx._template_fns[fn_tid] = tinfo
        end
        return
    end

    local ann = get_ann(ctx, n.line)
    local ann_fn_tid = nil
    local ann_isect_tid = nil  -- non-nil when annotation is an intersection of functions
    if ann and ann.kind == ANN_TYPE then
        ctx._ann_warn_line = n.line
        local resolved = resolve_annotation_type(ctx, ann.type_id)
        ctx._ann_warn_line = 0
        local rt = ctx.types:get(types_mod.find(ctx, resolved))
        if rt.tag == TAG_FUNCTION then
            ann_fn_tid = resolved
        elseif rt.tag == defs.TAG_INTERSECTION then
            -- Intersection of functions: check body against each overload independently.
            -- The function name will be bound to the intersection type.
            ann_isect_tid = types_mod.find(ctx, resolved)
            check_body_against_intersection(ctx, n.data[1], n.data[2], n.data[3], n.data[4],
                has_vararg, ann_isect_tid, n.line, n.col)
        end
    end
    local fn_tid = ann_isect_tid or
        gen_function(ctx, n.data[1], n.data[2], n.data[3], n.data[4], has_vararg, ann_fn_tid, n.line, n.col)
    -- Function statements ALWAYS require a signature (`--:` line above). If no
    -- function-typed annotation was found, record for the post-pass diagnostic.
    if not ann_fn_tid and not ann_isect_tid then
        ctx._missing_signatures = ctx._missing_signatures or {}
        local sig_name_id = -1
        if name_n.kind == NODE_IDENTIFIER then sig_name_id = name_n.data[0] end
        ctx._missing_signatures[#ctx._missing_signatures + 1] = {
            line = n.line, col = n.col,
            source_kind = "stmt",
            name_id = sig_name_id,
            fn_tid = fn_tid,
        }
    end

    if name_n.kind == NODE_IDENTIFIER then
        local name_id = name_n.data[0]
        local existing = env_mod.lookup(ctx.scope, name_id)
        if existing and not ann_isect_tid then
            -- Mutate the prescan stub in-place: copy the real function's data fields so that
            -- any C_CALLABLE constraints inside the body (recursive calls) that already hold
            -- the stub type ID now resolve directly to the real function's param/return vars.
            -- This avoids a C_UNIFY chain that aliases the stub's return var with the real
            -- return var in a way that conflicts after solve_return widens the return type.
            -- (Skipped when annotation is an intersection: the body was already checked
            -- per-overload, so the prescan stub is just replaced by the intersection type.)
            local stub_t = ctx.types:get(existing)
            local real_t = ctx.types:get(fn_tid)
            if stub_t.tag == TAG_FUNCTION and real_t.tag == TAG_FUNCTION then
                for k = 0, 6 do stub_t.data[k] = real_t.data[k] end
            else
                emit(ctx, { C_UNIFY, fn_tid, existing, n.line, n.col })
            end
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
    -- Use fresh TAG_VARs for params so that C_UNIFY with the real function type
    -- merges them (var→var) rather than binding real params to T_ANY.
    -- Callsite argument types then flow through the merged vars into the function body.
    local param_vars = {}
    for i = 1, pl do param_vars[i] = types_mod.make_var(ctx, ctx.scope.level) end
    local ret_var = types_mod.make_var(ctx, ctx.scope.level)
    return types_mod.make_func(ctx, param_vars, { ret_var }, -1)
end

--: (Ctx, integer, integer) -> ()
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

-- Generate constraints for a template function body re-check at a call site.
-- Binds params to concrete types provided by the caller, skips annotation
-- processing, then checks the body and returns a function type_id with the
-- inferred return type.
--: (Ctx, integer, integer, integer, integer, boolean, { [integer]: integer, ... }) -> integer
gen_function_for_template = function(ctx, ps, pl, bs, bl, has_vararg, concrete_param_tids)
    local fn_scope = env_mod.child(ctx.scope)
    local param_tids = {} --: { [integer]: integer, ... }
    for i = 0, pl - 1 do
        local name_id = ctx.ast_lists:get(ps + i)
        local pt_id = concrete_param_tids[i + 1] or types_mod.make_var(ctx, fn_scope.level)
        env_mod.bind(fn_scope, name_id, pt_id)
        param_tids[#param_tids + 1] = pt_id
    end
    if has_vararg then
        local dots_id = intern_mod.intern(ctx.pool, "...")
        env_mod.bind(fn_scope, dots_id, ctx.T_ANY)
    end
    local saved = ctx.scope
    ctx.scope = fn_scope
    local ret_var = types_mod.make_var(ctx, saved.level)
    ctx.return_vars[#ctx.return_vars + 1] = ret_var
    gen_prescan_block(ctx, bs, bl)
    gen_block(ctx, bs, bl)
    ctx.return_vars[#ctx.return_vars] = nil
    ctx.scope = saved
    return types_mod.make_func(ctx, param_tids, { ret_var }, ctx.T_ANY, {})
end

-- ---------------------------------------------------------------------------
-- Declaration file loader (for --:: require "mod.path")
-- ---------------------------------------------------------------------------
-- process_type_decls is defined below; load_decl_file calls it, so we need
-- to pre-declare the variable and assign the function body separately to
-- avoid the Lua gotcha where `local function f` inside an expression scope
-- creates a new local that shadows the forward-declared one.
--
-- Lua scoping rule: `local x = expr` does NOT put x in scope inside expr.
-- Therefore `load_decl_file` closes over the pre-declared `process_type_decls`
-- slot, and the assignment below fills that slot before any call can occur.
local process_type_decls

-- Load a declaration file into ctx.scope.
-- Translates "lib.js_types" → "lib/js_types.lua", parses it, and
-- processes its type alias and declare bindings using process_type_decls.
-- Also tries "lib/js_types/init.lua" if the .lua path does not exist
-- (directory packages follow the ?/init.lua convention).
--: (Ctx, string) -> nil
local function load_decl_file(ctx, mod_name)
    local parse_mod = require("lib.type.static.parse")
    -- Resolve module name to file path: "lib.js_types" → "lib/js_types.lua"
    local dot_slash = mod_name:gsub("%.", "/")
    local rel_path = dot_slash .. ".lua"
    local f = io.open(rel_path, "r")
    if not f then
        -- Fallback: directory package — try "lib/js_types/init.lua"
        rel_path = dot_slash .. "/init.lua"
        f = io.open(rel_path, "r")
    end
    if not f then return end
    local source = f:read("*a") --[[:! string]]
    f:close()

    local ok_p, pr = pcall(parse_mod.parse, source, rel_path, ctx.pool)
    if not ok_p then return end
    -- pcall erases the parse result type; force-cast to the fields we need.
    local pr_any = pr --[[:! { lexer: { annotations: unknown, ... }, ... }]]
    local ok_a, ar = pcall(ann_mod.parse_annotations, pr_any.lexer.annotations, ctx.pool, rel_path)
    if not ok_a then return end

    -- Temporarily swap ctx.ann and ctx.filename so process_type_decls operates
    -- on the loaded file's annotations and reports errors under the right filename.
    -- process_type_decls will report ar.warnings and ar.parse_errors under rel_path.
    local saved_ann      = ctx.ann
    local saved_filename = ctx.filename
    ctx.ann      = ar --[[:! AnnResult]]
    ctx.filename = rel_path
    process_type_decls(ctx)
    ctx.ann      = saved_ann
    ctx.filename = saved_filename
end

-- ---------------------------------------------------------------------------
-- Type declaration processing
-- ---------------------------------------------------------------------------

--: (Ctx) -> { [integer]: { r: { kind: integer, name_id: integer, type_id: integer, decl_var: boolean, newtype: boolean, ... }, line: integer, ... }, ... } | nil
process_type_decls = function(ctx)
    if not ctx.ann then return nil end
    -- After this guard, ctx.ann is narrowed to AnnResult (field_presence narrowing on ctx).
    local ann = ctx.ann
    if ann.warnings then
        for _, w in ipairs(ann.warnings) do
            errors_mod.warning(ctx.err, ctx.filename, w.line or 0, w.col or 0, w.msg)
        end
    end
    if ann.parse_errors then
        for _, e in ipairs(ann.parse_errors) do
            errors_mod.error(ctx.err, ctx.filename, e.line or 0, e.col or 0, e.msg)
        end
    end
    local decls = {} --: { [integer]: { kind: integer, name_id: integer, type_id: integer, decl_var: boolean, newtype: boolean, type_params_start: integer, type_params_len: integer, type_bounds_start: integer, type_bounds_len: integer, type_defaults_start: integer, type_defaults_len: integer, ... }, ... }
    -- decl_lines uses table-reference keys (result records as keys).
    -- { [unknown]: integer } captures this: any key (including table refs) maps to integer.
    local decl_lines = {} --: { [unknown]: integer }
    local module_decls = {} --: { [integer]: { kind: integer, type_id: integer, mod_name: string, ... }, ... }
    local module_decl_lines = {} --: { [unknown]: integer }
    -- require_decl_lines: result record → source line (same pattern as decl_lines).
    local require_decl_lines = {} --: { [unknown]: integer }
    local require_decls = {} --: { [integer]: { kind: integer, mod_name: string, ... }, ... }
    local augment_decls = {} --: { [integer]: { kind: integer, name_id: integer, type_id: integer, ... }, ... }
    local augment_decl_lines = {} --: { [unknown]: integer }
    for line, result in pairs(ann.results) do
        --: { kind: integer, name_id: integer, type_id: integer, decl_var: boolean, newtype: boolean, type_params_start: integer, type_params_len: integer, type_bounds_start: integer, type_bounds_len: integer, type_defaults_start: integer, type_defaults_len: integer, mod_name: string, ... }
        local result = result
        if result.kind == ANN_DECL then
            decls[#decls + 1] = result
            decl_lines[result] = line
        elseif result.kind == ANN_MODULE then
            module_decls[#module_decls + 1] = result
            module_decl_lines[result] = line
        elseif result.kind == ANN_REQUIRE then
            require_decls[#require_decls + 1] = result
            require_decl_lines[result] = line
        elseif result.kind == ANN_AUGMENT then
            augment_decls[#augment_decls + 1] = result
            augment_decl_lines[result] = line
        elseif result.kind == ANN_TEMPLATE then
            -- Record the line so gen_function can detect template markers.
            if not ctx._template_lines then ctx._template_lines = {} end
            ctx._template_lines[line] = true
        end
    end
    -- Sort by source line so forward references resolve in file order.
    table.sort(decls, function(a, b) return (decl_lines[a] or 0) < (decl_lines[b] or 0) end)
    -- Sort require_decls by line so they load in source order.
    if #require_decls > 1 then
        local rl = require_decl_lines
        table.sort(require_decls, function(a, b) return (rl[a] or 0) < (rl[b] or 0) end)
    end

    -- Identify decls whose body is a bare TAG_TYPEOF — these must be deferred until after
    -- gen_block, because typeof looks up value bindings that don't exist during prescan.
    local typeof_decls = {} --: { [integer]: { r: { kind: integer, name_id: integer, type_id: integer, decl_var: boolean, newtype: boolean, ... }, line: integer, ... }, ... }

    -- Pass -1: load --:: require "mod.path" declaration files before the file's own
    -- declarations are processed.  This ensures types declared in the loaded files are
    -- in scope when Pass 0–2b resolve the current file's type aliases and variables.
    for _, r in ipairs(require_decls) do
        load_decl_file(ctx, r.mod_name)
    end

    -- Pass 0: preliminary module_types population (before alias bodies are resolved).
    -- This ensures $Require<"mod"> in type alias bodies (Pass 2a) can look up modules
    -- declared in the same file.  Module types that reference named aliases (like Signal)
    -- may resolve to unknown here; errors are silently discarded because Pass 2mod
    -- (after Pass 2a) re-resolves them correctly with all aliases in scope.
    do
        local saved_err = ctx.err
        local pass0_err = errors_mod.new_ctx()
        pass0_err.source_lines = saved_err.source_lines
        ctx.err = pass0_err
        for _, r in ipairs(module_decls) do
            ctx.module_types[r.mod_name] = resolve_annotation_type(ctx, r.type_id)
        end
        ctx.err = saved_err
        -- pass0_err and any "undefined type" diagnostics it collected are discarded.
    end

    -- Pass 1: register all type alias names (body=nil) so forward refs are visible.
    for _, r in ipairs(decls) do
        if not r.decl_var then
            local params = nil
            if r.type_params_len and r.type_params_len > 0 then
                params = {}
                for i = r.type_params_start, r.type_params_start + r.type_params_len - 1 do
                    params[#params + 1] = ann.lists:get(i)
                end
            end
            -- Extract raw (annotation-arena) bound type IDs, if any.
            -- -1 entries are "no bound" sentinels. resolved_bounds is filled in Pass 2a.
            local raw_bounds = nil
            if r.type_bounds_len and r.type_bounds_len > 0 then
                raw_bounds = {}
                for i = r.type_bounds_start, r.type_bounds_start + r.type_bounds_len - 1 do
                    raw_bounds[#raw_bounds + 1] = ann.lists:get(i)
                end
            end
            -- Extract raw (annotation-arena) default type IDs, if any.
            -- -1 entries are "no default" sentinels. resolved_defaults is filled in Pass 2a.
            local raw_defaults = nil
            if r.type_defaults_len and r.type_defaults_len > 0 then
                raw_defaults = {}
                for i = r.type_defaults_start, r.type_defaults_start + r.type_defaults_len - 1 do
                    raw_defaults[#raw_defaults + 1] = ann.lists:get(i)
                end
            end
            local pending_alias --[[: unknown]] = {
                body         = nil,
                params       = params,
                nominal      = r.newtype or false,
                raw_bounds   = raw_bounds,    -- annotation-arena IDs; resolved in Pass 2a
                raw_defaults = raw_defaults,  -- annotation-arena IDs; resolved in Pass 2a
            }
            env_mod.bind_type(ctx.scope, r.name_id, pending_alias --[[:! TypeAlias]])
        end
    end

    -- Pass 2a: resolve type alias bodies (non-decl_var) before variable declarations
    -- reference them, so that `--:: declare x = SomeAlias` sees the fully-resolved body.
    -- Decls whose body is a bare TAG_TYPEOF are deferred to after gen_block, because they
    -- look up value bindings that don't exist during prescan.
    for _, r in ipairs(decls) do
        if not r.decl_var then
            -- Detect bare typeof body — defer until value bindings are in scope.
            local at = ann.types:get(r.type_id)
            if at.tag == TAG_TYPEOF then
                --: integer
                local r_line = decl_lines[r]
                typeof_decls[#typeof_decls + 1] = { r = r, line = r_line }
            else
                -- Warn on function type declarations with unnamed parameters.
                local fn_at
                if at.tag == defs.TAG_FUNCTION then
                    fn_at = at
                elseif at.tag == defs.TAG_FORALL then
                    local body = ann.types:get(at.data[2])
                    if body.tag == defs.TAG_FUNCTION then fn_at = body end
                end
                if fn_at and fn_at.data[1] > 0 and fn_at.data[6] == 0 then
                    --: integer
                    local r_line = decl_lines[r]
                    warn(ctx, r_line, 1, E.UNNAMED_PARAMS, {})
                end

                local alias = env_mod.lookup_type(ctx.scope, r.name_id)
                if alias then
                    -- For generic aliases, push a temporary scope where each type parameter
                    -- is bound to a TAG_NAMED placeholder. This lets resolve_annotation_type
                    -- produce the correct placeholder types (substitutable by env_mod.substitute)
                    -- instead of erroring on unresolved parameter names.
                    local old_scope = ctx.scope
                    if alias.params and #alias.params > 0 then
                        --: Scope
                        local scope = ctx.scope
                        local temp = env_mod.new(scope.level + 1)
                        temp.parent = scope
                        for _, param_name_id in ipairs(alias.params) do
                            local ph = types_mod.alloc_type(ctx, defs.TAG_NAMED)
                            --: TypeSlotArena
                            local types = ctx.types
                            types:get(ph).data[0] = param_name_id
                            env_mod.bind_type(temp, param_name_id, { body = ph, params = nil, nominal = false } --[[:! TypeAlias]])
                        end
                        ctx.scope = temp
                    end

                    --: integer
                    local r_line = decl_lines[r] or 0
                    ctx._ann_warn_line = r_line
                    if r.newtype then
                        local ann_nom = ann.types:get(r.type_id)
                        local underlying = resolve_annotation_type(ctx, ann_nom.data[2])
                        -- Stable nominal identity: hash of (filename, type name).
                        -- A newtype name is unique within a file; the filename prefix
                        -- makes it globally unique, so the hash is deterministic across runs.
                        local name_str = intern_mod.get(ctx.pool, r.name_id) or ""
                        local nominal_id = fnv31(ctx.filename .. ":newtype:" .. name_str)
                        alias.body = types_mod.make_nominal(ctx, r.name_id, nominal_id, underlying)
                    else
                        alias.body = resolve_annotation_type(ctx, r.type_id)
                    end
                    ctx._ann_warn_line = 0

                    -- Resolve raw_bounds (annotation-arena IDs) into checker-context type IDs.
                    -- These are resolved in the same temporary param scope so that bound types
                    -- that reference other params (e.g. <T: { x: U }, U>) resolve correctly.
                    if alias.raw_bounds then
                        alias.resolved_bounds = {}
                        local rb = alias.raw_bounds or {} --: { [integer]: integer, ... }
                        -- Allow unapplied type constructors as HKT bounds (e.g.
                        -- `<F: Functor>` where Functor is a generic alias). Mirrors
                        -- the argument-resolution site at lines 514-519.
                        local prev_allow = ctx._allow_unapplied_constructors
                        ctx._allow_unapplied_constructors = true
                        for _, raw_id in ipairs(rb) do
                            if raw_id == -1 then
                                alias.resolved_bounds[#alias.resolved_bounds + 1] = nil
                            else
                                alias.resolved_bounds[#alias.resolved_bounds + 1] =
                                    resolve_annotation_type(ctx, raw_id)
                            end
                        end
                        ctx._allow_unapplied_constructors = prev_allow
                    end

                    -- Resolve raw_defaults (annotation-arena IDs) into checker-context type IDs.
                    -- Also check each resolved default satisfies its corresponding bound at
                    -- definition site: Default <: Bound.
                    if alias.raw_defaults then
                        alias.resolved_defaults = {}
                        local rd = alias.raw_defaults or {} --: { [integer]: integer, ... }
                        for i, raw_id in ipairs(rd) do
                            if raw_id == -1 then
                                alias.resolved_defaults[i] = nil
                            else
                                local default_tid = resolve_annotation_type(ctx, raw_id)
                                alias.resolved_defaults[i] = default_tid
                                -- Check default satisfies bound at definition site.
                                if alias.resolved_bounds then
                                    local bound = alias.resolved_bounds[i]
                                    if bound ~= nil then
                                        local unify_mod = require("lib.type.static.unify")
                                        local widened_default = types_mod.widen(ctx, default_tid)
                                        if not unify_mod.try_unify(ctx, widened_default, bound) then
                                            local param_name = alias.params and alias.params[i]
                                                and (intern_mod.get(ctx.pool, alias.params[i]) or "?") or "?"
                                            local def_str = types_mod.display_short(ctx, default_tid)
                                            local bnd_str = types_mod.display_short(ctx, bound)
                                            --: integer
                                            local r_line = decl_lines[r]
                                            errors_mod.error(ctx.err, ctx.filename, r_line, 1,
                                                "default type '" .. def_str
                                                .. "' does not satisfy constraint '" .. bnd_str
                                                .. "' for parameter '" .. param_name .. "'")
                                        end
                                    end
                                end
                            end
                        end
                    end

                    -- Interface constraint check: --:: Name<T>: Constraint<T> = body
                    -- Register (name_id, constraint_name_id) in ctx.declared_subtypes and
                    -- verify body <: Constraint at definition time (symbolic check with TAG_VAR params).
                    -- constraint_type_id is an optional field on the open-table row variable;
                    -- force-cast to expose it as integer | nil.
                    local r_any = r --[[:! { constraint_type_id: integer | nil, ... }]]
                    if r_any.constraint_type_id then
                        local unify_mod = require("lib.type.static.unify")
                        --: integer
                        local ctid = r_any.constraint_type_id
                        -- Resolve the constraint type using the same param scope.
                        local constraint_tid = resolve_annotation_type(ctx, ctid)
                        -- Extract the constraint name_id from the annotation-arena TAG_NAMED node.
                        local ann_ct = ann.types:get(ctid)
                        local constraint_name_id = ann_ct.data[0]
                        -- Structural check: body <: constraint
                        -- Only register the oracle pair if the check passes.
                        if alias.body and not unify_mod.try_unify(ctx, alias.body, constraint_tid) then
                            local name_str = intern_mod.get(ctx.pool, r.name_id) or "?"
                            local cstr_str = types_mod.display_short(ctx, constraint_tid)
                            local body_str = types_mod.display_short(ctx, alias.body)
                            --: integer
                            local r_line = decl_lines[r]
                            errors_mod.error(ctx.err, ctx.filename, r_line, 1,
                                errors_mod.format_diag(E.CONSTRAINT_MISMATCH, {
                                    name       = name_str,
                                    constraint = cstr_str,
                                    detail     = "`" .. body_str .. "` is not assignable to `" .. cstr_str .. "`",
                                }))
                        else
                            -- Check passed: register oracle pair so try_unify can short-circuit.
                            ctx.declared_subtypes[r.name_id] = constraint_name_id
                        end
                    end

                    ctx.scope = old_scope
                end
            end
        end
    end

    -- Pass 2mod: populate ctx.module_types from --:: module declarations after type alias
    -- bodies are resolved.  This ensures that module type expressions can reference named
    -- type aliases declared in the same file (e.g. --:: module "lib.reactive": { signal: (unknown) -> Signal }).
    -- $Require<"mod"> in type alias bodies still works: it is expanded by the solver at
    -- call sites (after process_type_decls returns), not during resolve_annotation_type.
    for _, r in ipairs(module_decls) do
        local decl_line = module_decl_lines[r] or 0
        warn(ctx, decl_line, 1, E.MODULE_DECL, {})
        ctx._ann_warn_line = decl_line
        ctx.module_types[r.mod_name] = resolve_annotation_type(ctx, r.type_id)
        ctx._ann_warn_line = 0
    end

    -- Pass 2b: bind declared variables (decl_var), which may reference aliases set above.
    for _, r in ipairs(decls) do
        if r.decl_var then
            -- Warn on function type declarations with unnamed parameters.
            local at = ann.types:get(r.type_id)
            local fn_at
            if at.tag == defs.TAG_FUNCTION then
                fn_at = at
            elseif at.tag == defs.TAG_FORALL then
                local body = ann.types:get(at.data[2])
                if body.tag == defs.TAG_FUNCTION then fn_at = body end
            end
            if fn_at and fn_at.data[1] > 0 and fn_at.data[6] == 0 then
                --: integer
                local r_line = decl_lines[r]
                warn(ctx, r_line, 1, E.UNNAMED_PARAMS, {})
            end
            ctx._ann_warn_line = decl_lines[r] or 0
            env_mod.bind(ctx.scope, r.name_id, resolve_annotation_type(ctx, r.type_id))
            ctx._ann_warn_line = 0
        end
    end

    -- Pass 2c: apply --:: augment Name { ... } declarations.
    -- Runs after Pass 2a/2b so type aliases and declare variables are fully resolved.
    -- Augments merge fields into existing type bindings (value or type alias).
    -- For primitive type names (string/number/integer/boolean) the prim_index and
    -- prim_meta tables are updated so method dispatch stays consistent.
    if #augment_decls > 1 then
        local al = augment_decl_lines
        table.sort(augment_decls, function(a, b) return (al[a] or 0) < (al[b] or 0) end)
    end
    for _, r in ipairs(augment_decls) do
        -- Resolve the augment table type into the checker arena.
        ctx._ann_warn_line = augment_decl_lines[r] or 0
        local aug_tid = resolve_annotation_type(ctx, r.type_id)
        ctx._ann_warn_line = 0
        local aug_t = ctx.types:get(types_mod.find(ctx, aug_tid))
        if aug_t.tag == TAG_TABLE then
            -- Determine which prim tag this name corresponds to, if any.
            local name_str = intern_mod.get(ctx.pool, r.name_id) or ""
            local prim_tag = nil
            if name_str == "string"  then prim_tag = TAG_STRING
            elseif name_str == "number"  then prim_tag = TAG_NUMBER
            elseif name_str == "integer" then prim_tag = TAG_INTEGER
            elseif name_str == "boolean" then prim_tag = TAG_BOOLEAN
            end

            -- Collect new fields from the augment table.
            local new_field_ids = {}
            local new_meta_field_ids = {}
            for i = aug_t.data[0], aug_t.data[0] + aug_t.data[1] - 1 do
                new_field_ids[#new_field_ids + 1] = ctx.lists:get(i)
            end
            for i = aug_t.data[5], aug_t.data[5] + aug_t.data[6] - 1 do
                new_meta_field_ids[#new_meta_field_ids + 1] = ctx.lists:get(i)
            end

            -- Merge new_field_ids / new_meta_field_ids into an existing TAG_TABLE base_tid.
            -- Returns the new merged TAG_TABLE type ID.
            local function merge_into_table(base_tid)
                local bt = ctx.types:get(types_mod.find(ctx, base_tid))
                if bt.tag ~= TAG_TABLE then
                    return types_mod.make_table(ctx, new_field_ids, {}, -1, new_meta_field_ids)
                end
                local fs, fl = bt.data[0], bt.data[1]
                local is2, il = bt.data[2], bt.data[3]
                local rv = bt.data[4]
                local ms, ml = bt.data[5], bt.data[6]
                local merged = {}
                local name_pos = {}
                for i = fs, fs + fl - 1 do
                    local fid = ctx.lists:get(i)
                    local fe  = ctx.fields:get(fid)
                    if fe.name_id >= 0 then name_pos[fe.name_id] = #merged + 1 end
                    merged[#merged + 1] = fid
                end
                for _, fid in ipairs(new_field_ids) do
                    local fe = ctx.fields:get(fid)
                    if fe.name_id >= 0 and name_pos[fe.name_id] then
                        merged[name_pos[fe.name_id]] = fid  -- augment overrides existing field
                    else
                        if fe.name_id >= 0 then name_pos[fe.name_id] = #merged + 1 end
                        merged[#merged + 1] = fid
                    end
                end
                local merged_meta = {}
                local meta_name_pos = {}
                for i = ms, ms + ml - 1 do
                    local fid = ctx.lists:get(i)
                    local fe  = ctx.fields:get(fid)
                    if fe.name_id >= 0 then meta_name_pos[fe.name_id] = #merged_meta + 1 end
                    merged_meta[#merged_meta + 1] = fid
                end
                for _, fid in ipairs(new_meta_field_ids) do
                    local fe = ctx.fields:get(fid)
                    if fe.name_id >= 0 and meta_name_pos[fe.name_id] then
                        merged_meta[meta_name_pos[fe.name_id]] = fid
                    else
                        if fe.name_id >= 0 then meta_name_pos[fe.name_id] = #merged_meta + 1 end
                        merged_meta[#merged_meta + 1] = fid
                    end
                end
                local indexers = {}
                local ix = is2
                while ix < is2 + il - 1 do
                    indexers[#indexers + 1] = ctx.lists:get(ix)
                    indexers[#indexers + 1] = ctx.lists:get(ix + 1)
                    ix = ix + 2
                end
                return types_mod.make_table(ctx, merged, indexers, rv, merged_meta)
            end

            -- Look up existing binding: value (declare) takes precedence over type alias.
            local existing_value_tid = env_mod.lookup(ctx.scope, r.name_id)
            local existing_alias     = env_mod.lookup_type(ctx.scope, r.name_id)

            if existing_value_tid then
                local merged_tid = merge_into_table(existing_value_tid)
                env_mod.bind(ctx.scope, r.name_id, merged_tid)
                if prim_tag then ctx.prim_index[prim_tag] = merged_tid end
            elseif existing_alias then
                local base_body = existing_alias.body or types_mod.make_table(ctx, {}, {}, -1, {})
                local merged_tid = merge_into_table(base_body)
                existing_alias.body = merged_tid
                if prim_tag then
                    ctx.prim_index[prim_tag] = merged_tid
                    if aug_t.data[6] > 0 then ctx.prim_meta[prim_tag] = merged_tid end
                end
            else
                -- No existing binding: create fresh value binding from augment.
                local new_tid = types_mod.make_table(ctx, new_field_ids, {}, -1, new_meta_field_ids)
                env_mod.bind(ctx.scope, r.name_id, new_tid)
                if prim_tag then ctx.prim_index[prim_tag] = new_tid end
            end
        end
    end

    return typeof_decls
end

-- Resolve deferred `--:: Name = typeof ident` declarations.
-- Called after gen_block so that value bindings from local statements are in ctx.scope.
--: (Ctx, { [integer]: { r: { kind: integer, name_id: integer, type_id: integer, decl_var: boolean, newtype: boolean, ... }, line: integer, ... }, ... }) -> ()
local function process_typeof_decls(ctx, typeof_decls)
    for _, entry in ipairs(typeof_decls) do
        local r = entry.r
        local alias = env_mod.lookup_type(ctx.scope, r.name_id)
        if alias then
            ctx._ann_warn_line = entry.line
            alias.body = resolve_annotation_type(ctx, r.type_id)
            ctx._ann_warn_line = 0
        end
    end
end

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

-- Run constraint generation on a parsed source.
-- Returns {ctx, constraints} where ctx is the fully-initialized checker context
-- and constraints is the flat constraint array.
--: (string, string, Scope | nil, InternPool | nil, ((unknown, string) -> (integer | nil, { [integer]: unknown, ... } | nil)) | nil, { globals_files?: { [integer]: string, ... }, ... } | nil) -> (Ctx, { [integer]: { [integer]: unknown, ... }, ... })
function M.generate(source, filename, parent_scope, pool, cri_loader, opts)
    local parse_mod  = require("lib.type.static.parse")
    local intern_new = require("lib.type.static.intern").new
    pool = pool or intern_new()

    local scope = parent_scope or env_mod.new(0)
    local ctx = types_mod.new_ctx(pool)
    ctx.scope              = scope
    ctx.ann                = nil
    ctx.err                = errors_mod.new_ctx()
    ctx.filename           = filename or "?"
    ctx.source             = source  -- original source text; used for autofix byte slicing
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
    ctx._var_origin        = {}   -- [var_id] -> {obj_tid, field_name_id}: field-access origin for TAG_VAR results
    ctx.nominal_id         = 0
    ctx.catch_mode         = false   -- true while inside $Catch<T, ...> first-arg resolution
    ctx.catch_threw        = false   -- set to true by $Throw when catch_mode is active
    ctx._in_match_arm_subst = false  -- true during match arm result substitution (defers $Throw)
    ctx.rules_config       = opts and opts.rules_config or nil
    ctx.type_at            = {}
    ctx.name_at            = {}
    ctx.field_at           = {}
    ctx.def_sites          = {}
    ctx.require_sources    = {}
    ctx.declared_subtypes  = {}   -- [alias_name_id] = constraint_name_id; populated by interface declarations
    ctx.type_origins       = {}   -- [type_id] -> filename; populated for cross-file types
    ctx.constraints        = {}   -- v3: emitted constraints
    ctx._forall_bounds     = {}   -- [generic_tv_id] -> resolved_bound_type_id
    ctx._forall_ops = {}   -- [generic_tv_id] -> { op_descriptor, ... } (HM Phase 2)
    ctx.lit_cache          = {}   -- literal type interning: (kind<<32|val) → type_id

    if not parent_scope then
        local prelude = require("lib.type.static.prelude")
        local fn = filename or ""
        local globals_files = opts and opts.globals_files
        if fn:find("lib/type/static/", 1, true) or fn:find("lib\\type\\static\\", 1, true) then
            -- Self-check mode: load stdlib + typechecker-internal declarations.
            -- Takes priority over globals_files so ctx_types.lua is always loaded
            -- when checking typechecker sources, regardless of project config.
            prelude.populate_checker(ctx)
        elseif globals_files then
            -- Caller supplied an explicit list of globals files (from pkg.lua).
            -- Load each file and synthesize _G from the combined scope.
            prelude.populate_from_files(ctx, globals_files --[[:! { [integer]: string, ... }]], true)
        else
            -- Default: load stdlib_types.lua (hardcoded fallback for tools/tests
            -- that do not supply globals_files via opts).
            prelude.populate(ctx)
        end
        require("lib.type.static.prelude_luajit").populate(ctx)
    end

    local ok_parse, pr = pcall(parse_mod.parse, source, filename, pool)
    if not ok_parse then
        errors_mod.error(ctx.err, filename or "?", 0, 0, tostring(pr))
        return ctx, {}
    end
    -- pcall erases the parse result type; force-cast to the fields we need.
    -- Field-level types are asserted individually on the extracted locals below.
    local pr_any = pr --[[:! { lists: ListPool, nodes: ASTNodeArena, lexer: { annotations: { [integer]: unknown, ... }, ... } | nil, root: integer | nil }]]
    --: ListPool
    local pr_lists = pr_any.lists
    --: ASTNodeArena
    local pr_nodes = pr_any.nodes
    --: { annotations: { [integer]: unknown, ... }, ... } | nil
    local pr_lexer = pr_any.lexer
    --: integer | nil
    local pr_root = pr_any.root

    ctx.ast_lists = pr_lists
    ctx.nodes     = pr_nodes

    errors_mod.set_source(ctx.err, filename or "?", source)

    local lex_annotations = pr_lexer and pr_lexer.annotations
    if lex_annotations and next(lex_annotations) then
        local ok_ann, ar = pcall(ann_mod.parse_annotations, lex_annotations, pool, filename)
        if ok_ann then
            -- ar.parse_errors (hint errors, e.g. T?) are reported by process_type_decls below.
            ctx.ann = ar
        else
            -- Annotation parse error (e.g. type too deeply nested): report as a diagnostic.
            errors_mod.error(ctx.err, filename, 0, 0, "annotation parse error: " .. tostring(ar))
        end
    end

    if cri_loader then ctx.cri_loader = cri_loader end

    if ctx.ffi_hooks then
        local fh = ctx.ffi_hooks --[[:! { process: (unknown, string) -> (), init: (unknown) -> (), ... }]]
        fh.init(ctx)
    end

    local typeof_decls = process_type_decls(ctx)

    local chunk = pr_root and ctx.nodes:get(pr_root)
    if chunk then
        local bs, bl = chunk.data[0], chunk.data[1]
        gen_prescan_block(ctx, bs, bl)

        local module_ret_var = types_mod.make_var(ctx, ctx.scope.level)
        ctx.return_vars[1] = module_ret_var
        gen_block(ctx, bs, bl)
        ctx.return_vars[1] = nil
        ctx.module_return_tids = { { module_ret_var } }

        local td = typeof_decls or {}
        if #td > 0 then
            process_typeof_decls(ctx, td)
        end
    end

    return ctx, ctx.constraints
end

M.resolve_annotation_type = resolve_annotation_type
M.collect_bound_tvs = collect_bound_tvs  -- exposed for solve_escape_check

return M
