-- lib/remark_rehype/init.lua
-- Bridge plugin: mdast → hast transform for a unified pipeline.
-- Mirrors the JavaScript `remark-rehype` package.
--
-- Usage:
--   local remark      = require("lib.unified.remark")
--   local rehype      = require("lib.unified.rehype")
--   local remarkRehype = require("lib.unified.remark_rehype")
--
--   local processor = remark()
--     :use(remarkRehype)
--     :use(remarkRehype.stringify_plugin)
--
--   local html = processor:process("# Hello\n\nWorld.")
--   -- => "<h1>Hello</h1><p>World.</p>"
--
-- The plugin does two things:
--   1. Registers a transformer that converts an mdast tree into a hast tree.
--   2. Replaces the compiler with hast.to_html so the result is HTML.
--      (Pass opts.no_stringify = true to skip this and chain your own compiler.)

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local hast = require("lib.unified.hast")

local M = {}

-- ── stringify_plugin ──────────────────────────────────────────────────────────

-- Standalone plugin that registers hast.to_html as the compiler.
-- Use this when you want to attach the HTML serializer separately, or when
-- composing remark_rehype with additional rehype transformers.
--: (any, any) -> nil
local function stringify_plugin(processor, _opts)
  processor:compiler(function(ast)
    return hast.to_html(ast)
  end)
end

M.stringify_plugin = stringify_plugin

-- ── remark_rehype plugin ──────────────────────────────────────────────────────

-- Main plugin function. Registers:
--   1. A transformer that converts mdast → hast in place.
--   2. A compiler that serializes hast → HTML (unless opts.no_stringify).
--: (any, any) -> nil
local function remark_rehype(processor, opts)
  -- Transformer: mdast tree → hast tree.
  processor:use_transformer(function(ast)
    return hast.from_mdast(ast)
  end)

  -- Compiler: serialize hast → HTML string (default on, skip with no_stringify).
  if not (opts and opts.no_stringify) then
    stringify_plugin(processor, opts)
  end
end

-- Make the module itself callable as a plugin:
--   processor:use(remarkRehype)
setmetatable(M, { __call = function(_, ...) return remark_rehype(...) end })

-- Also export as a named function for explicit use.
M.plugin = remark_rehype

return M
