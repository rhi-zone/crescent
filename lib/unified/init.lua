-- lib/unified/init.lua
if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- unified: composable processing pipeline (parse → transform → stringify).
-- Ported from the unified.js concept; synchronous only — no vfile, no async.
--
-- Usage:
--   local unified = require("lib.unified")
--   local result = unified.new()
--     :use(plugin, opts)
--     :process(source)

local M = {}

-- Create a new processor.
-- A processor holds:
--   _parser      : function(source) -> ast
--   _compiler    : function(ast) -> string
--   _transformers: list of function(ast) -> ast
--   _plugins     : list of {fn, opts} already applied (for clone)
--   _frozen      : boolean
local function new_processor()
  local P = {}
  P._parser       = nil
  P._compiler     = nil
  P._transformers = {}
  P._plugins      = {}
  P._frozen       = false

  -- Register a parse function: fn(source) -> ast
  function P:parser(fn)
    self._parser = fn
    return self
  end

  -- Register a stringify/compile function: fn(ast) -> string
  function P:compiler(fn)
    self._compiler = fn
    return self
  end

  -- Append a transformer: fn(ast) -> ast
  function P:use_transformer(fn)
    self._transformers[#self._transformers + 1] = fn
    return self
  end

  -- Apply a plugin (and optional opts) to this processor.
  -- If the processor is frozen, clone first and apply to the clone.
  function P:use(plugin, opts)
    if self._frozen then
      return self:clone():use(plugin, opts)
    end
    self._plugins[#self._plugins + 1] = {plugin, opts}
    plugin(self, opts)
    return self
  end

  -- Freeze the processor. After freezing, :use() clones before applying.
  function P:freeze()
    self._frozen = true
    return self
  end

  -- Shallow clone: same plugins re-applied to a fresh processor.
  function P:clone()
    local c = new_processor()
    for i = 1, #self._plugins do
      local entry = self._plugins[i]
      entry[1](c, entry[2])
    end
    return c
  end

  -- Parse source into an AST using the registered parser.
  -- Returns (ast) or (nil, errmsg).
  function P:parse(source)
    if not self._parser then
      return nil, "unified: no parser registered"
    end
    return self._parser(source)
  end

  -- Run all transformers on ast in registration order.
  -- Returns (ast) or (nil, errmsg).
  function P:run(ast)
    local node = ast
    for i = 1, #self._transformers do
      local result = self._transformers[i](node)
      if result == nil then
        return nil, "unified: transformer " .. i .. " returned nil"
      end
      node = result
    end
    return node
  end

  -- Stringify an AST using the registered compiler.
  -- Returns (string) or (nil, errmsg).
  function P:stringify(ast)
    if not self._compiler then
      return nil, "unified: no compiler registered"
    end
    return self._compiler(ast)
  end

  -- Full pipeline: parse → run → stringify.
  -- Returns (string) or (nil, errmsg).
  function P:process(source)
    local ast, err = self:parse(source)
    if not ast then return nil, err end
    ast, err = self:run(ast)
    if not ast then return nil, err end
    return self:stringify(ast)
  end

  return P
end

-- Create a new, unfrozen processor.
M.new = new_processor

return M
