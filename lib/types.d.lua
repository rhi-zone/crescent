--[[@class ffilib]]
--[[@field new fun(ct: ffi.cdata*|ffi.cdecl*|ffi.ctype*, init?: unknown, ...: unknown): cdata: unknown]]
--[[@field sizeof fun(ct: ffi.cdata*|ffi.cdecl*|ffi.ctype*, nelem?: integer): size: integer]]
--[[@field cast fun(ct: ffi.cdata*|ffi.cdecl*|ffi.ctype*, init: any): cdata: unknown]]
--[[@field string fun(ptr: string_c, len?: integer): string]]

--[[@class ffilib]]
local ffi = {}
--[[@generic t: ptr_c<unknown>]]
--[[@param cdata t]]
--[[@param finalizer? fun(cdata: t): nil]]
--[[@return t]]
---@diagnostic disable-next-line: duplicate-set-field
ffi.gc = function(cdata, finalizer) return cdata end

--[[@class string_c: string]]
--[[@class error_c]]
--[[@class pid_c]]
--[[@class fd_c]]
--[[@class unix_epoch: number]]
--[[@class ptr_c<t>: { [0]: t }]]
--[[@class long_long_c: integer]]
