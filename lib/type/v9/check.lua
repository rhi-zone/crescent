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
--   index-write-mismatch error  a dynamic-key write outside the index
--                               part's invariant write bound — the same
--                               mutation-soundness rule as field writes
--   missing-field       warn    a field/method read the record provably
--                               lacks (v0 record tracking is intraprocedural
--                               — aliases don't see later extensions — so
--                               absence evidence is warn, not error; dial up
--                               once annotations land)
--   index-without-signature warn  a dynamic-key read on a record with NO
--                               index signature — the dynamism boundary for
--                               dynamic keys unless declared. Warn (not
--                               error) in v0: the tree is full of
--                               dynamic-key idioms on inferred records that
--                               annotations haven't reached yet; dial up as
--                               index annotations spread
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
--   new-index-on-write  off     the SAME concession for dynamic keys: a
--                               write GREW an index part on a part-less (or
--                               never-part) record — the `local t = {};
--                               t[k] = v` build idiom. Same aliasing hole,
--                               same dial.
--   unannotated-module-boundary off  a `require` site imported a summary
--                               whose return type is PURE INFERENCE (no
--                               annotation pins the module's returned
--                               value) — inferred summaries ARE cross-file
--                               contextual typing, and this dial is the
--                               owner's visibility into it (the "warn when
--                               cross-file contextual typing narrows a
--                               type" ask). Default off: inferred summaries
--                               are trusted across the boundary; dial up to
--                               see (warn) or forbid (error) them.
--   unsupported         warn    the dynamism/coverage boundary, per bucket
--                               (`unsupported:<construct>` may be dialed
--                               individually; the bare prefix is the
--                               default — `unsupported:cross-module` /
--                               `unsupported:cross-module-cycle` are the
--                               module-boundary buckets)
--
-- Caps-first: file access is INJECTED (`Caps.read_file`); this module never
-- reaches for io. Errors are data: `(nil, errmsg)`, never thrown.
--
-- CROSS-MODULE SUMMARIES ride a SESSION (M.session): checking a file that
-- requires others computes each dep's summary ON DEMAND through the same
-- runner — session-cached by path (the sha256 DISK cache of the legacy
-- checker is deliberately out of scope: session-only, stated), cycle-cut by
-- an in-progress set (the legacy `_checking` pattern — a participant's
-- in-progress summary is the honest unknown, never a deadlock).

if not package.path:find("?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

--:: require "lib.type.v9.engine.defs"
--:: require "lib.type.v9.summary"
--:: require "lib.type.v9.lattice"

local frontend = require("lib.type.v9.frontend")
local lower = require("lib.type.v9.lower")
local engine = require("lib.type.v9.engine.engine")
local lattice = require("lib.type.v9.lattice")
local modules = require("lib.type.v9.modules")
local summary_mod = require("lib.type.v9.summary")

--:: Diag = { code: string, severity: string, message: string, line: integer, col: integer }
--:: Obligation = { kind: string, cell: string, allow: Val | nil, field: string | nil, base: string | nil, key: string | nil, args: { [integer]: string } | nil, inits: { [integer]: boolean } | nil, init: boolean | nil, code: string, what: string, line: integer, col: integer }
--:: Policy = { [string]: string }
--:: Caps = { read_file: (string) -> (string | nil, string | nil) }
--:: Summary = { returns: { [integer]: unknown } | nil, annotated: boolean, aliases: { [string]: unknown }, cycle: boolean | nil }
--:: Deps = { summary: (name: string) -> (Summary | nil, string | nil) }
--:: CheckOpts = { policy: Policy | nil, mode: string | nil, deps: Deps | nil }
--:: Session = { summary: (name: string) -> (Summary | nil, string | nil), check_file: (path: string) -> ({ [integer]: Diag } | nil, string | nil, Summary | nil) }

local M = {}

--: (x: unknown) -> x is Val
local function as_val(x) return type(x) == "table" end

-- The atom bound a field-access TARGET must stay within (records are tables).
local TABLE_ONLY = lattice.single("table")
-- Lua's pad for a missing argument/result position.
local NIL_ONLY = lattice.single("nil")

--:: AtomLib = { atom: string, lib: Val }
--:: ReadMeta = { libs: { [integer]: AtomLib }, allow: Val, expected: string }

-- The READ-target meta view, built once per file from lowering's resolved
-- atom-metatable `__index` tables (globals.atom_index — LuaJIT wires
-- `string`'s metatable to the string library at boot): a field/index READ
-- target may be a table OR any wired atom whose table is declared; members
-- on a wired atom resolve through its declared table. UNIFORM over the
-- data — no atom is special-cased here. WRITE targets never take this view
-- (there is no `__newindex` wiring; writing e.g. a string is a runtime
-- error, an op-mismatch).
--: (atomlibs: { [integer]: AtomLib } | nil) -> ReadMeta | nil
local function read_meta(atomlibs)
    if atomlibs == nil then return nil end
    if #atomlibs == 0 then return nil end
    local names = { "table" } --: { [integer]: string }
    local expected = "a table" --: string
    for i = 1, #atomlibs do
        names[#names + 1] = atomlibs[i].atom
        expected = expected .. " or " .. atomlibs[i].atom
    end
    return { libs = atomlibs, allow = lattice.of(names), expected = expected }
end

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
    { "index-write-mismatch", "error" },
    { "missing-field", "warn" },
    { "use-before-narrow", "warn" },
    { "index-without-signature", "warn" },
    { "undeclared-global", "warn" },
    { "global-write", "warn" },
    { "unused-local", "warn" },
    { "new-field-on-write", "off" },
    { "new-index-on-write", "off" },
    { "unannotated-module-boundary", "off" },
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

--: (x: unknown) -> x is { graph: Graph, obligations: { [integer]: Obligation }, diags: { [integer]: Diag }, vars: { [string]: string }, atomlibs: { [integer]: AtomLib }, chunk_returns: { [integer]: Ret }, aliases: { [string]: unknown } }
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
--   non-table atoms   -> op-mismatch (naming the offending parts)
--   bare `table` top  -> use-before-narrow (fields unknown; narrow it)
-- `meta` is the READ-target meta view (read_meta — the atom-metatable
-- `__index` wiring): when given, targets admitting a wired atom are
-- admitted and resolve their members through the atom's declared table;
-- write targets pass nil (there is no `__newindex` wiring, so e.g. a
-- string write target is op-mismatch). A record component (with or
-- without the field) — or an admitted wired atom — returns true; the
-- caller decides ok / missing-field / new-field-on-write.
--: (diags: { [integer]: Diag }, v: Val, what: string, line: integer, col: integer, meta: ReadMeta | nil) -> boolean
local function triage_field_target(diags, v, what, line, col, meta)
    if lattice.is_unknown(v) then
        emit(diags, "use-before-narrow", line, col,
            what .. " target has type `unknown` — narrow it before dynamic use")
        return false
    end
    local allow = TABLE_ONLY --: Val
    local expected = "a table" --: string
    if meta ~= nil then
        allow = meta.allow
        expected = meta.expected
    end
    local bad = lattice.excess(v, allow)
    if bad ~= nil then
        emit(diags, "op-mismatch", line, col,
            what .. " target: got `" .. lattice.show(v) .. "`, expected " .. expected)
        return false
    end
    if lattice.has_rec(v) then return true end
    if meta ~= nil and not lattice.has_table_top(v) then
        -- a wired-atom(-only) target: members resolve through the atom's
        -- declared table — the caller consults meta.libs.
        local libs = meta.libs
        for i = 1, #libs do
            if lattice.has_atom(v, libs[i].atom) then return true end
        end
    end
    -- only the `table` top remains: some table, fields unknown.
    emit(diags, "use-before-narrow", line, col,
        what .. " target has type `table` — fields unknown; construct with known fields or narrow")
    return false
end

-- The loop/branch-merge hint: a PLAIN open record failing against an
-- index-bounded type is very often a table BUILT ACROSS MERGES (`local m =
-- {}` filled in a loop) — the join with the unbounded pre-loop `{}` drops
-- the index part (sound: a plain record's unnamed keys are unbounded), and
-- constructor freshness dies at the phi. The actionable fix is annotating
-- the DECLARATION: the pin carries the part through every merge and the
-- whole build is checked against it.
--: (v: Val, allow: Val) -> string
local function index_drop_hint(v, allow)
    if lattice.has_index(allow) and lattice.has_rec(v) and not lattice.has_index(v) then
        return " — a built table's index part survives neither loop/branch"
            .. " merges nor aliasing; annotate the DECLARATION (`local t ="
            .. " {} --: <this type>`) so the whole build is checked against it"
    end
    return ""
end

-- Evaluate ONE post-solve obligation against the fixpoint values. `meta`
-- is the READ-target meta view (nil when no wired atom's table is
-- declared): member reads on wired-atom targets resolve through it.
--: (diags: { [integer]: Diag }, values: { [string]: unknown }, ob: Obligation, meta: ReadMeta | nil) -> nil
local function evaluate_obligation(diags, values, ob, meta)
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
                                .. got .. "`, the parameter expects `" .. lattice.show(pin) .. "`"
                                .. index_drop_hint(avv, pin))
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
                    .. lattice.show(allow) .. "`" .. index_drop_hint(v, allow))
        end
        return nil
    end

    if ob.kind == "field-read" then
        local field = ob.field
        if field == nil then return nil end
        if triage_field_target(diags, v, ob.what, ob.line, ob.col, meta) then
            -- a string index part covers unnamed keys: the read is the
            -- (sound) `T | nil` index projection, not a missing field.
            local ok = lattice.has_field(v, field) or lattice.has_str_index(v)
            if not ok and meta ~= nil then
                -- a wired-atom target resolves members through the atom's
                -- declared table (its metatable's `__index`).
                local libs = meta.libs
                for i = 1, #libs do
                    local al = libs[i]
                    if lattice.has_atom(v, al.atom)
                        and (lattice.has_field(al.lib, field) or lattice.has_str_index(al.lib)) then
                        ok = true
                        break
                    end
                end
            end
            if not ok then
                emit(diags, "missing-field", ob.line, ob.col,
                    "no " .. ob.what .. " on `" .. lattice.show(v) .. "`")
            end
        end
        return nil
    end

    if ob.kind == "index-read" then
        -- dynamic-key read discipline: target triage first (unknown /
        -- string / non-table / table-top), then the KEY (unknown keys must
        -- narrow; keys outside string/number are the dynamic-index
        -- boundary), then the signature requirement — a read on a record
        -- with NO index part is the named dynamism boundary. One diag per
        -- read; an index-bounded target with a str/num key is fully checked
        -- (the projection already typed it `T | nil`).
        if not triage_field_target(diags, v, ob.what, ob.line, ob.col, meta) then
            return nil
        end
        local keycell = ob.key
        if keycell == nil then return nil end
        local kv = values[keycell]
        if not as_val(kv) then return nil end
        if lattice.is_bottom(kv) then return nil end
        local kk = lattice.key_kinds(kv)
        if kk.unknown then
            emit(diags, "use-before-narrow", ob.line, ob.col,
                ob.what .. " key has type `unknown` — narrow the key before dynamic use")
            return nil
        end
        if kk.other then
            emit(diags, "unsupported:dynamic-index", ob.line, ob.col,
                ob.what .. " key `" .. lattice.show(kv)
                    .. "` is outside the string/number index discipline (honest boundary; not checked)")
            return nil
        end
        if not lattice.has_index(v) then
            emit(diags, ob.code, ob.line, ob.col,
                ob.what .. " on `" .. lattice.show(v)
                    .. "` — no index signature declares its dynamic keys (annotate `{ [string]: T }` / `{ [number]: T }`)")
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
        if not triage_field_target(diags, base, "write to " .. ob.what, ob.line, ob.col, nil) then
            return nil
        end
        local w = lattice.field_write_bound(base, field)
        if w == nil then
            -- no named ref — but an index-bounded record's unnamed string
            -- keys are governed by its str part: a NAMED write IS a
            -- string-keyed write, checked against the part's bound (this
            -- is also what keeps freshness ownership-transfer sound: every
            -- write through a transferred map view stays checked). Writing
            -- nil deletes (as for dynamic keys); a never part means "no
            -- string keys yet" — growth, the named concession below.
            if lattice.has_str_index(base) then
                local pw = lattice.index_write_bound(base, "str")
                if pw ~= nil then
                    local vv = v --: Val
                    local dropped = lattice.tag_drop(v, "nil")
                    if as_val(dropped) then vv = dropped end
                    if lattice.is_bottom(vv) then return nil end
                    if lattice.is_unknown(vv) then
                        emit(diags, "use-before-narrow", ob.line, ob.col,
                            "value written to " .. ob.what
                                .. " has type `unknown` — narrow it before the write")
                        return nil
                    end
                    local ok = false
                    if ob.init == true then
                        ok = lattice.leq_init(vv, pw)
                    else
                        ok = lattice.leq(vv, pw)
                    end
                    if not ok then
                        emit(diags, ob.code, ob.line, ob.col,
                            "write to " .. ob.what .. ": got `" .. lattice.show(vv)
                                .. "`, the record's `[string]` index part bounds writes at `"
                                .. lattice.show(pw) .. "`")
                    end
                    return nil
                end
            end
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
        -- a direct-constructor written value is a fresh construction
        -- ascribed by the ref's bound (initialization ordering — the same
        -- rule dynamic-key writes already apply).
        local wok = false
        if ob.init == true then
            wok = lattice.leq_init(v, w)
        else
            wok = lattice.leq(v, w)
        end
        if not wok then
            emit(diags, ob.code, ob.line, ob.col,
                "write to " .. ob.what .. ": got `" .. lattice.show(v)
                    .. "`, the field's write bound is `" .. lattice.show(w) .. "`")
        end
        return nil
    end

    if ob.kind == "index-write" then
        -- dynamic-key write discipline, mirroring field writes: the written
        -- value must satisfy the touched index part's invariant `w` bound;
        -- growing a part on a part-less/never record is the named
        -- new-index-on-write concession. Key triage as for index reads.
        -- Writing nil DELETES the key in Lua (always legal — reads carry
        -- `| nil` for absence), so the nil part of the written value is
        -- outside the check; a direct-constructor write is a fresh
        -- construction ascribed by the bound (initialization ordering, as
        -- for call arguments — the `t[#t + 1] = {...}` append idiom).
        local basecell = ob.base
        local keycell = ob.key
        if basecell == nil or keycell == nil then return nil end
        local base = values[basecell]
        if not as_val(base) then return nil end
        if lattice.is_bottom(base) then return nil end
        if not triage_field_target(diags, base, "write at " .. ob.what, ob.line, ob.col, nil) then
            return nil
        end
        local kv = values[keycell]
        if not as_val(kv) then return nil end
        if lattice.is_bottom(kv) then return nil end
        local kk = lattice.key_kinds(kv)
        if kk.unknown then
            emit(diags, "use-before-narrow", ob.line, ob.col,
                ob.what .. " key has type `unknown` — narrow the key before dynamic use")
            return nil
        end
        if kk.other then
            emit(diags, "unsupported:dynamic-index", ob.line, ob.col,
                ob.what .. " key `" .. lattice.show(kv)
                    .. "` is outside the string/number index discipline (honest boundary; not checked)")
            return nil
        end
        local vv = v --: Val
        local dropped = lattice.tag_drop(v, "nil")
        if as_val(dropped) then vv = dropped end
        if lattice.is_bottom(vv) then return nil end
        local kinds = {} --: { [integer]: string }
        if kk.str then kinds[#kinds + 1] = "str" end
        if kk.num then kinds[#kinds + 1] = "num" end
        local grew = false
        for i = 1, #kinds do
            local w = lattice.index_write_bound(base, kinds[i])
            if w == nil then
                -- part-less record: the write GROWS the part.
                grew = true
            else
                if lattice.is_bottom(w) then
                    -- a never part ("no keys of this kind yet"): also growth.
                    grew = true
                elseif lattice.is_unknown(vv) then
                    emit(diags, "use-before-narrow", ob.line, ob.col,
                        "value written at " .. ob.what .. " has type `unknown` — narrow it before the write")
                    return nil
                else
                    local ok = false
                    if ob.init == true then
                        ok = lattice.leq_init(vv, w)
                    else
                        ok = lattice.leq(vv, w)
                    end
                    if not ok then
                        emit(diags, ob.code, ob.line, ob.col,
                            ob.what .. ": got `" .. lattice.show(vv)
                                .. "`, the index part's write bound is `" .. lattice.show(w) .. "`")
                        return nil
                    end
                end
            end
        end
        if grew then
            emit(diags, "new-index-on-write", ob.line, ob.col,
                ob.what .. " grew an index part on `" .. lattice.show(base)
                    .. "` (invisible through aliases — the open-record concession)")
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

-- Check a source string. Returns position-sorted, policy-stamped diags AND
-- (third value) the file's MODULE SUMMARY — its solved return type as At
-- data + its exported alias env (summary.lua states the form; returns is
-- nil when no solve ran). `opts.mode = "lower"` skips the solve (parse +
-- total lowering only — the totality smoke path); default is the full
-- check. `opts.deps` is the injected cross-module seam (a session's
-- `summary`); nil = single-file check, require sites stay the honest
-- boundary.
--: (source: string, filename: string, opts: CheckOpts | nil) -> ({ [integer]: Diag } | nil, string | nil, Summary | nil)
function M.check_source(source, filename, opts)
    local policy = M.default_policy()
    local mode = "full"
    local deps = nil --: Deps | nil
    if opts ~= nil then
        local op = opts.policy
        if op ~= nil then policy = op end
        local om = opts.mode
        if om ~= nil then mode = om end
        local od = opts.deps
        if od ~= nil then deps = od end
    end

    -- The lattice's pairwise memos (leq/join/meet/equal) are pure caches;
    -- reset per file so their strong pairs never accumulate dead per-file
    -- graphs across a session (measured ~20GB retained over a whole-lib
    -- run without the reset — lattice.reset_memo states why weak tables
    -- cannot express this).
    lattice.reset_memo()

    local ast, perr = frontend.parse(source, filename)
    if ast == nil then
        local msg = perr or "parse error"
        local line, col = error_position(msg)
        local diags = {} --: { [integer]: Diag }
        diags[1] = { code = "parse-error", severity = "warn", message = msg, line = line, col = col }
        stamp(diags, policy)
        return diags, nil, nil
    end

    -- Totality is the lowering's contract; a crash here is a checker bug,
    -- surfaced as data at this seam (and counted by the smoke run).
    local ok, res = pcall(lower.lower, ast, deps)
    if not ok then return nil, filename .. ": lowering crashed: " .. tostring(res), nil end
    local low = res --: unknown
    if not is_lower_result(low) then return nil, filename .. ": lowering returned a non-result", nil end

    local diags = low.diags
    local returns_at = nil --: { [integer]: unknown } | nil
    if mode ~= "lower" then
        local sol, serr = engine.solve(low.graph)
        if sol == nil then return nil, filename .. ": " .. (serr or "solve failed"), nil end
        local obligations = low.obligations
        local meta = read_meta(low.atomlibs)
        for i = 1, #obligations do
            evaluate_obligation(diags, sol.values, obligations[i], meta)
        end
        -- the module summary's return type: the chunk's solved returns,
        -- joined and exported as At DATA (never live cells — summary.lua).
        local mv = summary_mod.module_value(low.chunk_returns, sol.values)
        returns_at = { summary_mod.val_to_at(mv) }
    end
    local summary = {
        returns = returns_at,
        annotated = summary_mod.all_pinned(low.chunk_returns),
        aliases = low.aliases,
        cycle = nil,
    } --: Summary

    stamp(diags, policy)
    local kept = {} --: { [integer]: Diag }
    for i = 1, #diags do
        if diags[i].severity ~= "off" then kept[#kept + 1] = diags[i] end
    end
    sort_by_position(kept)
    return kept, nil, summary
end

-- Check a file via injected caps (never reaches for io).
--: (caps: Caps, path: string, opts: CheckOpts | nil) -> ({ [integer]: Diag } | nil, string | nil, Summary | nil)
function M.check_file(caps, path, opts)
    local src, err = caps.read_file(path)
    if src == nil then return nil, err or (path .. ": unreadable"), nil end
    return M.check_source(src, path, opts)
end

-- A CROSS-MODULE SESSION: demand-driven module summaries over injected
-- caps, cached by resolved path for the session's lifetime (the legacy
-- sha256 DISK cache is deliberately out of scope — session-only, stated).
--
--   session.summary(modname)  the module's summary, computing it by
--                              checking the module (full solve) on first
--                              demand — the seam `require` sites and
--                              `--:: require` imports consume via
--                              opts.deps.
--   session.check_file(path)  diags + summary for one file WITH
--                              cross-module resolution, session-cached: a
--                              file already solved as someone's dep is not
--                              solved again (what keeps the whole-lib smoke
--                              near-linear).
--
-- CYCLES (Lua allows them: B may require A mid-A-check): an in-progress
-- set — the legacy `_checking` tainted-set pattern — cuts re-entry by
-- handing the participant a shared `cycle = true` marker; the requiring
-- site emits `unsupported:cross-module-cycle` and reads unknown. Never a
-- deadlock, never unbounded recursion. A summary computed while one of its
-- deps was cycle-cut is honestly WIDER (the cut edge read unknown); it is
-- still cached for the session (stated, as legacy taints).
--
-- Summaries handed out are IMMUTABLE: importers read them, never write.
-- `opts.policy` applies to the session's internal checks (diags a summary
-- computation produced are cached and returned by check_file untouched).
--: (caps: Caps, opts: CheckOpts | nil) -> Session
function M.session(caps, opts)
    local resolver = modules.resolver(caps)
    --:: Entry = { summary: Summary | nil, diags: { [integer]: Diag } | nil, err: string | nil }
    local cache = {} --: { [string]: Entry }
    local in_progress = {} --: { [string]: boolean | nil }
    -- the shared cycle marker every in-cycle requester sees (immutable).
    local CYCLE = { returns = nil, annotated = false, aliases = {}, cycle = true } --: Summary

    local S = {}

    --: (path: string, src: string) -> Entry
    local function compute(path, src)
        in_progress[path] = true
        local diags, err, sum = M.check_source(src, path, {
            policy = opts ~= nil and opts.policy or nil,
            mode = nil,
            deps = S,
        })
        in_progress[path] = nil
        local e = { summary = sum, diags = diags, err = err } --: Entry
        cache[path] = e
        return e
    end

    --: (name: string) -> (Summary | nil, string | nil)
    function S.summary(name)
        local r, rerr = resolver.resolve(name)
        if r == nil then return nil, rerr end
        if in_progress[r.path] then return CYCLE, nil end
        local e = cache[r.path]
        if e == nil then e = compute(r.path, r.src) end
        if e.summary == nil then return nil, e.err or (r.path .. ": check failed") end
        return e.summary, nil
    end

    --: (path: string) -> ({ [integer]: Diag } | nil, string | nil, Summary | nil)
    function S.check_file(path)
        local e = cache[path]
        if e == nil then
            local src, err = caps.read_file(path)
            if src == nil then return nil, err or (path .. ": unreadable"), nil end
            e = compute(path, src)
        end
        return e.diags, e.err, e.summary
    end

    return S
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
