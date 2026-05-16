-- lib/js_pack_validator/parity_test.lua
--
-- Parity check between docs/platform_isolation.md §3 "Pack JS subset
-- (draft)" and lib/js_pack_validator/validator.test.js. Every banned /
-- restricted rule listed in the spec MUST be exercised in the JS test
-- corpus, identified by a hand-curated needle that appears verbatim in
-- the test file.
--
-- This mirrors lib/js_realm_sandbox/parity_test.lua: spec corpus on the
-- left, test-file substring needles on the right, adding a new rule to
-- the spec means adding the corresponding needle here AND a test case.
--
-- Optionally drives bun to run validator.test.js end-to-end when bun is
-- available.

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
-- Spec rule corpus. Each entry maps a docs/platform_isolation.md §3
-- "Pack JS subset" rule to a substring that MUST appear in
-- validator.test.js. The substring is normally either the rule's
-- distinctive AST keyword (in a `src:` string) or the rule label (in
-- the `rule:` field). Both are textual in the test file so a plain
-- string search is sufficient.
--
-- Order mirrors the spec's "Banned AST node types" / "Restricted
-- forms" lists.
-- =====================================================================

local SPEC_RULES = { --: SpecItem[]
  -- Banned AST node types
  { needle = "ClassDeclaration",
    doc = "class declaration banned (spec: ClassDeclaration / ClassExpression)" },
  { needle = "ClassExpression",
    doc = "class expression banned" },
  { needle = "WithStatement",
    doc = "with statement banned (legacy reflection)" },
  { needle = "generator function",
    doc = "generator function syntax banned (`function*`)" },
  { needle = "async generator",
    doc = "async generator banned (`async function*`)" },
  { needle = "TaggedTemplateExpression",
    doc = "tagged template literal banned" },
  { needle = "ImportExpression",
    doc = "dynamic import() banned" },
  { needle = "import.meta",
    doc = "import.meta meta-property banned" },
  -- Restricted forms
  { needle = "dynamic bracket",
    doc = "computed bracket access with non-literal key banned" },
  { needle = "non-whitelisted constructor",
    doc = "`new <name>` where <name> not in allow-list and not pack-local" },
  -- Banned global identifiers (each spec-listed name has a test case)
  { needle = "banned identifier: eval",
    doc = "Identifier `eval` rejected" },
  { needle = "banned identifier: Function",
    doc = "Identifier `Function` rejected" },
  { needle = "banned identifier: Reflect",
    doc = "Identifier `Reflect` rejected" },
  { needle = "banned identifier: Proxy",
    doc = "Identifier `Proxy` rejected" },
  { needle = "banned identifier: WeakRef",
    doc = "Identifier `WeakRef` rejected" },
  { needle = "banned identifier: FinalizationRegistry",
    doc = "Identifier `FinalizationRegistry` rejected" },
  { needle = "banned identifier: SharedArrayBuffer",
    doc = "Identifier `SharedArrayBuffer` rejected" },
  -- Regex literal hook into lib/js_safe_regex
  { needle = "regex literal catastrophic",
    doc = "regex literal validated via lib/js_safe_regex" },
  -- Error reporting shape
  { needle = "error location reporting",
    doc = "errors carry line/column/nodeType" },
  -- Acceptance cases (positive corpus must be exercised, not just rejects)
  { needle = "async function declaration",
    doc = "async function (non-generator) is allowed -- positive corpus" },
  { needle = "static import / export",
    doc = "static ESM import/export is allowed -- positive corpus" },
  { needle = "new on pack-local function",
    doc = "pack-local function names are allowed as `new` targets" },
  { needle = "safe regex literal",
    doc = "safe regex literals accepted -- positive corpus" },
}

T.describe("js_pack_validator / spec rule parity", function()
  local js_src = slurp("lib/js_pack_validator/validator.test.js")

  T.it("test file is non-empty", function()
    T.ok(#js_src > 0, "validator.test.js is empty")
  end)

  T.it("every spec subset rule is referenced in validator.test.js", function()
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
      "spec subset rules not exercised in validator.test.js:\n  - " ..
      table.concat(missing, "\n  - "))
  end)

  T.it("test file invokes the validator", function()
    T.ok(string.find(js_src, "validate", 1, true) ~= nil,
      "validator.test.js does not call validate(...)")
  end)
end)

-- =====================================================================
-- Optional: drive validator.test.js end-to-end via bun.
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

T.describe("js_pack_validator / validator.test.js end-to-end", function()
  if not bun_available() then
    T.it("skipped (bun not on PATH)", function()
      T.ok(true, "bun absent -- static parity above is the only check this run")
    end)
    return
  end

  T.it("bun lib/js_pack_validator/validator.test.js exits 0", function()
    local cmd = "bun lib/js_pack_validator/validator.test.js 2>&1"
    local fh = io.popen(cmd)
    if not fh then error("io.popen failed for: " .. cmd) end
    local out = fh:read("*a") or ""
    local ok, _kind, code = fh:close()
    T.ok(ok and (code == 0 or code == nil),
      "bun validator.test.js failed; output was:\n" .. out)
  end)
end)
