-- lib/type/v9/engine/domain/types.lua
-- DOMAIN 2: annotation-free TYPE INFERENCE. Cells are type UNKNOWNS (one fresh
-- cell per program value); the lattice is a set of atoms over {int,str,bool,nil}
-- where a set with >1 atom IS a union type; the transfer is subtyping
-- propagation (a value flows into the cell it is assigned to). NO annotations
-- are read — literal cells are the only seeds, and unions arise purely from the
-- engine's join at control-flow merges.
--
-- Flow-sensitivity is SSA: each assignment makes a fresh version cell, and an
-- `if` ends with phi cells; the phi receives BOTH branch versions as separate
-- proposals, so the engine's join yields `int | str` for `x` after the if with
-- zero special-casing. The type domain builds engine rules DIRECTLY (cells as
-- unknowns) — it does NOT use the CFG/dataflow adapter; that is the flow
-- analyses' path. Same engine, different lowering.
--
-- Imports only domain-agnostic substrate; references NOTHING from liveness or
-- constant domains.

--:: require "lib.type.v9.engine.defs"

local engine = require("lib.type.v9.engine.engine")

-- A type as a set of atom names; >1 atom = a union. Absence = ⊥ (no info yet).
--:: AtomSet = { [string]: boolean }

local M = {}

--: (x: unknown) -> x is AtomSet
local function as_atoms(x) return type(x) == "table" end

-- The set-union lattice over atoms (opaque-facing).
--: () -> unknown
local function bottom()
    local e = {} --: AtomSet
    return e
end
--: (unknown, unknown) -> unknown
local function join(a, b)
    if as_atoms(a) and as_atoms(b) then
        local r = {} --: AtomSet
        for k, v in pairs(a) do if v then r[k] = true end end
        for k, v in pairs(b) do if v then r[k] = true end end
        return r
    end
    return bottom()
end
--: (unknown, unknown) -> boolean
local function equal(a, b)
    if as_atoms(a) and as_atoms(b) then
        for k, v in pairs(a) do if v and not b[k] then return false end end
        for k, v in pairs(b) do if v and not a[k] then return false end end
        return true
    end
    return false
end

local lattice = { bottom = bottom, join = join, equal = equal } --: Lattice

-- A singleton atom type, e.g. single("int") = the type `int`.
--: (string) -> AtomSet
local function single(atom)
    local a = {} --: AtomSet
    a[atom] = true
    return a
end

-- Lower a program to an inference GRAPH. Returns the graph plus the cell ids to
-- read out: the final SSA cell of each variable, and the inferred return type.
--:: TypeLowering = { graph: Graph, vars: { [string]: string }, result: string }
--: (Program) -> TypeLowering
local function lower(program)
    local rules = {} --: { [integer]: Rule }
    local counter = 0
    local version = {} --: { [string]: string }
    local result_cell = "ty:result"

    --: (string) -> string
    local function fresh(tag)
        counter = counter + 1
        return "ty:" .. tag .. "#" .. counter
    end

    -- Seed a cell with a concrete atom type.
    --: (string, string) -> nil
    local function seed(cell, atom)
        rules[#rules + 1] = engine.rule({}, { cell }, function(get)
            return { [cell] = single(atom) }
        end)
        return nil
    end

    -- Flow the value of cell `src` into cell `dst` (a subtyping edge dst :> src).
    --: (string, string) -> nil
    local function flow(src, dst)
        rules[#rules + 1] = engine.rule({ src }, { dst }, function(get)
            return { [dst] = get(src) }
        end)
        return nil
    end

    -- Return a cell holding the inferred type of expression `e`.
    --: (Expr) -> string
    local function expr(e)
        if e.e == "int" then
            local c = fresh("int"); seed(c, "int"); return c
        elseif e.e == "str" then
            local c = fresh("str"); seed(c, "str"); return c
        elseif e.e == "bool" then
            local c = fresh("bool"); seed(c, "bool"); return c
        elseif e.e == "nil" then
            local c = fresh("nil"); seed(c, "nil"); return c
        elseif e.e == "add" then
            -- numeric addition: result is `int`; operands are still visited so
            -- their cells exist (and could later constrain operand types).
            expr(e.lhs); expr(e.rhs)
            local c = fresh("add"); seed(c, "int"); return c
        else
            -- var use: its current SSA cell (a free var gets a fresh ⊥ cell).
            local c = version[e.name]
            if c == nil then c = fresh("free-" .. e.name); version[e.name] = c end
            return c
        end
    end

    --: (string, Expr) -> nil
    local function define(name, value_expr)
        local src = expr(value_expr)
        local dst = fresh(name)
        flow(src, dst)
        version[name] = dst
        return nil
    end

    --: ({ [string]: string }) -> { [string]: string }
    local function snapshot()
        local r = {} --: { [string]: string }
        for k, v in pairs(version) do r[k] = v end
        return r
    end

    --: ({ [integer]: Stmt }) -> nil
    local function stmts(list)
        for i = 1, #list do
            local s = list[i]
            if s.s == "local" then
                define(s.name, s.value)
            elseif s.s == "assign" then
                define(s.name, s.value)
            elseif s.s == "call" then
                for k = 1, #s.args do expr(s.args[k]) end
            elseif s.s == "return" then
                local src = expr(s.value)
                flow(src, result_cell)
            elseif s.s == "if" then
                expr(s.cond)
                local before = snapshot()
                stmts(s.then_)
                local then_v = snapshot()
                version = {}
                for k, v in pairs(before) do version[k] = v end
                stmts(s.else_)
                local else_v = snapshot()
                -- phi-merge every variable touched in either branch.
                local names = {} --: { [string]: boolean }
                for k in pairs(then_v) do names[k] = true end
                for k in pairs(else_v) do names[k] = true end
                version = {}
                for name in pairs(names) do
                    local t = then_v[name]
                    local el = else_v[name]
                    if t ~= nil and t == el then
                        version[name] = t
                    else
                        -- distinct branch versions: a phi cell receives each as a
                        -- separate proposal; the engine joins them into a union.
                        local phi = fresh(name .. "-phi")
                        if t ~= nil then flow(t, phi) end
                        if el ~= nil then flow(el, phi) end
                        version[name] = phi
                    end
                end
            end
        end
        return nil
    end

    stmts(program)
    return { graph = { lattice = lattice, rules = rules }, vars = snapshot(), result = result_cell }
end
M.lower = lower

-- Render an atom-set as a sorted union string, e.g. "int | str", or "never".
--: (unknown) -> string
local function show(v)
    if not as_atoms(v) then return "never" end
    local atoms = {} --: { [integer]: string }
    for k, present in pairs(v) do if present then atoms[#atoms + 1] = k end end
    table.sort(atoms)
    if #atoms == 0 then return "never" end
    return table.concat(atoms, " | ")
end
M.show = show

-- Run inference and return each variable's inferred type + the return type, all
-- as rendered strings. The program carries NO annotations; these are inferred.
--:: TypeFacts = { vars: { [string]: string }, result: string, steps: integer }
--: (Program) -> (TypeFacts | nil, string | nil)
function M.analyze(program)
    local low = lower(program)
    local sol, err = engine.solve(low.graph)
    if sol == nil then return nil, err end
    local vars = {} --: { [string]: string }
    for name, cell in pairs(low.vars) do
        vars[name] = show(sol.values[cell])
    end
    return { vars = vars, result = show(sol.values[low.result]), steps = sol.steps }, nil
end

return M
