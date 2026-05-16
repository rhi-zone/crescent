-- lib/js_caps/parity_test.lua
--
-- Parity check between docs/browser_caps.md §4 + §5 (per-cap schema
-- sketches and the day-zero exposed cap surface) and
-- lib/js_caps/caps.test.js. Each cap kind documented in §5 as shipped
-- in this commit MUST be exercised in the JS test corpus, identified
-- by a hand-curated needle that appears verbatim in the test file.
--
-- Optionally drives bun to run caps.test.js end-to-end when bun is
-- available -- mirrors lib/js_cap_bridge/parity_test.lua.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")

--:: SpecItem = { needle: string, doc: string }

--: (string) -> string
local function slurp(path)
  local f = io.open(path, "r")
  if not f then error("cannot open " .. path) end
  local src = f:read("*a") or ""
  f:close()
  return src --[[: string]]
end

-- =====================================================================
-- Cap-kind corpus. Each entry maps a documented day-zero cap kind (in
-- docs/browser_caps.md §5) to a substring that MUST appear in
-- caps.test.js. The nine kinds below are the bare-function dayZeroCaps
-- entries (six trivial pure-wrap caps + set_timeout + web_crypto_subtle,
-- which consumes the cap-bridge AbortSignal extension per
-- docs/platform_isolation.md §4, + clipboard_write). The remaining
-- caps (navigate, dialog, toast) land in subsequent commits.
--
-- fetch_api and the four kv_* caps are factory caps (per-pack
-- config-bound at host-side instantiation per docs/browser_caps.md
-- §4.1.1, §4.2.1); their impls are shipped but they are NOT in
-- dayZeroCaps -- the host page constructs them via makeFetchApi /
-- makeKvCaps and inserts the results into the cap-impls Map per
-- manifest entry. kv_* in particular share a backend (one IndexedDB
-- database `pack_<pack_id>` with a single `kv` object store) and the
-- factory returns a record of all four caps.
-- =====================================================================

local SPEC_RULES = { --: SpecItem[]
  -- text_encode
  { needle = "text_encode: ascii happy path",
    doc = "text_encode: utf-8 encode happy path" },
  { needle = "text_encode: utf-8 multi-byte",
    doc = "text_encode: multi-byte boundary" },
  { needle = "text_encode: empty string",
    doc = "text_encode: empty-string boundary" },
  { needle = "text_encode: non-string throws TypeError",
    doc = "text_encode: validation failure on non-string" },
  -- text_decode
  { needle = "text_decode: ascii happy path",
    doc = "text_decode: happy path" },
  { needle = "text_decode: utf-8 multi-byte",
    doc = "text_decode: multi-byte boundary" },
  { needle = "text_decode: fatal opt rejects invalid utf-8",
    doc = "text_decode: fatal option propagates" },
  { needle = "text_decode: non-Uint8Array throws TypeError",
    doc = "text_decode: validation failure on bad input" },
  -- compress / decompress
  { needle = "compress + decompress: gzip round trip",
    doc = "compress/decompress: gzip round-trip" },
  { needle = "compress + decompress: deflate round trip",
    doc = "compress/decompress: deflate round-trip" },
  { needle = "compress + decompress: deflate-raw round trip",
    doc = "compress/decompress: deflate-raw round-trip" },
  { needle = "compress: bad format throws TypeError",
    doc = "compress: validation failure on bad format" },
  { needle = "decompress: bad format throws TypeError",
    doc = "decompress: validation failure on bad format" },
  -- console_log
  { needle = "console_log: returns undefined",
    doc = "console_log: happy path returns undefined" },
  { needle = "console_log: cycles do not throw",
    doc = "console_log: unrepresentable values do not throw" },
  -- web_crypto_random
  { needle = "web_crypto_random: small length",
    doc = "web_crypto_random: happy path" },
  { needle = "web_crypto_random: max length 65536",
    doc = "web_crypto_random: upper-bound boundary" },
  { needle = "web_crypto_random: length 0 rejected",
    doc = "web_crypto_random: lower-bound validation" },
  { needle = "web_crypto_random: length 65537 rejected",
    doc = "web_crypto_random: upper-bound validation" },
  -- set_timeout
  { needle = "set_timeout: resolves after delay",
    doc = "set_timeout: happy path resolves after delay" },
  { needle = "set_timeout: zero delay resolves promptly",
    doc = "set_timeout: zero-delay boundary" },
  { needle = "set_timeout: negative delay throws TypeError",
    doc = "set_timeout: validation failure on negative delay" },
  { needle = "set_timeout: Infinity delay throws TypeError",
    doc = "set_timeout: validation failure on Infinity" },
  { needle = "set_timeout: NaN delay throws TypeError",
    doc = "set_timeout: validation failure on NaN" },
  { needle = "set_timeout: string delay throws TypeError",
    doc = "set_timeout: validation failure on non-number delay" },
  { needle = "set_timeout: AbortSignal cancellation rejects with AbortError",
    doc = "set_timeout: cancellation via AbortSignal" },
  { needle = "set_timeout: pre-aborted signal rejects immediately",
    doc = "set_timeout: pre-aborted signal short-circuits" },
  { needle = "set_timeout: signal aborted after fire is a no-op",
    doc = "set_timeout: post-fire abort is a no-op" },
  { needle = "set_timeout: invalid opts.signal throws TypeError",
    doc = "set_timeout: validation failure on bad signal type" },
  { needle = "set_timeout: non-constructable",
    doc = "set_timeout: non-constructable (concise/arrow)" },
  -- web_crypto_subtle
  { needle = "web_crypto_subtle: digest happy path SHA-256",
    doc = "web_crypto_subtle: digest op" },
  { needle = "web_crypto_subtle: unknown op throws TypeError",
    doc = "web_crypto_subtle: validation failure on unknown op" },
  { needle = "web_crypto_subtle: null args throws TypeError",
    doc = "web_crypto_subtle: validation failure on null args" },
  { needle = "web_crypto_subtle: missing op throws TypeError",
    doc = "web_crypto_subtle: validation failure on missing op" },
  { needle = "web_crypto_subtle: missing required field throws TypeError",
    doc = "web_crypto_subtle: validation failure on missing required field" },
  { needle = "web_crypto_subtle: generateKey + encrypt + decrypt round trip",
    doc = "web_crypto_subtle: generateKey/encrypt/decrypt ops" },
  { needle = "web_crypto_subtle: sign + verify HMAC",
    doc = "web_crypto_subtle: sign/verify ops" },
  { needle = "web_crypto_subtle: importKey + exportKey jwk round trip",
    doc = "web_crypto_subtle: importKey/exportKey ops" },
  { needle = "web_crypto_subtle: deriveKey via PBKDF2",
    doc = "web_crypto_subtle: deriveKey op" },
  { needle = "web_crypto_subtle: wrapKey + unwrapKey round trip",
    doc = "web_crypto_subtle: wrapKey/unwrapKey ops" },
  { needle = "web_crypto_subtle: non-constructable",
    doc = "web_crypto_subtle: non-constructable (concise/arrow)" },
  { needle = "web_crypto_subtle: CryptoKey survives structured clone",
    doc = "web_crypto_subtle: CryptoKey survives the bridge boundary" },
  -- clipboard_write
  { needle = "clipboard_write: non-string number throws TypeError",
    doc = "clipboard_write: validation failure on non-string number" },
  { needle = "clipboard_write: non-string object throws TypeError",
    doc = "clipboard_write: validation failure on non-string object" },
  { needle = "clipboard_write: null throws TypeError",
    doc = "clipboard_write: validation failure on null" },
  { needle = "clipboard_write: oversized text rejects with RangeError",
    doc = "clipboard_write: 1 MiB size cap" },
  { needle = "clipboard_write: happy path writes through to navigator.clipboard.writeText",
    doc = "clipboard_write: happy path via mocked navigator.clipboard" },
  { needle = "clipboard_write: NotAllowedError propagates",
    doc = "clipboard_write: permission denial propagates" },
  { needle = "clipboard_write: missing navigator.clipboard throws clear error",
    doc = "clipboard_write: graceful error when API absent" },
  { needle = "clipboard_write: non-constructable",
    doc = "clipboard_write: non-constructable (arrow function)" },
  -- fetch_api (factory)
  { needle = "fetch_api factory: null config throws TypeError",
    doc = "fetch_api: factory rejects null config" },
  { needle = "fetch_api factory: non-array allowed_origins throws TypeError",
    doc = "fetch_api: factory rejects non-array allowed_origins" },
  { needle = "fetch_api factory: non-string allowed_origins entry throws TypeError",
    doc = "fetch_api: factory rejects non-string allowed_origins entry" },
  { needle = "fetch_api: non-constructable",
    doc = "fetch_api: non-constructable (concise method)" },
  { needle = "fetch_api: invalid url throws TypeError",
    doc = "fetch_api: validation failure on non-absolute URL" },
  { needle = "fetch_api: missing url throws TypeError",
    doc = "fetch_api: validation failure on missing url" },
  { needle = "fetch_api: origin not in allowlist throws TypeError",
    doc = "fetch_api: origin allowlist enforcement" },
  { needle = "fetch_api: invalid method throws TypeError",
    doc = "fetch_api: validation failure on disallowed method" },
  { needle = "fetch_api: non-object headers throws TypeError",
    doc = "fetch_api: validation failure on non-object headers" },
  { needle = "fetch_api: non-string header value throws TypeError",
    doc = "fetch_api: validation failure on non-string header value" },
  { needle = "fetch_api: happy path returns arraybuffer body by default",
    doc = "fetch_api: happy path with default response format" },
  { needle = "fetch_api: responseFormat json returns decoded JSON",
    doc = "fetch_api: responseFormat json branch" },
  { needle = "fetch_api: responseFormat text returns string",
    doc = "fetch_api: responseFormat text branch" },
  { needle = "fetch_api: invalid responseFormat throws TypeError",
    doc = "fetch_api: validation failure on bad responseFormat" },
  { needle = "fetch_api: AbortSignal propagates abort to fetch",
    doc = "fetch_api: AbortSignal cancellation" },
  { needle = "fetch_api: invalid signal throws TypeError",
    doc = "fetch_api: validation failure on bad signal" },
  { needle = "fetch_api: missing globalThis.fetch throws clear error",
    doc = "fetch_api: graceful error when fetch absent" },
  -- kv_* (factory: makeKvCaps)
  { needle = "kv factory: null config throws TypeError",
    doc = "kv_*: factory rejects null config" },
  { needle = "kv factory: non-string pack_id throws TypeError",
    doc = "kv_*: factory rejects non-string pack_id" },
  { needle = "kv factory: empty pack_id throws TypeError",
    doc = "kv_*: factory rejects empty pack_id" },
  { needle = "kv_read: non-constructable",
    doc = "kv_*: caps are non-constructable (concise method)" },
  { needle = "kv_read: write then read roundtrip",
    doc = "kv_read/kv_write: roundtrip" },
  { needle = "kv_read: missing key returns undefined",
    doc = "kv_read: absent-key sentinel" },
  { needle = "kv_delete: removes a key",
    doc = "kv_delete: happy path" },
  { needle = "kv_delete: absent key is a no-op",
    doc = "kv_delete: missing-key no-op" },
  { needle = "kv_keys: enumerates all keys",
    doc = "kv_keys: enumeration" },
  { needle = "kv: structured clone preserves Uint8Array and nested shape",
    doc = "kv: structured-clone fidelity for Uint8Array values" },
  { needle = "kv: per-pack partitioning isolates writes by pack_id",
    doc = "kv: per-pack storage partitioning" },
  { needle = "kv_read: non-string key throws TypeError",
    doc = "kv_read: validation failure on non-string key" },
  { needle = "kv_write: non-string key throws TypeError",
    doc = "kv_write: validation failure on non-string key" },
  { needle = "kv_write: empty key throws TypeError",
    doc = "kv_write: validation failure on empty key" },
  { needle = "kv_write: oversized key throws TypeError",
    doc = "kv_write: validation failure on oversized key" },
  { needle = "kv_write: null args throws TypeError",
    doc = "kv_write: validation failure on null args" },
  -- toast / dialog / navigate (factory: makeUiCaps)
  { needle = "makeUiCaps factory: null uiPrimitives throws TypeError",
    doc = "makeUiCaps: factory rejects null primitives" },
  { needle = "makeUiCaps factory: missing renderToast throws TypeError",
    doc = "makeUiCaps: factory rejects missing renderToast" },
  { needle = "makeUiCaps factory: missing renderDialog throws TypeError",
    doc = "makeUiCaps: factory rejects missing renderDialog" },
  { needle = "makeUiCaps factory: missing requestNavigate throws TypeError",
    doc = "makeUiCaps: factory rejects missing requestNavigate" },
  { needle = "makeUiCaps factory: returns object with three caps",
    doc = "makeUiCaps: factory returns toast/dialog/navigate" },
  { needle = "toast: happy path calls renderToast with defaults",
    doc = "toast: happy path forwards to primitive with defaults" },
  { needle = "toast: forwards level and duration",
    doc = "toast: explicit level/duration forwarded" },
  { needle = "toast: null args throws TypeError",
    doc = "toast: validation failure on null args" },
  { needle = "toast: missing message throws TypeError",
    doc = "toast: validation failure on missing message" },
  { needle = "toast: empty message throws TypeError",
    doc = "toast: validation failure on empty message" },
  { needle = "toast: oversized message rejects with RangeError",
    doc = "toast: validation failure on oversized message" },
  { needle = "toast: invalid level throws TypeError",
    doc = "toast: validation failure on bad level" },
  { needle = "toast: negative duration rejects with RangeError",
    doc = "toast: validation failure on negative duration" },
  { needle = "toast: Infinity duration throws TypeError",
    doc = "toast: validation failure on non-finite duration" },
  { needle = "toast: oversized duration rejects with RangeError",
    doc = "toast: validation failure on duration > 30s" },
  { needle = "toast: non-constructable",
    doc = "toast: non-constructable (concise method)" },
  { needle = "dialog: happy path returns selected button",
    doc = "dialog: happy path resolves to button name" },
  { needle = "dialog: host returned unknown button rejects",
    doc = "dialog: host contract violation surfaces as error" },
  { needle = "dialog: host returned non-string rejects",
    doc = "dialog: non-string host return surfaces as error" },
  { needle = "dialog: null args throws TypeError",
    doc = "dialog: validation failure on null args" },
  { needle = "dialog: missing message throws TypeError",
    doc = "dialog: validation failure on missing message" },
  { needle = "dialog: empty buttons throws TypeError",
    doc = "dialog: validation failure on empty buttons" },
  { needle = "dialog: non-array buttons throws TypeError",
    doc = "dialog: validation failure on non-array buttons" },
  { needle = "dialog: too many buttons rejects with RangeError",
    doc = "dialog: validation failure on >8 buttons" },
  { needle = "dialog: non-string button throws TypeError",
    doc = "dialog: validation failure on non-string button entry" },
  { needle = "dialog: empty button name throws TypeError",
    doc = "dialog: validation failure on empty button name" },
  { needle = "dialog: oversized message rejects with RangeError",
    doc = "dialog: validation failure on oversized message" },
  { needle = "dialog: non-constructable",
    doc = "dialog: non-constructable (concise method)" },
  { needle = "navigate: happy path calls requestNavigate",
    doc = "navigate: happy path forwards to primitive" },
  { needle = "navigate: null args throws TypeError",
    doc = "navigate: validation failure on null args" },
  { needle = "navigate: missing path throws TypeError",
    doc = "navigate: validation failure on missing path" },
  { needle = "navigate: empty path throws TypeError",
    doc = "navigate: validation failure on empty path" },
  { needle = "navigate: non-string path throws TypeError",
    doc = "navigate: validation failure on non-string path" },
  { needle = "navigate: oversized path rejects with RangeError",
    doc = "navigate: validation failure on oversized path" },
  { needle = "navigate: non-constructable",
    doc = "navigate: non-constructable (concise method)" },
  -- buildDayZeroCapImpls helper
  { needle = "buildDayZeroCapImpls: with all configs returns 17-entry Map",
    doc = "buildDayZeroCapImpls: full composition contains all 17 caps" },
  { needle = "buildDayZeroCapImpls: missing uiPrimitives omits toast/dialog/navigate",
    doc = "buildDayZeroCapImpls: ui factory omitted when uiPrimitives missing" },
  { needle = "buildDayZeroCapImpls: null opts throws TypeError",
    doc = "buildDayZeroCapImpls: validation failure on null opts" },
  { needle = "buildDayZeroCapImpls: ui-only composition includes 12 caps",
    doc = "buildDayZeroCapImpls: partial composition (pure + ui)" },
  -- dayZeroCaps aggregate
  { needle = "dayZeroCaps: contains the 9 shipped caps",
    doc = "dayZeroCaps map contains the 9 shipped names" },
  { needle = "dayZeroCaps: does not contain the deferred caps",
    doc = "dayZeroCaps map excludes deferred cap names" },
}

T.describe("js_caps / cap-kind parity", function()
  local js_src = slurp("lib/js_caps/caps.test.js")

  T.it("test file is non-empty", function()
    T.ok(#js_src > 0, "caps.test.js is empty")
  end)

  T.it("every day-zero cap rule is referenced in caps.test.js", function()
    local missing = {} --: { [integer]: string }
    local n = 0
    for i = 1, #SPEC_RULES do
      local item = SPEC_RULES[i]
      if not string.find(js_src, item.needle, 1, true) then
        n = n + 1
        missing[n] = item.needle .. "  (" .. item.doc .. ")"
      end
    end
    T.eq(n, 0,
      "cap-kind rules not exercised in caps.test.js:\n  - " ..
      table.concat(missing, "\n  - "))
  end)
end)

-- =====================================================================
-- Optional: drive caps.test.js end-to-end via bun.
-- =====================================================================

--: () -> boolean
local function bun_available()
  local fh = io.popen("command -v bun 2>/dev/null")
  if not fh then return false end
  local out = fh:read("*l")
  fh:close()
  if out == nil then return false end
  return out ~= ""
end

T.describe("js_caps / caps.test.js end-to-end", function()
  if not bun_available() then
    T.it("skipped (bun not on PATH)", function()
      T.ok(true, "bun absent -- static parity above is the only check this run")
    end)
    return
  end

  T.it("bun lib/js_caps/caps.test.js exits 0", function()
    local cmd = "bun lib/js_caps/caps.test.js 2>&1"
    local fh = io.popen(cmd)
    if not fh then error("io.popen failed for: " .. cmd) end
    local out = fh:read("*a") or ""
    local ok, _kind, code = fh:close()
    T.ok(ok and (code == 0 or code == nil),
      "bun caps.test.js failed; output was:\n" .. out)
  end)
end)
