-- lib/rehype/init.lua
-- HTML processing preset: wires lib/hast into a lib/unified processor.
-- Mirrors the JavaScript `rehype` package.
--
-- API:
--   rehype()                      -> frozen unified processor
--   rehype.from_mdast(mdast_node) -> hast root       (re-export from lib/hast)
--   rehype.to_html(hast_node)     -> string           (re-export from lib/hast)
--   rehype.md_to_html(source)     -> string           (re-export from lib/hast)
--
-- Usage:
--   local rehype = require("lib.unified.rehype")
--
--   local processor = rehype()
--   local ast = processor:parse("<p>Hello</p>")   -- stub: no HTML parser yet
--   local html = processor:stringify(ast)
--   local out = processor:process("<p>Hello</p>")
--
-- Note: A full HTML → hast parser is not yet implemented. The registered
-- parser is a stub that returns a root node carrying the raw source in
-- node.raw. Use rehype.md_to_html() or construct hast trees directly and
-- pass them to processor:stringify().

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local unified = require("lib.unified")
local hast    = require("lib.unified.hast")

local M = {}

-- ── Plugins ───────────────────────────────────────────────────────────────────

-- rehype-parse (stub): registers a minimal pass-through parser.
-- A real HTML → hast parser is not yet implemented; this lets :parse() and
-- :process() run without error and returns a root node that carries the
-- raw HTML source for downstream transformers that know how to handle it.
--: (unknown, unknown) -> nil
local function rehype_parse(processor, _opts)
  ;(processor --[[:! { parser: (...unknown) -> unknown, ... }]]):parser(function(source)
    -- Stub: no HTML parsing. Returns a root node with raw source attached.
    return { type = "root", children = {}, raw = source }
  end)
end

-- rehype-stringify: registers the hast → HTML compiler.
--: (unknown, unknown) -> nil
local function rehype_stringify(processor, _opts)
  ;(processor --[[:! { compiler: (...unknown) -> unknown, ... }]]):compiler(function(ast)
    return hast.to_html(ast)
  end)
end

-- ── Factory ───────────────────────────────────────────────────────────────────

-- Returns a frozen unified processor pre-configured with the rehype parser
-- stub and the hast HTML serializer. Use :use() to add transformer plugins
-- (returns a new unfrozen clone).
--: () -> unknown
function M.__call(_self, _opts)
  return unified.new()
    :use(rehype_parse)
    :use(rehype_stringify)
    :freeze()
end

setmetatable(M, { __call = M.__call })

-- ── Convenience re-exports from lib/hast ─────────────────────────────────────

M.from_mdast  = hast.from_mdast
M.to_html     = hast.to_html
M.md_to_html  = hast.md_to_html

return M
