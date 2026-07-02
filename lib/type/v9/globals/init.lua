-- lib/type/v9/globals/init.lua
-- The v9 GLOBAL ENVIRONMENT seam: a declaration source provides
-- `global name -> annotation tree (At)`; lowering resolves global READS
-- through it (writes stay the global-write policy diag — crescent has no
-- ambient mutable globals).
--
-- v0 sources behind this interface:
--   (a) the stdlib declaration data (globals/stdlib.lua): `--:: declare`
--       lines in v9's own annotation grammar, parsed here through the SAME
--       classify_decl/parse path a user file's `--::` lines take;
--   (b) per-file `--:: declare name = T` lines — wired by lower.lua's
--       annotation pre-pass on top of this environment (file declarations
--       shadow stdlib ones).
--
-- INTERNING: the stdlib source is parsed ONCE per process (memoized here);
-- every checked file shares the same At trees (they are immutable — the
-- per-file At -> lattice-value conversion happens lazily in lower.lua, only
-- for globals the file actually references). This is what keeps whole-tree
-- solve time flat under 40+ declarations.
--
-- HONESTY: parsing problems in the stdlib data (buckets, parse errors,
-- unclassifiable units) are collected as data in `problems` — a non-empty
-- list is a checker bug (the data file drifted outside the checked
-- grammar), asserted empty by globals_test.lua. Errors are data, never
-- thrown.

if not package.path:find("?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local annot = require("lib.type.v9.annot")
local stdlib_src = require("lib.type.v9.globals.stdlib")

--:: At = { k: string, ... }
--:: Env = { globals: { [string]: At }, problems: { [integer]: string } }

local M = {}

-- Split declaration SOURCE TEXT into units: each `--:: ...` line contributes
-- its content (prefix stripped); a unit continues across lines while its
-- brackets are unbalanced — the same joining rule the real lexer applies to
-- multi-line `--::` declarations. Non-`--::` lines are commentary.
--: (src: string) -> { [integer]: string }
local function units_of(src)
    local units = {} --: { [integer]: string }
    local current = "" --: string
    local open = false
    local depth = 0
    for line in src:gmatch("[^\n]+") do
        local content = line:match("^%s*%-%-::%s?(.*%S)") or ""
        if content ~= "" then
            if open then
                current = current .. " " .. content
            else
                current = content
                open = true
            end
            for i = 1, #content do
                local b = content:byte(i)
                if b == 123 or b == 40 or b == 91 then -- { ( [
                    depth = depth + 1
                elseif b == 125 or b == 41 or b == 93 then -- } ) ]
                    depth = depth - 1
                end
            end
            if depth <= 0 then
                units[#units + 1] = current
                current = ""
                open = false
                depth = 0
            end
        end
    end
    if open then units[#units + 1] = current end
    return units
end
M.units_of = units_of

-- Build an environment from declaration source text: aliases first (they
-- are position-independent), then `declare` bodies parsed with alias
-- resolution. Buckets and parse failures land in `problems`.
--: (src: string) -> Env
local function build(src)
    local units = units_of(src)
    local problems = {} --: { [integer]: string }
    --:: Alias = { content: string | nil, feature: string | nil }
    local aliases = {} --: { [string]: Alias }
    --:: Pending = { name: string, body: string }
    local decls = {} --: { [integer]: Pending }
    for i = 1, #units do
        local kind, a, b = annot.classify_decl(units[i])
        if kind == "alias" then
            aliases[a] = { content = b, feature = nil }
        elseif kind == "declare" then
            decls[#decls + 1] = { name = a, body = b or "" }
        elseif kind == "generic-alias" then
            aliases[a] = { content = nil, feature = "generic" }
            problems[#problems + 1] = "generic alias `" .. a .. "` in declaration source"
        else
            problems[#problems + 1] = "unclassifiable declaration unit: `"
                .. units[i]:sub(1, 60) .. "`"
        end
    end
    --: (string) -> (string | nil, string | nil)
    local function resolve(name)
        local al = aliases[name]
        if al == nil then return nil, nil end
        return al.content, al.feature
    end
    local globals = {} --: { [string]: At }
    for i = 1, #decls do
        local d = decls[i]
        local ok, at, buckets, perr = pcall(annot.parse, d.body, resolve)
        if not ok then
            problems[#problems + 1] = "declare " .. d.name .. ": parser crashed: " .. tostring(at)
        else
            if buckets ~= nil then
                for j = 1, #buckets do
                    problems[#problems + 1] = "declare " .. d.name
                        .. ": outside the checked grammar (bucket `" .. buckets[j] .. "`)"
                end
            end
            if at == nil then
                problems[#problems + 1] = "declare " .. d.name .. ": does not parse: "
                    .. (perr or "?")
            else
                globals[d.name] = at
            end
        end
    end
    return { globals = globals, problems = problems }
end
M.build = build

local cached = nil --: Env | nil

-- The stdlib environment (LuaJIT 5.1 globals). Memoized: parsed once per
-- process, shared across every checked file.
--: () -> Env
function M.stdlib()
    local env = cached
    if env ~= nil then return env end
    local built = build(stdlib_src)
    cached = built
    return built
end

-- Look one global up in the stdlib environment. The returned At is SHARED
-- and immutable — callers convert, never mutate.
--: (name: string) -> At | nil
function M.lookup(name)
    return M.stdlib().globals[name]
end

return M
