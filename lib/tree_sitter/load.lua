local ffi = require("ffi")

local mod = {}

---@param language_name string The name of the language for which to load the grammar
---@return ptr_c<TSLanguage> The loaded language grammar
local function load_grammar(language_name)
  ffi.cdef("TSLanguage *tree_sitter_" .. language_name:gsub("-", "_") .. "();")
  local lib = ffi.load("tree-sitter-" .. language_name)
  return lib["tree_sitter_" .. language_name:gsub("-", "_")]()
end

mod.load_grammar = load_grammar

return mod
