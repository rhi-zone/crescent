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
-- caps.test.js. The six kinds below are the ones this commit ships;
-- the remaining twelve (including set_timeout, which is blocked on the
-- cap-bridge AbortSignal extension per docs/platform_isolation.md §4)
-- land in subsequent commits and will be added here when their impls
-- land.
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
  -- dayZeroCaps aggregate
  { needle = "dayZeroCaps: contains the 6 trivial caps",
    doc = "dayZeroCaps map contains the 6 shipped names" },
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
