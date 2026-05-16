-- lib/js_realm_sandbox/parity_test.lua
--
-- Parity check between docs/platform_isolation.md §3 "Escape-test
-- corpus" and lib/js_realm_sandbox/sandbox.test.js. Every escape entry
-- listed in the spec MUST be referenced (by a distinctive
-- substring) in the JS test corpus. Drift between the spec and the
-- tests is the failure this catches: a corpus item added to the spec
-- but not exercised, or vice versa.
--
-- Optionally also drives bun to run the JS test file end-to-end, when
-- bun is on PATH -- mirrors the lib/js_safe_regex/parity_test.lua
-- pattern.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")

--:: SpecItem = { needle: string, doc: string }

-- =====================================================================
-- File slurp.
-- =====================================================================

--: (string) -> string
local function slurp(path)
  local f = io.open(path, "r")
  if not f then error("cannot open " .. path) end
  local src = f:read("*a") or ""
  f:close()
  return src --[[: string]]
end

-- =====================================================================
-- Spec corpus extraction.
--
-- The escape-test corpus in docs/platform_isolation.md is a Markdown
-- bulleted list under the heading "#### Escape-test corpus". We scan
-- for that heading and accumulate items until the next heading.
--
-- Each list item is normalised to a "needle": the most-distinctive
-- substring contained in the item, used as a presence check against
-- the JS test file. The mapping is hand-curated so each item gets a
-- short, unambiguous token. Adding a new corpus item to the spec
-- requires adding the corresponding needle here.
-- =====================================================================

-- Hand-curated needle table. Keys are the spec entries (lightly
-- normalised); values are the substrings that MUST appear in
-- sandbox.test.js. If the spec adds a corpus item, add an entry here
-- and the corresponding test in sandbox.test.js.
--
-- Order mirrors docs/platform_isolation.md §3 "Escape-test corpus".
local SPEC_ITEMS = { --: SpecItem[]
  { needle = "({}).__proto__.constructor.constructor",
    doc = "prototype-chain Function constructor reach" },
  { needle = "({}).constructor.constructor",
    doc = "Object constructor reach" },
  { needle = "(function(){}).constructor",
    doc = "function-instance constructor reach" },
  { needle = "(async function(){}).constructor",
    doc = "async function constructor reach" },
  { needle = "Object.getPrototypeOf",
    doc = "Object.getPrototypeOf removed" },
  { needle = "Reflect",
    doc = "Reflect.getPrototypeOf -- Reflect removed entirely" },
  { needle = "[].constructor.constructor",
    doc = "Array constructor reach" },
  { needle = "\"\".constructor.constructor",
    doc = "String constructor reach" },
  { needle = "(/x/).constructor.constructor",
    doc = "RegExp constructor reach" },
  { needle = "(new Error()).constructor.constructor",
    doc = "Error constructor reach" },
  { needle = "__proto__",
    doc = "__proto__ mutation attempts" },
  { needle = "Object.setPrototypeOf",
    doc = "Object.setPrototypeOf removed" },
  { needle = "repeat(1e9)",
    doc = "String.prototype.repeat DoS" },
  { needle = "Array(1e9)",
    doc = "Array(n) DoS" },
  { needle = "Array.from({length: 1e9})",
    doc = "Array.from length DoS" },
  { needle = "Array.of",
    doc = "Array.of arg-count DoS" },
  { needle = "String.fromCharCode",
    doc = "String.fromCharCode arg-count DoS" },
  { needle = "(a+)+b",
    doc = "ReDoS regex (catastrophic backtracking)" },
  { needle = "Symbol.for",
    doc = "Symbol.for removed (cross-realm registry)" },
  { needle = "__cap__",
    doc = "__cap__ assignment must throw/no-op" },
  { needle = "new Error()).stack",
    doc = "Error().stack masked" },
  { needle = "RegExp.$1",
    doc = "RegExp legacy statics neutralised" },
  -- Parser-level concerns; the runtime cannot defeat them but the spec
  -- still calls them out. We require the test file mention them in a
  -- comment so adding them later is discoverable.
  { needle = "function*",
    doc = "generator function literal (parser-side concern; runtime "
      .. "neutralises the constructor)" },
  { needle = "eval",
    doc = "eval removed at runtime (parser also rejects)" },
  { needle = "Function",
    doc = "Function constructor removed" },
}

-- =====================================================================
-- Tests.
-- =====================================================================

T.describe("js_realm_sandbox / spec escape-corpus parity", function()
  local js_src = slurp("lib/js_realm_sandbox/sandbox.test.js")

  T.it("test file is non-empty", function()
    T.ok(#js_src > 0, "sandbox.test.js is empty")
  end)

  T.it("every spec escape-corpus item is referenced in the test file", function()
    local missing = {} --: { [integer]: string }
    local n = 0
    for i = 1, #SPEC_ITEMS do
      local item = SPEC_ITEMS[i]
      if not string.find(js_src, item.needle, 1, true) then
        n = n + 1
        missing[n] = item.needle .. "  (" .. item.doc .. ")"
      end
    end
    T.eq(n, 0,
      "spec corpus items not referenced in sandbox.test.js:\n  - " ..
      table.concat(missing, "\n  - "))
  end)

  T.it("test file mentions the lockdown entry point", function()
    T.ok(string.find(js_src, "installLockdown", 1, true) ~= nil,
      "sandbox.test.js does not exercise installLockdown")
  end)
end)

-- =====================================================================
-- Optional: drive the JS test file end-to-end via bun.
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

T.describe("js_realm_sandbox / sandbox.test.js end-to-end", function()
  if not bun_available() then
    T.it("skipped (bun not on PATH)", function()
      T.ok(true, "bun absent -- spec parity above is the only check this run")
    end)
    return
  end

  T.it("bun lib/js_realm_sandbox/sandbox.test.js exits 0", function()
    local cmd = "bun lib/js_realm_sandbox/sandbox.test.js 2>&1"
    local fh = io.popen(cmd)
    if not fh then error("io.popen failed for: " .. cmd) end
    local out = fh:read("*a") or ""
    local ok, _kind, code = fh:close()
    -- io.popen close returns (ok, "exit", code) in LuaJIT.
    T.ok(ok and (code == 0 or code == nil),
      "bun sandbox.test.js failed; output was:\n" .. out)
  end)
end)
