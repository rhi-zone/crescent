-- lib/platform/apps/system_dashboard/static/projections/registry.lua
-- Type-stub for ./registry.js.
--
-- Initiative B Commit C. This file exists so projection Lua sources can write
--
--     local registry = require("lib.platform.apps.system_dashboard.static.projections.registry")
--     registry.register("text", project_text)
--
-- and the typechecker resolves the require through default `package.path`,
-- reads this file, and gets accurate types for every named export.
--
-- The implementations are no-ops that `error()` — these stubs are NEVER
-- executed at runtime. The transpile-time pipeline (lib/lua2ts) remaps the
-- require to `./registry.js` via `opts.imports` so the browser loads the
-- real registry directly from the JS module.
--
-- JS exports mirrored here:
--   register(tag, fn)     — push fn onto the stack for tag
--   select(tag, fn)       — move an already-registered fn to active position
--   has(tag) -> bool      — does tag have at least one projection?
--   shapeOf(v) -> string  — tag derivation: "null"/"array"/typeof/v.type
--   project(v, ctx)       — top-of-stack dispatch via shapeOf
--   setDefault(fn)        — install the fallback projection (used by _default.js)
--
-- See projection_types.lua for the canonical Ctx, Projection, and Element
-- type aliases. That file's declared globals (`dom`, `text`) stay in place
-- for now; Commit D removes them once projection sources migrate from the
-- declared-global style to require() everywhere.

--:: require "lib.web.js_types"
--:: require "lib.platform.apps.system_dashboard.primitive_types"
--:: require "lib.platform.apps.system_dashboard.projections.projection_types"

local M = {}

--: (tag: string, fn: Projection) -> ()
function M.register(_tag, _fn)
  error("registry.register: stub")
end

--: (tag: string, fn: Projection) -> ()
function M.select(_tag, _fn)
  error("registry.select: stub")
end

--: (tag: string) -> boolean
function M.has(_tag)
  error("registry.has: stub")
end

--: (v: unknown) -> string
function M.shapeOf(_v)
  error("registry.shapeOf: stub")
end

--: (v: Primitive, ctx: Ctx) -> Element
function M.project(_v, _ctx)
  error("registry.project: stub")
end

--: (fn: Projection) -> ()
function M.setDefault(_fn)
  error("registry.setDefault: stub")
end

return M
