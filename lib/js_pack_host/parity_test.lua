-- lib/js_pack_host/parity_test.lua
--
-- Parity check between the bootstrap's documented contract
-- (docs/platform_isolation.md §3 "Bootstrap script" / "Bootstrap
-- order", lib/js_pack_host/bootstrap.js JSDoc) and
-- lib/js_pack_host/bootstrap.test.js. Each load-bearing aspect of the
-- bootstrap MUST be exercised in the JS test corpus, identified by a
-- hand-curated needle that appears verbatim in the test file.
--
-- Optionally drives bun to run bootstrap.test.js end-to-end when bun
-- is available -- mirrors lib/js_cap_bridge/parity_test.lua.

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
-- Spec corpus. Each entry maps a documented bootstrap contract item
-- (in bootstrap.js JSDoc + docs/platform_isolation.md §3) to a
-- substring that MUST appear in bootstrap.test.js.
-- =====================================================================

local SPEC_RULES = { --: SpecItem[]
  -- Entry point and its key dependencies are referenced.
  { needle = "runBootstrap",
    doc = "test file exercises runBootstrap" },
  { needle = "createHostBridge",
    doc = "paired host-side bridge instantiated outside the vm" },
  -- Paired-bridge end-to-end round trip.
  { needle = "round-trips through host impl",
    doc = "realm call routes through host impl and back" },
  -- Cap subset enforcement on __cap__.
  { needle = "only granted capNames",
    doc = "only granted capNames surface on globalThis.__cap__" },
  { needle = "fetch_api",
    doc = "ungranted cap absent from __cap__" },
  -- Lockdown effective after bootstrap.
  { needle = "lockdown effective",
    doc = "lockdown checks run after bootstrap" },
  { needle = "typeof eval === 'undefined'",
    doc = "eval stripped post-bootstrap" },
  { needle = "typeof Function === 'undefined'",
    doc = "Function stripped post-bootstrap" },
  { needle = "typeof Object.create === 'undefined'",
    doc = "Object.create stripped post-bootstrap" },
  { needle = "({}).__proto__ === undefined",
    doc = "prototype-chain constructor reach closed" },
  -- Bridge envelope shape.
  { needle = "envelope id is a number",
    doc = "call envelope id is numeric" },
  { needle = "envelope.kind",
    doc = "call envelope kind is 'call'" },
  { needle = "envelope.cap",
    doc = "call envelope cap matches name" },
  { needle = "envelope.args",
    doc = "call envelope args is an array mirroring call arguments" },
  -- Non-constructable cap shell.
  { needle = "new __cap__.toast()",
    doc = "new __cap__.<name>() throws TypeError" },
  { needle = "TypeError",
    doc = "non-constructable cap shell throws TypeError" },
  -- node:vm test harness is wired.
  { needle = "node:vm",
    doc = "tests run inside node:vm contexts" },
  { needle = "_skipGlobalFreeze",
    doc = "tests pass _skipGlobalFreeze (bun node:vm freeze emulation gap)" },
}

T.describe("js_pack_host / bootstrap contract parity", function()
  local js_src = slurp("lib/js_pack_host/bootstrap.test.js")

  T.it("test file is non-empty", function()
    T.ok(#js_src > 0, "bootstrap.test.js is empty")
  end)

  T.it("every bootstrap contract rule is referenced in bootstrap.test.js", function()
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
      "bootstrap contract rules not exercised in bootstrap.test.js:\n  - " ..
      table.concat(missing, "\n  - "))
  end)
end)

-- =====================================================================
-- Optional: drive bootstrap.test.js end-to-end via bun.
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

T.describe("js_pack_host / bootstrap.test.js end-to-end", function()
  if not bun_available() then
    T.it("skipped (bun not on PATH)", function()
      T.ok(true, "bun absent -- static parity above is the only check this run")
    end)
    return
  end

  T.it("bun lib/js_pack_host/bootstrap.test.js exits 0", function()
    local cmd = "bun lib/js_pack_host/bootstrap.test.js 2>&1"
    local fh = io.popen(cmd)
    if not fh then error("io.popen failed for: " .. cmd) end
    local out = fh:read("*a") or ""
    local ok, _kind, code = fh:close()
    T.ok(ok and (code == 0 or code == nil),
      "bun bootstrap.test.js failed; output was:\n" .. out)
  end)
end)
