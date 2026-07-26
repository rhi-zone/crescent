#!/usr/bin/env luajit
-- tooling/grammar_gen/generate.lua
--
-- The decoder side of the grammar: given a derivation (an ordered list of
-- segments, each either literal terminal text or the already-expanded
-- output of a production — see derivations.lua), expand it into the source
-- text of one init.lua file.
--
-- Usage:
--   luajit generate.lua <derivation_name>        -- print generated source
--   luajit generate.lua <derivation_name> --diff  -- diff against the real file
--   luajit generate.lua --all --diff              -- do it for every derivation

local script_dir = (arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = script_dir .. "/?.lua;" .. package.path

local derivations = require("derivations")

--: (derivation: { segments: { [integer]: { kind: string, text: string } }, real_path: string }) -> string
local function generate(derivation)
  local parts = {}
  for _, seg in ipairs(derivation.segments) do
    parts[#parts + 1] = seg.text
  end
  return table.concat(parts)
end

--: (path: string) -> string | nil
local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

--: (name: string, do_diff: boolean) -> boolean
local function run_one(name, do_diff)
  local derivation = derivations[name]
  if not derivation then
    io.stderr:write("no such derivation: " .. name .. "\n")
    return false
  end
  local generated = generate(derivation)
  if not do_diff then
    io.write(generated)
    return true
  end

  local repo_root = script_dir .. "/../.."
  local real_path = repo_root .. "/" .. derivation.real_path
  local real = read_file(real_path)
  if not real then
    io.stderr:write("cannot read real file: " .. real_path .. "\n")
    return false
  end

  if generated == real then
    print(name .. ": IDENTICAL (" .. #generated .. " bytes)")
    return true
  end

  print(name .. ": DIFFERS (generated " .. #generated .. " bytes, real " .. #real .. " bytes)")
  local gen_tmp = os.tmpname()
  local gf, open_err = io.open(gen_tmp, "w")
  if not gf then
    io.stderr:write("cannot open temp file: " .. tostring(open_err) .. "\n")
    return false
  end
  gf:write(generated)
  gf:close()
  os.execute("diff -u '" .. real_path .. "' '" .. gen_tmp .. "'")
  os.remove(gen_tmp)
  return false
end

--: () -> nil
local function main()
  local do_diff = false
  local target = nil
  for _, a in ipairs(arg) do
    if a == "--diff" then do_diff = true
    elseif a == "--all" then target = "--all"
    else target = a end
  end

  if target == "--all" or target == nil then
    local all_ok = true
    local names = {}
    for name in pairs(derivations) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
      local ok = run_one(name, true)
      all_ok = all_ok and ok
    end
    os.exit(all_ok and 0 or 1)
  else
    local ok = run_one(target, do_diff)
    os.exit(ok and 0 or 1)
  end
end

main()
