-- lib/type/v9/check.lua
-- The v9 RUNNER: Lua source (string or file) -> diagnostics with line/col.
-- parse (frontend seam) -> total lowering -> engine fixpoint -> obligation
-- evaluation -> policy-stamped, position-sorted diagnostics.
--
-- THE POWER DIAL LIVES HERE and nowhere else: `Policy` maps NAMED rule codes
-- to severities ("error" | "warn" | "info" | "off"; "off" suppresses the
-- diagnostic entirely). Strictness is owner-decidable data, never an
-- implementation choice buried in the solver. v0 defaults:
--
--   parse-error         error   the file is not Lua
--   op-mismatch         error   supported-discipline type error
--   call-non-function   error   supported-discipline type error
--   field-write-mismatch error  a field write outside the field's invariant
--                               write bound — the record mutation-soundness
--                               rule (see lattice.lua's header)
--   call-mismatch       error   an argument outside the callee's annotated
--                               parameter pin (incl. a missing argument
--                               whose nil pad the pin rejects)
--   annotation-mismatch error   inference DISAGREES with an annotation —
--                               either the code lies or the annotation does;
--                               both are real findings
--   cast-mismatch       error   a checked cast `--[[: T]]` whose expression
--                               provably does not satisfy T
--   force-cast          error   `--[[:! T]]` — per conventions force casts
--                               are almost never correct; dial down only
--                               with cause
--   internal            error   a lowering invariant broke (checker bug)
--   missing-field       warn    a field/method read the record provably
--                               lacks (v0 record tracking is intraprocedural
--                               — aliases don't see later extensions — so
--                               absence evidence is warn, not error; dial up
--                               once annotations land)
--   use-before-narrow   warn    unknown used dynamically — v0 cannot narrow
--                               it yet (cross-module summaries / index
--                               signatures are the roadmap); the dial makes
--                               the debt visible
--   undeclared-global   warn    no ambient globals: fires only for names
--                               NEITHER the stdlib environment (the globals
--                               seam) nor a per-file `--:: declare` covers
--   global-write        warn    write to a global (declared or not —
--                               crescent has no ambient MUTABLE globals)
--   unused-local        warn    declared, never read (syntactic in v0)
--   new-field-on-write  off     a write CREATED a field on an open record —
--                               the Lua module idiom, admitted by default.
--                               THE one named soundness concession: a field
--                               created through one alias is invisible (and
--                               at a colliding type, unsound) through
--                               another. Dial to error to forbid the idiom
--                               and close the hole.
--   unsupported         warn    the dynamism/coverage boundary, per bucket
--                               (`unsupported:<construct>` may be dialed
--                               individually; the bare prefix is the default)
--
-- Caps-first: file access is INJECTED (`Caps.read_file`); this module never
-- reaches for io. Errors are data: `(nil, errmsg)`, never thrown.

if not package.path:find("?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

--:: require "lib.type.v9.engine.defs"
--:: require "lib.type.v9.lattice"

local frontend = require("lib.type.v9.frontend")
local lower = require("lib.type.v9.lower")
local engine = require("lib.type.v9.engine.engine")
local lattice = require("lib.type.v9.lattice")

--:: Diag = { code: string, severity: string, message: string, line: integer, col: integer }
--:: Obligation = { kind: string, cell: string, allow: Val | nil, field: string | nil, base: string | nil, args: { [integer]: string } | nil, inits: { [integer]: boolean } | nil, init: boolean | nil, code: string, what: string, line: integer, col: integer }
--:: Policy = { [string]: string }
--:: Caps = { read_file: (string) -> (string | nil, string | nil) }
--:: CheckOpts = { policy: Policy | nil, mode: string | nil }

local M = {}

--: (x: unknown) -> x is Val
local function as_val(x) return type(x) == "table" end

-- The atom bound a field-access TARGET must stay within (records are tables).
local TABLE_ONLY = lattice.single("table")
-- Lua's pad for a missing argument/result position.
local NIL_ONLY = lattice.single("nil")

-- The named rules and their default severities, as data. (Built with
-- dynamic keys: the checker folds literal-key writes into the alias shape.)
local DEFAULT_RULES = {
    { "parse-error", "error" },
    { "op-mismatch", "error" },
    { "call-non-function", "error" },
    { "call-mismatch", "error" },
    { "field-write-mismatch", "error" },
    { "annotation-mismatch", "error" },
    { "cast-mismatch", "error" },
    { "force-cast", "error" },
    { "internal", "error" },
    { "missing-field", "warn" },
    { "use-before-narrow", "warn" },
    { "undeclared-global", "warn" },
    { "global-write", "warn" },
    { "unused-local", "warn" },
    { "new-field-on-write", "off" },
    { "unsupported", "warn" },
} --: { [integer]: { [integer]: string } }

--: () -> Policy
function M.default_policy()
    local p = {} --: Policy
    for i = 1, #DEFAULT_RULES do
        p[DEFAULT_RULES[i][1]] = DEFAULT_RULES[i][2]
    end
    return p
end

-- Resolve a diag code to a severity: exact rule, else its prefix family
-- (`unsupported:for-num` -> `unsupported`), else warn.
--: (Policy, string) -> string
local function severity_of(policy, code)
    local s = policy[code]
    if s ~= nil then return s end
    local prefix = code:match("^([^:]+):")
    if prefix ~= nil then
        local ps = policy[prefix]
        if ps ~= nil then return ps end
    end
    return "warn"
end
M.severity_of = severity_of

--: ({ [integer]: Diag }, Policy) -> nil
local function stamp(diags, policy)
    for i = 1, #diags do
        diags[i].severity = severity_of(policy, diags[i].code)
    end
    return nil
end

--: ({ [integer]: Diag }) -> nil
local function sort_by_position(diags)
    table.sort(diags, function(a, b)
        if a.line ~= b.line then return a.line < b.line end
        if a.col ~= b.col then return a.col < b.col end
        return a.code < b.code
    end)
    return nil
end

-- Best-effort position out of a parser errmsg ("file:line:col: msg").
--: (string) -> (integer, integer)
local function error_position(errmsg)
    local l, c = errmsg:match(":(%d+):(%d+):")
    local line = tonumber(l)
    local col = tonumber(c)
    if line ~= nil and col ~= nil then return math.floor(line), math.floor(col) end
    return 0, 0
end

--: (x: unknown) -> x is { graph: Graph, obligations: { [integer]: Obligation }, diags: { [integer]: Diag }, vars: { [string]: string } }
local function is_lower_result(x) return type(x) == "table" end

--: (diags: { [integer]: Diag }, code: string, line: integer, col: integer, message: string) -> nil
local function emit(diags, code, line, col, message)
    -- severity is stamped by the policy afterwards.
    diags[#diags + 1] = { code = code, severity = "warn", line = line, col = col, message = message }
    return nil
end

-- Shared triage of a field-access TARGET value. Emits the target-shaped
-- diagnostics and reports whether field-level checking may proceed:
--   unknown           -> use-before-narrow
--   string only       -> unsupported:string-method (stdlib decls pending)
--   non-table atoms   -> op-mismatch (naming the offending parts)
--   bare `table` top  -> use-before-narrow (fields unknown; narrow it)
-- A record component (with or without the field) returns true; the caller
-- decides between ok / missing-field / new-field-on-write.
--: (diags: { [integer]: Diag }, v: Val, what: string, line: integer, col: integer) -> boolean
local function triage_field_target(diags, v, what, line, col)
    if lattice.is_unknown(v) then
        emit(diags, "use-before-narrow", line, col,
            what .. " target has type `unknown` — narrow it before dynamic use")
        return false
    end
    if lattice.is_string_only(v) then
        emit(diags, "unsupported:string-method", line, col,
            what .. " on `string` (the string metatable) needs stdlib declarations — outside v0")
        return false
    end
    local bad = lattice.excess(v, TABLE_ONLY)
    if bad ~= nil then
        emit(diags, "op-mismatch", line, col,
            what .. " target: got `" .. lattice.show(v) .. "`, expected a table")
        return false
    end
    if not lattice.has_rec(v) then
        -- only the `table` top remains: some table, fields unknown.
        emit(diags, "use-before-narrow", line, col,
            what .. " target has type `table` — fields unknown; construct with known fields or narrow")
        return false
    end
    return true
end

-- Evaluate ONE post-solve obligation against the fixpoint values.
--: (diags: { [integer]: Diag }, values: { [string]: unknown }, ob: Obligation) -> nil
local function evaluate_obligation(diags, values, ob)
    local v = values[ob.cell]
    if not as_val(v) then return nil end

    if ob.kind == "param-witness" then
        -- the ONE obligation that asks for evidence of INHABITATION: a
        -- still-bottom parameter means no in-file call reaches it and no
        -- annotation pins it — the body was checked against no inputs.
        if lattice.is_bottom(v) then
            emit(diags, ob.code, ob.line, ob.col,
                ob.what .. " is never constrained (no in-file call site, no annotation)"
                    .. " — the body is unchecked against real inputs; annotate to check")
        end
        return nil
    end

    if lattice.is_bottom(v) then return nil end

    if ob.kind == "call" then
        -- arguments against the callee's annotated parameter PINS (the
        -- contravariant face of the arrow; unpinned params take the
        -- argument FLOW instead and are checked by the body's own
        -- obligations). A missing argument is Lua's nil pad.
        local fn = v.fn
        if fn == nil then return nil end
        local args = ob.args
        if args == nil then return nil end
        local params = fn.params
        for i = 1, #params do
            local pin = params[i].pin
            if pin ~= nil then
                local av = nil --: unknown
                if i <= #args then av = values[args[i]] end
                local avv = NIL_ONLY --: Val
                local missing = true
                if av ~= nil and as_val(av) then
                    avv = av
                    missing = false
                end
                if not (not missing and lattice.is_bottom(avv)) and not lattice.is_unknown(pin) then
                    -- a direct-constructor argument is a fresh construction
                    -- ascribed by the pin: initialization ordering.
                    local inits = ob.inits
                    local ok = false
                    if inits ~= nil and inits[i] == true then
                        ok = lattice.leq_init(avv, pin)
                    else
                        ok = lattice.leq(avv, pin)
                    end
                    if lattice.is_unknown(avv) then
                        emit(diags, "use-before-narrow", ob.line, ob.col,
                            "argument #" .. tostring(i) .. " to " .. ob.what
                                .. " has type `unknown` — the parameter expects `"
                                .. lattice.show(pin) .. "`; narrow it first")
                    elseif not ok then
                        local got = lattice.show(avv)
                        if missing then got = got .. " (missing argument)" end
                        emit(diags, ob.code, ob.line, ob.col,
                            "argument #" .. tostring(i) .. " to " .. ob.what .. ": got `"
                                .. got .. "`, the parameter expects `" .. lattice.show(pin) .. "`")
                    end
                end
            end
        end
        -- a ⊤ rest bound is vacuous (everything satisfies `...unknown`,
        -- and an unknown value against it is not a finding) — same rule as
        -- the ann obligation's ⊤ check. Without this, every argument to a
        -- `(...unknown)`-declared stdlib fn (print, string.format) would
        -- flood use-before-narrow.
        local rest = fn.rest
        if fn.vararg and rest ~= nil and not lattice.is_unknown(rest) then
            for i = #params + 1, #args do
                local av = values[args[i]]
                if av ~= nil and as_val(av) and not lattice.is_bottom(av) then
                    if lattice.is_unknown(av) then
                        emit(diags, "use-before-narrow", ob.line, ob.col,
                            "argument #" .. tostring(i) .. " to " .. ob.what
                                .. " has type `unknown` — the rest parameter expects `"
                                .. lattice.show(rest) .. "`; narrow it first")
                    elseif not lattice.leq(av, rest) then
                        emit(diags, ob.code, ob.line, ob.col,
                            "argument #" .. tostring(i) .. " to " .. ob.what .. ": got `"
                                .. lattice.show(av) .. "`, the rest parameter expects `"
                                .. lattice.show(rest) .. "`")
                    end
                end
            end
        end
        return nil
    end

    if ob.kind == "ann" then
        -- annotation/cast agreement: the value must satisfy the annotated
        -- type (leq; leq_init for a directly-ascribed fresh constructor —
        -- the ascription re-types the constructor's field refs). `unknown`
        -- is the can't-verify class, not a disagreement.
        local allow = ob.allow
        if allow == nil then return nil end
        -- a ⊤ bound is vacuous: everything satisfies it, and an unknown
        -- VALUE against it is not a finding either.
        if lattice.is_unknown(allow) then return nil end
        if lattice.is_unknown(v) then
            emit(diags, "use-before-narrow", ob.line, ob.col,
                ob.what .. " has type `unknown` — `" .. lattice.show(allow)
                    .. "` is asserted but cannot be verified; narrow the value first")
            return nil
        end
        local ok = false
        if ob.init == true then
            ok = lattice.leq_init(v, allow)
        else
            ok = lattice.leq(v, allow)
        end
        if not ok then
            emit(diags, ob.code, ob.line, ob.col,
                ob.what .. ": got `" .. lattice.show(v) .. "`, the annotation says `"
                    .. lattice.show(allow) .. "`")
        end
        return nil
    end

    if ob.kind == "field-read" then
        local field = ob.field
        if field == nil then return nil end
        if triage_field_target(diags, v, ob.what, ob.line, ob.col) then
            if not lattice.has_field(v, field) then
                emit(diags, "missing-field", ob.line, ob.col,
                    "no " .. ob.what .. " on `" .. lattice.show(v) .. "`")
            end
        end
        return nil
    end

    if ob.kind == "field-write" then
        -- ob.cell is the WRITTEN VALUE's cell; ob.base is the target's
        -- pre-write version. The write must satisfy the field's invariant
        -- `w` bound (mutation soundness — lattice.lua header).
        local field = ob.field
        local basecell = ob.base
        if field == nil or basecell == nil then return nil end
        local base = values[basecell]
        if not as_val(base) then return nil end
        if lattice.is_bottom(base) then return nil end
        if not triage_field_target(diags, base, "write to " .. ob.what, ob.line, ob.col) then
            return nil
        end
        local w = lattice.field_write_bound(base, field)
        if w == nil then
            emit(diags, "new-field-on-write", ob.line, ob.col,
                ob.what .. " created by write on `" .. lattice.show(base)
                    .. "` (invisible through aliases — the open-record concession)")
            return nil
        end
        if lattice.is_unknown(v) then
            emit(diags, "use-before-narrow", ob.line, ob.col,
                "value written to " .. ob.what .. " has type `unknown` — narrow it before the write")
            return nil
        end
        if not lattice.leq(v, w) then
            emit(diags, ob.code, ob.line, ob.col,
                "write to " .. ob.what .. ": got `" .. lattice.show(v)
                    .. "`, the field's write bound is `" .. lattice.show(w) .. "`")
        end
        return nil
    end

    -- kind == "bound": the original upper-bound obligation.
    local allow = ob.allow
    if allow == nil then return nil end
    if lattice.is_unknown(v) then
        emit(diags, "use-before-narrow", ob.line, ob.col,
            ob.what .. " has type `unknown` — narrow it before dynamic use")
        return nil
    end
    local excess = lattice.excess(v, allow)
    if excess ~= nil then
        emit(diags, ob.code, ob.line, ob.col,
            ob.what .. ": got `" .. lattice.show(v) .. "`, expected `" .. lattice.show(allow) .. "`")
    end
    return nil
end

-- Check a source string. Returns position-sorted, policy-stamped diags.
-- `opts.mode = "lower"` skips the solve (parse + total lowering only — the
-- totality smoke path); default is the full check.
--: (source: string, filename: string, opts: CheckOpts | nil) -> ({ [integer]: Diag } | nil, string | nil)
function M.check_source(source, filename, opts)
    local policy = M.default_policy()
    local mode = "full"
    if opts ~= nil then
        local op = opts.policy
        if op ~= nil then policy = op end
        local om = opts.mode
        if om ~= nil then mode = om end
    end

    local ast, perr = frontend.parse(source, filename)
    if ast == nil then
        local msg = perr or "parse error"
        local line, col = error_position(msg)
        local diags = {} --: { [integer]: Diag }
        diags[1] = { code = "parse-error", severity = "warn", message = msg, line = line, col = col }
        stamp(diags, policy)
        return diags, nil
    end

    -- Totality is the lowering's contract; a crash here is a checker bug,
    -- surfaced as data at this seam (and counted by the smoke run).
    local ok, res = pcall(lower.lower, ast)
    if not ok then return nil, filename .. ": lowering crashed: " .. tostring(res) end
    local low = res --: unknown
    if not is_lower_result(low) then return nil, filename .. ": lowering returned a non-result" end

    local diags = low.diags
    if mode ~= "lower" then
        local sol, serr = engine.solve(low.graph)
        if sol == nil then return nil, filename .. ": " .. (serr or "solve failed") end
        local obligations = low.obligations
        for i = 1, #obligations do
            evaluate_obligation(diags, sol.values, obligations[i])
        end
    end

    stamp(diags, policy)
    local kept = {} --: { [integer]: Diag }
    for i = 1, #diags do
        if diags[i].severity ~= "off" then kept[#kept + 1] = diags[i] end
    end
    sort_by_position(kept)
    return kept, nil
end

-- Check a file via injected caps (never reaches for io).
--: (caps: Caps, path: string, opts: CheckOpts | nil) -> ({ [integer]: Diag } | nil, string | nil)
function M.check_file(caps, path, opts)
    local src, err = caps.read_file(path)
    if src == nil then return nil, err or (path .. ": unreadable") end
    return M.check_source(src, path, opts)
end

-- Diagnostic counts by code — the coverage histogram (the roadmap view:
-- which unsupported buckets dominate, which discipline errors fire).
--: ({ [integer]: Diag }) -> { [string]: integer }
function M.histogram(diags)
    local h = {} --: { [string]: integer }
    for i = 1, #diags do
        local code = diags[i].code
        h[code] = (h[code] or 0) + 1
    end
    return h
end

-- Merge histogram `src` into `dst` (whole-tree aggregation).
--: (dst: { [string]: integer }, src: { [string]: integer }) -> nil
function M.merge_histogram(dst, src)
    for code, n in pairs(src) do
        dst[code] = (dst[code] or 0) + n
    end
    return nil
end

return M
