-- lib/type/v9/infer/bidir.lua
-- Inference strategy seam — bidirectional synth/check. Proof oracle:
-- synth / check (check.v), proven `synth_sound` / `check_sound` vs `has_type`.
--
-- DIP: the engine depends only on the injected `Caps` (rep / subtype decider /
-- diagnostics) — never on a concrete impl, never on globals. Swapping in a
-- constraint-based engine later means writing a new module with the SAME
-- `Inference` contract; consumers are untouched.
--
-- CRITICAL (non-deferrable): every result carries a first-class `Deriv` — the
-- evidence tree (which `has_type` rule fired, over which premises). There is no
-- consumer yet, but the certificate emitter is added later by reading this Deriv
-- with ZERO change to the engine. That is why evidence is first-class from day 1.
--
-- Context = de-Bruijn stack: the LAST element is index 0 (innermost binder),
-- matching the proof's `T :: G` prepend + `nth_error G n`.

--:: require "lib.type.v9.type_defs"

local M = {}

--: (IrNode) -> string
local function site(e)
    return e.names.source or e.tag
end

-- Functional context extension (immutable): index 0 becomes the new top.
--: (Context, Ty) -> Context
local function extend(ctx, t)
    local n = {} --: Context
    for i = 1, #ctx do n[i] = ctx[i] end
    n[#n + 1] = t
    return n
end

-- check against an expected type via subsumption (proof TSub): synth, then
-- decide actual <: expected through the injected decider. `syn` is the synth
-- function passed explicitly (avoids a forward-declared mutable local).
--: (Caps, Context, IrNode, Ty, (Caps, Context, IrNode) -> (Deriv | nil, Diag | nil)) -> (Deriv | nil, Diag | nil)
local function check_with(caps, ctx, e, expected, syn)
    local d, err = syn(caps, ctx, e)
    if d == nil then return nil, err end
    local verdict = caps.sub.decide(caps.rep, d.type, expected)
    if verdict == "sub" then
        return { node = e, type = expected, rule = "TSub", premises = { d } }, nil
    elseif verdict == "notsub" then
        return nil, caps.diag.mismatch(caps.rep, d.type, expected, site(e))
    end
    return nil, caps.diag.unprovable(caps.rep, d.type, expected, site(e))
end

--: (Caps, Lit) -> Ty
local function lit_type(caps, l)
    if l.kind == "int" then return caps.rep.atom("int") end
    if l.kind == "str" then return caps.rep.atom("str") end
    if l.kind == "bool" then return caps.rep.atom("bool") end
    return caps.rep.atom("nil")
end

--: (Caps, Context, IrNode) -> (Deriv | nil, Diag | nil)
local function synth(caps, ctx, e)
    local tag = e.tag
    if e.tag == "lit" then
        return { node = e, type = lit_type(caps, e.lit), rule = "TLit", premises = {} }, nil
    elseif e.tag == "var" then
        local idx = #ctx - e.index
        local t = ctx[idx]
        if t == nil then
            return nil, caps.diag.make("unbound_var", site(e) .. ": unbound de-Bruijn index " .. tostring(e.index))
        end
        return { node = e, type = t, rule = "TVar", premises = {} }, nil
    elseif e.tag == "lam" then
        local db, err = synth(caps, extend(ctx, e.param_type), e.body)
        if db == nil then return nil, err end
        return { node = e, type = caps.rep.arrow(e.param_type, db.type), rule = "TLam", premises = { db } }, nil
    elseif e.tag == "app" then
        local df, ferr = synth(caps, ctx, e.fn)
        if df == nil then return nil, ferr end
        if caps.rep.kind(df.type) ~= "arrow" then
            return nil, caps.diag.make("not_a_function",
                site(e) .. ": applying a non-function of type " .. caps.rep.show(df.type))
        end
        local dom = caps.rep.arrow_dom(df.type)
        local cod = caps.rep.arrow_cod(df.type)
        local da, aerr = check_with(caps, ctx, e.arg, dom, synth)
        if da == nil then return nil, aerr end
        return { node = e, type = cod, rule = "TApp", premises = { df, da } }, nil
    elseif e.tag == "let" then
        local dv, verr = synth(caps, ctx, e.value)
        if dv == nil then return nil, verr end
        local db, berr = synth(caps, extend(ctx, dv.type), e.body)
        if db == nil then return nil, berr end
        return { node = e, type = db.type, rule = "TLet", premises = { dv, db } }, nil
    end
    return nil, caps.diag.make("unsupported_node", "unsupported IR node: " .. tag)
end

--: (Caps, Context, IrNode) -> (Deriv | nil, Diag | nil)
function M.synth(caps, ctx, e)
    return synth(caps, ctx, e)
end

--: (Caps, Context, IrNode, Ty) -> (Deriv | nil, Diag | nil)
function M.check(caps, ctx, e, expected)
    return check_with(caps, ctx, e, expected, synth)
end

return M
