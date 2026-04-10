-- lib/unified/retext/init.lua
if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- retext: natural language processing preset for the unified pipeline.
-- Analogous to remark/rehype but for natural language (nlcst trees).
--
-- Usage:
--   local retext = require("lib.unified.retext")
--   local processor = retext()
--   local tree = processor:parse("Hello, world!")

local unified        = require("lib.unified")
local retext_english = require("lib.unified.retext_english")

local M = {}

-- Create a new frozen retext processor with retext_english as the default parser.
-- The processor is frozen on creation; extend it via :use() which clones first.
local function make_processor()
  local p = unified.new()
  p:use(retext_english.plugin)
  p:freeze()
  return p
end

-- retext() returns a new frozen processor.
setmetatable(M, { __call = function(_self, _opts)
  return make_processor()
end })

return M
