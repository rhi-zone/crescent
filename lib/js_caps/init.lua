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
-- entry name corresponds to a cap kind in docs/browser_caps.md §5. The
-- full day-zero surface (17/17 caps) is shipped:
--
--   * 9 pure-function caps in `dayZeroCaps` (6 trivial pure-wraps plus
--     `set_timeout`, `web_crypto_subtle`, `clipboard_write`).
--   * 1 `fetch_api` via the `makeFetchApi` factory (config-bound on
--     `allowed_origins`).
--   * 4 `kv_*` caps via the `makeKvCaps` factory (config-bound on
--     `pack_id`; share an IndexedDB backend).
--   * 3 UI caps (`toast`, `dialog`, `navigate`) via the `makeUiCaps`
--     factory (host-app-bound on `renderToast`/`renderDialog`/
--     `requestNavigate` -- pure routing over host-supplied primitives).
--
-- `buildDayZeroCapImpls` composes the full Map for the common case.
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

-- fetch_api: factory-shaped per docs/browser_caps.md §4.1.1.
-- `makeFetchApi({ allowed_origins })` returns the cap function; the
-- cap function takes a single args record. Args carry the request URL,
-- optional method/headers/body, optional responseFormat, and an
-- opaque AbortSignal (bridge-translated, see SetTimeoutOpts).
--:: FetchApiConfig = { allowed_origins: { [integer]: string } }
--:: FetchApiArgs = {
--::   url: string,
--::   method: string | nil,
--::   headers: { [string]: string } | nil,
--::   body: unknown | nil,
--::   responseFormat: string | nil,
--::   signal: unknown | nil,
--:: }
--:: FetchApiResult = {
--::   status: integer,
--::   statusText: string,
--::   headers: { [string]: string },
--::   body: unknown,
--:: }
--:: FetchApiFn = (args: FetchApiArgs) -> FetchApiResult
--:: MakeFetchApiFn = (config: FetchApiConfig) -> FetchApiFn

-- kv_*: factory-shaped per docs/browser_caps.md §4.2.1. `makeKvCaps`
-- binds the four caps to a per-pack IndexedDB database
-- (`pack_<pack_id>`). The factory returns a record of four functions
-- rather than a single cap because they share a backend; the host page
-- merges all four into the cap-impls Map at mount time. Values are
-- structured-clone-cloneable JS values -- opaque from Lua's view, so
-- they appear as `unknown`.
--:: KvConfig = { pack_id: string }
--:: KvWriteArgs = { key: string, value: unknown }
--:: KvReadFn   = (key: string) -> unknown
--:: KvWriteFn  = (args: KvWriteArgs) -> nil
--:: KvDeleteFn = (key: string) -> nil
--:: KvKeysFn   = () -> { [integer]: string }
--:: KvCaps = {
--::   kv_read:   KvReadFn,
--::   kv_write:  KvWriteFn,
--::   kv_delete: KvDeleteFn,
--::   kv_keys:   KvKeysFn,
--:: }
--:: MakeKvCapsFn = (config: KvConfig) -> KvCaps

-- toast/dialog/navigate: factory-shaped per docs/browser_caps.md
-- §4.4.10, §4.10.3, §4.10.4. `makeUiCaps` binds three caps to a host-
-- app-provided set of UI primitives (the host app, not the browser,
-- renders toasts / dialogs / navigation; the caps are pure routing over
-- structured input). The factory returns the three caps as a record,
-- mirroring makeKvCaps -- the host page merges them into the cap-impls
-- Map alongside the rest.
--:: ToastArgs = {
--::   message: string,
--::   level: string | nil,
--::   duration: number | nil,
--:: }
--:: DialogArgs = {
--::   message: string,
--::   buttons: { [integer]: string },
--:: }
--:: NavigateArgs = { path: string }
--:: RenderToastArgs = {
--::   message: string,
--::   level: string,
--::   duration: number,
--:: }
--:: RenderDialogArgs = {
--::   message: string,
--::   buttons: { [integer]: string },
--:: }
--:: RequestNavigateArgs = { path: string }
--:: UiPrimitives = {
--::   renderToast:     (RenderToastArgs) -> nil,
--::   renderDialog:    (RenderDialogArgs) -> string,
--::   requestNavigate: (RequestNavigateArgs) -> nil,
--:: }
--:: ToastFn    = (args: ToastArgs) -> nil
--:: DialogFn   = (args: DialogArgs) -> string
--:: NavigateFn = (args: NavigateArgs) -> nil
--:: UiCaps = {
--::   toast:    ToastFn,
--::   dialog:   DialogFn,
--::   navigate: NavigateFn,
--:: }
--:: MakeUiCapsFn = (uiPrimitives: UiPrimitives) -> UiCaps

-- buildDayZeroCapImpls: convenience composer. Takes the per-pack /
-- per-host-app configs for each factory cap and returns the full
-- cap-impls Map ready to drop into mountPack's `opts.capImpls`. Map
-- values are typed `unknown` on the Lua side because Lua does not have
-- a Map type and the function shapes within the Map are heterogeneous;
-- Lua callers should not be constructing this Map -- it is built by
-- the JS host page in `lib/js_pack_host/host.js` callers.
--:: BuildDayZeroCapImplsOpts = {
--::   fetchConfig:  FetchApiConfig | nil,
--::   kvConfig:     KvConfig | nil,
--::   uiPrimitives: UiPrimitives | nil,
--:: }
--:: BuildDayZeroCapImplsFn = (opts: BuildDayZeroCapImplsOpts) -> unknown

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

--: (FetchApiConfig) -> FetchApiFn
function M.makeFetchApi(_config)
  error("lib/js_caps is type-only on the Lua side.")
end

--: (KvConfig) -> KvCaps
function M.makeKvCaps(_config)
  error("lib/js_caps is type-only on the Lua side.")
end

--: (UiPrimitives) -> UiCaps
function M.makeUiCaps(_uiPrimitives)
  error("lib/js_caps is type-only on the Lua side.")
end

--: (BuildDayZeroCapImplsOpts) -> unknown
function M.buildDayZeroCapImpls(_opts)
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
