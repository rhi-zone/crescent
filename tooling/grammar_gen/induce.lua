#!/usr/bin/env luajit
-- tooling/grammar_gen/induce.lua
--
-- CLI entrypoint: reads a set of files from disk (the one place in this
-- tool that touches io.* directly — bootstrapping, same pattern as
-- generate.lua's read_file), runs grammar induction (tooling/grammar_gen/
-- discover.lua) over them, and prints a report.
--
-- Usage:
--   luajit induce.lua <file...>              -- induce over exactly these files
--   luajit induce.lua --dispatchers          -- the 5 ground-truth files
--   luajit induce.lua --lib [--limit N]      -- whole lib/ tree (excludes
--                                                vendored/non-Lua material)
--   Add --verbose to print every slot's alternatives and every rule's
--   occurrences (default: summary counts + the top slots by reuse).

local script_dir = (arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = script_dir .. "/../../?.lua;" .. package.path

local discover = require("tooling.grammar_gen.discover")

--: (path: string) -> string | nil
local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

-- Directories under lib/ known to contain vendored/generated/non-Lua
-- material that chokes or pollutes structural analysis (minified JS,
-- non-Lua sources bundled alongside a Lua wrapper, etc).
local EXCLUDE_SUBSTR = {
  "/platform/apps/terminal_mux/static/",
}

--: (path: string) -> boolean
local function excluded(path)
  for _, sub in ipairs(EXCLUDE_SUBSTR) do
    if path:find(sub, 1, true) then return true end
  end
  return false
end

--: () -> { [integer]: string }
local function list_lib_lua_files()
  local repo_root = script_dir .. "/../.."
  local p = io.popen('find "' .. repo_root .. '/lib" -name "*.lua" -type f')
  local paths = {} --: { [integer]: string }
  if not p then return paths end
  for line in p:lines() do
    if line and not excluded(line) then paths[#paths + 1] = line end
  end
  p:close()
  table.sort(paths, function(a, b) return a < b end)
  return paths
end

local DISPATCHERS = {
  "lib/compress/init.lua",
  "lib/crypto/init.lua",
  "lib/format/json/init.lua",
  "lib/encode/base64/init.lua",
  "lib/regex/init.lua",
}

-- These mirror discover.lua's Slot/Rule/Occurrence shapes (see that file's
-- header for why this is a restated duplicate rather than an imported
-- name: crescent's checker has no cross-file named-type-sharing path for
-- locally-defined module types beyond structural matching, which this
-- restatement relies on).
--:: Occurrence = { fp: string, path: string, line: number, holes: { [integer]: string }, summary: string }
--:: Rule = { fp: string, count: number, occurrences: { [integer]: Occurrence } }
--:: Alternative = { occurrences: { [integer]: Occurrence } }
--:: Slot = { fp: string, count: number, alternatives: { [integer]: Alternative } }
--:: Residue = { fp: string, occurrence: Occurrence }
--:: ClusterResult = { rules: { [integer]: Rule }, slots: { [integer]: Slot }, residue: { [integer]: Residue } }

-- TYPECHECKER WORKAROUND, two distinct gaps stacked:
-- (1) this file's earlier `table.sort(paths, ...)` call (list_lib_lua_files,
--     over a `{ [integer]: string }`) appears to pin `table.sort`'s
--     declared `<V>(t: { [integer]: V, ... }, ...)` generic to `V = string`
--     for the rest of the file — a later, textually-distinct call with a
--     `{ [integer]: Slot }` / `{ [integer]: Rule }` argument is then
--     rejected as "cannot assign `{...}` to `string`", i.e. the same
--     generic function symbol seems to get monomorphized once rather than
--     re-generalized per call site.
-- (2) passing `result.slots`/`result.rules` into a helper function typed
--     with a looser parameter shape (e.g. `{ count: number, ... }`, to sort
--     generically by a shared field) degrades the ARGUMENT's own static
--     type at the call site for its remaining lifetime in the caller, so a
--     later read of `slot.alternatives`/`slot.fp` sees only the fields the
--     helper's parameter type mentioned.
-- Neither repro is isolated to a standalone minimal case yet; recorded
-- here as found. Worked around by inlining the sort at each call site
-- (never passing result.slots/result.rules through another function
-- boundary) instead of a shared sort_by_count_desc helper. Revert to a
-- shared generic sort helper (or plain `table.sort(..., comparator)`) once
-- either gap resolves. See TODO.md.
--: (label: string, result: ClusterResult, verbose: boolean) -> nil
local function print_cluster_result(label, result, verbose)
  print(string.format("-- %s: %d rules, %d slots, %d residue", label,
    #result.rules, #result.slots, #result.residue))
  -- Build fresh sorted-by-count-desc lists (insertion into a new array)
  -- rather than sorting result.slots/result.rules in place — swapping
  -- elements of the original arrays in a loop was enough to make the
  -- checker lose track of their element type afterward (see the workaround
  -- note above; a fresh array sidesteps it entirely).
  local sorted_slots = {} --: { [integer]: Slot }
  for _, slot in ipairs(result.slots) do
    local pos = #sorted_slots + 1
    for i = 1, #sorted_slots do
      if sorted_slots[i].count < slot.count then pos = i; break end
    end
    for i = #sorted_slots + 1, pos + 1, -1 do sorted_slots[i] = sorted_slots[i - 1] end
    sorted_slots[pos] = slot
  end
  local sorted_rules = {} --: { [integer]: Rule }
  for _, rule in ipairs(result.rules) do
    local pos = #sorted_rules + 1
    for i = 1, #sorted_rules do
      if sorted_rules[i].count < rule.count then pos = i; break end
    end
    for i = #sorted_rules + 1, pos + 1, -1 do sorted_rules[i] = sorted_rules[i - 1] end
    sorted_rules[pos] = rule
  end

  local top_n = verbose and #sorted_slots or math.min(10, #sorted_slots)
  for i = 1, top_n do
    local slot = sorted_slots[i]
    print(string.format("  SLOT (%d occurrences, %d alternatives): %s",
      slot.count, #slot.alternatives, slot.fp))
    for ai, alt in ipairs(slot.alternatives) do
      local first = alt.occurrences[1]
      print(string.format("    alt %d (%dx): %s:%d  [%s]",
        ai, #alt.occurrences, first.path, first.line, table.concat(first.holes, " | ")))
    end
  end
  local top_r = verbose and #sorted_rules or math.min(5, #sorted_rules)
  for i = 1, top_r do
    local rule = sorted_rules[i]
    local first = rule.occurrences[1]
    print(string.format("  RULE (%d occurrences, zero variance): %s  e.g. %s:%d",
      rule.count, rule.fp, first.path, first.line))
  end
end

--: () -> nil
local function main()
  local verbose = false
  local mode = nil
  local files = {}
  local limit = nil --: number | nil
  for _, a in ipairs(arg) do
    if a == "--verbose" then verbose = true
    elseif a == "--dispatchers" then mode = "dispatchers"
    elseif a == "--lib" then mode = "lib"
    elseif a:match("^--limit=") then limit = tonumber(a:match("^--limit=(%d+)"))
    else files[#files + 1] = a
    end
  end

  local paths
  if mode == "dispatchers" then
    paths = DISPATCHERS
  elseif mode == "lib" then
    paths = list_lib_lua_files()
    if limit then
      local trimmed = {}
      for i = 1, math.min(limit, #paths) do trimmed[i] = paths[i] end
      paths = trimmed
    end
  else
    paths = files
  end

  if #paths == 0 then
    io.stderr:write("no input files (use --dispatchers, --lib, or list files)\n")
    os.exit(1)
  end

  local corpus = {}
  local unreadable = {}
  for _, path in ipairs(paths) do
    local src = read_file(path)
    if src then
      corpus[#corpus + 1] = { path = path, source = src }
    else
      unreadable[#unreadable + 1] = path
    end
  end

  local t0 = os.clock()
  local result, unparsed = discover.induce(corpus)
  local elapsed = os.clock() - t0

  print(string.format("files: %d read, %d unreadable, %d failed to parse, %.2fs elapsed",
    #corpus, #unreadable, #unparsed, elapsed))
  if #unparsed > 0 then
    print("-- unparsed files:")
    for _, u in ipairs(unparsed) do
      print("  " .. u.path .. ": " .. u.err)
    end
  end
  print()
  print_cluster_result("single-statement", result.single, verbose)
  print()
  for w = 2, 5 do
    print_cluster_result(w .. "-statement windows", result.windows[w], verbose)
    print()
  end
end

main()
