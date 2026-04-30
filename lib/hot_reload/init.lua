if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

-- Hot code reloading for development workflows.
-- Watches Lua modules for file changes and reloads them automatically.
-- Pure Lua implementation using `stat` via io.popen for mtime checks.

local M = {}

M._tier = "pure"

--:: watcher = { check: () -> { [integer]: string }, stop: () -> nil }

-- ---------------------------------------------------------------------------
-- File modification time
-- ---------------------------------------------------------------------------

-- Returns the modification time as a Unix timestamp (number), or nil.
-- Tries Linux `stat -c %Y` first, falls back to macOS `stat -f %m`.
--: (string) -> number | nil
function M.mtime(path)
  -- Try Linux stat first
  local f = io.popen("stat -c %Y " .. path .. " 2>/dev/null")
  if f then
    local s = f:read("*a")
    f:close()
    local t = tonumber(s)
    if t then return t end
  end
  -- Fall back to macOS stat
  local f2 = io.popen("stat -f %m " .. path .. " 2>/dev/null")
  if f2 then
    local s2 = f2:read("*a")
    f2:close()
    local t2 = tonumber(s2)
    if t2 then return t2 end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Watcher
-- ---------------------------------------------------------------------------

-- Creates a new hot-reload watcher.
-- opts.poll_interval: seconds between checks (default 1.0)
--: ({ poll_interval: number | nil } | nil) -> watcher
function M.watcher(opts)
  assert(opts and opts.time_fn, "watcher requires opts.time_fn")
  local w = {}

  w._time_fn = opts.time_fn

  -- poll interval in seconds
  w._poll_interval = opts.poll_interval or 1.0

  -- map: module_name -> { filepath, last_mtime }
  w._watched = {}

  -- ordered list of watched module names (for iteration stability)
  w._watch_order = {}

  -- callbacks
  w._reload_cbs = {}
  w._error_cbs  = {}

  -- state preservation: module_name -> key
  w._preserve_keys = {}

  -- dependency graph: module_name -> list of dependents
  w._dependents = {}

  -- stats
  w._stats = { watched = 0, reloaded_total = 0, errors = 0 }

  -- last check time
  w._last_check = 0

  -- ---------------------------------------------------------------------------
  -- watch
  -- ---------------------------------------------------------------------------

  -- Register a module to watch.
  -- module_name: e.g. "lib.mymodule"
  -- filepath: absolute or relative path to the Lua file
  function w:watch(module_name, filepath)
    if not self._watched[module_name] then
      self._watch_order[#self._watch_order + 1] = module_name
      self._stats.watched = self._stats.watched + 1
    end
    self._watched[module_name] = {
      filepath   = filepath,
      last_mtime = M.mtime(filepath),
    }
  end

  -- ---------------------------------------------------------------------------
  -- watch_dir
  -- ---------------------------------------------------------------------------

  -- Watch all matching files in a directory recursively.
  -- opts.pattern: Lua pattern to filter filenames (default "%.lua$")
  -- opts.on_change: callback(filepath) when a file changes (optional)
  function w:watch_dir(dir, dir_opts)
    dir_opts = dir_opts or {}
    local pattern    = dir_opts.pattern or "%.lua$"
    local on_change  = dir_opts.on_change

    -- Collect files via find
    local cmd = "find " .. dir .. " -type f 2>/dev/null"
    local f = io.popen(cmd)
    if not f then return end
    local files = {}
    for line in f:lines() do
      if line:match(pattern) then
        files[#files + 1] = line
      end
    end
    f:close()

    for _, filepath in ipairs(files) do
      -- Derive a pseudo module name from the filepath
      -- e.g. "./lib/foo/init.lua" -> "lib.foo"
      local mod_name = filepath
        :gsub("^%.?/", "")        -- strip leading ./ or /
        :gsub("%.lua$", "")       -- strip .lua extension
        :gsub("/init$", "")       -- strip /init
        :gsub("/", ".")           -- slashes to dots

      -- Store on_change callback in the watch entry
      self._watched[mod_name] = {
        filepath    = filepath,
        last_mtime  = M.mtime(filepath),
        on_change   = on_change,
        dir_watched = true,
      }
      if not self._watched[mod_name] then
        self._watch_order[#self._watch_order + 1] = mod_name
        self._stats.watched = self._stats.watched + 1
      end
      -- Ensure it's counted if new
      local already = false
      for _, n in ipairs(self._watch_order) do
        if n == mod_name then already = true; break end
      end
      if not already then
        self._watch_order[#self._watch_order + 1] = mod_name
        self._stats.watched = self._stats.watched + 1
      end
    end
  end

  -- ---------------------------------------------------------------------------
  -- check
  -- ---------------------------------------------------------------------------

  -- Check all watched modules for file changes.
  -- Returns an array of { module_name, filepath } for changed modules.
  -- Respects poll_interval: if called more frequently, may return empty table.
  function w:check()
    local now = self._time_fn()
    -- Allow check() to be called freely; rate-limit only auto_reload via _last_check
    local changed = {}
    for _, module_name in ipairs(self._watch_order) do
      local entry = self._watched[module_name]
      if entry then
        local mt = M.mtime(entry.filepath)
        if mt and entry.last_mtime and mt ~= entry.last_mtime then
          changed[#changed + 1] = { module_name = module_name, filepath = entry.filepath }
          entry.last_mtime = mt
          -- fire on_change if set (dir_watched)
          if entry.on_change then
            entry.on_change(entry.filepath)
          end
        end
      end
    end
    return changed
  end

  -- ---------------------------------------------------------------------------
  -- reload
  -- ---------------------------------------------------------------------------

  -- Reload a specific module.
  -- Returns true on success, or nil + error message on failure.
  function w:reload(module_name)
    -- Grab old module for state preservation and fallback
    local old_module = package.loaded[module_name]

    -- Save preserved state if configured
    local saved_state
    local pkey = self._preserve_keys[module_name]
    if pkey and old_module and type(old_module) == "table" then
      saved_state = old_module[pkey]
    end

    -- Unload the module
    package.loaded[module_name] = nil

    -- Reload
    local ok, result = pcall(require, module_name)

    if not ok then
      -- Restore old module on failure
      package.loaded[module_name] = old_module
      self._stats.errors = self._stats.errors + 1
      -- Fire error callbacks
      for _, cb in ipairs(self._error_cbs) do
        cb(module_name, result)
      end
      -- Fire reload callbacks with failure
      for _, cb in ipairs(self._reload_cbs) do
        cb(module_name, false, result)
      end
      return nil, result
    end

    -- Reload succeeded; restore preserved state
    local new_module = package.loaded[module_name]
    if saved_state ~= nil and new_module and type(new_module) == "table" then
      if type(new_module._init_hot_state) == "function" then
        new_module:_init_hot_state(saved_state)
      else
        new_module[pkey] = saved_state
      end
    end

    self._stats.reloaded_total = self._stats.reloaded_total + 1

    -- Fire reload callbacks
    for _, cb in ipairs(self._reload_cbs) do
      cb(module_name, true, nil)
    end

    return true
  end

  -- ---------------------------------------------------------------------------
  -- auto_reload
  -- ---------------------------------------------------------------------------

  -- Check for changed modules and reload them all.
  -- Intended to be called from a main loop.
  -- Respects poll_interval to avoid excessive stat() calls.
  function w:auto_reload()
    local now = self._time_fn()
    if now - self._last_check < self._poll_interval then
      return
    end
    self._last_check = now

    local changed = self:check()
    for _, item in ipairs(changed) do
      self:reload(item.module_name)
    end
  end

  -- ---------------------------------------------------------------------------
  -- on_reload / on_error
  -- ---------------------------------------------------------------------------

  -- Register a callback called after each reload attempt.
  -- cb(module_name, ok, err)
  function w:on_reload(cb)
    self._reload_cbs[#self._reload_cbs + 1] = cb
  end

  -- Register a callback called when a reload fails.
  -- cb(module_name, err)
  function w:on_error(cb)
    self._error_cbs[#self._error_cbs + 1] = cb
  end

  -- ---------------------------------------------------------------------------
  -- preserve_state
  -- ---------------------------------------------------------------------------

  -- Before reloading module_name, save module[key] and restore it afterwards.
  function w:preserve_state(module_name, key)
    self._preserve_keys[module_name] = key
  end

  -- ---------------------------------------------------------------------------
  -- dependents
  -- ---------------------------------------------------------------------------

  -- Register that `dependent` requires `module_name`.
  function w:register_dependency(module_name, dependent)
    if not self._dependents[module_name] then
      self._dependents[module_name] = {}
    end
    local deps = self._dependents[module_name]
    -- Avoid duplicates
    for _, d in ipairs(deps) do
      if d == dependent then return end
    end
    deps[#deps + 1] = dependent
  end

  -- Returns modules that require this one (must be pre-registered).
  function w:dependents(module_name)
    return self._dependents[module_name] or {}
  end

  -- ---------------------------------------------------------------------------
  -- stats
  -- ---------------------------------------------------------------------------

  -- Returns a summary table.
  function w:stats()
    return {
      watched        = self._stats.watched,
      reloaded_total = self._stats.reloaded_total,
      errors         = self._stats.errors,
    }
  end

  return w
end

return M
