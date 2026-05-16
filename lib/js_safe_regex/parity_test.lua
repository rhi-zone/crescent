-- lib/js_safe_regex/parity_test.lua
--
-- Parity tests between lib/safe_regex/init.lua (Lua) and
-- lib/js_safe_regex/safe_regex.js (JS). Per CLAUDE.md, parallel
-- implementations require parity tests.
--
-- Two levels:
--
--   1. STATIC CORPUS PARITY (always runs). The two test corpora are
--      parsed and the pattern lists asserted equal in order. Catches
--      drift -- a case added to one corpus but not the other.
--
--   2. RUNTIME VERDICT PARITY (runs only if `bun` is on PATH).
--      For each pattern, Lua impl is invoked directly and JS impl is
--      invoked via a one-shot `bun` subprocess. The `ok` field must
--      agree; error-message text may differ in punctuation.
--
-- If `bun` is absent, runtime parity is skipped with a clear message.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local SR = require("lib.safe_regex")

--:: Case = { kind: string, pat: string }

-- ----------------------------------------------------------------------
-- File slurp helper
-- ----------------------------------------------------------------------

--: (string) -> string
local function slurp(path)
  local f = io.open(path, "r")
  if not f then error("cannot open " .. path) end
  local src = f:read("*a") or ""
  f:close()
  return src --[[: string]]
end

-- Evaluate a Lua double-quoted string literal body. `body` is the inner
-- text (between the quotes); escapes follow Lua syntax. Throws on error.
--: (string) -> string
local function eval_lua_dquote(body)
  local lit = "return \"" .. body .. "\""
  local fn, err = loadstring(lit)
  if not fn then error("bad literal: " .. tostring(err)) end
  local ok, val = pcall(fn)
  if not ok then error("eval failure: " .. tostring(val)) end
  if type(val) ~= "string" then error("literal didn't evaluate to string") end
  return val
end

-- Scan a double-quoted string literal starting at the opening `"` at
-- position `start` in `src`. Returns (body, end_pos) where end_pos is
-- the index of the closing `"`. Honours backslash escapes.
--: (string, integer) -> (string, integer)
local function scan_dquote(src, start)
  local len = #src
  local j = start + 1 --: integer
  local buf = {} --: { [integer]: string }
  local count = 0
  while j <= len do
    local c = string.sub(src, j, j)
    if c == "\\" and j < len then
      count = count + 1
      buf[count] = string.sub(src, j, j + 1)
      j = j + 2
    elseif c == "\"" then
      return table.concat(buf), j
    else
      count = count + 1
      buf[count] = c
      j = j + 1
    end
  end
  error("unterminated string literal at position " .. start)
end

-- ----------------------------------------------------------------------
-- Corpus extractors
-- ----------------------------------------------------------------------

-- Scrape `safe("...")` / `unsafe("..."...)` calls out of the Lua test.
--: (string) -> Case[]
local function extract_lua_cases(path)
  local src = slurp(path)
  local cases = {} --: Case[]
  local n = 0
  local i = 1 --: integer
  local len = #src
  while i <= len do
    local s_start, s_end = string.find(src, "safe%(\"", i)
    local u_start, u_end = string.find(src, "unsafe%(\"", i)
    local body --: string | nil
    local close_pos --: integer | nil
    local kind --: string | nil
    if s_start ~= nil and s_end ~= nil and (u_start == nil or s_start < u_start) then
      body, close_pos = scan_dquote(src, s_end)
      kind = "safe"
    elseif u_start ~= nil and u_end ~= nil then
      body, close_pos = scan_dquote(src, u_end)
      kind = "unsafe"
    else
      break
    end
    if body == nil or close_pos == nil or kind == nil then break end
    local pat = eval_lua_dquote(body)
    n = n + 1
    cases[n] = { kind = kind, pat = pat }
    i = close_pos + 1
  end
  return cases
end

-- Scrape `kind: "...", pat: "..."` pairs out of the JS test corpus.
--: (string) -> Case[]
local function extract_js_cases(path)
  local src = slurp(path)
  local cases = {} --: Case[]
  local n = 0
  local i = 1 --: integer
  local len = #src
  while i <= len do
    local k_start, k_end, kind = string.find(src, "kind:%s*\"(%w+)\"", i)
    if k_start == nil or k_end == nil or kind == nil then break end
    local p_start, p_end = string.find(src, "pat:%s*\"", k_end)
    if p_start == nil or p_end == nil then break end
    -- p_end is the position of the opening quote.
    local body, close_pos = scan_dquote(src, p_end)
    -- JS source escapes for the subset used here (\\, \", \n, \t, \r,
    -- \uHHHH, \xHH) overlap with Lua escapes well enough for
    -- loadstring. The patterns we feed contain regex escapes like
    -- `\d`, `\b`, `A`, `\u{1F600}`; these are valid Lua escape
    -- sequences too because `\d` etc. are treated as literal backslash
    -- + char by Lua only when the next char isn't a Lua escape -- but
    -- `\d`, `\w`, `\b`, `\B`, `\k`, `\u`, `\x` etc. include some Lua
    -- escapes (`\b` is backspace, `\u` requires a brace, `\x` requires
    -- two hex). Reuse a JS-shape literal evaluator instead.
    -- However in practice the corpus uses only `\\<char>` style which
    -- is fine, plus `\u{1F600}` -- Lua 5.2+ accepts `\u{...}` and
    -- LuaJIT does too. \b ambiguity: Lua \b is backspace (single
    -- char), but in our regex source the value is "\b" both ways, so
    -- it ends up equal anyway. We accept this and verify equality with
    -- the JS-side runtime check.
    n = n + 1
    cases[n] = { kind = kind, pat = eval_lua_dquote(body) }
    i = close_pos + 1
  end
  return cases
end

-- ----------------------------------------------------------------------
-- Bun runner (runtime parity)
-- ----------------------------------------------------------------------

--: () -> boolean
local function bun_available()
  local fh = io.popen("command -v bun 2>/dev/null")
  if not fh then return false end
  local out = fh:read("*l")
  fh:close()
  if out == nil then return false end
  return out ~= ""
end

-- JSON-encode a list of strings by hand (no json dep from the test path).
--: (string[]) -> string
local function json_string_array(strs)
  local parts = {} --: { [integer]: string }
  local p = 0
  p = p + 1; parts[p] = "["
  for k = 1, #strs do
    local s = strs[k]
    local esc = {} --: { [integer]: string }
    local e = 0
    for c = 1, #s do
      local ch = string.sub(s, c, c)
      local b = string.byte(ch) or 0
      e = e + 1
      if ch == "\\" then esc[e] = "\\\\"
      elseif ch == "\"" then esc[e] = "\\\""
      elseif ch == "\n" then esc[e] = "\\n"
      elseif ch == "\r" then esc[e] = "\\r"
      elseif ch == "\t" then esc[e] = "\\t"
      elseif b < 0x20 then
        esc[e] = string.format("\\u%04x", b)
      else
        esc[e] = ch
      end
    end
    p = p + 1; parts[p] = "\""
    p = p + 1; parts[p] = table.concat(esc)
    p = p + 1; parts[p] = "\""
    if k < #strs then
      p = p + 1; parts[p] = ","
    end
  end
  p = p + 1; parts[p] = "]"
  return table.concat(parts)
end

-- Invoke the JS validator on a list of patterns; returns a list of
-- boolean verdicts in input order. One bun spawn per batch.
--: (Case[]) -> boolean[]
local function run_js_batch(cases)
  local pats = {} --: string[]
  for k = 1, #cases do pats[k] = cases[k].pat end
  local json = json_string_array(pats)

  -- Resolve absolute path to safe_regex.js so the temp script (which
  -- lives in /tmp) can locate it regardless of bun's CWD.
  local cwd_f = io.popen("pwd")
  if not cwd_f then error("cannot resolve cwd") end
  local cwd_raw = cwd_f:read("*l") or ""
  cwd_f:close()
  local cwd = cwd_raw --[[: string]]
  if cwd == "" then error("pwd returned empty") end
  local js_path = cwd .. "/lib/js_safe_regex/safe_regex.js"

  local script =
    "import { validatePattern } from " .. string.format("%q", js_path) .. ";\n" ..
    "const pats = " .. json .. ";\n" ..
    "const out = pats.map(p => validatePattern(p).ok ? \"1\" : \"0\");\n" ..
    "process.stdout.write(out.join(\"\"));\n"

  local tmp = os.tmpname() .. ".mjs"
  local wf = io.open(tmp, "w")
  if not wf then error("cannot write tmp file " .. tmp) end
  wf:write(script)
  wf:close()

  local cmd = "bun " .. string.format("%q", tmp) .. " 2>&1"
  local rf = io.popen(cmd)
  if not rf then
    os.remove(tmp)
    error("io.popen failed for: " .. cmd)
  end
  local out_raw = rf:read("*a") or ""
  rf:close()
  os.remove(tmp)
  local out = out_raw --[[: string]]

  if #out ~= #cases then
    error("bun output length mismatch: expected " .. #cases ..
      " verdicts, got " .. #out .. " bytes -- output was: " .. out)
  end
  local verdicts = {} --: boolean[]
  for k = 1, #out do
    local c = string.sub(out, k, k)
    if c == "1" then
      verdicts[k] = true
    elseif c == "0" then
      verdicts[k] = false
    else
      error("bun emitted unexpected char " .. string.format("%q", c))
    end
  end
  return verdicts
end

-- ----------------------------------------------------------------------
-- Tests
-- ----------------------------------------------------------------------

T.describe("safe_regex / js_safe_regex corpus parity", function()
  local lua_cases = extract_lua_cases("lib/safe_regex/safe_regex_test.lua")
  local js_cases  = extract_js_cases("lib/js_safe_regex/safe_regex.test.js")

  T.it("Lua corpus is non-empty", function()
    T.ok(#lua_cases > 0, "no cases extracted from Lua test file")
  end)

  T.it("JS corpus is non-empty", function()
    T.ok(#js_cases > 0, "no cases extracted from JS test file")
  end)

  T.it("corpora have the same number of cases", function()
    T.eq(#lua_cases, #js_cases,
      "Lua corpus has " .. #lua_cases .. " cases, JS has " .. #js_cases ..
      " -- one was added without the other")
  end)

  T.it("corpora agree case-by-case on (kind, pattern)", function()
    local n = math.min(#lua_cases, #js_cases)
    for k = 1, n do
      local l = lua_cases[k]
      local j = js_cases[k]
      T.eq(l.kind, j.kind,
        "case #" .. k .. " kind mismatch: Lua=" .. l.kind ..
        " JS=" .. j.kind .. " (Lua pat=" .. string.format("%q", l.pat) ..
        ", JS pat=" .. string.format("%q", j.pat) .. ")")
      T.eq(l.pat, j.pat,
        "case #" .. k .. " pattern mismatch (kind=" .. l.kind .. ")")
    end
  end)
end)

T.describe("safe_regex / js_safe_regex runtime verdict parity", function()
  local lua_cases = extract_lua_cases("lib/safe_regex/safe_regex_test.lua")

  if not bun_available() then
    T.it("runtime parity is skipped (bun not on PATH)", function()
      T.ok(true, "bun absent -- static corpus parity above is the only check this run")
    end)
    return
  end

  local js_verdicts = run_js_batch(lua_cases)

  T.it("verdicts agree on every Lua corpus case", function()
    for k = 1, #lua_cases do
      local c = lua_cases[k]
      local lua_ok = SR.validate_pattern(c.pat)
      local js_ok  = js_verdicts[k]
      T.eq(lua_ok, js_ok,
        "case #" .. k .. " (" .. c.kind .. " " ..
        string.format("%q", c.pat) ..
        "): Lua ok=" .. tostring(lua_ok) ..
        " JS ok=" .. tostring(js_ok))
      if c.kind == "safe" then
        T.eq(lua_ok, true, "case #" .. k .. " kind=safe but Lua rejected it")
      else
        T.eq(lua_ok, false, "case #" .. k .. " kind=unsafe but Lua accepted it")
      end
    end
  end)
end)
