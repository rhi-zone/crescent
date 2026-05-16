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
-- This module ships the 6 trivial pure-wrap caps plus `set_timeout`
-- (cancellable via the cap-bridge AbortSignal extension,
-- docs/platform_isolation.md §4) plus `web_crypto_subtle` (op-
-- discriminated wrap of SubtleCrypto) plus `clipboard_write`. The
-- remaining caps land in subsequent commits.
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

-- SetTimeoutOpts.signal is the JS-side AbortSignal value. Lua has no
-- native AbortSignal type; the value is opaque from Lua's perspective
-- and would only ever originate as a host-bridged JS value. Annotated
-- as `unknown` so callers cannot read into its shape from Lua.
--:: SetTimeoutOpts = { signal: unknown | nil }

--:: TextEncodeFn   = (text: string) -> unknown
--:: TextDecodeFn   = (bytes: unknown, opts: TextDecodeOpts | nil) -> string
--:: CompressFn     = (bytes: unknown, format: string) -> unknown
--:: DecompressFn   = (bytes: unknown, format: string) -> unknown
--:: ConsoleLogFn   = (...unknown) -> nil
--:: RandomFn       = (byte_length: integer) -> unknown
--:: SetTimeoutFn   = (delay_ms: number, opts: SetTimeoutOpts | nil) -> nil
--:: ClipboardWriteFn = (text: string) -> nil

-- WebCryptoSubtleFn: op-discriminated single-cap dispatch over
-- crypto.subtle. The args shape varies per op (encrypt/decrypt/sign/
-- verify/digest/generateKey/deriveKey/deriveBits/importKey/exportKey/
-- wrapKey/unwrapKey); the union of shapes is too unwieldy to express in
-- the Lua annotation grammar without losing structural fidelity, so the
-- args parameter is typed `unknown` -- Lua callers must construct the
-- table per docs/browser_caps.md §4.7.2 and treat the returned value as
-- opaque (CryptoKey / ArrayBuffer / JsonWebKey are not Lua-native).
--:: WebCryptoSubtleFn = (args: unknown) -> unknown

--:: DayZeroCaps = {
--::   text_encode:       TextEncodeFn,
--::   text_decode:       TextDecodeFn,
--::   compress:          CompressFn,
--::   decompress:        DecompressFn,
--::   console_log:       ConsoleLogFn,
--::   web_crypto_random: RandomFn,
--::   web_crypto_subtle: WebCryptoSubtleFn,
--::   set_timeout:       SetTimeoutFn,
--::   clipboard_write:   ClipboardWriteFn,
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

--: (number, SetTimeoutOpts | nil) -> nil
function M.set_timeout(_delay_ms, _opts)
  error("lib/js_caps is type-only on the Lua side.")
end

--: (unknown) -> unknown
function M.web_crypto_subtle(_args)
  error("lib/js_caps is type-only on the Lua side.")
end

--: (string) -> nil
function M.clipboard_write(_text)
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
  web_crypto_subtle = M.web_crypto_subtle,
  set_timeout       = M.set_timeout,
  clipboard_write   = M.clipboard_write,
}

return M
