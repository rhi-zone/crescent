-- lib/type/v9/engine/domain/constprop.lua
-- DOMAIN 3 (the PRESSURE TEST): constant propagation. A FORWARD analysis over a
-- genuinely NON-set-union lattice — the per-variable constant lattice
--   ⊥  ⊑  Num(n)  ⊑  ⊤
-- where join(Num a, Num b) = ⊤ when a ≠ b. Unlike the type and liveness domains
-- (both set-union / monotone-grow-by-adding), this lattice's join LOSES
-- information and has a real top. The transfer also genuinely COMPUTES (it folds
-- `1 + 1` to Num(2)); it is not mere propagation. This is the case the three
-- engine-core spikes never exercised (all coincidentally used set-union), so it
-- is the real test that the engine + interface are not type-shaped.
--
-- It plugs into the SAME engine through the SAME dataflow adapter with
-- `direction = "forward"`, narrowing opaque cells via `as_env`. No interface
-- change was required — see ARCHITECTURE.md "The pressure test".

--:: require "lib.type.v9.engine.defs"

local cfg = require("lib.type.v9.engine.cfg")
local dataflow = require("lib.type.v9.engine.dataflow")
local engine = require("lib.type.v9.engine.engine")

-- A constant value: a known number, or ⊤ (not a single constant). Absence from
-- an environment = ⊥ (undefined / unreached).
--:: CV = { k: "num", n: number } | { k: "top" }
--:: ConstEnv = { [string]: CV }

local M = {}

local TOP = { k = "top" } --: CV

--: (number) -> CV
local function num(n) return { k = "num", n = n } end

-- Combine two constant values (the per-variable lattice join).
--: (CV, CV) -> CV
local function cv_join(a, b)
    if a.k == "top" then return a end
    if b.k == "top" then return b end
    -- both are num here
    if a.k == "num" and b.k == "num" then
        if a.n == b.n then return a end
        return TOP
    end
    return TOP
end

--: (CV, CV) -> boolean
local function cv_eq(a, b)
    if a.k == "num" and b.k == "num" then return a.n == b.n end
    return a.k == b.k
end

-- Narrows an opaque cell value to a ConstEnv at the domain boundary.
--: (x: unknown) -> x is ConstEnv
local function as_env(x) return type(x) == "table" end

--: (ConstEnv) -> ConstEnv
local function copy(e)
    local r = {} --: ConstEnv
    for k, v in pairs(e) do r[k] = v end
    return r
end

-- The constant-propagation lattice (opaque-facing).
--: () -> unknown
local function bottom()
    local e = {} --: ConstEnv
    return e
end
--: (unknown, unknown) -> unknown
local function join(a, b)
    if as_env(a) and as_env(b) then
        local r = copy(a)
        for k, vb in pairs(b) do
            local va = r[k]
            if va == nil then r[k] = vb else r[k] = cv_join(va, vb) end
        end
        return r
    end
    return bottom()
end
--: (unknown, unknown) -> boolean
local function equal(a, b)
    if as_env(a) and as_env(b) then
        for k, va in pairs(a) do
            local vb = b[k]
            if vb == nil or not cv_eq(va, vb) then return false end
        end
        for k, vb in pairs(b) do
            if a[k] == nil then return false end
        end
        return true
    end
    return false
end

local lattice = { bottom = bottom, join = join, equal = equal } --: Lattice

-- Abstract-evaluate an expression to a constant value under `env`. A non-numeric
-- literal, a free/unknown variable, or a non-foldable add yields ⊤.
--: (Expr, ConstEnv) -> CV
local function eval(e, env)
    if e.e == "int" then
        return num(e.value)
    elseif e.e == "var" then
        local v = env[e.name]
        if v == nil then return TOP end
        return v
    elseif e.e == "add" then
        local l = eval(e.lhs, env) --: CV
        local r = eval(e.rhs, env) --: CV
        if l.k == "num" then
            if r.k == "num" then return num(l.n + r.n) end
        end
        return TOP
    elseif e.e == "str" or e.e == "bool" or e.e == "nil" then
        -- non-numeric literals are not a numeric constant: ⊤.
        return TOP
    end
    return TOP
end

-- Forward block transfer: thread the environment through the block's statements.
--: (Block, unknown) -> unknown
local function transfer(block, env_in)
    if not as_env(env_in) then return bottom() end
    local env = copy(env_in)
    for i = 1, #block.stmts do
        local s = block.stmts[i]
        if s.s == "local" or s.s == "assign" then
            env[s.name] = eval(s.value, env)
        end
        -- call / return: no effect on the constant environment.
    end
    return env
end

local domain = { lattice = lattice, direction = "forward", boundary = bottom(), transfer = transfer } --: FlowDomain
M.domain = domain

-- Render a constant value for assertions / display.
--: (CV | nil) -> string
local function show(v)
    if v == nil then return "bottom" end
    if v.k == "num" then return "num(" .. v.n .. ")" end
    return "top"
end
M.show = show

-- Run constant propagation and return the environment AFTER the whole program
-- (out of the exit block), rendered as var -> string. Demonstrates folding
-- (y = num(2)) and the lossy ⊤ join (x = top after the if).
--:: ConstFacts = { env: { [string]: string }, steps: integer }
--: (Program) -> (ConstFacts | nil, string | nil)
function M.analyze(program)
    local graph = cfg.lower(program)
    local g = dataflow.to_graph(graph, domain)
    local sol, err = engine.solve(g)
    if sol == nil then return nil, err end

    local final = sol.values[dataflow.out_cell(graph.exit)] --: unknown
    local env = {} --: { [string]: string }
    if as_env(final) then
        for k, v in pairs(final) do env[k] = show(v) end
    end
    return { env = env, steps = sol.steps }, nil
end

return M
