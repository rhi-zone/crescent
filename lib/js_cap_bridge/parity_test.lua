-- lib/js_cap_bridge/parity_test.lua
--
-- Parity check between docs/platform_isolation.md §4 "Capability bridge
-- protocol" (plus the adversarial-review additions in §4 "Validation":
-- no implicit coercion, foreign thenable hazard) and
-- lib/js_cap_bridge/bridge.test.js. Each protocol rule documented in the
-- module's JSDoc header MUST be exercised in the JS test corpus,
-- identified by a hand-curated needle that appears verbatim in the test
-- file.
--
-- Optionally drives bun to run bridge.test.js end-to-end when bun is
-- available -- mirrors lib/js_realm_sandbox/parity_test.lua.

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
-- Protocol-rule corpus. Each entry maps a documented protocol rule (in
-- docs/platform_isolation.md §4 and the bridge.js JSDoc header) to a
-- substring that MUST appear in bridge.test.js.
-- =====================================================================

local SPEC_RULES = { --: SpecItem[]
  -- Envelope shapes
  { needle = "kind: \"call\"",
    doc = "realm->host call envelope shape" },
  { needle = "kind: \"result\"",
    doc = "host->realm result envelope shape" },
  { needle = "kind: \"error\"",
    doc = "host->realm error envelope shape" },
  -- Error types
  { needle = "\"denied\"",
    doc = "error type: denied (cap not granted)" },
  { needle = "\"missing\"",
    doc = "error type: missing (cap impl absent)" },
  { needle = "\"throw\"",
    doc = "error type: throw (impl threw or rejected)" },
  { needle = "\"malformed\"",
    doc = "error type: malformed (host responds when id is recoverable)" },
  -- Happy path
  { needle = "happy path: echo",
    doc = "single-call round trip" },
  { needle = "concurrent calls correlate by id",
    doc = "id-based correlation under concurrency" },
  { needle = "host returns a Promise",
    doc = "Promise return values supported" },
  -- Authorization
  { needle = "not in grantedCaps",
    doc = "auth: ungranted cap rejected with denied" },
  { needle = "impl missing rejects with missing",
    doc = "auth: granted but absent impl rejected with missing" },
  -- Error propagation
  { needle = "impl throws",
    doc = "synchronous throw from cap impl" },
  { needle = "impl returns rejected promise",
    doc = "async rejection from cap impl" },
  -- Malformed protocol
  { needle = "alien response with unknown id",
    doc = "realm drops responses for unknown ids" },
  { needle = "malformed when id is recoverable",
    doc = "host responds malformed when id can be salvaged" },
  { needle = "no recoverable id",
    doc = "host drops envelopes with no recoverable id" },
  { needle = "second response for same id",
    doc = "first response wins; subsequent dropped" },
  -- Non-constructability
  { needle = "new caps.echo()",
    doc = "realm cap shells are non-constructable" },
  { needle = "TypeError",
    doc = "non-constructable cap shell throws TypeError on `new`" },
  -- No implicit coercion / foreign thenable
  { needle = "Symbol.toPrimitive",
    doc = "host bridge never triggers Symbol.toPrimitive on args" },
  { needle = "no implicit coercion",
    doc = "no-implicit-coercion rule asserted in test corpus" },
  -- Sync postMessage failure
  { needle = "postMessage that throws",
    doc = "realm rejects when postMessage throws synchronously" },
  -- Entry points must be invoked
  { needle = "createRealmBridge",
    doc = "test file exercises createRealmBridge" },
  { needle = "createHostBridge",
    doc = "test file exercises createHostBridge" },
}

T.describe("js_cap_bridge / protocol rule parity", function()
  local js_src = slurp("lib/js_cap_bridge/bridge.test.js")

  T.it("test file is non-empty", function()
    T.ok(#js_src > 0, "bridge.test.js is empty")
  end)

  T.it("every protocol rule is referenced in bridge.test.js", function()
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
      "protocol rules not exercised in bridge.test.js:\n  - " ..
      table.concat(missing, "\n  - "))
  end)
end)

-- =====================================================================
-- Optional: drive bridge.test.js end-to-end via bun.
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

T.describe("js_cap_bridge / bridge.test.js end-to-end", function()
  if not bun_available() then
    T.it("skipped (bun not on PATH)", function()
      T.ok(true, "bun absent -- static parity above is the only check this run")
    end)
    return
  end

  T.it("bun lib/js_cap_bridge/bridge.test.js exits 0", function()
    local cmd = "bun lib/js_cap_bridge/bridge.test.js 2>&1"
    local fh = io.popen(cmd)
    if not fh then error("io.popen failed for: " .. cmd) end
    local out = fh:read("*a") or ""
    local ok, _kind, code = fh:close()
    T.ok(ok and (code == 0 or code == nil),
      "bun bridge.test.js failed; output was:\n" .. out)
  end)
end)
