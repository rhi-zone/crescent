-- lib/platform/apps/system_dashboard/static/projections/dom.lua
-- Type-stub for ../dom.js (the JS module at static/dom.js).
--
-- Initiative B Commit C. This file exists so projection Lua sources can write
--
--     local dom = require("lib.platform.apps.system_dashboard.static.projections.dom")
--
-- and the typechecker resolves the require through default `package.path`,
-- reads this file, and gets accurate types for every constructor.
--
-- The implementations are no-ops that `error()` — these stubs are NEVER
-- executed at runtime. The transpile-time pipeline (lib/lua2ts) remaps the
-- require to `./dom.js` via `opts.imports` so the browser loads the real
-- constructors directly from the JS module.
--
-- Mirrors the `dom` declared-global shape in
-- lib/platform/apps/system_dashboard/projections/projection_types.lua. That
-- declaration stays in place for now; Commit D removes it once projection
-- sources have switched from the declared-global style to require().
--
-- Note on JS surface: dom.js exports { dom, text, unmount }. This Lua stub
-- exposes only the constructor table (the `dom` JS named export) — that is
-- the shape currently used by projection sources via the declared global of
-- the same name. The lua2ts `opts.imports` remap is per-require, so `text`
-- and `unmount` will land in separate stub files (or stay as declared
-- globals) when Commit D wires up the full prelude refactor.

--:: require "lib.js_types"
--:: require "lib.platform.apps.system_dashboard.primitive_types"
--:: require "lib.platform.apps.system_dashboard.projections.projection_types"

local M = {}

--: DomCtor
function M.div(_props, _children)        error("dom.div: stub")        end
--: DomCtor
function M.span(_props, _children)       error("dom.span: stub")       end
--: DomCtor
function M.p(_props, _children)          error("dom.p: stub")          end
--: DomCtor
function M.h1(_props, _children)         error("dom.h1: stub")         end
--: DomCtor
function M.h2(_props, _children)         error("dom.h2: stub")         end
--: DomCtor
function M.h3(_props, _children)         error("dom.h3: stub")         end
--: DomCtor
function M.h4(_props, _children)         error("dom.h4: stub")         end
--: DomCtor
function M.h5(_props, _children)         error("dom.h5: stub")         end
--: DomCtor
function M.h6(_props, _children)         error("dom.h6: stub")         end
--: DomCtor
function M.pre(_props, _children)        error("dom.pre: stub")        end
--: DomCtor
function M.code(_props, _children)       error("dom.code: stub")       end
--: DomCtor
function M.ul(_props, _children)         error("dom.ul: stub")         end
--: DomCtor
function M.ol(_props, _children)         error("dom.ol: stub")         end
--: DomCtor
function M.li(_props, _children)         error("dom.li: stub")         end
--: DomCtor
function M.dl(_props, _children)         error("dom.dl: stub")         end
--: DomCtor
function M.dt(_props, _children)         error("dom.dt: stub")         end
--: DomCtor
function M.dd(_props, _children)         error("dom.dd: stub")         end
--: DomCtor
function M.table(_props, _children)      error("dom.table: stub")      end
--: DomCtor
function M.thead(_props, _children)      error("dom.thead: stub")      end
--: DomCtor
function M.tbody(_props, _children)      error("dom.tbody: stub")      end
--: DomCtor
function M.tr(_props, _children)         error("dom.tr: stub")         end
--: DomCtor
function M.th(_props, _children)         error("dom.th: stub")         end
--: DomCtor
function M.td(_props, _children)         error("dom.td: stub")         end
--: DomCtor
function M.caption(_props, _children)    error("dom.caption: stub")    end
--: DomCtor
function M.details(_props, _children)    error("dom.details: stub")    end
--: DomCtor
function M.summary(_props, _children)    error("dom.summary: stub")    end
--: DomCtor
function M.a(_props, _children)          error("dom.a: stub")          end
--: DomCtor
function M.kbd(_props, _children)        error("dom.kbd: stub")        end
--: DomCtor
function M.time(_props, _children)       error("dom.time: stub")       end
--: DomCtor
function M.button(_props, _children)     error("dom.button: stub")     end
--: DomCtor
function M.input(_props, _children)      error("dom.input: stub")      end
--: DomCtor
function M.label(_props, _children)      error("dom.label: stub")      end
--: DomCtor
function M.select(_props, _children)     error("dom.select: stub")     end
--: DomCtor
function M.option(_props, _children)     error("dom.option: stub")     end
--: DomCtor
function M.form(_props, _children)       error("dom.form: stub")       end
--: DomCtor
function M.fieldset(_props, _children)   error("dom.fieldset: stub")   end
--: DomCtor
function M.legend(_props, _children)     error("dom.legend: stub")     end
--: DomCtor
function M.nav(_props, _children)        error("dom.nav: stub")        end
--: DomCtor
function M.section(_props, _children)    error("dom.section: stub")    end
--: DomCtor
function M.article(_props, _children)    error("dom.article: stub")    end
--: DomCtor
function M.header(_props, _children)     error("dom.header: stub")     end
--: DomCtor
function M.footer(_props, _children)     error("dom.footer: stub")     end
--: DomCtor
function M.main(_props, _children)       error("dom.main: stub")       end
--: DomCtor
function M.aside(_props, _children)      error("dom.aside: stub")      end
--: DomCtor
function M.figure(_props, _children)     error("dom.figure: stub")     end
--: DomCtor
function M.figcaption(_props, _children) error("dom.figcaption: stub") end
--: DomCtor
function M.img(_props, _children)        error("dom.img: stub")        end
--: DomCtor
function M.hr(_props, _children)         error("dom.hr: stub")         end
--: DomCtor
function M.br(_props, _children)         error("dom.br: stub")         end
--: DomCtor
function M.strong(_props, _children)     error("dom.strong: stub")     end
--: DomCtor
function M.em(_props, _children)         error("dom.em: stub")         end
--: DomCtor
function M.svg(_props, _children)        error("dom.svg: stub")        end
--: DomCtor
function M.g(_props, _children)          error("dom.g: stub")          end
--: DomCtor
function M.path(_props, _children)       error("dom.path: stub")       end
--: DomCtor
function M.rect(_props, _children)       error("dom.rect: stub")       end
--: DomCtor
function M.circle(_props, _children)     error("dom.circle: stub")     end
--: DomCtor
function M.line(_props, _children)       error("dom.line: stub")       end
--: DomCtor
function M.polyline(_props, _children)   error("dom.polyline: stub")   end
--: DomCtor
function M.polygon(_props, _children)    error("dom.polygon: stub")    end
--: DomCtor
function M.text(_props, _children)       error("dom.text: stub")       end
--: DomCtor
function M.title(_props, _children)      error("dom.title: stub")      end
--: DomCtor
function M.defs(_props, _children)       error("dom.defs: stub")       end
--: DomCtor
function M.clipPath(_props, _children)   error("dom.clipPath: stub")   end
--: DomCtor
function M.use(_props, _children)        error("dom.use: stub")        end

return M
