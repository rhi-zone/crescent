local ffi = require("ffi")

ffi.cdef [[
void* dlopen(const char* filename, int flag);
void* dlsym(void* handle, const char* symbol);
int dlclose(void* handle);
char* dlerror(void);
]]

---@class dl_ffi
---@field dlopen fun(path: string_c, flags: number): ptr_c<nil>
---@field dlsym fun(handle: ptr_c<nil>, name: string): ptr_c<nil>
---@field dlclose fun(handle: ptr_c<nil>): number
---@field dlerror fun(): string_c

---@type dl_ffi
---@diagnostic disable-next-line: assign-type-mismatch
local dl_ffi = ffi.C

local RTLD_LAZY = 1

local mod = {}

---@class DynamicLibrary
local DynamicLibrary = {}
mod.DynamicLibrary = DynamicLibrary
DynamicLibrary.__index = DynamicLibrary

---@param path string The path to the dynamic library
---@return DynamicLibrary
function DynamicLibrary.open(path)
  local handle = dl_ffi.dlopen(path, RTLD_LAZY)
  if handle == nil then
    local err = ffi.string(dl_ffi.dlerror())
    error("Failed to open library: " .. err)
  end
  return setmetatable({ handle = handle }, DynamicLibrary)
end

---@param name string The name of the symbol to look up
---@return ptr_c<nil> symbol The pointer to the symbol, or `nil` if not found
function DynamicLibrary:symbol(name)
  local sym = dl_ffi.dlsym(self.handle, name)
  if sym == nil then
    local err = ffi.string(dl_ffi.dlerror())
    error("Failed to find symbol: " .. err)
  end
  return sym
end

function DynamicLibrary:close()
  if self.handle == nil then return end
  dl_ffi.dlclose(self.handle)
  self.handle = nil
end

return mod
