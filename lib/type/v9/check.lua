-- lib/type/v9/check.lua
-- The v9 RUNNER: Lua source (string or file) -> diagnostics with line/col.
-- parse (frontend seam) -> total lowering -> engine fixpoint -> obligation
-- evaluation -> policy-stamped, position-sorted diagnostics.
--
-- THE POWER DIAL LIVES HERE and nowhere else: `Policy` maps NAMED rule codes
-- to severities ("error" | "warn" | "info"). Strictness is owner-decidable
-- data, never an implementation choice buried in the solver. v0 defaults:
--
--   parse-error         error   the file is not Lua
--   op-mismatch         error   supported-discipline type error
--   call-non-function   error   supported-discipline type error
--   internal            error   a lowering invariant broke (checker bug)
--   use-before-narrow   warn    unknown used dynamically — v0 cannot narrow
--                               it yet (annotations/stdlib decls are the
--                               roadmap); the dial makes the debt visible
--   undeclared-global   warn    no ambient globals (stdlib decls pending)
--   global-write        warn    write to an undeclared global
--   unused-local        warn    declared, never read (syntactic in v0)
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

local frontend = require("lib.type.v9.frontend")
local lower = require("lib.type.v9.lower")
local engine = require("lib.type.v9.engine.engine")
local lattice = require("lib.type.v9.lattice")

--:: Diag = { code: string, severity: string, message: string, line: integer, col: integer }
--:: Obligation = { cell: string, allow: { [string]: boolean }, code: string, what: string, line: integer, col: integer }
--:: Policy = { [string]: string }
--:: Caps = { read_file: (string) -> (string | nil, string | nil) }
--:: CheckOpts = { policy: Policy | nil, mode: string | nil }

local M = {}

--: (x: unknown) -> x is { [string]: boolean }
local function as_atoms(x) return type(x) == "table" end

-- The named rules and their default severities, as data. (Built with
-- dynamic keys: the checker folds literal-key writes into the alias shape.)
local DEFAULT_RULES = {
    { "parse-error", "error" },
    { "op-mismatch", "error" },
    { "call-non-function", "error" },
    { "internal", "error" },
    { "use-before-narrow", "warn" },
    { "undeclared-global", "warn" },
    { "global-write", "warn" },
    { "unused-local", "warn" },
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
            local ob = obligations[i]
            local v = sol.values[ob.cell]
            if as_atoms(v) and not lattice.is_bottom(v) then
                if lattice.is_unknown(v) then
                    diags[#diags + 1] = {
                        code = "use-before-narrow",
                        severity = "warn",
                        line = ob.line,
                        col = ob.col,
                        message = ob.what .. " has type `unknown` — narrow it before dynamic use",
                    }
                else
                    local excess = lattice.excess(v, ob.allow)
                    if excess ~= nil then
                        diags[#diags + 1] = {
                            code = ob.code,
                            severity = "warn",
                            line = ob.line,
                            col = ob.col,
                            message = ob.what .. ": got `" .. lattice.show(v)
                                .. "`, expected `" .. lattice.show(ob.allow) .. "`",
                        }
                    end
                end
            end
        end
    end

    stamp(diags, policy)
    sort_by_position(diags)
    return diags, nil
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
