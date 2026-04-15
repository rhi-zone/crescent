-- lib/task_runner/init.lua
-- Makefile-inspired task runner with dependency resolution and topological scheduling.
-- Sequential by default; parallel execution is injectable via executor option.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ── Internal helpers ───────────────────────────────────────────────────────────

-- Topological sort via iterative DFS. Returns ordered list or (nil, errmsg) on cycle.
local function topo_sort(tasks, roots)
  -- roots: list of task names to include (and their transitive deps)
  local order = {}
  local visited = {}   -- "done"
  local in_stack = {}  -- cycle detection

  local function visit(name)
    if visited[name] then return nil end
    if in_stack[name] then
      return "cycle detected involving task: " .. name
    end
    local def = tasks[name]
    if not def then
      return "unknown task: " .. name
    end
    in_stack[name] = true
    if def.deps then
      for _, dep in ipairs(def.deps) do
        local err = visit(dep)
        if err then return err end
      end
    end
    in_stack[name] = nil
    visited[name] = true
    order[#order + 1] = name
    return nil
  end

  for _, name in ipairs(roots) do
    local err = visit(name)
    if err then return nil, err end
  end
  return order
end

-- Collect all task names (for run_all).
local function all_task_names(tasks)
  local names = {}
  for name in pairs(tasks) do
    names[#names + 1] = name
  end
  -- Sort for deterministic ordering.
  table.sort(names)
  return names
end

-- ── Runner constructor ─────────────────────────────────────────────────────────

function M.new(opts)
  opts = opts or {}
  local runner = {
    _tasks    = {},   -- name -> task def
    _hooks    = {},   -- event -> list of callbacks
    _executor = opts.executor,  -- optional parallel executor
    _log_fn   = opts.log_fn or error("task_runner: opts.log_fn function is required"),
  }

  -- ── task(name, def) ──────────────────────────────────────────────────────────
  function runner:task(name, def)
    if type(name) ~= "string" or name == "" then
      return nil, "task name must be a non-empty string"
    end
    def = def or {}
    self._tasks[name] = {
      desc    = def.desc,
      deps    = def.deps or {},
      run     = def.run,
      once    = def.once,
      timeout = def.timeout,
      tags    = def.tags or {},
    }
    return self
  end

  -- ── on(event, fn) ───────────────────────────────────────────────────────────
  function runner:on(event, fn)
    if not self._hooks[event] then self._hooks[event] = {} end
    local hooks = self._hooks[event]
    hooks[#hooks + 1] = fn
    return self
  end

  local function fire(runner_, event, ...)
    local hooks = runner_._hooks[event]
    if not hooks then return end
    for _, fn in ipairs(hooks) do
      fn(...)
    end
  end

  -- ── validate() ──────────────────────────────────────────────────────────────
  function runner:validate()
    local names = all_task_names(self._tasks)
    local _, err = topo_sort(self._tasks, names)
    if err then return nil, err end
    return true
  end

  -- ── plan(name_or_names) ─────────────────────────────────────────────────────
  function runner:plan(name_or_names)
    local roots
    if type(name_or_names) == "string" then
      roots = {name_or_names}
    else
      roots = name_or_names
    end
    local order, err = topo_sort(self._tasks, roots)
    if not order then return nil, err end
    return order
  end

  -- ── Internal: execute an ordered list, skipping already-done tasks ───────────
  local function execute_plan(runner_, order, results, done_set)
    for _, name in ipairs(order) do
      if done_set[name] then
        -- already ran (shared dep or once-flagged)
      else
        local def = runner_._tasks[name]
        local ctx = {
          _name    = name,
          _runner  = runner_,
          _results = results,
          log = function(self, msg)
            runner_._log_fn(self._name, msg)
          end,
          result = function(self, dep_name)
            local r = self._results[dep_name]
            if not r then return nil end
            return r.value
          end,
        }

        fire(runner_, "task:start", name)
        local t0 = os.clock()
        local ok, value_or_err

        if def.run then
          ok, value_or_err = pcall(def.run, ctx)
        else
          -- No run function: vacuous success.
          ok, value_or_err = true, true
        end

        local duration_ms = math.floor((os.clock() - t0) * 1000 + 0.5)

        if ok then
          local result = { ok = true, value = value_or_err, duration_ms = duration_ms }
          results[name] = result
          done_set[name] = true
          fire(runner_, "task:done", name, result)
        else
          -- value_or_err is the error message from pcall
          local result = { ok = false, err = tostring(value_or_err), duration_ms = duration_ms }
          results[name] = result
          done_set[name] = true
          fire(runner_, "task:error", name, tostring(value_or_err))
          -- Stop: dependents cannot run if a dep failed.
          -- We return here; remaining tasks in the plan that depend on this
          -- will be absent from results (caller can detect).
          return nil, "task '" .. name .. "' failed: " .. tostring(value_or_err), name
        end
      end
    end
    return results
  end

  -- ── run(name_or_names) ───────────────────────────────────────────────────────
  function runner:run(name_or_names)
    local roots
    if type(name_or_names) == "string" then
      roots = {name_or_names}
    else
      roots = name_or_names
    end

    local order, err = topo_sort(self._tasks, roots)
    if not order then return nil, err end

    local results  = {}
    local done_set = {}

    local res, run_err = execute_plan(self, order, results, done_set)
    if not res then
      -- Return partial results plus error.
      return results, run_err
    end
    return results
  end

  -- ── run_all() ───────────────────────────────────────────────────────────────
  function runner:run_all()
    local names = all_task_names(self._tasks)
    return self:run(names)
  end

  -- ── run_tagged(tag) ─────────────────────────────────────────────────────────
  function runner:run_tagged(tag)
    local tagged = {}
    for name, def in pairs(self._tasks) do
      for _, t in ipairs(def.tags) do
        if t == tag then
          tagged[#tagged + 1] = name
          break
        end
      end
    end
    table.sort(tagged)
    if #tagged == 0 then
      return {}, nil
    end
    return self:run(tagged)
  end

  -- ── watch(name, opts) ───────────────────────────────────────────────────────
  -- Watch mode: re-run task when files change.
  -- Requires an injectable watcher (opts.watcher).
  -- watcher must have a :watch(files, callback) method.
  function runner:watch(name, opts)
    opts = opts or {}
    local watcher = opts.watcher
    if not watcher then
      return nil, "watch requires opts.watcher"
    end
    local files = opts.files or {}
    watcher:watch(files, function()
      self:run(name)
    end)
    return true
  end

  return runner
end

return M
