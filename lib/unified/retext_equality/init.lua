-- lib/unified/retext_equality/init.lua
if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- retext_equality: warns about potentially insensitive or biased language.
-- Port of retext-equality (https://github.com/retextjs/retext-equality).
--
-- Matches words (case-insensitive) against a flagged-terms table.
--
-- Stores: root.data.equality = {
--   { word="blacklist", suggestion="denylist/blocklist" }, ...
-- }

local nlcst = require("lib.unified.nlcst") --[[: any]]

local M = {}

-- Flagged terms with suggested alternatives.
local FLAGGED = {
  blacklist     = "denylist/blocklist",
  whitelist     = "allowlist",
  master        = "primary/main",
  slave         = "secondary/replica",
  mankind       = "humankind",
  manmade       = "artificial/synthetic",
  ["man-made"]  = "artificial/synthetic",
  guys          = "everyone/folks",
  crazy         = "unexpected/surprising",
  lame          = "disappointing",
  dumb          = "silent",
  insane        = "extreme",
  blind         = "unaware of",
  cripple       = "limit",
  crippled      = "limited",
  midget        = "little person",
  elderly       = "older adults",
  retarded      = "has a disability",
  retard        = "person with a disability",
  handicapped   = "person with a disability",
  disabled      = "person with a disability",
  illegal       = "undocumented",
  alien         = "non-citizen",
  ["normal"]    = "typical",
  abnormal      = "atypical",
  ghetto        = "under-resourced area",
  bitch         = "complain",
  bitching      = "complaining",
  gyp           = "cheat",
  gypped        = "cheated",
  sanity        = "correctness",
  sanity_check  = "confidence check",
  brownbag      = "brown bag / lunch and learn",
  grandfathered = "legacy/exempted",
  grandfather   = "legacy/exempt",
  freshman      = "first-year student",
  manpower      = "workforce/staff",
  middleman     = "intermediary",
  chairman      = "chair/chairperson",
  policeman     = "police officer",
  fireman       = "firefighter",
}

local function transformer(root)
  local findings = {}

  local function walk(node)
    if node.type == nlcst.WORD then
      local text = nlcst.to_text(node)
      local suggestion = FLAGGED[text:lower()]
      if suggestion then
        findings[#findings + 1] = {
          word       = text,
          suggestion = suggestion,
        }
      end
      return
    end
    if node.children then
      local nc = node.children --[[:! { [integer]: any }]]
      for i = 1, #nc do walk(nc[i]) end
    end
  end

  walk(root)

  root.data = root.data or {}
  root.data.equality = findings

  return root
end

function M.plugin(processor, _opts)
  processor:use_transformer(transformer)
end

setmetatable(M, { __call = function(self, processor, opts)
  return self.plugin(processor, opts)
end })

return M
