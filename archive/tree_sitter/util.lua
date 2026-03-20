local ffi = require("ffi")
local memory = require("lib.memory")
local ts = require("dep.tree_sitter.ffi")

local mod = {}

mod.ts_node_string = function(node)
  local cstr = ts.ts_node_string(node)
  if cstr == nil then return "" end
  local str = ffi.string(cstr)
  memory.free(cstr)
  return str
end

---@type fun(node: TSNode, code: string, write?: (fun(...: unknown): nil), prefix?: string)
local print_tree
print_tree = function(node, code, write, prefix)
  write = write or function(...) io.stdout:write(...) end
  prefix = prefix or ""
  local type = ffi.string(ts.ts_node_type(node))
  write(prefix, type)
  local count = ts.ts_node_child_count(node)
  if count == 0 then
    local token = code:sub(ts.ts_node_start_byte(node) + 1, ts.ts_node_end_byte(node))
    if token ~= type then
      write(" \"", token, "\"")
    end
  end
  write("\n")
  for i = 0, count - 1 do
    local child = ts.ts_node_child(node, i)
    print_tree(child, code, write, prefix .. "  ")
  end
end
mod.print_tree = print_tree

return mod
