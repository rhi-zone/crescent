if not package.path:find("?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- lib/js_caps/init.lua
--
-- TYPE-ONLY MODULE. This file is NOT a runtime implementation; it
-- declares the shape of the JS module at lib/js_caps/index.js so
-- Lua-side typechecking of code that wires the browser-side cap-impl
-- map gets accurate signatures.
--
-- index.js exports `dayZeroCaps`, a Map<string, function> that callers
-- pass as `opts.capImpls` to lib/js_pack_host/host.js#mountPack. Each
-- entry name corresponds to a cap kind in docs/browser_caps.md §5.
-- This commit ships the 6 trivial caps (pure wraps with no design
-- questions). The remaining 12 land in subsequent commits, including
-- `set_timeout` which is blocked on the cap-bridge AbortSignal
-- extension (docs/platform_isolation.md §4).
--
-- Lua callers MUST NOT call any cap function at runtime -- they error.
-- The functions exist so Lua code that assembles browser-side pipelines
-- (daemon stub-page generation, pack-load orchestration) can typecheck
-- against the JS module's exported signatures.
--
-- See docs/browser_caps.md §4 and §5 for the cap-kind specifications.

local M = {}

-- The cap-side JS values that have no native Lua type (Uint8Array,
-- Promise<...>) are annotated as `unknown` here; callers are expected
-- to treat them as opaque and pass them back through cap-bridge calls
-- rather than reading into them on the Lua side.

--:: TextDecodeOpts = { encoding: string | nil, fatal: boolean | nil, ignoreBOM: boolean | nil }

--:: TextEncodeFn   = (text: string) -> unknown
--:: TextDecodeFn   = (bytes: unknown, opts: TextDecodeOpts | nil) -> string
--:: CompressFn     = (bytes: unknown, format: string) -> unknown
--:: DecompressFn   = (bytes: unknown, format: string) -> unknown
--:: ConsoleLogFn   = (...unknown) -> nil
--:: RandomFn       = (byte_length: integer) -> unknown

--:: DayZeroCaps = {
--::   text_encode:       TextEncodeFn,
--::   text_decode:       TextDecodeFn,
--::   compress:          CompressFn,
--::   decompress:        DecompressFn,
--::   console_log:       ConsoleLogFn,
--::   web_crypto_random: RandomFn,
--:: }

--: (string) -> unknown
function M.text_encode(_text)
  error("lib/js_caps is type-only on the Lua side: " ..
    "use lib/js_caps/index.js at runtime in the host stub page.")
end

--: (unknown, TextDecodeOpts | nil) -> string
function M.text_decode(_bytes, _opts)
  error("lib/js_caps is type-only on the Lua side.")
end

--: (unknown, string) -> unknown
function M.compress(_bytes, _format)
  error("lib/js_caps is type-only on the Lua side.")
end

--: (unknown, string) -> unknown
function M.decompress(_bytes, _format)
  error("lib/js_caps is type-only on the Lua side.")
end

--: (...unknown) -> nil
function M.console_log(...)
  local _ = ...
  error("lib/js_caps is type-only on the Lua side.")
end

--: (integer) -> unknown
function M.web_crypto_random(_byte_length)
  error("lib/js_caps is type-only on the Lua side.")
end

--:: dayZeroCaps_type = DayZeroCaps
M.dayZeroCaps = {
  text_encode       = M.text_encode,
  text_decode       = M.text_decode,
  compress          = M.compress,
  decompress        = M.decompress,
  console_log       = M.console_log,
  web_crypto_random = M.web_crypto_random,
}

return M
