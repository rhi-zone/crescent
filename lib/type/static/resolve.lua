-- lib/type/static/resolve.lua
-- Module resolver: finds Lua files for require() paths.

local M = {}

-- Convert a module path (e.g., "lib.path") to candidate file paths.
-- Follows package.path patterns.
function M.resolve(mod_path, search_paths)
  local rel = mod_path:gsub("%.", "/")
  local candidates = {
    rel .. "/init.lua",
    rel .. ".lua",
  }

  -- Also check for .d.lua declaration files
  local decl_candidates = {
    rel .. "/init.d.lua",
    rel .. ".d.lua",
  }

  -- Try each candidate
  for _, path in ipairs(candidates) do
    local f = io.open(path, "r")
    if f then
      f:close()
      -- Check for adjacent .d.lua
      local decl_path = path:gsub("%.lua$", ".d.lua")
      local df = io.open(decl_path, "r")
      if df then
        df:close()
        return path, decl_path
      end
      return path, nil
    end
  end

  -- Try declaration-only files
  for _, path in ipairs(decl_candidates) do
    local f = io.open(path, "r")
    if f then
      f:close()
      return nil, path
    end
  end

  -- Try custom search paths
  if search_paths then
    for _, base in ipairs(search_paths) do
      for _, suffix in ipairs({ "/init.lua", ".lua" }) do
        local path = base .. "/" .. rel .. suffix
        local f = io.open(path, "r")
        if f then
          f:close()
          return path, nil
        end
      end
    end
  end

  return nil, nil
end

return M
