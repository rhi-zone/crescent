-- Declaration-only file: shared type aliases for injected I/O capability functions.
-- No runtime code. Load via: --:: require "lib.caps.types"

--:: POpenFn  = (cmd: string, mode: string) -> (File | nil, string | nil)
--:: OpenFn   = (path: string, mode: string | nil) -> (File | nil, string | nil)
--:: RemoveFn = (path: string) -> (boolean | nil, string | nil)
--:: TmpnamFn = () -> string
--:: ReadFn   = (path: string) -> (string | nil, string | nil)
--:: WriteFn  = (path: string, content: string) -> (boolean | nil, string | nil)

return {}
