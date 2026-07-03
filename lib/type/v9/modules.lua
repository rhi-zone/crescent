-- lib/type/v9/modules.lua
-- The v9 MODULE RESOLUTION seam: Lua module name ("a.b.c") -> the file that
-- `require` would load, behind ONE injected-caps interface. Mined from the
-- legacy checker's resolution (lib/type/static/check.lua):
--
--   a.b.c  ->  a/b/c.lua, else a/b/c/init.lua   (the standard Lua package
--                                                layout; dot -> slash)
--
-- Caps-first: file access is the injected `read_file` cap and NOTHING else —
-- probing for existence IS reading (one cap, no `exists` side channel, no io
-- reached from here). Errors are data: `(nil, nil, errmsg)`, never thrown.
--
-- The seam is an INTERFACE (a resolver value with one function) so a future
-- package-path policy — search roots, `package.path`-shaped templates, a
-- vendored `dep/` mapping — replaces the candidate list without touching any
-- consumer: callers hold "module name -> (path, source)" and nothing about
-- the layout. NOT carried from legacy (recorded in TODO.md): the
-- `_types.lua` companion declaration OVERRIDE — legacy replaces the module
-- file wholesale with an alias-only declaration file, but v9 summaries are
-- INFERRED from the module's returns, and an alias-only companion returns
-- nothing (its summary value would be `true` — actively wrong); serving the
-- two existing pairs needs alias-env MERGING at the session, not a path
-- swap.

if not package.path:find("?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

--:: Caps = { read_file: (string) -> (string | nil, string | nil) }
--:: Resolved = { path: string, src: string }
--:: Resolver = { resolve: (name: string) -> (Resolved | nil, string | nil) }

local M = {}

-- Build a resolver over the injected caps. Resolution is memoized per
-- resolver (a module name probes the filesystem once per session).
--: (caps: Caps) -> Resolver
function M.resolver(caps)
    local memo = {} --: { [string]: Resolved }
    local failed = {} --: { [string]: string }
    --: (name: string) -> (Resolved | nil, string | nil)
    local function resolve(name)
        local hit = memo[name]
        if hit ~= nil then return hit, nil end
        local miss = failed[name]
        if miss ~= nil then return nil, miss end
        local rel = name:gsub("%.", "/")
        local flat = rel .. ".lua"
        local src = caps.read_file(flat)
        if src ~= nil then
            local r = { path = flat, src = src } --: Resolved
            memo[name] = r
            return r, nil
        end
        local init = rel .. "/init.lua"
        src = caps.read_file(init)
        if src ~= nil then
            local r = { path = init, src = src } --: Resolved
            memo[name] = r
            return r, nil
        end
        local err = "module '" .. name .. "' not found (tried " .. flat .. ", " .. init .. ")"
        failed[name] = err
        return nil, err
    end
    return { resolve = resolve }
end

return M
