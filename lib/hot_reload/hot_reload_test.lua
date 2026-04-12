if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T  = require("lib.test.assert")
local HR = require("lib.hot_reload")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Write content to a file path (overwrites).
local function write_file(path, content)
  local f = io.open(path, "w")
  if not f then error("cannot open " .. path) end
  f:write(content)
  f:close()
end

-- Delete a file.
local function rm(path)
  os.remove(path)
end

-- Sleep for n seconds (via os.execute with sleep).
local function sleep(n)
  os.execute("sleep " .. n)
end

-- Create a temp directory.
local function tmpdir()
  local d = os.tmpname()
  os.remove(d)            -- os.tmpname creates a file; we want a dir name
  os.execute("mkdir -p " .. d)
  return d
end

-- ---------------------------------------------------------------------------
-- HR.mtime
-- ---------------------------------------------------------------------------

T.describe("HR.mtime", function()
  T.it("returns nil for a missing file", function()
    local t = HR.mtime("/nonexistent/path/that/does/not/exist.lua")
    T.eq(t, nil)
  end)

  T.it("returns a number for an existing file", function()
    local path = os.tmpname()
    write_file(path, "-- temp\n")
    local t = HR.mtime(path)
    T.ok(type(t) == "number", "expected number, got " .. type(t))
    T.ok(t > 0, "mtime should be positive")
    rm(path)
  end)

  T.it("mtime changes after a write", function()
    local path = os.tmpname()
    write_file(path, "v1\n")
    local t1 = HR.mtime(path)
    -- touch the file with a 1-second-future mtime to ensure change
    os.execute("touch -m -d '+1 second' " .. path)
    local t2 = HR.mtime(path)
    T.ok(t2 ~= nil, "t2 should not be nil")
    T.ok(t2 >= t1, "t2 should be >= t1")
    rm(path)
  end)
end)

-- ---------------------------------------------------------------------------
-- HR._tier
-- ---------------------------------------------------------------------------

T.describe("HR._tier", function()
  T.it("is 'pure'", function()
    T.eq(HR._tier, "pure")
  end)
end)

-- ---------------------------------------------------------------------------
-- watcher creation
-- ---------------------------------------------------------------------------

T.describe("HR.watcher", function()
  T.it("creates a watcher with default poll_interval", function()
    local w = HR.watcher()
    T.ok(w ~= nil)
    T.eq(w._poll_interval, 1.0)
  end)

  T.it("accepts custom poll_interval", function()
    local w = HR.watcher({ poll_interval = 0.5 })
    T.eq(w._poll_interval, 0.5)
  end)

  T.it("starts with zero stats", function()
    local w = HR.watcher()
    local s = w:stats()
    T.eq(s.watched, 0)
    T.eq(s.reloaded_total, 0)
    T.eq(s.errors, 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- watcher:watch and check — no-change case
-- ---------------------------------------------------------------------------

T.describe("watcher:watch + check (no change)", function()
  T.it("watch registers a module", function()
    local path = os.tmpname()
    write_file(path, "return {}\n")
    local w = HR.watcher()
    w:watch("test.nochange", path)
    local s = w:stats()
    T.eq(s.watched, 1)
    rm(path)
  end)

  T.it("check returns empty table when file unchanged", function()
    local path = os.tmpname()
    write_file(path, "return {}\n")
    local w = HR.watcher()
    w:watch("test.nochange2", path)
    local changed = w:check()
    T.eq(#changed, 0)
    rm(path)
  end)
end)

-- ---------------------------------------------------------------------------
-- watcher:check — detects change
-- ---------------------------------------------------------------------------

T.describe("watcher:check (detects change)", function()
  T.it("returns changed entry after mtime bump", function()
    local path = os.tmpname()
    write_file(path, "return {}\n")
    local w = HR.watcher()
    w:watch("test.change", path)

    -- Confirm no change initially
    local c1 = w:check()
    T.eq(#c1, 0)

    -- Bump mtime
    os.execute("touch -m -d '+2 seconds' " .. path)
    local c2 = w:check()
    T.eq(#c2, 1)
    T.eq(c2[1].module_name, "test.change")
    T.eq(c2[1].filepath, path)

    -- After detecting, mtime is updated — next check should be clean
    local c3 = w:check()
    T.eq(#c3, 0)

    rm(path)
  end)

  T.it("detects changes for multiple modules independently", function()
    local p1 = os.tmpname()
    local p2 = os.tmpname()
    write_file(p1, "return {}\n")
    write_file(p2, "return {}\n")
    local w = HR.watcher()
    w:watch("test.multi1", p1)
    w:watch("test.multi2", p2)

    os.execute("touch -m -d '+2 seconds' " .. p1)
    local changed = w:check()
    T.eq(#changed, 1)
    T.eq(changed[1].module_name, "test.multi1")

    rm(p1)
    rm(p2)
  end)
end)

-- ---------------------------------------------------------------------------
-- watcher:reload
-- ---------------------------------------------------------------------------

T.describe("watcher:reload", function()
  T.it("clears package.loaded and re-requires the module", function()
    local path = os.tmpname() .. ".lua"
    -- The module name must resolve via package.path; we write to a temp path
    -- and register a loader.
    local mod_name = "hot_reload_tmp_v1_" .. tostring(math.random(1e9))
    write_file(path, "return { value = 1 }\n")

    -- Register a custom loader for this temp module
    local loader_path = path
    table.insert(package.loaders, 1, function(name)
      if name == mod_name then
        return function()
          local f = assert(loadfile(loader_path))
          return f()
        end
      end
    end)

    -- First require
    local m1 = require(mod_name)
    T.eq(m1.value, 1)

    -- Update the file
    write_file(path, "return { value = 2 }\n")

    -- Reload via watcher
    local w = HR.watcher()
    w:watch(mod_name, path)
    local ok, err = w:reload(mod_name)
    T.ok(ok, "reload should succeed: " .. tostring(err))

    local m2 = require(mod_name)
    T.eq(m2.value, 2)

    -- Stats updated
    local s = w:stats()
    T.eq(s.reloaded_total, 1)
    T.eq(s.errors, 0)

    -- Cleanup
    package.loaded[mod_name] = nil
    table.remove(package.loaders, 1)
    rm(path)
  end)

  T.it("returns nil+err and restores old module on syntax error", function()
    local path = os.tmpname() .. ".lua"
    local mod_name = "hot_reload_tmp_err_" .. tostring(math.random(1e9))
    write_file(path, "return { value = 42 }\n")

    table.insert(package.loaders, 1, function(name)
      if name == mod_name then
        return function()
          local f = assert(loadfile(path))
          return f()
        end
      end
    end)

    local m1 = require(mod_name)
    T.eq(m1.value, 42)

    -- Break the module
    write_file(path, "this is not valid lua !@#\n")

    local w = HR.watcher()
    w:watch(mod_name, path)
    local ok, err = w:reload(mod_name)
    T.fail(ok, "reload should fail")
    T.ok(err ~= nil, "err should be non-nil")

    -- Old module should still be in package.loaded
    local restored = package.loaded[mod_name]
    T.ok(restored ~= nil, "old module should be restored")
    T.eq(restored.value, 42)

    -- Stats
    local s = w:stats()
    T.eq(s.errors, 1)

    package.loaded[mod_name] = nil
    table.remove(package.loaders, 1)
    rm(path)
  end)
end)

-- ---------------------------------------------------------------------------
-- on_reload callback
-- ---------------------------------------------------------------------------

T.describe("on_reload callback", function()
  T.it("is called after a successful reload", function()
    local path = os.tmpname() .. ".lua"
    local mod_name = "hot_reload_cb_ok_" .. tostring(math.random(1e9))
    write_file(path, "return { v = 10 }\n")

    table.insert(package.loaders, 1, function(name)
      if name == mod_name then
        return function() return (loadfile(path))() end
      end
    end)
    require(mod_name)

    local calls = {}
    local w = HR.watcher()
    w:watch(mod_name, path)
    w:on_reload(function(mname, ok, err)
      calls[#calls + 1] = { mname = mname, ok = ok, err = err }
    end)

    w:reload(mod_name)

    T.eq(#calls, 1)
    T.eq(calls[1].mname, mod_name)
    T.ok(calls[1].ok)
    T.eq(calls[1].err, nil)

    package.loaded[mod_name] = nil
    table.remove(package.loaders, 1)
    rm(path)
  end)

  T.it("is called with ok=false on error", function()
    local path = os.tmpname() .. ".lua"
    local mod_name = "hot_reload_cb_fail_" .. tostring(math.random(1e9))
    write_file(path, "return { v = 1 }\n")

    table.insert(package.loaders, 1, function(name)
      if name == mod_name then
        return function() return (loadfile(path))() end
      end
    end)
    require(mod_name)

    -- Break it
    write_file(path, "invalid !! syntax\n")

    local calls = {}
    local w = HR.watcher()
    w:watch(mod_name, path)
    w:on_reload(function(mname, ok, err)
      calls[#calls + 1] = { mname = mname, ok = ok, err = err }
    end)

    w:reload(mod_name)
    T.eq(#calls, 1)
    T.fail(calls[1].ok)
    T.ok(calls[1].err ~= nil)

    package.loaded[mod_name] = nil
    table.remove(package.loaders, 1)
    rm(path)
  end)
end)

-- ---------------------------------------------------------------------------
-- on_error callback
-- ---------------------------------------------------------------------------

T.describe("on_error callback", function()
  T.it("is called when reload fails", function()
    local path = os.tmpname() .. ".lua"
    local mod_name = "hot_reload_errcb_" .. tostring(math.random(1e9))
    write_file(path, "return {}\n")

    table.insert(package.loaders, 1, function(name)
      if name == mod_name then
        return function() return (loadfile(path))() end
      end
    end)
    require(mod_name)

    write_file(path, "bad bad bad\n")

    local errs = {}
    local w = HR.watcher()
    w:watch(mod_name, path)
    w:on_error(function(mname, err)
      errs[#errs + 1] = { mname = mname, err = err }
    end)

    w:reload(mod_name)
    T.eq(#errs, 1)
    T.eq(errs[1].mname, mod_name)
    T.ok(errs[1].err ~= nil)

    package.loaded[mod_name] = nil
    table.remove(package.loaders, 1)
    rm(path)
  end)

  T.it("is NOT called on success", function()
    local path = os.tmpname() .. ".lua"
    local mod_name = "hot_reload_errcb_ok_" .. tostring(math.random(1e9))
    write_file(path, "return { x = 1 }\n")

    table.insert(package.loaders, 1, function(name)
      if name == mod_name then
        return function() return (loadfile(path))() end
      end
    end)
    require(mod_name)

    local errs = {}
    local w = HR.watcher()
    w:watch(mod_name, path)
    w:on_error(function(mname, err)
      errs[#errs + 1] = err
    end)

    w:reload(mod_name)
    T.eq(#errs, 0)

    package.loaded[mod_name] = nil
    table.remove(package.loaders, 1)
    rm(path)
  end)
end)

-- ---------------------------------------------------------------------------
-- preserve_state
-- ---------------------------------------------------------------------------

T.describe("preserve_state", function()
  T.it("restores _hot_state via key after reload", function()
    local path = os.tmpname() .. ".lua"
    local mod_name = "hot_reload_state_" .. tostring(math.random(1e9))
    write_file(path, "return { value = 1, _hot_state = nil }\n")

    table.insert(package.loaders, 1, function(name)
      if name == mod_name then
        return function() return (loadfile(path))() end
      end
    end)

    local m1 = require(mod_name)
    -- Set a hot state on the live module
    m1._hot_state = { counter = 99 }

    local w = HR.watcher()
    w:watch(mod_name, path)
    w:preserve_state(mod_name, "_hot_state")

    -- Update the module (same _hot_state field in returned table, but value changed)
    write_file(path, "return { value = 2, _hot_state = nil }\n")

    local ok, err = w:reload(mod_name)
    T.ok(ok, tostring(err))

    local m2 = package.loaded[mod_name]
    T.ok(m2 ~= nil)
    T.eq(m2.value, 2)
    -- State should be restored
    T.ok(m2._hot_state ~= nil, "hot state should be preserved")
    T.eq(m2._hot_state.counter, 99)

    package.loaded[mod_name] = nil
    table.remove(package.loaders, 1)
    rm(path)
  end)

  T.it("calls _init_hot_state if present", function()
    local path = os.tmpname() .. ".lua"
    local mod_name = "hot_reload_initstate_" .. tostring(math.random(1e9))

    -- First version: plain module
    write_file(path, "return { value = 1, _hot_state = nil }\n")

    table.insert(package.loaders, 1, function(name)
      if name == mod_name then
        return function() return (loadfile(path))() end
      end
    end)

    local m1 = require(mod_name)
    m1._hot_state = { x = 7 }

    -- Second version: has _init_hot_state
    write_file(path, [[
local M = {}
M.value = 2
M._hot_state = nil
M._received = nil
function M:_init_hot_state(state)
  self._received = state
  self._hot_state = state
end
return M
]])

    local w = HR.watcher()
    w:watch(mod_name, path)
    w:preserve_state(mod_name, "_hot_state")

    local ok, err = w:reload(mod_name)
    T.ok(ok, tostring(err))

    local m2 = package.loaded[mod_name]
    T.ok(m2 ~= nil)
    T.eq(m2.value, 2)
    T.ok(m2._received ~= nil, "_init_hot_state should have been called")
    T.eq(m2._received.x, 7)

    package.loaded[mod_name] = nil
    table.remove(package.loaders, 1)
    rm(path)
  end)
end)

-- ---------------------------------------------------------------------------
-- auto_reload
-- ---------------------------------------------------------------------------

T.describe("auto_reload", function()
  T.it("reloads changed modules automatically", function()
    local path = os.tmpname() .. ".lua"
    local mod_name = "hot_reload_auto_" .. tostring(math.random(1e9))
    write_file(path, "return { ver = 1 }\n")

    table.insert(package.loaders, 1, function(name)
      if name == mod_name then
        return function() return (loadfile(path))() end
      end
    end)
    require(mod_name)

    local w = HR.watcher({ poll_interval = 0 })
    w:watch(mod_name, path)

    -- Write new content first, then bump mtime so check() detects change
    write_file(path, "return { ver = 2 }\n")
    os.execute("touch -m -d '+2 seconds' " .. path)

    w:auto_reload()

    local m2 = package.loaded[mod_name]
    T.ok(m2 ~= nil)
    T.eq(m2.ver, 2)

    local s = w:stats()
    T.eq(s.reloaded_total, 1)

    package.loaded[mod_name] = nil
    table.remove(package.loaders, 1)
    rm(path)
  end)

  T.it("respects poll_interval (skips when called too soon)", function()
    local path = os.tmpname() .. ".lua"
    local mod_name = "hot_reload_poll_" .. tostring(math.random(1e9))
    write_file(path, "return { ver = 1 }\n")

    table.insert(package.loaders, 1, function(name)
      if name == mod_name then
        return function() return (loadfile(path))() end
      end
    end)
    require(mod_name)

    -- Long poll interval so second call should skip
    local w = HR.watcher({ poll_interval = 9999 })
    w:watch(mod_name, path)

    -- First call processes
    write_file(path, "return { ver = 2 }\n")
    os.execute("touch -m -d '+2 seconds' " .. path)
    w:auto_reload()
    T.eq(w:stats().reloaded_total, 1)

    -- Touch again; second call should be skipped due to poll_interval
    write_file(path, "return { ver = 3 }\n")
    os.execute("touch -m -d '+4 seconds' " .. path)
    w:auto_reload()
    -- Should still be 1 — poll interval blocked the second check
    T.eq(w:stats().reloaded_total, 1)

    package.loaded[mod_name] = nil
    table.remove(package.loaders, 1)
    rm(path)
  end)
end)

-- ---------------------------------------------------------------------------
-- stats
-- ---------------------------------------------------------------------------

T.describe("stats", function()
  T.it("tracks watched count correctly", function()
    local p1 = os.tmpname()
    local p2 = os.tmpname()
    write_file(p1, "")
    write_file(p2, "")
    local w = HR.watcher()
    T.eq(w:stats().watched, 0)
    w:watch("mod.a", p1)
    T.eq(w:stats().watched, 1)
    w:watch("mod.b", p2)
    T.eq(w:stats().watched, 2)
    -- Re-watching same module should not increase count
    w:watch("mod.a", p1)
    T.eq(w:stats().watched, 2)
    rm(p1)
    rm(p2)
  end)

  T.it("reloaded_total increments per reload", function()
    local path = os.tmpname() .. ".lua"
    local mod_name = "hot_reload_stats_" .. tostring(math.random(1e9))
    write_file(path, "return {}\n")

    table.insert(package.loaders, 1, function(name)
      if name == mod_name then
        return function() return (loadfile(path))() end
      end
    end)
    require(mod_name)

    local w = HR.watcher()
    w:watch(mod_name, path)
    w:reload(mod_name)
    w:reload(mod_name)
    T.eq(w:stats().reloaded_total, 2)

    package.loaded[mod_name] = nil
    table.remove(package.loaders, 1)
    rm(path)
  end)
end)

-- ---------------------------------------------------------------------------
-- dependents
-- ---------------------------------------------------------------------------

T.describe("dependents", function()
  T.it("returns empty list for unknown module", function()
    local w = HR.watcher()
    local d = w:dependents("lib.nothing")
    T.eq(type(d), "table")
    T.eq(#d, 0)
  end)

  T.it("register_dependency and dependents", function()
    local w = HR.watcher()
    w:register_dependency("lib.core", "lib.app")
    w:register_dependency("lib.core", "lib.server")
    local d = w:dependents("lib.core")
    T.eq(#d, 2)
    T.eq(d[1], "lib.app")
    T.eq(d[2], "lib.server")
  end)

  T.it("no duplicate dependents", function()
    local w = HR.watcher()
    w:register_dependency("lib.x", "lib.y")
    w:register_dependency("lib.x", "lib.y")
    T.eq(#w:dependents("lib.x"), 1)
  end)
end)

-- ---------------------------------------------------------------------------
-- watch_dir
-- ---------------------------------------------------------------------------

T.describe("watch_dir", function()
  T.it("watches lua files in a directory", function()
    local dir = tmpdir()
    write_file(dir .. "/a.lua", "return {}\n")
    write_file(dir .. "/b.lua", "return {}\n")
    write_file(dir .. "/c.txt", "not lua\n")  -- should be ignored

    local w = HR.watcher()
    w:watch_dir(dir, { pattern = "%.lua$" })

    -- Should have found 2 lua files
    T.ok(w:stats().watched >= 2, "expected at least 2 watched")

    -- No changes initially
    local changed = w:check()
    T.eq(#changed, 0)

    os.execute("rm -rf " .. dir)
  end)

  T.it("on_change callback fires for changed file in watched dir", function()
    local dir = tmpdir()
    local apath = dir .. "/watched.lua"
    write_file(apath, "return {}\n")

    local fired = {}
    local w = HR.watcher()
    w:watch_dir(dir, {
      pattern   = "%.lua$",
      on_change = function(fp) fired[#fired + 1] = fp end,
    })

    -- Bump mtime of the file
    os.execute("touch -m -d '+2 seconds' " .. apath)
    w:check()

    T.eq(#fired, 1)
    T.eq(fired[1], apath)

    os.execute("rm -rf " .. dir)
  end)
end)


