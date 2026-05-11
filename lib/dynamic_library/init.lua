if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local ffi = require("ffi")

ffi.cdef [[
void* dlopen(const char* filename, int flag);
void* dlsym(void* handle, const char* symbol);
int dlclose(void* handle);
char* dlerror(void);
]]

local dl_ffi = ffi.C

local RTLD_LAZY = 1

local mod = {}

--:: DynamicLibrary = { handle: unknown, path: string }

local DynamicLibrary = {}
mod.DynamicLibrary = DynamicLibrary
DynamicLibrary.__index = DynamicLibrary

--: (string) -> (DynamicLibrary | nil, string | nil)
function DynamicLibrary.open(path)
  local handle = dl_ffi.dlopen(path, RTLD_LAZY)
  if handle == nil then
    local err = ffi.string(dl_ffi.dlerror())
    return nil, "dynamic_library.open: " .. err
  end
  return setmetatable({ handle = handle }, DynamicLibrary)
end

--: (DynamicLibrary, string) -> (cdata | nil, string | nil)
function DynamicLibrary:symbol(name)
  local sym = dl_ffi.dlsym(self.handle, name)
  if sym == nil then
    local err = ffi.string(dl_ffi.dlerror())
    return nil, "dynamic_library.symbol: " .. err
  end
  return sym
end

--: (DynamicLibrary) -> nil
function DynamicLibrary:close()
  if self.handle == nil then return end
  dl_ffi.dlclose(self.handle)
  self.handle = nil
end

return mod
