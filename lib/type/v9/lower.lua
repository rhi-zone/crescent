-- lib/type/v9/lower.lua
-- TOTAL lowering: decoded full-Lua AST -> the v9 checkable representation
-- (an engine constraint Graph + post-solve Obligations + structural Diags).
--
-- TOTALITY IS THE CONTRACT. Every one of the parser's 30 node kinds is
-- recognized and routed — either into the supported v0 discipline or into an
-- honest structured `unsupported:<construct>` diagnostic with line/col. No
-- crashes on any construct, no silent passes. The unsupported set IS the
-- explicit dynamism/coverage boundary; shrinking it is the roadmap
-- ("total on semantics, bounded on dynamism").
--
-- UNIFORMITY: one constraint shape. Each construct contributes ONE lowering
-- rule that emits engine `Rule`s (seed / flow / truthy-falsy filter) and/or
-- one `Obligation` (a post-solve upper-bound check). There is NO bespoke
-- solver logic per construct — the engine stays domain-blind, and the only
-- flow operations are the lattice's truthy/falsy:
--
--   if x then …      then-branch x : truthy(x), else-branch x : falsy(x)
--   a and b          : falsy(a) | type(b)   } derived from the SAME two ops,
--   a or  b          : truthy(a) | type(b)  } never a hardcoded case
--   if type(x) == "s" then   then-branch x : tag_keep(x, s), else-branch
--                    x : tag_drop(x, s) — two more lattice flow ops of the
--                    same shape (either operand order; ~= swaps branches)
--   if x == nil then the SAME keep/drop filters at the nil tag (equality
--                    with the nil literal IS the type()-tag test for nil;
--                    ~= swaps branches, either operand order)
--
-- RECORDS ride the same shape: a table constructor with named fields is one
-- rule proposing `lattice.record_of` over its field cells; a field READ
-- (`t.x`, `t["x"]`, and the receiver half of `t:m(...)`) is one projection
-- rule + a field-read obligation; a field WRITE (`t.x = v`, incl. the
-- `function M.f()` module idiom) is one `set_field` rule that SSA-rebinds
-- the base local + a field-write obligation (the write is checked against
-- the field's invariant `w` bound post-solve — see lattice.lua's soundness
-- header). Non-literal keys are the honest `unsupported:dynamic-index`
-- boundary; the array part of constructors is `unsupported:table-array-part`.
--
-- FUNCTIONS ride the same shape (arrows are just more lattice values): a
-- function definition mints one param cell per parameter (UNSEEDED — a
-- cell-as-unknown that call sites flow argument types into) and one result
-- cell per return position; ONE rebuild rule re-proposes the function value
-- as its result cells climb. A call is ONE rule that flows argument values
-- into the callee's param cells and each result position out (truncation /
-- nil-extension per Lua call semantics; a call/vararg in last return
-- position marks the function result-OPEN — positions beyond are unknown,
-- not nil). Recursion works because the function's cell is bound BEFORE its
-- body lowers; the recursion-created value cycles are kept finite by
-- lattice.clip at the two cycle-closing proposal sites. `require(...)` is
-- the honest `unsupported:cross-module` boundary — no module summaries yet.
-- A parameter no in-file call reaches (and no annotation pins) stays at
-- BOTTOM; post-solve that is reported ONCE per parameter as
-- `unsupported:unconstrained-param` (the body was checked against no
-- inputs) instead of a per-use unknown flood — same honesty, right shape.
--
-- ANNOTATIONS (the v9 annot seam, lib/type/v9/annot) are read here and
-- nowhere else. The discipline is PIN + CHECK — an annotation is BOTH a
-- seed and an upper-bound obligation; inference must AGREE with it, never
-- be overridden by it:
--
--   local x = e --: T     x's cell is SEEDED T (readers see the interface);
--                         e gets an `ann` obligation e ⊑ T. A direct table
--                         constructor is initialization: the ascription
--                         re-types the fresh constructor's field refs
--                         (leq_init), which is what lets `f = nil --: T|nil`
--                         fields accept later in-bound writes.
--   x = e                 (x annotated) e ⊑ pin obligation; x's cell rebinds
--                         to e's cell — assignment NARROWING survives the pin.
--   --: (a: T) -> R       (preceding line) pins the function's param cells
--   local function f(a)   (seed T; call args are checked against the pin at
--                         the CALL site, not flowed) and its result cells
--                         (each return statement is obligated per position).
--   f = nil, --: T        a table-constructor field or field-write on the
--                         same line pins that field's ref type.
--   --[[: T]]             checked cast: obligation expr ⊑ T (cast-mismatch;
--                         `unknown` sources are the use-before-narrow class)
--                         AND the flow continues at T.
--   --[[:! T]]            force cast: the named `force-cast` policy
--                         (default error); the flow continues at T.
--   --:: Name = T         module-level alias, resolved inside annotations.
--   --:: declare g = T    a GLOBAL declaration (the house no-ambient-globals
--                         convention): reads of `g` resolve at T. File
--                         declares shadow the STDLIB ENVIRONMENT (the
--                         globals seam, lib/type/v9/globals — LuaJIT 5.1
--                         globals as shared, interned declare-lines data);
--                         only genuinely undeclared names diag. Global
--                         WRITES stay the global-write policy diag either
--                         way. `require(...)` calls stay the honest
--                         `unsupported:cross-module` boundary even though
--                         `require` itself is declared.
--
-- Every annotation feature the v9 lattice cannot express routes to a named
-- `unsupported:annotation-<feature>` bucket — honest, dialable, per bucket.
-- HAVOC of an annotated variable resets it to its PIN, not to unknown: the
-- annotation is the contract the unchecked region is trusted against
-- (stated; the write inside the region gets checked when loops land).
--
-- Flow-sensitivity is SSA-style versioning: assignments rebind a variable's
-- cell; `if` merges make phi cells that receive each branch version as a
-- separate proposal — the engine's monotone join IS the union at the merge.
--
-- Unsupported statements with bodies (loops, in v0) are not silently
-- skipped: the subtree is scanned so (a) reads keep outer locals from false
-- "unused" reports and (b) assigned outer locals are HAVOCED to unknown —
-- the supported discipline stays sound around the boundary.
--
-- Diag severities are stamped by the POLICY in check.lua, not here — the
-- power dial is the owner's, and it lives in one named place.

if not package.path:find("?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

--:: require "lib.type.v9.engine.defs"
--:: require "lib.type.v9.lattice"
--:: require "lib.type.v9.annot"
--:: require "lib.type.v9.globals"

local defs = require("lib.type.static.defs")
local engine = require("lib.type.v9.engine.engine")
local lattice = require("lib.type.v9.lattice")
local frontend = require("lib.type.v9.frontend")
local annot = require("lib.type.v9.annot")
local globals = require("lib.type.v9.globals")

--:: Ast = { tag: integer, line: integer, col: integer, ... }
--:: Diag = { code: string, severity: string, message: string, line: integer, col: integer }
--:: Obligation = { kind: string, cell: string, allow: Val | nil, field: string | nil, base: string | nil, args: { [integer]: string } | nil, inits: { [integer]: boolean } | nil, init: boolean | nil, code: string, what: string, line: integer, col: integer }
--:: LowerResult = { graph: Graph, obligations: { [integer]: Obligation }, diags: { [integer]: Diag }, vars: { [string]: string } }
--:: Decl = { id: string, name: string, line: integer, col: integer, read: boolean, cell: string, pin: Val | nil }
--:: Scope = { map: { [string]: Decl }, order: { [integer]: Decl } }
--:: Ann = { kind: integer, content: string, col: integer, force_cast: boolean | nil, line: integer | nil, consumed: boolean | nil }

local M = {}

--: (x: unknown) -> x is Ast
local function is_node(x) return type(x) == "table" end

--: (x: unknown) -> x is { [integer]: Ast }
local function is_list(x) return type(x) == "table" end

--: (x: unknown) -> x is { [string]: unknown }
local function is_tbl(x) return type(x) == "table" end

-- Operand upper bounds (shared AtomSet constants; never mutated).
local NUM = lattice.single("number")
local NUMSTR = lattice.of({ "number", "string" })
local LENABLE = lattice.of({ "string", "table" })
local FUNC = lattice.single("function")
local NIL_VAL = lattice.single("nil")
local UNKNOWN_VAL = lattice.single("unknown")

-- Depth bound for values proposed around recursion-created cycles (function
-- rebuild + call-argument flow) — see lattice.clip.
local CLIP_DEPTH = 5

-- The binary-operator discipline as DATA: op -> (operand bound | nil,
-- result atom | nil, derive | nil). `derive` marks the two operators whose
-- result is DERIVED from the lattice's truthy/falsy (and/or) instead of a
-- fixed result atom. An unrecognized op returns (nil, nil, nil).
--: (string) -> (Val | nil, string | nil, string | nil)
local function binop_rule(op)
    if op == "+" or op == "-" or op == "*" or op == "/" or op == "%" or op == "^" then
        return NUM, "number", nil
    elseif op == ".." then
        return NUMSTR, "string", nil
    elseif op == "<" or op == "<=" or op == ">" or op == ">=" then
        return NUMSTR, "boolean", nil
    elseif op == "==" or op == "~=" then
        return nil, "boolean", nil
    elseif op == "and" then
        return nil, nil, "falsy"
    elseif op == "or" then
        return nil, nil, "truthy"
    end
    return nil, nil, nil
end

-- The unary-operator discipline: op -> (operand bound | nil, result atom |
-- nil). Unrecognized op returns (nil, nil).
--: (string) -> (Val | nil, string | nil)
local function unop_rule(op)
    if op == "-" then
        return NUM, "number"
    elseif op == "not" then
        return nil, "boolean"
    elseif op == "#" then
        return LENABLE, "number"
    end
    return nil, nil
end

-- Lower a decoded chunk. Returns the constraint graph (engine-solvable), the
-- obligations to evaluate against the solution, and the structural
-- diagnostics gathered during the walk. Never throws on any construct.
--: (Ast) -> LowerResult
function M.lower(chunk)
    local rules = {} --: { [integer]: Rule }
    local obligations = {} --: { [integer]: Obligation }
    local diags = {} --: { [integer]: Diag }
    local counter = 0

    -- Lexical scopes (depth-indexed, never nil'd) + SSA versions: decl.cell
    -- is the CURRENT cell of the variable; branches snapshot/restore it.
    local scopes = {} --: { [integer]: Scope }
    local depth = 0
    -- Return frames, one per enclosing function (innermost = top): each
    -- return statement records its per-position cells; the function wires
    -- them into result-position cells once the max arity is known.
    --:: Ret = { cells: { [integer]: string }, spread: boolean, line: integer, col: integer }
    --:: Frame = { returns: { [integer]: Ret }, pins: { [integer]: Val } | nil }
    local ret_frames = {} --: { [integer]: Frame }
    local ret_depth = 0

    --: (string) -> string
    local function fresh(tag)
        counter = counter + 1
        return "c:" .. tag .. "#" .. counter
    end

    --: (string, Val) -> nil
    local function seed(cell, atoms)
        rules[#rules + 1] = engine.rule({}, { cell }, function(get)
            return { [cell] = atoms }
        end)
        return nil
    end

    --: (string, string) -> nil
    local function flow(src, dst)
        rules[#rules + 1] = engine.rule({ src }, { dst }, function(get)
            return { [dst] = get(src) }
        end)
        return nil
    end

    -- The ONE narrowing transfer shape: dst receives a lattice flow op of
    -- src. Modes: "truthy" / "falsy" (bare guards, and/or) and
    -- "keep:<tag>" / "drop:<tag>" (the `type(x) == "…"` guards) — all four
    -- are the lattice's own monotone unary ops, never lowering logic.
    --: (string, string, string) -> nil
    local function filter_flow(src, dst, mode)
        if mode == "truthy" then
            rules[#rules + 1] = engine.rule({ src }, { dst }, function(get)
                return { [dst] = lattice.truthy(get(src)) }
            end)
        elseif mode == "falsy" then
            rules[#rules + 1] = engine.rule({ src }, { dst }, function(get)
                return { [dst] = lattice.falsy(get(src)) }
            end)
        else
            local op, tag = mode:match("^(%a+):(%a+)$")
            if op == "keep" and tag ~= nil then
                local t = tag
                rules[#rules + 1] = engine.rule({ src }, { dst }, function(get)
                    return { [dst] = lattice.tag_keep(get(src), t) }
                end)
            elseif op == "drop" and tag ~= nil then
                local t = tag
                rules[#rules + 1] = engine.rule({ src }, { dst }, function(get)
                    return { [dst] = lattice.tag_drop(get(src), t) }
                end)
            end
        end
        return nil
    end

    --: (string) -> string
    local function unknown_cell(tag)
        local c = fresh(tag)
        seed(c, lattice.single("unknown"))
        return c
    end

    --: (string) -> string
    local function atom_cell(atom)
        local c = fresh(atom)
        seed(c, lattice.single(atom))
        return c
    end

    --: (code: string, line: integer, col: integer, message: string) -> nil
    local function diag(code, line, col, message)
        -- severity is stamped by the policy in check.lua.
        diags[#diags + 1] = { code = code, severity = "warn", line = line, col = col, message = message }
        return nil
    end

    --: (Ast, string) -> nil
    local function unsupported(n, what)
        diag("unsupported:" .. what, n.line, n.col,
            "`" .. what .. "` is outside the v0 checked subset (honest boundary; not checked)")
        return nil
    end

    --: (Ast, string) -> nil
    local function internal(n, msg)
        diag("internal", n.line, n.col, "lowering invariant violated: " .. msg)
        return nil
    end

    --: (cell: string, allow: Val, code: string, what: string, line: integer, col: integer) -> nil
    local function obligate(cell, allow, code, what, line, col)
        obligations[#obligations + 1] = {
            kind = "bound", cell = cell, allow = allow, field = nil, base = nil, args = nil, inits = nil, init = nil,
            code = code, what = what, line = line, col = col,
        }
        return nil
    end

    -- "`cell` (a field-read target) must be a record with `field`" — checked
    -- post-solve; violation codes are resolved there (missing-field /
    -- op-mismatch / use-before-narrow / unsupported:string-method).
    --: (cell: string, field: string, what: string, line: integer, col: integer) -> nil
    local function obligate_field_read(cell, field, what, line, col)
        obligations[#obligations + 1] = {
            kind = "field-read", cell = cell, allow = nil, field = field, base = nil, args = nil, inits = nil, init = nil,
            code = "missing-field", what = what, line = line, col = col,
        }
        return nil
    end

    -- "the value in `cell`, written to `base`.`field`, must satisfy the
    -- field's invariant write bound" — the mutation-soundness check. A write
    -- to a field `base` does not yet have is the named `new-field-on-write`
    -- policy case (also resolved post-solve).
    --: (cell: string, base: string, field: string, line: integer, col: integer) -> nil
    local function obligate_field_write(cell, base, field, line, col)
        obligations[#obligations + 1] = {
            kind = "field-write", cell = cell, allow = nil, field = field, base = base, args = nil, inits = nil, init = nil,
            code = "field-write-mismatch", what = "field '" .. field .. "'", line = line, col = col,
        }
        return nil
    end

    -- "`cell` (an unannotated parameter) should have received SOME evidence"
    -- — post-solve, a still-bottom parameter means no in-file call reaches it
    -- and no annotation pins it: the body was checked against no inputs.
    -- Reported once per parameter (the honest boundary, not a per-use flood).
    --: (cell: string, name: string, line: integer, col: integer) -> nil
    local function obligate_param_witness(cell, name, line, col)
        obligations[#obligations + 1] = {
            kind = "param-witness", cell = cell, allow = nil, field = nil, base = nil, args = nil, inits = nil, init = nil,
            code = "unsupported:unconstrained-param", what = "parameter '" .. name .. "'",
            line = line, col = col,
        }
        return nil
    end

    -- "each argument at this call site must satisfy the callee's param PINS"
    -- — evaluated post-solve against the callee's function component; only
    -- pinned (annotated) params are checked here, inferred params take their
    -- evidence from the argument flow instead. `inits[i]` marks an argument
    -- that is a direct table constructor (a fresh construction ascribed by
    -- the pin: initialization ordering, as for annotated locals).
    --: (cell: string, args: { [integer]: string }, inits: { [integer]: boolean }, what: string, line: integer, col: integer) -> nil
    local function obligate_call(cell, args, inits, what, line, col)
        obligations[#obligations + 1] = {
            kind = "call", cell = cell, allow = nil, field = nil, base = nil, args = args,
            inits = inits, init = nil, code = "call-mismatch", what = what, line = line, col = col,
        }
        return nil
    end

    -- "the value in `cell` must satisfy the annotated type" — the CHECK half
    -- of pin+check. `init` marks a directly-ascribed fresh constructor
    -- (leq_init: the ascription re-types the constructor's field refs).
    --: (cell: string, allow: Val, init: boolean, code: string, what: string, line: integer, col: integer) -> nil
    local function obligate_ann(cell, allow, init, code, what, line, col)
        obligations[#obligations + 1] = {
            kind = "ann", cell = cell, allow = allow, field = nil, base = nil, args = nil, inits = nil,
            init = init, code = code, what = what, line = line, col = col,
        }
        return nil
    end

    -- ── annotations (the annot seam, wired) ────────────────────────────────

    -- The lexer's raw captures, attached by the frontend: line-keyed for
    -- `--:`/`--::` comments, negative-id-keyed for `--[[: ]]` casts.
    local anns = {} --: { [integer]: Ann }
    do
        local raw = chunk.annotations --: unknown
        --: (x: unknown) -> x is { [integer]: Ann }
        local function is_anns(x) return type(x) == "table" end
        if is_anns(raw) then anns = raw end
    end

    -- Alias environment from the file's `--:: Name = T` declarations
    -- (collected up front: aliases resolve regardless of position). Non-alias
    -- `--::` forms are classified in the entry pre-pass below.
    --:: Alias = { content: string | nil, feature: string | nil }
    local aliases = {} --: { [string]: Alias }

    -- The GLOBAL environment (the globals seam): per-file `--:: declare
    -- name = T` annotation trees (collected in the entry pre-pass; they
    -- shadow the stdlib) over the shared stdlib declarations. Global READS
    -- resolve through it — one pinned cell per referenced global, minted
    -- lazily (`global_cells`); WRITES stay the global-write policy diag.
    local file_globals = {} --: { [string]: unknown }
    local global_cells = {} --: { [string]: string }

    --: (string) -> (string | nil, string | nil)
    local function resolve_alias(name)
        local a = aliases[name]
        if a == nil then return nil, nil end
        return a.content, a.feature
    end

    -- Parse one type-grammar string: named buckets become diags here; a
    -- hard parse failure is its own bucket. Returns the At (nil when
    -- unusable). `quiet` suppresses the bucket/parse diags for probe reads.
    -- Shared by `--:` annotations, casts, and `--:: declare` bodies — ONE
    -- parse shape for every place the type grammar appears.
    --: (content: string, line: integer, col: integer, quiet: boolean) -> unknown
    local function parse_type_string(content, line, col, quiet)
        local ok, at, buckets, perr = pcall(annot.parse, content, resolve_alias)
        if not ok then
            diag("internal", line, col, "annotation parser crashed: " .. tostring(at))
            return nil
        end
        if quiet then return at end
        if buckets ~= nil then
            for i = 1, #buckets do
                diag("unsupported:annotation-" .. buckets[i], line, col,
                    "annotation uses `" .. buckets[i]
                        .. "` — outside the v0 annotation subset (that part reads as unknown)")
            end
        end
        if at == nil then
            diag("unsupported:annotation-parse", line, col,
                "annotation does not parse: " .. (perr or "?"))
        end
        return at
    end

    --: (ann: Ann, line: integer, quiet: boolean) -> unknown
    local function parse_ann(ann, line, quiet)
        return parse_type_string(ann.content, line, ann.col, quiet)
    end

    --: (x: unknown) -> x is At
    local function is_at(x) return type(x) == "table" end

    -- Consume the ANN_TYPE annotation at `key` (a line, usually), if any.
    --: (key: integer) -> unknown
    local function read_ann(key)
        local ann = anns[key]
        if ann == nil or ann.consumed == true then return nil end
        if ann.kind ~= defs.ANN_TYPE then return nil end
        ann.consumed = true
        return parse_ann(ann, key, false)
    end

    -- Probe-then-consume for the PRECEDING-LINE function annotation: only a
    -- type that parses as an arrow belongs to the function (a non-arrow on
    -- the preceding line is someone else's); an unparsable one is consumed
    -- loudly (it is an annotation of SOME kind, and silence would hide it).
    --: (key: integer) -> unknown
    local function read_fn_ann(key)
        local ann = anns[key]
        if ann == nil or ann.consumed == true then return nil end
        if ann.kind ~= defs.ANN_TYPE then return nil end
        local probe = parse_ann(ann, key, true)
        if is_at(probe) and probe.k ~= "fn" then return nil end
        ann.consumed = true
        return parse_ann(ann, key, false)
    end

    -- At -> lattice Val. Function types mint fresh, pin-seeded param cells
    -- (the annotation's contravariant face lives in the pins; the cells give
    -- the arrow its identity). Bucketed subtrees read as unknown, or the
    -- `table` atom where table-ness is certain.
    --
    -- MEMOIZED on At node identity: alias expansion shares subtrees (the At
    -- is a DAG — see annot), so a naive walk is exponential on large alias
    -- graphs. Shared At nodes convert once per file; the resulting Vals are
    -- immutable and safe to share (a shared arrow shares its param cells —
    -- one declared type, one identity).
    local atval_memo = {}
    local at_val_raw
    --: (x: unknown) -> x is Val
    local function is_val(x) return type(x) == "table" end
    --: (unknown) -> Val
    local function at_val(at)
        if not is_at(at) then return UNKNOWN_VAL end
        local hit = atval_memo[at] --: unknown
        if is_val(hit) then return hit end
        local v = at_val_raw(at)
        atval_memo[at] = v
        return v
    end
    --: (unknown) -> Val
    at_val_raw = function(at)
        if not is_at(at) then return UNKNOWN_VAL end
        local k = at.k
        if k == "atom" then
            local name = at.name
            if type(name) == "string" then return lattice.single(name) end
            return UNKNOWN_VAL
        elseif k == "unknown" then
            return UNKNOWN_VAL
        elseif k == "never" then
            return lattice.of({})
        elseif k == "union" then
            local parts = at.parts
            local v = lattice.of({}) --: Val
            if is_tbl(parts) then
                for i = 1, #parts do
                    local pv = lattice.lattice.join(v, at_val(parts[i]))
                    if lattice.as_val(pv) then v = pv end
                end
            end
            return v
        elseif k == "record" then
            local fields = {} --: { [string]: Field }
            local fs = at.fields
            if is_tbl(fs) then
                for i = 1, #fs do
                    local f = fs[i]
                    if is_tbl(f) then
                        local fv = at_val(f.at)
                        if f.optional == true then
                            local j = lattice.lattice.join(fv, NIL_VAL)
                            if lattice.as_val(j) then fv = j end
                        end
                        local w = fv --: Val
                        if f.readonly == true then w = lattice.of({}) end
                        local name = f.name
                        if type(name) == "string" then
                            fields[name] = { r = fv, w = w }
                        end
                    end
                end
            end
            return lattice.record_rw(fields)
        elseif k == "fn" then
            local params = {} --: { [integer]: Param }
            local ps = at.params
            if is_tbl(ps) then
                for i = 1, #ps do
                    local p0 = ps[i]
                    if is_tbl(p0) then
                        local pat = p0.at
                        local pv = at_val(pat)
                        if p0.optional == true then
                            local j = lattice.lattice.join(pv, NIL_VAL)
                            if lattice.as_val(j) then pv = j end
                        end
                        local c = fresh("annp")
                        -- a pin that DEGRADED to unknown (bucketed feature)
                        -- carries no checking value: leave the param
                        -- unpinned so argument inference proceeds. Explicit
                        -- `unknown` stays a real pin (that is its meaning).
                        if lattice.is_unknown(pv) and not (is_at(pat) and pat.k == "unknown") then
                            params[#params + 1] = { cell = c, pin = nil }
                        else
                            seed(c, pv)
                            params[#params + 1] = { cell = c, pin = pv }
                        end
                    end
                end
            end
            local results = {} --: { [integer]: Val }
            local rs = at.results
            if is_tbl(rs) then
                for i = 1, #rs do results[i] = at_val(rs[i]) end
            end
            local rest = nil --: Val | nil
            if at.rest ~= nil then rest = at_val(at.rest) end
            return lattice.fn_val(params, results, at.vararg == true, rest, at.open == true)
        elseif k == "opaque" then
            if at.approx == "table" then return lattice.single("table") end
            return UNKNOWN_VAL
        end
        -- a tuple outside result position, or an unexpected node: honest top.
        return UNKNOWN_VAL
    end

    -- The contravariant seeding for an fn-typed VALUE annotation: whatever
    -- flows into `src` must accept the annotation's params — seed the pin
    -- types into the inflowing arrow's UNPINNED param cells so its body is
    -- checked against them (pinned params are checked by fn_leq in the ann
    -- obligation instead).
    --: (src: string, pinval: Val) -> nil
    local function ann_flow(src, pinval)
        local pfn = pinval.fn
        if pfn == nil then return nil end
        rules[#rules + 1] = engine.rule({ src }, {}, function(get)
            local out = {} --: { [string]: unknown }
            local v = get(src)
            if lattice.as_val(v) then
                local afn = v.fn
                if afn ~= nil then
                    for j = 1, #afn.params do
                        local ap = afn.params[j]
                        if ap.pin == nil then
                            local pj = pfn.params[j]
                            if pj ~= nil and pj.pin ~= nil then
                                out[ap.cell] = pj.pin
                            end
                        end
                    end
                end
            end
            return out
        end)
        return nil
    end

    -- A cell fixed at an annotated type (the PIN half of pin+check).
    --: (tag: string, pinval: Val) -> string
    local function pinned_cell(tag, pinval)
        local c = fresh("pin-" .. tag)
        seed(c, pinval)
        return c
    end

    -- Is this annotation USABLE as a pin? An explicit `unknown` is — that
    -- IS its meaning (callers must narrow). A type that merely DEGRADED to
    -- unknown through a bucket (unreadable alias, generic, ...) is NOT: a
    -- ⊤ pin carries no checking value, and seeding it would DESTROY the
    -- inference the cell already has. The bucket diag names the boundary;
    -- inference proceeds.
    --: (at: unknown, pinval: Val) -> boolean
    local function usable_pin(at, pinval)
        if not lattice.is_unknown(pinval) then return true end
        return is_at(at) and at.k == "unknown"
    end

    -- Resolve a global READ through the global environment: per-file
    -- `--:: declare` trees first, then the shared stdlib declarations.
    -- One pinned cell per referenced global per file, minted lazily (the
    -- shared At trees are converted only for globals this file touches —
    -- the cheap side of the interning split; the parse side is shared
    -- process-wide in the globals module). nil = genuinely undeclared.
    --: (name: string) -> string | nil
    local function global_cell(name)
        local c = global_cells[name]
        if c ~= nil then return c end
        local at = file_globals[name]
        if at == nil then at = globals.lookup(name) end
        if at == nil then return nil end
        local cell = pinned_cell("g-" .. name, at_val(at))
        global_cells[name] = cell
        return cell
    end

    -- ── scopes / versions ──────────────────────────────────────────────────

    --: () -> nil
    local function push_scope()
        depth = depth + 1
        local s = { map = {}, order = {} } --: Scope
        scopes[depth] = s
        return nil
    end

    --: () -> nil
    local function pop_scope()
        local s = scopes[depth]
        depth = depth - 1
        for i = 1, #s.order do
            local d = s.order[i]
            if not d.read and d.name:sub(1, 1) ~= "_" then
                diag("unused-local", d.line, d.col, "local '" .. d.name .. "' is never read")
            end
        end
        return nil
    end

    --: (name: string, line: integer, col: integer, cell: string, read: boolean) -> Decl
    local function declare(name, line, col, cell, read)
        counter = counter + 1
        local d = { id = name .. "#" .. counter, name = name, line = line, col = col, read = read, cell = cell, pin = nil } --: Decl
        local s = scopes[depth]
        s.map[name] = d
        s.order[#s.order + 1] = d
        return d
    end

    --: (string) -> Decl | nil
    local function resolve(name)
        for i = depth, 1, -1 do
            local d = scopes[i].map[name]
            if d ~= nil then return d end
        end
        return nil
    end

    -- All visible decls (innermost shadowing outer), for branch snapshots.
    --: () -> { [integer]: Decl }
    local function visible()
        local seen = {} --: { [string]: boolean }
        local out = {} --: { [integer]: Decl }
        for i = depth, 1, -1 do
            local s = scopes[i]
            for j = 1, #s.order do
                local d = s.order[j]
                if not seen[d.name] then
                    seen[d.name] = true
                    out[#out + 1] = d
                end
            end
        end
        return out
    end

    --: ({ [integer]: Decl }) -> { [string]: string }
    local function snapshot(vis)
        local r = {} --: { [string]: string }
        for i = 1, #vis do r[vis[i].id] = vis[i].cell end
        return r
    end

    --: ({ [integer]: Decl }, { [string]: string }) -> nil
    local function restore(vis, snap)
        for i = 1, #vis do
            local d = vis[i]
            local c = snap[d.id]
            if c ~= nil then d.cell = c end
        end
        return nil
    end

    -- ── forward declarations (mutual recursion: exprs contain bodies).
    -- Unannotated on purpose: the checker types them at their assignment
    -- sites below (annotated there), same idiom as parse.lua.
    local lower_expr, lower_stmts, lower_call

    -- ── havoc scan (soundness fence around unsupported subtrees) ──────────
    -- Marks identifier reads (no false "unused"), and havocs outer locals
    -- assigned inside the unchecked region to `unknown`. A FIELD write
    -- (`t.x = …`, `t[k] = …`, `function t.f()`) havocs the BASE variable:
    -- a record type must not survive unchecked mutation of the table.

    -- The root identifier of an assignment-target chain (`a.b[c].d` -> `a`);
    -- nil when the root is not a plain identifier.
    --: (unknown) -> string | nil
    local function target_root_name(t)
        local cur = t --: unknown
        while is_tbl(cur) do
            local tt = cur.tag
            if type(tt) == "number" then
                if tt == defs.NODE_IDENTIFIER then
                    local nm = cur.name
                    if type(nm) == "string" then return nm end
                    return nil
                elseif tt == defs.NODE_FIELD_EXPR or tt == defs.NODE_INDEX_EXPR then
                    cur = cur.target
                else
                    return nil
                end
            else
                return nil
            end
        end
        return nil
    end

    -- Havoc one variable: an ANNOTATED variable resets to its PIN (the
    -- annotation is the contract the unchecked region is trusted against —
    -- stated in the header); an unannotated one to unknown.
    --: (Decl) -> nil
    local function havoc_decl(d)
        local pin = d.pin
        if pin ~= nil then
            local c = fresh("havoc-pin-" .. d.name)
            seed(c, pin)
            d.cell = c
        else
            d.cell = unknown_cell("havoc-" .. d.name)
        end
        return nil
    end

    --: (unknown) -> nil
    local function havoc_scan(x)
        if not is_tbl(x) then return nil end
        local tag = x.tag
        if type(tag) == "number" then
            if tag == defs.NODE_IDENTIFIER then
                local nm = x.name
                if type(nm) == "string" then
                    local d = resolve(nm)
                    if d ~= nil then d.read = true end
                end
            elseif tag == defs.NODE_ASSIGN_STMT then
                local targets = x.targets
                if is_tbl(targets) then
                    for _, t in pairs(targets) do
                        local nm = target_root_name(t)
                        if nm ~= nil then
                            local d = resolve(nm)
                            if d ~= nil then havoc_decl(d) end
                        end
                    end
                end
            elseif tag == defs.NODE_FUNC_DECL then
                local nm = target_root_name(x.name)
                if nm ~= nil then
                    local d = resolve(nm)
                    if d ~= nil then havoc_decl(d) end
                end
            end
        end
        for _, v in pairs(x) do
            if is_tbl(v) then havoc_scan(v) end
        end
        return nil
    end

    -- ── shared construct pieces (each used by exactly the constructs whose
    --    semantics share them — not solver branches) ───────────────────────

    -- A function body: fresh scope; one UNSEEDED cell per param (a
    -- cell-as-unknown — call sites flow argument types in); one result cell
    -- per return position, wired once the max return arity is known; ONE
    -- rebuild rule proposing the function VALUE from its result cells
    -- (params ride as constant cell ids — the lattice header explains the
    -- polarity split). `recurse_decl`, when given, is bound to the function
    -- cell BEFORE the body lowers, so `local function f` sees its own arrow.
    --: (Ast, Decl | nil) -> string
    local function lower_function(n, recurse_decl)
        -- The definition-site annotation: `--: (a: T) -> R` on the line
        -- ABOVE the `function` keyword (the house grammar's only
        -- param/return form). Pins params and result positions.
        local fnat = read_fn_ann(n.line - 1)
        local anp = nil --: unknown
        local anr = nil --: unknown
        local an_rest = nil --: unknown
        local an_vararg = false
        local an_open = false
        if is_at(fnat) and fnat.k == "fn" then
            anp = fnat.params
            anr = fnat.results
            an_rest = fnat.rest
            an_vararg = fnat.vararg == true
            an_open = fnat.open == true
        end

        push_scope()
        ret_depth = ret_depth + 1
        local frame = { returns = {}, pins = nil } --: Frame
        ret_frames[ret_depth] = frame
        local params = {} --: { [integer]: Param }
        local nparams = n.params
        if is_list(nparams) then
            for i = 1, #nparams do
                local nm = nparams[i].name
                if type(nm) == "string" then
                    -- the pin for this position: the annotation's param i;
                    -- past the annotation's arity the callee receives nil
                    -- (Lua) unless the annotation is vararg (then its rest
                    -- bound, or unknown when unstated).
                    local pin = nil --: Val | nil
                    if is_tbl(anp) then
                        local ap = anp[i]
                        if is_tbl(ap) then
                            local p = at_val(ap.at)
                            if ap.optional == true then
                                local j = lattice.lattice.join(p, NIL_VAL)
                                if lattice.as_val(j) then p = j end
                            end
                            -- a degraded-to-unknown pin carries no checking
                            -- value: leave the param to inference.
                            if usable_pin(ap.at, p) then pin = p end
                        elseif an_vararg then
                            if an_rest ~= nil then pin = at_val(an_rest) else pin = UNKNOWN_VAL end
                        else
                            pin = NIL_VAL
                        end
                    end
                    local c = fresh("param-" .. nm)
                    -- params are exempt from unused-local (read = true):
                    -- callbacks legitimately ignore params.
                    local d = declare(nm, n.line, n.col, c, true)
                    if pin ~= nil then
                        seed(c, pin)
                        d.pin = pin
                        params[#params + 1] = { cell = c, pin = pin }
                    else
                        params[#params + 1] = { cell = c, pin = nil }
                        obligate_param_witness(c, nm, n.line, n.col)
                    end
                end
            end
        end
        -- annotated returns pin the frame BEFORE the body lowers: each
        -- return statement checks per position against these. A result list
        -- that degraded ENTIRELY to unknown pins nothing — inference keeps
        -- its precision (`-> ()` is informative: zero results).
        local pins = nil --: { [integer]: Val } | nil
        if is_tbl(anr) then
            local ps = {} --: { [integer]: Val }
            local any_usable = #anr == 0
            for i = 1, #anr do
                ps[i] = at_val(anr[i])
                if usable_pin(anr[i], ps[i]) then any_usable = true end
            end
            if any_usable then
                pins = ps
                frame.pins = pins
            end
        end
        local fcell = fresh("fn")
        if recurse_decl ~= nil then recurse_decl.cell = fcell end
        local body = n.body
        if is_list(body) then lower_stmts(body) end

        local vararg = n.vararg == true or an_vararg
        local rest = nil --: Val | nil
        if an_rest ~= nil then rest = at_val(an_rest) end
        if pins ~= nil then
            -- PINNED results: the arrow's interface IS the annotation
            -- (returns were obligated per position at each return site).
            local fnv = lattice.fn_val(params, pins, vararg, rest, an_open)
            rules[#rules + 1] = engine.rule({}, { fcell }, function(get)
                return { [fcell] = fnv }
            end)
            ret_depth = ret_depth - 1
            pop_scope()
            return fcell
        end

        -- INFERRED results: wire returns into result-position cells. A
        -- return shorter than the max arity pads with nil (Lua call
        -- semantics); a call/vararg spread in last position contributes
        -- unknown AND marks the arrow OPEN.
        local returns = frame.returns
        local maxk = 0
        local open = false
        for i = 1, #returns do
            local r = returns[i]
            if #r.cells > maxk then maxk = #r.cells end
            if r.spread then open = true end
        end
        local rcells = {} --: { [integer]: string }
        for i = 1, maxk do rcells[i] = fresh("ret" .. i) end
        for i = 1, #returns do
            local r = returns[i]
            for k = 1, maxk do
                local c = r.cells[k]
                if c ~= nil then
                    flow(c, rcells[k])
                elseif r.spread then
                    seed(rcells[k], UNKNOWN_VAL)
                else
                    seed(rcells[k], NIL_VAL)
                end
            end
        end
        rules[#rules + 1] = engine.rule(rcells, { fcell }, function(get)
            local results = {} --: { [integer]: Val }
            for i = 1, maxk do
                local v = get(rcells[i])
                if lattice.as_val(v) then
                    results[i] = lattice.clip(v, CLIP_DEPTH)
                else
                    results[i] = NIL_VAL
                end
            end
            return { [fcell] = lattice.fn_val(params, results, vararg, rest, open) }
        end)
        ret_depth = ret_depth - 1
        pop_scope()
        return fcell
    end

    -- Lower an expression list into `want` source cells. A call/method in
    -- LAST position spreads its per-position results into the remaining
    -- targets (Lua multi-return); a trailing vararg fills with `unknown`
    -- (the vararg boundary); anything else pads with `nil` (Lua semantics).
    --: ({ [integer]: Ast }, integer) -> { [integer]: string }
    local function lower_value_list(exprs, want)
        local cells = {} --: { [integer]: string }
        local nexpr = #exprs
        for i = 1, nexpr - 1 do
            cells[i] = lower_expr(exprs[i])
        end
        if nexpr == 0 then
            for i = 1, want do cells[i] = atom_cell("nil") end
            return cells
        end
        local last = exprs[nexpr]
        local t = last.tag
        if want > nexpr and (t == defs.NODE_CALL_EXPR or t == defs.NODE_METHOD_CALL) then
            local rc = lower_call(last, want - nexpr + 1)
            for j = 1, #rc do cells[nexpr + j - 1] = rc[j] end
            return cells
        end
        cells[nexpr] = lower_expr(last)
        if want > nexpr then
            local spread = t == defs.NODE_VARARG_EXPR
            for i = nexpr + 1, want do
                if spread then
                    cells[i] = unknown_cell("spread")
                else
                    cells[i] = atom_cell("nil")
                end
            end
        end
        return cells
    end

    -- The literal-string key of an index expression (`t["x"]`), nil when the
    -- key is any other expression — the `unsupported:dynamic-index` boundary.
    --: (unknown) -> string | nil
    local function literal_string_key(k)
        if not is_node(k) then return nil end
        if k.tag ~= defs.NODE_LITERAL then return nil end
        local lk = k.lit_kind
        local v = k.value
        if type(lk) == "number" and lk == defs.LIT_STRING and type(v) == "string" then return v end
        return nil
    end

    -- A field READ from an already-lowered target cell: ONE projection rule
    -- (the record analogue of the truthy/falsy filters) + ONE field-read
    -- obligation. Returns the projected cell.
    --: (tc: string, key: string, what: string, line: integer, col: integer) -> string
    local function field_read_from(tc, key, what, line, col)
        local rc = fresh("field-" .. key)
        rules[#rules + 1] = engine.rule({ tc }, { rc }, function(get)
            return { [rc] = lattice.project(get(tc), key) }
        end)
        obligate_field_read(tc, key, what, line, col)
        return rc
    end

    -- A field READ (`t.x` / `t["x"]` / the receiver half of `t:m()`).
    --: (target: Ast, key: string, what: string, line: integer, col: integer) -> string
    local function lower_field_read(target, key, what, line, col)
        return field_read_from(lower_expr(target), key, what, line, col)
    end

    -- The shared call core: ONE rule that (a) flows argument values into the
    -- callee's UNPINNED param cells (inference; pinned params are checked by
    -- the call obligation instead, and an fn-typed pin seeds its own pins
    -- into an fn-typed argument's param cells — the contravariant face), and
    -- (b) flows each wanted result position out (per-position; truncation /
    -- nil-extension per Lua call semantics; result-open arrows and the
    -- `function` top yield unknown). Plus the callee-shape and per-argument
    -- obligations. Returns the result-position cells.
    --: (cc: string, argcells: { [integer]: string }, inits: { [integer]: boolean }, want: integer, what: string, line: integer, col: integer) -> { [integer]: string }
    local function call_core(cc, argcells, inits, want, what, line, col)
        local rcells = {} --: { [integer]: string }
        for i = 1, want do rcells[i] = fresh("call" .. i) end
        local reads = { cc } --: { [integer]: string }
        for i = 1, #argcells do reads[#reads + 1] = argcells[i] end
        rules[#rules + 1] = engine.rule(reads, rcells, function(get)
            local out = {} --: { [string]: unknown }
            local v = get(cc)
            if not lattice.as_val(v) then return out end
            if lattice.is_bottom(v) then return out end
            local fn = lattice.fn_of(v)
            if fn ~= nil then
                for i = 1, #fn.params do
                    local p = fn.params[i]
                    local pin = p.pin
                    if pin == nil then
                        -- inference: the argument (or Lua's nil pad) flows in.
                        if i <= #argcells then
                            local av = get(argcells[i])
                            if lattice.as_val(av) then
                                out[p.cell] = lattice.clip(av, CLIP_DEPTH)
                            end
                        else
                            out[p.cell] = NIL_VAL
                        end
                    else
                        -- pinned: checked by the call obligation. An
                        -- fn-typed pin seeds its param pins into an
                        -- fn-typed argument's UNPINNED param cells so the
                        -- callback body is checked against what the callee
                        -- may pass (contravariance, operationalized).
                        local pfn = lattice.fn_of(pin)
                        if pfn ~= nil and i <= #argcells then
                            local av = get(argcells[i])
                            if lattice.as_val(av) then
                                local afn = lattice.fn_of(av)
                                if afn ~= nil then
                                    for j = 1, #afn.params do
                                        local ap = afn.params[j]
                                        if ap.pin == nil then
                                            local pj = pfn.params[j]
                                            if pj ~= nil and pj.pin ~= nil then
                                                out[ap.cell] = pj.pin
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
            for i = 1, want do
                local rv = UNKNOWN_VAL --: Val
                if fn ~= nil then
                    local r = fn.results[i]
                    if r ~= nil then
                        rv = r
                    elseif not fn.open then
                        rv = NIL_VAL
                    end
                end
                out[rcells[i]] = rv
            end
            return out
        end)
        obligate(cc, FUNC, "call-non-function", what, line, col)
        obligate_call(cc, argcells, inits, what, line, col)
        return rcells
    end

    -- A call expression (plain or method), lowered for `want` result
    -- positions. `require(<literal>)` — Lua's module boundary — is the
    -- honest `unsupported:cross-module` bucket: no module summaries in this
    -- increment, the results are unknown.
    --: (Ast, integer) -> { [integer]: string }
    lower_call = function(n, want)
        if n.tag == defs.NODE_CALL_EXPR then
            local callee = n.callee
            if not is_node(callee) then
                internal(n, "call without callee")
                local cells = {} --: { [integer]: string }
                for i = 1, want do cells[i] = unknown_cell("badcall") end
                return cells
            end
            local args = n.args
            if callee.tag == defs.NODE_IDENTIFIER and callee.name == "require"
                and resolve("require") == nil then
                if is_list(args) then
                    for i = 1, #args do lower_expr(args[i]) end
                end
                unsupported(n, "cross-module")
                local cells = {} --: { [integer]: string }
                for i = 1, want do cells[i] = unknown_cell("require") end
                return cells
            end
            local cc = lower_expr(callee)
            local acells = {} --: { [integer]: string }
            local inits = {} --: { [integer]: boolean }
            if is_list(args) then
                for i = 1, #args do
                    acells[i] = lower_expr(args[i])
                    inits[i] = args[i].tag == defs.NODE_TABLE_EXPR
                end
            end
            return call_core(cc, acells, inits, want, "called value", n.line, n.col)
        end
        -- t:m(...) = a field read of `m` + a call with the receiver as the
        -- implicit first argument (`function T:m` declared self the same way).
        local recv = n.receiver
        local method = n.method
        if not is_node(recv) or type(method) ~= "string" then
            internal(n, "malformed method call")
            local cells = {} --: { [integer]: string }
            for i = 1, want do cells[i] = unknown_cell("badmcall") end
            return cells
        end
        local tc = lower_expr(recv)
        local mc = field_read_from(tc, method, "method '" .. method .. "'", n.line, n.col)
        local acells = { tc } --: { [integer]: string }
        local inits = { false } --: { [integer]: boolean }
        local args = n.args
        if is_list(args) then
            for i = 1, #args do
                acells[#acells + 1] = lower_expr(args[i])
                inits[#inits + 1] = args[i].tag == defs.NODE_TABLE_EXPR
            end
        end
        return call_core(mc, acells, inits, want, "method '" .. method .. "'", n.line, n.col)
    end

    -- A field WRITE (`t.x = v`, `t["x"] = v`, `function M.f()`). When the
    -- base is a plain local, the write SSA-rebinds it through ONE set_field
    -- rule (flow-sensitive extension: the module idiom `local M = {}` +
    -- `function M.f() end` accretes fields on M's versions). Field types are
    -- invariant refs, so writes to EXISTING fields never change the type —
    -- for nested bases (`a.b.c = v`) no rebind is needed at all; the write
    -- is checked in place against the field's `w` bound. Non-literal keys
    -- are the `unsupported:dynamic-index` boundary.
    --: (Ast, string) -> nil
    local function lower_field_write(t, vcell)
        local key = nil --: string | nil
        if t.tag == defs.NODE_FIELD_EXPR then
            local k = t.key
            if type(k) == "string" then key = k end
        else
            key = literal_string_key(t.key)
        end
        local target = t.target
        if not is_node(target) then
            internal(t, "field write without a target")
            return nil
        end
        if key == nil then
            lower_expr(target)
            local k = t.key
            if is_node(k) then lower_expr(k) end
            unsupported(t, "dynamic-index")
            return nil
        end
        if target.tag == defs.NODE_IDENTIFIER then
            local nm = target.name
            if type(nm) == "string" then
                local d = resolve(nm)
                if d ~= nil then
                    -- mutation counts as use: `local M = {}; M.f = …` is not
                    -- an unused local even before anyone reads M.
                    d.read = true
                    local bc = d.cell
                    local nc = fresh(nm .. "-set-" .. key)
                    rules[#rules + 1] = engine.rule({ bc, vcell }, { nc }, function(get)
                        return { [nc] = lattice.set_field(get(bc), key, get(vcell)) }
                    end)
                    d.cell = nc
                    obligate_field_write(vcell, bc, key, t.line, t.col)
                    return nil
                end
            end
        end
        local bc = lower_expr(target)
        obligate_field_write(vcell, bc, key, t.line, t.col)
        return nil
    end

    -- The local a `type(<local>)` call tests, when the call is exactly that
    -- shape and `type` is the stdlib global (not shadowed by a local).
    --: (unknown) -> Decl | nil
    local function type_call_target(e)
        if not is_node(e) then return nil end
        if e.tag ~= defs.NODE_CALL_EXPR then return nil end
        local callee = e.callee
        if not is_node(callee) then return nil end
        if callee.tag ~= defs.NODE_IDENTIFIER then return nil end
        if callee.name ~= "type" or resolve("type") ~= nil then return nil end
        local args = e.args
        if not is_list(args) then return nil end
        if #args ~= 1 then return nil end
        local a1 = args[1]
        if not is_node(a1) then return nil end
        if a1.tag ~= defs.NODE_IDENTIFIER then return nil end
        local nm = a1.name
        if type(nm) ~= "string" then return nil end
        return resolve(nm)
    end

    -- The type()-tag string literal of an expression, nil otherwise.
    --: (unknown) -> string | nil
    local function tag_literal(e)
        if not is_node(e) then return nil end
        if e.tag ~= defs.NODE_LITERAL then return nil end
        local lk = e.lit_kind
        local v = e.value
        if type(lk) == "number" and lk == defs.LIT_STRING and type(v) == "string"
            and lattice.is_type_tag(v) then
            return v
        end
        return nil
    end

    -- The tested local of a plain-identifier expression, nil otherwise.
    --: (unknown) -> Decl | nil
    local function ident_target(e)
        if not is_node(e) then return nil end
        if e.tag ~= defs.NODE_IDENTIFIER then return nil end
        local nm = e.name
        if type(nm) ~= "string" then return nil end
        return resolve(nm)
    end

    --: (unknown) -> boolean
    local function is_nil_literal(e)
        return is_node(e) and e.tag == defs.NODE_LITERAL and e.lit_kind == defs.LIT_NIL
    end

    -- If `cond` is narrowable in v0, return the tested local's decl plus
    -- the then/else FILTER MODES (filter_flow vocabulary). Recognized:
    -- a bare local (truthy/falsy), `not <local>` (swapped), the tag guards
    -- `type(x) == "…"` / `type(x) ~= "…"` in either operand order
    -- (keep:<tag> / drop:<tag>), and the nil-equality guards `x == nil` /
    -- `x ~= nil` (the SAME keep/drop filters at the nil tag — equality with
    -- the nil literal IS the type()-tag test for nil). Richer guards
    -- (and/or chains) are later increments of the SAME mechanism.
    --: (Ast) -> (Decl | nil, string, string)
    local function cond_target(cond)
        if cond.tag == defs.NODE_IDENTIFIER then
            local nm = cond.name
            if type(nm) == "string" then return resolve(nm), "truthy", "falsy" end
        elseif cond.tag == defs.NODE_UNARY_EXPR then
            local op = cond.op
            local operand = cond.operand
            if op == "not" and is_node(operand) and operand.tag == defs.NODE_IDENTIFIER then
                local nm = operand.name
                if type(nm) == "string" then return resolve(nm), "falsy", "truthy" end
            end
        elseif cond.tag == defs.NODE_BINARY_EXPR then
            local op = cond.op
            if op == "==" or op == "~=" then
                local d = type_call_target(cond.lhs)
                local tag = tag_literal(cond.rhs)
                if d == nil or tag == nil then
                    d = type_call_target(cond.rhs)
                    tag = tag_literal(cond.lhs)
                end
                if d ~= nil and tag ~= nil then
                    if op == "==" then
                        return d, "keep:" .. tag, "drop:" .. tag
                    end
                    return d, "drop:" .. tag, "keep:" .. tag
                end
                local nd = ident_target(cond.lhs)
                local lit = is_nil_literal(cond.rhs)
                if nd == nil or not lit then
                    nd = ident_target(cond.rhs)
                    lit = is_nil_literal(cond.lhs)
                end
                if nd ~= nil and lit then
                    if op == "==" then
                        return nd, "keep:nil", "drop:nil"
                    end
                    return nd, "drop:nil", "keep:nil"
                end
            end
        end
        return nil, "truthy", "falsy"
    end

    -- A call expression that provably NEVER RETURNS (a diverging call): the
    -- callee is a plain identifier whose DECLARED type is a `-> never` arrow
    -- — a local pinned by annotation, or a declared global (the stdlib's
    -- `error`). Used by the reachability discipline: a statement list ending
    -- in such a call cannot fall through, so it contributes nothing to the
    -- enclosing merge. Syntactic + declaration-driven only (an INFERRED
    -- never-result is not consulted — lowering runs before the solve).
    --: (unknown) -> boolean
    local function call_diverges(e)
        if not is_node(e) then return false end
        if e.tag ~= defs.NODE_CALL_EXPR then return false end
        local callee = e.callee
        if not is_node(callee) then return false end
        if callee.tag ~= defs.NODE_IDENTIFIER then return false end
        local nm = callee.name
        if type(nm) ~= "string" then return false end
        local d = resolve(nm)
        if d ~= nil then
            local pin = d.pin
            if pin == nil then return false end
            local fn = pin.fn
            if fn == nil then return false end
            return #fn.results == 1 and lattice.is_bottom(fn.results[1])
        end
        local at = file_globals[nm] --: unknown
        if at == nil then at = globals.lookup(nm) end
        if not is_at(at) then return false end
        if at.k ~= "fn" then return false end
        local rs = at.results --: unknown
        if not is_list(rs) then return false end
        if #rs ~= 1 then return false end
        local r1 = rs[1] --: unknown
        return is_tbl(r1) and r1.k == "never"
    end

    -- ── expressions ────────────────────────────────────────────────────────

    --: (Ast) -> string
    lower_expr = function(n)
        local tag = n.tag
        if tag == defs.NODE_LITERAL then
            local k = n.lit_kind
            if type(k) == "number" then
                if k == defs.LIT_NIL then return atom_cell("nil") end
                if k == defs.LIT_BOOLEAN then
                    -- the literal atoms: `true`/`false` are distinct lattice
                    -- values (boolean is their union) — what keeps
                    -- `cond and a or b` from leaking a phantom boolean.
                    if n.value == true then return atom_cell("true") end
                    return atom_cell("false")
                end
                if k == defs.LIT_INTEGER or k == defs.LIT_NUMBER then return atom_cell("number") end
                if k == defs.LIT_STRING then return atom_cell("string") end
            end
            unsupported(n, "opaque-key-literal")
            return unknown_cell("opaque")
        elseif tag == defs.NODE_IDENTIFIER then
            local nm = n.name
            if type(nm) ~= "string" then
                internal(n, "identifier without a name")
                return unknown_cell("bad-ident")
            end
            local d = resolve(nm)
            if d ~= nil then
                d.read = true
                return d.cell
            end
            -- declared globals (per-file `--:: declare` / the stdlib
            -- environment) read at their declared type; only genuinely
            -- undeclared names are the policy diag.
            local g = global_cell(nm)
            if g ~= nil then return g end
            diag("undeclared-global", n.line, n.col,
                "undeclared global '" .. nm .. "' (crescent has no ambient globals; its type is unknown here)")
            return unknown_cell("g-" .. nm)
        elseif tag == defs.NODE_UNARY_EXPR then
            local operand = n.operand
            local op = n.op
            local oc = "" --: string
            if is_node(operand) then
                oc = lower_expr(operand)
            else
                internal(n, "unary without operand")
                oc = unknown_cell("unop")
            end
            if type(op) ~= "string" then
                internal(n, "unary without op")
                return unknown_cell("unop")
            end
            local bound, result = unop_rule(op)
            if result == nil then
                internal(n, "unknown unary op '" .. op .. "'")
                return unknown_cell("unop")
            end
            if bound ~= nil then
                obligate(oc, bound, "op-mismatch", "operand of unary '" .. op .. "'", n.line, n.col)
            end
            return atom_cell(result)
        elseif tag == defs.NODE_BINARY_EXPR then
            local lhs = n.lhs
            local rhs = n.rhs
            local op = n.op
            if not is_node(lhs) or not is_node(rhs) or type(op) ~= "string" then
                internal(n, "malformed binary expression")
                return unknown_cell("binop")
            end
            local lc = lower_expr(lhs)
            local rc = lower_expr(rhs)
            local bound, result, derive = binop_rule(op)
            if derive ~= nil then
                -- and/or: DERIVED from the lattice's falsy/truthy — the
                -- result cell joins filter(lhs) with type(rhs). No special
                -- case; the same transfer narrowing uses.
                local c = fresh(op)
                filter_flow(lc, c, derive)
                flow(rc, c)
                return c
            end
            if result == nil then
                internal(n, "unknown binary op '" .. op .. "'")
                return unknown_cell("binop")
            end
            if bound ~= nil then
                obligate(lc, bound, "op-mismatch", "left operand of '" .. op .. "'", lhs.line, lhs.col)
                obligate(rc, bound, "op-mismatch", "right operand of '" .. op .. "'", rhs.line, rhs.col)
            end
            return atom_cell(result)
        elseif tag == defs.NODE_CALL_EXPR or tag == defs.NODE_METHOD_CALL then
            -- expression position takes the FIRST result (Lua truncates);
            -- lower_value_list asks lower_call for more when spreading.
            local cells = lower_call(n, 1)
            return cells[1]
        elseif tag == defs.NODE_FIELD_EXPR then
            local target = n.target
            local key = n.key
            if not is_node(target) or type(key) ~= "string" then
                internal(n, "malformed field expression")
                return unknown_cell("field")
            end
            return lower_field_read(target, key, "field '" .. key .. "'", n.line, n.col)
        elseif tag == defs.NODE_INDEX_EXPR then
            local target = n.target
            local key = n.key
            if not is_node(target) then
                internal(n, "index without a target")
                return unknown_cell("index")
            end
            local k = literal_string_key(key)
            if k ~= nil then
                -- t["x"] IS t.x — same projection, same obligation.
                return lower_field_read(target, k, "field '" .. k .. "'", n.line, n.col)
            end
            lower_expr(target)
            if is_node(key) then lower_expr(key) end
            unsupported(n, "dynamic-index")
            return unknown_cell("index")
        elseif tag == defs.NODE_FUNC_EXPR then
            return lower_function(n, nil)
        elseif tag == defs.NODE_TABLE_EXPR then
            -- A constructor with named fields IS a record type: ONE rule
            -- proposing record_of over the field-value cells (duplicate keys:
            -- last wins, as in Lua). The array part and computed keys are the
            -- honest deferral buckets; their values are still lowered.
            local entries = {} --: { [integer]: { name: string, cell: string } }
            local fields = n.fields
            local array_flagged = false
            if is_list(fields) then
                for i = 1, #fields do
                    local f = fields[i]
                    local fk = f.field_kind
                    local v = f.value
                    local vc = nil --: string | nil
                    if is_node(v) then vc = lower_expr(v) end
                    if fk == "named" then
                        local k = f.key
                        if type(k) == "string" then
                            -- a same-line `--: T` pins this field's ref type
                            -- (`body = nil, --: string | nil`); it belongs
                            -- to the LAST field starting on the line.
                            local nxt = fields[i + 1]
                            if nxt == nil or nxt.line ~= f.line then
                                local at = read_ann(f.line)
                                if is_at(at) then
                                    local pinval = at_val(at)
                                    if usable_pin(at, pinval) then
                                        if type(vc) == "string" then
                                            local init = is_node(v) and v.tag == defs.NODE_TABLE_EXPR
                                            obligate_ann(vc, pinval, init, "annotation-mismatch",
                                                "field '" .. k .. "'", f.line, f.col)
                                            if pinval.fn ~= nil then ann_flow(vc, pinval) end
                                        end
                                        vc = pinned_cell("field-" .. k, pinval)
                                    end
                                end
                            end
                            if type(vc) == "string" then
                                entries[#entries + 1] = { name = k, cell = vc }
                            end
                        end
                    elseif fk == "positional" then
                        if not array_flagged then
                            array_flagged = true
                            unsupported(f, "table-array-part")
                        end
                    else
                        local k = f.key
                        if is_node(k) then lower_expr(k) end
                        unsupported(f, "dynamic-index")
                    end
                end
            end
            local tcell = fresh("table")
            local reads = {} --: { [integer]: string }
            for i = 1, #entries do reads[i] = entries[i].cell end
            rules[#rules + 1] = engine.rule(reads, { tcell }, function(get)
                local fieldvals = {} --: { [string]: Val }
                for i = 1, #entries do
                    local val = get(entries[i].cell)
                    if lattice.as_val(val) then fieldvals[entries[i].name] = val end
                end
                return { [tcell] = lattice.record_of(fieldvals) }
            end)
            return tcell
        elseif tag == defs.NODE_VARARG_EXPR then
            unsupported(n, "vararg")
            return unknown_cell("vararg")
        elseif tag == defs.NODE_CAST_EXPR then
            local inner = n.expr
            local ic = "" --: string
            local has_inner = false
            if is_node(inner) then
                ic = lower_expr(inner)
                has_inner = true
            end
            local ann = nil --: Ann | nil
            local aid = n.annotation_id
            if type(aid) == "number" then ann = anns[aid] end
            if ann == nil then
                internal(n, "cast without a captured annotation")
                return unknown_cell("cast")
            end
            ann.consumed = true
            local at = parse_ann(ann, n.line, false)
            if not is_at(at) then return unknown_cell("cast") end
            local pinval = at_val(at)
            if n.force == true then
                -- `--[[:! T]]`: the named force-cast policy (default error;
                -- per conventions force casts are almost never correct).
                diag("force-cast", n.line, n.col,
                    "force cast to `" .. lattice.show(pinval)
                        .. "` — use a checked cast or fix the producer")
            end
            if not usable_pin(at, pinval) then
                -- the asserted type degraded to unknown (bucketed feature):
                -- the cast can neither check nor sharpen — keep the inner
                -- flow rather than destroying it.
                if has_inner then return ic end
                return unknown_cell("cast")
            end
            if has_inner and n.force ~= true then
                -- `--[[: T]]`: CHECKED — the expression must satisfy T
                -- (an unknown source is the use-before-narrow class).
                local init = is_node(inner) and inner.tag == defs.NODE_TABLE_EXPR
                obligate_ann(ic, pinval, init, "cast-mismatch", "checked cast", n.line, n.col)
                if pinval.fn ~= nil then ann_flow(ic, pinval) end
            end
            -- the flow continues at the asserted type (that is what a cast
            -- is FOR); the obligation above keeps it honest.
            return pinned_cell("cast", pinval)
        elseif tag == defs.NODE_MATCH_EXPR then
            -- walker-only synthetic; never parser-emitted. Routed anyway.
            unsupported(n, "match-expr")
            return unknown_cell("match")
        end
        internal(n, "node kind '" .. frontend.node_name(tag) .. "' in expression position")
        return unknown_cell("unexpected")
    end

    -- ── statements ─────────────────────────────────────────────────────────

    -- `if`/`elseif`/`else` with truthiness narrowing and join-at-merge.
    -- Clause i's else-path IS clauses i+1.. (+ else block) — one recursion,
    -- so elseif chains get the same narrowing/merge as plain if/else.
    --
    -- REACHABILITY AT THE MERGE: a branch that cannot fall through (its
    -- lowering ends in return / break / a declared-never call — a DIVERGING
    -- branch) contributes NOTHING to the phi; the merge takes only the
    -- reachable branches' versions. This is what makes the early-exit idiom
    -- narrow: `if type(x) ~= "string" then return end` leaves x at the
    -- ELSE-arm's keep:string version after the if. Returns whether the
    -- whole if diverges (every path ends in a definite jump).
    --: ({ [integer]: Ast }, integer, { [integer]: Ast } | nil) -> boolean
    local function lower_if_from(clauses, i, else_body)
        local clause = clauses[i]
        local cond = clause.cond
        if not is_node(cond) then
            internal(clause, "if-clause without condition")
            return false
        end
        lower_expr(cond)
        local vis = visible()
        local pre = snapshot(vis)
        local d, then_mode, else_mode = cond_target(cond)

        -- then-arm: the condition's filter (truthy for a bare guard;
        -- keep/drop tag filters for `type(x) == "…"` and nil equality).
        if d ~= nil then
            local nc = fresh(d.name .. "-then")
            filter_flow(d.cell, nc, then_mode)
            d.cell = nc
        end
        local then_div = false
        local body = clause.body
        if is_list(body) then
            push_scope()
            then_div = lower_stmts(body)
            pop_scope()
        end
        local then_snap = snapshot(vis)
        restore(vis, pre)

        -- else-arm: the complementary filter, then the rest of the chain.
        -- An ABSENT else still narrows: the fall-through path is the
        -- else-arm (this is what the early-exit idiom merges with).
        if d ~= nil then
            local ec = fresh(d.name .. "-else")
            filter_flow(d.cell, ec, else_mode)
            d.cell = ec
        end
        local else_div = false
        if i < #clauses then
            else_div = lower_if_from(clauses, i + 1, else_body)
        elseif else_body ~= nil then
            push_scope()
            else_div = lower_stmts(else_body)
            pop_scope()
        end
        local else_snap = snapshot(vis)
        restore(vis, pre)

        -- merge: only REACHABLE branch versions meet at the phi; a diverging
        -- branch's version is skipped (its narrowing never leaks). Both arms
        -- diverging makes the merge point unreachable: fresh BOTTOM cells —
        -- code below is checked against no values (obligations on bottom are
        -- vacuous), which is exact for dead code.
        for k = 1, #vis do
            local dk = vis[k]
            local t = then_snap[dk.id]
            local e = else_snap[dk.id]
            if t ~= nil and e ~= nil then
                if then_div and else_div then
                    dk.cell = fresh(dk.name .. "-unreachable")
                elseif then_div then
                    dk.cell = e
                elseif else_div then
                    dk.cell = t
                elseif t == e then
                    dk.cell = t
                else
                    local phi = fresh(dk.name .. "-phi")
                    flow(t, phi)
                    flow(e, phi)
                    dk.cell = phi
                end
            end
        end
        return then_div and else_div
    end

    -- Lower one statement. Returns true when the statement DIVERGES (cannot
    -- fall through: return, break, a declared-never call, or an if whose
    -- every path diverges) — the reachability bit the merges consume.
    --: (Ast) -> boolean
    local function lower_stmt(n)
        local tag = n.tag
        if tag == defs.NODE_LOCAL_STMT then
            local names = n.names
            local exprs = n.exprs
            if not is_list(names) then
                internal(n, "local without names")
                return false
            end
            -- the same-line `--: T` annotation (single-name locals; consumed
            -- BEFORE the value list so a constructor's fields on this line
            -- cannot claim it). Multi-name annotated locals are ambiguous —
            -- a named bucket, not a guess.
            local at = nil --: unknown
            if #names == 1 then
                at = read_ann(n.line)
            elseif anns[n.line] ~= nil and anns[n.line].kind == defs.ANN_TYPE
                and anns[n.line].consumed ~= true then
                anns[n.line].consumed = true
                unsupported(n, "annotation-multi-local")
            end
            local cells = {} --: { [integer]: string }
            if is_list(exprs) then
                cells = lower_value_list(exprs, #names)
            end
            if is_at(at) then
                -- PIN + CHECK: the local's cell is the annotation (readers
                -- see the interface); the initializer must agree (leq_init
                -- for a directly-ascribed fresh constructor).
                local nm = names[1].name
                local pinval = at_val(at)
                if type(nm) == "string" and usable_pin(at, pinval) then
                    if is_list(exprs) and #exprs >= 1 then
                        local e1 = exprs[1]
                        local init = e1.tag == defs.NODE_TABLE_EXPR
                        obligate_ann(cells[1], pinval, init, "annotation-mismatch",
                            "local '" .. nm .. "'", n.line, n.col)
                        if pinval.fn ~= nil then ann_flow(cells[1], pinval) end
                    end
                    local d = declare(nm, n.line, n.col, pinned_cell(nm, pinval), false)
                    d.pin = pinval
                    return false
                end
            end
            for i = 1, #names do
                local nm = names[i].name
                if type(nm) == "string" then
                    local c = cells[i]
                    if c == nil then c = atom_cell("nil") end
                    declare(nm, n.line, n.col, c, false)
                end
            end
            return false
        elseif tag == defs.NODE_ASSIGN_STMT then
            local targets = n.targets
            local exprs = n.exprs
            if not is_list(targets) or not is_list(exprs) then
                internal(n, "malformed assignment")
                return false
            end
            -- the same-line `--: T` annotation (single-target; consumed
            -- before the value list, as for locals).
            local at = nil --: unknown
            if #targets == 1 then
                at = read_ann(n.line)
            elseif anns[n.line] ~= nil and anns[n.line].kind == defs.ANN_TYPE
                and anns[n.line].consumed ~= true then
                anns[n.line].consumed = true
                unsupported(n, "annotation-multi-target")
            end
            local cells = lower_value_list(exprs, #targets)
            for i = 1, #targets do
                local t = targets[i]
                local init = exprs[i] ~= nil and exprs[i].tag == defs.NODE_TABLE_EXPR
                if t.tag == defs.NODE_IDENTIFIER then
                    local nm = t.name
                    if type(nm) == "string" then
                        local d = resolve(nm)
                        if d ~= nil then
                            local c = cells[i]
                            if is_at(at) and usable_pin(at, at_val(at)) then
                                -- annotated assignment: pin from here on.
                                local pinval = at_val(at)
                                if c ~= nil then
                                    obligate_ann(c, pinval, init, "annotation-mismatch",
                                        "assignment to '" .. nm .. "'", t.line, t.col)
                                    if pinval.fn ~= nil then ann_flow(c, pinval) end
                                end
                                d.pin = pinval
                                d.cell = pinned_cell(nm, pinval)
                            else
                                local dp = d.pin
                                if dp ~= nil then
                                    -- the variable's own annotation: the
                                    -- value must agree; the cell REBINDS to
                                    -- the value (assignment narrowing
                                    -- survives the pin).
                                    if c ~= nil then
                                        obligate_ann(c, dp, init, "annotation-mismatch",
                                            "assignment to '" .. nm .. "'", t.line, t.col)
                                        d.cell = c
                                    end
                                elseif c ~= nil then
                                    d.cell = c
                                end
                            end
                        else
                            diag("global-write", t.line, t.col,
                                "write to global '" .. nm .. "' (crescent has no ambient mutable globals)")
                        end
                    end
                elseif t.tag == defs.NODE_FIELD_EXPR or t.tag == defs.NODE_INDEX_EXPR then
                    local c = cells[i]
                    if c == nil then c = atom_cell("nil") end
                    if is_at(at) then
                        -- annotated field write: the field's ref type IS the
                        -- annotation (`M._tier = nil --: string | nil`); the
                        -- written value must agree.
                        local pinval = at_val(at)
                        if usable_pin(at, pinval) then
                            obligate_ann(c, pinval, init, "annotation-mismatch",
                                "annotated field write", t.line, t.col)
                            if pinval.fn ~= nil then ann_flow(c, pinval) end
                            c = pinned_cell("fieldw", pinval)
                        end
                    end
                    lower_field_write(t, c)
                else
                    internal(t, "unexpected assignment target")
                end
            end
            return false
        elseif tag == defs.NODE_EXPR_STMT then
            -- a declared-never call (`error(...)`) diverges: the statement
            -- still lowers normally (arguments checked), but nothing after
            -- it in this block is reachable.
            local e = n.expr
            if is_node(e) then
                lower_expr(e)
                return call_diverges(e)
            end
            return false
        elseif tag == defs.NODE_DO_STMT then
            local body = n.body
            if is_list(body) then
                push_scope()
                local div = lower_stmts(body)
                pop_scope()
                return div
            end
            return false
        elseif tag == defs.NODE_IF_STMT then
            local clauses = n.clauses
            if is_list(clauses) and #clauses >= 1 then
                local else_body = n.else_body
                if is_list(else_body) then
                    return lower_if_from(clauses, 1, else_body)
                end
                return lower_if_from(clauses, 1, nil)
            end
            internal(n, "if without clauses")
            return false
        elseif tag == defs.NODE_RETURN_STMT then
            local frame_pins = nil --: unknown
            if ret_depth >= 1 then frame_pins = ret_frames[ret_depth].pins end
            --: (x: unknown) -> x is { [integer]: Val }
            local function is_pins(x) return type(x) == "table" end
            if is_pins(frame_pins) then
                local pins = frame_pins
                -- annotated function: each position is CHECKED against its
                -- pin here (missing positions are Lua's nil pad; a spread
                -- call's positions land per-position via lower_value_list);
                -- returns beyond the annotated count must be nil.
                local exprs = n.exprs
                local elist = {} --: { [integer]: Ast }
                if is_list(exprs) then elist = exprs end
                local want = #pins
                if #elist > want then want = #elist end
                local cells = lower_value_list(elist, want)
                for i = 1, #cells do
                    local pin = pins[i]
                    local init = elist[i] ~= nil and elist[i].tag == defs.NODE_TABLE_EXPR
                    if pin ~= nil then
                        obligate_ann(cells[i], pin, init, "annotation-mismatch",
                            "return value #" .. tostring(i), n.line, n.col)
                        if pin.fn ~= nil then ann_flow(cells[i], pin) end
                    else
                        obligate_ann(cells[i], NIL_VAL, false, "annotation-mismatch",
                            "return value #" .. tostring(i) .. " (beyond the annotated results)",
                            n.line, n.col)
                    end
                end
                return true
            end
            -- inferred function: record per-position cells on the enclosing
            -- frame; the function wires them once the max return arity is
            -- known. A call in LAST position forwards ALL its results in
            -- Lua — v0 carries its first result and marks the arrow
            -- result-OPEN (positions beyond are unknown); vararg likewise.
            local exprs = n.exprs
            local rec = { cells = {}, spread = false, line = n.line, col = n.col } --: Ret
            if is_list(exprs) then
                local ne = #exprs
                for i = 1, ne do
                    rec.cells[i] = lower_expr(exprs[i])
                    if i == ne then
                        local t = exprs[i].tag
                        if t == defs.NODE_CALL_EXPR or t == defs.NODE_METHOD_CALL
                            or t == defs.NODE_VARARG_EXPR then
                            rec.spread = true
                        end
                    end
                end
            end
            if ret_depth >= 1 then
                local frame = ret_frames[ret_depth]
                frame.returns[#frame.returns + 1] = rec
            end
            return true
        elseif tag == defs.NODE_FUNC_DECL then
            local name_node = n.name
            if is_node(name_node) and name_node.tag == defs.NODE_IDENTIFIER then
                local nm = name_node.name
                if type(nm) == "string" then
                    if n.is_local == true then
                        -- bind BEFORE the body: `local function f` sees
                        -- itself (recursion) — lower_function rebinds the
                        -- decl to the function cell before the body lowers.
                        local d = declare(nm, n.line, n.col, atom_cell("function"), false)
                        lower_function(n, d)
                    else
                        -- `function f() end`: assignment to f (a local if one
                        -- is visible, else an undeclared-global write).
                        local d = resolve(nm)
                        if d ~= nil then
                            lower_function(n, d)
                        else
                            lower_function(n, nil)
                            diag("global-write", n.line, n.col,
                                "write to global '" .. nm .. "' (crescent has no ambient mutable globals)")
                        end
                    end
                    return false
                end
            end
            -- `function M.f()` / `function M:f()` (the name is a field
            -- chain): the module idiom — a checked field write of the
            -- function value. (`:` already injected `self` as a param.)
            if is_node(name_node) and name_node.tag == defs.NODE_FIELD_EXPR then
                local c = lower_function(n, nil)
                lower_field_write(name_node, c)
                return false
            end
            -- funcname is Name{.Name}[:Name] — anything else is a decoder
            -- drift bug, surfaced loudly.
            if is_node(name_node) then lower_expr(name_node) end
            lower_function(n, nil)
            internal(n, "func-decl with an unexpected name shape")
            return false
        elseif tag == defs.NODE_WHILE_STMT or tag == defs.NODE_REPEAT_STMT
            or tag == defs.NODE_FOR_NUM or tag == defs.NODE_FOR_IN then
            unsupported(n, frontend.node_name(tag))
            havoc_scan(n)
            return false
        elseif tag == defs.NODE_BREAK_STMT then
            unsupported(n, "break-stmt")
            return false
        elseif tag == defs.NODE_GOTO_STMT then
            unsupported(n, "goto-stmt")
            return false
        elseif tag == defs.NODE_LABEL_STMT then
            unsupported(n, "label-stmt")
            return false
        elseif tag == defs.NODE_CHUNK or tag == defs.NODE_IF_CLAUSE or tag == defs.NODE_TABLE_FIELD then
            internal(n, "container node '" .. frontend.node_name(tag) .. "' in statement position")
            return false
        end
        -- expression kind in statement position (parser never emits this) —
        -- routed defensively, still total.
        internal(n, "node kind '" .. frontend.node_name(tag) .. "' in statement position")
        return false
    end

    -- Lower a statement list; true when the list cannot fall through (some
    -- statement diverges — in well-formed Lua that is the last one, since
    -- return/break must close a block).
    --: ({ [integer]: Ast }) -> boolean
    lower_stmts = function(list)
        local div = false
        for i = 1, #list do
            if lower_stmt(list[i]) then div = true end
        end
        return div
    end

    -- ── entry: annotation pre-pass ─────────────────────────────────────────
    -- `--::` declarations are position-independent: aliases go into the
    -- resolve environment up front; `declare name = T` bodies parse AFTER
    -- the alias sweep (a declare may reference an alias declared below it)
    -- into the file's global environment; every other form is a named
    -- bucket (`require` is the cross-module boundary). `--:<T>` call-site
    -- type arguments are their own bucket.
    --:: PendingDecl = { name: string, body: string, line: integer, col: integer }
    local pending_declares = {} --: { [integer]: PendingDecl }
    for key, ann in pairs(anns) do
        local line = 0
        if type(key) == "number" and key > 0 then line = math.floor(key) end
        if ann.kind == defs.ANN_DECL then
            local kind, a, b = annot.classify_decl(ann.content)
            if kind == "alias" then
                aliases[a] = { content = b, feature = nil }
            elseif kind == "declare" then
                pending_declares[#pending_declares + 1] =
                    { name = a, body = b or "", line = line, col = ann.col }
            elseif kind == "generic-alias" then
                aliases[a] = { content = nil, feature = "generic" }
                diag("unsupported:annotation-generic", line, ann.col,
                    "generic alias `" .. a .. "` — outside the v0 annotation subset")
            elseif kind == "feature" then
                diag("unsupported:" .. a, line, ann.col,
                    "`--:: " .. (ann.content:match("^%s*(%a+)") or "?")
                        .. "` declarations are outside the v0 annotation subset")
            else
                diag("unsupported:annotation-decl-parse", line, ann.col,
                    a .. ": `" .. ann.content:sub(1, 40) .. "`")
            end
            ann.consumed = true
        elseif ann.kind == defs.ANN_TYPE_ARGS then
            diag("unsupported:annotation-type-args", line, ann.col,
                "call-site type arguments (`--:<T>`) are outside the v0 annotation subset")
            ann.consumed = true
        end
    end
    for i = 1, #pending_declares do
        local pd = pending_declares[i]
        -- the same parse shape as `--:` annotations: buckets are named
        -- per feature; an unusable body still DECLARES the name (reads
        -- are unknown — declared-but-unreadable is not undeclared).
        local at = parse_type_string(pd.body, pd.line, pd.col, false)
        if is_at(at) then
            file_globals[pd.name] = at
        else
            file_globals[pd.name] = { k = "unknown" }
        end
    end

    -- ── entry: the chunk ───────────────────────────────────────────────────
    -- `vars` maps each top-level local to its FINAL cell — the readout for
    -- callers/tests that want inferred types by name.
    local vars = {} --: { [string]: string }
    if chunk.tag == defs.NODE_CHUNK then
        push_scope()
        ret_depth = 1
        -- the chunk's returns are recorded but unconsumed: the module
        -- summary (what `require` would see) is a later increment.
        ret_frames[1] = { returns = {}, pins = nil }
        local body = chunk.body
        if is_list(body) then lower_stmts(body) end
        local top = scopes[1]
        for i = 1, #top.order do
            local d = top.order[i]
            vars[d.name] = d.cell
        end
        pop_scope()
    else
        internal(chunk, "root is not a chunk")
    end

    return {
        graph = { lattice = lattice.lattice, rules = rules },
        obligations = obligations,
        diags = diags,
        vars = vars,
    }
end

-- The totality roster: every parser node kind and how it is routed —
-- "checked" (in the v0 discipline), "boundary" (honest unsupported
-- diagnostic), or "container" (only ever reached via its parent construct).
-- Tests assert this table covers all 30 kinds; the whole-lib smoke run is
-- the no-crash evidence.
local ROUTE = {} --: { [integer]: string }
ROUTE[defs.NODE_LITERAL] = "checked"
ROUTE[defs.NODE_IDENTIFIER] = "checked"
ROUTE[defs.NODE_UNARY_EXPR] = "checked"
ROUTE[defs.NODE_BINARY_EXPR] = "checked"
-- INDEX_EXPR: literal-string keys are checked (= field access); every other
-- key is the in-construct `unsupported:dynamic-index` boundary.
ROUTE[defs.NODE_INDEX_EXPR] = "checked"
ROUTE[defs.NODE_FIELD_EXPR] = "checked"
ROUTE[defs.NODE_METHOD_CALL] = "checked"
ROUTE[defs.NODE_CALL_EXPR] = "checked"
ROUTE[defs.NODE_FUNC_EXPR] = "checked"
-- TABLE_EXPR: named fields are checked (record construction); the array
-- part / computed keys are in-construct boundary buckets.
ROUTE[defs.NODE_TABLE_EXPR] = "checked"
ROUTE[defs.NODE_TABLE_FIELD] = "container"
ROUTE[defs.NODE_VARARG_EXPR] = "boundary"
ROUTE[defs.NODE_ASSIGN_STMT] = "checked"
ROUTE[defs.NODE_LOCAL_STMT] = "checked"
ROUTE[defs.NODE_DO_STMT] = "checked"
ROUTE[defs.NODE_WHILE_STMT] = "boundary"
ROUTE[defs.NODE_REPEAT_STMT] = "boundary"
ROUTE[defs.NODE_IF_STMT] = "checked"
ROUTE[defs.NODE_IF_CLAUSE] = "container"
ROUTE[defs.NODE_FOR_NUM] = "boundary"
ROUTE[defs.NODE_FOR_IN] = "boundary"
ROUTE[defs.NODE_RETURN_STMT] = "checked"
ROUTE[defs.NODE_BREAK_STMT] = "boundary"
ROUTE[defs.NODE_GOTO_STMT] = "boundary"
ROUTE[defs.NODE_LABEL_STMT] = "boundary"
ROUTE[defs.NODE_EXPR_STMT] = "checked"
ROUTE[defs.NODE_FUNC_DECL] = "checked"
ROUTE[defs.NODE_CHUNK] = "checked"
-- CAST_EXPR: checked casts are obligations, force casts the named policy;
-- unusable annotation strings are in-construct annotation-* buckets.
ROUTE[defs.NODE_CAST_EXPR] = "checked"
ROUTE[defs.NODE_MATCH_EXPR] = "boundary"
M.ROUTE = ROUTE

return M
