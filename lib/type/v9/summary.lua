-- lib/type/v9/summary.lua
-- The MODULE SUMMARY form: what checking one file EXPORTS across the module
-- boundary — (a) the module's return type (what `require` yields) and (b)
-- its alias environment (what `--:: require "mod"` imports).
--
-- THE EXPORTABLE FORM IS DATA, NOT LIVE LATTICE CELLS. A solved return type
-- is converted Val -> At (the annot seam's annotation tree): At trees are
-- plain immutable tables — serializable in principle, shared across every
-- importer — and the importing file converts At -> Val through its OWN
-- at_val (lower.lua), which mints FRESH param cells in the importer's
-- constraint graph. That per-importer re-mint is the reason cells cannot be
-- exported: a Val's function component carries engine cell ids of the
-- exporting file's graph; sharing them across graphs would collide fresh
-- counters and silently cross-wire two solves. This is the SAME interning
-- split the globals seam uses (stdlib At parsed once and shared; per-file
-- lazy At -> Val conversion) — one pattern, two producers.
--
--   Summary = {
--     returns:   { [integer]: At } | nil   position 1 = the value `require`
--                                          yields (Lua takes the chunk's
--                                          first return; a nil-returning
--                                          chunk loads as `true`). nil when
--                                          no solve produced it (lower-only
--                                          mode).
--     annotated: boolean                   every chunk return's first
--                                          position was an annotation-pinned
--                                          local or a checked cast — the
--                                          `unannotated-module-boundary`
--                                          policy dial's evidence (an
--                                          inferred summary IS cross-file
--                                          contextual typing; the dial makes
--                                          it visible).
--     aliases:   { [string]: Alias }       the file's exported `--::` alias
--                                          env (own + imported — transitively
--                                          closed, so an imported alias's
--                                          body references resolve).
--     cycle:     boolean | nil             true only on the shared
--                                          in-progress marker a require
--                                          CYCLE participant sees.
--   }
--
-- Summaries are IMMUTABLE once built: importers read them (and share Alias
-- entries), never write into them — checking A must not mutate B's cached
-- summary (pinned by test).
--
-- STATED UP-APPROXIMATIONS in Val -> At (each sound, none silent):
--   field read/write split   At fields carry ONE type; a field whose write
--                            bound has meet-narrowed below its read type
--                            exports as `readonly` (writes through the
--                            import are forbidden rather than over-admitted).
--   index-part split         index signatures have no readonly form; a
--                            meet-narrowed part exports its READ type (the
--                            same open-record aliasing concession family as
--                            new-field-on-write).
--   unpinned params          a function param no annotation pinned exports
--                            as `unknown` (a vacuous pin): the importer's
--                            arguments are NOT checked against inference —
--                            inferred inflows are evidence, not a declared
--                            contravariant bound, and pinning them would
--                            falsely reject new callers.

if not package.path:find("?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

--:: require "lib.type.v9.lattice"

local lattice = require("lib.type.v9.lattice")

--:: At = { k: string, ... }
--:: Alias = { content: string | nil, feature: string | nil }
--:: Summary = { returns: { [integer]: At } | nil, annotated: boolean, aliases: { [string]: Alias }, cycle: boolean | nil }
--:: Ret = { cells: { [integer]: string }, spread: boolean, pinned: boolean | nil, line: integer, col: integer }

local M = {}

local TRUE_VAL = lattice.single("true")
local NIL_VAL = lattice.single("nil")

-- Deterministic atom order for exported unions (display/serialization
-- stability; "boolean" collapses the true/false pair).
local ATOM_ORDER = { "nil", "boolean", "true", "false", "number", "string", "table", "function" } --: { [integer]: string }

--: (x: unknown) -> x is Val
local function is_val(x) return type(x) == "table" end

--: (x: unknown) -> x is At
local function is_at(x) return type(x) == "table" end

-- MEMOIZED on Val identity, process-wide (the same pattern as lower.lua's
-- atval_memo): Vals are immutable, so one Val exports one shared At forever
-- — shared substructure exports once, and repeated exports of a cached
-- summary's Val are free. Vals are clip-bounded trees, never cyclic.
local export_memo = {}
local val_to_at_raw

--: (v: Val) -> At
local function val_to_at(v)
    local hit = export_memo[v] --: unknown
    if is_at(hit) then return hit end
    local at = val_to_at_raw(v)
    export_memo[v] = at
    return at
end

--: (v: Val) -> At
val_to_at_raw = function(v)
    if lattice.is_unknown(v) then return { k = "unknown" } end
    local parts = {} --: { [integer]: At }
    local atoms = v.atoms
    for i = 1, #ATOM_ORDER do
        local name = ATOM_ORDER[i]
        if name == "boolean" then
            if atoms["true"] == true and atoms["false"] == true then
                parts[#parts + 1] = { k = "atom", name = "boolean" }
            end
        elseif atoms[name] == true then
            if (name ~= "true" and name ~= "false")
                or not (atoms["true"] == true and atoms["false"] == true) then
                parts[#parts + 1] = { k = "atom", name = name }
            end
        end
    end
    local rec = v.rec
    if rec ~= nil then
        local names = {} --: { [integer]: string }
        for fname in pairs(rec.fields) do names[#names + 1] = fname end
        table.sort(names)
        --:: RecField = { name: string, at: At, optional: boolean, readonly: boolean }
        local fields = {} --: { [integer]: RecField }
        for i = 1, #names do
            local f = rec.fields[names[i]]
            local ro = not lattice.lattice.equal(f.r, f.w)
            fields[#fields + 1] = {
                name = names[i], at = val_to_at(f.r), optional = false, readonly = ro,
            }
        end
        local istr = nil --: At | nil
        local inum = nil --: At | nil
        local idx = rec.idx
        if idx ~= nil then
            -- never parts export as `never` (the "no keys of this kind"
            -- claim survives the round trip: at_val's idx_of re-fills them).
            istr = val_to_at(idx.str.r)
            inum = val_to_at(idx.num.r)
        end
        parts[#parts + 1] = { k = "record", fields = fields, istr = istr, inum = inum }
    end
    local fn = v.fn
    if fn ~= nil then
        --:: FnParam = { at: At, optional: boolean }
        local params = {} --: { [integer]: FnParam }
        for i = 1, #fn.params do
            local pin = fn.params[i].pin
            local pat = { k = "unknown" } --: At
            if pin ~= nil then pat = val_to_at(pin) end
            params[#params + 1] = { at = pat, optional = false }
        end
        local results = {} --: { [integer]: At }
        local insts = fn.insts
        for i = 1, #fn.results do
            local inst = nil --: Inst | nil
            if insts ~= nil then inst = insts[i] end
            if inst ~= nil then
                -- a call-site instantiation position survives export as the
                -- inst node itself (an exported pairs-shaped declaration
                -- keeps its power; at_val re-marks it on import).
                results[i] = { k = "inst", proj = inst.proj, idx = inst.idx }
            else
                results[i] = val_to_at(fn.results[i])
            end
        end
        local rest = nil --: At | nil
        if fn.rest ~= nil then rest = val_to_at(fn.rest) end
        parts[#parts + 1] = {
            k = "fn", params = params, vararg = fn.vararg == true, rest = rest,
            results = results, open = fn.open == true,
        }
    end
    if #parts == 0 then return { k = "never" } end
    if #parts == 1 then return parts[1] end
    return { k = "union", parts = parts }
end

-- Export one solved Val as an At tree (immutable data; memoized on Val
-- identity so shared substructure exports once — Vals are clip-bounded
-- trees, never cyclic).
--: (v: Val) -> At
function M.val_to_at(v)
    return val_to_at(v)
end

-- The module VALUE from the chunk's solved return records: join of every
-- return's first position, with Lua's require semantics applied — a chunk
-- that returns nothing (or nil) loads as `true`, so the nil part of the
-- join is REPLACED by `true` (require never yields nil).
--: (returns: { [integer]: Ret }, values: { [string]: unknown }) -> Val
function M.module_value(returns, values)
    local v = lattice.of({}) --: Val
    if #returns == 0 then return TRUE_VAL end
    for i = 1, #returns do
        local c = returns[i].cells[1]
        local rv = NIL_VAL --: Val
        if c ~= nil then
            local got = values[c]
            if is_val(got) then rv = got end
        end
        local j = lattice.lattice.join(v, rv)
        if is_val(j) then v = j end
    end
    if lattice.is_bottom(v) then return TRUE_VAL end
    if lattice.has_atom(v, "nil") then
        local dropped = lattice.tag_drop(v, "nil")
        if is_val(dropped) then v = dropped end
        local j = lattice.lattice.join(v, TRUE_VAL)
        if is_val(j) then v = j end
    end
    return v
end

-- Was every chunk return's first position annotation-backed? (The
-- `unannotated-module-boundary` dial's evidence; lowering records the flag
-- per return.)
--: (returns: { [integer]: Ret }) -> boolean
function M.all_pinned(returns)
    if #returns == 0 then return true end
    for i = 1, #returns do
        if returns[i].pinned ~= true then return false end
    end
    return true
end

return M
