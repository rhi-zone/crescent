-- lib/type/v9/init.lua
-- v9 modular typechecker — top-level DIP wiring.
--
-- A `Checker` is ASSEMBLED from a set of seam implementations (`Impls`). Every
-- seam is injected; nothing is reached from a global. `new(impls)` lets a caller
-- swap ANY seam (a different type representation, a different subtyping backend,
-- a constraint engine, a real certificate emitter) without touching the others
-- — that is the whole point. `defaults()` supplies the minimal built-in slice.
--
-- The `Caps` bundle handed to inference is a READ-ONLY capability record, NOT a
-- mutable message bus: it carries function tables (rep / decider / diagnostics),
-- never per-phase scratch fields. (See ARCHITECTURE.md "What we are NOT doing".)

if not package.path:find("?/init.lua", 1, true) then
    package.path = package.path .. ";./?/init.lua"
end

--:: require "lib.type.v9.type_defs"

local M = {}

--: () -> Impls
function M.defaults()
    return {
        rep = require("lib.type.v9.type_rep.tagged"),
        sub = require("lib.type.v9.subtype.structural"),
        infer = require("lib.type.v9.infer.bidir"),
        diag = require("lib.type.v9.diagnostics"),
        cert = require("lib.type.v9.certificate"),
        parser = require("lib.type.v9.parser"),
    }
end

-- Lower source to IR and synth a type, threading errors as data.
--: (Impls, string) -> (CheckResult | nil, Diag | nil)
local function check_source(impls, src)
    local sexpr, perr = impls.parser.parse(src)
    if sexpr == nil then return nil, impls.diag.make("parse_error", perr or "parse error") end
    local node, lerr = impls.parser.lower(impls.rep, sexpr)
    if node == nil then return nil, impls.diag.make("lower_error", lerr or "lower error") end
    local caps = { rep = impls.rep, sub = impls.sub, diag = impls.diag } --: Caps
    local empty = {} --: Context
    local deriv, terr = impls.infer.synth(caps, empty, node)
    if deriv == nil then return nil, terr end
    local cert = impls.cert.emit(deriv)
    return { type = deriv.type, deriv = deriv, cert = cert }, nil
end

-- As above but CHECK the program against an expected type (parsed via the
-- parser's type grammar). Demonstrates the subsumption/diagnostic path.
--: (Impls, string, string) -> (CheckResult | nil, Diag | nil)
local function check_source_against(impls, src, type_src)
    local sexpr, perr = impls.parser.parse(src)
    if sexpr == nil then return nil, impls.diag.make("parse_error", perr or "parse error") end
    local node, lerr = impls.parser.lower(impls.rep, sexpr)
    if node == nil then return nil, impls.diag.make("lower_error", lerr or "lower error") end
    local expected, eerr = impls.parser.parse_type(impls.rep, type_src)
    if expected == nil then return nil, impls.diag.make("type_parse_error", eerr or "type parse error") end
    local caps = { rep = impls.rep, sub = impls.sub, diag = impls.diag } --: Caps
    local empty = {} --: Context
    local deriv, terr = impls.infer.check(caps, empty, node, expected)
    if deriv == nil then return nil, terr end
    local cert = impls.cert.emit(deriv)
    return { type = deriv.type, deriv = deriv, cert = cert }, nil
end

-- Assemble a Checker from a (partial-free) set of impls. Pass `nil` for defaults.
--: (Impls | nil) -> Checker
function M.new(impls)
    local i = impls or M.defaults()
    return {
        impls = i,
        --: (string) -> (CheckResult | nil, Diag | nil)
        check_source = function(src) return check_source(i, src) end,
        --: (string, string) -> (CheckResult | nil, Diag | nil)
        check_source_against = function(src, type_src) return check_source_against(i, src, type_src) end,
    }
end

return M
