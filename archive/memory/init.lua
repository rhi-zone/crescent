local ffi = require("ffi")

ffi.cdef [[
  void* malloc(size_t size);
  void free(void* ptr);
  void* realloc(void* ptr, size_t size);
  void* calloc(size_t num, size_t size);
]]

local mod = {}

---@generic t
---@type fun(size: number): ptr_c<t>
mod.malloc = ffi.C.malloc
---@generic t
---@type fun(ptr: ptr_c<t>): nil
mod.free = ffi.C.free
---@generic t
---@type fun(ptr: ptr_c<t>, size: number): ptr_c<t>
mod.realloc = ffi.C.realloc
---@generic t
---@type fun(num: number, size: number): ptr_c<t>
mod.calloc = ffi.C.calloc

return mod
