-- lib/find_cli/init.lua
-- Filesystem search library with a predicate DSL.
-- walk_fn capability must be injected (matches lib.fs.dir_list semantics).
-- No direct use of os, io, or global side-effect modules.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- ---------------------------------------------------------------------------
-- Unit helpers (constructors for size/time thresholds)
-- ---------------------------------------------------------------------------

-- Return n bytes unchanged (identity).
--: (number) -> number
M.b = function(n) return n end

local KIB = 2^10
-- Return n kibibytes as bytes.
--: (number) -> number
M.kib = function(n) return n * KIB end

local MIB = 2^20
-- Return n mebibytes as bytes.
--: (number) -> number
M.mib = function(n) return n * MIB end

local GIB = 2^30
-- Return n gibibytes as bytes.
--: (number) -> number
M.gib = function(n) return n * GIB end

local TIB = 2^40
-- Return n tebibytes as bytes.
--: (number) -> number
M.tib = function(n) return n * TIB end

local EIB = 2^50
-- Return n exbibytes as bytes.
--: (number) -> number
M.eib = function(n) return n * EIB end

local KB = 10^3
-- Return n kilobytes (decimal) as bytes.
--: (number) -> number
M.kb = function(n) return n * KB end

local MB = 10^6
-- Return n megabytes (decimal) as bytes.
--: (number) -> number
M.mb = function(n) return n * MB end

local GB = 10^9
-- Return n gigabytes (decimal) as bytes.
--: (number) -> number
M.gb = function(n) return n * GB end

local TB = 10^12
-- Return n terabytes (decimal) as bytes.
--: (number) -> number
M.tb = function(n) return n * TB end

local EB = 10^15
-- Return n exabytes (decimal) as bytes.
--: (number) -> number
M.eb = function(n) return n * EB end

-- Return n seconds unchanged.
--: (number) -> number
M.sec = function(n) return n end

local MIN = 60
-- Return n minutes as seconds.
--: (number) -> number
M.min = function(n) return n * MIN end

local HR = 3600
-- Return n hours as seconds.
--: (number) -> number
M.hr = function(n) return n * HR end

local DAY = 86400
-- Return n days as seconds.
--: (number) -> number
M.day = function(n) return n * DAY end

local MONTH = 30 * 86400
-- Return n months (30 days) as seconds.
--: (number) -> number
M.month = function(n) return n * MONTH end

local YEAR = math.floor(365.25 * 86400)
-- Return n years (365.25 days) as seconds.
--: (number) -> number
M.year = function(n) return n * YEAR end

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

--:: find_file_info = { name: string, path: string, is_dir: boolean, is_file: boolean, type: string, size: number | nil, created: number | nil, modified: number | nil, age: number | nil, modified_age: number | nil }

-- A predicate receives a find_file_info and returns (matched, action?).
-- action "stop" halts traversal; "skip" skips descending into the directory.
--:: find_predicate = (info: find_file_info) -> (boolean, ("stop" | "skip") | nil)

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Walk the directory tree rooted at path, calling predicate for each entry.
-- Returns a list of matching paths (strings).
--
-- walk_fn(path) must return (iter, state) where iter yields find_file_info
-- tables (compatible with lib.fs.dir_list).
--
-- time_fn() must return the current Unix timestamp as a number (seconds).
--
--: (string, ({ name: string, path: string, is_dir: boolean, is_file: boolean, type: string, size: number | nil, created: number | nil, modified: number | nil, age: number | nil, modified_age: number | nil }) -> (boolean, ("stop" | "skip") | nil), (string) -> (((unknown) -> unknown), unknown), () -> number) -> { [integer]: string }
M.find = function(path, predicate, walk_fn, time_fn)
  local results = {} --: { [integer]: string }
  local stopped = false

  local function process(dir_path)
    if stopped then return end
    local iter, state = walk_fn(dir_path)
    if not iter then return end
    local now = time_fn()
    while true do
      local entry = iter(state) --[[:! find_file_info | nil]]
      if not entry then break end
      entry.age          = now - (entry.created  or now)
      entry.modified_age = now - (entry.modified or now)
      entry.is_file = not entry.is_dir
      if entry.is_dir then
        entry.type = "directory"
      else
        entry.type = "file"
      end
      local ok, action = predicate(entry)
      if ok then results[#results + 1] = entry.path end
      if action == "stop" then stopped = true; return end
      if entry.is_dir and action ~= "skip" then
        process(entry.path)
        if stopped then return end
      end
    end
  end

  process(path)
  return results
end

-- Return a predicate that matches entries whose name matches the Lua pattern.
--: (string) -> find_predicate
M.name = function(pattern)
  --: (find_file_info) -> (boolean, ("stop" | "skip") | nil)
  return function(info)
    return info.name:find(pattern) ~= nil, nil
  end
end

-- Return a predicate that matches only files (not directories).
--: () -> find_predicate
M.files_only = function()
  --: (find_file_info) -> (boolean, ("stop" | "skip") | nil)
  return function(info)
    return info.is_file, nil
  end
end

-- Return a predicate that matches only directories.
--: () -> find_predicate
M.dirs_only = function()
  --: (find_file_info) -> (boolean, ("stop" | "skip") | nil)
  return function(info)
    return info.is_dir, nil
  end
end

-- Return a predicate that matches files larger than n bytes.
--: (number) -> find_predicate
M.larger_than = function(n)
  --: (find_file_info) -> (boolean, ("stop" | "skip") | nil)
  return function(info)
    return (info.size or 0) > n, nil
  end
end

-- Return a predicate that matches files smaller than n bytes.
--: (number) -> find_predicate
M.smaller_than = function(n)
  --: (find_file_info) -> (boolean, ("stop" | "skip") | nil)
  return function(info)
    return (info.size or 0) < n, nil
  end
end

-- Return a predicate that matches entries newer than t seconds old.
--: (number) -> find_predicate
M.newer_than = function(t)
  --: (find_file_info) -> (boolean, ("stop" | "skip") | nil)
  return function(info)
    return (info.age or 0) < t, nil
  end
end

-- Return a predicate that matches entries older than t seconds old.
--: (number) -> find_predicate
M.older_than = function(t)
  --: (find_file_info) -> (boolean, ("stop" | "skip") | nil)
  return function(info)
    return (info.age or 0) > t, nil
  end
end

-- Combine two predicates with logical AND.
--: (find_predicate, find_predicate) -> find_predicate
M.both = function(a, b)
  --: (find_file_info) -> (boolean, ("stop" | "skip") | nil)
  return function(info)
    local ok_a, act_a = a(info)
    local ok_b, act_b = b(info)
    -- act_a takes priority; if nil, use act_b
    local action = act_a or act_b --[[:! ("stop" | "skip") | nil]]
    return (ok_a and ok_b) == true, action
  end
end

-- Combine two predicates with logical OR.
--: (find_predicate, find_predicate) -> find_predicate
M.either = function(a, b)
  --: (find_file_info) -> (boolean, ("stop" | "skip") | nil)
  return function(info)
    local ok_a, act_a = a(info)
    local ok_b, act_b = b(info)
    local action = act_a or act_b --[[:! ("stop" | "skip") | nil]]
    return ok_a or ok_b, action
  end
end

-- Negate a predicate (action is still propagated).
--: (find_predicate) -> find_predicate
M.negate = function(pred)
  --: (find_file_info) -> (boolean, ("stop" | "skip") | nil)
  return function(info)
    local ok, action = pred(info)
    return not ok, action
  end
end

return M
