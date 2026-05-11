-- lib/unified/retext_simplify/init.lua
if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- retext_simplify: suggests simpler word alternatives.
-- Port of retext-simplify (https://github.com/retextjs/retext-simplify).
--
-- Matches words (case-insensitive) against a complex→simple table.
--
-- Stores: root.data.simplify = {
--   { word="utilize", suggestion="use", sentence="..." }, ...
-- }

local nlcst = require("lib.unified.nlcst") --[[: unknown]]

local M = {}

-- Complex → simple word replacements.
local REPLACEMENTS = {
  utilize        = "use",
  utilise        = "use",
  commence       = "start",
  terminate      = "end",
  facilitate     = "help",
  endeavor       = "try",
  endeavour      = "try",
  demonstrate    = "show",
  subsequently   = "then",
  sufficient     = "enough",
  numerous       = "many",
  regarding      = "about",
  approximately  = "about",
  additional     = "more",
  construct      = "build",
  inquire        = "ask",
  require        = "need",
  obtain         = "get",
  purchase       = "buy",
  indicate       = "show",
  implement      = "do",
  initiate       = "start",
  complete       = "finish",
  provide        = "give",
  assist         = "help",
  communicate    = "tell",
  determine      = "find",
  consider       = "think",
  maintain       = "keep",
  select         = "pick",
  currently      = "now",
  previously     = "before",
  forward        = "send",
  request        = "ask",
  leverage       = "use",
  methodology    = "method",
  functionality  = "feature",
  interface      = "connect",
  parameter      = "value",
  optimize       = "improve",
  optimise       = "improve",
  aggregate      = "total",
  beneficial     = "useful",
  consequently   = "so",
  modification   = "change",
  modifications  = "changes",
  utilize        = "use",
  utilization    = "use",
  consolidate    = "merge",
  ascertain      = "find",
  comprehend     = "understand",
  formulate      = "make",
  prioritize     = "rank",
  prioritise     = "rank",
  remuneration   = "pay",
  procure        = "get",
  leverage       = "use",
  ameliorate     = "improve",
  mitigate       = "reduce",
}

-- Walk the tree and collect word + surrounding sentence context.
local function transformer(root)
  local findings = {}

  local function walk_sentence(sent)
    local sentence_text = nlcst.to_text(sent)
    local function walk(node)
      if node.type == nlcst.WORD then
        local text = nlcst.to_text(node)
        local suggestion = REPLACEMENTS[text:lower()]
        if suggestion then
          findings[#findings + 1] = {
            word       = text,
            suggestion = suggestion,
            sentence   = sentence_text,
          }
        end
        return
      end
      if node.children then
        local nc = node.children --[[:! { [integer]: { type: string, children?: unknown, value?: string, ... } }]]
        for i = 1, #nc do walk(nc[i]) end
      end
    end
    walk(sent)
  end

  local function walk_node(node)
    if node.type == nlcst.SENTENCE then
      walk_sentence(node)
      return
    end
    if node.children then
      local nc = node.children --[[:! { [integer]: { type: string, children?: unknown, value?: string, ... } }]]
      for i = 1, #nc do walk_node(nc[i]) end
    end
  end

  walk_node(root)

  root.data = root.data or {}
  root.data.simplify = findings

  return root
end

function M.plugin(processor, _opts)
  processor:use_transformer(transformer)
end

setmetatable(M, { __call = function(self, processor, opts)
  return self.plugin(processor, opts)
end })

return M
