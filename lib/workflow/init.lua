if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Deep copy utility (for context snapshots and restore)
-- ---------------------------------------------------------------------------

local function deep_copy(val, seen)
  if type(val) ~= "table" then return val end
  seen = seen or {}
  if seen[val] then return seen[val] end
  local copy = {}
  seen[val] = copy
  for k, v in pairs(val) do
    copy[deep_copy(k, seen)] = deep_copy(v, seen)
  end
  return copy
end

-- ---------------------------------------------------------------------------
-- Workflow definition
-- ---------------------------------------------------------------------------

-- Returns a new workflow definition object.
-- opts = { steps = { [name] = { run, on_success, on_failure, retry, timeout } }, start = name }
function M.define(opts)
  local wf = {}
  wf._steps = opts.steps or {}
  wf._start = opts.start
  wf._hooks = {
    step_start  = {},
    step_done   = {},
    step_failed = {},
    complete    = {},
  }

  -- Hook registration
  function wf:on_step_start(fn)  self._hooks.step_start[#self._hooks.step_start+1] = fn  end
  function wf:on_step_done(fn)   self._hooks.step_done[#self._hooks.step_done+1] = fn    end
  function wf:on_step_failed(fn) self._hooks.step_failed[#self._hooks.step_failed+1] = fn end
  function wf:on_complete(fn)    self._hooks.complete[#self._hooks.complete+1] = fn       end

  local function fire(hooks, ...)
    for i = 1, #hooks do hooks[i](...) end
  end

  -- Validate definition: check for missing step references, detect unreachable steps.
  -- Returns true, nil on success; false, {errmsg,...} on failure.
  function wf:validate()
    local errs = {}
    local reachable = {}
    local queue = {}

    if not self._start then
      errs[#errs+1] = "no start step defined"
    elseif not self._steps[self._start] then
      errs[#errs+1] = "start step '" .. self._start .. "' not found"
    else
      queue[#queue+1] = self._start
    end

    -- BFS over steps reachable from start
    local visited = {}
    local qi = 1
    while qi <= #queue do
      local name = queue[qi]; qi = qi + 1
      if not visited[name] then
        visited[name] = true
        reachable[name] = true
        local step = self._steps[name]
        if not step then
          errs[#errs+1] = "step '" .. name .. "' referenced but not defined"
        else
          if step.on_success and not visited[step.on_success] then
            queue[#queue+1] = step.on_success
          end
          if step.on_failure and not visited[step.on_failure] then
            queue[#queue+1] = step.on_failure
          end
        end
      end
    end

    -- Check for steps defined but not reachable
    for name in pairs(self._steps) do
      if not reachable[name] then
        errs[#errs+1] = "step '" .. name .. "' is unreachable from start"
      end
    end

    if #errs == 0 then
      return true, nil
    end
    return false, errs
  end

  -- Create a new workflow instance with optional initial context.
  function wf:start(ctx)
    local inst = {
      _wf      = self,
      status   = "pending",
      current  = self._start,
      context  = ctx and deep_copy(ctx) or {},
      history  = {},
      error    = nil,
    }

    -- Run a single named step (internal helper).
    -- Returns "done", "advance", next_step, or "failed", errmsg.
    local function run_step(name)
      local step = self._steps[name]
      if not step then
        return "failed", "step '" .. name .. "' not found"
      end

      fire(self._hooks.step_start, inst, name)

      local max_tries = 1 + (step.retry or 0)
      local last_err
      local result
      local run_ok = false

      for attempt = 1, max_tries do
        local pok, pval = pcall(step.run, inst.context)
        if pok then
          run_ok = true
          result = pval
          last_err = nil
          break
        else
          last_err = tostring(pval)
        end
      end

      if not run_ok then
        -- All attempts failed
        inst.history[#inst.history+1] = {
          step      = name,
          result    = nil,
          error     = last_err,
          retries   = step.retry or 0,
          timestamp = os.time(),
        }
        fire(self._hooks.step_failed, inst, name, last_err)
        if step.on_failure then
          return "advance", step.on_failure
        end
        return "failed", last_err
      end

      -- Success
      inst.history[#inst.history+1] = {
        step      = name,
        result    = type(result) == "string" or type(result) == "table" and #result > 0 and type(result[1]) == "string"
                      and result or result,
        error     = nil,
        retries   = 0,
        timestamp = os.time(),
      }
      fire(self._hooks.step_done, inst, name, result)

      -- Determine next step
      if type(result) == "string" then
        -- Explicit branch: run() returned a step name
        return "advance", result
      elseif type(result) == "table" and #result > 0 and type(result[1]) == "string" then
        -- Parallel: run() returned an array of step names
        for i = 1, #result do
          local pname = result[i]
          local pstatus, pval = run_step(pname)
          if pstatus == "failed" then
            return "failed", pval
          end
          -- pstatus == "advance" or "done" — just continue
        end
        -- After all parallel steps, go to on_success
        if step.on_success then
          return "advance", step.on_success
        end
        return "done", nil
      else
        -- Normal: use on_success
        if step.on_success then
          return "advance", step.on_success
        end
        return "done", nil
      end
    end

    -- Advance one step.
    -- Returns true, nil on success (step completed, workflow still running or done).
    -- Returns nil, errmsg if the workflow fails.
    function inst:step()
      if self.status == "done" or self.status == "failed" then
        return nil, "workflow already " .. self.status
      end
      self.status = "running"

      local action, val = run_step(self.current)

      if action == "done" then
        self.current = nil
        self.status = "done"
        fire(self._wf._hooks.complete, self)
        return true, nil
      elseif action == "advance" then
        self.current = val
        return true, nil
      else
        -- "failed"
        self.status = "failed"
        self.error  = val
        self.current = nil
        return nil, val
      end
    end

    -- Run all steps until done or failed.
    function inst:run()
      while self.status ~= "done" and self.status ~= "failed" do
        local ok, err = self:step()
        if not ok then return nil, err end
      end
      if self.status == "failed" then
        return nil, self.error
      end
      return true, nil
    end

    -- Serialize the instance to a plain table (no functions).
    function inst:serialize()
      return {
        current  = self.current,
        status   = self.status,
        context  = deep_copy(self.context),
        history  = deep_copy(self.history),
        error    = self.error,
      }
    end

    inst.status = "pending"
    return inst
  end

  -- Restore an instance from a snapshot, re-attaching the workflow definition.
  function wf:restore(snapshot)
    local inst = self:start(snapshot.context)
    inst.current = snapshot.current
    inst.status  = snapshot.status
    inst.history = deep_copy(snapshot.history)
    inst.error   = snapshot.error
    return inst
  end

  return wf
end

return M
